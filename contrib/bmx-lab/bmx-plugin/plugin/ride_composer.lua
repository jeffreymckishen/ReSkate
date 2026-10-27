-- One per-tick ride pipeline over the wave-1 policies. Pure: it owns no SDK
-- object, makes no reskate.* call and runs nothing on require. Every native
-- read arrives in the caller's tick table (the body sample, the measured wheel
-- rows, the selected input observation, the support owner's fact and the
-- probe batches the caller cast for this composer's own plans). Every native
-- write leaves as a request in the result (force, torque, hop impulse, wheel
-- speeds to adopt, camera view, part matrices). Nothing here proves a body
-- moved. RIDE_COMPOSER.md has the contract, the mode graph, the measured
-- offline scenarios and the gaps.
--
-- One native step is three calls on the same tick table, then a receipt:
--   plan(tick)       wheel support from the tick's rows, then the rail probe,
--                    guard and camera plans for this read, inside the read's
--                    probe_batch allowance and the per-tick raycast request
--                    budget. The guard is bound to the read's Framev1.
--                    Nothing is cast here.
--   witness(tick)    the guard's witness rays, once tick.guard holds the first
--                    guard batch.
--   step(tick)       bail, input, manual balance, grind, mode, forces, peg
--                    contacts, tricks, rider presentation and camera. Only a
--                    read that bail_policy judged on this read's guard rows
--                    submits a command; every other read fails closed.
--   accept(serial) / reject(serial, outcome)
--                    the native owner's receipt for a submitted command. Only
--                    accept advances the force kernel's history and retires
--                    the hop as accepted (FORCES.md: adopt a preview only
--                    after native acceptance).
-- plan keeps its own copy of the read, and step runs on that copy. A tick
-- whose protected fields no longer match it is refused by witness, a repeated
-- plan and step (planned_*), and the refusal is final for that read. So is a
-- read whose plan was dropped before its step (planned_read_abandoned).
local Forces = require("./forces")
local M = require("./force_math")
local Mapping = require("./ride_input_mapping")
local Balance = require("./manual_balance")
local Grind = require("./grind_policy")
local Contact = require("./grind_contact")
local Probe = require("./rail_probe")
local Bail = require("./bail_policy")
local Guard = require("./bail_guard")
local Tricks = require("./trick_runtime")
local Stage = require("./trick_presentation")
local Rider = require("./rider_presentation")
local Camera = require("./camera_policy")
local Identity = require("./lease_identity")
local Frame = require("./frame_identity")
local Composer = {}
local Ride = {}
Ride.__index = Ride

local H = Forces.native_seconds
local TAU = 2 * math.pi
-- plugin_vm.h lets one plugin start 64 logical raycast requests per VM tick.
-- The two wheel rays (ride_runtime.lua's wheel_plan) are cast before plan()
-- and the camera's occlusion ray (reskate.world.raycast, not a batch) after
-- it. The rest is shared by the rail probe (30), the guard (8 to 24) and the
-- guard witnesses (0 to 24).
Composer.request_budget = 64
Composer.wheel_rays = 2
Composer.camera_rays = 1
Composer.rail_rays = 30
-- Each lane is its own probe_batch call: the wheels, the rail, the guard and
-- the witnesses, which aim along normals the guard batch measured and must
-- carry that batch's epoch (bail_guard.lua), so they can neither share the
-- guard's batch nor move to a later read. One batch holds 1 to 32 rays
-- (plugin_api_physics.cpp probe_batch, body_query::maximum_rays). Core's
-- api.probe_batch takes up to four batches per native serial, with every
-- existing guard checked on each call. batches_per_read is what
-- the caller's native owner lets one read make, the wheel batch included;
-- by default Core's allowance. A lane past it is refused, never split or
-- deferred. The SDK's per-tick request and cast limits still apply.
Composer.batch_rays = 32
-- Core's probe_batches_per_serial, written as a literal so requiring the
-- composer does not cold-load Core and its equipment modules.
-- ride_composer_tests pins the two together.
Composer.core_batches = 4
-- Authored display gearing for the presented crank (a 25/9 BMX drive). It
-- only turns the drawn cranks; no force or input reads it.
Composer.crank_ratio = 25 / 9
-- ride_runtime.lua's rule: a hop request older than this many observed
-- input milliseconds is cancelled rather than applied late.
Composer.hop_hold_ms = 100

Composer.modes = table.freeze({ "rolling", "airborne", "manual", "nose_manual", "grinding", "bailed" })
-- The mode graph. "none" is the state before the first accepted read. A lift
-- needs a supported roll-in, so airborne never goes straight to a manual, and
-- a grind starts only from the air through grind_policy's lock-on admission.
-- bailed is entered only on a bail_policy bail, from any state including the
-- first read, and left only through the caller's recovered fact.
local edges = {
    none = { rolling = true, airborne = true, bailed = true },
    rolling = { airborne = true, manual = true, nose_manual = true, bailed = true },
    manual = { rolling = true, airborne = true, bailed = true },
    nose_manual = { rolling = true, airborne = true, bailed = true },
    airborne = { rolling = true, grinding = true, bailed = true },
    grinding = { airborne = true, rolling = true, bailed = true },
    bailed = { rolling = true, airborne = true },
}
for _, row in pairs(edges) do table.freeze(row) end
table.freeze(edges)
function Composer.allowed(from, to)
    return from == to or (edges[from] ~= nil and edges[from][to] == true)
end
function Composer.edges()
    local out = {}
    for from, row in pairs(edges) do
        out[from] = {}
        for to in pairs(row) do out[from][to] = true end
    end
    return out
end

local function plain(v) return type(v) == "table" and getmetatable(v) == nil end
local finite = M.finite
local function array(v)
    if typeof(v) == "vector" then return { v.x, v.y, v.z } end
    if plain(v) and finite(v[1]) and finite(v[2]) and finite(v[3]) then return { v[1], v[2], v[3] } end
    return nil
end
-- bail_policy's owner token rule: opaque, never a game address.
local function token(v)
    return type(v) == "userdata" or (type(v) == "string" and #v > 0 and #v <= 128)
        or (type(v) == "number" and v == v and v >= 1 and v <= 9007199254740991 and v % 1 == 0)
end
local function wrap(angle)
    angle %= TAU
    if angle > math.pi then angle -= TAU end
    return angle
end
local function zero() return { 0, 0, 0 } end
local function settings_copy(source)
    local out = {}
    if plain(source) then for k, v in pairs(source) do out[k] = M.copy(v) end end
    return out
end
-- A detached copy without opaque handles or functions, for diagnostics that
-- may be logged. Handles stay with the caller that supplied them.
local function scrub(v, depth)
    if type(v) == "userdata" or type(v) == "function" then return nil end
    if type(v) ~= "table" then return v end
    if depth > 12 then return nil end
    local out = {}
    for k, x in pairs(v) do
        if type(k) ~= "userdata" then out[k] = scrub(x, depth + 1) end
    end
    return out
end
Composer.scrub = function(v) return scrub(v, 0) end

-- The native body sample (physics.read shape: Luau vectors for position,
-- velocity, angular velocity and inertia, a Hamilton XYZW rotation table)
-- becomes the force_math body, as ride_runtime.lua's sample_copy builds it.
local function sample_body(raw)
    if not plain(raw) or type(raw.epoch) ~= "userdata" or not Identity.is_nonzero_u64(raw.serial)
        or not finite(raw.time) or raw.time < 0 or not finite(raw.seconds)
        or math.abs(raw.seconds - H) > 1e-8 or not finite(raw.mass) or not plain(raw.rotation) then return nil end
    local body = { mass = raw.mass, center_of_mass = array(raw.position), linear_velocity = array(raw.velocity),
        angular_velocity = array(raw.angular_velocity), inertia_body = array(raw.inertia),
        orientation = { raw.rotation[1], raw.rotation[2], raw.rotation[3], raw.rotation[4] } }
    if not body.center_of_mass or not body.linear_velocity or not body.angular_velocity or not body.inertia_body
        or not M.valid_body(body) or not M.vec(body.center_of_mass, 1e5) or not M.vec(body.linear_velocity, 50)
        or not M.vec(body.angular_velocity, 40) then return nil end
    return body
end
-- A shallow copy of one plain vector-like table (an array or x/y/z); a native
-- vector is a value already.
local function detached(v)
    if plain(v) then return table.clone(v) end
    return v
end
-- Step runs on what plan read (Ride:step), so the read keeps its own copy of
-- the wheel rows rather than the caller's tables: the FORCES.md sample fields
-- forces.lua, the landing evidence and the rail contacts read. Other row
-- fields are not traversed.
local function rows_copy(raw)
    if not plain(raw) then return nil end
    local out = {}
    for i = 1, 2 do
        local row = raw[i]
        if not plain(row) or not plain(row.contact) then return nil end
        local c = row.contact
        if c.status ~= "hit" and c.status ~= "clear" and c.status ~= "unavailable" then return nil end
        out[i] = { contact = { status = c.status, point = detached(c.point), normal = detached(c.normal),
            forward = detached(c.forward), surface_velocity = detached(c.surface_velocity) },
            separation = row.separation, verified_plane = row.verified_plane,
            balance_normal_available = row.balance_normal_available, balance_normal = detached(row.balance_normal) }
    end
    return out
end
local function wheels_copy(raw)
    if not plain(raw) or not M.valid_wheel(raw[1]) or not M.valid_wheel(raw[2]) then return nil end
    return { M.copy(raw[1]), M.copy(raw[2]) }
end
-- The wheel batch's own facts. A ray that may have stopped on the rider or the
-- bike's own bodies is not ground, so unqualified rows say nothing at all.
local function query_qualified(q)
    return plain(q) and q.epoch_matches == true and q.local_actor_excluded == true
        and q.owned_bodies_excluded == true and q.budget_exhausted == false
end
local function input_source(frame)
    if not plain(frame) or frame.input_ok ~= true or type(frame.lease_handle) ~= "userdata" or not plain(frame.sample) then
        return nil
    end
    local s = frame.sample
    return { lease_handle = frame.lease_handle, generation = frame.generation, user = s.user, sequence = s.sequence,
        source_epoch = s.source_epoch, context_generation = s.context_generation,
        observation_serial = s.observation_serial, observed_ms = s.observed_ms, packet = s.packet }
end
local scalar_source = { "generation", "user", "sequence", "source_epoch", "context_generation",
    "observation_serial", "observed_ms", "packet" }
-- The Ride Framev1 (frame_identity.lua) of read t with a selected source:
-- this read's sample, body handle and gates. fresh is the composer's own verdict:
-- plan builds a frame only for a read whose serial follows the last read it
-- stepped (self._serial); an unstepped planned read is not tracked.
local function read_frame(t, source)
    return { valid = true, fresh = true, body_handle = t.body_handle, physics_epoch = t.epoch,
        serial = t.serial, time = t.time, seconds = t.seconds, body = t.body, sample = t.sample, source = source,
        owner = { body_handle = t.body_handle, lease_handle = source.lease_handle },
        gates = { focused = t.gates.focused, menu_open = t.gates.menu_open } }
end
-- The Framev1 every guard plan is bound to (bail_guard.lua). Its source is
-- the selected-source observation the caller gave for this read
-- (tick.input), so the frame names this read's body and source and nothing
-- older. Returns the frame and "bound", or nil and why no qualified frame
-- exists: no source for the read, a frame frame_identity refuses, or one read
-- unfocused or in the menu, which the guard refuses too.
local function guard_frame(t, tick)
    local source = input_source(tick.input)
    if not source then return nil, tick.input == nil and "input_source_absent" or "input_source_unavailable" end
    local frame = read_frame(t, source)
    local checked, why = Frame.copy(frame)
    if not checked then return nil, "frame_" .. tostring(why) end
    if not checked.gates.focused then return nil, "frame_unfocused" end
    if checked.gates.menu_open then return nil, "frame_menu_open" end
    return checked, "bound"
end

-- The support fact trick_runtime.lua gates on. Its provenance belongs to the
-- caller's native support owner (tick.support); this composer never stamps
-- measured_support on its own geometry, so without that owner the trick
-- model refuses, as INTEGRATION_PLAN.md B3 intends.
local unknown_support = table.freeze({ known = false, grounded_known = false, grounded = false, provenance = "none" })
local function support_packet(raw)
    if raw == nil then return unknown_support, "support_owner_absent" end
    if not plain(raw) or raw.provenance ~= "measured_support" or type(raw.grounded) ~= "boolean" then
        return unknown_support, "support_owner_unqualified"
    end
    local out = { known = true, grounded_known = true, grounded = raw.grounded, provenance = "measured_support" }
    if raw.grounded then
        out.point, out.normal, out.surface_velocity = array(raw.point), array(raw.normal), array(raw.surface_velocity)
        if not out.point or not out.normal or not out.surface_velocity then return unknown_support, "support_owner_incomplete" end
    end
    return out, "none"
end

-- options: forces (forces.lua tuning overrides), input (Input settings for
-- ride_input_mapping), balance, grind, bail, tricks, camera (each module's
-- own settings), crank_ratio, command_limits ({force, torque}: the submit
-- path's own caps, at most the kernel's), batches_per_read (the probe_batch
-- calls one read may make, the wheel batch included; Composer.core_batches
-- by default), and matrices (true builds the eight part matrices inside
-- every step; otherwise Ride:matrices builds them on demand). Each module
-- sanitizes or refuses its own settings.
function Composer.new(options)
    assert(options == nil or plain(options), "ride composer options are a plain table")
    options = options or {}
    local self = setmetatable({}, Ride)
    local batches = options.batches_per_read
    if batches == nil then batches = Composer.core_batches end
    assert(type(batches) == "number" and batches >= 1 and batches <= Composer.request_budget and batches % 1 == 0,
        "batches_per_read is an integer from 1 to 64")
    self._batches = batches
    self._kernel = Forces.new(options.forces)
    self._tuning = self._kernel.tuning
    local limits = options.command_limits or {}
    assert(plain(limits), "command limits are a plain table")
    self._force_cap = limits.force or self._tuning.force_limit
    self._torque_cap = limits.torque or self._tuning.torque_limit
    assert(finite(self._force_cap) and self._force_cap > 0 and self._force_cap <= self._tuning.force_limit
        and finite(self._torque_cap) and self._torque_cap > 0 and self._torque_cap <= self._tuning.torque_limit,
        "command limits must be positive and within the kernel's")
    -- manual_balance's output is a fraction of forces.lua's manual_pitch, so
    -- the two must agree; the kernel's value wins.
    self._balance_settings = settings_copy(options.balance)
    self._balance_settings.manual_pitch = self._tuning.manual_pitch
    self._crank_ratio = options.crank_ratio or Composer.crank_ratio
    assert(finite(self._crank_ratio) and self._crank_ratio > 0, "crank ratio must be positive")
    self._mapping = Mapping.new(options.input)
    self._balance = Balance.new(self._balance_settings)
    self._grind = Grind.new(options.grind)
    self._bail = Bail.new(options.bail)
    self._tricks = Tricks.new(options.tricks)
    self._with_matrices = options.matrices == true
    self._rider = Rider.new()
    self._camera = Camera.new(options.camera)
    self.mode = "none"
    self._sequence = 0
    self._wheel_phase = { 0, 0 }
    self._raw_crank, self._crank_display, self._steer = 0, 0, 0
    self._teleport = false
    self._ticks = 0
    -- Reads refused by the plan/step join, by epoch (checked_pending). Weak
    -- keys: an epoch the caller has dropped can never be presented again.
    self._refused = setmetatable({}, { __mode = "k" })
    return self
end

------------------------------------------------------------------------------
-- Reading one tick.

function Ride:_read(tick)
    if not plain(tick) then return nil, "invalid_tick" end
    local body = sample_body(tick.sample)
    if not body then return nil, "invalid_sample" end
    if type(tick.body_handle) ~= "userdata" then return nil, "invalid_body_handle" end
    if not token(tick.owner) then return nil, "invalid_owner" end
    local wheels = wheels_copy(tick.wheels)
    if not wheels then return nil, "invalid_wheels" end
    local rows = rows_copy(tick.wheel_rows)
    if not rows then return nil, "invalid_wheel_rows" end
    if not plain(tick.gates) or type(tick.gates.focused) ~= "boolean" or type(tick.gates.menu_open) ~= "boolean" then
        return nil, "invalid_gates"
    end
    -- Everything step later reads from the read is copied here, never held
    -- as the caller's table: the sample, the gates and the wheel batch's
    -- facts, beside the body, wheels and rows above.
    local raw = tick.sample
    local sample = { epoch = raw.epoch, serial = raw.serial, time = raw.time, seconds = raw.seconds, mass = raw.mass,
        position = detached(raw.position), velocity = detached(raw.velocity),
        angular_velocity = detached(raw.angular_velocity), inertia = detached(raw.inertia),
        rotation = detached(raw.rotation) }
    local facts = tick.wheel_query
    local qualified = query_qualified(facts)
    local t = { tick = tick, sample = sample, body = body, epoch = sample.epoch, serial = sample.serial,
        time = sample.time, seconds = sample.seconds, owner = tick.owner, body_handle = tick.body_handle,
        wheels = wheels, rows = rows, qualified = qualified,
        query = qualified and { epoch_matches = facts.epoch_matches, accounting_known = facts.accounting_known == true,
            budget_exhausted = facts.budget_exhausted, local_actor_excluded = facts.local_actor_excluded,
            owned_bodies_excluded = facts.owned_bodies_excluded } or nil,
        gates = { focused = tick.gates.focused, menu_open = tick.gates.menu_open },
        support = { false, false }, hit = { false, false }, normals = {}, any = false }
    for i = 1, 2 do
        local row = rows[i]
        if t.qualified and row.contact.status == "hit" then
            t.hit[i] = true
            t.normals[i] = M.unit(row.contact.normal)
            t.support[i] = Forces.eligible_support(body, row, .005, self._tuning.maximum_penetration)
        end
    end
    t.any = t.support[1] or t.support[2]
    -- Two facts. wheels_known: each wheel's support is known (qualified rows,
    -- neither unavailable). ground_known: whether the bike is on the ground
    -- at all is known (one supported wheel says so even beside an
    -- unavailable row). A read that knows neither is a hold, never a loss of
    -- contact.
    local unavailable = rows[1].contact.status == "unavailable" or rows[2].contact.status == "unavailable"
    t.wheels_known = t.qualified and not unavailable
    t.ground_known = t.qualified and (t.any or not unavailable)
    local q = M.normalized(body.orientation)
    t.forward = M.turn(q, { 0, 0, 1 })
    return t
end

------------------------------------------------------------------------------
-- Planning this read's queries.

local function frozen_plan(fields) return table.freeze(fields) end

-- One probe_batch call per lane, in priority order. lanes is a list of
-- {name, rays}; rays is nil for a lane whose count is known only later (the
-- witnesses), which reserves a batch it may leave unused. Batch 1 is the
-- caller's wheel batch. A lane outside 1..32 rays (batch_rays), or past the
-- allowance (batch_allowance), is refused: never split across batches, never
-- merged into another lane's batch, never moved to a later read. Returns
-- {batches (the wheel batch included), lanes = {name = batch number},
-- refused = {name = reason}}.
function Composer.layout(allowance, lanes)
    assert(type(allowance) == "number" and allowance >= 1 and allowance % 1 == 0, "batch allowance is a positive integer")
    local out = { batches = 1, lanes = {}, refused = {} }
    for _, lane in ipairs(lanes) do
        local n = lane.rays
        if n ~= nil and not (type(n) == "number" and n >= 1 and n <= Composer.batch_rays and n % 1 == 0) then
            out.refused[lane.name] = "batch_rays"
        elseif out.batches >= allowance then
            out.refused[lane.name] = "batch_allowance"
        else
            out.batches += 1
            out.lanes[lane.name] = out.batches
        end
    end
    return out
end

-- The one source for a lane's rows: the raw probe_batch result for that
-- lane's rays, cast against this read's sample epoch, which probe_batch
-- returns as batch.epoch (plugin_api_physics.cpp). A Contact.decode copy
-- carries its facts under query and binding and has no epoch, so it is
-- refused here rather than believed; rail_probe and bail_guard would also
-- refuse it on the epoch. Returns nil, or why the batch is not that source.
local function raw_batch_issue(batch, epoch, lane)
    if batch == nil then return lane .. "_batch_missing" end
    if not plain(batch) then return lane .. "_batch_malformed" end
    if rawget(batch, "query") ~= nil or rawget(batch, "binding") ~= nil then return lane .. "_batch_contact_copy" end
    if not rawequal(rawget(batch, "epoch"), epoch) then return lane .. "_epoch_mismatch" end
    return nil
end

-- The plan/witness/step join (RIDE_COMPOSER.md, The same-table contract). The
-- pending plan keeps its own read (p.t, the copies Ride:_read made), and step
-- runs on it. Before a cached plan or witness is returned, and before step
-- touches chronology or any model, the caller's original tick is read again
-- and compared with what plan saw: for a bound plan, the guard's frozen
-- Framev1 and the known pad values; for every plan, the outer table, epoch,
-- serial and mount owner. Wheel facts are not compared, because nothing reads
-- them again: the plan's copies are what step uses.
local body_fields = { "center_of_mass", "linear_velocity", "angular_velocity", "inertia_body", "orientation" }
local pad_fields = { "left_x", "left_y", "right_x", "right_y", "left_trigger", "right_trigger", "playstation" }
local button_fields = { "up", "down", "left", "right", "start", "back", "left_stick", "right_stick",
    "lb", "rb", "a", "b", "x", "y" }
-- The mapper's own key sets (ride_input_mapping.lua pad_keys, button_keys).
local pad_known, button_known = { buttons = true }, {}
for _, name in ipairs(pad_fields) do pad_known[name] = true end
for _, name in ipairs(button_fields) do button_known[name] = true end
-- Keep only the bounded input payload the models read. nil is a pad the
-- mapper refuses whatever its other values (ride_input_mapping.lua
-- sample_valid), so two refused pads are the same and step's mapper refuses
-- either: a non-plain pad or buttons table, a key outside the mapper's pad or
-- button set, a value of the wrong type, or a NaN or infinite number (the
-- mapper's own finite rule). The keys are walked as the mapper walks them; an
-- unknown key's value is never read, and no table but the buttons is entered.
-- Other invalid values are kept and compared as they are, and the mapper
-- refuses them at step as it always did.
local function pad_copy(input)
    if not plain(input) or not plain(input.sample) or not plain(input.sample.pad)
        or not plain(input.sample.pad.buttons) then return nil end
    local pad, out = input.sample.pad, { buttons = {} }
    for name in pairs(pad) do if not pad_known[name] then return nil end end
    for name in pairs(pad.buttons) do if not button_known[name] then return nil end end
    for _, name in ipairs(pad_fields) do
        local value = rawget(pad, name)
        if value ~= nil and type(value) ~= "number" and type(value) ~= "boolean" then return nil end
        if type(value) == "number" and not finite(value) then return nil end
        out[name] = value
    end
    for _, name in ipairs(button_fields) do
        local value = rawget(pad.buttons, name)
        if value ~= nil and type(value) ~= "boolean" then return nil end
        out.buttons[name] = value
    end
    table.freeze(out.buttons)
    return table.freeze(out)
end
local function same_number(a, b) return a == b and (a ~= 0 or 1 / a == 1 / b) end
local function same_pad(a, b)
    if a == nil or b == nil then return a == b end
    for _, name in ipairs(pad_fields) do
        if type(a[name]) == "number" and type(b[name]) == "number" then
            if not same_number(a[name], b[name]) then return false end
        elseif a[name] ~= b[name] then return false end
    end
    for _, name in ipairs(button_fields) do if a.buttons[name] ~= b.buttons[name] then return false end end
    return true
end

local function tick_epoch(tick)
    if plain(tick) and plain(tick.sample) and type(tick.sample.epoch) == "userdata" then return tick.sample.epoch end
    return nil
end
-- The pending plan this tick is the read of, or nil. On the planned table, a
-- different epoch is a new read: the caller reused the table, so the new read
-- plans afresh (and a step without that plan is uncast), and the plan it
-- replaces is abandoned (abandon). A planned table that no longer shows an
-- epoch at all is the planned read gone invalid, and is refused. Another
-- table carrying the planned epoch is the planned read too, and is refused
-- (planned_tick_changed).
local function pending_for(self, tick)
    local p = self._pending
    if not p then return nil end
    local epoch = tick_epoch(tick)
    if rawequal(p.t.tick, tick) then
        if epoch ~= nil and not rawequal(epoch, p.epoch) then return nil end
        return p
    end
    if epoch ~= nil and rawequal(epoch, p.epoch) then return p end
    return nil
end
-- The refusal already recorded for the read this tick names, if any.
local function refusal_for(self, tick)
    local epoch = tick_epoch(tick)
    return epoch ~= nil and self._refused[epoch] or nil
end
-- The first difference between pending plan p and tick, or nil.
local function drift(self, p, tick)
    local t, why = self:_read(tick)
    if not t then return "planned_read_invalid_" .. why end
    if not rawequal(p.t.tick, tick) then return "planned_tick_changed" end
    if not rawequal(t.epoch, p.epoch) or t.serial ~= p.serial then return "planned_body_changed" end
    if not rawequal(t.owner, p.t.owner) then return "planned_owner_changed" end
    -- An unbound plan has no frame to compare. It submits nothing, and step
    -- runs on its plan-time copies either way.
    if not p.frame then return nil end
    -- Guard's Framev1 is detached and frozen at plan time. Continuity's
    -- duplicate verdict is deliberately weaker than this exact join.
    local old = p.frame.query_frame
    if t.gates.focused ~= old.gates.focused or t.gates.menu_open ~= old.gates.menu_open then
        return "planned_gates_changed"
    end
    local current = guard_frame(t, tick)
    if not current then return "planned_frame_unavailable" end
    if not rawequal(old.body_handle, current.body_handle) or not same_number(old.time, current.time)
        or not same_number(old.seconds, current.seconds) or not same_number(old.body.mass, current.body.mass) then
        return "planned_body_changed"
    end
    for _, name in ipairs(body_fields) do
        for i = 1, name == "orientation" and 4 or 3 do
            if not same_number(old.body[name][i], current.body[name][i]) then return "planned_body_changed" end
        end
    end
    if not rawequal(old.source.lease_handle, current.source.lease_handle) then return "planned_source_changed" end
    for _, name in ipairs(scalar_source) do
        if old.source[name] ~= current.source[name] then return "planned_source_changed" end
    end
    if not same_pad(p.pad, pad_copy(tick.input)) then return "planned_input_changed" end
    return nil
end
local function checked_pending(self, p, tick)
    local issue = self._refused[p.epoch]
    if issue then return false, issue end
    issue = drift(self, p, tick)
    if issue then
        -- Final for this read, keyed by its epoch: neither restoring the
        -- caller's table nor planning the same read again revives it. A new
        -- plan would bind fresh guard rays while the table may still hold
        -- same-epoch rows cast for the old ones.
        self._refused[p.epoch] = issue
        return false, issue
    end
    return true
end
-- Drops the pending plan before its step: plan was given an invalid read,
-- another read (another table, the planned table reused, a duplicate or
-- regressed read), or a step planned its own read. The dropped read is final
-- too (planned_read_abandoned), for the same reason as a refusal: its table
-- may still hold same-epoch rows cast for the rays it planned, and a new plan
-- for it would bind fresh rays they do not answer. A refusal already recorded
-- for it is kept.
local function abandon(self)
    local p = self._pending
    if p and self._refused[p.epoch] == nil then self._refused[p.epoch] = "planned_read_abandoned" end
    self._pending = nil
end

-- The rail probe runs while the bike is known to be unsupported or grinding:
-- grind_policy admits a lock-on only from the air, and a supported step
-- disarms it anyway. Bail detection outranks grind detection: lanes go guard,
-- rail, witnesses; after a tick whose guard witnesses did not fit, the rail
-- probe yields until they fit again. While grinding the rail goes first,
-- since losing its rows would end the grind. One read plans once: a repeated
-- plan for it, or a plan for a read this composer has already stepped, asks
-- for nothing new and does not advance the camera.
--
-- Every guard plan is bound to this read's Framev1 (guard_frame). A read
-- without a qualified one, or one the guard cannot plan for at all, gets no
-- guard plan (bail_guard_unbound or the guard's own reason), and neither does
-- one whose guard lane the batch allowance refuses (batch_allowance). step
-- submits nothing for any of them, nor for a planned read bail_policy does not
-- judge: riding without bail protection is unsafe, so the composer fails
-- closed rather than pushing a body nothing guards.
function Ride:plan(tick)
    local pending = pending_for(self, tick)
    if pending then
        local ok, issue = checked_pending(self, pending, tick)
        if not ok then return frozen_plan({ valid = false, issue = issue }) end
        return pending.plan
    end
    local refusal = refusal_for(self, tick)
    if refusal then return frozen_plan({ valid = false, issue = refusal }) end
    local t, why = self:_read(tick)
    if not t then
        abandon(self)
        return frozen_plan({ valid = false, issue = why })
    end
    if self._serial then
        local order = Identity.compare(t.serial, self._serial)
        if order <= 0 then
            local issue = order == 0 and "duplicate_read" or "serial_regressed"
            local plan = frozen_plan({ valid = order == 0, issue = issue, serial = t.serial, requests = Composer.wheel_rays,
                budget = Composer.request_budget, batches = 1, batch_allowance = self._batches, witness_batch = false,
                rail_issue = "stale_read", guard_issue = "stale_read" })
            abandon(self)
            self._pending = { t = t, epoch = t.epoch, serial = t.serial, stale = true, plan = plan,
                guard_issue = "stale_read", rail_issue = "stale_read", camera = false, camera_issue = "stale_read",
                used = Composer.wheel_rays, batches = 1, witness_batch = false }
            return plan
        end
    end
    local used = Composer.wheel_rays + Composer.camera_rays
    local grinding = self.mode == "grinding"
    local query_frame, binding = guard_frame(t, tick)
    local frame, guard_plan, guard_issue = nil, nil, "bail_guard_unbound"
    if query_frame then
        frame = { serial = t.serial, seconds = t.seconds, owner = t.owner, body = t.body, query_frame = query_frame }
        guard_plan, guard_issue = Guard.plan(frame, self._guard_previous)
        if not guard_plan and guard_issue == "invalid_guard_frame" then
            frame, binding, guard_issue = nil, "guard_frame_refused", "bail_guard_unbound"
        end
    end
    local guard_rays = guard_plan and #guard_plan.rays or 0
    local rail_plan, rail_issue = nil, "not_requested"
    if (t.ground_known and not t.any) or grinding then
        if self._guard_pressure and not grinding then
            rail_issue = "guard_priority"
        elseif used + guard_rays + Composer.rail_rays > Composer.request_budget then
            rail_issue = "request_budget"
        else
            rail_issue = "none"
        end
    end
    local lanes = {}
    local guard_lane = guard_plan and { name = "guard", rays = guard_rays } or nil
    local rail_lane = rail_issue == "none" and { name = "rail", rays = Composer.rail_rays } or nil
    local witness_lane = guard_plan and { name = "witness" } or nil
    for _, lane in ipairs(grinding and { rail_lane or false, guard_lane or false, witness_lane or false }
        or { guard_lane or false, rail_lane or false, witness_lane or false }) do
        if lane then table.insert(lanes, lane) end
    end
    local layout = Composer.layout(self._batches, lanes)
    if guard_plan and layout.refused.guard then guard_plan, guard_issue = nil, layout.refused.guard end
    if guard_plan then used += #guard_plan.rays end
    if rail_lane then
        if layout.refused.rail then
            rail_issue = layout.refused.rail
        else
            rail_plan, rail_issue = Probe.plan(t.body, { epoch = t.epoch })
            if rail_plan and #rail_plan.rays > Composer.batch_rays then rail_plan, rail_issue = nil, "batch_rays" end
            if rail_plan then
                rail_issue = "none"
                used += #rail_plan.rays
            end
        end
    end
    local witness_batch = guard_plan ~= nil and layout.lanes.witness ~= nil
    local batches = 1 + (guard_plan and 1 or 0) + (rail_plan and 1 or 0)
    -- Unknown support keeps the camera's last known ground state.
    local grounded = self.mode == "grinding" or (t.ground_known and t.any)
        or (not t.ground_known and self._view_grounded == true)
    if t.ground_known then self._view_grounded = grounded end
    local view, camera_issue = self._camera:step({ position = t.sample.position, velocity = t.sample.velocity,
        rotation = t.sample.rotation, grounded = grounded, teleport = self._teleport }, t.seconds)
    self._teleport = false
    local plan = frozen_plan({ valid = true, issue = "none", serial = t.serial, rail = rail_plan, guard = guard_plan,
        camera = view and view.ray or nil, requests = used, budget = Composer.request_budget, batches = batches,
        batch_allowance = self._batches, witness_batch = witness_batch,
        rail_issue = rail_issue, guard_issue = guard_plan and "none" or guard_issue, guard_binding = binding })
    abandon(self)
    self._pending = { t = t, epoch = t.epoch, serial = t.serial, frame = frame,
        pad = frame and pad_copy(tick.input) or nil, guard = guard_plan,
        guard_issue = guard_plan and "none" or guard_issue, guard_binding = binding,
        rail = rail_plan, rail_issue = rail_issue,
        camera = view ~= nil, camera_issue = view and "none" or camera_issue, used = used, plan = plan,
        batches = batches, witness_batch = witness_batch }
    return plan
end

local function no_witness(reason) return table.freeze({ available = false, reason = reason, rays = table.freeze({}) }) end
-- The guard aims each witness along a normal it has only just measured, so
-- the witnesses go in their own batch after the guard's. A witness set with
-- no batch left in this read's allowance, or that does not fit what is left
-- of the request budget, makes the guard unavailable for this read (an
-- uncast witness is never clear) and gives the guard priority next tick.
function Ride:witness(tick)
    local p = pending_for(self, tick)
    if not p then return no_witness(refusal_for(self, tick) or "plan_required") end
    local ok, issue = checked_pending(self, p, tick)
    if not ok then return no_witness(issue) end
    if p.witness_done then return p.witness or no_witness(p.witness_issue) end
    if not p.guard then return no_witness(p.guard_issue) end
    if tick.guard == nil then
        p.witness_issue = "guard_batch_missing"
        return no_witness("guard_batch_missing")
    end
    p.witness_done = true
    local source = raw_batch_issue(tick.guard, p.epoch, "guard")
    if source then
        p.witness_issue = source
        return no_witness(source)
    end
    local w = Guard.witness(p.guard, tick.guard)
    if w.available and #w.rays > 0 then
        local refusal
        if not p.witness_batch then
            refusal = "witness_batch_allowance"
        elseif #w.rays > Composer.batch_rays then
            refusal = "witness_batch_rays"
        elseif #w.rays > Composer.request_budget - p.used then
            refusal = "witness_budget"
        end
        if refusal then
            p.witness, p.witness_issue = nil, refusal
            self._guard_pressure = true
            return no_witness(refusal)
        end
    end
    p.witness, p.witness_issue = w, w.available and "none" or w.reason
    if w.available then
        p.used += #w.rays
        if #w.rays > 0 then p.batches += 1 end
        self._guard_pressure = false
    end
    return w
end

------------------------------------------------------------------------------
-- The step.

-- Every edge taken is in the graph. Anything else is refused here, not taken.
function Ride:_transition(events, to, reason)
    local from = self.mode
    if from == to then return true end
    if not Composer.allowed(from, to) then
        self._edge_refused = from .. "_to_" .. to
        return false
    end
    self._sequence += 1
    table.insert(events, { name = "mode", from = from, to = to, reason = reason, sequence = self._sequence })
    self.mode = to
    return true
end

-- Settles the mode the sub-models describe against the mode graph. A refused
-- edge is reported and replaced by the nearest allowed one. Entering a grind
-- also needs this read's grind_policy lock_on.
local function settle(from, wanted, supported, lock_on)
    local fallback = supported and "rolling" or "airborne"
    if Composer.allowed(from, wanted) then
        if wanted ~= "grinding" or from == "grinding" or lock_on == true then return wanted, nil end
        return Composer.allowed(from, fallback) and fallback or from, "grind_without_lock_on"
    end
    if (wanted == "manual" or wanted == "nose_manual") and Composer.allowed(from, "rolling") then
        return "rolling", from .. "_to_" .. wanted .. "_refused"
    end
    if wanted == "grinding" and Composer.allowed(from, fallback) then
        return fallback, from .. "_to_grinding_refused"
    end
    return from, from .. "_to_" .. wanted .. "_refused"
end
Composer.settle = settle

local function reason_for(from, to, grind, balance, refusal)
    if refusal then return refusal end
    if to == "grinding" then return "grind_lock_on" end
    if from == "grinding" then
        return "grind_exit_" .. (grind.exit_reason ~= "none" and grind.exit_reason or "rows_lost")
    end
    if to == "manual" or to == "nose_manual" then return "lift_started" end
    if from == "manual" or from == "nose_manual" then
        local event = balance.event
        return "lift_ended_" .. ((event and event.reason) or balance.end_reason or "none")
    end
    if to == "airborne" then return from == "none" and "first_read" or "wheel_contact_lost" end
    if from == "none" then return "first_read" end
    return "landed"
end

-- Every sub-model back to its first-tick state, for a recovered rider. A
-- command still waiting for its receipt is dropped with the old mount.
function Ride:_reset_models(reason)
    local dropped = self._outstanding and self._outstanding.serial or nil
    self._kernel:reset()
    self._kernel_serial, self._outstanding = nil, nil
    self._balance = Balance.new(self._balance_settings)
    self._grind:reset()
    self._bail:reset()
    self._tricks:cancel(reason)
    self._mapping:reset(reason)
    self._rider:reset()
    self._camera:reset()
    self._teleport = true
    self._guard_previous, self._last_command, self._approach = nil, nil, nil
    self._was_supported, self._contact_serial = false, nil
    self._policy_bail, self._trick_reserved, self._recovery_pending = nil, false, false
    return dropped
end

local function refused(self, issue)
    return { valid = false, issue = issue, mode = self.mode, events = {},
        commands = { submit = false }, presentation = {}, camera = nil, diagnostics = { issue = issue } }
end

-- The force/velocity residual proxy of Extension/BMX/bmx_chassis_ride.cpp
-- (impact_contacts): the measured velocity change that the last read's
-- command and gravity do not explain, as an impulse. Only for the exact
-- successor of a read whose command fate is known (accepted, rejected or
-- never sent). It pairs C_N with B_N+1, which is sim_world's phase; the
-- native phase FORCES.md observed (C_N applied at N+1) is not modelled.
function Ride:_residual(t)
    local last = self._last_command
    if not last or Identity.bounded_delta(t.serial, last.serial, 1) ~= 1 then return nil end
    local m, out = t.body.mass, 0
    for i = 1, 3 do
        local expected = last.velocity[i] + last.force[i] * t.seconds / m + last.hop_impulse[i] / m
            + self._tuning.gravity[i] * t.seconds
        local r = (t.body.linear_velocity[i] - expected) * m
        out += r * r
    end
    return math.sqrt(out)
end

-- Peg and tire contacts against a rail, solved one after another on the body
-- as the kernel left it, so two pegs on one rail do not each stop the whole
-- closing speed. grind_contact predicts gravity itself, so the body passed to
-- it carries only the kernel's impulse. A tire row is solved only while that
-- wheel's ground row is clear, so no contact is solved twice.
local peg_names = { "front_left", "front_right", "rear_left", "rear_right" }
local function rail_contacts(body, kernel, contacts, wheel_rows, gravity, h)
    local after = M.copy(body)
    after.linear_velocity = M.add(after.linear_velocity,
        M.add(M.mul(kernel.force, h / body.mass), M.mul(kernel.hop_impulse, 1 / body.mass)))
    after.angular_velocity = M.add(after.angular_velocity, M.tensor(body, M.mul(kernel.torque, h), true))
    local rows = {}
    for _, name in ipairs(peg_names) do
        local row = contacts.pegs[name]
        if row and row.available == true and row.touching == true then table.insert(rows, { name = name, row = row }) end
    end
    for i, name in ipairs({ "front", "rear" }) do
        local row = contacts.tires[name]
        if row and row.available == true and row.touching == true and wheel_rows[i].contact.status == "clear" then
            table.insert(rows, { name = name, row = row })
        end
    end
    local force, torque, active, normal = zero(), zero(), {}, 0
    if #rows == 0 then return force, torque, active, 0, true end
    -- Two passes: the second lets a contact take up what the other's impulse
    -- changed at its point. The normal impulse never pulls, so a pass cannot
    -- undo the first one's push.
    for _ = 1, 2 do
        for _, entry in ipairs(rows) do
            local r = Contact.solve(after, entry.row, gravity, h)
            if not r.valid then return zero(), zero(), {}, 0, false end
            if r.active then
                force, torque = M.add(force, r.force), M.add(torque, r.torque)
                after.linear_velocity = M.add(after.linear_velocity, M.mul(r.force, h / body.mass))
                after.angular_velocity = M.add(after.angular_velocity, M.tensor(after, M.mul(r.torque, h), true))
                active[entry.name] = true
                normal += r.normal_impulse
            end
        end
    end
    return force, torque, active, normal, true
end

-- Landing evidence for rider_presentation's compression cue, in the
-- bmx_landing_approach Evidence fields it reads. The approach speed is the
-- last unsupported read's velocity into the contact normal. The C++ Tracker
-- itself is not ported; this is the composer's own reduction of it.
function Ride:_evidence(t)
    local out = { valid = true, post_available = t.any, first_contact = false }
    if t.any then
        local closing = 0
        for i = 1, 2 do
            if t.support[i] then
                local c = t.rows[i].contact
                local relative = M.sub(M.point_velocity(t.body, c.point), c.surface_velocity)
                closing = math.max(closing, -M.dot(relative, t.normals[i]))
            end
        end
        if not self._was_supported then
            self._contact_serial = t.serial
            out.first_contact = true
            local approach = 0
            if self._approach then
                for i = 1, 2 do
                    if t.support[i] then approach = math.max(approach, -M.dot(self._approach, t.normals[i])) end
                end
            end
            out.scoring_closing_speed = math.max(approach, closing)
            self._last_landing = { serial = t.serial, closing = out.scoring_closing_speed }
        end
        out.contact_serial = self._contact_serial
        out.post_closing_speed = closing
    else
        self._approach = M.copy(t.body.linear_velocity)
    end
    self._was_supported = t.any
    return out
end

function Ride:_judge_bail(events, p, tick, residual, bail)
    if not p.guard then bail.guard = p.guard_issue; return end
    if not (p.witness and p.witness.available) then
        bail.guard = p.witness_issue or "witness_not_called"
        return
    end
    local witness_batch
    if #p.witness.rays > 0 then
        local source = raw_batch_issue(tick.witness, p.epoch, "witness")
        if source then
            bail.guard = source
            return
        end
        witness_batch = tick.witness
    end
    local decoded = Guard.decode(p.witness, witness_batch)
    bail.guard = decoded.available and "available" or decoded.reason
    local sample = Guard.policy_sample(p.guard, decoded, residual)
    if not sample then return end
    local r = self._bail:step(sample)
    bail.evaluated, bail.valid, bail.issue = true, r.valid, r.issue
    bail.bail, bail.reason, bail.region = r.bail, r.reason, r.region
    bail.closing_speed, bail.alignment, bail.tilt_steps = r.closing_speed, r.alignment, r.tilt_steps
    if decoded.available then
        local hits = 0
        for _, row in ipairs(decoded.contacts) do if row.hit then hits += 1 end end
        bail.contacts, bail.witness_rays = hits, decoded.witness_rays
    end
    if r.bail and self:_transition(events, "bailed", r.reason) then
        self._kernel:reset()
        self._kernel_serial = nil
        -- A command already submitted keeps its receipt, but its kernel
        -- candidate describes a ride that has ended.
        if self._outstanding then self._outstanding.adoptable = false end
        self._balance:cancel()
        self._tricks:cancel("bailed")
        self._grind:reset()
    end
end

-- The receipt for the one submitted command still waiting for one. accept
-- adopts that read's previewed kernel and retires its hop as accepted when
-- the kernel applied it; reject drops the candidate and cancels the hop, or
-- marks it uncertain (ride_input_mapping then blocks until a reset, as its
-- contract requires for an unknown outcome).
function Ride:_settle_command(serial, outcome)
    local o = self._outstanding
    if not o then return false, "no_outstanding_command" end
    if serial ~= o.serial then return false, "serial_mismatch" end
    self._outstanding = nil
    local disposition
    if outcome == "applied" then
        if o.adoptable then self._kernel, self._kernel_serial = o.candidate, o.serial end
        self._last_command = o.residual
        disposition = o.hop_applied and "accepted" or "cancelled"
    elseif outcome == "uncertain" then
        self._last_command = nil
        disposition = "uncertain"
    else
        self._last_command = { serial = o.serial, velocity = o.residual.velocity, force = zero(), hop_impulse = zero() }
        disposition = "cancelled"
    end
    local hop = "none"
    if o.hop_id then
        local ok, why = self._mapping:retire_hop(o.hop_id, disposition)
        hop = ok and disposition or why
    end
    self._last_receipt = { serial = o.serial, outcome = outcome, hop = hop,
        adopted = outcome == "applied" and o.adoptable }
    return true, "none"
end
function Ride:accept(serial) return self:_settle_command(serial, "applied") end
function Ride:reject(serial, outcome)
    if outcome ~= nil and outcome ~= "rejected" and outcome ~= "expired" and outcome ~= "uncertain" then
        return false, "invalid_outcome"
    end
    return self:_settle_command(serial, outcome == "uncertain" and "uncertain" or (outcome or "rejected"))
end

-- rider_presentation's output without the crank's owner identity, the only
-- opaque handles it carries.
local function rider_public(r)
    local out = table.clone(r)
    if type(r.crank) == "table" then
        out.crank = table.clone(r.crank)
        if type(r.crank.state) == "table" then
            out.crank.state = table.clone(r.crank.state)
            out.crank.state.identity = nil
        end
    end
    return out
end

local function trimmed_bike(placed)
    return { valid = true, fresh = placed.fresh, issue = placed.issue, serial = placed.serial, time = placed.time,
        pose = placed.pose, offsets = placed.offsets, matrices = placed.matrices }
end

-- tick = {sample, body_handle, owner, wheels, wheel_rows, wheel_query, gates,
-- input, support, rail, guard, witness, camera_hit, recovered}.
-- RIDE_COMPOSER.md lists each field. Returns {valid, issue, serial, mode,
-- events, commands, presentation, camera, diagnostics}.
function Ride:step(tick)
    self._ticks += 1
    local p = pending_for(self, tick)
    if not p then
        -- No plan for this read: plan now. Its queries were never cast, so
        -- rail and guard rows are unavailable and the camera resolves clear.
        -- A read already refused stays refused (plan returns its refusal and
        -- keeps any pending plan). Otherwise planning this read abandons
        -- another read's pending plan.
        local plan = self:plan(tick)
        if not plan.valid then return refused(self, plan.issue) end
        p = self._pending
        p.uncast = true
        p.batches = 1
        p.witness_issue = p.witness_issue or "uncast"
    end
    self._pending = nil
    local ok, issue = checked_pending(self, p, tick)
    if not ok then
        -- A read nothing judged: it lends neither sweep history nor a
        -- residual baseline to the next one.
        self._guard_previous, self._last_command = nil, nil
        return refused(self, issue)
    end
    -- The plan's own read, as plan saw it. Nothing outside what
    -- checked_pending compared is read from the caller's tick again: the
    -- body, wheels, wheel rows and wheel batch facts are the plan's copies.
    -- The query results the caller appended since (rail, guard, witness,
    -- camera_hit), the input observation for the mapper, the support owner's
    -- fact and recovered are read below, as they always were.
    local t = p.t
    local events, h, gravity = {}, t.seconds, self._tuning.gravity
    local diagnostics = { support = { front = t.support[1], rear = t.support[2], any = t.any,
        rows_qualified = t.qualified, wheels_known = t.wheels_known, ground_known = t.ground_known },
        queries = { requests = p.used, rail = p.rail_issue, guard = p.guard_issue, guard_binding = p.guard_binding,
            witness = p.witness_issue or "none", uncast = p.uncast == true, batches = p.batches,
            batch_allowance = self._batches, witness_batch = p.witness_batch == true } }

    -- Chronology. A duplicate read submits nothing new.
    local consecutive = false
    if self._serial then
        local order = Identity.compare(t.serial, self._serial)
        if order == 0 then
            local out = refused(self, "duplicate_read")
            out.valid = true
            return out
        end
        if order < 0 then return refused(self, "serial_regressed") end
        consecutive = Identity.bounded_delta(t.serial, self._serial, 1) == 1
    end
    self._serial = t.serial
    diagnostics.consecutive = consecutive
    self._edge_refused = nil

    -- Bail: the guard's two batches, the residual proxy and bail_policy.
    local residual = self:_residual(t)
    local bail = { evaluated = false, residual = residual }
    if self.mode ~= "bailed" then self:_judge_bail(events, p, tick, residual, bail) end
    -- The guard lends sweep history only from a read bail_policy accepted.
    -- After a read it did not judge, the policy's own history has a gap, and
    -- a swept row on the next read would be refused as invalid_sample
    -- (bail_policy.lua's port of bmx_bail_policy.h:117-129), read after read
    -- while the crossing lasts, leaving each of those reads unguarded.
    -- Without that history the next plan casts no swept ray, the policy
    -- accepts it, and both histories restart together.
    local judged = bail.evaluated and bail.valid == true
    self._guard_previous = judged and p.frame or nil
    diagnostics.bail = bail
    diagnostics.outstanding = self._outstanding and self._outstanding.serial or nil
    diagnostics.receipt = self._last_receipt

    local recovered = false
    if self.mode == "bailed" then
        if tick.recovered == true then self._recovery_pending = true end
        -- The caller's recovered fact, completed on the first read that knows
        -- where the wheels are, so the recovered mode is not a guess.
        if not (self._recovery_pending and t.ground_known) then
            self._last_command = nil
            local camera = p.camera and self._camera:resolve(tick.camera_hit) or nil
            return { valid = true, issue = self._recovery_pending and "recovery_support_unknown" or "bailed",
                serial = t.serial, mode = self.mode, events = events, commands = { submit = false }, presentation = {},
                camera = camera, diagnostics = diagnostics }
        end
        -- The fall and recovery the caller owns are done and this read is the
        -- bike placed again. Everything restarts from a neutral prime, as on
        -- a new mount.
        local dropped = self:_reset_models("recovered")
        self:_transition(events, t.any and "rolling" or "airborne", "recovered")
        table.insert(events, { name = "recovered", serial = t.serial, dropped_command = dropped })
        p.camera = false
        recovered = true
    end
    -- Whether this read is guarded: bail_policy stepped on this read's own
    -- decoded guard sample and accepted it. Anything else is unguarded and
    -- submits nothing (see the submit decision below), with the reason
    -- named: the guard's (bail.guard: no plan, batch_allowance, a refused or
    -- missing guard or witness batch, witnesses that did not fit, a witness
    -- never called, an uncast read), the policy's own refusal
    -- (bail_policy_<issue>), or recovered_unjudged on the read that leaves
    -- bailed: bail_policy did not step on that read, because the ride was
    -- still bailed when its bail was judged, and the recovery has just reset
    -- the policy. The next read is judged afresh.
    local unguarded
    if recovered then
        unguarded = "recovered_unjudged"
    elseif not bail.evaluated then
        unguarded = bail.guard or "bail_unjudged"
    elseif not bail.valid then
        unguarded = "bail_policy_" .. tostring(bail.issue)
    end
    bail.guarded = unguarded == nil
    bail.unguarded = unguarded

    -- Input: the selected-source observation and the bound force controls.
    -- The input context stays grounded through a locked grind and through
    -- manual_balance's airborne grace, so a support flicker during a lift
    -- does not clear input.lua's manual gesture under it. A read that does
    -- not know the ground keeps the last known context.
    local grind_state, balance_state = self._grind:state(), self._balance:status()
    local lifting = balance_state.state == "entering" or balance_state.state == "balancing"
    local context_grounded
    if t.ground_known then
        context_grounded = t.any or grind_state.phase == "locked" or grind_state.phase == "stalled" or lifting
        self._context_grounded = context_grounded
    else
        context_grounded = self._context_grounded == true
    end
    local observe_issue = "none"
    if tick.input ~= nil then
        local observed = self._mapping:observe(tick.input, { grounded = context_grounded, focused = t.gates.focused,
            menu_open = t.gates.menu_open, rotation_reserved = self._trick_reserved == true })
        observe_issue = observed.issue
        local source = input_source(tick.input)
        if observed.valid and source then
            self._source = source
            self._pad = tick.input.sample.pad
        end
    end
    local controls = self._mapping:controls({ physics_epoch = t.epoch, h = h, grounded = context_grounded,
        rotation_reserved = self._trick_reserved == true })
    local active = controls.valid == true
    local actions = active and controls.actions or nil
    local pad = self._pad
    diagnostics.input = { active = active, issue = active and "none" or controls.issue, observe = observe_issue,
        hop = controls.hop and controls.hop.id or 0, context_grounded = context_grounded,
        manual = actions and actions.manual or 0, nose_manual = actions and actions.nose_manual or 0 }

    -- Manual balance owns the pitch controls whenever a wheel is supported.
    -- It needs both wheels' support facts, so a read without them is a hold.
    local support_up = { 0, 1, 0 }
    if t.any then
        local sum = zero()
        for i = 1, 2 do if t.support[i] then sum = M.add(sum, t.normals[i]) end end
        support_up = M.unit(sum) or support_up
    end
    local pitch, pitch_rate = Balance.measure(t.body.orientation, t.body.angular_velocity, support_up)
    pitch, pitch_rate = pitch or 0, pitch_rate or 0
    local speed = M.dot(t.body.linear_velocity, t.forward)
    local balance
    if t.wheels_known then
        balance = self._balance:step({ manual = actions and actions.manual or 0,
            nose_manual = actions and actions.nose_manual or 0, preload = actions and actions.preload or 0,
            hop = actions ~= nil and actions.hop_pressed, rear_neutral = actions ~= nil and actions.rear_neutral,
            pitch = pitch, pitch_rate = pitch_rate, front_support = t.support[1], rear_support = t.support[2],
            speed = math.clamp(speed, -100, 100) }, h)
    else
        local st = self._balance:status()
        balance = { state = st.state, kind = st.kind, armed = st.armed, target = st.target, end_reason = st.end_reason,
            issue = "support_unknown", manual = 0, nose_manual = 0 }
    end
    if balance.event then table.insert(events, { name = "balance", event = balance.event }) end
    if balance.bail_request then
        -- A request only. bail_policy decides, from measured contacts.
        self._policy_bail = { source = "manual_balance", reason = balance.event.reason, serial = t.serial }
    end
    diagnostics.balance = { state = balance.state, kind = balance.kind, issue = balance.issue, lift = balance.lift,
        target = balance.target, balance = balance.balance, armed = balance.armed, manual = balance.manual,
        nose_manual = balance.nose_manual, pitch = pitch, speed = speed, stepped = t.wheels_known }

    -- Rail rows, then grind_policy. A read without them, or without known
    -- ground, is a hold, never clear: grind_policy disarms while idle and
    -- counts toward its own cancel while locked. The rows come only from the
    -- raw probe_batch for this plan's rays on this read's epoch; Probe.plan
    -- was given that epoch, so Probe.decode also refuses any other.
    local rail, rail_rows = nil, p.rail_issue
    if p.rail then
        if p.uncast then
            rail_rows = "uncast"
        elseif not t.ground_known then
            rail_rows = "support_unknown"
        else
            rail_rows = raw_batch_issue(tick.rail, p.epoch, "rail")
            if not rail_rows then
                rail = Probe.decode(p.rail, tick.rail)
                rail_rows = rail.status == "available" and "available" or rail.reason
            end
        end
    end
    local contacts = rail and rail.contacts or nil
    local grind = self._grind:step({ seconds = h, ground_support = t.any, body = t.body, contacts = contacts,
        input = { enabled = active, lean = actions and actions.steer or 0,
            hop = (actions ~= nil and actions.hop_pressed) or (pad ~= nil and pad.buttons.right_stick == true) } })
    -- A lock-on the mode graph refuses (pegs touching a rail inside a
    -- manual's airborne grace, say) is undone in grind_policy too, so the
    -- policy never stays locked under another mode and a later grind needs a
    -- fresh lock-on from the air.
    local grinding = grind.state == "locked" or grind.state == "stalled"
    local lock_on = false
    for _, e in ipairs(grind.events) do if e.name == "lock_on" then lock_on = true end end
    local grind_refusal
    if grinding and self.mode ~= "grinding" then
        local _, why = settle(self.mode, "grinding", t.any, lock_on)
        if why then
            grind_refusal = why
            self._grind:reset()
            grinding = false
        end
    end
    for _, e in ipairs(grind.events) do
        if grind_refusal and e.name == "lock_on" then
            table.insert(events, { name = "grind", event = { name = "lock_on_refused", reason = grind_refusal,
                grind = e.grind, side = e.side } })
        else
            table.insert(events, { name = "grind", event = e })
        end
    end
    if grind.bail_request then
        self._policy_bail = { source = "grind_policy", reason = grind.bail_request.reason, serial = t.serial }
    end
    local touching = 0
    if contacts then
        for _, row in pairs(contacts.pegs) do if row.touching and row.separation <= .005 then touching += 1 end end
    end
    diagnostics.grind = { state = grinding and grind.state or (grind_refusal and "refused" or grind.state),
        grind = grind.grind, side = grind.side, classified = grind.classified, refusal = grind.refusal,
        issue = grind.issue, exit_reason = grind.exit_reason, hop_request = grind.hop_request, refused = grind_refusal,
        balance = grind.balance, rail = grind.rail, assist = grinding and grind.assist_torque or nil,
        rows = rail_rows,
        touching_pegs = touching,
        -- forces.lua applies a hop only with wheel ground support, so a hop
        -- off a rail has no physical realisation in this composition.
        hop_unrealized = grind.hop_request == true }

    -- Mode. A lift enters its mode when the lifted wheel leaves support (or
    -- the balance is already balancing) and keeps it through
    -- manual_balance's airborne grace; it leaves when the balance itself
    -- ends. A read that does not know the ground takes no edge, except out
    -- of a grind grind_policy ended.
    local lift = balance.state == "entering" or balance.state == "balancing"
    local wanted
    if not t.ground_known then
        wanted = (self.mode == "grinding" and not grinding) and "airborne" or self.mode
    elseif grinding then
        wanted = "grinding"
    elseif lift and (self.mode == balance.kind or balance.state == "balancing"
        or not t.support[balance.kind == "manual" and 1 or 2]) then
        wanted = balance.kind
    elseif t.any then
        wanted = "rolling"
    else
        wanted = "airborne"
    end
    if self.mode == "none" and wanted ~= "none" and wanted ~= "rolling" and wanted ~= "airborne" then
        wanted = t.any and "rolling" or "airborne"
    end
    local mode, edge_refusal = settle(self.mode, wanted, t.any, lock_on)
    diagnostics.transition_refused = edge_refusal or grind_refusal
    if edge_refusal and lift and (wanted == "manual" or wanted == "nose_manual") then self._balance:cancel() end
    self:_transition(events, mode, reason_for(self.mode, mode, grind, balance, edge_refusal))
    -- A policy bail request that a supported landing outlived was not a bail:
    -- the rider rode away. The grind latch it left is cleared, since the bail
    -- owner (bail_policy, here) decided the rider is back.
    if self._policy_bail and t.any and not grinding then
        if self._grind:state().bail_latched then self._grind:reset() end
        bail.unrealized = self._policy_bail
        self._policy_bail = nil
    end
    bail.pending_request = self._policy_bail

    -- Forces. The kernel previews from its committed history, which only an
    -- accepted command advances. A read that does not follow the last
    -- accepted read previews from a reset kernel, as after a serial gap,
    -- except for the pedal latch.
    local fc
    if not active or self.mode == "grinding" or not t.qualified then
        -- Passive support only: gated input submits no rider control, and a
        -- grinding bike has no wheel on the ground to steer or pedal with.
        fc = { enabled = false }
    else
        fc = M.copy(controls.force_controls)
        if t.any or lift then fc.manual, fc.nose_manual = balance.manual, balance.nose_manual end
        fc.rotation_reserved = fc.rotation_reserved or self._trick_reserved == true
    end
    if not (self._kernel_serial and Identity.bounded_delta(t.serial, self._kernel_serial, 1) == 1) then
        -- The pedal latch follows speed alone (forces.lua pedal_cadence), so a
        -- withheld read or a late receipt keeps it: a gap in the commands is
        -- not a gap in the bike's speed, and clearing it here would let a
        -- held pedal start again inside the band. A recovery or a bail still
        -- clears it, through _reset_models and the bail reset.
        local latch = self._kernel.pedal_latch
        self._kernel:reset()
        self._kernel.pedal_latch = latch
        self._kernel_serial = nil
    end
    local kernel, candidate
    if t.qualified then
        kernel, candidate = self._kernel:preview(h, t.body, t.wheels, t.rows, fc)
    else
        kernel = { valid = false, issue = "wheel_query_unqualified" }
    end
    diagnostics.kernel = { valid = kernel.valid, issue = kernel.issue, grounded = kernel.grounded,
        hop_applied = kernel.hop_applied, steering_limited = kernel.steering_limited,
        front_steer_angle = kernel.front_steer_angle, normal_load = kernel.normal_load, enabled = fc.enabled ~= false,
        pedal = fc.pedal or 0, pedaling = kernel.valid == true and kernel.pedaling == true, brake = fc.brake or 0,
        manual = fc.manual or 0, nose_manual = fc.nose_manual or 0, committed_serial = self._kernel_serial,
        consumed_hop = self._kernel:consumed_hop_event_id() }

    -- The submit decision comes before anything is committed or retired. An
    -- unguarded read fails closed first: no force, torque or hop impulse
    -- leaves for a body bail_policy did not judge, and its hop is cancelled
    -- below rather than held, since nothing says the next read is guarded.
    local commands, withheld = { submit = false }, nil
    local outstanding = self._outstanding
    local force, torque
    if unguarded then
        withheld = unguarded
    elseif not kernel.valid then
        withheld = kernel.issue or "kernel_invalid"
    else
        force, torque = M.copy(kernel.force), M.copy(kernel.torque)
        local active_pegs, normal_impulse, contacts_ok = {}, 0, true
        if contacts then
            local f, tq
            f, tq, active_pegs, normal_impulse, contacts_ok = rail_contacts(t.body, kernel, contacts, t.rows, gravity, h)
            force, torque = M.add(force, f), M.add(torque, tq)
        end
        if self.mode == "grinding" and grind.assist_torque then torque = M.add(torque, grind.assist_torque) end
        diagnostics.rail_contacts = { active = active_pegs, normal_impulse = normal_impulse, valid = contacts_ok }
        if not contacts_ok then
            withheld = "rail_contact_invalid"
        elseif M.length(force) > self._force_cap or M.length(torque) > self._torque_cap
            or M.length(M.add(force, M.mul(kernel.hop_impulse, 1 / h))) > self._force_cap then
            -- forces.lua's own rule, on the summed command: the force, and
            -- the force plus the hop impulse spread over the step.
            withheld = "output_limit"
        elseif outstanding then
            -- One command waits for its receipt at a time, as in ride_runtime.lua.
            withheld = "receipt_pending"
        end
    end
    local hop = controls.hop
    if not withheld then
        commands = { submit = true, serial = t.serial, force = force, torque = torque,
            hop_impulse = M.copy(kernel.hop_impulse), hop_event_id = kernel.hop_applied and kernel.hop_event_id or 0,
            wheels = { M.copy(kernel.wheels[1]), M.copy(kernel.wheels[2]) } }
        self._outstanding = { serial = t.serial, candidate = candidate, adoptable = true,
            hop_id = hop and hop.id or nil, hop_applied = kernel.hop_applied == true,
            residual = { serial = t.serial, velocity = M.copy(t.body.linear_velocity), force = M.copy(force),
                hop_impulse = M.copy(kernel.hop_impulse) } }
        self._steer = kernel.front_steer_angle
        self._last_command = nil
        diagnostics.hop = hop and "submitted" or "none"
    else
        diagnostics.kernel.issue = withheld
        diagnostics.hop = "none"
        if hop then
            if outstanding and outstanding.hop_id == hop.id then
                -- The waiting command owns this hop; its receipt retires it.
                diagnostics.hop = "owned_by_outstanding"
            elseif withheld == "receipt_pending" and self._source
                and Identity.bounded_delta(self._source.observed_ms, hop.observed_ms, Composer.hop_hold_ms) ~= nil then
                diagnostics.hop = "held"
            else
                -- Nothing was sent for it: cancelled, never accepted.
                self._mapping:retire_hop(hop.id, "cancelled")
                diagnostics.hop = "cancelled"
            end
        end
        -- The body got no command from this read, unless the waiting one
        -- lands on it, which only its receipt can say.
        self._last_command = (not outstanding) and { serial = t.serial, velocity = M.copy(t.body.linear_velocity),
            force = zero(), hop_impulse = zero() } or nil
    end

    -- Tricks and the bike's part matrices. The base articulation is this
    -- read's steer and wheel phases and last read's presented crank, because
    -- the rider cue that presents the crank reads this read's trick targets.
    for i = 1, 2 do self._wheel_phase[i] = wrap(self._wheel_phase[i] + t.wheels[i].angular_speed * h) end
    -- The kernel's own pedaling decision (forces.lua pedal_cadence), so the
    -- drawn crank turns only on a read whose preview pedals. At the top
    -- pedaling speed with the pedal held it stops, and rider_presentation
    -- levels it as for a released pedal.
    local pedaling = kernel.valid == true and kernel.pedaling == true
    if pedaling then self._raw_crank = wrap(self._raw_crank + t.wheels[2].angular_speed * h / self._crank_ratio) end
    local support, support_issue = support_packet(tick.support)
    diagnostics.support.owner = support_issue
    if support.known then diagnostics.support.owner_grounded = support.grounded end
    local bike, trick = { valid = false, issue = "input_inactive" }, nil
    if active and self._source and t.qualified then
        local source = self._source
        local frame = read_frame(t, source)
        local scalar = {}
        for _, name in ipairs(scalar_source) do scalar[name] = source[name] end
        local q = t.query
        local packet = { valid = true, binding = { body_handle = t.body_handle, physics_epoch = t.epoch,
            lease_handle = source.lease_handle }, frame = { serial = t.serial, time = t.time, seconds = h, source = scalar },
            query = { epoch_matches = q.epoch_matches, accounting_known = q.accounting_known == true,
                budget_exhausted = q.budget_exhausted, local_actor_excluded = q.local_actor_excluded,
                owned_bodies_excluded = q.owned_bodies_excluded },
            support = support }
        local base = { physics_epoch = t.epoch, steer = self._steer, front_wheel_phase = self._wheel_phase[1],
            rear_wheel_phase = self._wheel_phase[2], crank_phase = self._crank_display }
        -- One trick model, stepped once per read. trick_presentation's own
        -- stage would also build the part matrices twice on every step;
        -- here they are built only when asked for (Ride:matrices or the
        -- matrices option), through the stage's present() for a result
        -- this composer already stepped.
        local stepped = self._tricks:step(frame, packet, actions)
        if stepped.valid and stepped.visual_targets then
            trick = stepped
            local v = stepped.visual_targets
            local pose = { steer = base.steer, front_wheel_phase = base.front_wheel_phase,
                rear_wheel_phase = base.rear_wheel_phase, crank_phase = base.crank_phase + v.movement_crank_angle,
                barspin = v.barspin, tailwhip = v.tailwhip, movement_bike_pitch = v.movement_bike_pitch,
                movement_bike_roll = v.movement_bike_roll }
            self._presentable = { frame = frame, trick = stepped, base = base }
            if self._with_matrices then
                local placed = Stage.present(frame, stepped, base)
                bike = placed.valid and trimmed_bike(placed) or { valid = false, issue = placed.issue }
            else
                bike = { valid = true, fresh = true, issue = stepped.issue, serial = t.serial, pose = pose }
            end
        else
            self._presentable = nil
            bike = { valid = false, fresh = stepped.fresh == true, issue = stepped.issue }
        end
    else
        self._presentable = nil
    end
    self._trick_reserved = trick ~= nil and trick.requests ~= nil and trick.requests.rotation_reserved == true
    local trick_events = trick and trick.model_events or nil
    if trick_events then
        for _, name in ipairs({ "took_off", "landed", "combo_landed", "failed", "canceled", "bar_caught", "tail_caught",
            "movement_caught" }) do
            if trick_events[name] then
                table.insert(events, { name = "trick", event = name, barspins = trick_events.barspins,
                    tailwhips = trick_events.tailwhips, units = trick_events.units, failure = trick_events.failure })
            end
        end
    end
    local targets = trick and trick.visual_targets or nil
    diagnostics.trick = { valid = bike.valid, issue = bike.issue, reserved = self._trick_reserved,
        state = trick and trick.model_state or nil, events = trick_events, targets = targets }

    -- Rider cues. A read that does not know the ground steps no cue: the
    -- landing evidence and posture would otherwise read it as air.
    local rider = { valid = false, issue = "input_inactive" }
    if not t.ground_known then
        rider = { valid = false, issue = "support_unknown" }
    else
        local evidence = self:_evidence(t)
        if self._source then
            local stepped = self._rider:step({ identity = { body_handle = t.body_handle, lease_handle = self._source.lease_handle },
                serial = t.serial, time = t.time, seconds = h, raw_crank_phase = self._raw_crank, enabled = active,
                pedaling = pedaling, reserved = self._trick_reserved, airborne = self.mode == "airborne",
                supported = t.any, evidence = evidence,
                wheels = { supported = { t.support[1], t.support[2] }, normal_available = { t.hit[1], t.hit[2] },
                    normal = { t.normals[1] or { 0, 1, 0 }, t.normals[2] or { 0, 1, 0 } } },
                forward = t.forward, orientation = t.body.orientation,
                release = targets and { left_arm = targets.release_left_hand, right_arm = targets.release_right_hand,
                    left_leg = targets.release_left_foot, right_leg = targets.release_right_foot } or nil,
                movement_phase = targets and targets.phase or 0, preload = actions and actions.preload or 0 })
            if stepped.valid and stepped.articulation then self._crank_display = stepped.articulation.crank_phase end
            rider = rider_public(stepped)
        end
    end
    diagnostics.landing = self._last_landing

    -- Camera: the plan's ray was cast by the caller between plan and step.
    local camera, camera_issue = nil, p.camera_issue
    if p.camera then camera, camera_issue = self._camera:resolve(tick.camera_hit) end
    diagnostics.camera = camera_issue or "none"
    diagnostics.edge_refused = self._edge_refused

    return { valid = true, issue = "none", serial = t.serial, mode = self.mode, events = events, commands = commands,
        presentation = { bike = bike, rider = rider,
            meters = { manual = lift and balance.balance or nil,
                grind = grinding and grind.balance and grind.balance.normalized or nil } },
        camera = camera, diagnostics = diagnostics }
end

-- The eight part matrices for the last step's trick pose, placed at that
-- read's measured pose (trick_presentation.present). For the bike's visual
-- owner, once per placed frame; nil and why when the last step had no pose.
function Ride:matrices()
    local p = self._presentable
    if not p then return nil, "no_trick_pose" end
    local out = Stage.present(p.frame, p.trick, p.base)
    if not out.valid then return nil, out.issue end
    return trimmed_bike(out)
end

-- A detached diagnostic snapshot. Opaque handles are left out.
function Ride:status()
    return scrub({ mode = self.mode, serial = self._serial, ticks = self._ticks, balance = self._balance:status(),
        grind = self._grind:state(), bail = self._bail:status(), input = self._mapping:status(),
        trick = self._tricks:status(), camera = self._camera:status(), guard_pressure = self._guard_pressure == true,
        batch_allowance = self._batches,
        outstanding = self._outstanding and self._outstanding.serial or nil, kernel_serial = self._kernel_serial,
        kernel_consumed_hop = self._kernel:consumed_hop_event_id(), last_receipt = self._last_receipt,
        recovery_pending = self._recovery_pending == true }, 0)
end

return table.freeze(Composer)

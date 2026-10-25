-- Authored grind, peg-stall and tire-stall policy. Observed contact rows enter;
-- only requests leave: a grind type, transition events, a bail request, a
-- hop-out request and an optional bounded alignment torque. It never sets a
-- pose, position or velocity and never searches for a rail: the rail probe
-- owns every query and row. Grind names are new identifiers, not catalog IDs,
-- and every threshold is our own authored tuning. GRINDS.md has the geometry.
local M = require("./force_math")
local Pegs = require("./peg_geometry")
local Grind, Controller = {}, {}
Controller.__index = Controller
Grind.none = "none"
Grind.types = { "double_peg", "feeble", "smith", "icepick", "toothpick", "peg_stall", "tire_stall" }
local peg_names = Pegs.names()
local tire_names = { "front", "rear" }
-- forces.lua's default gravity is {0,-9.8,0}; balance is judged against it.
local world_up = { 0, 1, 0 }
-- Timers compare with this slack so whole native steps land on the authored
-- boundary instead of one step late through float rounding.
local epsilon = 1e-6
local moving = { double_peg = true, feeble = true, smith = true, icepick = true, toothpick = true }
local peg_info = {}
for _, name in ipairs(peg_names) do
    local peg = Pegs.peg(name)
    peg_info[name] = { side = peg.side, axle = peg.axle }
end
local defaults = {
    approach_yaw_limit = .70, max_closing_speed = 6, max_opening_speed = .5,
    peg_edge_tolerance = .025, peg_radial_tolerance = .03, contact_gap = .005, max_penetration = .03,
    rail_tangent_tolerance = .35, max_rail_incline = 1, admission_seconds = .1,
    feeble_min_yaw = .2, smith_min_yaw = .2, icepick_min_pitch = .6, toothpick_min_pitch = .6,
    stall_speed = .6, stall_seconds = .75, rail_end_seconds = .05, type_settle_seconds = .1,
    lean_authority = .35, fail_angle = .45, fail_seconds = .25, hard_fail_angle = .9,
    max_unavailable_seconds = .1, max_sample_seconds = .1, assist_yaw_deadband = .08,
    assist_yaw_stiffness = 60, assist_yaw_damping = 8, assist_roll_stiffness = 40,
    assist_roll_damping = 6, assist_torque_limit = 120,
}
local bounds = {
    approach_yaw_limit = { .05, 1.2 }, max_closing_speed = { .5, 20 }, max_opening_speed = { 0, 5 },
    peg_edge_tolerance = { 0, .1 }, peg_radial_tolerance = { .005, .1 }, contact_gap = { 0, .05 },
    max_penetration = { 0, .1 }, rail_tangent_tolerance = { .02, .8 }, max_rail_incline = { .1, 1.4 },
    admission_seconds = { 0, .5 }, feeble_min_yaw = { .02, 1 }, smith_min_yaw = { .02, 1 },
    icepick_min_pitch = { .2, 1.5 }, toothpick_min_pitch = { .2, 1.5 }, stall_speed = { .05, 3 },
    stall_seconds = { .05, 5 }, rail_end_seconds = { 0, .5 }, type_settle_seconds = { 0, .5 },
    lean_authority = { 0, .8 }, fail_angle = { .1, 1.2 }, fail_seconds = { 0, 2 },
    hard_fail_angle = { .1, 1.5 }, max_unavailable_seconds = { 0, 1 }, max_sample_seconds = { .001, .25 },
    assist_yaw_deadband = { 0, .5 }, assist_yaw_stiffness = { 0, 1000 }, assist_yaw_damping = { 0, 200 },
    assist_roll_stiffness = { 0, 1000 }, assist_roll_damping = { 0, 200 }, assist_torque_limit = { 0, 400 },
}
local finite = M.finite
local function sanitize(source)
    source = type(source) == "table" and source or {}
    local out = {}
    for name, fallback in pairs(defaults) do
        local value = source[name]
        out[name] = math.clamp(finite(value) and value or fallback, bounds[name][1], bounds[name][2])
    end
    -- Keep the authored windows reachable whatever the overrides say.
    out.hard_fail_angle = math.max(out.hard_fail_angle, out.fail_angle)
    out.feeble_min_yaw = math.min(out.feeble_min_yaw, out.approach_yaw_limit)
    out.smith_min_yaw = math.min(out.smith_min_yaw, out.approach_yaw_limit)
    -- The assist is a torque request, so it stays off unless asked for.
    out.assist_enabled = source.assist_enabled == true
    return out
end
function Grind.settings(source) return sanitize(source) end

-- Inert by default, like Tricks.input: a missing input never rides a rail.
-- lean is -1..1 with +1 leaning right (the ride stick's +X); hop is the held
-- hop request from the ride input, not a native receipt.
function Grind.input(source)
    local out = { enabled = false, lean = 0, hop = false }
    if type(source) == "table" then
        for key in pairs(out) do if source[key] ~= nil then out[key] = source[key] end end
    end
    return out
end

-- One row of the shape the rail probe produces (and grind.cpp consumes):
-- {available, touching, point, normal, tangent, separation, surface_velocity,
-- friction}. Unavailable is never clear. A clear row needs no geometry and
-- any geometry it carries is not read, so garbage there changes nothing.
function Grind.contact(raw)
    if type(raw) ~= "table" or raw.available == false then return nil, "unavailable_contact" end
    if raw.available ~= true or type(raw.touching) ~= "boolean" then return nil, "invalid_contact" end
    if not raw.touching then return { available = true, touching = false } end
    -- The same validity checks as solve_grind in standalone grind.cpp.
    if not M.vec(raw.point, 1e6) or not M.vec(raw.surface_velocity, 1e5) or not finite(raw.separation)
        or not finite(raw.friction) or raw.friction < 0 or raw.friction > 10 then return nil, "invalid_contact" end
    local normal, tangent = M.unit(raw.normal), M.unit(raw.tangent)
    if not normal or not tangent or math.abs(M.dot(normal, tangent)) > 1e-3 then return nil, "invalid_contact" end
    return { available = true, touching = true, point = M.copy(raw.point), normal = normal, tangent = tangent,
        separation = raw.separation, surface_velocity = M.copy(raw.surface_velocity), friction = raw.friction }
end
-- Every one of the six rows must be available. A missing or unavailable row
-- could hide a contact that changes the grind, so it is not read as clear.
local function rows_copy(contacts)
    if type(contacts) ~= "table" or type(contacts.pegs) ~= "table" or type(contacts.tires) ~= "table" then
        return nil, "unavailable_contact"
    end
    local out = { pegs = {}, tires = {} }
    for _, name in ipairs(peg_names) do
        local row, issue = Grind.contact(contacts.pegs[name])
        if not row then return nil, issue end
        out.pegs[name] = row
    end
    for _, name in ipairs(tire_names) do
        local row, issue = Grind.contact(contacts.tires[name])
        if not row then return nil, issue end
        out.tires[name] = row
    end
    return out
end
local function body_copy(raw)
    if type(raw) ~= "table" or type(raw.orientation) ~= "table" then return nil end
    local norm = 0
    for i = 1, 4 do
        local value = raw.orientation[i]
        if not finite(value) then return nil end
        norm += value * value
    end
    if math.abs(norm - 1) > .001 or not M.vec(raw.center_of_mass, 1e6) or not M.vec(raw.linear_velocity, 100)
        or not M.vec(raw.angular_velocity, 100) then return nil end
    return { orientation = M.normalized(raw.orientation), center_of_mass = M.copy(raw.center_of_mass),
        linear_velocity = M.copy(raw.linear_velocity), angular_velocity = M.copy(raw.angular_velocity) }
end
local function in_contact(t, row) return row.touching and row.separation <= t.contact_gap end

-- One step's geometry. `use` names the rows that describe the rail: "any"
-- (pegs when a peg touches, otherwise tires), "pegs" or "tires". With `strict`
-- (admission) a peg row that is off its peg or a row on another rail refuses
-- the step; while locked such rows are left out, and so are pegs on the far
-- side from `side`, because a row that is not on this peg is not its contact.
-- A row deeper than max_penetration is malformed wherever it is, so it holds
-- the step even when it is one of the rows that would be left out.
local function view(t, body, rows, use, strict, side)
    local q = body.orientation
    local v = { forward = M.turn(q, { 0, 0, 1 }), up = M.turn(q, { 0, 1, 0 }), pegs = {}, tires = {},
        touching = false, front_tire = false, rear_tire = false, side = "none", mixed = false,
        issue = "none", refusal = "none", closing = -math.huge }
    for _, group in ipairs({ { peg_names, rows.pegs }, { tire_names, rows.tires } }) do
        for _, name in ipairs(group[1]) do
            local row = group[2][name]
            if row.touching and row.separation < -t.max_penetration then v.issue = "invalid_contact"; return v end
            if in_contact(t, row) then
                v.touching = true
                -- The admission bound reads every row in contact, before any is
                -- refused or left out, so a slam on a step refused for another
                -- reason (an off-peg row, say) is still on record.
                local relative = M.sub(M.point_velocity(body, row.point), row.surface_velocity)
                v.closing = math.max(v.closing, -M.dot(relative, row.normal))
            end
        end
    end
    local primary = nil
    local function aligned(row)
        if not primary then
            primary = M.dot(row.tangent, v.forward) < 0 and M.mul(row.tangent, -1) or row.tangent
            return true
        end
        if math.abs(M.dot(row.tangent, primary)) >= math.cos(t.rail_tangent_tolerance) then return true end
        if strict then v.refusal = "rail_mismatch" end
        return false
    end
    for _, name in ipairs(peg_names) do
        local row, info = rows.pegs[name], peg_info[name]
        if in_contact(t, row) and (side == nil or info.side == side) and use ~= "tires" then
            local relation = Pegs.relation(name, Pegs.to_local(body, row.point))
            local refusal = math.abs(relation.surface_offset) > t.peg_radial_tolerance and "peg_radial_offset"
                or relation.edge_offset > t.peg_edge_tolerance and "peg_edge_offset" or nil
            if refusal and strict then v.refusal = refusal; return v end
            if not refusal then
                if not aligned(row) then
                    if strict then return v end
                else
                    table.insert(v.pegs, { name = name, side = info.side, axle = info.axle, row = row, relation = relation })
                end
            end
        end
    end
    for _, name in ipairs(tire_names) do
        if in_contact(t, rows.tires[name]) then
            v[name .. "_tire"] = true
            table.insert(v.tires, { name = name, row = rows.tires[name] })
        end
    end
    for _, peg in ipairs(v.pegs) do
        if v.side == "none" then v.side = peg.side elseif v.side ~= peg.side then v.mixed = true end
    end
    local rail = v.pegs
    if use == "tires" or (use == "any" and #v.pegs == 0) then
        rail = {}
        for _, tire in ipairs(v.tires) do
            if aligned(tire.row) then table.insert(rail, tire) elseif strict then return v end
        end
    end
    v.peg_count, v.tire_count = #v.pegs, #v.tires
    if #rail == 0 then return v end
    local sum, point, surface, closing = { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, -math.huge
    for _, entry in ipairs(rail) do
        local row = entry.row
        sum = M.add(sum, M.dot(row.tangent, primary) < 0 and M.mul(row.tangent, -1) or row.tangent)
        point, surface = M.add(point, row.point), M.add(surface, row.surface_velocity)
        local relative = M.sub(M.point_velocity(body, row.point), row.surface_velocity)
        closing = math.max(closing, -M.dot(relative, row.normal))
    end
    local tangent = M.unit(sum)
    if not tangent then v.issue = "invalid_contact"; return v end
    if M.dot(tangent, v.forward) < 0 then tangent = M.mul(tangent, -1) end
    -- A vertical rail has no lateral frame against gravity to balance on.
    local horizontal = M.sub(world_up, M.mul(tangent, M.dot(world_up, tangent)))
    if M.length(horizontal) < 1e-3 then v.issue = "invalid_contact"; return v end
    local up = M.mul(horizontal, 1 / M.length(horizontal))
    local lateral = M.cross(up, tangent)
    point, surface = M.mul(point, 1 / #rail), M.mul(surface, 1 / #rail)
    local relative = M.sub(M.point_velocity(body, point), surface)
    local along, across = M.dot(v.forward, tangent), M.dot(v.forward, lateral)
    local offset = M.sub(body.center_of_mass, point)
    v.rail = {
        kind = rail == v.pegs and "pegs" or "tires", point = point, tangent = tangent, up = up, lateral = lateral,
        speed = M.dot(relative, tangent), closing = closing,
        incline = math.asin(math.clamp(math.abs(M.dot(tangent, world_up)), 0, 1)),
        -- Heading in the rail's plane, + toward the rail's left; pitch, + nose
        -- up from the rail; roll and tilt, + toward the rail's right. Tilt is
        -- the measured contact-to-COM line, so measured roll enters through it.
        yaw = (math.abs(along) + math.abs(across) > 1e-9) and math.atan2(across, along) or 0,
        pitch = math.asin(math.clamp(M.dot(v.forward, up), -1, 1)),
        roll = math.atan2(-M.dot(v.up, lateral), M.dot(v.up, up)),
        tilt = math.atan2(-M.dot(offset, lateral), M.dot(offset, up)),
    }
    return v
end

-- Contact sets plus pitch and yaw decide the type. Returns grind, side and,
-- for "none", why. A slow peg set is a stall whatever its shape.
local function classify(t, v)
    if v.peg_count > 0 then
        if v.mixed then return "none", "none", "mixed_peg_sides" end
        if math.abs(v.rail.speed) < t.stall_speed then return "peg_stall", v.side, "none" end
        local front, rear = false, false
        for _, peg in ipairs(v.pegs) do if peg.axle == "front" then front = true else rear = true end end
        -- Positive when the front of the bike swings over the rail, away from
        -- the side the bike approached on.
        local toward = v.rail.yaw * Pegs.side_sign(v.side)
        if front and rear then return "double_peg", v.side, "none" end
        if rear then
            if v.rail.pitch >= t.icepick_min_pitch and not v.front_tire then return "icepick", v.side, "none" end
            if -toward >= t.smith_min_yaw then return "smith", v.side, "none" end
            if toward >= t.feeble_min_yaw or v.front_tire then return "feeble", v.side, "none" end
        elseif -v.rail.pitch >= t.toothpick_min_pitch and not v.rear_tire then
            return "toothpick", v.side, "none"
        end
        return "none", v.side, "unclassified"
    end
    if v.tire_count > 0 then
        if math.abs(v.rail.speed) < t.stall_speed then return "tire_stall", "none", "none" end
        return "none", "none", "unclassified"
    end
    return "none", "none", "none"
end
-- Admission checks in their reporting order. `closing` is the worst closing
-- speed of any row in contact since the first contact, refused steps
-- included, so a slam cannot be hidden by waiting or by an off-peg row.
-- `separating` reads only this step's rail rows: one of them still pressing
-- in means the bike is not leaving the rail.
local function admission(t, v, closing, grind, why)
    if v.refusal ~= "none" then return v.refusal end
    if v.mixed then return "mixed_peg_sides" end
    if v.rail.incline > t.max_rail_incline then return "rail_incline" end
    if v.rail.closing < -t.max_opening_speed then return "separating" end
    if closing > t.max_closing_speed then return "closing_speed" end
    -- A tire stall on coping is often square to the edge, so only peg
    -- lock-ons are limited by approach yaw.
    if v.peg_count > 0 and math.abs(v.rail.yaw) > t.approach_yaw_limit then return "approach_yaw" end
    if grind == "none" then return why ~= "none" and why or "unclassified" end
    return nil
end
local function diagnostics(v)
    local r = v.rail
    return { kind = r.kind, speed = r.speed, closing = r.closing, incline = r.incline, yaw = r.yaw, pitch = r.pitch,
        roll = r.roll, tilt = r.tilt, point = M.copy(r.point), tangent = M.copy(r.tangent), up = M.copy(r.up) }
end

-- Stateless classification of one observation, without the airborne history,
-- admission window or bail latch that the controller adds.
function Grind.evaluate(observation, settings)
    local t = sanitize(settings)
    local out = { grind = "none", side = "none", refusal = "none", issue = "none" }
    local o = type(observation) == "table" and observation or {}
    local body = body_copy(o.body)
    if not body then out.issue = "invalid_body"; return out end
    local rows, issue = rows_copy(o.contacts)
    if not rows then out.issue = issue; return out end
    local v = view(t, body, rows, "any", true)
    if v.issue ~= "none" then out.issue = v.issue; return out end
    if not v.touching then return out end
    if o.ground_support == true then out.refusal = "ground_supported"; return out end
    if v.refusal ~= "none" then out.refusal = v.refusal; return out end
    if not v.rail then out.refusal = "unclassified"; return out end
    local grind, side, why = classify(t, v)
    out.rail = diagnostics(v)
    local refusal = admission(t, v, v.closing, grind, why)
    if refusal then out.refusal = refusal; return out end
    out.grind, out.side = grind, side
    return out
end

function Grind.new(settings)
    local out = setmetatable({ _settings = sanitize(settings) }, Controller)
    out:reset()
    return out
end
function Controller:settings() return M.copy(self._settings) end
function Controller:_clear()
    self._phase, self._grind, self._side = "idle", "none", "none"
    self._airborne, self._window, self._window_closing = false, nil, -math.huge
    self._hop_rearmed, self._lost, self._failing, self._unavailable, self._stall_elapsed = false, 0, 0, 0, 0
    self._pending, self._pending_elapsed = "none", 0
end
-- reset is the only way to clear a bail latch: the bail owner decides when the
-- rider is back, not the next rail the tumbling bike touches.
function Controller:reset() self:_clear(); self._bail_latched = false end
function Controller:state()
    return { phase = self._phase, grind = self._grind, side = self._side, airborne_seen = self._airborne,
        admission_seconds = self._window or 0, bail_latched = self._bail_latched, hop_rearmed = self._hop_rearmed,
        contact_lost_seconds = self._lost, balance_failing_seconds = self._failing,
        unavailable_seconds = self._unavailable, stall_seconds = self._stall_elapsed,
        pending_grind = self._pending, pending_seconds = self._pending_elapsed }
end
function Controller:_result()
    return { valid = true, state = self._phase, grind = self._grind, side = self._side, classified = "none",
        refusal = "none", issue = "none", exit_reason = "none", events = {}, hop_request = false,
        assist_limited = false }
end
function Controller:_exit(out, reason)
    table.insert(out.events, { name = "exit", reason = reason, grind = self._grind, side = self._side })
    out.state, out.exit_reason, out.grind, out.side = "ended", reason, self._grind, self._side
    out.assist_torque = nil
    self:_clear()
    return out
end
-- An unusable sample cancels: elapsed time and the measured body are unknown.
function Controller:_cancel(out, issue, reason)
    out.valid, out.issue = false, issue
    if self._phase ~= "idle" then return self:_exit(out, reason) end
    self:_clear()
    return out
end
-- Unavailable or malformed rows hold the grind without reading them as clear.
-- While locked they only count toward a cancel; while idle they disarm, since
-- an unavailable sample cannot prove the bike was airborne.
function Controller:_hold(out, h, issue)
    out.issue = issue
    if self._phase == "idle" then self._airborne, self._window = false, nil; return out end
    self._unavailable += h
    if self._unavailable >= self._settings.max_unavailable_seconds - epsilon then
        return self:_exit(out, "contact_unavailable")
    end
    return out
end
function Controller:_balance(out, v, lean)
    local t = self._settings
    local effective = v.rail.tilt + lean * t.lean_authority
    out.balance = { tilt = v.rail.tilt, roll = v.rail.roll, lean = lean, effective = effective,
        normalized = math.clamp(effective / t.fail_angle, -1, 1), failing_seconds = self._failing }
    return effective
end
local function yaw_window(t, grind, side)
    local sign = Pegs.side_sign(side)
    if grind == "double_peg" or grind == "icepick" or grind == "toothpick" then
        return -t.assist_yaw_deadband, t.assist_yaw_deadband
    elseif grind == "feeble" or grind == "smith" then
        local low, high = grind == "feeble" and t.feeble_min_yaw or -t.approach_yaw_limit,
            grind == "feeble" and t.approach_yaw_limit or -t.smith_min_yaw
        if sign > 0 then return low, high end
        return -high, -low
    end
    -- Stalls get no yaw assist: a stall may sit at any admitted heading.
    return nil
end
-- A bounded PD torque request about the rail's up axis (only outside the
-- grind's yaw window) and about the rail tangent (toward the rider's lean
-- target). It is a request for the force owner to add, never a pose write.
function Controller:_assist(out, v, body, effective)
    local t = self._settings
    if not t.assist_enabled then return end
    local omega, rail = body.angular_velocity, v.rail
    local yaw_torque, low, high = 0, yaw_window(t, self._grind, self._side)
    if low then
        local drift = rail.yaw - math.clamp(rail.yaw, low, high)
        if drift ~= 0 then yaw_torque = -(t.assist_yaw_stiffness * drift + t.assist_yaw_damping * M.dot(omega, rail.up)) end
    end
    local roll_torque = -(t.assist_roll_stiffness * effective + t.assist_roll_damping * M.dot(omega, rail.tangent))
    local torque = M.add(M.mul(rail.up, yaw_torque), M.mul(rail.tangent, roll_torque))
    out.assist_limited = M.length(torque) > t.assist_torque_limit
    out.assist_torque = M.limited(torque, t.assist_torque_limit)
end
function Controller:_idle(out, h, body, rows, ground, input, lean)
    local t = self._settings
    local v = view(t, body, rows, "any", true)
    if v.issue ~= "none" then return self:_hold(out, h, v.issue) end
    if ground then
        self._airborne, self._window = false, nil
        if v.touching then out.refusal = "ground_supported" end
        return out
    end
    if not v.touching then self._airborne, self._window = true, nil; return out end
    if self._bail_latched then out.refusal = "bail_latched"; return out end
    if not self._airborne then out.refusal = "not_from_air"; return out end
    -- Pegs rarely land on the same step, so admission stays open briefly after
    -- the first contact instead of demanding the final set immediately.
    if self._window == nil then self._window, self._window_closing = 0, -math.huge else self._window += h end
    if self._window > t.admission_seconds + epsilon then
        self._airborne, self._window = false, nil
        out.refusal = "admission_window"
        return out
    end
    -- Recorded before any refusal return, so every touching step in the
    -- window counts toward the closing bound.
    self._window_closing = math.max(self._window_closing, v.closing)
    if v.refusal ~= "none" then out.refusal = v.refusal; return out end
    if not v.rail then out.refusal = "unclassified"; return out end
    out.rail = diagnostics(v)
    local grind, side, why = classify(t, v)
    out.classified = grind
    local refusal = admission(t, v, self._window_closing, grind, why)
    if refusal then out.refusal = refusal; return out end
    self:_clear()
    self._phase = (grind == "peg_stall" or grind == "tire_stall") and "stalled" or "locked"
    self._grind, self._side, self._hop_rearmed = grind, side, not input.hop
    out.state, out.grind, out.side = self._phase, grind, side
    table.insert(out.events, { name = "lock_on", grind = grind, side = side, state = self._phase })
    -- Balance is reported from the first step but only judged from the next.
    self:_assist(out, v, body, self:_balance(out, v, lean))
    return out
end
function Controller:_active(out, h, body, rows, ground, input, lean)
    local t = self._settings
    local v = view(t, body, rows, self._grind == "tire_stall" and "tires" or "pegs", false,
        self._grind ~= "tire_stall" and self._side or nil)
    if v.issue ~= "none" then return self:_hold(out, h, v.issue) end
    self._unavailable = 0
    if ground then return self:_exit(out, "grounded") end
    -- Hop-out needs the hop released once since lock-on, so the hop that
    -- carried the bike onto the rail cannot pop it straight off again.
    if input.hop then
        if self._hop_rearmed then out.hop_request = true; return self:_exit(out, "hop_out") end
    else
        self._hop_rearmed = true
    end
    if not v.rail then
        self._lost += h
        if self._lost >= t.rail_end_seconds - epsilon then return self:_exit(out, "rail_end") end
        return out
    end
    self._lost = 0
    out.rail = diagnostics(v)
    local effective = self:_balance(out, v, lean)
    if math.abs(effective) > t.fail_angle then self._failing += h else self._failing = 0 end
    out.balance.failing_seconds = self._failing
    if math.abs(effective) > t.hard_fail_angle or (self._failing > 0 and self._failing >= t.fail_seconds - epsilon) then
        self._bail_latched = true
        out.bail_request = { reason = "balance_lost", side = effective > 0 and "right" or "left", grind = self._grind }
        return self:_exit(out, "bail")
    end
    local grind, side = classify(t, v)
    out.classified = grind
    if self._phase == "stalled" then
        self._stall_elapsed += h
        if self._stall_elapsed >= t.stall_seconds - epsilon then return self:_exit(out, "stall_end") end
    elseif math.abs(v.rail.speed) < t.stall_speed then
        -- Too slow to keep grinding: stall in place, then exit after the hold.
        table.insert(out.events, { name = "stalled", from = self._grind, grind = "peg_stall", side = self._side })
        self._phase, self._grind, self._stall_elapsed = "stalled", "peg_stall", 0
        self._pending, self._pending_elapsed = "none", 0
    elseif moving[grind] and grind ~= self._grind and side == self._side then
        if self._pending == grind then self._pending_elapsed += h else self._pending, self._pending_elapsed = grind, 0 end
        if self._pending_elapsed >= t.type_settle_seconds - epsilon then
            table.insert(out.events, { name = "grind_changed", from = self._grind, to = grind, side = side })
            self._grind, self._pending, self._pending_elapsed = grind, "none", 0
        end
    else
        self._pending, self._pending_elapsed = "none", 0
    end
    out.state, out.grind, out.side = self._phase, self._grind, self._side
    self:_assist(out, v, body, effective)
    return out
end
-- observation = {seconds, body={orientation, center_of_mass, linear_velocity,
-- angular_velocity}, ground_support, contacts={pegs={front_left, front_right,
-- rear_left, rear_right}, tires={front, rear}}, input={enabled, lean, hop}}.
-- Inputs are copied and never modified.
function Controller:step(observation)
    local t = self._settings
    local out = self:_result()
    local o = type(observation) == "table" and observation or {}
    local input = Grind.input(o.input)
    if type(input.enabled) ~= "boolean" or not finite(input.lean) or type(input.hop) ~= "boolean" then
        return self:_cancel(out, "invalid_input", "invalid_sample")
    end
    -- A disabled step needs no measurement at all.
    if not input.enabled then return self:_cancel(out, "disabled", "cancelled") end
    if type(o.ground_support) ~= "boolean" then return self:_cancel(out, "invalid_input", "invalid_sample") end
    local h = o.seconds
    if not finite(h) or h <= 0 or h > t.max_sample_seconds then return self:_cancel(out, "invalid_step", "invalid_sample") end
    local body = body_copy(o.body)
    if not body then return self:_cancel(out, "invalid_body", "invalid_sample") end
    local rows, issue = rows_copy(o.contacts)
    if not rows then return self:_hold(out, h, issue) end
    local lean = math.clamp(input.lean, -1, 1)
    if self._phase == "idle" then return self:_idle(out, h, body, rows, o.ground_support, input, lean) end
    return self:_active(out, h, body, rows, o.ground_support, input, lean)
end
return Grind

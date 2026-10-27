-- Offline end-to-end cases for ride_composer.lua. Nothing runs on require;
-- run() is called by a Luau runner. The world here is constructed test
-- tooling: level ground at y = 0 and authored round rails, cast analytically
-- into probe_batch-shaped rows, with sim_world.lua's rigid-body integrator
-- standing in for native physics. Every number is a model metric of today's
-- modules in that world. None of it is gameplay, native or likeness evidence.
local Composer = require("./ride_composer")
local Core = require("./bike_runtime_core")
local World = require("./sim_world")
local Forces = require("./forces")
local M = require("./force_math")
local Pegs = require("./peg_geometry")
local Camera = require("./camera_policy")
local Presets = require("./input_presets")
local Probe = require("./rail_probe")
local Contact = require("./contact_runtime")
local Guard = require("./bail_guard")
local Geometry = require("./bike_geometry")
local Rider = require("./rider_presentation")
local Tests = {}
local H = Forces.native_seconds
local GRAVITY = Forces.tuning().gravity
local R = World.wheel_radius
local clock = os and os.clock
-- The constructed caller casts each lane (wheels, rail, guard, witnesses)
-- as its own probe_batch, so the offline scenarios run with four batches
-- per read. That is now Core's default too. Explicit lower allowances keep
-- their fail-closed counterexamples; they do not model Core's default.
local LAB_BATCHES = 4

------------------------------------------------------------------------------
-- The constructed world.

-- First front-facing hit on [from, to] against the ground plane and each rail
-- (a cylinder along +Z with flat end caps). Returns {fraction, point, normal}
-- or nil. A ray that starts inside a surface does not see it, as a native
-- raycast would not see a back face.
local function cast(world, from, to)
    local d = M.sub(to, from)
    local best
    if from[2] >= 0 and to[2] < 0 then
        local f = from[2] / (from[2] - to[2])
        best = { fraction = f, point = M.add(from, M.mul(d, f)), normal = { 0, 1, 0 } }
    end
    for _, bar in ipairs(world.bars or {}) do
        -- A bar along X at height y and position z, spanning x0..x1.
        local r = bar.radius
        local oy, oz = from[2] - bar.y, from[3] - bar.z
        local a = d[2] * d[2] + d[3] * d[3]
        local c = oy * oy + oz * oz - r * r
        if a > 1e-12 and c > 0 then
            local b = 2 * (oy * d[2] + oz * d[3])
            local disc = b * b - 4 * a * c
            if disc >= 0 then
                local s = (-b - math.sqrt(disc)) / (2 * a)
                if s >= 0 and s <= 1 and (not best or s < best.fraction) then
                    local p = M.add(from, M.mul(d, s))
                    if p[1] >= bar.x0 and p[1] <= bar.x1 then
                        best = { fraction = s, point = p, normal = { 0, (p[2] - bar.y) / r, (p[3] - bar.z) / r } }
                    end
                end
            end
        end
    end
    for _, rail in ipairs(world.rails) do
        local r = rail.radius
        local ox, oy = from[1] - rail.x, from[2] - rail.y
        local a = d[1] * d[1] + d[2] * d[2]
        local c = ox * ox + oy * oy - r * r
        if a > 1e-12 and c > 0 then
            local b = 2 * (ox * d[1] + oy * d[2])
            local disc = b * b - 4 * a * c
            if disc >= 0 then
                local s = (-b - math.sqrt(disc)) / (2 * a)
                if s >= 0 and s <= 1 and (not best or s < best.fraction) then
                    local p = M.add(from, M.mul(d, s))
                    if p[3] >= rail.z0 and p[3] <= rail.z1 then
                        best = { fraction = s, point = p, normal = { (p[1] - rail.x) / r, (p[2] - rail.y) / r, 0 } }
                    end
                end
            end
        end
        for _, cap in ipairs({ { rail.z0, -1 }, { rail.z1, 1 } }) do
            local z, sign = cap[1], cap[2]
            if d[3] * sign < 0 then
                local s = (z - from[3]) / d[3]
                if s >= 0 and s <= 1 and (not best or s < best.fraction) then
                    local p = M.add(from, M.mul(d, s))
                    if (p[1] - rail.x) ^ 2 + (p[2] - rail.y) ^ 2 <= r * r then
                        best = { fraction = s, point = p, normal = { 0, 0, sign } }
                    end
                end
            end
        end
    end
    return best
end
Tests.cast = cast

local function v3(a) return vector.create(a[1], a[2], a[3]) end
local function from_vector(v) return { v.x, v.y, v.z } end
-- A raw probe_batch result for these rays, in the shape
-- Extension/Plugins/plugin_api_physics.cpp builds it (:636-665): status,
-- native_casts (one cast per ray here; the SDK allows count to 2 x count),
-- budget_exhausted, the epoch it was given, both exclusion facts, and rows
-- whose hits carry a Luau vector position and normal, the fraction, measured
-- zero surface motion with motion = "measured", and no other field. The
-- guard runs the real Contact.decode on its batches, so a batch without cast
-- accounting or a hit without its motion would make every guard read
-- unavailable.
local function batch(world, rays, epoch)
    local rows = {}
    for i, ray in ipairs(rays) do
        local hit = cast(world, from_vector(ray.from), from_vector(ray.to))
        if hit then
            rows[i] = { status = "hit", fraction = hit.fraction, position = v3(hit.point), normal = v3(hit.normal),
                motion = "measured", normal_available = true, surface_velocity_available = true,
                surface_velocity = vector.create(0, 0, 0) }
        else
            rows[i] = { status = "clear" }
        end
    end
    return { status = "available", native_casts = #rows, budget_exhausted = false, epoch = epoch,
        local_actor_excluded = true, owned_bodies_excluded = true, rays = rows }
end

-- contact_runtime.lua's Contact.decode copy of a raw batch, for this tick's
-- own frame: the shape ride_runtime.lua makes of its wheel batch.
local function contact_copy(tick, rays, raw)
    local s, input = tick.sample, tick.input
    local src = input.sample
    local frame = { valid = true, fresh = true, body_handle = tick.body_handle, physics_epoch = s.epoch,
        serial = s.serial, time = s.time, seconds = s.seconds, body = nil, sample = s,
        source = { lease_handle = input.lease_handle, generation = input.generation, user = src.user, packet = src.packet,
            sequence = src.sequence, source_epoch = src.source_epoch, context_generation = src.context_generation,
            observation_serial = src.observation_serial, observed_ms = src.observed_ms },
        owner = { body_handle = tick.body_handle, lease_handle = input.lease_handle }, gates = tick.gates }
    frame.body = { mass = s.mass, inertia_body = { s.inertia.x, s.inertia.y, s.inertia.z },
        center_of_mass = { s.position.x, s.position.y, s.position.z },
        linear_velocity = { s.velocity.x, s.velocity.y, s.velocity.z },
        angular_velocity = { s.angular_velocity.x, s.angular_velocity.y, s.angular_velocity.z },
        orientation = { s.rotation[1], s.rotation[2], s.rotation[3], s.rotation[4] } }
    return Contact.decode(frame, rays, raw)
end

-- The two wheel rows, measured from the body the composer will read, the way
-- ride_runtime.lua's wheel_contacts builds them from its two rays.
local function wheel_rows(world, body)
    local forward = M.turn(M.normalized(body.orientation), { 0, 0, 1 })
    local rows = {}
    for i, hub in ipairs(World.hubs(body)) do
        if hub[2] < 0 then
            rows[i] = { contact = { status = "unavailable" } }
        else
            local hit = cast(world, hub, { hub[1], hub[2] - (R + World.ray_margin), hub[3] })
            local basis = hit and M.basis(hit.normal, forward)
            if not hit then
                rows[i] = { contact = { status = "clear" } }
            elseif not basis then
                rows[i] = { contact = { status = "unavailable" } }
            else
                rows[i] = { contact = { status = "hit", point = hit.point, normal = basis.normal, forward = basis.forward,
                    surface_velocity = { 0, 0, 0 } }, separation = M.dot(M.sub(hub, hit.point), basis.normal) - R,
                    verified_plane = false, balance_normal_available = false }
            end
        end
    end
    return rows
end

-- The native read of a body: float vectors, as physics.read returns them.
local function sample_of(body, serial, time)
    local q = M.normalized(body.orientation)
    return { epoch = newproxy(), serial = serial, time = time, seconds = H, mass = body.mass,
        position = v3(body.center_of_mass), rotation = { q[1], q[2], q[3], q[4] }, velocity = v3(body.linear_velocity),
        angular_velocity = v3(body.angular_velocity), inertia = v3(body.inertia_body) }
end
local function measured(sample)
    return { mass = sample.mass, inertia_body = from_vector(sample.inertia), center_of_mass = from_vector(sample.position),
        linear_velocity = from_vector(sample.velocity), angular_velocity = from_vector(sample.angular_velocity),
        orientation = { sample.rotation[1], sample.rotation[2], sample.rotation[3], sample.rotation[4] } }
end

local function increment(s)
    local chars, carry = {}, 1
    for i = #s, 1, -1 do
        local n = string.byte(s, i) - 48 + carry
        chars[i] = string.char(48 + n % 10)
        carry = n >= 10 and 1 or 0
    end
    return (carry == 1 and "1" or "") .. table.concat(chars)
end

-- Script inputs use short names: left_x, left_y, right_x, right_y, pedal (A),
-- brake (B), r3, lb, rb, rt (right trigger fully pulled). Everything omitted
-- is neutral.
local function pad_of(input)
    input = input or {}
    local out = { left_x = input.left_x or 0, left_y = input.left_y or 0, right_x = input.right_x or 0,
        right_y = input.right_y or 0, left_trigger = 0, right_trigger = 0, playstation = false,
        buttons = { up = false, down = false, left = false, right = false, start = false, back = false,
            left_stick = false, right_stick = input.r3 == true, lb = input.lb == true, rb = input.rb == true,
            a = input.pedal == true, b = input.brake == true, x = false, y = false } }
    if input.rt then out.right_trigger = 1 end
    return out
end

-- The constructed native support owner: the test world's own wheel contact,
-- reported with the provenance a native support owner would carry. It knows
-- nothing of pegs, as native collision does not. The composer forwards this
-- fact to trick_runtime and never makes one of its own.
local function support_owner(seen, rows)
    local point, normal, n = { 0, 0, 0 }, { 0, 0, 0 }, 0
    for i = 1, 2 do
        if World.supported(seen, rows[i]) then
            point, normal = M.add(point, rows[i].contact.point), M.add(normal, rows[i].contact.normal)
            n += 1
        end
    end
    if n == 0 then return { provenance = "measured_support", grounded = false } end
    return { provenance = "measured_support", grounded = true, point = M.mul(point, 1 / n), normal = M.unit(normal),
        surface_velocity = { 0, 0, 0 } }
end

------------------------------------------------------------------------------
-- The driver: one native step at a time, with the receipt left to the caller.

local function attitude(body)
    local yaw, pitch, lean = World.attitude(body)
    return yaw, pitch, lean
end

-- spec: options, rails, bars, speed, x, z, and `support` ("owner" by default,
-- "none" for no support owner, or a function(seen, rows) returning the fact).
-- With no explicit option the real composer/Core default supplies four
-- batches. The one-, two- and three-batch counterexamples set their option.
local function driver(spec)
    local options = table.clone(spec.options or {})
    local d = { spec = spec, world = { rails = spec.rails or {}, bars = spec.bars }, ride = Composer.new(options),
        s = { serial = "100", time = 0, k = 0, ms = 50000, owner = "mount-1", body_handle = newproxy(),
            lease = newproxy(), mounts = 1 }, costs = {} }
    d.body, d.wheels = World.place(World.terrain.flat(), { speed = spec.speed or 0, x = spec.x or 0, z = spec.z or 0 })
    return d
end

-- Builds the next read's tick. hooks.query edits the wheel batch facts and
-- hooks.duplicate reuses the last read's serial and sample.
local function next_tick(d, input, hooks)
    hooks = hooks or {}
    local s = d.s
    if hooks.duplicate and d.last_sample then
        local tick = M.copy(d.last_tick_shape)
        tick.sample, tick.body_handle, tick.input = d.last_sample, s.body_handle, nil
        return tick, d.last_sample, measured(d.last_sample)
    end
    s.k += 1
    s.serial = increment(s.serial)
    s.time = (s.k - 1) * H
    s.ms += (s.k % 3 == 0) and 16 or 17
    local recovered = false
    if input.recover then
        -- The caller's own recovery: the bike placed upright where it lay,
        -- at rest, as a new mount.
        local yaw = attitude(d.body)
        d.body, d.wheels = World.place(World.terrain.flat(), { x = d.body.center_of_mass[1], z = d.body.center_of_mass[3], yaw = yaw })
        s.mounts += 1
        s.owner = "mount-" .. s.mounts
        recovered = true
    end
    local sample = sample_of(d.body, s.serial, s.time)
    local seen = measured(sample)
    local rows = wheel_rows(d.world, seen)
    local support = d.spec.support
    local fact
    if support == nil or support == "owner" then fact = support_owner(seen, rows)
    elseif type(support) == "function" then fact = support(seen, rows) end
    local tick = { sample = sample, body_handle = s.body_handle, owner = s.owner,
        wheels = { M.copy(d.wheels[1]), M.copy(d.wheels[2]) }, wheel_rows = rows, support = fact,
        wheel_query = { epoch_matches = true, accounting_known = true, budget_exhausted = false,
            local_actor_excluded = true, owned_bodies_excluded = true },
        gates = { focused = true, menu_open = false }, recovered = recovered,
        input = { input_ok = true, lease_handle = s.lease, generation = 1, sample = { user = 0, packet = s.k,
            sequence = "7", source_epoch = "11", context_generation = "13",
            observation_serial = tostring(1000 + s.k), observed_ms = tostring(s.ms), pad = pad_of(input) } } }
    if hooks.query then hooks.query(tick.wheel_query) end
    -- hooks.tick edits the whole tick before plan (an unbound read, say).
    if hooks.tick then hooks.tick(tick) end
    d.last_sample = sample
    d.last_tick_shape = { owner = tick.owner, wheels = tick.wheels, wheel_rows = rows, support = fact,
        wheel_query = tick.wheel_query, gates = tick.gates }
    return tick, sample, seen
end

-- plan, cast, witness, cast, step: one read through the composer. Each
-- planned lane is cast as its own batch, and the cast batches are counted
-- (the wheel batch is batch 1). hooks.rail(tick, plan, raw),
-- hooks.guard(tick, plan, raw, seen) and hooks.witness(tick, witness, raw,
-- seen) may replace the batch the caller hands back (nil hands back none),
-- and hooks.no_witness leaves the witness call out.
local function read(d, input, hooks)
    local ride, world = d.ride, d.world
    local tick, sample, seen = next_tick(d, input, hooks)
    local c0 = clock and clock()
    local plan = ride:plan(tick)
    local c1 = clock and clock()
    local lanes = { Composer.wheel_rays }
    if plan.rail then
        tick.rail = batch(world, plan.rail.rays, sample.epoch)
        table.insert(lanes, #plan.rail.rays)
        if hooks and hooks.rail then tick.rail = hooks.rail(tick, plan, tick.rail) end
    end
    if plan.guard then
        tick.guard = batch(world, plan.guard.rays, sample.epoch)
        table.insert(lanes, #plan.guard.rays)
        if hooks and hooks.guard then tick.guard = hooks.guard(tick, plan, tick.guard, seen) end
    end
    if plan.camera then
        local hit = cast(world, from_vector(plan.camera.from), from_vector(plan.camera.to))
        tick.camera_hit = hit and v3(hit.point) or nil
    end
    local c2 = clock and clock()
    local w = (hooks and hooks.no_witness) and { available = false, reason = "not_called", rays = {} } or ride:witness(tick)
    local c3 = clock and clock()
    if #w.rays > 0 then
        tick.witness = batch(world, w.rays, sample.epoch)
        table.insert(lanes, #w.rays)
        if hooks and hooks.witness then tick.witness = hooks.witness(tick, w, tick.witness, seen) end
    end
    local c4 = clock and clock()
    local result = ride:step(tick)
    local c5 = clock and clock()
    if clock then table.insert(d.costs, ((c1 - c0) + (c3 - c2) + (c5 - c4)) * 1000) end
    local yaw, pitch, lean = attitude(seen)
    return { step = d.s.k, result = result, plan = plan, witness_rays = #w.rays, witness = w, lanes = lanes, mode = result.mode,
        position = M.copy(seen.center_of_mass), velocity = M.copy(seen.linear_velocity),
        speed = math.sqrt(seen.linear_velocity[1] ^ 2 + seen.linear_velocity[3] ^ 2), yaw = yaw, pitch = pitch,
        lean = lean, up_y = M.turn(M.normalized(seen.orientation), { 0, 1, 0 })[2], time = d.s.time, input = input,
        rows = tick.wheel_rows, tick = tick }
end

-- The constructed native step after a read. `applied` is the command the
-- world runs (the submitted one, or nil for none). Without one the body
-- falls freely, or with hold = true the constructed ground holds it up, as
-- native collision holds a bike nobody pushes.
local function advance(d, record, applied, hold)
    if applied then
        d.body = World.integrate(d.body, { force = applied.force, torque = applied.torque,
            hop_impulse = applied.hop_impulse }, GRAVITY, H)
        d.wheels = { M.copy(d.wheels[1]), M.copy(d.wheels[2]) }
        for i = 1, 2 do d.wheels[i].angular_speed = applied.wheels[i].angular_speed end
    elseif record.result.mode == "bailed" then
        -- The fall belongs to the caller's native owner. Here the body
        -- simply comes to rest where it lay.
        d.body = M.copy(d.body)
        d.body.linear_velocity, d.body.angular_velocity = { 0, 0, 0 }, { 0, 0, 0 }
    else
        local f = hold and M.mul(GRAVITY, -d.body.mass) or { 0, 0, 0 }
        d.body = World.integrate(d.body, { force = f, torque = { 0, 0, 0 }, hop_impulse = { 0, 0, 0 } }, GRAVITY, H)
    end
end

-- One native step after a read: the submitted command, or for a read that
-- submitted nothing, the body left to native physics. That holds it up while
-- a wheel was supported, as native collision holds a bike nobody pushes, and
-- lets it fall freely otherwise.
local function settle_read(d, record)
    local c = record.result.commands
    local support = record.result.diagnostics.support
    advance(d, record, c.submit and c or nil, support ~= nil and support.any == true)
end

-- One scenario: a scripted pad, the composer, the integrator, and a receipt
-- for every submitted command right after the constructed world ran it. With
-- spec.late each receipt arrives only after the next read instead, the native
-- cadence RIDE_COMPOSER.md known gap 11 describes: that read is withheld as
-- receipt_pending and the read after it previews across a serial gap.
local function run(spec)
    local d = driver(spec)
    local trace, script_state = {}, {}
    local last, pending
    for step = 1, spec.max_steps do
        local input = spec.script(step, last, script_state)
        if input == nil then break end
        local record = read(d, input, spec.hooks and spec.hooks(step) or nil)
        local c = record.result.commands
        settle_read(d, record)
        if pending then
            local ok, why = d.ride:accept(pending)
            assert(ok, "the composer takes the late receipt for its own command: " .. tostring(why))
            pending = nil
        end
        if c.submit and spec.late then
            pending = c.serial
        elseif c.submit then
            local ok, why = d.ride:accept(c.serial)
            assert(ok, "the composer takes the receipt for its own command: " .. tostring(why))
        end
        table.insert(trace, record)
        last = record
    end
    return { trace = trace, costs = d.costs, ride = d.ride, spec = spec }
end
Tests.run_scenario = run

------------------------------------------------------------------------------
-- Trace helpers.

local function first(trace, from, predicate)
    for i = from or 1, #trace do if predicate(trace[i], i) then return i end end
    return nil
end
local function events_named(record, name)
    local out = {}
    for _, e in ipairs(record.result.events) do if e.name == name then table.insert(out, e) end end
    return out
end
local function mode_event(record)
    for _, e in ipairs(record.result.events) do if e.name == "mode" then return e end end
    return nil
end
local function transitions(trace)
    local out = {}
    for _, r in ipairs(trace) do
        for _, e in ipairs(r.result.events) do
            if e.name == "mode" then table.insert(out, e.from .. ">" .. e.to .. "(" .. e.reason .. ")") end
        end
    end
    return out
end
local function has_trick(record, name)
    for _, e in ipairs(record.result.events) do if e.name == "trick" and e.event == name then return e end end
    return nil
end
local function grind_event(record, name)
    for _, e in ipairs(record.result.events) do if e.name == "grind" and e.event.name == name then return e.event end end
    return nil
end
local function percentile(list, p)
    if #list == 0 then return 0 end
    local sorted = table.clone(list)
    table.sort(sorted)
    return sorted[math.clamp(math.ceil(#sorted * p), 1, #sorted)]
end
local function fmt(x) return string.format("%.3f", x) end
-- The path to the first opaque handle inside v, or nil.
local function find_opaque(v, path, seen)
    seen = seen or {}
    if type(v) == "userdata" or type(v) == "function" then return path end
    if type(v) ~= "table" or seen[v] then return nil end
    seen[v] = true
    for k, x in pairs(v) do
        if type(k) == "userdata" then return path .. "[userdata key]" end
        local hit = find_opaque(x, path .. "." .. tostring(k), seen)
        if hit then return hit end
    end
    return nil
end

------------------------------------------------------------------------------
-- Scenario scripts.

local scenarios = {}

-- Pedal from rest on flat ground, coast, brake to a stop.
scenarios.pedal_brake = { speed = 0, max_steps = 900, script = function(step, last, st)
    if step <= 10 then return {} end
    if step <= 250 then return { pedal = true } end
    if step <= 280 then return {} end
    if not st.stopped then
        if last.speed < .05 and step > 290 then st.stopped = step else return { brake = true } end
    end
    if step > st.stopped + 15 then return nil end
    return {}
end }

-- A held from rest past the top pedaling speed and on for 1 s, then B with A
-- still held until the rider pedals again, A alone for 0.5 s, 0.5 s released,
-- then A until the rider stops pedaling once more.
scenarios.pedal_top_speed = { speed = 0, max_steps = 900, script = function(step, last, st)
    if step <= 10 then return {} end
    local pedaling = last.result.diagnostics.kernel.pedaling
    if not st.tripped then
        if last.input.pedal and not pedaling then st.tripped = step else return { pedal = true } end
    end
    if step <= st.tripped + 60 then return { pedal = true } end
    if not st.resumed then
        if pedaling then st.resumed = step else return { pedal = true, brake = true } end
    end
    if step <= st.resumed + 30 then return { pedal = true } end
    if step <= st.resumed + 60 then return {} end
    if not st.again then
        if last.input.pedal and not pedaling then st.again = step else return { pedal = true } end
    end
    if step <= st.again + 10 then return { pedal = true } end
    return nil
end }

-- A held for 2 s at 15 m/s, well past the top pedaling speed. The flat world
-- has no drag, so it holds that speed as a long downhill would.
scenarios.pedal_downhill = { speed = 15, max_steps = 130, script = function(step)
    if step <= 10 then return {} end
    return { pedal = true }
end }

-- Rolling at 8.5 m/s with A released, B alone into the band below 7.65 m/s,
-- then A until the rider stops pedaling at the top speed again.
scenarios.pedal_after_coast = { speed = 8.5, max_steps = 400, script = function(step, last, st)
    if step <= 10 then return {} end
    if not st.slowed then
        if last.speed < 7.65 then st.slowed = step else return { brake = true } end
    end
    if not st.stopped then
        if last.input.pedal and not last.result.diagnostics.kernel.pedaling then st.stopped = step else return { pedal = true } end
    end
    if step <= st.stopped + 10 then return { pedal = true } end
    return nil
end }

-- R3 bunny hop at 4 m/s.
scenarios.bunny_hop = { speed = 4, max_steps = 160, script = function(step)
    if step == 21 then return { r3 = true } end
    return {}
end }

-- A half pull held for 2 s: input.lua's manual at about the centre of
-- manual_balance's sweet spot.
scenarios.manual = { speed = 4, max_steps = 230, script = function(step)
    if step <= 20 then return {} end
    if step <= 140 then return { right_y = -.53 } end
    return {}
end }

-- The same pull held through a hop's landing: no lift until a neutral.
scenarios.manual_after_air = { speed = 4, max_steps = 260, script = function(step, last, st)
    if step == 21 then return { r3 = true } end
    if step < 24 then return {} end
    if not st.landed then
        if last.mode == "rolling" and step > 30 then st.landed = step else return { right_y = -.53 } end
    end
    if step < st.landed + 40 then return { right_y = -.53 } end
    if step < st.landed + 46 then return {} end
    if step < st.landed + 130 then return { right_y = -.53 } end
    return nil
end }

-- Hop with a held nose-down air pitch: an over-rotated landing.
scenarios.nose_dive = { speed = 4, max_steps = 300, script = function(step, last, st)
    if step == 21 then return { r3 = true } end
    if step < 24 then return {} end
    if not st.bailed then
        if last.mode == "bailed" then st.bailed = step else return { left_y = 1 } end
    end
    if step == st.bailed + 30 then return { recover = true } end
    if step < st.bailed + 42 then return {} end
    if step < st.bailed + 102 then return { pedal = true } end
    return nil
end }

-- Barspin left: LB with the right stick pulled back, one sample, in the air.
scenarios.barspin = { speed = 4, max_steps = 170, script = function(step)
    if step == 21 then return { r3 = true } end
    if step == 26 then return { lb = true, right_y = -1 } end
    return {}
end }

-- A 50 mm round rail, crest 0.45 m, from z = 6 to z = 10, under the left
-- pegs of a bike riding +Z at x = 0 (+X is rider left).
local RAIL = { x = Pegs.peg("front_left").center[1], crest = .45, radius = .025, z0 = 6, z1 = 10 }
local function rail_list()
    return { { x = RAIL.x, y = RAIL.crest - RAIL.radius, radius = RAIL.radius, z0 = RAIL.z0, z1 = RAIL.z1 } }
end
-- At 5 m/s: hold the right stick back for `charge` samples (input.lua's hop
-- charge, about 0.53 strength for 8), then flick, so the pegs fall about
-- 8 cm onto the crest at about 1 m/s. `lean` is the scripted rider's left
-- stick while grinding.
local function flick_onto(charge, lean)
    local trigger = RAIL.z0 - 1.28 - charge * 5 * H
    return function(step, last, st)
        if step <= 10 then return {} end
        if not st.charge_at and last.position[3] >= trigger then st.charge_at = step end
        if st.charge_at and step < st.charge_at + charge then return { right_y = -1 } end
        if st.charge_at and step == st.charge_at + charge then return { right_y = 1 } end
        if step > 400 then return nil end
        if st.charge_at and last.mode == "rolling" and step > st.charge_at + 60 then
            st.after = (st.after or 0) + 1
            if st.after > 40 then return nil end
        end
        if lean and last and last.mode == "grinding" then return { left_x = lean(last) } end
        return {}
    end
end
-- A full R3 hop onto the same rail: the pegs fall about 0.8 m onto it.
local function r3_onto(trigger)
    return function(step, last, st)
        if step <= 10 then return {} end
        if not st.hop and last.position[3] >= trigger then st.hop = step; return { r3 = true } end
        if step > 200 then return nil end
        return {}
    end
end
-- grind_policy's assist at its sanitize maxima, with no yaw deadband.
local STRONG_ASSIST = { assist_enabled = true, assist_roll_stiffness = 1000, assist_roll_damping = 200,
    assist_torque_limit = 400, assist_yaw_stiffness = 1000, assist_yaw_damping = 200, assist_yaw_deadband = 0 }
-- A constructed rider: a held left-stick lean of steer 0.14 right, plus ten
-- times the measured roll fed back each sample. It reads the attitude every
-- 60 Hz sample, which is faster and steadier than a person.
local function feedback_rider(last) return math.clamp(-.243 - 10 * last.lean, -1, 1) end

------------------------------------------------------------------------------

function Tests.run()
    local assertions, cases = 0, 0
    local function check(ok, why) assertions += 1; assert(ok, why) end
    local function scenario(name, body) cases += 1; body() end
    local all_costs, report = {}, {}
    local peak_requests, peak_witness = 0, 0
    local residual_max, residual_reads = 0, 0
    local function note(line) table.insert(report, line); print("ride_composer: " .. line) end

    -- Invariants every tick of every run must hold. Every read of a riding
    -- scenario has its selected source, so its guard is bound to a qualified
    -- Framev1; unbound = true allows the reads a case makes unbound on purpose.
    -- Whatever the case, a command leaves only from a bound read that
    -- bail_policy judged, and every other read that is not bailed says why it
    -- submitted nothing.
    local function invariants(name, out, unbound)
        local previous = "none"
        local max_requests = 0
        local after_command = false
        for _, r in ipairs(out.trace) do
            local res = r.result
            check(res.valid, name .. " step " .. r.step .. " valid: " .. tostring(res.issue))
            if not unbound then
                check(r.plan.guard_binding == "bound" and res.diagnostics.queries.guard_binding == "bound",
                    name .. " step " .. r.step .. " plans its guard on a qualified Framev1: " .. tostring(r.plan.guard_binding))
            end
            local b = res.diagnostics.bail
            if res.commands.submit then
                check(r.plan.guard_binding == "bound" and r.plan.guard_issue ~= "bail_guard_unbound",
                    name .. " step " .. r.step .. " submits only from a bound read")
                check(b.evaluated == true and b.valid == true and b.guarded == true and b.unguarded == nil and not b.bail,
                    name .. " step " .. r.step .. " submits only from a read bail_policy judged")
            end
            if b and b.guarded == false then
                check(not res.commands.submit and res.commands.force == nil and res.commands.torque == nil
                    and res.commands.hop_impulse == nil
                    and type(b.unguarded) == "string" and res.diagnostics.kernel.issue == b.unguarded,
                    name .. " step " .. r.step .. " an unguarded read submits nothing and says why")
            end
            for _, e in ipairs(res.events) do
                if e.name == "mode" then
                    check(Composer.allowed(e.from, e.to), name .. " edge " .. e.from .. ">" .. e.to .. " is in the graph")
                    check(e.from == previous, name .. " transition starts from the previous mode")
                    previous = e.to
                    if e.to == "grinding" then
                        check(grind_event(r, "lock_on") ~= nil, name .. " grinding begins only on a grind_policy lock_on")
                    end
                    if e.to == "bailed" then
                        check(res.diagnostics.bail.bail == true, name .. " bailed begins only on a bail_policy bail")
                    end
                    if e.from == "bailed" then
                        check(e.reason == "recovered" and r.input.recover == true, name .. " bailed ends only on recovered")
                    end
                    check(not (e.from == "airborne" and (e.to == "manual" or e.to == "nose_manual")),
                        name .. " airborne never enters a manual")
                end
            end
            check(res.mode == previous, name .. " result mode follows its transitions")
            if res.mode == "bailed" then check(res.commands.submit == false, name .. " a bailed ride submits nothing") end
            local requests = r.plan.requests + r.witness_rays
            max_requests = math.max(max_requests, requests)
            peak_requests = math.max(peak_requests, requests)
            peak_witness = math.max(peak_witness, r.witness_rays)
            check(requests <= Composer.request_budget, name .. " step " .. r.step .. " within the request budget")
            -- One probe_batch per lane, each of 1 to 32 rays, and no more
            -- batches than the read's allowance.
            check(#r.lanes <= r.plan.batch_allowance, name .. " step " .. r.step .. " within its batch allowance")
            for _, rays in ipairs(r.lanes) do
                check(rays >= 1 and rays <= Composer.batch_rays, name .. " every cast batch holds 1 to 32 rays")
            end
            if res.diagnostics.queries then
                check(res.diagnostics.queries.batches == #r.lanes, name .. " the composer counts the batches cast")
            end
            if res.camera then
                check(Camera.valid_look(res.camera.eye, res.camera.target, res.camera.fov), name .. " camera.look accepts the view")
            end
            if res.commands.submit then
                check(M.vec(res.commands.force) and M.vec(res.commands.torque) and M.vec(res.commands.hop_impulse),
                    name .. " finite commands")
                check(res.commands.serial == res.serial, name .. " a command names the read it was made for")
            end
            -- A read that submitted nothing while the constructed ground held
            -- the bike up leaves the next read an impulse the residual rightly
            -- sees (m g h, about 17.3 N s); the summary is of reads that follow
            -- a submitted command only.
            local residual = b and b.residual
            if residual and not unbound and after_command then
                residual_reads += 1
                residual_max = math.max(residual_max, residual)
            end
            after_command = res.commands.submit == true
        end
        for _, ms in ipairs(out.costs) do table.insert(all_costs, ms) end
        return max_requests
    end
    local function cost_line(out)
        if #out.costs == 0 then return "cost unmeasured" end
        return string.format("tick ms median %.2f p95 %.2f max %.2f over %d ticks", percentile(out.costs, .5),
            percentile(out.costs, .95), percentile(out.costs, 1), #out.costs)
    end

    scenario("graph and refusals", function()
        check(table.isfrozen(Composer), "module table frozen")
        check(Composer.allowed("airborne", "manual") == false and Composer.allowed("airborne", "nose_manual") == false,
            "airborne -> manual is not an edge")
        check(Composer.allowed("airborne", "grinding") and not Composer.allowed("rolling", "grinding")
            and not Composer.allowed("manual", "grinding"), "grinding is entered only from the air")
        for _, mode in ipairs({ "none", "rolling", "airborne", "manual", "nose_manual", "grinding" }) do
            check(Composer.allowed(mode, "bailed"), mode .. " -> bailed is an edge")
        end
        check(Composer.allowed("bailed", "rolling") and not Composer.allowed("bailed", "manual")
            and not Composer.allowed("bailed", "grinding"), "bailed leaves only to a plain ride mode")
        local mode, why = Composer.settle("airborne", "manual", true)
        check(mode == "rolling" and why == "airborne_to_manual_refused", "settle refuses airborne -> manual")
        mode, why = Composer.settle("rolling", "grinding", true)
        check(mode == "rolling" and why == "rolling_to_grinding_refused", "settle refuses rolling -> grinding")
        mode, why = Composer.settle("airborne", "grinding", false)
        check(mode == "airborne" and why == "grind_without_lock_on", "settle refuses a grind without this read's lock_on")
        mode, why = Composer.settle("airborne", "grinding", false, true)
        check(mode == "grinding" and why == nil, "airborne -> grinding on a lock_on")
        mode, why = Composer.settle("grinding", "grinding", false)
        check(mode == "grinding" and why == nil, "a held grind needs no new lock_on")
        mode, why = Composer.settle("bailed", "manual", true)
        check(mode == "rolling" and why ~= nil, "bailed cannot jump into a lift")
        local edges = Composer.edges()
        edges.airborne.manual = true
        check(not Composer.allowed("airborne", "manual"), "edges() is a copy")
        local ride = Composer.new()
        local out = ride:step({})
        check(not out.valid and out.issue == "invalid_sample" and out.commands.submit == false, "a malformed tick submits nothing")
        check(ride:plan({}).valid == false, "a malformed tick plans nothing")
        check(ride:witness({}).available == false, "no witness without a plan")
        check(not pcall(Composer.new, { forces = { not_a_key = 1 } }), "unknown force tuning is refused")
        check(not pcall(Composer.new, { command_limits = { force = 50000 } }), "a command limit above the kernel's is refused")
        check(not pcall(Composer.new, { command_limits = { torque = 0 } }), "a zero command limit is refused")
        local a, b = ride:accept("1")
        check(a == false and b == "no_outstanding_command", "no receipt without a submitted command")
        a, b = ride:reject("1", "lost")
        check(a == false and b == "invalid_outcome", "an unknown receipt outcome is refused")
    end)

    scenario("duplicate, gap and unknown-support reads", function()
        local ride = Composer.new({ batches_per_read = LAB_BATCHES })
        local body, wheels = World.place(World.terrain.flat(), { speed = 2 })
        local world = { rails = {} }
        local lease, source = newproxy(), newproxy()
        -- plan, cast every lane as its own batch, witness, cast, step.
        local function full(r, t)
            local plan = r:plan(t)
            if plan.rail then t.rail = batch(world, plan.rail.rays, t.sample.epoch) end
            if plan.guard then t.guard = batch(world, plan.guard.rays, t.sample.epoch) end
            local w = r:witness(t)
            if #w.rays > 0 then t.witness = batch(world, w.rays, t.sample.epoch) end
            return r:step(t)
        end
        -- Each read carries its selected source (a neutral pad), so its guard
        -- has a Framev1, unless unbound.
        local function tick(serial, k, unbound)
            local sample = sample_of(body, serial, k * H)
            local out = { sample = sample, body_handle = lease, owner = 1, wheels = wheels,
                wheel_rows = wheel_rows(world, measured(sample)),
                wheel_query = { epoch_matches = true, budget_exhausted = false, local_actor_excluded = true,
                    owned_bodies_excluded = true }, gates = { focused = true, menu_open = false } }
            if not unbound then
                out.input = { input_ok = true, lease_handle = source, generation = 1, sample = { user = 0, packet = k + 1,
                    sequence = "7", source_epoch = "11", context_generation = "13", observation_serial = tostring(1000 + k),
                    observed_ms = tostring(50000 + 17 * k), pad = pad_of({}) } }
            end
            return out
        end
        -- No selected source: no Framev1 for the guard, so no guard plan and
        -- nothing submitted, not even passive support.
        local none = ride:step(tick("499", 0, true))
        check(none.valid and none.mode == "rolling" and not none.commands.submit
            and none.diagnostics.queries.guard == "bail_guard_unbound"
            and none.diagnostics.queries.guard_binding == "input_source_absent"
            and none.diagnostics.kernel.issue == "bail_guard_unbound" and none.diagnostics.bail.guard == "bail_guard_unbound"
            and ride:status().outstanding == nil, "a read without its selected source fails closed (bail_guard_unbound)")
        -- A step without a plan plans itself, but nothing it planned was
        -- cast, so bail_policy cannot judge it: it fails closed as uncast.
        local a = ride:step(tick("500", 0))
        check(a.valid and a.mode == "rolling" and a.diagnostics.queries.uncast and a.diagnostics.queries.batches == 1
            and a.diagnostics.queries.guard_binding == "bound",
            "a step without plan plans itself, uncast: only the wheel batch was cast")
        check(not a.commands.submit and a.commands.force == nil and a.diagnostics.kernel.issue == "uncast"
            and a.diagnostics.bail.guard == "uncast" and a.diagnostics.bail.evaluated == false
            and a.diagnostics.bail.guarded == false and ride:status().outstanding == nil,
            "an uncast read is unguarded and submits nothing (uncast)")
        local c = full(ride, tick("501", 1))
        check(c.commands.submit and c.commands.serial == "501" and c.diagnostics.bail.guarded
            and c.diagnostics.kernel.pedal == 0 and c.diagnostics.kernel.brake == 0,
            "a neutral pad, every lane cast and judged: support with no rider control")
        check(ride:status().outstanding == "501" and ride:status().kernel_serial == nil,
            "a submitted command waits for its receipt; the kernel has not adopted it")
        local ok, why = ride:accept("500")
        check(not ok and why == "serial_mismatch", "a receipt for another read is refused")
        check(ride:accept("501") and ride:status().kernel_serial == "501", "accept adopts the previewed kernel")
        ok, why = ride:accept("501")
        check(not ok and why == "no_outstanding_command", "a receipt is taken once")
        local dup = ride:step(tick("501", 1))
        check(dup.valid and dup.issue == "duplicate_read" and not dup.commands.submit, "a duplicate read submits nothing")
        local back = ride:step(tick("500", 0))
        check(not back.valid and back.issue == "serial_regressed", "a regressed read is refused")
        local gap = full(ride, tick("503", 3))
        check(gap.valid and gap.diagnostics.consecutive == false and gap.diagnostics.kernel.committed_serial == nil,
            "a gap is reported and the kernel previews from a reset history")
        check(gap.commands.submit and ride:accept("503"), "the gap read still submits passive support")
        -- One budget-exhausted wheel batch while rolling: support is unknown,
        -- which is a hold, not a loss of contact.
        local unqualified = tick("504", 4)
        unqualified.wheel_query.budget_exhausted = true
        local u = full(ride, unqualified)
        check(u.valid and not u.diagnostics.support.ground_known and not u.commands.submit and u.diagnostics.bail.guarded
            and u.diagnostics.kernel.issue == "wheel_query_unqualified", "unqualified wheel rows grant nothing")
        check(u.mode == "rolling" and #u.events == 0, "an unknown read takes no mode edge")
        check(u.diagnostics.balance.stepped == false and ride:status().grind.airborne_seen == false,
            "manual_balance holds and grind_policy is not armed by an unknown read")
        local next_read = full(ride, tick("505", 5))
        check(next_read.mode == "rolling" and #next_read.events == 0, "the next known read continues rolling with no landing")
        -- An explicit one-batch allowance: the same read has no guard
        -- lane, so nothing is submitted.
        local core = Composer.new({ batches_per_read = 1 })
        local cr = full(core, tick("600", 0))
        check(cr.valid and cr.diagnostics.queries.guard == "batch_allowance" and not cr.commands.submit
            and cr.diagnostics.kernel.issue == "batch_allowance" and cr.diagnostics.bail.guarded == false,
            "under one batch a read is unguarded and submits nothing (batch_allowance)")
    end)

    scenario("pedal to speed and brake to stop", function()
        local out = run(scenarios.pedal_brake)
        invariants("pedal_brake", out)
        local tr = out.trace
        local start = first(tr, 1, function(r) return r.input.pedal end)
        local function reach(v)
            local i = first(tr, start, function(r) return r.speed >= v end)
            return i and (i - start) * H or -1
        end
        local stop_pedal = first(tr, start, function(r) return not r.input.pedal end)
        local brake = first(tr, stop_pedal, function(r) return r.input.brake end)
        local stopped = first(tr, brake, function(r) return r.speed < .05 end)
        check(reach(3) > 0 and reach(6) > 0, "pedalling reaches 6 m/s")
        check(stopped ~= nil, "braking stops the bike")
        local brake_seconds = (stopped - brake) * H
        local brake_distance = tr[stopped].position[3] - tr[brake].position[3]
        local top = tr[stop_pedal].speed
        for i = start, #tr do check(tr[i].mode == "rolling", "pedal_brake stays rolling") end
        note(string.format("pedal_brake: 3 m/s in %s s, 6 m/s in %s s, %s m/s after %s s of pedal; coast %s -> %s m/s; brake from %s m/s: %s s, %s m, %s m/s^2 mean; %s",
            fmt(reach(3)), fmt(reach(6)), fmt(top), fmt((stop_pedal - start) * H), fmt(top), fmt(tr[brake - 1].speed),
            fmt(tr[brake - 1].speed), fmt(brake_seconds), fmt(brake_distance), fmt(tr[brake - 1].speed / brake_seconds),
            cost_line(out)))
    end)

    -- The kernel decides pedaling (forces.lua pedal_cadence) and the drawn
    -- crank follows that decision, so at the top pedaling speed the drive and
    -- the crank stop together with A still held.
    local tuning = Forces.tuning()
    local top_speed, resume_speed = tuning.pedal_top_speed, tuning.pedal_resume_speed
    local level_step = Rider.leveling_rate * H + 1e-9
    local function pedaling(r) return r.result.diagnostics.kernel.pedaling == true end
    -- The kernel's motor speed: the faster of the body and the rear rim.
    local function motor(r) return math.max(r.speed, r.tick.wheels[2].angular_speed * r.tick.wheels[2].radius) end
    local function crank(r)
        local rider = r.result.presentation.rider
        check(rider.valid and rider.crank and rider.crank.valid and rider.articulation, "step " .. r.step .. " presents the crank")
        return rider.crank.state, rider.articulation.crank_phase
    end
    local function turned(a, b) return math.abs(math.atan2(math.sin(b - a), math.cos(b - a))) end
    -- Over reads from..to: the raw crank advances (or holds) on every read and
    -- the drawn crank only levels while it holds.
    local function crank_runs(tr, from, to, advancing, why)
        for i = from, to do
            local previous_state, previous_phase = crank(tr[i - 1])
            local state, phase = crank(tr[i])
            if advancing then
                check(turned(previous_state.raw_phase, state.raw_phase) > 0 and not state.coasting, why .. ": the crank turns at step " .. i)
            else
                check(state.raw_phase == previous_state.raw_phase and state.coasting, why .. ": the raw crank holds at step " .. i)
                check(turned(previous_phase, phase) <= level_step, why .. ": the drawn crank only levels at step " .. i)
            end
        end
    end

    scenario("zero pedal torque holds the crank while the bike rolls", function()
        local spec = { speed = 2, max_steps = 30, options = { forces = { pedal_torque = 0 } },
            script = function(step) return step <= 10 and {} or { pedal = true } end }
        local out = run(spec)
        invariants("zero pedal torque", out)
        local tr = out.trace
        local coast = run({ speed = spec.speed, max_steps = spec.max_steps, options = spec.options,
            script = function() return {} end }).trace
        local start = first(tr, 1, function(r) return r.input.pedal end)
        check(start ~= nil and start > 1 and #coast == #tr, "the zero-torque run starts pedaling after neutral reads")
        for i = start, #tr do
            local r = tr[i]
            check(r.mode == "rolling" and r.result.commands.submit and r.tick.wheels[2].angular_speed > 0,
                "the zero-torque bike still rolls and submits, step " .. i)
            check(r.result.diagnostics.kernel.pedal == 1 and pedaling(r),
                "zero torque preserves the kernel's held-pedal intent, step " .. i)
            local c, k = r.result.commands, coast[i].result.commands
            check(M.length(M.sub(c.force, k.force)) == 0 and M.length(M.sub(c.torque, k.torque)) == 0
                and c.wheels[2].angular_speed == k.wheels[2].angular_speed,
                "zero-torque held pedal sends the exact coast command, step " .. i)
        end
        crank_runs(tr, start, #tr, false, "zero pedal torque")
    end)
    scenario("pedaling stops at the top pedaling speed and resumes below the band", function()
        local out = run(scenarios.pedal_top_speed)
        invariants("pedal_top_speed", out)
        local tr = out.trace
        local start = first(tr, 1, function(r) return r.input.pedal end)
        local trip = first(tr, start, function(r) return not pedaling(r) end)
        local braking = trip and first(tr, trip, function(r) return r.input.brake end)
        local resumed = braking and first(tr, braking, pedaling)
        local released = resumed and first(tr, resumed, function(r) return not r.input.pedal end)
        local pressed = released and first(tr, released, function(r) return r.input.pedal end)
        local again = pressed and first(tr, pressed, function(r) return not pedaling(r) end)
        check(again ~= nil and again < #tr, "pedal_top_speed reaches every phase")
        for i = start, #tr do check(tr[i].mode == "rolling" and tr[i].result.commands.submit, "pedal_top_speed rolls and submits") end

        -- Accelerating with A: pedaling, the crank turns and the bike speeds up.
        for i = start, trip - 1 do check(pedaling(tr[i]) and motor(tr[i]) < top_speed, "A below the top speed pedals") end
        for i = start + 2, trip - 1 do check(tr[i].speed > tr[i - 1].speed, "pedaling drives the bike at step " .. i) end
        crank_runs(tr, start + 2, trip - 1, true, "accelerating")
        check(motor(tr[trip]) >= top_speed, "the rider stops pedaling on reaching the top speed")

        -- A still held at the top speed: no drive, so with no drag the speed
        -- holds, and the crank stops and levels.
        for i = trip, braking - 1 do check(tr[i].input.pedal and not pedaling(tr[i]), "A held at the top speed coasts") end
        check(math.abs(tr[braking - 1].speed - tr[trip].speed) < 1e-4, "no pedal drive at the top speed")
        crank_runs(tr, trip, braking - 1, false, "top speed")
        for i = braking - 20, braking - 1 do
            local _, previous_phase = crank(tr[i - 1])
            local _, phase = crank(tr[i])
            check(turned(previous_phase, phase) <= 1e-12, "the coasting crank has come level and stays there")
        end

        -- Braked into the band with A held: still coasting until the resume speed.
        for i = braking, resumed - 1 do check(not pedaling(tr[i]) and motor(tr[i]) > resume_speed, "inside the band A still coasts") end
        crank_runs(tr, braking, resumed - 1, false, "band")
        check(motor(tr[resumed]) <= resume_speed and motor(tr[resumed]) > resume_speed - .1,
            "pedaling resumes on the first read at the resume speed")
        for i = resumed, released - 1 do check(pedaling(tr[i]), "below the band A pedals again") end
        for i = resumed + 2, released - 1 do check(tr[i].speed > tr[i - 1].speed, "resumed pedaling drives the bike at step " .. i) end
        crank_runs(tr, resumed, released - 1, true, "resumed")

        -- Released: coasting, as before this change.
        for i = released, pressed - 1 do check(not pedaling(tr[i]), "a released pedal coasts") end
        crank_runs(tr, released, pressed - 1, false, "released")
        -- Pressed again below the top speed: pedaling up to it, and no further.
        for i = pressed, again - 1 do check(pedaling(tr[i]) and motor(tr[i]) < top_speed, "A pressed again below the top speed pedals") end
        crank_runs(tr, pressed, again - 1, true, "pressed again")
        check(motor(tr[again]) >= top_speed, "and stops again at the top speed")

        -- No flicker: pedaling changes only at the five scripted points.
        local changes = 0
        for i = start + 1, #tr do if pedaling(tr[i]) ~= pedaling(tr[i - 1]) then changes += 1 end end
        check(changes == 5, "pedaling changes exactly five times, not " .. changes)
        note(string.format("pedal_top_speed: stops pedaling at %s m/s after %s s of A and holds %s m/s with A held; braked with A held it pedals again at %s m/s; %s",
            fmt(motor(tr[trip])), fmt((trip - start) * H), fmt(tr[braking - 1].speed), fmt(motor(tr[resumed])), cost_line(out)))
    end)

    scenario("A held at 15 m/s never turns the crank or drives the bike", function()
        local out = run(scenarios.pedal_downhill)
        invariants("pedal_downhill", out)
        local tr = out.trace
        local start = first(tr, 1, function(r) return r.input.pedal end)
        -- The same run without A, for the command each read would send.
        local released = { speed = scenarios.pedal_downhill.speed, max_steps = scenarios.pedal_downhill.max_steps,
            script = function(step) return {} end }
        local coast = run(released).trace
        check(#coast == #tr, "the released run has as many reads")
        for i = start, #tr do
            local r = tr[i]
            check(r.mode == "rolling" and r.result.commands.submit, "pedal_downhill rolls and submits")
            check(r.result.diagnostics.kernel.pedal == 1 and not pedaling(r), "A held at 15 m/s is not pedaling")
            local c, k = r.result.commands, coast[i].result.commands
            check(M.length(M.sub(c.force, k.force)) == 0 and M.length(M.sub(c.torque, k.torque)) == 0
                and c.wheels[2].angular_speed == k.wheels[2].angular_speed, "A held at 15 m/s sends the released command exactly")
        end
        crank_runs(tr, start, #tr, false, "15 m/s")
        check(math.abs(tr[#tr].speed - tr[start].speed) < 1e-3, "the speed holds with A held")
    end)

    scenario("late receipts keep the pedaling band", function()
        -- Each receipt after the next read: every other read is withheld and
        -- each submitted read previews across a serial gap. The latch follows
        -- speed alone, so that reset carries it and the band still holds.
        local spec = table.clone(scenarios.pedal_top_speed)
        spec.late, spec.max_steps = true, 1800
        local out = run(spec)
        invariants("pedal_top_speed late", out)
        local tr = out.trace
        local start = first(tr, 1, function(r) return r.input.pedal end)
        local trip = first(tr, start, function(r) return not pedaling(r) end)
        local braking = trip and first(tr, trip, function(r) return r.input.brake end)
        local resumed = braking and first(tr, braking, pedaling)
        check(resumed ~= nil, "pedal_top_speed late reaches the resume")
        local pending = 0
        for i = start, resumed do
            if not tr[i].result.commands.submit then
                check(tr[i].result.diagnostics.kernel.issue == "receipt_pending", "a read is withheld only for its receipt at step " .. i)
                pending += 1
            end
        end
        check(pending * 3 > resumed - start, "about every other read waits for a receipt, " .. pending .. " of " .. (resumed - start + 1))
        check(motor(tr[trip]) >= top_speed, "late receipts still stop pedaling at the top speed")
        for i = trip, resumed - 1 do check(not pedaling(tr[i]) and motor(tr[i]) > resume_speed, "late receipts: inside the band A still coasts") end
        check(motor(tr[resumed]) <= resume_speed, "late receipts: pedaling resumes only at the resume speed")
        note(string.format("pedal_top_speed late receipts: %d of %d reads withheld; stops at %s m/s, pedals again at %s m/s",
            pending, resumed - start + 1, fmt(motor(tr[trip])), fmt(motor(tr[resumed]))))
    end)

    scenario("A pressed inside the band after coasting down from above pedals at once", function()
        local out = run(scenarios.pedal_after_coast)
        invariants("pedal_after_coast", out)
        local tr = out.trace
        local slowing = first(tr, 1, function(r) return r.input.brake end)
        local pressed = slowing and first(tr, slowing, function(r) return r.input.pedal end)
        local stopped = pressed and first(tr, pressed, function(r) return not pedaling(r) end)
        check(stopped ~= nil and stopped < #tr, "pedal_after_coast reaches every phase")
        check(motor(tr[slowing]) > top_speed, "the bike starts above the top speed")
        for i = 1, pressed - 1 do check(not pedaling(tr[i]), "without A the rider coasts") end
        check(motor(tr[pressed]) > resume_speed and motor(tr[pressed]) < top_speed, "A is pressed inside the band")
        check(pedaling(tr[pressed]), "A pressed inside the band pedals on its first read")
        for i = pressed, stopped - 1 do check(tr[i].input.pedal and pedaling(tr[i]) and motor(tr[i]) < top_speed, "A pedals at once below the top speed") end
        for i = pressed + 2, stopped - 1 do check(tr[i].speed > tr[i - 1].speed, "pedaling drives the bike at step " .. i) end
        crank_runs(tr, pressed, stopped - 1, true, "pressed after coasting")
        check(motor(tr[stopped]) >= top_speed, "and stops again at the top speed")
        note(string.format("pedal_after_coast: A pressed at %s m/s pedals at once and stops again at %s m/s",
            fmt(motor(tr[pressed])), fmt(motor(tr[stopped]))))
    end)

    scenario("bunny hop", function()
        local out = run(scenarios.bunny_hop)
        invariants("bunny_hop", out)
        local tr = out.trace
        local hop = first(tr, 1, function(r) return r.result.diagnostics.kernel.hop_applied end)
        check(hop ~= nil, "R3 applies a hop impulse")
        local air = first(tr, hop, function(r) return r.mode == "airborne" end)
        check(air == hop + 1, "rolling -> airborne on the first read after the impulse")
        local me = mode_event(tr[air])
        check(me and me.from == "rolling" and me.reason == "wheel_contact_lost", "airborne on wheel contact loss")
        local land = first(tr, air, function(r) return r.mode == "rolling" end)
        check(land ~= nil and mode_event(tr[land]).reason == "landed", "airborne -> rolling on landing")
        local apex, base = -math.huge, tr[hop].position[2]
        for i = hop, land do apex = math.max(apex, tr[i].position[2]) end
        local takeoff = tr[hop + 1].velocity[2]
        check(has_trick(tr[air], "took_off") ~= nil or has_trick(tr[air + 1], "took_off") ~= nil
            or first(tr, hop, function(r) return has_trick(r, "took_off") ~= nil end) ~= nil, "the trick model sees the takeoff")
        check(first(tr, land, function(r) return has_trick(r, "landed") ~= nil end) ~= nil, "the trick model lands")
        note(string.format("bunny_hop: takeoff %s m/s up, COM apex %s m above the hop read, airtime %s s, landing %s m/s down, %s m/s after; %s",
            fmt(takeoff), fmt(apex - base), fmt((land - hop - 1) * H), fmt(-tr[land - 1].velocity[2]),
            fmt(tr[math.min(land + 30, #tr)].speed), cost_line(out)))
    end)

    scenario("manual held over one second", function()
        local out = run(scenarios.manual)
        invariants("manual", out)
        local tr = out.trace
        local enter = first(tr, 1, function(r) return r.mode == "manual" end)
        check(enter ~= nil, "a half pull enters a manual")
        check(mode_event(tr[enter]).from == "rolling" and mode_event(tr[enter]).reason == "lift_started", "rolling -> manual")
        local pull = first(tr, 1, function(r) return r.result.diagnostics.balance.state == "entering" end)
        check(pull ~= nil and pull < enter, "the pull starts the balance before the mode changes")
        for i = pull, enter - 1 do
            check(tr[i].mode == "rolling" and tr[i].result.diagnostics.support.front, "rolling while the front tyre is supported")
        end
        check(not tr[enter].result.diagnostics.support.front or tr[enter].result.diagnostics.balance.state == "balancing",
            "manual mode begins when the front tyre leaves support")
        local leave = first(tr, enter, function(r) return r.mode ~= "manual" end) or #tr
        local balancing = first(tr, enter, function(r) return r.result.diagnostics.balance.state == "balancing" end)
        local peak, sum, n, clear, lifted = 0, 0, 0, 0, nil
        for i = enter, leave - 1 do
            peak = math.max(peak, tr[i].pitch)
            if tr[i].result.diagnostics.balance.state == "balancing" then sum += tr[i].pitch; n += 1 end
            local front = tr[i].rows[1]
            local up = front.contact.status == "clear" or (front.contact.status == "hit" and front.separation > .02)
            if up and not lifted then lifted = i end
            if front.contact.status == "hit" then clear = math.max(clear, front.separation) end
            if front.contact.status == "clear" then clear = math.huge end
        end
        local released = first(tr, enter, function(r) return r.input.right_y == nil end)
        local seconds = (leave - enter) * H
        local why = tr[leave] and mode_event(tr[leave]) and mode_event(tr[leave]).reason or "held"
        note(string.format("manual: stick -0.53 (input manual %s); pull to lift-off (manual mode) %s s; front tyre off its contact gap %s s after lift-off; balancing from %s s to the release at %s s (%s s balancing, %d samples); manual mode %s s in all; peak pitch %s rad, mean balancing pitch %s rad, front tyre up %s; front down %s s after release (%s); %s",
            fmt(tr[enter].result.diagnostics.input.manual), fmt((enter - pull) * H), lifted and fmt((lifted - enter) * H) or "never",
            balancing and fmt((balancing - enter) * H) or "never", fmt((released - enter) * H),
            balancing and fmt((released - balancing) * H) or "0", n, fmt(seconds), fmt(peak), n > 0 and fmt(sum / n) or "n/a",
            clear == math.huge and "past the 0.15 m wheel ray" or fmt(clear), fmt((leave - released) * H), why, cost_line(out)))
        check(seconds > 1, "the manual lasts more than one second")
        check(balancing ~= nil and (released - balancing) * H > 1, "the lift balances for more than one second")
    end)

    scenario("manual refused from the air until neutral", function()
        local out = run(scenarios.manual_after_air)
        invariants("manual_after_air", out)
        local tr = out.trace
        local air = first(tr, 1, function(r) return r.mode == "airborne" end)
        local land = first(tr, air, function(r) return r.mode == "rolling" end)
        check(air and land, "hop and landing")
        for i = air, land + 39 do
            check(tr[i].mode ~= "manual", "a pull held through the landing does not lift")
        end
        local held = tr[land + 20].result.diagnostics.balance
        check(held.state == "idle" and held.manual == 0, "the balance stays idle under a held pull")
        local later = first(tr, land + 40, function(r) return r.mode == "manual" end)
        check(later ~= nil and mode_event(tr[later]).from == "rolling", "neutral, then a fresh pull, enters from rolling")
        note(string.format("manual_after_air: landed at step %d with the pull held; no lift for %d steps; after neutral the fresh pull lifted at step %d",
            land, 40, later))
    end)

    scenario("barspin in the air and landing", function()
        local spec = table.clone(scenarios.barspin)
        spec.options = { matrices = true }
        local out = run(spec)
        invariants("barspin", out)
        local tr = out.trace
        local start = first(tr, 1, function(r)
            local s = r.result.diagnostics.trick.state
            return s and s.bar_rotating
        end)
        check(start ~= nil, "LB with the stick back starts the bar")
        local caught = first(tr, start, function(r) return has_trick(r, "bar_caught") ~= nil end)
        check(caught ~= nil, "the bar is caught at neutral")
        local landed = first(tr, caught, function(r) return has_trick(r, "combo_landed") ~= nil end)
        check(landed ~= nil and has_trick(tr[landed], "combo_landed").barspins == 1, "one barspin lands as a combo")
        local spin = 0
        for i = start, caught do
            local bike = tr[i].result.presentation.bike
            if bike and bike.valid then spin = math.max(spin, math.abs(bike.pose.barspin)) end
            check(bike and bike.valid and #bike.matrices == 8, "the bike's eight part matrices are presented")
        end
        check(math.abs(spin - 2 * math.pi) < 1e-6, "the presented bar turns one full revolution")
        local air = first(tr, 1, function(r) return r.mode == "airborne" end)
        note(string.format("barspin: selected %s s after takeoff, caught %s s later, combo landed %s s after the catch with %d barspin; presented bar angle peak %s rad",
            fmt((start - air) * H), fmt((caught - start) * H), fmt((landed - caught) * H), has_trick(tr[landed], "combo_landed").barspins,
            fmt(spin)))
        -- Without the option a step returns the pose only, and the visual
        -- owner asks for the matrices when it places the bike.
        local quiet = run(scenarios.barspin)
        invariants("barspin_pose_only", quiet)
        local last = quiet.trace[#quiet.trace].result.presentation.bike
        check(last.valid and last.pose ~= nil and last.matrices == nil, "by default a step returns the pose only")
        local placed = quiet.ride:matrices()
        check(placed ~= nil and #placed.matrices == 8 and placed.serial == quiet.trace[#quiet.trace].result.serial,
            "Ride:matrices places the last read's pose on demand")
        check(#tr == #quiet.trace, "the same run with or without matrices")
        for i = 1, #tr do
            local a, b = tr[i].result.presentation.bike, quiet.trace[i].result.presentation.bike
            check(a.valid == b.valid, "the same presentation validity with or without matrices")
            if a.valid then
                for key, value in pairs(b.pose) do
                    check(a.pose[key] == value, "the same pose with or without matrices: " .. key)
                end
            end
        end
    end)

    scenario("hard landing bails, then recovers", function()
        local out = run(scenarios.nose_dive)
        invariants("nose_dive", out)
        local tr = out.trace
        local bailed = first(tr, 1, function(r) return r.mode == "bailed" end)
        check(bailed ~= nil, "the over-rotated landing bails")
        local b = tr[bailed].result.diagnostics.bail
        check(b.bail and b.evaluated, "bail_policy made the decision")
        local recovered = first(tr, bailed, function(r) return r.mode ~= "bailed" end)
        check(recovered ~= nil and mode_event(tr[recovered]).reason == "recovered", "bailed -> recovered")
        -- bail_policy never saw the read that leaves bailed, so it submits
        -- nothing; the next read is judged afresh, without sweep history.
        local rb = tr[recovered].result.diagnostics.bail
        check(rb.guarded == false and rb.unguarded == "recovered_unjudged" and not tr[recovered].result.commands.submit
            and tr[recovered].result.diagnostics.kernel.issue == "recovered_unjudged",
            "the recovery read is unguarded and submits nothing (recovered_unjudged)")
        local after = tr[recovered + 1]
        check(after.result.diagnostics.bail.guarded and after.plan.guard.consecutive == false and after.result.commands.submit,
            "the read after the recovery is judged, without sweep history, and submits")
        local hop = first(tr, 1, function(r) return r.result.diagnostics.kernel.hop_applied end)
        note(string.format("nose_dive: bail %s s after the hop, reason %s, region %s, closing %s m/s, alignment %s, body up y %s, COM %s m up, %d guard contacts; recovered to %s; %s m/s after 1 s of pedal",
            fmt((bailed - hop) * H), b.reason, b.region, fmt(b.closing_speed), fmt(b.alignment), fmt(tr[bailed].up_y),
            fmt(tr[bailed].position[2]),
            b.contacts or -1, tr[recovered].mode, fmt(tr[#tr].speed), cost_line(out)))
        check(tr[#tr].speed > 1, "the recovered rider rides again")
    end)

    -- One grind run reduced to its numbers.
    local function grind_summary(name, out)
        local tr = out.trace
        local hop = first(tr, 1, function(r) return r.result.diagnostics.kernel.hop_applied end)
        local lock = first(tr, 1, function(r) return grind_event(r, "lock_on") ~= nil end)
        local s = { hop = hop, lock = lock, transitions = table.concat(transitions(tr), ", ") }
        if hop then
            s.strength_speed = tr[hop + 1].velocity[2]
        end
        if lock then
            s.leave = first(tr, lock, function(r) return r.mode ~= "grinding" end) or #tr
            local exit = grind_event(tr[s.leave], "exit")
            s.exit = exit and exit.reason or "none"
            s.grind = grind_event(tr[lock], "lock_on").grind
            s.seconds = (s.leave - lock) * H
            s.contact_ticks = 0
            for i = lock, s.leave - 1 do
                local rc = tr[i].result.diagnostics.rail_contacts
                if rc and next(rc.active) then s.contact_ticks += 1 end
            end
            s.closing = -tr[lock].velocity[2]
            s.speed_on, s.speed_off = tr[lock].speed, tr[s.leave - 1].speed
            s.z_off = tr[s.leave].position[3]
            s.landed = first(tr, s.leave, function(r) return r.mode == "rolling" end)
        end
        local issues = {}
        for i = hop or 1, #tr do
            local g = tr[i].result.diagnostics.grind
            if (g.issue ~= "none" and g.issue ~= "unavailable_contact") or g.refusal ~= "none" then
                table.insert(issues, string.format("%d:%s/%s", i, g.refusal, g.issue))
            end
        end
        s.issues = table.concat(issues, " ")
        if lock then
            note(string.format("%s: takeoff %s m/s up; %s lock-on %s s after the hop at %s m/s closing; %d ticks with a peg contact; grinding %s s, exit %s at z %s; speed %s -> %s m/s; %s",
                name, fmt(s.strength_speed), s.grind, fmt((lock - hop) * H), fmt(s.closing), s.contact_ticks, fmt(s.seconds), s.exit, fmt(s.z_off),
                fmt(s.speed_on), fmt(s.speed_off), s.landed and ("rolling again at step " .. s.landed) or "not landed"))
        else
            note(string.format("%s: no lock-on (takeoff %s m/s up); grind issues %s", name, fmt(s.strength_speed or 0), s.issues))
        end
        note(name .. " transitions: " .. s.transitions)
        return s
    end

    scenario("hop onto a rail: lock-on, then off with default grind tuning", function()
        local out = run({ speed = 5, max_steps = 420, rails = rail_list(), script = flick_onto(8) })
        invariants("rail_default", out)
        local s = grind_summary("rail_default", out)
        check(s.lock ~= nil and s.grind == "double_peg", "the flick onto the rail locks on as a double peg")
        check(s.closing < 2 and s.closing > .5, "the pegs met the rail slower than grind_contact's per-step window")
        -- Measured, not a goal: with no roll balance the left-peg contact
        -- rolls the bike off the rail within a few ticks.
        check(s.contact_ticks <= 4 and s.exit == "rail_end" and s.landed ~= nil, "default tuning falls off and lands")
    end)

    scenario("hop onto a rail, held double-peg grind, exit at the end", function()
        local out = run({ speed = 5, max_steps = 420, rails = rail_list(), options = { grind = STRONG_ASSIST },
            script = flick_onto(8, feedback_rider) })
        invariants("rail_balanced", out)
        local s = grind_summary("rail_balanced", out)
        check(s.lock ~= nil and s.grind == "double_peg", "locks on as a double peg")
        check(s.seconds > .75 and s.contact_ticks > 40, "the balanced grind holds most of the rail")
        check(s.z_off > RAIL.z1 - .5, "it leaves at the rail's end")
        check(s.exit == "grounded" or s.exit == "rail_end", "it exits by the end of the rail, not by a hold")
        check(s.landed ~= nil, "and rides away")
        local tr = out.trace
        local assisted = 0
        for i = s.lock, s.leave - 1 do
            local a = tr[i].result.diagnostics.grind.assist
            if a then assisted += 1; check(M.length(a) <= 400 + 1e-9, "assist inside its cap") end
            check(tr[i].result.diagnostics.kernel.enabled == false, "no rider force control while grinding")
        end
        check(assisted > 0, "the assist torque request reached the command")
    end)

    scenario("a full R3 hop onto the rail tunnels through it", function()
        -- Five takeoff points, so the result does not hang on one step phase.
        local locked = 0
        for _, trigger in ipairs({ 2.6, 2.7, 2.8, 2.9, 3.0 }) do
            local out = run({ speed = 5, max_steps = 220, rails = rail_list(), script = r3_onto(trigger) })
            invariants("rail_r3", out)
            local s = grind_summary("rail_r3 at z " .. trigger, out)
            if s.lock then locked += 1 end
            for _, r in ipairs(out.trace) do check(r.mode ~= "grinding", "no grind without a lock-on") end
        end
        note(string.format("rail_r3: %d of 5 full hops locked on", locked))
        check(locked == 0, "a 4 m/s closing peg passes grind_contact's 35 mm window in one 60 Hz step")
    end)

    scenario("rolling into a rail at peg height never grinds", function()
        -- The pegs meet the rail while both wheels are supported: the probe
        -- is not even planned, and grind_policy refuses from the ground.
        local low = { { x = RAIL.x, y = .25, radius = .025, z0 = 2, z1 = 6 } }
        local out = run({ speed = 3, max_steps = 120, rails = low, script = function(step) return step <= 120 and {} or nil end })
        invariants("rail_rolling", out)
        for _, r in ipairs(out.trace) do
            check(r.mode ~= "grinding", "no grind from the ground")
            if r.mode == "rolling" then check(r.plan.rail == nil, "no rail probe while supported") end
        end
    end)

    scenario("rolling into a head-height bar bails from rolling", function()
        local bar = { { y = 1.40, z = 3, radius = .03, x0 = -1, x1 = 1 } }
        local out = run({ speed = 3, max_steps = 120, bars = bar, script = function(step, last)
            if last and last.mode == "bailed" then return nil end
            return {}
        end })
        invariants("clothesline", out)
        local tr = out.trace
        local bailed = first(tr, 1, function(r) return r.mode == "bailed" end)
        check(bailed ~= nil, "the bar bails the rider")
        local me = mode_event(tr[bailed])
        local b = tr[bailed].result.diagnostics.bail
        check(me.from == "rolling" and b.bail, "rolling -> bailed through bail_policy")
        for i = 1, bailed - 1 do check(tr[i].mode == "rolling", "rolling until the bar") end
        note(string.format("clothesline: rolling -> bailed at z %s, reason %s, region %s, closing %s m/s, alignment %s",
            fmt(tr[bailed].position[3]), b.reason, b.region, fmt(b.closing_speed), fmt(b.alignment)))
    end)

    scenario("a manual loop-out is a request, not a bail", function()
        local out = run({ speed = 4, max_steps = 300, script = function(step, last, st)
            if step <= 20 then return {} end
            if st.done then return step < st.done + 20 and {} or nil end
            if last and last.result.diagnostics.bail.unrealized then st.done = step end
            return { right_y = -.74 }
        end })
        invariants("loop_out", out)
        local tr = out.trace
        local at = first(tr, 1, function(r) return r.result.diagnostics.bail.unrealized ~= nil end)
        check(at ~= nil, "a deep held pull loops out")
        local u = tr[at].result.diagnostics.bail.unrealized
        check(u.source == "manual_balance" and u.reason == "loop_out", "manual_balance asked for a bail")
        check(mode_event(tr[at]).reason == "lift_ended_loop_out", "manual -> rolling on the loop-out")
        for _, r in ipairs(tr) do check(r.mode ~= "bailed", "bail_policy saw no contact, so no bail") end
        local enter = first(tr, 1, function(r) return r.mode == "manual" end)
        note(string.format("loop_out: stick -0.74 (manual %s) looped out %s s after the lift began, at pitch %s rad; reported, not bailed",
            fmt(tr[enter].result.diagnostics.input.manual), fmt((at - enter) * H), fmt(tr[at].pitch)))
    end)

    scenario("input_presets: settings compose, bindings do not", function()
        local preset = Presets.get("trigger_pedal")
        local out = run({ speed = 0, max_steps = 140, options = { input = preset:settings() }, script = function(step)
            if step <= 10 then return {} end
            if step <= 70 then return { rt = true } end
            if step <= 75 then return {} end
            if step <= 135 then return { pedal = true } end
            return nil
        end })
        invariants("preset", out)
        local tr = out.trace
        check(tr[70].speed < .05, "RT does not pedal: ride_input_mapping hardcodes the default binding")
        check(tr[135].speed > 1, "A still pedals")
        note(string.format("preset: trigger_pedal settings, RT held 1 s -> %s m/s; A held 1 s -> %s m/s (binding not composed)",
            fmt(tr[70].speed), fmt(tr[135].speed)))
    end)

    scenario("receipts gate the kernel and the hop", function()
        local NEUTRAL, HOP = {}, { r3 = true }
        local function warm(d, n)
            for _ = 1, n do
                local r = read(d, NEUTRAL)
                advance(d, r, r.result.commands.submit and r.result.commands or nil, true)
                if r.result.commands.submit then assert(d.ride:accept(r.result.commands.serial)) end
            end
        end
        local function count_hops(list)
            local n = 0
            for _, r in ipairs(list) do if r.result.commands.submit and r.result.commands.hop_event_id > 0 then n += 1 end end
            return n
        end

        -- An older command still waits for its receipt when the hop arrives:
        -- the kernel's preview applies the hop, the composer withholds the
        -- command, and nothing is retired or consumed.
        local d = driver({ speed = 4 })
        warm(d, 19)
        local older = read(d, NEUTRAL)
        check(older.result.commands.submit, "the older command is submitted")
        advance(d, older, older.result.commands, true)
        local held = read(d, HOP)
        local hk = held.result.diagnostics.kernel
        check(hk.hop_applied == true and not held.result.commands.submit and hk.issue == "receipt_pending",
            "the kernel applied the hop, but the composer withheld the command")
        local st = d.ride:status()
        check(held.result.diagnostics.hop == "held" and st.input.pending_hop and st.input.pending_hop.id == 1
            and st.input.last_retired == nil and st.kernel_consumed_hop == 0,
            "a withheld hop is neither retired nor consumed")
        advance(d, held, nil, true)
        check(d.ride:accept(older.result.commands.serial), "the older receipt arrives")
        local sent = read(d, NEUTRAL)
        check(sent.result.commands.submit and sent.result.commands.hop_event_id == 1, "the held hop is sent on the next read")
        check(d.ride:status().kernel_consumed_hop == 0, "still not consumed before its receipt")
        advance(d, sent, sent.result.commands, true)
        check(d.ride:accept(sent.result.commands.serial), "its receipt")
        st = d.ride:status()
        check(st.kernel_consumed_hop == 1 and st.input.last_retired.disposition == "accepted"
            and st.last_receipt.hop == "accepted", "accepted once, consumed once")
        local after = { sent }
        for _ = 1, 6 do
            local r = read(d, NEUTRAL)
            advance(d, r, r.result.commands.submit and r.result.commands or nil)
            if r.result.commands.submit then assert(d.ride:accept(r.result.commands.serial)) end
            table.insert(after, r)
        end
        check(count_hops(after) == 1 and after[2].mode == "airborne", "one hop impulse in all, and the bike leaves the ground")

        -- A native rejection: the candidate is dropped and the hop cancelled.
        d = driver({ speed = 4 })
        warm(d, 20)
        local committed = d.ride:status().kernel_serial
        local rejected = read(d, HOP)
        check(rejected.result.commands.submit and rejected.result.commands.hop_event_id == 1, "the hop is submitted")
        check(d.ride:reject(rejected.result.commands.serial), "and rejected")
        st = d.ride:status()
        check(st.kernel_consumed_hop == 0 and st.kernel_serial == committed and st.input.last_retired.disposition == "cancelled"
            and st.last_receipt.hop == "cancelled", "a rejected hop is cancelled and the kernel keeps its last accepted history")
        advance(d, rejected, nil, true)
        local later = {}
        for _ = 1, 10 do
            local r = read(d, NEUTRAL)
            advance(d, r, r.result.commands.submit and r.result.commands or nil, true)
            if r.result.commands.submit then assert(d.ride:accept(r.result.commands.serial)) end
            table.insert(later, r)
            check(r.mode == "rolling" and not r.result.diagnostics.kernel.hop_applied, "a rejected hop never fires later")
        end
        check(count_hops(later) == 0 and later[1].result.diagnostics.bail.residual ~= nil,
            "no hop, and the residual is known after a rejection (nothing was applied)")

        -- An unknown outcome: the hop is uncertain and the input blocks.
        d = driver({ speed = 4 })
        warm(d, 20)
        local unknown = read(d, HOP)
        check(d.ride:reject(unknown.result.commands.serial, "uncertain"), "an uncertain receipt")
        advance(d, unknown, unknown.result.commands, true)
        local blocked = read(d, NEUTRAL)
        check(d.ride:status().input.uncertain ~= nil and blocked.result.diagnostics.input.observe == "hop_outcome_uncertain"
            and blocked.result.diagnostics.bail.residual == nil, "ride_input_mapping blocks and the residual is unknown")

        -- The composer's own refusal after the kernel applied the hop: a
        -- submit path capped below the kernel's force.
        d = driver({ speed = 4, options = { command_limits = { force = 1 } } })
        for _ = 1, 20 do
            local r = read(d, NEUTRAL)
            check(not r.result.commands.submit and r.result.diagnostics.kernel.issue == "output_limit", "every command is over 1 N")
            advance(d, r, nil, true)
        end
        local capped = read(d, HOP)
        st = d.ride:status()
        check(capped.result.diagnostics.kernel.hop_applied == true and not capped.result.commands.submit
            and capped.result.diagnostics.kernel.issue == "output_limit" and capped.result.diagnostics.hop == "cancelled",
            "the kernel applied the hop and the composer refused the command")
        check(st.input.last_retired.disposition == "cancelled" and st.kernel_consumed_hop == 0 and st.outstanding == nil,
            "a refused hop is cancelled, not accepted, and the kernel never consumed it")
        note("receipts: a withheld hop is held and sent once on the next read; rejected and refused hops are cancelled; an uncertain one blocks input; the kernel consumes a hop only on accept")
    end)

    scenario("support provenance belongs to the caller", function()
        local function hop_and_spin(support)
            local spec = table.clone(scenarios.barspin)
            spec.support = support
            local out = run(spec)
            invariants("barspin_support", out)
            return out
        end
        for _, case in ipairs({ { "none", "support_owner_absent" },
            { function() return { provenance = "geometry", grounded = true } end, "support_owner_unqualified" },
            { function() return { provenance = "measured_support", grounded = true } end, "support_owner_incomplete" } }) do
            local out = hop_and_spin(case[1])
            local tr = out.trace
            local stepped = 0
            for _, r in ipairs(tr) do
                local res = r.result
                check(res.diagnostics.support.owner == case[2], "the support owner's fact is judged: " .. case[2])
                if res.diagnostics.input.active then
                    stepped += 1
                    check(res.diagnostics.trick.issue == "physical_support_unqualified" and not res.presentation.bike.valid,
                        "without a native support owner trick_runtime refuses")
                end
                for _, e in ipairs(res.events) do check(e.name ~= "trick", "no trick event without measured support") end
            end
            local air = first(tr, 1, function(r) return r.mode == "airborne" end)
            local land = air and first(tr, air, function(r) return r.mode == "rolling" end)
            check(stepped > 100 and air ~= nil and land ~= nil, "the ride still hops and lands with tricks refused")
        end
        note("support: without a measured_support owner (absent, geometry-labelled or incomplete) trick_runtime refuses every read; the ride still hops and lands")
    end)

    scenario("a refused lock-on is undone in grind_policy", function()
        -- Stubs stand in for the two policies, so the lock-on arrives where
        -- the graph refuses it. The real composer settles everything else.
        local function grind_stub(script)
            local s = { resets = 0, k = 0, phase = "idle" }
            function s:state() return { phase = self.phase, bail_latched = false, airborne_seen = false } end
            function s:reset() self.resets += 1; self.phase = "idle" end
            function s:step(o)
                self.k += 1
                local want = script(self.k, o)
                local out = { valid = true, state = "idle", grind = "none", side = "none", classified = "none",
                    refusal = "none", issue = "none", exit_reason = "none", events = {}, hop_request = false }
                if want == "lock_on" then
                    self.phase = "locked"
                    out.state, out.grind, out.side = "locked", "double_peg", "left"
                    table.insert(out.events, { name = "lock_on", grind = "double_peg", side = "left", state = "locked" })
                elseif want == "locked" then
                    self.phase = "locked"
                    out.state, out.grind, out.side = "locked", "double_peg", "left"
                end
                return out
            end
            return s
        end
        local function balancing_stub()
            local b = { cancelled = 0 }
            function b:status() return { state = "balancing", kind = "manual", armed = false, end_reason = "none" } end
            function b:step() return { valid = true, state = "balancing", kind = "manual", manual = .3, nose_manual = 0,
                issue = "none", lift = .2, target = .2, balance = 0, armed = false } end
            function b:cancel() self.cancelled += 1 end
            return b
        end
        -- In a manual: a lock-on, then a policy that claims to stay locked.
        local d = driver({ speed = 4 })
        local grind = grind_stub(function(k) return (k == 6 and "lock_on") or (k == 7 and "locked") or "idle" end)
        d.ride._grind, d.ride._balance = grind, balancing_stub()
        local trace = {}
        for _ = 1, 9 do
            local r = read(d, {})
            advance(d, r, r.result.commands.submit and r.result.commands or nil, true)
            if r.result.commands.submit then assert(d.ride:accept(r.result.commands.serial)) end
            table.insert(trace, r)
        end
        check(trace[5].mode == "manual", "the stubbed balance holds a manual")
        local refused_on = grind_event(trace[6], "lock_on_refused")
        check(refused_on ~= nil and refused_on.reason == "manual_to_grinding_refused" and grind_event(trace[6], "lock_on") == nil,
            "the lock-on is reported refused, not as a lock_on")
        check(trace[6].mode == "manual" and trace[7].mode == "manual" and grind.resets == 2,
            "the manual continues and grind_policy is reset on both reads")
        check(trace[7].result.diagnostics.grind.refused == "manual_to_grinding_refused", "a lingering lock is refused again")
        for _, r in ipairs(trace) do check(r.mode ~= "grinding", "never grinding without an admitted lock-on") end
        -- In the air: a policy that reports locked without a lock_on event.
        d = driver({ speed = 4 })
        grind = grind_stub(function(k) return k >= 25 and k <= 27 and "locked" or "idle" end)
        d.ride._grind = grind
        trace = {}
        for step = 1, 30 do
            local r = read(d, step == 21 and { r3 = true } or {})
            advance(d, r, r.result.commands.submit and r.result.commands or nil)
            if r.result.commands.submit then assert(d.ride:accept(r.result.commands.serial)) end
            table.insert(trace, r)
        end
        check(trace[25].mode == "airborne" and trace[25].result.diagnostics.grind.refused == "grind_without_lock_on"
            and grind.resets >= 3, "airborne -> grinding needs this read's lock_on")
        for _, r in ipairs(trace) do check(r.mode ~= "grinding", "no grind from a lingering lock") end
        note("grind refusal: a lock-on inside a manual is reported as lock_on_refused and grind_policy is reset; a lock without a lock_on event never enters grinding")
    end)

    scenario("a first-read bail is an edge of the graph", function()
        local bar = { { y = 1.40, z = 3, radius = .03, x0 = -1, x1 = 1 } }
        local out = run({ speed = 3, z = 2.77, max_steps = 3, bars = bar, script = function() return {} end })
        invariants("first_read_bail", out)
        local me = mode_event(out.trace[1])
        check(me ~= nil and me.from == "none" and me.to == "bailed" and Composer.allowed("none", "bailed"),
            "none -> bailed on a first-read bail, inside the graph")
        note(string.format("first-read bail: none -> bailed (%s) at z %s", tostring(out.trace[1].result.diagnostics.bail.reason),
            fmt(out.trace[1].position[3])))
    end)

    scenario("one plan per read; stale reads move nothing", function()
        local d = driver({ speed = 4 })
        for _ = 1, 10 do
            local r = read(d, {})
            advance(d, r, r.result.commands.submit and r.result.commands or nil)
            if r.result.commands.submit then assert(d.ride:accept(r.result.commands.serial)) end
        end
        local tick = next_tick(d, {})
        local first_plan = d.ride:plan(tick)
        local camera = d.ride:status().camera
        check(rawequal(d.ride:plan(tick), first_plan), "a repeated plan for one read returns the same plan")
        check(d.ride:status().camera.yaw == camera.yaw, "and does not step the camera again")
        local r = d.ride:step(tick)
        check(r.valid and r.issue == "none", "the read steps")
        if r.commands.submit then assert(d.ride:accept(r.commands.serial)) end
        camera = d.ride:status().camera
        for _ = 1, 3 do
            local dup = next_tick(d, {}, { duplicate = true })
            local plan = d.ride:plan(dup)
            check(plan.valid and plan.issue == "duplicate_read" and plan.camera == nil and plan.rail == nil and plan.guard == nil,
                "a duplicate plans nothing")
            check(d.ride:witness(dup).available == false, "and has no witness")
            local s = d.ride:step(dup)
            check(s.valid and s.issue == "duplicate_read" and not s.commands.submit, "and steps nothing")
        end
        local now = d.ride:status().camera
        check(now.yaw == camera.yaw and now.distance == camera.distance and now.height == camera.height
            and now.pivot == camera.pivot and now.pull == camera.pull and now.fov == camera.fov,
            "three duplicate reads leave the camera exactly where it was")
    end)

    scenario("one read carries one batch per lane, inside its allowance", function()
        check(Composer.batch_rays == 32 and Composer.core_batches == 4, "a batch holds 32 rays; the composer allows four batches")
        -- The composer writes Core's allowance as a literal so that requiring
        -- it does not load Core. This pins the literal to Core's export.
        check(Composer.core_batches == Core.probe_batches_per_serial,
            "Composer.core_batches equals bike_runtime_core's probe_batches_per_serial")
        -- The arithmetic of merging: only the wheels and the rail together
        -- fill one batch. The rail and the smallest guard (8 rays) do not,
        -- and the witnesses depend on the guard batch's rows.
        check(Composer.wheel_rays + Composer.rail_rays == Composer.batch_rays and Composer.rail_rays + 8 > Composer.batch_rays,
            "wheels + rail fill 32; rail + guard exceed it")
        local function lanes(grinding)
            local guard, rail, witness = { name = "guard", rays = 14 }, { name = "rail", rays = Composer.rail_rays }, { name = "witness" }
            return grinding and { rail, guard, witness } or { guard, rail, witness }
        end
        local l = Composer.layout(1, lanes())
        check(l.batches == 1 and next(l.lanes) == nil and l.refused.guard == "batch_allowance"
            and l.refused.rail == "batch_allowance" and l.refused.witness == "batch_allowance",
            "an explicit one-batch allowance carries only the wheels: every composer lane is refused")
        l = Composer.layout(2, lanes())
        check(l.batches == 2 and l.lanes.guard == 2 and l.refused.rail == "batch_allowance"
            and l.refused.witness == "batch_allowance", "two batches: the wheels and the guard")
        l = Composer.layout(2, lanes(true))
        check(l.lanes.rail == 2 and l.refused.guard == "batch_allowance", "two while grinding: the wheels and the rail")
        l = Composer.layout(3, lanes())
        check(l.batches == 3 and l.lanes.guard == 2 and l.lanes.rail == 3 and l.refused.witness == "batch_allowance",
            "three: wheels, guard, rail, and no batch left for witnesses")
        l = Composer.layout(4, lanes())
        check(l.batches == 4 and l.lanes.witness == 4 and next(l.refused) == nil, "four carry every lane")
        l = Composer.layout(4, { { name = "wide", rays = Composer.batch_rays + 1 }, { name = "empty", rays = 0 },
            { name = "rail", rays = Composer.rail_rays } })
        check(l.refused.wide == "batch_rays" and l.refused.empty == "batch_rays" and l.lanes.rail == 2,
            "a lane outside 1 to 32 rays is refused, not split")
        for _, bad in ipairs({ 0, -1, 1.5, 65, "2", true }) do
            check(not pcall(Composer.new, { batches_per_read = bad }), "batches_per_read " .. tostring(bad) .. " is refused")
        end
        check(Composer.new():status().batch_allowance == Core.probe_batches_per_serial, "by default a read gets Core's four batches")

        -- An explicit one-batch allowance on the rail flick: only the wheels
        -- is planned, every refusal says why, and with no guard lane no read
        -- is guarded, so none submits anything. The constructed ground holds
        -- the bike up, so it coasts and never leaves the ground.
        local core = run({ speed = 5, max_steps = 420, rails = rail_list(), script = flick_onto(8), options = { batches_per_read = 1 } })
        invariants("rail_core_batches", core)
        local flicked = 0
        for _, r in ipairs(core.trace) do
            local res = r.result
            check(r.plan.batch_allowance == 1 and r.plan.batches == 1 and #r.lanes == 1 and r.plan.rail == nil
                and r.plan.guard == nil and r.plan.witness_batch == false, "one-batch allowance: the wheel batch only")
            check(r.plan.guard_issue == "batch_allowance" and res.diagnostics.queries.guard == "batch_allowance"
                and res.diagnostics.bail.guard == "batch_allowance" and res.diagnostics.bail.evaluated == false,
                "the guard is refused and bail_policy is not stepped as if clear")
            check(not res.commands.submit and res.commands.force == nil and res.commands.torque == nil
                and res.commands.hop_impulse == nil and res.diagnostics.kernel.issue == "batch_allowance",
                "one-batch allowance: an unguarded read submits no force, torque or impulse")
            if res.diagnostics.kernel.hop_applied then
                flicked += 1
                check(res.diagnostics.hop == "cancelled", "the flick's hop is cancelled, never sent")
            end
            check(res.diagnostics.support.any and r.mode ~= "airborne" and r.mode ~= "grinding"
                and grind_event(r, "lock_on") == nil, "nothing pushes the bike off the ground")
        end
        check(flicked >= 1, "the flick's hop reached the kernel and was withheld")
        -- An unsupported read under one batch: the rail is refused too.
        local up = driver({ speed = 5, options = { batches_per_read = 1 } })
        up.body = M.copy(up.body)
        up.body.center_of_mass[2] += 3
        local air = read(up, {})
        check(air.result.diagnostics.support.ground_known and not air.result.diagnostics.support.any
            and air.plan.rail == nil and air.plan.rail_issue == "batch_allowance"
            and air.result.diagnostics.grind.rows == "batch_allowance" and not air.result.commands.submit,
            "an unsupported read under one batch: the rail is refused as batch_allowance and nothing is submitted")
        local bar = { { y = 1.40, z = 3, radius = .03, x0 = -1, x1 = 1 } }
        local through = run({ speed = 3, max_steps = 90, bars = bar, options = { batches_per_read = 1 }, script = function() return {} end })
        invariants("clothesline_core_batches", through)
        for _, r in ipairs(through.trace) do
            check(r.mode ~= "bailed" and r.result.diagnostics.bail.guard == "batch_allowance"
                and not r.result.commands.submit, "no guard batch, so no bail and nothing submitted")
        end
        check(through.trace[#through.trace].position[3] > 3.5, "the coasting bike passes the bar the guard could not see")
        note(string.format("batches: with an explicit one-batch allowance no read is guarded, so none of the rail flick's %d reads or the head-height bar's %d submits anything (batch_allowance); the flick's hop is cancelled, the bike coasts on the constructed ground, never locks on, and passes the bar at z %s without a bail",
            #core.trace, #through.trace, fmt(through.trace[#through.trace].position[3])))

        -- Two and three batches: what each lane gets.
        local function tally(out)
            local t = { witness_refused = 0, rail_planned = 0, guard_priority = 0, rail_refused = 0, guard_available = 0,
                withheld = 0, policy_refused = 0,
                lock = first(out.trace, 1, function(r) return grind_event(r, "lock_on") ~= nil end),
                bail = first(out.trace, 1, function(r) return r.mode == "bailed" end) }
            for _, r in ipairs(out.trace) do
                local q = r.result.diagnostics.queries
                local b = r.result.diagnostics.bail
                if q and q.witness == "witness_batch_allowance" then
                    t.witness_refused += 1
                    -- The witnesses that did not fit leave the read unjudged,
                    -- so it fails closed.
                    check(b.guarded == false and b.unguarded == "witness_batch_allowance" and not r.result.commands.submit,
                        "a read whose witnesses had no batch submits nothing")
                end
                if r.plan.rail then t.rail_planned += 1 end
                if r.plan.rail_issue == "guard_priority" then t.guard_priority += 1 end
                if r.plan.rail_issue == "batch_allowance" then t.rail_refused += 1 end
                if b and b.guard == "available" then t.guard_available += 1 end
                if b and b.guarded == false then t.withheld += 1 end
                if b and b.evaluated and not b.valid then t.policy_refused += 1 end
            end
            t.reason = t.bail and out.trace[t.bail].result.diagnostics.bail.reason or nil
            return t
        end
        local function line(name, out, t)
            local b = t.bail and out.trace[t.bail].result.diagnostics.bail
            note(string.format("batches %s: %d reads, guard available on %d, witness refused (witness_batch_allowance) on %d, bail_policy refused %d, %d unguarded reads submitted nothing, rail planned on %d, refused (batch_allowance) on %d, yielded (guard_priority) on %d; %s; %s",
                name, #out.trace, t.guard_available, t.witness_refused, t.policy_refused, t.withheld, t.rail_planned,
                t.rail_refused, t.guard_priority, t.lock and ("lock-on at step " .. t.lock) or "no lock-on",
                b and string.format("bail at step %d (%s, %s)", t.bail, tostring(b.reason), tostring(b.region)) or "no bail"))
        end
        local measured = {}
        for _, n in ipairs({ 2, 3 }) do
            local rail = run({ speed = 5, max_steps = 420, rails = rail_list(), script = flick_onto(8),
                options = { batches_per_read = n } })
            invariants("rail_batches_" .. n, rail)
            local clothes = run({ speed = 3, max_steps = 120, bars = bar, options = { batches_per_read = n },
                script = function(step, last) if last and last.mode == "bailed" then return nil end return {} end })
            invariants("clothesline_batches_" .. n, clothes)
            local dive = run({ speed = 4, max_steps = 140, options = { batches_per_read = n }, script = function(step, last)
                if last and last.mode == "bailed" then return nil end
                if step == 21 then return { r3 = true } end
                if step < 24 then return {} end
                return { left_y = 1 }
            end })
            invariants("nose_dive_batches_" .. n, dive)
            measured[n] = { rail = tally(rail), clothes = tally(clothes), dive = tally(dive) }
            line("rail flick at " .. n, rail, measured[n].rail)
            line("head-height bar at " .. n, clothes, measured[n].clothes)
            line("nose dive at " .. n, dive, measured[n].dive)
        end
        -- Two batches: the guard takes the only one past the wheels, so the
        -- rail is never planned outside a grind and no witness has a batch.
        local two = measured[2]
        check(two.rail.rail_planned == 0 and two.rail.rail_refused > 10 and two.rail.lock == nil,
            "two batches: no rail probe, so no lock-on")
        check(two.clothes.witness_refused > 0 and two.clothes.bail == nil and two.dive.witness_refused > 0
            and two.dive.bail == nil, "two batches: refused witnesses leave the bar and the nose dive unjudged")
        -- Three: guard and rail share the read, and the witnesses wait for
        -- a read without the rail. In this world that is enough.
        local three = measured[3]
        check(three.rail.lock ~= nil and three.rail.witness_refused > 0 and three.rail.guard_priority > 0,
            "three batches: the flick locks on, with witnesses refused while the rail holds a batch")
        check(three.clothes.reason == "swept_body_crossing" and three.dive.reason == "hard_rider_contact",
            "three batches: the bar and the nose dive bail as with every lane carried")
    end)

    scenario("the rail batch is the raw probe_batch on this read's epoch", function()
        local function rail_run(hook)
            return run({ speed = 5, max_steps = 420, rails = rail_list(), script = flick_onto(8),
                hooks = hook and function() return { rail = hook } end or nil })
        end
        local control = rail_run(nil)
        local control_lock = first(control.trace, 1, function(r) return grind_event(r, "lock_on") ~= nil end)
        check(control_lock ~= nil and control.trace[control_lock].result.diagnostics.grind.rows == "available",
            "control: the raw batch on this read's epoch decodes and locks on")
        -- The previous read's epoch on this read's rows: a stale batch.
        local previous, probe_reasons = nil, {}
        local stale = rail_run(function(tick, plan, raw)
            local b = table.clone(raw)
            b.epoch = previous or newproxy()
            previous = tick.sample.epoch
            probe_reasons[Probe.decode(plan.rail, b).reason or "available"] = true
            return b
        end)
        invariants("rail_stale_epoch", stale)
        local refused = 0
        for _, r in ipairs(stale.trace) do
            if r.plan.rail then
                refused += 1
                check(r.result.diagnostics.grind.rows == "rail_epoch_mismatch", "a rail batch on another epoch is refused")
            end
            check(r.mode ~= "grinding" and grind_event(r, "lock_on") == nil, "and grinds nothing")
        end
        check(refused > 10 and probe_reasons.epoch_mismatch and not probe_reasons.available,
            "rail_probe refuses the same batches on its plan's epoch")
        -- A real Contact.decode copy of this read's own raw rows.
        local copies = 0
        local copied = rail_run(function(tick, plan, raw)
            local c = contact_copy(tick, plan.rail.rays, raw)
            check(c.valid and c.status == "available" and c.query.epoch_matches == true and rawget(c, "epoch") == nil,
                "a Contact.decode copy matched to this read carries no epoch")
            check(Probe.decode(plan.rail, c).reason == "epoch_mismatch", "rail_probe refuses a copy on its plan's epoch")
            copies += 1
            return c
        end)
        invariants("rail_contact_copy", copied)
        for _, r in ipairs(copied.trace) do
            if r.plan.rail then
                check(r.result.diagnostics.grind.rows == "rail_batch_contact_copy", "a Contact.decode copy is refused by name")
            end
            check(r.mode ~= "grinding" and grind_event(r, "lock_on") == nil, "and grinds nothing")
        end
        check(copies > 10, "copies were offered on every planned rail read")
        -- The guard lane keeps the same rule.
        local d = driver({ speed = 4 })
        for _ = 1, 5 do
            local r = read(d, {})
            advance(d, r, r.result.commands.submit and r.result.commands or nil, true)
            if r.result.commands.submit then assert(d.ride:accept(r.result.commands.serial)) end
        end
        local tick = next_tick(d, {})
        local plan = d.ride:plan(tick)
        tick.guard = batch(d.world, plan.guard.rays, newproxy())
        local w = d.ride:witness(tick)
        local r = d.ride:step(tick)
        check(not w.available and w.reason == "guard_epoch_mismatch" and r.diagnostics.bail.guard == "guard_epoch_mismatch"
            and r.diagnostics.bail.evaluated == false, "a guard batch on another epoch is refused")
        note(string.format("rail source: raw rows lock on at step %d; %d stale-epoch batches refused rail_epoch_mismatch and %d Contact.decode copies refused rail_batch_contact_copy (rail_probe: epoch_mismatch for both); no lock-on in either",
            control_lock, refused, copies))
    end)

    scenario("a read without a qualified Framev1 plans no guard and submits nothing", function()
        local d = driver({ speed = 4 })
        local trace = {}
        local function step(input, hooks)
            local r = read(d, input, hooks)
            advance(d, r, r.result.commands.submit and r.result.commands or nil, true)
            if r.result.commands.submit then assert(d.ride:accept(r.result.commands.serial)) end
            table.insert(trace, r)
            return r
        end
        for _ = 1, 10 do step({}) end
        local unbound = {
            { "input_source_absent", function(t) t.input = nil end },
            { "input_source_unavailable", function(t) t.input.input_ok = false end },
            { "input_source_unavailable", function(t) t.input.lease_handle = "lease" end },
            { "frame_invalid_source", function(t) t.input.sample.sequence = "0" end },
            { "frame_unfocused", function(t) t.gates.focused = false end },
            { "frame_menu_open", function(t) t.gates.menu_open = true end },
        }
        for _, case in ipairs(unbound) do
            local why = case[1]
            local r = step({}, { tick = case[2] })
            local res = r.result
            check(r.plan.guard == nil and r.plan.guard_issue == "bail_guard_unbound" and r.plan.guard_binding == why,
                why .. ": no guard plan")
            check(not r.witness.available and r.witness.reason == "bail_guard_unbound" and r.witness_rays == 0,
                why .. ": no witness")
            check(not res.commands.submit and res.commands.force == nil and res.commands.torque == nil
                and res.commands.hop_impulse == nil and res.diagnostics.kernel.issue == "bail_guard_unbound",
                why .. ": no force, torque or impulse leaves")
            check(res.diagnostics.queries.guard == "bail_guard_unbound" and res.diagnostics.queries.guard_binding == why
                and res.diagnostics.bail.guard == "bail_guard_unbound" and res.diagnostics.bail.evaluated == false,
                why .. ": the guard is reported unbound and bail_policy is not stepped")
            -- The next bound read plans its guard again, with no history from
            -- the read that had none; the one after it has history again.
            local back = step({})
            check(back.plan.guard ~= nil and back.plan.guard_binding == "bound" and back.plan.guard.consecutive == false
                and back.result.commands.submit, why .. ": the next bound read is guarded, without sweep history")
            local again = step({})
            check(again.plan.guard.consecutive == true and again.result.commands.submit,
                why .. ": its successor lends history")
        end
        -- A hop the kernel applies on an unbound read is cancelled, never sent.
        local older = read(d, {})
        check(older.result.commands.submit, "the older command is submitted")
        advance(d, older, older.result.commands, true)
        table.insert(trace, older)
        local held = read(d, { r3 = true })
        check(not held.result.commands.submit and held.result.diagnostics.kernel.issue == "receipt_pending"
            and held.result.diagnostics.hop == "held", "the hop is held behind the older receipt")
        advance(d, held, nil, true)
        table.insert(trace, held)
        assert(d.ride:accept(older.result.commands.serial))
        local blind = step({}, { tick = function(t) t.input = nil end })
        local st = d.ride:status()
        check(blind.result.diagnostics.kernel.hop_applied == true and not blind.result.commands.submit
            and blind.result.diagnostics.kernel.issue == "bail_guard_unbound" and blind.result.diagnostics.hop == "cancelled",
            "the kernel applied the held hop on an unbound read; nothing is submitted and the hop is cancelled")
        check(st.input.last_retired.disposition == "cancelled" and st.kernel_consumed_hop == 0 and st.outstanding == nil,
            "the hop is retired cancelled and never consumed")
        for _ = 1, 5 do
            local r = step({})
            check(r.result.commands.submit and r.result.commands.hop_event_id == 0 and r.mode == "rolling",
                "the cancelled hop never fires later")
        end
        invariants("unbound_reads", { trace = trace, costs = {} }, true)
        note(string.format("unbound: %d reads without a qualified Framev1 (%s) planned no guard and submitted nothing; a hop applied by the kernel on one was cancelled",
            #unbound + 1, "no source, an unavailable source, a lease that is not userdata, a source frame_identity refuses, unfocused, menu open"))
    end)

    -- A constructed read of one fixed body on its own composer, every lane
    -- cast here so a case can edit or replace any batch before the composer
    -- reads it (edit.guard and edit.witness return a replacement or nil).
    -- The body lies on its right side 5 m up (body up {-1, 0, 0}) at rest, so
    -- its guard plan is eight down rays and nothing in the world is near it
    -- except what a case puts in a row.
    local SIDE = { 0, 0, math.sqrt(.5), math.sqrt(.5) }
    local function posed()
        local body, wheels = World.place(World.terrain.flat(), { speed = 0 })
        body = M.copy(body)
        body.orientation, body.center_of_mass = SIDE, { 0, 5, 0 }
        body.linear_velocity, body.angular_velocity = { 0, 0, 0 }, { 0, 0, 0 }
        local p = { ride = Composer.new({ batches_per_read = LAB_BATCHES }), world = { rails = {} }, k = 0,
            lease = newproxy(), handle = newproxy() }
        function p.read(edit)
            edit = edit or {}
            p.k += 1
            local sample = sample_of(body, tostring(700 + p.k), (p.k - 1) * H)
            local seen = measured(sample)
            local rows = wheel_rows(p.world, seen)
            local tick = { sample = sample, body_handle = p.handle, owner = "mount-1",
                wheels = { M.copy(wheels[1]), M.copy(wheels[2]) }, wheel_rows = rows, support = support_owner(seen, rows),
                wheel_query = { epoch_matches = true, accounting_known = true, budget_exhausted = false,
                    local_actor_excluded = true, owned_bodies_excluded = true },
                gates = { focused = true, menu_open = false },
                input = { input_ok = true, lease_handle = p.lease, generation = 1, sample = { user = 0, packet = p.k,
                    sequence = "7", source_epoch = "11", context_generation = "13",
                    observation_serial = tostring(1000 + p.k), observed_ms = tostring(50000 + 17 * p.k), pad = pad_of({}) } } }
            if edit.tick then edit.tick(tick) end
            local plan = p.ride:plan(tick)
            if plan.rail then tick.rail = batch(p.world, plan.rail.rays, sample.epoch) end
            if plan.guard then
                tick.guard = batch(p.world, plan.guard.rays, sample.epoch)
                if edit.guard then tick.guard = edit.guard(tick.guard, plan, seen) or tick.guard end
            end
            local w = p.ride:witness(tick)
            if #w.rays > 0 then
                tick.witness = batch(p.world, w.rays, sample.epoch)
                if edit.witness then tick.witness = edit.witness(tick.witness, w, seen) or tick.witness end
            end
            local result = p.ride:step(tick)
            if result.commands.submit then assert(p.ride:accept(result.commands.serial)) end
            return { result = result, plan = plan, witness = w, tick = tick, seen = seen }
        end
        return p
    end
    -- The finite face of bail_guard_tests' review fixture: guard 3 (the right
    -- grip) above a tiny face whose plane is tangent to the sphere, centred on
    -- the down ray 24 mm from the sphere's perpendicular foot. A witness row
    -- may lie up to 25 mm off its own ray, so a witness can report that same
    -- point beside the witness line.
    local EDGE = 3
    local edge_r = Guard.guards[EDGE].radius
    local edge_a = math.atan(.024 / edge_r)
    local edge_n = { math.sin(edge_a), math.cos(edge_a), 0 }
    local edge_gap = math.sqrt(edge_r * edge_r + .024 * .024) - edge_r
    local function edge_center(seen)
        return M.add(seen.center_of_mass, M.turn(M.normalized(seen.orientation), M.sub(Guard.guards[EDGE].center, Geometry.com)))
    end
    local function edge_face(seen) return M.sub(edge_center(seen), { 0, edge_r / math.cos(edge_a), 0 }) end
    local function edge_foot(seen) return M.sub(edge_center(seen), M.mul(edge_n, edge_r)) end
    local function measured_row(point, ray)
        local from, to = from_vector(ray.from), from_vector(ray.to)
        local delta = M.sub(to, from)
        return { status = "hit", position = v3(point), fraction = M.dot(M.sub(point, from), delta) / M.dot(delta, delta),
            motion = "measured", normal_available = true, normal = v3(edge_n), surface_velocity_available = true,
            surface_velocity = vector.create(0, 0, 0) }
    end
    local function face_hit(b, plan, seen)
        for i, slot in ipairs(plan.guard.slots) do
            if slot.guard == EDGE and slot.kind == "down" then b.rays[i] = measured_row(edge_face(seen), plan.guard.rays[i]) end
        end
        return b
    end
    local function witness_at(point)
        return function(b, w, seen)
            if point then b.rays[1] = measured_row(point(seen), w.rays[1]) else b.rays[1] = { status = "clear" } end
            return b
        end
    end
    local function unmeasured(row)
        row.surface_velocity_available, row.surface_velocity, row.motion = false, nil, "unknown"
    end
    -- An unguarded read submits no force, torque or hop impulse, and its
    -- withheld issue is the guard's reason.
    local function withheld(r, reason)
        local c = r.result.commands
        return not c.submit and c.force == nil and c.torque == nil and c.hop_impulse == nil
            and r.result.diagnostics.kernel.issue == reason and r.result.diagnostics.bail.guarded == false
            and r.result.diagnostics.bail.unguarded == reason
    end
    -- The packet's batch edits, each with the reason the composer names
    -- (and, as a fourth entry, the guard's own reason when it differs).
    local guard_edits = {
        { "wrong epoch", function(b) b.epoch = newproxy() end, "guard_epoch_mismatch", "query_epoch_mismatch" },
        { "missing epoch", function(b) b.epoch = nil end, "guard_epoch_mismatch", "query_epoch_mismatch" },
        { "actor exclusion false", function(b) b.local_actor_excluded = false end, "guard_exclusion_unqualified" },
        { "owned exclusion false", function(b) b.owned_bodies_excluded = false end, "guard_exclusion_unqualified" },
        { "missing native_casts", function(b) b.native_casts = nil end, "malformed_available_batch" },
        { "zero native_casts", function(b) b.native_casts = 0 end, "malformed_available_batch" },
        { "available with a reason", function(b) b.reason = "available_but_unqualified" end, "malformed_available_batch" },
        { "unmeasured surface motion", function(b)
            for _, row in ipairs(b.rays) do if row.status == "hit" then unmeasured(row) end end
        end, "guard_measurements_unavailable" },
    }
    local witness_edits = {
        { "wrong epoch", function(b) b.epoch = newproxy() end, "witness_epoch_mismatch", "guard_witness_epoch_mismatch" },
        { "missing epoch", function(b) b.epoch = nil end, "witness_epoch_mismatch", "guard_witness_epoch_mismatch" },
        { "actor exclusion false", function(b) b.local_actor_excluded = false end, "guard_exclusion_unqualified" },
        { "owned exclusion false", function(b) b.owned_bodies_excluded = false end, "guard_exclusion_unqualified" },
        { "missing native_casts", function(b) b.native_casts = nil end, "malformed_available_batch" },
        { "available with a reason", function(b) b.reason = "available_but_unqualified" end, "malformed_available_batch" },
        { "unmeasured surface motion", function(b) unmeasured(b.rays[1]) end, "guard_measurements_unavailable" },
    }

    scenario("the guard packet's counterexamples are refused through the composer", function()
        local function near(a, b, tolerance) return math.abs(a - b) <= tolerance end
        -- Controls on the composer's own bound plan: the tiny face's witness
        -- at the foot is contact and seeds a severe tilt; the packet's
        -- finite-edge counterexamples (a witness beside its line, a witness
        -- that misses) cannot.
        local foot = posed().read({ guard = face_hit, witness = witness_at(edge_foot) })
        local fb = foot.result.diagnostics.bail
        check(foot.plan.guard_binding == "bound" and #foot.plan.guard.rays == 8 and #foot.witness.rays == 1
            and foot.witness.slots[1].guard == EDGE, "the tilted face under the grip needs one witness")
        local fd = Guard.decode(foot.witness, foot.tick.witness)
        check(fd.available and fd.contacts[EDGE].hit and near(fd.contacts[EDGE].separation, 0, 1e-5),
            "control: a witness at the foot is contact at the sphere's radius")
        check(fb.evaluated and fb.guard == "available" and fb.contacts == 1 and not fb.bail and fb.tilt_steps == 1,
            "control: through the composer it seeds a severe tilt (body up {-1, 0, 0})")
        check(fb.guarded and foot.result.commands.submit, "control: the judged read submits its command")
        local beside = posed().read({ guard = face_hit, witness = witness_at(edge_face) })
        local bd = Guard.decode(beside.witness, beside.tick.witness)
        local bb = beside.result.diagnostics.bail
        check(edge_gap > .005 and bd.available and bd.contacts[EDGE].hit and near(bd.contacts[EDGE].separation, edge_gap, 1e-5),
            "finite edge 1: a witness beside its line keeps the measured point's own distance")
        check(bb.evaluated and bb.contacts == 1 and not bb.bail and bb.tilt_steps == 0,
            "finite edge 1: through the composer its extended plane cannot seed a tilt")
        local miss = posed().read({ guard = face_hit, witness = witness_at(nil) })
        local md = Guard.decode(miss.witness, miss.tick.witness)
        local mb = miss.result.diagnostics.bail
        check(md.available and not md.contacts[EDGE].hit and md.counts.unwitnessed == 1 and mb.evaluated
            and mb.contacts == 0 and mb.tilt_steps == 0, "finite edge 2: a witness that misses the tiny face is no contact")
        check(bb.guarded and beside.result.commands.submit and mb.guarded and miss.result.commands.submit,
            "finite edges 1 and 2: judged without the false contact, so they submit")

        -- The first batch. The composer's own source check names an epoch
        -- refusal; the plan it made is bound, so the guard refuses the same
        -- batch on its own (direct).
        local first = guard_edits
        for _, case in ipairs(first) do
            local r = posed().read({ guard = function(b, plan, seen) face_hit(b, plan, seen); case[2](b); return b end,
                witness = witness_at(edge_foot) })
            local b = r.result.diagnostics.bail
            check(r.plan.guard_binding == "bound" and not r.witness.available and r.witness.reason == case[3]
                and b.guard == case[3] and b.evaluated == false and not b.bail,
                case[1] .. " in the guard batch is refused through the composer as " .. case[3])
            check(withheld(r, case[3]), case[1] .. " in the guard batch: nothing is submitted")
            local direct = Guard.witness(r.plan.guard, r.tick.guard)
            check(not direct.available and direct.reason == (case[4] or case[3]),
                case[1] .. ": the composer's bound plan refuses it in the guard too")
        end
        -- The witness batch, after an untouched guard batch with the face.
        local second = witness_edits
        for _, case in ipairs(second) do
            local r = posed().read({ guard = face_hit,
                witness = function(b, w, seen) witness_at(edge_foot)(b, w, seen); case[2](b); return b end })
            local b = r.result.diagnostics.bail
            check(r.witness.available and #r.witness.rays == 1 and b.guard == case[3] and b.evaluated == false
                and not b.bail, case[1] .. " in the witness batch is refused through the composer as " .. case[3])
            check(withheld(r, case[3]), case[1] .. " in the witness batch: nothing is submitted")
            local direct = Guard.decode(r.witness, r.tick.witness)
            check(not direct.available and direct.reason == (case[4] or case[3]),
                case[1] .. ": the composer's witness plan refuses it in the guard too")
        end
        -- A stale batch relabelled: the previous read's own raw batches,
        -- offered for the next read of the same pose (the same eight rays).
        local p = posed()
        local before = p.read({ guard = face_hit, witness = witness_at(edge_foot) })
        check(before.result.diagnostics.bail.evaluated, "the previous read's batches decode for that read")
        local stale = p.read({ guard = function() return before.tick.guard end })
        check(#stale.plan.guard.rays == #before.plan.guard.rays and stale.plan.guard.consecutive
            and stale.result.diagnostics.bail.guard == "guard_epoch_mismatch" and not stale.result.diagnostics.bail.evaluated
            and withheld(stale, "guard_epoch_mismatch"),
            "stale guard batch: the previous read's batch is refused through the composer and nothing is submitted")
        check(Guard.witness(stale.plan.guard, before.tick.guard).reason == "query_epoch_mismatch",
            "stale guard batch: the bound plan refuses it in the guard too")
        -- The stale read was not judged, so this plan has no sweep history.
        local stale_witness = p.read({ guard = face_hit, witness = function() return before.tick.witness end })
        check(stale_witness.result.diagnostics.bail.guard == "witness_epoch_mismatch"
            and not stale_witness.result.diagnostics.bail.evaluated and not stale_witness.plan.guard.consecutive
            and Guard.decode(stale_witness.witness, before.tick.witness).reason == "guard_witness_epoch_mismatch"
            and withheld(stale_witness, "witness_epoch_mismatch"),
            "stale witness batch: refused through the composer and by the guard, and nothing is submitted")
        -- No coherent frame: the same read without its selected source.
        local blind = posed().read({ tick = function(t) t.input = nil end })
        check(blind.plan.guard == nil and blind.plan.guard_binding == "input_source_absent"
            and blind.result.diagnostics.bail.guard == "bail_guard_unbound" and withheld(blind, "bail_guard_unbound"),
            "no coherent frame: no guard plan and nothing submitted")
        note(string.format("guard counterexamples through the composer: finite face at the foot seeds a tilt (control); beside the witness line separation %.4f m > 0.005, no tilt; witness miss, no contact; the three judged reads submit; %d guard-batch and %d witness-batch edits and both stale batches refused and nothing submitted, each also refused by the composer's bound plan in the guard; no frame, no plan, no submit",
            bd.contacts[EDGE].separation, #first, #second))
    end)

    scenario("an unguarded read submits no force, torque or hop impulse", function()
        -- A rider rolling at 4 m/s presses R3 on a read whose guard rows the
        -- composer cannot judge. The control is the same read judged: the
        -- tiny face under the right grip (a frame contact that does not bail
        -- an upright rider) with its witness at the foot.
        local FACE = function(_, plan, raw, seen) return face_hit(raw, plan, seen) end
        local FOOT = function(_, w, raw, seen) return witness_at(edge_foot)(raw, w, seen) end
        local function rider(options, spec)
            spec = spec or {}
            spec.speed, spec.options = 4, options
            local d = driver(spec)
            for _ = 1, 20 do
                local r = read(d, {})
                settle_read(d, r)
                if r.result.commands.submit then assert(d.ride:accept(r.result.commands.serial)) end
            end
            return d
        end
        local function hop_read(d, hooks)
            local r = read(d, { r3 = true }, hooks)
            settle_read(d, r)
            if r.result.commands.submit then assert(d.ride:accept(r.result.commands.serial)) end
            return r
        end
        local d = rider()
        local control = hop_read(d, { guard = FACE, witness = FOOT })
        local cb, cc = control.result.diagnostics.bail, control.result.commands
        check(cb.evaluated and cb.valid and cb.guarded and cb.contacts == 1 and not cb.bail and control.witness_rays == 1,
            "control: the face under the grip is judged, one frame contact, no bail")
        check(cc.submit and cc.hop_event_id > 0 and M.length(cc.hop_impulse) > 0 and control.result.diagnostics.hop == "submitted",
            "control: the judged read submits its force, torque and hop impulse")
        local control_impulse = M.length(cc.hop_impulse)
        local function refused_hop(name, r, reason, ride)
            check(r.result.valid and r.result.mode == "rolling" and withheld(r, reason),
                name .. ": no force, torque or hop impulse leaves (" .. reason .. ")")
            check(r.result.diagnostics.kernel.hop_applied == true and r.result.diagnostics.hop == "cancelled",
                name .. ": the kernel applied the hop, and it is cancelled, not sent")
            local st = ride:status()
            check(st.input.last_retired.disposition == "cancelled" and st.kernel_consumed_hop == 0 and st.outstanding == nil,
                name .. ": the hop is retired cancelled and never consumed")
        end
        local cases = 0
        -- The packet's guard-batch and witness-batch counterexamples.
        for _, case in ipairs(guard_edits) do
            d = rider()
            local r = hop_read(d, { guard = function(t, plan, raw, seen) FACE(t, plan, raw, seen); case[2](raw); return raw end,
                witness = FOOT })
            refused_hop("guard batch " .. case[1], r, case[3], d.ride)
            cases += 1
        end
        for _, case in ipairs(witness_edits) do
            d = rider()
            local r = hop_read(d, { guard = FACE,
                witness = function(t, w, raw, seen) FOOT(t, w, raw, seen); case[2](raw); return raw end })
            refused_hop("witness batch " .. case[1], r, case[3], d.ride)
            cases += 1
        end
        -- Stale batches relabelled: the previous read's own raw batches.
        d = rider()
        local before = read(d, {}, { guard = FACE, witness = FOOT })
        settle_read(d, before)
        assert(before.result.commands.submit and d.ride:accept(before.result.commands.serial))
        refused_hop("stale guard batch", hop_read(d, { guard = function() return before.tick.guard end }),
            "guard_epoch_mismatch", d.ride)
        d = rider()
        before = read(d, {}, { guard = FACE, witness = FOOT })
        settle_read(d, before)
        assert(before.result.commands.submit and d.ride:accept(before.result.commands.serial))
        refused_hop("stale witness batch", hop_read(d, { guard = FACE, witness = function() return before.tick.witness end }),
            "witness_epoch_mismatch", d.ride)
        cases += 2
        -- Batches the caller never handed back, a witness never asked for,
        -- witnesses with no batch left, an explicit one-batch cap, and a bail_policy
        -- that refuses every sample (an invalid tuning).
        d = rider()
        refused_hop("guard batch never cast", hop_read(d, { guard = function() return nil end }), "guard_batch_missing", d.ride)
        d = rider()
        refused_hop("witness never called", hop_read(d, { guard = FACE, no_witness = true }), "witness_not_called", d.ride)
        d = rider()
        refused_hop("witness batch never cast", hop_read(d, { guard = FACE, witness = function() return nil end }),
            "witness_batch_missing", d.ride)
        d = rider({ batches_per_read = 2 })
        refused_hop("witnesses with no batch", hop_read(d, { guard = FACE }), "witness_batch_allowance", d.ride)
        d = rider({ batches_per_read = 1 })
        refused_hop("explicit one-batch allowance", hop_read(d), "batch_allowance", d.ride)
        d = rider({ bail = { contact_gap = 1 } })
        refused_hop("bail_policy refusing its sample", hop_read(d), "bail_policy_invalid_sample", d.ride)
        cases += 6
        -- No coherent frame: the read without its selected source.
        d = rider()
        local blind = hop_read(d, { tick = function(t) t.input = nil end })
        check(withheld(blind, "bail_guard_unbound"), "no coherent frame: nothing leaves (bail_guard_unbound)")
        cases += 1
        -- After an unguarded read the guard lends no sweep history, so the
        -- policy's history and the guard's restart together; the next read
        -- is judged and submits, and its successor has history again.
        d = rider()
        local gap = hop_read(d, { guard = function(_, _, raw) raw.epoch = newproxy(); return raw end })
        check(withheld(gap, "guard_epoch_mismatch"), "an unjudged read")
        local next_read = read(d, {})
        settle_read(d, next_read)
        check(next_read.plan.guard.consecutive == false and next_read.result.diagnostics.bail.guarded
            and next_read.result.commands.submit and d.ride:accept(next_read.result.commands.serial),
            "the next read is planned without sweep history, judged, and submits")
        local again = read(d, {})
        check(again.plan.guard.consecutive == true and again.result.diagnostics.bail.guarded and again.result.commands.submit,
            "and its successor lends history again")
        note(string.format("unguarded reads: rolling at 4 m/s with R3, the judged control submits a %.1f N s hop; %d unguarded reads (%d guard-batch and %d witness-batch edits, both stale batches, a guard or witness batch never cast, a witness never called, witnesses with no batch, an explicit one-batch cap, a bail_policy refusing its sample, no frame) submit no force, torque or impulse and cancel the hop",
            control_impulse, cases, #guard_edits, #witness_edits))
    end)

    scenario("no opaque handles in status or results", function()
        local spec = table.clone(scenarios.barspin)
        spec.options = { matrices = true }
        local out = run(spec)
        for _, r in ipairs(out.trace) do
            local hit = find_opaque(r.result, "result")
            check(hit == nil, "step " .. r.step .. " result holds no handle: " .. tostring(hit))
        end
        check(find_opaque(out.ride:status(), "status") == nil, "status() holds no handle")
        local placed = out.ride:matrices()
        check(placed and find_opaque(placed, "matrices") == nil and #placed.matrices == 8, "matrices() holds no handle")
    end)

    scenario("per-tick cost, repeated runs", function()
        -- Wall time on a shared desktop includes preemption. Each scenario
        -- is run three times; the per-tick minimum over the runs is the
        -- estimate least disturbed by other work.
        local function minima(spec)
            local mins
            for _ = 1, 3 do
                local out = run(spec)
                if mins == nil then mins = table.clone(out.costs) end
                for i, ms in ipairs(out.costs) do mins[i] = math.min(mins[i] or ms, ms) end
            end
            return mins
        end
        local function line(name, mins)
            local sum = 0
            for _, ms in ipairs(mins) do sum += ms end
            note(string.format("cost %s: per-tick minimum of 3 runs mean %.2f ms, median %.2f, max %.2f over %d ticks",
                name, sum / #mins, percentile(mins, .5), percentile(mins, 1), #mins))
            return sum / #mins, percentile(mins, 1)
        end
        if not clock then return end
        local hop_mins = minima(scenarios.bunny_hop)
        local mean_hop, max_hop = line("bunny_hop", hop_mins)
        local mean_rail, max_rail = line("rail_balanced", minima({ speed = 5, max_steps = 420, rails = rail_list(),
            options = { grind = STRONG_ASSIST }, script = flick_onto(8, feedback_rider) }))
        local spec = table.clone(scenarios.barspin)
        local plain_mean = line("barspin", minima(spec))
        spec.options = { matrices = true }
        local matrix_mean = line("barspin with matrices", minima(spec))
        note(string.format("cost: building the part matrices in every step adds %.2f ms per tick", matrix_mean - plain_mean))
        -- Calibration: forces.lua alone, coasting on flat ground at 4 m/s,
        -- previewed and adopted as the composer does, the workload FORCES.md
        -- timed at 0.310 ms mean on an idle desktop (0.298 ms for step).
        local body, wheels = World.place(World.terrain.flat(), { speed = 4 })
        local rows = wheel_rows({ rails = {} }, body)
        local kernel_mins = {}
        for _ = 1, 3 do
            local kernel = Forces.new()
            for i = 1, 120 do
                local c0 = clock()
                local _, candidate = kernel:preview(H, body, wheels, rows, { enabled = true })
                kernel = candidate
                local ms = (clock() - c0) * 1000
                kernel_mins[i] = math.min(kernel_mins[i] or ms, ms)
            end
        end
        local kernel_median = percentile(kernel_mins, .5)
        note(string.format("cost calibration: forces.lua coasting preview/adopt alone, per-step minimum of 3 runs median %.3f ms (FORCES.md: 0.310 ms mean idle)",
            kernel_median))
        check(percentile(kernel_mins, .5) > 0 and mean_hop > 0 and mean_rail > 0, "costs measured")
        -- The hard bound is the work per call, and the median survives
        -- preemption; tails on a shared desktop are reported, not asserted.
        check(percentile(hop_mins, .5) < 20, "median least-disturbed tick inside 20 ms")
        note(string.format("cost: least-disturbed maxima %.2f ms (hop) and %.2f ms (rail) against the 50 ms call limit", max_hop, max_rail))
    end)

    note(string.format("requests: at most %d of %d in one read, at most %d witness rays", peak_requests,
        Composer.request_budget, peak_witness))
    note(string.format("residual proxy: evaluated on %d scenario reads, largest %.6f N s (sim_world applies exactly the submitted command)",
        residual_reads, residual_max))
    note(string.format("all scenarios: %d ticks, per-tick composer cost median %.2f ms, p95 %.2f ms, p99 %.2f ms, max %.2f ms",
        #all_costs, percentile(all_costs, .5), percentile(all_costs, .95), percentile(all_costs, .99), percentile(all_costs, 1)))
    if clock and #all_costs > 0 then
        check(percentile(all_costs, .5) < 20, "median per-tick cost inside 20 ms")
    end
    return { cases = cases, assertions = assertions, native_actions = 0, report = report }
end

return Tests

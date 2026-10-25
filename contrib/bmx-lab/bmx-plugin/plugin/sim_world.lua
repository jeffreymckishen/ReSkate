-- Offline single-body ride simulator. Test-only tooling: it is not an adapter,
-- owns no SDK object, makes no reskate.* call and runs nothing on require.
-- It drives the actual input.lua mapper and forces.lua kernel against an
-- authored heightfield and integrates the one rigid body itself, so every
-- number it produces is a model metric, never gameplay or native evidence.
-- SIMULATION.md lists what it models and, more importantly, what it does not.
local Forces = require("./forces")
local Input = require("./input")
local G = require("./bike_geometry")
local M = require("./force_math")
local World = {}
local Sim = {}
Sim.__index = Sim

-- forces.lua accepts only its own native interval; anything else is refused.
World.h = Forces.native_seconds
-- ride_runtime.lua's wheel_plan probes this far past the tyre below each hub.
World.ray_margin = .15
World.wheel_radius = G.wheel_radius
-- The frame origin is the measured COM minus the rotated authored COM, the
-- convention ride_runtime.lua, bike_visual.lua and peg_geometry.lua share.
-- Frozen because every simulator that requires this module reads them.
World.front_hub = table.freeze(M.sub(G.front_axle, G.com))
World.rear_hub = table.freeze(M.sub(G.rear_axle, G.com))

local function freeze(t)
    for _, v in pairs(t) do
        if type(v) == "table" and not table.isfrozen(v) then freeze(v) end
    end
    return table.freeze(t)
end
World.freeze = freeze

-- Terrain is a profile y = height(z), extruded along world X. Every kind is a
-- plain authored shape with no game data. A vertical step (ledge, gap wall)
-- is a discontinuity: a downward ray only ever sees the top face, as a native
-- ray would, and a hub that ends up below its own column's surface is
-- reported as an unavailable query instead of an invented face contact.
local Terrain = {}
World.terrain = Terrain
local function profile(kind, parameters, height, slope)
    return freeze({ kind = kind, parameters = parameters, height = height, slope = slope })
end
function Terrain.flat()
    return profile("flat", {}, function() return 0 end, function() return 0 end)
end
-- A straight ramp of `angle` radians starting at `start_z`, with a quadratic
-- blend of `blend` metres at the foot and the lip so the slope is continuous,
-- then a level deck at `top` metres.
function Terrain.ramp(options)
    options = options or {}
    local z0, angle, blend, top = options.start_z or 3, options.angle or math.rad(15), options.blend or .5, options.top or 3
    local k = math.tan(angle)
    assert(blend > 0 and top >= k * blend, "ramp deck must sit above both blends")
    local z1 = z0 + top / k
    local function height(z)
        if z <= z0 then return 0 end
        if z <= z0 + blend then return k * (z - z0) ^ 2 / (2 * blend) end
        if z <= z1 then return k * (z - z0 - blend / 2) end
        if z <= z1 + blend then local d = z - z1 return k * (z1 - z0 - blend / 2) + k * d - k * d * d / (2 * blend) end
        return top
    end
    local function slope(z)
        if z <= z0 or z >= z1 + blend then return 0 end
        if z <= z0 + blend then return k * (z - z0) / blend end
        if z <= z1 then return k end
        return k * (1 - (z - z1) / blend)
    end
    return profile("ramp", { start_z = z0, angle = angle, blend = blend, top = top, lip_z = z1 + blend }, height, slope)
end
-- A raised deck of `height` metres for z < edge_z, dropping to ground level.
function Terrain.ledge(options)
    options = options or {}
    local edge, deck = options.edge_z or 2, options.height or .3
    return profile("ledge", { edge_z = edge, height = deck },
        function(z) return z < edge and deck or 0 end, function() return 0 end)
end
-- Ground level except a pit of `depth` metres between near_z and far_z.
function Terrain.gap(options)
    options = options or {}
    local near, far, depth = options.near_z or 4, options.far_z or 5.5, options.depth or 1
    assert(far > near and depth > 0, "gap needs a positive width and depth")
    return profile("gap", { near_z = near, far_z = far, depth = depth },
        function(z) return (z >= near and z < far) and -depth or 0 end, function() return 0 end)
end
-- Shared by every caller of this module, so no caller may swap a shape.
table.freeze(Terrain)

-- One downward ray from `from` of `length` metres. Returns "hit" with the top
-- face point and unit normal, "clear" when the column surface is below the
-- ray, or "inside" when the start is already under the surface.
function World.ray(terrain, from, length)
    local y = terrain.height(from[3])
    if y > from[2] then return "inside" end
    if y < from[2] - length then return "clear" end
    local normal = M.unit({ 0, 1, -terrain.slope(from[3]) })
    return "hit", { from[1], y, from[3] }, normal
end

function World.hubs(body)
    local q = M.normalized(body.orientation)
    return { M.add(body.center_of_mass, M.turn(q, World.front_hub)),
        M.add(body.center_of_mass, M.turn(q, World.rear_hub)) }
end

-- Contact rows in the FORCES.md call-contract shape, built exactly the way
-- ride_runtime.lua's wheel_contacts builds them from measured rays: the
-- basis comes from the hit normal and the unsteered body forward, separation
-- is measured along that normal from the hub, and the static heightfield has
-- zero surface velocity. A clear row is only {contact={status="clear"}}.
-- Facts beside each row (`info`) are for metrics and never reach forces.lua.
function World.contacts(terrain, body, gravity)
    local down = M.unit(gravity)
    assert(down and down[1] == 0 and down[3] == 0 and down[2] < 0, "the heightfield ray needs vertical gravity")
    local forward = M.turn(M.normalized(body.orientation), { 0, 0, 1 })
    local samples, info, available = {}, {}, true
    for i, hub in ipairs(World.hubs(body)) do
        local status, point, normal = World.ray(terrain, hub, World.wheel_radius + World.ray_margin)
        local clearance = hub[2] - World.wheel_radius - terrain.height(hub[3])
        local basis = status == "hit" and M.basis(normal, forward) or nil
        if status == "hit" and basis then
            local separation = M.dot(M.sub(hub, point), basis.normal) - World.wheel_radius
            samples[i] = { contact = { status = "hit", point = point, normal = basis.normal, forward = basis.forward,
                surface_velocity = { 0, 0, 0 } }, separation = separation, verified_plane = false,
                balance_normal_available = false }
            info[i] = { status = "hit", separation = separation, clearance = clearance, hub = hub }
        elseif status == "clear" then
            samples[i] = { contact = { status = "clear" } }
            info[i] = { status = "clear", clearance = clearance, hub = hub }
        else
            -- A hub below its column surface, or a forward axis along the
            -- normal: the real adapter has no honest row here either.
            samples[i] = { contact = { status = "unavailable" } }
            info[i] = { status = "unavailable", clearance = clearance, hub = hub }
            available = false
        end
    end
    return samples, info, available
end

-- The support test ride_runtime.lua reports as `grounded`, per wheel.
function World.supported(body, sample, tuning)
    local maximum = tuning and tuning.maximum_penetration or .10
    return sample.contact.status == "hit" and Forces.eligible_support(body, sample, .005, maximum)
end

-- The selected-source force-control law of ride_input_mapping.lua's
-- Mapper:controls, applied to plain input.lua actions. sim_tests.lua checks it
-- against the real mapping, so a change there shows up as a test failure.
-- `hop` is the pending {id, strength} event, or nil.
function World.controls(settings, actions, raw, hop, grounded, rotation_reserved)
    local a = actions
    local neutral = settings.deadzone + (1 - settings.deadzone) * settings.neutral_threshold
    local rear_magnitude = math.sqrt(raw.right_x ^ 2 + raw.right_y ^ 2)
    local raw_rotation = math.sqrt(raw.left_x ^ 2 + raw.left_y ^ 2) > neutral
        or rear_magnitude > neutral
        or raw.left_shoulder or raw.right_shoulder
        or raw.left_trigger > settings.trigger_neutral or raw.right_trigger > settings.trigger_neutral
    local manual, nose = a.manual, a.nose_manual
    if not grounded then manual, nose = math.max(0, -a.air_pitch), math.max(0, a.air_pitch) end
    return { enabled = true, pedal = a.pedal, brake = a.brake, steer = a.steer,
        manual = manual, nose_manual = nose, air_yaw = a.steer, ground_pump = a.front_weight,
        pump_operator_available = true,
        pump_inhibited = hop ~= nil or a.hop_pressed or raw.quick_hop or a.preload > 0,
        rotation_reserved = raw_rotation or rotation_reserved == true,
        recovery_step_verified = false, contact_compliance_available = false,
        landing_contact_compliance_selected = false,
        hop_event_id = hop and hop.id or 0, hop_strength = hop and hop.strength or 0 }
end

-- Body + rotor kinetic energy plus gravitational potential, in joules.
function World.energy(body, wheels, gravity)
    local v, w = body.linear_velocity, body.angular_velocity
    local out = .5 * body.mass * M.dot(v, v) + .5 * M.dot(w, M.tensor(body, w, false))
    for _, wheel in ipairs(wheels) do out += .5 * wheel.inertia * wheel.angular_speed ^ 2 end
    return out - body.mass * M.dot(gravity, body.center_of_mass)
end

local function rotate(q, w, h)
    local rate = M.length(w)
    if rate * h < 1e-12 then return M.normalized(q) end
    local s = math.sin(rate * h / 2) / rate
    local dx, dy, dz, dw = w[1] * s, w[2] * s, w[3] * s, math.cos(rate * h / 2)
    -- Hamilton d * q: a world-frame angular velocity turns the body from the left.
    return M.normalized({
        dw * q[1] + dx * q[4] + dy * q[3] - dz * q[2],
        dw * q[2] - dx * q[3] + dy * q[4] + dz * q[1],
        dw * q[3] + dx * q[2] - dy * q[1] + dz * q[4],
        dw * q[4] - dx * q[1] - dy * q[2] - dz * q[3] })
end

-- One semi-implicit Euler step of the single rigid body. The submitted force
-- and torque act for h, gravity is added here because forces.lua excludes it,
-- and the hop impulse is applied once and never folded into the force. The
-- angular update uses the body table's own inertia at the step's starting
-- orientation, the same I^-1 response forces.lua predicts with, and has no
-- gyroscopic term. Position then advances with the new velocity and the
-- orientation by the exact rotation of the new angular velocity over h.
function World.integrate(body, result, gravity, h)
    local m, v = body.mass, body.linear_velocity
    local out = M.copy(body)
    out.linear_velocity = {
        v[1] + (result.force[1] / m + gravity[1]) * h + result.hop_impulse[1] / m,
        v[2] + (result.force[2] / m + gravity[2]) * h + result.hop_impulse[2] / m,
        v[3] + (result.force[3] / m + gravity[3]) * h + result.hop_impulse[3] / m }
    out.angular_velocity = M.add(body.angular_velocity, M.tensor(body, M.mul(result.torque, h), true))
    out.center_of_mass = M.add(body.center_of_mass, M.mul(out.linear_velocity, h))
    out.orientation = rotate(body.orientation, out.angular_velocity, h)
    return out
end

-- Heading (yaw), nose-up pitch and lean (positive toward body +X, rider left)
-- in radians, from the body axes. Yaw is atan2 of forward on the ground plane.
function World.attitude(body)
    local q = M.normalized(body.orientation)
    local forward, left = M.turn(q, { 0, 0, 1 }), M.turn(q, { 1, 0, 0 })
    return math.atan2(forward[1], forward[3]), math.asin(math.clamp(forward[2], -1, 1)),
        math.asin(math.clamp(-left[2], -1, 1))
end

-- A body at rest on the terrain with both tyres touching (zero separation on
-- flat ground), travelling at `speed` along `yaw` with the rotors rolling.
function World.place(terrain, options)
    options = options or {}
    local body, wheels = Forces.proposed_body(), Forces.proposed_wheels()
    if options.mass then body.mass = options.mass end
    if options.inertia then body.inertia_body = M.copy(options.inertia) end
    local yaw, speed = options.yaw or 0, options.speed or 0
    body.orientation = { 0, math.sin(yaw / 2), 0, math.cos(yaw / 2) }
    local x, z = options.x or 0, options.z or 0
    local y = -math.huge
    for _, hub in ipairs({ World.front_hub, World.rear_hub }) do
        local offset = M.turn(body.orientation, hub)
        y = math.max(y, terrain.height(z + offset[3]) + World.wheel_radius - offset[2])
    end
    body.center_of_mass = { x, y, z }
    local forward = M.turn(body.orientation, { 0, 0, 1 })
    body.linear_velocity = M.mul(forward, speed)
    for _, wheel in ipairs(wheels) do wheel.angular_speed = speed / wheel.radius end
    return body, wheels
end

function World.new(options)
    options = options or {}
    local terrain = options.terrain or Terrain.flat()
    local tuning = Forces.tuning(options.tuning)
    local body, wheels = World.place(terrain, options)
    local self = setmetatable({ terrain = terrain, tuning = tuning, controller = Forces.new(options.tuning),
        mapper = Input.new(options.input), body = body, wheels = wheels, steps = 0, time = 0,
        hop_counter = 0, stopped = false, issue = "none", rotation_reserved = options.rotation_reserved == true }, Sim)
    self.settings = self.mapper:settings()
    return self
end

local function raw_input(changes)
    local raw = { available = true, focused = true, menu_open = false, device = 0 }
    for key, value in pairs(changes or {}) do raw[key] = value end
    return Input.raw(raw)
end

-- One native step: query, map input, solve, integrate. `changes` are the raw
-- pad fields for this step (Input.raw names; omitted fields are neutral).
-- Returns a frozen record of the step. After a refused step the simulator
-- stops: it never integrates through an invalid kernel result.
function Sim:step(changes)
    assert(not self.stopped, "a stopped simulation cannot step")
    local h, gravity = World.h, self.tuning.gravity
    local body = self.body
    local samples, info, available = World.contacts(self.terrain, body, gravity)
    local grounded = false
    for i = 1, 2 do
        info[i].supported = available and World.supported(body, samples[i], self.tuning)
        grounded = grounded or info[i].supported
    end
    local raw = raw_input(changes)
    local actions = self.mapper:update(raw, { grounded = grounded }, h)
    local controls, hop
    if actions.active then
        if actions.hop_pressed then
            self.hop_counter += 1
            self.pending = { id = self.hop_counter, strength = actions.hop_strength }
        end
        hop = self.pending
        controls = World.controls(self.settings, actions, raw, hop, grounded, self.rotation_reserved)
    else
        -- The real mapping submits nothing while gated. Here the kernel is the
        -- only ground, so a gated step still solves passive support.
        controls = { enabled = false }
    end
    local energy_before = World.energy(body, self.wheels, gravity)
    local result = self.controller:step(h, body, self.wheels, samples, controls)
    -- forces.lua consumes any new hop ID on its first presentation, applied
    -- or not; an ideal owner retires it on that same step.
    self.pending = nil
    self.steps += 1
    local record = { step = self.steps, time = self.time + h, valid = result.valid, issue = result.issue,
        input_active = actions.active, grounded = grounded, kernel_grounded = result.grounded,
        hop_pressed = actions.hop_pressed, hop_applied = result.hop_applied,
        hop_strength = hop and hop.strength or 0, pedal = controls.pedal or 0, brake = controls.brake or 0,
        steer = controls.steer or 0, manual = controls.manual or 0, nose_manual = controls.nose_manual or 0,
        steering_limited = result.steering_limited, front_steer_angle = result.front_steer_angle,
        front = info[1], rear = info[2], normal_load = M.copy(result.normal_load), energy_before = energy_before }
    if not result.valid then
        self.stopped, self.issue = true, result.issue
    else
        self.body = World.integrate(body, result, gravity, h)
        self.wheels = M.copy(self.wheels)
        for i = 1, 2 do self.wheels[i].angular_speed = result.wheels[i].angular_speed end
        self.time += h
    end
    local b = self.body
    local yaw, pitch, lean = World.attitude(b)
    local forward = M.turn(M.normalized(b.orientation), { 0, 0, 1 })
    record.position = M.copy(b.center_of_mass)
    record.velocity = M.copy(b.linear_velocity)
    record.angular_velocity = M.copy(b.angular_velocity)
    record.speed = math.sqrt(b.linear_velocity[1] ^ 2 + b.linear_velocity[3] ^ 2)
    record.forward_speed = M.dot(b.linear_velocity, forward)
    record.yaw, record.pitch, record.lean = yaw, pitch, lean
    record.wheel_speed = { self.wheels[1].angular_speed, self.wheels[2].angular_speed }
    record.energy = World.energy(b, self.wheels, gravity)
    return freeze(record)
end

function Sim:state()
    return { body = M.copy(self.body), wheels = M.copy(self.wheels), steps = self.steps, time = self.time,
        stopped = self.stopped, issue = self.issue, hop_counter = self.hop_counter }
end

return table.freeze(World)

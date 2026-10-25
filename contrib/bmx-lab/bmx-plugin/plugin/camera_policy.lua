-- BMX chase-camera policy. Pure: it owns no SDK object, makes no reskate.*
-- call (no camera lease, look, cycle or raycast) and runs nothing on require.
-- Each tick the caller gives it the measured bike pose and velocity and, when
-- it can, the reskate.world.raycast result for the ray it proposes. It returns
-- {eye, target, fov} that reskate.camera.look accepts (plugin_api_world.cpp
-- 195-221): float positions within 100 km, eye and target more than 1 cm
-- apart, and 10 to 150 degrees of view. The model and every constant are our
-- own (CAMERA.md), not BMX Streets'.
-- Axes follow forces.lua: +Y is up, and the body quaternion {x, y, z, w} turns
-- the bike's local +Z (its forward) into the world.
local M = require("./force_math")
local Camera = {}
local Rig = {}
Rig.__index = Rig
Rig.__metatable = "locked"
local states = setmetatable({}, { __mode = "k" })

-- reskate.camera.look's own limits, so a returned view is never one it refuses.
local API_BOUND, API_SEPARATION, API_FOV_LOW, API_FOV_HIGH = 1e5, 0.01, 10, 150
-- Bike positions are refused this far inside the API's bound. The sanitized
-- tuning cannot place an eye or target more than about 30 m from the bike.
local POSITION_MARGIN = 100
-- Faster than any rideable bike; a larger reading is a broken measurement.
local MAX_SPEED = 150
local TAU = 2 * math.pi

local defaults = {
    -- Follow arm: metres behind and above the pivot, longer with speed.
    distance = 3.0, distance_per_speed = 0.08, max_distance = 4.6, min_distance = 0.6,
    height = 0.9, pivot_height = 1.1,
    -- Airborne framing: pull back and rise so the landing stays in view.
    air_distance = 0.8, air_height = 0.5,
    -- Spring frequencies, rad/s. Critically damped, so none overshoots.
    distance_frequency = 3.0, height_frequency = 3.5,
    heading_frequency = 3.2, air_heading_frequency = 1.5,
    vertical_frequency = 9.0, air_vertical_frequency = 3.5, vertical_lag_limit = 1.0,
    -- Below heading_speed_low the arm follows the bike's facing; above
    -- heading_speed_high it follows the line of travel.
    heading_speed_low = 0.8, heading_speed_high = 3.0, air_heading_speed = 1.0,
    -- Velocity look-ahead: seconds of travel to aim ahead, capped in metres.
    look_ahead_seconds = 0.25, look_ahead_max = 1.5, air_look_seconds = 0.2, air_look_down_max = 1.2,
    look_frequency = 4.0,
    -- Field of view in degrees, widening with speed; fov_rate is 1/s.
    fov = 70, fast_fov = 82, fov_full_speed = 12, air_fov = 3, fov_rate = 2.5,
    -- Pull-in: metres kept clear of a hit, and the 1/s rate of easing back out.
    clearance = 0.2, release_rate = 2.0,
    -- Reset when the bike lands this far from where its velocity said, or
    -- after a gap this many seconds long.
    reset_distance = 3.0, reset_gap = 0.5,
    -- Steepest view, radians: camera.look picks an arbitrary roll looking
    -- straight down, so the view never gets close to that.
    max_pitch = 1.2, min_separation = 0.3,
}

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function sanitize(overrides)
    if overrides ~= nil and not plain(overrides) then error("camera tuning is a plain table", 3) end
    local source = overrides or {}
    for key, value in pairs(source) do
        if defaults[key] == nil then error("unknown camera tuning: " .. tostring(key), 3) end
        if not M.finite(value) then error("camera tuning " .. key .. " is not a finite number", 3) end
    end
    local t = {}
    local function bounded(name, low, high)
        local value = source[name]
        t[name] = math.clamp(value == nil and defaults[name] or value, low, high)
    end
    bounded("min_separation", 0.05, 1)
    bounded("distance", 1, 8)
    -- The pulled-in arm may not be shorter than the separation the view keeps.
    bounded("min_distance", math.max(0.3, t.min_separation), t.distance)
    bounded("max_distance", t.distance, 10)
    bounded("distance_per_speed", 0, 0.5)
    bounded("height", 0, 4)
    bounded("pivot_height", 0, 3)
    bounded("air_distance", 0, 3)
    bounded("air_height", 0, 3)
    for _, name in ipairs({ "distance_frequency", "height_frequency", "heading_frequency", "air_heading_frequency",
        "vertical_frequency", "air_vertical_frequency", "look_frequency" }) do
        bounded(name, 0.5, 30)
    end
    bounded("vertical_lag_limit", 0, 3)
    bounded("heading_speed_low", 0, 10)
    bounded("heading_speed_high", t.heading_speed_low + 0.1, 20)
    bounded("air_heading_speed", 0, 20)
    bounded("look_ahead_seconds", 0, 1)
    bounded("look_ahead_max", 0, 5)
    bounded("air_look_seconds", 0, 1)
    bounded("air_look_down_max", 0, 5)
    bounded("fov", API_FOV_LOW, API_FOV_HIGH)
    bounded("fast_fov", API_FOV_LOW, API_FOV_HIGH)
    bounded("fov_full_speed", 1, 60)
    bounded("air_fov", -20, 20)
    bounded("fov_rate", 0.1, 20)
    bounded("clearance", 0, 1)
    bounded("release_rate", 0.1, 20)
    bounded("reset_distance", 0.5, 50)
    bounded("reset_gap", 0.05, 2)
    bounded("max_pitch", 0.2, 1.4)
    return t
end

-- A Luau vector, {x =, y =, z =} or {x, y, z}, copied to a double array.
local function point(value)
    local x, y, z
    if typeof(value) == "vector" then
        x, y, z = value.x, value.y, value.z
    elseif plain(value) then
        if value.x ~= nil or value.y ~= nil or value.z ~= nil then x, y, z = value.x, value.y, value.z
        else x, y, z = value[1], value[2], value[3] end
    else
        return nil
    end
    if not (M.finite(x) and M.finite(y) and M.finite(z)) then return nil end
    return { x, y, z }
end

local function quaternion(value)
    if not plain(value) then return nil end
    local q = value.w ~= nil and { value.x, value.y, value.z, value.w } or { value[1], value[2], value[3], value[4] }
    local norm = 0
    for i = 1, 4 do
        if not M.finite(q[i]) then return nil end
        norm += q[i] * q[i]
    end
    -- forces.lua accepts a body orientation within 1e-3 of unit length.
    if math.abs(norm - 1) > 1e-3 then return nil end
    return M.normalized(q)
end

local function measure(sample)
    if not plain(sample) then return nil, "invalid_sample" end
    local position = point(sample.position)
    if not position then return nil, "invalid_position" end
    for i = 1, 3 do
        if math.abs(position[i]) > API_BOUND - POSITION_MARGIN then return nil, "position_out_of_range" end
    end
    local velocity = point(sample.velocity)
    if not velocity or M.length(velocity) > MAX_SPEED then return nil, "invalid_velocity" end
    local rotation = quaternion(sample.rotation)
    if not rotation then return nil, "invalid_rotation" end
    -- Explicit, because a missing flag would silently turn airborne framing off.
    if type(sample.grounded) ~= "boolean" then return nil, "invalid_grounded" end
    if sample.teleport ~= nil and type(sample.teleport) ~= "boolean" then return nil, "invalid_teleport" end
    return { position = position, velocity = velocity, rotation = rotation, grounded = sample.grounded,
        teleport = sample.teleport == true }
end

-- Into (-pi, pi], so a heading spring always turns the short way round.
local function wrap(angle)
    angle %= TAU
    if angle > math.pi then angle -= TAU end
    return angle
end

-- A critically damped spring whose goal moves in a straight line from
-- `before` (the last tick's goal) to `goal` across the step. The solution is
-- exact for that motion at any step length, so 60 Hz and 120 Hz ticks of the
-- same ride differ only in how finely the goal was sampled, not in how the
-- spring was integrated. Holding the goal for the step instead would lead the
-- spring by half a tick, a lead that changes with the tick rate.
local function spring(value, rate, before, goal, frequency, seconds)
    local slope = (goal - before) / seconds
    local lead = 2 * slope / frequency
    local offset, drift = value - before + lead, rate - slope
    local drive = drift + frequency * offset
    local decay = math.exp(-frequency * seconds)
    return goal - lead + (offset + drive * seconds) * decay, slope + (drift - frequency * drive * seconds) * decay
end

-- First-order approach to a goal moving in a line across the step, exact as above.
local function ease(value, before, goal, rate, seconds)
    local lag = (goal - before) / (seconds * rate)
    return goal - lag + (value - before + lag) * math.exp(-rate * seconds)
end

local function smoothstep(low, high, x)
    local u = math.clamp((x - low) / (high - low), 0, 1)
    return u * u * (3 - 2 * u)
end

-- The line of travel as a turn from the heading `base`, within a quarter turn
-- either way: travel against `base` is read as that line reversed. Rolling
-- backwards (fakie) is then a small turn, not a half turn whose side a hair of
-- sideways drift would pick from one tick to the next. Also returns the speed
-- along the line, which is zero for travel square to `base`.
local function line_from(base, travel_yaw, travel_speed)
    local turn = wrap(travel_yaw - base)
    if turn > 0.5 * math.pi then turn -= math.pi elseif turn < -0.5 * math.pi then turn += math.pi end
    return turn, travel_speed * math.cos(turn)
end

-- Where the rig would like to be for this sample. `held` is the camera's
-- current heading, or nil when there is none to hold.
local function goals(t, m, held)
    local v = m.velocity
    local airborne = not m.grounded
    local speed = M.length(v)
    local travel_speed = math.sqrt(v[1] * v[1] + v[3] * v[3])
    local travel_yaw = travel_speed > 1e-3 and math.atan2(v[1], v[3]) or nil
    local forward = M.turn(m.rotation, { 0, 0, 1 })
    -- A bike pointing nearly straight up or down has no heading worth following.
    local facing = math.sqrt(forward[1] * forward[1] + forward[3] * forward[3])
    local forward_yaw = facing > 0.2 and math.atan2(forward[1], forward[3]) or nil
    local yaw
    if airborne then
        -- In the air the arm keeps the line of travel, in whichever direction is
        -- nearer its own heading, so spins, flips and a backwards hop turn the
        -- rider inside a steady frame instead of whipping the camera round.
        local base = held or forward_yaw
        if travel_yaw and travel_speed >= t.air_heading_speed then
            yaw = base and base + (line_from(base, travel_yaw, travel_speed)) or travel_yaw
        else
            yaw = base or travel_yaw or 0
        end
    else
        -- The arm follows the bike's facing, turned towards the line of travel
        -- as the speed along that line grows. Rolling backwards it stays behind
        -- the rider on the reversed line. Travel square to the facing has no
        -- speed along the line, so the heading goal is continuous where the
        -- line changes ends.
        local base = forward_yaw or held
        if not base then
            yaw = travel_yaw or 0
        elseif not travel_yaw then
            yaw = base
        else
            local turn, along = line_from(base, travel_yaw, travel_speed)
            yaw = base + turn * smoothstep(t.heading_speed_low, t.heading_speed_high, along)
        end
    end
    local look = M.limited({ v[1] * t.look_ahead_seconds, 0, v[3] * t.look_ahead_seconds }, t.look_ahead_max)
    -- Falling, the aim drops ahead of the bike so the landing comes into frame.
    if airborne and v[2] < 0 then look[2] = math.max(v[2] * t.air_look_seconds, -t.air_look_down_max) end
    local fov = t.fov + (t.fast_fov - t.fov) * smoothstep(0, t.fov_full_speed, speed) + (airborne and t.air_fov or 0)
    return {
        yaw = wrap(yaw), look = look,
        distance = math.clamp(t.distance + t.distance_per_speed * speed, t.min_distance, t.max_distance)
            + (airborne and t.air_distance or 0),
        height = t.height + (airborne and t.air_height or 0),
        pivot = m.position[2] + t.pivot_height,
        fov = math.clamp(fov, API_FOV_LOW, API_FOV_HIGH),
    }
end

local function state_of(rig)
    local s = states[rig]
    if not s then error("a camera rig method needs its rig (rig:step, not rig.step)", 3) end
    return s
end

-- Mirrors reskate.camera.look's checks on the float vectors it would receive.
-- A fov of 0 or none is the API's "the camera's own"; the policy never asks it.
function Camera.valid_look(eye, target, fov)
    if typeof(eye) ~= "vector" or typeof(target) ~= "vector" then return false, "not_vectors" end
    for _, v in ipairs({ eye, target }) do
        for _, c in ipairs({ v.x, v.y, v.z }) do
            if not M.finite(c) or math.abs(c) > API_BOUND then return false, "position_out_of_range" end
        end
    end
    if not (vector.magnitude(eye - target) > API_SEPARATION) then return false, "same_point" end
    if fov ~= nil and not (fov == 0 or (M.finite(fov) and fov >= API_FOV_LOW and fov <= API_FOV_HIGH)) then
        return false, "fov_out_of_range"
    end
    return true
end

function Camera.defaults()
    return table.freeze(M.copy(defaults))
end

function Camera.tuning(overrides)
    return table.freeze(sanitize(overrides))
end

function Camera.new(overrides)
    local rig = setmetatable({}, Rig)
    states[rig] = { tuning = sanitize(overrides), ready = false, pull = 1, unresolved = 0 }
    return rig
end

-- The next step snaps the rig behind the bike instead of following.
function Rig:reset()
    local s = state_of(self)
    s.ready, s.plan, s.unresolved = false, nil, 0
end

function Rig:tuning()
    return table.freeze(M.copy(state_of(self).tuning))
end

function Rig:status()
    local s = state_of(self)
    return table.freeze({ ready = s.ready, pending = s.plan ~= nil, yaw = s.yaw, distance = s.distance,
        height = s.height, pivot = s.pivot, pull = s.pull, fov = s.fov })
end

-- Advances the rig by `seconds` to this sample and proposes the occlusion ray,
-- from the pivot to just past the free eye. Call rig:resolve once afterwards,
-- with what reskate.world.raycast returned for that ray, or nil uncast.
function Rig:step(sample, seconds)
    local s = state_of(self)
    if not M.finite(seconds) or seconds <= 0 or seconds > 1 then return nil, "invalid_seconds" end
    local m, issue = measure(sample)
    if not m then return nil, issue end
    local t = s.tuning
    local reset = not s.ready or m.teleport or seconds > t.reset_gap
    if not reset then
        -- A position the measured velocity cannot explain is a teleport or a
        -- respawn; following it would sweep the camera through the world.
        local predicted = M.add(s.position, M.mul(M.add(s.velocity, m.velocity), 0.5 * seconds))
        reset = M.length(M.sub(m.position, predicted)) > t.reset_distance
    end
    local airborne = not m.grounded
    local g = goals(t, m, (not reset) and s.yaw or nil)
    if reset then
        s.yaw, s.yaw_rate = g.yaw, 0
        s.distance, s.distance_rate = g.distance, 0
        s.height, s.height_rate = g.height, 0
        s.pivot, s.pivot_rate = g.pivot, m.velocity[2]
        s.look, s.look_rate = M.copy(g.look), { 0, 0, 0 }
        s.fov, s.pull = g.fov, 1
    else
        local was = s.goal
        local turning = airborne and t.air_heading_frequency or t.heading_frequency
        -- Both heading goals are unwrapped next to the camera's own heading.
        local yaw_goal = s.yaw + wrap(g.yaw - s.yaw)
        s.yaw, s.yaw_rate = spring(s.yaw, s.yaw_rate, yaw_goal - wrap(g.yaw - was.yaw), yaw_goal, turning, seconds)
        s.yaw = wrap(s.yaw)
        s.distance, s.distance_rate = spring(s.distance, s.distance_rate, was.distance, g.distance,
            t.distance_frequency, seconds)
        s.height, s.height_rate = spring(s.height, s.height_rate, was.height, g.height, t.height_frequency, seconds)
        -- A softer vertical follow in the air lets the rider rise in frame, and
        -- smooths ground bumps; the lag is bounded so a drop never loses him.
        local vertical = airborne and t.air_vertical_frequency or t.vertical_frequency
        s.pivot, s.pivot_rate = spring(s.pivot, s.pivot_rate, was.pivot, g.pivot, vertical, seconds)
        if math.abs(s.pivot - g.pivot) > t.vertical_lag_limit then
            s.pivot = g.pivot + math.sign(s.pivot - g.pivot) * t.vertical_lag_limit
            s.pivot_rate = m.velocity[2]
        end
        for i = 1, 3 do
            s.look[i], s.look_rate[i] = spring(s.look[i], s.look_rate[i], was.look[i], g.look[i], t.look_frequency, seconds)
        end
        s.fov = ease(s.fov, was.fov, g.fov, t.fov_rate, seconds)
    end
    s.goal = g
    s.distance = math.clamp(s.distance, t.min_distance, t.max_distance + t.air_distance)
    s.height = math.clamp(s.height, 0, t.height + t.air_height)
    s.fov = math.clamp(s.fov, API_FOV_LOW, API_FOV_HIGH)
    s.position, s.velocity, s.ready = m.position, m.velocity, true

    -- The horizontal pivot is the bike itself: the arm, not the subject, lags.
    local pivot = { m.position[1], s.pivot, m.position[3] }
    local back = { -math.sin(s.yaw), 0, -math.cos(s.yaw) }
    -- Look-ahead never leans the aim back towards the camera, which keeps the
    -- eye and target at least the pulled-in arm apart.
    local look = M.copy(s.look)
    local toward = look[1] * back[1] + look[3] * back[3]
    if toward > 0 then
        look[1] -= back[1] * toward
        look[3] -= back[3] * toward
    end
    local rise = math.min(s.height, s.distance * math.tan(t.max_pitch))
    local arm = { back[1] * s.distance, rise, back[3] * s.distance }
    local length = M.length(arm)
    local unit = M.mul(arm, 1 / length)
    local reach = length + t.clearance
    local from = vector.create(pivot[1], pivot[2], pivot[3])
    local to = vector.create(pivot[1] + unit[1] * reach, pivot[2] + unit[2] * reach, pivot[3] + unit[3] * reach)
    s.unresolved += seconds
    s.plan = { pivot = pivot, target = M.add(pivot, look), back = back, unit = unit, length = length,
        airborne = airborne, reset = reset or (s.plan ~= nil and s.plan.reset) }
    return table.freeze({ ray = table.freeze({ from = from, to = to }), reset = s.plan.reset, airborne = airborne })
end

-- Finishes the step: `hit` is reskate.world.raycast's result for the step's
-- ray (a position, or nil when clear or not cast). A hit snaps the eye in at
-- once, so a wall is never looked through; clear space eases it back out.
function Rig:resolve(hit)
    local s = state_of(self)
    local plan = s.plan
    if not plan then return nil, "no_plan" end
    local t = s.tuning
    local allowed, occluded = plan.length, false
    if hit ~= nil and hit ~= false then
        local at = point(hit)
        if not at then return nil, "invalid_hit" end
        local offset = M.sub(at, plan.pivot)
        local along = M.dot(offset, plan.unit)
        local across = M.length(M.sub(offset, M.mul(plan.unit, along)))
        -- The ray and its hit are floats; allow their rounding, not a hit from
        -- some other ray. The plan stays pending so the caller can resolve again.
        local slack = 0.05 + 1e-6 * (math.abs(plan.pivot[1]) + math.abs(plan.pivot[2]) + math.abs(plan.pivot[3]))
        if across > slack or along < -slack or along > plan.length + t.clearance + slack then
            return nil, "hit_off_ray"
        end
        allowed = math.clamp(along - t.clearance, t.min_distance, plan.length)
        -- Float rounding of a hit at the ray's far end is not an obstruction.
        -- The ray's end and the hit are each rounded to a float, half a float
        -- step per axis, which is several millimetres near 100 km.
        local rounding = 1e-3 + 1.2e-7 * (math.abs(plan.pivot[1]) + math.abs(plan.pivot[2]) + math.abs(plan.pivot[3]))
        if allowed > plan.length - rounding then allowed = plan.length end
        occluded = allowed < plan.length
    end
    local fraction = allowed / plan.length
    if plan.reset or fraction <= s.pull then s.pull = fraction
    else s.pull = ease(s.pull, fraction, fraction, t.release_rate, s.unresolved) end
    s.plan, s.unresolved = nil, 0
    local reach = math.max(s.pull * plan.length, t.min_distance)
    local eye = M.add(plan.pivot, M.mul(plan.unit, reach))
    local target = M.copy(plan.target)
    -- Last guards, which move only the target, never the eye towards a wall:
    -- a horizontal gap of at least min_separation, and pitch within max_pitch.
    local dx, dz = eye[1] - target[1], eye[3] - target[3]
    if math.sqrt(dx * dx + dz * dz) < t.min_separation then
        target[1] = eye[1] - plan.back[1] * t.min_separation
        target[3] = eye[3] - plan.back[3] * t.min_separation
    end
    local eye_v = vector.create(eye[1], eye[2], eye[3])
    local target_v = vector.create(target[1], target[2], target[3])
    -- The pitch is held on the floats camera.look will read: near 100 km their
    -- rounding alone tips a view on the limit a few thousandths of a radian
    -- past it, so the target's height is rounded towards the eye's.
    local fx, fz = eye_v.x - target_v.x, eye_v.z - target_v.z
    local steepest = math.sqrt(fx * fx + fz * fz) * math.tan(t.max_pitch)
    local rise = eye_v.y - target_v.y
    if math.abs(rise) > steepest then
        target_v = vector.create(target_v.x, eye_v.y - math.sign(rise) * steepest, target_v.z)
        for _ = 1, 4 do
            if math.abs(eye_v.y - target_v.y) <= steepest then break end
            -- One float step of the target's height towards the eye.
            local _, exponent = math.frexp(target_v.y)
            target_v = vector.create(target_v.x, target_v.y + math.sign(rise) * math.ldexp(1, exponent - 24), target_v.z)
        end
    end
    local ok, why = Camera.valid_look(eye_v, target_v, s.fov)
    if not ok then return nil, why end
    return table.freeze({ eye = eye_v, target = target_v, fov = s.fov, distance = reach, pull = s.pull,
        occluded = occluded, airborne = plan.airborne, reset = plan.reset })
end

return table.freeze(Camera)

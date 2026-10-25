-- Pure Luau cases for camera_policy.lua. Nothing runs on require; call
-- require("./camera_policy_tests").run(progress) from a Luau runner. No game,
-- camera lease, raycast or reskate service is used: the walls below are
-- constructed planes and the bike motions are authored curves. Passing here is
-- not in-game evidence of framing, occlusion or camera.look acceptance.
local Camera = require("./camera_policy")
local Tests = {}
local H = 1 / 60

-- {x, y, z, w} turning the bike's +Z towards +X by `yaw` about +Y, the
-- convention forces.lua and the policy share.
local function yaw_rotation(yaw)
    return { 0, math.sin(yaw / 2), 0, math.cos(yaw / 2) }
end

local function sample(position, velocity, yaw, grounded, extra)
    local s = { position = position, velocity = velocity or vector.zero, rotation = yaw_rotation(yaw or 0),
        grounded = grounded ~= false }
    for key, value in pairs(extra or {}) do s[key] = value end
    return s
end

-- A constructed wall: the plane z = z0, standing in for reskate.world.raycast.
local function wall(z0)
    return function(from, to)
        if (from.z - z0) * (to.z - z0) >= 0 then return nil end
        return from + (to - from) * ((z0 - from.z) / (to.z - from.z))
    end
end

local function drive(rig, s, seconds, cast)
    local plan = assert(rig:step(s, seconds))
    local hit = cast and cast(plan.ray.from, plan.ray.to) or nil
    local view, issue = rig:resolve(hit)
    assert(view, issue)
    return view, plan
end

local function flat_distance(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
end

local function pitch_of(view)
    local d = view.eye - view.target
    return math.atan2(math.abs(d.y), math.sqrt(d.x * d.x + d.z * d.z))
end

local function wrap(angle)
    angle %= 2 * math.pi
    if angle > math.pi then angle -= 2 * math.pi end
    return angle
end

-- The heading the rig settles on for one sample at once: a new rig places
-- itself on its heading goal on its first step.
local function heading_goal(s, overrides)
    local rig = Camera.new(overrides)
    drive(rig, s, H)
    return rig:status().yaw
end

-- A fine fourth-order Runge-Kutta reference for a state array, from t = 0.
local function integrate(derivative, state, seconds)
    local dt = 1e-4
    local function shifted(base, k, scale)
        local out = {}
        for j = 1, #base do out[j] = base[j] + scale * k[j] end
        return out
    end
    local t = 0
    for _ = 1, math.floor(seconds / dt + 0.5) do
        local k1 = derivative(t, state)
        local k2 = derivative(t + 0.5 * dt, shifted(state, k1, 0.5 * dt))
        local k3 = derivative(t + 0.5 * dt, shifted(state, k2, 0.5 * dt))
        local k4 = derivative(t + dt, shifted(state, k3, dt))
        for j = 1, #state do state[j] += dt / 6 * (k1[j] + 2 * k2[j] + 2 * k3[j] + k4[j]) end
        t += dt
    end
    return state
end

-- Park-Miller, so the sweep is the same on every run and every machine.
local function random_source(seed)
    local state = seed
    return function(low, high)
        state = (state * 16807) % 2147483647
        return low + (high - low) * (state / 2147483647)
    end
end

function Tests.run(progress)
    local assertions, cases = 0, 0
    local function check(condition, message)
        assertions += 1
        assert(condition, message)
    end
    local function near(a, b, tolerance) return math.abs(a - b) <= (tolerance or 1e-9) end
    local function case(name, body)
        cases += 1
        local ok, issue = pcall(body)
        if not ok then error(name .. ": " .. tostring(issue), 0) end
        if type(progress) == "function" then progress(cases, assertions) end
    end
    local tuning = Camera.tuning()

    case("require is pure and nothing here can reach the camera API", function()
        -- Every case below runs with no reskate global at all, so none of the
        -- paths it exercises can call reskate.camera or reskate.world.
        check(reskate == nil, "the runner has no reskate global")
        check(table.isfrozen(Camera), "the module table is frozen")
        check(type(Camera.new) == "function" and type(Camera.valid_look) == "function", "the module exposes its policy")
        local rig = Camera.new()
        check(getmetatable(rig) == "locked", "a rig's metatable is locked")
        check(not rig:status().ready and not rig:status().pending, "a new rig holds nothing until its first step")
        check(not pcall(rig.status, {}), "a rig method refuses a table that is not its rig")
    end)

    case("tuning is sanitized and refuses what it cannot read", function()
        check(table.isfrozen(Camera.defaults()) and Camera.defaults().fov == 70, "defaults are a frozen copy")
        check(Camera.tuning({ fov = 500 }).fov == 150 and Camera.tuning({ fov = 1 }).fov == 10,
            "the base field of view stays in camera.look's 10-150 degrees")
        check(Camera.tuning({ fast_fov = 400 }).fast_fov == 150, "the fast field of view stays in range")
        local t = Camera.tuning({ distance = 2, min_distance = 5, max_distance = 1 })
        check(t.min_distance == 2 and t.max_distance == 2, "the arm limits keep min <= rest <= max")
        check(Camera.tuning({ min_separation = 0.9, min_distance = 0.4 }).min_distance == 0.9,
            "the pulled-in arm is never shorter than the kept separation")
        check(Camera.tuning({ heading_speed_low = 5, heading_speed_high = 1 }).heading_speed_high > 5,
            "the heading blend keeps a positive width")
        check(not pcall(Camera.new, { zoom = 2 }), "an unknown tuning name is refused")
        check(not pcall(Camera.new, { fov = 0 / 0 }), "a non-finite tuning value is refused")
        check(not pcall(Camera.new, { fov = "wide" }), "a non-number tuning value is refused")
        check(not pcall(Camera.new, 3), "tuning that is not a table is refused")
        check(not pcall(Camera.new, setmetatable({}, {})), "tuning with a metatable is refused")
    end)

    case("camera.look's own checks are mirrored on float vectors", function()
        local a = vector.create(1, 2, 3)
        check(Camera.valid_look(a, vector.create(1, 2, 3.02), 10), "2 cm apart at 10 degrees is accepted")
        check(Camera.valid_look(a, vector.create(4, 2, 3), 150), "150 degrees is accepted")
        check(Camera.valid_look(a, vector.create(4, 2, 3), 0) and Camera.valid_look(a, vector.create(4, 2, 3)),
            "0 or no field of view is the camera's own, as in fov_at")
        check(not Camera.valid_look(a, vector.create(4, 2, 3), 9.99), "below 10 degrees is refused")
        check(not Camera.valid_look(a, vector.create(4, 2, 3), 150.01), "above 150 degrees is refused")
        check(not Camera.valid_look(a, vector.create(4, 2, 3), 0 / 0), "a NaN field of view is refused")
        check(select(2, Camera.valid_look(a, a, 70)) == "same_point", "the same point is refused")
        check(not Camera.valid_look(a, vector.create(1, 2, 3.005), 70), "5 mm apart is refused")
        check(not Camera.valid_look(vector.create(100001, 0, 0), a, 70), "beyond 100 km is refused")
        check(not Camera.valid_look(vector.create(math.huge, 0, 0), a, 70), "an infinite position is refused")
        check(not Camera.valid_look({ 1, 2, 3 }, a, 70), "camera.look takes vectors, not tables")
    end)

    case("at a standstill the view sits behind and above the bike", function()
        local rig = Camera.new()
        local view, plan = drive(rig, sample(vector.create(10, 2, -5)), H)
        check(plan.reset and view.reset, "the first step places the rig instead of following")
        check(Camera.valid_look(view.eye, view.target, view.fov), "the view is valid for camera.look")
        check(near(view.target.x, 10, 1e-5) and near(view.target.y, 3.1, 1e-5) and near(view.target.z, -5, 1e-5),
            "a still bike is aimed at its pivot")
        check(near(view.target.z - view.eye.z, 3, 1e-5) and near(view.eye.x, 10, 1e-5),
            "the eye is the rest distance behind a +Z-facing bike")
        check(near(view.eye.y - view.target.y, 0.9, 1e-5), "the eye is the rest height above the pivot")
        check(view.fov == 70 and not view.occluded and view.pull == 1, "a still, clear view is the base framing")
        check(near(vector.magnitude(plan.ray.from - view.target), 0, 1e-5), "the occlusion ray starts at the pivot")
        check(near(vector.magnitude(plan.ray.to - view.eye), tuning.clearance, 1e-4),
            "the occlusion ray reaches the clearance past the eye")
        view = drive(rig, sample(vector.create(10, 2, -5)), H)
        check(not view.reset, "a second still step follows")
        local turned = Camera.new()
        view = drive(turned, sample(vector.zero, nil, math.pi / 2), H)
        check(near(view.eye.x, -3, 1e-5) and near(view.eye.z, 0, 1e-5), "a +X-facing bike is viewed from -X")
    end)

    case("follow distance and height are spring-damped", function()
        local rig = Camera.new()
        local z = 0
        drive(rig, sample(vector.zero), H)
        local goal = tuning.distance + tuning.distance_per_speed * 8
        local last = rig:status().distance
        local first
        for i = 1, 180 do
            z += 8 * H
            drive(rig, sample(vector.create(0, 0, z), vector.create(0, 0, 8)), H)
            local d = rig:status().distance
            if i == 1 then first = d - last end
            check(d >= last - 1e-12 and d <= goal + 1e-9, "the arm lengthens without overshoot")
            last = d
        end
        check(first > 0 and first < 0.01, "the arm does not jump with a sudden speed")
        check(near(last, goal, 0.02 * goal), "the arm settles at the speed's distance")
        rig = Camera.new()
        drive(rig, sample(vector.zero), H)
        local height = rig:status().height
        for i = 1, 180 do
            drive(rig, sample(vector.zero, nil, 0, false), H)
            local h = rig:status().height
            check(h >= height - 1e-12, "the eye rises steadily in the air")
            if i == 6 then check(h < tuning.height + 0.5 * tuning.air_height, "the rise is not a snap") end
            height = h
        end
        check(near(height, tuning.height + tuning.air_height, 0.01), "the airborne height is reached")
        for _ = 1, 180 do drive(rig, sample(vector.zero), H) end
        check(near(rig:status().height, tuning.height, 0.01), "landing brings the eye back down")
    end)

    case("the aim leads the bike by its velocity", function()
        for _, speed in ipairs({ 2, 6 }) do
            local rig = Camera.new()
            local z, view = 0, nil
            for _ = 1, 240 do
                view = drive(rig, sample(vector.create(0, 0, z), vector.create(0, 0, speed)), H)
                z += speed * H
            end
            local lead = math.min(speed * tuning.look_ahead_seconds, tuning.look_ahead_max)
            check(near(view.target.z - (z - speed * H), lead, 0.01), "the aim leads by the capped look-ahead")
            check(near(view.target.y, tuning.pivot_height, 1e-5), "level riding does not tilt the aim")
        end
        -- Rolling backwards slowly, the bike still faces +Z and so does the arm;
        -- the backward look-ahead would lean the aim at the camera and is dropped.
        local rig = Camera.new()
        local z, view = 0, nil
        for _ = 1, 120 do
            view = drive(rig, sample(vector.create(0, 0, z), vector.create(0, 0, -0.5)), H)
            z -= 0.5 * H
        end
        check(view.eye.z < view.target.z and near(view.target.z, z + 0.5 * H, 1e-4),
            "a backward look-ahead never aims towards the camera")
    end)

    case("in the air the arm keeps the line of travel through a spin", function()
        local rig = Camera.new()
        local position = vector.zero
        local velocity = vector.create(0, 0, 5)
        for _ = 1, 120 do
            drive(rig, sample(position, velocity), H)
            position += velocity * H
        end
        local rest = rig:status()
        for i = 1, 60 do
            local spin = 2 * math.pi * i / 60
            local view = drive(rig, sample(position, vector.create(0, 4 - 9.8 * i * H, 5), spin, false), H)
            position += vector.create(0, 4 - 9.8 * i * H, 5) * H
            check(math.abs(rig:status().yaw) < 1e-6, "a 360 in the air does not turn the arm")
            check(view.airborne and pitch_of(view) <= tuning.max_pitch + 1e-4, "the airborne view stays within max pitch")
        end
        local air = rig:status()
        check(air.distance > rest.distance and air.height > rest.height, "the air pulls the arm back and up")
        -- At one speed the air adds its own pull-back and rise, not a speed's.
        local function settled_arm(grounded)
            local r = Camera.new()
            local p, v = vector.zero, vector.create(0, 0, 5)
            for _ = 1, 240 do
                p += v * H
                drive(r, sample(p, v, 0, grounded), H)
            end
            return r:status()
        end
        local on_ground, in_air = settled_arm(true), settled_arm(false)
        check(near(in_air.distance - on_ground.distance, tuning.air_distance, 0.01),
            "at the same speed the air lengthens the arm by air_distance")
        check(near(in_air.height - on_ground.height, tuning.air_height, 0.01), "and raises the eye by air_height")
        -- Towards the same new line of travel, the air turns softer than the ground.
        local function turned_after(grounded)
            local r = Camera.new()
            local p, v = vector.zero, vector.create(0, 0, 5)
            for _ = 1, 60 do
                p += v * H
                drive(r, sample(p, v, 0, grounded), H)
            end
            v = vector.create(5 * math.sin(0.5), 0, 5 * math.cos(0.5))
            for _ = 1, 15 do
                p += v * H
                drive(r, sample(p, v, 0, grounded), H)
            end
            return r:status().yaw / 0.5
        end
        -- A critically damped step response, the goal having moved across the
        -- first tick, so half a tick late.
        local function step_response(frequency)
            local x = frequency * (15 * H - 0.5 * H)
            return 1 - (1 + x) * math.exp(-x)
        end
        local ground_turn, air_turn = turned_after(true), turned_after(false)
        check(near(ground_turn, step_response(tuning.heading_frequency), 1e-3), "the ground heading spring runs at its frequency")
        check(near(air_turn, step_response(tuning.air_heading_frequency), 1e-3), "the air heading spring runs at its own")
        check(ground_turn > 2 * air_turn, "so the air turns the arm more slowly")
        -- With no line of travel the arm holds its heading instead of spinning.
        local still = Camera.new()
        drive(still, sample(vector.zero), H)
        for i = 1, 60 do
            drive(still, sample(vector.zero, vector.create(0, 2, 0), 2 * math.pi * i / 60, false), H)
            check(math.abs(still:status().yaw) < 1e-6, "a spin straight up holds the heading")
        end
        -- On the ground at a standstill the arm turns to the bike's facing.
        local ground = Camera.new()
        drive(ground, sample(vector.zero), H)
        local previous = 0
        for i = 1, 180 do
            drive(ground, sample(vector.zero, nil, math.pi / 2), H)
            local yaw = ground:status().yaw
            check(yaw >= previous - 1e-12 and yaw <= math.pi / 2 + 1e-9, "the turn is damped, without overshoot")
            if i == 1 then check(yaw < 0.05, "the arm does not snap to a new facing") end
            previous = yaw
        end
        check(near(previous, math.pi / 2, 0.01), "the arm settles behind the turned bike")
    end)

    case("a turn across a half turn of heading goes the short way", function()
        local from, to = math.pi - 0.3, 0.3 - math.pi
        local rig = Camera.new()
        drive(rig, sample(vector.zero, nil, from), H)
        local previous, turned = rig:status().yaw, 0
        for _ = 1, 180 do
            drive(rig, sample(vector.zero, nil, to), H)
            local yaw = rig:status().yaw
            local step = wrap(yaw - previous)
            check(step >= -1e-12 and step < 0.02, "each tick turns a little, through +-pi rather than round")
            turned += step
            previous = yaw
        end
        check(near(turned, 0.6, 0.01) and near(wrap(previous - to), 0, 0.01), "the arm turned 0.6 rad onto the new facing")
    end)

    case("rolling backwards keeps the arm behind the rider without swinging", function()
        -- Fakie: the bike faces one way and rolls the other. A hair of sideways
        -- drift that changes sign must not flip the heading goal between the
        -- two sides of a half turn, at any speed through the heading blend.
        for _, facing in ipairs({ 0, 2.0, math.pi - 0.02 }) do
            local ahead = vector.create(math.sin(facing), 0, math.cos(facing))
            local side = vector.create(math.cos(facing), 0, -math.sin(facing))
            for _, speed in ipairs({ 1.2, 1.5, 2.0, 2.6, 6 }) do
                for _, drift in ipairs({ 0, 0.02 }) do
                    local rig = Camera.new()
                    local position, previous, turned = vector.zero, nil, 0
                    for i = 0, 540 do
                        -- The drift changes sign every second.
                        local velocity = ahead * -speed + side * (drift * math.sin(math.pi * i * H))
                        position += velocity * H
                        drive(rig, sample(position, velocity, facing), H)
                        local yaw = rig:status().yaw
                        check(math.abs(wrap(yaw - facing)) < 0.02, "rolling backwards the arm stays behind the rider")
                        if previous then
                            local step = math.abs(wrap(yaw - previous))
                            check(step < 0.002, "rolling backwards the arm never swings")
                            turned += step
                        end
                        previous = yaw
                    end
                    check(turned < 0.1, "nine seconds of drift turn the arm less than 0.1 rad in all")
                    if drift == 0 then
                        check(math.abs(wrap(previous - facing)) < 1e-6, "straight backwards the arm is square behind the rider")
                    end
                end
            end
        end
        -- Slowing from a fast backwards roll passes through the whole blend.
        local rig = Camera.new()
        local position = vector.zero
        for i = 0, 300 do
            local velocity = vector.create(0.03 * math.sin(7 * i * H), 0, -10 * (1 - i / 300))
            position += velocity * H
            drive(rig, sample(position, velocity, 0), H)
            check(math.abs(rig:status().yaw) < 0.02, "slowing from a backwards roll keeps the arm behind the rider")
        end
        -- A steady slip rolling backwards is followed on the reversed line.
        rig, position = Camera.new(), vector.zero
        local slipping = vector.create(6 * math.sin(0.3), 0, -6 * math.cos(0.3))
        for _ = 1, 240 do
            position += slipping * H
            drive(rig, sample(position, slipping, 0), H)
        end
        check(near(rig:status().yaw, -0.3, 0.01), "the arm lies on the reversed line of travel")
        -- A backwards hop keeps that frame in the air instead of turning to the line of travel.
        rig, position = Camera.new(), vector.zero
        local back = vector.create(0, 0, -3)
        for _ = 1, 120 do
            position += back * H
            drive(rig, sample(position, back, 0), H)
        end
        for i = 1, 30 do
            local velocity = vector.create(0, 3 - 9.8 * i * H, -3)
            position += velocity * H
            drive(rig, sample(position, velocity, 0, false), H)
            check(math.abs(rig:status().yaw) < 0.02, "a backwards hop does not swing the arm round")
        end
    end)

    case("the heading goal is continuous all the way round the facing", function()
        -- Travel square to the facing is where the line of travel changes
        -- ends; the goal must not jump there, nor straight backwards.
        local facing = 0.4
        for _, run in ipairs({ { speed = 1.5 }, { speed = 3 }, { speed = 6 }, { speed = 20 },
            { speed = 6, overrides = { heading_speed_low = 0 } } }) do
            local previous, largest = nil, 0
            for k = 0, 3142 do
                local travel = facing - math.pi + k * 0.002
                local velocity = vector.create(run.speed * math.sin(travel), 0, run.speed * math.cos(travel))
                local yaw = heading_goal(sample(vector.zero, velocity, facing), run.overrides)
                if previous then largest = math.max(largest, math.abs(wrap(yaw - previous))) end
                previous = yaw
            end
            check(largest < 0.1, "a 0.002 rad change of travel moves the goal less than 0.1 rad at " .. run.speed .. " m/s")
        end
        local ahead = heading_goal(sample(vector.zero, vector.create(6 * math.sin(0.7), 0, 6 * math.cos(0.7)), 0.4))
        check(near(ahead, 0.7, 1e-6), "fast travel ahead is followed on its own line")
        local square = heading_goal(sample(vector.zero, vector.create(6 * math.sin(0.4 + math.pi / 2), 0,
            6 * math.cos(0.4 + math.pi / 2)), 0.4))
        check(near(square, 0.4, 1e-6), "travel square to the facing leaves the facing")
    end)

    case("falling aims at the landing and the vertical lag is bounded", function()
        local rig = Camera.new()
        local y = 20
        drive(rig, sample(vector.create(0, y, 0)), H)
        local view
        for _ = 1, 30 do
            -- The policy reads the float vector, so the expected pivot does too.
            y = vector.create(0, y - 8 * H, 0).y
            view = drive(rig, sample(vector.create(0, y, 0), vector.create(0, -8, 4), 0, false), H)
            local lag = rig:status().pivot - (y + tuning.pivot_height)
            check(lag >= -1e-9 and lag <= tuning.vertical_lag_limit + 1e-9, "the pivot trails a drop by at most its limit")
            check(pitch_of(view) <= tuning.max_pitch + 1e-4, "the view never pitches past max_pitch")
        end
        check(view.target.y < rig:status().pivot - 0.5, "a falling bike is aimed below, towards its landing")
        -- Sinking at 2 m/s for a second, the ground follow keeps closer than the air's.
        local function lag_after(grounded)
            local r = Camera.new()
            local h = 20
            drive(r, sample(vector.create(0, h, 0), vector.create(0, -2, 0), 0, grounded), H)
            for _ = 1, 60 do
                h = vector.create(0, h - 2 * H, 0).y
                drive(r, sample(vector.create(0, h, 0), vector.create(0, -2, 0), 0, grounded), H)
            end
            return r:status().pivot - (h + tuning.pivot_height)
        end
        check(lag_after(false) > lag_after(true) + 0.3, "the air follow is softer than the ground's")
        -- On the ground the vertical follow is stiff again.
        for _ = 1, 180 do view = drive(rig, sample(vector.create(0, y, 0)), H) end
        check(near(rig:status().pivot, y + tuning.pivot_height, 1e-3) and near(view.target.y, y + tuning.pivot_height, 1e-3),
            "after landing the aim returns to the pivot")
    end)

    case("speed widens the field of view within camera.look's range", function()
        local function settled(speed, grounded, overrides)
            local rig = Camera.new(overrides)
            local z, view = 0, nil
            for _ = 1, 360 do
                view = drive(rig, sample(vector.create(0, 0, z), vector.create(0, 0, speed), 0, grounded), H)
                z += speed * H
            end
            return view.fov
        end
        check(settled(0) == 70, "a still bike has the base field of view")
        check(near(settled(12), 82, 0.01), "full speed reaches the fast field of view")
        -- A quarter of full speed is a smoothstep's 0.15625 of the widening, not a quarter of it.
        check(near(settled(3), 70 + 12 * 0.15625, 0.01), "the widening eases in with speed")
        check(near(settled(40), 82, 0.01), "the field of view stops widening past full speed")
        check(near(settled(12, false), 85, 0.01), "the air adds its few degrees")
        check(settled(30, false, { fov = 150, fast_fov = 150, air_fov = 20 }) == 150, "the widest view is 150 degrees")
        check(settled(30, false, { fov = 10, fast_fov = 10, air_fov = -20 }) == 10, "the narrowest view is 10 degrees")
        local rig = Camera.new()
        drive(rig, sample(vector.zero), H)
        local view = drive(rig, sample(vector.create(0, 0, 12 * H), vector.create(0, 0, 12)), H)
        check(view.fov > 70 and view.fov < 71, "a sudden speed widens the view gradually")
    end)

    case("a hit pulls the eye in at once and clear space eases it out", function()
        local rig = Camera.new()
        drive(rig, sample(vector.zero), H)
        local view, plan = drive(rig, sample(vector.zero), H, wall(-1.5))
        local hit = wall(-1.5)(plan.ray.from, plan.ray.to)
        check(view.occluded and view.eye.z > -1.5, "the eye is pulled in front of the wall on the first frame")
        check(near(vector.magnitude(hit - view.eye), tuning.clearance, 1e-4), "the eye keeps the clearance from the hit")
        check(near(flat_distance(view.eye, view.target) / vector.magnitude(view.eye - view.target),
            flat_distance(plan.ray.to, plan.ray.from) / vector.magnitude(plan.ray.to - plan.ray.from), 1e-4),
            "the eye slides along the arm, not out of it")
        check(Camera.valid_look(view.eye, view.target, view.fov), "a pulled-in view is valid for camera.look")
        local pull = view.pull
        local pulled = pull
        for i = 1, 180 do
            view = drive(rig, sample(vector.zero), H)
            check(not view.occluded and view.pull >= pull, "clear space only lets the eye out")
            if i == 1 then check(view.pull - pull < 0.05, "the eye eases out rather than snapping back") end
            check(near(view.pull, 1 - (1 - pulled) * math.exp(-tuning.release_rate * i * H), 1e-9),
                "the release is the exact exponential approach, not a stepped one")
            pull = view.pull
        end
        check(pull > 0.99, "the eye returns to the free arm")
        -- A step replaced before it was resolved still counts its time towards the release.
        local function released(resolve_each)
            local r = Camera.new()
            drive(r, sample(vector.zero), H)
            drive(r, sample(vector.zero), H, wall(-1.5))
            assert(r:step(sample(vector.zero), H))
            if resolve_each then assert(r:resolve(nil)) end
            assert(r:step(sample(vector.zero), H))
            return assert(r:resolve(nil)).pull
        end
        check(released(false) > pulled + 0.01 and near(released(false), released(true), 1e-12),
            "two steps and one resolve release as far as two resolved steps")
        view, plan = drive(rig, sample(vector.zero), H, wall(-0.2))
        check(near(view.distance, tuning.min_distance, 1e-9) and view.occluded, "a hit at the rider stops at min_distance")
        local free_arm = vector.magnitude(plan.ray.to - plan.ray.from) - tuning.clearance
        check(near(view.pull * free_arm, tuning.min_distance, 1e-5), "and the release starts from min_distance, not nearer")
        check(Camera.valid_look(view.eye, view.target, view.fov), "the shortest arm still gives a valid view")
        plan = assert(rig:step(sample(vector.zero), H))
        local issue
        view, issue = rig:resolve(vector.create(5, 5, 5))
        check(view == nil and issue == "hit_off_ray", "a hit that is not on the step's ray is refused")
        view, issue = rig:resolve("wall")
        check(view == nil and issue == "invalid_hit", "a hit that is not a position is refused")
        check(rig:status().pending and rig:resolve(nil) ~= nil, "a refused hit leaves the plan to resolve")
        view, issue = rig:resolve(nil)
        check(view == nil and issue == "no_plan", "each step resolves once")
        local free = Camera.new()
        plan = assert(free:step(sample(vector.zero), H))
        view = assert(free:resolve(plan.ray.to))
        check(not view.occluded and view.pull == 1, "a hit at the ray's end, a clearance past the eye, leaves the arm free")
        -- Far out the ray's end is a float some millimetres from where the plan
        -- put it, and a hit there is still not an obstruction.
        local random = random_source(7)
        for _ = 1, 400 do
            local far = Camera.new()
            local position = vector.create(random(-99800, 99800), random(-99800, 99800), random(-99800, 99800))
            plan = assert(far:step(sample(position, nil, random(-3, 3), random(0, 1) < 0.5), H))
            view = assert(far:resolve(plan.ray.to))
            check(not view.occluded and view.pull == 1, "a hit at a far ray's end leaves the arm free")
        end
    end)

    case("a steep, pulled-in arm keeps the eye and the aim apart horizontally", function()
        local rig = Camera.new({ height = 4, max_pitch = 1.4, min_distance = 0.3, min_separation = 0.3 })
        local plan = assert(rig:step(sample(vector.create(4, 1, -7)), H))
        local view = assert(rig:resolve(plan.ray.from))
        check(view.occluded and near(view.distance, 0.3, 1e-9), "a hit at the pivot holds the eye at min_distance")
        check(near(vector.magnitude(view.eye - plan.ray.from), 0.3, 1e-5), "the eye stays on its arm")
        -- On that steep arm the eye is only 0.18 m out horizontally, so the aim moves out instead.
        check(flat_distance(view.eye, view.target) >= 0.3 - 1e-5, "the aim keeps min_separation horizontally")
        check(pitch_of(view) <= 1.4 + 1e-6, "and the view stays within max_pitch")
        check(Camera.valid_look(view.eye, view.target, view.fov), "the guarded view is valid for camera.look")
        -- A height steeper than max_pitch is capped on the arm, so the eye
        -- comes down rather than the aim being lifted off the rider.
        local capped = Camera.new({ height = 4, max_pitch = 0.5 })
        view = drive(capped, sample(vector.create(4, 1, -7)), H)
        check(near(view.target.y, 1 + tuning.pivot_height, 1e-5), "the aim stays on the pivot")
        check(near(view.eye.y - view.target.y, tuning.distance * math.tan(0.5), 1e-5), "the eye rises only to max_pitch")
    end)

    case("teleports, large jumps and long gaps reset the rig", function()
        local function moving()
            local rig = Camera.new()
            local z = 0
            for _ = 1, 120 do
                drive(rig, sample(vector.create(0, 0, z), vector.create(0, 0, 6)), H)
                z += 6 * H
            end
            return rig, z
        end
        local rig, z = moving()
        local view, plan = drive(rig, sample(vector.create(0, 0, z), vector.create(0, 0, 6)), H)
        check(not plan.reset, "motion its velocity explains is followed")
        view, plan = drive(rig, sample(vector.create(500, 0, 500), vector.zero, math.pi, true, { teleport = true }), H)
        check(plan.reset and view.reset, "a teleport flag resets the rig")
        check(near(view.eye.z - 500, 3, 1e-4) and near(view.eye.x, 500, 1e-4) and view.fov == 70,
            "after a reset the view is the rest framing behind the new facing")
        rig, z = moving()
        view, plan = drive(rig, sample(vector.create(0, 0, z + 10), vector.zero), H)
        check(plan.reset, "a jump the velocity cannot explain resets the rig")
        rig, z = moving()
        view, plan = drive(rig, sample(vector.create(0, 0, z + 2), vector.create(0, 0, 6)), H)
        check(not plan.reset, "a small unexplained step is still followed")
        rig, z = moving()
        view, plan = drive(rig, sample(vector.create(0, 0, z + 3.6), vector.create(0, 0, 6)), 0.6)
        check(plan.reset, "a gap longer than reset_gap resets the rig")
        rig, z = moving()
        rig:reset()
        check(not rig:status().ready, "reset() empties the rig")
        view, plan = drive(rig, sample(vector.create(0, 0, z), vector.create(0, 0, 6)), H)
        check(plan.reset, "the step after reset() places the rig")
        rig, z = moving()
        assert(rig:step(sample(vector.create(0, 0, z), vector.zero, 0, true, { teleport = true }), H))
        assert(rig:step(sample(vector.create(0, 0, z), vector.zero), H))
        check(rig:resolve(nil).reset, "a reset is not lost when an unresolved plan is replaced")
    end)

    -- An authored ride sampled at `rate` Hz from t = 0 to 1 s. Returns the views
    -- at 0.5 s and 1 s. `motion(i, rate)` gives the sample at t = i / rate.
    local function ride(rate, motion, cast)
        local rig = Camera.new()
        local half, last
        for i = 0, rate do
            local view = drive(rig, motion(i, rate), 1 / rate, cast)
            if i * 2 == rate then half = view end
            last = view
        end
        return half, last
    end
    -- A 10 m radius turn at 6 m/s with a hop from 0.25 s to 0.75 s and a 360
    -- in it: heading, look-ahead, air framing and the vertical follow all move.
    local function carve(i, rate)
        local t = i / rate
        local heading = 0.6 * t
        local airborne = i * 4 >= rate and i * 4 < 3 * rate
        local air_t = t - 0.25
        local y = airborne and (2.45 * air_t - 4.9 * air_t * air_t) or 0
        local vy = airborne and (2.45 - 9.8 * air_t) or 0
        local spin = airborne and 2 * math.pi * air_t / 0.5 or 0
        return sample(vector.create(10 - 10 * math.cos(heading), y, 10 * math.sin(heading)),
            vector.create(6 * math.sin(heading), vy, 6 * math.cos(heading)), heading + spin, not airborne)
    end
    -- Accelerating away from a wall that starts inside the arm: distance,
    -- field of view and the pull-in release all move.
    local function launch(i, rate)
        local t = i / rate
        return sample(vector.create(0, 0, 4 * t * t), vector.create(0, 0, 8 * t))
    end

    case("60 Hz and 120 Hz agree over one second", function()
        for _, scenario in ipairs({ { motion = carve }, { motion = launch, cast = wall(-2) } }) do
            local half_60, last_60 = ride(60, scenario.motion, scenario.cast)
            for _, rate in ipairs({ 120, 144 }) do
                local half, last = ride(rate, scenario.motion, scenario.cast)
                for _, pair in ipairs({ { half_60, half }, { last_60, last } }) do
                    local a, b = pair[1], pair[2]
                    check(vector.magnitude(a.eye - b.eye) < 0.01, "the eye agrees within 1 cm at " .. rate .. " Hz")
                    check(vector.magnitude(a.target - b.target) < 0.01, "the aim agrees within 1 cm at " .. rate .. " Hz")
                    check(math.abs(a.fov - b.fov) < 0.05, "the field of view agrees within 0.05 degrees at " .. rate .. " Hz")
                    check(math.abs(a.pull - b.pull) < 0.005, "the pull-in agrees at " .. rate .. " Hz")
                end
            end
            if scenario.cast then check(half_60.pull < last_60.pull and last_60.pull < 1, "the release was exercised") end
        end
    end)

    case("each rate follows the continuous solution of the follow", function()
        -- The launch with no wall: the speed is 8t, so the arm's goal is 3 + 0.64t
        -- and the field of view's 70 + 12 smoothstep(8t / 12). The references
        -- integrate the same spring and approach finely from those curves.
        local function references(seconds)
            local arm = integrate(function(t, x)
                return { x[2], tuning.distance_frequency ^ 2 * (3 + 0.64 * t - x[1]) - 2 * tuning.distance_frequency * x[2] }
            end, { 3, 0 }, seconds)
            local fov = integrate(function(t, x)
                local u = math.clamp(8 * t / 12, 0, 1)
                return { tuning.fov_rate * (70 + 12 * u * u * (3 - 2 * u) - x[1]) }
            end, { 70 }, seconds)
            return arm[1], fov[1]
        end
        local arm_half, fov_half = references(0.5)
        local arm_end, fov_end = references(1)
        for _, rate in ipairs({ 60, 120 }) do
            local rig = Camera.new()
            local at_half
            for i = 0, rate do
                drive(rig, launch(i, rate), 1 / rate)
                if i * 2 == rate then at_half = rig:status() end
            end
            local at_end = rig:status()
            check(near(at_half.distance, arm_half, 1e-6) and near(at_end.distance, arm_end, 1e-6),
                "the arm spring is exact at " .. rate .. " Hz")
            check(near(at_half.fov, fov_half, 0.003) and near(at_end.fov, fov_end, 0.003),
                "the field of view follows its curve at " .. rate .. " Hz")
        end
    end)

    case("samples in any position form give the same view", function()
        local forms = {
            { position = vector.create(1, 2, 3), velocity = vector.create(0, 0, 4), rotation = yaw_rotation(0.3) },
            { position = { 1, 2, 3 }, velocity = { 0, 0, 4 }, rotation = yaw_rotation(0.3) },
            { position = { x = 1, y = 2, z = 3 }, velocity = { x = 0, y = 0, z = 4 },
                rotation = { x = 0, y = math.sin(0.15), z = 0, w = math.cos(0.15) } },
        }
        local first
        for _, form in ipairs(forms) do
            form.grounded = true
            local view = drive(Camera.new(), form, H)
            first = first or view
            check(vector.magnitude(view.eye - first.eye) < 1e-6 and vector.magnitude(view.target - first.target) < 1e-6,
                "vectors, arrays and named fields read alike")
        end
    end)

    case("malformed samples are refused without moving the rig", function()
        local rig = Camera.new()
        drive(rig, sample(vector.create(0, 0, 0), vector.create(0, 0, 3)), H)
        local before = rig:status()
        local good = sample(vector.create(0, 0, 3 * H), vector.create(0, 0, 3))
        local function with(changes)
            local s = table.clone(good)
            for key, value in pairs(changes) do s[key] = value end
            return s
        end
        local refusals = {
            { with({ position = vector.create(0 / 0, 0, 0) }), H, "invalid_position" },
            { with({ position = "here" }), H, "invalid_position" },
            { with({ position = vector.create(99950, 0, 0) }), H, "position_out_of_range" },
            { with({ velocity = vector.create(0, 0, 200) }), H, "invalid_velocity" },
            { with({ velocity = { 0, 0 } }), H, "invalid_velocity" },
            { with({ rotation = { 0, 0, 0, 0.9 } }), H, "invalid_rotation" },
            { with({ rotation = vector.create(0, 0, 1) }), H, "invalid_rotation" },
            { with({ grounded = "yes" }), H, "invalid_grounded" },
            { with({ teleport = 1 }), H, "invalid_teleport" },
            { setmetatable(table.clone(good), {}), H, "invalid_sample" },
            { good, 0, "invalid_seconds" },
            { good, -H, "invalid_seconds" },
            { good, 0 / 0, "invalid_seconds" },
            { good, 2, "invalid_seconds" },
        }
        local missing = table.clone(good)
        missing.grounded = nil
        table.insert(refusals, { missing, H, "invalid_grounded" })
        for _, refusal in ipairs(refusals) do
            local plan, issue = rig:step(refusal[1], refusal[2])
            check(plan == nil and issue == refusal[3], "refused as " .. refusal[3])
        end
        local after = rig:status()
        for key, value in pairs(before) do check(after[key] == value, "a refused sample leaves " .. key .. " alone") end
        check(drive(rig, good, H) ~= nil, "the rig carries on with the next good sample")
    end)

    case("every view in a constructed sweep is valid for camera.look", function()
        local random = random_source(20261025)
        local bound = 1e5 - 150
        local views = 0
        for _ = 1, 150 do
            local overrides = {}
            if random(0, 1) < 0.5 then
                overrides = { distance = random(0, 12), min_distance = random(0, 3), max_distance = random(0, 12),
                    height = random(-1, 6), air_height = random(0, 4), max_pitch = random(0, 2),
                    min_separation = random(0, 2), clearance = random(0, 2), look_ahead_max = random(0, 8),
                    fov = random(0, 200), fast_fov = random(0, 200), air_fov = random(-30, 30) }
            end
            local rig = Camera.new(overrides)
            local t = rig:tuning()
            local position = vector.create(random(-bound, bound), random(-bound, bound), random(-bound, bound))
            for _ = 1, 30 do
                local velocity = vector.create(random(-60, 60), random(-30, 30), random(-60, 60))
                local q = { random(-1, 1), random(-1, 1), random(-1, 1), random(-1, 1) }
                local n = math.sqrt(q[1] ^ 2 + q[2] ^ 2 + q[3] ^ 2 + q[4] ^ 2)
                for k = 1, 4 do q[k] /= n end
                local seconds = ({ 1 / 30, 1 / 60, 1 / 120, 1 / 144, 0.2, 0.7 })[math.floor(random(1, 6.999))]
                position += velocity * seconds
                if math.max(math.abs(position.x), math.abs(position.y), math.abs(position.z)) > bound then
                    position = vector.create(random(-bound, bound), random(-bound, bound), random(-bound, bound))
                end
                local s = { position = position, velocity = velocity, rotation = q, grounded = random(0, 1) < 0.5,
                    teleport = random(0, 1) < 0.05 }
                local plan = assert(rig:step(s, seconds))
                local hit = nil
                if random(0, 1) < 0.4 then hit = plan.ray.from + (plan.ray.to - plan.ray.from) * random(0, 1) end
                local view, issue = rig:resolve(hit)
                check(view ~= nil, "a sweep step resolves: " .. tostring(issue))
                check(Camera.valid_look(view.eye, view.target, view.fov), "the sweep view is valid for camera.look")
                check(view.fov >= 10 and view.fov <= 150, "the sweep field of view is in range")
                check(vector.magnitude(view.eye - view.target) >= 0.9 * t.min_separation, "the sweep keeps its separation")
                check(pitch_of(view) <= t.max_pitch + 1e-6, "the sweep keeps its pitch, on the floats camera.look reads")
                views += 1
            end
        end
        check(views == 4500, "every sweep step produced a view")
    end)

    return { cases = cases, assertions = assertions, native_actions = 0 }
end

return Tests

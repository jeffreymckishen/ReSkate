-- Pure Luau cases for rubric_metrics.lua. Nothing runs on require; call
-- require("./rubric_metrics_tests").run(progress) from a Luau runner. The
-- synthetic traces below are constructed with known answers, and the driven
-- cases ride sim_scenarios.lua, camera_policy.lua and grind_policy.lua over
-- authored worlds and fixtures. Passing here is not in-game or native
-- evidence, and an offline score is not the human-judged likeness score.
local Metrics = require("./rubric_metrics")
local Scenarios = require("./sim_scenarios")
local World = require("./sim_world")
local Camera = require("./camera_policy")
local Grind = require("./grind_policy")
local Pegs = require("./peg_geometry")
local Forces = require("./forces")
local M = require("./force_math")
local Tests = {}
local H = Forces.native_seconds

local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end
local function frozen_deep(t)
    if not table.isfrozen(t) then return false end
    for _, v in pairs(t) do
        if type(v) == "table" and not frozen_deep(v) then return false end
    end
    return true
end

-- A level, touching tyre row as sim_world.lua reports one.
local function wheel(height, hub_z, status)
    local hit = status ~= "clear" and height <= .15
    return { status = hit and "hit" or "clear", separation = hit and height or nil, clearance = height,
        hub = { 0, .3, hub_z }, supported = hit and height <= .005 and height >= -.10 }
end
-- A constructed straight-line record along +Z.
local function record(i, z, speed, extra)
    local r = { time = i * H, position = { 0, 1, z }, velocity = { 0, 0, speed }, speed = speed, forward_speed = speed,
        yaw = 0, pitch = 0, lean = 0, valid = true, front = wheel(0, z + .47), rear = wheel(0, z - .47) }
    for key, value in pairs(extra or {}) do r[key] = value end
    return r
end

-- Grind fixture: the top of a round rail one metre up along world +Z, with
-- the anchor peg's underside placed on it, as grind_policy_tests.lua does.
local rail_point = { 0, 1, 0 }
local function grind_body(speed, closing)
    local body = { orientation = { 0, 0, 0, 1 }, center_of_mass = { 0, 0, 0 },
        linear_velocity = { 0, -closing, speed }, angular_velocity = { 0, 0, 0 } }
    local peg = Pegs.peg("rear_left")
    body.center_of_mass = M.add(M.sub(rail_point, Pegs.to_world(body, peg.center)), { 0, peg.radius, 0 })
    return body
end
local function grind_observe(body, touching, hop)
    local contacts = { pegs = {}, tires = { front = { available = true, touching = false },
        rear = { available = true, touching = false } } }
    for _, name in ipairs(Pegs.names()) do contacts.pegs[name] = { available = true, touching = false } end
    for _, name in ipairs(touching) do
        local peg = Pegs.peg(name)
        contacts.pegs[name] = { available = true, touching = true,
            point = M.sub(Pegs.to_world(body, peg.center), { 0, peg.radius, 0 }), normal = { 0, 1, 0 },
            tangent = { 0, 0, 1 }, separation = 0, surface_velocity = { 0, 0, 0 }, friction = .12 }
    end
    return { seconds = H, body = body, ground_support = false, contacts = contacts,
        input = { enabled = true, lean = 0, hop = hop == true } }
end

function Tests.run(progress)
    local cases, assertions = 0, 0
    local function check(condition, message)
        assertions += 1
        assert(condition, message)
    end
    local function near(a, b, tolerance) return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (tolerance or 1e-12) end
    local function close(a, b, relative)
        return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (relative or 1e-9) * math.max(1, math.abs(b))
    end
    local function case(name, body)
        cases += 1
        local ok, why = pcall(body)
        if not ok then error(name .. ": " .. tostring(why), 0) end
        if type(progress) == "function" then progress(cases, assertions) end
    end

    case("inert module and cited targets", function()
        check(table.isfrozen(Metrics), "the module table is frozen")
        check(frozen_deep(Metrics.targets) and frozen_deep(Metrics.tolerance) and frozen_deep(Metrics.brake_bands)
            and table.isfrozen(Metrics.early_pedal_band), "targets, tolerances and bands are frozen")
        check(string.find(Metrics.disclaimer, "not the human-judged likeness score", 1, true) ~= nil,
            "the disclaimer says an offline score is not the likeness score")
        check(Metrics.tolerance.margin == .10 and Metrics.tolerance.falloff == .50, "the authored tolerance")
        check(Metrics.contact_gap == Forces.tuning().contact_gap, "contact gap is forces.lua's")
        local count, scenarios = 0, {}
        for _, id in ipairs(Metrics.extracted) do scenarios[id] = true end
        for id, t in pairs(Metrics.targets) do
            count += 1
            check(scenarios[string.match(id, "^(S%d%d)%.")] == true, "target on an extracted scenario " .. id)
            check(Metrics.category(id) ~= "none", "target has a rubric category " .. id)
            check(#t.observed >= 1, "target has observations " .. id)
            for _, v in ipairs(t.observed) do check(M.finite(v) and v > 0, "observation finite and positive " .. id) end
            check(#t.sources >= 1, "target cites a source " .. id)
            for _, s in ipairs(t.sources) do
                check(string.match(s, "^[%w_%-%./]+%.%a+:%d+$") ~= nil or string.match(s, "^[%w_%-%./]+%.%a+:%d+%-%d+$") ~= nil,
                    "source is file:line " .. s)
                check(string.find(s, "calibration", 1, true) == nil and string.find(s, "evidence", 1, true) == nil
                    and string.find(s, "streets", 1, true) == nil, "source is not a decoded-settings or decompiler note " .. s)
            end
            check(#t.caveats >= 1 and type(t.definition) == "string" and type(t.unit) == "string", "target is explained " .. id)
            check(t.unit == Metrics.unit(id), "target unit matches the metric unit " .. id)
            check(t.margin == Metrics.tolerance.margin and t.falloff == Metrics.tolerance.falloff, "target uses the stated tolerance " .. id)
        end
        check(count == 7, "seven recorded targets")
        -- R3 rise and airtime read the same three native captures.
        local function cites(t, source)
            for _, s in ipairs(t.sources) do if string.find(s, source, 1, true) then return true end end
            return false
        end
        local rise, air = Metrics.targets["S05.r3_quick_hop.apex_rise"], Metrics.targets["S05.r3_quick_hop.airtime"]
        for _, pair in ipairs({ { "COMPARISON.md:36", "COMPARISON.md:36" }, { "COMPARISON.md:37", "COMPARISON.md:37" },
            { "comparison-v1-history.md:25", "comparison-v1-history.md:26" },
            { "actual-flat04-fits.json:46-47", "actual-flat04-fits.json:61" } }) do
            check(cites(rise, pair[1]) and cites(air, pair[2]), "R3 rise and airtime cite one capture " .. pair[2])
        end
        check(#air.observed == 4 and math.min(table.unpack(air.observed)) == 1.36 and math.max(table.unpack(air.observed)) == 1.43,
            "four R3 airtimes, 1.36 to 1.43 s")
        check(Metrics.category("S01.flat.x") == "riding_steering" and Metrics.category("S06.a.b") == "ramps_landings"
            and Metrics.category("S07.a.b") == "tricks" and Metrics.category("S22.a.b") == "grinds_pegs_stalls"
            and Metrics.category("S32.a.b") == "camera" and Metrics.category("S33.a") == "none"
            and Metrics.category("summary") == "none", "rubric categories by scenario number")
    end)

    case("score against a constructed target", function()
        local single = { observed = { 2 }, margin = .1, falloff = .5 }
        local s = Metrics.score(2, single)
        check(s.score == 1 and s.within and s.low == 1.8 and near(s.high, 2.2) and s.relative_error == 0, "the observation scores 1")
        s = Metrics.score(2.2, single)
        check(s.score == 1 and s.within, "the band edge scores 1")
        s = Metrics.score(2.7, single)
        check(near(s.score, .5, 1e-12) and not s.within and near(s.relative_error, .35), "half the falloff beyond scores 0.5")
        check(Metrics.score(3.2, single).score == 0 and Metrics.score(9, single).score == 0, "the falloff and beyond score 0")
        check(near(Metrics.score(1.55, single).score, .75, 1e-12), "below the band falls the same way")
        local range = { observed = { 3, 2 }, margin = .1, falloff = .5 }
        s = Metrics.score(3.25, range)
        check(s.score == 1 and s.midpoint == 2.5 and s.low == 1.75 and s.high == 3.25, "a range is widened by its midpoint")
        check(Metrics.score(4.5, range).score == 0, "a range falls to 0 at falloff times its midpoint")
        check(table.isfrozen(s), "a score is frozen")
        local _, issue = Metrics.score(0 / 0, single)
        check(issue == "value_not_finite", "nan is refused")
        _, issue = Metrics.score(math.huge, single)
        check(issue == "value_not_finite", "inf is refused")
        for _, bad in ipairs({ { observed = {} }, { observed = { 0 }, margin = .1, falloff = .5 },
            { observed = { 1 }, margin = -1, falloff = .5 }, { observed = { 1 }, margin = .1, falloff = 0 },
            { observed = { 0 / 0 }, margin = .1, falloff = .5 }, {} }) do
            _, issue = Metrics.score(1, bad)
            check(issue == "invalid_target", "a malformed target is refused")
        end
    end)

    case("pedal curve on a constructed constant acceleration", function()
        local trace = {}
        for i = 1, 300 do
            local t = i * H
            trace[i] = record(i, t * t / 2, t)
        end
        local initial = { time = 0, position = { 0, 1, 0 }, speed = 0 }
        local m = Metrics.pedal(trace, 1, 300, { initial = initial })
        check(near(m.early_acceleration, 1, 1e-9), "early acceleration is the slope")
        local inside = 0
        for i = 1, 300 do if trace[i].speed >= .52 and trace[i].speed <= 3.87 then inside += 1 end end
        check(m.early_samples == inside and inside > 50, "early samples are the band's records")
        check(near(m.mean_acceleration, 1, 1e-9) and near(m.peak_acceleration, 1, 1e-9)
            and near(m.plateau_acceleration, 1, 1e-9), "constant acceleration everywhere")
        check(m.time_to_3 >= 3 - 1e-9 and m.time_to_3 < 3 + H and m.time_to_6 == nil and m.time_to_7_5 == nil,
            "time to 3 m/s, and 6 m/s never reached")
        check(m.speed_at_1 >= 1 - 1e-6 and m.speed_at_1 < 1 + H and m.speed_at_4 == trace[240].time
            and m.speed_at_0_5 ~= nil, "the curve samples")
        check(near(m.distance, trace[300].position[3], 1e-9) and near(m.seconds, 300 * H, 1e-9), "distance and seconds")
        -- A saturating curve reaches a plateau.
        for i = 1, 300 do trace[i] = record(i, 0, math.min(i * H, 4)) end
        m = Metrics.pedal(trace, 1, 300, { initial = initial })
        check(math.abs(m.plateau_acceleration) <= 1e-12 and m.end_speed == 4, "a plateau gains nothing")
        check(near(m.early_acceleration, 1, 1e-9), "the early band is still the slope")
        -- Without an initial state the first record is the start, one step earlier.
        m = Metrics.pedal(trace, 1, 300)
        check(near(m.seconds, 300 * H, 1e-9) and m.start_speed == trace[1].speed, "the first record opens the window")
        -- 2 m/s^2 for the first second, then 0.5 m/s^2: the peak is the hard
        -- start, the mean is the whole window and the plateau the soft end.
        for i = 1, 300 do
            local t = i * H
            trace[i] = record(i, 0, t <= 1 and 2 * t or 2 + .5 * (t - 1))
        end
        m = Metrics.pedal(trace, 1, 300, { initial = initial })
        check(near(m.peak_acceleration, 2, 1e-6) and near(m.mean_acceleration, trace[300].speed / (300 * H), 1e-9)
            and near(m.mean_acceleration, .8, 1e-6), "the peak is the largest step, apart from the mean")
        check(near(m.plateau_acceleration, .5, 1e-9), "the plateau is the late slope")
    end)

    case("brake and coast on constructed decelerations", function()
        local trace, i = {}, 0
        repeat
            i += 1
            local t = i * H
            trace[i] = record(i, 6 * t - 1.5 * t * t, 6 - 3 * t)
        until trace[i].speed < .05
        local n = i
        local m = Metrics.slowdown(trace, 1, n, { initial = { time = 0, position = { 0, 1, 0 }, speed = 6 },
            bands = Metrics.brake_bands })
        check(near(m.mean_deceleration, 3, 1e-9) and near(m.ols_deceleration, 3, 1e-9) and near(m.peak_deceleration, 3, 1e-9),
            "constant 3 m/s^2")
        check(near(m.moving_brake_deceleration, 3, 1e-9) and near(m.later_brake_deceleration, 3, 1e-9), "band fits")
        local moving, later = 0, 0
        for k = 1, n do
            local v = trace[k].speed
            if v >= .08 and v <= 4.52 then moving += 1 end
            if v >= .08 and v <= 2.67 then later += 1 end
        end
        check(m.moving_brake_samples == moving and m.later_brake_samples == later and later < moving, "band samples")
        check(m.stopped and near(m.stopping_seconds, n * H, 1e-9) and near(m.stopping_distance, trace[n].position[3], 1e-9),
            "stopping time and distance")
        check(near(m.start_speed, 6) and m.end_speed == trace[n].speed and near(m.seconds, n * H, 1e-9), "window ends")
        local coast = {}
        for k = 1, 120 do coast[k] = record(k, 5 * k * H, 5) end
        m = Metrics.slowdown(coast, 2, 120)
        check(m.mean_deceleration == 0 and math.abs(m.ols_deceleration) <= 1e-12 and m.peak_deceleration == 0, "coast keeps speed")
        check(not m.stopped and m.stopping_seconds == nil and m.stopping_distance == nil and near(m.distance, 5 * 119 * H, 1e-9),
            "a coast does not stop")
        check(m.moving_brake_deceleration == nil, "no bands unless asked")
    end)

    case("turns on constructed circles", function()
        local function circle(radius, speed, sign, steps, release)
            local trace, rate = {}, sign * speed / radius
            for i = 1, steps + release do
                local held = math.min(i, steps)
                local theta = rate * held * H
                -- d(position)/dt = speed * (sin theta, cos theta) with theta = rate * t.
                local x = sign * radius * (1 - math.cos(theta))
                local z = sign * radius * math.sin(theta)
                local yaw = math.atan2(math.sin(theta), math.cos(theta))
                local r = record(i, z, speed, { yaw = yaw, lean = sign * .2 })
                r.position = { x, 1, z }
                if i > steps then
                    -- Straight on along the final heading.
                    local f = { math.sin(theta), 0, math.cos(theta) }
                    local d = (i - steps) * H * speed
                    local e = trace[steps].position
                    r.position = { e[1] + f[1] * d, 1, e[3] + f[3] * d }
                end
                trace[i] = r
            end
            return trace
        end
        local left = circle(5, 3, 1, 180, 60)
        local m = Metrics.turn(left, 1, 180, { release = { 181, 240 } })
        check(near(m.radius, 5, 1e-4) and near(m.yaw_rate, .6, 1e-9), "radius and yaw rate of a 5 m circle at 3 m/s")
        check(near(m.lateral_acceleration, 1.8, 1e-3) and near(m.mean_lean, .2, 1e-12) and near(m.steady_seconds, 1.5, 1e-6),
            "lateral acceleration, lean and the steady window")
        check(m.steering_limited_fraction == nil, "no steering field, no fraction")
        check(m.release_settled and near(m.release_settle_seconds, H, 1e-9) and math.abs(m.release_heading_change) <= 1e-12,
            "a released turn stops at once")
        local right = Metrics.turn(circle(5, 3, -1, 180, 60), 1, 180, { release = { 181, 240 } })
        check(near(right.yaw_rate, -.6, 1e-9) and near(right.radius, m.radius, 1e-9), "a right turn mirrors")
        -- More than pi in the steady window, which opens at 1.5 rad and ends
        -- past the wrap, so raw yaw differences would not add up.
        local fast = Metrics.turn(circle(1, 3, 1, 120, 0), 1, 120)
        check(near(fast.heading_change, 3 * 90 * H, 1e-9) and fast.heading_change > math.pi, "wrapped headings add up")
        -- Steps a hair over 1/60 s, as accumulated clock time can be: 90 of
        -- them pass 1.5 s by 9e-8 s, inside the slack, so the window keeps 90.
        local long, step = {}, 1 / 60 + 1e-9
        for i = 1, 180 do long[i] = record(i, 3 * i * step, 3, { time = i * step, yaw = .01 * i }) end
        local slack = Metrics.turn(long, 1, 180)
        check(90 * step > 1.5 and near(slack.steady_seconds, 90 * step, 1e-12) and near(slack.heading_change, .9, 1e-9),
            "whole steps land on the steady window within the slack")
        local summary = Metrics.turn_speed({ { speed = 3, radius = 5, yaw_rate = .6 }, { speed = 6, radius = 9, yaw_rate = -2 / 3 } },
            { { { radius = 5, yaw_rate = .6 }, { radius = 5.5, yaw_rate = -.6 } } })
        check(near(summary.radius_growth_per_speed, 4 / 3, 1e-12) and near(summary.yaw_rate_growth_per_speed, (2 / 3 - .6) / 3, 1e-12),
            "growth with speed")
        check(near(summary.mirror_radius_error, .5 / 5.25, 1e-12) and summary.mirror_yaw_rate_error == 0, "mirror errors")
    end)

    case("hop and landing on a constructed ballistic trace", function()
        local g, v0, k = 9.8, 4, 20
        local trace, i, y, phase = {}, 0, 1, "ride"
        local touch_index, low_index
        while i < 160 do
            i += 1
            local r
            if i < k then
                r = record(i, i * H * 4, 4)
            else
                local tau = (i - k + 1) * H
                local height = v0 * tau - g * tau * tau / 2
                if phase == "ride" and i > k and height <= .02 then phase = "land" end
                if phase == "land" then
                    -- Penetrate 10 mm, then 4 mm, then settle on the surface.
                    local after = i - (touch_index or i)
                    if not touch_index then touch_index = i end
                    height = after == 0 and -.01 or after == 1 and -.004 or 0
                    if after == 0 then low_index = i end
                end
                r = record(i, i * H * 4, 4)
                r.position = { 0, 1 + height, i * H * 4 }
                r.velocity = { 0, phase == "land" and 0 or v0 - g * tau, 4 }
                r.front, r.rear = wheel(height, 0), wheel(height, 0)
                r.hop_applied = i == k
                r.pitch = phase == "land" and 0 or .05
            end
            trace[i] = r
        end
        -- The record before impact is the last airborne one; impact puts a tyre in the gap.
        local impact = touch_index
        local m = Metrics.air(trace, {})
        local apex, apex_index = -math.huge, nil
        for j = k, impact - 1 do
            if trace[j].position[2] - 1 > apex then apex, apex_index = trace[j].position[2] - 1, j end
        end
        check(m.hop_applied and m.landed and m.left_contact_gap, "the hop lands")
        check(m.apex_rise == apex and near(m.apex_rise, v0 * v0 / (2 * g), 2e-3), "apex is the highest sampled rise")
        -- The apex sample is v0/g after the step before the hop, so (apex - k) steps after the hop step.
        check(apex_index - k + 1 == math.floor(v0 / g / H + .5) and near(m.apex_seconds, (apex_index - k) * H, 1e-9),
            "apex time counts from the hop step")
        check(m.takeoff_speed == 4, "takeoff speed is the hop step's horizontal speed")
        check(near(m.airtime, (impact - 1 - k) * H, 1e-9) and m.first_contact == "both", "airtime and first contact")
        check(m.landing_vertical_speed == trace[impact - 1].velocity[2] and m.landing_pitch == .05, "landing state")
        check(m.impact_to_support == 0, "the 10 mm penetration is inside the support window, so support is immediate")
        -- Clearance is the constructed height; the rise is (1 + height) - 1, so they agree to rounding.
        check(near(m.takeoff_vertical_speed, v0 - g * H, 1e-12) and near(m.apex_clearance, apex, 1e-12), "takeoff and clearance")
        local l = m.landing
        check(near(l.compression_depth, .01, 1e-12) and near(l.com_dip, .01, 1e-12), "compression of the constructed landing")
        check(near(l.compression_seconds, trace[low_index].time - trace[impact - 1].time, 1e-12) and l.rebounded
            and near(l.rebound_seconds, 2 * H, 1e-9), "compression and rebound timing")
        check(l.supported_at_end and near(l.speed_retained, 1, 1e-12) and near(l.window_seconds, .5, 1e-6), "landing flows on")
        check(Metrics.air({ record(1, 0, 4), record(2, .1, 4) }).hop_applied == false, "no hop, no air metrics")
    end)

    case("landing with a bounce, a pitch swing and no settle", function()
        -- Ten airborne steps at 5 m/s, then impact on record 11 at 4 m/s. The
        -- COM sinks to 0.975 on record 13 and then rises 2 mm a step to the
        -- end of the 0.5 s window (record 40), so it never holds within 1 mm.
        local trace, touch, impact, low = {}, 10, 11, 13
        for i = 1, 50 do
            local s = i - impact
            local r = record(i, i * H * 5, 5)
            if i <= touch then
                r.position[2], r.velocity[2] = 1.2 - .01 * i, -2
                r.front, r.rear = wheel(.2, 0, "clear"), wheel(.2, 0, "clear")
            else
                local speed = 4 - .5 * math.min(s, 29) / 29
                local y = s == 0 and .99 or s == 1 and .98 or .975 + .002 * (s - 2)
                r.position[2], r.speed, r.forward_speed = y, speed, speed
                r.velocity = { 0, s == 0 and -1.5 or s == 1 and -.6 or s == 2 and -.3 or .002 / H, speed }
                r.front, r.rear = wheel(s == 0 and -.006 or 0, 0), wheel(s == 0 and -.002 or s == 1 and -.012 or 0, 0)
                r.pitch = s == 0 and .15 or s == 5 and -.08 or .02
            end
            trace[i] = r
        end
        local l = Metrics.landing(trace, impact, {})
        local last = 40
        check(near(l.window_seconds, trace[last].time - trace[touch].time, 1e-12) and near(l.window_seconds, .5, 1e-6),
            "the window is 0.5 s from the last airborne record")
        check(near(l.compression_depth, .012, 1e-12) and near(l.com_dip, trace[last].position[2] - .975, 1e-12)
            and near(l.compression_seconds, 3 * H, 1e-9), "deepest tyre, COM dip and time to the low point")
        check(near(l.max_rebound_speed, .002 / H, 1e-9), "the bounce is the fastest upward speed, not the impact")
        check(near(l.pitch_excursion, .13, 1e-12), "the pitch swing from where it ends")
        check(l.rebounded == false and near(l.rebound_seconds, trace[last].time - trace[low].time, 1e-12),
            "a COM still rising at the window end has not rebounded")
        check(near(l.speed_retained, 3.5 / 5, 1e-12), "speed retained is over the last airborne speed, not the impact's")
        check(l.supported_at_end, "both tyres carry the bike at the end")
        -- Sinking to the window end: the lowest point is the last record.
        for i = impact, 50 do trace[i].position[2] = 1 - .003 * (i - impact) end
        l = Metrics.landing(trace, impact, {})
        check(l.rebounded == false and l.rebound_seconds == 0 and l.com_dip == 0
            and near(l.compression_seconds, .5, 1e-6), "a COM still sinking has not rebounded")
        -- Under 1 mm of movement is settled from the impact.
        for i = impact, 50 do trace[i].position[2] = 1 - .00001 * (i - impact) end
        l = Metrics.landing(trace, impact, {})
        check(l.rebounded and l.rebound_seconds == 0, "a sub-millimetre dip is settled at once")
    end)

    case("ledge drop on a constructed trace", function()
        -- Each hub is unsupported for the 12 steps after it passes the 1.5 m
        -- edge, and supported on the deck before it and the ground after.
        local trace, fall = {}, 12 * 2 * H
        local function row(hz)
            return { status = "hit", separation = 0, clearance = 0, hub = { 0, .3, hz }, supported = hz < 1.5 or hz - 1.5 >= fall }
        end
        for i = 1, 90 do
            local z = .5 + i * H * 2
            local r = record(i, z, 2)
            r.front, r.rear = row(z + .47), row(z - .47)
            local both = r.front.supported and r.rear.supported
            r.velocity = { 0, both and 0 or -1.5, 2 }
            r.pitch = both and 0 or -.2
            trace[i] = r
        end
        local land, both, neither = nil, nil, 0
        for i, r in ipairs(trace) do
            if not land and ((r.front.supported and r.front.hub[3] >= 1.5) or (r.rear.supported and r.rear.hub[3] >= 1.5)) then land = i end
            if land and not both and r.front.supported and r.front.hub[3] >= 1.5 and r.rear.supported and r.rear.hub[3] >= 1.5 then both = i end
            if not r.front.supported and not r.rear.supported then neither += 1 end
        end
        -- The front tyre sinks 8 mm on the step it lands, and the rear 3 mm.
        trace[land].front.separation, trace[both].rear.separation = -.008, -.003
        local m = Metrics.drop(trace, { edge_z = 1.5 })
        check(m.landed and m.first_landing == "front" and land ~= nil and both ~= nil, "the front lands first")
        check(near(m.front_to_rear_seconds, (both - land) * H, 1e-9) and near(m.airborne_seconds, neither * H, 1e-9),
            "front to rear and airborne time")
        check(m.max_drop_speed == 1.5 and m.min_pitch == -.2, "drop speed and pitch")
        local l = m.landing
        check(near(l.compression_depth, .008, 1e-12) and near(l.window_seconds, .5, 1e-6)
            and near(l.compression_seconds, H, 1e-9), "the landing window opens on the front landing")
        check(l.com_dip == 0 and l.rebounded and l.rebound_seconds == 0 and l.max_rebound_speed == 0
            and l.pitch_excursion == .2 and l.speed_retained == 1 and l.supported_at_end, "the rest of the landing")
    end)

    case("ramp on a constructed climb and roll-back", function()
        -- Entry at 4 m/s. The COM rises to 0.5 m on record 70. Pitch climbs
        -- 0.02 a step over records 11-40, snaps 0.1 on record 50, and eases
        -- off from record 81. Neither tyre is supported on records 60-74, and
        -- only the front on 75-79. The bike rolls back through its start at 3 m/s.
        local trace, pitch = {}, 0
        for i = 1, 120 do
            if i >= 11 and i <= 40 then pitch += .02 elseif i == 50 then pitch += .1 elseif i > 80 then pitch -= .01 end
            local r = record(i, .02 * i * (110 - i) / 110, 4)
            r.position[2], r.pitch = 1 + .5 * math.sin(math.pi * i / 140), pitch
            r.front.supported = not (i >= 60 and i <= 79)
            r.rear.supported = not (i >= 60 and i <= 74)
            trace[i] = r
        end
        trace[120].forward_speed = -3
        local initial = { time = 0, position = { 0, 1, 0 }, speed = 4 }
        local m = Metrics.ramp(trace, { initial = initial })
        check(near(m.peak_rise, .5, 1e-12) and near(m.peak_seconds, 70 * H, 1e-9) and m.entry_speed == 4, "rise and its time")
        check(near(m.max_pitch, .7, 1e-9) and near(m.max_pitch_rate, .1 / H, 1e-6), "the steepest pitch and the snap")
        check(near(m.unsupported_seconds, 15 * H, 1e-9), "only steps with neither tyre supported count")
        check(trace[120].position[3] < 0 and m.rolled_back and m.return_speed == 3 and m.momentum_retained == .75,
            "rolled back with three quarters of the entry speed")
        check(near(m.seconds, 120 * H, 1e-9), "the window")
        trace[120].forward_speed = 1
        m = Metrics.ramp(trace, { initial = initial })
        check(not m.rolled_back and m.return_speed == nil and m.momentum_retained == nil, "still climbing, nothing returned")
    end)

    case("manual on a constructed hold", function()
        local trace = {}
        local pitches = {}
        for i = 1, 140 do
            local r = record(i, i * H * 4, 4 - i * .001)
            local up = (i >= 11 and i <= 60) or (i >= 63 and i <= 125)
            local p = 0
            if i >= 11 and i <= 60 then p = .2 + .01 * math.sin(i) elseif i >= 63 and i <= 125 then p = .25 end
            r.pitch = p
            r.front = up and { status = "clear", clearance = .1, hub = { 0, .3, 0 }, supported = false }
                or { status = "hit", separation = 0, clearance = 0, hub = { 0, .3, 0 }, supported = true }
            r.rear.supported = true
            trace[i] = r
            if up then table.insert(pitches, p) end
        end
        local m = Metrics.manual(trace, 1, 120, { lift = "front", release = { 121, 140 } })
        check(m.lifted and near(m.time_to_lift, 11 * H, 1e-9), "lifts on step 11")
        check(near(m.longest_hold_seconds, 58 * H, 1e-9) and m.touchdowns == 1, "longest hold and one touchdown")
        check(near(m.lifted_fraction, 108 / 120, 1e-12) and m.base_supported_fraction == 1 and m.lifted_at_end, "fractions")
        local sum, n, low, high = 0, 0, math.huge, -math.huge
        for j = 1, 108 do sum += pitches[j] n += 1 low = math.min(low, pitches[j]) high = math.max(high, pitches[j]) end
        local mean, var = sum / n, 0
        for j = 1, 108 do var += (pitches[j] - mean) ^ 2 end
        check(near(m.lift_pitch_mean, mean, 1e-12) and near(m.lift_pitch_std, math.sqrt(var / n), 1e-9), "pitch mean and spread")
        check(near(m.lift_pitch_range, high - low, 1e-12) and near(m.peak_lift_pitch, .25, 1e-12) and near(m.hold_lift_pitch, .25, 1e-12),
            "pitch range, peak and hold")
        local rate = 0
        for i = 12, 60 do rate = math.max(rate, math.abs(trace[i].pitch - trace[i - 1].pitch) / H) end
        check(near(m.max_lift_pitch_rate, rate, 1e-6), "the fastest pitch change while up")
        check(m.release_dropped and near(m.release_drop_seconds, 6 * H, 1e-9), "drops six steps into the release")
        check(near(m.max_lift_clearance, .1) and near(m.speed_change, trace[120].speed - trace[1].speed, 1e-12),
            "clearance, and the speed change from the first record without an initial state")
        -- The nose manual lifts the rear and reads pitch with the opposite sign.
        for _, r in ipairs(trace) do
            r.pitch, r.front, r.rear = -r.pitch, r.rear, r.front
        end
        local nose = Metrics.manual(trace, 1, 120, { lift = "rear", release = { 121, 140 } })
        check(near(nose.lift_pitch_mean, mean, 1e-12) and nose.touchdowns == 1 and near(nose.release_drop_seconds, 6 * H, 1e-9),
            "nose manual mirrors")
        -- Never lifted: no hold statistics and no release time.
        for _, r in ipairs(trace) do r.rear = { status = "hit", separation = 0, clearance = 0, hub = { 0, .3, 0 }, supported = true } end
        local flat = Metrics.manual(trace, 1, 120, { lift = "rear", release = { 121, 140 } })
        check(not flat.lifted and flat.time_to_lift == nil and flat.lift_pitch_std == nil and flat.release_drop_seconds == 0,
            "a manual that never lifts")
    end)

    case("segments and a grind driven through grind_policy", function()
        local modes = { "a", "a", "b", false, "b", "b" }
        local trace = {}
        for i, mode in ipairs(modes) do trace[i] = { time = i * H, speed = i, mode = mode or nil } end
        local s = Metrics.segments(trace, function(r) return r.mode end)
        check(#s == 3 and s[1].first == 1 and s[1].last == 2 and s[2].first == 3 and s[2].last == 3
            and s[3].first == 5 and s[3].last == 6, "three segments")
        check(s[1].entry_speed == 1 and s[1].exit_speed == 2 and near(s[1].seconds, 2 * H, 1e-12)
            and s[2].deceleration == nil and near(s[3].deceleration, -1 / H, 1e-6), "segment speeds and fits")
        -- A constructed double-peg approach through the actual grind policy:
        -- one airborne step, lock-on at 4 m/s, an authored 1.2 m/s^2 decay,
        -- then a hop-out.
        local c, decay, records = Grind.new(), 1.2, {}
        local function push(out, speed, body, i)
            table.insert(records, { time = i * H, speed = speed, rail_speed = out.rail and out.rail.speed or nil,
                state = out.state, grind = out.grind, exit_reason = out.exit_reason,
                position = body.center_of_mass, velocity = body.linear_velocity })
        end
        local body = grind_body(4, 1)
        push(c:step(grind_observe(body, {})), 4, body, 1)
        local lock = c:step(grind_observe(body, { "rear_left", "front_left" }))
        check(lock.state == "locked" and lock.grind == "double_peg", "the policy locks a double peg")
        push(lock, 4, body, 2)
        for i = 3, 61 do
            local v = 4 - decay * (i - 2) * H
            body = grind_body(v, 0)
            local out = c:step(grind_observe(body, { "rear_left", "front_left" }))
            check(out.state == "locked", "the grind holds")
            push(out, v, body, i)
        end
        body = grind_body(4 - decay * 60 * H, 0)
        local out = c:step(grind_observe(body, { "rear_left", "front_left" }, true))
        check(out.state == "ended" and out.exit_reason == "hop_out", "the hop exits")
        push(out, 4 - decay * 60 * H, body, 62)
        for i = 63, 66 do
            body = grind_body(3, 0)
            push(c:step(grind_observe(body, {})), 3, body, i)
        end
        local m = Metrics.grind(records)
        check(m.count == 1 and m.grind == "double_peg" and m.exit_reason == "hop_out", "one double peg with a hop-out")
        check(near(m.entry_speed, 4, 1e-9) and near(m.exit_speed, 4 - decay * 59 * H, 1e-9) and near(m.seconds, 60 * H, 1e-9),
            "entry and exit speed along the rail")
        check(near(m.deceleration, decay, 1e-6) and near(m.speed_retained, m.exit_speed / 4, 1e-12), "the authored decay")
        check(Metrics.grind({ { time = H, speed = 1, state = "idle" } }).count == 0, "no grind, no metrics")
        -- A slow double peg through the same policy: lock-on at 1 m/s and an
        -- authored 1.3 m/s^2 decay to rest. Under grind_policy's 0.6 m/s it
        -- stalls on record 21, holds the stall 0.75 s (45 steps) and ends.
        c, records = Grind.new(), {}
        body = grind_body(1, 1)
        push(c:step(grind_observe(body, {})), 1, body, 1)
        push(c:step(grind_observe(body, { "rear_left", "front_left" })), 1, body, 2)
        local step, stalled_at, ended_at = 2, nil, nil
        repeat
            step += 1
            local v = math.max(0, 1 - 1.3 * (step - 2) * H)
            body = grind_body(v, 0)
            out = c:step(grind_observe(body, { "rear_left", "front_left" }))
            push(out, v, body, step)
            if out.state == "stalled" and not stalled_at then stalled_at = step end
            if out.state == "ended" then ended_at = step end
        until ended_at or step > 200
        check(records[2].state == "locked" and stalled_at == 21 and ended_at == stalled_at + 45
            and records[ended_at].exit_reason == "stall_end" and records[ended_at - 1].grind == "peg_stall",
            "the policy stalls under 0.6 m/s and ends the stall after 0.75 s")
        m = Metrics.grind(records)
        local total = 0
        for j = 2, ended_at - 1 do total += math.abs(records[j].rail_speed) end
        check(m.count == 1 and m.grind == "double_peg" and m.exit_reason == "stall_end", "one grind that stalls out")
        check(near(m.seconds, (ended_at - 2) * H, 1e-9) and near(m.entry_speed, 1, 1e-9) and m.exit_speed == 0
            and m.speed_retained == 0, "the stalled records are part of the grind")
        check(near(m.mean_speed, total / (ended_at - 2), 1e-12), "the mean runs over the stall too")
    end)

    case("continuity flags constructed jumps", function()
        local trace = {}
        for i = 1, 60 do trace[i] = record(i, i * H * 3, 3) end
        local m = Metrics.continuity(trace)
        check(m.max_position_residual <= 1e-12 and m.teleports == 0 and m.max_speed_step == 0 and m.max_pitch_step == 0,
            "a consistent straight line")
        trace[30].position = { 1, 1, trace[30].position[3] }
        for i = 31, 60 do trace[i].position = { 1, 1, trace[i].position[3] } end
        trace[40].pitch = .3
        trace[20].lean = -.15
        -- Heading near pi throughout, crossing the wrap once between 45 and 46.
        for i = 1, 60 do trace[i].yaw = i <= 45 and 3.1 or -3.1 end
        trace[50] = { time = 50 * H, position = { 99, 99, 99 }, velocity = { 0, 0, 0 }, speed = 0, valid = false }
        m = Metrics.continuity(trace)
        check(m.teleports == 1 and m.first_teleport == 30 and near(m.max_position_residual, 1, 1e-9), "one 1 m teleport")
        check(near(m.max_pitch_step, .3, 1e-12) and near(m.max_yaw_step, 2 * math.pi - 6.2, 1e-9), "pitch snap and wrapped yaw")
        check(near(m.max_lean_step, .15, 1e-12), "a lean snap reads in its own step")
        check(m.max_speed_step == 0, "an invalid record is skipped")
    end)

    case("camera on constructed views", function()
        local views, subjects, floats = {}, {}, {}
        for i = 1, 120 do
            local t = i * H
            local eye = { 0, 2, -3 + t * t }
            views[i] = { eye = eye, target = { x = 0, y = 2, z = eye[3] + 3 }, fov = 70, reset = i == 1 }
            floats[i] = { eye = vector.create(eye[1], eye[2], eye[3]), target = vector.create(0, 2, eye[3] + 3), fov = 70 }
            subjects[i] = { 0, 1.5, eye[3] + 3 }
        end
        local m = Metrics.camera(views, subjects, { seconds = H })
        local angle = math.atan(.5 / 3)
        check(near(m.max_eye_acceleration, 2, 1e-6) and near(m.max_eye_speed, (240 - 1) * H, 1e-9), "eye motion")
        -- camera_policy returns Luau vectors, which are single precision: a
        -- second difference then carries rounding over h^2 (here about 2e-3).
        local f = Metrics.camera(floats, subjects, { seconds = H })
        check(near(f.max_eye_acceleration, 2, 1e-2) and f.max_eye_acceleration ~= m.max_eye_acceleration and f.resets == 0,
            "vector input reads as single precision")
        check(m.max_aim_rate <= 1e-9 and near(m.max_subject_angle, angle, 1e-9), "aim and subject angle")
        check(near(m.min_frame_margin, math.rad(35) - angle, 1e-9) and m.out_of_frame_steps == 0, "in frame")
        check(m.resets == 1 and m.min_fov == 70 and m.max_fov == 70 and m.steps == 120, "resets and fov")
        check(near(m.min_distance, math.sqrt(9.25), 1e-12) and near(m.max_distance, math.sqrt(9.25), 1e-12), "distance")
        check(m.own_view_steps == 0, "every view carries its field of view")
        subjects[60] = { 0, 2 + 3 * math.tan(math.rad(60)), views[60].target.z }
        m = Metrics.camera(views, subjects, { seconds = H })
        check(m.out_of_frame_steps == 1 and near(m.min_frame_margin, math.rad(35 - 60), 1e-9), "a subject above the frame")
        -- An aim turning at 0.8 rad/s about a fixed eye; the subject sits 45
        -- degrees right of it, inside a 16:9 frame 70 degrees tall but
        -- outside a square one, and 40 degrees up is outside both.
        local turning, beside = {}, {}
        for i = 1, 60 do
            local a = .8 * i * H
            local eye = { 0, 2, 0 }
            turning[i] = { eye = eye, target = { 3 * math.sin(a), 2, 3 * math.cos(a) }, fov = 70 }
            beside[i] = { 3 * math.sin(a - math.rad(45)), 2, 3 * math.cos(a - math.rad(45)) }
        end
        m = Metrics.camera(turning, beside, { seconds = H })
        local wide = math.atan(16 / 9 * math.tan(math.rad(35)))
        check(near(m.max_aim_rate, .8, 1e-9) and m.max_eye_speed == 0 and m.max_eye_acceleration == 0, "the aim turns at 0.8 rad/s")
        check(m.out_of_frame_steps == 0 and near(m.min_frame_margin, wide - math.rad(45), 1e-9)
            and near(m.max_subject_angle, math.rad(45), 1e-9), "45 degrees right is inside a 16:9 frame")
        m = Metrics.camera(turning, beside, { seconds = H, aspect = 1 })
        check(m.out_of_frame_steps == 60 and near(m.min_frame_margin, math.rad(35 - 45), 1e-9), "and outside a square one")
        local above = {}
        for i = 1, 60 do
            local a = .8 * i * H
            above[i] = { 3 * math.sin(a), 2 + 3 * math.tan(math.rad(40)), 3 * math.cos(a) }
        end
        m = Metrics.camera(turning, above, { seconds = H })
        check(m.out_of_frame_steps == 60 and near(m.min_frame_margin, math.rad(35 - 40), 1e-9), "40 degrees up is outside")
        -- A field of view of 0 is the camera's own, which the view does not say.
        local own = { { eye = { 0, 2, 0 }, target = { 0, 2, 3 }, fov = 0 }, { eye = { 0, 2, 0 }, target = { 0, 2, 3 }, fov = 70 } }
        m = Metrics.camera(own, { { 0, 9, 3 }, { 0, 2, 3 } }, { seconds = H })
        check(m.own_view_steps == 1 and m.out_of_frame_steps == 0 and m.min_fov == 70 and near(m.min_frame_margin, math.rad(35), 1e-9),
            "the camera's own field of view is left out of the frame test")
        m = Metrics.camera({ own[1] }, { { 0, 2, 3 } }, { seconds = H })
        check(m.own_view_steps == 1 and m.min_frame_margin == nil and m.min_fov == nil, "no frame without a field of view")
    end)

    -- Every scenario once; the driven cases below share these runs.
    local reference, runners = Scenarios.run()
    local collected = Metrics.collect(runners)
    local metrics = Metrics.extract(collected)

    case("sim scenarios: extraction agrees with sim_scenarios", function()
        check(frozen_deep(metrics) and metrics.version == Metrics.version, "metrics are frozen")
        for id, value in pairs(Metrics.flatten(metrics)) do
            check(type(value) ~= "number" or M.finite(value), "finite " .. id)
        end
        local function same(a, b, why) check(close(a, b), why .. ": " .. tostring(a) .. " vs " .. tostring(b)) end
        local f, r = metrics.S01.flat, reference.S01.flat
        for _, key in ipairs({ "time_to_3", "time_to_6", "time_to_7_5", "distance", "seconds" }) do same(f.accel[key], r.accel[key], "S01 accel " .. key) end
        same(f.accel.end_speed, r.accel.top_speed, "S01 top speed")
        for _, key in ipairs({ "distance", "seconds", "speed_change" }) do same(f.coast[key], r.coast[key], "S01 coast " .. key) end
        same(f.coast.start_speed, r.coast.speed_start, "S01 coast start")
        for _, key in ipairs({ "seconds", "distance", "mean_deceleration", "peak_deceleration" }) do
            same(f.brake[key], r.brake[key], "S01 brake " .. key)
        end
        check(f.brake.stopped == r.brake.stopped and f.brake.stopped, "S01 brake stops")
        same(f.brake.start_speed, r.brake.speed_start, "S01 brake start")
        same(f.rest.creep_distance, r.rest.creep_distance, "S01 creep")
        same(f.restart.end_speed, r.restart.speed_end, "S01 restart speed")
        same(f.restart.distance, r.restart.distance, "S01 restart distance")
        check(f.brake.moving_brake_samples >= 3 and f.brake.later_brake_samples >= 3, "S01 brake band fits ran")
        for name, run in pairs(reference.S02) do
            local m = metrics.S02[name]
            for _, key in ipairs({ "radius", "yaw_rate", "mean_speed", "mean_lean", "steering_limited_fraction",
                "release_heading_change", "release_settle_seconds", "release_lean" }) do
                same(m[key], run[key], "S02 " .. name .. " " .. key)
            end
            check(m.release_settled == run.release_settled, "S02 settled " .. name)
        end
        check(close(metrics.S02.summary.mirror_radius_error, 0, 1e-12) and metrics.S02.summary.radius_growth_per_speed > 0,
            "S02 turns mirror and widen with speed")
        for name, run in pairs(reference.S04) do
            local m = metrics.S04[name]
            same(m.peak_rise, run.peak_rise, "S04 rise " .. name)
            same(m.peak_seconds, run.peak_seconds, "S04 peak time " .. name)
            same(m.max_pitch, run.max_pitch, "S04 pitch " .. name)
            same(m.momentum_retained, run.return_ratio, "S04 return " .. name)
            check(m.rolled_back == run.rolled_back, "S04 rolled back " .. name)
        end
        for name, run in pairs(reference.S05) do
            local m = metrics.S05[name]
            check(m.hop_applied == run.hop_applied, "S05 hop " .. name)
            if run.hop_applied then
                for _, key in ipairs({ "apex_rise", "apex_clearance", "takeoff_vertical_speed" }) do same(m[key], run[key], "S05 " .. name .. " " .. key) end
                check(m.landed == run.landed and m.landed, "S05 lands " .. name)
                for _, key in ipairs({ "airtime", "air_distance", "landing_pitch", "landing_vertical_speed", "impact_to_support" }) do
                    same(m[key], run[key], "S05 " .. name .. " " .. key)
                end
                check(m.first_contact == run.first_contact, "S05 first contact " .. name)
                check(m.landing.compression_depth >= 0 and m.landing.window_seconds > 0, "S05 landing window " .. name)
            end
        end
        for name, run in pairs(reference.S06) do
            local m = metrics.S06[name]
            same(m.airborne_seconds, run.airborne_seconds, "S06 airborne " .. name)
            same(m.front_to_rear_seconds, run.front_to_rear_landing, "S06 front to rear " .. name)
            same(m.min_pitch, run.min_pitch, "S06 pitch " .. name)
            same(m.max_drop_speed, run.max_drop_speed, "S06 drop speed " .. name)
            check(m.first_landing == run.first_landing, "S06 first landing " .. name)
            -- The landing window is part of the run, so it is no deeper than the run's deepest row.
            check(m.landing ~= nil and m.landing.compression_depth <= math.max(0, -run.min_separation) + 1e-12,
                "S06 landing compression within the run's deepest separation " .. name)
        end
        for name, run in pairs(reference.S07) do
            local m = metrics.S07[name]
            check(m.lifted == run.lifted and m.lifted_at_end == run.lifted_at_release and m.release_dropped == run.release_dropped,
                "S07 lift flags " .. name)
            for _, key in ipairs({ "hold_lift_pitch", "lifted_fraction", "base_supported_fraction", "release_drop_seconds" }) do
                same(m[key], run[key], "S07 " .. name .. " " .. key)
            end
            same(math.max(0, m.peak_lift_pitch), run.peak_lift_pitch, "S07 peak " .. name)
            same(math.max(0, m.max_lift_clearance), run.max_lift_clearance, "S07 clearance " .. name)
            same(m.speed_change, run.hold_speed_change, "S07 speed change " .. name)
            if run.lifted then same(m.time_to_lift, run.time_to_lift, "S07 lift time " .. name) end
            check(m.lift == (string.sub(name, 1, 4) == "nose" and "rear" or "front"), "S07 lifted wheel " .. name)
        end
        -- The simulator moves the body by its own new velocity, so no valid
        -- step of any run is a teleport.
        for _, id in ipairs(Metrics.extracted) do
            for name, m in pairs(metrics[id]) do
                if m.continuity then
                    check(m.continuity.teleports == 0 and m.continuity.max_position_residual <= 1e-9, "continuous " .. id .. " " .. name)
                    check(m.valid == (name ~= "gap_no_hop"), "only the gap wall strike stops " .. id .. " " .. name)
                end
            end
        end
        check(equal(Metrics.extract(collected), metrics), "a second extraction is identical")
    end)

    case("sim scenarios: offline report", function()
        local values = Metrics.flatten(metrics)
        local report = Metrics.report(values)
        check(frozen_deep(report) and report.summary.kind == "offline_model_closeness"
            and report.summary.disclaimer == Metrics.disclaimer, "the report says what it is")
        local targets, scored, lowest, previous = 0, 0, math.huge, ""
        for _ in pairs(Metrics.targets) do targets += 1 end
        for _, row in ipairs(report.rows) do
            check(row.id > previous, "rows sorted by id")
            previous = row.id
            check(row.likeness == nil and row.likeness_score == nil, "no row claims a likeness score")
            check(row.value == values[row.id], "the row reports the extracted value " .. row.id)
            check(row.category == Metrics.category(row.id), "row category " .. row.id)
            if type(row.value) == "number" then check(row.unit ~= "", "numeric metric has a unit " .. row.id) end
            if row.scored then
                scored += 1
                check(Metrics.targets[row.id] ~= nil and row.score >= 0 and row.score <= 1 and #row.sources >= 1
                    and #row.caveats >= 1, "scored row " .. row.id)
                check(row.within == (row.score == 1), "inside the band exactly when the score is 1 " .. row.id)
                lowest = math.min(lowest, row.score)
            else
                check(Metrics.targets[row.id] == nil and row.reason == "no_recorded_target" and row.score == nil,
                    "unscored row " .. row.id)
            end
        end
        check(scored == targets and report.summary.scored == targets and report.summary.missing == 0, "every target scored")
        check(report.summary.unscored == #report.rows - targets and report.summary.unscored > 100, "the rest reported unscored")
        check(report.summary.lowest_score == lowest, "the summary keeps the lowest score")
        local missing = Metrics.report({ ["S05.r3_quick_hop.airtime"] = 1.4 })
        check(missing.summary.missing == #missing.rows - 1 and missing.summary.scored == 1, "targets without a metric are listed")
        local found = false
        for _, row in ipairs(missing.rows) do
            if row.id == "S05.r3_quick_hop.apex_rise" then found = row.reason == "metric_missing" and not row.scored end
        end
        check(found, "a missing metric is named")
        local evaluated = Metrics.evaluate(runners)
        check(equal(evaluated, report), "evaluate is collect, extract, flatten and report")
        -- An owner-supplied target table replaces the recorded one.
        local own = Metrics.report(values, { ["S02.left_3.radius"] = { observed = { values["S02.left_3.radius"] }, margin = 0, falloff = 1,
            sources = { "owner" }, caveats = { "constructed" } } })
        check(own.summary.scored == 1 and own.rows[1] ~= nil, "a caller target table is used")
        for _, row in ipairs(own.rows) do
            if row.id == "S02.left_3.radius" then check(row.scored and row.score == 1, "an exact owner target scores 1") end
            if row.id == "S05.r3_quick_hop.airtime" then check(not row.scored, "recorded targets are not mixed in") end
        end
    end)

    case("camera driven by the simulator", function()
        local sim = World.new({ speed = 4 })
        local rig = Camera.new()
        local views, subjects, trace = {}, {}, {}
        for step = 1, 120 do
            local r = sim:step(step == 16 and { quick_hop = true } or {})
            table.insert(trace, r)
            local body = sim.body
            local plan = rig:step({ position = body.center_of_mass, velocity = body.linear_velocity,
                rotation = body.orientation, grounded = r.grounded }, H)
            check(plan ~= nil, "the rig accepts the simulator's body")
            local view = rig:resolve(nil)
            check(view ~= nil, "the rig resolves a clear view")
            table.insert(views, view)
            table.insert(subjects, M.copy(body.center_of_mass))
        end
        local m = Metrics.camera(views, subjects, { seconds = H })
        for key, value in pairs(m) do check(M.finite(value), "finite camera metric " .. key) end
        check(m.steps == 120 and m.resets == 1 and views[1].reset and not views[2].reset, "one placement, then follow")
        check(m.min_distance > 0 and m.max_distance >= m.min_distance and m.min_fov >= 10 and m.max_fov <= 150,
            "distances and field of view")
        local air = Metrics.air(trace, {})
        check(air.hop_applied and air.landed, "the camera trace has a hop and landing")
        check(Metrics.continuity(trace).teleports == 0, "the driven body never teleports")
    end)

    return { cases = cases, assertions = assertions, native_actions = 0 }
end

return Tests

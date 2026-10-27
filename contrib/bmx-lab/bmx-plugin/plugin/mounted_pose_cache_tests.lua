-- Pure source regressions for the Poser's local-pose memo. No game or native API is used.
-- The existing test runner must stage mounted_pose_qualified_fixture.lua from mounted_pose.lua,
-- changing ONLY its qualification constant for tests, as for mounted_pose_tests.lua. This file
-- does not register itself in a runner or qualify the production module. Timing remains unmeasured.
local MP = require("./mounted_pose")
local Q = require("./mounted_pose_qualified_fixture")
local G = require("./bike_geometry")
local Bones = require("./bones")

local cases, assertions = 0, 0
local function check(ok, message)
    assertions += 1
    if not ok then error(message or "check failed", 2) end
end
local function test(name, fn)
    cases += 1
    local ok, why = pcall(fn)
    if not ok then error(name .. ": " .. tostring(why), 0) end
end
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in v do out[k] = copy(x) end
    return out
end
local function add(a, b) return {a[1] + b[1], a[2] + b[2], a[3] + b[3]} end
local function sub(a, b) return {a[1] - b[1], a[2] - b[2], a[3] - b[3]} end
local function mul(a, k) return {a[1] * k, a[2] * k, a[3] * k} end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function cross(a, b) return {a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1]} end
local function unit(a) return mul(a, 1 / math.sqrt(dot(a, a))) end
local function quaternion(v)
    return type(v) == "table" and #v == 4 and type(v[1]) == "number" and type(v[4]) == "number" and
        math.abs(v[1]^2 + v[2]^2 + v[3]^2 + v[4]^2 - 1) < 1e-6
end
-- Full shape/value comparison with the uncached compose oracle. Quaternion signs are immaterial;
-- Luau position vectors are float32, while array positions/diagnostics keep double precision.
local function same(a, b, path)
    path = path or "plan"
    check(type(a) == type(b), path .. " type")
    if type(a) == "table" then
        if quaternion(a) and quaternion(b) then
            local sign = a[1]*b[1] + a[2]*b[2] + a[3]*b[3] + a[4]*b[4] < 0 and -1 or 1
            for i = 1, 4 do check(math.abs(a[i] - sign*b[i]) < 1e-7, path .. " quaternion") end
        else
            for k, value in a do same(value, b[k], path .. "." .. tostring(k)) end
            for k in b do check(a[k] ~= nil, path .. " missing " .. tostring(k)) end
        end
    elseif type(a) == "vector" then
        check(vector.magnitude(a - b) < 2e-4, path .. " vector")
    elseif type(a) == "number" then
        check(a == a and b == b and math.abs(a - b) < 1e-7, path .. " number")
    else
        check(a == b, path .. " value")
    end
end
local function fake()
    local f = {sends = 0, ends = 0}
    f.api = {skater = {pose = function(pose, weight)
        if pose == nil then f.ends += 1 return true end
        if weight == 2 then error("place has a position, a rotation or both", 0) end
        local valid, why = Q.validate_pose(pose)
        check(valid, why)
        f.sends += 1
        return true
    end}}
    return f
end
local function input()
    return {bike = {root = {0, 0, 0}, rotation = {0, 0, 0, 1}}, articulation = {steer = .123456, crank_phase = .654321}}
end
local function mounted(options)
    local f = fake()
    local p = Q.new(f.api, options)
    check(p:mount(0).ok, "mount fake")
    return p, f
end
local function tick(p, now, i)
    local r = p:tick(now, i)
    check(r.ok and r.sent and r.plan ~= nil, r.reason)
    return r.plan
end
local function compare(p, now, i)
    local plan = tick(p, now, i)
    local direct, why = Q.compose(i, p.options)
    check(direct ~= nil, why)
    same(plan, direct)
    return plan
end
local function warm(options)
    local p, f = mounted(options)
    local i = input()
    compare(p, 0, i)
    compare(p, .02, i)
    check(p.memo_misses == 1 and p.memo_hits == 1, "one full local solve, then a hit")
    return p, f, i
end
local function disjoint(a, b)
    local seen = {}
    local function record(v)
        if type(v) ~= "table" or seen[v] then return end
        seen[v] = true
        for _, child in v do record(child) end
    end
    local function visit(v)
        if type(v) ~= "table" then return end
        check(not seen[v], "two results share a mutable table")
        for _, child in v do visit(child) end
    end
    record(a)
    visit(b)
end
local function refused(p, f, now, i, fragment)
    local sends, ends = f.sends, f.ends
    local r = p:tick(now, i)
    check(not r.ok and not r.sent and r.ended == true and r.state == "refused", tostring(r.reason))
    check(string.find(r.reason, fragment, 1, true) ~= nil, tostring(r.reason))
    check(f.sends == sends and f.ends == ends + 1, "one end, no bad send")
    p:stop()
    p:stop()
    check(f.ends == ends + 1, "cleanup does not end twice")
end

local function run()
    cases, assertions = 0, 0
    test("cache preserves exact non-quantized angles and every output field", function()
        local p, _, i = warm({head = {rotation = {.5, .5, .5, .5}, follow = .3}})
        local frames = {
            {root = {12, 3, -8}, rotation = Q.math.axis_angle(unit({1, 2, 3}), .8)},
            {center_of_mass = {-4, 9, 20}, rotation = Q.math.axis_angle(unit({-2, 1, 1}), -1.1)},
            {root = {0, 0, 0}, rotation = {0, 0, 0, -1}},
        }
        for n, frame in frames do
            i.bike = frame
            local plan = compare(p, .02 + n*.02, i)
            check(plan.planned.head ~= nil and plan.targets.free_feet ~= nil and plan.targets.spindles ~= nil,
                "memo returns the entire original contract")
        end
        check(p.memo_misses == 1 and p.memo_hits == 4, "world transform changes reuse only the local solve")
    end)
    test("in-place scalar changes invalidate even below the former rounding steps", function()
        local p, _, i = warm()
        i.articulation.steer += .00001
        compare(p, .04, i)
        i.articulation.crank_phase += .00001
        compare(p, .06, i)
        check(p.memo_misses == 3 and p.memo_hits == 1, "exact scalar keys")
        compare(p, .08, i)
        check(p.memo_hits == 2, "new exact tuple can hit")
    end)
    test("options, rig lengths, bone roots, head and geometry replacements invalidate", function()
        local p, _, i = warm()
        local g = copy(G)
        g.left_grip[1] += .002
        local changes = {
            {lean = .4}, {rig = {lengths = {left_arm = .31}}},
            {rig = {roots = {left_arm = {.50, .02, .17}}}}, {rig = {foot_slope = .4}},
            {head = {rotation = {0, 0, 0, 1}}}, {geometry = g}, {pin_shoulders = false}, {shown = "me"},
        }
        for n, options in changes do
            p.options = options
            local before = p.memo_misses
            compare(p, .02 + n*.02, i)
            check(p.memo_misses == before + 1, "changed options require a new local solve")
            check(table.isfrozen(p.options) and table.isfrozen(p.options.rig.lengths), "validated config is frozen")
        end
    end)
    test("caller configuration and bone maps cannot mutate a validated cache key", function()
        local options = {rig = {lengths = {left_arm = .31}}}
        local p, _, i = warm(options)
        options.rig.lengths.left_arm = 0/0
        compare(p, .04, i)
        check(p.options.rig.lengths.left_arm == .31 and p.memo_misses == 1, "options are copied before caching")
        check(not pcall(function() p.options.rig.roots.left_arm[1] = 1 end), "bone root snapshot is immutable")
        check(table.isfrozen(Bones), "bone map is immutable")
        for _, row in Bones do check(table.isfrozen(row), "bone row is immutable") end
        check(not pcall(function() Bones[1].id = 2 end), "bone IDs cannot change under cached joints")
    end)
    test("API, skater table and pose binding changes do not retain the old cache", function()
        local p, _, i = warm()
        local next_api = fake()
        p.api = next_api.api
        compare(p, .04, i)
        p.api.skater = fake().api.skater
        compare(p, .06, i)
        p.api.skater.pose = fake().api.skater.pose
        compare(p, .08, i)
        check(p.memo_misses == 4 and p.memo_hits == 1, "each binding replacement invalidates")
    end)
    test("rider and skater-root changes take the full validated path", function()
        local p, f, i = warm()
        i.rider = {crouch = .1, lean = .4}
        compare(p, .04, i)
        i.rider.crouch = .2
        compare(p, .06, i)
        i.rider = nil
        i.skater_root = {.2, 1, -.3}
        compare(p, .08, i)
        check(p.memo_misses == 1 and p.memo_hits == 1, "actor-relative inputs are not memoized")
        i.skater_root = {100, 100, 100}
        refused(p, f, .1, i, "skater's placement")
    end)
    test("every trick or release scalar bypasses the neutral cache", function()
        for _, key in {"barspin", "tailwhip", "movement_bike_pitch", "movement_bike_roll", "barspin_release",
            "tailwhip_release", "release_left_hand", "release_right_hand", "release_left_foot", "release_right_foot"} do
            local p, _, i = warm()
            i.articulation[key] = .1
            compare(p, .04, i)
            check(p.memo_misses == 1 and p.memo_hits == 1, key .. " must use full composition")
            i.articulation[key] = 0
            compare(p, .06, i)
            check(p.memo_misses == 2, "return from fallback discards old entry")
        end
    end)
    test("no returned mutable plan table aliases cache, inputs, options or another result", function()
        local p, _, i = warm()
        local first = compare(p, .04, i)
        local second = compare(p, .06, i)
        disjoint(first, second)
        disjoint(second, i)
        disjoint(second, p.options)
        second.pose[Q.JOINTS.hips].place.rotation[1] = 99
        second.pose[Q.JOINTS.left_arm].place = {}
        second.planned.hips.position[1] = 99
        second.planned.left_arm.lower_local[1] = 99
        second.targets.held_feet[1][1] = 99
        second.targets.free_palms[1][1] = 99
        second.targets.bike_root[1] = 99
        second.diagnostics.limbs.left_arm.requested = 99
        second.diagnostics.hip_local[1] = 99
        compare(p, .08, i)
        check(p.memo_misses == 1, "mutating a result cannot reach the private cache")
    end)
    test("cached refresh still validates mutated joint IDs and transforms", function()
        for _, tamper in {
            function(plan) plan.pose[50] = {place = {rotation = {0, 0, 0, 1}}} end,
            function(plan) plan.pose[Q.JOINTS.hips].place.position = vector.create(0/0, 0, 0) end,
            function(plan) plan.pose[Q.JOINTS.left_hand].place.relative_to = "skater" end,
        } do
            local p, f, i = warm()
            local plan = tick(p, .04, i)
            tamper(plan)
            local sends = f.sends
            local r = p:refresh(.05)
            check(not r.ok and not r.sent and r.ended and f.ends == 1 and f.sends == sends, "refresh must refuse")
            p:stop()
            check(f.ends == 1, "refresh refusal cleans up exactly once")
        end
    end)
    test("warm cache cannot skip input validation", function()
        local bad = {
            {change = function(i) i.actor = 1 end, why = "unknown input field actor"},
            {change = function(i) i.bike.actor = 1 end, why = "unknown bike field actor"},
            {change = function(i) i.bike.root[1] = 0/0 end, why = "bike's position"},
            {change = function(i) i.bike.rotation[4] = 2 end, why = "bike's rotation"},
            {change = function(i) i.bike.center_of_mass = {0, 0, 0} end, why = "exactly one"},
            {change = function(i) i.articulation.steer = math.huge end, why = "articulation steer"},
            {change = function(i) i.articulation.crank_phase = nil end, why = "no crank_phase"},
            {change = function(i) i.articulation.extra = 0 end, why = "unknown articulation field"},
            {change = function(i) i.articulation.release_left_hand = -1 end, why = "release_left_hand"},
            {change = function(i) i.rider = {extra = 0} end, why = "unknown rider field"},
            {change = function(i) i.skater_root = {0/0, 0, 0} end, why = "skater's root"},
        }
        for _, row in bad do
            local p, f, i = warm()
            row.change(i)
            refused(p, f, .04, i, row.why)
        end
    end)
    test("bad replacement config or bone names refuse and end a held pose", function()
        for _, row in {
            {options = {blend_in = 0}, why = "option blend_in"},
            {options = {rig = {lengths = {left_tail = .3}}}, why = "unknown joint"},
            {options = {rig = {roots = {left_hand = {0, 0, 0}}}}, why = "unknown joint"},
            {options = {rig = {lengths = {left_arm = 0/0}}}, why = "left_arm length"},
        } do
            local p, f, i = warm()
            p.options = row.options
            refused(p, f, .04, i, row.why)
        end
    end)
    test("stop and completed dismount clear the cache and end only once", function()
        for _, via_dismount in {false, true} do
            local p, f, i = warm()
            if via_dismount then
                tick(p, .3, i)
                check(p:dismount(.31).ok)
                local r = p:tick(1, i)
                check(r.ok and not r.sent and r.ended and r.state == "off")
            else
                check(p:stop().ended)
            end
            p:stop()
            p:stop()
            check(f.ends == 1, "one native end")
            local misses = p.memo_misses
            check(p:mount(2).ok)
            compare(p, 2.02, i)
            check(p.memo_misses == misses + 1, "new mount cannot reuse previous actor lifetime")
        end
    end)
    test("world-axis solver fallbacks retain the original world solution", function()
        local seed_input = {bike = {root = {0, 0, 0}, rotation = {0, 0, 0, 1}}, articulation = {steer = 0, crank_phase = 0}}
        local seed = assert(Q.compose(seed_input, {max_fit = 0}))
        local r = seed.planned.left_arm.root
        local offset = sub(seed.targets.grips[1], seed.targets.wrists[1])
        local h = Q.math.turn(seed.targets.hands[1], {1, 0, 0})
        local u = mul(unit(cross(h, {1, 0, 0})), Q.DEFAULT_RIG.lengths.left_arm)
        local wrist = sub(add(r, u), mul(h, Q.DEFAULT_RIG.lengths.left_fore_arm))
        local direction = unit(sub(wrist, r))
        local zero_geometry, opposite_geometry = copy(G), copy(G)
        zero_geometry.left_grip = add(r, offset)
        opposite_geometry.left_grip = add(wrist, offset)
        local choices = {
            {max_fit = 0, elbow_pole = sub(seed.targets.wrists[1], r)},
            {max_fit = 0, geometry = zero_geometry},
            {max_fit = 0, geometry = opposite_geometry, elbow_pole = sub(u, mul(direction, dot(u, direction))), max_wrist_bend = .2},
            {elbow_pole = {1e-8, 0, 0}}, -- valid but close to the solver's fixed-axis threshold
        }
        for _, options in choices do
            local p = mounted(options)
            local i = copy(seed_input)
            i.bike = {root = {4, 8, -7}, rotation = Q.math.axis_angle(unit({1, 2, 3}), 1.2)}
            compare(p, 0, i)
            compare(p, .02, i)
            check(p.memo_hits == 0 and p.memo_misses == 0, "singular local solve must not be cached")
        end
    end)
    test("production qualification remains a hard no-send gate", function()
        local f = fake()
        local p = MP.new(f.api)
        check(not MP.QUALIFIED and Q.QUALIFIED)
        for _, r in {p:mount(0), p:tick(0, input()), p:refresh(0), p:dismount(1), p:stop()} do
            check(not r.sent and r.reason == MP.NOT_QUALIFIED)
        end
        check(f.sends == 0 and f.ends == 0 and p.memo_hits == 0 and p.memo_misses == 0)
    end)
    return {cases = cases, assertions = assertions, native_calls = 0, game_evidence = false}
end
return {run = run}

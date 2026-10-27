-- Pure contracts for original pose-family descriptors. This tests the authored direction/reach
-- request, not a native pose. mounted_pose_limb_tests checks the final IK targets separately.
local PT = require("./pose_targets")
local catalog = require("./catalog")
local motions = require("./motions")
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
local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function near(a, b, message)
    check(finite(a) and finite(b) and math.abs(a - b) < 1e-12, message or "numbers differ")
end
local LIMBS = {"left_hand", "right_hand", "left_foot", "right_foot"}
local OPPOSITE = {left_hand = "right_hand", right_hand = "left_hand", left_foot = "right_foot", right_foot = "left_foot"}
local function sample(id, phase)
    local value, why = PT.sample(id, phase)
    check(value ~= nil, why)
    return value
end
local function fields(value, allowed)
    check(type(value) == "table" and getmetatable(value) == nil, "plain output table")
    for k in value do check(allowed[k] == true, "unexpected output field " .. tostring(k)) end
end
local function vector3(v)
    fields(v, {[1] = true, [2] = true, [3] = true})
    for i = 1, 3 do check(finite(v[i]), "finite vector component") end
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
        check(not seen[v], "samples share a mutable table")
        for _, child in v do visit(child) end
    end
    record(a)
    visit(b)
end
local function distance(a, b)
    return math.sqrt((a[1]-b[1])^2 + (a[2]-b[2])^2 + (a[3]-b[3])^2)
end

local function run()
    cases, assertions = 0, 0
    test("every existing catalog movement has a bounded authored family descriptor", function()
        local count, families = 0, {}
        for id = 0, 77 do
            local entry = motions.find(id)
            if catalog.name(id) ~= nil then
                count += 1
                check(entry ~= nil, "catalog id has no movement")
                families[entry.family] = true
                for _, phase in {0, .25, .5, 1} do
                    local out = sample(id, phase)
                    fields(out, {movement_id = true, family = true, phase = true, release_mask = true,
                        limb_targets = true, torso = true, provenance = true, realized = true})
                    check(out.movement_id == id and out.family == entry.family and out.phase == phase, "identity unchanged")
                    check(out.release_mask == entry.release_mask, "existing release mask unchanged")
                    check(out.provenance == "authored_pose_targets" and out.realized == false, "no native evidence claim")
                    if out.limb_targets then
                        fields(out.limb_targets, {left_hand = true, right_hand = true, left_foot = true, right_foot = true})
                    end
                    for i, name in LIMBS do
                        local released = math.floor(entry.release_mask / 2^(i-1)) % 2 == 1
                        local target = out.limb_targets and out.limb_targets[name]
                        check((target ~= nil) == released, "targets exactly match released limbs: " .. name)
                        if target then
                            fields(target, {direction = true, reach = true})
                            vector3(target.direction)
                            near(target.direction[1]^2 + target.direction[2]^2 + target.direction[3]^2, 1, "unit target direction")
                            check(finite(target.reach) and target.reach >= 0 and target.reach <= 1, "bounded reach fraction")
                        end
                    end
                    fields(out.torso, {weight = true, pelvis = true, pitch = true, head_yaw = true})
                    near(out.torso.weight, phase, "torso gets exact phase")
                    vector3(out.torso.pelvis)
                    for i = 1, 3 do check(math.abs(out.torso.pelvis[i]) <= .2, "bounded pelvis offset") end
                    check(finite(out.torso.pitch) and math.abs(out.torso.pitch) <= .5, "bounded torso pitch")
                    check(finite(out.torso.head_yaw) and math.abs(out.torso.head_yaw) <= 1.2, "bounded head yaw")
                end
            else
                local out, why = PT.sample(id, .5)
                check(out == nil and type(why) == "string", "catalog holes remain unsupported")
            end
        end
        check(count == 58, "existing 58 movements remain the full input set")
        local family_count = 0
        for _ in families do family_count += 1 end
        check(family_count > 30, "coverage includes all current pose and cycle families")
    end)
    test("all paired families mirror authored limb directions and torso data", function()
        local by_family = {}
        for id = 0, 77 do
            local entry = motions.find(id)
            if entry and entry.direction ~= 0 then
                by_family[entry.family] = by_family[entry.family] or {}
                by_family[entry.family][entry.direction] = id
            end
        end
        local pairs = 0
        for family, ids in by_family do
            if ids[-1] ~= nil and ids[1] ~= nil then
                pairs += 1
                local left, right = sample(ids[-1], .7), sample(ids[1], .7)
                for _, name in LIMBS do
                    local a = left.limb_targets and left.limb_targets[name]
                    local b = right.limb_targets and right.limb_targets[OPPOSITE[name]]
                    check((a == nil) == (b == nil), family .. " swaps released sides")
                    if a then
                        near(a.reach, b.reach, family .. " reach")
                        near(a.direction[1], -b.direction[1], family .. " reflected X")
                        near(a.direction[2], b.direction[2], family .. " same Y")
                        near(a.direction[3], b.direction[3], family .. " same Z")
                    end
                end
                near(left.torso.pelvis[1], -right.torso.pelvis[1], "mirrored pelvis X")
                near(left.torso.pelvis[2], right.torso.pelvis[2], "same pelvis Y")
                near(left.torso.pelvis[3], right.torso.pelvis[3], "same pelvis Z")
                near(left.torso.pitch, right.torso.pitch, "same pitch")
                near(left.torso.head_yaw, -right.torso.head_yaw, "mirrored head yaw")
            end
        end
        check(pairs > 10, "mirror checks reached paired catalog families")
    end)
    test("directions and fractions resolve inside the full two-bone reach interval", function()
        -- These include the extreme valid unequal lengths. Multiplying total length alone would
        -- miss the inner unreachable hole; the contract deliberately interpolates both limits.
        local rigs = {{.04, .04}, {.04, 1}, {1, .04}, {.295098, .273530}, {.408563, .438445}, {1, 1}}
        for id = 0, 77 do
            if catalog.name(id) ~= nil then
                local out = sample(id, 1)
                for _, target in out.limb_targets or {} do
                    for _, bones in rigs do
                        local a, b = bones[1], bones[2]
                        local margin = math.min(.0001, math.min(a, b)*.01)
                        local lower, upper = math.abs(a-b)+margin, a+b-margin
                        local d = lower + target.reach*(upper-lower)
                        local v = target.direction
                        local resolved = math.sqrt((v[1]*d)^2 + (v[2]*d)^2 + (v[3]*d)^2)
                        check(resolved >= lower - 1e-12 and resolved <= upper + 1e-12, "reachable annulus")
                    end
                end
            end
        end
    end)
    test("Can, Nac and One Footer encode three separated endpoint requests", function()
        for _, pair in {{61, 63, 66, "left_foot"}, {77, 75, 72, "right_foot"}} do
            local endpoints = {}
            for i = 1, 3 do
                local t = sample(pair[i], 1).limb_targets[pair[4]]
                local a, b, margin = .408563, .438445, .0001
                local d = math.abs(a-b)+margin + t.reach*((a+b-margin)-(math.abs(a-b)+margin))
                endpoints[i] = {t.direction[1]*d, t.direction[2]*d, t.direction[3]*d}
            end
            check(distance(endpoints[1], endpoints[2]) > .1, "Can vs Nac")
            check(distance(endpoints[1], endpoints[3]) > .1, "Can vs One Footer")
            check(distance(endpoints[2], endpoints[3]) > .1, "Nac vs One Footer")
        end
    end)
    test("phase is neither quantized nor applied twice to target extension", function()
        local a, b = sample(61, .123456789), sample(61, .123456790)
        check(a.phase ~= b.phase and a.torso.weight ~= b.torso.weight, "exact phases retained")
        local off, full = sample(61, 0), sample(61, 1)
        near(off.limb_targets.left_foot.reach, full.limb_targets.left_foot.reach, "release performs the blend")
        for i = 1, 3 do near(off.limb_targets.left_foot.direction[i], full.limb_targets.left_foot.direction[i]) end
        check(off.torso.weight == 0 and full.torso.weight == 1)
    end)
    test("samples never share mutable output or private family tables", function()
        for _, id in {0, 7, 21, 35, 57, 61, 255} do
            local a, b = sample(id, .5), sample(id, .5)
            disjoint(a, b)
            a.family = "changed"
            a.release_mask = 99
            if a.torso then a.torso.pelvis[1] = 99 a.torso.pitch = 99 end
            for _, limb in a.limb_targets or {} do limb.direction[1] = 99 limb.reach = 99 end
            local c = sample(id, .5)
            check(c.family == b.family and c.release_mask == b.release_mask, "metadata stays private")
            if b.torso then near(c.torso.pitch, b.torso.pitch) near(c.torso.pelvis[1], b.torso.pelvis[1]) end
            for name, limb in b.limb_targets or {} do
                near(c.limb_targets[name].reach, limb.reach)
                for i = 1, 3 do near(c.limb_targets[name].direction[i], limb.direction[i]) end
            end
        end
    end)
    test("none is neutral and invalid requests are refused rather than coerced", function()
        local none = sample(catalog.none, .75)
        check(none.family == "none" and none.release_mask == 0 and none.limb_targets == nil and none.torso == nil)
        local function denied(id, phase)
            local out, why = PT.sample(id, phase)
            check(out == nil and type(why) == "string", "invalid request refused")
        end
        denied(nil, .5)
        denied(61, nil)
        for _, id in {false, "61", {}, 0/0, math.huge, -math.huge, .5, -1, 78, 256, 30, 40, 60, 64, 70, 74} do denied(id, .5) end
        for _, phase in {false, "0.5", {}, 0/0, math.huge, -math.huge, -.0001, 1.0001} do
            denied(61, phase)
            denied(catalog.none, phase)
        end
    end)
    test("the module exports only the pure sampling operation", function()
        check(table.isfrozen(PT), "public API is frozen")
        local count = 0
        for name, value in PT do
            count += 1
            check(name == "sample" and type(value) == "function")
        end
        check(count == 1)
        check(not pcall(function() PT.sample = function() return {} end end))
    end)
    return {cases = cases, assertions = assertions, native_calls = 0, game_evidence = false}
end
return {run = run}

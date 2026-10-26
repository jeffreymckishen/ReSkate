-- mounted_pose.lua against constructed fakes of reskate.skater.pose that hold to the argument rules of
-- upstream plugin_api_world.cpp (PR #365, 8fe5d019, and 3d706383): joint keys, places and their
-- relative_to forms, keep_children, the 128-joint cap, the order the joints are posed in, the
-- weight and shown; an older skater.pose without places; and an emulation of pose_place.cpp that
-- turns what was sent into where the joints end up, checked first against the cases of upstream
-- pose_place_tests.cpp. The rider's joint conventions are checked against the r3 alignment capture
-- rows. Pure: no reskate API, no game; a pass is no evidence of what the game draws.
--
-- Needs mounted_pose_qualified_fixture.lua beside it: mounted_pose.lua with its one
-- `local MOUNTED_POSE_QUALIFIED = false` turned true, made only in a test copy (DESIGN.md).
local MP = require("./mounted_pose")
local Q = require("./mounted_pose_qualified_fixture")
local G = require("./bike_geometry")
local V = require("./bike_visual")
local Bones = require("./bones")

local cases, assertions = 0, 0
local function check(ok, message)
    assertions += 1
    if not ok then error(message or "check failed", 2) end
end
local function test(name, fn)
    cases += 1
    local ok, issue = pcall(fn)
    if not ok then error(name .. ": " .. tostring(issue), 0) end
end

------------------------------------------------------------------- maths (the tests' own)
local PI = math.pi
local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function arr(v) if type(v) == "vector" then return {v.x, v.y, v.z} end return v end
local function add(a, b) return {a[1] + b[1], a[2] + b[2], a[3] + b[3]} end
local function sub(a, b) return {a[1] - b[1], a[2] - b[2], a[3] - b[3]} end
local function mul(a, k) return {a[1] * k, a[2] * k, a[3] * k} end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function cross(a, b) return {a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1]} end
local function len(a) return math.sqrt(dot(a, a)) end
local function unit(a) return mul(a, 1 / len(a)) end
local function dist(a, b) return len(sub(arr(a), arr(b))) end
local function qmul(a, b)
    return {a[4] * b[1] + a[1] * b[4] + a[2] * b[3] - a[3] * b[2], a[4] * b[2] - a[1] * b[3] + a[2] * b[4] + a[3] * b[1],
        a[4] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[4], a[4] * b[4] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3]}
end
local function qnorm(q)
    local n = math.sqrt(q[1] ^ 2 + q[2] ^ 2 + q[3] ^ 2 + q[4] ^ 2)
    if not (n > 1e-8) or not finite(n) then return {0, 0, 0, 1} end
    return {q[1] / n, q[2] / n, q[3] / n, q[4] / n}
end
local function conj(q) return {-q[1], -q[2], -q[3], q[4]} end
local function rot(q, v)
    local u = {q[1], q[2], q[3]}
    local t = mul(cross(u, v), 2)
    return add(v, add(mul(t, q[4]), cross(u, t)))
end
local function aa(n, a)
    local l = len(n)
    local s = math.sin(a * .5) / l
    return {n[1] * s, n[2] * s, n[3] * s, math.cos(a * .5)}
end
-- The angle between two rotations, precise for small ones.
local function qangle(a, b)
    local r = qmul(conj(a), b)
    return 2 * math.atan2(math.sqrt(r[1] ^ 2 + r[2] ^ 2 + r[3] ^ 2), math.abs(r[4]))
end
local function slerp(a, b, t)
    local c = a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4]
    if c < 0 then a = {-a[1], -a[2], -a[3], -a[4]} c = -c end
    if c > .9995 then
        return qnorm({a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, a[4] + (b[4] - a[4]) * t})
    end
    local angle = math.acos(math.clamp(c, -1, 1))
    local s = math.sin(angle)
    local wa, wb = math.sin((1 - t) * angle) / s, math.sin(t * angle) / s
    return qnorm({a[1] * wa + b[1] * wb, a[2] * wa + b[2] * wb, a[3] * wa + b[3] * wb, a[4] * wa + b[4] * wb})
end
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in v do out[k] = copy(x) end
    return out
end
local function near(a, b, e, message)
    check(finite(a) and finite(b) and math.abs(a - b) <= (e or 1e-9), (message or "near") .. ": " .. tostring(a) .. " vs " .. tostring(b))
end
local function vnear(a, b, e, message)
    local d = dist(a, b)
    check(finite(d) and d <= (e or 1e-9), (message or "vnear") .. string.format(": %.6f m apart", d))
end
local function qnear(a, b, e, message)
    local d = qangle(qnorm(a), qnorm(b))
    check(finite(d) and d <= (e or 1e-6), (message or "qnear") .. string.format(": %.6f rad apart", d))
end

------------------------------------------------------------------- the skeleton
-- Extension/Multiplayer/Net/skater_bone_parents.h (the parents anim_studio::parent uses; joints past
-- 385 hang from nothing): each joint's parent, for joint i at [i + 1].
local PARENTS = {
    -1, 0, 1, 1, 3, 1, 5, 1, 7, 8, 9, 10, 10, 12, 12, 9, 9, 16, 9, 9,
    9, 20, 20, 20, 9, 24, 24, 8, 27, 27, 27, 27, 27, 27, 8, 8, 8, 8, 37, 37,
    37, 37, 7, 42, 43, 44, 45, 46, 47, 48, 49, 49, 51, 52, 49, 54, 55, 56, 49, 58,
    59, 60, 49, 62, 63, 64, 49, 66, 67, 68, 48, 48, 48, 48, 73, 74, 74, 48, 77, 77,
    77, 48, 81, 81, 47, 84, 84, 84, 84, 88, 88, 88, 88, 88, 47, 47, 47, 46, 46, 46,
    46, 45, 101, 102, 103, 103, 103, 103, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107,
    107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107,
    107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107,
    107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107,
    107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107,
    107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107,
    107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107,
    107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 255, 256, 257, 258,
    259, 260, 261, 262, 263, 263, 263, 266, 267, 267, 267, 102, 102, 101, 101, 45, 275, 276, 277, 278,
    279, 280, 281, 278, 278, 284, 285, 286, 278, 288, 289, 290, 278, 292, 293, 294, 278, 296, 297, 277,
    277, 277, 277, 302, 303, 303, 277, 306, 306, 306, 277, 310, 310, 276, 313, 313, 313, 313, 317, 317,
    317, 317, 317, 276, 276, 276, 275, 275, 275, 275, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45,
    45, 7, 341, 342, 343, 343, 345, 345, 342, 342, 349, 342, 342, 342, 353, 353, 353, 342, 357, 357,
    341, 360, 360, 360, 360, 360, 360, 341, 341, 341, 341, 370, 370, 370, 370, 1, 1, 376, 377, 378,
    378, 378, 377, 382, 382, 382,
}
local function parent(j)
    if j >= 0 and j < #PARENTS then return PARENTS[j + 1] end
    return -1
end
local function hangs_from(joint, ancestor)
    local at = parent(joint)
    while at >= 0 do
        if at == ancestor then return true end
        at = parent(at)
    end
    return false
end

-- build/bmx/alignment-actual-v3/storage-after-stop.json observations.joints: the default skater
-- standing still on MPR (state 504), world positions and rotations as skater.joint read them.
local SNAP = {
    [1] = {position = {307.9456481933594, 275.3114013671875, -474.8175048828125}, rotation = {0, 0.9367279410362244, 0, 0.35005834698677063}},
    [7] = {position = {307.9493713378906, 275.28009033203125, -474.8377685546875}, rotation = {0.25449082255363464, 0.2987007796764374, -0.6373405456542969, -0.6631813049316406}},
    [47] = {position = {308.07763671875, 275.79742431640625, -474.9578857421875}, rotation = {0.7526695728302002, -0.5746116042137146, 0.17249344289302826, -0.27121198177337646}},
    [48] = {position = {308.1605529785156, 275.51434326171875, -474.9732971191406}, rotation = {0.5642545223236084, -0.7606161236763, 0.09095586836338043, -0.30790770053863525}},
    [49] = {position = {308.11297607421875, 275.2638244628906, -475.0735168457031}, rotation = {0.46941879391670227, -0.7523925304412842, 0.18937304615974426, -0.4215320646762848}},
    [276] = {position = {307.84075927734375, 275.80731201171875, -474.70452880859375}, rotation = {0.6340905427932739, -0.6128161549568176, 0.4245186448097229, -0.20535217225551605}},
    [277] = {position = {307.807861328125, 275.5265197753906, -474.61993408203125}, rotation = {0.4646751880645752, -0.7494779825210571, 0.3612756133079529, -0.30305057764053345}},
    [278] = {position = {307.7035217285156, 275.27569580078125, -474.65185546875}, rotation = {0.46739333868026733, -0.7272008061408997, 0.3862271308898926, -0.32179367542266846}},
    [8] = {position = {308.0138854980469, 275.28375244140625, -474.8978576660156}, rotation = {0.34034091234207153, -0.3087075650691986, -0.6172500252723694, 0.638647198677063}},
    [9] = {position = {308.0333251953125, 274.8757629394531, -474.9085388183594}, rotation = {0.3039488196372986, -0.34460538625717163, -0.5427166819572449, 0.7030795812606812}},
    [10] = {position = {308.1093444824219, 274.4493103027344, -474.8407287597656}, rotation = {0.4845391809940338, -0.1310294270515442, -0.837919294834137, 0.21434614062309265}},
    [341] = {position = {307.888427734375, 275.2762145996094, -474.7765197753906}, rotation = {0.15204589068889618, -0.18998508155345917, -0.7770707011222839, 0.5804729461669922}},
    [342] = {position = {307.7740783691406, 274.884033203125, -474.782958984375}, rotation = {0.12372031062841415, -0.2095472812652588, -0.6873453259468079, 0.6843535304069519}},
    [343] = {position = {307.7597351074219, 274.4488220214844, -474.7317810058594}, rotation = {0.3018764555454254, -0.08769568800926208, -0.9174204468727112, 0.2439669966697693}},
}

------------------------------------------------------------------- a fake skater.pose
-- What plugin_api_world.cpp skater_pose does with its arguments, in its order, with its messages.
-- mode "new": PR #365 and after; mode "old": before it (no place or keep_children, 64 joints).
local NAMED = {right_hand = 49, left_hand = 278, head = 103, hips = 7, spine = 42, root = 1}
local JOINT_TEXT = "a joint is a number 0 to 394, or right_hand, left_hand, head, hips, spine or root"
local function raise(text) error(text, 0) end
local function type_error(n, want, got)
    raise(string.format("invalid argument #%d to 'pose' (%s expected, got %s)", n, want, typeof(got)))
end
local function number_at(v, n) -- luaL_checknumber: a number or a numeric string
    if type(v) == "number" then return v end
    local x = type(v) == "string" and tonumber(v)
    if x then return x end
    type_error(n, "number", v)
    return 0
end
local function joint_of(v, n)
    if type(v) == "string" then
        local id = NAMED[v]
        if not id then raise(JOINT_TEXT) end
        return id
    end
    local j = number_at(v, n)
    if not (j >= 0 and j <= 394) or j ~= math.floor(j) then raise(JOINT_TEXT) end
    return j
end
local function position_of(v, what) -- luaL_checkvector, then finite within 100 km
    if type(v) ~= "vector" then type_error(-1, "vector", v) end
    local p = {v.x, v.y, v.z}
    for i = 1, 3 do if not finite(p[i]) or math.abs(p[i]) > 1e5 then raise(what .. " must be a finite position within 100 km") end end
    return p
end
local function quaternion_at(v)
    if type(v) ~= "table" then type_error(-1, "table", v) end
    local q = {}
    for i = 1, 4 do
        local x = number_at(rawget(v, i), -1)
        if not finite(x) then raise("a rotation is 4 finite numbers {x, y, z, w}") end
        q[i] = x
    end
    local n = math.sqrt(q[1] ^ 2 + q[2] ^ 2 + q[3] ^ 2 + q[4] ^ 2)
    if not (n > 1e-4) then raise("a rotation {x, y, z, w} has a length") end
    return {q[1] / n, q[2] / n, q[3] / n, q[4] / n}
end
local function from_euler(d)
    local k = PI / 180
    return qnorm(qmul(qmul(aa({1, 0, 0}, d[1] * k), aa({0, 1, 0}, d[2] * k)), aa({0, 0, 1}, d[3] * k)))
end
local function place_of(t)
    if type(t) ~= "table" then type_error(-1, "table", t) end
    local place = {frame = "parent"}
    if t.position ~= nil then place.position = position_of(t.position, "a joint's place") end
    if t.rotation ~= nil then place.rotation = quaternion_at(t.rotation) end
    if t.angles ~= nil then place.rotation = from_euler(position_of(t.angles, "a joint's place's angles")) end
    local r = t.relative_to
    if type(r) == "string" and r == "skater" then
        place.frame = "skater"
    elseif type(r) == "string" and r == "world" then
        place.frame = "world"
    elseif r ~= nil then
        place.frame, place.joint = "joint", joint_of(r, -1)
    end
    if not place.position and not place.rotation then raise("a joint's place has a position, a rotation or both") end
    return place
end
-- pose_place::order: each entry after the posed joints it hangs from and after the joint it is
-- placed relative to (and what that hangs from); each time the lowest joint that is ready.
local function order_of(joints, relative_to)
    local n = #joints
    local after = {}
    for i = 1, n do
        local to = relative_to[i]
        if to == joints[i] then return nil, string.format("joint %d is placed relative to itself", joints[i]) end
        if to >= 0 and hangs_from(to, joints[i]) then
            return nil, string.format("joint %d is placed relative to joint %d, which hangs from it", joints[i], to)
        end
        after[i] = {}
        for k = 1, n do
            if k ~= i then
                local above = hangs_from(joints[i], joints[k])
                local frame = to >= 0 and (joints[k] == to or hangs_from(to, joints[k]))
                if above or frame then table.insert(after[i], k) end
            end
        end
    end
    local done, out = {}, {}
    while #out < n do
        local next_entry = nil
        for i = 1, n do
            if not done[i] then
                local ready = true
                for _, k in after[i] do if not done[k] then ready = false end end
                if ready and (next_entry == nil or joints[i] < joints[next_entry]) then next_entry = i end
            end
        end
        if not next_entry then
            local circle = {}
            for i = 1, n do if not done[i] then table.insert(circle, tostring(joints[i])) end end
            return nil, "joints " .. table.concat(circle, ", ") .. " are placed relative to each other in a circle"
        end
        done[next_entry] = true
        table.insert(out, next_entry)
    end
    return out
end

local function new_fake(config)
    config = config or {}
    local f = {calls = {}, accepted = {}, clock = 0, held_until = nil, ends = 0, raised = 0,
        mode = config.mode or "new", permission = config.permission ~= false, refuse = config.refuse}
    local function implementation(count, poses, weight, options)
        if not f.permission then raise('reskate.skater.pose needs the "skater.animation" permission in reskate-plugin.json') end
        local offsets = {}
        if poses ~= nil then
            if type(poses) ~= "table" then type_error(1, "table", poses) end
            for key, value in poses do
                local o = {joint = joint_of(key, -2), rotation = {0, 0, 0, 1}, scale = 1, offset = {0, 0, 0}, keep_children = false}
                if o.joint < 2 then raise("joints 0 and 1 place the skater in the world: they cannot be posed") end
                if type(value) ~= "table" then type_error(-1, "table", value) end
                if value.rotation ~= nil then o.rotation = quaternion_at(value.rotation) end
                if value.angles ~= nil then o.rotation = from_euler(position_of(value.angles, "a joint's angles")) end
                if value.scale ~= nil then
                    local s = number_at(value.scale, -1)
                    if not (s >= 0 and s <= 10) then raise("a joint's scale is 0 to 10") end
                    o.scale = s
                end
                if value.offset ~= nil then
                    o.offset = position_of(value.offset, "a joint's offset")
                    for i = 1, 3 do if math.abs(o.offset[i]) > 2 then raise("a joint's offset is at most 2 m on each axis") end end
                end
                if f.mode == "new" then
                    if value.place ~= nil then o.place = place_of(value.place) end
                    if value.keep_children ~= nil then
                        if type(value.keep_children) ~= "boolean" then type_error(-1, "boolean", value.keep_children) end
                        o.keep_children = value.keep_children
                    end
                end
                for _, e in offsets do if e.joint == o.joint then raise(string.format("joint %d is posed twice", o.joint)) end end
                local cap = f.mode == "new" and 128 or 64
                if #offsets >= cap then raise(string.format("at most %d joints are posed at once", cap)) end
                table.insert(offsets, o)
            end
            if f.mode == "new" then
                local joints, relative_to = {}, {}
                for i, o in offsets do
                    joints[i] = o.joint
                    relative_to[i] = o.place and o.place.frame == "joint" and o.place.joint or -1
                end
                local order, why = order_of(joints, relative_to)
                if not order then raise(why) end
                local sorted = {}
                for i, k in order do sorted[i] = offsets[k] end
                offsets = sorted
            end
        end
        local w = 1
        if count >= 2 and weight ~= nil then w = number_at(weight, 2) end
        if not (w >= 0 and w <= 1) then raise("invalid argument #2 to 'pose' (a weight is 0 to 1)") end
        local shown = "everyone"
        if count >= 3 and options ~= nil then
            if type(options) ~= "table" then type_error(3, "table", options) end
            if options.shown ~= nil then
                if type(options.shown) ~= "string" then type_error(-1, "string", options.shown) end
                if options.shown == "others" or options.shown == "me" or options.shown == "everyone" then shown = options.shown
                else raise("a pose's shown is \"everyone\", \"others\" or \"me\"") end
            end
        end
        if f.refuse then return false, f.refuse end
        table.insert(f.accepted, {offsets = offsets, weight = w, shown = shown, time = f.clock})
        if #offsets == 0 then
            f.held_until, f.ends = nil, f.ends + 1
        else
            f.held_until = f.clock + .3
        end
        return true
    end
    function f.pose(...)
        local count = select("#", ...)
        local poses, weight, options = ...
        table.insert(f.calls, {poses = poses, weight = weight, count = count, time = f.clock})
        local ok, accepted, why = pcall(implementation, count, poses, weight, options)
        if not ok then
            f.raised += 1
            error(accepted, 0)
        end
        if accepted then return true end
        return false, why
    end
    f.api = {skater = {pose = f.pose}}
    return f
end
-- A reskate table that records every key read and every call other than skater.pose.
local function trapped(f)
    local touched, others = {}, {}
    local function recorder(name) return function(...) table.insert(others, name) return nil end end
    local real_skater = {pose = f.pose, joint = recorder("skater.joint"), hand = recorder("skater.hand"),
        reach = recorder("skater.reach"), carry = recorder("skater.carry"), get = recorder("skater.get"),
        telemetry = recorder("skater.telemetry"), state = recorder("skater.state"), hide = recorder("skater.hide")}
    local skater = setmetatable({}, {__index = function(_, k)
        table.insert(touched, "skater." .. tostring(k))
        return real_skater[k]
    end, __newindex = function() error("the module wrote to reskate.skater", 0) end})
    local real = {skater = skater, time = {now = recorder("time.now")}, entities = {set = recorder("entities.set"),
        remove = recorder("entities.remove")}, storage = {get = recorder("storage.get"), set = recorder("storage.set")},
        log = recorder("log"), on = recorder("on"), input = {focus = recorder("input.focus")},
        body = {create = recorder("body.create")}, world = {raycast = recorder("world.raycast")}}
    local api = setmetatable({}, {__index = function(_, k)
        table.insert(touched, tostring(k))
        return real[k]
    end, __newindex = function() error("the module wrote to reskate", 0) end})
    return api, touched, others
end

------------------------------------------------------------------- pose_place.cpp, emulated
local IDENTITY = {position = {0, 0, 0}, rotation = {0, 0, 0, 1}, scale = 1}
local function compose_t(frame, child)
    local k = frame.scale
    return {position = add(frame.position, rot(frame.rotation, mul(child.position, k))),
        rotation = qnorm(qmul(frame.rotation, child.rotation)), scale = k * child.scale}
end
local function relative_t(frame, w)
    local k = math.max(frame.scale, 1e-4)
    local back = conj(frame.rotation)
    return {position = mul(rot(back, sub(w.position, frame.position)), 1 / k), rotation = qnorm(qmul(back, w.rotation)), scale = w.scale / k}
end
local function world_of(pose, j)
    if j < 0 or pose[j] == nil then return copy(IDENTITY) end
    local chain = {}
    local at = j
    while at >= 0 do
        check(pose[at] ~= nil, "the emulated pose has joint " .. at)
        table.insert(chain, at)
        at = parent(at)
    end
    local out = copy(IDENTITY)
    for i = #chain, 1, -1 do out = compose_t(out, pose[chain[i]]) end
    return out
end
local function apply_place(pose, joint, place, w)
    local now = copy(pose[joint])
    local wanted
    if place.frame == "parent" then
        wanted = {position = place.position and copy(place.position) or now.position, rotation = place.rotation and qnorm(place.rotation) or now.rotation}
    else
        local pw = world_of(pose, parent(joint))
        local frame = place.frame == "joint" and world_of(pose, place.joint) or place.frame == "skater" and world_of(pose, 1) or copy(IDENTITY)
        local in_frame = relative_t(frame, compose_t(pw, now))
        if place.position then in_frame.position = copy(place.position) end
        if place.rotation then in_frame.rotation = qnorm(place.rotation) end
        wanted = relative_t(pw, compose_t(frame, in_frame))
    end
    local t = math.clamp(w, 0, 1)
    pose[joint] = {position = add(now.position, mul(sub(wanted.position, now.position), t)),
        rotation = slerp(now.rotation, wanted.rotation, t), scale = now.scale}
end
local function keep(pose, joint)
    local kept = {}
    for c in pose do if parent(c) == joint then table.insert(kept, {joint = c, world = world_of(pose, c)}) end end
    return kept
end
local function put_back(pose, joint, kept)
    local now = world_of(pose, joint)
    for _, k in kept do pose[k.joint] = relative_t(now, k.world) end
end
-- skater_animation.cpp pose_joints: offsets, then the place, then kept children put back.
local function evaluate(base, record)
    local pose = copy(base)
    local w = math.clamp(record.weight, 0, 1)
    for _, o in record.offsets do
        if pose[o.joint] then
            local kept = o.keep_children and keep(pose, o.joint) or nil
            local j = pose[o.joint]
            j.rotation = qnorm(qmul(j.rotation, slerp({0, 0, 0, 1}, o.rotation, w)))
            j.scale = j.scale * math.max(1 + (o.scale - 1) * w, 1e-3)
            j.position = add(j.position, mul(o.offset, w))
            if o.place then apply_place(pose, o.joint, o.place, w) end
            if kept then put_back(pose, o.joint, kept) end
        end
    end
    return pose
end

-- An animated pose to place against: the r3 snapshot moved rigidly so its joint 1 stands at
-- `root_at`, turned `yaw` about up, with made-up spine, clavicle and neck joints between; `bend`
-- folds the upper body forward that far, for a different animation under the same joints.
local function base_pose(root_at, yaw, bend)
    local s1 = {position = SNAP[1].position, rotation = qnorm(SNAP[1].rotation), scale = 1}
    local new1 = {position = root_at, rotation = aa({0, 1, 0}, yaw), scale = 1}
    local W = {}
    for id, row in SNAP do
        W[id] = compose_t(new1, relative_t(s1, {position = row.position, rotation = qnorm(row.rotation), scale = 1}))
    end
    local hips = W[7]
    local up = rot(hips.rotation, {1, 0, 0})
    local function along(d) return {position = add(hips.position, mul(up, d)), rotation = copy(hips.rotation), scale = 1} end
    W[42], W[43], W[44], W[45] = along(.1), along(.2), along(.3), along(.4)
    W[101], W[102], W[103] = along(.48), along(.56), along(.64)
    W[46] = {position = mul(add(W[45].position, W[47].position), .5), rotation = copy(hips.rotation), scale = 1}
    W[275] = {position = mul(add(W[45].position, W[276].position), .5), rotation = copy(hips.rotation), scale = 1}
    if bend then
        local pivot = W[42].position
        local r = aa(rot(hips.rotation, {0, 0, 1}), bend)
        for _, id in {43, 44, 45, 46, 47, 48, 49, 101, 102, 103, 275, 276, 277, 278} do
            W[id] = {position = add(pivot, rot(r, sub(W[id].position, pivot))), rotation = qnorm(qmul(r, W[id].rotation)), scale = 1}
        end
    end
    W[0] = copy(IDENTITY)
    local pose = {}
    for id, w in W do pose[id] = id == 0 and copy(IDENTITY) or relative_t(W[parent(id)], w) end
    return pose
end
-- The upstream test's made-up pose on the whole skeleton (pose_place_tests.cpp made_up_pose).
local function made_up_pose()
    local pose = {}
    for i = 0, 394 do pose[i] = {position = {.01 * (i % 7), .1, .02}, rotation = aa({0, 0, 1}, .05 * (i % 5)), scale = 1} end
    pose[1] = {position = {3, 0, -2}, rotation = aa({0, 1, 0}, 1.2), scale = 1}
    return pose
end

------------------------------------------------------------------- the bike, as bike_visual draws it
local S = G.scale
local RADIUS = .0164 * S
local function visual_pose(a)
    return {steer = a.steer or 0, front_wheel_phase = 0, rear_wheel_phase = 0, crank_phase = a.crank_phase or 0,
        barspin = a.barspin or 0, tailwhip = a.tailwhip or 0, movement_bike_pitch = a.movement_bike_pitch or 0,
        movement_bike_roll = a.movement_bike_roll or 0}
end
local function apply_matrix(m, p)
    return {m[13] + p[1] * m[1] + p[2] * m[5] + p[3] * m[9], m[14] + p[1] * m[2] + p[2] * m[6] + p[3] * m[10],
        m[15] + p[1] * m[3] + p[2] * m[7] + p[3] * m[11]}
end
local function root_of(bike) return bike.root or sub(bike.center_of_mass, rot(bike.rotation, G.com)) end
local function drawn(bike, a)
    local m = assert(V.matrices(root_of(bike), bike.rotation, visual_pose(a)))
    return {grips = {apply_matrix(m[6], G.left_grip), apply_matrix(m[6], G.right_grip)},
        spindles = {apply_matrix(m[7], G.pedals[1]), apply_matrix(m[8], G.pedals[2])}}
end
local function to_local(bike, p) return rot(conj(bike.rotation), sub(arr(p), root_of(bike))) end
-- A point in part `part`'s own frame as bike_visual draws it (part 1 is the frame with the saddle).
local function in_part(bike, a, part, p)
    local m = assert(V.matrices(root_of(bike), bike.rotation, visual_pose(a)))[part]
    local d = sub(arr(p), {m[13], m[14], m[15]})
    return {d[1] * m[1] + d[2] * m[2] + d[3] * m[3], d[1] * m[5] + d[2] * m[6] + d[3] * m[7], d[1] * m[9] + d[2] * m[10] + d[3] * m[11]}
end
-- Part `part`'s axis `axis` (1 to 3) in the world, as bike_visual draws it.
local function part_axis(bike, a, part, axis)
    local m = assert(V.matrices(root_of(bike), bike.rotation, visual_pose(a)))[part]
    return {m[(axis - 1) * 4 + 1], m[(axis - 1) * 4 + 2], m[(axis - 1) * 4 + 3]}
end
local function angle_of(a, b) return math.acos(math.clamp(dot(unit(a), unit(b)), -1, 1)) end
local function deg(r) return r * 180 / PI end
local BIKES = {
    {root = {0, 0, 0}, rotation = {0, 0, 0, 1}},
    {root = {307.9, 274.36, -474.8}, rotation = aa({0, 1, 0}, -2.286)},
    {center_of_mass = {-1520.5, 12.25, 2210.75}, rotation = qnorm(qmul(aa({0, 1, 0}, 1.1), aa({1, 0, 0}, .15)))},
    {root = {12, 3, -4}, rotation = qnorm(qmul(aa({0, 1, 0}, .4), aa({0, 0, 1}, .3)))},
}
local function base_for(bike, bend)
    local root = root_of(bike)
    return base_pose(add(root, rot(bike.rotation, {.4, .9, -.6})), .7, bend)
end
local function posed(plan, weight, base)
    local f = new_fake()
    check(f.pose(plan.pose, weight or 1, {shown = "everyone"}) == true, "the fake skater.pose accepted the plan")
    return evaluate(base, f.accepted[#f.accepted]), f.accepted[#f.accepted]
end
local LEFT_HAND, RIGHT_HAND, LEFT_FOOT, RIGHT_FOOT = 278, 49, 343, 10
local function palm(pose, side)
    local hand = world_of(pose, side > 0 and LEFT_HAND or RIGHT_HAND)
    return add(hand.position, rot(hand.rotation, {.055, 0, side * (RADIUS + .004)}))
end
local function input(bike, a, rider) return {bike = bike, articulation = a, rider = rider} end
local function plan_of(i, o)
    local plan, why = Q.compose(i, o)
    check(plan ~= nil, "composed: " .. tostring(why))
    return plan
end

------------------------------------------------------------------- the suite
local function run()
    test("bones.lua names and ids are the upstream joints", function()
        check(MP.JOINT_ISSUE == nil and Q.JOINT_ISSUE == nil, tostring(MP.JOINT_ISSUE))
        local J = MP.JOINTS
        -- plugin_api_world.cpp joint_of's names, as upstream pose_place_tests use them.
        check(J.hips == NAMED.hips and J.right_hand == NAMED.right_hand and J.left_hand == NAMED.left_hand and J.head == NAMED.head)
        for _, row in Bones do
            check(row.parent == parent(row.id), row.name .. "'s parent in bones.lua is the skeleton's")
            if row.name ~= "root" then check(J[row.name] == row.id, row.name .. " maps to its bones.lua id") end
        end
        for _, limb in MP.LIMBS do
            check(parent(J[limb.middle]) == J[limb.upper] and parent(J[limb.tip]) == J[limb.middle], limb.name .. " is a chain")
        end
        check(parent(J.right_up_leg) == J.hips and parent(J.left_up_leg) == J.hips and parent(J.head) == 102)
        local children = {}
        for j = 0, 385 do if parent(j) == 7 then table.insert(children, j) end end
        check(#children == 3 and children[1] == 8 and children[2] == 42 and children[3] == 341, "the hips have three children")
        check(hangs_from(J.right_hand, NAMED.spine) and hangs_from(J.head, NAMED.spine) and not hangs_from(J.right_foot, NAMED.spine))
    end)

    test("the rig conventions are what the r3 capture measured", function()
        local rig = MP.DEFAULT_RIG
        local function frame(id) return qnorm(SNAP[id].rotation) end
        for _, limb in MP.LIMBS do
            local J = MP.JOINTS
            local u, m, t = J[limb.upper], J[limb.middle], J[limb.tip]
            near(dist(SNAP[u].position, SNAP[m].position), rig.lengths[limb.upper], 2e-6, limb.upper .. " length")
            near(dist(SNAP[m].position, SNAP[t].position), rig.lengths[limb.middle], 2e-6, limb.middle .. " length")
            for _, pair in {{u, m}, {m, t}} do
                local d = rot(conj(frame(pair[1])), sub(SNAP[pair[2]].position, SNAP[pair[1]].position))
                check(d[1] / len(d) > .9999, "joint " .. pair[1] .. " points at its child along its own +X")
            end
            check(dot(rot(frame(u), {0, 0, 1}), rot(frame(m), {0, 0, 1})) > .9999, limb.name .. ": the hinge +Z is shared")
            local l = qmul(conj(frame(u)), frame(m))
            if l[4] < 0 then l = {-l[1], -l[2], -l[3], -l[4]} end
            check(math.abs(l[1]) < 1e-3 and math.abs(l[2]) < 1e-3 and l[3] > .1, limb.name .. " bends about +Z by a positive angle")
            -- The module's frame rule on the measured limb: +Z = cross(side the joint points out to, the line).
            local S0, E, W = SNAP[u].position, SNAP[m].position, SNAP[t].position
            local line = unit(sub(W, S0))
            local out = unit(sub(sub(E, S0), mul(line, dot(sub(E, S0), line))))
            local z = unit(cross(out, line))
            check(dot(z, rot(frame(u), {0, 0, 1})) > .999, limb.name .. ": cross(side, line) is the measured hinge")
            local x = unit(sub(E, S0))
            check(dot(cross(z, x), rot(frame(u), {0, 1, 0})) > .999, limb.name .. ": +Y = +Z x +X")
        end
        -- Roots in the hips' frame.
        local hips = frame(7)
        for _, pair in {{"right_up_leg", 8}, {"left_up_leg", 341}} do
            vnear(rot(conj(hips), sub(SNAP[pair[2]].position, SNAP[7].position)), rig.roots[pair[1]], 2e-6, pair[1] .. " root")
        end
        local r = rot(conj(hips), sub(SNAP[47].position, SNAP[7].position))
        local l = rot(conj(hips), sub(SNAP[276].position, SNAP[7].position))
        vnear(rig.roots.left_arm, {(r[1] + l[1]) / 2, (r[2] + l[2]) / 2, (l[3] - r[3]) / 2}, 2e-6, "shoulders: the mean, mirrored")
        vnear(rig.roots.right_arm, {(r[1] + l[1]) / 2, (r[2] + l[2]) / 2, -(l[3] - r[3]) / 2}, 2e-6)
        -- The hips: +X up, +Y forward, +Z left in the rider's frame, near {.5, .5, .5, .5}.
        local hips_rider = MP.rider_rotation(SNAP[1].rotation, SNAP[7].rotation)
        check(qangle(hips_rider, MP.HIPS_REST) < 8 * PI / 180, "the hips rest frame")
        local fwd = rot(qnorm(qmul(qnorm(SNAP[1].rotation), aa({0, 1, 0}, PI / 2))), {0, 0, 1})
        check(dot(fwd, rot(hips, {0, 1, 0})) > .99, "the rider frame's forward is the hips' +Y")
        -- Feet: with the sole on level ground, +X slopes foot_slope below level; +Z is the left.
        local slope = 0
        for _, id in {10, 343} do
            slope += math.asin(-rot(frame(id), {1, 0, 0})[2]) / 2
            check(dot(rot(frame(id), {0, 0, 1}), rot(hips, {0, 0, 1})) > .9, "foot +Z to the left")
        end
        near(slope, rig.foot_slope, 2e-6, "foot slope")
        -- Hands hanging: +Z points to the rider's right on both, so the left palm (+Z) and the right
        -- palm (-Z) both face in.
        for _, id in {49, 278} do
            check(dot(rot(frame(id), {0, 0, 1}), rot(hips, {0, 0, 1})) < -.8, "hand " .. id .. " +Z to the right")
        end
    end)

    test("the emulated pose_place matches upstream pose_place_tests", function()
        local turned = aa({1, 0, 0}, .7)
        local function one(joint, place, w)
            local pose = made_up_pose()
            apply_place(pose, joint, place, w)
            return pose
        end
        local p = one(42, {frame = "parent", position = {0, .2, 0}, rotation = turned}, 1)
        vnear(p[42].position, {0, .2, 0}, 1e-6) qnear(p[42].rotation, turned)
        local before = made_up_pose()[42].position
        p = one(42, {frame = "parent", position = {0, .5, 0}}, .5)
        vnear(p[42].position, {before[1] * .5, (before[2] + .5) * .5, before[3] * .5}, 1e-6, "half the weight: halfway")
        local turn_before = world_of(made_up_pose(), 103).rotation
        p = one(103, {frame = "world", position = {1, 2, 3}}, 1)
        vnear(world_of(p, 103).position, {1, 2, 3}, 1e-6) qnear(world_of(p, 103).rotation, turn_before, 1e-6)
        p = one(103, {frame = "skater", position = {0, 1.5, .2}, rotation = turned}, 1)
        local wanted = compose_t(world_of(p, 1), {position = {0, 1.5, .2}, rotation = turned, scale = 1})
        vnear(world_of(p, 103).position, wanted.position, 1e-6) qnear(world_of(p, 103).rotation, wanted.rotation)
        p = one(49, {frame = "joint", joint = 278, position = {0, 0, -.1}, rotation = turned}, 1)
        wanted = compose_t(world_of(p, 278), {position = {0, 0, -.1}, rotation = turned, scale = 1})
        vnear(world_of(p, 49).position, wanted.position, 1e-6) qnear(world_of(p, 49).rotation, wanted.rotation)
        -- Children kept stay where they were; not kept they move.
        local pose = made_up_pose()
        local thigh, spine, shin = world_of(pose, 8).position, world_of(pose, 42).position, world_of(pose, 9).position
        local kept = keep(pose, 7)
        check(#kept == 3, "the hips have three children")
        apply_place(pose, 7, {frame = "parent", position = {0, .3, 0}, rotation = turned}, 1)
        put_back(pose, 7, kept)
        vnear(world_of(pose, 8).position, thigh, 1e-6) vnear(world_of(pose, 42).position, spine, 1e-6) vnear(world_of(pose, 9).position, shin, 1e-6)
        -- The order, and the three cases without one.
        local out = assert(order_of({49, 278, 9, 7}, {278, -1, -1, -1}))
        local at = {}
        for i, e in out do at[e] = i end
        check(at[2] < at[1] and at[4] < at[3], "after the joint it is placed relative to, and after its parent")
        check(not order_of({42}, {42}) and not order_of({7}, {42}))
        local none, why = order_of({49, 278}, {278, 49})
        check(none == nil and string.find(why, "in a circle", 1, true) ~= nil)
    end)

    test("the fake refuses what skater.pose refuses, with its messages", function()
        local f = new_fake()
        local pose = f.pose
        local function refused(expect, ...)
            local ok, message = pcall(pose, ...)
            check(not ok and string.find(tostring(message), expect, 1, true) ~= nil, "expected '" .. expect .. "', got " .. tostring(message))
        end
        local v = vector.create
        refused("table expected", 5)
        refused(JOINT_TEXT, {tail = {}})
        refused(JOINT_TEXT, {["7"] = {}})
        refused(JOINT_TEXT, {[7.5] = {}})
        refused(JOINT_TEXT, {[395] = {}})
        refused("number expected", {[true] = {}})
        refused("joints 0 and 1", {[1] = {}})
        refused("table expected", {[7] = 3})
        refused("a joint's scale is 0 to 10", {head = {scale = 11}})
        refused("a weight is 0 to 1", {head = {}}, 2)
        refused("a weight is 0 to 1", {head = {}}, -.1)
        refused("number expected", {head = {}}, "heavy")
        refused("joint 103 is posed twice", {head = {}, [103] = {}})
        refused("a joint's place has a position, a rotation or both", {[49] = {place = {relative_to = 278}}})
        refused("vector expected", {[49] = {place = {position = {0, 0, 0}}}})
        refused("must be a finite position within 100 km", {[49] = {place = {position = v(0 / 0, 0, 0)}}})
        refused("must be a finite position within 100 km", {[49] = {place = {position = v(2e5, 0, 0)}}})
        refused("a rotation is 4 finite numbers", {[49] = {place = {rotation = {0, 0, 0 / 0, 1}}}})
        refused("has a length", {[49] = {place = {rotation = {0, 0, 0, 0}}}})
        refused("number expected", {[49] = {place = {rotation = {0, 0, 1}}}})
        refused(JOINT_TEXT, {[49] = {place = {position = v(0, 0, 0), relative_to = "moon"}}})
        refused("boolean expected", {head = {keep_children = 1}})
        refused("relative to itself", {[49] = {place = {position = v(0, 0, 0), relative_to = 49}}})
        refused("which hangs from it", {hips = {place = {position = v(0, 0, 0), relative_to = "spine"}}})
        refused("in a circle", {[49] = {place = {position = v(0, 0, 0), relative_to = 278}}, [278] = {place = {position = v(0, 0, 0), relative_to = 49}}})
        refused('shown is "everyone", "others" or "me"', {head = {}}, 1, {shown = "nobody"})
        local many = {}
        for j = 2, 129 do many[j] = {scale = 1} end
        check(pose(many) == true, "128 joints")
        many[130] = {scale = 1}
        refused("at most 128 joints are posed at once", many)
        -- PR #365's own plugin test pose, in its order.
        check(pose({[49] = {place = {position = v(0, 0, -.1), relative_to = 278}},
            [278] = {place = {angles = v(0, 0, 90), relative_to = "skater"}, keep_children = true},
            head = {place = {position = v(1, 2, 3), relative_to = "world"}}, [42] = {place = {position = v(0, .2, 0)}}}) == true)
        local got = {}
        for _, o in f.accepted[#f.accepted].offsets do table.insert(got, o.joint) end
        check(table.concat(got, " ") == "42 103 278 49", "the order upstream's test expects: " .. table.concat(got, " "))
        qnear(f.accepted[#f.accepted].offsets[3].place.rotation, {0, 0, math.sqrt(.5), math.sqrt(.5)}, 1e-6, "angles in degrees")
        check(pose(nil) == true and f.held_until == nil and f.ends == 1, "nil ends it")
        check(f.pose({}) == true and f.ends == 2, "so does an empty pose")
        local p2 = new_fake({permission = false})
        local ok, message = pcall(p2.pose, nil)
        check(not ok and string.find(message, "skater.animation", 1, true) ~= nil, "the permission is checked first")
        local old = new_fake({mode = "old"})
        check(old.pose({[49] = {place = {position = v(0, 0, 0)}}}) == true, "an older skater.pose reads no place")
        check(#old.accepted[1].offsets[1].offset == 3 and old.accepted[1].offsets[1].place == nil)
        local old_many = {}
        for j = 2, 66 do old_many[j] = {} end
        check(not pcall(old.pose, old_many), "an older skater.pose takes 64")
        local refusing = new_fake({refuse = "unavailable"})
        local accepted, why = refusing.pose({head = {}})
        check(accepted == false and why == "unavailable", "the game's refusal is false and why")
    end)

    test("the place probe tells the skater.pose versions apart and poses nothing", function()
        for _, case in {{mode = "new", capability = "place"}, {mode = "old", issue = "older than PR #365"},
            {mode = "new", permission = false, issue = "skater.animation"}} do
            local f = new_fake({mode = case.mode, permission = case.permission})
            local ok, message = pcall(f.pose, {[MP.PROBE_JOINT] = {place = {}}}, MP.PROBE_WEIGHT)
            local capability, issue = MP.classify_probe(ok, message)
            check(not ok and #f.accepted == 0 and f.held_until == nil, "the probe posed nothing")
            if case.capability then check(capability == case.capability) else
                check(capability == nil and string.find(issue, case.issue, 1, true) ~= nil, tostring(issue)) end
        end
        local capability, issue = MP.classify_probe(true)
        check(capability == nil and string.find(issue, "weight of 2", 1, true) ~= nil)
        capability, issue = MP.classify_probe(false, "something else")
        check(capability == nil and string.find(issue, "something else", 1, true) ~= nil)
    end)

    test("each joint's relative_to and keep_children", function()
        local plan = plan_of(input(BIKES[2], {crank_phase = .4, steer = .2}))
        local J = MP.JOINTS
        check(plan.count == 13, "13 joints: the hips and three for each limb")
        check(MP.validate_pose(plan.pose))
        local world = {J.hips, J.left_hand, J.right_hand, J.left_up_leg, J.right_up_leg, J.left_foot, J.right_foot}
        for _, id in world do
            local e = plan.pose[id]
            check(e and e.place.relative_to == "world" and e.keep_children == false, "joint " .. id .. " placed in the world")
            check(type(e.place.rotation) == "table" and #e.place.rotation == 4, "joint " .. id .. " has a rotation")
        end
        for _, id in {J.left_arm, J.right_arm} do
            local e = plan.pose[id]
            check(e and e.place.relative_to == J.hips and e.keep_children == false, "upper arm " .. id .. " placed in the hips' frame")
        end
        for _, id in {J.left_fore_arm, J.right_fore_arm, J.left_leg, J.right_leg} do
            local e = plan.pose[id]
            check(e and e.place.relative_to == nil and e.place.position == nil and e.keep_children == false, "joint " .. id .. " in its parent's frame")
        end
        check(type(plan.pose[J.hips].place.position) == "vector", "the hips have a position")
        for _, side in {"left_arm", "right_arm"} do
            vnear(plan.pose[J[side]].place.position, MP.DEFAULT_RIG.roots[side], 1e-6, side .. ": the stance's shoulder, in the hips' frame")
        end
        for id, e in plan.pose do
            check(e.place.position == nil or id == J.hips or id == J.left_arm or id == J.right_arm,
                "joint " .. id .. ": no hand, foot, elbow, knee or hip socket is given a position")
        end
        for id in plan.pose do check(type(id) == "number" and id ~= 0 and id ~= 1, "joints by number, never 0 or 1") end
        local _, record = posed(plan, 1, base_for(BIKES[2]))
        check(record.offsets[1].joint == J.hips, "the hips are posed first")
        local seen = {}
        for _, o in record.offsets do
            if parent(o.joint) ~= 1 then check(seen[parent(o.joint)] or not plan.pose[parent(o.joint)], "joint " .. o.joint .. " after its parent") end
            seen[o.joint] = true
        end
    end)

    test("the hands land on the grips", function()
        local count = 0
        local J = MP.JOINTS
        for b, bike in BIKES do
            -- The spun bar is held as an X-up holds it (barspin_hold pi): without that the hands let go.
            for _, case in {{a = {crank_phase = 0}}, {a = {crank_phase = 1.1, steer = .45}},
                {a = {crank_phase = 4, steer = -.6, barspin = 1.3}, o = {barspin_hold = PI}},
                {a = {crank_phase = 2, movement_bike_pitch = .2, movement_bike_roll = -.15}}} do
                local a = case.a
                local plan = plan_of(input(bike, a), case.o)
                local pose = posed(plan, 1, base_for(bike))
                local want = drawn(bike, a)
                for i, side in {1, -1} do
                    local name = side > 0 and "left_arm" or "right_arm"
                    check(plan.targets.releases[i] == 0, "the hand holds")
                    vnear(plan.targets.grips[i], want.grips[i], 1e-7, "the planned grip is bike_visual's")
                    vnear(palm(pose, side), want.grips[i], 2e-3, string.format("bike %d palm %d on the grip", b, i))
                    qnear(world_of(pose, side > 0 and LEFT_HAND or RIGHT_HAND).rotation, plan.planned[name].tip_rotation, 1e-4, "hand turned as planned")
                    -- Where the wrist cap turns a hand less than the grip asks, it is by no more than the excess.
                    local d = plan.diagnostics.limbs[name]
                    check(d.swing_degrees <= deg(MP.STANCE.max_wrist_bend) + .05, string.format("%s's wrist bends %.2f degrees", name, d.swing_degrees))
                    if not d.wrist_limited then qnear(plan.planned[name].tip_rotation, plan.targets.hands[i], 1e-12, "uncapped: the grip's own turn") end
                    count += 1
                end
                check(plan.pose[J.left_hand].place.position == nil and plan.pose[J.right_hand].place.position == nil, "the hands are only turned")
            end
        end
        check(count == 32)
    end)

    test("the hands close over the grips palm down", function()
        local bike = BIKES[1]
        local plan = plan_of(input(bike, {crank_phase = 0}))
        for i, side in {1, -1} do
            local hand = plan.targets.hands[i]
            local outward = unit(MP.CONTACTS.grip_outward[i == 1 and "left" or "right"])
            check(rot(hand, {0, 0, side})[2] < -.9, "the palm faces down onto the grip")
            check(dot(rot(hand, {0, 1, 0}), outward) < -.999, "+Y runs along the tube, inward")
            local x = rot(hand, {1, 0, 0})
            near(math.asin(-x[2] / len(x)), MP.STANCE.wrist_slope, .05, "the fingers point forward and a little down")
            check(x[3] > .9)
        end
    end)

    test("the feet stand on the pedal spindles as the cranks turn", function()
        local bike = BIKES[2]
        local C = MP.CONTACTS
        local bb = G.bottom_bracket
        for _, crank in {0, PI / 2, PI, 3 * PI / 2, 1.234, -2.5, 31.7} do
            local a = {crank_phase = crank}
            local plan = plan_of(input(bike, a))
            local pose = posed(plan, 1, base_for(bike))
            local want = drawn(bike, a)
            for i, side in {1, -1} do
                vnear(plan.targets.spindles[i], want.spindles[i], 1e-7, "the planned spindle is bike_visual's pedal")
                local ankle = world_of(pose, side > 0 and LEFT_FOOT or RIGHT_FOOT)
                vnear(ankle.position, plan.targets.ankles[i], 2e-3, "the foot joint is at its ankle target")
                local key = side > 0 and "left" or "right"
                local offset = add(sub(C.pedal_face[key], C.pedal_spindle[key]), {0, C.ankle_from_sole, 0})
                vnear(rot(conj(bike.rotation), sub(ankle.position, want.spindles[i])), offset, 2e-3, "the ankle stands on that spindle's pedal")
                local s = to_local(bike, want.spindles[i])
                near(math.sqrt((s[2] - bb[2]) ^ 2 + (s[3] - bb[3]) ^ 2), .24056151769963072 * S, 1e-6, "on the crank circle")
                local platform = plan.targets.platforms[i]
                qnear(ankle.rotation, plan.targets.feet[i], 1e-4)
                check(dot(rot(ankle.rotation, {0, 0, 1}), rot(platform, {1, 0, 0})) > .9999, "the foot's +Z is the bike's left")
                near(dot(rot(ankle.rotation, {1, 0, 0}), rot(platform, {0, 1, 0})), -math.sin(MP.DEFAULT_RIG.foot_slope), 1e-4, "the sole flat on the pedal")
            end
            local l, r = to_local(bike, want.spindles[1]), to_local(bike, want.spindles[2])
            near(l[2] + r[2], 2 * bb[2], 1e-6, "the cranks are opposite") near(l[3] + r[3], 2 * bb[3], 1e-6)
        end
        -- Pedalling forward: the top pedal goes forward, then down.
        local a, b = plan_of(input(bike, {crank_phase = 0})), plan_of(input(bike, {crank_phase = .2}))
        local high = to_local(bike, a.targets.spindles[2])[2] > to_local(bike, a.targets.spindles[1])[2] and 2 or 1
        check(to_local(bike, b.targets.spindles[high])[3] > to_local(bike, a.targets.spindles[high])[3], "a positive crank_phase pedals forward")
        local moved = plan_of(input(bike, {crank_phase = 0}), {foot_fore_aft = -.08})
        vnear(sub(to_local(bike, moved.targets.ankles[1]), to_local(bike, a.targets.ankles[1])), {0, 0, -.08}, 1e-6, "foot_fore_aft moves the ankle along the pedal")
        -- Through a small held tailwhip and a whole-bike pitch and roll, each spindle, pedal platform
        -- and ankle is where bike_visual draws its pedal (parts 7 and 8).
        for _, w in {{crank_phase = .9, tailwhip = .08}, {crank_phase = 2.2, tailwhip = -.06, movement_bike_pitch = .25},
            {crank_phase = 4.1, movement_bike_roll = -.3, movement_bike_pitch = -.2}, {crank_phase = 5, tailwhip = .09, movement_bike_roll = .2}} do
            for _, b in {BIKES[2], BIKES[3]} do
                local plan = plan_of(input(b, w))
                local pose = posed(plan, 1, base_for(b))
                local want = drawn(b, w)
                for i, side in {1, -1} do
                    local part = 6 + i
                    check(plan.targets.releases[i + 2] == 0, "a whip this small is held")
                    vnear(plan.targets.spindles[i], want.spindles[i], 1e-7, "the spindle is bike_visual's through whip, pitch and roll")
                    for axis = 1, 3 do
                        local e = {0, 0, 0}
                        e[axis] = 1
                        vnear(rot(plan.targets.platforms[i], e), part_axis(b, w, part, axis), 1e-7, "the platform turns as bike_visual turns the pedal")
                    end
                    local key = side > 0 and "left" or "right"
                    local offset = add(sub(C.pedal_face[key], C.pedal_spindle[key]), {0, C.ankle_from_sole, 0})
                    local ankle = world_of(pose, side > 0 and LEFT_FOOT or RIGHT_FOOT)
                    vnear(in_part(b, w, part, ankle.position), add(G.pedals[i], offset), 2e-3, "the ankle stands on the drawn pedal")
                    qnear(ankle.rotation, plan.targets.feet[i], 1e-4)
                    near(dot(rot(ankle.rotation, {1, 0, 0}), part_axis(b, w, part, 2)), -math.sin(MP.DEFAULT_RIG.foot_slope), 1e-4, "the sole flat on the drawn pedal")
                end
            end
        end
    end)

    test("the hips ride over the saddle", function()
        local bike = BIKES[4]
        local g = MP.options().geometry
        local saddle = g.saddle
        local half_pelvis = .5 * dist(MP.DEFAULT_RIG.roots.left_up_leg, MP.DEFAULT_RIG.roots.right_up_leg)
        near(saddle.top, .702625573, 1e-12) near(saddle.rear, (-.31 - .10) * S, 1e-9) near(saddle.front, (-.09 + .10) * S, 1e-9)
        local previous = nil
        -- min_knee low enough that the knee floor (its own case below) does not lift these hips.
        local loose = {min_knee = .35}
        for _, crouch in {0, .05, .1, .13} do
            local plan = plan_of(input(bike, {crank_phase = .7}, {crouch = crouch}), loose)
            check(plan.diagnostics.knee_limited == false, "the knee floor is out of this case")
            local pose = posed(plan, 1, base_for(bike))
            local hip = to_local(bike, world_of(pose, 7).position)
            near(hip[1], 0, 1e-3, "over the midline")
            near(hip[2], MP.STANCE.hip_height - crouch, 1e-3, "the crouch lowers the hips")
            check(hip[3] >= saddle.rear and hip[3] <= saddle.front, "within the saddle's length")
            check(hip[2] - saddle.top >= half_pelvis + MP.STANCE.seat_clearance - 1e-3, "above the seat")
            check(plan.diagnostics.seat_limited == false and plan.diagnostics.saddle_limited == false)
            if previous then check(hip[2] < previous) end
            previous = hip[2]
        end
        local deep = plan_of(input(bike, {crank_phase = .7}, {crouch = .3}), loose)
        check(deep.diagnostics.seat_limited == true, "a crouch into the saddle stops on it")
        near(deep.diagnostics.hip_local[2], saddle.top + half_pelvis + MP.STANCE.seat_clearance, 1e-9)
        local aside = plan_of(input(bike, {crank_phase = .7}, {hip_offset = {.2, 0, -.2}}), loose)
        check(aside.diagnostics.saddle_limited == true)
        near(aside.diagnostics.hip_local[1], saddle.half_width, 1e-12) near(aside.diagnostics.hip_local[3], saddle.rear, 1e-12)
        -- The chest turns with the bars by follow_bars of the steer, and leans forward by lean.
        local steer = .5
        local plan = plan_of(input(bike, {crank_phase = 0, steer = steer}))
        local forward = rot(conj(bike.rotation), rot(plan.pose[7].place.rotation, {0, 1, 0}))
        near(math.atan2(forward[1], forward[3]), MP.STANCE.follow_bars * steer, 1e-6, "the chest follows the bars")
        local spine = rot(conj(bike.rotation), rot(plan.pose[7].place.rotation, {1, 0, 0}))
        near(math.acos(spine[2]), MP.STANCE.lean, 1e-6, "the torso leans toward the bars")
        local still = plan_of(input(bike, {crank_phase = 0, steer = steer}), {follow_bars = 0})
        local f0 = rot(conj(bike.rotation), rot(still.pose[7].place.rotation, {0, 1, 0}))
        near(math.atan2(f0[1], f0[3]), 0, 1e-9)
    end)

    test("the limbs stay a body's", function()
        local bike = BIKES[3]
        local base = base_for(bike)
        local J = MP.JOINTS
        local elbows, knees = {180, 0}, {180, 0}
        for k = 0, 35 do
            local a = {crank_phase = k * PI / 18, steer = .3 * math.sin(k)}
            local plan = plan_of(input(bike, a))
            for name, limb in plan.diagnostics.limbs do
                check(limb.clamped == false and limb.reaches == true and limb.release == 0, name .. " reaches its target")
                local bag = string.find(name, "arm", 1, true) and elbows or knees
                bag[1], bag[2] = math.min(bag[1], limb.interior_degrees), math.max(bag[2], limb.interior_degrees)
            end
            if k % 9 == 0 then
                local pose = posed(plan, 1, base)
                for _, limb in MP.LIMBS do
                    local u, m, t = world_of(pose, J[limb.upper]), world_of(pose, J[limb.middle]), world_of(pose, J[limb.tip])
                    near(dist(u.position, m.position), MP.DEFAULT_RIG.lengths[limb.upper], 2e-3, limb.upper .. " keeps its length")
                    local d = rot(conj(m.rotation), sub(t.position, m.position))
                    vnear(d, {MP.DEFAULT_RIG.lengths[limb.middle], 0, 0}, 2e-3, limb.tip .. " is where its parent ends: nothing stretched")
                    check(dot(rot(u.rotation, {0, 0, 1}), rot(m.rotation, {0, 0, 1})) > (limb.arm and .5 or .9999), limb.name .. " bends about its hinge")
                end
            end
        end
        check(elbows[1] > 65 and elbows[2] < 125, string.format("elbows %.1f to %.1f degrees", elbows[1], elbows[2]))
        check(knees[1] >= deg(MP.STANCE.min_knee) - 1e-6 and knees[2] < 176, string.format("knees %.1f to %.1f degrees", knees[1], knees[2]))
        -- With no forearm turn the elbow is a pure hinge and the wrist takes the whole pronation.
        local plan = plan_of(input(bike, {crank_phase = 1}), {forearm_twist_share = 0})
        for _, id in {J.left_fore_arm, J.right_fore_arm, J.left_leg, J.right_leg} do
            local r = plan.pose[id].place.rotation
            check(math.abs(r[1]) < 1e-9 and math.abs(r[2]) < 1e-9, "joint " .. id .. " turns about +Z only")
        end
        for _, name in {"left_arm", "right_arm"} do
            local d = plan.diagnostics.limbs[name]
            check(math.abs(d.twist) > 1.2 and math.abs(d.twist) < 1.8, "a palm-down grip pronates about a quarter turn")
            near(d.tip_twist, d.twist, 1e-12)
            check(d.swing_degrees < 35, "the hand carries on from the forearm")
        end
        local split = plan_of(input(bike, {crank_phase = 1}))
        near(split.diagnostics.limbs.left_arm.tip_twist, .5 * split.diagnostics.limbs.left_arm.twist, 1e-12, "half at the wrist")
        -- The elbows point down and a little out; the knees forward.
        local p = plan.planned
        for _, name in {"left_arm", "right_arm"} do
            local l = p[name]
            local line = unit(sub(l.tip, l.root))
            local out = rot(conj(bike.rotation), sub(sub(l.middle, l.root), mul(line, dot(sub(l.middle, l.root), line))))
            check(out[2] < 0, name .. "'s elbow points down")
        end
        for _, name in {"left_leg", "right_leg"} do
            local l = p[name]
            check(rot(conj(bike.rotation), sub(l.middle, l.root))[3] > rot(conj(bike.rotation), sub(l.tip, l.root))[3] * .5, name .. "'s knee points forward")
        end
    end)

    test("at full weight the result does not depend on the animation", function()
        for _, bike in {BIKES[1], BIKES[4]} do
            local plan = plan_of(input(bike, {crank_phase = 2.2, steer = -.3}))
            local a = posed(plan, 1, base_for(bike))
            local b = posed(plan, 1, base_pose(add(root_of(bike), {-1.5, .2, 2}), -1.9, .45))
            for _, id in {7, 47, 276, 49, 278, 10, 343, 48, 277, 9, 342} do
                vnear(world_of(a, id).position, world_of(b, id).position, 2e-3, "joint " .. id .. " lands the same")
                qnear(world_of(a, id).rotation, world_of(b, id).rotation, 1e-3)
            end
            for _, side in {1, -1} do vnear(palm(a, side), palm(b, side), 2e-3) end
        end
    end)

    test("out of reach the pelvis moves in, at most max_fit, and nothing is stretched", function()
        local bike = BIKES[1]
        local short = {rig = {lengths = {left_up_leg = .36, left_leg = .38}}}
        local J = MP.JOINTS
        -- The emulated skeleton gets the short leg too, so its chain is the rig's.
        local function shortened(pose)
            pose[J.left_leg] = {position = {.36, 0, 0}, rotation = pose[J.left_leg].rotation, scale = 1}
            pose[J.left_foot] = {position = {.38, 0, 0}, rotation = pose[J.left_foot].rotation, scale = 1}
            return pose
        end
        local plan = plan_of(input(bike, {crank_phase = 0}), short)
        check(plan.diagnostics.fit > .01 and plan.diagnostics.fit < .05 and plan.diagnostics.fit_limited == false, tostring(plan.diagnostics.fit))
        check(plan.diagnostics.limbs.left_leg.clamped == false and plan.diagnostics.limbs.left_leg.reaches == true)
        local pose = posed(plan, 1, shortened(base_for(bike)))
        vnear(world_of(pose, LEFT_FOOT).position, plan.targets.ankles[1], 2e-3, "the pelvis fit lets the short leg reach")
        short.max_fit = .005
        plan = plan_of(input(bike, {crank_phase = 0}), short)
        check(plan.diagnostics.fit_limited == true and plan.diagnostics.limbs.left_leg.clamped == true and plan.diagnostics.limbs.left_leg.reaches == false)
        check(plan.pose[J.left_foot].place.position == nil and plan.pose[J.left_foot].place.rotation ~= nil, "the foot is only turned")
        local base = shortened(base_for(bike))
        pose = posed(plan, 1, base)
        -- Straight toward the pedal and short of it, on the end of its own shin: not stretched.
        local d = plan.diagnostics.limbs.left_leg
        check(d.interior_degrees > 177, "the leg is straight (to the IK's 0.1 mm margin)")
        vnear(pose[LEFT_FOOT].position, base[LEFT_FOOT].position, 1e-9, "the foot stays where its shin ends")
        near(dist(world_of(pose, LEFT_FOOT).position, plan.targets.ankles[1]), d.requested - d.reach, 2e-3, "short of the pedal by what it cannot reach")
    end)

    test("the head follows the bars only from a calibrated rotation", function()
        local bike = BIKES[2]
        local i = input(bike, {crank_phase = 0, steer = .4})
        check(plan_of(i).pose[103] == nil, "without a calibration the head rides with the torso")
        local calibrated = MP.rider_rotation(SNAP[1].rotation, SNAP[7].rotation)
        local plan = plan_of(i, {head = {rotation = calibrated, follow = .5}})
        check(plan.count == 14 and plan.pose[103].place.relative_to == "world" and plan.pose[103].place.position == nil)
        qnear(plan.pose[103].place.rotation, qmul(qmul(bike.rotation, aa({0, 1, 0}, .2)), calibrated), 1e-9)
        check(MP.validate_pose(plan.pose))
        local none, why = Q.compose(i, {head = {follow = .5}})
        check(none == nil and string.find(why, "calibrated", 1, true) ~= nil)
    end)

    test("at every weight each elbow, hand, knee and foot stays on the end of its parent", function()
        -- skater.pose blends each joint's value in its parent's frame (pose_place.cpp apply). A joint
        -- given no position keeps its own offset from its parent at any weight, so it cannot come
        -- loose; only the pinned shoulders move off theirs, and in the hips' frame that is the same
        -- share of the stance's offset from the animation's shoulder at every weight.
        local J = MP.JOINTS
        local weights = {0, .1, .25, .5, .75, .9, 1}
        local count = 0
        for _, bike in {BIKES[1], BIKES[2], BIKES[4]} do
            for _, a in {{crank_phase = 1, steer = .2}, {crank_phase = 2.5, steer = -.4, movement_bike_pitch = .15},
                {crank_phase = 4, barspin = .2, tailwhip = .05, release_right_hand = .4}} do
                for _, o in {{}, {pin_shoulders = false}} do
                    local plan = plan_of(input(bike, a), o)
                    local base = base_for(bike)
                    local full = {}
                    for _, w in weights do
                        local pose = posed(plan, w, base)
                        for _, limb in MP.LIMBS do
                            for _, j in {limb.middle, limb.tip} do
                                vnear(pose[J[j]].position, base[J[j]].position, 1e-6, string.format("w %.2f: %s on the end of its parent", w, j))
                                count += 1
                            end
                            if not limb.arm then vnear(pose[J[limb.upper]].position, base[J[limb.upper]].position, 1e-6, "the hip socket is the skeleton's") end
                        end
                        for _, side in {"left_arm", "right_arm"} do
                            local moved = dist(pose[J[side]].position, base[J[side]].position)
                            if w == 1 then full[side] = moved end
                            if o.pin_shoulders == false then near(moved, 0, 1e-6, "an unpinned shoulder stays the animation's") end
                        end
                    end
                    -- The shoulder's share is linear in the weight, and the stance's shoulder is near the animation's.
                    for _, w in weights do
                        local pose = posed(plan, w, base)
                        for _, side in {"left_arm", "right_arm"} do
                            near(dist(pose[J[side]].position, base[J[side]].position), w * full[side], 1e-6, "the shoulder moves its share of the stance's offset")
                            check(full[side] < .05, string.format("%s's stance shoulder is %.3f m from the animation's", side, full[side]))
                        end
                    end
                    if o.pin_shoulders ~= false then
                        local pose = posed(plan, 1, base)
                        for i, side in {1, -1} do vnear(palm(pose, side), plan.targets.palms[i], 2e-3, "at weight 1 the chain ends on the palm's point") end
                        for i, id in {LEFT_FOOT, RIGHT_FOOT} do vnear(world_of(pose, id).position, plan.targets.ankles[i], 2e-3, "and on the ankle's") end
                    end
                end
            end
        end
        check(count == 3 * 3 * 2 * #weights * 8)
        -- A refresh part way through the blend sends the same part-weight pose: it stays joined too.
        local f = new_fake()
        local poser = Q.new(f.api)
        local bike = BIKES[2]
        local base = base_for(bike)
        poser:mount(0)
        for k = 0, 5 do f.clock = k / 60 poser:tick(f.clock, input(bike, {crank_phase = 1 + k / 10, steer = .2})) end
        f.clock += .1
        local again = poser:refresh(f.clock)
        check(again.sent and again.weight > .1 and again.weight < .9, "a part-weight refresh: " .. tostring(again.weight))
        local pose = evaluate(base, f.accepted[#f.accepted])
        for _, limb in MP.LIMBS do
            for _, j in {limb.middle, limb.tip} do vnear(pose[J[j]].position, base[J[j]].position, 1e-6, "refreshed: " .. j .. " joined") end
        end
    end)

    test("the hips stay above the saddle bike_visual draws through a pitch and a roll", function()
        local g = MP.options().geometry
        local saddle = g.saddle
        local margin = .5 * dist(MP.DEFAULT_RIG.roots.left_up_leg, MP.DEFAULT_RIG.roots.right_up_leg) + MP.STANCE.seat_clearance
        -- The knee floor would lift a deep crouch first; a low min_knee leaves the seat floor alone.
        local loose = {min_knee = .35}
        local floored = 0
        for _, bike in {BIKES[1], BIKES[3]} do
            for _, pitch in {-.35, -.2, 0, .2, .35} do
                for _, roll in {-.3, 0, .3} do
                    for _, crouch in {0, .13, .3} do
                        local a = {crank_phase = .7, movement_bike_pitch = pitch, movement_bike_roll = roll}
                        local plan = plan_of(input(bike, a, {crouch = crouch}), loose)
                        local pose = posed(plan, 1, base_for(bike))
                        -- In doubles; the emulated hips are within float precision of it (2.7 km out, 0.2 mm).
                        local hip = in_part(bike, a, 1, plan.targets.hips)
                        vnear(world_of(pose, 7).position, plan.targets.hips, 1e-3, "the hips land where planned")
                        local tag = string.format("pitch %.2f roll %.2f crouch %.2f", pitch, roll, crouch)
                        check(hip[2] - saddle.top >= margin - 1e-6, tag .. string.format(": %.4f above the drawn seat top", hip[2] - saddle.top))
                        check(math.abs(hip[1]) <= saddle.half_width + 1e-6 and hip[3] >= saddle.rear - 1e-6 and hip[3] <= saddle.front + 1e-6, tag .. ": over the drawn saddle")
                        near(plan.diagnostics.hip_above_seat, hip[2] - saddle.top, 1e-6, tag .. ": the diagnostic is the drawn seat's")
                        if plan.diagnostics.seat_limited then floored += 1 end
                    end
                end
            end
        end
        check(floored >= 10, "the floor is what holds some of them: " .. floored)
        -- The review's cases: nose down 0.35 and 0.20 with a 0.13 m crouch both stop on the floor.
        for _, pitch in {.35, .2} do
            local plan = plan_of(input(BIKES[1], {crank_phase = .7, movement_bike_pitch = pitch}, {crouch = .13}), loose)
            check(plan.diagnostics.seat_limited == true, "pitch " .. pitch .. " stops on the drawn seat")
        end
        -- Held bars carry the pelvis 0.75 of the grips' displacement, all of it with both feet off.
        local bike = BIKES[4]
        local neutral = {crank_phase = 1, steer = .1}
        local a = {crank_phase = 1, steer = .1, movement_bike_pitch = .2, movement_bike_roll = -.15}
        local function grips_moved(feet)
            local x = table.clone(a)
            for k, v in feet or {} do x[k] = v end
            local d = mul(sub(add(to_local(bike, drawn(bike, a).grips[1]), to_local(bike, drawn(bike, a).grips[2])),
                add(to_local(bike, drawn(bike, neutral).grips[1]), to_local(bike, drawn(bike, neutral).grips[2]))), .5)
            return d, x
        end
        local stance = {0, MP.STANCE.hip_height, MP.STANCE.hip_z}
        local d, x = grips_moved()
        vnear(plan_of(input(bike, x)).diagnostics.hip_wanted, add(stance, mul(d, .75)), 1e-9, "0.75 of the grips' displacement")
        d, x = grips_moved({release_left_foot = 1, release_right_foot = 1})
        vnear(plan_of(input(bike, x)).diagnostics.hip_wanted, add(stance, d), 1e-9, "all of it with both feet off")
        -- Let go of the bars, and the pelvis is neither carried nor seated on the turned saddle: the
        -- bike turns under it, and the floor is the bike's own (unpitched) seat.
        d, x = grips_moved({release_left_hand = 1, release_right_hand = 1})
        x.movement_bike_pitch = .35
        local free = plan_of(input(bike, x, {crouch = .3}), loose)
        vnear(free.diagnostics.hip_wanted, {0, MP.STANCE.hip_height - .3, MP.STANCE.hip_z}, 1e-9, "not carried")
        qnear(free.diagnostics.seat_rotation, {0, 0, 0, 1}, 1e-12, "the seat frame is the bike's own")
        near(free.diagnostics.hip_local[2], saddle.top + margin, 1e-9, "on the bike's own seat floor")
        check(free.diagnostics.seat_limited == true)
        -- Half let go: the seat frame is half way round.
        x.release_left_hand, x.release_right_hand = .5, 0
        local half = plan_of(input(bike, x), loose)
        local whole = qmul(aa({0, 0, 1}, x.movement_bike_roll), aa({1, 0, 0}, x.movement_bike_pitch))
        near(qangle({0, 0, 0, 1}, half.diagnostics.seat_rotation), .5 * qangle({0, 0, 0, 1}, whole), 1e-9, "half the turn")
    end)

    test("a hand or foot lets go when released, and of a part spun or whipped away", function()
        local bike = BIKES[2]
        local q = bike.rotation
        local C = MP.CONTACTS
        local bb = G.bottom_bracket
        local J = MP.JOINTS
        local base = base_for(bike)
        -- The free places are bmx_rider_pose.h's: beside the unspun grip, and parked off the pedals.
        local a = {crank_phase = 1, steer = .3, barspin = .2, release_left_hand = 1, release_right_foot = 1}
        local plan = plan_of(input(bike, a))
        local unspun = table.clone(a)
        unspun.barspin = 0
        vnear(plan.targets.palms[1], add(drawn(bike, unspun).grips[1], rot(q, {.08, .12, -.08})), 1e-9, "a free left palm")
        vnear(plan.targets.palms[2], drawn(bike, a).grips[2], 1e-9, "the right still holds")
        local still = plan_of(input(bike, {crank_phase = 1, steer = .3}))
        qnear(plan.targets.hands[1], still.targets.hands[1], 1e-9, "a free hand turns with the steer alone, not the spin")
        check(qangle(plan.targets.hands[2], still.targets.hands[2]) > .19, "the holding hand turns with the spun bar")
        vnear(plan.targets.ankles[2], add(root_of(bike), rot(q, {-.2792422, bb[2] + C.ankle_from_sole + .43, bb[3] - .08})), 1e-9, "a parked right foot")
        local pose = posed(plan, 1, base)
        vnear(palm(pose, 1), plan.targets.palms[1], 2e-3, "the chain ends on the free palm")
        vnear(world_of(pose, RIGHT_FOOT).position, plan.targets.ankles[2], 2e-3, "and on the parked ankle")
        near(dot(rot(plan.targets.feet[2], {1, 0, 0}), rot(q, {0, 1, 0})), -math.sin(MP.DEFAULT_RIG.foot_slope), 1e-9, "its sole level with the bike")
        -- A parked foot stops cycling; a held one goes on.
        local later = table.clone(a)
        later.crank_phase = 2.5
        local plan2 = plan_of(input(bike, later))
        vnear(plan2.targets.ankles[2], plan.targets.ankles[2], 1e-9, "a released foot does not cycle")
        check(dist(plan2.targets.ankles[1], plan.targets.ankles[1]) > .1, "a held foot does")
        -- Part released, part of the way: in place and in turn.
        local mid = plan_of(input(bike, {crank_phase = 1, steer = .3, barspin_release = .5}))
        local held = plan_of(input(bike, {crank_phase = 1, steer = .3}))
        local gone = plan_of(input(bike, {crank_phase = 1, steer = .3, barspin_release = 1}))
        for i = 1, 2 do
            vnear(mid.targets.palms[i], mul(add(held.targets.palms[i], gone.targets.palms[i]), .5), 1e-9, "half released, half way")
            near(qangle(held.targets.hands[i], mid.targets.hands[i]), .5 * qangle(held.targets.hands[i], gone.targets.hands[i]), 1e-9, "and half turned")
        end
        local whip = plan_of(input(bike, {crank_phase = 1, tailwhip_release = 1}))
        check(whip.targets.releases[3] == 1 and whip.targets.releases[4] == 1 and whip.targets.releases[1] == 0)
        -- Released feet tuck (bmx_rider_pose.h's parked place folds the knees) without lifting the pelvis.
        check(whip.diagnostics.knee_limited == false, "a released foot's tuck does not lift the hips")
        near(whip.diagnostics.hip_local[2], MP.STANCE.hip_height, 1e-9)
        check(whip.diagnostics.limbs.left_leg.interior_degrees < deg(MP.STANCE.min_knee), "the tuck folds the knee")
        -- With no release given, a barspin lets the hands go past barspin_hold, over hold_ramp, and
        -- takes them back as the bars come round: never crossing the arms.
        local St = MP.STANCE
        local last_palms, largest = nil, 0
        for k = 0, 628 do
            local spin = k / 100
            local p = plan_of(input(bike, {crank_phase = 1, barspin = spin}))
            local r = p.targets.releases[1]
            local x = math.abs(MP.math.wrap(spin))
            if x <= St.barspin_hold then check(r == 0, "held at " .. spin) end
            if x >= St.barspin_hold + St.hold_ramp then check(r == 1, "let go at " .. spin) end
            near(r, MP.hold_release(spin, St.barspin_hold, St.hold_ramp), 1e-12)
            check(p.targets.releases[2] == r and p.targets.releases[3] == 0, "both hands, not the feet")
            check(to_local(bike, p.targets.palms[1])[1] > .05 and to_local(bike, p.targets.palms[2])[1] < -.05, "the arms never cross at " .. spin)
            for _, name in {"left_arm", "right_arm"} do
                local d = p.diagnostics.limbs[name]
                check(d.reaches and d.interior_degrees < 150, string.format("%s at barspin %.2f: elbow %.1f", name, spin, d.interior_degrees))
                check(d.swing_degrees <= deg(St.max_wrist_bend) + .05)
            end
            if last_palms then largest = math.max(largest, dist(p.targets.palms[1], last_palms[1]), dist(p.targets.palms[2], last_palms[2])) end
            last_palms = p.targets.palms
        end
        check(largest < .02, string.format("no jump: at most %.4f m per 0.01 rad of spin", largest))
        -- A tailwhip likewise lets the feet go: they never chase the frame round with straight legs.
        local whip_largest, last_ankles = 0, nil
        for k = 0, 628 do
            local w = k / 100
            local p = plan_of(input(bike, {crank_phase = 1, tailwhip = w}))
            local r = p.targets.releases[3]
            near(r, MP.hold_release(w, St.tailwhip_hold, St.hold_ramp), 1e-12)
            check(p.targets.releases[4] == r and p.targets.releases[1] == 0, "both feet, not the hands")
            for i, name in {"left_leg", "right_leg"} do
                local d = p.diagnostics.limbs[name]
                check(d.reaches and d.interior_degrees < 176, string.format("%s at tailwhip %.2f: knee %.1f", name, w, d.interior_degrees))
                -- How far a foot turns off the bike's own level foot while it still holds a whipped pedal.
                check(qangle(p.targets.feet[i], p.targets.free_feet[i]) < .16, string.format("foot %d turned %.3f rad at %.2f", i, qangle(p.targets.feet[i], p.targets.free_feet[i]), w))
            end
            if last_ankles then whip_largest = math.max(whip_largest, dist(p.targets.ankles[1], last_ankles[1]), dist(p.targets.ankles[2], last_ankles[2])) end
            last_ankles = p.targets.ankles
        end
        check(whip_largest < .035, string.format("no jump: at most %.4f m per 0.01 rad of whip", whip_largest))
        -- An X-up holds the spun bars by choice (barspin_hold pi): the arms cross, the wrists still capped.
        local xup = plan_of(input(bike, {crank_phase = 1, barspin = PI}), {barspin_hold = PI})
        check(xup.targets.releases[1] == 0 and to_local(bike, xup.targets.palms[1])[1] < 0, "the left hand on the right of the bike")
        for _, name in {"left_arm", "right_arm"} do
            check(xup.diagnostics.limbs[name].swing_degrees <= deg(St.max_wrist_bend) + .05 and xup.diagnostics.limbs[name].wrist_limited == true)
        end
        pose = posed(xup, 1, base)
        for i, side in {1, -1} do vnear(palm(pose, side), xup.targets.grips[i], 2e-3, "an X-up's palms on the spun grips") end
        check(xup.pose[J.left_hand].place.position == nil)
    end)

    test("no wrist bends further than max_wrist_bend, and the palm stays on its grip", function()
        local cap = deg(MP.STANCE.max_wrist_bend)
        local capped = {}
        for b, bike in {BIKES[1], BIKES[2]} do
            local base = base_for(bike)
            for _, steer in {-.9, -.6, -.45, -.2, 0, .2, .45, .6, .9} do
                local plan = plan_of(input(bike, {crank_phase = 1, steer = steer}))
                local pose = posed(plan, 1, base)
                for i, side in {1, -1} do
                    local name = side > 0 and "left_arm" or "right_arm"
                    local d = plan.diagnostics.limbs[name]
                    check(d.swing_degrees <= cap + .05, string.format("bike %d steer %.2f %s: %.2f degrees", b, steer, name, d.swing_degrees))
                    -- In the plan's own doubles: the capped hand's palm is still on its point.
                    local l = plan.planned[name]
                    vnear(add(l.tip, rot(l.tip_rotation, {.055, 0, side * (RADIUS + .004)})), plan.targets.palms[i], 1e-9, "the palm stays on its point")
                    vnear(palm(pose, side), plan.targets.grips[i], 2e-3, string.format("steer %.2f: palm %d on the grip", steer, i))
                    -- Measured on the emulated skeleton: the forearm's line against the hand's +X.
                    local fore, hand = world_of(pose, side > 0 and 277 or 48), world_of(pose, side > 0 and LEFT_HAND or RIGHT_HAND)
                    check(deg(angle_of(sub(hand.position, fore.position), rot(hand.rotation, {1, 0, 0}))) <= cap + .1, "the drawn wrist bend")
                    if d.wrist_limited then capped[string.format("%d %.2f %d", b, steer, i)] = true end
                end
            end
        end
        check(capped["1 0.90 1"] and capped["1 -0.90 2"] and not capped["1 0.00 1"] and not capped["1 0.00 2"], "the outer wrist is capped on a hard turn, neither at 0")
        -- Without the cap the review's 91 degrees come back: the cap is what holds it.
        local loose = plan_of(input(BIKES[2], {crank_phase = 1, steer = .9}), {max_wrist_bend = PI})
        check(loose.diagnostics.limbs.left_arm.swing_degrees > 85 and loose.diagnostics.limbs.left_arm.wrist_limited == false)
    end)

    test("a held knee folds no tighter than min_knee, and the hips no lower than the seat floor", function()
        local bike = BIKES[2]
        local base = base_for(bike)
        local floor = MP.options().geometry.saddle.top + .5 * dist(MP.DEFAULT_RIG.roots.left_up_leg, MP.DEFAULT_RIG.roots.right_up_leg) + MP.STANCE.seat_clearance
        local limited = {}
        for _, crouch in {0, .04, .05, .1, .138, .2, .3} do
            limited[crouch] = 0
            for k = 0, 35 do
                local plan = plan_of(input(bike, {crank_phase = k * PI / 18}, {crouch = crouch}))
                for _, name in {"left_leg", "right_leg"} do
                    local d = plan.diagnostics.limbs[name]
                    check(d.interior_degrees >= deg(MP.STANCE.min_knee) - 1e-6, string.format("crouch %.3f phase %d %s: %.3f degrees", crouch, k, name, d.interior_degrees))
                    check(d.reaches, name .. " still reaches its pedal")
                end
                check(plan.diagnostics.hip_local[2] >= floor - 1e-9, "never below the seat floor")
                if plan.diagnostics.knee_limited then limited[crouch] += 1 end
                if k % 12 == 0 then
                    -- The emulated knee is the planned one.
                    local pose = posed(plan, 1, base)
                    for _, ids in {{341, 342, 343}, {8, 9, 10}} do
                        local u, m, t = world_of(pose, ids[1]).position, world_of(pose, ids[2]).position, world_of(pose, ids[3]).position
                        check(deg(angle_of(sub(u, m), sub(t, m))) >= deg(MP.STANCE.min_knee) - .05, "the drawn knee")
                    end
                end
            end
        end
        check(limited[0] == 0 and limited[.138] > 0 and limited[.3] > 0, "the knee floor holds a deep crouch, not the standing one")
        -- With min_knee lowered the review's 36.5 degrees at 0.138 m return.
        local lowest = 180
        for k = 0, 35 do
            local plan = plan_of(input(bike, {crank_phase = k * PI / 18}, {crouch = .138}), {min_knee = .35})
            lowest = math.min(lowest, plan.diagnostics.limbs.left_leg.interior_degrees, plan.diagnostics.limbs.right_leg.interior_degrees)
        end
        check(lowest < 40, string.format("without it the knee goes to %.1f degrees", lowest))
    end)

    test("validated options are frozen, and the poser checks its options on every use", function()
        local o = assert(MP.options({lean = .4}))
        check(table.isfrozen(o) and table.isfrozen(o.rig) and table.isfrozen(o.rig.lengths) and table.isfrozen(o.geometry.saddle))
        check(not pcall(function() o.lean = 5 end) and o.lean == .4, "a validated table cannot be changed")
        check(not pcall(function() o.rig.lengths.left_leg = 5 end))
        check(MP.options(o) == o, "it passes through as it is")
        local raw = {lean = .4}
        local checked = assert(MP.options(raw))
        raw.lean = 5
        check(checked.lean == .4 and MP.options(raw) == nil, "a raw table is checked each time")
        for _, gone in {"pin_hands", "pin_feet"} do
            local none, why = MP.options({[gone] = true})
            check(none == nil and string.find(why, "unknown option " .. gone, 1, true) ~= nil, "a hand or foot cannot be pinned")
        end
        local f = new_fake()
        local poser = Q.new(f.api, {lean = .4})
        local bike = BIKES[1]
        check(poser:mount(0).ok and poser:tick(0, input(bike, {crank_phase = 0})).sent)
        check(not pcall(function() poser.options.blend_in = 0 end), "the poser's own options are frozen")
        poser.options = {blend_in = 0}
        f.clock = 1 / 60
        local r = poser:tick(1 / 60, input(bike, {crank_phase = .1}))
        check(not r.ok and string.find(r.reason, "option blend_in", 1, true) ~= nil and r.ended == true and f.held_until == nil, tostring(r.reason))
        poser.options = {lean = .2}
        check(poser:mount(2 / 60).ok and poser:tick(2 / 60, input(bike, {crank_phase = .2})).sent, "replaced by good options it is checked and used")
        check(table.isfrozen(poser.options) and poser.options.lean == .2)
    end)

    test("the weight blends in on mount and out on dismount", function()
        local f = new_fake()
        local poser = Q.new(f.api)
        local bike = BIKES[2]
        local base = base_for(bike)
        local function frame() return input(bike, {crank_phase = f.clock * 6, steer = .1}) end
        local r = poser:mount(0)
        check(r.ok and r.state == "mounting" and r.weight == 0 and #f.accepted == 0, tostring(r.reason))
        local weights, last = {}, -1
        for k = 0, 20 do
            f.clock = k / 60
            r = poser:tick(f.clock, frame())
            check(r.ok and r.sent, tostring(r.reason))
            table.insert(weights, r.weight)
            check(r.weight >= last, "rising")
            last = r.weight
            if f.clock < .25 - 1e-9 then near(r.weight, MP.weight_of(f.clock / .25), 1e-9, "smoothstep of the blend") end
        end
        check(weights[1] == 0 and r.state == "mounted" and r.weight == 1, "in after blend_in")
        -- The emulated hands go from the animation's to the grips.
        local d = {}
        for _, w in {0, .5, 1} do
            local plan = plan_of(frame())
            d[w] = dist(palm(posed(plan, w, base), 1), plan.targets.grips[1])
        end
        check(d[0] > .1 and d[.5] < d[0] and d[1] < 2e-3 and d[.5] > d[1], string.format("%.3f %.3f %.4f", d[0], d[.5], d[1]))
        local sends = #f.accepted
        r = poser:dismount(1)
        check(r.ok and r.state == "dismounting")
        last = 2
        local ended_at, falling = nil, 0
        for k = 1, 20 do
            f.clock = 1 + k / 60
            r = poser:tick(f.clock, frame())
            check(r.ok, tostring(r.reason))
            if r.sent then
                check(r.weight < last, "falling") last = r.weight
                falling += 1
            elseif ended_at == nil then
                ended_at = f.clock
                check(r.ended == true and r.state == "off" and f.ends == 1 and f.held_until == nil, "ended with nil once")
            end
        end
        check(ended_at ~= nil and ended_at >= 1.2 - 1e-9 and ended_at <= 1.2 + 1 / 60 + 1e-9, "out after blend_out")
        local after = #f.accepted
        r = poser:tick(2, frame())
        check(r.ok and not r.sent and #f.accepted == after and f.ends == 1, "off sends nothing")
        -- blend_out 0.2 s at 60 Hz: twelve falling poses (a thirteenth if rounding leaves a sliver), then the end.
        check(falling >= 11 and falling <= 13 and after - sends == falling + 1, "falling poses, then one end: " .. falling)
        -- A remount part way out carries on from where it was.
        poser:mount(3) for k = 0, 9 do f.clock = 3 + k / 60 poser:tick(f.clock, frame()) end
        poser:dismount(f.clock)
        f.clock += 1 / 60
        local partial = poser:tick(f.clock, frame()).weight
        poser:mount(f.clock)
        f.clock += 1 / 60
        local resumed = poser:tick(f.clock, frame())
        check(resumed.weight > partial and resumed.weight < 1 and resumed.state == "mounting", "no pop on remount")
    end)

    test("the pose is sent again within the 0.3 s hold", function()
        local f = new_fake()
        local poser = Q.new(f.api)
        local bike = BIKES[1]
        poser:mount(0)
        local largest, previous = 0, nil
        for k = 0, 120 do
            f.clock = k / 60
            local r = poser:tick(f.clock, input(bike, {crank_phase = f.clock * 5}))
            check(r.sent and not r.lapsed)
            check(f.held_until ~= nil and f.held_until >= f.clock + .3 - 1e-9, "held past this tick")
            if previous then largest = math.max(largest, f.clock - previous) end
            previous = f.clock
        end
        check(largest <= 1 / 60 + 1e-9 and largest < MP.HOLD_SECONDS)
        f.clock = 2 + .35
        local slow = poser:tick(f.clock, input(bike, {crank_phase = 1}))
        check(slow.sent and slow.lapsed == true and slow.gap > .3, "a slower tick is reported as lapsed")
        -- A tick without a fresh bike transform can send the last pose again, as it was.
        local before = #f.accepted
        f.clock += .1
        local again = poser:refresh(f.clock)
        check(again.ok and again.sent and #f.accepted == before + 1 and again.weight == slow.weight)
        check(f.calls[#f.calls].poses == slow.plan.pose, "the same pose")
        f.clock += .25
        local stale = poser:refresh(f.clock)
        check(not stale.ok and string.find(stale.reason, "older than the 0.3 s hold", 1, true) ~= nil and f.ends == 1, "a stale pose is ended, not held")
        -- The plan a tick returns is the caller's to read; changed after it was sent, it is checked
        -- again before a refresh sends it. A finger (joint 50) is one skater.pose itself would take.
        for _, tamper in {function(pose) pose[50] = {place = {rotation = {0, 0, 0, 1}}} end,
            function(pose) pose[MP.JOINTS.right_hand].place.relative_to = "skater" end,
            function(pose) pose[MP.JOINTS.hips].place.position = vector.create(0 / 0, 0, 0) end} do
            local g2 = new_fake()
            local p2 = Q.new(g2.api)
            p2:mount(0)
            local sent = p2:tick(0, input(bike, {crank_phase = 0}))
            check(sent.sent and #g2.accepted == 1)
            tamper(sent.plan.pose)
            g2.clock = .05
            local resent = p2:refresh(.05)
            check(not resent.ok and not resent.sent and resent.ended == true and g2.held_until == nil and #g2.accepted == 2, tostring(resent.reason))
            check(g2.calls[#g2.calls].poses == nil, "the last call ended the pose")
            for _, record in g2.accepted do for _, o in record.offsets do check(o.joint ~= 50 and not (o.place and o.place.frame == "skater")) end end
        end
    end)

    test("refusals: missing API, older ReSkate, no permission", function()
        local bike = BIKES[1]
        for _, case in {{api = false, why = "no reskate API"}, {api = {}, why = "reskate.skater is missing"},
            {api = {skater = {}}, why = "reskate.skater.pose is missing"}, {api = {skater = {pose = 5}}, why = "reskate.skater.pose is missing"}} do
            local poser = Q.new(case.api or nil)
            local r = poser:mount(0)
            check(not r.ok and r.state == "refused" and string.find(r.reason, case.why, 1, true) ~= nil, tostring(r.reason))
            check(not poser:tick(0, input(bike, {crank_phase = 0})).sent)
        end
        local old = new_fake({mode = "old"})
        local poser = Q.new(old.api)
        local r = poser:mount(0)
        check(not r.ok and string.find(r.reason, "older than PR #365", 1, true) ~= nil, tostring(r.reason))
        check(#old.accepted == 0 and not poser:tick(0, input(bike, {crank_phase = 0})).sent and #old.accepted == 0, "nothing reaches an older skater.pose")
        check(not poser:mount(1).ok, "and it stays refused")
        local locked = new_fake({permission = false})
        r = Q.new(locked.api):mount(0)
        check(not r.ok and string.find(r.reason, "skater.animation", 1, true) ~= nil and #locked.accepted == 0)
        -- Something that accepts any weight is not trusted, and whatever it held is ended.
        local loose = {calls = 0, ends = 0}
        loose.api = {skater = {pose = function(p) loose.calls += 1 if p == nil then loose.ends += 1 end return true end}}
        r = Q.new(loose.api):mount(0)
        check(not r.ok and string.find(r.reason, "weight of 2", 1, true) ~= nil and loose.ends == 1)
    end)

    test("refusals: inputs that are not finite or not known", function()
        local bike = BIKES[2]
        local good = input(bike, {crank_phase = 1})
        local nan, inf = 0 / 0, math.huge
        local bad = {
            {i = input({root = {nan, 0, 0}, rotation = {0, 0, 0, 1}}, {crank_phase = 0}), why = "position"},
            {i = input({root = {0, 0, 0}, rotation = {0, inf, 0, 1}}, {crank_phase = 0}), why = "rotation"},
            {i = input({root = {0, 0, 0}, rotation = {0, 0, 0, 2}}, {crank_phase = 0}), why = "rotation"},
            {i = input({root = {0, 0, 0}, center_of_mass = {0, 0, 0}, rotation = {0, 0, 0, 1}}, {crank_phase = 0}), why = "exactly one"},
            {i = input({rotation = {0, 0, 0, 1}}, {crank_phase = 0}), why = "exactly one"},
            {i = input({root = {99001, 0, 0}, rotation = {0, 0, 0, 1}}, {crank_phase = 0}), why = "99 km"},
            {i = input(bike, {crank_phase = nan}), why = "crank_phase"},
            {i = input(bike, {steer = .1}), why = "crank_phase"},
            {i = input(bike, nil), why = "crank_phase"},
            {i = input(bike, {crank_phase = 0, steer = 1.5}), why = "steer"},
            {i = input(bike, {crank_phase = 0, wheelie = 1}), why = "unknown articulation"},
            {i = input(bike, {crank_phase = 0, release_left_hand = 1.5}), why = "release_left_hand is 0 to 1"},
            {i = input(bike, {crank_phase = 0, barspin_release = -.1}), why = "barspin_release is 0 to 1"},
            {i = input(bike, {crank_phase = 0, tailwhip_release = nan}), why = "tailwhip_release"},
            {i = input(bike, {crank_phase = 0}, {crouch = -.1}), why = "crouch"},
            {i = input(bike, {crank_phase = 0}, {crouch = nan}), why = "crouch"},
            {i = input(bike, {crank_phase = 0}, {hip_offset = {0, inf, 0}}), why = "hip_offset"},
            {i = input(bike, {crank_phase = 0}, {tilt = 1}), why = "unknown rider"},
            {i = {bike = bike, articulation = {crank_phase = 0}, weather = 1}, why = "unknown input"},
            {i = {bike = bike, articulation = {crank_phase = 0}, skater_root = add(bike.root, {4.5, 0, 0})}, why = "4 m"},
        }
        for n, case in bad do
            local plan, why = Q.compose(case.i)
            check(plan == nil and type(why) == "string" and string.find(why, case.why, 1, true) ~= nil, n .. ": " .. tostring(why))
        end
        check(Q.compose({bike = bike, articulation = {crank_phase = 0}, skater_root = add(bike.root, {.4, .9, -.6})}) ~= nil, "a skater nearby is fine")
        check(Q.compose(input({root = {98999, 0, 0}, rotation = {0, 0, 0, 1}}, {crank_phase = 0})) ~= nil, "within 99 km is fine")
        -- Unknown joints and options are refused before anything is sent.
        local f = new_fake()
        for _, o in {{rig = {lengths = {left_tail = .3}}}, {rig = {roots = {left_hand = {0, 0, 0}}}}, {grip = 1},
            {lean = 2}, {shown = "nobody"}, {pin_shoulders = 1}, {pin_hands = true}, {elbow_pole = {0, 0, 0}}, {rig = {foot_slope = inf}},
            {min_knee = 0}, {max_wrist_bend = 0}, {hold_ramp = 0}, {barspin_hold = 4}} do
            local poser = Q.new(f.api, o)
            local r = poser:mount(0)
            check(not r.ok and r.state == "refused" and type(r.reason) == "string", tostring(r.reason))
        end
        check(#f.calls == 0, "no call was made for a bad option")
        check(string.find(select(2, MP.options({rig = {lengths = {left_tail = .3}}})), "unknown joint left_tail", 1, true) ~= nil)
        local ok, why = MP.validate_pose({[50] = {place = {rotation = {0, 0, 0, 1}}}})
        check(not ok and string.find(why, "unknown joint 50", 1, true) ~= nil, "a finger is not this module's joint")
        ok, why = MP.validate_pose({[900] = {place = {rotation = {0, 0, 0, 1}}}})
        check(not ok and string.find(why, "2 to 394", 1, true) ~= nil)
        ok = MP.validate_pose({hips = {place = {rotation = {0, 0, 0, 1}}}})
        check(not ok, "joints by number only")
        local many = {}
        for j = 2, 130 do many[j] = {place = {rotation = {0, 0, 0, 1}}} end
        ok, why = MP.validate_pose(many)
        check(not ok and string.find(why, "128", 1, true) ~= nil)
        ok, why = MP.validate_pose({[7] = {place = {rotation = {0, 0, 0, 1}, relative_to = "skater"}}})
        check(not ok and string.find(why, "relative to skater", 1, true) ~= nil)
        ok, why = MP.validate_pose({[7] = {place = {position = {0, 0, 0}}}})
        check(not ok and string.find(why, "vector", 1, true) ~= nil)
        -- Only the hips' own frame, and never for the hips themselves.
        check(MP.validate_pose({[47] = {place = {rotation = {0, 0, 0, 1}, relative_to = 7}}}), "an upper arm in the hips' frame")
        ok, why = MP.validate_pose({[7] = {place = {rotation = {0, 0, 0, 1}, relative_to = 7}}})
        check(not ok and string.find(why, "relative to 7", 1, true) ~= nil, "the hips relative to themselves")
        ok = MP.validate_pose({[49] = {place = {rotation = {0, 0, 0, 1}, relative_to = 278}}})
        check(not ok, "relative to another hand")
        -- Mid-ride: a bad frame ends the pose instead of leaving it held where it was.
        local poser = Q.new(f.api)
        poser:mount(0)
        f.clock = 0
        check(poser:tick(0, good).sent and f.held_until ~= nil)
        local r = poser:tick(1 / 60, input(bike, {crank_phase = nan}))
        check(not r.ok and r.ended == true and f.held_until == nil and r.state == "refused", tostring(r.reason))
        check(not poser:tick(2 / 60, good).sent, "refused until mounted again")
        check(poser:mount(3 / 60).ok and poser:tick(3 / 60, good).sent, "a new mount starts again")
        r = poser:tick(2 / 60, good)
        check(not r.ok and r.reason == "time went backwards" and f.held_until == nil)
    end)

    test("refusals: skater.pose refusing or raising", function()
        local bike = BIKES[1]
        local f = new_fake()
        local poser = Q.new(f.api)
        check(poser:mount(0).ok)
        check(poser:tick(0, input(bike, {crank_phase = 0})).sent)
        f.refuse = "unavailable"
        local r = poser:tick(1 / 60, input(bike, {crank_phase = .1}))
        check(not r.ok and string.find(r.reason, "skater.pose refused: unavailable", 1, true) ~= nil and r.state == "refused", tostring(r.reason))
        check(f.calls[#f.calls].poses == nil, "it tried to end what it had sent")
        f.refuse = nil
        check(poser:mount(2 / 60).ok and poser:tick(2 / 60, input(bike, {crank_phase = .2})).sent, "it recovers on a new mount")
        local raising = {api = {skater = {pose = function(p, w)
            if w == MP.PROBE_WEIGHT then error("a joint's place has a position, a rotation or both", 0) end
            error("the game is not ready", 0)
        end}}}
        poser = Q.new(raising.api)
        check(poser:mount(0).ok)
        r = poser:tick(0, input(bike, {crank_phase = 0}))
        check(not r.ok and string.find(r.reason, "raised: the game is not ready", 1, true) ~= nil, tostring(r.reason))
    end)

    test("the production module is gated and calls nothing", function()
        check(MP.QUALIFIED == false and Q.QUALIFIED == true, "only the test copy is qualified")
        local f = new_fake()
        local api, touched, others = trapped(f)
        local poser = MP.new(api)
        local i = input(BIKES[2], {crank_phase = 0})
        for _, r in {poser:mount(0), poser:tick(0, i), poser:refresh(0), poser:dismount(1), poser:tick(1, i), poser:stop()} do
            check(r.sent == false and r.reason == MP.NOT_QUALIFIED, tostring(r.reason))
        end
        check(#touched == 0 and #others == 0 and #f.calls == 0, "not even the API's table was read")
        check(poser:status().qualified == false)
        -- The pure plan is the same code in both.
        local a, b = MP.compose(i), Q.compose(i)
        for id, e in a.pose do
            local o = b.pose[id]
            check(o and o.place.position == e.place.position and o.place.relative_to == e.place.relative_to, "joint " .. id)
            if e.place.rotation then for k = 1, 4 do check(o.place.rotation[k] == e.place.rotation[k]) end end
        end
    end)

    test("only skater.pose is ever called", function()
        local f = new_fake()
        local api, touched, others = trapped(f)
        local poser = Q.new(api)
        local bike = BIKES[3]
        poser:mount(0)
        for k = 0, 30 do f.clock = k / 60 poser:tick(f.clock, input(bike, {crank_phase = k / 10})) end
        poser:refresh(f.clock + .01)
        poser:dismount(f.clock + .01)
        for k = 1, 20 do poser:tick(f.clock + .01 + k / 60, input(bike, {crank_phase = 3})) end
        poser:mount(2) poser:tick(2, input(bike, {crank_phase = 3})) poser:stop()
        check(#others == 0, "no other reskate function was called")
        for _, key in touched do check(key == "skater" or key == "skater.pose", "read " .. key) end
        check(#touched > 0 and f.ends == 2 and #f.accepted > 40)
        local _, plan = pcall(Q.compose, input(bike, {crank_phase = 0}))
        check(type(plan) == "table", "compose needs no API at all")
    end)

    return {cases = cases, assertions = assertions, native_calls = 0, game_evidence = false}
end

return {run = run}

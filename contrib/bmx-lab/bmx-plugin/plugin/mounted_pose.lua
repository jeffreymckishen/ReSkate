-- The rider's mounted posture: each tick, the reskate.skater.pose table that sets the rider's own
-- joints (the joint places of ReSkate PR #365, upstream 8fe5d019) so that both hands hold the grips,
-- both feet stand on the pedals as the cranks turn, and the pelvis rides over the saddle, leaning
-- toward the bars and turning a little with them. Pure maths and one call, skater.pose: nothing else
-- of the reskate API is touched, and nothing runs on require.
--
-- Coordinates: authored bike +Y up, +Z forward, +X rider-left (bike_geometry.lua, bike_visual.lua);
-- Hamilton quaternions {x, y, z, w}; metres and radians.
--
-- The joints' own axes are not guessed. They were measured from the r3 alignment capture
-- (build/bmx/alignment-actual-v3/storage-after-stop.json, observations.joints: 14 joints read with
-- skater.joint while the default skater stood still on MPR): every arm and leg joint points at its
-- child along its own +X, an elbow or knee bends about the +Z it shares with the joint above it
-- (positive angles fold it), and the hips have +X up the spine, +Y forward and +Z to the rider's
-- left. mounted_pose_tests.lua checks each of these against those rows. A pose is a request: it
-- proves nothing about how the game draws it (DESIGN.md says what only the game can show).
--
-- skater.pose blends every joint's value in its parent's frame by the weight (pose_place.cpp
-- apply). A joint given a position is therefore pulled off the end of a parent that is itself only
-- part blended, so no hand, foot, elbow or knee is ever given a position here: each limb is a chain
-- of turns from a shoulder or hip socket, and at weight 1 the chain itself ends on the grip or pedal.
-- The one position below the hips, a pinned shoulder, is set in the hips' own frame, so during a
-- blend it moves only by the stance's difference from the animation's shoulder (about 3 cm).
--
-- MOUNTED_POSE_QUALIFIED stays false until the pose has been seen in the game. Until then a Poser
-- refuses and calls nothing; MP.compose (pure) works either way.
local MOUNTED_POSE_QUALIFIED = false
local G0 = require("./bike_geometry")
local Bones = require("./bones")

local MP = {}
MP.QUALIFIED = MOUNTED_POSE_QUALIFIED
MP.MAX_JOINTS = 128 -- plugin_api_world.cpp skater_pose since PR #365 (was 64)
MP.HOLD_SECONDS = .3 -- a pose holds 0.3 s, so it is sent again every tick
MP.SENT_JOINT_LIMIT = 4 -- upstream 3d706383: others are sent no joint further than 4 m from its parent
MP.POSITION_LIMIT = 1e5 -- position_of: a finite position within 100 km
MP.NOT_QUALIFIED = "the mounted pose is not qualified for the game (MOUNTED_POSE_QUALIFIED=false): nothing was sent"
-- A place without a position or a rotation: PR #365's skater.pose refuses it while reading the joints,
-- before it looks at the weight; an older skater.pose reads no place and refuses the weight of 2.
-- Either way nothing is posed. See MP.classify_probe.
MP.PROBE_JOINT = 49
MP.PROBE_WEIGHT = 2

local PI = math.pi
local EPS = 1e-9

------------------------------------------------------------------- maths
local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
-- {x, y, z} or a Luau vector, finite and within `bound` on each axis; a fresh array or nil.
local function vec3(v, bound)
    local x, y, z
    if type(v) == "vector" then
        x, y, z = v.x, v.y, v.z
    elseif type(v) == "table" then
        x, y, z = v[1], v[2], v[3]
    else
        return nil
    end
    bound = bound or 1e6
    if not (finite(x) and finite(y) and finite(z)) or math.abs(x) > bound or math.abs(y) > bound or math.abs(z) > bound then
        return nil
    end
    return {x, y, z}
end
local function add(a, b) return {a[1] + b[1], a[2] + b[2], a[3] + b[3]} end
local function sub(a, b) return {a[1] - b[1], a[2] - b[2], a[3] - b[3]} end
local function mul(a, k) return {a[1] * k, a[2] * k, a[3] * k} end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function cross(a, b) return {a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1]} end
local function length(a) return math.sqrt(dot(a, a)) end
local function unit(a)
    local n = length(a)
    if not finite(n) or n < EPS then return nil end
    return mul(a, 1 / n)
end
local function lerp(a, b, t) return add(a, mul(sub(b, a), t)) end
local function clamp(x, low, high) return math.max(low, math.min(high, x)) end
local function smooth(t) return t * t * (3 - 2 * t) end
local function normalized(q)
    local n = math.sqrt(q[1] * q[1] + q[2] * q[2] + q[3] * q[3] + q[4] * q[4])
    return {q[1] / n, q[2] / n, q[3] / n, q[4] / n}
end
-- A unit quaternion within `tolerance` of length 1 (squared), normalized; nil otherwise.
local function quat(q, tolerance)
    if type(q) ~= "table" then return nil end
    local n = 0
    for i = 1, 4 do
        if not finite(q[i]) then return nil end
        n += q[i] * q[i]
    end
    if math.abs(n - 1) > (tolerance or .001) then return nil end
    return normalized(q)
end
local function multiply(a, b)
    return {a[4] * b[1] + a[1] * b[4] + a[2] * b[3] - a[3] * b[2],
        a[4] * b[2] - a[1] * b[3] + a[2] * b[4] + a[3] * b[1],
        a[4] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[4],
        a[4] * b[4] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3]}
end
local function conjugate(q) return {-q[1], -q[2], -q[3], q[4]} end
local function turn(q, p)
    local u = {q[1], q[2], q[3]}
    local t = mul(cross(u, p), 2)
    return add(p, add(mul(t, q[4]), cross(u, t)))
end
local function axis_angle(n, angle)
    local s = math.sin(angle * .5)
    return {n[1] * s, n[2] * s, n[3] * s, math.cos(angle * .5)}
end
-- The shorter way from a to b, t of it.
local function slerp(a, b, t)
    local c = a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4]
    if c < 0 then b, c = {-b[1], -b[2], -b[3], -b[4]}, -c end
    if c > .9995 then
        return normalized({a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, a[4] + (b[4] - a[4]) * t})
    end
    local angle = math.acos(math.min(1, c))
    local s = math.sin(angle)
    local wa, wb = math.sin((1 - t) * angle) / s, math.sin(t * angle) / s
    return normalized({a[1] * wa + b[1] * wb, a[2] * wa + b[2] * wb, a[3] * wa + b[3] * wb, a[4] * wa + b[4] * wb})
end
-- The rotation whose own +X, +Y and +Z are x, y and z (orthonormal, right-handed).
local function from_axes(x, y, z)
    local t = x[1] + y[2] + z[3]
    local q
    if t > 0 then
        local s = math.sqrt(t + 1) * 2
        q = {(y[3] - z[2]) / s, (z[1] - x[3]) / s, (x[2] - y[1]) / s, .25 * s}
    elseif x[1] > y[2] and x[1] > z[3] then
        local s = math.sqrt(1 + x[1] - y[2] - z[3]) * 2
        q = {.25 * s, (x[2] + y[1]) / s, (x[3] + z[1]) / s, (y[3] - z[2]) / s}
    elseif y[2] > z[3] then
        local s = math.sqrt(1 + y[2] - x[1] - z[3]) * 2
        q = {(x[2] + y[1]) / s, .25 * s, (y[3] + z[2]) / s, (z[1] - x[3]) / s}
    else
        local s = math.sqrt(1 + z[3] - x[1] - y[2]) * 2
        q = {(x[3] + z[1]) / s, (y[3] + z[2]) / s, .25 * s, (x[2] - y[1]) / s}
    end
    return normalized(q)
end
local function wrap(angle) return angle - 2 * PI * math.floor((angle + PI) / (2 * PI)) end
local function degrees(radians) return radians * 180 / PI end
local function freeze(t)
    for _, v in t do if type(v) == "table" and not table.isfrozen(v) then freeze(v) end end
    return table.freeze(t)
end
MP.math = freeze({turn = turn, multiply = multiply, conjugate = conjugate, axis_angle = axis_angle,
    from_axes = from_axes, wrap = wrap, slerp = slerp})

------------------------------------------------------------------- joints
-- Names and ids from bones.lua (Extension/Skater/skater_skeleton.h and plugin_api_world.cpp), with
-- the parent each chain below needs. A bones.lua that disagrees refuses every pose.
local NEEDED = {
    hips = 1, right_arm = 46, right_fore_arm = "right_arm", right_hand = "right_fore_arm",
    left_arm = 275, left_fore_arm = "left_arm", left_hand = "left_fore_arm",
    right_up_leg = "hips", right_leg = "right_up_leg", right_foot = "right_leg",
    left_up_leg = "hips", left_leg = "left_up_leg", left_foot = "left_leg",
}
local function joint_map()
    if type(Bones) ~= "table" then return nil, "bones.lua did not return its rows" end
    local by = {}
    for _, row in ipairs(Bones) do
        if type(row) == "table" and type(row.name) == "string" then
            if by[row.name] then return nil, "bones.lua names " .. row.name .. " twice" end
            by[row.name] = row
        end
    end
    local ids = {}
    for name, parent in NEEDED do
        local row = by[name]
        if not row then return nil, "bones.lua has no " .. name end
        if type(row.id) ~= "number" or row.id ~= math.floor(row.id) or row.id < 2 or row.id > 394 then
            return nil, "bones.lua gives " .. name .. " an id that cannot be posed"
        end
        ids[name] = row.id
    end
    for name, parent in NEEDED do
        local want = type(parent) == "string" and ids[parent] or parent
        if by[name].parent ~= want then
            return nil, "bones.lua gives " .. name .. " parent " .. tostring(by[name].parent) .. ", not " .. tostring(want)
        end
    end
    -- Not in bones.lua: the head, one of skater.pose's own names (plugin_api_world.cpp joint_of).
    ids.head = 103
    return ids
end
local JOINTS, JOINT_ISSUE = joint_map()
MP.JOINTS = JOINTS and freeze(JOINTS) or freeze({})
MP.JOINT_ISSUE = JOINT_ISSUE
local KNOWN_IDS = {}
for name, id in MP.JOINTS do KNOWN_IDS[id] = name end

-- side: +1 the rider's left (+X), -1 the right. The order is the order of every per-limb list below.
local LIMBS = freeze({
    {name = "left_arm", side = 1, arm = true, upper = "left_arm", middle = "left_fore_arm", tip = "left_hand"},
    {name = "right_arm", side = -1, arm = true, upper = "right_arm", middle = "right_fore_arm", tip = "right_hand"},
    {name = "left_leg", side = 1, arm = false, upper = "left_up_leg", middle = "left_leg", tip = "left_foot"},
    {name = "right_leg", side = -1, arm = false, upper = "right_up_leg", middle = "right_leg", tip = "right_foot"},
})
MP.LIMBS = LIMBS

------------------------------------------------------------------- measured rig
-- From the r3 capture rows (see the header). Lengths are the distance from each joint to its child,
-- which lies on the joint's own +X. Roots are where a limb starts in the hips' own frame. The
-- shoulders are the mean of the two sides, mirrored: the standing capture leaned a little, which is
-- not a riding stance. The foot slope is the mean of both feet (29.1 and 30.0 degrees): with the sole
-- flat, the foot's +X (ankle toward the ball) points that far below level.
MP.DEFAULT_RIG = freeze({
    source = "alignment-actual-v3 storage-after-stop.json observations.joints (MPR, state 504, standing still)",
    lengths = {left_arm = .295098, left_fore_arm = .273530, right_arm = .295377, right_fore_arm = .273984,
        left_up_leg = .408563, left_leg = .438445, right_up_leg = .408592, right_leg = .438451},
    roots = {left_up_leg = {-.000026, -.001967, .086468}, right_up_leg = {-.000071, -.001354, -.088229},
        left_arm = {.521470, .018800, .172796}, right_arm = {.521470, .018800, -.172796}},
    foot_slope = .515999,
})
-- The hips' rest frame in bike space: their +X up, +Y forward, +Z left (bmx_rider_pose.h uses the
-- same {.5, .5, .5, .5}; the capture's hips are within 7 degrees of it).
local HIPS_REST = {.5, .5, .5, .5}
MP.HIPS_REST = freeze(table.clone(HIPS_REST))

------------------------------------------------------------------- authored stance and contacts
-- Stance: Extension/BMX/bmx_rider_pose.h small_bike_stance (authored, not recovered BMX values),
-- with the lean and the bars-follow share this module adds. Contacts: Engine/Game/BMX/bmx_geometry.h,
-- the same fitted anchors and 0.7737670588235294 scale as bike_geometry.lua, which does not carry
-- the grip axes, the pedal faces, the ankle height or the seat top.
local S = G0.scale
MP.STANCE = freeze({
    hip_height = .9578988338, hip_z = -.2877711058,
    lean = .55, follow_bars = .35, crouch = 0,
    elbow_pole = {.12, -1.70, -.05}, -- left arm; mirrored for the right: down, a little out and back
    knee_pole = {0, 0, 1}, wrist_slope = .30, forearm_twist_share = .5,
    seat_clearance = .03, max_fit = .15, foot_fore_aft = 0,
    -- bmx_rider_pose.h rejects a knee at or under 50 degrees (and from 176 straight).
    min_knee = 50 * PI / 180,
    -- rider_alignment.lua's maximum_tip_rotation: no hand turns further than this off its forearm.
    max_wrist_bend = .8,
    -- A hand holds a spinning bar, and a foot a whipping pedal, only this far from where they were;
    -- over the next hold_ramp it lets go (see contacts).
    barspin_hold = .3, tailwhip_hold = .1, hold_ramp = .3,
})
MP.CONTACTS = freeze({
    grip_outward = {left = {.9426919343452176, .11310901153299041, -.31390805728828},
        right = {-.9426919147801553, .11310899923644252, -.31390812047453476}},
    grip_radius = .0164 * S,
    -- From the wrist joint to the palm on the tube: toward the knuckles, and the tube radius plus
    -- 4 mm to the palm's side (+Z for the left hand, -Z for the right).
    palm_reach = .055, palm_gap = .004,
    -- The broad upper face of each pedal, which moves with its spindle and stays level.
    pedal_face = {left = {.139242193856 * S, .220121163795 * S, .011273203601 * S},
        right = {-.139242212706 * S, .599275463263 * S, -.284814700726 * S}},
    pedal_spindle = {left = {.084980725506 * S, .211285091841 * S, .011246842761 * S},
        right = {-.084980725506 * S, .590551321670 * S, -.284787818885 * S}},
    ankle_from_sole = .09, -- a native-rig ankle proxy, not a shoe measurement
    seat_top = .702625573, -- measured from the supplied seat mesh (bmx_rider_pose.h)
    -- Where a released hand or foot goes, bmx_rider_pose.h palm_target and foot_target (the same
    -- numbers rider_alignment.lua uses): a hand 8 cm out, 12 cm up and 8 cm back from its grip with
    -- the bars unspun; a foot parked off the pedals, its knee folded toward the rider.
    hand_free = {.08, .12, -.08},
    foot_free = {x = .2792422, above_bottom_bracket = .43, behind_bottom_bracket = .08},
})

------------------------------------------------------------------- inputs
local function geometry_of(g)
    g = g == nil and G0 or g
    if type(g) ~= "table" then return nil, "the geometry is not a table" end
    local out = {}
    for _, k in {"com", "left_grip", "right_grip", "steering_pivot", "bottom_bracket"} do
        out[k] = vec3(g[k], 3)
        if not out[k] then return nil, "the geometry's " .. k .. " is not a finite point" end
    end
    out.steering_axis = vec3(g.steering_axis, 2)
    out.steering_axis = out.steering_axis and unit(out.steering_axis)
    if not out.steering_axis then return nil, "the geometry's steering_axis is not a direction" end
    if type(g.pedals) ~= "table" then return nil, "the geometry has no pedals" end
    out.pedals = {vec3(g.pedals[1], 3), vec3(g.pedals[2], 3)}
    if not out.pedals[1] or not out.pedals[2] then return nil, "the geometry's pedal spindles are not finite points" end
    -- The saddle: capsule 5 of the collision envelope (wheels, frame, bars, saddle, then the seated
    -- rider), for its midline and fore-aft span; its top is the measured seat mesh's.
    local saddle = g.saddle
    if saddle == nil then
        local c = type(g.capsules) == "table" and g.capsules[5]
        local a, b = c and vec3(c.a, 3), c and vec3(c.b, 3)
        if not a or not b or not finite(c.radius) or c.radius <= 0 or a[1] ~= 0 or b[1] ~= 0 then
            return nil, "the geometry has no saddle capsule"
        end
        saddle = {top = MP.CONTACTS.seat_top, rear = math.min(a[3], b[3]) - c.radius,
            front = math.max(a[3], b[3]) + c.radius, half_width = c.radius}
    elseif type(saddle) ~= "table" or not finite(saddle.top) or not finite(saddle.rear) or not finite(saddle.front) or
        not finite(saddle.half_width) or saddle.rear >= saddle.front or saddle.half_width < 0 or saddle.half_width > .3 then
        return nil, "the geometry's saddle is {top, rear, front, half_width}"
    end
    out.saddle = {top = saddle.top, rear = saddle.rear, front = saddle.front, half_width = saddle.half_width}
    -- The pedal faces sit on the contacts' spindles; follow this geometry's spindles with the same offsets.
    local C = MP.CONTACTS
    out.pedal_offset = {sub(C.pedal_face.left, C.pedal_spindle.left), sub(C.pedal_face.right, C.pedal_spindle.right)}
    out.grip_outward = {unit(C.grip_outward.left), unit(C.grip_outward.right)}
    return out
end

local RIG_ROOTS = {left_arm = true, right_arm = true, left_up_leg = true, right_up_leg = true}
local function rig_of(o)
    local base = MP.DEFAULT_RIG
    local rig = {lengths = table.clone(base.lengths), roots = {}, foot_slope = base.foot_slope}
    for name, v in base.roots do rig.roots[name] = table.clone(v) end
    if o == nil then return rig end
    if type(o) ~= "table" then return nil, "the rig is not a table" end
    for k in o do
        if k ~= "lengths" and k ~= "roots" and k ~= "foot_slope" then return nil, "unknown rig field " .. tostring(k) end
    end
    if o.lengths ~= nil then
        if type(o.lengths) ~= "table" then return nil, "the rig's lengths is not a table" end
        for name, value in o.lengths do
            if rig.lengths[name] == nil then return nil, "unknown joint " .. tostring(name) .. " in the rig's lengths" end
            if not finite(value) or value < .04 or value > 1 then return nil, "the rig's " .. name .. " length is 0.04 to 1 m" end
            rig.lengths[name] = value
        end
    end
    if o.roots ~= nil then
        if type(o.roots) ~= "table" then return nil, "the rig's roots is not a table" end
        for name, value in o.roots do
            if not RIG_ROOTS[name] then return nil, "unknown joint " .. tostring(name) .. " in the rig's roots" end
            local v = vec3(value, .8)
            if not v then return nil, "the rig's " .. name .. " root is a finite point within 0.8 m of the hips" end
            rig.roots[name] = v
        end
    end
    if o.foot_slope ~= nil then
        if not finite(o.foot_slope) or o.foot_slope < 0 or o.foot_slope > 1.2 then return nil, "the rig's foot_slope is 0 to 1.2 radians" end
        rig.foot_slope = o.foot_slope
    end
    return rig
end

local OPTION_FIELDS = {lean = true, crouch = true, follow_bars = true, forearm_twist_share = true, wrist_slope = true,
    foot_fore_aft = true, pin_shoulders = true, elbow_pole = true, knee_pole = true, seat_clearance = true,
    max_fit = true, min_knee = true, max_wrist_bend = true, barspin_hold = true, tailwhip_hold = true, hold_ramp = true,
    rig = true, geometry = true, head = true, shown = true, blend_in = true, blend_out = true}
local NUMBER_OPTIONS = {lean = {0, 1.2}, crouch = {0, .3}, follow_bars = {0, 1}, forearm_twist_share = {0, 1},
    wrist_slope = {0, .8}, foot_fore_aft = {-.15, .15}, seat_clearance = {0, .2}, max_fit = {0, .3},
    min_knee = {.35, 1.6}, max_wrist_bend = {.2, PI}, barspin_hold = {0, PI}, tailwhip_hold = {0, PI},
    hold_ramp = {.05, 1}, blend_in = {.01, 5}, blend_out = {.01, 5}}
local SHOWN = {everyone = true, others = true, me = true}
-- The tables MP.options made. They are frozen, so a validated table cannot change after its checks
-- and passes through again as it is; anything else is checked.
local VALIDATED = setmetatable({}, {__mode = "k"})
-- Validated options with their defaults, or nil and why.
function MP.options(o)
    if VALIDATED[o] and table.isfrozen(o) then return o end
    o = o == nil and {} or o
    if type(o) ~= "table" then return nil, "the options are not a table" end
    for k in o do if not OPTION_FIELDS[k] then return nil, "unknown option " .. tostring(k) end end
    local out = {}
    local St = MP.STANCE
    for k, range in NUMBER_OPTIONS do
        local x = o[k]
        if x == nil then x = St[k] end
        if x == nil then x = k == "blend_in" and .25 or .2 end -- blend_in, blend_out
        if not finite(x) or x < range[1] or x > range[2] then
            return nil, "option " .. k .. " is " .. range[1] .. " to " .. range[2]
        end
        out[k] = x
    end
    if o.pin_shoulders ~= nil and type(o.pin_shoulders) ~= "boolean" then return nil, "option pin_shoulders is true or false" end
    out.pin_shoulders = o.pin_shoulders ~= false
    out.elbow_pole = o.elbow_pole == nil and table.clone(St.elbow_pole) or vec3(o.elbow_pole, 10)
    out.knee_pole = o.knee_pole == nil and table.clone(St.knee_pole) or vec3(o.knee_pole, 10)
    if not out.elbow_pole or not unit(out.elbow_pole) then return nil, "option elbow_pole is a direction" end
    if not out.knee_pole or not unit(out.knee_pole) then return nil, "option knee_pole is a direction" end
    local why
    out.rig, why = rig_of(o.rig)
    if not out.rig then return nil, why end
    out.geometry, why = geometry_of(o.geometry)
    if not out.geometry then return nil, why end
    out.shown = o.shown == nil and "everyone" or o.shown
    if not SHOWN[out.shown] then return nil, "option shown is \"everyone\", \"others\" or \"me\"" end
    if o.head ~= nil then
        local h = o.head
        if type(h) ~= "table" then return nil, "option head is {rotation, follow}" end
        for k in h do if k ~= "rotation" and k ~= "follow" then return nil, "unknown head field " .. tostring(k) end end
        -- The head's own axes were not in the capture, so only a rotation calibrated in the rider's
        -- frame (MP.rider_rotation from a standing read) can aim it.
        local q = quat(h.rotation)
        if not q then return nil, "the head needs its calibrated rotation in the rider's frame {x, y, z, w}" end
        local follow = h.follow == nil and .5 or h.follow
        if not finite(follow) or follow < 0 or follow > 1 then return nil, "the head's follow is 0 to 1" end
        out.head = {rotation = q, follow = follow}
    end
    freeze(out)
    VALIDATED[out] = true
    return out
end

local ARTICULATION = {steer = .9, crank_phase = 1e6, barspin = 8 * PI, tailwhip = 8 * PI,
    movement_bike_pitch = 4 * PI, movement_bike_roll = 4 * PI}
-- How far each hand or foot is let go, 0 to 1: trick_runtime.lua's visual_targets give the four
-- per-limb releases, and bmx_rider_pose.h's frame adds one for each spin channel.
local RELEASES = {"barspin_release", "tailwhip_release", "release_left_hand", "release_right_hand",
    "release_left_foot", "release_right_foot"}
local function articulation_of(a)
    if type(a) ~= "table" then return nil, "no articulation: crank_phase is needed" end
    local known = {}
    for _, k in RELEASES do known[k] = true end
    for k in a do if ARTICULATION[k] == nil and not known[k] then return nil, "unknown articulation field " .. tostring(k) end end
    if a.crank_phase == nil then return nil, "the articulation has no crank_phase" end
    local out = {}
    for k, cap in ARTICULATION do
        local x = a[k]
        if x == nil then x = 0 end
        if not finite(x) or math.abs(x) > cap then return nil, "articulation " .. k .. " is not a finite angle within " .. cap end
        out[k] = x
    end
    for _, k in RELEASES do
        local x = a[k]
        if x == nil then x = 0 end
        if not finite(x) or x < 0 or x > 1 then return nil, "articulation " .. k .. " is 0 to 1" end
        out[k] = x
    end
    return out
end

local function rider_of(r, o)
    if r == nil then r = {} end
    if type(r) ~= "table" then return nil, "rider is not a table" end
    for k in r do
        if k ~= "crouch" and k ~= "lean" and k ~= "hip_offset" then return nil, "unknown rider field " .. tostring(k) end
    end
    local crouch = r.crouch == nil and o.crouch or r.crouch
    if not finite(crouch) or crouch < 0 or crouch > .3 then return nil, "the rider's crouch is 0 to 0.3 m" end
    local lean = r.lean == nil and o.lean or r.lean
    if not finite(lean) or lean < 0 or lean > 1.2 then return nil, "the rider's lean is 0 to 1.2 radians" end
    local hip = r.hip_offset == nil and {0, 0, 0} or vec3(r.hip_offset, .5)
    if not hip then return nil, "the rider's hip_offset is a finite offset within 0.5 m on each axis" end
    return {crouch = crouch, lean = lean, hip_offset = hip}
end

local function bike_of(bike, g)
    if type(bike) ~= "table" then return nil, "no bike transform" end
    for k in bike do
        if k ~= "root" and k ~= "center_of_mass" and k ~= "rotation" then return nil, "unknown bike field " .. tostring(k) end
    end
    local q = quat(bike.rotation)
    if not q then return nil, "the bike's rotation is not a finite unit quaternion {x, y, z, w}" end
    if (bike.root == nil) == (bike.center_of_mass == nil) then
        return nil, "the bike transform needs exactly one of root and center_of_mass"
    end
    local p = vec3(bike.root ~= nil and bike.root or bike.center_of_mass, 99000)
    if not p then return nil, "the bike's position is not finite or is beyond 99 km" end
    -- bike_visual.from_sample: the body's position is its centre of mass, geometry.com from the root.
    return {root = bike.root ~= nil and p or sub(p, turn(q, g.com)), rotation = q}
end

------------------------------------------------------------------- the bike's contacts
-- How far a hand or foot lets go of a part that spins away from it: none up to `hold` from where the
-- part started (the wrapped angle, so a whole turn is back home), then smoothly all of it over `ramp`.
-- The trick model releases the hands and feet itself within a tenth of a spin, but trick_runtime's
-- visual_targets do not pass that release on; this keeps a caller that sends only the angles from
-- crossing the arms over a spun bar or chasing a whipped pedal with straight legs.
local function hold_release(angle, hold, ramp)
    local x = math.abs(wrap(angle))
    if x <= hold then return 0 end
    return smooth(math.min(1, (x - hold) / ramp))
end
MP.hold_release = hold_release

-- As bike_visual.lua moves its parts: the bars turn about the steering axis by steer plus barspin,
-- the cranks about +X through the bottom bracket, the pedals translate with their spindles and turn
-- only with a tailwhip, and then the whole bike pitches and rolls about the steering pivot. Each
-- hand and foot then goes `release` of the way from its part to where bmx_rider_pose.h puts a
-- released one (MP.CONTACTS hand_free and foot_free), in place and in turn.
local function contacts(frame, a, g, o)
    local q, root = frame.rotation, frame.root
    local whole = multiply(axis_angle({0, 0, 1}, a.movement_bike_roll), axis_angle({1, 0, 0}, a.movement_bike_pitch))
    local steered = axis_angle(g.steering_axis, a.steer)
    local bars = axis_angle(g.steering_axis, a.steer + a.barspin)
    local tail = axis_angle(g.steering_axis, a.tailwhip)
    local cranks = axis_angle({1, 0, 0}, a.crank_phase)
    local function about(r, p, pivot) return add(pivot, turn(r, sub(p, pivot))) end
    local function world(p) return add(root, turn(q, p)) end
    local out = {grips = {}, palms = {}, hands = {}, wrists = {}, spindles = {}, ankles = {}, feet = {},
        platforms = {}, grips_neutral = {}, local_grips = {}, releases = {}, holds = {}, free_palms = {},
        free_hands = {}, free_ankles = {}, free_feet = {}, held_hands = {}, held_feet = {}, palm_offsets = {}, whole = whole}
    local C = MP.CONTACTS
    local bar_hold = hold_release(a.barspin, o.barspin_hold, o.hold_ramp)
    local tail_hold = hold_release(a.tailwhip, o.tailwhip_hold, o.hold_ramp)
    for i, side in {1, -1} do
        -- Grip and hand, bmx_rider_pose.h grip_hand_rotation: the hand's +X from the wrist toward the
        -- knuckles, forward and wrist_slope below level; +Y across the palm, along the tube inward;
        -- the palm (+Z left, -Z right) closes over the top of the grip.
        local grip = side > 0 and g.left_grip or g.right_grip
        local turned = about(bars, grip, g.steering_pivot)
        out.grips_neutral[i] = turned
        out.local_grips[i] = about(whole, turned, g.steering_pivot)
        out.grips[i] = world(out.local_grips[i])
        local outward = g.grip_outward[i]
        local f = unit(sub({0, 0, 1}, mul(outward, dot(outward, {0, 0, 1}))))
        local up = mul(unit(cross(f, outward)), side)
        local distal = sub(mul(f, math.cos(o.wrist_slope)), mul(up, math.sin(o.wrist_slope)))
        local across = mul(outward, -1)
        local hand_local = from_axes(distal, across, cross(distal, across))
        local held_hand = normalized(multiply(multiply(multiply(q, whole), bars), hand_local))
        -- Released (bmx_rider_pose.h palm_target, hand_rotation): beside the grip with the bars
        -- unspun but the bike still pitched and rolled, turned with the steer alone.
        local free_palm = add(world(about(whole, about(steered, grip, g.steering_pivot), g.steering_pivot)),
            turn(q, {side * C.hand_free[1], C.hand_free[2], C.hand_free[3]}))
        local free_hand = normalized(multiply(multiply(q, steered), hand_local))
        local given = math.max(a.barspin_release, side > 0 and a.release_left_hand or a.release_right_hand)
        local r = math.max(given, bar_hold)
        out.releases[i], out.holds[i] = r, bar_hold
        out.held_hands[i], out.free_palms[i], out.free_hands[i] = held_hand, free_palm, free_hand
        out.palms[i] = lerp(out.grips[i], free_palm, r)
        out.hands[i] = slerp(held_hand, free_hand, r)
        out.palm_offsets[i] = {C.palm_reach, 0, side * (C.grip_radius + C.palm_gap)}
        out.wrists[i] = sub(out.palms[i], turn(out.hands[i], out.palm_offsets[i]))
        -- Pedal and foot: the spindle turns with the cranks; the ankle stands ankle_from_sole above
        -- the level pedal face; the sole lies flat on it, the foot's +Z to the rider's left.
        local spindle = about(cranks, g.pedals[i], g.bottom_bracket)
        spindle = about(whole, about(tail, spindle, g.steering_pivot), g.steering_pivot)
        out.spindles[i] = world(spindle)
        local platform = normalized(multiply(multiply(q, whole), tail))
        local offset = add(g.pedal_offset[i], {0, C.ankle_from_sole, o.foot_fore_aft})
        local held_ankle = add(out.spindles[i], turn(platform, offset))
        local slope = o.rig.foot_slope
        local x = {0, -math.sin(slope), math.cos(slope)}
        local z = {1, 0, 0}
        local foot_local = from_axes(x, cross(z, x), z)
        local held_foot = normalized(multiply(platform, foot_local))
        -- Released (bmx_rider_pose.h foot_target, foot_rotation): parked in the bike's own frame,
        -- not cycling with the cranks or chasing the frame through a whip, the sole level with the bike.
        local bb = g.bottom_bracket
        local Fr = C.foot_free
        local free_ankle = world({side * Fr.x, bb[2] + C.ankle_from_sole + Fr.above_bottom_bracket, bb[3] - Fr.behind_bottom_bracket})
        local free_foot = normalized(multiply(q, foot_local))
        local given_foot = math.max(a.tailwhip_release, side > 0 and a.release_left_foot or a.release_right_foot)
        local rf = math.max(given_foot, tail_hold)
        out.releases[i + 2], out.holds[i + 2] = rf, tail_hold
        out.held_feet[i], out.free_ankles[i], out.free_feet[i] = held_foot, free_ankle, free_foot
        out.ankles[i] = lerp(held_ankle, free_ankle, rf)
        out.feet[i] = slerp(held_foot, free_foot, rf)
        out.platforms[i] = platform
    end
    return out
end

------------------------------------------------------------------- limbs
-- Two segments from root toward target, bent toward the pole (a direction). The reach is clamped
-- inside the limb's length, never stretched.
local function two_bone(root, target, pole, a, b)
    local delta = sub(target, root)
    local requested = length(delta)
    local direction = unit(delta) or {0, -1, 0}
    local margin = math.min(.0001, math.min(a, b) * .01)
    local reach = clamp(requested, math.abs(a - b) + margin, a + b - margin)
    local along = (a * a - b * b + reach * reach) / (2 * reach)
    local height = math.sqrt(math.max(0, a * a - along * along))
    local across = sub(pole, mul(direction, dot(pole, direction)))
    local side = unit(across)
        or unit(cross(direction, math.abs(direction[2]) < .9 and {0, 1, 0} or {1, 0, 0}))
    return {root = root, middle = add(root, add(mul(direction, along), mul(side, height))),
        tip = add(root, mul(direction, reach)), direction = direction, side = side,
        requested = requested, reach = reach, limit = a + b - margin, clamped = math.abs(requested - reach) > 1e-7,
        -- The fallback axes above are in world space. Near them a local solve cannot be reused.
        frame_safe = requested > 1e-6 and length(across) > 1e-6}
end
-- The measured joint frames along a limb: +X toward the child, +Z the hinge both segments share
-- (cross(side, direction): the side the elbow or knee points out to, then the limb's line), so the
-- lower segment is the upper one turned about +Z by a positive flex.
local function limb_frames(ik)
    local z = unit(cross(ik.side, ik.direction))
    local xu = unit(sub(ik.middle, ik.root))
    local xl = unit(sub(ik.tip, ik.middle))
    local upper = from_axes(xu, cross(z, xu), z)
    local lower = from_axes(xl, cross(z, xl), z)
    local flex = math.atan2(dot(cross(xu, xl), z), dot(xu, xl))
    return upper, lower, flex
end
-- The turn of `q` about its own +X (swing-twist), -pi to pi.
local function twist_about_x(q)
    if q[4] < 0 then q = {-q[1], -q[2], -q[3], -q[4]} end
    return wrap(2 * math.atan2(q[1], q[4]))
end
local function angle_between(a, b) return math.acos(clamp(dot(unit(a), unit(b)), -1, 1)) end
-- `q` with its own +X brought to within `cap` of `direction` by the least turn: the bend at a wrist.
local function limit_swing(q, direction, cap)
    local x = turn(q, {1, 0, 0})
    local bend = angle_between(x, direction)
    if bend <= cap then return q, false, true end
    local across = cross(x, direction)
    local axis = unit(across) or unit(cross(x, math.abs(x[2]) < .9 and {0, 1, 0} or {1, 0, 0}))
    return normalized(multiply(axis_angle(axis, bend - cap), q)), true, length(across) > 1e-6
end

------------------------------------------------------------------- compose
-- Private eligibility metadata; no cache state or mutable local plan escapes in a returned plan.
local FRAME_SAFE = setmetatable({}, {__mode = "k"})
local function to_vector(p) return vector.create(p[1], p[2], p[3]) end
local function place(pose, id, position, rotation, relative_to)
    local p = {}
    if position then p.position = to_vector(position) end
    if rotation then p.rotation = {rotation[1], rotation[2], rotation[3], rotation[4]} end
    p.relative_to = relative_to
    -- keep_children is false on every joint: each placed joint's children must ride with it (the
    -- spine and head with the hips, the fingers with a hand, the toes with a foot).
    pose[id] = {place = p, keep_children = false}
end

-- input = {bike = {root | center_of_mass, rotation}, articulation = {crank_phase, steer, barspin,
-- tailwhip, movement_bike_pitch, movement_bike_roll, and the releases}, rider = {crouch, lean,
-- hip_offset}, skater_root = point?}. Returns the plan {pose, count, planned, targets, diagnostics}
-- or nil and why. Pure.
function MP.compose(input, options)
    if JOINT_ISSUE then return nil, JOINT_ISSUE end
    local o, why = MP.options(options)
    if not o then return nil, why end
    if type(input) ~= "table" then return nil, "no input" end
    for k in input do
        if k ~= "bike" and k ~= "articulation" and k ~= "rider" and k ~= "skater_root" then return nil, "unknown input field " .. tostring(k) end
    end
    local g, rig = o.geometry, o.rig
    local frame
    frame, why = bike_of(input.bike, g)
    if not frame then return nil, why end
    local a
    a, why = articulation_of(input.articulation)
    if not a then return nil, why end
    local rider
    rider, why = rider_of(input.rider, o)
    if not rider then return nil, why end
    local skater_root = nil
    if input.skater_root ~= nil then
        skater_root = vec3(input.skater_root, 1e5)
        if not skater_root then return nil, "the skater's root is not a finite point" end
    end
    local q, root = frame.rotation, frame.root
    local function world(p) return add(root, turn(q, p)) end
    local function bike_local(p) return turn(conjugate(q), sub(p, root)) end
    local c = contacts(frame, a, g, o)
    local releases = c.releases
    local hands_held = 1 - math.max(releases[1], releases[2])

    -- The hips turn with the bike, then toward the bars by follow_bars of the steer about the bike's
    -- up, after leaning forward about its left: the chest comes with them.
    local hips_local = normalized(multiply(multiply(axis_angle({0, 1, 0}, o.follow_bars * a.steer),
        axis_angle({1, 0, 0}, rider.lean)), HIPS_REST))
    local hips_rotation = normalized(multiply(q, hips_local))

    -- The pelvis: over the saddle's midline, the authored standing height less the crouch, then the
    -- rider's offset. Hands kept on the bars through a whole-bike pitch or roll carry the pelvis
    -- 0.75 of the grips' displacement instead of stretching the arms, all of it with both feet off
    -- (bmx_rider_pose.h). Letting go of the bars, the pelvis stops following them.
    local hip = {rider.hip_offset[1], MP.STANCE.hip_height - rider.crouch + rider.hip_offset[2],
        MP.STANCE.hip_z + rider.hip_offset[3]}
    if a.movement_bike_pitch ~= 0 or a.movement_bike_roll ~= 0 then
        local moved = mul(add(sub(c.local_grips[1], c.grips_neutral[1]), sub(c.local_grips[2], c.grips_neutral[2])), .5)
        local floating = .75 + .25 * math.min(releases[3], releases[4])
        hip = add(hip, mul(moved, hands_held * floating))
    end
    -- The saddle, where bike_visual draws it: the frame pitches and rolls about the steering pivot
    -- with the rest of the bike, and the seat clamp works in that frame. Only a rider holding the
    -- bars rides the saddle round; letting go, the seat frame turns back to the bike's own and the
    -- bike turns under the rider (the hips are no longer carried either). A tailwhip swings the
    -- saddle out from under the hips, so the clamp keeps the unwhipped saddle.
    local saddle = g.saddle
    local pivot = g.steering_pivot
    local seat_q = slerp({0, 0, 0, 1}, c.whole, hands_held)
    local function to_seat(p) return add(pivot, turn(conjugate(seat_q), sub(p, pivot))) end
    local function from_seat(p) return add(pivot, turn(seat_q, sub(p, pivot))) end
    local seat_up = turn(seat_q, {0, 1, 0})
    local half_pelvis = .5 * length(sub(rig.roots.left_up_leg, rig.roots.right_up_leg))
    local floor = saddle.top + half_pelvis + o.seat_clearance
    local function seated(p)
        local s = to_seat(p)
        local out = {clamp(s[1], -saddle.half_width, saddle.half_width), math.max(s[2], floor), clamp(s[3], saddle.rear, saddle.front)}
        return from_seat(out), out[2] ~= s[2], out[1] ~= s[1] or out[3] ~= s[3]
    end
    -- The knee floor (bmx_rider_pose.h proposed_hip_band): a held foot's knee folds no tighter than
    -- min_knee, so the pelvis rises along the seat's up until each hip socket is at least that far
    -- from its ankle. A released foot may tuck (its share of the rise goes with its release).
    local ankles_local = {bike_local(c.ankles[1]), bike_local(c.ankles[2])}
    local function knee_floor(p)
        local raise = 0
        for i = 3, 4 do
            local limb, held = LIMBS[i], 1 - releases[i]
            if held > 0 then
                local la, lb = rig.lengths[limb.upper], rig.lengths[limb.middle]
                local near = math.sqrt(la * la + lb * lb - 2 * la * lb * math.cos(o.min_knee))
                local v = sub(add(p, turn(hips_local, rig.roots[limb.upper])), ankles_local[i - 2])
                local d2 = dot(v, v)
                if d2 < near * near then
                    local vu = dot(v, seat_up)
                    raise = math.max(raise, held * (math.sqrt(math.max(0, vu * vu - d2 + near * near)) - vu))
                end
            end
        end
        if raise > 0 then return add(p, mul(seat_up, raise)), raise end
        return p, 0
    end
    local wanted_hip = hip
    local seat_limited, saddle_limited, knee_raise
    hip, seat_limited, saddle_limited = seated(hip)
    hip, knee_raise = knee_floor(hip)
    local targets = {c.wrists[1], c.wrists[2], c.ankles[1], c.ankles[2]}

    -- Out of reach, the pelvis moves into every limb's reach (at most max_fit), then back over the
    -- saddle and above the knee floor; what is still out of reach is bent straight toward its
    -- target, never stretched.
    local hip_world = world(hip)
    local fitted = hip_world
    for _ = 1, 24 do
        for i, limb in LIMBS do
            local reach = rig.lengths[limb.upper] + rig.lengths[limb.middle] - .001
            local center = sub(targets[i], turn(hips_rotation, rig.roots[limb.upper]))
            local d = sub(fitted, center)
            local n = length(d)
            if n > reach then fitted = add(center, mul(d, reach / n)) end
        end
    end
    local fit = length(sub(fitted, hip_world))
    local fit_limited = fit > o.max_fit
    if fit > 1e-9 and not fit_limited then
        local seat2, saddle2, raise2
        hip, seat2, saddle2 = seated(bike_local(fitted))
        hip, raise2 = knee_floor(hip)
        seat_limited, saddle_limited, knee_raise = seat_limited or seat2, saddle_limited or saddle2, math.max(knee_raise, raise2)
        hip_world = world(hip)
    end

    local J = MP.JOINTS
    local pose = {}
    -- The hips in the world: the bike's transform is a world transform, and the skater's own
    -- placement (joint 1, the hips' parent and the "skater" frame) is not tied to the bike.
    place(pose, J.hips, hip_world, hips_rotation, "world")
    local hip_seat = to_seat(hip)
    local diagnostics = {limbs = {}, seat_limited = seat_limited, saddle_limited = saddle_limited, fit = fit,
        fit_limited = fit_limited, hip_local = hip, hip_wanted = wanted_hip, hip_seat = hip_seat, seat_floor = floor,
        seat_rotation = seat_q, hip_above_seat = hip_seat[2] - saddle.top, knee_limited = knee_raise > 0,
        knee_raise = knee_raise, hands_held = hands_held}
    local frame_safe = true
    local planned = {hips = {position = hip_world, rotation = hips_rotation}}
    for i, limb in LIMBS do
        local side = limb.side
        local root_point = add(hip_world, turn(hips_rotation, rig.roots[limb.upper]))
        local pole_local = limb.arm and {side * o.elbow_pole[1], o.elbow_pole[2], o.elbow_pole[3]} or o.knee_pole
        local pole = turn(q, pole_local)
        local la, lb = rig.lengths[limb.upper], rig.lengths[limb.middle]
        local ik = two_bone(root_point, targets[i], pole, la, lb)
        frame_safe = frame_safe and ik.frame_safe
        local tip_rotation = limb.arm and c.hands[i] or c.feet[i - 2]
        local wrist_limited = false
        if limb.arm then
            -- No hand turns further than max_wrist_bend off its forearm. A capped hand turns less than
            -- the grip asks, and the wrist moves so the palm stays on its point: a few rounds, since
            -- the forearm's line moves with the wrist (by under a fifth of the change each round).
            local wanted = c.hands[i]
            for _ = 1, 8 do
                local capped, limited, safe = limit_swing(wanted, sub(ik.tip, ik.middle), o.max_wrist_bend)
                frame_safe = frame_safe and safe
                if not limited and not wrist_limited then break end
                wrist_limited = wrist_limited or limited
                local step = math.abs(capped[1] * tip_rotation[1] + capped[2] * tip_rotation[2] +
                    capped[3] * tip_rotation[3] + capped[4] * tip_rotation[4])
                tip_rotation = capped
                ik = two_bone(root_point, sub(c.palms[i], turn(capped, c.palm_offsets[i])), pole, la, lb)
                frame_safe = frame_safe and ik.frame_safe
                if step > 1 - 1e-14 then break end
            end
        end
        local upper, lower, flex = limb_frames(ik)
        local twist = twist_about_x(multiply(conjugate(lower), tip_rotation))
        -- Pronation: a palm-down grip turns the hand about the forearm's +X; share of it is the
        -- forearm's own turn, the rest the wrist's (the elbow stays a hinge with a share of 0).
        local share = limb.arm and o.forearm_twist_share or 0
        local lower_world = normalized(multiply(lower, axis_angle({1, 0, 0}, share * twist)))
        local lower_local = normalized(multiply(conjugate(upper), lower_world))
        if limb.arm then
            -- The upper arm in the hips' own frame. A pinned shoulder (the stance's) is set there, so
            -- part way through a blend it is off the animation's shoulder only by the stance's
            -- difference from it, never by how far the hips themselves still have to go.
            local pin = o.pin_shoulders and rig.roots[limb.upper] or nil
            place(pose, J[limb.upper], pin, normalized(multiply(conjugate(hips_rotation), upper)), J.hips)
        else
            -- A thigh turned in the world from its hip socket, the skeleton's own under the placed hips.
            place(pose, J[limb.upper], nil, upper, "world")
        end
        -- Elbows and knees in their parent's frame: a turn about the shared hinge, so the joint stays a
        -- hinge at any weight, whatever the segment above reached.
        place(pose, J[limb.middle], nil, lower_local, nil)
        -- Hands and feet are turned, never placed: each stays on the end of its forearm or shin at
        -- every weight, and at weight 1 that end is the grip or pedal point.
        place(pose, J[limb.tip], nil, tip_rotation, "world")
        local d = {requested = ik.requested, reach = ik.reach, limit = ik.limit, clamped = ik.clamped,
            reaches = not ik.clamped, flex = flex, interior_degrees = 180 - degrees(flex), release = releases[i],
            hold_release = c.holds[i]}
        if limb.arm then
            d.twist, d.tip_twist, d.wrist_limited = twist, (1 - share) * twist, wrist_limited
            d.swing_degrees = degrees(angle_between(sub(ik.tip, ik.middle), turn(tip_rotation, {1, 0, 0})))
        end
        diagnostics.limbs[limb.name] = d
        planned[limb.name] = {root = root_point, middle = ik.middle, tip = ik.tip, upper = upper, lower = lower_world,
            lower_local = lower_local, tip_rotation = tip_rotation}
    end
    if o.head then
        -- The head turns follow of the steer toward the bars, from its calibrated rider-frame rotation.
        local head = normalized(multiply(multiply(q, axis_angle({0, 1, 0}, o.head.follow * a.steer)), o.head.rotation))
        place(pose, J.head, nil, head, "world")
        planned.head = {rotation = head}
    end
    if skater_root then
        local d = length(sub(hip_world, skater_root))
        diagnostics.skater_root_distance = d
        if d > MP.SENT_JOINT_LIMIT then
            return nil, string.format("the skater's placement is %.2f m from the hips: others are sent no joint further than 4 m from its parent", d)
        end
    end
    local count = 0
    for _ in pose do count += 1 end
    if count > MP.MAX_JOINTS then return nil, "the pose has more than 128 joints" end
    local plan = {pose = pose, count = count, planned = planned, diagnostics = diagnostics,
        targets = {hips = hip_world, palms = c.palms, grips = c.grips, wrists = c.wrists, spindles = c.spindles,
            ankles = c.ankles, hands = c.hands, feet = c.feet, platforms = c.platforms, releases = releases,
            held_hands = c.held_hands, held_feet = c.held_feet, free_palms = c.free_palms, free_hands = c.free_hands,
            free_ankles = c.free_ankles, free_feet = c.free_feet, bike_root = root, bike_rotation = q}}
    FRAME_SAFE[plan] = frame_safe
    return plan
end

------------------------------------------------------------------- what is sent
-- The pose as skater.pose will read it, checked here first so a mistake is refused with a reason
-- instead of raised: only this module's joints, by number; each a place of a position within 100 km
-- or a 4-number rotation, relative to the world, its parent or the hips; keep_children true or false.
function MP.validate_pose(pose)
    if type(pose) ~= "table" then return false, "the pose is not a table" end
    local count = 0
    for _ in pose do count += 1 end
    if count > MP.MAX_JOINTS then return false, "the pose has more than 128 joints" end
    for id, entry in pose do
        if type(id) ~= "number" or id ~= math.floor(id) or id < 2 or id > 394 then
            return false, "the pose names a joint that is not a number 2 to 394: " .. tostring(id)
        end
        if not KNOWN_IDS[id] then return false, "unknown joint " .. id .. " in the pose" end
        if type(entry) ~= "table" or type(entry.place) ~= "table" then return false, "joint " .. id .. " has no place" end
        for k in entry do if k ~= "place" and k ~= "keep_children" then return false, "joint " .. id .. " has field " .. tostring(k) end end
        if entry.keep_children ~= nil and type(entry.keep_children) ~= "boolean" then return false, "joint " .. id .. "'s keep_children is not a boolean" end
        local p = entry.place
        for k in p do
            if k ~= "position" and k ~= "rotation" and k ~= "relative_to" then return false, "joint " .. id .. "'s place has field " .. tostring(k) end
        end
        if p.position == nil and p.rotation == nil then return false, "joint " .. id .. "'s place has no position or rotation" end
        if p.position ~= nil and (type(p.position) ~= "vector" or not vec3(p.position, MP.POSITION_LIMIT)) then
            return false, "joint " .. id .. "'s position is not a finite vector within 100 km"
        end
        if p.rotation ~= nil and not quat(p.rotation, .01) then return false, "joint " .. id .. "'s rotation is not a unit {x, y, z, w}" end
        -- The hips are every limb's ancestor and are posed first, so a place in their frame is
        -- never relative to the joint itself or to one hanging from it.
        if p.relative_to ~= nil and p.relative_to ~= "world" and not (p.relative_to == MP.JOINTS.hips and id ~= MP.JOINTS.hips) then
            return false, "joint " .. id .. " is placed relative to " .. tostring(p.relative_to)
        end
    end
    return true
end

-- What the place probe's pcall says about the skater.pose it reached.
function MP.classify_probe(ok, message)
    if ok then return nil, "skater.pose accepted a weight of 2: it is not the skater.pose this module knows" end
    message = tostring(message)
    if string.find(message, "place has a position, a rotation or both", 1, true) then return "place" end
    if string.find(message, "weight is 0 to 1", 1, true) then
        return nil, "skater.pose cannot set a joint's place: this ReSkate is older than PR #365"
    end
    if string.find(message, "permission", 1, true) then return nil, message end
    return nil, "skater.pose refused the place probe: " .. message
end

-- A joint's rotation in the rider's frame (bike space), from a standing read of the skater's
-- placement joint 1 and that joint (skater.joint, world rotations). Joint 1's own +X is the
-- skater's forward, +Y up and +Z the right (the r3 capture), so the rider's frame is it turned a
-- quarter about +Y. For calibrating option head.
function MP.rider_rotation(root_rotation, joint_rotation)
    local r, j = quat(root_rotation, .01), quat(joint_rotation, .01)
    if not r or not j then return nil, "both rotations are unit {x, y, z, w}" end
    local rider = multiply(r, axis_angle({0, 1, 0}, PI / 2))
    return normalized(multiply(conjugate(rider), j))
end

------------------------------------------------------------------- local-pose memo
-- Reuse the expensive local solve when its exact inputs repeat, as in the private S2b trial.
-- Unlike that trial, angles are not rounded and every field of the plan is retained. Continuously
-- changing steer or crank phase may miss every tick; any budget saving needs measurement.
-- Only neutral trick/release inputs without rider or skater-root overrides use this path. All input
-- checks still run before a hit, and every send still validates its returned pose. The world-axis
-- fallbacks of the solver are deliberately unchanged: a solve near one uses full world composition.
local MEMO_ZERO = {"barspin", "tailwhip", "movement_bike_pitch", "movement_bike_roll", "barspin_release",
    "tailwhip_release", "release_left_hand", "release_right_hand", "release_left_foot", "release_right_foot"}
local MEMO_ORIGIN = freeze({root = {0, 0, 0}, rotation = {0, 0, 0, 1}})
local MEMOS = setmetatable({}, {__mode = "k"})
local function copy_plan_value(value)
    if type(value) ~= "table" then return value end -- Luau vectors are immutable values.
    local out = {}
    for k, v in value do out[k] = copy_plan_value(v) end
    return out
end
local function memo_world(lp, root, q)
    local function at(p) return add(root, turn(q, p)) end
    local function rotated(r) return normalized(multiply(q, r)) end
    local pose = {}
    for id, entry in lp.pose do
        local p = entry.place
        local out = {relative_to = p.relative_to}
        if p.relative_to == "world" then
            -- Use the double-precision planned hips, not the already-rounded Luau position vector.
            if id == MP.JOINTS.hips then out.position = to_vector(at(lp.planned.hips.position))
            elseif p.position then out.position = to_vector(at({p.position.x, p.position.y, p.position.z})) end
            if p.rotation then out.rotation = rotated(p.rotation) end
        else
            out.position = p.position
            if p.rotation then out.rotation = table.clone(p.rotation) end
        end
        pose[id] = {place = out, keep_children = entry.keep_children}
    end
    local planned = {hips = {position = at(lp.planned.hips.position), rotation = rotated(lp.planned.hips.rotation)}}
    for _, limb in LIMBS do
        local p = lp.planned[limb.name]
        planned[limb.name] = {root = at(p.root), middle = at(p.middle), tip = at(p.tip), upper = rotated(p.upper),
            lower = rotated(p.lower), lower_local = table.clone(p.lower_local), tip_rotation = rotated(p.tip_rotation)}
    end
    if lp.planned.head then planned.head = {rotation = rotated(lp.planned.head.rotation)} end
    local t = lp.targets
    local targets = {hips = at(t.hips), releases = table.clone(t.releases),
        bike_root = table.clone(root), bike_rotation = table.clone(q)}
    for _, k in {"palms", "grips", "wrists", "spindles", "ankles", "free_palms", "free_ankles"} do
        targets[k] = {at(t[k][1]), at(t[k][2])}
    end
    for _, k in {"hands", "feet", "platforms", "held_hands", "held_feet", "free_hands", "free_feet"} do
        targets[k] = {rotated(t[k][1]), rotated(t[k][2])}
    end
    return {pose = pose, count = lp.count, planned = planned, targets = targets, diagnostics = copy_plan_value(lp.diagnostics)}
end
local function compose_memo(poser, input, o)
    local function full()
        MEMOS[poser] = nil
        return MP.compose(input, o)
    end
    if JOINT_ISSUE or type(input) ~= "table" then return full() end
    for k in input do if k ~= "bike" and k ~= "articulation" then return full() end end
    local frame, why = bike_of(input.bike, o.geometry)
    if not frame then MEMOS[poser] = nil return nil, why end
    local a
    a, why = articulation_of(input.articulation)
    if not a then MEMOS[poser] = nil return nil, why end
    for _, k in MEMO_ZERO do if a[k] ~= 0 then return full() end end
    -- The options (including rig lengths, bone roots and geometry) are recursively frozen by
    -- MP.options. Replacing them or the API binding invalidates this poser's private entry.
    local m, api = MEMOS[poser], poser.api
    if m and m.options == o and m.steer == a.steer and m.crank == a.crank_phase and
        m.api == api and m.skater == api.skater and m.pose == api.skater.pose then
        poser.memo_hits += 1
    else
        local lp, issue = MP.compose({bike = MEMO_ORIGIN, articulation = a}, o)
        if not lp then MEMOS[poser] = nil return nil, issue end
        if not FRAME_SAFE[lp] then return full() end
        m = {options = o, steer = a.steer, crank = a.crank_phase, api = api, skater = api.skater,
            pose = api.skater.pose, plan = lp}
        MEMOS[poser] = m
        poser.memo_misses += 1
    end
    return memo_world(m.plan, frame.root, frame.rotation)
end

------------------------------------------------------------------- the poser
local Poser = {}
Poser.__index = Poser

-- api is the reskate table (or any table with skater.pose); options as MP.options. Constructing one
-- calls nothing.
function MP.new(api, options)
    local o, why = MP.options(options)
    return setmetatable({api = api, options = o, state = o and "off" or "refused", reason = why, blend = 0,
        last_now = nil, last_sent = nil, last_plan = nil, last_weight = 0, capability = nil,
        capability_issue = nil, sends = 0, ends = 0, memo_hits = 0, memo_misses = 0}, Poser)
end

MP.weight_of = smooth

local function pose_function(api)
    if type(api) ~= "table" then return nil, "no reskate API was given" end
    local skater = api.skater
    if type(skater) ~= "table" then return nil, "reskate.skater is missing" end
    local pose = skater.pose
    if type(pose) ~= "function" then return nil, "reskate.skater.pose is missing: this ReSkate has no skater.pose" end
    return pose
end

function Poser:_result(fields)
    fields.state = self.state
    if fields.weight == nil then fields.weight = smooth(self.blend) end
    return fields
end
-- Ends what this poser holds, once: skater.pose(nil).
function Poser:_end_pose()
    if self.last_sent == nil then return false end
    self.last_sent = nil
    local pose = pose_function(self.api)
    if not pose then return false end
    local ok, accepted = pcall(pose, nil)
    self.ends += 1
    return ok and accepted == true
end
function Poser:_refuse(reason, end_held)
    MEMOS[self] = nil
    local ended = end_held and self:_end_pose() or false
    self.state, self.reason, self.blend, self.last_plan = "refused", reason, 0, nil
    return self:_result({ok = false, sent = false, ended = ended, reason = reason, weight = 0})
end
function Poser:_time(now)
    if not finite(now) or now < 0 then return "now is not a finite time" end
    if self.last_now and now < self.last_now then return "time went backwards" end
    return nil
end
-- The options again, every time they are used: a validated table is frozen and passes at once, and
-- anything put in its place is checked as if it were new.
function Poser:_options()
    local o, why = MP.options(self.options)
    if not o then return nil, "the poser's options: " .. tostring(why) end
    self.options = o
    return o
end

-- Starts blending in (or back in, from where a dismount had got to). The first mount probes
-- skater.pose for places, once.
function Poser:mount(now)
    if not MOUNTED_POSE_QUALIFIED then return {ok = false, sent = false, reason = MP.NOT_QUALIFIED, state = self.state, weight = 0} end
    if not self.options then return self:_result({ok = false, sent = false, reason = self.reason}) end
    local bad = self:_time(now)
    if bad then return self:_refuse(bad, true) end
    local _, unusable = self:_options()
    if unusable then return self:_refuse(unusable, true) end
    local pose, why = pose_function(self.api)
    if not pose then return self:_refuse(why, false) end
    if self.capability == nil then
        local ok, message = pcall(pose, {[MP.PROBE_JOINT] = {place = {}}}, MP.PROBE_WEIGHT)
        local capability, issue = MP.classify_probe(ok, message)
        if ok then pcall(pose, nil) end
        self.capability, self.capability_issue = capability == "place", issue
    end
    if not self.capability then return self:_refuse(self.capability_issue, false) end
    if self.state == "refused" or self.state == "off" then self.blend = 0 MEMOS[self] = nil end
    self.state = self.blend >= 1 and "mounted" or "mounting"
    self.reason, self.last_now = nil, now
    return self:_result({ok = true, sent = false})
end

-- Starts blending out; at weight 0 the pose is ended with skater.pose(nil).
function Poser:dismount(now)
    if not MOUNTED_POSE_QUALIFIED then return {ok = false, sent = false, reason = MP.NOT_QUALIFIED, state = self.state, weight = 0} end
    local bad = self:_time(now)
    if bad then return self:_refuse(bad, true) end
    if self.state == "mounting" or self.state == "mounted" then
        self.state, self.last_now = "dismounting", now
    end
    return self:_result({ok = true, sent = false})
end

-- One tick: advances the blend, composes the pose for this bike transform and sends it. Every
-- tick sends (a pose holds 0.3 s); a gap longer than that is reported as lapsed.
function Poser:tick(now, input)
    if not MOUNTED_POSE_QUALIFIED then return {ok = false, sent = false, reason = MP.NOT_QUALIFIED, state = self.state, weight = 0} end
    local bad = self:_time(now)
    if bad then return self:_refuse(bad, true) end
    if self.state == "off" or self.state == "refused" then
        self.last_now = now
        return self:_result({ok = self.state == "off", sent = false, reason = self.reason, weight = 0})
    end
    local pose, why = pose_function(self.api)
    if not pose then return self:_refuse(why, true) end
    local o, unusable = self:_options()
    if not o then return self:_refuse(unusable, true) end
    local dt = now - (self.last_now or now)
    self.last_now = now
    if self.state == "mounting" then
        self.blend = math.min(1, self.blend + dt / o.blend_in)
        if self.blend >= 1 then self.state = "mounted" end
    elseif self.state == "dismounting" then
        self.blend = math.max(0, self.blend - dt / o.blend_out)
        if self.blend <= 0 then
            local ended = self:_end_pose()
            self.state, self.last_plan = "off", nil
            MEMOS[self] = nil
            return self:_result({ok = true, sent = false, ended = ended, weight = 0})
        end
    end
    local composed, plan, issue = pcall(compose_memo, self, input, o)
    if not composed then return self:_refuse("the pose could not be composed: " .. tostring(plan), true) end
    if not plan then return self:_refuse(issue, true) end
    return self:_send(now, plan, smooth(self.blend))
end
-- Every send, a tick's or a refresh's, checks the pose first: the plan a tick returns is the
-- caller's to read, and a refresh sends that same table again.
function Poser:_send(now, plan, weight)
    local o, unusable = self:_options()
    if not o then return self:_refuse(unusable, true) end
    local valid, invalid = MP.validate_pose(plan.pose)
    if not valid then return self:_refuse(invalid, true) end
    if not finite(weight) or weight < 0 or weight > 1 then return self:_refuse("the weight is not 0 to 1", true) end
    local pose = pose_function(self.api)
    local ok, accepted, reason = pcall(pose, plan.pose, weight, {shown = o.shown})
    if not ok then return self:_refuse("skater.pose raised: " .. tostring(accepted), true) end
    if accepted ~= true then return self:_refuse("skater.pose refused: " .. tostring(reason or "no reason given"), true) end
    local gap = self.last_sent and now - self.last_sent or nil
    self.last_sent, self.last_plan, self.last_plan_time, self.last_weight = now, plan, now, weight
    self.sends += 1
    return self:_result({ok = true, sent = true, weight = weight, plan = plan, gap = gap,
        lapsed = gap ~= nil and gap > MP.HOLD_SECONDS})
end

-- Sends the last plan again, as it was, while it is younger than the hold: for a tick without a
-- fresh bike transform. The blend does not move.
function Poser:refresh(now)
    if not MOUNTED_POSE_QUALIFIED then return {ok = false, sent = false, reason = MP.NOT_QUALIFIED, state = self.state, weight = 0} end
    local bad = self:_time(now)
    if bad then return self:_refuse(bad, true) end
    if self.state ~= "mounting" and self.state ~= "mounted" and self.state ~= "dismounting" then
        return self:_result({ok = false, sent = false, reason = "nothing is mounted"})
    end
    if not self.last_plan or now - self.last_plan_time > MP.HOLD_SECONDS then
        return self:_refuse("the last pose is older than the 0.3 s hold: tick with a fresh bike transform", true)
    end
    local pose, why = pose_function(self.api)
    if not pose then return self:_refuse(why, true) end
    self.last_now = now
    local plan_time = self.last_plan_time
    local out = self:_send(now, self.last_plan, self.last_weight)
    self.last_plan_time = plan_time
    return out
end

-- Ends the pose at once (unload, menu, owner lost).
function Poser:stop()
    MEMOS[self] = nil
    if not MOUNTED_POSE_QUALIFIED then return {ok = true, sent = false, ended = false, reason = MP.NOT_QUALIFIED, state = self.state, weight = 0} end
    local ended = self:_end_pose()
    self.state, self.blend, self.last_plan = "off", 0, nil
    return self:_result({ok = true, sent = false, ended = ended, weight = 0})
end

function Poser:status()
    return {state = self.state, blend = self.blend, weight = smooth(self.blend), reason = self.reason,
        capability = self.capability, sends = self.sends, ends = self.ends, last_sent = self.last_sent,
        qualified = MOUNTED_POSE_QUALIFIED}
end

return table.freeze(MP)

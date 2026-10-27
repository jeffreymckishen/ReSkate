-- Original authored pose directions for the existing movement families. These are not recovered
-- animations, measured BMX Streets poses or proof of native rider alignment.
--
-- sample(movement_id, phase) returns fresh tables, or nil and a reason. phase is the exact 0..1
-- pose envelope, not elapsed time or a rounded cache key. Pass limb_targets and torso separately to
-- mounted_pose.compose; use the movement's existing per-limb releases, not phase a second time.
--
-- Each limb direction is in bike axes (+X rider-left, +Y up, +Z forward), measured from the FINAL
-- shoulder/hip socket toward a WRIST/ANKLE. reach is a fraction of the two-bone reachable interval:
-- abs(a-b)+margin .. a+b-margin. mounted_pose resolves that interval from its actual rig, then blends
-- by release. These directions are neither absolute world points nor palm/sole positions.
--
-- Torso pelvis is a bike-space offset in metres, pitch and head_yaw are radians, weight is phase.
-- A nonzero head_yaw needs mounted_pose's calibrated options.head; this module never guesses a head
-- frame. Existing masks still decide which limbs may leave contacts, including Superman and the
-- opposite hand of Bus Driver. A family descriptor alone never releases a limb or executes a trick.
local catalog = require("./catalog")
local motions = require("./motions")
local PT = {}

local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function target(row)
    if row == nil then return nil end
    local n = math.sqrt(row[1]*row[1] + row[2]*row[2] + row[3]*row[3])
    return {direction = {row[1]/n, row[2]/n, row[3]/n}, reach = row[4]}
end
local function reflect(row)
    if row == nil then return nil end
    return {-row[1], row[2], row[3], row[4]}
end
-- The canonical pose faces the left variant. Most pairs reflect a left-limb direction for the
-- right limb; No Foot Can supplies a separate right-foot direction to put both feet across the bike.
local function profile(hand, foot, pitch, pelvis, yaw, right_foot)
    return {limbs = {left_hand = target(hand), right_hand = target(reflect(hand)),
            left_foot = target(foot), right_foot = target(right_foot or reflect(foot))},
        pitch = pitch or 0, pelvis = pelvis or {0, 0, 0}, head_yaw = yaw or 0}
end

-- All magnitudes and posture choices below are authored starting points. The conservative reach
-- fractions keep a bend in each released limb; in-game calibration and visual judging are pending.
local profiles = {
    grand_slam = profile({.6, .2, .7, .72}, {.35, -.8, -.5, .68}, .12, {0, .04, -.03}),
    twix = profile({.6, -.15, .7, .72}, {.45, -.65, -.3, .68}, .05),
    helicopter = profile({.9, .05, .2, .78}, {.45, -.7, -.3, .68}, -.08),
    bri_flip = profile(nil, {.4, -.75, -.4, .70}, .12, {0, .03, -.04}),
    willy_flip = profile({.6, .2, .7, .72}, {.3, -.7, -.5, .70}, .15, {0, .04, -.04}),
    mc_griddle = profile(nil, {.3, -.6, .4, .66}, .10),
    kick_whip = profile({.7, -.15, .6, .74}, {.65, -.6, -.2, .74}, .06),
    superman = profile({.2, -.3, .93, .82}, {.12, -.2, -1, .84}, .38, {0, .03, -.12}),
    christ_air = profile({1, .05, 0, .88}, {.25, -1, 0, .82}, -.32, {0, .08, 0}),
    bar_hug = profile(nil, nil, .28, {0, -.04, .04}),
    nothing = profile({.7, -.25, -.1, .82}, {.45, -.8, -.1, .76}, -.12, {0, .06, 0}),
    tuck_no = profile({.25, -.5, .5, .63}, nil, .22, {0, -.08, .02}),
    table = profile(nil, nil, -.05, {.06, 0, 0}),
    invert = profile(nil, {.25, -.35, -.6, .70}, .08, {0, .02, -.03}),
    turndown = profile(nil, nil, .04, {0, 0, -.02}, .65),
    suicide = profile({.85, .15, -.35, .86}, nil, -.22, {0, .02, -.02}),
    euro = profile(nil, {.25, -.45, -.5, .72}, .05),
    lookback = profile(nil, nil, .04, {.03, 0, -.02}, .95),
    cannon_ball = profile({.15, -.8, -.4, .68}, {.15, -.5, .6, .60}, .12, {0, -.12, 0}),
    tire_grab = profile({.15, -.5, .85, .88}, nil, .18, {0, -.03, .02}, .12),
    seat_grab = profile({.1, -.75, -.55, .70}, nil, -.08, {0, 0, -.02}, .25),
    bus_driver = profile({.3, -.25, .9, .78}, nil, .04),
    barspin = profile({.55, -.2, .7, .74}, nil, .02),
    toboggan = profile({.2, -.65, -.65, .80}, nil, -.12, {0, 0, -.04}, .45),
    one_hander = profile({.9, .1, .1, .86}, nil, -.03),
    xup = profile(nil, nil, .03, {0, 0, 0}, .18),
    tuck_up = profile(nil, nil, .20, {0, -.10, .02}),
    no_foot_can = profile(nil, {-.65, -.55, .45, .73}, .02, {0, .02, 0}, 0, {-.65, -.6, .15, .68}),
    tailwhip = profile(nil, {.45, -.65, -.25, .72}, .02),
    whopper = profile(nil, {.45, -.6, -.35, .72}, .05),
    crankflip = profile(nil, {.25, -.65, .2, .65}, .03, {0, .03, 0}),
    -- A Can crosses forward, a Nac crosses behind, and One Footer extends away from the bike.
    -- Equal reach fractions separate direction from extension when these are compared after IK.
    can = profile(nil, {-.5, -.65, .5, .73}),
    moto = profile(nil, nil, .08, {.04, 0, 0}, .20),
    nac = profile(nil, {-.5, -.65, -.5, .73}),
    griz_air = profile(nil, {.25, -.4, .85, .78}, .08),
    one_footer = profile(nil, {.8, -.55, 0, .73}),
    candy_bar = profile(nil, {.05, -.2, 1, .80}, .06),
}
local function freeze(t)
    for _, value in t do if type(value) == "table" then freeze(value) end end
    return table.freeze(t)
end
freeze(profiles)

local LIMBS = {"left_hand", "right_hand", "left_foot", "right_foot"}
local OPPOSITE = {left_hand = "right_hand", right_hand = "left_hand", left_foot = "right_foot", right_foot = "left_foot"}

function PT.sample(movement_id, phase)
    if not finite(movement_id) or movement_id % 1 ~= 0 then return nil, "movement_id is a finite integer" end
    if not finite(phase) or phase < 0 or phase > 1 then return nil, "phase is finite and 0 to 1" end
    if movement_id == catalog.none then
        return {movement_id = movement_id, family = "none", phase = phase, release_mask = 0,
            provenance = "authored_pose_targets", realized = false}
    end
    local entry = motions.find(movement_id)
    if not entry or catalog.name(movement_id) == nil then return nil, "movement_id has no existing movement" end
    local authored = profiles[entry.family]
    if not authored then return nil, "movement family has no authored targets: " .. tostring(entry.family) end
    local mirrored = entry.direction > 0
    local sign = mirrored and -1 or 1
    local limbs = {}
    for i, name in LIMBS do
        if math.floor(entry.release_mask / 2^(i - 1)) % 2 == 1 then
            local source = authored.limbs[mirrored and OPPOSITE[name] or name]
            if not source then return nil, "released limb has no authored target: " .. name end
            local d = source.direction
            limbs[name] = {direction = {sign*d[1], d[2], d[3]}, reach = source.reach}
        end
    end
    return {movement_id = movement_id, family = entry.family, phase = phase, release_mask = entry.release_mask,
        limb_targets = next(limbs) and limbs or nil,
        torso = {weight = phase, pelvis = {sign*authored.pelvis[1], authored.pelvis[2], authored.pelvis[3]},
            pitch = authored.pitch, head_yaw = sign*authored.head_yaw},
        provenance = "authored_pose_targets", realized = false}
end

return table.freeze(PT)

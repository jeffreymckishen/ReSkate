-- Rider presentation cues: uphill counterpitch, crank leveling and landing
-- compression. Pure Luau ports of this repo's Engine/Game/BMX headers
-- bmx_rider_posture_presentation.h, bmx_crank_presentation.h and
-- bmx_landing_presentation.h, plus the cue-to-offset mapping that
-- Extension/BMX/bmx_rider_pose.h applies to them. Presentation only: nothing
-- here changes a force, contact, input, trick phase or score, it owns no SDK
-- object and runs nothing on require. The constants are our adaptation tuning
-- from those headers, not recovered BMX Streets values (RIDER_PRESENTATION.md).
-- Coordinates: authored bike +Y up, +Z forward, +X rider-left; Hamilton XYZW.
-- Serials are decimal uint64 strings, as frame_identity.lua carries them.
local Identity = require("./lease_identity")
local G = require("./bike_geometry")
local V = require("./bike_visual")
local P = {}

local RPD = .01745329251994329577
local PI, TAU = math.pi, 2 * math.pi
P.radians_per_degree = RPD
P.maximum_counterpitch = 25 * RPD
P.counterpitch_rate = 90 * RPD
P.leveling_rate = 4.5 -- rad/s
P.maximum_seconds = .1
-- rider_alignment.lua's neutral hip and chest anchors, in bike space.
P.neutral_hip = table.freeze({0, .9578988338, -.2877711058})
P.neutral_chest = table.freeze({0, 1.476639786, .015})

-- cos(15 deg): both measured wheel planes must agree this closely.
local PLANE_AGREEMENT = .9659258263
local UPRIGHT_LOW, UPRIGHT_HIGH = .5, .8191520443

local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function clamp(x, low, high) return math.max(low, math.min(high, x)) end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function flag(list, i) return type(list) == "table" and list[i] == true end
local function seconds_valid(x) return finite(x) and x >= 0 and x <= P.maximum_seconds end
local function speed_valid(x) return finite(x) and x >= 0 end
local function unit(v)
    if type(v) ~= "table" then return false end
    for i = 1, 3 do if not finite(v[i]) then return false end end
    local n = dot(v, v)
    return n > .99 and n < 1.01
end
local function smooth(low, high, value)
    local t = clamp((value - low) / (high - low), 0, 1)
    return t * t * (3 - 2 * t)
end
local function slew(previous, target, maximum)
    return previous + clamp(target - previous, -maximum, maximum)
end

-- IEEE remainder, as std::remainder: the quotient rounds to nearest, ties to
-- even. fmod is exact, and moving a remainder above half a period by one
-- period is exact too, so the result matches the C++ for any finite input.
local function remainder(x, y)
    local r = math.fmod(x, y)
    local half = y * .5
    if r > half then
        r -= y
    elseif r < -half then
        r += y
    elseif r == half or r == -half then
        local quotient = math.floor((x - r) / y + .5)
        if quotient % 2 ~= 0 then r = r > 0 and r - y or r + y end
    end
    return r
end
P.remainder = remainder
function P.wrap(angle) return remainder(angle, TAU) end
local wrap = P.wrap

----------------------------------------------------------------- uphill posture
-- Only two actually supported wheels with measured, agreeing normals create
-- an incline cue. A missing or disagreeing normal, or one-wheel support (a
-- manual), only fades a prior cue. A nose-up chassis or requested pitch alone
-- never manufactures a ground grade.
function P.posture_state() return {uphill = 0, counterpitch = 0, serial = "0"} end

local function posture_valid(s)
    return type(s) == "table" and finite(s.uphill) and s.uphill >= 0 and s.uphill <= 1 and
        finite(s.counterpitch) and s.counterpitch >= 0 and s.counterpitch <= P.maximum_counterpitch and
        Identity.is_u64(s.serial)
end
local function posture_copy(s) return {uphill = s.uphill, counterpitch = s.counterpitch, serial = s.serial} end

-- sample = {seconds, serial, supported = {bool, bool}, normal_available = {bool, bool},
-- normal = {vec, vec}, forward = vec}. The wheel order does not matter.
function P.step_posture(previous, sample)
    local valid_previous = posture_valid(previous)
    local out = {valid = false, advanced = false, measured_plane = false, measured_grade = 0,
        uphill_target = 0, counterpitch_target = 0,
        state = valid_previous and posture_copy(previous) or P.posture_state()}
    if not valid_previous then out.issue = "invalid_previous" return out end
    if type(sample) ~= "table" or not seconds_valid(sample.seconds) then out.issue = "invalid_seconds" return out end
    if not Identity.is_nonzero_u64(sample.serial) then out.issue = "invalid_serial" return out end
    if not unit(sample.forward) then out.issue = "invalid_forward" return out end
    if Identity.compare(sample.serial, previous.serial) < 0 then out.issue = "serial_regressed" return out end
    out.valid = true
    -- Duplicate and paused samples integrate nothing and keep the old serial.
    if sample.seconds == 0 then out.hold = "paused" return out end
    if sample.serial == previous.serial then out.hold = "duplicate" return out end
    local f, n = sample.forward, sample.normal
    local horizontal = math.sqrt(f[1] * f[1] + f[3] * f[3])
    if horizontal > .0001 and flag(sample.supported, 1) and flag(sample.supported, 2) and
        flag(sample.normal_available, 1) and flag(sample.normal_available, 2) and type(n) == "table" and
        unit(n[1]) and unit(n[2]) and n[1][2] > .7 and n[2][2] > .7 and dot(n[1], n[2]) >= PLANE_AGREEMENT then
        local m = {n[1][1] + n[2][1], n[1][2] + n[2][2], n[1][3] + n[2][3]}
        local length = math.sqrt(dot(m, m))
        m = {m[1] / length, m[2] / length, m[3] / length}
        local heading = {f[1] / horizontal, 0, f[3] / horizontal}
        out.measured_grade = math.atan2(-dot(m, heading), m[2])
        out.measured_plane = true
        out.uphill_target = smooth(3 * RPD, 20 * RPD, clamp(out.measured_grade, 0, 30 * RPD))
    end
    out.state.uphill = clamp(slew(previous.uphill, out.uphill_target, 4 * sample.seconds), 0, 1)
    local elevation = horizontal > .0001 and math.atan2(f[2], horizontal) or 0
    out.counterpitch_target = out.state.uphill * clamp(math.max(elevation, 0), 0, P.maximum_counterpitch)
    -- Without a fresh measured uphill plane, a takeoff can only fade the gaze.
    if not out.measured_plane or out.uphill_target == 0 then
        out.counterpitch_target = math.min(out.counterpitch_target, previous.counterpitch)
    end
    out.state.counterpitch = clamp(slew(previous.counterpitch, out.counterpitch_target,
        P.counterpitch_rate * sample.seconds), 0, P.maximum_counterpitch)
    out.state.serial = sample.serial
    out.advanced = true
    return out
end

----------------------------------------------------------------- crank leveling
-- Raw cadence, wheel rotors, forces and authored trick angles are untouched.
-- Coasting turns the displayed crank to the nearest level stance; pedaling
-- and reserved (trick) cadence apply only the fresh raw increment.

-- An X-axis rotation (bike_visual.lua, rider_alignment.lua) gives
-- y' = y*cos(a) - z*sin(a), so atan2(y, z) puts this arm horizontal.
function P.horizontal_angle(arm) return math.atan2(arm[2], arm[3]) end
-- Measured from bike_geometry, the geometry bike_visual rotates. The C++
-- reads float-rounded copies of the same anchors, 3e-8 rad apart.
local SOURCE_HORIZONTAL = P.horizontal_angle({G.pedals[1][1] - G.bottom_bracket[1],
    G.pedals[1][2] - G.bottom_bracket[2], G.pedals[1][3] - G.bottom_bracket[3]})
function P.source_horizontal_angle() return SOURCE_HORIZONTAL end

-- An identity is the owned body and its owner: {body_handle, lease_handle},
-- compared by reference. The per-read physics_epoch is deliberately not part
-- of it, since frame_identity.lua issues a new one with every measurement.
local function complete(key)
    return type(key) == "table" and key.body_handle ~= nil and key.body_handle ~= false and
        key.lease_handle ~= nil and key.lease_handle ~= false
end
local function same_identity(a, b)
    return complete(a) and complete(b) and rawequal(a.body_handle, b.body_handle) and
        rawequal(a.lease_handle, b.lease_handle)
end
local function identity_copy(key) return {body_handle = key.body_handle, lease_handle = key.lease_handle} end

function P.crank_state()
    return {identity = nil, phase = 0, raw_phase = 0, target = 0, time = 0, serial = "0",
        initialized = false, observed = false, coasting = false}
end
local function crank_copy(s)
    return {identity = s.identity and identity_copy(s.identity) or nil, phase = s.phase, raw_phase = s.raw_phase,
        target = s.target, time = s.time, serial = s.serial, initialized = s.initialized == true,
        observed = s.observed == true, coasting = s.coasting == true}
end
local function crank_valid(s)
    if type(s) ~= "table" then return false end
    if s.initialized ~= true then return true end
    return complete(s.identity) and finite(s.phase) and finite(s.raw_phase) and finite(s.target) and
        finite(s.time) and Identity.is_nonzero_u64(s.serial)
end

-- The same owned bike can resume at its displayed phase. A new identity or a
-- fresh start is seeded independently from its own source cadence.
function P.suspend_crank(previous)
    local s = crank_copy(previous)
    s.observed, s.coasting = false, false
    return s
end

-- sample = {identity, raw_phase, time, seconds, serial, enabled, pedaling, reserved}.
function P.step_crank(previous, sample)
    local valid_previous = crank_valid(previous)
    local out = {valid = false, advanced = false, rebased = false, leveling = false,
        state = valid_previous and crank_copy(previous) or P.crank_state()}
    if not valid_previous then out.issue = "invalid_previous" return out end
    if type(sample) ~= "table" or not complete(sample.identity) then out.issue = "invalid_identity" return out end
    if not Identity.is_nonzero_u64(sample.serial) then out.issue = "invalid_serial" return out end
    if not finite(sample.raw_phase) or math.abs(sample.raw_phase) > 1e6 then out.issue = "invalid_phase" return out end
    if not finite(sample.time) or sample.time < 0 then out.issue = "invalid_time" return out end
    if not seconds_valid(sample.seconds) then out.issue = "invalid_seconds" return out end
    out.valid = true
    -- No paused integration and no clock consumption.
    if sample.seconds == 0 then out.hold = "paused" return out end
    if previous.initialized ~= true or not same_identity(previous.identity, sample.identity) then
        local phase = wrap(sample.raw_phase)
        out.state = {identity = identity_copy(sample.identity), phase = phase, raw_phase = phase, target = 0,
            time = sample.time, serial = sample.serial, initialized = true, observed = true, coasting = false}
        out.rebased = true
        return out
    end
    if previous.observed == true and sample.serial == previous.serial then
        -- The same serial at another time is a contradiction, not a repeat.
        if sample.time ~= previous.time then
            out.valid, out.issue = false, "duplicate_changed"
            out.state = P.suspend_crank(previous)
        else
            out.hold = "duplicate"
        end
        return out
    end
    local successor = previous.observed == true and Identity.bounded_delta(sample.serial, previous.serial, 1) == 1 and
        math.abs(sample.time - previous.time - sample.seconds) <= 1e-7
    local nextstate = out.state
    nextstate.raw_phase, nextstate.time, nextstate.serial = wrap(sample.raw_phase), sample.time, sample.serial
    if not successor then
        -- Do not catch up through an unobserved interval or replay raw jumps.
        nextstate.observed, nextstate.coasting = true, false
        out.rebased = true
        return out
    end
    out.advanced = true
    if sample.enabled ~= true then nextstate.coasting = false return out end
    -- Pedaling resumes from the displayed phase with only the new raw cadence
    -- increment, rather than snapping back to its frozen source angle.
    nextstate.phase = wrap(previous.phase + wrap(nextstate.raw_phase - previous.raw_phase))
    if sample.pedaling == true or sample.reserved == true then nextstate.coasting = false return out end
    -- The level target is chosen once per coast, so the front foot stays put.
    if previous.coasting ~= true then
        nextstate.target = wrap(nextstate.phase + remainder(SOURCE_HORIZONTAL - nextstate.phase, PI))
    end
    nextstate.coasting = true
    local limit = P.leveling_rate * sample.seconds
    local movement = clamp(wrap(nextstate.target - nextstate.phase), -limit, limit)
    nextstate.phase = wrap(nextstate.phase + movement)
    out.leveling = movement ~= 0
    return out
end

----------------------------------------------------------------- landing compression
-- Stateless: the caller owns serial/clock continuity and clears the previous
-- value on pause, refusal or owner change. evidence carries the
-- bmx_landing_approach Evidence fields this needs: valid, first_contact,
-- post_available, contact_serial, post_closing_speed, scoring_closing_speed.
local function landing_refused(issue) return {valid = false, advanced = false, compression = 0, issue = issue} end
function P.step_landing(previous, native_seconds, current_serial, supported, evidence)
    if not finite(previous) or previous < 0 or previous > 1 then return landing_refused("invalid_previous") end
    if not seconds_valid(native_seconds) then return landing_refused("invalid_seconds") end
    -- Repeated renders or paused native time cannot trigger or spend recovery.
    if native_seconds == 0 then return {valid = true, advanced = false, compression = previous, hold = "paused"} end
    supported = supported == true
    if not Identity.is_nonzero_u64(current_serial) then return landing_refused("invalid_serial") end
    if type(evidence) ~= "table" or evidence.valid ~= true or supported ~= (evidence.post_available == true) or
        (evidence.first_contact == true and not supported) then return landing_refused("invalid_evidence") end
    local target = 0
    if supported then
        if not Identity.is_nonzero_u64(evidence.contact_serial) or
            Identity.compare(evidence.contact_serial, current_serial) > 0 or
            not speed_valid(evidence.post_closing_speed) then return landing_refused("invalid_evidence") end
        -- A retained first-touch maximum stays authoritative for scoring, but
        -- is an animation pulse only on that actual first-touch sample.
        local impact = evidence.post_closing_speed
        if evidence.first_contact == true then
            if evidence.contact_serial ~= current_serial or not speed_valid(evidence.scoring_closing_speed) then
                return landing_refused("invalid_evidence")
            end
            impact = math.max(impact, evidence.scoring_closing_speed)
        end
        target = clamp(impact / 6, 0, 1)
    end
    -- Advancing air samples may recover the stored pose, never create a pulse.
    local recovered = math.max(0, previous - native_seconds * 4)
    return {valid = true, advanced = true, compression = math.max(target, recovered)}
end

-- Slews the existing 4 cm air posture over about .2 native seconds either
-- way. No body position or airborne gate changes; same clock contract.
function P.step_air_extension(previous, native_seconds, airborne)
    if not finite(previous) or previous < 0 or previous > 1 then
        return {valid = false, advanced = false, blend = 0, issue = "invalid_previous"}
    end
    if not seconds_valid(native_seconds) then
        return {valid = false, advanced = false, blend = 0, issue = "invalid_seconds"}
    end
    if native_seconds == 0 then return {valid = true, advanced = false, blend = previous, hold = "paused"} end
    local limit = native_seconds * 5
    local change = clamp((airborne == true and 1 or 0) - previous, -limit, limit)
    return {valid = true, advanced = true, blend = clamp(previous + change, 0, 1)}
end

----------------------------------------------------------------- mapping
-- bike_visual.lua articulation with the presented crank. An uninitialized
-- crank shows the raw cadence, as the C++ bridge does.
function P.articulation(crank, raw_phase, base)
    local pose = V.neutral()
    if base ~= nil then
        if type(base) ~= "table" then return nil, "invalid base articulation" end
        for key in pose do
            if base[key] ~= nil then
                if not finite(base[key]) then return nil, "invalid base articulation " .. key end
                pose[key] = base[key]
            end
        end
    end
    if type(crank) == "table" and crank.initialized == true then
        if not finite(crank.phase) then return nil, "invalid crank phase" end
        pose.crank_phase = crank.phase
    elseif raw_phase ~= nil then
        if not finite(raw_phase) then return nil, "invalid raw crank phase" end
        pose.crank_phase = raw_phase
    end
    return pose
end

local function quaternion(q)
    if type(q) ~= "table" then return nil end
    local n = 0
    for i = 1, 4 do if not finite(q[i]) then return nil end n += q[i] * q[i] end
    if math.abs(n - 1) > .001 then return nil end
    n = math.sqrt(n)
    return {q[1] / n, q[2] / n, q[3] / n, q[4] / n}
end
local function turn(q, p)
    local x, y, z, w = q[1], q[2], q[3], q[4]
    local tx, ty, tz = 2 * (y * p[3] - z * p[2]), 2 * (z * p[1] - x * p[3]), 2 * (x * p[2] - y * p[1])
    return {p[1] + w * tx + y * tz - z * ty, p[2] + w * ty + z * tx - x * tz, p[3] + w * tz + x * ty - y * tx}
end
local function fraction(x, name, optional)
    if x == nil and optional then return 0 end
    if not finite(x) or x < 0 or x > 1 then return nil, "invalid " .. name end
    return x
end

-- Maps the presented cues onto rider_alignment.lua's visual.rider offsets.
-- cues = {posture = posture state or nil, compression, air_extension}.
-- context = {orientation (bike to world), release = {left_arm, right_arm,
-- left_leg, right_leg} (effective, already including bar/tail releases),
-- movement_phase, preload, airborne, scale (posture fit scale, default 1)}.
-- Returns {hip_offset, torso_offset, gaze_counterpitch, posture_applied}.
-- Preload, weight shift, pedal bob and seat fitting belong to other cues.
function P.rider_offsets(cues, context)
    if type(cues) ~= "table" or type(context) ~= "table" then return nil, "invalid presentation input" end
    local compression, why = fraction(cues.compression, "compression", true)
    if not compression then return nil, why end
    local air
    air, why = fraction(cues.air_extension, "air extension", true)
    if not air then return nil, why end
    local posture = cues.posture
    if posture ~= nil and not posture_valid(posture) then return nil, "invalid posture state" end
    local q = quaternion(context.orientation)
    if not q then return nil, "invalid orientation" end
    local released
    released, why = fraction(context.movement_phase, "movement phase", true)
    if not released then return nil, why end
    if context.release ~= nil and type(context.release) ~= "table" then return nil, "invalid release" end
    for _, limb in ipairs({"left_arm", "right_arm", "left_leg", "right_leg"}) do
        local value
        value, why = fraction(context.release and context.release[limb], "release " .. limb, true)
        if not value then return nil, why end
        released = math.max(released, value)
    end
    local scale = context.scale == nil and 1 or context.scale
    scale, why = fraction(scale, "scale")
    if not scale then return nil, why end
    if context.preload ~= nil and not finite(context.preload) then return nil, "invalid preload" end
    local preload = context.airborne == true and 0 or clamp(context.preload or 0, 0, 1)
    local hip, torso, gaze = {0, 0, 0}, {0, 0, 0}, 0
    if posture ~= nil and scale ~= 0 then
        -- Fades with a rolled or steep chassis and with any limb release, so a
        -- deep roll or a no-hander never forces an upright neutral correction.
        local up, forward = turn(q, {0, 1, 0}), turn(q, {0, 0, 1})
        local upright = smooth(UPRIGHT_LOW, UPRIGHT_HIGH, up[2]) *
            smooth(UPRIGHT_LOW, UPRIGHT_HIGH, math.sqrt(forward[1] * forward[1] + forward[3] * forward[3]))
        local neutral = 1 - released
        -- Bounded to 4.5 mm hip / 18.75 mm chest of incline body response.
        local a = .25 * scale * posture.uphill * (1 - .5 * air) * neutral * upright * (1 - .6 * preload)
        local c = scale * compression * neutral * upright
        hip = {0, -.018 * a, .010 * a - .004 * c}
        torso = {0, -.012 * a, math.min(.075, .075 * a + .015 * c)}
        gaze = scale * posture.counterpitch * (1 - .5 * air) * neutral * upright
    end
    -- The vertical landing recovery and air extension apply with or without
    -- posture, so a brief support toggle cannot rebound the hips.
    local extension = .04 * air
    return {hip_offset = {0, extension - .08 * compression + hip[2], hip[3]},
        torso_offset = {0, extension - .06 * compression + torso[2], torso[3]},
        gaze_counterpitch = gaze, posture_applied = posture ~= nil and scale ~= 0}
end

----------------------------------------------------------------- presenter
-- Mirrors how Extension/BMX/bmx_chassis_ride.cpp drives the three policies
-- once per accepted native step. A duplicate serial returns the previous
-- output without stepping anything; a new owner or a rewound serial clears
-- posture, compression and air extension and suspends the crank.
local Presenter = {}
Presenter.__index = Presenter

function P.new()
    local self = setmetatable({}, Presenter)
    self.crank = P.crank_state()
    self:reset()
    return self
end

function Presenter:reset()
    self.posture, self.posture_available = P.posture_state(), false
    self.compression, self.air_extension = 0, 0
    self.crank = P.suspend_crank(self.crank)
    self.identity, self.serial, self.last = nil, nil, nil
end

local function held(last, reason)
    local out = table.clone(last)
    out.advanced, out.hold, out.reset = false, reason, false
    return out
end

-- sample = {identity, serial, time, seconds, raw_crank_phase, enabled,
-- pedaling, reserved, airborne, supported, evidence, wheels = {supported,
-- normal_available, normal}, forward, orientation, release, movement_phase,
-- preload, scale, base_articulation}.
function Presenter:step(sample)
    if type(sample) ~= "table" or not complete(sample.identity) or not Identity.is_nonzero_u64(sample.serial) or
        not seconds_valid(sample.seconds) or not finite(sample.time) or sample.time < 0 or
        not finite(sample.raw_crank_phase) or math.abs(sample.raw_crank_phase) > 1e6 then
        self:reset()
        return {valid = false, advanced = false, reset = true, issue = "invalid_sample"}
    end
    local seconds, reset = sample.seconds, false
    if self.identity ~= nil then
        local same = same_identity(self.identity, sample.identity)
        -- An active duplicate must name the same consumed clock. Paused
        -- reads still spend no time, just as step_crank's pause contract.
        if same and self.last and seconds > 0 and sample.serial == self.serial and sample.time ~= self.crank.time then
            self:reset()
            return {valid = false, advanced = false, reset = true, issue = "duplicate_changed"}
        end
        -- Nothing steps twice for one native sample, and a pause spends nothing.
        if same and self.last and (sample.serial == self.serial or seconds == 0) then
            return held(self.last, seconds == 0 and "paused" or "duplicate")
        end
        if not same or Identity.compare(sample.serial, self.serial) < 0 then self:reset() reset = true end
    end
    local crank = P.step_crank(self.crank, {identity = sample.identity, raw_phase = sample.raw_crank_phase,
        time = sample.time, seconds = seconds, serial = sample.serial, enabled = sample.enabled,
        pedaling = sample.pedaling, reserved = sample.reserved})
    -- A failed crank clock cannot advance the other cues or become a valid
    -- aggregate pose merely because a previously seeded phase still exists.
    if not crank.valid then
        self:reset()
        return {valid = false, advanced = false, reset = true, issue = crank.issue}
    end
    self.crank = crank.state
    local air = P.step_air_extension(self.air_extension, seconds, sample.airborne)
    self.air_extension = air.blend
    local landing = P.step_landing(self.compression, seconds, sample.serial, sample.supported, sample.evidence)
    self.compression = landing.compression
    local wheels = type(sample.wheels) == "table" and sample.wheels or {}
    local posture = P.step_posture(self.posture, {seconds = seconds, serial = sample.serial,
        supported = wheels.supported, normal_available = wheels.normal_available, normal = wheels.normal,
        forward = sample.forward})
    -- A presentation refusal clears only the cue; it never parks the bike.
    if posture.valid then
        self.posture, self.posture_available = posture.state, true
    else
        self.posture, self.posture_available = P.posture_state(), false
    end
    local articulation, why = P.articulation(self.crank, sample.raw_crank_phase, sample.base_articulation)
    local offsets
    if articulation then
        offsets, why = P.rider_offsets({posture = self.posture_available and self.posture or nil,
            compression = self.compression, air_extension = self.air_extension}, {orientation = sample.orientation,
            release = sample.release, movement_phase = sample.movement_phase, preload = sample.preload,
            airborne = sample.airborne, scale = sample.scale})
    end
    if seconds > 0 then self.identity, self.serial = identity_copy(sample.identity), sample.serial end
    local out = {valid = offsets ~= nil, advanced = seconds > 0, reset = reset, issue = why,
        articulation = articulation, rider = offsets and {hip_offset = offsets.hip_offset,
            torso_offset = offsets.torso_offset} or nil,
        gaze_counterpitch = offsets and offsets.gaze_counterpitch or 0,
        crank = crank, posture = posture, landing = landing, air = air,
        posture_available = self.posture_available}
    if seconds > 0 then self.last = out end
    return out
end

return table.freeze(P)

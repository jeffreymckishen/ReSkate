-- Optional stage for the bike's existing single visual owner. One measured
-- frame goes through the tracked trick adapter once; its model targets plus
-- the owner's base articulation become the eight authored part matrices, in
-- bike_geometry.blueprints order. It writes no entity and never substitutes a
-- neutral pose when the adapter refuses a frame: a refusal carries no matrices.
local Runtime = require("./trick_runtime")
local Frame = require("./frame_identity")
local Visual = require("./bike_visual")
local G = require("./bike_geometry")
local Presentation = {}
local PARTS = 8
assert(#G.blueprints == PARTS, "bike_visual places exactly eight authored parts")
-- bike_visual refuses a root past 999990. Refuse the measured COM a little
-- inside that before the adapter runs, so a frame that cannot be presented
-- also cannot advance the trick model (or settle a landing) first.
local POSITION_BOUND = 999000
-- The adapter bounds its own angle targets to 10000 rad; base angles match.
local ANGLE_BOUND = 10000
local base_names = {"steer", "front_wheel_phase", "rear_wheel_phase", "crank_phase"}
-- trick_runtime's scalar_source list: the source fields its binding copies.
local source_names = {"generation", "user", "sequence", "source_epoch", "context_generation",
    "observation_serial", "observed_ms", "packet"}
local ORIGIN = table.freeze({0, 0, 0})
local UNROTATED = table.freeze({0, 0, 0, 1})

local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function plain(v) return type(v) == "table" and getmetatable(v) == nil end
local function same_number(a, b) return a == b and (a ~= 0 or 1 / a == 1 / b) end
local function refuse(issue, fresh) return {valid = false, fresh = fresh == true, issue = issue} end
-- A result's targets belong to the whole read the adapter stepped: the body,
-- physics epoch, input lease, serial, time, step and source read its binding
-- names, not just the physics serial. present() places a result another owner
-- kept, so a binding that names another read, or leaves part of one out, is
-- refused. Fields are read raw, so a metatable runs nothing; handles compare
-- by reference and uint64 strings stay strings. A copied or frozen binding
-- with extra owner fields is still the same read.
local function binding_matches(bound, frame)
    if not plain(bound) or not rawequal(rawget(bound, "physics_epoch"), frame.physics_epoch)
        or not rawequal(rawget(bound, "body_handle"), frame.body_handle)
        or not rawequal(rawget(bound, "lease_handle"), frame.source.lease_handle)
        or rawget(bound, "serial") ~= frame.serial or not same_number(rawget(bound, "time"), frame.time)
        or not same_number(rawget(bound, "seconds"), frame.seconds) then return false end
    local source = rawget(bound, "source")
    if not plain(source) or not rawequal(rawget(source, "lease_handle"), frame.source.lease_handle) then return false end
    for _, name in ipairs(source_names) do
        local actual, expected = rawget(source, name), frame.source[name]
        if type(expected) == "number" then
            if not same_number(actual, expected) then return false end
        elseif actual ~= expected then return false end
    end
    return true
end
-- The base articulation (steer, wheel and crank phases) belongs to whoever
-- presents the riding bike. It must name this exact read, so a stale pose from
-- an earlier frame cannot be dressed with the current trick targets.
local function base_copy(raw, frame)
    if not plain(raw) or not rawequal(rawget(raw, "physics_epoch"), frame.physics_epoch) then return nil end
    local out = {}
    for _, name in ipairs(base_names) do
        local n = rawget(raw, name)
        if not finite(n) or math.abs(n) > ANGLE_BOUND then return nil end
        out[name] = n
    end
    return out
end
-- Frame.copy reads raw fields only, so a hostile metatable runs nothing.
local function measured(raw_frame, base_pose)
    local frame, why = Frame.copy(raw_frame)
    if not frame then return nil, why end
    local p = frame.sample.position
    if math.abs(p.x) > POSITION_BOUND or math.abs(p.y) > POSITION_BOUND or math.abs(p.z) > POSITION_BOUND then
        return nil, "visual_position_unavailable"
    end
    local base = base_copy(base_pose, frame)
    if not base then return nil, "base_pose_unavailable" end
    return frame, base
end
local function matrices_valid(m)
    if type(m) ~= "table" or #m ~= PARTS then return false end
    for part = 1, PARTS do
        local matrix = m[part]
        if type(matrix) ~= "table" or #matrix ~= 16 then return false end
        for i = 1, 16 do if not finite(matrix[i]) then return false end end
    end
    return true
end
-- Places one adapter step result for this exact frame. The second return is
-- true when the result itself is unusable, which the stage treats as a fault
-- to cancel. An adapter refusal is passed on as it is: the adapter already
-- cancelled itself. cancelled says the adapter's generation moved during the
-- step. The adapter still reports a duplicate measurement under a changed
-- source or gate as duplicate_frame after cancelling its model for it, so
-- this is the only way to tell that duplicate from a harmless one.
local function place(frame, base, trick, cancelled)
    -- public_snapshot is the adapter's own shape check: plain fields, a
    -- model-only target set and finite bounded angles, without opaque handles.
    local public = plain(trick) and Runtime.public_snapshot(trick)
    if not public then return refuse("trick_result_unavailable"), true end
    if not public.valid then return refuse(public.issue, public.fresh) end
    if not public.visual_targets then
        -- The adapter's duplicate is the only valid result without targets.
        if public.issue ~= "duplicate_frame" or public.fresh or public.advanced then
            return refuse("trick_result_unavailable"), true
        end
        -- A duplicate read has nothing new to show. The owner may keep what it
        -- placed only while the model still runs; after a cancel it must not
        -- leave the old trick pose up.
        return refuse(cancelled and "duplicate_frame_cancelled" or "duplicate_frame", false)
    end
    local bound = rawget(trick, "binding")
    if not public.fresh or not public.advanced or public.serial ~= frame.serial
        or not same_number(public.time, frame.time) or not binding_matches(bound, frame) then
        return refuse("trick_frame_mismatch"), true
    end
    local t = public.visual_targets
    local pose = {steer = base.steer, front_wheel_phase = base.front_wheel_phase,
        rear_wheel_phase = base.rear_wheel_phase, crank_phase = base.crank_phase + t.movement_crank_angle,
        barspin = t.barspin, tailwhip = t.tailwhip,
        movement_bike_pitch = t.movement_bike_pitch, movement_bike_roll = t.movement_bike_roll}
    for _, angle in pairs(pose) do if not finite(angle) then return refuse("invalid_presentation"), true end end
    -- offsets are each part's articulation in the authored bike frame, so
    -- world = [measured rotation | root] * offset; a neutral pose gives the
    -- identity for every part. matrices are those offsets placed at the
    -- measured pose by bike_visual, the same placement bike_spawn uses.
    local placed_offsets, offsets = pcall(Visual.matrices, ORIGIN, UNROTATED, pose)
    local placed, matrices = pcall(Visual.from_sample, frame.sample, pose)
    if not placed_offsets or not placed or not matrices_valid(offsets) or not matrices_valid(matrices) then
        return refuse("visual_transform_unavailable"), true
    end
    return {valid = true, fresh = true, issue = public.issue, serial = frame.serial, time = frame.time,
        binding = bound, blueprints = table.clone(G.blueprints), pose = pose, offsets = offsets,
        matrices = matrices, trick = trick}
end

-- Pure placement of a result some other owner already stepped (the Ride
-- coordinator steps one adapter per frame). It steps and cancels nothing, so
-- unlike prepare it cannot keep a bad visual frame away from that model, and
-- it cannot see the adapter's generation: a duplicate that cancelled the
-- model reaches it as a plain duplicate_frame.
function Presentation.present(raw_frame, trick, base_pose)
    local frame, base = measured(raw_frame, base_pose)
    if not frame then return refuse(base) end
    return (place(frame, base, trick, false))
end

local function stage(runtime)
    local object = {}
    local function cancel(issue) runtime:cancel(issue); return refuse(issue) end
    local function generation()
        local status = runtime:status()
        return plain(status) and rawget(status, "generation") or nil
    end
    function object:prepare(raw_frame, contact, actions, base_pose)
        local frame, base = measured(raw_frame, base_pose)
        if not frame then return cancel(base) end
        local before = generation()
        -- The tracked adapter catches its own errors; a step that throws
        -- anyway is an unusable result like any other.
        local stepped, trick = pcall(runtime.step, runtime, raw_frame, contact, actions)
        local out, fault = place(frame, base, stepped and trick or nil, generation() ~= before)
        if fault then return cancel(out.issue) end
        -- Everything a successful prepare returns is built for this call, so
        -- the owner may keep or change it without reaching the adapter.
        return out
    end
    function object:cancel(reason) return runtime:cancel(reason) end
    function object:status() return runtime:status() end
    return table.freeze(object)
end

function Presentation.new(settings) return stage(Runtime.new(settings)) end
-- The same stage over an adapter the caller already holds, so a caller that
-- owns one need not run a second, diverging model. That adapter must then be
-- stepped only through prepare. The tests use it to hand the stage an
-- adapter whose results are broken; the tracked adapter is not known to
-- return one.
function Presentation.over(runtime)
    assert(plain(runtime) and type(rawget(runtime, "step")) == "function"
        and type(rawget(runtime, "cancel")) == "function" and type(rawget(runtime, "status")) == "function",
        "a plain trick adapter with step, cancel and status required")
    return stage(runtime)
end
return table.freeze(Presentation)

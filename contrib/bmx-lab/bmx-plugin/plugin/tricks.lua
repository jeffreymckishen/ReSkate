-- Pure Luau BMX trick policy, ported from Engine/Game/BMX/bmx_tricks.h.
-- Inputs must be measured observations. This module applies no physical motion,
-- changes no native score, and cannot turn input intent into a contact receipt.
local catalog = require("./catalog")
local motions = require("./motions")
local Tricks, Controller = {}, {}
Controller.__index = Controller
local pi, tau, maximum_count = math.pi, 2 * math.pi, 9007199254740991
local defaults = {
    bar_seconds = .45, tail_seconds = .55, catch_window = .12, catch_blend = .06,
    landing_tolerance = 35 * pi / 180, max_sample_seconds = .10, max_yaw_rate = 20,
    max_air_seconds = 15, landing_settle_seconds = .06, landing_gap_seconds = .04,
    minimum_body_up_alignment = .5, minimum_support_up_alignment = .15, maximum_closing_speed = 7,
}
local bounds = {
    bar_seconds = { .15, 1 }, tail_seconds = { .15, 1 }, catch_window = { .02, .30 },
    catch_blend = { .01, .20 }, landing_tolerance = { .05, pi / 3 }, max_sample_seconds = { .01, .10 },
    max_yaw_rate = { 1, 30 }, max_air_seconds = { 1, 30 }, landing_settle_seconds = { .01, .50 },
    landing_gap_seconds = { 0, .10 }, minimum_body_up_alignment = { .1, 1 },
    minimum_support_up_alignment = { .05, 1 }, maximum_closing_speed = { .1, 50 },
}
local function finite(v)
    return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end
local function clamp(v, low, high) return math.max(low, math.min(high, v)) end
local function smooth(t) return t * t * (3 - 2 * t) end
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end
local function add(value, amount) return value + math.min(maximum_count - value, amount) end
local function turns(angle, period) return math.floor(math.abs(angle) / period + .5) end
local function channel()
    return { armed = false, rotating = false, waiting = false, caught = false, failed = false,
        attempted = false, direction = 0, elapsed = 0, catch_elapsed = 0, blend_remaining = 0,
        origin = 0, angle = 0, release = 0, count = 0, started_at = 0, directional_counts = { 0, 0 } }
end
local function movement()
    local out = { id = catalog.none, armed = false, active = false, holding = false, recovering = false,
        waiting = false, caught = false, failed = false, attempted = false, elapsed = 0,
        recover_elapsed = 0, catch_elapsed = 0, phase = 0, progress = 0, release = 0, count = 0,
        started_at = 0, hold_seconds = 0, counts = {} }
    for id = 0, 79 do out.counts[id] = 0 end
    return out
end
local function tally()
    local out = { landed_combos = 0, landed_barspins = 0, landed_tailwhips = 0, landed_spin_half_turns = 0,
        failed_combos = 0, canceled_combos = 0, landed_units = 0, best_combo_units = 0,
        landed_movements = 0, landed_by_id = {}, landed_front_flips = 0, landed_back_flips = 0, landed_barrel_rolls = 0 }
    for id = 0, 79 do out.landed_by_id[id] = 0 end
    return out
end
local function state()
    return { airborne = false, air_seconds = 0, bar_angle = 0, tail_angle = 0, spin_radians = 0,
        bar_release = 0, tail_release = 0, bar_rotating = false, tail_rotating = false,
        bar_waiting_catch = false, tail_waiting_catch = false, bar_caught = false, tail_caught = false,
        pending_barspins = 0, pending_tailwhips = 0, pending_spin_half_turns = 0, pending_units = 0,
        failure = "none", tally = tally(), landing_pending = false, landing_hold_active = false,
        landing_hold_elapsed_seconds = 0, landing_support_seconds = 0, landing_gap_seconds = 0,
        movement_id = catalog.none, movement_phase = 0, movement_progress = 0, movement_release = 0,
        movement_bar_angle = 0, movement_tail_angle = 0, movement_crank_angle = 0,
        movement_bike_pitch = 0, movement_bike_roll = 0, release_left_hand = 0, release_right_hand = 0,
        release_left_foot = 0, release_right_foot = 0, movement_holding = false, movement_recovering = false,
        movement_caught = false, pending_movements = 0, flip_radians = 0, roll_radians = 0,
        pending_front_flips = 0, pending_back_flips = 0, pending_barrel_rolls = 0, movement_recovery_progress = 0 }
end
local function events()
    return { took_off = false, landed = false, combo_landed = false, failed = false, canceled = false,
        bar_caught = false, tail_caught = false, barspins = 0, tailwhips = 0, spin_half_turns = 0,
        units = 0, failure = "none", movement_caught = false, movements = 0,
        front_flips = 0, back_flips = 0, barrel_rolls = 0 }
end

function Tricks.input(source)
    local out = { enabled = false, grounded = true, owner = "", device = 0,
        barspin = "none", tailwhip = "none", bar_neutral = false, rear_neutral = false,
        body_yaw = 0, travel_yaw = 0, landing_quality_available = false,
        landing_settle_hold = false, landing_settle_hold_invalid = false,
        body_up_alignment = 1, support_up_alignment = 1, closing_normal_speed = 0,
        movement = catalog.none, orientation_available = false, body_quaternion = { 0, 0, 0, 1 } }
    for k in pairs(out) do if source and source[k] ~= nil then out[k] = source[k] end end
    return out
end
local function sanitize(source)
    local out = {}
    for k, fallback in pairs(defaults) do
        local v = source and source[k]
        out[k] = clamp(finite(v) and v or fallback, bounds[k][1], bounds[k][2])
    end
    return out
end
function Controller:settings() return copy(self._settings) end
function Controller:state() return copy(self._state) end
function Controller:_attempted()
    return self._bar.attempted or self._tail.attempted or self._spin_attempted
        or self._movement.attempted or self._flip_attempted or self._roll_attempted
end
function Controller:_clear_live(failure)
    local saved = self._state and self._state.tally or tally()
    self._state = state(); self._state.tally = saved; self._state.failure = failure or "none"
    self._bar, self._tail, self._movement = channel(), channel(), movement()
    self._ground_seen, self._spin_attempted, self._previous_yaw = false, false, 0
    self._full_orientation, self._flip_attempted, self._roll_attempted = false, false, false
    self._previous_quaternion = { 0, 0, 0, 1 }
    self._landing_pending, self._landing_seconds, self._landing_gap, self._landing_elapsed = false, 0, 0, 0
    self._hold_started, self._holding, self._hold_start = false, false, 0
    self._sequence, self._sequence_overflow, self._fakie_takeoff = {}, false, false
end
function Controller:_cancel_live(failure)
    local pending = self._state.airborne and self:_attempted()
    if pending then self._state.tally.canceled_combos = add(self._state.tally.canceled_combos, 1) end
    self:_clear_live(failure)
    return pending
end
function Controller:cancel() self:_cancel_live("canceled") end
function Controller:reset()
    self._state = state(); self:_clear_live()
    self._identity_known, self._owner, self._device = false, "", 0
end
function Tricks.new(settings)
    local out = setmetatable({ _settings = sanitize(settings) }, Controller)
    out:reset()
    return out
end
function Controller:_sync()
    local s, b, t, m = self._state, self._bar, self._tail, self._movement
    s.bar_angle, s.tail_angle, s.bar_release, s.tail_release = b.angle, t.angle, b.release, t.release
    s.bar_rotating, s.tail_rotating, s.bar_waiting_catch, s.tail_waiting_catch = b.rotating, t.rotating, b.waiting, t.waiting
    s.bar_caught, s.tail_caught, s.pending_barspins, s.pending_tailwhips = b.caught, t.caught, b.count, t.count
    s.pending_spin_half_turns = self._spin_attempted and turns(s.spin_radians, pi) or 0
    local flips = self._flip_attempted and turns(s.flip_radians, tau) or 0
    s.pending_front_flips, s.pending_back_flips = s.flip_radians > 0 and flips or 0, s.flip_radians < 0 and flips or 0
    s.pending_barrel_rolls = self._roll_attempted and turns(s.roll_radians, tau) or 0
    s.pending_movements = m.count
    s.pending_units = b.count + t.count + s.pending_spin_half_turns + m.count
        + s.pending_front_flips + s.pending_back_flips + s.pending_barrel_rolls
    s.landing_pending, s.landing_support_seconds, s.landing_gap_seconds = self._landing_pending, self._landing_seconds, self._landing_gap
    s.landing_hold_active = self._holding
    s.landing_hold_elapsed_seconds = self._hold_started and self._landing_elapsed - self._hold_start or 0
    s.movement_id, s.movement_phase, s.movement_progress, s.movement_release = m.id, m.phase, m.progress, m.release
    s.movement_holding, s.movement_recovering, s.movement_caught = m.holding, m.recovering, m.caught
    local entry = motions.find(m.id)
    s.movement_recovery_progress = m.recovering and entry and clamp(m.recover_elapsed / entry.recover_seconds, 0, 1) or 0
    local mask = entry and entry.release_mask or 0
    s.release_left_hand = mask % 2 >= 1 and m.release or 0
    s.release_right_hand = math.floor(mask / 2) % 2 >= 1 and m.release or 0
    s.release_left_foot = math.floor(mask / 4) % 2 >= 1 and m.release or 0
    s.release_right_foot = math.floor(mask / 8) % 2 >= 1 and m.release or 0
    local turn = smooth(m.progress) * tau
    s.movement_bar_angle = entry and entry.bar_turns * turn + entry.bar_pose_radians * m.phase or 0
    s.movement_tail_angle, s.movement_crank_angle = entry and entry.tail_turns * turn or 0, entry and entry.crank_turns * turn or 0
    s.movement_bike_pitch, s.movement_bike_roll = 0, 0
    if entry then
        local pose = entry.motion == "pose" and m.phase or smooth(m.progress)
        s.movement_bike_pitch, s.movement_bike_roll = entry.bike_pitch * pose, entry.bike_roll * pose
        if entry.family == "grand_slam" then s.movement_bike_roll = entry.bike_roll * math.sin(tau * smooth(m.progress)) end
        if entry.family == "bri_flip" then s.movement_bike_pitch = entry.bike_pitch * math.sin(tau * smooth(m.progress)) end
    end
end
function Controller:_record(kind, id, dir, started, finished, hold)
    -- Only catches enter this bounded log. Keep it outside state(), which the
    -- adapter copies twice each step; landing publishes its detached snapshot.
    if #self._sequence == 16 then self._sequence_overflow = true; return end
    local row = {kind = kind, id = id, dir = dir, start = started, finish = finished, hold = hold}
    local index = #self._sequence + 1
    while index > 1 and self._sequence[index - 1].start > started do
        self._sequence[index] = self._sequence[index - 1]; index = index - 1
    end
    self._sequence[index] = row
end
function Controller:_movement_channel(request, neutral, seconds)
    local m = self._movement
    if neutral and request == catalog.none then m.armed = true end
    if request ~= catalog.none and not catalog.legacy_rotation(request) then
        local start = m.armed and not m.active and not m.failed and not self._bar.rotating
            and not self._bar.waiting and not self._tail.rotating and not self._tail.waiting
            and self._bar.release == 0 and self._tail.release == 0
        m.armed = false -- Busy requests are consumed, never queued.
        if start then
            m.id, m.active, m.attempted, m.caught = request, true, true, false
            m.holding, m.recovering, m.waiting = false, false, false
            m.elapsed, m.recover_elapsed, m.catch_elapsed, m.phase, m.progress, m.release = 0, 0, 0, 0, 0, 0
            m.started_at, m.hold_seconds = self._state.air_seconds, 0
            return false
        end
    end
    if not m.active or m.failed then return false end
    local entry = motions.find(m.id)
    if not entry then m.failed = true; return false end
    if m.recovering then
        m.recover_elapsed = math.min(entry.recover_seconds, m.recover_elapsed + seconds)
        local left = 1 - smooth(m.recover_elapsed / entry.recover_seconds)
        if entry.motion == "pose" then m.phase = left end
        m.release = left
        if m.recover_elapsed + 1e-9 < entry.recover_seconds then return false end
        m.active, m.recovering, m.caught, m.phase, m.release = false, false, true, 0, 0
        m.count, m.counts[m.id] = m.count + 1, m.counts[m.id] + 1
        self:_record("move", m.id, entry.direction, m.started_at,
            m.started_at + entry.enter_seconds + m.hold_seconds, m.hold_seconds)
        return true
    end
    if not m.holding and not m.waiting then
        m.elapsed = m.elapsed + seconds; m.progress = math.min(1, m.elapsed / entry.enter_seconds)
        m.phase = entry.motion == "pose" and smooth(m.progress) or math.sin(pi * m.progress)
        m.release = math.min(1, m.progress / .15)
        if m.progress < 1 then return false end
        if entry.motion == "pose" then
            m.holding, m.hold_seconds = true, math.max(0, m.elapsed - entry.enter_seconds)
        else m.waiting = true; m.catch_elapsed = math.max(0, m.elapsed - entry.enter_seconds) end
    elseif m.waiting then m.catch_elapsed = m.catch_elapsed + seconds
    elseif m.holding then m.hold_seconds = m.hold_seconds + seconds end
    if m.waiting and m.catch_elapsed > self._settings.catch_window + 1e-9 then
        m.failed, m.release = true, 1; return false
    end
    if neutral then m.holding, m.waiting, m.recovering, m.recover_elapsed = false, false, true, 0 end
    return false
end
function Controller:_channel(c, request, neutral, seconds, duration, allowed)
    if c.caught and c.blend_remaining > 0 then
        c.blend_remaining = math.max(0, c.blend_remaining - seconds)
        c.release = c.blend_remaining / self._settings.catch_blend
    end
    if neutral and request == "none" then c.armed = true end
    if request ~= "none" then
        local start = allowed and c.armed and not c.rotating and not c.waiting and not c.failed
        c.armed = false
        if start then
            c.attempted, c.rotating, c.caught, c.elapsed = true, true, false, 0
            c.catch_elapsed, c.blend_remaining, c.origin = 0, 0, c.angle
            c.direction = request == "left" and -1 or 1
            c.started_at = self._state.air_seconds
            return false -- Request arrived at the end of this sample.
        end
    end
    if c.failed then c.release = 1; return false end
    if c.rotating then
        c.elapsed = c.elapsed + seconds
        local progress = math.min(1, c.elapsed / duration)
        c.angle = c.origin + c.direction * tau * smooth(progress); c.release = math.min(1, progress / .10)
        if progress < 1 then return false end
        c.rotating, c.waiting, c.catch_elapsed = false, true, math.max(0, c.elapsed - duration)
    elseif c.waiting then c.catch_elapsed = c.catch_elapsed + seconds end
    if c.waiting then
        c.release = 1
        if c.catch_elapsed > self._settings.catch_window + 1e-9 then c.waiting, c.failed = false, true
        elseif neutral then
            c.waiting, c.caught, c.count = false, true, c.count + 1
            local index = c.direction < 0 and 1 or 2
            c.directional_counts[index] = c.directional_counts[index] + 1
            local bar = c == self._bar
            local id = bar and (c.direction < 0 and 34 or 44) or (c.direction < 0 and 56 or 52)
            self:_record(bar and "bar" or "tail", id, c.direction, c.started_at, c.started_at + duration, 0)
            c.blend_remaining = self._settings.catch_blend
            return true
        end
    end
    return false
end
function Controller:_landing_failure(input)
    local s, b, t, m = self._state, self._bar, self._tail, self._movement
    local failure = s.failure
    if failure == "none" and (b.rotating or t.rotating) then failure = "under_rotated" end
    if failure == "none" and (b.waiting or t.waiting or b.failed or t.failed) then failure = "uncaught" end
    if failure == "none" and m.active then failure = m.progress < 1 and "under_rotated" or "uncaught" end
    if failure == "none" and m.failed then failure = "uncaught" end
    local rotation, half = math.abs(s.spin_radians), turns(s.spin_radians, pi)
    if failure == "none" and self._spin_attempted and (half == 0 or math.abs(rotation - half * pi) > self._settings.landing_tolerance) then
        failure = "under_rotated"
    end
    local function complete(angle)
        local count = turns(angle, tau)
        return count > 0 and math.abs(math.abs(angle) - count * tau) <= self._settings.landing_tolerance
    end
    if failure == "none" and ((self._flip_attempted and not complete(s.flip_radians)) or (self._roll_attempted and not complete(s.roll_radians))) then
        failure = "under_rotated"
    end
    if failure == "none" and self:_attempted() and math.abs(math.cos(input.body_yaw - input.travel_yaw)) < math.cos(self._settings.landing_tolerance) then
        failure = "unaligned_landing"
    end
    return failure
end
local function valid_quality(input)
    return finite(input.body_up_alignment) and math.abs(input.body_up_alignment) <= 1.000001
        and finite(input.support_up_alignment) and math.abs(input.support_up_alignment) <= 1.000001
        and finite(input.closing_normal_speed) and input.closing_normal_speed >= 0 and input.closing_normal_speed <= 1e6
end
function Controller:_clean_quality(input)
    return input.body_up_alignment >= self._settings.minimum_body_up_alignment
        and input.support_up_alignment >= self._settings.minimum_support_up_alignment
        and input.closing_normal_speed <= self._settings.maximum_closing_speed
end
local function valid_orientation(q)
    if type(q) ~= "table" then return false end
    local length = 0
    for i = 1, 4 do if not finite(q[i]) then return false end; length = length + q[i] * q[i] end
    return math.abs(length - 1) <= .001
end
local function remainder(angle)
    if not finite(angle) then return 0 / 0 end
    -- Subtracting a rounded large quotient loses the remainder completely.
    -- Both signs of the exact pi tie exceed every accepted step-rate bound.
    local wrapped = math.fmod(angle, tau)
    if wrapped > pi then wrapped = wrapped - tau end
    if wrapped < -pi then wrapped = wrapped + tau end
    return wrapped
end
function Controller:_orientation_change(seconds, input)
    if input.orientation_available ~= self._full_orientation then return nil end
    if not self._full_orientation then
        local delta = remainder(input.body_yaw - self._previous_yaw)
        self._previous_yaw = input.body_yaw
        if not finite(delta) or math.abs(delta) > self._settings.max_yaw_rate * seconds + .05 then return nil end
        return { 0, delta, 0 }
    end
    local a, b = self._previous_quaternion, input.body_quaternion
    local r = { a[4]*b[1]-a[1]*b[4]-a[2]*b[3]+a[3]*b[2],
        a[4]*b[2]+a[1]*b[3]-a[2]*b[4]-a[3]*b[1],
        a[4]*b[3]-a[1]*b[2]+a[2]*b[1]-a[3]*b[4],
        a[4]*b[4]+a[1]*b[1]+a[2]*b[2]+a[3]*b[3] }
    if r[4] < 0 then for i = 1, 4 do r[i] = -r[i] end end
    local sine = math.sqrt(r[1]^2 + r[2]^2 + r[3]^2)
    local angle = 2 * math.atan2(sine, math.max(0, r[4]))
    if angle > self._settings.max_yaw_rate * seconds + .05 then return nil end
    local scale = sine > 1e-12 and angle / sine or 2
    self._previous_quaternion, self._previous_yaw = copy(b), input.body_yaw
    return { r[1] * scale, r[2] * scale, r[3] * scale }
end
function Controller:_land(input, forced)
    local event = events(); event.landed = true
    local failure = forced or self:_landing_failure(input)
    local s, b, t, m = self._state, self._bar, self._tail, self._movement
    -- Use the model's airborne clock, excluding contact/settle time. A failed
    -- landing still reports its completed parts, but the existing failed flag
    -- remains authoritative. Unknown landing quality never gets default numbers.
    event.air_seconds, event.spin_radians, event.flip_radians, event.roll_radians =
        s.air_seconds, s.spin_radians, s.flip_radians, s.roll_radians
    event.fakie_takeoff, event.sequence, event.overflow = self._fakie_takeoff, copy(self._sequence), self._sequence_overflow
    if input.landing_quality_available and valid_quality(input) then
        event.landing = {body_up = input.body_up_alignment,
            heading_cos = math.cos(input.body_yaw - input.travel_yaw), closing = input.closing_normal_speed}
    end
    if self:_attempted() and failure ~= "none" then
        event.failed, event.failure = true, failure; s.tally.failed_combos = add(s.tally.failed_combos, 1)
    elseif self:_attempted() then
        event.barspins, event.tailwhips, event.movements = b.count, t.count, m.count
        event.spin_half_turns = self._spin_attempted and turns(s.spin_radians, pi) or 0
        local flips = self._flip_attempted and turns(s.flip_radians, tau) or 0
        event.front_flips, event.back_flips = s.flip_radians > 0 and flips or 0, s.flip_radians < 0 and flips or 0
        event.barrel_rolls = self._roll_attempted and turns(s.roll_radians, tau) or 0
        event.units = event.barspins + event.tailwhips + event.movements + event.spin_half_turns
            + event.front_flips + event.back_flips + event.barrel_rolls
        event.combo_landed = event.units > 0
        if event.combo_landed then
            s.tally.landed_combos = add(s.tally.landed_combos, 1)
            for _, name in ipairs({ "barspins", "tailwhips", "movements", "spin_half_turns", "front_flips", "back_flips", "barrel_rolls", "units" }) do
                s.tally["landed_" .. name] = add(s.tally["landed_" .. name], event[name])
            end
            for id, count in pairs({ [34] = b.directional_counts[1], [44] = b.directional_counts[2], [56] = t.directional_counts[1], [52] = t.directional_counts[2] }) do
                s.tally.landed_by_id[id] = add(s.tally.landed_by_id[id], count)
            end
            for id = 0, 79 do s.tally.landed_by_id[id] = add(s.tally.landed_by_id[id], m.counts[id]) end
            s.tally.best_combo_units = math.max(s.tally.best_combo_units, event.units)
        end
    end
    self:_clear_live(event.failed and failure or "none")
    self._ground_seen, self._previous_yaw = true, input.body_yaw
    self._full_orientation, self._previous_quaternion = input.orientation_available, copy(input.body_quaternion)
    return event
end
local function owner_valid(owner)
    -- Never represent a native uint64 address/generation as a rounded Lua number.
    return (type(owner) == "string" and #owner > 0 and #owner <= 128)
        or (finite(owner) and owner > 0 and owner <= maximum_count and owner % 1 == 0)
end
local function direction_valid(v) return v == "none" or v == "left" or v == "right" end
function Controller:update(seconds, source)
    local event, input = events(), Tricks.input(source)
    local function cancel(failure)
        event.canceled = self:_cancel_live(failure); event.failure = failure
        return event
    end
    if not input.enabled or not owner_valid(input.owner) then
        event.canceled = self:_cancel_live("canceled"); event.failure = event.canceled and "canceled" or "none"
        return event
    end
    if self._identity_known and (self._owner ~= input.owner or self._device ~= input.device) then
        event.canceled = self:_cancel_live("canceled"); event.failure = event.canceled and "canceled" or "none"
        self._owner, self._device = input.owner, input.device
        return event
    end
    self._identity_known, self._owner, self._device = true, input.owner, input.device
    if not finite(seconds) or seconds < 0 or seconds > self._settings.max_sample_seconds + 1e-9
        or not finite(input.body_yaw) or not finite(input.travel_yaw) or not finite(input.body_yaw - input.travel_yaw)
        or not finite(input.device) or input.device < 0 or input.device > 4294967295 or input.device % 1 ~= 0
        or not direction_valid(input.barspin) or not direction_valid(input.tailwhip)
        or not catalog.valid(input.movement) or (input.orientation_available and not valid_orientation(input.body_quaternion)) then
        return cancel("invalid_sample")
    end
    for _, name in ipairs({ "enabled", "grounded", "bar_neutral", "rear_neutral", "landing_quality_available",
        "landing_settle_hold", "landing_settle_hold_invalid", "orientation_available" }) do
        if type(input[name]) ~= "boolean" then return cancel("invalid_sample") end
    end
    if seconds == 0 then return event end
    if self._landing_pending then
        self._landing_elapsed = self._landing_elapsed + seconds
        if not self:_orientation_change(seconds, input) or self._state.air_seconds + self._landing_elapsed > self._settings.max_air_seconds then
            return cancel("invalid_sample")
        end
        self._previous_yaw, self._holding = input.body_yaw, false
        if input.landing_settle_hold_invalid then return cancel("unstable_landing") end
        if not input.grounded then
            self._landing_seconds, self._landing_gap = 0, self._landing_gap + seconds
            if input.landing_settle_hold and not self._hold_started then
                self._hold_started, self._hold_start = true, self._landing_elapsed - seconds
            end
            local hold = input.landing_settle_hold and self._hold_started and self._landing_elapsed - self._hold_start <= .2 + 1e-9
            self._holding = hold
            if (self._hold_started and not hold) or (not hold and self._landing_gap > self._settings.landing_gap_seconds + 1e-9) then
                return cancel("unstable_landing")
            end
            self:_sync(); return event
        end
        if not input.landing_quality_available or not valid_quality(input) then return cancel("invalid_sample") end
        if not self:_clean_quality(input) then return self:_land(input, "unstable_landing") end
        if self:_landing_failure(input) ~= "none" then return self:_land(input) end
        local recontact = self._landing_gap > 0; self._landing_gap = 0
        if not recontact then self._landing_seconds = self._landing_seconds + seconds end
        if self._landing_seconds + 1e-9 >= self._settings.landing_settle_seconds then return self:_land(input) end
        self:_sync(); return event
    end
    local s = self._state
    if not s.airborne then
        if input.grounded then
            self._ground_seen, self._previous_yaw = true, input.body_yaw
            self._full_orientation, self._previous_quaternion = input.orientation_available, copy(input.body_quaternion)
            return event
        end
        if not self._ground_seen then return event end
        s.airborne, s.air_seconds, s.failure = true, 0, "none"
        self._bar, self._tail, self._movement = channel(), channel(), movement()
        self._spin_attempted, self._flip_attempted, self._roll_attempted, self._previous_yaw = false, false, false, input.body_yaw
        self._full_orientation, self._previous_quaternion = input.orientation_available, copy(input.body_quaternion)
        self._fakie_takeoff = math.cos(input.body_yaw - input.travel_yaw) < 0
        event.took_off = true
        self._bar.armed = input.bar_neutral and input.barspin == "none"
        self._tail.armed = input.rear_neutral and input.tailwhip == "none"
        self._movement.armed = input.rear_neutral and input.movement == catalog.none
        self:_sync(); return event
    end
    local change = self:_orientation_change(seconds, input)
    if not change then return cancel("invalid_sample") end
    self._previous_yaw = input.body_yaw
    s.spin_radians, s.flip_radians, s.roll_radians = s.spin_radians + change[2], s.flip_radians + change[1], s.roll_radians + change[3]
    self._spin_attempted = self._spin_attempted or math.abs(s.spin_radians) >= pi / 2
    self._flip_attempted = self._flip_attempted or math.abs(s.flip_radians) >= pi / 2
    self._roll_attempted = self._roll_attempted or math.abs(s.roll_radians) >= pi / 2
    if input.grounded then -- Contact cannot finish rotation or catch an airborne trick.
        if self:_landing_failure(input) ~= "none" or not input.landing_quality_available then return self:_land(input) end
        if not valid_quality(input) then return cancel("invalid_sample") end
        if not self:_clean_quality(input) then return self:_land(input, "unstable_landing") end
        self._landing_pending, self._landing_seconds, self._landing_gap, self._landing_elapsed = true, 0, 0, 0
        self._hold_started, self._holding, self._hold_start = false, false, 0
        self:_sync(); return event
    end
    s.air_seconds = s.air_seconds + seconds
    if s.air_seconds > self._settings.max_air_seconds then return cancel("invalid_sample") end
    local movement_busy = self._movement.active
    event.bar_caught = self:_channel(self._bar, input.barspin, input.bar_neutral, seconds, self._settings.bar_seconds, not movement_busy)
    event.tail_caught = self:_channel(self._tail, input.tailwhip, input.rear_neutral, seconds, self._settings.tail_seconds, not movement_busy)
    event.movement_caught = self:_movement_channel(input.movement, input.rear_neutral, seconds)
    if (self._movement.failed or self._bar.failed or self._tail.failed) and s.failure == "none" then s.failure = "uncaught" end
    self:_sync()
    return event
end
return Tricks

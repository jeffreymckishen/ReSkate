-- Authored manual / nose-manual balance policy. Pure: it owns no SDK object,
-- makes no reskate.* call and runs nothing on require. Its manual/nose_manual
-- outputs are force-control requests that forces.lua reads as a fraction of its
-- manual_pitch tuning (forces.lua:210-215); nothing here proves a body moved.
-- The model and every constant are our own (MANUAL_BALANCE.md), not BMX Streets.
-- Pitch is nose-up positive radians against the support plane. "Lift" is that
-- pitch signed per kind, so the lifted wheel rising is always positive.
local Balance = {}
local Model = {}
Model.__index = Model

local defaults = {
    manual_pitch = 0.4,
    neutral_input = 0.02, engage_input = 0.08, sweet_spot = 0.5, sweet_spot_width = 0.3,
    manual_balance_point = 0.22, manual_loop_out = 0.36, manual_drop = 0.04,
    nose_balance_point = 0.16, nose_over = 0.3, nose_drop = 0.03,
    entry_rate = 1.4, entry_seconds = 1.0, entry_window = 0.05,
    climb_rate = 0.5, fall_rate = 0.6, instability = 0.6,
    min_entry_speed = 1.0, stall_speed = 0.6, stall_fall_rate = 0.5,
    band_full_speed = 4.0, band_min_scale = 0.5,
    lift_gain = 2.0, rate_gain = 0.3, settle_gain = 3.0, settle_limit = 0.3,
    airborne_grace = 0.05, max_step_seconds = 0.05,
}

-- Manual lifts the front on the rear wheel; nose manual lifts the rear on the
-- front wheel. They share the law but keep separate angles and end reasons.
local kinds = {
    manual = { sign = 1, balance = "manual_balance_point", over = "manual_loop_out", drop = "manual_drop",
        over_reason = "loop_out", drop_reason = "front_drop", lifted = "front_support", base = "rear_support" },
    nose_manual = { sign = -1, balance = "nose_balance_point", over = "nose_over", drop = "nose_drop",
        over_reason = "nose_over", drop_reason = "rear_drop", lifted = "rear_support", base = "front_support" },
}

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function copy(source)
    local result = {}
    for key, value in pairs(source) do result[key] = value end
    return result
end

local function sanitize(source)
    source = type(source) == "table" and source or {}
    local result = {}
    local function bounded(name, low, high)
        local value = source[name]
        return clamp(finite(value) and value or defaults[name], low, high)
    end
    -- forces.lua refuses manual_pitch above 0.6, so the conversion must too.
    result.manual_pitch = bounded("manual_pitch", 0.05, 0.6)
    result.neutral_input = bounded("neutral_input", 0, 0.2)
    result.engage_input = bounded("engage_input", result.neutral_input + 0.02, 0.5)
    -- The sweet spot must sit wholly between engagement and full stick, or a
    -- shallow pull could hold a manual and a full pull could never climb.
    result.sweet_spot_width = bounded("sweet_spot_width", 0.05, math.min(0.8, 0.97 - result.engage_input))
    result.sweet_spot = bounded("sweet_spot", result.engage_input + result.sweet_spot_width * 0.5 + 0.01,
        0.99 - result.sweet_spot_width * 0.5)
    local window = 0.2
    -- Keep headroom above the balance point so the command can settle against
    -- gravity sag without saturating at manual_pitch. Below a manual_pitch of
    -- 0.0625 that ceiling is under the usual 0.05 floor, so the floor gives way
    -- to it; otherwise the clamp inverts and the point lands on manual_pitch.
    local ceiling = 0.8 * result.manual_pitch
    local floor = math.min(0.05, ceiling)
    for _, spec in pairs(kinds) do
        result[spec.balance] = bounded(spec.balance, floor, ceiling)
        result[spec.over] = bounded(spec.over, result[spec.balance] + 0.04, 1.2)
        result[spec.drop] = bounded(spec.drop, 0, result[spec.balance] - 0.04)
        window = math.min(window, result[spec.balance] - result[spec.drop] - 0.01)
    end
    result.entry_rate = bounded("entry_rate", 0.2, 6)
    result.entry_seconds = bounded("entry_seconds", 0.1, 2)
    -- The entry window may not reach the drop angle, or balancing could begin
    -- already ended.
    result.entry_window = bounded("entry_window", 0.005, window)
    result.climb_rate = bounded("climb_rate", 0, 4)
    result.fall_rate = bounded("fall_rate", 0, 4)
    result.instability = bounded("instability", 0, 5)
    result.stall_speed = bounded("stall_speed", 0, 5)
    result.min_entry_speed = bounded("min_entry_speed", result.stall_speed, 10)
    result.stall_fall_rate = bounded("stall_fall_rate", 0, 4)
    result.band_full_speed = bounded("band_full_speed", 0.1, 30)
    result.band_min_scale = bounded("band_min_scale", 0.1, 1)
    result.lift_gain = bounded("lift_gain", 0, 4)
    result.rate_gain = bounded("rate_gain", 0, 0.5)
    result.settle_gain = bounded("settle_gain", 0, 20)
    result.settle_limit = bounded("settle_limit", 0, 0.4)
    result.airborne_grace = bounded("airborne_grace", 0, 0.25)
    result.max_step_seconds = bounded("max_step_seconds", 0.005, 0.1)
    return result
end

local function optional(value, fallback)
    if value == nil then return fallback end
    return value
end

-- Returns a validated copy, or nil. Out-of-range stick values are refused
-- rather than clamped: a negative manual usually means a sign error upstream.
local function read(sample)
    if type(sample) ~= "table" then return nil end
    local input = {
        manual = sample.manual, nose_manual = sample.nose_manual, preload = optional(sample.preload, 0),
        pitch = sample.pitch, pitch_rate = sample.pitch_rate, speed = sample.speed,
        front_support = sample.front_support, rear_support = sample.rear_support,
        hop = optional(sample.hop, false), rear_neutral = optional(sample.rear_neutral, true),
    }
    for _, name in ipairs({ "manual", "nose_manual", "preload" }) do
        local value = input[name]
        if not finite(value) or value < 0 or value > 1 then return nil end
    end
    if not finite(input.pitch) or math.abs(input.pitch) > math.pi
        or not finite(input.pitch_rate) or math.abs(input.pitch_rate) > 50
        or not finite(input.speed) or math.abs(input.speed) > 100 then return nil end
    -- Riding backwards is still rolling, so entry, the hold band and the stall
    -- read the speed's magnitude. The kinds, wheels and pitch signs follow the
    -- bike, not the travel direction.
    input.speed = math.abs(input.speed)
    for _, name in ipairs({ "front_support", "rear_support", "hop", "rear_neutral" }) do
        if type(input[name]) ~= "boolean" then return nil end
    end
    return input
end

function Model:_clear_balance()
    self._target, self._integral, self._elapsed, self._unsupported = 0, 0, 0, 0
end

-- Every state change goes through here, so each one yields exactly one event.
function Model:_transition(to, reason, bail)
    local from = self._state
    self._state = to
    self._sequence = self._sequence + 1
    return { name = to, from = from, to = to, kind = self._kind or "none", reason = reason or "none",
        bail_request = bail == true, sequence = self._sequence }
end

function Model:_end(reason, bail)
    local event = self:_transition("ended", reason, bail)
    self._end_reason, self._bail_pending, self._armed = reason, bail == true, false
    self:_clear_balance()
    return event
end

function Model:_output(valid, issue, fraction, event, measured)
    local kind = self._kind
    local active = self._state == "entering" or self._state == "balancing"
    local out = {
        valid = valid, issue = issue, state = self._state, kind = kind or "none",
        manual = 0, nose_manual = 0, balance_point = 0, lift = 0, target = 0, balance = 0,
        armed = self._armed, end_reason = self._end_reason, bail_request = event ~= nil and event.bail_request,
        event = event, scope = "model_request_only", realized = false,
    }
    if active then
        local spec, s = kinds[kind], self._settings
        local point, lift = s[spec.balance], measured or 0
        out[kind] = fraction
        out.balance_point, out.lift, out.target = point, lift, self._target
        -- A meter for presentation: -1 at the drop angle, +1 at over-rotation.
        if lift >= point then out.balance = clamp((lift - point) / (s[spec.over] - point), 0, 1)
        else out.balance = -clamp((point - lift) / (point - s[spec.drop]), 0, 1) end
    end
    return out
end

-- Cancels an active attempt and consumes the arm. Idle and ended keep their
-- state; ended still leaves through a neutral observation like any other end.
function Model:_cancel()
    local event
    if self._state == "entering" or self._state == "balancing" then event = self:_end("cancelled", false) end
    self._armed, self._context_known = false, false
    self:_clear_balance()
    return event
end

function Model:settings()
    return copy(self._settings)
end

function Model:configure(settings)
    self._settings = sanitize(settings)
    return self:_cancel()
end

function Model:cancel()
    return self:_cancel()
end

function Model:status()
    return { state = self._state, kind = self._kind or "none", armed = self._armed,
        end_reason = self._end_reason, bail_pending = self._bail_pending, target = self._target,
        integral = self._integral, steps = self._steps, sequence = self._sequence }
end

function Balance.new(settings)
    local model = setmetatable({ _settings = sanitize(settings), _state = "idle", _armed = false,
        _context_known = false, _grounded = false, _end_reason = "none", _bail_pending = false,
        _steps = 0, _sequence = 0 }, Model)
    model:_clear_balance()
    return model
end

-- The stick-depth band that holds the lift. It narrows at low speed, where a
-- rolling manual is harder to keep.
local function band(s, speed)
    local half = s.sweet_spot_width * 0.5 * clamp(speed / s.band_full_speed, s.band_min_scale, 1)
    return s.sweet_spot - half, s.sweet_spot + half
end

-- Returns true while entering once the ramp has reached its goal.
function Model:_advance_target(input, own, entering, dt)
    local s, spec = self._settings, kinds[self._kind]
    local point = s[spec.balance]
    local low, high = band(s, input.speed)
    -- A hop charge from a manual uses the same stick, so input.lua reports no
    -- manual while it charges. Holding the lift keeps the pop off a raised wheel.
    if input.preload > 0 then return false end
    if entering then
        -- Ramp toward the balance point. A shallow pull aims lower and may
        -- never lift the wheel; a deep pull only starts climbing once the
        -- lift is balancing, so the pop itself cannot loop out.
        local goal = point
        if own < low then goal = point * clamp((own - s.engage_input) / (low - s.engage_input), 0, 1) end
        local step = s.entry_rate * dt
        if self._target < goal then self._target = math.min(goal, self._target + step)
        elseif self._target > goal then self._target = math.max(goal, self._target - step) end
        return self._target == goal
    else
        local rate = 0
        if own > high then rate = s.climb_rate * (own - high) / (1 - high)
        elseif own < low then rate = -s.fall_rate * (low - own) / low end
        if input.speed < s.stall_speed and s.stall_speed > 0 then
            rate = rate - s.stall_fall_rate * math.min(1, (s.stall_speed - input.speed) / s.stall_speed)
        end
        -- The tipping term: away from the balance point the lift drifts
        -- further away, so a held lift needs small corrections. It is zero at
        -- the balance point itself, which an in-band entry reaches exactly.
        rate = rate + s.instability * (self._target - point)
        self._target = math.max(0, self._target + rate * dt)
    end
    return false
end

-- Closed loop on the measured lift: forces.lua holds whatever it is asked
-- for, minus gravity sag, so the integral term removes the sag and the rate
-- term adds damping. Integration waits for the lifted wheel to leave the
-- ground and stops while the command is saturated in the error's direction.
function Model:_command(lift, lift_rate, lifted_clear, dt)
    local s = self._settings
    local error = self._target - lift
    local command = self._target + s.lift_gain * error + self._integral - s.rate_gain * lift_rate
    local limit = s.manual_pitch
    if lifted_clear and not (command >= limit and error > 0) and not (command <= 0 and error < 0) then
        self._integral = clamp(self._integral + s.settle_gain * error * dt, -s.settle_limit, s.settle_limit)
    end
    return clamp(command, 0, limit) / limit
end

function Model:_invalid(issue)
    return self:_output(false, issue, 0, self:_cancel())
end

-- sample: manual, nose_manual and optional preload in [0,1] (input.lua
-- actions); pitch and pitch_rate (nose-up positive); front_support and
-- rear_support; signed forward speed in m/s, read as a magnitude; optional
-- hop and rear_neutral booleans.
-- dt is the native step in seconds.
function Model:step(sample, dt)
    self._steps = self._steps + 1
    local s = self._settings
    if not finite(dt) or dt <= 0 or dt > s.max_step_seconds then return self:_invalid("invalid_dt") end
    local input = read(sample)
    if not input then return self:_invalid("invalid_sample") end
    local grounded = input.front_support or input.rear_support
    if not self._context_known or self._grounded ~= grounded then
        -- As in input.lua, a ground/air change consumes the arm, so a stick
        -- held through takeoff or landing needs neutral before it can enter.
        self._armed = false
        self._context_known, self._grounded = true, grounded
    end
    local neutral = input.manual <= s.neutral_input and input.nose_manual <= s.neutral_input
        and input.preload <= 0 and not input.hop and input.rear_neutral
    local state = self._state

    if state == "ended" then
        if not neutral then return self:_output(true, "neutral_required", 0, nil) end
        local event = self:_transition("idle")
        self._kind, self._end_reason, self._bail_pending = nil, "none", false
        self._armed = grounded
        return self:_output(true, "none", 0, event)
    end

    if state == "idle" then
        if neutral then
            if grounded then self._armed = true end
            return self:_output(true, "none", 0, nil)
        end
        if not grounded then return self:_output(true, "unsupported", 0, nil) end
        if not self._armed then return self:_output(true, "neutral_required", 0, nil) end
        local want_manual, want_nose = input.manual >= s.engage_input, input.nose_manual >= s.engage_input
        if not want_manual and not want_nose then return self:_output(true, "none", 0, nil) end
        -- Any attempt consumes the arm, accepted or refused, so a refusal
        -- cannot turn into a late entry while the stick stays held.
        self._armed = false
        if want_manual and want_nose then return self:_output(true, "conflicting_input", 0, nil) end
        local kind = want_manual and "manual" or "nose_manual"
        local spec = kinds[kind]
        if not input[spec.base] then return self:_output(true, "base_wheel_unsupported", 0, nil) end
        if input.speed < s.min_entry_speed then return self:_output(true, "entry_speed_low", 0, nil) end
        if input.hop or input.preload > 0 then return self:_output(true, "hop_pending", 0, nil) end
        self._kind = kind
        self:_clear_balance()
        local lift = spec.sign * input.pitch
        -- Start from the measured lift so an already tilted bike is not
        -- commanded back down before the ramp begins.
        self._target = clamp(lift, 0, s[spec.balance])
        local event = self:_transition("entering")
        local own = kind == "manual" and input.manual or input.nose_manual
        self:_advance_target(input, own, true, dt)
        local fraction = self:_command(lift, spec.sign * input.pitch_rate, not input[spec.lifted], dt)
        return self:_output(true, "none", fraction, event, lift)
    end

    local spec = kinds[self._kind]
    local lift, lift_rate = spec.sign * input.pitch, spec.sign * input.pitch_rate
    local lifted_down, base_down = input[spec.lifted], input[spec.base]
    local own = self._kind == "manual" and input.manual or input.nose_manual
    local other = self._kind == "manual" and input.nose_manual or input.manual
    -- Pushing to the other side is a release of this kind, never a swap.
    if other >= s.engage_input then own = 0 end
    if input.hop then return self:_output(true, "none", 0, self:_end("hop_out", false)) end
    if not lifted_down and not base_down then
        self._unsupported = self._unsupported + dt
        if self._unsupported >= s.airborne_grace then
            return self:_output(true, "none", 0, self:_end("airborne", false))
        end
        -- Inside the grace the stick reads as air input (input.lua reports no
        -- manual there), so hold the lift rather than judge it as a release.
        return self:_output(true, "unsupported", self:_command(lift, lift_rate, false, dt), nil, lift)
    end
    self._unsupported = 0
    -- Losing the base wheel with the lifted wheel down means the bike rocked
    -- over onto the wrong wheel: the lift is gone.
    if lifted_down and not base_down then
        return self:_output(true, "none", 0, self:_end(spec.drop_reason, false))
    end
    local entering = state == "entering"
    if entering then
        if own <= s.neutral_input and input.preload <= 0 then
            return self:_output(true, "none", 0, self:_end("cancelled", false))
        end
        self._elapsed = self._elapsed + dt
        if self._elapsed > s.entry_seconds then
            return self:_output(true, "none", 0, self:_end(spec.drop_reason, false))
        end
    elseif lifted_down or lift <= s[spec.drop] then
        return self:_output(true, "none", 0, self:_end(spec.drop_reason, false))
    end
    local ramped = self:_advance_target(input, own, entering, dt)
    -- Over-rotation is judged on the measured lift and on the rider's target:
    -- forces.lua caps its command at manual_pitch, so a rider leaning past the
    -- point of no return may never be measured there. It is a bail request
    -- only; the bail itself belongs to another policy.
    if math.max(lift, self._target) >= s[spec.over] then
        return self:_output(true, "none", 0, self:_end(spec.over_reason, true))
    end
    -- Balancing starts once the ramp is done and the wheel is up near the
    -- point. Waiting for the ramp means the tipping term never starts on a
    -- target that a fast measured lift left behind.
    local event
    if entering and ramped and not lifted_down and lift >= s[spec.balance] - s.entry_window then
        event = self:_transition("balancing")
    end
    local fraction = self:_command(lift, lift_rate, not lifted_down, dt)
    return self:_output(true, "none", fraction, event, lift)
end

-- Measures pitch and pitch rate from a Hamilton XYZW body orientation, a world
-- angular velocity and the support normal, in the authored bike basis (+Y up,
-- +Z forward, +X rider-left). Returns nil when the frame is degenerate.
function Balance.measure(orientation, angular_velocity, support_up)
    local q, w, n = orientation, angular_velocity, support_up or { 0, 1, 0 }
    if type(q) ~= "table" or type(w) ~= "table" or type(n) ~= "table" then return nil end
    local norm = 0
    for i = 1, 4 do
        if not finite(q[i]) then return nil end
        norm = norm + q[i] * q[i]
    end
    if math.abs(norm - 1) > 0.001 then return nil end
    for i = 1, 3 do
        if not finite(w[i]) or not finite(n[i]) then return nil end
    end
    local n_length = math.sqrt(n[1] * n[1] + n[2] * n[2] + n[3] * n[3])
    if n_length < 1e-6 then return nil end
    local up = { n[1] / n_length, n[2] / n_length, n[3] / n_length }
    norm = math.sqrt(norm)
    local x, y, z, r = q[1] / norm, q[2] / norm, q[3] / norm, q[4] / norm
    -- Body +Z rotated by q.
    local forward = { 2 * (x * z + r * y), 2 * (y * z - r * x), 1 - 2 * (x * x + y * y) }
    local along = forward[1] * up[1] + forward[2] * up[2] + forward[3] * up[3]
    -- Pitch about the support-plane lateral axis, cross(up, forward), which is
    -- +X rider-left on a level bike. A positive turn about it lowers the nose.
    local lateral = { up[2] * forward[3] - up[3] * forward[2], up[3] * forward[1] - up[1] * forward[3],
        up[1] * forward[2] - up[2] * forward[1] }
    local l_length = math.sqrt(lateral[1] ^ 2 + lateral[2] ^ 2 + lateral[3] ^ 2)
    if l_length < 1e-6 then return nil end
    local rate = -(w[1] * lateral[1] + w[2] * lateral[2] + w[3] * lateral[3]) / l_length
    return math.asin(clamp(along, -1, 1)), rate
end

return Balance

-- Selected-source requests only. Native input time advances gestures; the
-- force owner supplies independent body correspondence, physics h and receipts.
local Input = require("./input")
local Identity = require("./lease_identity")
local Mapping, Mapper = {}, {}
Mapper.__index = Mapper
local maximum_hop = 4294967295
local axis_names = { "left_x", "left_y", "right_x", "right_y" }
local trigger_names = { "left_trigger", "right_trigger" }
local button_names = { "a", "b", "right_stick", "lb", "rb" }
local identity_names = { "sequence", "source_epoch", "context_generation" }
local action_source_names = { "lease_handle", "generation", "user", "sequence", "source_epoch",
    "context_generation", "observation_serial", "observed_ms", "packet" }
-- SDK records are plain tables. Reject callbacks before reading fields, and
-- retain only the bounded native pad shape before any copy or comparison.
local sdk_buttons = { "up", "down", "left", "right", "start", "back", "left_stick", "right_stick",
    "lb", "rb", "a", "b", "x", "y" }
local pad_keys = { left_x=true, left_y=true, right_x=true, right_y=true,
    left_trigger=true, right_trigger=true, playstation=true, buttons=true }
local button_keys = {}
for _, name in ipairs(sdk_buttons) do button_keys[name] = true end
local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function finite(v)
    return type(v) == "number" and v == v and math.abs(v) < math.huge
end
local function integer(v, low, high)
    return finite(v) and v % 1 == 0 and v >= low and v <= high
end
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for name, value in pairs(v) do out[name] = copy(value) end
    return out
end
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for name, value in pairs(a) do if not equal(value, b[name]) then return false end end
    for name in pairs(b) do if a[name] == nil then return false end end
    return true
end
local function reason(value, fallback)
    return type(value) == "string" and #value > 0 and #value <= 128 and value or fallback
end
local function sample_valid(sample)
    if not plain(sample) or not integer(sample.user, 0, 3)
        or not integer(sample.packet, 0, 4294967295) then return false end
    for _, name in ipairs(identity_names) do
        if not Identity.is_nonzero_u64(sample[name]) then return false end
    end
    if not Identity.is_nonzero_u64(sample.observation_serial)
        or not Identity.is_u64(sample.observed_ms) or not plain(sample.pad)
        or not plain(sample.pad.buttons) then return false end
    local pad = sample.pad
    for name in pairs(pad) do if not pad_keys[name] then return false end end
    for name, value in pairs(pad.buttons) do
        if not button_keys[name] or type(value) ~= "boolean" then return false end
    end
    if pad.playstation ~= nil and type(pad.playstation) ~= "boolean" then return false end
    for _, name in ipairs(axis_names) do
        if not finite(pad[name]) or math.abs(pad[name]) > 1 then return false end
    end
    for _, name in ipairs(trigger_names) do
        if not finite(pad[name]) or pad[name] < 0 or pad[name] > 1 then return false end
    end
    for _, name in ipairs(button_names) do
        if type(pad.buttons[name]) ~= "boolean" then return false end
    end
    return true
end
local function projected_pad(pad)
    local out = { buttons = {} }
    for _, name in ipairs(axis_names) do out[name] = pad[name] end
    for _, name in ipairs(trigger_names) do out[name] = pad[name] end
    for _, name in ipairs(sdk_buttons) do
        if pad.buttons[name] ~= nil then out.buttons[name] = pad.buttons[name] end
    end
    if pad.playstation ~= nil then out.playstation = pad.playstation end
    return out
end
local function source_record(frame)
    local s = frame.sample
    return { lease_handle = frame.lease_handle, generation = frame.generation,
        user = s.user, sequence = s.sequence, source_epoch = s.source_epoch,
        context_generation = s.context_generation, observation_serial = s.observation_serial,
        observed_ms = s.observed_ms, packet = s.packet, pad = projected_pad(s.pad) }
end
local function same_identity(a, b)
    return a and b and a.lease_handle == b.lease_handle and a.user == b.user
        and a.sequence == b.sequence and a.source_epoch == b.source_epoch
        and a.context_generation == b.context_generation and a.generation == b.generation
end
local function raw_input(s)
    local pad, b = s.pad, s.pad.buttons
    return Input.raw({ available = true, focused = true, menu_open = false,
        -- This is the actual selected slot, not a truncated native source epoch.
        -- The enclosing mapper resets on the full exact source identity above.
        device = s.user, left_x = pad.left_x, left_y = pad.left_y,
        right_x = pad.right_x, right_y = pad.right_y,
        left_trigger = pad.left_trigger, right_trigger = pad.right_trigger,
        left_shoulder = b.lb, right_shoulder = b.rb,
        pedal = b.a and 1 or 0, brake = b.b and 1 or 0, quick_hop = b.right_stick })
end

function Mapping.new(settings)
    local input = Input.new(settings)
    return setmetatable({ _mapper = input, _settings = input:settings(), _hop_counter = 0,
        _valid = false, _active = false, _issue = "not_primed", _needs_prime = true,
        _actions = Input.actions() }, Mapper)
end
function Mapper:_invalidate(issue, keep_hop)
    self._mapper:reset()
    self._valid, self._active, self._needs_prime = false, false, true
    self._issue, self._actions, self._raw = issue, Input.actions(), nil
    if not keep_hop then
        if self._pending then self._last_retired = { event = copy(self._pending), disposition = issue } end
        self._pending = nil
    end
end
function Mapper:reset(issue)
    self:_invalidate(reason(issue, "reset"))
    self._uncertain, self._blocked = nil, nil
    -- Keep same-source observation/time high-water marks and the lifetime
    -- counter. Reset cannot turn an old cached R3 press into a new event.
end
function Mapper:_observation(valid, issue, fresh)
    return { valid = valid, issue = issue, active = self._active,
        new_observation = fresh == true, source = copy(self._source),
        actions = copy(self._actions), hop = copy(self._pending) }
end
function Mapper:_refuse(issue, keep_hop)
    self:_invalidate(issue, keep_hop)
    return self:_observation(false, issue, false)
end
function Mapper:observe(frame, context)
    -- A duplicate still has to pass current source and explicit owner guards.
    -- The native source adapter supplies input_ok only after its fresh checks.
    if not plain(frame) or frame.input_ok ~= true then return self:_refuse("input_unavailable") end
    if not plain(context) or type(context.grounded) ~= "boolean"
        or type(context.focused) ~= "boolean" or type(context.menu_open) ~= "boolean"
        or type(context.rotation_reserved) ~= "boolean" then return self:_refuse("context_unavailable") end
    if not context.focused then return self:_refuse("focus_lost") end
    if context.menu_open then return self:_refuse("menu_open") end
    if type(frame.lease_handle) ~= "userdata" or not integer(frame.generation, 0, 9007199254740991)
        or not sample_valid(frame.sample) then return self:_refuse("invalid_source_sample") end
    if self._exhausted then return self:_refuse("hop_event_counter_exhausted") end
    if self._uncertain then return self:_refuse("hop_outcome_uncertain") end
    if self._blocked then return self:_refuse(self._blocked, true) end

    local current = source_record(frame)
    local changed = not same_identity(current, self._source)
    if changed then
        self:_invalidate("source_changed")
        self._source, self._last_sample = current, nil
        self._serial_floor, self._time_floor = nil, nil
    end
    local order = self._serial_floor and Identity.compare(current.observation_serial, self._serial_floor) or 1
    if order < 0 then return self:_refuse("observation_regressed") end
    if order == 0 then
        if not self._last_sample or not equal(current, self._last_sample) then
            return self:_refuse("inconsistent_observation")
        end
        self._rotation_reserved = context.rotation_reserved
        if self._grounded ~= context.grounded then
            self._grounded = context.grounded
            return self:_refuse("ground_context_changed")
        end
        return self:_observation(true, self._active and "duplicate_observation" or "awaiting_fresh_observation", false)
    end

    local elapsed = 0
    if self._time_floor then
        local maximum_ms = math.floor(self._settings.max_sample_seconds * 1000 + 1e-9)
        local delta = Identity.bounded_delta(current.observed_ms, self._time_floor, maximum_ms)
        if delta == nil then
            self._serial_floor = current.observation_serial
            if Identity.compare(current.observed_ms, self._time_floor) >= 0 then
                self._time_floor, self._last_sample, self._source = current.observed_ms, copy(current), current
                return self:_refuse("observation_gap")
            end
            self._last_sample = nil
            return self:_refuse("input_clock_regressed")
        end
        elapsed = delta / 1000
    end
    self._serial_floor, self._time_floor = current.observation_serial, current.observed_ms
    self._source, self._last_sample = current, copy(current)
    local ground_changed = self._grounded ~= nil and self._grounded ~= context.grounded
    if ground_changed and self._pending then
        self._last_retired = { event = copy(self._pending), disposition = "ground_context_changed" }
        self._pending = nil
    end
    self._grounded, self._rotation_reserved = context.grounded, context.rotation_reserved
    local raw = raw_input(current)
    local actions = self._mapper:update_observation(raw, { grounded = context.grounded }, self._needs_prime and 0 or elapsed)
    self._needs_prime, self._raw, self._actions = false, raw, actions
    self._valid, self._active, self._issue = true, actions.active, actions.active and "none" or "neutral_required"
    if actions.hop_pressed then
        if self._pending then
            self._blocked = "hop_pending_conflict"
            return self:_refuse(self._blocked, true)
        end
        if self._hop_counter >= maximum_hop then
            self._exhausted = true
            return self:_refuse("hop_event_counter_exhausted")
        end
        self._hop_counter = self._hop_counter + 1
        self._pending = { id = self._hop_counter, strength = actions.hop_strength,
            source = copy(current), observation_serial = current.observation_serial,
            observed_ms = current.observed_ms }
    end
    return self:_observation(true, self._issue, true)
end
function Mapper:controls(context)
    local out = { valid = false, issue = self._issue, submission_allowed = false }
    if not plain(context) or type(context.physics_epoch) ~= "userdata"
        or not finite(context.h) or context.h <= 0 or context.h > self._settings.max_sample_seconds
        or type(context.grounded) ~= "boolean" or type(context.rotation_reserved) ~= "boolean" then
        self:_invalidate("invalid_step_context")
        out.issue = self._issue
        return out
    end
    if self._grounded ~= context.grounded then
        self._grounded = context.grounded
        self:_invalidate("ground_context_changed")
        out.issue = self._issue
        return out
    end
    if not self._valid or not self._active or not self._raw or self._blocked or self._uncertain or self._exhausted then
        return out
    end
    local a, raw = self._actions, self._raw
    local neutral = self._settings.deadzone + (1 - self._settings.deadzone) * self._settings.neutral_threshold
    local rear_magnitude = math.sqrt(raw.right_x^2 + raw.right_y^2)
    local raw_rotation = math.sqrt(raw.left_x^2 + raw.left_y^2) > neutral
        or rear_magnitude > neutral
        or raw.left_shoulder or raw.right_shoulder
        or raw.left_trigger > self._settings.trigger_neutral or raw.right_trigger > self._settings.trigger_neutral
    local manual, nose = a.manual, a.nose_manual
    if not context.grounded then manual, nose = math.max(0, -a.air_pitch), math.max(0, a.air_pitch) end
    local hop = self._pending
    out.valid, out.issue, out.submission_allowed = true, "none", true
    out.physics_epoch, out.h, out.source, out.hop = context.physics_epoch, context.h, copy(self._source), copy(hop)
    -- Both authored bar and rear selections use the right stick. Neutral is a
    -- fact from this same admitted raw snapshot, never inferred from no request.
    local actions = copy(a)
    actions.physics_epoch, actions.h, actions.source = context.physics_epoch, context.h, {}
    for _, name in ipairs(action_source_names) do actions.source[name] = self._source[name] end
    actions.bar_neutral, actions.rear_neutral = rear_magnitude <= neutral, rear_magnitude <= neutral
    out.actions = actions
    out.force_controls = { enabled = true, pedal = a.pedal, brake = a.brake, steer = a.steer,
        manual = manual, nose_manual = nose, air_yaw = a.steer, ground_pump = a.front_weight,
        pump_operator_available = true,
        pump_inhibited = hop ~= nil or a.hop_pressed or raw.quick_hop or a.preload > 0,
        rotation_reserved = raw_rotation or self._rotation_reserved or context.rotation_reserved,
        recovery_step_verified = false, contact_compliance_available = false,
        landing_contact_compliance_selected = false,
        hop_event_id = hop and hop.id or 0, hop_strength = hop and hop.strength or 0 }
    return out
end
function Mapper:retire_hop(id, disposition)
    if not integer(id, 1, maximum_hop) or not self._pending or self._pending.id ~= id then
        return false, "hop_identity_mismatch"
    end
    if disposition ~= "accepted" and disposition ~= "cancelled" and disposition ~= "uncertain" then
        return false, "invalid_disposition"
    end
    local event = copy(self._pending)
    self._pending = nil
    self._last_retired = { event = event, disposition = disposition }
    if disposition == "accepted" then
        self._actions.hop_pressed, self._actions.hop_strength = false, 0
        if self._blocked then self._blocked = nil; self:_invalidate("awaiting_fresh_observation") end
    elseif disposition == "cancelled" then
        self:_invalidate("hop_cancelled")
        self._blocked = nil
    else
        self._uncertain = event
        self:_invalidate("hop_outcome_uncertain")
    end
    return true, "none"
end
function Mapper:status()
    return { valid = self._valid, active = self._active, issue = self._issue,
        source = copy(self._source), actions = copy(self._actions), pending_hop = copy(self._pending),
        hop_counter = self._hop_counter, exhausted = self._exhausted == true,
        uncertain = copy(self._uncertain), last_retired = copy(self._last_retired) }
end
return Mapping

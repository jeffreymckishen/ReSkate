-- Policy port of Engine/Game/BMX/bmx_input.h. No native service is used here.
-- Sticks: +X right, +Y forward. Outputs are requests, never execution receipts.
local catalog = require("./catalog")
local Input = {}
local Mapper = {}
Mapper.__index = Mapper

local defaults = {
    deadzone = 0.12, neutral_threshold = 0.18, trick_threshold = 0.7,
    hop_back_threshold = 0.72, hop_forward_threshold = 0.55, hop_lateral_limit = 0.35,
    hop_flick_seconds = 0.30, hop_charge_seconds = 0.25, manual_threshold = 0.22,
    trigger_neutral = 0.05, max_sample_seconds = 0.10, modifier_threshold = 0.2,
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
    source = source or {}
    local result = {}
    local function bounded(name, low, high)
        local value = source[name]
        return clamp(finite(value) and value or defaults[name], low, high)
    end
    result.deadzone = bounded("deadzone", 0, 0.45)
    result.neutral_threshold = bounded("neutral_threshold", 0.05, 0.40)
    result.trick_threshold = bounded("trick_threshold", math.max(0.55, result.neutral_threshold + 0.10), 0.95)
    result.hop_back_threshold = bounded("hop_back_threshold", 0.55, 0.95)
    result.hop_forward_threshold = bounded("hop_forward_threshold", 0.40, 0.95)
    result.hop_lateral_limit = bounded("hop_lateral_limit", 0.10, 0.50)
    result.hop_flick_seconds = bounded("hop_flick_seconds", 0.04, 0.75)
    result.hop_charge_seconds = bounded("hop_charge_seconds", 0.02, 1.00)
    result.manual_threshold = bounded("manual_threshold", 0.05, result.hop_back_threshold - 0.10)
    result.trigger_neutral = bounded("trigger_neutral", 0.01, 0.20)
    result.modifier_threshold = bounded("modifier_threshold", math.max(0.1, result.trigger_neutral + 0.05), 0.95)
    result.max_sample_seconds = bounded("max_sample_seconds", 0.01, 0.25)
    return result
end

function Input.actions()
    return {
        active = false, hop_pressed = false, steer = 0, front_weight = 0, rear_weight = 0,
        pedal = 0, brake = 0, preload = 0, hop_strength = 0, manual = 0, nose_manual = 0,
        handlebar = "none", tailwhip = "none", air_pitch = 0, movement = catalog.none,
    }
end

-- Fill the same defaults as the C++ RawInput aggregate. A caller-supplied
-- device is a uint32 routing key. A source adapter must separately track exact
-- native lease/source/context identity and reset gestures when that changes.
function Input.raw(source)
    source = source or {}
    local result = {
        left_x = 0, left_y = 0, right_x = 0, right_y = 0, pedal = 0, brake = 0,
        available = false, focused = true, menu_open = false, device = 0,
        quick_hop = false, left_trigger = 0, right_trigger = 0,
        left_shoulder = false, right_shoulder = false,
    }
    for key in pairs(result) do
        if source[key] ~= nil then result[key] = source[key] end
    end
    return result
end

local function normalize(settings, x, y)
    x, y = clamp(x, -1, 1), clamp(y, -1, 1)
    local length = math.sqrt(x * x + y * y)
    if length <= settings.deadzone then return { x = 0, y = 0, magnitude = 0 } end
    local magnitude = (math.min(length, 1) - settings.deadzone) / (1 - settings.deadzone)
    return { x = x / length * magnitude, y = y / length * magnitude, magnitude = magnitude }
end

function Mapper:_clear_gestures()
    self._rear_armed, self._air_pitch_armed, self._trick_armed = false, false, false
    self._hop_pending, self._charge_seconds, self._release_seconds = false, 0, 0
end

function Mapper:reset()
    self._gated, self._device_known, self._context_known = true, false, false
    self._quick_hop_held = false
    self:_clear_gestures()
end

function Mapper:settings()
    return copy(self._settings)
end

function Mapper:configure(settings)
    self._settings = sanitize(settings)
    self:reset()
end

function Input.new(settings)
    local mapper = setmetatable({ _settings = sanitize(settings), _grounded = true, _device = 0 }, Mapper)
    mapper:reset()
    return mapper
end

function Mapper:_ground(rear, seconds, out)
    local settings = self._settings
    if rear.magnitude <= settings.neutral_threshold and not self._hop_pending then self._rear_armed = true end
    local aligned = math.abs(rear.x) <= settings.hop_lateral_limit
    local back = aligned and rear.y <= -settings.hop_back_threshold
    if not self._hop_pending and self._rear_armed and back then
        self._hop_pending, self._rear_armed = true, false
        self._charge_seconds, self._release_seconds = 0, 0
    end
    if self._hop_pending then
        if not aligned then self._hop_pending = false; return end
        if back then
            self._charge_seconds = math.min(self._charge_seconds + seconds, settings.hop_charge_seconds)
            self._release_seconds = 0
        else
            self._release_seconds = self._release_seconds + seconds
        end
        if self._release_seconds > settings.hop_flick_seconds then self._hop_pending = false; return end
        out.preload = self._charge_seconds / settings.hop_charge_seconds
        if rear.y >= settings.hop_forward_threshold then
            out.hop_pressed = true
            out.hop_strength = clamp(out.preload, 0.25, 1)
            out.preload, self._hop_pending = 0, false
        end
        return
    end
    local amount = math.abs(rear.y)
    if self._rear_armed and aligned and amount >= settings.manual_threshold and amount < settings.hop_back_threshold then
        local balance = (amount - settings.manual_threshold) / (settings.hop_back_threshold - settings.manual_threshold)
        if rear.y < 0 then out.manual = balance else out.nose_manual = balance end
    end
end

function Mapper:_air_pitch(front, out)
    local settings = self._settings
    if front.magnitude <= settings.neutral_threshold then self._air_pitch_armed = true; return end
    if not self._air_pitch_armed then return end
    local amount = math.abs(front.y)
    if amount > settings.manual_threshold then
        local strength = clamp((amount - settings.manual_threshold) / (1 - settings.manual_threshold), 0, 1)
        out.air_pitch = front.y < 0 and -strength or strength
    end
end

function Mapper:_modifiers_neutral(raw)
    return not raw.left_shoulder and not raw.right_shoulder
        and raw.left_trigger <= self._settings.trigger_neutral and raw.right_trigger <= self._settings.trigger_neutral
end

function Mapper:_air_trick(rear, raw, out)
    local settings = self._settings
    if rear.magnitude <= settings.neutral_threshold then self._trick_armed = true; return end
    if not self._trick_armed or rear.magnitude < settings.trick_threshold then return end
    -- Unsupported/busy selections consume their gesture too. A modifier change
    -- with the selecting stick still held must not create a late trick.
    self._trick_armed = false
    local lt, rt = raw.left_trigger > settings.modifier_threshold, raw.right_trigger > settings.modifier_threshold
    local lb, rb = raw.left_shoulder, raw.right_shoulder
    local set = -1
    if lb and rt then set = 0
    elseif rb and lt then set = 1
    elseif lb and rb then set = 2
    elseif lb then set = 3
    elseif rb then set = 4
    elseif lt and rt then set = 5
    elseif lt then set = 6
    elseif rt then set = 7 end
    local degrees = math.atan2(rear.x, rear.y) * 180 / math.pi
    if degrees < 0 then degrees = degrees + 360 end
    local slot
    if degrees < 30 or degrees > 330 then slot = 0
    elseif degrees > 150 and degrees < 210 then slot = 4
    else slot = math.floor((degrees + 22.5) / 45) % 8 end
    out.movement = catalog.select(set, slot)
    if set == 3 and slot == 4 then out.handlebar = "left"
    elseif set == 4 and slot == 4 then out.handlebar = "right"
    elseif set == 5 and slot == 2 then out.tailwhip = "right"
    elseif set == 5 and slot == 6 then out.tailwhip = "left" end
end

local numeric_fields = { "left_x", "left_y", "right_x", "right_y", "pedal", "brake", "left_trigger", "right_trigger" }
local boolean_fields = { "available", "focused", "menu_open", "quick_hop", "left_shoulder", "right_shoulder" }

local function update(self, source, context, seconds, allow_zero)
    local raw = Input.raw(source)
    local grounded = context == nil or context.grounded == nil or context.grounded
    local valid = type(grounded) == "boolean" and finite(raw.device) and raw.device % 1 == 0
        and raw.device >= 0 and raw.device <= 4294967295
    for _, field in ipairs(numeric_fields) do valid = valid and finite(raw[field]) end
    for _, field in ipairs(boolean_fields) do valid = valid and type(raw[field]) == "boolean" end
    if not valid or not raw.available or not raw.focused or raw.menu_open
        or not finite(seconds) or seconds < 0 or (seconds == 0 and not allow_zero)
        or seconds > self._settings.max_sample_seconds then
        self:reset()
        return Input.actions()
    end
    if not self._device_known or self._device ~= raw.device then
        self:reset()
        self._device_known, self._device = true, raw.device
    end
    local front = normalize(self._settings, raw.left_x, raw.left_y)
    local rear = normalize(self._settings, raw.right_x, raw.right_y)
    local pedal, brake = clamp(raw.pedal, 0, 1), clamp(raw.brake, 0, 1)
    if self._gated then
        if front.magnitude > self._settings.neutral_threshold or rear.magnitude > self._settings.neutral_threshold
            or pedal > self._settings.trigger_neutral or brake > self._settings.trigger_neutral
            or raw.quick_hop or not self:_modifiers_neutral(raw) then return Input.actions() end
        self._gated = false
    end
    if not self._context_known or self._grounded ~= grounded then
        self:_clear_gestures()
        self._context_known, self._grounded = true, grounded
    end
    local out = Input.actions()
    local quick_hop_pressed = raw.quick_hop and not self._quick_hop_held
    self._quick_hop_held = raw.quick_hop
    out.active, out.steer, out.front_weight, out.rear_weight = true, front.x, front.y, rear.y
    local function trigger(value)
        if value <= self._settings.trigger_neutral then return 0 end
        return (value - self._settings.trigger_neutral) / (1 - self._settings.trigger_neutral)
    end
    out.pedal, out.brake = grounded and trigger(pedal) or 0, trigger(brake)
    if grounded then
        self:_ground(rear, seconds, out)
        if quick_hop_pressed then
            out.hop_pressed, out.hop_strength, out.preload = true, 1, 0
            self._hop_pending, self._rear_armed = false, false
            self._charge_seconds, self._release_seconds = 0, 0
        end
    else
        self:_air_trick(rear, raw, out)
        self:_air_pitch(front, out)
    end
    return out
end

function Mapper:update(source, context, seconds)
    return update(self, source, context, seconds, false)
end

-- Distinct ordered source observations can share one native millisecond stamp.
-- Zero advances their edges only; it invents no charge or release duration.
function Mapper:update_observation(source, context, seconds)
    return update(self, source, context, seconds, true)
end

return Input

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
    -- A flick hop's pull crosses the manual band in one to three frames, so a manual starts only once the stick
    -- has been in the band this long: a hop gets no nose-up kick on its way.
    manual_entry_seconds = 0.10,
    -- A manual output this long before the stick goes on to full back is kept up while the hop charges, at
    -- manual_preload (about 30 degrees), so a hop from a manual leaves from the back wheel.
    manual_carry_seconds = 0.25, manual_preload = 0.6,
    -- From a manual the stick goes this far back before a hop charges, and the manual stays at the top of its
    -- band on the way. The band ended at hop_back_threshold, so the highest manual sat on the hop's threshold:
    -- raw -.80 for three frames, early in a manual held at -.70, charged a hop and dropped the front.
    manual_hop_back_threshold = 0.85,
}

-- Held time is a sum of steps: whole milliseconds from Mapping, or the native step of 1/60 s in float32
-- (.01666666567) offline, six of which come to .0999999940. Compared within this much, both reach a threshold on
-- the same step; within 1e-9 the offline world entered and carried a manual a step later than the game.
local HELD_SLACK = 1e-6

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
    result.manual_entry_seconds = bounded("manual_entry_seconds", 0, 0.3)
    result.manual_carry_seconds = bounded("manual_carry_seconds", 0, 1)
    result.manual_preload = bounded("manual_preload", 0, 1)
    result.manual_hop_back_threshold = bounded("manual_hop_back_threshold", result.hop_back_threshold, 0.95)
    return result
end

function Input.actions()
    return {
        active = false, hop_pressed = false, steer = 0, front_weight = 0, rear_weight = 0,
        pedal = 0, brake = 0, preload = 0, hop_strength = 0, manual = 0, nose_manual = 0, manual_held = false,
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

-- A manual being entered, or carried through a hop's charge, starts over on a
-- change of ground. Whether the stick still holds one (_manual_held), whether
-- that one was established enough to carry into a charge (_manual_established),
-- and whether a landing may go into one (_land_armed), carry across it.
function Mapper:_clear_gestures()
    self._rear_armed, self._air_pitch_armed, self._trick_armed = false, false, false
    self._hop_pending, self._charge_seconds, self._release_seconds = false, 0, 0
    self._manual_seconds, self._manual_side, self._manual_carry, self._manual_live = 0, nil, false, false
end

function Mapper:reset()
    self._gated, self._device_known, self._context_known = true, false, false
    self._quick_hop_held = false
    self._manual_held, self._manual_established, self._land_armed = false, false, false
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

-- The right stick on the ground. Part way back is a manual, its height set by
-- how far back; all the way back charges a hop and a flick forward pops it.
-- The same band forward is the nose manual. A manual starts only after
-- manual_entry_seconds in the band, then follows the stick at once. One that
-- was established when the stick went on to full back is held at
-- manual_preload while the hop charges, and eased back into the band it goes
-- on as a manual; the step the hop pops sends none, the rider pushing the bars
-- forward to pop. From a live manual the band's top manual reaches on to
-- manual_hop_back_threshold, so a hop charges only past that.
function Mapper:_ground(rear, seconds, out)
    local settings = self._settings
    if rear.magnitude <= settings.neutral_threshold and not self._hop_pending then self._rear_armed = true end
    local live = self._manual_live
    self._manual_live = false
    local top = live and rear.y < 0 and settings.manual_hop_back_threshold or settings.hop_back_threshold
    local aligned = math.abs(rear.x) <= settings.hop_lateral_limit
    local back = aligned and rear.y <= -top
    local amount = math.abs(rear.y)
    local band = aligned and amount >= settings.manual_threshold and amount < top
    local balance = band and math.min(1, (amount - settings.manual_threshold) / (settings.hop_back_threshold - settings.manual_threshold)) or 0
    -- Out of the back band toward the middle or forward, a held manual is let go.
    if rear.y > -settings.manual_threshold then self._manual_held, self._manual_established = false, false end
    if not self._hop_pending and self._rear_armed and back then
        self._hop_pending, self._rear_armed = true, false
        self._charge_seconds, self._release_seconds = 0, 0
        self._manual_carry = live and (self._manual_established or self._manual_seconds >= settings.manual_carry_seconds - HELD_SLACK)
        self._manual_established = self._manual_carry
    end
    if self._hop_pending then
        local carry = self._manual_carry
        self._manual_seconds = 0
        if not aligned then
            self._hop_pending = false
            if carry then self._rear_armed, self._manual_carry = true, false end
            return
        end
        if back then
            self._charge_seconds = math.min(self._charge_seconds + seconds, settings.hop_charge_seconds)
            self._release_seconds = 0
        else
            self._release_seconds = self._release_seconds + seconds
        end
        if self._release_seconds > settings.hop_flick_seconds then
            -- Eased back with no flick: the hop lapses and the stick is the manual's again, a carried manual going
            -- straight on. Left unarmed after a charge that carried none, the band gave nothing until the stick
            -- had been back in the middle.
            self._hop_pending, self._rear_armed, self._manual_carry = false, true, false
        else
            out.preload = self._charge_seconds / settings.hop_charge_seconds
            if rear.y >= settings.hop_forward_threshold then
                out.hop_pressed = true
                out.hop_strength = clamp(out.preload, 0.25, 1)
                out.preload, self._hop_pending, self._manual_carry = 0, false, false
                return
            end
            if carry and (back or band and rear.y < 0) then
                out.manual, self._manual_live = back and settings.manual_preload or balance, true
            end
            return
        end
    end
    local side = rear.y < 0 and -1 or 1
    if self._rear_armed and band then
        if self._manual_side ~= nil and self._manual_side ~= side then self._manual_seconds, live = 0, false end
        self._manual_side = side
        self._manual_seconds = self._manual_seconds + seconds
        if live or self._manual_seconds >= settings.manual_entry_seconds - HELD_SLACK then
            if side < 0 then
                out.manual, self._manual_held = balance, true
                if self._manual_seconds >= settings.manual_carry_seconds - HELD_SLACK then self._manual_established = true end
            else
                out.nose_manual = balance
            end
            self._manual_live = true
        end
    else
        self._manual_seconds, self._manual_side = 0, nil
    end
end

-- In the air nothing is held up, but a landing can go into a manual: one the
-- stick still holds from take-off, or, once the stick has been back in the
-- middle, one it is pulled into before landing. A trick modifier, or the
-- stick pushed over for a trick, takes that away until the middle again. Only
-- a stick that has been back in the middle in this flight selects a trick
-- (_air_trick), so one held at the top of the band since take-off, or full
-- back charging a hop, is still the manual. Taken for a trick, both were lost
-- on a single step's lost support.
function Mapper:_air_manual(rear, raw)
    local settings = self._settings
    if rear.y > -settings.manual_threshold then self._manual_held, self._manual_established = false, false end
    if not self:_modifiers_neutral(raw) or self._trick_armed and rear.magnitude >= settings.trick_threshold then
        self._land_armed, self._manual_held, self._manual_established = false, false, false
    elseif rear.magnitude <= settings.neutral_threshold then
        self._land_armed = true
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
        local known = self._context_known
        -- Leaving the ground, a landing may go back into the manual held now.
        if known and not grounded then self._land_armed = self._manual_held end
        self:_clear_gestures()
        if known and grounded then
            -- Landing: the stick is armed if the air allowed a manual, and a
            -- manual still held comes back at once, so a step's flicker of
            -- lost support or a hop with the stick held leaves it as it was.
            self._rear_armed = self._land_armed
            self._manual_live = self._manual_held
        end
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
            -- R3 pops at once, from a manual too: this step sends none.
            out.hop_pressed, out.hop_strength, out.preload = true, 1, 0
            out.manual, out.nose_manual = 0, 0
            self._hop_pending, self._rear_armed = false, false
            self._charge_seconds, self._release_seconds = 0, 0
            self._manual_seconds, self._manual_carry, self._manual_live = 0, false, false
        end
    else
        self:_air_manual(rear, raw)
        self:_air_trick(rear, raw, out)
        self:_air_pitch(front, out)
    end
    -- Whether the stick still holds a manual, on the ground or off it, for the kernel's walk latch: the manual itself
    -- is zero on a step's lost support, and the stick has not been let go.
    out.manual_held = self._manual_held
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

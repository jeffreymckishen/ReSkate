-- Equipment gestures from our bmx_interaction.h/equipment_switch.h policies.
-- These are requests only. This module neither captures input nor calls a native action.
local Equipment = {}
local Toggle, Interaction, Quick = {}, {}, {}
Toggle.__index, Interaction.__index, Quick.__index = Toggle, Interaction, Quick
local maximum_integer = 9007199254740991

local function integer(n, maximum)
    return type(n) == "number" and n == n and n >= 0 and n <= maximum and n % 1 == 0
end
local function boolean(b) return type(b) == "boolean" end
local function owner_valid(owner)
    -- Real ownership must come from a qualified SDK adapter. Primitive tokens
    -- support the portable model; never convert a native pointer to a number.
    return type(owner) == "userdata" or (type(owner) == "string" and #owner > 0 and #owner <= 128)
        or (integer(owner, maximum_integer) and owner > 0)
end
Equipment.owner_valid = owner_valid

function Equipment.toggle() return setmetatable({_armed=false}, Toggle) end
function Toggle:reset() self._armed = false end
function Toggle:update(down, allowed)
    if not boolean(down) or not boolean(allowed) or not allowed then self:reset(); return false end
    if not down then self._armed = true; return false end
    local pressed = self._armed
    self._armed = false
    return pressed
end

function Equipment.interaction()
    local out = setmetatable({}, Interaction)
    out:reset()
    return out
end
function Interaction:reset()
    self._armed, self._pressed, self._consumed = false, false, false
    self._down_at, self._last = nil, nil
end
function Interaction:update(down, allowed, now_ms)
    if not boolean(down) or not boolean(allowed) or not allowed
        or not integer(now_ms, maximum_integer) or (self._last and now_ms < self._last) then
        self:reset(); return "none"
    end
    self._last = now_ms
    if not down then
        local tap = self._pressed and not self._consumed
        self._pressed, self._consumed, self._armed = false, false, true
        return tap and "tap" or "none"
    end
    if not self._pressed then
        if not self._armed then return "none" end
        self._pressed, self._consumed, self._armed, self._down_at = true, false, false, now_ms
    end
    if not self._consumed and now_ms - self._down_at >= 500 then
        self._consumed = true
        return "hold"
    end
    return "none"
end

local function event(pressed, suppress, capture)
    return {pressed=pressed or false, suppress_north=suppress or false, capture_north=capture or false}
end
function Equipment.quick_switch()
    local out = setmetatable({}, Quick)
    out:reset()
    return out
end
function Quick:reset()
    self._armed, self._north_was_down, self._claimed = false, false, false
    self._device, self._last, self._owner = 0, nil, nil
end
function Quick:owner_sample_needed(north, shoulder)
    if not boolean(north) or not boolean(shoulder) then return false end
    return (self._claimed and (north or shoulder))
        or (self._armed and not self._north_was_down and north and shoulder)
end
function Quick:update(north, shoulder, allowed, device, owner_observed, owner, now_ms)
    if not boolean(north) or not boolean(shoulder) or not boolean(allowed) or not boolean(owner_observed)
        or not allowed or not integer(device, 4294967295) or device == 0
        or not integer(now_ms, maximum_integer) then
        self:reset(); return event()
    end
    if device ~= self._device or (self._last and now_ms < self._last) then
        local quarantine = self._claimed and (north or shoulder)
        self:reset()
        self._device, self._claimed = device, quarantine
    end
    self._last = now_ms
    local chord_edge = not self._north_was_down and north and shoulder
    local fresh_chord = self._armed and chord_edge
    if owner_observed and (not owner_valid(owner) or (owner_valid(self._owner) and self._owner ~= owner)) then
        self._claimed = self._claimed or chord_edge
        self._armed, self._north_was_down = false, north
        self._owner = owner_valid(owner) and owner or nil
        return event(false, self._claimed, self._claimed)
    end
    if owner_observed then self._owner = owner end
    if not north and not shoulder then
        local release_capture = self._claimed
        self._claimed, self._north_was_down, self._armed = false, false, true
        -- Keep North filtered through this release observation, so it cannot
        -- become an ordinary tap. The next neutral sample ends shortcut capture.
        return event(false, false, release_capture)
    end
    self._north_was_down = north
    local pressed = fresh_chord and owner_observed and owner_valid(owner)
    if chord_edge then self._claimed, self._armed = true, false end
    if self._claimed then return event(pressed, true, true) end
    -- Reserve North while the modifier is held before its next physical edge.
    return event(false, false, self._armed and shoulder and not north)
end

function Equipment.quick_action(active, pending, mounting, parked, crashed)
    if not boolean(active) or not boolean(pending) or not boolean(mounting)
        or not boolean(parked) or not boolean(crashed) then return "none" end
    if pending or mounting then return "none" end
    if active then return "skateboard" end
    if parked or crashed then return "nearby_bike" end
    return "equip_bike"
end

function Equipment.natural_dismount_state(state)
    return state == 100 or state == 103
end
function Equipment.natural_dismount_selection(current, committed)
    return current == committed and Equipment.natural_dismount_state(current)
end

return Equipment

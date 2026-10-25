-- Named control presets for the BMX ride mapper. Each one maps an SDK pad table
-- (reskate.input.gamepad() or an input-lease sample's pad) to the fields of
-- Input.raw and carries a complete, already-sanitized Input settings bundle.
-- "default" is the binding ride_input_mapping.lua hardcodes in raw_input.
-- Nothing reads these presets yet; wiring them into the mapper is a later change.
local Input = require("./input")
local Presets, Preset = {}, {}
Preset.__index = Preset
-- Compiled data lives here rather than on the handle, so nobody holding a
-- handle can change a binding after it was validated. The handle and Preset
-- are both frozen once built, so rawset cannot shadow a method either; Luau
-- refuses to freeze a table whose metatable is protected, so it is not.
local states = setmetatable({}, { __mode = "k" })

-- Each role is one Input.raw field. Numeric roles take a trigger axis, copied
-- unchanged, or a button read as 1 or 0. Boolean roles take a button only.
local roles = { "pedal", "brake", "left_trigger", "right_trigger", "quick_hop", "left_shoulder", "right_shoulder" }
local role_kind = { pedal = "number", brake = "number", left_trigger = "number", right_trigger = "number",
    quick_hop = "boolean", left_shoulder = "boolean", right_shoulder = "boolean" }
-- Sticks are not roles. Left steers and rotates, right hops, manuals and
-- selects tricks in every preset; the judging rubric fails a mapping that
-- contradicts that, so they pass through and cannot be bound or used as sources.
local stick_fields = { "left_x", "left_y", "right_x", "right_y" }
local stick_set = { left_x = true, left_y = true, right_x = true, right_y = true }
local trigger_axes = { left_trigger = true, right_trigger = true }
local bindable_buttons = { a = true, b = true, x = true, left_stick = true, right_stick = true, lb = true, rb = true }
-- Never bindable. The D-pad keeps Skate's own mapping (changing it is a rubric
-- hard failure), North/Y is equipment.lua's toggle and dismount gesture, and
-- Start/Back open menus.
local reserved = { up = "dpad_reserved", down = "dpad_reserved", left = "dpad_reserved", right = "dpad_reserved",
    y = "north_reserved", start = "menu_reserved", back = "menu_reserved" }

-- The pad shape ride_input_mapping.lua admits. SDK records are plain tables;
-- callbacks are refused before any field is read.
local sdk_buttons = { "up", "down", "left", "right", "start", "back", "left_stick", "right_stick",
    "lb", "rb", "a", "b", "x", "y" }
local button_keys = {}
for _, name in ipairs(sdk_buttons) do button_keys[name] = true end
local pad_keys = { left_x = true, left_y = true, right_x = true, right_y = true,
    left_trigger = true, right_trigger = true, playstation = true, buttons = true }
local descriptor_fields = { name = true, bindings = true, settings = true }
local default_settings = Input.new():settings()

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
local function detail(key)
    return type(key) == "string" and #key <= 64 and key or nil
end

-- Only the buttons this preset reads must be present. Every pad the hardcoded
-- mapper accepts therefore passes for the default preset.
local function pad_valid(pad, needed)
    if not plain(pad) or not plain(pad.buttons) then return false end
    for name in pairs(pad) do if not pad_keys[name] then return false end end
    for name, value in pairs(pad.buttons) do
        if not button_keys[name] or type(value) ~= "boolean" then return false end
    end
    if pad.playstation ~= nil and type(pad.playstation) ~= "boolean" then return false end
    for _, name in ipairs(stick_fields) do
        if not finite(pad[name]) or math.abs(pad[name]) > 1 then return false end
    end
    for name in pairs(trigger_axes) do
        if not finite(pad[name]) or pad[name] < 0 or pad[name] > 1 then return false end
    end
    for _, name in ipairs(needed) do
        if type(pad.buttons[name]) ~= "boolean" then return false end
    end
    return true
end

local function compile_settings(source)
    if source == nil then source = {} end
    if not plain(source) then return nil, "invalid_settings" end
    local overrides = {}
    for name, value in pairs(source) do
        if default_settings[name] == nil then return nil, "unknown_setting", detail(name) end
        if not finite(value) then return nil, "invalid_setting", name end
        overrides[name] = value
    end
    local bundle = Input.new(overrides):settings()
    -- Input clamps silently. A preset is data someone chose, so a value the
    -- clamp would change is refused instead of quietly becoming another one.
    for name, value in pairs(overrides) do
        if bundle[name] ~= value then return nil, "setting_out_of_range", name end
    end
    -- Some bounds depend on another setting: trigger_neutral above 0.15 lifts
    -- modifier_threshold's floor past its default. Refuse that as well, so each
    -- value in a bundle is either one the preset named or Input's own default.
    for name, value in pairs(bundle) do
        if overrides[name] == nil and value ~= default_settings[name] then
            return nil, "dependent_setting_out_of_range", name
        end
    end
    return bundle
end

local function compile(descriptor)
    if not plain(descriptor) then return nil, "invalid_preset" end
    for key in pairs(descriptor) do
        if not descriptor_fields[key] then return nil, "unknown_preset_field", detail(key) end
    end
    local name = descriptor.name
    if type(name) ~= "string" or #name > 32 or not string.match(name, "^[a-z][a-z0-9_]*$") then
        return nil, "invalid_name"
    end
    local bindings = descriptor.bindings
    if not plain(bindings) then return nil, "invalid_bindings" end
    for role in pairs(bindings) do
        if stick_set[role] then return nil, "stick_binding_refused", role end
        if not role_kind[role] then return nil, "unknown_role", detail(role) end
    end
    -- Every role is bound, and to a different control: one press feeding two
    -- roles (say pedal and a trick modifier) would make pedalling reserve
    -- rotation through the mapper's raw modifier check.
    local compiled, used, needed = {}, {}, {}
    for _, role in ipairs(roles) do
        local source = bindings[role]
        if source == nil then return nil, "role_unbound", role end
        if type(source) ~= "string" then return nil, "invalid_source", role end
        if reserved[source] then return nil, reserved[source], role end
        if stick_set[source] then return nil, "stick_source_refused", role end
        if trigger_axes[source] then
            if role_kind[role] ~= "number" then return nil, "boolean_role_needs_button", role end
        elseif bindable_buttons[source] then
            table.insert(needed, source)
        else
            return nil, "unknown_source", role
        end
        if used[source] then return nil, "source_bound_twice", role end
        used[source], compiled[role] = true, source
    end
    local settings, issue, which = compile_settings(descriptor.settings)
    if not settings then return nil, issue, which end
    local handle = table.freeze(setmetatable({}, Preset))
    states[handle] = { name = name, bindings = compiled, needed = needed, settings = settings }
    return handle
end

function Preset:name()
    local state = states[self]
    if not state then return nil, "invalid_preset" end
    return state.name
end
function Preset:bindings()
    local state = states[self]
    if not state then return nil, "invalid_preset" end
    return copy(state.bindings)
end
-- A fresh table each call, ready for Input.new or Mapping.new.
function Preset:settings()
    local state = states[self]
    if not state then return nil, "invalid_preset" end
    return copy(state.settings)
end
-- device is the uint32 routing key Input expects; ride_input_mapping.lua passes
-- the selected slot. available/focused/menu_open are the same constants it
-- writes: the caller has already refused unfocused and menu frames.
function Preset:raw(pad, device)
    local state = states[self]
    if not state then return nil, "invalid_preset" end
    if not integer(device, 0, 4294967295) then return nil, "invalid_device" end
    if not pad_valid(pad, state.needed) then return nil, "invalid_pad" end
    local buttons = pad.buttons
    local fields = { available = true, focused = true, menu_open = false, device = device,
        left_x = pad.left_x, left_y = pad.left_y, right_x = pad.right_x, right_y = pad.right_y }
    for role, source in pairs(state.bindings) do
        if trigger_axes[source] then fields[role] = pad[source]
        elseif role_kind[role] == "boolean" then fields[role] = buttons[source]
        else fields[role] = buttons[source] and 1 or 0 end
    end
    return Input.raw(fields)
end
table.freeze(Preset)

local order = { "default", "trigger_pedal", "left_handed" }
local builtins = {
    -- ride_input_mapping.lua raw_input: A pedals, B brakes, R3 quick hops, and
    -- the shoulders and triggers are the air trick modifiers.
    default = { name = "default", settings = {}, bindings = { pedal = "a", brake = "b",
        quick_hop = "right_stick", left_shoulder = "lb", right_shoulder = "rb",
        left_trigger = "left_trigger", right_trigger = "right_trigger" } },
    -- An analog throttle and brake on the triggers frees the right thumb on the
    -- ground: under default, pedalling on A takes that thumb off the stick that
    -- manuals and preloads hops. The cost is in the air. The trigger modifier
    -- roles move to West/East, and Input reads them in the same frame the right
    -- stick selects, so the right thumb cannot press them. On a standard grip
    -- only the shoulder sets (2, 3, 4) can be selected; sets 0, 1, 5, 6 and 7
    -- need a claw grip. L3 is the only other control a standard grip leaves
    -- free, one short of the two modifier roles.
    trigger_pedal = { name = "trigger_pedal", bindings = { pedal = "right_trigger", brake = "left_trigger",
        quick_hop = "right_stick", left_shoulder = "lb", right_shoulder = "rb",
        left_trigger = "x", right_trigger = "b" },
        -- XInput.h publishes 30/255 as XINPUT_GAMEPAD_TRIGGER_THRESHOLD. A
        -- throttle trigger resting just above Input's 0.05 would otherwise
        -- pedal and keep the mapper's neutral gate shut.
        settings = { trigger_neutral = 30 / 255 } },
    -- The default mirrored across the pad's vertical centre line: LB/RB, LT/RT,
    -- L3/R3 and West/East trade roles, South and North sit on the line. The
    -- sticks are not mirrored, for the reason given at stick_fields.
    left_handed = { name = "left_handed", settings = {}, bindings = { pedal = "a", brake = "x",
        quick_hop = "left_stick", left_shoulder = "rb", right_shoulder = "lb",
        left_trigger = "right_trigger", right_trigger = "left_trigger" } },
}
local compiled_builtins = {}

function Presets.names()
    return copy(order)
end
function Presets.get(name)
    local preset = compiled_builtins[name]
    if not preset then return nil, "unknown_preset" end
    return preset
end
-- A plain copy to start a custom preset from. compile() registers nothing;
-- get() only ever returns the built-ins.
function Presets.descriptor(name)
    local descriptor = builtins[name]
    if not descriptor then return nil, "unknown_preset" end
    return copy(descriptor)
end
Presets.compile = compile

-- A built-in that fails validation is a bug in this file, so requiring the
-- module fails loudly instead of offering a partial set.
for _, name in ipairs(order) do
    local preset, issue = compile(builtins[name])
    assert(preset and states[preset].name == name, issue)
    compiled_builtins[name] = preset
end
return table.freeze(Presets)

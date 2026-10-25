-- Constructed pads only; none is game input. The default preset is compared
-- with the raw snapshot the real ride_input_mapping.lua mapper builds from the
-- same sample, and with that mapper's action stream. No API runs at load.
local Presets = require("./input_presets")
local Mapping = require("./ride_input_mapping")
local Input = require("./input")
local catalog = require("./catalog")
local Tests = {}

local sdk_buttons = { "up", "down", "left", "right", "start", "back", "left_stick", "right_stick",
    "lb", "rb", "a", "b", "x", "y" }
local default_reads = { "a", "b", "right_stick", "lb", "rb" }
local never_read = { "up", "down", "left", "right", "y", "start", "back" }
local stick_fields = { "left_x", "left_y", "right_x", "right_y" }
local roles = { "pedal", "brake", "left_trigger", "right_trigger", "quick_hop", "left_shoulder", "right_shoulder" }

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
local function pad(axes, pressed)
    local p = { left_x = 0, left_y = 0, right_x = 0, right_y = 0, left_trigger = 0, right_trigger = 0,
        playstation = false, buttons = {} }
    for _, name in ipairs(sdk_buttons) do p.buttons[name] = false end
    for name, value in pairs(axes or {}) do p[name] = value end
    for name, value in pairs(pressed or {}) do p.buttons[name] = value end
    return p
end
local function combo(mask, names)
    local pressed = {}
    for index, name in ipairs(names) do pressed[name] = bit32.extract(mask, index - 1) == 1 end
    return pressed
end
-- Park-Miller keeps every product below 2^53, so the sequence is exact.
local function generator(seed)
    local state = seed
    return function()
        state = state * 16807 % 2147483647
        return state / 2147483647
    end
end
local function random_axes(random)
    return { left_x = random() * 2 - 1, left_y = random() * 2 - 1, right_x = random() * 2 - 1,
        right_y = random() * 2 - 1, left_trigger = random(), right_trigger = random() }
end
local function random_buttons(random)
    local pressed = {}
    for _, name in ipairs(sdk_buttons) do pressed[name] = random() < 0.5 end
    return pressed
end
-- Swap every left/right pair of non-stick controls; South and North stay.
local mirror_pairs = { { "lb", "rb" }, { "left_stick", "right_stick" }, { "b", "x" }, { "left", "right" } }
local function mirror(p)
    local m = copy(p)
    for _, pair in ipairs(mirror_pairs) do
        m.buttons[pair[1]], m.buttons[pair[2]] = p.buttons[pair[2]], p.buttons[pair[1]]
    end
    m.left_trigger, m.right_trigger = p.right_trigger, p.left_trigger
    return m
end

-- Drives the real mapper with one exact source identity. After each fresh
-- observation its private _raw holds what raw_input (lines 98-105) built.
-- Reading it is test-only inspection; no production accessor is added. A
-- pending hop is retired so a later R3 edge never blocks the next comparison.
local function mapper_probe(grounded, user)
    local mapping = Mapping.new()
    local handle, serial, ms = newproxy(), 100000, 500000
    local context = { grounded = grounded, focused = true, menu_open = false, rotation_reserved = false }
    local probe = {}
    function probe.observe(p)
        serial += 1
        ms += 1
        local observed = mapping:observe({ input_ok = true, lease_handle = handle, generation = 1,
            sample = { pad = p, user = user, sequence = "7", source_epoch = "11", context_generation = "13",
                observation_serial = string.format("%d", serial), observed_ms = string.format("%d", ms),
                packet = 17 } }, context)
        local raw = mapping._raw
        if observed.hop then mapping:retire_hop(observed.hop.id, "accepted") end
        return observed, raw
    end
    return probe
end

function Tests.run()
    local cases, assertions = 0, 0
    local function check(value, why) assertions += 1 assert(value, why) end
    local default = Presets.get("default")
    local trigger_pedal = Presets.get("trigger_pedal")
    local left_handed = Presets.get("left_handed")
    local function matches_mapper(probe, p, user)
        local observed, expected = probe.observe(p)
        check(observed.valid and observed.new_observation and type(expected) == "table",
            "the real mapper admitted the sample")
        check(equal(default:raw(p, user), expected), "default preset equals ride_input_mapping.lua raw_input")
    end

    do
        cases += 1
        check(equal(Presets.names(), { "default", "trigger_pedal", "left_handed" }), "three named presets in a fixed order")
        for _, name in ipairs(Presets.names()) do
            local preset = Presets.get(name)
            check(preset ~= nil and preset:name() == name, "each name resolves to its own preset")
            check(table.isfrozen(preset) and table.isfrozen(getmetatable(preset)), "the handle and its methods are frozen")
            check(not pcall(function() preset.raw = nil end), "a preset handle cannot be edited")
            check(not pcall(rawset, preset, "raw", function() return {} end), "rawset cannot shadow a method")
            check(not pcall(function() getmetatable(preset).raw = nil end), "the shared methods cannot be replaced")
            check(not pcall(setmetatable, preset, {}), "the handle's metatable cannot be swapped")
            check(rawget(preset, "raw") == nil and Presets.get(name) == preset and preset:raw(pad(), 0) ~= nil,
                "the built-in handle still maps after every attempt")
            local bindings, settings = preset:bindings(), preset:settings()
            bindings.pedal, settings.deadzone = "y", 0.4
            check(preset:bindings().pedal ~= "y" and preset:settings().deadzone ~= 0.4, "accessors return detached copies")
            local again = Presets.compile(Presets.descriptor(name))
            check(again ~= nil and again ~= preset and equal(again:bindings(), preset:bindings())
                and equal(again:settings(), preset:settings()), "a descriptor round-trips through compile")
        end
        local missing, issue = Presets.get("goofy")
        check(missing == nil and issue == "unknown_preset", "an unknown preset name refuses")
        check(Presets.get(nil) == nil and Presets.descriptor("goofy") == nil, "missing names never alias a built-in")
        check(Presets.compile((function() local d = Presets.descriptor("default"); d.name = "mine"; return d end)()) ~= nil
            and Presets.get("mine") == nil, "compile registers nothing")
        check(not pcall(function() Presets.extra = true end), "the module table is frozen")
        local forged, why = default.raw({}, pad(), 0)
        check(forged == nil and why == "invalid_preset", "a forged handle cannot map a pad")
        local forged_name, name_why = default.name({})
        check(forged_name == nil and name_why == "invalid_preset", "a forged handle has no name")
    end

    do
        cases += 1
        check(equal(default:bindings(), { pedal = "a", brake = "b", quick_hop = "right_stick",
            left_shoulder = "lb", right_shoulder = "rb", left_trigger = "left_trigger", right_trigger = "right_trigger" }),
            "default names the ride_input_mapping.lua:98-105 binding")
        check(equal(default:settings(), Input.new():settings()), "default settings are Input's own defaults")
        check(equal(default:settings(), Mapping.new()._settings), "default settings equal the mapper's sanitized defaults")
    end

    -- Every combination of all fourteen SDK buttons, with the axes cycling
    -- through every stick extreme and trigger end.
    local extremes = {}
    for _, lx in ipairs({ -1, 0, 1 }) do for _, ly in ipairs({ -1, 0, 1 }) do
        for _, rx in ipairs({ -1, 0, 1 }) do for _, ry in ipairs({ -1, 0, 1 }) do
            for _, lt in ipairs({ 0, 1 }) do for _, rt in ipairs({ 0, 1 }) do
                table.insert(extremes, { left_x = lx, left_y = ly, right_x = rx, right_y = ry,
                    left_trigger = lt, right_trigger = rt })
            end end
        end end
    end end
    do
        cases += 1
        local probe = mapper_probe(true, 2)
        for mask = 0, 16383 do
            matches_mapper(probe, pad(extremes[mask % #extremes + 1], combo(mask, sdk_buttons)), 2)
        end
    end

    do
        cases += 1
        local probe = mapper_probe(false, 1)
        for _, axes in ipairs(extremes) do
            for mask = 0, 31 do matches_mapper(probe, pad(axes, combo(mask, default_reads)), 1) end
        end
        -- Exact SDK endpoints: int16 sticks over 32768/32767, uint8 triggers over 255.
        local stick_values = { -1, -32767 / 32768, -1 / 32768, 0, 1 / 32767, 32766 / 32767, 1 }
        local trigger_values = { 0, 1 / 255, 30 / 255, 31 / 255, 254 / 255, 1 }
        for _, name in ipairs({ "left_x", "left_y", "right_x", "right_y", "left_trigger", "right_trigger" }) do
            for _, value in ipairs(string.find(name, "trigger") and trigger_values or stick_values) do
                for mask = 0, 31 do matches_mapper(probe, pad({ [name] = value }, combo(mask, default_reads)), 1) end
            end
        end
    end

    do
        cases += 1
        local random = generator(20261025)
        local probes = {}
        for user = 0, 3 do probes[user] = { [true] = mapper_probe(true, user), [false] = mapper_probe(false, user) } end
        for _ = 1, 3000 do
            local p = pad(random_axes(random), random_buttons(random))
            local roll = random()
            if roll < 1 / 3 then p.playstation = true elseif roll < 2 / 3 then p.playstation = false else p.playstation = nil end
            local user = math.floor(random() * 4)
            matches_mapper(probes[user][random() < 0.5], p, user)
        end
        -- The minimum the mapper admits: five buttons, no playstation flag.
        local minimal = { left_x = 0.25, left_y = -1, right_x = 1, right_y = 0, left_trigger = 0.5, right_trigger = 0,
            buttons = { a = true, b = false, right_stick = true, lb = false, rb = true } }
        matches_mapper(mapper_probe(true, 0), minimal, 0)
        -- Input-lease samples arrive frozen.
        local frozen = pad({ right_y = -1, left_trigger = 1 }, { a = true, lb = true, y = true })
        table.freeze(frozen.buttons)
        table.freeze(frozen)
        matches_mapper(mapper_probe(true, 3), frozen, 3)
    end

    -- The whole action stream, not just the raw table: the real mapper's
    -- observations against a separate Input mapper fed only the preset.
    for _, grounded in ipairs({ true, false }) do
        cases += 1
        local random = generator(grounded and 7 or 11)
        local probe, reference = mapper_probe(grounded, 2), Input.new(default:settings())
        local active, hops, tricks = 0, 0, 0
        for index = 1, 3000 do
            local roll, p = random(), nil
            if roll < 0.25 then
                p = pad()
            elseif roll < 0.55 then
                local angle = math.floor(random() * 8) * math.pi / 4
                local radius = random() < 0.5 and 1 or 0.5
                p = pad({ right_x = math.sin(angle) * radius, right_y = math.cos(angle) * radius,
                    left_trigger = random() < 0.3 and 1 or 0, right_trigger = random() < 0.3 and 1 or 0 },
                    { lb = random() < 0.3, rb = random() < 0.3 })
            elseif roll < 0.8 then
                p = pad({ left_x = random() * 2 - 1, left_y = random() * 2 - 1 },
                    { a = random() < 0.5, b = random() < 0.3, right_stick = random() < 0.3 })
            else
                p = pad(random_axes(random), random_buttons(random))
            end
            local observed = probe.observe(p)
            local expected = reference:update_observation(default:raw(p, 2), { grounded = grounded }, index == 1 and 0 or 1 / 1000)
            check(observed.valid and equal(observed.actions, expected), "mapper actions equal Input fed the default preset")
            if expected.active then active += 1 end
            if expected.hop_pressed then hops += 1 end
            if expected.movement ~= catalog.none then tricks += 1 end
        end
        check(active > 1000, "the trace is mostly ungated")
        check(grounded and hops > 20 or not grounded and tricks > 20, "the trace exercises hops on the ground and tricks in the air")
    end

    do
        cases += 1
        local random = generator(424242)
        for _, name in ipairs(Presets.names()) do
            local preset = Presets.get(name)
            for _, source in pairs(preset:bindings()) do
                for _, forbidden in ipairs(never_read) do check(source ~= forbidden, "no preset binds the D-pad, North, Start or Back") end
            end
            for _ = 1, 400 do
                local p = pad(random_axes(random), random_buttons(random))
                local raw = preset:raw(p, 1)
                for _, field in ipairs(stick_fields) do check(raw[field] == p[field], "sticks pass through unchanged") end
                for _, button in ipairs(never_read) do
                    local flipped = copy(p)
                    flipped.buttons[button] = not flipped.buttons[button]
                    check(equal(preset:raw(flipped, 1), raw), "D-pad, North, Start and Back never change the output")
                end
                local flag = copy(p)
                flag.playstation = not flag.playstation
                check(equal(preset:raw(flag, 1), raw), "the playstation flag never changes the output")
            end
        end
    end

    do
        cases += 1
        local r = trigger_pedal:raw(pad({ right_trigger = 0.6, left_trigger = 0.3 }), 1)
        check(r.pedal == 0.6 and r.brake == 0.3 and r.left_trigger == 0 and r.right_trigger == 0,
            "triggers are an analog throttle and brake, not modifiers")
        r = trigger_pedal:raw(pad(nil, { x = true, b = true, a = true }), 1)
        check(r.left_trigger == 1 and r.right_trigger == 1 and r.pedal == 0 and r.brake == 0,
            "West and East carry the trigger modifier roles; South is unbound")
        r = trigger_pedal:raw(pad(nil, { lb = true, rb = true, right_stick = true }), 1)
        check(r.left_shoulder and r.right_shoulder and r.quick_hop, "shoulders and R3 keep their default roles")
        local settings = trigger_pedal:settings()
        check(settings.trigger_neutral == 30 / 255, "the throttle uses XInput's published trigger threshold")
        for name, value in pairs(Input.new():settings()) do
            if name ~= "trigger_neutral" then check(settings[name] == value, "every other setting is Input's default") end
        end
        local mapper = Input.new(settings)
        local function step(p, grounded) return mapper:update(trigger_pedal:raw(p, 3), { grounded = grounded }, 1 / 60) end
        check(step(pad(), true).active, "neutral arms the trigger-pedal mapper")
        check(step(pad({ right_trigger = 30 / 255 }), true).pedal == 0, "a trigger resting at the threshold does not pedal")
        local half = step(pad({ right_trigger = 0.5 }), true)
        check(math.abs(half.pedal - (0.5 - 30 / 255) / (1 - 30 / 255)) < 1e-12, "half trigger is a proportional throttle")
        check(step(pad({ right_trigger = 1 }), true).pedal == 1, "full trigger is full pedal")
        check(step(pad({ left_trigger = 1 }), true).brake == 1, "LT brakes")
        step(pad(), false)
        check(step(pad({ right_x = 1 }, { x = true }), false).movement == catalog.select(6, 2),
            "West with the right stick selects the left-trigger trick set (a claw-grip input)")
        step(pad(), false)
        local whip = step(pad({ right_x = 1 }, { x = true, b = true }), false)
        check(whip.tailwhip == "right" and whip.movement == catalog.select(5, 2), "West and East reach the both-trigger tailwhip")
        step(pad(), false)
        check(step(pad({ right_x = 1, right_trigger = 1 }), false).movement == catalog.none,
            "a held throttle never selects a trick set")
        local stock = Input.new()
        stock:update(default:raw(pad(), 3), { grounded = false }, 1 / 60)
        check(stock:update(default:raw(pad({ right_x = 1, right_trigger = 1 }), 3), { grounded = false }, 1 / 60).movement
            == catalog.select(7, 2), "the same pad under default does select the right-trigger set")
    end

    do
        cases += 1
        local r = left_handed:raw(pad(nil, { a = true, x = true }), 0)
        check(r.pedal == 1 and r.brake == 1, "South pedals and West brakes")
        r = left_handed:raw(pad(nil, { b = true, right_stick = true }), 0)
        check(r.pedal == 0 and r.brake == 0 and r.quick_hop == false, "East and R3 are free")
        r = left_handed:raw(pad(nil, { left_stick = true, lb = true }), 0)
        check(r.quick_hop and r.right_shoulder and not r.left_shoulder, "L3 quick hops and LB is the right shoulder role")
        r = left_handed:raw(pad({ left_trigger = 0.25, right_trigger = 0.75 }), 0)
        check(r.right_trigger == 0.25 and r.left_trigger == 0.75, "the triggers trade modifier roles")
        check(equal(left_handed:settings(), Input.new():settings()), "mirroring changes no threshold")
        local random = generator(99)
        for mask = 0, 16383 do
            local p = pad(random_axes(random), combo(mask, sdk_buttons))
            check(equal(left_handed:raw(mirror(p), 1), default:raw(p, 1)), "left_handed is default mirrored, sticks excepted")
        end
        local mapper = Input.new(left_handed:settings())
        local function step(p, grounded) return mapper:update(left_handed:raw(p, 4), { grounded = grounded }, 1 / 60) end
        check(step(pad(), false).active, "neutral arms the left-handed mapper")
        local spin = step(pad({ right_y = -1 }, { rb = true }), false)
        check(spin.movement == catalog.select(3, 4) and spin.handlebar == "left", "RB supplies the left shoulder trick set")
        step(pad(), true)
        local hop = step(pad(nil, { left_stick = true }), true)
        check(hop.hop_pressed and hop.hop_strength == 1, "L3 is the quick hop")
        step(pad(), true)
        check(not step(pad(nil, { right_stick = true }), true).hop_pressed, "R3 no longer hops")
    end

    -- A constructed grip model, not a feel test. Input reads the modifiers in
    -- the frame the right stick selects, so the right thumb is on that stick.
    -- A standard grip can then hold only what the index and middle fingers
    -- reach: LB, RB, LT and RT. A claw grip adds an index finger on West/East.
    do
        cases += 1
        local axis_controls = { left_trigger = true, right_trigger = true }
        local standard = { "lb", "rb", "left_trigger", "right_trigger" }
        local claw = { "lb", "rb", "left_trigger", "right_trigger", "x", "b" }
        local function reachable(preset, controls)
            local found = {}
            for mask = 0, bit32.lshift(1, #controls) - 1 do
                for slot = 0, 7 do
                    local angle = slot * math.pi / 4
                    local axes, pressed = { right_x = math.sin(angle), right_y = math.cos(angle) }, {}
                    for index, name in ipairs(controls) do
                        local held = bit32.extract(mask, index - 1) == 1
                        if axis_controls[name] then axes[name] = held and 1 or 0 else pressed[name] = held end
                    end
                    local mapper = Input.new(preset:settings())
                    mapper:update(preset:raw(pad(), 1), { grounded = false }, 1 / 60)
                    local movement = mapper:update(preset:raw(pad(axes, pressed), 1), { grounded = false }, 1 / 60).movement
                    if movement ~= catalog.none then found[math.floor(movement / 10)] = true end
                end
            end
            local sets = {}
            for set = 0, 7 do if found[set] then table.insert(sets, set) end end
            return sets
        end
        local all = { 0, 1, 2, 3, 4, 5, 6, 7 }
        check(equal(reachable(default, standard), all), "default reaches all eight sets on a standard grip")
        check(equal(reachable(left_handed, standard), all), "left_handed reaches all eight sets on a standard grip")
        check(equal(reachable(trigger_pedal, standard), { 2, 3, 4 }),
            "trigger_pedal reaches only the shoulder sets on a standard grip")
        check(equal(reachable(trigger_pedal, claw), all), "trigger_pedal needs a claw grip for the trigger sets")
    end

    do
        cases += 1
        local function mutated(change)
            local d = Presets.descriptor("default")
            change(d)
            return d
        end
        local rows = {
            { "invalid_preset", "default" },
            { "invalid_preset", setmetatable({}, { __index = Presets.descriptor("default") }) },
            { "unknown_preset_field", mutated(function(d) d.extra = 1 end) },
            { "invalid_name", mutated(function(d) d.name = nil end) },
            { "invalid_name", mutated(function(d) d.name = "Bad Name" end) },
            { "invalid_name", mutated(function(d) d.name = string.rep("a", 33) end) },
            { "invalid_bindings", mutated(function(d) d.bindings = nil end) },
            { "invalid_bindings", mutated(function(d) d.bindings = setmetatable({}, { __index = d.bindings }) end) },
            { "role_unbound", mutated(function(d) d.bindings.pedal = nil end) },
            { "unknown_role", mutated(function(d) d.bindings.wheelie = "x" end) },
            { "unknown_role", mutated(function(d) d.bindings[1] = "x" end) },
            { "stick_binding_refused", mutated(function(d) d.bindings.left_x = "right_x" end) },
            { "stick_source_refused", mutated(function(d) d.bindings.pedal = "left_y" end) },
            { "invalid_source", mutated(function(d) d.bindings.pedal = 1 end) },
            { "unknown_source", mutated(function(d) d.bindings.pedal = "z" end) },
            { "boolean_role_needs_button", mutated(function(d) d.bindings.quick_hop = "right_trigger" end) },
            { "source_bound_twice", mutated(function(d) d.bindings.brake = "a" end) },
            { "invalid_settings", mutated(function(d) d.settings = 5 end) },
            { "invalid_settings", mutated(function(d) d.settings = setmetatable({}, {}) end) },
            { "unknown_setting", mutated(function(d) d.settings = { wobble = 1 } end) },
            { "invalid_setting", mutated(function(d) d.settings = { deadzone = "0.1" } end) },
            { "invalid_setting", mutated(function(d) d.settings = { deadzone = 0 / 0 } end) },
            { "invalid_setting", mutated(function(d) d.settings = { deadzone = math.huge } end) },
            { "setting_out_of_range", mutated(function(d) d.settings = { deadzone = 0.9 } end) },
            { "setting_out_of_range", mutated(function(d) d.settings = { max_sample_seconds = 0 } end) },
            { "setting_out_of_range", mutated(function(d) d.settings = { hop_back_threshold = 0.6, manual_threshold = 0.55 } end) },
            -- Input would lift the unnamed modifier_threshold from 0.2 to 0.25.
            { "dependent_setting_out_of_range", mutated(function(d) d.settings = { trigger_neutral = 0.2 } end) },
        }
        local reserved = { up = "dpad_reserved", down = "dpad_reserved", left = "dpad_reserved", right = "dpad_reserved",
            y = "north_reserved", start = "menu_reserved", back = "menu_reserved" }
        for _, role in ipairs(roles) do
            for _, source in ipairs(never_read) do
                table.insert(rows, { reserved[source], mutated(function(d) d.bindings[role] = source end) })
            end
        end
        for _, row in ipairs(rows) do
            local preset, issue = Presets.compile(row[2])
            check(preset == nil and issue == row[1], "an invalid preset refuses with its reason")
        end
        local tuned = Presets.compile(mutated(function(d) d.name = "tuned"; d.settings = { deadzone = 0.2 } end))
        check(tuned ~= nil and tuned:settings().deadzone == 0.2, "an in-range override is kept exactly")
        check(equal(tuned:settings(), Input.new({ deadzone = 0.2 }):settings()), "and the rest of its bundle is sanitized Input")
        check(Input.new({ trigger_neutral = 0.2 }):settings().modifier_threshold == 0.25,
            "Input does move the dependent default this row relies on")
        local _, issue, which = Presets.compile(mutated(function(d) d.settings = { trigger_neutral = 0.2 } end))
        check(issue == "dependent_setting_out_of_range" and which == "modifier_threshold", "the refusal names the moved setting")
        local named = Presets.compile(mutated(function(d) d.settings = { trigger_neutral = 0.2, modifier_threshold = 0.25 } end))
        check(named ~= nil and named:settings().trigger_neutral == 0.2 and named:settings().modifier_threshold == 0.25,
            "naming the dependent value explicitly compiles")
        for _, name in ipairs(Presets.names()) do
            local settings = Presets.get(name):settings()
            check(equal(settings, Input.new(settings):settings()), "every bundle is complete and a sanitize fixed point")
        end
    end

    do
        cases += 1
        local bad = {
            function() return nil end,
            function() return "pad" end,
            function() return setmetatable(pad(), {}) end,
            function() local p = pad(); setmetatable(p.buttons, {}); return p end,
            function() local p = pad(); p.buttons = nil; return p end,
            function() local p = pad(); p.left_x = 0 / 0; return p end,
            function() local p = pad(); p.right_y = 1.5; return p end,
            function() local p = pad(); p.left_y = "0"; return p end,
            function() local p = pad(); p.left_trigger = -0.1; return p end,
            function() local p = pad(); p.right_trigger = math.huge; return p end,
            function() local p = pad(); p.buttons.a = 1; return p end,
            function() local p = pad(); p.buttons.turbo = false; return p end,
            function() local p = pad(); p.mode = "x"; return p end,
            function() local p = pad(); p.playstation = 1; return p end,
            function() local p = pad(); p.buttons.rb = nil; return p end,
        }
        local probe = mapper_probe(true, 2)
        for _, make in ipairs(bad) do
            for _, name in ipairs(Presets.names()) do
                local raw, issue = Presets.get(name):raw(make(), 2)
                check(raw == nil and issue == "invalid_pad", "a malformed pad refuses")
            end
            local observed = probe.observe(make())
            check(not observed.valid and observed.issue == "invalid_source_sample", "the hardcoded mapper refuses the same pad")
        end
        local no_west = pad()
        no_west.buttons.x = nil
        matches_mapper(probe, no_west, 2)
        check(trigger_pedal:raw(no_west, 2) == nil and left_handed:raw(no_west, 2) == nil,
            "a preset that reads West refuses a pad without it")
        for _, device in ipairs({ -1, 0.5, 4294967296, "1", 0 / 0 }) do
            local raw, issue = default:raw(pad(), device)
            check(raw == nil and issue == "invalid_device", "an invalid device refuses")
        end
        check(default:raw(pad(), nil) == nil, "a missing device refuses")
        check(default:raw(pad(), 0).device == 0 and default:raw(pad(), 4294967295).device == 4294967295,
            "the whole uint32 device range is accepted")
    end

    return { cases = cases, assertions = assertions, constructed = true, native_authority = false, gameplay = false }
end
return Tests

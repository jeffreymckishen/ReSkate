-- Switching is an explicit menu action. The input policy inspector below stays
-- read-only; neither path activates a BMX body, rider pose or old controller.
local Input = require("./input")
local catalog = require("./catalog")
local EquipmentRuntime = require("./equipment_runtime")
local equipment = EquipmentRuntime.new()
local switch_request = "No switch requested."
local mapper = Input.new()
local observing = false
local source_epoch = 1
local context_choice = 1
local status = "Stopped. This package cannot activate BMX riding."
local last_actions = Input.actions()
local last_hop = "None observed"
local last_trick = "None observed"
local samples = 0
local last_seconds = 0

local function reset()
    mapper:reset()
    last_actions = Input.actions()
    last_hop, last_trick, samples, last_seconds = "None observed", "None observed", 0, 0
end

reskate.on("tick", function(dt_ms)
    -- Receipt cleanup must keep running when input observation is stopped.
    equipment:update()
    if not observing then return end
    local focus = reskate.input.focus()
    local pad = reskate.input.gamepad()
    if not focus or not pad or not focus.focused or focus.interface_open or not focus.gameplay then
        mapper:reset()
        status = "Paused by focus, menu, gameplay readiness or unavailable pad. Close the menu to observe."
        return
    end
    local buttons = pad.buttons or {}
    local raw = Input.raw({
        available = true, focused = focus.focused, menu_open = focus.interface_open,
        device = source_epoch,
        left_x = pad.left_x, left_y = pad.left_y, right_x = pad.right_x, right_y = pad.right_y,
        pedal = buttons.a and 1 or 0, brake = buttons.b and 1 or 0,
        quick_hop = buttons.right_stick == true,
        left_trigger = pad.left_trigger, right_trigger = pad.right_trigger,
        left_shoulder = buttons.lb == true, right_shoulder = buttons.rb == true,
    })
    -- This is wall-time model inspection, NOT a native physics step/receipt.
    -- The context is explicitly selected below, never inferred as wheel support.
    last_seconds = dt_ms / 1000
    last_actions = mapper:update(raw, { grounded = context_choice == 1 }, last_seconds)
    samples = samples + 1
    if last_actions.hop_pressed then
        last_hop = string.format("Sample %d: strength %.3f; request only", samples, last_actions.hop_strength)
    end
    if last_actions.movement ~= catalog.none then
        last_trick = string.format("Sample %d: %s (%d); request only", samples,
            catalog.name(last_actions.movement) or "Unknown", last_actions.movement)
    end
    status = last_actions.active and "Policy sample accepted. No gameplay action was dispatched."
        or "Policy gated. Release sticks, pedals, brakes, R3 and modifiers; gaps above 100 ms reset it."
end)

reskate.menu.page("BMX Lua migration", function(ui)
    ui:warn("Lua BMX riding is not connected yet. These buttons switch the skateboard and on-foot state only.")
    ui:note("Choose your controller slot, close the menu, and leave every control released. Each click requests one switch.")
    for slot = 0, 3 do
        if ui:button("equipment" .. slot, "Switch skateboard / on foot: slot " .. slot) then
            local accepted, why = equipment:request(slot)
            switch_request = accepted and "Armed. Close the menu and release every control."
                or string.sub(tostring(why or "Request refused"), 1, 160)
        end
    end
    local switch = equipment:status()
    ui:info("Switch phase", tostring(switch.phase or "idle"))
    ui:info("Switch result", tostring(switch.outcome or "idle"))
    ui:info("Switch detail", tostring(switch.detail or switch.reason or "No request"))
    ui:info("Last switch click", switch_request)
    if switch.receipt then
        ui:info("Last input report", tostring(switch.receipt.status) .. " / " .. tostring(switch.receipt.reason))
    end
    ui:note("The controller inspector below records requests only. It does not execute hops or tricks.")
    ui:note("Observation uses wall-time and a selected model context, not native wheel support or a physics clock.")
    if ui:button("observe", observing and "Stop observing" or "Observe controller") then
        observing = not observing
        reset()
        status = observing and "Close the menu, then release every control to arm the model."
            or "Stopped. No gameplay or input ownership was changed."
    end
    local next_context = ui:tabs("context", { "Grounded model", "Airborne model" }, context_choice)
    if next_context ~= context_choice then context_choice = next_context; reset() end
    if ui:button("source", "New manual source epoch / reset") then
        source_epoch = (source_epoch + 1) % 4294967296
        reset()
    end
    ui:info("Status", status)
    ui:info("Source epoch", tostring(source_epoch) .. " (manual; the native API does not expose device identity)")
    ui:info("Model timing", string.format("%.5f wall seconds; %d samples", last_seconds, samples))
    ui:info("Last sample active", tostring(last_actions.active))
    ui:info("Steer / pitch request", string.format("%.3f / %.3f", last_actions.steer, last_actions.air_pitch))
    ui:info("Pedal / brake request", string.format("%.3f / %.3f", last_actions.pedal, last_actions.brake))
    ui:info("Preload / manual / nose", string.format("%.3f / %.3f / %.3f",
        last_actions.preload, last_actions.manual, last_actions.nose_manual))
    ui:info("Last hop request", last_hop)
    ui:info("Last trick request", last_trick)
    ui:note("Menu/focus loss resets gestures. After replacing a pad, choose New manual source epoch; replacement is not auto-detected.")
end)

reskate.on("unload", function()
    equipment:unload()
    observing = false
    mapper:reset()
end)

-- One lifecycle owner handles explicit requests and cleanup. Public mounting
-- stays unavailable; the controller policy inspector remains read-only.
local Input, catalog
local BikeRuntime = require("./bike_runtime")
local bike = BikeRuntime.new()
-- Dependencies precede their users so each idle tick compiles at most one cold
-- chunk. Construction and its one storage read have a separate tick.
local score_modules = {"./catalog", "./motions", "./tricks", "./lease_identity", "./force_math",
    "./frame_identity", "./trick_runtime", "./trick_names", "./score_rules", "./score_catalog",
    "./score_line", "./score_feed", "./score_hud", "./score_runtime"}
local score, ScoreRuntime
local score_index = 1
local score_failed = false
local score_detail = "Preparing local scoring."
local function prepare_score()
    local name = score_modules[score_index]
    if name then
        local ok, value = pcall(require, name)
        if not ok then
            score_failed = true
            score_detail = "Local scoring could not load. Reload the plugin to try again."
        else
            if name == "./catalog" then catalog = value end
            if name == "./score_runtime" then ScoreRuntime = value end
            score_index += 1
        end
        return
    end
    local ok, value = pcall(ScoreRuntime.new, {storage = {
        get = reskate.storage.get, set = reskate.storage.set,
    }})
    if ok then
        score = value
        score_detail = "Ready. Scores are saved locally."
    else
        score_failed = true
        score_detail = "Local scoring could not start. Reload the plugin to try again."
    end
end
local function score_idle(lifecycle)
    return (lifecycle.phase == "idle" or lifecycle.phase == "done")
        and not lifecycle.bike_authority and not lifecycle.cleanup_pending and not lifecycle.cleanup_unknown
        and not (lifecycle.board_return and lifecycle.board_return.pending)
end
local function drain_score()
    if not score then return end
    local previous = score:status()
    local log = bike:score_feed(previous.cursor)
    if type(log.generation) == "number" and log.generation > 0
        and (previous.generation == nil or log.generation > previous.generation)
        and previous.cursor ~= 0 then
        local generation = log.generation
        log = bike:score_feed(0)
        if log.generation ~= generation then
            -- Refuse a changing producer without inventing a physical sample.
            score:update({issue = "score_feed_generation_changed", steps = {{terminal = {
                outcome = "interrupted", reason = "score_feed_generation_changed",
            }}}})
            return
        end
    end
    score:ride(log)
end
local mount_request = "Unavailable: native lifecycle qualification has not completed."
local stop_request = "No stop requested."
local switch_request = "No switch requested."
local board_request = "No board return requested."
local mapper
local observing = false
local source_epoch = 1
local context_choice = 1
local status = "Stopped. This package cannot activate BMX riding."
local last_actions
local last_hop = "None observed"
local last_trick = "None observed"
local samples = 0
local last_seconds = 0

local function reset()
    if mapper then mapper:reset() end
    last_actions = Input and Input.actions() or nil
    last_hop, last_trick, samples, last_seconds = "None observed", "None observed", 0, 0
end

reskate.on("tick", function(dt_ms)
    -- Receipt cleanup must keep running when input observation is stopped.
    local lifecycle = bike:step(dt_ms)
    if lifecycle.startup and lifecycle.startup.work_this_tick then return end
    if not score and not score_failed and score_idle(lifecycle) then
        prepare_score()
        return
    end
    if score then
        score:advance(dt_ms / 1000) -- Banner expiry only; log rows carry measured physics time.
        drain_score()
    end
    if not observing then return end
    -- Inspector chunks are independent of lifecycle cleanup and load on demand.
    if not catalog then catalog = require("./catalog"); return end
    if not Input then Input = require("./input"); mapper = Input.new(); last_actions = Input.actions(); return end
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
    ui:warn("BMX mounting is unavailable while native lifecycle qualification remains incomplete. This package is not rideable.")
    ui:note("Mount requests stay disabled in public mode. Return to skateboard waits for cleanup; stock toggles require clear bike ownership.")
    for slot = 0, 3 do
        if ui:button("bike_mount" .. slot, "Mount bike (unavailable): slot " .. slot) then
            local accepted, why
            if bike:status().qualification_only and not score then
                accepted, why = false, "Local scoring must be ready before mounting."
            else
                accepted, why = bike:request_mount(slot)
            end
            mount_request = accepted and "Mount intent accepted; inspect the lifecycle status."
                or string.sub(tostring(why or "Mount unavailable"), 1, 160)
        end
    end
    if ui:button("bike_stop", "Stop bike / cleanup") then
        local accepted, why = bike:request_stop("explicit menu stop")
        stop_request = accepted and "Stop requested. Cleanup continues on ticks."
            or string.sub(tostring(why or "No active bike request"), 1, 160)
    end
    ui:note("Return to skateboard stops the bike and waits for cleanup. Close the menu and leave every control released; Stop cancels the return.")
    for slot = 0, 3 do
        if ui:button("bike_board" .. slot, "Return to skateboard: slot " .. slot) then
            local accepted, why = bike:request_board(slot)
            board_request = accepted and "Return accepted; inspect the return status. Close the menu and release every control."
                or string.sub(tostring(why or "Return refused"), 1, 160)
        end
    end
    ui:note("For stock switching, choose your controller slot, close the menu, and leave every control released. Each click requests one switch.")
    for slot = 0, 3 do
        if ui:button("equipment" .. slot, "Switch skateboard / on foot: slot " .. slot) then
            local accepted, why = bike:request_stock_toggle(slot)
            switch_request = accepted and "Armed. Close the menu and release every control."
                or string.sub(tostring(why or "Request refused"), 1, 160)
        end
    end
    local lifecycle = bike:status()
    ui:info("Bike phase", tostring(lifecycle.phase or "idle"))
    ui:info("Bike detail", tostring(lifecycle.detail or "Unavailable"))
    ui:info("Mount enabled", tostring(lifecycle.mount_enabled == true))
    ui:info("Bike authority", tostring(lifecycle.bike_authority == true))
    ui:info("Cleanup pending / unknown", tostring(lifecycle.cleanup_pending == true) .. " / " .. tostring(lifecycle.cleanup_unknown == true))
    ui:info("Stock toggle blocked", tostring(lifecycle.stock_toggle_blocked == true))
    ui:info("Last mount click", mount_request)
    ui:info("Last stop click", stop_request)
    local board = lifecycle.board_return or {}
    ui:info("Board return phase", tostring(board.phase or "idle"))
    ui:info("Board return detail", tostring(board.detail or "No board return requested."))
    ui:info("Last board return click", board_request)
    local switch = lifecycle.equipment or {}
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
    if not last_actions then ui:note("No controller sample; Observe loads the inspector on later ticks."); return end
    ui:info("Last sample active", tostring(last_actions.active))
    ui:info("Steer / pitch request", string.format("%.3f / %.3f", last_actions.steer, last_actions.air_pitch))
    ui:info("Pedal / brake request", string.format("%.3f / %.3f", last_actions.pedal, last_actions.brake))
    ui:info("Preload / manual / nose", string.format("%.3f / %.3f / %.3f",
        last_actions.preload, last_actions.manual, last_actions.nose_manual))
    ui:info("Last hop request", last_hop)
    ui:info("Last trick request", last_trick)
    ui:note("Menu/focus loss resets gestures. After replacing a pad, choose New manual source epoch; replacement is not auto-detected.")
end)

reskate.on("draw", function(d)
    if score then score:draw(d) end
end)

reskate.menu.panel("BMX local scores", function(ui)
    ui:info("Local scoring", score_detail)
    if not score then return end
    local current = score:status()
    local stats = current.stats
    ui:info("Best line", tostring(stats.best_line))
    ui:info("Best single air", tostring(stats.best_single_air))
    ui:info("Total banked score", tostring(stats.session_total))
    ui:info("Session best line", tostring(stats.session_best_line))
    ui:info("Session best air", tostring(stats.session_best_air))
    if current.storage_issue ~= "none" then
        ui:note("Scores remain in memory while local saving is unavailable.")
    end
end)

reskate.on("unload", function()
    bike:unload()
    drain_score() -- Cleanup publishes the final retained control row before this read.
    observing = false
    if mapper then mapper:reset() end
end)

-- Pure Luau source tests. Nothing runs on require; call require("./tests").run()
-- from a future quiet-window Host test or a compatible Luau runner.
-- No game, native body, camera, capture, filesystem or reskate service is used.
local Input = require("./input")
local catalog = require("./catalog")
local tests = {}

function tests.run()
    local assertions, cases = 0, 0
    local function check(condition, message)
        assertions = assertions + 1
        assert(condition, message)
    end
    local function near(a, b) return math.abs(a - b) < 1e-9 end
    local ground, air = { grounded = true }, { grounded = false }
    local dt = 1 / 60
    local function pad(changes)
        local raw = Input.raw({ available = true, device = 7 })
        for key, value in pairs(changes or {}) do raw[key] = value end
        return raw
    end
    local function step(mapper, raw, context, seconds)
        return mapper:update(raw or pad(), context or ground, seconds or dt)
    end
    local function ready(mapper, context)
        local result = step(mapper, pad(), context)
        check(result.active, "neutral source must arm the actual mapper")
    end
    local function event(actions)
        return actions.hop_pressed or actions.handlebar ~= "none" or actions.tailwhip ~= "none"
            or actions.movement ~= catalog.none
    end

    -- Independent authored slot oracle: every missing cell is deliberately255.
    local slots = {
        { 0, 1, 2, 3, 4, 5, 6, 7 }, { 10, 11, 12, 13, 14, 15, 16, 17 },
        { 20, 21, 22, 23, 24, 25, 26, 27 }, { 255, 31, 32, 33, 34, 35, 36, 37 },
        { 255, 41, 42, 43, 44, 45, 46, 47 }, { 50, 51, 52, 53, 54, 55, 56, 57 },
        { 255, 61, 62, 63, 255, 65, 66, 67 }, { 255, 71, 72, 73, 255, 75, 76, 77 },
    }
    local populated = 0
    for set = 0, 7 do
        for slot = 0, 7 do
            local expected = slots[set + 1][slot + 1]
            check(catalog.select(set, slot) == expected, "all64 authored selector slots retain identity")
            if expected ~= 255 then
                populated = populated + 1
                check(catalog.valid(expected) and catalog.name(expected) ~= nil, "every selected ID has a named record")
            end
        end
    end
    check(populated == 58, "complete selection catalog has58 populated identities")
    for _, invalid in ipairs({ -1, 8, 0.5, math.huge }) do
        check(catalog.select(invalid, 0) == 255 and catalog.select(0, invalid) == 255, "invalid selector coordinates refuse")
    end
    check(catalog.valid(255) and not catalog.valid(30) and not catalog.valid(64), "catalog holes never alias a request")
    cases = cases + 1

    do
        local mapper = Input.new()
        check(not step(mapper, pad({ pedal = 1 })).active, "new mapper refuses held pedal")
        ready(mapper)
        local a = step(mapper, pad({ left_x = 1, left_y = 1, pedal = 1, brake = 0.5 }))
        check(near(a.steer, math.sqrt(0.5)) and near(a.front_weight, math.sqrt(0.5)), "diagonal sticks preserve radial unit-disc normalization")
        check(near(a.pedal, 1) and near(a.brake, 0.45 / 0.95), "pedal and brake use original trigger remapping")
        check(near(step(mapper, pad({ left_x = 0.12 })).steer, 0), "deadzone boundary is neutral")
        check(near(step(mapper, pad({ pedal = 1 }), air).pedal, 0), "no airborne pedal propulsion")
        mapper:reset()
        check(not step(mapper, pad({ quick_hop = true })).active, "reset never accepts a held quick hop")
        cases = cases + 1
    end

    do
        local mapper = Input.new()
        ready(mapper)
        for _ = 1, 30 do
            local a = step(mapper, pad({ right_y = -1 }))
            check(not a.hop_pressed and a.preload > 0 and a.preload <= 1, "held back charges exactly one pending hop")
        end
        local a = step(mapper, pad({ right_y = 1 }))
        check(a.hop_pressed and near(a.hop_strength, 1) and a.preload == 0, "full charge releases a full-strength hop")
        for _ = 1, 8 do check(not step(mapper, pad({ right_y = 1 })).hop_pressed, "held forward cannot repeat hop") end
        step(mapper, pad({ right_y = -1 }))
        check(not step(mapper, pad({ right_y = 1 })).hop_pressed, "back-forward without neutral cannot rearm")
        ready(mapper)
        step(mapper, pad({ right_y = -1 })); step(mapper, pad())
        a = step(mapper, pad({ right_y = 1 }))
        check(a.hop_pressed and a.hop_strength >= 0.25 and a.hop_strength < 1, "quick flick through neutral retains bounded weak-hop strength")
        cases = cases + 1
    end

    do
        local mapper = Input.new(); ready(mapper)
        step(mapper, pad({ right_y = -1 }))
        for _ = 1, 30 do check(not step(mapper).hop_pressed, "neutral alone never releases hop") end
        check(not step(mapper, pad({ right_y = 1 })).hop_pressed, "late forward after timeout refuses")
        ready(mapper); step(mapper, pad({ right_y = -1 }))
        step(mapper, pad({ right_x = 0.9, right_y = 0.6 }))
        check(not step(mapper, pad({ right_y = 1 })).hop_pressed, "lateral cancellation cannot resume a stale hop")
        ready(mapper); step(mapper, pad({ right_y = -1 }))
        check(not event(step(mapper, pad({ right_y = -1 }), air)), "takeoff discards grounded preload")
        check(not step(mapper, pad({ right_y = 1 }), air).hop_pressed, "airborne flick cannot hop")
        step(mapper, pad({ right_y = -1 }), ground)
        check(not step(mapper, pad({ right_y = 1 }), ground).hop_pressed, "preheld landing stick cannot ghost-hop")
        cases = cases + 1
    end

    do
        local mapper = Input.new(); ready(mapper)
        check(step(mapper, pad({ right_y = -0.55 })).manual > 0, "partial back enters manual")
        check(step(mapper, pad({ right_y = 0.55 })).nose_manual > 0, "partial forward enters nose manual")
        check(step(mapper, pad({ right_x = 0.9, right_y = 0.55 })).nose_manual == 0, "lateral stick cannot create balance")
        check(step(mapper, pad({ right_y = -0.55 }), air).manual == 0, "airborne stick cannot claim a manual")
        check(step(mapper, pad({ right_y = -0.55 }), ground).manual == 0, "held landing needs neutral")
        ready(mapper)
        check(step(mapper, pad({ right_y = -0.55 })).manual > 0, "landing neutral rearms manual")
        cases = cases + 1
    end

    do
        local mapper = Input.new(); ready(mapper)
        check(step(mapper, pad({ quick_hop = true })).hop_pressed, "fresh R3 requests hop")
        check(not step(mapper, pad({ quick_hop = true }), air).hop_pressed, "held R3 never adds airborne impulse")
        check(not step(mapper, pad({ quick_hop = true }), ground).hop_pressed, "held R3 does not rearm on landing")
        step(mapper, pad())
        check(step(mapper, pad({ quick_hop = true })).hop_pressed, "R3 release rearms once")
        cases = cases + 1
    end

    -- LB1/RB2/LT4/RT8. This independent precedence table includes unsupported
    -- authored sets instead of falling through to a convenient legacy trick.
    local sets = { -1, 3, 4, 2, 6, 3, 1, 1, 7, 0, 4, 0, 5, 0, 1, 0 }
    local d = math.sqrt(0.5)
    local directions = { { 0, 1 }, { d, d }, { 1, 0 }, { d, -d }, { 0, -1 }, { -d, -d }, { -1, 0 }, { -d, d } }
    for mask = 0, 15 do
        for slot = 0, 7 do
            local mapper = Input.new(); ready(mapper, air)
            local raw = pad({
                left_shoulder = mask % 2 == 1, right_shoulder = math.floor(mask / 2) % 2 == 1,
                left_trigger = math.floor(mask / 4) % 2, right_trigger = math.floor(mask / 8) % 2,
                right_x = directions[slot + 1][1], right_y = directions[slot + 1][2],
            })
            local a, set = step(mapper, raw, air), sets[mask + 1]
            local expected = set < 0 and 255 or slots[set + 1][slot + 1]
            check(a.active and a.movement == expected, "all16 modifier combinations x8 sectors select exact catalog identity")
            local bar = set == 3 and slot == 4 and "left" or set == 4 and slot == 4 and "right" or "none"
            local tail = set == 5 and slot == 2 and "right" or set == 5 and slot == 6 and "left" or "none"
            check(a.handlebar == bar and a.tailwhip == tail, "legacy bar/tail outputs match named IDs")
            for _ = 1, 3 do check(not event(step(mapper, raw, air)), "held selector never repeats") end
            raw.right_x, raw.right_y = -raw.right_x, -raw.right_y
            check(not event(step(mapper, raw, air)), "opposite direction without neutral is consumed")
        end
    end
    cases = cases + 1

    do
        local mapper = Input.new(); ready(mapper)
        local raw = pad({ left_shoulder = true, right_y = -1 })
        check(not event(step(mapper, raw)), "grounded air selection cannot dispatch")
        for _ = 1, 5 do check(not event(step(mapper, raw, air)), "held takeoff selector requires airborne neutral") end
        raw.right_y = 0; step(mapper, raw, air); raw.right_y = -1
        check(step(mapper, raw, air).handlebar == "left", "airborne RS neutral rearms while modifier stays held")
        raw.right_y = 0; step(mapper, raw, air); raw.right_y = -1
        check(step(mapper, raw, air).handlebar == "left", "second neutral rearms distinct barspin request")
        raw.left_shoulder = false; step(mapper, raw, air); raw.left_shoulder = true
        check(not event(step(mapper, raw, air)), "modifier-only release does not rearm deflected selector")
        mapper:reset(); ready(mapper, air)
        raw = pad({ left_shoulder = true, right_y = 1 }); check(not event(step(mapper, raw, air)), "empty slot remains empty")
        raw.right_y = -1; check(not event(step(mapper, raw, air)), "empty slot still consumes attempted gesture")
        cases = cases + 1
    end

    do
        local mapper = Input.new(); ready(mapper)
        local raw = pad({ left_y = -1 })
        check(step(mapper, raw, air).air_pitch == 0, "held takeoff LS pitch needs airborne neutral")
        step(mapper, pad(), air)
        check(step(mapper, raw, air).air_pitch < -0.9, "airborne LS neutral then down requests front up")
        local diagonal = step(mapper, pad({ left_x = 0.7, left_y = 0.7 }), air)
        check(diagonal.steer > 0 and diagonal.air_pitch > 0, "armed diagonal keeps yaw plus flip")
        check(step(mapper, pad({ right_y = -1 }), air).air_pitch == 0, "rear stick never aliases LS flip")
        cases = cases + 1
    end

    do
        for _, radius in ipairs({ 0.699, 0.7, 0.701 }) do
            local mapper = Input.new({ deadzone = 0 }); ready(mapper, air)
            local a = step(mapper, pad({ left_shoulder = true, right_y = -radius }), air)
            check((a.handlebar == "left") == (radius >= 0.7), "selector radius threshold remains exact")
        end
        for _, trigger in ipairs({ 0.2, 0.2001 }) do
            local mapper = Input.new({ deadzone = 0 }); ready(mapper, air)
            local a = step(mapper, pad({ left_trigger = trigger, right_trigger = trigger, right_x = 1 }), air)
            check((a.tailwhip == "right") == (trigger > 0.2), "modifier threshold stays strict-greater")
        end
        local sectors = { { 29.999, 0 }, { 30.001, 1 }, { 67.499, 1 }, { 67.501, 2 },
            { 149.999, 3 }, { 150.001, 4 }, { 209.999, 4 }, { 210.001, 5 }, { 329.999, 7 }, { 330.001, 0 } }
        for _, sample in ipairs(sectors) do
            local mapper = Input.new({ deadzone = 0 }); ready(mapper, air)
            local angle = sample[1] * math.pi / 180
            local a = step(mapper, pad({ left_shoulder = true, right_trigger = 1, right_x = math.sin(angle), right_y = math.cos(angle) }), air)
            check(a.movement == sample[2], "authored asymmetric top/bottom sector boundaries remain unchanged")
        end
        cases = cases + 1
    end

    do
        local faults = { { available = false }, { focused = false }, { menu_open = true },
            { left_x = 0 / 0 }, { right_y = math.huge }, { pedal = -math.huge },
            { left_trigger = 0 / 0 }, { right_trigger = math.huge } }
        for _, fault in ipairs(faults) do
            local mapper = Input.new(); ready(mapper)
            step(mapper, pad({ right_y = -1 }))
            check(not step(mapper, pad(fault)).active, "invalid readiness or finite-field fault resets")
            check(not step(mapper, pad({ right_y = 1 })).active, "reset cannot replay held release")
        end
        for _, bad in ipairs({ -1, 0, 0.101, math.huge, 0 / 0 }) do
            local mapper = Input.new(); ready(mapper)
            check(not mapper:update(pad(), ground, bad).active, "invalid or overlong sample resets")
        end
        local mapper = Input.new(); ready(mapper)
        check(not step(mapper, pad({ device = 8, pedal = 1 })).active, "source replacement requires full neutral")
        ready(mapper)
        check(not step(mapper, pad({ device = 8, left_shoulder = true })).active, "held modifier on source change cannot arm")
        cases = cases + 1
    end

    do
        local mapper = Input.new({ deadzone = 0 / 0, neutral_threshold = 99, trick_threshold = -99,
            hop_back_threshold = -1, manual_threshold = 9, trigger_neutral = 99,
            modifier_threshold = 0, max_sample_seconds = -1 })
        local settings = mapper:settings()
        check(settings.deadzone == 0.12 and settings.neutral_threshold == 0.4 and settings.trick_threshold == 0.55, "configuration defaults and dependent bounds match C++")
        check(settings.hop_back_threshold == 0.55 and near(settings.manual_threshold, 0.45), "manual upper bound depends on sanitized hop threshold")
        check(settings.trigger_neutral == 0.2 and settings.modifier_threshold == 0.25 and settings.max_sample_seconds == 0.01, "dependent modifier and timing bounds match")
        settings.deadzone = 0
        check(mapper:settings().deadzone == 0.12, "settings readback cannot mutate mapper configuration")
        mapper:configure({})
        check(not step(mapper, pad({ pedal = 1 })).active, "configure resets gesture/source gate")
        cases = cases + 1
    end

    return { cases = cases, assertions = assertions, native_actions = 0 }
end

return tests

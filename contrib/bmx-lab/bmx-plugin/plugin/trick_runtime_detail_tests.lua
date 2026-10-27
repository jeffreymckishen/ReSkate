-- Constructed adapter/public-projection cases only. Support here is deliberately
-- authored as measured_support by the existing fixture, not native qualification.
local Runtime = require("./trick_runtime")
local Tricks = require("./tricks")
local Fixture = require("./trick_runtime_tests")
local Tests = {}
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}; for k, x in pairs(v) do out[k] = copy(x) end; return out
end
local function landed_event()
    local m = Tricks.new()
    local input = Tricks.input({enabled = true, owner = "event-projection", device = 0, bar_neutral = true, rear_neutral = true})
    m:update(.01, input); input.grounded = false; m:update(.01, input)
    input.barspin, input.bar_neutral = "left", false; m:update(.01, input)
    input.barspin, input.bar_neutral = "none", true
    for _ = 1, 52 do m:update(.01, input) end
    input.grounded = true
    return m:update(.01, input)
end
local function public(e)
    return Runtime.public_snapshot({valid = true, fresh = true, advanced = true, issue = "none", model_events = e})
end
function Tests.run()
    local assertions, cases = 0, 0
    local function check(ok, why) assertions += 1; assert(ok, why) end
    local function near(a, b) return math.abs(a - b) < 1e-8 end
    local function scenario(run) cases += 1; run() end
    local function tick(r, f, ground, opts) return r:step(f:next(ground, opts)) end
    scenario(function()
        local event = landed_event()
        event.landing = {body_up = .98, heading_cos = -1, closing = 4.32, ignored = {private = true}}
        event.sequence[1].ignored = {private = true}
        local result = public(event); local e = result and result.model_events
        check(e and e.scope == "model_events_only" and not e.realized and e.combo_landed, "projection keeps model-only provenance")
        check(e.sequence[1].id == 34 and e.sequence[1].dir == -1 and e.sequence[1].hold == 0
            and near(e.landing.heading_cos, -1) and near(e.landing.closing, 4.32), "projection preserves signed detail")
        check(e.sequence[1].ignored == nil and e.landing.ignored == nil, "projection whitelists nested detail fields")
        event.sequence[1].id = 44; event.landing.closing = 99
        check(e.sequence[1].id == 34 and near(e.landing.closing, 4.32), "projection owns detached nested tables")
        local second = Runtime.public_snapshot(result); e.sequence[1].start = 999
        check(second.model_events.sequence[1].start < 1, "each public snapshot detaches the bounded log")
    end)
    scenario(function()
        local mutations = {
            function(e) e.air_seconds = nil end,
            function(e) e.air_seconds = -1 end,
            function(e) e.air_seconds = 31 end,
            function(e) e.flip_radians = 0 / 0 end,
            function(e) e.roll_radians = math.huge end,
            function(e) e.fakie_takeoff = 1 end,
            function(e) e.overflow = "false" end,
            function(e) e.overflow = true end,
            function(e) e.sequence = nil end,
            function(e) e.sequence = setmetatable({}, {}) end,
            function(e) e.sequence[2] = e.sequence[1]; e.sequence[1] = nil end,
            function(e) e.sequence[0] = e.sequence[1] end,
            function(e) e.sequence.bad = e.sequence[1] end,
            function(e) for n = 2, 17 do e.sequence[n] = copy(e.sequence[1]) end end,
            function(e) e.sequence[1] = setmetatable(copy(e.sequence[1]), {}) end,
            function(e) e.sequence[1].kind = "rotation" end,
            function(e) e.sequence[1].id = 999 end,
            function(e) e.sequence[1].id = 255 end,
            function(e) e.sequence[1].id = 64 end,
            function(e) e.sequence[1].dir = 0 end,
            function(e) e.sequence[1].dir = 1 end,
            function(e) e.sequence[1].start = -1 end,
            function(e) e.sequence[1].finish = e.sequence[1].start end,
            function(e) e.sequence[1].finish = e.air_seconds + 1 end,
            function(e) e.sequence[1].hold = .01 end,
            function(e) e.sequence[1].hold = 0 / 0 end,
            function(e) e.sequence[1].kind = "move" end,
            function(e) e.sequence[1].kind = "tail" end,
            function(e) e.landing = {} end,
            function(e) e.landing = {body_up = 2, heading_cos = 0, closing = 1} end,
            function(e) e.landing = {body_up = 1, heading_cos = 1.1, closing = 1} end,
            function(e) e.landing = {body_up = 1, heading_cos = -1, closing = -1} end,
            function(e) e.landing = {body_up = 1, heading_cos = 0 / 0, closing = 1} end,
            function(e) e.landing = setmetatable({body_up = 1, heading_cos = 0, closing = 1}, {}) end,
            function(e) e.landed = false end,
        }
        for i, mutate in ipairs(mutations) do
            local e = landed_event(); mutate(e)
            check(public(e) == nil, "malformed detail rejected: " .. tostring(i))
        end
    end)
    scenario(function()
        local e = landed_event()
        e.sequence[1] = {kind = "move", id = 24, dir = 0, start = .01, finish = .40, hold = .21}
        check(public(e) ~= nil, "pose plateau detail is accepted")
        e.sequence[1].hold = .41
        check(public(e) == nil, "hold cannot exceed its entire interval")
        e.sequence[1] = {kind = "move", id = 54, dir = 0, start = .01, finish = .46, hold = .01}
        check(public(e) == nil, "cycle cannot claim pose hold")
        e.sequence[1].hold = 0
        check(public(e) ~= nil, "cycle interval without hold is accepted")
        e.sequence[2] = {kind = "bar", id = 34, dir = -1, start = 0, finish = .45, hold = 0}
        check(public(e) == nil, "rows with regressing start time are refused")
    end)
    scenario(function()
        local e = landed_event(); e.overflow = true
        for n = 2, 16 do e.sequence[n] = copy(e.sequence[1]) end
        local p = public(e)
        check(p ~= nil and #p.model_events.sequence == 16 and p.model_events.overflow, "exact cap is projected with explicit overflow")
        e.sequence[17] = copy(e.sequence[1])
        check(public(e) == nil, "seventeenth row is refused rather than silently truncated")
    end)
    scenario(function()
        local r, f = Runtime.new(), Fixture.fixture(); f.v = {0, 0, -3}
        check(tick(r, f, true).valid and tick(r, f, false).model_events.took_off, "constructed adapter primes and takes off")
        tick(r, f, false, {handlebar = "left", bar_neutral = false})
        for _ = 1, 52 do tick(r, f, false) end
        f.v = {0, -4.32, -3}; tick(r, f, false)
        f.v = {0, 0, -3}; local contact = tick(r, f, true)
        check(contact.valid and contact.model_state.landing_pending, "adapter retains original landing settle")
        local landed
        for _ = 1, 6 do landed = tick(r, f, true) end
        local e = landed.model_events
        check(landed.valid and e.combo_landed and #e.sequence == 1 and e.fakie_takeoff, "actual adapter projects the completed flight")
        check(near(e.air_seconds, .54) and near(e.landing.heading_cos, -1) and near(e.landing.body_up, 1)
            and near(e.landing.closing, 4.32), "adapter detail retains pre-impact closing speed and signed heading")
        local saved = r:status(); e.sequence[1].id = 77; e.landing.closing = 999
        check(saved.model_events.sequence[1].id == 34 and near(r:status().model_events.landing.closing, 4.32),
            "caller mutations cannot alter retained adapter result")
        local next_ground = tick(r, f, true)
        check(next_ground.model_events.sequence == nil and not next_ground.model_events.landed, "next ground sample cannot repeat detail award")
    end)
    scenario(function()
        local original, captured = Tricks.new, nil
        Tricks.new = function(settings) captured = original(settings); return captured end
        local built, r = pcall(Runtime.new)
        Tricks.new = original
        check(built and captured ~= nil, "constructed model injection restored before assertions")
        local actual_update = captured.update
        captured.update = function(self, seconds, input)
            local event = actual_update(self, seconds, input)
            if event.landed then event.sequence[17] = {kind = "bar", id = 34, dir = -1, start = 0, finish = .1, hold = 0} end
            return event
        end
        local f = Fixture.fixture(); tick(r, f, true); tick(r, f, false)
        tick(r, f, false, {handlebar = "left", bar_neutral = false})
        for _ = 1, 52 do tick(r, f, false) end
        tick(r, f, true)
        local out
        for _ = 1, 6 do out = tick(r, f, true) end
        captured.update = actual_update
        check(not out.valid and out.issue == "invalid_model_output" and out.model_events == nil and out.visual_targets == nil,
            "malformed model detail fails closed in actual adapter step")
        check(not r:status().valid and tick(r, f, true).valid, "refusal retains no score packet and needs a new ground prime")
    end)
    return {cases = cases, assertions = assertions, native_actions = 0}
end
return Tests

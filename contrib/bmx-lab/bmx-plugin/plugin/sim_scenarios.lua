-- Scripted rubric scenarios over sim_world.lua. Test-only tooling: nothing
-- runs on require, no reskate.* call is made, and the metrics are what the
-- current forces.lua/input.lua model does in an authored world. They are a
-- BASELINE to notice change, never a target, a likeness score or game
-- evidence. Any comparison target must come from the user's own observations.
-- Rubric ids are judging/rubric-v1.json's; SIMULATION.md defines each metric.
local World = require("./sim_world")
local Scenarios = {}
local H = World.h

Scenarios.order = table.freeze({ "S01", "S02", "S04", "S05", "S06", "S07" })
-- Four native steps per chunk. The step count is what bounds the work
-- between progress calls: these scenarios average well under 1 ms a step and
-- FORCES.md's slowest kernel case is about 2 ms on its own. Wall time on a
-- shared desktop also counts preemption, which no chunk size removes.
Scenarios.chunk_steps = 4

local function wrap(angle)
    while angle > math.pi do angle -= 2 * math.pi end
    while angle <= -math.pi do angle += 2 * math.pi end
    return angle
end
local function first(trace, from, to, predicate)
    for i = from, math.min(to, #trace) do if predicate(trace[i], i) then return i end end
    return nil
end
local function span(tags, tag)
    local a, b
    for i, t in ipairs(tags) do
        if t == tag then a = a or i b = i end
    end
    return a, b
end
local function horizontal(a, b) return math.sqrt((b[1] - a[1]) ^ 2 + (b[3] - a[3]) ^ 2) end
local function separation(info) return info.status == "hit" and info.separation or info.clearance end
-- The run's own m*g (forces.lua tuning gravity, vertical in this world).
local function weight(run) return run.initial.body.mass * -run.sim.tuning.gravity[2] end
local function kinetic(run)
    -- energy_before of step 1 holds the placed body's total; remove gravity.
    return run.trace[1].energy_before - weight(run) * run.initial.body.center_of_mass[2]
end
local function issue(run) return run.sim.issue end

------------------------------------------------------------------------------
-- S01: flat ground start, coast, brake to rest and restart.
local function s01()
    local phases = { { "settle", 1 }, { "accel", 360 }, { "coast", 180 }, { "brake", 360 }, { "rest", 30 }, { "restart", 120 } }
    local inputs = { settle = {}, accel = { pedal = 1 }, coast = {}, brake = { brake = 1 }, rest = {}, restart = { pedal = 1 } }
    return { { name = "flat", options = {}, input = function(_, last, state)
        state.at, state.count = state.at or 1, (state.count or 0) + 1
        local phase = phases[state.at]
        -- Braking ends at rest (0.05 m/s) or at the phase cap, whichever first.
        if state.count > phase[2] or (phase[1] == "brake" and last and last.speed < .05) then
            state.at, state.count = state.at + 1, 1
            phase = phases[state.at]
            if not phase then return nil end
        end
        return inputs[phase[1]], phase[1]
    end, summarize = function(run)
        local trace, tags = run.trace, run.tags
        local function window(tag)
            local a, b = span(tags, tag)
            local before = a > 1 and trace[a - 1] or nil
            local start = before and before.position or run.initial.body.center_of_mass
            local v0 = before and before.speed or 0
            local length = 0
            for i = a, b do length += horizontal(i > 1 and trace[i - 1].position or start, trace[i].position) end
            return a, b, v0, length, (before and before.time or 0)
        end
        local out = {}
        do
            local a, b, _, length, t0 = window("accel")
            local function reach(v)
                local i = first(trace, a, b, function(r) return r.speed >= v end)
                return i and trace[i].time - t0 or -1
            end
            local lean = 0
            for i = a, b do lean = math.max(lean, math.abs(trace[i].lean)) end
            out.accel = { time_to_3 = reach(3), time_to_6 = reach(6), time_to_7_5 = reach(7.5), top_speed = trace[b].speed,
                distance = length, seconds = (b - a + 1) * H, max_abs_lean = lean, lateral_drift = math.abs(trace[b].position[1]) }
        end
        do
            local a, b, v0, length = window("coast")
            out.coast = { speed_start = v0, speed_end = trace[b].speed, speed_change = trace[b].speed - v0,
                distance = length, seconds = (b - a + 1) * H, energy_change = trace[b].energy - trace[a].energy_before }
        end
        do
            local a, b, v0, length, t0 = window("brake")
            local peak, previous = 0, v0
            for i = a, b do peak = math.max(peak, (previous - trace[i].speed) / H) previous = trace[i].speed end
            local stopped = trace[b].speed < .05
            local seconds = trace[b].time - t0
            out.brake = { speed_start = v0, stopped = stopped, seconds = seconds, distance = length,
                mean_deceleration = (v0 - trace[b].speed) / seconds, peak_deceleration = peak,
                lateral_drift = math.abs(trace[b].position[1]) }
        end
        do
            local _, b, _, length = window("rest")
            out.rest = { creep_distance = length, speed_end = trace[b].speed }
        end
        do
            local _, b, v0, length = window("restart")
            out.restart = { speed_start = v0, speed_end = trace[b].speed, distance = length }
        end
        out.steps, out.valid, out.issue = #trace, not run.sim.stopped, issue(run)
        return out
    end } }
end

------------------------------------------------------------------------------
-- S02: full steering lock held at two speeds, each way, then released.
local function s02()
    local runs = {}
    for _, case in ipairs({ { "left_3", 3, -1 }, { "right_3", 3, 1 }, { "left_6", 6, -1 }, { "right_6", 6, 1 } }) do
        local name, speed, x = case[1], case[2], case[3]
        table.insert(runs, { name = name, options = { speed = speed }, input = function(step)
            if step <= 30 then return {}, "approach" end
            if step <= 210 then return { left_x = x }, "hold" end
            if step <= 270 then return {}, "release" end
            return nil
        end, summarize = function(run)
            local trace, tags = run.trace, run.tags
            local a, b = span(tags, "hold")
            -- Steady state: the last 1.5 s of the 3 s hold.
            local w = b - 89
            local turned, path, lean, limited, moving = 0, 0, 0, 0, 0
            for i = w, b do
                turned += wrap(trace[i].yaw - trace[i - 1].yaw)
                path += horizontal(trace[i - 1].position, trace[i].position)
                lean += trace[i].lean moving += trace[i].speed
                if trace[i].steering_limited then limited += 1 end
            end
            local n = b - w + 1
            local r1, r2 = span(tags, "release")
            local after, settle = 0, nil
            for i = r1, r2 do
                local rate = wrap(trace[i].yaw - trace[i - 1].yaw) / H
                after += rate * H
                if settle == nil and math.abs(rate) < .05 then settle = (i - r1 + 1) * H end
            end
            return { speed_start = speed, radius = path / math.abs(turned), yaw_rate = turned / (n * H),
                steer = trace[b].steer,
                mean_speed = moving / n, mean_lean = lean / n, steering_limited_fraction = limited / n,
                hold_speed_change = trace[b].speed - trace[a - 1].speed,
                hold_energy_change = trace[b].energy - trace[a].energy_before,
                release_heading_change = after, release_settled = settle ~= nil,
                release_settle_seconds = settle or (r2 - r1 + 1) * H, release_lean = trace[r2].lean,
                valid = not run.sim.stopped, issue = issue(run) }
        end })
    end
    return runs
end

------------------------------------------------------------------------------
-- S04: coast up a 15 degree ramp with no input at two speeds and roll back.
local function s04()
    local runs = {}
    for _, speed in ipairs({ 3, 6 }) do
        local terrain = World.terrain.ramp({ start_z = 2, angle = math.rad(15), blend = .5, top = 3 })
        table.insert(runs, { name = "speed_" .. speed, options = { speed = speed, terrain = terrain },
            input = function(step, last)
                -- Ends once the COM has rolled back past its start, or at 8 s.
                if step > 480 or (last and last.position[3] < 0 and last.forward_speed < 0) then return nil end
                return {}, "coast"
            end, summarize = function(run)
                local trace = run.trace
                local y0 = run.initial.body.center_of_mass[2]
                local peak, at, furthest, pitch = -math.huge, 1, -math.huge, 0
                for i, r in ipairs(trace) do
                    if r.position[2] > peak then peak, at = r.position[2], i end
                    furthest = math.max(furthest, r.position[3])
                    pitch = math.max(pitch, r.pitch)
                end
                local ideal = kinetic(run) / weight(run)
                local last = trace[#trace]
                return { speed_start = speed, peak_rise = peak - y0, ideal_rise = ideal, rise_ratio = (peak - y0) / ideal,
                    peak_seconds = trace[at].time, furthest_z = furthest, max_pitch = pitch,
                    rolled_back = last.position[3] < 0 and last.forward_speed < 0, return_speed = last.forward_speed,
                    return_ratio = math.abs(last.forward_speed) / speed,
                    energy_change = last.energy - trace[1].energy_before, seconds = last.time,
                    valid = not run.sim.stopped, issue = issue(run) }
            end })
    end
    return runs
end

------------------------------------------------------------------------------
-- S05: bunny hops on flat at 4 m/s, and a hop over a 1.5 m gap at 5 m/s.
-- Impact is the first step, after both tyres have left forces.lua's contact
-- gap, whose query puts a tyre back inside it, so the kernel solves it as
-- contact; support is the step where ride_runtime.lua's eligibility test
-- first passes again.
local function hop_metrics(run, input_step)
    local trace, gap = run.trace, run.sim.tuning.contact_gap
    local k = first(trace, 1, #trace, function(r) return r.hop_applied end)
    if not k then return { hop_applied = false, valid = not run.sim.stopped, issue = issue(run) } end
    local function touching(info) return info.status == "hit" and info.separation <= gap end
    local left = first(trace, k + 1, #trace, function(r) return not touching(r.front) and not touching(r.rear) end)
    local impact = left and first(trace, left, #trace, function(r) return touching(r.front) or touching(r.rear) end)
    local support = impact and first(trace, impact, #trace, function(r) return r.front.supported or r.rear.supported end)
    local before = trace[k - 1].position[2]
    local out = { hop_applied = true, hop_strength = trace[k].hop_strength, input_to_hop = (k - input_step) * H,
        takeoff_vertical_speed = trace[k].velocity[2], left_contact_gap = left ~= nil,
        landed = impact ~= nil and support ~= nil, valid = not run.sim.stopped, issue = issue(run) }
    local stop = impact or #trace
    local apex, clearance = -math.huge, -math.huge
    for i = k, stop - 1 do apex = math.max(apex, trace[i].position[2] - before) end
    for i = k + 1, stop do clearance = math.max(clearance, math.min(trace[i].front.clearance, trace[i].rear.clearance)) end
    out.apex_rise, out.apex_clearance = apex, clearance
    if impact and support then
        local touch = trace[impact - 1]
        out.airtime = (impact - 1 - k) * H
        out.air_distance = touch.position[3] - trace[k].position[3]
        out.landing_pitch, out.landing_vertical_speed = touch.pitch, touch.velocity[2]
        out.impact_to_support = (support - impact) * H
        out.first_contact = (touching(trace[impact].front) and touching(trace[impact].rear)) and "both"
            or touching(trace[impact].front) and "front" or "rear"
        local deepest = math.huge
        for i = impact, math.min(impact + 12, #trace) do
            deepest = math.min(deepest, separation(trace[i].front), separation(trace[i].rear))
        end
        out.landing_min_separation = deepest
        out.speed_after = trace[math.min(support + 30, #trace)].speed
    end
    return out
end
local function s05()
    local function flat(name, steps, script, input_step)
        return { name = name, options = { speed = 4 }, input = function(step)
            if step > steps then return nil end
            return script(step) or {}, "ride"
        end, summarize = function(run) return hop_metrics(run, input_step) end }
    end
    local gap = { near_z = 4, far_z = 5.5, depth = 1 }
    local function gap_run(name, hop)
        return { name = name, options = { speed = 5, terrain = World.terrain.gap(gap) }, input = function(step, last, state)
            if step > 120 then return nil end
            -- R3 once the last query put the front hub within 1.5 m of the
            -- near edge; the takeoff distance actually achieved is reported.
            if hop and not state.hopped and last and last.front.hub[3] >= gap.near_z - 1.5 then
                state.hopped = true
                return { quick_hop = true }, "ride"
            end
            return {}, "ride"
        end, summarize = function(run)
            local trace = run.trace
            if not hop then
                local last = trace[#trace]
                return { hop_applied = false, valid = not run.sim.stopped, issue = issue(run), seconds = last.time,
                    front_hub_z = last.front.hub[3], front_status = last.front.status }
            end
            local k = first(trace, 1, #trace, function(r) return r.hop_applied end)
            local out = hop_metrics(run, k or 0)
            out.input_to_hop = nil
            if k then out.takeoff_front_to_edge = gap.near_z - trace[k].front.hub[3] end
            local landing = first(trace, (k or #trace) + 1, #trace, function(r) return r.front.supported or r.rear.supported end)
            if landing then
                out.landing_rear_past_far = trace[landing].rear.hub[3] - gap.far_z
                out.cleared = not run.sim.stopped and trace[landing].rear.hub[3] >= gap.far_z
            else out.cleared = false end
            return out
        end }
    end
    return {
        flat("r3_quick_hop", 120, function(step) if step == 16 then return { quick_hop = true } end end, 16),
        -- 18 samples (0.3 s) back, past input.lua's 0.25 s full charge, then flick.
        flat("full_charge_flick", 140, function(step)
            if step >= 16 and step <= 33 then return { right_y = -1 } end
            if step == 34 then return { right_y = 1 } end
        end, 16),
        -- One sample back then forward: input.lua's minimum 0.25 strength.
        flat("minimum_flick", 90, function(step)
            if step == 16 then return { right_y = -1 } end
            if step == 17 then return { right_y = 1 } end
        end, 16),
        gap_run("gap_r3", true),
        gap_run("gap_no_hop", false),
    }
end

------------------------------------------------------------------------------
-- S06: roll off a 0.3 m ledge with no input at two speeds.
local function s06()
    local runs = {}
    for _, speed in ipairs({ 2, 5 }) do
        local edge = 1.5
        table.insert(runs, { name = "speed_" .. speed, options = { speed = speed, terrain = World.terrain.ledge({ edge_z = edge, height = .3 }) },
            input = function(step) if step > 90 then return nil end return {}, "coast" end,
            summarize = function(run)
                local trace = run.trace
                local function down(info) return info.supported and info.hub[3] >= edge end
                local front_off = first(trace, 1, #trace, function(r) return r.front.hub[3] >= edge end)
                local rear_off = first(trace, 1, #trace, function(r) return r.rear.hub[3] >= edge end)
                local landing = first(trace, front_off or 1, #trace, function(r) return down(r.front) or down(r.rear) end)
                local both = first(trace, landing or #trace, #trace, function(r) return down(r.front) and down(r.rear) end)
                local airborne, pitch, drop, deepest = 0, 0, 0, math.huge
                for _, r in ipairs(trace) do
                    if not r.front.supported and not r.rear.supported then airborne += 1 end
                    pitch = math.min(pitch, r.pitch) drop = math.min(drop, r.velocity[2])
                    deepest = math.min(deepest, separation(r.front), separation(r.rear))
                end
                local settled = both and first(trace, both, #trace, function(r) return math.abs(r.pitch) < .01 end)
                local last = trace[#trace]
                return { speed_start = speed, airborne_seconds = airborne * H,
                    first_landing = landing and ((down(trace[landing].front) and down(trace[landing].rear)) and "both"
                        or down(trace[landing].front) and "front" or "rear") or "none",
                    front_to_rear_landing = (landing and both) and (both - landing) * H or -1,
                    min_pitch = pitch, max_drop_speed = -drop, min_separation = deepest,
                    settle_seconds = (settled and rear_off) and (settled - rear_off) * H or -1,
                    energy_loss = trace[1].energy_before - last.energy, drop_potential = weight(run) * .3,
                    speed_end = last.speed, valid = not run.sim.stopped, issue = issue(run) }
            end })
    end
    return runs
end

------------------------------------------------------------------------------
-- S07: manuals and a nose manual at 4 m/s held with one fixed stick position
-- and nothing else, then released to neutral.
local function s07()
    local runs = {}
    for _, case in ipairs({ { "manual_075", -.75 }, { "manual_070", -.70 }, { "manual_060", -.60 }, { "nose_075", .75 } }) do
        local name, y = case[1], case[2]
        local lift = y < 0 and "front" or "rear"
        local base = y < 0 and "rear" or "front"
        table.insert(runs, { name = name, options = { speed = 4 }, input = function(step)
            if step <= 15 then return {}, "approach" end
            if step <= 135 then return { right_y = y }, "hold" end
            if step <= 195 then return {}, "release" end
            return nil
        end, summarize = function(run)
            local trace, tags, gap = run.trace, run.tags, run.sim.tuning.contact_gap
            local function lifted(r)
                local info = r[lift]
                return info.status == "clear" or (info.status == "hit" and info.separation > gap)
            end
            local a, b = span(tags, "hold")
            local r1, r2 = span(tags, "release")
            local up = first(trace, a, b, lifted)
            local peak, clear, count, based, sign = 0, 0, 0, 0, y < 0 and 1 or -1
            for i = a, b do
                peak = math.max(peak, sign * trace[i].pitch)
                clear = math.max(clear, trace[i][lift].clearance)
                if lifted(trace[i]) then count += 1 end
                if trace[i][base].supported then based += 1 end
            end
            local hold = 0
            for i = b - 29, b do hold += sign * trace[i].pitch end
            -- Neutral after the hold: how long the lifted wheel stays up with
            -- no stick at all. Zero when it was not up when the stick let go.
            local up_at_release = lifted(trace[b])
            local dropped = up_at_release and first(trace, r1, r2, function(r) return r[lift].supported end) or nil
            local release = 0
            if up_at_release then release = dropped and (dropped - r1 + 1) * H or (r2 - r1 + 1) * H end
            return { control = y < 0 and trace[b].manual or trace[b].nose_manual, lifted = up ~= nil,
                time_to_lift = up and (up - a + 1) * H or (b - a + 1) * H, peak_lift_pitch = peak,
                hold_lift_pitch = hold / 30, max_lift_clearance = clear, lifted_fraction = count / (b - a + 1),
                base_supported_fraction = based / (b - a + 1), hold_speed_change = trace[b].speed - trace[a - 1].speed,
                lifted_at_release = up_at_release, release_dropped = dropped ~= nil, release_drop_seconds = release,
                valid = not run.sim.stopped, issue = issue(run) }
        end })
    end
    return runs
end

local builders = { S01 = s01, S02 = s02, S04 = s04, S05 = s05, S06 = s06, S07 = s07 }
Scenarios.titles = table.freeze({
    S01 = "flat ground start, coast, brake to rest and restart",
    S02 = "full steering lock at 3 and 6 m/s each way, then release",
    S04 = "15 degree ramp coasted up and back at 3 and 6 m/s",
    S05 = "R3 hop, full-charge and minimum flick at 4 m/s; 1.5 m gap at 5 m/s",
    S06 = "0.3 m ledge rolled off at 2 and 5 m/s",
    S07 = "manual and nose manual held at one stick position, then released to neutral",
})

-- A resumable runner over one scenario's runs. Each run gets a fresh
-- World.new, a fresh script state and its own trace; advance(n) performs at
-- most n native steps and reports whether the scenario has finished.
local Runner = {}
Runner.__index = Runner
-- A chunk budget counts native steps. Zero, a negative or NaN never lets
-- advance() take a step, so run() would call it forever; a fraction takes
-- more steps than asked, and infinity is not a chunk. Refused before any work.
local function chunk_budget(budget)
    assert(type(budget) == "number" and budget > 0 and budget < math.huge and budget % 1 == 0,
        "scenario chunk budget must be a positive finite integer")
end
function Scenarios.runner(id)
    local build = builders[id]
    assert(build, "unknown scenario")
    return setmetatable({ id = id, runs = build(), at = 0, steps = 0, metrics = {}, finished = false, traces = {} }, Runner)
end
function Runner:_begin()
    self.at += 1
    local run = self.runs[self.at]
    if not run then self.finished = true return nil end
    run.sim = World.new(run.options)
    run.initial = run.sim:state()
    run.trace, run.tags, run.state = {}, {}, {}
    return run
end
function Runner:_finish(run)
    assert(#run.trace > 1, "a scenario run needs at least two steps")
    self.metrics[run.name] = run.summarize(run)
    self.traces[run.name] = run.trace
    self.current = nil
end
function Runner:advance(budget)
    chunk_budget(budget)
    local used = 0
    while not self.finished and used < budget do
        local run = self.current or self:_begin()
        self.current = run
        if not run then break end
        local changes, tag
        if not run.sim.stopped then changes, tag = run.input(#run.trace + 1, run.trace[#run.trace], run.state) end
        if changes == nil then
            self:_finish(run)
        else
            table.insert(run.trace, run.sim:step(changes))
            table.insert(run.tags, tag)
            used += 1
            self.steps += 1
        end
    end
    return self.finished
end
function Runner:result()
    assert(self.finished, "the scenario has not finished")
    return World.freeze(self.metrics)
end

-- Lua source for a metrics table with sorted keys and round-trip doubles,
-- so re-recording sim_tests.lua's BASELINE is a paste, not a transcription.
-- Integral values print as integers, everything else with 17 significant
-- digits, which reads back to the same double.
local function number_source(value)
    -- inf and nan have no Lua literal; the metrics are asserted finite.
    assert(value == value and math.abs(value) ~= math.huge, "lua_source needs finite numbers")
    if value == 0 and 1 / value < 0 then return "-0" end
    if value % 1 == 0 and math.abs(value) < 1e15 then return string.format("%d", value) end
    return string.format("%.17g", value)
end
function Scenarios.lua_source(metrics, name)
    local lines = {}
    local function emit(value, indent, prefix)
        if type(value) == "table" then
            local keys = {}
            for key in pairs(value) do table.insert(keys, key) end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            table.insert(lines, prefix .. "{")
            for _, key in ipairs(keys) do
                -- %q would quote a number key into a string key.
                local label = type(key) == "number" and ("[" .. number_source(key) .. "]")
                    or string.match(key, "^[%a_][%w_]*$") and key or ("[" .. string.format("%q", key) .. "]")
                emit(value[key], indent .. "    ", indent .. "    " .. label .. " = ")
                lines[#lines] ..= ","
            end
            table.insert(lines, indent .. "}")
        elseif type(value) == "number" then
            table.insert(lines, prefix .. number_source(value))
        elseif type(value) == "string" then
            table.insert(lines, prefix .. string.format("%q", value))
        else
            table.insert(lines, prefix .. tostring(value))
        end
    end
    emit(metrics, "", "local " .. (name or "BASELINE") .. " = ")
    return table.concat(lines, "\n")
end

-- Every scenario in order, chunk by chunk. progress(id, steps_done) runs
-- after each chunk. Returns the frozen metrics table and the runners, whose
-- traces the tests compare between repeat runs.
function Scenarios.run(progress, chunk)
    -- Only an omitted chunk takes the default; false is refused like any other non-number.
    if chunk == nil then chunk = Scenarios.chunk_steps end
    chunk_budget(chunk)
    local out, runners = { version = 1, h = H }, {}
    for _, id in ipairs(Scenarios.order) do
        local runner = Scenarios.runner(id)
        while not runner:advance(chunk) do
            if type(progress) == "function" then progress(id, runner.steps) end
        end
        if type(progress) == "function" then progress(id, runner.steps) end
        out[id] = runner:result()
        runners[id] = runner
    end
    return World.freeze(out), runners
end

return table.freeze(Scenarios)

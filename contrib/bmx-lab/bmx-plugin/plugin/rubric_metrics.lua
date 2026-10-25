-- Offline rubric metrics. Test-only tooling: pure reductions of step traces
-- (positions, velocities, contacts and modes over time) into the measurable
-- quantities that judging/rubric-v2.json's categories describe, and an
-- optional comparison of a few of them against BMX Streets behaviour that the
-- project's own notes recorded by watching the game run. It owns no SDK
-- object, makes no reskate.* call and runs nothing on require.
--
-- An offline score says how close one model metric is to one recorded
-- observation under tolerances authored here. It is NOT the human-judged
-- likeness score the rubric asks for, it is not gameplay or native evidence,
-- and it is not a tuning target on its own. contrib/bmx-lab/judging/
-- OFFLINE_METRICS.md defines every metric, every target and its tolerance, and
-- cites where each recorded value came from. No value here was recovered by
-- decompilation or decoded from game files; those are excluded on purpose.
local Forces = require("./forces")
local M = require("./force_math")
local Metrics = {}
local H = Forces.native_seconds
-- Whole native steps land on authored time boundaries within this slack.
local SLACK = 1e-6

Metrics.version = 1
Metrics.disclaimer = "Offline model metrics and closeness scores from constructed traces. This is not the "
    .. "human-judged likeness score of judging/rubric-v2.json, not gameplay or native evidence, and not a tuning target on its own."
-- forces.lua's contact gap: a tyre whose ray separation is within it is touching.
Metrics.contact_gap = Forces.tuning().contact_gap
Metrics.stop_speed = .05
-- Speed bands of the reference captures' own fit windows, so the model is fitted
-- over the same speeds as the observation it is compared with. They come from
-- standalone/bmx-movement/recordings/comparison-session01/actual-flat04-fits.json
-- (early_pedal lines 180-181, moving_brake 207-208, brake_later 261-262).
Metrics.early_pedal_band = table.freeze({ .52, 3.87 })
Metrics.brake_bands = table.freeze({
    moving_brake = table.freeze({ .08, 4.52 }),
    later_brake = table.freeze({ .08, 2.67 }),
})
Metrics.curve_seconds = table.freeze({ .5, 1, 2, 3, 4 })
Metrics.speed_thresholds = table.freeze({ 3, 6, 7.5 })
-- Authored scoring tolerance; OFFLINE_METRICS.md gives the reasoning. A metric
-- scores 1 inside the observed range widened by `margin` of its midpoint on
-- each side, then falls linearly to 0 at `falloff` of the midpoint beyond it.
Metrics.tolerance = table.freeze({ margin = .10, falloff = .50 })

local function freeze(t)
    for _, v in pairs(t) do
        if type(v) == "table" and not table.isfrozen(v) then freeze(v) end
    end
    return table.freeze(t)
end
Metrics.freeze = freeze

local function finite(x) return M.finite(x) end
local function wrap(angle)
    while angle > math.pi do angle -= 2 * math.pi end
    while angle <= -math.pi do angle += 2 * math.pi end
    return angle
end
local function horizontal(a, b) return math.sqrt((b[1] - a[1]) ^ 2 + (b[3] - a[3]) ^ 2) end
local function label(x) return (string.gsub(tostring(x), "%.", "_")) end
local function first(trace, from, to, predicate)
    for i = from, math.min(to, #trace) do if predicate(trace[i], i) then return i end end
    return nil
end

-- Least-squares slope of ys on xs; nil without two distinct xs.
local function slope(xs, ys)
    local n = #xs
    if n < 2 then return nil end
    local mx, my = 0, 0
    for i = 1, n do mx += xs[i] my += ys[i] end
    mx /= n
    my /= n
    local sxx, sxy = 0, 0
    for i = 1, n do
        local dx = xs[i] - mx
        sxx += dx * dx
        sxy += dx * (ys[i] - my)
    end
    if not (sxx > 0) then return nil end
    return sxy / sxx
end
Metrics.slope = slope

-- A Luau vector, {x =, y =, z =} or {x, y, z}, as a double array.
local function point(value)
    if typeof(value) == "vector" then return { value.x, value.y, value.z } end
    if type(value) ~= "table" then return nil end
    if value.x ~= nil then return { value.x, value.y, value.z } end
    return { value[1], value[2], value[3] }
end
-- Angle between two directions, accurate near 0 and pi.
local function angle_between(a, b)
    return math.atan2(M.length(M.cross(a, b)), M.dot(a, b))
end

-- Speed along a rail when the record has one, else horizontal speed.
local function speed_of(r)
    if type(r.rail_speed) == "number" then return math.abs(r.rail_speed) end
    if type(r.speed) == "number" then return r.speed end
    return math.sqrt(r.velocity[1] ^ 2 + r.velocity[3] ^ 2)
end
Metrics.speed_of = speed_of

-- The length of step i. The first record has no predecessor, so it takes the
-- next record's spacing (simulator records are one native step apart), or
-- one native step for a single record.
local function step_seconds(trace, i)
    if i > 1 then return trace[i].time - trace[i - 1].time end
    if #trace > 1 then return trace[2].time - trace[1].time end
    return H
end

-- The state a window starts from: the record before it, or the caller's
-- initial state {time, position, speed} for a window that opens the trace.
local function before(trace, a, initial)
    if a > 1 then return trace[a - 1] end
    if initial then return initial end
    local r = trace[a]
    return { time = r.time - step_seconds(trace, a), position = r.position, speed = speed_of(r), pitch = r.pitch }
end

local function path(trace, a, b, start)
    local total, last = 0, start
    for i = a, b do
        total += horizontal(last, trace[i].position)
        last = trace[i].position
    end
    return total
end

-- A ray-hit row is measured along its normal; a clear row only has vertical
-- clearance. Negative is a tyre below the surface.
local function depth_of(info)
    if type(info) ~= "table" then return math.huge end
    if info.status == "hit" then return info.separation end
    return info.clearance or math.huge
end
local function touching(info, gap)
    return type(info) == "table" and info.status == "hit" and info.separation <= gap
end
local function supported(info) return type(info) == "table" and info.supported == true end

-- First and last index carrying `tag`.
function Metrics.window(tags, tag)
    local a, b
    for i, t in ipairs(tags) do
        if t == tag then a = a or i b = i end
    end
    return a, b
end

-- The first record w of the last `seconds` of the window [a, b]: the smallest
-- w >= a, with a record before it, whose steps w..b add up to at most
-- `seconds` (90 native steps for 1.5 s, 30 for 0.5 s).
local function tail(trace, a, b, seconds)
    local w = b
    while w > a and w > 2 and trace[b].time - trace[w - 2].time <= seconds + SLACK do w -= 1 end
    return w
end

------------------------------------------------------------------------------
-- Riding: pedal acceleration curve over the window [a, b].
function Metrics.pedal(trace, a, b, options)
    options = options or {}
    local start = before(trace, a, options.initial)
    local t0, v0 = start.time, start.speed or 0
    local band = options.early_band or Metrics.early_pedal_band
    local v1 = speed_of(trace[b])
    local out = { start_speed = v0, end_speed = v1, seconds = trace[b].time - t0,
        distance = path(trace, a, b, start.position) }
    out.mean_acceleration = (v1 - v0) / out.seconds
    local times, speeds, peak, previous, previous_time = {}, {}, -math.huge, v0, t0
    for i = a, b do
        local v, t = speed_of(trace[i]), trace[i].time
        peak = math.max(peak, (v - previous) / (t - previous_time))
        previous, previous_time = v, t
        if v >= band[1] and v <= band[2] then
            table.insert(times, t)
            table.insert(speeds, v)
        end
    end
    out.peak_acceleration = peak
    local early = #times >= 3 and slope(times, speeds) or nil
    if early then out.early_acceleration, out.early_samples = early, #times end
    for _, threshold in ipairs(options.thresholds or Metrics.speed_thresholds) do
        local i = first(trace, a, b, function(r) return speed_of(r) >= threshold end)
        if i then out["time_to_" .. label(threshold)] = trace[i].time - t0 end
    end
    for _, seconds in ipairs(Metrics.curve_seconds) do
        local i = first(trace, a, b, function(r) return r.time - t0 >= seconds - SLACK end)
        if i then out["speed_at_" .. label(seconds)] = speed_of(trace[i]) end
    end
    -- The rate still being gained over the last half second: near zero when
    -- the pedal has reached its top speed.
    local w = tail(trace, a, b, .5)
    local late_t, late_v = {}, {}
    for i = w, b do
        table.insert(late_t, trace[i].time)
        table.insert(late_v, speed_of(trace[i]))
    end
    out.plateau_acceleration = slope(late_t, late_v)
    return out
end

-- Riding: coasting or braking over [a, b]. `bands` maps a name to a speed
-- range {low, high}; each gives <name>_deceleration, a least-squares fit over
-- the window's records inside that range.
function Metrics.slowdown(trace, a, b, options)
    options = options or {}
    local start = before(trace, a, options.initial)
    local t0, v0 = start.time, start.speed or 0
    local v1 = speed_of(trace[b])
    local stop = options.stop_speed or Metrics.stop_speed
    local out = { start_speed = v0, end_speed = v1, speed_change = v1 - v0, seconds = trace[b].time - t0,
        distance = path(trace, a, b, start.position) }
    out.mean_deceleration = (v0 - v1) / out.seconds
    local times, speeds, peak, previous, previous_time = {}, {}, -math.huge, v0, t0
    for i = a, b do
        local v, t = speed_of(trace[i]), trace[i].time
        peak = math.max(peak, (previous - v) / (t - previous_time))
        previous, previous_time = v, t
        table.insert(times, t)
        table.insert(speeds, v)
    end
    out.peak_deceleration = peak
    local fit = slope(times, speeds)
    if fit then out.ols_deceleration = -fit end
    local names = {}
    for name in pairs(options.bands or {}) do table.insert(names, name) end
    table.sort(names)
    for _, name in ipairs(names) do
        local range, bt, bv = options.bands[name], {}, {}
        for i = a, b do
            local v = speed_of(trace[i])
            if v >= range[1] and v <= range[2] then
                table.insert(bt, trace[i].time)
                table.insert(bv, v)
            end
        end
        local band = #bt >= 3 and slope(bt, bv) or nil
        if band then out[name .. "_deceleration"], out[name .. "_samples"] = -band, #bt end
    end
    out.stopped = v1 < stop
    local halt = first(trace, a, b, function(r) return speed_of(r) < stop end)
    if halt then
        out.stopping_seconds = trace[halt].time - t0
        out.stopping_distance = path(trace, a, halt, start.position)
    end
    return out
end

-- Riding: a held turn. The steady part is the last `steady_seconds` of [a, b];
-- `release` = {first, last} adds how the heading settles once let go.
function Metrics.turn(trace, a, b, options)
    options = options or {}
    local w = math.max(tail(trace, a, b, options.steady_seconds or 1.5), 2)
    local turned, length, lean, moving, limited, seconds, limits = 0, 0, 0, 0, 0, 0, false
    for i = w, b do
        local r, p = trace[i], trace[i - 1]
        turned += wrap(r.yaw - p.yaw)
        length += horizontal(p.position, r.position)
        lean += r.lean or 0
        moving += speed_of(r)
        seconds += r.time - p.time
        if r.steering_limited ~= nil then limits = true end
        if r.steering_limited then limited += 1 end
    end
    local n = b - w + 1
    local out = { heading_change = turned, steady_seconds = seconds, yaw_rate = turned / seconds,
        mean_speed = moving / n, mean_lean = lean / n }
    if math.abs(turned) > 1e-9 then
        out.radius = length / math.abs(turned)
        out.lateral_acceleration = out.mean_speed * math.abs(out.yaw_rate)
    end
    if limits then out.steering_limited_fraction = limited / n end
    if options.release then
        local r1, r2 = options.release[1], options.release[2]
        local after, settle = 0, nil
        local t0 = trace[r1 - 1].time
        for i = r1, r2 do
            local change = wrap(trace[i].yaw - trace[i - 1].yaw)
            after += change
            if settle == nil and math.abs(change / (trace[i].time - trace[i - 1].time)) < (options.settle_rate or .05) then
                settle = trace[i].time - t0
            end
        end
        out.release_heading_change = after
        out.release_settled = settle ~= nil
        out.release_settle_seconds = settle or (trace[r2].time - t0)
        out.release_lean = trace[r2].lean
    end
    return out
end

-- Riding: how the turning radius and yaw rate grow with speed across held
-- turns, from rows {speed, radius, yaw_rate}, and how far mirrored pairs
-- {left, right} differ.
function Metrics.turn_speed(rows, pairs_)
    local speeds, radii, rates = {}, {}, {}
    for _, row in ipairs(rows) do
        table.insert(speeds, row.speed)
        table.insert(radii, row.radius)
        table.insert(rates, math.abs(row.yaw_rate))
    end
    local out = { radius_growth_per_speed = slope(speeds, radii), yaw_rate_growth_per_speed = slope(speeds, rates) }
    if pairs_ then
        local radius, rate = 0, 0
        for _, pair in ipairs(pairs_) do
            local l, r = pair[1], pair[2]
            radius = math.max(radius, math.abs(l.radius - r.radius) / ((l.radius + r.radius) / 2))
            local lw, rw = math.abs(l.yaw_rate), math.abs(r.yaw_rate)
            rate = math.max(rate, math.abs(lw - rw) / ((lw + rw) / 2))
        end
        out.mirror_radius_error, out.mirror_yaw_rate_error = radius, rate
    end
    return out
end

------------------------------------------------------------------------------
-- Ramps: rolled up a ramp from the trace's start. Momentum retained is the
-- speed rolled back with over the speed it came in with.
function Metrics.ramp(trace, options)
    options = options or {}
    local start = before(trace, 1, options.initial)
    local y0, v0 = start.position[2], start.speed or 0
    local peak, at, pitch, rate, unsupported = -math.huge, 1, -math.huge, 0, 0
    for i, r in ipairs(trace) do
        if r.position[2] > peak then peak, at = r.position[2], i end
        pitch = math.max(pitch, r.pitch)
        if i > 1 then rate = math.max(rate, math.abs(r.pitch - trace[i - 1].pitch) / (r.time - trace[i - 1].time)) end
        if r.front and r.rear and not supported(r.front) and not supported(r.rear) then
            unsupported += step_seconds(trace, i)
        end
    end
    local last = trace[#trace]
    local forward = last.forward_speed or speed_of(last)
    local out = { entry_speed = v0, peak_rise = peak - y0, peak_seconds = trace[at].time - start.time,
        max_pitch = pitch, max_pitch_rate = rate, unsupported_seconds = unsupported,
        seconds = last.time - start.time, rolled_back = forward < 0 and last.position[3] < start.position[3] }
    if out.rolled_back and v0 > 0 then
        out.return_speed = math.abs(forward)
        out.momentum_retained = out.return_speed / v0
    end
    return out
end

-- Landings: what happens in the `settle_seconds` after the impact step.
-- compression_depth is the deepest tyre penetration; com_dip is how far the
-- centre of mass sinks below where it ends the window. The COM has settled
-- from the first record after which it stays within 1 mm of that end height;
-- rebounded says it settled before the window's last record, so a COM still
-- rising or sinking when the window closes has not. rebound_seconds runs from
-- the lowest point to the settled record, and is 0 for a dip under 1 mm.
function Metrics.landing(trace, impact, options)
    options = options or {}
    local window = options.settle_seconds or .5
    local touch = impact > 1 and trace[impact - 1] or nil
    local t_touch = touch and touch.time or (trace[impact].time - step_seconds(trace, impact))
    local last = impact
    while last < #trace and trace[last + 1].time - t_touch <= window + SLACK do last += 1 end
    local deepest, low, low_at, bounce, excursion = math.huge, math.huge, impact, -math.huge, 0
    for i = impact, last do
        local r = trace[i]
        deepest = math.min(deepest, depth_of(r.front), depth_of(r.rear))
        if r.position[2] < low then low, low_at = r.position[2], i end
        bounce = math.max(bounce, r.velocity[2])
    end
    local settled, steady = trace[last].position[2], impact
    for i = impact, last do excursion = math.max(excursion, math.abs(trace[i].pitch - trace[last].pitch)) end
    for i = last, impact, -1 do
        if math.abs(trace[i].position[2] - settled) > .001 then steady = i + 1 break end
    end
    local out = { window_seconds = trace[last].time - t_touch, compression_depth = math.max(0, -deepest),
        com_dip = math.max(0, settled - low), compression_seconds = trace[low_at].time - t_touch,
        max_rebound_speed = math.max(0, bounce), pitch_excursion = excursion, rebounded = steady < last,
        rebound_seconds = math.max(0, trace[steady].time - trace[low_at].time),
        supported_at_end = supported(trace[last].front) and supported(trace[last].rear) }
    local entry = speed_of(touch or trace[impact])
    if entry > 0 then out.speed_retained = speed_of(trace[last]) / entry end
    return out
end

-- Hops: takeoff, apex, airtime and landing. Takeoff is the first step with
-- the hop applied. Impact is the first step, after both tyres have left the
-- contact gap, whose query puts a tyre back inside it; support is the first
-- step from there with a supported wheel. These are sim_scenarios.lua's S05
-- definitions, recomputed here from the raw trace.
function Metrics.air(trace, options)
    options = options or {}
    local gap = options.contact_gap or Metrics.contact_gap
    local k = options.takeoff or first(trace, 1, #trace, function(r) return r.hop_applied end)
    if not k then return { hop_applied = false } end
    local left = first(trace, k + 1, #trace, function(r) return not touching(r.front, gap) and not touching(r.rear, gap) end)
    local impact = left and first(trace, left, #trace, function(r) return touching(r.front, gap) or touching(r.rear, gap) end)
    local support = impact and first(trace, impact, #trace, function(r) return supported(r.front) or supported(r.rear) end)
    local start = before(trace, k, options.initial)
    local out = { hop_applied = true, takeoff_vertical_speed = trace[k].velocity[2], takeoff_speed = speed_of(trace[k]),
        left_contact_gap = left ~= nil, landed = impact ~= nil and support ~= nil }
    local stop = impact or #trace
    local apex, apex_at, clearance = -math.huge, k, -math.huge
    for i = k, stop - 1 do
        local rise = trace[i].position[2] - start.position[2]
        if rise > apex then apex, apex_at = rise, i end
    end
    for i = k + 1, stop do
        if trace[i].front and trace[i].rear then
            clearance = math.max(clearance, math.min(trace[i].front.clearance, trace[i].rear.clearance))
        end
    end
    out.apex_rise, out.apex_seconds = apex, trace[apex_at].time - trace[k].time
    if clearance > -math.huge then out.apex_clearance = clearance end
    if impact and support then
        local touch = trace[impact - 1]
        out.airtime = touch.time - trace[k].time
        out.air_distance = horizontal(trace[k].position, touch.position)
        out.landing_pitch, out.landing_vertical_speed = touch.pitch, touch.velocity[2]
        out.impact_to_support = trace[support].time - trace[impact].time
        local f, r = touching(trace[impact].front, gap), touching(trace[impact].rear, gap)
        out.first_contact = (f and r) and "both" or f and "front" or "rear"
        out.landing = Metrics.landing(trace, impact, options)
    end
    return out
end

-- Landings: rolled off a ledge whose edge is at world z = edge_z. A wheel has
-- landed once it is supported past the edge.
function Metrics.drop(trace, options)
    local edge = options.edge_z
    local function down(info) return supported(info) and info.hub[3] >= edge end
    local front_off = first(trace, 1, #trace, function(r) return r.front.hub[3] >= edge end)
    local landing = front_off and first(trace, front_off, #trace, function(r) return down(r.front) or down(r.rear) end)
    local both = landing and first(trace, landing, #trace, function(r) return down(r.front) and down(r.rear) end)
    local airborne, pitch, drop = 0, 0, 0
    for i, r in ipairs(trace) do
        if not supported(r.front) and not supported(r.rear) then airborne += step_seconds(trace, i) end
        pitch = math.min(pitch, r.pitch)
        drop = math.min(drop, r.velocity[2])
    end
    local out = { airborne_seconds = airborne, min_pitch = pitch, max_drop_speed = -drop, landed = landing ~= nil }
    if landing then
        local f, r = down(trace[landing].front), down(trace[landing].rear)
        out.first_landing = (f and r) and "both" or f and "front" or "rear"
        if both then out.front_to_rear_seconds = trace[both].time - trace[landing].time end
        out.landing = Metrics.landing(trace, landing, options)
    end
    return out
end

------------------------------------------------------------------------------
-- Tricks: a manual (lift = "front") or nose manual (lift = "rear") held over
-- [a, b]. `release` = {first, last} adds how long the lifted wheel stays up at
-- neutral. Stability is read over the lifted steps after the first lift.
function Metrics.manual(trace, a, b, options)
    options = options or {}
    local lift = options.lift or "front"
    local base = lift == "front" and "rear" or "front"
    local sign = lift == "front" and 1 or -1
    local gap = options.contact_gap or Metrics.contact_gap
    local function lifted(r)
        local info = r[lift]
        return info.status == "clear" or (info.status == "hit" and info.separation > gap)
    end
    local t0 = before(trace, a, options.initial).time
    local up = first(trace, a, b, lifted)
    local count, based, peak, clear, n = 0, 0, -math.huge, -math.huge, b - a + 1
    for i = a, b do
        local r = trace[i]
        if lifted(r) then count += 1 end
        if supported(r[base]) then based += 1 end
        peak = math.max(peak, sign * r.pitch)
        clear = math.max(clear, r[lift].clearance)
    end
    local out = { lifted = up ~= nil, lifted_fraction = count / n, base_supported_fraction = based / n,
        peak_lift_pitch = peak, max_lift_clearance = clear, speed_change = speed_of(trace[b]) - speed_of(before(trace, a, options.initial)),
        lifted_at_end = lifted(trace[b]) }
    local w = tail(trace, a, b, .5)
    local hold, m = 0, 0
    for i = w, b do hold += sign * trace[i].pitch m += 1 end
    out.hold_lift_pitch = hold / m
    if up then
        out.time_to_lift = trace[up].time - t0
        local longest, run, drops, sum, squares, k, low, high, rate = 0, 0, 0, 0, 0, 0, math.huge, -math.huge, 0
        for i = up, b do
            local r = trace[i]
            if lifted(r) then
                run += step_seconds(trace, i)
                longest = math.max(longest, run)
                local p = sign * r.pitch
                sum += p
                squares += p * p
                k += 1
                low, high = math.min(low, p), math.max(high, p)
                if i > up and lifted(trace[i - 1]) then
                    rate = math.max(rate, math.abs(r.pitch - trace[i - 1].pitch) / step_seconds(trace, i))
                end
            else
                if run > 0 then drops += 1 end
                run = 0
            end
        end
        local mean = sum / k
        out.longest_hold_seconds, out.touchdowns = longest, drops
        out.lift_pitch_mean, out.lift_pitch_std = mean, math.sqrt(math.max(0, squares / k - mean * mean))
        out.lift_pitch_range, out.max_lift_pitch_rate = high - low, rate
    end
    if options.release then
        local r1, r2 = options.release[1], options.release[2]
        local dropped = out.lifted_at_end and first(trace, r1, r2, function(r) return supported(r[lift]) end) or nil
        out.release_drop_seconds = 0
        if out.lifted_at_end then
            out.release_drop_seconds = (dropped and trace[dropped].time or trace[r2].time) - trace[r1 - 1].time
        end
        out.release_dropped = dropped ~= nil
    end
    return out
end

------------------------------------------------------------------------------
-- Segments: consecutive records that share a mode. mode_of(record, index)
-- returns the mode or nil (no segment). Entry and exit speeds are the speeds
-- on the first and last record of the segment.
function Metrics.segments(trace, mode_of)
    local out, current = {}, nil
    for i, r in ipairs(trace) do
        local mode = mode_of(r, i)
        if mode ~= nil and current and current.mode == mode and current.last == i - 1 then
            current.last = i
        elseif mode ~= nil then
            current = { mode = mode, first = i, last = i }
            table.insert(out, current)
        else
            current = nil
        end
    end
    for _, s in ipairs(out) do
        local times, speeds, seconds, total = {}, {}, 0, 0
        for i = s.first, s.last do
            local v = speed_of(trace[i])
            table.insert(times, trace[i].time)
            table.insert(speeds, v)
            seconds += step_seconds(trace, i)
            total += v
        end
        s.seconds = seconds
        s.entry_speed, s.exit_speed = speeds[1], speeds[#speeds]
        s.mean_speed = total / #speeds
        s.speed_change = s.exit_speed - s.entry_speed
        local fit = slope(times, speeds)
        if fit then s.deceleration = -fit end
    end
    return out
end

-- Grinds: segments in a grind_policy-style trace whose `state` is locked or
-- stalled (one grind, even if it stalls). Speeds are `rail_speed` when the
-- records carry it. The exit reason is the first one reported after the grind.
function Metrics.grind(trace, options)
    options = options or {}
    local mode_of = options.mode_of or function(r)
        return (r.state == "locked" or r.state == "stalled") and "grind" or nil
    end
    local segments = Metrics.segments(trace, mode_of)
    local out = { count = #segments }
    local s = segments[1]
    if s then
        out.entry_speed, out.exit_speed, out.seconds = s.entry_speed, s.exit_speed, s.seconds
        out.mean_speed, out.speed_change, out.deceleration = s.mean_speed, s.speed_change, s.deceleration
        if s.entry_speed > 0 then out.speed_retained = s.exit_speed / s.entry_speed end
        out.grind = trace[s.first].grind
        local exit = first(trace, s.last + 1, #trace, function(r) return r.exit_reason ~= nil and r.exit_reason ~= "none" end)
        out.exit_reason = exit and trace[exit].exit_reason or "trace_end"
    end
    return out
end

------------------------------------------------------------------------------
-- Continuity across a whole trace: a position the step's own velocity does not
-- explain (a teleport or snap), and the largest single-step changes. Records
-- with valid=false are skipped; the simulator does not integrate them.
function Metrics.continuity(trace, options)
    options = options or {}
    local jump = options.teleport_distance or .25
    local out = { max_position_residual = 0, max_speed_step = 0, teleports = 0 }
    local angles = { pitch = 0, lean = 0, yaw = 0 }
    local previous
    for i, r in ipairs(trace) do
        if r.valid ~= false then
            if previous then
                local h = r.time - previous.time
                local residual = M.length(M.sub(M.sub(r.position, previous.position), M.mul(r.velocity, h)))
                out.max_position_residual = math.max(out.max_position_residual, residual)
                if residual > jump then
                    out.teleports += 1
                    out.first_teleport = out.first_teleport or i
                end
                out.max_speed_step = math.max(out.max_speed_step, math.abs(speed_of(r) - speed_of(previous)))
                for name in pairs(angles) do
                    if type(r[name]) == "number" and type(previous[name]) == "number" then
                        angles[name] = math.max(angles[name], math.abs(wrap(r[name] - previous[name])))
                    end
                end
            end
            previous = r
        end
    end
    out.max_pitch_step, out.max_lean_step, out.max_yaw_step = angles.pitch, angles.lean, angles.yaw
    return out
end

------------------------------------------------------------------------------
-- Camera: views[i] = {eye, target, fov, reset} beside the subject position
-- subjects[i], one tick of `seconds` apart. fov is camera.look's vertical
-- field of view in degrees (Extension/Plugins/plugin_game.h:678-679); 0 or
-- none is the camera's own, which a view does not carry, so such a step is
-- counted in own_view_steps and left out of the frame test and the fov range.
-- The frame is the view's rectangle in camera.look's own basis (no roll),
-- `aspect` (width over height, Metrics.camera_aspect unless given) times as
-- wide as it is tall. min_frame_margin is the smallest angle, vertical or
-- horizontal, by which the subject is inside it; max_subject_angle is the
-- subject's angle from the aim whatever the frame's shape.
Metrics.camera_aspect = 16 / 9
-- camera.look's basis: forward along the aim, right level, up = back x right
-- (plugin_api_world.cpp camera_look).
local function look_basis(eye, target)
    local back = M.unit(M.sub(eye, target))
    assert(back, "a view's eye and target are the same point")
    local flat = math.sqrt(back[3] * back[3] + back[1] * back[1])
    local right = flat > .001 and { back[3] / flat, 0, -back[1] / flat } or { 1, 0, 0 }
    return M.mul(back, -1), right, M.cross(back, right)
end
function Metrics.camera(views, subjects, options)
    options = options or {}
    local h = options.seconds or H
    local aspect = options.aspect or Metrics.camera_aspect
    assert(#views >= 1 and #views == #subjects, "one subject per view")
    assert(finite(aspect) and aspect > 0, "aspect is width over height")
    local out = { steps = #views, min_distance = math.huge, max_distance = 0, max_eye_speed = 0,
        max_eye_acceleration = 0, max_aim_rate = 0, max_subject_angle = 0, min_frame_margin = math.huge,
        out_of_frame_steps = 0, min_fov = math.huge, max_fov = -math.huge, resets = 0, own_view_steps = 0 }
    local eyes, aims = {}, {}
    for i, view in ipairs(views) do
        local eye, target, subject = point(view.eye), point(view.target), point(subjects[i])
        local aim = M.sub(target, eye)
        local to = M.sub(subject, eye)
        local distance = M.length(to)
        out.min_distance, out.max_distance = math.min(out.min_distance, distance), math.max(out.max_distance, distance)
        out.max_subject_angle = math.max(out.max_subject_angle, angle_between(aim, to))
        if type(view.fov) == "number" and view.fov > 0 then
            local forward, right, up = look_basis(eye, target)
            local depth, half = M.dot(to, forward), math.rad(view.fov) / 2
            local wide = math.atan(aspect * math.tan(half))
            local margin = math.min(half - math.atan2(math.abs(M.dot(to, up)), depth),
                wide - math.atan2(math.abs(M.dot(to, right)), depth))
            out.min_frame_margin = math.min(out.min_frame_margin, margin)
            if margin < 0 then out.out_of_frame_steps += 1 end
            out.min_fov, out.max_fov = math.min(out.min_fov, view.fov), math.max(out.max_fov, view.fov)
        else
            out.own_view_steps += 1
        end
        if view.reset then out.resets += 1 end
        eyes[i], aims[i] = eye, aim
        if i >= 2 then
            out.max_eye_speed = math.max(out.max_eye_speed, M.length(M.sub(eye, eyes[i - 1])) / h)
            out.max_aim_rate = math.max(out.max_aim_rate, angle_between(aim, aims[i - 1]) / h)
        end
        if i >= 3 then
            local second = M.add(M.sub(eye, M.mul(eyes[i - 1], 2)), eyes[i - 2])
            out.max_eye_acceleration = math.max(out.max_eye_acceleration, M.length(second) / (h * h))
        end
    end
    if out.own_view_steps == #views then out.min_frame_margin, out.min_fov, out.max_fov = nil, nil, nil end
    return out
end

------------------------------------------------------------------------------
-- Scenario extraction over sim_scenarios.lua runners.

-- Plain per-run inputs from Scenarios runners (id -> runner): the frozen
-- trace, the tags, the placed initial state, the terrain and the stop issue.
function Metrics.collect(runners)
    local out = {}
    for id, runner in pairs(runners) do
        out[id] = {}
        for _, run in ipairs(runner.runs) do
            if run.trace then
                local body = run.initial.body
                out[id][run.name] = { trace = run.trace, tags = run.tags, terrain = run.sim.terrain,
                    valid = not run.sim.stopped, issue = run.sim.issue,
                    initial = { time = 0, position = M.copy(body.center_of_mass), velocity = M.copy(body.linear_velocity),
                        speed = math.sqrt(body.linear_velocity[1] ^ 2 + body.linear_velocity[3] ^ 2), pitch = 0 } }
            end
        end
    end
    return out
end

local extract = {}
function extract.S01(runs)
    local out = {}
    for name, run in pairs(runs) do
        local trace, tags, o = run.trace, run.tags, { initial = run.initial }
        local m = {}
        local a, b = Metrics.window(tags, "accel")
        if a then m.accel = Metrics.pedal(trace, a, b, o) end
        a, b = Metrics.window(tags, "coast")
        if a then m.coast = Metrics.slowdown(trace, a, b, o) end
        a, b = Metrics.window(tags, "brake")
        if a then m.brake = Metrics.slowdown(trace, a, b, { initial = run.initial, bands = Metrics.brake_bands }) end
        a, b = Metrics.window(tags, "rest")
        if a then m.rest = { creep_distance = path(trace, a, b, before(trace, a, run.initial).position), end_speed = speed_of(trace[b]) } end
        a, b = Metrics.window(tags, "restart")
        if a then m.restart = Metrics.pedal(trace, a, b, o) end
        out[name] = m
    end
    return out
end
function extract.S02(runs)
    local out, rows, by = {}, {}, {}
    for name, run in pairs(runs) do
        local a, b = Metrics.window(run.tags, "hold")
        local r1, r2 = Metrics.window(run.tags, "release")
        if a then
            local m = Metrics.turn(run.trace, a, b, { release = r1 and { r1, r2 } or nil })
            out[name] = m
            if m.radius then
                local row = { speed = m.mean_speed, radius = m.radius, yaw_rate = m.yaw_rate }
                table.insert(rows, row)
                by[name] = row
            end
        end
    end
    -- Mirrored pairs by the runner's own naming: left_<speed> beside right_<speed>.
    local pairs_ = {}
    for name, row in pairs(by) do
        local speed = string.match(name, "^left_(.+)$")
        if speed and by["right_" .. speed] then table.insert(pairs_, { row, by["right_" .. speed] }) end
    end
    table.sort(rows, function(x, y) return x.speed < y.speed or (x.speed == y.speed and x.yaw_rate < y.yaw_rate) end)
    if #rows >= 2 then out.summary = Metrics.turn_speed(rows, #pairs_ > 0 and pairs_ or nil) end
    return out
end
function extract.S04(runs)
    local out = {}
    for name, run in pairs(runs) do out[name] = Metrics.ramp(run.trace, { initial = run.initial }) end
    return out
end
function extract.S05(runs)
    local out = {}
    for name, run in pairs(runs) do out[name] = Metrics.air(run.trace, { initial = run.initial }) end
    return out
end
function extract.S06(runs)
    local out = {}
    for name, run in pairs(runs) do
        out[name] = Metrics.drop(run.trace, { initial = run.initial, edge_z = run.terrain.parameters.edge_z })
    end
    return out
end
function extract.S07(runs)
    local out = {}
    for name, run in pairs(runs) do
        local a, b = Metrics.window(run.tags, "hold")
        local r1, r2 = Metrics.window(run.tags, "release")
        if a then
            -- The stick's own control says which wheel the hold lifts.
            local lift = run.trace[b].nose_manual > run.trace[b].manual and "rear" or "front"
            local m = Metrics.manual(run.trace, a, b, { initial = run.initial, lift = lift, release = r1 and { r1, r2 } or nil })
            m.lift = lift
            out[name] = m
        end
    end
    return out
end
Metrics.extracted = table.freeze({ "S01", "S02", "S04", "S05", "S06", "S07" })

-- Every metric for the collected runs, keyed scenario -> run -> metric. Each
-- run also carries its continuity reduction and whether it ran to the end.
function Metrics.extract(collected)
    local out = { version = Metrics.version }
    for _, id in ipairs(Metrics.extracted) do
        local runs = collected[id]
        if runs then
            local m = extract[id](runs)
            for name, run in pairs(runs) do
                m[name] = m[name] or {}
                m[name].continuity = Metrics.continuity(run.trace)
                m[name].valid, m[name].issue = run.valid, run.issue
            end
            out[id] = m
        end
    end
    return freeze(out)
end

-- Dotted metric ids ("S05.r3_quick_hop.airtime") to leaf values. The
-- top-level version is a format number, not a metric, and is left out.
function Metrics.flatten(nested, prefix, into)
    into = into or {}
    for key, value in pairs(nested) do
        local id = prefix and (prefix .. "." .. tostring(key)) or tostring(key)
        if type(value) == "table" then Metrics.flatten(value, id, into)
        elseif prefix or key ~= "version" then into[id] = value end
    end
    return into
end

------------------------------------------------------------------------------
-- Rubric categories by scenario number, as rubric-v2.json lists them.
local ranges = { { 1, 3, "riding_steering" }, { 4, 6, "ramps_landings" }, { 7, 10, "tricks" },
    { 11, 13, "rider_movement" }, { 14, 17, "falls_recovery" }, { 18, 21, "equipment_transitions" },
    { 22, 26, "grinds_pegs_stalls" }, { 27, 32, "camera" } }
function Metrics.category(id)
    local n = tonumber(string.match(tostring(id), "^S(%d%d)%."))
    if not n then return "none" end
    for _, range in ipairs(ranges) do
        if n >= range[1] and n <= range[2] then return range[3] end
    end
    return "none"
end

-- Units by the metric's last name, most specific rule first.
local unit_rules = {
    { "energy", "J" }, { "fov", "deg" }, { "error", "1" }, { "fraction", "1" }, { "retained", "1" },
    { "yaw_rate_growth", "rad/m" }, { "growth_per_speed", "s" }, { "samples", "count" }, { "count", "count" }, { "touchdowns", "count" },
    { "teleports", "count" }, { "steps", "count" }, { "resets", "count" }, { "rate", "rad/s" },
    { "acceleration", "m/s^2" }, { "deceleration", "m/s^2" }, { "seconds", "s" }, { "time_to", "s" },
    { "airtime", "s" }, { "impact_to", "s" }, { "speed", "m/s" }, { "radius", "m" }, { "distance", "m" },
    { "rise", "m" }, { "clearance", "m" }, { "depth", "m" }, { "dip", "m" }, { "residual", "m" },
    { "pitch", "rad" }, { "lean", "rad" }, { "yaw", "rad" }, { "angle", "rad" }, { "heading", "rad" },
    { "margin", "rad" }, { "excursion", "rad" },
}
function Metrics.unit(id)
    local name = string.match(tostring(id), "([^%.]+)$") or ""
    if name == "first_teleport" then return "index" end
    if name == "version" then return "" end
    for _, rule in ipairs(unit_rules) do
        if string.find(name, rule[1], 1, true) then return rule[2] end
    end
    return ""
end

------------------------------------------------------------------------------
-- Reference observations. Each value is BMX Streets behaviour measured from
-- the running game and recorded in the project's own notes; `sources` cites
-- file:line for each. Values recovered by decompiling or decoding game files
-- are excluded. Rise and airtime were observed under a different gravity and
-- rig, and every target has caveats: read them with the score.
local function target(t)
    t.margin = t.margin or Metrics.tolerance.margin
    t.falloff = t.falloff or Metrics.tolerance.falloff
    return t
end
local GRAVITY = "Observed under BMX Streets' runtime gravity of -12.5 m/s^2 (standalone/bmx-movement/REFERENCE.md:50); "
    .. "forces.lua uses -9.8 (forces.lua:11). Compared as observed, with no gravity scaling."
local RIG = "Native rise is the chassis or combined vehicle COM above its phase start on a multi-body rig; here it is "
    .. "the single 106 kg body's COM above the step before the hop."
local CLOCK = "Native airtime is engine-clock time between ground flags (standalone/bmx-movement/COMPARISON.md:67); "
    .. "here it runs from the end of the hop step to the step whose query re-enters the 0.02 m contact gap."
Metrics.targets = freeze({
    ["S01.flat.accel.early_acceleration"] = target({
        unit = "m/s^2", observed = { 2.4911 },
        sources = { "standalone/bmx-movement/reference/comparison-v1-history.md:37",
            "standalone/bmx-movement/recordings/comparison-session01/actual-flat04-fits.json:180-184" },
        definition = "least-squares slope of speed on time while pedalling, over speeds 0.52 to 3.87 m/s",
        caveats = { "One short native session, engine clock, full pedal from rest on flat ground.",
            "The speed band is the native fit window's first and last speed; the model is fitted over the same band." },
    }),
    ["S01.flat.brake.moving_brake_deceleration"] = target({
        unit = "m/s^2", observed = { 3.7318 },
        sources = { "standalone/bmx-movement/reference/comparison-v1-history.md:37",
            "standalone/bmx-movement/recordings/comparison-session01/actual-flat04-fits.json:207-211" },
        definition = "least-squares deceleration while braking, over speeds 0.08 to 4.52 m/s",
        caveats = { "One short native session; native braking started near 4.52 m/s, the model brakes from about 8 m/s "
            .. "and only its samples inside the band are fitted.",
            "Native braking is speed dependent (REFERENCE.md:58 lists it as a fidelity gap); the model's is constant." },
    }),
    ["S01.flat.brake.later_brake_deceleration"] = target({
        unit = "m/s^2", observed = { 3.1465 },
        sources = { "standalone/bmx-movement/reference/comparison-v1-history.md:37",
            "standalone/bmx-movement/recordings/comparison-session01/actual-flat04-fits.json:261-265" },
        definition = "least-squares deceleration while braking, over speeds 0.08 to 2.67 m/s",
        caveats = { "The later part of the same native brake as moving_brake; the two are not independent." },
    }),
    ["S05.r3_quick_hop.apex_rise"] = target({
        unit = "m", observed = { 2.510, 2.404, 2.3476, 2.3279, 2.3997 },
        sources = { "standalone/bmx-movement/COMPARISON.md:36", "standalone/bmx-movement/COMPARISON.md:37",
            "standalone/bmx-movement/reference/comparison-v1-history.md:25",
            "standalone/bmx-movement/reference/comparison-v1-history.md:37",
            "standalone/bmx-movement/recordings/comparison-session01/actual-flat04-fits.json:46-47" },
        definition = "R3 quick hop from flat riding: highest COM rise above the step before the hop",
        caveats = { GRAVITY, RIG, "Five native readings from three captures; the 2.3279/2.3997 pair is one hop read as "
            .. "chassis and combined COM." },
    }),
    ["S05.r3_quick_hop.airtime"] = target({
        unit = "s", observed = { 1.430, 1.390, 1.3700, 1.3600 },
        sources = { "standalone/bmx-movement/COMPARISON.md:36", "standalone/bmx-movement/COMPARISON.md:37",
            "standalone/bmx-movement/reference/comparison-v1-history.md:26",
            "standalone/bmx-movement/recordings/comparison-session01/actual-flat04-fits.json:61" },
        definition = "R3 quick hop from flat riding: time with both tyres out of the contact gap",
        caveats = { GRAVITY, CLOCK, "Four native readings from three captures, the same hops as apex_rise; the two "
            .. "scores are not independent." },
    }),
    ["S05.full_charge_flick.apex_rise"] = target({
        unit = "m", observed = { 1.452 },
        sources = { "standalone/bmx-movement/COMPARISON.md:38" },
        definition = "right-stick flick hop from flat riding: highest COM rise above the step before the hop",
        caveats = { GRAVITY, RIG, "One native reading of a full right-stick flick; the model's flick is its full-charge gesture." },
    }),
    ["S05.full_charge_flick.airtime"] = target({
        unit = "s", observed = { 1.140 },
        sources = { "standalone/bmx-movement/COMPARISON.md:38" },
        definition = "right-stick flick hop from flat riding: time with both tyres out of the contact gap",
        caveats = { GRAVITY, CLOCK, "One native reading; not independent of the flick's apex_rise." },
    }),
})

-- Closeness of one value to one target, in [0, 1]. The band is the observed
-- range widened by `margin` of its midpoint each side; inside it the score is
-- 1, and it falls linearly to 0 at `falloff` of the midpoint beyond the band.
function Metrics.score(value, t)
    if not finite(value) then return nil, "value_not_finite" end
    if type(t) ~= "table" or type(t.observed) ~= "table" or #t.observed < 1 then return nil, "invalid_target" end
    local lo, hi = math.huge, -math.huge
    for _, v in ipairs(t.observed) do
        if not finite(v) then return nil, "invalid_target" end
        lo, hi = math.min(lo, v), math.max(hi, v)
    end
    local mid = (lo + hi) / 2
    local scale = math.abs(mid)
    if not (scale > 0) or not finite(t.margin) or not finite(t.falloff) or t.margin < 0 or not (t.falloff > 0) then
        return nil, "invalid_target"
    end
    local low, high = lo - t.margin * scale, hi + t.margin * scale
    local outside = value < low and low - value or value > high and value - high or 0
    return table.freeze({ value = value, low = low, high = high, midpoint = mid, relative_error = (value - mid) / scale,
        within = outside == 0, score = math.max(0, 1 - outside / (t.falloff * scale)) })
end

-- One row per metric (sorted by id) and one per target whose metric is
-- missing. A metric with no target is reported and marked unscored. The
-- summary keeps the lowest score, never an average, as the rubric does.
function Metrics.report(values, targets)
    targets = targets or Metrics.targets
    local ids = {}
    for id in pairs(values) do table.insert(ids, id) end
    for id in pairs(targets) do if values[id] == nil then table.insert(ids, id) end end
    table.sort(ids)
    local rows, scored, unscored, missing, lowest = {}, 0, 0, 0, nil
    for _, id in ipairs(ids) do
        local value, t = values[id], targets[id]
        local row = { id = id, category = Metrics.category(id), unit = Metrics.unit(id), value = value, scored = false }
        if value == nil then
            row.reason, row.sources = "metric_missing", t.sources
            missing += 1
        elseif not t then
            row.reason = "no_recorded_target"
            unscored += 1
        else
            local s, issue = Metrics.score(value, t)
            row.sources, row.caveats, row.definition = t.sources, t.caveats, t.definition
            if s then
                row.scored = true
                row.score, row.within, row.low, row.high = s.score, s.within, s.low, s.high
                row.relative_error, row.midpoint = s.relative_error, s.midpoint
                scored += 1
                lowest = lowest and math.min(lowest, s.score) or s.score
            else
                row.reason = issue
                unscored += 1
            end
        end
        table.insert(rows, row)
    end
    return freeze({ rows = rows, summary = { kind = "offline_model_closeness", disclaimer = Metrics.disclaimer,
        scored = scored, unscored = unscored, missing = missing, lowest_score = lowest or -1,
        tolerance = { margin = Metrics.tolerance.margin, falloff = Metrics.tolerance.falloff } } })
end

-- Collect, extract, flatten and report Scenarios.run()'s runners at once.
function Metrics.evaluate(runners, targets)
    local metrics = Metrics.extract(Metrics.collect(runners))
    return Metrics.report(Metrics.flatten(metrics), targets), metrics
end

return table.freeze(Metrics)

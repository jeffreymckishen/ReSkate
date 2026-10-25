-- Pure Luau cases for manual_balance.lua. Nothing runs on require; call
-- require("./manual_balance_tests").run(progress) from a Luau runner. No game,
-- native body, input lease or reskate service is used. The pitch plant below is
-- a constructed point model: passing here is not in-game evidence.
local Balance = require("./manual_balance")
local Forces = require("./forces")
local Input = require("./input")
local Tests = {}
local H = Forces.native_seconds

-- One rigid bike pitching about whichever wheel stays down. It is driven the
-- way forces.lua drives the body (default balance stiffness, damping and
-- torque limit toward the commanded pitch) against gravity acting at an
-- authored weight-shifted centre of mass. Contact is perfectly plastic.
local function plant(options)
    options = options or {}
    local tuning, body = Forces.tuning(), Forces.proposed_body()
    return { theta = options.theta or 0, omega = options.omega or 0, lever = options.lever or 0.3, height = 0.9,
        mass = body.mass, weight = body.mass * -tuning.gravity[2], inertia = body.inertia_body[1],
        stiffness = tuning.balance_stiffness, damping = tuning.balance_damping,
        limit = tuning.balance_torque_limit, manual_pitch = tuning.manual_pitch }
end

local function advance(p, out, dt)
    dt = dt or H
    local command = (out.manual - out.nose_manual) * p.manual_pitch
    local torque = math.clamp(p.stiffness * math.sin(command - p.theta) - p.damping * p.omega, -p.limit, p.limit)
    local function pivot(sign, angle)
        local lift = sign * angle
        local gravity = -sign * p.weight * (p.lever * math.cos(lift) - p.height * math.sin(lift))
        return gravity, p.inertia + p.mass * (p.lever * p.lever + p.height * p.height)
    end
    local gravity, inertia
    if p.theta > 0 then gravity, inertia = pivot(1, p.theta)
    elseif p.theta < 0 then gravity, inertia = pivot(-1, p.theta)
    elseif torque > 0 then
        gravity, inertia = pivot(1, 0)
        if torque + gravity <= 0 then p.omega = 0; return end
    elseif torque < 0 then
        gravity, inertia = pivot(-1, 0)
        if torque + gravity >= 0 then p.omega = 0; return end
    else
        p.omega = 0; return
    end
    p.omega = p.omega + (torque + gravity) / inertia * dt
    local before, after = p.theta, p.theta + p.omega * dt
    if (before > 0 and after <= 0) or (before < 0 and after >= 0) then after, p.omega = 0, 0 end
    p.theta = after
end

local function sample(p, manual, nose, speed, extra)
    local s = { manual = manual or 0, nose_manual = nose or 0, pitch = p.theta, pitch_rate = p.omega,
        front_support = p.theta <= 0, rear_support = p.theta >= 0, speed = speed or 4 }
    for key, value in pairs(extra or {}) do s[key] = value end
    return s
end

-- A direct sample without a plant, for state-machine edges.
local function flat(changes)
    local s = { manual = 0, nose_manual = 0, pitch = 0, pitch_rate = 0,
        front_support = true, rear_support = true, speed = 4 }
    for key, value in pairs(changes or {}) do s[key] = value end
    return s
end

local function equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end

function Tests.run(progress)
    local assertions, cases = 0, 0
    local function check(condition, message)
        assertions = assertions + 1
        assert(condition, message)
    end
    local function near(a, b, tolerance) return math.abs(a - b) <= (tolerance or 1e-12) end
    local function case(name, body)
        cases = cases + 1
        local ok, issue = pcall(body)
        if not ok then error(name .. ": " .. tostring(issue), 0) end
        if type(progress) == "function" then progress(cases, assertions) end
    end
    local function held(kind, amount, changes)
        local s = flat(changes)
        s[kind] = amount or 0.5
        return s
    end
    -- Reaches balancing with constructed samples: arm, pull, then report the
    -- lifted wheel clear at the balance point until the entry ramp is done.
    local function balancing(kind, settings)
        local m = Balance.new(settings)
        m:step(flat(), H)
        check(m:step(held(kind), H).state == "entering", "constructed entry reaches entering")
        local sign = kind == "manual" and 1 or -1
        local point = m:settings()[kind == "manual" and "manual_balance_point" or "nose_balance_point"]
        local up = held(kind, 0.5, { pitch = sign * point, front_support = kind ~= "manual",
            rear_support = kind == "manual" })
        local events = 0
        for _ = 1, 30 do
            local out = m:step(up, H)
            if out.event then
                events = events + 1
                check(out.event.name == "balancing", "the only event on the way up is balancing")
            end
            if out.state == "balancing" then break end
        end
        check(events == 1 and m:status().state == "balancing" and m:status().target == point,
            "constructed lift reaches balancing once the ramp is done")
        return m, up
    end

    case("inert module and forces conversion", function()
        check(type(Balance.new) == "function" and type(Balance.measure) == "function", "module returns its API table")
        local m = Balance.new()
        local status = m:status()
        check(status.state == "idle" and status.kind == "none" and not status.armed and status.sequence == 0,
            "a new model is idle, unarmed and has emitted nothing")
        check(m:settings().manual_pitch == Forces.tuning().manual_pitch,
            "the default conversion matches forces.lua manual_pitch")
    end)

    case("zero input leaves the point model at rest", function()
        local m, p = Balance.new(), plant()
        for _ = 1, 600 do
            local out = m:step(sample(p, 0, 0, 4), H)
            check(out.valid and out.state == "idle" and out.event == nil, "zero input never transitions")
            check(out.manual == 0 and out.nose_manual == 0 and not out.bail_request, "zero input requests nothing")
            advance(p, out)
        end
        check(p.theta == 0 and p.omega == 0, "the constructed plant stays exactly level")
        check(m:status().sequence == 0, "no event was emitted")
    end)

    for _, kind in ipairs({ "manual", "nose_manual" }) do
        case(kind .. " in-band stick holds the balance point", function()
            local m, p = Balance.new(), plant()
            local sign = kind == "manual" and 1 or -1
            local other = kind == "manual" and "nose_manual" or "manual"
            local point = m:settings()[kind == "manual" and "manual_balance_point" or "nose_balance_point"]
            m:step(sample(p), H)
            local names, worst, last = {}, 0, nil
            for n = 1, 600 do
                local s = sample(p)
                s[kind] = 0.5
                last = m:step(s, H)
                if last.event then
                    table.insert(names, last.event.name)
                    check(last.event.kind == kind, "each event names its kind")
                end
                check(last[other] == 0 and last[kind] >= 0 and last[kind] <= 1, "only this kind's fraction is requested")
                advance(p, last)
                if n > 120 then
                    check(last.state == "balancing" and last.kind == kind, "the hold stays balancing")
                    worst = math.max(worst, math.abs(sign * p.theta - point))
                end
            end
            check(#names == 2 and names[1] == "entering" and names[2] == "balancing", "entry then balance, nothing else")
            check(worst <= 0.02, "zero correction holds within 0.02 rad for 480 steps")
            check(math.abs(sign * p.theta - point) <= 0.005 and math.abs(last.balance) < 0.05, "the hold settles on the point")
            check(last.balance_point == point and last.target == point, "an in-band entry parks the target exactly")
        end)
    end

    case("entry obeys the neutral rearm", function()
        local m = Balance.new()
        check(m:step(held("manual"), H).issue == "neutral_required", "a new model refuses a held manual")
        check(m:step(held("manual"), H).state == "idle", "holding longer never arms")
        m:step(flat(), H)
        local out = m:step(held("manual", 0.55), H)
        check(out.event and out.event.name == "entering" and out.kind == "manual", "partial back enters a manual")
        check(out.manual > 0 and out.nose_manual == 0, "entry requests lift immediately")
        m:cancel(); m:step(flat(), H)
        out = m:step(held("nose_manual", 0.55), H)
        check(out.event and out.kind == "nose_manual" and out.nose_manual > 0 and out.manual == 0,
            "partial forward enters a nose manual")
        m:cancel(); m:step(flat(), H)
        out = m:step(flat({ manual = 0.5, nose_manual = 0.5 }), H)
        check(out.state == "idle" and out.issue == "conflicting_input", "both sides at once cannot create a balance")
        check(m:step(held("manual"), H).issue == "neutral_required", "a refused attempt consumes the arm")
        m:step(flat(), H)
        local air = { front_support = false, rear_support = false }
        out = m:step(held("manual", 0.5, air), H)
        check(out.state == "idle" and out.issue == "unsupported", "an airborne stick cannot claim a manual")
        check(m:step(held("manual"), H).issue == "neutral_required", "a held landing needs neutral")
        check(not m:step(flat(air), H).armed, "neutral in the air arms nothing")
        check(m:step(held("manual"), H).issue == "neutral_required", "neutral in the air does not arm the landing")
        m:step(flat(), H)
        check(m:step(held("manual"), H).state == "entering", "landing neutral rearms the manual")
        m:cancel()
        check(m:step(flat({ rear_neutral = false }), H).state == "ended", "a deflected rear stick is not neutral")
        check(m:step(flat({ preload = 0.3 }), H).state == "ended", "a hop charge is not neutral")
        check(m:step(flat({ hop = true }), H).state == "ended", "a hop request is not neutral")
        check(m:step(flat({ manual = 0.03 }), H).state == "ended", "a lift above the neutral input is not neutral")
        check(m:step(flat({ manual = 0.02 }), H).state == "idle", "the neutral input itself is neutral")
        -- The wrong wheel down and a pending hop are refusals too, and they
        -- consume the arm like the others.
        local refusals = {
            { held("manual", 0.5, { rear_support = false }), "base_wheel_unsupported" },
            { held("nose_manual", 0.5, { front_support = false }), "base_wheel_unsupported" },
            { held("manual", 0.5, { preload = 0.3 }), "hop_pending" },
            { held("manual", 0.5, { hop = true }), "hop_pending" },
        }
        for _, refusal in ipairs(refusals) do
            m:step(flat(), H)
            out = m:step(refusal[1], H)
            check(out.state == "idle" and out.issue == refusal[2] and out.event == nil and not out.armed,
                "a refusal names its issue, emits nothing and consumes the arm")
            check(out.manual == 0 and out.nose_manual == 0, "a refusal requests nothing")
            check(m:step(refusal[1], H).issue == "neutral_required", "a refused stick cannot enter late")
        end
        -- input.lua ramps its manual output up from zero, so a stick between
        -- neutral and engagement is neither neutral nor an attempt.
        m:step(flat(), H)
        for _, amount in ipairs({ 0.03, 0.05, 0.07 }) do
            out = m:step(held("manual", amount), H)
            check(out.state == "idle" and out.issue == "none" and out.armed and out.event == nil,
                "a stick below engagement keeps the arm")
        end
        out = m:step(held("manual", 0.5), H)
        check(out.event and out.event.name == "entering", "the slow pull then enters")
    end)

    case("the entry ramp starts from the measured lift and scales with the pull", function()
        local s = Balance.new():settings()
        local point, step = s.manual_balance_point, s.entry_rate * H
        -- A bike already tilted starts the ramp where it is, clamped to the
        -- range between level and the balance point.
        for _, start in ipairs({ { 0.1, 0.1 + step }, { 0.3, point }, { -0.1, step } }) do
            local m = Balance.new()
            m:step(flat({ pitch = start[1] }), H)
            check(m:step(held("manual", 0.5, { pitch = start[1] }), H).state == "entering", "a tilted bike enters")
            check(near(m:status().target, start[2]), "the first target is the measured lift plus one ramp step")
        end
        -- Below the sweet spot the ramp aims proportionally lower. The lifted
        -- wheel stays down here, so the attempt stays entering.
        local low = s.sweet_spot - s.sweet_spot_width * 0.5
        for _, pull in ipairs({ 0.15, 0.3 }) do
            local m = Balance.new()
            m:step(flat(), H)
            for _ = 1, 21 do m:step(held("manual", pull), H) end
            local goal = point * (pull - s.engage_input) / (low - s.engage_input)
            check(m:status().state == "entering" and near(m:status().target, goal), "a shallow pull aims lower")
            check(m:status().integral == 0, "the integral waits while the lifted wheel is down")
        end
    end)

    for _, kind in ipairs({ "manual", "nose_manual" }) do
        case(kind .. " over-rotation ends once with a bail request", function()
            local reason = kind == "manual" and "loop_out" or "nose_over"
            local m, p = Balance.new(), plant()
            local sign = kind == "manual" and 1 or -1
            m:step(sample(p), H)
            local function pull(amount)
                local s = sample(p)
                s[kind] = amount
                local out = m:step(s, H)
                advance(p, out)
                return out
            end
            for _ = 1, 120 do if pull(0.5).state == "balancing" then break end end
            check(m:status().state == "balancing", "the constructed plant reached balancing")
            local ends, bails, steps = 0, 0, 0
            for _ = 1, 240 do
                local out = pull(0.95)
                steps = steps + 1
                if out.event then
                    check(out.event.name == "ended" and out.event.reason == reason and out.event.bail_request,
                        "deep stick climbs past the point of no return")
                    ends = ends + 1
                end
                if out.bail_request then bails = bails + 1 end
                check(out.state ~= "entering" and out.state ~= "balancing" or ends == 0, "no re-entry after the end")
            end
            check(ends == 1 and bails == 1, "exactly one over-rotation end and one bail request")
            check(m:status().bail_pending and m:status().end_reason == reason, "status latches the request until neutral")
            check(sign * p.theta < 0.5, "the request is made before the plant leaves the constructed range")
            local out = m:step(sample(p), H)
            check(out.event and out.event.name == "idle" and not m:status().bail_pending, "neutral clears the latch")
        end)
    end

    case("over-rotation is judged on the measured lift and the target", function()
        local m, up = balancing("manual")
        up.pitch = 0.37
        local out = m:step(up, H)
        check(out.event and out.event.reason == "loop_out" and out.bail_request, "a measured loop out requests a bail")
        check(m:step(up, H).event == nil, "the next step emits nothing")
        m = balancing("nose_manual")
        out = m:step(held("nose_manual", 0.5, { pitch = -0.31, front_support = true, rear_support = false }), H)
        check(out.event and out.event.reason == "nose_over", "a measured nose over requests a bail")
        -- forces.lua caps its command, so the measured lift can stall below
        -- the loop-out angle while the rider keeps leaning back.
        m, up = balancing("manual")
        up.manual = 0.95
        local loop_out = m:settings().manual_loop_out
        local reason, target
        for _ = 1, 120 do
            local before = m:status().target
            out = m:step(up, H)
            if out.event then reason = out.event.reason; target = before; break end
        end
        check(reason == "loop_out" and up.pitch < loop_out and target < loop_out, "a deep lean loops out on the target")
    end)

    case("the tipping term needs correction", function()
        local m, up = balancing("manual")
        local point = m:settings().manual_balance_point
        up.manual = 0.9
        for _ = 1, 6 do m:step(up, H) end
        up.manual = 0.5
        local previous = m:status().target
        check(previous > point, "a deep pulse moves the target above the point")
        for _ = 1, 30 do
            m:step(up, H)
            local now = m:status().target
            check(now > previous, "an in-band stick keeps tipping away from the point")
            previous = now
        end
        up.manual = 0.2
        for _ = 1, 120 do
            m:step(up, H)
            if m:status().target < point then break end
        end
        check(m:status().state == "balancing" and m:status().target < point, "a shallow stick corrects the tip")
        up.manual = 0.5
        previous = m:status().target
        m:step(up, H)
        check(m:status().target < previous, "below the point the tip runs toward a front drop")
        m, up = balancing("manual")
        up.nose_manual = 0.5
        local out = m:step(up, H)
        check(out.state == "balancing" and m:status().target < m:settings().manual_balance_point,
            "pushing to the other side releases the manual instead of swapping kinds")
        check(out.kind == "manual" and out.nose_manual == 0, "the kind never changes mid-lift")
    end)

    case("the stick and speed set the target rate while balancing", function()
        local s = Balance.new():settings()
        local point = s.manual_balance_point
        -- The documented law, written out independently of the module.
        local function rate(pull, speed)
            local half = s.sweet_spot_width * 0.5 * math.clamp(speed / s.band_full_speed, s.band_min_scale, 1)
            local low, high = s.sweet_spot - half, s.sweet_spot + half
            local value = 0
            if pull > high then value = s.climb_rate * (pull - high) / (1 - high)
            elseif pull < low then value = -s.fall_rate * (low - pull) / low end
            if speed < s.stall_speed then value = value - s.stall_fall_rate * (s.stall_speed - speed) / s.stall_speed end
            return value
        end
        local rows = { { 0, 4 }, { 0.2, 4 }, { 0.5, 4 }, { 0.62, 4 }, { 0.8, 4 }, { 0.95, 4 }, { 0.62, 3 },
            { 0.62, 1.2 }, { 0.3, 1.2 }, { 0.5, 0.3 }, { 0.8, 0.3 } }
        for _, row in ipairs(rows) do
            local m, up = balancing("manual")
            up.manual, up.speed = row[1], row[2]
            m:step(up, H)
            local first = point + rate(row[1], row[2]) * H
            check(near(m:status().target, first), "one step from the point follows the stick and speed law")
            -- The second step adds the tipping term on the first offset.
            m:step(up, H)
            local second = first + (rate(row[1], row[2]) + s.instability * (first - point)) * H
            check(near(m:status().target, second), "away from the point the tipping term adds on")
        end
        -- A full release with the wheel still clear floors the target at level.
        local m, up = balancing("manual")
        up.manual = 0
        for _ = 1, 60 do m:step(up, H) end
        check(m:status().state == "balancing" and m:status().target == 0, "the target never goes below level")
    end)

    case("the balance meter spans drop to over-rotation", function()
        for _, kind in ipairs({ "manual", "nose_manual" }) do
            local sign = kind == "manual" and 1 or -1
            local s = Balance.new():settings()
            local point = s[kind == "manual" and "manual_balance_point" or "nose_balance_point"]
            local over = s[kind == "manual" and "manual_loop_out" or "nose_over"]
            local drop = s[kind == "manual" and "manual_drop" or "nose_drop"]
            for _, fraction in ipairs({ -0.5, -0.25, 0.25, 0.5 }) do
                local m, up = balancing(kind)
                local lift = fraction < 0 and point + fraction * (point - drop) or point + fraction * (over - point)
                up.pitch = sign * lift
                local out = m:step(up, H)
                check(out.state == "balancing" and near(out.lift, lift) and near(out.balance, fraction),
                    "the meter is linear on each side of the point")
            end
        end
    end)

    for _, kind in ipairs({ "manual", "nose_manual" }) do
        case(kind .. " integral removes sag without winding up", function()
            local sign = kind == "manual" and 1 or -1
            local function hold(m, up, lift)
                up.pitch = sign * lift
                local out, history = nil, {}
                for n = 1, 600 do
                    out = m:step(up, H)
                    history[n] = m:status().integral
                    check(out.state == "balancing" and out.event == nil, "a constructed held lift stays balancing")
                end
                return out, history
            end
            local m, up = balancing(kind)
            local s = m:settings()
            local point = s[kind == "manual" and "manual_balance_point" or "nose_balance_point"]
            -- A lift held below the target is sag: the integral grows until
            -- the command pins at full manual_pitch, then stops there.
            local start = m:status().integral
            local out, history = hold(m, up, point - 0.04)
            check(history[1] > start and near(history[1], start + s.settle_gain * (point - (point - 0.04)) * H),
                "sag below the target winds the integral up at settle_gain")
            check(out[kind] == 1, "until the command pins at full manual_pitch")
            check(history[600] == history[300] and history[600] < s.settle_limit - 0.05,
                "a pinned command stops the integral short of its limit")
            -- Mirrored: a lift held above the target winds it down until the
            -- command reaches zero.
            m, up = balancing(kind)
            start = m:status().integral
            out, history = hold(m, up, point + 0.06)
            check(history[1] < start, "a lift above the target winds the integral down")
            check(out[kind] == 0, "until the command reaches zero")
            check(history[600] == history[300] and history[600] > 0.05 - s.settle_limit,
                "a command at zero stops the integral short of its limit")
            -- Without proportional gain the command never pins here, so
            -- settle_limit is what bounds the integral, in both directions.
            local bounded = { lift_gain = 0, settle_limit = 0.05 }
            m, up = balancing(kind, bounded)
            out, history = hold(m, up, point - 0.04)
            check(out[kind] > 0 and out[kind] < 1 and history[600] == 0.05, "settle_limit bounds a rising integral")
            m, up = balancing(kind, bounded)
            out, history = hold(m, up, point + 0.06)
            check(out[kind] > 0 and out[kind] < 1 and history[600] == -0.05, "settle_limit bounds a falling integral")
        end)
    end

    case("the lifted wheel touching ends the lift", function()
        local m, up = balancing("manual")
        up.front_support = true
        local out = m:step(up, H)
        check(out.event and out.event.reason == "front_drop" and not out.bail_request, "front support ends a manual")
        check(out.state == "ended" and out.manual == 0 and out.nose_manual == 0, "an end requests no lift")
        for _ = 1, 30 do check(m:step(up, H).event == nil, "a held stick on the ground emits nothing more") end
        m, up = balancing("nose_manual")
        up.rear_support = true
        check(m:step(up, H).event.reason == "rear_drop", "rear support ends a nose manual")
        m, up = balancing("manual")
        up.front_support, up.rear_support = true, false
        check(m:step(up, H).event.reason == "front_drop", "rocking onto the front wheel ends the manual")
        m, up = balancing("manual")
        up.pitch = 0.03
        check(m:step(up, H).event.reason == "front_drop", "a lift under the drop angle ends before contact is seen")
    end)

    case("entry failures end as drops or cancels", function()
        local m, p = Balance.new(), plant()
        local seconds = m:settings().entry_seconds
        m:step(sample(p), H)
        local window = m:settings().manual_balance_point - m:settings().entry_window
        local reason, steps, highest = nil, 0, 0
        for n = 1, 120 do
            local out = m:step(sample(p, 0.2), H)
            check(out.state ~= "balancing", "a shallow pull never balances")
            advance(p, out)
            highest = math.max(highest, p.theta)
            if out.event and out.event.name == "ended" then reason, steps = out.event.reason, n; break end
        end
        check(reason == "front_drop" and highest < window, "a shallow pull aims below the entry window")
        -- The entering step itself starts the clock; each later step adds dt.
        check((steps - 1) * H > seconds and (steps - 2) * H <= seconds, "and times out after entry_seconds")
        m = Balance.new()
        m:step(flat(), H); m:step(held("manual"), H)
        check(m:step(held("manual", 0.5, { rear_support = false }), H).event.reason == "front_drop",
            "losing the rear wheel while entering ends the manual")
        m = Balance.new()
        m:step(flat(), H); m:step(held("nose_manual"), H)
        check(m:step(flat(), H).event.reason == "cancelled", "releasing before the lift cancels it")
        m = Balance.new()
        m:step(flat(), H); m:step(held("manual"), H)
        check(m:step(held("manual", 0.5, { front_support = false, rear_support = false }), H).state == "entering",
            "a one-step support gap while entering is held")
        -- input.lua reports no manual while a hop charges, so a charge while
        -- entering is not a release.
        m = Balance.new()
        m:step(flat(), H); m:step(held("manual"), H)
        check(m:step(flat({ preload = 0.4 }), H).state == "entering", "a hop charge while entering is not a release")
        check(m:step(flat({ hop = true }), H).event.reason == "hop_out", "the pop ends the entry as a hop")
        -- A lift at the point that still reports contact has not left the ground.
        m = Balance.new()
        m:step(flat(), H); m:step(held("manual"), H)
        local touching = held("manual", 0.5, { pitch = m:settings().manual_balance_point })
        for _ = 1, 20 do check(m:step(touching, H).state == "entering", "a lift still touching does not balance") end
        -- With exact 1/32 s steps the timeout boundary is visible: an elapsed
        -- time equal to entry_seconds still enters; only past it is a drop.
        local dt = 1 / 32
        m = Balance.new()
        m:step(flat(), dt); m:step(held("manual"), dt)
        local ended
        for n = 1, 40 do
            if m:step(held("manual"), dt).event then ended = n; break end
        end
        check(ended == 33, "the entry ends once its elapsed time passes entry_seconds")
    end)

    case("releasing the stick lets the front down", function()
        -- Released as balancing begins, and after a settled 2 s hold.
        for _, settle in ipairs({ 0, 120 }) do
            local m, p = Balance.new(), plant()
            m:step(sample(p), H)
            for _ = 1, 120 do
                local out = m:step(sample(p, 0.5), H)
                advance(p, out)
                if out.state == "balancing" then break end
            end
            for _ = 1, settle do advance(p, m:step(sample(p, 0.5), H)) end
            local reason, steps = nil, 0
            for n = 1, 120 do
                local out = m:step(sample(p, 0), H)
                advance(p, out)
                if out.event then reason, steps = out.event.reason, n; break end
            end
            -- Rate-limited by fall_rate, so neither a slam nor a slow sink.
            check(reason == "front_drop" and steps * H >= 0.4 and steps * H <= 0.6,
                "a release ends as a front drop in 0.4 to 0.6 s")
            check(m:step(sample(p, 0), H).event.name == "idle", "the released stick is already neutral")
        end
    end)

    case("a slow pull through input.lua enters", function()
        local mapper, m = Input.new(), Balance.new()
        local settings = mapper:settings()
        local neutral = settings.deadzone + (1 - settings.deadzone) * settings.neutral_threshold
        local function feed(y)
            local a = mapper:update(Input.raw({ available = true, device = 7, right_y = y }), { grounded = true }, H)
            return m:step(flat({ manual = a.manual, nose_manual = a.nose_manual, preload = a.preload,
                hop = a.hop_pressed, rear_neutral = math.abs(y) <= neutral }), H), a.manual
        end
        feed(0)
        -- About 1.8 s from centre to a half pull: input.lua's manual output
        -- passes through values between neutral and engagement on the way.
        local engage, partial, entered = m:settings().engage_input, 0, nil
        for n = 1, 110 do
            local out, manual = feed(-0.005 * n)
            if manual > 0 and manual < engage then
                partial = partial + 1
                check(out.state == "idle" and out.armed and out.event == nil, "a partial pull keeps the arm")
            end
            if out.event then
                check(out.event.name == "entering", "the first event is the entry")
                entered = manual
                break
            end
        end
        check(partial >= 3, "the ramp produced partial pulls")
        check(entered ~= nil and entered >= engage and entered < engage + 0.02, "a slow pull enters at engagement")
    end)

    case("hop out and airborne", function()
        local m, up = balancing("manual")
        local hop = held("manual", 0, { pitch = up.pitch, front_support = false, preload = 0.5 })
        local target = m:status().target
        for _ = 1, 15 do check(m:step(hop, H).state == "balancing", "a hop charge holds the manual") end
        check(m:status().target == target, "the charge holds the target where it was")
        hop.preload, hop.hop = 0, true
        local out = m:step(hop, H)
        check(out.event and out.event.reason == "hop_out" and not out.bail_request, "a hop ends the manual without a bail")
        m, up = balancing("manual")
        up.rear_support = false
        local count = 0
        for n = 1, 6 do
            out = m:step(up, H)
            if out.event then
                count = count + 1
                check(out.event.reason == "airborne" and n >= 3, "both wheels clear past the grace ends airborne")
            end
            if n <= 2 then check(out.state == "balancing", "a short support gap keeps balancing") end
        end
        check(count == 1, "airborne is emitted once")
        check(m:status().target == 0 and m:status().integral == 0, "an end clears the balance state")
        out = m:step(flat({ front_support = false, rear_support = false }), H)
        check(out.event and out.event.name == "idle" and out.kind == "none" and m:status().kind == "none",
            "neutral in the air leaves the end and clears the kind")
        check(not out.armed, "but arms nothing until the ground is seen")
        check(m:step(held("manual"), H).issue == "neutral_required", "landing with the stick held needs neutral")
        -- The grace is inclusive: with 0.025 s steps, two clear steps are
        -- exactly airborne_grace.
        m, up = balancing("manual")
        local clear = held("manual", 0.5, { pitch = up.pitch, front_support = false, rear_support = false })
        check(m:step(clear, 0.025).state == "balancing", "one clear step is inside the grace")
        check(m:step(clear, 0.025).event.reason == "airborne", "a gap of exactly airborne_grace ends the lift")
        -- Rough ground: two-step gaps between supported steps never add up to
        -- the grace, and each gap holds the command the last support step had.
        m, up = balancing("manual")
        local gap = held("manual", 0.5, { pitch = up.pitch, front_support = false, rear_support = false })
        local previous = m:step(up, H)
        for _ = 1, 20 do
            for _ = 1, 2 do
                out = m:step(gap, H)
                check(out.state == "balancing" and out.event == nil and out.issue == "unsupported",
                    "a short gap keeps balancing")
                check(out.manual > 0 and near(out.manual, previous.manual), "the grace holds the lift")
            end
            previous = m:step(up, H)
            check(previous.state == "balancing" and previous.event == nil, "support resets the grace")
        end
    end)

    case("invalid dt and samples reset", function()
        for _, bad in ipairs({ 0, -H, 0 / 0, math.huge, 0.2 }) do
            local m, up = balancing("manual")
            local out = m:step(up, bad)
            check(not out.valid and out.issue == "invalid_dt", "invalid dt is refused")
            check(out.event and out.event.reason == "cancelled" and out.state == "ended", "invalid dt cancels the lift")
            check(out.manual == 0 and out.nose_manual == 0, "a reset requests nothing")
            check(m:step(up, H).issue == "neutral_required", "reset cannot resume a held lift")
            check(m:step(flat(), H).event.name == "idle", "neutral leaves the end")
            check(m:step(held("manual"), H).state == "entering", "neutral after a reset rearms")
        end
        local m = Balance.new()
        m:step(flat(), H)
        check(m:step(flat(), nil).issue == "invalid_dt" and m:status().state == "idle", "idle reset has no event")
        check(m:step(held("manual"), H).issue == "neutral_required", "an idle reset consumes the arm")
        local bad_samples = { false, {}, flat({ manual = -0.1 }), flat({ nose_manual = 1.5 }), flat({ pitch = 0 / 0 }),
            flat({ pitch_rate = math.huge }), flat({ speed = 1e9 }), flat({ front_support = "yes" }),
            flat({ hop = 1 }), flat({ preload = 2 }), flat({ rear_neutral = 0 }), flat({ pitch = -4 }),
            flat({ pitch_rate = 60 }) }
        for _, bad in ipairs(bad_samples) do
            local active, up = balancing("nose_manual")
            local out = active:step(bad, H)
            check(not out.valid and out.issue == "invalid_sample" and out.event.reason == "cancelled",
                "an invalid sample cancels the lift")
            check(active:step(up, H).event == nil, "and cannot resume it")
        end
    end)

    case("settings are sanitized and readback is detached", function()
        local m = Balance.new({ manual_pitch = 0 / 0, neutral_input = 9, engage_input = -1, sweet_spot = 2,
            sweet_spot_width = 0, manual_balance_point = 5, manual_loop_out = 0, manual_drop = 9,
            entry_window = 9, min_entry_speed = -5, stall_speed = 3, max_step_seconds = 0, unknown = 1 })
        local s = m:settings()
        check(s.manual_pitch == 0.4 and s.neutral_input == 0.2, "non-finite falls back; values clamp")
        check(near(s.engage_input, 0.22) and s.sweet_spot_width == 0.05, "engagement sits above neutral")
        check(near(s.sweet_spot, 0.99 - 0.025), "the sweet spot stays below full stick")
        check(near(s.manual_balance_point, 0.32) and near(s.manual_loop_out, 0.36) and near(s.manual_drop, 0.28),
            "angles keep their order")
        check(near(s.entry_window, 0.03), "the entry window cannot reach the drop angle")
        check(s.stall_speed == 3 and s.min_entry_speed == 3 and s.max_step_seconds == 0.005,
            "entry speed is never below stall speed")
        check(s.unknown == nil, "unknown settings are dropped")
        check(Balance.new({ manual_pitch = 1 }):settings().manual_pitch == 0.6,
            "manual_pitch stays within what forces.lua accepts")
        s.manual_pitch = 1
        check(m:settings().manual_pitch == 0.4, "settings readback cannot mutate the model")
        check(equal(Balance.new(7):settings(), Balance.new():settings()), "non-table settings use the defaults")
        local active = balancing("manual")
        local status = active:status()
        status.state, status.target = "idle", 99
        check(active:status().state == "balancing" and active:status().target ~= 99, "status readback is detached")
        local event = active:configure({ climb_rate = 0 })
        check(event and event.reason == "cancelled" and active:status().state == "ended", "configure cancels a lift")
        check(active:settings().climb_rate == 0, "configure applies sanitized settings")
    end)

    case("the balance points stay under the command ceiling at every manual_pitch", function()
        -- Each point is capped at 0.8 x manual_pitch so the command keeps room
        -- to cancel sag. Below a manual_pitch of 0.0625 that cap is under the
        -- usual 0.05 floor. The floor has to give way, or the point lands on
        -- manual_pitch itself and a lift held there saturates the command.
        -- Each row: manual_pitch, expected manual point, expected nose point,
        -- optional overrides.
        local rows = {
            { 0.05, 0.04, 0.04 }, { 0.055, 0.044, 0.044 }, { 0.0625, 0.05, 0.05 }, { 0.1, 0.08, 0.08 },
            { 0.4, 0.22, 0.16 }, { 0.6, 0.22, 0.16 },
            { 0.05, 0.04, 0.04, { manual_balance_point = 1, nose_balance_point = -1, manual_drop = 1,
                nose_drop = -1, manual_loop_out = 0, nose_over = 0, entry_window = 1 } },
        }
        for _, row in ipairs(rows) do
            local settings = { manual_pitch = row[1] }
            for key, value in pairs(row[4] or {}) do settings[key] = value end
            local s = Balance.new(settings):settings()
            check(s.manual_pitch == row[1], "manual_pitch is kept, so the force conversion is unchanged")
            for index, kind in ipairs({ "manual", "nose_manual" }) do
                local manual = kind == "manual"
                local point = s[manual and "manual_balance_point" or "nose_balance_point"]
                local over, drop = s[manual and "manual_loop_out" or "nose_over"], s[manual and "manual_drop" or "nose_drop"]
                check(near(point, row[index + 1]) and point <= 0.8 * row[1],
                    "the point sits at or under 0.8 x manual_pitch")
                check(drop >= 0 and drop <= point - 0.04 + 1e-12 and over >= point + 0.04 - 1e-12,
                    "drop and over-rotation keep their clearance from the point")
                check(s.entry_window >= 0.005 and s.entry_window <= point - drop - 0.01 + 1e-12,
                    "the entry window stays clear of the drop")
                -- A lift entered already at the point has no error and no
                -- integral yet, so its command is the point itself.
                local m = Balance.new(settings)
                m:step(flat(), H)
                local up = held(kind, 0.5, { pitch = (manual and 1 or -1) * point, front_support = not manual,
                    rear_support = manual })
                local out = m:step(up, H)
                check(out.state == "entering" and near(out[kind], point / row[1]) and out[kind] <= 0.8 + 1e-12,
                    "a lift at the point leaves the command headroom below saturation")
                out = m:step(up, H)
                check(out.state == "balancing" and near(out[kind], point / row[1]), "and it balances there")
            end
        end
    end)

    case("deterministic replay and one event per transition", function()
        local function script()
            local m, p, seed, outs = Balance.new(), plant(), 12345, {}
            local stick, speed = 0, 4
            for n = 1, 900 do
                -- Park-Miller stays exact in doubles, so the script is fixed.
                seed = seed * 16807 % 2147483647
                if n % 20 == 1 then
                    local pick = seed % 7
                    stick = ({ 0, 0, 0.5, 0.55, 0.45, 0.9, 0.2 })[pick + 1]
                    speed = ({ 4, 4, 2, 0.3, 6, 4, 1.2 })[(seed // 7) % 7 + 1]
                end
                local nose = n > 450 and stick or 0
                local manual = n <= 450 and stick or 0
                local before = m:status().state
                local out = m:step(sample(p, manual, nose, speed), H)
                if out.state ~= before then
                    check(out.event and out.event.from == before and out.event.to == out.state, "a transition has its event")
                else
                    check(out.event == nil, "no event without a transition")
                end
                advance(p, out)
                table.insert(outs, { out = out, theta = p.theta, omega = p.omega })
            end
            return outs, m:status()
        end
        local first, first_status = script()
        local second, second_status = script()
        check(equal(first, second) and equal(first_status, second_status), "replay is bitwise identical")
        local names = {}
        for _, row in ipairs(first) do if row.out.event then names[row.out.event.name] = true end end
        check(names.entering and names.balancing and names.ended and names.idle, "the script visits every state")
        check(first_status.sequence > 4, "events are numbered in order")
    end)

    case("speed gates entry and narrows the hold", function()
        local m = Balance.new()
        m:step(flat({ speed = 0.5 }), H)
        check(m:step(held("manual", 0.5, { speed = 0.5 }), H).issue == "entry_speed_low", "too slow to enter")
        check(m:step(held("manual", 0.5, { speed = 4 }), H).issue == "neutral_required", "speeding up while held is late")
        local fast, up = balancing("manual")
        up.manual = 0.62
        local point = fast:settings().manual_balance_point
        for _ = 1, 60 do fast:step(up, H) end
        check(fast:status().target == point, "0.62 is inside the band at 4 m/s")
        local slow, slow_up = balancing("manual")
        slow_up.manual, slow_up.speed = 0.62, 1.2
        for _ = 1, 60 do slow:step(slow_up, H) end
        check(slow:status().target > point, "the band narrows at 1.2 m/s, so 0.62 climbs")
        local m2, p = Balance.new(), plant()
        m2:step(sample(p), H)
        for _ = 1, 120 do
            local out = m2:step(sample(p, 0.5), H)
            advance(p, out)
            if out.state == "balancing" then break end
        end
        local reason
        for _ = 1, 180 do
            local out = m2:step(sample(p, 0.5, 0, 0.1), H)
            advance(p, out)
            if out.event then reason = out.event.reason; break end
        end
        check(reason == "front_drop", "a stalled manual lets the front down")
    end)

    case("reverse travel rolls at its speed magnitude", function()
        -- speed is signed, and riding backwards is still rolling: entry, the
        -- hold band and the stall read its magnitude. The kinds, the wheels
        -- and the pitch signs still follow the bike, not the travel direction.
        local function lifted(kind, speed, pull)
            local manual = kind == "manual"
            local point = Balance.new():settings()[manual and "manual_balance_point" or "nose_balance_point"]
            return held(kind, pull, { pitch = (manual and 1 or -1) * point, front_support = not manual,
                rear_support = manual, speed = speed })
        end
        local function reach(kind, speed)
            local m = Balance.new()
            m:step(flat({ speed = speed }), H)
            check(m:step(held(kind, 0.5, { speed = speed }), H).state == "entering", "a rolling pull enters")
            for _ = 1, 30 do
                if m:step(lifted(kind, speed, 0.5), H).state == "balancing" then break end
            end
            check(m:status().state == "balancing", "and balances in either travel direction")
            return m
        end
        for _, kind in ipairs({ "manual", "nose_manual" }) do
            for _, magnitude in ipairs({ 0.5, 1, 4, 100 }) do
                local ahead, behind = Balance.new(), Balance.new()
                ahead:step(flat({ speed = magnitude }), H)
                behind:step(flat({ speed = -magnitude }), H)
                local a = ahead:step(held(kind, 0.5, { speed = magnitude }), H)
                local b = behind:step(held(kind, 0.5, { speed = -magnitude }), H)
                check(equal(a, b), "entry is the same in either travel direction")
                if magnitude < 1 then
                    check(b.issue == "entry_speed_low", "too slow backwards is still too slow")
                    check(behind:step(held(kind, 0.5, { speed = -4 }), H).issue == "neutral_required",
                        "a reverse refusal still consumes the arm")
                else
                    check(b.state == "entering" and b.kind == kind, "min_entry_speed is inclusive backwards too")
                end
            end
            local point = Balance.new():settings()[kind == "manual" and "manual_balance_point" or "nose_balance_point"]
            for _, magnitude in ipairs({ 0, 0.3, 1.2, 4, 100 }) do
                local ahead, behind = reach(kind, 4), reach(kind, -4)
                for _ = 1, 40 do
                    local a = ahead:step(lifted(kind, magnitude, 0.62), H)
                    local b = behind:step(lifted(kind, -magnitude, 0.62), H)
                    check(equal(a, b) and equal(ahead:status(), behind:status()),
                        "the band, the stall and the command match in either direction")
                end
                local target = behind:status().target
                if magnitude >= 4 then check(target == point, "0.62 holds backwards at 4 m/s and up")
                elseif magnitude >= 1 then check(target > point, "the band narrows backwards at 1.2 m/s, so 0.62 climbs")
                else check(target < point, "a reverse crawl stalls the lift down") end
            end
        end
        check(Balance.new():step(flat({ speed = -100 }), H).valid, "-100 m/s is still a valid speed")
        for _, speed in ipairs({ -100.001, -1e9, -math.huge, 0 / 0 }) do
            local out = Balance.new():step(flat({ speed = speed }), H)
            check(not out.valid and out.issue == "invalid_sample", "an out-of-range reverse speed is refused")
        end
    end)

    case("a bump is rejected without an end", function()
        local m, p = Balance.new(), plant()
        local point = m:settings().manual_balance_point
        m:step(sample(p), H)
        for n = 1, 420 do
            if n == 200 then p.omega = p.omega + 0.6 end
            local out = m:step(sample(p, 0.5), H)
            advance(p, out)
            if n > 200 then check(out.event == nil and out.state == "balancing", "the bump does not end the manual") end
        end
        check(math.abs(p.theta - point) <= 0.01, "the closed loop returns to the point")
    end)

    case("measure reads pitch and pitch rate", function()
        local angle = 0.25
        local q = { -math.sin(angle * 0.5), 0, 0, math.cos(angle * 0.5) }
        local pitch, rate = Balance.measure(q, { -0.7, 0, 0 }, { 0, 1, 0 })
        check(near(pitch, angle, 1e-9) and near(rate, 0.7, 1e-9), "nose up about rider-left is positive")
        pitch, rate = Balance.measure({ 0, 0, 0, 1 }, { 0.4, 2, 0 })
        check(near(pitch, 0, 1e-12) and near(rate, -0.4, 1e-12), "yaw is not pitch; the default normal is world up")
        check(Balance.measure({ 0, 0, 0, 2 }, { 0, 0, 0 }) == nil, "a non-unit orientation is refused")
        check(Balance.measure({ 0, 0, 0, 1 }, { 0, 0 / 0, 0 }) == nil, "a non-finite rate is refused")
        check(Balance.measure({ 0, 0, 0, 1 }, { 0, 0, 0 }, { 0, 0, 1 }) == nil, "a forward-facing normal is degenerate")
        check(Balance.measure({ 0, 0, 0, 1 }, { 0, 0, 0 }, { 0, 0, 0 }) == nil, "a zero normal is degenerate")
    end)

    case("input.lua actions drive the model", function()
        local mapper, m = Input.new(), Balance.new()
        local settings = mapper:settings()
        local neutral = settings.deadzone + (1 - settings.deadzone) * settings.neutral_threshold
        local function feed(y, grounded, changes)
            local a = mapper:update(Input.raw({ available = true, device = 7, right_y = y }), { grounded = grounded }, H)
            local s = flat({ manual = a.manual, nose_manual = a.nose_manual, preload = a.preload, hop = a.hop_pressed,
                rear_neutral = math.abs(y) <= neutral, front_support = grounded, rear_support = grounded })
            for key, value in pairs(changes or {}) do s[key] = value end
            return m:step(s, H)
        end
        feed(0, true)
        local out = feed(-0.55, true)
        check(out.event and out.event.name == "entering" and out.kind == "manual", "input.lua manual enters")
        for _ = 1, 30 do
            out = feed(-0.55, true, { pitch = 0.2, front_support = false })
            if out.state ~= "entering" then break end
        end
        check(out.state == "balancing", "the lifted front balances")
        out = feed(-1, true, { pitch = 0.2, front_support = false })
        check(out.state == "balancing" and out.manual > 0, "a hop charge from the manual holds the lift")
        out = feed(1, true, { pitch = 0.2, front_support = false })
        check(out.event and out.event.reason == "hop_out", "the flick ends the manual as a hop")
        check(feed(1, true).issue == "neutral_required", "rear_neutral keeps a held flick from rearming")
        feed(0, true)
        check(feed(0.55, true).kind == "nose_manual", "input.lua nose manual enters after neutral")
        for _ = 1, 4 do out = feed(0.55, false) end
        check(m:status().end_reason == "airborne", "takeoff ends the nose manual")
        check(feed(0.55, true).state == "ended", "the stick held through landing stays ended")
        feed(0, true)
        check(feed(-0.55, true).state == "entering", "landing neutral rearms through input.lua")
    end)

    return { cases = cases, assertions = assertions, native_actions = 0 }
end

return Tests

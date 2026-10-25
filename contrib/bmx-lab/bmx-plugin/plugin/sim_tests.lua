-- Pure Luau cases for sim_world.lua and sim_scenarios.lua. Nothing runs on
-- require; call require("./sim_tests").run(progress) from a Luau runner. The
-- heightfield, scripts and simulator are constructed test tooling around the
-- actual input.lua and forces.lua modules: passing here is not in-game or
-- native evidence, and BASELINE below is a record of today's model, not a target.
local World = require("./sim_world")
local Scenarios = require("./sim_scenarios")
local Forces = require("./forces")
local Input = require("./input")
local Mapping = require("./ride_input_mapping")
local M = require("./force_math")
local Tests = {}
local H = Forces.native_seconds

-- Recorded from this source with forces.lua's default tuning. It exists so a
-- change to the force, input or simulator modules shows up as a diff to
-- review. When a change is intended, re-record it; never tune toward it, and
-- never fill it from standalone/reference or any BMX Streets extraction.
local BASELINE = {
    S01 = {
        flat = {
            accel = {
                distance = 34.663465353186531,
                lateral_drift = 0,
                max_abs_lean = 0,
                seconds = 5.9999996423721313,
                time_to_3 = 1.1999999284744263,
                time_to_6 = 2.3833331912755966,
                time_to_7_5 = 3.4666664600372314,
                top_speed = 7.9807029979194484,
            },
            brake = {
                distance = 8.9216737099854058,
                lateral_drift = 0,
                mean_deceleration = 3.5430986004703562,
                peak_deceleration = 3.5430986005621552,
                seconds = 2.2499998658895493,
                speed_start = 7.9807000597473472,
                stopped = true,
            },
            coast = {
                distance = 23.942101025982701,
                energy_change = 0.034719936104920635,
                seconds = 2.9999998211860657,
                speed_change = -2.9381721011745299e-06,
                speed_end = 7.9807000597473472,
                speed_start = 7.9807029979194484,
            },
            issue = "none",
            rest = {
                creep_distance = 0.0043643416641856447,
                speed_end = 0.0087286838486119924,
            },
            restart = {
                distance = 5.121006446857379,
                speed_end = 5.0702978113671122,
                speed_start = 0.0087286838486119924,
            },
            steps = 826,
            valid = true,
        },
    },
    S02 = {
        left_3 = {
            hold_energy_change = 8.5926929420927536,
            hold_speed_change = 0.015413931846346873,
            issue = "none",
            mean_lean = 0.18275363657026181,
            mean_speed = 3.0378809192421543,
            radius = 3.2169336014513221,
            release_heading_change = 0.13974668497377429,
            release_lean = 0.03312020872346879,
            release_settle_seconds = 0.44999997317790985,
            release_settled = true,
            speed_start = 3,
            steer = -1,
            steering_limited_fraction = 0,
            valid = true,
            yaw_rate = 0.94434057260977144,
        },
        left_6 = {
            hold_energy_change = 18.971566352684476,
            hold_speed_change = 0.053095046121460321,
            issue = "none",
            mean_lean = 0.29424699290512601,
            mean_speed = 6.0885533804135346,
            radius = 7.1257497251396362,
            release_heading_change = 0.12168670340072785,
            release_lean = 0.038980649320098308,
            release_settle_seconds = 0.41666664183139801,
            release_settled = true,
            speed_start = 6,
            steer = -1,
            steering_limited_fraction = 1,
            valid = true,
            yaw_rate = 0.85444389927604703,
        },
        right_3 = {
            hold_energy_change = 8.5926929420927536,
            hold_speed_change = 0.015413931846346873,
            issue = "none",
            mean_lean = -0.18275363657026181,
            mean_speed = 3.0378809192421543,
            radius = 3.2169336014513221,
            release_heading_change = -0.13974668497377429,
            release_lean = -0.03312020872346879,
            release_settle_seconds = 0.44999997317790985,
            release_settled = true,
            speed_start = 3,
            steer = 1,
            steering_limited_fraction = 0,
            valid = true,
            yaw_rate = -0.94434057260977144,
        },
        right_6 = {
            hold_energy_change = 18.971566352684476,
            hold_speed_change = 0.053095046121460321,
            issue = "none",
            mean_lean = -0.29424699290512601,
            mean_speed = 6.0885533804135346,
            radius = 7.1257497251396362,
            release_heading_change = -0.12168670340072785,
            release_lean = -0.038980649320098308,
            release_settle_seconds = 0.41666664183139801,
            release_settled = true,
            speed_start = 6,
            steer = 1,
            steering_limited_fraction = 1,
            valid = true,
            yaw_rate = -0.85444389927604703,
        },
    },
    S04 = {
        speed_3 = {
            energy_change = -67.205405095910919,
            furthest_z = 3.8074673697291583,
            ideal_rise = 0.48797489537613337,
            issue = "none",
            max_pitch = 0.27041591404864007,
            peak_rise = 0.44898271169216208,
            peak_seconds = 1.9333332180976868,
            return_ratio = 0.93136277381906873,
            return_speed = -2.7940883214572061,
            rise_ratio = 0.9200938735712707,
            rolled_back = true,
            seconds = 3.9166664332151413,
            speed_start = 3,
            valid = true,
        },
        speed_6 = {
            energy_change = -149.48689623900555,
            furthest_z = 9.2437578461750949,
            ideal_rise = 1.9518995815045335,
            issue = "none",
            max_pitch = 0.3258554910795492,
            peak_rise = 1.9056330159774268,
            peak_seconds = 2.8499998301267624,
            return_ratio = 0.96252395366513566,
            return_speed = -5.7751437219908137,
            rise_ratio = 0.97629664662797655,
            rolled_back = true,
            seconds = 5.6999996602535248,
            speed_start = 6,
            valid = true,
        },
    },
    S05 = {
        full_charge_flick = {
            air_distance = 3.5333331227223583,
            airtime = 0.88333328068256378,
            apex_clearance = 0.99599998747779872,
            apex_rise = 0.99600000199229888,
            first_contact = "both",
            hop_applied = true,
            hop_strength = 1,
            impact_to_support = 0.01666666567325592,
            input_to_hop = 0.29999998211860657,
            issue = "none",
            landed = true,
            landing_min_separation = -1.5638803585460437e-09,
            landing_pitch = -5.7168883395398768e-09,
            landing_vertical_speed = -4.3199994742307037,
            left_contact_gap = true,
            speed_after = 3.9999999999906923,
            takeoff_vertical_speed = 4.3366666764584254,
            valid = true,
        },
        gap_no_hop = {
            front_hub_z = 5.5298767184975359,
            front_status = "unavailable",
            hop_applied = false,
            issue = "unavailable_contact",
            seconds = 1.049999937415123,
            valid = false,
        },
        gap_r3 = {
            air_distance = 4.4166664033930587,
            airtime = 0.88333328068256378,
            apex_clearance = 1.994777769345095,
            apex_rise = 0.99600000205997752,
            cleared = true,
            first_contact = "both",
            hop_applied = true,
            hop_strength = 1,
            impact_to_support = 0.01666666567325592,
            issue = "none",
            landed = true,
            landing_min_separation = -1.5693585320164516e-09,
            landing_pitch = -5.4720316271385364e-09,
            landing_rear_past_far = 0.75087546009132566,
            landing_vertical_speed = -4.3199994740803058,
            left_contact_gap = true,
            speed_after = 4.9999999999906812,
            takeoff_front_to_edge = 1.4008760675126126,
            takeoff_vertical_speed = 4.3366666766088233,
            valid = true,
        },
        minimum_flick = {
            air_distance = 0.73333328960777755,
            airtime = 0.18333332240581512,
            apex_clearance = 0.055333330228514943,
            apex_rise = 0.055333333531863205,
            first_contact = "both",
            hop_applied = true,
            hop_strength = 0.25,
            impact_to_support = 0.01666666567325592,
            input_to_hop = 0.01666666567325592,
            issue = "none",
            landed = true,
            landing_min_separation = -3.5356761962646033e-10,
            landing_pitch = -5.9835835848566597e-08,
            landing_vertical_speed = -0.83499988228234789,
            left_contact_gap = true,
            speed_after = 3.9999999999938627,
            takeoff_vertical_speed = 0.96166667729464028,
            valid = true,
        },
        r3_quick_hop = {
            air_distance = 3.5333331226429818,
            airtime = 0.88333328068256378,
            apex_clearance = 0.99599998753703178,
            apex_rise = 0.99600000243947495,
            first_contact = "both",
            hop_applied = true,
            hop_strength = 1,
            impact_to_support = 0.01666666567325592,
            input_to_hop = 0,
            issue = "none",
            landed = true,
            landing_min_separation = -1.6005293757004324e-09,
            landing_pitch = -4.0787718303060064e-09,
            landing_vertical_speed = -4.3199994732369795,
            left_contact_gap = true,
            speed_after = 3.9999999999905653,
            takeoff_vertical_speed = 4.3366666774521496,
            valid = true,
        },
    },
    S06 = {
        speed_2 = {
            airborne_seconds = 0,
            drop_potential = 311.64000000000004,
            energy_loss = 311.65226555894856,
            first_landing = "front",
            front_to_rear_landing = 0.29999998211860657,
            issue = "none",
            max_drop_speed = 0.7629974274935365,
            min_pitch = -0.32797921076077469,
            min_separation = -0.00017211648200410323,
            settle_seconds = 0.24999998509883881,
            speed_end = 2.0000080751827967,
            speed_start = 2,
            valid = true,
        },
        speed_5 = {
            airborne_seconds = 0.18333332240581512,
            drop_potential = 311.64000000000004,
            energy_loss = 311.64013805315835,
            first_landing = "front",
            front_to_rear_landing = 0.14999999105930328,
            issue = "none",
            max_drop_speed = 1.6976809383590812,
            min_pitch = -0.22720498615969792,
            min_separation = -0.00407872551964783,
            settle_seconds = 0.28333331644535065,
            speed_end = 5.0000000690944555,
            speed_start = 5,
            valid = true,
        },
    },
    S07 = {
        manual_060 = {
            base_supported_fraction = 1,
            control = 0.65090909090909088,
            hold_lift_pitch = -7.5493229015089174e-08,
            hold_speed_change = 8.9535046043920374e-11,
            issue = "none",
            lifted = false,
            lifted_at_release = false,
            lifted_fraction = 0,
            max_lift_clearance = 0,
            peak_lift_pitch = 0,
            release_drop_seconds = 0,
            release_dropped = false,
            time_to_lift = 1.9999998807907104,
            valid = true,
        },
        manual_070 = {
            base_supported_fraction = 1,
            control = 0.87818181818181817,
            hold_lift_pitch = 0.13972167973304483,
            hold_speed_change = -1.3354805664000935e-05,
            issue = "none",
            lifted = true,
            lifted_at_release = true,
            lifted_fraction = 0.92500000000000004,
            max_lift_clearance = 0.13001141806455041,
            peak_lift_pitch = 0.14002765512223986,
            release_drop_seconds = 0.19999998807907104,
            release_dropped = true,
            time_to_lift = 0.1666666567325592,
            valid = true,
        },
        manual_075 = {
            base_supported_fraction = 1,
            control = 0.99181818181818193,
            hold_lift_pitch = 0.22380454391732668,
            hold_speed_change = -3.559115937745716e-05,
            issue = "none",
            lifted = true,
            lifted_at_release = true,
            lifted_fraction = 0.94166666666666665,
            max_lift_clearance = 0.20737951323874138,
            peak_lift_pitch = 0.22451855356863315,
            release_drop_seconds = 0.24999998509883881,
            release_dropped = true,
            time_to_lift = 0.13333332538604736,
            valid = true,
        },
        nose_075 = {
            base_supported_fraction = 1,
            control = 0.99181818181818193,
            hold_lift_pitch = 0.10094305519112208,
            hold_speed_change = -1.4868272977253127e-06,
            issue = "none",
            lifted = true,
            lifted_at_release = true,
            lifted_fraction = 0.89166666666666672,
            max_lift_clearance = 0.093918187292504007,
            peak_lift_pitch = 0.1009876393143143,
            release_drop_seconds = 0.1666666567325592,
            release_dropped = true,
            time_to_lift = 0.23333331942558289,
            valid = true,
        },
    },
    h = 0.01666666567325592,
    version = 1,
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, child in pairs(value) do out[key] = copy(child) end
    return out
end
-- ride_input_mapping identities are decimal u64 strings.
local function increment(value)
    local out, carry = {}, 1
    for at = #value, 1, -1 do
        local n = string.byte(value, at) - 48 + carry
        if n == 10 then n, carry = 0, 1 else carry = 0 end
        table.insert(out, 1, string.char(48 + n))
    end
    if carry == 1 then table.insert(out, 1, "1") end
    return table.concat(out)
end
local function count(t)
    local n = 0
    for _ in pairs(t) do n += 1 end
    return n
end

function Tests.run(progress)
    local cases, assertions = 0, 0
    local function check(condition, message)
        assertions += 1
        assert(condition, message)
    end
    local function near(a, b, tolerance) return math.abs(a - b) <= (tolerance or 1e-12) end
    local function tick() if type(progress) == "function" then progress(cases, assertions) end end
    -- Luau's os.clock is a wall clock, so a chunk preempted by another
    -- process counts the time that process held the core. Chunk times are
    -- collected for the result and only their median is asserted.
    local clock = os and os.clock
    local chunks, times, timing = 0, {}, nil
    local last_chunk
    local function case(name, body)
        cases += 1
        last_chunk = clock and clock() or nil
        local ok, why = pcall(body)
        if not ok then error(name .. ": " .. tostring(why), 0) end
        tick()
    end
    local function chunk()
        chunks += 1
        if clock then
            local now = clock()
            if last_chunk then table.insert(times, (now - last_chunk) * 1000) end
            last_chunk = now
        end
        tick()
    end
    -- Scenarios.run's progress(id, steps), logged so the budget case can
    -- check the native steps between calls exactly.
    local function logger(log)
        return function(id, steps)
            chunk()
            table.insert(log, { id, steps })
        end
    end
    -- A coast after pedalling starts with the rear tyre slightly inside its
    -- contact gap, and the kernel's recovery bias lifts the COM back out.
    -- That lift is the only energy such a coast may gain: kinetic energy
    -- (body, rotation, rotors) must not rise, the COM must not rise above the
    -- placed ride height, and the gain is at most m g times the height
    -- recovered. `before` is the record of the last step before the coast.
    local function recovery_bounded(records, before, placed_y, weight, label)
        local function kinetic(r) return r.energy - weight * r.position[2] end
        local top = -math.huge
        for _, r in ipairs(records) do top = math.max(top, r.position[2]) end
        local last = records[#records]
        check(records[1].energy_before == before.energy, label .. ": the coast starts from the pedalled state")
        check(kinetic(last) <= kinetic(before) + 1e-6, label .. ": kinetic energy does not rise")
        check(top <= placed_y + 1e-6, label .. ": the COM stays at or below the placed ride height")
        local gain = last.energy - records[1].energy_before
        check(gain <= weight * (placed_y - before.position[2]) + 1e-6, label .. ": the gain is at most the recovery lift")
        return gain
    end
    local first_log, repeat_log = {}, {}

    case("inert modules", function()
        -- Every table reachable from either module is shared module state.
        local seen = {}
        local function frozen(t, path)
            if seen[t] then return end
            seen[t] = true
            check(table.isfrozen(t), "frozen " .. path)
            for key, value in pairs(t) do
                if type(value) == "table" then frozen(value, path .. "." .. tostring(key)) end
            end
        end
        frozen(World, "World")
        frozen(Scenarios, "Scenarios")
        check(seen[World.terrain] and seen[Scenarios.order] and seen[World.front_hub] and seen[Scenarios.titles],
            "the walk reached the terrain kinds, the scenario order, the hub offsets and the titles")
        check(not pcall(function() World.terrain.flat = World.terrain.gap end), "a caller cannot swap a terrain kind")
        check(not pcall(table.insert, Scenarios.order, "S99"), "a caller cannot add a scenario")
        check(World.h == Forces.native_seconds, "the world steps at forces.lua's only accepted interval")
        check(World.wheel_radius == Forces.wheel_radius, "the query radius is the kernel's wheel radius")
        check(#Scenarios.order == 6 and Scenarios.chunk_steps == 4, "six rubric scenarios, four steps a chunk")
        for _, id in ipairs(Scenarios.order) do check(type(Scenarios.titles[id]) == "string", "every scenario is titled " .. id) end
        local runner = Scenarios.runner("S05")
        check(runner.steps == 0 and not runner.finished and runner.current == nil, "a new runner has not stepped or built a world")
        check(not pcall(Scenarios.runner, "S99"), "an unknown scenario id is refused")
    end)

    case("terrain profiles", function()
        local T = World.terrain
        local flat = T.flat()
        check(flat.height(-100) == 0 and flat.height(100) == 0 and flat.slope(3) == 0, "flat ground is level everywhere")
        local ramp = T.ramp({ start_z = 2, angle = math.rad(15), blend = .5, top = 3 })
        local k = math.tan(math.rad(15))
        check(ramp.height(2) == 0 and ramp.slope(2) == 0, "the ramp foot meets the ground level and flat")
        check(near(ramp.height(2.5), k * .25, 1e-12) and near(ramp.slope(2.5), k, 1e-12), "the foot blend ends on the ramp line")
        check(near(ramp.height(4), k * 1.75, 1e-12) and ramp.slope(4) == k, "the face is the authored 15 degree line")
        local lip = ramp.parameters.lip_z
        check(near(ramp.height(lip), 3, 1e-12) and near(ramp.slope(lip), 0, 1e-12) and ramp.height(lip + 1) == 3, "the lip blend levels onto the deck")
        for z = 1.9, lip + .1, .01 do
            check(math.abs(ramp.height(z + .001) - ramp.height(z) - ramp.slope(z) * .001) < 1e-4, "height and slope agree at z=" .. z)
        end
        local ledge = T.ledge({ edge_z = 1.5, height = .3 })
        check(ledge.height(1.4999) == .3 and ledge.height(1.5) == 0, "the ledge drops 0.3 m at its edge")
        local gap = T.gap({ near_z = 4, far_z = 5.5, depth = 1 })
        check(gap.height(3.99) == 0 and gap.height(4) == -1 and gap.height(5.49) == -1 and gap.height(5.5) == 0, "the gap is a 1.5 m pit 1 m deep")
        check(not pcall(T.gap, { near_z = 2, far_z = 1 }) and not pcall(T.ramp, { blend = 0 }), "degenerate shapes are refused")
        local status, point, normal = World.ray(ramp, { 0, 2, 4 }, 2)
        check(status == "hit" and near(point[2], k * 1.75, 1e-12) and near(normal[2], math.cos(math.rad(15)), 1e-12)
            and near(normal[3], -math.sin(math.rad(15)), 1e-12), "a ray finds the ramp face and its tilted normal")
        check(World.ray(flat, { 0, 1, 0 }, .5) == "clear", "a ray that ends above the ground is clear")
        check(World.ray(ledge, { 0, .2, 1 }, 1) == "inside", "a start under the deck surface is not a hit")
    end)

    case("contact rows follow the forces.lua call contract", function()
        local body = World.place(World.terrain.flat(), { speed = 3 })
        local tuning = Forces.tuning()
        local samples, info, available = World.contacts(World.terrain.flat(), body, tuning.gravity)
        check(available and #samples == 2, "two wheel rows, front then rear")
        for i = 1, 2 do
            local s, c = samples[i], samples[i].contact
            check(c.status == "hit" and M.vec(c.point) and M.vec(c.normal) and M.vec(c.forward) and M.vec(c.surface_velocity),
                "a hit carries finite point, normal, forward and surface velocity " .. i)
            check(near(c.normal[2], 1) and near(c.forward[3], 1) and c.surface_velocity[1] == 0 and c.surface_velocity[3] == 0,
                "flat ground: up normal, body-forward tangent, static surface " .. i)
            check(math.abs(s.separation) < 1e-4 and s.verified_plane == false and s.balance_normal_available == false,
                "placed tyres touch; no verified plane or balance normal is claimed " .. i)
            check(World.supported(body, s, tuning) and info[i].supported == nil, "a touching tyre is eligible support " .. i)
        end
        local front = World.hubs(body)[1]
        check(near(samples[1].contact.point[3], front[3], 1e-12) and samples[1].contact.point[2] == 0, "the front row is below the front hub")
        -- Lift the bike above the probe: honest clear rows carry nothing else.
        local high = copy(body) high.center_of_mass[2] += 1
        local clear = World.contacts(World.terrain.flat(), high, tuning.gravity)
        for i = 1, 2 do
            check(count(clear[i]) == 1 and count(clear[i].contact) == 1 and clear[i].contact.status == "clear",
                "a clear row is exactly {contact={status=\"clear\"}} " .. i)
        end
        local before = copy(clear)
        local result = Forces.new():step(H, high, Forces.proposed_wheels(), clear, Forces.controls())
        check(result.valid and not result.grounded and result.normal_impulse[1] == 0 and result.normal_impulse[2] == 0,
            "clear rows contribute no support or tyre impulse")
        for i = 1, 2 do check(count(clear[i]) == 1 and count(clear[i].contact) == count(before[i].contact), "the kernel leaves clear rows clear " .. i) end
        -- On the 15 degree face, separation is measured along the face normal.
        local ramp = World.terrain.ramp({ start_z = 0, angle = math.rad(15), blend = .5, top = 3 })
        -- A level bike placed on the face touches with the uphill front tyre.
        local on = World.place(ramp, { z = 3 })
        local rows = World.contacts(ramp, on, tuning.gravity)
        local hub = World.hubs(on)[1]
        local n = rows[1].contact.normal
        check(near(n[2], math.cos(math.rad(15)), 1e-9) and near(rows[1].separation,
            M.dot(M.sub(hub, rows[1].contact.point), n) - World.wheel_radius, 1e-12)
            and near(rows[1].separation, World.wheel_radius * (math.cos(math.rad(15)) - 1), 1e-9),
            "ramp rows use the ride_runtime separation along the face normal")
        -- A hub driven under the gap's far wall has no honest row at all.
        local gap = World.terrain.gap({ near_z = 4, far_z = 5.5, depth = 1 })
        local sunk = World.place(gap, { z = 5 })
        sunk.center_of_mass = { 0, .5, 5.3 }
        local wall, _, ok = World.contacts(gap, sunk, tuning.gravity)
        check(not ok and wall[1].contact.status == "unavailable", "a hub inside the far wall is an unavailable query")
    end)

    case("rigid-body integrator", function()
        local g = Forces.tuning().gravity
        local still = { force = { 0, 0, 0 }, torque = { 0, 0, 0 }, hop_impulse = { 0, 0, 0 } }
        local body = Forces.proposed_body()
        body.linear_velocity = { 0, 2, 3 }
        local p0 = copy(body.center_of_mass)
        local b = body
        for _ = 1, 30 do b = World.integrate(b, still, g, H) end
        local n = 30
        check(near(b.linear_velocity[2], 2 + n * g[2] * H, 1e-12) and b.linear_velocity[3] == 3, "gravity is added once per step")
        check(near(b.center_of_mass[2], p0[2] + n * H * 2 + g[2] * H * H * n * (n + 1) / 2, 1e-12)
            and near(b.center_of_mass[3], p0[3] + n * H * 3, 1e-12), "position advances with the new velocity (semi-implicit Euler)")
        check(body.linear_velocity[2] == 2 and body.center_of_mass[2] == p0[2], "integration never mutates its input body")
        -- Inertia comes from the body table, at the step's orientation.
        local spun = World.integrate(Forces.proposed_body(), { force = { 0, 0, 0 }, torque = { 26, 32, 10 }, hop_impulse = { 0, 0, 0 } }, g, H)
        for i = 1, 3 do check(near(spun.angular_velocity[i], H, 1e-15), "proposed inertia gives unit response on axis " .. i) end
        local light = Forces.proposed_body() light.inertia_body = { 13, 32, 10 }
        local lighter = World.integrate(light, { force = { 0, 0, 0 }, torque = { 26, 0, 0 }, hop_impulse = { 0, 0, 0 } }, g, H)
        check(near(lighter.angular_velocity[1], 2 * H, 1e-15), "halving a body moment doubles that axis response")
        local turned = Forces.proposed_body() turned.orientation = { 0, math.sin(math.pi / 4), 0, math.cos(math.pi / 4) }
        local world_x = World.integrate(turned, { force = { 0, 0, 0 }, torque = { 26, 0, 0 }, hop_impulse = { 0, 0, 0 } }, g, H)
        check(near(world_x.angular_velocity[1], 2.6 * H, 1e-12) and near(world_x.angular_velocity[3], 0, 1e-12),
            "a yawed body answers world X with its own Z moment")
        -- The hop impulse acts once and is not folded into the force.
        local hopped = World.integrate(Forces.proposed_body(), { force = { 0, 0, 0 }, torque = { 0, 0, 0 }, hop_impulse = { 0, 106 * 4.5, 0 } }, g, H)
        check(near(hopped.linear_velocity[2], 4.5 + g[2] * H, 1e-12), "a hop impulse changes velocity by J/m once")
        -- The orientation turns by exactly |omega| h each step.
        local yawing = Forces.proposed_body() yawing.angular_velocity = { 0, 1, 0 }
        for _ = 1, 60 do yawing = World.integrate(yawing, still, g, H) end
        local yaw = World.attitude(yawing)
        check(near(yaw, 60 * H, 1e-12) and near(M.length({ yawing.orientation[1], yawing.orientation[2], yawing.orientation[3] }) ^ 2
            + yawing.orientation[4] ^ 2, 1, 1e-12), "sixty steps at 1 rad/s turn 60h radians and stay unit")
        -- Through the whole step: clear air at neutral input is ballistic.
        local sim = World.new()
        sim.body.center_of_mass, sim.body.linear_velocity = { 0, 5, 0 }, { 0, 2, 3 }
        for _ = 1, 20 do check(not sim:step({}).grounded, "the raised body stays in clear air") end
        local s = sim:state()
        check(near(s.body.center_of_mass[2], 5 + 20 * H * 2 + g[2] * H * H * 20 * 21 / 2, 1e-12)
            and near(s.body.center_of_mass[3], 20 * H * 3, 1e-12), "kernel plus integrator in clear air follow the closed form")
    end)

    case("controls mirror ride_input_mapping", function()
        local settings = Input.new():settings()
        local f = { mapping = Mapping.new(), serial = "9007199254741001", ms = "9007199254742000", handle = newproxy() }
        local function pad(changes)
            local p = { left_x = 0, left_y = 0, right_x = 0, right_y = 0, left_trigger = 0, right_trigger = 0,
                playstation = false, buttons = { a = false, b = false, right_stick = false, lb = false, rb = false } }
            for key, value in pairs(changes or {}) do
                if key == "buttons" then for name, pressed in pairs(value) do p.buttons[name] = pressed end else p[key] = value end
            end
            return p
        end
        local compared, with_hop, airborne = 0, 0, 0
        local function observe(p, grounded, rotation)
            f.serial = increment(f.serial)
            for _ = 1, 16 do f.ms = increment(f.ms) end
            local context = { grounded = grounded, focused = true, menu_open = false, rotation_reserved = rotation }
            f.mapping:observe({ input_ok = true, lease_handle = f.handle, generation = 1, sample = { pad = copy(p), user = 2,
                sequence = "9007199254740995", source_epoch = "9007199254741009", context_generation = "9007199254741011",
                observation_serial = f.serial, observed_ms = f.ms, packet = 17 } }, context)
            local theirs = f.mapping:controls({ physics_epoch = newproxy(), h = H, grounded = grounded, rotation_reserved = rotation })
            if not theirs.valid then return nil end
            local status = f.mapping:status()
            local b = p.buttons
            local raw = Input.raw({ available = true, device = 2, left_x = p.left_x, left_y = p.left_y, right_x = p.right_x,
                right_y = p.right_y, left_trigger = p.left_trigger, right_trigger = p.right_trigger, left_shoulder = b.lb,
                right_shoulder = b.rb, pedal = b.a and 1 or 0, brake = b.b and 1 or 0, quick_hop = b.right_stick })
            local mine = World.controls(settings, status.actions, raw, status.pending_hop, grounded, rotation)
            check(count(mine) == count(theirs.force_controls), "the same control fields")
            for key, value in pairs(theirs.force_controls) do check(mine[key] == value, "control " .. key .. " matches the mapping") end
            compared += 1
            if status.pending_hop then with_hop += 1 end
            if not grounded then airborne += 1 end
            return status
        end
        observe(pad(), true, false)
        observe(pad(), true, false)
        observe(pad({ buttons = { a = true } }), true, false)
        observe(pad({ buttons = { b = true } }), true, false)
        observe(pad({ left_x = .8, left_y = -.5 }), true, false)
        observe(pad(), true, false)
        observe(pad({ right_y = -.6 }), true, false)
        observe(pad(), true, false)
        for _ = 1, 4 do observe(pad({ right_y = -1 }), true, false) end
        local flicked = observe(pad({ right_y = 1 }), true, false)
        check(flicked and flicked.pending_hop and flicked.pending_hop.strength > 0, "a flick leaves a pending hop to compare")
        f.mapping:retire_hop(flicked.pending_hop.id, "accepted")
        observe(pad(), true, false)
        observe(pad({ buttons = { right_stick = true } }), true, true)
        local status = f.mapping:status()
        if status.pending_hop then f.mapping:retire_hop(status.pending_hop.id, "accepted") end
        observe(pad({ left_trigger = .6, buttons = { lb = true } }), true, false)
        observe(pad(), false, false)
        observe(pad({ left_y = .9 }), false, false)
        observe(pad({ left_y = -.9, left_x = .4 }), false, false)
        check(compared >= 12 and with_hop >= 2 and airborne >= 2, "grounded, hop and airborne control rows were all compared")
    end)

    case("input drives the kernel", function()
        local sim = World.new({ speed = 4 })
        local first_step = sim:step({})
        check(first_step.valid and first_step.input_active and first_step.grounded, "a neutral first sample opens input.lua's gate")
        local hop = sim:step({ quick_hop = true })
        check(hop.hop_pressed and hop.hop_applied and hop.hop_strength == 1 and sim.controller:consumed_hop_event_id() == 1,
            "R3 becomes hop event 1, consumed and applied by forces.lua")
        local again = sim:step({ quick_hop = true })
        check(not again.hop_pressed and not again.hop_applied, "a held R3 is one event, not a stream")
        check(again.velocity[2] > 4, "the hop leaves the ground at the kernel's hop speed")
        local gated = World.new()
        local refused = gated:step({ pedal = 1 })
        check(not refused.input_active and refused.valid and refused.pedal == 0, "a held trigger before neutral is gated, support is passive")
        local rolling = World.new()
        rolling:step({})
        for _ = 1, 30 do rolling:step({ pedal = 1 }) end
        check(rolling:state().body.linear_velocity[3] > .5, "the pedal moves the bike forward through the real mapper and kernel")
        local pit = World.new({ speed = 5, terrain = World.terrain.gap({ near_z = 1.5, far_z = 3, depth = 1 }) })
        local stop
        for _ = 1, 120 do stop = pit:step({}) if not stop.valid then break end end
        check(not stop.valid and stop.issue == "unavailable_contact" and pit:state().stopped, "an unanswerable query stops the run")
        check(not pcall(pit.step, pit, {}), "a stopped simulation refuses to integrate further")
    end)

    case("no energy gain while coasting on flat ground", function()
        for _, speed in ipairs({ 0, 1, 4, 8 }) do
            local sim = World.new({ speed = speed })
            local start, gain, worst
            for i = 1, 120 do
                local r = sim:step({})
                check(r.valid and r.grounded, "coasting stays supported at " .. speed)
                start = start or r.energy_before
                worst = math.max(worst or -math.huge, r.energy - r.energy_before)
                gain = r.energy - start
                if i % Scenarios.chunk_steps == 0 then chunk() end
            end
            -- Per-step float noise is about 1e-7 J against 900-4600 J totals.
            check(gain <= 0 and worst <= 1e-6, "coasting at " .. speed .. " m/s never gains energy")
        end
        -- Half a second of pedal squats the rear tyre about 5 mm, so the
        -- recovery lift is about 3 J: large enough that an energy leak in
        -- the coast would not hide inside the bound.
        local sim = World.new()
        local placed_y = sim:state().body.center_of_mass[2]
        local weight = sim.body.mass * -sim.tuning.gravity[2]
        local before = sim:step({})
        for _ = 1, 30 do before = sim:step({ pedal = 1 }) end
        check(before.rear.separation < -1e-3, "the pedal squat leaves the rear tyre inside its contact gap")
        local records = {}
        for i = 1, 120 do
            table.insert(records, sim:step({}))
            if i % Scenarios.chunk_steps == 0 then chunk() end
        end
        local gain = recovery_bounded(records, before, placed_y, weight, "coast after 0.5 s of pedal")
        check(gain > 1, "the recovery lift is measured, not vacuous")
    end)

    local metrics, runners, repeat_runners
    case("scenario metrics are finite and frozen", function()
        metrics, runners = Scenarios.run(logger(first_log))
        check(table.isfrozen(metrics) and table.isfrozen(metrics.S05) and table.isfrozen(metrics.S05.r3_quick_hop), "the metrics table is frozen")
        local numbers = 0
        local function walk(value, path)
            if type(value) == "table" then
                for key, child in pairs(value) do walk(child, path .. "." .. tostring(key)) end
            elseif type(value) == "number" then
                numbers += 1
                check(M.finite(value), "finite " .. path)
            else
                check(type(value) == "boolean" or type(value) == "string", "plain value " .. path)
            end
        end
        walk(metrics, "metrics")
        check(numbers > 150, "the metrics table carries the scenario numbers")
        for _, id in ipairs(Scenarios.order) do
            check(runners[id].finished, "scenario finished " .. id)
            for name, run in pairs(metrics[id]) do
                if name ~= "gap_no_hop" then check(run.valid == true and run.issue == "none", "valid model run " .. id .. "." .. name) end
            end
        end
        -- Structural facts of the current model, independent of its tuning.
        local s02 = metrics.S02
        check(near(s02.left_3.radius, s02.right_3.radius, 1e-9) and near(s02.left_6.radius, s02.right_6.radius, 1e-9)
            and near(s02.left_3.yaw_rate, -s02.right_3.yaw_rate, 1e-9), "left and right turns mirror")
        local s05 = metrics.S05
        check(s05.r3_quick_hop.hop_strength == 1 and s05.full_charge_flick.hop_strength == 1 and s05.minimum_flick.hop_strength == .25,
            "input.lua strengths: R3 and full charge 1, the shortest flick 0.25")
        check(s05.gap_no_hop.valid == false and s05.gap_no_hop.issue == "unavailable_contact", "riding into the gap ends at its far wall")
        check(metrics.S01.flat.brake.stopped and metrics.S01.flat.accel.top_speed > 0, "the flat run accelerates and stops")
        -- S01's coast follows 6 s of pedal, so its energy_change is the
        -- recovery lift, held to the same bound as the constructed coast.
        local run = runners.S01.runs[1]
        local a, b
        for i, tag in ipairs(run.tags) do
            if tag == "coast" then a = a or i b = i end
        end
        local records = {}
        for i = a, b do table.insert(records, run.trace[i]) end
        local gain = recovery_bounded(records, run.trace[a - 1], run.initial.body.center_of_mass[2],
            run.initial.body.mass * -run.sim.tuning.gravity[2], "S01 coast")
        check(gain == metrics.S01.flat.coast.energy_change and gain > 0, "S01's energy_change is that bounded lift")
    end)

    case("a repeat run is bit-identical", function()
        local again
        again, repeat_runners = Scenarios.run(logger(repeat_log))
        -- Exact == on every leaf; the path is only spelled out on a mismatch.
        local function leaves(a, b)
            if type(a) ~= "table" or type(b) ~= "table" then return a == b and 1 or nil end
            if count(a) ~= count(b) then return nil end
            local n = 0
            for key, value in pairs(a) do
                local inner = leaves(value, b[key])
                if not inner then return nil end
                n += inner
            end
            return n
        end
        local function same(a, b, path)
            local n = leaves(a, b)
            if n then assertions += n - 1 end
            check(n ~= nil, "bit-identical " .. path)
        end
        same(metrics, again, "metrics")
        for _, id in ipairs(Scenarios.order) do
            for name, trace in pairs(runners[id].traces) do
                local other = repeat_runners[id].traces[name]
                check(#trace == #other, "same step count " .. id .. "." .. name)
                -- Every step: positions, velocities, energies, contact facts.
                for i = 1, #trace do same(trace[i], other[i], id .. "." .. name .. "[" .. i .. "]") end
            end
        end
    end)

    case("metrics match the recorded BASELINE", function()
        local function compare(value, expected, path)
            if type(expected) == "table" then
                check(type(value) == "table", "table " .. path)
                for key in pairs(value) do check(expected[key] ~= nil, "no unrecorded metric " .. path .. "." .. tostring(key)) end
                for key, child in pairs(expected) do compare(value[key], child, path .. "." .. tostring(key)) end
            elseif type(expected) == "number" then
                -- Tight enough to flag any behavioural change, loose enough
                -- for libm last-bit differences between Luau hosts.
                check(type(value) == "number" and math.abs(value - expected) <= 1e-6 * math.max(1, math.abs(expected)),
                    "baseline " .. path .. " " .. tostring(value) .. " vs " .. tostring(expected))
            else
                check(value == expected, "baseline " .. path)
            end
        end
        compare(metrics, BASELINE, "metrics")
        -- The serializer on a constructed table, against its exact source.
        local sample = { big = 1e20, list = { 3, -.25 }, n = -7, name = "a \"b\"", nested = { deep = { x = 2.5 } },
            off = false, on = true, ratio = .1, zero = -0, ["two words"] = 1 }
        check(Scenarios.lua_source(sample, "SAMPLE") == table.concat({
            "local SAMPLE = {",
            "    big = 1e+20,",
            "    list = {",
            "        [1] = 3,",
            "        [2] = -0.25,",
            "    },",
            "    n = -7,",
            "    name = \"a \\\"b\\\"\",",
            "    nested = {",
            "        deep = {",
            "            x = 2.5,",
            "        },",
            "    },",
            "    off = false,",
            "    on = true,",
            "    ratio = 0.10000000000000001,",
            "    [\"two words\"] = 1,",
            "    zero = -0,",
            "}" }, "\n"), "lua_source writes the expected source for a constructed table")
        check(not pcall(Scenarios.lua_source, { x = 0 / 0 }) and not pcall(Scenarios.lua_source, { x = math.huge }),
            "a number with no Lua literal is refused")
        -- The metrics' own source: every leaf, in sorted key order, reads
        -- back to the identical value, so a pasted BASELINE loses nothing.
        local source = Scenarios.lua_source(metrics)
        check(string.sub(source, 1, 18) == "local BASELINE = {" and source == Scenarios.lua_source(metrics),
            "the re-recording source is deterministic")
        local leaves = {}
        local function walk(value)
            local keys = {}
            for key in pairs(value) do table.insert(keys, key) end
            table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
            for _, key in ipairs(keys) do
                if type(value[key]) == "table" then walk(value[key]) else table.insert(leaves, { key, value[key] }) end
            end
        end
        walk(metrics)
        local at = 0
        for line in string.gmatch(source, "[^\n]+") do
            local key, text = string.match(line, "^%s+([%w_]+) = (.-),$")
            if key and text ~= "{" then
                at += 1
                local leaf = leaves[at]
                local expected = leaf and leaf[2]
                local same = leaf ~= nil and key == leaf[1]
                if type(expected) == "number" then same = same and tonumber(text) == expected
                elseif type(expected) == "string" then same = same and text == string.format("%q", expected)
                else same = same and text == tostring(expected) end
                check(same, "source line " .. at .. " round-trips: " .. line)
            end
        end
        check(at == #leaves and at > 150, "the source carries every metric")
    end)

    case("scenario chunks stay inside the test budget", function()
        local runner = Scenarios.runner("S01")
        local before = runner.steps
        runner:advance(Scenarios.chunk_steps)
        check(runner.steps - before == Scenarios.chunk_steps, "one chunk is exactly chunk_steps native steps")
        -- The hard bound is deterministic: within each scenario every
        -- progress call but the last follows exactly chunk_steps native steps,
        -- the last fewer, and there is one call per advance(), so no call
        -- ever waits on more than chunk_steps kernel steps.
        local n = Scenarios.chunk_steps
        for _, pass in ipairs({ { "first", first_log, runners }, { "repeat", repeat_log, repeat_runners } }) do
            local label, log, ran = pass[1], pass[2], pass[3]
            local at = 0
            for _, id in ipairs(Scenarios.order) do
                local total, traced = ran[id].steps, 0
                for _, trace in pairs(ran[id].traces) do traced += #trace end
                check(traced == total and total > n, label .. " " .. id .. " steps are the traced steps")
                local calls, previous = total // n + 1, 0
                for j = 1, calls do
                    at += 1
                    local row = log[at]
                    local delta = row and row[2] - previous
                    check(row ~= nil and row[1] == id and (j < calls and delta == n or j == calls and delta >= 0 and delta < n),
                        label .. " " .. id .. " progress call " .. j .. " of " .. calls)
                    previous = row[2]
                end
                check(previous == total, label .. " " .. id .. " the last call reports every step")
            end
            check(at == #log, label .. ": no progress call outside a chunk")
        end
        -- Plus the energy case's five 120-step coasts.
        check(#first_log == #repeat_log and chunks == #first_log + #repeat_log + 5 * (120 // n),
            "every progress call was a chunk")
        -- Wall time is advisory. The median survives preemption; the tail
        -- does not, so p99 and the maximum are only reported in the result.
        if clock and #times > 0 then
            local sorted = table.clone(times)
            table.sort(sorted)
            local over = 0
            for _, ms in ipairs(sorted) do if ms >= 20 then over += 1 end end
            timing = { median = sorted[(#sorted + 1) // 2], p99 = sorted[math.ceil(#sorted * .99)], max = sorted[#sorted],
                over = over }
            check(timing.median < 20, "median chunk " .. timing.median .. " ms is inside the 20 ms budget")
        end
    end)

    case("a chunk budget that is not a positive integer is refused", function()
        -- Scenarios.run calls advance() until the scenario finishes. Zero, a
        -- negative or NaN never lets advance() take a step, so run() looped
        -- forever; a fraction took more steps than asked, and infinity ran a
        -- whole scenario as one chunk. Every call here stays bounded even
        -- without the check: the runner's first attempt at work raises, and so
        -- does the first progress call.
        local issue = "scenario chunk budget must be a positive finite integer"
        local function refused(ok, why) return not ok and string.find(tostring(why), issue, 1, true) ~= nil end
        local bad = { { "zero", 0 }, { "negative zero", -0 }, { "negative", -1 }, { "negative fraction", -.1 },
            { "nan", 0 / 0 }, { "infinity", math.huge }, { "negative infinity", -math.huge }, { "fraction", .25 },
            { "fraction above one", 1.5 }, { "string", "4" }, { "false", false }, { "true", true }, { "table", {} } }
        for _, row in ipairs(bad) do
            local label, budget = row[1], row[2]
            local runner, began = Scenarios.runner("S01"), 0
            runner._begin = function() began += 1 error("bounded work sentinel", 0) end
            check(refused(pcall(runner.advance, runner, budget)), label .. ": advance refuses the budget")
            check(began == 0 and runner.steps == 0 and runner.at == 0 and runner.current == nil,
                label .. ": advance refused before any work")
            local calls = 0
            check(refused(pcall(Scenarios.run, function() calls += 1 error("bounded progress sentinel", 0) end, budget)),
                label .. ": run refuses the budget")
            check(calls == 0, label .. ": run refused before its first chunk")
        end
        local runner = Scenarios.runner("S01")
        check(refused(pcall(runner.advance, runner)), "advance needs a budget")
        check(runner.steps == 0 and runner.current == nil, "a missing budget does no work")
        -- A refusal mid-scenario leaves the run as it was, and a valid budget
        -- resumes it. A step replaces sim.body, so the same table means no step.
        check(not runner:advance(1) and runner.steps == 1, "a budget of one is one native step")
        local run = runner.current
        local body = run.sim.body
        check(refused(pcall(runner.advance, runner, 0)), "a runner part way through a scenario refuses zero")
        check(runner.current == run and runner.steps == 1 and #run.trace == 1 and run.sim.steps == 1 and run.sim.body == body,
            "the refusal left the run as it was")
        check(not runner:advance(7) and runner.steps == 8 and #run.trace == 8, "a valid budget resumes the run")
    end)

    return { cases = cases, assertions = assertions, native_actions = 0, chunks = chunks,
        chunks_over_20ms = timing and timing.over, chunk_ms_median = timing and timing.median,
        chunk_ms_p99 = timing and timing.p99, chunk_ms_max = timing and timing.max }
end

return Tests

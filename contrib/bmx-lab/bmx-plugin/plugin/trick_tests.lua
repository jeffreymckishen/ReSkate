local Tricks = require("./tricks")
local motions = require("./motions")
local catalog = require("./catalog")
local tests = {}
function tests.run()
    local assertions, cases = 0, 0
    local function check(value, reason)
        assertions = assertions + 1
        assert(value, reason)
    end
    local function near(a, b) return math.abs(a - b) < 1e-8 end
    local function ride(settings)
        local out = { tricks = Tricks.new(settings), input = Tricks.input({ enabled = true, owner = "rider:17:2", device = 2,
            bar_neutral = true, rear_neutral = true }) }
        function out:tick(seconds) return self.tricks:update(seconds or .01, self.input) end
        function out:air() self.input.grounded = false; check(self:tick().took_off, "observed ground starts one flight") end
        function out:bar(direction)
            self.input.bar_neutral, self.input.barspin = false, direction or "left"
            self:tick(); self.input.barspin = "none"
        end
        function out:tail(direction)
            self.input.rear_neutral, self.input.tailwhip = false, direction or "right"
            self:tick(); self.input.tailwhip = "none"
        end
        function out:wait(steps, neutral, seconds)
            self.input.bar_neutral, self.input.rear_neutral = neutral ~= false, neutral ~= false
            for _ = 1, steps do self:tick(seconds) end
        end
        function out:land() self.input.grounded = true; return self:tick() end
        function out:state() return self.tricks:state() end
        out:tick()
        return out
    end
    local function caught_quality()
        local r = ride(); r:air(); r:bar(); r:wait(52)
        check(r:state().bar_caught, "quality fixture caught in the air")
        r.input.landing_quality_available = true
        return r
    end

    do
        local r = ride()
        r.input.barspin, r.input.tailwhip, r.input.bar_neutral, r.input.rear_neutral = "left", "right", false, false
        r:tick(); check(not r:state().bar_rotating, "grounded request is not an air trick")
        r:air(); r:tick(); check(not r:state().bar_rotating and not r:state().tail_rotating, "held takeoff requests cannot start")
        r.input.barspin, r.input.tailwhip = "none", "none"; r:wait(1)
        r:bar(); r:tail()
        check(r:state().bar_rotating and r:state().tail_rotating, "fresh airborne requests can combine")
        r:wait(56)
        local s = r:state()
        check(s.bar_caught and s.tail_caught and s.pending_units == 2, "45/55 centisecond rotations catch in flight")
        check(near(s.bar_angle, -2 * math.pi) and near(s.tail_angle, 2 * math.pi), "signed full-turn endpoints stay unwrapped")
        check(s.tally.landed_units == 0 and s.tail_release > 0, "air catch has no landed score and starts a blend")
        r:wait(6); check(r:state().bar_release == 0 and r:state().tail_release == 0, "catch blend restores contacts")
        local e = r:land()
        check(e.combo_landed and e.barspins == 1 and e.tailwhips == 1 and e.units == 2, "support commits caught combo once")
        check(r:state().tally.landed_by_id[34] == 1 and r:state().tally.landed_by_id[52] == 1, "signed identities reach own tally")
        r:tick(); check(r:state().tally.landed_combos == 1, "held support cannot double-award")
        cases = cases + 1
    end
    do
        local early = ride(); early:air(); early:bar(); early:wait(38)
        early.input.grounded = true
        check(early:tick(.1).failure == "under_rotated", "contact interval cannot finish an incomplete rotation")
        local late = ride(); late:air(); late:tail(); late:wait(56, false)
        check(late:state().tail_waiting_catch, "held stick waits for catch")
        late.input.rear_neutral = true
        check(late:land().failure == "uncaught", "first contact cannot manufacture neutral catch")
        local expired = ride(); expired:air(); expired:bar(); expired:wait(60, false)
        check(expired:state().failure == "uncaught" and expired:state().bar_release == 1, "expired catch retains released contact")
        expired:wait(2); check(expired:land().failed, "late neutral cannot revive expired attempt")
        cases = cases + 1
    end
    do
        local r = ride(); r:air(); r:bar(); r:wait(46, false)
        r.input.bar_neutral = true; check(r:tick().bar_caught, "neutral within window catches")
        r:wait(6); r:bar("right"); r:wait(46)
        check(r:state().pending_barspins == 2 and near(r:state().bar_angle, 0), "fresh opposite spin repeats from unwrapped origin")
        check(r:land().barspins == 2, "both completed spins commit together")
        cases = cases + 1
    end
    do
        for _, angle in ipairs({ math.pi, 2 * math.pi, -2 * math.pi }) do
            local r = ride(); r:air()
            for i = 1, 40 do r.input.body_yaw = angle * i / 40; r:tick() end
            local e = r:land()
            check(e.combo_landed and e.spin_half_turns == math.floor(math.abs(angle) / math.pi + .5), "measured yaw supports forward and fakie landings")
        end
        local partial = ride(); partial:air()
        for i = 1, 40 do partial.input.body_yaw = .75 * math.pi * i / 40; partial:tick() end
        check(partial:land().failure == "under_rotated", "135 degrees does not claim 180")
        local side = ride(); side:air(); side:bar()
        for i = 1, 50 do side.input.body_yaw = .25 * math.pi * i / 50; side.input.bar_neutral = true; side:tick() end
        check(side:land().failure == "unaligned_landing", "caught trick landing sideways fails")
        local empty = ride(); empty:air(); empty:wait(10)
        check(not empty:land().combo_landed and empty:state().tally.landed_units == 0, "ordinary hop earns no trick credit")
        cases = cases + 1
    end
    do
        for mode = 1, 4 do
            local r = ride(); r:air(); r:bar(); r:wait(46)
            if mode == 1 then r.input.enabled = false
            elseif mode == 2 then r.input.device = 3
            elseif mode == 3 then r.input.owner = "rider:17:3"
            else r.tricks:cancel() end
            local e = r:tick()
            check(mode == 4 or e.canceled, "lifecycle and identity loss cancel live attempt")
            check(not r:state().airborne and r:state().bar_release == 0, "cancellation clears transient release")
            r.input.enabled = true; r.input.barspin = "none"; r:wait(60)
            check(not r:land().combo_landed and r:state().tally.canceled_combos == 1, "canceled flight cannot resurrect or count twice")
            r:tick(); r:air(); r:bar(); r:wait(46)
            check(r:land().combo_landed, "new ground and neutral permit new attempt")
            r.tricks:cancel(); check(r:state().tally.landed_combos == 1, "cancel preserves landed tally")
            r.tricks:reset(); check(r:state().tally.landed_units == 0, "explicit reset clears session tally")
        end
        cases = cases + 1
    end
    do
        for _, seconds in ipairs({ -.01, .2, math.huge, 0 / 0 }) do
            local r = ride(); r:air(); r:bar(); r:wait(20)
            local e = r:tick(seconds)
            check(e.canceled and e.failure == "invalid_sample", "bad or discontinuous clock cancels")
            r:wait(60); check(not r:land().combo_landed, "invalid elapsed time cannot catch up later")
        end
        local zero = ride(); zero:air(); zero:bar(); zero:wait(20)
        local angle = zero:state().bar_angle; zero.input.grounded, zero.input.bar_neutral = true, true
        zero:tick(0)
        check(zero:state().airborne and zero:state().bar_angle == angle, "zero step cannot catch or land")
        check(zero:tick().failed, "next real support sees incomplete trick")
        local jump = ride(); jump:air(); jump:bar(); jump.input.body_yaw = math.pi
        check(jump:tick().failure == "invalid_sample", "heading jump cannot fabricate spin credit")
        local huge = ride(); huge:air(); huge:bar(); huge.input.body_yaw = 1e20
        check(huge:tick().failure == "invalid_sample", "large finite heading retains its nonzero modular jump")
        cases = cases + 1
    end
    do
        local r = caught_quality(); local first = r:land()
        check(not first.landed and r:state().landing_pending and r:state().landing_support_seconds == 0, "first contact contributes zero settled time")
        local angle = r:state().bar_angle
        r.input.barspin, r.input.bar_neutral = "right", false
        r:tick(0); check(r:state().landing_support_seconds == 0, "zero step cannot settle")
        for _ = 1, 5 do
            r.input.body_yaw = r.input.body_yaw + .1; r.input.travel_yaw = r.input.body_yaw
            check(not r:tick().combo_landed, "less than60ms support cannot commit")
            check(r:state().bar_angle == angle and r:state().pending_barspins == 1, "contact freezes channels and airborne score")
        end
        local e = r:tick()
        check(e.combo_landed and e.barspins == 1 and e.spin_half_turns == 0, "six observed support intervals commit frozen combo")
        cases = cases + 1
    end
    do
        local r = caught_quality(); r:land(); r:wait(3)
        r.input.grounded = false; r:wait(4)
        check(r:state().landing_pending and near(r:state().landing_gap_seconds, .04) and r:state().landing_support_seconds == 0, "40ms bounce resets settlement")
        r.input.grounded = true; r:tick()
        check(r:state().landing_support_seconds == 0, "recontact interval contributes no support time")
        r:wait(5); check(r:tick().combo_landed, "consecutive support after bounce settles")
        local gap = caught_quality(); gap:land(); gap.input.grounded = false; gap:wait(5)
        check(not gap:state().landing_pending and gap:state().failure == "unstable_landing", "unqualified gap above40ms cancels")
        cases = cases + 1
    end
    do
        local held = caught_quality(); held:land()
        held.input.grounded, held.input.landing_settle_hold = false, true
        held:wait(20)
        check(held:state().landing_pending and held:state().landing_hold_active and near(held:state().landing_hold_elapsed_seconds, .2), "fresh adapter hold is bounded to200ms")
        held:tick(); check(held:state().failure == "unstable_landing" and not held:state().airborne, "hold expiry cancels without scoring")
        local invalid = caught_quality(); invalid:land(); invalid.input.landing_settle_hold_invalid = true
        check(invalid:tick().failure == "unstable_landing", "adapter rejection cancels pending landing")
        cases = cases + 1
    end
    do
        for _, fault in ipairs({ { body_up_alignment = .49 }, { support_up_alignment = .14 }, { closing_normal_speed = 7.01 } }) do
            local r = caught_quality()
            for k, v in pairs(fault) do r.input[k] = v end
            check(r:land().failure == "unstable_landing", "bad observed quality rejects landing")
        end
        local edge = caught_quality(); edge.input.body_up_alignment, edge.input.support_up_alignment, edge.input.closing_normal_speed = .5, .15, 7
        edge:land(); edge:wait(5); check(edge:tick().combo_landed, "quality thresholds include boundary")
        local bad = caught_quality(); bad.input.support_up_alignment = 0 / 0
        check(bad:land().failure == "invalid_sample", "NaN support is unavailable, never valid landing")
        local absent = caught_quality(); absent:land(); absent.input.landing_quality_available = false
        check(absent:tick().failure == "invalid_sample", "quality cannot disappear during settlement")
        cases = cases + 1
    end
    do
        -- Independent target checks, including the optional C++ aggregate fields.
        check(motions.find(0).bike_pitch == 2 * math.pi and motions.find(0).bike_roll == -.55, "grand slam has full pitch and bounded roll")
        check(motions.find(3).bike_pitch == -.35 and motions.find(3).bike_roll == -2 * math.pi, "bri flip has full roll and bounded pitch")
        check(motions.find(21).release_mask == 0 and motions.find(21).bike_roll == 1.38, "table retains contacts and authored roll target")
        check(motions.find(23).bar_pose_radians == -2.375 and motions.find(37).bar_pose_radians == -math.pi, "held bar targets differ from full rotations")
        check(motions.find(7).release_mask == 14 and motions.find(11).release_mask == 15, "limb release masks preserve hand/foot identity")
        check(not pcall(function() motions.find(21).bike_roll = 0 end), "motion records cannot be mutated by consumers")
        local count = 0
        for id = 0, 79 do
            local e = motions.find(id)
            check((e ~= nil) == (catalog.name(id) ~= nil), "motion records cover exactly58 named IDs")
            if e then
                count = count + 1
                local r = ride(); r:air()
                if id == 34 then r:bar("left") elseif id == 44 then r:bar("right")
                elseif id == 52 then r:tail("right") elseif id == 56 then r:tail("left")
                else r.input.movement, r.input.rear_neutral = id, false; r:tick(); r.input.movement = catalog.none end
                r:wait(20, true, .05)
                local result = r:land()
                check(result.combo_landed and result.units == 1 and r:state().tally.landed_by_id[id] == 1, "each named movement can recover in air and land once")
            end
        end
        check(count == 58 and motions.find(255) == nil, "empty slots and none have no motion record")
        cases = cases + 1
    end
    do
        local pose = ride(); pose:air(); pose.input.movement, pose.input.rear_neutral = 7, false; pose:tick(); pose.input.movement = 255
        pose:wait(20, false, .02)
        check(pose:state().movement_holding and pose:state().release_left_hand == 0 and pose:state().release_right_hand == 1
            and pose:state().release_left_foot == 1 and pose:state().release_right_foot == 1, "held Superman releases authored limbs")
        pose.input.rear_neutral = true; pose:tick()
        check(pose:state().movement_recovering and pose:state().movement_recovery_progress == 0, "neutral starts measured recovery at zero")
        pose:wait(5, true, .02)
        check(pose:land().failure == "uncaught", "contact cannot finish final recovery interval")
        local cycle = ride(); cycle:air(); cycle.input.movement, cycle.input.rear_neutral = 54, false; cycle:tick(); cycle.input.movement = 255
        cycle:wait(31, false, .02)
        check(cycle:state().failure == "uncaught", "catalog cycle also has bounded catch window")
        cases = cases + 1
    end
    do
        -- Full measured quaternion turns; alternating signs must not add rotation.
        for _, sample in ipairs({ { 1, 1, "front_flips" }, { 1, -1, "back_flips" }, { 3, 1, "barrel_rolls" } }) do
            local r = ride(); r.input.orientation_available = true; r:tick(); r:air()
            for i = 1, 40 do
                local angle = sample[2] * 2 * math.pi * i / 40
                local q = { 0, 0, 0, math.cos(angle / 2) }; q[sample[1]] = math.sin(angle / 2)
                if i % 2 == 0 then for j = 1, 4 do q[j] = -q[j] end end
                r.input.body_quaternion = q; r:tick()
                q[1] = 999 -- A caller mutation after the sample cannot change stored history.
            end
            r.input.body_quaternion = { 0, 0, 0, -1 }
            local e = r:land()
            check(e.combo_landed and e[sample[3]] == 1 and e.spin_half_turns == 0, "body-local quaternion increments recognize physical complete turn")
        end
        local flip = ride(); flip:air(); flip:bar(); flip.input.orientation_available = true
        check(flip:tick().failure == "invalid_sample", "orientation provenance cannot change midflight")
        local norm = ride(); norm:air(); norm:bar(); norm.input.orientation_available, norm.input.body_quaternion = true, { 0, 0, 0, 2 }
        check(norm:tick().failure == "invalid_sample", "nonunit orientation is refused")
        cases = cases + 1
    end
    do
        local r = ride({ bar_seconds = 0 / 0, tail_seconds = 99, catch_window = -1, landing_gap_seconds = 99 })
        local s = r.tricks:settings()
        check(s.bar_seconds == .45 and s.tail_seconds == 1 and s.catch_window == .02 and s.landing_gap_seconds == .1, "settings defaults and bounds are ported")
        s.bar_seconds = 0; check(r.tricks:settings().bar_seconds == .45, "settings readback is detached")
        r:air(); r:bar(); local snapshot = r:state(); snapshot.tally.landed_by_id[34] = 99
        snapshot.airborne = false
        check(r:state().airborne and r:state().tally.landed_by_id[34] == 0, "state readback cannot mutate controller")
        r.input.owner = 9007199254740992
        check(r:tick().canceled, "rounded uint64 owner identity is refused")
        local bad = ride(); bad:air(); bad:bar(); bad.input.movement = 30
        check(bad:tick().failure == "invalid_sample", "unsupported identity is invalid rather than a guessed trick")
        cases = cases + 1
    end
    do
        local r = ride(); r:air(); r.input.movement, r.input.rear_neutral = 7, false; r:tick(); r.input.movement = 255
        r:bar(); r:tail(); r:wait(20, true, .05)
        check(r:state().pending_movements == 1 and r:state().pending_barspins == 0 and r:state().pending_tailwhips == 0,
            "bar and tail pulses while catalog movement owns limbs are consumed")
        r:wait(5)
        check(not r:state().bar_rotating and not r:state().tail_rotating, "busy requests cannot start later on neutral")
        r:bar(); r:wait(50)
        check(r:land().units == 2, "fresh request after catalog recovery can combine")
        local busy = ride(); busy:air(); busy:bar()
        busy.input.movement, busy.input.rear_neutral = 7, false; busy:tick(); busy.input.movement = 255
        busy:wait(60)
        check(busy:state().pending_movements == 0 and busy:state().pending_barspins == 1, "catalog pulse during barspin is consumed")
        check(busy:land().units == 1, "busy catalog pulse never queues behind catch")
        cases = cases + 1
    end
    do
        local r = ride(); r:air(); r:bar(); r:tail(); r:wait(62)
        -- Seed only the private fixture tally to reach a numerical boundary
        -- without trillions of simulated landings. Public snapshots stay detached.
        local maximum = 9007199254740991
        local t = r.tricks._state.tally
        t.landed_combos, t.landed_units, t.landed_barspins = maximum, maximum - 1, maximum
        t.landed_by_id[34] = maximum
        local e = r:land()
        check(e.combo_landed and e.units == 2, "boundary fixture still produces a real two-unit landing")
        local result = r:state().tally
        check(result.landed_combos == maximum and result.landed_units == maximum and result.landed_barspins == maximum
            and result.landed_by_id[34] == maximum, "Lua tallies saturate at the last exact safe integer")
        r:tick(); check(r:state().tally.landed_units == maximum, "saturation remains stable on later support")
        cases = cases + 1
    end
    return { cases = cases, assertions = assertions, native_actions = 0 }
end
return tests

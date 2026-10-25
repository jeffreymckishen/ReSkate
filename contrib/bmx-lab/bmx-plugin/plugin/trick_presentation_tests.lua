-- The optional stage prepares work for the existing single visual owner. The
-- isolated runner provides no reskate writer, entity, input or rider API, and
-- every support fact below is CONSTRUCTED (see trick_runtime_tests.lua).
local Presentation = require("./trick_presentation")
local Fixture = require("./trick_runtime_tests")
local Visual = require("./bike_visual")
local G = require("./bike_geometry")
local M = require("./force_math")
local tests = {}

function tests.run()
    local cases, assertions = 0, 0
    local function check(value, why)
        assertions += 1
        assert(value, why)
    end
    local function near(a, b, tolerance) return math.abs(a - b) < (tolerance or 1e-6) end
    local function same_matrix(a, b, tolerance)
        for i = 1, 16 do if not near(a[i], b[i], tolerance) then return false end end
        return true
    end
    local IDENTITY = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
    local function part(name)
        for i, blueprint in ipairs(G.blueprints) do if blueprint == name then return i end end
        error("unknown blueprint " .. name)
    end
    local function deep_freeze(v)
        if type(v) == "table" and not table.isfrozen(v) then
            for _, x in pairs(v) do deep_freeze(x) end
            table.freeze(v)
        end
        return v
    end
    local function fixture(settings)
        local s = {stage = Presentation.new(settings), f = Fixture.fixture(),
            base = {steer = 0, front_wheel_phase = 0, rear_wheel_phase = 0, crank_phase = 0}}
        -- change(frame, contact, actions, base) edits this one call's records.
        function s:frame(ground, options, change)
            local frame, contact, actions = self.f:next(ground, options)
            local base = table.clone(self.base); base.physics_epoch = frame.physics_epoch
            if change then change(frame, contact, actions, base) end
            self.last = {frame = frame, contact = contact, actions = actions, base = base}
            return self.stage:prepare(frame, contact, actions, base)
        end
        function s:ready()
            local prime = self:frame(true)
            check(prime.valid and prime.issue == "primed" and #prime.matrices == 8,
                "constructed neutral ground primes and presents the measured bike")
            local air = self:frame(false)
            check(air.valid and air.trick.model_events.took_off, "takeoff comes from explicit measured support loss")
        end
        function s:bar()
            local out = self:frame(false, {handlebar = "left", neutral = false})
            check(out.valid and out.trick.model_state.bar_rotating, "a fresh airborne request starts the bar channel")
            return out
        end
        function s:wait(count, ground, options)
            local out
            for _ = 1, count do
                out = self:frame(ground == true, options)
                check(out.valid, "fresh presentation observation remains valid")
            end
            return out
        end
        function s:neutral() return Visual.from_sample(self.last.frame.sample, Visual.neutral()) end
        return s
    end
    local function absent(out) return not out.valid and out.matrices == nil and out.offsets == nil and out.pose == nil end

    do
        check(reskate == nil, "isolated fixture deliberately has no entity or rider writer API")
        local s = fixture()
        local out = s:frame(true)
        check(out.valid and out.fresh and out.issue == "primed", "a qualified prime is presented")
        check(#out.matrices == 8 and #out.offsets == 8 and #out.blueprints == 8, "eight parts, eight offsets, eight names")
        for i = 1, 8 do check(out.blueprints[i] == G.blueprints[i], "parts follow bike_geometry.blueprints order") end
        check(out.serial == s.last.frame.serial and rawequal(out.binding.physics_epoch, s.last.frame.physics_epoch)
            and rawequal(out.binding.body_handle, s.last.frame.body_handle),
            "matrices keep the exact native correlation beside the pose")
        check(out.pose.physics_epoch == nil and out.entity == nil and out.native_consumed == nil and out.actual_caught == nil,
            "prepared work gives the single writer no fabricated ownership or consumption claim")
        check(out.trick.scope == "model_adapter_only" and out.trick.realized == false
            and out.trick.visual_targets.realized == false, "the adapter result is still model-only")
        for _, list in ipairs({out.matrices, out.offsets}) do
            for _, matrix in ipairs(list) do
                check(#matrix == 16, "each authored part has a complete matrix")
                for _, value in ipairs(matrix) do
                    check(type(value) == "number" and value == value and math.abs(value) < math.huge,
                        "prepared matrix entries are finite")
                end
            end
        end
        cases += 1
    end
    do
        local s = fixture()
        for _, out in ipairs({s:frame(true), s:frame(false), s:frame(false)}) do
            check(out.valid, "neutral frames are presented")
            for i = 1, 8 do
                check(same_matrix(out.offsets[i], IDENTITY, 1e-12), "neutral articulation is an identity offset: " .. G.blueprints[i])
                check(same_matrix(out.matrices[i], s:neutral()[i], 1e-12), "neutral matches bike_visual's own neutral placement")
            end
        end
        cases += 1
    end
    do
        -- Each base channel moves only the parts it belongs to, found by name.
        local moves = {
            steer = {"reskate/bmx/fork", "reskate/bmx/front_wheel", "reskate/bmx/handlebars"},
            front_wheel_phase = {"reskate/bmx/front_wheel"},
            rear_wheel_phase = {"reskate/bmx/rear_wheel"},
            crank_phase = {"reskate/bmx/cranks", "reskate/bmx/left_pedal", "reskate/bmx/right_pedal"},
        }
        for channel, names in pairs(moves) do
            local s = fixture(); s.base[channel] = .7
            local out = s:frame(true)
            check(out.valid and out.pose[channel] == .7, "base channel passes through unchanged: " .. channel)
            local moved = {}
            for _, name in ipairs(names) do moved[part(name)] = true end
            for i = 1, 8 do
                check(same_matrix(out.offsets[i], IDENTITY, 1e-12) ~= (moved[i] == true),
                    channel .. " moves exactly its own parts; checked " .. G.blueprints[i])
            end
        end
        cases += 1
    end
    do
        local s = fixture(); s:ready(); s:bar()
        local out = s:wait(12, false, {neutral = false})
        local neutral = s:neutral()
        local bars = part("reskate/bmx/handlebars")
        check(out.pose.barspin < -.1 and not same_matrix(out.matrices[bars], neutral[bars]),
            "the barspin target visibly rotates the authored handlebars matrix")
        for _, name in ipairs({"reskate/bmx/frame", "reskate/bmx/fork", "reskate/bmx/front_wheel"}) do
            check(same_matrix(out.matrices[part(name)], neutral[part(name)]), "barspin leaves this part neutral: " .. name)
        end
        check(out.trick.model_events.units == 0 and not out.trick.model_events.combo_landed and out.actual_caught == nil,
            "visible bar motion neither awards a landing nor claims grip")
        cases += 1
    end
    do
        local s = fixture(); s:ready()
        s:frame(false, {movement = 21, rear_neutral = false})
        local out = s:wait(6, false)
        local frame_part = part("reskate/bmx/frame")
        check(out.pose.movement_bike_roll > .1 and not same_matrix(out.matrices[frame_part], s:neutral()[frame_part]),
            "authored Table movement changes the frame presentation matrix")
        local q = s.last.frame.sample.rotation
        check(q[1] == 0 and q[2] == 0 and q[3] == 0 and q[4] == 1 and s.last.frame.body.orientation[4] == 1,
            "trick articulation does not predict or rewrite measured body orientation")
        cases += 1
    end
    do
        local s = fixture(); s.f.q = {0, math.sqrt(.5), 0, math.sqrt(.5)}; s.f.center = {10, 20, 30}
        local out = s:frame(true)
        local m = out.matrices[1]
        check(near(m[13], 10.05) and near(m[14], 19.1) and near(m[15], 30),
            "measured COM becomes the visual root by subtracting the rotated authored COM")
        check(near(m[1], 0) and near(m[2], 0) and near(m[3], -1)
            and near(m[5], 0) and near(m[6], 1) and near(m[7], 0)
            and near(m[9], 1) and near(m[10], 0) and near(m[11], 0),
            "the world matrix uses the measured ninety-degree yaw in a column-major basis")
        for i = 2, 8 do check(same_matrix(m, out.matrices[i]), "neutral parts share the measured root and basis") end
        cases += 1
    end
    do
        -- World placement is exactly the measured root transform times the offset.
        -- Bar and tail together, then Table alone (tricks.lua consumes a
        -- movement request while a bar or tail channel is busy), each over
        -- non-zero base angles.
        for _, request in ipairs({
            {start = {handlebar = "left", tailwhip = "right", neutral = false}, hold = {neutral = false},
                moved = {"barspin", "tailwhip"}},
            {start = {movement = 21, rear_neutral = false}, hold = nil, moved = {"movement_bike_roll"}},
        }) do
            local s = fixture(); local angle = .4
            s.f.q = {math.sin(angle / 2) * .6, math.sin(angle / 2) * .8, 0, math.cos(angle / 2)}; s.f.center = {3, 4, -5}
            s.base = {steer = .2, front_wheel_phase = 1.25, rear_wheel_phase = -2.5, crank_phase = .75}
            s:ready(); s:frame(false, request.start)
            local out = s:wait(5, false, request.hold)
            for _, name in ipairs(request.moved) do check(math.abs(out.pose[name]) > .05, "a composed pose is under test: " .. name) end
            local q = s.last.frame.sample.rotation
            local root = M.sub(s.f.center, M.turn(q, G.com))
            for i = 1, 8 do
                local o, w = out.offsets[i], out.matrices[i]
                local ok = w[4] == 0 and w[8] == 0 and w[12] == 0 and w[16] == 1
                for column = 0, 3 do
                    local v = M.turn(q, {o[column * 4 + 1], o[column * 4 + 2], o[column * 4 + 3]})
                    if column == 3 then v = M.add(v, root) end
                    for row = 1, 3 do ok = ok and near(w[column * 4 + row], v[row], 1e-9) end
                end
                check(ok, "world = measured rotation and root times offset: " .. G.blueprints[i])
            end
        end
        cases += 1
    end
    do
        for _, entry in ipairs({
            {"physical_support_unqualified", function(_, c)
                c.support = {known = false, grounded_known = false, reason = "wheel_support_not_qualified"} end},
            {"invalid_actions", function(_, _, a) a.handlebar = "up" end},
        }) do
            local s = fixture(); s:ready(); s:bar(); s:wait(3, false, {neutral = false})
            local out = s:frame(false, nil, entry[2])
            check(absent(out) and out.issue == entry[1], "unavailable riding facts give no neutral fallback: " .. entry[1])
            -- Whether the refused read anchored chronology decides if this is a
            -- gap or an unprimed successor; either way nothing old is shown.
            out = s:frame(false)
            check(absent(out), "the refusal cancelled the old trick: " .. entry[1])
        end
        cases += 1
    end
    do
        local touched = false
        local trap = setmetatable({}, {__index = function() touched = true; return 0 end})
        for _, entry in ipairs({
            {"invalid_sample", function(fr) fr.sample.position = vector.create(math.huge, 0, 0) end},
            {"invalid_sample", function(fr) fr.sample.position = nil end},
            {"invalid_sample", function(fr) fr.sample.position = {10, 20, 30} end},
            {"invalid_sample", function(fr) fr.sample.rotation = {0, 0, 0, 2}; fr.body.orientation = {0, 0, 0, 2} end},
            {"visual_position_unavailable", function(fr)
                fr.sample.position = vector.create(1000000, .5, 0); fr.body.center_of_mass = {1000000, .5, 0} end},
            {"base_pose_unavailable", function(_, _, _, b) b.steer = math.huge end},
            {"base_pose_unavailable", function(_, _, _, b) b.crank_phase = 0 / 0 end},
            {"base_pose_unavailable", function(_, _, _, b) b.front_wheel_phase = 1e5 end},
            {"base_pose_unavailable", function(_, _, _, b) b.rear_wheel_phase = nil end},
            {"base_pose_unavailable", function(_, _, _, b) b.physics_epoch = newproxy() end},
            {"base_pose_unavailable", function(_, _, _, b) setmetatable(b, getmetatable(trap)) end},
            {"landing_quality_unavailable", function(_, c) c.support.normal = {0, 0 / 0, 0} end},
        }) do
            local s = fixture(); s:frame(true)
            local before = s.stage:status()
            local out = s:frame(true, nil, entry[2])
            local after = s.stage:status()
            check(absent(out) and out.issue == entry[1], "non-finite or unbound input refuses: " .. entry[1])
            check(after.generation > before.generation, "the refusal cancels the trick model: " .. entry[1])
            check(after.model_updates == before.model_updates, "a refused frame never advances the model: " .. entry[1])
        end
        local s = fixture(); s:frame(true)
        local out = s.stage:prepare(s.f:next(true))
        check(absent(out) and out.issue == "base_pose_unavailable", "a missing base pose is never assumed neutral")
        check(not touched, "a hostile base pose metatable runs nothing")
        cases += 1
    end
    do
        -- A control run finds the frame that settles the landing; the same run
        -- with that frame's visual input broken must not award it.
        local function landing(break_at)
            local s = fixture(); s:ready(); s:bar(); s:wait(52, false)
            check(s.stage:status().model_state.bar_caught, "the landing fixture has only a model catch")
            local first = s:frame(true)
            check(first.valid and first.trick.model_state.landing_pending, "first constructed support begins settling")
            for frame = 1, 12 do
                if frame == break_at then
                    local before = s.stage:status().model_updates
                    local out = s:frame(true, nil, function(_, _, _, b) b.steer = 0 / 0 end)
                    check(absent(out) and out.issue == "base_pose_unavailable", "the would-be settling frame is refused")
                    check(s.stage:status().model_updates == before, "the refused frame never reached the model")
                    -- The model never saw that step, so the next one is a gap.
                    local gap = s:frame(true)
                    check(absent(gap) and gap.issue == "body_serial_gap", "the unseen step is a gap, not a late settle")
                    local after = s:frame(true)
                    check(after.valid and after.issue == "primed" and not after.trick.model_events.combo_landed,
                        "the next ground frame primes a new attempt instead of awarding the old one")
                    return nil
                end
                local out = s:frame(true)
                if out.trick.model_events.combo_landed then return frame end
            end
            return nil
        end
        local settle = landing(nil)
        check(settle ~= nil, "the control run settles a combo")
        check(landing(settle) == nil, "visual validation precedes the model, so a rejected frame cannot award a landing")
        cases += 1
    end
    do
        local s = fixture(); s:ready(); s:bar()
        local original = s:wait(5, false, {neutral = false})
        local updates = s.stage:status().model_updates
        local frame, contact, actions = s.f:pack(false, {neutral = false})
        local base = table.clone(s.base); base.physics_epoch = frame.physics_epoch
        local duplicate = s.stage:prepare(frame, contact, actions, base)
        check(absent(duplicate) and duplicate.issue == "duplicate_frame" and not duplicate.fresh,
            "an extra render read dispatches no duplicate matrix work")
        check(s.stage:status().model_updates == updates, "a duplicate render cannot advance the trick angle")
        local next_frame = s:frame(false, {neutral = false})
        check(next_frame.valid and next_frame.pose.barspin ~= original.pose.barspin,
            "the next true native step resumes measured presentation")
        cases += 1
    end
    do
        -- The adapter cancels its model for a duplicate measurement under a
        -- changed source but still reports duplicate_frame. The stage sees the
        -- generation move and says so, so the owner drops the old trick pose.
        local s = fixture(); s:ready(); s:bar(); s:wait(3, false, {neutral = false})
        local before = s.stage:status()
        s.f.source_epoch = "18446744073709551613"
        local frame, contact, actions = s.f:pack(false, {neutral = false})
        local base = table.clone(s.base); base.physics_epoch = frame.physics_epoch
        local out = s.stage:prepare(frame, contact, actions, base)
        local after = s.stage:status()
        check(absent(out) and out.issue == "duplicate_frame_cancelled" and not out.fresh,
            "a duplicate that cancelled the model is not a harmless duplicate")
        check(after.issue == "duplicate_frame" and after.generation > before.generation
            and after.model_updates == before.model_updates, "the adapter itself still calls it a duplicate")
        out = s:frame(false, {neutral = false})
        check(absent(out) and out.issue == "neutral_ground_prime_required", "the cancelled trick is not shown again")
        cases += 1
    end
    do
        -- Presentation.over hands the stage an adapter whose step results are
        -- broken, which the tracked adapter never returns. prepare must cancel
        -- that adapter itself, so the model cannot carry on behind a frame the
        -- owner was given nothing for.
        local Runtime = require("./trick_runtime")
        for _, entry in ipairs({
            {"trick_frame_mismatch", function(out) out.binding.serial = "1"; return out end},
            {"trick_frame_mismatch", function(out) out.binding = {}; return out end},
            {"trick_frame_mismatch", function(out) out.fresh = false; return out end},
            -- The rest of the read the adapter binds: lease, source and clock.
            {"trick_frame_mismatch", function(out) out.binding.lease_handle = newproxy(); return out end},
            {"trick_frame_mismatch", function(out) out.binding.source.observation_serial = "1"; return out end},
            {"trick_frame_mismatch", function(out) out.time += 1; return out end},
            {"trick_result_unavailable", function(out) out.visual_targets.barspin = 0 / 0; return out end},
            {"trick_result_unavailable", function() return {valid = true, fresh = false, advanced = false, issue = "none"} end},
            {"trick_result_unavailable", function(out) out.fresh, out.advanced, out.visual_targets = false, false, nil; return out end},
            {"trick_result_unavailable", function() error("constructed adapter failure") end},
            {"trick_result_unavailable", function() return nil end},
        }) do
            local real, reasons, broken = Runtime.new(), {}, false
            local adapter = {}
            function adapter:step(...)
                local out = real:step(...)
                if broken then return entry[2](out) end
                return out
            end
            function adapter:cancel(reason) table.insert(reasons, reason); return real:cancel(reason) end
            function adapter:status() return real:status() end
            local s = fixture(); s.stage = Presentation.over(adapter)
            s:ready(); s:bar(); s:wait(3, false, {neutral = false})
            check(#reasons == 0, "a working adapter is never cancelled by the stage")
            broken = true
            local before = real:status().generation
            local out = s:frame(false, {neutral = false})
            check(absent(out) and out.issue == entry[1], "an unusable step result is never placed: " .. entry[1])
            check(#reasons == 1 and reasons[1] == entry[1] and real:status().generation > before,
                "prepare cancels the adapter for it: " .. entry[1])
            broken = false
            out = s:frame(false, {neutral = false})
            check(absent(out) and out.issue == "neutral_ground_prime_required", "the old trick does not come back: " .. entry[1])
        end
        local touched = false
        local real = Runtime.new()
        check(not pcall(Presentation.over), "a stage needs an adapter")
        for _, bad in ipairs({7, {}, {step = real.step, cancel = real.cancel},
            setmetatable({}, {__index = function() touched = true; return real.step end})}) do
            check(not pcall(Presentation.over, bad), "a stage needs a plain adapter with step, cancel and status")
        end
        check(not touched, "an adapter behind a metatable is refused untouched")
        local s = fixture(); s.stage = Presentation.over(real)
        check(s:frame(true).issue == "primed" and real:status().model_updates == 1, "a stage over a held adapter steps that adapter")
        cases += 1
    end
    do
        local s = fixture(); s:ready(); s:bar(); s:wait(3, false, {neutral = false})
        s.f.source_epoch = "18446744073709551613"
        local changed = s:frame(false)
        check(absent(changed) and changed.issue == "neutral_ground_prime_required",
            "a new input source cannot inherit the prior matrix presentation")
        local g = fixture(); g:ready(); g:bar(); g:wait(3, false, {neutral = false})
        g.f.focused = false
        local focus = g:frame(false)
        check(absent(focus) and focus.issue == "owner_or_focus_gate", "focus loss cancels presentation without a fallback")
        g.f.focused = true
        check(absent(g:frame(false)), "refocus in the air does not revive the old trick")
        cases += 1
    end
    do
        local s = fixture(); s.f.center = {10, 20, 30}
        local original = s:frame(true)
        original.matrices[1][13], original.pose.steer, original.offsets[1][1] = 9999, 9999, 9999
        original.blueprints[1] = "changed"; original.trick.visual_targets.barspin = 9999
        local next_frame = s:frame(true)
        check(near(next_frame.matrices[1][13], 10) and next_frame.pose.steer == 0 and next_frame.offsets[1][1] == 1
            and next_frame.blueprints[1] == "reskate/bmx/frame" and G.blueprints[1] == "reskate/bmx/frame"
            and next_frame.trick.visual_targets.barspin == 0,
            "the visual owner receives detached output and cannot change later prepared work")
        local cancelled = s.stage:cancel("constructed explicit cancel")
        check(not cancelled.valid and cancelled.issue == "constructed explicit cancel", "explicit cancel reports its reason")
        check(absent(s:frame(false)), "after cancel, flight needs a fresh prime")
        check(s:frame(true).issue == "primed", "explicit cancel then requires a fresh neutral ground prime")
        cases += 1
    end
    do
        -- Deep-frozen records and trapping handles: any write into the inputs,
        -- or any use of a handle beyond identity, would throw or flag here.
        local touched = false
        local function handle()
            local h = newproxy(true); local mt = getmetatable(h)
            mt.__index = function() touched = true end
            mt.__newindex = function() touched = true end
            mt.__tostring = function() touched = true; return "handle" end
            mt.__len = function() touched = true; return 0 end
            return h
        end
        local s = fixture(); s.f.body_handle, s.f.lease_handle = handle(), handle()
        for _, ground in ipairs({true, false, false}) do
            local frame, contact, actions = s.f:next(ground)
            local base = table.clone(s.base); base.physics_epoch = frame.physics_epoch
            local ok, out = pcall(s.stage.prepare, s.stage, deep_freeze(frame), deep_freeze(contact),
                deep_freeze(actions), deep_freeze(base))
            check(ok and out.valid and #out.matrices == 8, "frozen measured records are presented without being written")
        end
        check(not touched, "opaque body and lease handles are compared, never used")
        check(not pcall(function() s.stage.prepare = nil end) and not pcall(function() Presentation.new = nil end),
            "the stage and module cannot be rewired by a caller")
        local bad = setmetatable({}, {__index = function() touched = true end})
        check(not pcall(Presentation.new, bad) and not touched, "settings with a metatable are refused untouched")
        cases += 1
    end
    do
        -- present() places a result another owner stepped, so wiring can feed
        -- it the Ride coordinator's one adapter instead of a second model.
        local Runtime = require("./trick_runtime")
        local s, r, f = fixture(), Runtime.new(), Fixture.fixture()
        local function both(ground, options)
            local a = s:frame(ground, options)
            local frame, contact, actions = f:next(ground, options)
            local base = table.clone(s.base); base.physics_epoch = frame.physics_epoch
            local result = r:step(frame, contact, actions)
            local updates = r:status().model_updates
            local b = Presentation.present(frame, result, base)
            check(r:status().model_updates == updates, "present steps no model")
            return a, b, frame, result, base
        end
        local a, b = both(true)
        both(false); both(false, {handlebar = "left", tailwhip = "right", neutral = false})
        for _ = 1, 6 do a, b = both(false, {neutral = false}) end
        check(a.valid and b.valid and b.pose.barspin < -.1, "both paths present the same mid-trick frame")
        for i = 1, 8 do
            local exact = true
            for k = 1, 16 do exact = exact and a.matrices[i][k] == b.matrices[i][k] and a.offsets[i][k] == b.offsets[i][k] end
            check(exact, "present matches prepare exactly: " .. G.blueprints[i])
        end
        local _, _, frame, result, base = both(false)
        local stale_frame, contact, actions = f:next(false)
        local stale_base = table.clone(s.base); stale_base.physics_epoch = stale_frame.physics_epoch
        local stale = Presentation.present(stale_frame, result, stale_base)
        check(absent(stale) and stale.issue == "trick_frame_mismatch", "a result from another read is never placed")
        local unbound = Presentation.present(frame, result, stale_base)
        check(absent(unbound) and unbound.issue == "base_pose_unavailable", "present keeps the same base pose binding")
        for _, bad in ipairs({false, 7, setmetatable({}, {__index = result}), {valid = true, visual_targets = {}}}) do
            local out = Presentation.present(frame, bad, base)
            check(absent(out) and out.issue == "trick_result_unavailable", "a malformed result is never placed")
        end
        local missing = Presentation.present(frame, nil, base)
        check(absent(missing) and missing.issue == "trick_result_unavailable", "a missing result is never placed")
        local refused = r:step(stale_frame, contact, {})
        local out = Presentation.present(stale_frame, refused, stale_base)
        check(absent(out) and out.issue == "invalid_actions", "an adapter refusal passes through without matrices")
        r = Runtime.new(); f = Fixture.fixture(); r:step(f:next(true))
        local d_frame, d_contact, d_actions = f:pack(true)
        local d_base = table.clone(s.base); d_base.physics_epoch = d_frame.physics_epoch
        local duplicate = r:step(d_frame, d_contact, d_actions)
        out = Presentation.present(d_frame, duplicate, d_base)
        check(duplicate.valid and absent(out) and out.issue == "duplicate_frame", "a duplicate result has nothing to place")
        cases += 1
    end
    do
        -- A retained result names its whole read: the public serial and time,
        -- and the binding trick_runtime builds (body, physics epoch, lease,
        -- serial, time, seconds, and the source lease with its eight scalar
        -- fields). present() places work another owner kept, so a result that
        -- names any other read, or leaves part of it out, is never placed.
        local Runtime = require("./trick_runtime")
        local function copy(v)
            if type(v) ~= "table" then return v end
            local out = {}; for k, x in pairs(v) do out[k] = copy(x) end; return out
        end
        local function retained()
            local r, f = Runtime.new(), Fixture.fixture()
            check(r:step(f:next(true)).issue == "primed", "the real adapter primes")
            check(r:step(f:next(false)).model_events.took_off, "the real adapter enters flight")
            local frame, contact, actions = f:next(false, {handlebar = "left", neutral = false})
            local result = r:step(frame, contact, actions)
            check(result.valid and result.fresh and result.advanced and result.model_state.bar_rotating,
                "the real adapter returns a fresh mid-trick result")
            local base = {physics_epoch = frame.physics_epoch, steer = .1, front_wheel_phase = 2,
                rear_wheel_phase = 3, crank_phase = .25}
            return frame, result, base, r
        end
        -- The adapter's own result, a copy of it with owner metadata added, and
        -- deep-frozen copies of every record all still present.
        local frame, result, base, r = retained()
        local updates = r:status().model_updates
        local own = Presentation.present(frame, result, base)
        check(own.valid and #own.matrices == 8, "the adapter's own retained result presents")
        local extra = copy(result); extra.binding.extra = "owner metadata"; extra.binding.source.extra = true
        local out = Presentation.present(frame, extra, base)
        check(out.valid and #out.matrices == 8, "an equal copied binding with extra owner metadata presents")
        out = Presentation.present(deep_freeze(copy(frame)), deep_freeze(copy(result)), deep_freeze(copy(base)))
        check(out.valid and #out.matrices == 8 and out.binding.source.sequence == "18446744073709551615"
            and out.binding.source.context_generation == "9007199254741001",
            "deep-frozen copies present and uint64 source strings stay exact")
        for i = 1, 8 do
            local exact = true
            for k = 1, 16 do exact = exact and out.matrices[i][k] == own.matrices[i][k] end
            check(exact, "a copied result places exactly what the original does: " .. G.blueprints[i])
        end
        check(r:status().model_updates == updates, "presenting a retained result steps no model")
        local function each_source(change)
            local list = {}
            for _, name in ipairs({"generation", "user", "sequence", "source_epoch", "context_generation",
                "observation_serial", "observed_ms", "packet"}) do
                table.insert(list, {"source_" .. name .. "_" .. change, function(t)
                    local v = t.binding.source[name]
                    if change == "missing" then t.binding.source[name] = nil
                    elseif type(v) == "number" then t.binding.source[name] = v + 1
                    else t.binding.source[name] = Fixture.increment(v) end
                end})
            end
            return list
        end
        local mutations = {
            {"top_serial_changed", function(t) t.serial = Fixture.increment(t.serial) end},
            {"top_serial_missing", function(t) t.serial = nil end},
            {"top_time_changed", function(t) t.time += .01 end},
            {"top_time_missing", function(t) t.time = nil end},
            {"body_changed", function(t) t.binding.body_handle = newproxy() end},
            {"epoch_changed", function(t) t.binding.physics_epoch = newproxy() end},
            {"serial_changed", function(t) t.binding.serial = Fixture.increment(t.binding.serial) end},
            {"lease_changed", function(t) t.binding.lease_handle = newproxy() end},
            {"lease_missing", function(t) t.binding.lease_handle = nil end},
            {"time_changed", function(t) t.binding.time += .01 end},
            {"time_missing", function(t) t.binding.time = nil end},
            {"seconds_changed", function(t) t.binding.seconds = .02 end},
            {"seconds_missing", function(t) t.binding.seconds = nil end},
            {"source_missing", function(t) t.binding.source = nil end},
            {"source_not_a_table", function(t) t.binding.source = "source" end},
            {"source_lease_changed", function(t) t.binding.source.lease_handle = newproxy() end},
            {"source_lease_missing", function(t) t.binding.source.lease_handle = nil end},
            {"source_number_as_string", function(t) t.binding.source.user = tostring(t.binding.source.user) end},
        }
        for _, list in ipairs({each_source("changed"), each_source("missing")}) do
            for _, entry in ipairs(list) do table.insert(mutations, entry) end
        end
        for _, mutation in ipairs(mutations) do
            local changed = copy(result); mutation[2](changed)
            out = Presentation.present(frame, changed, base)
            check(absent(out) and out.issue == "trick_frame_mismatch",
                "a retained result naming another or an incomplete read is never placed: " .. mutation[1])
        end
        check(r:status().model_updates == updates, "refusing retained results steps and cancels nothing")
        -- The same from the frame side: one physics read (same body, epoch and
        -- serial) under another input lease or source read, or another clock,
        -- is not the read the result was stepped for.
        for _, entry in ipairs({
            {"frame_lease", function(fr) local h = newproxy(); fr.source.lease_handle = h; fr.owner.lease_handle = h end},
            {"frame_observation", function(fr) fr.source.observation_serial = Fixture.increment(fr.source.observation_serial) end},
            {"frame_packet", function(fr) fr.source.packet += 1 end},
            {"frame_time", function(fr) fr.time += .001; fr.sample.time = fr.time end},
        }) do
            local other = copy(frame); entry[2](other)
            out = Presentation.present(other, result, base)
            check(absent(out) and out.issue == "trick_frame_mismatch",
                "a result is never placed on another read of the same physics step: " .. entry[1])
        end
        -- Untrusted binding tables are read raw: a getter is never run.
        local touched = false
        local trap = {__index = function() touched = true; return nil end}
        for _, change in ipairs({
            function(t) t.binding.source = setmetatable({}, trap) end,
            function(t) setmetatable(t.binding.source, trap) end,
        }) do
            local changed = copy(result); change(changed)
            local ok, refused = pcall(Presentation.present, frame, changed, base)
            check(ok and absent(refused) and refused.issue == "trick_frame_mismatch",
                "a source table behind a metatable is refused")
        end
        check(not touched, "a hostile binding metatable runs nothing")
        cases += 1
    end
    return {cases = cases, assertions = assertions}
end
return tests

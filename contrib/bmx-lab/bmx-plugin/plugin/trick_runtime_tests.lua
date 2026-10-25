-- Pure regressions for the tracked trick adapter over CONSTRUCTED measured
-- frames. Positive support below is fixture policy, never Contact.decode output
-- (which still reports support unknown) and never a native receipt or catch.
-- The intent of each case is promoted from the private presentation proposal;
-- the shapes follow the tracked step(frame, contact, actions) contract.
local Runtime = require("./trick_runtime")
local Tricks = require("./tricks")
local catalog = require("./catalog")
local Tests = {}

local source_fields = {"generation", "user", "sequence", "source_epoch", "context_generation",
    "observation_serial", "observed_ms", "packet"}
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}; for k, x in pairs(v) do out[k] = copy(x) end; return out
end
-- Exact decimal successor, so serials above 2^53 never pass through a double.
local function increment(s)
    local chars, carry = {}, 1
    for i = #s, 1, -1 do
        local n = string.byte(s, i) - 48 + carry
        chars[i] = string.char(48 + n % 10); carry = n >= 10 and 1 or 0
    end
    return (carry == 1 and "1" or "") .. table.concat(chars)
end
Tests.increment = increment

-- One measured body, one input source. pack() rebuilds the current reading
-- with a new read credential; next() advances one physics step first.
function Tests.fixture(seconds)
    local f = {seconds = seconds or .01, time = 1, serial = "100", obs = "1000", observed_ms = 1000, packet = 0,
        body_handle = newproxy(), lease_handle = newproxy(), generation = 1, user = 2,
        sequence = "18446744073709551615", source_epoch = "18446744073709551614", context_generation = "9007199254741001",
        q = {0, 0, 0, 1}, v = {0, 0, 3}, w = {0, 0, 0}, center = {0, .5, 0}, normal = {0, 1, 0}, surface = {0, 0, 0},
        focused = true, menu_open = false}
    function f:pack(grounded, options)
        options = options or {}
        local epoch = newproxy()
        local body = {mass = 106, inertia_body = {26, 32, 10}, orientation = copy(self.q), center_of_mass = copy(self.center),
            linear_velocity = copy(self.v), angular_velocity = copy(self.w)}
        local source = {lease_handle = self.lease_handle, generation = self.generation, user = self.user, sequence = self.sequence,
            source_epoch = self.source_epoch, context_generation = self.context_generation, observation_serial = self.obs,
            observed_ms = tostring(self.observed_ms), packet = self.packet}
        local v = vector.create
        local frame = {valid = true, fresh = true, body_handle = self.body_handle, physics_epoch = epoch, serial = self.serial,
            time = self.time, seconds = self.seconds, body = body, source = source,
            owner = {body_handle = self.body_handle, lease_handle = self.lease_handle},
            gates = {focused = self.focused, menu_open = self.menu_open},
            sample = {epoch = epoch, serial = self.serial, time = self.time, seconds = self.seconds, mass = body.mass,
                position = v(self.center[1], self.center[2], self.center[3]), rotation = copy(self.q),
                velocity = v(self.v[1], self.v[2], self.v[3]), angular_velocity = v(self.w[1], self.w[2], self.w[3]),
                inertia = v(26, 32, 10)}}
        local scalar = {}; for _, name in ipairs(source_fields) do scalar[name] = source[name] end
        local contact = {valid = true, status = "constructed_fixture",
            binding = {body_handle = self.body_handle, physics_epoch = epoch, lease_handle = self.lease_handle},
            frame = {serial = self.serial, time = self.time, seconds = self.seconds, source = scalar},
            query = {epoch_matches = true, accounting_known = true, budget_exhausted = false,
                local_actor_excluded = true, owned_bodies_excluded = true},
            rays = {}, support = {known = true, grounded_known = true, grounded = grounded, provenance = "measured_support"},
            force_ready = false}
        if grounded then
            contact.support.point = {0, 0, 0}; contact.support.normal = copy(self.normal)
            contact.support.surface_velocity = copy(self.surface)
        end
        local neutral = options.neutral ~= false
        local actions = {active = true, physics_epoch = epoch, h = self.seconds, source = copy(source),
            handlebar = options.handlebar or "none", tailwhip = options.tailwhip or "none",
            movement = options.movement or catalog.none,
            bar_neutral = neutral, rear_neutral = neutral}
        if options.bar_neutral ~= nil then actions.bar_neutral = options.bar_neutral end
        if options.rear_neutral ~= nil then actions.rear_neutral = options.rear_neutral end
        return frame, contact, actions
    end
    function f:next(grounded, options)
        options = options or {}
        for _ = 1, options.steps or 1 do self.time += self.seconds; self.serial = increment(self.serial) end
        if options.time then self.time = options.time end -- A clock kept apart from the step.
        if not options.repeat_source then
            self.obs = increment(self.obs); self.observed_ms += 10; self.packet += 1
        end
        return self:pack(grounded, options)
    end
    return f
end

function Tests.run()
    local assertions, cases = 0, 0
    local function check(ok, why) assertions += 1; assert(ok, why) end
    local function scenario(run) cases += 1; run() end
    local function near(a, b, tolerance) return math.abs(a - b) < (tolerance or 1e-7) end
    local fixture = Tests.fixture
    local function tick(r, f, ground, opts) return r:step(f:next(ground, opts)) end
    local function airborne(r, f)
        local prime = tick(r, f, true)
        check(prime.valid and prime.issue == "primed", "constructed neutral ground primes the measured model")
        local out = tick(r, f, false)
        check(out.valid and out.model_events.took_off, "known unsupported successor starts model flight")
        return out
    end
    local function caught(r, f)
        airborne(r, f)
        local out = tick(r, f, false, {handlebar = "left", neutral = false})
        check(out.valid and out.model_state.bar_rotating, "fresh request after airborne neutral starts the bar channel")
        local count = 0
        for _ = 1, 52 do
            out = tick(r, f, false); check(out.valid, "fresh measured flight remains valid")
            if out.model_events.bar_caught then count += 1 end
        end
        check(count == 1 and out.model_state.bar_caught, "one model catch after the bounded virtual rotation")
        return out
    end
    local function refused(out) return not out.valid and out.visual_targets == nil and out.model_events == nil end

    scenario(function()
        local r, f = Runtime.new(), fixture()
        local frame, contact, actions = f:next(true)
        local out = r:step(frame, contact, actions)
        check(out.valid and out.fresh and out.advanced and out.issue == "primed", "first qualified frame primes as model-only input")
        check(rawequal(out.binding.body_handle, frame.body_handle) and rawequal(out.binding.physics_epoch, frame.physics_epoch)
            and rawequal(out.binding.lease_handle, frame.source.lease_handle) and out.binding.serial == frame.serial,
            "private result binds the exact read, body and source")
        local t = out.visual_targets
        check(t.scope == "model_target_only" and t.realized == false and t.pose_provenance == "authored_motions_policy",
            "targets carry model-only provenance")
        for _, name in ipairs({"barspin", "tailwhip", "movement_bike_pitch", "movement_bike_roll", "movement_crank_angle"}) do
            check(type(t[name]) == "number" and t[name] == 0, "neutral prime has zero authored angle: " .. name)
        end
        check(out.native_consumed == nil and out.actual_caught == nil and out.owner == nil and out.entity == nil,
            "adapter never claims native input consumption, a physical catch or rider ownership")
        local public = Runtime.public_snapshot(out)
        check(public.binding == nil and public.realized == false and public.visual_targets.realized == false,
            "public projection strips the opaque binding")
        out.visual_targets.barspin = 999; out.model_state.airborne = true; out.binding.source.sequence = "1"
        local status = r:status()
        check(status.visual_targets.barspin == 0 and status.model_state.airborne == false and status.binding == nil,
            "returned result is detached from the cached model snapshot")
        status.visual_targets.release_left_hand = 1
        check(r:status().visual_targets.release_left_hand == 0, "public status remains detached")
    end)
    scenario(function()
        -- The shape contact_runtime.lua returns today: geometry rays, unknown support.
        local r, f = Runtime.new(), fixture()
        local frame, contact, actions = f:next(false)
        contact.support = {known = false, grounded_known = false, reason = "wheel_support_not_qualified"}
        contact.rays = {{status = "clear"}, {status = "hit"}}
        local out = r:step(frame, contact, actions)
        check(refused(out) and out.issue == "physical_support_unqualified",
            "actual unknown support cannot create air, ground or a pose target")
        check(r:status().model_updates == 0, "unknown current contact advances no model")
    end)
    scenario(function()
        local r, f = Runtime.new(), fixture()
        local out = tick(r, f, false)
        check(refused(out) and out.issue == "neutral_ground_prime_required", "air-only observation cannot invent prior ground")
        out = tick(r, f, true, {handlebar = "left", neutral = false})
        check(refused(out) and out.issue == "neutral_ground_prime_required", "held request cannot prime the model")
        check(r:status().model_updates == 0, "refused primes leave the model unadvanced")
        check(tick(r, f, true).issue == "primed", "a later neutral ground observation primes")
    end)
    scenario(function()
        local r, f = Runtime.new(), fixture(); tick(r, f, true)
        local out = tick(r, f, false, {handlebar = "left", neutral = false})
        check(out.valid and out.model_events.took_off and not out.model_state.bar_rotating, "held takeoff request is not a fresh trick")
        out = tick(r, f, false, {handlebar = "left", neutral = false})
        check(not out.model_state.bar_rotating, "a held request needs a measured neutral first")
        tick(r, f, false)
        out = tick(r, f, false, {handlebar = "left", neutral = false})
        check(out.model_state.bar_rotating, "real neutral then an edge arms the airborne request")
    end)
    scenario(function()
        local r, f = Runtime.new(), fixture(); airborne(r, f)
        local out = tick(r, f, false, {handlebar = "left", tailwhip = "right", neutral = false})
        check(out.model_state.bar_rotating and out.model_state.tail_rotating, "fresh bar and tail requests start both channels")
        for _ = 1, 20 do out = tick(r, f, false, {neutral = false}) end
        check(out.visual_targets.barspin < -.1 and out.visual_targets.tailwhip > .1,
            "signed barspin and tailwhip channels drive the target angles")
        check(not out.model_state.bar_caught and out.model_state.pending_units == 0,
            "visible rotation neither catches early nor counts units")
        for _ = 1, 45 do out = tick(r, f, false) end
        check(out.model_state.bar_caught and out.model_state.tail_caught, "measured neutral drives only the model catch states")
        check(near(out.visual_targets.barspin, -2 * math.pi) and near(out.visual_targets.tailwhip, 2 * math.pi),
            "completed targets keep signed full turns")
        local contact = tick(r, f, true)
        check(contact.valid and contact.model_state.landing_pending and not contact.model_events.combo_landed,
            "first contact does not synthesize landing settle time")
        local landed, units = 0, 0
        for _ = 1, 8 do
            local settle = tick(r, f, true)
            if settle.model_events.combo_landed then landed += 1; units = settle.model_events.units end
        end
        check(landed == 1 and units == 2, "sustained constructed contact settles the caught combo once")
        check(not tick(r, f, true).model_events.combo_landed, "held ground cannot award the combo twice")
    end)
    scenario(function()
        local r, f = Runtime.new(), fixture(); airborne(r, f)
        tick(r, f, false, {handlebar = "left", neutral = false})
        for _ = 1, 10 do tick(r, f, false, {neutral = false}) end
        local out = tick(r, f, true)
        check(out.valid and out.model_events.failed and out.model_events.failure == "under_rotated"
            and not out.model_events.bar_caught and not out.model_events.combo_landed,
            "contact cannot finish an incomplete rotation or synthesize a catch")
    end)
    scenario(function()
        local r, f = Runtime.new(), fixture(); airborne(r, f)
        local out = tick(r, f, false, {movement = 54, rear_neutral = false})
        for _ = 1, 20 do out = tick(r, f, false) end
        check(out.visual_targets.movement_id == 54 and out.visual_targets.movement_crank_angle > .1,
            "Crankflip feeds the crank target; wheels are not a target")
        check(out.visual_targets.front_wheel_phase == nil and out.visual_targets.steer == nil,
            "trick targets never integrate or overwrite measured steering or wheels")
    end)
    scenario(function()
        local r, f = Runtime.new(), fixture(); airborne(r, f)
        local out = tick(r, f, false, {movement = 21, rear_neutral = false})
        for _ = 1, 9 do out = tick(r, f, false) end
        check(out.visual_targets.movement_bike_roll > .1 and out.visual_targets.movement_bike_pitch == 0,
            "authored Table motion feeds bike roll")
        check(near(out.visual_targets.barspin, 0) and near(out.visual_targets.tailwhip, 0),
            "a held bike pose does not fabricate barspin or tailwhip")
    end)
    scenario(function()
        local r, f = Runtime.new(), fixture(); airborne(r, f)
        r:step(f:next(false, {handlebar = "left", neutral = false}))
        local updates = r:status().model_updates
        local duplicate, same_contact, same_actions = f:pack(false, {handlebar = "left", neutral = false})
        local out = r:step(duplicate, same_contact, same_actions)
        check(out.valid and not out.fresh and not out.advanced and out.issue == "duplicate_frame"
            and out.model_events == nil and out.visual_targets == nil,
            "a new read credential on the same measurement replays no event or target")
        check(r:status().model_updates == updates, "a duplicate never advances model time")
        local resumed = tick(r, f, false)
        check(resumed.valid and resumed.advanced and resumed.model_state.bar_rotating, "the next true step resumes the flight")
        local changed, c, a = f:pack(false)
        changed.body.orientation = {0, 0, 0, -1}; changed.sample.rotation = {0, 0, 0, -1}
        out = r:step(changed, c, a)
        check(refused(out) and out.issue == "body_duplicate_changed", "a changed payload under a consumed serial is refused")
        out = tick(r, f, false)
        check(refused(out) and out.issue == "neutral_ground_prime_required", "the refusal cancelled the flight")
    end)
    scenario(function()
        local r, f = Runtime.new(), fixture(); airborne(r, f)
        local frame, contact, actions = f:next(false); r:step(frame, contact, actions)
        actions.handlebar, actions.bar_neutral = "left", false
        local out = r:step(frame, contact, actions)
        check(refused(out) and out.issue == "actions_duplicate_changed", "one source ordinal cannot change its requests")
    end)
    scenario(function()
        -- The tracked adapter refuses every serial gap. The proposal accepted N+2;
        -- here a gap cancels, anchors and needs a fresh neutral ground prime.
        local r, f = Runtime.new(), fixture(); airborne(r, f)
        local out = tick(r, f, false, {steps = 2})
        check(refused(out) and out.issue == "body_serial_gap", "a skipped measured step cannot be guessed")
        check(tick(r, f, false).issue == "neutral_ground_prime_required", "later known air stays unprimed")
        out = tick(r, f, true)
        check(out.valid and out.issue == "primed" and not out.model_state.airborne, "coherent neutral ground re-primes")
        check(tick(r, f, false).model_events.took_off, "gap recovery creates only a new observed flight")
    end)
    scenario(function()
        local r, f = Runtime.new(), fixture(); f.serial = "9007199254740992" -- 2^53
        check(tick(r, f, true).valid and tick(r, f, true).valid, "adjacent serials above 2^53 stay distinct and exact")
        check(f.serial == "9007199254740994", "the fixture walked past the exact-integer limit")
        local high = fixture(); high.serial = "18446744073709551614"
        check(tick(Runtime.new(), high, true).valid, "the largest uint64 serial is accepted")
        local h = Runtime.new(); high.serial = "18446744073709551613"; tick(h, high, true)
        local out = tick(h, high, true)
        check(out.valid and high.serial == "18446744073709551615", "the uint64 maximum is an ordinary successor")
        out = tick(h, high, true)
        check(refused(out) and out.issue == "invalid_sample", "uint64 overflow is refused")
    end)
    scenario(function()
        local invalid = {
            {"invalid_sample", function(fr) fr.sample.rotation = {0, 0, 0, 2}; fr.body.orientation = {0, 0, 0, 2} end},
            {"invalid_sample", function(fr) fr.sample.rotation[1] = 0 / 0 end},
            {"invalid_sample", function(fr) fr.sample.position = vector.create(math.huge, 0, 0) end},
            {"invalid_sample", function(fr) fr.sample.time = math.huge; fr.time = math.huge end},
            {"invalid_sample", function(fr) fr.sample.seconds = 0; fr.seconds = 0 end},
            {"invalid_sample", function(fr) fr.sample.seconds = .11; fr.seconds = .11 end},
            {"invalid_sample", function(fr) fr.sample.serial = "01"; fr.serial = "01" end},
            {"invalid_sample", function(fr) fr.sample.serial = "0"; fr.serial = "0" end},
            {"invalid_sample", function(fr) fr.sample.serial = 101; fr.serial = 101 end},
            {"invalid_frame", function(fr) fr.physics_epoch = "invented-epoch" end},
            {"sample_alias_mismatch", function(fr) fr.sample.epoch = newproxy() end},
            {"body_alias_mismatch", function(fr) fr.body.center_of_mass = {0, .6, 0} end},
            {"contact_frame_mismatch", function(_, c) c.binding.physics_epoch = newproxy() end},
            {"contact_frame_mismatch", function(_, c) c.frame.serial = "1" end},
            {"physical_support_unqualified", function(_, c) c.support.provenance = "ray_geometry" end},
            {"physical_support_unqualified", function(_, c) c.support.grounded = nil end},
            {"contact_query_unqualified", function(_, c) c.query.epoch_matches = false end},
            {"contact_query_unqualified", function(_, c) c.query.accounting_known = false end},
            {"contact_query_unqualified", function(_, c) c.query.budget_exhausted = true end},
            {"contact_query_unqualified", function(_, c) c.query.local_actor_excluded = false end},
            {"contact_query_unqualified", function(_, c) c.query.owned_bodies_excluded = false end},
            {"landing_quality_unavailable", function(_, c) c.support.normal = {0, 2, 0} end},
            {"landing_quality_unavailable", function(_, c) c.support.normal = {0, 0 / 0, 0} end},
            {"landing_quality_unavailable", function(_, c) c.support.point = nil end},
            {"invalid_actions", function(_, _, a) a.physics_epoch = newproxy() end},
            {"invalid_actions", function(_, _, a) a.h = .02 end},
            {"invalid_actions", function(_, _, a) a.active = false end},
            {"invalid_actions", function(_, _, a) a.handlebar = "up" end},
            {"invalid_actions", function(_, _, a) a.movement = -1 end},
            {"invalid_actions", function(_, _, a) a.bar_neutral = nil end},
            {"invalid_actions", function(_, _, a) a.rear_neutral = 0 end},
            {"invalid_actions", function(_, _, a) a.source.lease_handle = newproxy() end},
        }
        for _, entry in ipairs(invalid) do
            local r, f = Runtime.new(), fixture(); tick(r, f, true)
            local generation = r:status().generation
            local frame, contact, actions = f:next(true)
            entry[2](frame, contact, actions)
            local out = r:step(frame, contact, actions)
            check(refused(out) and out.issue == entry[1], "malformed or mismatched record is refused: " .. entry[1])
            -- A refused read may or may not anchor chronology, so the next air
            -- frame is either a gap or an unprimed successor. Neither advances.
            check(r:status().generation > generation and refused(tick(r, f, false)), "every refusal cancels: " .. entry[1])
        end
    end)
    scenario(function()
        local r, f = Runtime.new(), fixture(); tick(r, f, true)
        local frame, contact, actions = f:next(false)
        frame.time += 1; frame.sample.time = frame.time; contact.frame.time = frame.time
        check(refused(r:step(frame, contact, actions)), "an unobserved physical gap cannot become model time")
        local back = fixture(); local b = Runtime.new(); tick(b, back, true)
        frame, contact, actions = back:next(true)
        frame.time -= .02; frame.sample.time = frame.time; contact.frame.time = frame.time
        local out = b:step(frame, contact, actions)
        check(refused(out) and out.issue == "physical_time_regressed", "regressing native time is refused")
    end)
    scenario(function()
        local r, f = Runtime.new(), fixture(); airborne(r, f)
        tick(r, f, false, {handlebar = "left", neutral = false})
        f.source_epoch = "18446744073709551613"
        local out = tick(r, f, false)
        check(refused(out) and out.issue == "neutral_ground_prime_required", "a new source identity cannot adopt an airborne model")
        out = tick(r, f, true)
        check(out.valid and not out.model_state.airborne and not out.model_state.bar_rotating, "the new source primes clean")
        local g = Runtime.new(); local body = fixture(); airborne(g, body)
        tick(g, body, false, {handlebar = "left", neutral = false})
        body.body_handle = newproxy()
        out = tick(g, body, false)
        check(refused(out) and out.issue == "neutral_ground_prime_required", "a replacement body cannot inherit old trick angles")
    end)
    scenario(function()
        local r, f = Runtime.new(), fixture(); airborne(r, f)
        tick(r, f, false, {handlebar = "left", neutral = false})
        f.focused = false
        local out = tick(r, f, false)
        check(refused(out) and out.issue == "owner_or_focus_gate", "focus loss consumes no model time or targets")
        f.focused = true
        out = tick(r, f, false)
        check(refused(out) and out.issue == "neutral_ground_prime_required", "airborne refocus cannot revive the old flight")
        check(refused(tick(r, f, true, {handlebar = "left", neutral = false})), "held input cannot prime after focus loss")
        out = tick(r, f, true)
        check(out.valid and out.issue == "primed" and not out.model_state.bar_rotating, "fresh neutral ground re-primes")
        f.menu_open = true
        check(tick(r, f, true).issue == "owner_or_focus_gate", "an open menu is the same gate")
    end)
    scenario(function()
        local r, f = Runtime.new(), fixture(); caught(r, f)
        f.v = {0, 0, 0}; tick(r, f, false)
        local out = tick(r, f, true)
        check(refused(out) and out.issue == "preimpact_quality_unavailable",
            "stationary precontact travel never becomes an invented heading or award")
    end)
    scenario(function()
        local r, f = Runtime.new(), fixture(); caught(r, f)
        f.v = {0, -20, 3}; tick(r, f, false); f.v = {0, 0, 0}
        local out = tick(r, f, true)
        check(out.valid and out.model_events.failed and not out.model_events.combo_landed,
            "postcollision zero velocity cannot conceal a measured hard approach")
    end)
    scenario(function()
        local r, f = Runtime.new(), fixture(.02); caught(r, f)
        for i = 1, 4 do
            local angle = i * math.pi / 12; f.q = {0, 0, math.sin(angle / 2), math.cos(angle / 2)}
            check(tick(r, f, false).valid, "bounded measured roll updates")
        end
        f.normal = {math.sin(math.pi / 3), math.cos(math.pi / 3), 0}
        local out = tick(r, f, true)
        check(out.valid and out.model_events.failed, "body-up alignment uses the actual support normal")
    end)
    scenario(function()
        local r, f = Runtime.new(), fixture(.02); airborne(r, f)
        for i = 1, 24 do
            local angle = i * math.pi / 12; f.q = {math.sin(angle / 2), 0, 0, math.cos(angle / 2)}
            local out = tick(r, f, false)
            check(out.valid and out.advanced and out.visual_targets.realized == false,
                "a full measured flip is tracked through the vertical and the antipodal quaternion")
        end
        local out = tick(r, f, true)
        check(out.valid and out.model_state.landing_pending, "a fully observed flip can enter model settling")
    end)
    scenario(function()
        -- Native float(1/60) step against a double clock that accumulates 1/60.
        local r, f, clock = Runtime.new(), fixture(0.01666666753590107), 40
        local function step(ground, opts)
            opts = opts or {}; clock += 1 / 60; opts.time = clock
            return tick(r, f, ground, opts)
        end
        check(step(true).issue == "primed", "the native 60 Hz float interval primes")
        local air = step(false)
        check(air.valid and air.model_events.took_off, "60 Hz takeoff follows measured support loss")
        step(false, {handlebar = "left", neutral = false})
        local frames, caught_at = 0, nil
        for _ = 1, 40 do
            local out = step(false); frames += 1
            check(out.valid and out.model_state.airborne and not out.model_events.landed, "the float step stays a coherent successor")
            if out.model_events.bar_caught then caught_at = caught_at or frames end
        end
        check(caught_at and (caught_at + 1) / 60 >= .45 - 1e-9 and (caught_at + 1) / 60 <= .45 + 2 / 60,
            "the bar catch lands on the authored 0.45 s rotation at 60 Hz")
    end)
    scenario(function()
        local r, f = Runtime.new(), fixture(); airborne(r, f)
        local prior = {f:next(false, {handlebar = "left", neutral = false})}
        r:step(prior[1], prior[2], prior[3])
        local generation = r:status().generation
        local cancelled = r:cancel("constructed explicit cancel")
        check(not cancelled.valid and cancelled.issue == "constructed explicit cancel" and r:status().generation == generation + 1,
            "explicit cancel records its reason and a new generation")
        local again = {f:pack(false, {handlebar = "left", neutral = false})}
        local out = r:step(again[1], again[2], again[3])
        check(out.issue == "duplicate_frame" and out.visual_targets == nil, "a duplicate never revives the cancelled flight")
        check(tick(r, f, false).issue == "neutral_ground_prime_required", "cancel requires a fresh neutral ground prime")
    end)
    scenario(function()
        -- A duplicate measurement under a changed source cancels the model but
        -- still reports a valid duplicate_frame. The proposal refused a changed
        -- owner on a duplicate (input_identity_changed). trick_presentation
        -- tells this duplicate from a harmless one by the generation.
        local r, f = Runtime.new(), fixture(); airborne(r, f)
        tick(r, f, false, {handlebar = "left", neutral = false})
        local generation, updates = r:status().generation, r:status().model_updates
        f.source_epoch = "18446744073709551613"
        local out = r:step(f:pack(false, {neutral = false}))
        check(out.valid and not out.fresh and not out.advanced and out.issue == "duplicate_frame" and out.visual_targets == nil,
            "a duplicate under a new source still reads as a duplicate")
        check(r:status().generation > generation and r:status().model_updates == updates,
            "but the adapter cancelled its model for the new source")
        out = tick(r, f, false)
        check(refused(out) and out.issue == "neutral_ground_prime_required", "the new source cannot continue the old flight")
    end)
    scenario(function()
        -- An extra read of a consumed measurement still enforces lost
        -- authority, as the proposal's duplicate-render case did.
        for _, entry in ipairs({
            {"owner_or_focus_gate", function(fr) fr.gates.focused = false end},
            {"invalid_actions", function(_, _, a) a.active = false end},
        }) do
            local r, f = Runtime.new(), fixture(); airborne(r, f)
            tick(r, f, false, {handlebar = "left", neutral = false})
            local generation = r:status().generation
            local frame, contact, actions = f:pack(false, {handlebar = "left", neutral = false})
            entry[2](frame, contact, actions)
            local out = r:step(frame, contact, actions)
            check(refused(out) and out.issue == entry[1], "a duplicate read still enforces lost authority: " .. entry[1])
            check(r:status().generation > generation and refused(tick(r, f, false)),
                "the duplicate refusal cancels the flight: " .. entry[1])
        end
    end)
    scenario(function()
        -- The proposal refused a replay of the read before a refusal as
        -- stale_native_sample. Here the refused read may or may not anchor
        -- chronology, so the replay is a regression or a duplicate with no
        -- targets. Neither revives the flight.
        for _, entry in ipairs({
            {"owner_or_focus_gate", "body_serial_regressed", function(fr) fr.gates.focused = false end},
            {"invalid_actions", "duplicate_frame", function(_, _, a) a.active = false end},
        }) do
            local r, f = Runtime.new(), fixture(); airborne(r, f)
            local before = {f:next(false, {handlebar = "left", neutral = false})}
            check(r:step(before[1], before[2], before[3]).model_state.bar_rotating, "the replayed read had started a trick")
            local frame, contact, actions = f:next(false, {neutral = false})
            entry[3](frame, contact, actions)
            check(refused(r:step(frame, contact, actions)), "the next read is refused: " .. entry[1])
            local replay = r:step(before[1], before[2], before[3])
            check(replay.issue == entry[2] and replay.visual_targets == nil and replay.model_events == nil,
                "replaying the read before a refusal shows nothing: " .. entry[1])
            check(refused(tick(r, f, false)), "the old flight stays cancelled: " .. entry[1])
        end
    end)
    scenario(function()
        -- Tracked difference, pinned so an adapter change shows up: the adapter
        -- compares a frame only with the last one and keeps no per-body serial
        -- watermark. After body B, a retained grounded neutral read of body A
        -- is a changed identity and primes again. The proposal refused this
        -- replay as stale_native_sample.
        local r, f = Runtime.new(), fixture(); tick(r, f, true)
        local old = {f:next(true)}
        check(r:step(old[1], old[2], old[3]).valid, "body A's grounded neutral read is consumed")
        tick(r, f, true)
        f.body_handle = newproxy()
        check(tick(r, f, true).issue == "primed", "body B primes independently")
        local updates = r:status().model_updates
        local returned = r:step(old[1], old[2], old[3])
        check(returned.valid and returned.fresh and returned.advanced and returned.issue == "primed"
            and rawequal(returned.binding.body_handle, old[1].body_handle)
            and rawequal(returned.binding.physics_epoch, old[1].physics_epoch),
            "a retained read of body A after body B is accepted as a new prime, not refused as stale")
        check(r:status().model_updates == updates + 1, "that retained read advances the model")
    end)
    scenario(function()
        local touched = false
        local bad = setmetatable({}, {__index = function() touched = true; return true end})
        check(not pcall(Runtime.new, bad) and not touched, "settings refuse a computed metatable before any access")
        check(not pcall(Runtime.new, {bar_seconds = 0 / 0}), "non-finite settings are refused")
        local r, f = Runtime.new(), fixture()
        local frame, contact, actions = f:next(true)
        setmetatable(frame.body, {__index = function() touched = true end})
        check(refused(r:step(frame, contact, actions)) and not touched, "a measured metatable invokes no callback")
        check(Runtime.public_snapshot({valid = true, fresh = false, advanced = false, issue = "test", serial = newproxy()}) == nil,
            "the public snapshot cannot leak an opaque serial")
        local g, h = Runtime.new(), fixture()
        h.body_handle = newproxy(true); getmetatable(h.body_handle).__tostring = function() touched = true; return "forbidden" end
        check(tick(g, h, true).valid and not touched, "opaque body identity is compared without conversion")
    end)
    scenario(function()
        -- This seam patches the shared tricks.lua module table and one model
        -- object, so it needs both unfrozen. The original constructor is put
        -- back before any check, even when Runtime.new throws.
        check(not table.isfrozen(Tricks), "tricks.lua returns an unfrozen table; freezing it needs another seam here")
        local original, captured = Tricks.new, nil
        Tricks.new = function(settings) local m = original(settings); captured = m; return m end
        local built, r = pcall(Runtime.new)
        Tricks.new = original
        check(built and captured ~= nil and not table.isfrozen(captured), "the adapter was built over a model this case can patch")
        local actual_update, fired = captured.update, false
        captured.update = function(self, seconds, input)
            if not fired then fired = true; r:cancel("constructed reentrant cancellation") end
            return actual_update(self, seconds, input)
        end
        local f = fixture(); local out = tick(r, f, true)
        check(fired and refused(out) and r:status().model_updates == 0, "a late model callback cannot revive cancelled targets")
        captured.update = actual_update
        check(tick(r, f, true).valid, "a new measured ground frame primes after the cancelled callback")
    end)
    return {assertions = assertions, cases = cases}
end
return Tests

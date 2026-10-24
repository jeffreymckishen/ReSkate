-- Pure integration candidate. The ride coordinator owns every native effect.
-- Requiring/constructing/updating this module never calls reskate or captures input.
local Recovery = require("./recovery")
local Identity = require("./lease_identity")
local Runtime, Adapter = {}, {}
Adapter.__index = Adapter
local MAX_SAFE, MAX_CONTEXT = 9007199254740991, 4294967295
local source_fields = {"lease_handle", "generation", "user", "sequence", "source_epoch", "context_generation"}
local axes = {"left_x", "left_y", "right_x", "right_y", "left_trigger", "right_trigger"}
local buttons = {"up", "down", "left", "right", "start", "back", "left_stick", "right_stick", "lb", "rb", "a", "b", "x", "y"}
local api_names = {"recover", "recovery_state", "recovery_cancel", "recovery_acknowledge"}

local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function integer(v, lo, hi) return finite(v) and v >= lo and v <= hi and v % 1 == 0 end
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}; for k, x in pairs(v) do out[k] = copy(x) end; return out
end
local function source_key(s)
    if type(s) ~= "table" or type(s.lease_handle) ~= "userdata" or not integer(s.generation, 0, MAX_SAFE)
        or not integer(s.user, 0, 3) then return nil end
    for _, name in ipairs({"sequence", "source_epoch", "context_generation"}) do
        if not Identity.is_nonzero_u64(s[name]) then return nil end
    end
    local out = {}; for _, name in ipairs(source_fields) do out[name] = s[name] end; return out
end
local function same_source(a, b)
    if not a or not b then return false end
    for _, name in ipairs(source_fields) do if a[name] ~= b[name] then return false end end
    return true
end
local function source_neutral(s)
    if not source_key(s) or not Identity.is_nonzero_u64(s.observation_serial)
        or not Identity.is_u64(s.observed_ms) or type(s.pad) ~= "table" or s.pad.playstation ~= false
        or type(s.pad.buttons) ~= "table" then return false end
    for _, name in ipairs(axes) do if s.pad[name] ~= 0 then return false end end
    for _, name in ipairs(buttons) do if s.pad.buttons[name] ~= false then return false end end
    return true
end
local function observed_valid(o)
    -- Framev1's body epoch cannot supply this missing actor observation. In
    -- particular, do not attach the body's epoch to telemetry or a pose target.
    return type(o) == "table" and type(o.actor) == "userdata" and type(o.session) == "userdata"
        and type(o.epoch) == "userdata" and Identity.is_nonzero_u64(o.serial)
        and finite(o.time) and o.time >= 0 and finite(o.seconds) and o.seconds > 0 and o.seconds <= .25
        and integer(o.committed_state, 0, 4294967295) and o.ragdoll_known == true
        and type(o.ragdoll) == "boolean" and o.in_air_known == true and type(o.in_air) == "boolean"
        and type(o.offboard) == "boolean" and type(o.standable) == "boolean"
end
local function same_actor(a, b) return a and b and a.actor == b.actor and a.session == b.session end
local function same_observation(a, b)
    -- An epoch wrapper is newly allocated for each read. Its equality is not a
    -- native identity or observation clock; compare the actual immutable facts.
    for _, k in ipairs({"actor", "session", "serial", "time", "seconds", "committed_state", "ragdoll_known",
        "ragdoll", "in_air_known", "in_air", "offboard", "standable"}) do if a[k] ~= b[k] then return false end end
    return true
end
local function sampled_fall(f)
    -- Public telemetry can stop publication conservatively, but it cannot
    -- authorize get-up, actor release, or a native standing suffix.
    local t = f.telemetry
    return type(t) == "table" and type(t.watch) == "table" and t.watch.valid == true
        and t.watch.ragdoll_known == true and t.watch.ragdoll == true
end
local function complete_park(r, sequence)
    return type(r) == "table" and Identity.is_nonzero_u64(sequence) and r.sequence == sequence
        and r.phase == "completed" and r.terminal == true and r.park_observed == true
        and r.in_flight == 0 and type(r.pending) == "table" and next(r.pending) == nil
        and Identity.is_u64(r.final_revision) and Identity.is_u64(r.final_native_epoch)
        and (r.final_revision == "0") == (r.final_native_epoch == "0")
        and r.returned_revision == r.final_revision and r.native_retirement_known == false
end
local function source_drained(s, expected)
    if type(s) ~= "table" or s.phase ~= "complete" or s.lease_handle_present ~= false
        or s.cleanup_pending ~= false or s.cleanup_unknown ~= false or type(s.sample) ~= "table"
        or type(s.lease_state) ~= "table" or type(s.capture_state) ~= "table" then return false end
    -- Stop advances the adapter generation. Native identity remains exact.
    if not integer(s.generation, expected.generation, MAX_SAFE) then return false end
    for _, k in ipairs({"user", "sequence", "source_epoch", "context_generation"}) do
        if s.sample[k] ~= expected[k] or s.lease_state[k] ~= expected[k] or s.capture_state[k] ~= expected[k] then return false end
    end
    local l, c = s.lease_state, s.capture_state
    return l.terminal == true and l.source_released == true and l.capture_reserved == false
        and c.phase == "complete" and c.terminal == true and c.report_debt == false and c.quarantined == false
end
local function cleanup_complete(f, bound)
    local c = f.cleanup
    if type(c) ~= "table" or c.incident ~= bound.incident or c.body_handle ~= bound.body_handle
        or not same_source(source_key(c.source), bound.source) then return false end
    local b = c.bike
    if type(b) ~= "table" or b.schema ~= 1 or b.kind ~= "bike-lifecycle-v1" or b.phase ~= "done"
        or b.bike_cleanup_complete ~= true or b.bike_authority ~= false or b.cleanup_pending ~= false
        or b.cleanup_unknown ~= false or b.unloaded ~= false or b.stop_latched ~= true
        or b.completed_acknowledged ~= true or b.acknowledged ~= true
        or not complete_park(b.terminal_receipt, bound.follow_sequence) or not source_drained(b.source, bound.source)
        or type(b.equipment) ~= "table" or b.equipment.retained ~= false or b.equipment.unloaded ~= false
        or (b.equipment.phase ~= "idle" and b.equipment.phase ~= "done") then return false end
    -- The canonical coordinator, rather than this adapter, orders visual removal
    -- after park+ACK. Requiring its final state avoids a second removal/release owner.
    return true
end
local function snapshot(s, requests)
    return {schema = 1, kind = "fall-recovery-runtime-v1", enabled = s.enabled,
        phase = s.phase, issue = s.issue, incident = s.incident, requests = requests or {},
        suppress_forces = s.latched == true, suppress_follow = s.latched == true,
        duties_retained = s.bound ~= nil and not s.cleaned, duties = copy(s.bound),
        cleanup_qualified = s.cleaned == true, rearm_ready = s.rearm_ready == true,
        standing_samples = s.standing_samples or 0, standing_seconds = s.standing_seconds or 0,
        recovery_available = s.api_available, recovery = copy(s.policy_result),
        native_actions = 0, scope = "Pure coordinator requests; constructed tests do not establish native recovery"}
end
function Runtime.new(options)
    options = type(options) == "table" and options or {}
    local api, available = options.skater_api, true
    for _, name in ipairs(api_names) do available = available and type(api) == "table" and type(api[name]) == "function" end
    return setmetatable({enabled = options.enabled == true, allow_get_up = options.allow_get_up == true,
        api_available = available, phase = "inactive", issue = "disabled", incident = 0,
        context_generation = 0, policy = Recovery.new()}, Adapter)
end
function Adapter:status() return snapshot(self) end
function Adapter:_stop(f, why)
    if not self.latched then
        self.latched, self.phase, self.issue = true, "retaining_cleanup", why
        self.incident += 1
        local owner = self.last_owner or {source = source_key(f.source), body_handle = f.body_handle,
            follow_sequence = type(f.bike) == "table" and f.bike.sequence or nil,
            observed = self.last_observed or (observed_valid(f.observed) and f.observed or nil)}
        -- Missing identity remains a retained unknown, never an invented token.
        if owner.source and type(owner.body_handle) == "userdata"
            and Identity.is_nonzero_u64(owner.follow_sequence) then
            self.bound = {incident = self.incident, body_handle = owner.body_handle, source = copy(owner.source),
                follow_sequence = owner.follow_sequence, observed = copy(owner.observed)}
        else self.identity_unknown = true end
        self.stop_pending = true
    end
end
function Adapter:update(frame)
    if not self.enabled then return snapshot(self) end
    local f = type(frame) == "table" and frame or {}
    local requests = {}
    self.rearm_ready = false
    local clock_ok = finite(f.now_ms) and f.now_ms >= 0 and f.now_ms <= MAX_SAFE
    local now = clock_ok and math.floor(f.now_ms) or nil
    local fresh_wall = clock_ok and (not self.last_wall or now > self.last_wall)
    if self.last_wall and (not clock_ok or now < self.last_wall) then clock_ok, fresh_wall = false, false end
    if clock_ok then self.last_wall = now end
    local gates = type(f.gates) == "table" and f.gates.focused == true and f.gates.menu_open == false
    local loaded = f.loaded == true
    self.was_active = self.was_active == true or f.active == true
    local source = source_key(f.source)
    local fresh_input = false
    if source and Identity.is_nonzero_u64(f.source.observation_serial) and Identity.is_nonzero_u64(f.source.observed_ms) then
        if not same_source(source, self.input_source) then
            fresh_input = true
        elseif Identity.compare(f.source.observation_serial, self.input_serial) > 0
            and Identity.compare(f.source.observed_ms, self.input_ms) >= 0 then fresh_input = true end
        if fresh_input then
            self.input_source, self.input_serial, self.input_ms = copy(source), f.source.observation_serial, f.source.observed_ms
        end
    end
    local o, valid, fresh = f.observed, observed_valid(f.observed), false
    if valid then
        local previous = self.last_observed
        if previous and same_actor(previous, o) then
            local order = Identity.compare(o.serial, previous.serial)
            if order < 0 or o.time < previous.time or (order == 0) ~= (o.time == previous.time)
                or order == 0 and not same_observation(o, previous) then valid = false
            else fresh = order > 0 end
        else fresh = true end
    end
    local context_changed = valid and self.last_observed and not same_actor(self.last_observed, o)
    local source_changed = source and self.last_source and not same_source(source, self.last_source)
    local body_changed = self.last_owner and type(f.body_handle) == "userdata" and f.body_handle ~= self.last_owner.body_handle
    local watch = type(f.telemetry) == "table" and f.telemetry.watch or nil
    local wipeouts = type(watch) == "table" and watch.valid == true and integer(watch.wipeouts, 0, MAX_SAFE) and watch.wipeouts or nil
    local wipeout_edge = wipeouts and self.wipeouts and wipeouts > self.wipeouts
    local wipeout_rewind = wipeouts and self.wipeouts and wipeouts < self.wipeouts
    -- A changed exact source or measured session also stops before any caller
    -- can submit another force/follow. Focus loss never proves cleanup.
    if self.was_active and (not clock_ok or not gates or not loaded or f.valid ~= true
        or f.fresh ~= true or sampled_fall(f) or valid and fresh and o.ragdoll
        or wipeout_edge or wipeout_rewind or context_changed or source_changed or body_changed) then
        self:_stop(f, (sampled_fall(f) or valid and o.ragdoll or wipeout_edge) and "sampled_fall"
            or context_changed and "sampled_actor_or_session_changed" or source_changed and "selected_source_changed"
            or body_changed and "native_body_handle_changed" or wipeout_rewind and "sampled_wipeout_counter_rewound"
            or "runtime_readiness_lost")
    end
    if wipeouts then self.wipeouts = wipeouts end
    if valid and fresh then
        self.last_observed = copy(o)
    end
    if source then
        if not self.last_source or not same_source(source, self.last_source) then
            if self.context_generation < MAX_CONTEXT then self.context_generation += 1 else self.context_exhausted = true end
        end
        self.last_source = copy(source)
    end
    if not self.latched and f.active == true and source and type(f.body_handle) == "userdata"
        and type(f.bike) == "table" and Identity.is_nonzero_u64(f.bike.sequence) then
        self.last_owner = {source = copy(source), body_handle = f.body_handle,
            follow_sequence = f.bike.sequence, observed = valid and copy(o) or nil}
    end
    if self.stop_pending then
        -- Exactly one request; request_stop's own coordinator retains every
        -- body/input duty even if the returned call is absent or refused.
        requests.stop = {incident = self.incident, reason = tostring(self.issue)}
        self.stop_pending = false
    end
    if not self.latched then
        self.phase, self.issue = "observing", valid and "none" or "native_actor_observation_unavailable"
        return snapshot(self, requests)
    end
    if not self.cleaned and self.bound and cleanup_complete(f, self.bound) then
        self.cleaned, self.phase, self.issue = true, "awaiting_explicit_get_up", "cleanup_qualified"
        self.cleanup_observed = valid and copy(o) or nil
        self.standing_samples, self.standing_seconds, self.standing_previous = 0, 0, nil
    end
    if self.cleaned and not self.cleanup_observed and valid and fresh then
        -- First real post-cleanup sample is an anchor, never elapsed standing
        -- time. No missing interval is reconstructed from the caller clock.
        self.cleanup_observed = copy(o)
    end
    local same_incident_actor = valid and self.bound and self.bound.observed and same_actor(o, self.bound.observed)
    local ready = clock_ok and fresh_wall and gates and loaded and self.cleaned and same_incident_actor
        and source ~= nil and same_source(source, self.bound.source) and not self.context_exhausted
    -- A local context number is only the policy's uint32 bookkeeping key.
    -- The native source_epoch remains its full decimal string in bound.source.
    local policy_frame = {now_ms = now, actor = valid and o.actor or nil,
        source_epoch = self.context_generation, fall_epoch = self.incident,
        -- Missing input is not an observed neutral edge.
        gesture_down = f.get_up_down, allowed = ready and self.allow_get_up and self.api_available,
        loaded = loaded, fallen = valid and o.ragdoll == true, park_ready = self.cleaned == true,
        release_ready = self.cleaned == true}
    local replies = type(f.recovery_reply) == "table" and f.recovery_reply or {}
    for _, k in ipairs({"request_result", "receipt", "receipt_handle", "ack_result"}) do policy_frame[k] = replies[k] end
    self.policy_result = self.policy:update(policy_frame)
    local intents = self.policy_result.intents
    if next(intents) ~= nil then requests.recovery = copy(intents) end
    if self.policy_result.retained then self.phase, self.issue = "retaining_recovery", self.policy_result.outcome end
    if self.cleaned and not self.policy_result.retained and clock_ok and fresh_wall and valid and fresh and gates and loaded then
        local previous, after = self.standing_previous, self.cleanup_observed
        local standing = same_incident_actor and o.committed_state == 504 and o.offboard and o.standable
            and not o.ragdoll and not o.in_air and after and same_actor(after, o)
            and Identity.compare(o.serial, after.serial) > 0 and o.time > after.time
        if standing then
            if previous and same_actor(previous, o) and o.time > previous.time and o.time - previous.time <= .25 then
                self.standing_seconds += o.time - previous.time
                self.standing_samples += 1
            else self.standing_seconds, self.standing_samples = 0, 1 end
            self.standing_previous = copy(o)
        else self.standing_seconds, self.standing_samples, self.standing_previous = 0, 0, nil end
        if self.standing_samples >= 30 and self.standing_seconds >= 2 and source
            and not same_source(source, self.bound.source) and fresh_input and source_neutral(f.source) then
            -- This is eligibility for a separate explicit coordinator action.
            -- It neither acquires a source nor clears the historical stop latch.
            self.rearm_ready, self.phase, self.issue = true, "ready_for_explicit_rearm", "fresh_standing_and_new_neutral_source"
        end
    elseif not valid or not gates or not loaded then
        self.standing_samples, self.standing_seconds, self.standing_previous = 0, 0, nil
    end
    if self.identity_unknown then self.phase, self.issue = "retained_unknown", "incident_ownership_unavailable"
    elseif not self.cleaned then self.phase, self.issue = "retaining_cleanup", "positive_park_ack_and_source_drain_required"
    elseif not self.api_available and not self.rearm_ready then self.issue = "generic_recovery_api_unavailable"
    elseif not valid and not self.rearm_ready then self.issue = "native_actor_observation_unavailable" end
    return snapshot(self, requests)
end
return table.freeze(Runtime)

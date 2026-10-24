-- Lua orchestration only. This module never submits forces, moves a body, or
-- manufactures follow, mount, contact, release, park, or consumption evidence.
-- The sole force writer must honor submit_forces and supply the real owner.
-- A returned permit is local and cannot atomically cancel already queued work.
-- Before its one use, the sole writer must compare permit_token and
-- lifecycle_token with CURRENT status(), plus the exact body/session. Tokens
-- rotate before callbacks; neither token authorizes native work or replaces the
-- independent accepted-command/preview/response ledger and real stop hook.
-- owner.read(body, sample) is a dot-call provider returning a plain record:
-- available, body, session, follow, context; body_current, follow_current,
-- context_current, support_available, focused, menu_open, grounded, fall_stop,
-- rotation_reserved. Every decision is an explicit Boolean, and all keys are
-- genuine stable owner identities. The raw record is owner_record; the checked
-- fixed-field snapshot is owner_facts. Neither is invented by this module.
-- owner.request_stop(reason, body, body_sample) synchronously prevents future
-- force submissions and requests actual cleanup. Its unchanged return is
-- stop_request. owner.stop_state() is preserved as stop_outcome; only a genuine
-- available=true, stopped=true result matching the bound body/session confirms
-- owner cleanup. No first binding means unresolved duty. A terminal pair cannot
-- ride again; a genuine new session/body is required. Sixteen retained pairs is
-- the bounded capacity; exhaustion refuses arm, never evicts an old tombstone.
-- Source and Mapping use colon methods. Provider records must be plain tables;
-- callback failures invalidate output, while independent cleanup still runs.
local Identity = require("./lease_identity")
local RideInput = {}
RideInput.__index = RideInput
RideInput.__metatable = "locked"
local states = setmetatable({}, { __mode = "k" })
local MAX_SAFE, MAX_HOP = 9007199254740991, 4294967295
local MAX_RETIRED = 16
local owner_booleans = { "body_current", "follow_current", "context_current", "support_available",
    "focused", "menu_open", "grounded", "fall_stop", "rotation_reserved" }
local sample_vectors = { "position", "velocity", "angular_velocity", "inertia" }
local source_keys = { "sequence", "source_epoch", "context_generation" }
local pad_axes = { "left_x", "left_y", "right_x", "right_y", "left_trigger", "right_trigger" }
local pad_buttons = { "up", "down", "left", "right", "start", "back", "left_stick", "right_stick",
    "lb", "rb", "a", "b", "x", "y" }
local positive_controls = { "pedal", "brake", "manual", "nose_manual", "hop_strength" }
local signed_controls = { "steer", "air_yaw", "ground_pump" }
local boolean_controls = { "pump_operator_available", "pump_inhibited", "rotation_reserved",
    "recovery_step_verified", "contact_compliance_available", "landing_contact_compliance_selected" }
local soft_mapping = { neutral_required = true, awaiting_fresh_observation = true, not_primed = true }
local waiting_source = { armed = true, warming = true, waiting_neutral = true, capturing = true }

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end
local function integer(value, low, high)
    return finite(value) and value >= low and value <= high and value % 1 == 0
end
local function wall_time(value)
    return finite(value) and value >= 0 and value <= MAX_SAFE
end
local function invalidate_permit(s)
    -- Local cache invalidation only. This is never a native epoch, owner key,
    -- stop request identity, application receipt, or permission by itself.
    s.permit_token = table.freeze({})
end
local function plain(value)
    -- Native records have no metatable. Refuse computed field access rather
    -- than letting validation invoke arbitrary callbacks or recursive __index.
    return type(value) == "table" and getmetatable(value) == nil
end
local function reason(value, fallback)
    return type(value) == "string" and #value > 0 and #value <= 160 and value or fallback
end
local function lifecycle_key(value)
    local kind = type(value)
    return kind == "userdata" or kind == "table" or (kind == "string" and #value > 0 and #value <= 256)
end
local function method(object, name)
    local ok, value = pcall(function() return type(object) == "table" and object[name] or nil end)
    return ok and type(value) == "function" and value or nil
end
local function invoke(s, object, name, colon, ...)
    local guard = s.guard
    local fn = method(object, name)
    if guard ~= s.guard then return false, nil, name .. " lookup invalidated", false end
    if not fn then return false, nil, name .. " unavailable", guard == s.guard end
    -- Providers must return promptly and must not yield. We bound the number of
    -- calls, not the runtime of an arbitrary Lua provider; pcall is not a timer.
    local ok, result, why
    if colon then ok, result, why = pcall(fn, object, ...)
    else ok, result, why = pcall(fn, ...) end
    if not ok then return false, nil, name .. " callback failed", guard == s.guard end
    return true, result, why, guard == s.guard
end
local function ready(object, names)
    for _, name in ipairs(names) do if not method(object, name) then return false end end
    return true
end
local function vector_copy(value)
    if typeof(value) ~= "vector" and not plain(value) then return nil end
    if not finite(value.x) or not finite(value.y) or not finite(value.z) then return nil end
    return table.freeze({ x = value.x, y = value.y, z = value.z })
end
local function measurement(sample)
    if not plain(sample) or type(sample.epoch) ~= "userdata"
        or not Identity.is_nonzero_u64(sample.serial) or not finite(sample.time) or sample.time < 0
        or not finite(sample.seconds) or sample.seconds <= 0 or math.abs(sample.seconds - 1 / 60) > 1e-7
        or not finite(sample.mass) or sample.mass <= 0 or not plain(sample.rotation) then return nil end
    local out = { epoch = sample.epoch, serial = sample.serial, time = sample.time, seconds = sample.seconds, mass = sample.mass }
    for _, name in ipairs(sample_vectors) do
        out[name] = vector_copy(sample[name])
        if not out[name] then return nil end
    end
    if out.inertia.x <= 0 or out.inertia.y <= 0 or out.inertia.z <= 0 then return nil end
    local rotation, norm = {}, 0
    for i = 1, 4 do
        local value = sample.rotation[i]
        if not finite(value) then return nil end
        rotation[i], norm = value, norm + value * value
    end
    if math.abs(norm - 1) > .0001 then return nil end
    out.rotation = table.freeze(rotation)
    return table.freeze(out)
end
local function same_measurement(a, b)
    local function same_number(x, y) return x == y and (x ~= 0 or 1 / x == 1 / y) end
    if a.serial ~= b.serial or not same_number(a.time, b.time) or a.seconds ~= b.seconds or a.mass ~= b.mass then return false end
    for _, name in ipairs(sample_vectors) do
        for _, axis in ipairs({ "x", "y", "z" }) do if not same_number(a[name][axis], b[name][axis]) then return false end end
    end
    for i = 1, 4 do if not same_number(a.rotation[i], b.rotation[i]) then return false end end
    return true
end
local function unchanged_sample(raw, measured)
    local current = measurement(raw)
    return current ~= nil and rawequal(current.epoch, measured.epoch) and same_measurement(current, measured)
end
local function retired_pair(s, body, session)
    for _, pair in ipairs(s.retired) do if rawequal(pair.body, body) and rawequal(pair.session, session) then return true end end
    return false
end
local function owner_facts(record, body)
    -- Exact normalized owner.read schema. Stable session/follow/context keys
    -- must originate at their real owners, not from per-read snapshot wrappers.
    if not plain(record) or record.available ~= true or type(body) ~= "userdata"
        or not rawequal(record.body, body) or not lifecycle_key(record.session) or not lifecycle_key(record.follow)
        or not lifecycle_key(record.context) then return nil end
    local facts = { available = true, body = body, session = record.session,
        follow = record.follow, context = record.context }
    for _, name in ipairs(owner_booleans) do
        if type(record[name]) ~= "boolean" then return nil end
        facts[name] = record[name]
    end
    return table.freeze(facts)
end
local function owner_clear(facts)
    return facts.body_current and facts.follow_current and facts.context_current and facts.support_available
        and facts.focused and not facts.menu_open and not facts.fall_stop
end
local function owner_unchanged(record, facts, body)
    local current = owner_facts(record, body)
    if not current or not rawequal(current.session, facts.session) or not rawequal(current.follow, facts.follow)
        or not rawequal(current.context, facts.context) then return false end
    for _, name in ipairs(owner_booleans) do if current[name] ~= facts[name] then return false end end
    return true
end
local function source_clean(frame)
    return plain(frame) and frame.input_ok == false and (frame.phase == "idle" or frame.phase == "complete")
        and frame.cleanup_pending == false and frame.cleanup_unknown == false and frame.lease_handle == nil
end
local function source_sample_valid(sample)
    if not plain(sample) or not integer(sample.user, 0, 3) or not integer(sample.packet, 0, MAX_HOP)
        or not Identity.is_nonzero_u64(sample.observation_serial) or not Identity.is_u64(sample.observed_ms)
        or not plain(sample.pad) or sample.pad.playstation ~= false
        or not plain(sample.pad.buttons) then return false end
    for _, name in ipairs(source_keys) do if not Identity.is_nonzero_u64(sample[name]) then return false end end
    for _, name in ipairs(pad_axes) do
        local value = sample.pad[name]
        local low = (name == "left_trigger" or name == "right_trigger") and 0 or -1
        if not finite(value) or value < low or value > 1 then return false end
    end
    for _, name in ipairs(pad_buttons) do if type(sample.pad.buttons[name]) ~= "boolean" then return false end end
    return true
end
local function source_admitted(frame, user)
    return plain(frame) and frame.input_ok == true and frame.phase == "capturing"
        and frame.cleanup_pending == false and frame.cleanup_unknown == false
        and type(frame.lease_handle) == "userdata" and integer(frame.generation, 0, MAX_SAFE)
        and type(frame.new_observation) == "boolean" and plain(frame.lease_state)
        and frame.lease_state.status == "active" and plain(frame.capture_state)
        and frame.capture_state.phase == "capturing" and frame.capture_state.quarantined == false
        and source_sample_valid(frame.sample) and frame.sample.user == user
end
local function source_identity(frame)
    local sample = frame.sample
    return table.freeze({ lease_handle = frame.lease_handle, generation = frame.generation, user = sample.user,
        sequence = sample.sequence, source_epoch = sample.source_epoch, context_generation = sample.context_generation })
end
local function same_source(a, b)
    return rawequal(a.lease_handle, b.lease_handle) and a.generation == b.generation and a.user == b.user
        and a.sequence == b.sequence and a.source_epoch == b.source_epoch and a.context_generation == b.context_generation
end
local function mapped_source_matches(mapped, frame)
    local current = frame.sample
    if not plain(mapped) or not same_source(mapped, source_identity(frame)) then return false end
    return mapped.observation_serial == current.observation_serial and mapped.observed_ms == current.observed_ms
        and mapped.packet == current.packet
end
local function controls_copy(mapped, frame, epoch, h, reserved)
    if not plain(mapped) or mapped.valid ~= true or mapped.submission_allowed ~= true
        or not rawequal(mapped.physics_epoch, epoch) or mapped.h ~= h or not mapped_source_matches(mapped.source, frame)
        or not plain(mapped.force_controls) or mapped.force_controls.enabled ~= true then return nil end
    local original, controls = mapped.force_controls, { enabled = true }
    for _, name in ipairs(positive_controls) do
        local value = original[name]
        if not finite(value) or value < 0 or value > 1 then return nil end
        controls[name] = value
    end
    for _, name in ipairs(signed_controls) do
        local value = original[name]
        if not finite(value) or math.abs(value) > 1 then return nil end
        controls[name] = value
    end
    for _, name in ipairs(boolean_controls) do
        if type(original[name]) ~= "boolean" then return nil end
        controls[name] = original[name]
    end
    if not integer(original.hop_event_id, 0, MAX_HOP) or (original.hop_event_id == 0 and original.hop_strength ~= 0)
        or (reserved and not original.rotation_reserved) then return nil end
    -- The input mapper cannot promote unavailable recovery/contact producers.
    if original.recovery_step_verified or original.contact_compliance_available
        or original.landing_contact_compliance_selected then return nil end
    controls.hop_event_id = original.hop_event_id
    if controls.hop_event_id > 0 then
        if not plain(mapped.hop) or mapped.hop.id ~= controls.hop_event_id
            or mapped.hop.strength ~= controls.hop_strength
            or not Identity.is_nonzero_u64(mapped.hop.observation_serial) then return nil end
    elseif mapped.hop ~= nil then return nil end
    return table.freeze(controls)
end
local function emit(s, epoch, controls)
    -- Raw records are retained unchanged. Only our own normalized facts and
    -- fixed-size copies are frozen; we never mutate/freeze a provider's record.
    return table.freeze({ submit_forces = controls ~= nil and s.armed == true and not s.force_stop_required,
        physics_epoch = epoch, force_controls = controls, force_stop_required = s.force_stop_required,
        lifecycle_token = s.lifecycle_token, permit_token = s.permit_token,
        body = s.binding and s.binding.body or nil, session = s.binding and s.binding.session or nil,
        phase = s.phase, reason = s.reason, owner_record = s.owner_record, owner_facts = s.owner_facts,
        body_record = s.body_record, body_sample = s.current_measured,
        source_frame = s.source_frame, mapping_record = s.mapping_record,
        stop_request = s.stop_request, stop_outcome = s.stop_outcome,
        stop_request_error = s.stop_request_error, stop_outcome_error = s.stop_outcome_error,
        source_cleanup_error = s.source_cleanup_error, mapping_error = s.mapping_error,
        owner_stop_confirmed = s.owner_stopped == true, source_cleanup_complete = source_clean(s.source_frame),
        cleanup_unknown = s.force_stop_required and (s.owner_stopped ~= true
            or not plain(s.source_frame) or s.source_frame.cleanup_unknown == true), unloaded = s.unloaded == true })
end
local function complete_if_possible(s)
    if s.force_stop_required and not s.busy and not s.stop_running and not s.unload_pending
        and not s.source_cleanup_running and s.owner_stopped and source_clean(s.source_frame) then
        if not retired_pair(s, s.binding.body, s.binding.session) then
            if #s.retired >= MAX_RETIRED then s.phase, s.reason = "cleanup_unknown", "retired owner capacity exhausted"; return end
            table.insert(s.retired, { body = s.binding.body, session = s.binding.session })
        end
        s.force_stop_required, s.phase, s.reason = false, "complete", "source and real owner cleanup confirmed"
    end
end
local function poll_owner_stop(s)
    local called, outcome, why, current = invoke(s, s.owner, "stop_state", false)
    s.stop_outcome = outcome
    if called then s.stop_outcome_error = nil
    else s.stop_outcome_error = reason(why, "owner stop outcome unavailable") end
    if current and called and plain(outcome) and outcome.available == true and outcome.stopped == true
        and s.binding and not retired_pair(s, s.binding.body, s.binding.session)
        and rawequal(outcome.body, s.binding.body) and rawequal(outcome.session, s.binding.session) then
        s.owner_stopped = true
    end
end
local function reset_mapping(s, why)
    local called, _, detail, current = invoke(s, s.mapping, "reset", true, why)
    if called then s.mapping_error = nil
    else s.mapping_error = reason(detail, "mapping reset unavailable") end
    return called, current
end
local function stop(s, why)
    invalidate_permit(s)
    s.guard = {}
    -- A completed unarmed lifecycle already has real terminal proof. Repeated
    -- stop is idempotent; only an explicit new arm creates a new owner duty.
    if s.phase == "complete" and not s.armed and not s.force_stop_required then return end
    if not s.force_stop_required then
        s.lifecycle_token, s.armed, s.force_stop_required = table.freeze({}), false, true
        s.phase, s.reason, s.owner_stopped = "stopping", reason(why, "stopped"), false
    else s.armed = false end
    if s.stop_running or s.source_cleanup_running then return end
    s.stop_running = true
    -- Set the latch before any callback. Neither a request Boolean nor a source
    -- release proves body/follow/park completion. Cleanup calls are independent.
    if not s.stop_requested then
        s.stop_requested = true
        local called, outcome, detail = invoke(s, s.owner, "request_stop", false, s.reason,
            s.binding and s.binding.body or nil, s.bound_sample)
        s.stop_request = outcome
        if called then s.stop_request_error = nil
        else s.stop_request_error = reason(detail, "owner stop request unavailable") end
    end
    s.source_cleanup_running = true
    local called, frame, detail, current = invoke(s, s.source, "stop", true, s.reason)
    s.source_cleanup_running = false
    if called and current and plain(frame) then s.source_frame = frame
    else s.source_frame = nil; s.source_cleanup_error = reason(detail, "source stop unavailable") end
    reset_mapping(s, s.reason)
    poll_owner_stop(s)
    s.stop_running = false
    complete_if_possible(s)
end
local function invalidated(s, epoch)
    -- A callback may stop/unload us before returning. Request source cleanup
    -- again so a late adopted handle is retained/drained; never issue its permit.
    if s.force_stop_required then stop(s, s.reason) end
    return emit(s, epoch)
end
local function bind_measurement(s, body, sample, measured, facts)
    local old = s.binding
    if old and (not rawequal(old.body, body) or not rawequal(old.session, facts.session)
        or not rawequal(old.follow, facts.follow) or not rawequal(old.context, facts.context)) then
        return nil, "owner identity replaced"
    end
    local previous = s.measured
    if not old then
        if not facts.body_current then return nil, "initial body owner is not current" end
        if retired_pair(s, body, facts.session) then return nil, "retired body/session cannot be reused" end
        local history = s.history[body]
        if history then
            local order = Identity.compare(measured.serial, history.serial)
            if order < 0 or (order == 0 and not same_measurement(measured, history)) then return nil, "old body sample replayed" end
            if order > 0 and measured.time <= history.time then return nil, "body time regressed" end
        end
        s.binding = { body = body, session = facts.session, follow = facts.follow, context = facts.context }
        s.measured, s.bound_sample, s.history[body] = measured, measured, measured
        return "anchor"
    end
    local order = Identity.compare(measured.serial, previous.serial)
    if order < 0 then return nil, "body serial regressed" end
    if order == 0 then
        if not same_measurement(measured, previous) then return nil, "repeated body contents changed" end
        s.bound_sample = measured -- Keep this actual read's epoch in an owned copy.
        return "duplicate"
    end
    if measured.time <= previous.time or measured.seconds ~= previous.seconds then return nil, "body time or step changed" end
    -- No skipped-contact reconstruction or guessed h. A separate actual command
    -- ledger must authorize any N+2 adoption; this boundary admits only N+1.
    local advance = Identity.bounded_delta(measured.serial, previous.serial, 1)
    s.history[body] = measured
    if advance ~= 1 then return nil, "unsupported body step gap" end
    if math.abs(measured.time - previous.time - measured.seconds) > 1e-6 then return nil, "body elapsed time mismatched" end
    s.measured, s.bound_sample = measured, measured
    return "successor"
end
local function drain(s, now)
    s.source_cleanup_running = true
    local called, frame, detail, current = invoke(s, s.source, "step", true, now, { allow_acquire = false, allow_drive = false })
    s.source_cleanup_running = false
    if called and current and plain(frame) then s.source_frame = frame
    else s.source_frame = nil; s.source_cleanup_error = reason(detail, "source drain unavailable") end
    poll_owner_stop(s)
    if plain(s.source_frame) and s.source_frame.cleanup_unknown == true then s.phase = "cleanup_unknown" end
    return emit(s)
end
local function step(s, body, sample, now)
    if s.force_stop_required then return drain(s, now) end
    if not s.armed or s.unloaded then return emit(s) end
    if not wall_time(now) or (s.last_now and now < s.last_now) then
        stop(s, "invalid or regressed caller clock"); return emit(s)
    end
    s.last_now = now
    local measured = measurement(sample)
    if type(body) ~= "userdata" or not measured then stop(s, "body measurement unavailable"); return emit(s) end
    s.body_record, s.current_measured = sample, measured
    local called, record, detail, current = invoke(s, s.owner, "read", false, body, sample)
    if not current then return invalidated(s, measured.epoch) end
    s.owner_record, s.owner_facts = record, nil
    if not called then stop(s, reason(detail, "owner read unavailable")); return emit(s, measured.epoch) end
    if not unchanged_sample(sample, measured) then stop(s, "body record changed during owner read"); return emit(s, measured.epoch) end
    local facts = owner_facts(record, body)
    s.owner_facts = facts
    if not facts then stop(s, "owner facts unavailable"); return emit(s, measured.epoch) end
    local body_kind, body_issue = bind_measurement(s, body, sample, measured, facts)
    if not body_kind then stop(s, body_issue); return emit(s, measured.epoch) end
    if not owner_clear(facts) then stop(s, "owner body/follow/context/support/focus/menu/fall gate lost"); return emit(s, measured.epoch) end
    local source_called, frame, source_detail, source_current = invoke(s, s.source, "step", true, now,
        { allow_acquire = true, allow_drive = true })
    if not source_current then return invalidated(s, measured.epoch) end
    s.source_frame = frame
    if not unchanged_sample(sample, measured) or not owner_unchanged(record, facts, body) then
        stop(s, "body or owner record changed during source step"); return emit(s, measured.epoch)
    end
    if not source_called or not plain(frame) then
        stop(s, reason(source_detail, "source step unavailable")); return emit(s, measured.epoch)
    end
    if frame.input_ok ~= true then
        if not s.had_input and frame.input_ok == false and waiting_source[frame.phase]
            and frame.cleanup_pending == false and frame.cleanup_unknown == false then
            s.phase, s.reason = "waiting_input", reason(frame.reason, "waiting for actual input capture")
            return emit(s, measured.epoch)
        end
        stop(s, "selected source input lost"); return emit(s, measured.epoch)
    end
    if not source_admitted(frame, s.user) then stop(s, "invalid admitted source frame"); return emit(s, measured.epoch) end
    local key = source_identity(frame)
    if s.source_key and not same_source(key, s.source_key) then stop(s, "selected source identity replaced"); return emit(s, measured.epoch) end
    s.source_key, s.had_input = key, true
    -- Observe even on a duplicate body; Mapping deduplicates actual source
    -- ordinals and stages genuine zero-ms press/release without advancing forces.
    local observed, mapped, mapping_detail, mapping_current = invoke(s, s.mapping, "observe", true, frame,
        { grounded = facts.grounded, focused = facts.focused, menu_open = facts.menu_open,
            rotation_reserved = facts.rotation_reserved })
    if not mapping_current then return invalidated(s, measured.epoch) end
    s.mapping_record = mapped
    if not unchanged_sample(sample, measured) or not owner_unchanged(record, facts, body) then
        stop(s, "body or owner record changed during mapping observation"); return emit(s, measured.epoch)
    end
    if not observed or not plain(mapped) or mapped.valid ~= true or type(mapped.active) ~= "boolean"
        or type(mapped.new_observation) ~= "boolean" or not mapped_source_matches(mapped.source, frame) then
        stop(s, reason(mapping_detail, "mapping observation invalidated")); return emit(s, measured.epoch)
    end
    if body_kind ~= "successor" then
        s.phase, s.reason = "observing", body_kind == "anchor" and "first body sample anchors only" or "duplicate body; input observation staged"
        return emit(s, measured.epoch)
    end
    local controlled, controls, controls_detail, controls_current = invoke(s, s.mapping, "controls", true,
        { physics_epoch = measured.epoch, h = measured.seconds, grounded = facts.grounded, rotation_reserved = facts.rotation_reserved })
    if not controls_current then return invalidated(s, measured.epoch) end
    s.mapping_record = controls
    if not unchanged_sample(sample, measured) or not owner_unchanged(record, facts, body) then
        stop(s, "body or owner record changed during mapping controls"); return emit(s, measured.epoch)
    end
    if controlled and plain(controls) and controls.submission_allowed == false and soft_mapping[controls.issue] then
        s.phase, s.reason = "waiting_neutral", controls.issue
        return emit(s, measured.epoch)
    end
    local normalized = controlled and controls_copy(controls, frame, measured.epoch, measured.seconds, facts.rotation_reserved) or nil
    if not normalized then stop(s, reason(controls_detail, "mapping controls invalidated")); return emit(s, measured.epoch) end
    s.phase, s.reason = "riding", "current source and exact advancing body step admitted"
    return emit(s, measured.epoch, normalized)
end

local function flush_unload(s)
    if not s.unload_pending or s.unload_called or s.busy or s.stop_running or s.source_cleanup_running then return end
    s.unload_pending, s.unload_called, s.source_cleanup_running = false, true, true
    local called, frame, detail, current = invoke(s, s.source, "unload", true)
    s.source_cleanup_running = false
    if called and current and plain(frame) then
        s.source_frame = frame
        if not source_clean(frame) then
            s.force_stop_required = true
            s.phase, s.reason = frame.cleanup_unknown == true and "cleanup_unknown" or "stopping", "source unload still unresolved"
        end
    else
        s.source_frame, s.force_stop_required = nil, true
        s.phase, s.reason = "cleanup_unknown", "source unload outcome unavailable or superseded"
        s.source_cleanup_error = reason(detail, s.reason)
    end
    complete_if_possible(s)
end

function RideInput.new(source, mapping, owner)
    -- Inert construction. The owner methods use dot-call arguments; source and
    -- mapping use their documented colon methods. No reskate API is called here.
    -- Freeze the instance before protecting its per-instance metatable, as
    -- required by the vendored Luau table.freeze implementation.
    local instance_metatable = { __index = RideInput }
    local object = setmetatable({}, instance_metatable)
    states[object] = { source = source, mapping = mapping, owner = owner, guard = {}, phase = "idle",
        reason = "not armed", force_stop_required = false, history = setmetatable({}, { __mode = "k" }),
        retired = {}, lifecycle_token = table.freeze({}), permit_token = table.freeze({}) }
    table.freeze(object)
    instance_metatable.__metatable = "locked"
    table.freeze(instance_metatable)
    return object
end
function RideInput:arm(user, now)
    local s = states[self]
    if s.busy or s.stop_running or s.source_cleanup_running or s.unloaded or s.armed or s.force_stop_required then return false, "lifecycle unresolved" end
    if #s.retired >= MAX_RETIRED then return false, "retired owner capacity exhausted" end
    if not integer(user, 0, 3) or not wall_time(now) or (s.last_now and now < s.last_now) then
        return false, "invalid slot or caller clock"
    end
    s.busy = true
    invalidate_permit(s)
    local preflight_guard = s.guard
    if not ready(s.source, { "arm", "step", "stop", "status", "unload" })
        or not ready(s.mapping, { "observe", "controls", "reset", "status", "retire_hop" })
        or not ready(s.owner, { "read", "request_stop", "stop_state" }) then
        s.busy = false; flush_unload(s); return false, "real providers unavailable"
    end
    if preflight_guard ~= s.guard or s.force_stop_required or s.unloaded or s.unload_pending then
        s.busy = false; flush_unload(s); return false, "invalidated during provider lookup"
    end
    local called, frame, _, current = invoke(s, s.source, "status", true)
    s.source_frame = frame
    if not called or not current or not source_clean(frame) then
        s.busy = false
        flush_unload(s)
        if not current then return false, "invalidated during source status" end
        return false, "source cleanup unresolved"
    end
    local reset, reset_current = reset_mapping(s, "explicit arm")
    if not reset or not reset_current or s.force_stop_required or s.mapping_error or s.unloaded or s.unload_pending then
        s.busy = false; flush_unload(s); return false, "mapping reset unavailable or invalidated"
    end
    s.guard, s.lifecycle_token, s.armed, s.user, s.last_now = {}, table.freeze({}), true, user, now
    s.phase, s.reason = "armed", "waiting for actual owner and input facts"
    s.binding, s.bound_sample, s.measured, s.source_key, s.had_input = nil, nil, nil, nil, false
    s.owner_record, s.owner_facts, s.mapping_record = nil, nil, nil
    s.body_record, s.current_measured = nil, nil
    s.stop_request, s.stop_outcome, s.stop_requested, s.owner_stopped = nil, nil, false, false
    s.stop_request_error, s.stop_outcome_error, s.source_cleanup_error = nil, nil, nil
    local armed, accepted, detail, unchanged = invoke(s, s.source, "arm", true, user, now)
    s.busy = false
    if not unchanged then invalidated(s); flush_unload(s); return false, "invalidated during source arm" end
    if not armed or accepted ~= true then
        -- A callback failure may have left native duty. Do not infer a clean
        -- source or an absent owner from a failed request.
        stop(s, reason(detail, "source arm refused"))
        flush_unload(s)
        return false, s.reason
    end
    return true
end
function RideInput:step(body, sample, now)
    local s = states[self]
    invalidate_permit(s)
    if s.busy or s.stop_running or s.source_cleanup_running then stop(s, "reentrant step refused"); return emit(s) end
    s.busy = true
    local ok, result = pcall(step, s, body, sample, now)
    if not ok then stop(s, "malformed provider output or lifecycle error") end
    s.busy = false
    flush_unload(s)
    complete_if_possible(s)
    if not ok or s.force_stop_required then return emit(s, ok and result.physics_epoch or nil) end
    -- Completion may have changed the diagnostic phase after a drain call.
    if s.phase == "complete" then return emit(s) end
    return result
end
function RideInput:stop(why)
    local s = states[self]
    stop(s, why)
    flush_unload(s)
    return emit(s)
end
function RideInput:status()
    -- Diagnostic only: never return a cached permit or invent another epoch.
    return emit(states[self])
end
function RideInput:unload()
    local s = states[self]
    invalidate_permit(s)
    if s.unload_called or s.unload_pending then return emit(s) end
    s.unloaded, s.unload_pending = true, true
    stop(s, "unload requested; actual owner and native VM cleanup remain authoritative")
    flush_unload(s)
    complete_if_possible(s)
    return emit(s)
end
function RideInput:retire_hop(id, disposition)
    local s = states[self]
    if s.busy or s.stop_running or s.source_cleanup_running or not s.armed or s.force_stop_required or s.unloaded then return false, "riding lifecycle unavailable" end
    if not integer(id, 1, MAX_HOP) or (disposition ~= "accepted" and disposition ~= "cancelled" and disposition ~= "uncertain") then
        return false, "invalid hop retirement"
    end
    s.busy = true
    invalidate_permit(s)
    local called, accepted, detail, current = invoke(s, s.mapping, "retire_hop", true, id, disposition)
    s.busy = false
    if not current then invalidated(s); flush_unload(s); return false, "invalidated during hop retirement" end
    if not called then stop(s, "hop retirement outcome unavailable"); flush_unload(s); return false, "hop retirement callback failed" end
    if accepted ~= true then
        if accepted ~= false then stop(s, "hop retirement outcome unknown"); flush_unload(s) end
        return false, reason(detail, "hop retirement refused")
    end
    -- This is an explicit local ledger decision, never proof of application.
    if disposition == "uncertain" then stop(s, "native hop outcome uncertain"); flush_unload(s) end
    return true
end
return table.freeze(RideInput)

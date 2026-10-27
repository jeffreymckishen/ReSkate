-- Inactive pure adapter: measured frames enter; only model targets leave.
-- The ride coordinator owns every query, lease, body and physical effect.
local Tricks = require("./tricks")
local motions = require("./motions")
local catalog = require("./catalog")
local Frame = require("./frame_identity")
local M = require("./force_math")
local Identity = require("./lease_identity")
local Runtime = {}
local MAX = 9007199254740991
local scalar_source = {"generation", "user", "sequence", "source_epoch", "context_generation",
    "observation_serial", "observed_ms", "packet"}
local settings_names = {"bar_seconds", "tail_seconds", "catch_window", "catch_blend", "landing_tolerance",
    "max_sample_seconds", "max_yaw_rate", "max_air_seconds", "landing_settle_seconds", "landing_gap_seconds",
    "minimum_body_up_alignment", "minimum_support_up_alignment", "maximum_closing_speed"}
local target_numbers = {"barspin", "tailwhip", "movement_bike_pitch", "movement_bike_roll", "movement_crank_angle",
    "phase", "progress", "release_left_hand", "release_right_hand", "release_left_foot", "release_right_foot"}
local state_bools = {"airborne", "landing_pending", "bar_rotating", "tail_rotating", "bar_waiting_catch",
    "tail_waiting_catch", "bar_caught", "tail_caught", "movement_holding", "movement_recovering", "movement_caught"}
local event_bools = {"took_off", "landed", "combo_landed", "failed", "canceled", "bar_caught", "tail_caught", "movement_caught"}
local event_numbers = {"barspins", "tailwhips", "spin_half_turns", "units", "movements", "front_flips", "back_flips", "barrel_rolls"}
local detail_numbers = {"air_seconds", "spin_radians", "flip_radians", "roll_radians"}
local detail_fields = {"air_seconds", "spin_radians", "flip_radians", "roll_radians", "sequence", "overflow", "fakie_takeoff", "landing"}
local function plain(v) return type(v) == "table" and getmetatable(v) == nil end
local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function integer(v, lo, hi) return finite(v) and v >= lo and v <= hi and v % 1 == 0 end
local function direction(v) return v == "none" or v == "left" or v == "right" end
local function issue(v) return type(v) == "string" and #v > 0 and #v <= 100 and v or "cancelled" end
local function array(v, bound)
    if not plain(v) then return nil end
    local out = {}
    for i = 1, 3 do local n = rawget(v, i); if not finite(n) or math.abs(n) > bound then return nil end; out[i] = n end
    return out
end
local function source_matches(a, b, handles)
    if not plain(a) or not plain(b) then return false end
    if handles and not rawequal(rawget(a, "lease_handle"), b.lease_handle) then return false end
    for _, name in ipairs(scalar_source) do if rawget(a, name) ~= b[name] then return false end end
    return true
end
local function same_action_namespace(a, b)
    return rawequal(a.lease_handle, b.lease_handle) and a.generation == b.generation and a.user == b.user
        and a.sequence == b.sequence and a.source_epoch == b.source_epoch and a.context_generation == b.context_generation
end
local function actions_copy(raw, frame)
    if not plain(raw) or rawget(raw, "active") ~= true or not rawequal(rawget(raw, "physics_epoch"), frame.physics_epoch)
        or rawget(raw, "h") ~= frame.seconds or not source_matches(rawget(raw, "source"), frame.source, true)
        or not direction(rawget(raw, "handlebar")) or not direction(rawget(raw, "tailwhip"))
        or not catalog.valid(rawget(raw, "movement")) or type(rawget(raw, "bar_neutral")) ~= "boolean"
        or type(rawget(raw, "rear_neutral")) ~= "boolean" then return nil end
    return {active = true, handlebar = raw.handlebar, tailwhip = raw.tailwhip, movement = raw.movement,
        bar_neutral = raw.bar_neutral, rear_neutral = raw.rear_neutral,
        observation_serial = frame.source.observation_serial}
end
local function same_actions(a, b)
    return a.handlebar == b.handlebar and a.tailwhip == b.tailwhip and a.movement == b.movement
        and a.bar_neutral == b.bar_neutral and a.rear_neutral == b.rear_neutral
end
local function same_number(a, b) return a == b and (a ~= 0 or 1 / a == 1 / b) end
local function measured_continuity(previous, current)
    if not previous or not rawequal(previous.body_handle, current.body_handle) then return nil end
    -- Source/gate changes are cancellation facts. They cannot waive chronology
    -- or relabel a consumed body measurement as another model update.
    local order = Identity.compare(current.serial, previous.serial)
    if order < 0 then return {kind = "invalid", reason = "body_serial_regressed"} end
    if order == 0 then
        if not same_number(current.time, previous.time) or not same_number(current.seconds, previous.seconds)
            or not same_number(current.body.mass, previous.body.mass) then
            return {kind = "invalid", reason = "body_duplicate_changed"}
        end
        for _, name in ipairs({"inertia_body", "orientation", "center_of_mass", "linear_velocity", "angular_velocity"}) do
            for i = 1, name == "orientation" and 4 or 3 do
                if not same_number(current.body[name][i], previous.body[name][i]) then
                    return {kind = "invalid", reason = "body_duplicate_changed"}
                end
            end
        end
        return {kind = "duplicate", physical_elapsed = 0}
    end
    if rawequal(previous.physics_epoch, current.physics_epoch) then return {kind = "invalid", reason = "read_credential_relabelled"} end
    local elapsed = current.time - previous.time
    if not finite(elapsed) or elapsed <= 0 then return {kind = "invalid", reason = "physical_time_regressed"} end
    if not same_number(current.seconds, previous.seconds) then return {kind = "invalid", reason = "physical_step_changed"} end
    if Identity.bounded_delta(current.serial, previous.serial, 1) ~= 1 then return {kind = "gap", reason = "body_serial_gap", physical_elapsed = elapsed} end
    if math.abs(elapsed - current.seconds) > 1e-6 then return {kind = "invalid", reason = "physical_elapsed_mismatch"} end
    return {kind = "successor", physical_elapsed = elapsed}
end
local function support_copy(raw, frame)
    if not plain(raw) or rawget(raw, "valid") ~= true or not plain(rawget(raw, "binding"))
        or not plain(rawget(raw, "frame")) or not plain(rawget(raw, "query")) then return nil, "invalid_contact_packet" end
    local binding, measured, query = raw.binding, raw.frame, raw.query
    if not rawequal(rawget(binding, "body_handle"), frame.body_handle)
        or not rawequal(rawget(binding, "physics_epoch"), frame.physics_epoch)
        or not rawequal(rawget(binding, "lease_handle"), frame.source.lease_handle)
        or rawget(measured, "serial") ~= frame.serial or rawget(measured, "time") ~= frame.time
        or rawget(measured, "seconds") ~= frame.seconds or not source_matches(rawget(measured, "source"), frame.source, false) then
        return nil, "contact_frame_mismatch"
    end
    local s = rawget(raw, "support")
    if not plain(s) or rawget(s, "known") ~= true or rawget(s, "grounded_known") ~= true
        or type(rawget(s, "grounded")) ~= "boolean" or rawget(s, "provenance") ~= "measured_support" then
        return nil, "physical_support_unqualified"
    end
    -- Geometry hit/clear is deliberately insufficient. Actual Contact.decode
    -- currently returns support unknown, so it remains gated here.
    if rawget(query, "epoch_matches") ~= true or rawget(query, "accounting_known") ~= true
        or rawget(query, "budget_exhausted") ~= false or rawget(query, "local_actor_excluded") ~= true
        or rawget(query, "owned_bodies_excluded") ~= true then return nil, "contact_query_unqualified" end
    local out = {grounded = s.grounded}
    if out.grounded then
        out.point, out.normal, out.surface_velocity = array(rawget(s, "point"), 1e6), array(rawget(s, "normal"), 2), array(rawget(s, "surface_velocity"), 1e5)
        if not out.point or not out.normal or not out.surface_velocity
            or math.abs(M.dot(out.normal, out.normal) - 1) > .0001 then return nil, "landing_quality_unavailable" end
    end
    return out
end
local function yaw(v)
    if not M.vec(v, 1e8) or v[1] * v[1] + v[3] * v[3] <= 1e-8 then return nil end
    return math.atan2(v[1], v[3])
end
local function closing(body, support)
    local relative = M.sub(M.point_velocity(body, support.point), support.surface_velocity)
    local value = math.max(0, -M.dot(relative, support.normal))
    return finite(value) and value <= 1e6 and value or nil
end
local function target_copy(t)
    if not plain(t) or rawget(t, "valid") ~= true or rawget(t, "scope") ~= "model_target_only"
        or rawget(t, "realized") ~= false or rawget(t, "pose_provenance") ~= "authored_motions_policy"
        or not catalog.valid(rawget(t, "movement_id")) then return nil end
    local out = {valid = true, scope = t.scope, realized = false, pose_provenance = t.pose_provenance, movement_id = t.movement_id}
    for _, name in ipairs(target_numbers) do
        local n = rawget(t, name); if not finite(n) or math.abs(n) > 10000 then return nil end; out[name] = n
    end
    for _, name in ipairs({"phase", "progress", "release_left_hand", "release_right_hand", "release_left_foot", "release_right_foot"}) do
        if out[name] < 0 or out[name] > 1 then return nil end
    end
    for _, name in ipairs({"bar_neutral", "rear_neutral"}) do
        if type(rawget(t, name)) ~= "boolean" then return nil end; out[name] = t[name]
    end
    return out
end
local function model_state(s)
    if not plain(s) or not catalog.valid(rawget(s, "movement_id")) then return nil end
    local out = {scope = "model_state_only", realized = false, movement_id = s.movement_id}
    for _, name in ipairs(state_bools) do if type(rawget(s, name)) ~= "boolean" then return nil end; out[name] = s[name] end
    for _, name in ipairs({"pending_units", "pending_barspins", "pending_tailwhips", "pending_movements"}) do
        if not integer(rawget(s, name), 0, MAX) then return nil end; out[name] = s[name]
    end
    return out
end
local function event_detail(e, out)
    for _, name in ipairs(detail_numbers) do
        local n = rawget(e, name); if not finite(n) then return false end; out[name] = n
    end
    if out.air_seconds < 0 or out.air_seconds > 30 or type(rawget(e, "fakie_takeoff")) ~= "boolean"
        or type(rawget(e, "overflow")) ~= "boolean" then return false end
    local rows = rawget(e, "sequence")
    if not plain(rows) then return false end
    local count = 0
    for key in pairs(rows) do
        count += 1
        if count > 16 or not integer(key, 1, 16) then return false end
    end
    if e.overflow and count ~= 16 then return false end
    out.fakie_takeoff, out.overflow, out.sequence = e.fakie_takeoff, e.overflow, {}
    local previous = 0
    for i = 1, count do
        local row = rawget(rows, i)
        if not plain(row) then return false end
        local kind, id, dir = rawget(row, "kind"), rawget(row, "id"), rawget(row, "dir")
        local started, finished, hold = rawget(row, "start"), rawget(row, "finish"), rawget(row, "hold")
        if not integer(id, 0, 79) or not catalog.valid(id) or id == catalog.none
            or not integer(dir, -1, 1) or not finite(started) or not finite(finished) or not finite(hold)
            or started < previous or finished <= started or finished > out.air_seconds + 1e-9
            or hold < 0 or hold > finished - started + 1e-9 then return false end
        local entry = motions.find(id)
        if kind == "bar" then
            if id ~= (dir == -1 and 34 or dir == 1 and 44 or -1) or hold ~= 0 then return false end
        elseif kind == "tail" then
            if id ~= (dir == -1 and 56 or dir == 1 and 52 or -1) or hold ~= 0 then return false end
        elseif kind == "move" then
            if not entry or catalog.legacy_rotation(id) or dir ~= entry.direction
                or (entry.motion ~= "pose" and hold ~= 0) then return false end
        else return false end
        previous = started
        out.sequence[i] = {kind = kind, id = id, dir = dir, start = started, finish = finished, hold = hold}
    end
    local landing = rawget(e, "landing")
    if landing ~= nil then
        if not plain(landing) then return false end
        local up, heading, closing = rawget(landing, "body_up"), rawget(landing, "heading_cos"), rawget(landing, "closing")
        if not finite(up) or math.abs(up) > 1.000001 or not finite(heading) or math.abs(heading) > 1
            or not finite(closing) or closing < 0 or closing > 1e6 then return false end
        out.landing = {body_up = up, heading_cos = heading, closing = closing}
    end
    return true
end
local function model_events(e)
    if not plain(e) then return nil end
    local out = {scope = "model_events_only", realized = false}
    for _, name in ipairs(event_bools) do if type(rawget(e, name)) ~= "boolean" then return nil end; out[name] = e[name] end
    for _, name in ipairs(event_numbers) do if not integer(rawget(e, name), 0, MAX) then return nil end; out[name] = e[name] end
    if type(rawget(e, "failure")) ~= "string" or #e.failure > 100 then return nil end
    out.failure = e.failure
    if out.landed then
        if not event_detail(e, out) then return nil end
    else
        -- A partial or misplaced detail packet must not look like a scored air.
        for _, name in ipairs(detail_fields) do if rawget(e, name) ~= nil then return nil end end
    end
    return out
end
local function public_copy(raw)
    if not plain(raw) then return nil end
    local out = {scope = "model_adapter_only", realized = false}
    for _, name in ipairs({"valid", "fresh", "advanced"}) do if type(rawget(raw, name)) ~= "boolean" then return nil end; out[name] = raw[name] end
    out.issue = issue(rawget(raw, "issue"))
    if rawget(raw, "serial") ~= nil then if not Identity.is_nonzero_u64(raw.serial) then return nil end; out.serial = raw.serial end
    if rawget(raw, "time") ~= nil then if not finite(raw.time) or raw.time < 0 then return nil end; out.time = raw.time end
    if rawget(raw, "visual_targets") ~= nil then out.visual_targets = target_copy(raw.visual_targets); if not out.visual_targets then return nil end end
    if rawget(raw, "model_state") ~= nil then out.model_state = model_state(raw.model_state); if not out.model_state then return nil end end
    if rawget(raw, "model_events") ~= nil then out.model_events = model_events(raw.model_events); if not out.model_events then return nil end end
    if rawget(raw, "requests") ~= nil then
        if not plain(raw.requests) or type(rawget(raw.requests, "rotation_reserved")) ~= "boolean" then return nil end
        out.requests = {rotation_reserved = raw.requests.rotation_reserved, scope = "model_request_only"}
    end
    return out
end
function Runtime.public_snapshot(result) return public_copy(result) end

function Runtime.new(settings)
    assert(settings == nil or plain(settings), "plain trick settings required")
    local proposed = {}
    for _, name in ipairs(settings_names) do
        local value = settings and rawget(settings, name)
        assert(value == nil or finite(value), "finite trick settings required")
        proposed[name] = value
    end
    local model = Tricks.new(proposed)
    local limits = model:settings()
    local T = {generation = 0, busy = false, needs_prime = true, updates = 0, result = {valid = false, fresh = false, advanced = false,
        scope = "model_adapter_only", realized = false, issue = "not_observed"}}
    local object = {}
    local function rejected(why, frame, fresh)
        return {valid = false, fresh = fresh == true, advanced = false, scope = "model_adapter_only", realized = false,
            issue = issue(why), serial = frame and frame.serial, time = frame and frame.time}
    end
    local function cancel(why)
        T.generation += 1; T.approach = nil; T.impact = nil; T.needs_prime = true
        if not T.cancelling then T.cancelling = true; pcall(model.cancel, model); T.cancelling = false end
        T.result = rejected(why, T.last, false)
    end
    local function binding(frame)
        local source = {lease_handle = frame.source.lease_handle}
        for _, name in ipairs(scalar_source) do source[name] = frame.source[name] end
        return {body_handle = frame.body_handle, physics_epoch = frame.physics_epoch, lease_handle = frame.source.lease_handle,
            serial = frame.serial, time = frame.time, seconds = frame.seconds, source = source}
    end
    local function advance(raw, contact, action_raw)
        local frame, why = Frame.copy(raw)
        if not frame then cancel(why); return rejected(why, nil, false) end
        local measured = measured_continuity(T.last, frame)
        if measured and measured.kind == "invalid" then
            cancel(measured.reason); return rejected(measured.reason, frame, false)
        end
        local continuity = Frame.classify(T.last, frame)
        if frame.fresh and continuity.kind ~= "invalid" and continuity.kind ~= "not_fresh" and T.last
            and not same_action_namespace(T.last.source, frame.source) then
            -- Observation ordinals belong to this exact source namespace.
            -- Clear the old namespace before any accepted gate/gap anchor can
            -- hide its replacement. Measured chronology has already passed.
            T.action_seen = nil; T.action_consumed = nil
        end
        if not frame.fresh or not frame.gates.focused or frame.gates.menu_open then
            if frame.fresh then
                if continuity.kind ~= "invalid" and continuity.kind ~= "not_fresh" then T.last = frame end
            end
            cancel("owner_or_focus_gate"); return rejected("owner_or_focus_gate", frame, false)
        end
        if measured and measured.kind == "gap" and continuity.kind ~= "invalid" then continuity = measured end
        if continuity.kind == "invalid" or continuity.kind == "gap" or continuity.kind == "not_fresh" then
            -- A forward measured gap cancels the old attempt. Anchoring this
            -- known sample does not fill the missing interval or advance policy.
            if continuity.kind == "gap" then T.last = frame end
            cancel(continuity.reason); return rejected(continuity.reason, frame, false)
        end
        local identity_prime = continuity.kind == "prime" or continuity.kind == "changed"
        local prime = T.needs_prime or identity_prime
        if identity_prime then cancel("identity_prime"); T.action_seen = nil end
        local duplicate = measured and measured.kind == "duplicate" or continuity.kind == "duplicate"
        local actions = actions_copy(action_raw, frame)
        if not actions then cancel("invalid_actions"); return rejected("invalid_actions", frame, false) end
        if T.action_seen and T.action_seen.observation_serial == actions.observation_serial and not same_actions(T.action_seen, actions) then
            cancel("actions_duplicate_changed"); return rejected("actions_duplicate_changed", frame, false)
        end
        T.action_seen = actions
        local support, contact_why = support_copy(contact, frame)
        if not support then T.last = frame; cancel(contact_why); return rejected(contact_why, frame, not duplicate) end
        if duplicate then
            T.last = frame
            return {valid = true, fresh = false, advanced = false, scope = "model_adapter_only", realized = false,
                issue = "duplicate_frame", serial = frame.serial, time = frame.time, binding = binding(frame)}
        end
        T.last = frame -- Consume this fresh measurement before any model callback.
        if prime then
            cancel("identity_prime"); T.action_consumed = nil; T.action_seen = actions
            if not support.grounded or not actions.bar_neutral or not actions.rear_neutral then
                return rejected("neutral_ground_prime_required", frame, true)
            end
            T.needs_prime = false
        end
        local seconds = measured and measured.physical_elapsed or continuity.physical_elapsed or frame.seconds
        if not finite(seconds) or seconds <= 0 or seconds > limits.max_sample_seconds + 1e-9 then
            cancel("physical_sample_gap"); return rejected("physical_sample_gap", frame, true)
        end
        local before = model:state()
        local body_forward = M.turn(frame.body.orientation, {0, 0, 1})
        local body_yaw = yaw(body_forward)
        local travel_yaw = yaw(frame.body.linear_velocity)
        local quality
        if support.grounded and (before.airborne or before.landing_pending) then
            if not T.impact then
                local approach = T.approach
                if not approach or frame.time - approach.time <= 0 or frame.time - approach.time > limits.max_sample_seconds + 1e-9 then
                    cancel("preimpact_quality_unavailable"); return rejected("preimpact_quality_unavailable", frame, true)
                end
                local heading = yaw(M.sub(approach.body.linear_velocity, support.surface_velocity))
                local pre, post = closing(approach.body, support), closing(frame.body, support)
                if not heading or not pre or not post then cancel("preimpact_quality_unavailable"); return rejected("preimpact_quality_unavailable", frame, true) end
                T.impact = {time = frame.time, travel_yaw = heading, closing = math.max(pre, post)}
            end
            local post = closing(frame.body, support)
            if not body_yaw or not post or frame.time - T.impact.time > .2 + limits.landing_settle_seconds + limits.landing_gap_seconds then
                cancel("landing_quality_unavailable"); return rejected("landing_quality_unavailable", frame, true)
            end
            T.impact.closing = math.max(T.impact.closing, post)
            travel_yaw = T.impact.travel_yaw
            quality = {body_up_alignment = M.dot(M.turn(frame.body.orientation, {0, 1, 0}), support.normal),
                support_up_alignment = support.normal[2], closing_normal_speed = T.impact.closing}
        end
        if not support.grounded then
            -- A new unsupported interval is a new measured approach. Recontact
            -- must not inherit an earlier gentle impact or travel heading.
            T.impact = nil
            T.approach = {time = frame.time, body = frame.body}
        end
        local new_actions = not prime and T.action_consumed ~= actions.observation_serial
        T.action_consumed = actions.observation_serial
        local input = {enabled = true, owner = "measured-trick-model", device = frame.source.user, grounded = support.grounded,
            barspin = new_actions and actions.handlebar or "none", tailwhip = new_actions and actions.tailwhip or "none",
            movement = new_actions and actions.movement or catalog.none, bar_neutral = actions.bar_neutral, rear_neutral = actions.rear_neutral,
            -- Compatibility-only finite headings while airborne: full quaternion
            -- tracks vertical flips. They never qualify a landing or claim heading.
            body_yaw = body_yaw or 0, travel_yaw = travel_yaw or 0, orientation_available = true,
            body_quaternion = {frame.body.orientation[1], frame.body.orientation[2], frame.body.orientation[3], frame.body.orientation[4]},
            landing_quality_available = quality ~= nil, body_up_alignment = quality and quality.body_up_alignment or 0,
            support_up_alignment = quality and quality.support_up_alignment or 0, closing_normal_speed = quality and quality.closing_normal_speed or 0,
            landing_settle_hold = false, landing_settle_hold_invalid = false}
        local generation = T.generation
        local events = model:update(seconds, input)
        if T.generation ~= generation then cancel("cancelled_during_model_update"); return rejected("cancelled_during_model_update", frame, true) end
        local state = model:state()
        local projected, observed_events = model_state(state), model_events(events)
        if not projected or not observed_events then cancel("invalid_model_output"); return rejected("invalid_model_output", frame, true) end
        local targets = target_copy({valid = true, scope = "model_target_only", realized = false, pose_provenance = "authored_motions_policy",
            barspin = state.bar_angle + state.movement_bar_angle, tailwhip = state.tail_angle + state.movement_tail_angle,
            movement_bike_pitch = state.movement_bike_pitch, movement_bike_roll = state.movement_bike_roll,
            movement_crank_angle = state.movement_crank_angle, movement_id = state.movement_id,
            phase = state.movement_phase, progress = state.movement_progress, release_left_hand = state.release_left_hand,
            release_right_hand = state.release_right_hand, release_left_foot = state.release_left_foot, release_right_foot = state.release_right_foot,
            bar_neutral = actions.bar_neutral, rear_neutral = actions.rear_neutral})
        if not targets then cancel("invalid_model_targets"); return rejected("invalid_model_targets", frame, true) end
        local entry = motions.find(state.movement_id)
        local reserved = state.airborne and (state.bar_rotating or state.tail_rotating or state.bar_waiting_catch or state.tail_waiting_catch
            or state.movement_holding or state.movement_recovering or entry ~= nil and state.movement_progress > 0)
        T.updates += 1
        if not state.airborne and not state.landing_pending then T.impact = nil end
        return {valid = true, fresh = true, advanced = true, scope = "model_adapter_only", realized = false,
            issue = prime and "primed" or "none", serial = frame.serial, time = frame.time, binding = binding(frame),
            requests = {rotation_reserved = reserved == true, scope = "model_request_only"}, visual_targets = targets,
            model_state = projected, model_events = observed_events}
    end
    function object:step(frame, contact, actions)
        if T.busy then cancel("reentrant_step"); return rejected("reentrant_step", T.last, false) end
        T.busy = true
        local ok, result = pcall(advance, frame, contact, actions)
        if not ok then cancel("adapter_exception"); result = rejected("adapter_exception", T.last, false) end
        T.busy = false; T.result = public_copy(result) or rejected("invalid_public_projection", T.last, false)
        return result
    end
    function object:cancel(reason) cancel(issue(reason)); return public_copy(T.result) end
    function object:status() local out = public_copy(T.result); out.model_updates = T.updates; out.generation = T.generation; return out end
    return table.freeze(object)
end
return table.freeze(Runtime)

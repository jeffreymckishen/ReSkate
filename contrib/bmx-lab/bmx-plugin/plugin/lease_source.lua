-- Candidate Lua binding only. A fresh step proves selected observed XInput facts,
-- not rider/body authority, physical controller identity, or native consumption.
local Identity = require("./lease_identity")
local Source = {}
Source.__index = Source
Source.__metatable = "locked"
local states = setmetatable({}, {__mode = "k"})
local MAX_SAFE = 9007199254740991
local methods = {"lease", "lease_read", "lease_renew", "lease_state", "lease_release", "lease_acknowledge",
    "lease_capture", "lease_capture_state", "lease_release_capture", "lease_acknowledge_capture"}
local buttons = {"up", "down", "left", "right", "start", "back", "left_stick", "right_stick",
    "lb", "rb", "a", "b", "x", "y"}
local axes = {"left_x", "left_y", "right_x", "right_y", "left_trigger", "right_trigger"}
local sample_fields = {"user", "sequence", "source_epoch", "context_generation", "observation_serial", "observed_ms", "packet"}
local lease_fields = {"transport", "source_identity", "physical_device_identity", "mode", "capturing", "report_debt",
    "status", "reason", "terminal", "user", "sequence", "source_epoch", "context_generation", "requested_ms",
    "expires_ms", "observed_ms", "last_observation", "renewals", "source_released", "capture_reserved", "orphaned"}
local capture_fields = {"transport", "source_identity", "physical_device_identity", "mode", "capture_scope",
    "publication_scope", "consumption", "semantic_completion", "capturing", "report_debt", "phase", "reason",
    "terminal", "quarantined", "user", "sequence", "source_epoch", "context_generation", "generation", "revision",
    "expires_ms", "publications", "neutral_releases"}
local lease_statuses = {warming=true, active=true, released=true, revoked=true, expired=true}
local capture_phases = {waiting_neutral=1, capturing=2, releasing=3, complete=4}
local lease_reasons = {none=true, unavailable=true, busy=true, invalid_owner=true, invalid_source=true, wrong_thread=true,
    client_not_ready=true, source_unavailable=true, source_changed=true, source_stale=true, context_changed=true,
    focus_lost=true, gameplay_inactive=true, menu_open=true, interference=true, deadline=true, stale_epoch=true,
    capacity=true, sequence_exhausted=true, cancelled=true}
local capture_reasons = {none=true, unavailable=true, invalid_key=true, busy=true, exhausted=true, source_changed=true,
    source_stale=true, clock_regressed=true, authority_lost=true, context_changed=true, deadline=true, focus_lost=true,
    gameplay_inactive=true, menu_open=true, paused=true, interference=true, cancelled=true, publication_unconfirmed=true}

local function finite(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
local function integer(n, low, high) return finite(n) and n >= low and n <= high and math.floor(n) == n end
local function detail(value) return string.sub(tostring(value or "unavailable"), 1, 200) end
local function copy_fields(row, fields)
    local result = {}
    for _, name in ipairs(fields) do result[name] = row[name] end
    return result
end
local function api_ready(s)
    if type(s.api) ~= "table" then return false end
    for _, name in ipairs(methods) do if type(s.api[name]) ~= "function" then return false end end
    return true
end
local function invoke(s, name, ...)
    local fn = type(s.api) == "table" and s.api[name] or nil
    if type(fn) ~= "function" then return false, nil, name .. " unavailable" end
    local generation = s.generation
    local ok, value, why = pcall(fn, ...)
    if not ok then return false, nil, name .. " error: " .. detail(value) end
    if generation ~= s.generation then return false, value, "source invalidated during " .. name end
    return true, value, why
end
local function bound_matches(s, row)
    local key = s.bound
    return row.user == s.user and Identity.is_nonzero_u64(row.sequence) and
        Identity.is_nonzero_u64(row.source_epoch) and Identity.is_nonzero_u64(row.context_generation) and
        (not key or (row.sequence == key.sequence and row.source_epoch == key.source_epoch and
            row.context_generation == key.context_generation))
end
local function bind(s, row)
    if not s.bound then
        s.bound = {sequence=row.sequence, source_epoch=row.source_epoch, context_generation=row.context_generation}
    end
end
local function observer(row)
    return type(row) == "table" and row.transport == "xinput" and row.source_identity == "observed_stream" and
        row.physical_device_identity == "unobserved" and row.mode == "observe" and
        row.capturing == false and row.report_debt == false
end
local function pad_copy(row)
    if type(row) ~= "table" or row.playstation ~= false or type(row.buttons) ~= "table" then return nil end
    local result, pressed = {playstation=false}, {}
    for _, name in ipairs(axes) do
        local value = row[name]
        local low = (name == "left_trigger" or name == "right_trigger") and 0 or -1
        if not finite(value) or value < low or value > 1 then return nil end
        result[name] = value
    end
    for _, name in ipairs(buttons) do
        if type(row.buttons[name]) ~= "boolean" then return nil end
        pressed[name] = row.buttons[name]
    end
    result.buttons = table.freeze(pressed)
    return table.freeze(result)
end
local function pad_equal(a, b)
    for _, name in ipairs(axes) do if a[name] ~= b[name] then return false end end
    for _, name in ipairs(buttons) do if a.buttons[name] ~= b.buttons[name] then return false end end
    return a.playstation == b.playstation
end
local function sample_copy(s, row)
    if not observer(row) or not bound_matches(s, row) or type(row.epoch) ~= "userdata" or
        not Identity.is_nonzero_u64(row.observation_serial) or not Identity.is_nonzero_u64(row.observed_ms) or
        not integer(row.packet, 0, 4294967295) then return nil, "invalid source sample" end
    local pad = pad_copy(row.pad)
    if not pad then return nil, "invalid original pad" end
    local result = copy_fields(row, sample_fields)
    result.pad = pad
    local previous = s.sample
    if previous then
        local serial = Identity.compare(result.observation_serial, previous.observation_serial)
        if serial < 0 or Identity.compare(result.observed_ms, previous.observed_ms) < 0 then
            return nil, "source observation regressed"
        end
        if serial == 0 and (result.observed_ms ~= previous.observed_ms or result.packet ~= previous.packet or
            not pad_equal(result.pad, previous.pad)) then return nil, "changed duplicate observation" end
    end
    return table.freeze(result)
end
local function lease_copy(s, row)
    if not observer(row) or not bound_matches(s, row) or not lease_statuses[row.status] or
        not lease_reasons[row.reason] or type(row.terminal) ~= "boolean" or
        type(row.source_released) ~= "boolean" or type(row.capture_reserved) ~= "boolean" or
        type(row.orphaned) ~= "boolean" then return nil end
    for _, name in ipairs({"requested_ms", "expires_ms"}) do
        if not Identity.is_nonzero_u64(row[name]) then return nil end
    end
    for _, name in ipairs({"observed_ms", "last_observation", "renewals"}) do
        if not Identity.is_u64(row[name]) then return nil end
    end
    local terminal = row.status ~= "active" and row.status ~= "warming"
    if row.terminal ~= terminal or (row.source_released and (not terminal or row.capture_reserved)) or
        (terminal and not row.source_released and not row.capture_reserved) or
        (row.capture_reserved and not (s.capture_admitted or s.capture_uncertain)) or
        Identity.compare(row.expires_ms, row.requested_ms) <= 0 then return nil end
    if row.last_observation == "0" then
        if row.observed_ms ~= "0" or row.status == "active" then return nil end
    elseif row.observed_ms == "0" or Identity.compare(row.observed_ms, row.requested_ms) < 0 then return nil end
    if row.status == "active" and Identity.compare(row.observed_ms, row.expires_ms) >= 0 then return nil end
    local previous = s.lease_state
    if previous and (row.requested_ms ~= previous.requested_ms or
        Identity.compare(row.expires_ms, previous.expires_ms) < 0 or
        Identity.compare(row.renewals, previous.renewals) < 0 or
        Identity.compare(row.last_observation, previous.last_observation) < 0 or
        Identity.compare(row.observed_ms, previous.observed_ms) < 0 or
        (previous.terminal and not terminal)) then return nil end
    return table.freeze(copy_fields(row, lease_fields))
end
local function capture_copy(s, row)
    if type(row) ~= "table" or not bound_matches(s, row) or not capture_phases[row.phase] or
        not capture_reasons[row.reason] or row.transport ~= "xinput" or row.source_identity ~= "observed_stream" or
        row.physical_device_identity ~= "unobserved" or row.mode ~= "capture" or
        row.capture_scope ~= "selected_observed_xinput_stream" or row.publication_scope ~= "process_outer_xinput_buffer" or
        row.consumption ~= "unobserved" or row.semantic_completion ~= "unobserved" or
        row.capturing ~= (row.phase == "capturing") or row.terminal ~= (row.phase == "complete") or
        type(row.report_debt) ~= "boolean" or type(row.quarantined) ~= "boolean" then return nil end
    for _, name in ipairs({"generation", "revision", "expires_ms"}) do
        if not Identity.is_nonzero_u64(row[name]) then return nil end
    end
    if not Identity.is_u64(row.publications) or not Identity.is_u64(row.neutral_releases) or
        Identity.compare(row.neutral_releases, row.publications) > 0 then return nil end
    if row.phase == "waiting_neutral" and (row.report_debt or row.publications ~= "0" or
        row.neutral_releases ~= "0" or row.quarantined) then return nil end
    if row.phase == "capturing" and (not row.report_debt or row.publications == "0" or row.quarantined) then return nil end
    if row.phase == "releasing" and not row.report_debt then return nil end
    if row.phase == "complete" and row.report_debt then return nil end
    local previous = s.capture_state
    if previous then
        local generation = Identity.compare(row.generation, previous.generation)
        local revision = Identity.compare(row.revision, previous.revision)
        -- Stop and neutral handoff advance generation. An older in-flight poll
        -- can reopen a complete retained key before acknowledgement succeeds.
        local reopened = previous.phase == "complete" and row.phase == "releasing" and generation > 0 and revision > 0
        if generation < 0 or revision < 0 or
            (capture_phases[row.phase] < capture_phases[previous.phase] and not reopened) or
            Identity.compare(row.expires_ms, previous.expires_ms) < 0 or
            Identity.compare(row.publications, previous.publications) < 0 or
            Identity.compare(row.neutral_releases, previous.neutral_releases) < 0 then return nil end
    end
    return table.freeze(copy_fields(row, capture_fields))
end
local function frame(s, permitted, fresh)
    return table.freeze({input_ok=permitted == true, phase=s.phase, reason=s.reason,
        new_observation=fresh == true, generation=s.generation, lease_handle=s.handle,
        lease_state=s.lease_state, capture_state=s.capture_state, sample=s.sample,
        cleanup_pending=s.request_uncertain == true or (s.handle ~= nil and
            (s.phase == "stopping" or s.phase == "draining" or s.phase == "cleanup_unknown")),
        cleanup_unknown=s.phase == "cleanup_unknown"})
end
local function invalidate(s)
    s.input_ok = false
    if s.generation < MAX_SAFE then s.generation += 1 end
end
local function release(s)
    if not s.handle then return end
    -- Set each attempt flag before a callback can inspect or reenter the source.
    if (s.capture_admitted or s.capture_uncertain) and not s.capture_release_requested then
        s.capture_release_requested = true
        local called, accepted = invoke(s, "lease_release_capture", s.handle)
        s.capture_release_accepted = called and accepted == true
    end
    if not s.lease_release_requested then
        s.lease_release_requested = true
        local called, accepted = invoke(s, "lease_release", s.handle)
        s.lease_release_accepted = called and accepted == true
    end
end
local function stop(s, reason)
    if s.phase ~= "stopping" and s.phase ~= "draining" and s.phase ~= "cleanup_unknown" and
        (s.phase ~= "complete" or s.handle ~= nil) then
        invalidate(s) -- Revoke permission before any API callback.
        s.phase, s.reason, s.cleanup_at = "stopping", detail(reason or "stopped"), s.last_now
    else s.input_ok = false end
    release(s)
    if not s.handle then
        s.phase = s.request_uncertain and "cleanup_unknown" or "complete"
    end
end
local function drain(s, now)
    s.input_ok = false
    if s.phase == "cleanup_unknown" or s.phase == "complete" then return end
    if not s.handle then s.phase = s.request_uncertain and "cleanup_unknown" or "complete"; return end
    s.phase = "draining"
    if (s.capture_admitted or s.capture_uncertain) and not s.capture_acknowledged then
        local called, row, why = invoke(s, "lease_capture_state", s.handle)
        local checked = called and capture_copy(s, row) or nil
        if checked then
            s.capture_state = checked
            if checked.phase == "capturing" then s.capture_seen = true end
            if checked.phase == "complete" and not checked.report_debt and not checked.quarantined and
                (not s.capture_seen or checked.neutral_releases ~= "0") then
                local ack_called, accepted = invoke(s, "lease_acknowledge_capture", s.handle)
                if ack_called and accepted == true then s.capture_acknowledged = true end
            end
        else s.reason = "capture cleanup unobserved: " .. detail(why) end
        if not s.capture_acknowledged then
            if now - s.cleanup_at >= s.options.cleanup_ms then s.phase = "cleanup_unknown" end
            return
        end
    end
    local called, row, why = invoke(s, "lease_state", s.handle)
    local checked = called and lease_copy(s, row) or nil
    if checked then
        bind(s, checked)
        s.lease_state = checked
        if checked.terminal and checked.source_released and not checked.capture_reserved then
            local ack_called, accepted = invoke(s, "lease_acknowledge", s.handle)
            if ack_called and accepted == true then
                s.handle, s.input_epoch = nil, nil
                s.phase = "complete"
                return
            end
        end
    else s.reason = "lease cleanup unobserved: " .. detail(why) end
    if now - s.cleanup_at >= s.options.cleanup_ms then s.phase = "cleanup_unknown" end
end
local function clock(s, now)
    if not finite(now) or now < 0 or now > MAX_SAFE or (s.last_now and now < s.last_now) then return false end
    s.last_now = now
    return true
end
local function option_values(options)
    if options ~= nil and type(options) ~= "table" then return nil end
    local result = {setup_ms=15000, capture_ms=4000, cleanup_ms=4000}
    for name, default in pairs(result) do
        local value = options and options[name]
        if value == nil then value = default end
        if not integer(value, 1, 60000) then return nil end
        result[name] = value
    end
    return table.freeze(result)
end

function Source.new(input_api, options)
    -- Construction and require are inert, even when a native API is unavailable.
    -- Luau refuses freeze on an already protected metatable. Keep this new
    -- metatable private until the instance is frozen, then protect both.
    local instance_metatable = {__index=Source}
    local object = setmetatable({}, instance_metatable)
    states[object] = {api=input_api, options=option_values(options), phase="idle", reason="not armed", generation=0}
    table.freeze(object)
    instance_metatable.__metatable = "locked"
    table.freeze(instance_metatable)
    return object
end

function Source:arm(user, now_ms)
    local s = states[self]
    if s.busy then return false, "source operation in progress" end
    if s.phase ~= "idle" and s.phase ~= "complete" then return false, "source session unresolved" end
    if s.handle or s.request_uncertain then return false, "source cleanup unresolved" end
    if not integer(user, 0, 3) then return false, "select numeric XInput slot 0..3" end
    if not s.options then return false, "invalid watchdog options" end
    if not api_ready(s) then return false, "ten-method input lease API unavailable" end
    if s.generation >= MAX_SAFE - 1 then return false, "local generation exhausted" end
    if not clock(s, now_ms) then return false, "invalid or regressed caller clock" end
    local replacement = {api=s.api, options=s.options, phase="armed", reason="waiting for acquisition gate",
        generation=s.generation + 1, user=user, arm_at=now_ms, last_now=now_ms}
    states[self] = replacement
    return true
end

function Source:status()
    -- A cached status is diagnostic, not another guard-bearing native step.
    return frame(states[self], false, false)
end

function Source:stop(reason)
    local s = states[self]
    local busy = s.busy
    s.busy = true
    stop(s, reason)
    s.busy = busy
    return frame(s, false, false)
end

function Source:unload()
    return Source.stop(self, "unload requested; VM-close native cleanup remains authoritative")
end

local function advance(s, now_ms, gates)
    s.input_ok = false
    if s.phase == "idle" or s.phase == "complete" or s.phase == "cleanup_unknown" then return frame(s, false, false) end
    if not clock(s, now_ms) then
        stop(s, "invalid or regressed caller clock")
        if s.handle or s.request_uncertain then s.phase = "cleanup_unknown" end
        return frame(s, false, false)
    end
    if s.phase == "stopping" or s.phase == "draining" then drain(s, now_ms); return frame(s, false, false) end
    if not api_ready(s) then stop(s, "input lease API unavailable"); return frame(s, false, false) end
    local acquire = type(gates) == "table" and gates.allow_acquire == true
    local drive = type(gates) == "table" and gates.allow_drive == true
    if s.was_active and not drive then stop(s, "caller authority lost"); return frame(s, false, false) end
    if not s.was_active and now_ms - s.arm_at >= s.options.setup_ms then
        stop(s, "setup watchdog expired"); return frame(s, false, false)
    end
    if s.capture_at and not s.capture_seen and now_ms - s.capture_at >= s.options.capture_ms then
        stop(s, "capture watchdog expired"); return frame(s, false, false)
    end
    if s.phase == "armed" then
        if not acquire then return frame(s, false, false) end
        local called, handle, why = invoke(s, "lease", s.user)
        -- A fixture callback can stop during acquisition. Retain even a late
        -- returned real handle so the invalidated operation still requests release.
        if type(handle) == "userdata" then s.handle = handle end
        if not called or (handle ~= nil and type(handle) ~= "userdata") then
            s.request_uncertain = type(handle) ~= "userdata"
            stop(s, "lease request outcome unknown: " .. detail(why))
            return frame(s, false, false)
        end
        if not handle then stop(s, "lease refused: " .. detail(why)); return frame(s, false, false) end
        s.handle, s.phase, s.reason = handle, "warming", "waiting for post-cookie original input"
    end

    -- Native read checks freshness and guards. Caller wall time is never joined
    -- with observed_ms; body advancement is deliberately absent from this API.
    local called, raw, why = invoke(s, "lease_read", s.handle)
    if not called then stop(s, "input read error: " .. detail(why)); return frame(s, false, false) end
    if raw == nil then
        local state_called, row = invoke(s, "lease_state", s.handle)
        local checked = state_called and lease_copy(s, row) or nil
        if checked then bind(s, checked); s.lease_state = checked end
        if checked and checked.status == "warming" and not s.was_active and not s.capture_admitted then
            return frame(s, false, false)
        end
        stop(s, "fresh input unavailable: " .. detail(why)); return frame(s, false, false)
    end
    local sample, invalid = sample_copy(s, raw)
    if not sample then stop(s, invalid); return frame(s, false, false) end
    local fresh = not s.sample or sample.observation_serial ~= s.sample.observation_serial
    bind(s, sample)
    s.sample, s.input_epoch = sample, raw.epoch -- Opaque input proof stays private.
    if fresh then
        local renewed, accepted, reason = invoke(s, "lease_renew", s.handle, s.input_epoch)
        if not renewed or accepted ~= true then stop(s, "input renewal refused: " .. detail(reason)); return frame(s, false, false) end
        s.renewed_serial = sample.observation_serial
    end
    local state_called, lease_row, state_why = invoke(s, "lease_state", s.handle)
    local lease_state = state_called and lease_copy(s, lease_row) or nil
    if not lease_state or lease_state.status ~= "active" or lease_state.orphaned or
        Identity.compare(lease_state.last_observation, sample.observation_serial) < 0 or
        Identity.compare(lease_state.observed_ms, sample.observed_ms) < 0 then
        stop(s, "active lease unavailable: " .. detail(state_why)); return frame(s, false, false)
    end
    s.lease_state = lease_state
    if not s.capture_admitted then
        if not acquire or s.capture_attempt_serial == sample.observation_serial then return frame(s, false, fresh) end
        s.capture_attempt_serial = sample.observation_serial
        s.capture_at = s.capture_at or now_ms
        local capture_called, admitted, capture_why = invoke(s, "lease_capture", s.handle, s.input_epoch)
        if not capture_called or (admitted ~= true and admitted ~= false) then
            s.capture_uncertain = true
            stop(s, "capture admission outcome unknown: " .. detail(capture_why)); return frame(s, false, false)
        end
        if not admitted then s.reason = "capture admission refused: " .. detail(capture_why); return frame(s, false, fresh) end
        s.capture_admitted, s.phase, s.reason = true, "waiting_neutral", "waiting for later exact-neutral original report"
    end
    local capture_called, capture_row, capture_why = invoke(s, "lease_capture_state", s.handle)
    local checked_capture = capture_called and capture_copy(s, capture_row) or nil
    if not checked_capture then stop(s, "capture state unavailable: " .. detail(capture_why)); return frame(s, false, false) end
    s.capture_state = checked_capture
    if checked_capture.quarantined or (checked_capture.phase ~= "waiting_neutral" and checked_capture.phase ~= "capturing") then
        stop(s, "capture authority lost: " .. checked_capture.reason); return frame(s, false, false)
    end
    if checked_capture.phase == "waiting_neutral" then
        if s.was_active then stop(s, "capture regressed") end
        return frame(s, false, fresh)
    end
    s.capture_seen, s.phase = true, "capturing"
    if not drive then s.reason = "waiting for caller drive gate"; return frame(s, false, fresh) end
    s.was_active, s.input_ok, s.reason = true, true, "current selected-stream input admitted"
    return frame(s, true, fresh)
end

function Source:step(now_ms, gates)
    local s = states[self]
    if s.busy then return frame(s, false, false) end
    s.busy = true
    local result = advance(s, now_ms, gates)
    s.busy = false
    return result
end

return table.freeze(Source)

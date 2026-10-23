-- Recovery sequencing only. The caller owns every API call and must supply
-- real park/release witnesses; this model neither obtains nor proves them.
local Recovery, Policy = {}, {}
Policy.__index = Policy
local maximum_integer, maximum_u64 = 9007199254740991, "18446744073709551615"
local function integer(n, maximum)
    return type(n) == "number" and n == n and n >= 0 and n <= maximum and n % 1 == 0
end
local function finite(n) return type(n) == "number" and n == n and n >= 0 and n < math.huge end
local function token(v)
    return type(v) == "userdata" or (type(v) == "string" and #v > 0 and #v <= 128)
        or (integer(v, maximum_integer) and v > 0)
end
local function decimal(v, nonzero)
    return type(v) == "string" and #v > 0 and #v <= 20 and v:match("^%d+$") ~= nil
        and (#v == 1 or v:sub(1,1) ~= "0") and (not nonzero or v ~= "0")
        and (#v < 20 or v <= maximum_u64)
end
local function less(a,b) return #a < #b or (#a == #b and a < b) end
local function copy(t) local out = {}; for k,v in t do out[k] = v end; return out end
local nonterminal = {pending=true, entered=true, reset=true}
local statuses = {pending=true, entered=true, reset=true, completed=true, already_true=true,
    rejected=true, cancelled=true, expired=true, invalidated=true}
local reasons = {}
for _,name in {"none","invalid_owner","invalid_kind","unavailable","busy","receipt_capacity","context_changed",
    "focus_changed","teleporting","motion_owned","actor_changed","actor_destroyed","world_changed","unsupported_state",
    "protection_conflict","request_bits_conflict","request_write_failed","request_restore_failed","native_refused",
    "selector_overridden","cancelled","expired","owner_released","native_lifetime_changed"} do reasons[name] = true end
local booleans = {"terminal","true_entered","true_returned","reset_pending","reset_entered","reset_returned",
    "reset_readback_known","reset_false","cleared_before_reset","unresolved","actor_retired","quarantined",
    "standing_observed","stable_observed"}
local optional_booleans = {"prior_value","true_readback","ragdoll","in_air"}
local fields = {kind=true,status=true,reason=true,sequence=true,requested_ms=true,observed_ms=true,true_ms=true,
    true_serial=true,true_time=true,reset_ms=true,reset_serial=true,reset_time=true,committed_state=true,
    native_true_calls=true,native_reset_calls=true,start_attempts=true,cleanup_attempts=true,
    standing_samples=true,standing_seconds=true,standing_required_seconds=true}
for _,name in booleans do fields[name] = true end
for _,name in optional_booleans do fields[name] = true end

-- Only the currently published recovery receipt schema is accepted. Decimal
-- identifiers are compared as strings, never rounded through tonumber().
local function receipt_valid(r, previous)
    if type(r) ~= "table" or getmetatable(r) ~= nil then return false end
    for k in r do if not fields[k] then return false end end
    if r.kind ~= "get_up" or not statuses[r.status] or not reasons[r.reason]
        or not decimal(r.sequence,true) or not decimal(r.requested_ms,false)
        or r.terminal ~= not nonterminal[r.status] or (r.status == "completed" and not r.observed_ms) then return false end
    for _,name in booleans do if type(r[name]) ~= "boolean" then return false end end
    for _,name in optional_booleans do if r[name] ~= nil and type(r[name]) ~= "boolean" then return false end end
    for _,name in {"observed_ms","true_ms","reset_ms"} do
        if r[name] ~= nil and (not decimal(r[name],false) or less(r[name],r.requested_ms)) then return false end
    end
    for _,name in {"true_serial","reset_serial"} do if r[name] ~= nil and not decimal(r[name],true) then return false end end
    for _,name in {"true_time","reset_time"} do if r[name] ~= nil and not finite(r[name]) then return false end end
    if not integer(r.native_true_calls,1) or not integer(r.native_reset_calls,64)
        or not integer(r.start_attempts,64) or not integer(r.cleanup_attempts,64)
        or not integer(r.standing_samples,4294967295) or not finite(r.standing_seconds)
        or r.standing_required_seconds ~= 2
        or (r.committed_state ~= nil and not integer(r.committed_state,4294967295)) then return false end
    if (r.native_true_calls > 0 or r.true_returned or r.true_readback ~= nil) and not r.true_entered then return false end
    if r.true_entered and (not r.true_ms or not r.true_serial or not finite(r.true_time)) then return false end
    if not r.true_entered and (r.true_ms or r.true_serial or r.true_time) then return false end
    if r.reset_false then
        if not r.true_entered or not r.reset_ms or not r.reset_serial or not finite(r.reset_time)
            or not less(r.true_serial,r.reset_serial) or r.reset_time <= r.true_time
            or less(r.reset_ms,r.true_ms) or not r.reset_readback_known or r.reset_pending or r.unresolved then return false end
    elseif r.reset_ms or r.reset_serial or r.reset_time then return false end
    if r.quarantined and (not r.terminal or not r.unresolved or r.actor_retired) then return false end
    if r.true_entered and not r.reset_false and not r.actor_retired and not r.unresolved then return false end
    if r.status == "entered" and not r.true_entered then return false end
    if r.status == "reset" and not r.reset_false then return false end
    if previous then
        if r.sequence ~= previous.sequence or r.requested_ms ~= previous.requested_ms
            or (previous.terminal and (not r.terminal or r.status ~= previous.status or r.reason ~= previous.reason))
            or (previous.true_entered and not r.true_entered) or (previous.reset_false and not r.reset_false)
            or r.native_true_calls < previous.native_true_calls or r.native_reset_calls < previous.native_reset_calls
            or r.start_attempts < previous.start_attempts or r.cleanup_attempts < previous.cleanup_attempts
            or (previous.observed_ms and (not r.observed_ms or less(r.observed_ms,previous.observed_ms))) then return false end
        for _,name in {"true_ms","true_serial","true_time","reset_ms","reset_serial","reset_time"} do
            if previous[name] ~= nil and previous[name] ~= r[name] then return false end
        end
        if previous.status == "completed" then
            for name in fields do if r[name] ~= previous[name] then return false end end
        end
        local rank = {pending=0,entered=1,reset=2}
        if not previous.terminal and not r.terminal and rank[r.status] < rank[previous.status] then return false end
    end
    return true
end
local function standing(r)
    return r.status == "completed" and r.reason == "none" and r.terminal and r.native_true_calls == 1
        and r.true_entered and r.true_returned and r.true_readback == true and r.reset_false
        and r.reset_readback_known and not r.reset_pending and not r.unresolved and not r.quarantined
        and not r.actor_retired and r.standing_observed and r.stable_observed
        and r.standing_seconds >= 2 and r.standing_samples >= 30
        and r.committed_state == 504 and r.ragdoll == false and r.in_air == false
end

function Recovery.new()
    return setmetatable({_attempt=0,_latest_fall=0,_spent=0,_armed=false}, Policy)
end
function Policy:_fault(why)
    self._armed = false
    if self._awaiting or (self._handle and not self._acked) or self._uncertain then
        self._boundary = self._boundary or why
    end
end
function Policy:_reply(f)
    local e = f.request_result
    if e ~= nil then
        if type(e) ~= "table" or not self._awaiting or e.attempt ~= self._attempt then self:_fault("request_result_changed")
        else
            self._awaiting = false
            if e.accepted == true and token(e.handle) then self._handle = e.handle
            elseif e.accepted == false and e.handle == nil and type(e.reason) == "string" and #e.reason > 0 and #e.reason <= 160 then
                self._refused = e.reason
            else self._uncertain = true; self:_fault("request_result_unknown") end
        end
    end
    e = f.receipt
    if e ~= nil then
        if not self._handle or self._acked or f.receipt_handle ~= self._handle or not receipt_valid(e,self._receipt) then
            self:_fault("receipt_invalid")
        else self._receipt = copy(e) end
    end
    e = f.ack_result
    if e ~= nil then
        if type(e) ~= "table" or not self._ack_sent or self._ack_received or e.attempt ~= self._attempt
            or e.handle ~= self._handle or type(e.accepted) ~= "boolean" then self:_fault("ack_result_changed")
        else
            self._ack_received = true
            if e.accepted then self._acked = true else self._ack_failed = true end
        end
    end
end
function Policy:update(f)
    if type(f) ~= "table" then self:_fault("sample_invalid"); f = {} end
    -- Join results even after a local boundary: an accepted/uncertain native
    -- call must never disappear merely because the gesture clock became bad.
    self:_reply(f)
    local clock = integer(f.now_ms,maximum_integer) and (not self._last or f.now_ms >= self._last)
    local fresh = clock and (self._last == nil or f.now_ms > self._last)
    if clock then self._last = f.now_ms else self:_fault("clock_invalid") end
    -- A down observation at an equal clock cannot authorize a request, but it
    -- still consumes the edge instead of deferring it to the next clock.
    if not fresh and f.gesture_down == true then self._armed = false end
    local shape = token(f.actor) and integer(f.source_epoch,4294967295) and f.source_epoch > 0
        and integer(f.fall_epoch,4294967295) and f.fall_epoch > 0
    for _,name in {"gesture_down","allowed","loaded","fallen","park_ready","release_ready"} do
        shape = shape and type(f[name]) == "boolean"
    end
    if not shape then self:_fault("sample_invalid") end
    if shape then
        if self._actor ~= nil and f.actor ~= self._actor then
            self:_fault("actor_changed"); self._latest_fall,self._spent = 0,0
        end
        if self._source ~= nil and f.source_epoch ~= self._source then self:_fault("source_changed") end
        self._actor,self._source = f.actor,f.source_epoch
        if f.fall_epoch < self._latest_fall then shape = false; self:_fault("fall_epoch_rewound")
        else self._latest_fall = f.fall_epoch end
        local bound_active = self._awaiting or self._uncertain or (self._handle and not self._acked)
        if bound_active and self._bound_actor and (f.actor ~= self._bound_actor or f.source_epoch ~= self._bound_source
            or f.fall_epoch ~= self._bound_fall) then self:_fault("recovery_context_changed") end
        if not f.allowed or not f.loaded then self:_fault("readiness_lost") end
    end
    local intents = {}
    local active = self._awaiting or self._uncertain or (self._handle and not self._acked)
    if fresh and shape and f.loaded then
        local r = self._receipt
        if self._handle and not self._acked then
            if not r or not r.terminal or (r.unresolved and not r.actor_retired) or r.quarantined then
                intents.poll = {attempt=self._attempt,handle=self._handle}
            elseif not self._ack_sent then
                -- Output includes a copied full receipt before this one intent.
                self._ack_sent = true; intents.acknowledge = {attempt=self._attempt,handle=self._handle}
            end
            if self._boundary and r and r.status == "pending" and not r.true_entered and not self._cancel_sent then
                self._cancel_sent = true; intents.cancel = {attempt=self._attempt,handle=self._handle}
            end
        end
        if f.allowed then
            if not f.gesture_down then self._armed = true
            else
                local pressed = self._armed; self._armed = false
                if pressed and not active and f.fall_epoch > self._spent then
                    if f.fallen and f.park_ready and f.release_ready and self._attempt < maximum_integer then
                        self._attempt += 1; self._spent = f.fall_epoch
                        self._bound_actor,self._bound_source,self._bound_fall = f.actor,f.source_epoch,f.fall_epoch
                        self._awaiting,self._handle,self._receipt,self._boundary = true,nil,nil,nil
                        self._refused,self._uncertain,self._acked,self._ack_sent,self._ack_received,self._ack_failed,self._cancel_sent = nil,false,false,false,false,false,false
                        intents.request = {attempt=self._attempt,actor=f.actor,source_epoch=f.source_epoch,fall_epoch=f.fall_epoch}
                    end
                end
            end
        end
    end
    local r, outcome = self._receipt, "idle"
    if self._awaiting then outcome = "awaiting_request"
    elseif self._uncertain then outcome = "request_unknown"
    elseif self._refused then outcome = "request_refused"
    elseif r then
        if r.quarantined or (r.unresolved and not r.actor_retired) then outcome = "unresolved"
        elseif not r.terminal then outcome = r.status
        elseif standing(r) and not self._boundary and f.actor == self._bound_actor
            and f.source_epoch == self._bound_source and f.fall_epoch == self._bound_fall then outcome = "standing"
        elseif r.status == "completed" then outcome = "completion_not_accepted"
        elseif r.actor_retired then outcome = "actor_retired"
        else outcome = "terminal_failure" end
    elseif self._handle then outcome = "awaiting_receipt" end
    return {outcome=outcome,reason=self._boundary or self._refused or (r and r.reason) or "none",attempt=self._attempt,
        standing=outcome=="standing",native_completed=r ~= nil and r.status=="completed",
        retained=self._awaiting or self._uncertain or (self._handle ~= nil and not self._acked),acknowledged=self._acked==true,
        ack_failed=self._ack_failed==true,receipt=r and copy(r) or nil,intents=intents}
end

return Recovery

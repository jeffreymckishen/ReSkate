-- Equipment sequencing only. Every effect is an intent for the caller; requiring
-- this module performs no API calls. Context is a caller continuity token, not a
-- native actor identity. This version never retries an accepted or refused call.
local Transition, Policy = {}, {}
Policy.__index = Policy
-- update(frame) accepts integer now_ms, gesture_down/loaded/allowed, a caller
-- context token, slot0..3 and an observation of focus/menu/gameplay/local-player,
-- teleport/ground/ragdoll/fall/state facts. Replies carry attempt and handle;
-- receipt_result also carries the read_id, and store/ack results the exact
-- decimal sequence. A store result attests the caller saved the full snapshot;
-- the model cannot establish storage durability. No reskate globals are used.
local maximum_integer, maximum_u64 = 9007199254740991, "18446744073709551615"
local limits = {baseline_ms=600,request_ms=8000,settle_ms=2500,settle_samples=10,
    maximum_gap_ms=250,settle_bound_ms=6000,intent_ms=15000,read_ms=200}

local function integer(n,maximum)
    return type(n)=="number" and n==n and n>=0 and n<=maximum and n%1==0
end
local function token(v)
    return type(v)=="userdata" or (type(v)=="string" and #v>0 and #v<=128)
        or (integer(v,maximum_integer) and v>0)
end
local function decimal(v,nonzero)
    return type(v)=="string" and #v>0 and #v<=20 and v:match("^%d+$")~=nil
        and (#v==1 or v:sub(1,1)~="0") and (not nonzero or v~="0")
        and (#v<20 or v<=maximum_u64)
end
local function less(a,b) return #a<#b or (#a==#b and a<b) end
local function plus_thousand(s)
    local out,carry="",1000
    for i=#s,1,-1 do
        local n=string.byte(s,i)-48+carry
        out=string.char(48+n%10)..out;carry=math.floor(n/10)
    end
    return (carry>0 and tostring(carry) or "")..out
end
local function copy(value)
    if type(value)~="table" then return value end
    local out={};for k,v in value do out[k]=copy(v) end;return out
end
local statuses={queued=true,warming=true,pressing=true,releasing=true,released=true,cancelled=true,expired=true,revoked=true}
local terminal={released=true,cancelled=true,expired=true,revoked=true}
local reasons={}
for _,v in {"none","invalid_owner","invalid_source","invalid_button","rate_limited","busy","capacity","unavailable",
    "unsupported_transport","source_unavailable","source_changed","actor_changed","focus_lost","menu_open",
    "gameplay_inactive","interference","clock_unavailable","clock_regressed","deadline","cancelled",
    "publication_unconfirmed","cleanup_pending","sequence_exhausted"} do reasons[v]=true end
local stages={none=true,service_plan=true,core_plan=true,prepublish=true,tick_ready=true,tick_deadline=true,publication=true}
local counts={"press_candidates","press_publications","neutral_publications","original_failures","contentions"}
local flags={"terminal","report_debt","claim_released","actor_retired","orphaned","quarantined","original_result_known"}
local actor_flags={"first_actor_observation_known","first_actor_owner_present","first_actor_call_active",
    "first_actor_inspect_attempted","first_actor_inspect_succeeded","first_actor_equal",
    "first_actor_clock_attempted","first_actor_clock_known"}
local actor_phases,actor_reasons={},{}
for _,v in {"not_attempted","qualified","enter_owner_lock","enter_ownership","enter_claim",
    "inspect_owner_lock","inspect_ownership","controls_focus","controls_profile","controls_teleport",
    "controls_motion_active","controls_motion_unavailable","validation_owner_lock","readiness","capture",
    "actor_epoch","lifetime","world","protection","recapture","context","state","final_owner_lock",
    "final_lifetime","identity","controls_profile_lock","controls_profile_inactive",
    "controls_profile_manager_read","controls_profile_manager_null","controls_profile_phase_read",
    "controls_profile_exception"} do actor_phases[v]=true end
for _,v in {"none","invalid_owner","invalid_kind","unavailable","busy","receipt_capacity","context_changed",
    "focus_changed","teleporting","motion_owned","actor_changed","actor_destroyed","world_changed",
    "unsupported_state","protection_conflict","request_bits_conflict","request_write_failed",
    "request_restore_failed","native_refused","selector_overridden","cancelled","expired","owner_released",
    "native_lifetime_changed"} do actor_reasons[v]=true end
local actor_enums={first_actor_enter_phase=actor_phases,first_actor_enter_reason=actor_reasons,
    first_actor_inspect_phase=actor_phases,first_actor_inspect_reason=actor_reasons}
local actor_fields={}
for _,v in actor_flags do actor_fields[v]=true end
for v in actor_enums do actor_fields[v]=true end
local fields={status=true,reason=true,sequence=true,requested_ms=true,expires_ms=true,observed_ms=true,source_epoch=true,
    user=true,button=true,transport=true,source_identity=true,publication_scope=true,consumption=true,semantic_completion=true,
    first_rejection_mask=true,first_rejection_stage=true,original_result=true}
for _,v in counts do fields[v]=true end
for _,v in flags do fields[v]=true end
for v in actor_fields do fields[v]=true end

local function receipt_valid(r,previous,slot)
    if type(r)~="table" or getmetatable(r)~=nil then return false end
    for k in r do if not fields[k] then return false end end
    -- Older constructed receipts may omit this entire diagnostic group. It is
    -- otherwise complete and typed, never evidence for a transition decision.
    local actor_present=false
    for v in actor_fields do if r[v]~=nil then actor_present=true;break end end
    if actor_present then
        for _,v in actor_flags do if type(r[v])~="boolean" then return false end end
        for v,values in actor_enums do if type(r[v])~="string" or not values[r[v]] then return false end end
    end
    if not statuses[r.status] or not reasons[r.reason] or r.terminal~=(terminal[r.status]==true)
        or r.user~=slot or r.button~=0x8000 or r.transport~="xinput" or r.source_identity~="observed_stream"
        or r.publication_scope~="process_outer_xinput_buffer" or r.consumption~="unobserved"
        or r.semantic_completion~="unobserved" or not decimal(r.sequence,true) or not decimal(r.source_epoch,true)
        or not integer(r.first_rejection_mask,262143) or not stages[r.first_rejection_stage] then return false end
    for _,v in flags do if type(r[v])~="boolean" then return false end end
    for _,v in {"requested_ms","expires_ms","observed_ms"} do if not decimal(r[v],false) then return false end end
    if r.expires_ms~=plus_thousand(r.requested_ms) or less(r.observed_ms,r.requested_ms)
        or (r.claim_released and r.report_debt) then return false end
    for _,v in counts do if not decimal(r[v],false) then return false end end
    if less(r.press_candidates,r.press_publications) or (r.original_result_known and not integer(r.original_result,4294967295))
        or (not r.original_result_known and r.original_result~=nil) then return false end
    if previous then
        for _,v in {"sequence","requested_ms","expires_ms","source_epoch","user","button"} do
            if r[v]~=previous[v] then return false end
        end
        if less(r.observed_ms,previous.observed_ms) then return false end
        for _,v in counts do if less(r[v],previous[v]) then return false end end
        if previous.first_rejection_stage~="none" and (r.first_rejection_stage~=previous.first_rejection_stage
            or r.first_rejection_mask~=previous.first_rejection_mask) then return false end
        if previous.first_actor_observation_known==true then
            for v in actor_fields do if r[v]~=previous[v] then return false end end
        end
        if previous.terminal then for v in fields do if r[v]~=previous[v] then return false end end end
    end
    return true
end
local function clean(r) return r and r.terminal and not r.report_debt and not r.quarantined and r.claim_released end
local function shape(f)
    if not token(f.context) or not integer(f.slot,3) then return false end
    for _,v in {"gesture_down","allowed","loaded"} do if type(f[v])~="boolean" then return false end end
    local o=f.observation
    if type(o)~="table" or not integer(o.state,4294967295) then return false end
    for _,v in {"focused","menu_closed","gameplay","local_player","teleport_pending","grounded",
        "ragdoll_known","ragdoll","fallen"} do if type(o[v])~="boolean" then return false end end
    return true
end
local function common(f)
    local o=f.observation
    return f.allowed and f.loaded and o.focused and o.menu_closed and o.gameplay and o.local_player and not o.teleport_pending
end
local function standing(f,state)
    local o=f.observation
    return common(f) and o.grounded and o.ragdoll_known and not o.ragdoll and not o.fallen and o.state==state
end

function Transition.new() return setmetatable({_attempt=0,_armed=false,_phase="idle",_outcome="idle"},Policy) end
function Policy:_owned() return self._awaiting or self._unknown or (self._handle~=nil and not self._acked) end
function Policy:_fault(why,unsafe)
    self._armed=false
    if self._phase~="idle" and self._phase~="done" then
        self._boundary=self._boundary or why
        if self._suffix then
            self._suffix.first_ms,self._suffix.last_ms,self._suffix.qualified_samples,self._suffix.seconds=nil,nil,0,0
        end
    end
    if unsafe then self._unsafe=true end
end
function Policy:_done(outcome,why)
    self._phase,self._outcome="done",outcome
    self._boundary=self._boundary or why
end
function Policy:_cancel(intents)
    if self._handle and not self._acked and not self._cancel_sent then
        self._cancel_sent=true;intents.cancel={attempt=self._attempt,handle=self._handle}
    end
end
function Policy:_join(f)
    local e=f.request_result
    if e~=nil then
        if type(e)~="table" or not self._awaiting or e.attempt~=self._attempt then self:_fault("request_result_invalid",true)
        else
            self._awaiting=false
            if e.accepted==true and token(e.handle) then self._handle=e.handle
            elseif e.accepted==false and e.handle==nil and type(e.reason)=="string" and #e.reason>0 and #e.reason<=160 then
                self:_done("failed","request_refused:"..e.reason)
            else self._unknown=true;self:_fault("request_unknown",true) end
        end
    end
    e=f.receipt_result
    if e~=nil then
        if type(e)~="table" or not self._handle or self._acked or e.attempt~=self._attempt
            or e.handle~=self._handle or not self._read_pending or e.read_id~=self._read_pending
            or not receipt_valid(e.receipt,self._receipt,self._slot) then self:_fault("receipt_invalid",true)
        else
            self._receipt=copy(e.receipt)
            if e.receipt.actor_retired or e.receipt.orphaned then self:_fault("receipt_context_retired") end
        end
        self._read_pending=nil
    end
    e=f.store_result
    if e~=nil then
        if type(e)~="table" or not self._store_sent or self._store_received or e.attempt~=self._attempt
            or e.handle~=self._handle or not self._terminal or e.sequence~=self._terminal.sequence
            or type(e.accepted)~="boolean" then self:_fault("store_result_invalid",true)
        else
            self._store_received=true
            if e.accepted then self._stored=true else self:_fault("store_failed",true) end
        end
    end
    e=f.ack_result
    if e~=nil then
        if type(e)~="table" or not self._ack_sent or self._ack_received or e.attempt~=self._attempt
            or e.handle~=self._handle or not self._terminal or e.sequence~=self._terminal.sequence
            or type(e.accepted)~="boolean" then self:_fault("ack_result_invalid",true)
        else
            self._ack_received=true
            if e.accepted then self._acked=true else self._ack_failed=true;self:_fault("ack_failed",true) end
        end
    end
    e=f.cancel_result
    if e~=nil then
        if type(e)~="table" or not self._cancel_sent or self._cancel_received or e.attempt~=self._attempt
            or e.handle~=self._handle or type(e.accepted)~="boolean" then self:_fault("cancel_result_invalid",true)
        else self._cancel_received=true end -- Even accepted cancellation proves no cleanup.
    end
end
function Policy:_begin(f)
    self._attempt+=1;self._phase,self._outcome="baseline","pending"
    self._context,self._slot,self._start=f.context,f.slot,f.now_ms
    self._initial,self._expected=f.observation.state,f.observation.state==100 and 504 or 100
    self._quiet_first,self._quiet_last=f.now_ms,f.now_ms
    self._awaiting,self._unknown,self._unsafe,self._handle,self._receipt,self._terminal=false,false,false,nil,nil,nil
    self._boundary,self._acked,self._ack_failed=nil,false,false
    self._read_id,self._read_pending,self._read_at=0,nil,nil
    self._store_sent,self._store_received,self._stored=false,false,false
    self._ack_sent,self._ack_received,self._cancel_sent,self._cancel_received=false,false,false,false
    self._settle_at=nil;self._suffix={samples=0,qualified_samples=0,seconds=0}
end
function Policy:update(f)
    if type(f)~="table" then f={} end
    -- Results are joined even on an invalid observation; a late accepted handle
    -- must remain visible as retained duty rather than disappear on clock loss.
    self:_join(f)
    local clock=integer(f.now_ms,maximum_integer) and (not self._last or f.now_ms>=self._last)
    local fresh=clock and (self._last==nil or f.now_ms>self._last)
    if clock then self._last=f.now_ms else self:_fault("clock_invalid") end
    if not fresh and f.gesture_down==true then self._armed=false end
    local valid=shape(f)
    if not valid then self:_fault("sample_invalid") end
    local intents={}
    local active=self._phase~="idle" and self._phase~="done"
    -- Negative observations are boundaries even at a duplicate timestamp.
    -- Only positive dwell, sample counts and effect progression require fresh
    -- time; a later good frame cannot erase an observed context loss or fall.
    if active and valid then
        if f.context~=self._context or f.slot~=self._slot then self:_fault("context_changed") end
        if not common(f) then self:_fault("readiness_lost") end
        if f.observation.fallen or f.observation.ragdoll_known and f.observation.ragdoll then self:_fault("fall_observed") end
        if self._phase=="baseline" then
            if f.observation.state~=self._initial then self:_fault("baseline_changed") end
            if not standing(f,self._initial) then self._quiet_first,self._quiet_last=nil,nil end
        elseif self._phase=="settling" and not standing(f,self._expected) then
            self._suffix.first_ms,self._suffix.last_ms,self._suffix.qualified_samples,self._suffix.seconds=nil,nil,0,0
        end
    end
    if not clock or not valid then
        if f.loaded==true and self._phase~="done" then self:_cancel(intents) end
    elseif fresh then
        if active and f.now_ms-self._start>=limits.intent_ms then
            if f.loaded then self:_cancel(intents) end
            self:_done(self:_owned() and "unresolved" or "failed","intent_deadline")
        elseif active then
            if self._phase=="baseline" then
                if self._boundary then self:_done("failed",self._boundary)
                elseif f.observation.state~=self._initial then self:_done("failed","baseline_changed")
                elseif not standing(f,self._initial) then self._quiet_first,self._quiet_last=nil,nil
                else
                    if not self._quiet_last or f.now_ms-self._quiet_last>limits.maximum_gap_ms then self._quiet_first=f.now_ms end
                    self._quiet_last=f.now_ms
                    if f.now_ms-self._quiet_first>=limits.baseline_ms then
                        self._phase,self._awaiting,self._requested_at="watching",true,f.now_ms
                        intents.request={attempt=self._attempt,user=self._slot,button="y",expected_state=self._expected}
                    end
                end
            elseif self._phase=="settling" then
                local s=self._suffix
                if self._boundary then self:_done("failed",self._boundary)
                elseif f.now_ms-self._settle_at>limits.settle_bound_ms then self:_done("failed","settle_deadline")
                else
                    s.samples+=1
                    if standing(f,self._expected) then
                        if not s.last_ms or f.now_ms-s.last_ms>limits.maximum_gap_ms then s.first_ms=f.now_ms;s.qualified_samples=0 end
                        s.last_ms=f.now_ms;s.qualified_samples+=1;s.seconds=(f.now_ms-s.first_ms)/1000
                    else s.first_ms,s.last_ms,s.qualified_samples,s.seconds=nil,nil,0,0 end
                    if s.seconds*1000>=limits.settle_ms and s.qualified_samples>=limits.settle_samples then
                        self:_done("target_observed",nil)
                    elseif f.now_ms-self._settle_at>=limits.settle_bound_ms then self:_done("failed","settle_deadline") end
                end
            else
                if self._requested_at and f.now_ms-self._requested_at>=limits.request_ms then self:_fault("request_deadline") end
                if f.loaded and (self._boundary or self._unsafe) then self:_cancel(intents) end
                if self._handle and not self._acked and not self._terminal and f.loaded
                    and not clean(self._receipt)
                    and not self._read_pending and (not self._read_at or f.now_ms-self._read_at>=limits.read_ms) then
                    self._read_id+=1;self._read_pending=self._read_id;self._read_at=f.now_ms
                    intents.read={attempt=self._attempt,handle=self._handle,read_id=self._read_id}
                end
                if clean(self._receipt) and not self._unsafe then
                    self._terminal=self._terminal or copy(self._receipt)
                    if f.loaded and not self._store_sent then
                        self._store_sent=true;self._phase="saving"
                        intents.store={attempt=self._attempt,handle=self._handle,sequence=self._terminal.sequence,receipt=copy(self._terminal)}
                    end
                    if f.loaded and self._stored and not self._ack_sent then
                        self._ack_sent=true;self._phase="acknowledging"
                        intents.acknowledge={attempt=self._attempt,handle=self._handle,sequence=self._terminal.sequence}
                    end
                    if self._acked then
                        if self._boundary then self:_done("failed",self._boundary)
                        elseif self._terminal.status=="cancelled" then self:_done("failed","transport_cancelled")
                        elseif self._terminal.press_publications=="0" or self._terminal.neutral_publications=="0" then
                            self:_done("failed","no_confirmed_report_pair")
                        else self._phase,self._settle_at="settling",f.now_ms end
                    end
                end
            end
        end
        if f.loaded and f.allowed then
            if not f.gesture_down then self._armed=true
            else
                local pressed=self._armed;self._armed=false
                if pressed and not active and not self:_owned() and common(f) and
                    (f.observation.state==100 or f.observation.state==504) and standing(f,f.observation.state)
                    and self._attempt<maximum_integer then self:_begin(f) end
            end
        else self._armed=false end
    elseif active and self._boundary and f.loaded then
        -- Stopping future assertions does not need advancing semantic time.
        self:_cancel(intents)
    end
    local retained=self:_owned()
    local outcome=self._outcome
    if self._phase~="idle" and self._phase~="done" then
        outcome=(self._unsafe or self._unknown or self._boundary and retained) and "unresolved" or "pending"
    end
    local historical=self._outcome=="target_observed"
    return {phase=self._phase,outcome=outcome,reason=self._boundary or "none",attempt=self._attempt,
        initial_state=self._initial,expected_state=self._expected,retained=retained==true,
        acknowledged=self._acked==true,ack_failed=self._ack_failed==true,
        -- Retain the completed suffix as history, while refusing to present it
        -- as current readiness for a changed context or invalid observation.
        historical_transition=historical,
        qualified_transition=historical and clock and valid and f.context==self._context and f.slot==self._slot
            and standing(f,self._expected),receipt=copy(self._receipt),terminal_receipt=copy(self._terminal),
        suffix=copy(self._suffix),intents=intents}
end
function Transition.limits() return copy(limits) end
return Transition

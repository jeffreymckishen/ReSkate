-- Package exact production module copies beside this file; never fork them here.
local Runtime = require("./equipment_runtime")
local Fixture, Trial = {}, {}
Trial.__index = Trial
local KEY = "equipment_interruption_v1"
local MAXIMUM_INTEGER, MAXIMUM_BYTES, MAXIMUM_ROWS = 9007199254740991, 50000, 64
local OVERALL_MS, FALL_MS, PERSIST_MS = 75000, 5000, 250
local function integer(value)
    return type(value)=="number" and value==value and value>=0 and value<=MAXIMUM_INTEGER and value%1==0
end
local function short(value) return tostring(value or ""):sub(1,160) end
local function copy(value,depth)
    if type(value)~="table" then return value end
    depth=depth or 0
    assert(depth<12,"diagnostic snapshot depth exceeded")
    local out={};for k,v in value do out[k]=copy(v,depth+1) end;return out
end
local function call(fn,...)
    if type(fn)~="function" then return false,"API unavailable" end
    return pcall(fn,...)
end
local function clean(status)
    local r=status and status.terminal_receipt
    return type(r)=="table" and status.acknowledged==true and status.retained==false
        and status.storage_accepted==true and r.terminal==true and r.status=="released"
        and r.reason=="none" and r.first_rejection_mask==0 and r.report_debt==false
        and r.claim_released==true and r.quarantined==false and r.orphaned==false
        and r.actor_retired==false and type(r.press_publications)=="string" and r.press_publications~="0"
        and type(r.neutral_publications)=="string" and r.neutral_publications~="0"
end
local function standing(c,state,menu_allowed)
    return c and c.focused==true and (menu_allowed or c.menu_closed==true) and c.gameplay==true
        and c.player_present==true and c.skater==true and c.teleport_pending==false
        and type(c.level)=="string" and #c.level>0
        and c.player_airborne==false and c.airborne==false and c.watch_valid==true
        and c.state==state and c.ragdoll_known==true and c.ragdoll==false
end
local function resolved(status)
    if type(status)~="table" or status.retained~=false or status.phase~="idle" and status.phase~="done" then return false end
    local calls=status.calls
    if type(calls)~="table" then return false end
    if calls.request==0 then return true end
    local r=status.terminal_receipt
    return status.acknowledged==true and type(r)=="table" and r.terminal==true
        and r.claim_released==true and r.report_debt==false and r.quarantined==false
end

function Fixture.new(services,options)
    assert(type(services)=="table","services required")
    options=options or {}
    return setmetatable({_s=services,_adapter=Runtime.new(services),_id=short(options.id or "equipment-interruption-v1"),
        _run=short(options.run_id or "unspecified"),_used=false,_stopped=false,_phase="idle",_verdict="PENDING",
        _detail="Choose one explicit mode in a fresh VM; nothing has been armed.",_tick=0,
        _last={phase="idle",outcome="idle",attempt=0,retained=false,calls={request=0}}},Trial)
end
function Trial:_clock()
    local ok,value=call(self._s.time.now)
    if not ok or type(value)~="number" or value~=value or value<0 or value>MAXIMUM_INTEGER then return nil end
    value=math.floor(value)
    if self._now and value<self._now then return nil end
    self._now=value;return value
end
function Trial:_context(t)
    local ok,c=pcall(function()
        local f,p,w,l=self._s.input.focus(),self._s.skater.get(),self._s.skater.telemetry(),self._s.level.current()
        local watch=type(w)=="table" and type(w.watch)=="table" and w.watch or nil
        local out={at_ms=t,player_present=type(p)=="table"}
        if type(f)=="table" then
            out.focused,out.gameplay=f.focused,f.gameplay
            if type(f.interface_open)=="boolean" then out.menu_closed=not f.interface_open end
        end
        if type(p)=="table" then out.player_airborne=p.airborne end
        if type(w)=="table" then out.skater,out.airborne,out.teleport_pending=w.skater,w.airborne,w.teleport_pending end
        if watch then
            out.watch_valid,out.ragdoll_known,out.ragdoll=watch.valid,watch.ragdoll_known,watch.ragdoll
            if integer(watch.state) then out.state=watch.state end
            if integer(watch.wipeouts) then out.wipeouts=watch.wipeouts end
            if integer(watch.changes) then out.changes=watch.changes end
        end
        if type(l)=="table" and type(l.name)=="string" and #l.name>0 and #l.name<=200 then out.level=l.name end
        return out
    end)
    return ok and c or {at_ms=t,read_error=short(c)}
end
function Trial:_finish(covered,reason,t)
    if self._stopped then return end
    self._stopped=true;self._verdict=covered and "COVERED" or "NOT_COVERED"
    self._phase=covered and "covered" or "not_covered";self._detail=reason
    if self._record then
        self._record.stopped,self._record.verdict,self._record.reason=true,self._verdict,reason
        self._record.finished_ms=t;self._record.qualification_stop_adapter=copy(self._last)
    end
end
function Trial:_persist(t,force)
    if not self._record or self._persistence_disabled then return false end
    if not force and t and self._persist_at and t-self._persist_at<PERSIST_MS then return true end
    self._record.phase=self._phase
    local ok,text=call(self._s.json.encode,self._record)
    local stored
    if ok and type(text)=="string" and #text<=MAXIMUM_BYTES then
        stored=table.pack(call(self._s.storage.set,KEY,self._record))
        ok=stored[1]==true and stored.n==1 -- storage.set returns zero values on success.
    else ok=false end
    if not ok then
        self:_finish(false,"Storage/50000-byte evidence bound refused; no further wipeout call.",t)
        self._persistence_disabled=true;self._verdict="NOT_COVERED";self._phase="not_covered"
        self._detail="Storage refused; last cached record may be older. Production cleanup keeps ticking."
        self._record.stopped,self._record.verdict,self._record.phase=true,self._verdict,self._phase
        self._record.reason,self._record.evidence_error=self._detail,self._detail
        return false
    end
    self._persist_at=t;return true
end
function Trial:arm(mode)
    if self._used then return false,"This VM has already consumed its one Arm." end
    self._used=true
    if mode~="baseline" and mode~="post_terminal" then
        self._phase,self._verdict,self._stopped="blocked","NOT_COVERED",true
        self._detail="Unknown mode";return false,self._detail
    end
    local ok,keys=call(self._s.storage.keys)
    if not ok or type(keys)~="table" or next(keys)~=nil then
        self._phase,self._verdict,self._stopped="blocked","NOT_COVERED",true
        self._detail="Fresh empty plugin storage required; existing evidence was not overwritten."
        return false,self._detail
    end
    local t=self:_clock();local c=self:_context(t);local initial=mode=="baseline" and 100 or 504
    self._record={schema=1,id=self._id,run_id=self._run,mode=mode,started_ms=t,samples={},observed_ticks=0,
        calls={adapter_arm=0,wipeout=0},coverage={window_reached=false,actual_fall_observed=false,model_failed=false,
            fall_failure_latched=false,sampled_context_continuous=true,
            no_qualified_success=true,request_limit_ok=true},verdict="PENDING",stopped=false,
        limits={production_arms=1,production_requests=1,wipeout_calls=1,wipeout_force=.5,adapter_arm_ms=60000,
            overall_ms=OVERALL_MS,fall_observe_ms=FALL_MS,sample_rows=MAXIMUM_ROWS,json_bytes=MAXIMUM_BYTES},
        initial_context=copy(c),scope="Stock equipment interruption only; queue acceptance is not fall or native consumption proof.",
        storage_scope="Host cache acceptance only; operational fresh folder identity and later archived storage are required."}
    self._mode=mode
    if not t or not standing(c,initial,true) then
        self:_finish(false,"Initial grounded stock state refused; mode A requires100 and mode B requires504.",t)
        self:_persist(t,true);return false,self._detail
    end
    if not self:_persist(t,true) then return false,self._detail end
    self._record.calls.adapter_arm=1
    local accepted,why
    ok,accepted,why=pcall(self._adapter.request,self._adapter,0)
    self._record.arm={called=true,accepted_known=ok and type(accepted)=="boolean",accepted=ok and accepted==true,
        detail=short(ok and why or accepted)}
    if not ok or accepted~=true then self:_finish(false,"Production adapter Arm refused or unknown; no retry.",t)
    else self._phase="armed";self._detail="Close the menu; waiting for the unchanged production window." end
    self:_persist(t,true)
    return ok and accepted==true,self._detail
end
function Trial:_fire(t,c)
    if self._wipeout_used or self._stopped then return end
    local r=self._record
    if c.level~=r.initial_context.level then
        self:_finish(false,"Sampled level changed before the interruption; no wipeout call.",t);return
    end
    r.coverage.window_reached=true
    r.wipeout={planned=true,call_attempted=false,at_ms=t,before_context=copy(c),before_adapter=copy(self._last)}
    if not self:_persist(t,true) then return end
    self._wipeout_used=true;self._fired_tick=self._tick;r.calls.wipeout=1;r.wipeout.call_attempted=true
    local ok,accepted,why=call(self._s.skater.wipeout,.5)
    r.wipeout.accepted_known=ok and type(accepted)=="boolean"
    r.wipeout.accepted=ok and accepted==true;r.wipeout.detail=short(ok and why or accepted)
    self._phase="observing";self._detail="One wipeout call made; observing actual fall and adapter failure."
    if not ok or accepted~=true then self:_finish(false,"Wipeout queue refusal/unknown; no retry or recovery.",t) end
    self:_persist(t,true)
end
function Trial:_observe(t,c)
    local r,out=self._record,self._last
    r.latest_adapter_snapshot=copy(out);r.cleanup_resolved=resolved(out)
    if out.terminal_receipt and not r.terminal_receipt then r.terminal_receipt=copy(out.terminal_receipt) end
    if self._stopped then
        r.cleanup_latest_context=copy(c)
        if r.cleanup_resolved and not r.final_adapter_snapshot then r.final_adapter_snapshot=copy(out) end
        return -- Coverage is historical; later menu/focus changes are not part of its window.
    end
    r.observed_ticks=math.min(r.observed_ticks+1,MAXIMUM_INTEGER)
    local request=out.calls and out.calls.request
    if not integer(request) or request>1 then r.coverage.request_limit_ok=false end
    if out.qualified_transition==true or out.historical_transition==true then r.coverage.no_qualified_success=false end
    if out.outcome=="failed" then
        r.coverage.model_failed=true;r.model_failure_reason=short(out.reason)
        if out.reason=="fall_observed" then r.coverage.fall_failure_latched=true end
    end
    if not self._sample_at or t and t-self._sample_at>=250 then
        self._sample_at=t
        if #r.samples<MAXIMUM_ROWS then
            table.insert(r.samples,{context=copy(c),phase=out.phase,outcome=out.outcome,reason=out.reason,
                request=request,retained=out.retained,acknowledged=out.acknowledged})
        else r.sample_rows_capped=true end
    end
    if r.wipeout and r.wipeout.call_attempted and self._tick>self._fired_tick then
        local before=r.wipeout.before_context
        local continuous=c.read_error==nil and c.player_present==true and c.skater==true and c.watch_valid==true
            and c.focused==true and c.menu_closed==true and c.gameplay==true and c.teleport_pending==false
            and type(c.player_airborne)=="boolean" and type(c.airborne)=="boolean"
            and type(c.ragdoll_known)=="boolean" and type(c.ragdoll)=="boolean" and integer(c.state)
            and (not integer(before.wipeouts) or integer(c.wipeouts) and c.wipeouts>=before.wipeouts)
            and type(c.level)=="string" and #c.level>0 and c.level==before.level
        if not continuous then
            r.coverage.sampled_context_continuous=false
            if not r.observation_boundary then r.observation_boundary={at_ms=t,context=copy(c)} end
        else
            local basis={state300=c.state==300,known_ragdoll=c.ragdoll_known==true and c.ragdoll==true,
                wipeouts_increased=integer(c.wipeouts) and integer(before.wipeouts) and c.wipeouts>before.wipeouts}
            if basis.state300 or basis.known_ragdoll or basis.wipeouts_increased then
                r.coverage.actual_fall_observed=true
                if not r.first_fall then r.first_fall={at_ms=t,context=copy(c),basis=basis} end
            end
        end
    end
    if self._stopped and r.cleanup_resolved and not r.final_adapter_snapshot then r.final_adapter_snapshot=copy(out) end
end
function Trial:update()
    self._tick+=1
    -- Never stop the production adapter merely because diagnostic coverage ends.
    -- Its original single Arm, cleanup and watchdogs remain authoritative.
    local ok,out=pcall(self._adapter.update,self._adapter)
    if ok and type(out)=="table" then self._last=out
    elseif self._record then self:_finish(false,"Production adapter update failed; cleanup outcome remains unknown.",self._now) end
    if not self._record then return self:status() end
    local t=self:_clock();local c=self:_context(t)
    self:_observe(t,c)
    local r=self._record
    if not self._stopped then
        if not t or t-r.started_ms>OVERALL_MS then self:_finish(false,"Fixture clock/75s observation bound ended.",t)
        elseif not r.coverage.request_limit_ok then self:_finish(false,"Production request count exceeded or became unknown.",t)
        elseif not r.coverage.no_qualified_success then self:_finish(false,"Intended interruption window missed: target already qualified.",t)
        elseif not self._wipeout_used then
            if self._mode=="baseline" and out.phase=="baseline" and out.calls.request==0 and standing(c,100,false) then
                self:_fire(t,c)
            elseif self._mode=="post_terminal" and out.phase=="settling" and out.calls.request==1
                and out.initial_state==504 and out.expected_state==100 and clean(out) and standing(c,100,false)
                and out.suffix and type(out.suffix.seconds)=="number" and out.suffix.seconds<2.5 then
                self:_fire(t,c)
            elseif out.phase=="done" or out.phase=="idle" or self._mode=="baseline" and out.calls.request~=0 then
                self:_finish(false,"Intended production window missed or Arm ended; no wipeout retry.",t)
            end
        else
            local no_requests=self._mode~="baseline" or out.calls.request==0
            if not no_requests then self:_finish(false,"Baseline interruption missed: a production input request occurred.",t)
            elseif not r.coverage.sampled_context_continuous then
                self:_finish(false,"Post-fire sampled context became unavailable or changed; NOT COVERED.",t)
            elseif out.phase=="done" and out.outcome=="failed" and out.reason~="fall_observed" then
                self:_finish(false,"Production failed for another reason: "..short(out.reason).."; NOT COVERED.",t)
            elseif r.coverage.actual_fall_observed and r.coverage.fall_failure_latched and out.phase=="done"
                and out.outcome=="failed" and out.reason=="fall_observed"
                and r.cleanup_resolved and r.coverage.no_qualified_success then
                self:_finish(true,"Fall observed in the intended window; production attempt failed without qualified success.",t)
            elseif t-r.wipeout.at_ms>=FALL_MS then
                self:_finish(false,"No complete fall/failure/cleanup witness within5s; NOT COVERED.",t)
            end
        end
    end
    if self._stopped and r.cleanup_resolved and not r.final_adapter_snapshot then r.final_adapter_snapshot=copy(self._last) end
    self:_persist(t,self._stopped and not self._stop_saved)
    if self._stopped then self._stop_saved=true end
    return self:status()
end
function Trial:status()
    local r=self._record
    return {phase=self._phase,detail=self._detail,used=self._used,mode=self._mode,verdict=self._verdict,stopped=self._stopped,
        coverage=r and copy(r.coverage) or nil,adapter=copy(self._last),cleanup_resolved=r and r.cleanup_resolved==true or false}
end
function Trial:snapshot() return self._record and copy(self._record) or nil end
function Trial:unload()
    if self._unloaded then return self:status() end
    self._unloaded=true
    local ok,out=pcall(self._adapter.unload,self._adapter)
    if ok and type(out)=="table" then self._last=out end
    if self._record then
        if not self._stopped then self:_finish(false,"VM unload before coverage completed; no recovery or rearm.",self._now) end
        self._record.unloaded=true;self._record.unload_adapter=copy(self._last)
        self._record.latest_adapter_snapshot=copy(self._last)
        self:_persist(self._now,true)
    end
    return self:status()
end
return Fixture

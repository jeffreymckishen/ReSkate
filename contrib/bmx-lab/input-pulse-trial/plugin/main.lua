-- Explicit stock-input diagnostic. Equipment expectations below are Lua policy.
local ID="LuaInputPulse_20261023_v1"
local RUN="2678470e-9c99-4a1d-ae58-e2d7549a837b"
local KEY="game_input_pulse_v1"
local P,S=reskate.input,reskate.skater
local ARM_MS,WATCH_MS,POST_MS,DWELL_MS,SAMPLE_MS=30000,8000,2500,600,200
local phase,detail,used="idle","Choose one explicit slot, then close the menu.",0
local ledger,trial,handle,last_now,last_sample,last_poll,last_persist,quiet_since,quiet_last,quiet_state,post_at
local bound_sequence,cancel_sent,ack_sent

local function short(value)
    return string.sub(tostring(value or ""),1,180)
end
local function copy(value,depth)
    depth=depth or 0
    if type(value)=="vector" then return {x=value.x,y=value.y,z=value.z} end
    if type(value)~="table" then return value end
    if depth>6 then return "depth refused" end
    local out={} for k,v in pairs(value) do out[k]=copy(v,depth+1) end return out
end
local function now()
    local value=reskate.time.now()
    if type(value)~="number" or value~=value or value<0 or value==math.huge then return nil end
    value=math.floor(value)
    if last_now and value<last_now then return nil end
    last_now=value return value
end
local function context(t)
    local f,p,w=P.focus(),S.get(),S.telemetry()
    local watch=w and w.watch
    return {wall_ms=t,focus=f and {focused=f.focused,interface_open=f.interface_open,gameplay=f.gameplay},
        player=p and {position=copy(p.position),airborne=p.airborne},
        telemetry=w and {skater=w.skater,airborne=w.airborne,teleport_pending=w.teleport_pending,
            speed=w.speed,vertical=w.vertical,
            watch=watch and {valid=watch.valid,state=watch.state,previous=watch.previous,
                ragdoll_known=watch.ragdoll_known,ragdoll=watch.ragdoll,
                changes=watch.changes,wipeouts=watch.wipeouts,runouts=watch.runouts}}}
end
local function safe_context(t)
    local ok,c=pcall(context,t)
    return ok and c or {wall_ms=t,read_error=short(c)}
end
local function common(c)
    local f,w=c.focus,c.telemetry
    return f and f.focused==true and f.interface_open==false and f.gameplay==true and
        c.player~=nil and w and w.skater==true and w.teleport_pending==false
end
local function standing(c,state)
    local w=c.telemetry
    return common(c) and c.player.airborne==false and w.airborne==false and w.watch and
        w.watch.valid==true and w.watch.ragdoll_known==true and w.watch.ragdoll==false and
        (state and w.watch.state==state or not state and (w.watch.state==100 or w.watch.state==504))
end
local function fallen(c)
    local w=c.telemetry and c.telemetry.watch
    return w and w.valid==true and (w.state==300 or w.ragdoll_known==true and w.ragdoll==true or
        trial.baseline_wipeouts and type(w.wipeouts)=="number" and w.wipeouts>trial.baseline_wipeouts)
end
local function persist(force,t)
    if not ledger then return true end
    if force==false and t and last_persist and t-last_persist<SAMPLE_MS then return true end
    local encoded_ok,encoded=pcall(reskate.json.encode,ledger)
    if not encoded_ok or #encoded>62000 then
        phase,detail="stopped","Storage encoding/62000-byte bound refused; any duty remains owned by SDK"
        return false
    end
    local ok,why=pcall(reskate.storage.set,KEY,ledger)
    if not ok then phase,detail="stopped","Storage refused: "..short(why) return false end
    last_persist=t or last_now
    return true
end
local function finish(reason,t)
    phase,detail="stopped",reason
    if trial then
        trial.phase,trial.result,trial.finished_wall_ms=phase,reason,t
        trial.handle_retained=handle~=nil
    end
    if ledger then ledger.phase,ledger.result=phase,reason end
    persist()
end
local function sample(c,t)
    if last_sample and t-last_sample<SAMPLE_MS then return end
    last_sample=t;trial.sample_observations+=1
    if #ledger.samples>=48 then ledger.samples_capped=true return end
    local row=copy(c);row.arm=used
    local r=trial.last_receipt
    if r then row.pulse={sequence=r.sequence,status=r.status,reason=r.reason,report_debt=r.report_debt,
        claim_released=r.claim_released,press_publications=r.press_publications,
        neutral_publications=r.neutral_publications,original_failures=r.original_failures,contentions=r.contentions} end
    table.insert(ledger.samples,row)
end
local function cancel_once(reason,t)
    if not handle or cancel_sent then return true end
    cancel_sent=true;trial.calls.cancel+=1
    trial.cancel={requested_wall_ms=t,reason=reason}
    if not persist() then return false end
    local ok,accepted,why=pcall(P.pulse_cancel,handle)
    trial.cancel.accepted=ok and accepted==true
    trial.cancel.detail=short(ok and why or accepted)
    return true
end
local function decimal(value,nonzero)
    return type(value)=="string" and #value<=20 and value:match("^%d+$")~=nil and
        (#value==1 or value:sub(1,1)~="0") and (not nonzero or value~="0")
end
local function receipt_valid(r)
    if type(r)~="table" or not decimal(r.sequence,true) or r.user~=trial.slot or r.button~=0x8000 or
        r.transport~="xinput" or r.source_identity~="observed_stream" or
        r.publication_scope~="process_outer_xinput_buffer" or r.consumption~="unobserved" or
        r.semantic_completion~="unobserved" or type(r.status)~="string" or type(r.reason)~="string" or
        type(r.terminal)~="boolean" or type(r.report_debt)~="boolean" or type(r.claim_released)~="boolean" or
        type(r.quarantined)~="boolean" then return false end
    for _,key in {"requested_ms","expires_ms","observed_ms","source_epoch","press_candidates",
        "press_publications","neutral_publications","original_failures","contentions"} do
        if not decimal(r[key],false) then return false end
    end
    return not bound_sequence or r.sequence==bound_sequence
end
local function read_receipt(t)
    trial.calls.read+=1
    local ok,r,why=pcall(P.pulse_state,handle)
    if not ok or not receipt_valid(r) then
        trial.read_refusal={wall_ms=t,detail=short(ok and why or r)}
        cancel_once("Receipt unavailable or changed",t)
        finish("Receipt unavailable/invalid; handle retained without acknowledgement",t)
        return nil
    end
    bound_sequence=bound_sequence or r.sequence
    trial.last_receipt=copy(r)
    return r
end
local function suffix(c,t)
    local s=trial.observed_suffix
    s.samples+=1
    if standing(c,trial.expected_state) then
        if not s.first_ms or not s.last_ms or t-s.last_ms>250 then s.first_ms=t;s.qualified_samples=0 end
        s.last_ms=t;s.qualified_samples+=1;s.seconds=(t-s.first_ms)/1000
    else
        s.first_ms=nil;s.last_ms=nil;s.qualified_samples=0;s.seconds=0
    end
end
local function arm(slot)
    if used>=4 or handle or phase~="idle" and phase~="stopped" then return end
    local t=now();if not t then phase,detail="refused","Invalid fresh clock" return end
    used+=1
    ledger={schema=1,plugin=ID,run_id=RUN,fixture="explicit-input-pulse-v1",arm=used,samples={},
        limits={arms=4,arm_ms=ARM_MS,request_watch_ms=WATCH_MS,post_observe_ms=POST_MS,
            ready_dwell_ms=DWELL_MS,sample_interval_ms=SAMPLE_MS,samples=48,json_bytes=62000},
        scope="SDK report publications and sampled Lua equipment expectations; no native consumption, global-step, physical-device, or semantic-transition proof."}
    trial={arm=used,slot=slot,armed_wall_ms=t,phase="armed",calls={request=0,read=0,cancel=0,acknowledge=0},
        sample_observations=0,observed_suffix={samples=0,qualified_samples=0,seconds=0}}
    ledger.trial=trial
    phase,detail="armed","Close menu; wait for 600ms qualified stock baseline"
    ledger.phase=phase
    last_sample,last_poll,last_persist,quiet_since,quiet_last,quiet_state,post_at,bound_sequence,cancel_sent,ack_sent=nil,nil,nil,nil,nil,nil,nil,nil,false,false
    persist()
end
local fresh,keys=pcall(reskate.storage.keys)
if reskate.id~=ID or not fresh or type(keys)~="table" or next(keys)~=nil then
    phase,detail,used="refused","Exact fresh identity and empty storage required",4
end
reskate.menu.page("Lua Input Pulse",function(ui)
    ui:note("Explicit Y report pulse: choose slot, close menu, and leave the physical pad neutral. No automatic retry.")
    ui:note("At most 4 arms. Reports are not native consumption proof; sampled state can miss short transitions.")
    ui:note("Archive this arm's storage.json before the next Arm; the next explicit Arm replaces its ledger.")
    for slot=0,3 do
        if ui:button("arm"..slot,"Arm Y slot "..slot,(phase=="idle" or phase=="stopped") and not handle and used<4) then arm(slot) break end
    end
    ui:info("Phase",phase);ui:info("Status",detail);ui:info("Arms",tostring(used))
end)
reskate.on("tick",function()
    if not trial or phase=="stopped" or phase=="refused" then return end
    local t=now()
    if not t then
        cancel_once("Invalid/reversed fixture clock",nil)
        finish("Invalid/reversed clock; cancelled once, any cleanup duty retained",nil)
        return
    end
    local c=safe_context(t)
    if phase=="armed" then
        if t-trial.armed_wall_ms>=ARM_MS then finish("30s arm deadline; no request",t) return end
        if not c.focus or c.focus.focused~=true then finish("Focus lost before request",t) return end
        if fallen(c) then finish("Fall observed before request",t) return end
        if not standing(c,nil) then quiet_since,quiet_last,quiet_state=nil,nil,nil return end
        if not quiet_last or t-quiet_last>250 or quiet_state~=c.telemetry.watch.state then quiet_since=t end
        quiet_state=c.telemetry.watch.state
        quiet_last=t
        if t-quiet_since<DWELL_MS then return end
        trial.baseline=copy(c);trial.initial_state=c.telemetry.watch.state
        trial.baseline_wipeouts=c.telemetry.watch.wipeouts
        trial.expected_state=trial.initial_state==100 and 504 or 100
        trial.ready_dwell_ms=t-quiet_since;trial.request_wall_ms=t;trial.calls.request=1
        trial.phase,phase,ledger.phase="watching","watching","watching"
        detail="One request; watching report receipt and sampled stock state"
        if not persist() then return end
        local ok,h,why=pcall(P.pulse,trial.slot,"y")
        trial.request={accepted=ok and h~=nil,detail=short(ok and why or h)}
        if not ok or not h then finish(ok and "Pulse request refused; no retry" or "Pulse request raised; no retry",t) return end
        handle=h;trial.handle_retained=true;sample(c,t);persist();return
    end
    if phase=="observing" then
        suffix(c,t);sample(c,t)
        if fallen(c) then trial.post_fall_observed=true end
        if not common(c) then trial.post_readiness_lost=true end
        if t-post_at>=POST_MS then
            trial.post_observed_ms=t-post_at;trial.final_context=copy(c)
            local good=trial.acknowledged==true and trial.terminal_receipt.status=="released" and
                trial.terminal_receipt.press_publications~="0" and trial.terminal_receipt.neutral_publications~="0" and
                standing(c,trial.expected_state) and trial.observed_suffix.seconds>=2.5 and
                trial.observed_suffix.qualified_samples>=10 and not trial.post_fall_observed and not trial.post_readiness_lost
            finish(good and "Released reports; expected Lua state observed after bounded follow-up" or
                "Follow-up complete; requested transition not qualified",t)
        else persist(false,t) end
        return
    end
    local expired=t-trial.request_wall_ms>=WATCH_MS
    if fallen(c) then if not cancel_once("Fall observed after request",t) then return end
    elseif not common(c) then if not cancel_once("Focus/menu/gameplay/local readiness lost",t) then return end
    elseif expired then if not cancel_once("8s request watchdog",t) then return end end
    if not last_poll or t-last_poll>=SAMPLE_MS or expired then
        last_poll=t
        local r=read_receipt(t);if not r then return end
        sample(c,t)
        if r.terminal and not r.report_debt and r.claim_released and not r.quarantined then
            trial.terminal_receipt=copy(r);trial.terminal_context=copy(c);trial.terminal_wall_ms=t
            if not persist() then return end
            if not ack_sent then
                ack_sent=true;trial.calls.acknowledge=1
                local ok,accepted,why=pcall(P.pulse_acknowledge,handle)
                trial.acknowledged=ok and accepted==true;trial.ack_detail=short(ok and why or accepted)
                if trial.acknowledged then handle=nil end
            end
            post_at=t;phase,trial.phase,ledger.phase="observing","observing","observing"
            detail="Terminal receipt saved; observing at least 2.5 wall seconds"
            suffix(c,t);persist();return
        end
    end
    if expired then finish("8s watchdog; last receipt and unresolved duty retained",t) else persist(false,t) end
end)
reskate.on("unload",function()
    if trial and phase~="stopped" then
        trial.unloaded=true
        finish("VM unloaded; backend owns revocation and any report cleanup duty",now())
    end
end)

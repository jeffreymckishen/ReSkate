-- Exercises the actual fixture and unchanged adapter with constructed services.
-- These observations cannot qualify a native wipeout or a gameplay transition.
local Fixture=require("./fixture")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    local function copy(value)
        if type(value)~="table" then return value end
        local result={};for key,item in value do result[key]=copy(item) end;return result
    end
    local encode=reskate.json.encode
    local key="equipment_interruption_v1"
    local terminal_key="bmx_equipment_terminal_v1"
    local function fake(state)
        local f={now=1000,state=state or 100,menu=true,focused=true,gameplay=true,player=true,skater=true,watch_valid=true,
            airborne=false,ragdoll=false,wipeouts=0,teleport=false,level="constructed-level",records={},events={},
            calls={pulse=0,read=0,cancel=0,ack=0,wipeout=0,store=0},report="warming",maximum_encoded=0}
        local s={id="EquipmentInterruptionUnit",time={},input={},skater={},level={},json={},storage={}}
        function s.time.now() return f.now end
        function s.input.focus() return {focused=f.focused,interface_open=f.menu,gameplay=f.gameplay} end
        function s.skater.get() if f.player then return {airborne=f.airborne} end end
        function s.skater.telemetry()
            if f.telemetry_fault then error("constructed telemetry read failure") end
            return {skater=f.skater,airborne=f.airborne,teleport_pending=f.teleport,
                watch={valid=f.watch_valid,state=f.state,ragdoll_known=true,ragdoll=f.ragdoll,wipeouts=f.wipeouts}}
        end
        function s.level.current() if f.level then return {name=f.level} end end
        function s.skater.wipeout(force)
            f.calls.wipeout+=1;table.insert(f.events,"wipeout")
            check(force==0.5,"fixture asks for the bounded SDK lab force only")
            if f.wipeout_refused then return false,"constructed refusal" end
            return true -- Acceptance alone deliberately does not change the observations.
        end
        function s.input.pulse(slot,button)
            f.calls.pulse+=1;table.insert(f.events,"pulse")
            check(slot==0 and button=="y","the single explicit adapter gesture uses slot0 and Y")
            f.handle,f.requested=newproxy(),math.floor(f.now)
            return f.handle
        end
        function s.input.pulse_state(handle)
            f.calls.read+=1;check(handle==f.handle,"reads retain the actual opaque handle")
            local clean=f.report=="released" or f.report=="revoked" or f.report=="cancelled"
            local negative=f.report=="revoked" or f.report=="cancelled"
            local debt=f.report=="debt" or f.report=="unclean"
            f.ever_press=f.ever_press or debt or clean and f.report~="cancelled"
            local pressing=f.ever_press==true
            return {sequence="9007199254740994",status=clean and f.report or debt and "pressing" or "warming",
                reason=negative and (f.report=="cancelled" and "cancelled" or "unavailable") or "none",
                user=0,button=0x8000,requested_ms=tostring(f.requested),expires_ms=tostring(f.requested+1000),
                observed_ms=tostring(math.floor(f.now)),source_epoch="9007199254740995",transport="xinput",
                source_identity="observed_stream",publication_scope="process_outer_xinput_buffer",
                consumption="unobserved",semantic_completion="unobserved",terminal=clean,
                report_debt=debt,claim_released=clean,actor_retired=false,orphaned=false,quarantined=false,
                press_candidates=pressing and "7" or "0",press_publications=pressing and "7" or "0",
                neutral_publications=clean and pressing and "1" or "0",original_failures="0",contentions="0",
                first_rejection_mask=f.report=="revoked" and 1280 or 0,
                first_rejection_stage=f.report=="revoked" and "core_plan" or "none",
                original_result_known=true,original_result=0}
        end
        function s.input.pulse_cancel(handle)
            f.calls.cancel+=1;check(handle==f.handle,"cancel retains the exact owned handle");return true
        end
        function s.input.pulse_acknowledge(handle)
            f.calls.ack+=1;table.insert(f.events,"ack")
            check(handle==f.handle and f.records[terminal_key] and
                f.records[terminal_key].receipt.sequence=="9007199254740994",
                "full terminal cache acceptance precedes acknowledgement")
            if f.ack_refused then return false end
            return true
        end
        function s.json.encode(record)
            local text=encode(record);f.maximum_encoded=math.max(f.maximum_encoded,#text)
            if f.oversize and record.limits and record.limits.json_bytes==50000 then return string.rep("x",50001) end
            return text
        end
        function s.storage.keys()
            local keys={};for name in f.records do table.insert(keys,name) end;return keys
        end
        function s.storage.get(name) return copy(f.records[name]) end
        function s.storage.set(name,record)
            f.calls.store+=1
            if f.fail_covered_store and name==key and record.verdict=="COVERED" then
                f.failed_covered_stores=(f.failed_covered_stores or 0)+1
                error("constructed final coverage cache failure")
            end
            if f.store_fault then error("constructed cache failure") end
            if f.store_truthy then return true end -- The actual success contract returns zero values.
            local text=encode(record)
            check(#text<=50000,"every accepted individual ledger stays inside its declared cap")
            f.records[name]=copy(record)
            if name==terminal_key then table.insert(f.events,"terminal_store") end
        end
        function s.log() end
        return f,Fixture.new(s,{id=s.id,run_id="constructed-interruption-run"})
    end
    local function tick(f,a,delta)
        f.now+=delta or 100;return a:update()
    end
    local function ticks(f,a,count,delta)
        local out=a:status();for _=1,count do out=tick(f,a,delta) end;return out
    end
    local function until_call(f,a,name)
        for _=1,30 do if f.calls[name]>0 then return a:status() end;tick(f,a) end
        check(false,"expected one constructed "..name.." call in the bounded window")
    end
    local function fall(f) f.state,f.ragdoll,f.airborne,f.wipeouts=300,true,true,f.wipeouts+1 end
    local function bounded(a)
        local record=a:snapshot();check(type(record)=="table","explicit arm retains a ledger")
        check(#(record.samples or {})<=64 and #encode(record)<=50000,"snapshot rows and encoded bytes remain bounded")
        return record
    end
    local function covered(a)
        local record=bounded(a);local coverage=record.coverage
        check(record.verdict=="COVERED" and coverage.window_reached and coverage.actual_fall_observed and
            coverage.model_failed and coverage.fall_failure_latched and coverage.sampled_context_continuous and
            coverage.no_qualified_success and coverage.request_limit_ok and record.model_failure_reason=="fall_observed",
            "coverage requires a reached window, observed fall and failed model without success")
    end
    do
        local f,a=fake();ticks(f,a,60)
        check(a:status().phase=="idle" and a:snapshot()==nil and not next(f.records),"constructor/status/idle updates are inert")
        check(f.calls.pulse==0 and f.calls.wipeout==0 and f.calls.store==0,"idle never reaches either control service")
        a:unload();check(f.calls.cancel==0,"unused unload is inert");cases+=1
    end
    do
        for _,row in {{100,"post_terminal"},{504,"baseline"},{100,"unknown"}} do
            local f,a=fake(row[1]);check(not a:arm(row[2]),"incorrect initial state/mode refuses the arm")
            ticks(f,a,20);check(f.calls.pulse==0 and f.calls.wipeout==0,"mode guard cannot reach either actuator")
            check(not a:arm("baseline"),"a refused first click cannot become a deferred second gesture")
        end
        cases+=1
    end
    do
        local f,a=fake(100);check(a:arm("baseline"),"explicit baseline Arm accepted")
        ticks(f,a,5);check(f.calls.wipeout==0 and f.calls.pulse==0,"open menu cannot fire or request")
        f.menu=false;until_call(f,a,"wipeout")
        check(f.calls.wipeout==1 and f.calls.pulse==0,"baseline wipeout occurs before any input request")
        fall(f);ticks(f,a,30);covered(a)
        local coverage=encode(a:snapshot().coverage)
        f.menu=true;f.focused=false;ticks(f,a,20)
        check(f.calls.wipeout==1 and f.calls.pulse==0,"later ticks cannot repeat either control")
        check(encode(a:snapshot().coverage)==coverage,"later focus/menu changes cannot rewrite historical coverage")
        check(not a:arm("baseline"),"one VM never rearms");cases+=1
    end
    do
        local f,a=fake(100);check(a:arm("baseline"),"acceptance-only case arms")
        f.menu=false;until_call(f,a,"wipeout");ticks(f,a,170)
        local record=bounded(a)
        check(record.verdict=="NOT_COVERED" and not record.coverage.actual_fall_observed,
            "queued wipeout acceptance is not an observed fall")
        check(f.calls.wipeout==1 and f.calls.pulse<=1,"an unobserved effect cannot trigger a retry")
        cases+=1
    end
    do
        local f,a=fake(504);check(a:arm("post_terminal"),"explicit settling Arm accepted")
        f.menu=false;until_call(f,a,"pulse");ticks(f,a,2)
        check(f.calls.wipeout==0 and f.calls.ack==0,"nonterminal transport cannot open the settling fire window")
        f.report="released";f.state=100;until_call(f,a,"wipeout")
        local indices={};for i,event in f.events do indices[event]=indices[event] or i end
        check(indices.pulse<indices.terminal_store and indices.terminal_store<indices.ack and indices.ack<indices.wipeout,
            "only a clean released, cached and acknowledged terminal precedes settling wipeout")
        fall(f);ticks(f,a,30);covered(a)
        ticks(f,a,20);check(f.calls.pulse==1 and f.calls.wipeout==1 and f.calls.ack==1,"settling interruption is one-shot")
        cases+=1
    end
    do
        for _,report in {"revoked","cancelled","unclean"} do
            local f,a=fake(504);check(a:arm("post_terminal"),"negative terminal scenario arms")
            f.menu=false;until_call(f,a,"pulse");f.report=report;f.state=100;ticks(f,a,170)
            if not a:status().stopped then tick(f,a,76000) end
            local record=bounded(a)
            check(f.calls.wipeout==0 and record.verdict=="NOT_COVERED","non-released/debt-bearing receipt cannot authorize wipeout")
            check(f.calls.pulse==1,"negative transport does not create a replacement pulse")
        end
        cases+=1
    end
    do
        local f,a=fake(100);check(a:arm("baseline"),"late close scenario arms")
        ticks(f,a,1,60001);f.menu=false;ticks(f,a,10)
        local record=bounded(a)
        check(record.verdict=="NOT_COVERED" and not record.coverage.window_reached and
            f.calls.pulse==0 and f.calls.wipeout==0,"expired arm is not a covered interruption or a deferred control")
        local g,b=fake(504);check(b:arm("post_terminal"),"missed settling scenario arms")
        g.menu=false;until_call(g,b,"pulse");g.report="released";g.state=100;tick(g,b,16000);ticks(g,b,10)
        check(bounded(b).verdict=="NOT_COVERED" and g.calls.wipeout==0 and g.calls.pulse==1,
            "missing the bounded settling window cannot fire late or retry")
        cases+=1
    end
    do
        for _,fault in {"store_fault","store_truthy","oversize"} do
            local f,a=fake();f[fault]=true
            check(not a:arm("baseline"),"unaccepted initial cache blocks the fixture")
            ticks(f,a,20);check(f.calls.pulse==0 and f.calls.wipeout==0,"storage uncertainty cannot actuate")
        end
        local f,a=fake();f.records.old={}
        check(not a:arm("baseline") and f.calls.pulse==0 and f.calls.wipeout==0,"nonfresh namespace cannot arm")
        cases+=1
    end
    do
        local f,a=fake(100);check(a:arm("baseline"),"cleanup scenario arms")
        f.menu=false;until_call(f,a,"wipeout");until_call(f,a,"pulse")
        check(a:status().stopped and a:status().verdict=="NOT_COVERED",
            "a missed baseline window stops diagnostic coverage while the existing request remains in its original window")
        f.report="debt";tick(f,a)
        local reads=f.calls.read;ticks(f,a,5)
        check(f.calls.read>reads and f.calls.cancel<=1 and f.calls.ack==0,"stopped fixture continues existing adapter cleanup without debt acknowledgement")
        f.report="cancelled";ticks(f,a,12)
        check(f.calls.pulse==1 and f.calls.wipeout==1 and f.calls.cancel<=1 and f.calls.ack==1,
            "later clean cancellation is cached and acknowledged without another gesture")
        check(bounded(a).cleanup_resolved,"cleanup resolution is reported separately from missed coverage")
        a:unload();a:unload();check(f.calls.cancel<=1,"unload cannot repeat an already joined cancellation")
        cases+=1
    end
    do
        local f,a=fake(504);check(a:arm("post_terminal"),"hard deadline scenario arms")
        f.menu=false;until_call(f,a,"pulse");f.report="debt";tick(f,a)
        local stopped=tick(f,a,76000)
        check(stopped.stopped and stopped.verdict=="NOT_COVERED" and f.calls.wipeout==0,
            "hard fixture deadline ends qualification without a second effect")
        local reads=f.calls.read;f.report="cancelled";ticks(f,a,12)
        local record=bounded(a)
        check(f.calls.read==reads and f.calls.ack==0 and record.latest_adapter_snapshot.retained and not record.cleanup_resolved,
            "a reply beyond the production model deadline stays unresolved rather than inventing cleanup")
        cases+=1
    end
    do
        for _,change in {"level","player","skater"} do
            local f,a=fake(100);check(a:arm("baseline"),"mismatched fall context scenario arms")
            f.menu=false;until_call(f,a,"wipeout");fall(f)
            if change=="level" then f.level="another-level"
            elseif change=="player" then f.player=false
            else f.skater=false end
            ticks(f,a,60)
            local record=bounded(a)
            check(record.verdict=="NOT_COVERED" and not record.coverage.actual_fall_observed,
                "changed-level or missing-player cached watch cannot qualify an actual fall")
            check(f.calls.wipeout==1 and f.calls.pulse==0,"unmatched context cannot create another effect")
        end
        cases+=1
    end
    do
        for _,change in {"focus","transient_level","transient_player","transient_read_error"} do
            local f,a=fake(100);check(a:arm("baseline"),"unrelated failure scenario arms")
            f.menu=false;until_call(f,a,"wipeout")
            if change=="focus" then f.focused=false
            elseif change=="transient_level" then f.level="another-level"
            elseif change=="transient_player" then f.player=false
            else f.telemetry_fault=true end
            tick(f,a)
            f.focused,f.level,f.player,f.telemetry_fault=true,"constructed-level",true,false
            fall(f);ticks(f,a,60)
            local record=bounded(a)
            check(record.verdict=="NOT_COVERED" and record.observation_boundary and
                not record.coverage.sampled_context_continuous and not record.coverage.actual_fall_observed,
                "unrelated failure or transient read loss followed by a fall cannot repair interruption coverage")
            check(f.calls.wipeout==1 and f.calls.pulse==0,"transient context failure cannot rearm the controls")
        end
        cases+=1
    end
    do
        local f,a=fake(100);check(a:arm("baseline"),"final cache failure scenario arms")
        f.menu=false;until_call(f,a,"wipeout");f.fail_covered_store=true;fall(f);ticks(f,a,30)
        local record=bounded(a)
        check(f.failed_covered_stores==1 and record.coverage.actual_fall_observed and record.coverage.fall_failure_latched,
            "the actual complete fall witness reached the exact final COVERED cache attempt")
        check(a:status().verdict=="NOT_COVERED" and record.verdict=="NOT_COVERED" and record.phase=="not_covered"
            and type(record.evidence_error)=="string" and f.records[key].verdict~="COVERED",
            "an unaccepted final coverage save invalidates current status and record without upgrading the older cache")
        check(f.calls.wipeout==1 and f.calls.pulse==0,"a final evidence failure cannot repeat control effects")
        cases+=1
    end
    return {cases=cases,assertions=assertions,native_actions=0}
end
return Tests

-- Focused constructed settling-witness tests; no tests or APIs run on require.
-- Root supplies the current PLAYABLE transition candidate, not the legacy prototype.
local Transition=require("./equipment_transition")
local tests={}
function tests.run()
    local assertions,cases=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local sequence="9007199254740994"
    local function frame(t,changes)
        local f={now_ms=t,context="world-a",slot=0,gesture_down=false,loaded=true,allowed=true,
            observation={focused=true,menu_closed=true,gameplay=true,local_player=true,teleport_pending=false,
                grounded=true,ragdoll_known=true,ragdoll=false,state=100,fallen=false}}
        for k,v in changes or {} do
            if k=="observation" then for field,value in v do f.observation[field]=value end else f[k]=v end
        end
        return f
    end
    local function receipt(status,changes)
        local r={sequence=sequence,status=status or "warming",reason="none",user=0,button=0x8000,
            requested_ms="9007199254740997",expires_ms="9007199254741997",observed_ms="9007199254741250",source_epoch="9007199254740995",
            transport="xinput",source_identity="observed_stream",publication_scope="process_outer_xinput_buffer",
            consumption="unobserved",semantic_completion="unobserved",first_rejection_mask=0,first_rejection_stage="none",
            press_candidates="0",press_publications="0",neutral_publications="0",original_failures="0",contentions="0",
            terminal=false,report_debt=false,claim_released=false,actor_retired=false,orphaned=false,quarantined=false,
            original_result_known=false}
        if status=="released" or status=="revoked" or status=="cancelled" or status=="expired" then
            r.terminal,r.claim_released=true,true
            r.press_candidates,r.press_publications,r.neutral_publications="7","7","1"
        end
        if status=="revoked" then r.reason,r.first_rejection_mask,r.first_rejection_stage="unavailable",1280,"core_plan" end
        if status=="cancelled" then r.reason="cancelled" end
        if status=="expired" then r.reason="deadline" end
        for k,v in changes or {} do r[k]=v end
        return r
    end
    local function start(initial)
        local p=Transition.new();initial=initial or 100
        check(not p:update(frame(0,{observation={state=initial}})).intents.request,"neutral only arms")
        local o=p:update(frame(1,{gesture_down=true,observation={state=initial}}))
        check(o.phase=="baseline" and not o.intents.request,"one gesture starts independent readiness qualification")
        for t=101,501,100 do
            o=p:update(frame(t,{gesture_down=true,observation={state=initial}}))
            check(not o.intents.request,"baseline cannot request before600ms")
        end
        o=p:update(frame(601,{gesture_down=true,observation={state=initial}}))
        check(o.intents.request and o.intents.request.attempt==1 and o.intents.request.user==0 and o.intents.request.button=="y",
            "qualified baseline emits one Y request")
        check(o.initial_state==initial and o.expected_state==(initial==100 and 504 or 100),"target freezes from initial stock state")
        return p
    end
    local function accepted(initial)
        local p=start(initial)
        local o=p:update(frame(602,{request_result={attempt=1,accepted=true,handle="pulse-a"},observation={state=initial or 100}}))
        check(o.intents.read and o.intents.read.read_id==1 and o.retained,"accepted opaque handle produces correlated read")
        return p,o.intents.read.read_id
    end
    local function read(p,t,r,read_id,changes)
        local f=frame(t,{receipt_result={attempt=1,handle="pulse-a",read_id=read_id or 1,receipt=r}})
        for k,v in changes or {} do
            if k=="observation" then for field,value in v do f.observation[field]=value end else f[k]=v end
        end
        return p:update(f)
    end
    local function saved_and_acked(p,status,initial)
        local o=read(p,603,receipt(status or "released"),1,{observation={state=initial or 100}})
        check(o.intents.store and o.intents.store.receipt.sequence==sequence and not o.intents.acknowledge,
            "complete terminal receipt is returned for storage before acknowledgement")
        check(not o.intents.read,"clean terminal does not launch a redundant in-flight read")
        o=p:update(frame(604,{store_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true},observation={state=initial or 100}}))
        check(o.intents.acknowledge and not o.intents.store,"confirmed storage emits exactly one acknowledgement")
        o=p:update(frame(605,{ack_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true},observation={state=initial or 100}}))
        check(o.phase=="settling" and o.acknowledged and not o.retained,"accepted acknowledgement starts separate wall-time observation")
        return o
    end
    -- Focused additive witness tests. Root must supply the PLAYABLE transition
    -- candidate (8848 preimage plus witness), not the old adjacent prototype.
    -- These constructed histories cannot infer any missing R84 predicate.
    do
        local p=accepted(504);local o=saved_and_acked(p,"released",504)
        check(o.acknowledged and o.phase=="settling" and not o.qualified_transition
            and o.suffix.last_failure==nil,"transport ACK starts separate observation with no invented failure")
        o=p:update(frame(705,{observation={state=504}}))
        check(o.phase=="settling" and o.suffix.last_failure=="state_mismatch" and o.suffix.qualified_samples==0
            and o.outcome=="pending","ACK is not expected100 success when state stays504")
        o=p:update(frame(805,{observation={state=100,grounded=false}}))
        check(o.suffix.last_failure=="grounded_false" and o.suffix.qualified_samples==0 and not o.qualified_transition,
            "target100 without grounded truth differs from a state mismatch")
        o=p:update(frame(905,{observation={state=100,ragdoll_known=false}}))
        check(o.suffix.last_failure=="ragdoll_unknown" and o.suffix.qualified_samples==0,
            "unknown ragdoll truth is the most recent valid nonstanding predicate")
        o=p:update(frame(1005,{observation={state=100}}))
        check(o.suffix.qualified_samples==1 and o.suffix.last_failure=="ragdoll_unknown" and not o.qualified_transition,
            "one later good sample neither completes dwell nor erases the historical failure")
        o=p:update(frame(6605,{observation={state=100}}))
        check(o.phase=="done" and o.outcome=="failed" and o.reason=="settle_deadline" and o.acknowledged
            and not o.qualified_transition and o.suffix.last_failure=="ragdoll_unknown",
            "original bounded settle deadline remains independent of acknowledged transport")
        check(not o.intents.request and not o.intents.read and not o.intents.store and not o.intents.acknowledge,
            "diagnostic and deadline never create a request/read/store/ACK retry")
        cases+=1
    end
    do
        local p=accepted(504);saved_and_acked(p,"released",504)
        p:update(frame(705,{observation={state=100}}))
        local o=p:update(frame(805,{observation={state=100}}))
        check(o.suffix.qualified_samples==2 and o.suffix.last_failure==nil and not o.qualified_transition,
            "a real qualified prefix exists before a later suffix reset")
        o=p:update(frame(805,{observation={state=504,grounded=false,ragdoll_known=false}}))
        check(o.suffix.qualified_samples==0 and o.suffix.seconds==0 and o.suffix.last_failure=="grounded_false",
            "duplicate-time negative resets original suffix and records first failing standing predicate")
        o=p:update(frame(805,{observation={state=100}}))
        check(o.suffix.qualified_samples==0 and o.suffix.last_failure=="grounded_false" and not o.qualified_transition,
            "duplicate positive cannot accrue dwell or erase the negative witness")
        o=p:update(frame(905,{observation={state=504}}))
        check(o.suffix.last_failure=="state_mismatch","later valid nonstanding frame replaces the earlier failure")
        o=p:update(frame(1005,{observation={state=100,ragdoll_known=false}}))
        check(o.suffix.last_failure=="ragdoll_unknown","most recent unknown replaces mismatch in call order")
        o.suffix.last_failure="caller_mutation"
        o=p:update(frame(1105,{observation={state=100}}))
        check(o.suffix.qualified_samples==1 and o.suffix.last_failure=="ragdoll_unknown",
            "new positive prefix retains internal historical witness despite caller copy mutation")
        for t=1305,3505,200 do
            o=p:update(frame(t,{observation={state=100}}))
            check(not o.qualified_transition,"historical failure cannot shorten original2.5second dwell")
        end
        o=p:update(frame(3705,{observation={state=100}}))
        check(o.phase=="done" and o.outcome=="target_observed" and o.historical_transition and o.qualified_transition
            and o.suffix.last_failure=="ragdoll_unknown",
            "later actual success preserves diagnostic as history rather than a success veto")
        o=p:update(frame(3905,{observation={state=504}}))
        check(o.historical_transition and not o.qualified_transition and o.suffix.last_failure=="ragdoll_unknown",
            "afterdone witness is historical only and does not mutate with later invalid readiness")
        p:update(frame(4005,{observation={state=100}}))
        o=p:update(frame(4006,{gesture_down=true,observation={state=100}}))
        check(o.attempt==2 and o.phase=="baseline" and o.expected_state==504 and o.suffix.last_failure==nil
            and not o.intents.request,"only a fresh next_begin clears the witness and still requires baseline dwell")
        cases+=1
    end
    do
        local p=accepted(504);saved_and_acked(p,"released",504)
        local o=p:update(frame(705,{allowed=false,observation={state=100,grounded=false}}))
        check(o.phase=="done" and o.outcome=="failed" and o.reason=="readiness_lost"
            and o.suffix.last_failure=="allowed_false" and not o.qualified_transition,
            "unchanged common gate wins predicate order and remains a real failure")
        check(o.acknowledged and not o.retained and not o.intents.request and not o.intents.read
            and not o.intents.store and not o.intents.acknowledge,
            "one common-gate witness adds no transport or retained cleanup authority")
        o=p:update(frame(805,{observation={state=100}}))
        check(o.outcome=="failed" and o.suffix.last_failure=="allowed_false" and not o.qualified_transition,
            "a later positive frame cannot revive an already failed common gate")
        cases+=1
    end
    return {cases=cases,assertions=assertions,native_actions=0}
end
return tests

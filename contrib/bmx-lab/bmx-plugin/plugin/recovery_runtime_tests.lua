-- Constructed observations only; no SDK Host, game, HID or native recovery.
local Runtime = require("./recovery_runtime")
local tests = {}
function tests.run()
    local cases, assertions = 0, 0
    local function check(v, why) assertions += 1; assert(v, why) end
    local function copy(v) if type(v) ~= "table" then return v end; local o = {}; for k,x in pairs(v) do o[k] = copy(x) end; return o end
    local actor, session, body, lease = newproxy(), newproxy(), newproxy(), newproxy()
    local api_calls = 0
    local function forbidden() api_calls += 1; error("pure adapter called a service") end
    local api = {recover=forbidden,recovery_state=forbidden,recovery_cancel=forbidden,recovery_acknowledge=forbidden}
    local source = {lease_handle=lease,generation=4,user=0,sequence="9007199254740994",
        source_epoch="9007199254740995",context_generation="18446744073709551614"}
    local function frame(n, changes)
        local f = {valid=true,fresh=true,active=true,loaded=true,now_ms=n*17+.75,
            body_handle=body,source=copy(source),bike={sequence="9007199254740997"},
            gates={focused=true,menu_open=false},get_up_down=false,
            telemetry={watch={valid=true,ragdoll_known=true,ragdoll=false}},
            observed={actor=actor,session=session,epoch=newproxy(),serial=tostring(n),time=n/60,seconds=1/60,
                committed_state=504,ragdoll_known=true,ragdoll=false,in_air_known=true,in_air=false,offboard=true,standable=true}}
        for k,v in pairs(changes or {}) do f[k]=v end
        return f
    end
    local function adapter(extra)
        local o = {enabled=true,allow_get_up=true,skater_api=api}
        for k,v in pairs(extra or {}) do o[k]=v end
        return Runtime.new(o)
    end
    local function fallen(r)
        r:update(frame(1))
        local f=frame(2);f.observed.ragdoll=true;f.observed.committed_state=300
        local result=r:update(f)
        check(result.requests.stop and result.requests.stop.reason=="sampled_fall", "actual fall asks sole coordinator to stop")
        check(result.suppress_forces and result.suppress_follow and result.duties_retained, "stop keeps exact duties")
        check(result.duties.body_handle==body and result.duties.source.source_epoch==source.source_epoch,"exact body and u64 source retained")
        return result
    end
    local function cleanup(incident)
        local ids={user=source.user,sequence=source.sequence,source_epoch=source.source_epoch,context_generation=source.context_generation}
        local s={phase="complete",lease_handle_present=false,cleanup_pending=false,cleanup_unknown=false,generation=5,
            sample=copy(ids),lease_state=copy(ids),capture_state=copy(ids)}
        s.lease_state.terminal=true;s.lease_state.source_released=true;s.lease_state.capture_reserved=false
        s.capture_state.phase="complete";s.capture_state.terminal=true;s.capture_state.report_debt=false;s.capture_state.quarantined=false
        return {incident=incident,body_handle=body,source=copy(source),bike={schema=1,kind="bike-lifecycle-v1",phase="done",
            bike_cleanup_complete=true,bike_authority=false,cleanup_pending=false,cleanup_unknown=false,unloaded=false,
            stop_latched=true,completed_acknowledged=true,acknowledged=true,source=s,equipment={phase="done",retained=false,unloaded=false},
            terminal_receipt={sequence="9007199254740997",phase="completed",terminal=true,park_observed=true,in_flight=0,
                pending={},final_revision="4",final_native_epoch="75",returned_revision="4",native_retirement_known=false}}}
    end
    local function cleaned(r)
        fallen(r)
        local f=frame(3);f.observed.ragdoll=true;f.cleanup=cleanup(1)
        local result=r:update(f)
        check(result.cleanup_qualified and not result.duties_retained and not result.requests.recovery,"positive complete park ACK/drain permits explicit stage only")
        return result
    end
    local function requested(r)
        cleaned(r)
        local f=frame(4);f.observed.ragdoll=true;f.get_up_down=true
        local result=r:update(f)
        check(result.requests.recovery and result.requests.recovery.request and result.recovery.retained,"fresh explicit get-up requests one bounded policy attempt")
        return result
    end
    local function receipt(status)
        local r={kind="get_up",status=status or "pending",reason="none",sequence="9007199254741000",requested_ms="20",observed_ms="21",terminal=false,
            native_true_calls=0,native_reset_calls=0,start_attempts=0,cleanup_attempts=0,true_entered=false,true_returned=false,
            reset_pending=false,reset_entered=false,reset_returned=false,reset_readback_known=false,reset_false=false,
            cleared_before_reset=false,unresolved=false,actor_retired=false,quarantined=false,standing_observed=false,stable_observed=false,
            standing_samples=0,standing_seconds=0,standing_required_seconds=2}
        if status=="completed" then
            r.terminal=true;r.true_entered=true;r.true_returned=true;r.true_readback=true;r.prior_value=false
            r.true_ms="21";r.true_serial="80";r.true_time=1;r.native_true_calls=1;r.start_attempts=1
            r.reset_false=true;r.reset_readback_known=true;r.reset_entered=true;r.reset_returned=true
            r.reset_ms="38";r.reset_serial="81";r.reset_time=1+1/60;r.native_reset_calls=1;r.cleanup_attempts=1
            r.observed_ms="2038";r.standing_observed=true;r.stable_observed=true;r.standing_samples=122
            r.standing_seconds=2.0166665464639664;r.committed_state=504;r.ragdoll=false;r.in_air=false
        end
        return r
    end
    local function neutral_source(n)
        local s=copy(source);s.lease_handle=newproxy();s.generation=6;s.sequence="9007199254740995"
        s.observation_serial=tostring(n);s.observed_ms=tostring(n*17);s.pad={playstation=false,buttons={}}
        for _,k in ipairs({"left_x","left_y","right_x","right_y","left_trigger","right_trigger"}) do s.pad[k]=0 end
        for _,k in ipairs({"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"}) do s.pad.buttons[k]=false end
        return s
    end
    do
        local r=Runtime.new({skater_api=api});local f=frame(1);f.observed.ragdoll=true
        local result=r:update(f)
        check(not result.enabled and result.phase=="inactive" and next(result.requests)==nil,"default construction is inactive")
        check(api_calls==0,"construction never calls services")
        cases+=1
    end
    do
        local r=adapter();fallen(r)
        for n=3,30 do local o=r:update(frame(n));check(not o.requests.stop and not o.requests.recovery and o.duties_retained,"held incident neither repeats stop nor guesses cleanup") end
        local o=r:status();o.duties.source.source_epoch="2"
        check(r:status().duties.source.source_epoch==source.source_epoch,"detached status cannot rewrite exact duty")
        cases+=1
    end
    do
        for _,bad in ipairs({false,"missing_frame",0}) do
            local r=adapter();r:update(frame(1));local o=r:update(bad)
            check(o.requests.stop and o.duties_retained and o.suppress_forces,"malformed later frame cannot forget an active owner")
            check(o.duties.body_handle==body and o.duties.source.sequence==source.sequence,"malformed frame retains prior exact ownership")
        end
        cases+=1
    end
    do
        local r=adapter();r:update(frame(1));local f=frame(2);f.observed=nil;f.telemetry.watch.ragdoll=true
        local o=r:update(f)
        check(o.requests.stop and o.requests.stop.reason=="sampled_fall","actual telemetry alone can conservatively stop")
        check(not o.requests.recovery and not o.rearm_ready,"telemetry cannot authorize get-up or rearm")
        cases+=1
    end
    do
        for _,counter in ipairs({8,6}) do
            local r=adapter();local f=frame(1);f.telemetry.watch.wipeouts=7;r:update(f)
            f=frame(2);f.observed=nil;f.telemetry.watch.wipeouts=counter
            local o=r:update(f)
            check(o.requests.stop and o.duties_retained,"actual wipeout counter edge or rewind conservatively stops without invented native identity")
            check(not o.requests.recovery and not o.rearm_ready,"sampled counter cannot authorize get-up or rearm")
        end
        local r=adapter();r:update(frame(1));local f=frame(2);f.body_handle=newproxy();local o=r:update(f)
        check(o.requests.stop and o.duties.body_handle==body,"native body handle replacement retains old body duty")
        cases+=1
    end
    do
        for _,field in ipairs({"session","actor"}) do
            local r=adapter();r:update(frame(1));local f=frame(2);f.observed[field]=newproxy()
            local o=r:update(f)
            check(o.requests.stop and o.requests.stop.reason=="sampled_actor_or_session_changed","measured identity replacement stops")
            check(o.duties.observed.actor==actor and o.duties.observed.session==session,"replacement retains original actor/session duty")
        end
        cases+=1
    end
    do
        for _,field in ipairs({"lease_handle","generation","user","sequence","source_epoch","context_generation"}) do
            local r=adapter();r:update(frame(1));local f=frame(2)
            f.source[field]=field=="lease_handle" and newproxy() or field=="user" and 1 or field=="generation" and 5 or "9007199254740996"
            local o=r:update(f)
            check(o.requests.stop and o.duties.source[field]==source[field],"source change retains original exact ownership, including adjacent >2^53 epochs")
        end
        cases+=1
    end
    do
        local r=adapter();local f=frame(1);f.body_handle=nil;f.source=nil;f.observed.ragdoll=true
        local o=r:update(f)
        check(o.requests.stop and o.phase=="retained_unknown" and not o.cleanup_qualified,"missing owned identity cannot be fabricated")
        f=frame(2);f.cleanup=cleanup(1);o=r:update(f)
        check(o.phase=="retained_unknown" and not o.cleanup_qualified,"later unrelated cleanup cannot repair lost incident identity")
        cases+=1
    end
    do
        for _,change in ipairs({
            function(c)c.incident=2 end,function(c)c.body_handle=newproxy()end,
            function(c)c.source.source_epoch="9007199254740996"end,function(c)c.bike.completed_acknowledged=false end,
            function(c)c.bike.acknowledged=false end,function(c)c.bike.terminal_receipt.park_observed=false end,
            function(c)c.bike.terminal_receipt.returned_revision="3"end,function(c)c.bike.terminal_receipt.sequence="9007199254740998"end,
            function(c)c.bike.terminal_receipt.final_revision="0";c.bike.terminal_receipt.returned_revision="0"end,
            function(c)c.bike.terminal_receipt.final_native_epoch="0"end,
            function(c)c.bike.terminal_receipt.pending={"body_parked"}end,function(c)c.bike.terminal_receipt.in_flight=1 end,
            function(c)c.bike.bike_cleanup_complete=false end,function(c)c.bike.bike_authority=true end,
            function(c)c.bike.cleanup_unknown=true end,function(c)c.bike.phase="retained_unknown"end,
            function(c)c.bike.source.cleanup_unknown=true end,function(c)c.bike.source.lease_handle_present=true end,
            function(c)c.bike.source.capture_state.report_debt=true end,function(c)c.bike.source.capture_state.quarantined=true end,
            function(c)c.bike.source.lease_state.source_released=false end,function(c)c.bike.source.lease_state.capture_reserved=true end,
            function(c)c.bike.source.sample.sequence="9007199254740995"end,function(c)c.bike.equipment.retained=true end,
        }) do
            local r=adapter();fallen(r);local f=frame(3);f.cleanup=cleanup(1);change(f.cleanup);f.get_up_down=true
            local o=r:update(f)
            check(o.duties_retained and not o.cleanup_qualified and not o.requests.recovery,"partial/mismatched cleanup cannot release or get up")
        end
        cases+=1
    end
    do
        local r=adapter();fallen(r);local f=frame(3);f.cleanup=cleanup(1)
        f.cleanup.bike.terminal_receipt.final_revision="0"
        f.cleanup.bike.terminal_receipt.final_native_epoch="0"
        f.cleanup.bike.terminal_receipt.returned_revision="0"
        local o=r:update(f)
        check(o.cleanup_qualified and not o.duties_retained,"actual API permits paired-zero completed park ACK; zero is not an invented copied epoch")
        cases+=1
    end
    do
        local r=adapter();fallen(r)
        local f=frame(120000);f.bike={phase="done",ordinary_release_accepted=true};f.visual_targets={upright=true};f.get_up_down=true
        local o=r:update(f)
        check(o.duties_retained and not o.cleanup_qualified and not o.requests.recovery,"timeout/returned release/visual target/focus cannot prove park")
        cases+=1
    end
    do
        local r=adapter({skater_api={}});cleaned(r)
        local f=frame(4);f.observed.ragdoll=true;f.get_up_down=true
        local o=r:update(f)
        check(not o.recovery_available and not o.requests.recovery and o.issue=="generic_recovery_api_unavailable","missing generic API refuses instead of inventing a call")
        cases+=1
    end
    do
        local r=adapter();fallen(r)
        local f=frame(3);f.observed.ragdoll=true;f.get_up_down=true;r:update(f)
        f=frame(4);f.cleanup=cleanup(1);f.observed.ragdoll=true;f.get_up_down=true
        local o=r:update(f);check(not o.requests.recovery,"gesture held before readiness cannot dispatch once cleanup arrives")
        f=frame(5);f.observed.ragdoll=true;r:update(f)
        f=frame(6);f.observed.ragdoll=true;f.get_up_down=true;o=r:update(f)
        check(o.requests.recovery and o.requests.recovery.request,"fresh neutral then explicit press can request after cleanup")
        cases+=1
    end
    do
        local r=adapter();fallen(r)
        local f=frame(3);f.cleanup=cleanup(1);f.observed.ragdoll=true;f.get_up_down=nil;r:update(f)
        f=frame(4);f.observed.ragdoll=true;f.get_up_down=true
        check(not r:update(f).requests.recovery,"missing get-up observation cannot invent a neutral arm edge")
        f=frame(5);f.observed.ragdoll=true;r:update(f)
        f=frame(6);f.observed.ragdoll=true;f.get_up_down=true
        check(r:update(f).requests.recovery.request,"known neutral then explicit press works after missing input")
        cases+=1
    end
    do
        local r=adapter();requested(r)
        local f=frame(5);f.recovery_reply={request_result={attempt=1,uncertain=true}}
        local o=r:update(f)
        check(o.recovery.retained and o.recovery.outcome=="request_unknown","lost return retains bounded request")
        for n=6,35 do
            f=frame(n);f.get_up_down=n%2==0;f.source=neutral_source(n);o=r:update(f)
            check(o.recovery.retained and not o.requests.recovery and not o.rearm_ready,"unknown recovery never retries or rearms on another source")
        end
        cases+=1
    end
    do
        local r=adapter();requested(r)
        local f=frame(5);f.recovery_reply={request_result={attempt=1,accepted=false,reason="busy"}};r:update(f)
        for n=6,30 do f=frame(n);f.observed.ragdoll=true;f.get_up_down=n%2==0;local o=r:update(f);check(not o.requests.recovery,"known refusal cannot retry same fall") end
        cases+=1
    end
    do
        local r=adapter();requested(r);local handle=newproxy()
        local f=frame(5);f.recovery_reply={request_result={attempt=1,accepted=true,handle=handle}};r:update(f)
        f=frame(6);f.recovery_reply={receipt_handle=handle,receipt=receipt("completed")}
        local o=r:update(f)
        check(o.requests.recovery.acknowledge and not o.rearm_ready and o.standing_samples==0,"native completed receipt is saved before ACK but never substitutes for fresh standing")
        f=frame(7);f.recovery_reply={ack_result={attempt=1,handle=handle,accepted=false}};o=r:update(f)
        check(o.recovery.retained and o.recovery.ack_failed,"refused SDK ACK retains debt")
        for n=8,12 do o=r:update(frame(n));check(not o.requests.recovery and not o.rearm_ready,"unknown/refused ACK is never automatically retried") end
        cases+=1
    end
    do
        local r=adapter();cleaned(r)
        local o
        for n=4,135 do o=r:update(frame(n)) end
        check(o.standing_seconds>=2 and o.standing_samples>=30 and not o.rearm_ready,"stable actual standing still requires a new source")
        local f=frame(136);f.source=neutral_source(136);o=r:update(f)
        check(o.rearm_ready and o.phase=="ready_for_explicit_rearm" and o.suppress_forces and o.suppress_follow,"fresh standing plus new neutral source only grants eligibility, never restarts effects")
        local cached=copy(f.source);f=frame(137);f.source=cached;o=r:update(f)
        check(not o.rearm_ready,"repeated cached neutral input is not a fresh source observation")
        f=frame(138);f.gates.focused=false;o=r:update(f)
        check(not o.rearm_ready and o.standing_samples==0,"focus loss revokes current rearm eligibility")
        cases+=1
    end
    do
        local r=adapter();cleaned(r)
        local duplicate=frame(4);r:update(duplicate)
        for _=1,200 do local o=r:update(duplicate);check(not o.rearm_ready and o.standing_samples<=1,"repeated actual sample never creates simulated standing time") end
        local reread=copy(duplicate);reread.observed.epoch=newproxy();reread.now_ms+=1
        local reread_result=r:update(reread)
        check(reread_result.standing_samples==1,"new opaque wrapper for identical native serial/time is not a session change")
        local f=frame(5);f.observed.epoch=duplicate.observed.epoch;f.observed.serial=duplicate.observed.serial;f.observed.time=duplicate.observed.time;f.observed.ragdoll=true
        local o=r:update(f);check(not o.rearm_ready and o.standing_samples==0,"changed duplicate native sample fails closed")
        cases+=1
    end
    do
        for _,alter in ipairs({
            function(f)f.observed.ragdoll=true end,function(f)f.observed.in_air=true end,
            function(f)f.observed.committed_state=100 end,function(f)f.observed.offboard=false end,
            function(f)f.observed.standable=false end,function(f)f.observed.session=newproxy()end,
            function(f)f.observed.actor=newproxy()end,function(f)f.observed.ragdoll_known=false end,
            function(f)f.observed.in_air_known=false end,function(f)f.observed.epoch=nil end,
        }) do
            local r=adapter();cleaned(r)
            for n=4,80 do r:update(frame(n)) end
            local f=frame(81);alter(f);local o=r:update(f)
            check(not o.rearm_ready and o.standing_samples==0,"missing/changed/non-standing actual proof interrupts bounded suffix")
        end
        cases+=1
    end
    do
        local r=adapter();cleaned(r)
        for n=4,80 do r:update(frame(n)) end
        local f=frame(81);f.observed.time=10;local o=r:update(f)
        check(o.standing_samples==1 and o.standing_seconds==0,"large native observation gap starts a fresh suffix")
        f=frame(82);f.now_ms=0/0;f.observed.time=10+1/60;o=r:update(f)
        check(not o.rearm_ready,"invalid wall clock cannot grant rearm")
        cases+=1
    end
    do
        local r=adapter();cleaned(r)
        local f=frame(4);f.observed.ragdoll=true;f.get_up_down=true;f.now_ms=51.75
        check(not r:update(f).requests.recovery,"equal floored wall clock cannot spend explicit gesture")
        f=frame(5);f.observed.ragdoll=true;f.get_up_down=true
        check(not r:update(f).requests.recovery,"equal-clock press is consumed rather than deferred")
        cases+=1
    end
    check(api_calls==0,"all constructed transitions perform zero API calls")
    return {cases=cases,assertions=assertions,native_actions=api_calls}
end
return tests

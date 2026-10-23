-- Portable receipt/gesture model only. Requiring this module is inert.
local Recovery = require("./recovery")
local tests = {}

function tests.run()
    local assertions,cases = 0,0
    local function check(ok,why) assertions += 1; assert(ok,why) end
    local function copy(t) local o={}; for k,v in t do o[k]=v end; return o end
    local function frame(now,changes)
        local f={now_ms=now,actor="actor-a",source_epoch=1,fall_epoch=1,gesture_down=false,
            allowed=true,loaded=true,fallen=true,park_ready=true,release_ready=true}
        for k,v in changes or {} do f[k]=v end
        return f
    end
    local function request(p)
        check(not p:update(frame(1)).intents.request,"neutral is observation only")
        local o=p:update(frame(2,{gesture_down=true}))
        check(o.intents.request and o.intents.request.attempt==1 and o.retained,"one explicit gesture requests once")
        return o.intents.request.attempt
    end
    local function accepted()
        local p=Recovery.new();local attempt=request(p)
        local o=p:update(frame(3,{request_result={attempt=attempt,accepted=true,handle="handle-a"}}))
        check(o.intents.poll and not o.intents.request and o.retained,"acceptance joins opaque handle before polling")
        return p
    end
    local function receipt(status)
        local r={kind="get_up",status=status or "pending",reason="none",sequence="9007199254740994",
            requested_ms="9007199254740997",observed_ms="9007199254740997",terminal=false,
            native_true_calls=0,native_reset_calls=0,start_attempts=0,cleanup_attempts=0,
            true_entered=false,true_returned=false,reset_pending=false,reset_entered=false,reset_returned=false,
            reset_readback_known=false,reset_false=false,cleared_before_reset=false,unresolved=false,
            actor_retired=false,quarantined=false,standing_observed=false,stable_observed=false,
            standing_samples=0,standing_seconds=0,standing_required_seconds=2}
        if status=="entered" or status=="reset" or status=="completed" then
            r.true_entered,r.true_returned,r.true_readback,r.prior_value=true,true,true,false
            r.true_ms,r.true_serial,r.true_time="9007199254741001","9007199254740994",60
            r.observed_ms,r.native_true_calls,r.start_attempts=r.true_ms,1,1
            r.reset_pending,r.unresolved=true,true
        end
        if status=="reset" or status=="completed" then
            r.reset_false,r.reset_readback_known,r.reset_entered,r.reset_returned=true,true,true,true
            r.reset_ms,r.reset_serial,r.reset_time="9007199254741018","9007199254740995",60+1/60
            r.observed_ms,r.native_reset_calls,r.cleanup_attempts=r.reset_ms,1,1
            r.reset_pending,r.unresolved=false,false
        end
        if status=="completed" then
            r.terminal,r.standing_observed,r.stable_observed=true,true,true
            r.standing_samples,r.standing_seconds,r.committed_state=122,2.0166665464639664,504
            r.ragdoll,r.in_air=false,false;r.observed_ms="9007199254743018"
        end
        return r
    end
    local function read(p,now,r,extra)
        local f=frame(now,{receipt_handle="handle-a",receipt=r})
        for k,v in extra or {} do f[k]=v end
        return p:update(f)
    end
    do
        local p=Recovery.new()
        for i=1,20 do check(not p:update(frame(i,{gesture_down=true})).intents.request,"startup held input never requests") end
        p:update(frame(21));local o=p:update(frame(22,{gesture_down=true}))
        check(o.intents.request and o.attempt==1,"fresh release and press admits one recovery")
        for i=23,42 do check(not p:update(frame(i,{gesture_down=true})).intents.request,"held gesture cannot repeat while result unknown") end
        cases += 1
    end
    do
        local p=Recovery.new()
        check(not p:update(frame(0)).intents.request,"neutral at the first clock only arms")
        check(not p:update(frame(0,{gesture_down=true})).intents.request,"equal-clock press cannot dispatch")
        check(not p:update(frame(1,{gesture_down=true})).intents.request,"fresh clock cannot defer a press observed at the equal clock")
        p:update(frame(2));check(p:update(frame(3,{gesture_down=true})).intents.request,"a new neutral and press works after consuming equal-clock edge")
        cases += 1
    end
    do
        for _,missing in {"park_ready","release_ready","fallen"} do
            local p=Recovery.new();p:update(frame(1));local f=frame(2,{gesture_down=true});f[missing]=false
            check(not p:update(f).intents.request,"missing caller barrier/readiness prevents admission")
            check(not p:update(frame(3,{gesture_down=true})).intents.request,"becoming ready cannot spend a held old edge")
            p:update(frame(4));check(p:update(frame(5,{gesture_down=true})).intents.request,"new explicit gesture works after barriers without an earlier request")
        end
        cases += 1
    end
    do
        local p=Recovery.new();request(p)
        local o=p:update(frame(3,{request_result={attempt=1,accepted=false,reason="busy"}}))
        check(o.outcome=="request_refused" and not o.retained,"explicit nil refusal owns no native handle")
        for i=4,15 do
            o=p:update(frame(i,{gesture_down=i%2==1}))
            check(not o.intents.request,"even a new gesture cannot retry the spent fall epoch")
        end
        p:update(frame(16,{fall_epoch=2}))
        o=p:update(frame(17,{fall_epoch=2,gesture_down=true}))
        check(o.intents.request and o.attempt==2,"new caller-qualified fall epoch plus fresh gesture is a new request")
        cases += 1
    end
    do
        local p=accepted()
        check(read(p,4,receipt()).outcome=="pending","pending is not entered or recovered")
        check(read(p,5,receipt("entered")).outcome=="unresolved","entered true retains cleanup debt")
        check(read(p,6,receipt("reset")).outcome=="reset","verified false is distinct from standing")
        local o=read(p,7,receipt("completed"))
        check(o.standing and o.native_completed and o.intents.acknowledge and o.receipt.sequence=="9007199254740994",
            "complete native proof and exact large sequence produce standing plus one ack intent")
        o.receipt.sequence="mutated";o.receipt.standing_seconds=0;o.intents.acknowledge.handle="mutated"
        o=p:update(frame(8));check(o.standing and o.receipt.sequence=="9007199254740994" and not o.intents.acknowledge,
            "caller-mutated outputs cannot change retained receipt or repeat acknowledgement")
        o=p:update(frame(9,{ack_result={attempt=1,handle="handle-a",accepted=true}}))
        check(o.acknowledged and not o.retained and o.standing,"ack retires only the stored receipt, preserving historical outcome")
        check(not p:update(frame(10,{gesture_down=true})).intents.request,"acknowledgement never rearms same-fall recovery")
        o=p:update(frame(11,{fall_epoch=2}));check(not o.standing,"historical completed receipt is not current standing for a new incident")
        o=p:update(frame(12,{fall_epoch=2,gesture_down=true}))
        check(o.intents.request and o.attempt==2,"completed and acknowledged history cannot block a new explicit incident")
        cases += 1
    end
    do
        local p=accepted();read(p,4,receipt("entered"))
        local o=p:update(frame(5,{allowed=false}))
        check(o.retained and o.outcome=="unresolved" and o.intents.poll and not o.intents.cancel,"focus loss polls debt but cannot cancel entered intent")
        o=p:update(frame(6,{loaded=false,allowed=false}))
        check(o.retained and next(o.intents)==nil,"unload retains model obligation and makes no unavailable-VM API intent")
        o=read(p,7,receipt("reset"))
        check(o.retained and not o.standing and not o.intents.request,"returning focus does not retry or erase boundary")
        o=read(p,8,receipt("completed"))
        check(o.native_completed and not o.standing and o.outcome=="completion_not_accepted" and o.intents.acknowledge,
            "historical native completion after lost policy context is not current standing authority")
        cases += 1
    end
    do
        local p=accepted();read(p,4,receipt())
        local o=p:update(frame(5,{allowed=false}))
        check(o.intents.cancel and o.intents.poll,"known pending receipt allows one cancellation request on boundary")
        for i=6,10 do check(not p:update(frame(i,{allowed=false})).intents.cancel,"pending cancellation is never automatically retried") end
        local r=receipt();r.status,r.reason,r.terminal="cancelled","cancelled",true
        o=read(p,11,r,{allowed=false})
        check(o.outcome=="terminal_failure" and o.intents.acknowledge and not o.standing,"cancelled receipt is acknowledged separately from recovery")
        cases += 1
    end
    do
        for _,boundary in {"actor","source_epoch","fall_epoch"} do
            local p=accepted();read(p,4,receipt("entered"))
            local x={};x[boundary]=boundary=="actor" and "actor-b" or 2
            local o=p:update(frame(5,x))
            check(o.retained and o.intents.poll and not o.intents.cancel,"replacement source/actor/fall retains old entered debt")
            o=read(p,6,receipt("completed"),x)
            check(not o.standing and o.native_completed,"old receipt never grants standing to replacement context")
        end
        cases += 1
    end
    do
        for _,bad in {-1,.5,math.huge,0/0,"5",false,9007199254740992} do
            local p=accepted();read(p,4,receipt("entered"))
            local o=p:update(frame(bad))
            check(o.retained and next(o.intents)==nil,"invalid wall clock retains debt without emitting calls")
        end
        local p=accepted();read(p,10,receipt("entered"))
        local o=p:update(frame(9));check(o.retained and next(o.intents)==nil,"backward clock neither releases debt nor dispatches calls")
        o=p:update(frame(10));check(next(o.intents)==nil,"duplicate clock does not repeat intents")
        o=p:update(frame(11));check(o.intents.poll and not o.intents.request,"later valid clock resumes only observation")
        cases += 1
    end
    do
        local mutations={
            function(r)r.sequence="09007199254740994"end,function(r)r.sequence="18446744073709551616"end,
            function(r)r.sequence=9007199254740994 end,function(r)r.sequence="0"end,
            function(r)r.sequence="1\0tail"end,function(r)r.requested_ms="01"end,
            function(r)r.kind="board"end,function(r)r.status="done"end,function(r)r.reason="guessed"end,
            function(r)r.terminal=false end,function(r)r.observed_ms=nil end,
            function(r)r.ragdoll=0 end,function(r)r.native_true_calls=2 end,
            function(r)r.native_reset_calls=65 end,function(r)r.cleanup_attempts=.5 end,
            function(r)r.standing_seconds=0/0 end,function(r)r.standing_required_seconds=.1 end,
            function(r)r.reset_serial=r.true_serial end,function(r)r.reset_time=r.true_time end,
            function(r)r.reset_pending=true end,function(r)r.reset_readback_known=false end,
            function(r)r.unresolved=true end,function(r)r.native_pointer=123 end,
        }
        for _,mutate in mutations do
            local p=accepted();local r=receipt("completed");mutate(r)
            local o=read(p,4,r)
            check(o.retained and not o.standing and not o.intents.acknowledge and o.receipt==nil,"malformed public receipt cannot release or recover")
        end
        cases += 1
    end
    do
        local p=accepted();read(p,4,receipt("entered"))
        local r=receipt("reset");r.sequence="9007199254740995"
        local o=read(p,5,r)
        check(o.receipt.sequence=="9007199254740994" and o.outcome=="unresolved" and not o.intents.acknowledge,
            "adjacent identifiers above2^53 never round into the bound sequence")
        r=receipt("entered");r.true_time=61
        o=read(p,6,r);check(o.receipt.true_time==60,"immutable true-entry witness cannot be replaced")
        o=read(p,7,receipt());check(o.receipt.status=="entered","receipt phase/counters cannot move backward")
        o=read(p,8,receipt("reset"));check(o.receipt.reset_false and not o.standing,"valid later cleanup remains retainable after invalid observations")
        cases += 1
    end
    do
        local p=accepted();local r=receipt("entered");r.status,r.reason,r.terminal,r.quarantined="invalidated","native_lifetime_changed",true,true
        local o=read(p,4,r);check(o.outcome=="unresolved" and not o.intents.acknowledge,"terminal does not erase quarantine/debt")
        r=receipt("reset");r.status,r.reason,r.terminal="invalidated","native_lifetime_changed",true
        o=read(p,5,r);check(o.outcome=="terminal_failure" and o.intents.acknowledge and not o.standing,"later verified reset resolves failed record without relabelling it completed")
        r=receipt("completed");o=read(p,6,r)
        check(o.receipt.status=="invalidated" and not o.standing,"a failed terminal result cannot later become success")
        cases += 1
    end
    do
        local p=accepted();local r=receipt("entered");r.status,r.reason,r.terminal="invalidated","actor_destroyed",true
        r.actor_retired=true;r.quarantined=false
        local o=read(p,4,r)
        check(o.outcome=="actor_retired" and o.intents.acknowledge and o.receipt.unresolved and not o.receipt.reset_false,
            "exact actor retirement permits receipt retirement, never false-value or recovery proof")
        o=p:update(frame(5,{ack_result={attempt=1,handle="handle-a",accepted=true}}))
        check(o.acknowledged and not o.retained,"retired actor receipt can be acknowledged without false-reset proof")
        p:update(frame(6,{actor="actor-b",source_epoch=2}))
        o=p:update(frame(7,{actor="actor-b",source_epoch=2,gesture_down=true}))
        check(o.intents.request and o.attempt==2,"retired acknowledged actor cannot block a new owner generation")
        cases += 1
    end
    do
        local p=Recovery.new();request(p)
        local o=p:update(frame(3,{request_result={attempt=1,uncertain=true}}))
        check(o.outcome=="request_unknown" and o.retained and next(o.intents)==nil,"uncertain call without a handle is retained, not converted to a safe refusal")
        for i=4,15 do check(not p:update(frame(i,{fall_epoch=2,gesture_down=i%2==1})).intents.request,"unknown native entry never retries even on a new fall") end
        cases += 1
    end
    do
        for _,change in {
            function(r)r.native_true_calls=0 end,function(r)r.true_readback=nil end,
            function(r)r.stable_observed=false end,function(r)r.standing_samples=29 end,
            function(r)r.standing_seconds=1.999 end,function(r)r.committed_state=100 end,
            function(r)r.ragdoll=nil end,function(r)r.in_air=nil end,
            function(r)r.ragdoll=true end,function(r)r.in_air=true end,
        } do
            local p=accepted();local r=receipt("completed");change(r)
            local o=read(p,4,r)
            check(not o.standing and o.outcome=="completion_not_accepted","terminal completed alone cannot substitute for full recovery evidence")
        end
        cases += 1
    end
    do
        for _,status in {"cancelled","expired"} do
            local p=accepted();local r=receipt()
            r.status,r.reason,r.terminal,r.observed_ms=status,status,true,nil
            local o=read(p,4,r)
            check(o.outcome=="terminal_failure" and o.intents.acknowledge and o.receipt.observed_ms==nil,
                "negative terminal before a native callback can omit observed_ms and remain acknowledgeable")
            o=p:update(frame(5,{ack_result={attempt=1,handle="handle-a",accepted=true}}))
            check(o.acknowledged and not o.retained and not o.standing,"unobserved cancellation/expiry retires bookkeeping without inventing native completion")
        end
        cases += 1
    end
    do
        local p=accepted();local r=receipt();r.status,r.reason,r.terminal="rejected","unsupported_state",true
        local o=read(p,4,r)
        check(o.outcome=="terminal_failure" and o.intents.acknowledge and o.receipt.native_true_calls==0,"resolved rejection stores full receipt before ack intent")
        o=p:update(frame(5,{ack_result={attempt=1,handle="handle-a",accepted=false}}))
        check(o.retained and o.ack_failed and not o.intents.acknowledge,"failed acknowledgement is reported without automatic retry")
        o=p:update(frame(6,{ack_result={attempt=1,handle="handle-a",accepted=true}}))
        check(o.retained and not o.acknowledged and o.ack_failed,"a changed second acknowledgement result cannot retire the failed first call")
        cases += 1
    end
    do
        for _,change in {
            function(f)f.actor="actor-b" end,
            function(f)f.source_epoch=2 end,
            function(f)f.fall_epoch=2 end,
            function(f)f.allowed=false end,
            function(f)f.loaded=false end,
            function(f)f.now_ms=2 end,
            function(f)f.now_ms=0/0 end,
            function(f)f.actor=false end,
            function(f)f.park_ready="unknown" end,
        } do
            local p=accepted();read(p,4,receipt("completed"))
            local o=p:update(frame(5,{ack_result={attempt=1,handle="handle-a",accepted=true}}))
            check(o.standing and o.acknowledged,"accepted completion is retained for its original policy context")
            local f=frame(6);change(f);o=p:update(f)
            check(not o.standing and o.native_completed and o.receipt.status=="completed",
                "acknowledged historical completion cannot grant standing to a different or invalid current context")
        end
        local p=accepted();read(p,4,receipt("completed"))
        local o=p:update(frame(4,{ack_result={attempt=1,handle="handle-a",accepted=true}}))
        check(o.standing and o.acknowledged and next(o.intents)==nil,
            "a valid equal-clock acknowledgement keeps accepted standing without dispatch")
        cases += 1
    end
    return {cases=cases,assertions=assertions,native_actions=0}
end
return tests

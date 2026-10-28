-- Source-only regression cases. This module is inert until an assigned runner
-- calls run(); it cannot provide game, storage durability or native proof.
local Recorder=require("./hop_recorder")
local Codec=require("./hop_evidence_codec")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn) cases+=1;fn();return name end
    local function fresh(writer)
        local writes={}
        local recorder=Recorder.new(writer or function(key,value) writes[#writes+1]={key=key,value=value} end,"source_fixture")
        return recorder,writes
    end
    local function closed(unknown)
        return {phase=unknown and "cleanup_unknown" or "done",stop_latched=true,
            bike_authority=unknown==true,cleanup_pending=unknown==true,cleanup_unknown=unknown==true,
            bike_cleanup_complete=unknown~=true,force_cleanup_clear=unknown~=true,force_cleanup_unknown=unknown==true,
            ride={force_pending=unknown==true,unknown=unknown==true,pending_count=unknown and 1 or 0,
                submitted=1,acknowledged=unknown and 0 or 1},
            source={phase=unknown and "cleanup_unknown" or "complete",cleanup_pending=unknown==true,
                cleanup_unknown=unknown==true,lease_handle_present=unknown==true},
            stop_reason="fixture stop"}
    end
    local function drain(recorder)
        for _=1,2200 do
            if recorder:status().flushed then return end
            local ok,why=recorder:flush({inactive=true,terminal=true})
            check(ok,"bounded fixture flush: "..tostring(why))
        end
        error("fixture exceeded bounded flush count")
    end
    local function rows(writes)
        local chunks={}
        for _,write in ipairs(writes) do if write.value.rows then chunks[#chunks+1]=write.value end end
        if #chunks==0 then return {} end
        local decoded,why=Codec.decode_chunks(chunks,chunks[1].run_id)
        check(decoded~=nil,"strict v2 test evidence decoding: "..tostring(why))
        return decoded
    end
    local function find(writes,kind)
        for _,row in ipairs(rows(writes)) do if row.kind==kind then return row end end
    end
    case("require and construction are inert",function()
        local recorder,writes=fresh()
        check(#writes==0 and not recorder:status().stop_requested,"new records no effects")
        check(recorder:status().unresolved_debt and recorder:status().latest==nil,"unobserved cleanup is not clear")
        check(not recorder:flush({inactive=true,terminal=true}),"no terminal witness cannot flush")
    end)
    case("actual eight source scalars and body vectors are detached",function()
        local recorder,writes=fresh()
        local src={generation=2,user=0,sequence="9007199254740994",source_epoch="8",context_generation="9",
            observation_serial="10",observed_ms="11",packet=12,epoch=newproxy(),lease_handle=newproxy()}
        local sample={serial="21",time=1,seconds=1/60,mass=106,position={1,2,3},velocity=vector.create(4,5,6),
            angular_velocity={7,8,9},inertia={10,11,12},rotation={0,0,0,1},epoch=newproxy()}
        check(recorder:append("source",src) and recorder:append("body",sample),"actual scalar and vector fields accepted")
        src.sequence="changed";sample.position[1]=999;sample.rotation[4]=0
        recorder:terminal(closed(false));drain(recorder)
        local s,b=find(writes,"source").data,find(writes,"body").data
        check(s.generation==2 and s.user==0 and s.sequence=="9007199254740994" and s.source_epoch=="8"
            and s.context_generation=="9" and s.observation_serial=="10" and s.observed_ms=="11" and s.packet==12,
            "all eight exact Source values survive without numeric coercion")
        check(b.position[1]==1 and b.velocity[2]==5 and b.rotation[4]==1,"caller mutations cannot rewrite history")
        check(s.epoch==nil and s.lease_handle==nil and b.epoch==nil,"opaque epochs and handles are never copied")
    end)
    case("hostile opaque keys and values are not traversed",function()
        local recorder,writes=fresh()
        local touched=0
        local hostile=setmetatable({}, {__index=function() touched+=1;error("index") end,
            __tostring=function() touched+=1;error("string") end,__iter=function() touched+=1;error("iterate") end})
        check(recorder:append("submit",{force={0,1,0},torque={0,0,0},epoch=hostile,
            body_handle=newproxy(),private=hostile,[hostile]=function() end}),"unlisted opaque fields are ignored")
        check(not recorder:append("body",{serial="22",position=hostile}),"hostile listed field is rejected without invoking it")
        check(touched==0 and recorder:status().observation_loss and recorder:status().stop_requested,"hostile data fails closed")
        recorder:terminal(closed(true));drain(recorder)
        check(find(writes,"submit").data.private==nil,"opaque subtree never enters persistence")
    end)
    case("measured contacts retain their actual normal and surface velocity",function()
        local recorder,writes=fresh()
        local contact={valid=true,status="available",query={epoch_matches=true,accounting_known=true,
            native_casts=2,measurements_complete=true,local_actor_excluded=false,owned_bodies_excluded=true,
            named_actor_categories_absent=true,actor_lane="named_categories_absent"},
            support={known=false,grounded_known=false,reason="unqualified"},
            rays={{status="hit",position={1,2,3},fraction=.5,motion="measured",normal_available=true,
                surface_velocity_available=true,normal={0,1,0},surface_velocity={.2,0,0}}}}
        check(recorder:append("contact",contact),"measured contact copied")
        contact.rays[1].normal[2]=0;contact.rays[1].surface_velocity[1]=7
        recorder:terminal(closed(false));drain(recorder)
        local c=find(writes,"contact").data
        check(c.rays[1].normal[2]==1 and c.rays[1].surface_velocity[1]==.2 and not c.support.known,
            "copy preserves measurements without inventing support")
    end)
    case("real pose and hop disposition types do not fabricate loss",function()
        local recorder,writes=fresh()
        check(recorder:append("pose",{capability=false,last_sent=.3,qualified=false,result=false,
            reason="qualification unavailable",plan={at_ms=300,hips={1,2,3},wrists={{1,2,3},{4,5,6}},ankles={{1,2,3},{4,5,6}}}}),
            "actual boolean capability and false result are representable")
        check(recorder:append("force_pending",{force_pending=true,unknown=false,
            hop_disposition={id=7,disposition="adopted",confirmed=true}}),"actual nested hop disposition is representable")
        recorder:terminal(closed(false));drain(recorder)
        check(not recorder:status().observation_loss and find(writes,"pose").data.result==false,
            "false API result remains false and does not become recorder acceptance")
    end)
    case("identical receipt semantics coalesce but identities and outcomes do not",function()
        local recorder,writes=fresh()
        for i=1,400 do
            check(recorder:append("receipt",{call="world.physics.receipt",sequence="31",requested_serial="30",
                produced_serial="0",outcome="queued",at_ms=i}),"repeat receipt observed")
        end
        check(recorder:status().regular_rows==1 and recorder:status().coalesced==399,"400 watchdog polls consume one semantic row")
        recorder:append("receipt",{call="world.physics.receipt",sequence="31",requested_serial="30",produced_serial="31",outcome="applied",at_ms=401})
        recorder:append("receipt",{call="world.physics.receipt",sequence="32",requested_serial="31",produced_serial="0",outcome="queued",at_ms=402})
        recorder:terminal(closed(true));drain(recorder)
        local r=rows(writes)
        check(r[1].repeats==400 and r[1].first_call==1 and r[1].last_call==400
            and r[1].first_at_ms==1 and r[1].last_at_ms==400,"coalesced range preserves occurrence and wall bounds")
        check(r[2].data.outcome=="applied" and r[3].data.sequence=="32","distinct transitions retained")
    end)
    case("regular exhaustion requests stop and terminal debt survives",function()
        local recorder,writes=fresh()
        local refused=false
        for _=1,Recorder.limits.regular_rows+1 do
            if not recorder:append("ack",{result=true}) then refused=true;break end
        end
        check(refused and recorder:status().regular_rows<=Recorder.limits.regular_rows,
            "row or byte exhaustion refuses the first excess ordinary event")
        local snap=closed(true);snap.stop_reason="capacity stop with retained receipt"
        recorder:terminal(snap)
        check(recorder:status().stop_requested and recorder:status().observation_loss,"capacity failure is sticky")
        check(recorder:status().critical_rows==1 and recorder:status().latest.cleanup_unknown,"terminal has reserved space")
        drain(recorder)
        local summary=writes[#writes].value
        check(summary.unqualified and summary.unresolved_debt and summary.latest.stop_reason==snap.stop_reason,
            "retained debt persists despite ordinary overflow")
    end)
    case("critical exhaustion cannot clear or freeze the latest debt snapshot",function()
        local recorder,writes=fresh()
        recorder:terminal(closed(true))
        for i=1,Recorder.limits.critical_rows do recorder:append("ack",{sequence=tostring(i),result=false}) end
        local newer=closed(true);newer.stop_reason="watchdog expired after critical overflow";newer.ride.pending_count=3
        recorder:terminal(newer)
        check(recorder:status().critical_rows==Recorder.limits.critical_rows and recorder:status().observation_loss,
            "critical reserve is finite and loss is explicit")
        check(recorder:status().latest.ride.pending_count==3 and recorder:status().latest.stop_reason==newer.stop_reason,
            "latest debt always updates outside the event reserve")
        drain(recorder)
        check(writes[#writes].value.latest.cleanup_unknown and writes[#writes].value.unqualified,"unknown debt remains in summary")
    end)
    case("ordinary and critical byte limits are hard bounds",function()
        local recorder=fresh()
        local payload={call=string.rep("x",192),reason=string.rep("y",192),result=false,arity=2}
        for _=1,2049 do if not recorder:append("ack",payload) then break end end
        local s=recorder:status()
        check(s.observation_loss and s.summary.regular_bytes<=Recorder.limits.regular_bytes,"ordinary byte bound closes before unbounded growth")
        recorder:terminal(closed(true))
        local escaped={call=string.rep(string.char(1),192),reason=string.rep(string.char(2),192),result=false,arity=2}
        local refused=false
        for _=1,129 do if not recorder:append("ack",escaped) then refused=true;break end end
        local critical=recorder:status()
        check(refused and critical.critical_rows<Recorder.limits.critical_rows
            and critical.summary.critical_bytes<=Recorder.limits.critical_bytes,
            "escaped strings exhaust the independent critical byte budget before its row count")
    end)
    case("active and nonterminal flush gates perform no storage calls",function()
        local recorder,writes=fresh()
        recorder:append("ack",{result=true});recorder:terminal(closed(true))
        check(not recorder:flush({inactive=false,terminal=true}) and not recorder:flush({inactive=true,terminal=false}),"both gate facts required")
        check(#writes==0,"failed gates perform no storage writes")
        check(recorder:flush({inactive=true,terminal=true}) and #writes==1,"unknown terminal debt is eligible for evidence persistence")
        check(recorder:status().unresolved_debt,"storage never acknowledges native debt")
    end)
    case("each flush writes at most one bounded chunk",function()
        local recorder,writes=fresh()
        for i=1,40 do recorder:append("ack",{sequence=tostring(i),result=true}) end
        recorder:terminal(closed(false))
        local before=#writes
        recorder:flush({inactive=true,terminal=true})
        check(#writes==before+1 and #writes[1].value.rows==Recorder.limits.chunk_rows,"one idle flush writes one chunk")
        drain(recorder)
        for _,write in ipairs(writes) do
            check(#write.key<=128,"SDK key byte bound")
            if write.value.rows then check(#write.value.rows<=Recorder.limits.chunk_rows,"chunk row bound") end
        end
        check(recorder:status().flushed,"summary only completes after every chunk was accepted")
    end)
    case("failed chunk write never advances success and is not retried",function()
        local calls=0
        local recorder=fresh(function() calls+=1;error("fixture quota refusal",0) end)
        recorder:append("ack",{result=false});recorder:terminal(closed(true))
        check(not recorder:flush({inactive=true,terminal=true}),"raised writer refusal propagates as recorder fault")
        check(recorder:status().storage_fault and recorder:status().stored_rows==0 and not recorder:status().flushed,
            "no successful cursor or complete status on failed write")
        check(not recorder:flush({inactive=true,terminal=true}) and calls==1,"no ambiguous retry")
        check(recorder:status().latest.cleanup_unknown and recorder:status().unqualified,"failure leaves latest debt intact")
    end)
    case("unexpected writer result is not the SDK zero-result ABI",function()
        for _,result in ipairs({false,true}) do
            local recorder=fresh(function() return result end)
            recorder:terminal(closed(false))
            check(not recorder:flush({inactive=true,terminal=true}) and recorder:status().storage_fault,
                "returned boolean does not fake SDK acceptance")
        end
    end)
    case("events after an accepted summary require a new summary",function()
        local recorder,writes=fresh()
        recorder:terminal(closed(false));drain(recorder)
        local before=#writes
        recorder:append("ack",{sequence="99",result=true})
        check(not recorder:status().flushed,"later evidence invalidates completion")
        drain(recorder)
        check(#writes==before+2 and writes[#writes].value.kind=="hop-trial-evidence",
            "later chunk and updated summary both cached")
    end)
    case("missing or malformed terminal observations retain uncertainty",function()
        local recorder=fresh()
        recorder:terminal(closed(true));recorder:terminal({phase="done"})
        check(recorder:status().unresolved_debt,"missing false flags cannot certify cleanup")
        recorder:terminal({phase="done",cleanup_pending=false,cleanup_unknown=false,bike_authority=newproxy()})
        check(recorder:status().unresolved_debt and recorder:status().observation_loss,"opaque authority flag cannot clear uncertainty")
    end)
    case("oversized and nonfinite fields are explicit observation loss",function()
        local recorder=fresh()
        check(not recorder:append("ack",{reason=string.rep("x",193)}),"oversized reason is marked partial")
        check(not recorder:append("body",{serial="1",time=0/0,position={0,math.huge,0}}),"nonfinite body refused")
        check(recorder:status().observation_loss and recorder:status().stop_requested,"malformed data fails closed")
    end)
    case("capture lease fields retain exact string identity and debt",function()
        local recorder,writes=fresh()
        check(recorder:append("lease",{call="input.lease_capture_state",sequence="3",source_epoch="4",
            context_generation="5",generation="6",revision="7",phase="releasing",report_debt=true,
            terminal=false,quarantined=true,publications="8",neutral_releases="7"}),"capture DTO accepted")
        recorder:terminal(closed(true));drain(recorder)
        local row=find(writes,"lease").data
        check(row.generation=="6" and row.revision=="7" and row.report_debt and row.quarantined,
            "capture generation stays string and debt remains observed")
    end)
    case("a writer callback cannot coalesce later observations into an already captured chunk",function()
        local recorder
        local writes={}
        local repeated=false
        recorder=Recorder.new(function(key,value)
            writes[#writes+1]={key=key,value=value}
            if not repeated and value.rows then
                repeated=true
                recorder:append("follow",{sequence="8",phase="stopping",at_ms=2})
            end
        end,"reentrant_fixture")
        recorder:terminal(closed(true))
        recorder:append("follow",{sequence="8",phase="stopping",at_ms=1})
        drain(recorder)
        local found=0
        for _,row in ipairs(rows(writes)) do if row.kind=="follow" then found+=row.repeats end end
        check(found==2,"callback observation survives in a subsequent stored row")
    end)
    case("post-summary invalid events cannot leave a clean cached summary current",function()
        local recorder,writes=fresh()
        recorder:terminal(closed(false));drain(recorder)
        local before=#writes
        check(not recorder:append("not_an_event",{}),"unknown event is rejected")
        check(not recorder:status().flushed and recorder:status().observation_loss,"fault invalidates saved summary revision")
        drain(recorder)
        check(#writes==before+1 and writes[#writes].value.observation_loss and writes[#writes].value.unqualified,
            "replacement summary reports the rejected observation")
    end)
    case("stable terminal ticks update wall time without endless summary writes",function()
        local recorder,writes=fresh()
        local snap=closed(true);snap.wall_ms=100
        recorder:terminal(snap);drain(recorder)
        local before=#writes
        for i=101,600 do snap.wall_ms=i;recorder:terminal(snap) end
        check(recorder:status().flushed and recorder:status().latest.wall_ms==600,
            "same cleanup semantics keep persistence current while latest wall stays observed")
        check(recorder:flush({inactive=true,terminal=true}) and #writes==before,"unchanged idle terminal produces no write")
        snap.ride.pending_count=2;recorder:terminal(snap)
        check(not recorder:status().flushed,"real debt change still dirties terminal summary")
        drain(recorder)
        check(writes[#writes].value.latest.ride.pending_count==2,"changed debt is saved")
    end)
    case("BoardDrop restore uncertainty is independent of Core top-level cleanup flags",function()
        local recorder,writes=fresh()
        local snap=closed(false)
        snap.board_drop={state="restore_unknown",reason="board.clear raised",restore_pending=false,
            drop_inflight=false,restore_inflight=false,toss_calls=1,clear_calls=1,clear_result="raised"}
        recorder:terminal(snap);drain(recorder)
        local st=recorder:status()
        check(st.unresolved_debt and st.unqualified and st.latest.board_drop.state=="restore_unknown",
            "independent board restore debt is retained even with Core cleanup clear")
        check(writes[#writes].value.latest.board_drop.clear_result=="raised","actual board result is preserved")
        for _,flag in ipairs({"restore_pending","drop_inflight","restore_inflight"}) do
            local pending=closed(false);pending.board_drop={state="restored"};pending.board_drop[flag]=true
            recorder:terminal(pending)
            check(recorder:status().unresolved_debt,"board pending/inflight state remains unresolved")
        end
    end)
    case("pose release duty cannot be cleared by a Core bike-complete flag",function()
        local recorder,writes=fresh()
        local snap=closed(false)
        snap.mounted_pose={sends=3,stopped=true,nil_calls=1,nil_accepted=false,state="off",capability=true}
        recorder:terminal(snap);drain(recorder)
        check(recorder:status().unresolved_debt and recorder:status().summary.pose_release_unresolved,
            "failed nil release retains independent pose duty")
        check(writes[#writes].value.latest.mounted_pose.nil_accepted==false,"actual refused nil result persists")
        snap.mounted_pose={sends=3,stopped=false,nil_calls=0,state="mounted"}
        recorder:terminal(snap)
        check(recorder:status().summary.pose_release_unresolved,"sent pose without stopped and accepted nil remains owed")
        snap.mounted_pose={sends=0,stopped=true,nil_calls=1,nil_accepted=false,state="off"}
        recorder:terminal(snap)
        check(recorder:status().summary.pose_release_unresolved,"any attempted but unaccepted nil remains unresolved")
        snap.mounted_pose={sends=3,stopped=true,nil_calls=1,nil_accepted=true,state="off"}
        recorder:terminal(snap)
        check(not recorder:status().unresolved_debt,"actual observed accepted release can close recorded pose duty")
    end)
    case("explicit early unload writes one honest incomplete summary",function()
        local recorder,writes=fresh()
        recorder:append("submit",{sequence="11",force={0,1,0},torque={0,0,0}})
        local snap=closed(true);snap.phase="stopping"
        check(recorder:interrupt(snap),"one emergency snapshot accepted by the zero-result writer")
        check(#writes==1 and writes[1].key=="hop.source_fixture.incomplete","distinct incomplete key used once")
        local value=writes[1].value
        check(value.interrupted and value.complete==false and value.observation_loss and value.unqualified,
            "emergency record explicitly declares incomplete observation")
        check(value.latest.phase=="stopping" and value.latest.cleanup_unknown and value.unresolved_debt,
            "actual nonterminal phase and debt are not fabricated as terminal or clear")
        check(recorder:status().stored_rows==0 and recorder:status().chunks==0 and not recorder:status().flushed,
            "emergency summary advances no ordinary row/chunk/saved cursor")
        check(not recorder:interrupt(closed(false)) and not recorder:flush({inactive=true,terminal=true}) and #writes==1,
            "emergency is one-shot and does not open active streaming")
    end)
    case("emergency storage failure does not invent success or retry",function()
        local calls=0
        local recorder=fresh(function() calls+=1;error("emergency quota refusal",0) end)
        check(not recorder:interrupt(closed(true)),"failed emergency write is reported")
        check(not recorder:status().emergency_cached and recorder:status().storage_fault
            and recorder:status().latest.cleanup_unknown,"failed emergency keeps actual debt and failure")
        check(not recorder:interrupt(closed(false)) and calls==1,"failed emergency is never retried")
    end)
    case("one distinct emergency attempt does not erase a prior failed chunk",function()
        local calls=0
        local recorder=fresh(function() calls+=1;if calls==1 then error("chunk failed",0) end end)
        recorder:append("ack",{result=false});recorder:terminal(closed(true))
        check(not recorder:flush({inactive=true,terminal=true}),"ordinary chunk failed")
        check(recorder:interrupt(closed(true)) and calls==2,"one separate incomplete summary may still be cached")
        check(recorder:status().storage_fault and recorder:status().stored_rows==0
            and recorder:status().unqualified and not recorder:status().flushed,"prior failure remains sticky")
    end)
    case("emergency writer cannot reenter another emergency write",function()
        local recorder
        local calls=0
        recorder=Recorder.new(function()
            calls+=1
            check(not recorder:interrupt(closed(false)),"one-shot consumed before writer callback")
        end,"emergency_reentry")
        check(recorder:interrupt(closed(true)) and calls==1,"exactly one writer invocation")
    end)
    case("busy ordinary writer retains interruption loss without a nested write",function()
        local recorder
        local calls=0
        recorder=Recorder.new(function()
            calls+=1
            local ok,why=recorder:interrupt(closed(true))
            check(not ok and why=="busy","busy emergency does not nest a writer")
        end,"busy_unload")
        recorder:append("ack",{result=false});recorder:terminal(closed(true))
        recorder:flush({inactive=true,terminal=true})
        check(calls==1 and recorder:status().interrupted and recorder:status().observation_loss
            and not recorder:status().emergency_cached and not recorder:status().flushed,
            "busy interruption remains explicit and incomplete")
    end)
    case("missing final unload snapshot preserves the last actual debt observation",function()
        local recorder,writes=fresh()
        local previous=closed(true);previous.stop_reason="last actual retained receipt";previous.ride.pending_count=3
        recorder:terminal(previous)
        check(recorder:interrupt(nil),"unknown final status still writes the one incomplete summary")
        local value=writes[#writes].value
        check(value.final_snapshot_unavailable and value.unresolved_debt and value.unqualified,
            "missing final observation is explicit uncertainty")
        check(value.latest.stop_reason==previous.stop_reason and value.latest.ride.pending_count==3
            and value.latest.cleanup_unknown,"prior actual fields are retained rather than replaced or cleared")
    end)
    case("encoded evidence preserves Source deltas and separately anchored cleanup",function()
        local recorder,writes=fresh()
        for i=1,40 do
            check(recorder:append("source",{call="input.lease_read",sequence="31",source_epoch="2",context_generation="3",
                observation_serial=tostring(i),observed_ms=tostring(i*16),packet=i,
                pad={left_x=0,right_y=0,playstation=false,buttons={a=false}}}),"new exact Source observation retained")
        end
        local before=recorder:status().summary
        check(before.regular_state_bytes>0 and before.regular_wire_bytes>0
            and before.regular_bytes==before.regular_state_bytes+before.regular_wire_bytes,
            "canonical projection state is charged inside the ordinary budget")
        check(recorder:append("receipt",{sequence="7",requested_serial="6",produced_serial="7",outcome="applied",quarantined=true}),
            "critical receipt independently retained")
        recorder:terminal(closed(true));drain(recorder)
        local observed=rows(writes);local sources=0;local critical=false
        for _,row in ipairs(observed) do
            if row.kind=="source" then sources+=1;check(row.data.observation_serial==tostring(sources)
                and row.data.pad.buttons.a==false and row.data.pad.right_y==0,"source identities, false and zero survive deltas") end
            if row.kind=="receipt" then critical=row.critical end
        end
        check(sources==40 and critical,"no unique Source observation dropped and critical marker remains separate")
        for _,write in ipairs(writes) do if write.value.rows then for _,wire in ipairs(write.value.rows) do
            if wire[1] then check(wire[4]==0,"critical cleanup never references a regular row") end
        end end end
    end)
    case("storage writers cannot mutate retained encoded history",function()
        local recorder;local writes={};local attempts=0
        recorder=Recorder.new(function(key,value)
            writes[#writes+1]={key=key,value=value}
            if value.rows then
                attempts+=1
                check(not pcall(function() value.rows[1][6]=999 end),"writer sees frozen occurrence header")
                check(not pcall(function() value.rows[1][11][1]=99 end),"writer sees frozen encoded node graph")
            end
        end,"immutable_writer")
        recorder:append("ack",{sequence="9",acknowledged=true});recorder:terminal(closed(false));drain(recorder)
        check(attempts>0 and #rows(writes)==recorder:status().stored_rows,"writer mutation changes no retained record")
    end)
    case("signed zero changes cannot disappear through semantic coalescing",function()
        local recorder,writes=fresh()
        recorder:append("receipt",{sequence="9",requested_serial="8",produced_serial="9",outcome="applied",
            successor={velocity={-1/math.huge,0,0}}})
        recorder:append("receipt",{sequence="9",requested_serial="8",produced_serial="9",outcome="applied",
            successor={velocity={0,0,0}}})
        recorder:terminal(closed(false));drain(recorder)
        local found={};for _,row in ipairs(rows(writes)) do if row.kind=="receipt" then found[#found+1]=row end end
        check(#found==2 and 1/found[1].data.successor.velocity[1]==-math.huge
            and 1/found[2].data.successor.velocity[1]==math.huge,"actual zero sign transition remains two observations")
    end)
    return {cases=cases,assertions=assertions}
end
return table.freeze(Tests)
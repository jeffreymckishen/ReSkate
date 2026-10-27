-- Real Core/Source/Spawn/Poser/BoardDrop with constructed SDK services only.
-- Existing private fixture copies select the qualified pose and measured floor;
-- production literals stay closed. These cases are not native or game evidence.
local Core=require("./bike_runtime_core_mounted_pose_fixture")
local Production=require("./bike_runtime_core")
local Spawn=require("./bike_spawn")
local FloorSpawn=require("./bike_spawn_floor_qualified_fixture")
local Services=require("./core_ride_staging_tests")
local Tests={}
local function first(events,name)
    for i,value in ipairs(events) do if value==name then return i end end
    return math.huge
end
local function count(events,name)
    local n=0;for _,value in ipairs(events) do if value==name then n+=1 end end;return n
end
local function fixture(options)
    options=options or {}
    local f,s=Services.spawn_services()
    f.events={};f.floor=99.75;f.rays=0
    f.bones_calls,f.toss_calls,f.clear_calls=0,0,0
    f.pose_probes,f.pose_attempts,f.pose_sends,f.pose_ends=0,0,0,0
    local function event(name) table.insert(f.events,name) end
    function s.skater.get() return {airborne=false,position=vector.create(10,100,20),heading=0} end
    function s.world.raycast(...)
        assert(select("#",...)==2,"one bounded two-argument floor ray")
        f.rays+=1;event("ray");f.ray_from,f.ray_to=...
        return vector.create(f.ray_from.x,f.floor,f.ray_from.z)
    end
    s.board={}
    function s.board.bones(...)
        assert(select("#",...)==0,"board.bones takes no arguments")
        f.bones_calls+=1;event("bones")
        if f.on_bones then f.on_bones() end
        return {[1]={position=vector.create(10,101,20),rotation={0,0,0,1}},
            [2]={position=vector.create(0,.1,0),rotation={0,0,0,1}}}
    end
    function s.board.toss(...)
        assert(select("#",...)==2,"board.toss receives the bone list and options")
        f.toss_calls+=1;event("toss");f.toss_bones,f.toss_options=...
        if f.on_toss then f.on_toss() end
        if f.toss_mode=="false" then return false,"constructed board owner refusal" end
        if f.toss_mode=="raise" then error("constructed unknown toss",0) end
        if f.toss_mode=="malformed" then return "unknown acceptance" end
        return true
    end
    function s.board.clear(...)
        assert(select("#",...)==0,"board.clear must release the whole board without a bone argument")
        f.clear_calls+=1;event("clear")
        if f.on_clear then f.on_clear() end
        if f.clear_mode=="raise" then error("constructed unknown clear",0) end
        if f.clear_mode=="false" then return false end
        if f.clear_mode=="nil" then return nil end
        -- The real SDK clear contract returns zero values.
    end
    if options.no_api then s.board=nil end
    local capture_release=s.input.lease_release_capture
    function s.input.lease_release_capture(...)
        event("capture_release");return capture_release(...)
    end
    function s.skater.pose(plan,weight)
        if plan==nil then f.pose_ends+=1;event("pose_end");return true end
        if weight==2 then
            f.pose_probes+=1;event("pose_probe")
            if f.on_probe then f.on_probe() end
            if f.refuse_probe then error("constructed pose permission refusal",0) end
            error("a joint's place has a position, a rotation or both",0)
        end
        f.pose_attempts+=1;event("pose")
        if f.on_pose then f.on_pose() end
        if f.refuse_pose then return false,"constructed pose refusal" end
        f.pose_sends+=1;return true
    end
    function s.world.physics.reserve_follow(body,attachment)
        table.insert(f.reserves,{body=body,attachment=attachment})
        f.follow=newproxy();f.follow_phase="reserved";return f.follow,nil
    end
    function s.world.physics.publish_follow(handle)
        assert(handle==f.follow);f.follow_phase="following";f.published=true;return true
    end
    function s.world.physics.stop_follow(handle)
        assert(handle==f.follow);event("follow_stop");f.follow_phase="stopping";return true
    end
    function s.world.physics.read_follow(handle)
        assert(handle==f.follow)
        local done=f.follow_phase=="stopping"
        return {phase=done and "completed" or f.follow_phase,reason=done and "cancelled" or "none",
            park_reason=done and "none" or "unavailable",sequence="41",final_revision=f.published and "3" or "0",
            final_native_epoch=f.published and "9" or "0",returned_revision=done and "3" or "0",pending={},
            in_flight=0,claim_known=not done,orphaned=false,park_observed=done,native_retirement_known=false,terminal=done}
    end
    function s.world.physics.acknowledge_follow(handle)
        assert(handle==f.follow and f.records.bmx_bike_lifecycle_v1.terminal_receipt)
        event("follow_ack");return true
    end
    -- Existing Core.new shared-state seam: constructed admission, never native rearming.
    local state={phase="armed",used=true,active=true,ledger_owned=true,level="sanvan",wipeouts=0,
        generation=1,cancel_version=0,arm_at=f.now,slot=0,calls={},counts={},receipts={},omitted_calls=0,
        omitted_receipts=0,remove_attempted={},remove_accepted={}}
    f.core=(options.production and Production or Core).new(s,{qualification_only=true},state)
    -- Same real-Spawn selection seam as core_floor_spawn_fixture. Restore both
    -- cached exports even if backend binding fails; the instance retains real closures.
    local selected=options.no_floor and Spawn or FloorSpawn
    local selected_new,selected_gate=selected.new,selected.floor_spawn_qualified
    local original_new,original_gate=Spawn.new,Spawn.floor_spawn_qualified
    Spawn.floor_spawn_qualified=selected_gate
    Spawn.new=function(api) f.spawn=selected_new(api);return f.spawn end
    local ok,bound=pcall(f.core.prepare_backend,f.core)
    Spawn.new,Spawn.floor_spawn_qualified=original_new,original_gate
    assert(ok and bound==true,"real backend must bind: "..tostring(bound))
    assert(Spawn.new==original_new and Spawn.floor_spawn_qualified==original_gate,"restore cached Spawn exports")
    function f:step()
        self.now+=16
        if self.sample and self.follow_phase=="following" then
            self.sample=table.clone(self.sample);self.sample.epoch=newproxy()
            self.sample.serial=tostring(tonumber(self.sample.serial)+1);self.sample.time+=1/60
        end
        return self.core:step(16)
    end
    function f:following()
        local out=self.core:status()
        for _=1,220 do if out.phase=="following" then break end;out=self:step() end
        assert(out.phase=="following","constructed Source/Spawn reaches actual Core Follow")
        return out
    end
    function f:cancel(kind)
        if kind=="unload" then self.core:unload() else self.core:request_stop("constructed board callback stop") end
    end
    return f,s
end
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(run) cases+=1;run() end
    local function no_board_calls(f,why)
        check(f.bones_calls==0 and f.toss_calls==0 and f.clear_calls==0,why)
    end
    local function ledger(f,out)
        check((out.call_counts["board.bones"] or 0)==f.bones_calls
            and (out.call_counts["board.toss"] or 0)==f.toss_calls
            and (out.call_counts["board.clear"] or 0)==f.clear_calls,"Core ledger matches actual board SDK calls")
    end
    case(function()
        local f=fixture();local out=f.core:status()
        check(out.startup.board_instances==1 and out.board_drop.state=="idle","backend binds one inert board owner")
        check(f.core:prepare_backend() and f.core:status().startup.board_instances==1,"repeated preparation reuses that owner")
        f.core:status();f.core:status();no_board_calls(f,"construction, preparation and cached status perform no board effects")
        check(f.rays==0 and f.pose_probes==0,"preparation performs no floor query or pose probe")
        f.core:unload();no_board_calls(f,"unmounting an unused owner needs no clear")
    end)
    case(function()
        local f=fixture({production=true});f:following();local out=f:step()
        check(out.mounted_pose.qualified==false and f.pose_probes==0,"public production pose qualification stays closed")
        no_board_calls(f,"a measured floor cannot open the public board-drop path")
        check(out.board_drop.state=="idle" and not out.stop_latched,"closed presentation leaves lifecycle authority intact")
        f.core:unload();no_board_calls(f,"public cleanup has no board to clear")
    end)
    case(function()
        local f=fixture({no_api=true});f:following();local out=f:step()
        check(f.pose_sends==1 and out.board_drop.state=="refused","missing board API refuses presentation only")
        check(out.phase=="following" and not out.stop_latched,"missing optional board API cannot stop body authority")
        f:step();f.core:unload();no_board_calls(f,"missing API never reaches any board SDK callback")
    end)
    case(function()
        local f=fixture({no_floor=true});f:following();local out=f:step()
        check(f.spawn:floor_height()==nil and f.rays==0,"the real default Spawn retains no measured floor")
        check(f.pose_sends==1 and out.board_drop.state=="refused" and not out.stop_latched,
            "body and skater heights cannot substitute for a measured floor")
        f:step();f.core:unload();no_board_calls(f,"a missing floor refuses before bones, toss or clear")
    end)
    case(function()
        local f=fixture();f:following();no_board_calls(f,"publishing Follow does not yet mount presentation")
        f.events={};local out=f:step();local b=out.board_drop;local args=f.toss_options
        check(b.state=="dropped" and f.bones_calls==1 and f.toss_calls==1 and f.clear_calls==0,"accepted mount drops once")
        check(first(f.events,"pose_probe")<first(f.events,"bones") and first(f.events,"bones")<first(f.events,"toss")
            and first(f.events,"toss")<first(f.events,"pose"),"drop follows accepted mount capability and precedes the first posture send")
        check(#f.toss_bones==1 and f.toss_bones[1]==2 and args.velocity==vector.create(0,.6,0)
            and args.spin==vector.create(0,1.5,0) and math.abs(args.ground-99.754)<1e-9,"one exact deck toss uses the measured floor")
        check(b.floor==99.75 and b.upside==false and b.place_above_floor==1.25
            and b.calibration.place.position[2]==101 and b.toss_result=="accepted","cached diagnostics retain calibration and exact acceptance")
        local fresh=f.core:status()
        check(table.isfrozen(fresh.board_drop) and table.isfrozen(b.calibration) and table.isfrozen(b.calibration.place.position),
            "cached board evidence is deeply immutable even when safe snapshots share it")
        pcall(function() b.calibration.place.position[2]=-1;b.state="corrupted" end)
        check(f.core:status().board_drop.calibration.place.position[2]==101
            and f.core:status().board_drop.state=="dropped","public status cannot mutate private board evidence")
        f.floor=88;f:step();out=f:step()
        check(f.rays==1 and f.bones_calls==1 and f.toss_calls==1 and f.clear_calls==0
            and out.board_drop.floor==99.75,"following reuses the measured floor and never repeats the drop")
        ledger(f,out);f.core:unload()
    end)
    case(function()
        local f=fixture();f.toss_mode="false";f:following();local out=f:step()
        check(out.board_drop.state=="refused" and out.board_drop.toss_result=="refused"
            and out.phase=="following" and not out.stop_latched,"known toss refusal leaves riding authority intact")
        f:step();f.core:request_stop("done");f.core:unload()
        check(f.toss_calls==1 and f.clear_calls==0,"known toss refusal is not retried and owes no board clear")
        ledger(f,f.core:status())
    end)
    for _,mode in {"raise","malformed"} do case(function()
        local f=fixture();f.toss_mode=mode;f:following();local out=f:step()
        check(out.board_drop.state=="unknown" and out.board_drop.toss_result==(mode=="raise" and "raised" or "malformed")
            and not out.stop_latched,"uncertain toss remains visible without changing lifecycle authority")
        f:step();check(f.toss_calls==1 and f.clear_calls==0,"uncertain toss is held without retry until cleanup")
        f.core:request_stop("clear uncertain toss");out=f.core:status()
        check(out.board_drop.state=="restored" and f.clear_calls==1,"cleanup clears a possibly accepted toss once")
        f.core:unload();check(f.clear_calls==1,"unload cannot repeat uncertain-toss cleanup");ledger(f,f.core:status())
    end) end
    for _,mode in {"raise","false","nil"} do case(function()
        local f=fixture();f:following();f:step();f.clear_mode=mode
        f.on_clear=function() f.clear_status=f.core:status().board_drop end
        f.core:request_stop("preserve first lifecycle cause");local out=f.core:status()
        check(f.clear_status.restore_inflight==true and f.clear_status.drop_inflight==false,
            "the clear callback reports restoration in flight before its outcome: "..mode)
        check(out.board_drop.restore_inflight==false and out.board_drop.drop_inflight==false,
            "uncertain restoration settles both in-flight flags after return")
        check(out.board_drop.state=="restore_unknown" and out.board_drop.clear_result=="raised",
            "raised or non-void clear is unknown: "..mode)
        check(out.stop_reason=="preserve first lifecycle cause" and f.clear_calls==1,"board cleanup cannot replace the stop cause")
        f.core:request_stop("again");f.core:unload();f.core:unload()
        check(f.clear_calls==1 and f.core:status().board_drop.state=="restore_unknown","unknown clear is retained without retry")
        ledger(f,f.core:status())
    end) end
    case(function()
        local f,s=fixture();f:following();f:step();local clear=s.board.clear;s.board.clear=nil
        f.core:request_stop("clear API disappeared");local out=f.core:status()
        check(out.board_drop.state=="restore_unknown" and out.board_drop.clear_result=="missing"
            and f.clear_calls==0,"missing cleanup API remains unknown without an invented SDK clear")
        s.board.clear=clear;f.core:unload();f.core:request_stop("repeat")
        check(f.clear_calls==0 and f.core:status().board_drop.state=="restore_unknown",
            "restoring the API cannot retry an unknown cleanup")
        ledger(f,f.core:status())
    end)
    case(function()
        local f=fixture();f.refuse_pose=true;f:following();local out=f:step()
        check(f.pose_probes==1 and f.pose_attempts==1 and f.pose_sends==0 and f.toss_calls==1 and f.clear_calls==1,
            "accepted mount followed by first-posture refusal restores its drop in the same tick")
        check(out.board_drop.state=="restored" and not out.stop_latched,"first-posture refusal is presentation-only cleanup")
        f:step();f.core:unload();check(f.toss_calls==1 and f.clear_calls==1,"initial posture refusal cannot redrop or repeat cleanup")
    end)
    case(function()
        local f=fixture();f.refuse_probe=true;f:following();local out=f:step()
        check(f.pose_probes==1 and f.pose_attempts==0 and out.mounted_pose.issue~=nil,"mount capability refusal precedes posture")
        check(not out.stop_latched and out.board_drop.state=="idle","unaccepted mount never owns a board drop")
        f:step();f.core:unload();no_board_calls(f,"mount refusal performs no board effects")
    end)
    case(function()
        local f=fixture();f:following();f:step();f.refuse_pose=true;local out=f:step()
        check(out.board_drop.state=="restored" and f.clear_calls==1 and f.pose_ends==1,
            "a refused mounted posture restores the already dropped board")
        check(out.phase=="following" and not out.stop_latched,"presentation loss leaves lifecycle authority unchanged")
        f:step();f.core:unload();check(f.toss_calls==1 and f.clear_calls==1,"presentation refusal cannot redrop or reclear")
    end)
    case(function()
        local f=fixture();f:following();f:step();f.events={}
        f.on_clear=function() f.clear_status=f.core:status().board_drop end
        f.core:request_stop("normal stop");local out=f.core:status()
        check(f.clear_status.restore_inflight==true and f.clear_status.drop_inflight==false,
            "the successful clear callback reports restoration in flight")
        check(out.board_drop.restore_inflight==false and out.board_drop.drop_inflight==false,
            "successful restoration settles both in-flight flags")
        check(out.board_drop.state=="restored" and out.board_drop.clear_result=="cleared" and f.clear_calls==1,
            "normal Stop accepts exactly one void clear")
        check(first(f.events,"follow_stop")<first(f.events,"clear"),"native Follow stop precedes board cleanup")
        f.core:request_stop("repeat");f.core:unload();f.core:unload()
        check(f.clear_calls==1 and f.pose_ends==1 and count(f.events,"follow_stop")==1,
            "repeated Stop and unload preserve one-shot pose, board and Follow cleanup")
        ledger(f,f.core:status())
    end)
    for _,kind in {"stop","unload"} do case(function()
        local f=fixture();f:following()
        f.on_bones=function()
            f.on_bones=nil;f.bones_status=f.core:status().board_drop
            f:cancel(kind);f.cancelled_bones_status=f.core:status().board_drop
        end
        local out=f:step()
        check(f.bones_status.drop_inflight==true and f.bones_status.restore_inflight==false
            and f.cancelled_bones_status.drop_inflight==true and f.cancelled_bones_status.restore_inflight==false,
            "calibration cancellation preserves drop in flight until the callback unwinds")
        check(out.board_drop.drop_inflight==false and out.board_drop.restore_inflight==false,
            "cancelled calibration settles both in-flight flags")
        check(out.stop_latched and f.bones_calls==1 and f.toss_calls==0 and f.clear_calls==0,
            "cancel in bones prevents any real toss or clear: "..kind)
        check(f.pose_attempts==0 and out.board_drop.state=="refused","cancelled calibration cannot continue into posture or board ownership")
        f.core:unload();check(f.toss_calls==0 and f.clear_calls==0,"unload cannot revive cancelled calibration")
        ledger(f,f.core:status())
    end) end
    for _,kind in {"stop","unload"} do
        for _,mode in {"accept","raise"} do case(function()
            local f=fixture();f:following();f.toss_mode=mode
            f.on_clear=function() f.clear_status=f.core:status().board_drop end
            f.on_toss=function()
                f.on_toss=nil;f.toss_status=f.core:status().board_drop
                f:cancel(kind);f.clear_inside_toss=f.clear_calls
                f.cancelled_toss_status=f.core:status().board_drop
            end
            local out=f:step()
            check(f.toss_status.drop_inflight==true and f.toss_status.restore_inflight==false
                and f.cancelled_toss_status.drop_inflight==true and f.cancelled_toss_status.restore_inflight==false,
                "the late toss retains its in-flight marker throughout cancellation")
            check(f.clear_status.restore_inflight==true and f.clear_status.drop_inflight==false,
                "deferred clear begins only after the toss is no longer in flight")
            check(out.board_drop.drop_inflight==false and out.board_drop.restore_inflight==false,
                "late toss restoration settles both in-flight flags")
            check(f.clear_inside_toss==0 and f.toss_calls==1 and f.clear_calls==1,
                "cleanup waits for the late toss outcome, then clears exactly once: "..kind.."/"..mode)
            check(out.stop_latched and out.board_drop.state=="restored" and not out.board_drop.restore_pending
                and out.board_drop.toss_result==(mode=="accept" and "accepted" or "raised"),
                "late acceptance or uncertainty is retained through restoration")
            check(f.pose_attempts==0,"cancelled toss cannot send the first posture after callback return")
            f.core:unload();f.core:request_stop("repeat")
            check(f.toss_calls==1 and f.clear_calls==1,"late toss cleanup leaves no duplicate work for unload")
            ledger(f,f.core:status())
        end) end
    end
    case(function()
        local f=fixture();f:following()
        f.on_probe=function() f.on_probe=nil;f.core:request_stop("cancel inside mount probe") end
        local out=f:step()
        check(out.stop_latched and f.pose_probes==1 and f.pose_attempts==0,"mount callback cancellation revokes presentation")
        no_board_calls(f,"a late successful capability classification cannot drop after cancelled mount")
        f.core:unload();no_board_calls(f,"cancelled mount leaves nothing for board cleanup")
    end)
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)

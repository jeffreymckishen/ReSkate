-- Actual Core/Source/Spawn/Poser over constructed SDK services. The runner's
-- Core copy changes only its MountedPose require to the separately qualified
-- pose copy. Core/Ride/floor/renewal gates remain unchanged; no game evidence.
local Core=require("./bike_runtime_core_mounted_pose_fixture")
local Production=require("./bike_runtime_core")
local Runtime=require("./bike_runtime")
local Services=require("./core_ride_staging_tests")
local Tests={}
local function count(events,name)
    local n=0;for _,value in ipairs(events) do if value==name then n+=1 end end;return n
end
local function first(events,name)
    for i,value in ipairs(events) do if value==name then return i end end
    return math.huge
end
local function fixture(module)
    local f,s=Services.spawn_services()
    f.events,f.pose_sends,f.pose_attempts,f.pose_probes,f.pose_ends={},0,0,0,0
    local function event(name) table.insert(f.events,name) end
    local body_read=s.world.physics.read
    function s.world.physics.read(body) event("body_read");return body_read(body) end
    local visual_set=s.entities.set
    function s.entities.set(...)
        event("visual")
        if f.refuse_visual then return false end
        return visual_set(...)
    end
    local capture_release=s.input.lease_release_capture
    function s.input.lease_release_capture(...)
        event("capture_release");return capture_release(...)
    end
    function s.skater.pose(plan,weight)
        if plan==nil then
            f.pose_ends+=1;event("pose_end")
            if f.refuse_end then return false,"constructed pose end refusal" end
            return true
        end
        if weight==2 then
            f.pose_probes+=1;event("pose_probe")
            if f.on_probe then f.on_probe() end
            error("a joint's place has a position, a rotation or both",0)
        end
        f.pose_attempts+=1;event("pose")
        if f.on_pose then f.on_pose() end
        if f.refuse_pose then return false,"constructed pose refusal" end
        f.pose_sends+=1;f.last_plan=plan;f.last_weight=weight
        return true
    end
    function s.world.physics.reserve_follow(body,attachment)
        table.insert(f.reserves,{body=body,attachment=attachment})
        f.follow=newproxy();f.follow_phase="reserved"
        return f.follow,nil
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
            final_native_epoch=f.published and "9" or "0",
            returned_revision=done and "3" or "0",pending={},in_flight=0,claim_known=not done,orphaned=false,
            park_observed=done,native_retirement_known=false,terminal=done}
    end
    function s.world.physics.acknowledge_follow(handle)
        assert(handle==f.follow and f.records.bmx_bike_lifecycle_v1.terminal_receipt)
        event("follow_ack");return true
    end
    -- This is a constructed admission boundary, not a way to rearm a native VM.
    local state={phase="armed",used=true,active=true,ledger_owned=true,level="sanvan",wipeouts=0,
        generation=1,cancel_version=0,arm_at=f.now,slot=0,calls={},counts={},receipts={},omitted_calls=0,
        omitted_receipts=0,remove_attempted={},remove_accepted={}}
    f.core=(module or Core).new(s,{qualification_only=true},state)
    assert(f.core:prepare_backend())
    function f:step()
        self.now+=16
        if self.sample and self.follow_phase=="following" then
            self.sample=table.clone(self.sample)
            self.sample.epoch=newproxy();self.sample.serial=tostring(tonumber(self.sample.serial)+1)
            self.sample.time+=1/60
            if self.shift then self.sample.position+=self.shift;self.shift=nil end
        end
        return self.core:step(16)
    end
    function f:following()
        local out=self.core:status()
        for _=1,220 do if out.phase=="following" then break end;out=self:step() end
        assert(out.phase=="following","constructed Source/Spawn reaches actual Core Follow")
        return out
    end
    return f,s
end

local function startup()
    local f,s=Services.spawn_services()
    f.focused,f.state,f.level=true,504,"sanvan"
    function s.input.focus() return {focused=f.focused,interface_open=false,gameplay=true} end
    local telemetry=s.skater.telemetry
    function s.skater.telemetry()
        if f.on_facts then f.on_facts() end
        local row=telemetry();row.watch.state=f.state;return row
    end
    function s.level.current() return {name=f.level} end
    local owner=Runtime.new(s)
    assert(owner:request_board(2))
    function f:step() self.now+=16;return owner:step(16) end
    local out=owner:status()
    for _=1,10 do
        if out.startup.last_module=="./bike_runtime_core" then break end
        out=f:step()
    end
    assert(out.startup.last_module=="./bike_runtime_core" and not out.startup.core_ready,
        "the last module import ends before Core construction")
    return f,owner,out
end

function Tests.run()
    local cases,assertions=0,0
    local function check(v,why) assertions+=1;assert(v,why) end
    local function case(run) cases+=1;run() end
    case(function()
        local pose={steer=.3,crank_phase=1.7,rear_wheel_phase=2,front_wheel_phase=3,barspin=1,
            tailwhip=2,release_left_hand=1,movement_bike_pitch=.6}
        local a=Core.mounted_articulation(pose)
        check(a.steer==.3 and a.crank_phase==1.7,"accepted steering/cranks reach the rider unchanged")
        check(a.rear_wheel_phase==nil and a.front_wheel_phase==nil and a.barspin==0 and a.tailwhip==0
            and a.release_left_hand==0 and a.movement_bike_pitch==0,"wheel phases and unbound trick channels cannot pose the rider")
        a.steer=0;check(pose.steer==.3,"the mounted articulation is detached from Ride's accepted pose")
    end)
    case(function()
        local f=fixture(Production)
        f:following();local out=f:step()
        check(f.pose_probes==0 and f.pose_sends==0 and out.mounted_pose.qualified==false,
            "the production MountedPose gate stays closed while the complete adapter is wired")
        check(out.phase=="following" and not out.stop_latched,"unqualified presentation does not change body authority")
        f.core:unload();check(f.pose_ends==0,"an unqualified pose has nothing to release")
    end)
    case(function()
        local f=fixture();local initial=f.core:status()
        check(f.core:prepare_backend() and f.core:status().startup.pose_instances==1 and f.pose_probes==0,
            "backend preparation constructs exactly one inert Poser")
        check(initial.startup.pose_instances==1,"the owner reports its single presentation instance")
        f:following();check(f.pose_sends==0,"the publish tick does not pose an unobserved following frame")
        f.events={};local out=f:step()
        check(f.pose_probes==1 and f.pose_sends==1 and out.mounted_pose.sent_ticks==1,"first following tick probes once and sends once")
        check(first(f.events,"body_read")<first(f.events,"visual") and first(f.events,"visual")<first(f.events,"pose"),
            "the rider pose follows the accepted measured body and visual update")
        local x=out.mounted_pose.plan.hips[1]
        f.shift=vector.create(.125,0,0);out=f:step()
        check(math.abs(out.mounted_pose.plan.hips[1]-x-.125)<1e-9 and f.pose_sends==2 and f.pose_probes==1,
            "the next rider plan uses the same newer translated body as the bike")
        f.events={};f.core:request_stop("constructed stop")
        check(f.pose_ends==1 and first(f.events,"follow_stop")<first(f.events,"pose_end")
            and first(f.events,"pose_end")<first(f.events,"capture_release"),"normal cleanup releases the pose after Follow stop and before capture release")
        f.core:request_stop("again");f.core:unload();f.core:unload()
        check(f.pose_ends==1 and count(f.events,"follow_stop")==1,"repeated Stop/unload does not repeat pose or Follow release")
    end)
    case(function()
        local f=fixture();f:following();f:step()
        f.refuse_pose=true;local out=f:step()
        check(out.phase=="following" and not out.stop_latched and out.mounted_pose.issue~=nil,
            "presentation refusal is reported separately from riding authority")
        check(f.pose_attempts==2 and f.pose_sends==1 and f.pose_ends==1,"a refused update releases the prior held pose")
        f:step();f:step();f.core:unload()
        check(f.pose_attempts==2 and f.pose_ends==1,"refused presentation neither retries sends nor releases twice")
    end)
    for _,unloading in ipairs({false,true}) do case(function()
        local f=fixture();f:following()
        f.on_pose=function()
            f.on_pose=nil
            if unloading then f.core:unload() else f.core:request_stop("stop inside pose send") end
        end
        f.events={};local out=f:step()
        check(f.pose_sends==1 and f.pose_ends==1 and out.mounted_pose.stopped,
            "a late accepted pose is released after reentrant "..(unloading and "unload" or "Stop"))
        check(first(f.events,"follow_stop")<first(f.events,"pose_end"),"reentrant cleanup retains Follow-before-pose ordering")
        f.core:unload();check(f.pose_ends==1,"late acceptance does not leave another pose release for VM unload")
    end) end
    case(function()
        local f=fixture();f:following()
        f.on_probe=function() f.core:request_stop("stop inside capability probe") end
        local out=f:step()
        check(f.pose_probes==1 and f.pose_attempts==0 and f.pose_ends==0 and out.stop_latched,
            "a cancelled capability probe cannot be followed by the first posture send")
    end)
    case(function()
        local f=fixture();f:following();f:step()
        f.refuse_visual=true;local out=f:step()
        check(out.stop_latched and f.pose_sends==1 and f.pose_ends==1,
            "rejected bike visuals stop before any pose can use that body sample")
    end)
    case(function()
        local f=fixture();f:following();f:step();f.refuse_end=true
        f.core:request_stop("explicit cleanup")
        local out=f.core:status()
        check(f.pose_ends==1 and out.mounted_pose.nil_accepted==false
            and out.mounted_pose.issue=="Pose release refused or unavailable",
            "a refused pose release remains an explicit presentation failure")
        check(out.stop_reason=="explicit cleanup" and count(f.events,"follow_stop")==1,
            "presentation cleanup failure does not replace the lifecycle cause or repeat Follow stop")
        f.core:unload();check(f.pose_ends==1,"unload preserves the failed release evidence without retrying it")
    end)
    case(function()
        local f,owner,before=startup()
        local deadline=before.board_return.deadline_ms
        check(owner:request_board(3)==false,"a second click cannot replace the pending original intent")
        local out=f:step()
        check(out.startup.core_ready and out.startup.core_instances==1 and out.startup.equipment_instances==1
            and not out.startup.backend_ready,"Core construction has its own tick and creates one owner")
        check(out.startup.loaded==before.startup.loaded and out.startup.last_module==before.startup.last_module
            and out.board_return.slot==2 and out.board_return.deadline_ms==deadline,"construction preserves import accounting, slot and absolute deadline")
        out=f:step()
        check(out.startup.core_instances==1 and not out.startup.pending,"only the next tick hands the request to that Core")
        owner:request_stop("test complete");owner:unload()
        check(next(f.forbidden)==nil and not f.calls["input.lease"] and not f.calls["world.physics.create"],
            "separating construction grants no input, body or Follow authority")
    end)
    for _,kind in ipairs({"stop","unload","focus","level","direction","deadline","reentrant_stop","reentrant_unload"}) do case(function()
        local f,owner,before=startup()
        if kind=="stop" then owner:request_stop("between import and construction")
        elseif kind=="unload" then owner:unload()
        elseif kind=="focus" then f.focused=false
        elseif kind=="level" then f.level="other"
        elseif kind=="direction" then f.state=100
        elseif kind=="deadline" then f.now=before.board_return.deadline_ms-16
        else f.on_facts=function()
            f.on_facts=nil
            if kind=="reentrant_unload" then owner:unload() else owner:request_stop("inside readiness") end
        end end
        local out=f:step()
        check(not out.startup.pending and not out.startup.core_ready and (out.startup.core_instances or 0)==0,
            kind.." between import and construction prevents a Core instance")
        check((out.startup.equipment_instances or 0)==0 and not f.calls["input.lease"]
            and not f.calls["world.physics.create"] and next(f.forbidden)==nil,kind.." acquires no gameplay authority")
        f:step();check(not owner:status().startup.core_ready,"later readiness never revives cancelled construction")
    end) end
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return Tests

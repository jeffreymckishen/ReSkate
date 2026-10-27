-- Actual Core/Source/Spawn/Ride/Trick/Poser wiring over constructed SDK services.
-- The runner's distinct Core copy changes only composition and the three
-- qualified dependency bindings. No canonical gate or production hook changes.
local Core=require("./bike_runtime_core_trick_wiring_fixture")
local Production=require("./bike_runtime_core")
local Services=require("./core_ride_staging_tests")
local Poser=require("./mounted_pose_qualified_fixture")
local PoseTargets=require("./pose_targets")
local Visual=require("./bike_visual")
local G=require("./bike_geometry")
local Identity=require("./lease_identity")
local Tests={}
local function copy(v)
    if type(v)~="table" then return v end
    local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out
end
local function same(a,b)
    if typeof(a)~=typeof(b) then return false end
    if typeof(a)=="vector" then return vector.magnitude(a-b)<2e-5 end
    if type(a)=="number" then return math.abs(a-b)<1e-7 end
    if type(a)~="table" then return a==b end
    if #a==4 and #b==4 and type(a[1])=="number" and type(b[1])=="number" then
        local sign=a[1]*b[1]+a[2]*b[2]+a[3]*b[3]+a[4]*b[4]<0 and -1 or 1
        for i=1,4 do if math.abs(a[i]-sign*b[i])>1e-7 then return false end end
        return true
    end
    for k,v in pairs(a) do if not same(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function fixture(module)
    local f,s=Services.spawn_services()
    f.input_serial=5;f.body_serial=1;f.body_reads=0;f.events={};f.visuals={};f.visual_order={}
    f.pose_sends,f.pose_attempts,f.pose_probes,f.pose_ends=0,0,0,0
    f.packets,f.native,f.transactions={}, {}, {};f.next_sequence=0;f.force_acks=0
    local function event(name) table.insert(f.events,name) end
    local read_source=s.input.lease_read
    function s.input.lease_read(handle)
        local row,why=read_source(handle)
        if not row then return row,why end
        if not f.pad then f.pad=copy(row.pad) end
        row.pad=copy(f.pad);row.observation_serial=tostring(f.input_serial)
        row.observed_ms=tostring(2000+f.input_serial);row.packet=f.input_serial
        return row
    end
    local state_source=s.input.lease_state
    function s.input.lease_state(handle)
        local row,why=state_source(handle)
        if not row then return row,why end
        row.observed_ms=tostring(2000+f.input_serial);row.last_observation=tostring(f.input_serial)
        return row
    end
    local set=s.entities.set
    function s.entities.set(id,name,placement,...)
        event("visual");f.visuals[id]=copy(placement.matrix);table.insert(f.visual_order,id)
        if f.on_visual then f.on_visual() end
        return set(id,name,placement,...)
    end
    function s.skater.pose(plan,weight)
        if plan==nil then f.pose_ends+=1;event("pose_end");return true end
        if weight==2 then f.pose_probes+=1;event("pose_probe");error("a joint's place has a position, a rotation or both",0) end
        f.pose_attempts+=1;event("pose");f.last_pose=copy(plan);f.last_weight=weight
        if f.on_pose then f.on_pose() end
        f.pose_sends+=1;return true
    end
    local P=s.world.physics
    local function measured()
        return {epoch=newproxy(),serial=tostring(f.body_serial),time=f.body_serial/60,seconds=1/60,
            position=f.definition.position,rotation=copy(f.definition.rotation),mass=G.mass,
            velocity=vector.create(0,0,1),angular_velocity=vector.create(0,0,0),
            inertia=vector.create(G.inertia[1],G.inertia[2],G.inertia[3])}
    end
    function P.read(body)
        assert(body==f.body and f.definition,"real Spawn/Core reads the exact allocated body")
        f.body_reads+=1;event("body_read");f.read=measured();return f.read
    end
    function P.reserve_follow(body,attachment)
        assert(body==f.body);table.insert(f.reserves,{body=body,attachment=attachment})
        f.follow=newproxy();f.follow_phase="reserved";return f.follow,nil
    end
    function P.publish_follow(handle)
        assert(handle==f.follow);f.follow_phase="following";f.published=true;return true
    end
    function P.stop_follow(handle)
        assert(handle==f.follow);event("follow_stop");f.follow_phase="stopping";return true
    end
    function P.read_follow(handle)
        assert(handle==f.follow)
        local done=f.follow_phase=="stopping"
        return {phase=done and "completed" or f.follow_phase,reason=done and "cancelled" or "none",
            park_reason=done and "none" or "unavailable",sequence="41",final_revision=f.published and "3" or "0",
            final_native_epoch=f.published and "9" or "0",returned_revision=done and "3" or "0",pending={},
            in_flight=0,claim_known=not done,orphaned=false,park_observed=done,native_retirement_known=false,terminal=done}
    end
    function P.acknowledge_follow(handle)
        assert(handle==f.follow and f.records.bmx_bike_lifecycle_v1.terminal_receipt);event("follow_ack");return true
    end
    function P.probe_batch(body,epoch,rays,settings)
        assert(body==f.body and epoch==f.read.epoch and settings.require_contact and settings.exclude_local_actor,
            "real Ride query preserves Core body/epoch ownership and actor exclusion")
        event("probe")
        local batch={status="available",epoch=epoch,native_casts=#rays,budget_exhausted=false,
            local_actor_excluded=true,owned_bodies_excluded=true,rays={}}
        for i,ray in ipairs(rays) do
            if f.clear or #rays==3 then batch.rays[i]={status="clear"}
            else
                local d=ray.from-ray.to;local length=math.sqrt(d.x*d.x+d.y*d.y+d.z*d.z)
                batch.rays[i]={status="hit",position=ray.from+vector.create(0,-G.wheel_radius,0),
                    fraction=G.wheel_radius/length,normal=vector.create(0,1,0),surface_velocity=vector.create(0,0,0),
                    normal_available=true,surface_velocity_available=true,motion="measured"}
            end
        end
        if f.bad_batch then batch.epoch=newproxy() end
        return batch
    end
    local function refresh()
        for _,row in ipairs(f.native) do
            if row.outcome=="queued" and Identity.compare(tostring(f.body_serial),row.produced)>=0 then row.outcome="applied" end
            if row.outcome=="applied" and not row.successor and Identity.compare(tostring(f.body_serial),row.produced)>0 then
                row.successor=measured()
            end
        end
    end
    function P.submit(body,epoch,command)
        assert(body==f.body and epoch==f.read.epoch and typeof(command.force)=="vector" and typeof(command.torque)=="vector")
        event("submit");refresh()
        if f.backpressure then return false,"force_pipeline_full" end
        f.next_sequence+=1;local sequence=tostring(f.next_sequence)
        local row={sequence=sequence,requested=f.read.serial,produced=tostring(f.body_serial+1),outcome="queued"}
        f.transactions[sequence]=row;table.insert(f.native,row)
        table.insert(f.packets,{sequence=sequence,epoch=epoch,serial=f.read.serial,command=copy(command)})
        if f.on_submit then f.on_submit() end
        return true,nil,sequence
    end
    function P.receipt(body,sequence)
        assert(body==f.body and f.transactions[sequence]);refresh()
        local row=f.transactions[sequence];local applied=row.outcome=="applied"
        return {sequence=sequence,requested_serial=row.requested,produced_serial=applied and row.produced or "0",
            outcome=row.outcome,force_attempted=applied,torque_attempted=applied,retained=false,quarantined=false,
            cleanup_disposition="none",successor=row.successor}
    end
    function P.acknowledge(body,sequence)
        assert(body==f.body);refresh();assert(f.native[1].sequence==sequence,"oldest exact receipt is acknowledged first")
        table.remove(f.native,1);f.force_acks+=1;return true
    end
    -- Same constructor seam as mounted-pose tests, with real Source and Spawn.
    -- No public admission, native handle or game qualification is manufactured.
    local state={phase="armed",used=true,active=true,ledger_owned=true,level="sanvan",wipeouts=0,
        generation=1,cancel_version=0,arm_at=f.now,slot=0,calls={},counts={},receipts={},omitted_calls=0,
        omitted_receipts=0,remove_attempted={},remove_accepted={}}
    f.core=(module or Core).new(s,{qualification_only=true},state)
    assert(f.core:prepare_backend(),"actual Core binds its staged real models")
    function f:step()
        self.now+=16;self.input_serial+=1
        if self.follow_phase=="following" and not self.hold_body then self.body_serial+=1 end
        self.events={};self.visual_order={}
        return self.core:step(16)
    end
    function f:following()
        local out=self.core:status()
        for _=1,220 do if out.phase=="following" or out.stop_latched then break end;out=self:step() end
        assert(out.phase=="following","real Source/Spawn must reach Core Follow: "..tostring(out.stop_reason))
        return out
    end
    function f:prime()
        self:following();local out=self:step()
        assert(out.ride and out.ride.presentation_trick and self.pose_sends==1,
            "actual Core primes Trick and sends through actual Poser: "..tostring(out.stop_reason))
        return out
    end
    function f:trick(kind)
        self:prime();self.clear=true
        local out=self:step()
        assert(out.ride.presentation_trick and out.ride.model.trick_status~="physical_support_unqualified","measured clear rays establish flight")
        if kind=="bar" then self.pad.buttons.lb=true;self.pad.right_y=-1
        elseif kind=="tail" then self.pad.left_trigger=1;self.pad.right_trigger=1;self.pad.right_x=1
        elseif kind=="crank" then self.pad.left_trigger=1;self.pad.right_trigger=1;self.pad.right_y=-1
        else self.pad.buttons.lb=true;self.pad.buttons.rb=true;self.pad.right_y=-1 end
        for _=1,5 do out=self:step();assert(not out.stop_latched,tostring(out.stop_reason)) end
        return out
    end
    return f,s
end
local function expected(f,pose,targets)
    local input={bike={center_of_mass=f.read.position,rotation=f.read.rotation},articulation=Core.mounted_articulation(pose,targets)}
    if targets then
        local authored=assert(PoseTargets.sample(targets.movement_id,targets.phase))
        input.limb_targets=authored.limb_targets
        if authored.torso then
            local t=authored.torso;input.torso={weight=t.weight,pelvis=copy(t.pelvis),pitch=t.pitch}
        end
    end
    return assert(Poser.compose(input)),input
end
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(run) cases+=1;run() end
    case(function()
        local f=fixture();local out=f.core:status()
        check(out.startup.trick_instances==1 and out.startup.pose_instances==1 and out.startup.spawn_instances==1,
            "one actual Core backend owns one real Trick, Poser and Spawn")
        check(f.pose_sends==0 and #f.packets==0 and f.body==nil,"preparing every real module remains inert")
        local public=fixture(Production);public:following();local closed=public:step()
        check(not closed.ride_composition_qualified and closed.ride==nil and public.pose_sends==0 and #public.packets==0,
            "the same services cannot open canonical Core/Ride/Poser gates")
        f.core:unload();public.core:unload()
    end)
    for _,kind in ipairs({"bar","tail","movement","crank"}) do case(function()
        local f=fixture();local out=f:trick(kind);local ride=out.ride;local t=ride.presentation_trick.targets
        if kind=="bar" then check(math.abs(t.barspin)>0 and t.barspin_release>0,"actual mapped bar channel releases the hands")
        elseif kind=="tail" then check(math.abs(t.tailwhip)>0 and t.tailwhip_release>0,"actual mapped tail channel releases the feet")
        elseif kind=="crank" then check(t.movement_id==54 and t.movement_crank_angle~=0
            and t.release_left_foot>0 and t.release_right_foot>0,"actual Crankflip delivers both independent foot releases")
        else check(t.movement_id==24 and t.release_left_hand>0 and t.release_right_hand>0,"actual Suicide delivers both independent hand releases") end
        local plan=expected(f,ride.presentation_pose,t)
        check(same(f.last_pose,plan.pose),"actual SDK posture contains the accepted full articulation and authored optional targets: "..kind)
        local ordinary=expected(f,ride.presentation_pose,nil)
        check(not same(f.last_pose,ordinary.pose),"the observed posture is distinguishable from the neutral-release path: "..kind)
        local matrices=assert(Visual.from_sample(f.read,ride.presentation_pose))
        check(#f.visual_order==8 and same(f.visuals,matrices),"actual real Spawn writes the accepted bike articulation to all eight parts")
        check(out.mounted_pose.trick_scope=="authored_limb_torso_only" and out.mounted_pose.sent_ticks==f.pose_sends
            and out.mounted_pose.issue==nil,"the real Core call site marks the authored rider path without a presentation refusal")
        check(f.force_acks>0 and out.ride.acknowledged==f.force_acks,"successive force receipts use actual Core/Ride acknowledgement plumbing")
        f.core:request_stop("case complete");f.core:unload()
        check(f.pose_ends==1,"the actual mounted pose is released once on cleanup")
    end) end
    case(function()
        local f=fixture();local out=f:trick("crank");local prior=out.ride.presentation_trick
        local sends,packets,steps=f.pose_sends,#f.packets,out.ride.model_steps
        f.hold_body=true;out=f:step()
        check(not out.stop_latched and #f.packets==packets and out.ride.model_steps==steps
            and out.ride.presentation_trick.sequence==prior.sequence,"duplicate body retains Ride history without another model step or command")
        check(f.pose_sends==sends+1 and out.mounted_pose.trick_scope==nil,
            "actual Core does not reuse an old accepted projection for duplicate-body posture")
        local base=copy(out.ride.presentation_pose)
        base.crank_phase=prior.pedal_phase;base.barspin=0;base.tailwhip=0;base.movement_bike_pitch=0;base.movement_bike_roll=0
        check(same(f.last_pose,expected(f,base,nil).pose),"duplicate-body fallback delivers the unoffset base and neutral releases to real Poser")
        check(#f.visual_order==8 and same(f.visuals,assert(Visual.from_sample(f.read,base))),
            "real Spawn redraws that duplicate body in the same-call ordinary base")
        f.core:unload()
    end)
    case(function()
        local f=fixture();local out=f:trick("crank");local prior=out.ride.presentation_trick
        local sends,packets=f.pose_sends,#f.packets;f.backpressure=true;out=f:step()
        check(not out.stop_latched and out.ride.backpressure=="core_receipt_capacity" and #f.packets==packets,
            "SDK force backpressure is a nonterminal rejected candidate")
        check(out.ride.presentation_trick==nil and out.mounted_pose.trick_scope==nil and f.pose_sends==sends+1,
            "actual Core sends a current ordinary posture rather than holding stale authored targets")
        check(out.ride.presentation_pose.crank_phase==prior.pedal_phase,"fallback preserves the unoffset accepted drive crank")
        local plan=expected(f,out.ride.presentation_pose,nil)
        check(same(f.last_pose,plan.pose),"same-call fallback reaches the real Poser without stale releases or optional requests")
        check(same(f.visuals,assert(Visual.from_sample(f.read,out.ride.presentation_pose))),"same-call fallback also reaches real Spawn")
        f.core:unload()
    end)
    case(function()
        local f=fixture();f:trick("movement");local sends,packets=f.pose_sends,#f.packets
        f.bad_batch=true;local out=f:step()
        check(out.stop_latched and #f.packets==packets and f.pose_sends==sends,"malformed SDK contact cannot publish a new command or posture")
        check(f.pose_ends==1 and out.mounted_pose.stopped,"real Core releases the prior authored pose after contact rejection")
        f.core:unload();check(f.pose_ends==1,"rejection cleanup cannot release twice")
    end)
    case(function()
        local f=fixture();f:trick("movement");local sends,packets=f.pose_sends,#f.packets
        f.on_submit=function() f.on_submit=nil;f.core:request_stop("stop inside accepted force submit") end
        local out=f:step()
        check(out.stop_latched and #f.packets==packets+1 and f.pose_sends==sends,
            "late force acceptance remains recorded without a stale posture send")
        check(out.ride.force_pending and out.ride.model_history.sequence==tostring(f.next_sequence)
            and out.ride.presentation_trick==nil,"accepted command debt survives while current trick targets are cleared")
        check(f.pose_ends==1,"reentrant force stop releases the previously mounted pose")
        f.core:unload();check(f.pose_ends==1,"late acceptance leaves no duplicate pose cleanup")
    end)
    case(function()
        local f=fixture();f:trick("movement");local sends=f.pose_sends
        f.on_visual=function() f.on_visual=nil;f.core:request_stop("stop inside bike visual write") end
        local out=f:step()
        check(out.stop_latched and f.pose_sends==sends and f.pose_ends==1,"visual callback cancellation cannot continue into the current rider target")
        check(#f.visual_order==1,"real Spawn stops at the cancelled first part write")
        f.core:unload();check(f.pose_ends==1,"visual cancellation is released once")
    end)
    case(function()
        local f=fixture();f:trick("movement");local sends=f.pose_sends
        f.on_pose=function() f.on_pose=nil;f.core:unload() end
        local out=f:step()
        check(out.unloaded and f.pose_sends==sends+1 and f.pose_ends==1,
            "late accepted posture is released after unload inside the actual SDK pose callback")
        local before=f.pose_sends;f:step();f.core:unload()
        check(f.pose_sends==before and f.pose_ends==1,"unloaded Core cannot revive authored presentation")
    end)
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)

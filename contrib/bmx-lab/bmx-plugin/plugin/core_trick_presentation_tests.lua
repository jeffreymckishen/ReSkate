-- Real qualified Ride/Trick results enter Core's production pure presenter.
-- Opaque authority and SDK transport below are constructed. Existing private
-- fixtures qualify isolated modules only; no full active Core or native claim.
local Core=require("./bike_runtime_core")
local Ride=require("./ride_runtime_tricks_qualified_fixture")
local ProductionRide=require("./ride_runtime")
local Adapter=require("./trick_runtime_ride_support_qualified_fixture")
local Fixtures=require("./ride_runtime_tests")
local Services=require("./core_ride_staging_tests")
local Contact=require("./contact_runtime")
local Forces=require("./forces")
local Identity=require("./lease_identity")
local PoseTargets=require("./pose_targets")
local Poser=require("./mounted_pose_qualified_fixture")
local ProductionPoser=require("./mounted_pose")
local Increment=require("./trick_runtime_tests").increment
local Tests={}
local source_names={"generation","user","sequence","source_epoch","context_generation","observation_serial","observed_ms","packet"}
local releases={"barspin_release","tailwhip_release","release_left_hand","release_right_hand","release_left_foot","release_right_foot"}
local function copy(v)
    if type(v)~="table" then return v end
    local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out
end
local function freeze(v)
    if type(v)=="table" and not table.isfrozen(v) then
        for _,x in pairs(v) do freeze(x) end;table.freeze(v)
    end
    return v
end
local function wrap(x) x%=2*math.pi;if x>math.pi then x-=2*math.pi end;return x end
local function key(source)
    local out={generation=source.generation}
    for _,name in ipairs(source_names) do if name~="generation" then out[name]=source.sample[name] end end
    return out
end
-- Bounded local reuse of ride_trick_projection_tests' real contact/adapter and
-- N+1 application/N+2 successor transport; its pinned local factory is untouched.
local function fixture()
    local f=Fixtures.fixture({no_tricks=true})
    local sample=f.sample
    function f.sample() local s=sample();s.velocity=vector.create(0,0,1);return s end
    f.adapter=Adapter.new();f.adapter_calls=0
    local tricks={}
    function tricks:step(frame,contact,actions)
        f.adapter_calls+=1;f.trick_frame=frame;f.actions=copy(actions)
        f.result=f.adapter:step(frame,contact,actions);return f.result
    end
    function f.api.probe_batch(epoch,plan,settings)
        assert(epoch==f.read.epoch and settings.exclude_local_actor,"exact real Ride query identity")
        local batch={status="available",epoch=epoch,native_casts=#plan,budget_exhausted=false,
            local_actor_excluded=true,owned_bodies_excluded=true,rays={}}
        for i,r in ipairs(plan) do
            if #plan==3 or f.clear then batch.rays[i]={status="clear"}
            else
                local d=r.from-r.to;local length=math.sqrt(d.x*d.x+d.y*d.y+d.z*d.z)
                batch.rays[i]={status="hit",position=r.from+vector.create(0,-Forces.wheel_radius,0),
                    fraction=Forces.wheel_radius/length,normal=vector.create(0,1,0),surface_velocity=vector.create(0,0,0),
                    normal_available=true,surface_velocity_available=true,motion="measured"}
            end
        end
        return batch
    end
    f.native={};f.records={};f.commands={};f.next_id="9007199254745000"
    local function refresh()
        for _,r in ipairs(f.native) do
            if r.outcome=="queued" and Identity.compare(f.serial,r.produced)>=0 then r.outcome="applied" end
            if r.outcome=="applied" and not r.successor and Identity.compare(f.serial,r.produced)>0 then r.successor=copy(f.sample()) end
        end
    end
    function f.api.submit(epoch,command)
        refresh();assert(epoch==f.read.epoch)
        f.next_id=Increment(f.next_id)
        local r={sequence=f.next_id,requested=f.serial,produced=Increment(f.serial),outcome="queued"}
        f.records[r.sequence]=r;table.insert(f.native,r);table.insert(f.commands,copy(command))
        return true,nil,r.sequence
    end
    function f.api.receipt(sequence)
        refresh();local r=f.records[sequence];local applied=r.outcome=="applied"
        return {sequence=sequence,requested_serial=r.requested,produced_serial=applied and r.produced or "0",
            outcome=r.outcome,force_attempted=applied,torque_attempted=applied,retained=false,quarantined=false,
            cleanup_disposition="none",successor=r.successor}
    end
    function f.api.acknowledge(sequence)
        refresh();assert(f.native[1].sequence==sequence);table.remove(f.native,1);return true
    end
    f.ride=Ride.new(f.api,{mapping=f.mapping,force=f.force,contact=Contact,tricks=tricks},
        {body_handle=f.body,incarnation=f.incarnation})
    f.follow=newproxy();f.generation=7
    local source=f.frame();local bound=key(source);bound.lease_handle=f.lease
    bound.observation_serial,bound.observed_ms,bound.packet=nil,nil,nil
    f.owner=freeze({body=f.body,follow=f.follow,generation=f.generation,source=bound,incarnation=f.incarnation})
    f.binding={owner=f.owner}
    function f.context(source_frame,read)
        return {ride=f.ride,binding=f.binding,owner=f.owner,body=f.body,follow=f.follow,generation=f.generation,
            source_frame=source_frame,sample=read,live=true}
    end
    function f.present(p)
        local source_frame,read=f.frame(),f.sample();local c=f.context(source_frame,read)
        p:begin(c)
        local row=f.observe(nil,read,source_frame)
        p:finish(c,row);return row,c,p:display(c)
    end
    return f
end
-- Start with a real accepted result, then deliberately construct a nontrivial
-- bounded DTO to isolate the pure consumer from model-selection restrictions.
local function record(provider)
    local f=fixture();local source,read=f.frame(),f.sample();local c=f.context(source,read)
    local row=copy(f.observe(nil,read,source))
    assert(row.presentation_trick and not row.stop_requested,"real Ride must supply the seed projection")
    local t=row.presentation_trick.targets
    t.movement_id=35;t.phase=.6;t.progress=.6;t.barspin=.4;t.tailwhip=.5
    t.movement_bike_pitch=.03;t.movement_bike_roll=.04;t.movement_crank_angle=.35
    for i,name in ipairs(releases) do t[name]=i/10 end
    row.presentation_trick.pedal_phase=.654321
    local p=row.presentation_pose;p.steer=.123456;p.crank_phase=wrap(.654321+t.movement_crank_angle)
    for _,name in ipairs({"barspin","tailwhip","movement_bike_pitch","movement_bike_roll"}) do p[name]=t[name] end
    return Core.trick_presenter(Identity,provider or PoseTargets),c,row,f
end
local function accept(p,c,row) p:begin(c);p:finish(c,row);return p:display(c) end
local function next_record(c,row)
    local n=table.clone(c);n.sample=copy(c.sample);n.sample.epoch=newproxy()
    n.sample.serial=Increment(c.sample.serial);n.sample.time+=n.sample.seconds
    n.source_frame=copy(c.source_frame)
    n.source_frame.sample.observation_serial=Increment(c.source_frame.sample.observation_serial)
    n.source_frame.sample.observed_ms=Increment(c.source_frame.sample.observed_ms)
    local r=copy(row);local t=r.presentation_trick
    r.model_history.serial=n.sample.serial;r.model_history.sequence=Increment(row.model_history.sequence)
    if t then
        t.serial=n.sample.serial;t.time=n.sample.time;t.seconds=n.sample.seconds
        t.sequence=r.model_history.sequence;t.source=key(n.source_frame)
    end
    return n,r
end
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(run) cases+=1;run() end
    local function base(view,why)
        check(view.targets==nil and view.limb_targets==nil and view.torso==nil and view.scope==nil,why)
    end
    case(function()
        local calls=0;local p=Core.trick_presenter(Identity,{sample=function() calls+=1;error("not yet",0) end})
        local out=p:display(nil);check(out.pose==nil and calls==0,"construction/display are inert without a verified base")
        local _,s=Services.spawn_services();local core=Core.new(s)
        check(core:status().ride_composition_qualified==false and not core:prepare_backend(),"public Core composition remains closed")
        check(ProductionRide.new({},nil,{}):status().activation_qualified==false
            and ProductionPoser.new({}):status().qualified==false,"production Ride and MountedPose gates remain closed")
        local a=Core.mounted_articulation({steer=.2,crank_phase=.3,barspin=1,tailwhip=2})
        check(a.steer==.2 and a.crank_phase==.3 and a.barspin==0 and a.tailwhip==0,"older one-argument rider input keeps trick channels neutral")
    end)
    case(function()
        local f=fixture();local p=Core.trick_presenter(Identity,PoseTargets);local row,c,v=f.present(p)
        check(row.submitted==1 and f.adapter_calls==1 and f.result.valid and f.result.fresh and f.result.advanced,
            "real Ride adopts a fresh advanced adapter result through exact force acceptance")
        check(v.targets and v.scope=="authored_limb_torso_only" and v.realized==false
            and v.pose.crank_phase==row.presentation_pose.crank_phase,"the helper presents the accepted result without realization claims")
        p:begin(c);local same=f.observe(nil,c.sample,c.source_frame);p:finish(c,same)
        base(p:display(c),"a duplicate real body observation cannot re-publish the old trick projection")
        check(f.adapter_calls==1 and same.model_history.sequence==row.model_history.sequence,"duplicate never advances adapter or accepted history")
    end)
    case(function()
        local f=fixture();f.input_serial="30";f.ms="1000"
        local p=Core.trick_presenter(Identity,PoseTargets);f.present(p)
        f.clear=true;f.advance();local air=f.present(p)
        check(air.presentation_trick and f.result.model_events.took_off,"real measured support loss establishes model flight")
        f.input_serial="33";f.ms="1018";f.now+=1;f.pad.buttons.lb=true;f.pad.buttons.rb=true;f.pad.right_y=-1
        local queued=f.present(p);local calls=f.adapter_calls
        check(queued.input_queued==1,"first duplicate body queues the actual observation 33")
        f.new_input();f.pad.buttons.lb=false;f.pad.buttons.rb=false;f.pad.right_y=0;f.present(p)
        check(f.input_serial=="34" and f.adapter_calls==calls,"second duplicate queues release without stepping Trick")
        f.advance();local row,c,v=f.present(p)
        check(c.source_frame.sample.observation_serial=="35" and row.presentation_trick.source.observation_serial=="33",
            "advanced body consumes queued witness 33 while the current Source observation is 35")
        check(f.actions.movement==24 and v.targets and v.targets.movement_id==24 and f.adapter_calls==calls+1,
            "exact witnessed older input is accepted rather than restamped or rejected")
    end)
    case(function()
        local f=fixture();local p=Core.trick_presenter(Identity,PoseTargets);f.present(p)
        f.clear=true;f.advance();f.present(p)
        f.pad.left_trigger=1;f.pad.right_trigger=1;f.pad.right_y=-1
        local row,c,v
        for _=1,4 do f.advance();row,c,v=f.present(p) end
        local t=row.presentation_trick
        check(t and t.targets.movement_id==54 and math.abs(t.targets.movement_crank_angle)>0,
            "real mapped Crankflip creates a nonzero accepted crank offset")
        check(v.targets and v.pose.crank_phase==row.presentation_pose.crank_phase
            and v.pose.crank_phase==wrap(t.pedal_phase+t.targets.movement_crank_angle),"accepted crank composition passes through exactly once")
        p:begin(c);p:finish(c,row);local fallback=p:display(c)
        base(fallback,"repeated sequence loses all trick channels in the same call")
        check(fallback.pose.crank_phase==t.pedal_phase and fallback.pose.barspin==0,"replay falls back to the unoffset accepted pedal phase")
    end)
    case(function()
        local f=fixture();local p=Core.trick_presenter(Identity,PoseTargets);local first=f.present(p)
        local observation,observed_ms=f.input_serial,f.ms
        check(first.input_queued==0 and first.input_staged==1,"the initial real observation is consumed")
        for _=1,3 do
            f.advance();f.input_serial=observation;f.ms=observed_ms
            local row,_,v=f.present(p)
            check(row.input_queued==0 and row.input_staged==1 and row.presentation_trick.source.observation_serial==observation,
                "empty queue retains its actually consumed source across fresh body epochs")
            check(v.targets~=nil and not row.stop_requested,"held input remains eligible for fresh accepted presentation")
        end
        check(f.adapter_calls==4 and #f.commands==4,"held input still advances real Trick and accepted force once per body step")
    end)
    case(function()
        local f=fixture();local p=Core.trick_presenter(Identity,PoseTargets);f.present(p)
        local submit=f.api.submit;local before=#f.commands
        function f.api.submit(...)
            local ok,why,sequence=submit(...);f.ride:stop("constructed stop inside accepted submit")
            return ok,why,sequence
        end
        f.advance();local row,c,v=f.present(p)
        check(row.stop_requested and #f.commands==before+1 and row.model_history.serial==c.sample.serial,
            "reentrant stop preserves the exact newly accepted command history")
        check(row.force_pending and row.pending_count>0 and row.model_history.sequence==f.next_id,
            "accepted receipt debt remains owned after the reentrant stop")
        base(v,"stopped real Ride cannot publish a current Core target")
        check(v.pose==nil,"stop resets even the presenter's remembered owner base")
    end)
    case(function()
        local f=fixture();local p=Core.trick_presenter(Identity,PoseTargets);f.present(p)
        local row,c,v
        for _=1,32 do
            f.new_input();row,c,v=f.present(p)
            check(not row.stop_requested,"32 one-millisecond duplicate-body observations fit the real queue")
        end
        check(row.input_queued==32 and row.input_staged==33 and f.adapter_calls==1,
            "the real queue is full without advancing Trick or aging its oldest observation past 100 ms")
        f.new_input();row,c,v=f.present(p)
        check(row.stop_requested and row.issue=="selected input staging capacity exceeded" and #f.commands==1,
            "the next distinct observation causes the real capacity stop before another command")
        base(v,"actual queue overflow clears Core's active target")
        check(v.pose==nil and row.force_pending,"capacity stop resets the presenter while retaining accepted receipt debt")
    end)
    case(function()
        local p,c,row=record();local first=copy(key(c.source_frame));local last
        for i=1,33 do
            local n=table.clone(c);n.source_frame=copy(c.source_frame)
            n.source_frame.sample.observation_serial=tostring(100+i);n.source_frame.sample.observed_ms=tostring(200+i)
            if i==1 then first=key(n.source_frame) end
            p:begin(n);last=n
        end
        for _=1,40 do p:begin(last) end
        row.presentation_trick.source=first;p:finish(last,row)
        check(p:display(last).targets~=nil,"33 distinct witnessed source keys survive repeated polls of the newest observation")
        local n,r=next_record(last,row);r.presentation_trick.source=first
        p:begin(n);p:finish(n,r);base(p:display(n),"a 34th distinct key evicts the oldest witness despite advancing accepted history")
        local current,new_row=next_record(n,r)
        check(accept(p,current,new_row).targets~=nil,"a current witnessed projection still accepts after bounded eviction")
    end)
    case(function()
        for _,name in ipairs(source_names) do
            local p,c,row=record();check(accept(p,c,row).targets~=nil,"seed witness: "..name)
            local n,r=next_record(c,row);local value=r.presentation_trick.source[name]
            r.presentation_trick.source[name]=type(value)=="number" and value+1 or Increment(value)
            p:begin(n);p:finish(n,r);base(p:display(n),"unwitnessed source scalar is rejected: "..name)
        end
    end)
    case(function()
        for _,kind in ipairs({"ride","binding","owner","body","follow","generation","lease","epoch","sample","source_frame","live"}) do
            local p,c,row=record();p:begin(c)
            if kind=="ride" then c.ride={}
            elseif kind=="binding" then c.binding={owner=c.owner}
            elseif kind=="owner" then c.owner=freeze(copy(c.owner));c.binding={owner=c.owner}
            elseif kind=="body" then c.body=newproxy()
            elseif kind=="follow" then c.follow=newproxy()
            elseif kind=="generation" then c.generation+=1
            elseif kind=="lease" then c.source_frame.lease_handle=newproxy()
            elseif kind=="epoch" then c.sample.epoch=newproxy()
            elseif kind=="sample" then c.sample=copy(c.sample)
            elseif kind=="source_frame" then c.source_frame=copy(c.source_frame)
            else c.live=false end
            p:finish(c,row);base(p:display(c),"same-call opaque identity cannot change: "..kind)
        end
    end)
    case(function()
        for _,name in ipairs(source_names) do
            local p,c,row=record();p:begin(c)
            if name=="generation" then c.source_frame.generation+=1
            else
                local value=c.source_frame.sample[name]
                c.source_frame.sample[name]=type(value)=="number" and value+1 or Increment(value)
            end
            p:finish(c,row);base(p:display(c),"Source scalars cannot change during the observed call: "..name)
        end
    end)
    case(function()
        local changes={
            function(r) r.model_history.kind="constructed_unaccepted" end,
            function(r) r.model_history.serial=Increment(r.model_history.serial) end,
            function(r) r.model_history.sequence="01" end,
            function(r) r.presentation_trick.sequence=Increment(r.presentation_trick.sequence) end,
            function(r) r.presentation_trick.serial=Increment(r.presentation_trick.serial) end,
            function(r) r.presentation_trick.time+=.001 end,
            function(r) r.presentation_trick.seconds*=2 end,
            function(r) r.stop_requested=true end,
            function(r) r.unknown=true end,
        }
        for i,change in ipairs(changes) do
            local p,c,row=record();change(row);p:begin(c);p:finish(c,row)
            base(p:display(c),"fresh accepted-history requirements reject malformed DTO "..i)
        end
    end)
    case(function()
        local p,c,row=record();local good=accept(p,c,row);check(good.targets~=nil,"seed nontrivial target")
        local n,r=next_record(c,row);r.presentation_trick.targets.barspin_release=2
        p:begin(n);p:finish(n,r);local v=p:display(n)
        base(v,"a malformed new target removes the previous target immediately")
        check(v.pose.crank_phase==.654321 and v.pose.barspin==0 and v.pose.tailwhip==0,
            "malformed composed DTO cannot replace the verified unoffset base")
        check(good.targets.barspin_release==.1,"a previous frozen diagnostic remains immutable evidence, not current display")
    end)
    case(function()
        local p,c,row=record();accept(p,c,row);local n,r=next_record(c,row)
        r.model_history.sequence=row.model_history.sequence;r.presentation_trick.sequence=row.model_history.sequence
        p:begin(n);p:finish(n,r);local v=p:display(n)
        base(v,"a new body cannot make a reused command sequence advanced")
        check(v.pose.crank_phase==.654321,"reused sequence does not adopt its composed crank")
    end)
    case(function()
        local p,c,row=record();accept(p,c,row);local n,r=next_record(c,row)
        r.presentation_trick=nil;r.presentation_pose={steer=.2,front_wheel_phase=.4,rear_wheel_phase=.5,crank_phase=.6,
            barspin=0,tailwhip=0,movement_bike_pitch=0,movement_bike_roll=0}
        p:begin(n);p:finish(n,r);local v=p:display(n)
        base(v,"a nil projection consumes the ordinary Ride base in the same call")
        check(v.pose.steer==.2 and v.pose.crank_phase==.6,"ordinary accepted base remains available")
    end)
    case(function()
        local p,c,row=record();row.presentation_trick.targets.progress=0/0
        p:begin(c);p:finish(c,row);check(p:display(c).pose==nil,"first invalid projection cannot invent a base")
        local p2,c2,r2=record();p2:finish(c2,r2)
        check(p2:display(c2).targets==nil and p2:display(c2).pose==nil,"finish without begin has no observed authority")
    end)
    case(function()
        local p,c,row=record();local v=accept(p,c,row);local a=Core.mounted_articulation(v.pose,v.targets)
        for _,name in ipairs({"steer","crank_phase","barspin","tailwhip","movement_bike_pitch","movement_bike_roll"}) do
            check(a[name]==v.pose[name],"accepted pose angle is unchanged: "..name)
        end
        for _,name in ipairs(releases) do check(a[name]==v.targets[name],"all six independent releases propagate: "..name) end
        check(a.front_wheel_phase==nil and a.rear_wheel_phase==nil,"bike wheel phases do not enter rider articulation")
    end)
    case(function()
        local calls,authored=0,nil
        local provider={sample=function(id,phase) calls+=1;authored=assert(PoseTargets.sample(id,phase));return authored end}
        local p,c,row=record(provider);local v=accept(p,c,row)
        check(calls==1 and authored.torso.head_yaw~=0 and v.torso.head_yaw==nil,"sample once and omit the uncalibrated authored head request")
        check(v.torso.weight==.6 and v.torso.pitch==authored.torso.pitch and v.torso.pelvis[3]==authored.torso.pelvis[3],
            "torso phase is a weight, not a second scale on the authored offset")
        check(v.limb_targets~=authored.limb_targets and v.torso.pelvis~=authored.torso.pelvis
            and table.isfrozen(v) and table.isfrozen(v.targets) and table.isfrozen(v.limb_targets.left_hand.direction),
            "optional authored records are detached and deeply frozen")
        local x=v.limb_targets.left_hand.direction[1]
        authored.limb_targets.left_hand.direction[1]=99;authored.torso.pelvis[3]=99;row.presentation_trick.targets.release_left_hand=0
        check(v.limb_targets.left_hand.direction[1]==x and v.torso.pelvis[3]~=99 and v.targets.release_left_hand==.3,
            "producer mutation cannot alter the accepted view")
        p:display(c);p:display(c);check(calls==1,"display cannot resample authored targets")
    end)
    case(function()
        local p,c,row=record();row.presentation_trick.targets.movement_id=26
        local v=accept(p,c,row)
        check(v.targets and v.limb_targets==nil and v.torso and v.torso.head_yaw==nil,
            "Lookback preserves torso-only authoring while omitting its nonzero head yaw")
    end)
    case(function()
        local p,c,row=record();local v=accept(p,c,row);local sends=0
        local poser=Poser.new({skater={pose=function(plan,weight)
            if plan==nil then return true end
            if weight==2 then error("place has a position, a rotation or both",0) end
            sends+=1;return true
        end}})
        check(poser:mount(0).ok,"qualified real Poser accepts the constructed capability probe")
        local bike={center_of_mass=c.sample.position,rotation=c.sample.rotation}
        local neutral={bike=bike,articulation={steer=.123456,crank_phase=.654321}}
        check(poser:tick(0,neutral).ok and poser:tick(.016,neutral).ok,"ordinary rider pose warms its existing cache")
        local hits,misses=poser.memo_hits,poser.memo_misses
        check(hits==1 and misses==1,"control path establishes a real memo hit")
        local input={bike=bike,articulation=Core.mounted_articulation(v.pose,v.targets),limb_targets=v.limb_targets,torso=v.torso}
        local a=poser:tick(.032,input);local b=poser:tick(.048,input)
        check(a.ok and a.sent and b.ok and b.sent and sends==4,"real Poser composes and sends the optional limb/torso request")
        check(poser.memo_hits==hits and poser.memo_misses==misses,"optional authored inputs bypass the memo on every call")
        local raw=PoseTargets.sample(35,.6);local uncalibrated=table.clone(input);uncalibrated.torso=raw.torso
        check(Poser.compose(uncalibrated)==nil,"control rejects the raw nonzero head request without calibration")
        local direct=assert(Poser.compose(input))
        check(math.abs(a.plan.targets.wrists[1][1]-direct.targets.wrists[1][1])<1e-7,
            "optional composition matches the uncached real pose solver")
        check(poser:tick(.064,neutral).ok and poser.memo_misses==misses+1,"authored composition invalidates the prior neutral memo")
        poser:stop()
    end)
    case(function()
        local p,c,row=record({sample=function() error("constructed authoring refusal",0) end})
        p:begin(c);p:finish(c,row);local v=p:display(c)
        base(v,"authored-target failure exposes no partial optional pose")
        check(v.pose and v.pose.crank_phase==.654321,"accepted base remains known even when optional authoring fails")
    end)
    case(function()
        local p,c,row=record();check(accept(p,c,row).targets~=nil,"seed reset case")
        p:reset();local v=p:display(c);base(v,"reset clears active presentation")
        check(v.pose==nil,"reset also clears remembered owner base")
        p:finish(c,row);check(p:display(c).pose==nil,"old finish after reset cannot resurrect targets or base")
    end)
    case(function()
        local p,c,row=record();accept(p,c,row);local other=table.clone(c);other.sample=copy(c.sample)
        other.sample.epoch=newproxy();base(p:display(other),"display requires the original accepted body read")
        check(p:display(c).targets~=nil,"a refused observation does not mutate the verified cached diagnostic")
        p:begin(other);base(p:display(other),"begin clears the old target before a new result exists")
    end)
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)

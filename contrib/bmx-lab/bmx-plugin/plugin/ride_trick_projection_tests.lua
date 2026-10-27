-- Real Ride, input mapping, contact decoder, force model and trick adapter over
-- constructed Core transport. No native/body/controller qualification is claimed.
-- The runner stages Ride with only ACTIVATION_QUALIFIED and RIDE_TRICKS_QUALIFIED
-- changed to true; the real adapter fixture changes only RIDE_SUPPORT_QUALIFIED.
local Ride=require("./ride_runtime_tricks_qualified_fixture")
local LegacyRide=require("./ride_runtime_qualified_fixture")
local Runtime=require("./trick_runtime_ride_support_qualified_fixture")
local Fixtures=require("./ride_runtime_tests")
local Contact=require("./contact_runtime")
local Forces=require("./forces")
local Identity=require("./lease_identity")
local Increment=require("./trick_runtime_tests").increment
local Tests={}
local source_fields={"generation","user","sequence","source_epoch","context_generation","observation_serial","observed_ms","packet"}
local function copy(v)
    if type(v)~="table" then return v end
    local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out
end
local function wrap(x) x%=2*math.pi;if x>math.pi then x-=2*math.pi end;return x end
local function fixture(options)
    options=options or {}
    local f=Fixtures.fixture({no_tricks=true})
    local sample=f.sample
    function f.sample() local s=sample();s.velocity=vector.create(0,0,1);return s end
    f.adapter=Runtime.new();f.adapter_calls=0
    local tricks={}
    function tricks:step(frame,contact,actions)
        f.adapter_calls+=1;f.trick_frame=frame;f.trick_contact=contact;f.actions=copy(actions)
        local out=f.adapter:step(frame,contact,actions)
        if f.on_result then f.on_result(out) end
        f.result=out
        return out
    end
    local contact={CATEGORY_WHEEL_LANE_QUALIFIED=options.category==true}
    -- A declared test policy for the category branch, never native qualification.
    function contact.actor_lane_qualified(q)
        return options.category and q.actor_lane=="named_categories_absent" or Contact.actor_lane_qualified(q)
    end
    function contact.decode(frame,plan,batch)
        local out=Contact.decode(frame,plan,batch)
        if #plan==2 then f.decoded=out end
        return out
    end
    function f.api.probe_batch(epoch,plan,settings)
        assert(epoch==f.read.epoch,"constructed batch belongs to the exact observed epoch")
        local batch={status="available",epoch=epoch,native_casts=#plan,budget_exhausted=false,
            local_actor_excluded=not options.category,owned_bodies_excluded=true,rays={}}
        if options.category then
            assert(settings.query_preset=="camera" and settings.require_named_actor_categories_absent)
            batch.requested_query_preset="camera";batch.named_actor_categories_absent=true
        else assert(settings.exclude_local_actor) end
        for i,r in ipairs(plan) do
            if #plan==3 or f.clear then batch.rays[i]={status="clear"}
            else
                local delta=r.from-r.to;local distance=math.sqrt(delta.x^2+delta.y^2+delta.z^2)
                local gap=f.front_gap and i==1 and f.front_gap or 0
                local depth=Forces.wheel_radius+gap
                batch.rays[i]={status="hit",position=r.from+vector.create(0,-depth,0),fraction=depth/distance,
                    normal=vector.create(0,1,0),surface_velocity=vector.create(0,0,0),
                    normal_available=true,surface_velocity_available=true,motion="measured"}
            end
        end
        if f.on_batch then f.on_batch(batch,#plan) end
        return batch
    end
    -- Same N+1 application/N+2 successor construction as Ride's presentation
    -- tests. Accepted Lua predictions are not proof of this SDK timing in game.
    f.native={};f.records={};f.commands={};f.next_id="9007199254745000"
    local function refresh()
        for _,r in ipairs(f.native) do
            if r.outcome=="queued" and not f.hold_inbox and Identity.compare(f.serial,r.produced)>=0 then r.outcome="applied" end
            if r.outcome=="applied" and not r.successor and Identity.compare(f.serial,r.produced)>0 then r.successor=copy(f.sample()) end
        end
    end
    function f.api.submit(epoch,command)
        refresh();assert(epoch==f.read.epoch)
        if f.on_admission then return f.on_admission() end
        if f.refusal then return false,f.refusal end
        f.next_id=Increment(f.next_id)
        local r={sequence=f.next_id,requested=f.serial,produced=Increment(f.serial),outcome="queued"}
        f.records[r.sequence]=r;table.insert(f.native,r)
        table.insert(f.commands,{sequence=r.sequence,serial=f.serial,command=copy(command)})
        return true,nil,r.sequence
    end
    function f.api.receipt(sequence)
        refresh();local r=f.records[sequence];local attempted=r.outcome=="applied"
        return {sequence=sequence,requested_serial=r.requested,produced_serial=attempted and r.produced or "0",
            outcome=r.outcome,force_attempted=attempted,torque_attempted=attempted,retained=false,quarantined=false,
            cleanup_disposition="none",successor=r.successor}
    end
    function f.api.acknowledge(sequence)
        refresh();assert(f.native[1].sequence==sequence);table.remove(f.native,1);return true
    end
    f.ride=(options.legacy and LegacyRide or Ride).new(f.api,{mapping=f.mapping,force=f.force,contact=contact,
        tricks=not options.no_tricks and tricks or nil},{body_handle=f.body,incarnation=f.incarnation})
    function f.tick()
        if f.started then f.advance() end
        f.started=true
        return f.observe()
    end
    return f
end
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function scenario(run) cases+=1;run() end
    local function air(f)
        check(f.tick().presentation_trick~=nil,"real adapter primes from constructed admitted wheel support")
        f.clear=true
        check(f.tick().presentation_trick~=nil and f.result.model_events.took_off,"measured clear branch advances real model flight")
    end
    local function bar(f)
        air(f);f.pad.buttons.lb=true;f.pad.right_y=-1
        local s=f.tick()
        check(f.actions.handlebar=="left" and f.result.model_state.bar_rotating,"actual mapped pad starts the real bar channel")
        for _=1,3 do s=f.tick() end
        check(s.presentation_trick.targets.barspin_release==1,"accepted samples project the real released bar channel")
        return s
    end
    scenario(function()
        local f=fixture({legacy=true});local s=f.tick()
        check(s.submitted==1 and s.presentation_trick==nil and s.presentation_pose.barspin==0,"old Ride gate retains neutral presentation")
        check(not f.result.valid and f.trick_contact.support.known==false,"old gate does not promote decoded ray support")
        local fake=Fixtures.fixture();check(fake.observe().model_steps==1,"existing fake-companion contract remains intact")
    end)
    scenario(function()
        local f,g=fixture({no_tricks=true}),fixture({legacy=true,no_tricks=true})
        for _=1,3 do
            local a,b=f.tick(),g.tick()
            check(a.presentation_trick==nil and a.submitted==b.submitted,"no companion retains the same accepted cadence")
            local n=0;for key,value in pairs(a.presentation_pose) do n+=1;check(value==b.presentation_pose[key],"no companion pose unchanged: "..key) end
            check(n==8,"no additional visual fields")
        end
    end)
    scenario(function()
        local f=fixture();local s=f.tick();local packet,decoded=f.trick_contact,f.decoded
        check(packet~=decoded and packet.binding==decoded.binding and packet.frame==decoded.frame
            and packet.query==decoded.query and packet.rays==decoded.rays,"envelope preserves original exact decoded records")
        check(decoded.support.known==false and packet.support.known and packet.support.native_collision_contact==false,"derived support never rewrites native collision provenance")
        check(packet.support.wheel_index==1 and packet.support.landing_vectors_available,"front eligible wheel supplies landing vectors")
        local t=s.presentation_trick
        check(t.serial==f.serial and t.time==f.time and t.seconds==Forces.native_seconds and t.sequence==s.model_history.sequence,"projection identifies its accepted frame and sequence")
        for _,key in ipairs(source_fields) do check(t.source[key]==f.trick_frame.source[key],"exact scalar source: "..key) end
        check(t.body_handle==nil and t.physics_epoch==nil and t.source.lease_handle==nil and t.realized==false,"public projection contains no opaque handles or realization")
        check(table.isfrozen(t) and table.isfrozen(t.targets) and table.isfrozen(t.source),"projection is frozen through")
        check(not pcall(function() t.targets.barspin=9 end),"consumer cannot mutate accepted targets")
        f.result.visual_targets.barspin=7
        check(f.ride:status().presentation_trick.targets.barspin==0,"producer mutation cannot alter accepted copy")
    end)
    scenario(function()
        local f=fixture();f.front_gap=.04;local s=f.tick();local p=f.trick_contact
        check(s.presentation_trick~=nil and p.support.wheel_index==2,"distant first hit does not displace eligible rear wheel")
        check(p.support.point[3]==p.rays[2].position[3] and p.support.point[3]~=p.rays[1].position[3],"rear support retains exact measured point")
    end)
    scenario(function()
        local f=fixture({category=true});local s=f.tick();local serial=f.serial
        check(s.presentation_trick~=nil and f.trick_contact.support.actor_tripwire_serial==serial,"current tripwire carries its real serial")
        check(f.trick_contact.query.local_actor_excluded==false,"category lane does not invent actor identity exclusion")
        s=f.tick()
        check(s.presentation_trick~=nil and f.trick_contact.support.actor_tripwire_serial==serial
            and f.trick_contact.support.actor_tripwire=="authored_rider_crossings_clear_previous_epoch_v1","cached tripwire retains previous serial and label")
    end)
    scenario(function()
        local f=fixture();bar(f)
        for _=1,28 do f.tick() end
        local s=f.ride:status();local t=s.presentation_trick.targets
        check(f.result.model_state.bar_waiting_catch and t.barspin_release==1,"completed rotation keeps hands released until actual model catch")
        check(math.abs(math.abs(s.presentation_pose.barspin)-2*math.pi)<1e-7,"accepted geometric full turn is preserved")
        f.pad.right_y=0;f.pad.buttons.lb=false;s=f.tick()
        check(f.result.model_events.bar_caught and s.presentation_trick.targets.barspin_release==1,"catch begins without instantaneous regrip")
        s=f.tick();check(s.presentation_trick.targets.barspin_release>0 and s.presentation_trick.targets.barspin_release<1,"next accepted sample carries catch blend")
    end)
    scenario(function()
        local f=fixture();air(f);f.pad.left_trigger=1;f.pad.right_trigger=1;f.pad.right_x=1
        local s=f.tick()
        check(f.actions.tailwhip=="right" and f.result.model_state.tail_rotating,"mapped triggers and stick start the real tail channel")
        for _=1,4 do s=f.tick() end
        check(s.presentation_trick.targets.tailwhip_release==1,"accepted samples route real tail release")
        check(s.presentation_pose.tailwhip==s.presentation_trick.targets.tailwhip,"tail geometry matches accepted target")
    end)
    scenario(function()
        local f=fixture();air(f);f.pad.buttons.lb=true;f.pad.buttons.rb=true;f.pad.right_y=-1
        local s=f.tick()
        check(f.actions.movement==24 and s.presentation_trick.targets.movement_id==24,"mapped Suicide retains catalog identity")
        s=f.tick()
        check(s.presentation_trick.targets.release_left_hand>0 and s.presentation_trick.targets.release_right_hand>0,"independent movement hand releases are projected")
        check(s.presentation_trick.targets.barspin_release==0 and s.presentation_trick.targets.tailwhip_release==0,"pose selection does not fabricate spin releases")
    end)
    scenario(function()
        local f=fixture();air(f);f.pad.left_trigger=1;f.pad.right_trigger=1;f.pad.right_y=-1
        local previous
        for _=1,8 do
            local s=f.tick();local t=s.presentation_trick
            check(t and t.targets.movement_id==54,"mapped Crankflip uses real adapter targets")
            check(t.pedal_phase==0 and s.presentation_pose.crank_phase==wrap(t.pedal_phase+t.targets.movement_crank_angle),"movement crank offset is applied once to unchanged coast cadence")
            if previous and math.abs(previous)>1e-12 then check(s.presentation_pose.crank_phase~=wrap(previous+t.targets.movement_crank_angle),"previous trick offset never accumulates") end
            previous=s.presentation_pose.crank_phase
        end
        f.on_result=function(out) out.valid=false;out.issue="constructed refusal" end
        local s=f.tick()
        check(s.presentation_trick==nil and s.presentation_pose.crank_phase==0,"fallback returns to the unoffset accepted crank phase")
    end)
    scenario(function()
        local f=fixture();local s=bar(f);local n=f.adapter_calls;local before=s.presentation_trick
        s=f.observe(nil,f.read)
        check(f.adapter_calls==n and s.presentation_trick==before,"exact duplicate retains its original accepted identity without stepping")
    end)
    for _,field in ipairs({"barspin_release","release_left_foot","movement_crank_angle","movement_id","pose_provenance"}) do
        scenario(function()
            local f=fixture();bar(f)
            f.on_result=function(out) out.visual_targets[field]=field=="pose_provenance" and "measured" or 10001 end
            local before=#f.commands;local s=f.tick()
            check(not s.stop_requested and #f.commands==before+1,"malformed presentation falls back without corrupting force cadence")
            check(s.presentation_trick==nil and s.presentation_pose.barspin==0 and s.model.trick_fallbacks==1,"malformed targets never reach pose")
        end)
    end
    scenario(function()
        local f=fixture();bar(f);local n=#f.commands
        f.on_result=function(out) out.binding.source.packet+=1 end
        local s=f.tick()
        check(s.stop_requested and s.issue=="trick frame mismatch" and #f.commands==n,"changed packet identity stops before effect")
        check(s.presentation_trick==nil and s.presentation_pose.barspin==0,"stale bound targets are removed on stop")
    end)
    scenario(function()
        local f=fixture();bar(f);local n=#f.commands
        f.on_result=function(out) out.fresh=false end
        local s=f.tick()
        check(s.stop_requested and #f.commands==n and s.presentation_trick==nil,"nonfresh producer cannot publish or submit")
    end)
    scenario(function()
        local f=fixture();local before=bar(f);local n=#f.commands;f.hold_inbox=true
        local s=f.tick()
        check(s.backpressure=="native_inbox_queued" and #f.commands==n and s.model_steps==before.model_steps+1,"tricks still observe body chronology while command inbox is held")
        check(s.presentation_trick==nil and s.presentation_pose.barspin==0 and s.model_history.serial==before.model_history.serial,"new uncommanded epoch cannot reuse accepted target")
        f.hold_inbox=false;s=f.tick()
        check(s.presentation_trick and s.presentation_trick.serial==f.serial,"recovered admission projects only the current target")
    end)
    scenario(function()
        local f=fixture();local before=bar(f);local n=#f.commands;f.refusal="force_pipeline_full"
        local s=f.tick()
        check(s.backpressure=="core_receipt_capacity" and #f.commands==n and not s.stop_requested,"submission backpressure keeps existing lifecycle")
        check(s.presentation_trick==nil and s.presentation_pose.barspin==0 and s.model_history.serial==before.model_history.serial,"unaccepted preview cannot publish targets")
    end)
    scenario(function()
        local f=fixture();bar(f);local n=#f.commands;f.refusal="constructed admission denial"
        local s=f.tick()
        check(s.stop_requested and s.presentation_trick==nil and s.presentation_pose.barspin==0 and #f.commands==n,"rejected admission leaves no stale presentation")
    end)
    scenario(function()
        local f=fixture();bar(f)
        local s=f.ride:stop("test completed");local n=f.adapter_calls
        check(s.presentation_trick==nil and s.presentation_pose.barspin==0,"terminal stop removes authored targets")
        s=f.tick();check(f.adapter_calls==n and s.presentation_trick==nil,"terminal observation cannot restart projection")
        local rows=f.ride:trick_log().rows;local ended=rows[#rows]
        check(ended.control=="ended" and ended.seconds==nil and ended.events==nil,"terminal row fabricates no measured landing or score")
    end)
    scenario(function()
        local f=fixture();bar(f);f.on_admission=function() return nil,"constructed unknown" end
        local s=f.tick()
        check(s.stop_requested and s.unknown and s.presentation_trick==nil,"unknown admission publishes no target")
        check(s.presentation_pose.barspin==0,"uncertain command cannot leave old trick geometry")
    end)
    scenario(function()
        local f=fixture();bar(f);local submit=f.api.submit
        function f.api.submit(...)
            local ok,why,id=submit(...);f.ride:stop("cancelled during submission");return ok,why,id
        end
        local s=f.tick()
        check(s.stop_requested and s.presentation_trick==nil and s.presentation_pose.barspin==0,"cancellation during acceptance cannot publish a target")
        check(s.model_history.serial==f.serial,"accepted history remains available for receipt cleanup")
    end)
    scenario(function()
        local f=fixture();bar(f);local adopt=f.force._adopt
        function f.force:_adopt(candidate) adopt(self,candidate);f.ride:stop("cancelled during adoption") end
        local s=f.tick()
        check(s.stop_requested and s.presentation_trick==nil and s.presentation_pose.barspin==0,"cancellation during adoption cannot publish a target")
    end)
    return {cases=cases,assertions=assertions}
end
return table.freeze(Tests)
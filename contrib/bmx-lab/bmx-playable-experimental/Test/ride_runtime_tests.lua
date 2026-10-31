-- Constructed Core/native boundaries; these tests make no lifecycle claim.
local Ride=require("./ride_runtime")
local Qualified=require("./ride_runtime_qualified_fixture")
local Mapping=require("./ride_input_mapping")
local Forces=require("./forces")
local Contact=require("./contact_runtime")
local G=require("./bike_geometry")
local Tests={}
local function copy(v)
    if type(v)~="table" then return v end
    local out={} for k,c in pairs(v) do out[k]=copy(c) end return out
end
local function inc(v)
    local chars,carry={},1
    for i=#v,1,-1 do
        local d=string.byte(v,i)-48+carry
        if d==10 then d,carry=0,1 else carry=0 end
        table.insert(chars,1,string.char(48+d))
    end
    if carry==1 then table.insert(chars,1,"1") end
    return table.concat(chars)
end
local function count(f,name) local n=0 for _,c in ipairs(f.calls) do if c==name then n+=1 end end return n end
local function fixture(options)
    options=options or {}
    local f={body=newproxy(),incarnation=newproxy(),lease=newproxy(),serial="9007199254741001",
        input_serial="9007199254742001",ms="9007199254743001",time=1,now=1,calls={},mode="queued",
        pad={left_x=0,left_y=0,right_x=0,right_y=0,left_trigger=0,right_trigger=0,playstation=false,
            buttons={a=false,b=false,right_stick=false,lb=false,rb=false}}}
    function f.sample()
        return {epoch=newproxy(),serial=f.serial,time=f.time,seconds=Forces.native_seconds,mass=106,
            position=vector.create(0,.9,-.05),velocity=vector.create(0,0,0),angular_velocity=vector.create(0,0,0),
            inertia=vector.create(26,32,10),rotation={0,0,0,1}}
    end
    function f.frame()
        return {input_ok=true,phase="capturing",generation=1,lease_handle=f.lease,
            sample={user=2,sequence="9007199254740993",source_epoch=f.source_epoch or "9007199254740995",
                context_generation="9007199254740997",observation_serial=f.input_serial,observed_ms=f.ms,
                packet=9,pad=copy(f.pad)}}
    end
    function f.advance(n)
        for _=1,n or 1 do f.serial=inc(f.serial);f.time+=Forces.native_seconds end
        f.input_serial=inc(f.input_serial)
        for _=1,17 do f.ms=inc(f.ms) end
        f.now+=17
    end
    function f.new_input()
        f.input_serial=inc(f.input_serial);f.ms=inc(f.ms);f.now+=1
    end
    f.mapping=Mapping.new()
    f.force=Forces.new()
    f.contact={actor_lane_qualified=Contact.actor_lane_qualified}
    function f.contact.decode(frame,plan)
        table.insert(f.calls,"decode");f.last_frame=frame
        local rays={}
        for i=1,2 do
            rays[i]=f.clear and {status="clear"} or {status="hit",position={plan[i].from.x,plan[i].from.y-Forces.wheel_radius,plan[i].from.z},
                normal={0,1,0},surface_velocity={0,0,0},normal_available=true,surface_velocity_available=true,motion="measured"}
        end
        local out={valid=true,binding={body_handle=frame.body_handle,physics_epoch=frame.physics_epoch,lease_handle=frame.source.lease_handle},
            frame={serial=frame.serial,time=frame.time,seconds=frame.seconds,source=copy(frame.source)},rays=rays,
            query={epoch_matches=true,local_actor_excluded=true,owned_bodies_excluded=true,budget_exhausted=false,actor_lane="identity"},
            support={known=false,grounded_known=false},force_ready=false}
        if f.on_decode then f.on_decode(out) end
        return out
    end
    f.tricks={observed={},cancelled=0}
    function f.tricks:step(frame,contact,actions)
        table.insert(f.calls,"trick");table.insert(self.observed,frame.serial)
        assert(actions.physics_epoch==frame.physics_epoch and actions.source.observation_serial==frame.source.observation_serial)
        assert(contact.force_ready==false and contact.support.known==false,"no promotion of ray support")
        assert(frame.owner.command_authority==nil and frame.owner.release_authority==nil,"no fabricated delegation")
        assert(table.isfrozen(frame) and table.isfrozen(frame.body),"immutable model frame")
        local out={valid=true,fresh=true,advanced=true,issue="fixture_observed",requests={rotation_reserved=false},
            binding={body_handle=frame.body_handle,physics_epoch=frame.physics_epoch,lease_handle=frame.source.lease_handle,
                serial=frame.serial,time=frame.time,seconds=frame.seconds,source=copy(frame.source)}}
        if f.on_trick then f.on_trick(out) end
        return out
    end
    function f.tricks:cancel() self.cancelled+=1 end
    -- Fixed constructed backend facts for the selected real decoder lane;
    -- requests never establish exclusions in production code.
    f.category_lane=options.actual_contact and Contact.CATEGORY_WHEEL_LANE_QUALIFIED==true or false
    f.wheel_probes,f.tripwire_probes=0,0
    function f.contact_batch(epoch,rays)
        local batch={status="available",epoch=epoch,native_casts=#rays,budget_exhausted=false,
            local_actor_excluded=not f.category_lane,owned_bodies_excluded=true,rays=rays}
        if f.category_lane then
            batch.requested_query_preset="camera";batch.named_actor_categories_absent=true
        end
        return batch
    end
    f.api={};f.transactions={}
    function f.api.probe_batch(epoch,rays,settings)
        table.insert(f.calls,"probe")
        assert(epoch==f.read.epoch and settings.require_contact==true)
        if f.category_lane then
            assert((#rays==2 or #rays==3) and settings.query_preset=="camera"
                and settings.require_named_actor_categories_absent==true and settings.exclude_local_actor==nil)
        else assert(#rays==2 and settings.exclude_local_actor==true) end
        if #rays==3 then
            f.tripwire_probes+=1
            if f.on_tripwire then return f.on_tripwire(epoch,rays,settings) end
            return f.contact_batch(epoch,{{status="clear"},{status="clear"},{status="clear"}})
        end
        f.wheel_probes+=1
        if f.on_probe then return f.on_probe(epoch,rays,settings) end
        return {status="available",epoch=epoch,rays={},local_actor_excluded=true,owned_bodies_excluded=true}
    end
    function f.api.submit(epoch,command)
        table.insert(f.calls,"submit")
        assert(epoch==f.read.epoch and typeof(command.force)=="vector" and typeof(command.torque)=="vector")
        f.command=command
        if f.on_submit then return f.on_submit() end
        f.sequence=inc(f.sequence or "9007199254744001")
        f.requested,f.requested_time=f.serial,f.time
        f.produced=inc(f.requested)
        f.transactions[f.sequence]={requested=f.requested,requested_time=f.requested_time,produced=f.produced}
        return true,nil,f.sequence
    end
    function f.api.receipt(sequence)
        table.insert(f.calls,"receipt")
        local transaction=f.transactions[sequence]
        assert(transaction or sequence==f.sequence,"original exact sequence")
        if f.on_receipt then return f.on_receipt(sequence) end
        local requested=transaction and transaction.requested or f.requested
        local produced=transaction and transaction.produced or f.produced
        local successor=f.successor
        -- A provided sample may seal older rows while the newest row still
        -- awaits N+2. Single-command malformed-successor cases remain literal.
        local retained=0;for _ in pairs(f.transactions) do retained+=1 end
        if retained>1 and successor and successor.serial==produced then successor=nil end
        return {sequence=f.receipt_sequence or sequence,requested_serial=requested,
            produced_serial=(f.mode=="queued" or f.mode=="rejected" or f.mode=="expired") and "0" or produced,
            outcome=f.mode,force_attempted=f.mode=="applied" or f.mode=="partial",torque_attempted=f.mode=="applied",
            retained=f.retained==true,quarantined=f.quarantined==true,successor=f.mode=="applied" and successor or nil,
            cleanup_disposition=f.cleanup_disposition or "none"}
    end
    function f.api.acknowledge(sequence)
        table.insert(f.calls,"ack");assert(f.transactions[sequence] or sequence==f.sequence)
        if f.on_ack then return f.on_ack() end
        f.transactions[sequence]=nil
        return true
    end
    local models={mapping=f.mapping,force=f.force,contact=options.actual_contact and Contact or f.contact,
        tricks=options.no_tricks and nil or f.tricks}
    if options.models then for k,v in pairs(options.models) do models[k]=v end end
    local ride_options={body_handle=f.body,incarnation=f.incarnation}
    for name,value in pairs(options.ride_options or {}) do ride_options[name]=value end
    f.ride=Qualified.new(f.api,models,ride_options)
    function f.observe(context,raw,source)
        f.read=raw or f.sample()
        return f.ride:observe(source or f.frame(),f.read,context or {now_ms=f.now,focused=true,menu_open=false,loaded=true})
    end
    return f
end
function Tests.run(case_done)
    local cases,assertions=0,0
    local function check(v,why) assertions+=1;assert(v,why) end
    local function next_case()
        -- Yield only after the preceding case's assertions have completed.
        if case_done and cases>0 then case_done(cases,assertions) end
        cases+=1
    end
    next_case() do
        local touches=0
        local api=setmetatable({}, {__index=function() touches+=1;error("native touched") end})
        local r=Ride.new(api)
        check(r:observe(nil,nil,nil).phase=="inert" and touches==0,"default inert observation")
        check(r:drain().force_pending==false and touches==0,"default drain inert")
        check(r.start==nil and r.unload==nil and r.step==nil,"no lifecycle exports")
        check(r:stop("before observe").stop_requested and touches==0,"idle stop pure and terminal")
        check(r:observe(nil,nil,nil).stop_requested and touches==0,"stopped cannot restart")
    end
    next_case() do
        local f=fixture();local s=f.observe()
        check(s.submitted==1 and s.pending_sequence==f.sequence,"single exact u64 receipt")
        check(type(f.sequence)=="string" and #f.sequence>15,"u64 not converted to double")
        check(f.force:consumed_hop_event_id()==0,"neutral accepted history contains no hop")
        check(s.model_steps==1 and #f.tricks.observed==1,"first models observed")
        check(s.body_handle==nil and s.incarnation==nil and s.source==nil,"public report strips private binding")
        check(not pcall(function() s.submitted=7 end),"detached frozen status")
    end
    next_case() do
        local f=fixture();f.observe()
        for _=1,4 do f.advance();f.observe() end
        local s=f.ride:status()
        check(s.model_steps==5 and #f.tricks.observed==5,"queued receipt cannot hide observed samples")
        check(count(f,"submit")==1 and count(f,"probe")==5,"one force packet while every body gets contacts")
        check(s.input_consumed==5,"same snapshot consumed once on each progress")
        f.mode="applied";f.successor=f.sample();f.advance();f.observe()
        check(count(f,"ack")==1 and f.ride:status().acknowledged==1,"later exact successor ACK")
        check(#f.tricks.observed==6 and f.tricks.cancelled==0,"ACK preserves Trick cadence")
        check(f.ride:status().model_history.kind=="predictive_accepted","ACK preserves the accepted predictive history")
        check(count(f,"submit")==2,"current fresh epoch may submit after resolved prior ledger")
    end
    next_case() do
        local f=fixture();f.observe();f.pad.buttons.a=true;f.new_input();local d=f.observe()
        check(d.input_queued==1 and d.input_consumed==1,"new edge staged during duplicate body")
        check(#f.tricks.observed==1 and count(f,"probe")==1,"duplicate never repeats models/query")
        f.pad.buttons.a=false;f.new_input();f.observe();f.advance();local s=f.observe()
        check(s.input_consumed==2 and s.input_queued==2,"one ordered input is consumed per real body epoch")
        f.advance();local next_state=f.observe()
        check(next_state.input_consumed==3 and next_state.input_queued==2,"later release stays queued in native order")
        check(#f.tricks.observed==3 and count(f,"submit")==1,"fresh pending samples progress once each")
    end
    next_case() do
        local f=fixture();f.observe();local s=f.observe()
        check(s.observed_steps==1 and count(f,"submit")==1,"new EpochValue token on duplicate is not new body epoch")
        local changed=f.sample();changed.mass=107;s=f.observe(nil,changed)
        check(s.stop_requested and s.issue=="changed duplicate native sample","changed duplicate stops")
    end
    next_case() do
        local f=fixture();f.observe();f.advance(2);local s=f.observe()
        check(s.stop_requested and #f.tricks.observed==1,"true missing native epoch stops without invented model step")
        check(count(f,"submit")==1,"gap never resubmits")
    end
    next_case() do
        local f=fixture();f.observe();local raw=f.sample();raw.serial="9007199254741000";raw.time=.9
        check(f.observe(nil,raw).stop_requested,"native regression stops")
    end
    next_case() do
        local f=fixture();f.observe();f.source_epoch="9007199254740996";f.advance()
        check(f.observe().stop_requested and count(f,"probe")==1,"exact source replacement stops before query")
    end
    next_case() do
        local f=fixture();f.observe();local s=f.observe({now_ms=2,focused=false,menu_open=false,loaded=true})
        check(s.stop_requested and count(f,"probe")==1,"negative readiness checked even on duplicate")
    end
    next_case() do
        local f=fixture();f.on_probe=function() f.ride:stop("probe reentry");return {} end
        local s=f.observe()
        check(s.stop_requested and count(f,"decode")==0 and count(f,"submit")==0,"probe reentry fences model and force")
    end
    next_case() do
        local f=fixture();f.on_submit=function()
            f.sequence="9007199254744555";f.requested=f.serial;f.produced=inc(f.serial)
            f.ride:stop("submit reentry");return true,nil,f.sequence
        end
        local s=f.observe()
        check(s.stop_requested and s.pending_sequence==f.sequence and s.submitted==1,"late admitted sequence retained after stop")
        f.mode="rejected";f.retained=true;s=f.ride:drain()
        check(not s.force_pending and s.acknowledged==1,"retained allocation does not forbid terminal SDK ACK")
    end
    next_case() do
        local f=fixture();f.on_submit=function() error("possible native admission") end
        local s=f.observe()
        check(s.force_pending and s.unknown and s.pending_sequence==nil,"throwing submit retains unknown debt")
        f.advance();f.observe();f.ride:drain()
        check(count(f,"submit")==1 and count(f,"receipt")==0,"unknown sequence never guessed or repeated")
    end
    next_case() do
        local f=fixture();f.on_submit=function() return false,"Core guard refused" end
        local s=f.observe()
        check(s.stop_requested and not s.force_pending and not s.unknown,"explicit refusal is clean force ledger")
    end
    next_case() do
        local f=fixture();f.observe();f.mode="applied";f.advance();f.observe();f.advance();f.observe()
        check(count(f,"ack")==0 and f.ride:status().force_pending,"applied without successor retains native debt")
        f.now=1001;local s=f.observe()
        check(s.stop_requested and s.force_pending and s.issue=="force receipt watchdog expired","all waiting outcomes bounded")
        f.ride:stop("Core Follow completed");s=f.ride:drain()
        check(s.force_pending and count(f,"ack")==0,"outer terminal cannot manufacture force successor")
    end
    next_case() do
        local f=fixture();f.observe();f.mode="rejected";f.retained=true;f.quarantined=true
        local s=f.ride:drain()
        check(s.stop_requested and not s.force_pending and s.acknowledged==1,"actual terminal ACK governs force cleanup")
        check(s.receipt.retained and s.receipt.quarantined,"raw native allocation flags preserved separately")
    end
    next_case() do
        local f=fixture();f.observe();f.mode="partial";local s=f.ride:drain()
        check(s.unknown and s.force_pending and s.acknowledged==1,"partial write remains unresolved even after positive ACK")
        f.ride:drain();check(count(f,"ack")==1,"partial debt never repeated ACK")
    end
    next_case() do
        local f=fixture();f.observe();f.mode="rejected";f.on_ack=function() error("possible ACK") end
        local s=f.ride:drain();f.ride:drain()
        check(s.unknown and s.force_pending and s.ack_attempted,"uncertain ACK retained")
        check(count(f,"ack")==1,"unknown ACK not retried")
    end
    next_case() do
        local f=fixture();f.observe();f.receipt_sequence="9007199254744999"
        local s=f.ride:drain();check(s.unknown and count(f,"ack")==0,"wrong exact receipt never ACKed")
    end
    next_case() do
        local f=fixture();f.observe();local before=#f.calls;local s=f.ride:stop("Core cancellation")
        check(#f.calls==before and s.force_pending,"stop is a pure latch with retained force duty")
        f.advance();f.observe();check(#f.calls==before,"stopped observe has no capability calls")
        f.mode="expired";s=f.ride:drain()
        check(not s.force_pending and s.acknowledged==1,"cleanup uses original capability after stop")
    end
    next_case() do
        local f=fixture();f.observe()
        for _=1,32 do f.new_input();f.observe() end
        f.new_input();local s=f.observe()
        check(s.stop_requested and s.issue=="selected input staging capacity exceeded","bounded FIFO refuses overflow")
        check(count(f,"submit")==1,"overflow cannot publish again")
    end
    next_case() do
        local f=fixture();f.clear=true
        local s=f.observe();check(s.submitted==1,"paired force kernel accepts truthful sparse clears")
        check(f.command.impulse==nil,"clear cannot fabricate ground hop")
    end
    next_case() do
        local f=fixture({actual_contact=true})
        f.on_probe=function(epoch)
            return f.contact_batch(epoch,{{status="clear"},{status="clear"}})
        end
        local s=f.observe()
        check(s.submitted==1 and f.last_frame==nil,"actual Contact decoder clear joins paired force kernel")
        check(f.wheel_probes==1 and f.tripwire_probes==(f.category_lane and 1 or 0)
            and count(f,"probe")==1+f.tripwire_probes,"selected actor lane retains independent query duties")
    end
    next_case() do
        -- Constructed SDK-shaped facts join actual Contact, Mapping and Forces.
        -- No Trick model is configured and these flags are not native proof.
        local function measured_fixture(change)
            local f=fixture({actual_contact=true,models={tricks=false}})
            local sample=f.sample
            function f.sample()
                local raw=sample();raw.mass=83;raw.velocity=vector.create(.75,0,-.4)
                return raw
            end
            local real_preview=f.force.preview
            function f.force:preview(h,body,wheels,samples,controls,speculative)
                f.preview_calls=(f.preview_calls or 0)+1;f.preview_samples=copy(samples)
                f.preview_body=copy(body)
                local model,candidate=real_preview(self,h,body,wheels,samples,controls,speculative)
                f.preview_result=copy(model)
                return model,candidate
            end
            f.on_probe=function(epoch,plan)
                f.plan=plan
                local batch=f.contact_batch(epoch,{})
                batch.native_casts=2 -- The same two constructed wheel-hit rows below.
                for i=1,2 do
                    local from,to=plan[i].from,plan[i].to
                    batch.rays[i]={status="hit",fraction=Forces.wheel_radius/(from.y-to.y),
                        position=vector.create(from.x,from.y-Forces.wheel_radius,from.z),
                        normal_available=true,normal=vector.create(0,1,0),motion="measured",
                        surface_velocity_available=true,surface_velocity=f.read.velocity}
                end
                if change then change(batch) end
                f.batch=batch
                return batch
            end
            return f
        end
        local f=measured_fixture();local s=f.observe();local model=f.preview_result
        -- InFlight forecasts one interval even with no pending command. Solve
        -- the actual folded hard-contact rows independently of iterative Solver:
        -- current recovery policy supplies a bounded penetration target, while
        -- the kernel's next gravity interval acts on that already falling body.
        local first,second=f.preview_samples[1],f.preview_samples[2]
        local h=f.read.seconds
        local body,t=f.preview_body,Forces.tuning()
        local expected_center={f.read.position.x+f.read.velocity.x*h,
            f.read.position.y+(f.read.velocity.y-9.8*h)*h,
            f.read.position.z+f.read.velocity.z*h}
        check(body.mass==83 and math.abs(body.linear_velocity[2]-(f.read.velocity.y-9.8*h))<1e-12
            and math.abs(body.center_of_mass[1]-expected_center[1])<1e-12
            and math.abs(body.center_of_mass[2]-expected_center[2])<1e-12
            and math.abs(body.center_of_mass[3]-expected_center[3])<1e-12,
            "first command retains the independent one-gravity-interval body forecast")
        local function normal_target(sample)
            local bias=math.min(t.recovery_speed_limit,t.recovery_fraction*math.max(0,-sample.separation)/h)
            return sample.contact.surface_velocity[2]+bias-math.max(0,sample.separation)/h
        end
        local front_z,rear_z=first.contact.point[3]-body.center_of_mass[3],second.contact.point[3]-body.center_of_mass[3]
        local front_target,rear_target=normal_target(first),normal_target(second)
        local expected_spin=(rear_target-front_target)/(front_z-rear_z)
        local expected_vy=front_target+expected_spin*front_z
        local expected_load=83*(9.8+(expected_vy-body.linear_velocity[2])/h)
        local hub_y_sum=first.contact.point[2]+second.contact.point[2]+2*(Forces.wheel_radius-body.center_of_mass[2])
        local expected_vz=-expected_spin*hub_y_sum/(2+83*Forces.wheel_radius^2/.23)
        local expected_force_z,expected_pitch=83*expected_vz/h,26*(expected_spin-body.angular_velocity[1])/h
        check(s.submitted==1 and not s.stop_requested and s.model_steps==1,"actual measured-hit decoder reaches one force submission")
        check(f.wheel_probes==1 and f.tripwire_probes==(f.category_lane and 1 or 0)
            and count(f,"probe")==1+f.tripwire_probes and count(f,"decode")==0 and f.preview_calls==1,
            "one actual wheel decoder/force path plus required tripwire, no substitute decoder")
        check(count(f,"trick")==0,"measured-hit force test grants no Trick support qualification")
        check(model.valid and model.grounded,"actual force kernel accepts both plan-derived measured-hit rows")
        check(math.abs(f.command.force.y-expected_load)<=.002,"co-moving measured gaps carry analytic 83kg normal response")
        check(math.abs(f.command.force.x)<=.0001 and math.abs(f.command.force.z-expected_force_z)<=.0001
            and math.abs(f.command.torque.x-expected_pitch)<=.0001 and math.abs(f.command.torque.y)<=.0001
            and math.abs(f.command.torque.z)<=.0001,"measured gap difference adds only analytic pitch and free-rolling response")
        check(model.normal_load[1]>0 and model.normal_load[2]>0
            and math.abs(model.normal_load[1]+model.normal_load[2]-expected_load)<=.002,"actual Solver normal impulses sum to analytic measured-gap response")
        check(f.command.impulse==nil and not model.hop_applied,"neutral measured-hit path invents no hop")
        for i=1,2 do
            local sample,hit=f.preview_samples[i],f.batch.rays[i]
            local contact=sample.contact
            local axle=i==1 and G.front_axle or G.rear_axle
            local hub={expected_center[1]+axle[1]-G.com[1],expected_center[2]+axle[2]-G.com[2],
                expected_center[3]+axle[3]-G.com[3]}
            local gap=hub[2]-hit.position.y-Forces.wheel_radius
            check(contact.status=="hit" and math.abs(sample.separation-gap)<1e-12
                and sample.verified_plane==false and sample.balance_normal_available==false
                and sample.forecast_geometry_unavailable==false,"rigid forecast keeps authored wheel geometry, not a verified plane "..i)
            check(math.abs(contact.point[1]-hub[1])<1e-12 and math.abs(contact.point[2]-hit.position.y)<1e-12
                and math.abs(contact.point[3]-hub[3])<1e-12,"decoded plane is re-intersected by the independently forecast gravity ray "..i)
            check(contact.normal[1]==0 and contact.normal[2]==1 and contact.normal[3]==0
                and contact.forward[1]==0 and contact.forward[2]==0 and contact.forward[3]==1,"wheel row keeps level normal and projected heading "..i)
            check(contact.surface_velocity[1]==.75 and contact.surface_velocity[2]==0
                and contact.surface_velocity[3]==f.read.velocity.z,"nonzero measured surface velocity survives conversion "..i)
        end
        local variants={
            {"epoch",function(batch) batch.epoch=newproxy() end},
            {"required actor exclusion",function(batch)
                if Contact.CATEGORY_WHEEL_LANE_QUALIFIED then batch.named_actor_categories_absent=false
                else batch.local_actor_excluded=false end
            end},
            {"owned body exclusion",function(batch) batch.owned_bodies_excluded=false end},
            {"missing normal",function(batch) batch.rays[2].normal_available=false;batch.rays[2].normal=nil end},
            {"missing surface velocity",function(batch)
                batch.rays[2].surface_velocity_available=false;batch.rays[2].surface_velocity=nil;batch.rays[2].motion="unknown"
            end},
            {"inconsistent measured motion",function(batch) batch.rays[2].motion="unknown" end},
            {"off-ray hit",function(batch)
                local p=batch.rays[2].position;batch.rays[2].position=vector.create(p.x+.1,p.y,p.z)
            end},
            {"whole-batch refusal",function(batch)
                batch.status="unavailable";batch.reason="local_actor_exclusion_unavailable";batch.native_casts=0
                batch.local_actor_excluded=false;batch.owned_bodies_excluded=false
                if batch.named_actor_categories_absent~=nil then batch.named_actor_categories_absent=false end
                batch.rays={{status="unavailable"},{status="unavailable"}}
            end},
        }
        for _,variant in ipairs(variants) do
            next_case()
            local rejected=measured_fixture(variant[2]);local state=rejected.observe()
            check(state.stop_requested and state.submitted==0,variant[1].." refuses before force admission")
            check(rejected.preview_calls==nil and rejected.command==nil,variant[1].." never reaches actual force preview")
            check(count(rejected,"probe")==1 and count(rejected,"decode")==0,variant[1].." does not retry or substitute the decoder")
            check(count(rejected,"trick")==0,variant[1].." grants no companion support authority")
        end
    end
    if Contact.CATEGORY_WHEEL_LANE_QUALIFIED then
        next_case() do
            local f=fixture({actual_contact=true,models={tricks=false}})
            f.on_probe=function(epoch)
                return f.contact_batch(epoch,{{status="clear"},{status="clear"}})
            end
            f.on_tripwire=function(epoch,plan)
                local a,b=plan[1].from,plan[1].to
                return f.contact_batch(epoch,{{status="hit",fraction=.5,
                    position=vector.create((a.x+b.x)/2,(a.y+b.y)/2,(a.z+b.z)/2),
                    normal_available=true,normal=vector.create(-1,0,0),motion="measured",
                    surface_velocity_available=true,surface_velocity=vector.create(0,0,0)},
                    {status="clear"},{status="clear"}})
            end
            local state=f.observe()
            check(state.stop_requested and state.submitted==0 and f.command==nil,
                "actual category tripwire hit refuses before force admission")
            check(f.wheel_probes==1 and f.tripwire_probes==1 and count(f,"probe")==2 and count(f,"decode")==0,
                "tripwire uses actual decoder once without retry or substitute")
        end
    end
    next_case() do
        local f=fixture({actual_contact=true})
        f.on_probe=function(epoch) return {status="unavailable",reason="actor exclusion unavailable",epoch=epoch} end
        local s=f.observe()
        check(s.stop_requested and s.submitted==0,"actor exclusion unavailable never retries unsafe query")
        check(count(f,"probe")==1,"one query maximum per observed epoch")
    end
    next_case() do
        local f=fixture();f.on_trick=function(out) out.binding.source.observation_serial="1" end
        check(f.observe().stop_requested and count(f,"submit")==0,"private Trick observation binding exact")
    end
    next_case() do
        local f=fixture();f.on_ack=function() f.ride:drain();return true end
        f.observe();f.mode="rejected";local s=f.ride:drain()
        check(s.stop_requested and not s.force_pending and s.acknowledged==1,"reentrant drain cannot duplicate exact ACK")
        check(count(f,"ack")==1,"ACK reserved before callback")
    end
    next_case() do
        local f=fixture();f.on_receipt=function() error("receipt unknown") end
        f.observe();local s=f.ride:drain();f.ride:drain()
        check(s.force_pending and s.unknown and count(f,"ack")==0,"throwing receipt retained without ACK")
        check(count(f,"receipt")==1,"unknown receipt not replayed")
    end
    next_case() do
        local f=fixture();f.on_submit=function() return true,"wrong arity" end
        local s=f.observe()
        check(s.force_pending and s.unknown,"malformed admission retained")
    end
    next_case() do
        local f=fixture();f.observe();f.mode="applied";f.advance(2)
        f.successor=f.sample();f.successor.time+=.001
        local s=f.ride:drain()
        check(s.force_pending and s.unknown and count(f,"ack")==0,"incoherent successor never ACKed")
    end
    next_case() do
        local f=fixture();f.observe();f.on_decode=function(out) out.binding.physics_epoch=newproxy() end
        f.advance();local s=f.observe()
        check(s.stop_requested and count(f,"submit")==1,"same-read query token cannot be replaced")
    end
    next_case() do
        local f=fixture();local raw=f.sample();raw.seconds=.02
        check(f.observe(nil,raw).stop_requested and count(f,"probe")==0,"wall interval never substitutes native fixed step")
    end
    next_case() do
        local f=fixture();local source=f.frame();source.sample.pad.extra={}
        check(f.observe(nil,nil,source).stop_requested and count(f,"probe")==0,"unknown pad fields refused before staging")
    end
    next_case() do
        local f=fixture();f.observe();f.pad.buttons.a=true
        check(f.observe().stop_requested,"same input ordinal with changed payload refused")
    end
    next_case() do
        local f=fixture();f.observe();f.new_input();f.observe()
        for _=1,101 do f.ms=inc(f.ms) end
        f.input_serial=inc(f.input_serial)
        check(f.observe().stop_requested and count(f,"submit")==1,"input staging duration bound enforced")
    end
    next_case() do
        local f=fixture();f.observe();local raw=f.sample();raw.rotation={0,0,0,0}
        check(f.observe(nil,raw).stop_requested,"invalid measured rotation refused")
    end
    next_case() do
        local f=fixture();f.observe()
        f.on_receipt=function()
            return {sequence=f.sequence,requested_serial=f.requested,produced_serial=f.produced,
                outcome="partial",force_attempted=true,torque_attempted=true,retained=true,quarantined=false,cleanup_disposition="none"}
        end
        local s=f.ride:drain()
        check(s.receipt and s.receipt.outcome=="partial" and s.acknowledged==1,"both-attempted partial is real native terminal shape")
        check(s.force_pending and s.unknown,"partial debt retained after actual terminal ACK")
    end
    next_case() do
        local f=fixture();f.observe();local ordinal,ms=f.input_serial,f.ms
        f.advance();f.input_serial,f.ms=ordinal,ms;f.clear=true
        local s=f.observe()
        check(not s.stop_requested and s.model_steps==2 and #f.tricks.observed==2,"held-only ground projection continues the next constructed body model step")
        check(s.force_pending and s.pending_sequence==f.sequence and count(f,"submit")==1 and s.input_staged==1 and s.input_consumed==1,"same pending command and input accounting without another submission or source observation")
    end
    next_case() do
        local f=fixture();f.observe();f.advance(2);f.mode="applied";f.successor=f.sample()
        f.successor.velocity=vector.create(51,0,0)
        local s=f.ride:drain()
        check(s.acknowledged==1 and not s.force_pending,"native coherent successor above drive speed cleans exact ACK")
        check(s.stop_requested and not s.unknown,"drive refusal stays separate from force cleanup")
    end
    next_case() do
        local f=fixture();f.observe();f.ride:stop("pure local Core cancellation")
        f.advance(65);f.mode="applied";f.successor=f.sample()
        local s=f.ride:drain();f.ride:drain()
        check(s.acknowledged==1 and not s.force_pending,"coherent N+65 cleanup is independent of drive gap limit")
        check(count(f,"ack")==1,"late receipt acknowledged once after pure stop")
        check(s.model_steps==1 and #f.tricks.observed==1,"late cleanup cannot fill missing model steps")
    end
    next_case() do
        local f=fixture();f.observe();f.advance();f.mode="applied";f.successor=f.sample()
        local s=f.ride:drain()
        check(s.force_pending and s.unknown,"N+1 setter sample is not later consumption evidence")
        check(count(f,"ack")==0,"no early ACK of produced epoch")
    end
    if case_done then case_done(cases,assertions) end
    return {cases=cases,assertions=assertions}
end
Tests.fixture=fixture
return Tests

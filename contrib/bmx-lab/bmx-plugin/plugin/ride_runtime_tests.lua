-- Constructed Core/native boundaries; these tests make no lifecycle claim.
local Ride=require("./ride_runtime")
local Qualified=require("./ride_runtime_qualified_fixture")
local Mapping=require("./ride_input_mapping")
local Forces=require("./forces")
local Contact=require("./contact_runtime")
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
    f.contact={}
    function f.contact.decode(frame,plan)
        table.insert(f.calls,"decode");f.last_frame=frame
        local rays={}
        for i=1,2 do
            rays[i]=f.clear and {status="clear"} or {status="hit",position={plan[i].from.x,plan[i].from.y-Forces.wheel_radius,plan[i].from.z},
                normal={0,1,0},surface_velocity={0,0,0},normal_available=true,surface_velocity_available=true,motion="measured"}
        end
        local out={valid=true,binding={body_handle=frame.body_handle,physics_epoch=frame.physics_epoch,lease_handle=frame.source.lease_handle},
            frame={serial=frame.serial,time=frame.time,seconds=frame.seconds,source=copy(frame.source)},rays=rays,
            query={epoch_matches=true,local_actor_excluded=true,owned_bodies_excluded=true,budget_exhausted=false},
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
    f.api={}
    function f.api.probe_batch(epoch,rays,settings)
        table.insert(f.calls,"probe")
        assert(epoch==f.read.epoch and #rays==2 and settings.require_contact and settings.exclude_local_actor)
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
        return true,nil,f.sequence
    end
    function f.api.receipt(sequence)
        table.insert(f.calls,"receipt");assert(sequence==f.sequence,"original exact sequence")
        if f.on_receipt then return f.on_receipt() end
        return {sequence=f.receipt_sequence or f.sequence,requested_serial=f.requested,
            produced_serial=(f.mode=="queued" or f.mode=="rejected" or f.mode=="expired") and "0" or f.produced,
            outcome=f.mode,force_attempted=f.mode=="applied" or f.mode=="partial",torque_attempted=f.mode=="applied",
            retained=f.retained==true,quarantined=f.quarantined==true,successor=f.mode=="applied" and f.successor or nil}
    end
    function f.api.acknowledge(sequence)
        table.insert(f.calls,"ack");assert(sequence==f.sequence)
        if f.on_ack then return f.on_ack() end
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
function Tests.run()
    local cases,assertions=0,0
    local function check(v,why) assertions+=1;assert(v,why) end
    cases+=1 do
        local touches=0
        local api=setmetatable({}, {__index=function() touches+=1;error("native touched") end})
        local r=Ride.new(api)
        check(r:observe(nil,nil,nil).phase=="inert" and touches==0,"default inert observation")
        check(r:drain().force_pending==false and touches==0,"default drain inert")
        check(r.start==nil and r.unload==nil and r.step==nil,"no lifecycle exports")
        check(r:stop("before observe").stop_requested and touches==0,"idle stop pure and terminal")
        check(r:observe(nil,nil,nil).stop_requested and touches==0,"stopped cannot restart")
    end
    cases+=1 do
        local f=fixture();local s=f.observe()
        check(s.submitted==1 and s.pending_sequence==f.sequence,"single exact u64 receipt")
        check(type(f.sequence)=="string" and #f.sequence>15,"u64 not converted to double")
        check(f.force:consumed_hop_event_id()==0,"preview not adopted")
        check(s.model_steps==1 and #f.tricks.observed==1,"first models observed")
        check(s.body_handle==nil and s.incarnation==nil and s.source==nil,"public report strips private binding")
        check(not pcall(function() s.submitted=7 end),"detached frozen status")
    end
    cases+=1 do
        local f=fixture();f.observe()
        for _=1,4 do f.advance();f.observe() end
        local s=f.ride:status()
        check(s.model_steps==5 and #f.tricks.observed==5,"queued receipt cannot hide observed samples")
        check(count(f,"submit")==1 and count(f,"probe")==5,"one force packet while every body gets contacts")
        check(s.input_consumed==5,"same snapshot consumed once on each progress")
        f.mode="applied";f.successor=f.sample();f.advance();f.observe()
        check(count(f,"ack")==1 and f.ride:status().acknowledged==1,"later exact successor ACK")
        check(#f.tricks.observed==6 and f.tricks.cancelled==0,"ACK preserves Trick cadence")
        check(f.ride:status().model_history.kind=="force_reset","only force history reset")
        check(count(f,"submit")==2,"current fresh epoch may submit after resolved prior ledger")
    end
    cases+=1 do
        local f=fixture();f.observe();f.pad.buttons.a=true;f.new_input();local d=f.observe()
        check(d.input_queued==1 and d.input_consumed==1,"new edge staged during duplicate body")
        check(#f.tricks.observed==1 and count(f,"probe")==1,"duplicate never repeats models/query")
        f.pad.buttons.a=false;f.new_input();f.observe();f.advance();local s=f.observe()
        check(s.input_consumed==2 and s.input_queued==2,"one ordered input is consumed per real body epoch")
        f.advance();local next_state=f.observe()
        check(next_state.input_consumed==3 and next_state.input_queued==2,"later release stays queued in native order")
        check(#f.tricks.observed==3 and count(f,"submit")==1,"fresh pending samples progress once each")
    end
    cases+=1 do
        local f=fixture();f.observe();local s=f.observe()
        check(s.observed_steps==1 and count(f,"submit")==1,"new EpochValue token on duplicate is not new body epoch")
        local changed=f.sample();changed.mass=107;s=f.observe(nil,changed)
        check(s.stop_requested and s.issue=="changed duplicate native sample","changed duplicate stops")
    end
    cases+=1 do
        local f=fixture();f.observe();f.advance(2);local s=f.observe()
        check(s.stop_requested and #f.tricks.observed==1,"true missing native epoch stops without invented model step")
        check(count(f,"submit")==1,"gap never resubmits")
    end
    cases+=1 do
        local f=fixture();f.observe();local raw=f.sample();raw.serial="9007199254741000";raw.time=.9
        check(f.observe(nil,raw).stop_requested,"native regression stops")
    end
    cases+=1 do
        local f=fixture();f.observe();f.source_epoch="9007199254740996";f.advance()
        check(f.observe().stop_requested and count(f,"probe")==1,"exact source replacement stops before query")
    end
    cases+=1 do
        local f=fixture();f.observe();local s=f.observe({now_ms=2,focused=false,menu_open=false,loaded=true})
        check(s.stop_requested and count(f,"probe")==1,"negative readiness checked even on duplicate")
    end
    cases+=1 do
        local f=fixture();f.on_probe=function() f.ride:stop("probe reentry");return {} end
        local s=f.observe()
        check(s.stop_requested and count(f,"decode")==0 and count(f,"submit")==0,"probe reentry fences model and force")
    end
    cases+=1 do
        local f=fixture();f.on_submit=function()
            f.sequence="9007199254744555";f.requested=f.serial;f.produced=inc(f.serial)
            f.ride:stop("submit reentry");return true,nil,f.sequence
        end
        local s=f.observe()
        check(s.stop_requested and s.pending_sequence==f.sequence and s.submitted==1,"late admitted sequence retained after stop")
        f.mode="rejected";f.retained=true;s=f.ride:drain()
        check(not s.force_pending and s.acknowledged==1,"retained allocation does not forbid terminal SDK ACK")
    end
    cases+=1 do
        local f=fixture();f.on_submit=function() error("possible native admission") end
        local s=f.observe()
        check(s.force_pending and s.unknown and s.pending_sequence==nil,"throwing submit retains unknown debt")
        f.advance();f.observe();f.ride:drain()
        check(count(f,"submit")==1 and count(f,"receipt")==0,"unknown sequence never guessed or repeated")
    end
    cases+=1 do
        local f=fixture();f.on_submit=function() return false,"Core guard refused" end
        local s=f.observe()
        check(s.stop_requested and not s.force_pending and not s.unknown,"explicit refusal is clean force ledger")
    end
    cases+=1 do
        local f=fixture();f.observe();f.mode="applied";f.advance();f.observe();f.advance();f.observe()
        check(count(f,"ack")==0 and f.ride:status().force_pending,"applied without successor retains native debt")
        f.now=1001;local s=f.observe()
        check(s.stop_requested and s.force_pending and s.issue=="force receipt watchdog expired","all waiting outcomes bounded")
        f.ride:stop("Core Follow completed");s=f.ride:drain()
        check(s.force_pending and count(f,"ack")==0,"outer terminal cannot manufacture force successor")
    end
    cases+=1 do
        local f=fixture();f.observe();f.mode="rejected";f.retained=true;f.quarantined=true
        local s=f.ride:drain()
        check(s.stop_requested and not s.force_pending and s.acknowledged==1,"actual terminal ACK governs force cleanup")
        check(s.receipt.retained and s.receipt.quarantined,"raw native allocation flags preserved separately")
    end
    cases+=1 do
        local f=fixture();f.observe();f.mode="partial";local s=f.ride:drain()
        check(s.unknown and s.force_pending and s.acknowledged==1,"partial write remains unresolved even after positive ACK")
        f.ride:drain();check(count(f,"ack")==1,"partial debt never repeated ACK")
    end
    cases+=1 do
        local f=fixture();f.observe();f.mode="rejected";f.on_ack=function() error("possible ACK") end
        local s=f.ride:drain();f.ride:drain()
        check(s.unknown and s.force_pending and s.ack_attempted,"uncertain ACK retained")
        check(count(f,"ack")==1,"unknown ACK not retried")
    end
    cases+=1 do
        local f=fixture();f.observe();f.receipt_sequence="9007199254744999"
        local s=f.ride:drain();check(s.unknown and count(f,"ack")==0,"wrong exact receipt never ACKed")
    end
    cases+=1 do
        local f=fixture();f.observe();local before=#f.calls;local s=f.ride:stop("Core cancellation")
        check(#f.calls==before and s.force_pending,"stop is a pure latch with retained force duty")
        f.advance();f.observe();check(#f.calls==before,"stopped observe has no capability calls")
        f.mode="expired";s=f.ride:drain()
        check(not s.force_pending and s.acknowledged==1,"cleanup uses original capability after stop")
    end
    cases+=1 do
        local f=fixture();f.observe()
        for _=1,32 do f.new_input();f.observe() end
        f.new_input();local s=f.observe()
        check(s.stop_requested and s.issue=="selected input staging capacity exceeded","bounded FIFO refuses overflow")
        check(count(f,"submit")==1,"overflow cannot publish again")
    end
    cases+=1 do
        local f=fixture();f.clear=true
        local s=f.observe();check(s.submitted==1,"paired force kernel accepts truthful sparse clears")
        check(f.command.impulse==nil,"clear cannot fabricate ground hop")
    end
    cases+=1 do
        local f=fixture({actual_contact=true})
        f.on_probe=function(epoch)
            return {status="available",epoch=epoch,native_casts=2,budget_exhausted=false,
                local_actor_excluded=true,owned_bodies_excluded=true,rays={{status="clear"},{status="clear"}}}
        end
        local s=f.observe()
        check(s.submitted==1 and f.last_frame==nil,"actual Contact decoder clear joins paired force kernel")
    end
    cases+=1 do
        local f=fixture({actual_contact=true})
        f.on_probe=function(epoch) return {status="unavailable",reason="actor exclusion unavailable",epoch=epoch} end
        local s=f.observe()
        check(s.stop_requested and s.submitted==0,"actor exclusion unavailable never retries unsafe query")
        check(count(f,"probe")==1,"one query maximum per observed epoch")
    end
    cases+=1 do
        local f=fixture();f.on_trick=function(out) out.binding.source.observation_serial="1" end
        check(f.observe().stop_requested and count(f,"submit")==0,"private Trick observation binding exact")
    end
    cases+=1 do
        local f=fixture();f.on_ack=function() f.ride:drain();return true end
        f.observe();f.mode="rejected";local s=f.ride:drain()
        check(s.stop_requested and not s.force_pending and s.acknowledged==1,"reentrant drain cannot duplicate exact ACK")
        check(count(f,"ack")==1,"ACK reserved before callback")
    end
    cases+=1 do
        local f=fixture();f.on_receipt=function() error("receipt unknown") end
        f.observe();local s=f.ride:drain();f.ride:drain()
        check(s.force_pending and s.unknown and count(f,"ack")==0,"throwing receipt retained without ACK")
        check(count(f,"receipt")==1,"unknown receipt not replayed")
    end
    cases+=1 do
        local f=fixture();f.on_submit=function() return true,"wrong arity" end
        local s=f.observe()
        check(s.force_pending and s.unknown,"malformed admission retained")
    end
    cases+=1 do
        local f=fixture();f.observe();f.mode="applied";f.advance(2)
        f.successor=f.sample();f.successor.time+=.001
        local s=f.ride:drain()
        check(s.force_pending and s.unknown and count(f,"ack")==0,"incoherent successor never ACKed")
    end
    cases+=1 do
        local f=fixture();f.observe();f.on_decode=function(out) out.binding.physics_epoch=newproxy() end
        f.advance();local s=f.observe()
        check(s.stop_requested and count(f,"submit")==1,"same-read query token cannot be replaced")
    end
    cases+=1 do
        local f=fixture();local raw=f.sample();raw.seconds=.02
        check(f.observe(nil,raw).stop_requested and count(f,"probe")==0,"wall interval never substitutes native fixed step")
    end
    cases+=1 do
        local f=fixture();local source=f.frame();source.sample.pad.extra={}
        check(f.observe(nil,nil,source).stop_requested and count(f,"probe")==0,"unknown pad fields refused before staging")
    end
    cases+=1 do
        local f=fixture();f.observe();f.pad.buttons.a=true
        check(f.observe().stop_requested,"same input ordinal with changed payload refused")
    end
    cases+=1 do
        local f=fixture();f.observe();f.new_input();f.observe()
        for _=1,101 do f.ms=inc(f.ms) end
        f.input_serial=inc(f.input_serial)
        check(f.observe().stop_requested and count(f,"submit")==1,"input staging duration bound enforced")
    end
    cases+=1 do
        local f=fixture();f.observe();local raw=f.sample();raw.rotation={0,0,0,0}
        check(f.observe(nil,raw).stop_requested,"invalid measured rotation refused")
    end
    cases+=1 do
        local f=fixture();f.observe()
        f.on_receipt=function()
            return {sequence=f.sequence,requested_serial=f.requested,produced_serial=f.produced,
                outcome="partial",force_attempted=true,torque_attempted=true,retained=true,quarantined=false}
        end
        local s=f.ride:drain()
        check(s.receipt and s.receipt.outcome=="partial" and s.acknowledged==1,"both-attempted partial is real native terminal shape")
        check(s.force_pending and s.unknown,"partial debt retained after actual terminal ACK")
    end
    cases+=1 do
        local f=fixture();f.observe();local ordinal,ms=f.input_serial,f.ms
        f.advance();f.input_serial,f.ms=ordinal,ms;f.clear=true
        local s=f.observe()
        check(s.stop_requested and s.issue=="non-initial model cadence unavailable","unchanged input plus ground change cannot silently skip Trick epoch")
        check(#f.tricks.observed==1,"no invented action snapshot or extra model dt")
    end
    cases+=1 do
        local f=fixture();f.observe();f.advance(2);f.mode="applied";f.successor=f.sample()
        f.successor.velocity=vector.create(51,0,0)
        local s=f.ride:drain()
        check(s.acknowledged==1 and not s.force_pending,"native coherent successor above drive speed cleans exact ACK")
        check(s.stop_requested and not s.unknown,"drive refusal stays separate from force cleanup")
    end
    cases+=1 do
        local f=fixture();f.observe();f.ride:stop("pure local Core cancellation")
        f.advance(65);f.mode="applied";f.successor=f.sample()
        local s=f.ride:drain();f.ride:drain()
        check(s.acknowledged==1 and not s.force_pending,"coherent N+65 cleanup is independent of drive gap limit")
        check(count(f,"ack")==1,"late receipt acknowledged once after pure stop")
        check(s.model_steps==1 and #f.tricks.observed==1,"late cleanup cannot fill missing model steps")
    end
    cases+=1 do
        local f=fixture();f.observe();f.advance();f.mode="applied";f.successor=f.sample()
        local s=f.ride:drain()
        check(s.force_pending and s.unknown,"N+1 setter sample is not later consumption evidence")
        check(count(f,"ack")==0,"no early ACK of produced epoch")
    end
    return {cases=cases,assertions=assertions}
end
Tests.fixture=fixture
return Tests

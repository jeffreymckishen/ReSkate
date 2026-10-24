-- Constructed provider records exercise the real Lua lifecycle gate. These
-- fixtures are not body/follow/support authority and never submit native work.
-- No code below executes on require; main owns any future test invocation.
local RideInput = require("./ride_input")
local Mapping = require("./ride_input_mapping")
local Tests = {}
local H = .01666666567325592
local function copy(value)
    if type(value)~="table"then return value end
    local out={}for key,child in pairs(value)do out[key]=copy(child)end return out
end
local function increment(value)
    local out,carry={},1
    for at=#value,1,-1 do
        local n=string.byte(value,at)-48+carry
        if n==10 then n,carry=0,1 else carry=0 end
        table.insert(out,1,string.char(48+n))
    end
    if carry==1 then table.insert(out,1,"1")end
    return table.concat(out)
end
local function pad(buttons)
    local result={left_x=0,left_y=0,right_x=0,right_y=0,left_trigger=0,right_trigger=0,playstation=false,
        buttons={up=false,down=false,left=false,right=false,start=false,back=false,left_stick=false,
            right_stick=false,a=false,b=false,x=false,y=false,lb=false,rb=false}}
    for key,value in pairs(buttons or{})do result.buttons[key]=value end
    return result
end
local function fixture()
    local f={constructed=true,native_authority=false,body=newproxy(),session="fixture-session-17",
        follow="fixture-follow-4",context="fixture-context-9",serial="9007199254740995",time=40,now=1000.25,
        input_serial="9007199254741001",input_ms="9007199254742000",input_generation=1,lease=newproxy(),
        input_sequence="9007199254740995",
        source_new=true,source_ready=true,source_clean=false,source_stopped=false,source_armed=false,
        calls={},stop_calls=0,force_calls=0,input_pad=pad(),mapping=Mapping.new()}
    local function log(name,...)table.insert(f.calls,{name=name,args={...}})end
    function f.count(name)
        local total=0
        for _,call in ipairs(f.calls)do if call.name==name then total+=1 end end
        return total
    end
    function f.publish(buttons,equal_ms)
        f.input_serial=increment(f.input_serial)
        if not equal_ms then f.input_ms=increment(f.input_ms)end
        f.input_pad=pad(buttons);f.source_new=true
    end
    f.source={}
    function f.source:arm(user,now)
        log("source.arm",user,now)
        if f.source_stopped and not f.source_clean then return false,"fixture cleanup pending"end
        if f.source_armed then
            f.lease=newproxy();f.input_sequence=increment(f.input_sequence);f.input_generation+=1
        end
        f.source_stopped,f.source_armed,f.source_clean=false,true,false
        return true
    end
    function f.source:step(now,gates)
        log("source.step",now,gates)
        local allowed=f.source_armed and f.source_ready and not f.source_stopped and
            type(gates)=="table"and gates.allow_drive==true
        local out={input_ok=allowed,phase=f.source_stopped and (f.source_clean and "complete"or"draining")or"capturing",
            reason="constructed provider",new_observation=f.source_new,generation=f.input_generation,
            lease_handle=not f.source_clean and f.lease or nil,cleanup_pending=f.source_stopped and not f.source_clean,
            lease_state={status="active"},capture_state={phase="capturing",quarantined=false},
            cleanup_unknown=false,sample={pad=copy(f.input_pad),user=2,sequence=f.input_sequence,
                source_epoch="9007199254741009",context_generation="9007199254741011",
                observation_serial=f.input_serial,observed_ms=f.input_ms,packet=23}}
        f.source_new=false
        return out
    end
    function f.source:stop(reason)
        log("source.stop",reason)
        f.source_stopped=true;f.input_generation+=1
        return self:status()
    end
    function f.source:unload()log("source.unload");return self:stop("fixture unload")end
    function f.source:status()
        if not f.source_armed and not f.source_stopped then
            return{input_ok=false,new_observation=false,generation=f.input_generation,phase="idle",
                cleanup_pending=false,cleanup_unknown=false,lease_handle=nil}
        end
        return {input_ok=false,new_observation=false,generation=f.input_generation,
            phase=f.source_stopped and (f.source_clean and "complete"or"draining")or"capturing",
            cleanup_pending=f.source_stopped and not f.source_clean,cleanup_unknown=false,
            lease_handle=not f.source_clean and f.lease or nil}
    end
    f.record={available=true,body=f.body,session=f.session,follow=f.follow,context=f.context,
        body_current=true,follow_current=true,context_current=true,support_available=true,
        focused=true,menu_open=false,grounded=true,fall_stop=false,rotation_reserved=false}
    f.request={available=true,requested=true,fixture_only=true}
    f.owner={}
    function f.owner.read(body,sample)
        log("owner.read",body,sample)
        return f.record
    end
    function f.owner.request_stop(reason,body,sample)
        log("owner.request_stop",reason,body,sample);f.stop_calls+=1
        if f.on_stop then f.on_stop(reason,body,sample)end
        return f.request
    end
    function f.owner.stop_state()log("owner.stop_state");return f.stop_outcome end
    f.input=RideInput.new(f.source,f.mapping,f.owner)
    function f.sample()
        return {epoch=newproxy(),serial=f.serial,time=f.time,seconds=H,mass=106,
            position=vector.create(0,.9,0),velocity=vector.create(0,0,0),angular_velocity=vector.create(0,0,0),
            inertia=vector.create(26,32,10),rotation={0,0,0,1}}
    end
    function f.step(advance,change)
        if advance then f.serial=increment(f.serial);f.time+=H end
        f.now+=16.125 -- Real reskate.time.now is fractional; never a physics h.
        local sample=f.sample()
        if change then change(sample)end
        f.last_sample=sample
        f.last=f.input:step(f.body,sample,f.now)
        return f.last
    end
    function f.ready()
        assert(f.input:arm(2,f.now))
        local anchor=f.step(false)
        f.publish()
        return anchor,f.step(true)
    end
    -- This spy is an integration consumer, not a model/native implementation.
    -- A false gate must stop calls, even if disabled controls could create force.
    function f.consume(out)
        local current=f.input:status()
        -- Local equality is only stale-permit protection. It cannot turn this
        -- constructed provider or a historical frame into native authority.
        if out.submit_forces==true and out.lifecycle_token==current.lifecycle_token and
            out.permit_token==current.permit_token and out.body==current.body and out.session==current.session then
            assert(out.physics_epoch==f.last_sample.epoch,"permit must forward current real-shaped body read epoch")
            f.force_calls+=1
            return true
        end
        return false
    end
    return f
end

function Tests.run()
    local cases,assertions=0,0
    local function check(value,why)assertions+=1 assert(value,why)end
    local function refused(out,why)
        check(type(out)=="table"and out.submit_forces==false,why)
        check(out.force_controls==nil,"refusal does not masquerade as disabled-only force controls")
    end
    do
        cases+=1
        local f=fixture()
        local independent=fixture()
        check(f.input~=independent.input,"successive constructors create independent orchestrator instances")
        for _,object in ipairs({f.input,independent.input})do
            check(table.isfrozen(object),"orchestrator instances are frozen after construction")
            check(getmetatable(object)=="locked","orchestrator instance metatable remains protected")
            check(not pcall(function()rawset(object,"fixture_mutation",true)end),"rawset cannot mutate a constructed orchestrator")
            check(not pcall(function()setmetatable(object,{})end),"orchestrator instance metatable cannot be replaced")
        end
        check(#f.calls==0 and #independent.calls==0,"both independent orchestrator constructions leave every provider untouched")
        local anchor,ready=f.ready()
        refused(anchor,"first body measurement anchors without force")
        check(ready.submit_forces==true and ready.physics_epoch==f.last_sample.epoch,"exact native successor receives current body epoch")
        check(ready.mapping_error==nil,"successful mapping reset does not manufacture a callback error")
        check(ready.force_controls.enabled==true,"valid qualified controls are explicit")
        check(type(ready.lifecycle_token)=="table"and type(ready.permit_token)=="table"and
            not pcall(function()ready.permit_token.mutated=true end)and
            not pcall(function()ready.lifecycle_token.mutated=true end),"permit tokens are immutable local identities")
        check(f.input:status().submit_forces==false,"current status is diagnostic, never another permit")
        check(ready.owner_record==f.record and ready.owner_facts.body==f.body,"original provider record and normalized binding preserved")
        f.consume(ready);check(f.force_calls==1,"consumer sees only an advancing qualified body permit")
        f.publish();f.input_pad.left_y=-.8
        local pump=f.step(true)
        check(pump.submit_forces and pump.force_controls.ground_pump<0,
            "valid negative front-weight pump input remains signed through wrapper validation")
        check(not f.consume(ready),"a later body step invalidates an older cached submit=true frame")
    end
    do
        cases+=1
        local f=fixture();f.ready()
        local cached=f.last
        local previous=f.last_sample.epoch
        f.publish({right_stick=true},true)
        local press=f.step(false);refused(press,"fresh R3 on repeated body only stages input")
        check(press.permit_token~=cached.permit_token,"duplicate body step explicitly rotates the permit token")
        check(not f.consume(cached),"duplicate body step rotates the local permit before staged input callbacks")
        check(f.last_sample.epoch~=previous,"fixture reread minted a distinct opaque body epoch")
        f.publish({},true)
        local release=f.step(false);refused(release,"same-ms released R3 on repeated body only stages input")
        local next=f.step(true)
        check(next.submit_forces and next.force_controls.hop_event_id==1 and next.force_controls.hop_strength==1,
            "interstitial ordered press/release survives until the actual body successor")
        check(next.force_controls.pump_inhibited,"pending interstitial hop blocks pump after R3 releases")
        local id=next.force_controls.hop_event_id
        check(f.input:retire_hop(id,"accepted"),"orchestrator delegates exact local owner retirement")
        f.publish();local retired=f.step(true)
        check(retired.submit_forces and retired.force_controls.hop_event_id==0,"retired hop never repeats on a later physics step")
    end
    local missing={"available","body","session","follow","context","body_current","follow_current","context_current",
        "support_available","focused","menu_open","grounded","fall_stop","rotation_reserved"}
    for _,field in ipairs(missing)do
        cases+=1
        local f=fixture();f.ready();f.record[field]=nil
        local bad=f.step(true);refused(bad,"missing genuine owner fact cannot authorize source or force")
        f.consume(bad)
        check(f.force_calls==0 and bad.force_stop_required==true,"missing ownership invalidates submission and requires actual owner stop")
        check(f.stop_calls>=1,"actual owner stop provider is requested on loss")
    end
    local changes={
        function(f)f.record.body=newproxy()end,
        function(f)f.record.body_current=false end,
        function(f)f.record.follow_current=false end,
        function(f)f.record.context_current=false end,
        function(f)f.record.support_available=false end,
        function(f)f.record.focused=false end,
        function(f)f.record.menu_open=true end,
        function(f)f.record.fall_stop=true end,
        function(f)f.record.grounded="true"end,
        function(f)f.record.rotation_reserved="false"end,
        function(f)f.record.session="different-session"end,
        function(f)f.record.follow="different-follow"end,
        function(f)f.record.context="different-context"end,
    }
    for _,change in ipairs(changes)do
        cases+=1
        local f=fixture();f.ready();change(f)
        local out=f.step(true);refused(out,"mismatched or false real owner record disables force submission")
        check(out.force_stop_required and f.stop_calls>=1,"loss retains native stop obligation")
    end
    local sample_faults={
        function(s)s.epoch=false end,
        function(s)s.serial="1"end,
        function(s)s.serial="9007199254740998";s.time+=2*H end,
        function(s)s.time+=.02 end,
        function(s)s.seconds=.01 end,
        function(s)s.position=vector.create(0/0,0,0)end,
        function(s)s.inertia=vector.create(26,-1,10)end,
        function(s)s.rotation={0,0,0,2}end,
        function(s)s.mass=0 end,
    }
    for index,change in ipairs(sample_faults)do
        cases+=1
        local f=fixture();f.ready()
        local out=f.step(false,change);refused(out,"malformed/repeated-changed/gapped body measurement cannot advance forces")
        if index==3 then check(out.reason=="unsupported body step gap","skipped serials are refused without inventing intermediate contacts")end
        check(out.force_stop_required,"unknown body correspondence retains owner stop duty")
    end
    do
        cases+=1
        local f=fixture();f.ready()
        local disabled_calls=0
        f.mapping.controls=function(_,context)
            disabled_calls+=1
            -- A disabled ordinary model can still produce support/contact
            -- forces. This tempting fallback must never bypass the source gate.
            return{valid=true,submission_allowed=true,physics_epoch=context.physics_epoch,
                force_controls={enabled=false,pedal=0,brake=0,steer=0,hop_event_id=0,hop_strength=0}}
        end
        f.source_ready=false
        local out=f.step(true);refused(out,"source qualification loss blocks force consumer")
        f.consume(out)
        check(f.force_calls==0 and disabled_calls==0 and out.force_stop_required,
            "input loss blocks even disabled-model fallback and is not a native body stop receipt")
        f.source_clean=true;f.source_ready=true
        local cleaned=f.step(false);refused(cleaned,"source cleanup alone does not clear unknown native owner stop")
        check(not f.input:arm(2,f.now),"unknown native stop remains sticky even after source cleanup")
        check(cleaned.stop_request==f.request,"stop request outcome is preserved unchanged, never relabeled as stopped")
    end
    for _,outcome in ipairs({false,true,{available=true},{available=true,stopped=true},
        {available=true,stopped=true,body=newproxy(),session="fixture-session-17"}})do
        cases+=1
        local f=fixture();f.ready();f.input:stop("fixture loss")
        f.source_clean=true;f.stop_outcome=outcome
        local out=f.step(false);refused(out,"unbound/boolean/request-only stop state is not genuine cleanup proof")
        check(out.force_stop_required and not f.input:arm(2,f.now),"unsupported native outcome cannot clear sticky force stop")
    end
    do
        cases+=1
        local f=fixture();f.ready()
        local old_permit=f.last
        f.on_stop=function()
            check(f.input:status().submit_forces==false,"force permit invalidated before owner stop callback")
            check(not f.consume(old_permit),"stop invalidates cached permit tokens before invoking the actual owner")
        end
        local stopped=f.input:stop("fixture real stop request")
        refused(stopped,"explicit stop makes force permission false synchronously")
        check(stopped.stop_request_error==nil,"successful actual owner stop request has no callback error")
        check(stopped.lifecycle_token~=old_permit.lifecycle_token and stopped.permit_token~=old_permit.permit_token,
            "stop rotates both local token identities")
        f.source_clean=true
        f.stop_outcome={available=true,stopped=true,body=f.body,session=f.session,fixture_only=true}
        local out=f.step(false);refused(out,"cleaning does not issue an old body force permit")
        check(out.stop_outcome==f.stop_outcome,"actual bound cleanup record retained without generating a replacement DTO")
        check(out.stop_outcome_error==nil,"successful bound owner stop-state callback has no callback error")
        check(not out.force_stop_required,"only matching owner body/session stop proof clears native stop requirement")
        local requests=f.stop_calls
        local again=f.input:stop("fixture repeated completed stop")
        check(again.phase=="complete"and not again.force_stop_required and f.stop_calls==requests,
            "completed unarmed stop is idempotent and cannot create unclearable retired-pair debt")
        f.session="fixture-genuine-new-session-18";f.record.session=f.session
        check(f.input:arm(2,f.now),"new explicit intent may rearm after both cleanups")
        local current=f.input:status()
        check(current.lifecycle_token~=old_permit.lifecycle_token and current.permit_token~=old_permit.permit_token,
            "rearm exposes different current token identities from the stopped session")
        check(not f.consume(old_permit),"rearm rotates lifecycle identity so a previous session permit cannot return")
        f.publish();refused(f.step(false),"rearm anchors body anew rather than replaying an old permit")
        local replay=fixture();replay.ready();replay.input:stop("fixture terminal old owner")
        replay.source_clean=true
        replay.stop_outcome={available=true,stopped=true,body=replay.body,session=replay.session,fixture_only=true}
        replay.step(false)
        local armed=replay.input:arm(2,replay.now)
        if armed then
            replay.publish();local old_pair=replay.step(false)
            refused(old_pair,"fresh input lease cannot resurrect an already terminal stopped owner pair")
            check(old_pair.force_stop_required,"old owner pair remains unusable despite replayed terminal outcome")
        else check(replay.input:status().submit_forces==false,"rejected old owner rearm never exposes a force permit")end
    end
    do
        cases+=1
        local f=fixture();f.ready();local pending=f.last
        local unload=f.input:unload();refused(unload,"unload revokes even a previously enabled force frame")
        check(pending.force_controls.enabled==true and unload.force_stop_required,"disabled-control fallback is not substituted for native stop")
        f.consume(unload);check(f.force_calls==0,"no body/contact/balance force consumer runs on false gate")
    end
    do
        cases+=1
        local f=fixture();f.ready()
        local resets,reset=0,f.mapping.reset
        f.mapping.reset=function(self,...)
            resets+=1
            return reset(self,...)
        end
        f.on_stop=function()error("constructed owner request failure")end
        local out=f.input:stop("fixture independent cleanup")
        refused(out,"throwing owner stop request cannot preserve force permission")
        check(f.stop_calls==1 and type(out.stop_request_error)=="string",
            "failed owner request remains an explicit unresolved outcome")
        check(f.count("source.stop")==1 and f.source_stopped and resets==1,
            "source release and mapping reset still run after independent owner request failure")
        check(out.force_stop_required,"source release is not replacement owner stop proof")
    end
    do
        cases+=1
        local f=fixture();f.ready()
        local prior_bound_epoch=f.last_sample.epoch
        local source_steps=f.count("source.step")
        local captured_epoch,stop_sample
        local replacement_epoch=newproxy()
        f.owner.read=function(_,sample)
            captured_epoch=sample.epoch
            sample.epoch=replacement_epoch
            sample.velocity=vector.create(3,0,0)
            return f.record
        end
        f.on_stop=function(_,_,sample)stop_sample=sample end
        local out=f.step(true)
        refused(out,"owner callback cannot rewrite an actual body read into a force permit")
        check(out.reason=="body record changed during owner read" and f.count("source.step")==source_steps,
            "mutated body record is refused before any further source observation")
        check(out.physics_epoch==captured_epoch and out.body_sample.epoch==captured_epoch and
            out.body_record==f.last_sample and f.last_sample.epoch==replacement_epoch,
            "immutable body snapshot preserves the captured epoch while retaining the raw changed record")
        check(stop_sample~=f.last_sample and stop_sample.epoch==prior_bound_epoch and
            not pcall(function()stop_sample.epoch=replacement_epoch end),
            "owner stop receives the prior qualified immutable binding, never the callback's replacement epoch")
    end
    do
        cases+=1
        local f=fixture();f.ready()
        local source_steps=f.count("source.step")
        local unloads,nested_unload,nested_step=0,nil,nil
        f.source.unload=function(self)
            unloads+=1
            nested_unload=f.input:unload()
            nested_step=f.input:step(f.body,f.sample(),f.now)
            return self:status()
        end
        local out=f.input:unload()
        refused(out,"source unload callback reentry never exposes a force permit")
        refused(nested_unload,"nested unload stays diagnostic")
        refused(nested_step,"nested step is rejected during source cleanup")
        check(unloads==1 and f.count("source.step")==source_steps and f.count("source.stop")==1,
            "reentrant cleanup has one unload and no nested source step or stop loop")
        check(out.force_stop_required and not f.input:arm(2,f.now),
            "superseded cleanup retains actual owner and source duties")
        f.input:unload()
        check(unloads==1,"unload remains one-shot after the callback returns")
    end
    do
        cases+=1
        local f=fixture();f.ready()
        f.source_clean=true
        f.stop_outcome={available=true,stopped=true,body=f.body,session=f.session,fixture_only=true}
        local unloads=0
        f.source.unload=function(self)
            unloads+=1
            f.source_stopped,f.source_clean=true,false
            return self:status()
        end
        local out=f.input:unload()
        refused(out,"a later pending unload cannot inherit the preceding clean stop result")
        check(out.owner_stop_confirmed and out.force_stop_required and not out.source_cleanup_complete,
            "matching real-shaped owner proof cannot clear pending source unload duty")
        check(not f.input:arm(2,f.now),"unloaded pending lifecycle cannot rearm")
        f.source_clean=true
        local drained=f.step(false)
        refused(drained,"subsequent clean source drain remains diagnostic")
        check(drained.phase=="complete" and not drained.force_stop_required and
            drained.source_cleanup_complete and unloads==1,
            "only the later current clean drain completes the retained unload duty")
    end
    do
        cases+=1
        local stopped=fixture();stopped.ready();stopped.source_clean=true
        local clean=stopped.input:stop("fixture clean source, unknown owner")
        check(clean.source_cleanup_complete and clean.force_stop_required,
            "clean source cache alone leaves owner stop unresolved")
        stopped.stop_outcome={available=true,stopped=true,body=stopped.body,session=stopped.session,fixture_only=true}
        stopped.source.stop=function()error("constructed stop failure")end
        local failed_stop=stopped.input:stop("fixture failed current stop")
        refused(failed_stop,"throwing current source stop cannot reuse an old clean result")
        check(failed_stop.force_stop_required and failed_stop.source_frame==nil and
            not failed_stop.source_cleanup_complete and type(failed_stop.source_cleanup_error)=="string",
            "failed stop clears stale clean source cache before checking matching owner proof")
        local drained=fixture();drained.ready();drained.source_clean=true
        local prior=drained.input:stop("fixture prior clean source")
        check(prior.source_cleanup_complete and prior.force_stop_required,"second fixture starts with unresolved owner duty")
        drained.stop_outcome={available=true,stopped=true,body=drained.body,session=drained.session,fixture_only=true}
        drained.source.step=function()error("constructed drain failure")end
        local failed_drain=drained.step(false)
        refused(failed_drain,"throwing current drain cannot reuse an old clean result")
        check(failed_drain.force_stop_required and failed_drain.source_frame==nil and
            not failed_drain.source_cleanup_complete and type(failed_drain.source_cleanup_error)=="string",
            "failed drain retains source duty even after owner stop becomes confirmed")
    end
    do
        cases+=1
        for _,operation in ipairs({"stop","unload"})do
            local f=fixture();f.ready()
            f.source_clean=true
            f.stop_outcome={available=true,stopped=true,body=f.body,session=f.session,fixture_only=true}
            local completed=f.input:stop("fixture terminal owner before rearm")
            check(completed.phase=="complete"and not completed.force_stop_required,
                "rearm cancellation fixture starts from confirmed completed cleanup")
            f.session="fixture-genuine-new-session-after-"..operation;f.record.session=f.session
            local arms=f.count("source.arm")
            local callbacks,reset=0,f.mapping.reset
            f.mapping.reset=function(self,...)
                callbacks+=1
                if operation=="stop"then f.input:stop("fixture cancel during rearm reset")
                else f.input:unload()end
                return reset(self,...)
            end
            check(not f.input:arm(2,f.now),"stop or unload during completed-session reset cancels explicit rearm")
            local out=f.input:status()
            refused(out,"cancelled reset callback cannot expose a new body permit")
            check(callbacks==1 and f.count("source.arm")==arms,
                "cancelled reset is bounded and never adopts a new source lease")
            if operation=="unload"then
                check(f.count("source.unload")==1 and out.unloaded,
                    "deferred unload runs exactly once after rearm preflight leaves its busy guard")
            else
                check(f.count("source.unload")==0,"ordinary stop cancellation does not invent an unload request")
            end
        end
    end
    return{cases=cases,assertions=assertions,constructed=true,native_authority=false,gameplay=false}
end
return Tests

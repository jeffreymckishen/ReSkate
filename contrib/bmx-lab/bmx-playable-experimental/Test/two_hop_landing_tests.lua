-- Two intentional hops through the existing delayed-command model on a flat
-- authored plane. No SDK/native receipt or collision result is fabricated.
local Stage=require("./force_stage")
local Forces=require("./forces")
local Mapping=require("./ride_input_mapping")
local InFlight=require("./ride_inflight")
local World=require("./sim_world")
local M=require("./force_math")
local Tests={}
function Tests.run()
    local n=0
    local function check(ok,why)n+=1;assert(ok,why)end
    local h,tuning=Forces.native_seconds,Forces.tuning()
    local terrain,stage,mapper=World.terrain.flat(),Stage.new(),Mapping.new()
    local body,wheels=World.place(terrain,{speed=2})
    local lease=newproxy() -- Constructed source identity, never a native lease.
    local function contacts(measured)
        local samples={}
        local forward=M.turn(M.normalized(measured.orientation),{0,0,1})
        for i,hub in ipairs(World.hubs(measured))do
            local status,point,normal=World.ray(terrain,hub,World.wheel_radius+stage.tuning.wheel_probe_extra)
            local basis=status=="hit" and M.basis(normal,forward)
            if basis then
                samples[i]={contact={status="hit",point=point,normal=basis.normal,forward=basis.forward,
                    surface_velocity={0,0,0}},separation=M.dot(M.sub(hub,point),basis.normal)-World.wheel_radius,
                    wheel_center=M.copy(hub),wheel_radius=World.wheel_radius,
                    verified_plane=false,balance_normal_available=false}
            else samples[i]={contact={status=status=="clear" and "clear" or "unavailable"}}end
        end
        return samples
    end
    local function supported(measured,samples)
        local a=Forces.eligible_support(measured,samples[1],.005,tuning.maximum_penetration)
        local b=Forces.eligible_support(measured,samples[2],.005,tuning.maximum_penetration)
        return a or b,a and b
    end
    local function frame(serial,press)
        local buttons={}
        for _,key in ipairs({"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"})do buttons[key]=false end
        buttons.right_stick=press
        return {input_ok=true,lease_handle=lease,generation=1,sample={user=0,sequence="1",source_epoch="2",context_generation="3",
            observation_serial=tostring(serial),observed_ms=tostring(1000+math.floor((serial-1)*h*1000+.5)),packet=serial,
            pad={left_x=0,left_y=0,right_x=0,right_y=0,left_trigger=0,right_trigger=0,playstation=false,buttons=buttons}}}
    end
    local initial=contacts(body)
    check(supported(body,initial),"fixture starts on actual analytic support")
    local prime=mapper:observe(frame(1,false),{grounded=true,focused=true,menu_open=false,rotation_reserved=false})
    check(prime.valid and prime.active,"actual neutral source observation primes Mapping")
    local previous,integrated_hop,air_snapshot,land_snapshot
    local commands,applications,claims,retirements=0,0,0,0
    local first_air,second_air=false,false
    local first_stable,second_stable=0,0
    local release_step,second_press_step,finished_step
    for step=1,400 do
        if integrated_hop then
            check(mapper:retire_hop(integrated_hop,"accepted"),"exact local command disposition retires its integrated hop")
            integrated_hop=nil;retirements+=1
        end
        local samples=contacts(body)
        local grounded,both=supported(body,samples)
        if applications==1 and not second_press_step then
            if not grounded then first_air=true end
            if first_air and both and math.abs(body.linear_velocity[2])<=.4 then first_stable+=1 else first_stable=0 end
            if first_stable>=10 and not release_step then
                release_step=step
                land_snapshot={body=M.copy(body),wheels=M.copy(wheels),samples=M.copy(samples)}
            end
            if release_step and step-release_step>=10 and first_stable>=10 then second_press_step=step end
        elseif applications==2 then
            if not grounded then second_air=true end
            if second_air and both and math.abs(body.linear_velocity[2])<=.4 then second_stable+=1 else second_stable=0 end
        end
        if first_air and not air_snapshot and samples[1].contact.status=="clear" and samples[2].contact.status=="clear" then
            air_snapshot={body=M.copy(body),wheels=M.copy(wheels),samples=M.copy(samples)}
        end
        -- Hold the first press through actual landing, then observe ten fresh
        -- released samples before the distinct second press. Hold that too.
        local press=second_press_step~=nil or (release_step==nil and step>=8)
        local row=mapper:observe(frame(step+1,press),{grounded=grounded,focused=true,menu_open=false,rotation_reserved=false})
        check(row.valid and row.active,"actual Mapping observation refused at step"..step..":"..tostring(row.issue))
        local controls=mapper:controls({physics_epoch=newproxy(),h=h,grounded=grounded,rotation_reserved=false})
        check(controls.valid and controls.submission_allowed,"actual held controls refused at step"..step)
        if commands==1 and not second_press_step then
            check(mapper:status().hop_counter==1,"held R3 through flight/landing cannot mint another event")
        end
        local inflight={}
        if previous then
            local command={age=1,force=previous.force,torque=previous.torque}
            if previous.hop_applied then command.impulse=previous.hop_impulse;command.impulse_id=previous.hop_event_id end
            inflight[1]=command
        end
        local forecast,folded=InFlight.fold(h,tuning.gravity,inflight,body,samples)
        check(forecast~=nil,"original accepted-command fold refused at step"..step..":"..tostring(folded))
        check(stage:admit_measured(body),"original measured envelope refused at step"..step)
        local model,candidate=stage:preview(h,forecast,wheels,folded,controls.force_controls)
        check(model.valid,"actual Stage refused at step"..step..":"..tostring(model.issue))
        check(model.contact_scale==1 and M.length(model.force)<=6000 and M.length(model.torque)<=2000,
            "original force/torque caps and unclamped contact result remain")
        -- This is a constructed accepted-command boundary. It grants no SDK
        -- authority and is deliberately distinct from delayed model integration.
        stage:_adopt(candidate)
        if model.hop_applied then
            commands+=1
            check(controls.hop and model.hop_event_id==commands and model.hop_event_id==controls.hop.id,
                "each actual fresh R3 edge owns the next exact hop identity")
            check(math.abs(M.length(model.hop_impulse)-body.mass*tuning.hop_delta_speed)<1e-6,
                "hop keeps the original mass-scaled impulse")
            check(mapper:claim_hop(model.hop_event_id),"exact locally accepted hop becomes receipt-owned")
            claims+=1
        end
        local applied=previous or {force={0,0,0},torque={0,0,0},hop_impulse={0,0,0}}
        body=World.integrate(body,applied,tuning.gravity,h)
        if applied.hop_applied then applications+=1;integrated_hop=applied.hop_event_id end
        previous=model;wheels=model.wheels
        if second_stable>=10 then finished_step=step;break end
    end
    check(finished_step~=nil and first_air and second_air and first_stable>=10 and second_stable>=10,
        "both actual model ground-air-ground cycles finish within the original400-step bound")
    check(release_step and second_press_step and second_press_step-release_step>=10,
        "second hop follows actual landing and fresh released input rather than an automatic held-button replay")
    check(commands==2 and applications==2 and claims==2 and retirements==2 and integrated_hop==nil,
        "exactly two distinct commanded, delayed-integrated and retired hops")
    local status=mapper:status()
    check(status.hop_counter==2 and status.pending_hop==nil and status.last_retired.event.id==2,
        "no third held-button hop or unretired intent remains after the second landing")
    check(air_snapshot and land_snapshot,"separate actual clear-flight and stable-landing bodies were observed")
    -- Preserve the ordinary kernel's intentional policy: an event presented in
    -- air is consumed in that accepted candidate and cannot spring on landing.
    local raw=Forces.new()
    local air,candidate=raw:preview(h,air_snapshot.body,air_snapshot.wheels,air_snapshot.samples,{hop_event_id=9,hop_strength=1})
    check(air.valid and not air.grounded and not air.hop_applied,"actual clear-flight body cannot hop")
    check(raw:consumed_hop_event_id()==0 and candidate:consumed_hop_event_id()==9,"preview consumes only candidate history")
    raw:_adopt(candidate)
    local landed=raw:preview(h,land_snapshot.body,land_snapshot.wheels,land_snapshot.samples,{hop_event_id=9,hop_strength=1})
    check(landed.valid and landed.grounded and not landed.hop_applied and M.length(landed.hop_impulse)==0,
        "consumed airborne ID remains suppressed on actual model landing")
    return {cases=2,assertions=n,steps=finished_step,hop_commands=commands,hop_applications=applications,
        first_landing_release_step=release_step,second_press_step=second_press_step,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)
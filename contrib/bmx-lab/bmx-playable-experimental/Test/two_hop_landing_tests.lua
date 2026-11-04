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

    -- The manual on the right stick, through the actual Mapping: constructed pad frames a native step apart.
    local Input=require("./input")
    local function pad_frame(serial,pad)
        local buttons={}
        for _,key in ipairs({"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"})do buttons[key]=false end
        buttons.right_stick=pad.r3==true;buttons.lb=pad.lb==true
        return {input_ok=true,lease_handle=lease,generation=1,sample={user=0,sequence="1",source_epoch="2",context_generation="3",
            observation_serial=tostring(serial),observed_ms=tostring(1000+math.floor((serial-1)*h*1000+.5)),packet=serial,
            pad={left_x=0,left_y=pad.left_y or 0,right_x=0,right_y=pad.right_y or 0,left_trigger=0,right_trigger=0,
                playstation=false,buttons=buttons}}}
    end
    -- A fresh Mapping primed on a neutral pad. step(pad, grounded) observes one frame and returns its force
    -- controls and actions; a hop it mints is retired at once, as an accepted command would be.
    local function driver()
        local mapping,serial,hops=Mapping.new(),1,0
        local primed=mapping:observe(pad_frame(serial,{}),{grounded=true,focused=true,menu_open=false,rotation_reserved=false})
        check(primed.valid and primed.active,"a neutral pad primes the manual's Mapping")
        local d={mapping=mapping}
        function d.step(pad,grounded)
            if grounded==nil then grounded=true end
            serial+=1
            local row=mapping:observe(pad_frame(serial,pad),{grounded=grounded,focused=true,menu_open=false,rotation_reserved=false})
            check(row.valid,"the manual's pad frame is observed: "..tostring(row.issue))
            local c=mapping:controls({physics_epoch=newproxy(),h=h,grounded=grounded,rotation_reserved=false})
            check(c.valid and c.submission_allowed,"the manual's controls are sent: "..tostring(c.issue))
            local hop=c.hop
            if hop then hops+=1;check(mapping:retire_hop(hop.id,"accepted"),"the hop is retired") end
            return c.force_controls,c.actions,hop~=nil
        end
        function d.hops() return hops end
        return d
    end
    local band=.4918 -- right_y -.53 after the .12 dead zone: (.466-.22)/.50
    do -- Part way back: nothing for the first .10 s, then the manual follows the stick.
        local d=driver()
        local zero,first=0,nil
        for i=1,20 do
            local c=d.step({right_y=-.53})
            if c.manual==0 and not first then zero+=1 elseif not first then first=c.manual end
            if first then check(math.abs(c.manual-band)<.001,"the manual holds at the stick's height: "..c.manual) end
        end
        check(zero==5 and first and math.abs(first-band)<.001,"five steps (under .10 s) of nothing, then the manual: "..zero.." "..tostring(first))
    end
    do -- A flick hop pulls through the band in three frames and sends no manual on the way.
        local d=driver()
        local any=0
        for _,y in ipairs({-.33,-.67,-1,-1,-1,-1,.8,0,0}) do
            local c=d.step({right_y=y})
            if c.manual~=0 or c.nose_manual~=0 then any+=1 end
        end
        check(d.hops()==1 and any==0,"the flick hops and the front was never asked up: "..d.hops().." "..any)
    end
    do -- From an established manual the front stays up through the charge, and the flick sends none.
        local d=driver()
        for _=1,30 do d.step({right_y=-.53}) end
        local held=0
        for _=1,15 do local c=d.step({right_y=-1});if math.abs(c.manual-.6)<1e-9 then held+=1 end end
        check(held==15,"full back from a manual holds the front at .6 while the hop charges: "..held)
        local c,_,hopped=d.step({right_y=.8})
        check(hopped and c.manual==0,"the flick pops it with no manual on that step")
    end
    do -- Eased back into the band without a flick, the manual goes on, through the end of the flick window and after.
        local d=driver()
        for _=1,30 do d.step({right_y=-.53}) end
        for _=1,10 do d.step({right_y=-1}) end
        local kept=0
        for _=1,40 do local c=d.step({right_y=-.53});if math.abs(c.manual-band)<.001 then kept+=1 end end
        check(kept==40 and d.hops()==0,"the manual continues: "..kept)
    end
    do -- A step's flicker of lost support drops the manual for that step only.
        local d=driver()
        for _=1,20 do d.step({right_y=-.53}) end
        local air=d.step({right_y=-.53},false)
        local back=d.step({right_y=-.53},true)
        check(air.manual==0 and math.abs(back.manual-band)<.001,"none in the air, back at once: "..air.manual.." "..back.manual)
        -- The same between two pad frames: Ride's body steps re-project the held pad on the new ground.
        local function held(grounded)
            local c=d.mapping:controls({physics_epoch=newproxy(),h=h,grounded=grounded,rotation_reserved=false})
            check(c.valid,"the held pad is re-projected: "..tostring(c.issue))
            return c.force_controls.manual
        end
        local lost,found=held(false),held(true)
        check(lost==0 and math.abs(found-band)<.001,"with no fresh frame too: "..lost.." "..found)
    end
    do -- Through a step's lost support the stick still holds the manual, for the kernel's walk latch; let go, it holds none.
        local d=driver()
        for _=1,20 do d.step({right_y=-.53}) end
        local air=d.step({right_y=-.53},false)
        check(air.manual==0 and air.manual_held==true,"no manual in the air, but the stick still holds one: "..tostring(air.manual_held))
        check(d.step({right_y=-.53},true).manual_held==true,"and on the ground again")
        local free=d.step({},true)
        check(free.manual==0 and free.manual_held==false,"let go, it holds none: "..tostring(free.manual_held))
        check(d.step({},false).manual_held==false,"nor in the air after")
    end
    do -- R3 from a manual pops at once with no manual; landing with the stick still held goes back into it.
        local d=driver()
        for _=1,20 do d.step({right_y=-.53}) end
        local c,_,hopped=d.step({right_y=-.53,r3=true})
        check(hopped and c.manual==0,"R3 hops with no manual on that step")
        d.step({right_y=-.53})
        for _=1,30 do check(d.step({right_y=-.53},false).manual==0,"no manual in the air") end
        local landed=d.step({right_y=-.53},true)
        check(math.abs(landed.manual-band)<.001,"landing with the stick held lands in the manual at once: "..landed.manual)
    end
    do -- The left stick's air pitch is not sent as a manual.
        local d=driver()
        d.step({},false)
        local c=d.step({left_y=-.8},false)
        check(c.manual==0 and c.nose_manual==0,"no manual from the left stick in the air: "..c.manual)
    end
    do -- After a flick hop the stick back in the middle in the air arms a landing; LB held in the air does not.
        for _,lb in ipairs({false,true}) do
            local d=driver()
            for _,y in ipairs({-1,-1,-1,.8}) do d.step({right_y=y}) end
            for _=1,10 do d.step({lb=lb},false) end
            for _=1,10 do d.step({right_y=-.53,lb=lb},false) end
            local zero,first=0,nil
            for _=1,12 do
                local c=d.step({right_y=-.53},true)
                if c.manual==0 and not first then zero+=1 elseif not first then first=c.manual end
            end
            if lb then check(first==nil,"with LB held in the air, no manual until the stick has been in the middle")
            else check(zero==5 and first and math.abs(first-band)<.001,"a manual .10 s after landing: "..zero.." "..tostring(first)) end
        end
    end
    do -- The forward band writes the nose manual, and the stage passes it as the nose manual.
        local d=driver()
        local c
        for _=1,20 do c=d.step({right_y=.53}) end
        check(c.nose_manual>.4 and c.manual==0,"the forward band is the nose manual: "..c.nose_manual)
        local flat=World.terrain.flat()
        local level=World.place(flat,{speed=4})
        local samples=World.contacts(flat,level,tuning.gravity)
        local model=Stage.new():preview(h,level,Forces.proposed_wheels(),samples,c)
        check(model.valid and model.manual_active==false,"and it lifts no front")
        check(model.nose_manual_active==true,"but the rear, in the nose manual: "..tostring(model.nose_manual_active))
    end
    -- The manual a raw right_y holds, after the .12 dead zone, over the band from .22 to .72.
    local function level(y) return math.min(1,((math.abs(y)-.12)/.88-.22)/.5) end
    do -- Held at the top of the band, an overshoot is not a hop's charge: from a manual the stick goes on to .85 first.
        -- The band ended on the hop's threshold, so three frames at -.80, early in a manual held at -.70, charged a
        -- hop and dropped the front, and with no flick the band gave nothing until the stick was back in the middle.
        local d=driver()
        for _=1,12 do d.step({right_y=-.70}) end
        local over,after=0,0
        for _=1,3 do if d.step({right_y=-.80}).manual==1 then over+=1 end end
        for _=1,40 do if math.abs(d.step({right_y=-.70}).manual-level(-.70))<.001 then after+=1 end end
        check(over==3 and after==40 and d.hops()==0,"the overshoot holds the top manual and the manual goes on: "..over.." "..after)
        for _=1,6 do d.step({right_y=-.95}) end
        local _,_,hopped=d.step({right_y=.8})
        check(hopped and d.hops()==1,"all the way back from a manual still charges a hop")
    end
    do -- Pulled straight to the stop and eased back with no flick, the hop lapses and the stick holds a manual.
        local d=driver()
        for _=1,4 do d.step({right_y=-1}) end
        local first
        for i=1,40 do local c=d.step({right_y=-.70});if not first and c.manual>0 then first=i end end
        check(first and first<=25 and d.hops()==0,"a manual follows the lapsed hop: "..tostring(first))
    end
    do -- The top of the band is the manual's off the ground too: a step's lost support, or a landing, keeps it.
        -- Off the ground any stick at .70 or more was taken for a trick and let the manual go, from raw -.736 up.
        for _,y in ipairs({-.70,-.745}) do
            local d=driver()
            for _=1,20 do d.step({right_y=y}) end
            local air=d.step({right_y=y},false)
            local back=d.step({right_y=y},true)
            check(air.manual==0 and math.abs(back.manual-level(y))<.001,"at "..y.." none in the air, back at once: "..back.manual)
        end
        local d=driver()
        for _=1,20 do d.step({right_y=-.745}) end
        for _=1,30 do d.step({right_y=-.745},false) end
        check(math.abs(d.step({right_y=-.745},true).manual-level(-.745))<.001,"held through a flight it lands back in at once")
    end
    do -- A charge from a manual keeps the front up across a step's lost support, and the flick still hops.
        local d=driver()
        for _=1,30 do d.step({right_y=-.53}) end
        for _=1,5 do d.step({right_y=-1}) end
        check(d.step({right_y=-1},false).manual==0,"no manual in the air")
        local kept=0
        for _=1,5 do if math.abs(d.step({right_y=-1}).manual-.6)<1e-9 then kept+=1 end end
        local c,_,hopped=d.step({right_y=.8})
        check(kept==5 and hopped and c.manual==0,"the charge goes on at .6 and the flick hops: "..kept)
    end
    do -- After the middle, the stick pushed over for a trick still takes the landing's manual away.
        local d=driver()
        for _,y in ipairs({-1,-1,-1,.8}) do d.step({right_y=y}) end
        for _=1,5 do d.step({},false) end
        for _=1,3 do d.step({right_y=-.80},false) end
        local any=false
        for _=1,10 do d.step({right_y=-.53},false) end
        for _=1,12 do if d.step({right_y=-.53},true).manual~=0 then any=true end end
        check(not any,"a trick's push lets the landing manual go until the stick has been in the middle")
    end
    do -- sim_world's copy of the mapping sends the same manual, on the ground and in the air.
        for _,grounded in ipairs({true,false}) do
            local d=driver()
            local c,actions
            for _=1,20 do c,actions=d.step({right_y=-.53,left_y=-.8},grounded) end
            local raw=Input.raw({available=true,left_y=-.8,right_y=-.53})
            local copy=World.controls(d.mapping._settings,actions,raw,nil,grounded,false)
            check(copy.manual==c.manual and copy.nose_manual==c.nose_manual and copy.manual_held==c.manual_held,
                "World.controls matches Mapping "..(grounded and "on the ground" or "in the air")..": "..copy.manual.." "..c.manual)
        end
    end
    do -- sim_world enters a manual, and carries one into a hop's charge, on the same step as Mapping.
        -- Mapping times the stick in whole milliseconds, sim_world in native steps of 1/60 s in float32, six of which
        -- come to .0999999940: short of the .10 s entry by more than input.lua allowed, so the offline world entered
        -- a manual a step after the game did, and fifteen fell short of the .25 s carry the same way.
        local function simulated(pads)
            local world=World.new({terrain=terrain,speed=4})
            world:step({}) -- The neutral pad the mapper starts from, as Mapping's prime.
            local out={}
            for i,pad in ipairs(pads) do out[i]=world:step(pad).manual end
            return out
        end
        local function mapped(pads)
            local d=driver()
            local out={}
            for i,pad in ipairs(pads) do out[i]=d.step(pad).manual end
            return out
        end
        local entry,carry={},{}
        for i=1,12 do entry[i]={right_y=-.53} end
        for i=1,20 do carry[i]={right_y=i<=15 and -.53 or -1} end
        for _,row in ipairs({{"entry",entry},{"carry",carry}}) do
            local name,pads=row[1],row[2]
            local sim,game=simulated(pads),mapped(pads)
            for i=1,#pads do
                check(math.abs(sim[i]-game[i])<1e-9,string.format("%s step %d: sim_world sends %.3f where Mapping sends %.3f",name,i,sim[i],game[i]))
            end
        end
    end
    return {cases=3,assertions=n,steps=finished_step,hop_commands=commands,hop_applications=applications,
        first_landing_release_step=release_step,second_press_step=second_press_step,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)
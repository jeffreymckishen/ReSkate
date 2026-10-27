-- Pure Luau cases for forces.lua's pedaling decision (F.pedal_cadence) and the
-- latch the kernel keeps for it. Nothing runs on require; run() is called by a
-- Luau runner. The bodies are constructed fixtures, not native or game evidence.
-- force_tests.lua stays as it is: the Host's C++ comparison pins its case count.
local F=require("./forces")
local M=require("./force_math")
local tests={}
function tests.run()
    local cases,assertions=0,0
    local function check(value,why) assertions+=1 assert(value,why) end
    local function near(a,b,error) return math.abs(a-b)<=(error or 1e-9) end
    local function same(a,b) return M.length(M.sub(a,b))==0 end
    local h=F.native_seconds
    local t=F.tuning() local top,resume=t.pedal_top_speed,t.pedal_resume_speed
    local function fixture(speed)
        local b,w=F.proposed_body(),F.proposed_wheels() b.center_of_mass={0,.9,-.05}
        b.linear_velocity={0,0,speed} for _,wheel in w do wheel.angular_speed=speed/wheel.radius end
        local s={} for i=1,2 do s[i]={contact={status="hit",point={0,0,i==1 and .525 or -.525},normal={0,1,0},forward={0,0,1},surface_velocity={0,0,0}},separation=0,verified_plane=false,balance_normal_available=false} end
        return b,w,s
    end
    local function decide(state,speed,pedal,enabled)
        return F.pedal_cadence(state,{enabled=enabled~=false,pedal=pedal or 1,motor_speed=speed,top_speed=top,resume_speed=resume})
    end
    -- Changes of the pedaling decision over a speed sequence with the pedal held.
    local function changes(speeds,resume_speed)
        local state,last,count=F.pedal_state(),nil,0
        for _,speed in speeds do
            local d d,state=F.pedal_cadence(state,{enabled=true,pedal=1,motor_speed=speed,top_speed=top,resume_speed=resume_speed or resume})
            if last~=nil and d.pedaling~=last then count+=1 end last=d.pedaling
        end
        return count,last
    end
    cases+=1 do
        check(top<t.pedal_cutoff and top>=t.pedal_cutoff-.1 and near(top-resume,.5),"the rider stops just under the cutoff, with a 0.5 m/s band")
        local state,d=F.pedal_state()
        for _,speed in {0,3,6,resume,top-.01} do
            d,state=decide(state,speed) check(d.valid and d.pedaling and not d.spun_out,"a held pedal below the top speed pedals at "..speed)
        end
        d,state=decide(state,top) check(d.valid and not d.pedaling and d.spun_out,"reaching the top speed stops pedaling")
        for _,speed in {top-.01,7.6,resume+.01,resume+1e-9} do
            d,state=decide(state,speed) check(not d.pedaling and d.spun_out,"inside the band a held pedal still coasts at "..speed)
        end
        d,state=decide(state,resume) check(d.pedaling and not d.spun_out,"at the resume speed pedaling starts again")
        d,state=decide(state,7.6) check(d.pedaling,"climbing back through the band keeps pedaling")
        d,state=decide(state,15) check(not d.pedaling and d.spun_out,"far past the top speed it coasts")
        check(table.isfrozen(d) and not table.isfrozen(state),"the decision is frozen; the next latch is the caller's own")
    end
    cases+=1 do
        local d,state=decide(F.pedal_state(),3,0) check(d.valid and not d.pedaling and not d.spun_out,"a released pedal coasts")
        d,state=decide(F.pedal_state(),8.5,0) check(not d.pedaling and not state.spun_out,"a released pedal past the top speed does not arm the latch")
        d=decide(state,7.6,1) check(d.pedaling,"pressing inside the band after coasting down from above pedals")
        d,state=decide(F.pedal_state(),8.5,1,false) check(not d.pedaling and not state.spun_out,"disabled control past the top speed does not arm it")
        d,state=decide(F.pedal_state(),8.5,1) check(state.spun_out,"a held pedal past the top speed arms it")
        d,state=decide(state,7.6,0) check(state.spun_out,"releasing inside the band keeps it armed")
        d=decide(state,7.6,1) check(not d.pedaling,"pressing again inside the band after a spin-out still coasts")
        d=decide(state,7,1) check(d.pedaling,"pressing again below the band pedals")
        d=decide(F.pedal_state(),3,1,false) check(d.valid and not d.pedaling,"disabled control never pedals")
        d=decide(nil,7.6,1) check(d.valid and d.pedaling,"no history is a bike that has not spun out")
        d=decide(nil,top,1) check(d.valid and not d.pedaling,"no history still stops at the top speed")
    end
    cases+=1 do
        local base={enabled=true,pedal=1,motor_speed=3,top_speed=top,resume_speed=resume}
        for index,bad in {{motor_speed=0/0},{motor_speed=-1},{motor_speed=math.huge},{motor_speed=1e6+1},{pedal=1.5},{pedal=-.1},
            {pedal=0/0},{pedal="1"},{enabled=1},{top_speed=0/0},{resume_speed=top},{resume_speed=-1},{top_speed=51,resume_speed=7}} do
            local s=table.clone(base) for key,value in bad do s[key]=value end
            local d,state=F.pedal_cadence({spun_out=true},s)
            check(not d.valid and not d.pedaling and not d.spun_out and state.spun_out==false,"refused input never pedals "..index)
        end
        for _,previous in {"latch",{},{spun_out=1}} do
            check(not F.pedal_cadence(previous,base).valid,"a malformed latch is refused")
        end
        check(not F.pedal_cadence(nil,nil).valid and not F.pedal_cadence(nil,"s").valid,"a missing sample is refused")
        local b,w,s=fixture(3)
        for _,bad in {{pedal_top_speed=8.1},{pedal_resume_speed=top},{pedal_resume_speed=-1},{pedal_top_speed=0/0}} do
            check(not F.new(bad):step(h,b,w,s,{pedal=1}).valid,"the kernel refuses a top speed past the cutoff or a resume speed at or above it")
        end
    end
    cases+=1 do
        -- Flicker: speed noise around either threshold changes the decision once.
        local around_top,around_resume={},{}
        for i=0,40 do around_top[#around_top+1]=7+i*.0225 end
        for i=1,240 do around_top[#around_top+1]=top+.2*math.sin(i*.7) end
        local count,last=changes(around_top)
        check(count==1 and last==false,"0.2 m/s of noise at the top speed stops pedaling once, not "..count)
        around_resume[1]=8.5 for i=1,240 do around_resume[#around_resume+1]=resume+.2*math.sin(i*.7) end
        count,last=changes(around_resume)
        check(count==1 and last==true,"0.2 m/s of noise at the resume speed starts pedaling once, not "..count)
        count=changes(around_top,top-1e-6)
        check(count>20,"without the band the same noise switches "..count.." times")
    end
    cases+=1 do
        -- The kernel: no drive torque while the rider is not pedaling.
        local b,w,s=fixture(8.5)
        local held,released=F.new():step(h,b,w,s,{pedal=1}),F.new():step(h,b,w,s,{pedal=0})
        check(held.valid and released.valid and not held.pedaling and not released.pedaling,"a held pedal past the top speed is not pedaling")
        check(same(held.force,released.force) and same(held.torque,released.torque) and same(held.linear_impulse,released.linear_impulse) and
            held.wheels[2].angular_speed==released.wheels[2].angular_speed,"it sends exactly the released pedal's command")
        b,w,s=fixture(3) held,released=F.new():step(h,b,w,s,{pedal=1}),F.new():step(h,b,w,s,{pedal=0})
        check(held.pedaling and not released.pedaling and held.force[3]>released.force[3]+1,"below the top speed the held pedal drives the bike")
        -- The fade below the cutoff is unchanged: at 7 m/s half the torque.
        b,w,s=fixture(7)
        local faded=F.new():step(h,b,w,s,{pedal=1})
        local direct=F.new({pedal_torque=37.5,pedal_fade_start=10,pedal_cutoff=12,pedal_top_speed=11.9,pedal_resume_speed=11.4}):step(h,b,w,s,{pedal=1})
        check(faded.pedaling and direct.pedaling and M.length(M.sub(faded.force,direct.force))<1e-9 and
            near(faded.wheels[2].angular_speed,direct.wheels[2].angular_speed),"the fade still halves the drive at 7 m/s")
        local invalid=F.new():step(h*2,b,w,s,{pedal=1})
        check(not invalid.valid and invalid.pedaling==false,"a refused step reports no pedaling")
        b,w,s=fixture(3) check(not F.new():step(h,b,w,s,{pedal=1,enabled=false}).pedaling,"disabled control never pedals")
    end
    cases+=1 do
        -- The latch inside the kernel, one committed step at a time. Each
        -- fixture's rear rim turns at the body speed.
        local controller=F.new()
        local function ride(speed,pedal) local b,w,s=fixture(speed) return controller:step(h,b,w,s,{pedal=pedal or 1}) end
        for _,speed in {3,7,7.6,top-.01} do check(ride(speed).pedaling,"accelerating with the pedal held pedals at "..speed) end
        check(not ride(top).pedaling and controller.pedal_latch.spun_out,"the top speed stops pedaling")
        for _,speed in {top-.01,7.6,resume+.01} do check(not ride(speed).pedaling,"still coasting inside the band at "..speed) end
        check(ride(resume-.001).pedaling and not controller.pedal_latch.spun_out,"pedaling resumes at the resume speed")
        check(ride(7.6).pedaling,"and keeps on back up through the band")
        check(not ride(7.6,0).pedaling,"releasing always coasts")
        -- 2 s at 15 m/s, the pedal held all along.
        for _=1,120 do
            local r=ride(15) check(r.valid and not r.pedaling,"a long run at 15 m/s never pedals")
        end
        check(controller.pedal_latch.spun_out,"the latch holds at 15 m/s")
        -- A bike that coasted down from above without the pedal can be pedaled at once.
        controller=F.new()
        check(not ride(8.5,0).pedaling and not controller.pedal_latch.spun_out,"coasting past the top speed does not arm the latch")
        check(ride(7.6).pedaling,"so a pedal pressed inside the band pedals")
    end
    cases+=1 do
        -- Preview and adopt: only an adopted candidate carries the latch.
        local controller=F.new() local b,w,s=fixture(8.5)
        local r,candidate=controller:preview(h,b,w,s,{pedal=1})
        check(r.valid and not r.pedaling and candidate.pedal_latch.spun_out and not controller.pedal_latch.spun_out,"a preview trips only its candidate")
        b,w,s=fixture(7.6)
        check(controller:preview(h,b,w,s,{pedal=1}).pedaling,"the committed kernel was never adopted, so it pedals inside the band")
        check(not candidate:preview(h,b,w,s,{pedal=1}).pedaling,"the candidate coasts inside the band")
        controller:_adopt(candidate)
        check(controller.pedal_latch.spun_out and not controller:preview(h,b,w,s,{pedal=1}).pedaling,"adopting the candidate carries its latch")
        local copy=controller:clone() b,w,s=fixture(3)
        check(copy:step(h,b,w,s,{pedal=1}).pedaling and not copy.pedal_latch.spun_out and controller.pedal_latch.spun_out,"a clone's latch is its own")
        -- A refused step and a continuity break keep it; reset clears it.
        b,w,s=fixture(7.6)
        check(not controller:step(h*2,b,w,s,{pedal=1}).valid and controller.pedal_latch.spun_out,"a refused step keeps the latch")
        controller:invalidate_continuity()
        check(controller.pedal_latch.spun_out and not controller:step(h,b,w,s,{pedal=1}).pedaling,"a continuity break keeps the latch")
        controller:reset()
        check(not controller.pedal_latch.spun_out and controller:step(h,b,w,s,{pedal=1}).pedaling,"reset clears the latch")
    end
    cases+=1 do
        -- The pump reads the same decision: pedaling softens it to 0.75, and a
        -- held pedal past the top speed pumps as a released one.
        local function pump(speed,pedal)
            local controller=F.new() local b,w,s=fixture(speed)
            controller:step(h,b,w,s,{pedal=pedal,pump_operator_available=true,ground_pump=0})
            local r=controller:step(h,b,w,s,{pedal=pedal,pump_operator_available=true,ground_pump=-1})
            check(r.valid and r.pump.applied,"ground pump applies at "..speed) return r.pump.down_acceleration
        end
        check(near(pump(3,1),11*.75) and near(pump(3,0),11),"pedaling still softens the pump")
        check(near(pump(8.5,1),11) and near(pump(8.5,0),11),"a held pedal past the top speed pumps fully")
    end
    return {cases=cases,assertions=assertions}
end
return tests

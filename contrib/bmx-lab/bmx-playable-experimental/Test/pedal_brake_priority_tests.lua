-- Constructed Luau source only. These cases have not been run by the author.
local F=require("./forces")
local M=require("./force_math")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(value,why) assertions+=1 assert(value,why) end
    local function same(a,b) return M.length(M.sub(a,b))==0 end
    local function fixture(speed)
        local body,wheels=F.proposed_body(),F.proposed_wheels()
        body.center_of_mass={0,.9,-.05};body.linear_velocity={0,0,speed}
        for _,wheel in wheels do wheel.angular_speed=speed/wheel.radius end
        local samples={}
        for i=1,2 do
            samples[i]={contact={status="hit",point={0,0,i==1 and .525 or -.525},normal={0,1,0},
                forward={0,0,1},surface_velocity={0,0,0}},separation=0,verified_plane=false,balance_normal_available=false}
        end
        return body,wheels,samples
    end
    local function step(controller,speed,controls)
        local body,wheels,samples=fixture(speed)
        return controller:step(F.native_seconds,body,wheels,samples,controls)
    end
    cases+=1 do
        -- A+B should issue exactly the same command as B alone, including
        -- the cadence consumed by the accepted riding presentation.
        for _,speed in {3,7.6} do for _,brake in {.25,1} do
            local held=step(F.new(),speed,{pedal=1,brake=brake})
            local released=step(F.new(),speed,{pedal=0,brake=brake})
            check(held.valid and released.valid,"constructed braking packets remain valid")
            check(not held.pedaling and not released.pedaling,"braking pauses the rider's crank")
            check(same(held.force,released.force),"holding A does not fight braking force")
            check(same(held.torque,released.torque),"holding A does not change braking torque")
            check(same(held.linear_impulse,released.linear_impulse),"braking linear impulse matches released pedal")
            check(same(held.angular_impulse,released.angular_impulse),"braking angular impulse matches released pedal")
            check(held.wheels[1].angular_speed==released.wheels[1].angular_speed
                and held.wheels[2].angular_speed==released.wheels[2].angular_speed,"both rotor results match")
            check(held.pump.down_acceleration==released.pump.down_acceleration,"pump uses the same no-pedal decision")
        end end
        local controller=F.new()
        check(not step(controller,3,{pedal=1,brake=1}).pedaling,"a held pedal stays stopped during braking")
        local resumed=step(controller,3,{pedal=1,brake=0})
        local coasting=step(F.new(),3,{pedal=0,brake=0})
        check(resumed.valid and resumed.pedaling,"releasing the brake resumes a held pedal")
        check(resumed.force[3]>coasting.force[3]+1,"normal forward drive resumes without a new A edge")
    end
    cases+=1 do
        local controller=F.new();local tuning=F.tuning()
        check(not step(controller,tuning.pedal_top_speed,{pedal=1}).pedaling
            and controller.pedal_latch.spun_out,"top speed still arms the existing latch")
        check(not step(controller,7.6,{pedal=1,brake=1}).pedaling
            and controller.pedal_latch.spun_out,"braking inside the band preserves spin-out history")
        check(not step(controller,7.6,{pedal=1,brake=0}).pedaling
            and controller.pedal_latch.spun_out,"brake release cannot bypass the governor")
        check(step(controller,tuning.pedal_resume_speed,{pedal=1}).pedaling
            and not controller.pedal_latch.spun_out,"the original resume threshold still permits pedaling")
    end
    return {cases=cases,assertions=assertions}
end
return Tests

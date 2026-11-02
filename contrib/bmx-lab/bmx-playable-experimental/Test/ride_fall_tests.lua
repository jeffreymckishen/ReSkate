-- When a ride ends, on the real Ride, Mapping, Contact and ForceStage with constructed bodies and wheel rays:
-- a ramp is not a fall, a fall on the ground ends, a body in the air gets its time, and a hit goes over the bars.
-- Constructed SDK transport, no Host and no game; the bodies here are posed, not simulated.
local Ride=require("./ride_runtime_qualified_fixture")
local Mapping=require("./ride_input_mapping")
local Contact=require("./contact_runtime")
local Stage=require("./force_stage")
local Forces=require("./forces")
local Geometry=require("./bike_geometry")
local Identity=require("./lease_identity")
local M=require("./force_math")
local T={}
local h=Forces.native_seconds
local R=Geometry.wheel_radius
local function roll_of(angle) return {0,0,math.sin(angle/2),math.cos(angle/2)} end
local function pitch_of(angle) return {math.sin(angle/2),0,0,math.cos(angle/2)} end
-- ground(from,to) answers each ray with a row or {status="clear"}.
local function harness(ground)
    local body,incarnation,lease,epoch=newproxy(),newproxy(),newproxy(),newproxy()
    local w={serial=1000,time=1,submits={},requested={},ground=ground}
    local api={}
    function api.probe_batch(got,plan)
        local rays={}
        for i,ray in ipairs(plan) do rays[i]=w.ground(ray.from,ray.to,#plan,i) end
        return {status="available",epoch=got,native_casts=#plan,budget_exhausted=false,local_actor_excluded=false,
            owned_bodies_excluded=true,requested_query_preset="camera",named_actor_categories_absent=true,rays=rays}
    end
    local sequence=5000
    function api.submit(_,value)
        sequence+=1
        w.submits[#w.submits+1]=value
        w.requested[tostring(sequence)]=tostring(w.serial)
        return true,nil,tostring(sequence)
    end
    function api.receipt(got)
        return {sequence=got,requested_serial=w.requested[got],produced_serial="0",outcome="queued",force_attempted=false,
            torque_attempted=false,retained=false,quarantined=false,cleanup_disposition="none"}
    end
    function api.acknowledge() return true end
    local pad={left_x=0,left_y=0,right_x=0,right_y=0,left_trigger=0,right_trigger=0,playstation=false,
        buttons={a=false,b=false,right_stick=false,lb=false,rb=false}}
    local source={input_ok=true,phase="capturing",generation=1,lease_handle=lease,
        sample={user=0,sequence="77",source_epoch="78",context_generation="79",observation_serial="80",observed_ms="1000",packet=9,pad=pad}}
    local ride=Ride.new(api,{mapping=Mapping.new(),force=Stage.new(),contact=Contact},{body_handle=body,incarnation=incarnation})
    function w.step(pose)
        w.serial+=1;w.time+=h
        local v=pose.velocity or {0,0,0}
        local p=pose.position
        return ride:observe(source,{epoch=epoch,serial=tostring(w.serial),time=w.time,seconds=h,mass=Geometry.mass,
            position=vector.create(p[1],p[2],p[3]),velocity=vector.create(v[1],v[2],v[3]),
            angular_velocity=vector.create(0,0,0),inertia=vector.create(26,32,10),rotation=pose.rotation},
            {now_ms=1000,focused=true,menu_open=false,loaded=true})
    end
    return w
end
local function hit(from,to,y,normal)
    local fraction=(from.y-y)/(from.y-to.y)
    if fraction<0 or fraction>1 then return {status="clear"} end
    return {status="hit",position=vector.create(from.x,y,from.z),fraction=fraction,normal=vector.create(normal[1],normal[2],normal[3]),
        surface_velocity=vector.create(0,0,0),normal_available=true,surface_velocity_available=true,motion="measured"}
end
local function flat(from,to) return hit(from,to,0,{0,1,0}) end
local function clear() return {status="clear"} end
local function level() return {position={0,R+Geometry.com[2]-Geometry.rear_axle[2],0},rotation={0,0,0,1}} end
function T.run()
    local n,cases=0,0
    local function check(ok,why) n+=1;assert(ok,why) end
    local function case(body) cases+=1;body() end
    local function steps(w,pose,count)
        for i=1,count do
            local out=w.step(pose)
            if out.stop_requested then return i,out end
        end
        return nil
    end
    case(function() -- Up a quarter pipe: 60 degrees from world up, square to the surface under the wheels.
        local rotation=pitch_of(-math.rad(60))
        local n=M.turn(rotation,{0,1,0})
        local at={0,5,0}
        local rear=M.add(at,M.turn(rotation,M.sub(Geometry.rear_axle,Geometry.com)))
        local plane=M.sub(rear,M.mul(n,R))
        local w=harness(function(from,to)
            local y=plane[2]-(n[1]*(from.x-plane[1])+n[3]*(from.z-plane[3]))/n[2]
            return hit(from,to,y,n)
        end)
        local at_step,out=steps(w,{position=at,rotation=rotation},120)
        check(at_step==nil,"a ramp is not a fall: "..tostring(at_step).." "..tostring(out and out.issue))
    end)
    case(function() -- The bevel of a kerb under one wheel, the bike level: nothing world up would have stopped.
        local n=M.unit({0,.6,-.8})
        local w=harness(function(from,to,count,i) return i==1 and hit(from,to,0,n) or clear() end)
        check(steps(w,level(),120)==nil,"a level bike has not fallen, whatever one wheel reads")
    end)
    case(function() -- Over on its side on flat ground, the wheels' rays still landing.
        local rotation=roll_of(math.rad(90))
        local w=harness(flat)
        local at,out=steps(w,{position={0,.228,0},rotation=rotation},40)
        check(at==18,"a fall takes .3 s to end: "..tostring(at))
        check(string.match(out.issue,"^measured tilt 90.0 deg over the 65 deg Ride stop$")~=nil,"and says what it was: "..tostring(out.issue))
    end)
    case(function() -- Saved in time: back inside the limit restarts the count.
        local w=harness(flat)
        local over={position={0,.45,0},rotation=roll_of(math.rad(70))}
        check(steps(w,over,17)==nil,"not yet")
        check(steps(w,level(),1)==nil,"saved")
        check(steps(w,over,17)==nil,"the count began again")
    end)
    case(function() -- Thrown off a ramp with no surface under it: a second and a half, and no further than 120.
        local w=harness(clear)
        local at=steps(w,{position={0,9,0},rotation=roll_of(math.rad(100))},120)
        check(at==90,"the air has its time: "..tostring(at))
        local over=harness(clear)
        check(steps(over,{position={0,9,0},rotation=roll_of(math.rad(130))},5)==1,"upside down ends at once")
        local low=harness(clear)
        check(steps(low,{position={0,9,0},rotation=roll_of(math.rad(50))},200)==nil,"inside 55 degrees it can fly as long as it likes")
    end)
    case(function() -- A fall that keeps losing and finding its wheels still ends.
        local odd=false
        local w=harness(function(from,to,count,i)
            if i==1 then odd=not odd end
            return odd and flat(from,to) or clear()
        end)
        local at=steps(w,{position={0,.228,0},rotation=roll_of(math.rad(90))},120)
        check(at~=nil and at<=20,"one count for both branches: "..tostring(at))
    end)
    case(function() -- A hit: the bike goes over the bars rather than the ride ending level, and it ends either way.
        local w=harness(flat)
        local pose=level()
        pose.velocity={0,0,7.5}
        check(steps(w,pose,4)==nil,"riding")
        pose.velocity={0,0,7.2}
        check(steps(w,pose,1)==nil,"the first step of the hit")
        pose.velocity={0,0,.8}
        check(steps(w,pose,1)==nil,"a hit does not end the ride on the spot")
        local at,out=steps(w,pose,80)
        check(at~=nil and at<=61,"a bike that cannot go over still ends: "..tostring(at))
        check(string.match(out.issue,"^hit something at 7%.%d m/s$")~=nil,"and says so: "..tostring(out.issue))
        local tipped=harness(flat)
        pose=level()
        pose.velocity={0,0,7.5}
        steps(tipped,pose,4)
        pose.velocity={0,0,.8}
        steps(tipped,pose,2)
        pose.rotation=pitch_of(math.rad(80))
        local early=tipped.step(pose)
        check(early.stop_requested and string.match(early.issue,"^hit something")~=nil,"far enough over, it ends at once")
    end)
    case(function() -- What the kernel can do itself is not a hit: a hard brake, and the most a landing may send.
        local w=harness(flat)
        local pose=level()
        for i=0,40 do
            pose.velocity={0,0,7.5-i*.07}
            check(not w.step(pose).stop_requested,"a brake is not a hit")
        end
        local landing=harness(flat)
        pose=level()
        for i=0,3 do
            pose.velocity={0,0,7.5-i*1.9}
            check(not landing.step(pose).stop_requested,"nor is the landing cap")
        end
    end)
    case(function() -- A kerb the ray lands under keeps its wheel: a held row, not a clear one, down to the floor for a flat top.
        for _,depth in ipairs({.15,.22}) do
            local w=harness(function(from,to,count,i)
                local y=from.y-R
                if i==1 then y+=depth end
                return hit(from,to,y,{0,1,0})
            end)
            local out=w.step(level())
            check(not out.stop_requested and out.model~=nil,"a wheel riding onto a step of "..depth.." is admitted: "..tostring(out.issue))
            local command=w.submits[1]
            check(command~=nil and command.force.y>0,"and pushes back")
        end
        local w=harness(function(from,to,count,i)
            local y=from.y-R
            if i==1 then y+=.30 end
            return hit(from,to,y,{0,1,0})
        end)
        check(not w.step(level()).stop_requested,"past the floor it reads clear, as a wall does")
    end)
    return {cases=cases,assertions=n,native_authority=false,constructed=true}
end
return T

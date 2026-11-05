-- When a ride ends, on the real Ride, Mapping, Contact and ForceStage with constructed bodies and wheel rays:
-- a ramp is not a fall, a fall on the ground ends, a body in the air gets its time, and a hit goes over the bars.
-- Constructed SDK transport, no Host and no game; the bodies here are posed, not simulated.
local Ride=require("./ride_runtime_qualified_fixture")
local Mapping=require("./ride_input_mapping")
local Contact=require("./contact_runtime")
local Stage=require("./force_stage")
local Forces=require("./forces")
local Geometry=require("./bike_geometry")
local Visual=require("./bike_visual")
local Identity=require("./lease_identity")
local M=require("./force_math")
local MP=require("./mounted_pose")
local World=require("./sim_world")
local T={}
local h=Forces.native_seconds
local R=Geometry.wheel_radius
local function roll_of(angle) return {0,0,math.sin(angle/2),math.cos(angle/2)} end
local function pitch_of(angle) return {math.sin(angle/2),0,0,math.cos(angle/2)} end
-- ground(from,to) answers each ray with a row or {status="clear"}.
local function harness(ground)
    local body,incarnation,lease,epoch=newproxy(),newproxy(),newproxy(),newproxy()
    local w={serial=1000,time=1,submits={},requested={},samples={},ground=ground,by_serial={}}
    local api={}
    function api.probe_batch(got,plan)
        if w.unreadable and #plan==4 then
            return {status="unavailable",reason="contact_measurement_unavailable",epoch=got,native_casts=#plan,budget_exhausted=false,
                local_actor_excluded=false,owned_bodies_excluded=true,requested_query_preset="camera",named_actor_categories_absent=false}
        end
        local rays={}
        for i,ray in ipairs(plan) do rays[i]=w.ground(ray.from,ray.to,#plan,i) end
        return {status="available",epoch=got,native_casts=#plan,budget_exhausted=false,local_actor_excluded=false,
            owned_bodies_excluded=true,requested_query_preset="camera",named_actor_categories_absent=true,rays=rays}
    end
    local sequence=5000
    function api.submit(_,value)
        sequence+=1
        w.submits[#w.submits+1]=value
        w.by_serial[w.serial]=value
        w.requested[tostring(sequence)]=tostring(w.serial)
        return true,nil,tostring(sequence)
    end
    -- Queued until its serial has passed, then applied with the sample two steps on, as the SDK reports it.
    -- w.prompt answers on the next serial instead, as the game did in every ride step measured.
    function api.receipt(got)
        local requested=w.requested[got]
        local at=tonumber(requested)
        if w.serial<=at+(w.prompt and 0 or 1) then
            return {sequence=got,requested_serial=requested,produced_serial="0",outcome="queued",force_attempted=false,
                torque_attempted=false,retained=false,quarantined=false,cleanup_disposition="none"}
        end
        return {sequence=got,requested_serial=requested,produced_serial=tostring(at+1),outcome="applied",force_attempted=true,
            torque_attempted=true,retained=false,quarantined=false,cleanup_disposition="none",successor=w.samples[at+2]}
    end
    function api.acknowledge() return true end
    local pad={left_x=0,left_y=0,right_x=0,right_y=0,left_trigger=0,right_trigger=0,playstation=false,
        buttons={a=false,b=false,right_stick=false,lb=false,rb=false}}
    local source={input_ok=true,phase="capturing",generation=1,lease_handle=lease,
        sample={user=0,sequence="77",source_epoch="78",context_generation="79",observation_serial="80",observed_ms="1000",packet=9,pad=pad}}
    -- The real stage, behind a recorder of the controls Ride sends it and the step it previews from them.
    local stage=Stage.new()
    local force={hop_policy=stage.hop_policy,tuning=stage.tuning}
    function force.preview(_,...)
        w.controls=select(5,...)
        local model,candidate=stage:preview(...)
        w.model=model
        return model,candidate
    end
    function force._adopt(_,...) return stage:_adopt(...) end
    function force.invalidate_continuity() return stage:invalidate_continuity() end
    function force.admit_measured(_,...) return stage:admit_measured(...) end
    function force.reset() return stage:reset() end
    local ride=Ride.new(api,{mapping=Mapping.new(),force=force,contact=Contact},{body_handle=body,incarnation=incarnation})
    w.ride=ride
    function w.press_a()
        local pressed=table.clone(pad)
        pressed.buttons=table.clone(pad.buttons);pressed.buttons.a=true
        source={input_ok=true,phase="capturing",generation=1,lease_handle=lease,
            sample={user=0,sequence="77",source_epoch="78",context_generation="79",observation_serial="81",observed_ms="1016",packet=10,pad=pressed}}
    end
    -- From now on every step brings a fresh pad observation a native step on, with the right stick here, and the left
    -- stick across when given.
    local fresh
    function w.set_pad(right_y,left_x,a)
        local moved=table.clone(pad)
        moved.buttons=table.clone(pad.buttons);moved.right_y=right_y
        if left_x then moved.left_x=left_x end
        if a then moved.buttons.a=true end
        fresh=fresh or {serial=80}
        fresh.pad=moved
    end
    function w.step(pose)
        if fresh then
            fresh.serial+=1
            source={input_ok=true,phase="capturing",generation=1,lease_handle=lease,
                sample={user=0,sequence="77",source_epoch="78",context_generation="79",observation_serial=tostring(fresh.serial),
                    observed_ms=tostring(1000+math.floor((fresh.serial-80)*h*1000+.5)),packet=fresh.serial,pad=fresh.pad}}
        end
        w.serial+=1;w.time+=h
        local v,a=pose.velocity or {0,0,0},pose.angular_velocity or {0,0,0}
        local p=pose.position
        local raw={epoch=epoch,serial=tostring(w.serial),time=w.time,seconds=h,mass=Geometry.mass,
            position=vector.create(p[1],p[2],p[3]),velocity=vector.create(v[1],v[2],v[3]),
            angular_velocity=vector.create(a[1],a[2],a[3]),inertia=vector.create(26,32,10),rotation=pose.rotation}
        w.samples[w.serial]=raw
        return ride:observe(source,raw,{now_ms=1000,focused=true,menu_open=false,loaded=true})
    end
    -- A step of a body that moves: Ride observes b, and b moves on by the packet Ride sent the step before, so a
    -- packet made from one sample acts between the next two, as the game applies it. Returns Ride's result and b moved.
    function w.ride_step(b)
        local out=w.step({position=b.center_of_mass,velocity=b.linear_velocity,angular_velocity=b.angular_velocity,rotation=b.orientation})
        local sent=w.by_serial[w.serial-1]
        local packet={force={0,0,0},torque={0,0,0},hop_impulse={0,0,0}}
        if sent then
            packet.force={sent.force.x,sent.force.y,sent.force.z}
            packet.torque={sent.torque.x,sent.torque.y,sent.torque.z}
            if sent.impulse then packet.hop_impulse={sent.impulse.x,sent.impulse.y,sent.impulse.z} end
        end
        return out,World.integrate(b,packet,Forces.tuning().gravity,h)
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
-- A face across the road at z, facing back along -z unless told otherwise, met only by rays running along z: the rays
-- ahead of the bike. Everything else lands on flat ground.
local function face(z,normal,min_x)
    normal=normal or {0,0,-1}
    return function(from,to)
        if math.abs(to.z-from.z)>math.abs(to.x-from.x) and math.abs(to.z-from.z)>4*math.abs(to.y-from.y) then
            local f=(z-from.z)/(to.z-from.z)
            if f<0 or f>1 or min_x and from.x+(to.x-from.x)*f<min_x then return clear() end
            return {status="hit",position=vector.create(from.x+(to.x-from.x)*f,from.y,z),fraction=f,
                normal=vector.create(normal[1],normal[2],normal[3]),surface_velocity=vector.create(0,0,0),
                normal_available=true,surface_velocity_available=true,motion="measured"}
        end
        return flat(from,to)
    end
end
-- A face through (0, 0, z) turned this many degrees about up, facing back toward a bike coming along +z, met only by
-- rays running along the road.
local function turned(z,degrees)
    local a=math.rad(degrees)
    local n={-math.sin(a),0,-math.cos(a)}
    return function(from,to)
        local dx,dy,dz=to.x-from.x,to.y-from.y,to.z-from.z
        if math.sqrt(dx*dx+dz*dz)>4*math.abs(dy) then
            local across=dx*n[1]+dz*n[3]
            if math.abs(across)<1e-9 then return clear() end
            local f=(-from.x*n[1]+(z-from.z)*n[3])/across
            if f<0 or f>1 then return clear() end
            return {status="hit",position=vector.create(from.x+dx*f,from.y+dy*f,from.z+dz*f),fraction=f,
                normal=vector.create(n[1],n[2],n[3]),surface_velocity=vector.create(0,0,0),
                normal_available=true,surface_velocity_available=true,motion="measured"}
        end
        return flat(from,to)
    end,n
end
-- A road whose height along it is height(z), with slope(z) its gradient: each ray is marched to where it first meets it.
local function profile(height,slope)
    return function(from,to)
        local function above(f) return from.y+(to.y-from.y)*f-height(from.z+(to.z-from.z)*f) end
        if above(0)<0 then return clear() end
        local a,b=nil,nil
        for k=1,96 do if above(k/96)<=0 then a,b=(k-1)/96,k/96 break end end
        if not a then return clear() end
        for _=1,50 do local middle=(a+b)/2 if above(middle)>0 then a=middle else b=middle end end
        local f=(a+b)/2
        local z=from.z+(to.z-from.z)*f
        local n=M.unit({0,1,-slope(z)})
        return {status="hit",position=vector.create(from.x+(to.x-from.x)*f,from.y+(to.y-from.y)*f,z),fraction=f,
            normal=vector.create(n[1],n[2],n[3]),surface_velocity=vector.create(0,0,0),normal_available=true,
            surface_velocity_available=true,motion="measured"}
    end
end
-- The front of the front tyre of a level bike whose centre of mass is at z = 0.
local NOSE=Geometry.front_axle[3]+R-Geometry.com[3]
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
    case(function() -- Up a quarter pipe: 70 degrees from world up, square to the surface under the wheels.
        local rotation=pitch_of(-math.rad(70))
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
        local n=M.unit({0,.35,-.94})
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
        local rays=harness(function(from,to) return hit(from,to,from.y-R-.3,{0,1,0}) end)
        check(steps(rays,{position={0,9,0},rotation=roll_of(math.rad(70))},120)==90,"a ray landing far below is still the air")
    end)
    case(function() -- Time in the air does not spend a landing's chance to be saved.
        local w=harness(clear)
        local over={position={0,.45,0},rotation=roll_of(math.rad(70))}
        check(steps(w,over,30)==nil,"30 steps in the air")
        w.ground=flat
        local at=steps(w,over,40)
        check(at==18,"the landing still gets its .3 s: "..tostring(at))
    end)
    case(function() -- A fall that keeps losing and finding its wheels still ends.
        local odd=false
        local w=harness(function(from,to,count,i)
            if i==1 then odd=not odd end
            return odd and flat(from,to) or clear()
        end)
        local at=steps(w,{position={0,.228,0},rotation=roll_of(math.rad(90))},120)
        check(at~=nil and at<=36,"coming back in bounds is the only way out: "..tostring(at))
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
        check(steps(w,pose,3)==nil and w.submits[#w.submits].torque.x>0,"the rider's weight carries the nose down")
        local at,out=steps(w,pose,80)
        check(at~=nil and at>=50 and at<=61,"a bike that cannot go over still ends: "..tostring(at))
        check(string.match(out.issue,"^hit something at 7%.%d m/s$")~=nil,"and says so: "..tostring(out.issue))
        local back=harness(flat)
        pose=level()
        pose.velocity={0,0,-6}
        check(steps(back,pose,4)==nil,"rolling backward")
        pose.velocity={0,0,-.5}
        check(steps(back,pose,5)==nil and back.submits[#back.submits].torque.x<0,"backward into something, the tail goes down")
        local pedalling=harness(flat)
        pose=level()
        pose.velocity={0,0,5}
        check(steps(pedalling,pose,3)==nil,"rolling")
        pedalling.press_a()
        check(steps(pedalling,pose,6)==nil and pedalling.submits[#pedalling.submits].force.z>100,"A drives the bike")
        pose.velocity={0,0,.5}
        check(steps(pedalling,pose,10)==nil and pedalling.submits[#pedalling.submits].force.z<50,"and stops driving it once it has hit something")
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
        check(steps(w,pose,70)==nil,"and it does not end the ride a second later")
        local landing=harness(flat)
        pose=level()
        for i=0,3 do
            pose.velocity={0,0,7.5-i*1.9}
            check(not landing.step(pose).stop_requested,"nor is the landing cap")
        end
        check(steps(landing,pose,70)==nil,"nor does that end it later")
        local least=harness(flat)
        pose=level()
        for i=0,3 do
            pose.velocity={0,0,8-i*2}
            least.step(pose)
        end
        check(steps(least,pose,70)~=nil,"4 m/s in two steps is the world, not the kernel")
    end)
    case(function() -- A kerb the ray lands under keeps its wheel: a held row, not a clear one, down to the floor for a flat top.
        for _,depth in ipairs({.15,.22}) do
            local w=harness(function(from,to,count,i)
                local y=from.y-R
                if i==1 then y+=depth end
                return hit(from,to,y,{0,1,0})
            end)
            local out=w.step(level())
            check(not out.stop_requested,"a wheel riding onto a step of "..depth.." is admitted: "..tostring(out.issue))
            local command=w.submits[1]
            check(command~=nil and command.force.y>2000 and command.torque.x<0,"and the front wheel pushes back, lifting the nose")
        end
        local w=harness(function(from,to,count,i)
            local y=from.y-R
            if i==1 then y+=.25 end
            return hit(from,to,y,{0,1,0})
        end)
        check(not w.step(level()).stop_requested,"past the floor it reads clear, as a wall does")
        check(w.submits[1].torque.x>0,"so only the rear wheel is under it")
    end)
    case(function() -- A kerb is drawn on its top, not through it. The drawn bike follows the rays; the body, its rays and its pushes do not.
        local function kerbed(kerb)
            local w
            w=harness(function(from,to,count,i)
                if count~=2 then return flat(from,to) end
                if i==1 then w.front_from[#w.front_from+1]=from end
                local depth=kerb[i]
                if depth==false then return clear() end
                return hit(from,to,from.y-R+(depth or 0),{0,1,0})
            end)
            -- Every push is taken on the next step, so every step draws a new pose.
            w.front_from,w.prompt={},true
            return w
        end
        -- How far each hub is drawn up off the body, and the pose that draws it.
        local function drawn(out)
            local pose=out.presentation_pose
            if pose.movement_bike_lift==nil then return 0,0,pose end
            local front,rear=Geometry.hub_rise(Geometry,pose.movement_bike_pitch,pose.movement_bike_lift)
            return front,rear,pose
        end
        -- Bodies and rays come as native single-precision vectors.
        local function near(a,b) return math.abs(a-b)<1e-5 end
        local function fields(pose) local count=0 for _ in pairs(pose) do count+=1 end return count end
        -- How far a wheel's tyre is drawn from where it touches the road drawn on the body: the lowest point of its
        -- disc, the body being level.
        local function touch(m)
            local axle=M.unit({m[1],m[2],m[3]})
            local toward=M.unit(M.sub({0,-1,0},M.mul(axle,-axle[2])))
            return M.add({m[13],m[14],m[15]},M.mul(toward,R))
        end
        local function moved(sample,pose,part)
            return M.sub(touch(Visual.from_sample(sample,pose)[part]),touch(Visual.from_sample(sample)[part]))
        end
        local kerb={[1]=.15}
        local w=kerbed(kerb)
        local deep={[1]=.20}
        local twin=kerbed(deep)
        local rises={}
        for i=1,4 do
            local out=w.step(level())
            check(not out.stop_requested,"riding onto the kerb: "..tostring(out.issue))
            local front,rear,pose=drawn(out)
            rises[i]=front
            check(near(rear,0) and pose.movement_bike_pitch<0,"only the front is lifted, nose up")
            twin.step(level())
        end
        check(near(rises[1],.05) and near(rises[2],.10) and near(rises[3],.14) and near(rises[4],.14),
            "the front comes up 5 cm a step to a centimetre under the kerb top: "..table.concat(rises," "))
        local pose=select(3,drawn(w.step(level())))
        local matrices=Visual.from_sample(w.samples[w.serial],pose)
        check(matrices~=nil,"the visual draws the lifted pose")
        local bottom=matrices[4][14]-R
        check(near(bottom,.15-.01),"the drawn tyre sits on the kerb, its bottom at "..bottom.." against a top at .15")
        -- The bike is drawn turned about the rear wheel, which is still on the road where the physics has it. The front
        -- comes in by what the climb shortens the wheelbase seen from above, a centimetre, on the kerb's flat top.
        local rear_touch=moved(w.samples[w.serial],pose,3)
        check(M.length(rear_touch)<.01,
            string.format("the rear tyre touches the road within 1 cm of the body's: %.4f %.4f %.4f",rear_touch[1],rear_touch[2],rear_touch[3]))
        local front_touch=moved(w.samples[w.serial],pose,4)
        check(near(front_touch[2],.14) and front_touch[3]<0 and front_touch[3]>-.011 and math.abs(front_touch[1])<1e-5,
            string.format("and the front tyre is drawn on the kerb top, %.4f back of the body's",-front_touch[3]))
        check(near(select(1,drawn(twin.step(level()))),.19),"a deeper kerb is drawn higher")
        check(#w.submits==5 and #twin.submits==5,"every step was pushed")
        for i=1,5 do
            check(w.submits[i].force==twin.submits[i].force and w.submits[i].torque==twin.submits[i].torque,
                "but pushed the same, as the kernel holds both wheels at the same depth: the drawn lift is not physics")
        end
        for i=2,#w.front_from do
            check(w.front_from[i]==w.front_from[1],"the rays start from the body's own hub, wherever the wheel is drawn")
        end
        kerb[1]=false
        check(near(select(1,drawn(w.step(level()))),.09),"a ray that drops out for a step lowers the wheel 5 cm, not all the way")
        kerb[1]=.15
        check(near(select(1,drawn(w.step(level()))),.14),"and it comes back up")
        kerb[1]=nil
        local down={}
        for i=1,3 do down[i]=select(1,drawn(w.step(level()))) end
        check(near(down[1],.09) and near(down[2],.04) and down[3]==0,"off the kerb it comes down the same way: "..table.concat(down," "))
        local settled=w.step(level()).presentation_pose
        check(settled.movement_bike_pitch==0 and settled.movement_bike_lift==nil and fields(settled)==8,
            "and the pose is ordinary riding's eight fields again")
        local rear_kerb=kerbed({[2]=.15})
        local front,rear,lifted
        for _=1,3 do front,rear,lifted=drawn(rear_kerb.step(level())) end
        check(near(front,0) and near(rear,.14) and lifted.movement_bike_pitch>0,"a rear wheel on the kerb draws the nose down")
        local front_touch=moved(rear_kerb.samples[rear_kerb.serial],lifted,4)
        check(M.length(front_touch)<.01,string.format("about the front wheel, which touches the road within 1 cm of the body's: %.4f %.4f %.4f",
            front_touch[1],front_touch[2],front_touch[3]))
        local stopped=rear_kerb.ride:stop("constructed stop")
        check(stopped.presentation_pose.movement_bike_pitch==0 and stopped.presentation_pose.movement_bike_lift==nil
            and stopped.presentation_pose.movement_bike_shift==nil,"a stopped ride draws the bike on its body again")
        local rolling=harness(flat)
        rolling.prompt=true
        local sunk=level();sunk.position[2]-=.005
        for _=1,20 do
            local out=rolling.step(sunk)
            check(out.presentation_pose.movement_bike_pitch==0 and fields(out.presentation_pose)==8,
                "a tyre 5 mm into the road, as rolling sinks it, draws nothing")
        end
    end)
    case(function() -- The forecast can carry a wheel past the depth the kernel admits, in a step its ray did not.
        local w=harness(flat)
        local pose=level()
        pose.position={0,pose.position[2]-.09,0}
        pose.velocity={0,-5,0}
        check(not w.step(pose).stop_requested and #w.submits==1,"a hard landing is held, not refused")
    end)
    local function pushed(w) return w.submits[#w.submits].force.z end
    -- Rides a level bike at a face, its pushes moving it: a command acts on the sample two steps after the one it
    -- was sent on, as the transport reports it. Returns the harness, the stop if any, how far the tyre got past the
    -- face at most, and the speed it ends on.
    local function ride_in(speed,gap,count,pedal)
        local w=harness(face(NOSE+gap),pedal)
        w.prompt=true
        local pose=level();pose.velocity={0,0,speed}
        local sent,deepest,track={},-gap,{}
        for i=1,count do
            if sent[i-2] then pose.velocity[3]+=sent[i-2]*h/Geometry.mass end
            pose.position[3]+=pose.velocity[3]*h
            deepest=math.max(deepest,pose.position[3]-gap)
            track[i]={pose.position[3]-gap,pose.velocity[3]}
            local before=#w.submits
            local at,out=steps(w,pose,1)
            if at then return w,out,deepest,pose.velocity[3],track end
            sent[i]=#w.submits>before and w.submits[#w.submits].force.z or 0
        end
        return w,nil,deepest,pose.velocity[3],track
    end
    for _,speed in ipairs({.6,1,3}) do
        case(function() -- Nosed in below a hit: stopped at the face, a small bounce back, and the ride goes on.
            local _,stopped,deepest,ends=ride_in(speed,.5,240)
            check(stopped==nil,"a bump at "..speed.." m/s is not a crash: "..tostring(stopped and stopped.issue))
            check(deepest<=.03,"the tyre stops at the face at "..speed.." m/s: "..deepest)
            check(ends>-.35*speed,"and does not bounce off harder than it came in: "..ends)
        end)
    end
    case(function() -- Braked no earlier than the stop needs: half a metre out, a bike at 7.6 m/s still has most of its speed.
        local _,_,_,_,track=ride_in(7.6,3,200)
        local at
        for _,row in ipairs(track) do if row[1]>=-.5 then at=row[2] break end end
        check(at and at>6,"half a metre from the car it is still going: "..tostring(at))
    end)
    case(function() -- A look the lane could not read loses nothing: the crash already coming still comes.
        local w=harness(face(NOSE+.6))
        w.prompt=true
        local pose=level();pose.velocity={0,0,7.4}
        check(steps(w,pose,3)==nil,"braking for the car")
        -- Braked below a hit's speed while the looks go unread, no faster than a hit takes it off (HIT_DROP).
        w.unreadable=true
        pose.velocity={0,0,5.5}
        check(steps(w,pose,1)==nil,"one look unread")
        pose.velocity={0,0,3.7}
        check(steps(w,pose,1)==nil,"and another")
        w.unreadable=false
        local near=level();near.position[3]=.5;near.velocity={0,0,3.7}
        local at,out=steps(w,near,80)
        check(at and out.issue=="hit something at 7.4 m/s","the crash comes at the bumper: "..tostring(out and out.issue))
    end)
    case(function() -- Going over the bars, the bike is stopped where it is at the car, not slid along its face, and only near it.
        local w=harness(face(NOSE+.1,M.unit({-.7,0,-.7})))
        w.prompt=true
        local pose=level();pose.velocity={0,0,7.4}
        check(steps(w,pose,1)==nil,"the crash begins at the corner")
        pose.rotation=pitch_of(-math.rad(40));pose.velocity={0,0,2}
        check(steps(w,pose,1)==nil,"going over")
        local f=w.submits[#w.submits].force
        check(f.z<-4000 and f.x>-1500,"held where it is, not pushed along the corner: "..f.x.." "..f.z)
        local away=level();away.position[3]=-5;away.velocity={0,0,2}
        away.rotation=pitch_of(-math.rad(40))
        check(steps(w,away,1)==nil and w.submits[#w.submits].force.z>-2500,"five metres off, the car holds nothing: "..w.submits[#w.submits].force.z)
    end)
    case(function() -- A tight quarter pipe met from flat: the low ray finds the ramp first, so the steep face above is the same curve.
        local function quarter(ahead_of)
            local w=harness(function(from,to,count,i)
                if math.abs(to.z-from.z)>4*math.abs(to.y-from.y) and math.abs(to.z-from.z)>math.abs(to.x-from.x) then
                    if from.y<.3 then return face(NOSE+.2,M.unit({0,.7,-.71}))(from,to) end
                    return ahead_of(from,to)
                end
                return flat(from,to)
            end)
            local pose=level();pose.velocity={0,0,7}
            check(steps(w,pose,20)==nil,"the bike rides at it")
            return pushed(w)
        end
        local walled,open=quarter(face(NOSE+.6,M.unit({0,.17,-.98}))),quarter(flat)
        check(math.abs(walled-open)<500,"a quarter pipe ahead of the tyre is not a wall: "..walled.." against "..open)
    end)
    case(function() -- A car met at an angle: the gap is from the tyre, square to the car, not from where the travel points.
        local function angled(ground)
            local w=harness(ground)
            local pose=level();pose.velocity={4,0,7}
            check(steps(w,pose,20)==nil,"the bike rides at it")
            return pushed(w)
        end
        local walled,open=angled(face(NOSE+.6)),angled(flat)
        check(walled-open<-4500,"braked for the car the tyre is about to reach: "..walled.." against "..open)
    end)
    case(function() -- A corner only a bar end will meet is still met.
        local w=harness(face(.36-Geometry.com[3]+.1,nil,.2))
        local pose=level();pose.velocity={0,0,3}
        check(steps(w,pose,1)==nil and pushed(w)<-1000,"the bar end's lane stops the bike: "..pushed(w))
    end)
    case(function() -- A parked car at 7.4 m/s: braked hard, over the bars at the bumper, and held there.
        local _,stopped,deepest=ride_in(7.4,3,200)
        check(stopped and stopped.issue:match("^hit something at [67]%.%d m/s$"),"it is a crash: "..tostring(stopped and stopped.issue))
        check(deepest<=.1,"and the bike does not go on into the car: "..deepest)
    end)
    case(function() -- A car at 7.4 m/s within sight but not yet needing a stop asks nothing.
        local w=harness(face(NOSE+1.2))
        local pose=level();pose.velocity={0,0,7.4}
        check(steps(w,pose,20)==nil and math.abs(pushed(w))<500,"nothing before it is needed: "..pushed(w))
    end)
    case(function() -- Braking for a car and then hopping or steering off it before the bumper is no crash.
        local w=harness(face(NOSE+.6))
        local pose=level();pose.velocity={0,0,7.4}
        check(steps(w,pose,3)==nil and pushed(w)<-3000,"the bike brakes for the car")
        w.ground=flat
        check(steps(w,pose,90)==nil,"and once the car is no longer ahead the ride goes on")
    end)
    case(function() -- Going over the bars tips the rays off the car: the face it hit still holds the bike.
        local w=harness(face(NOSE+.1))
        local pose=level();pose.velocity={0,0,7.4}
        check(steps(w,pose,1)==nil,"the crash begins at the bumper")
        pose.rotation=pitch_of(-math.rad(40))
        check(steps(w,pose,3)==nil and pushed(w)<-3000,"pitched over, it is still held off the car: "..pushed(w))
    end)
    case(function() -- A car met at an angle is pushed off along its own face.
        local w=harness(face(NOSE+.2,M.unit({-.5,0,-.87})))
        local pose=level();pose.velocity={0,0,5}
        check(steps(w,pose,1)==nil and w.submits[#w.submits].force.x<-1000,"the push follows the face")
    end)
    case(function() -- Pedalling into a car it is against does not drive it on.
        local w=harness(face(NOSE+.02))
        local pose=level();pose.velocity={0,0,.1}
        check(steps(w,pose,3)==nil,"a bike against a car is ridden")
        w.press_a()
        check(steps(w,pose,6)==nil and pushed(w)<50,"pedalling stops at the bumper: "..pushed(w))
        local free=harness(flat)
        check(steps(free,pose,3)==nil,"the same bike on open ground")
        free.press_a()
        check(steps(free,pose,6)==nil and pushed(free)>100,"is driven by A: "..pushed(free))
    end)
    case(function() -- A ramp or a bank across the way is ridden up, not stopped at, even met fast and close.
        local w=harness(face(NOSE+.02,M.unit({0,.8,-.6})))
        local pose=level();pose.velocity={0,0,7}
        check(steps(w,pose,20)==nil and math.abs(pushed(w))<500,"a face this far from steep is a ramp: "..pushed(w))
    end)
    case(function() -- Up a tight quarter pipe the front wheel is already on: what is ahead is the same curve, steep only to the bike.
        local under=M.unit({0,.64,-.77})
        local function climbing(ahead)
            local w=harness(function(from,to,count,i)
                if count==2 and i==1 then return hit(from,to,0,under) end
                return ahead(from,to)
            end)
            local pose=level();pose.velocity={0,0,5}
            check(steps(w,pose,20)==nil,"the bike rides up it")
            return pushed(w)
        end
        local walled,open=climbing(face(NOSE+.1,M.unit({0,.34,-.94}))),climbing(flat)
        check(math.abs(walled-open)<500,"a face the front wheel is climbing is not a wall: "..walled.." against "..open)
    end)
    case(function() -- Already a little into a face at walking pace: pushed back out, by about a quarter of the way it came in.
        local w=harness(face(NOSE-.02))
        local pose=level();pose.velocity={0,0,.5}
        check(steps(w,pose,6)==nil and pushed(w)<-3000 and pushed(w)>-4800,"a soft bounce: "..pushed(w))
    end)
    case(function() -- A wall met at a glance is ridden along.
        local w=harness(face(NOSE+.05,M.unit({.97,0,-.24})))
        local pose=level();pose.velocity={0,0,7}
        check(steps(w,pose,20)==nil and math.abs(pushed(w))<500,"a glancing wall is not stopped at: "..pushed(w))
    end)
    case(function() -- Riding away from the car it just stopped at: nothing holds the bike back.
        local w=harness(face(NOSE+.05))
        local pose=level();pose.velocity={0,0,-1}
        check(steps(w,pose,20)==nil and math.abs(pushed(w))<500,"rolling back from a face is let go: "..pushed(w))
    end)
    -- Rolls a bike along z, pedal off, over ground(z), which gives the height there and the slope dy/dz. Each hub
    -- rolls a wheel radius off the plane its ray found the step before, so it meets a new surface a step after its
    -- ray does, as a hub's ray does in game: a kerb is under the ray while the wheel is still at road height, and a
    -- hill is followed. lift(i), if given, raises both hubs that far off those planes on step i, at a vertical speed;
    -- wheels in the air keep the planes they left, and come down onto whatever is under them. ahead, if given,
    -- answers the rays along the road; they find nothing otherwise. Commands move the bike along z two steps after
    -- they are sent. Returns the speed after each step, for each wheel the steps it struck a kerb on and the height
    -- it struck, and the push along z each step sent.
    local AXLES=Geometry.front_axle[3]-Geometry.rear_axle[3]
    local function roll_over(ground,speed,count,lift,ahead)
        local w=harness(function(from,to)
            if math.abs(to.y-from.y)<math.abs(to.z-from.z) then return ahead and ahead(from,to) or clear() end
            local y,k=ground(from.z)
            return hit(from,to,y,M.unit({0,1,-k}))
        end)
        w.prompt=true
        local z,v,sent,speeds,struck,last,flying=0,speed,{},{},{{},{}},{},false
        local function height(wheel,at)
            local g=last[wheel] or {at,ground(at)}
            return g[2]+g[3]*(at-g[1])+R*math.sqrt(1+g[3]*g[3])
        end
        for i=1,count do
            if sent[i-2] then v+=sent[i-2]*h/Geometry.mass end
            z+=v*h
            local up,climb=0,0
            if lift then up,climb=lift(i) end
            if up~=0 then flying=true elseif flying then flying=false;table.clear(last) end
            local rear,pitch=height(2,z)+up,0
            for _=1,4 do pitch=math.asin((height(1,z+AXLES*math.cos(pitch))+up-rear)/AXLES) end
            local front=z+AXLES*math.cos(pitch)
            if up==0 then last[1],last[2]={front,ground(front)},{z,ground(z)} end
            local rotation=pitch_of(-pitch)
            local before=#w.submits
            local out=w.step({position=M.add({0,rear,z},M.turn(rotation,M.sub(Geometry.com,Geometry.rear_axle))),
                rotation=rotation,velocity={0,climb,v}})
            check(not out.stop_requested,"the bike rides on: "..tostring(out.issue))
            local row=out.metrics.samples[#out.metrics.samples]
            if row.front_curb then table.insert(struck[1],{i,row.front_curb}) end
            if row.rear_curb then table.insert(struck[2],{i,row.rear_curb}) end
            sent[i]=#w.submits>before and w.submits[#w.submits].force.z or 0
            speeds[i]=v
        end
        return speeds,struck,sent
    end
    local function kerb(edge,top) return function(z) return z>=edge and top or 0,0 end end
    local function ramp(edge,slope) return function(z) if z<edge then return 0,0 end return (z-edge)*slope,slope end end
    local function none(struck) return #struck[1]==0 and #struck[2]==0 end
    local STEPS=90
    local road=roll_over(kerb(math.huge,0),7.4,STEPS)
    for _,top in ipairs({.15,.18}) do
        case(function() -- A kerb costs speed, once a wheel, as a tyre striking a step does.
            local speeds,struck=roll_over(kerb(3,top),7.4,STEPS)
            check(#struck[1]==1 and #struck[2]==1,"each wheel strikes a "..top.." m kerb once: "..#struck[1].." "..#struck[2])
            local front,rear=struck[1][1],struck[2][1]
            check(math.abs(front[2]-top)<.005 and math.abs(rear[2]-top)<.005,"as high as it is: "..front[2].." "..rear[2])
            local function lost(i) return road[i]-speeds[i] end
            -- A quarter of the speed per wheel radius of kerb, less what the still spinning wheels give back.
            local first=.25*speeds[front[1]]*top/R
            local second=first+.25*speeds[rear[1]]*top/R
            check(lost(front[1])<.01,"nothing before the front wheel reaches it: "..lost(front[1]))
            check(lost(rear[1]-1)>.85*first and lost(rear[1]-1)<=first,"the front wheel's share: "..lost(rear[1]-1).." of "..first)
            check(lost(rear[1]+6)>.85*second and lost(rear[1]+6)<=second,"and the rear wheel's: "..lost(rear[1]+6).." of "..second)
            check(math.abs(lost(STEPS)-lost(rear[1]+6))<.1,"and nothing more on top of it")
        end)
    end
    case(function() -- A 2 cm step in the road is ridden over for nothing.
        local speeds,struck=roll_over(kerb(3,.02),7.4,STEPS)
        check(none(struck) and math.abs(road[STEPS]-speeds[STEPS])<.02,"no strike: "..#struck[1].." "..#struck[2])
    end)
    case(function() -- A plain hill costs nothing, met from flat at the speed whose rise in a step reads as a kerb's.
        for _,degrees in ipairs({4,12,17}) do
            for phase=0,4 do
                local _,struck=roll_over(ramp(3+phase*.025,math.tan(math.rad(degrees))),7.4,STEPS)
                check(none(struck),"a "..degrees.." degree ramp is no kerb: "..#struck[1].." "..#struck[2].." at "..phase)
            end
        end
    end)
    -- Comes down at 3 m/s from 26.5 cm, through the ground it left on step 27, onto what is under it on step 28.
    local function drop(i)
        if i<=20 or i>27 then return 0,0 end
        return .265-(i-21)*.05,-3
    end
    case(function() -- A landing closes its gaps as fast as a kerb, onto ground that stays where it was.
        local speeds,struck=roll_over(kerb(math.huge,0),7.4,STEPS,drop)
        check(none(struck) and math.abs(road[STEPS]-speeds[STEPS])<.05,"a landing is no kerb: "..#struck[1].." "..#struck[2])
    end)
    case(function() -- A landing on a knuckle, a flat deck turning down a slope, is no kerb either.
        -- The front hub is over the deck's edge as it lands, at each point of one step's travel. A ray that crosses the
        -- edge then finds a point above the slope's plane carried back, as a kerb's top is, but under the deck's.
        local reach=AXLES
        for i=1,27 do reach+=road[i]*h end
        for _,degrees in ipairs({15,16,17}) do
            for phase=0,10 do
                local _,struck=roll_over(ramp(reach-phase*.0125,-math.tan(math.rad(degrees))),7.4,STEPS,drop)
                check(none(struck),"a knuckle at "..degrees.." degrees is no kerb: "..#struck[1].." "..#struck[2].." at "..phase
                    ..(struck[1][1] and " struck "..struck[1][1][2] or ""))
            end
        end
    end)
    local function hop(lift) return function(i) return i>12 and i<=32 and lift or 0,0 end end
    case(function() -- Hopped up a kerb, the wheels pass its edge in the air and strike nothing.
        local _,struck=roll_over(kerb(3,.15),7.4,STEPS,hop(.25))
        check(none(struck),"a hop up a kerb costs nothing: "..#struck[1].." "..#struck[2])
        -- Nor when the tyres clear its top by only 2 cm.
        _,struck=roll_over(kerb(3,.15),7.4,STEPS,hop(.17))
        check(none(struck),"a hop that just clears a kerb costs nothing: "..#struck[1].." "..#struck[2])
    end)
    case(function() -- A hop that falls short of a kerb strikes it, with the part of it the tyres did not clear.
        for _,lift in ipairs({.04,.10}) do
            local speeds,struck=roll_over(kerb(3,.15),7.4,STEPS,hop(lift))
            local base=roll_over(kerb(math.huge,0),7.4,STEPS,hop(lift))
            check(#struck[1]==1 and #struck[2]==1,"each wheel hopped "..lift.." m strikes a .15 m kerb once: "..#struck[1].." "..#struck[2])
            local front,rear=struck[1][1],struck[2][1]
            local short=.15-lift
            check(front and rear and math.abs(front[2]-short)<.005 and math.abs(rear[2]-short)<.005,
                "as much as it fell short: "..tostring(front and front[2]).." "..tostring(rear and rear[2]).." of "..short)
            -- A quarter of the speed per wheel radius of that, a wheel, against the same hop over the bare road.
            local owed=.25*speeds[front[1]]*short/R+.25*speeds[rear[1]]*short/R
            local lost=base[STEPS]-speeds[STEPS]
            check(lost>.85*owed and lost<=owed,"and the speed it owes: "..lost.." of "..owed)
        end
    end)
    -- Held over the road, then coming down at 3 m/s, 5 cm a step: the tyres are over a kerb's top by over on step at-1,
    -- 5 cm lower on step at, and on whatever is under them from the step after.
    local function fall(over,at)
        return function(i)
            if i<=12 or i>at then return 0,0 end
            local left=math.min(at-1-i,2)
            return .15+over+.05*left,left<2 and -3 or 0
        end
    end
    -- Where a kerb's edge lies phase of the way along the front hub's travel on step at, for that lift.
    local function edge_at(lift,at,phase)
        local speeds=roll_over(kerb(math.huge,0),7.4,STEPS,lift)
        local reach=AXLES
        for i=1,at-1 do reach+=speeds[i]*h end
        return reach+phase*speeds[at]*h
    end
    case(function() -- A hop coming down onto a kerb's top pays for what the tyre did not clear at the edge, not for landing.
        -- The front hub passes the edge as the tyres come down: a tenth to three tenths of the way through the step.
        for _,phase in ipairs({.1,.2,.3}) do
            -- 2 cm over the top a step before, 0.5 to 1.5 cm over it at the edge, then 3 cm into the top as it lands.
            local lift=fall(.02,19)
            local _,struck=roll_over(kerb(edge_at(lift,19,phase),.15),7.4,STEPS,lift)
            check(#struck[1]==0,"a front tyre over the top at the edge strikes nothing: "..#struck[1]
                ..(struck[1][1] and " struck "..struck[1][1][2] or "").." at "..phase)
            check(#struck[2]==1 and math.abs(struck[2][1][2]-.15)<.005,"and the rear, rolled into it after, strikes it all: "
                ..#struck[2]..(struck[2][1] and " struck "..struck[2][1][2] or "").." at "..phase)
        end
        -- Short at the edge, wherever in the step it lies: it strikes for the depth there, give or take half the 5 cm
        -- the tyre came down in the step. 2 cm short a step before and late in the step is 6.5 cm short at the edge.
        for _,over in ipairs({-.045,-.02}) do
            for _,phase in ipairs({.1,.3,.5,.7,.9}) do
                local lift=fall(over,19)
                local _,struck=roll_over(kerb(edge_at(lift,19,phase),.15),7.4,STEPS,lift)
                local short=-over+.05*phase
                local front=struck[1][1] and struck[1][1][2]
                if short>=.05 then
                    check(#struck[1]==1 and math.abs(front-short)<=.026,"a front tyre short at the edge strikes about that: "
                        ..#struck[1].." struck "..tostring(front).." of "..short.." at "..phase)
                else
                    check(#struck[1]<=1 and (front or 0)<=short+.026,"a tyre a little short strikes no more than half a step over: "
                        ..#struck[1].." struck "..tostring(front).." of "..short.." at "..phase)
                end
            end
        end
    end)
    case(function() -- A kerb struck while braking for a car: its push adds to the stop's rather than taking its place.
        local car=face(3+R+.55)
        local _,struck,both=roll_over(kerb(3,.15),7.4,24,nil,car)
        local _,_,stop=roll_over(kerb(math.huge,0),7.4,24,nil,car)
        local at=struck[1][1] and struck[1][1][1]
        check(at~=nil and stop[at]<-3000,"the bike brakes for the car as the front wheel strikes: "..tostring(at and stop[at]))
        check(both[at]-stop[at]<-4000,"and the kerb takes its own share on top: "..both[at].." against "..stop[at])
    end)
    -- A bike pitched this many degrees nose up on its rear wheel, the rear axle where a level bike's is.
    local function wheelie(degrees,speed)
        local rotation=pitch_of(-math.rad(degrees))
        local rear=M.turn(rotation,M.sub(Geometry.rear_axle,Geometry.com))
        local axle=Geometry.rear_axle[3]-Geometry.com[3]
        return {position={0,R-rear[2],axle-rear[3]},rotation=rotation,velocity={0,0,speed or 0}}
    end
    -- Rides the pose a few steps on a neutral pad, then with the right stick part way back for `count` steps.
    local function in_manual(w,pose,count)
        check(steps(w,pose,3)==nil,"riding before the manual")
        w.set_pad(-.53)
        return steps(w,pose,count)
    end
    -- A nose manual's pose: pitched this far nose down on its front wheel, and riding it with the stick part way forward.
    local function nose_down(degrees,speed)
        local rotation=pitch_of(math.rad(degrees))
        local front=M.turn(rotation,M.sub(Geometry.front_axle,Geometry.com))
        local axle=Geometry.front_axle[3]-Geometry.com[3]
        return {position={0,R-front[2],axle-front[3]},rotation=rotation,velocity={0,0,speed or 0}}
    end
    local function in_nose_manual(w,pose,count)
        check(steps(w,pose,3)==nil,"riding before the nose manual")
        w.set_pad(.53)
        return steps(w,pose,count)
    end
    case(function() -- The right stick part way back lifts the front, through Mapping, the stage and the packet.
        local w=harness(flat)
        local pose=level();pose.velocity={0,0,4}
        check(in_manual(w,pose,12)==nil,"a manual is ridden")
        check(w.controls.manual>.4,"the manual reaches the stage: "..tostring(w.controls.manual))
        check(w.submits[#w.submits].torque.x< -150,"and the packet lifts the nose: "..w.submits[#w.submits].torque.x)
        -- The drawn shift follows the physics' from rest, about .4 s for the whole of it; this harness accepts every
        -- other step.
        local shown
        for _=1,24 do shown=w.step(pose).presentation_pose end
        check(shown.rider_shift~=nil and shown.rider_shift>.05 and shown.rider_shift<=.2,
            "the rider is drawn shifted back by the weight the lift takes: "..tostring(shown.rider_shift))
        local still=harness(flat)
        local ridden=level();ridden.velocity={0,0,4}
        local plain
        for _=1,15 do plain=still.step(ridden).presentation_pose end
        local fields=0
        for _ in pairs(plain) do fields+=1 end
        check(fields==8 and plain.rider_shift==nil,"a neutral pad keeps ordinary riding's eight-field pose: "..fields)
    end)
    case(function() -- Going over the bars the manual is let go: the stage gets none while the crash runs.
        local w=harness(flat)
        local pose=level();pose.velocity={0,0,7.5}
        check(in_manual(w,pose,10)==nil and w.controls.manual>.4,"in a manual at speed")
        pose.velocity={0,0,7.2}
        check(steps(w,pose,1)==nil,"the first step of the hit")
        pose.velocity={0,0,.8}
        check(steps(w,pose,3)==nil,"the hit")
        check(w.controls.manual==0 and w.controls.nose_manual==0,"no manual reaches the stage in a crash: "..tostring(w.controls.manual))
        check(w.controls.nose_manual_held==false,"nor a stick held for a nose manual: "..tostring(w.controls.nose_manual_held))
    end)
    case(function() -- In a manual a parked car is still seen: pitched 32 degrees, the bike's own lanes climbed over it.
        local w=harness(face(NOSE+.5))
        local pose=wheelie(32,7)
        check(steps(w,pose,3)==nil,"riding at the car")
        w.set_pad(-.53)
        local braked,manual=0,false
        for _=1,12 do
            local before=#w.submits
            check(not w.step(pose).stop_requested,"riding at the car in a manual")
            manual=manual or w.controls.manual>.4
            if manual and #w.submits>before then braked=math.min(braked,w.submits[#w.submits].force.z) end
        end
        check(manual and braked< -1000,"the car ahead brakes the bike in its manual: "..braked)
    end)
    case(function() -- A kerb's bevel under the rear wheel of a manual does not hide the car: the lanes stay on the ground.
        -- In a manual the lanes lie on the ground under the rear wheel. A bevel row there ({0,.35,-.94}) laid them
        -- about 70 degrees over for its step, and the car at stopping distance was not seen.
        local bevel=M.unit({0,.35,-.94})
        local function crossing(car)
            local over=false
            local w=harness(function(from,to,count,i)
                if over and count==2 and i==2 then return hit(from,to,0,bevel) end
                return car(from,to)
            end)
            w.prompt=true
            local pose=wheelie(32,7)
            check(steps(w,pose,3)==nil,"riding at the car")
            w.set_pad(-.53)
            local rows,manual={},false
            for k=1,24 do
                over=k==13
                local before=#w.submits
                local out=w.step(pose)
                check(not out.stop_requested and #w.submits>before,"step "..k.." of the crossing is sent")
                local row=out.metrics.samples[#out.metrics.samples]
                -- Ride lays the lanes level for the manual of the step it accepted before.
                rows[k]={push=w.submits[#w.submits].force.z,seen=row.ahead_gap~=nil,manual=manual}
                manual=w.model.manual_active==true
            end
            return rows
        end
        local car,road=crossing(face(NOSE+.5)),crossing(flat)
        -- The bevel's row is a hard knock for the kernel too, which loses the manual for a step after it; the lanes
        -- are then on the bike, pitched past where a car's face counts as one. That step is the kernel's, not this.
        local held=0
        for k=8,24 do
            if car[k].manual then held+=1;check(car[k].seen,"in the manual the car is seen on step "..k) end
        end
        check(car[13].manual and held>=14,"the manual is held over the bevel and through most of the crossing: "..held)
        check(car[13].push-road[13].push< -5000,"and the stop pushes on the bevel's step: "..car[13].push.." against "..road[13].push)
    end)
    case(function() -- A slow manual over a kerb's bevel comes back after the bevel's step, as a faster one does.
        -- The manual's speed is taken along the ground under the wheels, which the bevel's row tilts nearly upright
        -- for its step: 1.6 to 2.5 m/s read .53 to .84. Read as a manual that had slowed to a walk, it kept the manual
        -- from starting again until the stick was let go, and the front came down onto the sidewalk.
        local bevel=M.unit({0,.35,-.94})
        for _,speed in ipairs({1.6,2,2.5,4}) do
            local over=false
            local w=harness(function(from,to,count,i)
                if over and count==2 and i==2 then return hit(from,to,0,bevel) end
                return flat(from,to)
            end)
            w.prompt=true
            local pose=wheelie(32,speed)
            check(steps(w,pose,3)==nil,"riding at the kerb at "..speed.." m/s")
            w.set_pad(-.53)
            local line=""
            for k=1,40 do
                over=k==13
                check(not w.step(pose).stop_requested,"step "..k.." over the kerb at "..speed.." m/s")
                line..=w.model.manual_active and "M" or "."
            end
            check(string.match(line,"^%.*M+%.?M+$")~=nil and #string.match(line,"M+$")>=20,
                "at "..speed.." m/s the manual is back a step after the bevel and held to the end: "..line)
        end
    end)
    case(function() -- A kerb's bevel read on two rows in a row, at a slow manual's 2 m/s, still does not hide the car.
        local bevel=M.unit({0,.35,-.94})
        local over=false
        local w=harness(function(from,to,count,i)
            if over and count==2 and i==2 then return hit(from,to,0,bevel) end
            return face(NOSE+.5)(from,to)
        end)
        w.prompt=true
        local pose=wheelie(32,2)
        check(steps(w,pose,3)==nil,"riding at the car")
        w.set_pad(-.53)
        local line,missed="",0
        for k=1,24 do
            over=k==13 or k==14
            local out=w.step(pose)
            check(not out.stop_requested,"step "..k.." of the crossing")
            local seen=out.metrics.samples[#out.metrics.samples].ahead_gap~=nil
            local manual=w.model.manual_active==true
            line..=(manual and "M" or ".")..(seen and "S" or "_")
            if k>=8 and manual and not seen then missed+=1 end
        end
        check(missed==0 and string.match(line,"MSMSMS$")~=nil,"in the manual the car is seen on every step from the 8th: "..line)
    end)
    case(function() -- In a manual up a ramp met at a kink, the car stop takes the ramp as the ground and sees a car on it in time.
        -- The ramp's normal is past 18 degrees from level and more than .2 rad from the road's, so it was never taken
        -- as the ground: the lanes stayed on the road behind and ran into the ramp ahead. A car 3 m up a 20 degree
        -- ramp was first seen 13 cm off at 7 m/s, and one up 25 degrees only once it was reached. Rays are answered
        -- by a plain ray and plane scene, every ray the same way, the rear hub rolling along the road and then
        -- parallel to the ramp, the bike held 32 degrees up from the ground under it.
        local function scene(theta,wall_at)
            local c,sn=math.cos(theta),math.sin(theta)
            local normal={0,c,-sn}
            local function height(z) return z<0 and 0 or z*sn/c end
            local base={0,wall_at*sn,wall_at*c}
            local surfaces={
                {p={0,0,0},n={0,1,0},ok=function(q) return q[3]<0 end},
                {p={0,0,0},n=normal,ok=function(q) return q[3]>=0 end},
                {p=base,n={0,0,-1},ok=function(q) local k=q[2]-height(q[3]) return k>=0 and k<=1.5 end},
            }
            return function(from,to)
                local f,d={from.x,from.y,from.z},{to.x-from.x,to.y-from.y,to.z-from.z}
                local best,bn,bp
                for _,surface in surfaces do
                    local den=M.dot(d,surface.n)
                    if den<0 then
                        local t=M.dot(M.sub(surface.p,f),surface.n)/den
                        if t>=0 and t<=1 then
                            local q=M.add(f,M.mul(d,t))
                            if surface.ok(q) and (not best or t<best) then best,bn,bp=t,surface.n,q end
                        end
                    end
                end
                if not best then return clear() end
                return {status="hit",position=vector.create(bp[1],bp[2],bp[3]),fraction=best,normal=vector.create(bn[1],bn[2],bn[3]),
                    surface_velocity=vector.create(0,0,0),normal_available=true,surface_velocity_available=true,motion="measured"}
            end
        end
        local function first_seen(degrees,speed)
            local theta=math.rad(degrees)
            local w=harness(scene(theta,3))
            w.prompt=true
            local touch=-R*math.tan(theta/2)
            local s=touch-speed*h*16
            local first,manual
            for k=1,3+16+24 do
                if k==4 then w.set_pad(-.53) end
                local hub,slope={0,R,s},0
                if s>touch then hub,slope=M.add({0,R,touch},M.mul({0,math.sin(theta),math.cos(theta)},s-touch)),theta end
                local rotation=pitch_of(-(math.rad(32)+slope))
                local p=M.sub(hub,M.turn(rotation,M.sub(Geometry.rear_axle,Geometry.com)))
                local out=w.step({position=p,rotation=rotation,velocity=M.mul({0,math.sin(slope),math.cos(slope)},speed)})
                check(not out.stop_requested,"step "..k.." up the "..degrees.." degree ramp")
                local gap=out.metrics.samples[#out.metrics.samples].ahead_gap
                if slope>0 and gap and not first then first,manual=gap,w.model.manual_active==true end
                s+=speed*h
            end
            return first,manual
        end
        for _,degrees in ipairs({20,25}) do
            local first,manual=first_seen(degrees,7)
            check(manual==true and first and first>.8,string.format("up %d degrees at 7 m/s, in the manual the car is first seen %s m off",
                degrees,tostring(first and string.format("%.2f",first))))
        end
    end)
    case(function() -- Going over the bars at a car from a manual, the manual is let go from the crash's first step.
        -- The pitched bike's own lanes do not count a car's face as one; the manual's level lanes find it already close.
        local w=harness(face(NOSE+.3))
        w.prompt=true
        local pose=wheelie(32,7)
        check(steps(w,pose,3)==nil,"riding at the car")
        w.set_pad(-.53)
        local first,sent,before_crash=nil,nil,false
        for k=1,20 do
            local before=#w.submits
            check(not w.step(pose).stop_requested and #w.submits>before,"step "..k.." is sent")
            -- The crash's torque, nose down on top of the stage's, marks the step it starts.
            if not first and w.submits[#w.submits].torque.x-w.model.torque[1]>1000 then first,sent=k,w.controls end
            if not first then before_crash=before_crash or w.controls.manual>.4 end
        end
        check(before_crash and first,"the manual is up before the crash comes: "..tostring(first))
        check(sent.manual==0 and sent.nose_manual==0 and sent.pedal==0,
            "and the crash's first step sends no manual: "..sent.manual.." "..sent.nose_manual.." "..sent.pedal)
    end)
    case(function() -- A quarter pipe ahead of a manual is still a ramp, not a wall.
        local function quarter(ahead_of)
            local w=harness(function(from,to,count,i)
                if math.abs(to.z-from.z)>4*math.abs(to.y-from.y) and math.abs(to.z-from.z)>math.abs(to.x-from.x) then
                    if from.y<.3 then return face(NOSE+.2,M.unit({0,.7,-.71}))(from,to) end
                    return ahead_of(from,to)
                end
                return flat(from,to)
            end)
            check(in_manual(w,wheelie(30,6),12)==nil,"the manual rides at it")
            return pushed(w)
        end
        local walled,open=quarter(face(NOSE+.6,M.unit({0,.17,-.98}))),quarter(flat)
        check(math.abs(walled-open)<500,"a quarter pipe ahead of a manual is not a wall: "..walled.." against "..open)
    end)
    case(function() -- A held manual is not a fall; a bike gone over backwards still is.
        local w=harness(flat)
        check(in_manual(w,wheelie(36,4),120)==nil,"36 degrees on the rear wheel rides on")
        local over=harness(flat)
        local at=in_manual(over,wheelie(70,4),40)
        check(at==18-3,"70 degrees from the surface ends after its .3 s: "..tostring(at))
    end)
    case(function() -- A held nose manual is not a fall; a bike gone over the bars still is.
        local w=harness(flat)
        check(steps(w,nose_down(31,4),3)==nil,"riding before the nose manual")
        w.set_pad(.53)
        local engaged
        for i=1,120 do
            local out=w.step(nose_down(31,4))
            check(not out.stop_requested,"31 degrees on the front wheel rides on at step "..i..": "..tostring(out.issue))
            if not engaged and w.model and w.model.nose_manual_active==true then engaged=i end
        end
        check(engaged and engaged<=8,"the stick puts the bike in the nose manual from step "..tostring(engaged))
        local over=harness(flat)
        local at=in_nose_manual(over,nose_down(70,4),40)
        check(at==18-3,"70 degrees over the front ends after its .3 s, as over the back does: "..tostring(at))
    end)
    case(function() -- In a nose manual a parked car is still seen: the lanes are laid from the front wheel on the ground.
        -- Laid on the bike pitched nose down, the lanes started .44 to .56 m up at 20 degrees and a car .5 m past the
        -- tyre at 7 m/s asked no push (-29 N).
        local knee=.5 -- How high ride_runtime's three high lanes (AHEAD_RAYS) sit over the ground they are laid on.
        for _,degrees in ipairs({20,25.6,31,36}) do
            for _,gap in ipairs({.5,1}) do
                -- The height each of the three high lanes starts at, on the last look.
                local car,heights=face(NOSE+gap),{}
                local w=harness(function(from,to,count,i)
                    if count==4 and i<=3 then heights[i]=from.y end
                    return car(from,to)
                end)
                local pose=nose_down(degrees,7)
                check(steps(w,pose,3)==nil,"riding at the car")
                w.set_pad(.53)
                local braked,engaged=0,nil
                for i=1,12 do
                    local before=#w.submits
                    check(not w.step(pose).stop_requested,"riding at the car in a nose manual at "..degrees.." degrees")
                    if not engaged and w.model.nose_manual_active==true then engaged=i end
                    if engaged and #w.submits>before then braked=math.min(braked,w.submits[#w.submits].force.z) end
                end
                check(engaged and engaged<=12,"the stick puts the bike in the nose manual at "..degrees.." degrees: "..tostring(engaged))
                for i=1,3 do
                    check(heights[i] and math.abs(heights[i]-knee)<.01,string.format(
                        "lane %d starts at the knees over the ground at %.1f degrees: %s",i,degrees,tostring(heights[i])))
                end
                if gap<1 then
                    check(braked<= -5000,string.format("a car %.1f m past the tyre brakes a nose manual at %.1f degrees: %.0f",gap,degrees,braked))
                else
                    check(braked>= -100,string.format("one %.1f m past it asks nothing yet at %.1f degrees: %.0f",gap,degrees,braked))
                end
            end
        end
    end)
    case(function() -- A kerb's bevel under the front wheel of a nose manual does not hide the car.
        -- In a nose manual the lanes lie on the ground under the front wheel, so a bevel row there ({0,.35,-.94}) is
        -- the rear manual's bevel under its rear wheel. Laid on the bike, the car was missed on every nose manual
        -- step from the 8th, 16 of 16 at 2 m/s.
        local bevel=M.unit({0,.35,-.94})
        local function crossing(car,speed,rows)
            local over=false
            local w=harness(function(from,to,count,i)
                if over and count==2 and i==1 then return hit(from,to,0,bevel) end
                return car(from,to)
            end)
            w.prompt=true
            local pose=nose_down(28,speed)
            check(steps(w,pose,3)==nil,"riding at the car")
            w.set_pad(.53)
            local out_rows,nose={},false
            for k=1,24 do
                over=k==13 or rows==2 and k==14
                local before=#w.submits
                local out=w.step(pose)
                check(not out.stop_requested,"step "..k.." of the crossing at "..speed.." m/s")
                -- Ride lays the lanes for the nose manual of the step it accepted before.
                out_rows[k]={push=#w.submits>before and w.submits[#w.submits].force.z or nil,
                    seen=out.metrics.samples[#out.metrics.samples].ahead_gap~=nil,nose=nose}
                nose=w.model.nose_manual_active==true
            end
            return out_rows
        end
        for _,rows in ipairs({1,2}) do
            for _,speed in ipairs({2,7}) do
                local car=crossing(face(NOSE+.5),speed,rows)
                local line,missed,held="",0,0
                for k=1,24 do
                    line..=(car[k].nose and "N" or ".")..(car[k].seen and "S" or "_")
                    if k>=8 and car[k].nose then held+=1;if not car[k].seen then missed+=1 end end
                end
                local road=crossing(flat,speed,rows)
                check(missed==0 and held>=10,string.format("over %d bevel row(s) at %d m/s the car is seen on every nose manual step from the 8th: %s",
                    rows,speed,line))
                if speed==7 then
                    check(car[13].push and road[13].push and car[13].push-road[13].push<= -3000,
                        string.format("and the stop pushes on the bevel's step: %s against %s",tostring(car[13].push),tostring(road[13].push)))
                end
            end
        end
    end)
    case(function() -- A corner only a bar end meets is still met in a nose manual: the bar ends lead the tyre.
        for _,degrees in ipairs({20,31}) do
            for _,gap in ipairs({.1,.2,.3,.4}) do
                local w=harness(face(NOSE+gap,nil,.2))
                local pose=nose_down(degrees,7)
                check(steps(w,pose,3)==nil,"riding at the corner")
                w.set_pad(.53)
                local braked,engaged=0,false
                for _=1,12 do
                    local before=#w.submits
                    check(not w.step(pose).stop_requested,"riding at the corner in a nose manual")
                    engaged=engaged or w.model.nose_manual_active==true
                    if engaged and #w.submits>before then braked=math.min(braked,w.submits[#w.submits].force.z) end
                end
                check(engaged and braked<= -5000,string.format("a corner %.1f m past the tyre at %d degrees stops the nose manual: %.0f",
                    gap,degrees,braked))
            end
        end
    end)
    case(function() -- Brought to rest at a car in a nose manual, the rear comes down with the front tyre at the bumper, not in it.
        -- The body moves here. As the rear comes down the front hub, .64 m under the centre of mass, swings forward
        -- while the centre of mass stays put: with the stop's closing taken from the centre of mass alone, it saw none,
        -- and the front tyre rolled .25 to .35 m into the car. A manual and plain riding rest at the bumper too.
        local WALL=4.5
        for _,row in ipairs({{.35,2},{.35,3.9},{.53,2},{.53,2.5},{.53,3.9},{1,2.5},{1,3.9},{-.53,2.5},{0,2.5}}) do
            local stick,speed=row[1],row[2]
            local what=string.format("stick %.2f at %.1f m/s",stick,speed)
            local w=harness(face(WALL))
            w.prompt=true
            local b=World.place(World.terrain.flat(),{speed=speed})
            local deepest,nosed,down=-math.huge,false,nil
            for step=1,260 do
                if step==4 then w.set_pad(stick) end
                local out
                out,b=w.ride_step(b)
                check(not out.stop_requested,what..": the ride goes on: "..tostring(out.issue))
                local nosing=w.model and w.model.nose_manual_active==true
                nosed=nosed or nosing
                if nosed and not nosing and not down then down=step end
                local q=M.normalized(b.orientation)
                local hub=M.add(b.center_of_mass,M.turn(q,M.sub(Geometry.front_axle,Geometry.com)))
                deepest=math.max(deepest,hub[3]+R-WALL)
            end
            if stick>0 then check(nosed and down,what..": into a nose manual, and the rear came down: "..tostring(down)) end
            check(deepest<=.03,string.format("%s: the front tyre goes at most %.3f m into the car",what,deepest))
        end
    end)
    case(function() -- Stopped at a car in a nose manual, the bike comes to rest there with the front tyre at the bumper.
        -- The body moves here. Levelling about the front hub held at the face, the rigid body's centre of mass goes back
        -- .34 m, and the push that does that left the bike rolling back at 1.2 to 1.5 m/s once the rear was down: 1.8 to
        -- 3.2 m off the car 4.3 s in and 5.3 to 7.5 m off it at 10 s, held stick or not. Let go at rest, let go still
        -- rolling, and against a face turned 20 or 40 degrees, the bike is now still a second after the rear lands.
        local WALL=4.5
        for _,row in ipairs({{.35,2,"held",0},{.53,2.5,"held",0},{1,3.9,"held",0},{.53,2,"rest",0},{1,3,"rest",0},
            {.35,2.5,"early",0},{.53,3.5,"early",0},{1,3.9,"early",0},{.53,3,"held",20},{.53,2.5,"held",40},{1,3.5,"held",40},
            {.53,3,"early",40}}) do
            local stick,speed,mode,degrees=row[1],row[2],row[3],row[4]
            local what=string.format("stick %.2f at %.1f m/s, %s, a face turned %d degrees",stick,speed,
                mode=="held" and "held" or mode=="rest" and "let go at rest" or "let go still rolling",degrees)
            local ground,n=turned(WALL,degrees)
            local w=harness(ground)
            w.prompt=true
            local b=World.place(World.terrain.flat(),{speed=speed})
            local deepest,nosed,lifted,down,released,depth,rolling=-math.huge,false,false,nil,false,nil,nil
            for step=1,400 do
                if step==4 then w.set_pad(stick) end
                local out
                out,b=w.ride_step(b)
                check(not out.stop_requested,what..": the ride goes on: "..tostring(out.issue))
                nosed=nosed or w.model and w.model.nose_manual_active==true
                local q=M.normalized(b.orientation)
                local hub=M.add(b.center_of_mass,M.turn(q,M.sub(Geometry.front_axle,Geometry.com)))
                local rear=M.add(b.center_of_mass,M.turn(q,M.sub(Geometry.rear_axle,Geometry.com)))
                local f,u=M.turn(q,{0,0,1}),M.turn(q,{0,1,0})
                -- How far the tyre's disc reaches past the face.
                depth=R*math.sqrt(M.dot(n,f)^2+M.dot(n,u)^2)-M.dot(M.sub(hub,{0,0,WALL}),n)
                deepest=math.max(deepest,depth)
                rolling=M.dot(b.linear_velocity,f)
                if not released and (mode=="early" and depth>-.3 or mode=="rest" and depth>-.05 and M.length(b.linear_velocity)<.1) then
                    w.set_pad(0) released=true
                end
                lifted=lifted or nosed and rear[2]-R>.05
                if lifted and not down and rear[2]-R<.006 then down=step end
                if down and step==down+60 then break end
            end
            check(nosed and down,what..": into a nose manual, and the rear came down: "..tostring(down))
            check(mode=="held" or released,what..": the stick was let go")
            check(deepest<=(degrees>=40 and .07 or .03),string.format("%s: the front tyre goes at most %.3f m into the car",what,deepest))
            -- Rolling along the bike, not standing up from the lean a turned face gave it.
            check(depth>=-.03 and math.abs(rolling)<.05,string.format("%s: a second after the rear lands the tyre is %.3f m off the car, rolling at %.3f m/s",
                what,-depth,rolling))
        end
    end)
    case(function() -- A 12 cm bump at a jog in a nose manual, the stick past half way: the rider's catch mostly holds it.
        -- The body moves here. The front meets a 12 cm bump .6 m long 1 to 1.8 s into the nose manual. Tipping on over the
        -- bars, the rider snaps the weight back; reaching all of the catch only .5 rad/s past where it starts, it gave
        -- 283 to 554 N m at .8 to .93 rad/s and ran out with the bike past 50 degrees, and these rides went over the bars on
        -- 19 of 36. Below 2.25 m/s the front stops dead at the bump's face and most still go over, a real endo.
        local high,length=.12,.6
        local function height(z) local u=z/length if u<=0 or u>=1 then return 0 end return high*.5*(1-math.cos(2*math.pi*u)) end
        local function slope(z) local u=z/length if u<=0 or u>=1 then return 0 end return high*math.pi*math.sin(2*math.pi*u)/length end
        local total,report=0,{}
        for _,row in ipairs({{2.25,.72},{2.25,1},{2.5,.72},{2.5,1}}) do
            local speed,stick=row[1],row[2]
            local over={}
            for k=0,8 do
                local at=1+k*.1
                local w=harness(profile(height,slope))
                w.prompt=true
                w.set_pad(0)
                local b=World.place(World.terrain.flat(),{speed=speed,z=-(speed*at+.5158)})
                local out
                for _=1,3 do out,b=w.ride_step(b) end
                w.set_pad(stick)
                for _=1,240 do
                    out,b=w.ride_step(b)
                    if out.stop_requested then over[#over+1]=string.format("%.1f",at) break end
                end
            end
            total+=#over
            report[#report+1]=string.format("%.2f m/s stick %.2f: %d of 9 (%s)",speed,stick,#over,table.concat(over,","))
            check(#over<=3,string.format("at %.2f m/s with the stick at %.2f, %d of 9 go over the bars",speed,stick,#over))
        end
        check(total<=8,"at most 8 of 36 go over the bars: "..table.concat(report,"; "))
    end)
    case(function() -- In a nose manual a corner only a bar end meets is rested against, and a face met at a glance ridden past.
        -- The body moves here. Each lane presses with its own part of the bike. With the front hub's travel read in every
        -- lane, the rear coming down shoved the bike .1 to .9 m back off a corner only the left bar end met, and a nose
        -- manual steered at 5.5 to 7.5 m/s into a face turned 5 to 25 degrees went over at 70 to 90 degrees.
        local WALL=4.5
        for _,row in ipairs({{.35,2},{.35,3.9},{.53,3},{1,2},{1,3.9}}) do
            local stick,speed=row[1],row[2]
            local what=string.format("a corner only the left bar end meets, stick %.2f at %.1f m/s",stick,speed)
            local w=harness(face(WALL,nil,.2))
            w.prompt=true
            local b=World.place(World.terrain.flat(),{speed=speed})
            local deepest,last,nosed=-math.huge,nil,false
            for step=1,300 do
                if step==4 then w.set_pad(stick) end
                local out
                out,b=w.ride_step(b)
                check(not out.stop_requested,what..": the ride goes on: "..tostring(out.issue))
                nosed=nosed or w.model and w.model.nose_manual_active==true
                local q=M.normalized(b.orientation)
                local grip=M.add(b.center_of_mass,M.turn(q,M.sub(Geometry.left_grip,Geometry.com)))
                last=grip[3]+.055*Geometry.scale-WALL
                deepest=math.max(deepest,last)
            end
            check(nosed,what..": into a nose manual")
            check(deepest<=.06,string.format("%s: the bar end goes at most %.3f m into the corner",what,deepest))
            check(last>=-.03 and M.length(b.linear_velocity)<.05,string.format("%s: it rests %.3f m off the corner at %.3f m/s",
                what,-last,M.length(b.linear_velocity)))
        end
        for _,row in ipairs({{5.5,-.75,-15},{6,-1,-5},{6,-.75,-25},{6.5,-1,-15},{6.5,-.75,-25},{7,-1,-15},{7,-.75,-25},{7.5,-1,-25}}) do
            local speed,steer,degrees=row[1],row[2],row[3]
            local what=string.format("steer %.2f at %.1f m/s into a face turned %d degrees",steer,speed,degrees)
            local w=harness((turned(4+speed*1.5,degrees)))
            w.prompt=true
            local b=World.place(World.terrain.flat(),{speed=speed})
            local nosed,issue=false,nil
            for step=1,300 do
                if step==4 then w.set_pad(.53) elseif step==30 then w.set_pad(.53,steer) end
                local out
                out,b=w.ride_step(b)
                nosed=nosed or w.model and w.model.nose_manual_active==true
                if out.stop_requested then issue=tostring(out.issue) break end
            end
            check(nosed,what..": into a nose manual")
            -- Closing as fast as a hit is a crash at the face, as on a bike on both wheels; going over sideways is not.
            check(issue==nil or issue:find("hit something",1,true)~=nil,what..": no fall over sideways: "..tostring(issue))
        end
    end)
    case(function() -- From a rear manual straight into a nose manual, the drawn hips swing forward no faster than in either alone.
        -- The body moves here. Eased a sixth of the way a step from the rear manual's shift to the nose manual's, the
        -- hips moved .095 m in one frame and stopped dead as the shift crossed to forward; from a rear manual held a
        -- third of a second, its own let-go moved them .066 m a step. Followed, they move at most 13 mm a step on the
        -- rider's own frame, and a rear manual held with its weight a little forward (stick -.72) does not drop the hips
        -- from its line to the nose manual's in one step either.
        local most=0
        for _,row in ipairs({{-.53,3,64},{-.53,4,64},{-.72,3,64},{-.72,4,64},{-.53,4,24},{-.72,4,24}}) do
            local back,speed,switch=row[1],row[2],row[3]
            local what=string.format("stick %.2f then .53 at step %d at %.1f m/s",back,switch,speed)
            local w=harness(flat)
            local b=World.place(World.terrain.flat(),{speed=speed})
            local reared,nosed,last,worst=false,false,nil,0
            for step=1,switch+96 do
                if step==4 then w.set_pad(back) elseif step==switch then w.set_pad(.53) end
                local out
                out,b=w.ride_step(b)
                check(not out.stop_requested,what..": the ride goes on: "..tostring(out.issue))
                if step<switch then reared=reared or w.model.manual_active==true else nosed=nosed or (w.model.nose_manual_active==true and w.model.manual_active~=true) end
                local a=out.presentation_pose
                local hip=a.rider_shift~=nil and MP.manual_rider(a.rider_shift,a.rider_standing,a.rider_nose,a.rider_over).hip_offset or {0,0,0}
                if last then worst=math.max(worst,M.length(M.sub(hip,last))) end
                last=hip
            end
            check(reared and nosed,what..": a rear manual, then a nose manual")
            check(worst<=.015,string.format("%s: the drawn hips move at most %.4f m in a step",what,worst))
            most=math.max(most,worst)
        end
        print(string.format("MEASURE rear manual into nose manual: hips move %.4f m in a step at most",most))
    end)
    case(function() -- From a rear manual held with the weight forward into a nose manual, the hips go to the nose manual's line a step at a time.
        -- Pitched past where the stick holds it, a rear manual's weight goes forward to bring the front down, and its
        -- hips with it toward the bars, on the manual's line (MP.manual_rider, no nose). Into a nose manual with that
        -- forward shift still drawn, rider_nose takes them to the nose manual's line, up over the bars, followed
        -- (RIDER_NOSE_OMEGA): set at once, the hips dropped 1.26 times the shift in one step.
        local w=harness(flat)
        w.prompt=true
        local reared=wheelie(40,4)
        check(in_manual(w,reared,60)==nil,"a rear manual pitched past its hold")
        local before=w.step(reared).presentation_pose
        check(w.model.manual_active==true and before.rider_shift~=nil and before.rider_shift<=-.02 and before.rider_nose==nil,
            "the rear manual's weight is drawn forward, on the manual's line: "..tostring(before.rider_shift).." "..tostring(before.rider_nose))
        w.set_pad(.53)
        local last=MP.manual_rider(before.rider_shift,before.rider_standing,before.rider_nose,before.rider_over).hip_offset
        local worst,nosed,rising=0,false,0
        for i=1,90 do
            local out=w.step(nose_down(28*math.min(1,i/20),4))
            check(not out.stop_requested,"into the nose manual: "..tostring(out.issue))
            local a=out.presentation_pose
            nosed=nosed or (w.model.nose_manual_active==true and w.model.manual_active~=true)
            if a.rider_nose and a.rider_nose<1 then rising+=1 end
            local hip=a.rider_shift~=nil and MP.manual_rider(a.rider_shift,a.rider_standing,a.rider_nose,a.rider_over).hip_offset or {0,0,0}
            worst=math.max(worst,M.length(M.sub(hip,last)))
            last=hip
        end
        check(nosed and rising>0,"a nose manual, its line taken over "..rising.." steps")
        check(worst<=.015,string.format("the drawn hips move at most %.4f m in a step",worst))
        print(string.format("MEASURE rear manual forward into a nose manual: shift %.3f, hips %.4f m a step at most, nose over %d steps",
            before.rider_shift,worst,rising))
    end)
    case(function() -- Going over the bars from a nose manual, the stick is let go: the stage gets no held stick while the crash runs.
        local w=harness(flat)
        local pose=nose_down(28,7.5)
        check(in_nose_manual(w,pose,10)==nil and w.model.nose_manual_active==true and w.controls.nose_manual_held==true,
            "in a nose manual at speed")
        pose.velocity={0,0,7.2}
        check(steps(w,pose,1)==nil,"the first step of the hit")
        pose.velocity={0,0,.8}
        check(steps(w,pose,3)==nil,"the hit")
        -- The crash's torque, nose down on top of the stage's, says it is running.
        local crashing=w.submits[#w.submits].torque.x-w.model.torque[1]
        check(crashing>1000,"over the bars: "..crashing)
        check(w.controls.manual==0 and w.controls.nose_manual==0 and w.controls.nose_manual_held==false,
            "no nose manual and no held stick reach the stage in a crash: "..tostring(w.controls.nose_manual).." "..tostring(w.controls.nose_manual_held))
    end)
    -- Where a drawn wheel's tyre touches down, the lowest point of its disc, against where the body's does.
    local function touch(m)
        local axle=M.unit({m[1],m[2],m[3]})
        local toward=M.unit(M.sub({0,-1,0},M.mul(axle,-axle[2])))
        return M.add({m[13],m[14],m[15]},M.mul(toward,R))
    end
    local function drawn_touch(sample,pose,part)
        local body,drawn=Visual.from_sample(sample),Visual.from_sample(sample,pose)
        return touch(drawn[part]),touch(body[part])
    end
    case(function() -- A manual rolled onto a kerb is drawn lifted onto it on its rear wheel, not nodded about the front in the air.
        local kerb=false
        local w=harness(function(from,to,count,i)
            if count==2 and i==2 and kerb then return hit(from,to,from.y-R+.15,{0,1,0}) end
            return flat(from,to)
        end)
        w.prompt=true
        local pose=wheelie(30,4)
        check(in_manual(w,pose,12)==nil and w.controls.manual>.4,"a manual on the road")
        check(w.step(pose).presentation_pose.movement_bike_lift==nil,"on the road the manual draws the bike on its body")
        kerb=true
        local lifts={}
        for i=1,6 do
            local out=w.step(pose)
            check(not out.stop_requested,"riding the manual onto the kerb: "..tostring(out.issue))
            local shown=out.presentation_pose
            check(math.abs(shown.movement_bike_pitch)<1e-6,
                "the drawn bike is not pitched about its front wheel in the air: "..shown.movement_bike_pitch)
            local rear,body=drawn_touch(w.samples[w.serial],shown,3)
            local front,front_body=drawn_touch(w.samples[w.serial],shown,4)
            local up=rear[2]-body[2]
            lifts[i]=string.format("%.3f",up)
            check(math.abs(rear[1]-body[1])<.002 and math.abs(rear[3]-body[3])<.002,string.format(
                "the rear tyre is drawn straight up off where the body's touches, not behind it: %.4f %.4f",rear[1]-body[1],rear[3]-body[3]))
            check(M.length(M.sub(M.sub(front,front_body),M.sub(rear,body)))<.002,"and the front goes up with it: the whole bike is lifted")
            if i>=3 then
                -- The ray found the kerb top under the body's rear hub, .15 above where its tyre touches the road.
                check(math.abs(rear[2]-(.15-.01))<.002,"the rear tyre is drawn on the kerb top, its bottom at "..rear[2].." against .15")
            end
        end
        check(lifts[1]=="0.050" and lifts[2]=="0.100" and lifts[3]=="0.140","it comes up 5 cm a step: "..table.concat(lifts," "))
        -- A level bike with its rear in the kerb and the front tyre a moment off the road beyond: a wheel just off the
        -- ground still holds the drawn bike, so the front is drawn where the body has it, give or take what it clears
        -- past 2 cm, and hovering across that line it does not flick up and down.
        local gap=.015
        local level_kerb=harness(function(from,to,count,i)
            if count~=2 then return flat(from,to) end
            if i==2 then return hit(from,to,from.y-R+.15,{0,1,0}) end
            return hit(from,to,from.y-R-gap,{0,1,0})
        end)
        level_kerb.prompt=true
        local highest=0
        -- Where each hub is drawn, the whole of it: the pitch's swing and the shift move a hub along the bike too.
        local function hubs(sample,shown)
            local m=Visual.from_sample(sample,shown)
            return {m[4][13],m[4][14],m[4][15]},{m[3][13],m[3][14],m[3][15]}
        end
        local last_front,last_rear
        local moved_front,moved_rear=0,0
        for i=1,12 do
            gap=i%2==0 and .015 or .025
            local shown=level_kerb.step(level()).presentation_pose
            local front=shown.movement_bike_lift and Geometry.hub_rise(Geometry,shown.movement_bike_pitch,shown.movement_bike_lift) or 0
            highest=math.max(highest,front)
            local front_hub,rear_hub=hubs(level_kerb.samples[level_kerb.serial],shown)
            -- Once the rear's rise has come up (three steps at LIFT_RATE), the drawn bike holds still but for the cap.
            if i>4 then
                moved_front=math.max(moved_front,M.length(M.sub(front_hub,last_front)))
                moved_rear=math.max(moved_rear,M.length(M.sub(rear_hub,last_rear)))
            end
            last_front,last_rear=front_hub,rear_hub
        end
        check(highest<.006,"a front tyre 1.5 to 2.5 cm off the road is drawn within 5 mm of the body's: "..highest)
        -- Held about the rear while the front was past 2 cm and about the front within it, the pitched bike was drawn
        -- 1.1 cm along itself back and forth every step for as long as the front hovered.
        check(moved_front<.006 and moved_rear<.002,string.format(
            "and the drawn bike does not buzz along itself: the front hub moves %.4f a step, the rear %.4f",moved_front,moved_rear))
    end)
    case(function() -- A manual in a kerb whose rear ray now and then finds the kerb's bevelled edge is not thrown along the ground.
        -- The rear tyre .15 into a kerb, drawn up 14 cm along the ground's normal. On some steps the ray finds a
        -- 25 degree edge there (fall() notes kerb bevels in the game). Lifted along each step's normal, the drawn
        -- rear hub jumped 6.4 cm along the ground and back on each one.
        local bevel=math.rad(25)
        local mode,kerb="top",false
        local w=harness(function(from,to,count,i)
            if count==2 and i==2 and kerb then
                if mode=="edge" then return hit(from,to,from.y-R+.15,{0,math.cos(bevel),-math.sin(bevel)}) end
                return hit(from,to,from.y-R+.15,{0,1,0})
            end
            return flat(from,to)
        end)
        w.prompt=true
        local pose=wheelie(30,4)
        check(in_manual(w,pose,12)==nil and w.controls.manual>.4,"a manual on the road")
        kerb=true
        local last,most=nil,0
        for i,m in ipairs({"top","top","top","top","top","edge","top","edge","top","top","edge","edge","edge","top","top"}) do
            mode=m
            local out=w.step(pose)
            check(not out.stop_requested,"riding the manual in the kerb: "..tostring(out.issue))
            local rear,body=drawn_touch(w.samples[w.serial],out.presentation_pose,3)
            local drawn=M.sub(rear,body)
            -- Once its 14 cm have come up, three steps at LIFT_RATE, the tyre stays up on the kerb. Measured on the
            -- edge, the ray's depth is the kerb's top along that normal, a centimetre more.
            if i>3 then
                check(drawn[2]>.13 and drawn[2]<.16,"the rear tyre is drawn on the kerb top: "..drawn[2])
                local along=M.sub(drawn,last)
                most=math.max(most,math.sqrt(along[1]*along[1]+along[3]*along[3]))
            end
            last=drawn
        end
        check(most<.01,string.format("and moves %.4f a step at most along the ground as its ray finds the edge and the top",most))
    end)
    case(function() -- A manual whose rear ray first finds a kerb on its 45 degree bevel is drawn up onto the top, not along the bevel.
        -- The first drawn step's direction was the bevel's normal as measured, and it took 18 steps at LIFT_TURN to come
        -- back to the top's: the drawn rear hub was 9 cm behind the body's and the tyre 4 cm into the kerb.
        local bevel=math.rad(45)
        local rows=0
        local w=harness(function(from,to,count,i)
            if count==2 and i==2 and rows>0 then
                if rows==1 then return hit(from,to,from.y-R+.15,{0,math.cos(bevel),-math.sin(bevel)}) end
                return hit(from,to,from.y-R+.15,{0,1,0})
            end
            return flat(from,to)
        end)
        w.prompt=true
        local pose=wheelie(30,4)
        check(in_manual(w,pose,12)==nil and w.controls.manual>.4,"a manual on the road")
        local into,behind=0,0
        for i=1,20 do
            rows=i
            local out=w.step(pose)
            check(not out.stop_requested,"riding the manual onto the kerb: "..tostring(out.issue))
            local shown=out.presentation_pose
            local sample=w.samples[w.serial]
            local rear=drawn_touch(sample,shown,3)
            local drawn,body=Visual.from_sample(sample,shown)[3],Visual.from_sample(sample)[3]
            if i>=3 then
                into=math.max(into,math.abs(rear[2]-.15))
                behind=math.max(behind,math.sqrt((drawn[13]-body[13])^2+(drawn[15]-body[15])^2))
            end
        end
        check(into<.015,string.format("from the third drawn step the rear tyre is drawn on the kerb top, %.4f off it at most",into))
        check(behind<.02,string.format("and the drawn rear hub is %.4f at most from the body's along the ground",behind))
    end)
    case(function() -- A steady manual's rear carries the whole weight and sinks past the drawn slack: nothing is drawn, so the rider is mapped.
        local w=harness(flat)
        w.prompt=true
        local pose=wheelie(30,4)
        -- The kernel's 100000 N/m spring holds 106 kg on one wheel 10.4 mm into the road.
        pose.position[2]-=.0104
        local api={skater={pose=function(_,weight)
            if weight==MP.PROBE_WEIGHT then error("place has a position, a rotation or both",0) end
            return true
        end}}
        local poser=MP.new(api)
        check(poser:mount(0).ok,"the poser mounts on a constructed skater.pose")
        -- Two thirds of a second in, the drawn shift and standing have come to rest on the physics' and the cranks level.
        check(in_manual(w,pose,40)==nil,"the manual is ridden")
        local drawn,shift=0,nil
        for i=1,90 do
            local out=w.step(pose)
            check(not out.stop_requested,"a steady manual rides on: "..tostring(out.issue))
            local a=out.presentation_pose
            if a.movement_bike_pitch~=0 or a.movement_bike_lift~=nil or a.movement_bike_shift~=nil then drawn+=1 end
            -- As Core poses the rider (bike_runtime_core pose_step).
            local articulation={steer=a.steer,crank_phase=a.crank_phase,barspin=a.barspin,tailwhip=a.tailwhip,
                movement_bike_pitch=a.movement_bike_pitch,movement_bike_roll=a.movement_bike_roll,
                movement_bike_lift=a.movement_bike_lift,movement_bike_shift=a.movement_bike_shift}
            local input={bike={center_of_mass=pose.position,rotation=pose.rotation},articulation=articulation,
                rider=a.rider_shift~=nil and MP.manual_rider(a.rider_shift,a.rider_standing) or nil}
            local r=poser:tick(i/60,input)
            check(r.ok and r.sent,"the manual's rider is posed: "..tostring(r.reason))
            shift=a.rider_shift
        end
        check(shift~=nil,"the kernel holds the manual, and the rider stands in it")
        check(drawn==0,"a rear 10.4 mm into the road draws nothing: "..drawn.." of 90 steps drawn")
        local hits,misses=poser.memo_hits or 0,poser.memo_misses or 0
        check(hits+misses==90 and hits>=81,"the manual's rider is mapped from its memo on 90% of its ticks: "..hits.." hits, "..misses.." misses")
    end)
    case(function() -- A manual begun and let go on a bike drawn pitched on a kerb stands the rider up and sits it down over ticks.
        -- A level body, its front tyre on a kerb's top and its rear .15 into the kerb's face: the bike is drawn
        -- pitched 8.6 degrees nose down about the front. A standing rider goes with all of that drawn turn, a seated
        -- one only with its seat, so a rider stood up or sat down in one tick turned 7.6 to 8.3 degrees in it.
        local w=harness(function(from,to,count,i)
            if count~=2 then return flat(from,to) end
            if i==1 then return hit(from,to,from.y-R,{0,1,0}) end
            return hit(from,to,from.y-R+.15,{0,1,0})
        end)
        w.prompt=true
        local pose=level();pose.velocity={0,0,4}
        -- Long enough for the cranks to come level, so only the manual moves the rider.
        steps(w,pose,40)
        w.set_pad(-.53)
        local function angle(a,b) return math.deg(2*math.acos(math.min(1,math.abs(a[1]*b[1]+a[2]*b[2]+a[3]*b[3]+a[4]*b[4])))) end
        local last,last_at,farthest,standing,most,pitched,stood,sat=nil,nil,0,0,0,0,false,false
        local function step(i)
            local out=w.step(pose)
            check(not out.stop_requested,"riding the manual on the kerb: "..tostring(out.issue))
            local a=out.presentation_pose
            if math.abs(a.movement_bike_pitch)>math.rad(8) then pitched+=1 end
            check((a.rider_shift==nil)==(a.rider_standing==nil),"the standing goes with the shift: "..tostring(a.rider_standing))
            local now=a.rider_standing or 0
            check(math.abs(now-standing)<=4*h+1e-9,string.format("step %d: the rider stands up or sits down no faster than 4 a second, %.3f to %.3f",
                i,standing,now))
            standing=now
            stood=stood or now==1
            sat=stood and a.rider_shift==nil
            -- As Core poses the rider (bike_runtime_core pose_step).
            local c=MP.compose({bike={center_of_mass=pose.position,rotation=pose.rotation},articulation={steer=a.steer,
                crank_phase=a.crank_phase,movement_bike_pitch=a.movement_bike_pitch,movement_bike_lift=a.movement_bike_lift,
                movement_bike_shift=a.movement_bike_shift},rider=a.rider_shift~=nil and MP.manual_rider(a.rider_shift,a.rider_standing,a.rider_nose,a.rider_over) or nil})
            local hips=c.planned.hips.rotation
            if last then
                local turned=angle(hips,last)
                most=math.max(most,turned)
                check(turned<2.5,string.format("step %d: the rider's hips turn %.2f degrees in a tick",i,turned))
                -- The body is posed still, so the hips' move in the world is their move on the bike.
                local moved=M.length(M.sub(c.planned.hips.position,last_at))
                farthest=math.max(farthest,moved)
                check(moved<=.015,string.format("step %d: the hips move %.1f mm in a tick",i,moved*1000))
            end
            last,last_at=hips,c.planned.hips.position
        end
        for i=1,40 do step(i) end
        check(stood,"the rider stands in the manual")
        w.set_pad(0)
        for i=41,100 do step(i) end
        check(sat,"and sits once it is let go")
        check(pitched==100,"the bike is drawn pitched on the kerb throughout: "..pitched)
        print(string.format("MEASURE kerb manual: hips turn %.2f degrees and move %.1f mm a tick at most",most,farthest*1000))
    end)
    case(function() -- Into and out of a manual the drawn hips move no more than 15 mm a tick on the bike, and come to rest on the physics' shift.
        -- The body moves here, every step accepted as in game. Eased a tenth of a second first order toward the
        -- physics' shift taken to the centimetre, the hips moved 36 to 39 mm on a manual's first tick in game (mn8,
        -- mn10, photo3) and 54 to 67 mm a tick coming out, 43 where a rider sitting down met the saddle's back edge.
        local Q=MP.math
        local worst,worst_at,rest,limited,steady,moving=0,nil,0,0,0,0
        for _,row in ipairs({{-.53,3},{-.72,4},{-.53,6},{-.72,2}}) do
            local back,speed=row[1],row[2]
            local what=string.format("stick %.2f at %d m/s",back,speed)
            local w=harness(flat)
            w.prompt=true
            local b=World.place(World.terrain.flat(),{speed=speed})
            local manual,last,ended,drawn_was=false,nil,nil,nil
            for step=1,300 do
                if step==41 then w.set_pad(back) elseif step==161 then w.set_pad(0) end
                local out
                out,b=w.ride_step(b)
                check(not out.stop_requested,what..": the ride goes on: "..tostring(out.issue))
                local a=out.presentation_pose
                -- As Core poses the rider (bike_runtime_core pose_step), measured on the bike.
                local body=w.samples[w.serial]
                local frame={center_of_mass={body.position.x,body.position.y,body.position.z},rotation=body.rotation}
                local c=MP.compose({bike=frame,articulation={steer=a.steer,crank_phase=a.crank_phase,movement_bike_pitch=a.movement_bike_pitch,
                    movement_bike_lift=a.movement_bike_lift,movement_bike_shift=a.movement_bike_shift},
                    rider=a.rider_shift~=nil and MP.manual_rider(a.rider_shift,a.rider_standing,a.rider_nose,a.rider_over) or nil})
                check(c~=nil and MP.validate_pose(c.pose),what..": the rider composes")
                if c.diagnostics.saddle_limited then limited+=1 end
                local hip=Q.turn(Q.conjugate(body.rotation),M.sub(c.planned.hips.position,frame.center_of_mass))
                if last and step>40 then
                    local moved=M.length(M.sub(hip,last))
                    if moved>worst then worst,worst_at=moved,string.format("%s, step %d",what,step) end
                end
                last=hip
                if step<=160 then manual=manual or w.model.manual_active==true end
                if step==160 then
                    check(w.model.manual_active==true and a.rider_shift~=nil,what..": the manual is held two seconds")
                    local off=math.abs(a.rider_shift-w.model.manual_shift)
                    rest=math.max(rest,off)
                    check(off<=.0075+1e-9,string.format("%s: held, the drawn shift %.4f is the physics' %.4f to under a centimetre",what,
                        a.rider_shift,w.model.manual_shift))
                end
                if step>140 and step<=160 and a.rider_shift~=nil then steady=math.max(steady,math.abs(a.rider_shift-w.model.manual_shift)) end
                -- Over the second second of the hold the physics' shift drifts 1 to 1.4 cm as it balances; the drawn one
                -- moves on only each centimetre of it, and rests between.
                if step>100 and step<=160 and a.rider_shift~=drawn_was then moving+=1 end
                drawn_was=a.rider_shift
                if step>160 and a.rider_shift==nil and not ended then ended=step end
            end
            check(manual,what..": a manual")
            check(ended~=nil and ended<=280,what..": ordinary riding is back after it: "..tostring(ended))
        end
        check(worst<=.015,string.format("the hips move at most %.1f mm a tick on the bike (%s)",worst*1000,tostring(worst_at)))
        check(limited==0,"the saddle's back edge never holds the hips: "..limited)
        check(moving<=160,"held, the drawn shift rests on a third or more of the second second of each manual: it moved on "..moving.." of 240 steps")
        print(string.format("MEASURE manual in and out: hips move %.1f mm a tick at most (%s); held, drawn shift within %.4f of the physics' (%.4f over the last third of a second), moving on %d of 240 held steps",
            worst*1000,tostring(worst_at),rest,steady,moving))
    end)
    case(function() -- Not pedalling, the cranks come round to the nearer level at a backpedal's pace, never driving the wheel, and pedalling takes them on from there.
        local ratio=25/9
        local flat_cranks=math.atan2(Geometry.pedals[1][2]-Geometry.bottom_bracket[2],Geometry.pedals[1][3]-Geometry.bottom_bracket[3])
        local function off_level(phase) local off=(phase-flat_cranks)%math.pi return math.min(off,math.pi-off) end
        local function turn_of(from,to) return math.atan2(math.sin(to-from),math.cos(to-from)) end
        local slowest,slowest_at,fastest,pedalled,resumed,backward,forward=0,nil,0,0,0,0,0
        local starts={}
        for _,speed in ipairs({8,4,1,0}) do
            for k=0,23 do
                local what=string.format("%d m/s, start %d",speed,k)
                local w=harness(flat)
                w.prompt=true
                local ridden=level();ridden.velocity={0,0,4}
                check(steps(w,ridden,3)==nil,"riding before pedalling")
                -- Pedalled at 4 m/s for a different time each, so the cranks are let go at 24 phases round the turn.
                w.set_pad(0,0,true)
                local last=w.step(ridden).presentation_pose.crank_phase
                for _=1,3*k+2 do
                    local out=w.step(ridden)
                    local now=out.presentation_pose.crank_phase
                    if w.model.pedaling==true then
                        pedalled+=1
                        local want=w.model.wheels[2].angular_speed*h/ratio
                        check(math.abs(turn_of(last,now)-want)<1e-9,string.format("%s: pedalling, the cranks turn %.5f, the rear wheel's %.5f through the gearing",
                            what,turn_of(last,now),want))
                    end
                    last=now
                end
                if speed==4 then starts[#starts+1]=string.format("%.0f",math.deg(off_level(last))) end
                -- Let go, rolling on at this speed.
                local coasting=level();coasting.velocity={0,0,speed}
                w.set_pad(0)
                local came,rested,way,idle=nil,nil,nil,0
                for i=1,90 do
                    local out=w.step(coasting)
                    local now=out.presentation_pose.crank_phase
                    local turn=turn_of(last,now)
                    local rear=w.model.wheels[2].angular_speed
                    check(w.model.pedaling~=true or i<=2,what..": the rider stops pedalling")
                    if w.model.pedaling~=true then idle+=1 end
                    -- A tenth of a second first, so a tap of A does not swing them about.
                    if idle<=5 then check(turn==0 or w.model.pedaling==true,what..": the cranks hold a tenth of a second first") end
                    check(math.abs(turn)<=7*h+1e-9,string.format("%s, step %d: the cranks turn %.4f rad, no faster than a backpedal",what,i,turn))
                    check(turn<=math.max(rear,0)*h/ratio+1e-9,string.format("%s, step %d: forward %.4f, never faster than the rear wheel turns them, %.4f",
                        what,i,turn,math.max(rear,0)*h/ratio))
                    fastest=math.max(fastest,math.abs(turn))
                    if turn~=0 then
                        way=way or (turn>0 and 1 or -1)
                        check(turn*way>0,what..": the cranks go one way to the level")
                    end
                    if not came and off_level(now)<=math.rad(5) then came=i end
                    if rested then check(turn==0,what..": level, the cranks stay there") end
                    if not rested and off_level(now)<1e-9 then rested=i end
                    last=now
                end
                if way==1 then forward+=1 elseif way==-1 then backward+=1 end
                check(came~=nil and came<=36,string.format("%s: within 5 degrees of level in .6 s: step %s",what,tostring(came)))
                check(rested~=nil,what..": and come to rest level")
                if came and came>slowest then slowest,slowest_at=came,what end
                -- Pedalling again takes the cranks on from where they are.
                w.set_pad(0,0,true)
                for i=1,20 do
                    local out=w.step(ridden)
                    local now=out.presentation_pose.crank_phase
                    local want=w.model.pedaling==true and w.model.wheels[2].angular_speed*h/ratio or 0
                    check(math.abs(turn_of(last,now)-want)<1e-9,string.format("%s, step %d: pedalling again, the cranks turn %.5f for %.5f",
                        what,i,turn_of(last,now),want))
                    if want~=0 then resumed+=1 end
                    last=now
                end
            end
        end
        -- Let go at 4 m/s, the cranks start forward to the level ahead, and the bike stops under them: they go back to
        -- the level behind instead of waiting forward on a wheel that no longer turns them.
        local stopped_back,stopped_slowest=0,0
        for k=0,23 do
            local what=string.format("stopped, start %d",k)
            local w=harness(flat)
            w.prompt=true
            local ridden=level();ridden.velocity={0,0,4}
            check(steps(w,ridden,3)==nil,"riding before pedalling")
            w.set_pad(0,0,true)
            local last=w.step(ridden).presentation_pose.crank_phase
            for _=1,3*k+2 do last=w.step(ridden).presentation_pose.crank_phase end
            w.set_pad(0)
            local started=nil
            for i=1,20 do
                local now=w.step(ridden).presentation_pose.crank_phase
                if turn_of(last,now)>0 then started=i;last=now break end
                last=now
            end
            if started then
                local still=level()
                local rested=nil
                for i=1,90 do
                    local now=w.step(still).presentation_pose.crank_phase
                    local turn=turn_of(last,now)
                    local rear=w.model.wheels[2].angular_speed
                    check(math.abs(turn)<=7*h+1e-9 and turn<=math.max(rear,0)*h/ratio+1e-9,string.format("%s, step %d: the cranks turn %.4f",what,i,turn))
                    if turn<0 then stopped_back+=1 end
                    if not rested and off_level(now)<1e-9 then rested=i end
                    last=now
                end
                check(rested~=nil and rested<=60,what..": the cranks come level within a second of the stop: "..tostring(rested))
                stopped_slowest=math.max(stopped_slowest,rested or math.huge)
            end
        end
        check(stopped_back>0,"some went back")
        print(string.format("MEASURE cranks stopped under a forward move: level within %.3f s of the stop",stopped_slowest*h))
        check(pedalled>0 and resumed>0,"the rider pedals")
        check(forward>0 and backward>0,"rolling, the cranks go forward to a level that is sooner that way, and back otherwise")
        print("MEASURE cranks let go at 4 m/s "..table.concat(starts," ").." degrees off level")
        print(string.format("MEASURE cranks within 5 degrees of level in %.3f s at most (%s), %.2f rad/s at most; %d went forward, %d back",
            slowest*h,tostring(slowest_at),fastest/h,forward,backward))
    end)
    case(function() -- In a nose manual the rider is drawn standing, hips forward over the bars by the physics' shift, and sits back down after it.
        local w=harness(flat)
        w.prompt=true
        local pose=nose_down(28,4)
        check(in_nose_manual(w,pose,120)==nil,"a nose manual held at 28 degrees for two seconds")
        local out=w.step(pose)
        local shown=out.presentation_pose
        check(w.model.nose_manual_active==true and w.model.manual_active~=true,"the kernel holds the nose manual")
        check(shown.rider_shift~=nil and shown.rider_shift>=-.30 and shown.rider_shift<=-.05,
            "the rider is drawn shifted forward by the weight the hold takes: "..tostring(shown.rider_shift).." against the model's "
            ..tostring(w.model.manual_shift))
        check(math.abs(shown.rider_shift-w.model.manual_shift)<=.0075+1e-9,"held, the drawn shift is the physics' to under a centimetre: "
            ..tostring(shown.rider_shift).." against "..tostring(w.model.manual_shift))
        local flat_cranks=math.atan2(Geometry.pedals[1][2]-Geometry.bottom_bracket[2],Geometry.pedals[1][3]-Geometry.bottom_bracket[3])
        local off=(shown.crank_phase-flat_cranks)%math.pi
        check(math.min(off,math.pi-off)<1e-9,"the cranks are level: "..tostring(shown.crank_phase))
        check(shown.rider_standing==1 and shown.rider_nose==1 and shown.rider_over==1,"standing, all the way over the bars: "
            ..tostring(shown.rider_standing).." "..tostring(shown.rider_nose).." "..tostring(shown.rider_over))
        -- As Core composes it, against the ordinary rider on the same body: the hips travel along the road as far as the
        -- physics moves the weight, with the hands on the grips and the feet on the pedals.
        local body=w.samples[w.serial]
        local frame={center_of_mass={body.position.x,body.position.y,body.position.z},rotation=body.rotation}
        local articulation={steer=shown.steer,crank_phase=shown.crank_phase}
        local rider=MP.manual_rider(shown.rider_shift,shown.rider_standing,shown.rider_nose,shown.rider_over)
        local over=MP.compose({bike=frame,articulation=articulation,rider=rider})
        local still=MP.compose({bike=frame,articulation=articulation})
        local travel=over.targets.hips[3]-still.targets.hips[3]
        check(math.abs(travel+w.model.manual_shift)<=.03,string.format("the hips go %.3f m forward along the road for the physics' %.3f",
            travel,-w.model.manual_shift))
        check(math.abs(over.targets.hips[2]-still.targets.hips[2])<=.03,"at the height they ride at: "
            ..tostring(over.targets.hips[2]-still.targets.hips[2]))
        local miss=0
        for i,name in ipairs({"left_arm","right_arm"}) do
            local p=over.planned[name]
            local palm=MP.math.turn(p.tip_rotation,{MP.CONTACTS.palm_reach,0,(i==1 and 1 or -1)*(MP.CONTACTS.grip_radius+MP.CONTACTS.palm_gap)})
            miss=math.max(miss,M.length(M.sub(M.add(p.tip,palm),over.targets.grips[i])))
            check(not over.diagnostics.limbs[name].clamped,"the "..name.." reaches its grip")
        end
        for i,name in ipairs({"left_leg","right_leg"}) do
            miss=math.max(miss,M.length(M.sub(over.planned[name].tip,over.targets.ankles[i])))
            check(not over.diagnostics.limbs[name].clamped,"the "..name.." reaches its pedal")
        end
        check(miss<=1e-4,"the hands hold the grips and the feet the pedals: "..miss)
        print(string.format("MEASURE nose manual at 28 degrees: physics shift %.3f, drawn %.3f, hips forward %.3f m and up %.3f m along the road",
            -w.model.manual_shift,-shown.rider_shift,travel,over.targets.hips[2]-still.targets.hips[2]))
        -- Posed level, the bike is never thrown up, so the kernel's throw runs on: far past what the pose takes.
        local level_w=harness(flat)
        local ridden=level();ridden.velocity={0,0,4}
        check(steps(level_w,ridden,3)==nil,"riding before the nose manual")
        level_w.set_pad(.53)
        local model_past,drawn_past,lowest,stood=false,false,0,0
        for i=1,40 do
            local out=level_w.step(ridden)
            check(not out.stop_requested,"the throw rides on: "..tostring(out.issue))
            local m,a=level_w.model,out.presentation_pose
            if m.nose_manual_active==true and m.manual_shift< -.30 then model_past=true end
            if a.rider_shift then
                drawn_past=drawn_past or a.rider_shift< -.10
                lowest=math.min(lowest,a.rider_shift)
                stood=a.rider_standing
            end
        end
        check(model_past,"the kernel's throw asks more than .3 m of the weight forward")
        check(drawn_past and lowest>=-.30-1e-12,"the drawn shift follows it and stops at .3 m: "..lowest)
        -- Let go: the shift eases out, the rider sits down, and the hips keep their line as they come back. Moving
        -- forward when the stick goes, the shift first slows to a stop, no more than 12 mm on, then comes back.
        level_w.set_pad(0)
        local start=lowest
        local last,peak,turned,standing,sitting,fields,gone=lowest,math.abs(lowest),false,stood,false,0,nil
        local nose_was,over_was=nil,nil
        for i=1,120 do
            local out=level_w.step(ridden)
            check(not out.stop_requested,"letting go rides on: "..tostring(out.issue))
            local a=out.presentation_pose
            if a.rider_shift~=nil then
                local now=math.abs(a.rider_shift)
                check(a.rider_shift<=0,"step "..i..": the shift comes back to none without going past it: "..a.rider_shift)
                if now<math.abs(last)-1e-12 then turned=true end
                check(not turned or now<=math.abs(last)+1e-12,string.format("step %d: once on its way back the shift eases toward none, %.4f to %.4f",
                    i,last,a.rider_shift))
                peak=math.max(peak,now)
                nose_was=nose_was or a.rider_nose;over_was=over_was or a.rider_over or 0
                check(a.rider_nose==nose_was and (a.rider_over or 0)==over_was,"step "..i..": the hips keep their line as the shift eases out: "
                    ..tostring(a.rider_nose).." "..tostring(a.rider_over))
                last=a.rider_shift
            else
                check(a.rider_standing==nil and a.rider_nose==nil and a.rider_over==nil,"step "..i..": the standing and the nose go with the shift")
            end
            -- Still standing up when the stick goes, the rider first stops rising, then sits down.
            local sat=a.rider_standing or 0
            if sat<standing-1e-12 then sitting=true end
            check(math.abs(sat-standing)<=4*h+1e-9 and (not sitting or sat<=standing+1e-12),string.format(
                "step %d: the rider sits down no faster than 4 a second, %.3f to %.3f",i,standing,sat))
            standing=sat
            if a.rider_shift==nil and not gone then gone=i end
            if i==120 then for _ in pairs(a) do fields+=1 end end
        end
        check(peak<=math.abs(start)+.012,string.format("the shift goes on at most 12 mm as it stops: %.4f from %.4f",peak,math.abs(start)))
        check(gone~=nil and gone<=110 and fields==8,"and ordinary riding's eight-field pose is back from step "..tostring(gone)..": "..fields)
        -- A rear manual is drawn as before: no nose.
        local rear=harness(flat)
        local back=level();back.velocity={0,0,4}
        check(in_manual(rear,back,12)==nil and rear.model.manual_active==true,"a rear manual")
        local drawn=rear.step(back).presentation_pose
        check(drawn.rider_shift>0 and drawn.rider_nose==nil,"a rear manual is drawn shifted back with no nose: "..tostring(drawn.rider_nose))
        -- A nose manual rolled onto a kerb is drawn lifted onto it on its front wheel, not nodded about the rear in the air.
        local kerb=false
        local kerbed=harness(function(from,to,count,i)
            if count==2 and i==1 and kerb then return hit(from,to,from.y-R+.15,{0,1,0}) end
            return flat(from,to)
        end)
        kerbed.prompt=true
        local on_road=nose_down(28,4)
        check(in_nose_manual(kerbed,on_road,12)==nil and kerbed.model.nose_manual_active==true,"a nose manual on the road")
        check(kerbed.step(on_road).presentation_pose.movement_bike_lift==nil,"on the road the nose manual draws the bike on its body")
        kerb=true
        local lifts={}
        for i=1,6 do
            local out=kerbed.step(on_road)
            check(not out.stop_requested,"riding the nose manual onto the kerb: "..tostring(out.issue))
            local lifted=out.presentation_pose
            check(math.abs(lifted.movement_bike_pitch)<1e-6,
                "the drawn bike is not pitched about its rear wheel in the air: "..lifted.movement_bike_pitch)
            local front,body=drawn_touch(kerbed.samples[kerbed.serial],lifted,4)
            local behind,rear_body=drawn_touch(kerbed.samples[kerbed.serial],lifted,3)
            local up=front[2]-body[2]
            lifts[i]=string.format("%.3f",up)
            check(math.abs(front[1]-body[1])<.002 and math.abs(front[3]-body[3])<.002,string.format(
                "the front tyre is drawn straight up off where the body's touches, not ahead of it: %.4f %.4f",front[1]-body[1],front[3]-body[3]))
            check(M.length(M.sub(M.sub(behind,rear_body),M.sub(front,body)))<.002,"and the rear goes up with it: the whole bike is lifted")
            if i>=3 then
                check(math.abs(front[2]-(.15-.01))<.002,"the front tyre is drawn on the kerb top, its bottom at "..front[2].." against .15")
            end
        end
        check(lifts[1]=="0.050" and lifts[2]=="0.100" and lifts[3]=="0.140","it comes up 5 cm a step: "..table.concat(lifts," "))
    end)
    case(function() -- Into a nose manual from riding, held, let go, or turned into a manual, the knees stay off the bars wherever the cranks stopped.
        local Q,C=MP.math,MP.CONTACTS
        local bar_radius=.055*Geometry.scale
        local function sub(a,b) return {a[1]-b[1],a[2]-b[2],a[3]-b[3]} end
        local function dot(a,b) return a[1]*b[1]+a[2]*b[2]+a[3]*b[3] end
        local function distance(a,b) local d=sub(a,b) return math.sqrt(dot(d,d)) end
        -- The least distance from segment p1-q1 to segment p2-q2.
        local function segment(p1,q1,p2,q2)
            local d1,d2,r=sub(q1,p1),sub(q2,p2),sub(p1,p2)
            local a,e,f=dot(d1,d1),dot(d2,d2),dot(d2,r)
            local s,t
            if a<=1e-12 then s=0;t=math.clamp(f/e,0,1)
            else
                local c,b=dot(d1,r),dot(d1,d2)
                local den=a*e-b*b
                s=den~=0 and math.clamp((b*f-c*e)/den,0,1) or 0
                t=(b*s+f)/e
                if t<0 then t=0;s=math.clamp(-c/a,0,1) elseif t>1 then t=1;s=math.clamp((b-c)/a,0,1) end
            end
            return distance({p1[1]+d1[1]*s,p1[2]+d1[2]*s,p1[3]+d1[3]*s},{p2[1]+d2[1]*t,p2[2]+d2[2]*t,p2[3]+d2[3]*t})
        end
        local flat_cranks=math.atan2(Geometry.pedals[1][2]-Geometry.bottom_bracket[2],Geometry.pedals[1][3]-Geometry.bottom_bracket[3])
        local function off_level(phase) local off=(phase-flat_cranks)%math.pi return math.min(off,math.pi-off) end
        -- The rider as Core composes it (bike_runtime_core pose_step: the body one read behind, the drawn articulation,
        -- MP.manual_rider), at the cranks drawn, against the bars drawn with it. The worst is kept: the knees, thighs and
        -- shins to the bar line less its radius, the torso to it, the lowest joint over the flat road, and how far a palm
        -- or an ankle misses its grip or pedal.
        local worst={legs=math.huge,torso=math.huge,ground=math.huge,miss=0,refused=0,clamped=0,poses=0,over=0,step=0}
        local hips_was=nil
        local function sweep(w,shown,label)
            local body=w.samples[w.serial-1]
            local rider=nil
            if shown.rider_shift~=nil then
                local why
                rider,why=MP.manual_rider(shown.rider_shift,shown.rider_standing,shown.rider_nose,shown.rider_over)
                if not rider then worst.refused+=1;worst.why=worst.why or label..": "..tostring(why) end
            end
            worst.over=math.max(worst.over,shown.rider_over or 0)
            local out,why=MP.compose({bike={center_of_mass={body.position.x,body.position.y,body.position.z},rotation=body.rotation},
                articulation={steer=shown.steer or 0,crank_phase=shown.crank_phase,movement_bike_pitch=shown.movement_bike_pitch or 0,
                    movement_bike_lift=shown.movement_bike_lift,movement_bike_shift=shown.movement_bike_shift},rider=rider})
            worst.poses+=1
            if not out or not MP.validate_pose(out.pose) then
                worst.refused+=1;worst.why=worst.why or label..": "..tostring(why)
                return
            end
            local left,right=out.targets.grips[1],out.targets.grips[2]
            for i,name in ipairs({"left_arm","right_arm"}) do
                local p=out.planned[name]
                local palm=Q.turn(p.tip_rotation,{C.palm_reach,0,(i==1 and 1 or -1)*(C.grip_radius+C.palm_gap)})
                worst.miss=math.max(worst.miss,distance({p.tip[1]+palm[1],p.tip[2]+palm[2],p.tip[3]+palm[3]},out.targets.grips[i]))
                if out.diagnostics.limbs[name].clamped then worst.clamped+=1 end
                worst.ground=math.min(worst.ground,p.root[2],p.middle[2],p.tip[2])
            end
            for i,name in ipairs({"left_leg","right_leg"}) do
                local p=out.planned[name]
                worst.miss=math.max(worst.miss,distance(p.tip,out.targets.ankles[i]))
                if out.diagnostics.limbs[name].clamped then worst.clamped+=1 end
                local legs=math.min(segment(p.middle,p.middle,right,left),segment(p.root,p.middle,right,left),
                    segment(p.middle,p.tip,right,left))-bar_radius
                if legs<worst.legs then
                    worst.legs,worst.at=legs,string.format("%s, cranks %.0f degrees off level, over %.2f",label,math.deg(off_level(shown.crank_phase)),
                        shown.rider_over or 0)
                end
                worst.ground=math.min(worst.ground,p.root[2],p.middle[2],p.tip[2])
            end
            local l,r=out.planned.left_arm.root,out.planned.right_arm.root
            worst.torso=math.min(worst.torso,segment(out.targets.hips,{(l[1]+r[1])/2,(l[2]+r[2])/2,(l[3]+r[3])/2},right,left)-bar_radius)
            local hips=Q.turn(Q.conjugate(body.rotation),M.sub(out.planned.hips.position,{body.position.x,body.position.y,body.position.z}))
            if hips_was then
                local moved=M.length(M.sub(hips,hips_was))
                if moved>worst.step then worst.step,worst.step_at=moved,label end
            end
            hips_was=hips
        end
        -- Pedalled at 4 m/s for a different time each, so the cranks stop at 24 phases round the turn, then at once into
        -- the nose manual: the bike pitched down onto its front wheel a degree and a half a step to 28, held there, then
        -- let go and set back down on both wheels. Not pedalling, the cranks only come toward level.
        local starts={}
        for k=0,23 do
            local w=harness(flat)
            w.prompt=true
            local ridden=level();ridden.velocity={0,0,4}
            check(steps(w,ridden,3)==nil,"riding before the nose manual")
            w.set_pad(0,0,true)
            local cranks=nil
            for _=1,3*k+1 do cranks=w.step(ridden).presentation_pose.crank_phase end
            starts[#starts+1]=string.format("%.0f",math.deg(off_level(cranks)))
            local plan={}
            for i=1,20 do plan[#plan+1]={.53,28*i/20,"lifting"} end
            for _=1,60 do plan[#plan+1]={.53,28,"held"} end
            for i=1,20 do plan[#plan+1]={0,28*(20-i)/20,"dropping"} end
            for _=1,40 do plan[#plan+1]={0,0,"riding after"} end
            local first,drawn,last,way=nil,0,cranks,nil
            hips_was=nil
            for i,leg in ipairs(plan) do
                w.set_pad(leg[1])
                local out=w.step(nose_down(leg[2],4))
                local what=string.format("start %d, %s, step %d",k,leg[3],i)
                check(not out.stop_requested,what..": the nose manual rides on: "..tostring(out.issue))
                local shown=out.presentation_pose
                local turn=math.atan2(math.sin(shown.crank_phase-last),math.cos(shown.crank_phase-last))
                check(math.abs(turn)<=7*h+1e-9,string.format("%s: the cranks turn %.3f rad in a step",what,turn))
                -- Not pedalling, they go one way, to a level, and stay there.
                if turn~=0 then
                    way=way or (turn>0 and 1 or -1)
                    check(turn*way>0,what..": the cranks do not turn back")
                end
                last=shown.crank_phase
                if shown.rider_shift~=nil then
                    drawn+=1
                    if not first then
                        first=i
                        check(w.model.nose_manual_active==true and shown.rider_shift<0 and shown.rider_nose==1,
                            what..": drawn forward from its first step, the rider is on the front wheel: "..tostring(shown.rider_nose))
                    end
                end
                if i==80 then
                    check(off_level(shown.crank_phase)<1e-9 and shown.rider_over==1,string.format(
                        "%s: by the end of the hold the cranks are level and the hips all the way over the bars: %.1f degrees, over %s",
                        what,math.deg(off_level(shown.crank_phase)),tostring(shown.rider_over)))
                end
                sweep(w,shown,what)
            end
            check(first~=nil and first<=8 and drawn>=80 and w.step(ridden).presentation_pose.rider_shift==nil,
                "the nose manual is drawn from step "..tostring(first).." for "..drawn.." steps and gone after")
        end
        print("MEASURE nose manual sweep: cranks stopped "..table.concat(starts," ").." degrees off level")
        -- From a nose manual held level into a manual: the forward shift eases back with the hips kept on their line.
        local into=harness(flat)
        into.prompt=true
        hips_was=nil
        local ridden=level();ridden.velocity={0,0,4}
        check(in_nose_manual(into,ridden,60)==nil and into.model.nose_manual_active==true,"a nose manual held level")
        into.set_pad(-.53)
        local held,manual=0,false
        for i=1,60 do
            local out=into.step(ridden)
            check(not out.stop_requested,"into a manual: "..tostring(out.issue))
            local shown=out.presentation_pose
            manual=manual or into.model.manual_active==true
            if shown.rider_shift~=nil and shown.rider_shift<0 and into.model.manual_active==true then
                held+=1
                check(shown.rider_nose==1,"step "..i..": in the manual the hips keep the nose manual's line while the shift is still forward: "
                    ..tostring(shown.rider_nose))
            end
            sweep(into,shown,string.format("into a manual, step %d",i))
        end
        check(manual and held>=1,"the manual comes in with the shift still forward, for "..held.." steps")
        check(worst.refused==0 and worst.poses==24*140+60,"every rider composes and keeps the joint contract: "..tostring(worst.why))
        check(worst.over==1,"the hips go all the way over the bars")
        check(worst.clamped==0 and worst.miss<=1e-4,string.format("the hands hold their grips and the feet their pedals: %d clamped, %.6f off",
            worst.clamped,worst.miss))
        -- Measured: hips up over the bars kept every crank phase 10 cm off them, and over the bars at level cranks 8.5 cm
        -- or more. Taken over before the cranks came level, the knees met the bars a pedal high in front.
        check(worst.legs>=.05,string.format("the knees, thighs and shins stay %.3f off the bars (%s)",worst.legs,tostring(worst.at)))
        check(worst.torso>=.25,string.format("and the torso %.3f",worst.torso))
        check(worst.ground>=.2,string.format("no part of the rider goes near the road: %.3f",worst.ground))
        check(worst.step<=.015,string.format("the hips move at most %.1f mm a tick on the bike (%s)",worst.step*1000,tostring(worst.step_at)))
        print(string.format("MEASURE nose manual sweep: knees %.3f off the bars at worst (%s), torso %.3f, lowest joint %.3f, hips %.1f mm a tick at most (%s)",
            worst.legs,tostring(worst.at),worst.torso,worst.ground,worst.step*1000,tostring(worst.step_at)))
    end)
    case(function() -- loop2 in game: the VM stopped at 64 MB after four rides, every Ride of the launch kept.
        -- Luau's weak keys are not ephemerons, and a Ride's api leads back to the Core that holds the Ride.
        -- A full collection has run once a table nothing holds is gone, made in its own call (a register of the running
        -- function stays marked until it is reused).
        local function collected()
            local sentinel=setmetatable({},{__mode="v"})
            local function plant() sentinel[1]={} end
            plant()
            local ring={}
            for i=1,4000000 do ring[i%64+1]={i,i,i,i};if sentinel[1]==nil then return true end end
            return false
        end
        local probe=setmetatable({},{__mode="v"})
        local function make()
            local api={}
            local ride=Ride.new(api,{mapping=Mapping.new(),contact=Contact},{})
            api.owner=ride
            check(ride:status().phase=="stopped","a Ride on a stand-in api stops at once")
            probe[1]=ride
        end
        make()
        check(collected() and collected(),"the collector ran twice")
        check(probe[1]==nil,"a Ride nothing holds is collected, though its api leads back to it")
    end)
    return {cases=cases,assertions=n,native_authority=false,constructed=true}
end
return T

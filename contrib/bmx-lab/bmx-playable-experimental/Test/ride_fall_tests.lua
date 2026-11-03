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
local T={}
local h=Forces.native_seconds
local R=Geometry.wheel_radius
local function roll_of(angle) return {0,0,math.sin(angle/2),math.cos(angle/2)} end
local function pitch_of(angle) return {math.sin(angle/2),0,0,math.cos(angle/2)} end
-- ground(from,to) answers each ray with a row or {status="clear"}.
local function harness(ground)
    local body,incarnation,lease,epoch=newproxy(),newproxy(),newproxy(),newproxy()
    local w={serial=1000,time=1,submits={},requested={},samples={},ground=ground}
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
    -- The real stage, behind a recorder of the controls Ride sends it.
    local stage=Stage.new()
    local force={hop_policy=stage.hop_policy,tuning=stage.tuning}
    function force.preview(_,...) w.controls=select(5,...);return stage:preview(...) end
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
    -- From now on every step brings a fresh pad observation a native step on, with the right stick here.
    local fresh
    function w.set_pad(right_y)
        local moved=table.clone(pad)
        moved.buttons=table.clone(pad.buttons);moved.right_y=right_y
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
        local v=pose.velocity or {0,0,0}
        local p=pose.position
        local raw={epoch=epoch,serial=tostring(w.serial),time=w.time,seconds=h,mass=Geometry.mass,
            position=vector.create(p[1],p[2],p[3]),velocity=vector.create(v[1],v[2],v[3]),
            angular_velocity=vector.create(0,0,0),inertia=vector.create(26,32,10),rotation=pose.rotation}
        w.samples[w.serial]=raw
        return ride:observe(source,raw,{now_ms=1000,focused=true,menu_open=false,loaded=true})
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
    case(function() -- The right stick part way back lifts the front, through Mapping, the stage and the packet.
        local w=harness(flat)
        local pose=level();pose.velocity={0,0,4}
        check(in_manual(w,pose,12)==nil,"a manual is ridden")
        check(w.controls.manual>.4,"the manual reaches the stage: "..tostring(w.controls.manual))
        check(w.submits[#w.submits].torque.x< -150,"and the packet lifts the nose: "..w.submits[#w.submits].torque.x)
        local shown=w.step(pose).presentation_pose
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
        check(in_manual(w,pose,10)==nil,"the manual is ridden")
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
        steps(w,pose,3)
        w.set_pad(-.53)
        local function angle(a,b) return math.deg(2*math.acos(math.min(1,math.abs(a[1]*b[1]+a[2]*b[2]+a[3]*b[3]+a[4]*b[4])))) end
        local last,standing,most,pitched,stood,sat=nil,0,0,0,false,false
        local function step(i)
            local out=w.step(pose)
            check(not out.stop_requested,"riding the manual on the kerb: "..tostring(out.issue))
            local a=out.presentation_pose
            if math.abs(a.movement_bike_pitch)>math.rad(8) then pitched+=1 end
            check((a.rider_shift==nil)==(a.rider_standing==nil),"the standing goes with the shift: "..tostring(a.rider_standing))
            local now=a.rider_standing or 0
            check(math.abs(now-standing)<=h/.1+1e-9,string.format("step %d: the rider stands up or sits down over a tenth of a second, %.3f to %.3f",
                i,standing,now))
            standing=now
            stood=stood or now==1
            sat=stood and a.rider_shift==nil
            -- As Core poses the rider (bike_runtime_core pose_step).
            local c=MP.compose({bike={center_of_mass=pose.position,rotation=pose.rotation},articulation={steer=a.steer,
                crank_phase=a.crank_phase,movement_bike_pitch=a.movement_bike_pitch,movement_bike_lift=a.movement_bike_lift,
                movement_bike_shift=a.movement_bike_shift},rider=a.rider_shift~=nil and MP.manual_rider(a.rider_shift,a.rider_standing) or nil})
            local hips=c.planned.hips.rotation
            if last then
                local turned=angle(hips,last)
                most=math.max(most,turned)
                check(turned<2.5,string.format("step %d: the rider's hips turn %.2f degrees in a tick",i,turned))
            end
            last=hips
        end
        for i=1,14 do step(i) end
        check(stood,"the rider stands in the manual")
        w.set_pad(0)
        for i=15,54 do step(i) end
        check(sat,"and sits once it is let go")
        check(pitched==54,"the bike is drawn pitched on the kerb throughout: "..pitched)
    end)
    return {cases=cases,assertions=n,native_authority=false,constructed=true}
end
return T

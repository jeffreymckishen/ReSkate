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
    return {cases=cases,assertions=n,native_authority=false,constructed=true}
end
return T

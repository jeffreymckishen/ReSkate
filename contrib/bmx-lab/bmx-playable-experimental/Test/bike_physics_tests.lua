-- How the bike rides, on the real ForceStage and kernel with the two-step command delay and InFlight.fold Ride uses.
-- Constructed terrain, wheel rays as Ride casts them, no native collision and no game. These are model numbers.
local Stage=require("./force_stage")
local Forces=require("./forces")
local InFlight=require("./ride_inflight")
local World=require("./sim_world")
local G=require("./bike_geometry")
local M=require("./force_math")
local T={}
local h=Forces.native_seconds
local gravity={0,-9.8,0}
local R=G.wheel_radius
local PROBE=.75
local Ground={}
function Ground.plane(rise_x,rise_z)
    return {height=function(x,z) return x*rise_x+z*rise_z end,grad=function() return rise_x,rise_z end}
end
-- The surface twists about the line of travel, so a bike going +z at x=0 keeps its height and meets a side slope.
function Ground.twist(angle,from,length)
    local k=math.tan(angle)
    local function bank(z) local u=math.clamp((z-from)/length,0,1);return k*u*u*(3-2*u) end
    local function slope(z)
        local u=(z-from)/length
        if u<=0 or u>=1 then return 0 end
        return k*6*u*(1-u)/length
    end
    return {height=function(x,z) return x*bank(z) end,grad=function(x,z) return bank(z),x*slope(z) end}
end
-- A smooth bump across the road, this high, from z=at for length metres.
function Ground.bump(at,height,length)
    local function u(z) return (z-at)/length end
    return {height=function(x,z) local s=u(z);if s<=0 or s>=1 then return 0 end;return height*.5*(1-math.cos(2*math.pi*s)) end,
        grad=function(x,z) local s=u(z);if s<=0 or s>=1 then return 0,0 end;return 0,height*math.pi*math.sin(2*math.pi*s)/length end}
end
-- A kicker across the road from z=at: a face this steep up to a deck this high, curved into at its foot and over at
-- its lip along blend metres.
function Ground.kicker(at,angle,blend,top)
    local k=math.tan(angle)
    local lip=at+top/k
    local function height(z)
        if z<=at then return 0 end
        if z<=at+blend then return k*(z-at)^2/(2*blend) end
        if z<=lip then return k*(z-at-blend/2) end
        if z<=lip+blend then local d=z-lip;return k*(lip-at-blend/2)+k*d-k*d*d/(2*blend) end
        return k*(lip-at-blend/2)+k*blend/2
    end
    local function slope(z)
        if z<=at or z>=lip+blend then return 0 end
        if z<=at+blend then return k*(z-at)/blend end
        if z<=lip then return k end
        return k*(1-(z-lip)/blend)
    end
    return {height=function(x,z) return height(z) end,grad=function(x,z) return 0,slope(z) end}
end
-- A kerb ramp across the road from z=at: a smooth step this high over length metres.
function Ground.rise(at,high,length)
    local function height(z) local u=math.clamp((z-at)/length,0,1);return high*u*u*(3-2*u) end
    local function slope(z) local u=(z-at)/length;if u<=0 or u>=1 then return 0 end;return high*6*u*(1-u)/length end
    return {height=function(x,z) return height(z) end,grad=function(x,z) return 0,slope(z) end}
end
local function turned(yaw) return {0,math.sin(yaw/2),0,math.cos(yaw/2)} end
local function place(ground,speed,yaw)
    local body,wheels=Forces.proposed_body(),Forces.proposed_wheels()
    local dx,dz=ground.grad(0,0)
    local n=M.unit({-dx,1,-dz})
    local q=turned(yaw or 0)
    local forward=M.turn(q,{0,0,1})
    local along=M.unit(M.sub(forward,M.mul(n,M.dot(forward,n))))
    local up=n
    local left=M.cross(up,along)
    -- The quaternion of the frame (left,up,along).
    local m00,m01,m02,m10,m11,m12,m20,m21,m22=left[1],up[1],along[1],left[2],up[2],along[2],left[3],up[3],along[3]
    local s=math.sqrt(math.max(0,1+m00+m11+m22))*2
    body.orientation=M.normalized({(m21-m12)/s,(m02-m20)/s,(m10-m01)/s,s/4})
    local lift=-math.huge
    for _,axle in ipairs({G.front_axle,G.rear_axle}) do
        local o=M.turn(body.orientation,M.sub(axle,G.com))
        lift=math.max(lift,ground.height(o[1],o[3])+R/n[2]-o[2])
    end
    body.center_of_mass={0,lift,0}
    body.linear_velocity=M.mul(along,speed)
    for _,wheel in ipairs(wheels) do wheel.angular_speed=speed/wheel.radius end
    return body,wheels
end
local function contacts(ground,body,steer)
    local q=M.normalized(body.orientation)
    local forward=M.turn(q,{0,0,1})
    local samples={}
    for i,axle in ipairs({G.front_axle_at(G,steer) or G.front_axle,G.rear_axle}) do
        local center=M.add(body.center_of_mass,M.turn(q,M.sub(axle,G.com)))
        local y=ground.height(center[1],center[3])
        if y>center[2] or y<center[2]-(R+PROBE) then samples[i]={contact={status="clear"}}
        else
            local dx,dz=ground.grad(center[1],center[3])
            local point={center[1],y,center[3]}
            local basis=M.basis(M.unit({-dx,1,-dz}),forward)
            local separation=basis and M.dot(M.sub(center,point),basis.normal)-R
            if basis and separation>=-.10 then
                samples[i]={contact={status="hit",point=point,normal=basis.normal,forward=basis.forward,surface_velocity={0,0,0}},
                    separation=separation,wheel_center=M.copy(center),wheel_radius=R,verified_plane=false,balance_normal_available=false}
            else samples[i]={contact={status="clear"}} end
        end
    end
    return samples
end
local function tilt_of(body)
    return math.deg(math.acos(math.clamp(M.turn(M.normalized(body.orientation),{0,1,0})[2],-1,1)))
end
-- ride.steps, and ride.controls(step,body,folded,forecast) -> {pedal,steer,brake,hop,manual,nose,nose_held}, from the
-- measured body and the forecast body and wheel rays the stage previews with. ride.pitch starts the
-- bike that many degrees nose up on its rear wheel, or nose down on its front wheel when it is negative, and ride.lift
-- raises it that far. ride.push(step,body,command) may return a force sent with the command, as Ride's car stop adds
-- one. Returns the peaks, and calls ride.each(step,body,out,wheels,samples) with the wheel rays this step's command
-- was made from.
local function run(ride)
    local stage=Stage.new()
    local body,wheels=place(ride.ground or Ground.plane(0,0),ride.speed or 0,ride.yaw)
    if ride.pitch then
        local a=-math.rad(ride.pitch)
        body.orientation={math.sin(a/2),0,0,math.cos(a/2)}
        local axle=M.turn(body.orientation,M.sub(ride.pitch>=0 and G.rear_axle or G.front_axle,G.com))
        body.center_of_mass={0,R-axle[2]-.005,0}
    end
    if ride.lift then body.center_of_mass={body.center_of_mass[1],body.center_of_mass[2]+ride.lift,body.center_of_mass[3]} end
    local previous
    local angle,hop_id=0,0
    local peak={tilt=0,speed=0,refused=0,slip=0,height=0,torque=0}
    local start=body.center_of_mass[2]
    for step=1,ride.steps do
        local samples=contacts(ride.ground or Ground.plane(0,0),body,angle)
        local inflight={}
        if previous then inflight[1]={age=1,force=previous.force,torque=previous.torque,
            impulse=previous.hop_applied and previous.hop_impulse or nil,impulse_id=previous.hop_applied and previous.hop_event_id or nil} end
        local folded,forecast=body,samples
        if not ride.immediate then
            folded,forecast=InFlight.fold(h,gravity,inflight,body,samples)
            assert(folded,"the forecast stays bounded")
        end
        local want=ride.controls and ride.controls(step,body,folded,forecast) or {}
        local input={pedal=want.pedal or 0,steer=want.steer or 0,brake=want.brake or 0}
        if want.hop then hop_id+=1;input.hop_event_id=hop_id;input.hop_strength=1 end
        if want.manual or want.nose then
            -- As Mapping sends them: only while a wheel is on the ground, and whether the stick holds one either way.
            local grounded=false
            for i=1,2 do grounded=grounded or samples[i].contact.status=="hit" and Forces.eligible_support(body,samples[i],.005,.10) end
            if want.manual then
                input.manual=grounded and want.manual or 0
                input.manual_held=want.manual>0
            end
            if want.nose then
                input.nose_manual=grounded and want.nose or 0
                input.nose_manual_held=want.nose_held==nil and want.nose>0 or want.nose_held==true
            end
        end
        if ride.hitch and ride.hitch(step) then stage:invalidate_continuity() end
        local out,candidate=stage:preview(h,folded,wheels,forecast,input)
        local command
        if out.valid then
            stage:_adopt(candidate)
            wheels=out.wheels;angle=out.front_steer_angle;command=out
        else peak.refused+=1;stage:invalidate_continuity() end
        -- A command shows in the sample two steps after the one it was made from.
        if ride.immediate and command then body=World.integrate(body,command,gravity,h)
        elseif previous then body=World.integrate(body,previous,gravity,h)
        else
            body=M.copy(body)
            body.linear_velocity=M.add(body.linear_velocity,M.mul(gravity,h))
            body.center_of_mass=M.add(body.center_of_mass,M.mul(body.linear_velocity,h))
        end
        previous=command
        if command and ride.push then
            local push=ride.push(step,body,command)
            if push then previous=M.copy(command);previous.force=M.add(previous.force,push) end
        end
        if command then peak.torque=math.max(peak.torque,M.length(command.torque)) end
        local flat=math.sqrt(body.linear_velocity[1]^2+body.linear_velocity[3]^2)
        local forward=M.turn(M.normalized(body.orientation),{0,0,1})
        if flat>1 then
            local dot=(forward[1]*body.linear_velocity[1]+forward[3]*body.linear_velocity[3])/(flat*math.sqrt(forward[1]^2+forward[3]^2))
            peak.slip=math.max(peak.slip,math.deg(math.acos(math.clamp(dot,-1,1))))
        end
        peak.tilt=math.max(peak.tilt,tilt_of(body));peak.speed=math.max(peak.speed,flat)
        peak.height=math.max(peak.height,body.center_of_mass[2]-start)
        if ride.each then ride.each(step,body,out,wheels,samples) end
    end
    peak.body,peak.wheels=body,wheels
    return peak
end
function T.run()
    local n,cases=0,0
    local function check(ok,why) n+=1;assert(ok,why) end
    local function case(body) cases+=1;body() end
    case(function() -- Top speed is drag meeting the fading pedal, and the rider coasts through the top of it.
        -- With the command applied at once: the rigid fixture bounces a wheel on the delayed one, which the game does not.
        local changes,last,lowest,highest,pedaled=0,nil,math.huge,0,0
        run({steps=1500,immediate=true,controls=function() return {pedal=1} end,each=function(step,body,out)
            check(out.valid and out.brake_impulse[1]==0 and out.brake_impulse[2]==0,"nothing brakes a bike holding its top speed")
            if step>360 then
                local speed=M.length(body.linear_velocity)
                lowest=math.min(lowest,speed);highest=math.max(highest,speed)
                if out.pedaling then pedaled+=1 end
                if last~=nil and last~=out.pedaling then changes+=1 end
                last=out.pedaling
            end
        end})
        check(lowest>=7 and highest<=7.75,string.format("the cruise holds its band: %.2f to %.2f",lowest,highest))
        check(pedaled>0 and pedaled<1140,"the rider pedals and coasts in turn at the top")
        check(changes>=2 and changes<=19,"the cranks start and stop less than once a second: "..changes)
    end)
    case(function() -- A coast slows by itself, and speed from a hill is not taken away on the flat.
        local coast=run({steps=600,speed=7.4})
        local speed=M.length(coast.body.linear_velocity)
        check(speed<6.3 and speed>5,"a coast from top speed loses about a quarter in 10 s: "..speed)
        local fast=run({steps=60,speed=12})
        check(M.length(fast.body.linear_velocity)>11.3,"nothing brakes a fast bike that is not asked to")
        local long=run({steps=2400,speed=.8})
        check(math.abs(long.body.linear_velocity[3])<.01,"a coast ends at rest, and does not roll back")
    end)
    case(function() -- Corners: tighter than the old 11 m at speed, leaned as far as the speed asks.
        local radius,lean
        run({steps=420,speed=7.4,controls=function(step) return {steer=-1,pedal=1} end,each=function(step,body,out)
            if step==420 then
                local v=M.length(body.linear_velocity)
                radius=v/math.abs(body.angular_velocity[2]);lean=tilt_of(body)
            end
        end})
        check(radius<9.2 and radius>8,"radius at top speed: "..radius)
        check(lean>21 and lean<30,"lean at top speed: "..lean)
    end)
    case(function() -- Rocking the stick, the test the leaner tuning fell over on.
        for _,slope in ipairs({0,math.tan(math.rad(12))}) do
            for _,rock in ipairs({{speed=5,stick=.7,every=50},{speed=2,stick=1,every=40}}) do
                local peak=run({steps=1200,speed=rock.speed,ground=Ground.plane(slope,0),controls=function(step,body)
                    local speed=M.length(body.linear_velocity)
                    return {steer=math.floor(step/rock.every)%2==0 and rock.stick or -rock.stick,pedal=speed<rock.speed and 1 or 0}
                end})
                check(peak.tilt<40 and peak.refused==0,"rocked at "..rock.speed.." m/s peaks at "..peak.tilt)
            end
        end
    end)
    case(function() -- The landing cushion cannot throw a bike over: hops with the stick held, the 59.7 degree stop's likely cause.
        for _,speed in ipairs({3,5,7.4}) do
            for _,stick in ipairs({.3,.5,1}) do
                local peak=run({steps=240,speed=speed,controls=function(step)
                    return {steer=-stick,pedal=1,hop=step==60}
                end})
                check(peak.tilt<42,string.format("hop at %.1f m/s, stick %.1f, peaks at %.1f",speed,stick,peak.tilt))
                check(peak.height>.8,"the hop still rises")
            end
        end
        local leaned=Forces.proposed_body()
        leaned.orientation={0,0,math.sin(.2),math.cos(.2)}
        leaned.center_of_mass={0,1,0}
        leaned.linear_velocity={0,-3,0}
        local landing=Forces.controls({contact_compliance_available=true,landing_contact_compliance_selected=true})
        local out=Forces.new():preview(h,leaned,Forces.proposed_wheels(),contacts(Ground.plane(0,0),leaned,0),landing)
        check(out.valid and out.landing_approach_mask~=0 and out.approach_normal_force[1]>1000,"a leaned bike is braked on the way down")
        local forward=M.turn(M.normalized(leaned.orientation),{0,0,1})
        check(math.abs(M.dot(out.contact_torque,forward))<1,"and that brake has no lever to roll it with: "..M.dot(out.contact_torque,forward))
        local drop=place(Ground.plane(0,0),0)
        drop.center_of_mass={0,drop.center_of_mass[2]+.03,0}
        drop.linear_velocity={0,-9,0}
        local catch=Stage.new():preview(h,drop,Forces.proposed_wheels(),contacts(Ground.plane(0,0),drop,0),{})
        check(catch.valid and M.length(catch.force)>6001 and M.length(catch.force)<=12000.001,
            "a big drop gets more than a rolling step may send: "..M.length(catch.force))
        leaned.center_of_mass={0,.85,0}
        out=Forces.new():preview(h,leaned,Forces.proposed_wheels(),contacts(Ground.plane(0,0),leaned,0),landing)
        check(out.valid and out.landing_recovery_mask~=0 and math.abs(M.dot(out.contact_torque,forward))<600,
            "nor does the first hard step of a touchdown: "..M.dot(out.contact_torque,forward))
    end)
    case(function() -- A bank does not add to the lean: gravity sets the roll, not the ground.
        local peak=run({steps=360,speed=5,ground=Ground.twist(math.rad(33),2,6)})
        check(peak.tilt<30 and peak.refused==0,"across a 33 degree bank, wheels straight: "..peak.tilt)
        local falling=run({steps=240,speed=7,ground=Ground.plane(math.tan(math.rad(30)),0),controls=function() return {steer=-1} end})
        check(falling.tilt<=31,"full left down a 30 degree plane: "..falling.tilt)
        local clamped=false
        run({steps=30,speed=3,ground=Ground.plane(math.tan(math.rad(50)),0),each=function(step,body,out)
            if out.valid and M.length(out.desired_balance_up)>.5 then
                local camber=math.acos(math.clamp(M.dot(out.desired_balance_up,out.balance_reference_up),-1,1))
                check(camber<=.8+1e-6,"a very steep surface keeps its tyres on it: "..camber)
                clamped=clamped or camber>=.79
            end
        end})
        check(clamped,"the surface is steep enough for that to bind")
    end)
    case(function() -- A wheel pushing back up out of a step is still on the ground.
        local body=Forces.proposed_body()
        local function sample(separation,rising)
            body.linear_velocity={0,rising,0}
            return {contact={status="hit",point={0,0,0},normal={0,1,0},forward={0,0,1},surface_velocity={0,0,0}},separation=separation}
        end
        check(Forces.eligible_support(body,sample(-.02,.2),.005,.10),"rising at the recovery speed keeps support")
        check(not Forces.eligible_support(body,sample(-.02,.5),.005,.10),"rising faster than recovery is a real lift")
        check(not Forces.eligible_support(body,sample(0,.1),.005,.10),"with nothing to recover from, the old limit stands")
    end)
    case(function() -- A brake in a corner does not swap the ends, flat or down a street grade.
        for _,row in ipairs({{speed=6,stick=1,grade=0},{speed=7.4,stick=.5,grade=0},{speed=6,stick=1,grade=.05},{speed=7.4,stick=1,grade=.05},
            {speed=7.4,stick=.5,grade=.1},{speed=9,stick=1,grade=.1}}) do
            local locked,rear_load=0,0
            local peak=run({steps=300,speed=row.speed,ground=Ground.plane(0,-row.grade),controls=function(step)
                return {steer=-row.stick,brake=step>90 and 1 or 0}
            end,each=function(step,body,out,wheels)
                local speed=M.length(body.linear_velocity)
                if step>90 and speed>1.5 and math.abs(wheels[2].angular_speed)*R<.2*speed then locked+=1 end
                if step>91 then check(math.abs(out.brake_impulse[2])<=.6*rear_load*R*h+1e-6,"the rear brake eases to what the tyre can hold") end
                rear_load=out.normal_load[2]
            end})
            check(peak.slip<12,string.format("%.1f m/s, stick %.1f, grade %.2f: peak slip %.1f",row.speed,row.stick,row.grade,peak.slip))
            check(locked==0,"the rear wheel keeps turning")
        end
        local stop=run({steps=210,speed=7.4,controls=function() return {brake=1} end})
        check(M.length(stop.body.linear_velocity)<.5,"a straight stop from top speed takes under 3.5 s")
        local first,squeezed
        run({steps=45,speed=7.4,controls=function(step) return {brake=step>30 and 1 or 0} end,each=function(step,body,out)
            if step==31 then first=math.abs(out.brake_impulse[1]) end
            if step==42 then squeezed=math.abs(out.brake_impulse[1]) end
        end})
        check(first>0 and first<.3*squeezed,"B is squeezed on, not snapped: "..first.." then "..squeezed)
        local braked=0
        run({steps=120,speed=7.4,controls=function() return {brake=1} end,hitch=function(step) return step%10==0 end,each=function(step,body,out)
            if step>60 and step%10==0 and math.abs(out.brake_impulse[2])>.1 then braked+=1 end
        end})
        check(braked==6,"a hitch leaves the rear brake on: "..braked)
    end)
    case(function() -- A stopped bike holds on a street grade, and a stall on a ramp still rolls back.
        for _,grade in ipairs({-.14,-.1,-.05,-.02,.02,.05,.1,.14}) do
            local ground=Ground.plane(0,grade)
            local from
            local peak=run({steps=600,ground=ground,each=function(step,body) if step==60 then from=M.copy(body.center_of_mass) end end})
            check(M.length(M.sub(peak.body.center_of_mass,from))<.005,"holds on a grade of "..grade)
        end
        local bank=Ground.plane(0,math.tan(math.rad(20)))
        local stall=run({steps=300,speed=.1,ground=bank})
        check(stall.body.linear_velocity[3]< -1,"a 20 degree ramp is too steep to hold")
        for _,grade in ipairs({-.17,.17}) do
            local ramp=run({steps=300,ground=Ground.plane(0,grade)})
            check(M.length(ramp.body.linear_velocity)>1,"past the limit a stall rolls, up or down: "..grade)
        end
        local hop=run({steps=120,controls=function(step) return {hop=step==60} end})
        check(hop.height>.9,"a hop leaves from a held stop")
        local away=run({steps=60,ground=Ground.plane(0,.08),controls=function(step) return {pedal=step>30 and 1 or 0} end})
        check(M.length(away.body.linear_velocity)>.7,"the pedal lets go of the hold at once")
    end)
    case(function() -- Pedalling is a rider's power: a steep climb slows to what the rider can push, the flat rides as before.
        local t=Forces.tuning()
        local rider=1200 -- forces.lua rider_power, in watts
        local weight=Forces.proposed_body().mass*M.length(t.gravity)
        local last=math.huge
        for _,grade in ipairs({.17,.2,.24}) do
            local sum,count=0,0
            run({steps=600,speed=6,ground=Ground.plane(0,grade),controls=function() return {pedal=1} end,each=function(step,body)
                if step>540 then sum+=M.length(body.linear_velocity);count+=1 end
            end})
            local speed=sum/count
            local sine,cosine=grade/math.sqrt(1+grade*grade),1/math.sqrt(1+grade*grade)
            local watts=speed*(weight*(sine+t.rolling_resistance*cosine)+t.air_drag*speed*speed)
            -- A constant torque held 6.6, 6.4 and 6.1 m/s here, 1300 to 1620 W.
            check(watts<=rider*1.02 and watts>=rider*.97,string.format("up %d%% the rider holds %.0f W at %.2f m/s",grade*100,watts,speed))
            check(speed<last-.5,"each steeper grade is clearly slower")
            last=speed
        end
        local street
        run({steps=600,speed=6,ground=Ground.plane(0,.13),controls=function() return {pedal=1} end,each=function(step,body)
            if step==600 then street=M.length(body.linear_velocity) end
        end})
        check(street>6.8,"the city's 13% hills still climb near full speed: "..street)
        local marks,reached={5,7.4,7.69},{}
        run({steps=420,controls=function() return {pedal=1} end,each=function(step,body)
            local speed=M.length(body.linear_velocity)
            for _,mark in ipairs(marks) do if not reached[mark] and speed>=mark then reached[mark]=step*h end end
        end})
        -- With the fade still from 6 m/s the power limit left the bike at 7.64 m/s, pedalling forever under the band.
        check(reached[5] and reached[5]<2.2,"from rest to 5 m/s as briskly as before: "..tostring(reached[5]))
        check(reached[7.4] and reached[7.4]<4,"and to 7.4 m/s inside 4 s: "..tostring(reached[7.4]))
        check(reached[7.69]~=nil,"the flat still reaches the top of the band, where the rider coasts")
    end)
    case(function() -- Ordinary riding with no manual sends exactly what it did before the manual was added.
        -- The digest was taken on the kernel before the manual law went in: every force and torque of a 900 step ride
        -- with pedal, steering, brake and two hops, and where the bike ends.
        local hash=2166136261
        local function mix(x)
            local text=string.format("%.17g",x)
            for i=1,#text do
                hash=bit32.bxor(hash,string.byte(text,i))
                hash=(bit32.lshift(hash,24)+hash*403)%4294967296
            end
        end
        local sent=0
        local ride=run({steps=900,speed=2,controls=function(step)
            return {pedal=step%300<200 and 1 or 0,steer=math.sin(step/40)*.6,brake=step%300>260 and 1 or 0,hop=step==400 or step==700}
        end,each=function(step,body,out)
            if out.valid then sent+=1;for i=1,3 do mix(out.force[i]);mix(out.torque[i]) end end
        end})
        for i=1,3 do mix(ride.body.center_of_mass[i]) end
        check(sent==900 and ride.refused==0,"every step of the ordinary ride is sent: "..sent)
        check(hash==0x24483bca,string.format("ordinary riding is unchanged: digest %08x",hash))
    end)
    -- Manuals. The pitch is the body's own, nose up positive, from the surface under the bike when one is given.
    local function pitch_of(body,ground)
        local f=M.turn(M.normalized(body.orientation),{0,0,1})
        local n={0,1,0}
        if ground then local dx,dz=ground.grad(body.center_of_mass[1],body.center_of_mass[3]);n=M.unit({-dx,1,-dz}) end
        return math.deg(math.asin(math.clamp(M.dot(f,n),-1,1)))
    end
    local function gap(sample) return sample.contact.status=="hit" and sample.separation or math.huge end
    -- o.m held from step o.before+1 for o.hold steps, then let go for o.after steps. o.during(t) and o.release(t) add
    -- controls, t counting steps from the start of the hold or of the release. Returns the ride and a row a step.
    local function manual(o)
        local before,hold=o.before or 15,o.hold or 120
        local rows={}
        local ride=run({steps=before+hold+(o.after or 60),speed=o.speed or 4,ground=o.ground,pitch=o.pitch,controls=function(step)
            if step<=before then return {pedal=o.pedal_before} end
            if step<=before+hold then
                local c=o.during and o.during(step-before) or {}
                if c.manual==nil then c.manual=o.m end
                return c
            end
            local c=o.release and o.release(step-before-hold) or {}
            if c.manual==nil then c.manual=0 end
            return c
        end,each=function(step,body,out,wheels,samples)
            rows[step]={hold=step>before and step<=before+hold,released=step>before+hold,t=step-before,
                pitch=pitch_of(body,o.ground),front=gap(samples[1]),rear=gap(samples[2]),out=out,body=body,samples=samples}
        end})
        return ride,rows
    end
    case(function() -- The stage passes the manual and refuses a malformed one; a manual coasts.
        local flat=Ground.plane(0,0)
        local body,wheels=place(flat,4)
        local samples=contacts(flat,body,0)
        local out=Stage.new():preview(h,body,wheels,samples,{manual=.5})
        check(out.valid and out.manual_active==true and out.manual_couple>0 and out.balance_torque[1]<0,
            "a manual on a level bike lifts the nose: "..tostring(out.manual_couple).." "..tostring(out.balance_torque[1]))
        check(Stage.new():preview(h,body,wheels,samples,{pedal=1}).pedaling==true,"A pedals the same bike on two wheels")
        local pedalled=Stage.new():preview(h,body,wheels,samples,{pedal=1,manual=.5})
        check(pedalled.valid and pedalled.pedaling==false,"and not in a manual")
        local function same(a,b)
            if type(a)~="table" or type(b)~="table" then return a==b end
            for k,v in a do if not same(v,b[k]) then return false end end
            for k in b do if a[k]==nil then return false end end
            return true
        end
        check(same(Stage.new():preview(h,body,wheels,samples,{manual=0}),Stage.new():preview(h,body,wheels,samples,{})),
            "a manual of 0 is no manual")
        for _,bad in ipairs({-.1,1.2,0/0,"half"}) do
            local refused=Stage.new():preview(h,body,wheels,samples,{manual=bad})
            check(not refused.valid and refused.issue=="invalid_manual","the stage refuses a manual of "..tostring(bad))
        end
        check(same(Stage.new():preview(h,body,wheels,samples,{manual_held=true}),Stage.new():preview(h,body,wheels,samples,{})),
            "a stick that holds a manual sends none by itself")
        local refused=Stage.new():preview(h,body,wheels,samples,{manual=.5,manual_held=1})
        check(not refused.valid and refused.issue=="invalid_manual","the stage refuses a manual_held that is not true or false")
    end)
    case(function() -- A held manual: the front lifts at once, holds where the stick puts it on the rear wheel alone, coasts, and touches down again.
        -- The low end of the band, the middle and the top: 20 degrees, 28.2, and 36.4 just past the balance at 33.1.
        for _,speed in ipairs({4,7}) do
            for _,row in ipairs({{m=.01,pitch=20.0},{m=.5,pitch=28.2},{m=1,pitch=36.4},{m=.5,pitch=28.2,pedal=true}}) do
                local what=string.format("m=%.2f at %d m/s%s",row.m,speed,row.pedal and " with A held" or "")
                local ride,rows=manual({m=row.m,speed=speed,pedal_before=row.pedal and 1 or nil,
                    during=row.pedal and function() return {pedal=1} end or nil})
                local lifted,pedalled,held,low,high,bottom=nil,false,true,math.huge,-math.huge,math.huge
                local down,closing,before,fastest,caught,rear_caught,bounced=nil,nil,nil,0,0,false,false
                local function front_closing(r)
                    return r.samples[1].contact.status=="hit" and -M.point_velocity(r.body,r.samples[1].contact.point)[2] or 0
                end
                for step,r in rows do
                    if r.hold then
                        if not lifted and r.front>.02 then lifted=r.t*h end
                        if r.out.pedaling then pedalled=true end
                        if r.t*h>=1 and r.t*h<=2 then
                            if r.rear>.005 then held=false end
                            low,high,bottom=math.min(low,r.pitch),math.max(high,r.pitch),math.min(bottom,r.front)
                        end
                    elseif r.released then
                        if not down then fastest=math.max(fastest,front_closing(r)) end
                        if not down and r.front<=.005 then
                            down=(r.t-120)*h
                            closing,before=front_closing(r),front_closing(rows[step-1])
                        end
                        if down and r.front>.01 then bounced=true end
                        -- Over the whole release: the kernel meets the front on the forecast sample, a step before the
                        -- measured one shows it down.
                        if bit32.band(r.out.landing_recovery_mask,1)~=0 then caught+=1 end
                        if bit32.band(r.out.landing_recovery_mask,2)~=0 then rear_caught=true end
                    end
                end
                check(ride.refused==0 and ride.torque<2000,what..": every step sent under the caps: "..ride.refused.." "..ride.torque)
                check(lifted and lifted<=.2,what..": the front is up within .2 s: "..tostring(lifted))
                check(held,what..": on the rear wheel alone from 1 s to 2 s")
                check(bottom>=.2,what..": the front tyre at least .2 m up: "..bottom)
                check(math.abs(low-row.pitch)<=1.5 and math.abs(high-row.pitch)<=1.5,
                    string.format("%s: holds %.1f to %.1f degrees",what,low,high))
                check(not pedalled,what..": the rider coasts in a manual")
                check(down and down<=.6,what..": let go, the front is down within .6 s: "..tostring(down))
                -- Let go, the front falls about as fast as gravity alone drops it (1.6 m/s from 28 degrees), and the
                -- landing approach slows it to half a metre a second. The kernel meets that as it meets any touchdown:
                -- at m=.01 and m=1 its catch holds the front alone for one step. Looked for only from the measured
                -- touchdown on, a step after that catch, the check read none.
                check(fastest>1 and before<.6 and closing<.5,
                    string.format("%s: slowed from %.2f m/s to %.2f, then %.2f on the ground",what,fastest,before,closing))
                check(caught<=1 and not rear_caught and not bounced,
                    what..": an ordinary touchdown, caught at most one step on the front, and no bounce: "..caught)
            end
        end
    end)
    case(function() -- On a slope the manual holds the same angle to the surface, uphill and down.
        for _,row in ipairs({{grade=.08,m=.5,pitch=28.2},{grade=.08,m=1,pitch=36.4},{grade=-.15,m=.5,pitch=28.2},{grade=-.15,m=1,pitch=36.4}}) do
            local ground=Ground.plane(0,row.grade)
            local ride,rows=manual({m=row.m,ground=ground,hold=150})
            local low,high=math.huge,-math.huge
            for _,r in rows do if r.hold and r.t*h>=1.5 and r.t*h<=2.5 then low,high=math.min(low,r.pitch),math.max(high,r.pitch) end end
            check(ride.refused==0 and math.abs(low-row.pitch)<=1.5 and math.abs(high-row.pitch)<=1.5,
                string.format("a grade of %.2f at m=%.1f holds %.1f to %.1f degrees to the surface",row.grade,row.m,low,high))
        end
    end)
    case(function() -- Bumps under the rear wheel: the manual rides over them and is still held a second later.
        for _,bump in ipairs({.05,.08,.12}) do
            for _,row in ipairs({{m=.75,pitch=32.3},{m=1,pitch=36.4}}) do
                -- The rear wheel reaches it about 1.2 s into the manual, and leaves it 1.3 s before the end.
                local ground=Ground.bump(4.5,bump,.6)
                local most,last=-math.huge,nil
                local over=run({steps=215,speed=4,ground=ground,controls=function(step) return {manual=step>15 and row.m or 0} end,
                    each=function(step,body,out)
                        local p=pitch_of(body)
                        most=math.max(most,p)
                        if step==215 then last={pitch=p,active=out.manual_active} end
                    end})
                check(over.refused==0 and most<65,string.format("a %d cm bump at m=%.2f: no fall, at most %.1f degrees",bump*100,row.m,most))
                check(last.active==true and math.abs(last.pitch-row.pitch)<=1.5,
                    string.format("and the manual is still held a second after it: %.1f degrees",last.pitch))
            end
        end
    end)
    case(function() -- A held manual rides over a bump or a kicker at a jog: the throw above 17.9 degrees is the lift's alone.
        -- The offset is measured along the surface under the rear wheel, so a rising face reads a bike at 34 degrees
        -- to level as about 17 to its ground. With the throw allowed there in a held manual, it threw the bike up
        -- the face at 450 to 630 N*m, and over the crest the bike went past its balance and over backwards (89 to
        -- 90 degrees). With the throw ending at 17.9 it rode on at 34 to 38.
        for _,row in ipairs({
            {what="an 8 cm bump .6 m long at 2 m/s",ground=Ground.bump(4.5,.08,.6),speed=2,m=1,pitch=36.4},
            {what="an 8 cm bump .8 m long at 2.5 m/s",ground=Ground.bump(4.5,.08,.8),speed=2.5,m=.88,pitch=34.4},
            {what="an 8 cm bump .8 m long at 3 m/s",ground=Ground.bump(4.5,.08,.8),speed=3,m=1,pitch=36.4},
            {what="a 16 degree kicker onto a 20 cm deck at 4 m/s",ground=Ground.kicker(6,math.rad(16),.3,.2),speed=4,m=.88,pitch=34.4},
        }) do
            local most,last=-math.huge,nil
            local ride=run({steps=215,speed=row.speed,ground=row.ground,controls=function(step) return {manual=step>15 and row.m or 0} end,
                each=function(step,body,out)
                    local p=pitch_of(body)
                    most=math.max(most,p)
                    if step==215 then last={pitch=p,active=out.manual_active} end
                end})
            check(ride.refused==0 and most<45,string.format("%s at m=%.2f: no fall, at most %.1f degrees",row.what,row.m,most))
            check(last.active==true and math.abs(last.pitch-row.pitch)<=1.5,
                string.format("%s: the manual is still held after it at %.1f degrees",row.what,last.pitch))
        end
    end)
    case(function() -- A bump or a kicker met in the last half second of the lift does not throw the bike over.
        -- Until the front first came up to the stick's offset, the wide throw was judged along the surface under the
        -- rear wheel, and the front reads as up only within a centimetre or two of that offset. A face met while the
        -- law crept up the last degree read a bike at 33 degrees to the road as about 17 to the face, kept the throw
        -- on at up to 800 N*m, and the bike went over backwards at the crest (88 to 90 degrees). Each row puts the
        -- bump where the rear hub is `after` seconds after the stick on a flat ride.
        local t=Forces.tuning()
        local stick=16
        local function rear_z(body)
            return M.add(body.center_of_mass,M.turn(M.normalized(body.orientation),M.sub(G.rear_axle,G.com)))[3]
        end
        local function controls(m) return function(step) return {manual=step>=stick and m or 0} end end
        for _,row in ipairs({
            {what="an 8 cm bump .8 m long at 2 m/s",ground=function(at) return Ground.bump(at,.08,.8) end,speed=2,m=1,after={.45,.52,.58}},
            {what="an 8 cm bump .8 m long at 2.5 m/s",ground=function(at) return Ground.bump(at,.08,.8) end,speed=2.5,m=1,after={.45}},
            {what="a 12 cm bump 1.2 m long at 3 m/s",ground=function(at) return Ground.bump(at,.12,1.2) end,speed=3,m=.75,after={.5}},
            {what="a 16 degree kicker onto a 20 cm deck at 4 m/s",ground=function(at) return Ground.kicker(at,math.rad(16),.3,.2) end,
                speed=4,m=.88,after={.5}},
            {what="a 16 degree kicker onto a 20 cm deck at 4 m/s",ground=function(at) return Ground.kicker(at,math.rad(16),.3,.2) end,
                speed=4,m=1,after={.55}},
            {what="a 16 degree kicker onto a 20 cm deck at 5 m/s",ground=function(at) return Ground.kicker(at,math.rad(16),.3,.2) end,
                speed=5,m=1,after={.5}},
        }) do
            local target=t.manual_low+(t.manual_high-t.manual_low)*row.m
            local hold=math.deg(math.acos(target/math.sqrt(.4158^2+.637^2))-math.atan2(.637,.4158))
            for _,after in ipairs(row.after) do
                local meet=stick+math.floor(after/h+.5)
                local at
                run({steps=meet,speed=row.speed,controls=controls(row.m),each=function(step,body) if step==meet-1 then at=rear_z(body) end end})
                local steps=meet+math.floor(2.4/h)
                local most,last=-math.huge,nil
                local ride=run({steps=steps,speed=row.speed,ground=row.ground(at),controls=controls(row.m),each=function(step,body,out)
                    local p=pitch_of(body)
                    most=math.max(most,p)
                    if step==steps then last={pitch=p,active=out.manual_active} end
                end})
                local what=string.format("%s at m=%.2f, met %.2f s after the stick",row.what,row.m,after)
                check(ride.refused==0 and most<45,string.format("%s: no fall, at most %.1f degrees",what,most))
                check(last.active==true and math.abs(last.pitch-hold)<=1.5,
                    string.format("%s: the manual is still held after it at %.1f degrees against %.1f",what,last.pitch,hold))
            end
        end
    end)
    case(function() -- Too far back: past where the rider can hold it the bike goes over, B saves it, and inside the window it comes back.
        local over
        run({steps=60,speed=4,pitch=46,controls=function() return {manual=1} end,each=function(step,body)
            if not over and pitch_of(body)>65 then over=step*h end
        end})
        check(over and over<=.75,"at 46 degrees on full stick the bike goes over: "..tostring(over))
        local most,last=-math.huge,0
        run({steps=120,speed=4,pitch=46,controls=function(step) return {manual=1,brake=step>12 and step<=27 and 1 or 0} end,
            each=function(step,body) most=math.max(most,pitch_of(body));last=pitch_of(body) end})
        check(most<50 and math.abs(last-36.4)<=1.5,string.format("a quarter second of B from .2 s saves it: at most %.1f, back to %.1f",most,last))
        most,last=-math.huge,0
        run({steps=120,speed=4,pitch=44,controls=function() return {manual=1} end,
            each=function(step,body) most=math.max(most,pitch_of(body));last=pitch_of(body) end})
        check(most<46 and math.abs(last-36.4)<=1.5,string.format("at 44 degrees it comes back by itself: at most %.1f, back to %.1f",most,last))
    end)
    case(function() -- A manual slowing to a walk: the rider puts the front down.
        local slow,front=nil,nil
        local ride=run({steps=420,speed=1.6,controls=function(step) return {manual=step>15 and .5 or 0} end,each=function(step,body,out,wheels,samples)
            local speed=M.length(body.linear_velocity)
            if not slow and step>15 and speed<1 then slow=step end
            if slow and step>=slow+36 then
                check(gap(samples[1])<=.005 and out.manual_active==false,"under 1 m/s the front is down: "..step.." "..gap(samples[1]))
            end
            front=front or gap(samples[1])>.1 and step
        end})
        check(ride.refused==0 and front and slow,"the manual lifts at 1.6 m/s and slows below 1 m/s: "..tostring(front).." "..tostring(slow))
    end)
    case(function() -- Steering a manual carves the bike round on its back wheel, the way the bars turn it on two, more gently.
        local function yawed(m)
            local first,last,lean,count
            lean,count=0,0
            run({steps=165,speed=4,controls=function(step) return {manual=m and step>15 and m or nil,steer=step>60 and 1 or 0} end,
                each=function(step,body,out)
                    local yaw,_,leaned=World.attitude(body)
                    if step==105 then first=yaw end
                    if step==165 then last=yaw end
                    if step>105 then lean+=leaned;count+=1 end
                    if m and step>=60 then check(out.manual_active==true,"still in the manual while it carves") end
                end})
            return (last-first)/(60*h),lean/count
        end
        local rate,lean=yawed(.5)
        local two,two_lean=yawed(nil)
        check(rate*two>0 and math.abs(rate)>=.3 and math.abs(rate)<=.6,string.format("it carves at %.2f rad/s, the way steering turns at %.2f",rate,two))
        check(lean*two_lean>0,string.format("leaning into the carve as into a turn: %.3f and %.3f",lean,two_lean))
    end)
    case(function() -- A hop from a manual pops off the back wheel and lands near level; holding the manual after landing lifts it again.
        local hop_step,air,landed,landing,lifted
        local ride=run({steps=330,speed=4,controls=function(step)
            if step<=15 then return {} end
            if step<=75 then return {manual=.5} end
            if step==76 then return {manual=0,hop=true} end
            if step>=150 then return {manual=.5} end
            return {manual=0}
        end,each=function(step,body,out,wheels,samples)
            if step==76 then hop_step=out.hop_applied end
            local any=gap(samples[1])<=.005 or gap(samples[2])<=.005
            if step>76 then
                if not any and not landed then air=(air or 0)+1 elseif air and not landed then landed=step;landing=pitch_of(body) end
            end
            if step>=150 and gap(samples[1])>.2 and not lifted then lifted=step end
        end})
        check(hop_step==true and ride.refused==0,"the hop leaves from the manual")
        check(air and air>=40,"a full hop: "..tostring(air).." steps in the air")
        check(landing and math.abs(landing)<15,"landing near level: "..tostring(landing))
        check(landed and landed<150 and lifted and lifted<=180,"and the manual lifts again after it: "..tostring(lifted))
    end)
    case(function() -- B in a manual brings the front down and keeps it down: the rider has no throw against the brake.
        -- The throw lifts the bike from the front wheel to 17.9 degrees, where the weight shift holds it. Allowed again
        -- whenever the bike was lower, it held a braked manual at 12 to 15 degrees on up to 800 N*m until the bike
        -- slowed to a walk, about 2 s, with the drawn rider at the .20 m it can shift.
        local limit=Forces.proposed_body().mass*9.8*Forces.tuning().manual_hold_back+1e-6
        for _,row in ipairs({{m=.01,within=1},{m=.5,within=1},{m=1,within=2.5}}) do
            -- B from 1.5 s into the manual, and B from .2 s, while the front is still going up; the stick held.
            for _,from in ipairs({90,12}) do
                local most,down,relift=-math.huge,nil,false
                local ride=run({steps=15+from+240,speed=4,controls=function(step)
                    return {manual=step>15 and row.m or 0,brake=step>15+from and 1 or 0}
                end,each=function(step,body,out,wheels,samples)
                    if step<=15+from then return end
                    most=math.max(most,out.manual_couple)
                    if not down and gap(samples[1])<=.005 then down=(step-15-from)*h end
                    if down and gap(samples[1])>.03 then relift=true end
                end})
                local what=string.format("m=%.2f, B from %.2f s",row.m,from*h)
                check(ride.refused==0 and most<=limit,string.format("%s: the rider lifts with no more than the shift, %.0f N*m",what,most))
                check(down and down<=row.within,what..": the front comes down: "..tostring(down))
                check(not relift,what..": and stays down while B is held")
            end
        end
        local lifted=false
        run({steps=120,speed=4,controls=function() return {manual=.5,brake=1} end,each=function(step,body,out,wheels,samples)
            if out.manual_active or gap(samples[1])>.02 then lifted=true end
        end})
        check(not lifted,"with B held on both wheels the stick does not lift the front")
    end)
    case(function() -- A throw is one movement: held below 17.9 degrees for over a second, the rider has no more of it.
        local t=Forces.tuning()
        local limit=Forces.proposed_body().mass*9.8*t.manual_hold_back+1e-6
        local flat=Ground.plane(0,0)
        local body,wheels=place(flat,4)
        local a=-math.rad(12)
        body.orientation={math.sin(a/2),0,0,math.cos(a/2)}
        body.center_of_mass={0,R-M.turn(body.orientation,M.sub(G.rear_axle,G.com))[2]-.005,0}
        -- The same pitched body every step, so nothing but the rider's throw can lift it.
        local stage,thrown,late=Stage.new(),0,0
        for step=1,90 do
            local out,candidate=stage:preview(h,body,wheels,contacts(flat,body,0),{manual=.01})
            check(out.valid and out.manual_active,"the manual is on at step "..step..": "..tostring(out.issue))
            stage:_adopt(candidate);wheels=out.wheels
            if out.manual_couple>limit then thrown+=1;if step>62 then late+=1 end end
        end
        check(thrown>=55 and thrown<=61 and late==0,"a second of throw, then the weight shift alone: "..thrown.." "..late)
        -- A rider pulls a low manual back up after a small bump without putting the front down.
        for _,m in ipairs({.01,.5,.75}) do
            local touched=false
            local ride=run({steps=215,speed=4,ground=Ground.bump(4.5,.05,.6),controls=function(step) return {manual=step>15 and m or 0} end,
                each=function(step,body,out,wheels,samples) if step>60 and gap(samples[1])<=.005 then touched=true end end})
            check(ride.refused==0 and not touched,string.format("a 5 cm bump at m=%.2f is ridden with the front up",m))
        end
    end)
    case(function() -- A and the stick held from a stop: the bike pedals up to the start speed, lifts once, and coasts down to a walk.
        -- With one speed for starting and ending a manual, the bike never got past 1.05 m/s: the front lifted 14 to 16
        -- times in 10 s and the pedal stopped and started 37 to 41 times.
        local t=Forces.tuning()
        for _,m in ipairs({.01,.5,1}) do
            local lifts,up,switches,last,lift_speed,down_speed=0,false,0,nil,nil,nil
            local ride=run({steps=600,controls=function() return {pedal=1,manual=m} end,each=function(step,body,out,wheels,samples)
                local speed=math.sqrt(body.linear_velocity[1]^2+body.linear_velocity[3]^2)
                local front=gap(samples[1])
                if front>.05 and not up then up=true;lifts+=1;lift_speed=lift_speed or speed
                elseif front<=.005 and up then up=false;down_speed=down_speed or speed end
                if last~=nil and last~=out.pedaling then switches+=1 end
                last=out.pedaling
            end})
            local what=string.format("m=%.2f",m)
            check(ride.refused==0 and lifts>=1 and lifts<=2,what..": the front lifts once a cycle, not every quarter second: "..lifts)
            check(lift_speed and lift_speed>=t.manual_start_speed-.1,what..": from the start speed: "..tostring(lift_speed))
            check(switches<=4,what..": the cranks stop and start "..switches.." times in 10 s")
            -- The speed along the surface, not along the pitched body: a 28 degree manual came down at 1.13 m/s.
            check(down_speed and down_speed<=t.manual_min_speed+.05,what..": the manual coasts down to a walk: "..tostring(down_speed))
        end
    end)
    case(function() -- Up a street grade with A and the stick held from a stop: one lift, then the rider pedals on up.
        -- Trial mn5, up a 10 degree grade: pedalled to the start speed, the front lifted, the bike fell below a walk
        -- in .4 s, the front came down and the rider pedalled again, every 1.6 s. Here, before the manual waited for
        -- the stick to be let go, it lifted seven times in 10 s up 8% and 10% and five up 17.6%, and the cranks
        -- started and stopped 10 to 14 times.
        for _,grade in ipairs({.08,.1,.176}) do
            local lifts,up,switches,last=0,false,0,nil
            local ride=run({steps=600,ground=Ground.plane(0,grade),controls=function() return {pedal=1,manual=.5} end,
                each=function(step,body,out,wheels,samples)
                    local front=gap(samples[1])
                    if front>.05 and not up then up=true;lifts+=1 elseif front<=.005 and up then up=false end
                    if last~=nil and last~=out.pedaling then switches+=1 end
                    last=out.pedaling
                end})
            local what=string.format("up %.1f%%",grade*100)
            check(ride.refused==0 and lifts==1,what..": the front lifts once in 10 s: "..lifts)
            check(switches<=3,what..": the cranks stop and start "..switches.." times")
            check(last==true,what..": and the rider is pedalling up the hill at the end")
        end
    end)
    case(function() -- Up a bumpy street grade with A and the stick held from a stop: still one manual.
        -- Mapping sends no manual on a step with neither wheel on the ground, and the manual that slowed to a walk took
        -- that zero for the stick let go: over a 2 to 5 cm bump every 3 m the bike went into 8 or 9 manuals in 20 s.
        local function bumpy(grade,height)
            local function s(z) return z<2 and -1 or ((z-2)%3)/.5 end
            return {height=function(x,z) local u=s(z) return z*grade+((u>=0 and u<1) and height*.5*(1-math.cos(2*math.pi*u)) or 0) end,
                grad=function(x,z) local u=s(z) return 0,grade+((u>=0 and u<1) and height*math.pi*math.sin(2*math.pi*u)/.5 or 0) end}
        end
        for _,row in ipairs({{grade=.08,height=.02},{grade=.1,height=.035},{grade=.176,height=.05}}) do
            local starts,manual,air=0,false,0
            local ride=run({steps=1200,ground=bumpy(row.grade,row.height),controls=function() return {pedal=1,manual=.5} end,
                each=function(step,body,out,wheels,samples)
                    if out.manual_active and not manual then starts+=1 end
                    manual=out.manual_active
                    local grounded=false
                    for i=1,2 do grounded=grounded or samples[i].contact.status=="hit" and Forces.eligible_support(body,samples[i],.005,.10) end
                    if not grounded then air+=1 end
                end})
            local what=string.format("up %.1f%% over %.1f cm bumps",row.grade*100,row.height*100)
            check(ride.refused==0 and air>0,what..": the bumps take both wheels off the ground on "..air.." steps")
            check(starts==1,what..": one manual in 20 s with the stick held: "..starts)
        end
    end)
    case(function() -- A manual that slowed to a walk starts again once the stick has been let go; one B put down, once B is.
        local t=Forces.tuning()
        -- On the flat from a stop with A held: up at the start speed, coasting down to a walk, pedalled on with the
        -- stick still held and no second lift at the start speed. Let go for half a second and pulled again, it lifts.
        local lifts,up,down_speed,pedalled={},false,nil,false
        local ride=run({steps=720,controls=function(step)
            return {pedal=1,manual=(step<=480 or step>510) and .5 or 0}
        end,each=function(step,body,out,wheels,samples)
            local front=gap(samples[1])
            if front>.05 and not up then up=true;lifts[#lifts+1]=step
            elseif front<=.005 and up then up=false;down_speed=down_speed or M.length(body.linear_velocity) end
            if step>420 and step<=480 and out.pedaling then pedalled=true end
        end})
        check(ride.refused==0 and lifts[1] and lifts[1]*h<1,"the front lifts from a stop: "..tostring(lifts[1]))
        check(down_speed and down_speed<=t.manual_min_speed+.05,"and comes down at a walk: "..tostring(down_speed))
        check(pedalled and not (lifts[2] and lifts[2]<=510),"the rider pedals on with the stick held, and it does not lift: "..tostring(lifts[2]))
        check(#lifts==2 and lifts[2]>510 and (lifts[2]-510)*h<=.3,"let go and pulled again, it lifts: "..tostring(lifts[2]))
        -- B puts a manual down and stops the bike, the stick held: let go of B, A pedals it to the start speed and the
        -- front lifts, as it did before the manual waited for the stick.
        local braked,relift=false,nil
        run({steps=420,speed=4,controls=function(step)
            if step<=15 then return {} end
            return {manual=.5,brake=step>105 and step<=225 and 1 or 0,pedal=step>225 and 1 or 0}
        end,each=function(step,body,out,wheels,samples)
            if step>105 and step<=225 and gap(samples[1])<=.005 then braked=true end
            if step>225 and not relift and gap(samples[1])>.05 then relift=step end
        end})
        check(braked and relift and (relift-225)*h<1.5,"after B the held stick lifts the front again: "..tostring(relift))
    end)
    case(function() -- Up a kerb ramp onto the sidewalk, a manual started on the ramp still reaches its angle.
        -- Trial mn4: the stick held at .88 from 2.4 degrees up a kerb ramp. The rear wheel went light over the ramp's
        -- crest, struck the 5 cm lip onto the sidewalk and landed from it, each a push up under the rear wheel that
        -- took the front's rise at 20 to 25 degrees, and the bike crawled at 19 to 21 degrees for 1.4 s instead of
        -- going on to 35. The throw ended at 17.9 degrees, where the weight shift alone only just holds the bike. The
        -- ramp is mn4's, as its rear hub measured it, from the rear hub's start.
        local points={{2.40,0},{2.55,.020},{3.40,.068},{4.80,.110},{5.93,.144},{6.55,.145},{7.10,.196}}
        local back=G.rear_axle[3]-G.com[3]
        local function piece(z)
            z-=back
            if z<=points[1][1] then return nil,points[1][2] end
            if z>=points[#points][1] then return nil,points[#points][2] end
            for i=1,#points-1 do
                local a,b=points[i],points[i+1]
                if z<b[1] then local k=(b[2]-a[2])/(b[1]-a[1]);return k,a[2]+k*(z-a[1]) end
            end
        end
        local kerb={height=function(x,z) local _,y=piece(z);return y end,grad=function(x,z) return 0,piece(z) or 0 end}
        local function reaches(ground)
            local at
            local ride=run({steps=170,speed=5.75,ground=ground,controls=function(step)
                return {pedal=step<33 and 1 or 0,manual=step>=36 and .88 or nil}
            end,each=function(step,body) if not at and pitch_of(body)>=30 then at=step*h end end})
            return ride,at
        end
        local over,reached=reaches(kerb)
        local flat,flat_reached=reaches(Ground.plane(0,0))
        check(over.refused==0 and flat.refused==0,"every step of both rides is sent")
        check(reached and flat_reached and reached-flat_reached<=.25,
            string.format("over the kerb the manual reaches 30 degrees within .25 s of the flat road: %s against %s",
                tostring(reached),tostring(flat_reached)))
    end)
    case(function() -- Up a street grade, a lip met while the front comes up does not stall the lift.
        -- Judged against level, a lift up a grade read as up to the stick's angle 7 to 10 degrees short of it, and
        -- the wide throw ended there. A 5 cm lip over .55 m then knocked the bike back to 16 or 17 degrees, where the
        -- weight shift alone barely holds it, and it crawled for a second or more, as mn4 did over its kerb ramp.
        local t=Forces.tuning()
        local stick=36
        local function rear_z(body)
            return M.add(body.center_of_mass,M.turn(M.normalized(body.orientation),M.sub(G.rear_axle,G.com)))[3]
        end
        local function lipped(grade,at)
            local function rise(z) return at and math.clamp((z-at)/.55,0,1)*.05 or 0 end
            return {height=function(x,z) return z*grade+rise(z) end,
                grad=function(x,z) return 0,grade+((at and z>at and z<at+.55) and .05/.55 or 0) end}
        end
        local function ride(row,at,each)
            return run({steps=stick+120,speed=row.speed,ground=lipped(row.grade,at),controls=function(step)
                return {pedal=step<stick and 1 or 0,manual=step>=stick and row.m or nil}
            end,each=each})
        end
        for _,row in ipairs({{grade=.08,speed=5,m=.5,after=.5},{grade=.1,speed=5,m=.5,after=.6},{grade=.12,speed=6,m=.5,after=.5}}) do
            -- The lip starts where the rear hub is `after` seconds after the stick on the plain grade.
            local at
            ride(row,nil,function(step,body) if step==stick+math.floor(row.after/h+.5) then at=rear_z(body) end end)
            local grade=math.deg(math.atan(row.grade))
            local reach=t.manual_low+(t.manual_high-t.manual_low)*row.m
            local want=math.deg(math.acos(reach/math.sqrt(.4158^2+.637^2))-math.atan2(.637,.4158))
            local reached,low=nil,math.huge
            local over=ride(row,at,function(step,body)
                local p=pitch_of(body)-grade
                if step>=stick and not reached and p>=want-2.5 then reached=(step-stick)*h end
                if (step-stick)*h>row.after and not reached then low=math.min(low,p) end
            end)
            local what=string.format("up %d%% at %d m/s, m=%.1f, the lip met %.1f s into the lift",row.grade*100,row.speed,row.m,row.after)
            check(over.refused==0 and reached and reached<=1,string.format("%s: within 2.5 degrees of %.1f in %s s",what,want,tostring(reached)))
            check(low>=21,string.format("%s: knocked back no lower than %.1f degrees",what,low))
        end
    end)
    case(function() -- A hop from any manual pops level: the rider pushes the bars forward on either side of the balance.
        -- With the law past the balance the pop was a 156 N*m nudge: m=.85 landed at 9 degrees and m=.9 at 33, on the
        -- back wheel, near where it goes over.
        local previous
        for _,m in ipairs({.3,.5,.75,.85,.9,1}) do
            local couple,landing,air,landed=nil,nil,0,false
            local ride=run({steps=240,speed=4,controls=function(step)
                if step<=15 then return {} end
                if step<76 then return {manual=m} end
                if step==76 then return {manual=0,hop=true} end
                return {manual=0}
            end,each=function(step,body,out,wheels,samples)
                if step==76 then couple=out.hop_applied and out.manual_couple end
                local any=gap(samples[1])<=.005 or gap(samples[2])<=.005
                if step>76 and not landed then
                    if not any then air+=1 elseif air>0 then landed=true;landing=pitch_of(body) end
                end
            end})
            local what=string.format("m=%.2f",m)
            check(ride.refused==0 and air>=40 and landed,what..": a full hop from the manual: "..air)
            check(couple and couple< -500,what..": the pop pushes the nose down: "..tostring(couple))
            check(landing>=0 and landing<15,what..": lands near level: "..tostring(landing))
            if previous then check(math.abs(landing-previous)<4,string.format("%s: a little higher lands a little higher, %.1f after %.1f",what,landing,previous)) end
            previous=landing
        end
    end)
    -- Nose manuals: the bike on its front wheel with the rear up. The weight the rider shifts is measured against W.
    local W=Forces.proposed_body().mass*M.length(Forces.tuning().gravity)
    -- The angle the nose manual holds to the surface at the low end of the stick's band, the middle and the top.
    local NOSE_HOLD={[.01]=23.05,[.5]=26.6,[1]=30.1}
    local function level_pitch(body) return math.deg(math.asin(math.clamp(M.turn(M.normalized(body.orientation),{0,0,1})[2],-1,1))) end
    -- o.m held forward from step o.before+1 for o.hold steps, then let go for o.after steps, as manual(o) does; o.during
    -- (t,body,folded,forecast) and o.release(t) may also set nose and nose_held. A row a step adds the nose-down pitch
    -- to the surface (nd) and to level (lnd), the speed along the ground and the tilt from world up.
    local function nose(o)
        local before,hold=o.before or 15,o.hold or 120
        local rows={}
        local ride=run({steps=before+hold+(o.after or 60),speed=o.speed or 4,ground=o.ground,pitch=o.pitch,lift=o.lift,push=o.push,
            controls=function(step,body,folded,forecast)
                if step<=before then return {pedal=o.pedal_before} end
                if step<=before+hold then
                    local c=o.during and o.during(step-before,body,folded,forecast) or {}
                    if c.nose==nil then c.nose=o.m end
                    return c
                end
                local c=o.release and o.release(step-before-hold,body) or {}
                if c.nose==nil then c.nose=0 end
                return c
            end,each=function(step,body,out,wheels,samples)
                rows[step]={hold=step>before and step<=before+hold,released=step>before+hold,t=step-before,
                    nd=-pitch_of(body,o.ground),lnd=-level_pitch(body),front=gap(samples[1]),rear=gap(samples[2]),out=out,body=body,
                    speed=math.sqrt(body.linear_velocity[1]^2+body.linear_velocity[3]^2),tilt=tilt_of(body)}
            end})
        return ride,rows
    end
    -- Ride's fall: tilted more than 65 degrees from world up for 18 steps in a row.
    local function fell(rows)
        local run_of=0
        for _,r in rows do
            if r.tilt>65 then run_of+=1;if run_of>=18 then return true end else run_of=0 end
        end
        return false
    end
    case(function() -- The nose manual's tuning: its defaults, and a step refused on tuning outside its limits.
        local t=Forces.tuning()
        local defaults={nose_hold_forward=.26,nose_hold_back=.20,nose_low=.23,nose_high=.13,nose_carve_rate=.6,
            nose_carve_lateral=2.5,nose_yaw_damping=300,nose_yaw_torque=300,nose_roll_gain=1.6,
            nose_catch_torque=800,nose_catch_rate=.6,nose_catch_span=.25,nose_catch_seconds=.4,nose_air_seconds=.5,
            nose_brake_fade=.05}
        for name,value in defaults do check(t[name]==value,"the nose manual's "..name.." is "..tostring(t[name])) end
        local flat=Ground.plane(0,0)
        local body,wheels=place(flat,4)
        local samples=contacts(flat,body,0)
        local function valid(overrides)
            return Forces.new(Forces.tuning(overrides)):preview(h,body,wheels,samples,Forces.controls({nose_manual=.5})).valid
        end
        check(valid(nil),"the defaults are valid")
        for _,bad in ipairs({{nose_hold_forward=.31},{nose_hold_back=.31},{nose_high=.23},{nose_low=.27},{nose_carve_rate=5},
            {nose_carve_lateral=11},{nose_yaw_torque=1201},{nose_roll_gain=.9},{nose_roll_gain=3.1},
            {nose_catch_torque=1201},{nose_catch_span=0},{nose_catch_seconds=1.1},{nose_air_seconds=1.1},
            {nose_brake_fade=0},{nose_brake_fade=.31}}) do
            local name,value=next(bad)
            check(not valid(bad),"a step is refused on "..name.."="..value)
        end
        for name in defaults do
            for _,value in ipairs({-1,0/0}) do check(not valid({[name]=value}),"a step is refused on "..name.."="..value) end
        end
    end)
    case(function() -- The stage passes the nose manual and refuses a malformed one; the rear manual comes first.
        local flat=Ground.plane(0,0)
        local body,wheels=place(flat,4)
        local samples=contacts(flat,body,0)
        local out=Stage.new():preview(h,body,wheels,samples,{nose_manual=.5,nose_manual_held=true})
        check(out.valid and out.nose_manual_active==true and out.manual_active==false and out.manual_couple<0 and out.balance_torque[1]>0,
            "a nose manual on a level bike lifts the rear: "..tostring(out.nose_manual_active).." "..out.manual_couple.." "..out.balance_torque[1])
        local pedalled=Stage.new():preview(h,body,wheels,samples,{pedal=1,nose_manual=.5})
        check(pedalled.valid and pedalled.pedaling==false,"the rider does not pedal in a nose manual")
        local function same(a,b)
            if type(a)~="table" or type(b)~="table" then return a==b end
            for k,v in a do if not same(v,b[k]) then return false end end
            for k in b do if a[k]==nil then return false end end
            return true
        end
        local plain=Stage.new():preview(h,body,wheels,samples,{})
        check(same(Stage.new():preview(h,body,wheels,samples,{nose_manual=0}),plain),"a nose manual of 0 is none")
        check(same(Stage.new():preview(h,body,wheels,samples,{nose_manual_held=true}),plain),"a stick that holds a nose manual sends none by itself")
        for _,bad in ipairs({-.1,1.2,0/0,"half"}) do
            local refused=Stage.new():preview(h,body,wheels,samples,{nose_manual=bad})
            check(not refused.valid and refused.issue=="invalid_manual","the stage refuses a nose manual of "..tostring(bad))
        end
        local refused=Stage.new():preview(h,body,wheels,samples,{nose_manual=.5,nose_manual_held=1})
        check(not refused.valid and refused.issue=="invalid_manual","the stage refuses a nose_manual_held that is not true or false")
        local both=Stage.new():preview(h,body,wheels,samples,{manual=.5,nose_manual=.5,manual_held=true,nose_manual_held=true})
        check(both.valid and both.manual_active==true and both.nose_manual_active==false,"with both asked, it is the manual")
        local slow,slow_wheels=place(flat,1.2)
        check(Stage.new():preview(h,slow,slow_wheels,contacts(flat,slow,0),{nose_manual=.5}).nose_manual_active==false,
            "at 1.2 m/s on both wheels it does not start")
        check(Stage.new():preview(h,body,wheels,samples,{nose_manual=.5,brake=1}).nose_manual_active==false,"nor with B held")
    end)
    case(function() -- A held nose manual: the rear lifts at once, holds where the stick puts it, coasts, and comes down again.
        for _,speed in ipairs({2,4,7}) do
            for _,row in ipairs({{m=.01,shift=-.215},{m=.5,shift=-.166},{m=1,shift=-.116},speed==4 and {m=.5,shift=-.166,pedal=true} or nil}) do
                local what=string.format("m=%.2f at %d m/s%s",row.m,speed,row.pedal and " with A held" or "")
                local hold=NOSE_HOLD[row.m]
                local ride,rows=nose({m=row.m,speed=speed,hold=180,after=60,pedal_before=row.pedal and 1 or nil,
                    during=row.pedal and function() return {pedal=1} end or nil})
                local lifted,engaged,front,low,high,peak,shift,target,pedalled=nil,true,0,math.huge,-math.huge,-math.huge,0,0,false
                local first,last,down,after,ended,again=nil,nil,nil,0,nil,false
                for _,r in rows do
                    if r.hold then
                        if not lifted and r.rear>.02 then lifted=r.t*h end
                        peak=math.max(peak,r.nd)
                        if r.out.nose_manual_active and r.out.pedaling then pedalled=true end
                        if r.t*h>=.25 then
                            engaged=engaged and r.out.nose_manual_active==true and r.out.manual_active==false
                            front=math.max(front,r.front)
                        end
                        if r.t*h>=1.5 and r.t*h<=3 then
                            low,high=math.min(low,r.nd),math.max(high,r.nd)
                            shift=math.max(shift,math.abs(r.out.manual_shift-row.shift))
                            target=math.max(target,math.abs(r.out.manual_target_offset-(.23-.1*row.m)))
                        end
                        if r.t==60 then first=r.speed end
                        if r.t==180 then last=r.speed end
                    elseif r.released then
                        if not down and r.rear<=.02 then down=(r.t-180)*h end
                        if down then after=math.max(after,r.rear) end
                        if not ended and not r.out.nose_manual_active then ended=r.t-180 end
                        if ended and r.out.nose_manual_active then again=true end
                    end
                end
                check(ride.refused==0,what..": every step is sent: "..ride.refused)
                check(lifted and lifted<=.25,what..": the rear is up within .25 s: "..tostring(lifted))
                check(engaged,what..": in the nose manual, not the manual, from .25 s")
                check(front<=.005,what..": the front tyre stays on the ground: "..front)
                check(math.abs(low-hold)<=.6 and math.abs(high-hold)<=.6 and peak<=hold+.5,
                    string.format("%s: holds %.1f to %.1f degrees, at most %.1f",what,low,high,peak))
                check(shift<=.01 and target<1e-6,string.format("%s: the shift within %.4f of %.3f, the target its offset",what,shift,row.shift))
                check(last-first<=0 and last-first>=-.6,string.format("%s: it coasts, %.2f m/s from 1 s to 3 s",what,last-first))
                check(not pedalled,what..": the rider does not pedal in it")
                check(down and down<=.5 and after<=.03,string.format("%s: let go, the rear is down in %s s and stays within %.3f",what,tostring(down),after))
                check(ended and ended*h<=1 and not again,what..": and the nose manual is over by 1 s: "..tostring(ended))
            end
        end
    end)
    case(function() -- The throw lifts the rear: one movement, gone after a second, and the weight shift alone after it.
        local first,reached,later=0,nil,math.huge
        local ride,rows=nose({m=.5,speed=4,hold=120,after=0})
        for _,r in rows do
            if r.t*h<=.1 then first=math.min(first,r.out.manual_couple) end
            if not reached and math.abs(r.nd-NOSE_HOLD[.5])<=1.5 then reached=r.t*h end
            if r.t*h>=1 then later=math.min(later,r.out.manual_couple) end
        end
        check(ride.refused==0 and first<=-790,"the rider throws the front down to lift the rear: "..first)
        check(reached and reached<=1.1,"and the bike is within 1.5 degrees of its hold by 1.1 s: "..tostring(reached))
        check(later>=-(W*.26)-1,"from 1 s the rider holds it with no more than the weight shift: "..later)
        -- The same pitched body every step, 12 degrees nose down with the rear up, so nothing but the throw can lift it.
        local flat=Ground.plane(0,0)
        local body,wheels=place(flat,4)
        local a=math.rad(12)
        body.orientation={math.sin(a/2),0,0,math.cos(a/2)}
        body.center_of_mass={0,R-M.turn(body.orientation,M.sub(G.front_axle,G.com))[2]-.005,0}
        local stage,thrown,late=Stage.new(),0,0
        for step=1,90 do
            local out,candidate=stage:preview(h,body,wheels,contacts(flat,body,0),{nose_manual=.01,nose_manual_held=true})
            check(out.valid and out.nose_manual_active,"the nose manual is on at step "..step..": "..tostring(out.issue))
            stage:_adopt(candidate);wheels=out.wheels
            if -out.manual_couple>W*.26 then thrown+=1;if step>62 then late+=1 end end
        end
        check(thrown>=55 and thrown<=61 and late==0,"a second of throw, then the weight shift alone: "..thrown.." "..late)
    end)
    case(function() -- The stick slammed between the ends of the band and the middle does not throw the bike over the bars.
        for _,speed in ipairs({2,4,7}) do
            for _,pattern in ipairs({{.01,1},{1,0},{0,1,.01,1,0}}) do
                local engaged,worst=false,-math.huge
                local ride,rows=nose({m=1,speed=speed,hold=240,after=0,during=function(t) return {nose=pattern[math.floor(t*h/.25)%#pattern+1]} end})
                for _,r in rows do
                    if r.hold then worst=math.max(worst,r.nd);engaged=engaged or r.out.nose_manual_active end
                end
                local what=string.format("at %d m/s through %s",speed,table.concat(pattern,","))
                check(ride.refused==0 and engaged and not fell(rows),what..": in the nose manual and no fall")
                check(worst<=31,string.format("%s: at most %.1f degrees",what,worst))
            end
        end
    end)
    case(function() -- On a street grade a nose manual holds its angle to the surface, uphill and down, and up a hill it slows to a walk.
        for _,row in ipairs({{grade=-.13,speed=3},{grade=-.13,speed=5},{grade=-.08,speed=3},{grade=-.08,speed=5},
            {grade=.08,speed=5},{grade=.13,speed=5},{grade=.08,speed=3,ends={2,2.8}},{grade=.13,speed=3,ends={1.3,1.9}}}) do
            local ground=Ground.plane(0,row.grade)
            local ride,rows=nose({m=.5,speed=row.speed,ground=ground,hold=180,after=0})
            local low,high,ended=math.huge,-math.huge,nil
            for _,r in rows do
                if r.hold and r.t*h>=1.2 and r.t*h<=2 then low,high=math.min(low,r.nd),math.max(high,r.nd) end
                if r.hold and r.t>30 and not ended and not r.out.nose_manual_active then ended=r.t*h end
            end
            local what=string.format("a grade of %.2f at %d m/s",row.grade,row.speed)
            check(ride.refused==0,what..": every step is sent")
            if row.ends then
                check(ended and ended>=row.ends[1] and ended<=row.ends[2],what..": the nose manual ends at a walk at "..tostring(ended))
            else
                check(not ended and math.abs(low-NOSE_HOLD[.5])<=.7 and math.abs(high-NOSE_HOLD[.5])<=.7,
                    string.format("%s: holds %.1f to %.1f degrees to the surface, still held at 2 s: %s",what,low,high,tostring(ended)))
            end
        end
        -- Slowed to a walk up 13% with the stick held, it does not start again; with A held the rider pedals on up.
        for _,pedal in ipairs({0,1}) do
            local ended,again,pedalled,later=nil,false,false,false
            local ride,rows=nose({m=.5,speed=3,ground=Ground.plane(0,.13),hold=360,after=0,during=function() return {pedal=pedal} end})
            for _,r in rows do
                if r.hold then
                    if r.t>30 and not ended and not r.out.nose_manual_active then ended=r.t*h end
                    if ended and r.out.nose_manual_active then again=true end
                    if r.out.nose_manual_active and r.out.pedaling then pedalled=true end
                    if ended and r.out.pedaling then later=true end
                end
            end
            local what="up 13% from 3 m/s with pedal "..pedal
            check(ride.refused==0 and ended and ended>=1.3 and ended<=1.9,what..": it ends at a walk at "..tostring(ended))
            check(not again,what..": and does not start again with the stick held")
            check(not pedalled and (pedal==0 or later),what..": the rider pedals only once the rear is down")
        end
        -- A and the stick held from a stop: the bike pedals to the start speed, lifts once, and coasts down to a walk.
        local lifts,up,lift_speed,down_speed,pedalled=0,false,nil,nil,false
        local ride=run({steps=720,controls=function() return {pedal=1,nose=.5} end,each=function(step,body,out,wheels,samples)
            local speed=math.sqrt(body.linear_velocity[1]^2+body.linear_velocity[3]^2)
            local rear=gap(samples[2])
            if rear>.05 and not up then up=true;lifts+=1;lift_speed=lift_speed or speed
            elseif rear<=.005 and up then up=false;down_speed=down_speed or speed end
            if down_speed and out.pedaling then pedalled=true end
        end})
        check(ride.refused==0 and lifts==1,"from a stop the rear lifts once in 12 s: "..lifts)
        check(lift_speed and lift_speed>=1.45 and lift_speed<=1.6,"at the start speed: "..tostring(lift_speed))
        check(down_speed and down_speed>=.95 and down_speed<=1.1,"and comes down at a walk: "..tostring(down_speed))
        check(pedalled,"after which the rider pedals on")
    end)
    case(function() -- B in a nose manual puts the rear down and keeps it down; B held first, the stick lifts nothing.
        for _,speed in ipairs({2,4,7}) do
            for _,m in ipairs({.01,1}) do
                local what=string.format("m=%.2f at %d m/s",m,speed)
                local pressed,down,worst,relift=nil,nil,-math.huge,false
                local ride,rows=nose({m=m,speed=speed,hold=240,after=0,during=function(t) return {brake=t>=90 and 1 or 0} end})
                for _,r in rows do
                    if r.hold and r.t>=90 then
                        if r.t==90 then pressed=r.nd end
                        worst=math.max(worst,r.nd)
                        if not down and r.rear<=.02 then down=(r.t-90)*h end
                        if down and r.rear>.02 then relift=true end
                    end
                end
                check(ride.refused==0 and down and down<=.5,what..": B puts the rear down in "..tostring(down).." s")
                check(worst<=pressed+.1,string.format("%s: tipping no further, at most %.2f from %.2f",what,worst,pressed))
                check(not relift,what..": and it stays down while B is held")
                local rose,engaged=0,false
                local _,first=nose({m=m,speed=speed,hold=120,after=0,during=function() return {brake=1} end})
                for _,r in first do if r.hold then rose=math.max(rose,r.rear);engaged=engaged or r.out.nose_manual_active end end
                check(rose<=.005 and not engaged,string.format("%s: with B held first the rear stays down, %.4f",what,rose))
            end
        end
    end)
    case(function() -- Too far over the bars: placed past the balance, the rider pulls it back as far as 51 degrees, not from 52.
        for _,deg in ipairs({44,48,50,51,52,54,56}) do
            local _,rows=nose({m=1,speed=4,pitch=-deg,before=0,hold=150,after=0})
            if deg<=51 then
                check(not fell(rows) and math.abs(rows[150].nd-30.2)<=.5,string.format("placed at %d, the held stick brings it back to %.1f",deg,rows[150].nd))
            else check(fell(rows),"placed at "..deg..", it goes over the bars") end
        end
        -- Let go after one step, the rear comes down from 50 degrees, and from 52 nothing holds it.
        for _,deg in ipairs({50,52,54}) do
            local _,rows=nose({m=1,speed=4,pitch=-deg,before=0,hold=150,after=0,during=function(t) return {nose=t==1 and 1 or 0,nose_held=false} end})
            if deg==50 then check(not fell(rows) and rows[150].rear<=.02,"let go at 50 degrees the rear comes down: "..rows[150].rear)
            else check(fell(rows),"let go at "..deg..", it goes over the bars") end
        end
    end)
    case(function() -- B past the balance does not throw the bike over the bars: the rider holds the front brake off there.
        -- The front brake's pull at the contact pitches the bike on round it. Whole there, B and the held stick took
        -- a bike placed at 44, 46 and 48 degrees over the bars.
        for _,deg in ipairs({44,46,48}) do
            local _,rows=nose({m=1,speed=4,pitch=-deg,before=0,hold=150,after=0,during=function() return {brake=1} end})
            local over=fell(rows)
            check(rows[1].out.nose_manual_active==true and not over and rows[150].rear<=.02,
                string.format("placed at %d with B held, the rear comes down: over the bars %s, the rear %.3f up",deg,tostring(over),rows[150].rear))
        end
    end)
    case(function() -- Steering a nose manual swings the rear round the front wheel, the way the bars turn the bike on two.
        local rates={}
        for _,speed in ipairs({2.5,4,7}) do
            local two,two_count=0,0
            run({steps=315,speed=speed,controls=function(step) return {steer=step>90 and step<=270 and 1 or 0} end,each=function(step,body)
                if step>150 and step<=270 then two+=body.angular_velocity[2];two_count+=1 end
            end})
            two/=two_count
            for _,steer in ipairs({1,-1,.3}) do
                local what=string.format("steer %.1f at %.1f m/s",steer,speed)
                local yaw,count,most,engaged,low,high,bars,slip=0,0,0,true,math.huge,-math.huge,0,0
                local ride,rows=nose({m=.5,speed=speed,hold=300,after=0,during=function(t) return {steer=t>75 and t<=255 and steer or 0} end})
                for _,r in rows do
                    if r.hold and r.t*h>=.25 then engaged=engaged and r.out.nose_manual_active==true end
                    if r.hold and r.t>75 and r.t<=255 then bars=math.max(bars,math.abs(r.out.front_steer_angle)) end
                    if r.hold and r.t>135 and r.t<=255 then
                        yaw+=r.body.angular_velocity[2];count+=1;most=math.max(most,math.abs(r.body.angular_velocity[2]))
                        low,high=math.min(low,r.nd),math.max(high,r.nd)
                        -- The heading against the travel, both along the ground: the rear swung out round the front.
                        local f,v=M.turn(M.normalized(r.body.orientation),{0,0,1}),r.body.linear_velocity
                        local cross=(f[1]*v[3]-f[3]*v[1])/(math.sqrt(f[1]^2+f[3]^2)*math.sqrt(v[1]^2+v[3]^2))
                        slip=math.max(slip,math.abs(math.deg(math.asin(math.clamp(cross,-1,1)))))
                    end
                end
                yaw/=count
                rates[speed..":"..steer]=yaw
                check(ride.refused==0 and engaged,what..": in the nose manual throughout")
                check(most<=1.15*math.abs(yaw),string.format("%s: a steady carve, at most %.3f against %.3f",what,most,yaw))
                check(math.abs(low-26.9)<=.6 and math.abs(high-26.9)<=.6,string.format("%s: holds %.1f to %.1f degrees",what,low,high))
                check(bars<=.06,string.format("%s: the bars turn no more than %.3f",what,bars))
                check(slip<=2,string.format("%s: once carving, the bike points along its travel within %.1f degrees",what,slip))
                if steer==1 then
                    local band=({[2.5]={-.6,-.5},[4]={-.65,-.55},[7]={-.5,-.4}})[speed]
                    check(yaw>=band[1] and yaw<=band[2] and yaw*two>0,string.format("%s: carves at %.3f rad/s, the way steering turns at %.3f",what,yaw,two))
                end
            end
            local full=rates[speed..":1"]
            check(math.abs(rates[speed..":-1"]+full)<=.01,string.format("at %.1f m/s the other way mirrors it: %.3f against %.3f",speed,rates[speed..":-1"],full))
            local part=rates[speed..":0.3"]/full
            check(part>=.25 and part<=.35,string.format("at %.1f m/s a third of the stick carves %.2f as fast",speed,part))
        end
    end)
    case(function() -- Carved into from a turn on both wheels, the bars come back to the front wheel's path in a few steps.
        -- Cut to that path in one step, they snapped .17 to .18 rad at full lock and .09 at half as the rear came up.
        for _,speed in ipairs({1.8,2.5,4,7}) do
            for _,steer in ipairs({1,.5,-1}) do
                local what=string.format("steer %.1f at %.1f m/s",steer,speed)
                local last,worst,engaged=nil,0,0
                local ride=run({steps=180,speed=speed,controls=function(step) return {steer=steer,nose=step>60 and .5 or nil} end,
                    each=function(step,body,out)
                        if not out.valid then return end
                        if last then worst=math.max(worst,math.abs(out.front_steer_angle-last)) end
                        last=out.front_steer_angle
                        if out.nose_manual_active then engaged+=1 end
                    end})
                check(ride.refused==0 and engaged==120,what..": in the nose manual from the first step of the stick: "..engaged)
                check(worst<=.06,string.format("%s: the bars turn at most %.3f rad in a step",what,worst))
            end
        end
    end)
    case(function() -- Carving on its front wheel at full lock over an 8 cm bump downhill, the bike does not spin round.
        -- Off the bump the bike is in the air for a moment and the nose manual begins again as it lands. The bars were
        -- brought back to the front wheel's path from there at twice the stick's rate, as on the way in, and were left past
        -- it for several steps: yaw 2.2 rad/s at 4 m/s, and at 5 m/s the bike spun round, 89 degrees off its travel. Once
        -- on that path they now keep to it for the rest of the nose manual.
        local FRONT=G.front_axle[3]-G.com[3]
        for _,row in ipairs({{grade=-.08,speed=4,m=.01},{grade=-.08,speed=5,m=.5}}) do
            local what=string.format("an 8 cm bump from %.1f m/s down %d%% at full lock, m=%.2f",row.speed,math.floor(-row.grade*100+.5),row.m)
            local at=FRONT+row.speed*3.2
            local plane,bump=Ground.plane(0,row.grade),Ground.bump(at,.08,.4)
            local ground={height=function(x,z) return plane.height(x,z)+bump.height(x,z) end,
                grad=function(x,z) local px,pz=plane.grad(x,z);local bx,bz=bump.grad(x,z);return px+bx,pz+bz end}
            local ride,rows=nose({m=row.m,speed=row.speed,ground=ground,hold=330,after=0,during=function(t) return {steer=t>60 and 1 or 0} end})
            local met,carving,yaw,slip=nil,false,0,0
            for _,r in rows do
                if not met and r.body.center_of_mass[3]+FRONT>=at then met=r.speed;carving=r.out.nose_manual_active==true end
                yaw=math.max(yaw,math.abs(r.body.angular_velocity[2]))
                local f,v=M.turn(M.normalized(r.body.orientation),{0,0,1}),r.body.linear_velocity
                local fl,vl=math.sqrt(f[1]^2+f[3]^2),math.sqrt(v[1]^2+v[3]^2)
                if vl>=.5 and fl>1e-6 then slip=math.max(slip,math.abs(math.deg(math.asin(math.clamp((f[1]*v[3]-f[3]*v[1])/(fl*vl),-1,1))))) end
            end
            -- Kept on the front wheel, the tyre meets the bump's face pressed down, and on two steps it goes past the
            -- penetration limit, which the kernel refuses.
            check(ride.refused<=2 and met~=nil and carving,string.format("%s: met at %.2f m/s in the nose manual, %d steps refused",
                what,met or -1,ride.refused))
            check(not fell(rows) and yaw<=2 and slip<=30,string.format("%s: no spin, at most %.2f rad/s and %.1f degrees off its travel",what,yaw,slip))
        end
    end)
    case(function() -- Carving on its front wheel into a small bump at pedalling speed, the bike keeps carving and stays up.
        -- With the lean following whatever yaw the bump gave and the twist rolling the pitched body, all three spun
        -- round at 3 to 3.8 rad/s, 89 degrees off their travel, and the two downhill fell. On both wheels the same rides
        -- reach .8 to 1.5 rad/s and 5 to 6 degrees.
        local FRONT=G.front_axle[3]-G.com[3]
        for _,row in ipairs({{grade=0,speed=7.6,steer=1,m=.5},{grade=-.13,speed=4,steer=.5,m=.01},{grade=-.08,speed=6,steer=.5,m=.01}}) do
            local what=string.format("a 5 cm bump from %.1f m/s down %d%%, steer %.1f, m=%.2f",row.speed,math.floor(-row.grade*100+.5),row.steer,row.m)
            -- The front tyre meets the bump about 3.2 s into the ride, carving by then.
            local at=FRONT+row.speed*3.2
            local plane,bump=Ground.plane(0,row.grade),Ground.bump(at,.05,.4)
            local ground={height=function(x,z) return plane.height(x,z)+bump.height(x,z) end,
                grad=function(x,z) local px,pz=plane.grad(x,z);local bx,bz=bump.grad(x,z);return px+bx,pz+bz end}
            local ride,rows=nose({m=row.m,speed=row.speed,ground=ground,hold=330,after=0,during=function(t) return {steer=t>60 and row.steer or 0} end})
            local met,carving,yaw,slip=nil,false,0,0
            for _,r in rows do
                if not met and r.body.center_of_mass[3]+FRONT>=at then met=r.speed;carving=r.out.nose_manual_active==true end
                yaw=math.max(yaw,math.abs(r.body.angular_velocity[2]))
                local f,v=M.turn(M.normalized(r.body.orientation),{0,0,1}),r.body.linear_velocity
                local fl,vl=math.sqrt(f[1]^2+f[3]^2),math.sqrt(v[1]^2+v[3]^2)
                if vl>=.5 and fl>1e-6 then slip=math.max(slip,math.abs(math.deg(math.asin(math.clamp((f[1]*v[3]-f[3]*v[1])/(fl*vl),-1,1))))) end
            end
            check(ride.refused==0 and met~=nil and met>=5 and carving,string.format("%s: met at %.2f m/s in the nose manual",what,met or -1))
            check(not fell(rows),what..": no fall")
            check(yaw<=1.2 and slip<=8,string.format("%s: no spin, at most %.2f rad/s and %.1f degrees off its travel",what,yaw,slip))
        end
    end)
    case(function() -- Carving on its front wheel down a hill at 10 m/s, the steer stick let go or eased: the lean follows the yaw up.
        -- With the lean target held between none and the carve the bars ask for, the stick let go pinned it upright while
        -- the bike still yawed: the lean swung through upright to the other side, the nose manual ended and the bike fell,
        -- 88 degrees over from 7 and 7.6 m/s down 13%, and with the stick eased to .3 it went 84 to 88 degrees over.
        local n=M.unit({0,1,.13})
        for _,row in ipairs({{speed=7,steer=1,m=1,eased=0},{speed=7.6,steer=1,m=1,eased=0},{speed=7.6,steer=1,m=1,eased=.3},
            {speed=7.6,steer=1,m=.5,eased=0},{speed=7.6,steer=.5,m=1,eased=0}}) do
            local what=string.format("from %.1f m/s down 13%%, steer %.1f eased to %.1f, m=%.2f",row.speed,row.steer,row.eased,row.m)
            local ride,rows=nose({m=row.m,speed=row.speed,ground=Ground.plane(0,-.13),hold=330,after=0,
                during=function(t) return {steer=t>60 and (t<=210 and row.steer or row.steer*row.eased) or 0} end})
            local before,after,engaged,speed=0,0,true,0
            for _,r in rows do
                local left=M.turn(M.normalized(r.body.orientation),{1,0,0})
                local lean=math.abs(math.deg(math.asin(math.clamp(M.dot(left,n),-1,1))))
                if r.hold and r.t>150 and r.t<=210 then before=math.max(before,lean) speed=r.speed end
                if r.hold and r.t>210 then after=math.max(after,lean) engaged=engaged and r.out.nose_manual_active==true end
            end
            check(ride.refused==0 and speed>=9.5 and not fell(rows),string.format("%s: at %.1f m/s at the let-go, and no fall",what,speed))
            check(engaged,what..": still in the nose manual")
            check(after<=1.5*before,string.format("%s: leans at most %.1f degrees after, against %.1f carving",what,after,before))
        end
    end)
    case(function() -- Dropped front first with the stick held, the bike lands into the nose manual; with it let go, onto both wheels.
        for _,deg in ipairs({8,18,28,36}) do
            for _,m in ipairs({0,.5,1}) do
                local what=string.format("dropped at %d degrees with m=%.1f",deg,m)
                local _,rows=nose({m=m,speed=4,pitch=-deg,lift=.3,before=0,hold=150,after=0,during=function() return {nose=m,nose_held=m>0} end})
                local touched,engaged,most,down,ever=nil,0,-math.huge,nil,false
                for _,r in rows do
                    if not touched and r.front<=.02 then touched=r.t end
                    ever=ever or r.out.nose_manual_active
                    if touched then
                        most=math.max(most,r.lnd)
                        if r.out.nose_manual_active then engaged+=1 end
                        if not down and r.rear<=.02 then down=(r.t-touched)*h end
                    end
                end
                if m>0 then
                    check(touched and engaged>=128,what..": in the nose manual on "..engaged.." steps after the touch")
                    check(most<=math.max(deg,NOSE_HOLD[m])+.5,string.format("%s: at most %.1f degrees",what,most))
                else
                    check(not ever and down and down<=.45,what..": no nose manual, and the rear is down in "..tostring(down).." s")
                end
            end
        end
    end)
    case(function() -- R3 from a nose manual: a full hop that lands front first and goes back into the nose manual.
        for _,speed in ipairs({3,4,7}) do
            for _,m in ipairs({.01,1}) do
                local what=string.format("m=%.2f at %d m/s",m,speed)
                -- As input sends it: the pop step sends no nose manual, and the stick still holds one.
                local ride,rows=nose({m=m,speed=speed,hold=200,after=0,during=function(t)
                    if t==90 then return {hop=true,nose=0,nose_held=true} end
                    return {}
                end})
                local air,landed,first,landing,worst,back=0,nil,nil,nil,-math.huge,nil
                for _,r in rows do
                    if r.hold and r.t>90 then
                        local front,rear=r.front<=.02,r.rear<=.02
                        if not landed then
                            if not front and not rear then air+=1
                            elseif air>0 then landed=r.t;first=front and (rear and "both" or "front") or "rear";landing=r.lnd end
                        else
                            worst=math.max(worst,r.lnd)
                            if not back and r.out.nose_manual_active then back=(r.t-landed)*h end
                        end
                    end
                end
                check(ride.refused==0 and air*h>=.85 and air*h<=1.05,what..": a full hop, "..air*h.." s in the air")
                check(landed and first~="rear" and landing<=10,string.format("%s: lands %s first at %.1f degrees",what,tostring(first),landing or 0/0))
                check(worst<=NOSE_HOLD[m]+.5,string.format("%s: at most %.1f degrees after",what,worst))
                check(back and back<=.1,what..": and is in the nose manual again in "..tostring(back).." s")
            end
        end
    end)
    case(function() -- The car stop's push in a held nose manual stops the bike without tipping it over the bars.
        -- Ride's stop pushes back along the travel through the centre of mass, at most 5400 N, at the stop's deceleration.
        for _,speed in ipairs({2,4,7}) do
            for _,m in ipairs({.01,1}) do
                for _,decel in ipairs({10,25,45}) do
                    local what=string.format("m=%.2f at %d m/s stopped at %d m/s^2",m,speed,decel)
                    local from=15+72
                    local ride,rows=nose({m=m,speed=speed,hold=72+90,after=1,push=function(step,body)
                        if step<from then return nil end
                        local v=body.linear_velocity
                        local flat=math.sqrt(v[1]^2+v[3]^2)
                        if flat<.05 then return nil end
                        local f=math.min(5400,body.mass*decel)
                        return {-v[1]/flat*f,0,-v[3]/flat*f}
                    end})
                    local held,worst,ended,down=rows[from].lnd,-math.huge,nil,nil
                    check(rows[from].out.nose_manual_active==true and rows[from].rear>.1,what..": held in the nose manual when the push starts")
                    for step=from,from+90 do
                        local r=rows[step]
                        worst=math.max(worst,r.lnd)
                        if not ended and not r.out.nose_manual_active then ended=(step-from)*h end
                        if not down and r.rear<=.005 then down=(step-from)*h end
                    end
                    check(ride.refused==0 and not fell(rows) and worst<=held+.5,string.format("%s: no further over than %.1f from %.1f",what,worst,held))
                    check(ended and ended<=1 and down and down<=1,what..": the nose manual ends with the rear down: "..tostring(ended).." "..tostring(down))
                end
            end
        end
    end)
    -- Where the front axle is 1.2 s into a nose manual begun after 15 steps, and how long to hold it: over the shape, a
    -- metre more, and a second after.
    local FRONT_AXLE=G.front_axle[3]-G.com[3]
    local function met(row) return FRONT_AXLE+row.speed*(1.2+15*h),math.ceil((1.2+(row.length+1)/row.speed+1)/h) end
    case(function() -- A bump or a kerb ramp at walking pace in a nose manual: the rider snaps the weight back, briefly.
        -- Each tips the bike on over the bars faster than the law asks. With no more than the static pull back
        -- (nose_hold_back) every one of these went over the bars.
        for _,row in ipairs({
            {what="a 12 cm bump .4 m long",shape=function(at) return Ground.bump(at,.12,.4) end,length=.4,speed=1.6,m=.3},
            {what="a 12 cm bump .4 m long",shape=function(at) return Ground.bump(at,.12,.4) end,length=.4,speed=1.6,m=1},
            {what="a 12 cm bump .6 m long",shape=function(at) return Ground.bump(at,.12,.6) end,length=.6,speed=1.6,m=.3},
            {what="a 12 cm bump .6 m long",shape=function(at) return Ground.bump(at,.12,.6) end,length=.6,speed=2.5,m=1},
            {what="a 10 cm kerb ramp over .2 m",shape=function(at) return Ground.rise(at,.10,.2) end,length=.2,speed=1.6,m=.3},
            {what="a 10 cm kerb ramp over .2 m",shape=function(at) return Ground.rise(at,.10,.2) end,length=.2,speed=2.5,m=.3},
            {what="a 10 cm kerb ramp over .2 m",shape=function(at) return Ground.rise(at,.10,.2) end,length=.2,speed=2.5,m=1},
            {what="a 15 cm kerb ramp over .2 m",shape=function(at) return Ground.rise(at,.15,.2) end,length=.2,speed=1.6,m=.3},
        }) do
            local what=string.format("%s at %.1f m/s, m=%.1f",row.what,row.speed,row.m)
            local at,hold=met(row)
            local ride,rows=nose({m=row.m,speed=row.speed,ground=row.shape(at),hold=hold,after=0})
            local peak,pulled,most=0,0,0
            for _,r in rows do
                if r.hold then
                    peak=math.max(peak,r.tilt)
                    -- The steps of a lift the rider pulls back past the static limit: at most nose_catch_seconds.
                    if r.out.nose_manual_active and r.rear>.02 then
                        if r.out.manual_couple>W*.20+1 then pulled+=1 end
                    else pulled=0 end
                    most=math.max(most,pulled)
                end
            end
            check(ride.refused==0 and not fell(rows) and peak<=47,string.format("%s: no fall, at most %.1f degrees from world up",what,peak))
            check(most<=25,string.format("%s: the catch pulls past the static limit on %d steps of a lift",what,most))
        end
    end)
    case(function() -- Thrown off the front by a bump or a kerb's top with the stick held, the rider holds the bike's angle in the air.
        -- With no hold in the air every one of these went over the bars once the front left the ground.
        local most_air=Forces.tuning().air_pitch_torque
        for _,row in ipairs({
            {what="an 8 cm bump .4 m long",shape=function(at) return Ground.bump(at,.08,.4) end,length=.4,speed=4,m=.3},
            {what="an 8 cm bump .4 m long",shape=function(at) return Ground.bump(at,.08,.4) end,length=.4,speed=4,m=1},
            {what="a 12 cm bump .4 m long",shape=function(at) return Ground.bump(at,.12,.4) end,length=.4,speed=2.5,m=.3},
            {what="a 12 cm bump .6 m long",shape=function(at) return Ground.bump(at,.12,.6) end,length=.6,speed=4,m=1},
            {what="a 12 cm bump .6 m long",shape=function(at) return Ground.bump(at,.12,.6) end,length=.6,speed=7,m=1},
            {what="a 25 degree kicker onto a 30 cm deck",shape=function(at) return Ground.kicker(at,math.rad(25),.3,.3) end,length=2,speed=7,m=1,down=true},
            {what="a 15 cm kerb ramp over .5 m",shape=function(at) return Ground.rise(at,.15,.5) end,length=.5,speed=7,m=1},
        }) do
            local what=string.format("%s at %.1f m/s, m=%.1f",row.what,row.speed,row.m)
            local at,hold=met(row)
            local _,rows=nose({m=row.m,speed=row.speed,ground=row.shape(at),hold=hold,after=0})
            local held,most,late,supported=false,0,0,nil
            for _,r in rows do
                if r.out.balance_support_mask~=0 then supported=r.t end
                -- A refused step sends nothing, so it holds nothing either.
                local air=r.out.valid and r.out.nose_air_couple or 0
                if air~=0 then
                    held=true;most=math.max(most,type(air)=="number" and math.abs(air) or math.huge)
                    -- At most nose_air_seconds after the last step the kernel had the front on the ground.
                    if (r.t-supported)*h>.5+h+1e-6 then late+=1 end
                end
            end
            check(not fell(rows),what..": no fall")
            check(held and most<=most_air,string.format("%s: the rider holds it in the air, at most %.0f N*m",what,most))
            check(late==0,what..": for no more than half a second: "..late.." steps later")
            if row.down then check(rows[#rows].rear<=.02 and not rows[#rows].out.nose_manual_active,what..": and lands with the rear down") end
        end
        -- The hold is the held stick's: let go as the kernel first sees the bike in the air, there is none.
        local row={shape=function(at) return Ground.bump(at,.08,.4) end,length=.4,speed=4}
        local at,hold=met(row)
        local flying,held=false,false
        local _,rows=nose({m=1,speed=4,ground=row.shape(at),hold=hold,after=0,during=function(t,body,folded,forecast)
            flying=flying or not Forces.eligible_support(folded,forecast[1],.005,.10) and not Forces.eligible_support(folded,forecast[2],.005,.10)
            return flying and {nose_held=false} or {}
        end})
        for _,r in rows do held=held or r.out.valid and r.out.nose_air_couple~=0 end
        check(flying and not held,"with the stick let go in the air the rider holds nothing")
        -- A hop pops the bike off the front: no hold over R3's flight.
        for _,speed in ipairs({3,4,7}) do
            for _,m in ipairs({.01,1}) do
                local hopped=false
                local _,flight=nose({m=m,speed=speed,hold=200,after=0,during=function(t)
                    if t==90 then return {hop=true,nose=0,nose_held=true} end
                    return {}
                end})
                for _,r in flight do hopped=hopped or r.out.valid and r.out.nose_air_couple~=0 end
                check(not hopped,string.format("R3 at %d m/s, m=%.2f: no hold in the hop's flight",speed,m))
            end
        end
    end)
    return {cases=cases,assertions=n,native_authority=false,constructed=true}
end
return T

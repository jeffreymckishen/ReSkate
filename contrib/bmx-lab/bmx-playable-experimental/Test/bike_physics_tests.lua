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
-- ride.steps, and ride.controls(step,body) -> {pedal,steer,brake,hop,manual}. ride.pitch starts the bike that many
-- degrees nose up on its rear wheel. Returns the peaks, and calls ride.each(step,body,out,wheels,samples) with the
-- wheel rays this step's command was made from.
local function run(ride)
    local stage=Stage.new()
    local body,wheels=place(ride.ground or Ground.plane(0,0),ride.speed or 0,ride.yaw)
    if ride.pitch then
        local a=-math.rad(ride.pitch)
        body.orientation={math.sin(a/2),0,0,math.cos(a/2)}
        local rear=M.turn(body.orientation,M.sub(G.rear_axle,G.com))
        body.center_of_mass={0,R-rear[2]-.005,0}
    end
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
        local want=ride.controls and ride.controls(step,body) or {}
        local input={pedal=want.pedal or 0,steer=want.steer or 0,brake=want.brake or 0}
        if want.hop then hop_id+=1;input.hop_event_id=hop_id;input.hop_strength=1 end
        if want.manual then
            -- As Mapping sends it: only while a wheel is on the ground.
            local grounded=false
            for i=1,2 do grounded=grounded or samples[i].contact.status=="hit" and Forces.eligible_support(body,samples[i],.005,.10) end
            input.manual=grounded and want.manual or 0
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
    return {cases=cases,assertions=n,native_authority=false,constructed=true}
end
return T

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
-- ride.steps, and ride.controls(step,body) -> {pedal,steer,brake,hop}. Returns the peaks, and calls ride.each(step,body,out).
local function run(ride)
    local stage=Stage.new()
    local body,wheels=place(ride.ground or Ground.plane(0,0),ride.speed or 0,ride.yaw)
    local previous
    local angle,hop_id=0,0
    local peak={tilt=0,speed=0,refused=0,slip=0,height=0}
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
        local flat=math.sqrt(body.linear_velocity[1]^2+body.linear_velocity[3]^2)
        local forward=M.turn(M.normalized(body.orientation),{0,0,1})
        if flat>1 then
            local dot=(forward[1]*body.linear_velocity[1]+forward[3]*body.linear_velocity[3])/(flat*math.sqrt(forward[1]^2+forward[3]^2))
            peak.slip=math.max(peak.slip,math.deg(math.acos(math.clamp(dot,-1,1))))
        end
        peak.tilt=math.max(peak.tilt,tilt_of(body));peak.speed=math.max(peak.speed,flat)
        peak.height=math.max(peak.height,body.center_of_mass[2]-start)
        if ride.each then ride.each(step,body,out,wheels) end
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
        check(radius<10 and radius>8,"radius at top speed: "..radius)
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
        leaned.center_of_mass={0,1.3,0}
        leaned.linear_velocity={0,-3,0}
        local out=Forces.new():preview(h,leaned,Forces.proposed_wheels(),contacts(Ground.plane(0,0),leaned,0),
            Forces.controls({contact_compliance_available=true,landing_contact_compliance_selected=true}))
        check(out.valid and out.landing_approach_mask~=0 and M.length(out.force)>0,"a leaned bike is braked on the way down")
        local forward=M.turn(M.normalized(leaned.orientation),{0,0,1})
        check(math.abs(M.dot(out.contact_torque,forward))<1,"and that brake has no lever to roll it with: "..M.dot(out.contact_torque,forward))
    end)
    case(function() -- A bank does not add to the lean: gravity sets the roll, not the ground.
        local peak=run({steps=360,speed=5,ground=Ground.twist(math.rad(33),2,6)})
        check(peak.tilt<30 and peak.refused==0,"across a 33 degree bank, wheels straight: "..peak.tilt)
        local falling=run({steps=240,speed=7,ground=Ground.plane(math.tan(math.rad(30)),0),controls=function() return {steer=-1} end})
        check(falling.tilt<55,"full left down a 30 degree plane: "..falling.tilt)
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
        for _,row in ipairs({{speed=6,stick=1,grade=0},{speed=7.4,stick=.5,grade=0},{speed=6,stick=1,grade=.05},{speed=7.4,stick=1,grade=.05},{speed=7.4,stick=.5,grade=.1}}) do
            local locked=0
            local peak=run({steps=300,speed=row.speed,ground=Ground.plane(0,-row.grade),controls=function(step)
                return {steer=-row.stick,brake=step>90 and 1 or 0}
            end,each=function(step,body,out,wheels)
                if step>90 and M.length(body.linear_velocity)>1.5 and wheels[2].angular_speed==0 then locked+=1 end
            end})
            check(peak.slip<12,string.format("%.1f m/s, stick %.1f, grade %.2f: peak slip %.1f",row.speed,row.stick,row.grade,peak.slip))
            check(locked==0,"the rear wheel keeps turning")
        end
        local stop=run({steps=210,speed=7.4,controls=function() return {brake=1} end})
        check(M.length(stop.body.linear_velocity)<.5,"a straight stop from top speed takes under 3.5 s")
    end)
    case(function() -- A stopped bike holds on a street grade, and a stall on a ramp still rolls back.
        for _,grade in ipairs({-.1,-.05,-.02,.02,.05,.1}) do
            local ground=Ground.plane(0,grade)
            local from
            local peak=run({steps=600,ground=ground,each=function(step,body) if step==60 then from=M.copy(body.center_of_mass) end end})
            check(M.length(M.sub(peak.body.center_of_mass,from))<.005,"holds on a grade of "..grade)
        end
        local bank=Ground.plane(0,math.tan(math.rad(20)))
        local stall=run({steps=300,speed=.1,ground=bank})
        check(stall.body.linear_velocity[3]< -1,"a 20 degree ramp is too steep to hold")
        local hop=run({steps=120,controls=function(step) return {hop=step==60} end})
        check(hop.height>.9,"a hop leaves from a held stop")
        local away=run({steps=60,ground=Ground.plane(0,.08),controls=function(step) return {pedal=step>30 and 1 or 0} end})
        check(M.length(away.body.linear_velocity)>.7,"the pedal lets go of the hold at once")
    end)
    return {cases=cases,assertions=n,native_authority=false,constructed=true}
end
return T

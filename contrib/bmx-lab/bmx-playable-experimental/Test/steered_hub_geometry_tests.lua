-- Constructed geometry and actual Ride query plumbing only; no native or
-- landing/support/steering-joint qualification. This fixture is authored UNRUN.
local G=require("./bike_geometry")
local M=require("./force_math")
local Forces=require("./forces")
local Stage=require("./force_stage")
local Visual=require("./bike_visual")
local MP=require("./mounted_pose")
local Fixtures=require("./ride_runtime_tests")
local Tests={}
local function apply(m,p)
    return {m[1]*p[1]+m[5]*p[2]+m[9]*p[3]+m[13],
        m[2]*p[1]+m[6]*p[2]+m[10]*p[3]+m[14],
        m[3]*p[1]+m[7]*p[2]+m[11]*p[3]+m[15]}
end
local function near(a,b,e)
    for i=1,3 do if math.abs(a[i]-b[i])>e then return false end end
    return true
end
-- Constructed sloped-plane invariant; not a replay of the human F126 stop.
-- A measured ray and an analytic reference describe the same plane and hub gap.
local function floor_geometry_case(check)
 local function same_vector(a,b,why)check(M.length(M.sub(a,b))<1e-7,why)end
 local h,radius=Forces.native_seconds,Forces.wheel_radius
 local angle=math.rad(8)
 local body=Forces.proposed_body()
 body.orientation={math.sin(angle*.5),0,0,math.cos(angle*.5)}
 body.center_of_mass={3,2,5}
 local normal=M.turn(body.orientation,{0,1,0})
 local forward=M.turn(body.orientation,{0,0,1})
 body.linear_velocity=M.sub(M.mul(forward,1.25),M.mul(normal,.25))
 -- Zero initial angular velocity makes grounded truth independent of which
 -- point on the same plane is supplied; the normal impulse still has a lever.
 body.angular_velocity={0,0,0}
 local wheels=Forces.proposed_wheels()
 for _,wheel in ipairs(wheels)do wheel.angular_speed=1.25/wheel.radius end
 local hubs={M.add(body.center_of_mass,M.turn(body.orientation,M.sub(G.front_axle,G.com))),
  M.add(body.center_of_mass,M.turn(body.orientation,M.sub(G.rear_axle,G.com)))}
 local controls={pedal=0,steer=0,brake=0}
 local function samples_at(front_gap)
  local plane_d=M.dot(hubs[1],normal)-radius-front_gap
  local rays,reference={},{}
  for i=1,2 do
   local distance=M.dot(hubs[i],normal)-plane_d
   local down={0,-1,0}
   local ray_length=distance/-M.dot(down,normal)
   local point=M.add(hubs[i],M.mul(down,ray_length))
   local projected=M.sub(hubs[i],M.mul(normal,distance))
   check(ray_length>0 and ray_length<radius+.75,"the finite current downward segment actually hits")
   check(math.abs(M.dot(point,normal)-plane_d)<1e-12
    and math.abs(M.dot(projected,normal)-plane_d)<1e-12,"both points lie on the exact same plane")
   check(math.abs(point[1]-3)<2 and math.abs(point[3]-5)<2
    and math.abs(projected[1]-3)<2 and math.abs(projected[3]-5)<2,"both points lie inside the finite face")
   local hub_jacobian=M.cross(M.sub(hubs[i],body.center_of_mass),normal)
   local projected_jacobian=M.cross(M.sub(projected,body.center_of_mass),normal)
   check(M.length(M.sub(projected_jacobian,hub_jacobian))<1e-12,
    "the normal projection preserves the derivative of the measured hub gap")
   check(M.length(M.sub(M.cross(M.sub(point,body.center_of_mass),normal),hub_jacobian))>.01,
    "a raw gravity-ray lever differs on this slope and cannot be substituted at contact")
   rays[i]={contact={status="hit",point=point,normal=M.copy(normal),forward=M.copy(forward),
    surface_velocity={0,0,0}},separation=distance-radius,wheel_center=M.copy(hubs[i]),wheel_radius=radius,
    verified_plane=false,balance_normal_available=false}
   reference[i]=M.copy(rays[i])
   -- This is an independent geometric reference, not a second observed ray.
   reference[i].contact.point=projected
  end
  return rays,reference
 end
 local function bounded(out,label)
  check(out.valid,label..": "..tostring(out.issue))
  check(out.contact_scale==1 and M.length(out.force)<=6000 and M.length(out.torque)<=2000,
   label.." retains the unchanged unscaled authored caps")
  check(not out.hop_applied and out.hop_event_id==0,label.." creates no hop")
 end
 local function equivalent(a,b,label)
  same_vector(a.force,b.force,label.." force is independent of tangential hit displacement")
  same_vector(a.torque,b.torque,label.." torque uses the same hub-gap Jacobian")
  check(a.grounded==b.grounded and a.balance_support_mask==b.balance_support_mask,
   label.." geometry does not invent support")
  for i=1,2 do
   check(math.abs(a.normal_impulse[i]-b.normal_impulse[i])<1e-7
    and math.abs(a.approach_normal_impulse[i]-b.approach_normal_impulse[i])<1e-7,
    label.." retains the same normal impulse")
   check(math.abs(a.wheels[i].angular_speed-b.wheels[i].angular_speed)<1e-7,
    label.." retains the same rotor result")
  end
 end
 -- Independent fresh previews straddle the existing 5 mm branch. This tests
 -- geometry on each side, not equality of the two different contact laws.
 for _,gap in ipairs({.006,.00501,.005,.00499,.004})do
  local samples,reference=samples_at(gap)
  local before=M.copy(samples)
  local stage=Stage.new()
  local actual,discarded=stage:preview(h,body,wheels,samples,controls)
  local expected=Stage.new():preview(h,body,wheels,reference,controls)
  bounded(actual,"ray gap "..tostring(gap))
  bounded(expected,"reference gap "..tostring(gap))
  equivalent(actual,expected,"gap "..tostring(gap))
  local expected_ground=false
  for i=1,2 do
   local approach=samples[i].separation>.005
   check((bit32.band(actual.landing_approach_mask,2^(i-1))~=0)==approach,
    "the unchanged measured gap chooses approach versus contact")
   expected_ground=expected_ground or Forces.eligible_support(body,samples[i],.005,.10)
   same_vector(samples[i].contact.point,before[i].contact.point,"preview preserves the observed hit")
   same_vector(samples[i].wheel_center,before[i].wheel_center,"preview preserves the observed hub")
  end
  check(actual.grounded==expected_ground,"only current support eligibility grants grounded truth")
  local again,accepted=stage:preview(h,body,wheels,samples,controls)
  bounded(again,"discarded preview")
  equivalent(actual,again,"discarded preview")
  check(discarded~=accepted,"a later preview has its own exact adoption token")
  check(not pcall(stage._adopt,stage,discarded),"discarded tokens still cannot adopt history")
  stage:_adopt(accepted)
  check(not pcall(stage._adopt,stage,accepted),"accepted history still advances only once")
 end
 -- These guards were already required for approach geometry; contact must
 -- not turn malformed exact hub/radius facts into a guessed lever.
 local samples=samples_at(.004)
 local wrong_radius=M.copy(samples);wrong_radius[1].wheel_radius+=.001
 local radius_refusal=Stage.new():preview(h,body,wheels,wrong_radius,controls)
 check(not radius_refusal.valid and radius_refusal.issue=="landing_geometry_unavailable",
  "contact preserves the exact authored-radius validation")
 local wrong_plane=M.copy(samples);wrong_plane[1].wheel_center[2]+=.001
 local plane_refusal=Stage.new():preview(h,body,wheels,wrong_plane,controls)
 check(not plane_refusal.valid and plane_refusal.issue=="landing_geometry_unavailable",
  "contact preserves the exact hub-plane-gap validation")
 local unavailable=M.copy(samples);unavailable[1].forecast_geometry_unavailable=true
 local forecast_refusal=Stage.new():preview(h,body,wheels,unavailable,controls)
 check(not forecast_refusal.valid and forecast_refusal.issue=="landing_geometry_unavailable",
  "unavailable forecast geometry never substitutes a measured point")
end
function Tests.run()
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    local function case(run) cases+=1;run() end
    case(function()
        local axle=G.front_axle_at(G,0)
        check(axle~=G.front_axle and near(axle,G.front_axle,0),"neutral axle is exact and detached")
        axle[1]=123
        check(G.front_axle[1]==0,"query preparation cannot mutate fitted anchors")
        check(G.wheel_radius==Forces.wheel_radius and G.wheelbase==Forces.tuning().wheelbase,
            "rendered and physical nominal dimensions remain identical")
        check(math.abs(G.front_axle[3]-G.rear_axle[3]-G.wheelbase)<1e-12,
            "fitted neutral wheelbase is retained")
        local neutral_only={front_axle={1,2,3}}
        check(near(G.front_axle_at(neutral_only,0),neutral_only.front_axle,0),
            "existing neutral-only geometry snapshots retain their path")
        check(G.front_axle_at(neutral_only,.1)==nil,"nonzero steering requires its actual pivot and axis")
        check(G.front_axle_at(G,0/0)==nil and G.front_axle_at(G,math.huge)==nil
            and G.front_axle_at(G,1.01)==nil,"unknown/out-of-policy steering refuses")
        local zero_axis={front_axle=G.front_axle,steering_pivot=G.steering_pivot,steering_axis={0,0,0}}
        check(G.front_axle_at(zero_axis,.1)==nil,"a zero steering axis does not invent a frame")
    end)
    case(function()
        local root={14,3,-21}
        for _,q in ipairs({{0,0,0,1},{0,.6,0,.8}}) do
            for _,steer in ipairs({0,.4,-.4}) do
                local pose=Visual.neutral();pose.steer=steer
                pose.front_wheel_phase=.73;pose.rear_wheel_phase=-.28
                local matrices=Visual.matrices(root,q,pose)
                local front=G.front_axle_at(G,steer)
                local expected=M.add(root,M.turn(q,front))
                check(near(apply(matrices[4],{0,0,0}),expected,1e-11),
                    "front hub equals the real visual's steered hub in the same frame")
                check(near(apply(matrices[3],{0,0,0}),M.add(root,M.turn(q,G.rear_axle)),1e-11),
                    "rear hub stays unchanged by front steering and wheel spin")
            end
        end
        -- The game smooths position apart from rotation between ticks, so a spinning part's
        -- position must not move as it spins, or it leaves its axle on screen.
        local still={}
        for spin=0,6 do
            local pose=Visual.neutral()
            pose.front_wheel_phase=spin*.5;pose.rear_wheel_phase=-spin*.5;pose.crank_phase=spin*.2
            local matrices=Visual.matrices(root,{0,.6,0,.8},pose)
            for part=3,5 do
                local at={matrices[part][13],matrices[part][14],matrices[part][15]}
                still[part]=still[part] or at
                check(near(at,still[part],1e-11),"a spinning part's position does not move as it spins")
            end
        end
        local left,right=G.front_axle_at(G,.4),G.front_axle_at(G,-.4)
        check(left[1]>.015 and right[1]<-.015,"the fitted fork offset is not silently discarded")
        check(math.abs(left[1]+right[1])<1e-12 and math.abs(left[2]-right[2])<1e-12
            and math.abs(left[3]-right[3])<1e-12,"opposite steer is symmetric about the fitted plane")
    end)
    case(function()
        local f=Fixtures.fixture({no_tricks=true})
        local old_sample=f.sample
        function f.sample()
            local row=old_sample()
            row.position=vector.create(4,3,-2);row.rotation={0,.6,0,.8}
            return row
        end
        f.plans={}
        f.on_probe=function(epoch,rays,settings)
            check(epoch==f.read.epoch and #rays==2 and settings.require_contact and settings.exclude_local_actor,
                "actual Ride keeps the same exact epoch, two rays and query guards")
            f.plans[#f.plans+1]=rays
            return {status="available",epoch=epoch,rays={},local_actor_excluded=true,owned_bodies_excluded=true}
        end
        local first=f.observe()
        check(first.submitted==1 and first.presentation_pose.steer==0,"first accepted pose is neutral")
        f.pad.left_x=-1;f.mode="applied";f.advance()
        local accepted=f.observe()
        check(accepted.submitted==2 and accepted.presentation_pose.steer~=0,
            "actual Mapping/Forces publish a fresh accepted steering pose")
        local previous=accepted.presentation_pose
        f.pad.left_x=1;f.advance();f.successor=f.sample()
        f.on_submit=function() return false,"constructed refusal" end
        local refused=f.observe()
        check(refused.stop_requested and refused.presentation_pose==previous,
            "current refused input cannot replace the accepted pose")
        local rays=f.plans[3]
        local p=f.read.position
        local center={p.x,p.y,p.z}
        local front=M.add(center,M.turn(f.read.rotation,M.sub(G.front_axle_at(G,previous.steer),G.com)))
        local rear=M.add(center,M.turn(f.read.rotation,M.sub(G.rear_axle,G.com)))
        local front_native=vector.create(front[1],front[2],front[3])
        local rear_native=vector.create(rear[1],rear[2],rear[3])
        check(rays[1].from==front_native and rays[2].from==rear_native,
            "query starts use the previous accepted hub in the actual fresh body frame")
        local unsteered=M.add(center,M.turn(f.read.rotation,M.sub(G.front_axle,G.com)))
        check(not near(front,unsteered,1e-5),"the regression exercises a real offset, not a neutral-only case")
        local root=M.sub(center,M.turn(f.read.rotation,G.com))
        local matrices=Visual.matrices(root,f.read.rotation,previous)
        check(near(apply(matrices[4],{0,0,0}),front,1e-11),
            "query and drawn front hub agree after the same body/source transform")
    end)
    case(function() floor_geometry_case(check) end)
    case(function() -- A wheel lifted onto a kerb is drawn by pitching and lifting the whole bike, and the rider goes with it.
        check(select("#",G.hub_rise(G,0,0))==2 and G.hub_rise(G,0,0)==0 and select(2,G.hub_rise(G,0,0))==0,
            "no pitch and no lift raise neither hub")
        local root,q={14,3,-21},{0,.6,0,.8}
        local function local_point(p) return M.turn({-q[1],-q[2],-q[3],q[4]},M.sub(p,root)) end
        for _,want in ipairs({{.14,0},{0,.14},{.05,.05},{.23,0},{.1,.03}}) do
            local pitch,lift=G.pitch_lift(G,want[1],want[2])
            local front,rear=G.hub_rise(G,pitch,lift)
            check(math.abs(front-want[1])<1e-12 and math.abs(rear-want[2])<1e-12,"pitch_lift is hub_rise turned round")
            check(want[1]>want[2] and pitch<0 or want[1]<want[2] and pitch>0 or math.abs(pitch)<1e-12,
                "a front wheel lifted higher draws the nose up, which bike_visual turns as a negative pitch")
            local pose=Visual.neutral();pose.steer=.1;pose.crank_phase=.4
            pose.movement_bike_pitch,pose.movement_bike_lift=pitch,lift
            check(Visual.valid_pose(pose),"a lifted pose is one the visual draws")
            local m=Visual.matrices(root,q,pose)
            local drawn_front,drawn_rear=local_point(apply(m[4],{0,0,0})),local_point(apply(m[3],{0,0,0}))
            check(math.abs(drawn_front[2]-G.front_axle_at(G,.1)[2]-want[1])<.0005
                and math.abs(drawn_rear[2]-G.rear_axle[2]-want[2])<1e-9,
                "bike_visual draws each hub that far up along the bike's own up")
            -- The rider's hands and feet are solved on the bars and pedals as they are drawn.
            local plan,why=MP.compose({bike={root=root,rotation=q},
                articulation={steer=.1,crank_phase=.4,movement_bike_pitch=pitch,movement_bike_lift=lift}})
            check(plan~=nil,"a lifted bike composes a mounted pose: "..tostring(why))
            for i,grip in ipairs({G.left_grip,G.right_grip}) do
                check(near(plan.targets.grips[i],apply(m[6],grip),1e-12),"each hand holds its grip where the bars are drawn")
                check(near(plan.targets.spindles[i],apply(m[6+i],G.pedals[i]),1e-12),"each foot stands where its pedal is drawn")
            end
        end
        -- Lifted straight up, the pelvis follows .75 of the bars and the saddle all of it: the legs take the rest.
        local rest=MP.compose({bike={root=root,rotation=q},articulation={crank_phase=.4}})
        local up=MP.compose({bike={root=root,rotation=q},articulation={crank_phase=.4,movement_bike_lift=.1}})
        check(math.abs(local_point(up.targets.hips)[2]-local_point(rest.targets.hips)[2]-.075)<1e-9,
            "the hips rise .75 of a lift")
        check(math.abs(up.diagnostics.hip_above_seat-rest.diagnostics.hip_above_seat+.025)<1e-9,
            "and sit the other quarter lower on a saddle drawn lifted with the bike")
        -- The Poser's memo keys only the steer and the cranks, so a lifted bike is composed in full each tick.
        local poser=MP.new({skater={pose=function(_,weight)
            if weight==MP.PROBE_WEIGHT then error("place has a position, a rotation or both",0) end
            return true
        end}})
        check(poser:mount(0).ok==true,"a constructed skater.pose mounts")
        local function ticked(now,lift)
            local r=poser:tick(now,{bike={root=root,rotation=q},articulation={crank_phase=.4,movement_bike_lift=lift}})
            check(r.sent==true,"the poser sends: "..tostring(r.reason))
            return r.plan
        end
        check(ticked(.1,nil).memoized==true,"ordinary riding is memoized")
        for i,lift in ipairs({.1,.15}) do
            local sent=ticked(.1+i*.1,lift)
            local full=MP.compose({bike={root=root,rotation=q},articulation={crank_phase=.4,movement_bike_lift=lift}})
            check(sent.memoized~=true and near(sent.targets.grips[1],full.targets.grips[1],1e-12)
                and near(sent.targets.ankles[2],full.targets.ankles[2],1e-12),"a lifted bike is composed in full, at its own lift")
        end
        check(Visual.valid_pose(Visual.neutral()) and Visual.neutral().movement_bike_lift==0,"the neutral pose has no lift")
        local wild=Visual.neutral();wild.movement_bike_lift=.6
        check(not Visual.valid_pose(wild) and MP.compose({bike={root=root,rotation=q},
            articulation={crank_phase=0,movement_bike_lift=.6}})==nil,"neither draws a lift of more than half a metre")
    end)
    case(function() -- The bike drawn up onto a kerb turns about the wheel left on the road, which stays where the physics has it.
        local root,q={14,3,-21},{0,.6,0,.8}
        local inverse={-q[1],-q[2],-q[3],q[4]}
        local function local_point(p) return M.turn(inverse,M.sub(p,root)) end
        local R=G.wheel_radius
        local down=M.turn(q,{0,-1,0})
        -- Where a drawn tyre touches flat ground under the body: the point of its circle furthest along the body's down.
        local function contact(m)
            local axle=M.unit({m[1],m[2],m[3]})
            local toward=M.unit(M.sub(down,M.mul(axle,M.dot(down,axle))))
            return local_point(M.add(apply(m,{0,0,0}),M.mul(toward,R)))
        end
        -- A world point in a drawn part's own frame, which is the bike's frame for every part without its own origin.
        local function in_part(m,p)
            local d=M.sub(p,{m[13],m[14],m[15]})
            return {d[1]*m[1]+d[2]*m[2]+d[3]*m[3],d[1]*m[5]+d[2]*m[6]+d[3]*m[7],d[1]*m[9]+d[2]*m[10]+d[3]*m[11]}
        end
        local reached=0
        for _,steer in ipairs({0,.1,-.3}) do
            local rest=Visual.neutral();rest.steer=steer;rest.crank_phase=.4
            local on_body=Visual.matrices(root,q,rest)
            local rest_plan=MP.compose({bike={root=root,rotation=q},articulation={steer=steer,crank_phase=.4}})
            for _,want in ipairs({{.14,0},{0,.14},{.23,0},{0,.23},{.1,.03},{.03,.1},{.05,.05}}) do
                check(select("#",G.pitch_lift(G,want[1],want[2]))==3,"pitch_lift gives a pitch, a lift and a shift")
                local pitch,lift,shift=G.pitch_lift(G,want[1],want[2])
                check(math.abs(shift)<.15,"the shift is no more than the pitch carried the grounded hub: "..shift)
                local pose=table.clone(rest)
                pose.movement_bike_pitch,pose.movement_bike_lift,pose.movement_bike_shift=pitch,lift,shift
                check(Visual.valid_pose(pose),"a shifted pose is one the visual draws")
                local m=Visual.matrices(root,q,pose)
                -- Part 4 is the front wheel and part 3 the rear; the one less raised is the one on the road.
                local low,high=3,4
                if want[1]<want[2] then low,high=4,3 end
                local low_rise,high_rise=want[high==4 and 2 or 1],want[high==4 and 1 or 2]
                local hub=M.sub(local_point(apply(m[low],{0,0,0})),local_point(apply(on_body[low],{0,0,0})))
                check(near(hub,{0,low_rise,0},.001),
                    string.format("the hub on the road is drawn within 1 mm of the body's: %.4f %.4f %.4f",hub[1],hub[2]-low_rise,hub[3]))
                -- Steered hard, the front tyre leans with the head tube, and pitching that leaning disc moves its
                -- lowest point across: 2 cm at .3 rad and the most Ride draws, with the hub still in place.
                local grounded=M.sub(contact(m[low]),contact(on_body[low]))
                check(near(grounded,{0,low_rise,0},math.abs(steer)<=.1 and .01 or .02),
                    string.format("and its tyre touches the road within 1 cm of where the body has it: %.4f %.4f %.4f",
                        grounded[1],grounded[2]-low_rise,grounded[3]))
                local raised=M.sub(contact(m[high]),contact(on_body[high]))
                check(math.abs(raised[2]-high_rise)<.002,
                    string.format("the raised wheel sits on the surface its ray measured: %.4f off",raised[2]-high_rise))
                -- A rigid wheelbase seen from above is shorter by the climb, so the raised wheel comes in toward the
                -- other one by that much: 3 cm at the most Ride draws.
                local inward=(high==4 and -1 or 1)*raised[3]
                local span=G.front_axle[3]-G.rear_axle[3]
                local shorter=span-math.sqrt(span*span-(high_rise-low_rise)^2)
                check(math.abs(inward-shorter)<(steer==0 and 1e-6 or .005) and math.abs(raised[1])<(steer==0 and 1e-9 or .02),
                    string.format("and comes in %.4f toward the other wheel, as a %.4f climb shortens the wheelbase, and %.4f across",
                        inward,shorter,raised[1]))
                -- The rider's hands and feet stay on the bars and pedals as they are drawn, and reach them.
                local plan,why=MP.compose({bike={root=root,rotation=q},
                    articulation={steer=steer,crank_phase=.4,movement_bike_pitch=pitch,movement_bike_lift=lift,movement_bike_shift=shift}})
                check(plan~=nil,"a shifted bike composes a mounted pose: "..tostring(why))
                for i,grip in ipairs({G.left_grip,G.right_grip}) do
                    check(near(plan.targets.grips[i],apply(m[6],grip),1e-12),"each hand holds its grip where the bars are drawn")
                    check(near(plan.targets.spindles[i],apply(m[6+i],G.pedals[i]),1e-12),"each foot stands where its pedal is drawn")
                    check(near(in_part(m[6],plan.targets.wrists[i]),in_part(on_body[6],rest_plan.targets.wrists[i]),1e-9),
                        "each wrist sits on the drawn bars as it does on the bike at rest")
                    check(near(in_part(m[6+i],plan.targets.ankles[i]),in_part(on_body[6+i],rest_plan.targets.ankles[i]),1e-9),
                        "each ankle sits on its drawn pedal as it does on the bike at rest")
                end
                -- Every limb reaches. The one exception is the rear wheel drawn 23 cm up with the bars turned .3 rad,
                -- where the saddle holds the hips back and the leading arm ends within a centimetre of its grip.
                for _,name in ipairs({"left_arm","right_arm","left_leg","right_leg"}) do
                    local limb=plan.diagnostics.limbs[name]
                    check(rest_plan.diagnostics.limbs[name].reaches,"the "..name.." reaches its part on the bike at rest")
                    check(limb.reaches or math.abs(steer)>.1 and limb.requested-limb.limit<.01,
                        string.format("the %s reaches its drawn part: %.4f of %.4f",name,limb.requested,limb.limit))
                    if limb.reaches then reached+=1 end
                end
            end
        end
        check(reached>=83,"all but one limb in 84 reach: "..reached)
        -- The Poser composes a shifted bike in full: its memo is only for a bike drawn on its body.
        local poser=MP.new({skater={pose=function(_,weight)
            if weight==MP.PROBE_WEIGHT then error("place has a position, a rotation or both",0) end
            return true
        end}})
        check(poser:mount(0).ok==true,"a constructed skater.pose mounts")
        check(poser:tick(.1,{bike={root=root,rotation=q},articulation={crank_phase=.4}}).plan.memoized==true,
            "ordinary riding is memoized")
        local shifted={bike={root=root,rotation=q},articulation={crank_phase=.4,movement_bike_shift=-.08}}
        local sent=poser:tick(.2,shifted).plan
        local full=MP.compose(shifted)
        check(sent.memoized~=true and near(sent.targets.grips[1],full.targets.grips[1],1e-12)
            and near(sent.targets.ankles[2],full.targets.ankles[2],1e-12),"a shifted bike is composed in full, at its own shift")
        local still=MP.compose({bike={root=root,rotation=q},articulation={crank_phase=.4}})
        check(near(M.sub(local_point(full.targets.grips[1]),local_point(still.targets.grips[1])),{0,0,-.08},1e-12),
            "a shift moves the bars along the bike's forward")
        -- As with a lift, the pelvis follows .75 of the bars and the saddle all of it.
        check(math.abs(local_point(full.targets.hips)[3]-local_point(still.targets.hips)[3]+.06)<1e-9,"the hips go .75 of a shift")
        check(math.abs(full.diagnostics.hip_seat[3]-still.diagnostics.hip_seat[3]-.02)<1e-9,
            "and sit the other quarter forward on a saddle drawn shifted with the bike")
        check(Visual.neutral().movement_bike_shift==0,"the neutral pose has no shift")
        local wild=Visual.neutral();wild.movement_bike_shift=.3
        check(not Visual.valid_pose(wild) and MP.compose({bike={root=root,rotation=q},
            articulation={crank_phase=0,movement_bike_shift=.3}})==nil,"neither draws a shift of more than a quarter metre")
    end)
    return {cases=cases,assertions=assertions}
end
return Tests
-- Constructed geometry and actual Ride query plumbing only; no native or
-- landing/support/steering-joint qualification. This fixture is authored UNRUN.
local G=require("./bike_geometry")
local M=require("./force_math")
local Forces=require("./forces")
local Stage=require("./force_stage")
local Visual=require("./bike_visual")
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
    return {cases=cases,assertions=assertions}
end
return Tests
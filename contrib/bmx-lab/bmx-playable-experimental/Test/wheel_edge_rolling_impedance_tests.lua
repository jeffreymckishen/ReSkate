-- NEW corrected rolling fixture. The original failed zero-rotor fixture is
-- preserved separately and is not relabelled by this module.
local Forces=require("./forces")
local Stage=require("./force_stage")
local Contact=require("./contact_runtime")
local InFlight=require("./ride_inflight")
local M=require("./force_math")
local G=require("./bike_geometry")
local T={}
function T.run()
 local n=0
 local function check(ok,why)n+=1;assert(ok,why)end
 local r,h,speed=G.wheel_radius,Forces.native_seconds,2
 local gravity=Forces.tuning().gravity
 local extent=math.min(.04,r*.15)
 local feature={wheel=1,top_point={0,.12,0},top_normal={0,1,0},top_velocity={0,0,0},
  wall_point={0,.06,0},wall_normal={0,0,-1},wall_velocity={0,0,0},
  lower_point={0,0,-.3},lower_normal={0,1,0},lower_velocity={0,0,0},
  up={0,1,0},anchor={0,.12,0},extent=extent,edge_height=.12,wall_below=.04,topology_known=false,
  top_witness={point={0,.12,extent},normal={0,1,0},surface_velocity={0,0,0}},
  wall_witness={point={0,.08,0},normal={0,0,-1},surface_velocity={0,0,0}},
  outside_witness={point={0,0,-extent},normal={0,1,0},surface_velocity={0,0,0}}}
 local function fixture(folded_gap)
  local body,wheels=Forces.proposed_body(),Forces.proposed_wheels()
  body.linear_velocity={0,0,speed}
  for _,wheel in ipairs(wheels)do wheel.angular_speed=speed/wheel.radius end
  -- With no pending command, fold advances v by gravity*h, then position
  -- by that velocity*h. Solve the initial hub for the DESIRED folded gap.
  -- This includes horizontal travel, not only the initial radial distance.
  local future_y=r+gravity[2]*h*h
  local future_dy=future_y-.12
  local future_dz=math.sqrt((r+folded_gap)^2-future_dy^2)
  local initial_front={0,r,-future_dz-speed*h}
  body.center_of_mass=M.sub(initial_front,M.sub(G.front_axle,G.com))
  local samples={}
  for i,axle in ipairs({G.front_axle,G.rear_axle})do
   local hub=M.add(body.center_of_mass,M.sub(axle,G.com))
   samples[i]={contact={status="hit",point={hub[1],0,hub[3]},normal={0,1,0},forward={0,0,1},
    surface_velocity={0,0,0}},separation=hub[2]-r,wheel_center=hub,wheel_radius=r,
    verified_plane=false,balance_normal_available=false}
  end
  samples[1].edge=assert(Contact.edge_sample(initial_front,r,feature,{0,0,1}))
  return body,wheels,samples
 end
 local last_forecast,last_wheels,last_folded
 for _,desired_gap in ipairs({.01,0})do
  local body,wheels,samples=fixture(desired_gap)
  check(math.abs(wheels[1].angular_speed*r-speed)<1e-10 and math.abs(wheels[2].angular_speed*r-speed)<1e-10,
   "both rotors begin in the same rolling2m/s state as the chassis")
  local forecast,folded=InFlight.fold(h,gravity,{},body,samples)
  check(forecast~=nil,"current geometry survives the existing accepted-command forecast")
  local edge=folded[1].edge
  check(edge and edge.kind=="edge" and edge.contact.status=="hit" and edge.contact.normal[2]<.95,
   "corrected fixture reaches the validated non-floor radial constraint")
  check(math.abs(edge.separation-desired_gap)<1e-8,"edge gap is constructed at the actual folded pose")
  check(math.abs(forecast.linear_velocity[3]-speed)<1e-10,"the forecast preserves actual horizontal entry speed")
  if desired_gap>0 then
   check(edge.separation>.005 and not Forces.eligible_support(forecast,edge,.005,.10),
    "the intended positive-gap case is still separated after forecasting")
  end
  local normal=M.copy(edge.contact.normal)
  local out=Stage.new():preview(h,forecast,wheels,folded,{pedal=.25,steer=0,brake=0})
  if not out.valid then
   local model=out.diagnostic or out
   print(string.format("corrected_rolling_refusal desired_gap=%.9g actual_gap=%.9g issue=%s rotor_in=(%.9g,%.9g) F=%.9g T=%.9g softness=%s",
    desired_gap,edge.separation,tostring(out.issue),wheels[1].angular_speed,wheels[2].angular_speed,
    M.length(model.force),M.length(model.torque),tostring(model.edge_normal_softness and model.edge_normal_softness[1])))
  end
  check(out.valid,"corrected rolling material packet refused: "..tostring(out.issue))
  check(out.edge_normal_softness[1]>0 and M.finite(out.edge_normal_softness[1]),
   "validated static non-floor constraint uses the existing finite impedance")
  check(M.length(out.force)<=6000 and M.length(out.torque)<=2000,
   "rolling material response retains the same authored force and torque caps")
  check(M.length(M.sub(edge.contact.normal,normal))==0,"material policy preserves the actual derived normal")
  if desired_gap>0 then
   check(out.edge_normal_load[1]==0 and out.edge_approach_impulse[1]>0,
    "normal-only anticipation may act without an eligible supporting load")
  else
   check(out.edge_normal_impulse[1]>0,"the actual current-contact case has a unilateral edge impulse")
  end
  last_forecast,last_wheels,last_folded=forecast,wheels,folded
 end
 local policy=Forces.controls({pedal=.25,contact_compliance_available=false,landing_contact_compliance_selected=false})
 local rigid=Forces.new():preview(h,last_forecast,last_wheels,last_folded,policy)
 check(rigid.valid and rigid.edge_normal_softness[1]==0,"unselected material policy remains unchanged")
 local forged=M.copy(last_folded);forged[1].edge.edge_feature.wall_witness=nil
 local refused=Stage.new():preview(h,last_forecast,last_wheels,forged,{pedal=.25,steer=0,brake=0})
 check(not refused.valid and refused.issue=="edge_geometry_unavailable",
  "unknown wall proof cannot enter the material path")
 return {cases=3,assertions=n,native_qualified=false}
end
return T
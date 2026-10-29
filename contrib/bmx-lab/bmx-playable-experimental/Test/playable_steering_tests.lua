local Stage=require("./force_stage")
local Forces=require("./forces")
local World=require("./sim_world")
local M=require("./force_math")
local T={}
function T.run()
 local n=0
 local function check(ok,why)n+=1;assert(ok,why)end
 local stage=Stage.new()
 local recorded=Forces.proposed_body()
 recorded.linear_velocity={-.13,0,3.04};recorded.angular_velocity={.04,.95,-.20}
 check(stage:admit_measured(recorded),"recorded human turning sample must stay admitted")
 local invalid=Forces.proposed_body();invalid.linear_velocity={0,0,13}
 check(not stage:admit_measured(invalid),"bounded overspeed stop remains")
 invalid.linear_velocity={0,7,0}
 check(not stage:admit_measured(invalid),"vertical stop remains unchanged")
 local terrain=World.terrain.flat()
 local body,wheels=World.place(terrain,{speed=2.9})
 local start=M.copy(body.center_of_mass)
 local maximum_speed,maximum_tilt,maximum_roll,maximum_distance=0,0,0,0
 for step=1,1800 do
  check(stage:admit_measured(body),"normal measured steering rejected at step"..step)
  local samples=World.contacts(terrain,body,Forces.tuning().gravity)
  local steer=step<=120 and 0 or (math.floor((step-121)/60)%2==0 and 1 or -1)
  local out,candidate=stage:preview(Forces.native_seconds,body,wheels,samples,{pedal=1,steer=steer,brake=0})
  check(out.valid,"turning force refused at step"..step..":"..tostring(out.issue))
  stage:_adopt(candidate)
  body=World.integrate(body,out,Forces.tuning().gravity,Forces.native_seconds);wheels=out.wheels
  local q=M.normalized(body.orientation)
  local up=M.turn(q,{0,1,0});local forward=M.turn(q,{0,0,1})
  local tilt=math.deg(math.acos(math.clamp(up[2],-1,1)))
  local roll=math.abs(M.dot(body.angular_velocity,forward))
  maximum_speed=math.max(maximum_speed,math.sqrt(body.linear_velocity[1]^2+body.linear_velocity[3]^2))
  maximum_tilt=math.max(maximum_tilt,tilt);maximum_roll=math.max(maximum_roll,roll)
  maximum_distance=math.max(maximum_distance,M.length(M.sub(body.center_of_mass,start)))
  check(tilt<55 and roll<8 and maximum_distance<512,"playable measured envelope exceeded")
 end
 check(maximum_speed>3.04,"replay crosses the original failure speed")
 check(maximum_distance>8.5,"replay leaves the original tiny spawn envelope")
 print(string.format("steering_replay steps=1800 max_speed=%.6f max_tilt=%.6f max_roll=%.6f max_distance=%.6f",maximum_speed,maximum_tilt,maximum_roll,maximum_distance))
 check(maximum_speed<8,"governor must bound repeated steering speed")
 -- First establish actual accepted wheel support, then roll the front tyre
 -- onto an 8.5 mm road step while turning at the recorded failure velocity.
 local road_stage=Stage.new()
 local road_body,road_wheels=World.place(terrain,{speed=4.04})
 local seed,seed_candidate=road_stage:preview(Forces.native_seconds,road_body,road_wheels,
  World.contacts(terrain,road_body,Forces.tuning().gravity),{pedal=0,steer=0,brake=0})
 check(seed.valid and seed.normal_load[1]>0 and seed.normal_load[2]>0,"road-step fixture needs accepted support")
 check(seed.compliant_normal_mask~=0,"unsupported first touchdown retains landing compliance")
 road_stage:_adopt(seed_candidate)
 road_body=World.integrate(road_body,seed,Forces.tuning().gravity,Forces.native_seconds);road_wheels=seed.wheels
 road_body.linear_velocity={.89,-.01,4.04};road_body.angular_velocity={.02,-.88,.06}
 local hubs=World.hubs(road_body)
 local edge=(hubs[1][3]+hubs[2][3])/2
 local road={height=function(z)return z>=edge and .0084716 or 0 end,slope=function()return 0 end}
 local road_samples=World.contacts(road,road_body,Forces.tuning().gravity)
 check(road_samples[1].contact.status=="hit" and road_samples[1].separation<-.008
  and road_samples[1].separation>-.015,"small front road step is within the old landing allowance")
 local crossing,crossing_candidate=road_stage:preview(Forces.native_seconds,road_body,road_wheels,road_samples,
  {pedal=1,steer=-1,brake=0})
 check(crossing.valid,"supported road step must recover instead of stopping: "..tostring(crossing.issue))
 check(crossing.grounded and crossing.normal_load[1]>0,"road step produces real supporting normal response")
 check(crossing.compliant_normal_mask==0,"supported rolling does not re-enter the landing-only deflection law")
 check(M.length(crossing.force)<=6000 and M.length(crossing.torque)<=2000,"road response retains native force and torque caps")
 road_stage:_adopt(crossing_candidate)
 return{cases=6,assertions=n,native_qualified=false}
end
return T
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
 -- R11: a hop arrives on a raised front lip while the rear wheel is still
 -- 454 mm above the lower floor. Preserve the measured -3.34 m/s descent.
 local impact_stage=Stage.new()
 local impact_body,impact_wheels=World.place(terrain,{speed=2.5336})
 impact_body.orientation={0,-.13937808573246002,0,.9902393221855164}
 impact_body.center_of_mass[2]+=.45448318504373963
 impact_body.linear_velocity={-.6993664503097534,-3.34,2.435194253921509}
 impact_body.angular_velocity={-2.590921758383047E-05,-2.343758524148143E-06,6.673593452433124E-05}
 for _,wheel in ipairs(impact_wheels)do wheel.angular_speed=9.630650616204395 end
 local impact_hubs=World.hubs(impact_body)
 local lip_edge=(impact_hubs[1][3]+impact_hubs[2][3])/2
 local lip={height=function(z)return z>=lip_edge and .4592097053437958 or 0 end,slope=function()return 0 end}
 -- World.contacts uses its ordinary 0.15 m ray margin. This hop stage actually
 -- queries 0.75 m below each tyre, which is why R11 also saw the rear floor.
 check(impact_stage.tuning.wheel_probe_extra==.75,"fixture uses the actual hop query range")
 local function impact_contacts(body,support_planes)
  local samples={};local forward=M.turn(M.normalized(body.orientation),{0,0,1})
  for i,hub in ipairs(World.hubs(body))do
   local query_terrain=lip
   if support_planes then
    local height=support_planes[i]
    query_terrain={height=function()return height end,slope=function()return 0 end}
   end
   local status,point,normal=World.ray(query_terrain,hub,World.wheel_radius+impact_stage.tuning.wheel_probe_extra)
   local basis=status=="hit" and M.basis(normal,forward)
   if basis then
    samples[i]={contact={status="hit",point=point,normal=basis.normal,forward=basis.forward,surface_velocity={0,0,0}},
     separation=M.dot(M.sub(hub,point),basis.normal)-World.wheel_radius,
     wheel_center=M.copy(hub),wheel_radius=World.wheel_radius,verified_plane=false,balance_normal_available=false}
   else samples[i]={contact={status=status=="clear" and "clear" or "unavailable"}}end
  end
  return samples
 end
 local first_samples=impact_contacts(impact_body)
 check(first_samples[1].contact.status=="hit" and first_samples[2].contact.status=="hit"
  and math.abs(first_samples[1].separation+.004726520300056158)<1e-6
  and math.abs(first_samples[2].separation-.45448318504373963)<1e-6,"recorded one-wheel touchdown geometry")
 local recorded_body,recorded_wheels=M.copy(impact_body),M.copy(impact_wheels)
 local first_impulse,total_impulse,final_closing=0,0,0
 -- The heightfield has no vertical-face response. Preserve its honest query
 -- failure once the rear hub enters the raised ledge; this is not a climb test.
 local query_refused=false
 for step=1,8 do
  local samples=impact_contacts(impact_body)
  local closing=-M.dot(M.point_velocity(impact_body,World.hubs(impact_body)[1]),{0,1,0})
  check(samples[1].contact.status=="hit" and samples[1].separation>=-.10,"observed front impact stays bounded at step"..step)
  local out,candidate=impact_stage:preview(Forces.native_seconds,impact_body,impact_wheels,samples,{pedal=0,steer=0,brake=0})
  local trace=string.format("step=%d gap=%s closing=%.6f recovery=%s impulse=%s rear=%s issue=%s",step,
   tostring(samples[1].separation),closing,tostring(out.landing_recovery_mask),
   tostring(out.normal_impulse and out.normal_impulse[1]),samples[2].contact.status,tostring(out.issue))
  print("ledge touchdown "..trace)
  if step==8 then
   check(samples[2].contact.status=="unavailable" and not out.valid and out.issue=="unavailable_contact",
    "unmodelled ledge face must remain an honest query refusal: "..trace)
   query_refused=true
   break
  end
  check(out.valid,"first seven observed impact steps must absorb: "..trace)
  check(out.normal_impulse[1]>=0 and M.length(out.force)<=6000 and M.length(out.torque)<=2000,"observed impact remains unilateral and capped: "..trace)
  if step==1 then
   first_impulse=out.normal_impulse[1]
   check(out.grounded and first_impulse>0,"recorded touchdown receives real support")
   check(out.landing_recovery_mask==1,"rear approach ray must not arm impact recovery")
  end
  total_impulse+=out.normal_impulse[1]
  impact_stage:_adopt(candidate)
  impact_body=World.integrate(impact_body,out,Forces.tuning().gravity,Forces.native_seconds);impact_wheels=out.wheels
  final_closing=-M.dot(M.point_velocity(impact_body,World.hubs(impact_body)[1]),{0,1,0})
 end
 check(query_refused and first_impulse>0 and total_impulse>=first_impulse and final_closing<1,"bounded front recovery precedes the separate ledge query refusal")
 -- Component fixture: each wheel retains its explicitly observed stationary
 -- plane. This tests complete contact-law recovery, not a full ledge climb or
 -- the native world's collision geometry. No unavailable result is replaced.
 local support_planes={.4592097053437958,0}
 impact_stage=Stage.new();impact_body=M.copy(recorded_body);impact_wheels=M.copy(recorded_wheels)
 local opening_recovery,released_recovery=false,false
 for step=1,32 do
  local samples=impact_contacts(impact_body,support_planes)
  check(samples[1].contact.status~="unavailable" and samples[2].contact.status~="unavailable","stationary planes provide complete current observations")
  local closing=-M.dot(M.point_velocity(impact_body,World.hubs(impact_body)[1]),{0,1,0})
  check(samples[1].contact.status=="clear" or samples[1].separation>=-.10,"plane fixture stays inside original gross penetration")
  local out,candidate=impact_stage:preview(Forces.native_seconds,impact_body,impact_wheels,samples,{pedal=0,steer=0,brake=0})
  local trace=string.format("step=%d gap=%s closing=%.6f recovery=%s impulse=%s grounded=%s issue=%s",step,
   tostring(samples[1].separation),closing,tostring(out.landing_recovery_mask),
   tostring(out.normal_impulse and out.normal_impulse[1]),tostring(out.grounded),tostring(out.issue))
  if step<=8 or not out.valid then print("plane touchdown "..trace)end
  check(out.valid,"fully observed impact recovery must produce a bounded packet: "..trace)
  check(out.normal_impulse[1]>=0 and M.length(out.force)<=6000 and M.length(out.torque)<=2000,"plane response remains unilateral and capped: "..trace)
  if step==2 and closing>.4 then check(bit32.band(out.compliant_normal_mask,1)~=0,"fast impact remains compliant")end
  if samples[1].contact.status=="hit" and samples[1].separation<-.015 then
   check(bit32.band(out.landing_recovery_mask,1)~=0,"deep impact keeps its admitted envelope: "..trace)
   if closing<0 then opening_recovery=true end
  end
  if not Forces.eligible_support(impact_body,samples[1],.005,.10)
   and not Forces.eligible_support(impact_body,samples[2],.005,.10) then
   check(not out.grounded,"recovery history must not invent loaded support: "..trace)
  end
  local recovered=step>1 and out.landing_recovery_mask==0 and
   (samples[1].contact.status=="clear" or samples[1].separation>=-.015 and closing<=.4)
  impact_stage:_adopt(candidate)
  impact_body=World.integrate(impact_body,out,Forces.tuning().gravity,Forces.native_seconds);impact_wheels=out.wheels
  if recovered then
   released_recovery=true
   print("plane touchdown recovered "..trace)
   break
  end
 end
 check(opening_recovery and released_recovery,"observed stationary planes recover and release the admitted impact envelope")
 local too_deep=M.copy(impact_body);too_deep.center_of_mass[2]-=.2
 local refused=Stage.new():preview(Forces.native_seconds,too_deep,impact_wheels,
  impact_contacts(too_deep,support_planes),{pedal=0,steer=0,brake=0})
 check(not refused.valid,"gross penetration still refuses instead of being swallowed")
 return{cases=7,assertions=n,native_qualified=false}
end
return T
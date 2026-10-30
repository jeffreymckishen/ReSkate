local Stage=require("./force_stage")
local Forces=require("./forces")
local World=require("./sim_world")
local M=require("./force_math")
local Contact=require("./contact_runtime")
local InFlight=require("./ride_inflight")
local G=require("./bike_geometry")
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
 check(crossing.compliant_normal_mask~=0,"supported rolling retains finite normal compliance across the road step")
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
 -- R12's right-turn sample has long-ray hits but neither wheel eligible for
 -- support. Ground steering is not an authored air-rotation request in Stage.
 local curb_body,curb_wheels=World.place(terrain,{speed=0})
 curb_body.orientation={.1326754093170166,.5308188199996948,-.4389405846595764,.7127130627632141}
 curb_body.linear_velocity={.7513578534126282,-.12699398398399353,-.42990657687187195}
 curb_body.angular_velocity={-1.3182944059371948,-.4027436673641205,-.7296744585037231}
 curb_wheels[1].angular_speed=2.4387068851439575;curb_wheels[2].angular_speed=14.976072191547267
 local gaps={.022167586578274445,.6324604365056077}
 local curb_samples={};local curb_forward=M.turn(M.normalized(curb_body.orientation),{0,0,1})
 for i,hub in ipairs(World.hubs(curb_body))do
  local point={hub[1],hub[2]-World.wheel_radius-gaps[i],hub[3]}
  local basis=M.basis({0,1,0},curb_forward)
  curb_samples[i]={contact={status="hit",point=point,normal=basis.normal,forward=basis.forward,surface_velocity={0,0,0}},
   separation=gaps[i],wheel_center=M.copy(hub),wheel_radius=World.wheel_radius,verified_plane=false,balance_normal_available=false}
 end
 local curb_stage=Stage.new()
 local curb=curb_stage:preview(Forces.native_seconds,curb_body,curb_wheels,curb_samples,{pedal=0,steer=.8000122074037904,brake=0})
 check(curb.valid,"recorded unsupported right-turn sample produces a bounded packet: "..tostring(curb.issue))
 check(not curb.grounded and curb.balance_support_mask==0 and curb.normal_load[1]==0 and curb.normal_load[2]==0,
  "long query hits never invent support")
 check(curb.neutral_air_damping_active and M.length(curb.air_damping_torque)>0 and M.length(curb.air_damping_torque)<=160,
  "unsupported ground steering retains bounded passive angular damping")
 check(M.dot(curb.air_damping_torque,curb_body.angular_velocity)<0,"unsupported damping removes angular energy")
 check(M.length(curb.force)<=6000 and M.length(curb.torque)<=2000,"unsupported correction retains packet caps")
 local air_controls=Forces.controls({steer=.8,air_yaw=.8,rotation_reserved=true,
  contact_compliance_available=true,landing_contact_compliance_selected=true})
 local reserved=Forces.new():preview(Forces.native_seconds,curb_body,curb_wheels,curb_samples,air_controls)
 check(reserved.valid and not reserved.neutral_air_damping_active,"explicit air rotation still suppresses passive damping")
 -- The already-slewed physical joint must not snap to raw steer when its
 -- measured support disappears. These constructed clear rows model a short
 -- support gap; they never grant ground or qualify a native road collision.
 local transition_stage=Stage.new()
 local transition_body,transition_wheels=World.place(terrain,{speed=2})
 local previous_angle=0
 local step_limit=5*Forces.tuning().steer_limit*Forces.native_seconds+1e-8
 local function joint_step(steer,supported,discard_once)
  local samples=supported and World.contacts(terrain,transition_body,Forces.tuning().gravity)
   or {{contact={status="clear"}},{contact={status="clear"}}}
  local controls={pedal=0,steer=steer,brake=0}
  local out,candidate=transition_stage:preview(Forces.native_seconds,transition_body,transition_wheels,samples,controls)
  check(out.valid,"support-transition packet stays bounded: "..tostring(out.issue))
  if discard_once then
   local second,accepted=transition_stage:preview(Forces.native_seconds,transition_body,transition_wheels,samples,controls)
   check(second.valid and math.abs(second.front_steer_angle-out.front_steer_angle)<1e-12,
    "discarded preview cannot advance joint history")
   out,candidate=second,accepted
  end
  check(math.abs(out.front_steer_angle-previous_angle)<=step_limit,
   "joint change remains bounded from the previous accepted step across support transitions")
  check(M.length(out.force)<=6000 and M.length(out.torque)<=2000 and out.contact_scale==1,
   "joint continuity preserves physical packet caps without clipping")
  if not supported then
   check(not out.grounded and out.balance_support_mask==0,"slewed airborne joint never invents support or balance")
  end
  transition_stage:_adopt(candidate)
  previous_angle=out.front_steer_angle
  transition_body=World.integrate(transition_body,out,Forces.tuning().gravity,Forces.native_seconds)
  transition_wheels=out.wheels
  return out
 end
 for _=1,12 do joint_step(0,true,false)end
 for _=1,3 do joint_step(.8,true,false)end
 check(previous_angle<0,"fixture first accepts a nonzero grounded joint angle")
 local lost=joint_step(-.8,false,true)
 check(lost.requested_front_steer_angle>0 and lost.front_steer_angle<0 and
  math.abs(lost.front_steer_angle-lost.requested_front_steer_angle)>1e-4,
  "first lost-support reversal retains the previous joint instead of jumping to the raw target")
 for _=1,2 do joint_step(-.8,false,false)end
 local returned=joint_step(.8,true,true)
 check(returned.grounded and returned.balance_support_mask~=0,
  "current measured contact independently restores eligible support")
 for _=1,7 do joint_step(.8,true,false)end
 -- Only the local wheel-joint scalar is slewed. The independent explicit air
 -- yaw/manual torque channels retain their original requested magnitudes.
 local joint_kernel=Forces.new()
 local joint_body,joint_wheels=Forces.proposed_body(),Forces.proposed_wheels()
 local no_support={{contact={status="clear"}},{contact={status="clear"}}}
 local seed_joint,seed_joint_candidate=joint_kernel:preview(Forces.native_seconds,joint_body,joint_wheels,no_support,Forces.controls())
 check(seed_joint.valid,"constructed air-joint history seed")
 joint_kernel:_adopt(seed_joint_candidate)
 local air_joint=joint_kernel:preview(Forces.native_seconds,joint_body,joint_wheels,no_support,
  Forces.controls({steer=1,air_yaw=.5,manual=.25,rotation_reserved=true,
   contact_compliance_available=true,landing_contact_compliance_selected=true}))
 check(air_joint.valid and math.abs(air_joint.front_steer_angle)<=step_limit and
  math.abs(air_joint.front_steer_angle-air_joint.requested_front_steer_angle)>1e-4,
  "existing joint slew continues with explicit air intent")
 check(math.abs(air_joint.air_control_torque[1]+40)<1e-8 and math.abs(air_joint.air_control_torque[2]+100)<1e-8 and
  math.abs(air_joint.air_control_torque[3])<1e-8 and not air_joint.neutral_air_damping_active,
  "joint continuity neither filters explicit air yaw/manual torque nor adds upright assistance")
 check(not air_joint.grounded and air_joint.balance_support_mask==0 and M.length(air_joint.torque)<=2000,
  "explicit airborne channels preserve support and torque contracts")
 -- A case-local exact segment fixture has finite top, wall and lower-floor
 -- faces. It reports the nearest intersection on the requested segment;
 -- vertical height-at-origin lookup cannot answer the horizontal wall rays.
 -- This geometry has no native collision impulses.
 local curb_stage=Stage.new()
 local curb_body,curb_wheels=World.place(terrain,{speed=1.25})
 local curb_edge=World.hubs(curb_body)[1][3]+.5
 local curb_height=.12
 local previous
 local saw_edge,saw_early,saw_two_patches,fully_crossed=false,false,false,false
 local edge_fixture
 local peak_force,peak_torque,deepest=0,0,0
 local function vec(v)return {v.x,v.y,v.z}end
 local function cast(ray,omit_wall)
  local from,to=vec(ray.from),vec(ray.to)
  local delta=M.sub(to,from)
  local best,point,normal
  local function face(axis,value,n,inside)
   if math.abs(delta[axis])<1e-12 or M.dot(delta,n)>=0 then return end
   local t=(value-from[axis])/delta[axis]
   if t<0 or t>1 then return end
   local p=M.add(from,M.mul(delta,t))
   if inside(p) and (not best or t<best) then best,point,normal=t,p,n end
  end
  -- A start inside the authored solid is unavailable, never a farther hit.
  if from[2]<0 or from[3]>=curb_edge and from[2]<curb_height then return {status="unavailable"} end
  face(2,0,{0,1,0},function(p)return p[3]<curb_edge end)
  face(2,curb_height,{0,1,0},function(p)return p[3]>=curb_edge end)
  if not omit_wall then face(3,curb_edge,{0,0,-1},function(p)return p[2]>=0 and p[2]<=curb_height end)end
  if not best then return {status="clear"} end
  return {status="hit",position=point,normal=normal,normal_available=true,fraction=best,
   surface_velocity={0,0,0},surface_velocity_available=true,motion="measured"}
 end
 local function cast_plan(plan,omit_wall)
  local rays={}
  for i,ray in ipairs(plan)do rays[i]=cast(ray,omit_wall)end
  return rays
 end
 local wall_segment={from=vector.create(0,.06,curb_edge-.1),to=vector.create(0,.06,curb_edge+.1)}
 local nearest_wall=cast(wall_segment)
 local wall_fraction=(curb_edge-wall_segment.from.z)/(wall_segment.to.z-wall_segment.from.z)
 check(nearest_wall.status=="hit" and math.abs(nearest_wall.fraction-wall_fraction)<1e-8
  and nearest_wall.normal[3]==-1,"a horizontal segment actually measures the finite vertical wall")
 local above_wall=cast({from=vector.create(0,.2,curb_edge-.1),to=vector.create(0,.2,curb_edge+.1)})
 check(above_wall.status=="clear","the finite wall never extends above the top face")
 local function query(body)
  local frame={body=body}
  local plan,centers,context=Contact.wheel_plan(frame,G,Forces.tuning().gravity,.75)
  check(plan and #plan==6,"curb fixture starts with three actual vertical segments per wheel")
  local rays=cast_plan(plan)
  local wall_plan,candidates=Contact.edge_plan(frame,rays,centers,context,G)
  check(wall_plan~=nil,"curb wall plan refused: "..tostring(candidates))
  local wall_rays=cast_plan(wall_plan)
  local witness_plan,features=Contact.edge_witness_plan(frame,wall_rays,candidates,G)
  check(witness_plan~=nil,"curb witness plan refused: "..tostring(features))
  local witness_rays=cast_plan(witness_plan)
  check(#wall_plan<=2 and #witness_plan<=6 and #plan+#wall_plan+#witness_plan<=14,
   "all wheel phases plus three tripwires remain within17rays/34worst casts")
  local samples,why=Contact.wheel_samples(frame,rays,centers,context,G,features,witness_rays)
  check(samples~=nil,"measured curb contacts refused: "..tostring(why))
  return samples,{plan=plan,centers=centers,context=context,rays=rays,wall_plan=wall_plan,candidates=candidates,
   wall_rays=wall_rays,witness_plan=witness_plan,features=features,witness_rays=witness_rays}
 end
 -- A verified compressed rim without accepted loaded history is still a
 -- new landing. Forged geometry must not arm the carried-compression state.
 local proof_body,proof_wheels=World.place(terrain,{speed=0})
 proof_body.center_of_mass[2]-=.005
 local function compressed_samples(body)
  local samples=World.contacts(terrain,body,Forces.tuning().gravity)
  local hub=World.hubs(body)[1]
  samples[1].wheel_center=M.copy(hub);samples[1].wheel_radius=G.wheel_radius
  samples[1].wheel_rim=M.add(hub,{0,-G.wheel_radius,0})
  samples[1].contact.point=M.add(samples[1].wheel_rim,{0,.035,0})
  samples[1].separation=-.035
  return samples
 end
 local opening=M.copy(proof_body);opening.linear_velocity[2]=.1
 local orphan=Stage.new():preview(Forces.native_seconds,opening,proof_wheels,compressed_samples(opening),
  {pedal=0,steer=0,brake=0})
 check(not orphan.valid and orphan.issue=="landing_deflection_limit","orphan compressed rim retains the15mm landing refusal")
 local loaded=Stage.new()
 local loaded_seed,loaded_token=loaded:preview(Forces.native_seconds,proof_body,proof_wheels,
  World.contacts(terrain,proof_body,Forces.tuning().gravity),{pedal=0,steer=0,brake=0})
 check(loaded_seed.valid and loaded_seed.normal_load[1]>0,"negative geometry tests begin with accepted positive load")
 loaded:_adopt(loaded_token)
 for _,fault in ipairs({"radius","rim","gap"})do
  local forged=compressed_samples(opening)
  if fault=="radius"then forged[1].wheel_radius=G.wheel_radius*.9
  elseif fault=="rim"then forged[1].wheel_rim[3]+=.01
  else forged[1].separation=-.040 end
  local refused=loaded:preview(Forces.native_seconds,opening,proof_wheels,forged,{pedal=0,steer=0,brake=0})
  check(not refused.valid and refused.issue=="landing_geometry_unavailable","forged negative rim cannot arm recovery: "..fault)
 end
 loaded:invalidate_continuity()
 local cleared=loaded:preview(Forces.native_seconds,opening,proof_wheels,compressed_samples(opening),
  {pedal=0,steer=0,brake=0})
 check(not cleared.valid and cleared.issue=="landing_deflection_limit","invalidation clears loaded-rim recovery authority")
 for step=1,300 do
  local samples,proof=query(curb_body)
  for i,sample in ipairs(samples)do
   if sample.contact.status=="hit"then
    deepest=math.min(deepest,sample.separation)
    local expected_height=proof.centers[i][3]>=curb_edge and curb_height or 0
    check(math.abs(sample.contact.point[2]-expected_height)<1e-8,"primary is the actual current central nearest face")
   end
   if sample.edge then
    local edge=sample.edge
    local f=edge.edge_feature
    saw_edge=true
    deepest=math.min(deepest,edge.separation)
    check(f.topology_known==false and math.abs(f.top_point[2]-curb_height)<1e-8
     and math.abs(f.wall_point[3]-curb_edge)<1e-8 and M.dot(f.top_normal,{0,1,0})>.999
     and M.dot(f.wall_normal,{0,0,-1})>.999,"edge retains both measured facets and unknown arbitrary topology")
    if edge.kind=="edge"then
     local radial=M.sub(proof.centers[i],edge.contact.point)
     check(M.dot(edge.contact.normal,M.unit(radial))>1-1e-8
      and math.abs(edge.separation-(M.length(radial)-G.wheel_radius))<1e-8,
      "secondary edge uses radial wheel geometry rather than a forged top normal")
     check(edge.contact.normal[2]>=0 and edge.contact.normal[3]<=0,"edge normal remains inside the measured convex cone")
     if proof.centers[i][3]<curb_edge then saw_early=true end
    end
    if sample.contact.status=="hit" and sample.contact.point[2]==0 then
     saw_two_patches=true
     if not edge_fixture then edge_fixture={body=M.copy(curb_body),samples=M.copy(samples),proof=M.copy(proof),wheel=i}end
    end
   end
  end
  local commands=previous and {{age=1,force=previous.force,torque=previous.torque}}or{}
  local forecast,folded=InFlight.fold(Forces.native_seconds,Forces.tuning().gravity,commands,curb_body,samples)
  check(forecast~=nil,"curb forecast rebuilds the local edge geometry: "..tostring(folded))
  local hubs=World.hubs(curb_body)
  if hubs[2][3]>curb_edge+.15 then fully_crossed=true end
  local out,candidate=curb_stage:preview(Forces.native_seconds,forecast,curb_wheels,folded,
   {pedal=fully_crossed and 0 or .25,steer=0,brake=fully_crossed and .1 or 0})
  check(out.valid,"delayed curb packet refused at step"..step..":"..tostring(out.issue))
  check(#out.wheels==2 and M.finite(out.wheels[1].angular_speed) and M.finite(out.wheels[2].angular_speed),
   "two contact patches retain one finite rotor per physical wheel")
  for i=1,2 do
   check(out.patch_count[i]>=0 and out.patch_count[i]<=2 and out.edge_normal_impulse[i]>=0,
    "secondary constraints keep two physical wheels and unilateral edge impulses")
  end
  peak_force=math.max(peak_force,M.length(out.force));peak_torque=math.max(peak_torque,M.length(out.torque))
  check(peak_force<=6000 and peak_torque<=2000 and deepest>=-.10,"curb keeps force torque and penetration bounds")
  curb_stage:_adopt(candidate)
  local applied=previous or {force={0,0,0},torque={0,0,0},hop_impulse={0,0,0}}
  curb_body=World.integrate(curb_body,applied,Forces.tuning().gravity,Forces.native_seconds)
  previous=out;curb_wheels=out.wheels
  local up=M.turn(M.normalized(curb_body.orientation),{0,1,0})
  local roll=math.abs(M.dot(curb_body.angular_velocity,M.turn(curb_body.orientation,{0,0,1})))
  check(math.deg(math.acos(math.clamp(up[2],-1,1)))<55 and roll<8
   and math.abs(curb_body.linear_velocity[2])<6,"curb keeps existing measured tilt roll and vertical limits")
 end
 check(saw_edge and saw_early and saw_two_patches,"measured top+wall edge and lower floor coexist before the central crossing")
 check(fully_crossed and World.hubs(curb_body)[2][3]>curb_edge,"both wheels actually cross the authored curb")
 check(curb_body.center_of_mass[2]>.98,"measured chassis rises onto the 120 mm deck")
 -- Keep every unknown nearest observation and the unchanged gross bound.
 local samples,proof=query(curb_body)
 proof.rays[2]={status="unavailable"}
 check(Contact.wheel_samples({body=curb_body},proof.rays,proof.centers,proof.context,G)==nil,"unknown neighbouring contact still refuses")
 samples,proof=query(curb_body)
 proof.rays[1]={status="hit",position={proof.centers[1][1],proof.centers[1][2]-.01,proof.centers[1][3]},
  normal={0,1,0},normal_available=true,surface_velocity={0,0,0},surface_velocity_available=true,motion="measured"}
 check(Contact.wheel_samples({body=curb_body},proof.rays,proof.centers,proof.context,G)==nil,"excessive central penetration still refuses")
 check(edge_fixture~=nil,"negative edge fixtures require a real locally witnessed edge")
 local ep=edge_fixture.proof
 local ef=edge_fixture.samples[edge_fixture.wheel].edge.edge_feature
 local center=ep.centers[edge_fixture.wheel]
 local forward=M.turn(edge_fixture.body.orientation,{0,0,1})
 for _,fault in ipairs({"wall","top_witness","outside","moving","normal","radius","unknown","topology"})do
  local forged=M.copy(ef)
  local radius=G.wheel_radius
  if fault=="wall"then forged.wall_point[3]+=.02
  elseif fault=="top_witness"then forged.top_witness.point[3]=curb_edge-.02
  elseif fault=="outside"then forged.outside_witness.point[2]=curb_height
  elseif fault=="moving"then forged.wall_velocity[3]=.1
  elseif fault=="normal"then forged.wall_normal={0,1,0}
  elseif fault=="radius"then radius*=.9
  elseif fault=="unknown"then forged.wall_witness=nil
  else forged.topology_known=true end
  check(Contact.edge_sample(center,radius,forged,forward)==nil,"forged edge geometry refuses: "..fault)
 end
 local no_wall=cast_plan(ep.wall_plan,true)
 local missing_plan,missing_features=Contact.edge_witness_plan({body=edge_fixture.body},no_wall,ep.candidates,G)
 check(missing_plan and #missing_plan==0 and #missing_features==0,"top and lower rays alone cannot invent an edge")
 local no_edge=Contact.wheel_samples({body=edge_fixture.body},ep.rays,ep.centers,ep.context,G,missing_features,{})
 check(no_edge and no_edge[edge_fixture.wheel].edge==nil,"an absent measured wall leaves only the ordinary primary")
 local unknown_wall=M.copy(ep.wall_rays);unknown_wall[1]={status="unavailable"}
 check(Contact.edge_witness_plan({body=edge_fixture.body},unknown_wall,ep.candidates,G)==nil,
  "an unknown nearest wall refuses without a farther-hit fallback")
 local unknown_witness=M.copy(ep.witness_rays);unknown_witness[1]={status="unavailable"}
 check(Contact.wheel_samples({body=edge_fixture.body},ep.rays,ep.centers,ep.context,G,ep.features,unknown_witness)==nil,
  "unknown local witness cannot be skipped for a safer neighbour")
 local crossed_center=M.copy(center);crossed_center[3]=curb_edge+ef.extent*.5;crossed_center[2]=curb_height+G.wheel_radius
 local top=Contact.edge_sample(crossed_center,G.wheel_radius,ef,forward)
 check(top and top.kind=="top_face" and top.contact.status=="hit" and M.dot(top.contact.normal,ef.top_normal)>.999,
  "forecast cone exit resolves to the bounded witnessed top region")
 crossed_center[3]=curb_edge+ef.extent*2
 local outside=Contact.edge_sample(crossed_center,G.wheel_radius,ef,forward)
 check(outside and outside.contact.status=="clear" and outside.edge_feature and outside.wheel_radius==G.wheel_radius,
  "forecast beyond the witnessed region clears while retaining rebuild metadata")
 print(string.format("round_wheel_curb steps=300 height=.12 early=%s crossed=%s min_gap=%.6f F=%.3f T=%.3f",
  tostring(saw_early),tostring(fully_crossed),deepest,peak_force,peak_torque))
 return{cases=11,assertions=n,native_qualified=false}
end
return T

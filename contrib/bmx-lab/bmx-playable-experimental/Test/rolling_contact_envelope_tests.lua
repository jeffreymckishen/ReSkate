-- One constructed regression for accepted rolling compression history.
-- Uses current planar ray intersections; no SDK/native/curb-crossing claim.
local Stage=require("./force_stage")
local Forces=require("./forces")
local World=require("./sim_world")
local M=require("./force_math")
local T={}
function T.run()
 local n=0
 local function check(ok,why)n+=1;assert(ok,why)end
 local h,gravity=Forces.native_seconds,Forces.tuning().gravity
 local terrain=World.terrain.flat()
 local body,wheels=World.place(terrain,{speed=1.25})
 for _,wheel in ipairs(wheels)do wheel.angular_speed=1.25/wheel.radius end
 local controls={pedal=0,steer=0,brake=0}
 local function bounded(out,label)
  check(out.valid,label..": "..tostring(out.issue))
  check(out.contact_scale==1 and M.length(out.force)<=6000 and M.length(out.torque)<=2000,
   label.." retains the existing unscaled authored packet caps")
  check(not out.hop_applied,label.." does not create a hop")
 end
 local stage=Stage.new()
 local initial=World.contacts(terrain,body,gravity)
 local seed,seed_candidate=stage:preview(h,body,wheels,initial,controls)
 bounded(seed,"initial planar support")
 check(seed.grounded and seed.normal_load[1]>0 and seed.normal_load[2]>0,
  "history starts only with an actually loaded accepted model contact")
 stage:_adopt(seed_candidate)
 -- Construct a fresh measured30mm compression inside the already-admitted
 -- gross envelope, on the same analytic plane. This is a policy fixture,
 -- not a claim that a particular native road sample had this deflection.
 local compressed=M.copy(body)
 compressed.center_of_mass[2]+=-.03-initial[1].separation
 local samples=World.contacts(terrain,compressed,gravity)
 for i=1,2 do
  check(samples[i].contact.status=="hit" and samples[i].separation<-.015 and samples[i].separation>-.10,
   "both current ray intersections lie inside the original loaded envelope")
 end
 local load,discarded=stage:preview(h,compressed,wheels,samples,controls)
 bounded(load,"loaded compression")
 check(load.grounded and load.normal_load[1]>0 and load.normal_load[2]>0,
  "compression is eligible measured support, not an approach-ray substitute")
 local repeated,load_candidate=stage:preview(h,compressed,wheels,samples,controls)
 check(repeated.valid and M.length(M.sub(repeated.force,load.force))<1e-12,
  "discarded preview does not advance compression history")
 stage:_adopt(load_candidate)
 local opening_body=M.copy(compressed);opening_body.linear_velocity[2]=.5
 local opening_samples=World.contacts(terrain,opening_body,gravity)
 local opening,opening_candidate=stage:preview(h,opening_body,wheels,opening_samples,controls)
 bounded(opening,"zero-load opening")
 check(opening.normal_load[1]==0 and opening.normal_load[2]==0,
  "the unilateral law genuinely releases both normal rows")
 check(not opening.grounded and opening.balance_support_mask==0,
  "carried deflection policy cannot claim ground or balance support")
 stage:_adopt(opening_candidate)
 -- Advance the actual bounded model packet, then measure the plane again.
 -- Gravity reduces opening speed while the tyre is still deeper than15mm.
 local next_body=World.integrate(opening_body,opening,gravity,h)
 local next_samples=World.contacts(terrain,next_body,gravity)
 for i=1,2 do
  check(next_samples[i].contact.status=="hit" and next_samples[i].separation<-.015 and next_samples[i].separation>-.10,
   "fresh post-opening rays still measure the previously admitted compression")
  check(not Forces.eligible_support(next_body,next_samples[i],.005,.10),
   "current opening motion remains independently ineligible for grounded truth")
 end
 local recovery,recovery_candidate=stage:preview(h,next_body,opening.wheels,next_samples,controls)
 bounded(recovery,"fresh hit after zero load")
 check(not recovery.grounded and recovery.balance_support_mask==0,
  "retaining the envelope does not fabricate supporting history")
 local too_deep=M.copy(next_body);too_deep.center_of_mass[2]-=.2
 local refused=stage:preview(h,too_deep,opening.wheels,World.contacts(terrain,too_deep,gravity),controls)
 check(not refused.valid and refused.issue=="penetration_limit",
  "the original gross penetration guard still refuses")
 local again,accepted=stage:preview(h,next_body,opening.wheels,next_samples,controls)
 check(again.valid and M.length(M.sub(again.force,recovery.force))<1e-12,
  "refused/discarded previews cannot publish a different accepted history")
 stage:_adopt(accepted)
 local raised=M.copy(next_body);raised.center_of_mass[2]+=2
 local clear_samples=World.contacts(terrain,raised,gravity)
 check(clear_samples[1].contact.status=="clear" and clear_samples[2].contact.status=="clear",
  "finite current rays actually clear the plane after the body is raised")
 local clear,clear_candidate=stage:preview(h,raised,again.wheels,clear_samples,controls)
 bounded(clear,"clear contact")
 check(not clear.grounded and clear.balance_support_mask==0,"clear rays remain unsupported")
 stage:_adopt(clear_candidate)
 local after_clear=stage:preview(h,opening_body,wheels,opening_samples,controls)
 check(after_clear.valid,"a wheel past its band after clear rays works back from where it is")
 local fresh=Stage.new():preview(h,opening_body,wheels,opening_samples,controls)
 check(fresh.valid,"a fresh contact past its band works back from where it is too")
 -- Additional constructed envelopes, not a replay: the human store omits742
 -- of766 samples and does not retain the failing full pose/mass/contact path.
 -- World.place supplies proposed106kg body/inertia/identity pose and rolling
 -- rotors here. Only the rounded failure velocities and last two gaps below
 -- are carried from that retained diagnostic, never the omitted trajectory.
 local function vector_text(v)
  if not v then return "unavailable" end
  return string.format("(%.9g,%.9g,%.9g)",v[1],v[2],v[3])
 end
 local function inspect(label,step,current,samples,out,previous)
  local raw=out.valid and out or out.diagnostic
  check(type(raw)=="table" and M.vec(raw.force) and M.vec(raw.torque),
   label.." exposes actual finite raw kernel force/torque even on authored refusal")
  local df=previous and M.sub(raw.force,previous.force) or nil
  local dt=previous and M.sub(raw.torque,previous.torque) or nil
  print(string.format("constructed_%s step=%d h=%.17g issue=%s gaps=(%s,%s) v=%s w=%s F=%s |F|=%.9g T=%s |T|=%.9g dF=%s dT=%s joint=%s target=%s grounded=%s approach=%s",
   label,step,h,tostring(out.issue),tostring(samples[1].separation),tostring(samples[2].separation),
   vector_text(current.linear_velocity),vector_text(current.angular_velocity),vector_text(raw.force),M.length(raw.force),
   vector_text(raw.torque),M.length(raw.torque),vector_text(df),vector_text(dt),tostring(raw.front_steer_angle),
   tostring(raw.requested_front_steer_angle),tostring(raw.grounded),tostring(raw.landing_approach_mask)))
  return raw
 end
 -- Twenty ordinary native steps: four neutral accepted support steps, then
 -- full steering reversals every two steps. No impulse, cap or cadence changes.
 local speed=math.sqrt(4.47^2+5.37^2)
 local turning_body,turning_wheels=World.place(terrain,{speed=speed})
 local turning_stage=Stage.new()
 local previous,previous_joint
 local joint_step_limit=5*Forces.tuning().steer_limit*h+1e-8 -- existing playable_steering_tests bound
 for step=1,20 do
  check(turning_stage:admit_measured(turning_body),"constructed rolling body remains inside original measured admission")
  local samples=World.contacts(terrain,turning_body,gravity)
  local steer=step<=4 and 0 or (math.floor((step-5)/2)%2==0 and .85 or -.85)
  local out,candidate=turning_stage:preview(h,turning_body,turning_wheels,samples,{pedal=0,brake=0,steer=steer})
  local raw=inspect("quick_reversal",step,turning_body,samples,out,previous)
  check(out.valid and out.contact_scale==1 and M.length(raw.force)<=6000 and M.length(raw.torque)<=2000
   and not out.hop_applied,"constructed rolling reversals retain original unscaled packet caps: "..tostring(out.issue))
  if previous_joint then check(math.abs(out.front_steer_angle-previous_joint)<=joint_step_limit,
   "reversal keeps the existing accepted joint step bound") end
  previous,previous_joint=raw,out.front_steer_angle
  turning_stage:_adopt(candidate)
  turning_body=World.integrate(turning_body,out,gravity,h);turning_wheels=out.wheels
 end
 -- One isolated near-floor closing component fixture. Two authored stationary
 -- planes are placed at the retained gaps under the proposed body's two hubs.
 -- This does not assert an actual native road normal, body orientation, mass,
 -- actuator state, accepted history, or force-component cause for the failure.
 local near_body,near_wheels=World.place(terrain,{speed=speed})
 near_body.linear_velocity={4.47,-1.47,5.37}
 near_body.angular_velocity={2.65,.03,3.45}
 local gaps={.006200412758532281,.006561090946082759}
 local near_samples={}
 for i,hub in ipairs(World.hubs(near_body))do
  local height=hub[2]-World.wheel_radius-gaps[i]
  local plane={height=function()return height end,slope=function()return 0 end}
  local samples=World.contacts(plane,near_body,gravity)
  local sample=samples[i];sample.wheel_center=M.copy(hub);sample.wheel_radius=World.wheel_radius
  near_samples[i]=sample
  -- Set an explicitly constructed rolling rotor for this authored contact
  -- point; the retained native wheel state is unknown and is not substituted.
  local rolling_speed=M.dot(M.point_velocity(near_body,sample.contact.point),sample.contact.forward)
  near_wheels[i].angular_speed=rolling_speed/near_wheels[i].radius
  check(math.abs(near_wheels[i].angular_speed*near_wheels[i].radius-rolling_speed)<1e-9,
   "authored rotor starts with zero longitudinal slip at its constructed ray point")
  check(sample.contact.status=="hit" and math.abs(sample.separation-gaps[i])<1e-9,
   "constructed plane gives the retained scalar gap without inventing an omitted ray")
  check(not Forces.eligible_support(near_body,sample,.005,.10),
   "positive gap outside original5mm eligibility never fabricates supporting contact")
 end
 local near_stage=Stage.new()
 check(near_stage:admit_measured(near_body),"rounded diagnostic velocity envelope remains within original measured caps")
 local near,candidate=near_stage:preview(h,near_body,near_wheels,near_samples,{pedal=0,brake=0,steer=0})
 local raw=inspect("near_floor_closing_guard",1,near_body,near_samples,near,nil)
 -- Positive measured gaps do not promise an admissible next point position.
 -- T45 actually refused this proposed pose/history. The original post-packet
 -- landing-deflection guard returns result(issue), sanitizing F/T/support/hop
 -- to zero; those zeros do not reveal the internal calculated packet or prove
 -- the human7802N cause. The unsupported valid-packet oracle from R1 is removed.
 check(near.valid and raw.valid,"a landing past the next-point band rides through: refusing it left the bike unsupported")
 check(not near.grounded and not raw.grounded and raw.balance_support_mask==0
  and not near.hop_applied and near.hop_event_id==0 and M.length(near.hop_impulse)==0
  and not raw.hop_applied and raw.hop_event_id==0 and M.length(raw.hop_impulse)==0,
  "a landing step cannot fabricate support, balance or a hop")
 check(pcall(function() near_stage:_adopt(candidate) end),"its accepted step can be adopted")
 -- One source-proven stopping-target boundary group; all earlier cases stay intact.
 do
 local function samples_at(body,gap)
  local samples={}
  for i,hub in ipairs(World.hubs(body))do
   local height=hub[2]-World.wheel_radius-gap
   local plane={height=function()return height end,slope=function()return 0 end}
   samples[i]=World.contacts(plane,body,gravity)[i]
   samples[i].wheel_center=M.copy(hub);samples[i].wheel_radius=World.wheel_radius
  end
  return samples
 end
 local function packet(speed,gap)
  local body,wheels=World.place(terrain,{speed=speed})
  body.linear_velocity[2]=-.4 -- authored shallow closing input, not a captured frame
  local samples=samples_at(body,gap)
  local eligible=gap<=.005
  for i=1,2 do
   check(samples[i].contact.status=="hit" and math.abs(samples[i].separation-gap)<1e-9,
    "constructed static planes retain their exact current measured gap")
   check(Forces.eligible_support(body,samples[i],.005,.10)==eligible,
    "original5mm eligibility remains exact on each side")
  end
  local out=Stage.new():preview(h,body,wheels,samples,{pedal=0,brake=0,steer=0})
  local raw=out.valid and out or out.diagnostic
  check(out.valid,"bounded shallow floor packet: "..tostring(out.issue))
  check(out.contact_scale==1 and M.length(out.force)<=6000 and M.length(out.torque)<=2000 and not out.hop_applied,
   "boundary continuity cannot clip, enlarge original caps or generate hop authority")
  check(out.grounded==eligible and out.balance_support_mask==(eligible and 3 or 0),
   "a continuous normal target does not widen ground or balance support")
  local normal_impulse=out.normal_impulse[1]+out.normal_impulse[2]
   +out.approach_normal_impulse[1]+out.approach_normal_impulse[2]
  print(string.format("constructed_floor_boundary speed=%.9g gap=%.12g F=(%.9g,%.9g,%.9g) T=(%.9g,%.9g,%.9g) normal_j=%.12g grounded=%s approach=%d",
   speed,gap,raw.force[1],raw.force[2],raw.force[3],raw.torque[1],raw.torque[2],raw.torque[3],
   normal_impulse,tostring(out.grounded),out.landing_approach_mask))
  return normal_impulse
 end
 -- A true target jump does not shrink when the two measured gaps approach
 -- the same boundary. Check actual unilateral output convergence, rather
 -- than restating the target formula or inventing a native comfort limit.
 for _,speed in ipairs({0,2})do
  local coarse=math.abs(packet(speed,.005-1e-4)-packet(speed,.005+1e-4))
  local fine=math.abs(packet(speed,.005-1e-8)-packet(speed,.005+1e-8))
  check(coarse>0 and fine<coarse*.1,"normal impulse boundary jump shrinks with the measured gap interval")
 end
 local body,wheels=World.place(terrain,{speed=2})
 body.linear_velocity[2]=-.4
 local unknown=samples_at(body,.004)
 unknown[1].forecast_geometry_unavailable=true
 local refused=Stage.new():preview(h,body,wheels,unknown,{pedal=0,brake=0,steer=0})
 check(not refused.valid and refused.issue=="landing_geometry_unavailable","unknown forecast geometry still refuses inside the band")
 local deep=samples_at(body,-.101)
 local penetration=Stage.new():preview(h,body,wheels,deep,{pedal=0,brake=0,steer=0})
 check(not penetration.valid and penetration.issue=="penetration_limit","original gross penetration guard remains unchanged")
 end
 return {cases=4,assertions=n,constructed=true,native_qualified=false}
end
return T

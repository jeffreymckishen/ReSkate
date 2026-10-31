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
 check(not after_clear.valid and after_clear.issue=="landing_deflection_limit",
  "clear observations erase the carried envelope")
 local fresh=Stage.new():preview(h,opening_body,wheels,opening_samples,controls)
 check(not fresh.valid and fresh.issue=="landing_deflection_limit",
  "a fresh unsupported contact cannot borrow an unobserved loaded envelope")
 return {cases=1,assertions=n,constructed=true,native_qualified=false}
end
return T

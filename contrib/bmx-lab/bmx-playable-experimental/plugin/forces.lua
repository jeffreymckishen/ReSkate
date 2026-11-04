-- Ordinary bmx_chassis_control.h kernel. Outputs impulses/forces only; never integrates pose.
local M=require("./force_math")
local Tire=require("./tire")
local Pump=require("./pump")
local Solver=require("./force_solver")
local F={native_seconds=.01666666567325592}
local Controller={} Controller.__index=Controller
local scale=.7737670588235294
F.wheel_radius=.34*scale
-- B is all or nothing, so the lever is squeezed here: this long to full brake, and this long to let go.
local BRAKE_SQUEEZE_SECONDS,BRAKE_RELEASE_SECONDS=.15,.05
local MAXIMUM_CAMBER=.8
local steering_axis={0,.9601196050643921,-.2795896530151367} -- the source float coefficients
-- Hop-only authored landing policy. The compliance arithmetic comes from our
-- native contact_compliance.h; earlier braking from a fresh measured ray is a
-- separate policy, not a native collision or a claim that a clear wheel rests.
local landing={stiffness=100000,impact_stiffness=10000,maximum_deflection=.015,deflection_tolerance=1e-8,contact_gap=.005,
    approach_gap=.65,approach_acceleration=25,floor_cosine=.95,stationary_speed=.0001,settle_speed=.4,soften_speed=3}
-- Keep the firm static spring (about 5.2 mm sag for 106 kg on two wheels),
-- and soften only closing impacts continuously across 0.4..3 m/s. Ordinary
-- rolling, lateral motion and opening retain the firm spring; loaded history
-- never removes this impedance.
local function floor_softness(h,body,contact,basis,fraction)
    local v=M.sub(M.point_velocity(body,contact.point),contact.surface_velocity)
    local closing=-M.dot(v,basis.normal)
    local u=math.clamp((closing-landing.settle_speed)/(landing.soften_speed-landing.settle_speed),0,1)
    u=u*u*(3-2*u)
    local stiffness=landing.stiffness+(landing.impact_stiffness-landing.stiffness)*u
    return fraction/(stiffness*h*h)
end
local defaults={gravity={0,-9.8,0},wheelbase=1.203956057050485*scale,steer_limit=.4,steer_speed_scale=8,
    pedal_torque=75,front_brake_torque=60,rear_brake_torque=45,friction={longitudinal_friction=1,lateral_friction=1},
    balance_stiffness=1600,balance_damping=360,balance_torque_limit=1200,lean_limit=.52,
    air_yaw_torque=200,air_pitch_torque=160,neutral_air_damping_rate=2.75,hop_delta_speed=4.5,
    contact_gap=.02,maximum_penetration=.10,recovery_fraction=.15,recovery_speed_limit=.4,
    force_limit=40000,torque_limit=4000,wheel_speed_limit=500,contact_iterations=12,pedal_fade_start=7,pedal_cutoff=8,
    pedal_top_speed=7.7,pedal_resume_speed=7.2,
    -- A rider, not a motor: the pedal starts with its full torque, but never puts more than this many watts into
    -- the rear wheel, so a steep climb slows the bike the way it slows a rider. The constant torque alone held
    -- 6.4 m/s up a 20% grade, about 1450 W. 1200 W is an elite rider's sprint (about 1100 W in the lab at 100 rpm,
    -- 1540 W at the peak in the field), held for as long as A is, with no fatigue: a feel choice, not a
    -- measurement. It takes over from the torque at about 4.2 m/s. The fade starts at 7 m/s because with the old
    -- fade from 6 as well, a bike on the flat only reached 7.64 m/s and never coasted.
    rider_power=1200,
    curvature_rate_limit=6,curvature_step_limit=.2,curvature_min_speed=.5,brake_iterations=96,
    -- Estimates, not measurements: a street tyre's rolling coefficient, and drag in N per (m/s)^2 for a
    -- rider sitting up on a BMX (air density 1.2, CdA .5).
    rolling_resistance=.01,air_drag=.3,
    -- Half the width of a 2.4 inch tyre: a leaned wheel rolls on its shoulder, this far inside its hub's plane.
    tyre_section_radius=.03,
    -- Braking uses grip the corner wanted. Under a full brake the cornering limit gives up this share, and the
    -- rider eases the rear brake to this share of what the rear tyre can hold, as they would by feel.
    brake_lateral_cut=.6,rear_brake_load_share=.6,
    -- A manual: the bike on its back wheel, held there by the rider's weight. A pitch couple on the one rigid body
    -- stands for the rider moving the whole centre of mass by couple/weight, so it is held to what a rider can
    -- shift: this far back (arms straight, hips behind the saddle) and this far forward (chest to the bars). The
    -- centre of mass sits .637 m over the rear axle and .4158 m ahead of it, so the bike balances at 33.1 degrees
    -- to the surface and the rider can hold it from 17.9 to 44.5. The target is how far the centre of mass sits
    -- ahead of the rear contact: low at the start of the stick's band (20 degrees), and at its end 3 degrees past
    -- the balance (36.4), where the rider leans toward the bars to hold it.
    manual_hold_back=.20,manual_hold_forward=.15,manual_low=.17,manual_high=-.05,
    -- Lifting the front from level needs 432 N*m, more than any weight shift gives (208 at manual_hold_back). A
    -- rider throws the bike up: on the way up this much is allowed up to 17.9 degrees, where the weight shift alone
    -- just holds the bike, fading out from there over manual_pull_ramp of offset, to none from 24.1 degrees. Faded
    -- out by 17.9 instead, the shift had almost nothing left to lift with just above it (208 N*m against gravity's
    -- 189 at 19.3 degrees), so a manual whose rise a kerb ramp's knocks took away there (trial mn4) crawled at 19 to
    -- 21 degrees for 1.4 s rather than going on to 35. Once the front has come up to the stick's offset, within
    -- manual_risen_slack of it along the surface or against the ground the lift started from, the throw fades out
    -- by 17.9 instead, until the front is down again. That ground is the surface under the rear wheel when the front
    -- last stood on the road, so up a hill it is the hill. Judged against level, up a 10% grade a lift read 8 to 9
    -- degrees short of its angle, and a 5 cm lip met then stalled the bike at 17 to 20 degrees for a second, as
    -- mn4's ramp did. The offset is measured along the surface under the rear wheel, so the rising face of a bump
    -- or a kicker reads a held manual at 34 degrees to level as about 17 to its ground; with the wider throw there
    -- too, it threw the bike up the face at 450 to 630 N*m and over backwards at the crest (an 8 cm bump at 2.5 m/s,
    -- a 16 degree kicker at 4). Ended once the bike first passed 24 degrees instead, the lift lost it just before
    -- mn4's knocks; judged along the surface alone, a bump met while the law crept up the last degree still threw
    -- the bike over. The law settles about 5 mm short of its target. A throw is one movement, not a hold: the rider
    -- has it for at most manual_pull_seconds at a time below 17.9 degrees, has it again once back above that or with
    -- the front down, and has none while braking. Allowed whenever the bike was below 17.9, it held a braked manual
    -- at 12 to 15 degrees on 430 to 800 N*m for over a second, two to four times what the drawn rider can shift.
    -- Spent until the front was down again, a 5 cm bump put the front of a 32 degree manual on the ground, where a
    -- rider pulls it back up. Followed over .3 s instead of held from the lift's start, that ground took on a kicker
    -- met during the lift, so the front never read as up and the throw carried the bike up the face and over.
    manual_pull=800,manual_pull_ramp=.08,manual_pull_seconds=1,manual_risen_slack=.02,
    -- Until then the throw is judged along the surface, but on an offset no further back than this past the one
    -- against the ground the lift started from, so a face met during the lift cannot hold the throw on: against
    -- that ground it fades from 24 degrees and is gone by 30. The front reads as up only within manual_risen_slack
    -- of the stick's offset, which the law creeps up to over its last degree; an 8 cm bump or a 16 degree kicker met
    -- in that last half second read the bike, 33 degrees to the road, as about 17 to the face, kept the throw on at
    -- up to 800 N*m, and the bike went over backwards at the crest. A wider slack only moved the window. At .04 the
    -- throw went too soon on mn4's kerb ramp, which then took 1.6 s to reach 30 degrees against 1.23.
    manual_face_offset=.08,
    -- The front moves at most this fast (rad/s), toward the target at this gain (1/s), on this damping (N*m*s).
    -- A plain spring overshot past the loop-out on high targets: 156 N*m forward cannot stop a fast lift.
    manual_rate=1.5,manual_gain=4,manual_damping=560,
    -- Slower than this the rider cannot keep their side balance on one wheel and the front comes down. From both
    -- wheels a manual starts only from manual_start_speed: with one speed for both, A and the stick held from a
    -- stop never got past 1.05 m/s, the pedal cut and the front lifted about every quarter second.
    manual_min_speed=1.0,manual_start_speed=1.5,
    -- With the front up nothing corners the bike: the bars turn the rider's hips, carving at most this yaw rate
    -- (rad/s, reached from 2 m/s), on this damping and no more than this torque.
    manual_carve_rate=.6,manual_carve_damping=100,manual_carve_torque=150,
    -- A nose manual: the bike on its front wheel with the rear up, held there by the rider's weight over the bars,
    -- the rear manual mirrored about the front contact. The centre of mass sits .637 m over the front axle and
    -- .5158 m behind it, so the bike balances on its front wheel at 39.0 degrees to the surface; at level gravity's
    -- torque about the front contact is 536 N*m. The rider shifts the weight at most nose_hold_forward forward (hips
    -- up over the bars, chest down) and nose_hold_back back; past the balance by more than that, at 53 degrees,
    -- nothing holds it and the bike goes over the bars. The target is how far the centre of mass sits behind the
    -- front contact: nose_low at the start of the band (23 degrees), nose_high at its end (30.1), 9 degrees short of
    -- the balance. The lift reuses the manual's throw, law, speeds and risen and face rules.
    nose_hold_forward=.26,nose_hold_back=.20,nose_low=.23,nose_high=.13,
    -- Tipping on over the bars faster than nose_catch_rate (rad/s), the rider snaps the weight back, up to
    -- nose_catch_torque, all of it nose_catch_span faster, for at most nose_catch_seconds of pulling past
    -- nose_hold_back a lift. Without it a 12 cm bump or a 10 cm kerb ramp met at 1.6 to 2.5 m/s threw the bike over.
    nose_catch_torque=800,nose_catch_rate=.6,nose_catch_span=.5,nose_catch_seconds=.4,
    -- Thrown off the front by a bump or a kerb's top with the stick still held, the rider holds the bike's angle with
    -- the air pitch's authority for at most nose_air_seconds. Without it an 8 cm bump at 4 m/s, a 12 cm one at 2.5
    -- to 7 m/s, a 25 degree kicker and a 15 cm kerb ramp at 7 m/s threw the bike over the bars.
    nose_air_seconds=.5,
    -- On its front wheel the bike carves round it: at most nose_carve_rate (reached from 2 m/s), and no more
    -- sideways than nose_carve_lateral, on the rider's twist (nose_yaw_damping, at most nose_yaw_torque), with the
    -- spring's roll part taken nose_roll_gain times.
    nose_carve_rate=.6,nose_carve_lateral=2.5,nose_yaw_damping=300,nose_yaw_torque=300,nose_roll_gain=1.6}
function F.tuning(overrides)
    local out=M.copy(defaults) for key,value in overrides or {} do assert(out[key]~=nil,"unknown force tuning") out[key]=M.copy(value) end return out
end
function F.proposed_body() return {mass=106,inertia_body={26,32,10},orientation={0,0,0,1},center_of_mass={0,0,0},linear_velocity={0,0,0},angular_velocity={0,0,0}} end
function F.proposed_wheels() return {{radius=F.wheel_radius,inertia=.23,angular_speed=0},{radius=F.wheel_radius,inertia=.23,angular_speed=0}} end
function F.controls(overrides)
    local c={enabled=true,pedal=0,brake=0,steer=0,manual=0,nose_manual=0,manual_held=false,nose_manual_held=false,air_yaw=0,hop_strength=0,hop_event_id=0,
        recovery_step_verified=false,rotation_reserved=false,pump_operator_available=false,pump_inhibited=false,ground_pump=0,
        contact_compliance_available=false,landing_contact_compliance_selected=false}
    for key,value in overrides or {} do assert(c[key]~=nil,"unknown force control") c[key]=value end return c
end
local function result(issue)
    return {valid=false,grounded=false,hop_applied=false,issue=issue or "invalid_sample",force={0,0,0},torque={0,0,0},
        linear_impulse={0,0,0},angular_impulse={0,0,0},hop_impulse={0,0,0},hop_event_id=0,wheels={},
        normal_load={0,0},normal_impulse={0,0},longitudinal_impulse={0,0},lateral_impulse={0,0},recovery_velocity={0,0},
        front_steer_angle=0,requested_front_steer_angle=0,turning_lean_angle=0,steering_limited=false,contact_scale=1,
        desired_support_angular_velocity={0,0,0},balance_support_mask=0,balance_continuation_mask=0,brake_impulse={0,0},
        balance_reference_up={0,0,0},desired_balance_up={0,0,0},balance_torque={0,0,0},air_control_torque={0,0,0},
        motor_torque={0,0,0},contact_torque={0,0,0},pre_contact_prediction_available=false,pump_force={0,0,0},
        air_damping_torque={0,0,0},air_rotation_reserved=false,neutral_air_damping_active=false,pedaling=false,
        landing_approach_mask=0,compliant_normal_mask=0,landing_recovery_mask=0,approach_normal_impulse={0,0},approach_normal_force={0,0},
        manual_active=false,manual_couple=0,manual_offset=0,manual_target_offset=0,manual_carve_rate=0,manual_shift=0,
        nose_manual_active=false,nose_manual_offset=0,nose_yaw_couple=0,nose_air_couple=0}
end
local function tuning_valid(t)
    if not M.vec(t.gravity,100) or M.length(t.gravity)<.1 then return false end
    for _,name in {"contact_iterations","brake_iterations"} do
        local x=t[name] local maximum=name=="contact_iterations" and 32 or 128
        if not M.finite(x) or x<1 or x>maximum or x%1~=0 then return false end
    end
    for _,name in {"wheelbase","steer_limit","steer_speed_scale","force_limit","torque_limit","wheel_speed_limit"} do
        if not M.finite(t[name]) or t[name]<=0 or t[name]>1e6 then return false end
    end
    for _,name in {"pedal_torque","front_brake_torque","rear_brake_torque","balance_stiffness","balance_damping","balance_torque_limit",
        "lean_limit","air_yaw_torque","air_pitch_torque","hop_delta_speed","contact_gap","maximum_penetration",
        "recovery_fraction","recovery_speed_limit","pedal_fade_start","pedal_cutoff","pedal_top_speed","pedal_resume_speed","rider_power",
        "curvature_rate_limit","curvature_step_limit","curvature_min_speed","neutral_air_damping_rate",
        "rolling_resistance","air_drag","tyre_section_radius","brake_lateral_cut","rear_brake_load_share",
        "manual_hold_back","manual_hold_forward","manual_pull","manual_pull_ramp","manual_pull_seconds","manual_risen_slack","manual_face_offset","manual_rate","manual_gain",
        "manual_damping","manual_min_speed","manual_start_speed","manual_carve_rate","manual_carve_damping","manual_carve_torque",
        "nose_hold_forward","nose_hold_back","nose_low","nose_high","nose_carve_rate","nose_carve_lateral","nose_yaw_damping",
        "nose_yaw_torque","nose_roll_gain","nose_catch_torque","nose_catch_rate","nose_catch_span","nose_catch_seconds",
        "nose_air_seconds"} do if not M.finite(t[name]) or t[name]<0 or t[name]>1e6 then return false end end
    if not M.finite(t.manual_low) or not M.finite(t.manual_high) then return false end
    if type(t.friction)~="table" then return false end
    for _,key in {"longitudinal_friction","lateral_friction"} do local x=t.friction[key] if not M.finite(x) or x<0 or x>10 then return false end end
    if t.manual_hold_back>.3 or t.manual_hold_forward>.3 or t.manual_high< -.3 or t.manual_high>=t.manual_low or t.manual_low>.3 or
        t.manual_pull>t.balance_torque_limit or t.manual_pull_ramp<=0 or t.manual_rate>4 or t.manual_gain>10 or
        t.manual_start_speed<t.manual_min_speed or t.manual_start_speed>5 or t.manual_pull_seconds>5 or t.manual_risen_slack>.1 or t.manual_face_offset>.3 then return false end
    if t.nose_hold_forward>.3 or t.nose_hold_back>.3 or t.nose_high>=t.nose_low or t.nose_low>t.nose_hold_forward or
        t.nose_carve_rate>4 or t.nose_carve_lateral>10 or t.nose_yaw_torque>t.balance_torque_limit or
        t.nose_roll_gain<1 or t.nose_roll_gain>3 or t.nose_catch_torque>t.balance_torque_limit or t.nose_catch_span<=0 or
        t.nose_catch_seconds>1 or t.nose_air_seconds>1 then return false end
    return t.brake_lateral_cut<=1 and t.rear_brake_load_share<=1 and t.steer_limit<=1 and t.lean_limit<=.8 and t.hop_delta_speed<=4.5 and t.contact_gap<=.05 and
        t.maximum_penetration<=.15 and t.recovery_fraction<=1 and t.recovery_speed_limit<=1 and t.pedal_fade_start<t.pedal_cutoff and
        t.pedal_cutoff<=50 and t.pedal_resume_speed<t.pedal_top_speed and t.pedal_top_speed<=t.pedal_cutoff and t.curvature_rate_limit<=10 and t.curvature_step_limit<=.35 and t.curvature_min_speed<=5 and t.neutral_air_damping_rate<=10
end
function F.eligible_support(body,sample,tolerance,maximum_penetration)
    tolerance=tolerance or .005 maximum_penetration=maximum_penetration or .10
    if not M.valid_body(body) or not M.vec(body.linear_velocity,50) or not M.vec(body.angular_velocity,40) then return false end
    local c=sample.contact
    if c.status~="hit" or not M.finite(tolerance) or tolerance<0 or tolerance>.05 or not M.finite(maximum_penetration) or
        maximum_penetration<0 or maximum_penetration>.15 or not M.finite(sample.separation) or sample.separation < -maximum_penetration or
        sample.separation>tolerance or not M.vec(c.point) or not M.vec(c.surface_velocity,50) then return false end
    local basis=M.basis(c.normal,c.forward) if not basis then return false end
    local relative=M.sub(M.point_velocity(body,c.point),c.surface_velocity)
    -- The contact below pushes a deep wheel back out. A wheel rising no faster than that is still on the ground:
    -- reading it as lifted took balance away for half a second over any small step, with the tyres still cornering.
    local recovering=math.min(defaults.recovery_speed_limit,defaults.recovery_fraction*math.max(0,-sample.separation)/F.native_seconds)
    return M.vec(relative) and M.dot(relative,basis.normal)<=.05+recovering
end
local function fraction(base,contact,cap)
    if not M.finite(M.length(base)) or not M.finite(M.length(contact)) or M.length(base)>cap then return -1 end
    if M.length(M.add(base,contact))<=cap then return 1 end
    local low,high=0,1 for _=1,56 do local middle=(low+high)*.5 if M.length(M.add(base,M.mul(contact,middle)))<=cap then low=middle else high=middle end end return low
end
local function reservation(a,successor,enabled,support,intent,launch)
    if not successor or not enabled then table.clear(a) return false end
    if support then a.ground_seen=true a.airborne=false a.reserved=false a.launch_reserved=launch return false end
    if not a.ground_seen then a.reserved=true return false end
    if not a.airborne then a.airborne=true a.reserved=a.launch_reserved or intent else a.reserved=a.reserved or intent end
    return not a.reserved
end
-- Whether the rider turns the cranks. The drawn cadence follows the rear wheel,
-- so a held pedal past the speed pedaling can reach spun the legs ever faster
-- while the fade gave almost no push. At or above top_speed the rider coasts
-- instead, pedal held or not, and pedals again only at or below resume_speed.
-- top_speed sits just under where the fading pedal meets drag (7.8 m/s), so
-- a rider holding the pedal on a flat road really does reach it and coast. The
-- band keeps a bike holding its top speed from switching every step on small
-- speed changes: about 1.4 s of pedalling, then 2 s of coasting. Only a rider
-- who would pedal at the top speed arms the latch. Once armed it follows speed
-- alone, so letting go and pressing again inside the band does not start a
-- spin back up, while a bike that coasted down from above can be pedaled at
-- once. The rear drive, the pump's pedal factor and the composer's drawn crank
-- all read this one decision.
-- s={enabled,pedal,motor_speed,top_speed,resume_speed}; previous is nil or a
-- pedal_state().
function F.pedal_state() return {spun_out=false} end
function F.pedal_cadence(previous,s)
    local refused=table.freeze({valid=false,pedaling=false,spun_out=false})
    if previous~=nil and (type(previous)~="table" or type(previous.spun_out)~="boolean") then return refused,F.pedal_state() end
    if type(s)~="table" or type(s.enabled)~="boolean" or not M.finite(s.pedal) or s.pedal<0 or s.pedal>1 or
        not M.finite(s.motor_speed) or s.motor_speed<0 or s.motor_speed>1e6 or not M.finite(s.top_speed) or
        not M.finite(s.resume_speed) or s.resume_speed<0 or s.resume_speed>=s.top_speed or s.top_speed>50 then return refused,F.pedal_state() end
    local spun=(s.enabled and s.pedal>0 and s.motor_speed>=s.top_speed) or (previous~=nil and previous.spun_out and s.motor_speed>s.resume_speed)
    return table.freeze({valid=true,pedaling=s.enabled and s.pedal>0 and not spun,spun_out=spun}),{spun_out=spun}
end
function F.new(tuning)
    local out=setmetatable({tuning=F.tuning(tuning)},Controller) out:reset() return out
end
-- reset clears the pedal latch with the rest. invalidate_continuity and a
-- refused step keep it: it holds no derivative, and outside the band this
-- step's speed decides it alone. Whether the bike is in a manual is kept the
-- same way, so a hitch does not drop the front of a held manual, and so is
-- how long the rider's throw has been in use, whether the front has come up
-- since it left the ground, the ground the lift started from, and whether a
-- manual slowed to a walk with the stick still held. The nose manual's state
-- is kept the same way.
function Controller:reset() self.last_hop_event=0 self.normals={{},{}} self.landing_impact={false,false} self.travel_direction=0 self.air={} self.steering={} self.pump=Pump.new() self.pump:reset() self.pedal_latch=F.pedal_state() self.brake_share=0 self.brake_squeeze=0 self.manual_engaged=false self.manual_throw_seconds=0 self.manual_risen=false self.manual_slowed=false self.manual_ground=nil
    self.nose_engaged=false self.nose_throw_seconds=0 self.nose_risen=false self.nose_slowed=false self.nose_ground=nil
    self.nose_catch_spent=0 self.nose_air_clock=-1 self.nose_air_target=0 end
function Controller:invalidate_continuity()
    -- A missed command breaks one-step derivative and state-machine history.
    -- Accepted hop consumption and authored tuning remain authoritative. The
    -- last load stays: it holds no support, and the rear brake and rolling
    -- resistance read it, so a hitch must not free the rear wheel for a step.
    self.normals={{normal_load=self.normals[1].normal_load},{normal_load=self.normals[2].normal_load}}
    self.landing_impact={false,false} self.travel_direction=0 self.air={} self.steering={}
    self.pump=Pump.new() self.pump:reset()
end
function Controller:clone()
    -- Tuning is fixed when the controller is made and nothing writes to it, so
    -- a clone shares it; every other field is copied as before. Two clones a
    -- step each copied the whole tuning table (S1 profile).
    local out={} for k,x in self do out[k]=k=="tuning" and x or M.copy(x) end
    setmetatable(out,Controller) setmetatable(out.pump,getmetatable(self.pump)) return out
end
function Controller:consumed_hop_event_id() return self.last_hop_event end
function Controller:_impl(h,measured,wheels,samples,c,recovery_mask)
    local out=result() local t=self.tuning
    local prior_normals,prior_direction,air,prior_steering,pump=M.copy(self.normals),self.travel_direction,M.copy(self.air),M.copy(self.steering),M.copy(self.pump)
    setmetatable(pump,getmetatable(self.pump)) local prior_latch=M.copy(self.pedal_latch)
    local prior_impact=M.copy(self.landing_impact)
    local prior_load={prior_normals[1].normal_load or 0,prior_normals[2].normal_load or 0}
    local prior_brake_share,prior_squeeze=self.brake_share,self.brake_squeeze
    local prior_manual=self.manual_engaged==true
    local prior_throw=M.finite(self.manual_throw_seconds) and math.max(0,self.manual_throw_seconds) or 0
    local prior_risen=self.manual_risen==true
    local prior_slowed=self.manual_slowed==true
    local prior_ground=M.unit(self.manual_ground)
    local prior_nose=self.nose_engaged==true
    local prior_nose_throw=M.finite(self.nose_throw_seconds) and math.max(0,self.nose_throw_seconds) or 0
    local prior_nose_risen=self.nose_risen==true
    local prior_nose_slowed=self.nose_slowed==true
    local prior_nose_ground=M.unit(self.nose_ground)
    local prior_nose_catch=M.finite(self.nose_catch_spent) and math.max(0,self.nose_catch_spent) or 0
    local prior_nose_air=M.finite(self.nose_air_clock) and self.nose_air_clock or -1
    local prior_nose_air_target=M.finite(self.nose_air_target) and self.nose_air_target or 0
    self.normals={{},{}} self.landing_impact={false,false} self.travel_direction=0 self.air={} self.steering={} self.pump:reset()
    if not M.finite(h) or math.abs(h-F.native_seconds)>1e-8 then out.issue="unsupported_step" return out end
    if not tuning_valid(t) or not M.valid_body(measured) or not M.vec(measured.linear_velocity,50) or not M.vec(measured.angular_velocity,40) or
        not M.valid_wheel(wheels[1]) or not M.valid_wheel(wheels[2]) then return out end
    for _,name in {"pedal","brake","steer","manual","nose_manual","air_yaw","hop_strength","ground_pump"} do if not M.finite(c[name]) then return out end end
    for _,name in {"enabled","recovery_step_verified","rotation_reserved","pump_operator_available","pump_inhibited",
        "contact_compliance_available","landing_contact_compliance_selected","manual_held","nose_manual_held"} do if type(c[name])~="boolean" then return out end end
    if not M.finite(c.hop_event_id) or c.hop_event_id<0 or c.hop_event_id%1~=0 or c.hop_event_id>9007199254740991 then return out end
    if c.contact_compliance_available~=c.landing_contact_compliance_selected then out.issue="unsupported_policy" return out end
    local landing_selected=c.contact_compliance_available and c.landing_contact_compliance_selected
    if landing_selected and not (t.recovery_fraction>0 and t.recovery_fraction<1) then out.issue="unsupported_policy" return out end
    local q=M.normalized(measured.orientation)
    local gravity_up=M.unit(M.mul(t.gravity,-1)) if not gravity_up then return out end
    local body_up,body_forward,body_left=M.turn(q,{0,1,0}),M.turn(q,{0,0,1}),M.turn(q,{1,0,0})
    local steer=c.enabled and math.clamp(c.steer,-1,1) or 0
    local contacts,next_normals={},{{},{}} local support_sum,surface_sum={0,0,0},{0,0,0} local surface_count=0
    for i=1,2 do
        local s=samples[i] if type(s)~="table" or type(s.contact)~="table" then return out end
        contacts[i]=M.copy(s.contact) local contact=contacts[i]
        -- Only this step's selected law may create solver policy fields.
        contact.normal_only,contact.normal_softness,contact.normal_floor_delta,contact.normal_deflection_limit,contact.normal_roll_free=nil,nil,nil,nil,nil
        if contact.status=="unavailable" then out.issue="unavailable_contact" return out end
        if contact.status~="hit" and contact.status~="clear" then return out end
        if contact.status=="hit" then
            local basis=M.basis(contact.normal,contact.forward)
            if not M.finite(s.separation) or not basis or not M.vec(contact.point) or not M.vec(contact.surface_velocity,50) then return out end
            contact.normal=basis.normal contact.forward=basis.forward
            if s.separation < -t.maximum_penetration then out.issue="penetration_limit" return out end
            -- Recovery policy is separate from loaded-support history. An
            -- opening wheel can lose eligibility before its penetration recovers.
            -- Keep the admitted envelope until back inside 15 mm or clear;
            -- this state never claims ground or a positive normal load.
            local closing=-M.dot(M.sub(M.point_velocity(measured,contact.point),contact.surface_velocity),basis.normal)
            local prior=prior_normals[i]
            local supported=prior.valid and prior.normal_load>0
            local recovering=prior_impact[i] and s.separation < -landing.maximum_deflection
            -- A wheel in the air may land on anything up to a 60 degree bank. A rolling wheel keeps the
            -- rigid law above 18 degrees, which is what carries it up a ramp's foot.
            local floor_plane=landing_selected and c.enabled
                and M.dot(basis.normal,gravity_up)>=(supported and landing.floor_cosine or .5)
                and M.length(contact.surface_velocity)<=landing.stationary_speed
            local landing_plane=floor_plane
                and (not supported or recovering or prior_impact[i] and closing>t.recovery_speed_limit)
            -- A distant approach ray does not arm impact recovery. Start only
            -- inside the existing contact band, not at the rear floor far below.
            local impact=landing_plane and s.separation<=landing.contact_gap and closing>t.recovery_speed_limit
            local impact_envelope=landing_plane and (impact or recovering)
            -- Loaded rolling already admitted this compression envelope. Keep
            -- it through an opening zero-load step until the measured tyre is
            -- back inside the landing band or clear. This carries deflection
            -- policy only; current support still requires fresh evidence.
            local carry_envelope=floor_plane and supported and s.separation < -landing.maximum_deflection
            self.landing_impact[i]=(impact_envelope or carry_envelope)==true
            -- The rider's legs take the first hard steps of a touchdown, which one rigid body cannot show. Levered
            -- at the tyre, they would throw a leaned bike over.
            if impact_envelope then out.landing_recovery_mask=bit32.bor(out.landing_recovery_mask,2^(i-1)) contact.normal_roll_free=true end
            -- Late one-wheel impacts cannot stop within 15 mm in one packet.
            -- Use softer finite compliance inside the unchanged gross-penetration
            -- bound; the packet's force/torque limits still decide admission.
            -- A wheel already past its band (over a ledge edge, deep in a landing) works back from where it is:
            -- refusing the step would leave the bike with no support at all and tip it over.
            local deflection_limit=(impact_envelope or supported) and t.maximum_penetration or landing.maximum_deflection
            if s.separation < -deflection_limit then deflection_limit=math.min(-s.separation,t.maximum_penetration) end
            if floor_plane then contact.normal_deflection_limit=deflection_limit end
            -- A gravity ray hits downslope from the tyre's normal projection.
            -- The gap is measured at the hub, so its normal Jacobian must use
            -- this projection in both approach and contact. Switching back to
            -- the ray hit at 5 mm changes the lever on the same measured plane.
            local exact_floor_geometry=floor_plane and s.separation<=landing.approach_gap
                and (s.wheel_center~=nil or s.wheel_radius~=nil)
            if exact_floor_geometry then
                if s.forecast_geometry_unavailable~=nil and s.forecast_geometry_unavailable~=false then
                    return result("landing_geometry_unavailable")
                end
                if not M.vec(s.wheel_center) or not M.finite(s.wheel_radius)
                    or math.abs(s.wheel_radius-wheels[i].radius)>1e-8
                    or math.abs(M.dot(M.sub(s.wheel_center,contact.point),basis.normal)-s.wheel_radius-s.separation)>1e-6 then
                    return result("landing_geometry_unavailable")
                end
                contact.point=M.sub(s.wheel_center,M.mul(basis.normal,s.separation+s.wheel_radius))
            end
            -- Use the same stopping-distance target on both sides of the
            -- positive contact band. Switching to gap/h below 5 mm permits
            -- more descent at a smaller gap, despite identical geometry.
            local floor_descent
            if floor_plane and s.separation>0 and s.separation<=landing.approach_gap then
                local ah=landing.approach_acceleration*h
                floor_descent=math.sqrt(ah*ah+2*landing.approach_acceleration*s.separation)-ah
            end
            local approach=floor_plane and s.separation>landing.contact_gap and s.separation<=landing.approach_gap
            if approach then
                -- Retain the legacy hit-only approach path. A folded sample
                -- without its forecast hub still cannot establish this geometry.
                if s.forecast_geometry_unavailable~=nil and s.forecast_geometry_unavailable~=false then
                    return result("landing_geometry_unavailable")
                end
                if not exact_floor_geometry then
                    local down=M.mul(gravity_up,-1) local dn=M.dot(down,basis.normal)
                    contact.point=M.sub(contact.point,M.mul(M.sub(down,M.mul(basis.normal,dn)),(s.separation+wheels[i].radius)/-dn))
                end
                -- For semi-implicit steps, v^2/(2*a)+v*h bounds the stopping
                -- distance. This leaves distance for a finite normal deceleration
                -- instead of demanding a full landing stop in one 60 Hz step.
                local allowed=floor_descent
                -- Preserve distant unilateral anticipation. Across the last
                -- contact band its impedance joins the tyre law continuously,
                -- rather than changing from rigid to soft in one delayed step.
                local band=math.max(t.contact_gap,2*landing.contact_gap)
                local blend=math.clamp((band-s.separation)/(band-landing.contact_gap),0,1)
                blend=blend*blend*(3-2*blend)
                contact.normal_softness=blend*floor_softness(h,measured,contact,basis,t.recovery_fraction)
                if contact.normal_softness>0 then
                    out.compliant_normal_mask=bit32.bor(out.compliant_normal_mask,2^(i-1))
                end
                contact.surface_velocity=M.sub(contact.surface_velocity,M.mul(basis.normal,allowed))
                contact.normal_only=true
                out.landing_approach_mask=bit32.bor(out.landing_approach_mask,2^(i-1))
            elseif s.separation>t.contact_gap then contact.status="clear"
            else
                local balance=basis.normal if s.balance_normal_available then balance=M.unit(s.balance_normal) if not balance or M.dot(balance,basis.normal)<=0 then return out end end
                surface_sum=M.add(surface_sum,contact.surface_velocity) surface_count+=1
                local actual=F.eligible_support(measured,s,.005,t.maximum_penetration) if actual then out.grounded=true end
                local continuation=not actual and bit32.band(recovery_mask,2^(i-1))~=0
                if not actual and not continuation and c.enabled and prior_normals[i].valid and prior_normals[i].normal_load>0 and s.separation<=.005 then
                    local relative=M.sub(M.point_velocity(measured,contact.point),contact.surface_velocity)
                    local opening,gravity_normal=M.dot(relative,basis.normal),M.dot(t.gravity,basis.normal)
                    local angle=math.atan2(M.length(M.cross(prior_normals[i].normal,basis.normal)),math.clamp(M.dot(prior_normals[i].normal,basis.normal),-1,1))
                    continuation=M.vec(relative) and opening>0 and gravity_normal<0 and opening+gravity_normal*h<=0 and angle<=t.curvature_step_limit
                end
                if actual or continuation then
                    next_normals[i]={valid=true,normal=basis.normal,normal_load=0,balance_normal=balance}
                    if continuation then out.balance_continuation_mask=bit32.bor(out.balance_continuation_mask,2^(i-1)) end
                end
                local bias=math.min(t.recovery_speed_limit,t.recovery_fraction*math.max(0,-s.separation)/h) out.recovery_velocity[i]=bias
                if next_normals[i].valid then
                    local history=next_normals[i]
                    history.point=contact.point history.surface_velocity=M.copy(s.contact.surface_velocity) history.separation=s.separation history.recovery_velocity=bias
                    history.verified_plane=s.verified_plane history.recovery_seconds=actual and 0 or (prior_normals[i].recovery_seconds or 0)+h
                    history.recovery_seeded=c.recovery_step_verified and s.verified_plane and s.separation<0 and (actual or prior_normals[i].recovery_seeded)
                end
                local target=bias-(floor_descent or math.max(0,s.separation)/h)
                if floor_plane then
                    -- Supported rolling keeps its original gross envelope,
                    -- with the same finite impedance as touchdown/recovery.
                    contact.normal_softness=floor_softness(h,measured,contact,basis,t.recovery_fraction)
                    contact.normal_floor_delta=(-deflection_limit-s.separation)/h-target
                    out.compliant_normal_mask=bit32.bor(out.compliant_normal_mask,2^(i-1))
                end
                contact.surface_velocity=M.add(contact.surface_velocity,M.mul(basis.normal,target))
            end
        end
    end
    local previous_mask,support_mask=0,0
    for i=1,2 do if prior_normals[i].valid then previous_mask=bit32.bor(previous_mask,2^(i-1)) end if next_normals[i].valid then support_mask=bit32.bor(support_mask,2^(i-1)) end end
    local surface=surface_count>0 and M.mul(surface_sum,1/surface_count) or {0,0,0}
    local speed=M.dot(M.sub(measured.linear_velocity,surface),body_forward)
    local direction=math.abs(speed)>=.25 and (speed>0 and 1 or -1) or 0
    if direction~=0 and prior_direction~=0 and direction~=prior_direction then
        prior_normals={{},{}} for i=1,2 do if bit32.band(out.balance_continuation_mask,2^(i-1))~=0 then next_normals[i]={} end end
        out.balance_continuation_mask=0 support_mask=0 for i=1,2 do if next_normals[i].valid then support_mask=bit32.bor(support_mask,2^(i-1)) end end
    end
    if previous_mask~=support_mask then prior_normals={{},{}} end
    out.balance_support_mask=support_mask for _,s in next_normals do if s.valid then support_sum=M.add(support_sum,s.balance_normal) end end
    if support_mask~=0 and math.abs(speed)>=t.curvature_min_speed then
        local transport,count={0,0,0},0
        for i=1,2 do if next_normals[i].valid and prior_normals[i].valid then
            local axis=M.cross(prior_normals[i].balance_normal,next_normals[i].balance_normal) local sine=M.length(axis)
            local angle=math.atan2(sine,math.clamp(M.dot(prior_normals[i].balance_normal,next_normals[i].balance_normal),-1,1))
            if angle<=t.curvature_step_limit then local rate=sine>1e-10 and M.mul(axis,math.min(angle/h,t.curvature_rate_limit)/sine) or {0,0,0} transport=M.add(transport,rate) count+=1 end
        end end
        if count>0 then out.desired_support_angular_velocity=M.mul(transport,1/count) end
    end
    out.requested_front_steer_angle=-steer*t.steer_limit/(1+math.abs(speed)/t.steer_speed_scale) out.front_steer_angle=out.requested_front_steer_angle
    local axis=M.unit(M.turn(q,steering_axis)) if not axis then return out end
    local up=support_mask~=0 and M.unit(support_sum) or nil
    local forward=up and M.unit(M.sub(body_forward,M.mul(up,M.dot(body_forward,up)))) or nil
    local balance_frame=up~=nil and forward~=nil
    -- A manual starts on the rear wheel with the stick in its band, rolling at least manual_min_speed. It lasts
    -- while the front is up, so a release still has the law below to put a bike past its balance back down, and
    -- ends in the air, on the front wheel alone, or on both wheels with the stick let go. On both wheels it starts
    -- only from manual_start_speed and goes on down to manual_min_speed, and not with B held: with no throw while
    -- braking it cut the pedal and drew the rider shifted all the way back on a bike that stayed level. Its speed is
    -- the one along the surface. Along the pitched body it read cos(pitch) of the true speed, so a 28 degree manual
    -- came down at 1.13 m/s and, on both wheels still above manual_min_speed, was thrown up again.
    local manual_amount=c.enabled and math.clamp(c.manual,0,1) or 0
    local brake_wanted=c.enabled and math.clamp(c.brake,0,1) or 0
    local manual_speed=forward and M.dot(M.sub(measured.linear_velocity,surface),forward) or speed
    local rear_support,front_support=bit32.band(support_mask,2)~=0,bit32.band(support_mask,1)~=0
    -- A manual that slowed to a walk with the stick still in its band does not start again until the stick is let
    -- go. Up a 10 degree street grade with A held, the bike pedalled to manual_start_speed, lifted, fell below
    -- manual_min_speed in .4 s, put the front down and pedalled again: four lifts in 6 s, the cranks starting and
    -- stopping each time. A manual ended by B is not one: let go of B with the stick held, it lifts again. The
    -- stick is let go when it no longer holds a manual (manual_held), not on a step the manual is zero because no
    -- wheel was on the ground: up a grade with a 2 to 5 cm bump every 3 m, each such step let the bike lift
    -- again, 8 or 9 manuals in 20 s.
    local slowed=prior_slowed and (manual_amount>0 or c.enabled and c.manual_held)
    local manual_engaged=false
    if rear_support and c.enabled and contacts[2].status=="hit" then
        if front_support then
            manual_engaged=manual_amount>0 and brake_wanted<=0 and
                (prior_manual and manual_speed>=t.manual_min_speed or not slowed and manual_speed>=t.manual_start_speed)
        else
            manual_engaged=prior_manual or not slowed and manual_amount>0 and manual_speed>=t.manual_min_speed
        end
    end
    local manual_wanted=manual_engaged and manual_amount>0 and manual_speed>=t.manual_min_speed
    -- It is set on the step such a manual ends on both wheels: up a grade or on the flat the front comes down under
    -- a walk, so that is where it ends. Set on the rear wheel alone as well, one kerb bevel row under it ({0,.35,
    -- -.94}) tilted the balance frame's forward nearly upright for its step, read 1.6 to 2.5 m/s as .53 to .84, and
    -- the manual it then dropped for that step never came back with the stick held.
    slowed=slowed or prior_manual and front_support and manual_amount>0 and brake_wanted<=0 and manual_speed<t.manual_min_speed
    local carving=manual_engaged and not front_support
    -- The rear tyre pushes along the surface's normal, so the balance is the centre of mass over the contact along
    -- that normal. Measured level instead, a bike rolling down a 15% ramp looped out and one going up 8% chattered
    -- at the bottom of the window; along the normal all of them hold the same manual against the surface.
    -- How far ahead it sits against the ground the lift started from as well: the surface under the rear wheel
    -- when the front last had support, held while the front is up. A bump's or a kicker's face met during the lift
    -- does not tilt it, and on a uniform grade it is the grade, so there the two offsets are the same.
    local manual_d,manual_v,manual_level,manual_ground=0,0,0,nil
    if manual_engaged then
        if not balance_frame then return out end
        local rel=M.sub(measured.center_of_mass,contacts[2].point)
        manual_d,manual_v=M.dot(rel,forward),M.dot(rel,up)
        manual_ground=not front_support and prior_ground or up
        local level=M.unit(M.sub(body_forward,M.mul(manual_ground,M.dot(body_forward,manual_ground))))
        manual_level=level and M.dot(rel,level) or manual_d
    end
    -- Whether the front has come up to the stick's offset since it left the ground: the throw above 17.9 degrees
    -- is the lift's only (see manual_pull).
    local risen=prior_risen and manual_engaged and not front_support
    -- Let go below the balance point, the ordinary spring sets the front down. Past it, the law brings the bike
    -- back toward the low target, under the same limits, so letting go is no save beyond what the rider can do.
    -- The step a hop pops, the rider pushes the bars forward as they spring, on either side of the balance, so the
    -- spring takes the pitch there too. With the law past the balance, a hop from just above it took a 156 N*m
    -- nudge and landed at 33 to 37 degrees on the back wheel, and one from just below took the spring's 900 and
    -- landed at 9.
    local popping=c.enabled and out.grounded and c.hop_event_id>self.last_hop_event and math.clamp(c.hop_strength,0,1)>0
    local manual_law=manual_engaged and (manual_wanted or manual_d<0 and not popping)
    -- A nose manual is the same on the front wheel: it starts there with the stick forward in its band, from
    -- manual_start_speed on both wheels and not with B held, lasts while the rear is up, and ends in the air, on the
    -- rear alone, or on both wheels with the stick let go. A manual on the rear wheel comes first. The walk latch is
    -- the manual's, on its own stick (nose_manual_held). Its offset is how far the centre of mass sits behind the
    -- front contact, along the surface under the front wheel and against the ground the lift started from.
    local nose_amount=c.enabled and math.clamp(c.nose_manual,0,1) or 0
    local nose_slowed=prior_nose_slowed and (nose_amount>0 or c.enabled and c.nose_manual_held)
    local nose_engaged=false
    if not manual_engaged and front_support and c.enabled and contacts[1].status=="hit" then
        if rear_support then
            nose_engaged=nose_amount>0 and brake_wanted<=0 and
                (prior_nose and manual_speed>=t.manual_min_speed or not nose_slowed and manual_speed>=t.manual_start_speed)
        else
            nose_engaged=prior_nose or not nose_slowed and nose_amount>0 and manual_speed>=t.manual_min_speed
        end
    end
    local nose_wanted=nose_engaged and nose_amount>0 and brake_wanted<=0 and manual_speed>=t.manual_min_speed
    nose_slowed=nose_slowed or prior_nose and rear_support and nose_amount>0 and brake_wanted<=0 and manual_speed<t.manual_min_speed
    local nose_carving=nose_engaged and not rear_support
    local nose_d,nose_v,nose_level,nose_ground=0,0,0,nil
    if nose_engaged then
        if not balance_frame then return out end
        local rel=M.sub(measured.center_of_mass,contacts[1].point)
        nose_d,nose_v=-M.dot(rel,forward),M.dot(rel,up)
        nose_ground=not rear_support and prior_nose_ground or up
        local level=M.unit(M.sub(body_forward,M.mul(nose_ground,M.dot(body_forward,nose_ground))))
        nose_level=level and -M.dot(rel,level) or nose_d
    end
    local nose_risen=prior_nose_risen and nose_engaged and not rear_support
    -- Let go below the balance, the spring sets the rear down; past it the law brings the bike back to nose_low
    -- under the same limits, and the step a hop pops the spring takes the pitch, as for the manual.
    local nose_law=nose_engaged and (nose_wanted or nose_d<0 and not popping)
    local nose_throw=brake_wanted<=0 and (rear_support or prior_nose_throw<t.manual_pull_seconds)
    local nose_catch_left,nose_catching=prior_nose_catch<t.nose_catch_seconds,false
    local nose_air_aim=nil
    -- The throw is the rider's for manual_pull_seconds below the hold, and not while braking.
    local throw=brake_wanted<=0 and (front_support or prior_throw<t.manual_pull_seconds)
    -- This is a body-local joint angle, so its accepted history remains valid
    -- when support disappears. Slew the same joint through loss/reacquisition;
    -- support, balance and raw air-trick intent keep their independent gates.
    if c.enabled and prior_steering.valid then
        local gain=t.steer_limit/(1+math.abs(speed)/t.steer_speed_scale) local u=math.clamp(math.abs(speed)/30,0,1)
        local rate_delta=(5-3*u*u*(3-2*u))*gain*h
        local joint_delta=math.clamp(6*h,0,1)*math.abs(out.requested_front_steer_angle-prior_steering.angle)
        local delta=math.min(rate_delta,joint_delta) out.front_steer_angle=math.clamp(out.requested_front_steer_angle,prior_steering.angle-delta,prior_steering.angle+delta)
    end
    local candidate_angle=out.front_steer_angle
    local brake_share=prior_brake_share+math.clamp(brake_wanted-prior_brake_share,-h/BRAKE_SQUEEZE_SECONDS,h/BRAKE_SQUEEZE_SECONDS)
    local front_heading=contacts[1].status=="hit" and not contacts[1].normal_only and contacts[1].forward or body_forward
    local function heading(angle)
        local front=balance_frame and M.basis(up,M.around(front_heading,axis,angle)) or nil if not front then return nil end
        local value=math.atan2(M.dot(up,M.cross(forward,front.forward)),math.clamp(M.dot(forward,front.forward),-1,1))
        return M.finite(value) and math.abs(value)<1.4 and value or nil
    end
    if balance_frame and M.dot(body_up,up)>.2 then
        local turn=heading(out.front_steer_angle) if turn==nil then return out end
        local maximum=math.atan2(M.length(t.gravity)*t.wheelbase*math.tan(t.lean_limit)*(1-t.brake_lateral_cut*brake_share),speed*speed)
        if math.abs(turn)>maximum then
            local low,high=0,1 for _=1,40 do local middle=(low+high)*.5 local trial=heading(candidate_angle*middle) if trial==nil then return out end if math.abs(trial)<=maximum then low=middle else high=middle end end
            out.front_steer_angle=candidate_angle*low out.steering_limited=true turn=heading(out.front_steer_angle) if turn==nil then return out end
        end
        out.turning_lean_angle=math.atan(-speed*speed*math.tan(turn)/(M.length(t.gravity)*t.wheelbase))
    end
    -- The lifted front corners nothing: its row is normal only. The lean the bars asked for leaned the bike and
    -- yawed it the wrong way (+.48 rad/s at 29 degrees). In a manual the bars carve: a yaw rate the rider turns the
    -- bike through, and the lean that turn needs.
    if carving then
        out.manual_carve_rate=-steer*t.manual_carve_rate*math.clamp(math.abs(speed)/2,0,1)
        out.turning_lean_angle=math.atan(-speed*out.manual_carve_rate/M.length(t.gravity))
    end
    -- On its front wheel the rider swings the rear round it. The lean follows the yaw the bike has, and the bars
    -- turn no further than the contact's own path, nose_d ahead of the centre of mass.
    if nose_carving then
        out.manual_carve_rate=-steer*math.min(t.nose_carve_rate*math.clamp(math.abs(speed)/2,0,1),t.nose_carve_lateral/math.max(math.abs(speed),.1))
        out.turning_lean_angle=math.atan(-manual_speed*M.dot(measured.angular_velocity,up)/M.length(t.gravity))
        if balance_frame and M.dot(body_up,up)>.2 then
            local most=math.atan(math.abs(out.manual_carve_rate)*math.max(nose_d,0)/math.max(math.abs(speed),.5))
            local turn=heading(out.front_steer_angle)
            if turn and math.abs(turn)>most then
                local low,high=0,1
                for _=1,40 do local middle=(low+high)*.5 local trial=heading(out.front_steer_angle*middle) if trial==nil then return out end
                    if math.abs(trial)<=most then low=middle else high=middle end end
                out.front_steer_angle=out.front_steer_angle*low out.steering_limited=true
            end
        end
    end
    local wheel_axes={}
    for i=1,2 do
        if contacts[i].status=="hit" and not contacts[i].normal_only then
            if i==1 then contacts[i].forward=M.around(contacts[i].forward,axis,out.front_steer_angle) end
            local wheel_basis=M.basis(contacts[i].normal,contacts[i].forward) if not wheel_basis then return out end
            wheel_axes[i]=wheel_basis.lateral
        else
            -- Retain the zero-camber wheel model using body/joint policy only.
            -- This frame is not observed terrain and never becomes contact geometry.
            if i==1 then
                local wheel_basis=M.basis(body_up,M.around(body_forward,axis,out.front_steer_angle))
                if not wheel_basis then return out end
                wheel_axes[i]=wheel_basis.lateral
            else wheel_axes[i]=body_left end
        end
    end
    -- A tyre grips under its own section, not under the hub. A leaned wheel rolls onto its shoulder, which brings
    -- the side force in under the rider: with the point under the hub the balance spring held 273 N*m through a
    -- turn, and let go of it at every hop.
    for i=1,2 do local contact=contacts[i]
        if contact.status=="hit" and not contact.normal_only and samples[i].wheel_center then
            local n,sine=contact.normal,M.dot(contact.normal,body_left)
            local down=M.mul(M.sub(n,M.mul(body_left,sine)),-1/math.sqrt(math.max(1e-6,1-sine*sine)))
            local tangent=M.sub(down,M.mul(n,M.dot(down,n)))
            local lateral=M.cross(n,contact.forward)
            local want=(wheels[i].radius-t.tyre_section_radius)*M.dot(tangent,lateral)
            local have=M.dot(M.sub(contact.point,samples[i].wheel_center),lateral)
            contact.point=M.add(contact.point,M.mul(lateral,want-have))
        end
    end
    local motor_speed=math.max(0,speed,wheels[2].angular_speed*wheels[2].radius)
    local brake=prior_squeeze+math.clamp(brake_wanted-prior_squeeze,-h/BRAKE_RELEASE_SECONDS,h/BRAKE_SQUEEZE_SECONDS)
    local braking=brake>0 and (t.front_brake_torque>0 or t.rear_brake_torque>0)
    -- The brake takes priority over a held pedal. Feed the same decision to
    -- the motor, pump and drawn crank rather than driving against the brake.
    -- Keeping the existing latch still prevents a brake tap from resetting
    -- a spin-out while speed remains above the resume threshold. A manual
    -- coasts: the drive at the rear contact, about a metre under the centre of
    -- mass, lifts the nose by 170 to 300 N*m, more than the 156 N*m the rider
    -- can lean forward, so a pedalled manual loops out at once. The cranks then
    -- stay still with it, and the top-speed latch is left as it was. A nose
    -- manual coasts too: its driven rear wheel is in the air.
    local cadence,next_latch=F.pedal_cadence(prior_latch,{enabled=c.enabled,pedal=(braking or manual_engaged or nose_engaged) and 0 or math.clamp(c.pedal,0,1),motor_speed=motor_speed,
        top_speed=t.pedal_top_speed,resume_speed=t.pedal_resume_speed})
    if not cadence.valid then return out end out.pedaling=cadence.pedaling
    local pedal_scale=math.clamp((t.pedal_cutoff-motor_speed)/(t.pedal_cutoff-t.pedal_fade_start),0,1)
    -- Torque times wheel speed is the rider's power; past rider_power the push falls as the bike goes faster.
    pedal_scale*=math.min(1,t.rider_power*wheels[2].radius/(t.pedal_torque*math.max(motor_speed,.01)))
    local pedal=cadence.pedaling and math.clamp(c.pedal,0,1)*pedal_scale or 0
    local pitch=c.enabled and math.clamp(c.nose_manual,0,1)-math.clamp(c.manual,0,1) or 0
    local assist={0,0,0} local world_up=M.unit(M.mul(t.gravity,-1)) if not world_up then return out end
    if support_mask~=0 then
        if not balance_frame then return out end out.balance_reference_up=up
        if M.dot(body_up,up)>.2 then
            -- Two wheels fix pitch to the surface, but nothing fixes roll to it. A bike's roll is set by gravity and
            -- the corner, so crossing a bank it stays near plumb instead of adding the bank to its lean. The limit
            -- is the most camber allowed against the surface, which keeps the tyres on a very steep one.
            local lateral=M.cross(up,forward)
            local plumb=M.unit(M.sub(world_up,M.mul(forward,M.dot(world_up,forward))))
            local neutral=plumb and math.atan2(M.dot(forward,M.cross(up,plumb)),M.dot(up,plumb)) or 0
            local roll=math.clamp(neutral+out.turning_lean_angle,-MAXIMUM_CAMBER,MAXIMUM_CAMBER)
            -- In a manual the spring keeps only the roll: it is aimed at the body's own pitch, and what pitch it
            -- has left is taken out below, where the manual law sets the pitch instead.
            local tilt=(manual_law or nose_law) and math.atan2(M.dot(body_up,forward),M.dot(body_up,up)) or 0
            local desired=M.around(M.around(up,lateral,tilt),forward,roll)
            out.desired_balance_up=desired
            local omega=M.sub(measured.angular_velocity,M.mul(up,M.dot(measured.angular_velocity,up)))
            local desired_omega=M.sub(out.desired_support_angular_velocity,M.mul(up,M.dot(out.desired_support_angular_velocity,up)))
            assist=M.limited(M.sub(M.mul(M.cross(body_up,desired),t.balance_stiffness),M.mul(M.sub(omega,desired_omega),t.balance_damping)),t.balance_torque_limit)
            local weight=measured.mass*math.max(0,-M.dot(t.gravity,up))
            if manual_law then
                -- The pitch couple is the rider's weight shift. It carries the weight at the offset the bike has
                -- (N*d), and turns the bike toward the target at no more than manual_rate, damped; whatever it asks
                -- is held to the shift a rider has, back and forward, with a throw allowed only low down.
                assist=M.sub(assist,M.mul(lateral,M.dot(assist,lateral)))
                local target=manual_wanted and t.manual_low+(t.manual_high-t.manual_low)*manual_amount or t.manual_low
                local reach=math.sqrt(manual_d*manual_d+manual_v*manual_v)
                -- The nose-up turn still needed to bring the centre of mass to the target offset.
                local delta=math.acos(math.clamp(target/reach,-1,1))-math.atan2(manual_v,manual_d)
                local rate=-M.dot(measured.angular_velocity,lateral)
                local want=math.clamp(t.manual_gain*delta,-t.manual_rate,t.manual_rate)
                local couple=weight*manual_d+t.manual_damping*(want-rate)
                -- On the way up the throw fades out above manual_hold_back, once the front is up below it; until
                -- then on no more than manual_face_offset past the offset against the ground the lift started from.
                local fade=risen and t.manual_hold_back or t.manual_hold_back-t.manual_pull_ramp
                local judged=risen and manual_d or math.min(manual_d,manual_level+t.manual_face_offset)
                local ramp=throw and math.clamp((judged-fade)/t.manual_pull_ramp,0,1) or 0
                local up_cap=weight*t.manual_hold_back+ramp*math.max(0,t.manual_pull-weight*t.manual_hold_back)
                couple=math.clamp(couple,-weight*t.manual_hold_forward,up_cap)
                assist=M.add(assist,M.mul(lateral,-couple))
                out.manual_target_offset=target
                if not front_support and math.min(manual_d,manual_level)<=target+t.manual_risen_slack then risen=true end
            end
            if nose_law then
                -- The same law mirrored: the couple is nose down positive (along lateral), the throw pushes the
                -- front down to lift the rear, and the pull back is the rider's static limit, or the catch.
                assist=M.sub(assist,M.mul(lateral,M.dot(assist,lateral)))
                local target=nose_wanted and t.nose_low+(t.nose_high-t.nose_low)*nose_amount or t.nose_low
                local reach=math.sqrt(nose_d*nose_d+nose_v*nose_v)
                local delta=math.acos(math.clamp(target/reach,-1,1))-math.atan2(nose_v,nose_d)
                local rate=M.dot(measured.angular_velocity,lateral)
                local want=math.clamp(t.manual_gain*delta,-t.manual_rate,t.manual_rate)
                local couple=weight*nose_d+t.manual_damping*(want-rate)
                local fade=nose_risen and t.nose_hold_forward or t.nose_hold_forward-t.manual_pull_ramp
                local judged=nose_risen and nose_d or math.min(nose_d,nose_level+t.manual_face_offset)
                local ramp=nose_throw and math.clamp((judged-fade)/t.manual_pull_ramp,0,1) or 0
                local down_cap=weight*t.nose_hold_forward+ramp*math.max(0,t.manual_pull-weight*t.nose_hold_forward)
                -- Tipping on over the bars faster than the law asks, the rider snaps the weight back. Only the steps
                -- it pulls past the static limit spend nose_catch_seconds: counted from the first step it was
                -- allowed, the lift itself spent 17 to 22 steps of it and the catch was gone when a kerb came.
                local catch=nose_catch_left and math.clamp((rate-t.nose_catch_rate)/t.nose_catch_span,0,1) or 0
                local back_cap=math.max(weight*t.nose_hold_back,catch*t.nose_catch_torque)
                if not rear_support and couple< -weight*t.nose_hold_back and catch>0 then nose_catching=true end
                couple=math.clamp(couple,-back_cap,down_cap)
                assist=M.add(assist,M.mul(lateral,couple))
                out.manual_target_offset=target
                -- The angle to the ground the lift started from that the law aims at, for the air hold.
                nose_air_aim=math.asin(math.clamp(-M.dot(body_forward,nose_ground),-1,1))+delta
                if not rear_support and math.min(nose_d,nose_level)<=target+t.manual_risen_slack then nose_risen=true end
            end
            if nose_carving then
                -- The front tyre's side force acts nose_d ahead of the centre of mass, so a yaw grows by itself at
                -- mass*speed*nose_d per rad/s; the rider's twist takes that out and carves toward the asked rate.
                -- The spring's yaw part through the pitched body fed the runaway, so the twist owns yaw here.
                local yaw_rate=M.dot(measured.angular_velocity,up)
                local lever=measured.mass*math.max(manual_speed,0)*math.max(nose_d,0)
                assist=M.sub(assist,M.mul(up,M.dot(assist,up)))
                assist=M.add(assist,M.mul(forward,M.dot(assist,forward)*(t.nose_roll_gain-1)))
                out.nose_yaw_couple=math.clamp(-lever*yaw_rate+t.nose_yaw_damping*(out.manual_carve_rate-yaw_rate),-t.nose_yaw_torque,t.nose_yaw_torque)
                assist=M.add(assist,M.mul(up,out.nose_yaw_couple))
            end
            if carving then
                local yaw_rate=M.dot(measured.angular_velocity,up)
                assist=M.add(assist,M.mul(up,math.clamp(t.manual_carve_damping*(out.manual_carve_rate-yaw_rate),-t.manual_carve_torque,t.manual_carve_torque)))
            end
            if manual_engaged or nose_engaged then
                assist=M.limited(assist,t.balance_torque_limit)
                -- What the pose shows: the pitch couple this step applies, nose up positive, as the rider's shift.
                out.manual_couple=-M.dot(assist,lateral)
                out.manual_shift=weight>0 and out.manual_couple/weight or 0
            end
            out.balance_torque=assist
        end
    elseif c.enabled then assist=M.add(M.mul(world_up,-math.clamp(c.air_yaw,-1,1)*t.air_yaw_torque),M.mul(body_left,pitch*t.air_pitch_torque)) out.air_control_torque=assist
        -- Thrown off the front by a bump or a kerb's top from a nose manual, the stick still held and no hop
        -- popping, the rider holds the angle the law last aimed at against the ground the lift started from.
        if prior_nose_air>=0 and prior_nose_air<t.nose_air_seconds and c.nose_manual_held and prior_nose_ground and c.hop_event_id<=self.last_hop_event then
            local now=math.asin(math.clamp(-M.dot(body_forward,prior_nose_ground),-1,1))
            local want=math.clamp(t.manual_gain*(prior_nose_air_target-now),-t.manual_rate,t.manual_rate)
            out.nose_air_couple=math.clamp(t.manual_damping*(want-M.dot(measured.angular_velocity,body_left)),-t.air_pitch_torque,t.air_pitch_torque)
            assist=M.add(assist,M.mul(body_left,out.nose_air_couple)) out.air_control_torque=assist
        end
    end
    local intent=c.rotation_reserved or c.manual~=0 or c.nose_manual~=0 or c.steer~=0 or c.air_yaw~=0 or c.brake>0
    local launch=c.rotation_reserved or c.manual~=0 or c.nose_manual~=0 or c.brake>0
    local neutral=reservation(air,c.recovery_step_verified,c.enabled,false,intent,launch)
    out.air_rotation_reserved=air.reserved==true
    -- Long landing rays may hit while neither tyre supports the bike. Keep
    -- ordinary steering from leaving that unsupported angular motion undamped.
    -- This is passive torque only, outside impact recovery; it grants no support
    -- and leaves explicit air rotations and the existing damping cap unchanged.
    local passive_landing=landing_selected and c.enabled and support_mask==0 and out.landing_recovery_mask==0
        and not c.rotation_reserved and c.manual==0 and c.nose_manual==0 and c.air_yaw==0
    if (neutral and contacts[1].status=="clear" and contacts[2].status=="clear") or passive_landing then
        local rate=t.neutral_air_damping_rate local cap=math.min(t.air_pitch_torque,t.air_yaw_torque)
        if rate>0 and cap>0 then out.air_damping_torque=M.limited(M.mul(M.tensor(measured,measured.angular_velocity,false),-rate/(1+rate*h)),cap) end
        out.neutral_air_damping_active=M.length(out.air_damping_torque)>0 assist=M.add(assist,out.air_damping_torque)
    end
    local prediction=M.copy(measured) local gravity_delta=M.mul(t.gravity,h) prediction.linear_velocity=M.add(prediction.linear_velocity,gravity_delta)
    prediction.linear_velocity=M.add(prediction.linear_velocity,M.mul(measured.linear_velocity,-t.air_drag*M.length(measured.linear_velocity)*h/measured.mass))
    out.pump=pump:step(h,{enabled=c.enabled,operator_available=c.pump_operator_available,supported=out.grounded,inhibited=c.pump_inhibited or c.hop_strength>0,
        input=c.ground_pump,manual=c.manual,nose_manual=c.nose_manual,world_upward_speed=measured.linear_velocity[2],pedal=cadence.pedaling and c.pedal or 0})
    if not out.pump.valid then return result() end
    out.pump_force={0,-measured.mass*out.pump.down_acceleration,0}
    prediction.linear_velocity=M.add(prediction.linear_velocity,M.mul(out.pump_force,h/measured.mass))
    prediction.angular_velocity=M.add(prediction.angular_velocity,M.tensor(measured,M.mul(assist,h),true))
    local new_event=c.hop_event_id>self.last_hop_event
    if new_event and c.enabled and out.grounded and math.clamp(c.hop_strength,0,1)>0 then
        out.hop_impulse=M.mul(world_up,measured.mass*t.hop_delta_speed*math.clamp(c.hop_strength,0,1))
        prediction.linear_velocity=M.add(prediction.linear_velocity,M.mul(out.hop_impulse,1/measured.mass)) out.hop_applied=true out.hop_event_id=c.hop_event_id
    end
    out.wheels=M.copy(wheels)
    for i=1,2 do
        -- The contact-free drive stage needs an axle, not a fabricated clear plane.
        -- Rolling resistance slows a wheel by its load, and stops it without ever turning it backward.
        local spin=out.wheels[i].angular_speed
        local rolling=-(spin>=0 and 1 or -1)*math.min(t.rolling_resistance*prior_load[i]*wheels[i].radius*h,math.abs(spin)*wheels[i].inertia)
        local b,w=Tire.axle_couple(prediction,out.wheels[i],wheel_axes[i],(i==2 and pedal*t.pedal_torque or 0)*h+rolling)
        if not b then return result() end prediction=b out.wheels[i]=w
    end
    local actuated,actuated_wheels=M.copy(prediction),M.copy(out.wheels)
    out.pre_contact_prediction=M.copy(actuated) out.pre_contact_prediction_available=true
    local effects
    -- Last step's load, and no cap in the air, so B still stops the wheels there.
    local rear_grounded=contacts[2].status=="hit" and not contacts[2].normal_only
    local rear_limit=rear_grounded and t.rear_brake_load_share*t.friction.longitudinal_friction*prior_load[2]*wheels[2].radius or nil
    prediction,out.wheels,effects=Solver.solve(h,prediction,out.wheels,contacts,t,brake,wheel_axes,rear_limit)
    if not prediction then return result() end
    local base_linear=M.sub(M.mul(M.sub(M.sub(actuated.linear_velocity,measured.linear_velocity),gravity_delta),measured.mass),out.hop_impulse)
    local base_angular=M.tensor(measured,M.sub(actuated.angular_velocity,measured.angular_velocity),false)
    local contact_linear=M.mul(M.sub(prediction.linear_velocity,actuated.linear_velocity),measured.mass)
    local contact_angular=M.tensor(measured,M.sub(prediction.angular_velocity,actuated.angular_velocity),false)
    local force_budget,torque_budget=t.force_limit*h*(1-1e-6),t.torque_limit*h*(1-1e-6)
    local amount=math.min(fraction(base_linear,contact_linear,force_budget),fraction(M.add(base_linear,out.hop_impulse),contact_linear,force_budget),fraction(base_angular,contact_angular,torque_budget))
    for i=1,2 do amount=math.min(amount,fraction({actuated_wheels[i].angular_speed,0,0},{braking and out.wheels[i].angular_speed-actuated_wheels[i].angular_speed or effects[i].spin,0,0},t.wheel_speed_limit)) end
    if amount<0 then return result("output_limit") end out.contact_scale=amount
    out.linear_impulse=M.add(base_linear,M.mul(contact_linear,amount)) out.angular_impulse=M.add(base_angular,M.mul(contact_angular,amount))
    out.force=M.mul(out.linear_impulse,1/h) out.torque=M.mul(out.angular_impulse,1/h)
    out.motor_torque=M.sub(M.mul(base_angular,1/h),assist) out.contact_torque=M.mul(contact_angular,amount/h)
    for i=1,2 do
        out.wheels[i].angular_speed=actuated_wheels[i].angular_speed+amount*(braking and out.wheels[i].angular_speed-actuated_wheels[i].angular_speed or effects[i].spin)
        out.brake_impulse[i]=amount*effects[i].brake out.normal_impulse[i]=amount*effects[i].solved.normal_impulse out.normal_load[i]=out.normal_impulse[i]/h
        out.longitudinal_impulse[i]=amount*effects[i].solved.longitudinal_impulse out.lateral_impulse[i]=amount*effects[i].solved.lateral_impulse
        out.approach_normal_impulse[i]=amount*(effects[i].solved.approach_impulse or 0)
        out.approach_normal_force[i]=out.approach_normal_impulse[i]/h
    end
    if not M.vec(out.force) or not M.vec(out.torque) or M.length(out.force)>t.force_limit or M.length(M.mul(M.add(out.linear_impulse,out.hop_impulse),1/h))>t.force_limit or
        M.length(out.torque)>t.torque_limit or math.abs(out.wheels[1].angular_speed)>t.wheel_speed_limit or math.abs(out.wheels[2].angular_speed)>t.wheel_speed_limit then return result("output_limit") end
    if new_event then self.last_hop_event=c.hop_event_id end
    if support_mask~=0 and not out.hop_applied and c.enabled then
        for i=1,2 do next_normals[i].normal_load=out.normal_load[i] end self.normals=next_normals self.travel_direction=direction~=0 and direction or prior_direction
    end
    local loaded=false for i=1,2 do loaded=loaded or (out.normal_load[i]>0 and F.eligible_support(measured,samples[i],.005,t.maximum_penetration)) end
    if loaded and not out.hop_applied then reservation(air,c.recovery_step_verified,c.enabled,true,intent,launch) end
    self.air=air out.air_rotation_reserved=air.reserved==true if c.enabled then self.steering={valid=true,angle=out.front_steer_angle} end
    self.brake_share=brake_share self.brake_squeeze=brake
    out.manual_active=manual_engaged out.manual_offset=manual_d self.manual_engaged=manual_engaged self.manual_slowed=slowed
    self.manual_throw_seconds=manual_engaged and not front_support and manual_d>t.manual_hold_back and prior_throw+h or 0
    self.manual_risen=risen self.manual_ground=manual_ground
    out.nose_manual_active=nose_engaged out.nose_manual_offset=nose_d self.nose_engaged=nose_engaged self.nose_slowed=nose_slowed
    self.nose_throw_seconds=nose_engaged and not rear_support and nose_d>t.nose_hold_forward and prior_nose_throw+h or 0
    self.nose_risen=nose_risen self.nose_ground=nose_ground
    self.nose_catch_spent=nose_engaged and not rear_support and prior_nose_catch+(nose_catching and h or 0) or 0
    -- The air hold's clock: 0 on a step on the front with the rear up, counting in the air after one, off otherwise.
    if out.hop_applied then self.nose_air_clock,self.nose_air_target=-1,0
    elseif nose_engaged and not rear_support then self.nose_air_clock,self.nose_air_target=0,nose_air_aim or prior_nose_air_target
    elseif support_mask==0 and prior_nose_air>=0 then self.nose_air_clock,self.nose_air_target,self.nose_ground=prior_nose_air+h,prior_nose_air_target,prior_nose_ground
    else self.nose_air_clock,self.nose_air_target=-1,0 end
    self.pump=pump self.pedal_latch=next_latch out.valid=true out.issue="none" return out
end
function Controller:_recovery_mask(h,body,samples,c,baseline)
    local t=self.tuning
    if not c.recovery_step_verified or not c.enabled or baseline.balance_support_mask==3 or baseline.hop_applied or c.hop_strength>0 or
        c.manual~=0 or c.nose_manual~=0 or c.steer~=0 or c.air_yaw~=0 then return 0 end
    local q=M.normalized(body.orientation) local up,forward=M.turn(q,{0,1,0}),M.turn(q,{0,0,1})
    local gravity_up=M.unit(M.mul(t.gravity,-1)) if not gravity_up then return 0 end
    local platform,mask={0,0,0},0
    for i=1,2 do
        local prior,s=self.normals[i],samples[i] local contact=s.contact
        if not prior.valid or not prior.recovery_seeded or not prior.verified_plane or prior.normal_load<=0 or not s.verified_plane or contact.status~="hit" or
            not s.balance_normal_available or baseline.normal_load[i]<=0 or s.separation>=0 or prior.separation>=0 or s.separation<=prior.separation or
            prior.recovery_velocity<=0 or prior.recovery_seconds+h>.2 then return 0 end
        local basis,face=M.basis(contact.normal,contact.forward),M.unit(s.balance_normal)
        if not basis or not face or M.dot(face,basis.normal)<math.cos(.002) or M.dot(prior.normal,basis.normal)<math.cos(.002) or
            M.dot(prior.balance_normal,face)<math.cos(.002) or M.dot(up,face)<.95 or M.dot(face,gravity_up)<.5 then return 0 end
        local delta=M.sub(M.sub(contact.point,prior.point),M.mul(prior.surface_velocity,h))
        if M.length(delta)>F.wheel_radius or math.abs(M.dot(delta,prior.normal))>.0025 or math.abs(M.dot(delta,basis.normal))>.0025 or
            M.length(M.sub(contact.surface_velocity,prior.surface_velocity))>1e-6 then return 0 end
        local relative=M.sub(M.point_velocity(body,contact.point),contact.surface_velocity)
        local opening,gravity_normal=M.dot(relative,basis.normal),M.dot(t.gravity,basis.normal)
        local allowance=math.min(.025,-gravity_normal*h*t.recovery_fraction)
        if not M.vec(relative) or opening<=0 or gravity_normal>=0 or math.abs(opening-prior.recovery_velocity)>allowance then return 0 end
        platform=M.add(platform,contact.surface_velocity)
        if not F.eligible_support(body,s,.005,t.maximum_penetration) then mask=bit32.bor(mask,2^(i-1)) end
    end
    local speed=M.dot(M.sub(body.linear_velocity,M.mul(platform,.5)),forward)
    if self.travel_direction~=0 and speed*self.travel_direction<0 then return 0 end return mask
end
function Controller:_adopt(other)
    self.last_hop_event=other.last_hop_event self.normals=other.normals self.landing_impact=other.landing_impact self.travel_direction=other.travel_direction
    self.air=other.air self.steering=other.steering self.pump=other.pump self.pedal_latch=other.pedal_latch
    self.brake_share=other.brake_share self.brake_squeeze=other.brake_squeeze self.manual_engaged=other.manual_engaged
    self.manual_throw_seconds=other.manual_throw_seconds self.manual_risen=other.manual_risen self.manual_slowed=other.manual_slowed
    self.manual_ground=other.manual_ground
    self.nose_engaged=other.nose_engaged self.nose_throw_seconds=other.nose_throw_seconds self.nose_risen=other.nose_risen
    self.nose_slowed=other.nose_slowed self.nose_ground=other.nose_ground self.nose_catch_spent=other.nose_catch_spent
    self.nose_air_clock=other.nose_air_clock self.nose_air_target=other.nose_air_target
end
function Controller:step(h,body,wheels,samples,controls,speculative)
    local c=F.controls(controls) local baseline_controller=self:clone()
    for _,proof in speculative or {} do
        if proof.selected then
            -- The private speculative normal law is deliberately outside this
            -- ordinary-kernel slice. Never silently fall back to invented support.
            c.contact_compliance_available=true
            c.landing_contact_compliance_selected=false
        end
    end
    local baseline=baseline_controller:_impl(h,body,wheels,samples,c,0)
    local mask=baseline.valid and self:_recovery_mask(h,body,samples,c,baseline) or 0
    if mask~=0 then
        local assisted_controller=self:clone() local assisted=assisted_controller:_impl(h,body,wheels,samples,c,mask)
        if assisted.valid and M.finite(assisted.normal_load[1]) and M.finite(assisted.normal_load[2]) and assisted.normal_load[1]>0 and assisted.normal_load[2]>0 then
            self:_adopt(assisted_controller) return assisted
        end
    end
    self:_adopt(baseline_controller) return baseline
end
-- The eventual native adapter must adopt this model copy only after actual SDK
-- acceptance/receipts; a preview does not consume the committed event/history.
function Controller:preview(h,body,wheels,samples,controls,speculative)
    local candidate=self:clone() return candidate:step(h,body,wheels,samples,controls,speculative),candidate
end
return F

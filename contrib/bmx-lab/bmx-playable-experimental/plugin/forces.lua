-- Ordinary bmx_chassis_control.h kernel. Outputs impulses/forces only; never integrates pose.
local M=require("./force_math")
local Tire=require("./tire")
local Pump=require("./pump")
local Solver=require("./force_solver")
local F={native_seconds=.01666666567325592}
local Controller={} Controller.__index=Controller
local scale=.7737670588235294
F.wheel_radius=.34*scale
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
    balance_stiffness=1600,balance_damping=360,balance_torque_limit=1200,lean_limit=.47,manual_pitch=.4,
    air_yaw_torque=200,air_pitch_torque=160,neutral_air_damping_rate=2.75,hop_delta_speed=4.5,
    contact_gap=.02,maximum_penetration=.10,recovery_fraction=.15,recovery_speed_limit=.4,
    force_limit=40000,torque_limit=4000,wheel_speed_limit=500,contact_iterations=12,pedal_fade_start=6,pedal_cutoff=8,
    pedal_top_speed=7.9,pedal_resume_speed=7.4,
    curvature_rate_limit=6,curvature_step_limit=.2,curvature_min_speed=.5,brake_iterations=96}
function F.tuning(overrides)
    local out=M.copy(defaults) for key,value in overrides or {} do assert(out[key]~=nil,"unknown force tuning") out[key]=M.copy(value) end return out
end
function F.proposed_body() return {mass=106,inertia_body={26,32,10},orientation={0,0,0,1},center_of_mass={0,0,0},linear_velocity={0,0,0},angular_velocity={0,0,0}} end
function F.proposed_wheels() return {{radius=F.wheel_radius,inertia=.23,angular_speed=0},{radius=F.wheel_radius,inertia=.23,angular_speed=0}} end
function F.controls(overrides)
    local c={enabled=true,pedal=0,brake=0,steer=0,manual=0,nose_manual=0,air_yaw=0,hop_strength=0,hop_event_id=0,
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
        landing_approach_mask=0,compliant_normal_mask=0,landing_recovery_mask=0,approach_normal_impulse={0,0},approach_normal_force={0,0}}
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
        "lean_limit","manual_pitch","air_yaw_torque","air_pitch_torque","hop_delta_speed","contact_gap","maximum_penetration",
        "recovery_fraction","recovery_speed_limit","pedal_fade_start","pedal_cutoff","pedal_top_speed","pedal_resume_speed",
        "curvature_rate_limit","curvature_step_limit","curvature_min_speed","neutral_air_damping_rate"} do if not M.finite(t[name]) or t[name]<0 or t[name]>1e6 then return false end end
    if type(t.friction)~="table" then return false end
    for _,key in {"longitudinal_friction","lateral_friction"} do local x=t.friction[key] if not M.finite(x) or x<0 or x>10 then return false end end
    return t.steer_limit<=1 and t.lean_limit<=.8 and t.manual_pitch<=.6 and t.hop_delta_speed<=4.5 and t.contact_gap<=.05 and
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
    return M.vec(relative) and M.dot(relative,basis.normal)<=.05
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
-- top_speed sits just under pedal_cutoff, because with no drag a flat road
-- only creeps toward the cutoff (SIMULATION.md). The band keeps a bike holding
-- its top speed from switching every step on small speed changes. Only a rider
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
-- step's speed decides it alone.
function Controller:reset() self.last_hop_event=0 self.normals={{},{}} self.landing_impact={false,false} self.travel_direction=0 self.air={} self.steering={} self.pump=Pump.new() self.pump:reset() self.pedal_latch=F.pedal_state() end
function Controller:invalidate_continuity()
    -- A missed command breaks one-step derivative and state-machine history.
    -- Accepted hop consumption and authored tuning remain authoritative.
    self.normals={{},{}} self.landing_impact={false,false} self.travel_direction=0 self.air={} self.steering={}
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
    self.normals={{},{}} self.landing_impact={false,false} self.travel_direction=0 self.air={} self.steering={} self.pump:reset()
    if not M.finite(h) or math.abs(h-F.native_seconds)>1e-8 then out.issue="unsupported_step" return out end
    if not tuning_valid(t) or not M.valid_body(measured) or not M.vec(measured.linear_velocity,50) or not M.vec(measured.angular_velocity,40) or
        not M.valid_wheel(wheels[1]) or not M.valid_wheel(wheels[2]) then return out end
    for _,name in {"pedal","brake","steer","manual","nose_manual","air_yaw","hop_strength","ground_pump"} do if not M.finite(c[name]) then return out end end
    for _,name in {"enabled","recovery_step_verified","rotation_reserved","pump_operator_available","pump_inhibited",
        "contact_compliance_available","landing_contact_compliance_selected"} do if type(c[name])~="boolean" then return out end end
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
        contact.normal_only,contact.normal_softness,contact.normal_floor_delta,contact.normal_deflection_limit=nil,nil,nil,nil
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
            local floor_plane=landing_selected and c.enabled
                and M.dot(basis.normal,gravity_up)>=landing.floor_cosine
                and M.length(contact.surface_velocity)<=landing.stationary_speed
            local landing_plane=floor_plane
                and (not supported or recovering or prior_impact[i] and closing>t.recovery_speed_limit)
            -- A distant approach ray does not arm impact recovery. Start only
            -- inside the existing contact band, not at the rear floor far below.
            local impact=landing_plane and s.separation<=landing.contact_gap and closing>t.recovery_speed_limit
            local impact_envelope=landing_plane and (impact or recovering)
            self.landing_impact[i]=impact_envelope==true
            if impact_envelope then out.landing_recovery_mask=bit32.bor(out.landing_recovery_mask,2^(i-1)) end
            -- Late one-wheel impacts cannot stop within 15 mm in one packet.
            -- Use softer finite compliance inside the unchanged gross-penetration
            -- bound; the packet's force/torque limits still decide admission.
            local deflection_limit=(impact_envelope or supported) and t.maximum_penetration or landing.maximum_deflection
            if floor_plane then contact.normal_deflection_limit=deflection_limit end
            if landing_plane and s.separation < -deflection_limit-landing.deflection_tolerance then out.issue="landing_deflection_limit" return out end
            local approach=floor_plane and s.separation>landing.contact_gap and s.separation<=landing.approach_gap
            if approach then
                -- A gravity ray hits downslope from the tyre's normal projection.
                -- Apply the approach impulse through that projection so a distant
                -- hit cannot invent a pitch or roll lever. Folded samples must
                -- retain an actual forecast hub; legacy hit-only forecasts do not
                -- establish this geometry.
                if s.forecast_geometry_unavailable~=nil and s.forecast_geometry_unavailable~=false then
                    return result("landing_geometry_unavailable")
                end
                if s.wheel_center~=nil or s.wheel_radius~=nil then
                    if not M.vec(s.wheel_center) or not M.finite(s.wheel_radius)
                        or math.abs(s.wheel_radius-wheels[i].radius)>1e-8
                        or math.abs(M.dot(M.sub(s.wheel_center,contact.point),basis.normal)-s.wheel_radius-s.separation)>1e-6 then
                        return result("landing_geometry_unavailable")
                    end
                    contact.point=M.sub(s.wheel_center,M.mul(basis.normal,s.separation+s.wheel_radius))
                else
                    local down=M.mul(gravity_up,-1) local dn=M.dot(down,basis.normal)
                    contact.point=M.sub(contact.point,M.mul(M.sub(down,M.mul(basis.normal,dn)),(s.separation+wheels[i].radius)/-dn))
                end
                -- For semi-implicit steps, v^2/(2*a)+v*h bounds the stopping
                -- distance. This leaves distance for a finite normal deceleration
                -- instead of demanding a full landing stop in one 60 Hz step.
                local ah=landing.approach_acceleration*h
                local allowed=math.sqrt(ah*ah+2*landing.approach_acceleration*s.separation)-ah
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
                local target=bias-math.max(0,s.separation)/h
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
    local front_heading=contacts[1].status=="hit" and not contacts[1].normal_only and contacts[1].forward or body_forward
    local function heading(angle)
        local front=balance_frame and M.basis(up,M.around(front_heading,axis,angle)) or nil if not front then return nil end
        local value=math.atan2(M.dot(up,M.cross(forward,front.forward)),math.clamp(M.dot(forward,front.forward),-1,1))
        return M.finite(value) and math.abs(value)<1.4 and value or nil
    end
    if balance_frame and M.dot(body_up,up)>.2 then
        local turn=heading(out.front_steer_angle) if turn==nil then return out end
        local maximum=math.atan2(M.length(t.gravity)*t.wheelbase*math.tan(t.lean_limit),speed*speed)
        if math.abs(turn)>maximum then
            local low,high=0,1 for _=1,40 do local middle=(low+high)*.5 local trial=heading(candidate_angle*middle) if trial==nil then return out end if math.abs(trial)<=maximum then low=middle else high=middle end end
            out.front_steer_angle=candidate_angle*low out.steering_limited=true turn=heading(out.front_steer_angle) if turn==nil then return out end
        end
        out.turning_lean_angle=math.atan(-speed*speed*math.tan(turn)/(M.length(t.gravity)*t.wheelbase))
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
    local motor_speed=math.max(0,speed,wheels[2].angular_speed*wheels[2].radius)
    local cadence,next_latch=F.pedal_cadence(prior_latch,{enabled=c.enabled,pedal=math.clamp(c.pedal,0,1),motor_speed=motor_speed,
        top_speed=t.pedal_top_speed,resume_speed=t.pedal_resume_speed})
    if not cadence.valid then return out end out.pedaling=cadence.pedaling
    local pedal_scale=math.clamp((t.pedal_cutoff-motor_speed)/(t.pedal_cutoff-t.pedal_fade_start),0,1)
    local pedal=cadence.pedaling and math.clamp(c.pedal,0,1)*pedal_scale or 0 local brake=c.enabled and math.clamp(c.brake,0,1) or 0
    local braking=brake>0 and (t.front_brake_torque>0 or t.rear_brake_torque>0)
    local pitch=c.enabled and math.clamp(c.nose_manual,0,1)-math.clamp(c.manual,0,1) or 0
    local assist={0,0,0} local world_up=M.unit(M.mul(t.gravity,-1)) if not world_up then return out end
    if support_mask~=0 then
        if not balance_frame then return out end out.balance_reference_up=up
        if M.dot(body_up,up)>.2 then
            local lateral=M.cross(up,forward) local desired=M.around(M.around(up,lateral,pitch*t.manual_pitch),forward,out.turning_lean_angle)
            out.desired_balance_up=desired
            local omega=M.sub(measured.angular_velocity,M.mul(up,M.dot(measured.angular_velocity,up)))
            local desired_omega=M.sub(out.desired_support_angular_velocity,M.mul(up,M.dot(out.desired_support_angular_velocity,up)))
            assist=M.limited(M.sub(M.mul(M.cross(body_up,desired),t.balance_stiffness),M.mul(M.sub(omega,desired_omega),t.balance_damping)),t.balance_torque_limit)
            out.balance_torque=assist
        end
    elseif c.enabled then assist=M.add(M.mul(world_up,-math.clamp(c.air_yaw,-1,1)*t.air_yaw_torque),M.mul(body_left,pitch*t.air_pitch_torque)) out.air_control_torque=assist end
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
        local b,w=Tire.axle_couple(prediction,out.wheels[i],wheel_axes[i],(i==2 and pedal*t.pedal_torque or 0)*h)
        if not b then return result() end prediction=b out.wheels[i]=w
    end
    local actuated,actuated_wheels=M.copy(prediction),M.copy(out.wheels)
    out.pre_contact_prediction=M.copy(actuated) out.pre_contact_prediction_available=true
    local effects
    prediction,out.wheels,effects=Solver.solve(h,prediction,out.wheels,contacts,t,brake,wheel_axes)
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
    if landing_selected then
        -- Recheck the actual bounded packet, including any shared budget scale.
        -- This is a linear point prediction, not a repaired pose or native proof.
        local bounded=M.copy(measured)
        bounded.linear_velocity=M.add(M.add(measured.linear_velocity,gravity_delta),M.mul(M.add(out.linear_impulse,out.hop_impulse),1/measured.mass))
        bounded.angular_velocity=M.add(measured.angular_velocity,M.tensor(measured,out.angular_impulse,true))
        for i=1,2 do
            if contacts[i].normal_only or contacts[i].normal_softness then
                local sample=samples[i]
                local velocity=M.sub(M.point_velocity(bounded,contacts[i].point),sample.contact.surface_velocity)
                local gap=sample.separation+M.dot(velocity,contacts[i].normal)*h
                if not M.finite(gap) or gap < -contacts[i].normal_deflection_limit-landing.deflection_tolerance then return result("landing_deflection_limit") end
            end
        end
    end
    if new_event then self.last_hop_event=c.hop_event_id end
    if support_mask~=0 and not out.hop_applied and c.enabled then
        for i=1,2 do next_normals[i].normal_load=out.normal_load[i] end self.normals=next_normals self.travel_direction=direction~=0 and direction or prior_direction
    end
    local loaded=false for i=1,2 do loaded=loaded or (out.normal_load[i]>0 and F.eligible_support(measured,samples[i],.005,t.maximum_penetration)) end
    if loaded and not out.hop_applied then reservation(air,c.recovery_step_verified,c.enabled,true,intent,launch) end
    self.air=air out.air_rotation_reserved=air.reserved==true if c.enabled then self.steering={valid=true,angle=out.front_steer_angle} end
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

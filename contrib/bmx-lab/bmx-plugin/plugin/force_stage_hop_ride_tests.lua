-- Combined-stage interactions only. The runner authors the private literals;
-- neither this suite nor a runtime option can enable the installable mod.
local Combined=require("./force_stage_hop_ride_fixture")
local Uncapped=require("./force_stage_hop_ride_uncapped_fixture")
local LowForce=require("./force_stage_hop_ride_low_force_fixture")
local LowTorque=require("./force_stage_hop_ride_low_torque_fixture")
local Zero=require("./force_stage")
local Ride=require("./ride_runtime")
local Forces=require("./forces")
local M=require("./force_math")
local Tests={}
local h=Forces.native_seconds
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for key,value in pairs(a) do if not equal(value,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function clear() return {{contact={status="clear"}},{contact={status="clear"}}} end
local function fixture(gap,vertical,speed)
    local b,w=Forces.proposed_body(),Forces.proposed_wheels()
    b.center_of_mass={0,.9,-.05};b.linear_velocity={0,vertical or 0,speed or .5}
    for _,wheel in ipairs(w) do wheel.angular_speed=(speed or .5)/wheel.radius end
    local samples={}
    for i=1,2 do
        samples[i]={contact={status="hit",point={0,0,i==1 and .525 or -.525},normal={0,1,0},
            forward={0,0,1},surface_velocity={0,0,0}},separation=gap or 0,
            verified_plane=false,balance_normal_available=false}
    end
    return b,w,samples
end
local function selected(controls)
    return Forces.controls({pedal=controls.pedal or 0,steer=controls.steer or 0,brake=controls.brake or 0,
        hop_event_id=controls.hop_event_id or 0,hop_strength=controls.hop_strength or 0,
        contact_compliance_available=true,landing_contact_compliance_selected=true})
end
function Tests.run()
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    local function case() cases+=1 end
    case() do
        local stage=Combined.new()
        check(stage.hop_policy=="grounded_once" and stage.tuning.wheel_probe_extra==.75,
            "combined driving retains the receipt-owned hop and longer current-ray policy")
        check(not pcall(Combined.new,{stage="hop_ride"}) and not pcall(Combined.new,nil),
            "combined driving adds no runtime stage or cap configuration")
        local b,w,s=fixture()
        local input={pedal=.5,steer=.2,brake=.3,hop_event_id=1,hop_strength=1}
        local zero=Zero.new():preview(h,b,w,s,input)
        check(zero.valid and M.length(zero.force)==0 and M.length(zero.torque)==0 and M.length(zero.hop_impulse)==0,
            "the unchanged tracked defaults still neutralize all combined input")
        local touched=0
        local api=setmetatable({}, {__index=function() touched+=1;error("native callback") end})
        check(Ride.new(api,{force=stage}):observe(nil,nil,nil).phase=="inert" and touched==0,
            "a private combined stage grants no production Ride activation")
    end
    for _,steer in ipairs({-.2,.2}) do case() do
        local b,w,s=fixture()
        local stage,reference=Combined.new(),Forces.new()
        local input={pedal=.4,steer=steer,brake=.25,hop_event_id=7,hop_strength=.5,
            manual=1,nose_manual=1,air_yaw=1,rotation_reserved=true,ground_pump=1,pump_operator_available=true}
        table.freeze(input)
        local chosen=selected(input)
        local expected,raw=reference:preview(h,b,w,s,chosen)
        local out,candidate=stage:preview(h,b,w,s,input)
        check(expected.valid and expected.contact_scale==1 and out.valid and equal(out,expected),
            "one preview combines the exact kernel steering, braking and hop while filtering manual/air/trick inputs")
        check(out.hop_applied and out.hop_event_id==7 and M.length(out.hop_impulse)>0 and out.front_steer_angle*steer<0,
            "the same accepted candidate has signed steering and its original hop impulse")
        stage:_adopt(candidate);reference:_adopt(raw)
        local repeated=stage:preview(h,b,out.wheels,s,input)
        local repeated_reference=reference:preview(h,b,out.wheels,s,chosen)
        check(repeated.valid and equal(repeated,repeated_reference) and not repeated.hop_applied
            and M.length(repeated.hop_impulse)==0,"driving after adoption cannot replay the same hop ID")
        check(input.hop_event_id==7 and input.steer==steer and input.manual==1,
            "combined selection leaves the caller's frozen action record intact")
    end end
    for _,gap in ipairs({0,.3}) do case() do
        local b,w,s=fixture(gap,gap==0 and -.1 or -4)
        local controls={pedal=.3,steer=.2,brake=.6}
        local expected=Forces.new():preview(h,b,w,s,selected(controls))
        local out=Combined.new():preview(h,b,w,s,controls)
        check(out.valid and equal(out,expected),"steering and braking do not replace the hop landing law")
        if gap>0 then
            check(out.landing_approach_mask==3 and not out.grounded and equal(out.normal_load,{0,0})
                and equal(out.longitudinal_impulse,{0,0}) and equal(out.lateral_impulse,{0,0}),
                "approach braking remains normal-only, with no fabricated tire friction or grounded authority")
            check(M.length(out.force)>0 and not out.hop_applied,"a descending steered/braked approach emits landing support, never a hop")
        else
            check(out.compliant_normal_mask==3 and math.abs(out.brake_impulse[1])+math.abs(out.brake_impulse[2])>0,
                "ground contact combines compliant support with actual rolling brake impulses")
        end
    end end
    case() do
        local b,w=fixture();b.linear_velocity={0,6,3}
        local stage=Combined.new()
        local out=stage:preview(h,b,w,clear(),{steer=.3,brake=.5,hop_event_id=3,hop_strength=1})
        check(stage:admit_measured(b) and out.valid and not out.hop_applied,
            "combined driving admits the inclusive split 3/6 boundary, not a three-metre total-speed cap")
        check(out.front_steer_angle<0 and out.landing_approach_mask==0,
            "air steering remains a presentation/axle input and clear rays grant no landing contact")
    end
    for _,spec in ipairs({{velocity={0,0,3.001},issue="authored_speed_limit"},
        {velocity={0,6.001,0},issue="authored_vertical_speed_limit"},
        {velocity={0,-6.001,0},issue="authored_vertical_speed_limit"}}) do case() do
        local b,w=fixture();b.linear_velocity=M.copy(spec.velocity)
        local stage=Combined.new();local ok,why=stage:admit_measured(b)
        local out,candidate=stage:preview(h,b,w,clear(),{steer=.3,brake=.5,hop_event_id=3,hop_strength=1})
        check(not ok and why==spec.issue and not out.valid and out.issue==why,
            "measured and forecast admission retain the same split cap despite combined control intent")
        check(M.length(out.hop_impulse)==0 and not pcall(stage._adopt,stage,candidate),
            "an over-cap combined preview neither emits the hop nor creates adoptable history")
    end end
    for _,spec in ipairs({{module=Uncapped,issue="authored_caps_unavailable"},
        {module=LowForce,issue="authored_force_limit"},{module=LowTorque,issue="authored_torque_limit"}}) do case() do
        local b,w,s=fixture(0,0,2);b.angular_velocity={.02,0,.04}
        local stage=spec.module.new()
        local out,candidate=stage:preview(h,b,w,s,{pedal=.5,steer=.4,brake=.6})
        check(not out.valid and out.issue==spec.issue,"combined driving refuses missing or insufficient authored caps")
        check(M.length(out.force)==0 and M.length(out.torque)==0 and M.length(out.hop_impulse)==0
            and not pcall(stage._adopt,stage,candidate),"a refused combined command cannot advance its private model")
    end end
    for _,entry in ipairs({{"steer",1.01},{"brake",-.01},{"hop_strength",1.01}}) do case() do
        local b,w,s=fixture();local stage=Combined.new()
        local controls={pedal=.5,steer=.2,brake=.2,hop_event_id=9,hop_strength=.5}
        controls[entry[1]]=entry[2]
        local out,candidate=stage:preview(h,b,w,s,controls)
        local issue=entry[1]=="hop_strength" and "invalid_hop" or "invalid_"..entry[1]
        check(not out.valid and out.issue==issue and not pcall(stage._adopt,stage,candidate),
            "invalid combined input cannot partly accept the driving or hop channels")
    end end
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)

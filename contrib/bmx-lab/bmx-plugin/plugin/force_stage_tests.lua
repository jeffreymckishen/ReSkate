-- These stage modules are exact private source substitutions made by the
-- standalone runner. Synthetic caps prove policy only, never DEC-5 approval.
local Zero=require("./force_stage")
local Support=require("./force_stage_support_fixture")
local Pedal=require("./force_stage_pedal_fixture")
local UncappedSupport=require("./force_stage_support_uncapped_fixture")
local UncappedPedal=require("./force_stage_pedal_uncapped_fixture")
local LowCap=require("./force_stage_low_cap_fixture")
local InvalidStage=require("./force_stage_invalid_fixture")
local Forces=require("./forces")
local M=require("./force_math")
local Tests={}
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function fixture(speed)
    local b,w=Forces.proposed_body(),Forces.proposed_wheels()
    b.center_of_mass={0,.9,-.05};b.linear_velocity={0,0,speed or 0}
    for _,wheel in ipairs(w) do wheel.angular_speed=(speed or 0)/wheel.radius end
    local samples={}
    for i=1,2 do
        samples[i]={contact={status="hit",point={0,0,i==1 and .525 or -.525},normal={0,1,0},
            forward={0,0,1},surface_velocity={0,0,0}},separation=0,verified_plane=false,balance_normal_available=false}
    end
    return b,w,samples
end
local function clear() return {{contact={status="clear"}},{contact={status="clear"}}} end
local function diagnostic(model)
    local out=M.copy(model);out.diagnostic_only=true;out.force_applied=false;return out
end
local function zero_vector(v) return equal(v,{0,0,0}) end
local h=Forces.native_seconds
function Tests.run()
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    local function case() cases+=1 end
    case() do
        local c=Zero.new()
        check(type(c.preview)=="function" and type(c._adopt)=="function" and type(c.reset)=="function","wrapper provides Ride's exact controller seam")
        check(equal(c.tuning.gravity,Forces.tuning().gravity) and c.tuning.force_limit==nil,"Ride receives gravity without a mutable tuning or cap selector")
        check(not pcall(Zero.new,{stage="pedal",force=20000,speed=10}) and not pcall(Zero.new,"pedal") and not pcall(Zero.new,nil),
            "constructor refuses every runtime configuration including an explicit nil argument")
        check(not pcall(function() c.tuning.gravity[2]=0 end) and not pcall(function() c.stage="pedal" end),"controller and exposed gravity cannot be rewritten")
        check(not pcall(InvalidStage.new),"a private invalid stage literal refuses construction")
    end
    case() do
        local b,w,s=fixture(.2);w[1].angular_speed=0
        local before_body,before_wheels,before_samples=M.copy(b),M.copy(w),M.copy(s)
        local c=Zero.new()
        local expected=Forces.new():preview(h,b,w,s,Forces.controls())
        local out,candidate=c:preview(h,b,w,s,{pedal=1,brake=1,steer=1,manual=1,hop_strength=1,hop_event_id=1})
        check(expected.valid and out.valid and M.length(out.diagnostic.force)>100,"zero stage actually evaluates the real support kernel")
        check(equal(out.diagnostic,diagnostic(expected)),"all diagnostic data is the detached real neutral-kernel prediction")
        check(zero_vector(out.force) and zero_vector(out.torque) and zero_vector(out.linear_impulse) and zero_vector(out.angular_impulse)
            and zero_vector(out.hop_impulse) and out.hop_applied==false and out.hop_event_id==0,"every submitted force and impulse channel stays zero")
        check(equal(out.wheels,before_wheels) and not equal(out.diagnostic.wheels,before_wheels),"hypothetical tire changes do not become the zero command's wheel state")
        check(equal(b,before_body) and equal(w,before_wheels) and equal(s,before_samples),"preview cannot rewrite measured input or contact provenance")
        check(pcall(c._adopt,c,candidate) and not pcall(c._adopt,c,candidate),"zero's exact acceptance token is consumed once")
        local again=c:preview(h,b,w,s,{})
        check(equal(again,out),"accepting zero never adopts hypothetical support histories or wheel impulses")
    end
    case() do
        local b,w,s=fixture();b.linear_velocity={0,-8,0}
        local expected=Forces.new():preview(h,b,w,s,Forces.controls())
        local c=Zero.new();local out,candidate=c:preview(h,b,w,s,{})
        check(expected.valid and expected.contact_scale<1,"constructed falling sample saturates the real kernel budget")
        check(out.valid and equal(out.diagnostic,diagnostic(expected)) and out.contact_scale==1,"zero retains the clamped prediction only under explicit diagnostics")
        check(zero_vector(out.force) and zero_vector(out.torque) and zero_vector(out.hop_impulse) and equal(out.wheels,w),"saturated diagnostics still produce only zero force and unchanged wheels")
        c:_adopt(candidate)
        check(equal(c:preview(h,b,w,s,{}),out),"accepting a zero packet cannot adopt saturated diagnostic history")
    end
    for _,module in ipairs({UncappedSupport,UncappedPedal}) do case() do
        local b,w,s=fixture();local c=module.new();local out,candidate=c:preview(h,b,w,s,{pedal=1})
        check(not out.valid and out.issue=="authored_caps_unavailable","each nonzero stage refuses without a reviewed source cap")
        check(zero_vector(out.force) and not pcall(c._adopt,c,candidate),"uncapped failure has no force or adoptable history")
    end end
    case() do
        local b,w,s=fixture()
        local controls={enabled=false,pedal=1,brake=1,steer=.8,manual=.7,nose_manual=.4,air_yaw=.3,hop_strength=1,
            hop_event_id=99,recovery_step_verified=true,rotation_reserved=true,pump_operator_available=true,
            pump_inhibited=true,ground_pump=1,contact_compliance_available=true,landing_contact_compliance_selected=true}
        local before=M.copy(controls)
        local out=Support.new():preview(h,b,w,s,controls)
        local expected=Forces.new():preview(h,b,w,s,Forces.controls())
        check(out.valid and equal(out,expected),"support passes only canonical neutral controls to the actual kernel")
        check(equal(controls,before) and out.hop_applied==false,"stage filtering does not mutate Mapping's controls or publish a hop")
    end
    case() do
        local b,w,s=fixture(.3);local support,pedal=Support.new(),Pedal.new()
        for _=1,4 do
            local a,ca=support:preview(h,b,w,s,{pedal=0,steer=1,brake=1})
            local p,cp=pedal:preview(h,b,w,s,{pedal=0,manual=1,hop_strength=1,hop_event_id=42})
            check(a.valid and p.valid and equal(a,p),"neutral pedal and support are recursively identical before each accepted step")
            support:_adopt(ca);pedal:_adopt(cp);w=M.copy(a.wheels)
        end
        support:reset();pedal:reset()
        check(equal(support:preview(h,b,w,s,{}),pedal:preview(h,b,w,s,{})),"reset preserves exact neutral equivalence")
    end
    case() do
        local b,w,s=fixture();local c=Pedal.new();local reference=Forces.new()
        local controls={pedal=.6,brake=1,steer=-1,manual=1,nose_manual=1,air_yaw=1,hop_strength=1,hop_event_id=17,
            ground_pump=1,pump_operator_available=true,recovery_step_verified=true,rotation_reserved=true}
        local expected,raw=reference:preview(h,b,w,s,Forces.controls({pedal=.6}))
        local out,candidate=c:preview(h,b,w,s,controls)
        check(out.valid and equal(out,expected) and not out.hop_applied,"pedal retains exactly its finite pedal channel and no other actions")
        local next_wheels=M.copy(expected.wheels)
        out.force[2]=math.huge;out.wheels[2].angular_speed=999
        c:_adopt(candidate);reference:_adopt(raw)
        local next_out=c:preview(h,b,next_wheels,s,{pedal=0})
        local next_expected=reference:preview(h,b,next_wheels,s,Forces.controls())
        check(next_out.valid and equal(next_out,next_expected),"accepted history comes from the private kernel candidate, not the caller-editable output")
    end
    for _,value in ipairs({-.01,1.01,math.huge,0/0,"1",false}) do case() do
        local b,w,s=fixture();local c=Pedal.new();local out,candidate=c:preview(h,b,w,s,{pedal=value})
        check(not out.valid and out.issue=="invalid_pedal" and not pcall(c._adopt,c,candidate),"invalid pedal is refused rather than clamped or defaulted")
    end end
    case() do
        local b,w,s=fixture();local c=LowCap.new();local expected=Forces.new():preview(h,b,w,s,Forces.controls())
        local out,candidate=c:preview(h,b,w,s,{})
        check(expected.valid and M.length(expected.force)>100 and out.issue=="authored_force_limit" and not out.valid,"an actual support force above the synthetic D5 fixture cap is invalid")
        check(zero_vector(out.force) and equal(out.diagnostic,diagnostic(expected)) and not pcall(c._adopt,c,candidate),"over-cap refusal retains uncropped diagnostics and no adoptable command")
    end
    for _,module in ipairs({Support,Pedal}) do case() do
        local b,w,s=fixture();b.linear_velocity={0,-8,0}
        local expected=Forces.new():preview(h,b,w,s,Forces.controls())
        local c=module.new();local out,candidate=c:preview(h,b,w,s,{pedal=0})
        check(expected.valid and expected.contact_scale<1 and not out.valid and out.issue=="kernel_clamped","nonzero stages refuse the real kernel's internally scaled contact result")
        check(equal(out.diagnostic,diagnostic(expected)) and not pcall(c._adopt,c,candidate),"a scaled result cannot be adopted as an unclamped authored force")
    end end
    case() do
        local b,w=fixture();local c=Support.new();b.linear_velocity={6,0,8}
        check(c:preview(h,b,w,clear(),{}).valid,"the synthetic speed magnitude boundary is accepted with clear contacts")
        b.linear_velocity={6,0,8.001}
        local out,candidate=c:preview(h,b,w,clear(),{})
        check(not out.valid and out.issue=="authored_speed_limit" and not pcall(c._adopt,c,candidate),"speed checks magnitude and refuses excess without clamping velocity")
        check(equal(b.linear_velocity,{6,0,8.001}),"speed refusal leaves measured body state unchanged")
    end
    for _,module in ipairs({Zero,Support,Pedal}) do case() do
        local b,w,s=fixture();b.linear_velocity[1]=math.huge
        local c=module.new();local out,candidate=c:preview(h,b,w,s,{})
        check(not out.valid and zero_vector(out.force) and not pcall(c._adopt,c,candidate),"nonfinite measured state is invalid in every stage")
    end end
    case() do
        local b,w,s=fixture();local c=Support.new();local other=Support.new()
        local _,old=c:preview(h,b,w,s,{});local _,current=c:preview(h,b,w,s,{})
        check(not pcall(c._adopt,c,old),"a newer preview invalidates an unaccepted old candidate")
        local _,foreign=other:preview(h,b,w,s,{})
        check(not pcall(c._adopt,c,foreign),"a foreign wrapper candidate cannot transfer history")
        local _,raw=Forces.new():preview(h,b,w,s,Forces.controls())
        check(not pcall(c._adopt,c,raw),"a caller cannot bypass stage policy with a raw Forces candidate")
        check(pcall(c._adopt,c,current) and not pcall(c._adopt,c,current),"refused candidates do not consume the valid token, which remains exact-once")
        local _,before_reset=c:preview(h,b,w,s,{})
        c:reset()
        check(not pcall(c._adopt,c,before_reset),"reset invalidates a pending candidate and cannot rewind accepted histories through ACK replay")
    end
    case() do
        local b,w,s=fixture();local c=Pedal.new();local _,candidate=c:preview(h,b,w,s,{pedal=1})
        local invalid=c:preview(h,b,w,s,{pedal=2})
        check(not invalid.valid and not pcall(c._adopt,c,candidate),"a refused later preview cannot leave an earlier command secretly adoptable")
        local expected=Forces.new():preview(h,b,w,s,Forces.controls())
        check(equal(c:preview(h,b,w,s,{}),expected),"unaccepted and invalid previews leave committed kernel history untouched")
    end
    return {cases=cases,assertions=assertions,native_actions=0}
end
return Tests

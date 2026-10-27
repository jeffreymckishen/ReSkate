-- Private source-selected stages over real Lua models and constructed receipts.
-- The runner supplies the exact cap fixtures; this is not native qualification.
local Zero=require("./force_stage")
local RideStage=require("./force_stage_ride_fixture")
local Uncapped=require("./force_stage_ride_uncapped_fixture")
local LowForce=require("./force_stage_ride_low_force_fixture")
local LowTorque=require("./force_stage_ride_low_torque_fixture")
local Hop=require("./force_stage_hop_fixture")
local Runtime=require("./ride_runtime")
local Fixtures=require("./ride_runtime_tests")
local Forces=require("./forces")
local M=require("./force_math")
local Identity=require("./lease_identity")
local Tests={}
local h=Forces.native_seconds
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for key,value in pairs(a) do if not equal(value,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function zero(v) return equal(v,{0,0,0}) end
local function fixture(speed)
    local b,w=Forces.proposed_body(),Forces.proposed_wheels()
    b.center_of_mass={0,.9,-.05};b.linear_velocity={0,0,speed or 0}
    for _,wheel in ipairs(w) do wheel.angular_speed=(speed or 0)/wheel.radius end
    local s={}
    for i=1,2 do
        s[i]={contact={status="hit",point={0,0,i==1 and .525 or -.525},normal={0,1,0},
            forward={0,0,1},surface_velocity={0,0,0}},separation=0,
            verified_plane=false,balance_normal_available=false}
    end
    return b,w,s
end
local function clear() return {{contact={status="clear"}},{contact={status="clear"}}} end
local function selected(c)
    return Forces.controls({pedal=c.pedal or 0,steer=c.steer or 0,brake=c.brake or 0})
end
local function transport()
    local actual=RideStage.new()
    local f
    local observer={tuning=actual.tuning,hop_policy=actual.hop_policy}
    function observer:admit_measured(body) return actual:admit_measured(body) end
    function observer:preview(...)
        local model,candidate=actual:preview(...)
        f.previews+=1;f.last_model=M.copy(model)
        return model,candidate
    end
    function observer:_adopt(candidate) actual:_adopt(candidate);f.adoptions+=1 end
    function observer:invalidate_continuity() actual:invalidate_continuity() end
    f=Fixtures.fixture({models={force=observer,tricks=false}})
    f.previews,f.adoptions,f.acks=0,0,{}
    local receipt,acknowledge=f.api.receipt,f.api.acknowledge
    function f.api.receipt(sequence)
        local transaction=f.transactions[sequence]
        local age=transaction and Identity.bounded_delta(f.serial,transaction.requested,64)
        -- Even a lone command needs N+2. N+1 application is not its successor.
        f.successor=age and age>=2 and f.sample() or nil
        return receipt(sequence)
    end
    function f.api.acknowledge(sequence)
        f.acks[#f.acks+1]=sequence
        return acknowledge(sequence)
    end
    return f
end
function Tests.run()
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    local function case(run) cases+=1;run() end
    case(function()
        local c=RideStage.new()
        check(c.hop_policy=="suppress" and c.tuning.wheel_probe_extra==nil,
            "ride retains hop suppression and the ordinary probe policy")
        check(not pcall(RideStage.new,{stage="ride"}) and not pcall(RideStage.new,nil),
            "the new stage grants no runtime selection or cap configuration")
        local b,w,s=fixture()
        local out=Zero.new():preview(h,b,w,s,{pedal=1,steer=1,brake=1})
        check(out.valid and zero(out.force) and zero(out.torque) and not out.hop_applied,
            "the tracked public zero-force stage remains inert")
        local touched=0
        local api=setmetatable({}, {__index=function() touched+=1;error("unexpected native callback") end})
        local unqualified=Runtime.new(api,{force=c})
        check(unqualified:observe(nil,nil,nil).phase=="inert" and touched==0,
            "a source-selected ride stage cannot qualify the public runtime")
    end)
    for _,controls in ipairs({{}, {pedal=.6}, {steer=-1}, {steer=1}, {brake=1},
        {pedal=.4,steer=-.35,brake=.2}, {pedal=.4,steer=.35,brake=.2}}) do case(function()
        local b,w,s=fixture(.5)
        local before={body=M.copy(b),wheels=M.copy(w),samples=M.copy(s)}
        local c=RideStage.new()
        local input=M.copy(controls)
        input.manual=1;input.nose_manual=1;input.air_yaw=1
        input.hop_event_id=19;input.hop_strength=1;input.ground_pump=1
        input.pump_operator_available=true;input.rotation_reserved=true
        input.contact_compliance_available=true;input.landing_contact_compliance_selected=true
        table.freeze(input)
        local expected=Forces.new():preview(h,b,w,s,selected(controls))
        local out=c:preview(h,b,w,s,input)
        check(expected.valid and expected.contact_scale==1 and out.valid and equal(out,expected),
            "ride is the exact real-kernel pedal/steer/brake result, with every other input neutral")
        check(not out.hop_applied and out.hop_event_id==0 and zero(out.hop_impulse)
            and out.landing_approach_mask==0 and out.compliant_normal_mask==0,
            "ride cannot import the hop impulse or its landing law")
        if controls.steer then check(out.front_steer_angle*controls.steer<0,"signed steering reaches the model") end
        if controls.brake then
            check(math.abs(out.brake_impulse[1])+math.abs(out.brake_impulse[2])>0,"braking reaches the rolling wheel model")
        end
        if controls.pedal then check(out.effective_pedal_torque>0,"accepted pedal diagnostics retain effective axle torque") end
        check(equal(b,before.body) and equal(w,before.wheels) and equal(s,before.samples),
            "selection leaves measured state and contact provenance unchanged")
        check(input.manual==1 and input.hop_event_id==19 and input.contact_compliance_available,
            "selection never rewrites the caller's frozen action record")
    end) end
    case(function()
        local b,w,s=fixture()
        local nil_input=RideStage.new():preview(h,b,w,s,nil)
        local zeros=RideStage.new():preview(h,b,w,s,{pedal=0,steer=0,brake=0})
        check(nil_input.valid and equal(nil_input,zeros),"omitted controls mean exactly neutral driving channels")
    end)
    for name,values in pairs({pedal={-.01,1.01,math.huge,0/0,"1",false},
        steer={-1.01,1.01,math.huge,0/0,"1",false},brake={-.01,1.01,math.huge,0/0,"1",false}}) do
        for _,value in ipairs(values) do case(function()
            local b,w,s=fixture()
            local c=RideStage.new()
            local _,old=c:preview(h,b,w,s,{})
            local out,candidate=c:preview(h,b,w,s,{[name]=value})
            check(not out.valid and out.issue=="invalid_"..name and zero(out.force) and zero(out.torque),
                "malformed "..name.." refuses instead of clamping or defaulting")
            check(not pcall(c._adopt,c,candidate) and not pcall(c._adopt,c,old),
                "an invalid selected channel leaves neither refused nor previous preview adoptable")
        end) end
    end
    case(function()
        local b,w,s=fixture()
        local out=RideStage.new():preview(h,b,w,s,setmetatable({},{}))
        check(not out.valid and out.issue=="invalid_controls","a metatable cannot synthesize driving inputs")
        local c=Uncapped.new()
        local admitted,why=c:admit_measured(b)
        local refused,candidate=c:preview(h,b,w,s,{pedal=1,steer=.2,brake=.1})
        check(not admitted and why=="authored_caps_unavailable" and refused.issue==why,
            "ride without authored caps refuses measured admission and prediction")
        check(not pcall(c._adopt,c,candidate),"uncapped ride cannot adopt an output")
    end)
    case(function()
        local b,w=fixture()
        local c=RideStage.new()
        b.linear_velocity={0,0,3}
        local out,candidate=c:preview(h,b,w,clear(),{})
        check(c:admit_measured(b) and out.valid,"the ride total-speed boundary is inclusive")
        b.linear_velocity={0,3.001,0}
        local admitted,why=c:admit_measured(b)
        check(not admitted and why=="authored_speed_limit","ride bounds vertical motion in the same total-speed cap")
        check(pcall(c._adopt,c,candidate),"measured admission reads limits without consuming prediction history")
        local refused,invalid=c:preview(h,b,w,clear(),{})
        check(refused.issue=="authored_speed_limit" and not pcall(c._adopt,c,invalid),
            "forecast excess independently refuses without a clipped velocity")
        check(Hop.new():admit_measured(b),"hop retains its separate horizontal and vertical limits")
        b.linear_velocity={0,6.001,0}
        local hop_ok,hop_why=Hop.new():admit_measured(b)
        check(not hop_ok and hop_why=="authored_vertical_speed_limit","the existing hop vertical cap still refuses excess")
    end)
    for _,spec in ipairs({{module=LowForce,issue="authored_force_limit"},
        {module=LowTorque,issue="authored_torque_limit"}}) do case(function()
        local b,w,s=fixture()
        if spec.module==LowTorque then b.angular_velocity={.02,0,.04} end
        local expected=Forces.new():preview(h,b,w,s,Forces.controls())
        local c=spec.module.new()
        local out,candidate=c:preview(h,b,w,s,{})
        check(expected.valid and expected.contact_scale==1,"cap test starts from an unclamped real-kernel result")
        check(not out.valid and out.issue==spec.issue and out.diagnostic and out.diagnostic.diagnostic_only
            and not out.diagnostic.force_applied,"authored caps refuse with explicit unsent diagnostics")
        check(equal(out.diagnostic.force,expected.force) and equal(out.diagnostic.torque,expected.torque),
            "cap diagnostics preserve the full requested force and torque")
        check(zero(out.force) and zero(out.torque) and zero(out.hop_impulse)
            and not pcall(c._adopt,c,candidate),"a capped prediction emits no command or adoptable history")
    end) end
    case(function()
        local b,w,s=fixture(.4)
        local c,reference=RideStage.new(),Forces.new()
        local controls={pedal=.4,steer=.35,brake=.2}
        local expected,raw=reference:preview(h,b,w,s,selected(controls))
        local first,old=c:preview(h,b,w,s,controls)
        local out,candidate=c:preview(h,b,w,s,controls)
        check(out.valid and equal(first,out) and equal(out,expected),"unadopted previews never advance steering or wheel history")
        check(not pcall(c._adopt,c,old),"a newer preview invalidates the old token")
        local other=RideStage.new()
        local _,foreign=other:preview(h,b,w,s,controls)
        check(not pcall(c._adopt,c,foreign) and not pcall(c._adopt,c,raw),"foreign and raw-kernel tokens cannot bypass stage policy")
        local next_wheels=M.copy(expected.wheels)
        out.force[2]=math.huge;out.wheels[2].angular_speed=999
        c:_adopt(candidate);reference:_adopt(raw)
        check(not pcall(c._adopt,c,candidate),"the exact accepted candidate is adopted once")
        local next_controls={pedal=0,steer=-.2,brake=.3}
        local next_out=c:preview(h,b,next_wheels,s,next_controls)
        local next_expected=reference:preview(h,b,next_wheels,s,selected(next_controls))
        check(next_out.valid and equal(next_out,next_expected),"editable output cannot alter the private accepted history")
        local _,pending=c:preview(h,b,next_wheels,s,next_controls)
        c:invalidate_continuity()
        check(not pcall(c._adopt,c,pending),"continuity loss invalidates an unaccepted ride token")
    end)
    case(function()
        local b,w,s=fixture()
        local c,reference=Hop.new(),Forces.new()
        local controls={hop_event_id=7,hop_strength=.5,steer=1,brake=1}
        local chosen=Forces.controls({hop_event_id=7,hop_strength=.5,
            contact_compliance_available=true,landing_contact_compliance_selected=true})
        local expected,raw=reference:preview(h,b,w,s,chosen)
        local out,candidate=c:preview(h,b,w,s,controls)
        check(out.valid and out.hop_applied and out.hop_event_id==7 and equal(out,expected),
            "adding ride preserves the existing hop selection and its real one-shot impulse")
        c:_adopt(candidate);reference:_adopt(raw)
        local repeated=c:preview(h,b,expected.wheels,s,controls)
        local repeated_reference=reference:preview(h,b,expected.wheels,s,chosen)
        check(repeated.valid and not repeated.hop_applied and zero(repeated.hop_impulse) and equal(repeated,repeated_reference),
            "an adopted hop ID cannot apply again after the ride-stage addition")
    end)
    case(function()
        local f=transport()
        local first=f.observe();local original=first.pending_sequence
        f.advance();f.mode="applied";f.pad.left_x=.3;f.pad.buttons.b=true
        local second=f.observe();local next_sequence=f.sequence
        check(not second.stop_requested and second.submitted==2 and second.pending_count==2 and f.adoptions==2,
            "real Ride adopts each accepted bounded driving preview while retaining both receipts")
        check(f.last_model.valid and f.last_model.front_steer_angle<0 and f.command.impulse==nil,
            "actual mapping forwards steering without creating a ride-stage hop")
        check(second.model_history.sequence==next_sequence and next_sequence~=original,
            "accepted prediction follows the new exact sequence, not an older receipt")
        f.ride:stop("constructed stop with two accepted ride packets")
        f.advance(2)
        local drained=f.ride:drain()
        check(drained.stop_requested and not drained.force_pending and not drained.unknown
            and f.acks[1]==original and f.acks[2]==next_sequence,
            "stopped Ride still drains the exact accepted receipt prefix at N+2")
        check(f.adoptions==2 and drained.model_history.sequence==next_sequence,
            "ACK cleanup never re-adopts old force or presentation history")
    end)
    case(function()
        local f=transport()
        local first=f.observe();local original=first.pending_sequence
        f.advance();f.pad.buttons.right_stick=true
        local held=f.observe()
        check(not held.stop_requested and held.backpressure=="native_inbox_queued"
            and held.hop_disposition.disposition=="suppressed" and held.hop_disposition.confirmed,
            "ride locally suppresses R3 while an unrelated accepted force is queued")
        check(held.pending_count==1 and held.pending_sequence==original and f.transactions[original]~=nil
            and held.submitted==1 and f.adoptions==1,"hop suppression cannot erase or replace accepted force debt")
        f.ride:stop("constructed stop after suppressed hop")
        f.advance();f.mode="applied"
        local drained=f.ride:drain()
        check(not drained.force_pending and drained.acknowledged==1 and f.acks[1]==original and f.adoptions==1,
            "only the original command's actual N+2 receipt clears its debt")
    end)
    for _,fault in ipairs({"speed","submission"}) do case(function()
        local f=transport()
        local first=f.observe();local original=first.pending_sequence
        f.advance();f.mode="applied"
        local raw
        if fault=="speed" then raw=f.sample();raw.velocity=vector.create(0,0,3.001)
        else f.on_submit=function() return false,"busy" end end
        local stopped=f.observe(nil,raw)
        check(stopped.stop_requested and not stopped.unknown and stopped.pending_sequence==original
            and stopped.pending_count==1 and f.adoptions==1,
            "a "..fault.." refusal keeps earlier accepted debt and adopts no new prediction")
        if fault=="speed" then check(f.previews==1,"measured overspeed stops before any forecast preview") end
        f.advance()
        local drained=f.ride:drain()
        check(drained.stop_requested and not drained.force_pending and f.acks[1]==original and f.adoptions==1,
            "the older exact receipt remains drainable after "..fault.." refusal")
    end) end
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)

-- Source-selected private hop fixtures prove the proposed policy, not native
-- ride qualification. The shipped force_stage literal remains zero_force.
local Zero=require("./force_stage")
local Hop=require("./force_stage_hop_fixture")
local Uncapped=require("./force_stage_hop_uncapped_fixture")
local InvalidVertical=require("./force_stage_hop_invalid_vertical_fixture")
local LowVertical=require("./force_stage_hop_low_vertical_fixture")
local Forces=require("./forces")
local Solver=require("./force_solver")
local M=require("./force_math")
local Tests={}
local h=Forces.native_seconds
local function near(a,b) return math.abs(a-b)<1e-8 end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function fixture(gap,vertical,speed)
    local b,w=Forces.proposed_body(),Forces.proposed_wheels()
    b.center_of_mass={0,.9,-.05};b.linear_velocity={0,vertical or 0,speed or 2}
    for _,wheel in ipairs(w) do wheel.angular_speed=(speed or 2)/wheel.radius end
    local samples={}
    for i=1,2 do
        samples[i]={contact={status="hit",point={0,0,i==1 and .525 or -.525},normal={0,1,0},
            forward={0,0,1},surface_velocity={0,0,0}},separation=gap or 0,verified_plane=false,balance_normal_available=false}
    end
    return b,w,samples
end
-- Construct actual gravity-ray intersections with a plane through the origin.
-- The bike starts three degrees shallower than the plane so the strict 15 degree
-- ride limit is meaningful even for the signed 15 degree terrain fixtures.
local function sloped_fixture(degrees,axis)
    local radians=math.rad(degrees) local sign=degrees<0 and -1 or 1
    local body_angle=degrees==0 and 0 or math.rad(degrees-sign*3)
    local sine=math.sin(body_angle/2)
    local b,w=Forces.proposed_body(),Forces.proposed_wheels()
    b.orientation={axis[1]*sine,axis[2]*sine,axis[3]*sine,math.cos(body_angle/2)}
    local normal=M.around({0,1,0},axis,radians)
    local up=M.turn(b.orientation,{0,1,0})
    b.center_of_mass=M.mul(normal,w[1].radius+.3+.65*M.dot(normal,up))
    b.linear_velocity={0,-4,0}
    b.angular_velocity=degrees==0 and {0,0,0} or M.mul(axis,sign*.05)
    local samples,centers,projected={},{},{}
    local down={0,-1,0} local forward=M.basis(normal,M.turn(b.orientation,{0,0,1})).forward
    for i=1,2 do
        local center=M.add(b.center_of_mass,M.turn(b.orientation,{0,-.65,i==1 and .525 or -.525}))
        local hit=M.add(center,M.mul(down,-M.dot(normal,center)/M.dot(normal,down)))
        local separation=M.dot(M.sub(center,hit),normal)-w[i].radius
        centers[i]=center;projected[i]=M.sub(center,M.mul(normal,separation+w[i].radius))
        samples[i]={contact={status="hit",point=hit,normal=M.copy(normal),forward=M.copy(forward),surface_velocity={0,0,0}},
            separation=separation,verified_plane=false,balance_normal_available=false}
    end
    return b,w,samples,centers,projected
end
local function bounded_body(body,out)
    local b=M.copy(body)
    b.linear_velocity=M.add(M.add(b.linear_velocity,{0,-9.8*h,0}),M.mul(M.add(out.linear_impulse,out.hop_impulse),1/b.mass))
    b.angular_velocity=M.add(b.angular_velocity,M.tensor(b,out.angular_impulse,true))
    return b
end
local function clear() return {{contact={status="clear"}},{contact={status="clear"}}} end
local function selected(extra)
    local c=Forces.controls({contact_compliance_available=true,landing_contact_compliance_selected=true})
    for k,v in pairs(extra or {}) do c[k]=v end
    return c
end
function Tests.run()
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    local function case() cases+=1 end
    case() do
        local c=Hop.new();local zero=Zero.new()
        check(c.hop_policy=="grounded_once" and c.tuning.wheel_probe_extra==.75,"only the authored hop fixture declares its one-shot policy and longer current ray")
        check(zero.hop_policy=="suppress" and zero.tuning.wheel_probe_extra==nil,"shipped zero stage keeps its existing hop suppression and default ray length")
        check(not pcall(Hop.new,{stage="hop"}) and not pcall(Hop.new,nil),"hop has no runtime configuration seam")
        check(not pcall(function() c.hop_policy="suppress" end) and not pcall(function() c.tuning.wheel_probe_extra=10 end),"hop policy and probe declaration are immutable")
    end
    for _,module in ipairs({Uncapped,InvalidVertical}) do case() do
        local b,w,s=fixture();local c=module.new();local out,candidate=c:preview(h,b,w,s,{})
        check(not out.valid and out.issue=="authored_caps_unavailable" and not pcall(c._adopt,c,candidate),"hop requires a finite positive authored vertical cap as well as ordinary caps")
    end end
    case() do
        local b,w=fixture();local c=Hop.new();b.linear_velocity={0,4.5,2}
        check(c:preview(h,b,w,clear(),{}).valid,"full-hop vertical motion is not charged against the horizontal speed cap")
        b.linear_velocity={0,6,3}
        check(c:preview(h,b,w,clear(),{}).valid,"independent horizontal and vertical boundaries are inclusive")
        b.linear_velocity={0,0,3.001}
        check(c:preview(h,b,w,clear(),{}).issue=="authored_speed_limit","horizontal excess refuses without changing measured velocity")
        for _,vertical in ipairs({6.001,-6.001}) do
            b.linear_velocity={0,vertical,0}
            check(c:preview(h,b,w,clear(),{}).issue=="authored_vertical_speed_limit","vertical magnitude cap applies to ascent and descent")
        end
        b.linear_velocity={0,.11,0}
        check(LowVertical.new():preview(h,b,w,clear(),{}).issue=="authored_vertical_speed_limit","private low cap exercises the actual vertical guard")
    end
    for _,controls in ipairs({{hop_event_id=false},{hop_strength=false},{hop_event_id="1",hop_strength=1},
        {hop_event_id=1.5,hop_strength=1},{hop_event_id=-1,hop_strength=1},{hop_event_id=4294967296,hop_strength=1},
        {hop_event_id=math.huge,hop_strength=1},{hop_event_id=0/0,hop_strength=1},
        {hop_event_id=1,hop_strength=0},{hop_event_id=0,hop_strength=1},{hop_event_id=1,hop_strength=1.001},
        {hop_event_id=1,hop_strength=-.1},{hop_event_id=1,hop_strength=math.huge},{hop_event_id=1,hop_strength="1"}}) do case() do
        local b,w,s=fixture();local c=Hop.new();local out,candidate=c:preview(h,b,w,s,controls)
        check(not out.valid and out.issue=="invalid_hop" and not pcall(c._adopt,c,candidate),"hop ID and strength are finite, paired, and bounded; invalid inputs are never coerced")
    end end
    case() do
        local b,w,s=fixture();local c=Hop.new()
        local intent={hop_event_id=17,hop_strength=1,pedal=0,steer=1,brake=1,manual=1,air_yaw=1}
        local before=M.copy(intent);local out,candidate=c:preview(h,b,w,s,intent)
        check(out.valid and out.hop_applied and out.hop_event_id==17 and equal(out.hop_impulse,{0,477,0}),"actual eligible support permits the 106 kg full-hop impulse")
        check(equal(intent,before) and M.length(out.air_control_torque)==0,"stage retains Mapping input untouched and filters unrelated actions")
        check(c:preview(h,b,w,s,intent).hop_applied,"an unaccepted preview does not consume the event")
        local _,latest=c:preview(h,b,w,s,intent)
        check(not pcall(c._adopt,c,candidate) and pcall(c._adopt,c,latest),"only the latest exact acceptance adopts the hop event")
        local again=c:preview(h,b,w,s,intent)
        check(again.valid and not again.hop_applied and again.hop_event_id==0 and M.length(again.hop_impulse)==0,"the adopted event cannot hop twice")
        c:invalidate_continuity()
        check(not c:preview(h,b,w,s,intent).hop_applied,"receipt continuity loss does not forget an accepted hop")
    end
    case() do
        local b,w,s=fixture(.3,-4);local c=Hop.new()
        local out,candidate=c:preview(h,b,w,s,{hop_event_id=31,hop_strength=1})
        check(out.valid and not out.grounded and not out.hop_applied and out.hop_event_id==0,"a new airborne ID returns explicit ineligible hop output while the measured approach row can brake")
        c:_adopt(candidate)
        local ground_b,ground_w,ground_s=fixture()
        check(not c:preview(h,ground_b,ground_w,ground_s,{hop_event_id=31,hop_strength=1}).hop_applied,"adoption consumes an ineligible raw-kernel ID rather than saving a delayed ground hop")
    end
    case() do
        local b,w,s=fixture(.3,-4);local before=M.copy(s)
        local out=Forces.new():preview(h,b,w,s,selected({hop_event_id=1,hop_strength=1}))
        check(out.valid and out.landing_approach_mask==3 and out.compliant_normal_mask==0,"both current distant floor samples select only normal approach rows")
        check(not out.grounded and not out.hop_applied and out.balance_support_mask==0 and out.balance_continuation_mask==0,"distant braking has no support, continuation or hop authority")
        check(out.approach_normal_impulse[1]+out.approach_normal_impulse[2]>0 and equal(out.normal_load,{0,0}) and equal(out.normal_impulse,{0,0}),"approach impulse is separately attributed and never becomes tire load")
        check(equal(out.longitudinal_impulse,{0,0}) and equal(out.lateral_impulse,{0,0}) and near(out.force[1],0) and near(out.force[3],0),"current floor approach has no friction or horizontal actuation")
        check(equal(s,before) and out.contact_scale==1,"normal policy does not mutate measured rays or hide shared-budget clamping")
    end
    case() do
        local b,w,s=fixture(.3,-4);local legacy=Forces.new():preview(h,b,w,s,Forces.controls())
        check(legacy.valid and legacy.landing_approach_mask==0 and M.length(legacy.force)<1e-8,"default kernel still treats the same distant ray as clear")
        local explicit=Forces.new():preview(h,b,w,s,Forces.controls({contact_compliance_available=false,landing_contact_compliance_selected=false}))
        check(equal(legacy,explicit),"explicit disabled flags and ordinary defaults are recursively identical")
        for _,flags in ipairs({{contact_compliance_available=true},{landing_contact_compliance_selected=true}}) do
            check(Forces.new():preview(h,b,w,s,Forces.controls(flags)).issue=="unsupported_policy","either unpaired compliance flag refuses")
        end
        local proof=Forces.new():preview(h,b,w,s,selected(),{{selected=true}})
        check(not proof.valid and proof.issue=="unsupported_policy","external speculative proof cannot bypass the new current-ray policy")
    end
    for _,kind in ipairs({"clear","moving","wall","too_far","disabled"}) do case() do
        local b,w,s=fixture(.3,-4);local controls=selected()
        if kind=="clear" then s=clear()
        elseif kind=="moving" then for _,v in ipairs(s) do v.contact.surface_velocity={.01,0,0} end
        elseif kind=="wall" then for _,v in ipairs(s) do v.contact.normal={1,0,0} end
        elseif kind=="too_far" then for _,v in ipairs(s) do v.separation=.651 end
        else controls.enabled=false end
        local out=Forces.new():preview(h,b,w,s,controls)
        check(out.valid and out.landing_approach_mask==0 and not out.grounded and equal(out.approach_normal_impulse,{0,0}),"unsupported current observations never fabricate an approach plane: "..kind)
    end end
    case() do
        local b,w,s=fixture(.3,-4);s[1].contact={status="unavailable"}
        local out=Forces.new():preview(h,b,w,s,selected())
        check(not out.valid and out.issue=="unavailable_contact" and M.length(out.force)==0,"unavailable observation refuses instead of borrowing another wheel's plane")
    end
    case() do
        local b,w,s=fixture();s[1].contact.normal_only=true;s[1].contact.normal_softness=1;s[1].contact.normal_floor_delta=99
        local out=Forces.new():preview(h,b,w,s,Forces.controls())
        local _,_,clean=fixture()
        check(equal(out,Forces.new():preview(h,b,w,clean,Forces.controls())),"caller-supplied private solver flags cannot select or alter landing policy")
    end
    for _,vertical in ipairs({-1,-2}) do case() do
        local b,w=Forces.proposed_body(),Forces.proposed_wheels();b.linear_velocity={0,vertical,0}
        local gamma=.15/(100000*h*h)
        local contacts={{status="hit",point={0,0,0},normal={0,1,0},forward={0,0,1},surface_velocity={0,0,0},
            normal_softness=gamma,normal_floor_delta=-.015/h},{status="clear"}}
        local expected=math.max(0,-vertical/(1/b.mass+gamma),(-.015/h-vertical)*b.mass)
        local t=Forces.tuning({friction={longitudinal_friction=0,lateral_friction=0}})
        local predicted,_,effects=Solver.solve(h,b,w,contacts,t,0,{{1,0,0},{1,0,0}})
        check(predicted~=nil and near(effects[1].solved.normal_impulse,expected),"the normal response is max(native soft impulse, independent 15 mm floor impulse)")
        check(near(predicted.linear_velocity[2],vertical+expected/b.mass) and predicted.linear_velocity[2]*h>=-.015-1e-8,"repeated solver iterations preserve softness and the linear hard floor")
        t.contact_iterations=1
        local single=Solver.solve(h,b,w,contacts,t,0,{{1,0,0},{1,0,0}})
        check(near(single.linear_velocity[2],predicted.linear_velocity[2]),"an isolated compliant row does not harden when more iterations are requested")
    end end
    for _,erp in ipairs({0,1}) do case() do
        local b,w,s=fixture();local kernel=Forces.new({recovery_fraction=erp})
        check(kernel:preview(h,b,w,s,selected()).issue=="unsupported_policy","selected native compliance refuses ERP outside its open interval instead of silently becoming rigid")
        check(kernel:preview(h,b,w,s,Forces.controls()).valid,"unselected ordinary ERP endpoint behavior is unchanged")
    end end
    case() do
        local b,w,s=fixture(-.015-5e-9,0);local out=Forces.new():preview(h,b,w,s,selected())
        check(out.valid and out.compliant_normal_mask==3,"admission uses the same roundoff tolerance as the accepted final deflection bound")
    end
    case() do
        local b,w,s=fixture(-.016,-.1);local out=Forces.new():preview(h,b,w,s,selected())
        check(not out.valid and out.issue=="landing_deflection_limit" and M.length(out.force)==0,"an already over-deformed selected floor refuses without a corrective teleport")
    end
    case() do
        local b,w,s=fixture(0,-1);local out=Forces.new({force_limit=100}):preview(h,b,w,s,selected())
        check(not out.valid and out.issue=="landing_deflection_limit" and M.length(out.force)==0,"shared-budget scaling is rechecked against the actual final 15 mm point prediction")
    end
    case() do
        local b,w,s=fixture(.3,-6);local c=Hop.new();local out,candidate=c:preview(h,b,w,s,{})
        check(not out.valid and out.issue=="authored_force_limit" and out.diagnostic and M.length(out.diagnostic.force)>6000,"an excessive landing demand retains the unclamped prediction and refuses the authored force cap")
        check(M.length(out.force)==0 and M.length(out.hop_impulse)==0 and not pcall(c._adopt,c,candidate),"an over-cap landing never emits a clipped force or adopts its prediction")
    end
    for _,axis in ipairs({{1,0,0},{0,0,1}}) do for _,degrees in ipairs({-15,-12,12,15}) do case() do
        local b,w,s,centers,projected=sloped_fixture(degrees,axis)
        local before=M.copy(s);local out=Forces.new():preview(h,b,w,s,selected())
        check(out.valid and out.landing_approach_mask==3,"signed slope and camber rays select bounded approach rows")
        local expected,old_moment={0,0,0},{0,0,0}
        for i=1,2 do
            check(s[i].separation>.005 and s[i].separation<.65 and math.abs(M.dot(s[i].contact.point,s[i].contact.normal))<1e-8,
                "each measured gap comes from the actual ray/plane intersection")
            local impulse=M.mul(s[i].contact.normal,out.approach_normal_impulse[i])
            expected=M.add(expected,M.cross(M.sub(projected[i],b.center_of_mass),impulse))
            old_moment=M.add(old_moment,M.cross(M.sub(s[i].contact.point,b.center_of_mass),impulse))
            check(M.length(M.sub(M.cross(M.sub(projected[i],b.center_of_mass),impulse),
                M.cross(M.sub(M.sub(centers[i],M.mul(s[i].contact.normal,w[i].radius)),b.center_of_mass),impulse)))<1e-8,
                "normal projection and tyre touch have the same normal impulse moment")
        end
        check(M.length(M.sub(M.mul(out.contact_torque,h),expected))<1e-8 and M.length(M.sub(old_moment,expected))>.1,
            "the emitted moment uses the tyre projection, with a discriminator against the old gravity-hit arm")
        local final=bounded_body(b,out);local forward=M.turn(b.orientation,{0,0,1})
        check(math.abs(M.dot(final.angular_velocity,forward))<1,"signed camber and pitch stay below the one radian per second roll stop")
        local up=M.turn(b.orientation,{0,1,0});local rate=M.length(final.angular_velocity)
        if rate>1e-12 then up=M.around(up,M.mul(final.angular_velocity,1/rate),rate*h) end
        check(math.acos(math.clamp(M.dot(up,{0,1,0}),-1,1))<math.rad(15),"one-step tilted landing remains strictly below fifteen degrees")
        check(not out.grounded and out.balance_support_mask==0 and equal(out.normal_load,{0,0}) and equal(out.normal_impulse,{0,0})
            and equal(out.longitudinal_impulse,{0,0}) and equal(out.lateral_impulse,{0,0}),"approach remains normal-only without tire load or support authority")
        check(equal(s,before),"landing correction leaves the measured ray and provenance untouched")
    end end end
    case() do
        local b,w,s,centers,projected=sloped_fixture(0,{1,0,0})
        local plain=Forces.new():preview(h,b,w,s,selected())
        for i=1,2 do
            check(equal(projected[i],s[i].contact.point),"flat terrain has no downslope arm correction")
            s[i].wheel_center=centers[i];s[i].wheel_radius=w[i].radius;s[i].forecast_geometry_unavailable=false
        end
        local equipped=Forces.new():preview(h,b,w,s,selected())
        check(plain.valid and equal(plain,equipped),"exact hub metadata preserves flat-plane output")
    end
    case() do
        local b,w,s,_,projected=sloped_fixture(15,{0,0,1})
        -- The same center and ray now describe a larger front wheel. Its gap
        -- changes by the radius difference; the physical normal arm does not.
        w[1].radius+=.04;s[1].separation-=.04
        local out=Forces.new():preview(h,b,w,s,selected())
        check(out.valid and out.landing_approach_mask==3 and out.approach_normal_impulse[1]>0,"each approach uses the radius that defined its own measured separation")
        local expected={0,0,0}
        for i=1,2 do expected=M.add(expected,M.cross(M.sub(projected[i],b.center_of_mass),M.mul(s[i].contact.normal,out.approach_normal_impulse[i]))) end
        check(M.length(M.sub(M.mul(out.contact_torque,h),expected))<1e-8,"a nondefault wheel radius cannot create a spurious downslope lever")
    end
    for _,kind in ipairs({"legacy_forecast","radius_mismatch","missing_radius","inconsistent_hub"}) do case() do
        local b,w,s,centers=sloped_fixture(15,{0,0,1})
        for i=1,2 do s[i].wheel_center=centers[i];s[i].wheel_radius=w[i].radius end
        if kind=="legacy_forecast" then s[1].forecast_geometry_unavailable=true
        elseif kind=="radius_mismatch" then s[1].wheel_radius+=.01
        elseif kind=="missing_radius" then s[1].wheel_radius=nil
        else s[1].wheel_center=M.add(s[1].wheel_center,M.mul(s[1].contact.normal,.01)) end
        local before=M.copy(s);local out=Forces.new():preview(h,b,w,s,selected())
        check(not out.valid and out.issue=="landing_geometry_unavailable" and M.length(out.force)==0,
            "selected approach refuses missing or inconsistent forecast geometry: "..kind)
        check(equal(before,s),"geometry refusal preserves all supplied sample facts")
    end end
    -- This deliberately fast spin isolates the recheck location; it is not a
    -- normal ride acceptance case. The corrected normal arm is through the COM,
    -- while the old hit has an angular velocity that falsely predicts >15 mm.
    for _,limited in ipairs({false,true}) do case() do
        local b,w=Forces.proposed_body(),Forces.proposed_wheels()
        local normal={math.sin(math.rad(15)),math.cos(math.rad(15)),0};local gap=.006
        local center=M.mul(normal,w[1].radius+gap)
        b.center_of_mass=M.add(center,M.mul(normal,.65));b.linear_velocity={0,-4,0}
        b.angular_velocity=limited and {0,0,0} or {0,0,-15}
        local hit=M.add(center,{0,-(w[1].radius+gap)/normal[2],0})
        local s={{contact={status="hit",point=hit,normal=normal,forward={0,0,1},surface_velocity={0,0,0}},separation=gap},
            {contact={status="clear"}}}
        local out=Forces.new(limited and {force_limit=16000} or nil):preview(h,b,w,s,selected())
        if limited then
            check(not out.valid and out.issue=="landing_deflection_limit" and M.length(out.force)==0,
                "scaled approach recheck uses real surface velocity, not the artificial braking target")
        else
            check(out.valid and out.landing_approach_mask==1,"final deflection uses the same corrected normal arm as the solve")
            local final=bounded_body(b,out)
            local projected=M.sub(center,M.mul(normal,gap+w[1].radius))
            local correct_gap=gap+M.dot(M.point_velocity(final,projected),normal)*h
            local old_gap=gap+M.dot(M.point_velocity(final,hit),normal)*h
            check(correct_gap>=-.015 and old_gap<-.015,"the physical projection passes while the old ray-hit recheck would falsely refuse")
        end
    end end
    return {cases=cases,assertions=assertions,native_actions=0}
end
return Tests

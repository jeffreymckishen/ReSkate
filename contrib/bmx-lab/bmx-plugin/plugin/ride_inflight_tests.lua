local I=require("./ride_inflight")
local M=require("./force_math")
local Forces=require("./forces")
local Tests={}
local function fixture()
    local body={mass=2,inertia_body={2,3,4},center_of_mass={1,2,3},orientation={0,0,0,1},
        linear_velocity={2,0,-1},angular_velocity={0,0,0},metadata={labels={"measured"}}}
    local samples={{contact={status="hit",point={1,1,3},normal={0,1,0},forward={0,0,1},
        surface_velocity={.5,.2,0}},separation=.02,verified_plane=false},
        {contact={status="clear"},metadata={labels={"clear"}}}}
    return body,samples
end
local function command(age)
    return {age=age,force={4,12,-2},torque={0,3,0}}
end
local function freeze(value)
    if type(value)~="table" or table.isfrozen(value) then return end
    for _,item in value do freeze(item) end
    table.freeze(value)
end
function Tests.run()
    local cases,assertions=0,0
    local h,g=1/60,{0,-10,0}
    local function check(value,why) assertions+=1;assert(value,why) end
    local function near(a,b,tolerance) return math.abs(a-b)<=(tolerance or 1e-9) end
    local function vnear(a,b,tolerance) return M.length(M.sub(a,b))<=(tolerance or 1e-9) end
    local function refused(commands,body,samples,step,gravity)
        local result=table.pack(I.fold(step or h,gravity or g,commands,body,samples))
        check(result.n==2 and result[1]==nil and type(result[2])=="string","invalid data returns only nil/reason")
    end
    cases+=1 do
        local b,s=fixture()
        local predicted,rows=I.fold(h,g,{command(1)},b,s)
        local expected={2+2*h,-4*h,-1-h}
        check(predicted and rows and I.VISIBLE_STEPS==2,"fixed measured visibility horizon")
        check(vnear(predicted.linear_velocity,expected),"force and gravity retain donor velocity integration")
        check(vnear(predicted.angular_velocity,{0,h,0}),"torque keeps world-space inverse-inertia integration")
        check(vnear(predicted.center_of_mass,M.add(b.center_of_mass,M.mul(expected,h))),"semi-implicit body position preserved")
        check(near(predicted.orientation[2],math.sin(h*h/2)) and near(predicted.orientation[4],math.cos(h*h/2)),"world angular velocity advances normalized orientation")
        check(vnear(rows[1].contact.forward,{math.sin(h*h),0,math.cos(h*h)}),"accepted yaw torque advances the contact heading with the forecast body")
        check(near(rows[1].separation,.02+(expected[2]-.2)*h),"wheel separation uses relative normal approach")
        check(vnear(rows[1].contact.point,{1+expected[1]*h,1,3+expected[3]*h}),"contact point follows tangential body velocity")
        check(rows[2].contact.status=="clear" and rows[2].separation==nil and rows[2].contact.point==nil,"clear stays absent without fabricated geometry")
    end
    cases+=1 do
        for _,age in {0,2,64} do
            local b,s=fixture()
            local c=command(age);c.impulse={0,9,0};c.impulse_id=7
            local predicted=assert(I.fold(h,g,{c},b,s))
            check(vnear(predicted.linear_velocity,{2,-10*h,-1}) and vnear(predicted.angular_velocity,{0,0,0}),"age0 waits and age2+ is already visible")
        end
    end
    cases+=1 do
        local b,s=fixture()
        local c=command(1);c.impulse={1,9,-2};c.impulse_id=4294967295
        local predicted,rows=I.fold(h,g,{c},b,s)
        local expected={2+2*h+.5,-4*h+4.5,-2-h}
        check(vnear(predicted.linear_velocity,expected),"accepted impulse contributes J/m once without h scaling")
        check(near(rows[1].separation,.02+(expected[2]-.2)*h),"impulse velocity reaches the forecast wheel approach")
        check(vnear(predicted.angular_velocity,{0,h,0}),"COM impulse adds no invented angular impulse")
        local shorter=assert(I.fold(h/2,g,{c},b,s))
        check(near(shorter.linear_velocity[2],4.5-2*h),"impulse magnitude is independent of step duration")
    end
    cases+=1 do
        local b,s=fixture()
        local a,z,visible=command(1),command(0),command(2)
        a.impulse={0,9,0};a.impulse_id=1
        z.force={999,999,999};z.impulse={0,100,0};z.impulse_id=2
        visible.force={888,888,888};visible.impulse={0,200,0};visible.impulse_id=3
        local predicted=assert(I.fold(h,g,{z,visible,a},b,s))
        check(vnear(predicted.linear_velocity,{2+2*h,4.5-4*h,-1-h}),"only the age1 accepted command acts, independent of list ordering")
        local reordered=assert(I.fold(h,g,{a,z,visible},b,s))
        check(vnear(predicted.linear_velocity,reordered.linear_velocity),"list order cannot add extra impulses")
    end
    cases+=1 do
        -- Each call starts from its actual sample. Once the impulse is visible,
        -- age2 must not replay it into the prediction of the following interval.
        local b,s=fixture();b.linear_velocity={0,0,0}
        local c={age=0,force={0,0,0},torque={0,0,0},impulse={0,9,0},impulse_id=1}
        local pending=assert(I.fold(h,g,{c},b,s))
        check(near(pending.linear_velocity[2],-10*h),"acceptance age has no premature impulse")
        local next_body=M.copy(b);next_body.linear_velocity={0,-10*h,0};c.age=1
        local acting=assert(I.fold(h,g,{c},next_body,s))
        check(near(acting.linear_velocity[2],4.5-20*h),"first acting interval has exactly one impulse")
        local visible=M.copy(b);visible.linear_velocity={0,4.5-20*h,0};c.age=2
        local later=assert(I.fold(h,g,{c},visible,s))
        check(near(later.linear_velocity[2],4.5-30*h),"visible impulse is not applied for a second time")
    end
    cases+=1 do
        local b,s=fixture();local c=command(1);c.impulse={0,9,0};c.impulse_id=1
        local list={c};freeze(b);freeze(s);freeze(list)
        local predicted,rows=I.fold(h,g,list,b,s)
        check(predicted~=b and rows~=s and predicted.center_of_mass~=b.center_of_mass and rows[1].contact~=s[1].contact,"forecast owns detached body and contact tables")
        predicted.metadata.labels[1]="forecast";rows[2].metadata.labels[1]="forecast"
        rows[1].contact.normal[1]=.5
        check(b.metadata.labels[1]=="measured" and s[2].metadata.labels[1]=="clear" and s[1].contact.normal[1]==0,"nested metadata and untouched contact fields are detached")
        check(c.force[2]==12 and c.impulse[2]==9 and c.age==1 and b.linear_velocity[2]==0 and s[1].separation==.02,"fold never edits accepted commands or measured inputs")
        local again=assert(I.fold(h,g,list,b,s))
        check(near(again.linear_velocity[2],4.5-4*h),"repeated pure preview cannot accumulate an impulse in the source")
    end
    cases+=1 do
        local b,s=fixture();b.orientation={0,math.sin(math.pi/4),0,math.cos(math.pi/4)}
        local c={age=1,force={0,0,0},torque={4,0,0}}
        local predicted=assert(I.fold(h,{0,0,0},{c},b,s))
        check(vnear(predicted.angular_velocity,{h,0,0}),"turned anisotropic body keeps donor world torque response")
        local norm=0;for i=1,4 do norm+=predicted.orientation[i]^2 end
        check(near(norm,1),"forecast orientation remains unit length")
    end
    cases+=1 do
        local b,s=fixture()
        local predicted=assert(I.fold(h,g,{},b,s))
        check(vnear(predicted.linear_velocity,{2,-10*h,-1}),"empty accepted list forecasts gravity only")
        local c=command(1);c.impulse={0,0,0};c.impulse_id=1
        local zero=assert(I.fold(h,g,{c},b,s))
        check(vnear(zero.linear_velocity,{2+2*h,-4*h,-1-h}),"explicit zero impulse stays zero")
        check(I.fold(h,g,{command(1)},b,{})~=nil,"empty wheel array has no fabricated contact")
    end
    cases+=1 do
        local b,s=fixture()
        for _,age in {-1,.5,65,math.huge,0/0,"1"} do local c=command(age);refused({c},b,s) end
        refused({command(1),command(1)},b,s)
        refused({command(0),command(0)},b,s)
        refused({[2]=command(1)},b,s)
        refused({command(1),extra=true},b,s)
        local c=command(1);c.accepted=false;refused({c},b,s)
    end
    cases+=1 do
        local b,s=fixture()
        for _,age in {0,1,2} do
            for _,key in {"force","torque"} do
                local c=command(age);c[key]=nil;refused({c},b,s)
                c=command(age);c[key]={0,math.huge,0};refused({c},b,s)
                c=command(age);c[key]={[1]=0,[3]=0};refused({c},b,s)
                c=command(age);c[key]={0,0,0,0};refused({c},b,s)
            end
        end
    end
    cases+=1 do
        local b,s=fixture()
        local c=command(1);c.impulse={0,9,0};refused({c},b,s)
        c=command(1);c.impulse_id=1;refused({c},b,s)
        for _,id in {0,-1,.5,4294967296,math.huge,"1"} do
            c=command(1);c.impulse={0,9,0};c.impulse_id=id;refused({c},b,s)
        end
        c=command(2);c.impulse={0,0/0,0};c.impulse_id=1;refused({c},b,s)
        local a,z=command(1),command(0)
        a.impulse={0,9,0};a.impulse_id=1;z.impulse={0,9,0};z.impulse_id=1
        refused({a,z},b,s)
    end
    cases+=1 do
        local b,s=fixture()
        for _,step in {0,-h,.100001,math.huge,0/0,"60"} do refused({},b,s,step) end
        refused({},b,s,h,{0,math.huge,0})
        refused({},b,s,h,{0,-10,0,1})
        refused({},b,s,h,{[1]=0,[3]=0})
    end
    cases+=1 do
        for _,edit in {
            function(b) b.mass=0 end,
            function(b) b.inertia_body[1]=0 end,
            function(b) b.orientation={0,0,0,0} end,
            function(b) b.orientation[5]=0 end,
            function(b) b.linear_velocity[2]=0/0 end,
            function(b) b.center_of_mass[4]=0 end,
            function(b) b.angular_velocity[2]=nil end} do
            local b,s=fixture();edit(b);refused({},b,s)
        end
    end
    cases+=1 do
        for _,edit in {
            function(s) s[1].contact.status="unavailable" end,
            function(s) s[1].contact.point=nil end,
            function(s) s[1].contact.normal={0,2,0} end,
            function(s) s[1].contact.forward=nil end,
            function(s) s[1].contact.forward={0,0,0} end,
            function(s) s[1].contact.forward={0,1,0} end,
            function(s) s[1].contact.forward={0,0,1,0} end,
            function(s) s[1].contact.surface_velocity={51,0,0} end,
            function(s) s[1].separation=math.huge end,
            function(s) s[2]=nil;s[3]={contact={status="clear"}} end} do
            local b,s=fixture();edit(s);refused({},b,s)
        end
    end
    cases+=1 do
        local b,s=fixture()
        refused(setmetatable({},{}),b,s)
        local c=command(1);setmetatable(c.force,{});refused({c},b,s)
        b.metadata.self=b.metadata;refused({},b,s)
        b,s=fixture();s[1].opaque=newproxy();refused({},b,s)
        b,s=fixture();local at=b.metadata
        for _=1,20 do at.next={};at=at.next end
        refused({},b,s)
    end
    cases+=1 do
        local b,s=fixture();b.mass=1e-9
        local c={age=1,force={1e5,0,0},torque={0,0,0}}
        refused({c},b,s)
        check(b.center_of_mass[1]==1 and b.linear_velocity[1]==2 and s[1].separation==.02,"overflow refusal leaves every measured input intact")
    end
    for _,yaw_rate in {-2,2} do cases+=1 do
        local step=Forces.native_seconds
        local b,w=Forces.proposed_body(),Forces.proposed_wheels()
        b.center_of_mass={0,.9,0};b.linear_velocity={0,0,2};b.angular_velocity={0,yaw_rate,0}
        local s={}
        for i=1,2 do
            w[i].angular_speed=2/w[i].radius
            s[i]={contact={status="hit",point={0,0,i==1 and .5 or -.5},normal={0,1,0},
                forward={0,0,1},surface_velocity={0,0,0}},separation=0,verified_plane=false,balance_normal_available=false}
        end
        local accepted={{age=1,force={0,b.mass*9.8,0},torque={0,0,0}}}
        freeze(b);freeze(s);freeze(accepted)
        local predicted,rows=I.fold(step,{0,-9.8,0},accepted,b,s)
        check(predicted~=nil,"yawing supported body has a forecast without mutating frozen measurements")
        local heading={math.sin(yaw_rate*step),0,math.cos(yaw_rate*step)}
        for i=1,2 do
            check(vnear(rows[i].contact.forward,heading) and vnear(s[i].contact.forward,{0,0,1}),"both tire headings follow forecast yaw while measured headings remain unchanged")
            check(vnear(rows[i].contact.normal,s[i].contact.normal) and not rows[i].verified_plane,"heading projection preserves measured normals and plane provenance")
        end
        local out=Forces.new():preview(step,predicted,w,rows,Forces.controls())
        check(out.valid and out.balance_support_mask==3 and out.front_steer_angle==0 and not out.steering_limited,"zero-steer yaw remains supported without a steering correction")
        check(near(out.turning_lean_angle,0) and M.length(out.balance_torque)<1e-8,"forecast yaw alone requests no turn lean or balance torque")
        local reference=M.copy(rows)
        for _,sample in ipairs(reference) do sample.contact.forward=M.copy(heading) end
        local expected=Forces.new():preview(step,predicted,w,reference,Forces.controls())
        check(expected.valid and vnear(out.force,expected.force,1e-7) and vnear(out.torque,expected.torque,1e-7)
            and near(out.wheels[1].angular_speed,expected.wheels[1].angular_speed,1e-8)
            and near(out.wheels[2].angular_speed,expected.wheels[2].angular_speed,1e-8),"actual tire response matches independently calculated forecast headings on both wheels")
        for _,sample in ipairs(reference) do sample.contact.forward={0,0,1} end
        local stale=Forces.new():preview(step,predicted,w,reference,Forces.controls())
        check(stale.valid and math.abs(stale.turning_lean_angle)>1e-3 and M.length(stale.balance_torque)>1,"regression detects the spurious lean caused by retaining measured headings")
    end end
    cases+=1 do
        local b,s=fixture();b.angular_velocity={0,2,0}
        s[2]=M.copy(s[1]);s[2].contact.normal={0,.6,.8};s[2].verified_plane=false
        local original=M.copy(s);freeze(b);freeze(s)
        local predicted,rows=I.fold(h,g,{},b,s)
        check(predicted~=nil,"distinct measured slope normals remain forecastable")
        local forward=M.turn(predicted.orientation,{0,0,1})
        for i=1,2 do
            local normal=original[i].contact.normal
            local projected=M.unit(M.sub(forward,M.mul(normal,M.dot(forward,normal))))
            check(vnear(rows[i].contact.forward,projected) and near(M.dot(rows[i].contact.forward,normal),0),"forecast heading is projected independently onto each retained measured normal")
            check(vnear(rows[i].contact.normal,normal) and vnear(rows[i].contact.surface_velocity,original[i].contact.surface_velocity)
                and rows[i].verified_plane==original[i].verified_plane,"projection changes no measured plane or surface velocity")
        end
    end
    cases+=1 do
        local b,s=fixture();b.angular_velocity={math.pi/(2*h),0,0}
        local original=M.copy(s);freeze(b);freeze(s)
        local predicted,why=I.fold(h,{0,0,0},{},b,s)
        check(predicted==nil and why=="fold contact heading invalid","a forecast heading parallel to the measured normal refuses instead of inventing a tangent")
        check(vnear(s[1].contact.forward,original[1].contact.forward) and vnear(s[1].contact.normal,original[1].contact.normal)
            and near(s[1].separation,original[1].separation),"degenerate forecast refusal leaves the measured contact intact")
        local clear=I.fold(h,{0,0,0},{},b,{{contact={status="clear"}}})
        check(clear~=nil,"the same orientation needs no tangent or invented normal for a clear row")
    end
    cases+=1 do
        local b,s=fixture()
        local shared={1,2,3}
        local a={age=1,force=shared,torque=shared,impulse=shared,impulse_id=19}
        local z={age=0,force=shared,torque=shared}
        local commands={a,z};freeze(shared);freeze(commands);freeze(b);freeze(s)
        local predicted,rows=I.fold(h,g,commands,b,s)
        check(predicted~=nil,"shared frozen command vectors are read without ownership transfer")
        predicted.linear_velocity[1]=999;predicted.angular_velocity[2]=999;rows[1].contact.forward[1]=999
        check(shared[1]==1 and shared[2]==2 and shared[3]==3 and a.force==z.force and a.torque==a.impulse,
            "forecast output owns no alias into shared command vectors")
        local repeated=assert(I.fold(h,g,commands,b,s))
        check(near(repeated.linear_velocity[1],2+h/2+.5),"output mutation cannot change a later preview of borrowed commands")
    end
    cases+=1 do
        local b,s=fixture()
        b.center_of_mass={0,0,0};b.linear_velocity={0,0,0};b.angular_velocity={0,1e5,0}
        s[1].contact.point={1e6,0,0}
        local predicted,why=I.fold(.1,{0,0,0},{},b,s)
        check(predicted==nil and why=="fold contact invalid","transformed contact overflow refuses even with a bounded forecast body")
        check(s[1].contact.point[1]==1e6 and s[1].contact.point[3]==0,"overflow leaves the measured point intact")
    end
    cases+=1 do
        local b,s=fixture()
        local predicted,rows=I.fold(h,{0,0,0},{},b,s)
        check(predicted~=nil and rows[1].forecast_geometry_unavailable==true and s[1].forecast_geometry_unavailable==nil,
            "legacy zero-gravity folds remain available and explicitly lack exact wheel geometry")
        s[1].wheel_center={1,1.28,3};s[1].wheel_radius=.26
        predicted,rows=I.fold(h,{0,0,0},{},b,s)
        check(predicted==nil and rows=="fold contact geometry invalid","exact gravity-ray geometry refuses an unavailable gravity direction")
        for _,edit in {
            function(row) row.wheel_radius=nil end,
            function(row) row.wheel_center=nil end,
            function(row) row.wheel_radius=0 end,
            function(row) row.wheel_center={1.05,1.28,3} end,
            function(row) row.separation=.04 end} do
            local bad=M.copy(s);edit(bad[1])
            local body,why=I.fold(h,g,{},b,bad)
            check(body==nil and why=="fold contact geometry invalid","partial, displaced or inconsistent wheel geometry is refused")
        end
    end
    for _,axis in {{1,0,0},{0,0,1}} do
        for _,angle in {-15,-12,0,12,15} do cases+=1 do
            local radians=math.rad(angle)
            local normal=M.around({0,1,0},axis,radians)
            local down={0,-1,0}
            local b=Forces.proposed_body()
            b.center_of_mass={0,1.1,0};b.linear_velocity={.3,-3,.8};b.angular_velocity={.35,.25,-.3}
            local surface={.2,.1,-.15}
            local centers={{0,.7,.5},{0,.7,-.5}}
            local rows={}
            for i,center in ipairs(centers) do
                local gap=M.dot(center,normal)
                rows[i]={wheel_center=M.copy(center),wheel_radius=Forces.wheel_radius,
                    separation=gap-Forces.wheel_radius,verified_plane=false,balance_normal_available=false,
                    contact={status="hit",point=M.add(center,M.mul(down,gap/-M.dot(down,normal))),
                        normal=M.copy(normal),forward=M.basis(normal,{0,0,1}).forward,surface_velocity=M.copy(surface)}}
            end
            local pending={{age=1,force={0,0,0},torque={3,2,-1},impulse={0,4,0},impulse_id=27}}
            local before=M.copy(rows);freeze(rows);freeze(pending);freeze(b)
            local forecast,out=I.fold(h,{0,-9.8,0},pending,b,rows)
            check(forecast~=nil,"rotating pending-receipt forecast accepts a physically consistent signed plane ray")
            local rate=M.length(forecast.angular_velocity)
            local rotation_axis=M.mul(forecast.angular_velocity,1/rate)
            for i,row in ipairs(out) do
                local expected_center=M.add(forecast.center_of_mass,M.around(M.sub(centers[i],b.center_of_mass),rotation_axis,rate*h))
                local expected_gap=M.dot(M.sub(expected_center,M.mul(surface,h)),normal)
                check(vnear(row.wheel_center,expected_center,1e-9) and near(row.separation,expected_gap-Forces.wheel_radius),
                    "hub uses rigid rotation and separation uses the translated measured plane")
                check(vnear(row.contact.point,M.add(expected_center,M.mul(down,expected_gap/-M.dot(down,normal))),1e-9)
                    and near(M.dot(M.sub(row.contact.point,M.mul(surface,h)),normal),0),
                    "forecast contact remains a gravity ray intersection on the advanced plane")
                local dn=M.dot(down,normal)
                local approach_point=M.sub(row.contact.point,M.mul(M.sub(down,M.mul(normal,dn)),
                    (row.separation+row.wheel_radius)/-dn))
                local touch=M.sub(expected_center,M.mul(normal,row.wheel_radius))
                check(vnear(M.cross(M.sub(approach_point,forecast.center_of_mass),normal),
                    M.cross(M.sub(touch,forecast.center_of_mass),normal),1e-9),
                    "corrected approach arm has the actual tyre's normal moment after rotation")
                check(row.forecast_geometry_unavailable==false and row.verified_plane==false and row.balance_normal_available==false
                    and vnear(row.contact.surface_velocity,surface) and vnear(row.contact.normal,normal),
                    "forecast keeps measured motion, normals and unverified contact provenance")
                local old_point_v=M.add(forecast.linear_velocity,M.cross(forecast.angular_velocity,M.sub(before[i].contact.point,b.center_of_mass)))
                local old_gap=before[i].separation+M.dot(M.sub(old_point_v,surface),normal)*h
                local old_point=M.add(before[i].contact.point,M.mul(M.sub(old_point_v,M.mul(normal,M.dot(old_point_v,normal))),h))
                check(math.abs(old_gap-row.separation)>1e-6 or M.length(M.sub(old_point,row.contact.point))>1e-5,
                    "the regression detects original-hit angular prediction instead of a rigid hub")
                check(vnear(rows[i].wheel_center,centers[i]) and vnear(rows[i].contact.point,before[i].contact.point),
                    "frozen measured hubs and ray hits remain intact")
            end
            out[1].wheel_center[1]=99
            check(rows[1].wheel_center[1]==0 and pending[1].impulse_id==27,"forecast hub mutation cannot reach measured geometry or receipt event")
        end end
    end
    cases+=1 do
        local b,s=fixture()
        b.orientation={0,math.sin(.4)*math.sqrt(1.0005),0,math.cos(.4)*math.sqrt(1.0005)}
        b.linear_velocity={0,0,0};b.angular_velocity={0,0,0}
        s[1].wheel_center={1.2,1.28,3.4};s[1].wheel_radius=.26
        s[1].contact.point={1.2,1,3.4};s[1].contact.surface_velocity={0,0,0}
        local held={{age=1,force={0,20,0},torque={0,0,0}}}
        local forecast,rows=I.fold(h,g,held,b,s)
        check(forecast~=nil and vnear(rows[1].wheel_center,s[1].wheel_center,1e-9),
            "accepted near-unit orientation normalization cannot move a nonrotating hub")
        check(vnear(forecast.center_of_mass,b.center_of_mass) and near(rows[1].separation,s[1].separation),
            "zero net acceleration and spin preserve the measured geometry")
    end
    cases+=1 do
        -- A stationary plane makes the actual landing law eligible. The
        -- accepted pending torque/impulse changes the forecast before that law.
        local normal={math.sin(math.rad(12)),math.cos(math.rad(12)),0}
        local b,wheels=Forces.proposed_body(),Forces.proposed_wheels()
        b.center_of_mass={0,.75,0};b.orientation={0,math.sin(.2),0,math.cos(.2)}
        b.linear_velocity={0,-4.2,.4};b.angular_velocity={.15,.2,-.1}
        local samples={}
        for i,z in ipairs({.4,-.4}) do
            local center={0,.56,z};local gap=M.dot(center,normal)
            samples[i]={wheel_center=center,wheel_radius=wheels[i].radius,
                separation=gap-wheels[i].radius,verified_plane=false,balance_normal_available=false,
                contact={status="hit",point=M.add(center,{0,-gap/normal[2],0}),normal=M.copy(normal),
                    forward=M.basis(normal,M.turn(b.orientation,{0,0,1})).forward,surface_velocity={0,0,0}}}
        end
        local pending={{age=1,force={0,0,0},torque={1,2,-1},impulse={0,4,0},impulse_id=43}}
        freeze(b);freeze(samples);freeze(pending)
        local forecast,rows=I.fold(h,{0,-9.8,0},pending,b,samples)
        check(forecast~=nil,"stationary camber keeps exact geometry through a rotating accepted receipt forecast")
        local controls=Forces.controls({contact_compliance_available=true,landing_contact_compliance_selected=true})
        local out=Forces.new():preview(h,forecast,wheels,rows,controls)
        check(out.valid and out.landing_approach_mask==3 and out.approach_normal_impulse[1]+out.approach_normal_impulse[2]>0,
            "the actual force law brakes both geometry-equipped forecast contacts")
        local moment={0,0,0}
        for i,row in ipairs(rows) do
            local touch=M.sub(row.wheel_center,M.mul(normal,row.wheel_radius))
            moment=M.add(moment,M.cross(M.sub(touch,forecast.center_of_mass),M.mul(normal,out.approach_normal_impulse[i])))
        end
        check(vnear(M.mul(out.contact_torque,h),moment,1e-8),
            "pending rotation followed by landing uses the actual tyre normal moment")
        check(not out.grounded and out.balance_support_mask==0 and out.normal_load[1]==0 and out.normal_load[2]==0
            and out.longitudinal_impulse[1]==0 and out.longitudinal_impulse[2]==0
            and out.lateral_impulse[1]==0 and out.lateral_impulse[2]==0,
            "forecast approach cannot grant support or friction authority")
        local final_w=M.add(forecast.angular_velocity,M.tensor(forecast,out.angular_impulse,true))
        check(math.abs(M.dot(final_w,M.turn(forecast.orientation,{0,0,1})))<1,
            "stationary pending-receipt approach stays below the one radian per second roll stop")
        local up=M.turn(forecast.orientation,{0,1,0});local rate=M.length(final_w)
        if rate>1e-12 then up=M.around(up,M.mul(final_w,1/rate),rate*h) end
        check(math.acos(math.clamp(M.dot(up,{0,1,0}),-1,1))<math.rad(15),
            "stationary pending-receipt approach keeps predicted tilt below fifteen degrees")
        local unsupported=M.copy(rows);unsupported[1].wheel_center=nil;unsupported[1].wheel_radius=nil
        unsupported[1].forecast_geometry_unavailable=true
        check(Forces.new():preview(h,forecast,wheels,unsupported,controls).issue=="landing_geometry_unavailable",
            "the same approach refuses when exact forecast geometry is explicitly unavailable")
        check(pending[1].impulse_id==43 and samples[1].forecast_geometry_unavailable==nil,
            "the composed preview preserves the accepted event and measured sample")
    end
    return {cases=cases,assertions=assertions}
end
return Tests

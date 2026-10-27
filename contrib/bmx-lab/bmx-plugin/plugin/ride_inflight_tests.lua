local I=require("./ride_inflight")
local M=require("./force_math")
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
    if type(value)~="table" then return end
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
    return {cases=cases,assertions=assertions}
end
return Tests

-- Pure injected observations only; not a Host, SDK or native sampler run.
local Sampler=require("./sampler")
local Bones=require("./bones")
local Tests={}
local function copy(v) if type(v)~="table" then return v end local r={}for k,x in pairs(v)do r[k]=copy(x)end return r end
local by_id={}for _,b in ipairs(Bones)do by_id[b.id]=b end
local function bounded(value,depth,seen,budget)
    depth,seen,budget=depth or 0,seen or {},budget or {n=0}
    budget.n+=1;assert(budget.n<5000 and depth<10,"DTO must remain bounded")
    local kind=type(value)
    if kind=="number"then assert(value==value and math.abs(value)<=9007199254740991,"DTO number must be finite/safe")
    elseif kind=="string"then assert(#value<=2000,"DTO string must be bounded")
    elseif kind=="table"then
        assert(not seen[value],"DTO cannot contain cycles/aliased hidden objects");seen[value]=true
        for key,v in pairs(value)do assert(type(key)=="string"or type(key)=="number","DTO key must be plain");bounded(v,depth+1,seen,budget)end
    else assert(kind=="boolean"or kind=="nil","DTO must contain plain data only")end
end
local function fixture()
    local f={now=1000,calls=0,facts_calls=0,by_id={},hand_calls=0}
    f.facts={level="constructed-level",focused=true,gameplay=true,interface_open=true,native_menu_open=false,
        skater=true,watch_valid=true,state=504,ragdoll_known=true,ragdoll=false,teleport_pending=false,
        airborne=false,telemetry_airborne=false,position={2,3,4},telemetry_position={2,3,4},
        heading=0,telemetry_heading=0,speed=0,vertical_speed=0,telemetry_speed=0,telemetry_vertical=0}
    local function row(id) return {position={id/100,1,2},rotation={0,0,0,1},scale=1,parent=by_id[id].parent} end
    f.model=Sampler.new({
        now=function()if f.on_now then return f.on_now(f)end f.now+=.01;return f.now end,
        facts=function()f.facts_calls+=1;local r=copy(f.facts);if f.on_facts then f.on_facts(r,f)end return r end,
        joint=function(id)
            f.calls+=1;f.by_id[id]=(f.by_id[id]or 0)+1
            if f.by_id[id]==1 then return nil end
            local r=row(id);if f.on_joint then return f.on_joint(r,id,f)end return r
        end,
        hand=function(side)
            f.calls+=1;f.hand_calls+=1
            local r=row(side=="left"and 278 or 49);r.parent=nil;r.scale=nil
            if f.on_hand then return f.on_hand(r,side,f)end return r
        end,
    },Bones)
    function f.step()
        local before=f.calls;f.now+=16;local status=f.model:step()
        assert(f.calls-before<=2 and f.calls<=32,"bounded pose work per tick/attempt")
        return status
    end
    function f.finish()
        for _=1,24 do if f.model:result()then break end f.step()end
        local dto=f.model:result();bounded(dto);return dto
    end
    return f
end
function Tests.run()
    local cases,assertions=0,0
    local function check(v,why)assertions+=1;assert(v,why)end
    local function test(fn)cases+=1;fn()end
    test(function()
        local f=fixture();f.step();check(f.calls==0 and f.facts_calls==0,"idle constructor/tick touches no read provider")
        check(f.model:request(),"first explicit capture accepted")
        local dto=f.finish();check(dto and dto.phase=="complete"and #dto.joints==14,"all exact finite joint observations retained")
        check(dto.pose_reads==32 and f.calls==32 and f.hand_calls==2 and dto.warm_nil==14,"strict32 total budget includes warm/hand/root calls")
        check(dto.root_angle==0 and dto.root_drift==0 and dto.stationary_observed,"stationary sampled root accepted")
        check(dto.coherent_pose==false and dto.native_authority==false and dto.body_relative==false and dto.same_actor_known==false,"no invented authority/calibration")
        check(dto.first_facts.interface_open==true and dto.last_facts.state==504,"SDK overlay does not imply game inactivity")
        check(not f.model:request(),"one-shot capture cannot rearm")
        f.step();check(f.calls==32,"terminal capture performs no more pose reads")
        dto.joints[1].position[1]=999;check(f.model:result().joints[1].position[1]~=999,"result is detached from retained observations")
        for _,r in ipairs(dto.joints)do check(r.parent==by_id[r.requested_id].parent and r.read_begin_ms<=r.read_end_ms,"exact parent and honest individual read interval")end
    end)
    test(function()
        local f=fixture();f.on_joint=function(r,id,x)if id==1 and x.by_id[id]==4 then r.rotation={0,0,0,-1}end return r end
        f.model:request();local d=f.finish();check(d.phase=="complete"and d.root_angle==0,"q and -q are equivalent stationary root rotations")
    end)
    test(function()
        local f=fixture();f.on_hand=function(r)r.position[1]+=3;return r end;f.model:request();local d=f.finish()
        check(d.phase=="complete"and math.abs(d.hand_residuals.left.position-3)<1e-9,"staggered hand/joint residual is diagnostic only")
    end)
    local bad_joints={
        {"NaNposition",function(r)r.position[2]=0/0 end,"joint_position_invalid"},
        {"infiniteposition",function(r)r.position[1]=math.huge end,"joint_position_invalid"},
        {"nilposition",function(r)r.position=nil end,"joint_position_invalid"},
        {"NaNrotation",function(r)r.rotation[4]=0/0 end,"joint_rotation_invalid"},
        {"zerorotation",function(r)r.rotation={0,0,0,0}end,"joint_rotation_invalid"},
        {"nonunitrotation",function(r)r.rotation={0,0,0,2}end,"joint_rotation_invalid"},
        {"parent",function(r)r.parent=999 end,"joint_parent_mismatch"},
        {"nilparent",function(r)r.parent=nil end,"joint_parent_mismatch"},
        {"scale",function(r)r.scale=0 end,"joint_scale_invalid"},
    }
    for _,bad in ipairs(bad_joints)do test(function()
        local f=fixture();f.on_joint=function(r,id)if id==47 then bad[2](r)end return r end
        f.model:request();local d=f.finish();check(d.phase=="partial"and d.issue==bad[3],bad[1].." refused")
        check(#d.joints==2 and d.stationary_observed==false,"partial capture preserves only prior finite rows")
        local reads=f.calls;f.step();check(f.calls==reads and reads<32,"invalid row has no retry or remaining reads")
    end)end
    test(function()
        local f=fixture();f.on_joint=function(r,id)if id==47 then return nil end return r end
        f.model:request();local d=f.finish();check(d.phase=="partial"and d.issue=="joint_unavailable"and #d.joints==2,"post-warm nil stays partial and unknown")
    end)
    test(function()
        local f=fixture();f.on_hand=function()return nil end;f.model:request();local d=f.finish()
        check(d.phase=="partial"and d.issue=="hand_unavailable"and #d.joints==14,"missing hand copy does not fabricate a complete capture")
    end)
    local facts_faults={
        {function(r)r.focused=false end,"focus_or_menu_lost"},
        {function(r)r.gameplay=false end,"focus_or_menu_lost"},
        {function(r)r.native_menu_open=true end,"focus_or_menu_lost"},
        {function(r)r.ragdoll_known=false end,"upright_onfoot_unknown"},
        {function(r)r.ragdoll=true end,"upright_onfoot_unknown"},
        {function(r)r.teleport_pending=true end,"upright_onfoot_unknown"},
        {function(r)r.state=100 end,"upright_onfoot_unknown"},
        {function(r)r.speed=.051 end,"movement_observed"},
        {function(r)r.telemetry_vertical=.051 end,"movement_observed"},
        {function(r)r.speed=0/0 end,"movement_unknown"},
        {function(r)r.heading=1e300 end,"movement_unknown"},
    }
    for _,bad in ipairs(facts_faults)do test(function()
        local f=fixture();f.on_facts=function(r,x)if x.facts_calls>=25 then bad[1](r)end end
        f.model:request();local d=f.finish();check(d.phase=="partial"and d.issue==bad[2],"current pre/post facts refuse capture")
        local n=f.calls;f.step();check(f.calls==n,"loss of readiness stops later pose reads")
    end)end
    for _,bad in ipairs({
        {function(r)r.position[1]+=.021 end,"movement_observed"},
        {function(r)r.telemetry_heading=math.deg(.021) end,"movement_observed"},
        {function(r)r.level="changed"end,"context_changed"},
    })do test(function()
        local f=fixture();f.on_facts=function(r,x)if x.facts_calls>=25 then bad[1](r)end end
        f.model:request();local d=f.finish();check(d.phase=="partial"and d.issue==bad[2],"context/drift cannot reuse earlier stationary observations")
    end)end
    for _,change in ipairs({
        function(r)r.position[1]+=.011 end,
        function(r)r.rotation={0,math.sin(.02),0,math.cos(.02)}end,
    })do test(function()
        local f=fixture();f.on_joint=function(r,id,x)if id==1 and x.by_id[id]==4 then change(r)end return r end
        f.model:request();local d=f.finish();check(d.phase=="partial"and d.issue=="root_movement_observed","root drift/rotation conservatively refuses calibration eligibility")
    end)end
    test(function()
        local f=fixture();f.model:request();for _=1,12 do f.step()end
        local n=f.calls;f.model:cancel();local d=f.model:result();check(d.phase=="partial"and d.issue=="cancelled","cancel latches partial result")
        f.step();check(f.calls==n and not f.model:request(),"cancel cannot resume or reacquire")
    end)
    test(function()
        local f=fixture();f.model:request();f.step();f.on_now=function(x)return x.now-100 end
        local d=f.finish();check(d.phase=="partial"and d.issue=="clock_unknown","clock reversal is unknown, not a new sample time")
    end)
    test(function()
        local f=fixture();f.model:request();f.step();f.now+=1501
        local d=f.finish();check(d.phase=="partial"and d.issue=="deadline"and d.pose_reads==2,"deadline retains partial reads without widening budget")
    end)
    test(function()
        local f=fixture();f.facts.extra=function()error("not data")end
        f.on_joint=function(r)r.position.extra=0/0;r.rotation.extra=function()end;return r end
        f.model:request();local d=f.finish()
        check(d.phase=="complete"and d.first_facts.extra==nil and d.joints[1].position.extra==nil and d.joints[1].rotation.extra==nil,
            "only whitelisted bounded SDK fields enter the DTO")
    end)
    test(function()
        local f=fixture();f.on_facts=function(r,x)if x.facts_calls>=25 then r.focused=false end end
        f.model:request();local d=f.finish()
        check(d.phase=="partial"and d.refused_facts.focused==false and d.refused_facts.state==504,
            "failed current facts remain observed rather than replaced by last known ready data")
    end)
    test(function()
        local f=fixture();f.on_joint=function(r,id)if id==47 then error("constructed read exception")end return r end
        f.model:request();local d=f.finish()
        check(d.phase=="partial"and d.issue=="read_exception"and #d.joints==2,"read exception preserves partial finite observations")
    end)
    test(function()
        local f=fixture();f.model:request();f.step();f.on_now=function()return 0/0 end
        local d=f.finish();check(d.phase=="partial"and d.issue=="clock_unknown","nonfinite clock is never serialized as a sample time")
    end)
    test(function()
        local f=fixture();f.on_hand=function(r)r.rotation={0,0,0,0};return r end
        f.model:request();local d=f.finish();check(d.phase=="partial"and d.issue=="hand_transform_invalid","hand API has its own finite/unit-transform guard")
    end)
    test(function()
        local f=fixture();f.model:request();f.model:cancel();local d=f.model:result();bounded(d)
        check(d.phase=="partial"and d.pose_reads==0 and d.start_ms==nil and f.facts_calls==0,"cancel before first sample fabricates no timestamps or reads")
    end)
    -- Telemetry is degrees; get.heading and the .02 drift limit are radians.
    test(function()
        local f=fixture();f.facts.telemetry_heading=338.3581848144531
        f.on_facts=function(r,x)if x.facts_calls>=25 then r.telemetry_heading+=2*math.pi end end
        f.model:request();local d=f.finish()
        check(d.phase=="partial"and d.issue=="movement_observed","2*pi DEGREES cannot alias a zero-radian change")
        check(d.refused_facts.telemetry_heading==338.3581848144531+2*math.pi,"raw refused telemetry degrees remain available")
    end)
    test(function()
        local f=fixture();f.facts.telemetry_heading=338.3581848144531
        f.on_facts=function(r,x)if x.facts_calls>=25 then r.telemetry_heading-=360 end end
        f.model:request();local d=f.finish()
        check(d.phase=="complete","full360-degree equivalence does not invent movement")
        check(d.first_facts.telemetry_heading==338.3581848144531 and d.last_facts.telemetry_heading==338.3581848144531-360,"raw endpoints retain their degrees")
        check(d.heading_units.heading=="radians"and d.heading_units.telemetry_heading=="degrees"and d.heading_units.drift_limit=="radians","DTO labels source units without claiming coherence")
    end)
    test(function()
        local f=fixture();f.facts.telemetry_heading=359.8
        f.on_facts=function(r,x)if x.facts_calls>=25 then r.telemetry_heading=.2 end end
        f.model:request();local d=f.finish()
        check(d.phase=="complete","359.8 to .2 degrees is a .4-degree shortest change within .02 radians")
    end)
    for _,change in ipairs({.019,-.019,.021,-.021})do
        test(function()
            local f=fixture();f.facts.telemetry_heading=338.3581848144531
            f.on_facts=function(r,x)if x.facts_calls>=25 then r.telemetry_heading+=math.deg(change)end end
            f.model:request();local d=f.finish()
            check(d.phase==(math.abs(change)<.02 and "complete"or "partial"),"signed degree source uses the unchanged .02-radian threshold")
            if math.abs(change)>.02 then check(d.issue=="movement_observed","over-threshold degree source is refused")end
        end)
    end
    return {cases=cases,assertions=assertions}
end
return Tests

-- Constructed SDK DTOs passed through the actual decoder, never native/support proof.
local Contact=require("./contact_runtime")
local Tests={}
local function copy(value)
    if type(value)~="table" then return value end
    local out={} for key,child in pairs(value) do out[key]=copy(child) end return out
end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for key,value in pairs(a) do if not equal(value,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function fixture()
    local epoch,body,lease=newproxy(),newproxy(),newproxy()
    local sample={epoch=epoch,serial="9007199254740993",time=1,seconds=1/60,mass=106,
        position=vector.create(0,1,0),velocity=vector.create(0,0,0),angular_velocity=vector.create(0,0,0),
        inertia=vector.create(26,32,10),rotation={0,0,0,1}}
    local source={lease_handle=lease,generation=1,user=0,packet=1,sequence="9007199254740995",
        source_epoch="9007199254740997",context_generation="9007199254740999",
        observation_serial="9007199254741001",observed_ms="9007199254741003"}
    local frame={valid=true,fresh=true,body_handle=body,physics_epoch=epoch,
        serial=sample.serial,time=sample.time,seconds=sample.seconds,sample=sample,source=source,
        body={mass=106,center_of_mass={0,1,0},linear_velocity={0,0,0},angular_velocity={0,0,0},
            inertia_body={26,32,10},orientation={0,0,0,1}},
        owner={body_handle=body,lease_handle=lease},gates={focused=true,menu_open=false}}
    local plan,batch={},{status="available",epoch=epoch,native_casts=2,budget_exhausted=false,
        local_actor_excluded=true,owned_bodies_excluded=true,rays={}}
    for i=1,2 do
        plan[i]={from=vector.create(i-1,2,0),to=vector.create(i-1,0,0)}
        batch.rays[i]={status="hit",fraction=.5,position=vector.create(i-1,1,0),normal_available=true,
            normal=vector.create(0,1,0),surface_velocity_available=true,
            surface_velocity=vector.create(0,0,0),motion="measured"}
    end
    return frame,plan,batch
end
function Tests.run(case_done)
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    local function next_case()
        if case_done and cases>0 then case_done(cases,assertions) end
        cases+=1
    end
    local function unqualified(out,why)
        check(out.force_ready==false and out.support.known==false and out.support.grounded_known==false,why)
    end
    next_case() do
        local frame,plan,batch=fixture()
        local old=Contact.decode(frame,plan,batch)
        batch.requested_query_preset=nil
        local omitted=Contact.decode(frame,plan,batch)
        check(old.valid and old.status=="available" and equal(old,omitted),"omitted/nil echo retains exact earlier DTO behavior")
        check(old.query.requested_query_preset==nil and old.query.measurements_complete,"omission adds no metadata or missing measurements")
        unqualified(old,"ordinary measured ray geometry remains unqualified support")
    end
    for _,preset in ipairs({"camera","terrain"}) do
        for _,status in ipairs({"available","unavailable"}) do next_case() do
            local frame,plan,batch=fixture()
            batch.requested_query_preset=preset
            if status=="unavailable" then
                -- All nine actual SDK fields: reason and explicit preset coexist.
                batch.status="unavailable";batch.reason="actor exclusion unavailable";batch.native_casts=0
                batch.local_actor_excluded=false;batch.owned_bodies_excluded=false
                batch.rays={{status="unavailable"},{status="unavailable"}}
            end
            local out=Contact.decode(frame,plan,batch)
            check(out.valid and out.status==status and out.query.requested_query_preset==preset,"exact preset echo accepted for "..status)
            check(out.query.local_actor_excluded==batch.local_actor_excluded
                and out.query.owned_bodies_excluded==batch.owned_bodies_excluded
                and out.query.native_casts==batch.native_casts,"echo preserves actual exclusion/accounting flags")
            unqualified(out,"echo never qualifies execution, terrain/static hits or physical support")
            local public=Contact.public_snapshot(out)
            check(public.binding==nil and public.query.requested_query_preset==preset,"public echo remains metadata without opaque identity")
            batch.requested_query_preset="changed"
            check(out.query.requested_query_preset==preset and not pcall(function() out.query.requested_query_preset="changed" end),"metadata result is detached/frozen")
        end end
    end
    for _,value in ipairs({"","none","static","Camera","TERRAIN","camera\0","terrain\0suffix",0,true,false,{},newproxy()}) do next_case() do
        local frame,plan,batch=fixture();batch.requested_query_preset=value
        local out=Contact.decode(frame,plan,batch)
        check(not out.valid and out.reason=="malformed_batch","unknown/type/case/NUL preset refuses whole batch")
        check(out.query.requested_query_preset==nil,"malformed echo is not relayed as metadata")
        unqualified(out,"malformed echo grants no support")
    end end
    for _,name in ipairs({"status","epoch","native_casts","budget_exhausted","local_actor_excluded","owned_bodies_excluded","rays"}) do next_case() do
        local frame,plan,batch=fixture();batch[name]=nil
        local old=Contact.decode(frame,plan,batch)
        batch.requested_query_preset="terrain"
        local out=Contact.decode(frame,plan,batch);local stripped=copy(out);stripped.query.requested_query_preset=nil
        check(not out.valid and equal(old,stripped),"preset cannot rescue missing required "..name)
        unqualified(out,"required-field refusal preserved")
    end end
    local guards={
        {"actor false",function(_,batch) batch.local_actor_excluded=false end},
        {"owned false",function(_,batch) batch.owned_bodies_excluded=false end},
        {"stale epoch",function(_,batch) batch.epoch=newproxy() end},
        {"frame not fresh",function(frame) frame.fresh=false end},
        {"budget exhausted",function(_,batch) batch.budget_exhausted=true end},
        {"bad accounting",function(_,batch) batch.native_casts="2" end},
        {"unknown field",function(_,batch) batch.executed_query_preset="terrain" end},
        {"malformed contact",function(_,batch) batch.rays[2].normal=nil end},
    }
    for _,guard in ipairs(guards) do next_case() do
        local frame,plan,batch=fixture();guard[2](frame,batch)
        local old=Contact.decode(frame,plan,batch)
        batch.requested_query_preset="camera"
        local out=Contact.decode(frame,plan,batch);local stripped=copy(out);stripped.query.requested_query_preset=nil
        check(equal(old,stripped),"preset changes no preexisting guard result: "..guard[1])
        unqualified(out,"guard output cannot gain support from echo")
        if guard[1]=="actor false" then
            check(out.valid and out.query.local_actor_excluded==false and out.force_reason=="actor_exclusion_unqualified","request echo is not actor exclusion evidence")
        elseif guard[1]=="malformed contact" then
            check(not out.valid and out.rays[1].status=="unavailable" and out.rays[2].status=="unavailable"
                and not out.rays[1].visual_hit,"one bad contact drops the entire batch")
        end
    end end
    if case_done then case_done(cases,assertions) end
    return {cases=cases,assertions=assertions}
end
return Tests

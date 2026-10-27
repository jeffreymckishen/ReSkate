-- Constructed transport and geometry only. Every model below is the real
-- Ride, Mapping, category-lane Contact and staged ForceStage/Forces implementation.
-- A clear authored tripwire proves neither native actor exclusion nor gameplay.
local Runtime=require("./ride_runtime")
local Fixtures=require("./ride_runtime_tests")
local Contact=require("./contact_runtime")
local QualifiedContact=require("./contact_runtime_category_qualified_fixture")
local Stage=require("./force_stage")
local Support=require("./force_stage_support_fixture")
local Pedal=require("./force_stage_pedal_fixture")
local LowCap=require("./force_stage_low_cap_fixture")
local UncappedSupport=require("./force_stage_support_uncapped_fixture")
local UncappedPedal=require("./force_stage_pedal_uncapped_fixture")
local Forces=require("./forces")
local Identity=require("./lease_identity")
local G=require("./bike_geometry")
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
local function magnitude(value)
    return math.sqrt(value[1]^2+value[2]^2+value[3]^2)
end
local function zero(value) return value[1]==0 and value[2]==0 and value[3]==0 end
local function fixture(stage,options)
    options=options or {}
    local actual=stage.new()
    local f
    -- This observer only records the real result. It does not supply controls,
    -- model values, candidates or history; all three operations delegate exactly.
    local observer={tuning=actual.tuning,hop_policy=actual.hop_policy}
    function observer:admit_measured(body) return actual:admit_measured(body) end
    function observer:preview(...)
        local args=table.pack(...)
        local model,candidate=actual:preview(...)
        f.previews[#f.previews+1]={args=copy(args),model=copy(model)}
        return model,candidate
    end
    function observer:_adopt(candidate) actual:_adopt(candidate);f.adoptions+=1 end
    function observer:reset() actual:reset();f.resets+=1 end
    f=Fixtures.fixture({models={contact=QualifiedContact,force=observer,tricks=false}})
    f.previews={};f.commands={};f.probes={};f.adoptions=0;f.resets=0
    if options.velocity then
        local sample=f.sample
        function f.sample() local out=sample();out.velocity=options.velocity;return out end
    end
    local submit=f.api.submit
    function f.api.submit(epoch,command)
        f.commands[#f.commands+1]=copy(command)
        return submit(epoch,command)
    end
    function f.api.probe_batch(epoch,rays,query)
        f.probes[#f.probes+1]={epoch=epoch,rays=rays,query=copy(query)}
        local out={status="available",epoch=epoch,native_casts=#rays,budget_exhausted=false,
            local_actor_excluded=false,owned_bodies_excluded=true,named_actor_categories_absent=true,
            requested_query_preset="camera",rays={}}
        for i,ray in ipairs(rays) do
            if #rays==2 then
                local fraction=G.wheel_radius/(G.wheel_radius+.15)
                out.rays[i]={status="hit",fraction=fraction,position=ray.from+(ray.to-ray.from)*fraction,
                    normal_available=true,normal=vector.create(0,1,0),surface_velocity_available=true,
                    surface_velocity=vector.create(0,0,0),motion="measured"}
            else out.rays[i]={status="clear"} end
        end
        if #rays==3 and options.tripwire_unavailable then
            out.named_actor_categories_absent=false
        end
        return out
    end
    local receipt=f.api.receipt
    function f.api.receipt(sequence)
        local pending=f.transactions[sequence]
        local steps=pending and Identity.bounded_delta(f.serial,pending.requested,64)
        -- N+1 application is not N+2 successor evidence, including when this
        -- is the only pending receipt. Bind proof eligibility to each record.
        f.successor=steps and steps>=2 and f.sample() or nil
        return receipt(sequence)
    end
    function f.next()
        f.advance()
        f.mode="applied"
        return f.observe()
    end
    return f
end
-- Finding 3 regression: real model graph, fresh reports for 204 ms after a
-- suppressed R3 edge. On the reviewed baseline this stops around step seven.
-- The fixture alone owns transport receipts; suppression must invent none.
function Tests.run()
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    for _,entry in ipairs({{"zero_force",Stage},{"support",Support},{"pedal",Pedal}}) do
        cases+=1
        local name,stage=entry[1],entry[2]
        local f=fixture(stage)
        local first=f.observe()
        check(first.submitted==1 and not first.stop_requested,"initial "..name.." graph is riding")
        local press_ms=f.ms
        f.pad.buttons.right_stick=true
        if name=="pedal" then f.pad.buttons.a=true end
        local out
        for _=1,12 do out=f.next() end
        local elapsed=Identity.bounded_delta(f.ms,press_ms,1000)
        check(elapsed and elapsed>100,"fresh-report trace exceeds the original hop expiry window")
        check(not out.stop_requested and out.submitted==13 and out.input_consumed==13,
            name.." must keep riding after a suppressed hop; got "..tostring(out.issue))
        local mapped=f.mapping:status()
        check(mapped.valid and mapped.active and mapped.pending_hop==nil and mapped.hop_counter==1,
            "suppression clears the exact pending request without re-prime or minting held-input events")
        check(mapped.last_retired and mapped.last_retired.disposition=="suppressed" and mapped.last_retired.event.id==1
            and mapped.uncertain==nil,"policy suppression is distinguished from native acceptance or uncertainty")
        local no_impulse=true
        for _,command in ipairs(f.commands) do no_impulse=no_impulse and command.impulse==nil and command.impulse_id==nil end
        check(no_impulse and #f.commands==13,"every accepted command remains free of native hop fields")
        check(out.acknowledged==11,"ordinary ordered force receipts still retire independently of suppressed input")
        f.pad.buttons.right_stick=false;f.next()
        f.pad.buttons.right_stick=true
        for _=1,12 do out=f.next() end
        mapped=f.mapping:status()
        check(not out.stop_requested and out.submitted==26 and mapped.pending_hop==nil and mapped.hop_counter==2,
            "a later genuine press is suppressed independently without expiry or ID reuse")
        check(mapped.last_retired and mapped.last_retired.disposition=="suppressed" and mapped.last_retired.event.id==2,
            "the second policy-only retirement retains its exact distinct identity")
        for _,command in ipairs(f.commands) do no_impulse=no_impulse and command.impulse==nil and command.impulse_id==nil end
        check(no_impulse and out.acknowledged==24,"repeated suppression never adds a fake hop command or receipt")
    end
    return {cases=cases,assertions=assertions,native_actions=0}
end
return table.freeze(Tests)

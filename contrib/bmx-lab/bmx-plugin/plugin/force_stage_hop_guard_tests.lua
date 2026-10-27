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
-- Fault injection at the pure mapper boundary. The real model graph must stop
-- before a second force packet when local suppression cannot be reconciled.
function Tests.run()
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    for _,failure in ipairs({"refusal","throw","reentry","changed_frame"}) do
        cases+=1
        local f=fixture(Stage);f.observe()
        local retire=f.mapping.retire_hop
        if failure=="refusal" then
            function f.mapping:retire_hop() return false,"hop_identity_mismatch" end
        elseif failure=="throw" then
            function f.mapping:retire_hop(id,disposition)
                retire(self,id,disposition);error("local suppression result unavailable",0)
            end
        elseif failure=="reentry" then
            function f.mapping:retire_hop(id,disposition)
                local ok,why=retire(self,id,disposition)
                f.ride:stop("constructed suppression reentry")
                return ok,why
            end
        else
            local controls=f.mapping.controls;local calls=0
            function f.mapping:controls(context)
                calls+=1
                local out=controls(self,context)
                if calls==2 then out.physics_epoch=newproxy() end
                return out
            end
        end
        f.pad.buttons.right_stick=true;local out=f.next()
        check(out.stop_requested and out.unknown,"suppression "..failure.." stops with unreconciled local state")
        check(out.submitted==1 and #f.commands==1 and #f.previews==1 and f.adoptions==1,
            "failed suppression never reaches another force preview, admission or history adoption")
        local mapped=f.mapping:status()
        if failure=="refusal" then
            check(mapped.pending_hop and mapped.pending_hop.id==1 and out.hop_disposition.confirmed==false,
                "explicit refusal retains the original request without claiming its retirement")
        else
            check(mapped.pending_hop==nil and mapped.last_retired.disposition=="suppressed",
                "a local retirement that did happen is never relabeled as native acceptance")
        end
        check(f.commands[1].impulse==nil and out.pending_count==1 and out.acknowledged==0,
            "unknown suppression preserves original native force debt and fabricates no hop receipt")
    end
    return {cases=cases,assertions=assertions,native_actions=0}
end
return table.freeze(Tests)

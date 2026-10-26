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
    local observer={tuning=actual.tuning}
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
function Tests.run()
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    local function case(_,run) cases+=1;run() end
    case("tracked gates remain closed",function()
        local touched=0
        local api=setmetatable({}, {__index=function() touched+=1;error("unqualified native callback") end})
        local ride=Runtime.new(api,{contact=QualifiedContact,force=Stage.new()})
        check(ride:observe(nil,nil,nil).phase=="inert" and touched==0,"a force stage grants no Ride activation")
        check(Contact.CATEGORY_WHEEL_LANE_QUALIFIED==false,"the tracked Contact lane stays unqualified")
    end)
    case("zero stage diagnoses real support but submits no force",function()
        local f=fixture(Stage);local out=f.observe()
        check(out.submitted==1 and not out.stop_requested and #f.previews==1,"real graph reaches exactly one accepted preview")
        local model=f.previews[1].model
        check(model.valid and model.diagnostic.valid and magnitude(model.diagnostic.force)>100,"actual kernel calculates nonzero support before the zero stage")
        check(model.diagnostic.diagnostic_only==true and model.diagnostic.force_applied==false,"kernel result is explicitly diagnostic")
        for _,name in ipairs({"force","torque","linear_impulse","angular_impulse","hop_impulse"}) do
            check(zero(model[name]),"zero stage has zero "..name)
        end
        check(not model.hop_applied and model.hop_event_id==0 and f.command.impulse==nil,"diagnostic hop cannot become a command")
        check(equal(model.wheels,f.previews[1].args[3]),"unapplied diagnostic wheel changes are not adopted as prediction")
        check(f.command.force==vector.create(0,0,0) and f.command.torque==vector.create(0,0,0),"native packet contains only zero vectors")
        check(#f.probes==2 and #f.probes[1].rays==2 and #f.probes[2].rays==3,"actual category lane requires wheel rays and rider tripwire")
        for _,probe in ipairs(f.probes) do
            check(probe.epoch==f.read.epoch and probe.query.query_preset=="camera"
                and probe.query.require_named_actor_categories_absent==true and probe.query.exclude_local_actor==nil,
                "both real decodes use the exact category query and measured epoch")
        end
        check(f.adoptions==1 and f.resets==0,"exact acceptance adopts only the wrapper candidate")
    end)
    case("support and neutral pedal are identical through ACKs",function()
        local support,pedal=fixture(Support),fixture(Pedal)
        for step=1,6 do
            local a=step==1 and support.observe() or support.next()
            local b=step==1 and pedal.observe() or pedal.next()
            check(not a.stop_requested and not b.stop_requested and a.submitted==step and b.submitted==step,"each real native-serial fixture admits one command")
            check(equal(support.previews[step].model,pedal.previews[step].model),"neutral pedal returns the entire support model exactly")
            check(equal(support.commands[step],pedal.commands[step]),"neutral packets match through accepted histories and ordered ACKs")
        end
        check(magnitude(support.previews[1].model.force)>100,"support equality is not two inert zero models")
        check(support.ride:status().acknowledged==4 and pedal.ride:status().acknowledged==4,"both exact synthetic transport ledgers ACK the oldest four commands")
        check(support.adoptions==6 and pedal.adoptions==6 and support.resets==0 and pedal.resets==0,"ACK never resets either real force history")
    end)
    case("pedal ignores the other mapped controls",function()
        local plain,extra,neutral=fixture(Pedal),fixture(Pedal),fixture(Support)
        plain.observe();extra.observe();neutral.observe()
        plain.pad.buttons.a=true;extra.pad.buttons.a=true;neutral.pad.buttons.a=true
        extra.pad.buttons.b=true;extra.pad.buttons.right_stick=true
        extra.pad.buttons.lb=true;extra.pad.buttons.rb=true
        extra.pad.left_x=.8;extra.pad.left_y=-.6;extra.pad.right_x=.7;extra.pad.right_y=-.8
        extra.pad.left_trigger=.8;extra.pad.right_trigger=.9
        local a,b,c=plain.next(),extra.next(),neutral.next()
        check(not a.stop_requested and not b.stop_requested and a.submitted==2 and b.submitted==2,"real Mapping admits both fresh action frames")
        local mapped=extra.previews[2].args[5]
        check(mapped.pedal==1 and mapped.brake>0 and mapped.steer~=0 and mapped.hop_strength>0,"the test actually sends pedal, brake, steering and hop into the wrapper")
        check(equal(plain.previews[2].model,extra.previews[2].model),"nonpedal actions cannot alter the real pedal-stage model")
        check(equal(plain.commands[2],extra.commands[2]) and extra.command.impulse==nil,"nonpedal actions cannot escape into native packet fields")
        check(not c.stop_requested and c.submitted==2 and not equal(plain.previews[2].model,neutral.previews[2].model),
            "positive pedal differs from support with identical prior accepted history")
        check(extra.mapping:status().pending_hop~=nil,"ignored hop remains a Mapping request, not fabricated receipt retirement")
    end)
    case("over-cap support stops instead of clamping",function()
        local f=fixture(LowCap);local out=f.observe()
        check(out.stop_requested and out.issue=="bounded force packet unavailable","invalid wrapper model stops the real Ride")
        check(out.submitted==0 and not out.force_pending and #f.commands==0 and f.adoptions==0,"over-cap packet creates no native debt or accepted history")
        check(#f.previews==1 and f.previews[1].model.valid==false,"cap refusal is reached after actual category decoding")
        local args=f.previews[1].args
        local raw=Forces.new():preview(args[1],args[2],args[3],args[4],Forces.controls())
        check(raw.valid and magnitude(raw.force)>100 and raw.contact_scale==1,"unclamped real support exceeds the synthetic 100 N authored cap")
        f.next();check(#f.previews==1 and #f.commands==0,"stopped graph never retries an over-cap force")
    end)
    for _,stage in ipairs({UncappedSupport,UncappedPedal}) do
        case("unselected authored caps cannot produce a packet",function()
            local f=fixture(stage);local out=f.observe()
            check(out.stop_requested and out.issue=="bounded force packet unavailable","missing authored decision refuses the nonzero stage")
            check(out.submitted==0 and #f.commands==0 and f.adoptions==0,"nil caps never silently use kernel or SDK ceilings")
        end)
    end
    case("real kernel clamp cannot pass as a bounded stage",function()
        local f=fixture(Support,{velocity=vector.create(0,-8,0)});local out=f.observe()
        check(out.stop_requested and out.submitted==0 and #f.commands==0,"bounded incoming speed does not authorize a clamped solver result")
        check(#f.previews==1 and f.previews[1].model.valid==false,"nonzero wrapper refuses before packet construction")
        local args=f.previews[1].args
        local raw=Forces.new():preview(args[1],args[2],args[3],args[4],Forces.controls())
        check(raw.valid and raw.contact_scale<1,"constructed impact actually reaches the real kernel contact scaling branch")
        check(f.adoptions==0,"an invalid diagnostic candidate cannot advance accepted force history")
    end)
    case("category refusal precedes every force preview",function()
        local f=fixture(Pedal,{tripwire_unavailable=true});local out=f.observe()
        check(out.stop_requested and out.issue=="rider tripwire lane or binding unavailable","actual decoder refuses missing category exclusion evidence")
        check(#f.probes==2 and #f.previews==0 and #f.commands==0,"stage wrapper cannot bypass the qualified lane's refusal")
    end)
    return {cases=cases,assertions=assertions,native_actions=0}
end
return table.freeze(Tests)

-- Measured admission and predictive limits are separate checks. The first
-- accepted packet below is constructed; later guards and previews are the real
-- source-selected ForceStage over the actual Ride/Mapping receipt path.
local Fixtures=require("./ride_runtime_tests")
local Hop=require("./force_stage_hop_fixture")
local Support=require("./force_stage_support_fixture")
local Pedal=require("./force_stage_pedal_fixture")
local Zero=require("./force_stage")
local Uncapped=require("./force_stage_support_uncapped_fixture")
local InFlight=require("./ride_inflight")
local Forces=require("./forces")
local M=require("./force_math")
local Tests={}
local h=Forces.native_seconds
local function clear() return {{contact={status="clear"}},{contact={status="clear"}}} end
local function body(velocity)
    local out=Forces.proposed_body()
    out.linear_velocity=M.copy(velocity)
    return out
end
local function count(f,name)
    local total=0
    for _,call in ipairs(f.calls) do if call==name then total+=1 end end
    return total
end
local function fixture(options)
    options=options or {}
    local actual=Hop.new()
    local first={}
    local f
    local proxy={tuning=actual.tuning,hop_policy=actual.hop_policy}
    function proxy:admit_measured(measured)
        f.guards[#f.guards+1]=measured
        assert(table.isfrozen(measured) and table.isfrozen(measured.linear_velocity),
            "measured admission receives the detached immutable native body")
        if options.guard then return options.guard(measured) end
        return actual:admit_measured(measured)
    end
    function proxy:preview(seconds,forecast,wheels,samples,controls)
        local entry={body=M.copy(forecast)}
        f.previews[#f.previews+1]=entry
        if #f.previews==1 then
            -- A bounded exact accepted packet creates the pending braking or
            -- acceleration debt; it does not pretend to be a solver result.
            entry.model={valid=true,force=M.copy(options.force or {0,1038.8,-318}),
                torque={0,0,0},hop_impulse={0,0,0},hop_applied=false,hop_event_id=0,
                wheels=M.copy(wheels)}
            return entry.model,first
        end
        local model,candidate=actual:preview(seconds,forecast,wheels,samples,controls)
        entry.model=M.copy(model)
        return model,candidate
    end
    function proxy:_adopt(candidate)
        f.adoptions+=1
        if candidate~=first then actual:_adopt(candidate) end
    end
    function proxy:reset() actual:reset() end
    function proxy:invalidate_continuity() actual:invalidate_continuity() end
    f=Fixtures.fixture({models={force=proxy,tricks=false}})
    f.proxy=proxy;f.guards={};f.previews={};f.adoptions=0;f.clear=true
    f.velocity=vector.create(0,0,2.9)
    local sample=f.sample
    function f.sample()
        local out=sample()
        out.velocity=f.velocity
        return out
    end
    return f
end
function Tests.run()
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    local function case() cases+=1 end
    case() do
        local measured=body({0,0,3.01})
        local before=M.copy(measured)
        local forecast,samples=InFlight.fold(h,{0,-9.8,0},
            {{age=1,force={0,1038.8,-318},torque={0,0,0}}},measured,clear())
        check(forecast and math.abs(forecast.linear_velocity[3]-(3.01-318/106*h))<1e-12
            and math.abs(forecast.linear_velocity[3]-2.96)<1e-8
            and math.abs(forecast.linear_velocity[2])<1e-12,
            "the reported accepted brake really hides 3.01 m/s behind a 2.96 m/s forecast")
        local stage=Hop.new()
        local admitted,issue=stage:admit_measured(measured)
        check(not admitted and issue=="authored_speed_limit","measured horizontal excess refuses independently")
        local model,candidate=stage:preview(h,forecast,Forces.proposed_wheels(),samples,{})
        check(model.valid,"the same below-cap forecast would otherwise pass the actual stage")
        local admitted_forecast,why=stage:admit_measured(forecast)
        check(admitted_forecast and why=="none" and pcall(stage._adopt,stage,candidate),
            "pure measured admission neither consumes nor invalidates an existing preview")
        check(measured.linear_velocity[3]==before.linear_velocity[3]
            and measured.linear_velocity[2]==before.linear_velocity[2],
            "admission and forecasting preserve the observed velocity")
    end
    case() do
        local stage=Hop.new()
        check(stage:admit_measured(body({3,6,0})) and stage:admit_measured(body({0,-6,3})),
            "horizontal and both vertical cap boundaries are inclusive")
        local ok,why=stage:admit_measured(body({3.001,0,0}))
        check(not ok and why=="authored_speed_limit","horizontal excess cannot borrow vertical budget")
        for _,vertical in ipairs({6.001,-6.001}) do
            ok,why=stage:admit_measured(body({0,vertical,2}))
            check(not ok and why=="authored_vertical_speed_limit","measured ascent and descent each use the vertical magnitude cap")
        end
    end
    for _,module in ipairs({Support,Pedal}) do case() do
        local stage=module.new()
        check(stage:admit_measured(body({6,8,0})),"legacy stage admits the exact 10 m/s three-dimensional boundary")
        local ok,why=stage:admit_measured(body({6,8.01,0}))
        check(not ok and why=="authored_speed_limit","legacy stage retains its full three-dimensional speed magnitude")
    end end
    case() do
        check(Zero.new():admit_measured(body({20,20,20})),"the zero stage does not acquire an authored nonzero speed cap")
        local ok,why=Uncapped.new():admit_measured(body({0,0,0}))
        check(not ok and why=="authored_caps_unavailable","unselected nonzero caps refuse before forecasting")
        local invalid=body({0,0,0});invalid.mass=0
        ok,why=Hop.new():admit_measured(invalid)
        check(not ok and why=="invalid_sample","the pure measured guard rejects an invalid body")
    end
    for _,outcome in ipairs({"applied","queued"}) do case() do
        local f=fixture()
        local initial=f.observe()
        local sequence=initial.pending_sequence
        check(initial.submitted==1 and not initial.stop_requested and #f.previews==1,
            "the constructed bounded packet receives an exact accepted sequence")
        check(f.command.force==vector.create(0,1038.8,-318) and initial.pending_count==1,
            "the accepted transport record contains the reported pending braking force")
        f.advance();f.mode=outcome;f.velocity=vector.create(0,0,3.01)
        local stopped=f.observe()
        check(stopped.stop_requested and stopped.issue=="measured body refused: authored_speed_limit",
            "actual Ride refuses measured excess before a below-cap forecast or queued inbox can conceal it")
        check(#f.guards==2 and #f.previews==1 and count(f,"probe")==1 and stopped.model_steps==1,
            "the second measured guard runs before contact, companions, preview and model advancement")
        check(stopped.backpressure_steps==0 and stopped.submitted==1 and f.adoptions==1,
            "neither queued backpressure nor measured refusal creates another command or adoption")
        check(stopped.pending_count==1 and stopped.pending_sequence==sequence and not stopped.unknown,
            "measured refusal retains the exact accepted receipt without quarantining it")
        check(math.abs(f.guards[2].linear_velocity[3]-3.01)<1e-6,
            "the guard sees the actual decoded sample rather than the braking forecast")
        f.advance();f.mode="applied";f.successor=f.sample()
        local drained=f.ride:drain()
        check(drained.acknowledged==1 and drained.pending_count==0 and not drained.force_pending and not drained.unknown,
            "an exact N+2 successor permits ordered cleanup even while its measured speed remains outside the drive cap")
        check(drained.issue==stopped.issue and count(f,"ack")==1 and count(f,"submit")==1,
            "cleanup preserves the original refusal and never replays admission")
    end end
    case() do
        local f=fixture({force={0,1038.8,318}})
        f.observe()
        f.advance();f.mode="applied";f.velocity=vector.create(0,0,2.99)
        local stopped=f.observe()
        check(#f.guards==2 and #f.previews==2 and f.guards[2].linear_velocity[3]<3,
            "a measured-safe sample still reaches the independent predictive preview")
        check(f.previews[2].body.linear_velocity[3]>3
            and f.previews[2].model.issue=="authored_speed_limit",
            "accepted acceleration that forecasts excess remains refused by the actual stage")
        check(stopped.stop_requested and string.find(stopped.issue,
            "bounded force packet unavailable: authored_speed_limit",1,true)==1
            and stopped.submitted==1 and f.adoptions==1,
            "adding the measured guard does not remove the existing forecast cap")
    end
    for _,vertical in ipairs({6.01,-6.01}) do case() do
        local force={0,1038.8+(vertical>0 and -318 or 318),0}
        local f=fixture({force=force})
        f.observe();f.advance();f.mode="applied";f.velocity=vector.create(0,vertical,0)
        local stopped=f.observe()
        check(stopped.stop_requested and stopped.issue=="measured body refused: authored_vertical_speed_limit",
            "pending vertical braking cannot erase measured ascent or descent beyond six metres per second")
        check(#f.previews==1 and stopped.submitted==1 and not stopped.unknown,
            "vertical refusal precedes any forecast or new accepted packet")
    end end
    local malformed={
        function() error("constructed admission exception") end,
        function() return true end,
        function() return true,"not_none" end,
        function() return false end,
        function() return {},"none" end,
        function() return nil,"none" end,
        function() return true,"none","extra" end,
    }
    for _,guard in ipairs(malformed) do case() do
        local f=fixture({guard=guard})
        local stopped=f.observe()
        check(stopped.stop_requested and stopped.issue=="measured body admission unavailable",
            "an exception or malformed measured-admission result fails closed")
        check(stopped.submitted==0 and #f.previews==0 and count(f,"probe")==0,
            "an unavailable guard cannot reach queries or force submission")
    end end
    for _,bad in ipairs({false,0,"guard",{}}) do case() do
        local force=Forces.new()
        force.admit_measured=bad
        local f=Fixtures.fixture({models={force=force,tricks=false}})
        local stopped=f.observe()
        check(stopped.stop_requested and stopped.submitted==0 and #f.calls==0,
            "a present non-callable measured guard refuses construction")
    end end
    case() do
        local f=fixture()
        f.proxy.admit_measured=nil
        f.velocity=vector.create(0,0,3.01)
        local stopped=f.observe()
        check(stopped.issue=="measured body refused: authored_speed_limit" and #f.guards==1,
            "the snapshotted guard cannot be removed from a live model to bypass admission")
    end
    case() do
        local f=Fixtures.fixture({models={tricks=false}})
        check(f.force.admit_measured==nil,"raw Forces retains its existing optional-guard compatibility")
        local admitted=f.observe()
        check(admitted.submitted==1 and not admitted.stop_requested,
            "a legacy raw force model with no authored admission method still runs")
    end
    return {cases=cases,assertions=assertions,native_actions=0}
end
return table.freeze(Tests)
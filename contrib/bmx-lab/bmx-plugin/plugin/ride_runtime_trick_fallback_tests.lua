-- A trick is presentation only: a trick adapter that refuses or is unavailable
-- leaves the step without a trick, and the ride goes on; every other companion
-- issue (a recovery stop, a trick bound to another frame) still stops.
-- Constructed boundaries only; the runner stages the real Ride with only its
-- private literal enabled.
local Fixtures=require("./ride_runtime_tests")
local Tests={}
local function count(f,name) local n=0 for _,c in ipairs(f.calls) do if c==name then n+=1 end end return n end
-- ride_runtime_tests' fixture whose trick adapter answers by f.trick_answer
-- (nil: the fixture's own valid trick), recording the controls each preview got.
local function fixture(models)
    local f=Fixtures.fixture({models=models})
    local step=f.tricks.step
    function f.tricks:step(frame,contact,actions)
        if f.trick_answer then table.insert(f.calls,"trick");return f.trick_answer(frame) end
        return step(self,frame,contact,actions)
    end
    f.controls={}
    local preview=f.force.preview
    function f.force:preview(h,body,wheels,samples,controls,...)
        table.insert(f.controls,controls)
        return preview(self,h,body,wheels,samples,controls,...)
    end
    return f
end
local function refused(issue) return function() return {valid=false,issue=issue} end end
-- A recovery companion with a fixed answer.
local function recovery(answer)
    local r={}
    function r:update() if type(answer)=="function" then return answer() end return answer end
    return r
end

function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(_,run) cases+=1;run() end

    case("a refused trick leaves the step without one and the ride goes on",function()
        local f=fixture();f.trick_answer=refused("physical_support_unqualified")
        local s=f.observe()
        check(not s.stop_requested and s.submitted==1 and count(f,"trick")==1,"the command is sent: "..tostring(s.issue))
        check(s.model.trick_status=="trick adapter refused: physical_support_unqualified" and s.model.trick_fallbacks==1,
            "the refusal is kept: "..tostring(s.model.trick_status))
        check(f.controls[1].rotation_reserved==false,"no trick reserves air rotation")
        f.mode="applied";f.advance();s=f.observe()
        check(not s.stop_requested and s.submitted==2 and s.model.trick_fallbacks==2,"every refused step goes on")
    end)
    for _,spec in ipairs({{"throws",function() error("constructed trick failure") end},
        {"answers nothing",function() return nil end},
        {"answers a string",function() return "valid" end},
        {"answers twice",function() return {valid=true},{valid=true} end}}) do
        case("a trick adapter that "..spec[1].." is unavailable, and the ride goes on",function()
            local f=fixture();f.trick_answer=spec[2]
            local s=f.observe()
            check(not s.stop_requested and s.submitted==1,"the command is sent: "..tostring(s.issue))
            check(s.model.trick_status=="trick adapter unavailable" and s.model.trick_fallbacks==1,tostring(s.model.trick_status))
            check(f.controls[1].rotation_reserved==false,"no air rotation is reserved")
        end)
    end
    case("a trick adapter with no step function is unavailable, and the ride goes on",function()
        local f=Fixtures.fixture({models={tricks={}}})
        local s=f.observe()
        check(not s.stop_requested and s.submitted==1,"the command is sent: "..tostring(s.issue))
        check(s.model.trick_status=="trick adapter unavailable" and s.model.trick_fallbacks==1,tostring(s.model.trick_status))
    end)
    case("a valid trick after refusals is a trick again",function()
        local f=fixture();f.trick_answer=refused("waiting")
        f.observe()
        f.trick_answer=nil;f.mode="applied";f.advance()
        local s=f.observe()
        check(not s.stop_requested and s.model.trick_status=="fixture_observed" and s.model.trick_fallbacks==1,
            "the fixture's trick is used: "..tostring(s.model.trick_status))
        f.on_trick=function(out) out.requests.rotation_reserved=true end
        f.advance();s=f.observe()
        check(not s.stop_requested and f.controls[3].rotation_reserved==true,"a valid trick still reserves air rotation")
    end)
    case("a stop during the trick call still stops",function()
        local f=fixture()
        f.trick_answer=function() f.ride:stop("constructed stop inside the trick adapter");return {valid=false,issue="late"} end
        local s=f.observe()
        check(s.stop_requested and s.issue=="constructed stop inside the trick adapter" and count(f,"submit")==0,
            "no command after a stop: "..tostring(s.issue))
    end)
    case("a trick bound to another frame still stops",function()
        local f=fixture();f.on_trick=function(out) out.binding.serial="1" end
        local s=f.observe()
        check(s.stop_requested and s.issue=="trick frame mismatch" and count(f,"submit")==0,tostring(s.issue))
    end)
    case("a trick asking for an unknown effect still stops",function()
        local f=fixture();f.on_trick=function(out) out.requests.impulse=true end
        local s=f.observe()
        check(s.stop_requested and s.issue=="unknown trick effect request" and count(f,"submit")==0,tostring(s.issue))
    end)
    case("a recovery stop still stops when the trick is refused",function()
        local f=fixture({recovery=recovery({phase="bailing",requests={stop={reason="constructed bail"}}})})
        f.trick_answer=refused("physical_support_unqualified")
        local s=f.observe()
        check(s.stop_requested and s.issue=="recovery stop: constructed bail" and count(f,"submit")==0,tostring(s.issue))
    end)
    case("recovery force suppression still stops when the trick is unavailable",function()
        local f=fixture({recovery=recovery({phase="recovering",suppress_forces=true,requests={}})})
        f.trick_answer=function() error("constructed trick failure") end
        local s=f.observe()
        check(s.stop_requested and s.issue=="recovery retains force suppression" and count(f,"submit")==0,tostring(s.issue))
    end)
    case("an unavailable recovery still stops",function()
        local f=fixture({recovery=recovery(function() error("constructed recovery failure") end)})
        f.trick_answer=refused("waiting")
        local s=f.observe()
        check(s.stop_requested and s.issue=="recovery adapter unavailable" and count(f,"submit")==0,tostring(s.issue))
    end)
    case("a refused trick with a quiet recovery rides on",function()
        local f=fixture({recovery=recovery({phase="riding",requests={}})})
        f.trick_answer=refused("waiting")
        local s=f.observe()
        check(not s.stop_requested and s.submitted==1 and s.model.recovery_status=="riding","the recovery's own answer: "..tostring(s.issue))
    end)
    return {cases=cases,assertions=assertions}
end
return table.freeze(Tests)

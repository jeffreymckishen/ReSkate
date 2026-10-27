local Line=require("./score_line")
local Tests={}
local function bar()
    return {air_seconds=.9,sequence={{kind="bar",id=34,dir=1,start=.1,finish=.5,hold=0}},
        landing={body_up=1,heading_cos=1,closing=4.32}}
end
function Tests.run(progress)
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    local function case(name,body)
        cases+=1
        local ok,why=pcall(body)
        if not ok then error(name..": "..tostring(why),0) end
        if type(progress)=="function" then progress(cases,assertions) end
    end
    local function fixture()
        local f={line=Line.new(),seconds=0}
        function f:step(extra,h)
            h=h or .1
            self.seconds+=math.max(h,.0001)
            local feed={seconds=self.seconds,mode="rolling",speed=1}
            for k,v in pairs(extra or {}) do feed[k]=v end
            return self.line:step(h,feed)
        end
        function f:land() return self:step({air={landed=bar()}},0) end
        return f
    end
    local function empty(out)
        check(not out.snapshot.active and out.snapshot.points==0 and out.snapshot.score==0,
            "terminal leaves no credited active line")
        check(not out.snapshot.airborne and out.snapshot.manual_seconds==0 and out.snapshot.grind_points==0,
            "terminal discards pending activity")
        check(#out.credits==0,"terminal creates no credit")
    end
    for _,outcome in ipairs({"banked","lost","interrupted"}) do
        case("terminal "..outcome.." closes existing credits once",function()
            local f=fixture();f:land()
            local out=f.line:finish("operator_stop",outcome)
            check(out.issue=="none" and out.closed.outcome==outcome and out.closed.reason=="operator_stop",
                "exact outcome and reason")
            check(out.closed.points==240 and out.closed.tricks==1 and out.closed.multiplier==1.5,
                "only the existing Barspin is reported")
            check(out.closed.score==(outcome=="lost" and 0 or 360),"loss zeros the payout only")
            empty(out)
            for _,next_outcome in ipairs({"lost","banked","interrupted"}) do
                local repeated=f.line:finish("another_stop",next_outcome)
                check(repeated.issue=="finished" and repeated.closed==nil,"repeated terminal has no receipt")
                empty(repeated)
            end
        end)
    end
    case("pending air cannot land after finish",function()
        local f=fixture();f:land()
        f:step({mode="airborne",air={took_off=true}},0)
        local out=f.line:finish("observation_gap","interrupted")
        check(out.closed.points==240 and out.closed.score==360,"pending flight adds no points")
        empty(out)
        local late=f:land()
        check(late.issue=="finished" and late.closed==nil,"late landing cannot reopen line")
        empty(late)
    end)
    case("pending manual is discarded without an exit credit",function()
        local f=fixture();f:land()
        f:step({mode="manual",manual={event="balancing",kind="manual"}},0)
        local pending=f:step({mode="manual"},.5)
        check(pending.snapshot.manual_seconds==.5,"fixture has a scoreable but unclosed manual")
        local out=f.line:finish("dismount","banked")
        check(out.closed.points==240 and out.closed.score==360 and out.closed.tricks==1,
            "terminal does not synthesize manual exit")
        empty(out)
        local late=f:step({manual={event="ended",kind="manual",reason="front_drop"}},.1)
        check(late.issue=="finished" and late.closed==nil,"late manual exit cannot credit")
        empty(late)
    end)
    case("pending grind is discarded without distance or exit credit",function()
        local f=fixture();f:land()
        f:step({mode="grinding",grind={event="lock_on",grind="double_peg"}},0)
        local pending=f:step({mode="grinding",speed=2},1)
        check(pending.snapshot.grind_points>0,"fixture has pending grind points")
        local out=f.line:finish("controller_loss","interrupted")
        check(out.closed.points==240 and out.closed.score==360 and out.closed.tricks==1,
            "terminal does not synthesize grind exit")
        empty(out)
        local late=f:step({grind={event="exit",grind="double_peg"}},.1)
        check(late.issue=="finished" and late.closed==nil,"late grind exit cannot credit")
        empty(late)
    end)
    case("empty terminal is idempotent including loss",function()
        for _,outcome in ipairs({"banked","lost","interrupted"}) do
            local line=Line.new()
            local out=line:finish("empty_stop",outcome)
            check(out.issue=="none","empty finish is accepted")
            if outcome=="lost" then
                check(out.closed.outcome=="lost" and out.closed.points==0 and out.closed.score==0,
                    "empty loss gets one zero-valued receipt")
            else check(out.closed==nil,"empty nonloss invents no receipt") end
            empty(out)
            local again=line:finish("duplicate","lost")
            check(again.issue=="finished" and again.closed==nil,"duplicate loss is suppressed")
            empty(again)
        end
    end)
    case("pending flight without credits closes at zero",function()
        local f=fixture()
        f:step({mode="airborne",air={took_off=true}},0)
        local out=f.line:finish("feed_gap","interrupted")
        check(out.closed.outcome=="interrupted" and out.closed.points==0 and out.closed.score==0,
            "unfinished flight cannot become a Bunny Hop")
        empty(out)
    end)
    case("malformed terminal arguments leave line unchanged and usable",function()
        local invalid={
            {why=nil,outcome="banked"}, {why="",outcome="banked"},
            {why=string.rep("r",161),outcome="banked"}, {why=false,outcome="banked"},
            {why={},outcome="banked"}, {why="stop",outcome=nil},
            {why="stop",outcome="none"}, {why="stop",outcome=false}, {why="stop",outcome={}},
        }
        for _,args in ipairs(invalid) do
            local f=fixture();local before=f:land().snapshot
            local out=f.line:finish(args.why,args.outcome)
            check(out.issue=="invalid_terminal" and out.closed==nil and #out.credits==0,"malformed call refused")
            for key,value in pairs(before) do check(out.snapshot[key]==value,"unchanged snapshot "..key) end
            local next_credit=f:land()
            check(next_credit.issue=="none" and #next_credit.credits==1,"invalid call does not latch terminal")
            local valid=f.line:finish("accepted_after_invalid","banked")
            check(valid.closed.points==430 and valid.closed.score==645,"old and later legitimate credit preserved")
        end
    end)
    case("reason length boundary is exact",function()
        local f=fixture();f:land()
        local why=string.rep("r",160)
        local out=f.line:finish(why,"banked")
        check(out.issue=="none" and out.closed.reason==why,"160 byte reason accepted intact")
        local invalid=f.line:finish(string.rep("r",161),"lost")
        check(invalid.issue=="invalid_terminal" and invalid.closed==nil,"invalid repeated call is still rejected")
        local again=f.line:finish(why,"lost")
        check(again.issue=="finished" and again.closed==nil,"invalid repeated call cannot reopen terminal")
        empty(again)
    end)
    case("terminal ignores later malformed and valid observations",function()
        local f=fixture();f:land();f.line:finish("complete","banked")
        local malformed=f.line:step(nil,nil)
        check(malformed.issue=="finished" and malformed.closed==nil,"no new interruption from malformed late feed")
        empty(malformed)
        local failed=f:step({mode="bailed",air={failed="uncaught",landed=bar()}},1)
        check(failed.issue=="finished" and failed.closed==nil,"no duplicate loss or late credit")
        empty(failed)
    end)
    case("regular timestamp admission and reusable closures stay unchanged",function()
        local f=fixture();f:land()
        local stale=f.line:step(.1,{seconds=f.seconds,mode="rolling",speed=1,air={landed=bar()}})
        check(stale.issue=="stale_feed" and #stale.credits==0 and stale.snapshot.points==240,
            "ordinary step still requires strictly increasing timestamps")
        local closed=f:step({ended={deliberate=true,reason="ordinary_stop"}},0)
        check(closed.closed.outcome=="banked" and closed.closed.points==240,"ordinary close still banks")
        local fresh=f:land()
        check(fresh.issue=="none" and fresh.credits[1].points==240,"ordinary close does not latch terminal")
        f.line:finish("generation_end","banked")
        local new_line=Line.new()
        local new_credit=new_line:step(0,{seconds=0,mode="rolling",speed=1,air={landed=bar()}})
        check(new_credit.issue=="none" and new_credit.credits[1].points==240,
            "new generation resets timestamp, repeat history and terminal state")
    end)
    case("terminal result tables do not expose mutable state",function()
        local f=fixture();f:land()
        local out=f.line:finish("complete","banked")
        out.closed.points=9999;out.snapshot.points=9999;out.snapshot.active=true
        table.insert(out.credits,{points=9999})
        local again=f.line:finish("duplicate","lost")
        check(again.issue=="finished" and again.closed==nil,"mutating receipt cannot revive it")
        empty(again)
    end)
    return {cases=cases,assertions=assertions,native_actions=0}
end
return Tests

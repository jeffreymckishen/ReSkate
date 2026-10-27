local Line=require("./score_line")
local Rules=require("./score_rules")
local Tests={}
local function row(kind,id,start,finish,hold)
    return {kind=kind,id=id,dir=1,start=start or .1,finish=finish or .5,hold=hold or 0}
end
local function air(sequence,seconds,landing)
    return {sequence=sequence or {},air_seconds=seconds or .9,landing=landing or {body_up=1,heading_cos=1,closing=4.32}}
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
    local function fixture(rules)
        local f={line=Line.new(rules),seconds=0}
        function f:step(extra,h)
            h=h or .1
            self.seconds+=math.max(h,.0001)
            local feed={seconds=self.seconds,mode="rolling",speed=1}
            for k,v in pairs(extra or {}) do feed[k]=v end
            return self.line:step(h,feed)
        end
        function f:land(a) return self:step({air={landed=a}},0) end
        return f
    end
    local function bar(seconds,id) return air({row("bar",id or 34)},seconds) end
    local function tail(seconds) return air({row("tail",52)},seconds) end
    case("G1 Bunny Hop",function()
        local out=fixture():land(air())
        check(out.credits[1].points==90 and out.snapshot.score==135,"90 points, line135")
        check(out.credits[1].name=="Bunny Hop" and out.credits[1].landing=="Clean","hop name and clean")
    end)
    case("G2 single Barspin",function()
        local out=fixture():land(bar())
        check(out.credits[1].points==240 and out.snapshot.score==360,"240 points, line360")
        check(out.snapshot.categories==1,"air bonus is not a second category")
    end)
    case("G3 repeated Barspin after two seconds",function()
        local f=fixture();f:land(bar());f:step({},2)
        local out=f:land(bar(nil,44))
        check(out.credits[1].points==190 and out.snapshot.points==430 and out.snapshot.score==645,
            "direction-neutral repeat:190, sum430, line645")
    end)
    case("G4 Truckdriver",function()
        local a=bar(1.2);a.spin_half_turns=2
        local out=fixture():land(a)
        check(out.credits[1].points==880 and out.credits[1].name=="Truckdriver","rotation and combo order")
    end)
    case("G5 cumulative double catch",function()
        local a=air({row("bar",34,.05,.4),row("bar",44,.55,.95)},1.1)
        local out=fixture():land(a)
        check(out.credits[1].points==560 and out.credits[1].name=="Double Barspin","200+300+60")
        check(out.snapshot.categories==1,"two catches are one category and key")
    end)
    case("G6 Sketchy Tailwhip",function()
        local a=tail();a.landing.body_up=.95
        local out=fixture():land(a)
        check(out.credits[1].points==273 and out.credits[1].landing=="Sketchy","390*.7")
    end)
    case("G7 two categories in a line",function()
        local f=fixture();f:land(bar());local out=f:land(tail())
        check(out.snapshot.points==630 and out.snapshot.multiplier==2 and out.snapshot.score==1260,"630*2")
    end)
    case("G8 failure wins over simultaneous landing",function()
        local f=fixture();f:land(bar())
        local out=f:step({air={failed="uncaught",landed=tail()}})
        check(out.closed.outcome=="lost" and out.closed.score==0 and #out.credits==0,"no failed credit")
        check(out.closed.points==240 and not out.snapshot.active,"lost report preserves old points only")
    end)
    case("G9 overlapping catches",function()
        local out=fixture():land(air({row("bar",34),row("tail",52)}))
        check(out.credits[1].points==865,"(200+350)*1.25*1.2+40")
        check(out.credits[1].name=="Barspin + Tailwhip","parallel naming")
    end)
    case("nonoverlap and exact half overlap threshold",function()
        local separate=fixture():land(air({row("bar",34,.05,.35),row("tail",52,.4,.8)}))
        check(separate.credits[1].points==700,"550*1.2+40 without overlap")
        local half=fixture():land(air({row("bar",34,0,.5),row("tail",52,.25,.75)}))
        check(half.credits[1].points==865,"exact half overlap qualifies")
    end)
    case("repeat floor and reset after bank",function()
        local f=fixture();local values={240,190,140,90,60,60}
        for i=1,6 do check(f:land(bar()).credits[1].points==values[i],"repeat "..i) end
        local close=f:step({ended={deliberate=true,reason="dismount"}})
        check(close.closed.outcome=="banked","dismount banks")
        check(f:land(bar()).credits[1].points==240,"new line resets repeat")
    end)
    case("unknown quality is discounted without label",function()
        local a=bar();a.landing=nil
        local out=fixture():land(a)
        check(out.credits[1].points==168 and out.credits[1].landing==nil,"unknown is .7 without Clean/Sketchy")
        local b=bar();b.landing.heading_cos=-1
        local back=fixture():land(b)
        check(back.credits[1].points==240 and back.credits[1].name=="Barspin to Fakie","signed heading preserved")
    end)
    case("short partless hop and failed first air",function()
        local out=fixture():land(air({},.24))
        check(#out.credits==0 and not out.snapshot.active,"short hop is no credit")
        local lost=fixture():step({air={failed="uncaught"}})
        check(lost.closed.outcome=="lost" and lost.closed.score==0,"first air bail still reports BAIL")
    end)
    case("pose holds cap and cycle hold is not a bonus",function()
        local held=fixture():land(air({row("move",37,.05,.85,.5)}))
        check(held.credits[1].points==190 and held.credits[1].name=="X-Up","D1 pose150+40")
        local longer=fixture():land(air({row("move",37,.05,1.05,.8)},1.2))
        check(longer.credits[1].points==220,"hold caps at1.5x:150+70")
        local cycle=fixture():land(air({row("move",54,.05,.85,.5)}))
        check(cycle.credits[1].points==240,"Crankflip cycle gets no hold factor")
    end)
    case("spin and flip scoring and independent repeat keys",function()
        for n,expected in ipairs({150,375,675,1050}) do
            local a=air({},.5);a.spin_half_turns=n
            check(fixture():land(a).credits[1].points==expected,"spin base "..n)
        end
        local f=fixture();local a=air({},.5);a.back_flips=1
        check(f:land(a).credits[1].points==600,"single backflip")
        check(f:land(a).credits[1].points==450,"flip repeat")
        local b=air({},.5);b.front_flips=2
        check(f:land(b).credits[1].points==1500,"double front axis independent key")
        local c=air({},.5);c.barrel_rolls=2
        check(fixture():land(c).credits[1].points==1500,"double roll")
    end)
    case("timer freezes in every protected mode",function()
        for _,extra in ipairs({{mode="airborne"},{mode="manual"},{mode="nose_manual"},
            {mode="grinding"},{mode="stalling"},{landing_pending=true}}) do
            local f=fixture();f:land(bar())
            local out=f:step(extra,5)
            check(out.closed==nil and out.snapshot.remaining==2.5,"protected timer")
            local bank=f:step({},2.5)
            check(bank.closed.outcome=="banked" and bank.closed.reason=="timeout","rolling drains timer")
        end
    end)
    case("pedalling does not earn or refill",function()
        local f=fixture();f:land(bar())
        local out=f:step({pedal=1},2)
        check(#out.credits==0 and out.snapshot.remaining==.5,"pedal is ignored")
        check(f:step({pedal=1},.5).closed.reason=="timeout","pedal cannot extend line")
    end)
    case("idle banking boundary",function()
        local f=fixture();f:land(bar())
        check(f:step({speed=.3},1).closed==nil,"exact threshold is moving")
        check(f:step({speed=.29},1).closed.reason=="idle","one continuous second below threshold")
    end)
    case("loss reasons remain distinct from infrastructure",function()
        local reasons={"bail","bailed","loop_out","nose_over","tilt_stop","roll_stop",
            "measured tilt 15.1 deg over the 15 deg Ride stop",
            "measured roll rate 1.10 rad/s over the 1 rad/s Ride stop"}
        for _,why in ipairs(reasons) do
            local f=fixture();f:land(bar())
            local lost=f:step({ended={reason=why}}).closed
            check(lost.outcome=="lost" and lost.reason==why,why)
        end
        local f=fixture();f:land(bar())
        check(f:step({mode="bailed"}).closed.score==0,"composer bail")
        local m=fixture();m:land(bar())
        check(m:step({manual={event="ended",kind="manual",reason="loop_out"}}).closed.outcome=="lost","manual bail")
        local g=fixture();g:land(bar())
        check(g:step({grind={event="exit",grind="double_peg",reason="bail"}}).closed.outcome=="lost","grind bail")
    end)
    case("every infrastructure route banks only existing credits",function()
        local feeds={{gap=true},{interrupted="owner"},{interrupted="focus"},{interrupted="menu"},
            {interrupted="gap"},{grind={event="exit",grind="double_peg",reason="contact_unavailable"}}}
        for _,why in ipairs({"force guard","lease","window end","epoch","serial gap","pad stall","measured tilt unavailable"}) do
            table.insert(feeds,{ended={reason=why,infrastructure=true}})
        end
        for _,feed in ipairs(feeds) do
            local f=fixture();f:land(bar());f:step({air={took_off=true},mode="airborne"})
            feed.air={landed=tail()}
            local out=f:step(feed)
            check(out.closed.outcome=="interrupted" and out.closed.score==360 and #out.credits==0,"bank only prior bar")
        end
    end)
    case("manual thresholds, cap, and cancellation",function()
        for _,kind in ipairs({"manual","nose_manual"}) do
            local f=fixture();f:step({mode=kind,manual={event="balancing",kind=kind}},0)
            f:step({mode=kind},.3)
            local out=f:step({manual={event="ended",kind=kind,reason="front_drop"}},0)
            check(out.credits[1].points==(kind=="manual" and 36 or 45),"minimum balances all observed duration")
        end
        local f=fixture();f:step({mode="manual",manual={event="balancing",kind="manual"}},0)
        f:step({mode="manual"},10);f:step({mode="manual"},10)
        check(f:step({manual={event="ended",kind="manual",reason="hop_out"}},0).credits[1].points==1200,"10second cap")
        for _,why in ipairs({"cancelled","unknown"}) do
            local q=fixture();q:step({mode="manual",manual={event="balancing",kind="manual"}},0)
            q:step({mode="manual"},1)
            check(#q:step({manual={event="ended",kind="manual",reason=why}},0).credits==0,"unqualified manual exit")
        end
    end)
    case("manual links and cap",function()
        local f=fixture();f:land(bar())
        for _=1,8 do
            f:step({mode="manual",manual={event="balancing",kind="manual"}},0)
            f:step({mode="manual"},.3)
            f:step({manual={event="ended",kind="manual",reason="rear_drop"}},0)
        end
        local out=f:step({},0)
        check(out.snapshot.links==4 and out.snapshot.multiplier==3,"links capped at4")
    end)
    case("grind distance changes and stall cap",function()
        local f=fixture();f:step({mode="grinding",grind={event="lock_on",grind="double_peg"}},0)
        f:step({mode="grinding",speed=-2},1)
        f:step({mode="grinding",grind={event="grind_changed",grind="feeble"}},0)
        f:step({mode="grinding",speed=2},1)
        check(f:step({grind={event="exit",grind="feeble",reason="hop_out"}},0).credits[1].points==480,
            "100lock+120distance+100change+160distance")
        local s=fixture();s:step({mode="stalling",grind={event="lock_on",grind="stall"}},0)
        s:step({mode="stalling"},1);s:step({mode="stalling"},1)
        check(s:step({grind={event="exit",grind="stall",reason="drop"}},0).credits[1].points==300,"stall .75cap")
    end)
    case("grind to stall preserves already accrued credit",function()
        local f=fixture();f:step({mode="grinding",grind={event="lock_on",grind="double_peg"}},0)
        f:step({mode="grinding",speed=2},1)
        f:step({mode="stalling",grind={event="grind_changed",grind="stall"}},0)
        f:step({mode="stalling"},1)
        check(f:step({grind={event="exit",grind="stall",reason="drop"}},0).credits[1].points==470,
            "100+120+100+150 retained")
    end)
    case("multiplier cap",function()
        local f=fixture();f:land(air());f:land(bar());f:land(tail())
        local rotated=bar();rotated.spin_half_turns=2;rotated.back_flips=1
        f:land(rotated)
        f:step({mode="manual",manual={event="balancing",kind="manual"}},0)
        f:step({mode="manual"},.3)
        local out=f:step({manual={event="ended",kind="manual",reason="front_drop"}},0)
        check(out.snapshot.multiplier==4,"authored multiplier never exceeds4")
    end)
    case("malformed air never partially credits",function()
        local bad={}
        local overflow=bar();overflow.overflow=true;table.insert(bad,overflow)
        local sparse=bar();sparse.sequence[3]=row("tail",52);table.insert(bad,sparse)
        local oversized=bar();for i=1,17 do oversized.sequence[i]=row("bar",34) end;table.insert(bad,oversized)
        local fake=bar();fake.sequence[1].id=30;table.insert(bad,fake)
        local wrong=bar();wrong.sequence[1].id=52;table.insert(bad,wrong)
        local invalid=bar();invalid.landing.closing=0/0;table.insert(bad,invalid)
        local bounds=bar();bounds.spin_half_turns=33;table.insert(bad,bounds)
        local false_count=bar();false_count.spin_half_turns=false;table.insert(bad,false_count)
        local false_hold=bar();false_hold.sequence[1].hold=false;table.insert(bad,false_hold)
        for _,a in ipairs(bad) do
            local f=fixture();f:land(bar());local out=f:land(a)
            check(out.issue=="invalid_air" and #out.credits==0 and out.closed.score==360,"refuse malformed air")
        end
    end)
    case("duplicate catch and family-channel forgery refused",function()
        local duplicate=air({row("bar",34),row("bar",34)})
        local overlap=air({row("bar",34,.1,.5),row("bar",44,.4,.8)})
        local wrong=bar();wrong.sequence[1].kind="move"
        local reverse=air({row("bar",34,.5,.8),row("bar",44,.1,.4)})
        for _,a in ipairs({duplicate,overlap,wrong,reverse}) do
            check(fixture():land(a).issue=="invalid_air","invalid completion order/channel")
        end
    end)
    case("invalid Air cannot partly credit a ground exit",function()
        local f=fixture();f:land(bar())
        f:step({mode="manual",manual={event="balancing",kind="manual"}},0)
        f:step({mode="manual"},1)
        local a=tail();a.overflow=true
        local out=f:step({manual={event="ended",kind="manual",reason="front_drop"},air={landed=a}},0)
        check(out.issue=="invalid_air" and #out.credits==0 and out.closed.points==240,
            "validate complete packet before crediting observed manual")
    end)
    case("interleaved catches do not invent concurrency",function()
        local out=fixture():land(air({row("bar",34,.05,.2),row("tail",52,.3,.6),row("bar",44,.8,.95)},1))
        check(out.credits[1].points==1070 and out.credits[1].name=="Double Barspin to Tailwhip",
            "500+350 times1.2 +50, actual intervals remain separate")
    end)
    case("projection tolerances and signed pitch axis",function()
        local a=bar();a.landing.body_up=1.0000005;a.landing.closing=1000000
        check(fixture():land(a).credits[1].points==168,"projector tolerance admitted, high closing Sketchy")
        local b=bar();b.front_flips=1;b.back_flips=1
        check(fixture():land(b).issue=="invalid_air","one signed pitch axis cannot claim both directions")
    end)
    case("duplicate feed cannot credit twice; snapshots are detached",function()
        local line=Line.new()
        local feed={seconds=1,mode="rolling",speed=1,air={landed=bar()}}
        local first=line:step(.1,feed)
        first.snapshot.points=999;first.credits[1].points=999
        local second=line:step(.1,feed)
        check(second.issue=="stale_feed" and #second.credits==0 and second.snapshot.points==240,"duplicate ignored")
        feed.seconds=0
        check(line:step(.1,feed).snapshot.points==240,"older clock ignored")
    end)
    case("rules sanitized, immutable, and detached",function()
        local supplied={air_rate=math.huge,repeat_floor=-1,base={200,300}}
        local rules=Rules.sanitize(supplied);supplied.base[1]=999
        check(rules.air_rate==100 and rules.repeat_floor==0 and rules.base[1]==200 and rules.base[3]==350,"known bounds")
        check(not pcall(function() rules.base[1]=5 end),"frozen rules")
    end)
    case("2^53 accounting saturation",function()
        local f=fixture();f:land(bar())
        -- Seed the arithmetic boundary; reaching it by game observations would be impractical.
        f.line._points=Rules.MAX_SCORE-10
        local out=f:land(tail())
        check(out.snapshot.points==Rules.MAX_SCORE and out.snapshot.score==Rules.MAX_SCORE,"sum and multiplier saturate")
        check(f:step({ended={deliberate=true}},0).closed.score==Rules.MAX_SCORE,"bank does not overflow")
    end)
    case("invalid feed interrupts and no raw native state is required",function()
        local f=fixture();f:land(bar())
        local out=f.line:step(.1,{seconds=2,mode="rolling",speed=math.huge})
        check(out.issue=="invalid_feed" and out.closed.score==360,"invalid speed banks previous credit")
        check(f:land(bar()).credits[1].points==240,"new line recovers")
    end)
    -- Median chunks follow the existing runner timing pattern: retain wall-clock
    -- evidence without treating one OS preemption as a steady-state cost.
    local timing
    case("bounded maximum-size scoring step",function()
        local clock=os and os.clock
        local samples={}
        local a=air({},2)
        for i=1,16 do
            local start=.15*math.floor((i-1)/2)
            a.sequence[i]=row(i%2==0 and "tail" or "bar",i%2==0 and 52 or 34,start,start+.1)
        end
        for _=1,9 do
            local f=fixture()
            local started=clock and clock()
            for _=1,64 do f:land(a) end
            if clock then table.insert(samples,(clock()-started)/64) end
            if type(progress)=="function" then progress(cases,assertions) end
        end
        if #samples>0 then
            table.sort(samples);timing=samples[5]
            check(timing<.001,"median maximum-size scoring step below1ms; measured "..timing)
        else check(true,"runner clock unavailable; timing remains unverified") end
    end)
    return {cases=cases,assertions=assertions,native_actions=0,median_step_seconds=timing}
end
return Tests

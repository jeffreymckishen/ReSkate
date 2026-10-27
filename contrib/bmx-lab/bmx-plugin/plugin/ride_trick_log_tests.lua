-- Constructed measured frames and model events only; no game, score or trick proof.
-- Reuse the existing fixture without running or changing its pinned cases.
local Ride=require("./ride_runtime")
local Fixtures=require("./ride_runtime_tests")
local Feed=require("./score_feed")
local Tests={}
local function event()
    return {took_off=false,landed=true,combo_landed=true,failed=false,canceled=false,
        bar_caught=false,tail_caught=false,movement_caught=false,
        barspins=1,tailwhips=0,spin_half_turns=0,units=1,movements=0,
        front_flips=0,back_flips=0,barrel_rolls=0,failure="none",
        air_seconds=.6,spin_radians=0,flip_radians=0,roll_radians=0,fakie_takeoff=true,overflow=false,
        sequence={{kind="bar",id=34,dir=-1,start=.01,finish=.46,hold=0}},
        landing={body_up=1,heading_cos=-1,closing=4.32}}
end
function Tests.run()
    local cases,assertions=0,0
    local function check(v,why) assertions+=1;assert(v,why) end
    local function case(run) cases+=1;run() end
    local function near(a,b) return math.abs(a-b)<1e-9 end

    case(function()
        local calls=0
        local api=setmetatable({}, {__index=function() calls+=1;error("production force API touched",0) end})
        local a,b=Ride.new(api),Ride.new(api)
        local first,other=a:trick_log(),b:trick_log()
        check(first.generation>0 and first.generation%1==0 and other.generation>first.generation,
            "each production instance has a distinct positive log generation")
        check(first.n==0 and #first.rows==0 and not first.gap and table.isfrozen(first) and table.isfrozen(first.rows),
            "a new production log is empty and frozen")
        a:observe(nil,nil,nil);a:drain()
        check(a:trick_log().n==0 and calls==0,"the production gate cannot create measured rows or touch the force API")
        a:stop("stopped before any observation")
        local stopped=a:trick_log()
        check(stopped.generation==first.generation and stopped.n==1 and stopped.rows[1].control=="ended",
            "an inert lifecycle stop is a control in the original generation")
        check(stopped.rows[1].seconds==nil and stopped.rows[1].h==nil and calls==0,
            "an inert stop invents no measured time and makes no force call")
    end)

    case(function()
        local f=Fixtures.fixture()
        local initial=f.ride:trick_log()
        local status=f.observe()
        local calls=#f.calls
        local out=f.ride:trick_log()
        local row=out.rows[1]
        check(out.generation==initial.generation and out.n==1 and #out.rows==1 and not out.gap,
            "one accepted model observation produces one numbered row")
        check(row.n==1 and near(row.seconds,f.time) and near(row.h,f.read.seconds) and row.speed==0
            and row.mode=="rolling" and row.landing_pending==false,
            "the row carries the actual frame's time, interval, speed and support mode")
        check(row.control==nil and row.events==nil and row.interrupted==nil
            and row.body_handle==nil and row.physics_epoch==nil and row.source==nil,
            "a quiet observation has no invented event or private authority")
        check(status.trick_log_n==1 and status.trick_log==nil and status.trick_log_rows==nil
            and status.rows==nil and status.events==nil,"status exposes only the log ordinal, not the ring")
        f.ride:trick_log(1);f.ride:trick_log(0)
        check(#f.calls==calls,"log reads make no query, receipt, model or force call")
    end)

    case(function()
        local f=Fixtures.fixture();f.observe()
        local generation=f.ride:trick_log().generation
        f.observe();f.pad.buttons.a=true;f.new_input();f.observe()
        check(f.ride:trick_log().n==1,"duplicate body observations and queued input cannot duplicate a physical row")
        f.ride:drain()
        check(f.ride:trick_log().n==1 and f.ride:trick_log().generation==generation,
            "receipt-only draining cannot create another observation or generation")
        f.advance();local status=f.observe()
        check(status.model_steps==2 and f.ride:trick_log(1).rows[1].n==2,
            "only the successor body sample advances the log")
    end)

    case(function()
        local f=Fixtures.fixture()
        for i=1,12 do
            if i>1 then f.advance() end
            check(not f.observe().stop_requested,"constructed queued receipt remains within its watchdog")
        end
        local full=f.ride:trick_log()
        check(full.n==12 and #full.rows==8 and full.gap and full.rows[1].n==5 and full.rows[8].n==12,
            "overflow keeps the latest eight rows and reports the missed prefix")
        local boundary=f.ride:trick_log(4)
        check(not boundary.gap and #boundary.rows==8 and boundary.rows[1].n==5,
            "the cursor immediately before the oldest retained row has no gap")
        check(f.ride:trick_log(3).gap,"a cursor older than the retained prefix reports a gap")
        local suffix=f.ride:trick_log(8)
        check(not suffix.gap and #suffix.rows==4 and suffix.rows[1].n==9 and suffix.rows[4].n==12,
            "an in-range cursor returns only later rows")
        local end_at=f.ride:trick_log(12)
        check(not end_at.gap and #end_at.rows==0 and end_at.n==12,"a caught-up cursor returns an empty suffix")
        for _,cursor in ipairs({-1,.5,13,math.huge,0/0,"0",false,{}}) do
            local invalid=f.ride:trick_log(cursor)
            check(invalid.gap and #invalid.rows==0 and invalid.n==12 and invalid.generation==full.generation,
                "invalid cursors cannot fabricate a suffix")
        end
        local other=Fixtures.fixture()
        check(other.ride:trick_log().generation~=full.generation,"a new Ride cannot reuse the observed instance's generation")
    end)

    case(function()
        local f=Fixtures.fixture();local produced=event()
        produced.private_handle=newproxy();produced.sequence[1].ignored={private=true}
        produced.landing.ignored={private=true}
        f.on_trick=function(out)
            out.model_events=produced
            out.model_state={airborne=false,landing_pending=true}
        end
        f.observe()
        local saved=f.ride:trick_log()
        local row=saved.rows[1]
        check(row.events.landed and row.events.combo_landed and row.events.units==1 and saved.n==1,
            "landed and combo_landed stay flags on one event, not two credits")
        check(row.landing_pending and row.events.fakie_takeoff and row.events.landing.heading_cos==-1,
            "the projection retains settle state and signed event detail")
        check(row.events.private_handle==nil and row.events.sequence[1].ignored==nil and row.events.landing.ignored==nil,
            "the scoring projection whitelists nested fields")
        produced.sequence[1].id=44;produced.landing.closing=99
        check(row.events.sequence[1].id==34 and near(row.events.landing.closing,4.32),
            "changing the producer's nested event cannot change the stored row")
        check(not pcall(function() saved.rows[1]={} end)
            and not pcall(function() row.events.sequence[1].id=77 end)
            and not pcall(function() row.events.landing.closing=999 end),
            "the packet, ring and nested detail are immutable")
        f.on_trick=nil
        for _=1,9 do f.advance();f.observe() end
        local current=f.ride:trick_log()
        check(saved.n==1 and #saved.rows==1 and saved.rows[1].n==1 and saved.rows[1].events.sequence[1].id==34,
            "an older snapshot remains stable after the live ring evicts its row")
        check(current.n==10 and current.rows[1].n==3 and current.rows[#current.rows].events==nil,
            "later observations neither retain nor repeat the one-shot landing event")
    end)

    case(function()
        local f=Fixtures.fixture();f.clear=true
        function f.tricks:step() return {valid=false,issue="constructed support refusal"} end
        local status=f.observe();local row=f.ride:trick_log().rows[1]
        check(not status.stop_requested and row.mode=="airborne"
            and row.interrupted=="trick adapter refused: constructed support refusal" and row.events==nil,
            "an airborne adapter refusal becomes an interruption without a fake failed landing")
        f.clear=false;f.advance();f.observe()
        row=f.ride:trick_log(1).rows[1]
        check(row.mode=="rolling" and row.interrupted~=nil,"the first supported refusal still interrupts the previously open air")
        f.advance();f.observe();row=f.ride:trick_log(2).rows[1]
        check(row.mode=="rolling" and row.interrupted==nil,"a later quiet grounded refusal cannot keep interrupting an old air")
    end)

    case(function()
        local f=Fixtures.fixture()
        f.on_trick=function(out) out.model_events={landed=true} end
        local status=f.observe();local row=f.ride:trick_log().rows[1]
        check(not status.stop_requested and row.events==nil and row.interrupted=="invalid trick event",
            "malformed scoring detail is omitted and reported without claiming a native ride failure")
        check(row.n==1 and near(row.seconds,f.time),"a malformed event does not erase its real physical observation")
        f.advance()
        f.on_trick=function(out) out.model_events={failed=true,landed=true,failure="uncaught",sequence={bad=newproxy()}} end
        local failed_status=f.observe();local failure=f.ride:trick_log(1).rows[1]
        check(not failed_status.stop_requested and failure.events.failed and failure.events.failure=="uncaught",
            "literal failure survives malformed coincident landed detail without changing Ride authority")
        check(failure.events.sequence==nil and failure.events.landed==nil and failure.interrupted==nil,
            "failure projection cannot retain malformed credit or downgrade loss to interruption")
        local batch=Feed.ride(f.ride:trick_log(1),1,{})
        check(#batch.steps==1 and batch.steps[1].feed.air.failed=="uncaught" and batch.steps[1].feed.air.landed==nil,
            "actual Ride log reaches Feed as a loss despite malformed coincident landing data")
    end)

    case(function()
        local f=Fixtures.fixture();f.observe();f.advance();f.observe()
        local prior=f.ride:trick_log()
        local calls=#f.calls
        f.ride:stop("explicit test stop");f.ride:stop("later cleanup cause");f.observe()
        check(#f.calls==calls,"stopping and observing a stopped Ride make no force or model calls")
        f.ride:drain()
        local terminal=f.ride:trick_log(prior.n)
        check(terminal.generation==prior.generation and terminal.n==prior.n+1 and #terminal.rows==1,
            "repeated Stop, observation and drain append the terminal control only once")
        local row=terminal.rows[1]
        check(row.control=="ended" and row.reason=="explicit test stop" and row.events==nil and row.interrupted==nil,
            "the terminal record preserves the first lifecycle cause without an unfinished-air award")
        check(row.seconds==nil and row.h==nil and row.speed==nil and row.mode==nil and row.landing_pending==nil,
            "a lifecycle control is never presented as another timed physics sample")
        check(f.ride:status().trick_log_n==terminal.n,"status reports the terminal ordinal")
        check(f.ride:trick_log(terminal.n).n==terminal.n and #f.ride:trick_log(terminal.n).rows==0,
            "the terminal control is consumed by the same ordinary cursor")
    end)

    case(function()
        local f=Fixtures.fixture();f.observe();local first=f.ride:trick_log().rows[1]
        f.advance(2);local status=f.observe();local out=f.ride:trick_log()
        check(status.stop_requested and out.n==2 and #out.rows==2 and out.rows[2].control=="ended",
            "a missing physical epoch adds only the control that ends the ride")
        check(out.rows[1].seconds==first.seconds and out.rows[2].seconds==nil,
            "the log does not invent a sample or elapsed time to fill the physical gap")
    end)
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return Tests

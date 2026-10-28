-- Synthetic copies of the recorded Composer output shapes and bounded Ride
-- rows. These exercise local accounting only, not native support or scoring.
local Feed=require("./score_feed")
local Line=require("./score_line")
local Tricks=require("./tricks")
local TrickRuntime=require("./trick_runtime")
local Tests={}
local function copy(v)
    if type(v)~="table" then return v end
    local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out
end
local function event(kind)
    local e={took_off=false,landed=false,combo_landed=false,failed=false,canceled=false,
        bar_caught=false,tail_caught=false,movement_caught=false,barspins=0,tailwhips=0,spin_half_turns=0,
        units=0,movements=0,front_flips=0,back_flips=0,barrel_rolls=0,failure="none"}
    if kind=="landed" then
        e.landed,e.combo_landed,e.barspins,e.units=true,true,1,1
        e.air_seconds,e.spin_radians,e.flip_radians,e.roll_radians=.9,0,0,0
        e.fakie_takeoff,e.overflow=false,false
        e.sequence={{kind="bar",id=34,dir=-1,start=.1,finish=.55,hold=0}}
        e.landing={body_up=1,heading_cos=1,closing=4.32}
    elseif kind then e[kind]=true end
    return e
end
local function composer(e,mode)
    return {valid=true,issue="none",mode=mode or "rolling",events={},diagnostics={consecutive=true,
        balance={stepped=true,issue="none"},grind={state="locked",issue="none"},
        trick={valid=true,issue="none",events=e,state={landing_pending=false}}}}
end
local function row(n,seconds,e,mode)
    return {n=n,seconds=seconds,h=.1,speed=3,mode=mode or "rolling",landing_pending=false,events=e}
end
local function log(rows,n,gap) return {generation=1,n=n or #rows,rows=rows,gap=gap==true} end
function Tests.run()
    local assertions,cases=0,0
    local function check(v,why) assertions+=1;assert(v,why) end
    local function near(a,b) return math.abs(a-b)<1e-7 end
    local function scenario(run) cases+=1;run() end
    local function context(seconds,h,mode,after)
        return {seconds=seconds,h=h,speed=3,previous_mode=mode,after_seconds=after,generation=1}
    end
    local function credit(line)
        local b=Feed.composer(composer(event("landed")),context(1,.1,"airborne"))
        return line:step(b.steps[1].h,b.steps[1].feed)
    end
    scenario(function()
        local raw=event("landed");local sample=composer(raw)
        sample.events={{name="trick",event="landed"},{name="trick",event="combo_landed"}}
        local b=Feed.composer(sample,context(1,.1,"airborne"))
        check(#b.steps==1 and b.cursor==nil and b.generation==1 and b.mode=="rolling", "composer emits one physical endpoint without a Ride cursor")
        local out=Line.new():step(b.steps[1].h,b.steps[1].feed)
        check(#out.credits==1 and out.credits[1].points==240, "full diagnostic event scores once despite duplicate summary flags")
        raw.sequence[1].id=77;raw.landing.closing=999
        check(b.steps[1].feed.air.landed.sequence[1].id==34 and near(b.steps[1].feed.air.landed.landing.closing,4.32),
            "event detail is detached from producer memory")
    end)
    scenario(function()
        local line=Line.new();credit(line)
        local e=event("landed");e.failed,e.failure=true,"uncaught";e.sequence={malformed=true}
        local c=context(1.1,.1,"airborne",1);c.gap=true
        local b=Feed.composer(composer(e),c);local step=b.steps[1]
        local out=line:step(step.h,step.feed)
        check(step.feed.air.failed=="uncaught" and step.feed.air.landed==nil and step.feed.mode=="bailed", "failure defeats coincident malformed landing and gap")
        check(out.closed and out.closed.outcome=="lost" and out.closed.score==0 and #out.credits==0, "failed endpoint loses the existing line")
        local ground=Line.new();credit(ground)
        local bad=composer(event("landed"))
        bad.events={{name="balance",event=false},{name="grind",event={name="exit",grind="smith",reason="bail"}}}
        local g=Feed.composer(bad,context(1.1,.1,"grinding",1));local loss=ground:step(g.steps[1].h,g.steps[1].feed)
        check(loss.closed and loss.closed.outcome=="lost" and #loss.credits==0,
            "malformed neighboring ground wrapper cannot downgrade a recognized grind bail")
    end)
    scenario(function()
        local line=Line.new();credit(line)
        local sample=composer(nil,"airborne");sample.diagnostics.trick.valid=false;sample.diagnostics.trick.issue="physical_support_unqualified"
        local b=Feed.composer(sample,context(1.1,.1,"airborne",1));local out=line:step(b.steps[1].h,b.steps[1].feed)
        check(out.closed and out.closed.outcome=="interrupted" and out.closed.points==240, "adapter refusal drops pending air while retaining completed credit")
        local canceled=event("canceled");canceled.failure="canceled"
        local c=Feed.composer(composer(canceled,"airborne"),context(2,.1))
        check(c.steps[1].feed.interrupted=="canceled" and c.steps[1].feed.air==nil, "cancel is an interruption, never a landing")
    end)
    scenario(function()
        local sample=composer(event())
        local stale=Feed.composer(sample,context(1,.1,"rolling",1))
        check(#stale.steps==0 and stale.issue=="stale_observation", "same timestamp cannot repeat credit or duration")
        sample.issue="duplicate_read"
        check(#Feed.composer(sample,context(2,.1,"rolling",1)).steps==0, "duplicate native read stays ignored even with a new caller clock")
        sample.issue="none"
        local bad=context(2,nil,"rolling",1);local refused=Feed.composer(sample,bad)
        check(refused.steps[1].terminal and refused.steps[1].terminal.outcome=="interrupted", "missing duration cannot default to a fabricated interval")
        local gap=Feed.composer(sample,context(1.2,.1,"rolling",1))
        check(gap.issue=="feed_gap" and gap.steps[1].h==0 and gap.steps[1].feed.gap, "clock/interval mismatch interrupts without charging unobserved time")
        local generation=Feed.composer(sample,{seconds=1,h=.1,speed=3,generation=0})
        check(generation.steps[1].terminal~=nil, "composer generation must be a caller-admitted positive cycle")
    end)
    scenario(function()
        local line=Line.new();local start=composer(nil,"manual")
        start.events={{name="balance",event={name="balancing",kind="manual"}}}
        local b=Feed.composer(start,context(1,.1,"rolling"));line:step(b.steps[1].h,b.steps[1].feed)
        local finish=composer(nil,"rolling")
        finish.events={{name="balance",event={name="ended",from="balancing",to="ended",kind="manual",reason="front_drop"}}}
        local f=Feed.composer(finish,context(1.4,.4,"manual",1));local out=line:step(f.steps[1].h,f.steps[1].feed)
        check(f.steps[1].feed.mode=="manual" and f.mode=="rolling", "final ground interval uses preceding mode, then publishes new endpoint")
        check(#out.credits==1 and out.credits[1].points==48, "manual exit includes its final observed four tenths")
        start.events={{name="balance",event={name="entering",kind="manual"}}}
        check(Feed.composer(start,context(2,.1)).steps[1].feed.manual==nil, "entering is not a scored balancing start")
    end)
    scenario(function()
        local sample=composer(nil,"grinding")
        sample.events={{name="grind",event={name="grind_changed",from="double_peg",to="smith",grind="double_peg"}}}
        local b=Feed.composer(sample,context(1,.1,"grinding"))
        check(b.steps[1].feed.grind.grind=="smith", "grind change reads the target to field")
        sample.events={{name="grind",event={name="stalled",from="smith",grind="peg_stall"}}}
        sample.diagnostics.grind={state="stalled",issue="none"}
        local stall=Feed.composer(sample,context(1.1,.1,"grinding",1))
        check(stall.steps[1].feed.grind.event=="grind_changed" and stall.steps[1].feed.grind.grind=="stall"
            and stall.steps[1].feed.mode=="grinding" and stall.mode=="stalling", "stall changes the existing lock rather than double-starting credit")
        sample.events={{name="grind",event={name="lock_on_refused",grind="double_peg"}}}
        check(Feed.composer(sample,context(2,.1)).steps[1].feed.grind==nil, "refused lock never creates credit")
    end)
    scenario(function()
        local rows={};for n=1,8 do rows[n]=row(n,1+(n-1)*.1,event()) end
        local b=Feed.ride(log(rows),0,{})
        check(#b.steps==8 and b.cursor==8 and b.generation==1 and b.issue=="none", "bounded Ride batch preserves cursor and independent time for every sample")
        for n=1,8 do check(near(b.steps[n].h,.1) and near(b.steps[n].feed.seconds,rows[n].seconds), "no shared wrapper dt or timestamp") end
        local repeated=Feed.ride(log({},8),8,{after_seconds=1.7,previous_mode="rolling"})
        check(#repeated.steps==0 and repeated.cursor==8, "unchanged log cannot charge elapsed time twice")
        local next_batch=Feed.ride(log({row(9,1.8,event())},9),8,{after_seconds=1.7,previous_mode="rolling"})
        check(#next_batch.steps==1 and next_batch.cursor==9 and next_batch.issue=="none", "exact successor continues the stream")
    end)
    scenario(function()
        local rows={};for n=3,10 do rows[#rows+1]=row(n,1+n*.1,n==4 and event("landed") or event()) end
        local line=Line.new();credit(line)
        local b=Feed.ride(log(rows,10,true),0,{after_seconds=1,previous_mode="rolling"})
        check(#b.steps==1 and b.steps[1].h==0 and b.steps[1].feed.air==nil and b.cursor==10, "overflow discards all retained partial awards")
        local out=line:step(b.steps[1].h,b.steps[1].feed)
        check(out.closed and out.closed.outcome=="interrupted" and out.closed.points==240 and #out.credits==0, "gap closes only already-completed credit")
        local lied=Feed.ride(log(rows,10,false),0,{after_seconds=1})
        check(lied.issue=="feed_gap", "cursor discontinuity exposes a producer that omits its gap flag")
    end)
    scenario(function()
        local end_row={n=2,control="ended",reason="explicit menu stop"}
        local b=Feed.ride(log({end_row},2),1,{after_seconds=99})
        check(#b.steps==1 and b.steps[1].terminal.outcome=="banked" and b.steps[1].h==nil and b.steps[1].feed==nil,
            "terminal stop closes without inventing physics time or delta")
        check(b.cursor==2 and #Feed.ride(log({},2),2,{}).steps==0, "terminal cursor is consumed exactly once")
        local late=Feed.ride(log({end_row,row(3,100,event("landed"))},3),1,{after_seconds=99.9})
        check(#late.steps==1 and late.steps[1].terminal.outcome=="interrupted", "physical credit after terminal within a batch is refused atomically")
    end)
    scenario(function()
        local failed=event("landed");failed.failed,failed.failure=true,"uncaught"
        failed.sequence={malformed=true}
        local invalid_h=row(3,1.2,event());invalid_h.h=-1
        local invalid_mode=row(3,1.2,event());invalid_mode.mode="unknown"
        local tails={
            {row=invalid_h,issue="invalid_observation"},
            {row=row(2,1.2,event()),issue="invalid_ride_row"},
            {row={n=3,control="ended",reason="explicit menu stop",seconds=1.2},issue="invalid_terminal_row"},
            {row=invalid_mode,issue="invalid_ride_row"},
            {issue="incomplete_ride_log"},
        }
        for _,tail in ipairs(tails) do
            local line=Line.new();credit(line)
            local rows={row(2,1.1,copy(failed))}
            if tail.row then table.insert(rows,copy(tail.row)) end
            local b=Feed.ride(log(rows,3),1,{after_seconds=1,previous_mode="rolling"})
            check(b.issue==tail.issue and #b.steps==1 and b.cursor==1,
                "malformed tail remains diagnosed without consuming partial cursor")
            local t=b.steps[1].terminal
            check(t and t.outcome=="lost" and t.reason=="uncaught" and b.steps[1].feed==nil,
                "an admitted failure wins over a later malformed or missing row")
            local out=line:finish(t.reason,t.outcome)
            check(out.closed and out.closed.outcome=="lost" and out.closed.points==240
                and out.closed.score==0 and #out.credits==0,
                "no coincident landing or retained payout survives malformed-tail failure")
        end
    end)
    scenario(function()
        local invalid=row(3,1.2,event());invalid.h=-1
        local b=Feed.ride(log({row(2,1.1,event(),"bailed"),invalid},3),1,
            {after_seconds=1,previous_mode="rolling"})
        check(b.steps[1].terminal.outcome=="lost" and b.steps[1].terminal.reason=="bailed",
            "an admitted bailed endpoint also survives malformed-tail rejection")
        local ordinary=Feed.ride(log({row(2,1.1,event("landed")),invalid},3),1,
            {after_seconds=1,previous_mode="rolling"})
        check(ordinary.steps[1].terminal.outcome=="interrupted" and ordinary.steps[1].terminal.reason=="invalid_observation",
            "malformation without a recognized bail still interrupts without partial awards")
        local stale=Feed.ride(log({row(1,1.1,event(),"bailed")},1),1,
            {after_seconds=1,previous_mode="rolling"})
        check(stale.steps[1].terminal.outcome=="interrupted" and stale.issue=="invalid_ride_row",
            "a stale unadmitted bail cannot forfeit current-cycle credit")
    end)
    scenario(function()
        local b=Feed.ride(log({row(2,1.1,event("landed")),{n=3,control="ended",reason="measured tilt 18.2 deg over the 15 deg Ride stop"}},3,true),0,{})
        check(#b.steps==1 and b.steps[1].terminal.outcome=="lost", "measured terminal bail wins over gap and coincident landed credit")
        local failed=event("landed");failed.failed,failed.failure=true,"uncaught"
        local c=Feed.ride(log({row(2,1.1,failed),{n=3,control="ended",reason="explicit menu stop"}},3,true),0,{})
        check(c.steps[1].terminal.outcome=="lost" and c.steps[1].terminal.reason=="uncaught", "retained air failure wins over later deliberate end across a gap")
    end)
    scenario(function()
        local bad={
            log({[2]=row(2,1,event())},2),
            log({row(1,1,event()),row(1,1.1,event())},2),
            log({row(1,1,event())},2),
            log({row(2,.5,event())},2),
            {generation=1,n=1,rows=setmetatable({row(1,1,event())},{}),gap=false},
        }
        for _,v in ipairs(bad) do
            local b=Feed.ride(v,0,{after_seconds=.9})
            check(#b.steps==1 and b.steps[1].terminal and b.steps[1].terminal.outcome=="interrupted", "malformed chronology or envelope fails without partial credit")
        end
        local rows={};for i=1,9 do rows[i]=row(i,i,event()) end
        check(Feed.ride(log(rows),0,{}).issue=="invalid_ride_log", "oversized row list is refused rather than truncated")
        local e=event("landed");e.sequence[17]=copy(e.sequence[1])
        local invalid=Feed.ride(log({row(1,1,e)}),0,{})
        check(invalid.steps[1].feed.interrupted=="invalid_trick_event" and invalid.steps[1].feed.air==nil, "malformed air details cannot become a partial award")
    end)
    scenario(function()
        local manual=composer(nil,"manual");manual.diagnostics.balance={stepped=false,issue="support_unknown"}
        local b=Feed.composer(manual,context(1,.1,"manual"))
        check(b.steps[1].feed.interrupted=="balance_observation_unavailable", "held unknown balance cannot earn duration")
        local grind=composer(nil,"grinding");grind.diagnostics.grind={state="locked",issue="unavailable"}
        local g=Feed.composer(grind,context(1,.1,"grinding"))
        check(g.steps[1].feed.interrupted=="unavailable", "held missing rail contact cannot earn distance")
    end)
    scenario(function()
        local absent={
            function(d) d.balance=nil end,
            function(d) d.balance=false end,
            function(d) d.balance={} end,
            function(d) d.balance=setmetatable({stepped=true,issue="none"},{}) end,
            function(d) d.balance={stepped="true",issue="none"} end,
        }
        for _,kind in ipairs({"manual","nose_manual"}) do
            for _,mutate in ipairs(absent) do
                local line=Line.new();credit(line)
                local start=composer(nil,kind)
                start.events={{name="balance",event={name="balancing",kind=kind}}}
                local a=Feed.composer(start,context(1.1,.1,"rolling",1));line:step(a.steps[1].h,a.steps[1].feed)
                local sample=composer(nil,kind);mutate(sample.diagnostics)
                local b=Feed.composer(sample,context(1.5,.4,kind,1.1));local step=b.steps[1]
                check(step.feed.interrupted=="balance_observation_unavailable", "missing/nonphysical balance facts cannot qualify elapsed manual time")
                local out=line:step(step.h,step.feed)
                check(out.closed and out.closed.outcome=="interrupted" and out.closed.points==240 and #out.credits==0,
                    "missing balance drops only pending ground work, retaining earlier completed credit")
                check(out.snapshot.manual_seconds==0 and not out.snapshot.active, "unobserved manual interval is not carried into an exit")
            end
            local line=Line.new();local start=composer(nil,kind)
            start.events={{name="balance",event={name="balancing",kind=kind}}}
            local a=Feed.composer(start,context(1,.1,"rolling"));line:step(a.steps[1].h,a.steps[1].feed)
            local finish=composer(nil,"rolling")
            finish.events={{name="balance",event={name="ended",kind=kind,reason="front_drop"}}}
            local b=Feed.composer(finish,context(1.4,.4,kind,1));local out=line:step(b.steps[1].h,b.steps[1].feed)
            check(b.steps[1].feed.interrupted==nil, "known balance facts retain the complete final observed interval")
            check(#out.credits==1 and out.credits[1].points==(kind=="nose_manual" and 60 or 48), "known manual duration keeps existing authored rates")
        end
    end)
    scenario(function()
        local absent={
            function(d) d.grind=nil end,
            function(d) d.grind=false end,
            function(d) d.grind={} end,
            function(d) d.grind=setmetatable({issue="none"},{}) end,
            function(d) d.grind={issue=false} end,
        }
        for _,mode in ipairs({"grinding","stalling"}) do
            local kind=mode=="stalling" and "peg_stall" or "double_peg"
            for _,mutate in ipairs(absent) do
                local line=Line.new();credit(line)
                local start=composer(nil,mode);start.events={{name="grind",event={name="lock_on",grind=kind}}}
                local a=Feed.composer(start,context(1.1,.1,"rolling",1));line:step(a.steps[1].h,a.steps[1].feed)
                local sample=composer(nil,mode);mutate(sample.diagnostics)
                local b=Feed.composer(sample,context(1.5,.4,mode,1.1));local step=b.steps[1]
                check(step.feed.interrupted=="grind_observation_unavailable", "missing rail diagnostics cannot qualify distance or stall time")
                local out=line:step(step.h,step.feed)
                check(out.closed and out.closed.outcome=="interrupted" and out.closed.points==240 and #out.credits==0,
                    "missing rail drops the unfinished lock rather than awarding its pending subtotal")
                check(out.snapshot.grind_points==0 and not out.snapshot.active, "unobserved grind interval cannot survive for a later exit")
            end
            local line=Line.new();local start=composer(nil,mode)
            start.events={{name="grind",event={name="lock_on",grind=kind}}}
            local a=Feed.composer(start,context(1,.1,"rolling"));line:step(a.steps[1].h,a.steps[1].feed)
            local finish=composer(nil,"rolling");finish.events={{name="grind",event={name="exit",grind=kind,reason="grounded"}}}
            local b=Feed.composer(finish,context(1.4,.4,mode,1));local out=line:step(b.steps[1].h,b.steps[1].feed)
            check(b.steps[1].feed.interrupted==nil, "known rail facts retain the final observed ground interval")
            check(#out.credits==1 and out.credits[1].points==(mode=="stalling" and 230 or 172), "known rail duration keeps existing lock/rate defaults")
        end
    end)
    scenario(function()
        for _,kind in ipairs({"balance","grind"}) do
            local line=Line.new();credit(line)
            local sample=composer(nil,"rolling")
            sample.diagnostics[kind]=nil
            sample.events=kind=="balance" and {{name="balance",event={name="ended",kind="manual",reason="loop_out"}}}
                or {{name="grind",event={name="exit",grind="smith",reason="bail"}}}
            local b=Feed.composer(sample,context(1.1,.1,kind=="balance" and "manual" or "grinding",1))
            check(b.steps[1].feed.interrupted~=nil, "missing ground observation stays explicit alongside a recognized bail")
            local out=line:step(b.steps[1].h,b.steps[1].feed)
            check(out.closed and out.closed.outcome=="lost" and out.closed.score==0 and #out.credits==0,
                "known bail still wins over missing ground observation")
        end
    end)
    -- Dependency-port regressions use the actual pure Tricks producer and the
    -- actual-BMX public projector. They are constructed model facts, not game
    -- contact receipts or evidence that Skate would award these points.
    local function producer()
        local p={model=Tricks.new(),input=Tricks.input({enabled=true,owner="scoring-port",device=1,
            bar_neutral=true,rear_neutral=true,landing_quality_available=true})}
        function p:tick() return self.model:update(.01,self.input) end
        function p:air() self.input.grounded=false;return self:tick() end
        function p:bar(dir)
            self.input.barspin,self.input.bar_neutral=dir or "left",false
            local out=self:tick();self.input.barspin="none";return out
        end
        function p:tail(dir)
            self.input.tailwhip,self.input.rear_neutral=dir or "right",false
            local out=self:tick();self.input.tailwhip="none";return out
        end
        function p:wait(n)
            self.input.bar_neutral,self.input.rear_neutral=true,true
            for _=1,n do self:tick() end
        end
        function p:land()
            self.input.grounded=true
            local out=self:tick()
            for _=1,6 do if not out.landed then out=self:tick() end end
            return out
        end
        p:tick();return p
    end
    local function project(e)
        return TrickRuntime.public_snapshot({valid=true,fresh=true,advanced=true,issue="none",model_events=e})
    end
    scenario(function()
        for _,sample in ipairs({{"left",34,-1},{"right",44,1}}) do
            local p=producer();check(p:air().took_off,"actual model observes takeoff")
            p:bar(sample[1]);p:wait(60);local e=p:land()
            check(e.landed and e.combo_landed and e.barspins==1 and e.units==1,"existing catch and settled landing policy remains authoritative")
            check(#e.sequence==1 and e.sequence[1].id==sample[2] and e.sequence[1].dir==sample[3],"actual signed bar identity crosses dependency port")
            check(near(e.sequence[1].finish-e.sequence[1].start,.45) and e.sequence[1].hold==0,"metadata retains configured rotation duration")
            local out=project(e);check(out and out.model_events.sequence[1].id==sample[2],"minimal actual-BMX projector accepts actual producer detail")
            local b=Feed.composer(composer(e),context(1,.1,"airborne"));local scored=Line.new():step(b.steps[1].h,b.steps[1].feed)
            check(#scored.credits==1 and scored.credits[1].points>0,"opt-in local scoring consumes actual model landing")
            e.sequence[1].id=77;e.landing.closing=999
            check(out.model_events.sequence[1].id==sample[2] and out.model_events.landing.closing==0,"public detail is detached from caller event")
            check(b.steps[1].feed.air.landed.sequence[1].id==sample[2],"feed retains detached signed event")
        end
    end)
    scenario(function()
        local p=producer();p:air();p:bar("left");p:tail("right");p:wait(60);local e=p:land()
        check(e.combo_landed and e.barspins==1 and e.tailwhips==1 and #e.sequence==2,"two actual catches retain existing tally")
        check(e.sequence[1].id==34 and e.sequence[2].id==52 and e.sequence[1].start<e.sequence[2].start,"sequence is ordered by actual request sample time")
        check(e.sequence[1].finish>e.sequence[2].start,"overlapping independent channels retain overlap rather than serialized invented times")
        local out=project(e);check(out and out.model_events.sequence[2].id==52,"both independent detailed channels survive public projection")
    end)
    scenario(function()
        local e=event("landed");e.sequence=nil
        check(project(e)==nil,"old aggregate-only landed packet cannot masquerade as detailed scoring evidence")
        local b=Feed.composer(composer(e),context(1,.1,"airborne"))
        check(b.steps[1].feed.interrupted=="invalid_trick_event" and b.steps[1].feed.air==nil,"missing dependency detail interrupts instead of awarding")
        local ordinary=event();ordinary.air_seconds=0
        check(project(ordinary)==nil,"non-landed packet cannot carry a misplaced detail scalar")
        local plain_event=event();check(project(plain_event)~=nil,"unchanged ordinary model event remains accepted")
    end)
    scenario(function()
        local edits={
            function(e)e.air_seconds=0/0 end,
            function(e)e.spin_radians=math.huge end,
            function(e)e.fakie_takeoff=0 end,
            function(e)e.overflow="false" end,
            function(e)e.sequence={[2]=e.sequence[1]} end,
            function(e)e.sequence[1].dir=1 end,
            function(e)e.sequence[1].finish=e.sequence[1].start end,
            function(e)e.sequence[1].finish=e.air_seconds+.01 end,
            function(e)e.sequence[1].hold=.01 end,
            function(e)e.landing.body_up=2 end,
            function(e)e.landing.heading_cos=2 end,
            function(e)e.landing.closing=-1 end,
            function(e)e.sequence=setmetatable({}, {}) end,
            function(e)e.sequence[1].kind="move" end,
        }
        for _,edit in ipairs(edits) do
            local e=event("landed");edit(e);check(project(e)==nil,"malformed scalar, topology or signed event detail refuses")
            local b=Feed.composer(composer(e),context(1,.1,"airborne"))
            check(b.steps[1].feed.air==nil and b.steps[1].feed.interrupted=="invalid_trick_event","malformed dependency projection cannot reach local award")
        end
    end)
    scenario(function()
        local p=producer();p:air()
        for _=1,17 do p:bar("left");p:wait(60) end
        local e=p:land()
        check(e.landed and e.combo_landed and e.units==17,"sequence bound does not rewrite existing model tally")
        check(e.overflow==true and #e.sequence==16,"seventeenth catch is explicit overflow with bounded sixteen-row detail")
        local projected=project(e);check(projected and projected.model_events.overflow and #projected.model_events.sequence==16,"overflow remains diagnostic instead of dropped flag")
        local b=Feed.composer(composer(e),context(20,.1,"airborne"));local out=Line.new():step(b.steps[1].h,b.steps[1].feed)
        check(out.issue=="invalid_air" and #out.credits==0,"bounded incomplete sequence cannot earn partial local landing credit")
    end)
    scenario(function()
        local p=producer();p:air();p:bar("left");p:wait(60);p:tail("right");local e=p:land()
        check(e.landed and e.failed and e.failure=="under_rotated" and #e.sequence==1,"completed bar metadata survives a real failed tail landing diagnostically")
        local line=Line.new();credit(line)
        local b=Feed.composer(composer(e),context(1.1,.1,"airborne",1));local out=line:step(b.steps[1].h,b.steps[1].feed)
        check(b.steps[1].feed.air.failed=="under_rotated" and b.steps[1].feed.air.landed==nil,"actual failed flag outranks completed detail")
        check(out.closed and out.closed.outcome=="lost" and out.closed.score==0 and #out.credits==0,"failed landing loses previous local credit without partial award")
    end)
    scenario(function()
        local p=producer();p:air();p:bar("left");p:wait(60);local first=p:land()
        p:air();p:tail("right");p:wait(60);local second=p:land()
        check(#first.sequence==1 and first.sequence[1].id==34 and #second.sequence==1 and second.sequence[1].id==52,"successive actual flights never reuse preceding sequence")
        second.sequence[1].id=77;check(first.sequence[1].id==34,"landing snapshots are distinct per attempt")
        p:air();p:bar("left");p:wait(60);p.model:cancel();p.input.grounded=true;p:tick()
        p:air();p:tail("left");p:wait(60);local third=p:land()
        check(#third.sequence==1 and third.sequence[1].id==56 and third.overflow==false,"cancel clears completed metadata before a fresh observed flight")
    end)
    scenario(function()
        local e=event("landed");e.landing=nil;e.binding={owner="private"};e.sequence[1].native_handle=newproxy()
        local out=project(e)
        check(out and out.model_events.landing==nil,"absent landing quality remains absent rather than a fabricated clean score")
        check(out.binding==nil and out.model_events.binding==nil and out.model_events.sequence[1].native_handle==nil,"public scoring detail copies no owner or opaque native authority")
        e.sequence={};e.combo_landed=false;e.barspins,e.units=0,0;e.air_seconds,e.spin_radians,e.flip_radians,e.roll_radians=0,0,0,0
        check(project(e)~=nil,"empty zero-valued ordinary hop detail is a valid bounded observation")
    end)    return {cases=cases,assertions=assertions,native_actions=0}
end
return Tests

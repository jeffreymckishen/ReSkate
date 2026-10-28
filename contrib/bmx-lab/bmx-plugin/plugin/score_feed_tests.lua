-- Synthetic copies of the recorded Composer output shapes and bounded Ride
-- rows. These exercise local accounting only, not native support or scoring.
local Feed=require("./score_feed")
local Line=require("./score_line")
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
    return {cases=cases,assertions=assertions,native_actions=0}
end
return Tests

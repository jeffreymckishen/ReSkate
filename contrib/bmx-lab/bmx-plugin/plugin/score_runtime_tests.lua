local Runtime=require("./score_runtime")
local Rules=require("./score_rules")
local Tests={}
local KEY="bmx_score_v1"
local function bar()
    return {air_seconds=.9,sequence={{kind="bar",id=34,dir=-1,start=.1,finish=.55,hold=0}},
        landing={body_up=1,heading_cos=1,closing=4.32}}
end
local function landed_event()
    local e=bar()
    for _,name in ipairs({"took_off","landed","combo_landed","failed","canceled","bar_caught","tail_caught","movement_caught"}) do e[name]=false end
    for _,name in ipairs({"barspins","tailwhips","spin_half_turns","units","movements","front_flips","back_flips","barrel_rolls"}) do e[name]=0 end
    e.landed,e.barspins,e.units=true,1,1
    e.failure,e.fakie_takeoff,e.overflow="none",false,false
    e.spin_radians,e.flip_radians,e.roll_radians=0,0,0
    return e
end
local function ride_log()
    return {generation=1,n=1,gap=false,rows={{n=1,seconds=1,h=.1,speed=1,mode="rolling",
        landing_pending=false,events=landed_event()}}}
end
local function composer_sample()
    return {valid=true,mode="rolling",events={},diagnostics={trick={valid=true,events=landed_event()}}}
end
local function fixture(options)
    options=options or {}
    local f={writes={},reads={},record=options.record,generation=1,cursor=0,seconds=0}
    local storage={}
    function storage.get(key)
        table.insert(f.reads,key)
        if options.read_error then error("read refused") end
        return f.record
    end
    function storage.set(key,value)
        table.insert(f.writes,{key=key,value=value})
        if f.on_write then f.on_write() end
        if options.write_error then error("write refused") end
        if options.write_false then return false end
        f.record=value
    end
    f.runtime=Runtime.new({storage=storage})
    function f:send(extra,h)
        h=h or .1
        self.seconds+=math.max(h,.001);self.cursor+=1
        local feed={seconds=self.seconds,mode="rolling",speed=1}
        for k,v in pairs(extra or {}) do feed[k]=v end
        local accepted,why=self.runtime:update({generation=self.generation,cursor=self.cursor,issue="none",
            mode=feed.mode,steps={{h=h,feed=feed}}})
        return self.runtime:view(),accepted,why
    end
    function f:land() return self:send({air={landed=bar()}},0) end
    function f:finish(outcome,reason)
        self.cursor+=1
        return self.runtime:update({generation=self.generation,cursor=self.cursor,issue="none",
            steps={{terminal={outcome=outcome,reason=reason or outcome}}}})
    end
    function f:new_generation()
        self.generation+=1;self.cursor=0;self.seconds=0
    end
    return f
end
function Tests.run(progress)
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,body)
        cases+=1;local ok,why=pcall(body)
        if not ok then error(name..": "..tostring(why),0) end
        if type(progress)=="function" then progress(cases,assertions) end
    end
    case("pedalling is idle and storage reads once",function()
        local f=fixture()
        for _=1,10 do f:send({pedal=1}) end
        check(#f.reads==1 and f.reads[1]==KEY and #f.writes==0,"one read, no pedal writes")
        check(not f.runtime:view().active and #f.runtime:view().rows==0,"pedalling opens no line")
        check(f.runtime:status().stats.session_total==0,"no points")
    end)
    case("valid landing and bank-only persistence",function()
        local f=fixture();f:land()
        local s=f.runtime:status()
        check(#f.writes==0 and s.stats.best_single_air==240 and s.stats.session_total==0,"landing is memory only")
        f:finish("banked","dismount")
        check(#f.writes==1 and f.writes[1].key==KEY,"one bank write to own key")
        check(f.record.version==1 and f.record.best_line==360 and f.record.best_single_air==240
            and f.record.session_total==360,"bounded local record")
        check(not f.runtime:status().pending_save and f.runtime:view().closed.new_best,"save/newbest recorded")
    end)
    case("interrupted credit persists with next normal bank",function()
        local f=fixture();f:land();f:finish("interrupted","focus")
        local s=f.runtime:status()
        check(#f.writes==0 and s.stats.session_total==360 and s.stats.best_line==360 and s.pending_save,
            "interrupted bank counts in memory without storage")
        f:new_generation();f:land();f:finish("banked","dismount")
        check(#f.writes==1 and f.record.session_total==720 and f.record.best_line==360,
            "next normal bank persists both")
    end)
    case("loss adds zero and does not persist",function()
        local f=fixture();f:land();f:finish("lost","tilt_stop")
        local s=f.runtime:status()
        check(s.stats.session_total==0 and s.stats.best_line==0 and #f.writes==0,"lost line adds zero")
        check(s.stats.best_single_air==240 and f.runtime:view().closed.score==0,"completed air best survives locally")
        check(f.runtime:view().closed.multiplier==1.5,"HUD can strike forfeited score")
    end)
    case("loaded record copied and never written during construction",function()
        local record={version=1,best_line=1000,best_single_air=500,session_total=2500}
        local f=fixture({record=record})
        record.best_line=99999
        check(f.runtime:status().stats.best_line==1000 and #f.writes==0,"detached read")
        f:land();f:finish("banked","dismount")
        check(f.record.best_line==1000 and f.record.best_single_air==500 and f.record.session_total==2860,
            "best values monotonic, total accumulates")
    end)
    case("read faults preserve unknown prior storage",function()
        local invalid={{version=2,best_line=1,best_single_air=1,session_total=1},
            {version=1,best_line=0/0,best_single_air=1,session_total=1},false,"bad"}
        for _,record in ipairs(invalid) do
            local f=fixture({record=record});f:land();f:finish("banked","dismount")
            check(f.runtime:status().storage_issue=="read_fault" and #f.writes==0,"malformed read disables writes")
            check(f.runtime:status().stats.session_total==360,"memory remains available")
        end
        local f=fixture({read_error=true});f:land();f:finish("banked","dismount")
        check(#f.writes==0 and f.runtime:status().storage_issue=="read_fault","throw contained")
    end)
    case("write fault retries only on later bank",function()
        local options={write_error=true}
        local f=fixture(options);f:land();f:finish("banked","dismount")
        check(#f.writes==1 and f.runtime:status().storage_issue=="write_fault","throw contained")
        f.runtime:advance(.1);f.runtime:status()
        check(#f.writes==1,"no timer/status retry")
        options.write_error=false;f:new_generation();f:land();f:finish("banked","dismount")
        check(#f.writes==2 and f.record.session_total==720 and not f.runtime:status().pending_save,"nextbank retries complete memory")
        local bad=fixture({write_false=true});bad:land();bad:finish("banked","dismount")
        check(bad.runtime:status().storage_issue=="write_fault","unexpected native arity is not success")
    end)
    case("write callback cannot reenter scoring",function()
        local f=fixture();f:land();local reentered,why
        f.on_write=function() reentered,why=f.runtime:update({steps={},issue="none"}) end
        f:finish("banked","dismount")
        check(reentered==false and why=="busy" and #f.writes==1,"reentry rejected before mutation")
    end)
    case("terminal control needs no newer physics time",function()
        local f=fixture();f:land();local before=f.runtime:status().last_seconds
        check(f:finish("banked","dismount"),"nonphysical terminal admitted")
        check(f.runtime:status().last_seconds==before and f.runtime:status().terminal,"physics clock unchanged")
        local total=f.runtime:status().stats.session_total
        f:finish("lost","late duplicate");f:land()
        check(f.runtime:status().stats.session_total==total and #f.writes==1,"later terminal/physical cannot rescore")
    end)
    case("new generation resets cursor and clock but preserves totals",function()
        local f=fixture();f:land();f:finish("interrupted","window")
        f:new_generation();f:land()
        local s=f.runtime:status()
        check(s.generation==2 and s.cursor==1 and s.stats.session_total==360 and f.runtime:view().points==240,"new stream")
        local accepted,why=f.runtime:update({generation=1,cursor=99,steps={},issue="none"})
        check(not accepted and why=="stale_generation" and f.runtime:status().generation==2,"old generation refused")
        f.runtime:update({generation=0,cursor=0,steps={},issue="none"})
        check(f.runtime:status().cursor==1 and not f.runtime:status().terminal,"idle generation ignored")
    end)
    case("generation change interrupts already credited previous line",function()
        local f=fixture();f:land();f:new_generation();f:land()
        check(f.runtime:status().stats.session_total==360 and #f.writes==0,"new generation banks old credit in memory")
        f:finish("banked","dismount")
        check(f.record.session_total==720,"both generations persisted on normal bank")
    end)
    case("cursor repeats cannot recredit changed timestamp",function()
        local f=fixture();f:land()
        local accepted,why=f.runtime:update({generation=1,cursor=1,issue="none",
            steps={{h=.1,feed={seconds=2,mode="rolling",speed=1,air={landed=bar()}}}}})
        check(not accepted and why=="stale_batch" and f.runtime:view().points==240,"cursor dedup independent of timestamp")
    end)
    case("oversized batches and terminal-following credit refuse atomically",function()
        for _,kind in ipairs({"oversize","after_terminal"}) do
            local f=fixture();f:land();local steps={}
            if kind=="oversize" then
                for i=1,9 do steps[i]={h=.1,feed={seconds=i+1,mode="rolling",speed=1,air={landed=bar()}}} end
            else steps={{terminal={reason="dismount",outcome="banked"}},
                {h=.1,feed={seconds=2,mode="rolling",speed=1,air={landed=bar()}}}} end
            local accepted,why=f.runtime:update({generation=1,cursor=20,steps=steps,issue="none"})
            check(not accepted and why=="invalid_batch" and f.runtime:status().stats.session_total==360,"no partial new credit")
            check(#f.writes==0,"invalid batch interruption never writes")
        end
    end)
    case("Line refusal propagates through runtime",function()
        local f=fixture();f:land()
        local a=bar();a.overflow=true
        local _,accepted,why=f:send({air={landed=a}})
        check(accepted and why=="invalid_air" and f.runtime:view().closed.outcome=="interrupted","precise refusal surfaced")
        check(f.runtime:status().stats.session_total==360 and #f.writes==0,"only prior credit")
    end)
    case("Ride wrapper error terminal closes without changing physical cursor/time",function()
        local f=fixture()
        check(f.runtime:ride(ride_log())==true and f.runtime:view().points==240,"actual Feed ride path")
        local before=f.runtime:status()
        local accepted=f.runtime:ride({generation=1,n=2,gap=false,rows={}})
        local after=f.runtime:status()
        check(accepted and after.terminal and after.stats.session_total==360,"unsequenced adapter error closes prior credit")
        check(after.cursor==before.cursor and after.last_seconds==before.last_seconds,"error invented no sample/cursor")
        check(#f.writes==0,"adapter interruption stays memory only")
    end)
    case("admitted bail survives a malformed later Ride row",function()
        local f=fixture();f.runtime:ride(ride_log())
        local failed=landed_event();failed.failed,failed.failure=true,"uncaught"
        local rows={
            {n=2,seconds=1.1,h=.1,speed=1,mode="rolling",landing_pending=false,events=failed},
            {n=3,seconds=1.2,h=-.1,speed=1,mode="rolling",landing_pending=false,events=landed_event()},
        }
        f.runtime:ride({generation=1,n=3,gap=false,rows=rows})
        local s=f.runtime:status();local closed=f.runtime:view().closed
        check(s.terminal and s.issue=="invalid_observation" and s.cursor==1 and s.last_seconds==1,
            "malformed tail terminates without advancing to an unaccepted sample")
        check(closed and closed.outcome=="lost" and closed.reason=="uncaught" and closed.points==240 and closed.score==0,
            "known bail forfeits existing credit despite later malformed observation")
        check(s.stats.session_total==0 and s.stats.best_line==0 and #f.writes==0,
            "failed line neither counts as interrupted credit nor persists")
        check(f.runtime:ride({generation=1,n=3,gap=false,rows=rows})==false
            and f.runtime:status().stats.session_total==0,
            "replaying the refused batch cannot recover or duplicate forfeited credit")
        local fresh=ride_log();fresh.generation=2;f.runtime:ride(fresh)
        f.runtime:ride({generation=2,n=2,gap=false,rows={{n=2,control="ended",reason="explicit menu stop"}}})
        check(#f.writes==1 and f.record.session_total==360 and f.record.best_line==360,
            "next normal bank persists only the new line, with no deferred bail payout")
    end)
    case("idle generation zero differs from Core read failure",function()
        local f=fixture();f.runtime:ride(ride_log())
        f.runtime:ride({generation=0,n=0,gap=false,rows={}})
        check(not f.runtime:status().terminal and f.runtime:view().points==240,"genuine idle leaves current stream")
        f.runtime:ride({n=0,gap=true,rows={},issue="read_failure"})
        check(f.runtime:status().terminal and f.runtime:status().stats.session_total==360,"missing-generation failure interrupts")
        local g=fixture();g.runtime:ride(ride_log())
        g.runtime:ride({generation=0,n=0,gap=true,rows={}})
        check(g.runtime:status().terminal,"malformed generation0 is not idle")
    end)
    case("composer wrapper preserves caller gap and interruption",function()
        for _,field in ipairs({"gap","interrupted"}) do
            local f=fixture()
            check(f.runtime:composer(composer_sample(),{generation=1,seconds=1,h=.1,speed=1})==true,"actual Feed composer path")
            local context={generation=1,seconds=1.1,h=.1,speed=1}
            context[field]=field=="gap" and true or "focus"
            f.runtime:composer({valid=true,mode="rolling",events={},diagnostics={}},context)
            check(f.runtime:status().stats.session_total==360 and f.runtime:view().closed.outcome=="interrupted",
                "caller "..field.." reaches Line")
            check(#f.writes==0,"interruption no immediate storage")
        end
    end)
    case("composer terminal restarts only on explicit newer cycle",function()
        local f=fixture();local sample=composer_sample()
        check(f.runtime:composer(sample,{seconds=1,h=.1,speed=1})==false,"generation required")
        f.runtime:composer(sample,{generation=1,seconds=1,h=.1,speed=1})
        f.runtime:update({generation=1,steps={{terminal={reason="dismount",outcome="banked"}}},issue="none"})
        f.runtime:composer(sample,{generation=1,seconds=2,h=1,speed=1})
        check(f.runtime:status().terminal and f.runtime:status().stats.session_total==360,"late same-cycle landing refused")
        f.runtime:composer(sample,{generation=2,seconds=.1,h=.1,speed=1})
        check(not f.runtime:status().terminal and f.runtime:view().points==240 and f.runtime:status().stats.session_total==360,
            "admitted new cycle gets fresh Line preserving totals")
        check(f.runtime:ride(ride_log())==false,"source switch requires separate Runtime")
    end)
    case("four-row ring, immutable view and detached status",function()
        local f=fixture()
        for _=1,6 do f:land() end
        local view=f.runtime:view()
        check(#view.rows==4 and view.rows[4].points==60,"latest4 credits retained")
        check(table.isfrozen(view) and table.isfrozen(view.rows) and table.isfrozen(view.rows[1]),"immutable cache inputs")
        check(not pcall(function() view.rows[1].points=999 end),"external mutation refused")
        local s=f.runtime:status();s.stats.session_total=999
        check(f.runtime:status().stats.session_total==0,"status detached")
    end)
    case("banner expiry advances display only",function()
        local f=fixture();f:land();f:finish("banked","dismount")
        local cursor,last=f.runtime:status().cursor,f.runtime:status().last_seconds
        f.runtime:advance(1.49)
        check(f.runtime:view().closed~=nil,"bank visible before1.5seconds")
        f.runtime:advance(.02)
        check(f.runtime:view().closed==nil,"bank hides after1.5seconds")
        check(f.runtime:status().cursor==cursor and f.runtime:status().last_seconds==last and #f.writes==1,"expiry no physics or storage")
        local lost=fixture();lost:land();lost:finish("lost","bail");lost.runtime:advance(1.2)
        check(lost.runtime:view().closed==nil,"bail1.2seconds")
        check(lost.runtime:advance(-1)==false and lost.runtime:advance(math.huge)==false,"invalid displaydt refused")
    end)
    case("layout caching and drawing faults",function()
        local f=fixture();f:land()
        local d={calls=0,width=1920,height=1080}
        function d:size() return {x=self.width,y=self.height} end
        function d:text() self.calls+=1 end
        function d:line() self.calls+=1 end
        function d:rect() self.calls+=1 end
        check(f.runtime:draw(d)==true and d.calls>0,"actual HUD dispatch")
        local builds=f.runtime:status().layout_builds
        f.runtime:draw(d);f.runtime:advance(.01);f.runtime:draw(d)
        check(f.runtime:status().layout_builds==builds,"unchanged visible snapshot reuses ops")
        d.width=1280;d.height=720;f.runtime:draw(d)
        check(f.runtime:status().layout_builds==builds+1,"size change rebuilds")
        function d:text() error("draw refused") end
        check(f.runtime:draw(d)==false,"native draw fault contained")
        function d:size() error("size refused") end
        check(f.runtime:draw(d)==false and f.runtime:status().stats.session_total==0,"sizefault cannot mutate score")
    end)
    case("air header has no landed points and manual duration stays separate",function()
        local f=fixture()
        local view=f:send({mode="airborne",air={took_off=true},live={bar_rotating=true}})
        check(view.airborne and view.live_name=="Barspin" and #view.rows==0,"live header only")
        f:send({air={landed=bar()}})
        f:send({mode="manual",manual={event="balancing",kind="manual"}},0)
        view=f:send({mode="manual"},.5)
        check(view.manual_kind=="manual" and view.manual_seconds==.5 and view.points==240,"manual livecounter noearlycredit")
    end)
    case("storage totals saturate",function()
        local f=fixture({record={version=1,best_line=1,best_single_air=1,session_total=Rules.MAX_SCORE-10}})
        f:land();f:finish("banked","dismount")
        check(f.record.session_total==Rules.MAX_SCORE and f.runtime:status().stats.session_total==Rules.MAX_SCORE,"2^53cap")
    end)
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return Tests

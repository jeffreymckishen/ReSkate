-- Constructed Core Follow lease cases (LUA-4 B5 against S2's read_follow_lease).
-- Every SDK result here is a fixture: no Host, permission, native clock or game.
-- The ride fixture swaps bike_spawn's constructor for a stand-in only while Core
-- binds its backend, so the real reserve, publish and following lines run.
local Core=require("./bike_runtime_core")
local Spawn=require("./bike_spawn")
local Identity=require("./lease_identity")
local Tests={}
local limits=Core.ride_limits

local function fixed(remaining,over)
    local row={sequence="7",renewable=false,active=true,renewals="0",last_serial="0",remaining_ms=remaining,
        lifetime_remaining_ms=remaining,base_ms=3000,renewal_ms=500,lifetime_ms=3000,revocation="none",dispatch_busy="0"}
    for key,value in pairs(over or {}) do row[key]=value end
    return row
end
local function renewable(remaining,renewals,over)
    local row=fixed(remaining,{renewable=true,lifetime_ms=120000,lifetime_remaining_ms=60000,
        renewals=renewals,last_serial=renewals=="0" and "0" or "41"})
    for key,value in pairs(over or {}) do row[key]=value end
    return row
end

local function fake_spawn(f)
    local owner={phase="armed"}
    function owner:request() return true end
    function owner:update() if self.phase=="armed" then self.phase="spawned" end end
    function owner:status()
        return {phase=self.phase,cleanup_unknown=false,creation_unknown=false,body=false,visual_remove_requested=false}
    end
    function owner:handoff_follow() self.phase="follow_owned";return f.body,{serial="1"},nil end
    function owner:follow_visual()
        f.visuals+=1
        if f.visual_delay then f.now+=f.visual_delay end
        return true
    end
    function owner:stop() self.phase="closed" end
    return owner
end
-- A constructed owner one tick before publication: Spawn reports spawned, so
-- the next Core step runs handoff, reserve, the reservation read and publish.
-- The delay fields move the clock inside one call, as a slow SDK call would.
local function ride_fixture(options)
    options=options or {}
    local f={now=10000,clock_step=options.clock_step or 0,reserve_delay=options.reserve_delay or 0,
        reads=0,lease_calls=0,body_reads=0,publishes=0,reserves=0,stops=0,visuals=0,trace={},
        follow=newproxy(),body=newproxy(),published=false}
    local s={time={},input={},skater={},level={},storage={},json={},menu={},entities={},world={physics={}}}
    function s.time.now() local value=f.now;f.now+=f.clock_step;table.insert(f.trace,"clock");return value end
    function s.json.encode() return "constructed bounded storage DTO" end
    function s.storage.get() return nil end
    function s.storage.set() end
    local P=s.world.physics
    function P.reserve_follow(_,attachment)
        f.reserves+=1;f.reserve_called_at=f.now;f.attachment=attachment;f.now+=f.reserve_delay
        return f.follow,nil
    end
    function P.read_follow()
        f.reads+=1;table.insert(f.trace,"read")
        if f.read_delay then f.now+=f.read_delay end
        local following=f.published
        return {phase=following and "following" or "reserved",reason="none",park_reason="none",sequence="7",
            final_revision=following and "1" or "0",final_native_epoch=following and "5" or "0",
            returned_revision=following and "1" or "0",pending={},in_flight=0,claim_known=true,orphaned=false,
            park_observed=false,native_retirement_known=false,terminal=false}
    end
    function P.publish_follow()
        f.publishes+=1;f.published=true
        if f.publish_delay then f.now+=f.publish_delay end
        return true
    end
    function P.read()
        f.body_reads+=1;table.insert(f.trace,"body")
        if f.body_delay then f.now+=f.body_delay end
        return {serial=tostring(f.body_reads+1)}
    end
    function P.stop_follow() f.stops+=1;return true end
    function P.acknowledge_follow() return true end
    function P.release() return true end
    if options.lease then
        function P.read_follow_lease(handle)
            f.lease_calls+=1;f.lease_called_at=f.now;f.lease_handle=handle;table.insert(f.trace,"lease")
            return options.lease(f)
        end
    end
    local state={phase="spawning",detail="constructed spawned owner",generation=1,cancel_version=1,calls={},counts={},
        receipts={},omitted_calls=0,omitted_receipts=0,remove_attempted={},remove_accepted={},used=true,
        ledger_owned=true,spawn_requested=true,input_current=true,slot=0}
    local core=Core.new(s,{qualification_only=true},state)
    local original=Spawn.new
    Spawn.new=function() return fake_spawn(f) end
    local ok,bound=pcall(core.prepare_backend,core)
    Spawn.new=original
    assert(ok and bound==true,"constructed backend binds the stand-in spawn owner")
    function f.tick(at)
        if at then assert(at>=f.now,"fixture time is monotonic");f.now=at end
        local before={reads=f.reads,lease=f.lease_calls,body=f.body_reads}
        local out=core:step(16)
        return out,{reads=f.reads-before.reads,lease=f.lease_calls-before.lease,body=f.body_reads-before.body}
    end
    return f,core,state
end
-- A constructed owner already stopping, for the cleanup lines.
local function cleanup_fixture(now)
    local f={now=now or 50000,reads=0}
    local s={time={now=function() return f.now end},input={},skater={},level={},entities={},menu={},
        json={encode=function() return "constructed bounded storage DTO" end},
        storage={get=function() return nil end,set=function() end},world={physics={}}}
    function s.world.physics.read_follow()
        f.reads+=1
        return {phase="stopping",reason="cancelled",park_reason="none",sequence="7",final_revision="1",
            final_native_epoch="5",returned_revision="1",pending={},in_flight=0,claim_known=true,orphaned=false,
            park_observed=false,native_retirement_known=false,terminal=false}
    end
    function s.world.physics.stop_follow() return true end
    local state={phase="idle",generation=2,cancel_version=1,calls={},counts={},receipts={},omitted_calls=0,
        omitted_receipts=0,remove_attempted={},remove_accepted={}}
    local core=Core.new(s,{qualification_only=true},state)
    assert(core:prepare_backend(),"constructed backend binds without any actuator")
    state.used,state.stop_latched,state.stop_reason,state.stop_at=true,true,"constructed stop",f.now
    state.phase,state.active,state.follow,state.transferred,state.ledger_owned="stopping",false,newproxy(),true,true
    state.follow_stop_attempted,state.follow_stop_accepted=true,true
    return f,core,state
end

function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,run) cases+=1;run(name) end
    local from=Core.lease_from_report

    -- Pure policy against S2's copied report.
    case("a report that shortens",function()
        local until_ms,renewals,verdict,why=from(Identity,4000,"0",fixed(2000),1500,"7",false)
        check(verdict=="refined" and why=="shortened" and until_ms==3500 and renewals=="0",
            "remaining time from a pre-call clock replaces a later seed")
    end)
    case("a report cannot extend without a renewal",function()
        local until_ms,_,verdict,why=from(Identity,4000,"0",fixed(2900),1500,"7",false)
        check(verdict=="refined" and why=="unchanged" and until_ms==4000,"a later native deadline leaves the seed")
        until_ms,_,verdict=from(Identity,4000,"0",fixed(2500),1500,"7",false)
        check(verdict=="refined" and until_ms==4000,"an equal deadline changes nothing")
    end)
    case("a renewals increase may move the deadline later",function()
        local until_ms,renewals,verdict,why=from(Identity,4000,"0",renewable(3000,"1"),2000,"7",true)
        check(verdict=="refined" and why=="renewed" and until_ms==5000 and renewals=="1",
            "a newer accepted renewal replaces the deadline")
        until_ms,renewals,verdict,why=from(Identity,5000,"1",renewable(3000,"1"),2500,"7",true)
        check(verdict=="refined" and why=="unchanged" and until_ms==5000 and renewals=="1",
            "the same renewal count cannot extend again")
        until_ms,renewals,verdict=from(Identity,5000,"1",renewable(400,"2"),2500,"7",true)
        check(verdict=="refined" and until_ms==2900 and renewals=="2","a newer renewal can also move it earlier")
        until_ms,renewals,verdict,why=from(Identity,5000,"2",renewable(3000,"1"),2500,"7",true)
        check(verdict=="ignored" and why=="lease_renewals_regressed" and until_ms==5000 and renewals=="2",
            "a renewal count that went back changes nothing")
        until_ms,renewals,verdict=from(Identity,5000,"18446744073709551614",
            renewable(3000,"18446744073709551615"),2500,"7",true)
        check(verdict=="refined" and until_ms==5500 and renewals=="18446744073709551615",
            "renewal counts compare as exact u64 strings")
    end)
    case("active=false",function()
        local until_ms,renewals,verdict,why=from(Identity,4000,"0",fixed(0,{active=false}),1500,"7",false)
        check(verdict=="stop" and why=="Follow lease is no longer active" and until_ms==4000 and renewals=="0",
            "an inactive native lease stops the ride and extends nothing")
        until_ms,renewals,verdict=from(Identity,4000,"0",fixed(800,{active=false}),1500,"7",false)
        check(verdict=="stop","inactive with time left still stops")
    end)
    for _,name in ipairs({"deadline","lifetime","clock","client_not_ready","focus_lost","menu_open","pause_menu_open",
        "debug_control","actor_state","other"}) do
        case("revocation "..name,function()
            local until_ms,_,verdict,why=from(Identity,4000,"0",fixed(0,{active=false,revocation=name}),1500,"7",false)
            check(verdict=="stop" and why=="Follow lease revoked: "..name and until_ms==4000,"a revoked lease stops the ride")
        end)
    end
    local malformed={
        {"not a table",function() return "report" end},
        {"metatable",function(r) return setmetatable(r,{}) end},
        {"missing field",function(r) r.dispatch_busy=nil;return r end},
        {"numeric dispatch_busy",function(r) r.dispatch_busy=0;return r end},
        {"noncanonical dispatch_busy",function(r) r.dispatch_busy="01";return r end},
        {"extra field",function(r) r.deadline_ms=99999;return r end},
        {"other sequence",function(r) r.sequence="8";return r end},
        {"renewable on a fixed reserve",function(r) r.renewable=true;return r end},
        {"nonboolean active",function(r) r.active=1;return r end},
        {"numeric renewals",function(r) r.renewals=0;return r end},
        {"noncanonical serial",function(r) r.last_serial="01";return r end},
        {"serial without renewal",function(r) r.last_serial="4";return r end},
        {"fixed lease with a renewal",function(r) r.renewals="1";r.last_serial="4";return r end},
        {"unknown revocation",function(r) r.revocation="expired";return r end},
        {"base bound",function(r) r.base_ms=2999;return r end},
        {"renewal bound",function(r) r.renewal_ms=1000;return r end},
        {"fixed with the renewable ceiling",function(r) r.lifetime_ms=120000;return r end},
        {"remaining above lifetime",function(r) r.remaining_ms=2500;return r end},
        -- S2's follow_lease refuses a fixed lease whose two remaining times differ.
        {"fixed lease with remaining below lifetime",function(r) r.remaining_ms=1500;return r end},
        {"remaining beyond the fixed lease",function(r) r.remaining_ms=3001;r.lifetime_remaining_ms=3001;return r end},
        {"fractional remaining",function(r) r.remaining_ms=1999.5;r.lifetime_remaining_ms=1999.5;return r end},
        {"negative remaining",function(r) r.remaining_ms=-1;r.lifetime_remaining_ms=-1;return r end},
        {"NaN remaining",function(r) r.remaining_ms=0/0;return r end},
        {"string remaining",function(r) r.remaining_ms="2000";return r end},
        {"active with nothing left",function(r) r.remaining_ms=0;r.lifetime_remaining_ms=0;return r end},
        {"active and revoked",function(r) r.remaining_ms=0;r.lifetime_remaining_ms=0;r.revocation="focus_lost";return r end},
        {"revoked with time left",function(r) r.active=false;r.revocation="deadline";return r end},
    }
    for _,spec in ipairs(malformed) do
        case("malformed report: "..spec[1],function()
            local until_ms,renewals,verdict,why=from(Identity,4000,"0",spec[2](fixed(2000)),1500,"7",false)
            check(verdict=="ignored" and why=="lease_report_malformed" and until_ms==4000 and renewals=="0",
                "a malformed report neither stops nor extends")
        end)
    end
    case("invalid clock or lease state",function()
        for _,before in ipairs({-1,0/0,math.huge,"1500"}) do
            local until_ms,_,verdict,why=from(Identity,4000,"0",fixed(2000),before,"7",false)
            check(verdict=="ignored" and why=="lease_clock_invalid" and until_ms==4000,"an invalid pre-call clock is not an anchor")
        end
        local _,_,verdict,why=from(Identity,4000,"0",fixed(2000),nil,"7",false)
        check(verdict=="ignored" and why=="lease_clock_invalid","a missing pre-call clock is not an anchor")
        _,_,verdict,why=from(Identity,9007199254740991,"0",fixed(2000),9007199254740000,"7",false)
        check(verdict=="ignored" and why=="lease_clock_invalid","an overflowing deadline is not used")
        for _,state in ipairs({{nil,"0","7"},{4000,"01","7"},{4000,"0","0"},{4000,"0",nil},{0/0,"0","7"}}) do
            local until_ms,_,result=from(Identity,state[1],state[2],fixed(2000),1500,state[3],false)
            check(result=="ignored" and until_ms==state[1] or result=="ignored" and until_ms~=until_ms,
                "a missing seed, counter or sequence is never refined")
        end
        _,_,verdict=from(Identity,4000,"0",fixed(2000),1500,"7","false")
        check(verdict=="ignored","the lifetime expectation must be a boolean")
    end)

    -- Core itself, from publication on.
    case("seed only",function()
        local f,_,state=ride_fixture({reserve_delay=2400})
        local out,n=f.tick()
        check(out.phase=="following" and state.reserve_at==10000 and state.lease_until==13000
            and f.reserve_called_at==10000 and state.publish_at==12400,
            "the seed is three seconds from the clock read before reserve_follow")
        check(f.attachment.lifetime==nil and f.lease_calls==0,"Core reserves the fixed lease and has no report to read")
        check(n.reads==1 and n.body==0 and f.visuals==1,"the publish tick reads the reservation only")
        out,n=f.tick(12849)
        check(out.stop_reason==nil and n.reads==1 and n.lease==0 and n.body==1,"inside the seed the ride continues")
        out=f.tick(12850)
        check(out.stop_reason=="ride window or Follow lease ended" and state.lease_until==13000,
            "the seed less the margin ends the ride before its 500 ms window")
    end)
    case("reserve and publish read the same seed",function()
        local f=ride_fixture({reserve_delay=3000})
        local out=f.tick()
        check(out.stop_reason=="reserve callback cancelled or exceeded native lease" and f.publishes==0,
            "a reserve call that outlasts the seed never publishes")
        f=ride_fixture({reserve_delay=2000});f.read_delay=1000
        out=f.tick()
        check(out.stop_reason=="reservation lease elapsed before publish" and f.publishes==0,
            "a reservation read that reaches the seed never publishes")
        f=ride_fixture();f.publish_delay=500
        out=f.tick()
        check(out.stop_reason=="publish refused, cancelled or bounded interval elapsed" and f.publishes==1,
            "a publish call that outlasts the window stops at once")
        f=ride_fixture();f.publish_delay=499
        out=f.tick()
        check(out.phase=="following" and out.stop_reason==nil,"inside the window publication stands")
    end)
    case("publication against the seed less the margin",function()
        -- Reserve returns 2700 ms into the seed, so the lease bound (12850) comes
        -- before the 500 ms window (13200) and alone decides the publish check.
        local f,_,state=ride_fixture({reserve_delay=2700});f.publish_delay=150
        local out=f.tick()
        check(state.publish_at==12700 and f.publishes==1 and state.phase~="following"
            and out.stop_reason=="publish refused, cancelled or bounded interval elapsed",
            "a publish call that reaches the seed less the margin stops inside the window")
        f,_,state=ride_fixture({reserve_delay=2700});f.publish_delay=149
        out=f.tick()
        check(out.phase=="following" and out.stop_reason==nil and state.publish_at==12700,
            "a millisecond earlier, publication stands")
        f,_,state=ride_fixture({reserve_delay=2850})
        out=f.tick()
        check(state.publish_at==12850 and f.publishes==1 and state.phase~="following"
            and out.stop_reason=="publish refused, cancelled or bounded interval elapsed",
            "a publication that begins inside the margin never starts following")
    end)
    -- The two later mid-tick bounds, each by the window and by the lease. The
    -- lease cases publish at 12400 against a 13000 seed, so at 12700 the window
    -- has 200 ms left but the lease bound (12850) comes first.
    local midtick={
        {"the window ends during the body read",{},10400,"body_delay",100,"during body read",1},
        {"the lease ends during the body read",{reserve_delay=2400},12700,"body_delay",150,"during body read",1},
        {"the window ends during the visual update",{},10400,"visual_delay",100,"during visual update",2},
        {"the lease ends during the visual update",{reserve_delay=2400},12700,"visual_delay",150,"during visual update",2},
    }
    for _,spec in ipairs(midtick) do
        case(spec[1],function()
            local f,_,state=ride_fixture(spec[2])
            f.tick()
            f[spec[4]]=spec[5]
            local out,n=f.tick(spec[3])
            check(out.stop_reason=="ride window or Follow lease ended "..spec[6] and n.body==1,
                "the bound is checked straight after the call that crossed it")
            check(f.visuals==spec[7] and f.stops==1 and state.phase~="following",
                "nothing more is placed once the bound has passed, and the native Follow is stopped")
            f,_,state=ride_fixture(spec[2])
            f.tick()
            f[spec[4]]=spec[5]-1
            out,n=f.tick(spec[3])
            check(out.stop_reason==nil and state.phase=="following" and n.body==1 and f.visuals==2,
                "a millisecond inside the bound, the tick completes")
        end)
    end
    case("seed only, tracked window",function()
        local f,_,state=ride_fixture()
        f.tick()
        check(state.publish_at==10000 and state.lease_until==13000,"a quick reserve publishes at once")
        local out=f.tick(10499)
        check(out.stop_reason==nil,"inside the 500 ms window")
        out=f.tick(10500)
        check(out.stop_reason=="ride window or Follow lease ended","RIDE_WINDOW_MS=500 ends the ride")
    end)
    case("a lease read that shortens",function()
        local f,_,state=ride_fixture({reserve_delay=1000,lease=function() return fixed(300) end})
        f.tick()
        local out,n=f.tick(11100)
        check(n.lease==1 and state.lease_until==11400 and out.lease_until_ms==11400 and out.lease_reports==1
            and out.lease_report_last=="shortened" and out.stop_reason==nil,"the report replaces the later seed")
        out,n=f.tick(11249)
        check(out.stop_reason==nil and n.lease==1 and state.lease_until==11400 and out.lease_report_last=="unchanged",
            "inside the shortened lease, and a later report does not undo it")
        out=f.tick(11250)
        check(out.stop_reason=="ride window or Follow lease ended" and state.lease_until==11400,
            "the shortened lease less the margin ends the ride before the window")
    end)
    case("a shortening read stops within the same tick",function()
        local f,_,state=ride_fixture({lease=function() return fixed(100) end})
        f.tick()
        local out,n=f.tick(10016)
        check(state.lease_until==10116 and n.lease==1 and n.body==0
            and out.stop_reason=="ride window or Follow lease ended during receipt or lease read",
            "a report inside the margin stops before the body read")
    end)
    case("a later report never extends the seed",function()
        local f,_,state=ride_fixture({lease=function() return fixed(2999) end})
        f.tick()
        local out=f.tick(10100)
        check(state.lease_until==13000 and out.lease_report_last=="unchanged","a fixed lease report cannot move the seed later")
    end)
    case("a failed read",function()
        local f,_,state=ride_fixture({lease=function() return nil,"follow lease busy" end})
        f.tick()
        local out,n=f.tick(10100)
        check(n.lease==1 and state.lease_until==13000 and out.lease_report_last=="follow lease busy"
            and out.stop_reason==nil,"a busy report keeps the seed and the ride")
        out,n=f.tick(10200)
        check(n.lease==1 and not state.lease_report_refused,"a busy report is read again next tick")
        out=f.tick(10500)
        check(out.stop_reason=="ride window or Follow lease ended","the seed and window still end the ride")
    end)
    case("a malformed read",function()
        local f,_,state=ride_fixture({lease=function() return fixed(100,{deadline_ms=10100}) end})
        f.tick()
        local out=f.tick(10050)
        check(state.lease_until==13000 and out.lease_report_last=="lease_report_malformed" and out.stop_reason==nil,
            "a malformed report is not used, even to shorten")
        local g,_,other=ride_fixture({lease=function() return fixed(100),"extra" end})
        g.tick()
        out=g.tick(10050)
        check(other.lease_until==13000 and out.lease_report_last=="lease report returned malformed results",
            "extra results are not a report")
    end)
    case("a refused read without the permission",function()
        local f,_,state=ride_fixture({lease=function()
            error("reskate.world.physics follow renewal needs the \"world.physics.follow.renew\" permission in reskate-plugin.json",0)
        end})
        f.tick()
        local out=f.tick(10100)
        check(state.lease_report_refused and out.lease_report_refused and state.lease_until==13000
            and out.stop_reason==nil,"a raise latches seed-only operation and does not stop the ride")
        out=f.tick(10200)
        check(f.lease_calls==1,"a raised report is not called again")
        out=f.tick(10500)
        check(out.stop_reason=="ride window or Follow lease ended","the seed alone still bounds the ride")
    end)
    case("active=false",function()
        local f,_,state=ride_fixture({lease=function() return fixed(0,{active=false}) end})
        f.tick()
        local out,n=f.tick(10100)
        check(out.stop_reason=="Follow lease is no longer active" and n.body==0 and state.lease_until==13000,
            "an inactive report stops before the body read")
        check(f.stops==1,"the stop requests the native Follow stop once")
    end)
    case("a revocation",function()
        local f,_,_=ride_fixture({lease=function() return fixed(0,{active=false,revocation="focus_lost"}) end})
        f.tick()
        local out,n=f.tick(10100)
        check(out.stop_reason=="Follow lease revoked: focus_lost" and n.body==0,"a revoked report stops the ride")
    end)
    case("a renewals increase Core did not request",function()
        local f,_,state=ride_fixture({lease=function() return renewable(9000,"1") end})
        f.tick()
        local out=f.tick(10100)
        check(state.lease_until==13000 and state.lease_renewals=="0" and out.lease_report_last=="lease_report_malformed",
            "Core reserved a fixed lease, so a renewable report extends nothing")
    end)
    case("clock read ordering",function()
        local f,_,state=ride_fixture({clock_step=3,lease=function() return fixed(2000) end})
        f.tick()
        check(state.reserve_at+3==f.reserve_called_at and state.lease_until==state.reserve_at+3000,
            "the seed uses the clock read before reserve_follow, not the call or its return")
        f.tick(state.publish_at+30)
        local at
        for index,name in ipairs(f.trace) do if name=="lease" then at=index end end
        check(at and f.trace[at-1]=="clock" and f.trace[at+1]=="clock","a clock read comes just before and after the report")
        check(state.lease_until==f.lease_called_at-3+2000 and state.lease_until<f.lease_called_at+2000,
            "the report is anchored to the clock read before the call, so call time only shortens it")
        check(f.lease_handle==f.follow,"the report is read for Core's own Follow handle")
    end)
    case("the read budget per tick",function()
        local f,_,_=ride_fixture({lease=function() return fixed(2000) end})
        local out,n=f.tick()
        check(n.reads==1 and n.lease==0 and n.body==0 and out.follow_reads_this_tick==1 and out.lease_reads_this_tick==0,
            "publish tick: the reservation read only")
        out,n=f.tick(10100)
        check(n.reads==1 and n.lease==1 and n.body==1 and out.follow_reads_this_tick==1 and out.lease_reads_this_tick==1,
            "following tick: one receipt read, one lease report, one body read")
        check(out.follow_reads_per_tick==limits.follow_reads_per_tick and out.lease_reads_per_tick==1
            and out.follow_cleanup_reads==400,"the status reports the budget")
    end)
    case("cleanup reads at the cap",function()
        local f,core,state=cleanup_fixture()
        state.cleanup_reads=limits.cleanup_reads-2
        f.now+=60;core:step(16)
        f.now+=60;core:step(16)
        check(f.reads==2 and state.cleanup_reads==limits.cleanup_reads,"the last two cleanup reads are made")
        f.now+=60;local out=core:step(16)
        check(f.reads==2 and out.follow_cleanup_reads_used==400,"the 401st cleanup read is refused before the SDK call")
    end)
    -- CLEANUP_READS is sized from one read per FOLLOW_POLL_MS, so the throttle
    -- is what makes 400 reads last the whole watchdog.
    case("cleanup reads once per poll",function()
        local f,core,state=cleanup_fixture()
        f.now+=16;core:step(16)
        check(f.reads==1,"the first cleanup tick reads the receipt")
        f.now+=limits.follow_poll_ms-1;core:step(16)
        check(f.reads==1,"a tick inside the poll interval makes no read")
        f.now+=1;core:step(16)
        check(f.reads==2 and state.cleanup_reads==2,"the next read comes one poll after the last")
    end)
    case("cleanup reads last the whole watchdog at 60 Hz",function()
        local f,core,state=cleanup_fixture()
        local reads,last_read=f.reads,nil
        while f.now+16-state.stop_at<limits.cleanup_watchdog_ms do
            f.now+=16;core:step(16)
            if f.reads>reads then reads=f.reads;last_read=f.now end
        end
        check(f.reads<=limits.cleanup_reads and state.cleanup_reads==f.reads and state.cleanup_expired~=true,
            "16 ms ticks stay inside the cleanup read budget")
        check(last_read~=nil and last_read-state.stop_at>limits.cleanup_watchdog_ms-limits.follow_poll_ms-16,
            "cleanup still reads the receipt in the watchdog's last poll")
        f.now+=16;local out=core:step(16)
        check(state.cleanup_expired==true and out.phase=="retained_unknown" and f.reads==reads,
            "at the watchdog cleanup stops reading and retains its duty")
    end)
    case("the cleanup watchdog starts at the stop",function()
        local f,core,state=cleanup_fixture(50000)
        state.effect_at=0
        f.now+=60;core:step(16)
        check(state.cleanup_expired~=true and f.reads==1,"an old Source arm does not expire cleanup that just began")
        f.now=state.stop_at+limits.cleanup_watchdog_ms;local out=core:step(16)
        check(state.cleanup_expired==true and out.phase=="retained_unknown","cleanup expires 20 s after the stop")
    end)
    return {cases=cases,assertions=assertions,native_actions=0}
end

return table.freeze(Tests)

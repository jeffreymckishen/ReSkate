-- Constructed Core Follow renewal cases (LUA-12 on LUA-4's single lease source).
-- Every SDK result is a fixture shaped like Extension/Plugins/plugin_api_physics.cpp:
-- renew_follow raises for a missing permission, then for a wrong arity, then
-- spends the one renewal a plugin tick; read_follow_lease reports the same
-- constructed native lease. No Host, permission, native clock or game. The
-- tracked Core keeps its false literal; the trial copy is Core with only
-- FOLLOW_RENEWAL_QUALIFIED flipped, as the luau-runner stages it.
local Core=require("./bike_runtime_core")
local Trial=require("./bike_runtime_core_follow_renewal_fixture")
local Spawn=require("./bike_spawn")
local Tests={}
local PERMISSION='reskate.world.physics follow renewal needs the "world.physics.follow.renew" permission in reskate-plugin.json'
local ARITY="renew_follow takes one opaque follow handle and one measured body epoch"
local FOREIGN="body epoch belongs to another body or plugin instance"

local function fake_spawn(f)
    local owner={phase="armed"}
    function owner:request() return true end
    function owner:update() if self.phase=="armed" then self.phase="spawned" end end
    function owner:status()
        return {phase=self.phase,cleanup_unknown=false,creation_unknown=false,body=false,visual_remove_requested=false}
    end
    function owner:handoff_follow() self.phase="follow_owned";return f.body,{serial="1"},nil end
    function owner:follow_visual() f.visuals+=1;return true end
    function owner:stop() self.phase="closed" end
    return owner
end
-- A constructed owner one tick before publication, as in core_follow_lease_tests,
-- over a constructed native lease: three seconds from reservation, moved to
-- max(deadline, min(now + 500, reservation + 120 s)) by an accepted renewal.
local function fixture(module,options)
    options=options or {}
    local f={now=10000,reserve_delay=options.reserve_delay or 0,permitted=options.permitted~=false,
        reads=0,lease_calls=0,body_reads=0,renews=0,probes=0,raised=0,publishes=0,stops=0,visuals=0,
        accepted=0,tick_renews=0,trace={},follow=newproxy(),body=newproxy(),published=false}
    local s={time={},input={},skater={},level={},storage={},json={},menu={},entities={},world={physics={}}}
    function s.time.now()
        local value=f.now;table.insert(f.trace,"clock")
        if f.jump then f.now+=f.jump;f.jump=nil end -- a slow step between two clock reads
        return value
    end
    function s.json.encode() return "constructed bounded storage DTO" end
    function s.storage.get() return nil end
    function s.storage.set() end
    local P=s.world.physics
    function P.reserve_follow(_,attachment)
        f.attachment=attachment;f.reserve_called_at=f.now;table.insert(f.trace,"reserve")
        f.renewable=attachment.lifetime=="renewable"
        f.deadline=f.now+3000;f.ceiling=f.now+(f.renewable and 120000 or 3000)
        f.now+=f.reserve_delay
        return f.follow,nil
    end
    function P.read_follow()
        f.reads+=1;table.insert(f.trace,"read")
        local following=f.published
        return {phase=f.receipt_phase or (following and "following" or "reserved"),reason="none",park_reason="none",
            sequence="7",final_revision=following and "1" or "0",final_native_epoch=following and "5" or "0",
            returned_revision=following and "1" or "0",pending={},in_flight=0,claim_known=true,orphaned=false,
            park_observed=false,native_retirement_known=false,terminal=false}
    end
    function P.publish_follow() f.publishes+=1;f.published=true;return true end
    function P.read()
        f.body_reads+=1;table.insert(f.trace,"body")
        f.epoch=newproxy() -- Each read issues the body's newest sample.
        if f.body_delay then f.now+=f.body_delay end
        if f.body_jump then f.jump=f.body_jump end
        return {serial=tostring(f.body_reads+1),epoch=f.epoch}
    end
    function P.stop_follow() f.stops+=1;return true end
    function P.acknowledge_follow() return true end
    function P.release() return true end
    function f.accept()
        if not f.renewable then return false,"not_renewable" end
        if f.now>=f.deadline then return false,"expired" end
        if f.deadline>=f.ceiling then return false,"lifetime_exhausted" end
        f.deadline=math.max(f.deadline,math.min(f.now+500,f.ceiling));f.accepted+=1
        return true,f.deadline-f.now
    end
    function f.row()
        local remaining=math.max(0,f.deadline-f.now)
        return {sequence="7",renewable=f.renewable,active=remaining>0,renewals=tostring(f.accepted),
            last_serial=f.accepted==0 and "0" or "41",remaining_ms=remaining,
            lifetime_remaining_ms=f.renewable and math.max(0,f.ceiling-f.now) or remaining,base_ms=3000,
            renewal_ms=500,lifetime_ms=f.renewable and 120000 or 3000,revocation="none",dispatch_busy="0"}
    end
    if options.lease~=false then
        function P.read_follow_lease()
            if not f.permitted then error(PERMISSION,0) end
            f.lease_calls+=1;table.insert(f.trace,"lease")
            if options.lease then return options.lease(f) end
            return f.row()
        end
    end
    if options.renew~=false then
        -- The binding's order: permission, arity, owner and body of the epoch, quota, backend.
        function P.renew_follow(...)
            if not f.permitted then f.raised+=1;error(PERMISSION,0) end
            if select("#",...)~=2 then f.probes+=1;table.insert(f.trace,"probe");error(ARITY,0) end
            local handle,epoch=...
            if handle~=f.follow or typeof(epoch)~="userdata" then f.raised+=1;error(FOREIGN,0) end
            if f.tick_renews>=1 then return false,"asked to renew follow more than once in one tick" end
            f.tick_renews+=1;f.renews+=1;f.renew_epoch=epoch;f.renew_called_at=f.now;table.insert(f.trace,"renew")
            if f.renew_delay then f.now+=f.renew_delay end
            if options.renew then return options.renew(f) end
            return f.accept()
        end
    end
    local state={phase="spawning",detail="constructed spawned owner",generation=1,cancel_version=1,calls={},counts={},
        receipts={},omitted_calls=0,omitted_receipts=0,remove_attempted={},remove_accepted={},used=true,
        ledger_owned=true,spawn_requested=true,input_current=true,slot=0}
    local core=module.new(s,{qualification_only=true},state)
    local original=Spawn.new
    Spawn.new=function() return fake_spawn(f) end
    local ok,bound=pcall(core.prepare_backend,core)
    Spawn.new=original
    assert(ok and bound==true,"constructed backend binds the stand-in spawn owner")
    function f.tick(at)
        if at then assert(at>=f.now,"fixture time is monotonic");f.now=at end
        f.tick_renews=0 -- The SDK's renewal quota resets on the plugin tick.
        local before={reads=f.reads,lease=f.lease_calls,body=f.body_reads,renew=f.renews,visuals=f.visuals}
        local out=core:step(16)
        return out,{reads=f.reads-before.reads,lease=f.lease_calls-before.lease,body=f.body_reads-before.body,
            renew=f.renews-before.renew,visuals=f.visuals-before.visuals}
    end
    return f,core,state
end
local function fields(t) local n=0 for _ in pairs(t) do n+=1 end return n end
local function at(trace,name) for index,value in ipairs(trace) do if value==name then return index end end end
local function last(trace,name) local found for index,value in ipairs(trace) do if value==name then found=index end end return found end

function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,run) cases+=1;run(name) end
    local outcome=Core.renewal_outcome
    local function packed(...) return table.pack(true,...) end

    -- Pure policy against S2's renew_follow results.
    case("an accepted renewal",function()
        local until_ms,verdict,why=outcome(13000,12700,packed(true,500))
        check(until_ms==13200 and verdict=="renewed" and why=="renewed","remaining time from the pre-call clock moves the deadline later")
        until_ms,verdict,why=outcome(13000,12000,packed(true,300))
        check(until_ms==12300 and verdict=="renewed" and why=="renewed_earlier","a renewal that reports less time moves it earlier")
        until_ms,verdict=outcome(13000,10000,packed(true,120000))
        check(until_ms==130000 and verdict=="renewed","the ceiling itself is a valid remaining time")
    end)
    case("refusals are the lease source's facts",function()
        local expected={expired="stop",not_following="stop",client_not_ready="stop",focus_lost="stop",menu_open="stop",
            pause_menu_open="stop",debug_control="stop",actor_state="stop",not_renewable="off",lifetime_exhausted="off",
            busy="wait",sample_not_advanced="wait",sample_stale="wait",body_unavailable="wait",
            ["asked to renew follow more than once in one tick"]="wait",["follow renewal returned invalid observations"]="wait",
            some_later_refusal="wait"}
        for name,verdict in pairs(expected) do
            local until_ms,got,why=outcome(13000,12700,packed(false,name))
            check(until_ms==13000 and got==verdict and why==name,"refusal "..name.." is "..verdict.." and moves nothing")
        end
    end)
    case("raised and malformed renewals extend nothing",function()
        local until_ms,verdict=outcome(13000,12700,table.pack(false,FOREIGN))
        check(until_ms==13000 and verdict=="off","a raise ends renewal; the lease runs down")
        for _,r in {packed(true,0),packed(true,120001),packed(true,499.5),packed(true,0/0),packed(true,math.huge),
            packed(true,"500"),packed(true),packed(true,500,"extra"),packed(false),packed(false,""),packed(false,string.rep("x",201)),
            packed(nil,"busy"),packed("yes",500),packed(false,"busy","extra")} do
            local u,v,why=outcome(13000,12700,r)
            check(u==13000 and v=="wait" and why=="renewal returned malformed results","a malformed result waits and moves nothing")
        end
        local u,v,why=outcome(13000,nil,packed(true,500))
        check(u==13000 and v=="wait" and why=="renewal_state_invalid","no pre-call clock, no anchor")
        u,v=outcome(nil,12700,packed(true,500))
        check(u==nil and v=="wait","no lease source, nothing to refine")
        u,v,why=outcome(13000,9007199254740000,packed(true,5000))
        check(u==13000 and v=="wait" and why=="lease_clock_invalid","an overflowing deadline is not used")
    end)
    case("the renewal budget",function()
        local limits=Trial.ride_limits
        check(limits.renewals_per_tick==1 and limits.sdk_renewals_per_tick==1 and limits.follow_renewal_qualified==true
            and Core.ride_limits.follow_renewal_qualified==false,"one renewal a tick, under S2's one; only the trial is qualified")
        check(Core.renew_admitted(0) and not Core.renew_admitted(1) and not Core.renew_admitted(-1)
            and not Core.renew_admitted(0.5) and not Core.renew_admitted(nil),"a second renewal in a tick is refused before the SDK")
        for key,value in pairs(Core.ride_limits) do
            if key~="follow_renewal_qualified" then check(limits[key]==value,"the trial copy changes no other limit: "..key) end
        end
    end)

    -- The tracked Core, with renew_follow and its permission present.
    case("the tracked literal keeps the fixed lease",function()
        local f,_,state=fixture(Core,{reserve_delay=2400})
        local out,n=f.tick()
        check(out.follow_renewal_qualified==false and out.lease_renewable==false and out.phase=="following",
            "the tracked Core reports renewal unqualified and publishes")
        check(f.attachment.lifetime==nil and fields(f.attachment)==4 and f.probes==0 and f.raised==0,
            "the same four-field fixed reserve, with no probe")
        check(n.reads==1 and n.lease==0 and n.body==0 and n.renew==0,"publish tick: the reservation read only")
        out,n=f.tick(12500)
        check(n.reads==1 and n.lease==1 and n.body==1 and n.renew==0 and out.follow_reads_this_tick==1
            and out.lease_reads_this_tick==1 and out.renewals_this_tick==0 and out.lease_renew_calls==0,
            "following tick: LUA-4's budget and no renewal")
        check(state.lease_until==13000 and out.lease_report_last=="unchanged","the fixed report leaves the seed")
        out=f.tick(12849)
        check(out.stop_reason==nil,"inside the seed less the margin")
        out=f.tick(12850)
        check(out.stop_reason=="ride window or Follow lease ended" and f.renews==0 and f.probes==0
            and out.call_counts["follow.renew"]==nil and out.call_counts["follow.renew_probe"]==nil,
            "the seed ends the ride exactly as before, and renew_follow is never called")
    end)

    -- The trial copy.
    case("the trial reserves a renewable lease after one probe",function()
        local f,_,state=fixture(Trial)
        local out,n=f.tick()
        check(out.follow_renewal_qualified==true and out.lease_renewable==true and out.phase=="following",
            "the trial reports a renewable reserve and publishes")
        check(f.attachment.lifetime=="renewable" and f.attachment.cleanup=="owned_body"
            and f.attachment.motion_policy=="callback_entry" and fields(f.attachment)==5,
            "only lifetime=renewable is added to the attachment")
        check(f.probes==1 and n.renew==0 and f.raised==0 and out.call_counts["follow.renew_probe"]==1,
            "one zero-argument probe and no renewal on the publish tick")
        check(at(f.trace,"probe")<at(f.trace,"reserve"),"the probe comes before the reserve")
        check(state.reserve_at==10000 and state.lease_until==13000,"the same three-second seed")
        out,n=f.tick(10100)
        check(f.probes==1 and n.renew==1,"the probe is not repeated")
    end)
    case("an accepted renewal extends the deadline",function()
        local f,_,state=fixture(Trial,{reserve_delay=2400})
        f.tick()
        check(state.publish_at==12400 and state.lease_until==13000,"published late in the seed")
        local expected={{12500,13000},{12600,13100},{12700,13200},{12860,13360}}
        for _,step in ipairs(expected) do
            local out,n=f.tick(step[1])
            check(out.stop_reason==nil and n.reads==1 and n.lease==1 and n.body==1 and n.renew==1 and n.visuals==1,
                "following tick at "..step[1].." keeps the budget plus one renewal")
            check(state.lease_until==step[2] and f.deadline==step[2],"the deadline follows the accepted renewal")
            check(f.renew_epoch==f.epoch and last(f.trace,"body")<last(f.trace,"renew"),"renewed with this tick's body read epoch")
        end
        local out=f.tick(12890)
        check(out.stop_reason==nil and state.lease_renew_accepted==5 and out.lease_renew_accepted==5,
            "past the seed less the margin, where the fixed lease stops, the ride goes on")
        out=f.tick(12900)
        check(out.stop_reason=="ride window or Follow lease ended" and f.renews==5,
            "the tracked RIDE_WINDOW_MS still ends the ride, before any renewal that tick")
        local g=fixture(Core,{reserve_delay=2400})
        g.tick()
        g.tick(12500);g.tick(12600);g.tick(12700)
        out=g.tick(12860)
        check(out.stop_reason=="ride window or Follow lease ended","the same ticks on the tracked Core stop at the seed")
    end)
    case("the renewal is anchored to the clock read before the call",function()
        local f,_,state=fixture(Trial,{reserve_delay=2400})
        f.tick()
        f.renew_delay=40
        f.tick(12700)
        check(f.deadline==13240 and state.lease_until==13200,"call time only shortens the deadline Core holds")
        local renew=last(f.trace,"renew")
        check(f.trace[renew-1]=="clock" and f.trace[renew+1]=="clock","a clock read comes just before and after the renewal")
        check(f.renew_called_at==12700,"the renewal is made at the pre-call clock")
    end)
    case("a report alone never moves the deadline later",function()
        -- Constructed: the native lease accepts but Core is told busy, so later
        -- reports show renewals Core never saw accepted.
        local f,_,state=fixture(Trial,{reserve_delay=2400,renew=function(f) f.accept();return false,"busy" end})
        f.tick()
        f.tick(12500);f.tick(12600)
        local out=f.tick(12700)
        check(f.deadline==13200 and state.lease_until==13000 and state.lease_renewals=="2" and out.lease_report_last=="renewed",
            "a report with more renewals adopts the count, not a later deadline")
        out=f.tick(12850)
        check(out.stop_reason=="ride window or Follow lease ended","the unrenewed seed still ends the ride")
    end)
    for _,why in {"busy","sample_not_advanced","sample_stale","body_unavailable","asked to renew follow more than once in one tick",
        "follow renewal returned invalid observations","some_later_refusal"} do
        case("refusal "..why.." waits for the next tick",function()
            local f,_,state=fixture(Trial,{reserve_delay=2400,renew=function(f)
                if f.renews==1 then return false,why end
                return f.accept()
            end})
            f.tick()
            local out,n=f.tick(12600)
            check(out.stop_reason==nil and n.renew==1 and n.visuals==1 and state.lease_until==13000
                and out.lease_renew_last==why and not out.lease_renew_off,"the ride goes on, the deadline does not move")
            out,n=f.tick(12700)
            check(out.stop_reason==nil and n.renew==1 and state.lease_until==13200,"the next tick renews again and is accepted")
        end)
    end
    for _,why in {"expired","not_following","client_not_ready","focus_lost","menu_open","pause_menu_open","debug_control","actor_state"} do
        case("refusal "..why.." stops the ride",function()
            local f,_,state=fixture(Trial,{reserve_delay=2400,renew=function() return false,why end})
            f.tick()
            local out,n=f.tick(12600)
            check(out.stop_reason=="Follow renewal refused: "..why and n.renew==1 and n.visuals==0 and f.stops==1
                and state.lease_until==13000,"the stop comes at once: no visual update, the native Follow is stopped once")
            for tick=1,4 do out,n=f.tick(12600+tick*60) end
            check(f.renews==1 and out.lease_renew_calls==1,"no renewal follows the stop")
        end)
    end
    for _,why in {"lifetime_exhausted","not_renewable"} do
        case("refusal "..why.." ends renewal, not the ride",function()
            local f,_,state=fixture(Trial,{reserve_delay=2400,renew=function() return false,why end})
            f.tick()
            local out,n=f.tick(12500)
            check(out.stop_reason==nil and n.renew==1 and out.lease_renew_off==true and state.lease_until==13000,
                "the ride goes on unrenewed")
            out,n=f.tick(12600)
            check(out.stop_reason==nil and n.renew==0 and n.body==1,"no further renewal is asked for")
            out=f.tick(12850)
            check(out.stop_reason=="ride window or Follow lease ended" and f.renews==1,"the lease runs down as a fixed one")
        end)
    end
    case("a raised renewal ends renewal and keeps the lease",function()
        local f,_,state=fixture(Trial,{reserve_delay=2400,renew=function() error(FOREIGN,0) end})
        f.tick()
        local out,n=f.tick(12500)
        check(out.stop_reason==nil and n.renew==1 and out.lease_renew_off==true and state.lease_until==13000
            and out.lease_renew_last=="renewal raised; the lease runs down unrenewed","a raise is not a lease fact; it is not retried")
        out,n=f.tick(12600)
        check(n.renew==0 and out.stop_reason==nil,"no renewal after a raise")
    end)
    for index,result in {table.pack(true,0),table.pack(true,120001),table.pack(true,499.5),table.pack(true,"500"),
        table.pack(true),table.pack(true,500,"extra"),table.pack(false),table.pack(false,""),table.pack("yes",500)} do
        case("malformed renewal result "..index,function()
            -- The native lease accepts each time; only the first answer Core sees is malformed.
            local f,_,state=fixture(Trial,{reserve_delay=2400,renew=function(f)
                local ok,remaining=f.accept()
                if f.renews==1 then return table.unpack(result,1,result.n) end
                return ok,remaining
            end})
            f.tick()
            local out,n=f.tick(12600)
            check(out.stop_reason==nil and n.renew==1 and state.lease_until==13000 and not out.lease_renew_off
                and out.lease_renew_last=="renewal returned malformed results","a malformed result extends nothing")
            out=f.tick(12700)
            check(out.stop_reason==nil and state.lease_until==13200,"a later well-formed renewal is still accepted")
        end)
    end
    case("once per following tick",function()
        local f=fixture(Trial)
        f.tick()
        local out
        for tick=1,20 do
            local n
            out,n=f.tick(10000+tick*16)
            check(n.renew==1 and out.renewals_this_tick==1 and out.stop_reason==nil,"exactly one renewal on following tick "..tick)
        end
        check(f.renews==20 and out.lease_renew_calls==20 and out.call_counts["follow.renew"]==20
            and out.lease_renew_last=="renewed","no tick asks twice, so the SDK quota never refuses")
    end)
    case("renewal never follows a stop",function()
        local f=fixture(Trial)
        f.tick()
        f.receipt_phase="stopping"
        local out,n=f.tick(10100)
        check(out.stop_reason=="native follow is no longer following" and n.body==0 and n.renew==0,
            "a stopping receipt stops before the body read and the renewal")
        f=fixture(Trial,{lease=function() return {sequence="7",renewable=true,active=false,renewals="0",last_serial="0",
            remaining_ms=0,lifetime_remaining_ms=0,base_ms=3000,renewal_ms=500,lifetime_ms=120000,revocation="focus_lost",
            dispatch_busy="0"} end})
        f.tick()
        out,n=f.tick(10100)
        check(out.stop_reason=="Follow lease revoked: focus_lost" and n.body==0 and n.renew==0,"a revoked report stops first")
        f=fixture(Trial)
        f.tick()
        f.body_delay=500
        out,n=f.tick(10016)
        check(out.stop_reason=="ride window or Follow lease ended during body read" and n.body==1 and n.renew==0,
            "a body read that crosses the window is not followed by a renewal")
        f=fixture(Trial,{reserve_delay=2400})
        f.tick()
        f.body_jump=150
        out,n=f.tick(12700)
        check(out.stop_reason=="ride window or Follow lease ended before renewal" and n.renew==0,
            "a lease Core holds ended at the renewal's own clock read is stopped, not renewed")
        local core
        f,core=fixture(Trial)
        f.tick()
        f.tick(10100)
        check(core:request_stop("constructed stop"),"an explicit stop is accepted")
        for tick=1,5 do out,n=f.tick(10100+tick*60);check(n.renew==0,"no renewal while stopping") end
        check(f.renews==1,"only the renewal before the stop was made")
    end)
    case("a missing permission behaves as today",function()
        local f,_,state=fixture(Trial,{permitted=false,reserve_delay=2400})
        local out,n=f.tick()
        check(f.attachment.lifetime==nil and fields(f.attachment)==4 and out.lease_renewable==false and f.raised==1
            and out.lease_renew_last=="fixed lease: "..PERMISSION,"the refused probe keeps the fixed reserve")
        out,n=f.tick(12500)
        check(n.reads==1 and n.body==1 and n.renew==0 and out.lease_report_refused and state.lease_until==13000
            and f.raised==1,"the report raises as for the tracked Core, and renew_follow is not called again")
        out=f.tick(12850)
        check(out.stop_reason=="ride window or Follow lease ended","the seed ends the ride as before")
        local g=fixture(Core,{permitted=false,reserve_delay=2400})
        g.tick();g.tick(12500)
        out=g.tick(12850)
        check(out.stop_reason=="ride window or Follow lease ended" and g.raised==0,"the tracked Core ends the same way")
    end)
    case("renew_follow absent behaves as today",function()
        local f,_,state=fixture(Trial,{renew=false,reserve_delay=2400})
        local out=f.tick()
        check(f.attachment.lifetime==nil and fields(f.attachment)==4 and out.lease_renewable==false
            and out.lease_renew_last=="renew_follow absent; fixed lease" and out.call_counts["follow.renew_probe"]==nil,
            "an SDK without renew_follow is not probed and gets the fixed reserve")
        local n
        out,n=f.tick(12500)
        check(n.reads==1 and n.lease==1 and n.body==1 and state.lease_until==13000 and out.lease_report_last=="unchanged",
            "the fixed lease report, read as before")
        out=f.tick(12850)
        check(out.stop_reason=="ride window or Follow lease ended","the seed ends the ride")
    end)
    return {cases=cases,assertions=assertions,native_actions=0}
end

return table.freeze(Tests)

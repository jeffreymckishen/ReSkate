-- Actual Core and lease_source over constructed SDK services, with a stand-in
-- Spawn owner. The service setup follows core_ride_mode_tests so public Source
-- authorization runs too. No Host, native sleep, body lifetime or game proof.
local Core=require("./bike_runtime_core")
local Spawn=require("./bike_spawn")
local Tests={}
local REFUSAL="body snapshot or native epoch changed; no sample published"
local axes={"left_x","left_y","right_x","right_y","left_trigger","right_trigger"}
local buttons={"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"}
local function frame()
    local pad={playstation=false,buttons={}}
    for _,key in ipairs(axes) do pad[key]=0 end
    for _,key in ipairs(buttons) do pad.buttons[key]=false end
    return {input_ok=true,sample={user=0,pad=pad}}
end
local function source_fixture(options)
    options=options or {}
    local f={now=1000,slot=options.slot or 0,serial=5,renewals=0,reserves=0,publishes=0,follow_reads=0,
        body_reads=0,stops=0,spawn_requests=0,visuals=0,published=false,follow=newproxy(),body=newproxy()}
    f.pad=frame().sample.pad
    -- The SDK's sample.neutral, or nil for a runtime without it (Core stays exact zero).
    f.neutral=options.neutral
    local s={time={},input={},skater={},level={},storage={},json={},menu={},entities={},world={physics={}}}
    local function forbidden(name) return function() error(name.." must not be reached",0) end end
    function s.time.now() return f.now end
    -- Closed menus, focused gameplay, an upright, grounded on-foot (504) rider.
    function s.input.focus() return {focused=f.focused~=false,interface_open=false,gameplay=true} end
    function s.input.allowed() return true end
    function s.menu.game() return {open=false} end
    function s.skater.get() return {airborne=false,position=vector.create(0,0,0),heading=0} end
    function s.skater.telemetry() return {skater=true,airborne=false,teleport_pending=false,
        watch={valid=true,state=504,ragdoll_known=true,ragdoll=false,wipeouts=0}} end
    function s.level.current() return {name="sanvan"} end
    function s.json.encode() return "bounded constructed encoding" end
    function s.storage.get() return nil end
    function s.storage.set() end
    for _,name in {"pulse","pulse_state","pulse_cancel","pulse_acknowledge"} do s.input[name]=forbidden("input."..name) end
    for _,name in {"probe_batch","submit","receipt","acknowledge"} do s.world.physics[name]=forbidden(name) end
    -- One selected stream. Each pad change is a new observation, as Source requires.
    local function stream(row)
        row.transport,row.source_identity,row.physical_device_identity="xinput","observed_stream","unobserved"
        row.user,row.sequence,row.source_epoch,row.context_generation=f.user,"11",f.source_epoch or "12","13"
        return row
    end
    function s.input.lease(user)
        if f.lease then return nil,"busy" end
        f.user,f.lease,f.lease_status=user,newproxy(),"active"
        return f.lease
    end
    function s.input.lease_read(handle)
        if handle~=f.lease or f.lease_status~="active" then return nil,"unavailable" end
        local row=stream({mode="observe",capturing=false,report_debt=false,observation_serial=tostring(f.serial),
            observed_ms=tostring(2000+f.serial),packet=f.serial,pad=f.pad,neutral=f.neutral})
        row.epoch=newproxy()
        return row
    end
    function s.input.lease_renew(handle)
        if handle~=f.lease then return false,"stale_epoch" end
        f.renewals+=1
        return true
    end
    function s.input.lease_state(handle)
        if handle~=f.lease then return nil,"unavailable" end
        local terminal=f.lease_status~="active"
        local reserved=f.capture~=nil and not f.capture_acked
        return stream({mode="observe",capturing=false,report_debt=false,status=f.lease_status,
            reason=terminal and "cancelled" or "none",terminal=terminal,requested_ms="1000",expires_ms="900000",
            observed_ms=tostring(2000+f.serial),last_observation=tostring(f.serial),renewals=tostring(f.renewals),
            source_released=terminal and not reserved,capture_reserved=reserved,orphaned=false})
    end
    function s.input.lease_release(handle)
        if handle~=f.lease or f.lease_status~="active" then return false,"unavailable" end
        f.lease_status="released"
        return true
    end
    function s.input.lease_acknowledge(handle)
        if handle~=f.lease or f.lease_status=="active" or (f.capture and not f.capture_acked) then return false,"busy" end
        return true
    end
    local function capture_row()
        local c=f.capture
        return stream({mode="capture",capture_scope="selected_observed_xinput_stream",
            publication_scope="process_outer_xinput_buffer",consumption="unobserved",semantic_completion="unobserved",
            capturing=c.phase=="capturing",report_debt=c.phase=="capturing",phase=c.phase,reason=c.reason,
            terminal=c.phase=="complete",quarantined=false,generation=c.generation,revision=c.revision,
            expires_ms="900000",publications=c.publications,neutral_releases=c.neutral_releases})
    end
    function s.input.lease_capture(handle)
        if handle~=f.lease or f.capture then return false,"busy" end
        f.capture={phase="waiting_neutral",reason="none",generation="21",revision="22",
            publications="0",neutral_releases="0",reads=0}
        return true
    end
    function s.input.lease_capture_state(handle)
        if handle~=f.lease or not f.capture then return nil,"unavailable" end
        local c=f.capture
        c.reads+=1
        -- Constructed: the second read reports the selected stream as captured.
        if c.phase=="waiting_neutral" and c.reads>1 then c.phase,c.publications="capturing","1" end
        return capture_row()
    end
    function s.input.lease_release_capture(handle)
        local c=f.capture
        if handle~=f.lease or not c or c.phase=="complete" then return false,"unavailable" end
        c.phase,c.reason,c.generation,c.revision,c.neutral_releases="complete","cancelled","23","24",c.publications
        return true
    end
    function s.input.lease_acknowledge_capture(handle)
        if handle~=f.lease or not f.capture or f.capture.phase~="complete" then return false,"busy" end
        f.capture_acked=true
        return true
    end
    local P=s.world.physics
    function P.reserve_follow() f.reserves+=1;return f.follow,nil end
    function P.read_follow()
        f.follow_reads+=1
        local following=f.published
        return {phase=f.follow_phase or (following and "following" or "reserved"),reason="none",park_reason="none",sequence="7",
            final_revision=following and "1" or "0",final_native_epoch=following and "5" or "0",
            returned_revision=following and "1" or "0",pending={},in_flight=0,claim_known=f.claim_known~=false,orphaned=f.orphaned==true,
            park_observed=f.park_observed==true,native_retirement_known=false,terminal=false}
    end
    function P.publish_follow() f.publishes+=1;f.published=true;return true end
    function P.read(handle)
        f.body_reads+=1
        if f.on_read then return f.on_read(handle) end
        return {serial=tostring(f.body_reads+1)}
    end
    function P.stop_follow() f.stops+=1;return true end
    function P.acknowledge_follow() return true end
    function P.release() return true end
    -- Spawn reports spawned after options.spawn_ticks updates.
    local owner={phase="armed",waits=options.spawn_ticks or 0}
    function owner:request() f.spawn_requests+=1;return true end
    function owner:update()
        if self.phase~="armed" then return end
        if self.waits>0 then self.waits-=1 else self.phase="spawned" end
    end
    function owner:status()
        return {phase=self.phase,cleanup_unknown=false,creation_unknown=false,body=false,visual_remove_requested=false}
    end
    function owner:handoff_follow() self.phase="follow_owned";return f.body,{serial="1"},nil end
    function owner:follow_visual() f.visuals+=1;return true end
    function owner:stop() self.phase="closed" end
    local state={phase="armed",detail="constructed armed owner",generation=1,cancel_version=1,calls={},counts={},
        receipts={},omitted_calls=0,omitted_receipts=0,remove_attempted={},remove_accepted={},used=true,
        ledger_owned=true,active=true,slot=f.slot,arm_at=f.now,level="sanvan",wipeouts=0}
    local core=Core.new(s,{qualification_only=true},state)
    local original=Spawn.new
    Spawn.new=function() return owner end
    local ok,bound=pcall(core.prepare_backend,core)
    Spawn.new=original
    assert(ok and bound==true,"constructed backend binds the real Source and the stand-in spawn owner")
    function f.step()
        f.now+=16
        local before=f.body_reads
        local out=core:step(16)
        return out,f.body_reads-before
    end
    -- Neutral ticks until Core reaches phase, or a stop.
    function f.until_phase(phase)
        local out=core:status()
        for _=1,200 do
            if out.phase==phase or out.stop_latched then break end
            out=f.step()
        end
        return out
    end
    -- neutral, when given, is the SDK's fact for the new pad; nil keeps the last one.
    function f.set_pad(edit,neutral)
        local pad=table.clone(f.pad);pad.buttons=table.clone(f.pad.buttons)
        edit(pad);f.pad=pad;f.serial+=1
        if neutral~=nil then f.neutral=neutral end
    end
    f.core,f.state=core,state
    return f,core,state
end


function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,run) cases+=1;run(name) end
    local function following()
        local f=source_fixture()
        check(f.until_phase("following").phase=="following","real Source setup reaches one published Follow")
        check(f.reserves==1 and f.publishes==1 and f.body_reads==0,"publication tick observes no following body")
        return f
    end
    case("one exact refusal gets one guarded reread and no new owner",function()
        local f=following();local tries=0;local body=f.body;local visuals=f.visuals
        function f.on_read(handle)
            check(handle==body,"both reads use the original body")
            tries+=1
            if tries==1 then return nil,REFUSAL end
            return {serial="9"}
        end
        local s,reads=f.step()
        check(s.phase=="following" and not s.stop_latched and reads==2,"one same-tick reread recovers")
        check(s.body_read_retries==1 and s.body_read_recoveries==1 and s.body_read_retry_this_tick,"retry and recovery counted once")
        check(f.reserves==1 and f.publishes==1 and f.stops==0,"neither Follow nor body is replaced")
        check(f.visuals==visuals+1,"only the recovered table reaches the visual")
        f.on_read=nil;local before=f.body_reads;s,reads=f.step()
        check(reads==1 and f.body_reads==before+1 and not s.body_read_retry_this_tick,"ordinary next tick has its normal one read")
        check(s.body_read_retries==1 and s.body_read_recoveries==1,"ordinary read does not inflate recovery counts")
    end)
    case("a second identical refusal is terminal without a third call",function()
        local f=following();local visuals=f.visuals
        f.on_read=function() return nil,REFUSAL end
        local s,reads=f.step()
        check(s.stop_latched and reads==2 and s.body_read_retries==1 and s.body_read_recoveries==0,"two refusals end the ride")
        check(f.visuals==visuals and f.reserves==1 and f.publishes==1,"no stale sample drawn or Follow re-reserved")
    end)
    case("other errors, exceptions and wrong return shapes never retry",function()
        local rows={
            function() return nil,"different native failure" end,
            function() return nil,REFUSAL.." " end,
            function() return false,REFUSAL end,
            function() return nil,REFUSAL,"extra" end,
            function() error(REFUSAL,0) end,
            function() return nil end,
        }
        for _,read in ipairs(rows) do
            local f=following();f.on_read=read
            local s,reads=f.step()
            check(s.stop_latched and reads==1 and s.body_read_retries==0 and s.body_read_recoveries==0,"only the exact nil/reason pair is retryable")
        end
    end)
    case("cancellation, owner replacement and expired window fence retry",function()
        local rows={
            function(f) f.core:request_stop("cancelled during first body read") end,
            function(f) f.state.body=newproxy() end,
            function(f) f.state.follow=newproxy() end,
            function(f) f.state.generation+=1 end,
            function(f) f.state.active=false end,
            function(f) f.now+=1000 end,
        }
        for _,change in ipairs(rows) do
            local f=following()
            f.on_read=function() change(f);return nil,REFUSAL end
            local s,reads=f.step()
            check(s.stop_latched and reads==1 and s.body_read_retries==0,"lost current owner or lease cannot reread")
        end
    end)
    case("fresh readiness and Source identity must still authorize",function()
        local rows={
            function(f) f.focused=false end,
            function(f) f.source_epoch="99" end,
            function(f) f.lease_status="released" end,
        }
        for _,change in ipairs(rows) do
            local f=following();f.on_read=function() change(f);return nil,REFUSAL end
            local s,reads=f.step()
            check(s.stop_latched and reads==1 and s.body_read_retries==0,"fresh readiness or Source refusal suppresses retry")
        end
    end)
    case("fresh Follow receipt must still report a live claim",function()
        local rows={
            function(f) f.follow_phase="stopping" end,
            function(f) f.follow_phase="retained" end,
            function(f) f.orphaned=true end,
            function(f) f.claim_known=false end,
            function(f) f.park_observed=true end,
        }
        for _,change in ipairs(rows) do
            local f=following();f.on_read=function() change(f);return nil,REFUSAL end
            local s,reads=f.step()
            check(s.stop_latched and reads==1 and s.body_read_retries==0,"stopped, orphaned, unclaimed or parked Follow cannot revive")
        end
    end)
    case("a successful table after callback ownership loss is not recovery",function()
        for _,change in ipairs({
            function(f) f.core:request_stop("cancelled in reread") end,
            function(f) f.state.body=newproxy() end,
            function(f) f.now+=1000 end,
        }) do
            local f=following();local tries=0;local visuals=f.visuals
            f.on_read=function()
                tries+=1;if tries==1 then return nil,REFUSAL end
                change(f);return {serial="9"}
            end
            local s,reads=f.step()
            check(s.stop_latched and reads==2 and s.body_read_retries==1 and s.body_read_recoveries==0,"late table cannot recover lost ownership")
            check(f.visuals==visuals,"unowned reread does not reach visuals")
        end
    end)
    case("only recovery grants one extra bounded Follow read",function()
        local limits=Core.ride_limits
        check(limits.follow_reads_per_tick==6 and limits.follow_recovery_reads_per_tick==7
            and limits.sdk_follow_reads_per_tick==8,"normal and recovery limits leave one SDK read for cleanup")
        for reads=0,5 do check(Core.follow_read_admitted(reads,0,false),"normal call before six") end
        check(not Core.follow_read_admitted(6,0,false) and not Core.follow_read_admitted(6,0,false,false),"ordinary cap remains six")
        check(Core.follow_read_admitted(6,0,false,true) and not Core.follow_read_admitted(7,0,false,true),"recovery cap is exactly seven")
        check(Core.follow_read_admitted(7,limits.cleanup_reads-1,true,true)
            and not Core.follow_read_admitted(7,limits.cleanup_reads,true,true),"cleanup keeps its separate lifetime cap")
        check(not Core.follow_read_admitted(0/0,0,false,true) and not Core.follow_read_admitted(-1,0,false,true),"malformed recovery counter refused")
    end)
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return Tests

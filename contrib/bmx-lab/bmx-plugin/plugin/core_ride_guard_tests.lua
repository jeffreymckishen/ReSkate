-- Actual private Core owner guards through qualified Core, Ride, Source and
-- restricted adapters over constructed SDK services. Only the runner copy
-- opens composition and binds its separately qualified Ride; production gates
-- stay closed. No Host, native effect, wall-clock timing or game qualification.
local Core=require("./bike_runtime_core_ride_guard_fixture")
local Production=require("./bike_runtime_core")
local Spawn=require("./bike_spawn")
local G=require("./bike_geometry")
local M=require("./force_math")
local Tests={}
local axes={"left_x","left_y","right_x","right_y","left_trigger","right_trigger"}
local buttons={"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"}
local function frame()
    local pad={playstation=false,buttons={}}
    for _,key in ipairs(axes) do pad[key]=0 end
    for _,key in ipairs(buttons) do pad.buttons[key]=false end
    return {input_ok=true,sample={user=0,pad=pad}}
end
local function v(a) return vector.create(a[1],a[2],a[3]) end
local function fixture(options)
    options=options or {}
    local f={now=1000,slot=options.slot or 0,serial=5,renewals=0,reserves=0,publishes=0,follow_reads=0,
        body_reads=0,stops=0,spawn_requests=0,visuals=0,published=false,follow=newproxy(),body=newproxy(),trace={},packets={},transactions={}}
    f.pad=frame().sample.pad
    -- The SDK's sample.neutral, or nil for a runtime without it (Core stays exact zero).
    f.neutral=options.neutral
    local s={time={},input={},skater={},level={},storage={},json={},menu={},entities={},world={physics={}}}
    local function forbidden(name) return function() error(name.." must not be reached",0) end end
    function s.time.now() if f.bad_clock then f.bad_clock=false;return nil end;return f.now end
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
    -- Probe and force calls below use constructed SDK transactions.
    -- One selected stream. Each pad change is a new observation, as Source requires.
    local function stream(row)
        row.transport,row.source_identity,row.physical_device_identity="xinput","observed_stream","unobserved"
        row.user,row.sequence,row.source_epoch,row.context_generation=f.user,"11","12","13"
        return row
    end
    function s.input.lease(user)
        if f.lease then return nil,"busy" end
        f.user,f.lease,f.lease_status=user,newproxy(),"active"
        return f.lease
    end
    function s.input.lease_read(handle)
        if handle~=f.lease or f.lease_status~="active" or f.refuse_read then return nil,"unavailable" end
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
        if handle~=f.lease or f.refuse_lease then return nil,"unavailable" end
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
        if handle~=f.lease or not f.capture or f.refuse_capture then return nil,"unavailable" end
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
    function P.prepare() return true end
    function P.reserve_follow() f.reserves+=1;return f.follow,nil end
    function P.read_follow()
        f.follow_reads+=1
        local following=f.published
        return {phase=following and "following" or "reserved",reason="none",park_reason="none",sequence="7",
            final_revision=following and "1" or "0",final_native_epoch=following and "5" or "0",
            returned_revision=following and "1" or "0",pending={},in_flight=0,claim_known=true,orphaned=false,
            park_observed=false,native_retirement_known=false,terminal=false}
    end
    function P.publish_follow() f.publishes+=1;f.published=true;return true end
    function P.read(body)
        assert(body==f.body,"Core reads its original body")
        f.body_reads+=1
        f.read={epoch=newproxy(),serial=tostring(f.body_reads+1),time=f.body_reads/60,seconds=1/60,
            position=vector.create(0,1,0),rotation={0,0,0,1},mass=G.mass,
            velocity=vector.create(0,0,0),angular_velocity=vector.create(0,0,0),inertia=v(G.inertia)}
        return f.read
    end
    function P.probe_batch(body,epoch,rays,settings)
        assert(body==f.body and epoch==f.read.epoch and #rays==2 and settings.require_contact
            and settings.exclude_local_actor,"actual Ride supplies its measured body and two qualified wheel rays")
        if f.after_probe then f.after_probe(f) end
        return {status="available",epoch=epoch,native_casts=2,budget_exhausted=false,
            local_actor_excluded=true,owned_bodies_excluded=true,rays={{status="clear"},{status="clear"}}}
    end
    function P.submit(body,epoch,command)
        assert(body==f.body and epoch==f.read.epoch and typeof(command.force)=="vector"
            and typeof(command.torque)=="vector","actual Ride submits against the same measured sample")
        local sequence=tostring(#f.packets+1)
        f.transactions[sequence]={requested=f.read.serial,produced=tostring(tonumber(f.read.serial)+1)}
        f.packets[#f.packets+1]={sequence=sequence,command=command,body=body,epoch=epoch}
        if f.after_submit then f.after_submit(f) end
        return true,nil,sequence
    end
    function P.receipt(body,sequence)
        assert(body==f.body and f.transactions[sequence],"receipt polling retains the original accepted owner and sequence")
        local row=f.transactions[sequence]
        return {sequence=sequence,requested_serial=row.requested,produced_serial=row.produced,
            outcome="applied",force_attempted=true,torque_attempted=true,retained=false,quarantined=false,
            cleanup_disposition="none"}
    end
    function P.acknowledge() error("a receipt without a successor must not be acknowledged",0) end
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
    f.state,f.sdk=state,s
    local function wrap(t,prefix)
        for key,value in pairs(t) do
            if type(value)=="table" then wrap(value,prefix..key..".")
            elseif type(value)=="function" then
                local name=prefix..key
                t[key]=function(...)
                    f.trace[#f.trace+1]=name
                    return value(...)
                end
            end
        end
    end
    wrap(s,"")
    local core=Core.new(s,{qualification_only=true},state)
    f.core=core
    local original=Spawn.new
    Spawn.new=function() return owner end
    local ok,bound=pcall(core.prepare_backend,core)
    Spawn.new=original
    assert(ok and bound==true,"constructed backend binds the real Source and the stand-in spawn owner")
    function f.step()
        f.now+=16;f.serial+=1;table.clear(f.trace)
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
    return f,core,state
end

local function count(trace,name)
    local n=0
    for _,entry in ipairs(trace) do if entry==name then n+=1 end end
    return n
end
local function at(trace,name,last)
    local found
    for i,entry in ipairs(trace) do
        if entry==name then found=i;if not last then break end end
    end
    return found
end
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,run) cases+=1;run();return name end
    local function start()
        local f,core,state=fixture()
        local out=f.until_phase("following")
        check(out.phase=="following" and out.ride_composition_qualified,"test-only Core reaches active composition")
        for _=1,10 do
            if #f.packets>0 or out.stop_latched then break end
            out=f.step()
        end
        check(not out.stop_latched and #f.packets==1 and out.ride and out.ride.activation_qualified
            and out.ride.submitted==1,"actual qualified Ride admits a packet through private Core guards")
        return f,core,state,out
    end
    case("actual active Core guard call trace has no diagnostic reads",function()
        local f,_,_,out=start()
        local tracked=Production.new({},{}):status()
        check(tracked.ride_composition_qualified==false,"the tracked Core gate remains closed")
        local p,s=at(f.trace,"world.physics.probe_batch"),at(f.trace,"world.physics.submit")
        local expected={"time.now","world.physics.read_follow","time.now","world.physics.probe_batch",
            "time.now","time.now","time.now","input.focus","input.allowed","menu.game","skater.get",
            "skater.telemetry","level.current","world.physics.read_follow","input.lease_read","input.lease_state",
            "input.lease_capture_state","time.now","world.physics.submit","time.now","time.now"}
        check(p and s and s+2-(p-3)+1==#expected,"guarded contact and submit have the exact bounded trace length")
        for i,name in ipairs(expected) do check(f.trace[p-4+i]==name,"active guard SDK trace "..i.." is "..name) end
        check(count(f.trace,"world.physics.read_follow")==3 and count(f.trace,"input.focus")==2
            and count(f.trace,"input.lease_read")==2 and count(f.trace,"input.lease_state")==2
            and count(f.trace,"input.lease_capture_state")==2,
            "one tick receipt, one per pre-guard, one start/fresh facts set and two Source read sets")
        check(out.ride.pending_count==1 and f.packets[1].sequence=="1",
            "healthy diagnostics leave one accepted exact force debt")
    end)
    local post_faults={
        {"owner",function(f) f.state.generation+=1 end},
        {"body",function(f) f.state.body=newproxy() end},
        {"follow",function(f) f.state.follow=newproxy() end},
        {"source identity",function(f) f.state.input_current=false end},
        {"phase",function(f) f.state.phase="spawning" end},
        {"receipt",function(f) local row=M.copy(f.state.receipt);row.claim_known=false;f.state.receipt=row end},
        {"lease",function(f) f.state.lease_until=f.now end},
    }
    for _,fault in ipairs(post_faults) do
        case("actual post-contact guard names "..fault[1],function()
            local f,core=start()
            f.after_probe=fault[2]
            local out=f.step()
            local why="Core guard changed during contact query: "..fault[1]
            check(out.stop_latched and out.stop_reason==why,"post-contact failure retains its exact first category: "..tostring(out.stop_reason))
            check(#f.packets==1 and count(f.trace,"world.physics.probe_batch")==1
                and count(f.trace,"world.physics.submit")==0,"failed post-contact guard sends no new force")
            core:request_stop("later unrelated cleanup diagnostic")
            check(core:status().stop_reason==why,"later cleanup cannot overwrite the first private guard refusal")
        end)
    end
    case("fresh readiness is named before force publication",function()
        local f=start()
        f.after_probe=function(row) row.focused=false end
        local out=f.step()
        check(out.stop_reason=="current Core Source/Follow/body/epoch force guard refused: readiness",
            "fresh focus loss is classified by the actual pre-submit owner guard")
        check(#f.packets==1 and count(f.trace,"input.focus")==2 and count(f.trace,"world.physics.submit")==0,
            "fresh readiness uses the existing second facts set and refuses before publication")
    end)
    for _,spec in ipairs({
        {"read","fresh selected input unavailable","input.lease_read",2,1,1},
        {"lease","fresh selected lease authority unavailable","input.lease_state",2,2,1},
        {"capture","fresh selected capture authority unavailable","input.lease_capture_state",2,2,2},
    }) do
        case("Source authorization retains "..spec[1].." refusal",function()
            local f=start()
            f.after_probe=function(row) row["refuse_"..spec[1]]=true end
            local out=f.step()
            check(out.stop_reason=="current Core Source/Follow/body/epoch force guard refused: source authorization: "..spec[2],
                "actual Source failure detail reaches the stopping guard: "..tostring(out.stop_reason))
            check(#f.packets==1 and count(f.trace,"world.physics.submit")==0,"authorization refusal sends no packet")
            -- Cleanup may read state again. Only the prefix ending at the
            -- refusal's required final clock belongs to the publication guard.
            local failed=at(f.trace,spec[3])
            for i=failed+1,#f.trace do if f.trace[i]==spec[3] then failed=i;break end end
            check(f.trace[failed+1]=="time.now","Source refusal still pays the existing second guard clock before cleanup")
            local prefix={}
            for i=1,failed+1 do prefix[i]=f.trace[i] end
            check(count(prefix,"input.lease_read")==spec[4] and count(prefix,"input.lease_state")==spec[5]
                and count(prefix,"input.lease_capture_state")==spec[6],
                "Source failure short-circuit does not repeat SDK reads for diagnostics")
        end)
    end
    case("clock failure retains its earlier native-independent cause",function()
        local f=start()
        f.after_probe=function(row) row.bad_clock=true end
        local out=f.step()
        check(out.stop_latched and out.stop_reason=="invalid or reversed Lua wall clock",
            "clock() keeps its already latched cause instead of replacing it with a guard category")
        check(#f.packets==1 and count(f.trace,"world.physics.submit")==0,"unknown clock cannot publish another force")
    end)
    case("post-publication owner failure preserves the accepted exact debt",function()
        local f,core=start()
        f.after_submit=function(row) row.state.body=newproxy() end
        local out=f.step()
        check(out.stop_reason=="Core guard changed during force publication: body",
            "post-publication cause is distinct from pre-publication refusal")
        check(#f.packets==2 and f.packets[2].sequence=="2" and f.packets[2].body==f.body,
            "second packet was accepted by the original body before the callback changed Core state")
        local retained=false
        for _,row in ipairs(out.ride.pending_commands) do if row.sequence=="2" then retained=true end end
        check(out.ride.submitted==2 and out.ride.force_pending and retained and not out.force_cleanup_clear,
            "post-effect guard cannot erase the accepted exact sequence or manufacture cleanup")
        core:request_stop("later stop")
        check(core:status().stop_reason==out.stop_reason,"post-effect first cause survives later stop calls")
        check(count(f.trace,"world.physics.submit")==1,"classification never retries the native publication")
    end)
    -- Private binding.observing/sample/epoch and in-flight admission are not
    -- externally writable capabilities. Their adapter protections remain in
    -- core_force_pipeline_tests; no test-only production bypass is exported.
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return Tests

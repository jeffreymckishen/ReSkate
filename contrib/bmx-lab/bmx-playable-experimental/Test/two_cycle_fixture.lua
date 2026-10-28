-- Constructed ten-API fixtures only. newproxy values are test identities, never
-- native handles, source authority, physical controllers or gameplay evidence.
-- Requiring this module performs no API calls. Main owns eventual execution.
local Source = require("./lease_source")
local Identity = require("./lease_identity")
local Core = require("./bike_runtime_core")

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, child in pairs(value) do out[key] = copy(child) end
    return out
end
local function increment(value)
    local digits, carry = {}, 1
    for at = #value, 1, -1 do
        local digit = string.byte(value, at) - 48 + carry
        if digit == 10 then digit, carry = 0, 1 else carry = 0 end
        table.insert(digits, 1, string.char(48 + digit))
    end
    if carry == 1 then table.insert(digits, 1, "1") end
    return table.concat(digits)
end
local names = {"lease","lease_read","lease_renew","lease_release","lease_state","lease_acknowledge",
    "lease_capture","lease_capture_state","lease_release_capture","lease_acknowledge_capture"}
local button_names = {"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"}
local function neutral()
    local pad = {left_x=0,left_y=0,right_x=0,right_y=0,left_trigger=0,right_trigger=0,playstation=false,buttons={}}
    for _, name in ipairs(button_names) do pad.buttons[name] = false end
    return pad
end
local function metadata(row, mode)
    row.transport, row.source_identity, row.physical_device_identity = "xinput", "observed_stream", "unobserved"
    row.mode, row.capturing, row.report_debt = mode or "observe", false, false
    return row
end
local function fixture(options)
    local f = {constructed=true,native_authority=false,now=1000,api={},calls={},issued={},renewed={},
        sequence="9007199254740995",source_epoch="9007199254741009",context="9007199254741011",
        serial="9007199254741001",native_ms="9007199254741000",packet=23,user=2,in_flight=false}
    local function call(name, ...)
        table.insert(f.calls, {name=name,args={...}})
        if f.on_call then f.on_call(name, ...) end
    end
    local function owns(handle) return handle ~= nil and handle == f.handle end
    local function sync()
        if not f.passive then return end
        local retained = f.capture and (not f.capture.terminal or f.in_flight)
        f.passive.capture_reserved = retained == true
        if f.passive.terminal then f.passive.source_released = not retained end
    end
    -- rest is the SDK's sample.neutral; leaving it nil models a runtime without it.
    function f.publish(pad, equal_ms, rest)
        f.serial = increment(f.serial)
        if not equal_ms then f.native_ms = increment(f.native_ms) end
        f.sample = metadata({sequence=f.sequence,source_epoch=f.source_epoch,context_generation=f.context,
            observation_serial=f.serial,observed_ms=f.native_ms,user=f.user,packet=f.packet,pad=copy(pad or neutral()),
            neutral=rest})
        if f.passive then
            f.passive.status, f.passive.observed_ms, f.passive.last_observation = "active", f.native_ms, f.serial
        end
    end
    function f.activate()
        assert(f.capture, "fixture needs an admitted capture before publication")
        f.capture.phase, f.capture.capturing, f.capture.report_debt = "capturing", true, true
        f.capture.publications = "1"
        sync()
    end
    function f.complete_capture()
        assert(f.capture, "fixture needs capture duty")
        f.capture.phase, f.capture.terminal, f.capture.capturing, f.capture.report_debt = "complete", true, false, false
        f.capture.quarantined = false
        f.capture.publications, f.capture.neutral_releases = increment(f.capture.publications), increment(f.capture.neutral_releases)
        f.capture.generation, f.capture.revision = increment(f.capture.generation), increment(f.capture.revision)
        sync()
    end
    f.api.lease = function(user)
        call("lease", user)
        if f.handle then return nil, "busy" end
        f.user, f.handle, f.sample = user, newproxy(), nil
        f.passive = metadata({sequence=f.sequence,source_epoch=f.source_epoch,context_generation=f.context,
            user=user,status="warming",reason="none",terminal=false,requested_ms="9007199254740997",
            expires_ms="9007199254741247",observed_ms="0",last_observation="0",renewals="0",
            source_released=false,capture_reserved=false,orphaned=false})
        return f.handle
    end
    f.api.lease_read = function(handle)
        call("lease_read", handle)
        if not owns(handle) or not f.sample or f.passive.terminal then return nil, "unavailable" end
        local row, epoch = copy(f.sample), newproxy()
        row.epoch = epoch
        f.issued[epoch] = copy(f.sample)
        return row
    end
    f.api.lease_renew = function(handle, epoch)
        call("lease_renew", handle, epoch)
        local sample = f.issued[epoch]
        if not owns(handle) or not sample or sample.observation_serial ~= f.sample.observation_serial or
            f.renewed[sample.observation_serial] then return false, "stale_epoch" end
        f.renewed[sample.observation_serial] = true
        f.passive.renewals = increment(f.passive.renewals)
        return true
    end
    f.api.lease_state = function(handle)
        call("lease_state", handle)
        if not owns(handle) or not f.passive then return nil, "unavailable" end
        sync()
        return copy(f.passive)
    end
    f.api.lease_release = function(handle)
        call("lease_release", handle)
        if not owns(handle) or not f.passive or f.passive.terminal then return false, "unavailable" end
        f.passive.status, f.passive.reason, f.passive.terminal = "released", "cancelled", true
        if f.capture and not f.capture.terminal then
            if f.capture.phase~="releasing" then
                f.capture.generation,f.capture.revision=increment(f.capture.generation),increment(f.capture.revision)
            end
            f.capture.phase, f.capture.capturing, f.capture.reason = "releasing", false, "cancelled"
            if not f.capture.report_debt then f.capture.phase, f.capture.terminal = "complete", true end
        end
        sync()
        return true
    end
    f.api.lease_acknowledge = function(handle)
        call("lease_acknowledge", handle)
        sync()
        if not owns(handle) or not f.passive or not f.passive.terminal or not f.passive.source_released or
            f.passive.capture_reserved then return false, "busy" end
        f.passive, f.handle, f.sample = nil, nil, nil
        return true
    end
    f.api.lease_capture = function(handle, epoch)
        call("lease_capture", handle, epoch)
        local sample = f.issued[epoch]
        if not owns(handle) or not sample or sample.observation_serial ~= f.sample.observation_serial then return false, "authority_lost" end
        if f.capture_refusal then return false, f.capture_refusal end
        if f.capture then return false, "busy" end
        f.capture = metadata({sequence=f.sequence,source_epoch=f.source_epoch,context_generation=f.context,user=f.user,
            phase="waiting_neutral",reason="none",terminal=false,quarantined=false,generation="9007199254741020",
            revision="9007199254741022",expires_ms="9007199254741247",publications="0",neutral_releases="0"}, "capture")
        f.capture.capture_scope, f.capture.publication_scope = "selected_observed_xinput_stream", "process_outer_xinput_buffer"
        f.capture.consumption, f.capture.semantic_completion = "unobserved", "unobserved"
        sync()
        return true
    end
    f.api.lease_capture_state = function(handle)
        call("lease_capture_state", handle)
        if not owns(handle) or not f.capture then return nil, "unavailable" end
        return copy(f.capture)
    end
    f.api.lease_release_capture = function(handle)
        call("lease_release_capture", handle)
        if not owns(handle) or not f.capture or f.capture.terminal then return false, "unavailable" end
        if f.capture.phase~="releasing" then
            f.capture.generation,f.capture.revision=increment(f.capture.generation),increment(f.capture.revision)
        end
        f.capture.reason, f.capture.capturing = "cancelled", false
        if f.capture.report_debt then f.capture.phase = "releasing"
        else f.capture.phase, f.capture.terminal = "complete", true end
        sync()
        return true
    end
    f.api.lease_acknowledge_capture = function(handle)
        call("lease_acknowledge_capture", handle)
        if not owns(handle) or not f.capture or not f.capture.terminal or f.capture.report_debt or
            f.capture.quarantined or f.in_flight then return false, "busy" end
        f.capture = nil
        sync()
        return true
    end
    f.source = Source.new(f.api, options)
    function f.step(gates)
        f.now += 1
        return f.source:step(f.now, gates or {allow_acquire=true,allow_drive=true})
    end
    function f.count(name)
        local count = 0
        for _, item in ipairs(f.calls) do if item.name == name then count += 1 end end
        return count
    end
    function f.start()
        assert(f.source:arm(f.user, f.now))
        f.step()
        f.publish(); f.step()
        assert(f.capture, "fixture expected one admitted key")
        f.activate(); f.publish()
        return f.step()
    end
    return f
end

-- Constructs SDK-shaped services and real Core sessions. Fake userdata and
-- seeded terminal Follow/pose facts are NOT native ownership or game evidence.
local function make(check,options)
    local f=fixture()
    f.stock=504;f.records={};f.saves={};f.pulse_number=0
    local R={time={},input=f.api,menu={},skater={},level={},storage={},json={},entities={},world={physics={}}}
    function R.time.now() return f.now end
    function R.input.focus() return {focused=true,interface_open=false,gameplay=true} end
    function R.input.allowed() return true end
    function R.menu.game() return {open=false} end
    function R.skater.get() return {airborne=false,position=vector.create(0,0,0),heading=0} end
    function R.skater.telemetry() return {skater=true,airborne=false,teleport_pending=false,
        watch={valid=true,state=f.stock,ragdoll_known=true,ragdoll=false,wipeouts=0}} end
    function R.level.current() return {name="constructed"} end
    function R.storage.get(k) return f.records[k] end
    function R.storage.set(k,v)
        if f.on_store then f.on_store(k,v) end
        f.saves[#f.saves+1]={key=k,row=copy(v)};f.records[k]=copy(v)
    end
    function R.json.encode() return "constructed bounded diagnostic" end
    function R.input.pulse(slot,button)
        check(slot==f.user and button=="y","same selected guarded equipment request")
        f.pulse_number+=1;f.pulse=newproxy();f.pulse_at=math.floor(f.now);f.pulse_observed=nil
        f.target=f.stock==100 and 504 or 100
        return f.pulse
    end
    function R.input.pulse_state(h)
        check(h==f.pulse,"pulse read retains exact current handle")
        if f.bad_pulse then return {status="released",terminal=true} end
        f.stock=f.target;f.pulse_observed=f.pulse_observed or math.floor(f.now)
        return {sequence=tostring(f.pulse_number),status="released",reason="none",user=f.user,button=0x8000,
            requested_ms=tostring(f.pulse_at),expires_ms=tostring(f.pulse_at+1000),observed_ms=tostring(f.pulse_observed),
            source_epoch="19",transport="xinput",source_identity="observed_stream",publication_scope="process_outer_xinput_buffer",
            consumption="unobserved",semantic_completion="unobserved",terminal=true,report_debt=false,claim_released=true,
            actor_retired=false,orphaned=false,quarantined=false,original_result_known=true,original_result=0,
            first_rejection_mask=0,first_rejection_stage="none",
            press_candidates="50",press_publications="50",neutral_publications="1",original_failures="0",contentions="0"}
    end
    function R.input.pulse_cancel(h) check(h==f.pulse,"same pulse cancel handle");return true end
    function R.input.pulse_acknowledge(h) check(h==f.pulse,"same pulse ACK handle");f.pulse=nil;return true end
    local function forbidden() error("constructed cycle fixture never creates/publishes a native body",0) end
    for _,n in {"bounds","set","status","remove"} do R.entities[n]=forbidden end
    for _,n in {"create","read","release","reserve_follow","publish_follow","read_follow","stop_follow","acknowledge_follow",
        "probe_batch","submit","receipt","acknowledge"} do R.world.physics[n]=forbidden end
    f.R=R
    f.owner=assert(Core.experimental_two_cycle_owner())
    f.T={phase="idle",generation=0,cancel_version=0,calls={},counts={},receipts={},omitted_calls=0,
        omitted_receipts=0,remove_attempted={},remove_accepted={}}
    f.core=assert(f.owner:first(R,{qualification_only=true},f.T))
    check(f.core:prepare_backend(),"first real Core backend is inert and available")
    check(f.core:request_mount(f.user),"first actual Core request consumes VM/private attempt")
    for _=1,42 do f.now+=16;f.core:step(16) end
    check(f.handle~=nil and f.count("lease")==1,"real Core admitted only the selected constructed Source")
    f.publish();f.now+=16;f.core:step(16)
    check(f.capture and f.capture.phase=="waiting_neutral","capture admitted without a body")
    f.activate();f.core:request_stop("constructed stop before body")
    if options and options.pending_source then
        f.now+=4001;f.core:step(16)
        check(f.core:status().source.cleanup_unknown,"real stopped Source retains unACKed capture debt")
        return f
    end
    f.complete_capture();f.now+=16;f.core:step(16)
    check(f.core:status().source.phase=="complete" and f.handle==nil,"actual Source read/ACK conjunction is complete")
    -- Existing shared-state test seam: these are deliberately constructed
    -- successful Follow/pose/board/visual history, not fabricated live results.
    local T=f.T
    T.published_seen=true;T.sequence="1";T.completed_ack=true;T.ack_attempted=true;T.acknowledged=true
    T.terminal=table.freeze({phase="completed",reason="cancelled",park_reason="none",sequence="1",final_revision="7",
        final_native_epoch="9",returned_revision="7",pending=table.freeze({}),in_flight=0,claim_known=false,orphaned=false,
        park_observed=true,native_retirement_known=false,terminal=true})
    T.pose_status=table.freeze({state="off",stopped=true,nil_accepted=true})
    T.board_status=table.freeze({state="restored",clear_result="cleared"})
    for i=1,8 do T.remove_attempted[i]=true;T.remove_accepted[i]=true end
    T.phase="done";T.active=false;T.bike_cleanup_complete=true
    function f.ticks(n)
        for _=1,n do f.now+=16;f.core:step(16) end
    end
    function f.stock_to(target)
        check(f.core:request_stock_toggle(f.user),"existing stock adapter accepts one fresh transaction")
        for _=1,600 do
            f.ticks(1)
            local s=f.core:status()
            if s.equipment.phase=="done" and not s.cleanup_pending then
                check(s.equipment.expected_state==target and s.equipment.acknowledged and s.equipment.current_transition,
                    "NEW target/ACK completed on old owner")
                return s
            end
        end
        error("constructed equipment transition failed to complete within unchanged arm window",0)
    end
    f.stock_to(100)
    check(f.core:status().stock_toggle_blocked==false,"old Core is fully clean after actual adapter100 ACK")
    function f.second_state()
        return {phase="idle",detail="constructed successor",generation=0,cancel_version=0,
            calls={},counts={},receipts={},omitted_calls=0,omitted_receipts=0,remove_attempted={},remove_accepted={}}
    end
    function f.prepare_504()
        check(f.owner:archive_return(),"archive exact stock100 terminal once")
        f.stock_to(504)
        check(f.owner:ready(),"real Core validates NEW504 attempt+ACK")
    end
    return f
end
return {new=make,copy=copy,Core=Core}

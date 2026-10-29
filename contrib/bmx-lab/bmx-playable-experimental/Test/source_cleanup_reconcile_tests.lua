-- Constructed ten-API fixtures only. newproxy values are test identities, never
-- native handles, source authority, physical controllers or gameplay evidence.
-- Requiring this module performs no API calls. Main owns eventual execution.
local Source = require("./lease_source")
local Identity = require("./lease_identity")
local Tests = {}
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
        -- Native ACK accepts a debt-free terminal lost-stream receipt even
        -- when its quarantine witness remains; live polls still refuse it.
        if not owns(handle) or not f.capture or not f.capture.terminal or f.capture.report_debt or
            f.in_flight then return false, "busy" end
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

-- Regression input is constructed. No service below is a native capability.
local function core_fixture(check)
    local f=fixture()
    local R={input=f.api,time={},menu={},skater={},level={},storage={},json={},entities={},world={physics={}}}
    f.clock_calls=0
    function R.time.now()
        f.clock_calls+=1
        if f.clock_hook then return f.clock_hook(f.clock_calls) end
        return f.now
    end
    function R.input.focus() return {focused=true,interface_open=false,gameplay=true} end
    function R.input.allowed() return true end
    function R.menu.game() return {open=false} end
    function R.skater.get() return {airborne=false,position=vector.create(0,0,0),heading=0} end
    function R.skater.telemetry() return {skater=true,airborne=false,teleport_pending=false,
        watch={valid=true,state=504,ragdoll_known=true,ragdoll=false,wipeouts=0}} end
    function R.level.current() return {name="constructed"} end
    function R.storage.get() return nil end
    function R.storage.set() end
    function R.json.encode() return "constructed bounded diagnostic" end
    local function forbidden() error("constructed cleanup must never acquire a body or publish input",0) end
    for _,name in {"bounds","set","status","remove"} do R.entities[name]=forbidden end
    for _,name in {"create","read","release","reserve_follow","publish_follow","read_follow","stop_follow",
        "acknowledge_follow","probe_batch","submit","receipt","acknowledge"} do R.world.physics[name]=forbidden end
    for _,name in {"pulse","pulse_state","pulse_cancel","pulse_acknowledge"} do R.input[name]=forbidden end
    -- Existing Core.new shared-state fixture seam. This seeded owner has never
    -- mounted a body or run request_mount; no once-per-VM guard is reset.
    local T={phase="armed",used=true,active=true,slot=f.user,generation=1,cancel_version=0,
        calls={},counts={},receipts={},omitted_calls=0,omitted_receipts=0,remove_attempted={},remove_accepted={},
        arm_at=f.now,ready_since=0,ready_last=f.now-1,ready_ticks=11,level="constructed",wipeouts=0}
    f.owner=Core.new(R,{qualification_only=true},T)
    f.T=T
    check(f.owner:prepare_backend()==true,"existing backend construction binds the real Core/Source path")
    f.owner:step(16)
    check(T.source_armed==true and f.count("lease")==1,"constructed Core arms exactly one selected lease")
    f.publish();f.now+=16;f.owner:step(16)
    check(f.capture and f.capture.phase=="waiting_neutral","real Core reaches admitted waiting capture without a body")
    f.activate()
    check(f.owner:request_stop("constructed owner stop")==true,"Core Stop revokes its constructed owner")
    f.stop_at=T.stop_at
    check(type(f.stop_at)=="number" and f.count("lease_release")==1 and f.count("lease_release_capture")==1,
        "both original releases occur exactly once")
    f.now=f.stop_at+4001;f.owner:step(16)
    check(f.owner:status().source.cleanup_unknown==true,"the original Source4s watchdog still latches UNKNOWN")
    f.clock_calls=0
    return f
end

function Tests.run()
    local cases,assertions=0,0
    local function check(v,why) assertions+=1;assert(v,why) end
    local function denied(row,why) check(type(row)=="table" and row.input_ok==false,why) end
    local gate={allow_acquire=true,allow_drive=true,allow_cleanup_reconcile=true}
    local function unknown(f)
        local active=f.start()
        check(active.input_ok==true,"constructed active Source before Stop")
        f.source:stop("constructed stop")
        local stop=f.now
        f.now=stop+4001
        local row=f.source:step(f.now)
        check(row.cleanup_unknown and row.cleanup_pending and row.input_ok==false,"original4s UNKNOWN remains visible")
        return active,stop,f.handle
    end
    local function no_resurrection(f,active,handle)
        check(f.source:authorize(active)==false and f.source:authorize(active,true)==false,
            "old publication is not authorized during or after cleanup")
        check(f.count("lease")==1 and f.count("lease_capture")==1,"cleanup never reacquires or recaptures")
        check(f.count("lease_release")==1 and f.count("lease_release_capture")==1,"cleanup never resends either release")
        for _,row in f.calls do
            if row.name~="lease" then check(row.args[1]==handle,"every cleanup API retains the exact original handle") end
        end
    end
    do
        cases+=1
        local f=fixture();unknown(f);f.complete_capture()
        local before=#f.calls
        for _,g in {false,{allow_cleanup_reconcile=false},{allow_cleanup_reconcile=1}} do
            f.now+=16;local row=f.source:step(f.now,g)
            check(row.cleanup_unknown and row.cleanup_pending,"default/false/nonboolean gate retains UNKNOWN")
        end
        check(#f.calls==before,"legacy callers never resume native polling after4s")
    end
    do
        cases+=1
        local f=fixture();local active,stop,handle=unknown(f)
        f.now=stop+5000;f.complete_capture()
        local row=f.source:step(f.now,gate)
        denied(row,"late cleanup never drives input")
        check(row.phase=="complete" and not row.cleanup_pending and not row.cleanup_unknown and row.lease_handle==nil,
            "strict late native capture+lease ACK resolves UNKNOWN")
        check(f.count("lease_acknowledge_capture")==1 and f.count("lease_acknowledge")==1,"both ACKs are actually accepted")
        no_resurrection(f,active,handle)
        local before=#f.calls;f.now+=16;f.source:step(f.now,gate)
        check(#f.calls==before,"completed key is never queried again")
    end
    do
        cases+=1
        local f=fixture();local active,stop,handle=unknown(f)
        f.capture.reason="interference"
        for _,offset in {5000,10000,19999} do
            f.now=stop+offset;local row=f.source:step(f.now,gate)
            check(row.phase=="cleanup_unknown" and row.cleanup_pending and row.cleanup_unknown,
                "known interfering/releasing debt remains UNKNOWN without a transient draining state")
            check(not f.source:arm(f.user,f.now),"retained debt cannot rearm")
        end
        check(f.count("lease_acknowledge_capture")==0 and f.count("lease_acknowledge")==0,"debt is never ACKed")
        no_resurrection(f,active,handle)
    end
    do
        cases+=1
        local f=fixture();unknown(f);f.complete_capture();f.in_flight=true
        denied(f.source:step(f.now+16,gate),"in-flight ACK refusal cannot restore input")
        check(f.source:status().cleanup_unknown and f.count("lease_acknowledge")==0,"false capture ACK does not advance lease ACK")
        f.in_flight=false;local row=f.source:step(f.now+32,gate)
        check(row.phase=="complete","same handle can finish once native ACK is actually accepted")
    end
    do
        cases+=1
        local f=fixture();unknown(f);f.complete_capture()
        local real=f.api.lease_acknowledge_capture
        f.api.lease_acknowledge_capture=function() error("constructed ACK error") end
        local row=f.source:step(f.now+16,gate)
        check(row.cleanup_unknown and f.count("lease_acknowledge")==0,"capture ACK throw remains retained")
        f.api.lease_acknowledge_capture=real
        check(f.source:step(f.now+32,gate).phase=="complete","a later actual ACK can resolve the same stopped handle")
    end
    -- R16 disconnect: native lost-release completion is quarantined and has no
    -- neutral witness. Only a successful native ACK may retire that old key.
    do
        cases+=1
        local f=fixture();local active,stop,handle=unknown(f)
        local renewals=f.count("lease_renew")
        f.passive.status,f.passive.reason="revoked","source_unavailable"
        f.capture.reason,f.capture.quarantined="authority_lost",true

        f.now=stop+5000
        local row=f.source:step(f.now,gate)
        check(row.cleanup_unknown and not row.input_ok and f.capture.phase=="releasing" and f.capture.report_debt,
            "nonterminal quarantined release debt stays retained")
        check(f.count("lease_acknowledge_capture")==0 and f.count("lease_acknowledge")==0,
            "nonterminal release cannot reach either native ACK")

        f.capture.phase,f.capture.terminal,f.capture.capturing="complete",true,false
        f.capture.generation,f.capture.revision=increment(f.capture.generation),increment(f.capture.revision)
        f.now+=4;row=f.source:step(f.now,gate)
        check(row.cleanup_unknown and row.cleanup_pending and f.count("lease_acknowledge_capture")==0,
            "malformed terminal receipt with report debt cannot reach native ACK")

        f.capture.report_debt=false
        f.capture.neutral_releases="0" -- end_lost_release never invents a neutral witness.
        f.capture.sequence="7"
        f.now+=4;row=f.source:step(f.now,gate)
        check(row.cleanup_unknown and f.count("lease_acknowledge_capture")==0 and f.count("lease_acknowledge")==0,
            "foreign terminal lost-stream identity cannot reach either ACK")
        f.capture.sequence=f.sequence

        f.in_flight=true
        f.now+=8;row=f.source:step(f.now,gate)
        check(row.cleanup_unknown and row.cleanup_pending and row.lease_handle==handle and not row.input_ok,
            "native capture ACK refusal retains the exact stopped handle")
        check(f.count("lease_acknowledge_capture")==1 and f.count("lease_acknowledge")==0,
            "debt-free quarantined zero-witness completion attempts capture ACK but does not skip its refusal")
        check(row.capture_state.phase=="complete" and row.capture_state.quarantined and
            row.capture_state.reason=="authority_lost" and row.capture_state.neutral_releases=="0",
            "refused ACK retains honest quarantine and zero neutral-witness diagnostics")

        f.in_flight=false
        f.now+=16;row=f.source:step(f.now,gate)
        check(row.phase=="complete" and row.lease_handle==nil and not row.cleanup_pending and
            not row.cleanup_unknown and not row.input_ok,"later actual native capture and passive ACKs resolve only cleanup")
        check(f.count("lease_acknowledge_capture")==2 and f.count("lease_acknowledge")==1,
            "passive source ACK follows the successful capture ACK exactly once")
        check(row.lease_state.terminal and row.lease_state.source_released and
            not row.lease_state.capture_reserved,"passive source release must be observed before its ACK")
        check(row.capture_state.quarantined and row.capture_state.neutral_releases=="0" and
            row.capture_state.reason=="authority_lost","cleanup never erases quarantine or manufactures a neutral handoff")
        check(f.count("lease_renew")==renewals,"disconnect cleanup never renews input authority")
        no_resurrection(f,active,handle)
        local count=#f.calls;f.now+=16;f.source:step(f.now,gate)
        check(#f.calls==count,"retired disconnect key is never queried again")
    end
    local bad_capture={
        {"terminal debt",function(f) f.capture.report_debt=true end},
        {"wrong identity",function(f) f.capture.sequence="7" end},
        {"stale generation",function(f) f.capture.generation="1" end},
        {"missing neutral release",function(f) f.capture.neutral_releases="0" end},
    }
    for _,spec in bad_capture do
        cases+=1
        local f=fixture();unknown(f);f.complete_capture();spec[2](f)
        local row=f.source:step(f.now+16,gate)
        check(row.cleanup_unknown and row.cleanup_pending and row.input_ok==false,spec[1].." cannot resolve UNKNOWN")
        check(f.count("lease_acknowledge_capture")==0 and f.count("lease_acknowledge")==0,spec[1].." cannot reach either ACK")
    end
    do
        cases+=1
        local f=fixture();unknown(f);f.complete_capture()
        local real=f.api.lease_acknowledge
        f.api.lease_acknowledge=function(h) check(h==f.handle,"lease ACK uses original handle");return false,"busy" end
        local row=f.source:step(f.now+16,gate)
        check(row.cleanup_unknown and row.lease_handle~=nil,"lease ACK false retains handle/UNKNOWN")
        f.api.lease_acknowledge=real
        check(f.source:step(f.now+32,gate).phase=="complete","later lease ACK success completes without re-ACKing erased capture")
        check(f.count("lease_acknowledge_capture")==1,"accepted capture ACK is not replayed")
    end
    do
        cases+=1
        local f=fixture();unknown(f);f.complete_capture();f.passive.status="active"
        local row=f.source:step(f.now+16,gate)
        check(row.cleanup_unknown and f.count("lease_acknowledge")==0,"contradictory passive terminal metadata is blocked")
    end
    do
        cases+=1
        local f=fixture();unknown(f);f.complete_capture()
        local before=#f.calls
        denied(f.source:step(f.now-1,gate),"regressed reconciliation clock denies input")
        check(#f.calls==before and f.source:status().cleanup_unknown,"clock refusal performs no native reconciliation")
    end
    do
        cases+=1
        local f=fixture()
        f.api.lease=function() error("unknown admission without a handle") end
        check(f.source:arm(f.user,f.now),"fixture arms before unknown admission")
        f.step();local before=#f.calls
        local row=f.source:step(f.now+5000,gate)
        check(row.cleanup_unknown and row.lease_handle==nil and #f.calls==before,"opt-in cannot invent/adopt a lost handle")
    end
    do
        cases+=1
        local f=core_fixture(check);f.now=f.stop_at+5000;f.complete_capture()
        local out=f.owner:step(16)
        check(out.source.phase=="complete" and out.source.cleanup_unknown==false,"real Core proxy accepts same-key late cleanup inside20s")
        check(out.phase=="done" and out.bike_cleanup_complete and not out.bike_authority and not out.cleanup_pending,
            "Core resolves only the original full cleanup conjunction")
        check(f.count("lease")==1 and f.count("lease_release")==1 and f.count("lease_release_capture")==1,"no new authority or release attempts")
        check(f.T.stop_at==f.stop_at and not f.T.cleanup_expired,"original watchdog anchor is not reset")
    end
    do
        cases+=1
        local f=core_fixture(check);f.complete_capture();f.now=f.stop_at+20000
        local before=#f.calls;local out=f.owner:step(16)
        check(#f.calls==before and f.T.cleanup_expired==true,"exactly20s closes even the first native read")
        check(out.source.cleanup_unknown and out.cleanup_unknown and out.stock_toggle_blocked,"expired Core cannot recover stock permission")
        f.now+=16;f.owner:step(16)
        check(#f.calls==before and f.T.stop_at==f.stop_at,"expiry is sticky with no watchdog reset or late polls")
    end
    do
        cases+=1
        local f=core_fixture(check);f.complete_capture();f.now=f.stop_at+19999;f.clock_calls=0
        f.clock_hook=function(n) if n>=2 then return f.stop_at+20000 end;return f.now end
        local before=#f.calls;local out=f.owner:step(16)
        check(#f.calls==before and f.T.cleanup_expired,"fresh proxy clock refuses a deadline crossed after tick entry")
        check(out.source.cleanup_unknown and out.stock_toggle_blocked,"stale tick clock cannot qualify cleanup")
    end
    for _,method in {"lease_capture_state","lease_acknowledge_capture","lease_state","lease_acknowledge"} do
        cases+=1
        local f=core_fixture(check);f.complete_capture();f.now=f.stop_at+5000
        local start=#f.calls
        f.on_call=function(name) if name==method then f.now=f.stop_at+20000 end end
        local out=f.owner:step(16)
        local last=f.calls[#f.calls]
        check(#f.calls>start and last.name==method,"actual Core proxy reaches exactly the selected crossing callback: "..method)
        check(out.source.cleanup_unknown and out.stock_toggle_blocked and f.T.cleanup_expired,
            "a callback crossing20s cannot publish late completion: "..method)
        local after=#f.calls;f.now+=16;f.owner:step(16)
        check(#f.calls==after,"no native operation follows deadline crossing: "..method)
        check(f.T.stop_at==f.stop_at and f.count("lease")==1 and f.count("lease_release")==1,
            "crossing never extends watchdog or reacquires/releases again: "..method)
    end
    do
        cases+=1
        local f=core_fixture(check);f.complete_capture();f.now=f.stop_at+5000
        f.on_call=function(name) if name=="lease_capture_state" then f.owner:unload() end end
        local start=#f.calls;local out=f.owner:step(16)
        check(#f.calls==start+1 and out.unloaded and out.source.cleanup_unknown,"reentrant unload blocks subsequent ACK without losing UNKNOWN")
        check(f.count("lease_release")==1 and f.count("lease_release_capture")==1,"unload sends no duplicate release")
    end
    for _,bad in {"regressed","unavailable"} do
        cases+=1
        local f=core_fixture(check);f.complete_capture();f.now=f.stop_at+5000;f.clock_calls=0
        f.clock_hook=function(n) if n>=2 then if bad=="regressed" then return f.now-1 end;return nil end;return f.now end
        local before=#f.calls;local out=f.owner:step(16)
        check(#f.calls==before and f.T.clock_unknown,"bad fresh proxy clock blocks read/ACK: "..bad)
        check(out.source.cleanup_unknown and out.stock_toggle_blocked,"bad clock never grants stock authority: "..bad)
    end
    do
        cases+=1
        local f=core_fixture(check);f.complete_capture();f.in_flight=true;f.now=f.stop_at+5000
        local out=f.owner:step(16)
        check(out.source.cleanup_unknown and out.stock_toggle_blocked and f.count("lease_acknowledge")==0,"Core cannot treat failed capture ACK as source release")
        f.in_flight=false;f.now=f.stop_at+20000
        local before=#f.calls;out=f.owner:step(16)
        check(#f.calls==before and out.source.cleanup_unknown and f.T.cleanup_expired,"native readiness at exact deadline cannot reopen expired cleanup")
    end
    do
        cases+=1
        local f=core_fixture(check);f.now=f.stop_at+5000;f.capture.reason="interference"
        local out=f.owner:step(16)
        check(out.source.cleanup_unknown and out.stock_toggle_blocked and f.count("lease_acknowledge_capture")==0,
            "real Core preserves SDK interference/debt UNKNOWN")
        f.now=f.stop_at+19999;f.complete_capture();out=f.owner:step(16)
        check(out.source.phase=="complete" and out.phase=="done" and not f.T.cleanup_expired,
            "actual terminal evidence immediately before original deadline can still resolve")
    end
    return {cases=cases,assertions=assertions,constructed=true,native_authority=false,gameplay=false}
end
return Tests

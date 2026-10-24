-- Constructed ten-API fixtures only. newproxy values are test identities, never
-- native handles, source authority, physical controllers or gameplay evidence.
-- Requiring this module performs no API calls. Main owns eventual execution.
local Source = require("./lease_source")
local Identity = require("./lease_identity")
local Tests = {}

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
    function f.publish(pad, equal_ms)
        f.serial = increment(f.serial)
        if not equal_ms then f.native_ms = increment(f.native_ms) end
        f.sample = metadata({sequence=f.sequence,source_epoch=f.source_epoch,context_generation=f.context,
            observation_serial=f.serial,observed_ms=f.native_ms,user=f.user,packet=f.packet,pad=copy(pad or neutral())})
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

function Tests.run()
    local cases, assertions = 0, 0
    local function check(value, why) assertions += 1 assert(value, why) end
    local function denied(frame, why) check(type(frame)=="table" and frame.input_ok==false, why) end
    do
        cases += 1
        check(Identity.is_u64("18446744073709551615") and Identity.is_u64("0"),"canonical uint64 endpoints accepted")
        for _,bad in ipairs({"18446744073709551616","00","01","+1","1.0","1e3","",false,1})do
            check(not Identity.is_u64(bad),"overflow, leading zero and noncanonical/native-number input refused")
        end
        check(Identity.compare("9007199254740993","9007199254740992")==1,"identities above 2^53 differ by one exactly")
        check(Identity.compare("18446744073709551615","18446744073709551615")==0,"MAX_U64 remains exact")
        check(Identity.bounded_delta("10000000000000000000","9999999999999999999",1)==1,"decimal subtraction borrows across all digits")
        check(Identity.bounded_delta("18446744073709551615","18446744073709551600",15)==15,"exact bounded difference accepted at limit")
        check(Identity.bounded_delta("18446744073709551615","18446744073709551599",15)==nil,"difference limit plus one refuses")
        check(Identity.bounded_delta("9007199254740992","9007199254740993",100)==nil,"native publication clock regression refuses")
        check(Identity.bounded_delta("9007199254740993","9007199254740993",0)==0,"genuine equal-ms difference remains zero")
    end
    do
        cases += 1
        local f = fixture()
        local independent = fixture()
        check(f.source~=independent.source,"successive constructors create independent source instances")
        for _,object in ipairs({f.source,independent.source})do
            check(table.isfrozen(object),"source instances are frozen after construction")
            check(getmetatable(object)=="locked","source instance metatable remains protected")
            check(not pcall(function()rawset(object,"fixture_mutation",true)end),"rawset cannot mutate a constructed source")
            check(not pcall(function()setmetatable(object,{})end),"source instance metatable cannot be replaced")
        end
        check(#f.calls==0 and #independent.calls==0,"both independent constructions must not acquire input")
        check(f.source:arm(2,f.now),"explicit fixture arm")
        check(#f.calls==0,"arm records intent without a native request")
        denied(f.step({}),"missing caller gates grant no input")
        check(f.count("lease")==0,"false acquire gate never calls lease")
        f.step({allow_acquire=true,allow_drive=false})
        check(f.count("lease")==1,"one explicit selected slot acquisition")
        for _=1,3 do denied(f.step(),"warming has no sample authority") end
        check(f.count("lease")==1 and f.count("lease_capture")==0,"warming does not retry/fabricate sample")
    end
    do
        cases += 1
        local f = fixture(); local frame = f.start()
        check(frame.input_ok==true and frame.phase=="capturing","only native-shaped capturing facts admit input")
        check(frame.sample.source_epoch=="9007199254741009" and frame.sample.user==2,"exact64 identity and actual slot retained")
        check(frame.lease_handle==f.handle and frame.sample.epoch==nil,"real opaque handle returned but input epoch stays private")
        local renewals = f.count("lease_renew")
        local duplicate = f.step()
        check(duplicate.input_ok and not duplicate.new_observation,"new epoch userdata does not turn a duplicate ordinal into a sample")
        check(f.count("lease_renew")==renewals,"duplicate source ordinal never renews")
        f.publish(nil,true)
        check(f.step().new_observation,"fresh ordered observation may have zero native-ms elapsed")
        local status=f.source:status(); local original=status.sample.source_epoch
        pcall(function()status.sample.source_epoch="1"end)
        check(f.source:status().sample.source_epoch==original,"status snapshots cannot mutate retained identity")
        check(f.count("lease_capture")==1,"one successful capture per lease")
    end
    do
        cases += 1
        local f=fixture();assert(f.source:arm(2,f.now));f.step();f.capture_refusal="source_stale"
        f.publish();denied(f.step(),"refused capture cannot admit input")
        local attempts=f.count("lease_capture")
        for _=1,3 do denied(f.step(),"same refused ordinal stays unqualified") end
        check(f.count("lease_capture")==attempts,"capture retry needs a later fresh observation")
        f.capture_refusal=nil;f.publish();denied(f.step(),"admission still waits for capture publication")
        check(f.count("lease_capture")==attempts+1,"one retry on a later observation")
    end
    local faults = {
        function(f)f.sample.observation_serial="9007199254740999"end,
        function(f)f.sample.observed_ms="9007199254740999"end,
        function(f)f.sample.pad.buttons.a=true end,
        function(f)f.sample.packet+=1 end,
        function(f)f.sample.source_epoch="9007199254741010"end,
        function(f)f.sample.context_generation="9007199254741012"end,
        function(f)f.sample.user=1 end,
        function(f)f.sample.source_epoch="09007199254741009"end,
        function(f)f.sample.source_epoch="18446744073709551616"end,
        function(f)f.sample.pad.left_x=0/0 end,
        function(f)f.sample.pad.buttons.right_stick=nil end,
        function(f)f.capture.quarantined=true end,
        function(f)f.capture.report_debt=false end,
        function(f)f.capture.consumption="proven"end,
        function(f)f.capture.phase="waiting_neutral";f.capture.capturing=false end,
        function(f)f.capture.generation="1"end,
        function(f)f.capture.revision="1"end,
    }
    for _, fault in ipairs(faults) do
        cases += 1
        local f=fixture();check(f.start().input_ok,"fault begins from constructed admitted input")
        fault(f);denied(f.step(),"regression/replacement/inconsistent source or capture facts revoke input")
        check(f.count("lease")==1,"loss never automatically acquires a replacement lease")
    end
    do
        cases += 1
        local f=fixture();local active=f.start();check(active.input_ok,"constructed capturing source before cleanup")
        local release_start=#f.calls+1
        f.on_call=function(name)
            if name=="lease_release_capture" or name=="lease_release" then
                check(f.source:status().input_ok==false,"permission invalidated before release callback")
                check(f.source:status().generation>active.generation,"generation invalidated before release callback")
                local count=#f.calls
                denied(f.source:step(f.now,{allow_acquire=true,allow_drive=true}),"release callback cannot reenter driving/drain")
                check(not f.source:arm(2,f.now) and #f.calls==count,"release reentry neither invokes API nor rearms")
            end
        end
        denied(f.source:stop("fixture owner loss"),"stop revokes synchronously")
        for _=1,3 do denied(f.step(),"debt retains cleanup without driving") end
        check(f.count("lease_acknowledge_capture")==0 and f.count("lease_acknowledge")==0,"releasing debt is not acknowledged")
        local capture_release,passive_release
        for index=release_start,#f.calls do
            local name=f.calls[index].name
            if name=="lease_release_capture" and not capture_release then capture_release=index end
            if name=="lease_release" and not passive_release then passive_release=index end
        end
        check(capture_release and passive_release and capture_release<passive_release,"capture release precedes passive release")
        f.complete_capture();f.in_flight=true;denied(f.step(),"inflight drain still withholds source acknowledgement")
        check(f.count("lease_acknowledge")==0,"clean capture DTO alone is not source drain")
        f.in_flight=false
        for _=1,3 do f.step() end
        local state=f.source:status()
        check(state.phase=="complete" and not state.cleanup_pending and state.lease_handle==nil,"both native-shaped acknowledgements finish cleanup")
        local capture_ack,passive_ack
        for index,item in ipairs(f.calls) do
            if item.name=="lease_acknowledge_capture" and not capture_ack then capture_ack=index end
            if item.name=="lease_acknowledge" and not passive_ack then passive_ack=index end
        end
        check(capture_ack and passive_ack and capture_ack<passive_ack,"capture acknowledgement precedes passive acknowledgement")
        local counts={f.count("lease_capture_state"),f.count("lease_state"),f.count("lease")}
        f.step();f.step()
        check(f.count("lease_capture_state")==counts[1] and f.count("lease_state")==counts[2] and f.count("lease")==counts[3],
            "completed cleanup neither queries acknowledged objects nor reacquires")
    end
    do
        cases += 1
        local f=fixture({cleanup_ms=5});check(f.start().input_ok,"constructed active source")
        f.source:unload();f.now+=6
        local state=f.step()
        denied(state,"unload/unknown cleanup never permits input")
        check(state.cleanup_unknown and state.cleanup_pending,"cleanup timeout retains unknown debt")
        check(not f.source:arm(2,f.now),"unknown cleanup cannot be bypassed with another arm")
        check(f.capture and f.capture.report_debt and f.count("lease_acknowledge")==0,"timeout never clears native-shaped debt")
    end
    do
        cases += 1
        local f=fixture();check(f.start().input_ok,"constructed active capture before in-flight reopening")
        f.source:stop("fixture stop before delayed outer report")
        f.complete_capture();f.in_flight=true
        denied(f.step(),"complete capture still cannot acknowledge an in-flight source call")
        local refused=f.count("lease_acknowledge_capture")
        check(refused>0 and f.count("lease_acknowledge")==0,"native-shaped capture acknowledgement refused before source drain")
        f.capture.phase,f.capture.terminal,f.capture.report_debt="releasing",false,true
        f.capture.generation,f.capture.revision=increment(f.capture.generation),increment(f.capture.revision)
        f.capture.publications=increment(f.capture.publications)
        denied(f.step(),"advancing same-key complete-to-releasing reopening retains cleanup duty")
        check(f.count("lease_acknowledge_capture")==refused and f.count("lease_acknowledge")==0,
            "reopened debt is never acknowledged as an old complete receipt")
        f.in_flight=false;f.complete_capture()
        for _=1,3 do f.step()end
        check(f.source:status().phase=="complete" and f.handle==nil,"later advancing neutral cleanup can finish after legitimate reopening")
    end
    for _, name in ipairs(names) do
        cases += 1
        local f=fixture();f.api[name]=nil
        f.source=Source.new(f.api)
        f.source:arm(2,f.now);denied(f.step(),"missing official method keeps source unavailable")
        check(f.count("lease")==0,"missing one of ten methods never admits native ownership")
    end
    do
        cases += 1
        local f=fixture();check(f.start().input_ok,"constructed source before caller loss")
        denied(f.step({allow_acquire=true,allow_drive=false}),"caller drive loss stops an active session")
        f.complete_capture();for _=1,3 do f.step()end
        check(f.count("lease")==1,"restoring caller gates does not auto-resume")
    end
    do
        cases += 1
        local f=fixture();local active=f.start()
        local snapshot=f.source:status()
        check(active.input_ok and snapshot.input_ok==false and snapshot.new_observation==false,
            "diagnostic status cannot be reused as a force/input permission")
        f.now-=10;denied(f.source:step(f.now,{allow_acquire=true,allow_drive=true}),"Lua watchdog regression stops input")
        check(f.source:status().generation>active.generation,"clock loss invalidates old permit generation")
    end
    for _, options in ipairs({{setup_ms=0},{capture_ms=60001},{cleanup_ms=1.5},{setup_ms="5"},{capture_ms=0/0}}) do
        cases += 1
        local f=fixture(options)
        check(not f.source:arm(2,f.now),"malformed/out-of-bound watchdog configuration disables arm")
        check(#f.calls==0,"invalid options never invoke native-shaped methods")
    end
    do
        cases += 1
        local f=fixture();check(f.start().input_ok,"constructed active source before API error")
        f.api.lease_capture_state=function()error("fixture API exception")end
        denied(f.step(),"API exception cannot preserve input permission")
        check(f.count("lease")==1 and not f.source:arm(2,f.now),"uncertain API outcome cannot trigger reacquisition")
    end
    do
        cases += 1
        local f=fixture();local stopped=false
        f.on_call=function(name)
            if name=="lease" and not stopped then
                stopped=true
                denied(f.source:stop("fixture admission callback revoked owner"),"reentrant stop is synchronous")
            end
        end
        check(f.source:arm(2,f.now),"explicit fixture arm before late admission")
        denied(f.step(),"late handle admission cannot resurrect a revoked generation")
        check(stopped and f.count("lease")==1 and f.count("lease_capture")==0,"stale admission result never proceeds to capture")
        check(f.count("lease_release")>0,"late returned handle is retained for native-shaped release")
        check(not f.source:arm(2,f.now),"late admission cleanup cannot be bypassed")
    end
    return {cases=cases,assertions=assertions,constructed=true,native_authority=false,gameplay=false}
end
return Tests

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
    function f.complete_lost_capture()
        -- Model the SDK's ended lost-stream receipt, not a Lua release timer
        -- or a neutral report from a replacement source.
        assert(f.capture, "fixture needs the retained lost-stream key")
        f.capture.phase, f.capture.terminal, f.capture.capturing, f.capture.report_debt = "complete", true, false, false
        f.capture.reason, f.capture.quarantined = "authority_lost", true
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
        if not owns(handle) or not f.capture or f.capture.phase ~= "complete" or not f.capture.terminal or
            f.capture.report_debt or f.in_flight then return false, "busy" end
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
        -- The SDK's rest fact is copied as given, so Core uses it without thresholds of its own.
        local f=fixture();local active=f.start()
        check(active.input_ok and active.sample.neutral==nil,"a runtime without the fact leaves it nil")
        local noisy=neutral();noisy.left_x,noisy.right_trigger=.2,.1
        f.publish(noisy,false,true)
        local frame=f.step()
        check(frame.input_ok and frame.sample.neutral==true and frame.sample.pad.left_x==.2,
            "the SDK's neutral fact is copied beside the pad")
        local pushed=neutral();pushed.left_x=.9
        f.publish(pushed,false,false)
        frame=f.step()
        check(frame.input_ok and frame.sample.neutral==false,"a false fact is copied too")
    end
    local contradictions={
        {"string",function(pad) return pad,"true" end},
        {"number",function(pad) return pad,1 end},
        {"pressed button called neutral",function(pad) pad.buttons.a=true;return pad,true end},
        {"exact zero called active",function(pad) return pad,false end},
    }
    for _, spec in ipairs(contradictions) do
        cases += 1
        local f=fixture();check(f.start().input_ok,"constructed admitted input")
        local pad,value=spec[2](neutral())
        f.publish(pad,false,value)
        denied(f.step(),"a malformed or contradictory neutral fact stops input: "..spec[1])
        check(f.source:status().reason=="invalid neutral fact","the stop names the neutral fact: "..spec[1])
        check(f.count("lease")==1,"a bad fact never acquires a replacement lease")
    end
    do
        cases += 1
        local f=fixture();check(f.start().input_ok,"constructed admitted input")
        local noisy=neutral();noisy.left_y=-.1
        f.publish(noisy,false,true);check(f.step().input_ok,"a fresh neutral observation is admitted")
        f.sample.neutral=false
        denied(f.step(),"a duplicate observation whose neutral fact changed stops input")
        check(f.source:status().reason=="changed duplicate observation","the stop names the changed duplicate")
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
        local f=fixture();check(f.start().input_ok,"constructed active source before lost-stream cleanup")
        local handle=f.handle
        f.source:stop("fixture lost-stream authority")
        f.capture.reason,f.capture.quarantined="authority_lost",true
        for _=1,3 do denied(f.step(),"before the native release bound, quarantined debt grants no input") end
        check(f.capture.phase=="releasing" and f.capture.report_debt and f.capture.neutral_releases=="0",
            "Lua does not infer a lost-stream release from its own elapsed steps")
        check(f.count("lease_acknowledge_capture")==0 and f.count("lease_acknowledge")==0,
            "pre-bound debt cannot attempt either acknowledgement")
        local publications=f.capture.publications
        f.complete_lost_capture()
        local before=#f.calls
        local ended=f.step()
        denied(ended,"ended lost-stream cleanup never grants input")
        check(ended.phase=="complete" and ended.lease_handle==nil and not ended.cleanup_pending,
            "true exact capture ACK and later released lease ACK finish cleanup")
        check(ended.capture_state.quarantined and ended.capture_state.reason=="authority_lost" and
            ended.capture_state.neutral_releases=="0" and ended.capture_state.publications==publications,
            "frozen cleanup history preserves quarantine and unwitnessed neutral")
        check(ended.lease_state.terminal and ended.lease_state.source_released and not ended.lease_state.capture_reserved,
            "completion retains the later validated source-release receipt")
        local sequence={}
        for index=before+1,#f.calls do
            sequence[#sequence+1]=f.calls[index].name
            check(f.calls[index].args[1]==handle,"cleanup uses the original opaque handle")
        end
        check(table.concat(sequence," ")=="lease_capture_state lease_acknowledge_capture lease_state lease_acknowledge",
            "fresh capture receipt, true capture ACK, fresh passive receipt and true passive ACK stay ordered")
        local calls=#f.calls
        f.step()
        check(#f.calls==calls and f.count("lease")==1,"completed cleanup neither re-reads acknowledged keys nor reacquires")
    end
    do
        cases += 1
        local f=fixture();check(f.start().input_ok,"constructed active source before lost-stream poll drain")
        local handle=f.handle
        f.source:stop("fixture lost-stream poll still in flight")
        f.complete_lost_capture();f.in_flight=true
        local reads=f.count("lease_state")
        local held=f.step()
        denied(held,"a debt-free receipt is not an SDK acknowledgement")
        check(f.count("lease_acknowledge_capture")==1 and f.count("lease_acknowledge")==0 and
            f.count("lease_state")==reads,"in-flight capture ACK refusal cannot advance to passive cleanup")
        check(held.cleanup_pending and held.lease_handle==handle and f.handle==handle and
            held.capture_state.quarantined and held.capture_state.neutral_releases=="0",
            "refusal retains exact ownership and lost-stream history")
        f.in_flight=false
        local ended=f.step()
        check(ended.phase=="complete" and f.count("lease_acknowledge_capture")==2 and
            f.count("lease_acknowledge")==1,"a later true SDK ACK after poll drain permits passive cleanup")
        check(ended.capture_state.quarantined and ended.capture_state.neutral_releases=="0",
            "successful poll drain does not manufacture a neutral witness")
    end
    do
        cases += 1
        local f=fixture({cleanup_ms=5});check(f.start().input_ok,"constructed active source before unwitnessed ordinary completion")
        local handle=f.handle
        f.source:stop("fixture ordinary completion without neutral witness")
        f.complete_lost_capture();f.capture.quarantined,f.capture.reason=false,"cancelled"
        local held=f.step()
        denied(held,"ordinary completion without a neutral witness grants no input")
        check(held.capture_state.phase=="complete" and not held.capture_state.report_debt and
            not held.capture_state.quarantined and held.capture_state.neutral_releases=="0",
            "the ordinary debt-free receipt is retained without manufacturing its missing witness")
        check(f.count("lease_acknowledge_capture")==0 and f.count("lease_acknowledge")==0,
            "the quarantine exception does not admit ordinary unwitnessed completion after capturing")
        f.now+=6
        local unknown=f.step()
        check(unknown.cleanup_unknown and unknown.cleanup_pending and unknown.lease_handle==handle and
            f.handle==handle and f.count("lease_acknowledge_capture")==0 and f.count("lease_acknowledge")==0,
            "ordinary unwitnessed cleanup remains owned and unknown at the watchdog bound")
    end
    for _,lost_stream in ipairs({false,true})do
        cases += 1
        local f=fixture();check(f.start().input_ok,"constructed active capture before in-flight reopening")
        f.source:stop("fixture stop before delayed outer report")
        if lost_stream then f.complete_lost_capture()else f.complete_capture()end
        f.in_flight=true
        denied(f.step(),"complete capture still cannot acknowledge an in-flight source call")
        local refused=f.count("lease_acknowledge_capture")
        check(refused>0 and f.count("lease_acknowledge")==0,"native-shaped capture acknowledgement refused before source drain")
        f.capture.phase,f.capture.terminal,f.capture.report_debt="releasing",false,true
        f.capture.generation,f.capture.revision=increment(f.capture.generation),increment(f.capture.revision)
        f.capture.publications=increment(f.capture.publications)
        denied(f.step(),"advancing same-key complete-to-releasing reopening retains cleanup duty")
        check(f.count("lease_acknowledge_capture")==refused and f.count("lease_acknowledge")==0,
            "reopened debt is never acknowledged as an old complete receipt")
        f.in_flight=false
        if lost_stream then f.complete_lost_capture()else f.complete_capture()end
        for _=1,3 do f.step()end
        local ended=f.source:status()
        check(ended.phase=="complete" and f.handle==nil,"later advancing debt-free cleanup can finish after legitimate reopening")
        check(ended.capture_state.quarantined==lost_stream and
            ended.capture_state.neutral_releases==(lost_stream and "0" or "2"),
            "reopened cleanup preserves ordinary witnesses or the lost stream's unwitnessed history")
    end
    local invalid_cleanup={
        {"foreign user",function(row)row.user=1 end},
        {"foreign sequence",function(row)row.sequence=increment(row.sequence)end},
        {"foreign source epoch",function(row)row.source_epoch=increment(row.source_epoch)end},
        {"foreign context",function(row)row.context_generation=increment(row.context_generation)end},
        {"complete with debt",function(row)row.report_debt=true end},
        {"complete without terminal",function(row)row.terminal=false end},
    }
    for _,spec in ipairs(invalid_cleanup)do
        cases += 1
        local f=fixture();check(f.start().input_ok,"constructed active source before invalid cleanup: "..spec[1])
        local handle=f.handle
        f.source:stop("fixture invalid terminal capture")
        f.complete_lost_capture();spec[2](f.capture)
        local reads=f.count("lease_state")
        local held=f.step()
        denied(held,"invalid terminal capture cannot grant input: "..spec[1])
        check(f.count("lease_acknowledge_capture")==0 and f.count("lease_acknowledge")==0 and
            f.count("lease_state")==reads,"invalid/foreign capture receipt never attempts ACK: "..spec[1])
        check(held.cleanup_pending and held.lease_handle==handle and not f.source:arm(2,f.now),
            "invalid cleanup retains original ownership without reacquisition: "..spec[1])
    end
    local non_true_ack={{label="false",value=false},{label="nil"},{label="truthy string",value="true"},{label="number",value=1}}
    for _,spec in ipairs(non_true_ack)do
        cases += 1
        local f=fixture();check(f.start().input_ok,"constructed active source before capture ACK "..spec.label)
        local handle=f.handle
        f.source:stop("fixture capture ACK did not return true")
        f.complete_lost_capture()
        f.api.lease_acknowledge_capture=function(key)
            table.insert(f.calls,{name="lease_acknowledge_capture",args={key}})
            return spec.value,"fixture capture ACK outcome"
        end
        local reads=f.count("lease_state")
        local held=f.step()
        denied(held,"non-true capture ACK grants no input")
        check(f.count("lease_acknowledge_capture")==1 and f.count("lease_acknowledge")==0 and
            f.count("lease_state")==reads,"only literal true capture ACK can advance to passive receipt: "..spec.label)
        check(held.cleanup_pending and held.lease_handle==handle and f.handle==handle and
            held.capture_state.quarantined and held.capture_state.neutral_releases=="0",
            "non-true capture ACK retains handle and unwitnessed history: "..spec.label)
    end
    local delayed_source={
        {"not terminal",function(row)
            row.status,row.reason,row.terminal="active","none",false
            row.source_released,row.capture_reserved=false,false
        end},
        {"terminal still reserved",function(row)row.source_released,row.capture_reserved=false,true end},
    }
    for _,spec in ipairs(delayed_source)do
        cases += 1
        local f=fixture();check(f.start().input_ok,"constructed active source before delayed passive evidence")
        local handle=f.handle
        f.source:stop("fixture later passive receipt not yet released")
        f.complete_lost_capture()
        local native_state=f.api.lease_state
        f.api.lease_state=function(key)
            local row=native_state(key)
            spec[2](row)
            return row
        end
        local held=f.step()
        denied(held,"true capture ACK alone cannot complete source cleanup")
        check(f.capture==nil and f.count("lease_acknowledge_capture")==1 and f.count("lease_acknowledge")==0,
            "capture ACK succeeds but delayed passive evidence prevents passive ACK: "..spec[1])
        check(held.cleanup_pending and held.lease_handle==handle and f.handle==handle,
            "later source-release evidence remains required: "..spec[1])
        check(held.lease_state.source_released==false and
            held.lease_state.terminal==(spec[1]~="not terminal") and
            held.lease_state.capture_reserved==(spec[1]~="not terminal"),
            "the deliberately delayed passive receipt was validated and retained: "..spec[1])
        f.api.lease_state=native_state
        local ended=f.step()
        check(ended.phase=="complete" and f.count("lease_acknowledge_capture")==1 and f.count("lease_acknowledge")==1,
            "fresh terminal released evidence finishes without repeating capture ACK: "..spec[1])
        check(ended.capture_state.quarantined and ended.capture_state.neutral_releases=="0",
            "passive release preserves quarantined capture history: "..spec[1])
    end
    for _,spec in ipairs(non_true_ack)do
        cases += 1
        local f=fixture();check(f.start().input_ok,"constructed active source before passive ACK "..spec.label)
        local handle=f.handle
        f.source:stop("fixture passive ACK did not return true")
        f.complete_lost_capture()
        local native_ack=f.api.lease_acknowledge
        f.api.lease_acknowledge=function(key)
            table.insert(f.calls,{name="lease_acknowledge",args={key}})
            return spec.value,"fixture passive ACK outcome"
        end
        local held=f.step()
        check(held.phase=="draining" and held.cleanup_pending and held.lease_handle==handle and f.handle==handle,
            "literal true passive ACK is still required to discard ownership: "..spec.label)
        check(f.count("lease_acknowledge_capture")==1 and f.count("lease_acknowledge")==1,
            "capture ACK completed independently of the refused passive ACK: "..spec.label)
        f.api.lease_acknowledge=native_ack
        local ended=f.step()
        check(ended.phase=="complete" and ended.lease_handle==nil and f.count("lease_acknowledge_capture")==1 and
            f.count("lease_acknowledge")==2,"later true passive ACK alone completes the retained source: "..spec.label)
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
    do
        -- authorize afresh makes the three lease reads; from the step it judges the rows that
        -- step read, the same way, and makes no SDK call. Core uses the step's rows only for
        -- checks that publish nothing and reads afresh before it publishes a force.
        cases += 1
        local f=fixture();local frame=f.start()
        check(frame.input_ok,"constructed capturing source before authorization")
        local before=#f.calls
        local ok,why=f.source:authorize(frame)
        local reads={}
        for i=before+1,#f.calls do reads[#reads+1]=f.calls[i].name end
        check(ok==true and why==nil and table.concat(reads," ")=="lease_read lease_state lease_capture_state",
            "afresh: the sample, the lease and the capture are read, in that order")
        before=#f.calls
        ok,why=f.source:authorize(frame,true)
        check(ok==true and why==nil and #f.calls==before,"from the step: the same answer with no SDK call")
        local later=f.step()
        check(later.input_ok,"a later step")
        before=#f.calls
        for _,from_step in ipairs({true,false}) do
            ok,why=f.source:authorize(frame,from_step)
            check(ok==false and why=="selected Source publication is not current" and #f.calls==before,
                "an earlier step's frame is refused before any read, either way")
        end
        ok,why=f.source:authorize(later,true)
        check(ok==true and #f.calls==before,"the latest step's rows authorize without a read")
        -- The native lease ends after the step: only a fresh read can see it.
        f.passive.status,f.passive.reason,f.passive.terminal="revoked","focus_lost",true
        ok,why=f.source:authorize(later,true)
        check(ok==true and #f.calls==before,"the step's rows still hold, unread: why Core reads afresh before a force")
        ok,why=f.source:authorize(later)
        check(ok==false and why=="fresh selected input unavailable","afresh, the revoked lease refuses at its first read: "..tostring(why))
    end
    return {cases=cases,assertions=assertions,constructed=true,native_authority=false,gameplay=false}
end
return Tests

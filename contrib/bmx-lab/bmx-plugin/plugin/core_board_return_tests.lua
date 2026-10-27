-- Actual Core, EquipmentRuntime, Source and Spawn with constructed SDK-shaped
-- services. Shared state starts at an explicitly constructed admission boundary;
-- it is not a mounted game actor or a way to rearm the production one-shot owner.
-- No qualification literal is changed. The opaque identities below are newproxy
-- test values, never native body/Follow/input handles or game evidence.
local Core=require("./bike_runtime_core")
local Runtime=require("./bike_runtime")
local Services=require("./core_ride_staging_tests")
local Tests={}
local KEY="bmx_bike_lifecycle_v1"
local TERMINAL="bmx_equipment_terminal_v1"
local PROGRESS="bmx_equipment_runtime_v1"

local function copy(value)
    if type(value)~="table" then return value end
    local out={};for k,v in pairs(value) do out[k]=copy(v) end;return out
end
local function history(now,active)
    return {phase=active and "armed" or "done",detail="Constructed admission history",
        used=true,active=active==true,bike_cleanup_complete=not active,stop_latched=not active,
        ledger_owned=true,level="sanvan",wipeouts=0,generation=1,cancel_version=0,
        arm_at=now,slot=0,calls={},counts={},receipts={},omitted_calls=0,omitted_receipts=0,
        remove_attempted={},remove_accepted={}}
end
local function fixture(mode)
    local f,s=Services.spawn_services()
    f.now,f.state,f.menu,f.focused,f.gameplay=100000,504,false,true,true
    f.airborne,f.ragdoll,f.teleport,f.player=false,false,false,true
    f.level,f.wipeouts="sanvan",0
    f.events,f.pulses,f.pulse_reads,f.pulse_acks,f.pulse_cancels={},0,0,0,0
    f.follow_stops,f.follow_acks,f.follow_reads=0,0,0
    f.follow_done=true
    local function event(name) table.insert(f.events,name) end
    function s.input.focus() return {focused=f.focused,interface_open=f.menu,gameplay=f.gameplay} end
    function s.input.allowed() return true end
    function s.menu.game() return {open=f.menu} end
    function s.skater.get()
        if f.player then return {airborne=f.airborne,position=vector.create(0,0,0),heading=0} end
    end
    function s.skater.telemetry()
        if f.on_telemetry then f.on_telemetry() end
        return {skater=f.player,airborne=f.airborne,teleport_pending=f.teleport,
            watch={valid=f.player,state=f.state,ragdoll_known=true,ragdoll=f.ragdoll,wipeouts=f.wipeouts}}
    end
    function s.level.current() return {name=f.level} end
    function s.storage.set(key,record)
        event("store:"..key)
        if f.on_store then f.on_store(key,record) end
        if f.fail_store==key then error("constructed storage failure",0) end
        f.records[key]=copy(record)
        -- The SDK returns zero values; a boolean is not success.
    end
    function s.input.pulse(slot,button)
        assert(button=="y","only a bounded Y pulse is requested")
        f.pulses+=1;event("pulse")
        f.pulse_handle,f.pulse_slot,f.pulse_at=newproxy(),slot,f.now
        if f.on_pulse then f.on_pulse() end
        return f.pulse_handle
    end
    function s.input.pulse_state(handle)
        assert(handle==f.pulse_handle,"read preserves the exact pulse identity")
        f.pulse_reads+=1
        local debt=f.pulse_debt==true
        return {sequence="9007199254740994",status=debt and "pressing" or "revoked",reason=debt and "none" or "unavailable",
            user=f.pulse_slot,button=0x8000,requested_ms=tostring(f.pulse_at),expires_ms=tostring(f.pulse_at+1000),
            observed_ms=tostring(f.now),source_epoch="9007199254740995",transport="xinput",source_identity="observed_stream",
            publication_scope="process_outer_xinput_buffer",consumption="unobserved",semantic_completion="unobserved",
            first_rejection_mask=debt and 0 or 1280,first_rejection_stage=debt and "none" or "core_plan",
            press_candidates="7",press_publications="7",neutral_publications=debt and "0" or "1",original_failures="0",contentions="0",
            terminal=not debt,report_debt=debt,claim_released=not debt,actor_retired=false,orphaned=false,quarantined=false,
            original_result_known=false}
    end
    function s.input.pulse_cancel(handle)
        assert(handle==f.pulse_handle,"cancel preserves the exact pulse identity")
        f.pulse_cancels+=1;event("pulse_cancel");return true
    end
    function s.input.pulse_acknowledge(handle)
        assert(handle==f.pulse_handle,"ACK preserves the exact pulse identity")
        assert(f.records[TERMINAL] and f.records[TERMINAL].receipt.sequence=="9007199254740994",
            "the complete pulse receipt is stored before ACK")
        f.pulse_acks+=1;event("pulse_ack")
        if f.fail_pulse_ack then return false end
        return true
    end
    local release_capture=s.input.lease_release_capture
    function s.input.lease_release_capture(handle)
        event("capture_release")
        local result=release_capture(handle)
        if result and f.hold_capture then
            f.capture.phase,f.capture.neutral_releases="releasing","0"
        end
        return result
    end
    local capture_state=s.input.lease_capture_state
    function s.input.lease_capture_state(handle)
        if f.capture and f.capture.phase=="releasing" and not f.hold_capture then
            f.capture.phase,f.capture.neutral_releases,f.capture.revision="complete",f.capture.publications,"25"
        end
        local row,why=capture_state(handle)
        if row and row.phase=="releasing" then row.report_debt=true end
        -- Preserve exact return arity; a trailing nil is not the SDK contract.
        if row then return row end
        return nil,why
    end
    for _,name in {"lease_release","lease_acknowledge_capture","lease_acknowledge"} do
        local original=s.input[name]
        s.input[name]=function(...)
            event(name);return original(...)
        end
    end
    local remove=s.entities.remove
    function s.entities.remove(id) event("remove:"..id);return remove(id) end
    local release=s.world.physics.release
    function s.world.physics.release(body) event("body_release");return release(body) end
    function s.world.physics.reserve_follow(body,attachment)
        table.insert(f.reserves,{body=body,attachment=attachment})
        f.follow=newproxy();f.follow_phase,f.follow_reason="reserved","none";event("follow_reserve")
        -- Successful reserve_follow returns both the handle and an explicit nil reason.
        return f.follow,nil
    end
    function s.world.physics.publish_follow(handle)
        assert(handle==f.follow,"publish uses the reserved Follow")
        event("follow_publish")
        if f.refuse_publish then return false,"native_refused" end
        f.follow_phase,f.ever_published="following",true;return true
    end
    function s.world.physics.stop_follow(handle)
        assert(handle==f.follow,"stop uses the exact Follow")
        f.follow_stops+=1;event("follow_stop");f.follow_phase="stopping"
        -- Native Follow preserves the first stop reason, including a menu loss
        -- observed before the later explicit Return click.
        if f.follow_reason=="none" then f.follow_reason="cancelled" end
        return true
    end
    function s.world.physics.read_follow(handle)
        assert(handle==f.follow,"read uses the exact Follow")
        f.follow_reads+=1
        local phase=f.follow_phase
        if phase=="stopping" and f.follow_done then phase=f.ever_published and "completed" or "abandoned" end
        local terminal=phase=="completed" or phase=="abandoned"
        return {phase=phase,reason=f.follow_reason,
            park_reason=f.park_reason or (phase=="completed" and "none" or "unavailable"),
            sequence="41",final_revision=f.ever_published and "3" or "0",
            final_native_epoch=f.ever_published and "9" or "0",
            returned_revision=phase=="completed" and "3" or "0",
            pending=phase=="stopping" and f.ever_published and {"body_parked"} or {},in_flight=0,
            claim_known=not terminal,orphaned=false,park_observed=phase=="completed",
            native_retirement_known=false,terminal=terminal}
    end
    function s.world.physics.acknowledge_follow(handle)
        assert(handle==f.follow,"ACK uses the exact Follow")
        assert(f.records[KEY] and f.records[KEY].terminal_receipt,"Follow terminal is stored before ACK")
        f.follow_acks+=1;event("follow_ack")
        if f.fail_follow_ack then return false end
        return true
    end
    local state=mode=="active" and history(f.now,true) or mode=="clean" and history(f.now,false) or nil
    f.shared=state
    f.core=Core.new(s,mode=="active" and {qualification_only=true} or nil,state)
    if mode=="active" then assert(f.core:prepare_backend(),"constructed admission binds actual Source and Spawn") end
    function f:step(dt)
        self.now+=dt or 100
        return self.core:step(dt or 100)
    end
    function f:ticks(n,dt)
        local out=self.core:status();for _=1,n do out=self:step(dt) end;return out
    end
    function f:following()
        local out=self.core:status()
        for _=1,220 do
            if out.phase=="following" or self.refuse_publish and out.stop_latched then break end
            out=self:step(16)
        end
        assert(self.ever_published or self.refuse_publish and #self.reserves==1,
            "the actual Core/Source/Spawn path reaches the constructed Follow")
        return out
    end
    function f:until_pulse()
        for _=1,40 do if self.pulses>0 then break end;self:step() end
        return self.core:status()
    end
    function f:finish_board()
        self:until_pulse();self.state=100;return self:ticks(35)
    end
    return f,s
end
local function event_at(f,name)
    for i,value in ipairs(f.events) do if value==name then return i end end
    return nil
end

function Tests.new_runner()
    local assertions=0
    local function check(value,why) assertions+=1;assert(value,why) end
    local cases={}
    local function case(fn) table.insert(cases,fn) end
    local function ended(f,why)
        local out=f.core:status()
        check(not out.board_return.pending and out.board_return.phase~="done",why)
        check(f.pulses==0,"refused/cancelled return never sends a pulse")
        return out
    end
    case(function()
        for _,slot in {0,1,2,3} do
            local f=fixture();f.state=100
            check(f.core:request_board(slot),"an explicit already-board request is accepted")
            local out=f:ticks(2)
            check(out.board_return.phase=="done" and not out.board_return.pending,"fresh board100 completes without equipment work")
            check(f.pulses==0 and f.pulse_reads==0 and f.pulse_acks==0,"already-board completion creates no report")
            check(not out.used and not out.bike_authority and #f.reserves==0,"the no-op does not mount or burn a bike attempt")
        end
    end)
    case(function()
        local f=fixture()
        for _,slot in {-1,4,.5,"0",false} do check(not f.core:request_board(slot),"invalid board slot is refused") end
        check(f.pulses==0 and #f.reserves==0,"invalid slots have no authority effects")
    end)
    case(function()
        local f=fixture();f.menu=true
        check(f.core:request_board(2),"fresh feet504 arms one fixed board target")
        f:ticks(5);check(f.pulses==0,"open menu cannot dispatch the return pulse")
        f.menu=false;f:until_pulse()
        local out=f.core:status()
        check(f.pulses==1 and f.pulse_slot==2,"return preserves the selected XInput slot")
        check(out.equipment.initial_state==504 and out.equipment.expected_state==100,"the frozen direction is feet504 to board100")
        check(out.board_return.pending and out.board_return.phase~="done","receipt publication alone is not target success")
        out=f:finish_board()
        check(out.board_return.phase=="done" and not out.board_return.pending,"fresh target suffix and ACK complete the return")
        check(out.equipment.qualified_transition and out.equipment.acknowledged and not out.equipment.retained,
            "completion retains the actual adapter's qualified target and clean ACK")
        check(f.pulses==1 and f.pulse_acks==1,"a successful return issues and ACKs exactly one report")
        f:ticks(15);check(f.pulses==1,"quiescent ticks do not return or toggle again")
    end)
    case(function()
        local f=fixture("active");f:following();f.follow_done=false;f.hold_capture=true
        check(f.core:request_board(0),"a mounted owner accepts one explicit return")
        f:ticks(3)
        check(f.core:status().board_return.pending and f.pulses==0,"Follow and held-input cleanup delay the pulse")
        check(event_at(f,"follow_stop")<event_at(f,"capture_release"),"Follow stop precedes capture release")
        f.follow_done=true;f:ticks(2)
        check(f.follow_acks==1 and f.pulses==0,"Follow terminal ACK cannot bypass held capture")
        f.hold_capture=false
        local out=f:finish_board()
        check(out.board_return.phase=="done" and f.pulses==1,"cleared owner reaches the actual stock adapter")
        check(f.follow_stops==1 and f.follow_acks==1 and #f.releases==0,"completed Follow is stopped/ACKed once without double body release")
        check(f.calls["entities.remove"]==8,"all eight bike visuals receive removal requests")
        local pulse=event_at(f,"pulse")
        for _,name in {"follow_ack","lease_acknowledge_capture","lease_acknowledge"} do
            check(event_at(f,name)~=nil and event_at(f,name)<pulse,name.." precedes stock input")
        end
        for id=1,8 do check(event_at(f,"remove:"..id)<pulse,"visual removal "..id.." precedes stock input") end
        check(out.bike_cleanup_complete and not out.bike_authority and not out.cleanup_unknown,"the full cleanup conjunction holds")
        check(not f.core:request_mount(0) and out.used,"board return does not rearm a mount")
    end)
    case(function()
        local f=fixture("active");f.refuse_publish=true;f.follow_done=false;f:following()
        check(f.core:request_board(0),"a stopped never-published reservation accepts an explicit return")
        f:ticks(2);check(f.pulses==0 and #f.releases==0,"unacknowledged abandonment retains its body")
        f.follow_done=true
        local out=f:finish_board()
        check(out.board_return.phase=="done" and f.follow_acks==1,"abandoned Follow can drain into one return")
        check(#f.releases==1 and f.releases[1]==f.body,"abandoned Follow uses one ordinary release of its exact body")
        check(event_at(f,"follow_ack")<event_at(f,"body_release") and event_at(f,"body_release")<event_at(f,"pulse"),
            "abandoned ACK precedes body release, which precedes the stock pulse")
    end)
    case(function()
        local f=fixture("active");f:following();f.follow_done=false
        f.follow_reason="focus_changed"
        f.menu=true;f:step(100)
        check(f.core:status().stop_latched,"opening the menu can stop the bike before its return click")
        check(f.follow_reason=="focus_changed","the native first stop reason survives Core's explicit stop")
        local prior=f.core:status().receipt
        check(prior and prior.phase=="stopping" and prior.reason=="focus_changed",
            "the pre-click Lua cleanup tick cached a validated native focus-stop receipt")
        local reads=f.follow_reads
        check(f.core:request_board(0),"the explicit click remains available after that menu stop")
        check(f.follow_reads==reads,"the exact cached focus-stop receipt does not need another admission read")
        f.follow_done=true;f:ticks(2);check(f.pulses==0,"the return still waits for a closed menu")
        f.menu=false
        check(f:finish_board().board_return.phase=="done","menu-stop history does not cancel the later explicit return")
        check(f.follow_acks==1 and #f.releases==0,"sticky focus reason preserves completed Follow's exact ACK/release rules")
    end)
    case(function()
        local f=fixture("active");f:following();f.follow_done=false
        -- Native Follow stopped for the menu before Lua has had a tick to see
        -- it. The explicit Return call must inspect that receipt before stop.
        f.menu=true;f.follow_phase,f.follow_reason="stopping","focus_changed"
        check(not f.core:status().stop_latched and f.follow_stops==0,"no Lua stop or cleanup tick preceded this click")
        local reads=f.follow_reads
        check(f.core:request_board(0),"the admission read may establish an already-existing native menu stop")
        local out=f.core:status()
        check(f.follow_reads==reads+1 and out.receipt.reason=="focus_changed" and out.receipt.sequence=="41",
            "one bounded admission read binds the exact preexisting receipt and Follow sequence")
        check(out.stop_latched and f.follow_stops==1,"the observed native stop then drains through the existing owner once")
        f.follow_done=true;f:ticks(2);f.menu=false
        out=f:finish_board()
        check(out.board_return.phase=="done" and f.pulses==1 and f.follow_acks==1 and #f.releases==0,
            "a preexisting receipt permits the return while preserving completed Follow release ownership")
    end)
    case(function()
        local f=fixture("active");f:following();f.follow_done=false;f.menu=true
        local reads=f.follow_reads
        check(f.core:request_board(0),"menu-open admission observes a still-following native owner")
        local out=f.core:status()
        check(f.follow_reads==reads+1 and out.receipt.phase=="following" and out.receipt.reason=="none",
            "admission has no preexisting focus-stop evidence to bind")
        -- Deliberately later evidence: an open menu/currently restored focus
        -- cannot manufacture a pre-click reason/handle/sequence binding.
        f.follow_reason="focus_changed";f.focused=true;f:step(100)
        ended(f,"later native focus_changed cancels even though the menu was open at admission and focus is now true")
        f.follow_done=true;f.menu=false;f:ticks(45)
        check(f.pulses==0 and f.follow_acks==1 and #f.releases==0,
            "later cleanup drains the exact Follow but cannot adopt late evidence or resurrect board input")
    end)
    case(function()
        local f=fixture("active");f:following();f.follow_done=false
        check(f.core:request_board(0),"closed-menu return starts before a later native focus change")
        f.follow_reason="focus_changed";f:step(100)
        ended(f,"a native focus change is not a pre-intent menu stop for a closed-menu admission")
        f.follow_done=true;f:ticks(45)
        check(f.pulses==0 and f.follow_acks==1 and #f.releases==0,
            "refused return still drains completed Follow without double release or stock input")
    end)
    for _,fault in {"context_changed","actor_changed_park"} do case(function()
        local f=fixture("active");f:following();f.follow_done=false;f.menu=true
        check(f.core:request_board(0),"menu-open admission starts before abnormal native cleanup evidence")
        if fault=="context_changed" then f.follow_reason="context_changed" else f.park_reason="actor_changed" end
        f:step(100);ended(f,"abnormal "..fault.." is never treated as a benign menu stop")
        f.menu=false;f:ticks(10)
        check(f.pulses==0,"later ready frames cannot resurrect a return cancelled by abnormal native evidence")
    end) end
    case(function()
        local f=fixture("clean");f.menu=true
        check(f.core:request_board(0),"clean same-owner history accepts an explicit return")
        local before=f.core:status().board_return
        f:ticks(4)
        check(not f.core:request_board(1),"a second click cannot replace the active return")
        local after=f.core:status().board_return
        check(after.slot==before.slot and after.admitted_at_ms==before.admitted_at_ms and after.deadline_ms==before.deadline_ms,
            "duplicate intent keeps slot and original deadline")
        f.menu=false
        check(f:finish_board().board_return.phase=="done" and f.pulses==1,"only the first explicit return runs")
    end)
    for _,change in {"focus","menu_focus","fall","level","wipeouts","teleport"} do case(function()
        local f=fixture("active");f:following();f.follow_done=false
        if change=="menu_focus" then f.menu=true end
        check(f.core:request_board(0),"return starts before "..change.." changes during drain")
        if change=="focus" or change=="menu_focus" then f.focused=false elseif change=="fall" then f.ragdoll=true
        elseif change=="level" then f.level="other" elseif change=="wipeouts" then f.wipeouts=1 else f.teleport=true end
        f:step(16);ended(f,"transient "..change.." cancels while stop is already latched")
        f.focused,f.ragdoll,f.level,f.wipeouts,f.teleport,f.menu=true,false,"sanvan",0,false,false
        f.follow_done=true;f:ticks(45)
        check(f.pulses==0 and not f.core:status().board_return.pending,"later readiness cannot resurrect a cancelled return")
    end) end
    case(function()
        local f=fixture("active");f:following();f.follow_done=false
        f.shared.gear_admission_at=f.now-59800
        f.shared.admitted_facts={state=f.state,level=f.level,wipeouts=f.wipeouts}
        check(f.core:request_board(0,f.shared),"deferred request preserves its original still-valid admission")
        local original=f.core:status().board_return.deadline_ms
        f:ticks(2)
        ended(f,"original 60-second deadline expires while bike cleanup is still draining")
        check(f.core:status().board_return.deadline_ms==original,"drain never resets the original deadline")
        f.follow_done=true;f:ticks(45)
        check(f.pulses==0,"clearing cleanup after the deadline does not dispatch a late pulse")
    end)
    case(function()
        local f=fixture("clean");f.menu=true
        check(f.core:request_board(0),"return arms before its deadline test")
        local deadline=f.core:status().board_return.deadline_ms
        f.now=deadline-100;f.core:step(100)
        check(f.pulses==0,"open menu retains the original arm without a pulse")
        f:step(100);ended(f,"deadline ends the stock arm")
        f.menu=false;f:ticks(20);check(f.pulses==0,"expired stock arm does not resume")
    end)
    case(function()
        local f=fixture();local first=f.now
        f.on_telemetry=function() f.on_telemetry=nil;f.now+=1000 end
        check(f.core:request_board(0),"admission remains valid after a bounded facts callback delay")
        local out=f.core:status().board_return
        check(out.admitted_at_ms==first and out.deadline_ms==first+60000,
            "the first admission clock precedes callbacks; their work does not extend the intent")
        f.core:request_stop("end admission-clock test")
        f:ticks(20);check(f.pulses==0,"stopping that intent cannot dispatch later")
    end)
    case(function()
        local f,s=fixture()
        f.on_telemetry=function() f.on_telemetry=nil;f.now+=60001 end
        local owner=Runtime.new(s)
        check(not owner:request_board(0),"cold facade facts cannot consume more than the original 60-second admission window")
        local out=owner:status()
        check(not out.board_return.pending and not out.startup.pending,"expired cold admission never queues Core startup")
        for _=1,30 do f.now+=100;out=owner:step(100) end
        check(f.pulses==0 and #f.reserves==0 and not out.board_return.pending,
            "later facade ticks cannot revive the callback-expired request")
    end)
    for _,stop in {"explicit","unload","invalid_tick"} do case(function()
        local f=fixture("active");f:following();f.follow_done=false
        check(f.core:request_board(0),"return begins before "..stop)
        if stop=="explicit" then f.core:request_stop("explicit test cancellation")
        elseif stop=="unload" then f.core:unload() else f:step(300) end
        ended(f,stop.." cancels the queued return")
        f.follow_done=true;f:ticks(45)
        check(f.pulses==0,"cancelled return cannot dispatch after cleanup becomes available")
    end) end
    for _,flag in {"reserve_unknown","handoff_unknown","ride_unknown","removal_unknown","gear_unknown"} do case(function()
        local f=fixture("clean");f.shared[flag]=true
        check(not f.core:request_board(0),flag.." refuses board return")
        f:ticks(10);check(f.pulses==0,"unknown duty is never treated as complete cleanup")
    end) end
    case(function()
        local f=fixture("active");f:following();f.follow_done=false
        check(f.core:request_board(0),"return starts before cleanup acknowledgement fails")
        f.fail_follow_ack=true;f.follow_done=true;f:ticks(3)
        ended(f,"failed exact Follow ACK cancels return")
        check(f.follow_acks==1,"an uncertain acknowledgement is not retried")
        f.fail_follow_ack=false;f:ticks(20);check(f.pulses==0 and f.follow_acks==1,"later ACK readiness cannot erase retained duty")
    end)
    case(function()
        local f=fixture();f.menu=true
        check(f.core:request_board(0),"fixed direction is armed")
        f:step()
        f.state=100;f.menu=false;f:ticks(25)
        check(f.pulses==0,"a changed504 baseline cannot invert board100 back to feet504")
        check(not f.core:status().board_return.pending,"the changed baseline terminates the old return intent")
    end)
    for _,change in {"state","level","wipeouts"} do case(function()
        local f=fixture();f.menu=false
        check(f.core:request_board(0),"return arms before a final persistence callback changes "..change)
        f.on_store=function(key,record)
            if key==PROGRESS and record.phase=="watching" then
                if change=="state" then f.state=100 elseif change=="level" then f.level="other" else f.wipeouts=1 end
                f.on_store=nil
            end
        end
        f:ticks(30)
        check(f.on_store==nil,"the injected callback occurs on the pre-dispatch progress save")
        check(f.pulses==0,"the final fresh-state/context guard follows the progress callback and refuses changed "..change)
    end) end
    case(function()
        local f=fixture()
        check(f.core:request_board(0),"return arms before a final persistence callback consumes its deadline")
        local deadline=f.core:status().board_return.deadline_ms
        f.on_store=function(key,record)
            if key==PROGRESS and record.phase=="watching" then f.now=deadline;f.on_store=nil end
        end
        f:ticks(25)
        check(f.on_store==nil,"the deadline advances at the final pre-dispatch storage callback")
        ended(f,"the last clock check refuses a pulse after the original deadline")
    end)
    case(function()
        local f=fixture("clean")
        check(f.core:request_board(0),"return arms before reentrant cancellation")
        f.on_store=function(key,record)
            if key==PROGRESS and record.phase=="watching" then
                f.on_store=nil;f.core:request_stop("explicit Stop from progress callback")
            end
        end
        f:ticks(25)
        check(f.on_store==nil,"the reentrant Stop runs at the pre-pulse callback")
        ended(f,"explicit reentrant Stop cancels without a pulse")
    end)
    case(function()
        local f=fixture()
        check(f.core:request_board(0),"return starts before the final target revalidation")
        f.on_telemetry=function()
            local out=f.core:status()
            if out.board_return.pending and out.equipment.phase=="done" and out.equipment.qualified_transition then
                f.on_telemetry=nil;f.state=504
            end
        end
        local out=f:finish_board()
        check(f.on_telemetry==nil,"state changes only after the adapter has a qualified target and before Core completes")
        check(out.board_return.phase~="done" and not out.board_return.pending,
            "a historical qualified adapter target cannot replace the final fresh board100 observation")
        check(f.pulses==1 and f.pulse_acks==1,"the final readiness refusal preserves the already-clean exact report")
    end)
    case(function()
        local f=fixture()
        check(f.core:request_board(0),"first return starts")
        check(f:finish_board().board_return.phase=="done","first return has real constructed target history")
        f.state=504;f.menu=true
        check(f.core:request_board(0),"a later explicit stock return creates a fresh attempt")
        local out=f:ticks(3)
        check(out.board_return.pending and out.board_return.phase~="done" and f.pulses==1,
            "historical board target cannot complete a later fresh feet request")
        f.core:request_stop("do not dispatch the later test request")
        f.menu=false;f:ticks(20);check(f.pulses==1,"cancelled second attempt never borrows history or sends another report")
    end)
    case(function()
        local f=fixture();f.pulse_debt=true
        check(f.core:request_board(0),"return starts before held report debt")
        f:until_pulse();f.state=100
        local out=f:ticks(30)
        check(out.board_return.phase~="done" and f.pulse_acks==0 and out.equipment.retained,
            "observed board100 cannot substitute for exact pulse release and ACK")
        f.core:request_stop("cancel held report")
        f.pulse_debt=false;f:ticks(20)
        check(f.pulses==1 and f.pulse_cancels==1 and f.pulse_acks==0,"cancel preserves report cleanup duty without fabricating an ACK")
    end)
    for _,failure in {"terminal_store","pulse_ack"} do case(function()
        local f=fixture()
        if failure=="terminal_store" then f.fail_store=TERMINAL else f.fail_pulse_ack=true end
        check(f.core:request_board(0),"return starts before "..failure)
        f:until_pulse();f.state=100;local out=f:ticks(35)
        check(out.board_return.phase~="done" and not out.board_return.pending,"receipt cleanup failure cannot finish the return")
        check(f.pulses==1 and f.pulse_acks==(failure=="pulse_ack" and 1 or 0),"failed receipt storage/ACK never retries or sends a replacement")
    end) end
    case(function()
        local f=fixture("clean");f.fail_store=KEY
        local accepted=f.core:request_board(0)
        f:ticks(3)
        check(not accepted or not f.core:status().board_return.pending,"owned lifecycle storage failure closes return authority")
        check(f.pulses==0 and f.core:status().storage_fault,"storage failure cannot produce a stock action")
    end)
    case(function()
        local f=fixture();f.records[KEY]={phase="done",bike_cleanup_complete=true}
        check(not f.core:request_board(0),"a replacement owner cannot adopt even a clean serialized lifecycle marker")
        check(f.pulses==0 and f.core:status().retained_reload_marker,"stored history is not native ownership or a rearm token")
    end)
    local done,failed=0,false
    local runner={}
    function runner:step()
        assert(not failed,"board-return case failed; automatic replay is forbidden")
        if done<#cases then failed=true;cases[done+1]();done+=1;failed=false end
        return {cases=done,total_cases=#cases,assertions=assertions,native_actions=0,done=done==#cases}
    end
    return runner
end
function Tests.run()
    local runner=Tests.new_runner();local result
    repeat result=runner:step() until result.done
    return {cases=result.cases,assertions=result.assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)

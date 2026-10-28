-- Actual Core/facade/pure Recovery over constructed SDK services only.
-- Test userdata, receipt facts and shared cleanup state are fixtures; they are
-- never native actors, cleanup qualification, mounted recovery or game evidence.
local Core=require("./bike_runtime_core")
local Runtime=require("./bike_runtime")
local Services=require("./core_ride_staging_tests")
local Tests={}
local KEY="bmx_current_recovery_v1"
local function copy(v) if type(v)~="table" then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
local function receipt(status)
    local r={kind="get_up",status=status or "pending",reason="none",sequence="9007199254740994",requested_ms="1000",observed_ms="1000",
        terminal=false,native_true_calls=0,native_reset_calls=0,start_attempts=0,cleanup_attempts=0,
        true_entered=false,true_returned=false,reset_pending=false,reset_entered=false,reset_returned=false,
        reset_readback_known=false,reset_false=false,cleared_before_reset=false,unresolved=false,actor_retired=false,
        quarantined=false,standing_observed=false,stable_observed=false,standing_samples=0,standing_seconds=0,standing_required_seconds=2}
    if status=="entered" or status=="completed" then
        r.true_entered,r.true_returned,r.true_readback,r.prior_value=true,true,true,false
        r.true_ms,r.true_serial,r.true_time="1001","9007199254740995",60
        r.observed_ms,r.native_true_calls,r.start_attempts="1001",1,1
        r.reset_pending,r.unresolved=true,true
    end
    if status=="completed" then
        r.reset_false,r.reset_readback_known,r.reset_entered,r.reset_returned=true,true,true,true
        r.reset_ms,r.reset_serial,r.reset_time="1018","9007199254740996",60+1/60
        r.observed_ms,r.native_reset_calls,r.cleanup_attempts="3018",1,1
        r.reset_pending,r.unresolved=false,false
        r.terminal,r.standing_observed,r.stable_observed=true,true,true
        r.standing_samples,r.standing_seconds,r.committed_state=122,2.0166665464639664,504
        r.ragdoll,r.in_air=false,false
    end
    return r
end
local function fixture(changes,options,pristine)
    local f,s=Services.spawn_services()
    f.focused,f.menu,f.game_menu,f.allowed=true,true,false,true
    f.level,f.wipeouts,f.player,f.watch_valid="sanvan",1,true,true
    f.ragdoll,f.state=true,300
    f.native=receipt();f.recovery_handle=newproxy();f.events={};f.requests,f.polls,f.cancels,f.acks=0,0,0,0
    function s.time.now()
        if f.on_clock then f.on_clock() end
        return f.now
    end
    function s.input.focus() return {focused=f.focused,interface_open=f.menu,gameplay=true} end
    function s.input.allowed() return f.allowed end
    function s.menu.game() return {open=f.game_menu} end
    function s.level.current() return {name=f.level} end
    function s.skater.telemetry()
        if f.on_telemetry then f.on_telemetry() end
        return {skater=f.player,airborne=false,teleport_pending=false,
            watch={valid=f.watch_valid,state=f.state,ragdoll_known=true,ragdoll=f.ragdoll,wipeouts=f.wipeouts}}
    end
    function s.skater.recover()
        f.requests+=1;table.insert(f.events,"recover")
        if f.on_recover then f.on_recover() end
        if f.throw_request then error("constructed unknown request",0) end
        if f.refuse_request then return nil,"busy" end
        return f.recovery_handle
    end
    function s.skater.recovery_state(handle)
        assert(handle==f.recovery_handle,"poll keeps actual returned opaque handle")
        f.polls+=1;table.insert(f.events,"poll")
        return copy(f.native)
    end
    function s.skater.recovery_cancel(handle)
        assert(handle==f.recovery_handle,"cancel keeps exact handle")
        f.cancels+=1;table.insert(f.events,"cancel");return true
    end
    function s.storage.set(key,record)
        table.insert(f.events,"store:"..key)
        if key==KEY and f.fail_store then error("constructed terminal store failure",0) end
        f.records[key]=copy(record)
    end
    function s.skater.recovery_acknowledge(handle)
        assert(handle==f.recovery_handle,"ACK keeps exact handle")
        assert(f.records[KEY] and f.records[KEY].receipt.sequence==f.native.sequence,"full actual receipt is stored before ACK")
        f.acks+=1;table.insert(f.events,"ack")
        if f.refuse_ack then return false,"unavailable" end
        return true
    end
    function s.input.pulse(user,button)
        assert(user==0 and button=="y","post-recovery stock action is one explicit selected Y pulse")
        f.pulse_handle,f.pulse_at=newproxy(),f.now
        f.pulse_calls=(f.pulse_calls or 0)+1
        f.state=100
        return f.pulse_handle
    end
    function s.input.pulse_state(handle)
        assert(handle==f.pulse_handle,"stock receipt keeps exact pulse handle")
        return {sequence="9007199254740998",status="released",reason="none",user=0,button=0x8000,
            requested_ms=tostring(f.pulse_at),expires_ms=tostring(f.pulse_at+1000),observed_ms=tostring(f.now),source_epoch="9007199254740999",
            transport="xinput",source_identity="observed_stream",publication_scope="process_outer_xinput_buffer",consumption="unobserved",semantic_completion="unobserved",
            first_rejection_mask=0,first_rejection_stage="none",press_candidates="1",press_publications="1",neutral_publications="1",original_failures="0",contentions="0",
            terminal=true,report_debt=false,claim_released=true,actor_retired=false,orphaned=false,quarantined=false,original_result_known=false}
    end
    function s.input.pulse_cancel(handle) assert(handle==f.pulse_handle);return true end
    function s.input.pulse_acknowledge(handle) assert(handle==f.pulse_handle);return true end
    local t={phase="done",detail="Constructed positive cleanup history",used=true,active=false,bike_cleanup_complete=true,
        stop_latched=true,ledger_owned=true,level="sanvan",wipeouts=0,generation=1,cancel_version=0,arm_at=f.now,
        calls={},counts={},receipts={},omitted_calls=0,omitted_receipts=0,remove_attempted={},remove_accepted={}}
    for k,v in pairs(changes or {}) do t[k]=v end
    -- A never-mounted owner must use the real constructor defaults. The other
    -- fixtures deliberately inject completed mounted history for get-up tests.
    if pristine then t=nil end
    f.shared=t;f.core=Core.new(s,options,t)
    function f:step(ms) self.now+=ms or 17;return self.core:step(ms or 17) end
    function f:request() return self.core:request_get_up() end
    function f:start()
        assert(self:request(),"constructed complete cleanup and current fallen skater admit explicit arm")
        assert(self.requests==0,"menu click itself dispatches no native get-up")
        self.menu=false;self:step();self:step()
        assert(self.requests==1,"two fresh closed-menu observations dispatch exactly once")
        self:step();return self.core:status()
    end
    return f,s
end
function Tests.new_runner()
    local cases,assertions=0,0
    local work={}
    local function check(v,why) assertions+=1;assert(v,why) end
    table.insert(work,function()
        local f=fixture();local owner=Runtime.new({})
        check(not owner:request_get_up(),"cold facade rejects get-up without loading/effecting a bike owner")
        check(f.requests==0 and f.polls==0,"Core construction and cold facade are actuator inert")
        cases+=1
    end)
    table.insert(work,function()
        for _,change in ipairs({{bike_cleanup_complete=false},{active=true},{body=newproxy()},{follow=newproxy()},
            {handoff_unknown=true},{reserve_unknown=true},{ride_unknown=true},{gear_unknown=true},
            {cleanup_expired=true},{reload_blocked=true},{storage_fault=true},{source_armed=true}}) do
            local f=fixture(change)
            check(not f:request() and f.requests==0,"each missing cleanup barrier refuses before native recovery")
        end
        cases+=1
    end)
    table.insert(work,function()
        for _,alter in ipairs({function(f)f.player=false end,function(f)f.watch_valid=false end,
            function(f)f.ragdoll=false;f.state=504 end,function(f)f.focused=false end}) do
            local f=fixture();alter(f)
            check(not f:request() and f.requests==0,"missing or negative sampled facts cannot arm get-up")
        end
        cases+=1
    end)
    table.insert(work,function()
        local f=fixture();check(f:request(),"explicit menu arm accepted")
        for _=1,4 do f:step() end
        check(f.requests==0 and f.core:status().recovery.armed,"open menu cannot issue get-up")
        check(not f.core:request_stock_toggle(0) and not f.core:request_board(0),"armed recovery excludes stock/board transactions")
        check(not f:request(),"second menu click does not replace or extend arm")
        f.menu=false;f:step();f:step()
        check(f.requests==1,"closed menus spend original intent once")
        for _=1,4 do f:step() end
        check(f.requests==1,"pending receipt never replays native get-up")
        f.native=receipt("completed")
        local out
        for _=1,4 do out=f:step() end
        check(f.acks==1 and out.recovery.acknowledged and not out.recovery.retained,"complete stored receipt retires actual handle by one ACK")
        check(out.recovery.native_completed and out.recovery.receipt.sequence=="9007199254740994","large exact sequence and completion remain historical evidence")
        check(out.stop_latched and out.used and not out.bike_authority,"recovery cannot clear mount latch or create bike authority")
        check(not f:request() and f.requests==1,"same adapter never automatically retries even after ACK")
        cases+=1
    end)
    table.insert(work,function()
        local f=fixture();check(f:request(),"arm before Stop")
        f.core:request_stop("explicit recovery cancel");f.menu=false;f:step();f:step()
        check(f.requests==0 and not f.core:status().recovery.armed,"Stop cancels arm before any native call")
        cases+=1
    end)
    table.insert(work,function()
        local f=fixture();f:start();f.native=receipt("entered");f:step();f:step()
        f.focused=false;local o=f:step()
        check(o.recovery.retained and f.cancels==0,"focus loss cannot clear or cancel an entered native request")
        f.core:unload()
        local polls=f.polls;f:step()
        check(f.polls==polls and f.core:status().recovery.retained,"unload stops Lua calls while SDK retains entered cleanup")
        cases+=1
    end)
    table.insert(work,function()
        local f=fixture();f:start();f:step();f.focused=false;f:step()
        check(f.cancels==1,"known pending request is cancelled once after lost readiness")
        for _=1,4 do f:step() end
        check(f.cancels==1 and f.requests==1,"cancellation is never retried or treated as recovery completion")
        cases+=1
    end)
    table.insert(work,function()
        local f=fixture();f.throw_request=true;f:start()
        local o=f:step()
        check(o.recovery.retained and o.recovery.unknown and f.requests==1,"thrown request keeps unknown native duty without a handle")
        check(not f:request() and not f.core:request_board(0),"unknown request blocks replacement and stock return")
        cases+=1
    end)
    table.insert(work,function()
        local f=fixture();f.refuse_request=true;f:start();local o=f:step()
        check(not o.recovery.retained and o.recovery.phase=="request_refused","known nil refusal holds no native handle")
        check(not f:request() and f.requests==1,"known refusal is not automatically retried")
        cases+=1
    end)
    table.insert(work,function()
        local f=fixture();f.fail_store=true;f:start();f.native=receipt("completed")
        local o;for _=1,4 do o=f:step() end
        check(o.recovery.retained and o.recovery.storage_fault and f.acks==0,"terminal store failure retains handle without ACK")
        check(not f.core:request_stock_toggle(0),"storage debt cannot enable stock switching")
        cases+=1
    end)
    table.insert(work,function()
        local f=fixture();f.refuse_ack=true;f:start();f.native=receipt("completed")
        local o;for _=1,4 do o=f:step() end
        check(o.recovery.retained and f.acks==1,"refused native ACK retains debt")
        for _=1,4 do f:step() end
        check(f.acks==1 and f.requests==1,"neither ACK nor get-up is automatically retried")
        cases+=1
    end)
    table.insert(work,function()
        local f=fixture();f:start();f:step();f.native=receipt("completed");f.native.sequence="9007199254740995"
        local o;for _=1,4 do o=f:step() end
        check(o.recovery.retained and f.acks==0 and not o.recovery.native_completed,"changed exact receipt sequence cannot be acknowledged")
        cases+=1
    end)
    table.insert(work,function()
        local f=fixture();check(f:request(),"arm before original deadline")
        f.now+=60000;f.menu=false;local o=f:step()
        check(f.requests==0 and not o.recovery.armed,"original arm deadline cannot restart on menu close")
        cases+=1
    end)
    table.insert(work,function()
        local f=fixture();check(f:request(),"arm before reentrant callback")
        f.menu=false;f:step()
        f.on_telemetry=function() f.on_telemetry=nil;f.core:request_stop("stop inside recovery facts") end
        f:step()
        check(f.requests==0,"reentrant Stop during final facts prevents the native call")
        cases+=1
    end)
    table.insert(work,function()
        for _,callback in ipairs({"on_clock","on_telemetry"}) do
            local f=fixture()
            f[callback]=function() f[callback]=nil;f.core:request_stop("stop during initial recovery admission") end
            check(not f:request(),"Stop during initial clock/facts rejects the arm")
            f.menu=false;f:step();f:step()
            check(f.requests==0 and not f.core:status().recovery.armed,"cancelled initial arm cannot be deferred to later ticks")
        end
        cases+=1
    end)
    table.insert(work,function()
        local f=fixture();check(f:request(),"arm before final standing transition")
        f.menu=false;f:step()
        local reads=0
        f.on_telemetry=function()
            reads+=1
            if reads==2 then f.ragdoll=false;f.state=504 end
        end
        f:step();f:step()
        check(f.requests==0 and not f.core:status().recovery.retained,"final standing facts refuse before native get-up")
        cases+=1
    end)
    table.insert(work,function()
        for _,kind in ipairs({"stock","board"}) do
            local f=fixture();f:start();f.native=receipt("completed")
            local out;for _=1,4 do out=f:step() end
            check(out.recovery.acknowledged and not out.recovery.retained,"post-fall recovery receipt is retired before stock admission")
            f.ragdoll,f.state,f.menu=false,504,true
            local accepted
            if kind=="stock" then accepted=f.core:request_stock_toggle(0)
            else accepted=f.core:request_board(0) end
            check(accepted,"separate explicit stock/board request admits incremented current wipeout count")
            f.menu=false
            for _=1,50 do out=f:step(100) end
            check(f.pulse_calls==1 and out.phase=="done" and not out.cleanup_unknown,"stock target settles after a single confirmed report pair")
            check(f.shared.wipeouts==0 and out.stock_context.wipeouts==1,"original bike continuity stays historical; stock context is separate")
            check(out.used and out.stop_latched and not out.bike_authority,"stock return cannot rearm the bike")
            if kind=="board" then check(out.board_return.phase=="done","explicit board-return lifecycle finishes after recovery") end
        end
        cases+=1
    end)
    table.insert(work,function()
        local f=fixture(nil,{qualification_only=true},true)
        f.wipeouts,f.ragdoll,f.state=0,false,504
        check(f.core:request_stock_toggle(0),"fresh stock request binds its own initial context")
        f.menu=false
        for _=1,50 do f:step(100) end
        local before=f.core:status()
        check(before.stock_context.wipeouts==0,"completed stock history is retained")
        check(not before.used and before.initial_readiness==nil and before.arm_ms==nil,
            "actual stock-only constructor has no mounted continuity or admission clock")
        f.wipeouts,f.state=1,504
        local accepted,why=f.core:request_mount(0)
        check(accepted,"new private mount admits current upright facts after a stock-only history: "..tostring(why))
        local out=f.core:status()
        check(out.stock_context==nil and out.initial_readiness.wipeouts==1,
            "new mount clears older stock context while binding current bike continuity")
        f.core:request_stop("constructed admission case complete")
        cases+=1
    end)
    local next_case,failed=0,false
    local runner={}
    function runner:step()
        assert(not failed,"recovery case failed; automatic replay forbidden")
        if next_case<#work then failed=true;work[next_case+1]();next_case+=1;failed=false end
        return {cases=cases,total_cases=#work,assertions=assertions,native_actions=0,game_evidence=false,done=next_case==#work}
    end
    return runner
end
function Tests.run()
    local runner=Tests.new_runner();local out
    repeat out=runner:step() until out.done
    return out
end
return Tests

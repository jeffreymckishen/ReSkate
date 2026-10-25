-- Constructed regressions for the throttled lifecycle ledger. A terminal or
-- cancelled stock request must reach the storage cache before the owner goes
-- quiescent. Injected SDK-shaped services only: no Host, native body, input
-- capture or game state is involved, and no bike actuator may be reached.
local Core=require("./bike_runtime_core")
local Equipment=require("./equipment_runtime")
local tests={}
function tests.new_runner()
    local assertions=0
    local work_functions={}
    local function check(v,why) assertions+=1;assert(v,why) end
    local function copy(t) if type(t)~="table" then return t end;local o={};for k,v in t do o[k]=copy(v) end;return o end
    local KEY,PROGRESS,TERMINAL="bmx_bike_lifecycle_v1","bmx_equipment_runtime_v1","bmx_equipment_terminal_v1"
    local lease_methods={"lease","lease_read","lease_renew","lease_state","lease_release","lease_acknowledge",
        "lease_capture","lease_capture_state","lease_release_capture","lease_acknowledge_capture"}
    local function fake()
        local f={now=1000,state=504,menu=true,focused=true,gameplay=true,player=true,airborne=false,ragdoll=false,
            teleport=false,wipeouts=0,level="sanvan",records={},saves={},forbidden=0,
            calls={request=0,read=0,cancel=0,ack=0,store=0}}
        local s={time={},input={},skater={},level={},storage={},json={},menu={},entities={},world={physics={}}}
        function s.time.now() return f.now end
        function s.input.focus() return {focused=f.focused,interface_open=f.menu,gameplay=f.gameplay} end
        function s.input.allowed() return true end
        function s.menu.game() return {open=f.menu} end
        function s.skater.get()
            if f.player then return {airborne=f.airborne,position=vector.create(0,0,0),heading=0} end
        end
        function s.skater.telemetry() return {skater=f.player,airborne=f.airborne,teleport_pending=f.teleport,
            watch={valid=f.player,state=f.state,ragdoll_known=true,ragdoll=f.ragdoll,wipeouts=f.wipeouts}} end
        function s.level.current() if f.level then return {name=f.level} end end
        function s.input.pulse(slot,button)
            f.calls.request+=1;check(button=="y","stock switching requests only selected Y")
            f.handle,f.slot,f.requested=newproxy(),slot,math.floor(f.now)
            return f.handle
        end
        function s.input.pulse_state(h)
            f.calls.read+=1;check(h==f.handle,"read uses the exact returned opaque userdata")
            return {sequence="9007199254740994",status="revoked",reason="unavailable",
                user=f.slot,button=0x8000,requested_ms=tostring(f.requested),expires_ms=tostring(f.requested+1000),
                observed_ms=tostring(math.floor(f.now)),source_epoch="9007199254740995",transport="xinput",source_identity="observed_stream",
                publication_scope="process_outer_xinput_buffer",consumption="unobserved",semantic_completion="unobserved",
                first_rejection_mask=1280,first_rejection_stage="core_plan",
                press_candidates="7",press_publications="7",neutral_publications="1",original_failures="0",contentions="0",
                terminal=true,report_debt=false,claim_released=true,actor_retired=false,orphaned=false,quarantined=false,
                original_result_known=false}
        end
        function s.input.pulse_cancel(h) f.calls.cancel+=1;check(h==f.handle,"cancel never substitutes a handle");return true end
        function s.input.pulse_acknowledge(h)
            f.calls.ack+=1
            check(h==f.handle and f.records[TERMINAL]~=nil,"terminal receipt is cached before acknowledgement")
            return true
        end
        function s.json.encode() return "bounded constructed encoding" end
        function s.storage.get(key) return f.records[key] end
        function s.storage.set(key,record)
            f.calls.store+=1
            f.records[key]=copy(record)
            table.insert(f.saves,{key=key,at=f.now})
            -- The actual SDK contract is zero values, not `return true`.
        end
        -- The private qualification checks that its full API exists before it
        -- admits one intent. These cases stop before acquisition, so any call
        -- into a bike, Follow or input-lease actuator is a test failure.
        local function forbidden(name)
            return function() f.forbidden+=1;error(name.." must not be reached",0) end
        end
        for _,name in {"bounds","set","status","remove"} do s.entities[name]=forbidden("entities."..name) end
        for _,name in {"create","read","release","reserve_follow","publish_follow","read_follow","stop_follow","acknowledge_follow"} do
            s.world.physics[name]=forbidden("world.physics."..name)
        end
        for _,name in lease_methods do s.input[name]=forbidden("input."..name) end
        return f,s
    end
    local function saves(f,key,before)
        local n,last=0,nil
        for _,row in f.saves do
            if row.key==key and (before==nil or row.at<before) then n+=1;last=row.at end
        end
        return n,last
    end
    -- Constructed already-clean qualification history whose ledger this owner
    -- holds. It is not evidence of a native mount, Follow or body cleanup.
    local function clean_history()
        return {phase="done",detail="Constructed clean bike history",used=true,bike_cleanup_complete=true,
            stop_latched=true,ledger_owned=true,level="sanvan",wipeouts=0,generation=1,cancel_version=1,
            calls={},counts={},receipts={},omitted_calls=0,omitted_receipts=0,remove_attempted={},remove_accepted={}}
    end

    table.insert(work_functions, function()
        -- The one real private-ledger path in this VM: explicit intent, Stop
        -- before acquisition, cleanup, then one stock request whose 60 s arm
        -- expires 10 ms after a throttled save.
        local f,s=fake()
        local core=Core.new(s,{qualification_only=true})
        check(core:request_mount(0),"constructed private qualification admits its one intent")
        check(f.records[KEY] and f.records[KEY].phase=="armed","explicit intent saves the first ledger")
        check(core:request_stop("constructed Stop before acquisition"),"explicit Stop accepted")
        f.now+=16;local out=core:step(16)
        check(out.phase=="done" and out.bike_cleanup_complete and f.records[KEY].phase=="done",
            "stopped qualification finishes cleanup and saves done")
        local before=saves(f,KEY)
        f.now+=16;core:step(16)
        check(saves(f,KEY)==before+1,"the first quiescent tick flushes the throttled tick-end snapshot once")
        for _=1,20 do f.now+=16;core:step(16) end
        check(saves(f,KEY)==before+1,"later quiescent ticks make no further ledger saves")
        check(core:request_stock_toggle(0),"clean qualified owner accepts one stock request")
        local armed_at=f.now
        -- The menu stays open, so the stock arm can only end at its deadline.
        f.now=armed_at+59990;core:step(16)
        local open=f.records[KEY]
        check(open.phase=="stock_switching" and open.stock_requested==true and open.wall_ms==f.now,
            "reproduction precondition: a tick-end save records the open request 10 ms before its deadline")
        check(f.records[PROGRESS].phase=="armed" and f.records[PROGRESS].wall_ms==f.now,
            "reproduction precondition: equipment progress records the open arm at the same tick")
        f.now=armed_at+60000;out=core:step(16)
        check(out.phase=="done" and out.stock_requested==false and out.detail:find("ended without a qualified target",1,true)~=nil,
            "the deadline ends the stock request without a pulse")
        for _=1,60 do f.now+=16;core:step(16) end
        local stored=f.records[KEY]
        check(stored.phase=="done" and stored.stock_requested==false,
            "terminal stock record reaches storage before quiescent ticks, not stock_switching/stock_requested")
        check(stored.detail:find("ended without a qualified target",1,true)~=nil and stored.wall_ms==armed_at+60000,
            "stored terminal record is the deadline tick's own snapshot")
        local progress=f.records[PROGRESS]
        check(progress.phase=="idle" and progress.arm_started_ms==nil,
            "equipment progress records the ended arm after the owner stops updating it")
        check(f.forbidden==0 and f.calls.request==0 and f.calls.ack==0,"no bike actuator or stock pulse was reached")
    end)
    -- A qualified stock transition at several tick cadences. The tick
    -- that completes it lands within 200 ms of the previous save in at
    -- least one cadence; every cadence must still store the final record.
    local throttled=0
    local function append_cadence(cadence,final_cadence)
        local f,core,phase,baseline_steps,target_steps,quiet_steps
        table.insert(work_functions, function()
            if not phase then
                local s
                f,s=fake()
                core=Core.new(s,nil,clean_history())
                check(core:request_stock_toggle(0),"clean constructed owner accepts one stock request")
                f.menu=false
                phase,baseline_steps,target_steps,quiet_steps="baseline",0,0,0
            end
            -- Preserve the original loop caps and synthetic cadence, but let
            -- each successful callback perform at most one simulated step.
            local function step() f.now+=cadence;return core:step(cadence) end
            if phase=="baseline" then
                if f.calls.request~=1 and baseline_steps<200 then
                    step();baseline_steps+=1
                end
                if f.calls.request~=1 and baseline_steps<200 then return false end
                check(f.calls.request==1,"closed-menu neutral baseline produces one stock pulse")
                f.state=100
                phase="target"
                return false
            end
            if phase=="target" then
                local out=step();target_steps+=1
                local completed_at=out.stock_requested==false and f.now or nil
                if not completed_at and target_steps<400 then return false end
                check(completed_at and out.phase=="done" and out.detail:find("Stock target observed",1,true)~=nil,
                    "the stock target is observed and the request completes")
                local _,last=saves(f,KEY,completed_at)
                check(last~=nil,"the open request was saved before it completed")
                if completed_at-last<200 then throttled+=1 end
                phase="quiescent"
                return false
            end
            step();quiet_steps+=1
            if quiet_steps<60 then return false end
            local stored=f.records[KEY]
            check(stored.phase=="done" and stored.stock_requested==false and
                stored.detail:find("Stock target observed",1,true)~=nil,
                "completed stock record reaches storage at cadence "..cadence.." ms")
            check(f.calls.request==1 and f.calls.ack==1 and f.forbidden==0,"one pulse and one acknowledgement, no bike actuator")
            if final_cadence then
                check(throttled>0,"reproduction precondition: some completion tick fell inside the 200 ms save throttle")
            end
            return true
        end)
    end
    for index,cadence in {16,50,100,150,200} do append_cadence(cadence,index==5) end
    table.insert(work_functions, function()
        -- A refused request is saved on the next quiescent tick, after any
        -- deferred startup caller has restored the owner's phase.
        local f,s=fake()
        local core=Core.new(s,nil,clean_history())
        f.airborne=true
        check(not core:request_stock_toggle(0),"fresh airborne readiness refuses the stock request")
        check(f.records[KEY]==nil,"refusal itself writes nothing mid-request")
        f.now+=16;core:step(16)
        local stored=f.records[KEY]
        check(stored and stored.phase=="done" and stored.stock_requested==false and
            stored.detail:find("Stock request refused",1,true)~=nil,"refused stock request reaches storage")
        local n=saves(f,KEY)
        for _=1,20 do f.now+=16;core:step(16) end
        check(saves(f,KEY)==n and f.calls.request==0,"refusal flush is one save and never a pulse")
    end)
    table.insert(work_functions, function()
        -- An invalid wall tick cancels an open stock request 16 ms after a save.
        local f,s=fake()
        local core=Core.new(s,nil,clean_history())
        check(core:request_stock_toggle(0),"stock request accepted before the stalled tick")
        f.now+=300;core:step(16)
        check(f.records[KEY].phase=="stock_switching" and f.records[KEY].wall_ms==f.now,
            "reproduction precondition: the open request was saved one tick earlier")
        f.now+=16;local out=core:step(300)
        check(out.phase=="stock_stopping" and out.detail:find("invalid",1,true)~=nil,"stalled tick cancels the stock request")
        local stored=f.records[KEY]
        check(stored.phase=="stock_stopping" and stored.wall_ms==f.now,"the cancelling tick saves its own record")
        check(f.calls.request==0 and f.forbidden==0,"cancellation never pulses or reaches a bike actuator")
    end)
    table.insert(work_functions, function()
        -- The adapter alone: an arm ended by its deadline or by readiness
        -- loss inside the throttle is saved at once, because the Core stops
        -- calling update after it observes that end.
        for _,ending in {"deadline","focus"} do
            local f,s=fake();f.state=100
            local adapter=Equipment.new(s)
            check(adapter:request(0),"explicit stock arm accepted")
            local armed_at=f.now
            f.now=ending=="deadline" and armed_at+59990 or armed_at+250;adapter:update()
            check(f.records[PROGRESS].phase=="armed" and f.records[PROGRESS].wall_ms==f.now,
                "reproduction precondition: progress saved the open arm on the previous update")
            if ending=="deadline" then f.now=armed_at+60000 else f.now+=16;f.focused=false end
            local out=adapter:update()
            check(out.phase=="idle" and f.calls.request==0,"the arm ends without a pulse")
            local progress=f.records[PROGRESS]
            check(progress.phase=="idle" and progress.arm_started_ms==nil and progress.wall_ms==f.now,
                "ended arm ("..ending..") reaches progress storage on its own update")
        end
        local f,s=fake()
        local adapter=Equipment.new(s)
        for _=1,20 do f.now+=100;adapter:update() end
        check(f.calls.store==0,"an unrequested adapter still makes no storage call")
    end)
    -- Case 2 may yield incomplete work after one simulated Core step.
    -- The Core's one qualification intent per VM remains untouched.
    local completion={1,1,1,1,1,2,3,4,5}
    local completed,work_completed,failed=0,0,false
    local runner={}
    local function snapshot(work_unit_complete)
        return {cases=completed,assertions=assertions,native_actions=0,total_cases=5,
            work_units=work_completed,total_work_units=#work_functions,work_unit_complete=work_unit_complete,done=work_completed==#work_functions}
    end
    function runner:step()
        assert(not failed,"persistence case failed; automatic replay is forbidden")
        if work_completed==#work_functions then return snapshot(true) end
        failed=true
        local complete=work_functions[work_completed+1]()~=false
        if complete then
            work_completed+=1
            completed=completion[work_completed]
        end
        failed=false
        return snapshot(complete)
    end
    return runner
end
function tests.run()
    local runner=tests.new_runner()
    local result
    repeat result=runner:step() until result.done
    return {cases=result.cases,assertions=result.assertions,native_actions=result.native_actions}
end
return tests

-- Thin, actuator-inert entry owner. Cold chunks load only after explicit intent.
-- Source-only candidate: unchanged VM budgets; no performance result is claimed.
local BikeRuntime={}
local vm_attempt_used=false
local Admission
local stock_modules={"./equipment_transition","./equipment_runtime","./bike_runtime_core"}
-- One cold module per startup tick, each after everything it requires. The
-- two middle rows are Ride and Contact with their dependencies, so
-- prepare_backend binds them from cache and the first following tick imports nothing.
-- The accepted-step barspin adapter is staged before Ride; Core need not bind it.
local mount_modules={"./lease_identity","./lease_source","./force_math","./bike_geometry","./bike_visual","./bike_spawn",
    "./tire","./brake","./pump","./force_solver","./forces","./force_stage","./catalog","./input","./ride_input_mapping",
    "./frame_identity","./contact_runtime","./ride_inflight","./trick_adapter","./ride_runtime",
    "./equipment_transition","./equipment_runtime",
    "./bones","./mounted_pose", -- S2 declared change: the mounted pose, staged before Core binds it
    "./bike_runtime_core"}
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function valid_slot(v) return finite(v) and v>=0 and v<=3 and v%1==0 end
local function new_runtime(services,options,two_cycle)
    local R=services or reskate
    local qualification_only=type(options)=="table" and options.qualification_only==true
    local session_renewable=type(options)=="table" and options.session_renewable==true
    local function core_options()
        return {qualification_only=qualification_only,session_renewable=session_renewable}
    end
    local T={phase="idle",detail="Stock switching and inspection only; native bike qualification unavailable.",
        generation=0,cancel_version=0,calls={},counts={},receipts={},omitted_calls=0,omitted_receipts=0,
        remove_attempted={},remove_accepted={},experimental_attempt_limit=two_cycle and 2 or nil}
    local object={}
    local core,api,pending,running,cancelling
    local session_owner,mounts_burned,next_preparation,next_admitted_at= nil,0,false,nil
    local loaded={}
    local function status()
        if core then return core:status() end
        if Admission then return Admission.snapshot(T,qualification_only) end
        return {schema=1,kind="bike-lifecycle-v1",storage_key="bmx_bike_lifecycle_v1",phase=T.phase,detail=T.detail,
            mount_enabled=false,qualification_only=qualification_only,used=T.used==true,bike_authority=false,
            cleanup_pending=false,cleanup_unknown=false,stock_toggle_blocked=T.unloaded==true,
            unloaded=T.unloaded==true,equipment={phase="idle",retained=false,unloaded=false},qualification_ms=500,
            startup={pending=false,loaded=0,core_ready=false,backend_ready=false}}
    end
    local function cancel(why,unloading)
        if next_preparation and session_owner then session_owner:abort_preparation() end
        if pending and pending.kind=="stock" then T.startup_closed=true end
        T.cancel_version+=1;T.generation+=1
        -- A second-intent callback may cancel the old clean owner. Keep that
        -- owner's original stop/deadline history; this is not a new bike stop.
        if not (two_cycle and next_preparation and T.stop_at~=nil) then T.stop_at=T.now end
        T.stop_latched=true;T.stop_reason=why
        pending=nil;T.startup_pending=false
        if unloading and not core then T.unloaded=true end
        if core then
            if cancelling then return end
            cancelling=true
            if unloading then core:unload() else core:request_stop(why) end
            if not T.used and not T.gear_requested then
                T.phase="done";T.detail=why;T.bike_cleanup_complete=true
            end
            cancelling=false
        else
            T.phase="done"
            if T.marker_unknown or T.storage_fault or T.reload_blocked then T.phase="blocked" end
            T.detail=why;T.bike_cleanup_complete=true
            if api and T.ledger_owned and not cancelling then
                cancelling=true;api.persist();cancelling=false
            end
        end
    end
    local function admission(kind,slot,grade)
        if not valid_slot(slot) then return false,"Choose an XInput slot from0 to3" end
        if kind=="mount" and not qualification_only then return false,"Native bike lifecycle qualification unavailable" end
        if running then
            cancel("reentrant lifecycle intent during startup")
            return false,"Bike lifecycle operation already in progress"
        end
        if core and core:status().stock_toggle_blocked then
            return false,"Bike, input, equipment or retained reload cleanup blocks startup"
        end
        local clean_new_stock=kind=="stock" and T.used==true and T.bike_cleanup_complete and not T.marker_unknown
            and not T.reload_blocked and not T.storage_fault and not T.clock_unknown
        if pending or T.unloaded or T.startup_closed or T.stop_latched and not clean_new_stock or kind=="mount" and (T.used or vm_attempt_used and not (two_cycle and mounts_burned==1 and T.experimental_session==2)) then
            return false,"One attempt per VM; busy or retained duty prevents rearm"
        end
        -- Burn private admission and latch before require or any service callback.
        running=true;T.startup_pending=true
        if kind=="mount" then mounts_burned+=1;T.used=true;vm_attempt_used=true end
        local generation=T.generation
        if not Admission then
            local ok,value=pcall(require,"./bike_admission")
            if ok then Admission=value;T.startup_loaded=1;T.startup_last="./bike_admission"
            else cancel("admission module unavailable; no retry");running=false;return false,T.detail end
        end
        api=api or Admission.bind(T,R,qualification_only)
        local clear=api.marker_clear()
        if clear and generation==T.generation and not T.unloaded then
            if kind=="mount" then
                T.ledger_owned=true;T.phase="armed";T.detail="One explicit zero-force qualification intent; no native acquisition yet."
                clear=api.persist() and generation==T.generation
            end
        end
        local ok,missing=true,nil
        if kind=="mount" then ok,missing=api.available() end
        local now=clear and ok and api.clock() or nil
        T.startup_fact_read=nil -- A diagnostic may describe only this intent's existing reads.
        local observed=clear and ok and (kind=="stock" or now) and api.facts() or nil
        if now then now=api.clock() end
        local ready=Admission.ready(observed) -- Pure policy; no additional SDK observation.
        local arm_at=kind=="mount" and two_cycle and T.experimental_session==2 and next_admitted_at or now
        local accepted=clear and ok and generation==T.generation and not T.unloaded and not T.storage_fault
            and not T.clock_unknown and ready and now~=nil and finite(arm_at) and arm_at<=now and now-arm_at<60000
        T.startup_admission={kind=kind,clear=clear==true,api_available=ok==true,missing_api=missing,
            clock_present=now~=nil,generation_match=generation==T.generation,unloaded=T.unloaded==true,
            storage_fault=T.storage_fault==true,clock_unknown=T.clock_unknown==true,ready=ready==true,
            facts_present=observed~=nil,accepted=accepted==true,facts=observed,fact_read=T.startup_fact_read}
        if accepted then
            T.admitted_facts=observed;T.startup_admitted_at=arm_at
            if kind=="mount" then
                T.arm_at=arm_at;T.level=observed.level;T.wipeouts=observed.wipeouts
                T.initial_facts=observed;T.facts=observed
                accepted=api.persist() and generation==T.generation and not T.unloaded
            end
        end
        if accepted then
            pending={kind=kind,slot=slot,grade=grade,generation=generation,modules=kind=="mount" and mount_modules or stock_modules,index=1}
            T.phase="startup";T.detail="Request accepted; preparing. Stop cancels it before acquisition."
        elseif kind=="stock" and clear and generation==T.generation and not T.stop_latched
            and not T.unloaded and not T.storage_fault and not T.clock_unknown then
            -- No transaction or authority was started. A later explicit click may try fresh readiness.
            T.startup_pending=false;T.phase=T.used and T.bike_cleanup_complete and "done" or "idle"
            T.detail="Stock request refused by fresh readiness; no transaction started."
        elseif not T.reload_blocked and not T.marker_unknown then
            cancel(not ok and "Required API unavailable: "..tostring(missing) or "Startup intent refused, cancelled or readiness lost")
        else T.startup_pending=false end
        running=false
        return accepted==true,accepted and nil or T.detail
    end
    function object:status() return status() end
    function object:playable_grade_policy()
        return qualification_only and session_renewable and "measured_plane_grade_v1" or nil
    end
    function object:request_mount(slot,grade)
        if grade~=nil and (not qualification_only or not session_renewable or type(grade)~="table"
            or getmetatable(grade)~=nil or not table.isfrozen(grade) or grade.policy~="measured_plane_grade_v1"
            or type(grade.origin)~="table" or not table.isfrozen(grade.origin)
            or type(grade.actor_position)~="table" or not table.isfrozen(grade.actor_position)) then
            return false,"Closed immutable playable grade required"
        end
        if not valid_slot(slot) then return false,"Choose an XInput slot from0 to3" end
        if not qualification_only then return false,"Native bike lifecycle qualification unavailable" end
        if core and T.backend_ready and not pending then
            if running then cancel("reentrant mount request");return false,"Bike lifecycle operation already in progress" end
            if two_cycle and mounts_burned==1 and next_preparation and session_owner then
                local version=T.generation
                local now=next_admitted_at~=nil and api.clock() or nil
                if T.unloaded or T.startup_closed or T.generation~=version or not next_preparation or
                    next_admitted_at~=nil and (not now or now<next_admitted_at or now-next_admitted_at>=60000) then
                    T.startup_closed=true;return false,"Original second Mount admission expired or changed"
                end
                running=true
                local next_state={phase="idle",detail="Second bounded fresh-allocation session.",generation=0,cancel_version=0,
                    calls={},counts={},receipts={},omitted_calls=0,omitted_receipts=0,remove_attempted={},remove_accepted={},
                    experimental_session=2,experimental_attempt_limit=2}
                local successor,why=session_owner:successor(R,core_options(),next_state)
                if not successor then running=false;T.startup_closed=true;return false,why end
                T=next_state;core=successor;api=Admission.bind(T,R,qualification_only)
                T.core_ready=true;T.backend_ready=false;next_preparation=false
                running=false
            elseif vm_attempt_used then return false,"One attempt per VM; busy or retained duty prevents rearm" end
        end
        return admission("mount",slot,grade)
    end
    function object:can_prepare_next_mount()
        if not two_cycle or running or pending or T.unloaded or T.startup_closed or mounts_burned~=1
            or next_preparation or not session_owner then return false,"No clean successor available" end
        return session_owner:can_archive_return()
    end
    function object:prepare_next_mount(slot,admitted_at_ms)
        if not two_cycle or not valid_slot(slot) or running or pending or T.unloaded or T.startup_closed
            or mounts_burned~=1 or next_preparation or not session_owner or not core then
            return false,"Second preparation unavailable"
        end
        -- Entry may wait for its Mount chord to release before admission. Keep
        -- that same intent's original arm deadline rather than starting it again.
        if admitted_at_ms~=nil then
            local now=api.clock()
            if not finite(admitted_at_ms) or admitted_at_ms<0 or admitted_at_ms%1~=0
                or not now or admitted_at_ms>now or now-admitted_at_ms>=60000 then
                T.startup_closed=true;return false,"Original second Mount admission expired"
            end
        end
        -- Intent two is spent before archive/stock callbacks. Any failure closes
        -- it permanently; no fresh facade or reset can recover this admission.
        next_preparation=true;next_admitted_at=admitted_at_ms;running=true
        local ok,why=session_owner:archive_return()
        if not ok then T.startup_closed=true;running=false;return false,why end
        local previous=T.gear_admission_at
        T.gear_admission_at=admitted_at_ms
        local called,accepted,reason=pcall(core.request_stock_toggle,core,slot)
        T.gear_admission_at=previous;running=false
        if not called or accepted~=true then
            T.startup_closed=true;return false,called and reason or "Second preparation raised; cleanup required"
        end
        return true
    end
    function object:next_mount_ready()
        if not two_cycle or not next_preparation or running or pending or T.unloaded or T.startup_closed then
            return false,"Second preparation unavailable"
        end
        running=true
        local ok,why=session_owner:ready()
        running=false
        if not ok and why~="pending" then T.startup_closed=true end
        return ok,why
    end
    function object:second_preflight_ready(admitted_at_ms)
        if not two_cycle or not qualification_only or running or pending or T.unloaded or T.startup_closed
            or mounts_burned~=1 or not next_preparation or not session_owner or not core or not api
            or not finite(next_admitted_at) or admitted_at_ms~=next_admitted_at then
            return false,"No unrequested second terrain preflight remains"
        end
        local version=T.generation
        running=true
        local out=table.pack(pcall(function()
            local now=api.clock()
            if not now or now<next_admitted_at or now-next_admitted_at>=60000 then
                return false,"Original second Mount admission expired"
            end
            -- ready() retains full old body/Follow/Source/pose/board cleanup,
            -- NEW504 terminal ACK and fresh same-context readiness predicates.
            local ok,why=session_owner:ready()
            if not ok then return false,why end
            local after=api.clock()
            if T.generation~=version or T.unloaded or T.startup_closed or pending or mounts_burned~=1 or not next_preparation
                or not after or after<next_admitted_at or after-next_admitted_at>=60000 then
                return false,"Second terrain preflight changed or expired"
            end
            return true,why
        end))
        running=false
        if not out[1] or out.n~=3 or out[2]~=true or not finite(out[3]) or out[3]%1~=0 or out[3]<2 then
            if not out[1] or out[3]~="pending" then T.startup_closed=true end
            return false,out[1] and out[3] or "Second terrain proof raised; no retry"
        end
        return true,out[3]
    end
    function object:request_stock_toggle(slot)
        if core and not pending then
            if running then cancel("reentrant stock request");return false,"Bike lifecycle operation already in progress" end
            running=true;local result=table.pack(core:request_stock_toggle(slot));running=false
            return table.unpack(result,1,result.n)
        end
        return admission("stock",slot)
    end
    function object:request_return()
        if T.unloaded or running or pending or not core or type(core.request_return)~="function" then
            return false,"Live Return owner unavailable"
        end
        running=true;local result=table.pack(pcall(core.request_return,core));running=false
        if not result[1] then return false,"Live Return raised; ordinary cleanup is still required" end
        return table.unpack(result,2,result.n)
    end
    function object:request_stop(why)
        if next_preparation and session_owner then session_owner:abort_preparation() end
        if T.unloaded then return false,"Runtime is unloaded; SDK retains cleanup" end
        if core and not pending then
            local outer=running;running=true;local result=table.pack(core:request_stop(why));running=outer
            return table.unpack(result,1,result.n)
        end
        if pending or T.startup_pending then cancel(type(why)=="string" and #why>0 and #why<=200 and why or "explicit Stop") end
        return true
    end
    local function startup_tick(dt)
        local intent=pending
        if not finite(dt) or dt<=0 or dt>250 then cancel("invalid startup wall tick") end
        if pending then
            local now=api.clock()
            if not now or now-T.startup_admitted_at>=60000 then cancel("startup intent expired before acquisition")
            elseif T.startup_last_step_at and now<=T.startup_last_step_at then cancel("stalled or reversed startup wall tick")
            else T.startup_last_step_at=now end
        end
        if pending then
            local observed=api.facts()
            if not Admission.ready(observed) or not Admission.matches(T.admitted_facts,observed) then
                cancel("sampled startup readiness or bound direction changed")
            end
        end
        if pending and intent.generation==T.generation and not T.unloaded then
            while intent.index<=#intent.modules and loaded[intent.modules[intent.index]] do intent.index+=1 end
            local name=intent.modules[intent.index]
            if name then
                local ok,value=pcall(require,name)
                if not ok then cancel("startup dependency unavailable; no retry")
                elseif pending and intent.generation==T.generation then
                    loaded[name]=value;intent.index+=1
                    T.startup_loaded=(T.startup_loaded or 0)+1;T.startup_last=name
                    if name=="./bike_runtime_core" and not core then
                        if two_cycle then
                            session_owner=value.experimental_two_cycle_owner()
                            if not session_owner then cancel("private two-cycle owner unavailable");return end
                            T.experimental_session=1
                            core=session_owner:first(R,core_options(),T)
                            if not core then cancel("first private Core unavailable");return end
                        else core=value.new(R,core_options(),T) end
                        T.core_ready=true
                        T.core_instances=(T.core_instances or 0)+1
                    end
                end
            elseif intent.kind=="mount" and not T.backend_ready then
                if core:prepare_backend() then T.backend_ready=true else cancel("private backend preparation refused") end
            else
                pending=nil;T.startup_pending=false;T.startup_handoff=true
                T.gear_admission_at=math.floor(T.startup_admitted_at)
                local accepted,why
                if intent.kind=="mount" then
                    if intent.grade then accepted,why=core:request_mount(intent.slot,T,intent.grade)
                    else accepted,why=core:request_mount(intent.slot,T) end
                else accepted,why=core:request_stock_toggle(intent.slot,T) end
                T.startup_handoff=false;T.gear_admission_at=nil
                if not accepted and T.phase=="startup" then
                    T.phase=T.used and T.bike_cleanup_complete and "done" or "idle"
                    T.detail=why or "Deferred request refused"
                end
            end
        end
    end
    function object:step(dt)
        if running then cancel("reentrant lifecycle step");return status() end
        if not pending then
            if core then running=true;local result=core:step(dt);running=false;return result end
            return status()
        end
        running=true
        local ok=pcall(startup_tick,dt)
        if not ok then
            T.startup_handoff=false;T.gear_admission_at=nil
            cancel("startup exception; no retry")
        end
        running=false
        local result=status()
        result.startup=result.startup or {}
        result.startup.work_this_tick=true -- Detached scheduling fact: this step began with a pending intent.
        return result
    end
    function object:unload()
        if next_preparation and session_owner then session_owner:abort_preparation() end
        if T.unloaded then return status() end
        if core and not pending then local outer=running;running=true;local result=core:unload();running=outer;return result end
        cancel("unload before startup; no game authority acquired",true)
        return status()
    end
    return table.freeze(object)
end
function BikeRuntime.new(services,options)
    return new_runtime(services,options,false)
end
local experimental_manager_created=false
function BikeRuntime.new_experimental_two_cycle(services,options)
    if experimental_manager_created or vm_attempt_used then return nil,"VM already has a manager or consumed mount" end
    experimental_manager_created=true
    return new_runtime(services,options,true)
end
return table.freeze(BikeRuntime)
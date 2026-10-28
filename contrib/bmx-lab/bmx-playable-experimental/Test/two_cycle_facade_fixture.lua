return function(require)
-- Thin, actuator-inert entry owner. Cold chunks load only after explicit intent.
-- Source-only candidate: unchanged VM budgets; no performance result is claimed.
local BikeRuntime={}
local vm_attempt_used=false
local Admission
local stock_modules={"./equipment_transition","./equipment_runtime","./bike_runtime_core"}
-- One cold module per startup tick, each after everything it requires. The
-- two middle rows are Ride and Contact with their dependencies, so
-- prepare_backend binds them from cache and the first following tick imports nothing.
-- The trick adapter is not staged; Core passes none.
local mount_modules={"./lease_identity","./lease_source","./force_math","./bike_geometry","./bike_visual","./bike_spawn",
    "./tire","./brake","./pump","./force_solver","./forces","./force_stage","./catalog","./input","./ride_input_mapping",
    "./frame_identity","./contact_runtime","./ride_inflight","./ride_runtime",
    "./equipment_transition","./equipment_runtime",
    "./bones","./mounted_pose", -- S2 declared change: the mounted pose, staged before Core binds it
    "./bike_runtime_core"}
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function valid_slot(v) return finite(v) and v>=0 and v<=3 and v%1==0 end
local function new_runtime(services,options,two_cycle)
    local R=services or reskate
    local qualification_only=type(options)=="table" and options.qualification_only==true
    local T={phase="idle",detail="Stock switching and inspection only; native bike qualification unavailable.",
        generation=0,cancel_version=0,calls={},counts={},receipts={},omitted_calls=0,omitted_receipts=0,
        remove_attempted={},remove_accepted={},experimental_attempt_limit=two_cycle and 2 or nil}
    local object={}
    local core,api,pending,running,cancelling
    local session_owner,mounts_burned,next_preparation= nil,0,false
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
    local function admission(kind,slot)
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
        local observed=clear and ok and (kind=="stock" or now) and api.facts() or nil
        if now then now=api.clock() end
        local accepted=clear and ok and generation==T.generation and not T.unloaded and not T.storage_fault
            and not T.clock_unknown and Admission.ready(observed) and now~=nil
        if accepted then
            T.admitted_facts=observed;T.startup_admitted_at=now
            if kind=="mount" then
                T.arm_at=now;T.level=observed.level;T.wipeouts=observed.wipeouts
                T.initial_facts=observed;T.facts=observed
                accepted=api.persist() and generation==T.generation and not T.unloaded
            end
        end
        if accepted then
            pending={kind=kind,slot=slot,generation=generation,modules=kind=="mount" and mount_modules or stock_modules,index=1}
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
    function object:request_mount(slot)
        if not valid_slot(slot) then return false,"Choose an XInput slot from0 to3" end
        if not qualification_only then return false,"Native bike lifecycle qualification unavailable" end
        if core and T.backend_ready and not pending then
            if running then cancel("reentrant mount request");return false,"Bike lifecycle operation already in progress" end
            if two_cycle and mounts_burned==1 and next_preparation and session_owner then
                running=true
                local next_state={phase="idle",detail="Second bounded fresh-allocation session.",generation=0,cancel_version=0,
                    calls={},counts={},receipts={},omitted_calls=0,omitted_receipts=0,remove_attempted={},remove_accepted={},
                    experimental_session=2,experimental_attempt_limit=2}
                local successor,why=session_owner:successor(R,{qualification_only=qualification_only},next_state)
                if not successor then running=false;T.startup_closed=true;return false,why end
                T=next_state;core=successor;api=Admission.bind(T,R,qualification_only)
                T.core_ready=true;T.backend_ready=false;next_preparation=false
                running=false
            elseif vm_attempt_used then return false,"One attempt per VM; busy or retained duty prevents rearm" end
        end
        return admission("mount",slot)
    end
    function object:can_prepare_next_mount()
        if not two_cycle or running or pending or T.unloaded or T.startup_closed or mounts_burned~=1
            or next_preparation or not session_owner then return false,"No clean successor available" end
        return session_owner:can_archive_return()
    end
    function object:prepare_next_mount(slot)
        if not two_cycle or not valid_slot(slot) or running or pending or T.unloaded or T.startup_closed
            or mounts_burned~=1 or next_preparation or not session_owner or not core then
            return false,"Second preparation unavailable"
        end
        -- Intent two is spent before archive/stock callbacks. Any failure closes
        -- it permanently; no fresh facade or reset can recover this admission.
        next_preparation=true;running=true
        local ok,why=session_owner:archive_return()
        if not ok then T.startup_closed=true;running=false;return false,why end
        local accepted,reason=core:request_stock_toggle(slot)
        running=false
        if not accepted then T.startup_closed=true;return false,reason end
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
    function object:request_stock_toggle(slot)
        if core and not pending then
            if running then cancel("reentrant stock request");return false,"Bike lifecycle operation already in progress" end
            running=true;local result=table.pack(core:request_stock_toggle(slot));running=false
            return table.unpack(result,1,result.n)
        end
        return admission("stock",slot)
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
                            core=session_owner:first(R,{qualification_only=qualification_only},T)
                            if not core then cancel("first private Core unavailable");return end
                        else core=value.new(R,{qualification_only=qualification_only},T) end
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
                if intent.kind=="mount" then accepted,why=core:request_mount(intent.slot,T)
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
end

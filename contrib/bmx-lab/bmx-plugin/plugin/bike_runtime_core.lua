-- One Lua owner for stock switching and a private, fixed zero-force qualification.
-- Require/new are inert. Public mounting remains unavailable: native park and
-- attachment qualification are unresolved. No riding/consumption claim is made.
local EquipmentRuntime=require("./equipment_runtime")
local Admission=require("./bike_admission")
local BikeRuntime={}
local vm_attempt_used=false
local KEY="bmx_bike_lifecycle_v1"
local MAX=9007199254740991
-- Source proposal only. No option, public request or manifest can open this.
-- The separate Ride469D activation literal also remains false.
local RIDE_COMPOSITION_QUALIFIED=false
local receipt_revisions={"final_revision","final_native_epoch","returned_revision"}
local receipt_flags={"claim_known","orphaned","park_observed","native_retirement_known","terminal"}

function BikeRuntime.new(services,options,shared_state)
local supplied=services or reskate
local R=type(supplied)=="table" and supplied or {}
local qualification_only=type(options)=="table" and options.qualification_only==true
local T=shared_state or {phase="idle",detail="Stock switching and inspection only; native bike qualification unavailable.",
    generation=0,cancel_version=0,calls={},counts={},receipts={},omitted_calls=0,omitted_receipts=0,
    remove_attempted={},remove_accepted={}}
local object={}
local stop_all,latch_stop,source,spawn,equipment,facts,closed_ready,snapshot,flush_removals
local ride,ride_binding,selected_source_frame,stop_ride,drain_ride,observe_ride
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function short(v) return type(v)=="string" and v:gsub("[%c]"," "):sub(1,180) or "unavailable or malformed result" end
local function reason(v) return type(v)=="string" and #v>0 and #v<=200 end
local function lookup(path)
    local value=R
    for part in path:gmatch("[^.]+") do value=type(value)=="table" and value[part] or nil end
    return type(value)=="function" and value or nil
end
local function event(name, result)
    T.counts[name]=(T.counts[name] or 0)+1
    local row={call=name,at_ms=T.now,called=result[1]==true,returns=result[1] and result.n-1 or 0,
        first_type=typeof(result[2])}
    if type(result[2])=="boolean" then row.accepted=result[2] end
    if type(result[3])=="string" then row.reason=short(result[3]) end
    if not result[1] then row.error=short(result[2]) end
    if #T.calls==64 then table.remove(T.calls,1);T.omitted_calls+=1 end
    table.insert(T.calls,row)
end
local function call(name, fn, ...)
    local result=table.pack(pcall(fn,...))
    event(name,result)
    return result
end
local function yes(r) return r[1]==true and r.n==2 and r[2]==true end
local function current(g) return not T.stop_latched and not T.unloaded and T.generation==g end
local function clock()
    local r=call("time.now",lookup("time.now"))
    local value=r[2]
    if not r[1] or r.n~=2 or not finite(value) or value<0 or value>MAX or T.now and value<T.now then
        T.clock_unknown=true
        if stop_all then stop_all("invalid or reversed Lua wall clock") end
        return nil
    end
    T.now=value
    return value
end
local function plain(value, depth, budget)
    local kind=type(value)
    if kind=="nil" or kind=="boolean" then return value end
    if kind=="number" then assert(finite(value),"nonfinite diagnostic");return value end
    if kind=="string" then assert(#value<=1200,"oversized diagnostic");return value end
    assert(kind=="table" and depth<8,"opaque or deep diagnostic refused")
    local out={}
    for k,v in pairs(value) do
        budget.n+=1;assert(budget.n<=3000,"diagnostic field limit")
        assert(type(k)=="string" or type(k)=="number" and finite(k),"invalid diagnostic key")
        out[k]=plain(v,depth+1,budget)
    end
    return out
end
local function copied(value) return plain(value,0,{n=0}) end
local function source_record(f,defer_copy)
    if type(f)~="table" then return nil end
    -- Opaque lease handles and private input epochs never enter the storage DTO.
    local record={phase=f.phase,reason=f.reason,input_ok=f.input_ok,new_observation=f.new_observation,
        generation=f.generation,lease_handle_present=f.lease_handle~=nil,cleanup_pending=f.cleanup_pending,cleanup_unknown=f.cleanup_unknown,
        sample=f.sample,lease_state=f.lease_state,capture_state=f.capture_state}
    -- snapshot immediately validates and detaches the whole DTO with copied;
    -- its source subtree need not be recursively copied twice. Stored step
    -- records still take their own copy and never retain dependency state.
    return defer_copy and record or copied(record)
end
local function status_of(object)
    if not object then return nil end
    local ok,value=pcall(object.status,object)
    return ok and type(value)=="table" and value or nil
end
local function force_clear()
    if T.ride_unknown==true then return false end
    if not ride_binding then return T.ride_construct_attempted~=true end
    if ride_binding.inflight or ride_binding.unknown or ride_binding.sequence then return false end
    local row=T.ride_status
    -- This is only the subordinate's local force ledger gate. Native body,
    -- Follow, Source and equipment still require their independent conjunction.
    return type(row)=="table" and row.force_pending==false and row.unknown==false
end
local function source_clean(read_status)
    local f=(read_status or status_of)(source)
    return f and f.phase=="complete" and f.lease_handle==nil and f.cleanup_pending==false and f.cleanup_unknown==false
end
local function visuals_accepted()
    for id=1,8 do if not T.remove_attempted[id] or not T.remove_accepted[id] then return false end end
    return true
end
local function spawn_cleanup_allowed()
    -- Unknown handoff/reservation results can hide SDK ownership even without a handle.
    if not force_clear() or T.handoff_unknown or T.reserve_unknown or T.follow then return false end
    if T.transferred then
        return T.completed_ack==true and T.acknowledged==true
            or T.release_accepted==true and not T.published_seen
    end
    return not T.reserve_attempted and not T.publish_attempted and not T.published_seen
end
local function stop_spawn_when_allowed(why)
    if not spawn then return end
    T.visual_cleanup_deferred=not spawn_cleanup_allowed()
    if T.visual_cleanup_deferred then return end
    -- Removal can advance the native entity lifetime stamp. Keep visuals frozen
    -- while Follow still needs that same lifetime to observe park and complete.
    call("spawn.stop",spawn.stop,spawn,why)
    if flush_removals then flush_removals() end
end

local function equipment_clear(read_status)
    local e=(read_status or status_of)(equipment)
    return e and not e.retained and not e.unloaded and (e.phase=="idle" or e.phase=="done")
end
local function source_clear(read_status)
    if not source then return not T.source_armed end
    local read=read_status or status_of
    local s=read(source)
    return s and (not T.source_armed and s.phase=="idle" or source_clean(read))
end
local function unknown_duty(read_status)
    local read=read_status or status_of
    local s=read(source);local b=read(spawn);local e=read(equipment)
    return T.reload_blocked==true or T.marker_unknown==true or T.storage_fault==true or T.clock_unknown==true
        or T.handoff_unknown==true or T.reserve_unknown==true or T.gear_unknown==true
        or T.cleanup_expired==true or T.protocol_unknown==true or T.ride_unknown==true
        or T.stop_latched==true and not force_clear()
        or T.ack_attempted==true and T.acknowledged~=true
        or T.release_attempted==true and T.release_accepted~=true
        or s and s.cleanup_unknown==true or b and (b.cleanup_unknown==true or b.creation_unknown==true)
        or e and e.outcome=="unresolved" or T.removal_unknown==true
end
local function stock_blocked(read_status)
    if T.unloaded or T.busy or T.gear_requested or T.startup_pending or T.startup_closed or unknown_duty(read_status) then return true end
    local e=(read_status or status_of)(equipment)
    if e and e.storage_fault==true then return true end
    if not force_clear() or not equipment_clear(read_status) or not source_clear(read_status) then return true end
    if T.intent_inflight or T.active or T.follow or T.body or T.handoff_unknown or T.reserve_unknown then return true end
    if T.used and T.phase~="done" and not T.startup_handoff then return true end
    return false
end
snapshot=function()
    -- These dependency status methods read only local cached state. Reuse one
    -- detached observation inside this diagnostic copy, never across a call,
    -- tick or actuator callback. Authority helpers keep their ordinary reader.
    local s,b,e=status_of(source),status_of(spawn),status_of(equipment)
    local function read_cached(object)
        if object==source then return s end
        if object==spawn then return b end
        if object==equipment then return e end
        return nil
    end
    return copied({schema=1,kind="bike-lifecycle-v1",storage_key=KEY,
        mount_enabled=false,qualification_only=qualification_only,used=T.used==true,
        bike_authority=T.active==true or T.follow~=nil or T.body~=nil or T.handoff_unknown==true or T.reserve_unknown==true,
        cleanup_pending=T.stop_latched==true and not T.bike_cleanup_complete or T.gear_requested==true
            or T.reload_blocked==true or T.marker_unknown==true,
        cleanup_unknown=unknown_duty(read_cached)==true,stock_toggle_blocked=stock_blocked(read_cached),
        retained_reload_marker=T.reload_blocked==true,marker_unknown=T.marker_unknown==true,
        bike_cleanup_complete=T.bike_cleanup_complete==true,
        stock_requested=T.gear_requested==true,equipment_purpose=T.gear_purpose,
        native_follow_lease_ms=3000,qualification_ms=500,one_attempt_per_vm=true,retained_body_slot_limit=8,
        limit_scope="Eight retained native body slots may already be exhausted; not a retry budget. No Follow renewal or body reuse.",
        source_freshness_scope="Existing selected-input lease renewal only; no Follow lifetime extension.",
        phase=T.phase,detail=T.detail,selected_slot=T.slot,wall_ms=T.now,arm_ms=T.arm_at,
        effect_start_ms=T.effect_at,stop_ms=T.stop_at,stop_reason=T.stop_reason,
        stop_latched=T.stop_latched==true,unloaded=T.unloaded==true,clock_unknown=T.clock_unknown==true,
        storage_fault=T.storage_fault==true,readiness=T.facts,initial_readiness=T.initial_facts,
        capture_attempted=T.capture_attempted==true,source=source_record(s,true),last_source_step=T.source_record,
        spawn=b,equipment=e,
        ride_composition_qualified=RIDE_COMPOSITION_QUALIFIED,ride=T.ride_status,
        force_cleanup_clear=force_clear(),force_cleanup_unknown=T.ride_unknown==true,
        handoff_attempted=T.handoff_attempted==true,body_transferred=T.transferred==true,
        handoff_unknown=T.handoff_unknown==true,reserve_attempted=T.reserve_attempted==true,
        reserve_unknown=T.reserve_unknown==true,reserve_refused=T.reserve_refused==true,
        sequence=T.sequence,publish_attempted=T.publish_attempted==true,published_seen=T.published_seen==true,
        follow_stop_attempted=T.follow_stop_attempted==true,follow_stop_accepted=T.follow_stop_accepted==true,
        receipt=T.receipt,terminal_receipt=T.terminal,receipt_history=T.receipts,omitted_receipts=T.omitted_receipts,
        acknowledge_attempted=T.ack_attempted==true,acknowledged=T.acknowledged==true,
        completed_acknowledged=T.completed_ack==true,ordinary_release_attempted=T.release_attempted==true,
        ordinary_release_accepted=T.release_accepted==true,visual_remove_attempted=T.remove_attempted,
        visual_remove_call_accepted=T.remove_accepted,visual_cleanup_deferred=T.visual_cleanup_deferred==true,
        calls=T.calls,call_counts=T.counts,omitted_calls=T.omitted_calls,
        equipment_storage_prefix="",ledger_limit_bytes=48000,call_history_limit=64,
        follow_history_limit=16,follow_read_limit=400,
        startup={pending=T.startup_pending==true,loaded=T.startup_loaded or 0,last_module=T.startup_last,
            core_ready=T.core_ready==true,backend_ready=T.backend_ready==true,
            core_instances=T.core_instances or 0,equipment_instances=T.equipment_instances or 0,
            source_instances=T.source_instances or 0,spawn_instances=T.spawn_instances or 0},
        geometry_scope="Original actor+3m/+0.5m spawn; COM attachment and anchor remain unqualified",
        evidence_scope="Host storage cache acceptance only; no disk durability, native consumption or mounted success inferred"})
end
local function persist(force)
    if not T.ledger_owned or T.saving or T.storage_fault then return false end
    if not force and T.saved_at and T.now and T.now-T.saved_at<200 then
        -- A quiescent tick makes no later tick-end save; it flushes this once.
        T.persist_dirty=true;return true
    end
    T.saving=true
    local ok,record=pcall(snapshot)
    local encoded=ok and call("json.encode",lookup("json.encode"),record) or nil
    local accepted=false
    if encoded and encoded[1] and encoded.n==2 and type(encoded[2])=="string" and #encoded[2]<=48000 then
        local stored=call("storage.set",lookup("storage.set"),KEY,record)
        accepted=stored[1]==true and stored.n==1 -- Actual API returns zero values; this is not a durability proof.
    end
    T.saving=false
    if accepted then T.saved_at=T.now;T.persist_dirty=false;return true end
    T.storage_fault=true
    if stop_all then stop_all("ledger cache failed; no retry or replacement") end
    return false
end
local function follow_stop_once()
    if not T.follow or T.follow_stop_attempted then return end
    T.follow_stop_attempted=true
    local r=call("follow.stop",lookup("world.physics.stop_follow"),T.follow)
    T.follow_stop_accepted=yes(r)
end
latch_stop=function(why)
    if not T.stop_latched then
        T.stop_latched=true;T.generation+=1;T.stop_at=T.now;T.stop_reason=short(why)
        T.phase="stopping";T.detail=T.stop_reason;T.stop_needs_cleanup=true
        -- Pure local Ride stop precedes any reentrant Follow/Source callback.
        if stop_ride then stop_ride(T.stop_reason) end
    end
end
stop_all=function(why)
    latch_stop(why)
    T.cancel_version+=1
    if T.bike_cleanup_complete and T.gear_requested then
        T.phase="stock_stopping";T.detail=short(why)
    end
    if T.cleanup_busy then return end
    T.cleanup_busy=true
    -- Stop known follow FIRST, before Source can release capture or another body read occurs.
    follow_stop_once()
    if T.source_inflight then T.cleanup_busy=false;return end
    if source then call("source.stop",source.stop,source,T.stop_reason) end
    stop_spawn_when_allowed(T.stop_reason)
    if equipment and T.gear_requested and not T.gear_cancelled then
        T.gear_cancelled=true
        call("equipment.unload",equipment.unload,equipment)
    end
    T.stop_needs_cleanup=false
    T.cleanup_busy=false
end

local function removal_allowed()
    if not force_clear() then return false end
    if T.transferred then
        return spawn_cleanup_allowed()
    end
    local b=status_of(spawn)
    return b and not b.creation_unknown and not b.cleanup_unknown and not b.body
        and (b.creation_attempts==0 or T.spawn_release_accepted==true or T.preallocation_refused==true)
end
local function remove_once(id)
    if T.remove_attempted[id] then return end
    T.remove_attempted[id]=true
    local r=call("entities.remove",lookup("entities.remove"),id)
    T.remove_accepted[id]=r[1]==true and r.n==1
    if not T.remove_accepted[id] then T.removal_unknown=true end
end
flush_removals=function()
    if not T.deferred_removals then return end
    if not removal_allowed() then T.visual_cleanup_deferred=true;return end
    T.visual_cleanup_deferred=false
    for id=1,8 do if T.deferred_removals[id] then remove_once(id) end end
end
local input_proxy={}
local input_methods={"lease","lease_read","lease_renew","lease_state","lease_release","lease_acknowledge",
    "lease_capture","lease_capture_state","lease_release_capture","lease_acknowledge_capture"}
for _,method in ipairs(input_methods) do
    local name=method
    input_proxy[name]=function(...)
        if T.stop_latched and name=="lease" then return nil,"bike lifecycle cancelled before lease acquisition" end
        if T.stop_latched and name=="lease_renew" then return false,"bike lifecycle cancelled before lease renewal" end
        if name=="lease_release" or name=="lease_release_capture" then
            latch_stop("input source began cleanup")
            follow_stop_once()
        end
        if name=="lease_capture" then
            if T.capture_attempted or T.stop_latched then latch_stop("second or cancelled capture attempt refused");return false,"one-shot capture only" end
            T.capture_attempted=true
        end
        local r=call("input."..name,lookup("input."..name),...)
        -- Let Source classify known false versus unknown before outer cleanup.
        if name=="lease_capture" and not yes(r) then latch_stop("capture refusal, exception or malformed result") end
        if not r[1] then error("input "..name.." callback failed",0) end
        return table.unpack(r,2,r.n)
    end
end
local Identity,G
local spawn_api={input=R.input,skater=R.skater,world={physics={}},entities={}}
for _,method in ipairs({"create","read","release"}) do
    local name=method
    spawn_api.world.physics[name]=function(...)
        if name~="release" and T.stop_latched then return nil,"bike lifecycle cancelled before spawn body operation" end
        if name=="release" and T.transferred then return false,"spawn no longer owns body release" end
        local r=call("spawn.body."..name,lookup("world.physics."..name),...)
        if name=="create" and r[1] and r.n==3 and r[2]==nil
            and r[3]=="waiting for a fresh qualified 60 Hz physics step" then
            T.preallocation_refused=true
        end
        if name=="release" then
            T.spawn_release_accepted=yes(r)
            if not T.spawn_release_accepted then T.protocol_unknown=true end
        end
        if not r[1] then error("spawn body "..name.." callback failed",0) end
        return table.unpack(r,2,r.n)
    end
end
for _,method in ipairs({"bounds","set","status","remove"}) do
    local name=method
    spawn_api.entities[name]=function(...)
        if name=="set" and T.stop_latched then return false,"bike lifecycle cancelled before visual publication" end
        local args=table.pack(...)
        if name=="remove" and type(args[1])=="number" then
            T.deferred_removals=T.deferred_removals or {}
            T.deferred_removals[args[1]]=true
            if not removal_allowed() then T.visual_cleanup_deferred=true;return end
            remove_once(args[1])
            -- Spawn's void adapter receives request acceptance; the owner keeps
            -- actual native return arity separately and never retries a failure.
            return
        end
        local r=call("entities."..name,lookup("entities."..name),...)
        if not r[1] then error("entity "..name.." callback failed",0) end
        return table.unpack(r,2,r.n)
    end
end


local gear_api={time=R.time,input={focus=R.input and R.input.focus},
    skater={get=R.skater and R.skater.get},level=R.level,json=R.json,storage=R.storage}
gear_api.skater.telemetry=function(...)
    local r=call("equipment.skater.telemetry",lookup("skater.telemetry"),...)
    if not r[1] then error("equipment telemetry callback failed",0) end
    -- Bind the requested direction before EquipmentRuntime takes its baseline.
    if T.gear_arming and (r.n~=2 or type(r[2])~="table" or type(r[2].watch)~="table"
        or r[2].watch.state~=T.gear_initial) then return nil end
    return table.unpack(r,2,r.n)
end
for _,method in ipairs({"pulse","pulse_state","pulse_cancel","pulse_acknowledge"}) do
    local name=method
    gear_api.input[name]=function(...)
        if name=="pulse" then
            if T.unloaded or T.gear_cancelled or T.storage_fault or T.clock_unknown or not T.gear_requested then
                return nil,"stock intent cancelled before pulse"
            end
            local version=T.cancel_version
            local direction=status_of(equipment)
            local observed=facts()
            if T.cancel_version~=version or T.unloaded or T.gear_cancelled or T.storage_fault or T.clock_unknown
                or not T.gear_requested or not direction or direction.initial_state~=T.gear_initial
                or direction.expected_state~=T.gear_expected or not closed_ready(observed,true,true)
                or observed.state~=T.gear_initial then
                return nil,"bound stock direction or fresh readiness refused before pulse"
            end
        end
        local r=call("equipment.input."..name,lookup("input."..name),...)
        -- A Stop during pulse cannot erase a subsequently returned real handle.
        if name=="pulse" and r[1] and typeof(r[2])=="userdata"
            and (T.unloaded or T.gear_cancelled) and not T.late_gear_cancel then
            T.late_gear_cancel=true
            call("equipment.input.late_cancel",lookup("input.pulse_cancel"),r[2])
        end
        if not r[1] then error("equipment input "..name.." callback failed",0) end
        return table.unpack(r,2,r.n)
    end
end
equipment=EquipmentRuntime.new(gear_api)
T.equipment_instances=(T.equipment_instances or 0)+1

local required={"time.now","input.focus","input.allowed","skater.get","skater.telemetry","level.current",
    "menu.game","json.encode","storage.get","storage.set","entities.bounds","entities.set","entities.status","entities.remove",
    "world.physics.create","world.physics.read","world.physics.release","world.physics.reserve_follow","world.physics.publish_follow",
    "world.physics.read_follow","world.physics.stop_follow","world.physics.acknowledge_follow",
    "input.pulse","input.pulse_state","input.pulse_cancel","input.pulse_acknowledge"}
local function available()
    for _,path in ipairs(required) do if not lookup(path) then return false,path end end
    for _,name in ipairs(input_methods) do if not lookup("input."..name) then return false,"input."..name end end
    return type(vector)=="table" and type(vector.create)=="function","vector.create"
end

facts=function() return Admission.facts(call,lookup) end
local function base_ready(f,stock)
    return f and f.focused and f.gameplay and (stock and f.upright_stock or f.upright_onfoot)
        and (not T.level or f.level==T.level) and (not T.wipeouts or f.wipeouts==T.wipeouts)
end
closed_ready=function(f,grounded,stock)
    return base_ready(f,stock) and f.interface_closed and f.game_menu_closed and f.input_allowed
        and (not grounded or f.grounded)
end
local axes={"left_x","left_y","right_x","right_y","left_trigger","right_trigger"}
local buttons={"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"}
local function exact_zero(frame)
    local s=frame and frame.sample
    if frame.input_ok~=true or type(s)~="table" or s.user~=T.slot or type(s.pad)~="table" or s.pad.playstation~=false then return false end
    for _,key in ipairs(axes) do if s.pad[key]~=0 then return false end end
    if type(s.pad.buttons)~="table" then return false end
    for _,key in ipairs(buttons) do if s.pad.buttons[key]~=false then return false end end
    return true
end
local phases={reserved=true,following=true,stopping=true,retained=true,abandoned=true,completed=true}
local reasons={none=true,invalid_owner=true,invalid_kind=true,unavailable=true,busy=true,receipt_capacity=true,context_changed=true,
    focus_changed=true,teleporting=true,motion_owned=true,actor_changed=true,actor_destroyed=true,world_changed=true,
    unsupported_state=true,protection_conflict=true,request_bits_conflict=true,request_write_failed=true,request_restore_failed=true,
    native_refused=true,selector_overridden=true,cancelled=true,expired=true,owner_released=true,native_lifetime_changed=true}
local fields={phase=true,reason=true,park_reason=true,sequence=true,final_revision=true,final_native_epoch=true,returned_revision=true,
    pending=true,in_flight=true,claim_known=true,orphaned=true,park_observed=true,native_retirement_known=true,terminal=true}
local function receipt_copy(row)
    if type(row)~="table" then return nil end
    local n=0;for key in pairs(row) do if not fields[key] then return nil end;n+=1 end
    if n~=14 or not phases[row.phase] or not reasons[row.reason] or not reasons[row.park_reason]
        or not Identity.is_nonzero_u64(row.sequence) or T.sequence and row.sequence~=T.sequence then return nil end
    for _,key in ipairs(receipt_revisions) do if not Identity.is_u64(row[key]) then return nil end end
    if Identity.compare(row.returned_revision,row.final_revision)>0 or (row.final_revision=="0")~=(row.final_native_epoch=="0")
        or not finite(row.in_flight) or row.in_flight<0 or row.in_flight>255 or row.in_flight%1~=0 then return nil end
    for _,key in ipairs(receipt_flags) do
        if type(row[key])~="boolean" then return nil end
    end
    if row.native_retirement_known or row.terminal~=(row.phase=="abandoned" or row.phase=="completed") or type(row.pending)~="table" then return nil end
    local count=0;for key,value in pairs(row.pending) do if key~=1 or value~="body_parked" then return nil end;count+=1 end
    if count>1 then return nil end
    if row.phase=="reserved" and (row.final_revision~="0" or row.park_observed or count~=0) then return nil end
    if row.phase=="abandoned" and (row.final_revision~="0" or row.in_flight~=0 or row.park_observed or count~=0 or T.published_seen) then return nil end
    if row.phase=="completed" and (not row.park_observed or row.in_flight~=0 or count~=0 or row.returned_revision~=row.final_revision) then return nil end
    if T.receipt and (Identity.compare(row.final_revision,T.receipt.final_revision)<0 or
        Identity.compare(row.returned_revision,T.receipt.returned_revision)<0) then return nil end
    local out=copied(row);table.freeze(out.pending);table.freeze(out)
    return out
end
local function release_once()
    if not force_clear() or T.unloaded or T.release_attempted or not T.body or T.follow or T.reserve_unknown or T.handoff_unknown or T.published_seen then return end
    local handoff_without_reserve=T.transferred==true and T.handoff_attempted==true
        and T.handoff_unknown==false and T.reserve_attempted~=true
    if not handoff_without_reserve and not T.reserve_refused
        and not (T.acknowledged and T.terminal and T.terminal.phase=="abandoned") then return end
    T.release_attempted=true
    local r=call("body.release",lookup("world.physics.release"),T.body)
    T.release_accepted=yes(r)
    if T.release_accepted then T.body=nil end
end
local function accept_terminal(dto)
    if T.terminal then return end
    stop_all("native follow terminal receipt observed")
    T.terminal=dto
    if not persist(true) or T.unloaded then return end
    T.ack_attempted=true
    local r=call("follow.acknowledge",lookup("world.physics.acknowledge_follow"),T.follow)
    T.acknowledged=yes(r)
    if T.acknowledged then
        T.follow=nil
        if dto.phase=="completed" then T.completed_ack=true;T.body=nil else release_once() end
    end
    stop_spawn_when_allowed(T.stop_reason)
    persist(true)
end
local function read_follow(force)
    if not T.follow or T.ack_attempted or T.follow_reads==400 then return false end
    if not force and T.follow_read_at and T.now and T.now-T.follow_read_at<50 then return false end
    T.follow_read_at=T.now;T.follow_reads=(T.follow_reads or 0)+1
    local r=call("follow.read",lookup("world.physics.read_follow"),T.follow)
    local dto=r[1] and r.n==2 and receipt_copy(r[2]) or nil
    if not dto then T.follow_unknown=true;stop_all("follow receipt unavailable or contradictory");return false end
    T.sequence=T.sequence or dto.sequence;T.receipt=dto
    if dto.phase=="following" or dto.final_revision~="0" then T.published_seen=true end
    if #T.receipts==16 then table.remove(T.receipts,1);T.omitted_receipts+=1 end
    table.insert(T.receipts,copied(dto))
    if dto.orphaned and not dto.terminal then stop_all("native receipt reports orphaned ownership") end
    if dto.phase=="stopping" or dto.phase=="retained" or T.published_seen and dto.phase=="reserved" then
        stop_all("native follow is no longer following")
    end
    if dto.terminal then accept_terminal(dto) end
    return true
end
local source_identity_names={"sequence","source_epoch","context_generation"}
local function same_selected(frame,bound)
    if type(frame)~="table" or frame.input_ok~=true or frame.cleanup_pending or frame.cleanup_unknown
        or frame.lease_handle~=bound.lease_handle or frame.generation~=bound.generation
        or type(frame.sample)~="table" or frame.sample.user~=bound.user then return false end
    for _,name in ipairs(source_identity_names) do if frame.sample[name]~=bound[name] then return false end end
    return true
end
local function remember_ride(row)
    if type(row)~="table" or type(row.force_pending)~="boolean" or type(row.unknown)~="boolean"
        or type(row.stop_requested)~="boolean" or not finite(row.submitted) or row.submitted<0 or row.submitted%1~=0
        or not finite(row.acknowledged) or row.acknowledged<0 or row.acknowledged%1~=0 then
        T.ride_unknown=true;return false
    end
    local ok,detached=pcall(copied,row)
    if not ok then T.ride_unknown=true;return false end
    T.ride_status=detached
    if row.unknown then T.ride_unknown=true end
    return true
end
stop_ride=function(why)
    if not ride then return end
    local r=call("ride.stop",ride.stop,ride,why)
    if not r[1] or r.n~=2 or not remember_ride(r[2]) then T.ride_unknown=true end
end
drain_ride=function()
    if not ride then return end
    local r=call("ride.drain",ride.drain,ride)
    if not r[1] or r.n~=2 or not remember_ride(r[2]) then T.ride_unknown=true end
end
local function current_ride_owner(binding,epoch)
    local owner=binding.owner
    if not current(owner.generation) or ride_binding~=binding or not binding.observing
        or not T.active or T.body~=owner.body or T.follow~=owner.follow or T.input_current~=true
        or T.phase~="following" or not same_selected(selected_source_frame,owner.source)
        or not binding.sample or epoch~=binding.sample.epoch then return false end
    local now=clock()
    if not now or not current(owner.generation) or not T.publish_at or now-T.publish_at>=500 then return false end
    local f=facts();T.facts=f
    if not current(owner.generation) or not closed_ready(f,false) then return false end
    if not read_follow(true) or not current(owner.generation) then return false end
    local receipt=T.receipt
    if not receipt or receipt.phase~="following" or receipt.claim_known~=true or receipt.orphaned
        or receipt.terminal or receipt.park_observed then return false end
    -- Source owns this fresh read-only lease/capture check. It does not publish
    -- another model input or native body sample. All earlier guard callbacks
    -- run first; a post-effect failure still retains the accepted sequence.
    local authorization=call("source.authorize",source.authorize,source,selected_source_frame)
    now=clock() -- Include authorization time in the finite sampled500ms boundary.
    return now~=nil and current(owner.generation) and T.body==owner.body and T.follow==owner.follow
        and T.input_current==true and same_selected(selected_source_frame,owner.source)
        and now-T.publish_at<500 and binding.observing and binding.sample and epoch==binding.sample.epoch
        and authorization[1] and authorization.n==2 and authorization[2]==true
end
local function create_ride(frame)
    if not RIDE_COMPOSITION_QUALIFIED or ride or T.ride_construct_attempted then return end
    T.ride_construct_attempted=true
    local source_key={lease_handle=frame.lease_handle,generation=frame.generation,user=frame.sample.user}
    for _,name in ipairs(source_identity_names) do source_key[name]=frame.sample[name] end
    table.freeze(source_key)
    local owner=table.freeze({body=T.body,follow=T.follow,generation=T.generation,
        source=source_key,incarnation=table.freeze({})})
    local binding={owner=owner}
    ride_binding=binding -- Reserve before constructors/callbacks can reenter.
    local api={}
    local function guard(epoch)
        if binding.inflight or binding.unknown or not current_ride_owner(binding,epoch) then
            stop_all("current Core Source/Follow/body/epoch force guard refused")
            return false
        end
        return true
    end
    api.probe_batch=function(epoch,rays,query_options)
        if type(query_options)~="table" or query_options.require_contact~=true
            or query_options.exclude_local_actor~=true or not guard(epoch) then return nil end
        local serial=binding.sample.serial
        if binding.last_probe==serial then stop_all("second contact batch for one native serial refused");return nil end
        binding.last_probe=serial
        local r=call("ride.probe_batch",lookup("world.physics.probe_batch"),owner.body,epoch,rays,query_options)
        if not current_ride_owner(binding,epoch) then stop_all("Core guard changed during contact query") end
        if not r[1] then error("contact query result unknown",0) end
        return table.unpack(r,2,r.n)
    end
    api.submit=function(epoch,command)
        if not guard(epoch) then return false,"Core force publication guard refused before SDK call" end
        local serial=binding.sample.serial
        if binding.sequence or binding.last_submit==serial then
            stop_all("pending or duplicate force publication refused")
            return false,"one force transaction per measured serial"
        end
        binding.last_submit=serial;binding.inflight=true
        local r=call("ride.submit",lookup("world.physics.submit"),owner.body,epoch,command)
        -- Adopt the actual returned sequence even if Stop/unload ran inside SDK.
        -- Never replace a late accepted tuple with a fabricated clean refusal.
        if r[1] and r.n==4 and r[2]==true and r[3]==nil and Identity.is_nonzero_u64(r[4]) then
            binding.sequence=r[4];binding.ack_attempted=false
        elseif not (r[1] and r.n==3 and r[2]==false and type(r[3])=="string") then
            binding.unknown=true;T.ride_unknown=true
        end
        binding.inflight=false
        if not current_ride_owner(binding,epoch) then stop_all("Core guard changed during force publication") end
        if not r[1] then error("force publication outcome unknown",0) end
        return table.unpack(r,2,r.n)
    end
    api.receipt=function(sequence)
        -- Original body binding survives T.body=nil, Follow ACK, stop and unload.
        if sequence~=binding.sequence or not Identity.is_nonzero_u64(sequence) then
            binding.unknown=true;T.ride_unknown=true;return nil
        end
        local r=call("ride.receipt",lookup("world.physics.receipt"),owner.body,sequence)
        if not r[1] then binding.unknown=true;T.ride_unknown=true;error("force receipt unknown",0) end
        return table.unpack(r,2,r.n)
    end
    api.acknowledge=function(sequence)
        if sequence~=binding.sequence or binding.ack_attempted or not Identity.is_nonzero_u64(sequence) then
            binding.unknown=true;T.ride_unknown=true;return false,"exact original pending sequence required"
        end
        binding.ack_attempted=true
        local r=call("ride.acknowledge",lookup("world.physics.acknowledge"),owner.body,sequence)
        if yes(r) then binding.sequence=nil
        else binding.unknown=true;T.ride_unknown=true end
        if not r[1] then error("force acknowledgement outcome unknown",0) end
        return table.unpack(r,2,r.n)
    end
    table.freeze(api)
    local built=call("ride.new",function()
        local Ride=require("./ride_runtime")
        local Contact=require("./contact_runtime")
        local Trick=require("./trick_runtime")
        return Ride.new(api,{contact=Contact,tricks=Trick.new()},{body_handle=owner.body,incarnation=owner.incarnation})
    end)
    if built[1] and built.n==2 and type(built[2])=="table" then ride=built[2] end
    if not ride or not remember_ride(status_of(ride)) then
        T.ride_unknown=true;stop_all("subordinate construction or force ledger unavailable");return
    end
    if not current(owner.generation) then stop_ride("cancelled during subordinate construction") end
end
observe_ride=function(frame,sample,now)
    if not RIDE_COMPOSITION_QUALIFIED then return end
    if not ride then create_ride(frame) end
    if not ride or not ride_binding or T.stop_latched then return end
    -- Freeze this exact same-read sample; both Ride and the visual update use
    -- these userdata/vector values. No extra body read or receipt surrogate.
    if type(sample)~="table" or getmetatable(sample)~=nil or typeof(sample.epoch)~="userdata"
        or not Identity.is_nonzero_u64(sample.serial) or type(sample.rotation)~="table" then
        stop_all("same-read body sample unavailable for subordinate");return
    end
    if not table.isfrozen(sample.rotation) then table.freeze(sample.rotation) end
    if not table.isfrozen(sample) then table.freeze(sample) end
    local binding=ride_binding
    binding.sample=sample;binding.observing=true
    local r=call("ride.observe",ride.observe,ride,frame,sample,
        {now_ms=now,focused=T.facts.focused,menu_open=not T.facts.interface_closed or not T.facts.game_menu_closed,loaded=true})
    binding.observing=false;binding.sample=nil
    if not r[1] or r.n~=2 or not remember_ride(r[2]) then
        T.ride_unknown=true;stop_all("subordinate observation outcome unknown")
    elseif r[2].stop_requested then stop_all("subordinate requested stop") end
end

local function handoff_and_follow()
    local generation=T.generation
    T.handoff_attempted=true;T.handoff_unknown=true
    local h=call("spawn.handoff_follow",spawn.handoff_follow,spawn)
    if h[1] and typeof(h[2])=="userdata" then T.body=h[2];T.transferred=true end
    if not h[1] or h.n~=4 or typeof(h[2])~="userdata" or type(h[3])~="table" or h[4]~=nil then
        if h[1] and h.n==4 and h[2]==nil and h[3]==nil and reason(h[4]) then T.handoff_unknown=false end
        stop_all("spawn handoff refused or unknown");return
    end
    T.handoff_unknown=false
    local at=clock();if not at or not current(generation) then stop_all("cancelled during body handoff");return end
    local v=call("spawn.follow_visual",spawn.follow_visual,spawn,h[3],at)
    if not yes(v) or not clock() or not current(generation) then stop_all("initial follow visual refused or cancelled");return end
    T.reserve_attempted=true;T.reserve_unknown=true;T.reserve_at=T.now
    local reserved=call("follow.reserve",lookup("world.physics.reserve_follow"),T.body,
        {offset_from_com=vector.create(-G.com[1],-G.com[2],-G.com[3]),root_in_body={0,0,0,1}})
    -- Adopt any returned userdata BEFORE inspecting why or cancellation.
    if reserved[1] and typeof(reserved[2])=="userdata" then T.follow=reserved[2];T.reserve_unknown=false end
    local after=clock()
    if not T.follow then
        -- Protocol strings can hide a backend reservation whose handle was lost.
        if reserved[1] and reserved.n==3 and reserved[2]==nil and type(reserved[3])=="string"
            and reserved[3]~="none" and reasons[reserved[3]]==true then T.reserve_unknown=false;T.reserve_refused=true end
        stop_all("follow reserve refused or unknown");release_once();return
    end
    if not after or not current(generation) or after-T.reserve_at>=3000 then stop_all("reserve callback cancelled or exceeded native lease");return end
    if reserved.n~=3 or reserved[3]~=nil then stop_all("partial or malformed follow reserve; never publish");return end
    read_follow(true)
    if not current(generation) or not T.receipt or T.receipt.phase~="reserved" then stop_all("reservation receipt did not qualify publication");return end
    after=clock()
    if not after or not current(generation) or after-T.reserve_at>=3000 then stop_all("reservation lease elapsed before publish");return end
    T.publish_attempted=true;T.publish_at=after
    local published=call("follow.publish",lookup("world.physics.publish_follow"),T.follow)
    if published[1] and published[2]==true then T.published_seen=true end
    after=clock()
    if not yes(published) or not after or not current(generation) or after-T.publish_at>=500 then stop_all("publish refused, cancelled or bounded interval elapsed");return end
    T.phase="following";T.detail="Published one zero-force attachment; sampled alignment is not claimed."
    persist(true)
end

local function cleanup_tick()
    -- A separately requested stock transaction cannot reopen completed bike
    -- history or inherit the old qualification cleanup deadline.
    if T.bike_cleanup_complete then return end
    local previous=T.phase
    follow_stop_once()
    -- Follow cancellation/park is immediate. It never fabricates force ACK;
    -- cleanup capabilities retain the original body after Follow clears T.body.
    drain_ride()
    local start=T.effect_at or T.stop_at
    if not T.cleanup_expired and T.now and start and T.now-start>=20000 then
        T.cleanup_expired=true;T.detail="Cleanup watchdog expired; unresolved duty retained for SDK VM close."
    end
    if not T.cleanup_expired then read_follow(false) end
    release_once()
    stop_spawn_when_allowed(T.stop_reason)
    flush_removals()
    local b=status_of(spawn)
    local body_clear=not spawn and not T.spawn_requested
        or not T.transferred and b and not b.cleanup_unknown and not b.creation_unknown and not b.body
        or T.completed_ack or T.release_accepted
    local follow_clear=not T.follow and not T.reserve_unknown and not T.handoff_unknown
    local removals_clear=not b or not b.visual_remove_requested or visuals_accepted()
    local e=status_of(equipment)
    local equipment_clean=e and not e.retained and (e.phase=="idle" or e.phase=="done")
    if force_clear() and source_clear() and body_clear and follow_clear and removals_clear and equipment_clean
        and not unknown_duty() then
        T.active=false;T.gear_requested=false;T.bike_cleanup_complete=true;T.phase="done"
        T.detail=T.completed_ack and "Completed + ACK; input drained. Stock return requires a separate explicit request."
            or "No published bike authority remains; stock switching is a separate explicit request."
    elseif T.cleanup_expired or unknown_duty() then
        T.phase="retained_unknown"
    end
    if T.phase~=previous then persist(true) end
end
local function valid_slot(slot)
    return finite(slot) and slot>=0 and slot<=3 and slot%1==0
end
local function marker_clear()
    if T.ledger_owned then return true end
    if T.reload_blocked or T.marker_unknown then return false end
    local old=call("storage.get",lookup("storage.get"),KEY)
    if not old[1] or old.n~=2 then
        T.marker_unknown=true;T.phase="blocked";T.detail="Bike marker unreadable; no adoption, rearm or stock pulse."
        return false
    end
    if old[2]~=nil then
        T.reload_blocked=true;T.phase="blocked";T.detail="Prior bike marker retained; no handle adoption, rearm or stock pulse."
        return false
    end
    return true
end
local function begin_equipment(slot,purpose,initial)
    T.gear_purpose=purpose;T.gear_initial=initial;T.gear_expected=initial==100 and 504 or 100
    T.gear_requested=true;T.gear_cancelled=false;T.late_gear_cancel=false;T.gear_arming=true
    local version=T.cancel_version
    local r=call("equipment.request",equipment.request,equipment,slot,T.gear_admission_at)
    T.gear_arming=false
    if not yes(r) or T.cancel_version~=version or T.unloaded or T.gear_cancelled then
        local known_false=r[1] and r.n==3 and r[2]==false and reason(r[3])
        if not known_false or not equipment_clear() then T.gear_unknown=true
        else T.gear_requested=false end
        if purpose=="mount" or T.gear_unknown then stop_all("stock request refused, cancelled or unknown") end
        return false,"Stock request refused, cancelled or unresolved"
    end
    T.phase=purpose=="mount" and "equipment_acquiring" or "stock_switching"
    T.detail=purpose=="mount" and "Board100 to feet504 acquisition; capture waits for matching report ACK and stable target."
        or "Explicit stock toggle armed; close menus and keep the selected controller neutral."
    return true
end
local function equipment_tick()
    if not T.gear_requested or T.gear_cancelled then return end
    local version=T.cancel_version
    local r=call("equipment.update",equipment.update,equipment)
    local e=status_of(equipment)
    if not r[1] or r.n~=2 or type(r[2])~="table" or not e then
        T.gear_unknown=true;stop_all("equipment update unavailable or malformed");return
    end
    if T.cancel_version~=version or T.gear_cancelled or T.unloaded then
        stop_all("equipment callback cancelled");return
    end
    if e.outcome=="unresolved" then
        T.gear_unknown=true;stop_all("equipment report cleanup is unresolved");return
    end
    if not e.retained and (e.phase=="done" or e.phase=="idle") then
        if T.gear_purpose=="mount" then
            if e.initial_state~=100 or e.expected_state~=504 or not e.qualified_transition
                or not e.acknowledged or e.unloaded then
                stop_all("board-to-feet transition did not qualify with cleared ACK duty");return
            end
            T.gear_requested=false;T.phase="armed"
            T.detail="Feet504 acquisition complete; waiting for closed-menu neutral source qualification."
            T.ready_since=nil;T.ready_ticks=0;T.ready_last=nil
            persist(true)
        else
            T.gear_requested=false;T.phase=T.used and "done" or "idle"
            T.detail=e.current_transition==true and "Stock target observed; consumption remains unobserved."
                or "Stock request ended without a qualified target; no automatic retry."
        end
    end
end
function object:prepare_backend()
    if source or spawn then return source~=nil and spawn~=nil end
    if T.unloaded or T.stop_latched or not qualification_only then return false end
    -- Dependencies were staged individually. These require calls are cache hits.
    local Source=require("./lease_source")
    local BikeSpawn=require("./bike_spawn")
    Identity=require("./lease_identity")
    G=require("./bike_geometry")
    source=Source.new(input_proxy,{setup_ms=15000,capture_ms=4000,cleanup_ms=4000})
    T.source_instances=(T.source_instances or 0)+1
    spawn=BikeSpawn.new(spawn_api)
    T.spawn_instances=(T.spawn_instances or 0)+1
    return true
end
function object:status()
    -- All three dependency status methods are local cached reads. Detached
    -- copying strips private epochs/handles and refuses opaque nested values.
    local ok,result=pcall(snapshot)
    if ok then return result end
    return {phase="retained_unknown",detail="Diagnostic copy refused; preserve SDK cleanup duty.",
        mount_enabled=false,qualification_only=qualification_only,bike_authority=true,
        cleanup_pending=true,cleanup_unknown=true,stock_toggle_blocked=true,used=T.used==true,
        unloaded=T.unloaded==true,equipment={phase="unknown",retained=true},storage_key=KEY}
end
function object:request_mount(slot,admitted)
    if not valid_slot(slot) then return false,"Choose an XInput slot from0 to3" end
    -- This branch precedes clock, storage, facts and all other API calls.
    if not qualification_only then return false,"Native bike lifecycle qualification unavailable" end
    if T.busy then
        if T.intent_inflight or T.active or T.gear_requested then stop_all("reentrant mount request") end
        return false,"Bike lifecycle operation already in progress"
    end
    if (T.used and admitted~=T) or vm_attempt_used or T.unloaded or stock_blocked() then return false,"One attempt per VM; busy or retained duty prevents rearm" end
    T.busy=true;T.intent_inflight=true;T.used=true;vm_attempt_used=true;T.slot=slot
    local generation=T.generation
    local clear=marker_clear()
    if clear and current(generation) then
        T.ledger_owned=true;T.phase="armed";T.detail="One explicit zero-force qualification intent; no native acquisition yet."
        clear=persist(true) and current(generation)
    end
    local ok,missing=available()
    local now=clear and ok and clock() or nil
    local observed=now and facts() or nil
    if now then now=clock() end
    local accepted=false
    if not clear or not current(generation) then
        if not T.reload_blocked and not T.marker_unknown then stop_all("mount cancelled before acquisition") end
    elseif not ok then stop_all("Required API unavailable: "..short(missing))
    elseif not now or not base_ready(observed,true) or not observed.grounded
        or admitted==T and not Admission.matches(T.admitted_facts,observed) then
        stop_all("Grounded upright board100 or on-foot504 and focused gameplay required")
    else
        T.arm_at=T.arm_at or now;T.level=observed.level;T.wipeouts=observed.wipeouts
        T.initial_facts=observed;T.facts=observed;T.active=true
        if persist(true) and current(generation) then
            if observed.state==100 then accepted=begin_equipment(slot,"mount",100)
            else T.phase="armed";T.detail="Armed once; close both menus and keep the selected raw pad exactly zero.";accepted=true end
        end
    end
    T.intent_inflight=false;T.busy=false
    if not accepted then return false,short(T.detail) end
    return true
end
function object:request_stop(why)
    if T.unloaded then return false,"Runtime is unloaded; SDK retains cleanup" end
    if not T.used and not T.gear_requested and not T.intent_inflight then return true end
    stop_all(reason(why) and why or "explicit Stop")
    if T.ledger_owned then persist(true) end
    return true
end
function object:request_stock_toggle(slot,admitted)
    if not valid_slot(slot) then return false,"Choose an XInput slot from0 to3" end
    if stock_blocked() then
        if T.busy and (T.intent_inflight or T.active or T.gear_requested) then stop_all("reentrant stock request") end
        return false,"Bike, input, equipment or retained reload cleanup blocks stock switching"
    end
    -- Latch before marker/facts callbacks, before EquipmentRuntime sets pending.
    T.busy=true;T.intent_inflight=true
    local version=T.cancel_version
    local clear=marker_clear()
    local observed=clear and facts() or nil
    local accepted=false
    if clear and T.cancel_version==version and not T.unloaded and not T.storage_fault and not T.clock_unknown
        and base_ready(observed,true) and observed.grounded
        and (admitted~=T or Admission.matches(T.admitted_facts,observed)) then
        accepted=begin_equipment(slot,"stock",observed.state)
    elseif clear then T.detail="Stock request refused by fresh readiness or cancelled intent." end
    T.intent_inflight=false;T.busy=false
    if not accepted then
        -- A refused or cancelled request is terminal. The next quiescent tick
        -- saves it, after a deferred startup caller has restored its phase.
        T.persist_dirty=true
        return false,short(T.detail)
    end
    return true
end
local function tick(dt)
    selected_source_frame=nil
    if T.unloaded or T.phase=="blocked" then return end
    if not T.used and not T.gear_requested or T.phase=="done" and not T.gear_requested then
        -- No tick-end save runs from here, so a throttled snapshot would
        -- otherwise remain the cached ledger for the rest of this VM.
        if T.persist_dirty then persist(true) end
        return
    end
    -- The tick that completes or cancels a stock request leaves the next tick
    -- on the quiescent return above, so that terminal record is saved now.
    local stock_open=T.gear_purpose=="stock" and T.gear_requested==true and not T.gear_cancelled
    local now=clock()
    if not finite(dt) or dt<=0 or dt>250 or now and T.last_step_at and now<=T.last_step_at then
        stop_all("invalid, stalled or reversed wall tick")
    end
    if now then T.last_step_at=now end
    if T.gear_requested and not T.gear_cancelled then equipment_tick() end
    if T.active and now and not T.stop_latched then
        local f=facts();T.facts=f
        if not base_ready(f,T.gear_requested and T.gear_purpose=="mount") then
            stop_all("fresh sampled upright/focus/context/fall readiness lost")
        elseif T.gear_requested then
            -- Equipment owns its report transaction. No selected source yet.
        elseif not T.source_armed then
            if now-T.arm_at>=60000 then stop_all("mount intent expired before acquisition")
            elseif closed_ready(f,true) then
                if not T.ready_since then T.ready_since=now;T.ready_last=now;T.ready_ticks=0
                elseif now>T.ready_last then T.ready_ticks+=1;T.ready_last=now end
                if now-T.ready_since>=600 and T.ready_ticks>=10 then
                    T.source_armed=true;T.effect_at=now
                    local generation=T.generation
                    local r=call("source.arm",source.arm,source,T.slot,now)
                    if not yes(r) or not current(generation) then stop_all("source Arm refused, cancelled or unknown")
                    else T.phase="capturing" end
                end
            else T.ready_since=nil;T.ready_ticks=0;T.ready_last=nil end
        elseif not closed_ready(f,T.phase~="following") then stop_all("fresh menu/input/grounded acquisition gate lost") end
        if T.effect_at and now-T.effect_at>=20000 then stop_all("total effect watchdog expired") end
    end
    if T.source_armed and not source_clean() then
        local generation=T.generation
        local allow=not T.stop_latched and closed_ready(T.facts,T.phase~="following")
        T.source_inflight=true;T.input_current=false
        local frame=call("source.step",source.step,source,T.now or 0,{allow_acquire=allow,allow_drive=allow})
        T.source_inflight=false
        if T.stop_needs_cleanup then stop_all(T.stop_reason) end
        if frame[1] and frame.n==2 and type(frame[2])=="table" then
            T.source_record=source_record(frame[2])
            if not T.stop_latched and T.input_seen and frame[2].input_ok~=true then stop_all("current selected-stream input permission lost") end
            if not T.stop_latched and (frame[2].cleanup_pending or frame[2].cleanup_unknown
                or frame[2].phase=="complete" or frame[2].phase=="stopping" or frame[2].phase=="draining") then
                stop_all("source stopped or retained cleanup duty")
            end
            if current(generation) and frame[2].input_ok then
                T.input_seen=true;T.input_current=true
                selected_source_frame=frame[2] -- Exact private Source output, never source_record DTO.
                if not exact_zero(frame[2]) then stop_all("selected raw pad left exact zero")
                elseif not T.spawn_requested then
                    T.spawn_requested=true
                    local r=call("spawn.request",spawn.request,spawn)
                    if not yes(r) or not current(generation) then stop_all("one spawn request refused, cancelled or unknown")
                    else T.phase="spawning" end
                end
            end
        else stop_all("source step exception or malformed frame") end
    end
    if not T.stop_latched and T.input_current and T.spawn_requested and not T.handoff_attempted then
        local generation=T.generation
        call("spawn.update",spawn.update,spawn,dt)
        local b=status_of(spawn)
        if not current(generation) then stop_all("cancelled during spawn callback")
        elseif not b or b.cleanup_unknown or b.phase=="closed" or b.phase=="cleanup_unknown" or b.phase=="clock_prepared" then
            stop_all("spawn stopped; no retry")
        elseif b.phase=="spawned" then handoff_and_follow() end
    end
    if T.phase=="following" and not T.stop_latched and T.input_current then
        now=clock()
        if not now or now-T.publish_at>=500 then stop_all("500ms published qualification interval ended")
        else
            local generation=T.generation
            if not read_follow(true) and current(generation) then stop_all("bounded follow receipt unavailable before body read") end
            if current(generation) then
                now=clock()
                if not now or now-T.publish_at>=500 then stop_all("qualification interval elapsed during receipt read")
                elseif current(generation) then
                    local measured_body=T.body
                    local r=call("body.read",lookup("world.physics.read"),measured_body)
                    now=clock()
                    if not now or now-T.publish_at>=500 then stop_all("qualification interval elapsed during body read")
                    elseif not r[1] or r.n~=2 or type(r[2])~="table" then stop_all("following body observation unavailable")
                    elseif RIDE_COMPOSITION_QUALIFIED and T.body~=measured_body then
                        stop_all("body owner changed during same-read subordinate observation")
                    elseif current(generation) then
                        observe_ride(selected_source_frame,r[2],now)
                        local v=current(generation) and call("spawn.follow_visual",spawn.follow_visual,spawn,r[2],now) or {false,n=1}
                        now=clock()
                        if not yes(v) or not now or not current(generation) or now-T.publish_at>=500 then
                            stop_all("follow visual refused, cancelled or interval elapsed")
                        end
                    end
                end
            end
        end
    end
    if T.stop_latched and not T.bike_cleanup_complete then cleanup_tick() end
    persist(stock_open and (not T.gear_requested or T.gear_cancelled==true))
end
function object:step(dt_ms)
    if T.busy then
        if T.intent_inflight or T.active or T.gear_requested then stop_all("reentrant lifecycle step") end
        return self:status()
    end
    T.busy=true
    local ok=pcall(tick,dt_ms)
    if not ok then
        T.source_inflight=false
        stop_all("lifecycle exception; no retry")
        persist(true)
    end
    T.busy=false
    return self:status()
end
function object:unload()
    if T.unloaded then return self:status() end
    T.unloaded=true;T.generation+=1
    if T.used or T.gear_requested or T.intent_inflight then stop_all("unload; SDK retains unresolved native duty") end
    drain_ride()
    if source then call("source.unload",source.unload,source) end
    call("equipment.unload",equipment.unload,equipment)
    if T.used then stop_spawn_when_allowed("unload visual cleanup");persist(true) end
    return self:status()
end
return table.freeze(object)
end
return table.freeze(BikeRuntime)

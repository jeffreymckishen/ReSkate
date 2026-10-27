-- Shared synchronous admission policy; imported only after explicit valid intent.
-- One state table passes to the delayed core. No body/source ownership lives here.
local Admission={}
local KEY="bmx_bike_lifecycle_v1"
local MAX=9007199254740991
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function short(v) return type(v)=="string" and v:gsub("[%c]"," "):sub(1,180) or "unavailable or malformed result" end
function Admission.matches(before,after)
    return before and after and before.state==after.state and before.level==after.level
        and before.wipeouts==after.wipeouts
end
function Admission.ready(f)
    return f and f.focused and f.gameplay and f.upright_stock and f.grounded
end
function Admission.snapshot(T,qualification_only)
    -- Fresh nested tables: pristine/startup diagnostics never expose owner state.
    return {schema=1,kind="bike-lifecycle-v1",storage_key=KEY,mount_enabled=false,
        qualification_only=qualification_only,used=T.used==true,phase=T.phase,detail=T.detail,
        bike_authority=false,cleanup_pending=T.reload_blocked==true or T.marker_unknown==true,
        cleanup_unknown=T.reload_blocked==true or T.marker_unknown==true or T.storage_fault==true or T.clock_unknown==true,
        stock_toggle_blocked=T.startup_closed==true or T.startup_pending==true or T.reload_blocked==true or T.marker_unknown==true
            or T.storage_fault==true or T.clock_unknown==true or T.unloaded==true or T.used==true and not T.bike_cleanup_complete,
        retained_reload_marker=T.reload_blocked==true,marker_unknown=T.marker_unknown==true,
        unloaded=T.unloaded==true,stop_latched=T.stop_latched==true,stop_reason=T.stop_reason,
        arm_ms=T.arm_at,qualification_ms=500,one_attempt_per_vm=true,
        equipment={phase="idle",retained=false,unloaded=false},
        startup={pending=T.startup_pending==true,loaded=T.startup_loaded or 0,last_module=T.startup_last,
            core_ready=T.core_ready==true,backend_ready=T.backend_ready==true}}
end
function Admission.bind(T,R,qualification_only)
    local api={}
    local function lookup(path)
        local value=R
        for part in path:gmatch("[^.]+") do value=type(value)=="table" and value[part] or nil end
        return type(value)=="function" and value or nil
    end
    local function call(name,fn,...)
        local result=table.pack(pcall(fn,...))
        T.counts[name]=(T.counts[name] or 0)+1
        local row={call=name,at_ms=T.now,called=result[1]==true,returns=result[1] and result.n-1 or 0,
            first_type=typeof(result[2])}
        if type(result[2])=="boolean" then row.accepted=result[2] end
        if type(result[3])=="string" then row.reason=short(result[3]) end
        if not result[1] then row.error=short(result[2]) end
        if #T.calls==64 then table.remove(T.calls,1);T.omitted_calls+=1 end
        table.insert(T.calls,row)
        return result
    end
    function api.persist()
        if not T.ledger_owned or T.storage_fault or T.saving then return false end
        T.saving=true
        local record=Admission.snapshot(T,qualification_only)
        local encoded=call("json.encode",lookup("json.encode"),record)
        local accepted=false
        if encoded[1] and encoded.n==2 and type(encoded[2])=="string" and #encoded[2]<=48000 then
            local stored=call("storage.set",lookup("storage.set"),KEY,record)
            accepted=stored[1]==true and stored.n==1
        end
        T.saving=false
        if not accepted then T.storage_fault=true end
        return accepted
    end
    function api.clock()
        local result=call("time.now",lookup("time.now"))
        local value=result[2]
        if not result[1] or result.n~=2 or not finite(value) or value<0 or value>MAX or T.now and value<T.now then
            T.clock_unknown=true;return nil
        end
        T.now=value;return value
    end
    function api.marker_clear()
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
    function api.facts() return Admission.facts(call,lookup) end
    function api.available()
        for _,path in ipairs(Admission.required) do if not lookup(path) then return false,path end end
        for _,name in ipairs(Admission.input_methods) do if not lookup("input."..name) then return false,"input."..name end end
        return type(vector)=="table" and type(vector.create)=="function","vector.create"
    end
    return api
end
function Admission.facts(call,lookup)
    local f=call("input.focus",lookup("input.focus"))
    local a=call("input.allowed",lookup("input.allowed"))
    local m=call("menu.game",lookup("menu.game"))
    local p=call("skater.get",lookup("skater.get"))
    local w=call("skater.telemetry",lookup("skater.telemetry"))
    local l=call("level.current",lookup("level.current"))
    -- The six results checked in order, without a list made for the loop.
    if not f[1] or f.n~=2 or not a[1] or a.n~=2 or not m[1] or m.n~=2 or not p[1] or p.n~=2
        or not w[1] or w.n~=2 or not l[1] or l.n~=2 then return nil end
    f,a,m,p,w,l=f[2],a[2],m[2],p[2],w[2],l[2]
    if type(f)~="table" or type(a)~="boolean" or type(m)~="table" or type(m.open)~="boolean"
        or type(p)~="table" or type(w)~="table" or type(w.watch)~="table" or type(l)~="table"
        or type(l.name)~="string" or #l.name==0 or #l.name>200 then return nil end
    local watch=w.watch
    local upright=w.skater==true and watch.valid==true and (watch.state==100 or watch.state==504)
        and watch.ragdoll_known==true and watch.ragdoll==false and w.teleport_pending==false
        and type(p.airborne)=="boolean" and type(w.airborne)=="boolean"
        and typeof(p.position)=="vector" and finite(p.heading)
        and finite(p.position.x) and finite(p.position.y) and finite(p.position.z)
    local wipeouts=finite(watch.wipeouts) and watch.wipeouts>=0 and watch.wipeouts<=MAX
        and watch.wipeouts%1==0 and watch.wipeouts or nil
    return {level=l.name,focused=f.focused==true,gameplay=f.gameplay==true,
        interface_closed=f.interface_open==false,game_menu_closed=m.open==false,input_allowed=a,
        upright_stock=upright,upright_onfoot=upright and watch.state==504,
        grounded=p.airborne==false and w.airborne==false,wipeouts=wipeouts,
        state=watch.state,ragdoll_known=watch.ragdoll_known,ragdoll=watch.ragdoll,teleport_pending=w.teleport_pending,
        scope="Sampled Lua observations only; not actor/allocation/session identity"}
end

Admission.required={"time.now","input.focus","input.allowed","skater.get","skater.telemetry","level.current",
    "menu.game","json.encode","storage.get","storage.set","entities.bounds","entities.set","entities.status","entities.remove",
    "world.physics.prepare","world.physics.create","world.physics.read","world.physics.release","world.physics.reserve_follow","world.physics.publish_follow",
    "world.physics.read_follow","world.physics.stop_follow","world.physics.acknowledge_follow",
    -- Core's four force closures call these. A missing one refuses here, before
    -- any body or Ride exists, instead of raising inside a ride. Presence only:
    -- probe_batch still needs world.raycast at call time.
    "world.physics.probe_batch","world.physics.submit","world.physics.receipt","world.physics.acknowledge",
    "input.pulse","input.pulse_state","input.pulse_cancel","input.pulse_acknowledge"}
Admission.input_methods={"lease","lease_read","lease_renew","lease_state","lease_release","lease_acknowledge",
    "lease_capture","lease_capture_state","lease_release_capture","lease_acknowledge_capture"}

return table.freeze(Admission)

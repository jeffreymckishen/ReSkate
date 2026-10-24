-- Package exact bike_spawn/bike_visual/bike_geometry/force_math production
-- modules beside this file. This entry is not the mounted riding mode.
-- Trial-only API breadcrumbs. Text stays below the existing 50-line/s cap;
-- a tiny last-call record survives a timeout through the SDK's normal VM close.
local marker_sequence,log_at,log_lines=0,nil,0
local logged={}
local function marker(event,operation,key)
    marker_sequence+=1
    local record={sequence=marker_sequence,event=event,operation=operation,key=tostring(key or "")}
    reskate.storage.set("lua_bike_api_marker_v3",record)
    local unique=event.."|"..operation.."|"..(operation=="bounds" and record.key or "")
    if logged[unique] then return end
    local now=reskate.time.now()
    if not log_at or now<log_at or now-log_at>=1000 then log_at,log_lines=now,0 end
    if log_lines<40 then
        reskate.log(string.format("Lua bike API %d %s %s %s",marker_sequence,event,operation,record.key))
        log_lines+=1
        logged[unique]=true
    end
end
-- Each result has its own separate key: later cleanup cannot overwrite it.
-- These are API return facts, not native allocation, measurement or cleanup proof.
local function returned(operation,result)
    if operation~="create" and operation~="read" and operation~="release" then return end
    local value=result[2]
    local record={operation=operation,pcall_ok=result[1]==true,arity=result.n-1,
        value_type=typeof(value),first_is_nil=value==nil}
    if operation=="create" then record.body_returned=typeof(value)=="userdata" end
    if operation=="release" then record.release_accepted=value==true end
    local reason=result[1] and result[3] or result[2]
    if type(reason)=="string" then record.reason=string.sub(reason,1,256) end
    reskate.storage.set("lua_bike_api_"..operation.."_result_v4",record)
end
local function traced(operation,call)
    return function(...)
        local key=(operation=="bounds" or operation=="set" or operation=="status" or operation=="remove") and select(1,...) or ""
        marker("before",operation,key)
        local result=table.pack(pcall(call,...))
        returned(operation,result)
        if not result[1] then marker("error",operation,key) error(result[2],0) end
        marker("after",operation,key)
        return table.unpack(result,2,result.n)
    end
end
local observed={
    input={focus=traced("focus",reskate.input.focus)},
    skater={get=traced("skater",reskate.skater.get)},
    entities={bounds=traced("bounds",reskate.entities.bounds),set=traced("set",reskate.entities.set),
        status=traced("status",reskate.entities.status),remove=traced("remove",reskate.entities.remove)},
    world={physics={create=traced("create",reskate.world.physics.create),
        read=traced("read",reskate.world.physics.read),release=traced("release",reskate.world.physics.release)}}}
local bike=require("./bike_spawn").new(observed)
local saved=false
reskate.menu.page("Lua Bike Spawn Trial",function(ui)
    ui:warn("One unmounted Lua bike and owned chassis for five seconds. No riding or rider attachment.")
    ui:note("Requires the current private eight-part BMX asset pack with matching wheel bounds.")
    if ui:button("spawn","Spawn one Lua bike") then bike:request() end
    if ui:button("retry","Retry after readiness wait") then bike:retry_after_clock_warmup() end
    if ui:button("stop","Release bike / stop") then bike:stop("explicit page action") end
    local status=bike:status()
    ui:info("Phase",status.phase) ui:info("Detail",status.detail)
    ui:info("Measured visual updates",tostring(status.visual_updates))
    ui:info("Readiness retry available",tostring(status.clock_retry_available))
    ui:info("Body release accepted",tostring(status.body_release_accepted))
    ui:info("Cleanup unknown",tostring(status.cleanup_unknown))
end)
reskate.on("tick",function(dt)
    bike:update(dt)
    local status=bike:status()
    if not saved and (status.phase=="closed" or status.phase=="cleanup_unknown") then
        local ok=pcall(reskate.storage.set,"lua_bike_spawn_v1",status)
        saved=ok
    end
end)
reskate.on("unload",function() bike:stop("plugin unload") end)

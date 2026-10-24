-- Package exact bike_spawn/bike_visual/bike_geometry/force_math production
-- modules beside this file. This entry is not the mounted riding mode.
local bike=require("./bike_spawn").new()
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

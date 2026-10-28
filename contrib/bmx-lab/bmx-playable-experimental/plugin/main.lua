-- Separate experimental one-session package; Root owns review and deployment.
local EXPERIMENTAL_ADMITTED=false
local SLOT=0
local Runtime=require("./bike_runtime")
local Survey=require("./ride_r1_record")
local Entry=require("./bmx_playable_entry")
local bike=Entry.new(reskate,Runtime,Survey,{admitted=EXPERIMENTAL_ADMITTED,slot=SLOT})
reskate.on("tick",function(dt_ms) bike:step(dt_ms) end)
reskate.menu.page("BMX experimental",function(ui)
    local s=bike:status()
    ui:warn("Experimental: one bike attempt per session, on foot only, in a flat area with 10 m clear around you.")
    if not s.admitted then ui:note("This reviewed source build is inactive; no Mount action is admitted.") end
    if ui:button("bmx_play_mount","Mount bike") then bike:mount() end
    if ui:button("bmx_play_return","Return to skateboard") then bike:return_to_skateboard() end
    if ui:button("bmx_play_cancel","Cancel / stop and keep cleanup") then bike:cancel() end
    s=bike:status()
    ui:info("State",s.phase)
    ui:note(s.detail)
    if s.phase=="blocked" or s.phase=="stopped" then ui:note(s.lifecycle_detail) end
    ui:note("Mount prepares the native service and surveys the area. Stay still, then close menus and release all controls.")
    ui:note("The bounded ride ends after 60 s. Remounting needs a new experimental session; no retries are hidden.")
    ui:info("Lifecycle",tostring(s.core_phase))
    ui:info("Cleanup pending / unknown",tostring(s.cleanup_pending).." / "..tostring(s.cleanup_unknown))
end)
reskate.on("unload",function() bike:unload() end)

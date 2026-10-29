return function(reskate, require)
-- Separate experimental TWO-attempt package; Root owns review and deployment.
local EXPERIMENTAL_ADMITTED=false
local SESSION_RENEWABLE=false
local SLOT=0
local Runtime=require("./bike_runtime")
local Survey=require("./ride_r1_record")
local Entry=require("./bmx_playable_entry")
local bike=Entry.new(reskate,Runtime,Survey,{admitted=EXPERIMENTAL_ADMITTED,slot=SLOT,experimental_two_cycle=true,session_renewable=SESSION_RENEWABLE})
reskate.input.bind("bmx_return","F8")
reskate.on("action",function(name)
    if name=="bmx_return" then bike:return_to_skateboard() end
end)
reskate.on("tick",function(dt_ms) bike:step(dt_ms) end)
reskate.menu.page("BMX experimental",function(ui)
    local s=bike:status()
    ui:warn("Experimental: at most TWO attempts; each uses a new retained body slot. Start on foot on flat ground with 1.25 m clear around you for spawning.")
    if not s.admitted then ui:note("This reviewed source build is inactive; no Mount action is admitted.") end
    if ui:button("bmx_play_mount","Mount bike") then bike:mount() end
    if ui:button("bmx_play_return","Return to skateboard") then bike:return_to_skateboard() end
    if ui:button("bmx_play_cancel","Cancel / stop and keep cleanup") then bike:cancel() end
    s=bike:status()
    ui:info("State",s.phase)
    ui:note(s.detail)
    ui:note("F8: return to skateboard (remappable in Binds).")
    if s.phase=="blocked" or s.phase=="stopped" then ui:note(s.lifecycle_detail) end
    ui:note("First Mount requires on-foot504. Second Mount requires current stock100 after clean Return, then visibly obtains504 before a NEW survey. Stay still and neutral.")
    if SESSION_RENEWABLE then
        ui:note("Ride continues until Return or stop. After clean stock Return, Mount once more first obtains on-foot504. Slots are never reclaimed. Only proven first preflight terrain refusals can retry; other failures end the attempt.")
    else
        ui:note("Each ride is bounded to60s. After clean stock Return, Mount once more first obtains on-foot504. Slots are never reclaimed. Only proven first preflight terrain refusals can retry; other failures end the attempt.")
    end
    ui:info("Attempts used / limit",tostring(s.attempts_used).." / "..tostring(s.attempt_limit))
    ui:info("Terrain refusals / limit",tostring(s.terrain_refusal_count).." / "..tostring(s.terrain_refusal_limit))
    ui:info("Lifecycle",tostring(s.core_phase))
    ui:info("Cleanup pending / unknown",tostring(s.cleanup_pending).." / "..tostring(s.cleanup_unknown))
end)
reskate.on("unload",function() bike:unload() end)

end

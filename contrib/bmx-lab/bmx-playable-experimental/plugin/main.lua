-- Separate experimental TWO-attempt package; Root owns review and deployment.
local EXPERIMENTAL_ADMITTED=false
local SESSION_RENEWABLE=false
local SLOT=0
local Runtime=require("./bike_runtime")
local Survey=require("./ride_r1_record")
local Entry=require("./bmx_playable_entry")
local ScoreHUD=require("./score_hud")
local bike=Entry.new(reskate,Runtime,Survey,{admitted=EXPERIMENTAL_ADMITTED,slot=SLOT,experimental_two_cycle=true,session_renewable=SESSION_RENEWABLE})
local unloaded=false
local score_lines
local function score_snapshot()
    local view,issue,landing=bike:score_view()
    return ScoreHUD.lines(view,issue,landing)
end
local function draw_score_lines(d)
    if unloaded or not score_lines then return end
    local size=d:size()
    local width,height=size.x,size.y
    if not (width>=320 and height>=240 and width<=16384 and height<=16384) then return end
    local scale=height/1080
    if width/scale<400 then return end
    local limit=math.clamp(math.floor((width/scale-72)/20),16,ScoreHUD.MAX_TEXT)
    for i=1,math.min(#score_lines,ScoreHUD.MAX_LINES) do
        local text=ScoreHUD.fit(score_lines[i],limit)
        d:text(vector.create(36*scale,(36+(i-1)*24)*scale,0),text,
            i==1 and ScoreHUD.header_style or ScoreHUD.row_style)
    end
end
reskate.input.bind("bmx_return","F8")
reskate.input.bind("bmx_recover","F9")
reskate.input.bind("bmx_recover_pad","Pad.LB+Pad.RB+Pad.L3")
reskate.input.bind("bmx_return_pad","Pad.LB+Pad.RB+Pad.R3")
reskate.input.bind("bmx_mount_pad","Pad.LB+Pad.A")
reskate.on("action",function(name)
    if name=="bmx_return" or name=="bmx_return_pad" then bike:return_to_skateboard()
    elseif (name=="bmx_recover" or name=="bmx_recover_pad") and not unloaded then
        local s=bike:status()
        if s.recovery_available==true then bike:recover() end
    elseif name=="bmx_mount_pad" then bike:mount() end
end)
reskate.on("tick",function(dt_ms)
    bike:step(dt_ms)
    -- Optional score formatting cannot interrupt the riding owner.
    local ok,text=pcall(score_snapshot)
    score_lines=ok and text or nil
end)
reskate.on("draw",function(d) pcall(draw_score_lines,d) end)
reskate.menu.page("BMX experimental",function(ui)
    local s=bike:status()
    ui:warn("Experimental: at most TWO attempts; each uses a new retained body slot. Start on foot on flat ground with 1.25 m clear around you for spawning.")
    if not s.admitted then ui:note("This reviewed source build is inactive; no Mount action is admitted.") end
    ui:warn("Opening Insert ends an active ride. F8 or LB + RB + R3 returns; F9 or LB + RB + L3 recovers after a fall.")
    if ui:button("bmx_play_mount","Mount bike") then bike:mount() end
    if ui:button("bmx_play_return","Return to skateboard") then bike:return_to_skateboard() end
    if ui:button("bmx_play_cancel","Cancel / stop and keep cleanup") then bike:cancel() end
    if s.fall_reason then
        ui:warn("Fallen: "..s.fall_reason)
        if s.recovery_available then
            if ui:button("bmx_play_recover","Recover bike") then bike:recover() end
        elseif s.recovery_pending then ui:note("Recover requested. Close menus and release controls while Return completes.")
        elseif s.attempts_used>=s.attempt_limit then ui:note("Both bike attempts are spent. Return to skateboard remains available.") end
        if s.attempts_used<s.attempt_limit then ui:note("Recovery uses the remaining attempt and checks fresh flat ground.") end
        ui:note("The stopped bike is removed during normal cleanup.")
    end
    s=bike:status()
    ui:info("State",s.phase)
    ui:note(s.detail)
    ui:note("Hold LB, then press A to request Mount. Start on foot and release all controls while preparing (remappable in Binds).")
    ui:note("F8: return to skateboard (remappable in Binds).")
    ui:note("Hold LB + RB, then click R3 to return to skateboard. Release all controls while Return runs (remappable in Binds).")
    ui:note("F9: recover bike after a fall (remappable in Binds).")
    ui:note("LB + RB + L3: recover after a fall; release all controls while recovery runs (remappable in Binds).")
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
reskate.on("unload",function() unloaded=true;score_lines=nil;bike:unload() end)

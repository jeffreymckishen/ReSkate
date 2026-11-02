-- Separate experimental TWO-attempt package; Root owns review and deployment.
local EXPERIMENTAL_ADMITTED=false
local SESSION_RENEWABLE=false
local SLOT=0
local Runtime=require("./bike_runtime")
local Survey=require("./ride_r1_record")
local Entry=require("./bmx_playable_entry")
local ScoreHUD=require("./score_hud")
local bike=Entry.new(reskate,Runtime,Survey,{admitted=EXPERIMENTAL_ADMITTED,slot=SLOT,experimental_two_cycle=true,session_renewable=SESSION_RENEWABLE,auto_return=true})
local unloaded=false
local score_lines
local function score_snapshot()
    local view,issue,landing=bike:score_view()
    local lines=ScoreHUD.lines(view,issue,landing)
    local help=bike.help_line and bike:help_line()
    if not help then return lines end
    local shown=table.clone(lines) -- The panel's six rows are full: this takes the last one while the mod is busy.
    shown[#shown]=help
    return shown
end
local function draw_score_lines(d)
    if unloaded or not score_lines then return end
    local size=d:size()
    local width,height=size.x,size.y
    if not (width>=320 and height>=240 and width<=16384 and height<=16384) then return end
    local scale=height/1080
    if width/scale<400 then return end
    local limit=math.clamp(math.floor((width/scale-72)/20),16,ScoreHUD.MAX_TEXT)
    local count=math.min(#score_lines,ScoreHUD.MAX_LINES)
    if count==0 then return end
    local rows,right,bottom={},36*scale,36*scale
    for i=1,count do
        local text=ScoreHUD.fit(score_lines[i],limit)
        local style=i==1 and ScoreHUD.header_style or ScoreHUD.row_style
        -- d:measure already returns display pixels; scale only the padding.
        local extent=d:measure(text,style)
        rows[i]={text=text,style=style}
        right=math.max(right,36*scale+extent.x)
        bottom=math.max(bottom,(36+(i-1)*24)*scale+extent.y)
    end
    local padding=12*scale
    d:rect(vector.create(24*scale,24*scale,0),
        vector.create(math.min(width-24*scale,right+padding),math.min(height-24*scale,bottom+padding),0),ScoreHUD.panel_style)
    for i=1,count do
        d:text(vector.create(36*scale,(36+(i-1)*24)*scale,0),rows[i].text,rows[i].style)
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
reskate.menu.page("BMX",function(ui)
    local s=bike:status()
    if not s.admitted then ui:note("This build is inactive; Mount does nothing.") end
    ui:note("First ride of a launch: on foot on flat ground with a little room around you, hold LB, then press A, and let go of the controls while the bike gets ready.")
    ui:note("A pedals, B brakes, the left stick steers, clicking the right stick hops.")
    ui:note("F8 or LB + RB + R3 goes back to the skateboard. A ride that ends any other way goes back on its own, and a fall gets you back on the bike.")
    ui:note("Back on the skateboard, hold LB, then press A to ride again, standing still with the controls released. Pausing or opening Insert ends the ride.")
    ui:note("Each game launch allows "..tostring(s.attempt_limit).." mounts; restart the game for more. Mounting and going back to the skateboard can be changed in Binds.")
    if ui:button("bmx_play_mount","Mount bike") then bike:mount() end
    if ui:button("bmx_play_return","Return to skateboard") then bike:return_to_skateboard() end
    if s.fall_reason then ui:warn("Fallen: "..s.fall_reason) end
    if s.last_stop then ui:info("Last ride ended",s.last_stop) end
    if s.phase=="blocked" or s.phase=="stopped" then ui:note(s.lifecycle_detail) end
    ui:info("State",s.phase)
    ui:note(s.detail)
    ui:info("Mounts used",tostring(s.attempts_used).." of "..tostring(s.attempt_limit))
end)
reskate.on("unload",function() unloaded=true;score_lines=nil;bike:unload() end)

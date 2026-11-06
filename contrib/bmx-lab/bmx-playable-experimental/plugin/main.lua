-- Separate experimental TWO-attempt package; Root owns review and deployment.
local EXPERIMENTAL_ADMITTED=false
local SESSION_RENEWABLE=false
local SLOT=0
local Runtime=require("./bike_runtime")
local Survey=require("./ride_r1_record")
local Entry=require("./bmx_playable_entry")
local ScoreHUD=require("./score_hud")
local YButton=require("./y_button")
-- The one storage key that outlives a launch: whether bike mode is on. Entry keeps it at load and clears the rest.
local SETTINGS_KEY="bmx_settings_v1"
local bike=Entry.new(reskate,Runtime,Survey,{admitted=EXPERIMENTAL_ADMITTED,slot=SLOT,experimental_two_cycle=true,session_renewable=SESSION_RENEWABLE,auto_return=true,settings_key=SETTINGS_KEY})
-- Bike mode: Y gets on the bike and off it. Made after Entry, whose load has already cleared a malformed setting.
local ybutton=YButton.new(reskate,bike,SETTINGS_KEY)
local unloaded=false
local score_lines
local function score_snapshot()
    local view,issue,landing=bike:score_view()
    local lines=ScoreHUD.lines(view,issue,landing)
    -- In place of Entry's line: what a Y press being carried out waits for, and for a few seconds why one did not
    -- bring the bike.
    local help=ybutton:notice() or bike.help_line and bike:help_line()
    if not help then return lines end
    -- Before the first ride there is no score to show, and the help is all the panel has: getting ready, checking
    -- for room, or why a Mount did not start.
    if lines==nil then return table.freeze({help}) end
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
-- Does nothing until bike mode is switched on.
reskate.input.bind("bmx_y","Pad.Y")
reskate.on("action",function(name)
    if name=="bmx_y" then ybutton:press();return end
    -- The others ask Entry for a Return, Recover or Mount: a Y press being carried out is dropped first, so the two
    -- do not both ask (y_button.lua).
    ybutton:drop_press()
    if name=="bmx_return" or name=="bmx_return_pad" then bike:return_to_skateboard()
    elseif (name=="bmx_recover" or name=="bmx_recover_pad") and not unloaded then
        local s=bike:status()
        if s.recovery_available==true then bike:recover() end
    elseif name=="bmx_mount_pad" then bike:mount() end
end)
reskate.on("tick",function(dt_ms)
    bike:step(dt_ms)
    ybutton:step()
    -- Optional score formatting cannot interrupt the riding owner.
    local ok,text=pcall(score_snapshot)
    score_lines=ok and text or nil
end)
reskate.on("draw",function(d) pcall(draw_score_lines,d) end)
reskate.menu.page("BMX",function(ui)
    local s=bike:status()
    if not s.admitted then ui:note("This build is inactive; Mount does nothing.") end
    local mode=ui:toggle("bmx_bike_mode","Switch to bike: Y gets on and off",ybutton:enabled(),
        "On foot or on the skateboard, standing still, Y gets on the bike, and riding, Y goes back to the skateboard."
        .." LB + A, F8 and LB + RB + R3 still work. Kept for later launches until switched off.")
    if mode~=ybutton:enabled() then ybutton:set_enabled(mode) end
    if ybutton:enabled() then
        ui:note("Bike mode: standing still on foot or on the skateboard, press Y once and let go of the controls while the bike gets ready. Don't press Y again until you ride. Riding, Y goes back to the skateboard.")
        ui:note("Y is then for the bike. Before the first ride of a launch, on the skateboard, Y steps off first. After it, on foot, Y brings the skateboard out first, and on the skateboard Y no longer steps off. When no ride can start, Y does what it does in the game. LB + A, F8 and LB + RB + R3 still work.")
        ui:note("A PlayStation controller without Steam Input can still pass Y to the game. The HUD then says so: press Y again.")
    end
    ui:note("First ride of a launch: on foot on flat ground with a little room around you, hold LB, then press A, and let go of the controls while the bike gets ready.")
    ui:note("A pedals, B brakes, the left stick steers, clicking the right stick hops.")
    ui:note("F8 or LB + RB + R3 goes back to the skateboard. A ride that ends any other way goes back on its own, and a fall gets you back on the bike.")
    ui:note("Back on the skateboard, hold LB, then press A to ride again, standing still with the controls released. Pausing or opening Insert ends the ride.")
    -- Only a ReSkate that cannot reuse the parked bike limits the mounts of a launch.
    if s.body_reuse==false then ui:note("This ReSkate allows "..tostring(s.attempt_limit).." mounts a game launch; restart the game for more.") end
    ui:note("Mounting and going back to the skateboard can be changed in Binds.")
    if ui:button("bmx_play_mount","Mount bike") then ybutton:drop_press();bike:mount() end
    if ui:button("bmx_play_return","Return to skateboard") then ybutton:drop_press();bike:return_to_skateboard() end
    if s.fall_reason then ui:warn("Fallen: "..s.fall_reason) end
    if s.last_stop then ui:info("Last ride ended",s.last_stop) end
    if s.phase=="blocked" or s.phase=="stopped" then ui:note(s.lifecycle_detail) end
    ui:info("State",s.phase)
    ui:note(s.detail)
    ui:info("Mounts used",tostring(s.attempts_used)..(s.body_reuse==false and " of "..tostring(s.attempt_limit) or ""))
end)
reskate.on("unload",function() unloaded=true;score_lines=nil;ybutton:unload();bike:unload() end)

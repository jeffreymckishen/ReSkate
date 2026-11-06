return function(reskate, require)
-- Separate experimental TWO-attempt package; Root owns review and deployment.
local EXPERIMENTAL_ADMITTED=false
local SESSION_RENEWABLE=false
local SLOT=0
local Runtime=require("./bike_runtime")
local Survey=require("./ride_r1_record")
local Entry=require("./bmx_playable_entry")
local bike=Entry.new(reskate,Runtime,Survey,{admitted=EXPERIMENTAL_ADMITTED,slot=SLOT,experimental_two_cycle=true,session_renewable=SESSION_RENEWABLE,auto_return=true})
local unloaded=false
-- The mod draws no score of its own. All it puts on screen is Entry's help, one line, and only while the mod needs
-- something from the rider: stand still while the bike gets ready, let go of the controls, press A to get up, or why
-- a Mount did not start. Nothing is drawn during a normal ride, or on the skateboard when there is nothing to say.
local MAX_HELP=96
-- Positions are scaled here. SDK style sizes already scale by screen height in the overlay, so the font size is not.
local HELP_STYLE=table.freeze({colour="#FFFFFF",size=18,font="body",shadow=true})
local BACKING_STYLE=table.freeze({colour="#10151DE6",fill=true,rounding=8})
local help_text
local function read_help()
    local help=bike:help_line()
    if type(help)~="string" or help=="" then return nil end
    -- Cut before cleaning, so a long message cannot grow the work. Only printable ASCII is kept: a cut can split a
    -- UTF-8 character, and a newline would make the one line two.
    return (string.gsub(string.sub(help,1,MAX_HELP),"[^ -~]","?"))
end
-- The line sits at the top left, where the mod's score panel used to be: in play that spot was clear of the game's
-- controller hints and under ReSkate's own notices.
local function draw_help(d)
    if unloaded or not help_text then return end
    local size=d:size()
    local width,height=size.x,size.y
    if not (width>=320 and height>=240 and width<=16384 and height<=16384) then return end
    local scale=height/1080
    if width/scale<400 then return end
    -- Allowing about 20 pixels a character at 1080p keeps the line inside the window with room to spare.
    local limit=math.clamp(math.floor((width/scale-72)/20),16,MAX_HELP)
    local text=help_text
    if #text>limit then text=string.sub(text,1,limit-3).."..." end
    -- d:measure already returns display pixels; scale only the padding.
    local extent=d:measure(text,HELP_STYLE)
    local padding=12*scale
    d:rect(vector.create(24*scale,24*scale,0),vector.create(math.min(width-24*scale,36*scale+extent.x+padding),
        math.min(height-24*scale,36*scale+extent.y+padding),0),BACKING_STYLE)
    d:text(vector.create(36*scale,36*scale,0),text,HELP_STYLE)
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
    -- The help is read in its own pcall, so it cannot interrupt the riding owner, and the draw reads only what it left.
    local ok,help=pcall(read_help)
    help_text=ok and help or nil
end)
reskate.on("draw",function(d) pcall(draw_help,d) end)
reskate.menu.page("BMX",function(ui)
    local s=bike:status()
    if not s.admitted then ui:note("This build is inactive; Mount does nothing.") end
    ui:note("First ride of a launch: on foot on flat ground with a little room around you, hold LB, then press A, and let go of the controls while the bike gets ready.")
    ui:note("A pedals, B brakes, the left stick steers, clicking the right stick hops.")
    ui:note("F8 or LB + RB + R3 goes back to the skateboard. A ride that ends any other way goes back on its own, and a fall gets you back on the bike.")
    ui:note("Back on the skateboard, hold LB, then press A to ride again, standing still with the controls released. Pausing or opening Insert ends the ride.")
    -- Only a ReSkate that cannot reuse the parked bike limits the mounts of a launch.
    if s.body_reuse==false then ui:note("This ReSkate allows "..tostring(s.attempt_limit).." mounts a game launch; restart the game for more.") end
    ui:note("Mounting and going back to the skateboard can be changed in Binds.")
    if ui:button("bmx_play_mount","Mount bike") then bike:mount() end
    if ui:button("bmx_play_return","Return to skateboard") then bike:return_to_skateboard() end
    if s.fall_reason then ui:warn("Fallen: "..s.fall_reason) end
    if s.last_stop then ui:info("Last ride ended",s.last_stop) end
    if s.phase=="blocked" or s.phase=="stopped" then ui:note(s.lifecycle_detail) end
    ui:info("State",s.phase)
    ui:note(s.detail)
    ui:info("Mounts used",tostring(s.attempts_used)..(s.body_reuse==false and " of "..tostring(s.attempt_limit) or ""))
end)
reskate.on("unload",function() unloaded=true;help_text=nil;bike:unload() end)

end

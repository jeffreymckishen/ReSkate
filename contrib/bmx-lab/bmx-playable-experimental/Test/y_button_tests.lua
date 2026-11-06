-- Bike mode's Y (plugin/y_button.lua): when Y is kept from the game, and what one press asks of the Entry.
-- The first cases build the game and the Entry: every reskate call, the Entry's answers and the rider's state are set
-- by the case. The last ones put the real Entry, facade, Core, Equipment and Source behind it (remount_chain_fixture),
-- with a game whose own Y moves the rider between the board and on foot.
-- Nothing here is the plugin Host, the SDK's mask, a native pulse or the game.
local Y=require("./y_button")
local Chain=require("./remount_chain_fixture")
local T={}
local KEY="bmx_settings_v1"
local Y_BIT=0x8000
local LEAK="The game got the Y, as it can on some controllers. Hold LB and press A instead."
local IDLE={"idle","skateboard","preflight_refused","blocked","spent"}
local BUSY={"preparing","surveying","awaiting_mount","mounting","riding","stepping_off","returning","fallen","stopped",
    "cancelled","unloaded"}
local function copy(v)
    if type(v)~="table" then return v end
    local out={};for k,c in pairs(v) do out[k]=copy(c) end;return out
end
local function on_record() return {[KEY]={schema=1,bike_mode=true}} end

-- A constructed game and Entry around one y_button. start=false means no Mount can start; key=false gives no key.
local function world(options)
    options=options or {}
    local w={now=1000,focused=true,gameplay=true,interface_open=false,game_menu=false,pad=Chain.neutral_pad(),
        state=options.state or 100,airborne=false,ragdoll=false,records=options.records or {},
        phase=options.phase or "skateboard",recovery_pending=false,return_requested=false,
        mask=0,calls=0,held_changes=0,events={},lines={},mounts=0,returns=0,sets=0,controls={}}
    if options.start==nil then w.start=100 elseif options.start then w.start=options.start end
    local R={time={},input={},menu={},skater={},storage={}}
    function R.log(line) w.lines[#w.lines+1]=line end
    function R.time.now() return w.now end
    function R.input.focus() return {focused=w.focused,gameplay=w.gameplay,interface_open=w.interface_open} end
    function R.menu.game() return {open=w.game_menu} end
    function R.input.gamepad() return w.pad and copy(w.pad) or nil end
    function R.input.game_buttons(hidden,held,pause)
        w.calls+=1
        if w.refuse then error("constructed game_buttons refusal",0) end
        assert(held==0 and pause==false,"Y is hidden from the game, never held for it, and pause is left alone")
        -- Hiding a held Y hands the game a release, and giving it back a press.
        if w.pad and w.pad.buttons.y then w.held_changes+=1 end
        w.mask=hidden;w.events[#w.events+1]="mask "..hidden
        return true
    end
    function R.skater.telemetry()
        return {skater=true,airborne=w.airborne,teleport_pending=false,
            watch={valid=true,state=w.state,ragdoll_known=true,ragdoll=w.ragdoll,wipeouts=0}}
    end
    function R.skater.get() return {airborne=w.airborne} end
    function R.storage.get(k) return copy(w.records[k]) end
    function R.storage.set(k,v)
        w.sets+=1
        if w.storage_refuse then error("constructed storage refusal",0) end
        w.records[k]=copy(v)
    end
    local bike={}
    function bike:status() return {phase=w.phase,recovery_pending=w.recovery_pending,return_requested=w.return_requested} end
    function bike:next_start_state() return w.start end
    function bike:mount()
        w.mounts+=1;w.events[#w.events+1]="mount mask "..w.mask
        if w.on_mount then w.on_mount() end
        return true
    end
    function bike:return_to_skateboard() w.returns+=1;w.events[#w.events+1]="return";return true end
    function bike:set_controls(kind) w.controls[#w.controls+1]=kind;return true end
    w.R,w.bike=R,bike
    local key=KEY
    if options.key==false then key=nil end
    w.y=Y.new(R,bike,key)
    function w.tick(n) for _=1,n or 1 do w.now+=16;w.y:step() end end
    -- The bind fires on the press, with the pad already showing Y down; it is held for ms, then let go.
    function w.press(ms)
        w.pad.buttons.y=true
        local out=w.y:press()
        w.tick(math.ceil((ms or 100)/16))
        w.pad.buttons.y=false
        return out
    end
    return w
end
-- Bike mode on, as a kept setting turns it on at load, with one tick so the mask follows.
local function on(options)
    options=options or {}
    options.records=options.records or on_record()
    local w=world(options)
    w.tick()
    return w
end

-- The real chain behind the button. Y_BIT hidden while a lease, capture or pulse is live, or a Mount, lease or pulse
-- asked for under the mask, fails the case: in the SDK a change of the mask revokes all three, and a hidden button
-- refuses the mod's own pulses.
local function chain(check,options)
    options=options or {}
    local w=Chain.new({entry={settings_key=KEY},storage=on_record()})
    w.stock=options.stock or 504
    w.mask,w.mask_calls,w.mounts=0,0,0
    local R=w.R
    function R.input.game_buttons(hidden,held,pause)
        w.mask_calls+=1
        check(held==0 and pause==false,"only Y is hidden from the game")
        check(w.handle==nil and w.capture==nil and w.pulse==nil,"the mask changes with no lease, capture or pulse live")
        check(not w.pad.buttons.y,"and only with Y up")
        w.mask=hidden;w.log("mask "..hidden)
        return true
    end
    local lease,capture=R.input.lease,R.input.lease_capture
    R.input.lease=function(...) check(w.mask==0,"no lease is asked for with Y hidden");return lease(...) end
    R.input.lease_capture=function(...) check(w.mask==0,"no capture is asked for with Y hidden");return capture(...) end
    w.on_pulse=function() check(w.mask==0,"the Entry's own Y goes out with nothing hidden") end
    -- The Entry as main.lua hands it over, counting each Mount.
    local entry=w.entry
    local bike={}
    for _,name in {"status","next_start_state","set_controls","return_to_skateboard"} do
        bike[name]=function(_,...) return entry[name](entry,...) end
    end
    function bike:mount()
        check(w.mask==0,"a Mount is asked for with Y back with the game")
        w.mounts+=1
        return entry:mount()
    end
    w.y=Y.new(R,bike,KEY)
    -- The game's own Y, about 80 ms after a press it saw: on foot it brings out the board, on the board it steps off.
    -- main.lua steps the button after the Entry each tick; here it runs at the start of the next, the same order.
    w.on_tick=function()
        if w.game_y_at and w.now>=w.game_y_at then
            w.game_y_at=nil;w.stock=w.stock==100 and 504 or 100;w.log("the game's Y: stock now "..w.stock)
        end
        w.y:step()
    end
    -- A press of Y. The game sees it unless it is hidden, or a riding capture hands the game a neutral pad. leaky: a
    -- PlayStation pad the mask does not cover.
    function w.press_y(ms)
        w.pad.buttons.y=true
        local capturing=w.capture~=nil and w.capture.capturing==true
        if (w.mask==0 or w.leaky) and not capturing then w.game_y_at=w.now+80 end
        local out=w.y:press()
        w.tick(math.ceil((ms or 100)/16))
        w.pad.buttons.y=false
        return out
    end
    function w.until_true(test,limit)
        for _=1,limit or 4000 do
            w.tick()
            if test() then return true end
        end
        return false
    end
    function w.phase() return w.entry:status().phase end
    return w
end

function T.run()
    local cases,n=0,0
    local function check(v,why) n+=1;assert(v,why) end
    local function case(body) cases+=1;body() end
    local function same(list,want)
        if #list~=#want then return false end
        for i=1,#want do if list[i]~=want[i] then return false end end
        return true
    end
    case(function() -- Off by default, and a missing or malformed setting is off: Y does nothing, and is never hidden.
        local stored={{},{[KEY]={schema=1,bike_mode=false}},{[KEY]={schema=2,bike_mode=true}},
            {[KEY]={schema=1,bike_mode="true"}},{[KEY]="on"},{[KEY]=true}}
        for i,records in ipairs(stored) do
            local w=world({records=records})
            check(w.y:enabled()==false,"setting "..i.." is off")
            w.tick(5)
            check(w.press(100)==false and w.mounts==0 and w.calls==0,"Y asks nothing and is not hidden: "..i)
            w.phase="riding"
            check(w.press(100)==false and w.returns==0,"not even riding: "..i)
            check(#w.controls==0 and w.sets==0,"and the Entry's words and the storage are left alone: "..i)
        end
        local w=world({records=on_record(),key=false})
        check(w.y:enabled()==false,"without a key nothing is read")
    end)
    case(function() -- A kept setting turns bike mode on at load, and the Entry is told to name Y; nothing is written.
        local w=on()
        check(w.y:enabled()==true and same(w.controls,{"y"}) and w.sets==0,"on, Y named, no write")
        check(w.mask==Y_BIT and w.calls==1,"and Y is hidden on the board before a later ride")
    end)
    case(function() -- The switch writes its key only when it changes, and switching off clears it.
        local w=world()
        check(w.y:set_enabled(true)==true and w.y:enabled() and w.sets==1,"switched on, written once")
        local r=w.records[KEY]
        check(r.schema==1 and r.bike_mode==true,"the record")
        local fields=0;for _ in pairs(r) do fields+=1 end
        check(fields==2,"and nothing else in it")
        check(same(w.controls,{"y"}),"the Entry names Y")
        check(w.y:set_enabled(true)==false and w.sets==1,"no write when nothing changes")
        check(world({records=copy(w.records)}).y:enabled(),"the next launch reads it")
        check(w.y:set_enabled(false)==true and w.sets==2 and w.records[KEY]==nil,"switched off: the key is cleared")
        check(same(w.controls,{"y","lb_a"}),"and the Entry names LB + A again")
        check(w.y:set_enabled(false)==false and w.sets==2,"no write when nothing changes")
        w.storage_refuse=true
        check(w.y:set_enabled(true)==true and w.y:enabled(),"a refused write still switches it for this launch")
        check(string.find(w.lines[#w.lines],"could not be kept",1,true)~=nil,"and says so in the log")
        w.y:unload()
        check(w.y:set_enabled(false)==false and w.y:enabled(),"nothing switches after unload")
    end)
    case(function() -- Y is hidden only while the mod is idle with the rider standing in the state the next ride starts from.
        for _,phase in IDLE do
            local w=on({phase=phase})
            check(w.mask==Y_BIT,"idle in "..phase)
            for _,busy in BUSY do
                w.phase=busy;w.tick()
                check(w.mask==0,"given back in "..busy)
                w.phase=phase;w.tick()
                check(w.mask==Y_BIT,"and hidden again in "..phase)
            end
        end
        local w=on({start=504,state=504,phase="idle"})
        check(w.mask==Y_BIT,"on foot before the first ride")
        local function given_back(why,set,reset)
            set(w);w.tick()
            check(w.mask==0,why)
            reset(w);w.tick()
            check(w.mask==Y_BIT,"and hidden again after: "..why)
        end
        given_back("a Recover owed",function(x) x.recovery_pending=true end,function(x) x.recovery_pending=false end)
        given_back("a Return asked for",function(x) x.return_requested=true end,function(x) x.return_requested=false end)
        given_back("no Mount can start",function(x) x.start=nil end,function(x) x.start=504 end)
        given_back("on the board when the ride starts on foot",function(x) x.state=100 end,function(x) x.state=504 end)
        given_back("in the air",function(x) x.airborne=true end,function(x) x.airborne=false end)
        given_back("ragdolled",function(x) x.ragdoll=true end,function(x) x.ragdoll=false end)
        given_back("in a trick or any other state",function(x) x.state=300 end,function(x) x.state=504 end)
        check(w.held_changes==0,"never with Y down")
    end)
    case(function() -- The mask moves only with Y up: Y held through a change of phase never moves it.
        local w=on()
        local calls=w.calls
        w.pad.buttons.y=true;w.phase="preparing";w.tick(20)
        check(w.mask==Y_BIT and w.calls==calls,"held, the mask stays")
        w.pad.buttons.y=false;w.tick()
        check(w.mask==0 and w.calls==calls+1,"let go, it is given back")
        w.pad.buttons.y=true;w.phase="skateboard";w.tick(20)
        check(w.mask==0 and w.calls==calls+1,"held, it is not hidden either")
        w.pad.buttons.y=false;w.tick()
        check(w.mask==Y_BIT and w.held_changes==0,"let go, it is")
        -- A pad that cannot be read is most likely gone: Y can be given back then, but not hidden.
        w.pad=nil;w.phase="preparing";w.tick()
        check(w.mask==0,"given back with no pad")
        w.phase="skateboard";w.tick(10)
        check(w.mask==0,"and not hidden with no pad")
        w.pad=Chain.neutral_pad();w.tick()
        check(w.mask==Y_BIT,"the pad back, it is")
    end)
    case(function() -- A game menu, a ReSkate surface, the game out of front or bike mode off give Y back at once.
        local away={game_menu=true,interface_open=true,focused=false,gameplay=false}
        for field,value in pairs(away) do
            local w=on()
            local before=w[field]
            w.pad.buttons.y=true;w[field]=value;w.tick()
            check(w.mask==0,"given back at once, Y held: "..field)
            check(w.y:press()==false and w.mounts==0,"and Y asks nothing: "..field)
            w.tick(30)
            check(w.mask==0 and w.mounts==0,"while it lasts: "..field)
            w[field]=before;w.pad.buttons.y=false;w.tick()
            check(w.mask==Y_BIT,"hidden again after: "..field)
            -- A press being carried out when it happens is dropped.
            check(w.press(100)==true and w.y:status().pending=="guard","a press: "..field)
            w[field]=value;w.tick()
            check(w.y:status().pending==nil,"dropped: "..field)
            w[field]=before;w.tick(60)
            check(w.mounts==0,"and never asks for the bike: "..field)
        end
        local w=on()
        w.pad.buttons.y=true
        check(w.y:set_enabled(false)==true and w.mask==0 and w.calls==2,"switched off, given back before the next tick")
        w.tick(10)
        check(w.calls==2,"and left alone")
    end)
    case(function() -- A press with Y hidden asks for the bike once Y has been up 300 ms, giving Y back first.
        local w=on()
        w.on_mount=function() w.phase="stepping_off" end
        w.events={}
        check(w.press(100)==true and w.y:status().pending=="guard","the press is carried out")
        check(w.y:press()==false,"a second while it is says no")
        w.tick(15)
        check(w.mounts==0,"Y up 240 ms: not yet")
        w.tick(5)
        check(w.mounts==1 and same(w.events,{"mask 0","mount mask 0"}),"then Y back, then the Mount: "..table.concat(w.events,","))
        w.tick(30)
        check(w.mask==0 and w.mounts==1 and w.y:status().pending==nil,"busy, Y stays with the game")
        -- Held past 6 s it is dropped, with no word.
        local held=on()
        check(held.press(6100)==true,"a long press")
        held.tick(40)
        check(held.mounts==0 and held.y:status().pending==nil and held.y:notice()==nil,"dropped without a word")
        check(held.mask==Y_BIT,"and Y stays hidden for the next")
        -- The Entry not idle any more, or its next start changing, drops it too.
        local moved=on()
        moved.press(100);moved.start=504;moved.tick(40)
        check(moved.mounts==0 and moved.y:status().pending==nil,"a changed start drops it")
    end)
    case(function() -- A Y the game took anyway moves the rider: the press is dropped, with a word that LB + A works.
        local w=on()
        w.pad.buttons.y=true
        check(w.y:press()==true,"pressed")
        w.tick(5);w.state=504;w.tick()
        check(w.y:status().pending==nil and w.y:notice()==LEAK,"dropped, and told")
        check(w.mask==Y_BIT,"held, the mask stays")
        w.pad.buttons.y=false;w.tick()
        check(w.mask==0,"let go, on foot is not where a later ride starts, so it is given back")
        w.tick(60)
        check(w.mounts==0,"and the bike is not asked for")
        w.tick(200)
        check(w.y:notice()==nil,"the word goes after 4 s")
        -- A rider who leaves the ground or ragdolls during the press: dropped, without the word.
        for _,field in {"airborne","ragdoll"} do
            local x=on()
            x.pad.buttons.y=true;x.y:press();x.tick(3);x[field]=true;x.tick()
            check(x.y:status().pending==nil and x.y:notice()==nil,"dropped quietly: "..field)
            x.pad.buttons.y=false;x[field]=false;x.tick(60)
            check(x.mounts==0,"no Mount: "..field)
        end
    end)
    case(function() -- First ride from the board: the game's Y steps the rider off, and the bike comes once they stand still.
        local w=on({start=504,state=100,phase="idle"})
        w.on_mount=function() w.phase="preparing" end
        check(w.mask==0 and w.calls==0,"on the board before the first ride, Y is the game's")
        w.pad.buttons.y=true
        check(w.y:press()==true and w.y:status().pending=="arrive","the press waits for the rider")
        w.tick(5);w.state=504;w.tick(2);w.pad.buttons.y=false
        w.tick(30)
        check(w.mounts==0,"480 ms at rest: not yet")
        check(w.calls==0,"and Y is not hidden while they arrive")
        w.tick(10)
        check(w.mounts==1 and same(w.events,{"mount mask 0"}),"600 ms at rest: the Mount, with Y the game's: "..table.concat(w.events,","))
        -- A stick pushed while waiting starts the rest again.
        local x=on({start=504,state=100,phase="idle"})
        x.pad.buttons.y=true;x.y:press();x.tick(5);x.state=504;x.pad.buttons.y=false
        x.tick(20);x.pad.left_x=.6;x.tick(20)
        check(x.mounts==0,"no Mount with the stick pushed")
        x.pad.left_x=0;x.tick(30)
        check(x.mounts==0,"480 ms after it is let go: not yet")
        x.tick(10)
        check(x.mounts==1,"600 ms: the Mount")
        -- A rider who never arrives: dropped after 6 s.
        local never=on({start=504,state=100,phase="idle"})
        never.press(100);never.tick(400)
        check(never.mounts==0 and never.y:status().pending==nil,"never arriving, dropped")
    end)
    case(function() -- A later ride from on foot: the game's Y brings out the board first.
        local w=on({start=100,state=504})
        w.on_mount=function() w.phase="stepping_off" end
        check(w.mask==0,"on foot when the ride starts on the board, Y is the game's")
        w.pad.buttons.y=true
        check(w.y:press()==true and w.y:status().pending=="arrive","the press waits for the board")
        w.tick(5);w.state=100;w.tick(2);w.pad.buttons.y=false
        w.tick(45)
        check(w.mounts==1 and same(w.events,{"mount mask 0"}),"then the Mount, with Y the game's")
        w.tick(20)
        check(w.calls==0,"and Y was never hidden")
    end)
    case(function() -- Riding, Y goes back to the skateboard once; a busy, airborne or fallen rider's press asks nothing.
        local w=on({phase="riding"})
        check(w.press(100)==true and w.returns==1,"one Return")
        w.phase="returning"
        check(w.press(100)==false and w.returns==1,"and not another while returning")
        check(w.calls==0,"Y never hidden")
        for _,busy in {"preparing","surveying","awaiting_mount","mounting","stepping_off","returning","stopped","cancelled"} do
            local x=on({phase=busy})
            check(x.press(100)==false and x.mounts==0 and x.returns==0,"nothing while "..busy)
        end
        local air=on();air.airborne=true
        check(air.press(100)==false and air.mounts==0,"nothing in the air")
        local fallen=on({phase="fallen"})
        check(fallen.press(100)==false and fallen.mounts==0,"after a fall with a Mount able to start, Recover's")
        -- With no Mount able to start the Entry is asked anyway, as LB + A does, so it says why; Y stays the game's.
        local none=on({start=false})
        check(none.press(100)==true and none.mounts==1 and none.calls==0,"no Mount can start: the Entry says why")
        local down=on({phase="fallen",start=false})
        check(down.press(100)==true and down.mounts==1,"after a fall too")
        down.recovery_pending=true
        check(down.press(100)==true and down.mounts==1,"but not with a Recover owed")
        local back=on({start=false});back.return_requested=true
        check(back.press(100)==false and back.mounts==0,"or a Return asked for")
    end)
    case(function() -- Unload gives Y back once, and nothing happens after it.
        local w=on()
        w.y:unload()
        check(w.mask==0 and w.calls==2 and w.y:status().unloaded,"given back")
        w.tick(10)
        check(w.press(100)==false and w.calls==2 and w.mounts==0,"nothing after")
        w.y:unload()
        check(w.calls==2,"once")
        local off=on({start=false})
        off.y:unload()
        check(off.calls==0,"with Y not hidden, game_buttons is not called: another plugin may own it")
    end)
    case(function() -- A game_buttons that raises is not asked again, and Y still works where the game's own Y gets there.
        local w=world({records=on_record()})
        w.refuse=true;w.on_mount=function() w.phase="stepping_off" end
        w.tick(10)
        check(w.calls==1 and w.y:status().broken and w.mask==0,"tried once")
        check(string.find(w.lines[#w.lines],"could not be kept",1,true)~=nil,"and logged")
        check(w.press(100)==false and w.mounts==0,"on the board with Y not hidden, the game had it")
        w.state=504;w.tick(5)
        w.pad.buttons.y=true
        check(w.y:press()==true,"from on foot it waits for the board")
        w.tick(5);w.state=100;w.pad.buttons.y=false;w.tick(50)
        check(w.mounts==1 and w.calls==1,"and the bike comes, game_buttons never asked again")
    end)
    case(function() -- Another BMX button gives Y back first when it is up, and drops a press being carried out.
        local w=on()
        w.press(100)
        w.y:give_back()
        check(w.mask==0 and w.y:status().pending==nil,"given back, the press dropped")
        w.phase="preparing";w.tick(40)
        check(w.mounts==0 and w.mask==0,"the press never asks")
        local held=on()
        held.pad.buttons.y=true;held.y:give_back()
        check(held.mask==Y_BIT and held.held_changes==0,"held, the mask stays")
        held.phase="preparing";held.tick(5);held.pad.buttons.y=false;held.tick()
        check(held.mask==0,"and goes once Y is let go")
    end)

    ---------------- The real Entry behind the button ----------------
    case(function() -- On foot, Y gets on the bike; riding, Y goes back to the board; on the board, Y rides again.
        local w=chain(check)
        check(w.y:enabled() and w.records[KEY]~=nil,"the kept setting survives the Entry's load and turns bike mode on")
        check(w.entry:next_start_state()==504,"the first ride starts on foot")
        w.tick(3)
        check(w.mask==Y_BIT,"on foot before it, Y is hidden")
        check(w.press_y(100),"Y")
        check(w.stock==504,"the game did not see it")
        local busy_nil=true
        local rode=w.until_true(function()
            local p=w.phase()
            if p~="riding" and p~="idle" and w.entry:next_start_state()~=nil then busy_nil=false end
            return p=="riding"
        end)
        if not rode then w.timeline(60) end
        check(rode and w.mounts==1 and w.mask==0,"the bike comes: "..w.phase())
        check(busy_nil and w.entry:next_start_state()==nil,"while busy or riding no Mount can start")
        w.ride_ms(500)
        check(w.press_y(100) and w.stock==504,"Y while riding, which the riding capture keeps from the game")
        local back=w.until_true(function() return w.phase()=="skateboard" end)
        if not back then w.timeline(60) end
        check(back and w.stock==100 and w.mounts==1,"back on the board")
        check(w.entry:next_start_state()==100,"and the next ride starts there")
        w.tick(3)
        check(w.mask==Y_BIT,"so Y is hidden there")
        check(w.press_y(100) and w.stock==100,"Y, which the game did not see")
        rode=w.until_true(function() return w.phase()=="riding" end)
        if not rode then w.timeline(60) end
        check(rode and w.mounts==2 and w.entry:status().attempts_used==2,"rides again, the Entry's own Y stepping off")
    end)
    case(function() -- A pad the mask does not cover: the press is dropped and told, and the next Y waits for the board.
        local w=chain(check)
        w.tick(3);w.press_y(100)
        check(w.until_true(function() return w.phase()=="riding" end),"rode")
        w.ride_ms(500);w.press_y(100)
        check(w.until_true(function() return w.phase()=="skateboard" end),"back on the board")
        w.tick(3);w.leaky=true
        check(w.mask==Y_BIT and w.press_y(100),"Y, which the game takes anyway")
        w.tick(10)
        check(w.stock==504 and w.y:notice()==LEAK and w.mounts==1,"stepped off, dropped and told: "..tostring(w.y:notice()))
        check(w.mask==0,"on foot, Y is the game's")
        check(w.press_y(100),"Y again")
        local rode=w.until_true(function() return w.phase()=="riding" end)
        if not rode then w.timeline(60) end
        check(rode and w.mounts==2 and w.entry:status().attempts_used==2,"the game brought the board, then the bike came")
    end)
    case(function() -- The first ride from the board: the game's Y steps the rider off, then the bike comes.
        local w=chain(check,{stock=100})
        w.tick(3)
        check(w.entry:next_start_state()==504 and w.mask==0,"on the board before the first ride, Y is the game's")
        check(w.press_y(100),"Y")
        local rode=w.until_true(function() return w.phase()=="riding" end)
        if not rode then w.timeline(60) end
        check(rode and w.mounts==1 and w.mask_calls==0,"stepped off, then rode, Y never hidden")
    end)
    case(function() -- A later ride refused by the ground waits on foot, and Y there retries it.
        local w=chain(check)
        w.tick(3);w.press_y(100)
        check(w.until_true(function() return w.phase()=="riding" end),"rode")
        w.ride_ms(500);w.press_y(100)
        check(w.until_true(function() return w.phase()=="skateboard" end),"back on the board")
        local flat=w.R.world.probe
        w.R.world.probe=function(from,to)
            if from.y-to.y>1 then return {status="hit",position=vector.create(from.x,from.x*.5,from.z)} end
            return {status="clear"}
        end
        w.tick(3);w.press_y(100)
        local refused=w.until_true(function() local p=w.phase();return p=="preflight_refused" or p=="blocked" end)
        if not refused then w.timeline(60) end
        check(refused and w.phase()=="preflight_refused" and w.stock==504,"refused on a hill, on foot: "..w.phase())
        check(w.entry:next_start_state()==504,"a retry starts on foot")
        w.tick(3)
        check(w.mask==Y_BIT,"so Y is hidden there")
        w.R.world.probe=flat
        check(w.press_y(100) and w.stock==504,"Y on flat ground")
        local rode=w.until_true(function() return w.phase()=="riding" end)
        if not rode then w.timeline(60) end
        check(rode and w.mounts==3 and w.entry:status().attempts_used==2,"the retry rides: "..w.phase())
    end)
    return {cases=cases,assertions=n,native_authority=false,constructed=true}
end
return T

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
local LEAK="The game got the Y, as it can on some controllers. Press Y again."
-- The button's own lines while a press is carried out (by the state the ride starts from), and when one runs out.
local STEPPING="Stepping off the board for the bike: stand still and don't press Y."
local READY="Getting the bike ready: stand still."
local BOARD_OUT="Getting your board out for the bike: stand still and don't press Y."
local NO_BIKE="The bike didn't come. Stand still, then press Y again."
local SECOND_Y="The game took a second Y. Stand still, then press Y again."
local IDLE={"idle","skateboard","preflight_refused","blocked","spent"}
local BUSY={"preparing","surveying","awaiting_mount","mounting","riding","stepping_off","returning","fallen","stopped",
    "cancelled","unloaded"}
local function copy(v)
    if type(v)~="table" then return v end
    local out={};for k,c in pairs(v) do out[k]=copy(c) end;return out
end
local function on_record() return {[KEY]={schema=1,bike_mode=true}} end

-- A constructed game and Entry around one y_button. start=false means no Mount can start; key=false gives no key;
-- no_hold leaves the Entry without set_input_hold. w.hold is the Entry's hold_state.
local function world(options)
    options=options or {}
    local w={now=1000,focused=true,gameplay=true,interface_open=false,game_menu=false,pad=Chain.neutral_pad(),
        state=options.state or 100,airborne=false,ragdoll=false,records=options.records or {},
        phase=options.phase or "skateboard",recovery_pending=false,return_requested=false,hold=nil,
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
    function bike:status()
        return {phase=w.phase,recovery_pending=w.recovery_pending,return_requested=w.return_requested,hold_state=w.hold}
    end
    function bike:next_start_state() return w.start end
    function bike:mount()
        w.mounts+=1;w.events[#w.events+1]="mount mask "..w.mask
        if w.on_mount then w.on_mount() end
        return true
    end
    function bike:return_to_skateboard() w.returns+=1;w.events[#w.events+1]="return";return true end
    function bike:set_controls(kind) w.controls[#w.controls+1]=kind;return true end
    if not options.no_hold then
        function bike:set_input_hold(fn) w.hold_fn=fn;return true end
    end
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
    -- What the Entry's hold answers now.
    function w.holding() return w.hold_fn~=nil and w.hold_fn()==true end
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

-- The real chain behind the button, stepped as main.lua's tick does: the Entry, then the button. Y_BIT hidden while a
-- lease, capture or pulse is live, a lease, capture or pulse asked for under the mask, or the mask on while Core has
-- the game's input, fails the case: in the SDK a change of the mask revokes all three, and a hidden button refuses them.
local function chain(check,options)
    options=options or {}
    local w=Chain.new({entry={settings_key=KEY},storage=on_record()})
    w.stock=options.stock or 504
    w.mask,w.mask_calls,w.mounts,w.phases=0,0,0,{}
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
    for _,name in {"status","next_start_state","set_controls","return_to_skateboard","set_input_hold"} do
        bike[name]=function(_,...) return entry[name](entry,...) end
    end
    function bike:mount() w.mounts+=1;return entry:mount() end
    w.y=Y.new(R,bike,KEY)
    -- The game's own Y, about 80 ms after a press it saw: on foot it brings out the board, on the board it steps off.
    w.on_tick=function()
        if w.game_y_at and w.now>=w.game_y_at then
            w.game_y_at=nil;w.stock=w.stock==100 and 504 or 100;w.log("the game's Y: stock now "..w.stock)
        end
    end
    w.after_entry=function()
        -- Before the button moves the mask: with Y hidden, Core has been handed nothing of the game's input.
        local core=w.manager and w.manager:status()
        if w.mask~=0 then
            check(core==nil or core.phase=="idle" or core.phase=="done","Core has the game's input only with Y back with the game")
        end
        local p=w.entry:status().phase
        if p~=w.phases[#w.phases] then w.phases[#w.phases+1]=p end
        w.y:step()
        -- The HUD's help line as main.lua reads it after the button's step, each tick, once a case asks for it.
        if w.hud_log then
            w.hud_log[#w.hud_log+1]={line=w.hud(),pending=w.y:status().pending,phase=w.entry:status().phase,now=w.now}
        end
    end
    -- main.lua's help line: the button's own line first, then Entry's.
    function w.hud() return w.y:notice() or w.entry:help_line() end
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
    function w.saw(phase) for _,p in w.phases do if p==phase then return true end end;return false end
    -- The first ride, then a Return by Y, back on the board where the next ride starts with Y hidden.
    function w.first_ride_and_back()
        w.tick(3);w.press_y(100)
        check(w.until_true(function() return w.phase()=="riding" end),"rode")
        w.ride_ms(500);w.press_y(100)
        check(w.until_true(function() return w.phase()=="skateboard" end),"back on the board")
        w.tick(3)
        check(w.mask==Y_BIT and w.stock==100,"Y hidden on the board")
        w.phases={}
    end
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
    local function lines_with(w,text)
        local count=0
        for _,line in w.lines do if string.find(line,text,1,true) then count+=1 end end
        return count
    end
    -- Whether a HUD line asks for Y. The button's own lines say not to press it, which is not asking.
    local function asks_for_y(line)
        return type(line)=="string" and string.find((string.gsub(line,"don't press Y","")),"ress Y",1,true)~=nil
    end
    -- The HUD a chain case recorded from a Y press on (w.hud_log), up to the first tick riding: while the press was
    -- carried out it was the button's own line want, and from the press to the ride no line was empty or asked for Y.
    -- Answers for how many ticks the press was carried out.
    local function hud_until_ride(w,want,why)
        local waited,bad,rode=0,nil,false
        for _,row in w.hud_log do
            if row.phase=="riding" then rode=true;break end
            if row.pending then
                waited+=1
                if row.line~=want then bad=bad or "not the press's own line: "..tostring(row.line) end
            end
            if type(row.line)~="string" or row.line=="" then bad=bad or "an empty line in "..row.phase end
            if asks_for_y(row.line) then bad=bad or "a line asking for Y in "..row.phase..": "..row.line end
        end
        check(rode and bad==nil,why..": "..tostring(bad or "never rode"))
        return waited
    end
    -- The rows of w.hud_log after the press stopped being carried out: the first is the tick it ended.
    local function after_press(w)
        local out,seen={},false
        for _,row in w.hud_log do
            if row.pending then seen=true elseif seen then out[#out+1]=row end
        end
        return out
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
        check(w.holding(),"and the Entry is told it is, so it hands nothing of the game's input on")
        -- An Entry that cannot wait for Y must never have it hidden.
        local x=world({records=on_record(),no_hold=true});x.tick(5)
        check(x.y:enabled() and x.calls==0 and x.y:status().broken,"no hold, no mask")
        check(lines_with(x,"the Entry cannot wait for it")==1,"and the log says why")
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
    case(function() -- Idle, Y is hidden once the rider stands where the next ride starts, and kept on the same side.
        for _,phase in IDLE do
            local w=on({phase=phase})
            check(w.mask==Y_BIT,"idle in "..phase)
            for _,busy in BUSY do
                w.phase=busy;w.tick()
                check(w.mask==0,"given back in "..busy.." with nothing for the Entry to hold")
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
        given_back("down",function(x) x.ragdoll=true end,function(x) x.ragdoll=false end)
        -- Kept through a jump on foot, and only hidden again by a rider who stands there.
        local calls=w.calls
        w.airborne=true;w.tick(10)
        check(w.mask==Y_BIT and w.calls==calls,"kept through a jump")
        w.state=100;w.tick();w.airborne=false;w.state=504
        check(w.mask==0,"given back once the board comes out")
        w.airborne=true;w.tick(5)
        check(w.mask==0,"and not hidden again in the air")
        w.airborne=false;w.tick()
        check(w.mask==Y_BIT,"but once they stand there")
        check(w.held_changes==0,"never with Y down")
    end)
    case(function() -- Skating the board between rides costs no change of the mask; a bail costs two, logged once.
        local w=on()
        local calls=w.calls
        -- An ollie: crouched (103), in the air (200 or 201), landed (100); a grind (403); a manual's own states.
        for i=1,50 do
            w.state=103;w.tick(3)
            w.state=i%2==0 and 200 or 201;w.airborne=true;w.tick(20)
            w.state=i%5==0 and 403 or 100;w.airborne=i%5==0;w.tick(10)
            w.state=100;w.airborne=false;w.tick(5)
        end
        check(w.mask==Y_BIT and w.calls==calls,"fifty jumps and ten grinds, no change: "..(w.calls-calls))
        check(w.press(100)==true and w.y:status().pending=="guard","and Y on the board still asks for the bike")
        w.y:drop_press()
        local before=#w.lines
        for _=1,20 do
            w.state=504;w.ragdoll=true;w.tick(30)
            w.state=100;w.ragdoll=false;w.tick(30)
        end
        check(w.calls==calls+40,"twenty bails give Y back and hide it again: "..(w.calls-calls))
        -- The hide at load was this phase's first, so only the first give-back is new.
        check(#w.lines-before==1,"the first of each is logged, the rest counted: "..(#w.lines-before))
        w.phase="stepping_off";w.tick()
        check(lines_with(w,"Y kept and given back 39 more times in skateboard.")==1,"the count goes to the log as the phase changes")
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
            check(w.mask==0 and not w.holding(),"given back at once, Y held: "..field)
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
            -- And in a Mount that holds Y, the same.
            w.phase,w.hold,w.state="preparing",504,504;w.tick()
            check(w.mask==Y_BIT,"held for the Mount: "..field)
            w[field]=value;w.tick()
            check(w.mask==0,"given back at once from the Mount too: "..field)
        end
        local w=on()
        w.pad.buttons.y=true
        check(w.y:set_enabled(false)==true and w.mask==0 and w.calls==2,"switched off, given back before the next tick")
        w.tick(10)
        check(w.calls==2,"and left alone")
    end)
    case(function() -- A press with Y hidden asks for the bike once Y has been up 300 ms, with Y still hidden.
        local w=on()
        w.on_mount=function() w.phase,w.hold="stepping_off",100 end
        w.events={}
        check(w.press(100)==true and w.y:status().pending=="guard","the press is carried out")
        check(w.y:notice()==STEPPING,"and the HUD says what the step-off that follows will: "..tostring(w.y:notice()))
        check(w.y:press()==false,"a second while it is says no")
        w.tick(15)
        check(w.mounts==0 and w.y:notice()==STEPPING,"Y up 240 ms: not yet")
        w.tick(5)
        check(w.mounts==1 and same(w.events,{"mount mask "..Y_BIT}),"then the Mount, Y still hidden: "..table.concat(w.events,","))
        check(w.y:notice()==nil,"and the line is the Entry's again")
        -- On foot, the guard says what the Entry says once the bike gets ready.
        local foot=on({start=504,state=504,phase="idle"})
        foot.pad.buttons.y=true;foot.y:press()
        check(foot.y:notice()==READY,"on foot the bike gets ready: "..tostring(foot.y:notice()))
        -- The Mount waits for released controls with nothing asked of the game's input: a second press stays hidden.
        w.tick(5)
        check(w.mask==Y_BIT and w.holding(),"still hidden while the step-off waits, and the Entry told so")
        check(w.press(100)==false and w.mask==Y_BIT and w.mounts==1,"a second Y then is hidden and asks nothing")
        -- In a crouch or rolling on, as before; a rider off the board or down has it back.
        w.state=103;w.tick(3);w.state=100;w.tick(3)
        check(w.mask==Y_BIT,"kept through a crouch")
        -- The Entry about to hand the game's input on stops holding: Y goes back, with Y up only.
        w.pad.buttons.y=true;w.hold=nil;w.tick(5)
        check(w.mask==Y_BIT and w.holding(),"not with Y down: the Entry waits")
        w.pad.buttons.y=false;w.tick()
        check(w.mask==0 and not w.holding() and w.held_changes==0,"Y up, it goes back, and the Entry may go on")
        w.tick(30)
        check(w.mask==0 and w.mounts==1 and w.y:status().pending==nil,"and stays back")
        -- A held press past 6 s is dropped, with no word.
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
    case(function() -- A Mount that waits with nothing asked of the game's input keeps Y from it, wherever it began.
        local w=on({start=504,state=504,phase="preparing"})
        check(w.mask==0,"no hold state, no mask")
        w.hold=504;w.tick()
        check(w.mask==Y_BIT and w.holding(),"hidden where the Entry holds, with the rider standing there")
        for _,phase in {"surveying","awaiting_mount"} do
            w.phase=phase;w.tick()
            check(w.mask==Y_BIT,"and through "..phase)
        end
        w.state=100;w.tick()
        check(w.mask==0,"given back once the rider is on the board, where the game's Y is needed")
        w.state=504;w.airborne=true;w.tick()
        check(w.mask==0,"not hidden again in the air")
        w.airborne=false;w.tick()
        check(w.mask==Y_BIT,"but once they stand there")
        w.hold=nil;w.tick()
        check(w.mask==0,"and given back once the Entry stops holding")
        w.hold=504;w.phase="mounting";w.tick()
        check(w.mask==Y_BIT,"the hold state is the Entry's, not this module's reading of its phase")
        check(w.press(100)==false and w.mounts==0,"a press there asks nothing")
        check(w.held_changes==0,"never with Y down")
    end)
    case(function() -- A Y the game took anyway moves the rider: the press is dropped, with a word to press Y again.
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
        -- A rider who crouches, jumps, grinds or bails during the press: dropped, without the word.
        for _,how in {{state=103},{state=200,airborne=true},{state=201,airborne=true},{state=403,airborne=true},
            {state=300,ragdoll=true},{state=504,ragdoll=true},{airborne=true},{ragdoll=true}} do
            local x=on()
            x.pad.buttons.y=true;x.y:press();x.tick(3)
            for k,v in how do x[k]=v end
            x.tick()
            local name=tostring(how.state).."/"..tostring(how.airborne).."/"..tostring(how.ragdoll)
            check(x.y:status().pending==nil and x.y:notice()==nil,"dropped quietly: "..name)
            x.pad.buttons.y=false;x.state,x.airborne,x.ragdoll=100,false,false;x.tick(60)
            check(x.mounts==0 and x.y:notice()==nil,"no Mount and no word: "..name)
        end
        -- Before the first ride the other state is the board.
        local first=on({start=504,state=504,phase="idle"})
        first.pad.buttons.y=true;first.y:press();first.tick(3);first.state=100;first.tick()
        check(first.y:notice()==LEAK,"the board out before the first ride is the game's Y too")
    end)
    case(function() -- First ride from the board: the game's Y steps the rider off, and the bike comes once they stand still.
        local w=on({start=504,state=100,phase="idle"})
        w.on_mount=function() w.phase,w.hold="preparing",504 end
        check(w.mask==0 and w.calls==0,"on the board before the first ride, Y is the game's")
        check(w.y:notice()==nil,"and nothing is said before a press")
        w.pad.buttons.y=true
        check(w.y:press()==true and w.y:status().pending=="arrive","the press waits for the rider")
        check(w.y:notice()==STEPPING,"the HUD says what the game's Y is doing, and not to press it again")
        w.tick(5);w.state=504;w.tick(2);w.pad.buttons.y=false
        w.tick(30)
        check(w.mounts==0 and w.y:notice()==STEPPING,"480 ms at rest: not yet")
        check(w.calls==0,"and Y is not hidden while they arrive")
        w.tick(10)
        check(w.mounts==1 and same(w.events,{"mount mask 0","mask "..Y_BIT}),
            "600 ms at rest: the Mount, with Y the game's, then hidden while the bike gets ready on foot: "..table.concat(w.events,","))
        check(w.y:notice()==nil,"and the line is the Entry's again")
        -- A stick pushed while waiting starts the rest again.
        local x=on({start=504,state=100,phase="idle"})
        x.pad.buttons.y=true;x.y:press();x.tick(5);x.state=504;x.pad.buttons.y=false
        x.tick(20);x.pad.left_x=.6;x.tick(20)
        check(x.mounts==0,"no Mount with the stick pushed")
        x.pad.left_x=0;x.tick(30)
        check(x.mounts==0,"480 ms after it is let go: not yet")
        x.tick(10)
        check(x.mounts==1,"600 ms: the Mount")
        -- A rider who never arrives: dropped after 6 s, and the HUD says the bike is not coming.
        local never=on({start=504,state=100,phase="idle"})
        never.press(100);never.tick(365)
        check(never.mounts==0 and never.y:status().pending=="arrive" and never.y:notice()==STEPPING,"5.95 s: still waiting")
        never.tick(4)
        check(never.mounts==0 and never.y:status().pending==nil,"never arriving, dropped")
        check(never.y:notice()==NO_BIKE and lines_with(never,"told: "..NO_BIKE)==1,"and told: "..tostring(never.y:notice()))
        never.tick(240)
        check(never.y:notice()==NO_BIKE,"for a few seconds")
        never.tick(15)
        check(never.y:notice()==nil,"then the line is the Entry's again")
        -- One that arrives but never stands still runs out the same way.
        local busy=on({start=504,state=100,phase="idle"})
        busy.press(100);busy.state=504;busy.pad.left_x=.6;busy.tick(380)
        check(busy.mounts==0 and busy.y:status().pending==nil and busy.y:notice()==NO_BIKE,"arrived, never still: told")
        -- A press that ends any other way says nothing: a changed start or a busy Entry.
        local gone=on({start=504,state=100,phase="idle"})
        gone.press(100);gone.start=100;gone.tick()
        check(gone.y:status().pending==nil and gone.y:notice()==nil,"a changed start ends it with no word")
        local taken=on({start=504,state=100,phase="idle"})
        taken.press(100);taken.phase="preparing";taken.tick()
        check(taken.y:status().pending==nil and taken.y:notice()==nil,"so does a busy Entry")
        -- A word from an earlier press is answered by a new one: the new press's line is shown, and the old one does not
        -- come back once it ends.
        local again=on({start=504,state=100,phase="idle"})
        again.press(100);again.tick(380)
        check(again.y:notice()==NO_BIKE,"told")
        again.on_mount=function() again.phase,again.hold="preparing",504 end
        again.pad.buttons.y=true;again.y:press()
        check(again.y:notice()==STEPPING,"the new press's line, not the old word")
        again.tick(5);again.state=504;again.pad.buttons.y=false;again.tick(40)
        check(again.mounts==1 and again.y:notice()==nil,"and once it asks for the bike, nothing of the old word")
    end)
    case(function() -- A later ride from on foot: the game's Y brings out the board first.
        local w=on({start=100,state=504})
        w.on_mount=function() w.phase="stepping_off" end
        check(w.mask==0,"on foot when the ride starts on the board, Y is the game's")
        w.pad.buttons.y=true
        check(w.y:press()==true and w.y:status().pending=="arrive","the press waits for the board")
        check(w.y:notice()==BOARD_OUT,"and the HUD says so, and not to press Y again: "..tostring(w.y:notice()))
        w.tick(5);w.state=100;w.tick(2);w.pad.buttons.y=false
        check(w.y:notice()==BOARD_OUT,"on the board, until the Mount")
        w.tick(45)
        check(w.mounts==1 and same(w.events,{"mount mask 0"}),"then the Mount, with Y the game's")
        check(w.y:notice()==nil,"which says the rest")
        w.tick(20)
        check(w.calls==0,"and Y was never hidden, with nothing for the Entry to hold")
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
        check(w.mask==0 and w.calls==2 and w.y:status().unloaded and not w.holding(),"given back")
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
        check(w.calls==1 and w.y:status().broken and w.mask==0 and not w.holding(),"tried once")
        check(string.find(w.lines[#w.lines],"could not be kept",1,true)~=nil,"and logged")
        check(w.press(100)==false and w.mounts==0,"on the board with Y not hidden, the game had it")
        w.state=504;w.tick(5)
        w.pad.buttons.y=true
        check(w.y:press()==true,"from on foot it waits for the board")
        w.tick(5);w.state=100;w.pad.buttons.y=false;w.tick(50)
        check(w.mounts==1 and w.calls==1,"and the bike comes, game_buttons never asked again")
    end)
    case(function() -- Another BMX button drops a press being carried out, and leaves the mask to the Entry's hold.
        local w=on()
        w.press(100)
        w.y:drop_press()
        check(w.mask==Y_BIT and w.y:status().pending==nil,"the press dropped, Y still hidden")
        w.phase,w.hold="preparing",nil;w.tick(40)
        check(w.mounts==0 and w.mask==0,"the press never asks, and Y goes back where nothing holds it")
    end)

    case(function() -- A press waiting for the game's Y whose rider goes down ends at once, with no word.
        -- Kept waiting, its line hid Entry's "Press A to get up.", and at 6 s NO_BIKE asked a rider still lying there
        -- to stand still and press Y, which does nothing for them (the round-3 verification of bike mode).
        for _,from in {{start=504,state=100,line=STEPPING},{start=100,state=504,line=BOARD_OUT}} do
            local name="start "..from.start
            local w=on({start=from.start,state=from.state,phase="idle"})
            w.press(100)
            check(w.y:status().pending=="arrive" and w.y:notice()==from.line,"waiting: "..name)
            w.ragdoll=true;w.tick()
            check(w.y:status().pending==nil and w.y:notice()==nil,"down before arriving: dropped, no word: "..name)
            w.tick(400)
            check(w.y:notice()==nil and w.mounts==0 and lines_with(w,"told: ")==0,"and never told the bike didn't come: "..name)
            -- Down after arriving, as a bail reads: on foot (504) with the ragdoll set.
            local x=on({start=from.start,state=from.state,phase="idle"})
            x.press(100);x.state=from.start;x.tick(5)
            check(x.y:status().pending=="arrive","arrived and settling: "..name)
            x.ragdoll=true;x.state=504;x.tick()
            check(x.y:status().pending==nil and x.y:notice()==nil and x.mounts==0,"down after arriving: dropped, no word: "..name)
            -- Down on the very tick the 6 s run out: still no word.
            local y=on({start=from.start,state=from.state,phase="idle"})
            y.press(100);y.tick(367)
            check(y.y:status().pending=="arrive","5.984 s: "..name)
            y.ragdoll=true;y.tick()
            check(y.y:status().pending==nil and y.y:notice()==nil,"down as it runs out at 6 s: no word: "..name)
        end
        -- A rider who could not be read keeps the press, as before: only one read down ends it.
        local gone=on({start=504,state=100,phase="idle"})
        gone.press(100);gone.R.skater.telemetry=function() return {skater=true} end;gone.tick(10)
        check(gone.y:status().pending=="arrive","an unreadable rider is not a downed one")
        -- The guard was already ended by a downed rider, with no word.
        local guard=on();guard.press(100)
        check(guard.y:status().pending=="guard","a guarded press")
        guard.ragdoll=true;guard.tick()
        check(guard.y:status().pending==nil and guard.y:notice()==nil,"down: dropped quietly")
    end)
    case(function() -- A second Y the game takes after the rider has arrived ends the press at once, and says so.
        -- Kept waiting, the HUD said for the rest of the 6 s that the step-off or the board was still under way.
        for _,from in {{start=504,state=100,line=STEPPING},{start=100,state=504,line=BOARD_OUT}} do
            local name="start "..from.start
            local w=on({start=from.start,state=from.state,phase="idle"})
            w.on_mount=function() w.phase="preparing" end
            w.press(100)
            w.tick(5)
            check(w.y:status().pending=="arrive" and w.y:notice()==from.line,"before the game's Y the press only waits: "..name)
            w.state=from.start;w.tick(10)
            check(w.y:status().pending=="arrive" and w.y:notice()==from.line,"arrived, settling: "..name)
            -- The game's second Y takes the rider back.
            w.state=from.state;w.tick()
            check(w.y:status().pending==nil and w.y:notice()==SECOND_Y and lines_with(w,"told: "..SECOND_Y)==1,
                "back where the press began: dropped, and told: "..name)
            check(w.mounts==0 and w.mask==0,"no Mount, and Y is the game's there: "..name)
            w.tick(245)
            check(w.y:notice()==SECOND_Y,"for a few seconds: "..name)
            w.tick(10)
            check(w.y:notice()==nil,"then Entry's line again: "..name)
            -- And the next Y, which the game acts on, brings the bike as the first would have.
            w.pad.buttons.y=true
            check(w.y:press()==true and w.y:status().pending=="arrive","the next Y waits again: "..name)
            w.tick(5);w.state=from.start;w.pad.buttons.y=false;w.tick(45)
            check(w.mounts==1,"and the bike comes: "..name)
        end
        -- A crouch, a jump or a grind after arriving is not a second Y.
        local w=on({start=100,state=504,phase="idle"})
        w.press(100);w.state=100;w.tick(5)
        w.state=103;w.tick(3);w.state=200;w.airborne=true;w.tick(10);w.state=100;w.airborne=false;w.tick(2)
        check(w.y:status().pending=="arrive" and w.y:notice()==BOARD_OUT,"skating the board is not a second Y")
    end)
    case(function() -- A word for a press that did not bring the bike goes with another BMX control, bike mode off or a busy Entry.
        -- Kept up for its 4 s, it covered Entry's lines once a Mount was under way another way, and asked for Y while
        -- the mod's own step-off ran.
        local function told(word)
            local w
            if word==NO_BIKE then w=on({start=504,state=100,phase="idle"});w.press(100);w.tick(380)
            else w=on();w.pad.buttons.y=true;w.y:press();w.tick(3);w.state=504;w.tick();w.pad.buttons.y=false;w.tick() end
            check(w.y:notice()==word,"told: "..word)
            return w
        end
        for _,word in {NO_BIKE,LEAK} do
            local a=told(word);a.y:drop_press()
            check(a.y:notice()==nil,"another BMX control clears it: "..word)
            a.tick(10);check(a.y:notice()==nil,"and it does not come back: "..word)
            local b=told(word);b.y:set_enabled(false)
            check(b.y:notice()==nil,"bike mode off clears it: "..word)
            local c=told(word);c.phase="stepping_off";c.tick()
            check(c.y:notice()==nil,"a busy Entry clears it: "..word)
            c.phase="skateboard";c.tick()
            check(c.y:notice()==nil,"and an idle one does not bring it back: "..word)
            local d=told(word);d.tick(100)
            check(d.y:notice()==word,"left alone, it stays up: "..word)
        end
    end)
    ---------------- The real Entry behind the button ----------------
    case(function() -- On foot, Y gets on the bike; riding, Y goes back to the board; on the board, Y rides again.
        local w=chain(check)
        check(w.y:enabled() and w.records[KEY]~=nil,"the kept setting survives the Entry's load and turns bike mode on")
        check(w.entry:next_start_state()==504,"the first ride starts on foot")
        w.tick(3)
        check(w.mask==Y_BIT,"on foot before it, Y is hidden")
        w.hud_log={}
        check(w.press_y(100),"Y")
        check(w.stock==504,"the game did not see it")
        local busy_nil,mounting_told=true,false
        local rode=w.until_true(function()
            local p=w.phase()
            if p~="riding" and p~="idle" and w.entry:next_start_state()~=nil then busy_nil=false end
            if p=="mounting" and w.entry:help_line()=="Getting on the bike: let go of the controls and don't press Y." then mounting_told=true end
            return p=="riding"
        end)
        if not rode then w.timeline(60) end
        check(rode and w.mounts==1 and w.mask==0,"the bike comes: "..w.phase())
        check(mounting_told,"and while the rider got on, the HUD said not to press Y")
        check(hud_until_ride(w,READY,"first ride on foot")>=18,"the 300 ms guard said the bike was getting ready")
        check(busy_nil and w.entry:next_start_state()==nil,"while busy or riding no Mount can start")
        w.ride_ms(500)
        check(w.press_y(100) and w.stock==504,"Y while riding, which the riding capture keeps from the game")
        local back=w.until_true(function() return w.phase()=="skateboard" end)
        if not back then w.timeline(60) end
        check(back and w.stock==100 and w.mounts==1,"back on the board")
        check(w.entry:next_start_state()==100,"and the next ride starts there")
        w.tick(3)
        check(w.mask==Y_BIT,"so Y is hidden there")
        w.hud_log={}
        check(w.press_y(100) and w.stock==100,"Y, which the game did not see")
        local told=false
        rode=w.until_true(function()
            if w.phase()=="stepping_off" and w.entry:help_line()=="Stepping off the board for the bike: stand still and don't press Y." then told=true end
            return w.phase()=="riding"
        end)
        if not rode then w.timeline(60) end
        check(rode and w.mounts==2 and w.entry:status().attempts_used==2,"rides again, the Entry's own Y stepping off")
        check(told,"and the HUD said not to press Y while the rider stepped off")
        check(hud_until_ride(w,STEPPING,"later ride on the board")>=18,"from the press on, the guard first")
    end)
    case(function() -- A second Y while the later ride's step-off waits is kept from the game, and the ride goes on.
        local w=chain(check)
        w.first_ride_and_back()
        w.press_y(100)
        check(w.until_true(function() return w.phase()=="stepping_off" end,40),"the Mount starts")
        w.tick(5)
        check(w.mask==Y_BIT and w.entry:status().hold_state==100,"Y still hidden while the step-off waits for released controls")
        -- The player saw nothing happen and pressed Y again, twice.
        check(w.press_y(100)==false and w.stock==100,"a second Y, which the game did not see")
        w.tick(25)
        check(w.press_y(60)==false and w.stock==100,"and a third")
        local rode=w.until_true(function() return w.phase()=="riding" or w.phase()=="blocked" end)
        if not rode then w.timeline(80) end
        check(w.phase()=="riding" and not w.saw("blocked") and w.mounts==2 and w.entry:status().attempts_used==2,
            "the ride goes on: "..table.concat(w.phases,","))
        check(w.saw("preparing") and w.saw("surveying"),"through the step-off and the survey")
    end)
    case(function() -- The step-off's quiet passes and Y goes back, then the quiet breaks before the hand-over: Y is kept again.
        -- Until the second review of 1827ac54 the step-off then went on waiting for Y with it given back, all through the
        -- new 600 ms quiet, and a Y there stepped the rider off and ended the attempt ('Attempt two lost its stock100
        -- baseline before admission').
        local away={stick=function(w,on) w.pad.left_x=on and .6 or 0 end,
            menu=function(w,on) w.game_menu=on end,
            focus=function(w,on) w.focused=not on end,
            overlay=function(w,on) w.interface_open=on end}
        for how,set in pairs(away) do
            local w=chain(check)
            w.first_ride_and_back()
            w.press_y(100)
            check(w.until_true(function() return w.entry:status().hold_waiting end,200),"the quiet passes: "..how)
            check(w.phase()=="stepping_off" and w.mask==0 and w.pulse==nil and w.entry:status().hold_state==nil,
                "and the step-off waits for Y, given back: "..how)
            -- On the very next tick, before the hand-over.
            set(w,true);w.tick()
            local s=w.entry:status()
            check(s.phase=="stepping_off" and w.pulse==nil and not s.hold_waiting and s.hold_state==100,
                "the step-off waits for a new quiet, no longer for Y: "..how)
            set(w,false);w.tick()
            check(w.mask==Y_BIT,"so Y is kept from the game again: "..how)
            check(w.press_y(100)==false and w.stock==100,"a further Y, which the game did not see: "..how)
            local rode=w.until_true(function() return w.phase()=="riding" or w.phase()=="blocked" end)
            if not rode then w.timeline(80) end
            check(w.phase()=="riding" and not w.saw("blocked") and w.mounts==2 and w.entry:status().attempts_used==2,
                "the ride starts: "..how..": "..table.concat(w.phases,","))
        end
    end)
    case(function() -- The same at the mount's request: a menu that opens there, then closes, leaves it to ask at once.
        local w=chain(check)
        w.tick(3);w.press_y(100)
        check(w.until_true(function() return w.entry:status().hold_waiting end,400),"the mount's request waits for Y")
        check(w.phase()=="awaiting_mount" and w.mask==0,"given back")
        w.game_menu=true;w.tick(10)
        local s=w.entry:status()
        check(s.phase=="awaiting_mount" and not s.hold_waiting and s.hold_state==504 and w.mask==0 and w.handle==nil,
            "with a menu open it waits for the menu, not for Y, and Y stays the game's while the menu is up")
        w.game_menu=false;w.tick()
        check(w.phase()=="mounting" and w.mask==0,"closed, the request goes on the same tick, with Y the game's")
        local rode=w.until_true(function() return w.phase()=="riding" or w.phase()=="blocked" end)
        check(rode and w.phase()=="riding" and w.mounts==1,"and the bike comes: "..table.concat(w.phases,","))
    end)
    case(function() -- A second Y while the first ride gets ready is kept from the game as well.
        local w=chain(check)
        w.tick(3);w.press_y(100)
        check(w.until_true(function() local p=w.phase();return p=="preparing" or p=="surveying" end,40),"the Mount starts")
        check(w.mask==Y_BIT and w.entry:status().hold_state==504,"Y still hidden")
        check(w.press_y(100)==false and w.stock==504,"a second Y, which the game did not see")
        local rode=w.until_true(function() return w.phase()=="riding" or w.phase()=="preflight_refused" or w.phase()=="blocked" end)
        if not rode then w.timeline(60) end
        check(w.phase()=="riding" and w.mounts==1,"the ride goes on: "..table.concat(w.phases,","))
    end)
    case(function() -- LB + A with Y held under the mask: the Entry waits for Y to come back before it asks for the bike.
        local w=chain(check)
        w.tick(3)
        check(w.mask==Y_BIT,"Y hidden on foot before the first ride")
        -- The player holds Y, nothing happens, so they hold LB and press A too.
        w.pad.buttons.y=true;w.y:press();w.tick(2)
        w.y:drop_press();check(w.entry:mount(),"LB + A")
        check(w.until_true(function() return w.entry:status().hold_waiting end,200),"the Mount gets ready and waits")
        local s=w.entry:status()
        check(s.phase=="awaiting_mount" and s.hold_state==nil and w.mask==Y_BIT,"at the request, with Y still down and hidden")
        w.tick(120)
        check(w.phase()=="awaiting_mount" and w.handle==nil and w.manager:status().phase=="idle","nothing asked of the game for 2 s")
        w.pad.buttons.y=false
        local rode=w.until_true(function() return w.phase()=="riding" or w.phase()=="blocked" end)
        if not rode then w.timeline(60) end
        check(w.phase()=="riding" and w.stock==504,"Y let go: given back, then the bike")
    end)
    case(function() -- The Entry's hold on its own: the mount's request and the step-off's Y wait for it, nothing else.
        local w=Chain.new()
        w.holding=false
        check(w.entry:set_input_hold(function() return w.holding end) and not w.entry:set_input_hold(5),"a function or nil")
        local states={}
        local function note() local h=w.entry:status().hold_state;states[w.entry:status().phase]=h or false end
        w.holding=true
        check(w.entry:mount(),"Mount")
        for _=1,200 do w.tick();note();if w.entry:status().hold_waiting then break end end
        check(states.preparing==504 or states.surveying==504,"on foot while it gets ready")
        w.tick(120)
        local s=w.entry:status()
        check(s.phase=="awaiting_mount" and s.hold_waiting and s.hold_state==nil and w.manager:status().phase=="idle"
            and w.handle==nil,"held, the mount is not asked for, and the hold state is let go")
        w.holding=false
        check(w.until_phase("riding"),"let go, it rides")
        check(w.entry:status().hold_state==nil and not w.entry:status().hold_waiting,"no hold state riding")
        w.ride_ms(500);w.entry:return_to_skateboard()
        check(w.until_phase("skateboard"),"back on the board")
        check(w.entry:status().hold_state==nil,"none idle")
        w.holding=true
        check(w.entry:mount(),"Mount from the board")
        w.tick()
        check(w.entry:status().phase=="stepping_off" and w.entry:status().hold_state==100,"on the board before the step-off")
        for _=1,200 do w.tick();if w.entry:status().hold_waiting then break end end
        w.tick(120)
        s=w.entry:status()
        check(s.phase=="stepping_off" and s.hold_waiting and w.pulse==nil and w.stock==100
            and w.manager:status().phase=="done","held, the step-off's Y is not asked for")
        w.holding=false
        check(w.until_phase("riding") and w.entry:status().attempts_used==2,"let go, it steps off and rides")
        check(w.entry:set_input_hold(nil),"the hold can be taken away")
    end)
    case(function() -- A fall's own remount keeps Y from the game only where it costs the step-off nothing.
        local w=chain(check)
        w.tick(3);w.press_y(100)
        check(w.until_true(function() return w.phase()=="riding" end),"rode")
        w.ride_ms(500);w.phases={}
        w.tilt_stop(59.7)
        local rode=w.until_true(function() local s=w.entry:status();return s.phase=="riding" and s.attempts_used==2 end)
        if not rode then w.timeline(80) end
        check(rode,"the fall gets back on: "..table.concat(w.phases,","))
        check(w.saw("returning") and w.saw("stepping_off"),"through a Return and a step-off")
    end)
    case(function() -- A fall's own remount that finds the rider on foot is never told not to press Y, then asks for it.
        local STEPPING="Stepping off the board for the bike: stand still and don't press Y."
        local Y_LINE="Press Y for your skateboard, then let go of the controls."
        local w=chain(check)
        w.tick(3);w.press_y(100)
        check(w.until_true(function() return w.phase()=="riding" end),"rode")
        w.ride_ms(500);w.tilt_stop(59.7)
        check(w.until_true(function() return w.phase()=="stepping_off" end),"the remount's step-off")
        -- The game has put the rider down on foot rather than on the board.
        w.stock,w.ragdoll=504,true
        check(w.until_true(function() return w.entry:help_line()=="Press A to get up." end,400),"down: "..tostring(w.entry:help_line()))
        check(w.mask==0,"Y the game's, which the rider will need")
        w.ragdoll=false
        local stood,said,asked=w.now,{},nil
        for _=1,100 do
            w.tick()
            local line=w.entry:help_line()
            said[line]=true
            if line==Y_LINE then asked=w.now;break end
        end
        check(not said[STEPPING],"standing on foot, the HUD never says not to press Y")
        check(said["Getting back on the bike."],"it says what is under way")
        check(asked and asked-stood>=1000 and w.mask==0,"then, a second on, asks for Y, which the game has")
        check(w.press_y(100)==false and w.stock==100,"the game's Y brings out the board")
        local told=false
        local rode=w.until_true(function()
            if w.phase()=="stepping_off" and w.entry:help_line()==STEPPING then told=true end
            return w.phase()=="riding" or w.phase()=="blocked"
        end)
        if not rode then w.timeline(80) end
        check(w.phase()=="riding" and w.entry:status().attempts_used==2,"the remount goes on: "..table.concat(w.phases,","))
        check(told,"on the board the step-off's own line comes back")
    end)
    case(function() -- A pad the mask does not cover: the press is dropped and told, and the next Y waits for the board.
        local w=chain(check)
        w.first_ride_and_back()
        w.leaky=true
        check(w.press_y(100),"Y, which the game takes anyway")
        w.tick(10)
        check(w.stock==504 and w.y:notice()==LEAK and w.mounts==1,"stepped off, dropped and told: "..tostring(w.y:notice()))
        check(w.mask==0,"on foot, Y is the game's")
        w.hud_log={}
        check(w.press_y(100),"Y again, as the HUD says")
        local rode=w.until_true(function() return w.phase()=="riding" end)
        if not rode then w.timeline(60) end
        check(rode and w.mounts==2 and w.entry:status().attempts_used==2,"the game brought the board, then the bike came")
        -- The leak's word was still fresh, and it asked for Y while the game brought the board out.
        check(hud_until_ride(w,BOARD_OUT,"after the leak")>=40,"the press's own line, not the leak's")
    end)
    case(function() -- The first ride from the board: the game's Y steps the rider off, then the bike comes.
        local w=chain(check,{stock=100})
        w.tick(3)
        check(w.entry:next_start_state()==504 and w.mask==0,"on the board before the first ride, Y is the game's")
        check(w.press_y(100),"Y")
        local rode=w.until_true(function() return w.phase()=="riding" end)
        if not rode then w.timeline(60) end
        check(rode and w.mounts==1 and w.stock==504,"stepped off, then rode")
        check(w.mask_calls==2,"Y hidden only while the bike got ready on foot: "..w.mask_calls)
    end)
    case(function() -- The first ride from the board on the HUD: while the game's Y steps the rider off, it says not to press Y.
        -- Until then Entry was still idle and its line blank, and a second Y the game saw put the rider back on the
        -- board, and the press was dropped 6 s later with no word.
        local w=chain(check,{stock=100})
        w.tick(3)
        check(w.hud()==nil,"before a press the HUD has no line")
        w.hud_log={}
        check(w.press_y(100),"Y")
        check(w.until_true(function() return w.phase()=="riding" or w.phase()=="blocked" end),"the ride")
        local waited=hud_until_ride(w,STEPPING,"first ride from the board")
        check(waited>=40 and w.stock==504 and w.mounts==1,"the press waited for the rider for "..waited.." ticks, then rode")
        -- The game did not act on this Y (it can ignore one, as when the rider is rolling): after 6 s the HUD says so.
        local x=chain(check,{stock=100})
        x.tick(3);x.hud_log={}
        x.pad.buttons.y=true
        check(x.y:press() and x.y:status().pending=="arrive","Y, which the game drops")
        x.tick(7);x.pad.buttons.y=false
        check(x.until_true(function() return x.y:status().pending==nil end,400),"the press runs out")
        local waited_ms=x.hud_log[#x.hud_log].now-x.hud_log[1].now
        for _,row in x.hud_log do
            if row.pending then check(row.line==STEPPING,"the press's own line while it waits: "..tostring(row.line)) end
        end
        check(waited_ms>=5950 and x.stock==100 and x.mounts==0,"6 s on the board, no Mount: "..waited_ms)
        local after=after_press(x)
        check(#after==1 and after[1].line==NO_BIKE,"then told: "..tostring(after[1] and after[1].line))
        x.tick(245)
        check(x.hud()==NO_BIKE,"for a few seconds")
        x.tick(10)
        check(x.hud()==nil,"then the HUD is Entry's again")
        check(x.press_y(100) and x.until_true(function() return x.phase()=="riding" end),"and a further Y rides")
    end)
    case(function() -- A later ride refused by the ground waits on foot, and Y there retries it.
        local w=chain(check)
        w.first_ride_and_back()
        local flat=w.R.world.probe
        w.R.world.probe=function(from,to)
            if from.y-to.y>1 then return {status="hit",position=vector.create(from.x,from.x*.5,from.z)} end
            return {status="clear"}
        end
        w.press_y(100)
        local refused=w.until_true(function() local p=w.phase();return p=="preflight_refused" or p=="blocked" end)
        if not refused then w.timeline(60) end
        check(refused and w.phase()=="preflight_refused" and w.stock==504,"refused on a hill, on foot: "..w.phase())
        check(w.entry:next_start_state()==504,"a retry starts on foot")
        w.tick(3)
        check(w.mask==Y_BIT,"so Y is hidden there")
        w.R.world.probe=flat
        check(w.press_y(100) and w.stock==504,"Y on flat ground")
        check(w.until_true(function() return w.phase()=="preparing" end,40),"the retry starts")
        w.tick(5)
        check(w.press_y(100)==false and w.stock==504,"a second Y during the retry's wait, which the game did not see")
        local rode=w.until_true(function() return w.phase()=="riding" or w.phase()=="blocked" end)
        if not rode then w.timeline(60) end
        check(w.phase()=="riding" and w.mounts==3 and w.entry:status().attempts_used==2,"the retry rides: "..w.phase())
    end)
    -- A later ride blocked with the rider on foot: the step-off's wait sees the rider off the board, as after a Y from a
    -- pad the mask does not cover. The next ride starts on the board, so Y there waits for the game's Y to bring it out.
    local function blocked_on_foot()
        local w=chain(check)
        w.first_ride_and_back()
        w.press_y(100)
        check(w.until_true(function() return w.phase()=="stepping_off" end,40),"the Mount starts")
        w.leaky=true;w.press_y(100);w.leaky=false
        check(w.until_true(function() return w.phase()=="blocked" end,100) and w.stock==504,"blocked, on foot: "..w.phase())
        w.tick(5)
        check(w.entry:next_start_state()==100 and w.mask==0,"the next ride starts on the board, so Y is the game's")
        return w
    end
    case(function() -- A blocked later ride from on foot: while the game's Y brings out the board, the HUD says not to press Y.
        -- Until then the blocked line stayed up, "That didn't finish. Press Y to ride again.", and a second Y the game
        -- saw put the board away again.
        local w=blocked_on_foot()
        check(w.hud()=="That didn't finish. Press Y to ride again.","the blocked line: "..tostring(w.hud()))
        w.hud_log={}
        check(w.press_y(100) and w.stock==100,"Y, and the game brings out the board")
        check(w.until_true(function() return w.phase()=="riding" end,1500),"the ride: "..table.concat(w.phases,","))
        local waited=hud_until_ride(w,BOARD_OUT,"blocked later ride from on foot")
        check(waited>=40 and w.saw("stepping_off") and w.entry:status().attempts_used==2,"waited "..waited.." ticks, then stepped off and rode")
        -- LB + A first, which asks for Y on the HUD: "Press Y to ride again." Once the bike is on its way that word is
        -- stale, and up for its 4 s it asked for Y while the step-off's own Y went out.
        local l=blocked_on_foot()
        l.y:drop_press()
        check(l.entry:mount()==false and l.hud()=="Press Y to ride again." and l.phase()=="blocked","LB + A, told to press Y")
        l.hud_log={}
        check(l.press_y(100) and l.stock==100,"so Y, and the game brings out the board")
        check(l.until_true(function() return l.phase()=="riding" end,1500),"the ride: "..table.concat(l.phases,","))
        check(hud_until_ride(l,BOARD_OUT,"LB + A, then Y")>=40,"the press waited for the board")
        local started=after_press(l)[1]
        check(started and started.phase=="stepping_off" and started.now-l.hud_log[1].now<3000,
            "and the Mount started well inside the old word's 4 s")
        -- The game did not act on this Y: after 6 s the HUD says so, then the blocked line comes back.
        local x=blocked_on_foot()
        x.hud_log={}
        x.pad.buttons.y=true
        check(x.y:press() and x.y:status().pending=="arrive","Y, which the game drops")
        x.tick(7);x.pad.buttons.y=false
        check(x.until_true(function() return x.y:status().pending==nil end,400),"the press runs out")
        for _,row in x.hud_log do
            if row.pending then check(row.line==BOARD_OUT,"the press's own line while it waits: "..tostring(row.line)) end
        end
        check(x.hud_log[#x.hud_log].now-x.hud_log[1].now>=5950 and x.stock==504 and x.phase()=="blocked","6 s on foot")
        check(#after_press(x)==1 and x.hud()==NO_BIKE,"then told: "..tostring(x.hud()))
        x.tick(245)
        check(x.hud()==NO_BIKE,"for a few seconds")
        x.tick(10)
        check(x.hud()=="That didn't finish. Press Y to ride again.","then the blocked line again: "..tostring(x.hud()))
        check(x.press_y(100) and x.until_true(function() return x.phase()=="riding" end,1500),"and a further Y rides")
    end)
    case(function() -- A blocked later ride from on foot, Y, and the rider goes down while the game's Y brings out the board.
        -- Until the round-3 verification the press kept waiting: its line hid Entry's "Press A to get up.", and at 6 s
        -- the HUD told a rider still lying there that the bike didn't come and to press Y, which does nothing for them.
        local w=blocked_on_foot()
        w.hud_log={}
        check(w.press_y(100) and w.stock==100 and w.y:status().pending=="arrive","Y, and the game brings out the board")
        w.tick(5)
        check(w.hud()==BOARD_OUT,"the press's line while it waits")
        -- A bail: on foot, with the ragdoll set.
        w.stock,w.ragdoll=504,true;w.tick()
        check(w.y:status().pending==nil and w.y:notice()==nil,"the press ends at once, with no word")
        check(w.until_true(function() return w.hud()=="Press A to get up." end,30),"the HUD is Entry's: "..tostring(w.hud()))
        local from=#w.hud_log
        w.tick(500)
        local bad=nil
        for i=from,#w.hud_log do if w.hud_log[i].line~="Press A to get up." then bad=bad or tostring(w.hud_log[i].line) end end
        check(bad==nil,"8 s down, past the press's 6 s, the HUD only says to get up: "..tostring(bad))
        local said=false
        for _,row in w.hud_log do if row.line==NO_BIKE then said=true end end
        check(not said,"and never that the bike didn't come")
        check(w.mask==0 and w.phase()=="blocked" and w.mounts==2,"Y the game's, nothing asked of Entry")
        w.ragdoll=false;w.tick(20)
        check(w.hud()=="That didn't finish. Press Y to ride again.","up again, the blocked line: "..tostring(w.hud()))
        check(w.press_y(100) and w.until_true(function() return w.phase()=="riding" end,1500),"and a further Y rides")
    end)
    case(function() -- A second Y while the game's own Y is under way: the game undoes it, and the HUD says so at once.
        -- Until the round-3 verification the HUD said for the rest of the 6 s that the board was coming out, or the
        -- step-off was under way, with the rider back where they began.
        local w=blocked_on_foot()
        check(w.press_y(100) and w.stock==100,"Y, and the game brings out the board")
        w.tick(5)
        check(w.y:status().pending=="arrive" and w.hud()==BOARD_OUT,"the press waits for the rider to stand still")
        check(w.press_y(100)==false and w.stock==504,"a second Y, which the game takes: the board is put away")
        check(w.y:status().pending==nil and w.hud()==SECOND_Y and w.mounts==2,"the press ended at once, and told: "..tostring(w.hud()))
        local told_at=w.now
        check(w.until_true(function() return w.hud()~=SECOND_Y end,400),"the word goes")
        check(w.now-told_at>=3900 and w.hud()=="That didn't finish. Press Y to ride again.",
            "after its 4 s, the blocked line again: "..tostring(w.hud()))
        check(w.press_y(100) and w.until_true(function() return w.phase()=="riding" end,1500),"and a further Y rides")
        -- The first ride from the board: the game's Y steps the rider off, and a second puts them back on.
        local x=chain(check,{stock=100})
        x.tick(3)
        check(x.press_y(100) and x.stock==504 and x.y:status().pending=="arrive","Y, and the game steps the rider off")
        x.tick(5)
        check(x.press_y(100)==false and x.stock==100,"a second Y puts them back on the board")
        check(x.y:status().pending==nil and x.hud()==SECOND_Y and x.mounts==0,"the press ended, and told: "..tostring(x.hud()))
        x.tick(260)
        check(x.press_y(100) and x.until_true(function() return x.phase()=="riding" end),"and a further Y rides")
    end)
    case(function() -- The bike didn't come, then LB + A: the HUD is Entry's step-off line at once, not the old word.
        -- Until the round-3 verification the word stayed up for its 4 s, over Entry's line, asking for Y while the mod's
        -- own step-off ran.
        local w=blocked_on_foot()
        check(w.press_y(100) and w.stock==100,"Y, and the game brings out the board")
        -- The rider keeps the stick pushed, so the press never sees them still.
        w.pad.left_x=.6
        check(w.until_true(function() return w.y:status().pending==nil end,400),"the press runs out")
        check(w.hud()==NO_BIKE,"told: "..tostring(w.hud()))
        w.pad.left_x=0;w.tick(2)
        -- LB + A as main.lua hands it on: the button's press is dropped first.
        w.y:drop_press()
        check(w.entry:mount(),"LB + A on the board")
        check(w.hud()==STEPPING,"the HUD is Entry's step-off line at once: "..tostring(w.hud()))
        w.hud_log={}
        local rode=w.until_true(function() return w.phase()=="riding" or w.phase()=="blocked" end,1500)
        local said=false
        for _,row in w.hud_log do if row.line==NO_BIKE then said=true end end
        check(rode and w.phase()=="riding" and not said,"and it rides, the old word never back: "..table.concat(w.phases,","))
    end)
    return {cases=cases,assertions=n,native_authority=false,constructed=true}
end
return T

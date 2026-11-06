-- Bike mode: Y alone gets on the bike and off it (main.lua). Every reskate call comes in through R, so the suites run
-- it with constructed services (Test/y_button_tests.lua). When a Mount can start, and from which state, is Entry's
-- rule (next_start_state in bmx_playable_entry.lua); this module decides only what one Y press means and when the game
-- must not see it.
--
-- In the game Y on foot brings out the skateboard and Y on the board steps off it. A ride after the first starts on
-- the board, and its step-off is the mod's own Y: a Y the game took as well would step the rider off first, and that
-- ride's step-off refuses a rider already on foot. So while the mod is idle with the rider in the state the next ride
-- starts from, Y is kept from the game (reskate.input.game_buttons) and a press asks for the bike. It stays kept while
-- that Mount waits with nothing asked of the game's input (Entry's hold_state), so a second press, which players make
-- when nothing seems to happen, does not undo it.
-- While any button is hidden the SDK refuses every input lease, capture and pulse (input_capture.cpp
-- input_pulse_available), and a change of the mask revokes them. So Entry asks this module before it hands the game's
-- input on (set_input_hold) and waits until Y is given back, and the mask changes only where Entry holds none of them.
-- It changes only while the real Y is up: hiding a held Y hands the game a release, and giving it back hands it a
-- press. A menu or overlay opening, the game losing focus, bike mode switched off and unload give it back at once.
--
-- The mask covers XInput reads only. A PlayStation pad the SDK reads natively, without Steam Input, still passes Y to
-- the game: the press then sees the rider reach the other stock state, and is dropped with a word to press Y again,
-- which then waits for the game's Y as it does from that state.
local Y={}
local Y_BIT=0x8000
-- Where the game's own Y takes the rider from each stock state: off the board (504) from it (100), and back.
local OTHER={[100]=504,[504]=100}
-- After the press is let go the start state must hold this long before the bike is asked for: a Y the game took
-- moves the rider within it.
local GUARD_MS,GUARD_SAMPLES=300,5
-- A press held longer than this is dropped without a word. One whose rider has not arrived and stood still by then
-- is dropped with NO_BIKE.
local PRESS_LIMIT_MS,ARRIVE_MS=6000,6000
-- Before a Mount asked for from the other state: the rider in the start state with the pad at rest this long, as the
-- step-off's own admission waits (second_quiet in bmx_playable_entry.lua). Samples further apart start it again.
local QUIET_MS,QUIET_SAMPLES,GAP_MS=600,10,250
local NOTICE_MS=4000
-- Where the mod is idle: nothing is being prepared, surveyed, mounted, ridden, stepped off or returned.
local IDLE={idle=true,skateboard=true,preflight_refused=true,blocked=true,spent=true}
-- The rider is then back in the state the game's Y took them to, where a press waits for the game's Y again.
local LEAK="The game got the Y, as it can on some controllers. Press Y again."
-- The HUD's line while a press is being carried out, by its kind and the state the ride starts from. Entry is still
-- idle then, and its own line is blank or one that asks for Y ("Press Y to ride again."), so a player who sees nothing
-- happen presses again. Under the guard that second Y is kept from the game, but while a press waits for the game's
-- own Y it is not: the game then puts the rider back on the board or puts the board away, and the press runs out.
-- The guard's lines are the ones Entry shows once the Mount starts from there (HELP.preparing and the step-off's
-- line in bmx_playable_entry.lua), so the line does not change when it does.
local PENDING={guard={[504]="Getting the bike ready: stand still.",
        [100]="Stepping off the board for the bike: stand still and don't press Y."},
    arrive={[504]="Stepping off the board for the bike: stand still and don't press Y.",
        [100]="Getting your board out for the bike: stand still and don't press Y."}}
-- A press that waited for the game's own Y and ran out. The rider is then where the ride starts, with Y kept from the
-- game, or where the game's Y is needed again, and either way the next Y works once they stand still.
local NO_BIKE="The bike didn't come. Stand still, then press Y again."
local BUTTONS={"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function call(fn,...)
    if type(fn)~="function" then return table.pack(false,"required method unavailable") end
    return table.pack(pcall(fn,...))
end
-- Every button up and both sticks and triggers at rest, by the SDK's circular XInput thresholds that Entry's
-- second_quiet uses. An unreadable pad is not at rest.
local function at_rest(p)
    if not plain(p) or not plain(p.buttons) then return false end
    for _,name in BUTTONS do if p.buttons[name]~=false then return false end end
    for _,name in {"left_x","left_y","right_x","right_y","left_trigger","right_trigger"} do
        if not finite(p[name]) then return false end
    end
    return p.left_x^2+p.left_y^2<=(7849/32767)^2 and p.right_x^2+p.right_y^2<=(8689/32767)^2
        and p.left_trigger<=30/255 and p.right_trigger<=30/255
end
function Y.new(R,bike,key)
    assert(type(R)=="table" and type(bike)=="table","services and the Entry required")
    local function trace(line) call(R.log,"[BMX] "..line) end
    -- The mask this module last set: 0 or Y_BIT. game_buttons has one owner, the last plugin to call it, so it is
    -- called only when this changes. broken: a call raised, or the Entry cannot wait for Y, and no mask is asked for
    -- again.
    local applied,broken,unloaded=0,false,false
    -- Entry asks this before it hands the game's input on, and waits while Y is kept.
    local hooked=call(bike.set_input_hold,bike,function() return applied~=0 end)
    if not hooked[1] or hooked[2]~=true then broken=true;trace("Y will not be kept from the game: the Entry cannot wait for it.") end
    -- Bike mode is kept in storage under key, the one key Entry keeps at load. Entry clears anything else under it
    -- first (fresh_namespace), so what is read here is main.lua's own record or nothing, and nothing is off.
    local enabled=false
    if type(key)=="string" then
        local stored=call(R.storage and R.storage.get,key)
        enabled=stored[1] and stored.n==2 and plain(stored[2]) and stored[2].schema==1 and stored[2].bike_mode==true
    end
    if enabled then call(bike.set_controls,bike,"y") end
    -- One press being carried out: "guard" waits for Y up and the start state to hold, "arrive" for the game's own Y
    -- to bring the rider to the start state. notice is a line told when a press ended without the bike.
    local pending=nil
    local notice,notice_until=nil,0
    -- The log gets the first hide and the first give-back while Entry stays in one phase, and how many more there were
    -- at the first change after it leaves it (or at unload), so a rider bailing again and again between rides does not
    -- fill it.
    local last_phase,log_phase,logged,unlogged=nil,nil,{},0
    local function log_unlogged()
        if unlogged>0 then
            trace("Y kept and given back "..unlogged..(unlogged==1 and " more time" or " more times").." in "..tostring(log_phase)..".")
        end
        unlogged=0
    end
    local object={}
    local function clock()
        local out=call(R.time and R.time.now)
        return out[1] and out.n==2 and finite(out[2]) and out[2] or nil
    end
    local function set_mask(mask)
        if applied==mask then return true end
        if broken then return false end
        local out=call(R.input and R.input.game_buttons,mask,0,false)
        if not out[1] then
            broken=true;trace("Y could not be kept from the game: "..tostring(out[2]))
            return false
        end
        applied=mask
        if last_phase~=log_phase then log_unlogged();log_phase,logged=last_phase,{} end
        if logged[mask] then unlogged+=1
        else logged[mask]=true;trace(mask~=0 and "Y kept from the game for the bike." or "Y given back to the game.") end
        return true
    end
    -- The game in front and in play, with no game menu and no ReSkate surface open. An unreadable answer is no.
    local function in_front()
        local f=call(R.input and R.input.focus)
        local m=call(R.menu and R.menu.game)
        return f[1] and f.n==2 and plain(f[2]) and f[2].focused==true and f[2].gameplay==true
            and f[2].interface_open==false and m[1] and m.n==2 and plain(m[2]) and m[2].open==false
    end
    local function pad()
        local out=call(R.input and R.input.gamepad)
        return out[1] and out.n==2 and plain(out[2]) and plain(out[2].buttons) and out[2] or nil
    end
    -- Where the rider is; whether they are down (ragdolled, or that cannot be told); and whether they stand: upright,
    -- not ragdolled, on the ground and not being placed.
    local function rider()
        local w=call(R.skater and R.skater.telemetry)
        local a=call(R.skater and R.skater.get)
        local t=w[1] and w.n==2 and plain(w[2]) and w[2] or nil
        local watch=t and plain(t.watch) and t.watch or nil
        if not watch or not finite(watch.state) then return nil end
        local p=a[1] and a.n==2 and plain(a[2]) and a[2] or nil
        local down=watch.ragdoll_known~=true or watch.ragdoll~=false
        return {state=watch.state,down=down,standing=t.skater==true and watch.valid==true and not down
            and t.airborne==false and t.teleport_pending==false and p~=nil and p.airborne==false}
    end
    local function status()
        local out=call(bike.status,bike)
        local s=out[1] and plain(out[2]) and out[2] or nil
        if s then last_phase=s.phase end
        return s
    end
    local function idle(s)
        return s~=nil and IDLE[s.phase]==true and s.recovery_pending~=true and s.return_requested~=true
    end
    local function next_start()
        local out=call(bike.next_start_state,bike)
        return out[1] and (out[2]==100 or out[2]==504) and out[2] or nil
    end
    local function tell(message,now)
        trace("told: "..message)
        notice,notice_until=message,(now or 0)+NOTICE_MS
    end
    -- One sample of a wait that needs its condition to hold: true once it has held for ms over samples reads.
    local function held(p,now,ok,ms,samples)
        if not ok then p.since,p.last,p.samples=nil,nil,0;return false end
        if not p.last or now<=p.last or now-p.last>GAP_MS then p.since,p.samples=now,0 end
        p.last=now;p.samples+=1
        return now-p.since>=ms and p.samples>=samples
    end
    local function advance(now,s,read)
        local p=pending
        local limit=p.kind=="guard" and PRESS_LIMIT_MS or ARRIVE_MS
        if not idle(s) or next_start()~=p.start or now<p.at then pending=nil;return end
        if now-p.at>=limit then
            pending=nil
            -- The HUD said to stand still and not press Y for all of it. Dropped with no word, it went back to
            -- Entry's line, blank or asking for Y, and nothing said the bike was not coming.
            if p.kind=="arrive" then tell(NO_BIKE,now) end
            return
        end
        local r=rider()
        if p.kind=="guard" then
            -- Y was kept from the game, so the rider stays where they were. In the state the game's own Y leads to,
            -- the game had the Y after all, from a pad the mask does not cover. Any other way out of the start state,
            -- a crouch, a jump, a grind or a bail, only ends the press, with no word.
            if r and not r.down and r.state==OTHER[p.start] then pending=nil;tell(LEAK,now);return end
            if not r or not r.standing or r.state~=p.start or applied~=Y_BIT then pending=nil;return end
            if not held(p,now,read~=nil and read.buttons.y==false,GUARD_MS,GUARD_SAMPLES) then return end
            pending=nil
            -- Y stays kept: the Mount's first steps ask nothing of the game's input, and Entry asks before it hands
            -- the game's input on, then waits for Y to come back.
            call(bike.mount,bike)
            return
        end
        if not held(p,now,r~=nil and r.standing and r.state==p.start and at_rest(read),QUIET_MS,QUIET_SAMPLES) then return end
        pending=nil
        call(bike.mount,bike)
    end
    -- Whether Y should be kept from the game now, and for which state of the rider: the one the next ride starts from
    -- while the mod is idle, or the one Entry names while a Mount waits with nothing asked of the game's input
    -- (hold_state). It is hidden once the rider stands there. It stays hidden through the board's own states, a
    -- crouch, the air or a grind, so skating the board between rides costs no change: the state read is the game's
    -- physics state, which an ollie alone takes from 100 to 103 (crouched, Engine/Game/Build/20260929/no_bail.h) and
    -- to 200 or 201 (in the air, skater_state.h). Each change is a publication change that revokes every plugin's
    -- input leases, captures and pulses, and goes to the log. It goes back when the rider reaches the other stock
    -- state, where a press needs the game's Y, or goes down. A guarded press keeps the mask it was pressed under until
    -- it ends; one waiting for the rider to arrive needs the game to have Y.
    local function wanted(s)
        if broken or s==nil then return 0 end
        if pending then return pending.kind=="guard" and applied or 0 end
        local where
        if idle(s) then where=next_start() elseif s.hold_state==100 or s.hold_state==504 then where=s.hold_state end
        if where==nil then return 0 end
        local r=rider()
        if not r then return 0 end
        if applied==0 then return r.standing and r.state==where and Y_BIT or 0 end
        return not r.down and r.state~=OTHER[where] and Y_BIT or 0
    end
    function object:enabled() return enabled end
    -- The switch on the BMX page. The key is written only when it changes, and switching off clears it.
    function object:set_enabled(on)
        on=on==true
        if unloaded or on==enabled then return false end
        if type(key)=="string" then
            local out=call(R.storage and R.storage.set,key,on and {schema=1,bike_mode=true} or nil)
            if not out[1] then trace("Bike mode could not be kept for later launches: "..tostring(out[2])) end
        end
        enabled=on
        call(bike.set_controls,bike,on and "y" or "lb_a")
        if not on then pending=nil;set_mask(0) end
        return true
    end
    -- The bmx_y bind's press. It reaches here with or without the mask: a bind does not take the press from the game.
    function object:press()
        if unloaded or not enabled then return false end
        local now=clock()
        if not now or not in_front() then return false end
        local s=status()
        if not s then return false end
        -- The ride's capture already hands the game a neutral pad, and the ride reads no Y.
        if s.phase=="riding" then
            pending=nil;call(bike.return_to_skateboard,bike)
            return true
        end
        if pending or not (idle(s) or s.phase=="fallen") then return false end
        local start=next_start()
        if start==nil then
            -- No Mount can start. Asked anyway, Entry says why on the HUD, as it does for LB + A; the mask is off, so
            -- the game has had the Y too. After a fall this is the only thing Y does: Recover owns that phase.
            if s.recovery_pending~=true and s.return_requested~=true then call(bike.mount,bike) end
            return true
        end
        if s.phase=="fallen" then return false end
        local r=rider()
        if not r or not r.standing then return false end
        -- A line told for an earlier press, such as the leak's "Press Y again.", is answered by this one, and kept up
        -- it would ask for Y while this press waits.
        if r.state==start then
            -- With the mask off here the game had this Y and is acting on it.
            if applied~=Y_BIT then return false end
            pending={kind="guard",start=start,at=now,samples=0};notice=nil
            return true
        end
        if applied==0 and r.state==OTHER[start] then
            -- The game takes this Y and brings the rider to the start state: off the board for the first ride of a
            -- launch, onto it for a later one. Then the bike is asked for.
            pending={kind="arrive",start=start,at=now,samples=0};notice=nil
            return true
        end
        return false
    end
    -- Another BMX control was pressed: a Y press being carried out is dropped, so the two do not both ask Entry. The
    -- mask stays as it is, since Entry waits for Y to come back before it hands the game's input on.
    function object:drop_press() pending=nil end
    -- Each tick, after Entry's step.
    function object:step()
        if unloaded then return end
        if not enabled then
            pending=nil
            if applied~=0 then set_mask(0) end
            return
        end
        local now=clock()
        if not now or not in_front() then
            pending=nil
            if applied~=0 then set_mask(0) end
            return
        end
        local read=pad()
        local s=status()
        if pending then
            advance(now,s,read)
            if not pending then s=status() end
        end
        local mask=wanted(s)
        if mask==applied then return end
        -- An unreadable pad is taken as Y up for giving Y back, since it is most likely gone, but not for hiding it.
        if read and read.buttons.y==false or mask==0 and read==nil then set_mask(mask) end
    end
    -- A short line for the HUD in place of Entry's (main.lua): what a press being carried out waits for, or, for a
    -- few seconds, why a press did not bring the bike.
    function object:notice()
        if pending and not unloaded then return PENDING[pending.kind][pending.start] end
        if not notice then return nil end
        local now=clock()
        if now and now<notice_until then return notice end
        notice=nil
        return nil
    end
    function object:status()
        return table.freeze({enabled=enabled,mask=applied,pending=pending and pending.kind or nil,broken=broken,unloaded=unloaded})
    end
    function object:unload()
        if unloaded then return end
        unloaded=true;pending=nil
        if applied~=0 then call(R.input and R.input.game_buttons,0,0,false);applied=0 end
        log_unlogged()
    end
    return table.freeze(object)
end
return table.freeze(Y)

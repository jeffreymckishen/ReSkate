-- Every way a player found to lose the next ride after a fall: each ends riding again in the same launch.
-- Constructed services through the real Entry, facade, Core, Equipment and Source (remount_chain_fixture.lua).
local Chain=require("./remount_chain_fixture")
local T={}
local busy={stepping_off=true,preparing=true,surveying=true,awaiting_mount=true,mounting=true}
local function riding(w,from) local s=w.entry:status();return s.phase=="riding" and s.attempts_used>from end
-- What a player does: stands on the board, presses Mount, waits, and tries again a few times.
local function player_remounts(w,start)
    local from=start or w.entry:status().attempts_used
    for _=1,4 do
        if riding(w,from) then break end
        if not busy[w.entry:status().phase] then
            if w.stock~=100 then w.stock=100 end
            w.tick(70)
            w.entry:mount()
        end
        for _=1,1300 do w.tick();if riding(w,from) then break end end
    end
    return riding(w,from)
end
local function start(options)
    local w=Chain.new(options)
    w.mount_and_ride();w.ride_ms(500)
    return w
end
local function obstacle(w)
    w.R.world.probe=function(from,to)
        if from.y-to.y>1 then return {status="hit",position=vector.create(from.x,0,from.z)} end
        return {status="hit",position=vector.create(from.x,from.y,from.z)}
    end
end
local function steep(w)
    w.R.world.probe=function(from,to)
        if from.y-to.y>1 then return {status="hit",position=vector.create(from.x,from.x*.5,from.z)} end
        return {status="clear"}
    end
end
local function until_refused(w)
    for _=1,1500 do w.tick();local p=w.entry:status().phase;if p=="blocked" or p=="preflight_refused" then break end end
end
function T.run()
    local n,cases=0,0
    local function check(v,why) n+=1;assert(v,why) end
    local function case(body) cases+=1;body() end
    case(function() -- Beside a wall: the survey for the automatic remount finds something in the way.
        local w=start();local open=w.R.world.probe;obstacle(w);w.tilt_stop(59.7)
        until_refused(w)
        check(w.entry:status().phase=="preflight_refused","an obstacle is somewhere to move away from")
        w.R.world.probe=open;w.tick(100)
        check(player_remounts(w),"a Mount in the clear rides")
    end)
    case(function() -- On a hill, then rides the board somewhere flat.
        local w=start();local open=w.R.world.probe;steep(w);w.tilt_stop(59.7)
        until_refused(w)
        w.stock=100;w.tick(300);w.R.world.probe=open
        check(player_remounts(w),"a Mount from the board on flat ground rides")
    end)
    case(function() -- On a hill, then a long walk to flat ground.
        local w=start();local open=w.R.world.probe;steep(w);w.tilt_stop(59.7)
        until_refused(w)
        w.tick(math.ceil(70000/16));w.R.world.probe=open
        w.entry:mount();w.tick(100)
        check(player_remounts(w),"the step-off's time limit costs no ride")
    end)
    case(function() -- Insert opened while riding and left open past the cleanup watchdog.
        local w=start();w.interface_open=true;w.capture_hold=true
        w.on_tick=function()
            if w.stop_seen_at and w.capture_hold and w.now-w.stop_seen_at>=25000 then
                w.capture_hold=false;w.interface_open=false
            end
        end
        w.tick(math.ceil(30000/16))
        check(player_remounts(w),"cleanup past its watchdog still finishes")
    end)
    case(function() -- The Return's press went out, then a control stayed held for 20 s.
        local w=start({pulse_mode="stuck_release"});w.tilt_stop(59.7)
        w.on_tick=function()
            if w.pulse and w.pulse.mode=="stuck_release" and w.pulse.pressed and w.now-w.pulse.at>=20000 then
                w.pulse.mode="neutral";w.pulse_mode="neutral"
            end
        end
        w.tick(math.ceil(60000/16))
        check(player_remounts(w),"a pulse's deadline ends the wait, not the watch")
    end)
    case(function() -- First ride, fell, and got on the board by hand before the mod's own switch.
        local w=start();w.tilt_stop(59.7)
        w.pad.left_x=-1
        w.on_tick=function()
            if w.stop_seen_at and not w.boarded and w.stock==504 and w.now-w.stop_seen_at>=1000 then
                w.boarded=true;w.stock=100;w.pad.left_x=0
            end
        end
        w.tick(math.ceil(10000/16));w.on_tick=nil
        check(player_remounts(w),"boarding first costs no ride")
    end)
    case(function() -- A fall during the Y pulse, the session that was reported.
        local w=Chain.new({pulse_mode="held"})
        w.mount_and_ride();w.ride_ms(10600);w.tilt_stop(59.7)
        local opened,undone
        w.on_tick=function()
            if not opened and w.T and w.T.gear_requested then opened=w.now end
            if opened and not undone and w.now-opened>=900 then w.ragdoll=true end
            if opened and not undone and w.now-opened>=2400 then undone=true;w.ragdoll=false end
        end
        w.tick(math.ceil(30000/16));w.on_tick=nil;w.ragdoll=false;w.pulse_mode="neutral"
        check(player_remounts(w),"a fall during the pulse ends that pulse, not the session")
    end)
    case(function() -- The controls let go for a moment as the Return arms its switch, then held again.
        -- The user's log of 2026-11-02: the Return saw the controller at rest once and armed the switch, the
        -- controller was held again before the Y went out, and the SDK let that press expire unpressed.
        local w=start();w.tilt_stop(59.7)
        local arms,was,held,released={},false
        w.on_tick=function()
            local armed=w.T and w.T.gear_requested==true
            if armed and not was then arms[#arms+1]=w.now end;was=armed
            if not held and armed and w.entry:status().phase=="returning" then held=w.now;w.pad.buttons.rb=true
            elseif held and not released and w.now-held>=2000 then released=w.now;w.pad.buttons.rb=false end
        end
        -- As in the SDK, a press asked for while the controller is held is never published.
        w.on_pulse=function(p) if w.pad.buttons.rb then p.mode="held" end end
        for _=1,3000 do w.tick();if riding(w,1) then break end end
        local first,second=w.pulses[1],w.pulses[2]
        check(held and released and first and first.at>=released+600 and first.mode=="neutral",
            "the switch asks for no Y while the control is held, and asks 600 ms after it is let go")
        check(w.pulse_n==2 and riding(w,1),"that one press reaches the board, and the ride goes on")
        check(second and #arms==2 and second.at-arms[2]<=650,"the step-off's switch, the pad at rest, still goes 600 ms after it is armed")
    end)
    case(function() -- The SDK's Try-lock refuses the Follow ACK once.
        local w=Chain.new()
        local real=w.R.world.physics.acknowledge_follow;local refused=false
        w.R.world.physics.acknowledge_follow=function(h)
            if not refused then refused=true;return false,"follow cleanup is incomplete or receipt unavailable" end
            return real(h)
        end
        w.mount_and_ride();w.ride_ms(500);w.tilt_stop(59.7)
        w.tick(math.ceil(60000/16))
        check(refused and player_remounts(w),"a refused ACK is asked again")
    end)
    case(function() -- Ride reports its force ledger unknown at the stop.
        local w=start();w.ride_unknown=true;w.tilt_stop(59.7)
        w.tick(math.ceil(60000/16))
        check(player_remounts(w),"a completed Follow proves the forces are over")
    end)
    case(function() -- A crash on the last mount of the launch: nothing left to get back on, so the board comes back.
        local w=start()
        for used=1,7 do
            w.tilt_stop(59.7)
            for _=1,3000 do w.tick();if riding(w,used) then break end end
            check(riding(w,used),"the fall after mount "..used.." gets back on")
            w.ride_ms(500)
        end
        w.tilt_stop(59.7)
        for _=1,3000 do w.tick();if w.entry:status().phase=="skateboard" then break end end
        check(w.entry:status().phase=="skateboard" and w.stock==100,"on the board: "..tostring(w.entry:status().phase))
    end)
    case(function() -- Nothing else going wrong: the mod remounts by itself.
        local w=start();w.tilt_stop(59.7)
        for _=1,3000 do w.tick();if riding(w,1) then break end end
        check(riding(w,1),"a plain fall gets back on the bike")
    end)
    return {cases=cases,assertions=n,native_authority=false,constructed=true}
end
return T

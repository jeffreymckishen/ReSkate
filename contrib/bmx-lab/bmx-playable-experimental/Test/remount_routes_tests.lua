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
-- The SDK's create, with the real Spawn in the chain. One that can reuse is asked to every time, allocates the first
-- body and then re-activates the parked one, under a new handle each time.
local function reusing_sdk(w,...)
    local n,definition,options=select("#",...),...
    assert(n==2 and type(definition)=="table" and type(options)=="table" and options.reuse==true,
        "Spawn asks the SDK to reuse its parked bike")
    if w.body==nil then return newproxy(),nil,"allocated","none_parked" end
    return newproxy(),nil,"reused"
end
-- An older SDK ignores the option and returns the body alone.
local function older_sdk() return newproxy() end
local function refusing_sdk(why) return function() return nil,why end end
-- A reusing SDK that refuses the creates numbered `first` through `last`, with `why` (body_reuse_pending by default):
-- a parked bike still settling, or an SDK not ready yet.
local function refusing_from(first,last,why)
    return function(w,...)
        local at=#w.creates+1
        if at>=first and at<=last then return nil,why or "body_reuse_pending" end
        return reusing_sdk(w,...)
    end
end
local function refusing_once(at,why) return refusing_from(at,at,why) end
-- Ticks until the refused create has been cleaned up and the Entry has settled on or off the board.
local function until_refusal_settled(w)
    for _=1,4000 do
        w.tick()
        local p,core=w.entry:status().phase,w.manager:status()
        if core.spawn and core.spawn.creation_refusal and (p=="spent" or p=="skateboard" or p=="blocked") then break end
    end
end
-- What the Entry told the rider, from its log.
local function told(lines,message)
    for _,line in ipairs(lines) do if line=="[BMX] "..message then return true end end
    return false
end
-- How many times the Entry told the rider that.
local function times_told(lines,message)
    local n=0
    for _,line in ipairs(lines) do if line=="[BMX] "..message then n+=1 end end
    return n
end
-- Every create asked for reuse with the definition alone beside it.
local function asked_reuse(w)
    for _,c in ipairs(w.creates) do
        if c.args.n~=2 or type(c.args[2])~="table" or c.args[2].reuse~=true then return false end
    end
    return #w.creates>0
end
-- Falls with the automatic remount, from the mount after `from` through mount `to`.
local function falls(w,from,to,check)
    for used=from,to-1 do
        w.tilt_stop(59.7)
        for _=1,3000 do w.tick();if riding(w,used) then break end end
        check(riding(w,used),"the fall after mount "..used.." gets back on")
        w.ride_ms(500)
    end
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
-- Flat still ground under the bike for an explicit Return to measure, and a rider that goes where it is placed.
-- The ground is half a metre below the ray's start, or at floor_y when that is given.
local function measured(w,floor_y)
    local P=w.R.world.physics
    local base=P.probe_batch
    P.probe_batch=function(body,epoch,rays,settings)
        if #rays~=4 then return base(body,epoch,rays,settings) end
        local from=rays[1].from
        local y=floor_y or from.y-.5
        local batch={status="available",epoch=epoch,native_casts=4,budget_exhausted=false,local_actor_excluded=false,
            owned_bodies_excluded=true,requested_query_preset="camera",named_actor_categories_absent=true,rays={}}
        batch.rays[1]={status="hit",fraction=(from.y-y)/(from.y-rays[1].to.y),position=vector.create(from.x,y,from.z),normal_available=true,
            normal=vector.create(0,1,0),motion="measured",surface_velocity_available=true,surface_velocity=vector.create(0,0,0)}
        for i=2,4 do batch.rays[i]={status="clear"} end
        return batch
    end
    local position,heading=vector.create(0,.5,0),0
    w.placed=0
    w.R.skater.teleport=function(p,h) position,heading=p,h;w.placed+=1;return true end
    w.R.skater.get=function() return {airborne=w.airborne,position=position,heading=heading} end
end
-- An explicit Return with a control held: from the Return until `before` ms later, and again from when its switch
-- arms until `after` ms later. As in the SDK, a press asked for while the controller is held is never published.
local function held_return(before,after)
    local w=start({real_ride=true});measured(w)
    local accepted=w.entry:return_to_skateboard()
    w.plan=accepted and w.entry:status().return_position~=nil
    local from=w.now
    w.pad.buttons.rb=before>0
    w.on_tick=function()
        local armed=w.T and w.T.gear_requested==true
        if armed and not w.armed_at then w.armed_at=w.now end
        if not w.armed_at and w.now-from>=before then w.pad.buttons.rb=false end
        if not w.held_at and armed and w.entry:status().phase=="returning" then w.held_at=w.now;w.pad.buttons.rb=after>0
        elseif w.held_at and not w.let_go_at and w.now-w.held_at>=after then w.let_go_at=w.now;w.pad.buttons.rb=false end
    end
    w.on_pulse=function(p) if w.pad.buttons.rb then p.mode="held" end end
    for _=1,4000 do w.tick();local p=w.entry:status().phase;if p=="skateboard" or p=="blocked" then break end end
    w.on_tick=nil;w.on_pulse=nil
    return w
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
    case(function() -- On a hill, then a long walk: the late Mount itself rides, with no new step-off (reuse6 in game).
        local w=start();local open=w.R.world.probe;steep(w);w.tilt_stop(59.7)
        until_refused(w)
        local s=w.entry:status()
        check(s.phase=="preflight_refused" and s.attempts_used>=2,"the later cycle's survey refuses the hill")
        local from=s.attempts_used
        w.tick(math.ceil(74000/16));w.R.world.probe=open
        check(w.stock==504,"still on foot after the walk")
        w.clock_offset=.25 -- the press reads a fractional game time, which the runtime only takes as whole ms
        check(w.entry:mount(),"a Mount 74 s after the step-off is a terrain retry: "..tostring(w.entry:status().detail))
        check(w.entry:status().phase=="preparing","the retry surveys again rather than block")
        for _=1,1500 do w.tick();local p=w.entry:status().phase;if p=="riding" or p=="blocked" then break end end
        s=w.entry:status()
        check(s.phase=="riding" and s.attempts_used==from,
            "the retry rides with its own 60 s, in the same cycle: "..tostring(s.phase).." "..tostring(s.detail))
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
    case(function() -- An explicit Return: let go as it arms its switch about 3 s after the stop, then held 10 s more.
        -- The Y waits for the controller at rest, so the switch matched its target with less of the measured placement's
        -- 20 s left than one queued placement needs, the rider already on the board.
        local w=held_return(3000,10000)
        local stop,s=w.stop_seen_at,w.entry:status()
        check(w.plan and math.abs(w.armed_at-stop-3000)<=250,"the Return measured a placement and armed about 3 s after the stop")
        check(w.pulse_n==1 and w.pulses[1].at>=w.let_go_at+600 and w.now-stop>=20000-5100,
            "one Y, once the control was let go, finishing with too little of the window left to place the rider")
        check(s.phase=="skateboard" and w.stock==100 and w.placed==0 and s.return_position==nil,
            "the Return ends on the board where the rider stands: "..tostring(s.detail))
        check(player_remounts(w),"and the next Mount rides")
    end)
    case(function() -- The same Return let go after 6 s: its placement still fits the window and still runs.
        local w=held_return(3000,6000)
        local s=w.entry:status()
        check(w.plan and w.pulse_n==1 and w.pulses[1].at>=w.let_go_at+600,"one Y, once the control was let go")
        check(s.phase=="skateboard" and w.placed==1 and s.return_position and s.return_position.observed==true,
            "the rider is placed once and seen there: "..tostring(s.detail))
        check(player_remounts(w),"and the next Mount rides")
    end)
    case(function() -- A control held from an explicit Return until 12 s later, so its switch arms late and the Y with it.
        local w=held_return(12000,0)
        local s=w.entry:status()
        check(w.plan and w.armed_at-w.stop_seen_at>=11900 and w.pulse_n==1,"the switch arms once the control is let go")
        check(s.phase=="skateboard" and w.stock==100 and w.placed==0,"the Return ends on the board: "..tostring(s.detail))
    end)
    case(function() -- 12 s in the pause menu right after an explicit Return, when no Y may be sent.
        local w=start({real_ride=true});measured(w)
        check(w.entry:return_to_skateboard() and w.entry:status().return_position~=nil,"the Return measured a placement")
        local from=w.now;w.game_menu=true
        w.on_tick=function() if w.now-from>=12000 then w.game_menu=false end end
        for _=1,4000 do w.tick();local p=w.entry:status().phase;if p=="skateboard" or p=="blocked" then break end end
        w.on_tick=nil
        local s=w.entry:status()
        check(s.phase=="skateboard" and w.stock==100 and w.placed==0,"the Return ends on the board: "..tostring(s.detail))
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
    case(function() -- Ten crashes in a launch with an SDK that reuses the parked bike: every one gets back on.
        local w=start({create=reusing_sdk})
        falls(w,1,11,check)
        local s=w.entry:status()
        check(s.attempts_used==11 and s.attempt_limit==nil and s.body_reuse==true,"no cap once the SDK says where bodies come from")
        check(#w.creates==11 and asked_reuse(w),"every mount asked for the parked bike")
    end)
    case(function() -- An older SDK that returns the body alone: a crash on the eighth mount brings the board back.
        local w=start({create=older_sdk})
        falls(w,1,8,check)
        w.tilt_stop(59.7)
        for _=1,3000 do w.tick();if w.entry:status().phase=="skateboard" then break end end
        local s=w.entry:status()
        check(s.phase=="skateboard" and w.stock==100,"on the board: "..tostring(s.phase))
        check(s.attempt_limit==8 and s.body_reuse==false and #w.creates==8,"the cap stays at eight")
        local mounted,why=w.entry:mount()
        check(not mounted and why=="All 8 mounts are used: restart the game to ride again.","a ninth Mount says why: "..tostring(why))
    end)
    case(function() -- Twelve Mount and Return cycles in one launch with an SDK that reuses the parked bike.
        local w=start({create=reusing_sdk});measured(w,0) -- The rider goes back where they mounted.
        for used=1,11 do
            check(w.entry:return_to_skateboard(),"Return "..used.." accepted")
            for _=1,3000 do w.tick();if w.entry:status().phase=="skateboard" then break end end
            check(w.entry:status().phase=="skateboard","Return "..used.." reaches the board: "..tostring(w.entry:status().phase))
            check(player_remounts(w,used),"Mount "..(used+1).." rides")
            w.ride_ms(500)
        end
        local s,core=w.entry:status(),w.manager:status()
        check(s.attempts_used==12 and s.attempt_limit==nil,"twelve mounts and no cap")
        check(#w.creates==12 and asked_reuse(w),"every mount asked for the parked bike")
        check(core.spawn.origin=="reused" and core.spawn.reuse_miss==nil,"the twelfth bike is the parked one")
    end)
    case(function() -- The SDK has no body left this launch: a clean refusal, then the board, and the rider is told.
        for _,why in ipairs({"the eight retained body slots are exhausted; native destruction is unproven","body_slots_exhausted"}) do
            local w=Chain.new({create=refusing_sdk(why)})
            check(w.entry:mount(),"Mount accepted")
            until_refusal_settled(w)
            local s,core=w.entry:status(),w.manager:status()
            check(core.spawn.creation_unknown==false and core.spawn.creation_refusal=="restart","no body and nothing to clean up: "..why)
            check(core.cleanup_unknown==false and core.bike_cleanup_complete==true,"cleanup finishes")
            check(s.phase=="spent" and w.stock==100,"back on the board: "..tostring(s.phase).." "..tostring(s.detail))
            local mounted,told_why=w.entry:mount()
            check(not mounted and told_why=="No bike is left this launch: restart the game to ride again.","Mount says why: "..tostring(told_why))
            check(#w.creates==1,"and asks the SDK no more")
        end
    end)
    case(function() -- A world that refuses another body, or a parked bike that could not be re-activated.
        for _,why in ipairs({"body_reactivation_failed","a previous partial allocation in this world prohibits another native allocation",
            "body_allocation_prohibited"}) do
            local w=Chain.new({create=refusing_sdk(why)})
            check(w.entry:mount(),"Mount accepted")
            until_refusal_settled(w)
            local core=w.manager:status()
            check(core.spawn.creation_refusal=="change_level" and core.cleanup_unknown==false,"no body and nothing to clean up: "..why)
            -- Rides do not carry on past a level change in this launch, so only a restart helps.
            local mounted,told_why=w.entry:mount()
            check(not mounted and told_why=="The bike can't be made here: restart the game to ride again.","Mount says why: "..tostring(told_why))
            check(#w.creates==1,"and asks the SDK no more")
        end
    end)
    case(function() -- The SDK is not ready, or the parked bike not settled: a clean refusal, and the next Mount rides.
        for _,why in ipairs({"body_reuse_pending","body_preallocation_unavailable"}) do
            local lines={}
            local w=Chain.new({create=refusing_once(1,why),log=function(line) lines[#lines+1]=line end})
            check(w.entry:mount(),"Mount accepted")
            until_refusal_settled(w)
            local core=w.manager:status()
            check(core.spawn.creation_unknown==false and core.spawn.creation_refusal=="retry" and core.cleanup_unknown==false,
                "no body and nothing to clean up: "..why)
            check(w.entry:status().phase=="skateboard" and w.stock==100,"back on the board: "..tostring(w.entry:status().phase)
                .." "..tostring(w.entry:status().detail))
            check(told(lines,"The bike was not ready: mount again."),"the rider is told to mount again")
            check(player_remounts(w) and #w.creates==2,"and the next Mount rides")
        end
    end)
    case(function() -- Getting back on after a Return before the parked bike has settled: told, and Mount rides it.
        local lines={}
        local w=start({create=refusing_once(2),log=function(line) lines[#lines+1]=line end});measured(w,0)
        check(w.entry:return_to_skateboard(),"Return accepted")
        for _=1,3000 do w.tick();if w.entry:status().phase=="skateboard" then break end end
        check(w.entry:mount(),"Mount 2 accepted")
        until_refusal_settled(w)
        local s=w.entry:status()
        check(s.phase=="skateboard" and #w.creates==2 and told(lines,"The bike was not ready: mount again."),
            "the refused Mount ends on the board and says so: "..tostring(s.phase).." "..tostring(s.detail))
        check(player_remounts(w) and #w.creates==3 and w.manager:status().spawn.origin=="reused","Mount 3 rides the parked bike")
    end)
    case(function() -- Two Mounts in a row before the parked bike has settled: the rider is told each time.
        local lines={}
        local w=start({create=refusing_from(2,3),log=function(line) lines[#lines+1]=line end});measured(w,0)
        check(w.entry:return_to_skateboard(),"Return accepted")
        for _=1,3000 do w.tick();if w.entry:status().phase=="skateboard" then break end end
        for mount=2,3 do
            if mount>2 then w.tick(70) end
            local mounted,why=w.entry:mount()
            check(mounted,"Mount "..mount.." accepted: "..tostring(why))
            until_refusal_settled(w)
            local s=w.entry:status()
            check(s.phase=="skateboard" and #w.creates==mount,"Mount "..mount.." ends on the board: "..tostring(s.phase).." "..tostring(s.detail))
            check(times_told(lines,"The bike was not ready: mount again.")==mount-1,"Mount "..mount.."'s refusal is told: "
                ..times_told(lines,"The bike was not ready: mount again.").." times")
        end
        check(player_remounts(w) and #w.creates==4 and w.manager:status().spawn.origin=="reused","Mount 4 rides the parked bike")
    end)
    case(function() -- The SDK not ready for nine Mounts before the first bike: none of them is a mount used.
        local lines={}
        local w=Chain.new({create=refusing_from(1,9,"body_preallocation_unavailable"),log=function(line) lines[#lines+1]=line end})
        for mount=1,9 do
            if mount>1 then w.tick(70) end
            local mounted,why=w.entry:mount()
            check(mounted,"Mount "..mount.." accepted: "..tostring(why))
            until_refusal_settled(w)
            local s=w.entry:status()
            check(s.phase=="skateboard" and w.stock==100 and #w.creates==mount,
                "Mount "..mount.." is refused and ends on the board: "..tostring(s.phase).." "..tostring(s.detail))
        end
        local s=w.entry:status()
        check(s.attempt_limit==8 and s.body_reuse==nil,"with no body made yet the defensive cap of eight still stands")
        check(times_told(lines,"The bike was not ready: mount again.")==9,"each refusal is told")
        check(player_remounts(w) and #w.creates==10 and w.manager:status().spawn.origin=="allocated","the tenth Mount rides the first bike")
        check(w.entry:status().attempt_limit==nil and w.entry:status().body_reuse==true,"and that body's origin lifts the cap")
    end)
    case(function() -- The automatic remount after a fall refused the same way: back on the board once, and Mount rides.
        local w=start({create=refusing_once(2)})
        w.tilt_stop(59.7)
        until_refusal_settled(w)
        local s=w.entry:status()
        check(s.phase=="skateboard" and #w.creates==2,"the refused remount ends on the board: "..tostring(s.phase).." "..tostring(s.detail))
        w.tick(300)
        check(#w.creates==2 and w.entry:status().phase=="skateboard","and does not ask again by itself")
        check(player_remounts(w) and #w.creates==3,"the next Mount rides")
    end)
    -- Ticks until the Entry rides a mount after `from` or stops, noting each HUD line shown on the way.
    local function until_riding(w,from,limit)
        local shown={}
        for _=1,limit or 4000 do
            w.tick();shown[w.entry:help_line() or "none"]=true
            local p=w.entry:status().phase
            if p=="blocked" or riding(w,from) then break end
        end
        return riding(w,from),shown
    end
    case(function() -- Knocked down mid-ride: the user's beta sessions of 2026-11-02 and 2026-11-04, and loop3 beside an SUV.
        local w=start();w.ragdoll=true
        local stood
        w.on_tick=function()
            if w.stop_seen_at and not stood and w.now-w.stop_seen_at>=8000 then stood=w.now;w.ragdoll=false end
        end
        local rode,shown=until_riding(w,1)
        w.on_tick=nil
        local s=w.entry:status()
        check(s.last_stop=="rider was knocked down","the stop says the rider was knocked down: "..tostring(s.last_stop))
        check(rode and s.attempts_used==2,"and the rider gets back on the bike once they stand: "..tostring(s.phase).." "..tostring(s.detail))
        check(stood and w.pulses[1] and w.pulses[1].at>=stood,"no Y while the rider was down")
        check(shown["Press A to get up."],"while down the HUD says so")
    end)
    case(function() -- A crash that keeps the rider down for over a minute, as beside the SUV in loop3 (2026-11-04).
        for _,down in ipairs({{stock=504,name="on foot, ragdolled"},{stock=300,name="fallen"}}) do
            local w=start();w.tilt_stop(59.7)
            local stood
            w.on_tick=function()
                if not w.stop_seen_at or stood then return end
                if w.now-w.stop_seen_at<65000 then w.ragdoll=true;w.stock=down.stock
                else stood=w.now;w.ragdoll=false;w.stock=504 end
            end
            local rode,shown=until_riding(w,1,8000)
            w.on_tick=nil
            local s=w.entry:status()
            check(rode and s.attempts_used==2,down.name.." 65 s, the rider still gets back on the bike: "..tostring(s.phase).." "..tostring(s.detail))
            check(stood and w.pulses[1] and w.pulses[1].at>=stood,down.name..": no Y while the rider was down")
            check(shown["Press A to get up."] and not shown["That didn't finish. Get on your skateboard, then hold LB and press A."],
                down.name..": the HUD said why it waited, and never that it gave up")
        end
    end)
    case(function() -- The rider reads off the board as the remount after a crash steps off: the user's crash of 2026-11-02 19:35.
        local w=start();w.tilt_stop(59.7)
        local hit,cleared
        w.on_tick=function()
            if not hit and w.entry:status().phase=="stepping_off" then hit=w.now;w.ragdoll=true end
            if hit and not cleared and w.now-hit>=1100 then cleared=w.now;w.ragdoll=false end
        end
        local rode=until_riding(w,1)
        w.on_tick=nil
        check(hit and cleared and rode and w.entry:status().attempts_used==2,
            "a ragdoll sample in the step-off waits, and the mount still happens: "..tostring(w.entry:status().detail))
        check(w.pulses[2] and w.pulses[2].at>=cleared+600,"the step-off's Y waits a full quiet window after it")
    end)
    -- Ticks to the end of a Return that may give up, noting when each HUD line was first and last shown after `from`.
    local function until_blocked_or_riding(w,limit)
        local first,last={},{}
        for _=1,limit do
            w.tick()
            local h=w.entry:help_line() or "none"
            local at=w.now-(w.stop_seen_at or w.now)
            first[h]=first[h] or at;last[h]=at
            local p=w.entry:status().phase
            if p=="blocked" or riding(w,1) then break end
        end
        return first,last
    end
    local WAITING,LET_GO="Press A to get up.","Going back to the skateboard: let go of the controls."
    case(function() -- Down 10 s after a crash, then standing with the stick held: told to let go, and the 45 s run.
        -- Until 2026-11-04 the last refusal from while the rider was down kept 'Waiting for the rider to get up.' up
        -- and the 45 s stopped, so this Return sat for 3 minutes with the HUD hiding what would unblock it.
        local w=start();w.tilt_stop(59.7)
        local stood
        w.on_tick=function()
            if not w.stop_seen_at or stood then return end
            if w.now-w.stop_seen_at<10000 then w.ragdoll=true
            else stood=w.now-w.stop_seen_at;w.ragdoll=false;w.stock=504;w.pad.left_x=.9 end
        end
        local first,last=until_blocked_or_riding(w,math.ceil(200000/16))
        w.on_tick=nil;w.pad.left_x=0
        local s=w.entry:status()
        check(stood and first[WAITING] and last[WAITING]<stood+100,"the waiting line only while down: "..tostring(last[WAITING]))
        check(first[LET_GO] and first[LET_GO]<=stood+100,"standing with the stick held, the HUD asks to let go")
        local at=w.now-w.stop_seen_at
        check(s.phase=="blocked" and s.detail:find("Return did not finish",1,true) and at>=50000 and at<=57000 and w.pulse_n==0,
            "and the 45 s limit ends it, not the 3-minute cap: "..tostring(at).." ms "..s.phase)
    end)
    case(function() -- Ragdolled 65 s with the stick held all along, then up and let go: still gets back on the bike.
        local w=start();w.tilt_stop(59.7)
        local stood
        w.on_tick=function()
            if not w.stop_seen_at or stood then return end
            if w.now-w.stop_seen_at<65000 then w.ragdoll=true;w.pad.left_x=.9 else stood=w.now;w.ragdoll=false;w.pad.left_x=0 end
        end
        local rode,shown=until_riding(w,1,8000)
        w.on_tick=nil;w.pad.left_x=0
        local s=w.entry:status()
        check(rode and s.attempts_used==2,"a stick held while down does not run out the Return: "..tostring(s.phase).." "..tostring(s.detail))
        check(shown[WAITING] and not shown["That didn't finish. Get on your skateboard, then hold LB and press A."],
            "the HUD said why it waited, and never that it gave up")
        check(stood and w.pulses[1] and w.pulses[1].at>=stood,"no Y while the rider was down")
    end)
    case(function() -- A level change after the stop: Core refuses every switch, though the rider stands and has let go.
        -- Core's refusal is the same text it gives a rider who is down. Until 2026-11-04 that kept 'Waiting for the rider
        -- to get up.' up and the Return going for 3 minutes; it ends at 45 s, as before 21f2f0a2.
        local w=start();w.tilt_stop(59.7)
        w.on_tick=function() if w.stop_seen_at and w.level~="another" then w.level="another" end end
        local first=until_blocked_or_riding(w,math.ceil(200000/16))
        w.on_tick=nil
        local s=w.entry:status()
        local at=w.now-w.stop_seen_at
        check(s.phase=="blocked" and s.detail:find("Return did not finish",1,true) and at>=43000 and at<=47000,
            "the Return ends at 45 s: "..tostring(at).." ms "..s.phase.." "..tostring(s.detail))
        check(not first[WAITING],"the HUD never says the rider is down")
        check(w.entry:help_line()=="That didn't finish. Get on your skateboard, then hold LB and press A.",
            "a ride whose Core was made keeps the general blocked line: "..tostring(w.entry:help_line()))
    end)
    case(function() -- The remount after a crash steps off and reads the rider standing on foot: the HUD asks for Y.
        local Y_LINE="Press Y for your skateboard, then let go of the controls."
        local w=start();w.tilt_stop(59.7)
        local hit,boarded
        local first={}
        w.on_tick=function()
            if not hit and w.entry:status().phase=="stepping_off" then hit=w.now;w.stock=504;w.ragdoll=false end
            -- The player presses Y 5 s in.
            if hit and not boarded and w.now-hit>=5000 then boarded=w.now;w.stock=100 end
        end
        for _=1,4000 do
            w.tick()
            if hit then local h=w.entry:help_line() or "none";first[h]=first[h] or w.now-hit end
            if w.entry:status().phase=="blocked" or riding(w,1) then break end
        end
        w.on_tick=nil
        check(hit and first[Y_LINE] and first[Y_LINE]>=1000 and first[Y_LINE]<=1500,
            "standing on foot for a second, the HUD asks for Y: "..tostring(first[Y_LINE]))
        check(boarded and riding(w,1) and w.entry:status().attempts_used==2,
            "Y pressed, the step-off goes on and the rider gets back on the bike: "..tostring(w.entry:status().detail))
        -- One 200 ms read on foot, then the board again: no Y line, and the remount goes on.
        local v=start();v.tilt_stop(59.7)
        local seen,back
        local shown=false
        v.on_tick=function()
            if not seen and v.entry:status().phase=="stepping_off" then seen=v.now;v.stock=504 end
            if seen and not back and v.now-seen>=200 then back=v.now;v.stock=100 end
        end
        for _=1,4000 do
            v.tick();shown=shown or v.entry:help_line()==Y_LINE
            if v.entry:status().phase=="blocked" or riding(v,1) then break end
        end
        v.on_tick=nil
        check(back and not shown and riding(v,1),"a short read on foot never asks for Y: "..tostring(v.entry:status().detail))
    end)
    case(function() -- The game loses focus mid-ride: the same readiness stop as before, and a plain Return to the board.
        local w=start();w.focused=false
        w.on_tick=function() if w.stop_seen_at and w.now-w.stop_seen_at>=5000 then w.focused=true end end
        for _=1,4000 do w.tick();local p=w.entry:status().phase;if p=="skateboard" or p=="blocked" then break end end
        w.on_tick=nil
        local s=w.entry:status()
        check(s.last_stop=="fresh sampled upright/focus/context/fall readiness lost" and s.fall_reason==nil,
            "the stop keeps its old text and is not a fall: "..tostring(s.last_stop))
        check(s.phase=="skateboard" and w.stock==100 and s.attempts_used==1 and not s.recovery_pending,
            "the Return ends on the board: "..tostring(s.phase).." "..tostring(s.detail))
        w.tick(300)
        check(w.entry:status().phase=="skateboard" and w.entry:status().attempts_used==1,"and does not get back on the bike by itself")
    end)
    case(function() -- F8 where Core cannot measure where to put the rider: Core stops the bike anyway, and the Return goes on.
        local w=start()
        check(w.entry:return_to_skateboard(),"the Return is accepted")
        local s,core=w.entry:status(),w.manager:status()
        check(s.phase=="returning" and s.return_position==nil and core.stop_latched and type(core.return_capture_issue)=="string",
            "Core stopped the bike and measured nothing: "..tostring(core.return_capture_issue))
        for _=1,3000 do w.tick();local p=w.entry:status().phase;if p=="skateboard" or p=="blocked" then break end end
        check(w.entry:status().phase=="skateboard" and w.stock==100 and w.pulse_n==1,
            "one Y after cleanup reaches the board: "..tostring(w.entry:status().detail))
        check(player_remounts(w),"and the next Mount rides")
    end)
    -- Ticks until Core latches a stop, then until the Entry has gone back to the board or settled elsewhere.
    local function until_settled(w)
        for _=1,1000 do if w.manager:status().stop_latched then break end;w.tick() end
        for _=1,4000 do local p=w.entry:status().phase;if p=="skateboard" or p=="spent" or p=="blocked" then break end;w.tick() end
    end
    local REFUSED="capture refusal, exception or malformed result (refused: "
    case(function() -- One authority_lost capture refusal, as at loop10's fourth Mount (2026-11-05 00:55): asked again, and rides.
        local w=Chain.new({create=reusing_sdk})
        w.on_capture=function(n) if n==1 then return {false,"authority_lost",n=2} end end
        check(w.entry:mount(),"Mount accepted")
        local reached,why=w.until_phase("riding")
        check(reached,"the Source asks again on its next observation and rides: "..tostring(why))
        w.ride_ms(500)
        local core=w.manager:status()
        check(core.phase=="following" and not core.stop_latched and core.source.phase=="capturing"
            and core.last_source_step and core.last_source_step.input_ok==true,
            "riding on the captured input: "..tostring(core.phase).." "..tostring(core.stop_reason))
        check(w.capture_calls==2 and w.captures_admitted==1 and core.capture_attempted==true,"one admitted capture: "..w.capture_calls)
        check(core.capture_refusals==1 and core.capture_refusal=="authority_lost","the refusal is kept for the log")
        -- The same at the fourth Mount, a remount after a fall with the parked bike.
        local v=start({create=reusing_sdk})
        falls(v,1,3,check)
        v.on_capture=function(n) if n==4 then return {false,"authority_lost",n=2} end end
        v.tilt_stop(59.7)
        for _=1,3000 do v.tick();if riding(v,3) then break end end
        check(riding(v,3) and v.capture_calls==5 and v.captures_admitted==4,"the fourth Mount rides: "..tostring(v.entry:status().phase)
            .." "..tostring(v.manager:status().stop_reason))
        check(v.manager:status().capture_refusals==1 and not v.manager:status().stop_latched,"after one refusal")
    end)
    case(function() -- Loop10's shape: three rides and Returns, then a fourth Mount the SDK refuses past the bound.
        local lines={}
        local w=start({create=reusing_sdk,log=function(line) lines[#lines+1]=line end});measured(w,0)
        for used=1,3 do
            check(w.entry:return_to_skateboard(),"Return "..used.." accepted")
            for _=1,3000 do w.tick();if w.entry:status().phase=="skateboard" then break end end
            check(w.entry:status().phase=="skateboard","Return "..used.." reaches the board: "..tostring(w.entry:status().phase))
            if used<3 then check(player_remounts(w,used),"Mount "..(used+1).." rides");w.ride_ms(500) end
        end
        w.on_capture=function() return {false,"authority_lost",n=2} end
        w.tick(70)
        check(w.entry:mount(),"Mount 4 accepted")
        until_settled(w)
        local core,s=w.manager:status(),w.entry:status()
        check(core.stop_reason==REFUSED.."authority_lost)","the stop keeps the text trials grep: "..tostring(core.stop_reason))
        check(told(lines,"Ride ended: "..REFUSED.."authority_lost)"),"and the log says so")
        check(s.phase=="skateboard" and w.stock==100,"back on the board, not spent: "..tostring(s.phase).." "..tostring(s.detail))
        check(w.manager:can_prepare_next_mount()==true,"a clean successor is available")
        check(core.capture_attempted==false,"a refused capture reserved nothing")
        check(w.capture_calls==12 and w.captures_admitted==3 and core.capture_refusals==9 and core.capture_refusal=="authority_lost",
            "nine refusals and no capture: "..w.capture_calls)
        w.on_capture=nil
        check(player_remounts(w,4) and w.captures_admitted==4,"and Mount 5 rides")
        -- Eight retryable refusals are each asked again, and the ninth capture rides.
        for _,why in ipairs({"authority_lost","busy","source_stale"}) do
            local v=Chain.new({create=reusing_sdk})
            v.on_capture=function(n) if n<=8 then return {false,why,n=2} end end
            check(v.entry:mount(),"Mount accepted")
            local reached,detail=v.until_phase("riding")
            check(reached and v.capture_calls==9 and v.captures_admitted==1,"eight "..why.." refusals, then rides: "..tostring(detail))
            check(v.manager:status().capture_refusals==8 and not v.manager:status().stop_latched,"no stop within the bound")
        end
    end)
    case(function() -- A refusal the SDK does not expect retried stops the ride at once, and the next Mount still rides.
        for _,answer in ipairs({{false,"menu_open",n=2},{false,n=1}}) do
            local reason=answer[2] or "no reason given"
            local w=Chain.new({create=reusing_sdk})
            w.on_capture=function() return answer end
            check(w.entry:mount(),"Mount accepted")
            until_settled(w)
            local core,s=w.manager:status(),w.entry:status()
            check(core.stop_reason==REFUSED..reason..")" and w.capture_calls==1,"stopped at the first refusal: "..tostring(core.stop_reason))
            check(s.phase=="skateboard" and w.stock==100,"back on the board, not spent: "..tostring(s.phase).." "..tostring(s.detail))
            check(core.capture_attempted==false and core.capture_refusals==1 and core.capture_refusal==reason,"which reserved nothing")
            w.on_capture=nil
            check(player_remounts(w) and w.captures_admitted==1,"and the next Mount rides")
        end
    end)
    case(function() -- A capture asked for inside another's callback, or after one was admitted, still stops the ride.
        local w=Chain.new()
        local inner
        w.on_capture=function(n,h,epoch) if n==1 then inner=table.pack(w.source_api.lease_capture(h,epoch)) end end
        check(w.entry:mount(),"Mount accepted")
        for _=1,400 do w.tick();if w.manager and w.manager:status().stop_latched then break end end
        local core=w.manager:status()
        check(inner and inner[1]==false and inner[2]=="one-shot capture only","the reentrant capture is refused")
        check(core.stop_reason=="second or cancelled capture attempt refused" and w.capture_calls==1 and w.captures_admitted==1,
            "and stops the ride without reaching the SDK: "..tostring(core.stop_reason))
        local v=start()
        local again=table.pack(v.source_api.lease_capture(v.handle,newproxy()))
        local c=v.manager:status()
        check(again[1]==false and again[2]=="one-shot capture only" and c.stop_reason=="second or cancelled capture attempt refused",
            "a second capture after one was admitted is refused: "..tostring(c.stop_reason))
        check(v.capture_calls==1 and v.captures_admitted==1,"and never reaches the SDK")
    end)
    case(function() -- A capture whose outcome is unknown, raised or malformed, still spends the chain.
        for _,answer in ipairs({"raise","malformed"}) do
            -- admitted: the SDK took the capture and its answer was lost, so the Source's cleanup can see it end. Without
            -- it nothing was taken, but nothing can show that either, so the cleanup stays retained.
            for _,admitted in ipairs({true,false}) do
                local w=Chain.new({create=reusing_sdk})
                w.on_capture=function(_,h,epoch)
                    if admitted then assert(w.admit_capture(h,epoch)) end
                    if answer=="raise" then error("constructed capture fault",0) end
                    return {"admitted",n=1}
                end
                check(w.entry:mount(),"Mount accepted")
                until_settled(w)
                local core,s=w.manager:status(),w.entry:status()
                local why=answer=="raise" and "exception: constructed capture fault" or "malformed result: string/2"
                check(core.stop_reason=="capture refusal, exception or malformed result ("..why..")","the same stop: "..tostring(core.stop_reason))
                check(core.capture_attempted==true and (core.capture_refusals or 0)==0,"an unknown capture spends the cycle's one")
                check(w.manager:can_prepare_next_mount()~=true,"no clean successor: "..tostring(s.phase))
                -- With its cleanup seen through, the rider is back on the board and the chain is spent, as before.
                check(not admitted or s.phase=="spent" and w.stock==100 and core.bike_cleanup_complete==true,
                    "spent on the board: "..tostring(s.phase).." "..tostring(s.detail))
                local mounted,told_why=w.entry:mount()
                check(not mounted and (not admitted or told_why=="The bike is stuck: restart the game to ride again."),
                    "the next Mount is refused: "..tostring(told_why))
                for _=1,600 do w.tick() end
                check(w.capture_calls==1 and w.captures_admitted==(admitted and 1 or 0),"and asks the SDK no more")
            end
        end
    end)
    case(function() -- The automatic remount after a fall refused for its input: back on the board once, not remounting for ever.
        -- The fall belongs to the ride that fell. Carried into the remount's stop it read as a second fall, and the mod
        -- got back on by itself again after every refusal (the capture-retry review, 2026-11-05).
        for _,variant in ipairs({"capture","lease"}) do
            local lines={}
            local w=start({create=reusing_sdk,log=function(line) lines[#lines+1]=line end})
            local base_lease,leases_refused=w.R.input.lease,0
            if variant=="capture" then w.on_capture=function(n) if n>=2 then return {false,"authority_lost",n=2} end end
            else w.R.input.lease=function() leases_refused+=1;return nil,"busy" end end
            w.tilt_stop(59.7)
            local back,mounts={},{}
            for _=1,9000 do
                w.tick()
                local s=w.entry:status()
                mounts[s.attempts_used]=true
                if s.phase=="skateboard" and s.attempts_used==2 and w.manager:status().stop_latched then back[#back+1]=w.now;break end
            end
            for _=1,1500 do w.tick() end
            local s,core=w.entry:status(),w.manager:status()
            check(#back==1 and s.phase=="skateboard" and w.stock==100,
                variant..": the refused remount ends on the board: "..tostring(s.phase).." "..tostring(s.detail))
            -- Core asks for the lease and the capture before the body, so the refused remount makes no bike.
            check(s.attempts_used==2 and not mounts[3] and #w.creates==1,variant..": and does not mount again by itself: "
                ..s.attempts_used.." mounts, "..#w.creates.." creates")
            check(s.fall_reason==nil and s.recovery_pending==false,variant..": the remount's stop is not a fall: "..tostring(s.fall_reason))
            check(times_told(lines,"told: The rider came off. Getting back on the bike.")==1
                and times_told(lines,"told: The ride stopped. Going back to the skateboard.")==1,variant..": the fall is told once, then the stop")
            if variant=="capture" then
                check(core.stop_reason==REFUSED.."authority_lost)" and w.capture_calls==10 and w.captures_admitted==1,
                    "capture: nine refusals, then the stop: "..tostring(core.stop_reason).." "..w.capture_calls)
                w.on_capture=nil
            else
                check(core.stop_latched and leases_refused==1 and w.capture_calls==1 and w.captures_admitted==1,
                    "lease: one refused lease, and no capture asked for: "..leases_refused.." "..w.capture_calls.." "..tostring(core.stop_reason))
                w.R.input.lease=base_lease
            end
            check(player_remounts(w,2),variant..": and the player's next Mount rides")
        end
    end)
    case(function() -- Nothing else going wrong: the mod remounts by itself.
        local w=start();w.tilt_stop(59.7)
        for _=1,3000 do w.tick();if riding(w,1) then break end end
        check(riding(w,1),"a plain fall gets back on the bike")
    end)
    return {cases=cases,assertions=n,native_authority=false,constructed=true}
end
return T

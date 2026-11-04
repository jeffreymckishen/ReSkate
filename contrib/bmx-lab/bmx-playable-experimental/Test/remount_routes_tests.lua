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
    case(function() -- Nothing else going wrong: the mod remounts by itself.
        local w=start();w.tilt_stop(59.7)
        for _=1,3000 do w.tick();if riding(w,1) then break end end
        check(riding(w,1),"a plain fall gets back on the bike")
    end)
    return {cases=cases,assertions=n,native_authority=false,constructed=true}
end
return T

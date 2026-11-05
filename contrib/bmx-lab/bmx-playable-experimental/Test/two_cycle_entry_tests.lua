-- Constructed entry tests with the real pinned survey mathematics. No Host,
-- native physics, game, input injection or admission is exercised by this suite.
local Entry=require("./bmx_playable_entry")
local Survey=require("./ride_r1_record")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn) cases+=1;local ok,why=pcall(fn);assert(ok,name..": "..tostring(why)) end
    local function copy(v) if type(v)~="table" then return v end;local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out end
    local function cleaned()
        return {phase="done",bike_cleanup_complete=true,bike_authority=false,cleanup_pending=false,
            cleanup_unknown=false,stock_toggle_blocked=false,unloaded=false,stop_latched=true}
    end
    local function fixture(options)
        options=options or {}
        local f={now=0,slot=0,focused=true,gameplay=true,overlay=true,game_menu=false,stock=504,
            position=vector.create(0,.5,0),heading=0,slope=0,airborne=false,new_calls=0,steps=0,mounts=0,stops=0,toggles=0,
            unloads=0,prepares=0,probes=0,probe_tick=0,probe_peak=0,events={},keys=options.keys or {},latest=cleaned()}
        f.latest.phase="idle";f.latest.stop_latched=false
        local R={time={},input={},menu={},skater={},storage={},world={physics={}}}
        function R.time.now() return f.now end
        function R.input.focus()
            if f.on_focus then f.on_focus() end
            return {focused=f.focused,gameplay=f.gameplay,interface_open=f.overlay}
        end
        function R.input.gamepad()
            local pad={left_x=0,left_y=0,right_x=0,right_y=0,left_trigger=0,right_trigger=0,buttons={}}
            for _,name in {"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"} do
                pad.buttons[name]=false
            end
            if f.on_pad then return f.on_pad(pad) end
            return pad
        end
        function R.menu.game() if f.on_menu then f.on_menu() end;return {open=f.game_menu} end
        function R.skater.get()
            if f.on_actor then f.on_actor() end
            return {position=f.position,heading=f.heading,airborne=f.airborne}
        end
        function R.skater.telemetry()
            if f.on_telemetry then f.on_telemetry() end
            return {skater=true,airborne=f.airborne,teleport_pending=false,watch={valid=true,state=f.stock,ragdoll_known=true,ragdoll=f.ragdoll==true}}
        end
        function R.storage.keys() if f.keys_raise then error("keys unavailable") end;return f.keys end
        function R.world.physics.prepare()
            f.prepares+=1;f.events[#f.events+1]="prepare"
            if f.on_prepare then return f.on_prepare(f.prepares) end
            return true
        end
        function R.world.probe(from,to)
            f.probes+=1;f.probe_tick+=1;f.probe_peak=math.max(f.probe_peak,f.probe_tick)
            if f.on_probe then f.on_probe(from,to) end
            if from.y-to.y>1 then
                local y=math.tan(math.rad(f.slope))*from.x
                if f.rough and from.x>f.position.x then y+=.02 end
                return {status="hit",position=vector.create(from.x,y,from.z)}
            end
            if f.obstacle then return {status=f.obstacle,position=vector.create(to.x,to.y,to.z)} end
            return {status="clear"}
        end
        local owner={}
        function owner:status() if f.on_status then f.on_status() end;return copy(f.latest) end
        function owner:step(dt)
            f.steps+=1;f.events[#f.events+1]="step"
            if f.step_raise then error("constructed step failure") end
            if f.on_step then f.on_step(dt) end
            return copy(f.latest)
        end
        function owner:request_mount(slot)
            f.mounts+=1;f.events[#f.events+1]="mount";check(slot==0,"selected slot is preserved")
            if f.on_mount then return f.on_mount() end
            f.latest={phase="following",bike_cleanup_complete=false,bike_authority=true,cleanup_pending=false,
                cleanup_unknown=false,stock_toggle_blocked=true,unloaded=false,stop_latched=false}
            return true
        end
        function owner:request_stop(why)
            f.stops+=1;f.events[#f.events+1]="stop";check(type(why)=="string","stop reason remains explicit")
            f.latest={phase="cleanup",bike_cleanup_complete=false,bike_authority=true,cleanup_pending=true,
                cleanup_unknown=false,stock_toggle_blocked=true,unloaded=false,stop_latched=true}
            if f.on_stop then f.on_stop() end
            return true
        end
        function owner:request_stock_toggle(slot)
            f.toggles+=1;f.events[#f.events+1]="stock";check(slot==0,"stock transaction uses selected slot")
            if f.on_stock then return f.on_stock() end
            f.latest=cleaned();f.latest.stock_toggle_blocked=true;f.latest.cleanup_pending=true
            return true
        end
        function owner:unload()
            f.unloads+=1;f.events[#f.events+1]="unload"
            if f.on_unload then f.on_unload() end
            f.latest=cleaned();f.latest.unloaded=true;return copy(f.latest)
        end
        local Runtime={}
        function Runtime.new(services,config)
            f.new_calls+=1;check(services==R and config.qualification_only==true,"existing private lifecycle contract is preserved")
            return owner
        end
        local old_new=Runtime.new
        Runtime.new_experimental_two_cycle=function(services,config)
            f.experimental_factory=true
            return old_new(services,config)
        end
        function owner:can_prepare_next_mount()return not f.failed_cycle end
        function owner:prepare_next_mount(slot,admitted_at_ms)
            f.stepoffs=(f.stepoffs or 0)+1;f.events[#f.events+1]="prepare504"
            f.second_admitted_at=admitted_at_ms
            if f.on_prepare504 then return f.on_prepare504() end
            f.latest=cleaned();f.latest.phase="stock_switching";f.latest.cleanup_pending=true;f.latest.stock_toggle_blocked=true
            return true
        end
        function owner:next_mount_ready()
            if f.on_ready504 then return f.on_ready504() end
            return false,"pending"
        end
        function owner:playable_grade_policy()return options.playable and Survey.PLAYABLE_GRADE_POLICY or nil end
        -- As the runtime does: a later press than the current one, no later than now, within its own 60 s.
        function owner:renew_second_admission(admitted_at_ms,renewed_at_ms)
            f.renewals=(f.renewals or 0)+1
            if f.on_renew then return f.on_renew(admitted_at_ms,renewed_at_ms) end
            if admitted_at_ms~=f.second_admitted_at or renewed_at_ms<admitted_at_ms or renewed_at_ms>f.now
                or f.now-renewed_at_ms>=60000 then return false,"No second preparation to renew" end
            f.second_admitted_at=renewed_at_ms
            return true
        end
        function owner:second_preflight_ready(admitted_at_ms)
            f.preflight_proofs=(f.preflight_proofs or 0)+1
            if f.on_preflight_proof then return f.on_preflight_proof(admitted_at_ms) end
            -- The runtime's own window: a proof read with a Mount time 60 s old is refused (reuse6 in game).
            if f.now<admitted_at_ms or f.now-admitted_at_ms>=60000 then return false,"Second Mount admission expired" end
            if f.stepoffs~=1 or f.mounts~=1 or admitted_at_ms~=f.second_admitted_at or f.stock~=504 then
                return false,"No current unrequested second intent"
            end
            return self:next_mount_ready()
        end
        f.R=R;f.owner=owner
        f.entry=Entry.new(R,Runtime,Survey,{admitted=options.admitted~=false,slot=0,experimental_two_cycle=options.two==true,session_renewable=options.playable==true,auto_return=options.auto_return==true})
        function f.tick(count)
            for _=1,count or 1 do f.now+=16;f.probe_tick=0;f.entry:step(16) end
        end
        function f.await_stepoff()
            for _=1,80 do
                f.tick()
                local s=f.entry:status()
                if f.stepoffs or s.phase=="blocked" or s.cancelled or s.phase=="unloaded" then return end
            end
            error("bounded fixture did not reach step-off or refusal")
        end
        function f.await_mount()
            for _=1,200 do f.tick();if f.entry:status().mount_requested or f.entry:status().phase=="blocked" then return end end
            error("bounded fixture did not reach mount or refusal")
        end
        function f.riding()
            f.overlay=false;check(f.entry:mount(),"explicit mount intent accepted")
            f.await_mount();check(f.mounts==1,"exactly one lifecycle mount requested");f.tick()
            check(f.entry:status().phase=="riding","actual supplied following status drives visible riding phase")
        end
        return f
    end
    local function first_return(f)
        f.riding()
        check(f.entry:return_to_skateboard(),"explicit first Return accepted")
        f.latest=cleaned();f.stock=100;f.tick()
        check(f.entry:status().phase=="skateboard","first actual supplied100 closes Return")
    end
    local function await_terrain(f)
        for _=1,220 do
            f.tick();local s=f.entry:status()
            if s.phase=="preflight_refused" or s.phase=="blocked" or s.mount_requested then return s end
        end
        error("bounded constructed survey did not finish")
    end
    local function second_terrain(f)
        first_return(f);f.rough=true
        check(f.entry:mount(),"one original second intent")
        f.await_stepoff();check(f.stepoffs==1,"one consumed old-owner step-off")
        f.latest=cleaned();f.stock=504;f.on_ready504=function()return true,2 end
        f.tick();check(f.entry:status().phase=="preparing","NEW504 ACK precedes survey")
        local s=await_terrain(f)
        check(s.phase=="preflight_refused" and s.attempts_used==2 and f.mounts==1,
            "terrain-only second refusal retains charged intent before new native request")
        check(s.terrain_refusal_count==1 and s.terrain_refusals[1].residual_mm>3,
            "actual full constructed footprint is over unchanged3mm")
        return s
    end
    case("two-cycle completes two explicit cycles and spends third",function()
        local f=fixture({two=true});first_return(f)
        check(f.experimental_factory and f.new_calls==1,"one private manager, never a replacement Runtime.new")
        local before=f.probes
        check(f.entry:mount(),"second intent is accepted once")
        check(f.entry:status().attempts_used==2 and f.stepoffs==nil,"intent2 burned before the deferred old-owner504 request")
        f.await_stepoff();check(f.stepoffs==1,"released settled closed-menu dwell sends one old-owner504 request")
        f.tick(10);check(f.probes==before,"pending504 must never take a new survey")
        f.latest=cleaned();f.stock=504;f.on_ready504=function()return true,2 end
        f.tick();check(f.entry:status().phase=="preparing","only acknowledged504 begins preparation")
        f.await_mount();check(f.mounts==2 and f.probes>=before+1260,"second NEW full survey precedes fresh owner mount")
        f.tick();check(f.entry:status().phase=="riding","second supplied following status is visible")
        check(f.entry:return_to_skateboard(),"second explicit Return accepted")
        f.latest=cleaned();f.stock=100;f.tick()
        check(f.entry:status().phase=="skateboard" and f.entry:mount(),"third intent begins the next cycle")
        check(f.entry:status().attempts_used==3 and f.entry:status().attempt_limit==8,"a third mount; the cap stays until a create reports reuse")
        check(f.new_calls==1 and f.mounts==2,"fixed manager; the third mount follows its own step-off")
    end)
    case("second Mount chord cannot race the strict equipment baseline",function()
        local f=fixture({two=true});first_return(f)
        local held=true
        f.on_pad=function(pad)pad.buttons.lb=held;pad.buttons.a=held;return pad end
        local admitted=f.now
        check(f.entry:mount(),"second intent is spent while the actual Mount chord is held")
        f.tick(50)
        check(f.stepoffs==nil and f.entry:status().attempts_used==2,"held chord cannot arm an equipment baseline or refund intent")
        held=false;f.airborne=true;f.stock=200;f.tick(45)
        check(f.stepoffs==nil,"known transient airborne stock state cannot arm the baseline")
        f.airborne=false;f.stock=100;f.tick(20)
        check(f.stepoffs==nil,"fresh100 for less than600ms cannot arm")
        held=true;f.tick();held=false;f.tick(38)
        check(f.stepoffs==nil,"a renewed input edge resets the full dwell")
        f.tick();check(f.stepoffs==1 and f.second_admitted_at==admitted,"one admission preserves the original intent time after release and600ms")
        local probes=f.probes;f.stock=504;f.latest=cleaned();f.on_ready504=function()return false,"stale old ACK"end
        f.tick();check(f.entry:status().phase=="blocked" and f.stepoffs==1 and f.probes==probes,"actual504 cannot replace a newer qualified targetACK")
        check(not f.entry:mount(),"baseline failure cannot retry the spent intent")
        local expired=fixture({two=true});first_return(expired);expired.overlay=true
        check(expired.entry:mount(),"one second intent before bounded wait")
        expired.now+=60000;expired.tick()
        check(expired.stepoffs==nil and expired.entry:status().phase=="blocked","original60s expires even with menus open")
        local unknown=fixture({two=true});first_return(unknown)
        unknown.on_pad=function()return nil end
        check(unknown.entry:mount(),"one second intent before unreadable pad proof")
        unknown.tick();check(unknown.stepoffs==nil and unknown.entry:status().phase=="blocked","missing release evidence is never classified neutral")
    end)
    case("legacy Entry retains one-shot factory and behavior",function()
        local f=fixture();first_return(f)
        check(not f.experimental_factory and f.entry:status().attempt_limit==1,"default uses legacy Runtime.new")
        check(not f.entry:mount() and f.stepoffs==nil,"legacy Return cannot enable a second intent")
    end)
    case("archive/preparation refusal permanently burns attempt2",function()
        local f=fixture({two=true});first_return(f)
        f.on_prepare504=function()return false,"archive refused"end
        local before=f.probes
        check(f.entry:mount(),"intent is accepted before its deferred callback")
        f.await_stepoff()
        check(f.entry:status().attempts_used==1 and f.entry:status().phase=="blocked","deferred refusal stays visible and spends no mount")
        check(f.probes==before and f.mounts==1,"no hidden allocation or survey retry")
    end)
    case("old sampled504 cannot replace private newer equipment ACK",function()
        local f=fixture({two=true});first_return(f);check(f.entry:mount(),"intent2 accepted")
        f.await_stepoff();check(f.stepoffs==1,"old-owner504 request starts before readiness check")
        f.stock=504;f.latest=cleaned();f.on_ready504=function()return false,"stale old ACK"end
        local before=f.probes;f.tick()
        check(f.entry:status().phase=="blocked" and f.probes==before,"private proof refusal blocks survey despite504 sample")
    end)
    case("private ready504 but wrong sampled state is refused",function()
        local f=fixture({two=true});first_return(f);check(f.entry:mount(),"intent2 accepted")
        f.await_stepoff()
        f.latest=cleaned();f.stock=100;f.on_ready504=function()return true,2 end
        f.tick();check(f.entry:status().phase=="blocked" and f.mounts==1,"fresh state check prevents premature survey/mount")
    end)
    case("Cancel during second archive/preparation callback cannot restart",function()
        local f=fixture({two=true});first_return(f)
        f.on_prepare504=function()f.entry:cancel();return true end
        check(f.entry:mount(),"intent accepted before deferred callback")
        f.await_stepoff();check(f.stepoffs==1 and f.entry:status().cancelled,"reentrant Cancel invalidates deferred acceptance")
        f.tick(20);check(f.entry:status().cancelled and f.mounts==1,"no second body after cancellation")
    end)
    case("Cancel during acknowledged504 callback cannot start prepare",function()
        local f=fixture({two=true});first_return(f);check(f.entry:mount(),"intent2 accepted")
        f.await_stepoff()
        f.latest=cleaned();f.stock=504
        f.on_ready504=function()f.entry:cancel();return true,2 end
        local before=f.prepares;f.tick()
        check(f.entry:status().cancelled and f.prepares==before,"no prepare after readiness callback Cancel")
    end)
    case("unload during second preparation cannot start prepare",function()
        local f=fixture({two=true});first_return(f);check(f.entry:mount(),"intent2 accepted")
        f.await_stepoff()
        f.latest=cleaned();f.stock=504
        f.on_ready504=function()f.entry:unload();return true,2 end
        local before=f.prepares;f.tick();check(f.entry:status().phase=="unloaded" and f.prepares==before,"unload remains terminal")
    end)
    case("Return unavailable during step-off cannot send a second transaction",function()
        local f=fixture({two=true});first_return(f);check(f.entry:mount(),"intent2 accepted")
        local before=f.toggles;check(not f.entry:return_to_skateboard(),"old mount proof does not authorize Return during504 setup")
        check(f.toggles==before and f.stepoffs==nil,"no pulse from premature Return while deferred")
        f.await_stepoff();check(f.stepoffs==1,"only the released closed-menu dwell starts step-off")
    end)
    case("prior namespace blocks experimental factory acquisition",function()
        local f=fixture({two=true,keys={"old_marker"}})
        check(not f.entry:mount(),"reload cannot adopt old terminal namespace")
        f.tick(10);check(f.prepares==0 and f.mounts==0 and f.stepoffs==nil,"no native work on reload refusal")
    end)
    case("new survey expiry remains unchanged for second mount",function()
        local f=fixture({two=true});first_return(f);f.overlay=true
        check(f.entry:mount(),"intent2 accepted")
        f.overlay=false;f.await_stepoff();check(f.stepoffs==1,"released closed-menu dwell starts step-off");f.overlay=true
        f.latest=cleaned();f.stock=504;f.on_ready504=function()return true,2 end
        for _=1,200 do f.tick();if f.entry:status().phase=="awaiting_mount" then break end end
        check(f.entry:status().phase=="awaiting_mount","fresh second survey waits behind overlay")
        f.now+=45001;f.overlay=false;f.tick()
        check(f.entry:status().phase=="blocked" and f.mounts==1,"old45s TTL is never extended for remount")
    end)
    case("second survey movement failure remains terminal",function()
        local f=fixture({two=true});first_return(f);f.overlay=true
        check(f.entry:mount(),"intent2 accepted")
        f.overlay=false;f.await_stepoff();check(f.stepoffs==1,"released closed-menu dwell starts step-off");f.overlay=true
        f.latest=cleaned();f.stock=504;f.on_ready504=function()return true,2 end
        for _=1,200 do f.tick();if f.entry:status().phase=="awaiting_mount" then break end end
        f.position=vector.create(1,.5,0);f.overlay=false;f.tick()
        check(f.entry:status().phase=="blocked" and f.mounts==1,"fresh original movement guard is retained")
    end)
    case("failed first cycle cannot advertise or admit another attempt",function()
        local f=fixture({two=true});f.riding();f.failed_cycle=true
        check(f.entry:return_to_skateboard(),"explicit cleanup Return remains available")
        f.latest=cleaned();f.stock=100;f.tick()
        check(f.entry:status().phase=="spent" and not f.entry:mount(),"a cycle Core will not qualify refuses Mount and says so")
        check(f.stepoffs==nil and f.mounts==1,"no step-off or allocation before that cycle's own checks")
    end)    case("Root-approved narrower second Mount refuses already-onfoot504",function()
        local f=fixture({two=true});first_return(f);f.stock=504
        check(not f.entry:mount(),"second intent is not an optional manual504 rearm")
        check(f.entry:status().attempts_used==1 and f.entry:status().phase=="skateboard","the refused Mount spends nothing")
        check(f.stepoffs==nil and f.mounts==1 and not f.entry:mount(),"no archive/stock/body retry from already504")
    end)
    case("second Mount waits for both menus to close and sends once",function()
        local f=fixture({two=true});first_return(f);f.overlay=true
        local before=f.probes
        check(f.entry:mount(),"second intent armed in overlay")
        check(f.entry:status().attempts_used==2 and f.stepoffs==nil,"intent spent without menu callback pulse")
        check(not f.entry:mount(),"duplicate pending intent refused")
        f.tick(10);check(f.stepoffs==nil and f.probes==before,"overlay-open ticks send no step-off or survey")
        f.overlay=false;f.game_menu=true;f.tick(10)
        check(f.stepoffs==nil,"game menu also blocks step-off")
        f.game_menu=false;f.await_stepoff();check(f.stepoffs==1,"released closed-menu dwell sends exactly once")
        f.tick(10);check(f.stepoffs==1 and f.probes==before,"pending504 status cannot resend or survey")
        check(not f.entry:mount() and f.entry:status().attempts_used==2,"pending readiness never rearms intent")
    end)
    case("Cancel before closing menus suppresses deferred second request",function()
        local f=fixture({two=true});first_return(f);f.overlay=true
        check(f.entry:mount(),"second intent armed")
        f.entry:cancel();f.overlay=false;f.tick(10)
        check(f.entry:status().cancelled and f.stepoffs==nil and f.mounts==1,"cancel suppresses pending request permanently")
        check(not f.entry:mount() and f.entry:status().attempts_used==2,"cancel does not refund second intent")
    end)
    case("unload before closing menus suppresses deferred second request",function()
        local f=fixture({two=true});first_return(f);f.overlay=true
        check(f.entry:mount(),"second intent armed")
        f.entry:unload();f.overlay=false;f.tick(10)
        check(f.entry:status().phase=="unloaded" and f.stepoffs==nil and f.mounts==1,"unload suppresses pending request")
        check(not f.entry:mount() and f.entry:status().attempts_used==2,"unload leaves intent spent")
    end)
    case("lost old-owner cleanup proof while pending refuses without request",function()
        local f=fixture({two=true});first_return(f);f.overlay=true
        check(f.entry:mount(),"second intent armed")
        f.latest.cleanup_unknown=true;f.overlay=false;f.tick()
        check(f.entry:status().phase=="blocked" and f.stepoffs==nil,"fresh old-owner proof required on request tick")
        check(not f.entry:mount() and f.mounts==1,"proof failure is not a retry")
    end)
    case("changed stock100 while pending refuses without request",function()
        local f=fixture({two=true});first_return(f);f.overlay=true
        check(f.entry:mount(),"second intent armed")
        f.stock=504;f.overlay=false;f.tick()
        check(f.entry:status().phase=="blocked" and f.stepoffs==nil,"fresh100 still required after menus close")
        check(not f.entry:mount() and f.entry:status().attempts_used==1,"a step-off that never ran spends no mount")
    end)
    case("request callback reentry cannot resend deferred step-off",function()
        local f=fixture({two=true});first_return(f)
        f.on_prepare504=function()
            check(not f.entry:mount(),"reentrant Mount refused after intent burn")
            f.entry:step(16)
            return true
        end
        check(f.entry:mount(),"second intent armed")
        f.await_stepoff()
        check(f.stepoffs==1 and f.entry:status().cancelled and f.mounts==1,"reentrant tick cancels without duplicate request/body")
    end)
    case("Cancel during fresh menu proof suppresses deferred request",function()
        local f=fixture({two=true});first_return(f)
        check(f.entry:mount(),"second intent armed")
        f.on_focus=function()f.on_focus=nil;f.entry:cancel()end
        f.tick(10)
        check(f.entry:status().cancelled and f.stepoffs==nil,"cancel during environment read wins before owner callback")
    end)
    local function fall(f,issue)
        f.latest=cleaned();f.latest.phase="stopping";f.latest.bike_cleanup_complete=false
        f.latest.bike_authority=true;f.latest.cleanup_pending=true;f.latest.stock_toggle_blocked=true
        f.latest.stop_reason="subordinate requested stop"
        f.latest.ride={stop_requested=true,issue=issue}
        f.tick()
    end
    case("with auto_return a ride that stopped hands back without asking",function()
        local f=fixture({two=true,auto_return=true});f.riding()
        fall(f,"measured tilt 55.8 deg over the 55 deg Ride stop")
        check(f.entry:status().recovery_pending and f.stops==1,"a fall starts Recover on its own")
        local g=fixture({two=true,auto_return=true});g.riding()
        fall(g,"rider came off the bike")
        check(g.entry:status().recovery_pending and g.stops==1,"coming off the bike is a fall")
        local k=fixture({two=true,auto_return=true});k.riding()
        fall(k,"hit something at 7.5 m/s")
        check(k.entry:status().recovery_pending and k.stops==1,"a hit is a fall")
        local h=fixture({two=true,auto_return=true});h.riding()
        fall(h,"input source began cleanup")
        check(h.entry:status().return_requested and not h.entry:status().recovery_pending,"any other stop goes back to the board")
    end)
    case("explicit tilt recovery waits for clean Return and fresh504 survey",function()
        local f=fixture({two=true});f.riding()
        fall(f,"measured tilt 55.8 deg over the 55 deg Ride stop")
        check(f.entry:status().phase=="fallen" and f.entry:status().recovery_available,"known tilt is visible without restarting")
        check(f.toggles==0 and f.stops==0 and f.mounts==1,"fall observation alone sends no recovery command")
        check(f.entry:recover() and f.entry:status().recovery_pending,"one explicit Recover intent is accepted")
        check(not f.entry:recover() and f.stops==1,"repeated Recover never resends Return")
        f.tick(5);check(f.toggles==0 and f.mounts==1,"incomplete cleanup blocks stock input and a new mount")
        f.latest=cleaned();f.overlay=true;f.tick()
        check(f.toggles==0,"menu-open cleanup proof never sends stock input")
        f.overlay=false;f.tick();check(f.toggles==1 and f.mounts==1,"one existing stock transaction after clean proof")
        local probes=f.probes
        f.latest=cleaned();f.stock=100;f.tick()
        check(f.entry:status().phase=="stepping_off" and f.entry:status().attempts_used==2
            and not f.entry:status().recovery_pending and f.stepoffs==nil,"actual100 consumes the single fresh Mount intent before callbacks")
        f.await_stepoff();check(f.stepoffs==1 and f.probes==probes,"existing deferred504 request precedes all new survey work")
        f.latest=cleaned();f.stock=504;f.on_ready504=function()return true,2 end
        f.tick();f.await_mount();f.tick()
        check(f.mounts==2 and f.probes>=probes+1260 and f.entry:status().phase=="riding","fresh504 ACK and complete fresh survey precede mount two")
        check(f.new_calls==1 and f.entry:status().fall_reason==nil,"same bounded manager; fallen display clears only on actual following")
        fall(f,"measured tilt 56.0 deg over the 55 deg Ride stop")
        check(f.entry:status().recovery_available and f.entry:recover() and f.mounts==2,"a second fall recovers like the first, spending another mount")
    end)
    case("explicit recovery can wait for known300 within its original stop window",function()
        local function pending_fall()
            local f=fixture({two=true});f.riding()
            fall(f,"measured tilt 55.8 deg over the 55 deg Ride stop")
            local stop=f.now
            check(f.entry:recover(),"one explicit Recover starts existing stop/Return")
            f.latest=cleaned();f.latest.stop_ms=stop;f.latest.stock_requested=false
            f.latest.initial_readiness={level="constructed",wipeouts=0}
            f.stock=300;f.level="constructed";f.ragdoll_known=true
            f.R.level={current=function()return{name=f.level}end}
            function f.R.skater.telemetry()
                return{skater=true,airborne=false,teleport_pending=false,
                    watch={valid=true,state=f.stock,ragdoll_known=f.ragdoll_known,ragdoll=f.stock==300,wipeouts=0}}
            end
            return f
        end
        local f=pending_fall();f.tick(5)
        check(f.entry:status().phase=="returning" and f.entry:status().recovery_pending
            and f.toggles==0 and f.mounts==1,"known300 waits after full cleanup without stock input or allocation")
        f.stock=504;f.tick()
        check(f.toggles==1 and f.mounts==1,"actual grounded504 permits exactly the existing stock transaction")
        f.latest=cleaned();f.stock=100
        f.latest.equipment={phase="done",outcome="target_observed",initial_state=504,expected_state=100,
            retained=false,acknowledged=true,qualified_transition=true,current_transition=true,unloaded=false,storage_fault=false,
            terminal_receipt={terminal=true,claim_released=true,report_debt=false,quarantined=false}}
        f.tick();f.await_stepoff()
        check(f.stepoffs==1 and f.entry:status().attempts_used==2,"supplied clean stock100ACK precedes one remaining explicit recovery handoff")
        f.latest=cleaned();f.stock=504;f.on_ready504=function()return true,2 end
        f.tick();f.await_mount();f.tick()
        check(f.mounts==2 and f.entry:status().phase=="riding","fresh504ACK and full survey still precede the new mounted session")
        -- A rider still down past stop+20 s used to end the recovery for good here. The ordinary Return now waits
        -- for them, still with no stock input, and switches once they stand.
        local expired=pending_fall();expired.tick();expired.now+=20000;expired.tick(5)
        check(expired.entry:status().phase=="returning" and expired.entry:status().recovery_pending
            and expired.toggles==0 and expired.mounts==1,"known300 past stop+20s waits on, with no stock input")
        expired.stock=504;expired.tick()
        check(expired.toggles==1 and expired.mounts==1,"standing up after it permits exactly the existing stock transaction")
        local unknown=pending_fall();unknown.ragdoll_known=false;unknown.tick()
        check(unknown.entry:status().phase=="blocked" and unknown.toggles==0,"unknown ragdoll context is never treated as a recoverable wait")
        local missing=pending_fall();missing.latest.stop_ms=nil;missing.tick()
        check(missing.entry:status().phase=="blocked" and missing.toggles==0,"missing original stop time cannot create a new recovery deadline")
        local changed=pending_fall();changed.tick();changed.level="other";changed.tick()
        check(changed.entry:status().phase=="blocked" and changed.toggles==0,"fresh level mismatch ends waiting before any stock request")
        -- A knock-down reaches this wait with the rider in any state. One it cannot read, or a rider ragdolled on foot
        -- after a known300, is left to the ordinary Return to wait for; both used to end the recovery for good.
        local odd=pending_fall();odd.stock=0;odd.tick(5)
        check(odd.entry:status().phase=="returning" and odd.entry:status().recovery_pending and odd.toggles==0,
            "a state the wait cannot read waits on, with no stock input")
        local rag=pending_fall();rag.tick();rag.stock=504
        function rag.R.skater.telemetry()
            return {skater=true,airborne=false,teleport_pending=false,
                watch={valid=true,state=504,ragdoll_known=true,ragdoll=true,wipeouts=0}}
        end
        rag.on_stock=function() return false,"Stock request refused by fresh readiness or cancelled intent." end
        rag.tick(5)
        check(rag.entry:status().phase=="returning" and rag.entry:status().recovery_pending and rag.toggles==1,
            "ragdolled on foot after a known300, Core is asked and refuses, and the Return waits")
    end)
    case("roll fall can recover after a separately completed Return",function()
        local f=fixture({two=true});f.riding()
        fall(f,"measured roll rate 8.25 rad/s over the 8 rad/s Ride stop")
        check(f.entry:status().phase=="fallen" and f.entry:return_to_skateboard(),"existing measured roll diagnostic enables the same guarded flow")
        f.latest=cleaned();f.stock=100;f.tick()
        check(f.entry:status().phase=="skateboard" and f.mounts==1,"Return alone never requests a fresh Mount")
        check(f.entry:recover() and f.stops==1,"Recover after Return does not repeat the stock transaction or Stop")
        f.tick();check(f.entry:status().attempts_used==2 and f.stepoffs==nil,"next tick consumes one ordinary second Mount intent")
    end)
    case("closed nonfall and unknown cleanup cannot recover",function()
        local closed=fixture({two=true,admitted=false})
        check(not closed.entry:recover(),"closed admission never gains a recovery intent")
        for _,issue in {"selected riding pad unavailable or malformed","native command outcome unknown","measured tilt unavailable"} do
            local f=fixture({two=true});f.riding();fall(f,issue)
            check(f.entry:status().phase=="stopped" and not f.entry:recover(),"arbitrary Source/native/measurement faults are not fall recovery")
            f.tick(5);check(f.toggles==0 and f.mounts==1,"fault classification never sends stock or remount commands")
        end
        local f=fixture({two=true});f.riding();fall(f,"measured tilt 55.8 deg over the 55 deg Ride stop")
        check(f.entry:recover(),"known first fall intent starts once")
        f.latest.cleanup_unknown=true;f.tick(5)
        check(f.entry:status().recovery_pending and f.toggles==0 and f.mounts==1,
            "unknown cleanup holds the queued intent without any stock or Mount")
    end)
    case("recovery Cancel unload and successor failure never replay",function()
        for _,operation in {"cancel","unload"} do
            local f=fixture({two=true});f.riding();fall(f,"measured tilt 55.8 deg over the 55 deg Ride stop")
            check(f.entry:recover(),"one recover intent before explicit cancellation")
            f.entry[operation](f.entry);f.latest=cleaned();f.stock=100;f.tick(5)
            check(not f.entry:status().recovery_pending and f.mounts==1 and f.stepoffs==nil,"cancel/unload clears pending recovery before later clean status")
        end
        local f=fixture({two=true});f.riding();fall(f,"measured tilt 55.8 deg over the 55 deg Ride stop")
        check(f.entry:recover(),"one recover before successor proof")
        f.latest=cleaned();f.stock=100;f.failed_cycle=true;f.tick(5)
        check(f.entry:status().phase=="spent" and not f.entry:status().recovery_pending and f.mounts==1,"failed successor proof clears intent and never mounts")
        local g=fixture({two=true});g.riding();fall(g,"measured tilt 55.8 deg over the 55 deg Ride stop")
        check(g.entry:recover(),"one recover before equipment refusal")
        g.latest=cleaned();g.on_stock=function()return false,"constructed stock refusal" end;g.tick(5)
        check(g.entry:status().phase=="returning" and g.entry:status().recovery_pending
            and g.toggles==1 and g.mounts==1,"stock refusal waits to ask again and is not converted into a Mount")
    end)
    case("second terrain retry keeps intent and step-off then repeats full survey",function()
        local f=fixture({two=true,playable=true});second_terrain(f)
        local probes,prepares=f.probes,f.prepares
        local held=true;f.on_pad=function(p) p.buttons.lb=held;p.buttons.a=held;return p end
        f.rough=false;f.position=vector.create(4,.5,0)
        local admitted=f.now
        check(f.entry:mount(),"explicit terrain retry accepted on existing second intent")
        check(f.renewals==1 and f.second_admitted_at==admitted,"the retry press is the intent's new Mount time")
        f.tick(45)
        check(f.probes==probes and f.prepares==prepares and f.mounts==1 and f.stepoffs==1,
            "held retry chord delays all preparation and never repeats Y")
        held=false;f.tick(38)
        check(f.probes==probes and f.mounts==1,"less than600ms neutral cannot start a new survey")
        f.await_mount()
        check(f.mounts==2 and f.stepoffs==1 and f.new_calls==1 and f.second_admitted_at==admitted,
            "one fresh owner request after the retry press, no replacement manager or step-off")
        local counts=Survey.survey_counts()
        check(counts.floor==180 and counts.obstacle==1080 and counts.obstacle_ticks==35
            and counts.probes==1295 and Survey.SURVEY_RAYS_PER_TICK==32,
            "unchanged180floor+1080obstacle+35check rays and32ray per-tick policy")
        check(f.probes-probes==counts.probes,
            string.format("fresh complete survey probe count: got%d expected%d",f.probes-probes,counts.probes))
        check(f.probe_peak<=Survey.SURVEY_RAYS_PER_TICK,
            string.format("original per-tick probe budget: got%d limit%d",f.probe_peak,Survey.SURVEY_RAYS_PER_TICK))
        check(f.entry:status().attempts_used==2 and f.entry:status().terrain_refusal_count==1,
            "attempt and retained numeric history never refunded")
        check(not f.entry:mount(),"a native request permanently closes this retry seam")
    end)
    case("second terrain proof loss is sticky and never repeats native work",function()
        for _,kind in {"cleanup","ack","missingproof","state","pad"} do
            local f=fixture({two=true,playable=true});second_terrain(f)
            local probes,prepares=f.probes,f.prepares;f.rough=false
            if kind=="cleanup" then f.latest.cleanup_unknown=true
            elseif kind=="ack" then f.on_preflight_proof=function()return false,"newACK lost" end
            elseif kind=="missingproof" then f.owner.second_preflight_ready=nil
            elseif kind=="state" then f.stock=100
            else f.on_pad=function()return nil end end
            local accepted=f.entry:mount()
            if kind=="state" then check(accepted and f.entry:status().phase=="stepping_off","back on the board, this Mount starts a new cycle")
            elseif kind=="pad" then check(accepted,"pending retry before malformed new pad read");f.tick()
            else check(not accepted,"exact prior proof required before retry") end
            -- Back on the board with a clean ride, Mount starts a whole new cycle rather than a terrain retry.
            if kind~="state" then
            check(f.entry:status().phase=="blocked" and not f.entry:mount(),"proof loss cannot become another terrain retry")
            check(f.mounts==1 and f.stepoffs==1 and f.probes==probes and f.prepares==prepares,
                "no body request, Y or survey after unknown proof")
            end
        end
    end)
    case("each terrain retry press arms its own 60 seconds, and nothing else does",function()
        -- reuse6 in game: the third press came 74 s after the step-off and blocked the rest of the launch.
        local f=fixture({two=true,playable=true});second_terrain(f);f.rough=false
        local original=f.second_admitted_at
        f.now=original+74000
        check(f.entry:mount(),"a retry long after the step-off's press is still a retry")
        check(f.second_admitted_at==original+74000 and f.entry:status().phase=="preparing","the press renews the Mount time")
        f.await_mount()
        check(f.mounts==2 and f.stepoffs==1 and f.new_calls==1,"the retry mounts with no second step-off or manager")
        local g=fixture({two=true,playable=true});second_terrain(g);g.rough=false
        g.now=g.second_admitted_at+30000
        local pressed=g.now;check(g.entry:mount(),"one pending terrain retry")
        g.on_pad=function(p)p.buttons.a=true;return p end;g.tick(4)
        check(g.entry:status().phase=="preparing","held controls keep the retry preparing")
        g.now=pressed+50000
        check(not g.entry:mount() and g.renewals==1 and g.second_admitted_at==pressed,
            "a Mount press while the retry prepares renews nothing")
        g.now=pressed+60000;g.tick()
        check(g.entry:status().phase=="blocked" and g.second_admitted_at==pressed and g.mounts==1 and g.stepoffs==1,
            "held controls cannot turn retry time into a fresh arm window")
        local h=fixture({two=true,playable=true});second_terrain(h)
        local probes,prepares=h.probes,h.prepares
        h.on_renew=function()return false,"constructed renewal refusal" end
        check(not h.entry:mount() and h.entry:status().phase=="blocked","a refused renewal is no retry")
        check(h.mounts==1 and h.stepoffs==1 and h.probes==probes and h.prepares==prepares,"refusal admits no native or survey work")
        -- Two slow retries in a row: the second renews from its own press, not the first retry's.
        local i=fixture({two=true,playable=true});second_terrain(i)
        local first=i.second_admitted_at
        i.now=first+50000
        check(i.entry:mount() and i.renewals==1 and i.second_admitted_at==first+50000,"a first slow retry renews")
        local s=await_terrain(i)
        check(s.phase=="preflight_refused" and s.terrain_refusal_count==2,"its survey refuses the ground again")
        i.rough=false;i.now=first+115000
        check(i.entry:mount(),"a second retry 65 s after the first is still a retry: "..tostring(i.entry:status().detail))
        check(i.renewals==2 and i.second_admitted_at==first+115000 and i.entry:status().phase=="preparing",
            "the second retry renews from its own press")
        i.await_mount()
        check(i.mounts==2 and i.stepoffs==1 and i.new_calls==1,"the second retry mounts with no new step-off")
    end)
    case("eight terrain refusals of one Mount intent never allocate or evict",function()
        local f=fixture({two=true,playable=true});second_terrain(f)
        for count=2,8 do
            check(f.entry:mount(),"explicit bounded terrain retry")
            local s=await_terrain(f)
            check(s.terrain_refusal_count==count,"same existing refusal history appends")
            check(f.mounts==1 and f.stepoffs==1 and f.new_calls==1,"terrain refusals cannot create new owners or repeat stock")
        end
        local s=f.entry:status()
        check(s.phase=="blocked" and #s.terrain_refusals==8 and s.terrain_refusals[1].index==1,
            "eighth refusal of one intent is final without dropping the first")
        check(not f.entry:mount(),"no ninth terrain attempt in that intent")
    end)
    case("terrain refusals of separate Mount intents do not add up",function()
        local f=fixture({two=true,playable=true});first_return(f)
        f.on_preflight_proof=function(at) return at==f.second_admitted_at and f.stock==504,2 end
        -- Each later intent steps off, then refuses `refusals` times before clear ground mounts: nine in the launch.
        for intent,refusals in ipairs({5,4}) do
            f.rough=true;check(f.entry:mount(),"intent "..(intent+1).." accepted")
            local stepoffs=f.stepoffs or 0
            for _=1,80 do f.tick();if f.stepoffs and f.stepoffs>stepoffs then break end end
            check(f.stepoffs==stepoffs+1,"intent "..(intent+1).." steps off once")
            f.latest=cleaned();f.stock=504;f.on_ready504=function()return true,2 end;f.tick()
            for count=1,refusals do
                local s=await_terrain(f)
                check(s.phase=="preflight_refused" and s.terrain_refusal_count==count,
                    "refusal "..count.." of intent "..(intent+1).." is a retry: "..tostring(s.detail))
                if count<refusals then check(f.entry:mount(),"terrain retry") end
            end
            f.rough=false;check(f.entry:mount(),"retry on clear ground")
            f.await_mount();f.tick()
            check(f.mounts==intent+1 and f.entry:status().phase=="riding","intent "..(intent+1).." mounts")
            check(f.entry:return_to_skateboard(),"Return");f.latest=cleaned();f.stock=100;f.tick()
            check(f.entry:status().phase=="skateboard","back on the board")
        end
    end)
    case("second obstacle or native refusal never gains terrain retry",function()
        local f=fixture({two=true,playable=true});first_return(f)
        check(f.entry:mount(),"second intent before unknown obstacle result");f.await_stepoff()
        f.latest=cleaned();f.stock=504;f.on_ready504=function()return true,2 end;f.obstacle="unavailable"
        local s=await_terrain(f)
        check(s.phase=="preflight_refused" and s.terrain_refusal_count==1,"an obstacle is somewhere to move away from")
        check(f.mounts==1 and f.stepoffs==1,"unknown query never sends new allocation or Y")
        local g=fixture({two=true,playable=true});second_terrain(g);g.rough=false
        g.on_mount=function()return false,"constructed native refusal" end
        check(g.entry:mount(),"one resurvey intent before native refusal")
        g.await_mount();g.tick()
        check(g.entry:status().phase=="blocked" and g.mounts==2 and g.stepoffs==1 and not g.entry:mount(),
            "native-request refusal stays spent even after successful terrain retry")
    end)
    case("terrain proof callback cancellation keeps its terminal phase",function()
        for _,operation in {"cancel","unload"} do
            local f=fixture({two=true,playable=true});second_terrain(f);f.rough=false
            check(f.entry:mount(),"one terrain retry before later proof callback cancellation")
            local stopped=f.stops
            f.on_preflight_proof=function()
                f.entry[operation](f.entry)
                return false,"cancelled during private proof"
            end
            for _=1,80 do
                f.tick();local phase=f.entry:status().phase
                if phase=="cancelled" or phase=="unloaded" or phase=="blocked" then break end
            end
            check(f.entry:status().phase==(operation=="cancel" and "cancelled" or "unloaded"),
                "reentrant cancellation is checked before a false proof can replace its phase")
            check(f.stops==stopped+(operation=="cancel" and 1 or 0),"no extra stop callback after cancelled/unloaded proof")
            check(f.mounts==1 and f.stepoffs==1 and not f.entry:mount(),"no allocation/Y or retry after cancellation")
        end
    end)
    -- An explicit Return measures where to put the rider once the switch is done. In the user's log of 2026-11-02
    -- the SDK revoked (19:31:56) or expired (19:33:11) that switch's Y in warmup while the controller was held, so
    -- no Y reached the game, and the Return stopped at once where one without a placement would press again.
    local function measured_return(f)
        f.placements=0
        function f.R.input.allowed() return true end
        f.R.level={current=function() return {name="constructed"} end}
        function f.R.skater.telemetry()
            return {skater=true,airborne=false,teleport_pending=false,
                watch={valid=true,state=f.stock,ragdoll_known=true,ragdoll=false,wipeouts=0}}
        end
        function f.R.skater.teleport() f.placements+=1;return true end
        function f.owner:request_return()
            self:request_stop("explicit return to skateboard")
            return true,table.freeze({schema="measured_return_position_v1",ground=table.freeze({0,0,0}),
                actor_floor_clearance_m=.5,heading=0,level="constructed",wipeouts=0,stop_ms=f.now,expires_ms=f.now+20000})
        end
        check(f.entry:return_to_skateboard() and f.entry:status().return_position~=nil,"an explicit Return carries its placement")
        f.latest=cleaned();f.tick()
        check(f.toggles==1 and f.entry:status().stock_attempted,"finished cleanup arms one stock switch")
    end
    -- The switch's transaction as the lifecycle reports it once it is over; by default one whose Y never published.
    local function switch_ended(f,change)
        f.latest=cleaned()
        f.latest.equipment={phase="done",outcome="failed",reason="no_confirmed_report_pair",attempt=f.toggles,
            initial_state=504,expected_state=100,retained=false,acknowledged=true,qualified_transition=false,
            current_transition=false,unloaded=false,storage_fault=false,
            terminal_receipt={terminal=true,claim_released=true,report_debt=false,quarantined=false}}
        if change then change(f.latest.equipment) end
        f.tick()
    end
    case("an explicit Return whose stock press sends no Y presses again and reaches the skateboard",function()
        local f=fixture({two=true});f.riding();measured_return(f)
        local held=true
        f.on_pad=function(pad) pad.buttons.rb=held;return pad end
        switch_ended(f)
        local s=f.entry:status()
        check(s.phase=="returning" and s.return_requested and not s.stock_attempted and s.return_position==nil,
            "the Return goes on without its placement instead of stopping")
        f.tick(20);check(f.toggles==1 and f.entry:status().phase=="returning","the next press waits for the controls to be let go")
        held=false;f.tick();check(f.toggles==2,"let go, the switch is armed once more")
        f.latest=cleaned();f.stock=100;f.tick()
        check(f.entry:status().phase=="skateboard" and f.placements==0 and f.toggles==2,
            "the second press reaches the skateboard where the rider stands, with nothing placed")
        -- Pressing again keeps the bound every Return has: four more goes, then it stops.
        local g=fixture({two=true});g.riding();measured_return(g)
        for _=1,5 do switch_ended(g);g.tick() end
        check(g.toggles==5 and g.entry:status().phase=="blocked"
            and g.entry:status().detail:find("without an observed skateboard",1,true),"five presses that all fail end the Return")
        -- A switch that still holds its claim, is unresolved, faulted storage, or matched its target without the
        -- ACK keeps the existing refusal, and so does one after the rider has been placed.
        for _,change in {function(e) e.retained=true end,function(e) e.outcome="unresolved" end,
            function(e) e.storage_fault=true end,function(e) e.outcome="target_observed";e.acknowledged=false end} do
            local h=fixture({two=true});h.riding();measured_return(h);switch_ended(h,change)
            check(h.entry:status().phase=="blocked" and h.toggles==1 and h.placements==0,"the placement guard still refuses")
        end
        local p=fixture({two=true});p.riding();measured_return(p);p.stock=100
        switch_ended(p,function(e)
            e.outcome="target_observed";e.qualified_transition=true;e.current_transition=true
        end)
        check(p.placements==1 and p.entry:status().return_position.attempted,"a matched switch places the rider once")
        switch_ended(p);check(p.entry:status().phase=="blocked" and p.placements==1 and p.toggles==1,
            "once placed, a later failed report never drops the placement or presses again")
    end)
    case("a switch that matches its target too late to place the rider still reaches the skateboard",function()
        -- One queued placement needs 5.1 s of the 20 s after the stop. A Y that waited for a held controller, or for
        -- the game to be in front, can match its target with less left. Nothing has been placed then, and the rider
        -- is on the board, so the Return finishes there instead of stopping.
        local function matched(e) e.outcome="target_observed";e.qualified_transition=true;e.current_transition=true end
        for _,left in {5100,2000,0,-3000} do
            local f=fixture({two=true});f.riding();local stop=f.now;measured_return(f);f.stock=100
            f.now=stop+20000-left-16;switch_ended(f,matched)
            local s=f.entry:status()
            check(s.phase=="skateboard" and f.placements==0 and f.toggles==1 and s.return_position==nil,
                left.." ms of the window left ends on the board with nothing placed: "..tostring(s.detail))
        end
        -- 16 ms more than one placement needs still places the rider, as before.
        local g=fixture({two=true});g.riding();local stop=g.now;measured_return(g);g.stock=100
        g.now=stop+20000-5116-16;switch_ended(g,matched)
        check(g.placements==1 and g.entry:status().return_position.attempted,"a placement that fits is still made")
        g.tick(30);check(g.entry:status().phase=="skateboard" and g.entry:status().return_position.observed,"and seen there")
        -- The window can also close during the reads before the placement, after its first clock read passed.
        local r=fixture({two=true});r.riding();stop=r.now;measured_return(r);r.stock=100
        local read,lag=r.R.skater.telemetry,nil
        function r.R.skater.telemetry() if lag then r.now+=lag;lag=nil end;return read() end
        r.now=stop+20000-5300-16;lag=300;switch_ended(r,matched)
        check(r.entry:status().phase=="skateboard" and r.placements==0 and r.now==stop+20000-5000,
            "a window that closes during the reads places nothing and ends on the board")
        -- Once the rider has been placed the window still holds: a placement not seen in time stops the Return.
        local h=fixture({two=true});h.riding();stop=h.now;measured_return(h);h.stock=100
        h.position=vector.create(3,.5,0)
        h.now=stop+20000-6000-16;switch_ended(h,matched)
        check(h.placements==1 and h.entry:status().phase=="returning","placed with time to spare, not yet seen there")
        h.now=stop+20000-16;h.tick()
        check(h.entry:status().phase=="blocked" and h.placements==1 and h.toggles==1,
            "a placement the window ran out on still stops the Return")
    end)
    case("time out of the game does not run out a Return waiting to press the switch",function()
        -- The user's log of 2026-11-02: a ride ended by focus loss at 19:33:32 went back on its own, and that Return
        -- gave up at 19:34:17, its 45 s spent in another window, a second before the game was in front again.
        local f=fixture({two=true,auto_return=true});f.riding()
        f.focused=false;fall(f,"fresh sampled upright/focus/context/fall readiness lost")
        check(f.entry:status().return_requested and f.stops==1,"the stopped ride goes back to the board on its own")
        f.latest=cleaned()
        for _=1,60 do f.now+=984;f.tick() end
        check(f.entry:status().phase=="returning" and f.toggles==0,"a minute in another window sends nothing and does not give up")
        f.focused=true;f.game_menu=true
        for _=1,60 do f.now+=984;f.tick() end
        check(f.entry:status().phase=="returning" and f.toggles==0,"nor does a minute in the pause menu")
        -- The Insert overlay, focused and with the pause menu closed, at a pace the 250 ms gap cap leaves whole:
        -- 48 s that would all count if the overlay were not a time out of the game.
        f.game_menu=false;f.overlay=true
        for _=1,240 do f.now+=184;f.tick() end
        check(f.entry:status().phase=="returning" and f.toggles==0,"nor do 48 s with the Insert overlay open")
        f.overlay=false;f.tick()
        check(f.toggles==1,"back in the game the switch is armed")
        f.latest=cleaned();f.stock=100;f.tick()
        check(f.entry:status().phase=="skateboard","and the Return reaches the skateboard")
        -- Nor does a stretch with no ticks at all, as when the game stops ticking out of focus.
        local h=fixture({two=true});h.riding();h.on_stock=function() return false,"constructed refusal" end
        check(h.entry:return_to_skateboard(),"Return accepted")
        h.latest=cleaned();h.tick();h.now+=60000;h.tick()
        check(h.entry:status().phase=="returning","a minute between two ticks counts as one short tick")
        -- Time in the game still counts: a switch refused every time stops after the same 45 s.
        local g=fixture({two=true});g.riding();g.on_stock=function() return false,"constructed refusal" end
        check(g.entry:return_to_skateboard(),"Return accepted")
        g.latest=cleaned();g.tick()
        for _=1,224 do g.now+=184;g.tick() end
        check(g.entry:status().phase=="returning" and g.toggles>=40,"44.8 s in the game, asking all along, is inside the limit")
        g.now+=184;g.tick()
        check(g.entry:status().phase=="blocked" and g.entry:status().detail:find("Return did not finish",1,true),
            "45 s in the game ends it")
    end)
    -- Core's answer to a stock request while the rider is down (bike_runtime_core.lua request_stock_toggle).
    local DOWN="Stock request refused by fresh readiness or cancelled intent."
    local function refused_while_down(f)
        f.on_stock=function()
            if f.ragdoll then return false,DOWN end
            f.latest=cleaned();f.latest.stock_toggle_blocked=true;f.latest.cleanup_pending=true
            return true
        end
    end
    case("a knock-down mid-ride is a fall; the readiness text is still a plain Return",function()
        local f=fixture({two=true,auto_return=true});f.riding()
        fall(f,"rider was knocked down")
        local s=f.entry:status()
        check(s.fall_reason=="rider was knocked down" and s.recovery_pending and s.return_requested and f.stops==1,
            "a knock-down starts Recover on its own")
        local g=fixture({two=true,auto_return=true});g.riding()
        g.focused=false;fall(g,"fresh sampled upright/focus/context/fall readiness lost")
        s=g.entry:status()
        check(s.return_requested and not s.recovery_pending and s.fall_reason==nil,
            "the readiness text, as losing focus gives, goes back to the board")
    end)
    case("a rider kept down after a crash is returned once they stand, not stopped at 45 s",function()
        -- loop3 (2026-11-04): the rider lay beside an SUV, Core refused every switch, and after 45 s the Return gave up for good.
        local f=fixture({two=true,auto_return=true});f.riding()
        fall(f,"hit something at 4.5 m/s")
        f.latest=cleaned();f.ragdoll=true;refused_while_down(f)
        for _=1,400 do f.now+=184;f.tick() end
        local s=f.entry:status()
        check(s.phase=="returning" and s.recovery_pending and f.toggles>=100,
            "80 s down, asked every 500 ms or so all along, is still a Return: "..tostring(s.phase).." "..tostring(f.toggles))
        check(f.entry:help_line()=="Press A to get up.","while down the HUD says so")
        local asked=f.toggles
        f.ragdoll=false;f.now+=500;f.tick()
        check(f.toggles==asked+1 and f.entry:status().stock_attempted,"once they stand the next ask arms the switch")
        check(f.entry:help_line()=="Going back to the skateboard: let go of the controls.","and the HUD goes back to its usual line")
        f.latest=cleaned();f.stock=100;f.tick()
        s=f.entry:status()
        check(s.phase=="stepping_off" and s.attempts_used==2,"the switch reaches the board and the remount starts")
        -- A refusal for anything else is not a rider who is down: its line stays, and the 45 s still run (case above).
        local g=fixture({two=true,auto_return=true});g.riding();fall(g,"hit something at 4.5 m/s")
        g.latest=cleaned();g.on_stock=function() return false,"constructed refusal" end
        g.now+=5000;g.tick(3)
        check(g.entry:help_line()=="Going back to the skateboard: let go of the controls.","another refusal keeps the usual line")
        -- The hard cap still ends a Return that never finishes.
        local h=fixture({two=true,auto_return=true});h.riding();fall(h,"hit something at 4.5 m/s")
        h.latest=cleaned();h.ragdoll=true;refused_while_down(h)
        local from=h.now
        for _=1,1000 do h.now+=184;h.tick();if h.entry:status().phase=="blocked" then break end end
        s=h.entry:status()
        check(s.phase=="blocked" and s.detail:find("Return did not finish",1,true) and h.now-from>=179000 and h.now-from<=181000,
            "three minutes down ends it: "..tostring(h.now-from).." ms")
        -- loop5 (2026-11-04): a rider still lying there once the mod stops waiting is told to get up, not to find a board.
        h.tick(16)
        check(h.entry:help_line()=="Press A to get up.","a blocked rider still down is told to get up: "..tostring(h.entry:help_line()))
        h.ragdoll=false;h.tick(16)
        check(h.entry:help_line()~="Press A to get up." and h.entry:status().phase=="blocked","standing, the blocked line comes back")
        -- Only a ragdoll is a rider who is down. In the air, or back on the board and skating, nothing is said.
        h.airborne=true;h.tick(16)
        check(h.entry:help_line()~="Press A to get up.","a rider in the air is not told to get up")
        local k=fixture({two=true});first_return(k);k.ragdoll=true;k.tick(32)
        check(k.entry:status().phase=="skateboard" and k.entry:help_line()~="Press A to get up.","a bail on the skateboard is the game's: "..tostring(k.entry:help_line()))
    end)
    case("a rider who stands up holding a control is asked to let go, and the 45 s run",function()
        -- No switch is asked for while a control is held, so Core's last answer, given while the rider was down, said
        -- nothing about a rider who had stood since. Until 2026-11-04 that answer kept the HUD on 'Waiting for the rider
        -- to get up.' over a standing rider, and stopped the 45 s, so only the 3-minute cap ended the Return.
        local f=fixture({two=true,auto_return=true});f.riding()
        fall(f,"hit something at 4.5 m/s")
        f.latest=cleaned();f.ragdoll=true;refused_while_down(f)
        for _=1,30 do f.now+=184;f.tick() end
        check(f.entry:help_line()=="Press A to get up." and f.toggles>0,"down, and the switch refused")
        local asked,stood=f.toggles,f.now
        f.ragdoll=false;f.on_pad=function(pad) pad.left_x=1;return pad end
        for _=1,55 do f.now+=184;f.tick() end
        local s=f.entry:status()
        check(s.phase=="returning" and f.toggles==asked and s.detail=="Let go of the controls to go back to the skateboard.",
            "standing with the stick held, nothing is asked: "..tostring(s.detail))
        check(f.entry:help_line()=="Going back to the skateboard: let go of the controls.",
            "and the HUD asks to let go: "..tostring(f.entry:help_line()))
        for _=1,300 do f.now+=184;f.tick();if f.entry:status().phase=="blocked" then break end end
        s=f.entry:status()
        check(s.phase=="blocked" and s.detail:find("Return did not finish",1,true) and f.now-stood>=44000 and f.now-stood<=46000,
            "held while standing, the 45 s limit ends it: "..tostring(f.now-stood).." ms "..s.phase)
        -- Letting go asks at once.
        local g=fixture({two=true,auto_return=true});g.riding()
        fall(g,"hit something at 4.5 m/s")
        g.latest=cleaned();g.ragdoll=true;refused_while_down(g)
        for _=1,30 do g.now+=184;g.tick() end
        g.ragdoll=false;g.on_pad=function(pad) pad.left_x=1;return pad end
        for _=1,55 do g.now+=184;g.tick() end
        asked=g.toggles;g.on_pad=nil;g.now+=500;g.tick()
        check(g.toggles==asked+1 and g.entry:status().stock_attempted,"letting go arms the switch")
        g.latest=cleaned();g.stock=100;g.tick()
        check(g.entry:status().phase=="stepping_off" and g.entry:status().attempts_used==2,"and the remount starts on the board")
    end)
    case("a rider kept down with a control held is still down, and stands into the switch",function()
        -- A stick held from the crash on: nothing is asked of Core, so only the rider's own read says they are down.
        -- Until 2026-11-04 that Return gave up at 45 s, as loop3's did beside the SUV.
        local f=fixture({two=true,auto_return=true});f.riding()
        fall(f,"hit something at 4.5 m/s")
        f.latest=cleaned();f.ragdoll=true;refused_while_down(f)
        f.on_pad=function(pad) pad.left_x=1;return pad end
        for _=1,330 do f.now+=184;f.tick();if f.entry:status().phase=="blocked" then break end end
        local s=f.entry:status()
        check(s.phase=="returning" and f.toggles==0 and f.entry:help_line()=="Press A to get up.",
            "60 s ragdolled with the stick held: "..s.phase.." "..tostring(f.entry:help_line()))
        -- Let go while still down: the switch is asked for and refused, and the HUD still says why it waits.
        f.on_pad=nil;f.now+=500;f.tick()
        check(f.toggles==1 and not f.entry:status().stock_attempted and f.entry:help_line()=="Press A to get up.",
            "let go while down, refused, and still waiting")
        f.ragdoll=false;f.now+=500;f.tick()
        check(f.toggles==2 and f.entry:status().stock_attempted,"up and let go, the switch is armed")
    end)
    case("each Return after a crash gets its own three minutes",function()
        local f=fixture({two=true,auto_return=true});f.riding()
        fall(f,"hit something at 4.5 m/s")
        f.latest=cleaned();f.ragdoll=true;refused_while_down(f)
        for _=1,650 do f.now+=184;f.tick() end
        check(f.entry:status().phase=="returning","first crash, 120 s down, still a Return")
        f.ragdoll=false;f.now+=500;f.tick()
        f.latest=cleaned();f.stock=100;f.tick()
        f.await_stepoff()
        f.latest=cleaned();f.stock=504;f.on_ready504=function()return true,2 end
        f.tick();f.await_mount();f.tick()
        check(f.entry:status().phase=="riding","rides again")
        fall(f,"hit something at 4.5 m/s")
        f.latest=cleaned();f.ragdoll=true
        for _=1,650 do f.now+=184;f.tick() end
        check(f.entry:status().phase=="returning","a second 120 s crash is not cut short by the first one's time: "
            ..f.entry:status().phase.." "..tostring(f.entry:status().detail))
    end)
    case("the remount after a crash waits out a rider off the board as it steps off",function()
        -- The user's crash of 2026-11-02 19:35: the board read once, the step-off read the rider off it 1.1 s later,
        -- and the remount stopped for good with 'Attempt two lost its stock100 baseline before admission.'
        local f=fixture({two=true,auto_return=true});f.riding()
        fall(f,"rider was knocked down")
        f.latest=cleaned();f.tick();check(f.toggles==1,"the Return's one switch")
        f.latest=cleaned();f.stock=100;f.tick()
        check(f.entry:status().phase=="stepping_off" and f.entry:status().attempts_used==2,"on the board, Recover's Mount steps off")
        f.ragdoll=true;f.tick(3)
        check(f.entry:status().phase=="stepping_off" and f.stepoffs==nil,"a ragdoll sample waits rather than stopping")
        f.ragdoll=false;f.stock=504;f.tick(3);f.stock=100
        check(f.entry:status().phase=="stepping_off" and f.stepoffs==nil,"and so does one on foot")
        local quiet=f.now
        f.await_stepoff()
        check(f.stepoffs==1 and f.now-quiet>=600,"back on the board, the full quiet window runs again before the step-off")
        f.latest=cleaned();f.stock=504;f.on_ready504=function()return true,2 end
        f.tick();f.await_mount();f.tick()
        check(f.mounts==2 and f.entry:status().phase=="riding","and the ride goes on")
        -- A Mount the rider chose keeps its rule: off the board before the step-off spends it.
        local g=fixture({two=true});first_return(g)
        check(g.entry:mount(),"a deliberate second Mount")
        g.ragdoll=true;g.tick()
        check(g.entry:status().phase=="blocked" and g.entry:status().detail:find("stock100 baseline",1,true),
            "its step-off still stops on the same sample")
        -- Still off the board when the step-off's 60 s run out: the rider is told plainly what to press.
        local h=fixture({two=true,auto_return=true});h.riding();fall(h,"rider was knocked down")
        h.latest=cleaned();h.tick();h.latest=cleaned();h.stock=100;h.tick()
        check(h.entry:status().phase=="stepping_off","Recover's step-off")
        h.stock=504
        for _=1,400 do h.now+=184;h.tick();if h.entry:status().phase=="blocked" then break end end
        check(h.entry:status().phase=="blocked" and h.stepoffs==nil,"60 s off the board ends the step-off")
        check(h.entry:help_line()=="Press Y for your skateboard, then hold LB and press A.","the notice says what to press")
        h.now+=4000;h.tick()
        check(h.entry:help_line()=="Press Y for your skateboard, then hold LB and press A.","and so does the line after it")
    end)
    case("while the remount after a crash waits for the board, the HUD says what helps",function()
        -- Until 2026-11-04 the HUD said 'Stepping off the board: stand still and let go of the controls.' all the
        -- while, for up to 60 s. A rider standing on foot is not put back on the board by the game: Y does that.
        local Y_LINE="Press Y for your skateboard, then let go of the controls."
        local function recover_stepping_off(f)
            f.riding();fall(f,"rider was knocked down")
            f.latest=cleaned();f.tick();f.latest=cleaned();f.stock=100;f.tick()
            check(f.entry:status().phase=="stepping_off" and f.entry:status().attempts_used==2,"Recover's step-off")
        end
        local f=fixture({two=true,auto_return=true});recover_stepping_off(f)
        f.ragdoll=true
        for _=1,25 do f.now+=184;f.tick() end
        check(f.entry:status().phase=="stepping_off" and f.entry:help_line()=="Press A to get up.",
            "a rider the game has down is waited for, and the HUD says so: "..tostring(f.entry:help_line()))
        f.ragdoll=false;f.stock=504;f.now+=184;f.tick()
        check(f.entry:help_line()~=Y_LINE,"a first standing read does not yet ask for Y")
        for _=1,6 do f.now+=184;f.tick() end
        check(f.entry:help_line()==Y_LINE,"standing on foot for a second, the HUD asks for Y: "..tostring(f.entry:help_line()))
        for _=1,16 do f.now+=184;f.tick() end
        check(f.entry:status().phase=="stepping_off" and f.stepoffs==nil and f.entry:help_line()==Y_LINE,"and keeps asking")
        f.stock=100;f.tick()
        check(f.entry:help_line()=="Stepping off the board: stand still and let go of the controls.","Y pressed, the usual line")
        f.await_stepoff()
        check(f.stepoffs==1,"the step-off goes on")
        f.latest=cleaned();f.stock=504;f.on_ready504=function()return true,2 end
        f.tick();f.await_mount();f.tick()
        check(f.mounts==2 and f.entry:status().phase=="riding" and f.entry:status().attempts_used==2,"and the ride goes on")
        -- One odd read of the rider on foot never asks a rider on the board for Y.
        local g=fixture({two=true,auto_return=true});recover_stepping_off(g)
        g.on_pad=function(pad) pad.buttons.x=true;return pad end
        for _=1,25 do g.now+=184;g.tick() end
        g.on_pad=nil
        local shown=false
        g.stock=504
        for _=1,12 do g.tick();shown=shown or g.entry:help_line()==Y_LINE end
        g.stock=100
        for _=1,80 do g.tick();shown=shown or g.entry:help_line()==Y_LINE;if g.stepoffs then break end end
        check(not shown and g.stepoffs==1,"a 200 ms read on foot, then the board: no Y line, and the step-off goes on")
    end)
    case("a Recover step-off that runs out with the rider back on the board is not told to press Y",function()
        local h=fixture({two=true,auto_return=true});h.riding();fall(h,"rider was knocked down")
        h.latest=cleaned();h.tick();h.latest=cleaned();h.stock=100;h.tick()
        check(h.entry:status().phase=="stepping_off","Recover's step-off")
        h.ragdoll=true;h.tick(2);h.ragdoll=false
        h.on_pad=function(pad) pad.buttons.x=true;return pad end
        for _=1,400 do h.now+=184;h.tick();if h.entry:status().phase=="blocked" then break end end
        check(h.entry:status().phase=="blocked" and h.stepoffs==nil,"the step-off ran out")
        check(h.entry:help_line()=="That didn't finish. Get on your skateboard, then hold LB and press A.",
            "on the board the HUD gives the general line: "..tostring(h.entry:help_line()))
    end)
    case("a Mount from a blocked ride that cannot start yet keeps the blocked help line up",function()
        local f=fixture({two=true});f.riding();f.on_stock=function() return false,"constructed refusal" end
        check(f.entry:return_to_skateboard(),"Return accepted")
        f.latest=cleaned()
        for _=1,300 do f.now+=184;f.tick();if f.entry:status().phase=="blocked" then break end end
        check(f.entry:status().phase=="blocked","the Return gave up on foot")
        local mounted,why=f.entry:mount()
        check(not mounted and why=="Get on your skateboard, then hold LB and press A.","on foot, Mount says why")
        check(f.entry:status().phase=="blocked","and the ride stays blocked rather than 'skateboard'")
        f.now+=4000;f.tick()
        check(f.entry:help_line()=="That didn't finish. Get on your skateboard, then hold LB and press A.",
            "so the HUD keeps a line after the notice")
        f.stock=100
        check(f.entry:mount() and f.entry:status().phase=="stepping_off","on the board the same Mount goes")
    end)
    case("the log says which readiness failed and why a switch's settle gave up",function()
        local lines={}
        local f=fixture({two=true});f.R.log=function(line) lines[#lines+1]=line end
        f.riding()
        fall(f,"rider was knocked down")
        f.latest.readiness={state=504,ragdoll=true,wipeouts=1};f.latest.initial_readiness={wipeouts=0}
        f.latest.equipment={phase="done",outcome="failed",reason="settle_deadline",suffix={last_failure="ragdoll_true"}}
        f.tick()
        local found=false
        for _,line in lines do
            if line:find("ready_state=504 ready_ragdoll=true ready_wipeouts=1/0 settle_failure=ragdoll_true",1,true) then found=true end
        end
        check(found,"one lifecycle line carries the frozen facts and the settle suffix's last failure")
    end)
    case("an F8 whose position Core could not measure goes on as a plain Return",function()
        local f=fixture({two=true});f.riding()
        function f.owner:request_return()
            -- Core's request_return: stop the bike always, then say the capture failed (bike_runtime_core.lua).
            self:request_stop("explicit return to skateboard")
            f.latest.return_capture_issue="Return measured support unavailable"
            return false,"Return measured support unavailable"
        end
        check(f.entry:return_to_skateboard(),"the Return is accepted")
        local s=f.entry:status()
        check(s.phase=="returning" and s.return_position==nil and f.stops==1,"with no placement, and the one stop Core made")
        f.tick(3);check(f.toggles==0,"no switch before cleanup finishes")
        f.latest=cleaned();f.tick();check(f.toggles==1,"one switch once it has")
        f.latest=cleaned();f.stock=100;f.tick()
        check(f.entry:status().phase=="skateboard" and f.stops==1,"and the Return ends on the board")
        -- A refusal from before Core, or one without Core's stop and capture issue, still ends the Return and asks
        -- for the ordinary stop.
        for _,stopped in {false,true} do
            local g=fixture({two=true});g.riding()
            function g.owner:request_return()
                if stopped then self:request_stop("explicit return to skateboard") end
                return false,"Live Return owner unavailable"
            end
            check(not g.entry:return_to_skateboard() and g.entry:status().phase=="blocked",
                "a refusal Core did not explain stays a failure")
            check(g.stops==(stopped and 2 or 1) and g.toggles==0,"with the ordinary stop asked for, as before")
        end
    end)
    case("a ride's end is told in plain words, and the log and status keep Core's reason",function()
        -- The beta told riders 'Ride ended: fresh sampled upright/focus/context/fall readiness lost' and the like.
        local function logged(lines,line)
            for _,l in lines do if l==line then return true end end
            return false
        end
        local lines={}
        local f=fixture({two=true,auto_return=true});f.R.log=function(line) lines[#lines+1]=line end
        f.riding();fall(f,"hit something at 4.5 m/s")
        check(f.entry:help_line()=="The rider came off. Getting back on the bike.","a crash says the rider came off and what comes next")
        check(logged(lines,"[BMX] Ride ended: hit something at 4.5 m/s")
            and logged(lines,"[BMX] told: The rider came off. Getting back on the bike."),"the log keeps Core's reason and what was told")
        check(f.entry:status().last_stop=="hit something at 4.5 m/s","and the status, for the menu page, keeps the reason")
        local k=fixture({two=true,auto_return=true});k.riding();fall(k,"rider was knocked down")
        check(k.entry:help_line()=="The rider came off. Getting back on the bike.","a knock-down is told the same way")
        lines={}
        local g=fixture({two=true,auto_return=true});g.R.log=function(line) lines[#lines+1]=line end
        -- Core's own stop: its reason is the stop's, as when focus is lost (bike_runtime_core.lua stop_all).
        g.riding();g.focused=false
        g.latest=cleaned();g.latest.phase="stopping";g.latest.bike_cleanup_complete=false
        g.latest.bike_authority=true;g.latest.cleanup_pending=true;g.latest.stock_toggle_blocked=true
        g.latest.stop_reason="fresh sampled upright/focus/context/fall readiness lost"
        g.latest.ride={stop_requested=true,issue=g.latest.stop_reason}
        g.tick()
        -- The Return starts on the same tick, and LB + A is refused until it reaches the board, so the notice says where
        -- the rider is going. Until 2026-11-04 it said 'Hold LB and press A to ride again.' over the Return.
        check(g.entry:help_line()=="The ride stopped. Going back to the skateboard." and g.entry:status().phase=="returning",
            "any other end says the ride stopped and where the rider is going: "..tostring(g.entry:help_line()))
        check(logged(lines,"[BMX] Ride ended: fresh sampled upright/focus/context/fall readiness lost")
            and g.entry:status().last_stop=="fresh sampled upright/focus/context/fall readiness lost","with the reason kept in the log and status")
        -- With no mount left (an SDK that cannot reuse the bike), a fall goes back to the skateboard instead.
        local h=fixture({auto_return=true});h.riding();fall(h,"hit something at 4.5 m/s")
        check(h.entry:help_line()=="The rider came off. Going back to the skateboard." and h.entry:status().return_requested,
            "a fall with no mount left says where the rider is going")
        local m=fixture({two=true});m.riding();fall(m,"hit something at 4.5 m/s")
        check(m.entry:help_line()=="The rider came off. Hold LB and press A to ride again.","without the automatic Return the rider is told what to press")
    end)
    case("a failure shows the blocked help line, and the log keeps why",function()
        local lines={}
        local f=fixture({two=true,auto_return=true});f.R.log=function(line) lines[#lines+1]=line end
        f.riding();fall(f,"hit something at 4.5 m/s")
        check(f.entry:help_line()=="The rider came off. Getting back on the bike.","the ride's end is up")
        f.step_raise=true;f.tick()
        check(f.entry:status().phase=="blocked","the lifecycle step failing ends it")
        check(f.entry:help_line()=="That didn't finish. Get on your skateboard, then hold LB and press A.",
            "at once the HUD shows what to do, not the internal reason or the earlier notice")
        local found=false
        for _,line in lines do if line=="[BMX] Stopped: Lifecycle step unavailable; cleanup remains required." then found=true end end
        check(found,"the log keeps why it stopped")
    end)
    return {cases=cases,assertions=assertions,constructed=true,native_authority=false,gameplay=false}
end
return Tests

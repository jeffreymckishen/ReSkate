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
            return {skater=true,airborne=f.airborne,teleport_pending=false,watch={valid=true,state=f.stock,ragdoll_known=true,ragdoll=false}}
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
        function owner:second_preflight_ready(admitted_at_ms)
            f.preflight_proofs=(f.preflight_proofs or 0)+1
            if f.on_preflight_proof then return f.on_preflight_proof(admitted_at_ms) end
            if f.stepoffs~=1 or f.mounts~=1 or admitted_at_ms~=f.second_admitted_at or f.stock~=504 then
                return false,"No current unrequested second intent"
            end
            return self:next_mount_ready()
        end
        f.R=R;f.owner=owner
        f.entry=Entry.new(R,Runtime,Survey,{admitted=options.admitted~=false,slot=0,experimental_two_cycle=options.two==true,session_renewable=options.playable==true})
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
        check(f.entry:status().phase=="skateboard" and not f.entry:mount(),"third intent refused before preparation")
        check(f.new_calls==1 and f.mounts==2 and f.stepoffs==1,"fixed manager/two mounts/one preparation transition")
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
        check(f.entry:status().attempts_used==2 and f.entry:status().phase=="blocked","deferred refusal remains visible and spent")
        check(not f.entry:mount() and f.probes==before and f.mounts==1,"no hidden allocation or survey retry")
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
        check(f.entry:status().phase=="spent" and not f.entry:mount(),"observed100 cannot turn an unqualified cycle into a retry")
        check(f.stepoffs==nil and f.mounts==1,"no step-off/prepare/allocation after failed first cycle")
    end)    case("Root-approved narrower second Mount refuses already-onfoot504",function()
        local f=fixture({two=true});first_return(f);f.stock=504
        check(not f.entry:mount(),"second intent is not an optional manual504 rearm")
        check(f.entry:status().attempts_used==2 and f.entry:status().phase=="blocked","narrower intent is consumed and explained")
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
        check(not f.entry:mount() and f.entry:status().attempts_used==2,"state failure remains spent")
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
        check(not f.entry:recover() and not f.entry:status().recovery_available and f.mounts==2,"second fall cannot allocate a third attempt")
        check(f.entry:return_to_skateboard(),"ordinary Return remains available after the final fall")
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
        local expired=pending_fall();expired.tick();expired.now+=20000;expired.tick()
        check(expired.entry:status().phase=="blocked" and not expired.entry:status().recovery_pending
            and expired.toggles==0 and expired.mounts==1,"original stop+20s is never restarted or extended for known300")
        local unknown=pending_fall();unknown.ragdoll_known=false;unknown.tick()
        check(unknown.entry:status().phase=="blocked" and unknown.toggles==0,"unknown ragdoll context is never treated as a recoverable wait")
        local missing=pending_fall();missing.latest.stop_ms=nil;missing.tick()
        check(missing.entry:status().phase=="blocked" and missing.toggles==0,"missing original stop time cannot create a new recovery deadline")
        local changed=pending_fall();changed.tick();changed.level="other";changed.tick()
        check(changed.entry:status().phase=="blocked" and changed.toggles==0,"fresh level mismatch ends waiting before any stock request")
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
        check(f.entry:status().phase=="blocked" and not f.entry:status().recovery_pending
            and f.toggles==0 and f.mounts==1,"unknown cleanup cancels the queued intent without any stock or Mount")
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
        check(g.entry:status().phase=="blocked" and not g.entry:status().recovery_pending
            and g.toggles==1 and g.mounts==1,"stock refusal is not retried or converted into a Mount")
    end)
    case("second terrain retry keeps intent and step-off then repeats full survey",function()
        local f=fixture({two=true,playable=true});second_terrain(f)
        local admitted=f.second_admitted_at;local probes,prepares=f.probes,f.prepares
        local held=true;f.on_pad=function(p) p.buttons.lb=held;p.buttons.a=held;return p end
        f.rough=false;f.position=vector.create(4,.5,0)
        check(f.entry:mount(),"explicit terrain retry accepted on existing second intent")
        f.tick(45)
        check(f.probes==probes and f.prepares==prepares and f.mounts==1 and f.stepoffs==1,
            "held retry chord delays all preparation and never repeats Y")
        held=false;f.tick(38)
        check(f.probes==probes and f.mounts==1,"less than600ms neutral cannot start a new survey")
        f.await_mount()
        check(f.mounts==2 and f.stepoffs==1 and f.new_calls==1 and f.second_admitted_at==admitted,
            "one fresh owner request after the same intent, no replacement manager or step-off")
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
            if kind=="pad" then check(accepted,"pending retry before malformed new pad read");f.tick()
            else check(not accepted,"exact prior proof required before retry") end
            check(f.entry:status().phase=="blocked" and not f.entry:mount(),"proof loss cannot become another terrain retry")
            check(f.mounts==1 and f.stepoffs==1 and f.probes==probes and f.prepares==prepares,
                "no body request, Y or survey after unknown proof")
        end
    end)
    case("second terrain retry never resets original60second deadline",function()
        local f=fixture({two=true,playable=true});second_terrain(f)
        local probes,prepares=f.probes,f.prepares
        f.now=f.second_admitted_at+60000
        check(not f.entry:mount() and f.entry:status().phase=="blocked","expired original intent refuses explicit retry")
        check(f.mounts==1 and f.stepoffs==1 and f.probes==probes and f.prepares==prepares,"expiry admits no native or survey work")
        local g=fixture({two=true,playable=true});second_terrain(g);g.rough=false
        local original=g.second_admitted_at;check(g.entry:mount(),"one pending terrain retry")
        g.on_pad=function(p)p.buttons.a=true;return p end;g.now=original+60000;g.tick()
        check(g.entry:status().phase=="blocked" and g.second_admitted_at==original and g.mounts==1 and g.stepoffs==1,
            "held controls cannot turn retry time into a fresh arm window")
    end)
    case("shared eight terrain refusals never allocate or evict",function()
        local f=fixture({two=true,playable=true});second_terrain(f)
        for count=2,8 do
            check(f.entry:mount(),"explicit bounded terrain retry")
            local s=await_terrain(f)
            check(s.terrain_refusal_count==count,"same existing refusal history appends")
            check(f.mounts==1 and f.stepoffs==1 and f.new_calls==1,"terrain refusals cannot create new owners or repeat stock")
        end
        local s=f.entry:status()
        check(s.phase=="blocked" and #s.terrain_refusals==8 and s.terrain_refusals[1].index==1,
            "eighth refusal is sticky without dropping the first")
        check(not f.entry:mount(),"no ninth terrain attempt")
    end)
    case("second obstacle or native refusal never gains terrain retry",function()
        local f=fixture({two=true,playable=true});first_return(f)
        check(f.entry:mount(),"second intent before unknown obstacle result");f.await_stepoff()
        f.latest=cleaned();f.stock=504;f.on_ready504=function()return true,2 end;f.obstacle="unavailable"
        local s=await_terrain(f)
        check(s.phase=="blocked" and s.terrain_refusal_count==0 and not f.entry:mount(),"unknown query is not a terrain-only refusal")
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
    return {cases=cases,assertions=assertions,constructed=true,native_authority=false,gameplay=false}
end
return Tests

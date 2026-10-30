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
            position=vector.create(0,.5,0),heading=0,slope=0,new_calls=0,steps=0,mounts=0,stops=0,toggles=0,
            unloads=0,prepares=0,probes=0,probe_tick=0,probe_peak=0,events={},keys=options.keys or {},latest=cleaned()}
        f.latest.phase="idle";f.latest.stop_latched=false
        local R={time={},input={},menu={},skater={},storage={},world={physics={}}}
        function R.time.now() return f.now end
        function R.input.focus()
            if f.on_focus then f.on_focus() end
            return {focused=f.focused,gameplay=f.gameplay,interface_open=f.overlay}
        end
        function R.menu.game() if f.on_menu then f.on_menu() end;return {open=f.game_menu} end
        function R.skater.get()
            if f.on_actor then f.on_actor() end
            return {position=f.position,heading=f.heading}
        end
        function R.skater.telemetry()
            if f.on_telemetry then f.on_telemetry() end
            return {watch={state=f.stock}}
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
            if from.y-to.y>1 then return {status="hit",position=vector.create(from.x,math.tan(math.rad(f.slope))*from.x,from.z)} end
            if f.obstacle then return {status=f.obstacle,position=vector.create(to.x,to.y,to.z)} end
            return {status="clear"}
        end
        local owner={}
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
        function owner:prepare_next_mount(slot)
            f.stepoffs=(f.stepoffs or 0)+1;f.events[#f.events+1]="prepare504"
            if f.on_prepare504 then return f.on_prepare504() end
            f.latest=cleaned();f.latest.phase="stock_switching";f.latest.cleanup_pending=true;f.latest.stock_toggle_blocked=true
            return true
        end
        function owner:next_mount_ready()
            if f.on_ready504 then return f.on_ready504() end
            return false,"pending"
        end
        f.R=R;f.owner=owner
        f.entry=Entry.new(R,Runtime,Survey,{admitted=options.admitted~=false,slot=0,experimental_two_cycle=options.two==true})
        function f.tick(count)
            for _=1,count or 1 do f.now+=16;f.probe_tick=0;f.entry:step(16) end
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
    case("two-cycle completes two explicit cycles and spends third",function()
        local f=fixture({two=true});first_return(f)
        check(f.experimental_factory and f.new_calls==1,"one private manager, never a replacement Runtime.new")
        local before=f.probes
        check(f.entry:mount(),"second intent is accepted once")
        check(f.entry:status().attempts_used==2 and f.stepoffs==nil,"intent2 burned before the deferred old-owner504 request")
        f.tick();check(f.stepoffs==1,"closed-menu tick sends one old-owner504 request")
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
        f.tick()
        check(f.entry:status().attempts_used==2 and f.entry:status().phase=="blocked","deferred refusal remains visible and spent")
        check(not f.entry:mount() and f.probes==before and f.mounts==1,"no hidden allocation or survey retry")
    end)
    case("old sampled504 cannot replace private newer equipment ACK",function()
        local f=fixture({two=true});first_return(f);check(f.entry:mount(),"intent2 accepted")
        f.tick();check(f.stepoffs==1,"old-owner504 request starts before readiness check")
        f.stock=504;f.latest=cleaned();f.on_ready504=function()return false,"stale old ACK"end
        local before=f.probes;f.tick()
        check(f.entry:status().phase=="blocked" and f.probes==before,"private proof refusal blocks survey despite504 sample")
    end)
    case("private ready504 but wrong sampled state is refused",function()
        local f=fixture({two=true});first_return(f);check(f.entry:mount(),"intent2 accepted")
        f.tick()
        f.latest=cleaned();f.stock=100;f.on_ready504=function()return true,2 end
        f.tick();check(f.entry:status().phase=="blocked" and f.mounts==1,"fresh state check prevents premature survey/mount")
    end)
    case("Cancel during second archive/preparation callback cannot restart",function()
        local f=fixture({two=true});first_return(f)
        f.on_prepare504=function()f.entry:cancel();return true end
        check(f.entry:mount(),"intent accepted before deferred callback")
        f.tick();check(f.stepoffs==1 and f.entry:status().cancelled,"reentrant Cancel invalidates deferred acceptance")
        f.tick(20);check(f.entry:status().cancelled and f.mounts==1,"no second body after cancellation")
    end)
    case("Cancel during acknowledged504 callback cannot start prepare",function()
        local f=fixture({two=true});first_return(f);check(f.entry:mount(),"intent2 accepted")
        f.tick()
        f.latest=cleaned();f.stock=504
        f.on_ready504=function()f.entry:cancel();return true,2 end
        local before=f.prepares;f.tick()
        check(f.entry:status().cancelled and f.prepares==before,"no prepare after readiness callback Cancel")
    end)
    case("unload during second preparation cannot start prepare",function()
        local f=fixture({two=true});first_return(f);check(f.entry:mount(),"intent2 accepted")
        f.tick()
        f.latest=cleaned();f.stock=504
        f.on_ready504=function()f.entry:unload();return true,2 end
        local before=f.prepares;f.tick();check(f.entry:status().phase=="unloaded" and f.prepares==before,"unload remains terminal")
    end)
    case("Return unavailable during step-off cannot send a second transaction",function()
        local f=fixture({two=true});first_return(f);check(f.entry:mount(),"intent2 accepted")
        local before=f.toggles;check(not f.entry:return_to_skateboard(),"old mount proof does not authorize Return during504 setup")
        check(f.toggles==before and f.stepoffs==nil,"no pulse from premature Return while deferred")
        f.tick();check(f.stepoffs==1,"only the following closed-menu tick starts step-off")
    end)
    case("prior namespace blocks experimental factory acquisition",function()
        local f=fixture({two=true,keys={"old_marker"}})
        check(not f.entry:mount(),"reload cannot adopt old terminal namespace")
        f.tick(10);check(f.prepares==0 and f.mounts==0 and f.stepoffs==nil,"no native work on reload refusal")
    end)
    case("new survey expiry remains unchanged for second mount",function()
        local f=fixture({two=true});first_return(f);f.overlay=true
        check(f.entry:mount(),"intent2 accepted")
        f.overlay=false;f.tick();check(f.stepoffs==1,"closed-menu tick starts step-off");f.overlay=true
        f.latest=cleaned();f.stock=504;f.on_ready504=function()return true,2 end
        for _=1,200 do f.tick();if f.entry:status().phase=="awaiting_mount" then break end end
        check(f.entry:status().phase=="awaiting_mount","fresh second survey waits behind overlay")
        f.now+=45001;f.overlay=false;f.tick()
        check(f.entry:status().phase=="blocked" and f.mounts==1,"old45s TTL is never extended for remount")
    end)
    case("second survey movement failure remains terminal",function()
        local f=fixture({two=true});first_return(f);f.overlay=true
        check(f.entry:mount(),"intent2 accepted")
        f.overlay=false;f.tick();check(f.stepoffs==1,"closed-menu tick starts step-off");f.overlay=true
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
        f.game_menu=false;f.tick();check(f.stepoffs==1,"first closed-menu tick sends exactly once")
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
        f.tick(10)
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
        f.tick();check(f.stepoffs==1 and f.probes==probes,"existing deferred504 request precedes all new survey work")
        f.latest=cleaned();f.stock=504;f.on_ready504=function()return true,2 end
        f.tick();f.await_mount();f.tick()
        check(f.mounts==2 and f.probes>=probes+1260 and f.entry:status().phase=="riding","fresh504 ACK and complete fresh survey precede mount two")
        check(f.new_calls==1 and f.entry:status().fall_reason==nil,"same bounded manager; fallen display clears only on actual following")
        fall(f,"measured tilt 56.0 deg over the 55 deg Ride stop")
        check(not f.entry:recover() and not f.entry:status().recovery_available and f.mounts==2,"second fall cannot allocate a third attempt")
        check(f.entry:return_to_skateboard(),"ordinary Return remains available after the final fall")
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
    return {cases=cases,assertions=assertions,constructed=true,native_authority=false,gameplay=false}
end
return Tests

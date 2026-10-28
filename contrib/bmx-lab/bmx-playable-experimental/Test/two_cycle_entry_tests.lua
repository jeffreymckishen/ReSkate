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
        check(f.entry:status().attempts_used==2 and f.stepoffs==1,"intent2 burned before one old-owner504 request")
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
        check(not f.entry:mount(),"failure is visible to caller")
        check(f.entry:status().attempts_used==2 and f.entry:status().phase=="blocked","failed intent remains spent")
        check(not f.entry:mount() and f.probes==before and f.mounts==1,"no hidden allocation or survey retry")
    end)
    case("old sampled504 cannot replace private newer equipment ACK",function()
        local f=fixture({two=true});first_return(f);check(f.entry:mount(),"intent2 accepted")
        f.stock=504;f.latest=cleaned();f.on_ready504=function()return false,"stale old ACK"end
        local before=f.probes;f.tick()
        check(f.entry:status().phase=="blocked" and f.probes==before,"private proof refusal blocks survey despite504 sample")
    end)
    case("private ready504 but wrong sampled state is refused",function()
        local f=fixture({two=true});first_return(f);check(f.entry:mount(),"intent2 accepted")
        f.latest=cleaned();f.stock=100;f.on_ready504=function()return true,2 end
        f.tick();check(f.entry:status().phase=="blocked" and f.mounts==1,"fresh state check prevents premature survey/mount")
    end)
    case("Cancel during second archive/preparation callback cannot restart",function()
        local f=fixture({two=true});first_return(f)
        f.on_prepare504=function()f.entry:cancel();return true end
        check(not f.entry:mount(),"reentrant Cancel invalidates returned acceptance")
        f.tick(20);check(f.entry:status().cancelled and f.mounts==1,"no second body after cancellation")
    end)
    case("Cancel during acknowledged504 callback cannot start prepare",function()
        local f=fixture({two=true});first_return(f);check(f.entry:mount(),"intent2 accepted")
        f.latest=cleaned();f.stock=504
        f.on_ready504=function()f.entry:cancel();return true,2 end
        local before=f.prepares;f.tick()
        check(f.entry:status().cancelled and f.prepares==before,"no prepare after readiness callback Cancel")
    end)
    case("unload during second preparation cannot start prepare",function()
        local f=fixture({two=true});first_return(f);check(f.entry:mount(),"intent2 accepted")
        f.latest=cleaned();f.stock=504
        f.on_ready504=function()f.entry:unload();return true,2 end
        local before=f.prepares;f.tick();check(f.entry:status().phase=="unloaded" and f.prepares==before,"unload remains terminal")
    end)
    case("Return unavailable during step-off cannot send a second transaction",function()
        local f=fixture({two=true});first_return(f);check(f.entry:mount(),"intent2 accepted")
        local before=f.toggles;check(not f.entry:return_to_skateboard(),"old mount proof does not authorize Return during504 setup")
        check(f.toggles==before and f.stepoffs==1,"no pulse from premature Return")
    end)
    case("prior namespace blocks experimental factory acquisition",function()
        local f=fixture({two=true,keys={"old_marker"}})
        check(not f.entry:mount(),"reload cannot adopt old terminal namespace")
        f.tick(10);check(f.prepares==0 and f.mounts==0 and f.stepoffs==nil,"no native work on reload refusal")
    end)
    case("new survey expiry remains unchanged for second mount",function()
        local f=fixture({two=true});first_return(f);f.overlay=true
        check(f.entry:mount(),"intent2 accepted")
        f.latest=cleaned();f.stock=504;f.on_ready504=function()return true,2 end
        for _=1,200 do f.tick();if f.entry:status().phase=="awaiting_mount" then break end end
        check(f.entry:status().phase=="awaiting_mount","fresh second survey waits behind overlay")
        f.now+=45001;f.overlay=false;f.tick()
        check(f.entry:status().phase=="blocked" and f.mounts==1,"old45s TTL is never extended for remount")
    end)
    case("second survey movement failure remains terminal",function()
        local f=fixture({two=true});first_return(f);f.overlay=true
        check(f.entry:mount(),"intent2 accepted")
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
    end)    return {cases=cases,assertions=assertions,constructed=true,native_authority=false,gameplay=false}
end
return Tests

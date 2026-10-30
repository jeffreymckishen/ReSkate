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
        f.R=R;f.owner=owner
        f.entry=Entry.new(R,Runtime,Survey,{admitted=options.admitted~=false,slot=0})
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
    case("01 closed admission and prior namespace cannot acquire",function()
        local f=fixture({admitted=false})
        check(not f.entry:mount(),"closed source refuses intent")
        f.tick(30);check(f.prepares==0 and f.probes==0 and f.mounts==0 and f.toggles==0,"no preparation/survey/mount/stock call when closed")
        local g=fixture({keys={"prior_lifecycle"}})
        check(not g.entry:mount(),"prior namespace is refused before native work")
        g.tick(5);check(g.mounts==0 and g.prepares==0,"namespace refusal cannot be retried into acquisition")
        check(f.new_calls==1 and g.new_calls==1,"each entry constructs only one inert owner")
    end)
    case("02 preparation and real full survey precede one owner mount",function()
        local f=fixture();f.riding()
        check(f.new_calls==1 and f.prepares==1 and f.probes>=1260,"one owner and complete floor/obstacle survey, not a fabricated pass")
        check(f.probe_peak<=32,"original per-tick survey ray bound retained")
        check(not f.entry:mount(),"second intent is unavailable")
        f.tick(10);check(f.mounts==1 and not f.entry:status().session_reusable,"entry never resets or replaces owner")
    end)
    case("03 cold and clock pending preparation are bounded without create retries",function()
        local f=fixture();f.overlay=false
        f.on_prepare=function(n)
            if n==1 then return false,"native body producer setup pending; call prepare again explicitly" end
            if n==2 then return false,"waiting for a fresh qualified 60 Hz physics step" end
            return true
        end
        check(f.entry:mount(),"intent accepted");f.tick(6);check(f.prepares==1,"no prepare call faster than100ms")
        f.await_mount();check(f.prepares==3 and f.mounts==1,"pending readiness resolves before one mount, never one floor/create replay")
    end)
    case("04 unknown preparation and exceptions fail closed",function()
        for _,answer in ipairs({function() return false,"unknown" end,function() error("prepare raised") end,
            function() return true,"extra" end,function() return nil end}) do
            local f=fixture();f.overlay=false;f.on_prepare=answer
            check(f.entry:mount(),"one intent accepted before actual readiness")
            f.tick(10);check(f.entry:status().phase=="blocked" and f.prepares==1 and f.probes==0 and f.mounts==0,"bad readiness never reaches survey/mount")
            check(f.stops==1 and not f.entry:mount(),"failure is visible and cannot rearm")
        end
    end)
    case("05 slow prepare success cannot escape original30s deadline",function()
        local f=fixture();f.overlay=false
        f.on_prepare=function() f.now+=30000;return true end
        check(f.entry:mount(),"intent accepted");f.tick()
        check(f.prepares==1 and f.probes==0 and f.mounts==0 and f.entry:status().phase=="blocked","post-call clock rejects late ready result")
        local g=fixture();g.overlay=false;g.on_prepare=function() return false,"waiting for a fresh qualified 60 Hz physics step" end
        check(g.entry:mount(),"bounded pending intent accepted");g.tick(200)
        check(g.prepares==20 and g.mounts==0 and g.entry:status().phase=="blocked","twenty-call bound is not enlarged")
    end)
    case("06 hit unavailable and changing survey floor refuse mount",function()
        for _,obstacle in ipairs({"hit","unavailable"}) do
            local f=fixture();f.overlay=false;f.obstacle=obstacle
            check(f.entry:mount(),"survey intent accepted");f.await_mount()
            check(f.mounts==0 and f.entry:status().phase=="blocked","no obstruction/unknown result becomes clear")
        end
    end)
    case("07 original displayed slope rule remains stricter than generic survey pass",function()
        local f=fixture();f.overlay=false;f.slope=.0525
        check(f.entry:mount(),"historical0.05display intent accepted");f.await_mount()
        check(f.mounts==1,"known0.0525degree floor still meets original displayed0.05rule")
        local g=fixture();g.overlay=false;g.slope=.06
        check(g.entry:mount(),"survey intent accepted");g.await_mount()
        check(g.mounts==0 and g.entry:status().phase=="blocked" and g.entry:status().detail:find("slope",1,true),"generic0.5degree helper cannot relax operational0.05display bound")
    end)
    case("08 menus delay acquisition and changed position invalidates survey",function()
        local f=fixture();check(f.entry:mount(),"intent while overlay open is queued")
        f.tick(100);check(f.entry:status().phase=="awaiting_mount" and f.mounts==0,"no owner mount while overlay open")
        f.position=vector.create(.3,.5,0);f.overlay=false;f.tick()
        check(f.mounts==0 and f.entry:status().phase=="blocked","moved rider needs a new session, not a reused survey")
    end)
    case("09 stock-board state does not bypass Root3 foot-only admission",function()
        local f=fixture();f.overlay=false;f.stock=100
        check(f.entry:mount(),"intent may survey before current state check");f.await_mount()
        check(f.mounts==0 and f.entry:status().phase=="blocked","board100 cannot directly enter unproven board-to-bike path")
    end)
    case("10 cancel during survey immediately revokes remaining queries",function()
        local f=fixture();f.overlay=false
        f.on_probe=function() f.entry:cancel() end
        check(f.entry:mount(),"intent accepted");f.tick(10)
        check(f.probes==1 and f.mounts==0 and f.stops==1 and f.entry:status().cancelled,"reentrant cancel stops at the first actual probe")
        f.entry:cancel();f.tick(3);check(f.stops==1 and f.probes==1,"cancel is idempotent and cleanup ticks continue")
    end)
    case("11 cancellation in final readiness read cannot race into mount",function()
        local f=fixture();check(f.entry:mount(),"intent accepted");f.tick(100)
        f.overlay=false;f.on_telemetry=function() f.entry:cancel() end;f.tick()
        check(f.mounts==0 and f.entry:status().cancelled,"generation cancellation wins before owner request")
    end)
    case("12 mount refusal remains one attempt and cleanup continues",function()
        for _,answer in ipairs({function() return false,"constructed mount refusal" end,function() error("mount raised") end}) do
            local f=fixture();f.overlay=false;f.on_mount=answer
            check(f.entry:mount(),"explicit intent accepted");f.await_mount();local before=f.steps;f.tick(5)
            check(f.mounts==1 and f.stops==1 and f.steps==before+5 and f.entry:status().phase=="blocked","no mount retry or halted cleanup after failure")
        end
    end)
    case("13 Return waits every actual cleanup predicate",function()
        local changes={function(s) s.phase="retained_unknown" end,function(s) s.bike_authority=true end,
            function(s) s.cleanup_pending=true end,function(s) s.cleanup_unknown=true end,
            function(s) s.stock_toggle_blocked=true end,function(s) s.bike_cleanup_complete=nil end,
            function(s) s.unloaded=true end}
        for _,mutate in ipairs(changes) do
            local f=fixture();f.riding();check(f.entry:return_to_skateboard(),"return intent accepted")
            f.latest=cleaned();mutate(f.latest);f.tick(4)
            check(f.toggles==0,"no stock transaction before all explicit cleanup predicates")
        end
    end)
    case("14 already observed board needs no stock pulse",function()
        local f=fixture();f.riding();check(f.entry:return_to_skateboard(),"return accepted")
        f.latest=cleaned();f.stock=100;f.tick()
        check(f.toggles==0 and f.entry:status().phase=="skateboard","observed desired state completes without toggling away")
        check(not f.entry:mount(),"return does not create a second session")
        f.tick(3);check(f.entry:status().phase=="skateboard" and f.toggles==0,"observed success remains stable across later cleanup ticks")
    end)
    case("15 one stock transaction after clean and closed menus",function()
        local f=fixture();f.riding();check(f.entry:return_to_skateboard(),"return accepted")
        f.latest=cleaned();f.overlay=true;f.tick(3);check(f.toggles==0,"stock intent waits for closed overlay")
        f.overlay=false;f.tick();check(f.toggles==1 and f.entry:status().stock_attempted,"one existing equipment transaction armed")
        f.tick(5);check(f.toggles==1 and f.entry:status().return_requested,"pending equipment cannot be replayed")
        f.latest=cleaned();f.stock=100;f.tick()
        check(f.entry:status().phase=="skateboard" and f.toggles==1,"actual returned state, not submit acceptance, completes return")
    end)
    case("16 stock refusal and exception remain visible with no retry",function()
        for _,answer in ipairs({function() return false,"constructed stock refusal" end,function() error("stock raised") end}) do
            local f=fixture();f.riding();f.on_stock=answer;check(f.entry:return_to_skateboard(),"return accepted")
            f.latest=cleaned();f.tick();f.tick(10)
            check(f.toggles==1 and f.entry:status().phase=="blocked","stock failure cannot become repeated input")
        end
    end)
    case("17 Cancel can revoke a stock transaction independently of prior ride stop",function()
        local f=fixture();f.riding();check(f.entry:return_to_skateboard(),"return accepted")
        f.latest=cleaned();f.tick();check(f.toggles==1 and f.stops==1,"return stop and stock call occurred once")
        f.entry:cancel();f.entry:cancel();f.tick(5)
        check(f.stops==2 and f.toggles==1 and f.entry:status().cancelled,"one separate cancel revokes new equipment authority, never another toggle")
    end)
    case("18 reentrant Cancel in stock callback cannot be overwritten",function()
        local f=fixture();f.riding();check(f.entry:return_to_skateboard(),"return accepted")
        f.on_stock=function() f.entry:cancel();return true end
        f.latest=cleaned();f.tick();f.tick(3)
        check(f.toggles==1 and f.entry:status().phase=="cancelled" and not f.entry:status().return_requested,"callback acceptance does not resurrect cancelled return")
    end)
    case("19 failed step never authorizes return from stale clean status",function()
        local f=fixture();f.riding();check(f.entry:return_to_skateboard(),"return accepted")
        f.latest=cleaned();f.step_raise=true;f.tick(3)
        check(f.toggles==0 and f.entry:status().cleanup_unknown and f.entry:status().phase=="blocked","unavailable step keeps conservative unknown state")
        local before=f.steps;f.step_raise=false;f.tick(3);check(f.steps==before+3,"cleanup continues after entry failure")
        local g=fixture();g.riding();check(g.entry:return_to_skateboard(),"second return accepted")
        g.latest=cleaned();g.tick();check(g.toggles==1,"equipment has separate live authority")
        g.step_raise=true;g.tick(3)
        check(g.stops==2 and g.toggles==1,"entry fault separately revokes equipment without replaying stock input")
    end)
    case("20 unload latches before callbacks and never switches stock",function()
        local f=fixture();f.riding();check(f.entry:return_to_skateboard(),"return accepted")
        f.on_unload=function() check(not f.entry:mount(),"unload cannot remount reentrantly");f.entry:unload() end
        local before=f.steps;f.entry:unload();f.entry:unload();f.tick(5)
        check(f.unloads==1 and f.toggles==0 and f.steps==before and f.entry:status().phase=="unloaded","single unload and no later work")
    end)
    case("21 Cancel or unload during environment reads prevents the next prepare or probe",function()
        for _,phase in ipairs({"preparing","surveying"}) do
            for _,hook in ipairs({"on_focus","on_menu"}) do
                for _,action in ipairs({"cancel","unload"}) do
                    local f=fixture();check(f.entry:mount(),"one intent accepted before callback revocation")
                    if phase=="surveying" then f.tick();check(f.entry:status().phase=="surveying" and f.probes==0,"real survey is queued but has not cast") end
                    local prepares,probes=f.prepares,f.probes
                    f[hook]=function() if action=="cancel" then f.entry:cancel() else f.entry:unload() end end
                    f.tick();f[hook]=nil;f.tick(3)
                    check(f.prepares==prepares and f.probes==probes,"environment revocation prevents the next preparation/probe effect")
                    check(f.mounts==0 and f.toggles==0 and f.entry:status().cancelled,"no later body/stock request follows revocation")
                    if action=="cancel" then check(f.stops==1 and f.entry:status().phase=="cancelled","one cancellation keeps cleanup ticking")
                    else check(f.unloads==1 and f.entry:status().phase=="unloaded","unload remains one terminal owner call") end
                end
            end
        end
    end)
    case("22 measured Return places once after clean stock100 ACK and then converges",function()
        local function stock_done(f)
            f.stock=100;f.latest=cleaned()
            f.latest.equipment={phase="done",outcome="target_observed",initial_state=504,expected_state=100,
                retained=false,acknowledged=true,qualified_transition=true,current_transition=true,unloaded=false,storage_fault=false,
                terminal_receipt={terminal=true,claim_released=true,report_debt=false,quarantined=false}}
        end
        local function prepared(options)
            options=options or {}
            local f=fixture();f.riding();f.placements=0;f.pending=false
            function f.R.input.allowed() return true end
            f.R.level={current=function()return{name="constructed"}end}
            function f.R.skater.get()return{position=f.position,heading=f.heading,airborne=false}end
            function f.R.skater.telemetry()return{skater=true,airborne=false,teleport_pending=f.pending,
                watch={valid=true,state=f.stock,ragdoll_known=true,ragdoll=false,wipeouts=0}}end
            function f.owner:request_return()
                self:request_stop("explicit return to skateboard")
                local stop=f.now
                return true,table.freeze({schema="measured_return_position_v1",ground=table.freeze({55,5,80}),
                    actor_floor_clearance_m=.8,heading=.2,level="constructed",wipeouts=0,stop_ms=stop,expires_ms=stop+20000})
            end
            function f.R.skater.teleport(at,heading)
                f.placements+=1;f.placed_at=f.now
                check(f.latest.bike_cleanup_complete and f.stops==1 and f.toggles==1 and f.stock==100
                    and f.latest.equipment.acknowledged,"full bike cleanup and exact stock100 target/ACK precede the ONE placement")
                check(at==vector.create(55,5.8,80) and heading==.2,"final captured target survives a stock-root reset in exact native-vector representation")
                if options.refuse then return false,"host disabled" end
                if options.raise then error("constructed unknown queued result") end
                f.pending=true;return true
            end
            check(f.entry:return_to_skateboard(),"one explicit Return starts the transaction")
            f.tick(2);check(f.placements==0 and f.toggles==0,"retained bike cleanup blocks stock and placement")
            return f
        end
        local function after_stock(options)
            local f=prepared(options);f.latest=cleaned();f.tick()
            check(f.toggles==1 and f.placements==0,"clean bike requests stock exactly once with NO earlier504placement")
            f.position=vector.create(1,.5,1) -- actual stock transition may reset the physical root
            stock_done(f);f.tick()
            return f
        end
        local f=after_stock()
        check(f.placements==1 and f.pending and f.toggles==1 and f.entry:status().phase=="returning",
            "postACK sent means queued only; final Return and remount remain unavailable")
        check(not f.entry:mount(),"queued handback cannot remount")
        f.pending=false;f.tick(12)
        check(f.entry:status().phase=="returning" and not f.entry:status().return_position.observed,
            "stock100 ACK plus pending cleared at the OLD physical location is not final Return")
        f.position=vector.create(55,5.8,80);f.heading=.2;f.tick(12)
        check(f.placements==1 and f.toggles==1 and f.entry:status().return_position.observed
            and f.entry:status().phase=="skateboard","only grounded100 root/heading convergence spanning100ms completes Return")
        for _,options in ipairs({{refuse=true},{raise=true}})do
            local g=after_stock(options);g.tick(5)
            check(g.placements==1 and g.toggles==1 and g.entry:status().phase=="blocked",
                "placement refusal/unknown after stock never retries or advertises final Return")
        end
        local noack=prepared();noack.latest=cleaned();noack.tick();stock_done(noack)
        noack.latest.equipment.acknowledged=false;noack.tick()
        check(noack.placements==0 and noack.toggles==1 and noack.entry:status().phase=="blocked",
            "stock100 without exact equipment ACK cannot queue placement")
        local late=prepared();late.now+=14900;late.latest=cleaned();late.tick(3)
        check(late.placements==0 and late.toggles==0 and late.entry:status().phase=="blocked",
            "native5s queue plus100ms convergence must fit original20s before stock even starts")
        local slow=prepared();slow.latest=cleaned();slow.tick();slow.now+=14900;stock_done(slow);slow.tick()
        check(slow.placements==0 and slow.toggles==1 and slow.entry:status().phase=="blocked",
            "time spent obtaining stock ACK is charged to original20s; no late placement")
        local lost=after_stock();lost.now+=20001;lost.tick()
        check(lost.placements==1 and lost.toggles==1 and lost.entry:status().phase=="blocked",
            "missing poststock convergence by original deadline stays failed")
        local cancelled=after_stock();check(cancelled.entry:cancel(),"cancel after queued poststock placement accepted")
        cancelled.tick(10)
        check(cancelled.placements==1 and cancelled.toggles==1 and cancelled.entry:status().return_position.unknown,
            "cancel never retries or claims to cancel/complete the generic queued placement")
        for _,raises in ipairs({false,true}) do
            local refused=fixture();refused.riding()
            function refused.owner:request_return()
                if raises then error("constructed cold Return failure") end
                return false,"constructed cold Return refusal"
            end
            check(not refused.entry:return_to_skateboard(),"cold/raised Return refuses position authority")
            check(refused.stops==1 and refused.toggles==0 and refused.entry:status().phase=="blocked",
                "refused Return still requests exactly one ordinary cleanup stop")
        end
        local legacy=fixture();legacy.riding();check(legacy.entry:return_to_skateboard(),"legacy stopped recovery path remains available")
        legacy.latest=cleaned();legacy.tick();check(legacy.toggles==1,"legacy owner without measured Return method retains its existing transaction")
    end)
    check(cases==22,"exactly22 focused entry groups authored")
    return {cases=cases,assertions=assertions,game_evidence=false,native_actions=0}
end
return table.freeze(Tests)

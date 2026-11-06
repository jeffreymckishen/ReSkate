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
            unloads=0,prepares=0,probes=0,probe_tick=0,probe_peak=0,events={},keys=options.keys or {},values=options.values or {},
            set_raise=options.set_raise,latest=cleaned()}
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
        -- A new list each call, as the SDK's is, so clearing keys while going through them misses none.
        function R.storage.keys() if f.keys_raise then error("keys unavailable") end;return table.clone(f.keys) end
        function R.storage.get(key) return copy(f.values[key]) end
        function R.storage.set(key,value)
            if f.set_raise then error("set unavailable") end
            f.values[key]=copy(value)
            local at=table.find(f.keys,key)
            if value==nil and at then table.remove(f.keys,at) end
        end
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
        f.entry=Entry.new(R,Runtime,Survey,{admitted=options.admitted~=false,slot=0,settings_key=options.settings_key})
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
    case("01 closed admission cannot acquire, and an earlier launch's record does not stop this one",function()
        local f=fixture({admitted=false})
        check(not f.entry:mount(),"closed source refuses intent")
        f.tick(30);check(f.prepares==0 and f.probes==0 and f.mounts==0 and f.toggles==0,"no preparation/survey/mount/stock call when closed")
        -- A plugin's storage outlives the game. A ride's record from an earlier launch must not refuse this one.
        local g=fixture({keys={"bmx_bike_lifecycle_v1"}})
        check(#g.keys==0 and g.entry:status().phase=="idle","an earlier launch's record is cleared at load")
        check(g.entry:mount(),"Mount works on the launch after a ride")
        local h=fixture({keys={"bmx_bike_lifecycle_v1"},set_raise=true})
        check(not h.entry:mount() and h.entry:status().phase=="blocked","a record that cannot be cleared still refuses")
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
        check(not f.entry:mount(),"board100 cannot directly enter unproven board-to-bike path")
        check(f.mounts==0 and f.entry:status().attempts_used==0,"the refused first Mount spends nothing")
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
    case("16 a refused stock switch waits and asks again slowly",function()
        for _,answer in ipairs({function() return false,"constructed stock refusal" end,function() error("stock raised") end}) do
            local f=fixture();f.riding();f.on_stock=answer;check(f.entry:return_to_skateboard(),"return accepted")
            f.latest=cleaned();f.tick();f.tick(10)
            check(f.toggles==1 and f.entry:status().phase=="returning","stock refusal cannot become repeated input")
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
    -- A measured Return: the bike stopped where Core measured a placement at (55, 5.8, 80) heading .2. The rider's
    -- reads come from f: f.stock, f.pending, f.ragdoll, f.wipeouts, f.watch_air (telemetry) and f.actor_air (skater.get).
    -- f.no_skater, f.invalid, f.rag_unknown and f.rag_nil turn off the facts the telemetry read is otherwise sure of.
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
        function f.R.skater.get()return{position=f.position,heading=f.heading,airborne=f.actor_air==true}end
        function f.R.skater.telemetry()return{skater=not f.no_skater,airborne=f.watch_air==true,teleport_pending=f.pending,
            watch={valid=not f.invalid,state=f.stock,ragdoll_known=not f.rag_unknown,
                ragdoll=if f.rag_nil then nil else f.ragdoll==true,wipeouts=f.wipeouts or 0}}end
        function f.owner:request_return()
            self:request_stop("explicit return to skateboard")
            local stop=f.now
            return true,table.freeze({schema="measured_return_position_v1",ground=table.freeze({55,5,80}),
                actor_floor_clearance_m=.8,heading=.2,level="constructed",wipeouts=0,stop_ms=stop,expires_ms=stop+20000})
        end
        function f.R.skater.teleport(at,heading,placement_options)
            f.placements+=1;f.placed_at=f.now
            check(type(placement_options)=="table" and getmetatable(placement_options)==nil and placement_options.on_board==true
                and next(placement_options)=="on_board" and next(placement_options,"on_board")==nil,
                "the single postACK placement explicitly requests only on_board=true")
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
    case("22 measured Return places once after clean stock100 ACK and then converges",function()
        local f=after_stock()
        check(f.placements==1 and f.pending and f.toggles==1 and f.entry:status().phase=="returning",
            "postACK sent means queued only; final Return and remount remain unavailable")
        check(not f.entry:mount(),"queued handback cannot remount")
        f.pending=false;f.tick(12)
        check(f.entry:status().phase=="returning" and not f.entry:status().return_position.observed,
            "stock100 ACK plus pending cleared at the OLD physical location is not final Return")
        f.position=vector.create(55,5.8,80);f.heading=.2;f.stock=504;f.tick(12)
        local wrong_state=f.entry:status().return_position
        check(f.entry:status().phase=="returning" and not wrong_state.observed and wrong_state.actual_state==504
            and wrong_state.actual_pending==false and wrong_state.horizontal_error_m<1e-6,
            "matching root on504 is cached truthfully and never promoted to stock100 convergence")
        check(f.placements==1 and f.toggles==1,"504 observation causes no second placement or equipment pulse")
        f.stock=100;f.heading=.2+math.pi;f.tick(12)
        local wrong_heading=f.entry:status().return_position
        check(not wrong_heading.observed and wrong_heading.actual_state==100 and math.abs(math.abs(wrong_heading.heading_error_deg)-180)<1e-6,
            "a real180degree heading mismatch stays refused and visible without a guessed heading flip")
        f.heading=.2;f.tick(12)
        check(f.placements==1 and f.toggles==1 and f.entry:status().return_position.observed
            and f.entry:status().phase=="skateboard","only grounded100 root/heading convergence spanning100ms completes Return")
        -- A paused callback cannot turn three distant endpoints into100ms
        -- continuous Return evidence. The same one queued placement remains.
        local gap=after_stock()
        gap.pending=false;gap.position=vector.create(55,5.8,80);gap.heading=.2
        gap.tick(4)
        check(gap.entry:status().return_position.samples==1 and gap.entry:status().phase=="returning",
            "first grounded target match starts an incomplete convergence suffix")
        gap.now+=1000;gap.tick()
        check(gap.entry:status().return_position.samples==1 and not gap.entry:status().return_position.observed,
            "an unobserved gap over250ms resets the suffix instead of crediting elapsed time")
        gap.tick(4)
        check(gap.entry:status().phase=="returning" and gap.entry:status().return_position.samples==2,
            "only two new matching samples cannot finish Return after the gap")
        gap.tick(4)
        check(gap.entry:status().phase=="skateboard" and gap.entry:status().return_position.observed
            and gap.placements==1 and gap.toggles==1,
            "three fresh matches spanning100ms complete the existing placement without a retry")
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
        check(late.placements==0 and late.toggles==1 and late.entry:status().phase=="returning",
            "a Return too late to place the rider goes back to the board where they stand")
        -- Nothing was placed and the switch reached the board, so the Return finishes there rather than stopping.
        local slow=prepared();slow.latest=cleaned();slow.tick();slow.now+=14900;stock_done(slow);slow.tick()
        check(slow.placements==0 and slow.toggles==1 and slow.entry:status().phase=="skateboard"
            and slow.entry:status().return_position==nil,
            "time spent obtaining stock ACK is charged to original20s; no late placement, the rider stays on the board")
        local lost=after_stock();lost.now+=20001;lost.tick()
        check(lost.placements==1 and lost.toggles==1 and lost.entry:status().phase=="blocked",
            "a placement the game may still carry out at the original deadline stays failed")
        -- loop5 (2026-11-04): placed on a grade, the board turned and rolled away, so it never held still at the target.
        -- The game had finished with the placement, so the Return finishes on the board where the rider is, a second
        -- after the game is done with it rather than when the 20 s run out (loop7), rolling or not.
        local rolled=after_stock();rolled.tick(4)
        check(rolled.entry:status().return_position.pending_seen==true and rolled.entry:status().phase=="returning",
            "the queued placement is read pending")
        rolled.pending=false;local done_at=rolled.now
        for i=1,100 do
            rolled.position=vector.create(1+i*.05,.5-i*.01,1);rolled.tick()
            if rolled.entry:status().phase~="returning" then break end
        end
        check(rolled.placements==1 and rolled.toggles==1 and rolled.entry:status().phase=="skateboard"
            and rolled.entry:status().return_position==nil and rolled.now-done_at>=1000 and rolled.now-done_at<1100,
            "a finished placement rolling away on the board ends there a second later: "..rolled.entry:status().phase
                .." after "..(rolled.now-done_at).." ms")
        -- Only a read that says the game is done with the placement lets the Return go on: one that cannot say stops it.
        local unread=after_stock();unread.pending=nil;unread.now+=20001;unread.tick()
        check(unread.placements==1 and unread.toggles==1 and unread.entry:status().phase=="blocked",
            "an unreadable pending flag at the deadline still stops the Return")
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
    case("23 a rider the game is done placing who holds on the board ends the Return there",function()
        -- loop7 (2026-11-04 22:35): the placement read pending, then left the rider grinding 1.7 m above the target
        -- (state 403), then on the board 7 m off it, turned 70 deg. They stood there in a traffic lane until they were slammed, most likely by
        -- a car, just before the 20 s ran out. A rider on the board for a second after the game is done placing now ends
        -- the Return there.
        -- One poll per call, at ms after the placement was sent (polls are at least 50 ms apart).
        local function at(f,ms) check(f.placed_at+ms-16>=f.now,"times only go forward");f.now=f.placed_at+ms-16;f.tick() end
        local function logged(f) local lines={};f.R.log=function(line) lines[#lines+1]=line end;return lines end
        local function has(lines,piece) for _,line in lines do if line:find(piece,1,true) then return true end end;return false end
        local function returning(f,why)
            local s=f.entry:status()
            check(s.phase=="returning" and s.return_position and not s.return_position.observed and f.placements==1 and f.toggles==1,
                why..": "..s.phase.." "..tostring(s.detail))
        end
        local function finished(f,why)
            local s=f.entry:status()
            check(s.phase=="skateboard" and s.return_position==nil and f.placements==1 and f.toggles==1,
                why..": "..s.phase.." "..tostring(s.detail))
        end
        -- (a) Read pending, then done: on the board 7 m off the target for 1000 ms, five reads 250 ms apart, ends there.
        local a=after_stock();local lines=logged(a);at(a,100)
        check(a.entry:status().return_position.pending_seen==true,"the placement is read pending")
        a.pending=false;a.heading=.2+math.rad(70)
        for _,ms in {300,550,800,1050} do at(a,ms) end
        returning(a,"750 ms on the board off the target is not yet a second")
        check(a.entry:status().return_position.settled_samples==4 and a.entry:status().return_position.first_settled==a.placed_at+300,
            "the stretch counts from the first read after the game was done")
        at(a,1300)
        finished(a,"a second on the board after the placement ends the Return there")
        check(has(lines,"The game is done with the Return placement, off its target (state 100 pending false h")
            and has(lines,"the rider is on the board, so the Return finishes there.")
            and not has(lines,"not confirmed in its 20 s window"),"the log says the game is done with the placement, off its target")
        check(not has(lines,"Stopped:") and a.entry:status().return_requested==false,"nothing blocked, and the Return is over")
        -- (b) 999 ms is not a second.
        local b=after_stock();at(b,100);b.pending=false
        for _,ms in {300,500,700,900,1100,1299} do at(b,ms) end
        returning(b,"999 ms on the board is still Returning")
        at(b,1349);finished(b,"the next read past a second ends it")
        -- (c) A pending flag never read true counts only 5.1 s after the send: the SDK may not have taken the request.
        local c=after_stock();c.pending=false
        for ms=200,5000,200 do at(c,ms) end
        returning(c,"4.8 s on the board with the placement never read pending is still Returning")
        check((c.entry:status().return_position.settled_samples or 0)==0,"no read before 5.1 s counts")
        for _,ms in {5100,5300,5500,5700,5900,6000} do at(c,ms) end
        returning(c,"900 ms past 5.1 s is not yet a second, so the read at 5 s did not count")
        at(c,6100);finished(c,"a second from 5.1 s after the send ends it")
        -- (d) A read in the air, ragdolled, off the board or after another crash starts the second over, as does one that
        -- cannot say the rider is there, the watch is valid, or whether they are ragdolled: a stale state 100 or a rider
        -- the game cannot call out of ragdoll may be one who is down.
        local breaks={
            {"in the air (telemetry)",function(f,on) f.watch_air=on end},
            {"in the air (skater)",function(f,on) f.actor_air=on end},
            {"ragdolled",function(f,on) f.ragdoll=on end},
            {"off the board (504)",function(f,on) f.stock=on and 504 or 100 end},
            {"another wipeout",function(f,on) f.wipeouts=on and 1 or 0 end},
            {"no skater",function(f,on) f.no_skater=on end},
            {"watch invalid",function(f,on) f.invalid=on end},
            {"ragdoll unknown",function(f,on) f.rag_unknown=on end},
            {"ragdoll nil",function(f,on) f.rag_nil=on end}}
        for _,row in breaks do
            local d=after_stock();at(d,100);d.pending=false
            for _,ms in {300,500,700,900} do at(d,ms) end
            row[2](d,true);at(d,1100)
            returning(d,row[1].." keeps the Return waiting")
            check((d.entry:status().return_position.settled_samples or 0)==0,row[1].." resets the stretch")
            row[2](d,false)
            for _,ms in {1300,1500,1700,1900,2100} do at(d,ms) end
            returning(d,"after "..row[1].." the second starts over")
            at(d,2300);finished(d,"a second after "..row[1].." ends it")
        end
        -- A read that fails says nothing of the rider, so it too starts the second over rather than being skipped.
        local unreadable={
            {"a telemetry read that raises","telemetry",function() error("constructed telemetry fault") end},
            {"a skater read that raises","get",function() error("constructed skater fault") end},
            {"a skater read of nil","get",function() return nil end}}
        for _,row in unreadable do
            local d=after_stock();at(d,100);d.pending=false
            for _,ms in {300,500,700,900} do at(d,ms) end
            local original=d.R.skater[row[2]];d.R.skater[row[2]]=row[3];at(d,1100);d.R.skater[row[2]]=original
            returning(d,row[1].." keeps the Return waiting")
            check((d.entry:status().return_position.settled_samples or 0)==0,row[1].." resets the stretch")
            at(d,1300);returning(d,"the read after "..row[1].." starts the second")
            for _,ms in {1500,1700,1900,2100} do at(d,ms) end
            returning(d,"800 ms after "..row[1])
            at(d,2300);finished(d,"a second after "..row[1].." ends it")
        end
        -- (e) More than 250 ms between reads starts the second over.
        local e=after_stock();at(e,100);e.pending=false
        for _,ms in {300,550,800,1051} do at(e,ms) end
        check(e.entry:status().return_position.settled_samples==1,"a 251 ms gap restarts the stretch")
        at(e,1301);returning(e,"1001 ms since the first read, across the gap, is not a held second")
        for _,ms in {1551,1801} do at(e,ms) end
        returning(e,"750 ms since the gap is not yet a second")
        at(e,2051);finished(e,"a second of reads 250 ms apart after the gap ends it")
        -- (f) A rider who comes to the target is observed there, as before, and a match starts the second over.
        local f=after_stock();lines=logged(f);at(f,100);f.pending=false
        for _,ms in {300,500,700,900,1100} do at(f,ms) end
        f.position=vector.create(55,5.8,80);f.heading=.2
        for _,ms in {1200,1250,1300} do at(f,ms) end
        local s=f.entry:status()
        check(s.phase=="skateboard" and s.return_position and s.return_position.observed==true
            and s.return_position.phase=="observed" and not has(lines,"off its target"),
            "a rider who converges is observed at the target, not settled")
        local m=after_stock();at(m,100);m.pending=false
        for _,ms in {300,500,700,900,1100} do at(m,ms) end
        m.position=vector.create(55,5.8,80);m.heading=.2;at(m,1200)
        m.position=vector.create(1,.5,1);at(m,1300)
        returning(m,"a pass over the target starts the second over")
        for _,ms in {1500,1700,1900,2100} do at(m,ms) end
        returning(m,"800 ms since the pass")
        at(m,2300);finished(m,"a second after the pass ends it")
        -- (g) A placement the game still has pending never settles, and blocks at the deadline; so does one whose read
        -- cannot say, and one read pending once but unreadable since.
        local g=after_stock()
        for ms=200,19800,200 do at(g,ms) end
        returning(g,"19.8 s on the board with the placement still pending is still Returning")
        g.now+=20001;g.tick()
        check(g.entry:status().phase=="blocked" and g.placements==1 and g.toggles==1,"still pending at the deadline blocks")
        local u=after_stock();at(u,100);u.pending=nil
        for ms=300,3000,200 do at(u,ms) end
        returning(u,"an unreadable pending flag never settles")
        u.now+=20001;u.tick()
        check(u.entry:status().phase=="blocked" and u.placements==1,"and blocks at the deadline")
        -- A rider the game is done with who never held on the board, in the air the whole window, goes on at the
        -- deadline ("unconfirmed") and the Return waits for them to come down, as the slammed rider of loop7 did.
        local air=after_stock();lines=logged(air);at(air,100);air.pending=false;air.stock=403;air.watch_air=true;air.actor_air=true
        for ms=300,19900,200 do at(air,ms) end
        returning(air,"a rider in the air never settles")
        air.now+=20001;air.tick()
        check(air.entry:status().phase=="returning" and air.entry:status().return_position==nil
            and has(lines,"Return placement not confirmed in its 20 s window (state 403 pending false")
            and has(lines,"Return waits for the rider") and not has(lines,"off its target"),
            "at the deadline the Return goes on from where the rider is and waits for them")
        air.stock=100;air.watch_air=false;air.actor_air=false;air.tick()
        check(air.entry:status().phase=="skateboard" and air.placements==1 and air.toggles==1,"down on the board, it finishes there")
        -- Cancel during the second still wins.
        local x=after_stock();at(x,100);x.pending=false
        for _,ms in {300,500,700,900} do at(x,ms) end
        check(x.entry:cancel(),"cancel during the second");at(x,1100);at(x,1300)
        check(x.entry:status().phase=="cancelled" and x.placements==1 and x.toggles==1,"a cancelled Return never settles")
        -- A pending flag read unreadable, never true, is not a read of true (as while the game rebuilt the skater at 17.3
        -- in loop7): an early false still waits for 5.1 s, or a queued placement could land after the Return is over.
        local nn=after_stock();nn.pending=nil;at(nn,100);nn.pending=false
        check(nn.entry:status().return_position.pending_seen==false,"an unreadable pending flag is not seen pending")
        for ms=300,2500,200 do at(nn,ms) end
        returning(nn,"a pending flag read unreadable, then false, at 2.5 s is still Returning")
        for ms=2700,5000,200 do at(nn,ms) end
        check((nn.entry:status().return_position.settled_samples or 0)==0,"no read before 5.1 s counts")
        for _,ms in {5100,5300,5500,5700,5900} do at(nn,ms) end
        returning(nn,"800 ms past 5.1 s is not yet a second")
        at(nn,6100);finished(nn,"a second from 5.1 s after the send ends it")
    end)
    case("24 the bike mode setting is the one key a load keeps, and the lines name the controls main.lua picks",function()
        local KEY="bmx_settings_v1"
        local good={schema=1,bike_mode=true}
        local f=fixture({settings_key=KEY,keys={"bmx_bike_lifecycle_v1",KEY,"bmx_equipment_terminal_v1"},values={[KEY]=copy(good)}})
        check(#f.keys==1 and f.keys[1]==KEY and f.values[KEY].bike_mode==true,"the setting is kept and every other key cleared")
        check(f.entry:status().phase=="idle","and Mount is open")
        for i,bad in ipairs({{schema=2,bike_mode=true},{schema=1,bike_mode="on"},{schema=1,bike_mode=true,more=1},{schema=1},"on",true}) do
            local g=fixture({settings_key=KEY,keys={KEY},values={[KEY]=bad}})
            check(#g.keys==0 and g.values[KEY]==nil and g.entry:status().phase=="idle","a malformed setting is cleared: "..i)
        end
        local off=fixture({settings_key=KEY,keys={KEY},values={[KEY]={schema=1,bike_mode=false}}})
        check(#off.keys==1,"off is a setting too, and kept")
        check(#fixture({keys={KEY},values={[KEY]=copy(good)}}).keys==0,"without the option it is cleared like any other key")
        check(#fixture({settings_key="bmx settings",keys={"bmx settings"},values={["bmx settings"]=copy(good)}}).keys==0,
            "a key name that is not one plain word is no option")
        -- The state the next Mount starts from, which y_button.lua asks every tick.
        check(f.entry:next_start_state()==504,"the first ride starts on foot")
        check(fixture({admitted=false}).entry:next_start_state()==nil,"nothing starts when closed")
        check(f.entry:set_controls("y") and f.entry:set_controls("lb_a") and not f.entry:set_controls("x")
            and not f.entry:set_controls(nil),"two kinds of controls")
        f.overlay=false;f.stock=100
        local mounted,why=f.entry:mount()
        check(not mounted and why=="Step off your skateboard with Y, then hold LB and press A.","LB + A named by default: "..tostring(why))
        check(f.entry:set_controls("y"),"bike mode")
        mounted,why=f.entry:mount()
        check(not mounted and why=="Press Y to get on the bike." and f.entry:help_line()==why,"names Y: "..tostring(why))
        check(f.entry:next_start_state()==504,"a Mount refused for where the rider is still starts on foot")
        f.stock=504
        check(f.entry:mount(),"on foot it goes")
        check(f.entry:next_start_state()==nil,"and while it is busy no other can start")
        f.await_mount();f.tick()
        check(f.entry:status().phase=="riding" and f.entry:next_start_state()==nil,"nor while riding")
    end)
    check(cases==24,"exactly24 focused entry groups authored")
    return {cases=cases,assertions=assertions,game_evidence=false,native_actions=0}
end
return table.freeze(Tests)

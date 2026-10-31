-- Test-only exact-main wrapper and constructor/event/menu wiring. No game APIs.
local Main=require("./playable_main_fixture")
local ScoreHUD=require("./score_hud")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn) cases+=1;local ok,why=pcall(fn);assert(ok,name..": "..tostring(why)) end
    local function setup()
        local f={new_calls=0,callbacks={},buttons={},mounts=0,returns=0,recovers=0,cancels=0,steps=0,unloads=0,status_reads=0,requires={},binds={},notes={}}
        local Runtime,Survey={},{}
        local controller={}
        function controller:mount() f.mounts+=1;return false,"closed" end
        function controller:return_to_skateboard() f.returns+=1;return false,"not mounted" end
        function controller:recover()
            f.recovers+=1
            if f.report and f.report.recovery_available==true then
                f.report.recovery_available=false;f.report.recovery_pending=true;return true
            end
            return false,"not eligible"
        end
        function controller:cancel() f.cancels+=1;return true end
        function controller:step(dt) f.steps+=1;f.last_dt=dt end
        function controller:unload() f.unloads+=1 end
        function controller:score_view() return nil,"ride_unavailable","unavailable" end
        function controller:status()
            f.status_reads+=1
            if f.report then return f.report end
            return {phase="idle",detail="closed",admitted=false,core_phase="idle",cleanup_pending=false,cleanup_unknown=false}
        end
        local R={menu={},input={}}
        function R.input.bind(name,key) f.binds[#f.binds+1]={name=name,key=key};return true end
        function R.on(event,fn) check(f.callbacks[event]==nil,"one callback per event");f.callbacks[event]=fn end
        function R.menu.page(name,fn) f.page=name;f.menu=fn end
        local E={}
        function E.new(actual,run,survey,options)
            f.new_calls+=1;check(actual==R and run==Runtime and survey==Survey,"main binds exact service/runtime/survey modules")
            check(options.admitted==false and options.slot==0,"source admission stays closed and slot unchanged")
            return controller
        end
        local modules={["./bike_runtime"]=Runtime,["./ride_r1_record"]=Survey,["./bmx_playable_entry"]=E,["./score_hud"]=ScoreHUD}
        local function require_one(name) check(modules[name]~=nil,"no undeclared main dependency");f.requires[#f.requires+1]=name;return modules[name] end
        Main(R,require_one)
        local ui={}
        function ui:warn(_) end;function ui:note(text) f.notes[#f.notes+1]=text end;function ui:info(_,_) end
        function ui:button(id,_) return f.buttons[id]==true end
        f.ui=ui;return f
    end
    case("one inert controller and four declared Lua dependencies",function()
        local f=setup();check(f.new_calls==1 and #f.requires==4,"main creates one owner coordinator once")
        check(type(f.callbacks.tick)=="function" and type(f.callbacks.draw)=="function" and type(f.callbacks.unload)=="function" and type(f.callbacks.action)=="function" and type(f.menu)=="function","entry binds normal events/menu")
    end)
    case("explicit Mount Return Cancel reach the same controller",function()
        local f=setup();f.menu(f.ui);check(f.mounts==0 and f.returns==0 and f.cancels==0,"draw alone dispatches no command")
        f.buttons.bmx_play_mount=true;f.menu(f.ui);f.buttons={}
        f.buttons.bmx_play_return=true;f.menu(f.ui);f.buttons={}
        f.buttons.bmx_play_cancel=true;f.menu(f.ui)
        check(f.mounts==1 and f.returns==1 and f.cancels==1 and f.new_calls==1,"three explicit buttons, no second owner")
    end)
    case("tick and unload delegate without constructing sessions",function()
        local f=setup();for _=1,20 do f.callbacks.tick(16) end;f.callbacks.unload()
        check(f.steps==20 and f.last_dt==16 and f.unloads==1 and f.new_calls==1,"same controller receives ordinary ticks/unload")
    end)
    case("F8 action uses the guarded Return path without opening the menu",function()
        local f=setup()
        check(#f.binds==5 and f.binds[1].name=="bmx_return" and f.binds[1].key=="F8","F8 default remains alongside recovery; remapping belongs to Binds")
        check(f.returns==0 and f.mounts==0 and f.cancels==0 and f.steps==0 and #f.notes==0,"registration dispatches no lifecycle command or menu draw")
        f.callbacks.action("another_action");f.callbacks.action(nil);f.callbacks.action({name="bmx_return"})
        check(f.returns==0 and f.mounts==0 and f.cancels==0,"only the exact action name selects Return")
        f.callbacks.action("bmx_return")
        check(f.returns==1 and f.new_calls==1 and #f.notes==0,"action reaches the existing controller without menu interaction")
        f.callbacks.action("bmx_return")
        check(f.returns==2 and f.mounts==0 and f.cancels==0 and f.steps==0,"guarded refusal is not converted into Mount, Cancel, input or a replacement owner")
        f.buttons.bmx_play_return=true;f.menu(f.ui)
        check(f.returns==3 and f.new_calls==1,"menu and action use the exact same Return method")
        local noted=false
        for _,note in ipairs(f.notes) do if note=="F8: return to skateboard (remappable in Binds)." then noted=true end end
        check(noted,"menu documents the normal gameplay action and remapping")
    end)
    case("F9 requests existing eligible recovery once and is inert after unload",function()
        local f=setup()
        check(#f.binds==5 and f.binds[2].name=="bmx_recover" and f.binds[2].key=="F9","one remappable F9 recovery default")
        check(f.recovers==0 and f.status_reads==0 and f.steps==0 and #f.notes==0,"registration never requests recovery or draws the menu")
        f.report={phase="riding",detail="constructed",admitted=true,core_phase="following",recovery_available=false,
            attempts_used=1,attempt_limit=2,cleanup_pending=false,cleanup_unknown=false}
        f.callbacks.action("bmx_recover")
        check(f.recovers==0 and f.mounts==0 and f.returns==0 and f.cancels==0 and #f.notes==0,"active ride cannot request recovery or menu inspection")
        f.report.phase="fallen";f.report.recovery_available=nil
        f.callbacks.action("bmx_recover");f.callbacks.action({name="bmx_recover"});f.callbacks.action("another_action")
        f.report.recovery_available=1;f.callbacks.action("bmx_recover")
        f.report.recovery_available="true";f.callbacks.action("bmx_recover")
        check(f.recovers==0,"missing/nonboolean eligibility and nonmatching actions never reach Recover")
        f.report.recovery_available=true;f.report.fall_reason="constructed measured tilt stop"
        f.callbacks.action("bmx_recover")
        check(f.recovers==1 and f.report.recovery_pending==true and f.report.recovery_available==false,"eligible key press delegates one existing intent")
        f.callbacks.action("bmx_recover");f.callbacks.action("bmx_recover")
        check(f.recovers==1,"pending intent makes repeated key actions ineligible")
        check(f.new_calls==1 and f.mounts==0 and f.returns==0 and f.cancels==0 and f.steps==0 and #f.notes==0,
            "direct key creates no owner, direct Mount/Return, tick or menu work")
        f.menu(f.ui)
        local noted=false
        for _,note in ipairs(f.notes) do if note=="F9: recover bike after a fall (remappable in Binds)." then noted=true end end
        check(noted and f.recovers==1,"visible F9 instruction draws without automatic recovery")
        f.report.recovery_available=true
        local reads,notes=f.status_reads,#f.notes
        f.callbacks.unload();f.callbacks.action("bmx_recover")
        check(f.unloads==1 and f.recovers==1,"unload disables even a late key callback with stale eligible status")
        check(f.status_reads==reads and #f.notes==notes and f.returns==0 and f.mounts==0,
            "late key callback performs no status, menu or lifecycle work")
    end)
    case("controller recovery shares exact eligibility and pending intent with F9",function()
        local f=setup()
        check(#f.binds==5 and f.binds[3].name=="bmx_recover_pad" and f.binds[3].key=="Pad.LB+Pad.RB+Pad.L3",
            "separate remappable controller action preserves the F8/F9 defaults")
        f.report={phase="riding",detail="constructed",admitted=true,core_phase="following",recovery_available=false,
            attempts_used=1,attempt_limit=2,cleanup_pending=false,cleanup_unknown=false}
        f.callbacks.action("bmx_recover_pad")
        check(f.recovers==0,"controller action cannot request recovery while riding")
        f.report.phase="fallen";f.report.recovery_available=1;f.callbacks.action("bmx_recover_pad")
        f.report.recovery_available=nil;f.callbacks.action("bmx_recover_pad")
        check(f.recovers==0,"controller action uses only exact existing boolean eligibility")
        f.report.recovery_available=true;f.report.fall_reason="constructed measured tilt stop"
        f.callbacks.action("bmx_recover_pad")
        check(f.recovers==1 and f.report.recovery_pending==true and f.report.recovery_available==false,
            "eligible controller action calls the same existing Recover intent")
        f.callbacks.action("bmx_recover_pad");f.callbacks.action("bmx_recover")
        check(f.recovers==1,"controller repeat and F9 cannot duplicate the same pending intent")
        check(f.new_calls==1 and f.mounts==0 and f.returns==0 and f.cancels==0 and f.steps==0 and #f.notes==0,
            "controller action adds no owner, direct Mount/Return, tick or menu work")
        f.menu(f.ui);local noted=false
        for _,note in ipairs(f.notes) do
            if note=="LB + RB + L3: recover after a fall; release all controls while recovery runs (remappable in Binds)." then noted=true end
        end
        check(noted and f.recovers==1,"controller instruction does not auto-recover")
        f.report.recovery_available=true;local reads=f.status_reads
        f.callbacks.unload();f.callbacks.action("bmx_recover_pad");f.callbacks.action("bmx_recover")
        check(f.unloads==1 and f.recovers==1 and f.status_reads==reads,"unload blocks both late recovery actions before status or intent calls")
    end)
    case("controller Return uses the exact F8 path without a menu or ride input step",function()
        local f=setup()
        check(#f.binds==5 and f.binds[4].name=="bmx_return_pad" and f.binds[4].key=="Pad.LB+Pad.RB+Pad.R3",
            "separate remappable Return chord preserves all earlier binding defaults")
        check(f.returns==0 and f.mounts==0 and f.recovers==0 and f.steps==0 and f.status_reads==0,
            "registering the Return chord performs no lifecycle or input work")
        f.callbacks.action("Pad.LB+Pad.RB+Pad.R3");f.callbacks.action({name="bmx_return_pad"});f.callbacks.action(nil)
        check(f.returns==0 and f.status_reads==0,"only the action identity selects Return; raw or remapped key text is not a command")
        f.callbacks.action("bmx_return_pad")
        check(f.returns==1 and f.new_calls==1 and f.status_reads==0 and f.steps==0 and #f.notes==0,
            "the chord directly invokes the existing guarded Entry Return before any tick or menu")
        f.callbacks.action("bmx_return");f.callbacks.action("bmx_return_pad")
        check(f.returns==3 and f.mounts==0 and f.recovers==0 and f.cancels==0 and f.steps==0,
            "F8 and the pad action share refusal semantics without a replacement owner, recovery or input step")
        f.menu(f.ui);local noted=false
        for _,note in ipairs(f.notes) do
            if note=="Hold LB + RB, then click R3 to return to skateboard. Release all controls while Return runs (remappable in Binds)." then noted=true end
        end
        check(noted and f.returns==3,"drawing the press-order and release instruction never repeats Return")
        f.callbacks.unload()
        check(f.unloads==1 and f.new_calls==1 and f.returns==3 and f.steps==0,"unload delegates cleanup to the same existing Entry")
        check(#f.binds==5 and f.mounts==0 and f.recovers==0 and f.cancels==0,
            "events and unload add no rebindings or alternate lifecycle actions; SDK owns binding cleanup")
    end)
    case("controller Mount requests the existing guarded intent without a menu or input step",function()
        local f=setup()
        check(#f.binds==5 and f.binds[5].name=="bmx_mount_pad" and f.binds[5].key=="Pad.LB+Pad.A",
            "a separate remappable Mount action preserves the Return and recovery defaults")
        check(f.mounts==0 and f.returns==0 and f.recovers==0 and f.steps==0 and f.status_reads==0,
            "registration never requests Mount or bypasses the closed source constructor")
        f.callbacks.action("Pad.LB+Pad.A");f.callbacks.action({name="bmx_mount_pad"});f.callbacks.action(nil)
        check(f.mounts==0 and f.status_reads==0,"only the stable Mount action name selects the intent after any remap")
        f.callbacks.action("bmx_mount_pad")
        check(f.mounts==1 and f.new_calls==1 and f.status_reads==0 and f.steps==0 and #f.notes==0,
            "the action calls the same Entry Mount directly without a new owner, authority latch or tick")
        f.callbacks.action("bmx_mount_pad")
        check(f.mounts==2 and f.returns==0 and f.recovers==0 and f.cancels==0 and f.steps==0,
            "a separately delivered explicit event preserves Entry refusal instead of queuing an automatic retry")
        f.buttons.bmx_play_mount=true;f.menu(f.ui);f.buttons={}
        check(f.mounts==3 and f.new_calls==1,"the menu button and controller action use exactly the same guarded Mount method")
        local noted=false
        for _,note in ipairs(f.notes) do
            if note=="Hold LB, then press A to request Mount. Start on foot and release all controls while preparing (remappable in Binds)." then noted=true end
        end
        check(noted and f.mounts==3,"the on-foot and release instruction performs no automatic Mount")
        f.callbacks.unload()
        check(f.unloads==1 and f.new_calls==1 and f.mounts==3 and f.returns==0 and f.cancels==0 and #f.binds==5,
            "unload uses the existing Entry and SDK binding cleanup without an alternate lifecycle")
    end)
    return {cases=cases,assertions=assertions,game_evidence=false,native_actions=0}
end
return table.freeze(Tests)

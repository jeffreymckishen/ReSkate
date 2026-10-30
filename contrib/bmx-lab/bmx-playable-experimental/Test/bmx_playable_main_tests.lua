-- Test-only exact-main wrapper and constructor/event/menu wiring. No game APIs.
local Main=require("./playable_main_fixture")
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
        local modules={["./bike_runtime"]=Runtime,["./ride_r1_record"]=Survey,["./bmx_playable_entry"]=E}
        local function require_one(name) check(modules[name]~=nil,"no undeclared main dependency");f.requires[#f.requires+1]=name;return modules[name] end
        Main(R,require_one)
        local ui={}
        function ui:warn(_) end;function ui:note(text) f.notes[#f.notes+1]=text end;function ui:info(_,_) end
        function ui:button(id,_) return f.buttons[id]==true end
        f.ui=ui;return f
    end
    case("one inert controller and three declared Lua dependencies",function()
        local f=setup();check(f.new_calls==1 and #f.requires==3,"main creates one owner coordinator once")
        check(type(f.callbacks.tick)=="function" and type(f.callbacks.unload)=="function" and type(f.callbacks.action)=="function" and type(f.menu)=="function","entry binds normal events/menu")
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
        check(#f.binds==2 and f.binds[1].name=="bmx_return" and f.binds[1].key=="F8","F8 default remains alongside recovery; remapping belongs to Binds")
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
        check(#f.binds==2 and f.binds[2].name=="bmx_recover" and f.binds[2].key=="F9","one remappable F9 recovery default")
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
    return {cases=cases,assertions=assertions,game_evidence=false,native_actions=0}
end
return table.freeze(Tests)

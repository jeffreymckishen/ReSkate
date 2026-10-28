-- Test-only exact-main wrapper and constructor/event/menu wiring. No game APIs.
local Main=require("./playable_main_fixture")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn) cases+=1;local ok,why=pcall(fn);assert(ok,name..": "..tostring(why)) end
    local function setup()
        local f={new_calls=0,callbacks={},buttons={},mounts=0,returns=0,cancels=0,steps=0,unloads=0,requires={}}
        local Runtime,Survey={},{}
        local controller={}
        function controller:mount() f.mounts+=1;return false,"closed" end
        function controller:return_to_skateboard() f.returns+=1;return false,"not mounted" end
        function controller:cancel() f.cancels+=1;return true end
        function controller:step(dt) f.steps+=1;f.last_dt=dt end
        function controller:unload() f.unloads+=1 end
        function controller:status() return {phase="idle",detail="closed",admitted=false,core_phase="idle",cleanup_pending=false,cleanup_unknown=false} end
        local R={menu={}}
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
        function ui:warn(_) end;function ui:note(_) end;function ui:info(_,_) end
        function ui:button(id,_) return f.buttons[id]==true end
        f.ui=ui;return f
    end
    case("one inert controller and three declared Lua dependencies",function()
        local f=setup();check(f.new_calls==1 and #f.requires==3,"main creates one owner coordinator once")
        check(type(f.callbacks.tick)=="function" and type(f.callbacks.unload)=="function" and type(f.menu)=="function","entry binds normal events/menu")
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
    return {cases=cases,assertions=assertions,game_evidence=false,native_actions=0}
end
return table.freeze(Tests)

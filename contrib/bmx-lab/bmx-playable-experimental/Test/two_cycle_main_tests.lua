local Main=require("./playable_main_fixture")
local T={}
function T.run()
    local n=0;local function check(v,why)n+=1;assert(v,why)end
    local R={menu={},input={}};local count=0
    function R.input.bind(name,key)
        check(name=="bmx_return" and key=="F8" or name=="bmx_recover" and key=="F9"
            or name=="bmx_recover_pad" and key=="Pad.LB+Pad.RB+Pad.L3","exact remappable Return/Recover defaults")
        return true
    end
    local object={step=function()end,unload=function()end,status=function()return {phase="idle",detail="source closed",admitted=false,
        core_phase="idle",attempts_used=0,attempt_limit=2,cleanup_pending=false,cleanup_unknown=false}end}
    function R.on(name,fn)check((name=="tick" or name=="unload" or name=="action")and type(fn)=="function","normal callbacks only")end
    function R.menu.page(name,fn)check(name=="BMX experimental" and type(fn)=="function","same explicit menu")end
    local Runtime,Survey={},{}
    local E={new=function(actual,r,s,options)
        count+=1;check(actual==R and r==Runtime and s==Survey,"exact dependencies")
        check(options.admitted==false and options.slot==0 and options.experimental_two_cycle==true,
            "only this closed experimental Main selects the private bounded manager")
        return object
    end}
    local modules={["./bike_runtime"]=Runtime,["./ride_r1_record"]=Survey,["./bmx_playable_entry"]=E}
    Main(R,function(name)check(modules[name]~=nil,"no new SDK or module dependency");return modules[name]end)
    check(count==1,"one inert manager is constructed once")
    return {cases=1,assertions=n,native_authority=false,constructed=true}
end
return T

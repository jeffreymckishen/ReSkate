local Support=require("./two_cycle_facade_test_support")
local Wrapper=require("./two_cycle_facade_fixture")
local Admission=require("./bike_admission")
local T={}
function T.run()
    local n=0;local function check(v,why)n+=1;assert(v,why)end
    do
        local reads,native,imports,records={},0,{},{}
        local services={time={},input={},menu={},skater={},level={},storage={},json={},entities={},world={physics={}}}
        local function note(name) reads[name]=(reads[name] or 0)+1 end
        local function forbidden() native+=1;error("admission must not reach native authority",0) end
        local function install(path)
            local at=services;local names=string.split(path,".")
            for i=1,#names-1 do at[names[i]]=at[names[i]] or {};at=at[names[i]] end
            at[names[#names]]=forbidden
        end
        for _,path in ipairs(Admission.required) do install(path) end
        for _,name in ipairs(Admission.input_methods) do services.input[name]=forbidden end
        function services.time.now() note("time.now");return 1000 end
        function services.input.focus() note("input.focus");return {focused=true,gameplay=true,interface_open=false} end
        function services.input.allowed() note("input.allowed");return true end
        function services.menu.game() note("menu.game");return {open=false} end
        function services.skater.get() note("skater.get");return {position=vector.create(0,0,0),heading=0,airborne=false} end
        function services.skater.telemetry() note("skater.telemetry");return {skater=true,airborne=true,teleport_pending=false,
            watch={valid=true,state=504,ragdoll_known=true,ragdoll=false,wipeouts=0}} end
        function services.level.current() note("level.current");return {name="constructed"} end
        function services.storage.get() return nil end
        function services.storage.set(key,value) records[key]=value end
        function services.json.encode() return "constructed bounded diagnostic" end
        local Runtime=Wrapper(function(name)
            imports[#imports+1]=name
            if name=="./bike_admission" then return Admission end
            error("refused admission must not load a Core or backend",0)
        end)
        local owner=Runtime.new(services,{qualification_only=true})
        check(not owner:request_mount(0),"actual admission still refuses mixed airborne readiness")
        local state=owner:status();local d=state.startup.admission
        check(d and d.clear and d.api_available and d.clock_present and d.generation_match and not d.unloaded
            and not d.storage_fault and not d.clock_unknown and not d.ready and not d.accepted,
            "diagnostic separates every first admission gate without accepting a failed term")
        check(d.facts.focused and d.facts.gameplay and d.facts.upright_stock and not d.facts.grounded and d.facts.state==504,
            "the already-computed readiness facts identify grounded as the exact refusal")
        check(d.fact_read.stage=="decoded" and d.fact_read.position_airborne==false and d.fact_read.telemetry_airborne==true,
            "the diagnostic retains the two actual sampled airborne facts rather than inferring an input cause")
        check(d.fact_read.focus_return and d.fact_read.allowed_return and d.fact_read.menu_return
            and d.fact_read.skater_return and d.fact_read.telemetry_return and d.fact_read.level_return,
            "all six existing fact call contracts are independently visible")
        check(reads["input.focus"]==1 and reads["input.allowed"]==1 and reads["menu.game"]==1 and reads["skater.get"]==1
            and reads["skater.telemetry"]==1 and reads["level.current"]==1 and reads["time.now"]==2,
            "diagnostics add no SDK fact or clock reads")
        check(state.phase=="done" and not state.startup.pending and state.startup.loaded==1
            and not state.startup.core_ready and #imports==1 and native==0,"refusal still ends at admission with no Core, source or body")
        check(records.bmx_bike_lifecycle_v1.startup.admission.ready==false,"the existing refusal persist carries its computed diagnostic")
        d.facts.focused=false;d.fact_read.telemetry_airborne=false
        check(owner:status().startup.admission.facts.focused and owner:status().startup.admission.fact_read.telemetry_airborne,
            "nested diagnostic snapshots are detached from the owner and subsequent snapshots")
        check(not owner:request_mount(0) and reads["input.focus"]==1 and native==0,"the diagnostic creates no retry or native authority")
    end
    local f=Support.new(check)
    f.old.stop_at=2000
    check(f.manager:prepare_next_mount(0),"second preparation admitted")
    f.done504=true;f.state=504;f.old.phase="done"
    f.on_marker=function()check(not f.manager:request_mount(0),"nested Mount cannot admit another owner")end
    check(not f.manager:request_mount(0),"reentry in new-marker callback closes outer admission")
    check(f.aborted and f.core_count==1 and f.old.retired,"no successor after nested admission callback")
    check(f.old.stop_at==2000,"original stopped cycle watchdog anchor is never rewritten")
    check(not f.manager:request_mount(0),"spent private epoch cannot retry after reentry")
    return {cases=1,assertions=n,constructed=true,native_authority=false}
end
return T

-- Real public deferred BikeRuntime/Core/Equipment modules; injected SDK-shaped services only.
local Runtime=require("./bike_runtime")
local tests={}
function tests.run()
    local checks=0
    local function check(v,why) checks+=1;assert(v,why) end
    local f={now=1000,progress_writes=0,pulses=0,native=0}
    local s={time={},input={},skater={},level={},storage={},json={},menu={},entities={},world={physics={}}}
    function s.time.now() return f.now end
    function s.input.focus() return {focused=true,interface_open=true,gameplay=true} end
    function s.input.allowed() return true end
    function s.menu.game() return {open=true} end
    function s.skater.get() return {airborne=false,position=vector.create(0,0,0),heading=0} end
    function s.skater.telemetry() return {skater=true,airborne=false,teleport_pending=false,
        watch={valid=true,state=504,ragdoll_known=true,ragdoll=false,wipeouts=0}} end
    function s.level.current() return {name="sanvan"} end
    function s.storage.get() return nil end
    function s.json.encode() return "bounded constructed encoding" end
    function s.storage.set(key)
        check(key=="bmx_equipment_runtime_v1","failure is the actual pending-arm progress write")
        f.progress_writes+=1
        error("constructed progress cache failure",0)
    end
    function s.input.pulse() f.pulses+=1;error("a refused arm must never pulse",0) end
    local function forbidden() f.native+=1;error("no bike/native path is allowed",0) end
    for _,k in {"bounds","set","status","remove"} do s.entities[k]=forbidden end
    for _,k in {"create","read","release","reserve_follow","publish_follow","read_follow","stop_follow","acknowledge_follow"} do s.world.physics[k]=forbidden end
    local owner=Runtime.new(s) -- Default public wiring; never qualification_only or a fabricated clean owner.
    check(owner:status().mount_enabled==false,"public mounting stays unavailable")
    check(owner:request_stock_toggle(0),"actual public stock intent enters deferred startup")
    local out
    for _=1,10 do
        f.now+=16;out=owner:step(16)
        if not out.startup.pending then break end
    end
    check(out.startup.core_ready and out.startup.loaded>=3,"real delayed module handoff completed")
    check(out.phase=="idle" and out.stock_requested==false,"known pre-pulse failure restores public idle phase")
    check(f.progress_writes==1 and f.pulses==0 and f.native==0,"one failed progress write, no input or native action")
    check(out.equipment.detail:find("Progress cache failed",1,true)~=nil,"actual adapter latched its permanent cache fault")
    check(out.stock_toggle_blocked==true,"permanently faulted equipment must block future public stock requests")
    check(out.equipment.storage_fault==true,"fault is visible in the detached equipment status")
    check(out.cleanup_unknown==false and out.bike_authority==false,"known no-pulse failure is not fabricated native cleanup debt")
    check(not owner:request_stock_toggle(0),"later explicit request refuses at the owner gate")
    check(f.progress_writes==1 and f.pulses==0 and f.native==0,"no replacement, cache retry or actuation after permanent fault")
    return {cases=1,assertions=checks,native_actions=0}
end
return tests

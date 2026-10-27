-- One real mount per independently generated Core module; no latch reset.
local Core=require("./bike_runtime_core")
local Admission=require("./bike_admission")
local Provisional=require("./bike_runtime_core_provisional_follow_fixture")
local Renewal=require("./bike_runtime_core_follow_renewal_fixture")
local Lead=require("./bike_runtime_core_follow_lead_fixture")
local Guard=require("./bike_runtime_core_ride_guard_fixture")
local Mounted=require("./bike_runtime_core_mounted_pose_fixture")
local Trick=require("./bike_runtime_core_trick_wiring_fixture")
local Floor=require("./bike_spawn_floor_qualified_fixture")
local Fixture=require("./core_native_prepare_fixture")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local entries={
        {Core,function() return false,"owned bodies require the current local client phase outside multiplayer" end},
        {Provisional,function() error("constructed world.physics permission denial",0) end},
        {Renewal,function() return true,"extra result" end},
        {Lead,function() return false end},
        {Guard,function() return false,"asked to prepare native bodies more than once in one tick" end},
        {Mounted,function() return false,Fixture.setup_pending,nil end},
    }
    for _,entry in entries do
        cases+=1
        local f=Fixture.new(entry[1],Floor,entry[2])
        check(f.arm(),"constructed mount admitted before preparation response")
        local out=f.tick()
        check(out.stop_latched and out.native_preparation.phase=="refused"
            and out.native_preparation.attempts==1 and out.native_preparation.ready_ms==nil,
            "denied, thrown or malformed result is terminal and never ready")
        check(f.unacquired(),"refusal creates no input, visual, floor or body duty")
        for _=1,3 do f.tick() end
        check(f.prepares==1 and f.unacquired() and not f.core:request_mount(0),
            "refusal never retries preparation or resets mount admission")
    end
    cases+=1 do
        local f=Fixture.new(Trick,Floor)
        f.sdk.world.physics.prepare=nil
        local admission={counts={},calls={},omitted_calls=0}
        local available,missing=Admission.bind(admission,f.sdk,true).available()
        check(not available and missing=="world.physics.prepare" and #admission.calls==0 and next(f.calls)==nil,
            "facade admission rejects missing preparation by lookup without calling services")
        local accepted,_,out=f.arm()
        check(not accepted and out.stop_latched and f.prepares==0 and f.unacquired(),
            "missing required API closes admission before any preparation call")
        check(string.find(out.stop_reason,"world.physics.prepare",1,true)~=nil,
            "missing preparation names the unavailable API")
    end
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)
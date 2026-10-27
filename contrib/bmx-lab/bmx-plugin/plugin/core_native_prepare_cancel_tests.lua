-- Late successful callbacks cannot revive the original cancelled owner.
local Core=require("./bike_runtime_core")
local Provisional=require("./bike_runtime_core_provisional_follow_fixture")
local Renewal=require("./bike_runtime_core_follow_renewal_fixture")
local Lead=require("./bike_runtime_core_follow_lead_fixture")
local Guard=require("./bike_runtime_core_ride_guard_fixture")
local Mounted=require("./bike_runtime_core_mounted_pose_fixture")
local Floor=require("./bike_spawn_floor_qualified_fixture")
local Fixture=require("./core_native_prepare_fixture")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local entries={
        {Core,function(f) f.core:request_stop("stop inside prepare") end},
        {Provisional,function(f) f.core:unload() end},
        {Renewal,function(f) f.core:step(16) end},
        {Lead,function(f) f.core:request_mount(0) end},
        {Guard,function(f) f.focused=false end},
        {Mounted,function(f) f.now+=60000 end},
    }
    for _,entry in entries do
        cases+=1
        local f=Fixture.new(entry[1],Floor,function(state) entry[2](state);return true end)
        check(f.arm(),"constructed mount is admitted")
        local out=f.tick()
        check(out.stop_latched and out.native_preparation.phase=="cancelled"
            and out.native_preparation.ready_ms==nil and f.prepares==1,
            "late true is discarded after Stop, unload, reentrancy, readiness loss or deadline")
        check(f.unacquired(),"cancelled callback cannot acquire any input, visual or body")
        for _=1,3 do f.tick() end
        check(f.prepares==1 and f.unacquired() and not f.core:request_mount(0),
            "cancelled owner stays consumed after later ticks")
    end
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)
-- Fresh admission is checked after prepare and again before acquisition.
local Core=require("./bike_runtime_core")
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
    for _,entry in {
        {Core,function(f) f.level="another-level" end},
        {Provisional,function(f) f.state=100 end},
        {Renewal,function(f) f.wipeouts+=1 end},
        {Lead,function(f) f.menu_open=true end},
    } do
        cases+=1
        local f=Fixture.new(entry[1],Floor,function(state) entry[2](state);return true end)
        check(f.arm(),"mount admits the original upright context")
        local out=f.tick()
        check(out.stop_latched and out.native_preparation.phase=="cancelled"
            and out.native_preparation.ready_ms==nil and f.unacquired(),
            "post-callback level, stock state, wipeout or menu drift discards ready")
        f.tick()
        check(f.prepares==1 and f.unacquired(),"changed context cannot trigger a retry")
    end
    cases+=1 do
        local f=Fixture.new(Guard,Floor)
        check(f.arm(),"mount before ready-to-acquire boundary")
        local out=f.tick()
        check(out.native_preparation.phase=="ready" and f.unacquired(),"ready is sampled before later acquisition")
        f.focused=false
        out=f.tick()
        check(out.stop_latched and f.unacquired() and f.prepares==1,
            "historical ready cannot replace fresh readiness on the following tick")
    end
    for _,entry in {{Mounted,-16},{Trick,0/0}} do
        cases+=1
        local f=Fixture.new(entry[1],Floor,function() return false,Fixture.step_pending end)
        check(f.arm(),"invalid dt case admits a real pending mount")
        f.tick()
        -- Advance the valid clock independently so no clock failure masks dt.
        f.now+=16;f.host_tick+=1
        local out=f.core:step(entry[2])
        check(out.stop_latched and not out.clock_unknown and f.prepares==1
            and out.native_preparation.attempts==1 and f.unacquired(),
            "negative or nonfinite dt cannot use the inert setup-gap exception")
    end
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)
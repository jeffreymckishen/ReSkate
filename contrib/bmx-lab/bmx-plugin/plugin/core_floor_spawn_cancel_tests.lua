-- Fresh suite VM for cancellation during the real Core-to-Spawn floor call.
local Core=require("./bike_runtime_core")
local TrialCore=require("./bike_runtime_core_provisional_follow_fixture")
local TrialSpawn=require("./bike_spawn_floor_qualified_fixture")
local Fixture=require("./core_floor_spawn_fixture")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    for _,entry in {{Core,"cancel"},{TrialCore,"reenter"}} do
        cases+=1
        local f=Fixture.new(entry[1],TrialSpawn,entry[2])
        local out=f.drive()
        check(f.rays==1 and out.call_counts["spawn.world.raycast"]==1,"the real callback is counted once")
        check(out.stop_latched and f.spawn:status().phase=="closed","callback cancellation stays closed after the late hit")
        check(not f.body and #f.reserves==0 and not f.calls["entities.set"],"no post-cancel visuals, body or reservation")
        check(not pcall(f.proxy.world.raycast,f.ray_from,f.ray_to) and f.rays==1,"a stopped owner cannot issue another SDK ray")
        local done=f.drain()
        check(f.rays==1 and not f.body and #f.releases==0 and next(f.forbidden)==nil,"cleanup introduces no native duty")
        check(done.source and done.source.phase=="complete" and not done.cleanup_unknown,"actual Source drains after callback cancellation")
    end
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)
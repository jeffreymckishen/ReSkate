-- Fresh suite VM for absent permission/API and an SDK callback exception.
local Core=require("./bike_runtime_core")
local TrialCore=require("./bike_runtime_core_provisional_follow_fixture")
local TrialSpawn=require("./bike_spawn_floor_qualified_fixture")
local Fixture=require("./core_floor_spawn_fixture")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    for _,entry in {{Core,"missing"},{TrialCore,"throw"}} do
        cases+=1
        local missing=entry[2]=="missing"
        local f=Fixture.new(entry[1],TrialSpawn,entry[2])
        local out=f.drive()
        check((f.proxy.world.raycast==nil)==missing,"no proxy is invented for an absent SDK function")
        check(f.rays==(missing and 0 or 1) and (out.call_counts["spawn.world.raycast"] or 0)==f.rays,"refusal call accounting is exact")
        check(out.stop_latched and f.spawn:status().phase=="closed","failure ends the real spawn path")
        check(not f.body and #f.reserves==0 and not f.calls["entities.set"],"failure cannot publish visuals or allocate")
        check(f.spawn:status().detail== (missing and "floor ray API unavailable" or "floor ray refused or failed: spawn floor ray callback failed"),
            "missing API and callback exception remain distinguishable")
        local done=f.drain()
        check(f.rays==(missing and 0 or 1) and #f.releases==0 and next(f.forbidden)==nil,"no fallback or retry invents body duty")
        check(done.source and done.source.phase=="complete" and not done.cleanup_unknown,"actual Source cleanup completes after refusal")
    end
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)
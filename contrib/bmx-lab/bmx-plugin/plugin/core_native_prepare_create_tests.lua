-- Sampled preparation success never promises that later creation can succeed.
local Core=require("./bike_runtime_core")
local OtherCore=require("./bike_runtime_core_provisional_follow_fixture")
local Floor=require("./bike_spawn_floor_qualified_fixture")
local Fixture=require("./core_native_prepare_fixture")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    for _,entry in {
        {Core,function() return nil,"body_preallocation_unavailable" end,false},
        {OtherCore,function() error("constructed uncertain create",0) end,true},
    } do
        cases+=1
        local f=Fixture.new(entry[1],Floor)
        f.create_reply=entry[2]
        check(f.arm(),"mount is admitted")
        local out=f.until_status(function(row) return row.stop_latched end)
        check(out.stop_latched and out.native_preparation.phase=="ready"
            and f.prepares==1 and f.rays==1 and f.creates==1,
            "later create refusal consumes the already queried floor exactly once")
        check(not f.body and #f.reserves==0 and not out.publish_attempted,
            "failed create cannot invent a body or Follow authority")
        if entry[3] then
            check(out.spawn.creation_unknown==true,"throwing create preserves unknown allocation duty")
        else
            check(out.spawn.creation_unknown==false and out.spawn.phase~="clock_prepared",
                "known preallocation refusal cannot rearm the floor trial")
        end
        for _=1,12 do f.tick() end
        check(f.prepares==1 and f.rays==1 and f.creates==1 and not f.core:request_mount(0),
            "neither known refusal nor uncertain create restarts warmup, floor or allocation")
    end
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)
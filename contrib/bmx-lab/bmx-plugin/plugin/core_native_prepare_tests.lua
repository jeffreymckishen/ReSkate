-- Constructed readiness and cold-producer progression through actual Core.
local Core=require("./bike_runtime_core")
local OtherCore=require("./bike_runtime_core_provisional_follow_fixture")
local Floor=require("./bike_spawn_floor_qualified_fixture")
local Fixture=require("./core_native_prepare_fixture")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    cases+=1 do
        local f=Fixture.new(Core,Floor)
        local accepted,_,out=f.arm()
        check(accepted and out.phase=="armed" and f.prepares==0 and f.unacquired(),
            "explicit mount remains inert and armed")
        check(out.native_preparation.phase=="pending" and out.native_preparation.attempts==0,
            "pending starts before any preparation call")
        out=f.tick()
        local ready=out.native_preparation.ready_ms
        check(out.native_preparation.phase=="ready" and out.native_preparation.attempts==1
            and ready==f.now and f.unacquired(),"ready consumes its own tick without acquisition")
        for _=1,10 do
            out=f.tick(100)
            check(f.unacquired(),"600ms alone cannot bypass ten later readiness ticks")
        end
        out=f.tick(100)
        check(out.effect_start_ms and out.effect_start_ms>=ready+600,"Source starts only after fresh qualification")
        out=f.until_status(function(row) return #f.reserves>0 or row.stop_latched end)
        check(f.prepares==1 and f.rays==1 and f.creates==1 and #f.reserves==1,
            "one preparation precedes one real floor query, create and reserve")
        check(f.order[1]=="prepare" and f.order[2]=="lease","native readiness precedes input ownership")
        check(out.reserve_refused and not out.publish_attempted,"existing known reserve refusal still closes safely")
        f.until_status(function(row) return row.bike_cleanup_complete end,20)
        check(f.prepares==1 and f.rays==1 and f.creates==1,"cleanup does not retry preparation or allocation")
    end
    cases+=1 do
        local f=Fixture.new(OtherCore,Floor,function(state)
            if state.prepares==1 then return false,Fixture.setup_pending end
            if state.prepares==2 then return false,Fixture.step_pending end
            return true
        end)
        f.state=100
        local accepted,_,out=f.arm()
        check(accepted and f.prepares==0 and not out.call_counts["equipment.request"],
            "board admission defers equipment until native readiness")
        for index,reason in {Fixture.setup_pending,Fixture.step_pending} do
            out=f.tick()
            check(out.native_preparation.phase=="pending" and out.native_preparation.attempts==index
                and out.native_preparation.reason==reason and f.unacquired(),
                "only the exact pending reason waits without acquisition")
            check(not out.call_counts["equipment.request"],"pending preparation cannot start equipment")
        end
        out=f.tick()
        check(out.native_preparation.phase=="ready" and f.prepares==3 and f.unacquired()
            and not out.call_counts["equipment.request"],"late readiness still yields before equipment")
        f.core:request_stop("test ends before stock acquisition")
        f.tick()
        check(f.unacquired() and f.prepares==3 and not f.core:request_mount(0),
            "Stop consumes the existing mount attempt without a retry")
    end
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)
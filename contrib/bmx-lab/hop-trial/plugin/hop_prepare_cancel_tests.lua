-- Real facade/Core in a fresh suite VM. No attempt latch is reset or adopted.
local Runtime=require("./bike_runtime")
local Services=require("./hop_services")
local Composition=require("./hop_composition_tests")
local Tests={}
function Tests.run()
    local assertions=0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local f=Composition.ready_services()
    local observed={}
    local context={}
    function context:observe_service(path,args,result)
        observed[#observed+1]={path=path,args=args,result=result};return true
    end
    function context:request_stop() error("observer must not independently fail",0) end
    local wrapped=Services.wrap(f.services,context)
    local owner=Runtime.new(wrapped,{qualification_only=true})
    check(owner:request_mount(0),"explicit request enters real facade admission")
    local state
    for _=1,40 do
        f.now+=16;state=owner:step(16)
        if not state.startup.pending then break end
    end
    check(state.phase=="armed" and f.prepares==0 and f.native==0,
        "open menus preserve inert staging and native preparation has not started")
    f.menu_open=false
    f.on_prepare=function()
        check(owner:request_stop("cancel inside preparation"),"reentrant Stop reaches the real owner")
        return true
    end
    f.now+=16;state=owner:step(16)
    check(f.prepares==1 and f.native==0 and state.stop_latched
        and state.native_preparation.phase=="cancelled" and state.native_preparation.ready_ms==nil,
        "a late successful SDK return cannot revive cancelled preparation")
    check(not state.call_counts["source.arm"] and not state.call_counts["spawn.request"]
        and not state.call_counts["equipment.request"],"cancellation precedes every acquisition owner")
    local calls=0
    for _,row in ipairs(observed) do
        if row.path=="world.physics.prepare" then
            calls+=1
            check(row.args.n==0 and row.result.n==2 and row.result[1] and row.result[2],
                "the observer records the actual late return without converting it into acquisition")
        end
    end
    check(calls==1,"one SDK call is observed once")
    for _=1,5 do f.now+=16;owner:step(16) end
    check(f.prepares==1 and f.native==0 and not owner:request_mount(0),
        "later ticks and another click cannot retry or rearm the cancelled intent")
    state=owner:unload()
    check(state.unloaded and f.prepares==1 and f.native==0,"unload adds no preparation or native acquisition")
    return {cases=1,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)

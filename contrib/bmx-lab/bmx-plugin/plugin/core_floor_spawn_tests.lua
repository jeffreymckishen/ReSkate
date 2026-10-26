-- Both literal settings through real public Core mount, Source and Spawn.
-- Existing generated copies keep the runner unchanged and production gates off.
local Core=require("./bike_runtime_core")
local TrialCore=require("./bike_runtime_core_provisional_follow_fixture")
local Spawn=require("./bike_spawn")
local TrialSpawn=require("./bike_spawn_floor_qualified_fixture")
local Fixture=require("./core_floor_spawn_fixture")
local Visual=require("./bike_visual")
local G=require("./bike_geometry")
local Tests={}
local function equal(a,b)
    if typeof(a)~=typeof(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    for _,entry in {{Core,Spawn,false},{TrialCore,TrialSpawn,true}} do
        cases+=1
        local trial=entry[3]
        local f=Fixture.new(entry[1],entry[2])
        local out=f.drive()
        check(#f.reserves==1 and f.reserves[1].body==f.body,
            "real Core and Spawn reach one reserve; rays="..f.rays.."; spawn="..tostring(out.spawn.detail))
        check((f.proxy.world.raycast~=nil)==trial,"only the floor literal exposes the ray proxy")
        check(f.rays==(trial and 1 or 0),"one floor ray when on; none when off")
        check((out.call_counts["spawn.world.raycast"] or 0)==f.rays,"Core accounts for every forwarded SDK ray")
        local root=trial and {10,99.77,20} or {13,100.5,20}
        check(equal(f.definition,assert(Visual.definition(root,{0,0,0,1}))),"full authored body definition matches the selected placement")
        local expected=trial and vector.create(0,.05,-.05) or vector.create(-G.com[1],-G.com[2],-G.com[3])
        check(f.reserves[1].attachment.offset_from_com==expected,"the actual reserve uses the selected attachment literal")
        check(f.calls["entities.bounds"]==8 and f.calls["entities.set"]==16 and f.calls["entities.status"]==8
            and f.calls["world.physics.create"]==1 and f.calls["world.physics.read"]==1,
            "real asset, visual, allocation and sample cadence is unchanged")
        check(out.reserve_refused and not out.published_seen and #f.releases==1,"known reserve refusal releases the exact body without publishing")
        check(out.last_source_step and out.last_source_step.input_ok==true,"the mount used the actual selected Source capture frame")
        check(next(f.forbidden)==nil,"no force, contact, pulse or Follow publication")
        if trial then
            check(f.ray_from==vector.create(10,100.5,20) and f.ray_to==vector.create(10,97,20),"Core forwards the exact bounded segment")
            check(f.order[1]=="ray" and f.order[2]=="visual" and f.order[10]=="create","ray precedes all visuals and allocation")
            check(not pcall(f.proxy.world.raycast,f.ray_from,f.ray_to) and f.rays==1,"the closed owner cannot forward another query")
        else
            check(f.order[1]=="visual" and f.order[9]=="create","default order has no extra world call")
        end
        local done=f.drain()
        check(f.rays==(trial and 1 or 0) and #f.reserves==1 and #f.releases==1,"cleanup never repeats ray, reserve or release")
        check(done.source and done.source.phase=="complete" and not done.cleanup_unknown,"constructed Source cleanup completes")
    end
    -- No mount is consumed by these cross-controls. They distinguish the floor
    -- literal from the independent provisional attachment literal.
    for _,entry in {{TrialCore,Spawn,false},{Core,TrialSpawn,true}} do
        cases+=1
        local f=Fixture.new(entry[1],entry[2])
        check((type(f.proxy.world.raycast)=="function")==entry[3],"mixed gates follow Spawn rather than M1")
        check(f.rays==0 and not f.body and #f.reserves==0,"backend preparation is inert")
    end
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)
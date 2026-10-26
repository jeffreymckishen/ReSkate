-- SDK-shaped services with real Core, Source and Spawn. Module selection is
-- test-only and restored immediately; no fake Spawn or native handle is used.
local Services=require("./core_ride_staging_tests")
local Spawn=require("./bike_spawn")
local Fixture={}
function Fixture.new(core_module,spawn_module,mode)
    local f,s=Services.spawn_services()
    f.rays=0;f.order={}
    function s.skater.get() return {airborne=false,position=vector.create(10,100,20),heading=0} end
    if mode~="missing" then
        function s.world.raycast(...)
            f.rays+=1;table.insert(f.order,"ray")
            assert(select("#",...)==2,"one two-argument SDK ray")
            f.ray_from,f.ray_to=...
            if mode=="cancel" then f.core:request_stop("cancelled in floor SDK callback")
            elseif mode=="reenter" then f.core:step(1)
            elseif mode=="throw" then error("constructed permission refusal",0) end
            return vector.create(f.ray_from.x,99.75,f.ray_from.z)
        end
    end
    local create,set=s.world.physics.create,s.entities.set
    function s.world.physics.create(...)
        table.insert(f.order,"create");return create(...)
    end
    function s.entities.set(...)
        table.insert(f.order,"visual");return set(...)
    end
    f.core=core_module.new(s,{qualification_only=true})
    local original_new,original_gate=Spawn.new,Spawn.floor_spawn_qualified
    local selected_new,selected_gate=spawn_module.new,spawn_module.floor_spawn_qualified
    -- Core's cached require receives the selected real module exports only for
    -- construction. The resulting Spawn keeps its own literal in its closures.
    Spawn.floor_spawn_qualified=selected_gate
    Spawn.new=function(api)
        f.proxy=api
        f.spawn=selected_new(api)
        return f.spawn
    end
    local ok,bound=pcall(f.core.prepare_backend,f.core)
    Spawn.new,Spawn.floor_spawn_qualified=original_new,original_gate
    assert(ok and bound==true,"real backend must bind: "..tostring(bound))
    assert(Spawn.new==original_new and Spawn.floor_spawn_qualified==original_gate,"restore cached module exports")
    function f.drive()
        assert(f.core:request_mount(0),"one public mount per Core module in this fresh suite VM")
        local out
        for _=1,200 do
            f.now+=16;out=f.core:step(16)
            if #f.reserves>0 or out.stop_latched then break end
        end
        return out
    end
    function f.drain()
        for _=1,10 do f.now+=16;f.core:step(16) end
        return f.core:status()
    end
    return f
end
return table.freeze(Fixture)
-- Real Core, Source and Spawn under SDK-shaped services. A Host tick is a
-- constructed identity here, not a native clock, producer or allocation proof.
local Services=require("./core_ride_staging_tests")
local Spawn=require("./bike_spawn")
local Fixture={}
Fixture.setup_pending="native body producer setup pending; call prepare again explicitly"
Fixture.step_pending="waiting for a fresh qualified 60 Hz physics step"

function Fixture.new(core_module,spawn_module,prepare)
    local f,s=Services.spawn_services()
    f.sdk=s;f.prepares=0;f.creates=0;f.rays=0;f.visuals=0;f.host_tick=0
    f.order={};f.prepare_ticks={};f.prepare_times={}
    f.focused=true;f.gameplay=true;f.menu_open=false;f.allowed=true
    f.state=504;f.wipeouts=0;f.level="sanvan";f.airborne=false
    function s.input.focus()
        return {focused=f.focused,interface_open=f.menu_open,gameplay=f.gameplay}
    end
    function s.input.allowed() return f.allowed end
    function s.menu.game() return {open=f.menu_open} end
    function s.skater.get()
        return {airborne=f.airborne,position=vector.create(10,100,20),heading=0}
    end
    function s.skater.telemetry()
        return {skater=true,airborne=f.airborne,teleport_pending=false,
            watch={valid=true,state=f.state,ragdoll_known=true,ragdoll=false,wipeouts=f.wipeouts}}
    end
    function s.level.current() return {name=f.level} end
    function s.world.physics.prepare(...)
        f.prepares+=1
        f.calls["world.physics.prepare"]=(f.calls["world.physics.prepare"] or 0)+1
        table.insert(f.prepare_times,f.now);table.insert(f.order,"prepare")
        assert(select("#",...)==0,"prepare takes no arguments")
        if f.prepare_ticks[f.host_tick] then
            return false,"asked to prepare native bodies more than once in one tick"
        end
        f.prepare_ticks[f.host_tick]=true
        if prepare then return prepare(f) end
        return true
    end
    function s.world.raycast(...)
        assert(select("#",...)==2,"floor query retains its SDK shape")
        local from=...
        f.rays+=1;table.insert(f.order,"ray")
        return vector.create(from.x,99.75,from.z)
    end
    local create,set,lease=s.world.physics.create,s.entities.set,s.input.lease
    function s.world.physics.create(...)
        f.creates+=1;table.insert(f.order,"create")
        if f.create_reply then return f.create_reply(...) end
        return create(...)
    end
    function s.entities.set(...)
        f.visuals+=1;table.insert(f.order,"visual")
        return set(...)
    end
    function s.input.lease(...)
        table.insert(f.order,"lease")
        return lease(...)
    end
    f.core=core_module.new(s,{qualification_only=true})
    assert(f.prepares==0,"Core construction is inert")
    local original_new,original_gate=Spawn.new,Spawn.floor_spawn_qualified
    local selected_new=spawn_module.new
    Spawn.new=function(api) f.spawn=selected_new(api);return f.spawn end
    Spawn.floor_spawn_qualified=spawn_module.floor_spawn_qualified
    local ok,bound=pcall(f.core.prepare_backend,f.core)
    Spawn.new,Spawn.floor_spawn_qualified=original_new,original_gate
    assert(ok and bound==true,"real backend binds: "..tostring(bound))
    assert(f.prepares==0 and next(f.calls)==nil,"backend binding is inert")
    function f.arm()
        local accepted,why=f.core:request_mount(0)
        return accepted,why,f.core:status()
    end
    function f.tick(delta)
        delta=delta or 16
        f.host_tick+=1;f.now+=delta
        return f.core:step(delta)
    end
    function f.until_status(predicate,limit,delta)
        local out=f.core:status()
        for _=1,limit or 200 do
            if predicate(out) then return out end
            out=f.tick(delta)
        end
        return out
    end
    function f.unacquired()
        local out=f.core:status()
        return not f.lease and not f.capture and f.rays==0 and f.creates==0 and f.visuals==0
            and #f.reserves==0 and next(f.forbidden)==nil and not (out.call_counts or {})["source.arm"]
    end
    return f
end
return table.freeze(Fixture)
-- Constructed placement checks only. The runner makes the single-literal
-- trial copy; the shipped module stays airborne. No native/game fact is mocked
-- into qualification, and no result is evidence of support under both wheels.
local Spawn=require("./bike_spawn")
local Trial=require("./bike_spawn_floor_qualified_fixture")
local G=require("./bike_geometry")
local M=require("./force_math")
local Visual=require("./bike_visual")
local Tests={}
local function xyz(v) return {v.x,v.y,v.z} end
local function equal(a,b)
    if typeof(a)~=typeof(b) then return false end
    if typeof(a)=="vector" then return a.x==b.x and a.y==b.y and a.z==b.z end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function fixture(module,answer,options)
    options=options or {}
    local f={rays=0,creates=0,reads=0,sets=0,removes=0,releases=0,bounds=0,statuses=0,order={},
        actor={position=vector.create(10,100,20),heading=options.heading or 0}}
    local api={input={},skater={},entities={},world={physics={}}}
    function api.input.focus() return {focused=true,gameplay=true,interface_open=false} end
    function api.skater.get() return f.actor end
    function api.world.raycast(...)
        f.rays+=1;table.insert(f.order,"ray")
        assert(select("#",...)==2,"one ordinary two-argument world ray")
        f.from,f.to=...
        assert(typeof(f.from)=="vector" and typeof(f.to)=="vector" and f.from.x==f.to.x and f.from.z==f.to.z
            and f.from.y>f.to.y and f.from.y-f.to.y<=4,"one bounded downward segment")
        return answer(f,f.from,f.to)
    end
    if options.no_api then api.world.raycast=nil end
    function api.entities.bounds()
        f.bounds+=1
        return vector.create(-.02,-G.wheel_radius,-G.wheel_radius),vector.create(.02,G.wheel_radius,G.wheel_radius)
    end
    function api.entities.set(id,name,transform,attached,joint,settings)
        assert(name==G.blueprints[id] and attached==false and joint==nil and settings.solid==false)
        f.sets+=1;table.insert(f.order,"visual");f.last_matrix=transform.matrix
        if options.on_set then options.on_set(f) end
        return true
    end
    function api.entities.status()
        f.statuses+=1
        if options.on_status then options.on_status(f) end
        return options.visual_loading and "loading" or "ready"
    end
    function api.entities.remove() f.removes+=1 end
    function api.world.physics.create(definition)
        f.creates+=1;table.insert(f.order,"create");f.definition=definition
        if options.warmup then return nil,"waiting for a fresh qualified 60 Hz physics step" end
        f.body=newproxy();return f.body
    end
    function api.world.physics.read(body)
        assert(body==f.body);f.reads+=1
        return {epoch=newproxy(),serial="1",time=1/60,seconds=1/60,mass=G.mass,
            position=f.definition.position,rotation=f.definition.rotation,velocity=vector.create(0,0,0),
            angular_velocity=vector.create(0,0,0),inertia=vector.create(unpack(G.inertia))}
    end
    function api.world.physics.release(body) assert(body==f.body);f.releases+=1;return true end
    f.owner=module.new(api)
    function f.drive()
        assert(f.owner:request())
        for _=1,30 do
            f.owner:update(16)
            local phase=f.owner:status().phase
            if phase=="spawned" or phase=="closed" or phase=="cleanup_unknown" or phase=="clock_prepared" then break end
        end
        return f.owner:status()
    end
    return f
end
local function hit(f,from) return vector.create(from.x,f.actor.position.y-.25,from.z) end
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(run) cases+=1;run() end
    for _,no_api in {false,true} do case(function()
        local f=fixture(Spawn,function() error("tracked default must not query") end,{no_api=no_api})
        local out=f.drive()
        local root={13,100.5,20}
        check(out.phase=="spawned" and f.rays==0,"literal off keeps the airborne path and calls no floor API")
        check(equal(f.definition,assert(Visual.definition(root,{0,0,0,1}))),"literal off preserves every authored body-definition value")
        check(f.bounds==8 and f.sets==16 and f.statuses==8 and f.creates==1 and f.reads==1,
            "literal off preserves existing asset/visual/create/read cadence")
        check(out.detail=="Lua bike parts follow the measured chassis. Rider and controls remain untouched.",
            "literal off preserves status text")
        check(out.creation_attempts==1 and not out.cleanup_unknown and f.removes==0 and f.releases==0,
            "literal off retains existing ownership and cleanup state")
    end) end
    for _,spec in {{0,.25},{math.pi/2,.25},{math.pi,.25},{-math.pi/2,.25},{1.2,.25},{0,0},{0,2}} do case(function()
        local f=fixture(Trial,function(row,from) return vector.create(from.x,row.actor.position.y-spec[2],from.z) end,{heading=spec[1]})
        local out=f.drive()
        local root=M.sub(xyz(f.definition.position),M.turn(f.definition.rotation,G.com))
        local floor=100-spec[2]
        check(out.phase=="spawned" and f.rays==1 and f.creates==1,"trial accepts one measured hit before one allocation")
        check(math.abs(root[1]-10)<1e-5 and math.abs(root[3]-20)<1e-5,"trial starts directly under the reported rider position")
        check(math.abs(root[2]-floor-.02)<1e-5,"body-frame origin starts two centimetres above the returned hit")
        local forward=M.turn(f.definition.rotation,{0,0,1})
        check(math.abs(forward[1]-math.sin(spec[1]))<1e-6 and math.abs(forward[3]-math.cos(spec[1]))<1e-6,
            "bike +Z follows the SDK's rider heading convention without a quarter turn")
        for _,axle in {G.front_axle,G.rear_axle} do
            local clearance=root[2]+M.turn(f.definition.rotation,axle)[2]-G.wheel_radius-floor
            check(clearance>=0 and clearance<=.02,"both authored wheels clear the returned hit height by at most two centimetres")
        end
        check(f.definition.position.y>floor,"native body COM is never placed below the hit")
        for _,capsule in f.definition.capsules do
            local a=M.add(xyz(f.definition.position),M.turn(f.definition.rotation,xyz(capsule.a)))
            local b=M.add(xyz(f.definition.position),M.turn(f.definition.rotation,xyz(capsule.b)))
            check(math.min(a[2],b[2])-capsule.radius>=floor,"authored collision capsules start above the returned hit")
        end
        local ray_at,create_at
        for i,name in f.order do if name=="ray" then ray_at=i elseif name=="create" then create_at=i end end
        check(ray_at and create_at and ray_at<create_at and f.order[ray_at+1]=="visual","query precedes all initial visuals and body creation")
        for _=1,3 do f.owner:update(16) end
        check(f.rays==1 and f.creates==1,"later samples do not repeat the floor query or allocation")
    end) end
    local refusals={
        {"miss",function() return nil end,"floor ray missed or is unavailable"},
        {"unavailable",function() return nil end,"floor ray missed or is unavailable"},
        {"refused",function() error("permission refused",0) end,"floor ray refused or failed: permission refused"},
        {"too far below",function(f,from) return vector.create(from.x,97.75,from.z) end,"floor ray hit is too far below the actor"},
        {"above actor",function(f,from) return vector.create(from.x,100.125,from.z) end,"floor ray hit is above the actor"},
        {"missing API",hit,"floor ray API unavailable",true},
        {"malformed hit",function() return {} end,"floor ray returned an invalid hit"},
        {"nonfinite hit",function(f,from) return vector.create(from.x,0/0,from.z) end,"floor ray returned an invalid hit"},
        {"off segment",function(f,from) return vector.create(from.x+.125,99.75,from.z) end,"floor ray hit is outside the bounded segment"},
        {"wrong arity",function() return nil,"extra" end,"floor ray returned a malformed result"},
    }
    for _,spec in refusals do case(function()
        local f=fixture(Trial,spec[2],{no_api=spec[4]})
        local out=f.drive()
        check(out.phase=="closed" and out.detail==spec[3],spec[1].." stops with the actual bounded-query reason")
        check(f.rays==(spec[4] and 0 or 1) and f.creates==0 and f.sets==0,spec[1].." cannot publish or allocate")
        check(not out.cleanup_unknown and not out.body and not out.creation_unknown and out.creation_attempts==0,
            spec[1].." ends cleanly with no invented native cleanup duty")
        f.owner:update(16);check(not f.owner:request() and f.rays==(spec[4] and 0 or 1),spec[1].." never retries or falls back")
    end) end
    for _,reenter in {false,true} do case(function()
        local f=fixture(Trial,function(row,from)
            if reenter then row.owner:update(1) else row.owner:stop("cancelled in floor ray") end
            return hit(row,from)
        end)
        local out=f.drive()
        check(out.phase=="closed" and f.rays==1,"stop or reentry during query consumes the one attempt")
        check(f.creates==0 and f.sets==0 and not out.cleanup_unknown,"late query return cannot publish or allocate after cancellation")
    end) end
    for _,expire in {false,true} do case(function()
        local f=fixture(Trial,hit,{on_status=function(row)
            if not row.cancelled then
                row.cancelled=true
                if expire then row.owner:update(101) else row.owner:stop("cancelled in visual status") end
            end
        end})
        local out=f.drive()
        check(out.phase=="closed" and f.rays==1 and f.creates==0,"status callbacks cannot allocate from a stopped or expired floor attempt")
        check(f.removes==8 and not out.cleanup_unknown,"status cancellation retains one clean visual removal request")
    end) end
    case(function()
        local f=fixture(Trial,hit,{on_set=function(row) row.owner:stop("cancelled in visual setter") end})
        local out=f.drive()
        check(out.phase=="closed" and f.creates==0 and f.rays==1,"visual setter cancellation cannot reopen the floor attempt")
        check(f.sets==1 and f.removes==8 and not out.cleanup_unknown,"stopped trial does not publish later visual parts")
    end)
    case(function()
        local f=fixture(Trial,hit,{visual_loading=true})
        local out=f.drive()
        check(out.phase=="closed" and out.detail=="floor hit expired before body creation","visual loading cannot retain an old floor hit for the five-second readiness window")
        check(f.rays==1 and f.creates==0 and f.sets==8 and f.removes==8,"expired hit cleans visuals without resampling or allocating")
        check(not out.cleanup_unknown and not out.clock_retry_available,"expired trial has no native or retry duty")
    end)
    case(function()
        local f=fixture(Trial,hit,{warmup=true})
        local out=f.drive()
        check(out.phase=="closed" and not out.clock_retry_available and f.rays==1 and f.creates==1 and f.removes==8,"known preallocation refusal removes visuals without inventing a body")
        local ok,why=f.owner:retry_after_clock_warmup()
        check(not ok and why=="Floor spawn does not repeat or reuse its one floor query.","trial cannot reuse a stale hit or issue a second query")
        f.owner:update(16);check(f.rays==1 and f.creates==1,"floor query stays one per VM after readiness refusal")
    end)
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return Tests

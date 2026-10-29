-- Constructed Spawn visual policy only; no Host, native body, input or ride proof.
local Spawn=require("./bike_spawn")
local G=require("./bike_geometry")
local Visual=require("./bike_visual")
local Tests={}
local function fixture(options,handed_off)
    local f={sets=0,releases=0,removals=0}
    local api={entities={},input={},world={physics={}}}
    function api.entities.set(id)
        f.sets+=1
        if id==f.refuse_id then return false,"constructed partial placement refusal" end
        return true
    end
    function api.entities.remove() f.removals+=1 end
    function api.input.focus() return {focused=true,gameplay=true,interface_open=false} end
    function api.world.physics.read() return f.next_read end
    function api.world.physics.release() f.releases+=1;return true end
    local owner=Spawn.new(api,options)
    -- An exact zero COM avoids vector quantization at the512 m boundary.
    -- The fixture starts with a measured spawned body, then uses real handoff.
    owner.root,owner.rotation={0,-G.com[2],-G.com[3]},{0,0,0,1}
    function f.sample(serial,x,time)
        return {epoch=newproxy(),serial=tostring(serial),time=time or serial/60,seconds=1/60,mass=G.mass,
            position=vector.create(x,0,0),rotation={0,0,0,1},velocity=vector.create(0,0,0),
            angular_velocity=vector.create(0,0,0),inertia=vector.create(unpack(G.inertia))}
    end
    owner.sample=f.sample(1,0);owner.body=newproxy();owner.phase="spawned";owner.used=true
    if handed_off~=false then
        local body,measured,why=owner:handoff_follow()
        assert(typeof(body)=="userdata" and measured==owner.sample and why==nil,"actual one-shot handoff")
    end
    return owner,f
end
function Tests.run()
    local assertions=0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    for _,options in {{},{session_renewable=false},{session_renewable="true"},{session_renewable=1}} do
        local owner,f=fixture(options)
        local edge=f.sample(2,512)
        check(owner:follow_visual(edge,16),"legacy exact512 m boundary remains allowed")
        local sets=f.sets
        local ok,why=owner:follow_visual(f.sample(3,513),32)
        check(not ok and why=="Body left the 512 m spawn envelope","unset/false/nonboolean option keeps original spawn anchor")
        check(owner.sample==edge and f.sets==sets,"legacy rejection changes no accepted sample or visual")
    end
    local unmounted,u=fixture({session_renewable=true},false)
    check(not unmounted:follow_visual(u.sample(2,1),16),"session visuals require established handoff before accepting a sample")
    u.next_read=u.sample(2,513);unmounted:update(16)
    check(unmounted.phase=="closed" and unmounted.detail=="body left the 512 m spawn envelope",
        "explicit session option never relaxes the unmounted spawn guard")
    check(u.releases==1 and u.removals==0 and unmounted.body_release_accepted,"unmounted rejection retains original release cleanup")

    local options={session_renewable=true}
    local owner,f=fixture(options);options.session_renewable=false
    local root,rotation=owner.root,owner.rotation
    for i=1,5 do
        local sample=f.sample(i+1,i*128)
        check(owner:follow_visual(sample,i*16),"explicit session accepts each bounded successive measurement")
        check(owner.sample==sample,"only accepted fresh measurements advance the anchor")
    end
    check(owner.sample.position.x==640 and owner.sample.position.x>Spawn.limits.envelope_m and f.sets==40,
        "session travels cumulatively beyond512 m without changing the per-sample bound")
    check(owner.root==root and root[1]==0 and root[2]==-G.com[2] and root[3]==-G.com[3]
        and owner.rotation==rotation and owner.wall==0 and owner.phase_wall==0 and owner.read_wall==0,
        "no root, orientation, body or clock rebasing")
    local accepted=owner.sample;local observed=owner.follow_observed_at
    local pose=Visual.neutral();pose.steer=.25
    check(owner:follow_visual(accepted,81,pose),"same measured sample can receive a new presentation pose")
    check(owner.sample==accepted and owner.follow_observed_at==observed,"pose-only duplicate does not advance the measured anchor or freshness")
    local sets=f.sets
    check(not owner:follow_visual(f.sample(6,641,accepted.time),82),"same serial cannot conceal a changed body")
    check(owner.sample==accepted and f.sets==sets,"changed duplicate never advances or places a body")
    f.refuse_id=4
    check(not owner:follow_visual(f.sample(7,896),82),"partial visual placement still refuses")
    check(owner.sample==accepted and owner.follow_observed_at==observed and f.sets==sets+4,
        "failed placement does not advance anchor despite accepted setter prefix")
    f.refuse_id=nil;sets=f.sets
    check(not owner:follow_visual(f.sample(8,1153),83),"jump beyond512 m is measured from last accepted body, not the failed candidate")
    check(owner.sample==accepted and f.sets==sets,"huge jump is refused before any visual setter")
    for _,corrupt in {
        function(row) row.epoch=nil end,
        function(row) row.position=vector.create(0/0,0,0) end,
        function(row) row.position=vector.create(100001,0,0) end,
        function(row) row.rotation={0,0,0,0} end,
    } do
        local row=f.sample(9,641);corrupt(row)
        check(not owner:follow_visual(row,84),"session option does not admit malformed or out-of-world measurements")
        check(owner.sample==accepted and f.sets==sets,"invalid measurements cannot move the accepted anchor")
    end
    check(not owner:follow_visual(accepted,80),"reversed follow wall clock still refuses")
    check(not owner:follow_visual(accepted,181),"unchanged native sample still expires after100 ms")
    check(owner.sample==accepted and owner.follow_observed_at==observed and owner.root==root,
        "all rejected paths retain the accepted sample, freshness and original root")
    return {cases=1,assertions=assertions,constructed=true,native_qualified=false}
end
return table.freeze(Tests)

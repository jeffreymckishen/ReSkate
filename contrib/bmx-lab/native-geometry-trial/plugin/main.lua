-- Private single-body contact diagnostic. No force packet or rider/input lease.
local P, V = reskate.world.physics, vector.create
local body, sample, origin, right
local phase, detail = "idle", "Start explicitly, then close the menu."
local armed, used, retry_clock, saved = false, false, false, false
local wall_ms, queries = 0, {}
local actor_before, actor_after
local key = "owned_geometry_native_v1"
if reskate.storage.get(key) ~= nil then used, phase = true, "previous trial" end
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function vec(v) return v and finite(v.x) and finite(v.y) and finite(v.z) end
local function xyz(v) return {v.x,v.y,v.z} end
local function snapshot(s)
    if not s then return nil end
    return {serial=s.serial,time=s.time,seconds=s.seconds,mass=s.mass,inertia=xyz(s.inertia),
        position=xyz(s.position),velocity=xyz(s.velocity),angular_velocity=xyz(s.angular_velocity),rotation=s.rotation}
end
local function valid(s)
    return s and type(s.serial)=="string" and s.serial:match("^[1-9][0-9]*$") and finite(s.time)
        and finite(s.seconds) and math.abs(s.seconds-1/60)<1e-7 and s.mass==12
        and vec(s.position) and vec(s.velocity) and vec(s.angular_velocity) and vec(s.inertia)
        and type(s.rotation)=="table" and #s.rotation==4
end
local function same(a,b)
    if not a or not b or a.serial~=b.serial or a.time~=b.time or a.seconds~=b.seconds or a.mass~=b.mass then return false end
    local function number(x,y) return x==y and (x~=0 or 1/x==1/y) end
    for _,field in {"position","velocity","angular_velocity","inertia"} do
        for _,axis in {"x","y","z"} do if not number(a[field][axis],b[field][axis]) then return false end end
    end
    for i=1,4 do if not number(a.rotation[i],b.rotation[i]) then return false end end
    return true
end
local function finish(reason, passed)
    if saved then return end
    armed, used, retry_clock = false, true, false
    local released, why = true, "no body allocated"
    if body then released, why = P.release(body); if released then body=nil end end
    phase = passed and released and "passed" or "stopped"
    detail = reason.."; release="..tostring(released).."; "..tostring(why or "parked and retained")
    local report={reason=reason,passed=passed==true and released==true,released=released,
        release_detail=why or "retained parked slot; not destroyed",queries=queries,
        sample=snapshot(sample),actor_before=actor_before,actor_after=actor_after,submitted=0,actor_exclusion_supported=false,
        purpose="single-capsule geometry and refusal qualification; no vehicle or rider safety claim"}
    local ok, error = pcall(reskate.storage.set,key,report)
    saved=ok
    reskate.log("owned-geometry-native-v1 finish "..reskate.json.encode({phase=phase,reason=reason,
        released=released,storage_queued=ok,storage_detail=tostring(error),query_count=#queries,submitted=0}))
end
local function query(actor, rays)
    local row={exclude_local_actor=actor,requests={},response={rays={}}}; queries[#queries+1]=row
    for i,ray in rays do row.requests[i]={from=xyz(ray.from),to=xyz(ray.to)} end
    local ok, batch=pcall(P.probe_batch,body,sample.epoch,rays,{exclude_local_actor=actor})
    if not ok or type(batch)~="table" then row.error=tostring(batch); return nil end
    row.response.status,row.response.reason,row.response.native_casts,row.response.budget_exhausted=
        batch.status,batch.reason,batch.native_casts,batch.budget_exhausted
    if type(batch.rays)=="table" then
        for i,ray in batch.rays do
            row.response.rays[i]={status=ray.status,position=vec(ray.position) and xyz(ray.position) or nil,
                fraction=ray.fraction,motion=ray.motion,body_token=ray.body~=nil,
                normal_present=ray.normal~=nil,velocity_present=ray.velocity~=nil}
        end
    end
    return batch
end
reskate.menu.page("Owned Geometry Trial",function(ui)
    ui:note("One 12 kg capsule; no force commands. Two actual world hits required.")
    ui:note("Actor exclusion remains unavailable. This is not BMX riding or a rider-safe query.")
    if (not used or retry_clock) and not body then
        if ui:button("start",retry_clock and "Retry after clock warmup" or "Start geometry qualification",true) then
            armed,retry_clock,wall_ms=true,false,0; phase,detail="armed","Close menu within two minutes, with the game focused."
            reskate.log("owned-geometry-native-v1 armed; explicit page action")
        end
    end
    if ui:button("stop","Release / stop") and phase~="idle" and phase~="previous trial" then finish("explicit page action",false) end
    ui:info("Phase",phase); ui:info("Status",detail); ui:info("Query count",tostring(#queries))
end)
reskate.on("tick",function(dt_ms)
    if saved or (not armed and not body) then return end
    if not finite(dt_ms) or dt_ms<0 then finish("invalid wall clock",false); return end
    wall_ms+=dt_ms
    if wall_ms>(body and 6000 or 120000) then finish("trial watchdog",false); return end
    local focus=reskate.input.focus()
    if not focus or not focus.focused or not focus.gameplay or focus.interface_open then
        if body then finish("focus/gameplay/interface changed",false) end
        return
    end
    if armed then
        armed,used,wall_ms=false,true,0
        local player=reskate.skater.get()
        if not player or not vec(player.position) or not finite(player.heading) then finish("no finite local actor placement",false); return end
        origin=player.position+V(math.cos(player.heading)*2,1.5,-math.sin(player.heading)*2)
        right=V(math.sin(player.heading),0,math.cos(player.heading))
        local why
        body,why=P.create({mass=12,inertia=V(.4,.1,.4),position=origin,rotation={0,0,0,1},
            capsules={{a=V(0,-.25,0),b=V(0,.25,0),radius=.12}}})
        reskate.log("owned-geometry-native-v1 create accepted="..tostring(body~=nil).." detail="..tostring(why))
        if not body then
            retry_clock=why=="waiting for a fresh qualified 60 Hz physics step"
            phase,detail="refused",tostring(why); return
        end
        phase,detail="waiting sample","No command is published."
    end
    local why
    sample,why=P.read(body)
    if not sample then detail=tostring(why); return end
    if not valid(sample) then finish("invalid native sample",false); return end
    local offset=sample.position-origin
    if offset.x^2+offset.y^2+offset.z^2>.35^2 then finish("placement left bounded trial",false); return end
    local rays={}
    local actor=reskate.skater.get()
    if not actor or not vec(actor.position) then finish("local actor placement unavailable",false); return end
    actor_before=xyz(actor.position)
    for i,side in {1,-1} do
        local from=sample.position+right*(side*.35)
        local dx,dz=from.x-actor.position.x,from.z-actor.position.z
        if dx*dx+dz*dz<1 then finish("ray entered one-metre actor clearance",false); return end
        rays[i]={from=from,to=from-V(0,4,0)}
    end
    local refused=query(true,{rays[1]})
    if not refused or refused.status~="unavailable" or refused.reason~="local_actor_exclusion_unavailable"
        or refused.native_casts~=0 or refused.budget_exhausted~=false or #refused.rays~=1 then
        finish("actor refusal contract changed",false); return
    end
    local rejected=refused.rays[1]
    if rejected.status~="unavailable" or rejected.position or rejected.fraction or rejected.body or rejected.motion then
        finish("actor refusal exposed geometry",false); return
    end
    local batch=query(false,rays)
    if not batch or batch.status~="available" or batch.native_casts~=2 or batch.budget_exhausted~=false or #batch.rays~=2 then
        finish("geometry unavailable: "..tostring(batch and batch.reason),false); return
    end
    for i,ray in batch.rays do
        if ray.status~="hit" or not vec(ray.position) or not finite(ray.fraction) or ray.fraction<0 or ray.fraction>1
            or ray.motion~="unknown" or ray.body or ray.normal or ray.velocity then
            finish("actual qualified world hit required",false); return
        end
        local delta=ray.position-(rays[i].from+(rays[i].to-rays[i].from)*ray.fraction)
        if math.abs(delta.x)>.025 or math.abs(delta.y)>.025 or math.abs(delta.z)>.025 then
            finish("hit left its actual segment",false); return
        end
    end
    local after=P.read(body)
    queries[#queries].after=snapshot(after)
    if not valid(after) or not same(sample,after) then finish("postquery sample changed; no relabel or retry",false); return end
    actor=reskate.skater.get()
    if not actor or not vec(actor.position) then finish("postquery actor placement unavailable",false); return end
    actor_after=xyz(actor.position)
    for _,ray in rays do
        local dx,dz=ray.from.x-actor.position.x,ray.from.z-actor.position.z
        if dx*dx+dz*dz<1 then finish("postquery actor clearance changed",false); return end
    end
    finish("two actual world hits; actor refusal retained; no commands",true)
end)
reskate.on("unload",function() if body or armed then finish("plugin unload",false) end end)

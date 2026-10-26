-- Mod-only fixtures with actual Contact decoding. The runner alone creates
-- qualified Ride/Contact copies; no native support or actor identity is proved.
local Runtime=require("./ride_runtime")
local Fixtures=require("./ride_runtime_tests")
local Contact=require("./contact_runtime")
local Qualified=require("./contact_runtime_category_qualified_fixture")
local G=require("./bike_geometry")
local Tests={}
local function fixture(spec)
    spec=spec or {}
    local f
    local models={contact=spec.closed and Contact or Qualified,tricks=false,
        alignment={solve=function(frame) f.model_frame=frame;return {status="targets_only",native_alignment=false} end}}
    f=Fixtures.fixture({models=models})
    f.probes={}
    function f.api.probe_batch(epoch,rays,options)
        table.insert(f.calls,"probe")
        table.insert(f.probes,{epoch=epoch,rays=rays,options=options})
        local category=not spec.closed or spec.force_category
        local batch={status="available",epoch=epoch,native_casts=#rays,budget_exhausted=false,
            local_actor_excluded=not category,owned_bodies_excluded=true,rays={}}
        if category then batch.named_actor_categories_absent=true;batch.requested_query_preset="camera" end
        for i,ray in ipairs(rays) do
            if #rays==2 and not spec.clear_wheels then
                local fraction=G.wheel_radius/(G.wheel_radius+.15)
                batch.rays[i]={status="hit",fraction=fraction,position=ray.from+(ray.to-ray.from)*fraction,
                    normal_available=true,normal=vector.create(0,1,0),surface_velocity_available=true,
                    surface_velocity=vector.create(0,0,0),motion="measured"}
            else batch.rays[i]={status="clear"} end
        end
        if #rays==2 and spec.wheel then return spec.wheel(batch,f) end
        if #rays==3 and spec.trip then return spec.trip(batch,f) end
        return batch
    end
    return f
end
local function hit(batch,f)
    local ray=f.probes[2].rays[1]
    local delta=ray.to-ray.from
    local length=math.sqrt(delta.x*delta.x+delta.y*delta.y+delta.z*delta.z)
    batch.rays[1]={status="hit",fraction=.5,position=(ray.from+ray.to)*.5,normal_available=true,
        normal=delta*(-1/length),surface_velocity_available=true,surface_velocity=vector.create(0,0,0),motion="measured"}
    return batch
end
function Tests.run()
    local cases,assertions=0,0
    local function check(v,why) assertions+=1;assert(v,why) end
    local function case() cases+=1 end
    case() do
        local touches=0
        local api=setmetatable({}, {__index=function() touches+=1;error("native touched") end})
        local ride=Runtime.new(api,{contact=Qualified})
        check(ride:observe(nil,nil,nil).phase=="inert" and touches==0,"the tracked Ride gate remains closed even with a qualified Contact model")
        check(Contact.CATEGORY_WHEEL_LANE_QUALIFIED==false and ride:drain().force_pending==false and touches==0,"neither tracked activation gate is opened by the fixture")
    end
    case() do
        local f=fixture({closed=true});local out=f.observe()
        check(out.submitted==1 and #f.probes==1,"the identity lane keeps its single wheel batch")
        local options=f.probes[1].options
        check(options.require_contact==true and options.exclude_local_actor==true and options.query_preset==nil,"the false literal selects exactly shape A")
        check(f.model_frame.support.actor_lane=="identity" and f.model_frame.support.actor_tripwire=="not_required_identity_lane"
            and f.model_frame.contact.decoded.query.local_actor_excluded==true,"identity never claims an uncast clear tripwire")
    end
    case() do
        local f=fixture({closed=true,force_category=true});local out=f.observe()
        check(out.stop_requested and out.issue=="contact actor lane unavailable","the tracked false Contact literal refuses a category wheel lane")
        check(#f.probes==1 and out.model_steps==0 and out.submitted==0 and f.model_frame==nil,"a category claim cannot bypass the gate or request a rescuing tripwire")
    end
    case() do
        local f=fixture();local out=f.observe()
        check(out.submitted==1 and out.model_steps==1 and #f.probes==2,"the qualified fixture can continue only after both batches")
        check(#f.probes[1].rays==2 and #f.probes[2].rays==3 and f.probes[1].epoch==f.read.epoch and f.probes[2].epoch==f.read.epoch,
            "wheel then tripwire use the same measured epoch")
        local exact=true
        for _,probe in ipairs(f.probes) do
            local count=0;for _ in pairs(probe.options) do count+=1 end
            exact=exact and count==3 and probe.options.require_contact==true and probe.options.query_preset=="camera"
                and probe.options.require_named_actor_categories_absent==true and probe.options.exclude_local_actor==nil
                and probe.options.include_shape_categories==nil and probe.options.include_hit_owner==nil
        end
        check(exact,"both calls use exactly shape B without an observe diagnostic")
        local support=f.model_frame.support
        check(support.actor_lane=="named_categories_absent" and support.actor_tripwire=="authored_rider_crossings_clear_v1"
            and support.native_collision_contact==false,"the support record names its actual lane and completed refusal-only check")
        local decoded=f.model_frame.contact.decoded
        check(decoded.query.local_actor_excluded==false and decoded.force_ready==false and decoded.support.known==false
            and not Contact.actor_lane_qualified(decoded.query),"the category result never becomes identity, SDK support or force readiness")
        check(support.epoch==f.read.epoch and support.provenance=="measured_rays_authored_wheel_geometry"
            and f.model_frame.physics_epoch==f.read.epoch,"the existing geometric provenance and binding remain explicit")
    end
    case() do
        local f=fixture({clear_wheels=true})
        local raw=f.sample();raw.position=vector.create(3,4,5);raw.rotation={0,math.sqrt(.5),0,math.sqrt(.5)}
        local out=f.observe(nil,raw)
        local trip=f.probes[2] and f.probes[2].rays
        check(trip~=nil and #trip==3,"the rotated sample produces the three authored crossings")
        local center={3,4,5}
        local lateral={0,0,-.6}
        for i,point in ipairs({{0,.89,-.305},{0,1.085,-.225},{0,1.40,.135}}) do
            local rotated={point[3]-G.com[3],point[2]-G.com[2],-(point[1]-G.com[1])}
            for axis,key in ipairs({"x","y","z"}) do
                check(math.abs(trip[i].from[key]-(center[axis]+rotated[axis]-lateral[axis]))<1e-5
                    and math.abs(trip[i].to[key]-(center[axis]+rotated[axis]+lateral[axis]))<1e-5,
                    "tripwire endpoints rotate with the body and subtract its COM")
            end
            local d=trip[i].to-trip[i].from
            check(math.abs(math.sqrt(d.x*d.x+d.y*d.y+d.z*d.z)-1.2)<1e-5,"each crossing is 1.2 metres long")
        end
        check(not out.stop_requested and #f.probes==2,"the geometry check creates no extra query or false contact")
    end
    for _,variant in ipairs({
        {"hit",hit,"rider tripwire hit"},
        {"unavailable",function(batch)
            batch.status="unavailable";batch.reason="hit_categories_unavailable";batch.native_casts=0
            batch.named_actor_categories_absent=false;batch.owned_bodies_excluded=false
            batch.rays={{status="unavailable"},{status="unavailable"},{status="unavailable"}};return batch
        end,"rider tripwire lane or binding unavailable"},
        {"accounting",function(batch) batch.native_casts="3";return batch end,"rider tripwire lane or binding unavailable"},
        {"stale epoch",function(batch) batch.epoch=newproxy();return batch end,"rider tripwire lane or binding unavailable"},
        {"mixed facts",function(batch) batch.local_actor_excluded=true;return batch end,"rider tripwire lane or binding unavailable"},
        {"false category",function(batch) batch.named_actor_categories_absent=false;return batch end,"rider tripwire lane or binding unavailable"},
        {"absent category",function(batch) batch.named_actor_categories_absent=nil;return batch end,"rider tripwire lane or binding unavailable"},
        {"missing preset",function(batch) batch.requested_query_preset=nil;return batch end,"rider tripwire lane or binding unavailable"},
        {"extra field",function(batch) batch.extra=true;return batch end,"rider tripwire lane or binding unavailable"},
        {"partial rays",function(batch) batch.rays[3]=nil;return batch end,"rider tripwire lane or binding unavailable"},
        {"exception",function() error("constructed query exception",0) end,"rider tripwire batch unavailable"},
        {"reentry",function(batch,f) f.ride:observe(f.frame(),f.sample(),{now_ms=f.now,focused=true,menu_open=false,loaded=true});return batch end,"reentrant observe"},
        {"extra return",function(batch) return batch,"unexpected" end,"rider tripwire batch unavailable"},
    }) do case() do
        local f=fixture({trip=variant[2]});local out=f.observe()
        check(out.stop_requested and out.issue==variant[3],"tripwire "..variant[1].." refuses the read")
        check(#f.probes==2 and out.model_steps==0 and out.submitted==0 and f.model_frame==nil,"a refused tripwire precedes models and submission")
        f.observe()
        check(#f.probes==2 and f.ride:status().submitted==0,"a tripwire refusal is terminal and is never recast")
    end end
    for _,edit in ipairs({
        function(batch) batch.rays[1].normal=nil;return batch end,
        function(batch) batch.named_actor_categories_absent=false;return batch end,
    }) do case() do
        local f=fixture({wheel=edit});local out=f.observe()
        check(out.stop_requested and #f.probes==1,"a bad wheel batch gets no rescuing tripwire")
        check(out.model_steps==0 and out.submitted==0 and f.model_frame==nil,"bad wheels cannot advance a model or command")
    end end
    case() do
        local f=fixture({clear_wheels=true});local out=f.observe()
        check(not out.stop_requested and f.model_frame.support.grounded==false,"a clear tripwire does not turn clear wheels into ground")
        check(f.model_frame.contact.decoded.force_ready==false and f.model_frame.support.native_collision_contact==false,
            "a successful refusal-only check is not SDK physical authority")
    end
    return {cases=cases,assertions=assertions,native_actions=0}
end
return Tests

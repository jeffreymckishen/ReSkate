-- Mod-only constructed DTOs. The runner makes the true-literal fixture in
-- its owned copy; neither fixture nor an activation option ships in the mod.
local Contact=require("./contact_runtime")
local Qualified=require("./contact_runtime_category_qualified_fixture")
local Guard=require("./bail_guard")
local Tests={}
local function fixture()
    local epoch,body,lease=newproxy(),newproxy(),newproxy()
    local sample={epoch=epoch,serial="9007199254740993",time=1,seconds=1/60,mass=106,
        position=vector.create(0,1,0),velocity=vector.create(0,0,0),angular_velocity=vector.create(0,0,0),
        inertia=vector.create(26,32,10),rotation={0,0,0,1}}
    local source={lease_handle=lease,generation=1,user=0,packet=1,sequence="9007199254740995",
        source_epoch="9007199254740997",context_generation="9007199254740999",
        observation_serial="9007199254741001",observed_ms="9007199254741003"}
    local frame={valid=true,fresh=true,body_handle=body,physics_epoch=epoch,
        serial=sample.serial,time=sample.time,seconds=sample.seconds,sample=sample,source=source,
        body={mass=106,center_of_mass={0,1,0},linear_velocity={0,0,0},angular_velocity={0,0,0},
            inertia_body={26,32,10},orientation={0,0,0,1}},
        owner={body_handle=body,lease_handle=lease},gates={focused=true,menu_open=false}}
    local plan,batch={},{status="available",epoch=epoch,native_casts=2,budget_exhausted=false,
        local_actor_excluded=true,owned_bodies_excluded=true,rays={}}
    for i=1,2 do
        plan[i]={from=vector.create(i-1,2,0),to=vector.create(i-1,0,0)}
        batch.rays[i]={status="hit",fraction=.5,position=vector.create(i-1,1,0),normal_available=true,
            normal=vector.create(0,1,0),surface_velocity_available=true,surface_velocity=vector.create(0,0,0),motion="measured"}
    end
    return frame,plan,batch
end
local function category(batch)
    batch.local_actor_excluded=false
    batch.named_actor_categories_absent=true
    batch.requested_query_preset="camera"
end
local function unavailable(batch)
    batch.status="unavailable";batch.reason="hit_categories_unavailable";batch.native_casts=0
    batch.local_actor_excluded=false;batch.owned_bodies_excluded=false
    batch.rays={{status="unavailable"},{status="unavailable"}}
end
function Tests.run()
    local cases,assertions=0,0
    local function check(v,why) assertions+=1;assert(v,why) end
    local function case() cases+=1 end
    case() do
        check(Contact.CATEGORY_WHEEL_LANE_QUALIFIED==false and table.isfrozen(Contact),"the tracked category gate stays false and frozen")
        check(not pcall(function() Contact.CATEGORY_WHEEL_LANE_QUALIFIED=true end),"a caller cannot flip the export")
        check(Qualified.CATEGORY_WHEEL_LANE_QUALIFIED==true and Qualified.actor_lane_qualified({actor_lane="named_categories_absent"}),
            "only the generated Contact copy continues the category chain")
        check(Contact.actor_lane_qualified({actor_lane="identity"}) and not Contact.actor_lane_qualified({actor_lane="named_categories_absent"})
            and not Contact.actor_lane_qualified({actor_lane="none"}),"identity and category are distinct lanes")
        check(not Contact.actor_lane_qualified(nil) and not Contact.actor_lane_qualified(true) and not Contact.actor_lane_qualified({}),
            "malformed or absent lane records grant nothing")
    end
    case() do
        local frame,plan,batch=fixture();local out=Contact.decode(frame,plan,batch)
        check(out.valid and out.query.actor_lane=="identity" and out.query.local_actor_excluded==true,"identity remains the actual raw fact")
        check(Contact.actor_lane_qualified(out.query) and out.force_ready==false and out.support.known==false,"identity grants no physical support")
    end
    case() do
        local frame,plan,batch=fixture();batch.local_actor_excluded=false
        local out=Contact.decode(frame,plan,batch)
        check(out.valid and out.query.actor_lane=="none" and out.force_reason=="actor_exclusion_unqualified","no claim remains unqualified")
        check(out.query.local_actor_excluded==false and out.force_ready==false and out.support.known==false,"absence never becomes identity or support")
    end
    case() do
        local frame,plan,batch=fixture();category(batch)
        local out=Contact.decode(frame,plan,batch)
        check(out.valid and out.query.actor_lane=="named_categories_absent" and out.force_reason=="actor_category_lane_unqualified",
            "a genuine SDK category claim cannot open the tracked lane")
        check(out.query.local_actor_excluded==false and out.force_ready==false and out.support.known==false,"the category claim never becomes identity")
        batch.named_actor_categories_absent=false
        check(out.query.named_actor_categories_absent==true and not pcall(function() out.query.actor_lane="identity" end),"the copied lane is detached and frozen")
    end
    case() do
        local frame,plan,batch=fixture();category(batch)
        local out=Qualified.decode(frame,plan,batch)
        check(out.valid and Qualified.actor_lane_qualified(out.query) and out.force_reason=="physical_support_unqualified","the qualified copy reaches the unchanged support chain")
        check(out.query.local_actor_excluded==false and out.force_ready==false and out.support.known==false,"even the trial copy creates no SDK identity/support fact")
    end
    for _,variant in ipairs({
        {"contact_measurements_unknown",function(batch) batch.rays[1].normal_available=false;batch.rays[1].normal=nil end},
        {"clear_force_geometry_unknown",function(batch) batch.rays={{status="clear"},{status="clear"}} end},
        {"surface_velocity_outside_force_bounds",function(batch) batch.rays[1].surface_velocity=vector.create(51,0,0) end},
    }) do case() do
        local frame,plan,batch=fixture();category(batch);variant[2](batch)
        local out=Qualified.decode(frame,plan,batch)
        check(out.valid and Qualified.actor_lane_qualified(out.query) and out.force_reason==variant[1],"the category lane preserves chain step "..variant[1])
        check(out.force_ready==false and out.support.known==false and out.query.local_actor_excluded==false,"later chain steps grant no identity/support")
    end end
    for _,variant in ipairs({
        {function(batch) batch.named_actor_categories_absent="true" end,"malformed_batch"},
        {function(batch) batch.named_actor_categories_absent=1 end,"malformed_batch"},
        {function(batch) batch.named_actor_categories_absent={} end,"malformed_batch"},
        {function(batch) batch.local_actor_excluded=true end,"malformed_batch"},
        {function(batch) batch.requested_query_preset="terrain" end,"malformed_batch"},
        {function(batch) batch.named_actor_categories_absent=false;batch.requested_query_preset="terrain" end,"malformed_batch"},
        {function(batch) batch.requested_query_preset=nil end,"malformed_batch"},
        {function(batch) batch.named_actor_categories_absent=false;batch.requested_query_preset=nil end,"malformed_batch"},
        {function(batch) unavailable(batch) end,"malformed_unavailable_batch"},
    }) do case() do
        local frame,plan,batch=fixture();category(batch);variant[1](batch)
        local out=Qualified.decode(frame,plan,batch)
        check(not out.valid and out.reason==variant[2],"malformed category combinations refuse the whole batch")
        check(out.query.actor_lane=="none" and out.force_ready==false and out.support.known==false,"a refused combination grants no lane")
    end end
    case() do
        local frame,plan,batch=fixture();category(batch);unavailable(batch);batch.named_actor_categories_absent=false
        local count=0;for _ in pairs(batch) do count+=1 end
        check(count==10,"the honest unavailable DTO can carry all ten fields")
        local out=Contact.decode(frame,plan,batch)
        check(out.valid and out.status=="unavailable" and out.reason=="hit_categories_unavailable" and out.query.actor_lane=="none","ten fields retain an honest refusal")
        batch.extra=false;local extra=Contact.decode(frame,plan,batch)
        check(not extra.valid and extra.reason=="malformed_batch","an eleventh field is refused")
        check(out.query.named_actor_categories_absent==false and out.query.local_actor_excluded==false and out.force_ready==false,"false is not an identity or support claim")
    end
    case() do
        local frame,plan,batch=fixture();category(batch);batch.rays[1].in_categories=0
        local out=Qualified.decode(frame,plan,batch)
        check(not out.valid and out.reason=="malformed_hit","the production hit schema still refuses diagnostic category words")
        check(out.query.actor_lane=="none" and out.force_ready==false,"a diagnostic value cannot qualify the lane")
    end
    local function guard_batch(frame)
        local plan=Guard.plan({serial=frame.serial,seconds=frame.seconds,owner=newproxy(),body=frame.body,query_frame=frame})
        if not plan then return nil end
        local batch={status="available",epoch=frame.physics_epoch,native_casts=#plan.rays,budget_exhausted=false,
            local_actor_excluded=false,owned_bodies_excluded=true,named_actor_categories_absent=true,
            requested_query_preset="camera",rays={}}
        for i=1,#plan.rays do batch.rays[i]={status="clear"} end
        return plan,batch
    end
    case() do
        local frame=fixture();local plan,batch=guard_batch(frame)
        check(plan~=nil,"the Guard refusal uses a real issued plan")
        local out=Guard.witness(plan,batch)
        check(not out.available and out.reason=="guard_batch_not_raw","Guard's unchanged raw schema refuses the category field")
    end
    case() do
        local frame=fixture();local plan,batch=guard_batch(frame)
        check(plan~=nil,"the second Guard case is bound to its actual frame")
        local decoded=Qualified.decode(frame,plan.rays,batch)
        check(decoded.valid and Qualified.actor_lane_qualified(decoded.query) and decoded.query.local_actor_excluded==false,
            "the category decode is real and has no identity claim")
        local copied=Guard.witness(plan,decoded)
        check(not copied.available and copied.reason=="guard_batch_not_raw","a public decoded copy is refused before Guard's identity check")
        batch.named_actor_categories_absent=nil
        local stripped=Guard.witness(plan,batch)
        check(not stripped.available and stripped.reason=="guard_exclusion_unqualified","removing the category field cannot launder its false identity fact")
    end
    return {cases=cases,assertions=assertions,native_actions=0}
end
return Tests

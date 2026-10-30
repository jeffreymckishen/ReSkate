-- Decode copied query facts only. Ride owns every query, clock and effect.
local Frame = require("./frame_identity")
local M = require("./force_math")
local Contact = {}
-- Only an owner-qualified private trial copy may change this literal.
local CATEGORY_WHEEL_LANE_QUALIFIED=true
Contact.CATEGORY_WHEEL_LANE_QUALIFIED=CATEGORY_WHEEL_LANE_QUALIFIED
local MAX_RAYS, MAX_CASTS = 32, 64
local source_fields = {"generation", "user", "sequence", "source_epoch", "context_generation", "observation_serial", "observed_ms", "packet"}
local batch_fields = {status=true,reason=true,native_casts=true,budget_exhausted=true,epoch=true,local_actor_excluded=true,owned_bodies_excluded=true,rays=true,requested_query_preset=true,named_actor_categories_absent=true}
local hit_fields = {status=true,position=true,fraction=true,motion=true,normal_available=true,surface_velocity_available=true,normal=true,surface_velocity=true,body=true}

local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function integer(v,lo,hi) return finite(v) and v>=lo and v<=hi and v%1==0 end
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function fields(t, allowed, limit)
    if not plain(t) then return false end
    local count=0
    for key in pairs(t) do
        count+=1
        if count>limit or not allowed[key] then return false end
    end
    return true
end
local function dense(t,count)
    if not plain(t) or #t~=count then return false end
    local seen=0
    for key in pairs(t) do
        seen+=1
        if seen>count or not integer(key,1,count) then return false end
    end
    return seen==count
end
local function vector_copy(v,bound)
    if typeof(v)~="vector" then return nil end
    local out={v.x,v.y,v.z}
    for i=1,3 do if not finite(out[i]) or math.abs(out[i])>bound then return nil end end
    return out
end
local function freeze(t)
    for _,v in pairs(t) do if type(v)=="table" then freeze(v) end end
    return table.freeze(t)
end
local function base()
    return {valid=false,status="unavailable",reason="malformed_input",rays={},
        query={epoch_matches=false,accounting_known=false,measurements_complete=false,actor_lane="none"},
        support={known=false,grounded_known=false,reason="wheel_support_not_qualified"},
        force_ready=false,force_reason="physical_support_unqualified"}
end
local function accounting(out,batch)
    if not plain(batch) then return end
    if integer(batch.native_casts,0,MAX_CASTS) then
        out.query.native_casts=batch.native_casts
        out.query.accounting_known=true
    end
    if type(batch.budget_exhausted)=="boolean" then out.query.budget_exhausted=batch.budget_exhausted end
    if type(batch.local_actor_excluded)=="boolean" then out.query.local_actor_excluded=batch.local_actor_excluded end
    if type(batch.owned_bodies_excluded)=="boolean" then out.query.owned_bodies_excluded=batch.owned_bodies_excluded end
    if type(batch.named_actor_categories_absent)=="boolean" then out.query.named_actor_categories_absent=batch.named_actor_categories_absent end
    if batch.status=="available" or batch.status=="unavailable" then out.query.status=batch.status end
    if type(batch.reason)=="string" and #batch.reason>0 and #batch.reason<=200 then out.query.reason=batch.reason end
end
local function reject(out,reason,count)
    out.valid=false;out.status="unavailable";out.reason=reason
    out.force_reason=reason;out.query.measurements_complete=false;out.rays={}
    for i=1,count or 0 do
        out.rays[i]={status="unavailable",visual_hit=false,normal_available=false,surface_velocity_available=false,motion="unknown"}
    end
    return freeze(out)
end
local function plan_copy(plan)
    if not plain(plan) or not integer(#plan,1,MAX_RAYS) or not dense(plan,#plan) then return nil end
    local out={}
    for i=1,#plan do
        local ray=plan[i]
        if not fields(ray,{from=true,to=true},2) then return nil end
        local a,b=vector_copy(ray.from,100000),vector_copy(ray.to,100000)
        if not a or not b then return nil end
        local delta={}
        local distance=0
        for axis=1,3 do delta[axis]=b[axis]-a[axis];distance+=delta[axis]*delta[axis] end
        distance=math.sqrt(distance)
        if not finite(distance) or distance<.00001 or distance>1000 then return nil end
        out[i]={from=a,to=b,delta=delta,distance=distance}
    end
    return out
end
local function hit_copy(raw,ray)
    if not fields(raw,hit_fields,9) or raw.status~="hit" or not finite(raw.fraction) or raw.fraction<0 or raw.fraction>1
        or type(raw.normal_available)~="boolean" or type(raw.surface_velocity_available)~="boolean"
        or (raw.body~=nil and type(raw.body)~="userdata") then return nil end
    local point=vector_copy(raw.position,100000)
    if not point then return nil end
    for axis=1,3 do
        if math.abs(point[axis]-(ray.from[axis]+ray.delta[axis]*raw.fraction))>.025 then return nil end
    end
    local out={status="hit",visual_hit=true,position=point,fraction=raw.fraction,
        normal_available=raw.normal_available,surface_velocity_available=raw.surface_velocity_available,
        motion=raw.motion}
    if raw.normal_available then
        out.normal=vector_copy(raw.normal,1.01)
        if not out.normal then return nil end
        local norm,facing=0,0
        for axis=1,3 do norm+=out.normal[axis]*out.normal[axis];facing+=ray.delta[axis]*out.normal[axis] end
        if norm<.98 or norm>1.02 or facing>1e-4*ray.distance then return nil end
    elseif raw.normal~=nil then return nil end
    if raw.surface_velocity_available then
        out.surface_velocity=vector_copy(raw.surface_velocity,100)
        if not out.surface_velocity or raw.motion~="measured" then return nil end
    elseif raw.surface_velocity~=nil or raw.motion~="unknown" then return nil end
    return out
end
local function decode(out,frame,plan,batch)
    local checked=Frame.copy(frame)
    if not checked then return reject(out,"invalid_frame") end
    out.binding={body_handle=checked.body_handle,physics_epoch=checked.physics_epoch,lease_handle=checked.source.lease_handle}
    local source={}
    for _,key in ipairs(source_fields) do source[key]=checked.source[key] end
    out.frame={serial=checked.serial,time=checked.time,seconds=checked.seconds,source=source}
    if checked.valid~=true or checked.fresh~=true then return reject(out,"frame_not_current") end
    if math.abs(checked.seconds-1/60)>1e-7 then return reject(out,"unsupported_native_step") end
    local rays=plan_copy(plan)
    if not rays then return reject(out,"invalid_ray_plan") end
    local count=#rays
    if not fields(batch,batch_fields,10) or (batch.status~="available" and batch.status~="unavailable")
        or type(batch.budget_exhausted)~="boolean" or type(batch.local_actor_excluded)~="boolean"
        or type(batch.owned_bodies_excluded)~="boolean" or not dense(batch.rays,count)
        or (batch.requested_query_preset~=nil and batch.requested_query_preset~="camera" and batch.requested_query_preset~="terrain")
        or (batch.named_actor_categories_absent~=nil and (type(batch.named_actor_categories_absent)~="boolean"
            or batch.requested_query_preset~="camera"))
        or (batch.named_actor_categories_absent==true and batch.local_actor_excluded) then
        return reject(out,"malformed_batch",count)
    end
    -- Request metadata only: this proves neither a filter ran nor support/exclusions.
    if batch.requested_query_preset~=nil then out.query.requested_query_preset=batch.requested_query_preset end
    out.query.epoch_matches=rawequal(batch.epoch,checked.physics_epoch)
    if not out.query.epoch_matches then return reject(out,"query_epoch_mismatch",count) end
    if batch.native_casts~=nil and not out.query.accounting_known then return reject(out,"invalid_cast_accounting",count) end
    if batch.status=="unavailable" then
        if type(batch.reason)~="string" or #batch.reason==0 or #batch.reason>200
            or batch.local_actor_excluded or batch.owned_bodies_excluded or batch.named_actor_categories_absent==true then
            return reject(out,"malformed_unavailable_batch",count)
        end
        for i=1,count do
            if not fields(batch.rays[i],{status=true},1) or batch.rays[i].status~="unavailable" then
                return reject(out,"partial_unavailable_batch",count)
            end
            out.rays[i]={status="unavailable",visual_hit=false,normal_available=false,surface_velocity_available=false,motion="unknown"}
        end
        out.valid=true;out.reason=batch.reason;out.force_reason=batch.reason
        return freeze(out)
    end
    if batch.reason~=nil or batch.budget_exhausted or not batch.owned_bodies_excluded or not out.query.accounting_known
        or batch.native_casts<count or batch.native_casts>count*2 then return reject(out,"malformed_available_batch",count) end
    local complete=true
    local has_clear,force_velocity_outside=false,false
    for i=1,count do
        local raw=batch.rays[i]
        if plain(raw) and raw.status=="clear" and fields(raw,{status=true},1) then
            out.rays[i]={status="clear",visual_hit=false,normal_available=false,surface_velocity_available=false,motion="unknown"}
            has_clear=true
        else
            out.rays[i]=hit_copy(raw,rays[i])
            if not out.rays[i] then return reject(out,"malformed_hit",count) end
            local hit=out.rays[i]
            complete=complete and hit.normal_available and hit.surface_velocity_available
            if hit.surface_velocity then
                for axis=1,3 do force_velocity_outside=force_velocity_outside or math.abs(hit.surface_velocity[axis])>50 end
            end
        end
    end
    out.valid=true;out.status="available";out.reason=nil
    out.query.measurements_complete=complete
    out.query.actor_lane=batch.local_actor_excluded and "identity"
        or batch.named_actor_categories_absent==true and "named_categories_absent" or "none"
    if out.query.actor_lane=="none" then out.force_reason="actor_exclusion_unqualified"
    elseif out.query.actor_lane=="named_categories_absent" and not CATEGORY_WHEEL_LANE_QUALIFIED then
        out.force_reason="actor_category_lane_unqualified"
    elseif not complete then out.force_reason="contact_measurements_unknown"
    elseif has_clear then out.force_reason="clear_force_geometry_unknown"
    elseif force_velocity_outside then out.force_reason="surface_velocity_outside_force_bounds"
    else out.force_reason="physical_support_unqualified" end
    return freeze(out)
end
function Contact.actor_lane_qualified(query)
    if not plain(query) then return false end
    return query.actor_lane=="identity" or (query.actor_lane=="named_categories_absent" and CATEGORY_WHEEL_LANE_QUALIFIED)
end
function Contact.decode(frame,ray_plan,batch)
    local out=base();accounting(out,batch)
    local ok,decoded=pcall(decode,out,frame,ray_plan,batch)
    if ok then return decoded end
    return reject(out,"malformed_input")
end

-- A bounded lower-arc stencil, not a shape sweep. Every selected point must
-- have a current measured ray hit. Its normal remains that surface's normal.
-- The central rays retain the original spherical-radius contact convention.
function Contact.wheel_plan(frame,geometry,gravity,probe_extra)
    if type(frame)~="table" or not M.valid_body(frame.body) or type(geometry)~="table"
        or not M.vec(geometry.com,10) or not M.vec(geometry.front_axle,10)
        or not M.vec(geometry.rear_axle,10) or not M.finite(geometry.wheel_radius)
        or geometry.wheel_radius<.01 or geometry.wheel_radius>2
        or not M.finite(probe_extra) or probe_extra<.15 or probe_extra>.75 then return nil end
    local down=M.unit(gravity)
    local heading=down and M.turn(frame.body.orientation,{0,0,1})
    heading=heading and M.unit(M.sub(heading,M.mul(down,M.dot(heading,down))))
    if not down or not heading then return nil end
    local radius=geometry.wheel_radius
    local rays,centers,rims={},{},{}
    local function native(p)return vector.create(p[1],p[2],p[3])end
    for i,axle in ipairs({geometry.front_axle,geometry.rear_axle})do
        local center=M.add(frame.body.center_of_mass,M.turn(frame.body.orientation,M.sub(axle,geometry.com)))
        if not M.vec(center,100000) then return nil end
        centers[i]=center
        -- Quarter-radius spacing keeps the last rim-to-central height
        -- change about8mm, rather than the old89mm late curb step.
        for _,offset in ipairs({0,.25,.5,.75,-.25,-.5,-.75})do
            local rim=offset~=0 and M.add(center,M.add(M.mul(heading,offset*radius),
                M.mul(down,math.sqrt(1-offset*offset)*radius))) or nil
            local from=rim and M.sub(rim,M.mul(down,radius)) or center
            local to=rim and M.add(rim,M.mul(down,probe_extra))
                or M.add(center,M.mul(down,radius+probe_extra))
            if not M.vec(from,100000) or not M.vec(to,100000) then return nil end
            rays[#rays+1]={from=native(from),to=native(to)}
            rims[#rims+1]=rim or false
        end
    end
    return freeze(rays),centers,rims
end

-- This pure projection grants no epoch, ownership or actor authority. Ride
-- validates the complete decoded batch binding before calling it.
function Contact.wheel_samples(frame,rays,centers,rims,geometry)
    if type(rays)~="table" or #rays~=14 or type(centers)~="table" or #centers~=2
        or type(rims)~="table" or #rims~=14 then return nil,"wheel arc batch shape unavailable" end
    local samples={}
    local forward=M.turn(frame.body.orientation,{0,0,1})
    for i=1,2 do
        local selected
        for j=1,7 do
            local index=(i-1)*7+j
            local ray,rim=rays[index],rims[index]
            if type(ray)~="table" then return nil,"measured wheel surface unavailable" end
            if ray.status~="clear" then
                if ray.status~="hit" or ray.normal_available~=true or ray.surface_velocity_available~=true
                    or ray.motion~="measured" or not M.vec(ray.position,100000)
                    or not M.vec(ray.normal,1) or not M.vec(ray.surface_velocity,50)
                    or math.abs(M.length(ray.normal)-1)>.001 then
                    return nil,"measured wheel surface unavailable"
                end
                local basis=M.basis(ray.normal,forward)
                if not basis then return nil,"measured wheel tangent unavailable" end
                local separation=rim and M.dot(M.sub(rim,ray.position),basis.normal)
                    or M.dot(M.sub(centers[i],ray.position),basis.normal)-geometry.wheel_radius
                if not M.finite(separation) or separation<-.10 then
                    return nil,"wheel penetration unavailable or excessive"
                end
                if not selected or separation<selected.separation then
                    selected={contact={status="hit",point=M.copy(ray.position),normal=basis.normal,
                        forward=basis.forward,surface_velocity=M.copy(ray.surface_velocity)},
                        separation=separation,wheel_center=M.copy(centers[i]),wheel_radius=geometry.wheel_radius,
                        verified_plane=false,balance_normal_available=false}
                    if rim then selected.wheel_rim=M.copy(rim) end
                end
            end
        end
        samples[i]=selected or {contact={status="clear"}}
    end
    return samples
end
-- This projection is for storage/display, never for effect or identity gates.
function Contact.public_snapshot(value)
    local budget=0
    local function copy(v,depth)
        local kind=type(v)
        if kind=="nil" or kind=="boolean" then return v end
        if kind=="number" then assert(finite(v),"nonfinite");return v end
        if kind=="string" then assert(#v<=512,"oversized");return v end
        assert(plain(v) and depth<8,"opaque_or_deep")
        local out={}
        for key,item in pairs(v) do
            budget+=1;assert(budget<=4096,"too_many_fields")
            assert(type(key)=="string" and #key<=80 or integer(key,1,MAX_RAYS),"invalid_key")
            if key~="binding" then out[key]=copy(item,depth+1) end
        end
        return out
    end
    local ok,out=pcall(copy,value,0)
    if not ok or not plain(out) then return nil,"invalid_public_snapshot" end
    return freeze(out)
end
return table.freeze(Contact)

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

-- These three phases use at most fourteen nearest segments for both wheels.
-- Vertical neighbours discover a height change; they never replace the
-- measured central face. A secondary edge needs its own measured wall and
-- three local witnesses. Arbitrary topology beyond those witnesses is unknown.
local function native_point(p)return vector.create(p[1],p[2],p[3])end
local function segment(a,b)return {from=native_point(a),to=native_point(b)}end
local function measured(row)
    return type(row)=="table" and row.status=="hit" and row.normal_available==true
        and row.surface_velocity_available==true and row.motion=="measured"
        and M.vec(row.position,100000) and M.vec(row.normal,1.001)
        and math.abs(M.length(row.normal)-1)<.001 and M.vec(row.surface_velocity,50)
end
local function complete(rays,count)
    if type(rays)~="table" or #rays~=count then return false end
    for _,row in ipairs(rays)do
        if type(row)~="table" or row.status~="clear" and not measured(row) then return false end
    end
    return true
end
local function stationary(v)return M.vec(v,50) and M.length(v)<=1e-6 end
local function plane_edge(center,top,nt,wall,nw)
    local c=M.dot(nt,nw)
    local d=1-c*c
    if d<.75 then return nil end
    local rt,rw=M.dot(nt,M.sub(center,top)),M.dot(nw,M.sub(center,wall))
    local a,b=(rt-c*rw)/d,(rw-c*rt)/d
    return M.sub(M.sub(center,M.mul(nt,a)),M.mul(nw,b)),a,b,c
end
local function witness(row)
    return {point=M.copy(row.position),normal=M.copy(row.normal),surface_velocity=M.copy(row.surface_velocity)}
end
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
    local rays,centers={},{}
    for i,axle in ipairs({geometry.front_axle,geometry.rear_axle})do
        local center=M.add(frame.body.center_of_mass,M.turn(frame.body.orientation,M.sub(axle,geometry.com)))
        if not M.vec(center,100000) then return nil end
        centers[i]=center
        for _,offset in ipairs({0,1,-1})do
            local from=M.add(center,M.mul(heading,offset*radius))
            local to=M.add(from,M.mul(down,radius+probe_extra))
            if not M.vec(from,100000) or not M.vec(to,100000) then return nil end
            rays[#rays+1]=segment(from,to)
        end
    end
    return freeze(rays),centers,{up=M.mul(down,-1),heading=heading}
end

function Contact.edge_plan(frame,rays,centers,context,geometry)
    if not complete(rays,6) or type(centers)~="table" or #centers~=2
        or type(context)~="table" or not M.vec(context.up,1.001) then
        return nil,"measured wheel surface unavailable"
    end
    local plan,candidates={},{}
    for i=1,2 do
        local high,low
        for j=1,3 do
            local row=rays[(i-1)*3+j]
            if row.status=="hit" and M.dot(row.normal,context.up)>=.95 then
                local h=M.dot(row.position,context.up)
                if not high or h>M.dot(high.position,context.up) then high=row end
                if not low or h<M.dot(low.position,context.up) then low=row end
            end
        end
        if high and low then
            local height=M.dot(M.sub(high.position,low.position),context.up)
            -- Gravity height also changes across an ordinary inclined road.
            -- Only suppress this optional edge candidate when every current
            -- wheel observation proves the same local plane, in both measured
            -- normal directions and within the existing witness tolerance.
            -- Unknown/clear/noncoplanar rows cannot qualify this classification;
            -- real wall evidence still follows every unchanged facet guard.
            local common_plane=true
            for j=1,3 do
                local row=rays[(i-1)*3+j]
                if row.status~="hit" then common_plane=false;break end
                local delta=M.sub(row.position,high.position)
                if M.dot(row.normal,high.normal)<=.995
                    or math.abs(M.dot(delta,high.normal))>.003
                    or math.abs(M.dot(delta,row.normal))>.003 then
                    common_plane=false;break
                end
            end
            if not common_plane and height>.015 and height<=geometry.wheel_radius*.75
                and M.dot(high.normal,low.normal)>.995 then
                local from=M.add(low.position,M.mul(context.up,height*.5))
                local to=M.sub(high.position,M.mul(context.up,height*.5))
                plan[#plan+1]=segment(from,to)
                candidates[#candidates+1]={wheel=i,top=high,lower=low,up=M.copy(context.up),
                    center=M.copy(centers[i]),height=height}
            end
        end
    end
    return freeze(plan),candidates
end

-- A nearest segment aimed at a wall can instead enter the already measured
-- top floor on a shallow road/seam. This proves no second facet or edge.
-- It may retain only the original central contacts, never synthesize support.
local function floor_continuation(candidate,wall,geometry)
    local top,lower=candidate.top,candidate.lower
    local radius=geometry.wheel_radius
    if not measured(top) or not measured(lower) or not measured(wall)
        or not stationary(top.surface_velocity) or not stationary(wall.surface_velocity)
        or not stationary(lower.surface_velocity) or not M.finite(radius) or radius<.01 or radius>2
        or not M.vec(candidate.center,100000) or not M.vec(candidate.up,1.001)
        or math.abs(M.length(candidate.up)-1)>.001 or not M.finite(candidate.height)
        or candidate.height<=.015 or candidate.height>radius*.75 then return false end
    local nt,nw,up=top.normal,wall.normal,candidate.up
    if M.dot(nt,nw)<.999 or M.dot(nt,up)<.95 or M.dot(nw,up)<.95
        or M.dot(lower.normal,up)<.95 or M.dot(nt,lower.normal)<=.995 then return false end
    local offset=M.sub(wall.position,top.position)
    if math.abs(M.dot(offset,nt))>.003 or math.abs(M.dot(offset,nw))>.003 then return false end
    -- Use the same bounded segment and original vertical-column envelope.
    -- These checks cannot bless an unknown result or a farther replacement.
    for _,row in ipairs({top,lower})do
        local arm=M.sub(row.position,candidate.center)
        local vertical=M.dot(arm,up)
        if vertical>.003 or vertical< -(radius+.75+.003)
            or M.length(M.sub(arm,M.mul(up,vertical)))>radius+.003 then return false end
    end
    local span=M.sub(top.position,lower.position)
    if math.abs(M.dot(span,up)-candidate.height)>.003 then return false end
    local delta=M.sub(span,M.mul(up,candidate.height))
    local distance=M.length(delta)
    if distance<.00001 or distance>2*radius+.003 or not M.finite(wall.fraction)
        or wall.fraction<0 or wall.fraction>1 or M.dot(delta,nw)>1e-4*distance then return false end
    local from=M.add(lower.position,M.mul(up,candidate.height*.5))
    local expected=M.add(from,M.mul(delta,wall.fraction))
    return M.length(M.sub(wall.position,expected))<=.003
end

function Contact.edge_witness_plan(frame,rays,candidates,geometry)
    if type(candidates)~="table" or not complete(rays,#candidates) then return nil,"measured edge wall unavailable" end
    local plan,features={},{}
    for i,candidate in ipairs(candidates)do
        local wall=rays[i]
        if wall.status=="hit" then
            if floor_continuation(candidate,wall,geometry) then continue end
            local top,lower=candidate.top,candidate.lower
            local nt,nw=top.normal,wall.normal
            local outside=M.unit(M.sub(lower.position,top.position))
            local anchor,top_distance,wall_distance,c=plane_edge(candidate.center,top.position,nt,wall.position,nw)
            -- Preserve the original first-failing order and acceptance rule.
            -- A bounded refusal reason records geometry, not contact authority.
            local failed
            if not anchor then failed="plane_pair"
            elseif math.abs(M.dot(nw,candidate.up))>.2 then failed="wall_up"
            elseif not outside then failed="outside_direction"
            elseif M.dot(nw,outside)<.8 then failed="wall_outside"
            elseif not stationary(top.surface_velocity) then failed="top_velocity"
            elseif not stationary(wall.surface_velocity) then failed="wall_velocity"
            elseif not stationary(lower.surface_velocity) then failed="lower_velocity" end
            if failed then
                local function velocity(v)
                    return M.vec(v,50) and string.format("%.5g",M.length(v)) or "bad"
                end
                local top_offset=M.dot(M.sub(wall.position,top.position),nt)
                local reason=string.format("edge facets:%s nd=%.5g up=%.5g out=%s pt=%.5g apt=%.5g v=%s/%s/%s",failed,
                    M.dot(nt,nw),M.dot(nw,candidate.up),outside and string.format("%.5g",M.dot(nw,outside)) or "none",
                    top_offset,math.abs(top_offset),
                    velocity(top.surface_velocity),velocity(wall.surface_velocity),velocity(lower.surface_velocity))
                return nil,string.sub(reason,1,200)
            end
            local side=M.unit(M.sub(nw,M.mul(nt,c)))
            local wall_up=M.unit(M.sub(nt,M.mul(nw,c)))
            local extent=math.min(.04,geometry.wheel_radius*.15)
            local below=math.min(.04,candidate.height*.35)
            local inside=M.sub(anchor,M.mul(side,extent))
            local on_wall=M.sub(anchor,M.mul(wall_up,below))
            local outside_point=M.add(anchor,M.mul(side,extent))
            plan[#plan+1]=segment(M.add(inside,M.mul(candidate.up,.08)),M.sub(inside,M.mul(candidate.up,.08)))
            plan[#plan+1]=segment(M.add(on_wall,M.mul(nw,.08)),M.sub(on_wall,M.mul(nw,.08)))
            plan[#plan+1]=segment(M.add(outside_point,M.mul(candidate.up,.08)),
                M.sub(outside_point,M.mul(candidate.up,candidate.height+.08)))
            features[#features+1]={wheel=candidate.wheel,top_point=M.copy(top.position),top_normal=M.copy(nt),
                top_velocity=M.copy(top.surface_velocity),wall_point=M.copy(wall.position),wall_normal=M.copy(nw),
                wall_velocity=M.copy(wall.surface_velocity),lower_point=M.copy(lower.position),lower_normal=M.copy(lower.normal),
                lower_velocity=M.copy(lower.surface_velocity),up=M.copy(candidate.up),anchor=anchor,extent=extent,
                edge_height=candidate.height,wall_below=below,topology_known=false}
        end
    end
    return freeze(plan),features
end

-- This is a wheel constraint derived from two measured facets, not a native
-- collision or a measured surface normal. It is rebuilt after forecasting.
-- The local witnesses prove this neighbourhood only; no facet identity is
-- exposed by the nearest-segment API, and arbitrary topology stays unknown.
function Contact.edge_sample(center,radius,feature,forward)
    if not M.vec(center,100000) or not M.finite(radius) or radius<.01 or radius>2
        or type(feature)~="table" or feature.topology_known~=false
        or not M.vec(forward,1.001) then return nil,"edge geometry unavailable" end
    local f=feature
    for _,key in ipairs({"top_point","wall_point","lower_point","anchor"})do
        if not M.vec(f[key],100000) then return nil,"edge facet point unavailable" end
    end
    for _,key in ipairs({"top_normal","wall_normal","lower_normal","up"})do
        if not M.vec(f[key],1.001) or math.abs(M.length(f[key])-1)>.001 then return nil,"edge facet normal unavailable" end
    end
    for _,key in ipairs({"top_velocity","wall_velocity","lower_velocity"})do
        if not stationary(f[key]) then return nil,"moving edge feature unavailable" end
    end
    if not M.finite(f.extent) or f.extent<.005 or f.extent>math.min(.04,radius*.15)+1e-8
        or not M.finite(f.edge_height) or f.edge_height<=.015 or f.edge_height>radius*.75
        or not M.finite(f.wall_below) or f.wall_below<.005 or f.wall_below>.04
        or M.dot(f.top_normal,f.up)<.95 or M.dot(f.lower_normal,f.up)<.95
        or M.dot(f.top_normal,f.lower_normal)<.995 or math.abs(M.dot(f.wall_normal,f.up))>.2 then
        return nil,"edge local bounds unavailable"
    end
    local nt,nw=f.top_normal,f.wall_normal
    local edge,a,b=plane_edge(center,f.top_point,nt,f.wall_point,nw)
    if not edge or math.abs(M.dot(M.sub(f.anchor,f.top_point),nt))>.003
        or math.abs(M.dot(M.sub(f.anchor,f.wall_point),nw))>.003 then return nil,"edge planes unavailable" end
    for _,key in ipairs({"top_witness","wall_witness","outside_witness"})do
        local w=f[key]
        if type(w)~="table" or not M.vec(w.point,100000) or not M.vec(w.normal,1.001)
            or math.abs(M.length(w.normal)-1)>.001 or not stationary(w.surface_velocity)
            or M.length(M.sub(w.point,f.anchor))>radius then return nil,"edge local witness unavailable" end
    end
    local tw,ww,ow=f.top_witness,f.wall_witness,f.outside_witness
    local ti=M.dot(M.sub(tw.point,f.anchor),nw)
    local wb=M.dot(M.sub(ww.point,f.anchor),nt)
    local oo=M.dot(M.sub(ow.point,f.anchor),nw)
    if math.abs(M.dot(M.sub(tw.point,f.top_point),nt))>.003 or M.dot(tw.normal,nt)<.999
        or ti>-.5*f.extent or ti< -1.5*f.extent
        or math.abs(M.dot(M.sub(ww.point,f.wall_point),nw))>.003 or M.dot(ww.normal,nw)<.999
        or wb>-.5*f.wall_below or wb< -1.5*f.wall_below
        or math.abs(M.dot(M.sub(ow.point,f.lower_point),f.lower_normal))>.003 or M.dot(ow.normal,f.lower_normal)<.999
        or oo<.5*f.extent or oo>1.5*f.extent
        or math.abs(M.dot(M.sub(f.top_point,f.lower_point),f.up)-f.edge_height)>.003 then
        return nil,"incoherent edge witnesses"
    end
    local function clear()
        return {contact={status="clear"},wheel_center=M.copy(center),wheel_radius=radius,edge_feature=M.copy(f)}
    end
    if b< -1e-7 then
        -- The forecast may enter the witnessed top before its old central
        -- lower-floor query catches up. Only the small observed inside
        -- neighbourhood may become a top face; the infinite plane cannot.
        local height=M.dot(M.sub(center,f.top_point),nt)
        local point=M.sub(center,M.mul(nt,height))
        local side=M.unit(M.sub(nw,M.mul(nt,M.dot(nt,nw))))
        local line=M.unit(M.cross(nt,nw))
        local offset=M.sub(point,f.anchor)
        local inside=M.dot(offset,side)
        if inside>1e-7 or inside< -f.extent or math.abs(M.dot(offset,line))>f.extent then return clear() end
        local basis=M.basis(nt,forward)
        local gap=height-radius
        if not basis or gap<-.10 then return nil,"edge top penetration unavailable or excessive" end
        return {kind="top_face",contact={status="hit",point=point,normal=basis.normal,forward=basis.forward,
            surface_velocity={0,0,0}},separation=gap,wheel_center=M.copy(center),wheel_radius=radius,
            wheel_rim=M.sub(center,M.mul(nt,radius)),verified_plane=false,balance_normal_available=true,
            balance_normal=M.copy(nt),edge_feature=M.copy(f)}
    end
    if M.length(M.sub(edge,f.anchor))>f.extent or a< -1e-7 then return clear() end
    local radial=M.sub(center,edge)
    local distance=M.length(radial)
    if distance<1e-8 or distance>radius+.15 then return clear() end
    local basis=M.basis(M.mul(radial,1/distance),forward)
    local gap=distance-radius
    if not basis or gap<-.10 then return nil,"edge wheel penetration unavailable or excessive" end
    return {kind="edge",contact={status="hit",point=edge,normal=basis.normal,forward=basis.forward,surface_velocity={0,0,0}},
        separation=gap,wheel_center=M.copy(center),wheel_radius=radius,wheel_rim=M.sub(center,M.mul(basis.normal,radius)),
        verified_plane=false,balance_normal_available=true,balance_normal=M.copy(nt),edge_feature=M.copy(f)}
end

-- This pure projection grants no epoch, ownership or actor authority. Ride
-- validates every complete decoded batch binding before calling a helper.
function Contact.wheel_samples(frame,rays,centers,context,geometry,features,witness_rays)
    if not complete(rays,6) or type(centers)~="table" or #centers~=2 then return nil,"wheel batch shape unavailable" end
    features=features or {};witness_rays=witness_rays or {}
    if not complete(witness_rays,#features*3) then return nil,"edge witnesses unavailable" end
    local samples={}
    local forward=M.turn(frame.body.orientation,{0,0,1})
    for i=1,2 do
        local ray=rays[(i-1)*3+1]
        if ray.status=="hit" then
            local basis=M.basis(ray.normal,forward)
            if not basis then return nil,"measured wheel tangent unavailable" end
            local separation=M.dot(M.sub(centers[i],ray.position),basis.normal)-geometry.wheel_radius
            if not M.finite(separation) or separation<-.10 then return nil,"wheel penetration unavailable or excessive" end
            samples[i]={contact={status="hit",point=M.copy(ray.position),normal=basis.normal,
                forward=basis.forward,surface_velocity=M.copy(ray.surface_velocity)},separation=separation,
                wheel_center=M.copy(centers[i]),wheel_radius=geometry.wheel_radius,
                verified_plane=false,balance_normal_available=false}
        else samples[i]={contact={status="clear"}} end
    end
    for i,feature in ipairs(features)do
        local f=M.copy(feature)
        for j,key in ipairs({"top_witness","wall_witness","outside_witness"})do
            local row=witness_rays[(i-1)*3+j]
            if not measured(row) then return nil,"edge local witness unavailable" end
            f[key]=witness(row)
        end
        if f.wheel~=1 and f.wheel~=2 or samples[f.wheel].edge then return nil,"edge wheel index unavailable" end
        local edge,why=Contact.edge_sample(centers[f.wheel],geometry.wheel_radius,f,forward)
        if not edge then return nil,why end
        if edge.contact.status=="hit" then
            local primary=samples[f.wheel]
            local duplicate=edge.kind=="top_face" and primary.contact.status=="hit"
                and M.dot(primary.contact.normal,edge.contact.normal)>.999
                and math.abs(M.dot(M.sub(primary.contact.point,edge.contact.point),edge.contact.normal))<.003
                and math.abs(primary.separation-edge.separation)<.003
            if not duplicate then primary.edge=edge end
        end
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

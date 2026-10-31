-- A bounded mod landing qualification from current measured body/ray facts.
-- No prediction, native collision/catch/score, storage, clock or SDK effects.
local Frame=require("./frame_identity")
local Identity=require("./lease_identity")
local Forces=require("./forces")
local M=require("./force_math")
local G=require("./bike_geometry")
local Landing={}
local UP={0,1,0} -- The current supported ride's fixed world gravity direction.
local HEADING=math.cos(math.rad(35))
local function finite(v)return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function plain(v)return type(v)=="table" and getmetatable(v)==nil end
local function same(a,b)return a==b and (a~=0 or 1/a==1/b)end
local function vector_same(a,b)
    local native=typeof(a)=="vector"
    if not native and not plain(a) then return false end
    for _,axis in ipairs({"x","y","z"})do
        local v=native and a[axis] or rawget(a,axis)
        if not finite(v) or not same(v,b[axis]) then return false end
    end
    return true
end
local function array_same(a,b,n)
    if not plain(a) then return false end
    for i=1,n do if not same(rawget(a,i),b[i]) then return false end end
    return true
end
local function close(a,b)return M.vec(a) and M.vec(b) and M.length(M.sub(a,b))<=1e-8 end
local function dense(v,limit)
    if not plain(v) then return nil end
    local n,high=0,0
    for k in next,v do
        n+=1
        if n>limit or not finite(k) or k%1~=0 or k<1 or k>limit then return nil end
        high=math.max(high,k)
    end
    return n==high and n or nil
end
local function current_application(f,proofs,last_sequence)
    local rows=plain(proofs) and proofs.applied_successors
    local n=dense(rows,3)
    if n==nil then return nil,"application_proofs_unavailable" end
    local sequence
    for i=1,n do
        local entry=rows[i]
        local row=plain(entry) and entry.receipt
        local r=plain(entry) and entry.request
        local successor=plain(row) and row.successor
        if plain(successor) and successor.serial==f.serial then
            if not plain(r) or not Identity.is_nonzero_u64(r.sequence) or row.sequence~=r.sequence
                or row.requested_serial~=r.serial or not Identity.is_nonzero_u64(r.serial)
                or r.seconds~=f.seconds or not finite(r.time) or row.outcome~="applied"
                or row.force_attempted~=true or row.torque_attempted~=true
                or row.retained~=false or row.quarantined~=false or row.cleanup_disposition~="none"
                or Identity.bounded_delta(row.produced_serial,r.serial,1)~=1 then return nil,"application_binding_mismatch" end
            local steps=Identity.bounded_delta(f.serial,r.serial,64)
            if not steps or steps<2 or math.abs(f.time-r.time-steps*f.seconds)>1e-6
                or type(successor.epoch)~="userdata" or successor.time~=f.time or successor.seconds~=f.seconds
                or not same(successor.mass,f.sample.mass) or not array_same(successor.rotation,f.sample.rotation,4) then
                return nil,"application_successor_mismatch"
            end
            for _,name in ipairs({"position","velocity","angular_velocity","inertia"})do
                if not vector_same(successor[name],f.sample[name]) then return nil,"application_successor_changed" end
            end
            if not sequence or Identity.compare(r.sequence,sequence)==1 then sequence=r.sequence end
        end
    end
    if not sequence then return nil,"current_applied_successor_unavailable" end
    if last_sequence and Identity.compare(sequence,last_sequence)~=1 then return nil,"application_witness_replayed" end
    return sequence
end
local function contact_facts(f,c,tripwire,authored_steer)
    local d=plain(c) and c.decoded
    local s=plain(c) and c.support
    local b=plain(d) and d.binding
    local q=plain(d) and d.query
    if not plain(s) or s.known~=true or s.grounded_known~=true or type(s.grounded)~="boolean"
        or not rawequal(s.epoch,f.physics_epoch) or s.provenance~="measured_rays_authored_wheel_geometry"
        or s.native_collision_contact~=false or not plain(b) or not rawequal(b.body_handle,f.body_handle)
        or not rawequal(b.physics_epoch,f.physics_epoch) or not rawequal(b.lease_handle,f.source.lease_handle)
        or d.valid~=true or d.status~="available" or not plain(d.frame) or d.frame.serial~=f.serial
        or d.frame.time~=f.time or d.frame.seconds~=f.seconds or not plain(d.frame.source)
        or not plain(q) or q.epoch_matches~=true or q.measurements_complete~=true
        or q.owned_bodies_excluded~=true or q.budget_exhausted~=false
        or dense(d.rays,2)~=2 or dense(c.samples,2)~=2 then return nil,"measured_contact_binding_unavailable" end
    for _,name in ipairs({"generation","user","sequence","source_epoch","context_generation","observation_serial","observed_ms","packet"})do
        if d.frame.source[name]~=f.source[name] then return nil,"contact_source_changed" end
    end
    if q.actor_lane=="identity" then
        if q.local_actor_excluded~=true or s.actor_lane~="identity"
            or s.actor_tripwire~="not_required_identity_lane" then return nil,"actor_identity_unavailable" end
    elseif q.actor_lane=="named_categories_absent" then
        if q.named_actor_categories_absent~=true or s.actor_lane~="named_categories_absent" then return nil,"actor_category_unavailable" end
        if s.actor_tripwire=="authored_rider_crossings_clear_v1" then tripwire=f.serial
        elseif s.actor_tripwire~="authored_rider_crossings_clear_previous_epoch_v1"
            or not tripwire or Identity.bounded_delta(f.serial,tripwire,1)~=1 then return nil,"actor_tripwire_unavailable" end
    else return nil,"actor_lane_unavailable" end
    -- Use the same accepted authored articulation that positioned THIS query.
    -- It is not a measured native steering joint or a visual trick angle.
    local front=type(G.front_axle_at)=="function" and G.front_axle_at(G,authored_steer)
    if not M.vec(front,10) then return nil,"authored_probe_geometry_unavailable" end
    local supported,normals,velocities,closing=0,{0,0,0},{0,0,0},0
    for i=1,2 do
        local sample,ray=c.samples[i],d.rays[i]
        local hit=plain(sample) and sample.contact
        if not plain(hit) or not plain(ray) or hit.status~=ray.status then return nil,"contact_row_unavailable" end
        if hit.status=="hit" then
            local axle=i==1 and front or G.rear_axle
            local center=M.add(f.body.center_of_mass,M.turn(f.body.orientation,M.sub(axle,G.com)))
            local forward=M.turn(f.body.orientation,{0,0,1})
            local basis=M.vec(ray.normal,1) and M.basis(ray.normal,forward)
            if not basis or math.abs(M.length(ray.normal)-1)>.001 or ray.normal_available~=true or ray.surface_velocity_available~=true or ray.motion~="measured"
                or not M.vec(ray.position,100000) or not M.vec(ray.surface_velocity,50)
                or not close(hit.point,ray.position) or not close(hit.normal,basis.normal)
                or not close(hit.forward,basis.forward) or not close(hit.surface_velocity,ray.surface_velocity)
                or not close(sample.wheel_center,center) or sample.wheel_radius~=G.wheel_radius
                or not finite(sample.separation)
                or math.abs(sample.separation-(M.dot(M.sub(center,ray.position),basis.normal)-G.wheel_radius))>1e-8 then
                return nil,"measured_geometry_mismatch"
            end
            if Forces.eligible_support(f.body,sample,.005,.10) then
                supported+=1;normals=M.add(normals,basis.normal);velocities=M.add(velocities,ray.surface_velocity)
                local relative=M.sub(M.point_velocity(f.body,hit.point),ray.surface_velocity)
                closing=math.max(closing,-M.dot(relative,basis.normal))
            end
        elseif hit.status~="clear" then return nil,"measured_contact_unknown" end
    end
    if c.grounded~=(supported>0) or s.grounded~=(supported>0) then return nil,"grounded_projection_changed" end
    local result={grounded=supported>0,both=supported==2,closing=closing}
    if supported>0 then
        local normal=M.unit(normals)
        local up=M.unit(M.turn(f.body.orientation,{0,1,0}))
        local forward=M.turn(f.body.orientation,{0,0,1})
        local travel=M.sub(f.body.linear_velocity,M.mul(velocities,1/supported))
        local heading=normal and M.unit(M.sub(forward,M.mul(normal,M.dot(forward,normal))))
        local direction=normal and M.unit(M.sub(travel,M.mul(normal,M.dot(travel,normal))))
        if not normal or not up or not heading or not direction then return nil,"measured_travel_heading_unavailable" end
        result.body_up=math.clamp(M.dot(up,normal),-1,1)
        result.support_up=math.clamp(M.dot(normal,UP),-1,1)
        result.heading=math.clamp(M.dot(heading,direction),-1,1)
    end
    return result,nil,tripwire
end
function Landing.new()
    local previous,phase,last_sequence,tripwire=nil,"grounded",nil,nil
    local ground_seen,failed_air,stopped=false,false,false
    local air_samples,first_contact,stable_start,stable_samples,peak_closing=0,nil,nil,0,0
    local object={}
    local function output(f,landed,quality,issue)
        local visible=quality and (quality.qualified==true and "landed" or "unavailable") or phase
        return table.freeze({phase=visible,landed=landed,quality=quality,issue=issue or "none",
            serial=f and f.serial or nil,accepting_catches=phase=="airborne" and issue==nil and not failed_air and not stopped,
            native_landing=false,scope="measured_mod_landing_producer_v1"})
    end
    local function unavailable(f,why,terminal)
        failed_air=true;stable_start=nil;stable_samples=0
        phase=terminal and "stopped" or "unavailable";stopped=stopped or terminal==true
        return output(f,true,table.freeze({available=false,qualified=false,native_landing=false,reason=why}),why)
    end
    function object:step(raw,contact,proofs)
        if stopped then return output(nil,false,nil,"stopped") end
        local f,why=Frame.copy(raw)
        if not f or not f.fresh or not f.gates.focused or f.gates.menu_open then return unavailable(f,why or "owner_gate_unavailable",true) end
        if previous then
            local kind=Frame.classify(previous,f).kind
            if kind=="duplicate" then return output(f,false,nil,"duplicate_body") end
            if kind~="successor" then return unavailable(f,"measured_body_continuity_lost",true) end
        end
        previous=f
        local facts,contact_why,next_tripwire=contact_facts(f,contact,tripwire,plain(proofs) and proofs.authored_steer)
        if not facts then return unavailable(f,contact_why,false) end
        tripwire=next_tripwire
        local sequence,application_why=current_application(f,proofs,last_sequence)
        if sequence then last_sequence=sequence end
        if failed_air then
            if facts.grounded then
                failed_air=false;ground_seen=true;phase="grounded"
                air_samples=0;first_contact=nil;stable_start=nil;stable_samples=0;peak_closing=0
            end
            return output(f,true,table.freeze({available=false,qualified=false,native_landing=false,reason="air_observations_incomplete"}),"air_observations_incomplete")
        end
        if not sequence then
            if phase=="airborne" or phase=="settling" or not facts.grounded then return unavailable(f,application_why,false) end
            ground_seen=true;phase="grounded"
            return output(f,false,nil,application_why)
        end
        if first_contact and (f.time-first_contact>.5 or stable_samples>=31) then return unavailable(f,"landing_settle_window_expired",false) end
        if not facts.grounded then
            if not ground_seen then return unavailable(f,"measured_ground_prime_required",false) end
            air_samples=math.min(2,air_samples+1);stable_start=nil;stable_samples=0
            if phase~="settling" then phase="airborne" end
            return output(f,false,nil)
        end
        if phase~="airborne" and phase~="settling" then ground_seen=true;phase="grounded";return output(f,false,nil) end
        if air_samples<2 then return unavailable(f,"measured_air_interval_too_short",false) end
        phase="settling";first_contact=first_contact or f.time
        if facts.body_up<.5 or facts.support_up<.15 or math.abs(facts.heading)<HEADING or facts.closing>7 then
            return unavailable(f,"measured_landing_outside_mod_thresholds",false)
        end
        peak_closing=math.max(peak_closing,facts.closing)
        if not facts.both then stable_start=nil;stable_samples=0;return output(f,false,nil) end
        stable_start=stable_start or f.time;stable_samples+=1
        local elapsed=f.time-stable_start
        if stable_samples<4 or elapsed<.06 then return output(f,false,nil) end
        if elapsed>.5 or stable_samples>31 then return unavailable(f,"landing_settle_window_expired",false) end
        local quality=table.freeze({available=true,qualified=true,scope="measured_mod_landing_v1",
            serial=f.serial,physics_epoch=f.physics_epoch,source_observation_serial=f.source.observation_serial,
            grounded=true,support_known=true,observations_complete=true,owned_bodies_excluded=true,native_landing=false,
            body_up_alignment=facts.body_up,support_up_alignment=facts.support_up,heading_cos=facts.heading,
            closing_normal_speed=peak_closing,settled_seconds=elapsed,settled_samples=stable_samples,
            actor_scope="existing_identity_or_named_categories_with_bounded_rider_tripwire",
            geometry_scope="current_accepted_mod_steer_and_measured_body",
            calibration="C0_UNRUN"})
        phase="grounded";ground_seen=true;air_samples=0;first_contact=nil;stable_start=nil;stable_samples=0;peak_closing=0
        return output(f,true,quality)
    end
    function object:cancel(reason)
        if stopped then return false,"stopped" end
        unavailable(previous,type(reason)=="string" and reason or "cancelled",true)
        return true,"cancelled"
    end
    return table.freeze(object)
end
return table.freeze(Landing)
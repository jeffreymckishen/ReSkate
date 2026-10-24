-- Inactive subordinate: Core alone owns Source, body, Follow and lifecycle.
-- Construction and observation make no native calls while this literal is false.
local ACTIVATION_QUALIFIED = false
local Mapping = require("./ride_input_mapping")
local Forces = require("./forces")
local M = require("./force_math")
local Identity = require("./lease_identity")
local Geometry = require("./bike_geometry")
local Ride, Object = {}, {}
local states = setmetatable({}, {__mode="k"})
local MAX_SAFE = 9007199254740991

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end
local function freeze(value)
    if type(value) ~= "table" then return value end
    for _, child in pairs(value) do freeze(child) end
    if not table.isfrozen(value) then table.freeze(value) end
    return value
end
local function detached(value) return freeze(copy(value)) end
local function detail(value) return string.sub(tostring(value or "unavailable"), 1, 180) end
local function array(value)
    if typeof(value) ~= "vector" then return nil end
    local result = {value.x, value.y, value.z}
    return M.vec(result) and result or nil
end
local function native(value) return vector.create(value[1], value[2], value[3]) end
local function clock(s, now)
    if not M.finite(now) or now < 0 or now > MAX_SAFE or s.now and now < s.now then return false end
    s.now = now
    return true
end
local function invoke(s, fn, ...)
    if type(fn) ~= "function" then return {false, "callback unavailable", n=2} end
    local generation = s.generation
    local result = table.pack(pcall(fn, ...))
    result.current = generation == s.generation
    return result
end
local function exact_true(result) return result[1] and result[2] == true and result.current end
local pad_keys={left_x=true,left_y=true,right_x=true,right_y=true,left_trigger=true,right_trigger=true,playstation=true,buttons=true}
local button_keys={up=true,down=true,left=true,right=true,start=true,back=true,left_stick=true,right_stick=true,
    lb=true,rb=true,a=true,b=true,x=true,y=true}
local function pad_copy(pad)
    if type(pad)~="table" or getmetatable(pad)~=nil or type(pad.buttons)~="table" or getmetatable(pad.buttons)~=nil then return nil end
    for name in pairs(pad) do if not pad_keys[name] then return nil end end
    local out={buttons={}}
    for _,name in ipairs({"left_x","left_y","right_x","right_y"}) do
        if not M.finite(pad[name]) or math.abs(pad[name])>1 then return nil end
        out[name]=pad[name]
    end
    for _,name in ipairs({"left_trigger","right_trigger"}) do
        if not M.finite(pad[name]) or pad[name]<0 or pad[name]>1 then return nil end
        out[name]=pad[name]
    end
    if pad.playstation~=nil and type(pad.playstation)~="boolean" then return nil end
    out.playstation=pad.playstation
    for name,value in pairs(pad.buttons) do
        if not button_keys[name] or type(value)~="boolean" then return nil end
        out.buttons[name]=value
    end
    for _,name in ipairs({"a","b","right_stick","lb","rb"}) do if type(out.buttons[name])~="boolean" then return nil end end
    return out
end
local function source_key(frame)
    if type(frame) ~= "table" or getmetatable(frame)~=nil or frame.input_ok ~= true or type(frame.lease_handle) ~= "userdata"
        or type(frame.generation) ~= "number" or frame.generation < 0 or frame.generation > MAX_SAFE
        or frame.generation % 1 ~= 0 or type(frame.sample) ~= "table" or getmetatable(frame.sample)~=nil then return nil end
    local sample = frame.sample
    if type(sample.user) ~= "number" or sample.user < 0 or sample.user > 3 or sample.user % 1 ~= 0 then return nil end
    for _, name in ipairs({"sequence","source_epoch","context_generation","observation_serial","observed_ms"}) do
        if not Identity.is_nonzero_u64(sample[name]) then return nil end
    end
    if not M.finite(sample.packet) or sample.packet<0 or sample.packet>4294967295 or sample.packet%1~=0 then return nil end
    local pad=pad_copy(sample.pad)
    if not pad then return nil end
    return {lease_handle=frame.lease_handle,generation=frame.generation,user=sample.user,
        sequence=sample.sequence,source_epoch=sample.source_epoch,context_generation=sample.context_generation,
        observation_serial=sample.observation_serial,observed_ms=sample.observed_ms,packet=sample.packet,pad=pad}
end
local function same_source(a, b)
    if not a or not b then return false end
    for _, name in ipairs({"lease_handle","generation","user","sequence","source_epoch","context_generation"}) do
        if a[name] ~= b[name] then return false end
    end
    return true
end
local function same_input(a,b)
    if not same_source(a,b) then return false end
    for _,name in ipairs({"observation_serial","observed_ms","packet"}) do if a[name]~=b[name] then return false end end
    local function equal(x,y)
        if type(x)~=type(y) then return false end
        if type(x)~="table" then return x==y end
        for key,value in pairs(x) do if not equal(value,y[key]) then return false end end
        for key in pairs(y) do if x[key]==nil then return false end end
        return true
    end
    return equal(a.pad,b.pad)
end
local function same_observation(a,b)
    if not same_source(a,b) then return false end
    for _,name in ipairs({"observation_serial","observed_ms","packet"}) do if a[name]~=b[name] then return false end end
    return true
end
local function stage_input(s,frame,key)
    local previous=s.staged_last
    if previous then
        local order=Identity.compare(key.observation_serial,previous.observation_serial)
        if order<0 then return false,"selected input observation regressed" end
        if order==0 then return same_input(key,previous),"selected duplicate input changed" end
        if Identity.compare(key.observed_ms,previous.observed_ms)<0 then return false,"selected input clock regressed" end
    end
    if #s.input_queue>=32 then return false,"selected input staging capacity exceeded" end
    local first=s.input_queue[1]
    if first and not Identity.bounded_delta(key.observed_ms,first.sample.observed_ms,100) then
        return false,"selected input staging window exceeded"
    end
    local selected=copy(key)
    selected.lease_handle,selected.generation=nil,nil
    s.input_queue[#s.input_queue+1]=detached({input_ok=true,lease_handle=key.lease_handle,generation=key.generation,sample=selected})
    s.staged_last=detached(key)
    s.input_staged+=1
    return true
end
local function sample_copy(raw)
    if type(raw) ~= "table" or getmetatable(raw)~=nil or type(raw.epoch) ~= "userdata" or not Identity.is_nonzero_u64(raw.serial)
        or not M.finite(raw.time) or raw.time < 0 or not M.finite(raw.seconds)
        or math.abs(raw.seconds - Forces.native_seconds) > 1e-8 then return nil end
    local body = {mass=raw.mass,center_of_mass=array(raw.position),orientation=copy(raw.rotation),
        linear_velocity=array(raw.velocity),angular_velocity=array(raw.angular_velocity),inertia_body=array(raw.inertia)}
    if not M.valid_body(body) or not M.vec(body.center_of_mass,100000) or not M.vec(body.linear_velocity,50)
        or not M.vec(body.angular_velocity,40) then return nil end
    local sample = {epoch=raw.epoch,serial=raw.serial,time=raw.time,seconds=raw.seconds,position=raw.position,
        rotation=copy(raw.rotation),velocity=raw.velocity,angular_velocity=raw.angular_velocity,inertia=raw.inertia,mass=raw.mass}
    return detached(sample), detached(body)
end
local function receipt_sample_copy(raw)
    -- Cleanup checks native record shape/correlation, not drive policy limits.
    -- SDK observe_checked bounds pose rings to 1e6 and velocity/spin to 100;
    -- its quaternion squared norm admits [.9,1.1]. A tighter ride refusal must
    -- not withhold an otherwise exact native terminal acknowledgement.
    if type(raw)~="table" or getmetatable(raw)~=nil or type(raw.epoch)~="userdata"
        or not Identity.is_nonzero_u64(raw.serial) or not M.finite(raw.time) or raw.time<0
        or not M.finite(raw.seconds) or math.abs(raw.seconds-Forces.native_seconds)>1e-8
        or not M.finite(raw.mass) or raw.mass<=0 or type(raw.rotation)~="table" then return nil end
    local bounds={position=1000000,velocity=100,angular_velocity=100}
    for name,bound in pairs(bounds) do
        local v=raw[name]
        if typeof(v)~="vector" or not M.finite(v.x) or not M.finite(v.y) or not M.finite(v.z)
            or math.abs(v.x)>bound or math.abs(v.y)>bound or math.abs(v.z)>bound then return nil end
    end
    local inertia=raw.inertia
    if typeof(inertia)~="vector" or not M.finite(inertia.x) or not M.finite(inertia.y) or not M.finite(inertia.z)
        or inertia.x<=0 or inertia.y<=0 or inertia.z<=0 then return nil end
    local norm=0
    for i=1,4 do if not M.finite(raw.rotation[i]) then return nil end;norm+=raw.rotation[i]^2 end
    if not M.finite(norm) or norm<.9 or norm>1.1 then return nil end
    return detached({epoch=raw.epoch,serial=raw.serial,time=raw.time,seconds=raw.seconds,mass=raw.mass,
        position=raw.position,rotation=copy(raw.rotation),velocity=raw.velocity,angular_velocity=raw.angular_velocity,inertia=raw.inertia})
end
local function equal_sample(a,b)
    if a.serial ~= b.serial or a.time ~= b.time or a.seconds ~= b.seconds or a.position ~= b.position
        or a.velocity ~= b.velocity or a.angular_velocity ~= b.angular_velocity or a.inertia ~= b.inertia
        or a.mass ~= b.mass then return false end
    for i=1,4 do if a.rotation[i] ~= b.rotation[i] then return false end end
    return true
end
local function stop(s, reason)
    -- Pure latch. Core inspects stop_requested after this subordinate returns.
    -- There are no Source, body, Follow or owner callbacks in this module.
    if not s.stopped then s.stopped=true;s.generation+=1;s.issue=detail(reason) end
    s.phase="stopped"
    s.input_queue={}
end
local function retire(s,pending,disposition)
    if not pending.hop_id or pending.hop_retired then return true end
    local result=invoke(s,s.mapping.retire_hop,s.mapping,pending.hop_id,disposition)
    pending.hop_retired=result[1] and result[2]==true
    s.hop_disposition={id=pending.hop_id,disposition=disposition,confirmed=pending.hop_retired}
    if not pending.hop_retired then s.unknown=true;stop(s,"hop retirement unavailable") end
    return pending.hop_retired
end
local function status(s)
    local p=s.pending
    -- Opaque body/lease/incarnation/epoch stay private; this is diagnostic only.
    return detached({phase=s.phase,issue=s.issue,activation_qualified=ACTIVATION_QUALIFIED,
        stop_requested=s.stopped==true,force_pending=p~=nil,unknown=s.unknown==true or p and p.unknown==true or false,
        pending_sequence=p and p.sequence,ack_attempted=p and p.ack_attempted==true or false,
        submitted=s.submitted,acknowledged=s.acknowledged,last_serial=s.last_sample and s.last_sample.serial,
        input_staged=s.input_staged,input_consumed=s.input_consumed,input_queued=#s.input_queue,
        observed_steps=s.observed_steps,model_steps=s.model_steps,receipt=s.last_receipt,
        model_history=s.model_history,hop_disposition=s.hop_disposition,
        model={trick_status=s.trick_status,alignment_status=s.alignment_status,recovery_status=s.recovery_status}})
end
local function receipt_valid(row,p)
    if type(row)~="table" or row.sequence~=p.sequence or row.requested_serial~=p.serial
        or not Identity.is_u64(row.produced_serial) or type(row.force_attempted)~="boolean"
        or type(row.torque_attempted)~="boolean" or type(row.retained)~="boolean"
        or type(row.quarantined)~="boolean" then return false end
    if row.outcome=="queued" then return row.produced_serial=="0" and not row.force_attempted and not row.torque_attempted end
    if row.outcome=="applied" then
        return row.force_attempted and row.torque_attempted
            and Identity.bounded_delta(row.produced_serial,p.serial,1)==1
    end
    if row.outcome=="partial" then
        return Identity.is_nonzero_u64(row.produced_serial) and Identity.bounded_delta(row.produced_serial,p.serial,1)==1
            and (row.force_attempted or row.torque_attempted)
    end
    return (row.outcome=="rejected" or row.outcome=="expired") and not row.force_attempted and not row.torque_attempted
end
local function poll_pending(s)
    local p=s.pending
    if not p or p.unknown then return end
    if not p.sequence then p.unknown=true;s.unknown=true;stop(s,"force admission has no exact sequence");return end
    if s.now and s.now-p.submitted_at>=1000 then
        p.watchdog_expired=true;stop(s,"force receipt watchdog expired")
    end
    local read=invoke(s,s.api.receipt,p.sequence)
    local row=read[1] and read.n==2 and read[2] or nil
    if not receipt_valid(row,p) then
        p.unknown=true;s.unknown=true;stop(s,"force receipt unavailable or identity mismatch");return
    end
    -- Keep only bounded scalar receipt diagnostics. Never publish its successor.
    s.last_receipt={outcome=row.outcome,sequence=row.sequence,requested_serial=row.requested_serial,
        produced_serial=row.produced_serial,force_attempted=row.force_attempted,torque_attempted=row.torque_attempted,
        retained=row.retained,quarantined=row.quarantined,successor_available=row.successor~=nil}
    if row.outcome=="queued" then return end
    if row.outcome=="applied" then
        if row.successor==nil then return end -- Park/Follow terminal cannot replace this native evidence.
        local successor=receipt_sample_copy(row.successor)
        local steps=successor and Identity.bounded_delta(successor.serial,p.serial,MAX_SAFE)
        if not successor or not steps or steps<2 or Identity.compare(successor.serial,row.produced_serial)<=0
            or successor.seconds~=p.seconds or successor.time<=p.time+p.seconds
            or math.abs(successor.time-p.time-steps*p.seconds)>1e-6 then
            p.unknown=true;s.unknown=true;stop(s,"applied successor incoherent");return
        end
        if not sample_copy(row.successor) then stop(s,"native successor outside drive policy") end
    else
        stop(s,"force command "..row.outcome)
    end
    if p.ack_attempted then p.unknown=true;s.unknown=true;return end
    p.ack_attempted=true -- At most one attempt; an exception may follow native ACK.
    local ack=invoke(s,s.api.acknowledge,p.sequence)
    if not ack[1] or ack.n~=2 or ack[2]~=true then
        p.unknown=true;s.unknown=true;stop(s,"force acknowledgement outcome unknown");return
    end
    s.acknowledged+=1
    if row.outcome=="partial" then
        retire(s,p,"uncertain");p.unknown=true;s.unknown=true;return
    end
    if not retire(s,p,row.outcome=="applied" and "accepted" or "cancelled") then p.unknown=true;return end
    s.pending=nil
    -- A one-step preview is older than the SDK's N+2 successor. Reset ONLY
    -- force policy histories. Mapping/Trick already observed intervening epochs.
    local reset=invoke(s,s.force.reset,s.force)
    if not reset[1] or reset.n~=1 then s.unknown=true;stop(s,"force history reset unavailable");return end
    s.wheels=Forces.proposed_wheels()
    s.model_history={kind="force_reset",serial=p.serial,reason="terminal_force_receipt",native_wheel_state_known=false}
end
local function companion_result(s,frame,contact,actions)
    local out = {rotation_reserved=false,requests={},events={}}
    if s.tricks then
        local result = invoke(s,s.tricks.step,s.tricks,frame,contact,actions)
        if not result[1] or result.n ~= 2 or not result.current or type(result[2]) ~= "table" then return nil,"trick adapter unavailable" end
        local value = result[2]
        if value.valid then
            local bound=value.binding
            if type(bound)~="table" or bound.body_handle~=frame.body_handle or bound.physics_epoch~=frame.physics_epoch
                or bound.lease_handle~=frame.source.lease_handle or bound.serial~=frame.serial or bound.time~=frame.time
                or bound.seconds~=frame.seconds or not same_observation(bound.source,frame.source)
                or value.fresh~=true or value.advanced~=true or type(value.requests)~="table"
                or type(value.requests.rotation_reserved)~="boolean" then return nil,"trick frame mismatch" end
            for name in pairs(value.requests) do
                if name~="rotation_reserved" and name~="scope" then return nil,"unknown trick effect request" end
            end
            out.rotation_reserved=value.requests.rotation_reserved
            out.events=copy(value.model_events)
            -- Keep the producer's private binding on the full result. Never
            -- stamp an unbound bare authored target as a measured native pose.
            out.visual_targets=value.visual_targets and copy(value) or nil
            out.trick=copy(value)
        else return nil,"trick adapter refused: " .. detail(value.issue) end
    end
    if s.recovery then
        local result = invoke(s,s.recovery.update,s.recovery,frame)
        if not result[1] or result.n ~= 2 or not result.current or type(result[2]) ~= "table" then return nil,"recovery adapter unavailable" end
        out.recovery = copy(result[2])
        if type(result[2].requests)=="table" and result[2].requests.stop then
            return nil,"recovery stop: " .. detail(result[2].requests.stop.reason)
        end
        if result[2].suppress_forces==true then return nil,"recovery retains force suppression" end
    end
    if s.alignment then
        local result = invoke(s,s.alignment.solve,frame,s.geometry,out.visual_targets,s.alignment_options)
        -- Alignment currently returns requested targets only. It has no native
        -- rig/apply receipt; failure here cannot establish or mutate an actor.
        out.alignment = result[1] and result.n==2 and result.current and copy(result[2])
            or {status="unavailable",native_alignment=false}
    end
    return out
end
local function wheel_plan(frame,geometry,gravity)
    if type(geometry)~="table" or not M.vec(geometry.com,10) or not M.vec(geometry.front_axle,10)
        or not M.vec(geometry.rear_axle,10) or not M.finite(geometry.wheel_radius)
        or geometry.wheel_radius<.01 or geometry.wheel_radius>2 then return nil end
    local down=M.unit(gravity)
    if not down then return nil end
    local rays,centers={},{}
    for i,axle in ipairs({geometry.front_axle,geometry.rear_axle}) do
        local center=M.add(frame.body.center_of_mass,M.turn(frame.body.orientation,M.sub(axle,geometry.com)))
        local target=M.add(center,M.mul(down,geometry.wheel_radius+.15))
        if not M.vec(center,100000) or not M.vec(target,100000) then return nil end
        centers[i]=center
        rays[i]={from=native(center),to=native(target)}
    end
    return freeze(rays),centers
end
local function wheel_contacts(frame,decoded,centers,geometry)
    if type(decoded)~="table" or decoded.valid~=true or type(decoded.binding)~="table"
        or decoded.binding.body_handle~=frame.body_handle or decoded.binding.physics_epoch~=frame.physics_epoch
        or decoded.binding.lease_handle~=frame.source.lease_handle or type(decoded.frame)~="table"
        or decoded.frame.serial~=frame.serial or decoded.frame.time~=frame.time or decoded.frame.seconds~=frame.seconds
        or type(decoded.frame.source)~="table"
        or type(decoded.rays)~="table" or #decoded.rays~=2 or type(decoded.query)~="table"
        or decoded.query.epoch_matches~=true or decoded.query.local_actor_excluded~=true
        or decoded.query.owned_bodies_excluded~=true or decoded.query.budget_exhausted~=false then
        return nil,"contact decode binding or native exclusions unavailable"
    end
    for _,name in ipairs({"generation","user","sequence","source_epoch","context_generation","observation_serial","observed_ms","packet"}) do
        if decoded.frame.source[name]~=frame.source[name] then return nil,"contact selected source identity mismatch" end
    end
    local samples,grounded={},false
    local forward=M.turn(frame.body.orientation,{0,0,1})
    for i,ray in ipairs(decoded.rays) do
        if ray.status=="clear" then
            -- The paired clear-aware Forces/Solver accepts this absence.
            samples[i]={contact={status="clear"}}
        elseif ray.status=="hit" and ray.normal_available==true and ray.surface_velocity_available==true
            and ray.motion=="measured" and M.vec(ray.position,100000) and M.vec(ray.normal,1)
            and M.vec(ray.surface_velocity,50) then
            if math.abs(M.length(ray.normal)-1)>.001 then return nil,"measured normal is not unit" end
            local basis=M.basis(ray.normal,forward)
            if not basis then return nil,"measured wheel tangent unavailable" end
            local separation=M.dot(M.sub(centers[i],ray.position),basis.normal)-geometry.wheel_radius
            if not M.finite(separation) or separation<-.10 then return nil,"wheel penetration unavailable or excessive" end
            samples[i]={contact={status="hit",point=copy(ray.position),normal=basis.normal,
                forward=basis.forward,surface_velocity=copy(ray.surface_velocity)},separation=separation,
                verified_plane=false,balance_normal_available=false}
            grounded=grounded or Forces.eligible_support(frame.body,samples[i],.005,.10)
        else return nil,"measured wheel surface unavailable" end
    end
    return {samples=samples,grounded=grounded,decoded=copy(decoded),
        support={known=true,grounded_known=true,grounded=grounded,epoch=frame.physics_epoch,
            provenance="measured_rays_authored_wheel_geometry",native_collision_contact=false,
            landing_quality_available=false,reason="landing_quality_not_qualified"}}
end
local function packet(model,companions,h)
    if type(model) ~= "table" or model.valid ~= true or not M.vec(model.force) or not M.vec(model.torque)
        or not M.vec(model.hop_impulse) then return nil end
    local torque = copy(model.torque)
    local request_count=0
    for key in pairs(companions.requests or {}) do
        if type(key)~="number" or key%1~=0 or key<1 or key>#companions.requests then return nil end
        request_count+=1
    end
    if request_count~=#(companions.requests or {}) then return nil end
    for _, request in ipairs(companions.requests or {}) do
        if type(request) ~= "table" or request.kind ~= "torque" or not M.vec(request.torque,4000) then return nil end
        torque = M.add(torque,request.torque)
    end
    local force,impulse = model.force,model.hop_impulse
    if M.length(force)>40000 or M.length(torque)>4000 or M.length(impulse)>600
        or M.length(M.add(force,M.mul(impulse,1/h)))>40000 then return nil end
    local command = {force=native(force),torque=native(torque)}
    if model.hop_applied then
        if type(model.hop_event_id) ~= "number" or model.hop_event_id < 1
            or model.hop_event_id > 4294967295 or model.hop_event_id % 1 ~= 0 then return nil end
        command.impulse,command.impulse_id = native(impulse),model.hop_event_id
    elseif M.length(impulse) ~= 0 then return nil end
    return freeze(command)
end
local function observe(s,source_frame,raw,context)
    if not ACTIVATION_QUALIFIED or s.stopped then return end
    if type(context)~="table" or not clock(s,context.now_ms) then stop(s,"caller watchdog clock invalid");return end
    if context.focused~=true or context.menu_open~=false or context.loaded~=true then
        stop(s,"current readiness unavailable");return
    end
    local key=source_key(source_frame)
    if not key then stop(s,"exact selected source unavailable");return end
    if s.bound_source and not same_source(key,s.bound_source) then stop(s,"selected source identity changed");return end
    local staged,why=stage_input(s,source_frame,key)
    if not staged then stop(s,why);return end
    s.bound_source=detached(key)
    -- Stage even on duplicate bodies and while a command receipt is pending.
    local sample,body=sample_copy(raw)
    if not sample then stop(s,"native body sample invalid");return end
    if s.last_sample then
        local order=Identity.compare(sample.serial,s.last_sample.serial)
        if order==0 then
            if not equal_sample(sample,s.last_sample) then stop(s,"changed duplicate native sample") end
            poll_pending(s)
            return
        end
        if order<0 or sample.time<=s.last_sample.time or sample.seconds~=s.last_sample.seconds then
            stop(s,"native sample regressed");return
        end
        local steps=Identity.bounded_delta(sample.serial,s.last_sample.serial,64)
        if steps~=1 or math.abs(sample.time-s.last_sample.time-sample.seconds)>1e-6 then
            -- No manufactured update(0), missed step, heading or landing.
            stop(s,"unobserved native body step gap");return
        end
    end
    s.last_sample=sample -- Consume before callbacks. This native serial cannot submit twice.
    s.observed_steps+=1
    -- One exact queued observation per body step preserves non-hop selection /
    -- release ordering without stepping Trick twice at one native epoch. Bind
    -- the frame to that real observation, never restamp it as the latest poll.
    local input_frame=s.input_queue[1]
    local model_source=input_frame and source_key(input_frame) or s.model_source
    if not model_source then stop(s,"no staged model input observation");return end
    local frame=detached({valid=true,fresh=true,body_handle=s.body,physics_epoch=sample.epoch,
        serial=sample.serial,time=sample.time,seconds=sample.seconds,body=body,sample=sample,source=model_source,
        owner={body_handle=s.body,lease_handle=model_source.lease_handle},gates={focused=true,menu_open=false},
        now_ms=s.now,active=true,loaded=true,telemetry=copy(context.telemetry),observed=copy(context.observed)})
    local plan,centers=wheel_plan(frame,s.geometry,s.force.tuning.gravity)
    if not plan then stop(s,"authored wheel geometry unavailable");return end
    local probed=invoke(s,s.api.probe_batch,sample.epoch,plan,{require_contact=true,exclude_local_actor=true})
    if not probed[1] or probed.n~=2 or not probed.current or s.stopped then stop(s,"native contact batch unavailable");return end
    local contacted=invoke(s,s.contact.decode,frame,plan,probed[2])
    if not contacted[1] or contacted.n~=2 or not contacted.current or s.stopped then stop(s,"contact decode unavailable");return end
    local contact,issue=wheel_contacts(frame,contacted[2],centers,s.geometry)
    if not contact then stop(s,issue);return end
    local enriched=copy(frame)
    enriched.contact,enriched.support=copy(contact),copy(contact.support)
    frame=freeze(enriched)
    if input_frame then
        table.remove(s.input_queue,1)
        s.input_consumed+=1
        local mapped=invoke(s,s.mapping.observe,s.mapping,input_frame,{grounded=contact.grounded,
            focused=true,menu_open=false,rotation_reserved=false})
        if not mapped[1] or mapped.n~=2 or not mapped.current or s.stopped or type(mapped[2])~="table" then
            stop(s,"input mapping unavailable");return
        end
        s.model_source=detached(model_source)
    end
    local controlled=invoke(s,s.mapping.controls,s.mapping,{physics_epoch=sample.epoch,h=sample.seconds,
        grounded=contact.grounded,rotation_reserved=false})
    local controls=controlled[1] and controlled.n==2 and controlled[2] or nil
    if not controlled.current or s.stopped then return end
    if type(controls)~="table" or controls.valid~=true or controls.submission_allowed~=true then
        -- Once a model has advanced, silently omitting an observed physics
        -- epoch would make its later chronology false. Initial neutral prime
        -- may wait; a later unavailable action frame terminates this instance.
        if s.model_steps>0 then stop(s,"non-initial model cadence unavailable") end
        poll_pending(s);return
    end
    if controls.physics_epoch~=sample.epoch or controls.h~=sample.seconds or not same_observation(controls.source,model_source) then
        stop(s,"mapped native frame mismatch");return
    end
    if controls.hop and not Identity.bounded_delta(key.observed_ms,controls.hop.observed_ms,100) then
        stop(s,"hop request expired before body progress");return
    end
    if s.tricks and type(controls.actions)~="table" then stop(s,"bound trick action snapshot unavailable");return end
    local companions,companion_issue=companion_result(s,frame,contacted[2],controls.actions)
    if not companions then stop(s,companion_issue);return end
    if s.stopped then return end
    s.model_steps+=1
    s.trick_status=companions.trick and companions.trick.issue or nil
    s.alignment_status=companions.alignment and companions.alignment.status or nil
    s.recovery_status=companions.recovery and companions.recovery.phase or nil
    -- Every coherent observed model step happens before the command gate.
    poll_pending(s)
    if s.pending or s.stopped or s.unknown then return end
    local force_controls=copy(controls.force_controls)
    force_controls.rotation_reserved=force_controls.rotation_reserved or companions.rotation_reserved==true
    local preview=invoke(s,s.force.preview,s.force,sample.seconds,body,s.wheels,contact.samples,force_controls)
    local model,candidate=preview[2],preview[3]
    if not preview[1] or preview.n~=3 or not preview.current or s.stopped or type(candidate)~="table" then
        stop(s,"force preview unavailable");return
    end
    local command=packet(model,companions,sample.seconds)
    if not command then stop(s,"bounded force packet unavailable");return end
    local p={serial=sample.serial,time=sample.time,seconds=sample.seconds,submitted_at=s.now,
        hop_id=model.hop_applied and model.hop_event_id or nil}
    -- Core's closures enforce exact live ownership before AND after effects.
    -- This local reservation survives stop during submit and unknown admission.
    s.pending=p
    local submitted=invoke(s,s.api.submit,sample.epoch,command)
    if submitted[1] and submitted.n==4 and submitted[2]==true and submitted[3]==nil
        and Identity.is_nonzero_u64(submitted[4]) then
        p.sequence=submitted[4];s.submitted+=1
        if not submitted.current or s.stopped then stop(s,"stopped during force admission") end
    elseif submitted[1] and submitted.n==3 and submitted[2]==false and type(submitted[3])=="string" then
        s.pending=nil;retire(s,p,"cancelled");stop(s,"force admission refused")
    else
        p.unknown=true;s.unknown=true;retire(s,p,"uncertain");stop(s,"force admission outcome unknown")
    end
end

function Ride.new(force_api,models,options)
    models,options=models or {},options or {}
    local meta={__index=Object}
    local object=setmetatable({},meta)
    local s={api=force_api,body=options.body_handle,incarnation=options.incarnation,
        mapping=models.mapping or Mapping.new(options.input),force=models.force or Forces.new(options.force),
        contact=models.contact,tricks=models.tricks,recovery=models.recovery,alignment=models.alignment,
        alignment_options=detached(options.alignment),geometry=detached(options.geometry or Geometry),
        wheels=Forces.proposed_wheels(),phase="inert",issue="native qualification required",generation=0,
        submitted=0,acknowledged=0,input_queue={},input_staged=0,input_consumed=0,observed_steps=0,model_steps=0}
    if ACTIVATION_QUALIFIED then
        local valid=type(s.body)=="userdata" and s.incarnation~=nil and type(force_api)=="table"
            and type(s.contact)=="table" and type(s.contact.decode)=="function"
        if valid then
            for _,name in ipairs({"probe_batch","submit","receipt","acknowledge"}) do
                if type(force_api[name])~="function" then valid=false end
            end
        end
        if valid then s.phase,s.issue="observing","waiting for exact Core samples"
        else stop(s,"restricted force capability or private binding unavailable") end
    end
    states[object]=s
    table.freeze(object);meta.__metatable="locked";table.freeze(meta)
    return object
end
function Object:observe(source_frame,body_sample,context)
    local s=states[self]
    if not ACTIVATION_QUALIFIED or s.stopped then return status(s) end
    if s.busy then stop(s,"reentrant observe");return status(s) end
    s.busy=true
    local ok,why=pcall(observe,s,source_frame,body_sample,context)
    if not ok then stop(s,"observe exception: "..detail(why)) end
    s.busy=false
    return status(s)
end
function Object:drain()
    local s=states[self]
    if not ACTIVATION_QUALIFIED or not s.pending then return status(s) end
    if s.busy then stop(s,"reentrant drain");return status(s) end
    s.busy=true
    local ok,why=pcall(poll_pending,s)
    if not ok then
        s.unknown=true;if s.pending then s.pending.unknown=true end
        stop(s,"drain exception: "..detail(why))
    end
    s.busy=false
    return status(s)
end
function Object:stop(reason) local s=states[self];stop(s,reason or "Core stop");return status(s) end
function Object:status() return status(states[self]) end
return table.freeze(Ride)

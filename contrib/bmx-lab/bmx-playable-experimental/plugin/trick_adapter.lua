-- Pure authored bar channel. The turn/catch/blend equations and timings are
-- the existing tricks.lua _channel policy (.45/.12/.06 seconds), with no
-- landing, tally, movement, score or native effect machinery. A ray-qualified
-- airborne interval is not a native collision or a qualified landing.
local Model = {}
local TAU, BAR_SECONDS, CATCH_WINDOW, CATCH_BLEND = 2 * math.pi, .45, .12, .06
local function smooth(t) return t * t * (3 - 2 * t) end
function Model.new(primed)
    return {primed=primed==true,airborne=false,air_seconds=0,armed=false,rotating=false,
        waiting=false,caught=false,failed=false,direction=0,elapsed=0,catch_elapsed=0,
        blend_remaining=0,origin=0,angle=0,release=0}
end
function Model.advance(previous,seconds,grounded,request,neutral)
    -- Only the adapter supplies these already checked bounded scalar inputs.
    local c=table.clone(previous)
    if grounded then
        return Model.new(c.primed or neutral and request=="none")
    end
    if not c.primed then return nil,"neutral_ground_prime_required" end
    if not c.airborne then
        c.airborne=true;c.armed=neutral and request=="none"
        return c -- A takeoff sample never starts the bar rotation itself.
    end
    c.air_seconds+=seconds
    if c.air_seconds>15 then return nil,"authored_air_time_exceeded" end
    if c.caught and c.blend_remaining>0 then
        c.blend_remaining=math.max(0,c.blend_remaining-seconds)
        c.release=c.blend_remaining/CATCH_BLEND
    end
    if neutral and request=="none" then c.armed=true end
    if request~="none" then
        local start=c.armed and not c.rotating and not c.waiting and not c.failed
        c.armed=false
        if start then
            c.rotating,c.caught,c.elapsed=true,false,0
            c.catch_elapsed,c.blend_remaining,c.origin=0,0,c.angle
            c.direction=request=="left" and -1 or 1
            return c -- Existing policy: the request arrived at sample end.
        end
    end
    if c.failed then c.release=1;return c end
    if c.rotating then
        c.elapsed+=seconds
        local progress=math.min(1,c.elapsed/BAR_SECONDS)
        c.angle=c.origin+c.direction*TAU*smooth(progress)
        c.release=math.min(1,progress/.10)
        if progress<1 then return c end
        c.rotating,c.waiting,c.catch_elapsed=false,true,math.max(0,c.elapsed-BAR_SECONDS)
    elseif c.waiting then c.catch_elapsed+=seconds end
    if c.waiting then
        c.release=1
        if c.catch_elapsed>CATCH_WINDOW+1e-9 then c.waiting,c.failed=false,true
        elseif neutral then
            -- This is an authored neutral/catch phase only, never a physical
            -- completion. No count, event, landing or score is generated.
            c.waiting,c.caught=false,true;c.blend_remaining=CATCH_BLEND
        end
    end
    return c
end
function Model.target(c)
    -- Equivalent periodic joint pose within existing articulation bounds.
    local angle=(c.angle+math.pi)%TAU-math.pi
    return table.freeze({valid=true,scope="authored_ray_barspin_target_only",realized=false,
        pose_provenance="measured_rays_authored_wheel_geometry",native_collision_contact=false,
        landing_quality_available=false,completion_qualified=false,barspin=angle,
        tailwhip=0,movement_bike_pitch=0,movement_bike_roll=0,movement_crank_angle=0,
        barspin_release=c.release,tailwhip_release=0,release_left_hand=c.release,
        release_right_hand=c.release,release_left_foot=0,release_right_foot=0})
end
function Model.reserved(c) return c.airborne and (c.rotating or c.waiting) end
table.freeze(Model)
-- Optional accepted-step successor; the legacy observed-step trick adapter is
-- untouched. Only Ride's qualified ray-support record is admitted. This owns
-- no body, query, lease, effect, score or progression authority.
local Frame=require("./frame_identity")
local Identity=require("./lease_identity")
-- Model is the closed pure bar channel above; no extra dependency leaf.
local Runtime={}
local SOURCE={"generation","user","sequence","source_epoch","context_generation",
    "observation_serial","observed_ms","packet"}
local SUPPORT={"known","grounded_known","grounded","epoch","provenance",
    "native_collision_contact","actor_lane","actor_tripwire","landing_quality_available","reason"}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function source_matches(a,b,handle)
    if not plain(a) then return false end
    if handle and not rawequal(rawget(a,"lease_handle"),b.lease_handle) then return false end
    for _,name in ipairs(SOURCE) do if rawget(a,name)~=b[name] then return false end end
    return true
end
local function support_copy(raw,frame)
    local support=rawget(raw,"support")
    local contact=rawget(raw,"contact")
    if not plain(support) or not plain(contact) or not plain(rawget(contact,"support"))
        or rawget(contact,"grounded")~=rawget(support,"grounded") then return nil,"ray_support_missing" end
    for _,name in ipairs(SUPPORT) do
        if rawget(contact.support,name)~=rawget(support,name) then return nil,"ray_support_alias_mismatch" end
    end
    if rawget(support,"known")~=true or rawget(support,"grounded_known")~=true
        or type(rawget(support,"grounded"))~="boolean"
        or not rawequal(rawget(support,"epoch"),frame.physics_epoch)
        or rawget(support,"provenance")~="measured_rays_authored_wheel_geometry"
        or rawget(support,"native_collision_contact")~=false
        or rawget(support,"landing_quality_available")~=false
        or rawget(support,"reason")~="landing_quality_not_qualified" then return nil,"ray_support_unqualified" end
    local decoded=rawget(contact,"decoded")
    if not plain(decoded) or rawget(decoded,"valid")~=true or rawget(decoded,"status")~="available"
        or not plain(rawget(decoded,"binding")) or not plain(rawget(decoded,"frame"))
        or not plain(rawget(decoded,"query")) then return nil,"ray_contact_missing" end
    local binding,measured,query=decoded.binding,decoded.frame,decoded.query
    if not rawequal(rawget(binding,"body_handle"),frame.body_handle)
        or not rawequal(rawget(binding,"physics_epoch"),frame.physics_epoch)
        or not rawequal(rawget(binding,"lease_handle"),frame.source.lease_handle)
        or rawget(measured,"serial")~=frame.serial or rawget(measured,"time")~=frame.time
        or rawget(measured,"seconds")~=frame.seconds
        or not source_matches(rawget(measured,"source"),frame.source,false)
        or rawget(query,"epoch_matches")~=true or rawget(query,"accounting_known")~=true
        or rawget(query,"budget_exhausted")~=false or rawget(query,"owned_bodies_excluded")~=true
        or rawget(query,"measurements_complete")~=true then return nil,"ray_contact_binding_mismatch" end
    local lane=rawget(support,"actor_lane")
    if rawget(query,"actor_lane")~=lane then return nil,"ray_actor_lane_mismatch" end
    if lane=="identity" then
        if rawget(query,"local_actor_excluded")~=true
            or rawget(support,"actor_tripwire")~="not_required_identity_lane" then return nil,"ray_actor_unqualified" end
    elseif lane=="named_categories_absent" then
        local tripwire=rawget(support,"actor_tripwire")
        if rawget(query,"named_actor_categories_absent")~=true
            or (tripwire~="authored_rider_crossings_clear_v1"
                and tripwire~="authored_rider_crossings_clear_previous_epoch_v1") then return nil,"ray_actor_unqualified" end
    else return nil,"ray_actor_unqualified" end
    return {grounded=support.grounded,actor_lane=lane,actor_tripwire=support.actor_tripwire}
end
local function actions_copy(raw,frame)
    if not plain(raw) or rawget(raw,"active")~=true
        or not rawequal(rawget(raw,"physics_epoch"),frame.physics_epoch)
        or rawget(raw,"h")~=frame.seconds or not source_matches(rawget(raw,"source"),frame.source,true)
        or type(rawget(raw,"bar_neutral"))~="boolean" then return nil end
    local request=rawget(raw,"handlebar")
    if request~="none" and request~="left" and request~="right" then return nil end
    if request=="left" and rawget(raw,"movement")~=34
        or request=="right" and rawget(raw,"movement")~=44 then return nil end
    return {request=request,neutral=raw.bar_neutral,observation_serial=frame.source.observation_serial}
end
local function reject(why)
    return table.freeze({valid=false,issue=why,scope="accepted_step_ray_barspin_only",
        realized=false,completion_qualified=false})
end
function Runtime.new()
    local state=Model.new()
    local observed,accepted,action_seen,consumed,sequence,draft,air_started
    local revision,stopped,stop_reason=0,false,nil
    local object={}
    local function result(frame,support,next_state)
        local source={lease_handle=frame.source.lease_handle}
        for _,name in ipairs(SOURCE) do source[name]=frame.source[name] end
        return table.freeze({valid=true,issue="candidate",scope="accepted_step_ray_barspin_only",
            realized=false,completion_qualified=false,native_collision_contact=false,
            landing_quality_available=false,actor_lane=support.actor_lane,actor_tripwire=support.actor_tripwire,
            binding=table.freeze({body_handle=frame.body_handle,physics_epoch=frame.physics_epoch,
                lease_handle=frame.source.lease_handle,serial=frame.serial,time=frame.time,seconds=frame.seconds,
                source=table.freeze(source)}),visual_targets=Model.target(next_state),
            requests=table.freeze({rotation_reserved=Model.reserved(next_state),scope="model_request_only"})})
    end
    function object:preview(raw,actions)
        -- One outstanding candidate at most. Replacement/refusal never adopts.
        draft=nil
        if stopped then return reject(stop_reason or "stopped") end
        local frame,why=Frame.copy(raw)
        if not frame then return reject(why) end
        if not frame.fresh or not frame.gates.focused or frame.gates.menu_open then return reject("owner_or_focus_gate") end
        local continuity=Frame.classify(observed,frame)
        if continuity.kind~="prime" and continuity.kind~="successor" and continuity.kind~="duplicate" then
            return reject(continuity.reason)
        end
        if accepted and Identity.compare(frame.serial,accepted.serial)~=1 then return reject("body_step_already_adopted") end
        local support,support_issue=support_copy(raw,frame)
        if not support then return reject(support_issue) end
        local action=actions_copy(actions,frame)
        if not action then return reject("invalid_mapped_barspin_actions") end
        if action_seen and action_seen.observation_serial==action.observation_serial
            and (action_seen.request~=action.request or action_seen.neutral~=action.neutral) then
            return reject("actions_duplicate_changed")
        end
        -- Observe every eligible physical frame, including an eventual refused
        -- command, but do not change accepted model time, action consumption or
        -- articulation. This preserves chronology across command backpressure.
        observed,action_seen=frame,action
        -- Keep the existing authored-air bound on measured time as well, so
        -- repeated discarded candidates cannot extend it by freezing model h.
        if state.airborne and not support.grounded and air_started and frame.time-air_started>15 then
            return reject("authored_air_time_exceeded")
        end
        local request=consumed~=action.observation_serial and action.request or "none"
        local next_state,model_issue=Model.advance(state,frame.seconds,support.grounded,request,action.neutral)
        if not next_state then return reject(model_issue) end
        local out=result(frame,support,next_state)
        local candidate=table.freeze({scope="private_ray_barspin_candidate_v1"})
        local next_air=next_state.airborne and (state.airborne and air_started or frame.time) or nil
        draft={token=candidate,revision=revision,frame=frame,action=action,state=next_state,result=out,air_started=next_air}
        return out,candidate
    end
    function object:discard(candidate)
        if not draft or not rawequal(candidate,draft.token) then return false,"stale_candidate" end
        draft=nil;return true
    end
    function object:adopt(candidate,accepted_sequence)
        if stopped then return false,"stopped" end
        if not draft or not rawequal(candidate,draft.token) or draft.revision~=revision then return false,"stale_candidate" end
        if not Identity.is_nonzero_u64(accepted_sequence)
            or sequence and Identity.compare(accepted_sequence,sequence)~=1 then return false,"invalid_accepted_sequence" end
        -- Root alone calls this after exact native admission and force-history
        -- adoption. This local sequence check is not a native receipt itself.
        local chosen=draft
        state,accepted,consumed,sequence=chosen.state,chosen.frame,chosen.action.observation_serial,accepted_sequence
        air_started=chosen.air_started;revision+=1;draft=nil
        return true,table.freeze({valid=true,scope="predictive_accepted_ray_barspin_only",realized=false,
            completion_qualified=false,serial=accepted.serial,accepted_sequence=sequence,
            visual_targets=chosen.result.visual_targets,requests=chosen.result.requests})
    end
    function object:cancel(reason)
        if stopped then return end
        draft=nil;stopped=true;state=Model.new();revision+=1
        stop_reason=type(reason)=="string" and #reason>0 and #reason<=100 and reason or "cancelled"
    end
    object.stop=object.cancel
    function object:status()
        return table.freeze({scope="accepted_step_ray_barspin_only",realized=false,completion_qualified=false,
            stopped=stopped,issue=stop_reason or "none",revision=revision,
            accepted_sequence=sequence,serial=accepted and accepted.serial or nil,
            visual_targets=Model.target(state),rotation_reserved=Model.reserved(state)})
    end
    return table.freeze(object)
end
return table.freeze(Runtime)
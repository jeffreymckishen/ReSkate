-- Private P0/H1 trial admission. This module observes real Ride/ForceStage
-- values; it does not create a model result, SDK receipt, source or body epoch.
local Identity=require("./lease_identity")
local Catalog=require("./catalog")
local Guard={}
-- Pinned supported-build native step, also declared by forces.lua.
local H=.01666666567325592
local MASS,STRENGTH,IMPULSE=106,.25,119.25
local FORCE,TORQUE,SPEED,VERTICAL,TOTAL=6000,2000,3,3,40000
local source_fields={"lease_handle","generation","user","sequence","source_epoch","context_generation","observation_serial","observed_ms","packet"}
local stream_fields={"lease_handle","generation","user","sequence","source_epoch","context_generation"}
local axes={"left_x","left_y","right_x","right_y","left_trigger","right_trigger"}
local buttons={"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"}
local zero_controls={"pedal","brake","steer","manual","nose_manual","air_yaw","ground_pump"}
local control_flags={"enabled","pump_operator_available","pump_inhibited","rotation_reserved","recovery_step_verified","contact_compliance_available","landing_contact_compliance_selected"}
local zero_actions={"pedal","brake","steer","manual","nose_manual","air_pitch","front_weight"}
local action_facts={"rear_weight","preload","hop_pressed","hop_strength"}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function integer(v,lo,hi) return finite(v) and v%1==0 and v>=lo and v<=hi end
local function array(v,n)
    if not plain(v) then return false end
    local count=0
    for k,x in pairs(v) do
        if not integer(k,1,n) or not finite(x) then return false end
        count+=1
    end
    return count==n
end
local function native(v) return typeof(v)=="vector" and finite(v.x) and finite(v.y) and finite(v.z) end
local function length(v) return math.sqrt(v[1]^2+v[2]^2+v[3]^2) end
local function xyz(v) return {v.x,v.y,v.z} end
local function vector_of(v) return vector.create(v[1],v[2],v[3]) end
local function equal_array(a,b,n)
    if not array(a,n) or not array(b,n) then return false end
    for i=1,n do if a[i]~=b[i] then return false end end
    return true
end
local function equal_fields(a,b,names)
    if not plain(a) or not plain(b) then return false end
    for _,name in ipairs(names) do if a[name]~=b[name] then return false end end
    return true
end
local function pad_copy(p)
    if not plain(p) or not plain(p.buttons) or (p.playstation~=nil and type(p.playstation)~="boolean") then return nil end
    local out={buttons={},playstation=p.playstation}
    for _,name in ipairs(axes) do
        local value=p[name]
        if not finite(value) or math.abs(value)>1 or (string.find(name,"trigger",1,true) and value<0) then return nil end
        out[name]=value
    end
    for _,name in ipairs(buttons) do
        local value=p.buttons[name]
        if value~=nil and type(value)~="boolean" then return nil end
        out.buttons[name]=value
    end
    for _,name in ipairs({"a","b","right_stick","lb","rb"}) do
        if type(out.buttons[name])~="boolean" then return nil end
    end
    return out
end
local function source_copy(s)
    if not plain(s) or typeof(s.lease_handle)~="userdata" or not integer(s.generation,0,9007199254740991)
        or not integer(s.user,0,3) or not integer(s.packet,0,4294967295) then return nil end
    for _,name in ipairs({"sequence","source_epoch","context_generation","observation_serial"}) do
        if not Identity.is_nonzero_u64(s[name]) then return nil end
    end
    if not Identity.is_u64(s.observed_ms) then return nil end
    local out={pad=pad_copy(s.pad)}
    if not out.pad then return nil end
    for _,name in ipairs(source_fields) do out[name]=s[name] end
    return out
end
local function same_source(a,b)
    if not equal_fields(a,b,source_fields) then return false end
    local p,q=plain(a) and a.pad,plain(b) and b.pad
    if not plain(p) or not plain(q) or not equal_fields(p,q,axes) or p.playstation~=q.playstation then return false end
    return equal_fields(p.buttons,q.buttons,buttons)
end
local function sample_copy(s)
    if not plain(s) or typeof(s.epoch)~="userdata" or not Identity.is_nonzero_u64(s.serial)
        or not finite(s.time) or s.time<0 or not finite(s.seconds) or math.abs(s.seconds-H)>1e-8
        or s.mass~=MASS or not array(s.rotation,4) then return nil end
    local out={epoch=s.epoch,serial=s.serial,time=s.time,seconds=s.seconds,mass=s.mass,rotation=table.clone(s.rotation)}
    for _,name in ipairs({"position","velocity","angular_velocity","inertia"}) do
        if not native(s[name]) then return nil end
        out[name]=s[name]
    end
    return out
end
local function same_sample(a,b)
    if not plain(a) or not plain(b) then return false end
    for _,name in ipairs({"epoch","serial","time","seconds","mass","position","velocity","angular_velocity","inertia"}) do
        if a[name]~=b[name] then return false end
    end
    return equal_array(a.rotation,b.rotation,4)
end
local function body_ok(b)
    return plain(b) and b.mass==MASS and array(b.center_of_mass,3) and array(b.orientation,4)
        and array(b.linear_velocity,3) and array(b.angular_velocity,3) and array(b.inertia_body,3)
        and math.sqrt(b.linear_velocity[1]^2+b.linear_velocity[3]^2)<=SPEED
        and math.abs(b.linear_velocity[2])<=VERTICAL
end
local function body_matches(b,s)
    return body_ok(b) and equal_array(b.center_of_mass,xyz(s.position),3)
        and equal_array(b.orientation,s.rotation,4) and equal_array(b.linear_velocity,xyz(s.velocity),3)
        and equal_array(b.angular_velocity,xyz(s.angular_velocity),3) and equal_array(b.inertia_body,xyz(s.inertia),3)
end
local function control_copy(c)
    if not plain(c) or c.enabled~=true then return nil end
    local out={}
    for _,name in ipairs(zero_controls) do if c[name]~=0 then return nil end;out[name]=c[name] end
    for _,name in ipairs(control_flags) do
        if type(c[name])~="boolean" then return nil end
        out[name]=c[name]
    end
    if not integer(c.hop_event_id,0,4294967295) or not finite(c.hop_strength)
        or (c.hop_event_id==0 and c.hop_strength~=0)
        or (c.hop_event_id>0 and c.hop_strength~=STRENGTH) then return nil end
    out.hop_event_id,out.hop_strength=c.hop_event_id,c.hop_strength
    return out
end
local function actions_ok(a,source,epoch,h)
    if not plain(a) or a.active~=true or a.physics_epoch~=epoch or a.h~=h
        or not equal_fields(a.source,source,source_fields) or a.handlebar~="none" or a.tailwhip~="none"
        or a.movement~=Catalog.none or type(a.hop_pressed)~="boolean"
        or not finite(a.rear_weight) or math.abs(a.rear_weight)>1
        or not finite(a.preload) or a.preload<0 or a.preload>1 then return false end
    for _,name in ipairs(zero_actions) do if a[name]~=0 then return false end end
    return a.hop_pressed and a.hop_strength==STRENGTH or not a.hop_pressed and a.hop_strength==0
end
local function no_other_pad(source)
    local p=source.pad
    -- The right-stick Y gesture is allowed. Deadzone-neutral stick noise is
    -- judged by the real mapped controls above, never promoted into input.
    return p.buttons.right_stick==false and p.buttons.a==false and p.buttons.b==false
        and p.buttons.lb==false and p.buttons.rb==false
        and p.left_trigger<=.05 and p.right_trigger<=.05
end
local function control_equal(a,b)
    return equal_fields(a,b,zero_controls) and equal_fields(a,b,control_flags)
        and a.hop_event_id==b.hop_event_id and a.hop_strength==b.hop_strength
end
local function frame_matches(frame,body,raw,source)
    return plain(frame) and frame.valid==true and frame.fresh==true and frame.active==true and frame.loaded==true
        and frame.body_handle==body and frame.physics_epoch==raw.epoch and frame.serial==raw.serial
        and frame.time==raw.time and frame.seconds==raw.seconds and same_sample(frame.sample,raw)
        and body_matches(frame.body,raw) and same_source(frame.source,source)
        and plain(frame.owner) and frame.owner.body_handle==body and frame.owner.lease_handle==source.lease_handle
        and plain(frame.gates) and frame.gates.focused==true and frame.gates.menu_open==false
end
local function support_matches(contact,raw,grounded)
    return plain(contact) and type(contact.grounded)=="boolean" and plain(contact.support)
        and contact.support.known==true and contact.support.grounded_known==true
        and contact.support.epoch==raw.epoch and contact.support.grounded==contact.grounded
        and (grounded==nil or contact.grounded==grounded)
end
local function same_hop(hop,kept)
    if kept==nil then return hop==nil end
    return plain(hop) and hop.id==kept.id and hop.strength==kept.strength
        and hop.observation_serial==kept.observation_serial and hop.observed_ms==kept.observed_ms
        and same_source(hop.source,kept.source)
end
local function context_current(c)
    local controls=c.controls
    return same_sample(c.sample,c.raw) and body_matches(c.raw_body,c.raw)
        and controls.valid==true and controls.submission_allowed==true
        and controls.physics_epoch==c.raw.epoch and controls.h==c.raw.seconds
        and same_source(controls.source,c.source) and control_equal(controls.force_controls,c.force)
        and actions_ok(controls.actions,c.source,c.raw.epoch,c.raw.seconds)
        and equal_fields(controls.actions,c.action,action_facts) and same_hop(controls.hop,c.hop)
        and frame_matches(c.frame,c.body,c.raw,c.source) and support_matches(c.contact,c.raw,c.grounded)
end
function Guard.new()
    local s={phase="P0",admitted=false,configured=false,stopped=false,begins=0,previews=0,
        submits=0,hop_attempts=0,last_outcome="none"}
    local context,prepared,bound,last_submit
    local object={}
    local function refuse(why)
        s.stopped=true;s.admitted=false;s.reason=s.reason or why
        context,prepared=nil,nil
        return false,"hop guard: "..s.reason
    end
    local function available()
        return s.configured and s.admitted and not s.stopped and not s.inflight
    end
    function object:configure(options)
        if s.configured then return refuse("configuration already consumed") end
        s.configured=true
        if not plain(options) or (options.phase~="P0" and options.phase~="H1") or options.admitted~=true then
            return refuse("explicit P0/H1 admission required")
        end
        for key in pairs(options) do if key~="phase" and key~="admitted" then return refuse("unknown configuration field") end end
        s.phase,s.admitted=options.phase,true
        return true
    end
    function object:stop(why)
        return refuse(type(why)=="string" and #why>0 and #why<=180 and why:gsub("[%c]"," ") or "trial stopped")
    end
    function object:begin(body,sample,controls,raw_body,frame,contact)
        prepared,context=nil,nil
        if not available() then return refuse("trial admission unavailable") end
        local raw=sample_copy(sample)
        local source=plain(controls) and source_copy(controls.source)
        local fc=plain(controls) and control_copy(controls.force_controls)
        if typeof(body)~="userdata" or not raw or not source or not fc or not body_matches(raw_body,raw)
            or controls.valid~=true or controls.submission_allowed~=true or controls.physics_epoch~=raw.epoch or controls.h~=raw.seconds then
            return refuse("measured body or mapped controls unavailable")
        end
        if not frame_matches(frame,body,raw,source) then
            return refuse("queued source or model frame mismatch")
        end
        if not actions_ok(controls.actions,source,raw.epoch,raw.seconds) or not no_other_pad(source) then
            return refuse("non-hop action or R3 input")
        end
        if not support_matches(contact,raw) then
            return refuse("current measured support unavailable")
        end
        if s.phase=="P0" and (controls.actions.preload~=0 or controls.actions.rear_weight~=0) then
            return refuse("P0 forbids hop charge")
        end
        local hop,kept_hop=controls.hop,nil
        if controls.actions.hop_pressed and fc.hop_event_id==0 then return refuse("unmatched pressed hop") end
        if fc.hop_event_id>0 then
            local hs=plain(hop) and source_copy(hop.source)
            if s.phase~="H1" then return refuse("P0 forbids hop intent") end
            if not hs or hop.id~=fc.hop_event_id or hop.strength~=STRENGTH
                or hop.observation_serial~=hs.observation_serial or hop.observed_ms~=hs.observed_ms
                or not equal_fields(hs,source,stream_fields) or not no_other_pad(hs)
                or Identity.compare(hs.observation_serial,source.observation_serial)>0
                or not Identity.bounded_delta(source.observed_ms,hs.observed_ms,100) then
                return refuse("quarter-strength hop source unavailable")
            end
            kept_hop={id=hop.id,strength=hop.strength,source=hs,observation_serial=hop.observation_serial,observed_ms=hop.observed_ms}
        elseif hop~=nil then return refuse("unmatched hop intent") end
        if bound and (bound.body~=body or not equal_fields(bound.source,source,stream_fields)
            or Identity.compare(raw.serial,bound.serial)<0 or Identity.compare(source.observation_serial,bound.source.observation_serial)<0
            or Identity.compare(source.observed_ms,bound.source.observed_ms)<0) then return refuse("owner or chronology changed") end
        bound={body=body,source=source,serial=raw.serial}
        -- rear_weight/preload describe the real hop gesture; they are not
        -- force channels. Retain them exactly instead of remapping the pad.
        local action={};for _,name in ipairs(action_facts) do action[name]=controls.actions[name] end
        context={body=body,sample=sample,raw=raw,source=source,controls=controls,force=fc,hop=kept_hop,action=action,
            raw_body=raw_body,frame=frame,contact=contact,grounded=contact.grounded}
        s.begins+=1;s.serial=raw.serial;s.observation_serial=source.observation_serial
        return true
    end
    function object:observe(h,folded_body,force_controls,model,candidate)
        prepared=nil
        if not available() or not context then return refuse("no current measured candidate") end
        local c=context
        if h~=c.raw.seconds or not body_ok(folded_body) or not context_current(c)
            or not control_equal(force_controls,c.force) then return refuse("preview identity or controls changed") end
        if not plain(model) or model.valid~=true or model.contact_scale~=1 or not plain(candidate)
            or not array(model.force,3) or not array(model.torque,3) or not array(model.hop_impulse,3)
            or type(model.hop_applied)~="boolean" or length(model.force)>FORCE or length(model.torque)>TORQUE then
            return refuse("preview exceeds trial caps or is invalid")
        end
        if model.hop_applied then
            if s.phase~="H1" or c.force.hop_strength~=STRENGTH or c.force.hop_event_id==0
                or model.hop_event_id~=c.force.hop_event_id or not c.grounded or model.grounded~=true
                or not equal_array(model.hop_impulse,{0,IMPULSE,0},3) then return refuse("quarter-strength impulse mismatch") end
        elseif model.hop_event_id~=0 or not equal_array(model.hop_impulse,{0,0,0},3) then
            return refuse("unexpected impulse without hop")
        end
        local combined={}
        for i=1,3 do combined[i]=model.force[i]+model.hop_impulse[i]/h end
        if length(combined)>TOTAL then return refuse("total force plus impulse exceeds packet limit") end
        prepared={candidate=candidate,body=c.body,epoch=c.raw.epoch,serial=c.raw.serial,
            force=vector_of(model.force),torque=vector_of(model.torque),
            impulse=model.hop_applied and vector_of(model.hop_impulse) or nil,
            impulse_id=model.hop_applied and model.hop_event_id or nil,h=h}
        s.previews+=1
        return true
    end
    function object:submit(body,epoch,packet,delegate)
        local p=prepared;prepared=nil
        if not available() or not p or not context then return refuse("no eligible prepared packet") end
        if body~=p.body or epoch~=p.epoch or not context_current(context)
            or not plain(packet) or type(delegate)~="function" or not native(packet.force) or not native(packet.torque)
            or packet.force~=p.force or packet.torque~=p.torque or packet.impulse~=p.impulse or packet.impulse_id~=p.impulse_id then
            return refuse("prepared packet or body epoch mismatch")
        end
        for key in pairs(packet) do
            if key~="force" and key~="torque" and key~="impulse" and key~="impulse_id" then return refuse("unexpected packet field") end
        end
        -- Native vectors round their components. Check the exact packed values
        -- with scalar arithmetic, whose norm does not round back to the cap.
        local force,torque,impulse=xyz(packet.force),xyz(packet.torque),packet.impulse and xyz(packet.impulse) or {0,0,0}
        local combined={};for i=1,3 do combined[i]=force[i]+impulse[i]/p.h end
        if length(force)>FORCE or length(torque)>TORQUE or length(combined)>TOTAL then
            return refuse("packed packet exceeds trial caps")
        end
        if last_submit and Identity.compare(p.serial,last_submit)<=0 then return refuse("native serial already attempted") end
        if p.impulse~=nil and s.hop_attempts~=0 then return refuse("one native hop attempt already consumed") end
        -- Reserve before invoking the SDK. Even a refusal, exception, or late
        -- accepted return cannot make a second native impulse attempt possible.
        last_submit=p.serial;s.submits+=1;s.inflight=true
        if p.impulse~=nil then s.hop_attempts+=1;s.hop_event_id=p.impulse_id end
        local result=table.pack(pcall(delegate,body,epoch,packet))
        s.inflight=false
        if result[1] and result.n==4 and result[2]==true and result[3]==nil and Identity.is_nonzero_u64(result[4]) then
            s.last_outcome="accepted";s.sequence=result[4]
        elseif result[1] and result.n==3 and result[2]==false and type(result[3])=="string" then s.last_outcome="refused"
        else s.last_outcome="unknown";refuse("SDK publication outcome unknown") end
        if not result[1] then error(result[2],0) end
        return table.unpack(result,2,result.n)
    end
    function object:status()
        return table.freeze({phase=s.phase,configured=s.configured,admitted=s.admitted,stopped=s.stopped,
            reason=s.reason,begins=s.begins,previews=s.previews,submits=s.submits,hop_attempts=s.hop_attempts,
            inflight=s.inflight==true,last_outcome=s.last_outcome,sequence=s.sequence,serial=s.serial,
            observation_serial=s.observation_serial,hop_event_id=s.hop_event_id})
    end
    return table.freeze(object)
end
return table.freeze(Guard)

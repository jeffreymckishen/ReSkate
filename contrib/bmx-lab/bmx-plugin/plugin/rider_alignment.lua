-- Pure rider target/IK policy. This module owns no SDK objects and makes no
-- native calls. A request is never evidence that a native bone moved.
-- Coordinates: authored bike +Y up, +Z forward, +X rider-left; Hamilton XYZW.
-- The native rig basis must be supplied by an actual calibrated rig snapshot.
local A = {}
local PI, EPS = math.pi, 1e-9
local function finite(x) return type(x)=="number" and x==x and math.abs(x)<math.huge end
local function vec(v, bound)
    if type(v)~="table" then return false end
    for i=1,3 do if not finite(v[i]) or math.abs(v[i])>(bound or 1000000) then return false end end
    return true
end
local function copy(v) local r={} for i=1,#v do r[i]=v[i] end return r end
local function add(a,b) return {a[1]+b[1],a[2]+b[2],a[3]+b[3]} end
local function sub(a,b) return {a[1]-b[1],a[2]-b[2],a[3]-b[3]} end
local function mul(a,b) return {a[1]*b,a[2]*b,a[3]*b} end
local function dot(a,b) return a[1]*b[1]+a[2]*b[2]+a[3]*b[3] end
local function cross(a,b) return {a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1]} end
local function length(a) return math.sqrt(dot(a,a)) end
local function unit(a) local n=length(a) if n<EPS then return nil end return mul(a,1/n) end
local function clamp(x,lo,hi) return math.max(lo,math.min(hi,x)) end
local function blend(a,b,t) return add(mul(a,1-t),mul(b,t)) end
local function default(x,value) if x==nil then return value end return x end
local function checked_quat(q)
    if type(q)~="table" then return nil end
    local n=0
    for i=1,4 do if not finite(q[i]) then return nil end n=n+q[i]*q[i] end
    if math.abs(n-1)>.001 then return nil end
    n=math.sqrt(n) return {q[1]/n,q[2]/n,q[3]/n,q[4]/n}
end
local function normalized(q)
    local n=math.sqrt(q[1]^2+q[2]^2+q[3]^2+q[4]^2)
    if n<EPS then return nil end
    return {q[1]/n,q[2]/n,q[3]/n,q[4]/n}
end
local function inverse(q) return {-q[1],-q[2],-q[3],q[4]} end
local function multiply(a,b)
    return {a[4]*b[1]+a[1]*b[4]+a[2]*b[3]-a[3]*b[2],
        a[4]*b[2]-a[1]*b[3]+a[2]*b[4]+a[3]*b[1],
        a[4]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[4],
        a[4]*b[4]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3]}
end
local function turn(q,p)
    local v={q[1],q[2],q[3]} local t=mul(cross(v,p),2)
    return add(p,add(mul(t,q[4]),cross(v,t)))
end
local function axis(n,angle)
    local s=math.sin(angle*.5) return {n[1]*s,n[2]*s,n[3]*s,math.cos(angle*.5)}
end
local function from_to(a,b)
    a,b=unit(a),unit(b)
    if not a or not b then return nil end
    local d=clamp(dot(a,b),-1,1)
    if d<-.999999 then
        local n=unit(cross(a,math.abs(a[2])<.9 and {0,1,0} or {1,0,0}))
        return {n[1],n[2],n[3],0}
    end
    local n=cross(a,b) return normalized({n[1],n[2],n[3],1+d})
end
local function limited_rotation(a,b,limit)
    -- Tolerated input norm error must not change the dot product's angle or
    -- leak a non-unit endpoint when the angular bound is zero or already met.
    a,b=normalized(a),normalized(b)
    local d=a[1]*b[1]+a[2]*b[2]+a[3]*b[3]+a[4]*b[4]
    if d<0 then b={-b[1],-b[2],-b[3],-b[4]} d=-d end
    local angle=2*math.acos(clamp(d,-1,1))
    if limit==0 then return copy(a),angle>0 end
    if angle<=limit or angle<EPS then return copy(b),false end
    local t=limit/angle local half=angle*.5 local sine=math.sin(half)
    local x,y=math.sin((1-t)*half)/sine,math.sin(t*half)/sine
    return normalized({a[1]*x+b[1]*y,a[2]*x+b[2]*y,a[3]*x+b[3]*y,a[4]*x+b[4]*y}),true
end
local function serial(s)
    return type(s)=="string" and s:match("^[1-9][0-9]*$")~=nil and
        (#s<20 or (#s==20 and s<="18446744073709551615"))
end
local function unavailable(issue)
    return {status="unavailable",issue=issue,targets=nil,pose_request=nil,native_alignment=false}
end
local function binding_matches(sample,frame)
    return type(sample)=="table" and sample.valid==true and sample.fresh==true and
        sample.serial==frame.serial and sample.physics_epoch==frame.physics_epoch and
        sample.body_handle==frame.body_handle
end
local function transform_point(root,q,p) return add(root,turn(q,p)) end
local function around(p,pivot,n,angle) return add(pivot,turn(axis(n,angle),sub(p,pivot))) end

-- Segment lengths are retained even when a target is unreachable or coincides
-- with the root. Pole is a direction, never a world position. Zero/parallel
-- poles use a deterministic perpendicular fallback without dividing by zero.
function A.two_bone(root,target,pole,a,b,fallback)
    if not vec(root) or not vec(target) or not vec(pole,10) or not finite(a) or not finite(b) or
        a<.04 or b<.04 or a>1 or b>1 then return nil,"invalid limb" end
    local delta=sub(target,root) local requested=length(delta)
    local direction=unit(delta) or (vec(fallback,10) and unit(fallback)) or {0,0,1}
    local margin=math.min(.0001,math.min(a,b)*.01)
    local reach=clamp(requested,math.abs(a-b)+margin,a+b-margin)
    local along=(a*a-b*b+reach*reach)/(2*reach)
    local height=math.sqrt(math.max(0,a*a-along*along))
    local side=unit(sub(pole,mul(direction,dot(pole,direction))))
    if not side then side=unit(cross(direction,math.abs(direction[2])<.9 and {0,1,0} or {1,0,0})) end
    local middle=add(root,add(mul(direction,along),mul(side,height)))
    local tip=add(root,mul(direction,reach)) local error=length(sub(tip,target))
    return {root=copy(root),middle=middle,tip=tip,requested_target=copy(target),
        requested_distance=requested,reach=reach,error=error,clamped=math.abs(requested-reach)>EPS,
        upper_length=a,lower_length=b}
end

-- Parent/world conversions reject invalid quaternions instead of silently
-- substituting identity. They are public for adapters and pure geometry tests.
function A.to_world(parent,p,q)
    local pq=type(parent)=="table" and checked_quat(parent.rotation)
    local scale=type(parent)=="table" and default(parent.scale,1) or nil
    q=checked_quat(q)
    if not pq or not q or not vec(parent.position) or not vec(p,10) or
        not finite(scale) or scale<=0 or scale>10 then return nil end
    return {position=transform_point(parent.position,pq,mul(p,scale)),rotation=normalized(multiply(pq,q))}
end
function A.to_local(parent,p,q)
    local pq=type(parent)=="table" and checked_quat(parent.rotation)
    local scale=type(parent)=="table" and default(parent.scale,1) or nil
    q=checked_quat(q)
    if not pq or not q or not vec(parent.position) or not vec(p) or
        not finite(scale) or scale<=0 or scale>10 then return nil end
    return {position=mul(turn(inverse(pq),sub(p,parent.position)),1/scale),
        rotation=normalized(multiply(inverse(pq),q))}
end

local angle_fields={steer=.9,barspin=8*PI,tailwhip=8*PI,crank_phase=1000000,
    movement_bike_pitch=4*PI,movement_bike_roll=4*PI}
local limbs={"left_arm","right_arm","left_leg","right_leg"}
local source_fields={"generation","user","sequence","source_epoch","context_generation",
    "observation_serial","observed_ms","packet"}
local function adapter_matches(result,frame)
    local b,s=type(result)=="table" and result.binding,frame.source
    if result.valid~=true or result.fresh~=true or result.advanced~=true or result.realized~=false or
        type(b)~="table" or type(s)~="table" or type(b.source)~="table" or s.lease_handle==nil or
        b.body_handle~=frame.body_handle or b.physics_epoch~=frame.physics_epoch or
        b.lease_handle~=s.lease_handle or b.source.lease_handle~=s.lease_handle or
        result.serial~=frame.serial or result.time~=frame.time or b.serial~=frame.serial or
        not finite(frame.time) or not finite(frame.seconds) or frame.seconds<=0 or
        b.time~=frame.time or b.seconds~=frame.seconds then return false end
    for _,k in ipairs(source_fields) do if s[k]==nil or b.source[k]~=s[k] then return false end end
    return true
end
local function articulation(visual,frame,options)
    local pose={} for k in pairs(angle_fields) do pose[k]=0 end
    local rider={hip_offset={0,0,0},torso_offset={0,0,0},hip_yaw=0,hip_roll=0,
        release={left_arm=0,right_arm=0,left_leg=0,right_leg=0},local_targets={}}
    local base=default(options.base_articulation,{})
    if type(base)~="table" then return nil,nil,"invalid base articulation" end
    for _,k in ipairs({"steer","crank_phase"}) do
        local value=default(base[k],0)
        if not finite(value) or math.abs(value)>angle_fields[k] then return nil,nil,"invalid base articulation "..k end
        pose[k]=value
    end
    if visual==nil then return pose,rider end
    local private_bound=type(visual)=="table" and visual.scope=="model_adapter_only"
    if private_bound then
        if not adapter_matches(visual,frame) or type(visual.visual_targets)~="table" or
            visual.visual_targets.valid~=true or visual.visual_targets.scope~="model_target_only" then
            return nil,nil,"stale or unbound private trick result" end
        visual=visual.visual_targets
    end
    if not private_bound and (type(visual)~="table" or visual.valid~=true or visual.fresh~=true or visual.serial~=frame.serial or
        default(visual.physics_epoch,visual.epoch)~=frame.physics_epoch or
        (visual.physics_epoch~=nil and visual.physics_epoch~=frame.physics_epoch) or
        (visual.epoch~=nil and visual.epoch~=frame.physics_epoch) or
        (visual.body_handle~=nil and visual.body_handle~=frame.body_handle)) then
        return nil,nil,"stale or unbound visual targets" end
    local input=default(visual.articulation,{})
    local flat=visual.scope=="model_target_only"
    local flat_rider
    if flat then
        if visual.pose_provenance~="authored_motions_policy" or visual.realized~=false or
            type(visual.bar_neutral)~="boolean" or type(visual.rear_neutral)~="boolean" or
            not finite(visual.phase) or visual.phase<0 or visual.phase>1 or
            not finite(visual.progress) or visual.progress<0 or visual.progress>1 or
            not finite(visual.movement_crank_angle) or math.abs(visual.movement_crank_angle)>8*PI then
            return nil,nil,"invalid model target provenance" end
        input={steer=pose.steer,crank_phase=pose.crank_phase+visual.movement_crank_angle}
        for _,k in ipairs({"barspin","tailwhip","movement_bike_pitch","movement_bike_roll"}) do
            if visual[k]==nil then return nil,nil,"missing model target "..k end
            input[k]=visual[k]
        end
        flat_rider={release={left_arm=visual.release_left_hand,right_arm=visual.release_right_hand,
            left_leg=visual.release_left_foot,right_leg=visual.release_right_foot}}
        for _,name in ipairs(limbs) do
            if flat_rider.release[name]==nil then return nil,nil,"missing model release "..name end
        end
    elseif visual.scope~=nil then return nil,nil,"unknown visual target scope" end
    if type(input)~="table" then return nil,nil,"invalid articulation table" end
    for k,cap in pairs(angle_fields) do
        local x=default(input[k],pose[k])
        if not finite(x) or math.abs(x)>cap then return nil,nil,"invalid articulation "..k end
        pose[k]=x
    end
    local r=flat_rider or default(visual.rider,{})
    if type(r)~="table" or (r.release~=nil and type(r.release)~="table") or
        (r.local_targets~=nil and type(r.local_targets)~="table") then return nil,nil,"invalid rider table" end
    for _,k in ipairs({"hip_offset","torso_offset"}) do
        local v=default(r[k],{0,0,0}) if not vec(v,.5) then return nil,nil,"invalid rider offset" end rider[k]=copy(v)
    end
    for _,k in ipairs({"hip_yaw","hip_roll"}) do
        local x=default(r[k],0) if not finite(x) or math.abs(x)>PI then return nil,nil,"invalid rider angle" end rider[k]=x
    end
    for _,name in ipairs(limbs) do
        local release=default((r.release or {})[name],0)
        if not finite(release) or release<0 or release>1 then return nil,nil,"invalid limb release" end
        rider.release[name]=release
        local p=(r.local_targets or {})[name]
        if p then if not vec(p,3) then return nil,nil,"invalid motion target" end rider.local_targets[name]=copy(p) end
    end
    return pose,rider
end

local function geometry_valid(g)
    local valid=type(g)=="table" and vec(g.com,3) and vec(g.left_grip,3) and vec(g.right_grip,3) and
        vec(g.steering_pivot,3) and vec(g.steering_axis,2) and unit(g.steering_axis) and
        vec(g.bottom_bracket,3) and type(g.pedals)=="table" and vec(g.pedals[1],3) and vec(g.pedals[2],3)
    if not valid then return false end
    return g.pedal_contact_offsets==nil or (type(g.pedal_contact_offsets)=="table" and
        vec(g.pedal_contact_offsets[1],.3) and vec(g.pedal_contact_offsets[2],.3))
end
local function make_targets(frame,g,pose,rider)
    local q=checked_quat(frame.body.orientation) local root=sub(frame.body.center_of_mass,turn(q,g.com))
    local steering=unit(g.steering_axis)
    local function whole(p)
        p=around(p,g.steering_pivot,{1,0,0},pose.movement_bike_pitch)
        return around(p,g.steering_pivot,{0,0,1},pose.movement_bike_roll)
    end
    local function local_contact(i,spun)
        if i<=2 then return whole(around(i==1 and g.left_grip or g.right_grip,g.steering_pivot,steering,
            pose.steer+(spun and pose.barspin or 0))) end
        -- Existing bike_geometry exports spindles, not measured shoe contacts.
        -- A supplied pedal_contact offset is authored data, still not observation.
        local p=g.pedals[i-2] local offset=g.pedal_contact_offsets and g.pedal_contact_offsets[i-2]
        local spindle=around(p,g.bottom_bracket,{1,0,0},pose.crank_phase)
        p=offset and add(spindle,offset) or spindle
        return whole(around(p,g.steering_pivot,steering,spun and pose.tailwhip or 0))
    end
    local targets={bike_root=copy(root),center_of_mass=copy(frame.body.center_of_mass),bike_rotation=copy(q),
        hip=transform_point(root,q,add({0,.9578988338,-.2877711058},rider.hip_offset)),
        chest=transform_point(root,q,add({0,1.476639786,.015},rider.torso_offset)),limbs={}}
    local whole_q=multiply(axis({0,0,1},pose.movement_bike_roll),axis({1,0,0},pose.movement_bike_pitch))
    for i,name in ipairs(limbs) do
        local left=i%2==1 local release=rider.release[name]
        local closed=local_contact(i,true) local free
        if i<=2 then free=add(local_contact(i,false),{left and .08 or -.08,.12,-.08})
        else free={left and .2792422 or -.2792422,g.bottom_bracket[2]+.52,g.bottom_bracket[3]-.08} end
        if rider.local_targets[name] then free=rider.local_targets[name] end
        local p=blend(closed,free,release)
        local part=multiply(whole_q,axis(steering,i<=2 and (pose.steer+pose.barspin) or pose.tailwhip))
        local free_q=i<=2 and multiply(whole_q,axis(steering,pose.steer)) or {0,0,0,1}
        -- Rotation follows an explicit release blend, independent of reach.
        local d=part[1]*free_q[1]+part[2]*free_q[2]+part[3]*free_q[3]+part[4]*free_q[4]
        if d<0 then free_q={-free_q[1],-free_q[2],-free_q[3],-free_q[4]} end
        local part_q=normalized({part[1]*(1-release)+free_q[1]*release,part[2]*(1-release)+free_q[2]*release,
            part[3]*(1-release)+free_q[3]*release,part[4]*(1-release)+free_q[4]*release}) or part
        targets.limbs[name]={contact_world=transform_point(root,q,p),contact_local=copy(p),
            orientation_frame=normalized(multiply(q,part_q)),release=release,
            anchor_kind=i<=2 and "authored_grip" or (g.pedal_contact_offsets and "authored_pedal_contact" or "spindle_proxy")}
    end
    targets.root_orientation_frame=normalized(multiply(q,multiply(axis({0,1,0},rider.hip_yaw),axis({0,0,1},rider.hip_roll))))
    return targets
end

local function rig_valid(rig,frame)
    if not binding_matches(rig,frame) or rig.basis~="calibrated" or type(rig.root)~="table" or
        not vec(rig.root.position) or not checked_quat(rig.root.rotation) or
        not checked_quat(rig.bike_to_root_rotation) or not checked_quat(rig.root.parent_rotation) then return false end
    if type(rig.chains)~="table" then return false end
    for _,name in ipairs(limbs) do
        local c=rig.chains[name]
        if type(c)~="table" or not vec(c.contact_offset,.3) or not checked_quat(c.bike_to_tip_rotation) or
            not checked_quat(c.parent_rotation) then return false end
        for _,key in ipairs({"upper","middle","tip"}) do
            local bone=c[key]
            if type(bone)~="table" or not vec(bone.position) or not checked_quat(bone.rotation) then return false end
        end
        local a,b=length(sub(c.middle.position,c.upper.position)),length(sub(c.tip.position,c.middle.position))
        if a<.04 or b<.04 or a>1 or b>1 then return false end
    end
    return true
end
local function pose_request(rig,targets,options)
    local shift_cap=default(options.maximum_root_shift,.18) local angle_cap=default(options.maximum_root_rotation,.75)
    local tip_cap=default(options.maximum_tip_rotation,.8)
    if not finite(shift_cap) or shift_cap<0 or shift_cap>.35 or not finite(angle_cap) or angle_cap<0 or angle_cap>PI or
        not finite(tip_cap) or tip_cap<0 or tip_cap>PI then return nil,"invalid pose bounds" end
    local source_rotation=checked_quat(rig.root.rotation)
    local root_basis=checked_quat(rig.bike_to_root_rotation)
    local wanted=normalized(multiply(targets.root_orientation_frame,root_basis))
    local root_q,rotation_limited=limited_rotation(source_rotation,wanted,angle_cap)
    local shift=sub(targets.hip,rig.root.position) local shift_length=length(shift)
    if shift_length>shift_cap then shift=mul(shift,shift_cap/shift_length) end
    local root=add(rig.root.position,shift) local dq=normalized(multiply(root_q,inverse(source_rotation)))
    local result={space="world",root={position=root,rotation=root_q,
        local_rotation=normalized(multiply(inverse(rig.root.parent_rotation),root_q))},limbs={},
        root_shift=length(shift),root_shift_limited=shift_length>shift_cap,root_rotation_limited=rotation_limited,
        all_targets_reachable=true,contact_observed=false,applied=false}
    for _,name in ipairs(limbs) do
        local c,t=rig.chains[name],targets.limbs[name]
        local function moved(p) return add(root,turn(dq,sub(p,rig.root.position))) end
        local upper,mid,tip=moved(c.upper.position),moved(c.middle.position),moved(c.tip.position)
        local tip_source=normalized(multiply(dq,c.tip.rotation))
        local tip_q,tip_limited=limited_rotation(tip_source,normalized(multiply(t.orientation_frame,c.bike_to_tip_rotation)),tip_cap)
        local wrist=sub(t.contact_world,turn(tip_q,c.contact_offset))
        local left=name=="left_arm" or name=="left_leg"
        local pole=name:find("arm",1,true) and {left and .12 or -.12,-1.7,-.05} or {0,0,1}
        pole=turn(targets.bike_rotation,pole)
        local ik,issue=A.two_bone(upper,wrist,pole,length(sub(mid,upper)),length(sub(tip,mid)),sub(tip,upper))
        if not ik then return nil,issue end
        local uq=normalized(multiply(from_to(sub(mid,upper),sub(ik.middle,upper)),multiply(dq,c.upper.rotation)))
        local mq=normalized(multiply(from_to(sub(tip,mid),sub(ik.tip,ik.middle)),multiply(dq,c.middle.rotation)))
        local parent=normalized(multiply(dq,c.parent_rotation))
        ik.upper_rotation=uq ik.middle_rotation=mq ik.tip_rotation=tip_q ik.tip_rotation_limited=tip_limited
        ik.upper_local_rotation=normalized(multiply(inverse(parent),uq))
        ik.middle_local_rotation=normalized(multiply(inverse(uq),mq))
        ik.tip_local_rotation=normalized(multiply(inverse(mq),tip_q))
        ik.contact_requested=copy(t.contact_world) ik.contact_result=add(ik.tip,turn(tip_q,c.contact_offset))
        ik.contact_error=length(sub(ik.contact_result,t.contact_world)) ik.release=t.release
        result.limbs[name]=ik
        if ik.clamped then result.all_targets_reachable=false end
    end
    return result
end

function A.solve(frame,geometry,visual_targets,options)
    options=default(options,{})
    if type(options)~="table" then return unavailable("invalid options") end
    if options.enabled~=true then return {status="disabled",targets=nil,pose_request=nil,native_alignment=false} end
    if options.bike_basis~="y_up_z_forward_x_left" then return unavailable("unknown bike basis") end
    if type(frame)~="table" or frame.valid~=true or frame.fresh~=true or not serial(frame.serial) or
        frame.physics_epoch==nil or frame.body_handle==nil or type(frame.body)~="table" or
        not vec(frame.body.center_of_mass,999990) or not checked_quat(frame.body.orientation) then return unavailable("invalid or stale measured frame") end
    if frame.gates~=nil and type(frame.gates)~="table" then return unavailable("invalid measured gates") end
    if frame.gates and (frame.gates.focused==false or frame.gates.menu_open==true or frame.gates.falling==true) then
        return unavailable("measured frame gate closed") end
    if not geometry_valid(geometry) then return unavailable("invalid authored geometry") end
    local pose,rider,issue=articulation(visual_targets,frame,options)
    if not pose then return unavailable(issue) end
    local targets=make_targets(frame,geometry,pose,rider)
    local result={status="targets_only",targets=targets,pose_request=nil,native_alignment=false,
        diagnostics={serial=frame.serial,physics_epoch=frame.physics_epoch,body_handle=frame.body_handle,
            basis="y_up_z_forward_x_left",rig_available=false,contact_observed=false,applied=false,
            issue="coherent calibrated rig snapshot and qualified native pose bridge unavailable"}}
    if options.rig~=nil then
        if not rig_valid(options.rig,frame) then return unavailable("invalid or stale calibrated rig") end
        local request,reason=pose_request(options.rig,targets,options)
        if not request then return unavailable(reason) end
        result.status="request_ready" result.pose_request=request result.diagnostics.rig_available=true
        result.diagnostics.issue="pure bounded request only; native application unverified"
    end
    return result
end

return table.freeze and table.freeze(A) or A

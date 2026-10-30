-- Private fixed-pose workspace. Geometry and inertia are constant throughout a
-- single contact solve; only velocities, rotor speeds and impulse limits vary.
-- No caller tables are mutated and no row survives into the next model step.
local M=require("./force_math")
local Brake=require("./brake")
local S={}
local function valid(state)
    -- Every private workspace component is already a number. Range comparisons
    -- also reject NaN/infinity, without eight generic type-check calls per row.
    -- Written out rather than looped: a braked step runs this about 800 times.
    local x1,x2,x3,x4,x5,x6,x7,x8=state[1],state[2],state[3],state[4],state[5],state[6],state[7],state[8]
    return x1>=-1e5 and x1<=1e5 and x2>=-1e5 and x2<=1e5 and x3>=-1e5 and x3<=1e5 and x4>=-1e5 and x4<=1e5
        and x5>=-1e5 and x5<=1e5 and x6>=-1e5 and x6<=1e5 and x7>=-1e5 and x7<=1e5 and x8>=-1e5 and x8<=1e5
end
local function row(body,wheel,linear,angular,rotor,offset)
    local spin=M.tensor(body,angular,true)
    return {linear[1],linear[2],linear[3],angular[1],angular[2],angular[3],rotor,
        linear[1]/body.mass,linear[2]/body.mass,linear[3]/body.mass,spin[1],spin[2],spin[3],rotor/wheel.inertia,offset}
end
local function mass(body,wheel,a,b)
    return (a[1]*b[1]+a[2]*b[2]+a[3]*b[3])/body.mass+
        (a[4]*b[11]+a[5]*b[12]+a[6]*b[13])+a[7]*b[7]/wheel.inertia
end
local function speed(state,r,wi)
    return state[1]*r[1]+state[2]*r[2]+state[3]*r[3]+state[4]*r[4]+state[5]*r[5]+state[6]*r[6]+state[wi]*r[7]-r[15]
end
-- The loops of the row arithmetic are written out, each term and its order
-- unchanged, so the results are the same numbers with fewer interpreter steps.
local function apply(state,r,wi,j,point_impulse)
    if not valid(state) or not (type(j)=="number" and j==j and math.abs(j)<math.huge) then return false end
    if point_impulse and (math.abs(r[1]*j)>1e9 or math.abs(r[2]*j)>1e9 or math.abs(r[3]*j)>1e9) then return false end
    state[1]+=r[8]*j state[2]+=r[9]*j state[3]+=r[10]*j state[4]+=r[11]*j state[5]+=r[12]*j state[6]+=r[13]*j
    state[wi]+=r[14]*j return valid(state)
end
local function prepare(body,wheel,contact,free_axis)
    local basis,lateral
    if contact.status=="clear" and free_axis~=nil then
        -- Mechanical rotor coupling remains available without a terrain observation.
        lateral=M.unit(free_axis) if not lateral then return nil end
    else
        basis=M.basis(contact.normal,contact.forward) if not basis then return nil end
        lateral=basis.lateral
    end
    if contact.normal_only==true and free_axis~=nil then lateral=M.unit(free_axis) if not lateral then return nil end end
    local softness=contact.normal_softness
    if softness==nil then softness=0 end
    local p={hit=contact.status=="hit",inertia=wheel.inertia,radius=wheel.radius,cache={},cache_slot=1,
        normal_only=contact.normal_only==true,softness=softness,floor_delta=contact.normal_floor_delta}
    if not M.finite(p.softness) or p.softness<0 or p.floor_delta~=nil and not M.finite(p.floor_delta) then return nil end
    p.axle=row(body,wheel,{0,0,0},M.mul(lateral,-1),1,0)
    p.axle_mass=1/wheel.inertia+M.dot(lateral,M.tensor(body,lateral,true))
    if not M.finite(p.axle_mass) or p.axle_mass<=0 then return nil end
    if not p.hit then return p end
    local arm=M.sub(contact.point,body.center_of_mass)
    local hub_arm=M.sub(M.add(contact.point,M.mul(basis.normal,wheel.radius)),body.center_of_mass)
    p.normal=row(body,wheel,basis.normal,M.cross(arm,basis.normal),0,M.dot(contact.surface_velocity,basis.normal))
    p.forward=row(body,wheel,basis.forward,M.cross(hub_arm,basis.forward),-wheel.radius,M.dot(contact.surface_velocity,basis.forward))
    p.lateral=row(body,wheel,lateral,M.cross(arm,lateral),0,M.dot(contact.surface_velocity,lateral))
    -- Retain the public tire path's effective-mass evaluation and determinant
    -- boundaries; the brake's generalized matrix uses its own original form.
    p.normal_mass=M.dot(basis.normal,M.response(body,arm,basis.normal))
    p.tire_ff=M.dot(basis.forward,M.response(body,hub_arm,basis.forward))+wheel.radius^2/wheel.inertia
    p.tire_ll=M.dot(lateral,M.response(body,arm,lateral))
    p.tire_fl=M.dot(basis.forward,M.response(body,arm,lateral,hub_arm))
    local rows={p.forward,p.lateral,p.axle} p.k={}
    for i=1,3 do for j=1,3 do local x=mass(body,wheel,rows[i],rows[j]) if not M.finite(x) then return nil end p.k[(i-1)*3+j]=x end end
    if not M.finite(p.normal_mass) or p.normal_mass<=0 or not M.finite(p.tire_ff) or not M.finite(p.tire_ll) or
        not M.finite(p.tire_fl) or p.tire_ff<=0 or p.tire_ll<=0 or p.k[1]<=0 or p.k[5]<=0 then return nil end
    return p
end
local function normal(state,p,wi)
    if not p.hit then return 0 end
    local r=p.normal
    local relative=state[1]*r[1]+state[2]*r[2]+state[3]*r[3]+state[4]*r[4]+state[5]*r[5]+state[6]*r[6]+state[wi]*r[7]-r[15]
    local j=math.max(0,-relative/(p.normal_mass+p.softness))
    if p.floor_delta~=nil then j=math.max(j,(p.floor_delta-relative)/p.normal_mass) end
    if not apply(state,r,wi,j,true) then return nil end return j
end
local function tire(state,p,wi,h,friction,solved,normal_impulse)
    if not valid(state) then return false end
    local j=normal_impulse
    if j==nil then j=normal(state,p,wi) end
    if j==nil then return false end
    solved.normal_impulse=p.normal_only and 0 or j solved.normal_load=solved.normal_impulse/h
    solved.approach_impulse=p.normal_only and j or 0 solved.longitudinal_impulse=0 solved.lateral_impulse=0
    if not p.hit or p.normal_only then return true end
    local lf,ll=friction.longitudinal_friction*j,friction.lateral_friction*j
    if lf>0 or ll>0 then
        local slip,lateral=speed(state,p.forward,wi),speed(state,p.lateral,wi)
        local ff,fl,nn=p.tire_ff,p.tire_fl,p.tire_ll
        local fj,lj=0,0
        if lf>0 and ll>0 then
            local determinant=ff*nn-fl*fl if not M.finite(determinant) or determinant<=1e-12*ff*nn then return false end
            fj=(-slip*nn+lateral*fl)/determinant lj=(-lateral*ff+slip*fl)/determinant
            local ellipse=math.sqrt((fj/lf)^2+(lj/ll)^2) if ellipse>1 then fj/=ellipse lj/=ellipse end
        elseif lf>0 then fj=math.clamp(-slip/ff,-lf,lf) else lj=math.clamp(-lateral/nn,-ll,ll) end
        if not apply(state,p.forward,wi,fj,true) or not apply(state,p.lateral,wi,lj,true) then return false end
        solved.longitudinal_impulse=fj solved.lateral_impulse=lj
    end
    return M.finite(solved.normal_load)
end
local function project(p,g1,g2,g3,l1,l2,l3)
    -- The matrix is private and fixed for this one solve. Reusing a result
    -- requires numerical equality of EVERY changing projection argument. This
    -- does not skip a contact iteration or relax any convergence tolerance.
    for i=1,2 do
        local entry=p.cache[i]
        if entry and entry[1]==g1 and entry[2]==g2 and entry[3]==g3 and entry[4]==l1 and entry[5]==l2 and entry[6]==l3 then
            return entry[7],entry[8],entry[9]
        end
    end
    local x,y,z,root1,root2,root3=Brake.project(p.k,g1,g2,g3,l1,l2,l3,true,p.root1,p.root2,p.root3) if x==nil then return nil end
    -- These are initialization hints, not cached outputs for different inputs.
    -- They exist only with this step's prepared matrix and are reclassified.
    p.root1,p.root2,p.root3=root1,root2,root3
    local slot=p.cache_slot local entry=p.cache[slot] or {} p.cache[slot]=entry p.cache_slot=3-slot
    entry[1],entry[2],entry[3],entry[4],entry[5],entry[6]=g1,g2,g3,l1,l2,l3 entry[7],entry[8],entry[9]=x,y,z
    return x,y,z
end
local function tangent(state,p,wi,h,j,brake,friction,solved)
    if not valid(state) then return nil end
    solved.normal_impulse=p.normal_only and 0 or j solved.normal_load=solved.normal_impulse/h
    solved.approach_impulse=p.normal_only and j or 0 solved.longitudinal_impulse=0 solved.lateral_impulse=0
    if not p.hit or p.normal_only then
        local before=state[wi] local relative=speed(state,p.axle,wi)
        local impulse=-(relative>=0 and 1 or -1)*math.min(math.abs(relative)/p.axle_mass,brake*h)
        if not apply(state,p.axle,wi,impulse,false) then return nil end return (state[wi]-before)*p.inertia
    end
    local F,L,A=p.forward,p.lateral,p.axle
    local s1,s2,s3,s4,s5,s6,sw=state[1],state[2],state[3],state[4],state[5],state[6],state[wi]
    local fj,lj,bj=project(p,s1*F[1]+s2*F[2]+s3*F[3]+s4*F[4]+s5*F[5]+s6*F[6]+sw*F[7]-F[15],
        s1*L[1]+s2*L[2]+s3*L[3]+s4*L[4]+s5*L[5]+s6*L[6]+sw*L[7]-L[15],
        s1*A[1]+s2*A[2]+s3*A[3]+s4*A[4]+s5*A[5]+s6*A[6]+sw*A[7]-A[15],
        friction.longitudinal_friction*j,friction.lateral_friction*j,brake*h)
    if fj==nil then return nil end
    state[1]+=F[8]*fj+L[8]*lj+A[8]*bj state[2]+=F[9]*fj+L[9]*lj+A[9]*bj state[3]+=F[10]*fj+L[10]*lj+A[10]*bj
    state[4]+=F[11]*fj+L[11]*lj+A[11]*bj state[5]+=F[12]*fj+L[12]*lj+A[12]*bj state[6]+=F[13]*fj+L[13]*lj+A[13]*bj
    state[wi]+=F[14]*fj+L[14]*lj+A[14]*bj
    if not valid(state) then return nil end
    solved.longitudinal_impulse=fj solved.lateral_impulse=lj return bj
end
local function pair(value)
    if type(value)~="table" or value[1]==nil or value[2]==nil then return false end
    for key in value do if key~=1 and key~=2 then return false end end return true
end
local function patch_valid(contact,secondary)
    if type(contact)~="table" or contact.status~="hit" and contact.status~="clear" then return false end
    if secondary and contact.secondary~=nil then return false end
    for key in contact do if type(key)=="number" then return false end end
    if contact.normal_only~=nil and type(contact.normal_only)~="boolean" then return false end
    if contact.normal_softness~=nil and (not M.finite(contact.normal_softness) or contact.normal_softness<0) then return false end
    if contact.normal_floor_delta~=nil and not M.finite(contact.normal_floor_delta) then return false end
    if contact.normal_deflection_limit~=nil and (not M.finite(contact.normal_deflection_limit) or contact.normal_deflection_limit<0) then return false end
    if contact.status=="hit" then
        if not M.vec(contact.point) or not M.vec(contact.surface_velocity,1e5) or not M.basis(contact.normal,contact.forward) then return false end
    end
    return true
end
local function effect()
    return {linear={0,0,0},angular={0,0,0},spin=0,brake=0,normal_linear={0,0,0},normal_angular={0,0,0},solved={}}
end
local function patch_step(state,p,e,wi,h,friction)
    -- Replacing this patch's old responses leaves every other patch and the
    -- shared axle response in the same body-six/rotor-two velocity workspace.
    local nl,na=e.normal_linear,e.normal_angular
    state[1]-=nl[1] state[4]-=na[1] state[2]-=nl[2] state[5]-=na[2] state[3]-=nl[3] state[6]-=na[3]
    local b1,b2,b3,b4,b5,b6=state[1],state[2],state[3],state[4],state[5],state[6]
    local j=normal(state,p,wi) if j==nil then return false end
    nl[1]=state[1]-b1 na[1]=state[4]-b4 nl[2]=state[2]-b2 na[2]=state[5]-b5 nl[3]=state[3]-b3 na[3]=state[6]-b6
    local el,ea=e.linear,e.angular
    state[1]-=el[1] state[4]-=ea[1] state[2]-=el[2] state[5]-=ea[2] state[3]-=el[3] state[6]-=ea[3] state[wi]-=e.spin
    b1,b2,b3,b4,b5,b6=state[1],state[2],state[3],state[4],state[5],state[6] local before_spin=state[wi]
    if not tire(state,p,wi,h,friction,e.solved,j) then return false end
    el[1]=state[1]-b1 ea[1]=state[4]-b4 el[2]=state[2]-b2 ea[2]=state[5]-b5 el[3]=state[3]-b3 ea[3]=state[6]-b6 e.spin=state[wi]-before_spin
    return true
end
local function solve_patches(h,body,wheels,contacts,t,brake,free_axes)
    if not M.valid_body(body) or not pair(wheels) or not M.valid_wheel(wheels[1]) or not M.valid_wheel(wheels[2])
        or not pair(contacts) or not pair(free_axes) or not M.finite(h) or h<=0 or h>.1 or not M.finite(brake) or brake<0 or brake>1
        or type(t)~="table" or type(t.friction)~="table" then return nil end
    for _,name in {"contact_iterations","brake_iterations"} do
        local count=t[name] local maximum=name=="contact_iterations" and 32 or 128
        if not M.finite(count) or count<1 or count>maximum or count%1~=0 then return nil end
    end
    for _,name in {"front_brake_torque","rear_brake_torque"} do
        if not M.finite(t[name]) or t[name]<0 or t[name]>1e6 then return nil end
    end
    for _,name in {"longitudinal_friction","lateral_friction"} do
        if not M.finite(t.friction[name]) or t.friction[name]<0 or t.friction[name]>10 then return nil end
    end
    local groups,effects={},{}
    for i=1,2 do
        local axis=M.unit(free_axes[i]) local contact=contacts[i]
        if not axis or not patch_valid(contact,false) or contact.secondary~=nil and not patch_valid(contact.secondary,true) then return nil end
        -- Terrain patches all refer to the existing wheel. Their prepared axle
        -- rows are unused here: only this fixed mechanical row owns its brake.
        local group={patches={},brake=0,axle=row(body,wheels[i],{0,0,0},M.mul(axis,-1),1,0)}
        group.axle_mass=1/wheels[i].inertia+M.dot(axis,M.tensor(body,axis,true))
        if not M.finite(group.axle_mass) or group.axle_mass<=0 then return nil end
        effects[i]=effect() effects[i].patches={}
        local count=contact.secondary~=nil and 2 or 1
        for k=1,count do
            local p=prepare(body,wheels[i],k==1 and contact or contact.secondary,axis)
            if not p or p.hit and not M.finite(p.normal_mass+p.softness) then return nil end
            group.patches[k]=p effects[i].patches[k]=effect()
        end
        groups[i]=group
    end
    local state={body.linear_velocity[1],body.linear_velocity[2],body.linear_velocity[3],body.angular_velocity[1],body.angular_velocity[2],body.angular_velocity[3],wheels[1].angular_speed,wheels[2].angular_speed}
    local braking=brake>0 and (t.front_brake_torque>0 or t.rear_brake_torque>0)
    local wheel_brake={brake*t.front_brake_torque*h,brake*t.rear_brake_torque*h}
    for iteration=0,(braking and t.brake_iterations or t.contact_iterations)-1 do for order=0,1 do
        local i=(iteration+order)%2+1 local wi=i+6 local group=groups[i]
        local patches=group.patches
        for patch_order=0,#patches-1 do
            local k=(iteration+patch_order)%#patches+1
            if not patch_step(state,patches[k],effects[i].patches[k],wi,h,t.friction) then return nil end
        end
        if braking then
            -- Accumulate one bounded mechanical impulse per wheel. A second
            -- terrain patch changes its reaction, never the available torque.
            local relative=speed(state,group.axle,wi)
            local impulse=math.clamp(group.brake-relative/group.axle_mass,-wheel_brake[i],wheel_brake[i])
            if not apply(state,group.axle,wi,impulse-group.brake,false) then return nil end group.brake=impulse
        end
    end end
    for i=1,2 do
        local e,group=effects[i],groups[i] local solved=e.solved
        solved.normal_impulse=0 solved.normal_load=0 solved.approach_impulse=0 solved.longitudinal_impulse=0 solved.lateral_impulse=0
        for _,patch in e.patches do
            for j=1,3 do
                e.linear[j]+=patch.linear[j] e.angular[j]+=patch.angular[j]
                e.normal_linear[j]+=patch.normal_linear[j] e.normal_angular[j]+=patch.normal_angular[j]
            end
            e.spin+=patch.spin
            for _,name in {"normal_impulse","normal_load","approach_impulse","longitudinal_impulse","lateral_impulse"} do
                solved[name]+=patch.solved[name] if not M.finite(solved[name]) then return nil end
            end
        end
        e.brake=group.brake local axle=group.axle
        for j=1,3 do e.linear[j]+=axle[j+7]*group.brake e.angular[j]+=axle[j+10]*group.brake end
        e.spin+=axle[14]*group.brake
        if not M.vec(e.linear,1e9) or not M.vec(e.angular,1e9) or not M.vec(e.normal_linear,1e9) or not M.vec(e.normal_angular,1e9)
            or not M.finite(e.spin) or not M.finite(e.brake) then return nil end
    end
    local prediction=M.copy(body) prediction.linear_velocity={state[1],state[2],state[3]} prediction.angular_velocity={state[4],state[5],state[6]}
    local next_wheels=M.copy(wheels) for i=1,2 do next_wheels[i].angular_speed=state[i+6] end
    return prediction,next_wheels,effects
end
function S.solve(h,body,wheels,contacts,t,brake,free_axes)
    if type(contacts)=="table" and (type(contacts[1])=="table" and contacts[1].secondary~=nil
        or type(contacts[2])=="table" and contacts[2].secondary~=nil) then return solve_patches(h,body,wheels,contacts,t,brake,free_axes) end
    local state={body.linear_velocity[1],body.linear_velocity[2],body.linear_velocity[3],body.angular_velocity[1],body.angular_velocity[2],body.angular_velocity[3],wheels[1].angular_speed,wheels[2].angular_speed}
    local prepared={prepare(body,wheels[1],contacts[1],free_axes and free_axes[1]),prepare(body,wheels[2],contacts[2],free_axes and free_axes[2])}
    if not prepared[1] or not prepared[2] then return nil end
    local braking=brake>0 and (t.front_brake_torque>0 or t.rear_brake_torque>0)
    local effects={} for i=1,2 do effects[i]={linear={0,0,0},angular={0,0,0},spin=0,brake=0,normal_linear={0,0,0},normal_angular={0,0,0},solved={}} end
    -- Each wheel's brake torque and the friction table are the same in every
    -- iteration; the element loops are written out, each element's arithmetic
    -- unchanged (a braked step runs this body 192 times).
    local friction=t.friction
    local wheel_brake={brake*t.front_brake_torque,brake*t.rear_brake_torque}
    for iteration=0,(braking and t.brake_iterations or t.contact_iterations)-1 do for order=0,1 do
        local i=(iteration+order)%2+1 local wi=i+6 local effect,p=effects[i],prepared[i]
        local j=0
        local separated_normal=braking or p.softness>0 or p.normal_only
        if separated_normal then
            local nl,na=effect.normal_linear,effect.normal_angular
            state[1]-=nl[1] state[4]-=na[1] state[2]-=nl[2] state[5]-=na[2] state[3]-=nl[3] state[6]-=na[3]
            local b1,b2,b3,b4,b5,b6=state[1],state[2],state[3],state[4],state[5],state[6]
            j=normal(state,p,wi) if j==nil then return nil end
            nl[1]=state[1]-b1 na[1]=state[4]-b4 nl[2]=state[2]-b2 na[2]=state[5]-b5 nl[3]=state[3]-b3 na[3]=state[6]-b6
        end
        local el,ea=effect.linear,effect.angular
        state[1]-=el[1] state[4]-=ea[1] state[2]-=el[2] state[5]-=ea[2] state[3]-=el[3] state[6]-=ea[3] state[wi]-=effect.spin
        local b1,b2,b3,b4,b5,b6=state[1],state[2],state[3],state[4],state[5],state[6] local before_spin=state[wi]
        if braking then
            effect.brake=tangent(state,p,wi,h,j,wheel_brake[i],friction,effect.solved)
            if effect.brake==nil then return nil end
        elseif not tire(state,p,wi,h,friction,effect.solved,separated_normal and j or nil) then return nil end
        el[1]=state[1]-b1 ea[1]=state[4]-b4 el[2]=state[2]-b2 ea[2]=state[5]-b5 el[3]=state[3]-b3 ea[3]=state[6]-b6 effect.spin=state[wi]-before_spin
    end end
    local prediction=M.copy(body) prediction.linear_velocity={state[1],state[2],state[3]} prediction.angular_velocity={state[4],state[5],state[6]}
    local next_wheels=M.copy(wheels) for i=1,2 do next_wheels[i].angular_speed=state[i+6] end
    return prediction,next_wheels,effects
end
return S

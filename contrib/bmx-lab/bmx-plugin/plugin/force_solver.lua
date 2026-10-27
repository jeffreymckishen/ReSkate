-- Private fixed-pose workspace. Geometry and inertia are constant throughout a
-- single contact solve; only velocities, rotor speeds and impulse limits vary.
-- No caller tables are mutated and no row survives into the next model step.
local M=require("./force_math")
local Brake=require("./brake")
local S={}
local function valid(state)
    -- Every private workspace component is already a number. Range comparisons
    -- also reject NaN/infinity, without eight generic type-check calls per row.
    for i=1,8 do local x=state[i] if not (x>=-1e5 and x<=1e5) then return false end end return true
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
local function apply(state,r,wi,j,point_impulse)
    if not valid(state) or not M.finite(j) then return false end
    if point_impulse then for k=1,3 do if math.abs(r[k]*j)>1e9 then return false end end end
    for k=1,6 do state[k]+=r[k+7]*j end state[wi]+=r[14]*j return valid(state)
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
    local relative=speed(state,p.normal,wi)
    local j=math.max(0,-relative/(p.normal_mass+p.softness))
    if p.floor_delta~=nil then j=math.max(j,(p.floor_delta-relative)/p.normal_mass) end
    if not apply(state,p.normal,wi,j,true) then return nil end return j
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
    local fj,lj,bj=project(p,speed(state,p.forward,wi),speed(state,p.lateral,wi),speed(state,p.axle,wi),
        friction.longitudinal_friction*j,friction.lateral_friction*j,brake*h)
    if fj==nil then return nil end
    for k=1,6 do state[k]+=p.forward[k+7]*fj+p.lateral[k+7]*lj+p.axle[k+7]*bj end
    state[wi]+=p.forward[14]*fj+p.lateral[14]*lj+p.axle[14]*bj
    if not valid(state) then return nil end
    solved.longitudinal_impulse=fj solved.lateral_impulse=lj return bj
end
function S.solve(h,body,wheels,contacts,t,brake,free_axes)
    local state={body.linear_velocity[1],body.linear_velocity[2],body.linear_velocity[3],body.angular_velocity[1],body.angular_velocity[2],body.angular_velocity[3],wheels[1].angular_speed,wheels[2].angular_speed}
    local prepared={prepare(body,wheels[1],contacts[1],free_axes and free_axes[1]),prepare(body,wheels[2],contacts[2],free_axes and free_axes[2])}
    if not prepared[1] or not prepared[2] then return nil end
    local braking=brake>0 and (t.front_brake_torque>0 or t.rear_brake_torque>0)
    local effects={} for i=1,2 do effects[i]={linear={0,0,0},angular={0,0,0},spin=0,brake=0,normal_linear={0,0,0},normal_angular={0,0,0},solved={}} end
    local before={0,0,0,0,0,0}
    for iteration=0,(braking and t.brake_iterations or t.contact_iterations)-1 do for order=0,1 do
        local i=(iteration+order)%2+1 local wi=i+6 local effect,p=effects[i],prepared[i]
        local j=0
        local separated_normal=braking or p.softness>0 or p.normal_only
        if separated_normal then
            for k=1,3 do state[k]-=effect.normal_linear[k] state[k+3]-=effect.normal_angular[k] end
            for k=1,6 do before[k]=state[k] end
            j=normal(state,p,wi) if j==nil then return nil end
            for k=1,3 do effect.normal_linear[k]=state[k]-before[k] effect.normal_angular[k]=state[k+3]-before[k+3] end
        end
        for k=1,3 do state[k]-=effect.linear[k] state[k+3]-=effect.angular[k] end state[wi]-=effect.spin
        for k=1,6 do before[k]=state[k] end local before_spin=state[wi]
        if braking then
            effect.brake=tangent(state,p,wi,h,j,brake*(i==1 and t.front_brake_torque or t.rear_brake_torque),t.friction,effect.solved)
            if effect.brake==nil then return nil end
        elseif not tire(state,p,wi,h,t.friction,effect.solved,separated_normal and j or nil) then return nil end
        for k=1,3 do effect.linear[k]=state[k]-before[k] effect.angular[k]=state[k+3]-before[k+3] end effect.spin=state[wi]-before_spin
    end end
    local prediction=M.copy(body) prediction.linear_velocity={state[1],state[2],state[3]} prediction.angular_velocity={state[4],state[5],state[6]}
    local next_wheels=M.copy(wheels) for i=1,2 do next_wheels[i].angular_speed=state[i+6] end
    return prediction,next_wheels,effects
end
return S

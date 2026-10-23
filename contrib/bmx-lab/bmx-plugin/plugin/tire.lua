-- bmx_tire_dynamics.h: same constraint arithmetic, immutable body/wheel returns.
local M=require("./force_math")
local Tire={}
function Tire.axle_couple(body,wheel,axle,j)
    local b,w=M.copy(body),M.copy(wheel)
    b.angular_velocity=M.sub(body.angular_velocity,M.tensor(body,M.mul(axle,j),true))
    w.angular_speed+=j/w.inertia
    if not M.valid_body(b) or not M.valid_wheel(w) then return nil,nil end return b,w
end
function Tire.solve(h,body,wheel,contact,controls,parameters)
    controls=controls or {drive_torque=0,brake_torque=0}
    parameters=parameters or {longitudinal_friction=1,lateral_friction=1}
    local drive,brake=controls.drive_torque or 0,controls.brake_torque or 0
    local r={valid=false,touching=false,status=contact.status,normal_impulse=0,normal_load=0,longitudinal_impulse=0,lateral_impulse=0,brake_energy=0}
    local function reject() r.valid=false return r,body,wheel end
    if not M.valid_body(body) or not M.valid_wheel(wheel) or not M.finite(h) or h<0 or h>.1 or
        not M.finite(drive) or math.abs(drive)>1e6 or not M.finite(brake) or brake<0 or brake>1e6 then return reject() end
    for _,key in {"longitudinal_friction","lateral_friction"} do local x=parameters[key] if not M.finite(x) or x<0 or x>10 then return reject() end end
    if contact.status~="hit" and contact.status~="clear" then return reject() end
    local basis=M.basis(contact.normal,contact.forward) if not basis then return reject() end r.basis=basis
    if contact.status=="hit" and (not M.vec(contact.point) or not M.vec(contact.surface_velocity,1e5)) then return reject() end
    r.valid=true r.touching=contact.status=="hit" if h==0 then return r,body,wheel end
    local b,w=Tire.axle_couple(body,wheel,basis.lateral,drive*h) if not b then return reject() end
    local relative=w.angular_speed-M.dot(b.angular_velocity,basis.lateral)
    local axle_mass=1/wheel.inertia+M.dot(basis.lateral,M.tensor(b,basis.lateral,true))
    local j=-(relative>=0 and 1 or -1)*math.min(math.abs(relative)/axle_mass,brake*h)
    r.brake_energy=math.max(0,-(j*relative+.5*j*j*axle_mass))
    b,w=Tire.axle_couple(b,w,basis.lateral,j) if not b then return reject() end
    if contact.status=="clear" then return r,b,w end
    local arm=M.sub(contact.point,body.center_of_mass)
    local velocity=M.sub(M.point_velocity(b,contact.point),contact.surface_velocity)
    local normal_mass=M.dot(basis.normal,M.response(body,arm,basis.normal))
    if not M.finite(normal_mass) or normal_mass<=0 then return reject() end
    r.normal_impulse=math.max(0,-M.dot(velocity,basis.normal)/normal_mass) r.normal_load=r.normal_impulse/h
    if not M.finite(r.normal_impulse) or not M.finite(r.normal_load) then return reject() end
    b=M.apply_impulse(b,contact.point,M.mul(basis.normal,r.normal_impulse)) if not b then return reject() end
    local longitudinal_limit=parameters.longitudinal_friction*r.normal_impulse
    local lateral_limit=parameters.lateral_friction*r.normal_impulse
    if longitudinal_limit>0 or lateral_limit>0 then
        velocity=M.sub(M.point_velocity(b,contact.point),contact.surface_velocity)
        local hub=M.add(contact.point,M.mul(basis.normal,wheel.radius)) local hub_arm=M.sub(hub,body.center_of_mass)
        local hub_velocity=M.sub(M.point_velocity(b,hub),contact.surface_velocity)
        local slip=M.dot(hub_velocity,basis.forward)-w.angular_speed*wheel.radius local lateral=M.dot(velocity,basis.lateral)
        local ff=M.dot(basis.forward,M.response(body,hub_arm,basis.forward))+wheel.radius^2/wheel.inertia
        local ll=M.dot(basis.lateral,M.response(body,arm,basis.lateral))
        local fl=M.dot(basis.forward,M.response(body,arm,basis.lateral,hub_arm))
        if not M.finite(ff) or not M.finite(ll) or not M.finite(fl) or ff<=0 or ll<=0 then return reject() end
        local forward_j,lateral_j=0,0
        if longitudinal_limit>0 and lateral_limit>0 then
            local determinant=ff*ll-fl*fl if not M.finite(determinant) or determinant<=1e-12*ff*ll then return reject() end
            forward_j=(-slip*ll+lateral*fl)/determinant lateral_j=(-lateral*ff+slip*fl)/determinant
            local ellipse=math.sqrt((forward_j/longitudinal_limit)^2+(lateral_j/lateral_limit)^2)
            if ellipse>1 then forward_j/=ellipse lateral_j/=ellipse end
        elseif longitudinal_limit>0 then forward_j=math.clamp(-slip/ff,-longitudinal_limit,longitudinal_limit)
        else lateral_j=math.clamp(-lateral/ll,-lateral_limit,lateral_limit) end
        if not M.finite(forward_j) or not M.finite(lateral_j) then return reject() end
        b=M.apply_impulse(b,hub,M.mul(basis.forward,forward_j)) if not b then return reject() end
        b=M.apply_impulse(b,contact.point,M.mul(basis.lateral,lateral_j)) if not b then return reject() end
        w.angular_speed-=forward_j*wheel.radius/wheel.inertia if not M.valid_wheel(w) then return reject() end
        r.longitudinal_impulse=forward_j r.lateral_impulse=lateral_j
    end
    return r,b,w
end
return Tire

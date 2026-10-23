-- bmx_coupled_brake.h: bounded joint friction/brake projection, not a free-wheel stop.
local M=require("./force_math")
local Tire=require("./tire")
local B={}
local function disk(a,b)
    local function at(multiplier)
        local aa,dd=a[1][1]+multiplier,a[2][2]+multiplier
        local determinant=aa*dd-a[1][2]^2
        if not M.finite(determinant) or aa<=0 or dd<=0 or determinant<=0 then return nil end
        local x={(-dd*b[1]+a[1][2]*b[2])/determinant,(a[1][2]*b[1]-aa*b[2])/determinant}
        return M.finite(x[1]) and M.finite(x[2]) and x or nil
    end
    local function norm(x) return math.sqrt(x[1]^2+x[2]^2) end
    local x=at(0) if not x then return nil end if norm(x)<=1 then return x end
    local low,high=0,math.max(1,norm(b)) local feasible=at(high)
    if not feasible or norm(feasible)>1+1e-12 then return nil end
    for _=1,64 do
        local middle=(low+high)*.5 local trial=at(middle) if not trial then return nil end
        if norm(trial)>1 then low=middle else high=middle feasible=trial end
    end
    return feasible
end
function B.constrained(k,g,limits)
    local a,b={{0,0,0},{0,0,0},{0,0,0}},{0,0,0}
    for i=1,3 do
        if not M.finite(limits[i]) or limits[i]<0 or not M.finite(g[i]) then return nil end
        b[i]=g[i]*limits[i]
        for j=1,3 do if not M.finite(k[i][j]) then return nil end a[i][j]=k[i][j]*limits[i]*limits[j] end
    end
    if limits[3]==0 then a[3][3]=1 b[3]=0 end
    if a[3][3]<=0 or not M.finite(a[3][3]) then return nil end
    local best,winner=0,{0,0,0}
    for mode=-1,1 do
        local free=mode==0 local reduced,rhs={{0,0},{0,0}},{0,0}
        for i=1,2 do
            rhs[i]=b[i]+(free and -a[i][3]*b[3]/a[3][3] or a[i][3]*mode)
            for j=1,2 do reduced[i][j]=a[i][j]-(free and a[i][3]*a[3][j]/a[3][3] or 0) end
        end
        for i=1,2 do if limits[i]==0 then rhs[i]=0 reduced[i][i]=1 reduced[i][3-i]=0 reduced[3-i][i]=0 end end
        local friction=disk(reduced,rhs) if not friction then return nil end
        local candidate={friction[1],friction[2],mode}
        if free then candidate[3]=-(b[3]+a[3][1]*candidate[1]+a[3][2]*candidate[2])/a[3][3] end
        if not M.finite(candidate[3]) or math.abs(candidate[3])>1+1e-12 then continue end
        candidate[3]=math.clamp(candidate[3],-1,1) local objective=0
        for i=1,3 do
            objective+=b[i]*candidate[i]
            for j=1,3 do objective+=.5*candidate[i]*a[i][j]*candidate[j] end
        end
        if not M.finite(objective) then return nil end
        if objective<best then best=objective winner=candidate end
    end
    return {winner[1]*limits[1],winner[2]*limits[2],winner[3]*limits[3]}
end
function B.solve_tangent(h,body,wheel,contact,normal_impulse,brake_torque,parameters)
    local r={valid=false,status=contact.status,touching=false,normal_impulse=0,normal_load=0,longitudinal_impulse=0,lateral_impulse=0,brake_energy=0}
    local function reject() return r,body,wheel,0 end
    if not M.valid_body(body) or not M.valid_wheel(wheel) or not M.finite(h) or h<=0 or h>.1 or
        not M.finite(brake_torque) or brake_torque<0 or brake_torque>1e6 or not M.finite(normal_impulse) or normal_impulse<0 then return reject() end
    for _,key in {"longitudinal_friction","lateral_friction"} do local x=parameters[key] if not M.finite(x) or x<0 or x>10 then return reject() end end
    if contact.status~="hit" and contact.status~="clear" then return reject() end
    local basis=M.basis(contact.normal,contact.forward) if not basis then return reject() end r.basis=basis
    if contact.status=="clear" then
        local result,b,w=Tire.solve(h,body,wheel,contact,{drive_torque=0,brake_torque=brake_torque},parameters)
        return result,b,w,result.valid and (w.angular_speed-wheel.angular_speed)*wheel.inertia or 0
    end
    if not M.vec(contact.point) or not M.vec(contact.surface_velocity,1e5) then return reject() end
    r.normal_impulse=normal_impulse r.normal_load=normal_impulse/h if not M.finite(r.normal_load) then return reject() end
    local arm=M.sub(contact.point,body.center_of_mass)
    local hub=M.add(contact.point,M.mul(basis.normal,wheel.radius)) local hub_arm=M.sub(hub,body.center_of_mass)
    local linear={basis.forward,basis.lateral,{0,0,0}}
    local angular={M.cross(hub_arm,basis.forward),M.cross(arm,basis.lateral),M.mul(basis.lateral,-1)}
    local rotor={-wheel.radius,0,1}
    local hub_relative=M.sub(M.point_velocity(body,hub),contact.surface_velocity)
    local relative=M.sub(M.point_velocity(body,contact.point),contact.surface_velocity)
    local speed={M.dot(hub_relative,basis.forward)-wheel.angular_speed*wheel.radius,
        M.dot(relative,basis.lateral),wheel.angular_speed-M.dot(body.angular_velocity,basis.lateral)}
    local inverse_mass={{0,0,0},{0,0,0},{0,0,0}}
    for i=1,3 do for j=1,3 do
        inverse_mass[i][j]=M.dot(linear[i],linear[j])/body.mass+M.dot(angular[i],M.tensor(body,angular[j],true))+rotor[i]*rotor[j]/wheel.inertia
    end end
    local impulse=B.constrained(inverse_mass,speed,{parameters.longitudinal_friction*normal_impulse,parameters.lateral_friction*normal_impulse,brake_torque*h})
    if not impulse then return reject() end
    local linear_j,angular_j,rotor_j={0,0,0},{0,0,0},0
    for i=1,3 do linear_j=M.add(linear_j,M.mul(linear[i],impulse[i])) angular_j=M.add(angular_j,M.mul(angular[i],impulse[i])) rotor_j+=rotor[i]*impulse[i] end
    local b,w=M.copy(body),M.copy(wheel)
    b.linear_velocity=M.add(b.linear_velocity,M.mul(linear_j,1/body.mass)) b.angular_velocity=M.add(b.angular_velocity,M.tensor(body,angular_j,true))
    w.angular_speed+=rotor_j/wheel.inertia if not M.valid_body(b) or not M.valid_wheel(w) then return reject() end
    r.longitudinal_impulse=impulse[1] r.lateral_impulse=impulse[2] r.touching=true r.valid=true
    return r,b,w,impulse[3]
end
return B

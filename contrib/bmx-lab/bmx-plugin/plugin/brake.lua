-- bmx_coupled_brake.h: bounded joint friction/brake projection, not a free-wheel stop.
local M=require("./force_math")
local Tire=require("./tire")
local B={}
local function neighbor(x,up)
    if x==0 then return math.ldexp(1,-1074) end
    local fraction,exponent=math.frexp(x)
    local bits=not up and fraction==.5 and 54 or 53
    local spacing=math.ldexp(1,math.max(-1074,exponent-bits))
    return up and x+spacing or x-spacing
end
local function accelerated(a,off,d,b1,b2,h,x0,y0,hx,hy,hint)
    local scale=math.max(math.abs(a),math.abs(off),math.abs(d))
    if not M.finite(scale) or scale<1e-100 or scale>1e100 or math.sqrt(hx*hx+hy*hy)>1 then return nil end
    local na,nd,noff=a/scale,d/scale,off/scale
    local norm=math.sqrt(x0*x0+y0*y0)
    if na*nd-noff*noff<=1e-8 or norm>1e100 then return nil end
    local low,high,trial=0,h,0 local x,y=x0,y0 local fx,fy=hx,hy
    local square,cross1,cross2=off*off,off*b1,off*b2
    local seed
    if M.finite(hint) and hint>0 and hint<1 then
        local guess=hint*h if guess>low and guess<high then seed=guess end
    end
    if not seed then
        local rhs_norm=math.sqrt(b1*b1+b2*b2)
        if M.finite(rhs_norm) and rhs_norm>0 then
            local bx,by=b1/rhs_norm,b2/rhs_norm
            local guess=rhs_norm-(a*bx*bx+2*off*bx*by+d*by*by)
            if M.finite(guess) and guess>low and guess<high then seed=guess end
        end
    end
    for probe=1,12 do
        local next_trial
        if probe==1 and seed then
            -- A prior root or Rayleigh estimate is only a starting probe, one
            -- of the same twelve attempts and must pass the actual classifier.
            next_trial=seed
        else
            local aa,dd=a+trial,d+trial local det=aa*dd-square
            local ix,iy=(dd*x-off*y)/det,(aa*y-off*x)/det
            local q=x*ix+y*iy local residual=norm-1
            if not (q>0 and q<math.huge and residual>-math.huge and residual<math.huge) then return nil end
            -- f(alpha)=||x(alpha)||-1, f'=-x'*(A+alpha I)^-1*x/||x||.
            -- This uses the same sqrt classification, including its rounded zero.
            next_trial=trial+residual*norm/q
            -- Rounded stagnation probes the adjacent binary64 number toward
            -- the other endpoint, still spending one of the twelve attempts.
            if next_trial==trial then next_trial=neighbor(trial,trial==low) end
        end
        if not (next_trial>-math.huge and next_trial<math.huge) then return nil end
        if next_trial==low or next_trial==high then return low,high,fx,fy end
        if next_trial<low or next_trial>high then return nil end
        local aa,dd=a+next_trial,d+next_trial local determinant=aa*dd-square
        if not (determinant>0 and determinant<math.huge) or aa<=0 or dd<=0 then return nil end
        local tx,ty=(-dd*b1+cross2)/determinant,(cross1-aa*b2)/determinant
        -- These are internal arithmetic results, already numbers. Retain the
        -- original finite/positive checks without generic Lua function calls.
        if not (tx>-math.huge and tx<math.huge and ty>-math.huge and ty<math.huge) then return nil end
        norm=math.sqrt(tx*tx+ty*ty) if not (norm<math.huge) then return nil end
        if norm>1 then low=next_trial else high=next_trial fx,fy=tx,ty end
        local middle=(low+high)*.5
        if middle==low or middle==high then return low,high,fx,fy end
        trial=next_trial x,y=tx,ty
    end
    -- These were valid classified probes. Preserve their proven bracket for
    -- bounded bisection rather than repeating work from the original endpoints.
    return low,high,fx,fy
end
local function disk(a,off,d,b1,b2,fast,hint)
    local square,cross1,cross2=off*off,off*b1,off*b2
    -- Endpoint expressions are the same as the original at(0)/at(high), in
    -- that order. Internal arithmetic results need no generic type checks.
    local aa,dd=a+0,d+0 local determinant=aa*dd-square
    if not (determinant>0 and determinant<math.huge) or aa<=0 or dd<=0 then return nil end
    local x,y=(-dd*b1+cross2)/determinant,(cross1-aa*b2)/determinant
    if not (x>-math.huge and x<math.huge and y>-math.huge and y<math.huge) then return nil end
    if math.sqrt(x*x+y*y)<=1 then return x,y,0 end
    local low,high=0,math.max(1,math.sqrt(b1*b1+b2*b2))
    aa,dd=a+high,d+high determinant=aa*dd-square
    if not (determinant>0 and determinant<math.huge) or aa<=0 or dd<=0 then return nil end
    local fx,fy=(-dd*b1+cross2)/determinant,(cross1-aa*b2)/determinant
    if not (fx>-math.huge and fx<math.huge and fy>-math.huge and fy<math.huge) or math.sqrt(fx*fx+fy*fy)>1+1e-12 then return nil end
    local refined=false local original_high=high
    if fast then
        -- A strict diagonal one-coordinate objective has an exact interval
        -- solution. The original at0/high invalid-domain checks already ran.
        if off==0 and (b1==0 or b2==0) then return math.clamp(x,-1,1),math.clamp(y,-1,1) end
        local nlow,nhigh,nfx,nfy=accelerated(a,off,d,b1,b2,high,x,y,fx,fy,hint)
        if nlow~=nil then low,high,fx,fy=nlow,nhigh,nfx,nfy refined=true end
        -- Invalid or uncertain Newton probes retain the original bracket.
        -- Valid exhaustion or endpoint stagnation retains a proven refinement.
    end
    for _=1,64 do
        local middle=(low+high)*.5
        if refined and (middle==low or middle==high) then return fx,fy,high/original_high end
        local aa,dd=a+middle,d+middle
        local determinant=aa*dd-square
        -- These are arithmetic results, hence already numbers. The comparisons
        -- preserve the same finite/positive rejection before either division.
        if not (determinant>0 and determinant<math.huge) or aa<=0 or dd<=0 then return nil end
        local tx,ty=(-dd*b1+cross2)/determinant,(cross1-aa*b2)/determinant
        if not (tx>-math.huge and tx<math.huge and ty>-math.huge and ty<math.huge) then return nil end
        if math.sqrt(tx*tx+ty*ty)>1 then low=middle else high=middle fx,fy=tx,ty end
    end
    return fx,fy,fast and high/original_high or nil
end
-- k is an immutable, validated row-major matrix. Only velocity and limits vary
-- during a fixed-pose contact solve. Scalars avoid allocating search iterates.
function B.project(k,g1,g2,g3,l1,l2,l3,fast,hint1,hint2,hint3)
    if type(g1)~="number" or not (g1>-math.huge and g1<math.huge) or
        type(g2)~="number" or not (g2>-math.huge and g2<math.huge) or
        type(g3)~="number" or not (g3>-math.huge and g3<math.huge) or
        type(l1)~="number" or not (l1>-math.huge and l1<math.huge) or
        type(l2)~="number" or not (l2>-math.huge and l2<math.huge) or
        type(l3)~="number" or not (l3>-math.huge and l3<math.huge) then return nil end
    if l1<0 or l2<0 or l3<0 then return nil end
    local a11,a12,a13=k[1]*l1*l1,k[2]*l1*l2,k[3]*l1*l3
    local a21,a22,a23=k[4]*l2*l1,k[5]*l2*l2,k[6]*l2*l3
    local a31,a32,a33=k[7]*l3*l1,k[8]*l3*l2,k[9]*l3*l3
    local b1,b2,b3=g1*l1,g2*l2,g3*l3
    if l3==0 then a33=1 b3=0 end
    if a33<=0 or not M.finite(a33) then return nil end
    local best,wx,wy,wz=0,0,0,0 local root1,root2,root3
    for mode=-1,1 do
        local free=mode==0
        local aa=a11-(free and a13*a31/a33 or 0)
        local off=a12-(free and a13*a32/a33 or 0)
        local dd=a22-(free and a23*a32/a33 or 0)
        local r1=b1+(free and -a13*b3/a33 or a13*mode)
        local r2=b2+(free and -a23*b3/a33 or a23*mode)
        if l1==0 then r1=0 aa=1 off=0 end
        if l2==0 then r2=0 dd=1 off=0 end
        local hint if mode==-1 then hint=hint1 elseif mode==0 then hint=hint2 else hint=hint3 end
        -- disk's first test, the same expressions in the same order: most braked
        -- projections end there, with the alpha-zero point inside the unit disk.
        -- Any other case goes to disk, which repeats that test and goes on.
        local x,y,root
        do
            local square,cross1,cross2=off*off,off*r1,off*r2
            local ia,id=aa+0,dd+0 local determinant=ia*id-square
            if determinant>0 and determinant<math.huge and ia>0 and id>0 then
                local ux,uy=(-id*r1+cross2)/determinant,(cross1-ia*r2)/determinant
                if ux>-math.huge and ux<math.huge and uy>-math.huge and uy<math.huge and math.sqrt(ux*ux+uy*uy)<=1 then
                    x,y,root=ux,uy,0
                end
            end
        end
        if x==nil then x,y,root=disk(aa,off,dd,r1,r2,fast,hint) if x==nil then return nil end end
        if mode==-1 then root1=root elseif mode==0 then root2=root else root3=root end
        local z=free and -(b3+a31*x+a32*y)/a33 or mode
        -- M.finite written out (z and objective are always numbers here).
        if not (type(z)=="number" and z==z and math.abs(z)<math.huge) or math.abs(z)>1+1e-12 then continue end z=math.clamp(z,-1,1)
        -- Preserve the original row-wise work summation, including nonsymmetric
        -- last-bit matrix values; zero remains the feasible initial winner.
        local objective=b1*x
        objective+=.5*x*a11*x objective+=.5*x*a12*y objective+=.5*x*a13*z
        objective+=b2*y objective+=.5*y*a21*x objective+=.5*y*a22*y objective+=.5*y*a23*z
        objective+=b3*z objective+=.5*z*a31*x objective+=.5*z*a32*y objective+=.5*z*a33*z
        if not (type(objective)=="number" and objective==objective and math.abs(objective)<math.huge) then return nil end
        if objective<best then best=objective wx,wy,wz=x,y,z end
    end
    return wx*l1,wy*l2,wz*l3,root1,root2,root3
end
function B.constrained(k,g,limits)
    local matrix={}
    for i=1,3 do for j=1,3 do if not M.finite(k[i][j]) then return nil end matrix[(i-1)*3+j]=k[i][j] end end
    local x,y,z=B.project(matrix,g[1],g[2],g[3],limits[1],limits[2],limits[3])
    return x~=nil and {x,y,z} or nil
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

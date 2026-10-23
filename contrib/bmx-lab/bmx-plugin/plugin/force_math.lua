-- Double-number array arithmetic for the portable force policy. No native writes.
local M = {}
function M.finite(x) return type(x)=="number" and x==x and math.abs(x)<math.huge end
function M.vec(v,bound)
    if type(v)~="table" then return false end
    for i=1,3 do if not M.finite(v[i]) or math.abs(v[i])>(bound or 1e6) then return false end end
    return true
end
function M.copy(v)
    if type(v)~="table" then return v end
    local out={} for k,x in v do out[k]=M.copy(x) end return out
end
function M.add(a,b) return {a[1]+b[1],a[2]+b[2],a[3]+b[3]} end
function M.sub(a,b) return {a[1]-b[1],a[2]-b[2],a[3]-b[3]} end
function M.mul(a,s) return {a[1]*s,a[2]*s,a[3]*s} end
function M.dot(a,b) return a[1]*b[1]+a[2]*b[2]+a[3]*b[3] end
function M.cross(a,b) return {a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1]} end
function M.length(a) return math.sqrt(M.dot(a,a)) end
function M.unit(a)
    if not M.vec(a,1e9) then return nil end
    local n=M.length(a) if not M.finite(n) or n<1e-9 then return nil end return M.mul(a,1/n)
end
function M.normalized(q)
    local n=0 for i=1,4 do n+=q[i]*q[i] end n=math.sqrt(n)
    return {q[1]/n,q[2]/n,q[3]/n,q[4]/n}
end
function M.turn(q,v)
    local axis={q[1],q[2],q[3]} local twice=M.mul(M.cross(axis,v),2)
    return M.add(v,M.add(M.mul(twice,q[4]),M.cross(axis,twice)))
end
function M.tensor(b,v,inverse)
    local q=M.normalized(b.orientation)
    local local_v=M.turn({-q[1],-q[2],-q[3],q[4]},v)
    for i=1,3 do local_v[i]*=inverse and 1/b.inertia_body[i] or b.inertia_body[i] end
    return M.turn(q,local_v)
end
function M.around(v,axis,angle)
    local c,s=math.cos(angle),math.sin(angle)
    return M.add(M.add(M.mul(v,c),M.mul(M.cross(axis,v),s)),M.mul(axis,M.dot(axis,v)*(1-c)))
end
function M.limited(v,cap) local n=M.length(v) return n>cap and M.mul(v,cap/n) or v end
function M.positive(x) return M.finite(x) and x>=1e-9 and x<=1e9 end
function M.valid_body(b)
    if type(b)~="table" or not M.positive(b.mass) or not M.vec(b.inertia_body,1e9) or
        not M.vec(b.center_of_mass) or not M.vec(b.linear_velocity,1e5) or not M.vec(b.angular_velocity,1e5) or type(b.orientation)~="table" then return false end
    for i=1,3 do if not M.positive(b.inertia_body[i]) then return false end end
    local norm=0 for i=1,4 do if not M.finite(b.orientation[i]) then return false end norm+=b.orientation[i]^2 end
    return M.finite(norm) and math.abs(norm-1)<=.001
end
function M.valid_wheel(w)
    return type(w)=="table" and M.positive(w.inertia) and M.finite(w.radius) and w.radius>=1e-6 and w.radius<=10 and
        M.finite(w.angular_speed) and math.abs(w.angular_speed)<=1e5
end
function M.point_velocity(b,p) return M.add(b.linear_velocity,M.cross(b.angular_velocity,M.sub(p,b.center_of_mass))) end
function M.basis(normal,forward)
    local n=M.unit(normal) if not n or not M.vec(forward,1e9) then return nil end
    local f=M.unit(M.sub(forward,M.mul(n,M.dot(forward,n)))) if not f then return nil end
    local l=M.unit(M.cross(n,f)) if not l then return nil end return {normal=n,forward=M.cross(l,n),lateral=l}
end
function M.response(b,arm,impulse,at_arm)
    return M.add(M.mul(impulse,1/b.mass),M.cross(M.tensor(b,M.cross(arm,impulse),true),at_arm or arm))
end
function M.apply_impulse(b,p,j)
    if not M.valid_body(b) or not M.vec(p) or not M.vec(j,1e9) then return nil end
    local out=M.copy(b) out.linear_velocity=M.add(b.linear_velocity,M.mul(j,1/b.mass))
    out.angular_velocity=M.add(b.angular_velocity,M.tensor(b,M.cross(M.sub(p,b.center_of_mass),j),true))
    return M.valid_body(out) and out or nil
end
return M

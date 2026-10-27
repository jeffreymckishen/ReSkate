-- Double-number array arithmetic for the portable force policy. No native writes.
local M = {}
function M.finite(x) return type(x)=="number" and x==x and math.abs(x)<math.huge end
function M.vec(v,bound)
    if type(v)~="table" then return false end
    -- M.finite written out: vec runs hundreds of times a step.
    for i=1,3 do
        local x=v[i]
        if not (type(x)=="number" and x==x and math.abs(x)<math.huge) or math.abs(x)>(bound or 1e6) then return false end
    end
    return true
end
function M.copy(v)
    if type(v)~="table" then return v end
    -- Scalars are stored directly rather than through a call each.
    local out={} for k,x in v do if type(x)=="table" then out[k]=M.copy(x) else out[k]=x end end return out
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
-- turn and tensor do their arithmetic in scalars: each operation and its
-- order is that of the table form, v+(twice*q[4]+axis x twice) with
-- twice=(axis x v)*2, so the results are the same numbers, made with one
-- result table instead of seven per rotation (they run in every step).
local function turn3(q1,q2,q3,q4,v1,v2,v3)
    local t1,t2,t3=(q2*v3-q3*v2)*2,(q3*v1-q1*v3)*2,(q1*v2-q2*v1)*2
    return v1+(t1*q4+(q2*t3-q3*t2)),v2+(t2*q4+(q3*t1-q1*t3)),v3+(t3*q4+(q1*t2-q2*t1))
end
function M.turn(q,v)
    return {turn3(q[1],q[2],q[3],q[4],v[1],v[2],v[3])}
end
-- turn's arithmetic on scalars, for a caller that keeps its points in scalars:
-- the same numbers, and no table at all.
M.turn3=turn3
function M.tensor(b,v,inverse)
    local o=b.orientation
    local n=0 for i=1,4 do n+=o[i]*o[i] end n=math.sqrt(n)
    local q1,q2,q3,q4=o[1]/n,o[2]/n,o[3]/n,o[4]/n
    local l1,l2,l3=turn3(-q1,-q2,-q3,q4,v[1],v[2],v[3])
    local inertia=b.inertia_body
    l1*=inverse and 1/inertia[1] or inertia[1]
    l2*=inverse and 1/inertia[2] or inertia[2]
    l3*=inverse and 1/inertia[3] or inertia[3]
    return {turn3(q1,q2,q3,q4,l1,l2,l3)}
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

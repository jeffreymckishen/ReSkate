-- Pure forecast of accepted commands not yet visible in the native body sample.
-- A command from sample S acts over S+1 -> S+2, so only age 1 acts over the
-- forecast interval. Age 0 waits for the next interval; age >=2 is already in
-- the measured sample. These copies do not grant native command authority.
local M=require("./force_math")
local I={VISIBLE_STEPS=2}
local function plain(value) return type(value)=="table" and getmetatable(value)==nil end
local function array_size(value,limit)
    if not plain(value) then return nil end
    local count,last=0,0
    for key in value do
        if not M.finite(key) or key%1~=0 or key<1 or key>limit then return nil end
        count+=1;last=math.max(last,key)
    end
    return count==last and count or nil
end
local function vector(value,bound)
    return array_size(value,3)==3 and M.vec(value,bound)
end
local function clone(value,seen,budget,depth)
    local kind=type(value)
    if kind=="number" then return value,M.finite(value) end
    if kind=="boolean" or kind=="string" or value==nil then return value,true end
    if not plain(value) or seen[value] or depth>=16 then return nil,false end
    seen[value]=true
    local out={}
    for key,item in value do
        budget[1]+=1
        if budget[1]>4096 or type(key)~="string" and
            (not M.finite(key) or key%1~=0 or key<1 or key>4096) then return nil,false end
        local copied,ok=clone(item,seen,budget,depth+1)
        if not ok then return nil,false end
        out[key]=copied
    end
    seen[value]=nil
    return out,true
end
local function copy(value) return clone(value,{},{0},0) end
local function rotate(q,w,h)
    local rate=M.length(w)
    if rate*h<1e-12 then return M.normalized(q) end
    local s=math.sin(rate*h/2)/rate
    local dx,dy,dz,dw=w[1]*s,w[2]*s,w[3]*s,math.cos(rate*h/2)
    return M.normalized({
        dw*q[1]+dx*q[4]+dy*q[3]-dz*q[2],
        dw*q[2]-dx*q[3]+dy*q[4]+dz*q[1],
        dw*q[3]+dx*q[2]-dy*q[1]+dz*q[4],
        dw*q[4]-dx*q[1]-dy*q[2]-dz*q[3]})
end
local function valid_body(b)
    return M.valid_body(b) and vector(b.center_of_mass) and vector(b.linear_velocity,1e5)
        and vector(b.angular_velocity,1e5) and vector(b.inertia_body,1e9) and array_size(b.orientation,4)==4
end
local function valid_samples(samples)
    local count=array_size(samples,8)
    if count==nil then return false end
    for _,sample in ipairs(samples) do
        local contact=plain(sample) and sample.contact
        if not plain(contact) then return false end
        if contact.status=="hit" then
            if not M.finite(sample.separation) or not vector(contact.point)
                or not vector(contact.normal,2) or math.abs(M.length(contact.normal)-1)>.001
                or not vector(contact.surface_velocity,50) or not vector(contact.forward)
                or not M.basis(contact.normal,contact.forward) then return false end
        elseif contact.status~="clear" then return false end
    end
    return true
end
-- inflight is a dense list of accepted {age,force,torque,impulse?,impulse_id?}.
-- Ages are exact bounded serial differences. Only one accepted command may have
-- a given active age. A present impulse and its positive uint32 ID are paired;
-- the same event cannot appear in two accepted commands. Even ignored ages are
-- validated. No missing force, torque or contact fact is replaced by zero.
-- Returns fresh mutable body and contact tables, or nil/reason; inputs stay intact.
-- Optional hit wheel_center/wheel_radius must describe the measured gravity ray.
-- Their rigid forecast retains a consistent ray/plane/gap tuple. Without this
-- pair, legacy point prediction remains available but is explicitly unsuitable
-- for geometry-dependent approach braking (forecast_geometry_unavailable=true).
function I.fold(h,gravity,inflight,body,samples)
    if not M.finite(h) or h<=0 or h>.1 or not vector(gravity) then return nil,"fold input invalid" end
    local b,body_ok=copy(body)
    local out,samples_ok=copy(samples)
    -- The closed plain-table command schema below is read synchronously, without
    -- callbacks or yields. No command reference escapes in the forecast.
    local commands=inflight
    if not body_ok or not valid_body(b) then return nil,"fold body invalid" end
    if not samples_ok or not valid_samples(out) then return nil,"fold contact invalid" end
    if array_size(commands,64)==nil then return nil,"fold command invalid" end
    local active,events={},{}
    for _,command in ipairs(commands) do
        if not plain(command) then return nil,"fold command invalid" end
        for key in command do
            if key~="age" and key~="force" and key~="torque" and key~="impulse" and key~="impulse_id" then
                return nil,"fold command invalid"
            end
        end
        if not M.finite(command.age) or command.age%1~=0 or command.age<0 or command.age>64
            or not vector(command.force,1e5) or not vector(command.torque,1e5) then return nil,"fold command invalid" end
        if command.impulse~=nil then
            local id=command.impulse_id
            if not vector(command.impulse,1e5) or not M.finite(id) or id%1~=0 or id<1 or id>4294967295
                or events[id] then return nil,"fold command invalid" end
            events[id]=true
        elseif command.impulse_id~=nil then return nil,"fold command invalid" end
        if command.age<I.VISIBLE_STEPS then
            if active[command.age] then return nil,"fold command invalid" end
            active[command.age]=command
        end
    end
    local command=active[1]
    local force,torque={0,0,0},{0,0,0}
    if command then force,torque=command.force,command.torque end
    local v=M.add(b.linear_velocity,M.mul(M.add(M.mul(force,1/b.mass),gravity),h))
    -- An accepted impulse changes velocity once by J/m, not by J*h/m. It acts
    -- in the same interval as that command's force, before forecasting contacts.
    if command and command.impulse then v=M.add(v,M.mul(command.impulse,1/b.mass)) end
    local w=M.add(b.angular_velocity,M.tensor(b,M.mul(torque,h),true))
    local old_center,old_orientation=b.center_of_mass,M.normalized(b.orientation)
    b.linear_velocity,b.angular_velocity=v,w
    b.center_of_mass=M.add(b.center_of_mass,M.mul(v,h))
    b.orientation=rotate(b.orientation,w,h)
    if not valid_body(b) then return nil,"fold body invalid" end
    local down=M.unit(gravity)
    local inverse={-old_orientation[1],-old_orientation[2],-old_orientation[3],old_orientation[4]}
    for _,sample in ipairs(out) do
        local contact=sample.contact
        if contact.status=="hit" then
            local center,radius=sample.wheel_center,sample.wheel_radius
            if center~=nil or radius~=nil then
                -- This optional pair is authored wheel geometry attached to a
                -- measured gravity ray. It grants no native contact authority.
                if not vector(center) or not M.finite(radius) or radius<1e-6 or radius>10 or not down then
                    return nil,"fold contact geometry invalid"
                end
                local dn=M.dot(down,contact.normal)
                local gap=M.dot(M.sub(center,contact.point),contact.normal)
                -- Native ray coordinates are single precision; allow their
                -- rounding error without accepting a displaced near-origin ray.
                local tolerance=1e-5+1e-7*math.max(M.length(center),M.length(contact.point))
                if dn>=-1e-6 or math.abs(gap-radius-sample.separation)>tolerance
                    or M.length(M.sub(M.add(center,M.mul(down,gap/-dn)),contact.point))>tolerance then
                    return nil,"fold contact geometry invalid"
                end
                local local_center=M.turn(inverse,M.sub(center,old_center))
                local next_center=M.add(b.center_of_mass,M.turn(b.orientation,local_center))
                local plane_point=M.add(contact.point,M.mul(contact.surface_velocity,h))
                local next_gap=M.dot(M.sub(next_center,plane_point),contact.normal)
                sample.wheel_center=next_center
                sample.separation=next_gap-radius
                contact.point=M.add(next_center,M.mul(down,next_gap/-dn))
                sample.forecast_geometry_unavailable=false
            else
                -- Legacy generic samples lack the hub/radius needed to move a
                -- gravity ray under rotation. Keep their existing prediction,
                -- but never let it masquerade as exact approach geometry.
                local point_v=M.add(v,M.cross(w,M.sub(contact.point,old_center)))
                sample.separation=sample.separation+M.dot(M.sub(point_v,contact.surface_velocity),contact.normal)*h
                contact.point=M.add(contact.point,M.mul(M.sub(point_v,M.mul(contact.normal,M.dot(point_v,contact.normal))),h))
                sample.forecast_geometry_unavailable=true
            end
        end
    end
    -- Ride derives this tangent from the bike heading, not from the surface.
    -- Keep it in the forecast body's frame while retaining each measured normal;
    -- stale tangents otherwise look like front steering and rotate both tire axes.
    local forward=M.turn(b.orientation,{0,0,1})
    for _,sample in ipairs(out) do
        local contact=sample.contact
        if contact.status=="hit" then
            local basis=M.basis(contact.normal,forward)
            if not basis then return nil,"fold contact heading invalid" end
            contact.forward=basis.forward
        end
    end
    -- Immutable normals/surface motion were validated before the forecast.
    -- Only changed fields need rechecking; overflow can still invalidate a
    -- contact even when the predicted body remains within its own bounds.
    for _,sample in ipairs(out) do
        local contact=sample.contact
        if contact.status=="hit" and (not M.finite(sample.separation) or not vector(contact.point)
            or not vector(contact.forward) or sample.wheel_center~=nil and not vector(sample.wheel_center)) then
            return nil,"fold contact invalid"
        end
    end
    return b,out
end
return table.freeze(I)

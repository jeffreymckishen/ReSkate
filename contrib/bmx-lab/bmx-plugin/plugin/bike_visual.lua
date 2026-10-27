-- Actual bike part transforms in Lua. Visual placement follows measured body
-- pose; it does not drive that body or attach the rider.
local M = require("./force_math")
local G = require("./bike_geometry")
local V = {}
local function rotation(q)
    if type(q)~="table" then return nil end
    local n=0
    for i=1,4 do if not M.finite(q[i]) then return nil end n+=q[i]^2 end
    if math.abs(n-1)>.0001 then return nil end
    return M.normalized(q)
end
local function rotate(p,axis,angle,pivot)
    pivot=pivot or {0,0,0}
    local v=M.sub(p,pivot)
    local a,b=axis%3+1,(axis+1)%3+1
    local x,y=v[a],v[b]
    v[a],v[b]=x*math.cos(angle)-y*math.sin(angle),x*math.sin(angle)+y*math.cos(angle)
    return M.add(v,pivot)
end
local function steering(p,angle)
    return M.add(M.around(M.sub(p,G.steering_pivot),M.unit(G.steering_axis),angle),G.steering_pivot)
end
-- A part-local point after the pose and before the body rotation q.
local function posed_point(p,part,pose)
    if part==3 then p=rotate(p,1,pose.rear_wheel_phase,G.rear_axle) end
    if part==4 then p=rotate(p,1,pose.front_wheel_phase,G.front_axle) end
    if part==5 then p=rotate(p,1,pose.crank_phase,G.bottom_bracket) end
    if part==7 or part==8 then
        local spindle=G.pedals[part-6]
        p=M.add(p,M.sub(rotate(spindle,1,pose.crank_phase,G.bottom_bracket),spindle))
    end
    -- A barspin turns the whole front end (fork, front wheel and bars) about the head tube, as
    -- steering does; turning the bars alone would spin them off the fork.
    if part==2 or part==4 or part==6 then p=steering(p,pose.steer+pose.barspin)
    else p=steering(p,pose.tailwhip) end
    p=rotate(p,1,pose.movement_bike_pitch,G.steering_pivot)
    p=rotate(p,3,pose.movement_bike_roll,G.steering_pivot)
    return p
end
local function local_point(p,part,pose,q) return M.turn(q,posed_point(p,part,pose)) end
function V.neutral()
    return {steer=0,front_wheel_phase=0,rear_wheel_phase=0,crank_phase=0,
        barspin=0,tailwhip=0,movement_bike_pitch=0,movement_bike_roll=0}
end
-- Without a pose (the measured follow), everything before the body rotation is
-- the same each time: the neutral pose's posed origin and unit axes of every
-- part, computed once by the same arithmetic (G is fixed module data). Only
-- the rotation by the measured q remains per sample, so the matrices are the
-- same numbers without the 32 posed points a sample (S1 profile).
local neutral_points
local function neutral_posed()
    if not neutral_points then
        local pose,points=V.neutral(),{}
        for part=1,8 do
            local row={posed_point({0,0,0},part,pose)}
            for axis=1,3 do
                local basis={0,0,0} basis[axis]=1
                row[axis+1]=posed_point(basis,part,pose)
            end
            points[part]=row
        end
        neutral_points=points
    end
    return neutral_points
end
function V.matrices(root,orientation,pose)
    if not M.vec(root,999990) then return nil,"invalid visual root" end
    local q=rotation(orientation)
    if not q then return nil,"invalid measured rotation" end
    local posed=pose==nil and neutral_posed() or nil
    pose=pose or V.neutral()
    for key in V.neutral() do if not M.finite(pose[key]) then return nil,"invalid articulation" end end
    local out={}
    for part=1,8 do
        local origin=posed and M.turn(q,posed[part][1]) or local_point({0,0,0},part,pose,q)
        local m=table.create(16,0) m[16]=1
        for axis=1,3 do
            local basis={0,0,0} basis[axis]=1
            basis=M.sub(posed and M.turn(q,posed[part][axis+1]) or local_point(basis,part,pose,q),origin)
            for row=1,3 do m[(axis-1)*4+row]=basis[row] end
        end
        local at=M.add(root,origin)
        for row=1,3 do m[12+row]=at[row] end
        out[part]=m
    end
    return out
end
function V.from_sample(sample,pose)
    local q=rotation(sample.rotation)
    if not q then return nil,"invalid measured rotation" end
    local p=sample.position
    local root=M.sub({p.x,p.y,p.z},M.turn(q,G.com))
    return V.matrices(root,q,pose)
end
function V.definition(root,orientation)
    local q=rotation(orientation)
    if not q or not M.vec(root,99900) then return nil end
    local at=M.add(root,M.turn(q,G.com))
    local v=vector.create
    local d={mass=G.mass,inertia=v(unpack(G.inertia)),position=v(unpack(at)),rotation=q,capsules={}}
    for i,c in G.capsules do
        d.capsules[i]={a=v(unpack(M.sub(c.a,G.com))),b=v(unpack(M.sub(c.b,G.com))),radius=c.radius}
    end
    return d
end
return V

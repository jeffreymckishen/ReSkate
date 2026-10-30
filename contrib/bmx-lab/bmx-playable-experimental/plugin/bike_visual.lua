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
-- A part is posed in scalars. Each operation, and its order, is that of the
-- table forms these replaced (rotate's M.sub, turn and M.add about a pivot;
-- steering's M.around about the unit steering axis; M.turn by q), and each
-- angle's sine and cosine is taken once a sample where they took it again for
-- every point, so every matrix is the same numbers, made without the 25 or so
-- tables a posed point took, 32 points a sample. A ride passes its pose on
-- every sample: posed by tables, that cost 80 us a sample in the runner,
-- against 15 for the neutral pose, which cached its posed points; in scalars
-- either costs 16.
local turn3=M.turn3
-- The unit steering axis, as steering computed it on every call.
local AXIS=M.unit(G.steering_axis)
-- rotate(p,1,angle,c): about +X through c, y and z turned; co and si are the
-- angle's cosine and sine.
local function about_x(x,y,z,co,si,c)
    local v1,v2,v3=x-c[1],y-c[2],z-c[3]
    v2,v3=v2*co-v3*si,v2*si+v3*co
    return v1+c[1],v2+c[2],v3+c[3]
end
-- rotate(p,3,angle,c): about +Z through c, x and y turned.
local function about_z(x,y,z,co,si,c)
    local v1,v2,v3=x-c[1],y-c[2],z-c[3]
    v1,v2=v1*co-v2*si,v1*si+v2*co
    return v1+c[1],v2+c[2],v3+c[3]
end
-- steering(p,angle): M.around about the steering axis through its pivot.
local function steered(x,y,z,co,si)
    local c0=G.steering_pivot
    local v1,v2,v3=x-c0[1],y-c0[2],z-c0[3]
    local k1,k2,k3=AXIS[1],AXIS[2],AXIS[3]
    local e=(k1*v1+k2*v2+k3*v3)*(1-co)
    return v1*co+(k2*v3-k3*v2)*si+k1*e+c0[1],v2*co+(k3*v1-k1*v3)*si+k2*e+c0[2],
        v3*co+(k1*v2-k2*v1)*si+k3*e+c0[3]
end
-- One pose's cosines and sines, and each pedal's offset as its spindle turns
-- with the cranks, set by set_pose before any point of that pose is posed.
local rear_c,rear_s,front_c,front_s,crank_c,crank_s,bars_c,bars_s,whip_c,whip_s,pitch_c,pitch_s,roll_c,roll_s
local pedal_offsets={{0,0,0},{0,0,0}}
local function set_pose(pose)
    rear_c,rear_s=math.cos(pose.rear_wheel_phase),math.sin(pose.rear_wheel_phase)
    front_c,front_s=math.cos(pose.front_wheel_phase),math.sin(pose.front_wheel_phase)
    crank_c,crank_s=math.cos(pose.crank_phase),math.sin(pose.crank_phase)
    local bars=pose.steer+pose.barspin
    bars_c,bars_s=math.cos(bars),math.sin(bars)
    whip_c,whip_s=math.cos(pose.tailwhip),math.sin(pose.tailwhip)
    pitch_c,pitch_s=math.cos(pose.movement_bike_pitch),math.sin(pose.movement_bike_pitch)
    roll_c,roll_s=math.cos(pose.movement_bike_roll),math.sin(pose.movement_bike_roll)
    for i=1,2 do
        local spindle,offset=G.pedals[i],pedal_offsets[i]
        local s1,s2,s3=about_x(spindle[1],spindle[2],spindle[3],crank_c,crank_s,G.bottom_bracket)
        offset[1],offset[2],offset[3]=s1-spindle[1],s2-spindle[2],s3-spindle[3]
    end
end
-- A part-local point after the pose set_pose was given, before the body rotation q.
local function posed_point(part,x,y,z)
    if part==3 then x,y,z=about_x(x,y,z,rear_c,rear_s,G.rear_axle) end
    if part==4 then x,y,z=about_x(x,y,z,front_c,front_s,G.front_axle) end
    if part==5 then x,y,z=about_x(x,y,z,crank_c,crank_s,G.bottom_bracket) end
    if part==7 or part==8 then
        local offset=pedal_offsets[part-6]
        x,y,z=x+offset[1],y+offset[2],z+offset[3]
    end
    -- A barspin turns the whole front end (fork, front wheel and bars) about the head tube, as
    -- steering does; turning the bars alone would spin them off the fork.
    if part==2 or part==4 or part==6 then x,y,z=steered(x,y,z,bars_c,bars_s)
    else x,y,z=steered(x,y,z,whip_c,whip_s) end
    x,y,z=about_x(x,y,z,pitch_c,pitch_s,G.steering_pivot)
    return about_z(x,y,z,roll_c,roll_s,G.steering_pivot)
end
local POSE_KEYS={"steer","front_wheel_phase","rear_wheel_phase","crank_phase",
    "barspin","tailwhip","movement_bike_pitch","movement_bike_roll"}
function V.neutral()
    return {steer=0,front_wheel_phase=0,rear_wheel_phase=0,crank_phase=0,
        barspin=0,tailwhip=0,movement_bike_pitch=0,movement_bike_roll=0}
end
local NEUTRAL=table.freeze(V.neutral())
-- Whether pose is an articulation matrices accepts: a table with every field finite.
function V.valid_pose(pose)
    if type(pose)~="table" then return false end
    for _,key in POSE_KEYS do if not M.finite(pose[key]) then return false end end
    return true
end
function V.matrices(root,orientation,pose)
    if not M.vec(root,999990) then return nil,"invalid visual root" end
    local q=rotation(orientation)
    if not q then return nil,"invalid measured rotation" end
    pose=pose or NEUTRAL
    if not V.valid_pose(pose) then return nil,"invalid articulation" end
    set_pose(pose)
    local q1,q2,q3,q4=q[1],q[2],q[3],q[4]
    local out={}
    for part=1,8 do
        local o1,o2,o3=turn3(q1,q2,q3,q4,posed_point(part,0,0,0))
        local m=table.create(16,0) m[16]=1
        -- Each unit axis, posed and turned, less the posed origin.
        local b1,b2,b3=turn3(q1,q2,q3,q4,posed_point(part,1,0,0))
        m[1],m[2],m[3]=b1-o1,b2-o2,b3-o3
        b1,b2,b3=turn3(q1,q2,q3,q4,posed_point(part,0,1,0))
        m[5],m[6],m[7]=b1-o1,b2-o2,b3-o3
        b1,b2,b3=turn3(q1,q2,q3,q4,posed_point(part,0,0,1))
        m[9],m[10],m[11]=b1-o1,b2-o2,b3-o3
        m[13],m[14],m[15]=root[1]+o1,root[2]+o2,root[3]+o3
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
    -- Wheel support is solved from the measured hub rays. The two tyre
    -- spheres would add a second collision response at a curb face before
    -- those vertical rays can see its top. Keep only frame and rider solids.
    -- Leave G.capsules intact: mounted_pose also uses its saddle metadata.
    for i=3,#G.capsules do
        local c=G.capsules[i]
        d.capsules[#d.capsules+1]={a=v(unpack(M.sub(c.a,G.com))),b=v(unpack(M.sub(c.b,G.com))),radius=c.radius}
    end
    return d
end
return V

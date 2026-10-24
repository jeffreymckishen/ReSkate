local A=require("./rider_alignment")
local assertions,cases=0,0
local function check(x,reason) assertions=assertions+1 assert(x,reason or "check failed") end
local function near(a,b,e) check(math.abs(a-b)<(e or 1e-7),tostring(a).." != "..tostring(b)) end
local function vnear(a,b,e) for i=1,3 do near(a[i],b[i],e) end end
local function qnear(a,b)
    local d=0 for i=1,4 do d=d+a[i]*b[i] end near(math.abs(d),1,1e-7)
end
local function len(v) return math.sqrt(v[1]^2+v[2]^2+v[3]^2) end
local function sub(a,b) return {a[1]-b[1],a[2]-b[2],a[3]-b[3]} end
local function clone(v)
    if type(v)~="table" then return v end local r={} for k,x in pairs(v) do r[k]=clone(x) end return r
end
local function equal(a,b)
    if type(a)~="table" then return a==b end if type(b)~="table" then return false end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end return true
end
local function test(name,fn)
    cases=cases+1 local ok,issue=pcall(fn) if not ok then error(name..": "..tostring(issue)) end
    print("PASS "..name)
end
local geometry={com={0,.9,-.05},left_grip={.26,.953,.264},right_grip={-.26,.953,.264},
    steering_pivot={0,.743,.285},steering_axis={0,.9601195908265842,-.279589648075517},
    bottom_bracket={0,.3102,-.1058},pedals={{.06575,.1635,.0087},{-.06575,.4569,-.2204}}}
local epoch,handle={},{}
local function frame()
    return {valid=true,fresh=true,serial="18446744073709551615",physics_epoch=epoch,body_handle=handle,
        body={orientation={0,0,0,1},center_of_mass={0,.9,-.05}},gates={focused=true,menu_open=false}}
end
local function options() return {enabled=true,bike_basis="y_up_z_forward_x_left"} end
local function visual(f,p,r)
    return {valid=true,fresh=true,serial=f.serial,physics_epoch=f.physics_epoch,body_handle=f.body_handle,
        articulation=p or {},rider=r or {}}
end
local function rig(f)
    local function bone(p) return {position=p,rotation={0,0,0,1}} end
    local r={valid=true,fresh=true,serial=f.serial,physics_epoch=f.physics_epoch,body_handle=f.body_handle,
        basis="calibrated",bike_to_root_rotation={0,0,0,1},
        root={position={0,.9578988338,-.2877711058},rotation={0,0,0,1},parent_rotation={0,0,0,1}},chains={}}
    for i,name in ipairs({"left_arm","right_arm","left_leg","right_leg"}) do
        local s=i%2==1 and 1 or -1 local arm=i<=2
        r.chains[name]={parent_rotation={0,0,0,1},bike_to_tip_rotation={0,0,0,1},
            contact_offset=arm and {.04,0,.01} or {0,-.09,0},
            upper=bone(arm and {.22*s,1.4,-.1} or {.1*s,.9579,-.28}),
            middle=bone(arm and {.31*s,1.1,.03} or {.17*s,.58,.12}),
            tip=bone(arm and {.26*s,.953,.264} or {.09*s,.2,.01})}
    end return r
end
local function finite_tree(x)
    if type(x)=="number" then check(x==x and math.abs(x)<math.huge,"non-finite output") end
    if type(x)=="table" then for _,v in pairs(x) do finite_tree(v) end end
end

test("default inert and unknown basis",function()
    check(A.solve(nil,nil).status=="disabled")
    local out=A.solve(frame(),geometry,nil,{enabled=true}) check(out.status=="unavailable")
    check(out.issue=="unknown bike basis") check(out.pose_request==nil)
end)
test("missing measured state never fabricates pose",function()
    local f=frame() f.fresh=false check(A.solve(f,geometry,nil,options()).status=="unavailable")
    f=frame() f.body.orientation={0,0,0,0} check(A.solve(f,geometry,nil,options()).status=="unavailable")
    f=frame() f.body.orientation={0,0,0,1.01} check(A.solve(f,geometry,nil,options()).status=="unavailable")
    f=frame() f.body.center_of_mass[1]=0/0 check(A.solve(f,geometry,nil,options()).status=="unavailable")
    f=frame() f.serial="01" check(A.solve(f,geometry,nil,options()).status=="unavailable")
    f=frame() f.serial="18446744073709551616" check(A.solve(f,geometry,nil,options()).status=="unavailable")
end)
test("neutral COM and root have distinct frames",function()
    local out=A.solve(frame(),geometry,nil,options())
    check(out.status=="targets_only") check(out.pose_request==nil) check(out.native_alignment==false)
    vnear(out.targets.bike_root,{0,0,0}) vnear(out.targets.center_of_mass,geometry.com)
    vnear(out.targets.limbs.left_arm.contact_world,geometry.left_grip)
    vnear(out.targets.limbs.right_leg.contact_world,geometry.pedals[2])
    check(out.targets.limbs.left_leg.anchor_kind=="spindle_proxy")
    check(out.diagnostics.contact_observed==false) check(out.diagnostics.applied==false)
end)
test("yaw and antipodal quaternions preserve basis",function()
    local f=frame() f.body.orientation={0,math.sin(math.pi/4),0,math.cos(math.pi/4)}
    f.body.center_of_mass={10-.05,20+.9,30}
    local a=A.solve(f,geometry,nil,options()) vnear(a.targets.bike_root,{10,20,30})
    vnear(a.targets.limbs.left_arm.contact_world,{10+.264,20+.953,30-.26})
    f.body.orientation={0,-math.sin(math.pi/4),0,-math.cos(math.pi/4)}
    local b=A.solve(f,geometry,nil,options()) vnear(a.targets.limbs.left_arm.contact_world,b.targets.limbs.left_arm.contact_world)
end)
test("frame binding rejects stale targets and visual state gates",function()
    local f=frame() local v=visual(f) v.serial="1"
    check(A.solve(f,geometry,v,options()).issue=="stale or unbound visual targets")
    v=visual(f) v.body_handle={} check(A.solve(f,geometry,v,options()).status=="unavailable")
    v=visual(f) v.physics_epoch={} check(A.solve(f,geometry,v,options()).status=="unavailable")
    for _,k in ipairs({"menu_open","falling"}) do f=frame() f.gates[k]=true check(A.solve(f,geometry,nil,options()).status=="unavailable") end
    f=frame() f.gates.focused=false check(A.solve(f,geometry,nil,options()).status=="unavailable")
end)
test("crank spindle translation leaves authored sole platform level",function()
    local f=frame() local g=clone(geometry) g.pedal_contact_offsets={{.05,.02,0},{-.05,.02,0}}
    local out=A.solve(f,g,visual(f,{crank_phase=math.pi/2}),options())
    local p=g.pedals[1] local bb=g.bottom_bracket
    local expected={p[1]+.05,bb[2]-(p[3]-bb[3])+.02,bb[3]+p[2]-bb[2]}
    vnear(out.targets.limbs.left_leg.contact_local,expected)
    check(out.targets.limbs.left_leg.anchor_kind=="authored_pedal_contact")
end)
test("bar steering uses oblique axis and shared pivot",function()
    local f=frame() local out=A.solve(f,geometry,visual(f,{steer=.3,barspin=.7}),options())
    local p=sub(geometry.left_grip,geometry.steering_pivot) local n=geometry.steering_axis
    local norm=len(n) n={n[1]/norm,n[2]/norm,n[3]/norm}
    local c,s=math.cos(1),math.sin(1) local d=p[1]*n[1]+p[2]*n[2]+p[3]*n[3]
    local cp={n[2]*p[3]-n[3]*p[2],n[3]*p[1]-n[1]*p[3],n[1]*p[2]-n[2]*p[1]}
    local expected={} for i=1,3 do expected[i]=geometry.steering_pivot[i]+p[i]*c+cp[i]*s+n[i]*d*(1-c) end
    vnear(out.targets.limbs.left_arm.contact_local,expected)
    vnear(out.targets.limbs.left_leg.contact_local,geometry.pedals[1])
end)
test("whole pitch then roll is noncommutative and has no blanket correction",function()
    local f=frame() local pitch,roll=.7,-.4
    local out=A.solve(f,geometry,visual(f,{movement_bike_pitch=pitch,movement_bike_roll=roll}),options())
    local p=sub(geometry.left_grip,geometry.steering_pivot)
    local y,z=p[2]*math.cos(pitch)-p[3]*math.sin(pitch),p[2]*math.sin(pitch)+p[3]*math.cos(pitch)
    local x,yy=p[1]*math.cos(roll)-y*math.sin(roll),p[1]*math.sin(roll)+y*math.cos(roll)
    vnear(out.targets.limbs.left_arm.contact_local,{geometry.steering_pivot[1]+x,geometry.steering_pivot[2]+yy,geometry.steering_pivot[3]+z})
    local neutral=A.solve(f,geometry,nil,options()) vnear(neutral.targets.limbs.left_arm.contact_local,geometry.left_grip)
end)
test("released limbs follow explicit authored motion anchors",function()
    local f=frame() local v=visual(f,{barspin=5,tailwhip=-4,crank_phase=6},
        {release={left_arm=1,right_leg=1},local_targets={left_arm={.5,1.2,-.2},right_leg={-.3,.8,-.4}}})
    local out=A.solve(f,geometry,v,options())
    vnear(out.targets.limbs.left_arm.contact_local,{.5,1.2,-.2})
    vnear(out.targets.limbs.right_leg.contact_local,{-.3,.8,-.4})
    check(out.targets.limbs.left_arm.release==1)
    v.rider.release.left_arm=2 check(A.solve(f,geometry,v,options()).status=="unavailable")
end)
test("two bone exact lengths and unreachable envelopes",function()
    for _,target in ipairs({{0,0,0},{0,0,.05},{0,0,.6},{0,0,10},{.2,.2,.2}}) do
        local out=A.two_bone({0,0,0},target,{0,0,1},.3,.5,{1,0,0})
        near(len(out.middle),.3) near(len(sub(out.tip,out.middle)),.5)
        check(out.reach>=.2001-1e-8 and out.reach<=.7999+1e-8) finite_tree(out)
    end
    local out=A.two_bone({0,0,0},{0,0,10},{0,0,0},.5,.5)
    check(out.clamped) check(out.error>9) finite_tree(out)
    check(A.two_bone({0,0,0},{0,0,1},{0,1,0},0,.5)==nil)
    check(A.two_bone({0,0,0},{0,0,1},{0,1,0},1.01,.5)==nil)
end)
test("deterministic reach sweep preserves both measured segments",function()
    local seed=72341
    local function random() seed=(seed*48271)%2147483647 return seed/2147483647 end
    for i=1,600 do
        local a,b=.04+random()*.96,.04+random()*.96
        local root={random()*20-10,random()*20-10,random()*20-10}
        local target={root[1]+random()*8-4,root[2]+random()*8-4,root[3]+random()*8-4}
        local pole=i%3==0 and {0,0,0} or {random(),random(),random()}
        local out=A.two_bone(root,target,pole,a,b)
        near(len(sub(out.middle,root)),a,1e-6)
        near(len(sub(out.tip,out.middle)),b,1e-6)
        check(out.reach>math.abs(a-b) and out.reach<a+b)
        if out.clamped then check(out.error>0) end
    end
end)
test("local/world transforms round trip scaled rotated parent",function()
    local parent={position={7,3,-2},rotation={0,math.sin(.6),0,math.cos(.6)},scale=1.7}
    local p,q={.3,-.2,.8},{math.sin(.2),0,0,math.cos(.2)}
    local world=A.to_world(parent,p,q) local local_pose=A.to_local(parent,world.position,world.rotation)
    vnear(local_pose.position,p) qnear(local_pose.rotation,q)
    parent.rotation={0,0,0,0} check(A.to_local(parent,p,q)==nil)
end)
test("parent transforms cover noncommuting quaternion products",function()
    for i=1,64 do
        local x,y,z=i*.037,i*.021,-i*.013
        local qx,qy,qz={math.sin(x),0,0,math.cos(x)},{0,math.sin(y),0,math.cos(y)},{0,0,math.sin(z),math.cos(z)}
        local parent=A.to_world({position={i,-i,.1*i},rotation=qy,scale=1},{0,0,0},qz)
        parent.scale=.5+i*.01
        local p={.3,-.7,.12*i}
        local world=A.to_world(parent,p,qx) local again=A.to_local(parent,world.position,world.rotation)
        vnear(again.position,p,1e-6) qnear(again.rotation,qx)
    end
end)
test("calibrated rig makes finite bounded requests with local rotations",function()
    local f=frame() local o=options() o.rig=rig(f)
    local out=A.solve(f,geometry,nil,o) check(out.status=="request_ready") check(out.native_alignment==false)
    check(out.pose_request.applied==false) check(out.pose_request.contact_observed==false)
    for name,c in pairs(o.rig.chains) do
        local l=out.pose_request.limbs[name]
        near(len(sub(l.middle,l.root)),len(sub(c.middle.position,c.upper.position)))
        near(len(sub(l.tip,l.middle)),len(sub(c.tip.position,c.middle.position)))
        local world=A.to_world({position={0,0,0},rotation=l.upper_rotation},{0,0,0},l.middle_local_rotation)
        qnear(world.rotation,l.middle_rotation)
        vnear(sub(l.contact_result,l.tip),sub(l.contact_requested,l.requested_target))
    end finite_tree(out)
end)
test("unreachable requests never stretch or claim contact",function()
    local f=frame() local o=options() o.rig=rig(f)
    local v=visual(f,{steer=.9,tailwhip=2}, {release={left_arm=1},local_targets={left_arm={3,3,3}},hip_offset={.5,.5,.5},hip_yaw=math.pi})
    local out=A.solve(f,geometry,v,o) check(out.status=="request_ready")
    local p=out.pose_request check(p.root_shift_limited) check(p.root_rotation_limited)
    check(p.root_shift<=.18000001) check(p.all_targets_reachable==false)
    check(p.limbs.left_arm.clamped) check(p.limbs.left_arm.contact_error>1)
    check(p.limbs.left_leg.tip_rotation_limited) check(p.contact_observed==false)
    finite_tree(out)
end)
test("no implicit native basis, stale rig or bad calibration",function()
    local f=frame() local o=options() o.rig=rig(f) o.rig.basis="unknown"
    check(A.solve(f,geometry,nil,o).status=="unavailable")
    o.rig=rig(f) o.rig.fresh=false check(A.solve(f,geometry,nil,o).status=="unavailable")
    o.rig=rig(f) o.rig.chains.left_arm.contact_offset={1,0,0} check(A.solve(f,geometry,nil,o).status=="unavailable")
    o.rig=rig(f) o.maximum_root_shift=.36 check(A.solve(f,geometry,nil,o).status=="unavailable")
    o.maximum_root_shift=false check(A.solve(f,geometry,nil,o).status=="unavailable")
end)
test("outputs detached and all inputs unchanged",function()
    local f=frame() local o=options() o.rig=rig(f) local v=visual(f,{steer=.2})
    local before={clone(f),clone(geometry),clone(v),clone(o)}
    local out=A.solve(f,geometry,v,o)
    check(equal(f,before[1])) check(equal(geometry,before[2])) check(equal(v,before[3])) check(equal(o,before[4]))
    out.targets.limbs.left_arm.contact_world[1]=123
    out.pose_request.limbs.left_arm.middle[1]=456
    check(equal(f,before[1])) check(equal(geometry,before[2])) check(equal(v,before[3])) check(equal(o,before[4]))
    local again=A.solve(f,geometry,v,o) check(again.targets.limbs.left_arm.contact_world[1]~=123)
    check(again.pose_request.limbs.left_arm.middle[1]~=456)
end)
test("invalid geometry and infinities are refused",function()
    local g=clone(geometry) g.steering_axis={0,0,0} check(A.solve(frame(),g,nil,options()).status=="unavailable")
    local f=frame() local v=visual(f,{barspin=math.huge}) check(A.solve(f,geometry,v,options()).status=="unavailable")
    v=visual(f,{}, {hip_offset={.6,0,0}}) check(A.solve(f,geometry,v,options()).status=="unavailable")
end)
test("malformed optional inputs fail closed without effects",function()
    local f=frame()
    for _,x in ipairs({false,42,"unexpected"}) do
        check(A.solve(f,geometry,nil,x).status=="unavailable")
        local v=visual(f) v.articulation=x check(A.solve(f,geometry,v,options()).status=="unavailable")
        v=visual(f) v.rider=x check(A.solve(f,geometry,v,options()).status=="unavailable")
        v=visual(f) v.rider={release=x} check(A.solve(f,geometry,v,options()).status=="unavailable")
        local g=clone(geometry) g.pedal_contact_offsets=x check(A.solve(f,g,nil,options()).status=="unavailable")
    end
    local v=visual(f,{steer=false}) check(A.solve(f,geometry,v,options()).status=="unavailable")
    local g=clone(geometry) g.pedal_contact_offsets={{0,0,0}} check(A.solve(f,g,nil,options()).status=="unavailable")
    f.gates=false check(A.solve(f,geometry,nil,options()).status=="unavailable")
    check(A.to_world({position={0,0,0},rotation={0,0,0,1},scale=false},{0,0,0},{0,0,0,1})==nil)
    check(A.to_local({position={0,0,0},rotation={0,0,0,1},scale=false},{0,0,0},{0,0,0,1})==nil)
end)
-- Added during Root's Host HOLD; execution resumed only after explicit DONE.
test("helper2 flat visual targets bind authored policy without realized proof",function()
    local f=frame()
    local v={scope="model_target_only",valid=true,fresh=true,serial=f.serial,epoch=f.physics_epoch,
        barspin=.7,tailwhip=-.4,movement_bike_pitch=.2,movement_bike_roll=-.3,movement_crank_angle=.5,
        movement_id=34,phase=.5,progress=.3,release_left_hand=1,release_right_hand=.5,
        release_left_foot=0,release_right_foot=1,bar_neutral=false,rear_neutral=false,
        pose_provenance="authored_motions_policy",realized=false}
    local o=options() o.base_articulation={steer=.2,crank_phase=.3}
    local out=A.solve(f,geometry,v,o)
    check(out.status=="targets_only") check(out.native_alignment==false)
    local nested=visual(f,{steer=.2,crank_phase=.8,barspin=.7,tailwhip=-.4,movement_bike_pitch=.2,movement_bike_roll=-.3},
        {release={left_arm=1,right_arm=.5,left_leg=0,right_leg=1}})
    local expected=A.solve(f,geometry,nested,options())
    for _,name in ipairs({"left_arm","right_arm","left_leg","right_leg"}) do
        vnear(out.targets.limbs[name].contact_world,expected.targets.limbs[name].contact_world)
    end
    v.valid=false check(A.solve(f,geometry,v,o).status=="unavailable")
    v.valid=true v.realized=true check(A.solve(f,geometry,v,o).status=="unavailable")
    v.realized=false v.release_left_hand=nil check(A.solve(f,geometry,v,o).status=="unavailable")
    v.release_left_hand=1 v.epoch={} check(A.solve(f,geometry,v,o).status=="unavailable")
    v.physics_epoch=f.physics_epoch check(A.solve(f,geometry,v,o).status=="unavailable")
    v.epoch=f.physics_epoch v.physics_epoch={} check(A.solve(f,geometry,v,o).status=="unavailable")
end)
test("actual helper2 private envelope carries binding; public view cannot authorize targets",function()
    local f=frame() local lease={}
    f.time=12 f.seconds=.01 f.source={lease_handle=lease,generation=4,user=0,sequence="10",source_epoch="2",
        context_generation="3",observation_serial="9",observed_ms="12000",packet=7}
    local t={valid=true,scope="model_target_only",barspin=.2,tailwhip=.4,movement_bike_pitch=0,
        movement_bike_roll=0,movement_crank_angle=.7,movement_id=34,phase=.5,progress=.3,
        release_left_hand=.25,release_right_hand=.75,release_left_foot=.1,release_right_foot=.6,
        bar_neutral=false,rear_neutral=false,pose_provenance="authored_motions_policy",realized=false}
    local function result()
        local s={} for k,v in pairs(f.source) do s[k]=v end
        return {valid=true,fresh=true,advanced=true,scope="model_adapter_only",realized=false,
            serial=f.serial,time=f.time,binding={body_handle=f.body_handle,physics_epoch=f.physics_epoch,
                lease_handle=lease,serial=f.serial,time=f.time,seconds=f.seconds,source=s},visual_targets=t}
    end
    local raw=result() local out=A.solve(f,geometry,raw,options())
    check(out.status=="targets_only") near(out.targets.limbs.left_arm.release,.25)
    near(out.targets.limbs.right_leg.release,.6) check(out.native_alignment==false)
    check(A.solve(f,geometry,t,options()).status=="unavailable")
    raw=result() raw.binding=nil check(A.solve(f,geometry,raw,options()).status=="unavailable")
    raw=result() raw.binding.source.sequence="11" check(A.solve(f,geometry,raw,options()).status=="unavailable")
    raw=result() raw.binding.lease_handle={} check(A.solve(f,geometry,raw,options()).status=="unavailable")
    raw=result() raw.binding.seconds=.02 check(A.solve(f,geometry,raw,options()).status=="unavailable")
    raw=result() raw.time=13 check(A.solve(f,geometry,raw,options()).status=="unavailable")
    raw=result() raw.fresh=false raw.advanced=false check(A.solve(f,geometry,raw,options()).status=="unavailable")
    raw=result() raw.valid=false raw.visual_targets=nil check(A.solve(f,geometry,raw,options()).status=="unavailable")
end)
print(string.format("RESULT %d cases %d assertions; pure geometry only; native alignment unverified",cases,assertions))
return {run=function() return {cases=cases,assertions=assertions} end}

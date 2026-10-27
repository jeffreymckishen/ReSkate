-- The bike draws its own steer, wheels and cranks: bike_visual's scalar posing
-- against the table forms it replaced, Spawn's follow visual in a supplied
-- presentation pose, and Core handing that pose over and naming a refusal.
-- Constructed fixtures only; no Host, permission, native clock or game. Ride's
-- side of the pose is ride_runtime_presentation_tests (the qualified copy).
local Visual=require("./bike_visual")
local Spawn=require("./bike_spawn")
local Core=require("./bike_runtime_core")
local G=require("./bike_geometry")
local M=require("./force_math")
local Tests={}
local PI=math.pi

-- bike_visual's posing before it moved to scalars, word for word, as the
-- reference its matrices must equal number for number.
local Reference={}
do
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
    local function posed_point(p,part,pose)
        if part==3 then p=rotate(p,1,pose.rear_wheel_phase,G.rear_axle) end
        if part==4 then p=rotate(p,1,pose.front_wheel_phase,G.front_axle) end
        if part==5 then p=rotate(p,1,pose.crank_phase,G.bottom_bracket) end
        if part==7 or part==8 then
            local spindle=G.pedals[part-6]
            p=M.add(p,M.sub(rotate(spindle,1,pose.crank_phase,G.bottom_bracket),spindle))
        end
        if part==2 or part==4 or part==6 then p=steering(p,pose.steer+pose.barspin)
        else p=steering(p,pose.tailwhip) end
        p=rotate(p,1,pose.movement_bike_pitch,G.steering_pivot)
        p=rotate(p,3,pose.movement_bike_roll,G.steering_pivot)
        return p
    end
    local function local_point(p,part,pose,q) return M.turn(q,posed_point(p,part,pose)) end
    function Reference.matrices(root,q,pose)
        q=M.normalized(q)
        local out={}
        for part=1,8 do
            local origin=local_point({0,0,0},part,pose,q)
            local m=table.create(16,0) m[16]=1
            for axis=1,3 do
                local basis={0,0,0} basis[axis]=1
                basis=M.sub(local_point(basis,part,pose,q),origin)
                for row=1,3 do m[(axis-1)*4+row]=basis[row] end
            end
            local at=M.add(root,origin)
            for row=1,3 do m[12+row]=at[row] end
            out[part]=m
        end
        return out
    end
end
local function same_number(a,b) return a==b and (a~=0 or 1/a==1/b) end
local function pose_of(changes)
    local pose=Visual.neutral()
    for key,value in pairs(changes or {}) do pose[key]=value end
    return pose
end
local function v(a) return vector.create(a[1],a[2],a[3]) end
-- Where matrix m puts the part-local point p.
local function apply(m,p)
    return {m[1]*p[1]+m[5]*p[2]+m[9]*p[3]+m[13],m[2]*p[1]+m[6]*p[2]+m[10]*p[3]+m[14],m[3]*p[1]+m[7]*p[2]+m[11]*p[3]+m[15]}
end

-- A Spawn that owns a handed-off body at serial "1", recording each part request.
local function visual_fixture()
    local f={sets={},refuse=nil}
    local owner=Spawn.new({entities={set=function(id,_,options)
        if f.refuse then return false,f.refuse end
        table.insert(f.sets,{id=id,matrix=options.matrix});return true
    end}})
    owner.root,owner.rotation={0,-G.com[2],-G.com[3]},{0,0,0,1}
    local base=M.add(owner.root,M.turn(owner.rotation,G.com))
    function f.sample(serial,time,delta)
        return {epoch=newproxy(),serial=serial,time=time,seconds=1/60,mass=G.mass,
            position=v(M.add(base,delta or {0,0,0})),rotation=table.clone(owner.rotation),
            velocity=vector.create(0,0,0),angular_velocity=vector.create(0,0,0),inertia=v(G.inertia)}
    end
    owner.sample=f.sample("1",0)
    owner.phase,owner.follow_handed_off="follow_owned",true
    return owner,f
end

-- Core one tick before publication with a stand-in Spawn, as core_tick_budget_tests:
-- the next step publishes and every later step is a following tick. The tracked
-- RIDE_COMPOSITION_QUALIFIED is false, so Core makes no Ride.
local function following_fixture()
    local f={now=10000,visuals={},follow=newproxy(),body=newproxy(),published=false}
    local spawn={phase="armed"}
    function spawn:request() return true end
    function spawn:update() if self.phase=="armed" then self.phase="spawned" end end
    function spawn:status()
        return {phase=self.phase,cleanup_unknown=false,creation_unknown=false,body=false,visual_remove_requested=false}
    end
    function spawn:handoff_follow() self.phase="follow_owned";return f.body,{serial="1"},nil end
    function spawn:follow_visual(...)
        local args=table.pack(...)
        table.insert(f.visuals,args)
        if f.refuse_visual then return false,f.refuse_visual end
        return true
    end
    function spawn:stop() self.phase="closed" end
    local s={time={},input={},skater={},level={},storage={},json={},menu={},entities={},world={physics={}}}
    function s.time.now() return f.now end
    function s.json.encode() return "constructed bounded storage DTO" end
    function s.storage.get() return nil end
    function s.storage.set() end
    local P=s.world.physics
    function P.reserve_follow() return f.follow,nil end
    function P.read_follow()
        local following=f.published
        return {phase=following and "following" or "reserved",reason="none",park_reason="none",sequence="7",
            final_revision=following and "1" or "0",final_native_epoch=following and "5" or "0",
            returned_revision=following and "1" or "0",pending={},in_flight=0,claim_known=true,orphaned=false,
            park_observed=false,native_retirement_known=false,terminal=false}
    end
    function P.publish_follow() f.published=true;return true end
    function P.read() f.serial=(f.serial or 1)+1;return {serial=tostring(f.serial)} end
    function P.stop_follow() return true end
    function P.acknowledge_follow() return true end
    function P.release() return true end
    local state={phase="spawning",detail="constructed spawned owner",generation=1,cancel_version=1,calls={},counts={},
        receipts={},omitted_calls=0,omitted_receipts=0,remove_attempted={},remove_accepted={},used=true,
        ledger_owned=true,spawn_requested=true,input_current=true,slot=0}
    local core=Core.new(s,{qualification_only=true},state)
    local original=Spawn.new
    Spawn.new=function() return spawn end
    local ok,bound=pcall(core.prepare_backend,core)
    Spawn.new=original
    assert(ok and bound==true,"constructed backend binds the stand-in spawn owner")
    function f.tick(at)
        if at then f.now=at end
        return core:step(16)
    end
    return f,state
end

function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(_,run) cases+=1;run() end

    local rotations={{0,0,0,1},{.1,.7,-.2,math.sqrt(1-.01-.49-.04)},{0,math.sqrt(.5),0,math.sqrt(.5)},
        {-.3,.1,.4,math.sqrt(1-.09-.01-.16)}}
    local poses={
        {},
        {steer=.31,front_wheel_phase=1.2,rear_wheel_phase=-2.9,crank_phase=.45},
        {steer=-.4,front_wheel_phase=PI,rear_wheel_phase=-PI,crank_phase=-3.1},
        {steer=.2,front_wheel_phase=.3,rear_wheel_phase=.4,crank_phase=5.5,barspin=2*PI+.3,tailwhip=-1.7,
            movement_bike_pitch=.6,movement_bike_roll=-.55},
        {steer=-0.0,crank_phase=-0.0,movement_bike_roll=1e-300},
    }
    case("posed matrices are the table forms' numbers",function()
        for ri,q in ipairs(rotations) do
            for pi,changes in ipairs(poses) do
                local root={3.25+ri,101.5,-7.125*pi}
                local pose=pose_of(changes)
                local got=assert(Visual.matrices(root,q,pose))
                local want=Reference.matrices(root,q,pose)
                for part=1,8 do for k=1,16 do
                    check(same_number(got[part][k],want[part][k]),
                        "rotation "..ri.." pose "..pi.." matrix "..part.."["..k.."]: "..got[part][k].." against "..want[part][k])
                end end
            end
        end
    end)
    case("no pose is the neutral pose",function()
        local q=rotations[2]
        local without=assert(Visual.matrices({1,2,3},q))
        local neutral=Reference.matrices({1,2,3},q,Visual.neutral())
        for part=1,8 do for k=1,16 do check(same_number(without[part][k],neutral[part][k]),"neutral "..part.."["..k.."]") end end
        local sample={position=vector.create(3,4,5),rotation=q}
        local posed=assert(Visual.from_sample(sample,pose_of(poses[2])))
        local root=M.sub({3,4,5},M.turn(M.normalized(q),G.com))
        local want=Reference.matrices(root,q,pose_of(poses[2]))
        for part=1,8 do for k=1,16 do check(same_number(posed[part][k],want[part][k]),"from_sample "..part.."["..k.."]") end end
    end)
    case("the drawn parts move as the pose says",function()
        local q={0,0,0,1}
        local base=assert(Visual.matrices({0,0,0},q))
        local turned=assert(Visual.matrices({0,0,0},q,pose_of({rear_wheel_phase=PI/2,front_wheel_phase=PI/2})))
        -- A wheel turned a quarter about +X: its +Y axis now points along +Z.
        for part,axle in pairs({[3]=G.rear_axle,[4]=G.front_axle}) do
            check(math.abs(turned[part][5])<1e-12 and math.abs(turned[part][6])<1e-12 and math.abs(turned[part][7]-1)<1e-12,
                "wheel "..part.." turns about its axle")
            local a,b=apply(base[part],axle),apply(turned[part],axle)
            check(M.length(M.sub(a,b))<1e-12,"wheel "..part.." stays on its axle")
        end
        for _,part in ipairs({1,2,5,6,7,8}) do
            for k=1,16 do check(turned[part][k]==base[part][k],"part "..part.." does not move with the wheels") end
        end
        local cranked=assert(Visual.matrices({0,0,0},q,pose_of({crank_phase=PI})))
        for i,part in ipairs({7,8}) do
            -- Half a turn of the cranks carries each pedal to the other side of the bottom bracket.
            local spindle,bb=G.pedals[i],G.bottom_bracket
            check(math.abs(cranked[part][14]-base[part][14]+2*(spindle[2]-bb[2]))<1e-12
                and math.abs(cranked[part][15]-base[part][15]+2*(spindle[3]-bb[3]))<1e-12,"pedal "..i.." goes round with the cranks")
        end
        local steered=assert(Visual.matrices({0,0,0},q,pose_of({steer=.3})))
        for _,part in ipairs({2,4,6}) do
            local changed=false
            for k=1,15 do changed=changed or steered[part][k]~=base[part][k] end
            check(changed,"front end part "..part.." turns with the bars")
        end
        for _,part in ipairs({1,3,5,7,8}) do
            for k=1,16 do check(steered[part][k]==base[part][k],"part "..part.." does not steer") end
        end
    end)
    case("a malformed pose is refused",function()
        check(Visual.valid_pose(Visual.neutral()) and not Visual.valid_pose(nil) and not Visual.valid_pose(5),"tables only")
        for _,key in ipairs({"steer","front_wheel_phase","rear_wheel_phase","crank_phase","barspin","tailwhip",
            "movement_bike_pitch","movement_bike_roll"}) do
            for _,bad in ipairs({0/0,math.huge,"0",false}) do
                local pose=Visual.neutral();pose[key]=bad
                local m,why=Visual.matrices({0,0,0},{0,0,0,1},pose)
                check(not Visual.valid_pose(pose) and m==nil and why=="invalid articulation","refused "..key.."="..tostring(bad))
            end
            local pose=Visual.neutral();pose[key]=nil
            check(not Visual.valid_pose(pose),"a pose without "..key.." is refused")
        end
    end)

    case("the follow visual draws a new sample in its pose",function()
        local owner,f=visual_fixture()
        local pose=table.freeze(pose_of(poses[2]))
        local sample=f.sample("2",1/60,{.5,0,0})
        check(owner:follow_visual(sample,1000,pose)==true and #f.sets==8,"eight part requests")
        local want=assert(Visual.from_sample(sample,pose))
        for i,row in ipairs(f.sets) do
            check(row.id==i,"part "..i.." in order")
            for k=1,16 do check(same_number(row.matrix[k],want[i][k]),"part "..i.."["..k.."] is drawn in the pose") end
        end
        local status=owner:status()
        check(status.visual_updates==1 and status.posed_updates==1 and owner.sample==sample,"one posed update at the new serial")
    end)
    case("the same body in the same pose places nothing",function()
        local owner,f=visual_fixture()
        local pose=table.freeze(pose_of(poses[2]))
        owner:follow_visual(f.sample("2",1/60),1000,pose)
        table.clear(f.sets)
        check(owner:follow_visual(f.sample("2",1/60),1010,pose_of(poses[2]))==true and #f.sets==0,
            "an equal pose on the same serial is the early return")
        check(owner:status().visual_updates==1,"no update counted")
        -- No pose is the neutral pose: equal to a neutral-valued pose already drawn.
        local plain,g=visual_fixture()
        plain:follow_visual(g.sample("2",1/60),1000,Visual.neutral())
        table.clear(g.sets)
        check(plain:follow_visual(g.sample("2",1/60),1010)==true and #g.sets==0,"nil after a neutral pose places nothing")
    end)
    case("a reused mutable pose redraws every changed presentation value",function()
        local owner,f=visual_fixture()
        local sample=f.sample("2",1/60)
        local pose=Visual.neutral();pose.unused={caller=true}
        check(owner:follow_visual(sample,1000,pose)==true,"initial mutable pose draws")
        local keys={"steer","front_wheel_phase","rear_wheel_phase","crank_phase","barspin","tailwhip",
            "movement_bike_pitch","movement_bike_roll"}
        for index,key in ipairs(keys) do
            local prior=owner.pose
            local before=pose[key]
            pose[key]=index/10
            table.clear(f.sets)
            check(owner:follow_visual(sample,1000+index,pose)==true and #f.sets==8,"reused "..key.." redraws the same body")
            check(prior[key]==before and owner.pose~=pose and owner.pose[key]==pose[key],"the prior "..key.." value stays detached")
            local want=assert(Visual.from_sample(sample,pose))
            for i,row in ipairs(f.sets) do for k=1,16 do
                check(same_number(row.matrix[k],want[i][k]),"reused "..key.." matrix "..i.."["..k.."]")
            end end
        end
        local fields=0;for _ in owner.pose do fields+=1 end
        check(fields==8 and owner.pose.unused==nil,"the snapshot contains only the eight presentation values")
        table.clear(f.sets)
        check(owner:follow_visual(sample,1010,table.clone(pose))==true and #f.sets==0,"equal values in a different table still skip placement")
        check(owner:status().visual_updates==9 and owner:status().posed_updates==9,"only the initial and changed draws are counted")
    end)
    case("a setter cannot change the pose snapshot for matrices already drawn",function()
        local owner,f=visual_fixture()
        local sample=f.sample("2",1/60)
        local pose=pose_of({steer=.2,crank_phase=.4})
        local drawn=table.clone(pose)
        local want=assert(Visual.from_sample(sample,drawn))
        local place=owner.api.entities.set
        owner.api.entities.set=function(id,...)
            if id==1 then pose.steer=.6;pose.crank_phase=.8 end
            return place(id,...)
        end
        check(owner:follow_visual(sample,1000,pose)==true and #f.sets==8,"the original snapshot is placed")
        check(owner.pose.steer==drawn.steer and owner.pose.crank_phase==drawn.crank_phase,"cache describes the values captured before callbacks")
        for i,row in ipairs(f.sets) do for k=1,16 do
            check(same_number(row.matrix[k],want[i][k]),"callback draw "..i.."["..k.."]")
        end end
        owner.api.entities.set=place
        table.clear(f.sets)
        check(owner:follow_visual(sample,1010,pose)==true and #f.sets==8,"the callback's caller mutation needs another draw")
        check(owner.pose.steer==.6 and owner.pose.crank_phase==.8 and owner:status().visual_updates==2,"only the later draw publishes the mutated values")
    end)
    case("a partial placement refusal keeps the last successful pose snapshot",function()
        local owner,f=visual_fixture()
        local sample=f.sample("2",1/60)
        local pose=pose_of({steer=.2})
        check(owner:follow_visual(sample,1000,pose)==true,"initial draw succeeds")
        local prior=owner.pose
        pose.steer=.5
        local place=owner.api.entities.set
        owner.api.entities.set=function(id,...)
            if id==3 then return false,"constructed partial placement" end
            return place(id,...)
        end
        table.clear(f.sets)
        local ok,why=owner:follow_visual(sample,1010,pose)
        check(not ok and why=="bike visual request refused: constructed partial placement" and #f.sets==2,"two accepted parts do not complete the draw")
        check(owner.pose==prior and prior.steer==.2 and owner.sample==sample,"failed publication retains the last pose and body")
        check(owner:status().visual_updates==1 and owner:status().posed_updates==1,"a partial draw advances no update counter")
        owner.api.entities.set=place
        table.clear(f.sets)
        check(owner:follow_visual(sample,1020,pose)==true and #f.sets==8,"the still-unpublished values need all eight placements")
        check(owner.pose~=pose and owner.pose.steer==.5 and owner:status().visual_updates==2,"full success publishes the detached replacement")
    end)
    case("the same body in a newer pose is drawn again without advancing the body",function()
        local owner,f=visual_fixture()
        local sample=f.sample("1",0)
        -- The handoff drew serial 1 neutral; Ride's first step was on that same sample.
        local pose=table.freeze(pose_of(poses[3]))
        check(owner:follow_visual(sample,1000,pose)==true and #f.sets==8,"drawn again on the same serial")
        local want=assert(Visual.from_sample(sample,pose))
        for i,row in ipairs(f.sets) do for k=1,16 do check(same_number(row.matrix[k],want[i][k]),"redrawn "..i.."["..k.."]") end end
        check(owner.sample.serial=="1" and owner.follow_observed_at==1000 and owner:status().posed_updates==1,
            "the body sample and its freshness clock stay")
        table.clear(f.sets)
        -- The native clock rule still holds on the same serial, pose or not.
        check(owner:follow_visual(f.sample("1",0),1050,pose_of(poses[2]))==true and #f.sets==8,"another pose 50 ms on")
        local ok,why=owner:follow_visual(f.sample("1",0),1101,pose_of(poses[4]))
        check(not ok and why=="Body native clock stopped advancing for follow visuals","a stalled body is refused in any pose")
    end)
    case("a malformed pose is refused with its own reason and nothing is placed",function()
        local owner,f=visual_fixture()
        local bad=pose_of(poses[2]);bad.crank_phase=0/0
        local ok,why=owner:follow_visual(f.sample("2",1/60),1000,bad)
        check(not ok and why=="Invalid presentation pose for follow visuals" and #f.sets==0,"refused: "..tostring(why))
        check(owner:status().follow_visual_error==why and owner.sample.serial=="1","the reason is kept; the body does not advance")
        local wrong,g=visual_fixture()
        local ok2,why2=wrong:follow_visual(g.sample("2",1/60),1000,{steer=0})
        check(not ok2 and why2=="Invalid presentation pose for follow visuals" and #g.sets==0,"a partial pose is refused")
        local body,h=visual_fixture()
        local sample=h.sample("2",1/60);sample.mass=0
        local ok3,why3=body:follow_visual(sample,1000,pose_of(poses[2]))
        check(not ok3 and why3=="Invalid measured bike body for follow visuals","a bad body keeps its own reason")
    end)
    case("a new serial without a pose draws neutral",function()
        local owner,f=visual_fixture()
        owner:follow_visual(f.sample("2",1/60),1000,pose_of(poses[2]))
        table.clear(f.sets)
        local sample=f.sample("3",2/60)
        check(owner:follow_visual(sample,1017)==true and #f.sets==8,"drawn")
        local want=assert(Visual.from_sample(sample))
        for i,row in ipairs(f.sets) do for k=1,16 do check(same_number(row.matrix[k],want[i][k]),"neutral "..i.."["..k.."]") end end
        check(owner:status().posed_updates==1 and owner:status().visual_updates==2,"only the posed update is counted as posed")
    end)

    case("Core hands over Ride's pose, or none",function()
        check(Core.follow_pose(nil)==nil and Core.follow_pose({})==nil and Core.follow_pose("pose")==nil,"no Ride status, no pose")
        local pose=table.freeze(Visual.neutral())
        check(Core.follow_pose({presentation_pose=pose})==pose,"Ride's own frozen pose, shared")
    end)
    case("a refused follow visual names Spawn's reason",function()
        check(Core.follow_visual_stop("follow visual",{true,false,"Body left the 2 m spawn envelope",n=3})
            =="follow visual refused: Body left the 2 m spawn envelope","the reason is kept")
        check(Core.follow_visual_stop("initial follow visual",{true,false,"Invalid presentation pose for follow visuals",n=3})
            =="initial follow visual refused: Invalid presentation pose for follow visuals","the initial draw too")
        for _,r in ipairs({{false,"boom",n=2},{false,n=1},{true,false,n=2},{true,false,"",n=3},{true,false,7,n=3},{true,nil,n=2},"x"}) do
            check(Core.follow_visual_stop("follow visual",r)=="follow visual refused or cancelled","no reason, the plain text")
        end
    end)
    case("tracked Core draws the measured follow with no pose",function()
        local f,state=following_fixture()
        local out=f.tick()
        check(out.phase=="following" and #f.visuals==1 and f.visuals[1].n==2,"the handoff draws once, with no pose argument")
        for i=1,3 do
            out=f.tick(state.publish_at+16*i)
            check(out.phase=="following","still following")
        end
        check(#f.visuals==4,"one follow visual a following tick")
        for i=2,4 do
            local args=f.visuals[i]
            check(args.n==3 and args[3]==nil and type(args[1])=="table" and args[1].serial~=nil,
                "the same body read and a nil pose: no Ride, so neutral")
        end
    end)
    case("Core's stop names the refused follow visual",function()
        local f,state=following_fixture()
        f.tick()
        f.refuse_visual="Body left the 2 m spawn envelope"
        local out=f.tick(state.publish_at+16)
        check(out.stop_reason=="follow visual refused: Body left the 2 m spawn envelope","stop reason: "..tostring(out.stop_reason))
        local g=following_fixture()
        g.refuse_visual="Invalid measured bike body for follow visuals"
        local first=g.tick()
        check(first.stop_reason=="initial follow visual refused: Invalid measured bike body for follow visuals",
            "initial stop reason: "..tostring(first.stop_reason))
    end)
    return {cases=cases,assertions=assertions}
end
return table.freeze(Tests)

-- One constructed mathematical regression; no skater API or native fit claim.
local MP=require("./mounted_pose")
local Tests={}
local function distance(a,b)
    local n=0 for i=1,3 do n+=(a[i]-b[i])^2 end return math.sqrt(n)
end
function Tests.run()
    local assertions=0
    local function check(v,why) assertions+=1;assert(v,why) end
    local bike={root={0,0,0},rotation={0,0,0,1}}
    local rig={lengths={left_up_leg=.36,left_leg=.38}}
    local function plan(budget,articulation)
        local out,why=MP.compose({bike=bike,articulation=articulation or {crank_phase=0}},
            {rig=rig,max_fit=budget})
        check(out~=nil,"constructed short-leg pose composes: "..tostring(why))
        return out
    end
    -- Reuse the existing mounted-pose suite's short-leg fixture. Its raw
    -- reach projection is computed before max_fit is applied.
    local zero=plan(0)
    local fit=zero.diagnostics.fit
    check(fit>.01 and fit<.05,"constructed reach projection stays in its declared range")
    local epsilon=1e-6
    local below=plan(fit-epsilon)
    local at=plan(fit)
    local above=plan(fit+epsilon)
    check(below.diagnostics.fit_limited==true and at.diagnostics.fit_limited==false
        and above.diagnostics.fit_limited==false,"diagnostics retain the unchanged fit budget")
    check(math.abs(below.diagnostics.fit-fit)<1e-12 and math.abs(above.diagnostics.fit-fit)<1e-12,
        "raw reach projection is independent of its later movement budget")
    check(distance(below.targets.hips,at.targets.hips)<4*epsilon,
        "crossing max_fit cannot drop the whole pelvis correction")
    check(distance(at.targets.hips,above.targets.hips)<1e-12,
        "an adequate budget retains the full existing fit")
    local budget=.005
    local limited=plan(budget)
    local moved=distance(limited.targets.hips,zero.targets.hips)
    check(moved>budget*.9 and moved<=budget+1e-9,
        "a limited fit uses its existing displacement budget without exceeding it")
    check(limited.diagnostics.limbs.left_leg.clamped==true,
        "a too-short leg remains visibly reach-limited rather than stretched")
    check(limited.pose[MP.JOINTS.left_foot].place.position==nil,
        "the foot remains a turn on the end of its shin")
    for _,p in ipairs({below,at,above,limited}) do
        check(MP.validate_pose(p.pose),"bounded fitted pose retains the existing joint contract")
        check(p.diagnostics.hip_above_seat>=MP.STANCE.seat_clearance-1e-9,
            "the existing saddle floor still constrains the fitted hips")
        for i=1,2 do
            check(distance(p.targets.grips[i],zero.targets.grips[i])<1e-12
                and distance(p.targets.ankles[i],zero.targets.ankles[i])<1e-12,
                "fitting the pelvis does not move the bike's grip or pedal targets")
        end
    end
    local released=plan(budget,{crank_phase=.6,barspin=.5,tailwhip=-.5,
        release_left_hand=1,release_right_hand=1,release_left_foot=1,release_right_foot=1})
    for i=1,4 do check(released.targets.releases[i]==1,"bar/tail/one-hand release semantics stay intact") end

    -- The rider in a manual, on the default rig and bike: the hips back or forward by the physics' shift.
    local function pitched(degrees)
        local a=-math.rad(degrees)/2
        return {root={0,.3,0},rotation={math.sin(a),0,0,math.cos(a)}}
    end
    for _,row in ipairs({{shift=.16,degrees=20},{shift=-.04,degrees=36}}) do
        local rider=MP.manual_rider(row.shift)
        local out,why=MP.compose({bike=pitched(row.degrees),articulation={crank_phase=.4,steer=.05},rider=rider})
        check(out~=nil,"a manual's rider composes: "..tostring(why))
        local what=string.format("shift %.2f at %d degrees",row.shift,row.degrees)
        for i,name in ipairs({"left_arm","right_arm"}) do
            local miss=distance(out.planned[name].tip,out.targets.wrists[i])
            check(miss<.001,what..": the hand holds its grip: "..miss)
        end
        for i,name in ipairs({"left_leg","right_leg"}) do
            local miss=distance(out.planned[name].tip,out.targets.ankles[i])
            check(miss<1e-9,what..": the foot stays on its pedal: "..miss)
        end
        check(out.diagnostics.saddle_limited==false,what..": standing, the saddle does not hold the hips back")
        check(MP.validate_pose(out.pose),what..": the pose keeps the joint contract")
        local seat=MP.compose({bike=pitched(row.degrees),articulation={crank_phase=.4,steer=.05}})
        local moved=out.diagnostics.hip_local[3]-seat.diagnostics.hip_local[3]
        check(row.shift>0 and moved< -.1 or row.shift<0 and moved>.02,what..": the hips go the way the weight does: "..moved)
    end
    -- No shift is the ordinary rider, to the bit.
    local function same(a,b)
        if type(a)=="table" and type(b)=="table" then
            for k,v in a do if not same(v,b[k]) then return false end end
            for k in b do if a[k]==nil then return false end end
            return true
        end
        if typeof(a)=="vector" and typeof(b)=="vector" then return a.x==b.x and a.y==b.y and a.z==b.z end
        return a==b
    end
    local level={root={0,.3,0},rotation={0,0,0,1}}
    local still=MP.compose({bike=level,articulation={crank_phase=.4,steer=.05},rider=MP.manual_rider(0)})
    local ordinary=MP.compose({bike=level,articulation={crank_phase=.4,steer=.05}})
    check(same(still.pose,ordinary.pose) and same(still.targets,ordinary.targets),"a shift of 0 poses the ordinary rider exactly")
    -- A steady manual composes once and is mapped after, as ordinary riding is.
    local api={skater={pose=function(pose,weight)
        if weight==MP.PROBE_WEIGHT then error("place has a position, a rotation or both",0) end
        return true
    end}}
    local poser=MP.new(api)
    check(poser:mount(0).ok,"the poser mounts on a constructed skater.pose")
    for tick=1,120 do
        local shift=.16+.002*math.sin(tick/7)
        local r=poser:tick(tick/60,{bike=pitched(20),articulation={crank_phase=.4,steer=0},rider=MP.manual_rider(shift)})
        check(r.ok and r.sent,"a manual's pose is sent: "..tostring(r.reason))
    end
    local hits,misses=poser.memo_hits or 0,poser.memo_misses or 0
    check(hits+misses==120 and hits>=108,"a steady manual is mapped from its memo on 90% of its ticks: "..hits.." hits, "..misses.." misses")

    -- A manual's standing rider on a bike Ride draws up off a kerb: pitched about the steering pivot, lifted and
    -- shifted. Standing, the rider is composed in the drawn bike's frame, hands on the grips and feet on the pedals.
    local G=require("./bike_geometry")
    local Q=MP.math
    local C=MP.CONTACTS
    local function add(a,b) return {a[1]+b[1],a[2]+b[2],a[3]+b[3]} end
    local function sub(a,b) return {a[1]-b[1],a[2]-b[2],a[3]-b[3]} end
    -- Where bike_visual draws the bike for an articulation: turned about the steering pivot, then lifted along its up
    -- and shifted along its forward.
    local function drawn_frame(b,a)
        local whole=Q.axis_angle({1,0,0},a.movement_bike_pitch or 0)
        local c=G.steering_pivot
        local moved=add(sub(c,Q.turn(whole,c)),{0,a.movement_bike_lift or 0,a.movement_bike_shift or 0})
        return {root=add(b.root,Q.turn(b.rotation,moved)),rotation=Q.multiply(b.rotation,whole)}
    end
    local function local_of(b,p) return Q.turn(Q.conjugate(b.rotation),sub(p,b.root)) end
    local manual=pitched(30)
    local pitch,lift,shift=G.pitch_lift(G,0,.14)
    local kerbs={
        {name="drawn nose down about the front wheel, the rear 14 cm up",movement_bike_pitch=pitch,movement_bike_lift=lift,movement_bike_shift=shift},
        {name="lifted 14 cm off the ground at 30 degrees",movement_bike_lift=.14*math.cos(math.rad(30)),movement_bike_shift=.14*math.sin(math.rad(30))},
        {name="lifted 23 cm off the ground at 36 degrees",movement_bike_lift=.23*math.cos(math.rad(36)),movement_bike_shift=.23*math.sin(math.rad(36))},
    }
    for _,kerb in ipairs(kerbs) do
        local a={crank_phase=.4,steer=.05,movement_bike_pitch=kerb.movement_bike_pitch,movement_bike_lift=kerb.movement_bike_lift,
            movement_bike_shift=kerb.movement_bike_shift}
        local out,why=MP.compose({bike=manual,articulation=a,rider=MP.manual_rider(.2)})
        check(out~=nil,kerb.name..": the manual's rider composes: "..tostring(why))
        for i,name in ipairs({"left_arm","right_arm"}) do
            local side=i==1 and 1 or -1
            local planned=out.planned[name]
            local palm=add(planned.tip,Q.turn(planned.tip_rotation,{C.palm_reach,0,side*(C.grip_radius+C.palm_gap)}))
            local miss=distance(palm,out.targets.grips[i])
            check(miss<.01,kerb.name..": the "..name.." hand holds its grip: "..miss)
        end
        for i,name in ipairs({"left_leg","right_leg"}) do
            local miss=distance(out.planned[name].tip,out.targets.ankles[i])
            check(miss<.01,kerb.name..": the "..name.." foot stands on its pedal: "..miss)
        end
        -- The same rider on the bike set where it is drawn, nothing drawn on it: the whole rider goes with the bike.
        local frame=drawn_frame(manual,a)
        local still=MP.compose({bike=frame,articulation={crank_phase=.4,steer=.05},rider=MP.manual_rider(.2)})
        check(distance(out.targets.hips,still.targets.hips)<1e-6,kerb.name..": the hips go where the drawn bike carries them: "
            ..distance(out.targets.hips,still.targets.hips))
        local q,r=out.planned.hips.rotation,still.planned.hips.rotation
        check(math.abs(math.abs(q[1]*r[1]+q[2]*r[2]+q[3]*r[3]+q[4]*r[4])-1)<1e-9,kerb.name..": and turn with it")
        for _,name in ipairs({"left_arm","right_arm","left_leg","right_leg"}) do
            check(distance(out.planned[name].middle,still.planned[name].middle)<1e-6,kerb.name..": the "..name.." bends as on the bike undrawn")
        end
        -- Riding seated, the pelvis still carries .75 of the grips' move and all of the shift, as before.
        local seat=MP.compose({bike=manual,articulation=a})
        local level=MP.compose({bike=manual,articulation={crank_phase=.4,steer=.05}})
        local moved={0,0,0}
        for i=1,2 do moved=add(moved,sub(local_of(manual,seat.targets.grips[i]),local_of(manual,level.targets.grips[i]))) end
        local s=a.movement_bike_shift or 0
        local want={.375*moved[1],MP.STANCE.hip_height+.375*moved[2],MP.STANCE.hip_z+.375*(moved[3]-2*s)+s}
        check(distance(seat.diagnostics.hip_wanted,want)<1e-9,kerb.name..": a seated rider's hips are carried as they were")
    end
    -- Standing behind the saddle there is none under the hips: low, they are not pushed back up to its floor.
    local crouched=MP.compose({bike=manual,articulation={crank_phase=.4,steer=.05},rider={standing=1,hip_offset={0,-.2,-.3}}})
    check(crouched.diagnostics.seat_limited==false and crouched.diagnostics.hip_local[2]<crouched.diagnostics.seat_floor-.05,
        "a standing rider's hips 30 cm behind the saddle are not held at its floor: "..crouched.diagnostics.hip_local[2])
    local sitting=MP.compose({bike=manual,articulation={crank_phase=.4,steer=.05},rider={hip_offset={0,-.2,0}}})
    check(sitting.diagnostics.seat_limited==true and sitting.diagnostics.hip_above_seat>=MP.STANCE.seat_clearance,
        "over the saddle the floor still holds them")

    -- A standing rider's hips moved back past the saddle's back edge a millimetre at a time, wanted from 15 cm under
    -- its top to 12 cm over it: the floor behind the saddle is continuous, so the hips never jump. It dropped from
    -- the saddle's top to nothing at the margin's distance behind it, 16 cm for 1 mm of travel. The knee floor has
    -- its own slope, up to 6 mm for 1 mm with the hips that low, so it is held off here: no fit, and the least fold
    -- the options take.
    local saddle=MP.options().geometry.saddle
    local margin=sitting.diagnostics.seat_floor-saddle.top
    local steepest,nearest,raised=0,math.huge,0
    for crank=0,6,.3 do
        for _,wanted in ipairs({-.15,-.08,-.03,0,.03,.08,.12}) do
            local last
            for i=0,300 do
                local z=saddle.rear+.01-i*.001
                local out=MP.compose({bike=bike,articulation={crank_phase=crank,steer=0},
                    rider={standing=1,hip_offset={0,saddle.top+wanted-MP.STANCE.hip_height,z-MP.STANCE.hip_z}}},{max_fit=0,min_knee=.35})
                raised=math.max(raised,out.diagnostics.knee_raise)
                local hip=out.diagnostics.hip_seat
                if last then steepest=math.max(steepest,math.abs(hip[2]-last)) end
                last=hip[2]
                -- Behind the saddle the pelvis still clears its back edge by the margin.
                if hip[3]<saddle.rear then nearest=math.min(nearest,math.sqrt((hip[2]-saddle.top)^2+(hip[3]-saddle.rear)^2)) end
            end
        end
    end
    check(raised==0,"the knee floor is held off: "..raised)
    check(steepest<.0015,"a standing rider's hips behind the saddle move at most 1.5 mm up or down for 1 mm back: "..steepest)
    check(nearest>=margin-1e-9,"and clear the saddle's back edge by the margin: "..nearest.." against "..margin)

    -- The rider in a nose manual: hips up over the bars, not toward them, so the knees clear the bars at every crank
    -- phase. With no nose, or none given, it is the manual's rider exactly.
    for _,row in ipairs({{.16,1},{-.12,1},{-.2,.5},{0,nil},{.3,.25}}) do
        local plain=MP.manual_rider(row[1],row[2])
        check(same(plain,MP.manual_rider(row[1],row[2],nil)) and same(plain,MP.manual_rider(row[1],row[2],0)),
            "no nose is the manual's rider: "..row[1])
    end
    for _,bad in ipairs({-.1,1.1,0/0,"x"}) do
        local r,why=MP.manual_rider(-.2,1,bad)
        check(r==nil and why=="the rider's nose is 0 to 1","a nose outside 0 to 1 is refused: "..tostring(bad).." "..tostring(why))
    end
    local up=MP.manual_rider(-.2,1,1)
    check(up.hip_offset[1]==0 and math.abs(up.hip_offset[2]-.08)<1e-12 and up.hip_offset[3]==0
        and math.abs(up.lean-(MP.STANCE.lean+.16))<1e-12 and up.standing==1,"all the way on the nose the hips go up, not forward")
    local half=MP.manual_rider(-.2,1,.5)
    check(math.abs(half.hip_offset[2]-.04)<1e-12 and math.abs(half.hip_offset[3]-.12)<1e-12,"half way, half of each")
    check(same(MP.manual_rider(.16,1,1),MP.manual_rider(.16,1,0)),"a back shift takes no part of the nose")
    -- Each forward shift on the bike pitched nose down as far as it holds it (the weight's offset behind the front
    -- contact is .8196 cos(pitch + 51 degrees), scaled bike), at 24 crank phases: the hands on the grips, the feet on
    -- the pedals, no limb out of reach, and the knees, thighs and shins at least 9 cm off the bar line (grip to grip,
    -- less the bar's radius), the torso at least 30 cm. Drawn toward the bars instead, the knees met them: 6 mm
    -- into the bar at a .10 shift, 2 mm at .12.
    local function segment(p1,q1,p2,q2)
        local d1,d2,r=sub(q1,p1),sub(q2,p2),sub(p1,p2)
        local function dot(a,b) return a[1]*b[1]+a[2]*b[2]+a[3]*b[3] end
        local a,e,f=dot(d1,d1),dot(d2,d2),dot(d2,r)
        local s,t
        if a<=1e-12 then s=0;t=math.clamp(f/e,0,1)
        else
            local c=dot(d1,r)
            local b=dot(d1,d2)
            local den=a*e-b*b
            s=den~=0 and math.clamp((b*f-c*e)/den,0,1) or 0
            t=(b*s+f)/e
            if t<0 then t=0;s=math.clamp(-c/a,0,1) elseif t>1 then t=1;s=math.clamp((b-c)/a,0,1) end
        end
        return distance(add(p1,{d1[1]*s,d1[2]*s,d1[3]*s}),add(p2,{d2[1]*t,d2[2]*t,d2[3]*t}))
    end
    local bar_radius=.055*G.scale
    local legs,torso,palm_miss,ankle_miss=math.huge,math.huge,0,0
    for _,f in ipairs({.06,.10,.12,.13,.15,.18,.20,.22,.23,.25,.27,.30}) do
        local degrees=math.deg(math.acos(f/.8196))-51
        local a=math.rad(degrees)
        local bike={root={0,.3,0},rotation={math.sin(a/2),0,0,math.cos(a/2)}}
        local function bike_local(p) return Q.turn(Q.conjugate(bike.rotation),sub(p,bike.root)) end
        for phase=0,23 do
            local out,why=MP.compose({bike=bike,articulation={crank_phase=phase/24*2*math.pi,steer=0},rider=MP.manual_rider(-f,1,1)})
            check(out~=nil,"a nose manual's rider composes: "..tostring(why))
            check(MP.validate_pose(out.pose),"and keeps the joint contract")
            for i,name in ipairs({"left_arm","right_arm"}) do
                local side=i==1 and 1 or -1
                local planned=out.planned[name]
                local palm=add(planned.tip,Q.turn(planned.tip_rotation,{C.palm_reach,0,side*(C.grip_radius+C.palm_gap)}))
                palm_miss=math.max(palm_miss,distance(palm,out.targets.grips[i]))
                check(not out.diagnostics.limbs[name].clamped,"the "..name.." reaches its grip")
            end
            for i,name in ipairs({"left_leg","right_leg"}) do
                ankle_miss=math.max(ankle_miss,distance(out.planned[name].tip,out.targets.ankles[i]))
                check(not out.diagnostics.limbs[name].clamped,"the "..name.." reaches its pedal")
                local p=out.planned[name]
                local hip,knee,ankle=bike_local(p.root),bike_local(p.middle),bike_local(p.tip)
                legs=math.min(legs,segment(knee,knee,G.right_grip,G.left_grip)-bar_radius,
                    segment(hip,knee,G.right_grip,G.left_grip)-bar_radius,segment(knee,ankle,G.right_grip,G.left_grip)-bar_radius)
            end
            local shoulders=bike_local({(out.planned.left_arm.root[1]+out.planned.right_arm.root[1])/2,
                (out.planned.left_arm.root[2]+out.planned.right_arm.root[2])/2,(out.planned.left_arm.root[3]+out.planned.right_arm.root[3])/2})
            torso=math.min(torso,segment(bike_local(out.targets.hips),shoulders,G.right_grip,G.left_grip)-bar_radius)
        end
    end
    check(palm_miss<=1e-4 and ankle_miss<=1e-4,string.format("the hands hold their grips and the feet their pedals: %.6f %.6f",palm_miss,ankle_miss))
    check(legs>=.09,string.format("the knees, thighs and shins stay %.3f off the bars at every hold and crank phase",legs))
    check(torso>=.3,string.format("and the torso %.3f",torso))

    -- The bars at the walk's full lock (forces.lua walk_lock, 32 degrees), either way, seated on a level bike at 24
    -- crank phases: both hands hold their grips with no arm stretched, the near hand, whose wrist is at its bend limit
    -- there, turns no more than 15 degrees short of its grip, and the knees, thighs and shins keep 5 cm off the bar line
    -- (7.4 cm at the old full lock, .4 rad). Against the bike's own mesh the knee joint is 12 cm from the bars there.
    local walk=require("./forces").tuning().walk_lock
    local level={root={0,.3,0},rotation={0,0,0,1}}
    local function level_local(p) return sub(p,level.root) end
    local short,reach_miss,bar_legs,clamped=0,0,math.huge,false
    for _,steer in ipairs({walk,-walk}) do
        for phase=0,23 do
            local out,why=MP.compose({bike=level,articulation={crank_phase=phase/24*2*math.pi,steer=steer}})
            check(out~=nil,"the rider composes with the bars at the walk's lock: "..tostring(why))
            local grips={level_local(out.targets.grips[1]),level_local(out.targets.grips[2])}
            for i,name in ipairs({"left_arm","right_arm"}) do
                local side=i==1 and 1 or -1
                local planned=out.planned[name]
                local palm=add(planned.tip,Q.turn(planned.tip_rotation,{C.palm_reach,0,side*(C.grip_radius+C.palm_gap)}))
                reach_miss=math.max(reach_miss,distance(palm,out.targets.grips[i]))
                clamped=clamped or out.diagnostics.limbs[name].clamped
                local a,b=planned.tip_rotation,out.targets.hands[i]
                short=math.max(short,math.deg(2*math.acos(math.min(1,math.abs(a[1]*b[1]+a[2]*b[2]+a[3]*b[3]+a[4]*b[4])))))
            end
            for _,name in ipairs({"left_leg","right_leg"}) do
                local p=out.planned[name]
                local hip,knee,ankle=level_local(p.root),level_local(p.middle),level_local(p.tip)
                bar_legs=math.min(bar_legs,segment(hip,knee,grips[1],grips[2])-bar_radius,segment(knee,ankle,grips[1],grips[2])-bar_radius)
            end
        end
    end
    check(not clamped and reach_miss<=1e-4,string.format("at the walk's lock both hands hold their grips: %.6f",reach_miss))
    check(short<=15,string.format("the near hand turns %.1f degrees short of its grip",short))
    check(bar_legs>=.05,string.format("the knees, thighs and shins stay %.3f off the bars",bar_legs))
    return {cases=6,assertions=assertions}
end
return table.freeze(Tests)

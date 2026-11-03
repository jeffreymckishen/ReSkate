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
    return {cases=3,assertions=assertions}
end
return table.freeze(Tests)

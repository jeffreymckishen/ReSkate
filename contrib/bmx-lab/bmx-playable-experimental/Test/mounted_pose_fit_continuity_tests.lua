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
    return {cases=1,assertions=assertions}
end
return table.freeze(Tests)

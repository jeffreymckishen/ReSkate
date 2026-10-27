-- Authored limb/torso contracts only. Uses the runner's existing qualified current-source fixture.
-- No historical implementation is embedded/imported. A separate 17ba468f -> candidate differential
-- and the optional timing_gate below must run in coordinator-owned isolated staging before claims.
local MP = require("./mounted_pose")
local Q = require("./mounted_pose_qualified_fixture")
local PT = require("./pose_targets")
local Catalog = require("./catalog")
local G = require("./bike_geometry")
local cases, assertions = 0, 0
local function check(ok, message)
    assertions += 1
    if not ok then error(message or "check failed", 2) end
end
local function test(name, fn)
    cases += 1
    local ok, why = pcall(fn)
    if not ok then error(name .. ": " .. tostring(why), 0) end
end
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in v do out[k] = copy(x) end
    return out
end
local function add(a, b) return {a[1]+b[1], a[2]+b[2], a[3]+b[3]} end
local function sub(a, b) return {a[1]-b[1], a[2]-b[2], a[3]-b[3]} end
local function mul(a, k) return {a[1]*k, a[2]*k, a[3]*k} end
local function len(a) return math.sqrt(a[1]^2+a[2]^2+a[3]^2) end
local function near(a, b, tolerance) check(len(sub(a,b)) <= (tolerance or 1e-7), "points differ") end
local function exact(a, b)
    check(type(a) == type(b), "different value types")
    if type(a) == "table" then
        for k, v in a do exact(v, b[k]) end
        for k in b do check(a[k] ~= nil, "different output fields") end
    else
        check(a == b, "not bit-identical")
    end
end
local HEAD = {head = {rotation = {.5,.5,.5,.5}, follow = .3}}
local KEYS = {"left_hand", "right_hand", "left_foot", "right_foot"}
local LIMBS = {"left_arm", "right_arm", "left_leg", "right_leg"}
local function input()
    return {bike = {root = {0,0,0}, rotation = {0,0,0,1}}, articulation = {steer = .12, crank_phase = .6}}
end
local function family_input(id, phase)
    local sample, why = PT.sample(id, phase)
    check(sample ~= nil, why)
    local i = input()
    i.limb_targets, i.torso = sample.limb_targets, sample.torso
    for n, key in KEYS do
        i.articulation["release_" .. key] = math.floor(sample.release_mask / 2^(n-1)) % 2 == 1 and phase or 0
    end
    return i, sample
end
local function compose(i, options)
    local plan, why = MP.compose(i, options or HEAD)
    check(plan ~= nil, why)
    local valid, invalid = MP.validate_pose(plan.pose)
    check(valid, invalid)
    return plan
end
local function fake()
    local f = {sends=0, ends=0}
    f.api = {skater = {pose = function(pose, weight)
        if pose == nil then f.ends += 1 return true end
        if weight == 2 then error("place has a position, a rotation or both", 0) end
        f.sends += 1
        return true
    end}}
    return f
end
local function plan_tick(p, now, i)
    local out = p:tick(now, i)
    check(out.ok and out.sent and out.plan, out.reason)
    return out.plan
end
local function run()
    cases, assertions = 0, 0
    test("absent targets retain the existing pose shape and ownership", function()
        local i = input()
        local plan = compose(i, {})
        check(plan.count == 13 and plan.diagnostics.torso_request == nil)
        check(plan.pose[MP.JOINTS.hips].place.relative_to == "world")
        for _, limb in MP.LIMBS do
            check(plan.pose[MP.JOINTS[limb.tip]].place.position == nil, "tips remain rotation-only")
            check(plan.diagnostics.limbs[limb.name].authored_endpoint == nil)
            check(plan.targets.held_hands ~= nil and plan.targets.free_feet ~= nil)
        end
        local again = compose(copy(i), {})
        exact(plan, again)
        plan.targets.ankles[1][1] = 99
        check(again.targets.ankles[1][1] ~= 99, "results own their arrays")
        -- This checks determinism/current invariants, NOT the still-unrun historical differential.
    end)
    test("valid zero-release targets do not change a single base value", function()
        local i = input()
        local base = compose(i)
        i.limb_targets = {left_hand={direction={1,0,0},reach=.6}, left_foot={direction={0,-1,0},reach=.8}}
        exact(base, compose(i))
    end)
    test("all existing family endpoints resolve inside their final socket reach", function()
        for id=0,77 do if Catalog.name(id) then
            for _, phase in {0,.5,1} do
                local i, sample = family_input(id, phase)
                local plan = compose(i)
                for n, key in KEYS do if sample.limb_targets and sample.limb_targets[key] and phase > 0 then
                    local p, d = plan.planned[LIMBS[n]], plan.diagnostics.limbs[LIMBS[n]]
                    check(d.authored_endpoint ~= nil and d.target_blend == phase, "active target diagnostic")
                    check(len(sub(p.tip,p.root)) <= d.limit+1e-7, "solved tip cannot stretch a bone")
                    if phase == 1 then
                        near(p.tip, d.authored_endpoint)
                        check(not d.clamped, "full authored endpoint must be reachable")
                    end
                    if n <= 2 then check(d.swing_degrees <= MP.STANCE.max_wrist_bend*180/math.pi+1e-5, "wrist limit") end
                end end
            end
        end end
    end)
    test("Can Nac and One Footer have distinct final ankles on each side", function()
        for _, pair in {{ids={61,63,66},limb="left_leg"},{ids={77,75,72},limb="right_leg"}} do
            local points = {}
            for _, id in pair.ids do
                local i = family_input(id,1)
                points[#points+1] = compose(i).planned[pair.limb].tip
            end
            for a=1,3 do for b=a+1,3 do check(len(sub(points[a],points[b])) >= .10, "three authored foot families need 10 cm separation") end end
        end
    end)
    test("released orientations do not follow the held bar or pedal seed", function()
        local options=copy(HEAD)
        options.max_wrist_bend=math.pi -- isolates the existing release rotation from the later wrist cap
        for _, row in {
            {channel="barspin",angle=.25,release="release_left_hand",limb="left_hand",group="hands",free="free_hands"},
            {channel="tailwhip",angle=.05,release="release_left_foot",limb="left_foot",group="feet",free="free_feet"},
            {channel="barspin",angle=math.pi/2,release="release_left_hand",limb="left_hand",group="hands",free="free_hands"},
            {channel="tailwhip",angle=math.pi/2,release="release_left_foot",limb="left_foot",group="feet",free="free_feet"},
        } do
            for _, release in {0,.5,1} do
                local i=input()
                i.articulation[row.channel],i.articulation[row.release]=row.angle,release
                local base=compose(i,options)
                i.limb_targets={[row.limb]={direction={.3,-.8,-.4},reach=.7}}
                local result=compose(i,options)
                exact(result.targets[row.group][1],base.targets[row.group][1])
                exact(result.targets[row.free][1],base.targets[row.free][1])
                if release==1 then
                    -- slerp at one normalizes; equivalent rotations may differ by final rounding.
                    local dot=0
                    for n=1,4 do dot += result.targets[row.group][1][n]*base.targets[row.free][1][n] end
                    check(math.abs(math.abs(dot)-1)<1e-7,"fully free orientation stays in the bike frame")
                end
            end
        end
    end)
    test("targets follow bike transform rather than world axes", function()
        local i = family_input(66,1)
        local base = compose(i)
        local q = MP.math.axis_angle({0,1,0},.8)
        local root = {3,7,-2}
        i.bike = {root=root,rotation=q}
        local moved = compose(i)
        for _, limb in MP.LIMBS do
            near(moved.planned[limb.name].tip, add(root,MP.math.turn(q,base.planned[limb.name].tip)),1e-6)
        end
    end)
    test("annulus crossing stays clamped and distinguishes desired from solved", function()
        local options = {max_fit=0,min_knee=.35,rig={lengths={left_up_leg=1,left_leg=.04}}}
        local i = input()
        i.articulation.steer, i.articulation.crank_phase = 0,0
        i.articulation.release_left_foot = .5
        local seed = compose(i,options)
        local o = assert(MP.options(options))
        local held = add(G.pedals[1],add(o.geometry.pedal_offset[1],{0,MP.CONTACTS.ankle_from_sole,0}))
        local delta = sub(held,seed.planned.left_leg.root)
        local distance = len(delta)
        local margin = .0001
        local near_limit,far_limit = .96+margin,1.04-margin
        local held_reach = math.clamp(distance,near_limit,far_limit)
        i.limb_targets = {left_foot={direction=mul(delta,-1/distance),reach=(held_reach-near_limit)/(far_limit-near_limit)}}
        local result = compose(i,options)
        local d, p = result.diagnostics.limbs.left_leg,result.planned.left_leg
        check(d.clamped and d.requested < 1e-6, "half blend crosses the inner hole")
        check(len(sub(p.tip,p.root)) >= near_limit-1e-7, "original IK clamp is retained")
        check(len(sub(result.targets.ankles[1],p.tip)) > .9, "requested and solved positions stay distinguishable")
    end)
    test("limb data is copied and no optional result can poison the next solve", function()
        local i = family_input(61,1)
        local p = compose(i)
        local pristine = copy(p)
        i.limb_targets.left_foot.direction[1] += .1
        local changed = compose(i)
        exact(p,pristine)
        check(len(sub(changed.planned.left_leg.tip,p.planned.left_leg.tip)) > 1e-4)
        p.diagnostics.torso_request.pelvis[1] = 99
        p.diagnostics.limbs.left_leg.authored_endpoint[1] = 99
        p.targets.free_ankles[1][1] = 99
        local next_plan = compose(i)
        exact(changed,next_plan)
    end)
    test("optional requests bypass the private exact-angle cache", function()
        local f = fake()
        local poser = Q.new(f.api,HEAD)
        check(poser:mount(0).ok)
        local neutral = input()
        plan_tick(poser,0,neutral)
        plan_tick(poser,.02,neutral)
        check(poser.memo_hits == 1 and poser.memo_misses == 1)
        local active = family_input(66,1)
        local first = plan_tick(poser,.04,active)
        active.limb_targets.left_foot.direction[3] += .05
        local changed = plan_tick(poser,.06,active)
        check(poser.memo_hits == 1 and poser.memo_misses == 1, "no reuse of active target data")
        check(len(sub(first.planned.left_leg.tip,changed.planned.left_leg.tip)) > 1e-4)
        plan_tick(poser,.08,neutral)
        check(poser.memo_misses == 2, "old neutral entry was cleared")
    end)
    test("torso weighting is bounded and the head needs calibration", function()
        local i = input()
        i.torso = {weight=.5,pelvis={0,.02,-.03},pitch=.2,head_yaw=.3}
        local p = compose(i)
        local equivalent = input()
        equivalent.rider = {lean=MP.STANCE.lean+.1,hip_offset={0,.01,-.015}}
        local e = compose(equivalent)
        near(p.planned.hips.position,e.planned.hips.position)
        exact(p.planned.hips.rotation,e.planned.hips.rotation)
        local expected = MP.math.multiply(MP.math.axis_angle({0,1,0},.3*i.articulation.steer+.15),HEAD.head.rotation)
        local dot=0
        for n=1,4 do dot += p.planned.head.rotation[n]*expected[n] end
        check(math.abs(math.abs(dot)-1) < 1e-7, "head yaw in its calibrated frame")
        local refused, why = MP.compose(i,{})
        check(refused == nil and string.find(why,"calibrated",1,true) ~= nil)
        i.torso.weight = 0
        check(MP.compose(i,{}) == nil, "zero weight cannot admit uncalibrated head data")
    end)
    test("invalid optional data refuses even at zero release or weight", function()
        local nan = 0/0
        local bad = {
            {limb_targets=false}, {limb_targets={unknown={direction={1,0,0},reach=.5}}},
            {limb_targets={left_hand={direction={0,0,0},reach=.5}}},
            {limb_targets={left_hand={direction={nan,0,0},reach=.5}}},
            {limb_targets={left_hand={direction={[1]=1,[3]=0},reach=.5}}},
            {limb_targets={left_hand={direction={1,0,0,4},reach=.5}}},
            {limb_targets={left_hand={direction={1,0,0},reach=1.1}}},
            {limb_targets={left_hand={direction={1,0,0},reach=nan}}},
            {limb_targets={left_hand={direction={1,0,0},reach=.5,other=0}}},
            {limb_targets=setmetatable({}, {})}, {torso=false}, {torso={}},
            {torso={weight=0,other=0}}, {torso={weight=-1}}, {torso={weight=nan}},
            {torso={weight=0,pitch=math.huge}}, {torso={weight=0,head_yaw=1.3}},
            {torso={weight=0,pelvis={.21,0,0}}}, {torso={weight=0,pelvis={0,0}}},
            {torso=setmetatable({weight=0},{})},
        }
        for _, fields in bad do
            local i = input()
            for k,v in fields do i[k] = v end
            local plan, why = MP.compose(i,HEAD)
            check(plan == nil and type(why) == "string", "malformed request must refuse")
        end
        local i=input()
        i.rider={lean=1.1}
        i.torso={weight=1,pitch=.2}
        check(MP.compose(i,HEAD) == nil, "combined lean remains bounded")
        i.rider={hip_offset={.45,0,0}}
        i.torso={weight=1,pelvis={.1,0,0}}
        check(MP.compose(i,HEAD) == nil, "combined offset remains bounded")
    end)
    test("bad active requests end exactly once and qualification stays closed", function()
        local f=fake()
        local p=Q.new(f.api,HEAD)
        check(p:mount(0).ok)
        local i=family_input(66,1)
        plan_tick(p,0,i)
        i.limb_targets.left_foot.reach = 2
        local refused=p:tick(.02,i)
        check(not refused.sent and not refused.ok and refused.ended and f.ends == 1)
        p:stop() p:stop()
        check(f.ends == 1)
        local gated=MP.new(f.api,HEAD)
        check(not MP.QUALIFIED and not gated:mount(0).sent and not gated:tick(0,input()).sent)
        check(f.sends == 1, "production gate sent nothing")
    end)
    return {cases=cases,assertions=assertions,native_calls=0,game_evidence=false,historical_nil_comparison=false}
end

-- An explicit coordinator-run measurement, never an implicit substitute for whole-plugin timing.
-- 220 us is the existing pose target in the plan; the result must be reported even when over it.
local function timing_gate(iterations)
    iterations = iterations or 200
    assert(type(iterations)=="number" and iterations%1==0 and iterations>=20 and iterations<=2000,"iterations20..2000")
    local options=assert(MP.options(HEAD))
    local max_mean=0
    local rows={}
    for _, id in {7,11,20,27,35,51,61,63,66} do
        local i=family_input(id,1)
        for _=1,10 do assert(MP.compose(i,options)) end
        local start=os.clock()
        for _=1,iterations do assert(MP.compose(i,options)) end
        local mean=(os.clock()-start)/iterations
        rows[#rows+1]={id=id,seconds_per_compose=mean}
        max_mean=math.max(max_mean,mean)
    end
    return {rows=rows,max_mean_seconds=max_mean,limit_seconds=.000220,passed=max_mean<=.000220,
        native_calls=0,whole_plugin_budget_verified=false}
end
return {run=run,timing_gate=timing_gate}

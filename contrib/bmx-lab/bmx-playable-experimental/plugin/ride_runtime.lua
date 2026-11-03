-- Inactive subordinate: Core alone owns Source, body, Follow and lifecycle.
-- Construction and observation make no native calls while this literal is false.
local ACTIVATION_QUALIFIED = true
local Mapping = require("./ride_input_mapping")
local Forces = require("./forces")
local M = require("./force_math")
local Identity = require("./lease_identity")
local Geometry = require("./bike_geometry")
local InFlight = require("./ride_inflight")
local TrickAdapter = require("./trick_adapter")
local ModScore = require("./score_runtime")
local MeasuredLanding = require("./measured_landing")
local Ride, Object = {}, {}
local states = setmetatable({}, {__mode="k"})
local MAX_SAFE = 9007199254740991
local MAX_PENDING = 3
-- The rider tripwire's cadence in measured epochs: every second one.
local TRIPWIRE_EVERY = 2
local METRIC_SAMPLE_LIMIT, METRIC_TRANSITION_LIMIT = 24, 16
local METRIC_STOP_REASON_LIMIT, METRIC_STOP_KEY_BYTES = 8, 1024
-- Stop measured bodies outside playable tilt or local-roll bounds. The old
-- 15 deg/1 rad/s lab bounds clipped normal kernel lean (about 27 deg) and
-- steering reversals (about 1.6 rad/s). These fixed limits retain a
-- measured-body stop beyond ordinary riding. Roll rate is read before any
-- query. Tilt needs the wheel rays, because a ramp is not a fall.
local TILT_STOP_DEG = 55
-- A body this far from both world up and the surface under a wheel, for this
-- many steps, has fallen. The steps let a bike be saved, or really go down,
-- rather than the ride cutting off half way over.
local FALL_SURFACE_DEG, FALL_STEPS = 65, 18
-- With no surface under a wheel, a ramp can throw a body past TILT_STOP_DEG.
-- It gets a second and a half to come back, and no further than this.
local AIR_TILT_STOP_DEG, UNSUPPORTED_TILT_STEPS = 120, 90
-- A wheel ray that lands this far under the tyre has met a step the bike is
-- riding onto, not a wall. Flat tops get more, because a kerb is flat. The
-- row keeps its true depth and pushes from a depth the kernel admits.
local HELD_DEPTH, HELD_FLOOR, HELD_FLAT_FLOOR = .095, .19, .24
-- Such a wheel climbs out at the kernel's recovery rate, .25 to .6 s on a kerb, and a hard landing sinks one a few
-- centimetres. The bike is drawn with each wheel lifted out of what its ray measured, presentation alone: the
-- body, its rays and every force stay where they are, and the rider's hands and feet go with the bars and pedals
-- drawn. The first centimetre is left, as a rolling tyre is drawn about 5 mm into the road, so ordinary riding
-- draws nothing. A drawn wheel moves at most this fast, in m/s, so a ray that drops out for a step does not flicker it.
-- Nor is a rise under LIFT_LEAST drawn: the kernel's spring holds a wheel no deeper than its 15 mm maximum deflection
-- (forces.lua landing), and in a manual the rear alone carries the weight and sinks 10.4 mm, just past the slack.
-- Drawn, that published a sub-millimetre lift every step, and the rider was composed afresh every tick, never mapped
-- from its memo (mounted_pose.lua compose_memo): 380 to 480 us a tick against 40 to 85.
-- The drawn bike is lifted along the ground's normal, which in a manual stands 20 to 36 degrees from the bike's own
-- up; LIFT_TILT bounds that direction, past any manual.
local LIFT_SLACK, LIFT_RATE, LIFT_LEAST, LIFT_TILT = .01, 3, .005, math.rad(45)
-- A tyre that strikes a kerb loses speed to it, where the held row alone lifted the wheel and let it roll on as if
-- the kerb were not there. A wheel whose gap closes by CURB_STEP or more onto a flat top (normal up at least
-- CURB_FLAT), rolled or hopped into it, has struck a step that high: the least of how far its gap closed, how far
-- the ground came up and how far the tyre is into it, at the step's end and halfway through. It costs this share of
-- the speed along the ground per wheel radius of step, up to the whole radius, paid against the travel at no more
-- than CURB_FORCE a step. The share is a feel value, not a measured one: 15 cm at 7.4 m/s costs 1 m/s a wheel.
local CURB_STEP, CURB_FLAT, CURB_SHARE, CURB_FORCE = .025, .95, .25, 5400
-- Speed lost along the travel over this many steps. ForceStage's caps take at
-- most 3.8 m/s over them, on a landing, so this much is the world stopping the
-- body: a pillar took 7.5 m/s in two steps, and left the rider sitting on a
-- bike with its nose against it and no way back.
local HIT_DROP, HIT_STEPS = 4, 2
-- The rider's weight carries on over the bars. The bike pitches nose down at
-- this rate per m/s of the hit, up to the limit, on this much torque (ForceStage
-- keeps 2000 of the 4000 N*m a packet may carry). The ride ends this far over,
-- where the game's own fall takes the rider, or after this many steps if
-- whatever the bike hit will not let it go over. Ended level, the rider just
-- stood up beside the pillar.
local CRASH_RATE, CRASH_RATE_LIMIT, CRASH_TORQUE = .5, 4, 1900
local CRASH_TILT_DEG, CRASH_STEPS = 75, 60
-- What the bike's own body rolls through and the rider does not: a parked car. Ridden into one at 7.6 m/s, the
-- rider stopped dead at the bumper and the bike went on 3.9 m through it. Rays ahead along the travel, at the
-- rider's knees and either side of them, on the wheels' own lane, saw the car's front from 6 m out. Each lane is
-- across, height, and how far the bike reaches in it from its origin: the front tyre in the middle, the bar ends
-- either side. A ray starts this far behind that, so a face pressed against the bike is still seen.
local AHEAD_RAYS = {{0,.5,.73},{-.28,.5,.36},{.28,.5,.36}}
local AHEAD_BEHIND, AHEAD_MIN, AHEAD_MAX = .13, 1, 6
-- A face is steep against the bike's own up and against the ground under the front wheel, and it faces the bike
-- more than this: a wall met at a glance is ridden along. A ray low along the road in front of the tyre finds a
-- ramp or a tight quarter pipe the bike will roll onto before it reaches what the high rays see, and then they
-- see the same curve further up, not a wall.
local AHEAD_FACE_UP, AHEAD_FACING = .5, .25
local AHEAD_LOW = {0,.15,.73}
-- The stop is the landing law turned sideways, on the forecast this step's command acts on: closing speed is let
-- through down to what this deceleration can still take out before the face, on at most this force. At a face it
-- bounces back this share of the speed, so the bike can steer away, and pedalling stops within the pedal gap.
-- Closing as fast as a hit (HIT_DROP) when the braking starts is a crash once the front reaches the face, as a
-- wall would make it; a hop or a turn that takes the rays off the face first lets the ride go on.
local AHEAD_DECEL, AHEAD_FORCE, AHEAD_REBOUND, AHEAD_PEDAL_GAP = 45, 5400, .25, .25
-- Going over the bars, the tyre jammed at the face stops the bike there while it is this near the face.
local AHEAD_HOLD_REACH = 2.5
-- Steps in a row the force model may refuse before Ride stops: a second and a half.
local MAX_REFUSED_STEPS = 90
local ROLL_STOP_RATE = 14
-- Authored display gearing for the drawn cranks: ride_composer's
-- Composer.crank_ratio (a 25/9 BMX drive), written here so Ride does not load
-- the composer; ride_runtime_presentation_tests pins the two together. Only
-- the presentation pose reads it.
local CRANK_RATIO = 25 / 9
local TAU = 2 * math.pi
-- The most the rider shifts the weight in a manual, forward and back (forces.lua manual_hold_forward and
-- manual_hold_back), and how long the drawn shift takes to follow the physics'.
local RIDER_SHIFT_FORWARD, RIDER_SHIFT_BACK, RIDER_SHIFT_SECONDS = .15, .20, .1

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do
        if type(child) == "table" then result[key] = copy(child) else result[key] = child end
    end
    return result
end
-- Tables frozen whole by freeze or detached: frozen, with no metatable, and
-- every table inside them frozen whole too, so none of them can change.
-- detached shares them instead of copying; a status, frame or staged input
-- copied each step was most of Ride's own cost (S1 profile).
local whole = setmetatable({}, {__mode="k"})
local function freeze(value)
    if type(value) ~= "table" or whole[value] then return value end
    local all = getmetatable(value) == nil
    for _, child in pairs(value) do
        freeze(child)
        if type(child) == "table" and not whole[child] then all = false end
    end
    if not table.isfrozen(value) then table.freeze(value) end
    if all then whole[value] = true end
    return value
end
-- A table its maker froze all through, with no metatable anywhere, is marked
-- whole as it is, without freezing or copying anything; otherwise nil.
local function frozen_whole(value)
    if whole[value] then return value end
    if type(value) ~= "table" or not table.isfrozen(value) or getmetatable(value) ~= nil then return nil end
    for _, child in pairs(value) do
        if type(child) == "table" and not frozen_whole(child) then return nil end
    end
    whole[value] = true
    return value
end
-- The same tables as freeze(copy(value)), except that what is already frozen
-- whole is shared rather than copied.
local function detached(value)
    if type(value) ~= "table" then return value end
    if whole[value] then return value end
    local result = {}
    for key, child in pairs(value) do
        if type(child) == "table" then result[key] = detached(child) else result[key] = child end
    end
    table.freeze(result)
    whole[result] = true
    return result
end
local function detail(value) return string.sub(tostring(value or "unavailable"), 1, 180) end
local function wrap(angle)
    angle %= TAU
    if angle > math.pi then angle -= TAU end
    return angle
end
-- The bike's articulation, as bike_visual draws it. A refused barspin step
-- holds the last accepted angle; the separate candidate publishes only after
-- exact advancing force admission and force-history adoption.
local NEUTRAL_POSE = table.freeze({steer=0,front_wheel_phase=0,rear_wheel_phase=0,crank_phase=0,
    barspin=0,tailwhip=0,movement_bike_pitch=0,movement_bike_roll=0})
local TRICK_RELEASES = table.freeze({"barspin_release","release_left_hand","release_right_hand","tailwhip_release","release_left_foot","release_right_foot"})
-- How far a wheel is drawn up out of the ground its row measured: its true
-- depth (ray_separation on a held row) less LIFT_SLACK, along the ground's
-- normal as the bike's own pitch sees it (rise_tilt). A row's depth is a
-- sphere's, and a leaning tyre is a disc whose rim stands clear of that
-- sphere, so lifting it the depth itself never draws it into the ground nor
-- further off it than it rolls. A clear wheel, or one off the ground, is
-- drawn where the body has it, and so is one under LIFT_LEAST into it.
local function ground_rise(row)
    if type(row)~="table" or type(row.contact)~="table" or row.contact.status~="hit" then return 0 end
    local depth=row.ray_separation or row.separation
    if not M.finite(depth) then return 0 end
    local rise=math.min(-depth-LIFT_SLACK,HELD_FLAT_FLOOR-LIFT_SLACK)
    return rise>=LIFT_LEAST and rise or 0
end
-- How far a row's tyre stands off the ground its ray found, or math.huge for a ray that found none. A wheel no more
-- than ON_GROUND off it is on the ground, as fall() and ahead() count one.
local ON_GROUND = .02
local function clearance(row)
    if type(row)=="table" and type(row.contact)=="table" and row.contact.status=="hit" and M.finite(row.separation) then
        return row.separation
    end
    return math.huge
end
local function on_ground(row) return clearance(row)<=ON_GROUND end
-- The direction the drawn wheels rise along, as Geometry.hub_rise's tilt from the bike's up toward its forward:
-- the normal of the ground under the wheels on it, as fall() sums it, or world up with neither on it, so a wheel
-- drawn up off a kerb in a manual comes down the way it went up when the bike leaves it. Only its part in the
-- bike's own plane counts: a lean is still lifted along the bike's up, as ground_rise says. A bike square to the
-- ground under it has a tilt of 0 and is drawn as it was before.
local function rise_tilt(samples,orientation,up)
    local sum,count={0,0,0},0
    for i=1,2 do
        local row=samples[i]
        if on_ground(row) and M.vec(row.contact.normal,2) then sum=M.add(sum,row.contact.normal);count+=1 end
    end
    local n=count>0 and M.unit(sum) or up
    if not n or type(orientation)~="table" then return 0 end
    local q=M.normalized(orientation)
    local seen=M.turn({-q[1],-q[2],-q[3],q[4]},n)
    if not M.vec(seen) or seen[2]*seen[2]+seen[3]*seen[3]<1e-6 then return 0 end
    return math.clamp(math.atan2(seen[3],seen[2]),-LIFT_TILT,LIFT_TILT)
end
-- The presentation pose after an accepted step: the front steer angle the
-- kernel commanded, each wheel turned by its accepted angular speed over the
-- step, and the cranks turned by the rear wheel through CRANK_RATIO only while
-- the kernel's pedal latch says the rider pedals (forces.lua pedal_cadence),
-- so a coast or a held pedal at top speed leaves them still. These are
-- accepted Lua predictions drawn on the measured body, never native wheel
-- state. ForceStage's zero stage commands nothing and reports no steer or
-- cadence: the bars and cranks hold. One new table a step, which status
-- shares; nil for a model that reports either malformed. orientation is the
-- measured body's and up is world up, for the direction a wheel is drawn up.
local function presentation(previous,model,wheels,h,samples,geometry,orientation,up)
    local steer,pedaling=model.front_steer_angle,model.pedaling
    if steer==nil then steer=previous.steer
    elseif not M.finite(steer) or math.abs(steer)>1 then return nil end
    if pedaling==nil then pedaling=false elseif type(pedaling)~="boolean" then return nil end
    local rear=wheels[2].angular_speed*h
    local pose={steer=steer,front_wheel_phase=wrap(previous.front_wheel_phase+wheels[1].angular_speed*h),
        rear_wheel_phase=wrap(previous.rear_wheel_phase+rear),
        crank_phase=pedaling and wrap(previous.crank_phase+rear/CRANK_RATIO) or previous.crank_phase,
        barspin=previous.barspin,tailwhip=previous.tailwhip,movement_bike_pitch=0,movement_bike_roll=0}
    -- A refused candidate holds the same accepted hand releases as its angle.
    -- Omitted zero releases keep ordinary riding's eight-field pose unchanged.
    for _,name in ipairs(TRICK_RELEASES) do pose[name]=previous[name] end
    -- Each drawn wheel moves from where the last pose drew it toward what this
    -- step's rays measured under the body being drawn, no faster than
    -- LIFT_RATE. A rigid bike lifts a wheel by pitching and lifting the whole
    -- of it, and the shift keeps the wheel it turns about where the body has it
    -- across the ground. Nothing in Ride or the kernel reads the pitch, lift or shift back.
    -- Only a wheel on the ground holds the drawn bike. One off it, the front in a manual, has nothing under it to
    -- keep it down: it takes the other's rise, so the whole bike is lifted by the rear's rise with no drawn pitch, and
    -- the bike turns about the wheel on the ground. Drawn as if the front still stood on the road, a manual climbing
    -- a kerb nodded 7 degrees nose down about its airborne front wheel for a third of a second, the body at 30 up.
    -- It takes no more of that rise than it stands clear of the ground beyond ON_GROUND, so one just off it still
    -- holds the bike nearly as one on it does: a tyre an instant off a kerb's top is not drawn floating over it,
    -- and one hovering about the 2 cm line does not flick 5 cm up and down a step.
    local front_down,back_down=on_ground(samples[1]),on_ground(samples[2])
    local want_front,want_back=ground_rise(samples[1]),ground_rise(samples[2])
    if front_down and not back_down then want_back=math.min(want_front,clearance(samples[2])-ON_GROUND)
    elseif back_down and not front_down then want_front=math.min(want_back,clearance(samples[1])-ON_GROUND) end
    local was=previous.movement_bike_pitch~=0 or previous.movement_bike_lift~=nil
    -- Ordinary riding, with nothing drawn and nothing to draw, skips the tilt.
    local tilt=(was or want_front~=0 or want_back~=0) and rise_tilt(samples,orientation,up) or 0
    local front,back=0,0
    if was then
        front,back=Geometry.hub_rise(geometry,previous.movement_bike_pitch,previous.movement_bike_lift or 0,
            previous.movement_bike_shift or 0,tilt)
        if not front then front,back=0,0 end
    end
    local most=LIFT_RATE*h
    front+=math.clamp(want_front-front,-most,most)
    back+=math.clamp(want_back-back,-most,most)
    if front~=0 or back~=0 then
        local held=front_down~=back_down and (front_down and "front" or "rear") or nil
        local pitch,lift,shift=Geometry.pitch_lift(geometry,front,back,tilt,held)
        -- On one wheel the bike is lifted whole, its shift the rise times the tilt's sine, 16 cm at most. Only
        -- hubs drawn far apart at a steep tilt pass what bike_visual draws (its SHIFT_LIMIT), and a bike with
        -- both wheels on the ground stands near square to it; the clamp keeps any pose one the visual takes.
        if pitch then pose.movement_bike_pitch,pose.movement_bike_lift,pose.movement_bike_shift=pitch,lift,math.clamp(shift,-.25,.25) end
    end
    -- In a manual the rider's hips go where the physics holds the weight: the kernel's pitch couple over
    -- the weight, eased over RIDER_SHIFT_SECONDS so the pose does not jump on a step's change. Out of it
    -- the shift eases back and the field goes once it is under half a centimetre.
    local shift=previous.rider_shift
    if model.manual_active==true then
        if not M.finite(model.manual_shift) then return nil end
        local target=math.clamp(model.manual_shift,-RIDER_SHIFT_FORWARD,RIDER_SHIFT_BACK)
        shift=(shift or 0)+(target-(shift or 0))*math.min(1,h/RIDER_SHIFT_SECONDS)
    elseif shift~=nil then
        shift-=shift*math.min(1,h/RIDER_SHIFT_SECONDS)
        if math.abs(shift)<.005 then shift=nil end
    end
    pose.rider_shift=shift
    return pose
end
-- The measured tilt of the body's up axis from world up, in degrees, and its
-- roll rate about its own forward axis, in rad/s; nil when either is unknown.
local function attitude(body,gravity)
    local down=M.unit(gravity)
    if not down then return nil end
    local q=M.normalized(body.orientation)
    local u1,u2,u3=M.turn3(q[1],q[2],q[3],q[4],0,1,0)
    local f1,f2,f3=M.turn3(q[1],q[2],q[3],q[4],0,0,1)
    local w=body.angular_velocity
    local tilt=math.deg(math.acos(math.clamp(-(u1*down[1]+u2*down[2]+u3*down[3]),-1,1)))
    local roll=w[1]*f1+w[2]*f2+w[3]*f3
    if not M.finite(tilt) or not M.finite(roll) then return nil end
    return tilt,roll
end
-- Whether this step's wheels show a fall, as the angle and limit to report, or
-- nil. Tilt from the surface alone would end a ride on the bevel of a kerb,
-- with the bike level, so it only ever excuses a tilt from world up: a stop
-- here is one that world up would have made as well. Air and ground count
-- apart, so time in the air does not spend a landing's chance to be saved.
-- Only coming back in bounds clears them, so a fall that keeps losing and
-- finding its wheels still ends.
local function fall(s,body,tilt,contact)
    local sum,count={0,0,0},0
    for _,row in ipairs(contact.samples) do
        if row.contact.status=="hit" and row.separation<=.02 then sum=M.add(sum,row.contact.normal);count+=1 end
    end
    local surface=count>0 and M.unit(sum) or nil
    local angle,limit,steps=tilt,TILT_STOP_DEG,UNSUPPORTED_TILT_STEPS
    if surface then
        local from_surface=attitude(body,M.mul(surface,-1))
        if from_surface and from_surface<angle then angle=from_surface end
        limit,steps=FALL_SURFACE_DEG,FALL_STEPS
    end
    if angle<=limit then s.fall_steps,s.air_fall_steps=0,0;return nil end
    local count=surface and "fall_steps" or "air_fall_steps"
    s[count]=(s[count] or 0)+1
    if s[count]>=steps or not surface and tilt>AIR_TILT_STOP_DEG then return angle,limit end
    return nil
end
-- The torque a bike that has hit something gets this step: nose down, or tail
-- down if it hit rolling backward, because the rider's weight carries on the
-- way the bike was going.
local function crash_torque(s,body)
    local over=M.mul(M.turn(M.normalized(body.orientation),{1,0,0}),s.crash.way)
    local rate=math.min(s.crash.speed*CRASH_RATE,CRASH_RATE_LIMIT)
    return M.mul(over,M.dot(body.angular_velocity,over)<rate and CRASH_TORQUE or 0)
end
-- The speed and velocity this step's body had when it hit something, or nil.
local function hit(s,body)
    local history=s.speed_history or {}
    s.speed_history=history
    local v,old=body.linear_velocity,history[HIT_STEPS]
    table.insert(history,1,v)
    history[HIT_STEPS+1]=nil
    if not old then return nil end
    local speed=math.sqrt(old[1]*old[1]+old[3]*old[3])
    if speed>=HIT_DROP and speed-(v[1]*old[1]+v[3]*old[3])/speed>=HIT_DROP then return speed,old end
    return nil
end
-- Adds what a kerb struck this step costs to what is still to pay. Each wheel keeps its true gap from the last
-- step, not the held depth, and the point and normal its ray found. A gap that closes is a kerb only when the
-- ground came up under the wheel by as much, along the new surface's normal and the old one's both, and only for
-- as far as the tyre is now into the new surface. A landing closes its gap with the wheel coming down onto ground
-- that stayed where it was. On a hill, or onto a ramp met from flat, the new point lies on or under the plane the
-- wheel was on, and over a crest, a knuckle landed on among them, it lies under the plane of the old surface. A
-- wheel hopped at a kerb pays for the part of it the tyre did not clear, so a hop that clears its top costs
-- nothing and one a few centimetres off the road costs nearly the whole kerb. A wheel coming down as its hub passes
-- the edge is deeper at the end of the step than it was there, by the drop after it. At a steady speed its depth at
-- the edge lies between where its tyre was under the new surface a step before, from its hub then, and where it is
-- now, so it pays the depth halfway between: wrong by at most half a step's fall either way, wherever in the step
-- the edge lay. The lesser of the two would let a tyre that came down well short go free whenever the edge lay late
-- in the step. So a tyre that cleared the top at the edge pays nothing, unless it came down more than twice
-- CURB_STEP in the step and cleared it by less than that error, and then it pays a little. The step's contact
-- metrics name the height a wheel struck.
local function curb_strike(s,body,contact)
    local last,rows=s.curb_rows or {},{}
    local up=M.unit(M.mul(s.force.tuning.gravity,-1))
    for i,row in ipairs(contact.samples) do
        if row.contact.status=="hit" then
            local gap,point,normal=row.ray_separation or row.separation,row.ray_point or row.contact.point,row.contact.normal
            local before=last[i]
            rows[i]={gap=gap,point=point,normal=normal,center=row.wheel_center}
            if before and up and M.dot(normal,up)>=CURB_FLAT then
                local d=M.sub(point,before.point)
                -- The tyre's depth under the new surface from last step's hub, measured as gap is.
                local was=-(M.dot(M.sub(before.center,point),normal)-s.geometry.wheel_radius)
                local step=math.min(before.gap-gap,M.dot(d,normal),M.dot(d,before.normal),-gap,(was-gap)/2)
                if step>=CURB_STEP then
                    local v=body.linear_velocity
                    local speed=M.length(M.sub(v,M.mul(up,M.dot(v,up))))
                    s.curb_loss=(s.curb_loss or 0)+CURB_SHARE*speed*math.min(step/s.geometry.wheel_radius,1)
                    s.metrics_step.contact[i==1 and "front_curb" or "rear_curb"]=step
                end
            end
        end
    end
    s.curb_rows=rows
end
-- The push that pays a kerb strike this step, against the forecast's travel along the ground, and the speed it
-- takes; nil when nothing is owed. Ride takes the speed off what is owed once the command carrying it is admitted.
local function curb_push(s,b,h)
    local owed=s.curb_loss
    if not owed or owed<=0 then return nil end
    local down=M.unit(s.force.tuning.gravity)
    local travel=down and M.sub(b.linear_velocity,M.mul(down,M.dot(b.linear_velocity,down)))
    local moving=travel and M.length(travel) or 0
    -- A bike already stopped has nothing left for the kerb to take.
    if moving<=.05 then s.curb_loss=nil;return nil end
    local paid=math.min(owed,moving,CURB_FORCE*h/b.mass)
    return M.mul(travel,-paid*b.mass/(h*moving)),paid
end
local function array(value)
    if typeof(value) ~= "vector" then return nil end
    local result = {value.x, value.y, value.z}
    return M.vec(result) and result or nil
end
local function native(value) return vector.create(value[1], value[2], value[3]) end
local function clock(s, now)
    if not M.finite(now) or now < 0 or now > MAX_SAFE or s.now and now < s.now then return false end
    s.now = now
    return true
end
local function invoke(s, fn, ...)
    if type(fn) ~= "function" then return {false, "callback unavailable", n=2} end
    local generation = s.generation
    local result = table.pack(pcall(fn, ...))
    result.current = generation == s.generation
    return result
end
local function exact_true(result) return result[1] and result[2] == true and result.current end
local function score_plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function score_number(v,lo,hi) return M.finite(v) and v>=lo and v<=hi end
local function score_count(v,hi) return score_number(v,0,hi) and v%1==0 end
-- Project the bounded mod view before putting it in status. A scoring fault
-- must not introduce callback tables, cycles or unbounded data into Ride.
local function score_snapshot(v)
    if not score_plain(v) or v.scope~="authored_mod_score_only" or v.calibration~="C0_UNRUN"
        or v.native_score~=false or type(v.active)~="boolean" or type(v.stopped)~="boolean"
        or type(v.issue)~="string" or #v.issue>180 then return nil end
    local out={scope=v.scope,calibration=v.calibration,native_score=false,active=v.active,stopped=v.stopped,issue=v.issue}
    for _,name in ipairs({"pending_points","pending_score","eligible_pending_score","banked_total","best_combo","landed_combos"}) do
        if not score_count(v[name],999999999) then return nil end
        out[name]=v[name]
    end
    for _,name in ipairs({"tricks","observed_command_tricks"}) do
        if not score_count(v[name],16) then return nil end
        out[name]=v[name]
    end
    if not score_number(v.multiplier,1,4) or not score_number(v.combo_factor,1,2) or not score_plain(v.rows) then return nil end
    out.multiplier,out.combo_factor,out.rows=v.multiplier,v.combo_factor,{}
    local n,high=0,0
    for k in next,v.rows do
        n+=1;if n>4 or not score_count(k,4) or k==0 then return nil end
        high=math.max(high,k)
    end
    if n~=high then return nil end
    for i=1,n do
        local r=v.rows[i]
        if not score_plain(r) or type(r.name)~="string" or #r.name==0 or #r.name>80
            or (r.channel~="barspin" and r.channel~="tailwhip" and r.channel~="one_hander" and r.channel~="one_footer")
            or not Identity.is_nonzero_u64(r.body_serial) or not Identity.is_nonzero_u64(r.accepted_sequence)
            or (r.state~="prediction_only" and r.state~="force_applied_observed") then return nil end
        out.rows[i]={name=r.name,channel=r.channel,body_serial=r.body_serial,accepted_sequence=r.accepted_sequence,state=r.state}
    end
    if v.last_closed~=nil then
        local c=v.last_closed
        if not score_plain(c) or (c.outcome~="lost" and c.outcome~="landed")
            or type(c.reason)~="string" or #c.reason==0 or #c.reason>100
            or not score_count(c.score,999999999) or not score_count(c.points,999999999)
            or not score_count(c.tricks,16) or c.authored~=true or c.native_score~=false or c.native_landing~=false
            or c.multiplier~=nil and not score_number(c.multiplier,1,4)
            or c.combo_factor~=nil and not score_number(c.combo_factor,1,2) then return nil end
        out.last_closed={outcome=c.outcome,reason=c.reason,score=c.score,points=c.points,tricks=c.tricks,
            authored=true,native_score=false,native_landing=false,multiplier=c.multiplier,combo_factor=c.combo_factor}
        if c.rows~=nil then
            if not score_plain(c.rows) then return nil end
            local rows,count,high={},0,0
            for k in next,c.rows do
                count+=1;if count>4 or not score_count(k,4) or k==0 then return nil end
                high=math.max(high,k)
            end
            if count~=high or count>c.tricks then return nil end
            for i=1,count do
                local r=c.rows[i]
                if not score_plain(r) or type(r.name)~="string" or #r.name==0 or #r.name>80
                    or (r.channel~="barspin" and r.channel~="tailwhip" and r.channel~="one_hander" and r.channel~="one_footer")
                    or not Identity.is_nonzero_u64(r.body_serial) or not Identity.is_nonzero_u64(r.accepted_sequence)
                    or (r.state~="prediction_only" and r.state~="force_applied_observed") then return nil end
                -- Only these scalar fields may survive the display boundary.
                -- Unknown/nested keys, including cycles, are not closed labels.
                local fields=0
                for key in next,r do
                    fields+=1
                    if fields>5 or (key~="name" and key~="channel" and key~="body_serial"
                        and key~="accepted_sequence" and key~="state") then return nil end
                end
                rows[i]={name=r.name,channel=r.channel,body_serial=r.body_serial,
                    accepted_sequence=r.accepted_sequence,state=r.state}
            end
            out.last_closed.rows=rows
        end
    end
    return freeze(out)
end
local function score_disable(s,why)
    if s.score_disabled then return end
    s.score_disabled=true;s.score_stopped=true;s.score_issue=detail(why);s.score_sequences={}
    if s.score_ledger then pcall(s.score_ledger.cancel,s.score_ledger,s.score_issue) end
    if s.score_landing then pcall(s.score_landing.cancel,s.score_landing,s.score_issue) end
    local old=s.mod_score
    s.mod_score=freeze({scope="authored_mod_score_only",calibration="C0_UNRUN",native_score=false,
        active=false,stopped=true,issue=s.score_issue,pending_points=0,pending_score=0,eligible_pending_score=0,
        tricks=0,observed_command_tricks=0,multiplier=1,combo_factor=1,rows={},
        banked_total=old and old.banked_total or 0,best_combo=old and old.best_combo or 0,
        landed_combos=old and old.landed_combos or 0,last_closed=old and old.last_closed or nil})
end
local function score_refresh(s)
    if not s.score_ledger or s.score_disabled then return end
    local out=table.pack(pcall(s.score_ledger.view,s.score_ledger))
    local view=out[1] and out.n==2 and score_snapshot(out[2]) or nil
    if not view then score_disable(s,"mod score view unavailable");return end
    s.mod_score=view
end
local function score_stop(s,why)
    if s.score_stopped then return end
    s.score_stopped=true;s.score_sequences={};s.score_accept_catches=false;s.score_frame_serial=nil
    if s.score_ledger then pcall(s.score_ledger.cancel,s.score_ledger,detail(why)) end
    if s.score_landing then pcall(s.score_landing.cancel,s.score_landing,detail(why)) end
    score_refresh(s)
end
local function score_action(s,name,...)
    if not s.score_ledger or s.score_disabled or s.score_stopped then return nil end
    local generation=s.generation
    local out=table.pack(pcall(s.score_ledger[name],s.score_ledger,...))
    if s.generation~=generation or s.stopped then return nil end
    if not out[1] or out.n~=3 or type(out[2])~="boolean"
        or (type(out[3])~="string" and type(out[3])~="table") then
        score_disable(s,"mod score "..name.." unavailable");return nil
    end
    s.score_issue=type(out[3])=="string" and detail(out[3]) or "none"
    score_refresh(s)
    if s.mod_score and s.mod_score.stopped then score_stop(s,s.mod_score.issue) end
    return out[2],out[3]
end
local function score_queue(s,frame,presentation)
    if not s.score_ledger or s.score_disabled or s.score_stopped or s.stopped then return end
    if not presentation.authored_events then return end
    if s.score_frame_serial~=frame.serial or s.score_accept_catches~=true then
        s.score_issue="mod landing air unavailable";return
    end
    local accepted=score_action(s,"queue",frame,presentation)
    if accepted and not s.score_stopped and s.mod_score and s.mod_score.active then
        s.score_sequences[presentation.accepted_sequence]=true
    end
end
local function score_frame(s,frame,contact,proofs,authored_steer)
    if not s.score_ledger or s.score_disabled or s.score_stopped or s.stopped or not frame or not contact then return end
    s.score_frame_serial=frame.serial;s.score_accept_catches=false
    for _,proof in ipairs(proofs or {}) do
        local row=proof.receipt
        if s.score_sequences[row.sequence] then
            local accepted,why=score_action(s,"observe",frame,row)
            if accepted and why=="pending_landing" then s.score_sequences[row.sequence]=nil end
            if s.score_disabled or s.score_stopped or s.stopped then return end
        end
    end
    if s.score_landing then
        local generation=s.generation
        local out=table.pack(pcall(s.score_landing.step,s.score_landing,frame,contact,{applied_successors=proofs or {},authored_steer=authored_steer}))
        if s.generation~=generation or s.stopped then return end
        local value=out[1] and out.n==2 and out[2] or nil
        if not score_plain(value) or value.serial~=frame.serial or type(value.landed)~="boolean" or type(value.accepting_catches)~="boolean"
            or type(value.phase)~="string" or #value.phase>80 then
            score_disable(s,"measured mod landing unavailable");return
        end
        s.score_landing_phase=value.phase;s.score_accept_catches=value.accepting_catches
        if value.landed then
            if s.mod_score and s.mod_score.active then
                score_action(s,"land",frame,score_plain(value.quality) and value.quality or {available=false})
            end
            s.score_sequences={}
        end
    else
        -- Pending HUD facts may still be shown without a landing producer.
        -- Known recontact discards them; missing quality never becomes credit.
        s.score_accept_catches=contact.grounded==false
        if s.score_grounded==false and contact.grounded==true then
            if s.mod_score and s.mod_score.active then score_action(s,"land",frame,{available=false}) end
            s.score_sequences={}
        end
    end
    s.score_grounded=contact.grounded
end
local pad_keys={left_x=true,left_y=true,right_x=true,right_y=true,left_trigger=true,right_trigger=true,playstation=true,buttons=true}
local button_keys={up=true,down=true,left=true,right=true,start=true,back=true,left_stick=true,right_stick=true,
    lb=true,rb=true,a=true,b=true,x=true,y=true}
local function pad_copy(pad)
    if type(pad)~="table" or getmetatable(pad)~=nil or type(pad.buttons)~="table" or getmetatable(pad.buttons)~=nil then return nil end
    for name in pairs(pad) do if not pad_keys[name] then return nil end end
    local out={buttons={}}
    for _,name in ipairs({"left_x","left_y","right_x","right_y"}) do
        if not M.finite(pad[name]) or math.abs(pad[name])>1 then return nil end
        out[name]=pad[name]
    end
    for _,name in ipairs({"left_trigger","right_trigger"}) do
        if not M.finite(pad[name]) or pad[name]<0 or pad[name]>1 then return nil end
        out[name]=pad[name]
    end
    if pad.playstation~=nil and type(pad.playstation)~="boolean" then return nil end
    out.playstation=pad.playstation
    for name,value in pairs(pad.buttons) do
        if not button_keys[name] or type(value)~="boolean" then return nil end
        out.buttons[name]=value
    end
    for _,name in ipairs({"a","b","right_stick","lb","rb"}) do if type(out.buttons[name])~="boolean" then return nil end end
    return out
end
local function source_key(frame)
    if type(frame) ~= "table" or getmetatable(frame)~=nil or frame.input_ok ~= true or type(frame.lease_handle) ~= "userdata"
        or type(frame.generation) ~= "number" or frame.generation < 0 or frame.generation > MAX_SAFE
        or frame.generation % 1 ~= 0 or type(frame.sample) ~= "table" or getmetatable(frame.sample)~=nil then return nil end
    local sample = frame.sample
    if type(sample.user) ~= "number" or sample.user < 0 or sample.user > 3 or sample.user % 1 ~= 0 then return nil end
    for _, name in ipairs({"sequence","source_epoch","context_generation","observation_serial","observed_ms"}) do
        if not Identity.is_nonzero_u64(sample[name]) then return nil end
    end
    if not M.finite(sample.packet) or sample.packet<0 or sample.packet>4294967295 or sample.packet%1~=0 then return nil end
    local pad=pad_copy(sample.pad)
    if not pad then return nil end
    return {lease_handle=frame.lease_handle,generation=frame.generation,user=sample.user,
        sequence=sample.sequence,source_epoch=sample.source_epoch,context_generation=sample.context_generation,
        observation_serial=sample.observation_serial,observed_ms=sample.observed_ms,packet=sample.packet,pad=pad}
end
local function same_source(a, b)
    if not a or not b then return false end
    for _, name in ipairs({"lease_handle","generation","user","sequence","source_epoch","context_generation"}) do
        if a[name] ~= b[name] then return false end
    end
    return true
end
local function same_input(a,b)
    if not same_source(a,b) then return false end
    for _,name in ipairs({"observation_serial","observed_ms","packet"}) do if a[name]~=b[name] then return false end end
    local function equal(x,y)
        if type(x)~=type(y) then return false end
        if type(x)~="table" then return x==y end
        for key,value in pairs(x) do if not equal(value,y[key]) then return false end end
        for key in pairs(y) do if x[key]==nil then return false end end
        return true
    end
    return equal(a.pad,b.pad)
end
local function same_observation(a,b)
    if not same_source(a,b) then return false end
    for _,name in ipairs({"observation_serial","observed_ms","packet"}) do if a[name]~=b[name] then return false end end
    return true
end
local function stage_input(s,frame,key)
    local previous=s.staged_last
    if previous then
        local order=Identity.compare(key.observation_serial,previous.observation_serial)
        if order<0 then return false,"selected input observation regressed" end
        if order==0 then return same_input(key,previous),"selected duplicate input changed" end
        if Identity.compare(key.observed_ms,previous.observed_ms)<0 then return false,"selected input clock regressed" end
    end
    if #s.input_queue>=32 then return false,"selected input staging capacity exceeded" end
    local first=s.input_queue[1]
    if first and not Identity.bounded_delta(key.observed_ms,first.sample.observed_ms,100) then
        return false,"selected input staging window exceeded"
    end
    -- One detached copy of the key; the queued sample is that copy less its
    -- handle and generation, sharing its frozen pad.
    local staged=detached(key)
    local selected=table.clone(staged)
    selected.lease_handle,selected.generation=nil,nil
    s.input_queue[#s.input_queue+1]=detached({input_ok=true,lease_handle=key.lease_handle,generation=key.generation,sample=selected})
    s.staged_last=staged
    s.input_staged+=1
    return true
end
local function sample_copy(raw)
    if type(raw) ~= "table" or getmetatable(raw)~=nil or type(raw.epoch) ~= "userdata" or not Identity.is_nonzero_u64(raw.serial)
        or not M.finite(raw.time) or raw.time < 0 or not M.finite(raw.seconds)
        or math.abs(raw.seconds - Forces.native_seconds) > 1e-8 then return nil end
    local body = {mass=raw.mass,center_of_mass=array(raw.position),orientation=copy(raw.rotation),
        linear_velocity=array(raw.velocity),angular_velocity=array(raw.angular_velocity),inertia_body=array(raw.inertia)}
    if not M.valid_body(body) or not M.vec(body.center_of_mass,100000) or not M.vec(body.linear_velocity,50)
        or not M.vec(body.angular_velocity,40) then return nil end
    local sample = {epoch=raw.epoch,serial=raw.serial,time=raw.time,seconds=raw.seconds,position=raw.position,
        rotation=copy(raw.rotation),velocity=raw.velocity,angular_velocity=raw.angular_velocity,inertia=raw.inertia,mass=raw.mass}
    -- Both tables and everything in them were made here: frozen in place,
    -- they are what detaching them would copy.
    return freeze(sample), freeze(body)
end
local function receipt_sample_copy(raw)
    -- Cleanup checks native record shape/correlation, not drive policy limits.
    -- SDK observe_checked bounds pose rings to 1e6 and velocity/spin to 100;
    -- its quaternion squared norm admits [.9,1.1]. A tighter ride refusal must
    -- not withhold an otherwise exact native terminal acknowledgement.
    if type(raw)~="table" or getmetatable(raw)~=nil or type(raw.epoch)~="userdata"
        or not Identity.is_nonzero_u64(raw.serial) or not M.finite(raw.time) or raw.time<0
        or not M.finite(raw.seconds) or math.abs(raw.seconds-Forces.native_seconds)>1e-8
        or not M.finite(raw.mass) or raw.mass<=0 or type(raw.rotation)~="table" then return nil end
    local bounds={position=1000000,velocity=100,angular_velocity=100}
    for name,bound in pairs(bounds) do
        local v=raw[name]
        if typeof(v)~="vector" or not M.finite(v.x) or not M.finite(v.y) or not M.finite(v.z)
            or math.abs(v.x)>bound or math.abs(v.y)>bound or math.abs(v.z)>bound then return nil end
    end
    local inertia=raw.inertia
    if typeof(inertia)~="vector" or not M.finite(inertia.x) or not M.finite(inertia.y) or not M.finite(inertia.z)
        or inertia.x<=0 or inertia.y<=0 or inertia.z<=0 then return nil end
    local norm=0
    for i=1,4 do if not M.finite(raw.rotation[i]) then return nil end;norm+=raw.rotation[i]^2 end
    if not M.finite(norm) or norm<.9 or norm>1.1 then return nil end
    return detached({epoch=raw.epoch,serial=raw.serial,time=raw.time,seconds=raw.seconds,mass=raw.mass,
        position=raw.position,rotation=copy(raw.rotation),velocity=raw.velocity,angular_velocity=raw.angular_velocity,inertia=raw.inertia})
end
local function equal_sample(a,b)
    if a.serial ~= b.serial or a.time ~= b.time or a.seconds ~= b.seconds or a.position ~= b.position
        or a.velocity ~= b.velocity or a.angular_velocity ~= b.angular_velocity or a.inertia ~= b.inertia
        or a.mass ~= b.mass then return false end
    for i=1,4 do if a.rotation[i] ~= b.rotation[i] then return false end end
    return true
end
local function wheel_copy(wheels,previous)
    if type(wheels)~="table" then return nil end
    local out={}
    for i=1,2 do
        local wheel=wheels[i]
        if not M.valid_wheel(wheel) or wheel.radius~=previous[i].radius or wheel.inertia~=previous[i].inertia then return nil end
        out[i]={radius=wheel.radius,inertia=wheel.inertia,angular_speed=wheel.angular_speed}
    end
    return detached(out)
end
local function new_metrics()
    local out={version=1,stop_counts={},stop_counts_overflow=0,steps=0,fresh_report_steps=0,steps_without_report=0,
        max_steps_without_report=0,report_gap_count=0,largest_report_gap_ms=0,report_gap_unbounded=0,
        grounded_changes_with_report=0,grounded_changes_without_report=0,grounded_transition_total=0,
        grounded_transition_omitted=0,grounded_transitions={},samples_total=0,samples_omitted=0,samples={},
        inflight=0,max_inflight=0,applied_delay_one=0,applied_delay_other=0}
    for _,prefix in ipairs({"submitted","applied"}) do
        for _,suffix in ipairs({"count","delta_count","delta_one","delta_other","delta_max","delta_unbounded"}) do
            out[prefix.."_"..suffix]=0
        end
    end
    return out
end
local function metrics_inflight(s)
    local count=0
    for _,p in ipairs(s.pending) do if not p.acknowledged then count+=1 end end
    s.metrics.inflight=count
    s.metrics.max_inflight=math.max(s.metrics.max_inflight,count)
    return count
end
local function metrics_serial(s,prefix,serial)
    local m=s.metrics
    m[prefix.."_count"]+=1
    local previous=s["metrics_"..prefix.."_serial"]
    if previous then
        m[prefix.."_delta_count"]+=1
        local delta=Identity.bounded_delta(serial,previous,MAX_SAFE)
        if delta then
            local kind=delta==1 and "_delta_one" or "_delta_other"
            m[prefix..kind]+=1
            m[prefix.."_delta_max"]=math.max(m[prefix.."_delta_max"],delta)
        else m[prefix.."_delta_unbounded"]+=1 end
    end
    s["metrics_"..prefix.."_serial"]=serial
end
local function metrics_report(s,key)
    local m=s.metrics
    s.metrics_step.report=true
    s.metrics_step.input_observed_ms=key.observed_ms
    if s.metrics_report_ms then
        m.report_gap_count+=1
        local delta=Identity.bounded_delta(key.observed_ms,s.metrics_report_ms,MAX_SAFE)
        if delta then m.largest_report_gap_ms=math.max(m.largest_report_gap_ms,delta)
        else m.report_gap_unbounded+=1 end
    end
    s.metrics_report_ms=key.observed_ms
end
local function metric_ring(m,name,limit,row)
    local stem=name=="grounded_transitions" and "grounded_transition" or name
    m[stem.."_total"]+=1
    local ring=m[name]
    if #ring==limit then table.remove(ring,1);m[stem.."_omitted"]+=1 end
    ring[#ring+1]=freeze(row) -- Never changed once kept; status shares it.
end
-- Fixed first report-backed support-classification edge, not collision evidence.
-- V2: at most 96 value slots, depth 3, SDK JSON bound 2948 bytes
-- (2970 including its metrics member). The unchanged 48000-byte ledger owns admission.
local function metric_support_row(row,facts)
    local function vec(v) return v and {v[1],v[2],v[3]} or nil end
    local out={serial=row.serial,physics_time=facts.physics_time,report=row.report,grounded=row.grounded,
        input_observed_ms=facts.input_observed_ms,rear_hub_position=vec(facts.measured_rear_hub),
        rear_hit_position=vec(facts.measured_rear_hit),rear_hit_normal=vec(facts.measured_rear_normal),
        front_hit=row.front_hit,rear_hit=row.rear_hit,front_gap=row.front_separation,rear_gap=row.rear_separation,
        body_height=row.body_height,command_admitted=facts.published_sequence~=nil,
        model_sequence=facts.published_sequence,model_grounded=facts.published_grounded,
        front_normal_load=facts.published_front_load,rear_normal_load=facts.published_rear_load}
    -- SDK JSON converts integral -0 to 0. Keep its sign in a six-bit mask:
    -- time, front gap, rear gap, height, front load, rear load, in that order.
    local negative_zero=0
    for i,name in ipairs({"physics_time","front_gap","rear_gap","body_height","front_normal_load","rear_normal_load"}) do
        if out[name]==0 and 1/out[name]==-math.huge then negative_zero+=2^(i-1) end
    end
    -- Preserve the v1 bits 0..5; append hub XYZ, hit XYZ, normal XYZ at bits 6..14.
    for i,name in ipairs({"rear_hub_position","rear_hit_position","rear_hit_normal"}) do
        local value=out[name]
        if value then for axis=1,3 do
            if value[axis]==0 and 1/value[axis]==-math.huge then negative_zero+=2^(5+(i-1)*3+axis) end
        end end
    end
    out.negative_zero_mask=negative_zero
    return freeze(out)
end
local function metrics_support_loss(s,row,step)
    local m=s.metrics
    local first=m.first_support_loss
    if first==nil then
        local previous=s.metrics_support_previous
        if previous and previous.row.grounded==true and row.grounded==false and step.report then
            m.first_support_loss=freeze({version=2,scope="reported_grounded_classification_only",
                rear_normal_provenance="qualified_plane_used_for_gap",input_clock_provenance="selected_sample.observed_ms",
                measured_provenance="measured_rays_authored_wheel_geometry",
                model_provenance="admitted_forecast_model_not_consumption",
                native_collision_contact=false,native_consumption_known=false,time_provenance="body_sample.time",
                prior=metric_support_row(previous.row,previous),loss=metric_support_row(row,step)})
            s.metrics_support_previous=nil
        else
            -- One private reference to the preceding existing ring row and
            -- scalar facts and three small ray-term arrays; no whole model is retained.
            previous=previous or {}
            previous.row=row;previous.physics_time=step.physics_time
            previous.published_sequence=step.published_sequence;previous.published_grounded=step.published_grounded
            previous.published_front_load=step.published_front_load;previous.published_rear_load=step.published_rear_load
            previous.measured_rear_hub=step.measured_rear_hub;previous.measured_rear_hit=step.measured_rear_hit
            previous.measured_rear_normal=step.measured_rear_normal;previous.input_observed_ms=step.input_observed_ms
            s.metrics_support_previous=previous
        end
    elseif first.reacquired==nil and row.grounded==true then
        local complete=table.clone(first)
        complete.reacquired=metric_support_row(row,step)
        m.first_support_loss=freeze(complete)
    end
end
local function metrics_finish_step(s)
    local step=s.metrics_step
    if not step then return end
    s.metrics_step=nil
    local m=s.metrics
    m.steps+=1
    if step.report then
        m.fresh_report_steps+=1;s.metrics_no_report_steps=0
    else
        m.steps_without_report+=1
        s.metrics_no_report_steps=(s.metrics_no_report_steps or 0)+1
        m.max_steps_without_report=math.max(m.max_steps_without_report,s.metrics_no_report_steps)
    end
    local inflight=metrics_inflight(s)
    local row=step.contact
    if not row then return end
    row.report=step.report
    row.inflight=inflight
    -- Speeds are the latest accepted Lua prediction, never native wheel state.
    row.front_speed=s.wheels[1].angular_speed;row.rear_speed=s.wheels[2].angular_speed
    metrics_support_loss(s,row,step)
    if s.metrics_grounded~=nil and row.grounded~=s.metrics_grounded then
        local kind=step.report and "grounded_changes_with_report" or "grounded_changes_without_report"
        m[kind]+=1
        metric_ring(m,"grounded_transitions",METRIC_TRANSITION_LIMIT,
            {serial=step.serial,grounded=row.grounded,report=step.report})
    end
    s.metrics_grounded=row.grounded
    metric_ring(m,"samples",METRIC_SAMPLE_LIMIT,row)
end
local function stop_key_bytes(text)
    -- Count the compact SDK JSON key, including quotes. Refuse new malformed
    -- UTF-8 keys rather than poisoning an otherwise serializable ledger.
    if #text+2>METRIC_STOP_KEY_BYTES or utf8.len(text)==nil then return nil end
    local bytes=#text+2
    for i=1,#text do
        local b=string.byte(text,i)
        if b==34 or b==92 then bytes+=1
        elseif b<32 then
            bytes+=(b==8 or b==9 or b==10 or b==12 or b==13) and 1 or 5
        end
        if bytes>METRIC_STOP_KEY_BYTES then return nil end
    end
    return bytes
end
local function count_stop(s,text)
    local counts=s.metrics.stop_counts
    if counts[text]~=nil then counts[text]+=1;return end
    local bytes=stop_key_bytes(text)
    if bytes and (s.stop_reason_count or 0)<METRIC_STOP_REASON_LIMIT
        and (s.stop_key_bytes or 0)+bytes<=METRIC_STOP_KEY_BYTES then
        counts[text]=1
        s.stop_reason_count=(s.stop_reason_count or 0)+1
        s.stop_key_bytes=(s.stop_key_bytes or 0)+bytes
    else s.metrics.stop_counts_overflow+=1 end
end
local function stop(s, reason)
    -- Count every request, including cleanup observations after the pure
    -- lifecycle latch. Full keys remain distinct; only the first issue uses
    -- the existing display bound. Neither counter capacity nor later reasons
    -- can replace the first cause or advance cancellation generation again.
    local text=tostring(reason or "unavailable")
    count_stop(s,text)
    s.manual_active=false
    if not s.stopped then
        s.stopped=true;s.generation+=1;s.issue=detail(text)
        score_stop(s,text)
        if s.accepted_barspin then
            pcall(s.accepted_barspin.cancel,s.accepted_barspin,text)
            local ok,row=pcall(s.accepted_barspin.status,s.accepted_barspin)
            if ok then s.barspin_state=row end
            s.barspin_candidate,s.barspin_preview,s.barspin_presentation=nil,nil,nil;s.barspin_issue="stopped"
            if s.pose then
                local changed=s.pose.barspin~=0 or s.pose.tailwhip~=0
                for _,name in ipairs(TRICK_RELEASES) do changed=changed or s.pose[name]~=nil end
                if changed then
                    local pose=table.clone(s.pose);pose.barspin=0;pose.tailwhip=0
                    for _,name in ipairs(TRICK_RELEASES) do pose[name]=nil end
                    s.pose=freeze(pose)
                end
            end
        end
        -- A drawn lift is what the last step's rays measured. Nothing measures the wheels once Ride has
        -- stopped, so the bike is drawn on its body again rather than held up off a body that may be falling.
        if s.pose and (s.pose.movement_bike_pitch~=0 or s.pose.movement_bike_lift) then
            local pose=table.clone(s.pose)
            pose.movement_bike_pitch=0;pose.movement_bike_lift=nil;pose.movement_bike_shift=nil
            s.pose=freeze(pose)
        end
    end
    s.phase="stopped"
    s.input_queue={}
end
-- A step the model refuses (a wheel deep in a parked car, a landing past its envelope) goes unsent, as a
-- backpressured step does, and the next starts over from what is measured. A ride ends only if it stays refused.
local function refused_step(s,why)
    s.refused_steps=(s.refused_steps or 0)+1
    s.refused_issue=why
    if s.refused_steps>MAX_REFUSED_STEPS then return false end
    s.continuity_pending=true
    return true
end
local function discard_barspin(s)
    local candidate=s.barspin_candidate
    s.barspin_candidate,s.barspin_preview=nil,nil
    if candidate and s.accepted_barspin then
        pcall(s.accepted_barspin.discard,s.accepted_barspin,candidate);s.barspin_issue="discarded_unadopted"
    end
end
local function retire(s,pending,disposition)
    if not pending.hop_id or pending.hop_retired then return true end
    local result=invoke(s,s.mapping.retire_hop,s.mapping,pending.hop_id,disposition)
    pending.hop_retired=result[1] and result[2]==true
    s.hop_disposition={id=pending.hop_id,disposition=disposition,confirmed=pending.hop_retired}
    if not pending.hop_retired then s.unknown=true;stop(s,"hop retirement unavailable") end
    return pending.hop_retired
end
local function accepted_hop_owner(s,id)
    for _,pending in ipairs(s.pending) do
        if pending.hop_id==id and Identity.is_nonzero_u64(pending.sequence) and not pending.hop_retired then return true end
    end
    return false
end
local function suppress_hop(s,id)
    local retired=invoke(s,s.mapping.retire_hop,s.mapping,id,"suppressed")
    local confirmed=retired[1] and retired.n==3 and retired[2]==true and retired[3]=="none"
    s.hop_disposition={id=id,disposition="suppressed",confirmed=confirmed==true}
    if not confirmed or not retired.current or s.stopped then
        s.unknown=true;stop(s,"hop suppression unavailable");return false
    end
    return true
end
-- A single fixed-size refusal projection, not a force or collision receipt.
-- Body prediction and ray contacts keep their existing, different provenance.
local function force_refusal(s,issue,d,sample,measured,folded,contact)
    if s.last_force_refusal~=nil then return end
    local function vec(v) return M.vec(v) and {v[1],v[2],v[3]} or nil end
    local function four(v)
        return type(v)=="table" and M.finite(v[1]) and M.finite(v[2]) and M.finite(v[3]) and M.finite(v[4])
            and {v[1],v[2],v[3],v[4]} or nil
    end
    local function pair(v)
        return type(v)=="table" and M.finite(v[1]) and M.finite(v[2]) and {v[1],v[2]} or nil
    end
    local out={version=1,issue=detail(issue),serial=sample.serial,seconds=sample.seconds,
        diagnostic_only=true,command_submitted=false,model_valid=d.valid==true,
        force=vec(d.force),torque=vec(d.torque),
        measured={center_of_mass=vec(measured.center_of_mass),linear_velocity=vec(measured.linear_velocity),
            angular_velocity=vec(measured.angular_velocity),orientation=four(measured.orientation)},
        folded={mass=M.finite(folded.mass) and folded.mass or nil,linear_velocity=vec(folded.linear_velocity),
            angular_velocity=vec(folded.angular_velocity),center_of_mass=vec(folded.center_of_mass),
            orientation=four(folded.orientation),inertia_body=vec(folded.inertia_body)},
        contacts={provenance=contact.support.provenance,native_collision_contact=false,
            landing_quality_available=false,grounded=contact.grounded,wheels={}}}
    if out.force then out.force_norm=M.length(out.force) end
    if out.torque then out.torque_norm=M.length(out.torque) end
    for _,name in ipairs({"balance_torque","contact_torque","motor_torque","air_control_torque","air_damping_torque","pump_force"}) do
        out[name]=vec(d[name])
    end
    for _,name in ipairs({"contact_scale","balance_support_mask","balance_continuation_mask","landing_approach_mask",
        "compliant_normal_mask","landing_recovery_mask"}) do
        if M.finite(d[name]) then out[name]=d[name] end
    end
    for _,name in ipairs({"normal_load","normal_impulse","approach_normal_force"}) do out[name]=pair(d[name]) end
    for i=1,2 do
        local row=contact.samples[i]
        local c=row.contact
        out.contacts.wheels[i]={status=c.status,separation=M.finite(row.separation) and row.separation or nil,
            point=vec(c.point),normal=vec(c.normal),surface_velocity=vec(c.surface_velocity)}
    end
    s.last_force_refusal=freeze(out)
end
local function status(s)
    metrics_inflight(s)
    local p=s.pending[1]
    local sequences={}
    for _,entry in ipairs(s.pending) do
        sequences[#sequences+1]={sequence=entry.sequence,serial=entry.serial,ack_attempted=entry.ack_attempted==true,
            acknowledged=entry.acknowledged==true,unknown=entry.unknown==true,outcome=entry.outcome}
    end
    -- Opaque body/lease/incarnation/epoch stay private; this is diagnostic only.
    return detached({phase=s.phase,issue=s.issue,activation_qualified=ACTIVATION_QUALIFIED,
        stop_requested=s.stopped==true,force_pending=p~=nil,unknown=s.unknown==true or p and p.unknown==true or false,
        pending_sequence=p and p.sequence,ack_attempted=p and p.ack_attempted==true or false,
        pending_count=#s.pending,pending_commands=sequences,pending_limit=MAX_PENDING,
        backpressure=s.backpressure,backpressure_steps=s.backpressure_steps,last_backpressure_serial=s.last_backpressure_serial,
        continuity={pending=s.continuity_pending,skipped_steps=s.continuity_skipped_steps,
            invalidations=s.continuity_invalidations,body_read_recoveries=s.body_read_recoveries,
            gap_wheels="torque_free_coast",native_wheel_state_known=false},
        submitted=s.submitted,acknowledged=s.acknowledged,last_serial=s.last_sample and s.last_sample.serial,
        input_staged=s.input_staged,input_consumed=s.input_consumed,input_queued=#s.input_queue,
        observed_steps=s.observed_steps,model_steps=s.model_steps,receipt=s.last_receipt,
        model_history=s.model_history,hop_disposition=s.hop_disposition,metrics=s.metrics,
        last_force_refusal=s.last_force_refusal,
        presentation_pose=s.pose,presentation_trick=s.barspin_presentation,
        mod_score=s.mod_score,mod_score_issue=s.score_issue,mod_landing_phase=s.score_landing_phase,
        model={trick_status=s.trick_status,trick_fallbacks=s.trick_fallbacks,
            accepted_barspin=s.barspin_state,barspin_issue=s.barspin_issue,
            alignment_status=s.alignment_status,recovery_status=s.recovery_status}})
end
local function receipt_valid(row,p)
    if type(row)~="table" or row.sequence~=p.sequence or row.requested_serial~=p.serial
        or not Identity.is_u64(row.produced_serial) or type(row.force_attempted)~="boolean"
        or type(row.torque_attempted)~="boolean" or type(row.retained)~="boolean"
        or type(row.quarantined)~="boolean"
        or (row.cleanup_disposition~="none" and row.cleanup_disposition~="parked_without_successor") then return false end
    if row.cleanup_disposition=="parked_without_successor" and (row.outcome~="applied" or row.successor~=nil
        or not row.retained or row.quarantined or not row.force_attempted or not row.torque_attempted) then return false end
    if row.outcome=="queued" then return row.produced_serial=="0" and not row.force_attempted and not row.torque_attempted end
    if row.outcome=="applied" then
        return row.force_attempted and row.torque_attempted
            and Identity.bounded_delta(row.produced_serial,p.serial,1)==1
    end
    if row.outcome=="partial" then
        return Identity.is_nonzero_u64(row.produced_serial) and Identity.bounded_delta(row.produced_serial,p.serial,1)==1
            and (row.force_attempted or row.torque_attempted)
    end
    return (row.outcome=="rejected" or row.outcome=="expired") and not row.force_attempted and not row.torque_attempted
end
local function poll_pending(s,frame,contact,authored_steer)
    -- Inspect every retained command before choosing this poll's stop cause
    -- and ACKing its eligible prefix. Retained/quarantined are body-level SDK
    -- flags, so an older generic row must not hide a younger explicit outcome.
    -- Unknown evidence outranks native failure, which outranks park cleanup.
    -- Equal priority keeps receipt order; stop() preserves any earlier latch.
    local causes={}
    local score_proofs=s.score_ledger and {} or nil
    local function propose(reason,rank)
        causes[#causes+1]={reason=reason,rank=rank,order=#causes+1}
    end
    for _,p in ipairs(s.pending) do
        p.ack_ready=false
        if not p.unknown and not p.acknowledged then
            if not p.sequence then
                p.unknown=true;s.unknown=true;propose("force admission has no exact sequence",80)
            else
                if s.now and s.now-p.submitted_at>=1000 then
                    p.watchdog_expired=true;propose("force receipt watchdog expired",20)
                end
                local read=invoke(s,s.api.receipt,p.sequence)
                local row=read[1] and read.n==2 and read[2] or nil
                if not receipt_valid(row,p) then
                    p.unknown=true;s.unknown=true;propose("force receipt unavailable or identity mismatch",80)
                else
                    p.outcome=row.outcome;p.parked=row.cleanup_disposition=="parked_without_successor"
                    if row.outcome=="applied" and not p.metrics_applied then
                        p.metrics_applied=true
                        metrics_serial(s,"applied",row.produced_serial)
                        local delay=Identity.bounded_delta(row.produced_serial,p.serial,MAX_SAFE)
                        local kind=delay==1 and "applied_delay_one" or "applied_delay_other"
                        s.metrics[kind]+=1
                    end
                    s.last_receipt=freeze({outcome=row.outcome,sequence=row.sequence,requested_serial=row.requested_serial,
                        produced_serial=row.produced_serial,force_attempted=row.force_attempted,torque_attempted=row.torque_attempted,
                        retained=row.retained,quarantined=row.quarantined,successor_available=row.successor~=nil,
                        cleanup_disposition=row.cleanup_disposition})
                    if row.quarantined then propose("force body retained or quarantined",60)
                    elseif row.retained then propose("force body retained or quarantined",10) end
                    if p.parked then propose("force body parked without successor",40) end
                    if p.parked then
                        p.ack_ready=true
                    elseif row.outcome=="applied" then
                        if row.successor~=nil then
                            local successor=receipt_sample_copy(row.successor)
                            local steps=successor and Identity.bounded_delta(successor.serial,p.serial,MAX_SAFE)
                            if not successor or not steps or steps<2 or Identity.compare(successor.serial,row.produced_serial)<=0
                                or successor.seconds~=p.seconds or successor.time<=p.time+p.seconds
                                or math.abs(successor.time-p.time-steps*p.seconds)>1e-6 then
                                p.unknown=true;s.unknown=true;propose("applied successor incoherent",80)
                            else
                                p.ack_ready=true
                                if not sample_copy(row.successor) then propose("native successor outside drive policy",50)
                                elseif score_proofs and frame and contact and not row.retained and not row.quarantined
                                    and row.cleanup_disposition=="none" then
                                    score_proofs[#score_proofs+1]={request={sequence=p.sequence,serial=p.serial,time=p.time,seconds=p.seconds},receipt=row}
                                end
                            end
                        end
                    elseif row.outcome~="queued" then
                        propose("force command "..row.outcome,row.outcome=="partial" and 70 or 30);p.ack_ready=true
                    end
                end
            end
        end
    end
    -- Keep every observed cause for diagnostics, but let the most specific
    -- one reach the first latch before ACK callbacks or another admission.
    table.sort(causes,function(a,b)
        return a.rank>b.rank or a.rank==b.rank and a.order<b.order
    end)
    for _,cause in ipairs(causes) do stop(s,cause.reason) end
    -- Only fresh measured frames may inform local points, before the same ACK loop.
    score_frame(s,frame,contact,score_proofs,authored_steer)
    local index=1
    while index<=#s.pending do
        local p=s.pending[index]
        if p.acknowledged then
            -- Positive ACK frees native capacity but cannot erase uncertainty.
            index+=1
        elseif p.unknown or not p.ack_ready then break
        else
            if p.ack_attempted then p.unknown=true;s.unknown=true;break end
            p.ack_attempted=true -- A thrown call may have completed natively.
            local ack=invoke(s,s.api.acknowledge,p.sequence)
            if not ack[1] or ack.n~=2 or ack[2]~=true then
                p.unknown=true;s.unknown=true;stop(s,"force acknowledgement outcome unknown");break
            end
            p.acknowledged=true;s.acknowledged+=1
            local disposition=p.parked and "uncertain" or p.outcome=="applied" and "accepted"
                or p.outcome=="partial" and "uncertain" or "cancelled"
            local retired=retire(s,p,disposition)
            if p.outcome=="partial" or not retired then
                p.unknown=true;s.unknown=true;index+=1
            else table.remove(s.pending,index) end
            -- ACK never adopts older wheels or resets the newer prediction head.
        end
    end
end
local function mark_backpressure(s,reason,serial)
    s.backpressure=reason;s.backpressure_steps+=1;s.last_backpressure_serial=serial
    s.continuity_pending=true;s.continuity_skipped_steps+=1
    -- The absent command applies no modeled axle torque. Keep virtual wheel
    -- spin as an explicit coast assumption; this is not native wheel evidence.
end
local function command_backpressure(s)
    if #s.pending>=MAX_PENDING then return "receipt_capacity" end
    for _,p in ipairs(s.pending) do
        if not p.acknowledged and p.outcome=="queued" then return "native_inbox_queued" end
    end
    return nil
end
local function companion_result(s,frame,contact,actions)
    local out = {rotation_reserved=false,requests={},events={}}
    if s.tricks then
        local result = invoke(s,s.tricks.step,s.tricks,frame,contact,actions)
        -- A trick is presentation and its air rotation reservation only. An
        -- adapter that refuses or is unavailable leaves this step without a
        -- trick, decided by the kernel and the recovery below as if Ride had
        -- none. A stop during the call, or a trick bound to another frame or
        -- asking for an unknown effect, still stops. A missing step callback
        -- has no current flag (nothing was called), so only a call that ran
        -- into a stop counts as one.
        if result.current==false then return nil,"stopped during trick adapter" end
        local value = result[1] and result.n == 2 and type(result[2]) == "table" and result[2] or nil
        if not value then
            out.trick_fallback = "trick adapter unavailable"
        elseif value.valid then
            local bound=value.binding
            if type(bound)~="table" or bound.body_handle~=frame.body_handle or bound.physics_epoch~=frame.physics_epoch
                or bound.lease_handle~=frame.source.lease_handle or bound.serial~=frame.serial or bound.time~=frame.time
                or bound.seconds~=frame.seconds or not same_observation(bound.source,frame.source)
                or value.fresh~=true or value.advanced~=true or type(value.requests)~="table"
                or type(value.requests.rotation_reserved)~="boolean" then return nil,"trick frame mismatch" end
            for name in pairs(value.requests) do
                if name~="rotation_reserved" and name~="scope" then return nil,"unknown trick effect request" end
            end
            out.rotation_reserved=value.requests.rotation_reserved
            out.events=copy(value.model_events)
            -- Keep the producer's private binding on the full result. Never
            -- stamp an unbound bare authored target as a measured native pose.
            out.visual_targets=value.visual_targets and copy(value) or nil
            out.trick=copy(value)
        else out.trick_fallback = "trick adapter refused: " .. detail(value.issue) end
    end
    if s.recovery then
        local result = invoke(s,s.recovery.update,s.recovery,frame)
        if not result[1] or result.n ~= 2 or not result.current or type(result[2]) ~= "table" then return nil,"recovery adapter unavailable" end
        out.recovery = copy(result[2])
        if type(result[2].requests)=="table" and result[2].requests.stop then
            return nil,"recovery stop: " .. detail(result[2].requests.stop.reason)
        end
        if result[2].suppress_forces==true then return nil,"recovery retains force suppression" end
    end
    if s.alignment then
        local result = invoke(s,s.alignment.solve,frame,s.geometry,out.visual_targets,s.alignment_options)
        -- Alignment currently returns requested targets only. It has no native
        -- rig/apply receipt; failure here cannot establish or mutate an actor.
        out.alignment = result[1] and result.n==2 and result.current and copy(result[2])
            or {status="unavailable",native_alignment=false}
    end
    return out
end
local function wheel_plan(frame,geometry,gravity,probe_extra,steer)
    if type(geometry)~="table" or not M.vec(geometry.com,10) or not M.vec(geometry.front_axle,10)
        or not M.vec(geometry.rear_axle,10) or not M.finite(geometry.wheel_radius)
        or geometry.wheel_radius<.01 or geometry.wheel_radius>2
        or not M.finite(probe_extra) or probe_extra<.15 or probe_extra>.75 then return nil end
    local down=M.unit(gravity)
    if not down then return nil end
    -- Contact rays follow the last accepted steer drawn on this measured body.
    -- Current input and an unaccepted force preview cannot move their hubs.
    local front=Geometry.front_axle_at(geometry,steer)
    if not front then return nil end
    local rays,centers={},{}
    for i,axle in ipairs({front,geometry.rear_axle}) do
        local center=M.add(frame.body.center_of_mass,M.turn(frame.body.orientation,M.sub(axle,geometry.com)))
        local target=M.add(center,M.mul(down,geometry.wheel_radius+probe_extra))
        if not M.vec(center,100000) or not M.vec(target,100000) then return nil end
        centers[i]=center
        rays[i]={from=native(center),to=native(target)}
    end
    return freeze(rays),centers
end
local function contact_binding(s,frame,decoded,count)
    if type(decoded)~="table" or decoded.valid~=true or type(decoded.binding)~="table"
        or decoded.binding.body_handle~=frame.body_handle or decoded.binding.physics_epoch~=frame.physics_epoch
        or decoded.binding.lease_handle~=frame.source.lease_handle or type(decoded.frame)~="table"
        or decoded.frame.serial~=frame.serial or decoded.frame.time~=frame.time or decoded.frame.seconds~=frame.seconds
        or type(decoded.frame.source)~="table"
        or type(decoded.rays)~="table" or #decoded.rays~=count or type(decoded.query)~="table"
        or decoded.query.epoch_matches~=true
        or decoded.query.owned_bodies_excluded~=true or decoded.query.budget_exhausted~=false then
        return nil,"contact decode binding or native exclusions unavailable"
    end
    for _,name in ipairs({"generation","user","sequence","source_epoch","context_generation","observation_serial","observed_ms","packet"}) do
        if decoded.frame.source[name]~=frame.source[name] then return nil,"contact selected source identity mismatch" end
    end
    local qualified=invoke(s,s.contact.actor_lane_qualified,decoded.query)
    local expected=s.contact.CATEGORY_WHEEL_LANE_QUALIFIED==true and "named_categories_absent" or "identity"
    if not qualified[1] or qualified.n~=2 or qualified[2]~=true or not qualified.current or s.stopped
        or decoded.query.actor_lane~=expected then return nil,"contact actor lane unavailable" end
    return true
end
-- One shape the contact readers refuse makes the whole native batch unavailable. That costs a wheel a step of
-- support, not the ride: ask again a wheel at a time, on the terrain preset for a wheel that still fails, and
-- carry a wheel neither query can read as clear.
local function wheel_batch(s,epoch,plan,options)
    local probed=invoke(s,s.api.probe_batch,epoch,plan,options)
    if not probed[1] or probed.n~=2 or not probed.current or s.stopped then return probed end
    local batch=probed[2]
    if type(batch)~="table" or batch.status~="unavailable" or batch.reason~="contact_measurement_unavailable" then return probed end
    local function read(ray,query)
        local one=invoke(s,s.api.probe_batch,epoch,{ray},query)
        if not one[1] or one.n~=2 or not one.current or s.stopped then return nil,one end
        local row=one[2]
        if type(row)=="table" and row.status=="available" and type(row.rays)=="table" then return row.rays[1] end
        return nil
    end
    local rays={}
    for i,ray in ipairs(plan) do
        local row,failed=read(ray,options)
        if failed then return failed end
        if not row then
            row,failed=read(ray,{require_contact=true,query_preset="terrain"})
            if failed then return failed end
        end
        rays[i]=row or {status="clear"}
    end
    s.wheel_rereads=(s.wheel_rereads or 0)+1
    return {true,{status="available",native_casts=#plan,budget_exhausted=false,epoch=epoch,local_actor_excluded=false,
        owned_bodies_excluded=true,rays=rays,requested_query_preset=options.query_preset,
        named_actor_categories_absent=options.require_named_actor_categories_absent==true or nil},n=2,current=true}
end
local function wheel_contacts(s,frame,decoded,centers,geometry)
    local bound,why=contact_binding(s,frame,decoded,2)
    if not bound then return nil,why end
    local samples,grounded={},false
    local forward=M.turn(frame.body.orientation,{0,0,1})
    for i,ray in ipairs(decoded.rays) do
        if ray.status=="clear" then
            -- The paired clear-aware Forces/Solver accepts this absence.
            samples[i]={contact={status="clear"}}
        elseif ray.status=="hit" and ray.normal_available==true and ray.surface_velocity_available==true
            and ray.motion=="measured" and M.vec(ray.position,100000) and M.vec(ray.normal,1)
            and M.vec(ray.surface_velocity,50) then
            -- A wheel shoved into a kerb or a face it cannot roll on loses a step of support, not the ride.
            local basis=math.abs(M.length(ray.normal)-1)<=.001 and M.basis(ray.normal,forward) or nil
            local separation=basis and M.dot(M.sub(centers[i],ray.position),basis.normal)-geometry.wheel_radius
            if basis and M.finite(separation) and separation<-.10
                and separation>-(basis.normal[2]>=.95 and HELD_FLAT_FLOOR or HELD_FLOOR) then
                local down=M.unit(s.force.tuning.gravity)
                samples[i]={contact={status="hit",point=M.add(centers[i],M.mul(down,(geometry.wheel_radius-HELD_DEPTH)/-M.dot(down,basis.normal))),
                    normal=basis.normal,forward=basis.forward,surface_velocity=copy(ray.surface_velocity)},separation=-HELD_DEPTH,
                    ray_point=copy(ray.position),ray_separation=separation,
                    wheel_center=copy(centers[i]),wheel_radius=geometry.wheel_radius,
                    verified_plane=false,balance_normal_available=false}
                grounded=grounded or Forces.eligible_support(frame.body,samples[i],.005,.10)
            elseif basis and M.finite(separation) and separation>=-.10 then
                samples[i]={contact={status="hit",point=copy(ray.position),normal=basis.normal,
                    forward=basis.forward,surface_velocity=copy(ray.surface_velocity)},separation=separation,
                    wheel_center=copy(centers[i]),wheel_radius=geometry.wheel_radius,
                    verified_plane=false,balance_normal_available=false}
                grounded=grounded or Forces.eligible_support(frame.body,samples[i],.005,.10)
            else samples[i]={contact={status="clear"}} end
        else samples[i]={contact={status="clear"}} end
    end
    -- Contact.decode returns a new table frozen all through: kept as it is,
    -- where detaching copied it. Anything else is detached as before.
    return {samples=samples,grounded=grounded,decoded=frozen_whole(decoded) or detached(decoded),
        support={known=true,grounded_known=true,grounded=grounded,epoch=frame.physics_epoch,
            provenance="measured_rays_authored_wheel_geometry",native_collision_contact=false,
            actor_lane=decoded.query.actor_lane,
            actor_tripwire=decoded.query.actor_lane=="identity" and "not_required_identity_lane" or nil,
            landing_quality_available=false,reason="landing_quality_not_qualified"}}
end
local function rider_tripwire_plan(frame,geometry)
    -- These authored capsule crossings require P2 before a private trial may
    -- qualify them. Clear rows only avoid this refusal; they grant no identity.
    local lateral=M.mul(M.turn(frame.body.orientation,{1,0,0}),.6)
    local rays={}
    for i,point in ipairs({{0,.89,-.305},{0,1.085,-.225},{0,1.40,.135}}) do
        local center=M.add(frame.body.center_of_mass,M.turn(frame.body.orientation,M.sub(point,geometry.com)))
        local a,b=M.sub(center,lateral),M.add(center,lateral)
        if not M.vec(a,100000) or not M.vec(b,100000) then return nil end
        rays[i]={from=native(a),to=native(b)}
    end
    return freeze(rays)
end
local function rider_tripwire(s,frame,options)
    local plan=rider_tripwire_plan(frame,s.geometry)
    if not plan then return nil,"rider tripwire geometry unavailable" end
    local probed=invoke(s,s.api.probe_batch,frame.physics_epoch,plan,options)
    if not probed[1] or probed.n~=2 or not probed.current or s.stopped then return nil,"rider tripwire batch unavailable" end
    local contacted=invoke(s,s.contact.decode,frame,plan,probed[2])
    if not contacted[1] or contacted.n~=2 or not contacted.current or s.stopped then return nil,"rider tripwire decode unavailable" end
    local decoded=contacted[2]
    local bound=contact_binding(s,frame,decoded,3)
    if not bound or decoded.status~="available" then return nil,"rider tripwire lane or binding unavailable" end
    for _,row in ipairs(decoded.rays) do
        if row.status~="clear" then return nil,"rider tripwire hit" end
    end
    return true
end
-- The nearest face ahead of a body and what it asks of it, {gap, closing, face, force}, or nil when the rays
-- found none. Ride passes the forecast this step's command acts on, so last step's push is already in its speed.
-- A batch the lane cannot read stops nothing, and says so: nil, "unread".
local function ahead(s,frame,body,options,contact)
    local q=M.normalized(body.orientation)
    local up=M.turn(q,{0,1,0})
    local forward=M.turn(q,{0,0,1})
    local origin=M.sub(body.center_of_mass,M.turn(q,s.geometry.com))
    -- In a manual the bike is pitched 20 to 36 degrees. Its knee lanes started a metre up and climbed with it, and
    -- from 30 degrees a car's vertical face is too steep to its up to count as one, so a car was ridden into. The
    -- lanes are laid as on the bike set down level about its rear hub, on the ground under the rear wheel; the
    -- front then reads about .12 m ahead of the lifted tyre at 30 degrees, so a car is stopped at slightly early.
    local rear=contact.samples[2]
    if s.manual_active and rear and rear.contact.status=="hit" and rear.separation<=.02 then
        local ground=M.unit(rear.contact.normal)
        local level=ground and M.unit(M.sub(forward,M.mul(ground,M.dot(forward,ground))))
        if level then
            local g=s.geometry
            local hub=M.add(body.center_of_mass,M.turn(q,M.sub(g.rear_axle,g.com)))
            up=ground
            origin=M.sub(M.sub(hub,M.mul(up,g.rear_axle[2])),M.mul(level,g.rear_axle[3]))
        end
    end
    local v=body.linear_velocity
    local along=M.sub(v,M.mul(up,M.dot(v,up)))
    local speed=M.length(along)
    local heading=M.unit(M.sub(forward,M.mul(up,M.dot(forward,up))))
    if not heading then return nil,"unread" end
    -- Slower than this the travel is no direction: look along the bike, so a bike nosed in is still watched.
    local travel=speed>=.3 and M.mul(along,1/speed) or heading
    -- The lanes sit on the bike as it points, the end that leads leading, and their rays run along the travel.
    if M.dot(heading,travel)<0 then heading=M.mul(heading,-1) end
    local side=M.unit(M.cross(up,heading))
    if not side then return nil,"unread" end
    local front=contact.samples[1]
    local under=front and front.contact.status=="hit" and M.unit(front.contact.normal) or nil
    local h=frame.seconds
    local reach=math.clamp(speed*(2*h+.02)+speed*speed/(2*AHEAD_DECEL)+.4,AHEAD_MIN,AHEAD_MAX)
    local plan,parts={},{}
    for i,ray in ipairs({AHEAD_RAYS[1],AHEAD_RAYS[2],AHEAD_RAYS[3],AHEAD_LOW}) do
        local part=M.add(M.add(origin,M.mul(side,ray[1])),M.add(M.mul(up,ray[2]),M.mul(heading,ray[3])))
        local from=M.sub(part,M.mul(travel,AHEAD_BEHIND))
        local to=M.add(from,M.mul(travel,reach+AHEAD_BEHIND))
        if not M.vec(from,100000) or not M.vec(to,100000) then return nil,"unread" end
        parts[i],plan[i]=part,{from=native(from),to=native(to)}
    end
    plan=freeze(plan)
    local probed=invoke(s,s.api.probe_batch,frame.physics_epoch,plan,options)
    if not probed[1] or probed.n~=2 or not probed.current or s.stopped then return nil,"unread" end
    local contacted=invoke(s,s.contact.decode,frame,plan,probed[2])
    if not contacted[1] or contacted.n~=2 or not contacted.current or s.stopped then return nil,"unread" end
    local decoded=contacted[2]
    if not contact_binding(s,frame,decoded,#plan) or decoded.status~="available" then return nil,"unread" end
    local function usable(row)
        return row.status=="hit" and row.normal_available==true and M.vec(row.position,100000) and M.vec(row.normal,1)
            and M.length(row.normal)>.5
    end
    local low,ramp=decoded.rays[4],nil
    if usable(low) and math.abs(M.dot(M.unit(low.normal),up))>=AHEAD_FACE_UP then
        ramp=M.dot(M.sub(low.position,parts[4]),travel)
    end
    local face
    for i=1,#AHEAD_RAYS do
        local row=decoded.rays[i]
        if usable(row) then
            local n=M.unit(row.normal)
            local facing=-M.dot(n,travel)
            -- From the part of the bike in that lane to the face, along the travel and then square to the face.
            local reached=M.dot(M.sub(row.position,parts[i]),travel)
            if math.abs(M.dot(n,up))<AHEAD_FACE_UP and (not under or math.abs(M.dot(n,under))<AHEAD_FACE_UP)
                and facing>AHEAD_FACING and not (ramp and ramp<reached) then
                local gap=reached*facing
                if not face or gap<face.gap then face={gap=gap,normal=n,point=copy(row.position)} end
            end
        end
    end
    if not face then return nil end
    local closing=-M.dot(v,face.normal)
    local out={gap=face.gap,closing=closing,face=face}
    if closing<=0 then return out end
    local allowed=face.gap>0 and math.sqrt((AHEAD_DECEL*h)^2+2*AHEAD_DECEL*face.gap)-AHEAD_DECEL*h or -AHEAD_REBOUND*closing
    if closing>allowed then out.force=M.mul(face.normal,math.min(body.mass*(closing-allowed)/h,AHEAD_FORCE)) end
    return out
end
local function packet(model,companions,h,crash,push)
    if type(model) ~= "table" or model.valid ~= true or not M.vec(model.force) or not M.vec(model.torque)
        or not M.vec(model.hop_impulse) then return nil end
    local torque = crash and M.add(model.torque,crash) or copy(model.torque)
    local request_count=0
    for key in pairs(companions.requests or {}) do
        if type(key)~="number" or key%1~=0 or key<1 or key>#companions.requests then return nil end
        request_count+=1
    end
    if request_count~=#(companions.requests or {}) then return nil end
    for _, request in ipairs(companions.requests or {}) do
        if type(request) ~= "table" or request.kind ~= "torque" or not M.vec(request.torque,4000) then return nil end
        torque = M.add(torque,request.torque)
    end
    local force,impulse = push and M.add(model.force,push) or model.force,model.hop_impulse
    if M.length(force)>40000 or M.length(torque)>4000 or M.length(impulse)>600
        or M.length(M.add(force,M.mul(impulse,1/h)))>40000 then return nil end
    local command = {force=native(force),torque=native(torque)}
    if model.hop_applied then
        if type(model.hop_event_id) ~= "number" or model.hop_event_id < 1
            or model.hop_event_id > 4294967295 or model.hop_event_id % 1 ~= 0 then return nil end
        command.impulse,command.impulse_id = native(impulse),model.hop_event_id
    elseif M.length(impulse) ~= 0 then return nil end
    return freeze(command)
end
local function observe(s,source_frame,raw,context)
    if not ACTIVATION_QUALIFIED or s.stopped then return end
    if type(context)~="table" or not clock(s,context.now_ms) then stop(s,"caller watchdog clock invalid");return end
    if context.focused~=true or context.menu_open~=false or context.loaded~=true then
        stop(s,"current readiness unavailable");return
    end
    local key=source_key(source_frame)
    if not key then stop(s,"exact selected source unavailable");return end
    if s.bound_source and not same_source(key,s.bound_source) then stop(s,"selected source identity changed");return end
    local staged,why=stage_input(s,source_frame,key)
    if not staged then stop(s,why);return end
    -- stage_input has just made staged_last a detached copy of this key, or
    -- found it field for field equal to it (same_input); either way it is the
    -- detached key.
    s.bound_source=s.staged_last
    -- Stage even on duplicate bodies and while a command receipt is pending.
    local sample,body=sample_copy(raw)
    if not sample then stop(s,"native body sample invalid");return end
    if context.body_read_recovered==true then
        -- Core recovered its one guarded read, not an unobserved model step.
        -- Keep every pending receipt, accepted hop and predicted wheel state;
        -- only derivative history is invalidated before the next preview.
        s.continuity_pending=true;s.body_read_recoveries+=1
    end
    if s.last_sample then
        local order=Identity.compare(sample.serial,s.last_sample.serial)
        if order==0 then
            if not equal_sample(sample,s.last_sample) then stop(s,"changed duplicate native sample") end
            poll_pending(s)
            return
        end
        if order<0 or sample.time<=s.last_sample.time or sample.seconds~=s.last_sample.seconds then
            stop(s,"native sample regressed");return
        end
        local steps=Identity.bounded_delta(sample.serial,s.last_sample.serial,64)
        if not steps or math.abs(sample.time-s.last_sample.time-steps*sample.seconds)>steps*1e-6 then
            -- No manufactured update(0), missed step, heading or landing.
            stop(s,"unobserved native body step gap");return
        end
        -- A frame long enough to run two physics steps is a hitch to ride through: this model step starts from
        -- what is measured now, with no derivative across the gap.
        if steps>1 then s.continuity_pending=true;s.step_gaps=(s.step_gaps or 0)+1 end
    end
    s.last_sample=sample -- Consume before callbacks. This native serial cannot submit twice.
    -- A rolling body stops here, on its consumed sample, before any query or
    -- command (ROLL_STOP_RATE). A tipping body stops once the rays say what it
    -- is tipping from (fall).
    local tilt,roll=attitude(body,s.force.tuning.gravity)
    if not tilt then stop(s,"measured tilt unavailable");return end
    if math.abs(roll)>ROLL_STOP_RATE then
        stop(s,string.format("measured roll rate %.2f rad/s over the %d rad/s Ride stop",math.abs(roll),ROLL_STOP_RATE));return
    end
    if not s.crash then
        local hit_speed,travel=hit(s,body)
        if hit_speed then
            local forward=M.turn(M.normalized(body.orientation),{0,0,1})
            s.crash={speed=hit_speed,steps=0,way=M.dot(travel,forward)<0 and -1 or 1}
        end
    end
    if s.crash then
        s.crash.steps+=1
        if tilt>CRASH_TILT_DEG or s.crash.steps>CRASH_STEPS then
            stop(s,string.format("hit something at %.1f m/s",s.crash.speed));return
        end
    end
    s.observed_steps+=1
    s.metrics_step={serial=sample.serial,physics_time=sample.time,report=false}
    -- Check observed limits before prediction, model work or command
    -- backpressure can conceal them. Exact accepted receipts remain drainable.
    if s.admit_measured then
        local admitted=invoke(s,s.admit_measured,s.force,detached(body))
        if not admitted[1] or admitted.n~=3 or not admitted.current or s.stopped
            or type(admitted[2])~="boolean" or type(admitted[3])~="string"
            or admitted[2] and admitted[3]~="none" or not admitted[2] and (admitted[3]=="none" or admitted[3]=="") then
            stop(s,"measured body admission unavailable");return
        end
        if not admitted[2] then stop(s,"measured body refused: "..admitted[3]);return end
    end
    -- One exact queued observation per body step preserves non-hop selection /
    -- release ordering without stepping Trick twice at one native epoch. Bind
    -- the frame to that real observation, never restamp it as the latest poll.
    local input_frame=s.input_queue[1]
    -- A key source_key makes is new and is never changed, so it is frozen in
    -- place: the frame and model_source below then share it uncopied.
    local model_source=input_frame and source_key(input_frame) or s.model_source
    if input_frame and model_source then freeze(model_source) end
    if not model_source then stop(s,"no staged model input observation");return end
    local frame=detached({valid=true,fresh=true,body_handle=s.body,physics_epoch=sample.epoch,
        serial=sample.serial,time=sample.time,seconds=sample.seconds,body=body,sample=sample,source=model_source,
        owner={body_handle=s.body,lease_handle=model_source.lease_handle},gates={focused=true,menu_open=false},
        now_ms=s.now,active=true,loaded=true,telemetry=copy(context.telemetry),observed=copy(context.observed)})
    local authored_steer=s.pose.steer
    local plan,centers=wheel_plan(frame,s.geometry,s.force.tuning.gravity,s.wheel_probe_extra,authored_steer)
    if not plan then stop(s,"authored wheel geometry unavailable");return end
    local category_lane=s.contact.CATEGORY_WHEEL_LANE_QUALIFIED==true
    local query_options=category_lane
        and {require_contact=true,query_preset="camera",require_named_actor_categories_absent=true}
        or {require_contact=true,exclude_local_actor=true}
    local rereads=s.wheel_rereads
    local probed=wheel_batch(s,sample.epoch,plan,query_options)
    if not probed[1] or probed.n~=2 or not probed.current or s.stopped then stop(s,"native contact batch unavailable");return end
    local contacted=invoke(s,s.contact.decode,frame,plan,probed[2])
    if not contacted[1] or contacted.n~=2 or not contacted.current or s.stopped then stop(s,"contact decode unavailable");return end
    local contact,issue=wheel_contacts(s,frame,contacted[2],centers,s.geometry)
    if not contact then stop(s,issue);return end
    local fallen,fall_limit=fall(s,body,tilt,contact)
    if fallen then
        stop(s,string.format("measured tilt %.1f deg over the %d deg Ride stop",fallen,fall_limit));return
    end
    if category_lane then
        -- The tripwire is cast on the first wheel batch and then every
        -- TRIPWIRE_EVERY measured epochs (S1b in game: 0.34 ms a batch). A
        -- refusal still stops Ride before any model or command; in between it
        -- lags by one epoch (16.7 ms at 60 Hz, 5 cm at the S1 3 m/s cap), and
        -- the support record says so.
        local since=s.tripwire_serial and Identity.bounded_delta(sample.serial,s.tripwire_serial,TRIPWIRE_EVERY-1)
        if since and since>0 then
            contact.support.actor_tripwire="authored_rider_crossings_clear_previous_epoch_v1"
        else
            -- Something beside the rider is scenery to ride past. The wheel lane's own answer decides support.
            rider_tripwire(s,frame,query_options)
            s.tripwire_serial=sample.serial
            contact.support.actor_tripwire="authored_rider_crossings_clear_v1"
        end
    end
    s.ahead=nil
    -- Contact diagnostics exist only after the complete wheel binding and,
    -- where required, the independent rider tripwire have passed.
    s.metrics_step.contact={serial=sample.serial,body_height=body.center_of_mass[2],
        front_hit=contact.samples[1].contact.status=="hit",rear_hit=contact.samples[2].contact.status=="hit",
        front_separation=contact.samples[1].separation,rear_separation=contact.samples[2].separation,
        grounded=contact.grounded,tilt=tilt,roll_rate=roll,steer=authored_steer}
    s.metrics_step.measured_rear_hub=centers[2]
    s.metrics_step.measured_rear_hit=contact.samples[2].contact.point
    s.metrics_step.measured_rear_normal=contact.samples[2].contact.normal
    curb_strike(s,body,contact)
    -- The frame is frozen whole, so a shallow copy shares everything in it.
    local enriched=table.clone(frame)
    -- contact is complete here and only read from now on (the fold and the
    -- kernel copy what they change), so it is frozen in place.
    enriched.contact,enriched.support=freeze(contact),detached(contact.support)
    frame=freeze(enriched)
    if input_frame then
        table.remove(s.input_queue,1)
        s.input_consumed+=1
        metrics_report(s,model_source)
        local mapped=invoke(s,s.mapping.observe,s.mapping,input_frame,{grounded=contact.grounded,
            focused=true,menu_open=false,rotation_reserved=false})
        if not mapped[1] or mapped.n~=2 or not mapped.current or s.stopped or type(mapped[2])~="table" then
            stop(s,"input mapping unavailable");return
        end
        s.model_source=detached(model_source)
    end
    local controlled=invoke(s,s.mapping.controls,s.mapping,{physics_epoch=sample.epoch,h=sample.seconds,
        grounded=contact.grounded,rotation_reserved=false})
    local controls=controlled[1] and controlled.n==2 and controlled[2] or nil
    if not controlled.current or s.stopped then return end
    if type(controls)~="table" or controls.valid~=true or controls.submission_allowed~=true then
        -- Once a model has advanced, silently omitting an observed physics
        -- epoch would make its later chronology false. Initial neutral prime
        -- may wait; a later unavailable action frame terminates this instance.
        if s.model_steps>0 then stop(s,"non-initial model cadence unavailable") end
        poll_pending(s);return
    end
    if controls.physics_epoch~=sample.epoch or controls.h~=sample.seconds or not same_observation(controls.source,model_source) then
        stop(s,"mapped native frame mismatch");return
    end
    -- Polling below can retire this accepted event while controls still holds
    -- its earlier projection. Remember its owner before consuming receipts.
    local hop_owned=controls.hop and accepted_hop_owner(s,controls.hop.id) or false
    if controls.hop and (s.hop_policy=="suppress"
        or s.hop_policy=="grounded_once" and not contact.grounded and not hop_owned) then
        local id=controls.hop.id
        if not suppress_hop(s,id) then return end
        -- Refresh the same pure action projection after local retirement. No
        -- source observation, body step, force receipt or native hop is made.
        local refreshed=invoke(s,s.mapping.controls,s.mapping,{physics_epoch=sample.epoch,h=sample.seconds,
            grounded=contact.grounded,rotation_reserved=false})
        local next_controls=refreshed[1] and refreshed.n==2 and refreshed[2] or nil
        if not refreshed.current or s.stopped or type(next_controls)~="table" or next_controls.valid~=true
            or next_controls.submission_allowed~=true or next_controls.physics_epoch~=sample.epoch
            or next_controls.h~=sample.seconds or not same_observation(next_controls.source,model_source)
            or next_controls.hop~=nil or type(next_controls.force_controls)~="table"
            or next_controls.force_controls.hop_event_id~=0 or next_controls.force_controls.hop_strength~=0
            or type(next_controls.actions)~="table" or next_controls.actions.hop_pressed~=false
            or next_controls.actions.hop_strength~=0 then
            s.unknown=true;stop(s,"hop suppression controls unavailable");return
        end
        controls=next_controls
    end
    if controls.hop and not hop_owned and not Identity.bounded_delta(key.observed_ms,controls.hop.observed_ms,100) then
        stop(s,"hop request expired before body progress");return
    end
    if s.tricks and type(controls.actions)~="table" then stop(s,"bound trick action snapshot unavailable");return end
    local companions,companion_issue=companion_result(s,frame,contacted[2],controls.actions)
    if not companions then stop(s,companion_issue);return end
    if s.stopped then return end
    s.model_steps+=1
    s.trick_status=companions.trick and companions.trick.issue or companions.trick_fallback
    if companions.trick_fallback then s.trick_fallbacks+=1 end
    s.alignment_status=companions.alignment and companions.alignment.status or nil
    s.recovery_status=companions.recovery and companions.recovery.phase or nil
    -- This new path observes the already qualified ray frame before the gate,
    -- while the existing companions above retain their observed-step policy.
    -- It changes no accepted trick state until the command is admitted below.
    if s.accepted_barspin then
        local prepared=invoke(s,s.accepted_barspin.preview,s.accepted_barspin,frame,controls.actions)
        if prepared.current==false or s.stopped then return end
        local value=prepared[1] and type(prepared[2])=="table" and prepared[2] or nil
        if value and value.valid==true and prepared.n==3 and type(prepared[3])=="table" then
            s.barspin_candidate,s.barspin_preview=prepared[3],value;s.barspin_issue="candidate"
        else s.barspin_issue=value and detail(value.issue) or "adapter unavailable" end
    end
    -- Every coherent observed model step happens before the command gate.
    poll_pending(s,frame,contact,authored_steer)
    if s.stopped or s.unknown then return end
    s.backpressure=command_backpressure(s)
    if s.backpressure then
        -- This measured step is visible but uncommanded. Never replay it or
        -- advance a force preview as though a packet had been accepted.
        mark_backpressure(s,s.backpressure,sample.serial)
        return
    end
    if s.continuity_pending then
        local invalidated=invoke(s,s.force.invalidate_continuity,s.force)
        if not invalidated[1] or invalidated.n~=1 or not invalidated.current or s.stopped then
            s.unknown=true;stop(s,"force history continuity invalidation unavailable");return
        end
        s.continuity_pending=false;s.continuity_invalidations+=1
    end
    local force_controls=copy(controls.force_controls)
    -- Going over the bars the rider lets go of everything: the front is left to the ordinary spring and the crash
    -- torque, never held up by a manual.
    if s.crash then force_controls.pedal,force_controls.manual,force_controls.nose_manual=0,0,0 end
    force_controls.rotation_reserved=force_controls.rotation_reserved or companions.rotation_reserved==true
        or (s.barspin_preview~=nil and s.barspin_preview.requests.rotation_reserved==true)
    -- Solve from the state this command will act on. Accepted commands
    -- younger than InFlight.VISIBLE_STEPS are not in the sample yet; fold them in first.
    local inflight={}
    for _,q in ipairs(s.pending) do
        local age=q.sequence and q.force and q.torque and Identity.bounded_delta(sample.serial,q.serial,64)
        if age and age<InFlight.VISIBLE_STEPS and (q.outcome==nil or q.outcome=="queued" or q.outcome=="applied") then
            inflight[#inflight+1]={age=age,force=q.force,torque=q.torque,impulse=q.impulse,impulse_id=q.impulse_id}
        end
    end
    local folded=invoke(s,InFlight.fold,sample.seconds,s.force.tuning.gravity,inflight,body,contact.samples)
    if not folded[1] or not folded.current or s.stopped or type(folded[2])~="table" or type(folded[3])~="table" then
        if folded[1] and folded.current and not s.stopped and refused_step(s,tostring(folded[3])) then return end
        stop(s,"in-flight fold unavailable: "..tostring(folded[3]));return
    end
    -- The forecast can carry a wheel past the depth the kernel admits, in the
    -- same step its ray did not. Hold it at the same depth as wheel_contacts.
    for _,row in ipairs(folded[3]) do
        if row.contact.status=="hit" and row.separation< -HELD_DEPTH and row.wheel_center then
            local down=M.unit(s.force.tuning.gravity)
            row.separation=-HELD_DEPTH
            row.contact.point=M.add(row.wheel_center,M.mul(down,(row.wheel_radius-HELD_DEPTH)/-M.dot(down,row.contact.normal)))
        end
    end
    -- Faces ahead of the forecast. One batch more, but not on a step whose wheels already took the slow path:
    -- a serial allows four.
    local looked=s.wheel_rereads==rereads
    local unread
    if looked then s.ahead,unread=ahead(s,frame,folded[2],query_options,contact) end
    if s.stopped then return end
    local closing_face=s.ahead~=nil and s.ahead.closing>0
    if s.ahead and s.ahead.force and s.ahead.closing>=HIT_DROP then s.ahead_hit=math.max(s.ahead_hit or 0,s.ahead.closing)
    elseif looked and not unread and not closing_face then s.ahead_hit=nil end
    if s.ahead_hit and not s.crash and closing_face and s.ahead.gap<AHEAD_PEDAL_GAP then
        local forward=M.turn(M.normalized(body.orientation),{0,0,1})
        s.crash={speed=s.ahead_hit,steps=0,way=M.dot(body.linear_velocity,forward)<0 and -1 or 1,face=s.ahead.face}
    end
    -- Going over the bars tips the rays off the face. The tyre jammed at it stops the bike there: its travel
    -- along the ground is taken out while it is near the face, and only that, so it still falls.
    if s.crash and s.crash.face and not (s.ahead and s.ahead.force) then
        local b,face=folded[2],s.crash.face
        local down=M.unit(s.force.tuning.gravity)
        local travel=M.sub(b.linear_velocity,M.mul(down,M.dot(b.linear_velocity,down)))
        local moving=M.length(travel)
        if moving>.05 and math.abs(M.dot(M.sub(b.center_of_mass,face.point),face.normal))<AHEAD_HOLD_REACH then
            s.ahead={gap=0,closing=-M.dot(b.linear_velocity,face.normal),face=face,
                force=M.mul(travel,-math.min(b.mass/sample.seconds,AHEAD_FORCE/moving))}
        end
    end
    if s.crash or closing_face and s.ahead.gap<AHEAD_PEDAL_GAP then force_controls.pedal=0 end
    if s.metrics_step.contact and s.ahead then
        s.metrics_step.contact.ahead_gap,s.metrics_step.contact.ahead_closing=s.ahead.gap,s.ahead.closing
    end
    local preview=invoke(s,s.force.preview,s.force,sample.seconds,folded[2],s.wheels,folded[3],force_controls)
    local model,candidate=preview[2],preview[3]
    if not preview[1] or preview.n~=3 or not preview.current or s.stopped or type(candidate)~="table" then
        stop(s,"force preview unavailable");return
    end
    -- A kerb's push rides with a stop's, added to it: both are the world taking speed off the bike.
    local push=s.ahead and s.ahead.force
    local curb,curb_paid=curb_push(s,folded[2],sample.seconds)
    if curb then push=push and M.add(push,curb) or curb end
    local command=packet(model,companions,sample.seconds,s.crash and crash_torque(s,body) or nil,push)
    if not command then -- Name the ForceStage refusal and the unsent magnitudes.
        local d=type(model)=="table" and (type(model.diagnostic)=="table" and model.diagnostic or model) or {}
        local b=folded[2]
        local why=type(model)=="table" and tostring(model.issue) or "no model"
        force_refusal(s,why,d,sample,body,b,contact)
        if M.vec(d.force) and M.vec(d.torque) then why..=string.format(" |F| %.0f N |T| %.0f N*m",M.length(d.force),M.length(d.torque)) end
        if M.vec(b.linear_velocity) and M.vec(b.angular_velocity) then
            local v,w=b.linear_velocity,b.angular_velocity
            why..=string.format(" v(%.2f,%.2f,%.2f) w(%.2f,%.2f,%.2f)",v[1],v[2],v[3],w[1],w[2],w[3])
        end
        if refused_step(s,why) then return end
        stop(s,"bounded force packet unavailable: "..why);return
    end
    s.refused_steps=0
    local wheels=wheel_copy(model.wheels,s.wheels)
    if not wheels then stop(s,"bounded wheel model unavailable");return end
    local pose=presentation(s.pose,model,wheels,sample.seconds,contact.samples,s.geometry,body.orientation,
        M.unit(M.mul(s.force.tuning.gravity,-1)))
    if not pose then stop(s,"bounded presentation model unavailable");return end
    local p={serial=sample.serial,time=sample.time,seconds=sample.seconds,submitted_at=s.now,
        hop_id=model.hop_applied and model.hop_event_id or nil,wheels=wheels,
        force=array(command.force),torque=array(command.torque),impulse=array(command.impulse),impulse_id=command.impulse_id}
    -- Core's closures enforce exact live ownership before AND after effects.
    -- This local reservation survives stop during submit and unknown admission.
    table.insert(s.pending,p)
    local submitted=invoke(s,s.api.submit,sample.epoch,command)
    if submitted[1] and submitted.n==4 and submitted[2]==true and submitted[3]==nil
        and Identity.is_nonzero_u64(submitted[4]) then
        local sequence=submitted[4]
        if s.last_sequence and Identity.compare(sequence,s.last_sequence)~=1 then
            -- Never alias an older receipt when an admitted ID repeats/regresses.
            p.returned_sequence=sequence;p.unknown=true;s.unknown=true
            stop(s,"force admission sequence did not advance");return
        end
        p.sequence=sequence;s.last_sequence=sequence;s.submitted+=1
        if curb_paid then s.curb_loss-=curb_paid end
        metrics_serial(s,"submitted",p.serial)
        -- The returned sequence is command admission, not application or consumption.
        local metric_step=s.metrics_step
        metric_step.published_sequence=sequence
        if type(model.grounded)=="boolean" then metric_step.published_grounded=model.grounded end
        local loads=model.normal_load
        if type(loads)=="table" then
            if M.finite(loads[1]) then metric_step.published_front_load=loads[1] end
            if M.finite(loads[2]) then metric_step.published_rear_load=loads[2] end
        end
        -- Prediction follows exact acceptance order, independent of later ACK.
        -- Actual N+1 application and N+2+ proof remain separate receipt facts.
        local adopted=invoke(s,s.force._adopt,s.force,candidate)
        if not adopted[1] or adopted.n~=1 then
            p.history_unknown=true;s.unknown=true;stop(s,"accepted force history adoption unavailable");return
        end
        if not submitted.current or not adopted.current or s.stopped then
            stop(s,"stopped during force admission");return
        end
        if s.barspin_candidate then
            local accepted=invoke(s,s.accepted_barspin.adopt,s.accepted_barspin,s.barspin_candidate,sequence)
            local value=accepted[1] and accepted.n==3 and accepted[2]==true and accepted[3] or nil
            local target=type(value)=="table" and value.visual_targets or nil
            if not accepted.current or s.stopped or type(value)~="table" or value.serial~=sample.serial
                or value.accepted_sequence~=sequence or value.realized~=false or value.completion_qualified~=false
                or type(target)~="table" or target.realized~=false or target.completion_qualified~=false
                or not M.finite(target.barspin) or math.abs(target.barspin)>math.pi
                or not M.finite(target.tailwhip) or math.abs(target.tailwhip)>math.pi then
                stop(s,"accepted barspin adoption unavailable");return
            end
            for _,name in ipairs(TRICK_RELEASES) do
                local release=target[name]
                if not M.finite(release) or release<0 or release>1 then
                    stop(s,"accepted barspin release unavailable");return
                end
                pose[name]=release~=0 and release or nil
            end
            pose.barspin=target.barspin;pose.tailwhip=target.tailwhip
            s.barspin_presentation=freeze(value);s.barspin_state=s.accepted_barspin:status()
            score_queue(s,frame,value)
            s.barspin_issue="predictive_accepted"
            s.barspin_candidate,s.barspin_preview=nil,nil
        end
        s.wheels=wheels
        -- The accepted step's manual, which the next step's look ahead reads.
        s.manual_active=model.manual_active==true
        -- The pose follows the accepted prediction, with the wheels it adopts;
        -- model_history names that step.
        s.pose=freeze(pose)
        s.model_history=freeze({kind="predictive_accepted",serial=p.serial,sequence=sequence,
            reason="exact_force_admission",native_wheel_state_known=false})
        if s.hop_policy=="grounded_once" then
            if p.hop_id then
                local claimed=invoke(s,s.mapping.claim_hop,s.mapping,p.hop_id)
                if not claimed[1] or claimed.n~=3 or claimed[2]~=true or claimed[3]~="none"
                    or not claimed.current or s.stopped then
                    -- The exact sequence still permits receipt cleanup. Pure
                    -- ownership uncertainty must not quarantine that transport.
                    p.hop_claim_unknown=true;s.unknown=true;stop(s,"accepted hop ownership unavailable");return
                end
            elseif controls.hop and not hop_owned and model.hop_applied==false then
                -- The forecast can already be airborne while measured contact
                -- is grounded. Its accepted preview consumed this local ID.
                if not suppress_hop(s,controls.hop.id) then return end
            end
        end
        if not submitted.current or not adopted.current or s.stopped then stop(s,"stopped during force admission") end
    elseif submitted[1] and submitted.n==3 and submitted[2]==false and type(submitted[3])=="string" then
        table.remove(s.pending,#s.pending)
        if submitted[3]=="force_pipeline_full" then
            mark_backpressure(s,"core_receipt_capacity",sample.serial)
        else retire(s,p,"cancelled");stop(s,"force admission refused") end
    else
        p.unknown=true;s.unknown=true;retire(s,p,"uncertain");stop(s,"force admission outcome unknown")
    end
end

function Ride.new(force_api,models,options)
    models,options=models or {},options or {}
    local accepted_barspin=TrickAdapter.new()
    if models.accepted_barspin==false then accepted_barspin=nil end
    local meta={__index=Object}
    local object=setmetatable({},meta)
    local s={api=force_api,body=options.body_handle,incarnation=options.incarnation,
        mapping=models.mapping or Mapping.new(options.input),force=models.force or Forces.new(options.force),
        contact=models.contact,tricks=models.tricks,recovery=models.recovery,alignment=models.alignment,
        accepted_barspin=accepted_barspin,barspin_state=accepted_barspin and accepted_barspin:status() or nil,
        alignment_options=detached(options.alignment),geometry=detached(options.geometry or Geometry),
        wheels=Forces.proposed_wheels(),phase="inert",issue="native qualification required",generation=0,
        pose=freeze(NEUTRAL_POSE),trick_fallbacks=0,manual_active=false,
        submitted=0,acknowledged=0,pending={},metrics=new_metrics(),backpressure_steps=0,
        continuity_pending=false,continuity_skipped_steps=0,continuity_invalidations=0,body_read_recoveries=0,
        input_queue={},input_staged=0,input_consumed=0,observed_steps=0,model_steps=0,
        score_sequences={},score_issue=models.scoring==false and "disabled" or "waiting_for_mod_catch",score_landing_phase="unavailable"}
    -- Pure optional services. Failure disables only local points; it never
    -- grants or withholds force, body, Source, Follow or cleanup authority.
    if models.scoring~=false then
        s.score_ledger=models.scoring
        if s.score_ledger==nil then
            local made=table.pack(pcall(ModScore.new))
            s.score_ledger=made[1] and made.n==2 and made[2] or nil
        end
        if type(s.score_ledger)~="table" then
            s.score_ledger=nil;s.score_issue="mod score construction unavailable"
        else
            local valid=true
            for _,name in ipairs({"queue","observe","land","cancel","view"}) do
                if type(s.score_ledger[name])~="function" then valid=false end
            end
            if not valid then score_disable(s,"mod score capability unavailable")
            else
                if models.score_landing~=false then
                    s.score_landing=models.score_landing
                    if s.score_landing==nil then
                        local landing=table.pack(pcall(MeasuredLanding.new))
                        s.score_landing=landing[1] and landing.n==2 and landing[2] or nil
                    end
                    if type(s.score_landing)~="table" or type(s.score_landing.step)~="function"
                        or type(s.score_landing.cancel)~="function" then
                        s.score_landing=nil;s.score_issue="measured mod landing unavailable"
                    end
                end
                score_refresh(s)
            end
        end
    end
    if ACTIVATION_QUALIFIED then
        -- Snapshot an immutable model capability once. Raw Forces has no hop
        -- policy and retains its receipt-owned hop behavior unchanged.
        s.hop_policy=s.force.hop_policy
        s.admit_measured=s.force.admit_measured
        s.wheel_probe_extra=.15
        local valid=type(s.body)=="userdata" and s.incarnation~=nil and type(force_api)=="table"
            and type(s.contact)=="table" and type(s.contact.decode)=="function" and type(s.contact.actor_lane_qualified)=="function"
            and (s.hop_policy==nil or s.hop_policy=="suppress" or s.hop_policy=="grounded_once")
            and (s.admit_measured==nil or type(s.admit_measured)=="function")
        if s.hop_policy=="grounded_once" then
            local extra
            if type(s.force.tuning)=="table" then extra=s.force.tuning.wheel_probe_extra else valid=false end
            if extra~=nil then
                if M.finite(extra) and extra>=.15 and extra<=.75 then s.wheel_probe_extra=extra
                else valid=false end
            end
            valid=valid and type(s.mapping.claim_hop)=="function"
        end
        if valid then
            for _,name in ipairs({"probe_batch","submit","receipt","acknowledge"}) do
                if type(force_api[name])~="function" then valid=false end
            end
        end
        if valid then s.phase,s.issue="observing","waiting for exact Core samples"
        else stop(s,"restricted force capability or private binding unavailable") end
    end
    states[object]=s
    table.freeze(object);meta.__metatable="locked";table.freeze(meta)
    return object
end
function Object:observe(source_frame,body_sample,context)
    local s=states[self]
    if not ACTIVATION_QUALIFIED or s.stopped then return status(s) end
    if s.busy then stop(s,"reentrant observe");return status(s) end
    s.busy=true
    local ok,why=pcall(observe,s,source_frame,body_sample,context)
    if not ok then stop(s,"observe exception: "..detail(why)) end
    -- Every early/refused/backpressured path releases its unadopted candidate.
    discard_barspin(s)
    metrics_finish_step(s)
    s.busy=false
    return status(s)
end
function Object:drain()
    local s=states[self]
    if not ACTIVATION_QUALIFIED or #s.pending==0 then return status(s) end
    if s.busy then stop(s,"reentrant drain");return status(s) end
    s.busy=true
    local ok,why=pcall(poll_pending,s)
    if not ok then
        s.unknown=true;for _,p in ipairs(s.pending) do if not p.acknowledged then p.unknown=true end end
        stop(s,"drain exception: "..detail(why))
    end
    s.busy=false
    return status(s)
end
function Object:stop(reason) local s=states[self];stop(s,reason or "Core stop");return status(s) end
function Object:status() return status(states[self]) end
function Object:score_view() local s=states[self];return s.mod_score,s.score_issue,s.score_landing_phase end
return table.freeze(Ride)

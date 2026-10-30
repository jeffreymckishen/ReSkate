-- Private BMX ride recorder with local spawn-clearance sampling. The survey
-- covers the authored bike/rider footprint and margin, not the future route.
-- The recorder retains the historical ride/pose evidence format and
-- hooks nothing inside Core: each tick it reads the status DTO Core already returns from step (Ride's
-- status, Spawn's last measured body sample, the selected Source sample, the Follow receipts and lease,
-- and S2's pose status), one skater.get, on every JOINT_EVERY-th following tick the five skater.joint
-- reads the entry made, the force of each command the entry's pass-through submit wrapper forwarded,
-- and the entry's Lua step time. Rows are integers.
--
-- S2: the summary is kept incrementally, a fixed amount of work a row (Rec:add_row), so summary() costs
-- the same after 3,900 rows as after one; the entry stores only the summary while the ride runs and the
-- rows afterwards, in chunks (main.lua). The verdict is FREE_RIDE (every ride and pose rule), RIDE_UNPOSED
-- (only pose rules fail) or NOT_YET.
local M=require("./force_math")
local G=require("./bike_geometry")
local Rec={}
Rec.MAX_ROWS=3900 -- 65 s at 60 Hz: the 60 s window with margin
Rec.RIDER_MM=50 -- M1's 5 cm rule
Rec.RIDER_SHARE=.9 -- on at least 90% of the rows
-- S2b: the first A is held 0.4 s, to about 1.0 m/s, and covers about v^2/2a = 0.19 m (the fixture: 194 mm, 185 mm
-- at S2's low speed, 174 mm at -10%), so FIRST_RIDE's 0.3 m is now 0.1 m: still well past the 20 mm M4 drift.
Rec.MIN_FORWARD_MM=100 -- at least 0.1 m along the body's +Z while the first A is held
Rec.MAX_FORWARD_MM=3000 -- INTEGRATION_PLAN M5's upper bound
Rec.FALL_TILT_E1=300 -- a body tilted past 30 degrees has fallen
Rec.SEG1_MS=500 -- TR-M45 segment 1 (M4): at least 500 ms of standing support before A
Rec.SEG1_HEIGHT_MM=20
Rec.SEG1_DRIFT_MM=20
Rec.SEG1_SPEED_MMS=200
Rec.SETTLE_MS=250 -- M4 is judged after the floor spawn's 2 cm drop has landed
Rec.TURN_MIN_MRAD=5000 -- S2b: each 17.1 s full-lock hold turns the bike by at least 5 rad (unwrapped)
Rec.STEER_X=500 -- |left_x| x 1000 at or over this marks a left-stick hold row (the scenario uses 1000, full lock)
Rec.TILT_RULE_E1=100 -- tilt under 10 degrees on every row (Ride stops itself past 15)
Rec.STOP_MMS=100 -- each B after the first A: under 0.1 m/s within STOP_WITHIN_MS, and on every later row of it
Rec.STOP_WITHIN_MS=1000
Rec.RESTART_FROM_MMS=100 -- the second A starts from rest ...
Rec.RESTART_RISE_MMS=500 -- ... and raises the speed by at least 0.5 m/s
Rec.FARTHEST_MM=7500 -- farthest_under_7_5m: 1 m inside Spawn's 8.5 m envelope (S2b, resized for a 0.055 deg floor)
Rec.STILL_MMS=250 -- still_at_end: a 0.5 deg slope rolls a released bike to at most 0.18 m/s in the 2.1 s after B
Rec.WINDOW_SLACK_MS=100 -- the window end lands at publish + RIDE_WINDOW_MS to + 100 ms
Rec.LEAD_BAND_MMS=2570 -- the 0.035 m static lead keeps the rider within 5 cm of P up to this speed
Rec.HOST_BUDGET_MS=6 -- launch.ps1 passes --plugin-tick-ms=6; no 1 s window over it (plugin_vm.cpp:437-446)
Rec.TARGET_MS=4 -- the spec's estimate band, reported only
-- The pose rules (S2): the place probe passes once, the Poser is mounted by blend_in + 0.5 s, a pose is
-- sent on 95% of the rows, nothing refuses, skater.pose(nil) is accepted at the end, and the drawn joints
-- sit on the plan sent the tick before: wrists and ankles within 40 mm, hips within 50 mm, each on 90% of
-- its reads.
Rec.POSE_BLEND_IN_MS=250 -- mounted_pose.lua MP.options default blend_in (0.25 s)
Rec.POSE_MOUNT_SLACK_MS=500
Rec.POSE_SENT_SHARE=.95
Rec.POSE_JOINT_SHARE=.9
Rec.JOINT_EVERY=6 -- main.lua reads the five joints on following ticks 1, 7, 13, ...
-- The joints read and the plan target each is held to: skater.joint 7 (hips), 278 and 49 (left and right
-- hand: the wrist), 343 and 10 (left and right foot: the ankle); mounted_pose.lua LIMBS orders left first.
Rec.JOINTS=table.freeze({
    table.freeze({id=7,field="jh",group="hips",side=nil,limit_mm=50}),
    table.freeze({id=278,field="jlw",group="wrists",side=1,limit_mm=40}),
    table.freeze({id=49,field="jrw",group="wrists",side=2,limit_mm=40}),
    table.freeze({id=343,field="jla",group="ankles",side=1,limit_mm=40}),
    table.freeze({id=10,field="jra",group="ankles",side=2,limit_mm=40}),
})
-- Spawn at the actor, so preflight covers the authored footprint and a margin,
-- not the old low-speed lab route. A capsule's horizontal reach is bounded by
-- each endpoint's radius from the origin plus its own radius. Include the
-- wheel's full outer radius as well, then round clearance up to a quarter metre.
local footprint=0
local function include_footprint(point,radius)
    assert(type(point)=="table" and M.finite(point[1]) and M.finite(point[3])
        and M.finite(radius) and radius>=0,"invalid spawn footprint")
    footprint=math.max(footprint,math.sqrt(point[1]^2+point[3]^2)+radius)
end
for _,capsule in ipairs(G.capsules) do
    include_footprint(capsule.a,capsule.radius)
    include_footprint(capsule.b,capsule.radius)
end
include_footprint(G.front_axle,G.wheel_radius)
include_footprint(G.rear_axle,G.wheel_radius)
assert(footprint<=.75,"spawn footprint exceeds the local survey sizing")
Rec.SURVEY_FOOTPRINT_M=footprint
Rec.SURVEY_CLEARANCE_MARGIN_M=.5
Rec.SURVEY_R=math.ceil((footprint+Rec.SURVEY_CLEARANCE_MARGIN_M)*4)/4
assert(Rec.SURVEY_R==1.25,"spawn clearance no longer matches the sampled rings")
Rec.SURVEY_RESIDUAL_M=.04
-- Skeptic fix 2: a coast at 1.52 m/s climbs only v^2/2g = 0.118 m, reached at 0.92 deg across the 7.36 m
-- circle, and at 0.5 deg a released bike gains 0.086 m/s^2; so at most 0.5 deg in any direction.
-- S2b keeps these limits. At about 1.0 m/s a coast climbs only 0.051 m, and 0.5 deg across the 5.2 m circle
-- is 0.045 m: on 0.48 deg down to the rider's right the left circle nearly stalls, drifts, and the path
-- leaves the envelope, where Spawn stops the ride inside the survey (ride_s2_slope_cross_climb_tests). The
-- band is far more sensitive than that: at 0.25 deg the band's corners leave the envelope or turn under 5 rad,
-- and from 0.05 deg they pass the farthest rule a flat sizing set (review findings 1 and 2), so the size above
-- holds only up to 0.055 deg and HANDOFF arms only on a survey whose page reads a slope of 0.05 deg or less.
Rec.SURVEY_SLOPE_DEG=.5
Rec.SURVEY_DOWNHILL_DEG=.5
Rec.SURVEY_UPHILL_DEG=.75
-- Obstacle ray heights over the fitted plane. The combined body spans about 0.03-1.66 m over the floor
-- (bike_geometry.lua capsules, origin 2 cm above the hit), so the steps are at most 0.35 m from 0.12 m.
Rec.SURVEY_HEIGHTS=table.freeze({.12,.45,.80,1.10,1.40,1.65})
-- Retain all 180 floor samples and 1080 obstacle samples in the local area.
-- The inner 0.75 m avoids the current rider without adding query exclusions.
Rec.SURVEY_FLOOR_RINGS=table.freeze({.75,.875,1,1.125,1.25})
Rec.SURVEY_FLOOR_STEP_DEG=10
Rec.SURVEY_OBSTACLE_STEP_DEG=2
Rec.SURVEY_MAX_AGE_MS=45000
Rec.SURVEY_MOVE_M=.25
Rec.SURVEY_TURN_RAD=math.rad(5)
-- Separate playable geometry admission; R1/S2 survey limits above stay exact.
Rec.PLAYABLE_GRADE_POLICY="measured_plane_grade_v1"
Rec.PLAYABLE_GRADE_SLOPE_DEG=5
Rec.PLAYABLE_GRADE_RESIDUAL_M=.003
-- main.lua casts the survey with world.probe ("unavailable", "clear" or "hit"); with nothing excluded a
-- ray spends one native cast, at most two, of the tick's 64, so 32 rays a tick never run the budget short.
Rec.SURVEY_RAYS_PER_TICK=32
-- The seat P=(0,.95,-.10) the rider rule measures, as P-G.com. Core's S1 attachment leads it by 0.035 m along +Z.
Rec.OFFSET=table.freeze({-G.com[1],.95-G.com[2],-.10-G.com[3]})
-- Row fields, in order. Lengths mm, speeds mm/s, angles mrad, tilt 0.1 degree, forces N. S2 adds ps (a pose
-- was sent this tick: 1, 0, or -1 with no pose status), pw (its weight x 1000, -1 without), and the five
-- joint errors in mm against the plan sent the tick before (-1 when not read, or no plan was sent then).
Rec.FIELDS=table.freeze({"t10","dserial","x","y","z","vx","vy","vz","yaw","tilt","err","a","b","sx","cap","g","hits",
    "sepf","sepr","state","sub","ack","fn","fy","fh","lt","ps","pw","jh","jlw","jrw","jla","jra"})
local F={}
for i,name in ipairs(Rec.FIELDS) do F[name]=i end
Rec.F=table.freeze(F)
local LIST_MAX=16 -- A runs, stick holds and brake runs kept in the summary; more are counted

local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function round(v) return finite(v) and math.floor(v+.5) or nil end
local function arr(v)
    if type(v)=="table" and finite(v[1]) and finite(v[2]) and finite(v[3]) then return {v[1],v[2],v[3]} end
    if typeof(v)=="vector" then return {v.x,v.y,v.z} end
    return nil
end
local function quat(q)
    if type(q)~="table" then return nil end
    for i=1,4 do if not finite(q[i]) then return nil end end
    return M.normalized(q)
end
local function wrap(a) while a>math.pi do a-=2*math.pi end while a<-math.pi do a+=2*math.pi end return a end
local function horizontal(v) return math.sqrt(v[1]*v[1]+v[3]*v[3]) end
local function hspeed(row) return math.sqrt(row[F.vx]^2+row[F.vz]^2) end
local function speed3(row) return math.sqrt(row[F.vx]^2+row[F.vy]^2+row[F.vz]^2) end

local function new_state()
    return {n=0,y0=nil,last=nil,first_a=nil,release=nil,
        seg1={rows=0,height_dev_mm=0,height_min_mm=0,height_max_mm=0,drift_mm=0,speed_mms=0,hspeed_mms=0,
            settled_rows=0,settled_height_dev_mm=0,settled_drift_mm=0,settled_speed_mms=0,force_max_n=0,force_y_sum=0,
            force_rows=0,braked_rows=0},
        ref=nil,seg2=nil,seg2_end=nil,prev=nil,
        a_runs={},a_open=nil,a_over=0,holds={},hold_open=nil,holds_over=0,brakes={},brake_open=nil,brakes_over=0,
        all={tilt_max_e1=0,rider_rows=0,rider_within=0,rider_max_mm=0,rider_missing=0,not_504=0,grounded=0,contact_rows=0,
            both_hit=0,no_hit=0,sep_min_mm=nil,sep_max_mm=nil,serial_gaps=0,top_speed_mms=0,force_max_n=0,
            max_distance_mm=0,b_rows=0,a_rows=0,a_capturing=0,over_lead_band=0,lt_rows=0,lt_max=0,lt_sum=0,lt_b_rows=0,lt_b_sum=0},
        pose={rows=0,sent=0,weighted=0,full_ms=nil,reads=0,joints={}}}
end

function Rec.new()
    local self={rows={},rows_dropped=0,dup_ticks=0,ticks=0,publish_ms=nil,last_serial=nil,
        yaw_prev=nil,yaw_acc=0,origin=nil,last_force=nil,forces={count=0,max_n=0,max_torque_nm=0,raised=0},
        actor_missing=0,contact_missing=0,pose_sent_seen=0,prev_plan=nil,prev_plan_tick=nil,joint_reads=0,
        joint_reads_planned=0,S=new_state()}
    for _,j in ipairs(Rec.JOINTS) do self.S.pose.joints[j.field]={reads=0,within=0,max_mm=0} end
    return setmetatable(self,{__index=Rec})
end

-- Called by the entry's submit wrapper after the SDK returned (or raised).
function Rec:note_submit(command,accepted)
    local f=self.forces
    f.count+=1
    if accepted~=true then f.refused=(f.refused or 0)+1 end
    local v=type(command)=="table" and arr(command.force) or nil
    if not v then f.malformed=(f.malformed or 0)+1;return end
    local n=M.length(v)
    if n>f.max_n then f.max_n=n end
    local tq=arr(command.torque)
    if tq and M.length(tq)>f.max_torque_nm then f.max_torque_nm=M.length(tq) end
    self.last_force={n=n,y=v[2],h=horizontal(v)}
end

local function contact_row(ride,serial)
    local m=type(ride)=="table" and type(ride.metrics)=="table" and ride.metrics or nil
    local ring=m and type(m.samples)=="table" and m.samples or nil
    if not ring then return nil end
    for i=#ring,1,-1 do
        local row=ring[i]
        if type(row)=="table" and row.serial==serial then return row end
    end
    return nil
end
local function target_of(plan,j)
    local t=plan[j.group]
    if j.side then t=type(t)=="table" and t[j.side] or nil end
    return arr(t)
end

-- One call per tick after bike:step. st is Core's detached status; actor is skater.get(); step_ms the
-- entry's bike:step time; joints, on a joint-read tick, maps each Rec.JOINTS id to its skater.joint
-- position (a vector) or false.
function Rec:observe(st,actor,step_ms,joints)
    self.ticks+=1
    -- Pose first, on every tick: whether Core sent a pose this tick (its sent count rose), its weight,
    -- and the joint errors against the plan sent the tick before (this tick's drawn skeleton shows that
    -- one). This tick's plan is then kept for the next tick.
    local pose=type(st)=="table" and type(st.pose)=="table" and st.pose or nil
    local ps,pw=-1,-1
    if pose then
        local sent=finite(pose.sent_ticks) and pose.sent_ticks or 0
        ps=sent>self.pose_sent_seen and 1 or 0
        self.pose_sent_seen=math.max(self.pose_sent_seen,sent)
        pw=finite(pose.weight) and round(pose.weight*1000) or -1
    end
    local jerr
    if type(joints)=="table" then
        self.joint_reads+=1
        jerr={}
        local plan=self.prev_plan_tick==self.ticks-1 and self.prev_plan or nil
        if plan then self.joint_reads_planned+=1 end
        for k,j in ipairs(Rec.JOINTS) do
            local at=arr(joints[j.id])
            local want=plan and target_of(plan,j) or nil
            jerr[k]=at and want and round(M.length(M.sub(at,want))*1000) or -1
        end
    end
    self.prev_plan=pose and ps==1 and type(pose.plan)=="table" and pose.plan or nil
    self.prev_plan_tick=self.ticks
    if type(st)~="table" then return end
    if finite(st.publish_ms) and not self.publish_ms then self.publish_ms=st.publish_ms end
    local m=type(st.spawn)=="table" and st.spawn.last_measurement or nil
    if not self.publish_ms or st.published_seen~=true or type(m)~="table" then self.last_force=nil;return end
    local serial=type(m.serial)=="string" and tonumber(m.serial) or nil
    local com,q,vel=arr(m.position),quat(m.rotation),arr(m.velocity)
    if not serial or not com or not q or not vel then self.last_force=nil;return end
    if self.last_serial and serial<=self.last_serial then self.dup_ticks+=1;self.last_force=nil;return end
    local dserial=self.last_serial and serial-self.last_serial or 0
    self.last_serial=serial
    if not self.origin then self.origin=com end
    local fwd=M.turn(q,{0,0,1})
    local up=M.turn(q,{0,1,0})
    local yaw=math.atan2(fwd[1],fwd[3])
    if self.yaw_prev then self.yaw_acc+=wrap(yaw-self.yaw_prev) end
    self.yaw_prev=yaw
    local tilt=math.deg(math.acos(math.clamp(up[2],-1,1)))
    local err=-1
    local ap=type(actor)=="table" and arr(actor.position) or nil
    if ap then
        local target=M.add(com,M.turn(q,Rec.OFFSET))
        err=round(M.length(M.sub(ap,target))*1000)
    else self.actor_missing+=1 end
    local src=type(st.last_source_step)=="table" and st.last_source_step or {}
    local pad=type(src.sample)=="table" and type(src.sample.pad)=="table" and src.sample.pad or nil
    local a=pad and type(pad.buttons)=="table" and pad.buttons.a==true and 1 or 0
    local bb=pad and type(pad.buttons)=="table" and pad.buttons.b==true and 1 or 0
    local sx=pad and finite(pad.left_x) and round(pad.left_x*1000) or 0
    local cap=type(src.capture_state)=="table" and src.capture_state.phase=="capturing" and 1 or 0
    local ride=type(st.ride)=="table" and st.ride or nil
    local c=contact_row(ride,m.serial)
    local g,hits,sepf,sepr=-1,0,-9999,-9999
    if c then
        g=c.grounded==true and 1 or 0
        hits=(c.front_hit==true and 1 or 0)+(c.rear_hit==true and 2 or 0)
        sepf=round(finite(c.front_separation) and c.front_separation*1000) or -9999
        sepr=round(finite(c.rear_separation) and c.rear_separation*1000) or -9999
    else self.contact_missing+=1 end
    local f=self.last_force
    self.last_force=nil
    local readiness=type(st.readiness)=="table" and st.readiness or {}
    local o=self.origin
    local t=finite(st.wall_ms) and st.wall_ms-self.publish_ms or -1
    local j=jerr or {-1,-1,-1,-1,-1}
    local row={round(t*10),dserial,round((com[1]-o[1])*1000),round((com[2]-o[2])*1000),round((com[3]-o[3])*1000),
        round(vel[1]*1000),round(vel[2]*1000),round(vel[3]*1000),round(self.yaw_acc*1000),round(tilt*10),err,a,bb,sx,cap,g,hits,
        sepf,sepr,finite(readiness.state) and readiness.state or -1,ride and ride.submitted or -1,ride and ride.acknowledged or -1,
        f and round(f.n) or -1,f and round(f.y) or 0,f and round(f.h) or 0,finite(step_ms) and round(step_ms*100) or -1,
        ps,pw,j[1],j[2],j[3],j[4],j[5]}
    if #self.rows>=Rec.MAX_ROWS then self.rows_dropped+=1;return end
    table.insert(self.rows,row)
    -- The forward axis at the row, for segment 2's projection only (never stored).
    self:add_row(row,fwd[1],fwd[3])
end

-- Rows first..first+count-1 as stored (the fields only), for one storage chunk.
function Rec:stored_rows(first,count)
    first=first or 1
    local last=count and math.min(#self.rows,first+count-1) or #self.rows
    local out=table.create(math.max(0,last-first+1))
    for i=first,last do out[i-first+1]=table.clone(self.rows[i]) end
    return out
end

-- The incremental summary: each row updates the running state once.
local function open_list(list,over,entry)
    if #list>=LIST_MAX then return nil,over+1 end
    table.insert(list,entry)
    return entry,over
end
function Rec:add_row(row,fx,fz)
    local S=self.S
    S.n+=1
    local i=S.n
    local t=row[F.t10]/10
    local hs=hspeed(row)
    if i==1 then S.y0=row[F.y];S.seg1.height_min_mm=row[F.y];S.seg1.height_max_mm=row[F.y] end
    -- Segment 1: the rows before the first A (all rows while A never came).
    if not S.first_a and row[F.a]==1 then
        S.first_a=i
        local n=math.sqrt(fx*fx+fz*fz)
        if n<1e-6 then fx,fz,n=0,1,1 end
        S.seg2={rows=0,start_ms=t,start_x=row[F.x],start_z=row[F.z],fx=fx/n,fz=fz/n,start_yaw=row[F.yaw],
            speed_start_mms=round(hs),path_mm=0,top_speed_mms=0,heading_dev_mrad=0,tilt_max_e1=0,rider_rows=0,
            rider_within=0,rider_max_mm=0,rider_missing=0,grounded=0,contact_rows=0,force_max_n=0,force_h_max_n=0,capturing_rows=0}
        S.seg1_ms=t
    end
    if not S.first_a then
        local s1=S.seg1
        s1.rows=i
        local dy=row[F.y]-S.y0
        if row[F.b]==1 then s1.braked_rows+=1 end
        s1.height_dev_mm=math.max(s1.height_dev_mm,math.abs(dy))
        s1.height_min_mm=math.min(s1.height_min_mm,row[F.y]);s1.height_max_mm=math.max(s1.height_max_mm,row[F.y])
        s1.drift_mm=math.max(s1.drift_mm,round(math.sqrt(row[F.x]^2+row[F.z]^2)))
        s1.speed_mms=math.max(s1.speed_mms,round(speed3(row)))
        s1.hspeed_mms=math.max(s1.hspeed_mms,round(hs))
        if not S.ref and row[F.t10]>=Rec.SETTLE_MS*10 then S.ref={x=row[F.x],y=row[F.y],z=row[F.z]} end
        if S.ref then
            local ref=S.ref
            s1.settled_rows+=1
            s1.settled_height_dev_mm=math.max(s1.settled_height_dev_mm,math.abs(row[F.y]-ref.y))
            s1.settled_drift_mm=math.max(s1.settled_drift_mm,round(math.sqrt((row[F.x]-ref.x)^2+(row[F.z]-ref.z)^2)))
            s1.settled_speed_mms=math.max(s1.settled_speed_mms,round(speed3(row)))
        end
        if row[F.fn]>=0 then
            s1.force_max_n=math.max(s1.force_max_n,row[F.fn])
            s1.force_y_sum+=row[F.fy];s1.force_rows+=1
        end
    end
    -- Segment 2: the first A row to the first row after it without A (that row included), or the last row.
    local g=S.seg2
    if g and not S.release then
        g.rows+=1
        if g.rows>1 and S.prev then g.path_mm+=round(math.sqrt((row[F.x]-S.prev[F.x])^2+(row[F.z]-S.prev[F.z])^2)) end
        g.top_speed_mms=math.max(g.top_speed_mms,round(hs))
        g.heading_dev_mrad=math.max(g.heading_dev_mrad,math.abs(row[F.yaw]-g.start_yaw))
        g.tilt_max_e1=math.max(g.tilt_max_e1,row[F.tilt])
        g.rider_rows+=1
        if row[F.err]<0 then g.rider_missing+=1
        else
            if row[F.err]<=Rec.RIDER_MM then g.rider_within+=1 end
            g.rider_max_mm=math.max(g.rider_max_mm,row[F.err])
        end
        if row[F.g]>=0 then g.contact_rows+=1;if row[F.g]==1 then g.grounded+=1 end end
        if row[F.fn]>=0 then g.force_max_n=math.max(g.force_max_n,row[F.fn]);g.force_h_max_n=math.max(g.force_h_max_n,row[F.fh]) end
        if row[F.cap]==1 then g.capturing_rows+=1 end
        if i>S.first_a and row[F.a]==0 then
            S.release=i
            S.seg2_end={t=t,x=row[F.x],z=row[F.z],yaw=row[F.yaw],hs=hs}
        end
    end
    -- Every A run: from its first A row to the first row after it without A (that row's speed ends it).
    -- (An open entry is nil when none is open, false when one is open but the list was full.)
    if row[F.a]==1 then
        if S.a_open==nil then
            local r
            r,S.a_over=open_list(S.a_runs,S.a_over,{start_ms=t,start_mms=round(hs),top_mms=0,rows=0,capturing=0})
            S.a_open=r or false
        end
        local r=S.a_open
        if r then r.rows+=1;r.top_mms=math.max(r.top_mms,round(hs));r.end_mms=round(hs);r.end_ms=t
            if row[F.cap]==1 then r.capturing+=1 end end
    elseif S.a_open~=nil then
        local r=S.a_open
        if r then r.end_ms=t;r.end_mms=round(hs);r.top_mms=math.max(r.top_mms,round(hs));r.closed=true end
        S.a_open=nil
    end
    -- Left-stick holds (after the first A): yaw from the first held row to the first row after the hold.
    local dir=row[F.sx]<=-Rec.STEER_X and -1 or row[F.sx]>=Rec.STEER_X and 1 or 0
    if S.hold_open~=nil and S.hold_dir~=dir then
        local h=S.hold_open
        if h then h.end_ms=t;h.mrad=row[F.yaw]-h.start_yaw;h.closed=true end
        S.hold_open,S.hold_dir=nil,nil
    end
    if S.hold_open==nil and dir~=0 and S.first_a and i>S.first_a then
        local h
        h,S.holds_over=open_list(S.holds,S.holds_over,{dir=dir,start_ms=t,start_yaw=row[F.yaw],rows=0,mrad=0})
        S.hold_open,S.hold_dir=h or false,dir
    end
    if S.hold_open then S.hold_open.rows+=1;S.hold_open.mrad=row[F.yaw]-S.hold_open.start_yaw;S.hold_open.end_ms=t end
    -- Brake runs after the first A: under STOP_MMS within STOP_WITHIN_MS of the run's first row, and every
    -- later row of the run under it too.
    local braking=row[F.b]==1 and S.first_a~=nil and i>S.first_a
    if S.brake_open~=nil and not braking then
        if S.brake_open then S.brake_open.closed=true;S.brake_open.end_ms=t end
        S.brake_open=nil
    end
    if braking and S.brake_open==nil then
        local b
        b,S.brakes_over=open_list(S.brakes,S.brakes_over,{start_ms=t,speed_start_mms=round(hs),x=row[F.x],z=row[F.z],
            stop_ms=nil,braked_rows=0,moving_after=0,rows=0})
        S.brake_open=b or false
    end
    local b=S.brake_open
    if b then
        b.rows+=1;b.end_ms=t
        if b.stop_ms==nil and hs<Rec.STOP_MMS then
            b.stop_ms=t-b.start_ms
            b.distance_mm=round(math.sqrt((row[F.x]-b.x)^2+(row[F.z]-b.z)^2))
        end
        if b.stop_ms~=nil then
            b.braked_rows+=1
            if hs>=Rec.STOP_MMS then b.moving_after+=1 end
        end
    end
    -- The whole following interval.
    local all=S.all
    all.tilt_max_e1=math.max(all.tilt_max_e1,row[F.tilt])
    all.rider_rows+=1
    if row[F.err]<0 then all.rider_missing+=1
    else
        if row[F.err]<=Rec.RIDER_MM then all.rider_within+=1 end
        all.rider_max_mm=math.max(all.rider_max_mm,row[F.err])
    end
    if row[F.state]~=504 then all.not_504+=1 end
    if row[F.g]>=0 then
        all.contact_rows+=1
        if row[F.g]==1 then all.grounded+=1 end
        if row[F.hits]==3 then all.both_hit+=1 elseif row[F.hits]==0 then all.no_hit+=1 end
        for _,sep in ipairs({row[F.sepf],row[F.sepr]}) do
            if sep~=-9999 then
                all.sep_min_mm=math.min(all.sep_min_mm or sep,sep);all.sep_max_mm=math.max(all.sep_max_mm or sep,sep)
            end
        end
    end
    if i>1 and row[F.dserial]~=1 then all.serial_gaps+=1 end
    all.top_speed_mms=math.max(all.top_speed_mms,round(hs))
    if row[F.fn]>=0 then all.force_max_n=math.max(all.force_max_n,row[F.fn]) end
    all.max_distance_mm=math.max(all.max_distance_mm,round(math.sqrt(row[F.x]^2+row[F.z]^2)))
    if row[F.b]==1 then all.b_rows+=1 end
    if row[F.a]==1 then all.a_rows+=1;if row[F.cap]==1 then all.a_capturing+=1 end end
    if hs>Rec.LEAD_BAND_MMS then all.over_lead_band+=1 end
    if row[F.lt]>=0 then
        all.lt_rows+=1;all.lt_sum+=row[F.lt];all.lt_max=math.max(all.lt_max,row[F.lt])
        if row[F.b]==1 then all.lt_b_rows+=1;all.lt_b_sum+=row[F.lt] end
    end
    -- The pose columns.
    local p=S.pose
    if row[F.pw]>=0 then
        p.rows+=1
        if row[F.ps]==1 then p.sent+=1 end
        if row[F.pw]>=1000 and p.full_ms==nil then p.full_ms=t end
    end
    local read=false
    for _,j in ipairs(Rec.JOINTS) do
        local e=row[F[j.field]]
        if e>=0 then
            read=true
            local jj=p.joints[j.field]
            jj.reads+=1;jj.max_mm=math.max(jj.max_mm,e)
            if e<=j.limit_mm then jj.within+=1 end
        end
    end
    if read then p.reads+=1 end
    S.prev=row
    S.last=row
end

local function copy_list(list)
    local out=table.create(#list)
    for i,v in ipairs(list) do out[i]=table.clone(v) end
    return out
end
-- Everything judged comes from the rows, through the running state; the status adds lifecycle facts.
-- A fixed amount of work: the lists hold at most LIST_MAX entries each.
function Rec:summary()
    local S=self.S
    local s={rows=S.n,rows_dropped=self.rows_dropped,dup_ticks=self.dup_ticks,actor_missing=self.actor_missing,
        contact_missing=self.contact_missing,forces={count=self.forces.count,max_n=round(self.forces.max_n),
        max_torque_nm=round(self.forces.max_torque_nm),refused=self.forces.refused or 0,malformed=self.forces.malformed or 0},
        joint_reads=self.joint_reads,joint_reads_planned=self.joint_reads_planned,incremental=true}
    if S.n==0 then return s end
    local e=S.last
    s.first_a_row,s.release_row=S.first_a,S.release
    local seg1=table.clone(S.seg1)
    seg1.ms=S.first_a and S.seg1_ms or e[F.t10]/10
    seg1.settle_ms=Rec.SETTLE_MS
    seg1.force_y_mean_n=seg1.force_rows>0 and round(seg1.force_y_sum/seg1.force_rows) or nil
    seg1.force_y_sum=nil
    seg1.m4_hold=seg1.ms>=Rec.SEG1_MS and seg1.settled_rows>0 and seg1.settled_height_dev_mm<=Rec.SEG1_HEIGHT_MM
        and seg1.settled_drift_mm<=Rec.SEG1_DRIFT_MM and seg1.settled_speed_mms<Rec.SEG1_SPEED_MMS
    seg1.raw_hold=seg1.ms>=Rec.SEG1_MS and seg1.height_dev_mm<=Rec.SEG1_HEIGHT_MM and seg1.drift_mm<=Rec.SEG1_DRIFT_MM
        and seg1.speed_mms<Rec.SEG1_SPEED_MMS
    s.seg1=seg1
    if S.seg2 then
        local g=S.seg2
        local stop=S.seg2_end or {t=e[F.t10]/10,x=e[F.x],z=e[F.z],yaw=e[F.yaw],hs=hspeed(e)}
        local dx,dz=stop.x-g.start_x,stop.z-g.start_z
        local seg2={rows=g.rows,ms=stop.t-g.start_ms,start_ms=g.start_ms,end_ms=stop.t,
            forward_mm=round(dx*g.fx+dz*g.fz),lateral_mm=round(math.abs(dx*g.fz-dz*g.fx)),path_mm=g.path_mm,
            speed_start_mms=g.speed_start_mms,speed_end_mms=round(stop.hs),top_speed_mms=g.top_speed_mms,
            heading_change_mrad=stop.yaw-g.start_yaw,heading_dev_mrad=g.heading_dev_mrad,tilt_max_e1=g.tilt_max_e1,
            rider_rows=g.rider_rows,rider_within=g.rider_within,rider_max_mm=g.rider_max_mm,rider_missing=g.rider_missing,
            grounded=g.grounded,contact_rows=g.contact_rows,force_max_n=g.force_max_n,force_h_max_n=g.force_h_max_n,
            capturing_rows=g.capturing_rows,ended_by_release=S.release~=nil}
        seg2.speed_rose=seg2.speed_end_mms>seg2.speed_start_mms+50
        s.seg2=seg2
        if S.seg2_end and S.release<S.n then
            local cx,cz=e[F.x]-S.seg2_end.x,e[F.z]-S.seg2_end.z
            s.coast={rows=S.n-S.release,ms=e[F.t10]/10-S.seg2_end.t,forward_mm=round(cx*g.fx+cz*g.fz),speed_end_mms=round(hspeed(e))}
        end
    end
    s.a_runs=copy_list(S.a_runs);s.a_runs_over=S.a_over
    s.holds=copy_list(S.holds);s.holds_over=S.holds_over
    local left,right
    for _,h in ipairs(S.holds) do
        if h.dir<0 and not left then left=h end
        if h.dir>0 and not right then right=h end
    end
    s.turns={left_mrad=left and left.mrad or nil,right_mrad=right and right.mrad or nil,
        left_ms=left and left.end_ms-left.start_ms or nil,right_ms=right and right.end_ms-right.start_ms or nil,holds=#S.holds}
    s.brakes=copy_list(S.brakes);s.brakes_over=S.brakes_over
    for _,b in ipairs(s.brakes) do b.stopped=b.stop_ms~=nil and b.stop_ms<=Rec.STOP_WITHIN_MS and b.moving_after==0 end
    s.brake=s.brakes[#s.brakes]
    local second=S.a_runs[2]
    s.restart=second and {start_ms=second.start_ms,start_mms=second.start_mms,end_mms=second.end_mms,top_mms=second.top_mms,
        rose=second.start_mms<Rec.RESTART_FROM_MMS and (second.end_mms or 0)>=second.start_mms+Rec.RESTART_RISE_MMS} or nil
    local all=table.clone(S.all)
    all.distance_mm=round(math.sqrt(e[F.x]^2+e[F.z]^2))
    all.yaw_mrad=e[F.yaw]
    all.last_speed_mms=round(speed3(e))
    all.last_hspeed_mms=round(hspeed(e))
    all.last_ms=e[F.t10]/10
    all.lt_mean=all.lt_rows>0 and round(all.lt_sum/all.lt_rows) or nil
    all.lt_b_mean=all.lt_b_rows>0 and round(all.lt_b_sum/all.lt_b_rows) or nil
    all.lt_sum,all.lt_b_sum=nil,nil
    s.all=all
    local p=S.pose
    local joints={}
    for k,v in pairs(p.joints) do joints[k]=table.clone(v) end
    s.pose={rows=p.rows,sent=p.sent,full_ms=p.full_ms,reads=p.reads,joints=joints}
    return s
end

local function terminal(phase) return phase=="done" or phase=="retained_unknown" or phase=="blocked" end
Rec.terminal=terminal

-- Lifecycle and cleanup facts from Core's status (as M1's judged fields), with S2's pose status.
function Rec.lifecycle(st)
    if type(st)~="table" then return {phase="unavailable"} end
    local tr=type(st.terminal_receipt)=="table" and st.terminal_receipt or nil
    local src=type(st.source)=="table" and st.source or {}
    local cap=type(src.capture_state)=="table" and src.capture_state or {}
    local lease=type(src.lease_state)=="table" and src.lease_state or {}
    local ride=type(st.ride)=="table" and st.ride or {}
    local metrics=type(ride.metrics)=="table" and ride.metrics or {}
    local pose=type(st.pose)=="table" and st.pose or {}
    local board=type(st.board)=="table" and st.board or {}
    local attempted,accepted=0,0
    for id=1,8 do
        if type(st.visual_remove_attempted)=="table" and st.visual_remove_attempted[id]==true then attempted+=1 end
        if type(st.visual_remove_call_accepted)=="table" and st.visual_remove_call_accepted[id]==true then accepted+=1 end
    end
    local stops,count={},0
    if type(metrics.stop_counts)=="table" then
        for reason,n in pairs(metrics.stop_counts) do
            count+=1
            if count<=8 then table.insert(stops,{string.sub(tostring(reason),1,120),n}) end
        end
        table.sort(stops,function(x,y) return x[1]<y[1] end)
    end
    return {phase=st.phase,stop_reason=st.stop_reason,stop_ms=st.stop_ms,detail=type(st.detail)=="string" and string.sub(st.detail,1,200) or nil,
        publish_ms=st.publish_ms,reserve_ms=st.reserve_ms,ride_window_ms=st.ride_window_ms,lease_until_ms=st.lease_until_ms,
        effect_start_ms=st.effect_start_ms,
        lease_renewable=st.lease_renewable==true,lease_renew_calls=st.lease_renew_calls,
        lease_renew_accepted=st.lease_renew_accepted,lease_renew_off=st.lease_renew_off==true,
        lease_renew_last=type(st.lease_renew_last)=="string" and string.sub(st.lease_renew_last,1,120) or nil,
        lease_renewals=st.lease_renewals,
        lease_report_refused=st.lease_report_refused==true,lease_reports=st.lease_reports,
        completed_acknowledged=st.completed_acknowledged==true,acknowledged=st.acknowledged==true,
        terminal_phase=tr and tr.phase,terminal_reason=tr and tr.reason,park_reason=tr and tr.park_reason,
        park_observed=tr~=nil and tr.park_observed==true,final_revision=tr and tr.final_revision,
        returned_revision=tr and tr.returned_revision,
        source_phase=src.phase,source_lease_handle=src.lease_handle_present==true,
        source_cleanup_pending=src.cleanup_pending==true,source_cleanup_unknown=src.cleanup_unknown==true,
        capture_phase=cap.phase,capture_report_debt=cap.report_debt,lease_status=lease.status,lease_report_debt=lease.report_debt,
        removals_attempted=attempted,removals_accepted=accepted,cleanup_unknown=st.cleanup_unknown==true,
        bike_cleanup_complete=st.bike_cleanup_complete==true,force_cleanup_clear=st.force_cleanup_clear==true,
        force_cleanup_unknown=st.force_cleanup_unknown==true,storage_fault=st.storage_fault==true,
        ride_composition_qualified=st.ride_composition_qualified==true,ride_built=type(st.ride)=="table",
        ride_phase=ride.phase,ride_issue=ride.issue,ride_activation=ride.activation_qualified,
        ride_submitted=ride.submitted,ride_acknowledged=ride.acknowledged,ride_pending=ride.pending_count,
        ride_unknown=ride.unknown==true,ride_observed_steps=ride.observed_steps,ride_model_steps=ride.model_steps,
        ride_backpressure_steps=ride.backpressure_steps,
        ride_skipped=type(ride.continuity)=="table" and ride.continuity.skipped_steps or nil,
        applied=metrics.applied_count,applied_delay_one=metrics.applied_delay_one,applied_delay_other=metrics.applied_delay_other,
        submitted_count=metrics.submitted_count,max_inflight=metrics.max_inflight,
        steps_without_report=metrics.steps_without_report,largest_report_gap_ms=metrics.largest_report_gap_ms,
        grounded_changes=(metrics.grounded_changes_with_report or 0)+(metrics.grounded_changes_without_report or 0),
        stop_counts=stops,stop_counts_overflow=metrics.stop_counts_overflow,
        wipeouts_start=type(st.initial_readiness)=="table" and st.initial_readiness.wipeouts or nil,
        wipeouts_now=type(st.readiness)=="table" and st.readiness.wipeouts or nil,
        follow_reads=type(st.call_counts)=="table" and st.call_counts["follow.read"] or 0,
        lease_calls=type(st.call_counts)=="table" and st.call_counts["follow.lease"] or 0,
        pose_calls=type(st.call_counts)=="table" and st.call_counts["skater.pose"] or 0,
        pose_built=type(st.pose)=="table",pose_state=pose.state,pose_capability=pose.capability,pose_issue=pose.issue,
        pose_reason=pose.reason,pose_sends=pose.sends,pose_ends=pose.ends,pose_ticks=pose.ticks,pose_sent_ticks=pose.sent_ticks,
        pose_mount_ms=pose.mount_ms,pose_mounted_ms=pose.mounted_ms,pose_nil_calls=pose.nil_calls,
        pose_nil_accepted=pose.nil_accepted,pose_stopped=pose.stopped,pose_qualified=pose.qualified,
        -- S2c: Core's board status (its S2c adapter around board_drop.lua) and the ledger's board call counts.
        board_built=type(st.board)=="table",board_state=board.state,board_reason=board.reason,board_issue=board.issue,
        board_ground=board.ground,board_floor=board.floor,board_up_y=board.up_y,board_upside=board.upside,
        board_place_above_floor=board.place_above_floor,board_toss_result=board.toss_result,
        board_clear_result=board.clear_result,board_bones_result=board.bones_result,board_toss_calls=board.toss_calls,
        board_clear_calls=board.clear_calls,board_bones_calls=board.bones_calls,board_calibration=board.calibration,
        board_drop_ms=board.drop_ms,board_restore_ms=board.restore_ms,
        board_ledger_tosses=type(st.call_counts)=="table" and st.call_counts["board.toss"] or 0,
        board_ledger_clears=type(st.call_counts)=="table" and st.call_counts["board.clear"] or 0}
end

function Rec.cleanup_checks(c)
    return {
        done_completed_ack=c.phase=="done" and c.completed_acknowledged and c.acknowledged,
        final_equals_returned=c.final_revision~=nil and c.final_revision==c.returned_revision,
        park_observed=c.park_observed==true,
        force_ledger_clear=c.force_cleanup_clear==true and not c.force_cleanup_unknown and (c.ride_pending or 0)==0,
        source_complete_no_debt=c.source_phase=="complete" and not c.source_lease_handle and not c.source_cleanup_pending
            and not c.source_cleanup_unknown and c.capture_report_debt==false and c.lease_report_debt==false,
        eight_removals=c.removals_attempted==8 and c.removals_accepted==8,
    }
end
Rec.CLEANUP_NAMES=table.freeze({"done_completed_ack","final_equals_returned","park_observed","force_ledger_clear",
    "source_complete_no_debt","eight_removals"})

-- The window end: Core's window text, at publish + RIDE_WINDOW_MS or up to WINDOW_SLACK_MS later, and
-- Ride stopped for the same reason. stop_ms is the clock read that failed lease_live, so a lease that ran
-- down early fails this rule.
local WINDOW="ride window or Follow lease ended"
local function on_window(c)
    return type(c.stop_reason)=="string" and string.sub(c.stop_reason,1,#WINDOW)==WINDOW
        and finite(c.stop_ms) and finite(c.publish_ms) and finite(c.ride_window_ms)
        and c.stop_ms-c.publish_ms>=c.ride_window_ms and c.stop_ms-c.publish_ms<=c.ride_window_ms+Rec.WINDOW_SLACK_MS
        and (c.ride_issue==nil or c.ride_issue==c.stop_reason)
end
Rec.on_window=on_window

-- The Host's cost rule (plugin_vm.cpp:437-446): each 1 s window's time over its ticks, against the budget.
-- rows are main.lua's per-window cost rows {from_ms, ticks, tick_us, call_us, tick_max_us} (skeptic fix 1:
-- every window, not only the last 10); those from from_ms on are judged. The plugin's tick handler time
-- stands for the Host's (the Host adds its call around it, and any page drawn: the overlay is shut).
function Rec.cost_check(rows,from_ms,budget_ms)
    budget_ms=budget_ms or Rec.HOST_BUDGET_MS
    local out={windows=0,over_budget=0,over_target=0,worst_ms=0,worst_from_ms=nil,budget_ms=budget_ms,target_ms=Rec.TARGET_MS,
        worst_tick_max_ms=0}
    for _,w in ipairs(type(rows)=="table" and rows or {}) do
        local from,ticks,tick_us=w[1],w[2],w[3]
        if finite(from) and finite(ticks) and ticks>0 and finite(tick_us) and (not finite(from_ms) or from>=from_ms) then
            local ms=tick_us/ticks/1000
            out.windows+=1
            if ms>budget_ms then out.over_budget+=1 end
            if ms>Rec.TARGET_MS then out.over_target+=1 end
            if ms>out.worst_ms then out.worst_ms,out.worst_from_ms=ms,from end
            if finite(w[5]) and w[5]/1000>out.worst_tick_max_ms then out.worst_tick_max_ms=w[5]/1000 end
        end
    end
    out.worst_ms=math.floor(out.worst_ms*1000+.5)/1000
    return out
end

-- FREE_RIDE's rules: the ride's (S1's at 60 s, the brakes, the restart, the envelope, speed, rest and
-- cost) and the pose's. Every one must hold, with Core done and every cleanup check true.
function Rec.free_rules(s,c)
    c=type(c)=="table" and c or {}
    local g,t,all,p=s.seg2,s.turns or {},s.all,s.pose or {}
    local brakes=s.brakes or {}
    local stopped=#brakes>0 and (s.brakes_over or 0)==0
    for _,b in ipairs(brakes) do if b.stopped~=true then stopped=false end end
    local runs=s.a_runs or {}
    local capturing=#runs>0 and all~=nil and all.a_rows>0 and all.a_capturing==all.a_rows
    local cost=c.cost
    local joints=p.joints or {}
    local joints_ok=(p.reads or 0)>0
    for _,j in ipairs(Rec.JOINTS) do
        local jj=joints[j.field]
        if not jj or jj.reads==0 or jj.within<Rec.POSE_JOINT_SHARE*jj.reads then joints_ok=false end
    end
    return {
        forward_0_1_to_3_m=g~=nil and g.forward_mm>=Rec.MIN_FORWARD_MM and g.forward_mm<=Rec.MAX_FORWARD_MM,
        speed_rose=g~=nil and g.speed_rose==true,
        capturing_on_a=capturing,
        m4_segment1=s.seg1~=nil and s.seg1.m4_hold==true,
        left_turn_5rad=t.left_mrad~=nil and t.left_mrad>=Rec.TURN_MIN_MRAD,
        right_turn_5rad=t.right_mrad~=nil and t.right_mrad<=-Rec.TURN_MIN_MRAD,
        brake_stops=stopped,
        restart_rose=s.restart~=nil and s.restart.rose==true,
        tilt_under_10=all~=nil and all.tilt_max_e1<Rec.TILT_RULE_E1,
        rider_5cm_90pct=all~=nil and all.rider_rows>0 and all.rider_within>=Rec.RIDER_SHARE*all.rider_rows,
        state_504=all~=nil and all.not_504==0,
        rows_whole=s.rows>0 and s.rows_dropped==0,
        farthest_under_7_5m=all~=nil and all.max_distance_mm<Rec.FARTHEST_MM,
        under_2_57_mps=all~=nil and all.top_speed_mms<Rec.LEAD_BAND_MMS,
        still_at_end=all~=nil and all.last_hspeed_mms<Rec.STILL_MMS,
        renewal_held=c.lease_renewable==true and type(c.lease_renew_accepted)=="number" and c.lease_renew_accepted>0
            and c.lease_renew_off~=true,
        ended_on_window=on_window(c),
        cost_within_budget=type(cost)=="table" and cost.windows>0 and cost.over_budget==0,
        pose_probe_ok=c.pose_capability==true,
        pose_mounted_in_time=finite(c.pose_mount_ms) and finite(c.pose_mounted_ms)
            and c.pose_mounted_ms-c.pose_mount_ms<=Rec.POSE_BLEND_IN_MS+Rec.POSE_MOUNT_SLACK_MS,
        pose_sent_95pct=s.rows>0 and (p.sent or 0)>=Rec.POSE_SENT_SHARE*s.rows,
        pose_no_refusal=c.pose_built==true and c.pose_issue==nil and c.pose_state~="refused",
        pose_nil_accepted=c.pose_nil_accepted==true and (c.pose_nil_calls or 0)>=1,
        pose_joints_90pct=joints_ok,
    }
end
Rec.RIDE_NAMES=table.freeze({"forward_0_1_to_3_m","speed_rose","capturing_on_a","m4_segment1","left_turn_5rad","right_turn_5rad",
    "brake_stops","restart_rose","tilt_under_10","rider_5cm_90pct","state_504","rows_whole","farthest_under_7_5m","under_2_57_mps",
    "still_at_end","renewal_held","ended_on_window","cost_within_budget"})
Rec.POSE_NAMES=table.freeze({"pose_probe_ok","pose_mounted_in_time","pose_sent_95pct","pose_no_refusal","pose_nil_accepted",
    "pose_joints_90pct"})

-- S2c: the rider's board. Core's adapter drops it once at the pose's first accepted mount (board.toss of the
-- deck's mount onto the spawn's measured floor) and gives it back where the pose ends (board.clear). Its two
-- rules are INFORMATIONAL: the record and the page show them, and the verdict (FREE_RIDE, RIDE_UNPOSED or
-- NOT_YET) never reads them: a board refused, raised or never dropped leaves a free ride free.
Rec.BOARD_NAMES=table.freeze({"board_dropped","board_restored"})
function Rec.board(c)
    c=type(c)=="table" and c or {}
    local function after(ms) return finite(ms) and finite(c.publish_ms) and round(ms-c.publish_ms) or nil end
    local dropped=c.board_toss_result=="accepted"
    return {informational=true,built=c.board_built==true,state=c.board_state,reason=c.board_reason,issue=c.board_issue,
        ground_y=c.board_ground,floor_y=c.board_floor,up_y=c.board_up_y,upside=c.board_upside,
        place_above_floor=c.board_place_above_floor,toss=c.board_toss_result,clear=c.board_clear_result,
        bones=c.board_bones_result,toss_calls=c.board_toss_calls,clear_calls=c.board_clear_calls,
        bones_calls=c.board_bones_calls,ledger_tosses=c.board_ledger_tosses,ledger_clears=c.board_ledger_clears,
        calibration=c.board_calibration,drop_ms=after(c.board_drop_ms),restore_ms=after(c.board_restore_ms),
        rules={board_dropped=dropped,board_restored=dropped and c.board_clear_result=="cleared" and c.board_state=="restored"}}
end
local function ms_text(v) return finite(v) and string.format("%+d ms",v) or "n/a" end
-- One page line: "dropped +N ms, ground y=..., restored +M ms", or why not.
function Rec.board_line(b)
    if type(b)~="table" or not b.built then return "no board status yet (dropped at the pose's mount)" end
    local parts={}
    if b.toss=="accepted" then
        table.insert(parts,string.format("dropped %s, ground y=%s",ms_text(b.drop_ms),finite(b.ground_y) and string.format("%.3f",b.ground_y) or "n/a"))
    elseif b.state=="idle" and b.issue==nil then
        table.insert(parts,"not dropped: the pose never mounted")
    else
        table.insert(parts,string.format("not dropped (%s%s): %s",tostring(b.state),b.toss and ", toss "..b.toss or "",
            tostring(b.issue or b.reason or "no reason")))
    end
    if b.clear=="cleared" then table.insert(parts,"restored "..ms_text(b.restore_ms))
    elseif b.clear~=nil then table.insert(parts,"restore "..tostring(b.clear)..": "..tostring(b.reason))
    elseif b.toss=="accepted" or b.toss=="raised" or b.toss=="malformed" then table.insert(parts,"not restored yet") end
    return table.concat(parts,"; ")
end
local function xyz_text(v)
    if type(v)~="table" or not finite(v[1]) or not finite(v[2]) or not finite(v[3]) then return "n/a" end
    return string.format("(%.3f, %.3f, %.3f)",v[1],v[2],v[3])
end
-- The calibration line: bone 1 (the board's place) and bone 2 (the deck's mount), each in its parent's frame, then
-- bone 1's height above the measured floor (about hand height when bone 1 is a place in the world, as
-- board_pose.cpp takes it) and which way up it was (up y below 0: it lands upside down, 0.141 m higher).
function Rec.board_bones_line(b)
    local cal=type(b)=="table" and type(b.calibration)=="table" and b.calibration or {}
    local place,mount=type(cal.place)=="table" and cal.place or {},type(cal.mount)=="table" and cal.mount or {}
    local above=type(b)=="table" and finite(b.place_above_floor) and string.format("%.3f m",b.place_above_floor) or "n/a"
    local side="side unknown"
    if type(b)=="table" and finite(b.up_y) then side=string.format("%s, up y %.3f",b.upside==true and "upside down" or "upright",b.up_y) end
    return string.format("1 at %s, 2 at %s (parents' frames; %s); 1 is %s above the floor, %s",xyz_text(place.position),
        xyz_text(mount.position),tostring(b and b.bones),above,side)
end

local function pose_reasons(s,c,r)
    local out={}
    local p=s.pose or {}
    -- A refusal leads: it explains the sends missing after it.
    if not r.pose_no_refusal then
        table.insert(out,"pose refused: "..(c.pose_built==true and tostring(c.pose_issue or c.pose_state) or "no pose status"))
    end
    if not r.pose_probe_ok then table.insert(out,"pose: the place probe did not pass (capability "..tostring(c.pose_capability)..")") end
    if not r.pose_mounted_in_time then
        table.insert(out,string.format("pose: mounted %s ms after the mount (needs by %d)",
            finite(c.pose_mounted_ms) and finite(c.pose_mount_ms) and string.format("%.0f",c.pose_mounted_ms-c.pose_mount_ms) or "never",
            Rec.POSE_BLEND_IN_MS+Rec.POSE_MOUNT_SLACK_MS))
    end
    if not r.pose_sent_95pct then table.insert(out,string.format("pose: sent on %d of %d rows (needs 95%%)",p.sent or 0,s.rows or 0)) end
    if not r.pose_nil_accepted then
        table.insert(out,string.format("pose: skater.pose(nil) not accepted at the end (%s calls, accepted %s)",
            tostring(c.pose_nil_calls or 0),tostring(c.pose_nil_accepted)))
    end
    if not r.pose_joints_90pct then
        local parts={}
        for _,j in ipairs(Rec.JOINTS) do
            local jj=(p.joints or {})[j.field] or {reads=0,within=0,max_mm=0}
            table.insert(parts,string.format("%d %d/%d (max %d)",j.id,jj.within,jj.reads,jj.max_mm))
        end
        table.insert(out,"pose joints within 40/50 mm on under 90% of reads: "..table.concat(parts,", "))
    end
    return out
end

-- The one-line verdict: FREE_RIDE, RIDE_UNPOSED (only pose rules fail), NOT_YET with reasons, or PENDING
-- while the run or cleanup lasts. retained_unknown is never final. Rule reasons appear once the run has ended.
function Rec.verdict(s,c)
    c=type(c)=="table" and c or {}
    local reasons={}
    local final=c.phase=="done" or c.phase=="blocked"
    local judged=final or c.phase=="retained_unknown"
    local r=Rec.free_rules(s,c)
    local g,t,all,s1=s.seg2,s.turns or {},s.all,s.seg1
    if all then
        if all.tilt_max_e1>Rec.FALL_TILT_E1 then table.insert(reasons,string.format("fall: body tilted %.1f deg",all.tilt_max_e1/10)) end
        if all.not_504>0 then table.insert(reasons,string.format("fall: actor left state 504 on %d rows",all.not_504)) end
    end
    if c.wipeouts_start~=nil and c.wipeouts_now~=nil and c.wipeouts_now~=c.wipeouts_start then
        table.insert(reasons,"fall: wipeout count changed")
    end
    local posed={}
    if judged then
        if s.rows==0 then table.insert(reasons,"no following rows")
        elseif not g then table.insert(reasons,"A never seen while following") end
        if g then
            if not r.forward_0_1_to_3_m then table.insert(reasons,string.format("moved %d mm forward with the first A held (needs %d to %d)",
                g.forward_mm,Rec.MIN_FORWARD_MM,Rec.MAX_FORWARD_MM)) end
            if not r.speed_rose then table.insert(reasons,string.format("speed did not rise with the first A held (%d -> %d mm/s)",
                g.speed_start_mms,g.speed_end_mms)) end
            if not r.capturing_on_a then table.insert(reasons,string.format("capture held on %d of %d A rows",
                all and all.a_capturing or 0,all and all.a_rows or 0)) end
            if not r.left_turn_5rad then table.insert(reasons,"left turn "..(t.left_mrad and string.format("%+d mrad",t.left_mrad) or "not seen")
                .." over its stick hold (needs +"..Rec.TURN_MIN_MRAD.." or more)") end
            if not r.right_turn_5rad then table.insert(reasons,"right turn "..(t.right_mrad and string.format("%+d mrad",t.right_mrad) or "not seen")
                .." over its stick hold (needs -"..Rec.TURN_MIN_MRAD.." or less)") end
            if not r.brake_stops then
                local bad
                for k,b in ipairs(s.brakes or {}) do if b.stopped~=true and not bad then bad={k=k,b=b} end end
                table.insert(reasons,bad and string.format("brake %d of %d from %d mm/s: %s, %d of %d later braked rows moving",bad.k,#s.brakes,
                    bad.b.speed_start_mms,bad.b.stop_ms and string.format("under %d mm/s after %.0f ms (needs %d)",Rec.STOP_MMS,bad.b.stop_ms,Rec.STOP_WITHIN_MS)
                    or "never under "..Rec.STOP_MMS.." mm/s",bad.b.moving_after,bad.b.braked_rows)
                    or ((s.brakes_over or 0)>0 and "more brake runs than the record keeps" or "no brake after the first A"))
            end
            if not r.restart_rose then table.insert(reasons,s.restart and string.format("the second A from %d mm/s ended at %s mm/s (needs from under %d and +%d)",
                s.restart.start_mms,tostring(s.restart.end_mms),Rec.RESTART_FROM_MMS,Rec.RESTART_RISE_MMS) or "the second A (the restart) not seen") end
        end
        if s1 and not r.m4_segment1 then
            table.insert(reasons,string.format("M4 segment 1 failed: %.0f ms, settled height dev %d mm, drift %d mm, speed %d mm/s",
                s1.ms,s1.settled_height_dev_mm,s1.settled_drift_mm,s1.settled_speed_mms))
        end
        if all then
            if not r.tilt_under_10 then table.insert(reasons,string.format("tilt reached %.1f deg (needs under 10)",all.tilt_max_e1/10)) end
            if not r.rider_5cm_90pct then table.insert(reasons,string.format("rider within 5 cm of P on %d of %d rows (max %d mm, actor missing %d)",
                all.rider_within,all.rider_rows,all.rider_max_mm,all.rider_missing or 0)) end
            if not r.farthest_under_7_5m then table.insert(reasons,string.format("farthest %.2f m from the spawn (needs under %.1f)",
                all.max_distance_mm/1000,Rec.FARTHEST_MM/1000)) end
            if not r.under_2_57_mps then table.insert(reasons,string.format("top speed %d mm/s (needs under %d)",all.top_speed_mms,Rec.LEAD_BAND_MMS)) end
            if not r.still_at_end then table.insert(reasons,string.format("the last row moves %d mm/s (needs under %d)",all.last_hspeed_mms,Rec.STILL_MMS)) end
        end
        if s.rows>0 and not r.rows_whole then table.insert(reasons,string.format("%d rows dropped past %d",s.rows_dropped,Rec.MAX_ROWS)) end
        if not r.renewal_held then table.insert(reasons,string.format("Follow renewal not held: renewable %s, accepted %s, off %s (%s)",
            tostring(c.lease_renewable),tostring(c.lease_renew_accepted),tostring(c.lease_renew_off),tostring(c.lease_renew_last))) end
        if not r.cost_within_budget then
            local k=c.cost
            table.insert(reasons,type(k)=="table" and k.windows>0 and string.format("cost: %d of %d windows over the %d ms budget (worst %.2f ms a tick)",
                k.over_budget,k.windows,k.budget_ms,k.worst_ms) or "cost: no closed 1 s window to judge")
        end
        posed=pose_reasons(s,c,r)
    end
    if c.phase=="blocked" then table.insert(reasons,"Core blocked") end
    if c.phase=="done" then
        local checks,failed=Rec.cleanup_checks(c),{}
        for _,name in Rec.CLEANUP_NAMES do if checks[name]~=true then table.insert(failed,name) end end
        if #failed>0 then table.insert(reasons,"cleanup not CLEAN: "..table.concat(failed,", ")) end
    elseif c.phase=="retained_unknown" then
        table.insert(reasons,"cleanup retained_unknown (still draining, or stuck): not CLEAN")
    end
    -- Ending anywhere but the planned window end explains most NOT_YETs, so it leads.
    if type(c.stop_reason)=="string" and not on_window(c) then
        local at=finite(c.stop_ms) and finite(c.publish_ms) and string.format("+%.0f ms",c.stop_ms-c.publish_ms) or "before publish"
        table.insert(reasons,1,string.format("ride stopped %s: %s%s",at,c.stop_reason,
            type(c.ride_issue)=="string" and c.ride_issue~=c.stop_reason and " / Ride: "..c.ride_issue or ""))
    end
    if #reasons==0 and final then
        for _,name in Rec.RIDE_NAMES do if r[name]~=true then table.insert(reasons,"rule "..name.." not held") end end
    end
    if final then
        if #reasons==0 and #posed==0 then
            for _,name in Rec.POSE_NAMES do if r[name]~=true then table.insert(posed,"rule "..name.." not held") end end
        end
        if #reasons==0 and #posed==0 then return "FREE_RIDE",reasons end
        if #reasons==0 then return "RIDE_UNPOSED",posed end
        for _,why in ipairs(posed) do table.insert(reasons,why) end
        return "NOT_YET",reasons
    end
    for _,why in ipairs(posed) do table.insert(reasons,why) end
    if #reasons==0 then return "PENDING (FREE_RIDE so far)",reasons end
    return "PENDING",reasons
end

-- Survey directions: degrees from the rider's facing, + toward the rider's left (the body's +X). Facing is
-- (sin h, cos h) in x,z and left (cos h, -sin h), as bike_spawn.lua:237 builds the bike's yaw from h.
local function survey_dir(heading,deg)
    local a=math.rad(deg)
    local fx,fz,lx,lz=math.sin(heading),math.cos(heading),math.cos(heading),-math.sin(heading)
    return math.cos(a)*fx+math.sin(a)*lx,math.cos(a)*fz+math.sin(a)*lz
end
Rec.survey_dir=survey_dir
-- Floor rays, each from 1 m above to 3 m below the rider's position: the full ring, every
-- SURVEY_FLOOR_STEP_DEG on each of SURVEY_FLOOR_RINGS (180 rays). No ray at the rider: it would pass
-- through the rider's own shape.
function Rec.survey_floor_rays(p,heading)
    local out={}
    for _,r in ipairs(Rec.SURVEY_FLOOR_RINGS) do
        for deg=-180,180-Rec.SURVEY_FLOOR_STEP_DEG,Rec.SURVEY_FLOOR_STEP_DEG do
            local ux,uz=survey_dir(heading,deg)
            local dx,dz=r*ux,r*uz
            table.insert(out,{r=r,deg=deg,dx=dx,dz=dz,from={p[1]+dx,p[2]+1,p[3]+dz},to={p[1]+dx,p[2]-3,p[3]+dz}})
        end
    end
    return out
end
-- The check ray that closes every obstacle tick is 0.75 m straight ahead.
-- It must report a hit on the fitted plane, beside counting every obstacle ray that
-- is not "clear" as blocked.
function Rec.survey_check_ray(p,heading)
    local ux,uz=survey_dir(heading,0)
    local r=Rec.SURVEY_FLOOR_RINGS[1]
    local dx,dz=r*ux,r*uz
    return {r=r,deg=0,dx=dx,dz=dz,from={p[1]+dx,p[2]+1,p[3]+dz},to={p[1]+dx,p[2]-3,p[3]+dz}}
end
-- A hit within SURVEY_RESIDUAL_M of the fitted plane at the ray's own offset.
function Rec.survey_on_plane(plane,ray,v)
    return type(plane)=="table" and type(v)=="table" and finite(v[2])
        and math.abs(v[2]-(plane.a+plane.b*ray.dx+plane.c*ray.dz))<=Rec.SURVEY_RESIDUAL_M
end
-- One floor hit: a vector inside its own vertical segment, bounded like the spawn's ray (bike_spawn.lua:57-63).
function Rec.survey_floor_hit(ray,hit)
    local v=arr(hit)
    if not v or math.abs(v[1]-ray.from[1])>.025 or math.abs(v[3]-ray.from[3])>.025
        or v[2]<ray.to[2] or v[2]>ray.from[2] then return nil end
    return v
end
-- Least-squares plane y = a + b*dx + c*dz through the hits (dx, dz from the rider) and its worst residual.
function Rec.survey_plane(points)
    local n,sx,sz,sy,sxx,szz,sxz,sxy,szy=0,0,0,0,0,0,0,0,0
    for _,q in ipairs(points) do
        n+=1;sx+=q.dx;sz+=q.dz;sy+=q.y;sxx+=q.dx*q.dx;szz+=q.dz*q.dz;sxz+=q.dx*q.dz;sxy+=q.dx*q.y;szy+=q.dz*q.y
    end
    local function det(m) return m[1]*(m[5]*m[9]-m[6]*m[8])-m[2]*(m[4]*m[9]-m[6]*m[7])+m[3]*(m[4]*m[8]-m[5]*m[7]) end
    local A={n,sx,sz,sx,sxx,sxz,sz,sxz,szz}
    local d=det(A)
    if n<3 or not finite(d) or math.abs(d)<1e-9 then return nil end
    local function solve(col)
        local m=table.clone(A)
        m[col],m[col+3],m[col+6]=sy,sxy,szy
        return det(m)/d
    end
    local plane={a=solve(1),b=solve(2),c=solve(3),residual=0}
    for _,q in ipairs(points) do
        plane.residual=math.max(plane.residual,math.abs(q.y-(plane.a+plane.b*q.dx+plane.c*q.dz)))
    end
    return plane
end
-- Obstacle rays at each SURVEY_HEIGHTS height above the fitted plane, from 0.75 m out to SURVEY_R, every
-- SURVEY_OBSTACLE_STEP_DEG all round (180 directions a height): 1080 rays, every one must answer clear.
function Rec.survey_obstacle_rays(p,heading,plane)
    local out={}
    local function at(dx,dz,h) return plane.a+plane.b*dx+plane.c*dz+h end
    for _,h in ipairs(Rec.SURVEY_HEIGHTS) do
        for deg=-180,180-Rec.SURVEY_OBSTACLE_STEP_DEG,Rec.SURVEY_OBSTACLE_STEP_DEG do
            local ux,uz=survey_dir(heading,deg)
            local x0,z0,x1,z1=.75*ux,.75*uz,Rec.SURVEY_R*ux,Rec.SURVEY_R*uz
            table.insert(out,{deg=deg,r=Rec.SURVEY_R,h=h,from={p[1]+x0,at(x0,z0,h),p[3]+z0},to={p[1]+x1,at(x1,z1,h),p[3]+z1}})
        end
    end
    return out
end
-- The survey's size: floor rays, obstacle rays, ticks (the floor at SURVEY_RAYS_PER_TICK a tick, the
-- obstacles at one fewer, each obstacle tick closing with its check ray) and every world.probe call.
function Rec.survey_counts()
    local floor=#Rec.SURVEY_FLOOR_RINGS*(360//Rec.SURVEY_FLOOR_STEP_DEG)
    local obstacle=#Rec.SURVEY_HEIGHTS*(360//Rec.SURVEY_OBSTACLE_STEP_DEG)
    local per=Rec.SURVEY_RAYS_PER_TICK
    local floor_ticks=(floor+per-1)//per
    local obstacle_ticks=(obstacle+per-2)//(per-1)
    return {floor=floor,obstacle=obstacle,floor_ticks=floor_ticks,obstacle_ticks=obstacle_ticks,ticks=floor_ticks+obstacle_ticks,
        probes=floor+obstacle+obstacle_ticks}
end
-- One survey verdict. misses: floor rays that missed or left their segment; blocked: obstacle rays
-- that did not answer clear, hit or unavailable (0 while judging the floor alone).
function Rec.survey_judge(heading,floor,misses,plane,blocked)
    local out={pass=false,floor_rays=#floor+misses,floor_misses=misses,blocked=blocked}
    if misses>0 then out.why=misses.." floor rays missed or left their segment";return out end
    if not plane then out.why="floor plane could not be fitted";return out end
    local fx,fz,lx,lz=math.sin(heading),math.cos(heading),math.cos(heading),-math.sin(heading)
    out.residual_mm=round(plane.residual*1000)
    out.slope_deg=math.deg(math.atan(math.sqrt(plane.b^2+plane.c^2)))
    out.downhill_deg=math.deg(math.atan(-(plane.b*fx+plane.c*fz)))
    out.downhill_dir_deg=(plane.b~=0 or plane.c~=0) and math.deg(math.atan2(-(plane.b*lx+plane.c*lz),-(plane.b*fx+plane.c*fz))) or 0
    if plane.residual>Rec.SURVEY_RESIDUAL_M then
        out.why=string.format("floor not flat: %d mm off its plane (at most %d)",out.residual_mm,round(Rec.SURVEY_RESIDUAL_M*1000))
    elseif out.slope_deg>Rec.SURVEY_SLOPE_DEG then
        out.why=string.format("floor slopes %.2f deg (at most %.1f)",out.slope_deg,Rec.SURVEY_SLOPE_DEG)
    elseif out.downhill_deg>Rec.SURVEY_DOWNHILL_DEG then
        out.why=string.format("facing runs %.2f deg downhill (at most %.2f): turn toward uphill or across",out.downhill_deg,Rec.SURVEY_DOWNHILL_DEG)
    elseif -out.downhill_deg>Rec.SURVEY_UPHILL_DEG then
        out.why=string.format("facing runs %.2f deg uphill (at most %.2f): turn toward across the slope",-out.downhill_deg,Rec.SURVEY_UPHILL_DEG)
    elseif type(blocked)~="number" or blocked>0 then
        out.why=tostring(blocked).." obstacle rays not clear (hit or unavailable) inside the clear area"
    else out.pass=true;out.why="clear" end
    return out
end
-- Only the closed live-contact playable owner may consume this verdict. A
-- gentle grade requires a tighter measured plane, never a level substitute.
function Rec.playable_survey_judge(heading,floor,misses,plane,blocked)
    local out=Rec.survey_judge(heading,floor,misses,plane,blocked)
    local displayed=finite(out.slope_deg) and tonumber(string.format("%.2f",out.slope_deg)) or nil
    if out.pass and displayed and displayed<=.05 then return out end
    out.pass=false
    if misses>0 or not plane then return out end
    if #floor~=Rec.survey_counts().floor or not finite(plane.a) or not finite(plane.b)
        or not finite(plane.c) or not finite(plane.residual) or plane.residual<0 then
        out.why="complete measured playable plane required"
    elseif plane.residual>Rec.PLAYABLE_GRADE_RESIDUAL_M then
        out.why="gentle-grade plane exceeds 3 mm residual"
    elseif not finite(out.slope_deg) or out.slope_deg>Rec.PLAYABLE_GRADE_SLOPE_DEG then
        out.why=string.format("playable floor slopes %.2f deg (at most %.1f)",out.slope_deg or 0,Rec.PLAYABLE_GRADE_SLOPE_DEG)
    elseif type(blocked)~="number" or blocked~=0 then
        out.why=tostring(blocked).." obstacle rays not clear inside the playable area"
    else out.pass=true;out.why="measured gentle grade; aligned placement still required" end
    return out
end
-- Arm's check: a passing survey, at most SURVEY_MAX_AGE_MS old, the rider still where it was taken.
function Rec.survey_fresh(sv,actor,now)
    if type(sv)~="table" or sv.pass~=true or not finite(sv.at) or type(sv.p)~="table" or not finite(sv.heading) then
        return false,"no passing survey"
    end
    if not finite(now) or now-sv.at>Rec.SURVEY_MAX_AGE_MS then return false,"survey older than "..(Rec.SURVEY_MAX_AGE_MS//1000).." s" end
    local v=type(actor)=="table" and arr(actor.position) or nil
    if not v or not finite(actor.heading) then return false,"rider position or heading unreadable" end
    local moved=math.sqrt((v[1]-sv.p[1])^2+(v[3]-sv.p[3])^2)
    if moved>Rec.SURVEY_MOVE_M then return false,string.format("rider moved %.2f m since the survey",moved) end
    if math.abs(wrap(actor.heading-sv.heading))>Rec.SURVEY_TURN_RAD then return false,"rider turned since the survey" end
    return true
end

return table.freeze(Rec)

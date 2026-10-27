-- Constructed SDK transport and an independent one-body world. No game API,
-- collision floor clamp, force-model prediction or fold output integrates this
-- world. A packet from N is applied at N+1 and changes the sample at N+2.
local Fixtures=require("./ride_runtime_tests")
local Hop=require("./force_stage_hop_fixture")
local Forces=require("./forces")
local G=require("./bike_geometry")
local M=require("./force_math")
local Pose=require("./mounted_pose")
local Presentation=require("./rider_presentation")
local World={}
local h=Forces.native_seconds
local gravity={0,-9.8,0}
local function vec(v) return vector.create(v[1],v[2],v[3]) end
local function arr(v) return {v.x,v.y,v.z} end
local function inc(v)
    local digits,carry={},1
    for i=#v,1,-1 do
        local n=string.byte(v,i)-48+carry
        if n==10 then n,carry=0,1 else carry=0 end
        table.insert(digits,1,string.char(48+n))
    end
    if carry==1 then table.insert(digits,1,"1") end
    return table.concat(digits)
end
local function root(body) return M.sub(body.center_of_mass,M.turn(body.orientation,G.com)) end
local function hub(body,axle) return M.add(body.center_of_mass,M.turn(body.orientation,M.sub(axle,G.com))) end
local function rotation(q,w,seconds)
    local magnitude=math.sqrt(w[1]^2+w[2]^2+w[3]^2)
    if magnitude<1e-12 then return M.normalized(q) end
    local k=math.sin(magnitude*seconds/2)/magnitude
    local x,y,z,r=w[1]*k,w[2]*k,w[3]*k,math.cos(magnitude*seconds/2)
    return M.normalized({r*q[1]+x*q[4]+y*q[3]-z*q[2],
        r*q[2]-x*q[3]+y*q[4]+z*q[1],r*q[3]+x*q[2]-y*q[1]+z*q[4],
        r*q[4]-x*q[1]-y*q[2]-z*q[3]})
end
local function integrate(body,command)
    local out=M.copy(body)
    local force=command and arr(command.force) or {0,0,0}
    local torque=command and arr(command.torque) or {0,0,0}
    local impulse=command and command.impulse and arr(command.impulse) or {0,0,0}
    for i=1,3 do out.linear_velocity[i]=body.linear_velocity[i]+h*(gravity[i]+force[i]/body.mass)+impulse[i]/body.mass end
    out.angular_velocity=M.add(body.angular_velocity,M.tensor(body,M.mul(torque,h),true))
    for i=1,3 do out.center_of_mass[i]=body.center_of_mass[i]+h*out.linear_velocity[i] end
    out.orientation=rotation(body.orientation,out.angular_velocity,h)
    return out
end
local function zero() return {0,0,0} end

function World.new(options)
    options=options or {}
    local world={tick=0,commands={},records={},ring={},previews={},rows={},history={},samples={},
        impulses={},applied_impulses={},next_sequence="9007199254750000",floor=options.floor or 0,
        successor_delay=options.successor_delay or 0,air=0,initial_root=nil,
        peak_force=0,peak_torque=0,peak_vertical=0,peak_horizontal=0,peak_height=0,
        min_clearance=math.huge,pose_checks=0,max_root_distance=0,max_lag=0,clear_ray_steps=0,
        airborne_steps=0,grounded_steps=0,acknowledged=0,adoptions=0,refusals=0}
    assert(world.successor_delay%1==0 and world.successor_delay>=0 and world.successor_delay<=1)
    local controller=Hop.new()
    local proxy={hop_policy=controller.hop_policy,tuning=controller.tuning}
    function proxy:admit_measured(body) return controller:admit_measured(body) end
    function proxy:preview(...)
        local model,candidate=controller:preview(...)
        world.previews[#world.previews+1]={tick=world.tick,model=M.copy(model)}
        if not model.valid then world.refusals+=1 end
        return model,candidate
    end
    function proxy:_adopt(candidate) controller:_adopt(candidate);world.adoptions+=1 end
    function proxy:reset() controller:reset() end
    function proxy:invalidate_continuity() controller:invalidate_continuity() end
    table.freeze(proxy)
    -- The shared fixture's no_tricks and/or expression retains its stand-in.
    -- An explicit false survives the model override and disables that path.
    local f=Fixtures.fixture({actual_contact=true,models={force=proxy,tricks=false}})
    world.f=f;world.controller=controller
    local body=Forces.proposed_body()
    body.orientation=M.copy(options.orientation or {0,0,0,1})
    local y=-math.huge
    for _,axle in ipairs({G.front_axle,G.rear_axle}) do
        y=math.max(y,world.floor+G.wheel_radius-M.turn(body.orientation,M.sub(axle,G.com))[2])
    end
    body.center_of_mass={0,y+(options.height or 0),0}
    -- Ride begins with stationary rotors. Supply the conserved total momentum
    -- that settles into 2 m/s rolling motion before the tested hop is requested.
    local rolling=options.rolling_speed or 2
    local initial=rolling*(1+2*Forces.proposed_wheels()[1].inertia/(body.mass*G.wheel_radius^2))
    body.linear_velocity={0,options.vertical_speed or 0,initial}
    world.body=body;world.initial_root=root(body);world.history[1]=M.copy(body)
    function f.sample()
        local b=world.body
        return {epoch=newproxy(),serial=f.serial,time=f.time,seconds=h,mass=b.mass,
            position=vec(b.center_of_mass),velocity=vec(b.linear_velocity),angular_velocity=vec(b.angular_velocity),
            inertia=vec(b.inertia_body),rotation=M.copy(b.orientation)}
    end
    world.samples[0]=f.sample()
    function f.api.probe_batch(epoch,rays,settings)
        assert(epoch==f.read.epoch and #rays==2 and settings.require_contact and settings.exclude_local_actor)
        local hits={}
        local clear_count=0
        for i,ray in ipairs(rays) do
            local a,b=arr(ray.from),arr(ray.to)
            local dy=b[2]-a[2]
            assert(dy<0 and math.abs(a[1]-b[1])<1e-5 and math.abs(a[3]-b[3])<1e-5,"fixture expects the actual vertical wheel rays")
            local fraction=(world.floor-a[2])/dy
            if options.no_plane or fraction<0 or fraction>1 then
                hits[i]={status="clear"};clear_count+=1
            else
                hits[i]={status="hit",position=vector.create(a[1],world.floor,a[3]),fraction=fraction,
                    normal_available=true,surface_velocity_available=true,normal=vector.create(0,1,0),
                    surface_velocity=vector.create(0,0,0),motion="measured"}
            end
        end
        if clear_count==2 then world.clear_ray_steps+=1 end
        world.last_rays=M.copy(rays)
        return {status="available",native_casts=2,budget_exhausted=false,epoch=epoch,
            local_actor_excluded=true,owned_bodies_excluded=true,rays=hits}
    end
    local function refresh()
        for _,record in ipairs(world.ring) do
            if world.tick>=record.tick+1 then record.outcome="applied" end
            local visible=record.tick+2+world.successor_delay
            if not record.successor and world.tick>=visible then
                assert(world.samples[visible],"successor must be an existing independently integrated sample")
                record.successor=M.copy(world.samples[visible])
            end
        end
    end
    function f.api.submit(epoch,command)
        assert(not world.closing,"receipt drain must never submit another command")
        refresh()
        assert(epoch==f.read.epoch,"submit uses the observed epoch")
        assert(#world.ring<4,"constructed SDK ring is bounded")
        for _,record in ipairs(world.ring) do assert(record.outcome~="queued","constructed SDK has one pending inbox") end
        assert(world.commands[world.tick]==nil,"one command per body sample")
        world.next_sequence=inc(world.next_sequence)
        local record={sequence=world.next_sequence,serial=f.serial,produced=inc(f.serial),tick=world.tick,
            command=M.copy(command),outcome="queued"}
        world.commands[world.tick]=record;world.records[record.sequence]=record
        world.ring[#world.ring+1]=record
        world.peak_force=math.max(world.peak_force,M.length(arr(command.force)))
        world.peak_torque=math.max(world.peak_torque,M.length(arr(command.torque)))
        if command.impulse then
            assert(command.impulse_id and not world.impulses[command.impulse_id],"one accepted impulse per event")
            world.impulses[command.impulse_id]={tick=world.tick,impulse=arr(command.impulse),
                speed=M.length({world.body.linear_velocity[1],0,world.body.linear_velocity[3]}),
                preview=M.copy(world.previews[#world.previews].model)}
        end
        return true,nil,record.sequence
    end
    function f.api.receipt(sequence)
        refresh()
        local record=world.records[sequence]
        assert(record and not record.acked,"receipt belongs to its exact unacknowledged sequence")
        local applied=record.outcome=="applied"
        return {sequence=sequence,requested_serial=record.serial,produced_serial=applied and record.produced or "0",
            outcome=record.outcome,force_attempted=applied,torque_attempted=applied,retained=false,quarantined=false,
            cleanup_disposition="none",successor=record.successor}
    end
    function f.api.acknowledge(sequence)
        refresh()
        local record=world.ring[1]
        assert(record and record.sequence==sequence and record.outcome=="applied" and record.successor,
            "ACK requires the oldest receipt's independently measured successor")
        record.acked=true;table.remove(world.ring,1);world.acknowledged+=1
        return true
    end
    return setmetatable(world,{__index=World})
end

function World:measure()
    local previous=self.rows[#self.rows]
    if previous and previous.tick==self.tick then return previous end
    local b=self.body
    local clearances={hub(b,G.front_axle)[2]-self.floor-G.wheel_radius,hub(b,G.rear_axle)[2]-self.floor-G.wheel_radius}
    local clearance=math.min(clearances[1],clearances[2])
    local airborne=clearances[1]>.005 and clearances[2]>.005
    self.peak_height=math.max(self.peak_height,root(b)[2]-self.initial_root[2])
    self.peak_horizontal=math.max(self.peak_horizontal,M.length({b.linear_velocity[1],0,b.linear_velocity[3]}))
    self.peak_vertical=math.max(self.peak_vertical,math.abs(b.linear_velocity[2]))
    self.min_clearance=math.min(self.min_clearance,clearance)
    if airborne then self.airborne_steps+=1 else self.grounded_steps+=1 end
    local air=Presentation.step_air_extension(self.air,h,airborne)
    assert(air.valid,"presentation accepts the same native interval")
    self.air=air.blend
    local delayed=self.history[math.max(1,self.tick-1)]
    local skater_root=root(delayed)
    self.max_lag=math.max(self.max_lag,M.length(M.sub(root(b),skater_root)))
    -- Both authored posture endpoints must remain reachable, not just the
    -- neutral hip target. This makes no claim about a native Follow or pose.
    for _,compression in ipairs({0,1}) do
        local offsets,reason=Presentation.rider_offsets({compression=compression,air_extension=self.air},
            {orientation=b.orientation,airborne=airborne})
        assert(offsets,reason)
        local plan,why=Pose.compose({bike={center_of_mass=b.center_of_mass,rotation=b.orientation},
            articulation={crank_phase=0,steer=0},rider={hip_offset=offsets.hip_offset},skater_root=skater_root})
        assert(plan,why)
        local valid,detail=Pose.validate_pose(plan.pose)
        assert(valid,detail)
        assert(not plan.diagnostics.fit_limited,"rider fitting must remain inside authored reach")
        local limbs=0
        for _,limb in pairs(plan.diagnostics.limbs) do
            limbs+=1
            assert(limb.reaches and not limb.clamped and limb.release==0,"every held limb must reach its actual target")
        end
        assert(limbs==4,"all four actual IK limbs were checked")
        assert(M.finite(plan.diagnostics.skater_root_distance) and plan.diagnostics.skater_root_distance<=Pose.SENT_JOINT_LIMIT)
        self.max_root_distance=math.max(self.max_root_distance,plan.diagnostics.skater_root_distance)
        self.pose_checks+=1
    end
    local up=M.turn(b.orientation,{0,1,0})
    local row={tick=self.tick,body=M.copy(b),clearance=clearance,front_clearance=clearances[1],rear_clearance=clearances[2],
        airborne=airborne,vertical_speed=b.linear_velocity[2],horizontal_speed=M.length({b.linear_velocity[1],0,b.linear_velocity[3]}),
        tilt=math.acos(math.clamp(up[2],-1,1))*180/math.pi,height=root(b)[2]-self.initial_root[2]}
    self.rows[#self.rows+1]=row
    return row
end

function World:observe(buttons)
    self.f.pad.buttons.right_stick=buttons and buttons.hop==true or false
    self.f.pad.buttons.a=buttons and buttons.pedal==true or false
    self.status=self.f.observe()
    return self.status
end
function World:advance()
    local record=self.commands[self.tick-1]
    if record and record.command.impulse then
        local id=record.command.impulse_id
        assert(not self.applied_impulses[id],"integrator must consume each accepted impulse once")
        self.applied_impulses[id]=true
    end
    self.body=integrate(self.body,record and record.command)
    self.tick+=1;self.f.advance()
    self.history[self.tick+1]=M.copy(self.body);self.samples[self.tick]=self.f.sample()
end
function World:run(steps,buttons)
    for _=1,steps do
        local row=self:measure()
        local selected=type(buttons)=="function" and buttons(self,row) or buttons
        local state=self:observe(selected)
        if state.stop_requested then return false,state.issue end
        self:advance()
    end
    return true
end
function World:close()
    if self.closure then return self.closure end
    local before=self.f.ride:status()
    local closure={before_stop=self:measure(),tail_sequences={},advance_steps=0,
        submitted_before=before.submitted,acknowledged_before=self.acknowledged,adoptions_before=self.adoptions}
    for _,record in ipairs(self.ring) do closure.tail_sequences[#closure.tail_sequences+1]=record.sequence end
    assert(before.pending_count==#closure.tail_sequences,"Ride and constructed transport agree on the exact tail")
    self.closing=true
    self.status=self.f.ride:stop("offline fixture complete")
    self.status=self.f.ride:drain()
    -- Publish only independently integrated successor samples. The optional
    -- extra publication delay includes one gravity-only step after the final
    -- accepted packet; it is not another modeled or supported ride step.
    while #self.ring>0 and closure.advance_steps<2+self.successor_delay do
        self:advance();closure.advance_steps+=1
        self:measure()
        self.status=self.f.ride:drain()
    end
    assert(#self.ring==0 and self.status.pending_count==0 and not self.status.force_pending and not self.status.unknown,
        "bounded drain must close every constructed receipt")
    assert(self.status.submitted==closure.submitted_before and self.adoptions==closure.adoptions_before,
        "stop and drain cannot submit or adopt another force command")
    for _,sequence in ipairs(closure.tail_sequences) do
        assert(self.records[sequence].acked,"each exact tail sequence must receive its own ACK")
    end
    assert(self.acknowledged-closure.acknowledged_before==#closure.tail_sequences,"tail ACK count is exact")
    assert(self.status.acknowledged==self.status.submitted and self.status.acknowledged==self.acknowledged,
        "every accepted constructed command has a terminal ACK")
    closure.final_tick=self.tick
    closure.final_measurement=self.rows[#self.rows]
    assert(closure.final_measurement.tick==self.tick,"the last integrated body must have measured metrics and rider IK")
    self.closure=closure
    return closure
end
function World:impulse_count()
    local count=0 for _ in pairs(self.impulses) do count+=1 end return count
end
function World:summary()
    local last=self.rows[#self.rows]
    return {peak_force=self.peak_force,peak_torque=self.peak_torque,peak_height=self.peak_height,
        peak_horizontal=self.peak_horizontal,peak_vertical=self.peak_vertical,min_clearance=self.min_clearance,
        final_tilt=last and last.tilt,final_clearance=last and last.clearance,final_vertical=last and last.vertical_speed,
        impulses=self:impulse_count(),pose_checks=self.pose_checks,max_root_distance=self.max_root_distance,
        max_follow_lag=self.max_lag,airborne_steps=self.airborne_steps,clear_ray_steps=self.clear_ray_steps,
        refusals=self.refusals,adoptions=self.adoptions,acknowledged=self.acknowledged,
        drain_steps=self.closure and self.closure.advance_steps,
        drained_receipts=self.closure and #self.closure.tail_sequences,
        final_measured_tick=last and last.tick,terminal_tick=self.closure and self.closure.final_tick,
        final_pending_count=self.status and self.status.pending_count,
        final_force_pending=self.status and self.status.force_pending,
        final_unknown=self.status and self.status.unknown}
end
World.native_seconds=h
World.root=root
World.zero=zero
return table.freeze(World)

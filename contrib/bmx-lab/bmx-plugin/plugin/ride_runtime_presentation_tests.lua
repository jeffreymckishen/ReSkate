-- Ride's presentation pose: the bike's own steer, wheel and crank phases from
-- each accepted step, which Core hands to Spawn's follow visual. Constructed
-- transport only; no Host or native effect. The runner stages the real Ride
-- with only its private literal enabled.
local Fixtures=require("./ride_runtime_tests")
local Identity=require("./lease_identity")
local Forces=require("./forces")
local ForceStage=require("./force_stage")
local Visual=require("./bike_visual")
local Composer=require("./ride_composer")
local Tests={}
local TAU=2*math.pi
local H=Forces.native_seconds
local function copy(v)
    if type(v)~="table" then return v end
    local out={} for k,c in pairs(v) do out[k]=copy(c) end return out
end
local function inc(v)
    local chars,carry={},1
    for i=#v,1,-1 do
        local n=string.byte(v,i)-48+carry
        if n==10 then n,carry=0,1 else carry=0 end
        table.insert(chars,1,string.char(48+n))
    end
    if carry==1 then table.insert(chars,1,"1") end
    return table.concat(chars)
end
local function wrap(angle)
    angle %= TAU
    if angle > math.pi then angle -= TAU end
    return angle
end
-- ride_runtime_tests' fixture with ride_runtime_pipeline_tests' constructed SDK
-- ring, so a command is accepted every step. Each preview's model and each
-- accepted step's pose are kept.
local function fixture(options)
    options=options or {}
    local f=Fixtures.fixture({no_tricks=true,models=options.models})
    local sample=f.sample
    local speed=options.speed or 1
    function f.sample() local row=sample();row.velocity=vector.create(0,0,speed);return row end
    f.native={};f.records={};f.commands={};f.next_id="9007199254745000";f.models={}
    local preview=f.force.preview
    function f.force:preview(...)
        local model,candidate=preview(self,...)
        if f.on_model then f.on_model(model) end
        f.models[#f.models+1]={serial=f.serial,model=copy(model)}
        return model,candidate
    end
    local function refresh()
        for _,r in ipairs(f.native) do
            if r.outcome=="queued" and not f.hold_inbox and Identity.compare(f.serial,r.produced)>=0 then r.outcome="applied" end
            if r.outcome=="applied" and not r.successor and not f.withhold_successors
                and Identity.compare(f.serial,r.produced)>0 then r.successor=copy(f.sample()) end
        end
    end
    function f.api.submit(epoch,command)
        refresh()
        assert(epoch==f.read.epoch,"command uses this exact measured body epoch")
        if f.refusal then return false,f.refusal end
        f.next_id=inc(f.next_id)
        local r={sequence=f.next_id,requested=f.serial,produced=inc(f.serial),outcome="queued"}
        f.records[r.sequence]=r;table.insert(f.native,r)
        table.insert(f.commands,{sequence=r.sequence,serial=f.serial,command=copy(command)})
        return true,nil,r.sequence
    end
    function f.api.receipt(sequence)
        refresh()
        local r=f.records[sequence]
        local attempted=r.outcome=="applied"
        return {sequence=r.sequence,requested_serial=r.requested,produced_serial=attempted and r.produced or "0",
            outcome=r.outcome,force_attempted=attempted,torque_attempted=attempted,retained=false,quarantined=false,
            cleanup_disposition="none",successor=r.successor}
    end
    function f.api.acknowledge(sequence)
        refresh()
        local r=f.native[1]
        assert(r and r.sequence==sequence,"SDK acknowledges only its oldest receipt")
        table.remove(f.native,1)
        return true
    end
    return f
end
-- Steps the fixture n bodies on, keeping each step's status. The mapper waits
-- for a neutral pad before its first action, so the first step is neutral and
-- f.held (the pad's buttons and axes) is pressed from the second.
local function ride(f,n)
    local out={}
    for i=1,n do
        if f.started then f.advance() end
        if f.started and f.held then
            for key,value in pairs(f.held) do
                if f.pad.buttons[key]~=nil then f.pad.buttons[key]=value else f.pad[key]=value end
            end
        end
        f.started=true
        out[i]=f.observe()
    end
    return out
end

function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(_,run) cases+=1;run() end

    case("the gearing is the composer's",function()
        -- Ride holds the literal so it need not load the composer.
        local f=fixture();f.held={a=true}
        local s=ride(f,3)
        local model=f.models[3].model
        local before=s[2].presentation_pose.crank_phase
        check(model.pedaling==true and model.effective_pedal_torque>0,"the default pedal applies axle torque")
        check(s[3].presentation_pose.crank_phase==wrap(before+model.wheels[2].angular_speed*H/Composer.crank_ratio),
            "the cranks turn by the rear wheel over Composer.crank_ratio")
    end)
    case("before any step the pose is neutral",function()
        local f=fixture()
        local s=f.ride:status()
        local neutral=Visual.neutral()
        local keys=0
        for key,value in pairs(s.presentation_pose) do keys+=1;check(neutral[key]==value,key.." is neutral") end
        for key in pairs(neutral) do check(s.presentation_pose[key]~=nil,"bike_visual's "..key.." is there") end
        check(keys==8 and s.model_history==nil and table.isfrozen(s.presentation_pose),"eight frozen fields, no step yet")
        check(Visual.valid_pose(s.presentation_pose),"bike_visual accepts it")
    end)
    case("each accepted step steers, rolls the wheels and turns the cranks while pedaling",function()
        local f=fixture();f.held={a=true,left_x=-1}
        local statuses=ride(f,12)
        local front,rear,crank,pedaled=0,0,0,0
        for i,s in ipairs(statuses) do
            local model=f.models[i].model
            check(s.submitted==i and f.models[i].serial==f.commands[i].serial,"step "..i.." is accepted")
            front=wrap(front+model.wheels[1].angular_speed*H)
            rear=wrap(rear+model.wheels[2].angular_speed*H)
            if model.pedaling then crank=wrap(crank+model.wheels[2].angular_speed*H/(25/9));pedaled+=1 end
            local pose=s.presentation_pose
            check(pose.steer==model.front_steer_angle,"step "..i.." draws the kernel's steer angle")
            check(pose.front_wheel_phase==front and pose.rear_wheel_phase==rear,"step "..i.." wheel phases integrate the accepted speeds")
            check(pose.crank_phase==crank,"step "..i.." crank phase")
            check(pose.barspin==0 and pose.tailwhip==0 and pose.movement_bike_pitch==0 and pose.movement_bike_roll==0,"no trick terms")
            check(s.model_history.serial==f.commands[i].serial,"the pose is that of the accepted step model_history names")
            check(Visual.valid_pose(pose) and table.isfrozen(pose),"a frozen pose bike_visual accepts")
        end
        check(pedaled==11 and statuses[12].presentation_pose.steer~=0,"the rider pedals and the bars are turned throughout")
        check(statuses[12].presentation_pose.rear_wheel_phase~=0 and statuses[12].presentation_pose.crank_phase~=0,"the wheels and cranks moved")
    end)
    case("a coast or a spun-out pedal leaves the cranks still while the wheels roll",function()
        local f=fixture({speed=2})
        local statuses=ride(f,6)
        for i=2,6 do
            local a,b=statuses[i-1].presentation_pose,statuses[i].presentation_pose
            check(f.models[i].model.pedaling==false and b.crank_phase==a.crank_phase,"coasting, step "..i.." keeps the cranks")
            check(b.rear_wheel_phase~=a.rear_wheel_phase,"the rear wheel rolls on, step "..i)
        end
        -- At the kernel's top pedaling speed the latch coasts with the pedal held.
        local g=fixture({speed=Forces.tuning().pedal_top_speed+.3});g.held={a=true}
        local held=ride(g,6)
        for i=2,6 do
            check(g.models[i].model.pedaling==false,"the latch coasts at top speed, step "..i)
            check(held[i].presentation_pose.crank_phase==held[i-1].presentation_pose.crank_phase
                and held[i].presentation_pose.rear_wheel_phase~=held[i-1].presentation_pose.rear_wheel_phase,
                "held pedal at top speed: wheels roll, cranks still, step "..i)
        end
    end)
    case("zero pedal torque holds the cranks while a moving wheel rolls",function()
        local f=fixture({speed=2});f.held={a=true}
        -- This is the exact controller both Ride and the preview recorder use.
        f.force.tuning.pedal_torque=0
        local statuses=ride(f,6)
        for i=2,6 do
            local model=f.models[i].model
            local before,pose=statuses[i-1].presentation_pose,statuses[i].presentation_pose
            check(not statuses[i].stop_requested and statuses[i].submitted==i,"zero torque accepts the ordinary step "..i)
            check(model.pedaling==true and model.effective_pedal_torque==0,"held input has intent but no axle torque, step "..i)
            check(pose.rear_wheel_phase~=before.rear_wheel_phase,"the moving wheel still rolls, step "..i)
            check(pose.crank_phase==before.crank_phase,"zero effective torque keeps the cranks still, step "..i)
        end
    end)
    case("the pose is shared, not copied, by each status",function()
        local f=fixture();f.held={a=true}
        ride(f,3)
        local a,b=f.ride:status(),f.ride:status()
        check(a.presentation_pose==b.presentation_pose,"one table between steps")
        f.advance();local c=f.observe()
        check(c.presentation_pose~=a.presentation_pose and table.isfrozen(c.presentation_pose),"a new accepted step, a new frozen pose")
    end)
    case("a step without an accepted command keeps the pose",function()
        local f=fixture();f.held={a=true};f.withhold_successors=true
        local s=ride(f,4)
        check(s[3].pending_count==3 and s[4].backpressure=="receipt_capacity","the fourth step is backpressured")
        check(s[4].presentation_pose==s[3].presentation_pose and s[4].model_history.serial==s[3].model_history.serial,
            "no accepted step, no new pose")
        local g=fixture();g.held={a=true}
        ride(g,2)
        local before=g.ride:status()
        g.refusal="Core guard refused";g.advance();local refused=g.observe()
        check(refused.stop_requested and refused.presentation_pose==before.presentation_pose,"a refused admission keeps the pose")
        local d=fixture();d.held={a=true}
        ride(d,2)
        local kept=d.ride:status().presentation_pose
        d.api.submit=function() error("possible native admission") end
        d.advance();local unknown=d.observe()
        check(unknown.unknown and unknown.presentation_pose==kept,"an unknown admission keeps the pose")
    end)
    case("a duplicate body keeps the pose",function()
        local f=fixture();f.held={a=true}
        ride(f,2)
        local before=f.ride:status()
        f.new_input();local again=f.observe()
        check(again.presentation_pose==before.presentation_pose and again.submitted==before.submitted,"same serial, no step")
    end)
    case("the zero force stage holds the bars and cranks",function()
        local f=fixture({models={force=ForceStage.new()}});f.held={a=true,left_x=-1}
        local s=ride(f,5)
        for i=1,5 do
            check(not s[i].stop_requested and s[i].submitted==i,"step "..i.." submits its zero command")
            local pose=s[i].presentation_pose
            check(pose.steer==0 and pose.crank_phase==0,"the stage commands nothing, so nothing turns")
            check(pose.front_wheel_phase==0 and pose.rear_wheel_phase==0,"its unchanged wheels do not spin")
        end
    end)
    for _,spec in ipairs({{"a steer past 1 rad",function(m) m.front_steer_angle=1.2 end},
        {"a nonfinite steer",function(m) m.front_steer_angle=0/0 end},
        {"a string steer",function(m) m.front_steer_angle="0" end},
        {"a numeric cadence",function(m) m.pedaling=1 end},
        {"a negative effective pedal torque",function(m) m.effective_pedal_torque=-1 end},
        {"a string effective pedal torque",function(m) m.effective_pedal_torque="75" end},
        {"a nonfinite effective pedal torque",function(m) m.effective_pedal_torque=0/0 end},
        {"an infinite effective pedal torque",function(m) m.effective_pedal_torque=math.huge end},
        {"an excessive effective pedal torque",function(m) m.effective_pedal_torque=1e6+1 end}}) do
        case("a model with "..spec[1].." stops before its command",function()
            local f=fixture();f.held={a=true}
            ride(f,2)
            local kept=f.ride:status().presentation_pose
            f.on_model=spec[2]
            f.advance();local s=f.observe()
            check(s.stop_requested and s.issue=="bounded presentation model unavailable","stops: "..tostring(s.issue))
            check(#f.commands==2 and s.presentation_pose==kept,"no command and no pose from that step")
        end)
    end
    return {cases=cases,assertions=assertions}
end
return table.freeze(Tests)

-- Constructed continuity breaks, accepted predictions and transport facts.
-- No native wheel measurement or gameplay qualification is claimed.
local Fixtures=require("./ride_runtime_metrics_tests")
local Forces=require("./forces")
local M=require("./force_math")
local Stage=require("./force_stage")
local Support=require("./force_stage_support_fixture")
local Tests={}
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function fixture()
    local f=Fixtures.fixture();local sample=f.sample
    f.angle=0;f.previews={};f.commands={}
    function f.sample()
        local row=sample();row.velocity=vector.create(0,f.vertical_velocity or 0,2);return row
    end
    f.on_decode=function(row)
        for _,ray in ipairs(row.rays) do
            if ray.status=="hit" then ray.normal={math.sin(f.angle),math.cos(f.angle),0} end
        end
    end
    local preview,submit=f.force.preview,f.api.submit
    function f.force:preview(...)
        local args=table.pack(...)
        local model,candidate=preview(self,...)
        f.previews[#f.previews+1]={h=args[1],args=M.copy(args),wheels=M.copy(args[3]),model=M.copy(model),
            normal_valid=self.normals[1].valid==true,steering_valid=self.steering.valid==true}
        return model,candidate
    end
    function f.api.submit(epoch,command)
        local result=table.pack(submit(epoch,command))
        if result[1]==true then f.commands[#f.commands+1]=M.copy(command) end
        return table.unpack(result,1,result.n)
    end
    return f
end
local function fill(f)
    f.withhold_successors=true
    f.observe();f.advance();f.observe();f.advance();return f.observe()
end
local function release_head_only(f)
    local head=f.ride:status().pending_sequence
    local receipt=f.on_receipt
    f.on_receipt=function(sequence)
        local row=receipt(sequence)
        if sequence==head then row.successor=f.sample() end
        return row
    end
end
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(_,run) cases+=1;run() end
    case("capacity gap invalidates normal transport and steering chronology",function()
        local f=fixture();local full=fill(f)
        check(full.submitted==3 and f.force.normals[1].valid and f.force.steering.valid,
            "accepted flat support seeds the real normal and steering histories")
        local wheels=M.copy(f.previews[3].model.wheels)
        f.angle=.05;f.pad.left_x=.8;f.advance();local held=f.observe()
        check(held.submitted==3 and #f.previews==3 and held.backpressure=="receipt_capacity",
            "one measured capacity step is intentionally uncommanded")
        f.withhold_successors=false;f.angle=.1;f.advance();local resumed=f.observe()
        local last=f.previews[4]
        check(resumed.submitted==4 and last and last.model.valid,"fresh measured step resumes after exact ordered cleanup")
        check(M.length(last.model.desired_support_angular_velocity)==0,
            "skipped body step must not be treated as one-step-old normal transport")
        check(last.model.requested_front_steer_angle~=0 and last.model.front_steer_angle==last.model.requested_front_steer_angle,
            "steering restarts from the measured frame rather than one stale slew interval")
        check(not last.normal_valid and not last.steering_valid and last.h==Forces.native_seconds,
            "continuity is invalidated before preview without changing fixed h")
        check(wheels[1].angular_speed~=0 and wheels[2].angular_speed~=0 and equal(last.wheels,wheels),
            "virtual wheel spins coast unchanged over the uncommanded step")
        check(resumed.continuity.skipped_steps==1 and resumed.continuity.invalidations==1 and not resumed.continuity.pending
            and resumed.continuity.gap_wheels=="torque_free_coast" and resumed.continuity.native_wheel_state_known==false,
            "bounded continuity diagnostics distinguish the coast assumption from native wheel evidence")
    end)
    case("consecutive commands retain normal and steering continuity",function()
        local f=fixture();f.observe();f.angle=.1;f.pad.left_x=.8;f.advance()
        -- The first command is not visible at N+1: that measured interval has
        -- gravity only. A frozen zero velocity would make its later fold rise.
        f.vertical_velocity=-9.8*Forces.native_seconds;local s=f.observe()
        local row=f.previews[2]
        check(s.submitted==2 and row.model.valid and row.normal_valid and row.steering_valid,
            "consecutive actual admissions keep their one-step histories")
        check(M.length(row.model.desired_support_angular_velocity)>0,
            "the same tilted contact has real transport when no command step was skipped")
        check(math.abs(row.model.front_steer_angle-row.model.requested_front_steer_angle)>1e-6,
            "continuous steering retains its actual one-step slew limit")
        check(s.continuity.skipped_steps==0 and s.continuity.invalidations==0 and not s.continuity.pending,
            "ordinary receipt latency does not itself invalidate continuity")
    end)
    case("queued inbox gap is invalidated before the next preview",function()
        local f=fixture();local receipt=f.on_receipt;f.hold_inbox=true
        f.on_receipt=function(sequence)
            local row=receipt(sequence)
            if f.hold_inbox then
                row.outcome="queued";row.produced_serial="0";row.force_attempted=false;row.torque_attempted=false;row.successor=nil
            end
            return row
        end
        f.observe();f.advance();local held=f.observe()
        check(held.backpressure=="native_inbox_queued" and held.submitted==1 and #f.previews==1
            and held.continuity.pending and held.continuity.skipped_steps==1,"constructed queued boundary records one uncommanded body step")
        f.hold_inbox=false;f.advance();local resumed=f.observe()
        check(resumed.submitted==2 and resumed.acknowledged==1 and resumed.continuity.invalidations==1,
            "queued backpressure clears one-step history before fresh admission")
        check(not f.previews[2].normal_valid and f.previews[2].h==Forces.native_seconds,
            "queued gap neither reuses derivative history nor enlarges h")
    end)
    case("Core capacity refusals accumulate explicit coast steps",function()
        local f=fixture();f.on_submit=function() return false,"force_pipeline_full" end
        local a=f.observe();f.advance();local b=f.observe()
        check(a.submitted==0 and b.submitted==0 and not b.force_pending and #f.commands==0,
            "defensive local capacity refusal admits no native command")
        check(b.continuity.pending and b.continuity.skipped_steps==2 and b.continuity.invalidations==1,
            "each rejected measured packet is visible even when a prior gap was already invalidated")
        f.on_submit=nil;f.advance();local resumed=f.observe()
        check(resumed.submitted==1 and resumed.continuity.invalidations==2 and resumed.continuity.skipped_steps==2,
            "the next attempt invalidates the second discarded preview")
        check(equal(f.previews[3].wheels,Forces.proposed_wheels()) and not f.previews[3].normal_valid,
            "unaccepted previews never change virtual wheels or seed continuity")
    end)
    case("accepted hop high-water survives a gap while its receipt waits",function()
        local f=fixture();f.withhold_successors=true;f.observe()
        f.advance();f.vertical_velocity=-9.8*Forces.native_seconds;f.pad.buttons.right_stick=true;local hopped=f.observe()
        local hop_sequence=hopped.pending_commands[2].sequence
        check(f.commands[2].impulse_id==1 and f.force:consumed_hop_event_id()==1,
            "the actual force candidate has consumed the accepted hop before the gap")
        f.advance();f.observe();f.advance();local held=f.observe()
        check(held.submitted==3 and held.continuity.pending,"hop receipt remains inside the full pipeline")
        release_head_only(f);f.advance();local resumed=f.observe()
        check(resumed.acknowledged==1 and resumed.pending_sequence==hop_sequence
            and f.mapping:status().pending_hop.id==1,"only the older neutral command is ACKed; hop remains pending")
        check(resumed.submitted==4 and f.commands[4].impulse==nil and f.commands[4].impulse_id==nil
            and f.force:consumed_hop_event_id()==1,"continuity invalidation never replays the accepted unacknowledged hop")
        check(resumed.continuity.invalidations==1 and not resumed.continuity.pending,
            "hop preservation occurs through the actual gap invalidation path")
    end)
    case("kernel invalidation preserves tuning and consumed events only",function()
        local f=fixture();f.observe();f.advance();f.vertical_velocity=-9.8*Forces.native_seconds;f.pad.buttons.right_stick=true;f.observe()
        -- A hop clears normal history, and its age-one forecast is airborne.
        -- Once that impulse is visible, the later supplied grounded sample
        -- rebuilds history without changing the accepted hop high-water.
        f.advance();f.observe();f.advance();f.observe()
        local tuning=f.force.tuning;local before_tuning=M.copy(tuning)
        local args=f.previews[2].args
        -- Explicit synthetic stale pump/air state tests the seam's full contract.
        f.force.air.reserved=true;f.force.pump.direct_elapsed=.2;f.force.pump.automatic_remaining=.1
        check(f.force:consumed_hop_event_id()==1 and f.force.normals[1].valid and f.force.steering.valid,
            "actual accepted predictions seed the preserved event and discarded normal/steering state")
        local result=table.pack(f.force:invalidate_continuity())
        check(result.n==0 and f.force.tuning==tuning and equal(tuning,before_tuning)
            and f.force:consumed_hop_event_id()==1,"invalidation is exact void and preserves tuning identity plus accepted event")
        check(equal(f.force.normals,{{},{}}) and f.force.travel_direction==0
            and next(f.force.air)==nil and next(f.force.steering)==nil,"all one-step normal, direction, air and steering state is cleared")
        check(equal(f.force.pump,Forces.new().pump),"pump history is reset without resetting consumed hop identity")
        local model=f.force:preview(table.unpack(args,1,args.n))
        check(model.valid and not model.hop_applied,"the original accepted hop controls cannot emit another impulse after invalidation")
    end)
    for _,module in ipairs({Stage,Support}) do
        case("stage invalidation revokes an outstanding candidate token",function()
            local c=module.new();local body,wheels=Forces.proposed_body(),Forces.proposed_wheels()
            body.center_of_mass={0,.9,-.05}
            local samples={}
            for i=1,2 do
                samples[i]={contact={status="hit",point={0,0,i==1 and .525 or -.525},normal={0,1,0},
                    forward={0,0,1},surface_velocity={0,0,0}},separation=0,verified_plane=false,balance_normal_available=false}
            end
            local model,old=c:preview(Forces.native_seconds,body,wheels,samples,Forces.controls())
            check(model.valid,"real stage preview issues a live candidate")
            local tuning=c.tuning;local invalidated=table.pack(c:invalidate_continuity())
            check(invalidated.n==0 and c.tuning==tuning and not pcall(c._adopt,c,old),
                "invalidation revokes the stale stage token while preserving exposed tuning")
            local fresh,candidate=c:preview(Forces.native_seconds,body,wheels,samples,Forces.controls())
            check(fresh.valid and candidate~=old and pcall(c._adopt,c,candidate) and not pcall(c._adopt,c,candidate),
                "a fresh stage token remains single-use after invalidation")
        end)
    end
    case("support stage invalidates its private accepted kernel history",function()
        local changed,continuous=Support.new(),Support.new()
        local body,wheels=Forces.proposed_body(),Forces.proposed_wheels()
        body.center_of_mass={0,.9,-.05};body.linear_velocity={0,0,2}
        for _,wheel in ipairs(wheels) do wheel.angular_speed=2/wheel.radius end
        local samples={}
        for i=1,2 do
            samples[i]={contact={status="hit",point={0,0,i==1 and .525 or -.525},normal={0,1,0},
                forward={0,0,1},surface_velocity={0,0,0}},separation=0,verified_plane=false,balance_normal_available=false}
        end
        local seeded,a=changed:preview(Forces.native_seconds,body,wheels,samples,Forces.controls())
        local reference,b=continuous:preview(Forces.native_seconds,body,wheels,samples,Forces.controls())
        check(seeded.valid and reference.valid,"both actual support kernels admit the same flat-history seed")
        changed:_adopt(a);continuous:_adopt(b)
        local _,stale=changed:preview(Forces.native_seconds,body,seeded.wheels,samples,Forces.controls())
        local result=table.pack(changed:invalidate_continuity())
        check(result.n==0 and not pcall(changed._adopt,changed,stale),"private-kernel invalidation also revokes an outstanding wrapper token")
        for _,sample in ipairs(samples) do sample.contact.normal={math.sin(.1),math.cos(.1),0} end
        local fresh,token=changed:preview(Forces.native_seconds,body,seeded.wheels,samples,Forces.controls())
        local prior=continuous:preview(Forces.native_seconds,body,seeded.wheels,samples,Forces.controls())
        check(fresh.valid and prior.valid and M.length(fresh.desired_support_angular_velocity)==0
            and M.length(prior.desired_support_angular_velocity)>0,
            "wrapper invalidation clears accepted private history while the uninterrupted reference still transports it")
        check(pcall(changed._adopt,changed,token) and not pcall(changed._adopt,changed,token),
            "fresh support history still commits through one exact single-use token")
    end)
    for _,mode in ipairs({"missing","throw","nonvoid"}) do
        case("failed invalidation preserves known force debt "..mode,function()
            local f=fixture();fill(f);f.advance();f.observe();release_head_only(f)
            if mode=="missing" then f.force.invalidate_continuity=false
            elseif mode=="throw" then f.force.invalidate_continuity=function() error("constructed invalidation failure") end
            else f.force.invalidate_continuity=function() return true end end
            f.advance();local stopped=f.observe()
            check(stopped.stop_requested and stopped.unknown and stopped.issue=="force history continuity invalidation unavailable",
                "missing, throwing and non-void invalidation all stop before preview")
            check(stopped.submitted==3 and #f.previews==3 and stopped.pending_count==2
                and not stopped.pending_commands[1].unknown and not stopped.pending_commands[2].unknown,
                "known native receipt identities survive model-history uncertainty")
            f.withhold_successors=false;f.advance();local drained=f.ride:drain()
            check(drained.unknown and drained.acknowledged==3 and not drained.force_pending,
                "known receipts can drain without claiming the failed model history is resolved")
        end)
    end
    return {cases=cases,assertions=assertions,native_actions=0}
end
return table.freeze(Tests)

-- Actual Ride, Mapping, Contact, Hop ForceStage and kernel in a constructed
-- N+2 world. These are offline model checks, not game or Follow qualification.
-- hop_offline_fixture needs force_stage_hop_fixture in the runner's qualified copy.
local World=require("./hop_offline_fixture")
local M=require("./force_math")
local Pose=require("./mounted_pose")
local Zero=require("./force_stage")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local results={}
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn) cases+=1;fn();return name end
    local function run(world,steps,schedule)
        local ok,why=world:run(steps,schedule)
        check(ok,"actual force path stopped: "..tostring(why))
    end
    local function complete(world,expected)
        check(world.status.unknown~=true and world.status.stop_requested~=true,"the modeled ride reaches its intended stop without uncertainty")
        local closure=world:close()
        local result=world:summary()
        check(world.body.mass==106,"the authored hop body is exactly 106 kg")
        check(result.impulses==expected,"exactly one accepted packet per requested grounded hop")
        check(result.refusals==0,"the whole hop passes ForceStage without a refused preview")
        check(result.peak_force<6000 and result.peak_torque<=2000,"uncropped submitted forces and torques stay below authored caps")
        check(result.peak_horizontal<=3 and result.peak_vertical<=6,"horizontal and vertical speed bounds are distinct")
        check(result.airborne_steps>20 and result.peak_height>.65,"the full hop has a substantial airborne arc")
        check(result.min_clearance>=-.016,"landing respects the 15 mm compliance backstop without a world floor clamp")
        check(math.abs(closure.before_stop.clearance)<.02 and math.abs(closure.before_stop.vertical_speed)<.15,
            "the world settles back onto the measured floor before the deliberate stop")
        check(math.abs(result.final_clearance)<.02 and math.abs(result.final_vertical)<.15+9.8*World.native_seconds*world.successor_delay,
            "the measured terminal body stays within the bounded post-stop gravity coast")
        check(result.final_tilt<10,"the bike finishes within ten degrees of level")
        check(result.pose_checks==#world.rows*2 and result.max_root_distance<=Pose.SENT_JOINT_LIMIT,
            "every body sample and both posture endpoints have reachable actual IK limbs")
        check(result.max_follow_lag>.05,"rider reach includes a real two-step moving target lag")
        check(world.status.stop_requested and not world.status.unknown and not world.status.force_pending
            and world.status.pending_count==0 and #world.ring==0,"the stopped constructed transport has no unresolved receipt")
        check(world.status.submitted==world.status.acknowledged and world.status.submitted==closure.submitted_before,
            "draining ACKs every exact accepted command without another submit")
        local stop_count=0
        for reason,count in pairs(world.status.metrics.stop_counts) do
            check(reason=="offline fixture complete" and count==1,"no receipt-drain refusal is hidden behind the intentional stop")
            stop_count+=count
        end
        check(stop_count==1 and world.status.metrics.stop_counts_overflow==0,"the deliberate stop is the only stop request")
        check(result.final_measured_tick==world.tick and result.terminal_tick==world.tick
            and closure.final_measurement.body.center_of_mass[2]==world.body.center_of_mass[2],
            "terminal metrics and rider IK include the final integrated body")
        for id,event in pairs(world.impulses) do
            check(math.abs(event.impulse[1])<1e-5 and math.abs(event.impulse[2]-477)<1e-4 and math.abs(event.impulse[3])<1e-5,
                "each full hop sends the literal upward impulse {0,477,0} N s for 4.5 m/s")
            check(event.speed>=1.95 and event.speed<=2.05,"the actual measured body is rolling at 2 m/s when it hops")
            check(world.applied_impulses[id]==true,"each accepted hop was consumed by the independent world")
            check(event.preview.contact_scale==1,"a full hop is never qualified by kernel budget scaling")
        end
        return result
    end
    case("shipped stage remains closed",function()
        check(Zero.new().hop_policy=="suppress","the ordinary tracked module still suppresses hop")
    end)
    case("full rolling hop and held button",function()
        local world=World.new()
        run(world,180,function(w) return {hop=w.tick>=24 and w.tick<34} end)
        results.full=complete(world,1)
        check(world.impulses[1]~=nil,"fresh input on takeoff preserves the accepted event identity")
        check(world.f.mapping:status().pending_hop==nil,"receipt ACK retires the hop after its measured successor")
        check(world.status.metrics.fresh_report_steps==world.status.model_steps,"every modeled step receives a fresh report, including takeoff")
    end)
    case("another grounded hop after landing",function()
        local world=World.new()
        run(world,300,function(w) return {hop=w.tick==24 or w.tick==164} end)
        results.repeat_hop=complete(world,2)
        check(world.impulses[1]~=nil and world.impulses[2]~=nil,"the second grounded press receives its own monotonic event ID")
    end)
    case("successor delayed one extra sample",function()
        local world=World.new({successor_delay=1})
        run(world,180,function(w) return {hop=w.tick>=24 and w.tick<34} end)
        results.delayed_receipt=complete(world,1)
        check(world.status.metrics.max_inflight==3,"the late receipt exercises all three bounded Ride slots")
        check(world.status.backpressure_steps==0,"an extra successor sample does not invent a missed command")
    end)
    case("a press in the air does not defer a hop until landing",function()
        local world=World.new()
        local extra=false
        run(world,180,function(w,row)
            if w.tick==24 then return {hop=true} end
            if not extra and w.tick>40 and row.airborne and row.height>.35 then extra=true;return {hop=true} end
            return {hop=false}
        end)
        results.air_press=complete(world,1)
        check(extra,"the second physical press was made in the observed airborne interval")
        check(world.f.mapping:status().pending_hop==nil,"an airborne press cannot retain an expiring deferred event")
    end)
    case("clear rays never invent a landing plane",function()
        local world=World.new({height=2,no_plane=true})
        run(world,20,function(w) return {hop=w.tick==3} end)
        check(world:impulse_count()==0 and world.clear_ray_steps==20,"no current floor hit can authorize a grounded hop")
        check(world.peak_force<1e-6,"approach and compliance produce no lift without a current hit")
        check(world.body.linear_velocity[2]<-3,"the independent world falls freely without clamping it to terrain")
        world:close()
    end)
    case("a too-late high-energy landing is refused without a packet",function()
        local world=World.new({height=.12,vertical_speed=-5})
        local state=world:observe()
        local preview=world.previews[1] and world.previews[1].model
        check(state.stop_requested and preview and preview.valid==false,"a contact too late for the available force budget is refused")
        check(preview.issue=="authored_force_limit" or preview.issue=="authored_torque_limit" or preview.issue=="kernel_clamped",
            "high landing energy is attributed to a force budget, not hidden by body repair: "..tostring(preview.issue))
        check(world.commands[0]==nil and world.peak_force==0,"the refusal sends no cropped packet")
    end)
    case("rider placement distance has a negative control",function()
        local world=World.new()
        local b=world.body
        local root=M.add(World.root(b),{4.5,0,0})
        local plan=Pose.compose({bike={center_of_mass=b.center_of_mass,rotation=b.orientation},
            articulation={crank_phase=0,steer=0},skater_root=root})
        check(plan==nil,"the real poser rejects a skater root beyond its four-metre placement limit")
    end)
    local full=results.full
    local max_follow_lag=0
    for _,result in pairs(results) do max_follow_lag=math.max(max_follow_lag,result.max_follow_lag) end
    return {cases=cases,assertions=assertions,native_actions=0,metrics=results,
        full_peak_force_N=full.peak_force,full_peak_torque_Nm=full.peak_torque,
        full_hop_height_m=full.peak_height,full_min_clearance_m=full.min_clearance,
        full_final_tilt_deg=full.final_tilt,max_follow_lag_m=max_follow_lag,
        full_pose_checks=full.pose_checks,full_final_pending_count=full.final_pending_count,
        full_final_force_pending=full.final_force_pending,full_final_unknown=full.final_unknown,
        full_drained_receipts=full.drained_receipts,full_drain_steps=full.drain_steps}
end
return table.freeze(Tests)

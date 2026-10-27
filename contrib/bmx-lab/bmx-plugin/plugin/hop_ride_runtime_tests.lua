-- Actual Mapping -> Ride -> combined ForceStage, with constructed samples and
-- exact queued/applied/successor receipts. This is not an integrated native
-- trajectory, a landing-quality verdict or a game qualification result.
local Combined=require("./force_stage_hop_ride_fixture")
local Fixtures=require("./ride_runtime_tests")
local Forces=require("./forces")
local Identity=require("./lease_identity")
local M=require("./force_math")
local Tests={}
local h=Forces.native_seconds
local function fixture()
    local stage=Combined.new()
    local f
    local proxy={hop_policy=stage.hop_policy,tuning=stage.tuning}
    function proxy:admit_measured(body)
        f.measured[#f.measured+1]=M.copy(body)
        return stage:admit_measured(body)
    end
    function proxy:preview(seconds,body,wheels,samples,controls)
        local model,candidate=stage:preview(seconds,body,wheels,samples,controls)
        f.previews[#f.previews+1]={args=M.copy({seconds,body,wheels,samples,controls}),model=M.copy(model)}
        return model,candidate
    end
    function proxy:_adopt(candidate) stage:_adopt(candidate);f.adoptions+=1 end
    function proxy:invalidate_continuity() stage:invalidate_continuity() end
    function proxy:reset() stage:reset() end
    f=Fixtures.fixture({models={force=proxy,tricks=false}})
    f.stage=stage;f.measured={};f.previews={};f.adoptions=0;f.claims=0
    f.accepted_impulses={};f.acks={};f.observations={};f.allow_successors=false
    f.velocity=vector.create(0,0,0);f.gap=0
    local sample=f.sample
    function f.sample() local row=sample();row.velocity=f.velocity;return row end
    function f.on_decode(out)
        for _,ray in ipairs(out.rays) do
            if ray.status=="hit" then ray.position[2]-=f.gap end
        end
    end
    local observe,claim=f.mapping.observe,f.mapping.claim_hop
    function f.mapping:observe(frame,context)
        local row=observe(self,frame,context)
        f.observations[#f.observations+1]=row
        return row
    end
    function f.mapping:claim_hop(id) f.claims+=1;return claim(self,id) end
    local submit,receipt,acknowledge=f.api.submit,f.api.receipt,f.api.acknowledge
    function f.api.submit(epoch,command)
        local result=table.pack(submit(epoch,command))
        if result[1] and command.impulse then
            f.accepted_impulses[#f.accepted_impulses+1]={sequence=result[3],command=command}
        end
        -- Preserve both the accepted triple and known-refusal pair exactly.
        return table.unpack(result,1,result.n)
    end
    function f.api.receipt(sequence)
        local record=f.transactions[sequence]
        local age=record and Identity.bounded_delta(f.serial,record.requested,64)
        assert(age~=nil,"receipt must refer to a retained exact command")
        f.mode=age>=1 and "applied" or "queued"
        -- A produced N+1 body is never a successor, even with one pending row.
        f.successor=f.allow_successors and age>=2 and f.sample() or nil
        return receipt(sequence)
    end
    function f.api.acknowledge(sequence)
        f.acks[#f.acks+1]=sequence
        return acknowledge(sequence)
    end
    return f
end
local function press(f,steer)
    f.advance();f.velocity=vector.create(0,-9.8*h,.5)
    f.pad.left_x=steer;f.pad.buttons.b=true;f.pad.buttons.right_stick=true
    return f.observe()
end
function Tests.run()
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    local function case() cases+=1 end
    for _,steer in ipairs({-.3,.3}) do case() do
        local f=fixture();local first=f.observe();local first_sequence=first.pending_sequence
        local accepted=press(f,steer);local hop_sequence=f.sequence
        local original=f.mapping:status().pending_hop
        local preview=f.previews[#f.previews]
        check(not accepted.stop_requested and accepted.submitted==2 and f.claims==1 and original.id==1,
            "one real grounded input edge admits a steered/braked hop with exact receipt ownership")
        check(preview.args[5].steer*steer>0 and preview.args[5].brake==1
            and preview.model.front_steer_angle*steer<0 and preview.model.hop_applied,
            "the same Mapping-to-force preview contains steering, braking and the hop")
        check(#f.accepted_impulses==1 and f.accepted_impulses[1].sequence==hop_sequence
            and f.accepted_impulses[1].command.impulse_id==original.id,
            "the combined packet carries its original exact impulse ID once")
        f.advance();f.velocity=vector.create(0,0,.5);f.pad.buttons.right_stick=false
        local released=f.observe()
        check(not released.stop_requested,"releasing R3 does not stop ongoing steered/braked riding")
        f.advance();f.pad.buttons.right_stick=true
        local second=f.observe();local mapped=f.observations[#f.observations]
        check(mapped.valid and mapped.issue=="hop_press_suppressed" and not mapped.actions.hop_pressed,
            "a second press with the first receipt pending is suppressed in the actual Mapper")
        check(not second.stop_requested and not second.unknown and f.claims==1 and #f.accepted_impulses==1
            and f.transactions[hop_sequence]~=nil and f.mapping:status().pending_hop.id==original.id,
            "combined steering/braking cannot replace the accepted hop or stop the ride on a second press")
        check(second.backpressure=="receipt_capacity" and second.pending_count==3,
            "the suppressed edge remains valid while three exact commands wait for their successors")
        f.allow_successors=true;f.advance();local resumed=f.observe()
        check(not resumed.stop_requested and f.mapping:status().pending_hop==nil
            and f.mapping:status().last_retired.disposition=="accepted"
            and f.acks[1]==first_sequence and f.acks[2]==hop_sequence,
            "the original hop retires only through its ordered exact successor receipt")
        for _=1,3 do f.advance();resumed=f.observe() end
        check(not resumed.stop_requested and #f.accepted_impulses==1 and f.claims==1
            and f.mapping:status().hop_counter==original.id,"holding the dropped second edge after ACK cannot replay the impulse")
        local adoptions=f.adoptions;local submitted=resumed.submitted
        f.ride:stop("combined fixture complete");f.advance(2)
        local drained=f.ride:drain()
        check(not drained.force_pending and not drained.unknown and drained.acknowledged==submitted
            and f.adoptions==adoptions,"combined driving drains its exact tail without adopting or submitting again")
    end end
    case() do
        local f=fixture();local first=f.observe();local original_sequence=first.pending_sequence
        f.on_submit=function() return false,"busy" end
        local stopped=press(f,.3);local rejected=f.previews[#f.previews]
        check(stopped.stop_requested and not stopped.unknown and stopped.submitted==1 and stopped.pending_count==1
            and stopped.pending_sequence==original_sequence,"known rejection retains only the previously accepted command")
        check(rejected.model.valid and rejected.model.hop_applied and f.command.impulse_id==1
            and f.adoptions==1 and f.claims==0 and #f.accepted_impulses==0,
            "a rejected steered/braked hop never adopts force history or claims receipt ownership")
        local mapping=f.mapping:status()
        check(stopped.model_history.sequence==original_sequence and mapping.pending_hop==nil
            and mapping.last_retired.event.id==1 and mapping.last_retired.disposition=="cancelled",
            "rejection keeps accepted history and cancels the unaccepted local event without a force claim")
        local again=f.stage:preview(table.unpack(rejected.args))
        check(again.valid and again.hop_applied and again.hop_event_id==1,
            "the unaccepted hop ID remains unconsumed in the actual combined force kernel")
        f.allow_successors=true;f.advance()
        local drained=f.ride:drain()
        check(not drained.force_pending and drained.acknowledged==1 and f.acks[1]==original_sequence
            and f.adoptions==1 and f.claims==0,"known rejection still drains older debt without adopting the rejected preview")
    end
    for _,spec in ipairs({{velocity=vector.create(0,0,3.001),issue="authored_speed_limit"},
        {velocity=vector.create(0,6.001,0),issue="authored_vertical_speed_limit"},
        {velocity=vector.create(0,-6.001,0),issue="authored_vertical_speed_limit"}}) do case() do
        local f=fixture();local first=f.observe();local sequence=first.pending_sequence
        f.advance();f.velocity=spec.velocity;f.pad.left_x=.3;f.pad.buttons.b=true;f.pad.buttons.right_stick=true
        local stopped=f.observe()
        check(stopped.stop_requested and stopped.issue=="measured body refused: "..spec.issue
            and #f.measured==2 and #f.previews==1,"combined input cannot hide measured horizontal or vertical excess behind a forecast")
        check(stopped.submitted==1 and stopped.pending_sequence==sequence and f.adoptions==1 and f.claims==0,
            "the measured cap refuses before claiming a hop or changing accepted force history")
        f.allow_successors=true;f.advance();local drained=f.ride:drain()
        check(not drained.force_pending and drained.acknowledged==1 and f.acks[1]==sequence,
            "measured overspeed cannot prevent cleanup of the older exact receipt")
    end end
    case() do
        local f=fixture();f.observe();local accepted=press(f,.3);local hop_sequence=f.sequence
        check(not accepted.stop_requested and f.claims==1,"predictive-cap fixture begins with an accepted combined hop")
        -- Constructed sample still admits 2 m/s vertical motion. The pending
        -- accepted 4.5 m/s impulse has not yet appeared in that sample.
        f.advance();f.velocity=vector.create(0,2,.5);f.pad.buttons.right_stick=false
        local stopped=f.observe();local preview=f.previews[#f.previews]
        check(f.measured[#f.measured].linear_velocity[2]<6 and preview.args[2].linear_velocity[2]>6
            and preview.model.issue=="authored_vertical_speed_limit",
            "an accepted hop's forecast is independently checked against the six-metre vertical cap")
        check(stopped.stop_requested and stopped.submitted==2 and f.adoptions==2 and f.claims==1
            and f.transactions[hop_sequence]~=nil,"forecast refusal preserves the accepted hop receipt and history")
        f.allow_successors=true;f.advance();local drained=f.ride:drain()
        check(not drained.force_pending and not drained.unknown and drained.acknowledged==2
            and f.mapping:status().last_retired.disposition=="accepted","predictive refusal drains the original hop without replay")
    end
    for _,steer in ipairs({-.3,.3}) do case() do
        local f=fixture();f.gap=.3;f.velocity=vector.create(0,-3,.5)
        local approach=f.observe()
        check(not approach.stop_requested,"current measured approach begins inside the combined landing budget")
        f.advance();f.pad.left_x=steer;f.pad.buttons.b=true
        local out=f.observe();local preview=f.previews[#f.previews]
        check(not out.stop_requested and preview.args[5].steer*steer>0 and preview.args[5].brake==1,
            "real Mapping keeps steering/braking on the descending approach")
        check(preview.model.landing_approach_mask==3 and not preview.model.grounded
            and preview.model.normal_load[1]==0 and preview.model.normal_load[2]==0 and f.command.impulse==nil,
            "the combined runtime retains normal-only landing braking without inventing tire support or a hop")
        f.allow_successors=true;f.ride:stop("approach fixture complete");f.advance(2)
        local drained=f.ride:drain()
        check(not drained.force_pending and not drained.unknown and drained.acknowledged==out.submitted,
            "steered/braked approach commands retain ordinary exact cleanup ownership")
    end end
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)

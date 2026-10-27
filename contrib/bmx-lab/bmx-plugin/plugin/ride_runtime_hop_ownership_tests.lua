-- Constructed exact SDK receipts around the real Mapping and force kernel.
-- This isolates pure claim failures from unknown native admission outcomes.
local Fixtures=require("./ride_runtime_tests")
local Forces=require("./forces")
local Tests={}
local function fixture(fault)
    local force=Forces.new()
    force.hop_policy="grounded_once"
    local f=Fixtures.fixture({models={force=force}})
    f.force=force
    f.claims,f.submits,f.read_ids,f.ack_ids=0,0,{},{}
    local sample=f.sample
    function f.sample()
        local row=sample()
        row.velocity=vector.create(0,f.vertical_velocity or 0,0)
        return row
    end
    local claim=f.mapping.claim_hop
    function f.mapping:claim_hop(id)
        f.claims+=1
        if fault=="refuse" then return false,"constructed claim refusal" end
        if fault=="throw_before_claim" then error("constructed claim exception") end
        local accepted,why=claim(self,id)
        if fault=="throw_after_claim" then error("constructed exception after claim") end
        return accepted,why
    end
    local submit,receipt,acknowledge=f.api.submit,f.api.receipt,f.api.acknowledge
    function f.api.submit(epoch,command)
        f.submits+=1
        local accepted,why,sequence=submit(epoch,command)
        if command.impulse~=nil and fault=="stop_in_submit" then
            f.ride:stop("constructed stop inside accepted hop submit")
        end
        return accepted,why,sequence
    end
    function f.api.receipt(sequence)
        f.read_ids[#f.read_ids+1]=sequence
        return receipt(sequence)
    end
    function f.api.acknowledge(sequence)
        f.ack_ids[#f.ack_ids+1]=sequence
        return acknowledge(sequence)
    end
    return f
end
function Tests.run()
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    for _,fault in ipairs({"refuse","throw_before_claim","throw_after_claim","stop_in_submit"})do
        cases+=1
        local f=fixture(fault)
        local initial=f.observe()
        local first_sequence=initial.pending_sequence
        check(initial.submitted==1 and not initial.stop_requested and f.claims==0,"neutral admission never claims a hop")
        -- At N+1 the accepted force is not visible. The measured velocity is
        -- gravity-only, so the forecast recovers supported rest for this hop.
        f.advance();f.vertical_velocity=-9.8*f.read.seconds
        f.mode="applied";f.pad.buttons.right_stick=true
        local stopped=f.observe()
        local hop_sequence=f.sequence
        check(f.command.impulse~=nil and f.command.impulse_id==1 and f.claims==1,"exact accepted hop invokes one claim")
        check(stopped.stop_requested and stopped.unknown and stopped.submitted==2 and stopped.pending_count==2,
            "claim uncertainty stops driving while retaining both accepted commands: "..fault)
        check(stopped.pending_commands[1].sequence==first_sequence and stopped.pending_commands[2].sequence==hop_sequence,
            "pure claim failure cannot discard or replace either exact sequence")
        check(not stopped.pending_commands[2].unknown,"pure claim uncertainty does not quarantine known native receipt")
        check(f.force:consumed_hop_event_id()==1 and stopped.model_history.sequence==hop_sequence,
            "exact accepted hop keeps its adopted prediction history despite claim failure")
        check(f.mapping:status().pending_hop.id==1,"pending hop remains available for receipt retirement")
        local before_reads=#f.read_ids
        f.advance(2);f.successor=f.sample()
        local drained=f.ride:drain()
        check(#f.read_ids==before_reads+2 and f.read_ids[before_reads+1]==first_sequence
            and f.read_ids[before_reads+2]==hop_sequence,"cleanup polls both original accepted sequences after stop")
        check(#f.ack_ids==2 and f.ack_ids[1]==first_sequence and f.ack_ids[2]==hop_sequence,
            "cleanup acknowledges the exact ready receipt prefix in order")
        check(drained.stop_requested and drained.unknown and not drained.force_pending and drained.acknowledged==2,
            "transport drains while pure ownership uncertainty stays latched")
        local mapping=f.mapping:status()
        check(mapping.pending_hop==nil and mapping.last_retired.event.id==1
            and mapping.last_retired.disposition=="accepted","accepted receipt retires the hop once even if claim failed")
        f.ride:drain();f.observe()
        check(f.submits==2 and #f.ack_ids==2 and f.claims==1,"stopped cleanup cannot replay submit, claim or acknowledgement")
    end
    return {cases=cases,assertions=assertions,native_actions=0}
end
return table.freeze(Tests)

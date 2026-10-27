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
    f.impulse_packets,f.map_observations,f.retirements={},{},{}
    local observe,retire=f.mapping.observe,f.mapping.retire_hop
    function f.mapping:observe(frame,context)
        local result=observe(self,frame,context)
        f.map_observations[#f.map_observations+1]={grounded=context.grounded,observation=result}
        return result
    end
    function f.mapping:retire_hop(id,disposition)
        f.retirements[#f.retirements+1]={id=id,disposition=disposition}
        return retire(self,id,disposition)
    end
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
        if accepted and command.impulse~=nil then
            f.impulse_packets[#f.impulse_packets+1]={sequence=sequence,command=command}
        end
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
    for _,ack_timing in ipairs({"delayed","same_update"})do
        cases+=1
        local f=fixture()
        f.observe()
        f.advance();f.vertical_velocity=-9.8*f.read.seconds
        f.mode="applied";f.pad.buttons.right_stick=true
        local accepted=f.observe()
        local hop_sequence=f.sequence
        local original=f.mapping:status().pending_hop
        local packet=f.impulse_packets[1]
        check(not accepted.stop_requested and original and original.id==1 and f.claims==1
            and packet and packet.sequence==hop_sequence,"first grounded hop has one exact accepted receipt owner")
        f.advance();f.pad.buttons.right_stick=false;f.observe()
        f.advance();f.pad.buttons.right_stick=true
        if ack_timing=="same_update" then f.successor=f.sample() end
        local pressed=f.observe()
        local mapped=f.map_observations[#f.map_observations]
        check(mapped.grounded and mapped.observation.valid and mapped.observation.issue=="hop_press_suppressed"
            and not mapped.observation.actions.hop_pressed and mapped.observation.actions.hop_strength==0,
            "a new grounded press is consumed before "..ack_timing.." receipt polling")
        check(not pressed.stop_requested and not pressed.unknown and f.claims==1 and #f.impulse_packets==1,
            "a second press cannot end Ride or submit a second impulse while the old receipt is pending")
        check(f.force:consumed_hop_event_id()==original.id and f.mapping:status().hop_counter==original.id,
            "accepted model debt and lifetime event counter still describe only the first hop")
        check(packet.sequence==hop_sequence and packet.command.impulse_id==original.id
            and f.impulse_packets[1].command==packet.command,
            "new input cannot replace the original accepted impulse packet")
        if ack_timing=="delayed" then
            local pending=f.mapping:status().pending_hop
            local retained=false
            for _,command in ipairs(pressed.pending_commands)do
                if command.sequence==hop_sequence then retained=true end
            end
            check(retained and pending.id==original.id and pending.strength==original.strength
                and pending.observation_serial==original.observation_serial and pending.observed_ms==original.observed_ms,
                "delayed ACK preserves both the exact native sequence and the original event provenance")
            check(#f.retirements==0 and f.transactions[hop_sequence]~=nil,
                "dropping the second press cannot erase native debt or retire the accepted hop")
            f.advance();f.successor=f.sample();pressed=f.observe()
        end
        local state=f.mapping:status()
        check(not pressed.stop_requested and state.pending_hop==nil and state.last_retired.event.id==original.id
            and state.last_retired.disposition=="accepted" and f.transactions[hop_sequence]==nil,
            "the original ready receipt is acknowledged and retired as accepted")
        check(#f.retirements==1 and f.retirements[1].id==original.id and f.retirements[1].disposition=="accepted",
            "suppressed press never retires the accepted event as suppressed")
        for _=1,3 do
            f.advance();f.successor=f.sample();local held=f.observe()
            check(not held.stop_requested and f.mapping:status().pending_hop==nil and #f.impulse_packets==1,
                "holding the second press through and after ACK cannot replay its impulse")
        end
        check(f.mapping:status().hop_counter==original.id and f.claims==1,
            "held input cannot claim a new command or consume an event ID")
        f.advance();f.pad.buttons.right_stick=false;f.successor=f.sample();f.observe()
        f.advance();f.pad.buttons.right_stick=true;f.successor=f.sample();local fresh=f.observe()
        check(not fresh.stop_requested and f.mapping:status().hop_counter==original.id+1,
            "only a fresh release and press after ACK may create the next lifetime ID")
    end
    for _,outcome in ipairs({"rejected","partial"})do
        cases+=1
        local f=fixture()
        f.observe()
        f.advance();f.vertical_velocity=-9.8*f.read.seconds
        f.mode="applied";f.pad.buttons.right_stick=true;local accepted=f.observe()
        local hop_sequence=f.sequence
        local original=f.mapping:status().pending_hop
        check(not accepted.stop_requested and original and original.id==1 and f.claims==1 and #f.impulse_packets==1,
            "terminal outcome fixture begins with one accepted impulse")
        local receipt=f.api.receipt
        local terminal=false
        function f.api.receipt(sequence)
            local row=receipt(sequence)
            if sequence==hop_sequence then
                -- Keep the accepted command queued until its terminal receipt;
                -- an applied command cannot later become rejected.
                row.outcome=terminal and outcome or "queued";row.successor=nil
                row.force_attempted=terminal and outcome=="partial";row.torque_attempted=false
                if not terminal or outcome=="rejected" then row.produced_serial="0" end
            end
            return row
        end
        f.advance();f.pad.buttons.right_stick=false;local queued=f.observe()
        check(not queued.stop_requested and queued.backpressure=="native_inbox_queued"
            and f.mapping:status().pending_hop.id==original.id and f.transactions[hop_sequence]~=nil,
            "release advances input while the accepted hop remains queued with its exact native debt")
        terminal=true
        f.advance();f.pad.buttons.right_stick=true;f.successor=f.sample()
        local stopped=f.observe()
        local mapped=f.map_observations[#f.map_observations]
        local state=f.mapping:status()
        local disposition=outcome=="partial" and "uncertain" or "cancelled"
        check(mapped.grounded and mapped.observation.issue=="hop_press_suppressed" and mapped.observation.valid,
            "terminal receipt fixture first drops the new grounded edge without a mapping refusal")
        check(stopped.stop_requested and stopped.issue=="force command "..outcome,
            "new input never conceals the original native failure: "..outcome)
        check(state.pending_hop==nil and state.last_retired.event.id==original.id
            and state.last_retired.disposition==disposition and state.hop_counter==original.id,
            "the original event retains the exact failed receipt disposition")
        check(#f.retirements==1 and f.retirements[1].id==original.id
            and f.retirements[1].disposition==disposition and #f.impulse_packets==1 and f.claims==1,
            "failed receipt remains one impulse and one retirement with no suppressed substitute")
        if outcome=="partial" then
            check(stopped.unknown and state.uncertain and state.uncertain.id==original.id,
                "partially applied impulse keeps its original uncertainty")
        else check(not state.uncertain,"rejected impulse keeps cancellation distinct from uncertainty") end
        local submits=f.submits
        f.advance();f.observe()
        check(f.submits==submits and #f.impulse_packets==1 and f.mapping:status().hop_counter==original.id,
            "stopped Ride cannot replay the held second press after a failed receipt")
    end
    return {cases=cases,assertions=assertions,native_actions=0}
end
return table.freeze(Tests)

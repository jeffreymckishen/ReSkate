-- Constructed transport boundaries around the actual Ride/Mapping/Forces path.
-- The qualified module is the existing test-only literal projection; public Ride stays inert.
local Fixtures=require("./ride_runtime_tests")
local Tests={}
local function copy(value)
    if type(value)~="table" then return value end
    local out={} for key,child in pairs(value) do out[key]=copy(child) end return out
end
local function count(f,name)
    local n=0 for _,call in ipairs(f.calls) do if call==name then n+=1 end end return n
end
local function parked(f)
    return {sequence=f.sequence,requested_serial=f.requested,produced_serial=f.produced,
        outcome="applied",force_attempted=true,torque_attempted=true,retained=true,quarantined=false,
        cleanup_disposition="parked_without_successor"}
end
local function watch_wheels(f)
    local previews={}
    local original=f.force.preview
    function f.force:preview(h,body,wheels,samples,controls,speculative)
        local model,candidate=original(self,h,body,wheels,samples,controls,speculative)
        previews[#previews+1]={before=copy(wheels),after=copy(model.wheels),raw=model}
        return model,candidate
    end
    return previews
end
function Tests.run(case_done)
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    local function next_case()
        if case_done and cases>0 then case_done(cases,assertions) end
        cases+=1
    end
    next_case() do
        local f=Fixtures.fixture();f.observe()
        local before=f.ride:status()
        f.on_receipt=function() return parked(f) end
        local s=f.ride:drain();f.ride:drain();f.advance();f.observe()
        check(s.stop_requested and not s.force_pending and not s.unknown and s.issue=="force body parked without successor",
            "exact park disposition closes transport with its specific stop cause")
        check(s.acknowledged==1 and count(f,"ack")==1,"exact original command acknowledged once")
        check(s.receipt.cleanup_disposition=="parked_without_successor" and not s.receipt.successor_available,"park marker remains distinct from successor")
        check(s.model_steps==before.model_steps and #f.tricks.observed==1 and count(f,"submit")==1,"cleanup invents no model step or new command")
        check(f.force:consumed_hop_event_id()==0 and not s.model_history.native_wheel_state_known,"cleanup does not adopt preview or claim native wheel state")
    end
    next_case() do
        local f=Fixtures.fixture();f.observe();f.mode="applied";f.retained=true
        local s=f.ride:drain();f.ride:stop("outer Follow terminal");s=f.ride:drain()
        check(s.force_pending and not s.unknown and count(f,"ack")==0,"ordinary applied without successor still waits")
        check(s.receipt.cleanup_disposition=="none","outer stop cannot manufacture park disposition")
    end
    local malformed={
        {"missing",function(row) row.cleanup_disposition=nil end},
        {"unknown",function(row) row.cleanup_disposition="retired" end},
        {"wrong type",function(row) row.cleanup_disposition=false end},
        {"queued",function(row) row.outcome="queued" end},
        {"rejected",function(row) row.outcome="rejected" end},
        {"expired",function(row) row.outcome="expired" end},
        {"partial",function(row) row.outcome="partial" end},
        {"successor",function(row,f) row.successor=f.sample() end},
        {"not retained",function(row) row.retained=false end},
        {"quarantined",function(row) row.quarantined=true end},
        {"force missing",function(row) row.force_attempted=false end},
        {"torque missing",function(row) row.torque_attempted=false end},
        {"wrong produced",function(row) row.produced_serial=row.requested_serial end},
        {"wrong requested",function(row) row.requested_serial="1" end},
        {"wrong sequence",function(row) row.sequence="1" end},
    }
    for _,variant in ipairs(malformed) do next_case() do
        local f=Fixtures.fixture();f.observe()
        f.on_receipt=function() local row=parked(f);variant[2](row,f);return row end
        local s=f.ride:drain();f.ride:drain()
        check(s.unknown and s.force_pending and s.stop_requested,variant[1].." park receipt retains unknown duty")
        check(count(f,"ack")==0 and count(f,"receipt")==1,variant[1].." cannot ACK or replay unknown receipt")
    end end
    local ack_failures={
        {"false with reason",function() return false,"not acknowledged" end},
        {"nil",function() return nil end},
        {"extra value",function() return true,"unexpected" end},
        {"throw",function() error("ACK outcome unknown",0) end},
    }
    for _,variant in ipairs(ack_failures) do next_case() do
        local f=Fixtures.fixture();f.observe()
        f.on_receipt=function() return parked(f) end
        f.on_ack=variant[2]
        local s=f.ride:drain();f.ride:drain()
        check(s.unknown and s.force_pending and s.ack_attempted and s.acknowledged==0,variant[1].." ACK preserves duty")
        check(count(f,"ack")==1,variant[1].." ACK is never retried")
    end end
    next_case() do
        local f=Fixtures.fixture();f.observe();f.advance();f.observe()
        f.advance();f.pad.buttons.right_stick=true;f.mode="applied";f.successor=f.sample()
        local s=f.observe()
        check(s.submitted==2 and f.command.impulse_id==1,"actual mapper/kernel stages one R3 hop on second command")
        f.advance();f.on_receipt=function() return parked(f) end
        s=f.ride:drain()
        local mapping=f.mapping:status()
        check(not s.force_pending and s.acknowledged==2 and s.hop_disposition.id==1
            and s.hop_disposition.disposition=="uncertain","park ACK retires bookkeeping without accepting hop outcome")
        check(mapping.uncertain and mapping.pending_hop==nil,"uncertain hop remains diagnostic and cannot replay")
        check(f.force:consumed_hop_event_id()==1,"park ACK never rewinds previously accepted predictive hop history")
    end
    next_case() do
        local f=Fixtures.fixture();f.observe();f.advance();f.observe();f.advance()
        f.mode="applied";f.successor=f.sample()
        f.on_ack=function() f.ride:stop("stopped inside exact ACK");return true end
        local s=f.observe()
        check(s.stop_requested and not s.force_pending and s.acknowledged==1,"positive transport ACK survives stop callback")
        check(count(f,"submit")==1 and count(f,"ack")==1,"ACK callback cannot restart drive or duplicate transport")
    end
    next_case() do
        local f=Fixtures.fixture()
        local original_sample=f.sample
        f.sample=function() local raw=original_sample();raw.velocity=vector.create(0,0,1);return raw end
        local previews=watch_wheels(f)
        local resets=0;local original_reset=f.force.reset
        function f.force:reset() resets+=1;return original_reset(self) end
        f.observe()
        local first=copy(previews[1].after)
        check(math.abs(first[1].angular_speed)+math.abs(first[2].angular_speed)>1e-8,"actual tire kernel produces nonzero predicted rolling spin")
        previews[1].raw.wheels[1].angular_speed=12345
        previews[1].raw.wheels[2].angular_speed=-12345
        f.advance();f.observe()
        check(#previews==1 and count(f,"ack")==0,"queued command does not commit or preview another command")
        f.advance();f.mode="applied";f.successor=f.sample();local s=f.observe()
        check(#previews==2 and s.acknowledged==1 and s.submitted==2,"exact successor and ACK admit next preview")
        for i=1,2 do
            check(previews[1].before[i].angular_speed==0,"first wheel starts from authored rest "..i)
            check(previews[2].before[i].angular_speed==first[i].angular_speed,"next command carries detached applied spin "..i)
            check(previews[2].before[i].radius==first[i].radius and previews[2].before[i].inertia==first[i].inertia,"wheel shape unchanged "..i)
        end
        local second=copy(previews[2].after)
        f.mode="queued";f.successor=nil;f.advance();f.observe()
        f.advance();f.mode="applied";f.successor=f.sample();s=f.observe()
        for i=1,2 do check(previews[3].before[i].angular_speed==second[i].angular_speed,"spin survives consecutive applied ACKs "..i) end
        check(s.acknowledged==2 and s.submitted==3 and resets==0,"queued inbox backpressure remains; ACK never resets force history")
        check(f.force:consumed_hop_event_id()==0,"neutral history carry does not invent a consumed hop")
    end
    next_case() do
        local f=Fixtures.fixture();local original=f.force.preview
        function f.force:preview(...)
            local model,candidate=original(self,...)
            model.wheels[1].radius*=2
            return model,candidate
        end
        local s=f.observe()
        check(s.stop_requested and s.issue=="bounded wheel model unavailable" and not s.force_pending,"wheel shape mutation refused before admission")
        check(count(f,"submit")==0,"no command admits an unbounded or altered wheel state")
    end
    if case_done then case_done(cases,assertions) end
    return {cases=cases,assertions=assertions}
end
return Tests

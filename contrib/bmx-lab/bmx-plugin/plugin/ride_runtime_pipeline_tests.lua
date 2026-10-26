-- Constructed three-command transport and prediction tests. No Host or native
-- effects. The runner stages the real Ride with only its private literal enabled.
local Fixtures=require("./ride_runtime_tests")
local Identity=require("./lease_identity")
local Tests={}
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
local function fixture()
    local f=Fixtures.fixture()
    local sample=f.sample
    function f.sample() local row=sample();row.velocity=vector.create(0,0,1);return row end
    f.native={};f.records={};f.commands={};f.read_ids={};f.ack_ids={};f.ack_attempts={}
    f.next_id="9007199254745000";f.adoptions=0;f.resets=0;f.previews={}
    local preview,adopt,reset=f.force.preview,f.force._adopt,f.force.reset
    function f.force:preview(...)
        local args=table.pack(...)
        local row={head=f.adoptions,serial=f.serial,owner=self,wheels=copy(args[3])}
        f.previews[#f.previews+1]=row
        local model,candidate=preview(self,...);row.result=copy(model)
        return model,candidate
    end
    function f.force:_adopt(candidate)
        if self==f.force then
            if f.adopt_error then error("constructed model adoption failure") end
            f.adoptions+=1
        end
        return adopt(self,candidate)
    end
    function f.force:reset() if self==f.force then f.resets+=1 end;return reset(self) end
    local function refresh()
        for _,r in ipairs(f.native) do
            if r.outcome=="queued" and not r.hold and not f.hold_inbox
                and Identity.compare(f.serial,r.produced)>=0 then r.outcome="applied" end
            if r.outcome=="applied" and r.cleanup=="none" and not r.successor and not f.withhold_successors
                and Identity.compare(f.serial,r.produced)>0 then r.successor=copy(f.sample()) end
        end
    end
    function f.api.submit(epoch,command)
        refresh()
        assert(epoch==f.read.epoch,"command uses this exact measured body epoch")
        if f.refusal then return false,f.refusal end
        assert(#f.native<4,"constructed SDK ring has four slots")
        for _,r in ipairs(f.native) do assert(r.outcome~="queued","constructed SDK inbox is singular") end
        f.next_id=inc(f.next_id)
        local r={sequence=f.next_id,requested=f.serial,time=f.time,produced=inc(f.serial),
            outcome="queued",cleanup="none",retained=false,quarantined=false}
        f.records[r.sequence]=r;table.insert(f.native,r)
        table.insert(f.commands,{sequence=r.sequence,serial=f.serial,command=copy(command)})
        if f.stop_in_submit then f.ride:stop("constructed stop inside accepted submit") end
        return true,nil,f.return_sequence or r.sequence
    end
    function f.api.receipt(sequence)
        refresh()
        local r=f.records[sequence];assert(r and not r.acked,"original unacknowledged sequence")
        table.insert(f.read_ids,sequence)
        local attempted=r.outcome=="applied" or r.outcome=="partial"
        return {sequence=r.sequence,requested_serial=r.requested,
            produced_serial=attempted and r.produced or "0",outcome=r.outcome,
            force_attempted=attempted,torque_attempted=r.outcome=="applied",
            retained=r.retained,quarantined=r.quarantined,cleanup_disposition=r.cleanup,successor=r.successor}
    end
    function f.api.acknowledge(sequence)
        refresh()
        table.insert(f.ack_attempts,sequence)
        local r=f.native[1]
        assert(r and r.sequence==sequence,"SDK acknowledges only its oldest receipt")
        assert(r.outcome~="queued" and (r.outcome~="applied" or r.successor or r.cleanup=="parked_without_successor"),
            "SDK waits for actual successor or explicit park cleanup")
        if f.ack_error then error("constructed uncertain ACK") end
        r.acked=true;table.remove(f.native,1);table.insert(f.ack_ids,sequence)
        return true
    end
    function f.park(r)
        r.outcome="applied";r.cleanup="parked_without_successor";r.retained=true;r.quarantined=false;r.successor=nil
    end
    return f
end
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(_,run) cases+=1;run() end
    case("consecutive samples advance prediction before delayed ordered ACK",function()
        local f=fixture();local first=f.observe();local id1=first.pending_sequence
        f.advance();local second=f.observe()
        check(second.submitted==2 and second.pending_count==2 and second.acknowledged==0,"N+1 admits second command while first lacks N+2 proof")
        check(f.previews[2].head==1 and f.previews[2].owner==f.force,"next preview sees accepted history on the same controller")
        check(f.previews[2].wheels[1].angular_speed==f.previews[1].result.wheels[1].angular_speed,"prediction carries prior accepted wheels")
        f.advance();local third=f.observe()
        check(third.submitted==3 and third.acknowledged==1 and f.ack_ids[1]==id1,"oldest proof ACK does not stall current sample")
        check(f.previews[3].head==2 and f.adoptions==3 and f.resets==0,"ACK neither resets nor rolls history back")
        check(third.model_history.kind=="predictive_accepted" and third.model_history.serial==f.serial
            and third.model_history.native_wheel_state_known==false,"accepted prediction is not native wheel evidence")
        for _=1,6 do f.advance();f.observe() end
        check(#f.commands==9 and #f.ack_ids==7 and #f.native==2,"ring wraps while preserving the two latest transactions")
        for i=2,#f.commands do check(f.commands[i].serial==inc(f.commands[i-1].serial),"each packet belongs to its own consecutive N") end
    end)
    case("three-command capacity backpressure exposes the missed command step",function()
        local f=fixture();f.withhold_successors=true
        f.observe();f.advance();f.observe();f.advance();local full=f.observe()
        check(full.pending_count==3 and full.submitted==3,"three retained commands fit below SDK capacity four")
        f.advance();local held=f.observe()
        check(held.submitted==3 and #f.previews==3 and held.backpressure=="receipt_capacity","full capacity performs no submit or speculative advance")
        check(held.backpressure_steps==1 and held.last_backpressure_serial==f.serial,"uncommanded sample remains visible")
        local skipped=f.serial
        f.withhold_successors=false;f.advance();local resumed=f.observe()
        check(resumed.submitted==4 and resumed.acknowledged==3 and #f.native==1,"ordered prefix drains before one fresh command")
        check(f.commands[4].serial==f.serial and f.commands[4].serial~=skipped and #f.previews==4,"no catch-up command reuses the skipped sample")
        check(f.previews[4].head==3 and f.resets==0,"backpressure and ACK do not pretend to rewind accepted history")
    end)
    case("queued inbox is different from an applied row awaiting successor",function()
        local f=fixture();f.hold_inbox=true;f.observe();f.advance();local held=f.observe()
        check(held.backpressure=="native_inbox_queued" and held.submitted==1 and f.adoptions==1,"one queued native inbox blocks a second packet")
        f.hold_inbox=false;local duplicate=f.observe()
        check(duplicate.submitted==1 and #f.previews==1,"duplicate body may drain but cannot invent a command")
        f.advance();local resumed=f.observe()
        check(resumed.submitted==2 and resumed.acknowledged==1 and resumed.backpressure_steps==1,"fresh observation resumes without replay")
    end)
    case("later partial quarantine is visible behind a blocked head",function()
        local f=fixture();f.withhold_successors=true
        f.observe();f.advance();f.observe()
        local first,second=f.native[1],f.native[2]
        second.outcome="partial";second.quarantined=true;second.retained=true
        f.advance();local stopped=f.observe()
        check(stopped.stop_requested and stopped.submitted==2 and stopped.pending_count==2,"later failure stops admission before any third command")
        check(#f.ack_ids==0 and f.read_ids[#f.read_ids]==second.sequence,"selected later receipt is inspected without unordered ACK")
        f.park(first);local drained=f.ride:drain()
        check(#f.ack_ids==2 and f.ack_ids[1]==first.sequence and f.ack_ids[2]==second.sequence,"cleanup ACKs the now-eligible prefix in order")
        check(drained.unknown and drained.force_pending and drained.acknowledged==2,"partial mutation retains uncertainty after transport ACK")
        f.ride:drain();check(#f.ack_attempts==2 and f.resets==0,"uncertain mutation never duplicates ACK or restores old model history")
    end)
    case("malformed younger successor stops behind an older row awaiting proof",function()
        local f=fixture();f.withhold_successors=true
        f.observe();f.advance();f.observe()
        local first,second=f.native[1],f.native[2]
        f.advance(2);second.outcome="applied";second.successor=copy(f.sample())
        -- The younger identity and production serial are correct. Only its
        -- successor time contradicts its own requested serial and fixed step.
        second.successor.time+=second.successor.seconds
        -- Receipt cleanup can inspect native progress without manufacturing
        -- the missed N+2 model step. A later observe must remain stopped.
        local reads=#f.read_ids;local stopped=f.ride:drain();f.observe()
        check(stopped.stop_requested and stopped.unknown and stopped.issue=="applied successor incoherent"
            and stopped.submitted==2,"bad younger proof stops before a new command")
        check(#f.read_ids==reads+2 and f.read_ids[#f.read_ids]==second.sequence and #f.ack_ids==0,
            "blocked head does not hide younger proof or authorize unordered ACK")
        check(stopped.pending_count==2 and not stopped.pending_commands[1].unknown and stopped.pending_commands[2].unknown,
            "only the incoherent transaction becomes unknown")
        f.park(first);local drained=f.ride:drain()
        check(#f.ack_ids==1 and f.ack_ids[1]==first.sequence and drained.pending_sequence==second.sequence,
            "known parked head drains while younger uncertainty remains")
        second.successor=copy(f.sample());f.ride:drain()
        check(#f.ack_ids==1 and #f.ack_attempts==1 and f.adoptions==2 and f.resets==0,
            "later fixture repair cannot erase retained uncertainty or rewind history")
    end)
    case("B10 parked head does not erase the next command's successor duty",function()
        local f=fixture();f.withhold_successors=true
        f.observe();f.advance();f.observe()
        local first,second=f.native[1],f.native[2]
        -- Constructed per-receipt transport facts; not a claim about native park timing.
        f.park(first);second.hold=true;f.ride:stop("constructed Follow stop")
        local head=f.ride:drain()
        check(head.pending_count==1 and head.pending_sequence==second.sequence and head.acknowledged==1,"head park ACK leaves second exact transaction")
        second.hold=false;f.advance();local waiting=f.ride:drain()
        check(waiting.force_pending and waiting.acknowledged==1,"second applied row still requires its own later successor")
        f.withhold_successors=false;f.advance();local drained=f.ride:drain()
        check(not drained.force_pending and drained.acknowledged==2 and #f.commands==2,"second successor drains original capability after stop")
        check(f.resets==0 and f.adoptions==2,"park cleanup never changes accepted model history")
    end)
    case("later proof cannot skip an older receipt",function()
        local f=fixture();f.withhold_successors=true
        f.observe();f.advance();f.observe();f.advance();f.observe()
        local a,b,c=f.native[1],f.native[2],f.native[3]
        f.advance(2);c.outcome="applied";c.successor=copy(f.sample())
        f.ride:drain();check(#f.ack_ids==0,"later ready row cannot bypass blocked head")
        a.successor=copy(f.sample());f.ride:drain()
        check(#f.ack_ids==1 and f.ack_ids[1]==a.sequence,"only the eligible prefix is ACKed")
        b.successor=copy(f.sample());local done=f.ride:drain()
        check(not done.force_pending and f.ack_ids[2]==b.sequence and f.ack_ids[3]==c.sequence,"ordered final ACKs preserve sequence identity")
        check(f.adoptions==3 and f.resets==0,"out-of-order proof arrival cannot roll the prediction head back")
    end)
    case("uncertain head ACK retains every later command",function()
        local f=fixture();f.withhold_successors=true;f.observe();f.advance();f.observe()
        f.withhold_successors=false;f.advance();f.ack_error=true
        local stopped=f.ride:drain()
        check(stopped.unknown and stopped.pending_count==2 and stopped.ack_attempted,"unknown head ACK retains all command duty")
        f.ride:drain();check(#f.ack_attempts==1 and #f.ack_ids==0,"unknown ACK is neither retried nor skipped")
    end)
    for _,mode in ipairs({"duplicate","regressed","noncanonical"}) do
        case("invalid accepted identity "..mode,function()
            local f=fixture();f.withhold_successors=true;local first=f.observe()
            f.return_sequence=mode=="duplicate" and first.pending_sequence or mode=="regressed" and "1" or "01"
            f.advance();local stopped=f.observe()
            check(stopped.unknown and stopped.stop_requested and stopped.pending_count==2,"bad admitted sequence becomes separate retained uncertainty")
            check(stopped.pending_sequence==first.pending_sequence and stopped.pending_commands[2].sequence==nil,"earlier receipt identity is never overwritten")
            check(f.adoptions==1 and stopped.submitted==1,"invalid admission identity cannot advance model history")
        end)
    end
    case("defensive Core capacity refusal is clean backpressure",function()
        local f=fixture();f.refusal="force_pipeline_full";local s=f.observe()
        check(not s.stop_requested and not s.force_pending and s.submitted==0,"known local cap creates no native debt")
        check(s.backpressure=="core_receipt_capacity" and s.backpressure_steps==1 and f.adoptions==0,"refused preview never becomes accepted history")
    end)
    case("arbitrary native refusal still stops without adopting preview",function()
        local f=fixture();f.refusal="body command invalid, repeated, stopped, pending or receipt ring full"
        local s=f.observe()
        check(s.stop_requested and not s.force_pending and f.adoptions==0,"ambiguous native refusal is not classified as recoverable capacity")
    end)
    case("late accepted transaction survives stop inside submit",function()
        local f=fixture();f.stop_in_submit=true;local s=f.observe()
        check(s.stop_requested and s.pending_sequence==f.commands[1].sequence and f.adoptions==1,"exact accepted tuple survives reentrant stop")
        f.advance(2);local done=f.ride:drain()
        check(not done.force_pending and done.acknowledged==1,"original transaction drains after stop")
    end)
    case("model adoption failure still drains its known native receipt",function()
        local f=fixture();f.adopt_error=true;local s=f.observe()
        check(s.unknown and s.force_pending and s.submitted==1,"accepted native debt survives model failure")
        f.advance(2);local done=f.ride:drain()
        check(done.unknown and not done.force_pending and done.acknowledged==1,"model uncertainty cannot hide a known receipt from cleanup")
    end)
    case("accepted hop history prevents replay while its receipt waits",function()
        local f=fixture();f.withhold_successors=true;f.observe()
        f.advance();f.pad.buttons.right_stick=true;f.observe()
        f.advance();local s=f.observe()
        check(f.commands[2].command.impulse_id==1 and f.commands[3].command.impulse==nil,"same pending input hop is not emitted in two accepted packets")
        check(f.force:consumed_hop_event_id()==1 and f.mapping:status().pending_hop.id==1,"predictive event consumption is separate from receipt retirement")
        check(s.submitted==3 and s.acknowledged==0,"hop receipt remains independently pending")
    end)
    return {cases=cases,assertions=assertions,native_actions=0}
end
return table.freeze(Tests)

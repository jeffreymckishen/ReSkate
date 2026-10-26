-- Constructed SDK-shaped receipt cleanup. No native or gameplay claim.
local Fixtures=require("./ride_runtime_metrics_tests")
local Tests={}
local function copy(v)
    if type(v)~="table" then return v end
    local out={} for k,child in pairs(v) do out[k]=copy(child) end return out
end
local function fixture(mode)
    local f=Fixtures.fixture();f.withhold_successors=true
    f.observe();f.advance();f.observe()
    local state=f.ride:status()
    assert(state.submitted==2 and state.pending_count==2 and not state.stop_requested,"two accepted commands before cleanup")
    f.first=state.pending_commands[1].sequence;f.second=state.pending_commands[2].sequence
    -- Native progression to N+2 produces the younger command and proves the
    -- older one. Park keeps that older successor and seals only the younger.
    f.advance();f.proof=copy(f.sample())
    local receipt,ack=f.on_receipt,f.api.acknowledge
    f.rows={};f.reads={};f.acks={}
    function f.on_receipt(sequence)
        local row=receipt(sequence)
        assert(row.outcome=="applied","both original commands were produced")
        row.retained=true -- Actual SDK retained state is shared by every row.
        if sequence==f.first then row.successor=copy(f.proof)
        else row.cleanup_disposition="parked_without_successor";row.successor=nil end
        if mode=="malformed_younger" and sequence==f.second then row.sequence="01" end
        if mode=="malformed_older" and sequence==f.first then row.successor.time+=row.successor.seconds end
        if mode=="partial_quarantine" then
            row.quarantined=true -- Likewise a body-level flag on both rows.
            if sequence==f.second then
                row.outcome="partial";row.torque_attempted=false;row.cleanup_disposition="none"
            end
        end
        f.rows[sequence]=copy(row);f.reads[#f.reads+1]=sequence
        return row
    end
    function f.api.acknowledge(sequence)
        assert(sequence==(#f.acks==0 and f.first or f.second),"positive ACK follows the exact native receipt order")
        local result=ack(sequence);f.acks[#f.acks+1]=sequence;return result
    end
    return f
end
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(_,run) cases+=1;run() end
    case("younger park outranks older body-level retained flag",function()
        local f=fixture();local s=f.ride:drain()
        check(f.rows[f.first].retained and f.rows[f.second].retained and f.rows[f.first].successor~=nil
            and f.rows[f.first].cleanup_disposition=="none" and f.rows[f.second].cleanup_disposition=="parked_without_successor",
            "receipt setup preserves the SDK body flag and per-command cleanup distinction")
        check(s.acknowledged==2 and not s.force_pending and not s.unknown
            and f.acks[1]==f.first and f.acks[2]==f.second,"both exact terminal receipts ACK in order")
        check(s.issue=="force body parked without successor","younger explicit park must survive the older generic retained row")
        check(s.metrics.stop_counts["force body parked without successor"]==1
            and s.metrics.stop_counts["force body retained or quarantined"]==2,"both generic row observations are counted while explicit park remains the first cause")
        f.ride:drain();check(#f.acks==2,"cleanup does not duplicate either ACK")
    end)
    case("an existing Core stop cause remains authoritative",function()
        local f=fixture();f.ride:stop("Core window ended")
        local s=f.ride:drain()
        check(s.issue=="Core window ended" and s.metrics.stop_counts["Core window ended"]==1,"poll selection cannot overwrite a previously latched cause")
        check(s.acknowledged==2 and not s.force_pending and f.acks[1]==f.first and f.acks[2]==f.second,
            "preserving the outer cause does not block ordered terminal cleanup")
    end)
    case("malformed younger receipt outranks generic retained state",function()
        local f=fixture("malformed_younger");local s=f.ride:drain()
        check(s.issue=="force receipt unavailable or identity mismatch" and s.unknown,"untrusted selected identity has priority over body retention")
        check(s.acknowledged==1 and f.acks[1]==f.first and s.pending_sequence==f.second,"known older row drains without ACKing the malformed younger row")
        f.ride:drain();check(#f.acks==1,"unknown younger duty is neither guessed nor retried")
    end)
    case("malformed older successor is not hidden by valid younger park",function()
        local f=fixture("malformed_older");local s=f.ride:drain()
        check(s.issue=="applied successor incoherent" and s.unknown,"invalid proof outranks a later valid cleanup disposition")
        check(#f.reads==2 and f.reads[2]==f.second,"the complete poll observes both outcomes before choosing its cause")
        check(#f.acks==0 and s.pending_count==2,"younger park never permits ACK around an unknown head")
    end)
    case("partial mutation outranks shared body quarantine",function()
        local f=fixture("partial_quarantine");local s=f.ride:drain()
        check(f.rows[f.first].quarantined and f.rows[f.second].quarantined,"quarantine is consistently body-level in this fixture")
        check(s.issue=="force command partial" and s.unknown,"concrete partial mutation is more specific than the shared quarantine flag")
        check(s.acknowledged==2 and #f.acks==2 and s.pending_count==1 and s.pending_commands[1].acknowledged,
            "terminal transport ACK preserves the partial mutation's unresolved duty")
    end)
    case("callback and selected causes are visible before ACK callbacks",function()
        for _,callback_stop in ipairs({true,false}) do
            local f=fixture();local receipt,ack=f.on_receipt,f.api.acknowledge
            local expected=callback_stop and "receipt callback stop" or "force body parked without successor"
            function f.on_receipt(sequence)
                if callback_stop and sequence==f.first then f.ride:stop(expected) end
                return receipt(sequence)
            end
            function f.api.acknowledge(sequence)
                local current=f.ride:status()
                check(current.stop_requested and current.issue==expected,
                    "the prelatched or selected cause must already be visible during every ACK callback")
                return ack(sequence)
            end
            local result=f.ride:drain()
            check(result.issue==expected and result.metrics.stop_counts[expected]==1,
                "poll priority preserves a callback's earlier latch and selects its own cause otherwise")
            check(result.acknowledged==2 and not result.force_pending and #f.acks==2,
                "callback visibility does not change either ordered terminal ACK")
        end
    end)
    return {cases=cases,assertions=assertions,native_actions=0}
end
return table.freeze(Tests)

-- TEST ONLY. Exact Recorder lexical copy + pure cost proxy, never runtime/staged code.
-- Targeted callee-fault atomicity is separate from normal-production Host qualification.
-- Malformed private-state cases are robustness-only, not reachable SDK traces.
local Factory=require("./hop_recorder_private_test_factory")
local Recorder=Factory.Recorder
local Codec=require("./hop_evidence_codec_real")
local Control=require("./hop_pair_fault_control")
local F=require("./hop_pair_sdk_fixtures")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local KA,KB="lease|input.lease_state","lease|input.lease_capture_state"
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn) cases+=1;local ok,why=pcall(fn);assert(ok,name..": "..tostring(why)) end
    local function emit(rec,data,at)
        local payload=F.copy(data);payload.at_ms=at
        return rec:append("lease",payload)
    end
    local function slot_count(s)
        local count=0
        for key in pairs(s.pair_candidates) do
            check(type(key)=="number" and (key==1 or key==2),"candidate map has only the two fixed array keys")
            count+=1
        end
        check(count==2 and #s.pair_candidates==2,"fixed candidate map cardinality remains exactly two")
        return count
    end
    local function prepared()
        Control.clear();local writes={}
        local rec=Recorder.new(function(key,value) writes[#writes+1]={key=key,value=value} end,"pair_fault_fixture")
        check(Codec.pair_data_known(F.lease_state()) and Codec.pair_data_known(F.capture_state()),"strict real SDK fixtures are eligible")
        check(emit(rec,F.lease_state(),nil) and emit(rec,F.capture_state(),8),"two ordinary valid singletons admitted")
        local s=Factory.state(rec)
        check(#s.regular==2 and #s.critical==0 and s.pair_candidates[1]==s.regular[1] and s.pair_candidates[2]==s.regular[2],"exact source pair slots hold two current entries")
        check(slot_count(s)==2,"prepared state uses exactly two bounded candidate references")
        return rec,writes,s
    end
    local function values(entry)
        return {key=entry.key,kind=entry.kind,bytes=entry.bytes,critical=entry.critical,flushed=entry.flushed,writing=entry.writing,
            first=entry.first_call,last=entry.last_call,repeats=entry.repeats,first_at=entry.first_at_ms,last_at=entry.last_at_ms}
    end
    local function snapshot(s)
        local a,b=s.regular[1],s.regular[2]
        return {refs={regular=s.regular,critical=s.critical,a=a,b=b,wire_a=a.wire,wire_b=b.wire,
            bases=s.bases,base_a=s.bases[KA],base_b=s.bases[KB],base_bytes=s.base_bytes,candidates=s.pair_candidates,
            candidate_a=s.pair_candidates[1],candidate_b=s.pair_candidates[2],last=s.last,last_lease=s.last.lease},
            data={a=values(a),b=values(b),wire_a_value=F.copy(a.wire),wire_b_value=F.copy(b.wire),candidate_slots=slot_count(s),
                regular_count=#s.regular,critical_count=#s.critical,
                wire_bytes=s.regular_wire_bytes,state_bytes=s.regular_state_bytes,total=s.regular_bytes,critical_bytes=s.critical_bytes,
                base_a_bytes=s.base_bytes[KA],base_b_bytes=s.base_bytes[KB],base_count=s.base_count,
                regular_next=s.regular_next,critical_next=s.critical_next,store_bytes=s.store_bytes,chunks=s.chunks,stored_rows=s.stored_rows,
                coalesced=s.coalesced,busy=s.busy,storage_fault=s.storage_fault,stopping=s.stopping,
                cleanup_observed=s.cleanup_observed,unresolved_debt=s.unresolved_debt,saved_revision=s.saved_revision,latest_revision=s.latest_revision},
            calls=s.calls,version=s.version,dropped=s.dropped}
    end
    local function unchanged(s,before,writes,reason)
        local after=snapshot(s)
        for key,value in pairs(before.refs) do check(after.refs[key]==value,"failed preflight changed original reference "..key) end
        for key,value in pairs(after.refs) do check(before.refs[key]==value,"failed preflight added/replaced reference "..key) end
        check(F.same(after.data,before.data),"failed preflight changed header/endpoints/canonical/wire/pointer budget/cursors")
        check(s.calls==before.calls+1 and s.version==before.version+2 and s.dropped==before.dropped+1,"one attempt plus established sticky-fault accounting only")
        check(s.first_fault==reason and s.stop_requested and s.observation_loss,"fault remains explicit and sticky")
        check(#writes==0 and s.coalesced==0,"no storage side effect or half-admitted pair")
    end
    local function append_refused(rec)
        local result=table.pack(pcall(function() return emit(rec,F.lease_state(),16) end))
        check(result[1] and result[2]==false and type(result[3])=="string","real append returns controlled refusal instead of exception/admission")
    end
    local function persist_originals(rec,writes)
        Control.clear()
        rec:terminal({phase="cleanup_unknown",stop_latched=true,bike_authority=true,cleanup_pending=true,cleanup_unknown=true,
            source={cleanup_pending=true,cleanup_unknown=true,lease_handle_present=true,capture_state={phase="capturing",report_debt=true,quarantined=false}},
            stop_reason="synthetic preflight fault"})
        for _=1,2200 do if rec:status().flushed then break end;local ok,why=rec:flush({inactive=true,terminal=true});check(ok,"fault evidence flush: "..tostring(why)) end
        check(rec:status().flushed and rec:status().unqualified,"fault evidence stays unqualified after persistence")
        local chunks={};for _,write in ipairs(writes) do if write.value.rows then chunks[#chunks+1]=write.value end end
        local rows,why=Codec.decode_chunks(chunks,"pair_fault_fixture");check(type(rows)=="table","real codec accepts preserved evidence: "..tostring(why))
        local leases={};for _,r in ipairs(rows) do if r.kind=="lease" then leases[#leases+1]=r end end
        check(#leases==2,"rejected incoming call3 did not create a row or mutate prior endpoints")
        local a,b=leases[1],leases[2]
        check(a.first_call==1 and a.last_call==1 and a.repeats==1 and a.first_at_ms==nil and a.last_at_ms==nil and rawget(a,"paired")==nil,"original A1 absent timestamps and ordinary marker are exact")
        check(b.first_call==2 and b.last_call==2 and b.repeats==1 and b.first_at_ms==8 and b.last_at_ms==8 and rawget(b,"paired")==nil,"original B2 endpoints and marker are exact")
        check(F.same(a.data,F.lease_state()) and F.same(b.data,F.capture_state()) and b.data.report_debt==true,"full SDK facts and known capture debt survive fault")
    end
    case("unarmed lexical fixture takes the real absent-first pair path",function()
        local rec,writes,s=prepared();local before=snapshot(s);local old_base=s.bases[KA];local old_wire=s.regular[1].wire
        local ok,why=emit(rec,F.lease_state(),16);check(ok and why=="paired","no injected fault uses real producer path")
        local a=s.regular[1]
        check(a.first_call==1 and a.last_call==3 and a.repeats==2 and a.first_at_ms==nil and a.last_at_ms==16 and a.wire[12]==true,"exact marker/endpoints with absent first time")
        check(a.wire[11]==old_wire[11] and s.bases[KA].data==old_base.data,"only headers change; no payload copy")
        check(old_wire[6]==1 and old_wire[7]==1 and old_wire[12]==false and old_base.last_call==1 and old_base.paired==nil,"old frozen wire/base never mutated")
        check(s.regular_wire_bytes==before.data.wire_bytes-3,"false5 to integer16 two bytes shrinks the second timestamp cost3")
        check(s.regular_state_bytes==before.data.state_bytes+256 and s.regular_bytes==before.data.total+253,"exact256 current-state surcharge plus wire delta, inside unchanged cap")
        check(s.pair_candidates[1]==false and s.pair_candidates[2]==before.refs.candidate_b and s.last.lease==a,"sealed pointer cleared and exact latest-kind entry updated atomically")
        check(#writes==0 and Control.status().mode==false,"no storage or injected costs were needed")
    end)
    for _,mode in ipairs({"wire_nil","wire_oversize","state_nil","state_budget"}) do
        case("targeted valid-candidate preflight cost fault "..mode,function()
            local rec,writes,s=prepared();Control.arm(mode);local before=snapshot(s)
            append_refused(rec)
            unchanged(s,before,writes,mode=="state_budget" and "regular_capacity" or "invalid_encoding")
            local seen=Control.status();check(seen.wire_hits==1 and seen.state_hits==1,"fault reached exact new-pair cost calls after valid old-state checks")
            persist_originals(rec,writes)
        end)
    end
    for _,mode in ipairs({"wire_nan","wire_string","state_fractional","state_negative"}) do
        case("robustness-only malformed cost return "..mode,function()
            local rec,writes,s=prepared();Control.arm(mode);local before=snapshot(s)
            append_refused(rec);unchanged(s,before,writes,"invalid_encoding")
            check(Control.status().wire_hits==1 and Control.status().state_hits==1,"malformed pure-cost return was exercised")
            persist_originals(rec,writes)
        end)
    end
    local mutations={
        slot_type=function(s)local old=s.pair_candidates[1];s.pair_candidates[1]="invalid private slot";return function()s.pair_candidates[1]=old end end,
        candidate_key=function(s)local a=s.regular[1];local old=a.key;a.key="lease|wrong";return function()a.key=old end end,
        cache_endpoint=function(s)local old=s.bases[KA];local bad=F.copy(old);bad.last_call=2;s.bases[KA]=table.freeze(bad);return function()s.bases[KA]=old end end,
        old_wire_charge=function(s)local a=s.regular[1];local old=a.bytes;a.bytes=old+1;return function()a.bytes=old end end,
        old_state_charge=function(s)local old=s.base_bytes[KA];s.base_bytes[KA]=old+1;return function()s.base_bytes[KA]=old end end,
        one_sided_time=function(s)local a=s.regular[1];local old=a.last_at_ms;a.last_at_ms=0;return function()a.last_at_ms=old end end,
        ledger=function(s)local old=s.regular_bytes;s.regular_bytes=old-1;return function()s.regular_bytes=old end end,
        mutable_wire=function(s)local a=s.regular[1];local old=a.wire;a.wire=F.copy(old);return function()a.wire=old end end,
    }
    for _,mode in ipairs({"slot_type","candidate_key","cache_endpoint","old_wire_charge","old_state_charge","one_sided_time","ledger","mutable_wire"}) do
        case("robustness-only malformed private bookkeeping "..mode,function()
            local rec,writes,s=prepared();local undo=mutations[mode](s);local before=snapshot(s)
            append_refused(rec);unchanged(s,before,writes,"invalid_pair_state")
            if mode=="mutable_wire" then check(not table.isfrozen(s.regular[1].wire),"refusal did not freeze or repair injected caller-owned test wire") end
            -- Restore ONLY the test-injected malformation after checking no producer
            -- mutation. Sticky fault/loss remains; this is never a recovery/retry path.
            undo();persist_originals(rec,writes)
        end)
    end
    check(cases==17,"complete17-case targeted/robustness preflight matrix")
    return {cases=cases,assertions=assertions,native_actions=0,private_fault_fixture=true,normal_host_qualified=false}
end
return table.freeze(Tests)

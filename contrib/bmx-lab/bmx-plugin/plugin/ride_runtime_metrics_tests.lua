-- Constructed diagnostic counters only. No native or gameplay qualification.
local Ride=require("./ride_runtime")
local Fixtures=require("./ride_runtime_tests")
local Identity=require("./lease_identity")
local Forces=require("./forces")
local Tests={}
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
local function add(v,n) for _=1,n do v=inc(v) end;return v end
local function held_step(f)
    local serial,ms=f.input_serial,f.ms
    f.advance();f.input_serial,f.ms=serial,ms
end
local function fixture()
    local f=Fixtures.fixture()
    -- Long canonical IDs keep the diagnostic tests above double precision.
    f.serial="18446744073709520000"
    f.input_serial="18446744073709530000"
    f.ms="18446744073709540000"
    function f.on_receipt(sequence)
        local r=f.transactions[sequence]
        assert(r,"selected exact native transaction")
        local applied=Identity.compare(f.serial,r.produced)>=0
        local successor=applied and not f.withhold_successors
            and Identity.compare(f.serial,r.produced)>0 and f.sample() or nil
        return {sequence=sequence,requested_serial=r.requested,produced_serial=applied and r.produced or "0",
            outcome=applied and "applied" or "queued",force_attempted=applied,torque_attempted=applied,
            retained=false,quarantined=false,cleanup_disposition="none",successor=successor}
    end
    return f
end
Tests.fixture=fixture
Tests.held_step=held_step
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(_,run) cases+=1;run() end
    case("default inactive counters are plain and empty",function()
        local r=Ride.new({},{});local m=r:status().metrics
        check(m.steps==0 and m.samples_total==0 and #m.samples==0 and m.inflight==0,"inactive metrics invent no body evidence")
        check(m.submitted_count==0 and m.applied_count==0 and next(m.stop_counts)==nil,"inactive metrics invent no transport or stop")
    end)
    case("every stop reason and repetition is counted while first cause stays latched",function()
        local f=fixture()
        f.ride:stop("first fixture cause")
        f.ride:stop("force receipt watchdog expired")
        f.ride:stop("force acknowledgement outcome unknown")
        f.ride:stop("force receipt watchdog expired")
        f.ride:stop("first fixture cause")
        f.ride:drain();f.observe()
        local status=f.ride:status();local m=status.metrics;local count=0
        for _ in pairs(m.stop_counts) do count+=1 end
        check(count==3 and m.stop_counts["first fixture cause"]==2
            and m.stop_counts["force receipt watchdog expired"]==2
            and m.stop_counts["force acknowledgement outcome unknown"]==1,
            "later cleanup reasons and repeated requests each increment their own counter")
        check(status.issue=="first fixture cause" and status.stop_requested,
            "later reasons never replace the first latched cause")
        check(m.steps==0 and m.samples_total==0,"stopped observe cannot create a diagnostic step")
    end)
    case("stop key count is bounded and overflow counts occurrences",function()
        local f=fixture()
        for i=1,8 do f.ride:stop("bounded reason "..i) end
        for _=1,5 do f.ride:stop("ninth reason") end
        f.ride:stop("bounded reason 3")
        local status=f.ride:status();local m=status.metrics;local keys,total=0,m.stop_counts_overflow
        for _,n in pairs(m.stop_counts) do keys+=1;total+=n end
        check(keys==8 and m.stop_counts_overflow==5 and m.stop_counts["ninth reason"]==nil,
            "a ninth reason is counted in overflow on every occurrence")
        check(m.stop_counts["bounded reason 3"]==2 and total==14,
            "an admitted reason still increments after cardinality exhaustion")
        check(status.issue=="bounded reason 1","overflow cannot replace the first cause")
    end)
    case("escaped key bytes admit the exact boundary without truncation",function()
        local f=fixture();local keys={}
        -- Each JSON key is128bytes: two quotes, one digit,20 six-byte
        -- control escapes and five printable bytes.
        for i=1,8 do keys[i]=tostring(i)..string.rep(string.char(1),20).."xxxxx" end
        for i=1,7 do f.ride:stop(keys[i]) end
        f.ride:stop(keys[8].."x")
        check(f.ride:status().metrics.stop_counts_overflow==1,
            "a129byte candidate cannot fit the last128bytes")
        f.ride:stop(keys[8]);f.ride:stop(keys[1]);f.ride:stop("overflow after exact boundary")
        local m=f.ride:status().metrics;local count=0
        for _ in pairs(m.stop_counts) do count+=1 end
        check(count==8 and m.stop_counts[keys[8]]==1 and m.stop_counts[keys[1]]==2,
            "exact1024 encoded key bytes fit, and a retained key repeats at the boundary")
        check(m.stop_counts[keys[8].."x"]==nil and m.stop_counts_overflow==2,
            "rejected keys are never shortened or merged into an admitted key")
    end)
    case("full Unicode reason keys stay distinct and malformed later keys overflow",function()
        local f=fixture();f.ride:stop("first cause")
        local prefix=string.rep("x",179)
        local a=prefix..string.char(0xC3,0xA9)
        local b=prefix..string.char(0xC3,0xAA)
        f.ride:stop(a);f.ride:stop(b)
        for _,bad in ipairs({string.char(0xFF),string.char(0xC0,0xAF),string.char(0xED,0xA0,0x80),
            string.char(0xF4,0x90,0x80,0x80)}) do f.ride:stop(bad) end
        local status=f.ride:status();local m=status.metrics
        check(m.stop_counts[a]==1 and m.stop_counts[b]==1 and m.stop_counts[prefix..string.char(0xC3)]==nil,
            "valid reasons sharing their first180bytes retain full distinct keys")
        check(m.stop_counts_overflow==4 and status.issue=="first cause",
            "invalid later UTF-8 cannot poison stored keys or replace the first issue")
    end)
    case("report timestamp gap differs from no-report body streak",function()
        local f=fixture();local initial_ms=f.ms;f.observe()
        for _=1,3 do held_step(f);f.observe() end
        local held=f.ride:status().metrics
        check(held.steps==4 and held.fresh_report_steps==1 and held.steps_without_report==3
            and held.max_steps_without_report==3,"held reports count observed body steps without new consumption")
        check(held.report_gap_count==0 and held.largest_report_gap_ms==0,"held body time is not a fabricated report timestamp")
        f.advance();f.ms=add(initial_ms,34);local m=f.observe().metrics
        check(m.report_gap_count==1 and m.largest_report_gap_ms==34 and m.report_gap_unbounded==0,
            "exact long native timestamps produce only their bounded difference")
        check(m.max_steps_without_report==3 and m.fresh_report_steps==2,"a fresh report resets the current streak without erasing its maximum")
    end)
    case("duplicate body stages a report for later consumption",function()
        local f=fixture();f.observe()
        f.new_input();local duplicate=f.observe().metrics
        check(duplicate.steps==1 and duplicate.fresh_report_steps==1 and duplicate.report_gap_count==0,
            "staging on a duplicate body is not consumption")
        f.advance();local status=f.observe();local m=status.metrics
        check(m.steps==2 and m.fresh_report_steps==2 and m.samples[2].report and status.input_queued==1,
            "next body consumes the previously staged fresh report")
        check(m.report_gap_count==1 and m.largest_report_gap_ms==1,
            "report gap follows the consumed observation rather than the newest staged timestamp")
    end)
    case("grounded transitions distinguish consumed and held reports",function()
        local f=fixture();f.observe()
        f.clear=true;held_step(f);local air_serial=f.serial;f.observe()
        f.clear=false;f.advance();local ground_serial=f.serial;local m=f.observe().metrics
        check(m.grounded_transition_total==2 and m.grounded_changes_without_report==1 and m.grounded_changes_with_report==1,
            "validated contact changes count on both kinds of body step")
        check(m.grounded_transitions[1].serial==air_serial and not m.grounded_transitions[1].grounded
            and not m.grounded_transitions[1].report,"air transition retains its exact serial and report distinction")
        check(m.grounded_transitions[2].serial==ground_serial and m.grounded_transitions[2].grounded
            and m.grounded_transitions[2].report,"ground transition retains its exact serial and report distinction")
        f.clear=true;local duplicate=f.observe().metrics
        check(duplicate.grounded_transition_total==2 and duplicate.samples_total==3,"duplicate bodies cannot fabricate contact changes")
    end)
    case("asymmetric wheel rows retain each scalar from the accepted prediction",function()
        local f=fixture();local sample=f.sample
        f.height=1;f.separation=1/256
        function f.sample()
            local row=sample();row.position=vector.create(0,f.height,-.05);return row
        end
        f.on_decode=function(row)
            local hit=f.reverse and 2 or 1
            local clear=f.reverse and 1 or 2
            row.rays[hit].position[2]-=f.separation
            row.rays[clear]={status="clear"}
        end
        local preview,adopt=f.force.preview,f.force._adopt
        local predictions,adopted={},{}
        function f.force:preview(h,body,wheels,samples,controls)
            local model,candidate=preview(self,h,body,wheels,samples,controls)
            local predicted={}
            for name,value in pairs(model) do predicted[name]=value end
            -- Deliberately unequal synthetic wheel predictions isolate the
            -- diagnostic mapping. Contact validation and candidate adoption
            -- still follow the actual Ride transaction path.
            local speeds=f.reverse and {-.75,2.5} or {3.25,-1.5}
            predicted.wheels={}
            for i=1,2 do
                predicted.wheels[i]={radius=model.wheels[i].radius,inertia=model.wheels[i].inertia,
                    angular_speed=speeds[i]}
            end
            predictions[#predictions+1]={candidate=candidate,front_separation=samples[1].separation,
                rear_separation=samples[2].separation}
            return predicted,candidate
        end
        function f.force:_adopt(candidate)
            if self==f.force then adopted[#adopted+1]=candidate end
            return adopt(self,candidate)
        end
        local first=f.observe();local a=first.metrics.samples[1]
        check(first.submitted==1 and not first.stop_requested and adopted[1]==predictions[1].candidate,
            "first scalar record follows exact admission and the original candidate adoption")
        check(a.front_hit and not a.rear_hit,"first contact row keeps front hit and rear clear distinct")
        check(math.abs(a.front_separation-f.separation)<1e-6 and a.front_separation>0 and a.rear_separation==nil,
            "front separation is the measured scalar and clear rear separation remains absent")
        check(math.abs(a.front_separation-predictions[1].front_separation-9.8*Forces.native_seconds^2)<1e-9,
            "the gravity-only forecast changes preview separation without overwriting measured diagnostics")
        check(a.front_speed==3.25 and a.rear_speed==-1.5,"unequal nonzero predicted speeds retain their wheel identity")
        check(a.body_height==1,"first record contains the sampled body height")
        f.advance();f.reverse=true;f.height=1.25;f.separation=1/512
        local second=f.observe();local b=second.metrics.samples[2]
        check(second.submitted==2 and not second.stop_requested and adopted[2]==predictions[2].candidate,
            "changed scalar record follows the next accepted candidate")
        check(not b.front_hit and b.rear_hit,"reversed contacts keep front clear and rear hit distinct")
        check(b.front_separation==nil and math.abs(b.rear_separation-f.separation)<1e-6
            and b.rear_separation>0 and b.rear_separation~=a.front_separation,
            "rear separation changes with measured contact instead of reusing the front scalar or its forecast")
        check(b.front_speed==-.75 and b.rear_speed==2.5,"both predicted speed fields change on the second admission")
        check(b.body_height==1.25 and b.body_height~=a.body_height,"body height changes with the actual sampled body")
    end)
    case("invalid contact never becomes a wheel or grounded record",function()
        local f=fixture();f.on_decode=function(row) row.rays[1].normal={0,0,0} end
        local status=f.observe();local m=status.metrics
        check(status.stop_requested and m.steps==1 and m.steps_without_report==1,"known body with unconsumed staged report is counted literally")
        check(m.samples_total==0 and m.grounded_transition_total==0,"invalid contact emits no wheel or grounded evidence")
    end)
    case("required tripwire must pass before wheel diagnostics exist",function()
        local f=fixture();local decode=f.contact.decode
        f.contact.CATEGORY_WHEEL_LANE_QUALIFIED=true
        f.contact.actor_lane_qualified=function(query) return query.actor_lane=="named_categories_absent" end
        f.api.probe_batch=function() return {} end
        f.contact.decode=function(frame,plan)
            if #plan==3 then error("constructed tripwire failure") end
            local row=decode(frame,plan);row.query.actor_lane="named_categories_absent";return row
        end
        local status=f.observe();local m=status.metrics
        check(status.stop_requested and status.issue=="rider tripwire decode unavailable","fixture reaches the independent required tripwire")
        check(m.steps==1 and m.samples_total==0 and m.grounded_transition_total==0,"wheel records cannot precede tripwire validation")
    end)
    case("serial metrics count accepted and applied entries once",function()
        local f=fixture();f.withhold_successors=true
        f.observe();f.advance();f.observe();f.advance();f.observe();f.advance();local full=f.observe()
        local m=full.metrics
        check(m.submitted_count==3 and m.submitted_delta_count==2 and m.submitted_delta_one==2,
            "accepted serial cadence counts each exact admission once")
        check(m.applied_count==3 and m.applied_delta_count==2 and m.applied_delta_one==2
            and m.applied_delay_one==3 and m.applied_delay_other==0,"application observations use each receipt's original production serial")
        check(m.inflight==3 and m.max_inflight==3 and m.samples[#m.samples].inflight==3,"per-step flight count includes retained known commands")
        f.ride:drain();f.ride:drain();local repeated=f.ride:status().metrics
        check(repeated.applied_count==3 and repeated.applied_delta_count==2,"repeated receipt polling never recounts application")
        f.withhold_successors=false;f.advance();local resumed=f.observe().metrics
        check(resumed.submitted_count==4 and resumed.submitted_delta_other==1 and resumed.submitted_delta_max==2,
            "backpressure remains visible as an accepted-command serial gap")
        check(resumed.inflight==1 and resumed.max_inflight==3 and resumed.samples[#resumed.samples].inflight==1,
            "post-step sample reflects ordered ACK and current admission")
    end)
    case("history stays bounded across the complete M3 sample window",function()
        local f=fixture();local early
        for i=1,150 do
            if i>1 then f.advance() end
            f.clear=i%2==0
            local status=f.observe();if i==1 then early=status end
        end
        local m=f.ride:status().metrics
        check(m.steps==150 and m.samples_total==150 and #m.samples==24 and m.samples_omitted==126,
            "wheel and body-height ring keeps only the latest24 valid observations")
        check(m.grounded_transition_total==149 and #m.grounded_transitions==16 and m.grounded_transition_omitted==133,
            "transition history is separately bounded")
        check(m.samples[24].serial==f.serial and math.abs(m.samples[24].body_height-.9)<1e-6
            and Identity.bounded_delta(m.samples[24].serial,m.samples[1].serial,23)==23,
            "bounded rows retain exact serial ordering and sampled height")
        check(early.metrics.steps==1 and #early.metrics.samples==1,"returned diagnostics are detached from later updates")
        local fields=0
        local function visit(value,depth)
            local kind=type(value)
            check(kind=="table" or kind=="string" or kind=="number" or kind=="boolean","metrics contain only serializable plain values")
            if kind=="table" then
                check(depth<8,"metric nesting remains within Core's depth contract")
                for _,child in pairs(value) do fields+=1;visit(child,depth+1) end
            elseif kind=="string" then check(#value<=1200,"diagnostic strings remain bounded") end
        end
        visit(m,0);check(fields<600,"Ride metrics leave room for the complete Core ledger")
    end)
    case("unrepresentable report differences are explicit",function()
        local f=fixture();f.ms="1";f.observe()
        f.advance();f.ms="18446744073709551615";local m=f.observe().metrics
        check(m.report_gap_count==1 and m.report_gap_unbounded==1 and m.largest_report_gap_ms==0,
            "large exact timestamp difference is marked unavailable rather than rounded or clamped")
    end)
    return {cases=cases,assertions=assertions,native_actions=0}
end
return table.freeze(Tests)

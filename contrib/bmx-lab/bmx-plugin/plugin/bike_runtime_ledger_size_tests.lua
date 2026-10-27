-- Whole-Core ledger byte/shape regression (LUA-3r). The Ride fixture advances
-- 151 native-shaped steps at the pinned native timestep exceed the2500 ms
-- target. The actual duration is reported. Its actual diagnostics are
-- placed in Core's existing shared-state seam; Core then builds and persists
-- every whole snapshot through the SDK-compatible runner JSON helper.
-- Core's activation/window literals stay unchanged. This is constructed
-- serialization/counter evidence, not a 2500 ms admitted Core/native ride.
local Core=require("./bike_runtime_core")
local Spawn=require("./bike_spawn")
local Equipment=require("./equipment_runtime")
local RideTests=require("./ride_runtime_tests")
local Identity=require("./lease_identity")
local Forces=require("./forces")
local Tests={}
local KEY="bmx_bike_lifecycle_v1"
local function copy(v)
    if type(v)~="table" then return v end
    local out={};for k,c in pairs(v) do out[k]=copy(c) end;return out
end
local function long(n) return "100000000000"..string.format("%08d",n) end
local axes={"left_x","left_y","right_x","right_y","left_trigger","right_trigger"}
local buttons={"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"}
local function frame()
    local pad={playstation=false,buttons={}}
    for _,key in ipairs(axes) do pad[key]=0 end
    for _,key in ipairs(buttons) do pad.buttons[key]=false end
    return {input_ok=true,sample={user=0,pad=pad}}
end
local history_receipt={sequence=long(77),status="revoked",reason="cancelled",user=0,button=0x8000,
    requested_ms=long(1000),expires_ms=long(2000),observed_ms=long(1800),source_epoch=long(12),
    transport="xinput",source_identity="observed_stream",publication_scope="process_outer_xinput_buffer",
    consumption="unobserved",semantic_completion="unobserved",terminal=true,report_debt=false,
    claim_released=true,actor_retired=false,orphaned=false,quarantined=false,original_result_known=false,
    first_rejection_mask=1280,first_rejection_stage="core_plan",press_candidates="7",press_publications="7",
    neutral_publications="1",original_failures="0",contentions="0"}
-- The Source service fixture follows core_ride_mode_tests: real lease_source
-- validates its reports; the Spawn owner is a stand-in, as in that suite.
local function source_fixture(encode,options)
    options=options or {}
    local f={now=1000,slot=options.slot or 0,serial=5,renewals=0,reserves=0,publishes=0,follow_reads=0,
        body_reads=0,stops=0,spawn_requests=0,visuals=0,published=false,follow=newproxy(),body=newproxy()}
    f.pad=frame().sample.pad
    local s={time={},input={},skater={},level={},storage={},json={},menu={},entities={},world={physics={}}}
    local function forbidden(name) return function() error(name.." must not be reached",0) end end
    function s.time.now() return f.now end
    -- Closed menus, focused gameplay, an upright, grounded on-foot (504) rider.
    function s.input.focus() return {focused=true,interface_open=false,gameplay=true} end
    function s.input.allowed() return true end
    function s.menu.game() return {open=false} end
    function s.skater.get() return {airborne=false,position=vector.create(0,0,0),heading=0} end
    function s.skater.telemetry() return {skater=true,airborne=false,teleport_pending=false,
        watch={valid=true,state=504,ragdoll_known=true,ragdoll=false,wipeouts=0}} end
    function s.level.current() return {name="sanvan"} end
    f.saves,f.encoded_sizes={},{}
    function s.json.encode(record)
        local text=encode(record)
        table.insert(f.encoded_sizes,#text)
        return text
    end
    function s.storage.get() return nil end
    function s.storage.set(key,record)
        if key==KEY then table.insert(f.saves,{record=copy(record),bytes=#encode(record)}) end
        -- The actual SDK returns zero values.
    end
    for _,name in {"pulse","pulse_state","pulse_cancel","pulse_acknowledge"} do s.input[name]=forbidden("input."..name) end
    for _,name in {"probe_batch","submit","receipt","acknowledge"} do s.world.physics[name]=forbidden(name) end
    -- One selected stream. Each pad change is a new observation, as Source requires.
    local function stream(row)
        row.transport,row.source_identity,row.physical_device_identity="xinput","observed_stream","unobserved"
        row.user,row.sequence,row.source_epoch,row.context_generation=f.user,"10000000000000000011","10000000000000000012","10000000000000000013"
        return row
    end
    function s.input.lease(user)
        if f.lease then return nil,"busy" end
        f.user,f.lease,f.lease_status=user,newproxy(),"active"
        return f.lease
    end
    function s.input.lease_read(handle)
        if handle~=f.lease or f.lease_status~="active" then return nil,"unavailable" end
        local row=stream({mode="observe",capturing=false,report_debt=false,observation_serial=long(f.serial),
            observed_ms=long(2000+f.serial),packet=f.serial,pad=f.pad})
        row.epoch=newproxy()
        return row
    end
    function s.input.lease_renew(handle)
        if handle~=f.lease then return false,"stale_epoch" end
        f.renewals+=1
        return true
    end
    function s.input.lease_state(handle)
        if handle~=f.lease then return nil,"unavailable" end
        local terminal=f.lease_status~="active"
        local reserved=f.capture~=nil and not f.capture_acked
        return stream({mode="observe",capturing=false,report_debt=false,status=f.lease_status,
            reason=terminal and "cancelled" or "none",terminal=terminal,requested_ms=long(1000),expires_ms=long(900000),
            observed_ms=long(2000+f.serial),last_observation=long(f.serial),renewals=tostring(f.renewals),
            source_released=terminal and not reserved,capture_reserved=reserved,orphaned=false})
    end
    function s.input.lease_release(handle)
        if handle~=f.lease or f.lease_status~="active" then return false,"unavailable" end
        f.lease_status="released"
        return true
    end
    function s.input.lease_acknowledge(handle)
        if handle~=f.lease or f.lease_status=="active" or (f.capture and not f.capture_acked) then return false,"busy" end
        return true
    end
    local function capture_row()
        local c=f.capture
        return stream({mode="capture",capture_scope="selected_observed_xinput_stream",
            publication_scope="process_outer_xinput_buffer",consumption="unobserved",semantic_completion="unobserved",
            capturing=c.phase=="capturing",report_debt=c.phase=="capturing",phase=c.phase,reason=c.reason,
            terminal=c.phase=="complete",quarantined=false,generation=c.generation,revision=c.revision,
            expires_ms=long(900000),publications=c.publications,neutral_releases=c.neutral_releases})
    end
    function s.input.lease_capture(handle)
        if handle~=f.lease or f.capture then return false,"busy" end
        f.capture={phase="waiting_neutral",reason="none",generation=long(21),revision=long(22),
            publications="0",neutral_releases="0",reads=0}
        return true
    end
    function s.input.lease_capture_state(handle)
        if handle~=f.lease or not f.capture then return nil,"unavailable" end
        local c=f.capture
        c.reads+=1
        -- Constructed: the second read reports the selected stream as captured.
        if c.phase=="waiting_neutral" and c.reads>1 then c.phase,c.publications="capturing","1" end
        return capture_row()
    end
    function s.input.lease_release_capture(handle)
        local c=f.capture
        if handle~=f.lease or not c or c.phase=="complete" then return false,"unavailable" end
        c.phase,c.reason,c.generation,c.revision,c.neutral_releases="complete","cancelled",long(23),long(24),c.publications
        return true
    end
    function s.input.lease_acknowledge_capture(handle)
        if handle~=f.lease or not f.capture or f.capture.phase~="complete" then return false,"busy" end
        f.capture_acked=true
        return true
    end
    local P=s.world.physics
    function P.reserve_follow() f.reserves+=1;return f.follow,nil end
    function P.read_follow()
        f.follow_reads+=1
        local following=f.published
        return {phase=following and "following" or "reserved",reason="none",park_reason="none",sequence="7",
            final_revision=following and "1" or "0",final_native_epoch=following and "5" or "0",
            returned_revision=following and "1" or "0",pending={},in_flight=0,claim_known=true,orphaned=false,
            park_observed=false,native_retirement_known=false,terminal=false}
    end
    function P.publish_follow() f.publishes+=1;f.published=true;return true end
    function P.read() f.body_reads+=1;return {serial=tostring(f.body_reads+1)} end
    function P.stop_follow() f.stops+=1;return true end
    function P.acknowledge_follow() return true end
    function P.release() return true end
    -- Spawn reports spawned after options.spawn_ticks updates.
    local spawn_status=Spawn.new({}):status()
    local owner={phase="armed",waits=options.spawn_ticks or 0}
    function owner:request() f.spawn_requests+=1;return true end
    function owner:update()
        if self.phase~="armed" then return end
        if self.waits>0 then self.waits-=1 else self.phase="spawned" end
    end
    function owner:status()
        local row=copy(spawn_status)
        row.phase,row.used,row.follow_handed_off=self.phase,true,self.phase=="follow_owned"
        row.visual_updates=f.visuals
        row.last_measurement={serial=long(f.body_reads+1),time=f.now/1000,seconds=1/60,
            position={1.125,.9123456789,-.05},rotation={0,0,0,1},velocity={.125,0,0},angular_velocity={0,0,0}}
        return row
    end
    function owner:handoff_follow() self.phase="follow_owned";return f.body,{serial="1"},nil end
    function owner:follow_visual() f.visuals+=1;return true end
    function owner:stop() self.phase="closed" end
    local state={phase="armed",detail="constructed armed owner",generation=1,cancel_version=1,calls={},counts={},
        receipts={},omitted_calls=0,omitted_receipts=0,remove_attempted={},remove_accepted={},used=true,
        ledger_owned=true,active=true,slot=f.slot,arm_at=f.now,level="sanvan",wipeouts=0}
    -- Retain real Equipment status fields and add an explicit constructed prior
    -- terminal record. This is serialization pressure, never transition proof.
    local original_equipment=Equipment.new
    Equipment.new=function(api)
        local owner=original_equipment(api)
        local original_status=owner.status
        function owner:status()
            local row=original_status(self)
            row.receipt,row.terminal_receipt=copy(history_receipt),copy(history_receipt)
            row.calls={request=1,read=64,cancel=1,acknowledge=1}
            return row
        end
        return owner
    end
    local made,core=pcall(Core.new,s,{qualification_only=true},state)
    Equipment.new=original_equipment
    assert(made,"constructed Core creation restores Equipment constructor on failure")
    local original=Spawn.new
    Spawn.new=function() return owner end
    local ok,bound=pcall(core.prepare_backend,core)
    Spawn.new=original
    assert(ok and bound==true,"constructed backend binds the real Source and the stand-in spawn owner")
    function f.step()
        f.now+=16
        local before=f.body_reads
        local out=core:step(16)
        return out,f.body_reads-before
    end
    -- Neutral ticks until Core reaches phase, or a stop.
    function f.until_phase(phase)
        local out=core:status()
        for _=1,200 do
            if out.phase==phase or out.stop_latched then break end
            out=f.step()
        end
        return out
    end
    function f.set_pad(edit)
        local pad=table.clone(f.pad);pad.buttons=table.clone(f.pad.buttons)
        edit(pad);f.pad=pad;f.serial+=1
    end
    return f,core,state
end

function Tests.run(runner)
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    check(reskate==nil and bmx_luau_runner==nil,"JSON helper is never a module global")
    check(type(runner)=="table" and table.isfrozen(runner) and type(runner.json_encode)=="function",
        "runner helper argument supplies only the standalone JSON encoder")
    check(getfenv(Forces.new).bmx_luau_runner==nil and getfenv(Core.new).bmx_luau_runner==nil,
        "imported production Force/Core modules have no ambient JSON helper")
    local encode=runner.json_encode
    local target_window_ms=2500
    local native_step_ms=Forces.native_seconds*1000
    local model_steps=math.ceil(target_window_ms/native_step_ms)
    local cf,core,state=source_fixture(encode)
    local ready=cf.until_phase("following")
    check(ready.phase=="following" and ready.source and ready.source.capture_state
        and ready.source.capture_state.phase=="capturing","real Source reaches constructed captured reports")
    check(ready.mount_enabled==false and ready.ride_composition_qualified==false,
        "production mount/Ride gates stay closed")
    -- Freeze the constructed Core owner on its quiescent branch. Source/Spawn
    -- retain their full cached status; no source, body or Follow execution is
    -- claimed during the separate Ride model window below.
    state.phase,state.active="done",false
    local start_ms=cf.now
    local f=RideTests.fixture()
    -- First observation closes the first constructed native interval [0,h].
    local model_start_time=0
    f.time=model_start_time+Forces.native_seconds
    f.serial,f.input_serial,f.ms,f.sequence=long(30000),long(40000),long(50000),long(60000)
    f.source_epoch=long(12)
    local raw_frame=f.frame
    function f.frame()
        local row=raw_frame()
        row.sample.sequence,row.sample.context_generation=long(11),long(13)
        return row
    end
    local raw_sample=f.sample
    function f.sample()
        local row=raw_sample()
        row.position=vector.create(.125,.9+.01*((f.model_step or 1)%7),-.05)
        return row
    end
    -- Native has one queued inbox. Applied rows may still await successor
    -- proof; deliberately retain three of those, never three queued requests.
    function f.on_receipt(sequence)
        local r=f.transactions[sequence]
        assert(r,"receipt uses an actually admitted fixture sequence")
        local applied=Identity.compare(f.serial,r.requested)>0
        local successor=applied and not f.withhold_successors and Identity.compare(f.serial,r.produced)>0 and f.sample() or nil
        return {sequence=sequence,requested_serial=r.requested,produced_serial=applied and r.produced or "0",
            outcome=applied and "applied" or "queued",force_attempted=applied,torque_attempted=applied,
            retained=false,quarantined=false,successor=successor,cleanup_disposition="none"}
    end
    local peak_bytes,peak_fields,saved_steps,peak_pending,bound_worst=0,0,0,0,0
    local function shape(record)
        local fields=0
        local function visit(value,depth)
            local kind=type(value)
            if kind=="table" then
                check(depth<8,"whole Core DTO remains within the actual copier depth bound")
                for key,child in pairs(value) do
                    fields+=1
                    check(type(key)=="string" or type(key)=="number","whole Core DTO uses permitted keys")
                    visit(child,depth+1)
                end
            elseif kind=="string" then check(#value<=1200,"diagnostic strings stay within copier bound")
            elseif kind=="number" then check(value==value and math.abs(value)<math.huge,"diagnostic numbers are finite")
            else check(kind=="nil" or kind=="boolean","no opaque value in whole Core DTO") end
        end
        visit(record,0)
        check(fields<=3000,"whole Core DTO stays within3000 fields before JSON encoding")
        peak_fields=math.max(peak_fields,fields)
    end
    local function fill_histories()
        -- Explicit constructed bounded-history pressure, not recorded gameplay.
        -- Each failed-call row has only its real error branch (no reason/accept).
        local detail=string.rep("bounded fixture diagnostic ",8):sub(1,180)
        state.calls={}
        for i=1,64 do state.calls[i]={call="world.physics.read_follow",at_ms=state.now-i,
            called=false,returns=0,first_type="string",error=detail} end
        state.receipts={}
        for i=1,16 do
            state.receipts[i]={phase="following",reason="none",park_reason="none",sequence=long(7),
                final_revision=long(i),final_native_epoch=long(i+100),returned_revision=long(i),pending={},
                in_flight=0,claim_known=true,orphaned=false,park_observed=false,native_retirement_known=false,terminal=false}
        end
        state.receipt=copy(state.receipts[16])
        state.lease_report_last={sequence=long(7),renewable=false,active=true,renewals="0",last_serial=long(30000),
            remaining_ms=3000,lifetime_remaining_ms=3000,base_ms=3000,renewal_ms=500,lifetime_ms=3000,
            revocation="none",dispatch_busy="0"}
    end
    local function persist_step(row,step)
        state.ride_status=row
        state.now=start_ms+step*native_step_ms
        fill_histories()
        state.persist_dirty=true
        local before=#cf.saves
        local out=core:step(native_step_ms)
        check(out.schema==1 and out.kind=="bike-lifecycle-v1" and out.phase~="retained_unknown"
            and out.storage_fault==false,"full Core schema survives copying and real encoding")
        check(#cf.saves==before+1,"actual Core persistence accepts one whole record with zero-return storage")
        local saved=cf.saves[#cf.saves]
        local dto=saved.record
        check(dto.schema==1 and dto.kind=="bike-lifecycle-v1" and dto.ride and dto.ride.metrics,
            "stored record contains the whole Core/Ride/metrics schema, never a small fallback")
        check(dto.source and dto.source.sample and dto.source.lease_state and dto.source.capture_state
            and dto.last_source_step and dto.spawn and dto.spawn.last_measurement
            and dto.equipment and dto.equipment.terminal_receipt,"full Source/Spawn/Equipment subtrees are measured")
        check(#dto.calls==64 and #dto.receipt_history==16,"both existing Core history caps are occupied")
        check(encode(dto.ride)==encode(row),"Core stores the actual Ride diagnostics without silent pruning")
        check(saved.bytes==#encode(dto) and saved.bytes<48000,"actual whole-record JSON bytes stay strictly below48000")
        shape(dto)
        peak_bytes=math.max(peak_bytes,saved.bytes)
        saved_steps+=1
    end
    cases+=1
    for step=1,model_steps do
        if step>1 then
            local old_serial,old_ms=f.input_serial,f.ms
            f.advance()
            if step%2==0 then f.input_serial,f.ms=old_serial,old_ms
            else f.ms=long(50000+math.floor((step-1)*native_step_ms)) end
        end
        f.now=step*native_step_ms
        f.model_step=step
        f.clear=math.floor(step/5)%2==1
        f.withhold_successors=step<=3 or step>=model_steps-2
        local row=f.observe()
        check(not row.stop_requested and not row.unknown,"each constructed model step remains valid")
        check(row.observed_steps==step and row.model_steps==step,"no missing or duplicate accepted body step")
        check(row.metrics and row.metrics.steps==step and row.metrics.samples_total==step,
            "new metrics count the actual processed sequence")
        peak_pending=math.max(peak_pending,row.pending_count)
        persist_step(row,step)
    end
    local row=f.ride:status()
    local m=row.metrics
    local model_span_ms=(f.time-model_start_time)*1000
    check(model_span_ms>=target_window_ms and (model_steps-1)*native_step_ms<target_window_ms
        and row.observed_steps==model_steps,"the smallest actual native-step sequence covers the target window")
    local fresh_steps=math.ceil(model_steps/2)
    check(m.fresh_report_steps==fresh_steps and m.steps_without_report==model_steps-fresh_steps and m.max_steps_without_report==1,
        "held input is measured separately from body advancement")
    check(m.report_gap_count==fresh_steps-1 and m.largest_report_gap_ms==34 and m.report_gap_unbounded==0,
        "exact long report clocks produce bounded observed gaps")
    check(m.samples_total==model_steps and #m.samples==24 and m.samples_omitted==model_steps-24,
        "sample ring is full with explicit historical omission")
    check(m.grounded_transition_total>16 and #m.grounded_transitions==16
        and m.grounded_transition_omitted==m.grounded_transition_total-16,
        "transition ring bounds preserve their explicit total and omissions")
    check(m.grounded_changes_with_report>0 and m.grounded_changes_without_report>0,
        "ground changes include both fresh and held reports")
    check(peak_pending==3 and row.pending_count==3 and m.inflight==3 and m.max_inflight==3,
        "the full record includes three actually admitted in-flight rows")
    check(m.submitted_count==row.submitted and m.applied_count>0 and m.applied_count<=m.submitted_count,
        "submit and first-application counters reflect actual fixture transactions")
    check(#row.pending_commands==3 and #row.pending_commands[1].sequence==20,
        "three pending rows retain exact long identity strings")
    local window_records=saved_steps
    check(window_records==model_steps and state.storage_fault~=true,"every model-window persistence was accepted")
    cases+=1
    local reasons={"ledger fixture completed","force receipt watchdog expired",
        "force body parked without successor","force body retained or quarantined",
        "force acknowledgement outcome unknown","applied successor incoherent"}
    local key_bytes=0
    for _,why in ipairs(reasons) do key_bytes+=#encode(why) end
    local function escaped_reason(prefix,bytes)
        -- Include both short and six-byte escapes, unescaped slash/DEL and
        -- multibyte UTF-8. The actual SDK-compatible writer sizes each key.
        local value=prefix..'"\\\b\t\n\f\r\0\1/'..string.char(127,0xC3,0xA9)
        local remaining=bytes-#encode(value)
        assert(remaining>=0,"constructed escaped key target has room")
        return value..string.rep("x",remaining)
    end
    local seventh_bytes=math.floor((1024-key_bytes)/2)
    reasons[7]=escaped_reason("escaped cleanup A:",seventh_bytes)
    reasons[8]=escaped_reason("escaped cleanup B:",1024-key_bytes-seventh_bytes)
    for _,why in ipairs(reasons) do f.ride:stop(why) end
    f.ride:stop(reasons[2]);f.ride:stop(reasons[2])
    f.ride:stop("overflow cleanup reason");f.ride:stop("overflow cleanup reason")
    f.ride:stop(string.char(0xFF))
    local stopped_pending=f.ride:status()
    local keys,bytes=0,0
    for why in pairs(stopped_pending.metrics.stop_counts) do keys+=1;bytes+=#encode(why) end
    check(keys==8 and bytes==1024 and stopped_pending.metrics.stop_counts_overflow==3,
        "eight exact keys fill the encoded budget, with every excess or malformed occurrence counted")
    check(stopped_pending.issue==reasons[1] and stopped_pending.metrics.stop_counts[reasons[2]]==3,
        "later repeated cleanup causes are counted without replacing the first issue")
    check(stopped_pending.pending_count==3 and #stopped_pending.metrics.samples==24
        and #stopped_pending.metrics.grounded_transitions==16,"full stop counters coexist with all pending rows and both rings")
    persist_step(stopped_pending,model_steps+1)
    f.withhold_successors=false
    f.advance(2)
    f.now=(f.time-model_start_time)*1000
    local stopped=f.ride:drain()
    check(stopped.stop_requested and not stopped.force_pending and not stopped.unknown,
        "late exact successors drain the constructed window")
    check(stopped.metrics.stop_counts[reasons[1]]==1,"the initial stop occurrence remains recorded")
    f.ride:stop(reasons[2]);f.ride:stop("later stop request")
    stopped=f.ride:status()
    check(stopped.metrics.stop_counts[reasons[2]]==4 and stopped.metrics.stop_counts_overflow==4,
        "retained reasons and overflow occurrences keep counting during later cleanup")
    persist_step(stopped,model_steps+2)
    check(core:request_stop("Core fixture terminal save"),"the real Core forced-stop persistence path runs")
    check(state.storage_fault~=true and cf.saves[#cf.saves].record.ride.metrics.stop_counts["ledger fixture completed"]==1,
        "terminal persistence retains full Ride metrics")
    for _,saved in ipairs(cf.saves) do
        check(saved.record.schema==1 and saved.record.kind=="bike-lifecycle-v1"
            and saved.record.phase~="retained_unknown" and saved.bytes==#encode(saved.record)
            and saved.bytes<48000,"every accepted startup/window/terminal record uses full schema and actual bounded bytes")
        -- Core skips its size-check encode only under this bound; it must cover the actual writer.
        local bound=Core.ledger_bound(saved.record)
        check(bound==nil or bound>=saved.bytes,"the ledger bound covers the actual bytes: "..tostring(bound).." "..saved.bytes)
        bound_worst=math.max(bound_worst,bound and bound/saved.bytes or 0)
        peak_bytes=math.max(peak_bytes,saved.bytes)
    end
    check(bound_worst>=1 and bound_worst<1.5,"bounds are found and within half again of the bytes: "..bound_worst)
    cases+=1
    -- Positive size checks above cannot pass via a constant fake encoder: add
    -- bounded strings, below copier limits, that push the actual bytes overcap.
    state.ride_status=copy(stopped)
    state.ride_status.oversized_fixture={}
    for i=1,40 do state.ride_status.oversized_fixture[i]=string.rep("x",1200) end
    local too_large=core:status()
    check(too_large.schema==1 and too_large.phase~="retained_unknown" and #encode(too_large)>48000,
        "negative byte fixture reaches JSON and exceeds48000 without failing the copier")
    local before=#cf.saves
    core:request_stop("oversized diagnostic fixture")
    check(state.storage_fault==true and #cf.saves==before,"real byte cap rejects oversized persistence without truncation")
    cases+=1
    state.ride_status.oversized_fixture={}
    for i=1,3001 do state.ride_status.oversized_fixture[i]=true end
    check(core:status().phase=="retained_unknown","the size test recognizes and rejects copier-fallback records")
    return {cases=cases,assertions=assertions,native_actions=0,target_window_ms=target_window_ms,
        model_span_ms=model_span_ms,model_steps=model_steps,persisted_window_records=window_records,
        measured_ride_records=saved_steps,peak_ledger_bytes=peak_bytes,peak_fields=peak_fields}
end
return Tests
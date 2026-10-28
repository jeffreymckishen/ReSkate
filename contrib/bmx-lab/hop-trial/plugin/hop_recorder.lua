-- Private trial evidence only. No game calls, native polling or Core ledger writes.
-- The wrapper supplies observations from calls it already made; these copies
-- confer no authority and cannot establish native consumption or retirement.
local Codec = require("./hop_evidence_codec")
local Recorder = {codec=Codec}
local Object = {} Object.__index = Object
local states = setmetatable({}, {__mode="k"})
local LIMITS = table.freeze({regular_rows=2048, regular_bytes=512*1024,
    critical_rows=128, critical_bytes=128*1024, summary_bytes=16*1024,
    row_bytes=12*1024, chunk_bytes=24*1024, chunk_rows=16, text_bytes=192})
Recorder.limits = LIMITS

local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function fields(names, kind, out)
    out=out or {}
    for name in string.gmatch(names,"%S+") do out[name]=kind end
    return out
end
local function list(item, limit) return {item=item, limit=limit} end
local function merge(a,b)
    local out={}
    for k,v in pairs(a) do out[k]=v end
    for k,v in pairs(b) do out[k]=v end
    return out
end
local function schema(text, numbers, flags)
    return fields(flags or "","boolean",fields(numbers or "","number",fields(text or "","text")))
end
local identity=fields("generation user packet","number",fields(
    "sequence source_epoch context_generation observation_serial observed_ms","id"))
local pad=fields("left_x left_y right_x right_y left_trigger right_trigger","number",{playstation="boolean",
    buttons=fields("up down left right start back left_stick right_stick lb rb a b x y","boolean")})
local source=merge(identity,schema("phase reason",nil,"input_ok neutral new_observation cleanup_pending cleanup_unknown"))
source.pad=pad
local body=fields("position velocity angular_velocity inertia","vec3",schema(nil,"time seconds mass",nil))
body.serial="id";body.rotation="vec4"
local model_body=fields("center_of_mass linear_velocity angular_velocity inertia_body","vec3",{mass="number",orientation="vec4"})
local support=fields("point normal surface_velocity","vec3",schema("provenance reason",nil,"known grounded_known grounded"))
local query=schema("status reason requested_query_preset actor_lane","native_casts",
    "epoch_matches accounting_known measurements_complete budget_exhausted local_actor_excluded owned_bodies_excluded named_actor_categories_absent")
local ray=fields("position normal surface_velocity","vec3",schema("status motion","fraction",
    "visual_hit normal_available surface_velocity_available"))
local wheel_contact=fields("point normal forward surface_velocity","vec3",{status="text"})
local wheel_sample={contact=wheel_contact,separation="number",verified_plane="boolean",
    balance_normal_available="boolean",balance_normal="vec3"}
local wheel=fields("radius inertia angular_speed","number")
local controls=schema("disposition", "hop_event_id hop_strength pedal steer brake", "hop rotation_reserved")
controls.pending_hop=merge(identity,{id="number",strength="number"})
local force_model=fields("force torque linear_impulse angular_impulse hop_impulse","vec3",
    schema("issue","hop_event_id contact_scale","valid grounded hop_applied diagnostic_only force_applied"))
force_model.wheels=list(wheel,2)
local preview_model=merge(force_model,{diagnostic=force_model})
local command_state=fields("sequence serial","id",schema("outcome",nil,"ack_attempted acknowledged unknown"))
local force_pending=fields("pending_sequence last_serial","id",schema("phase issue",
    "pending_count pending_limit submitted acknowledged observed_steps model_steps","force_pending unknown stop_requested ack_attempted"))
force_pending.pending_commands=list(command_state,3)
force_pending.hop_disposition={id="number",disposition="text",confirmed="boolean"}
local receipt=fields("sequence requested_serial produced_serial","id",schema("outcome cleanup_disposition",nil,
    "force_attempted torque_attempted retained quarantined successor_available"))
receipt.successor=body
local follow=fields("sequence final_revision final_native_epoch returned_revision","id",schema("phase reason park_reason",
    "in_flight","claim_known orphaned park_observed native_retirement_known terminal"))
follow.pending=list("text",1)
local lease=fields("sequence renewals last_serial","id",schema("revocation",
    "remaining_ms lifetime_remaining_ms base_ms renewal_ms lifetime_ms","renewable active"))
local pose_plan={at_ms="number",hips="vec3",wrists=list("vec3",2),ankles=list("vec3",2)}
local pose=schema("state reason issue trick_scope","blend weight sends ends last_sent mount_ms mounted_ms ticks sent_ticks nil_calls",
    "qualified stopped nil_accepted capability")
pose.plan=pose_plan
local common=schema("call reason", "arity", "call_ok result")
common.serial="id";common.sequence="id"
local event_schemas={
    source=source, body=body,
    contact=merge(schema("status reason force_reason",nil,"valid force_ready"),
        {query=query,support=support,rays=list(ray,32),samples=list(wheel_sample,2)}),
    force_pending=force_pending, mapped_hop=controls,
    preview={seconds="number",body=model_body,controls=controls,model=preview_model},
    submit=fields("force torque impulse","vec3",{impulse_id="number"}),
    receipt=receipt, ack=schema("reason",nil,"acknowledged"), pose=pose, follow=follow, lease=lease,
}
for name, shape in pairs(event_schemas) do event_schemas[name]=merge(common,shape) end
-- Preparation has no body, command or Follow identity to record.
event_schemas.prepare=schema("call reason phase","arity arguments","call_ok result")
local preparation=schema("phase reason scope","attempts ready_ms")

local lease_state=fields("sequence source_epoch context_generation requested_ms expires_ms observed_ms last_observation renewals","id",
    schema("phase status reason", "user", "terminal source_released capture_reserved orphaned capturing report_debt"))
local capture=fields("sequence source_epoch context_generation generation revision expires_ms publications neutral_releases","id",
    schema("phase reason","user","terminal quarantined capturing report_debt"))
event_schemas.lease=merge(event_schemas.lease,merge(lease_state,capture))
local source_state=merge(schema("phase reason","generation","input_ok new_observation lease_handle_present cleanup_pending cleanup_unknown"),
    {sample=source,lease_state=lease_state,capture_state=capture})
local subordinate=schema("phase outcome reason detail",nil,"retained cleanup_pending cleanup_unknown unknown acknowledged unloaded qualified_transition")
local terminal_schema=schema("phase detail stop_reason equipment_purpose", "wall_ms stop_ms selected_slot mount_deadline_ms",
    "stop_latched unloaded bike_authority cleanup_pending cleanup_unknown bike_cleanup_complete stock_toggle_blocked "..
    "force_cleanup_clear force_cleanup_unknown handoff_unknown reserve_unknown marker_unknown retained_reload_marker "..
    "stock_requested acknowledge_attempted acknowledged completed_acknowledged ordinary_release_attempted ordinary_release_accepted "..
    "visual_cleanup_deferred storage_fault clock_unknown")
terminal_schema.native_preparation=preparation
terminal_schema.source=source_state;terminal_schema.last_source_step=source_state
terminal_schema.ride=merge(force_pending,{receipt=receipt})
terminal_schema.receipt=follow;terminal_schema.terminal_receipt=follow
terminal_schema.mounted_pose=pose;terminal_schema.spawn=subordinate;terminal_schema.equipment=subordinate
terminal_schema.board_return=merge(subordinate,{pending="boolean"})
terminal_schema.board_drop=schema("state reason issue toss_result clear_result bones_result",
    "toss_calls clear_calls bones_calls drop_ms restore_ms", "tried restore_tried restore_pending drop_inflight restore_inflight")

-- Count a conservative compact JSON upper bound while copying only named fields.
-- Numbers get 32 bytes; string controls, quotes and non-ASCII bytes get six each.
-- Keys below are fixed ASCII names. No user table is enumerated or stringified.
local function spend(b,n)
    b.bytes+=n;b.nodes+=1
    if b.bytes>b.limit or b.nodes>768 then b.lost=true;b.full=true;return false end
    return true
end
local function bad(b) b.lost=true;return nil end
local function string_cost(v)
    local n=2
    for i=1,#v do
        local c=string.byte(v,i)
        n+=((c<32 or c==34 or c==92 or c>=127) and 6 or 1)
    end
    return n
end
-- All numeric output keys are vectors or schema lists bounded to32. Count
-- canonical DATA keys, independently of the unchanged legacy spend below.
local function canonical_index_bytes(index) return index<10 and 5 or 6 end
local copy
copy=function(value,shape,b)
    if value==nil or b.full then return nil end
    if shape=="number" then
        if not finite(value) then return bad(b) end
        if spend(b,32) then return value,32 end
    elseif shape=="boolean" then
        if type(value)~="boolean" then return bad(b) end
        if spend(b,5) then return value,5 end
    elseif shape=="text" or shape=="id" then
        if type(value)~="string" then return bad(b) end
        if shape=="id" then
            if #value<1 or #value>20 or not string.match(value,"^%d+$") then return bad(b) end
        elseif #value>LIMITS.text_bytes then
            b.lost=true;value=string.sub(value,1,LIMITS.text_bytes)
        end
        local bytes=string_cost(value)
        if spend(b,bytes) then return value,bytes end
    elseif shape=="vec3" or shape=="vec4" then
        local count=shape=="vec3" and 3 or 4
        local native=typeof(value)=="vector"
        if not native and not plain(value) or native and count~=3 then return bad(b) end
        local out={}
        if not spend(b,2) then return nil end
        local canonical=2
        for i=1,count do
            local v
            if native then v=(i==1 and value.x or i==2 and value.y or value.z)
            else
                v=rawget(value,i)
                if v==nil and count==3 then v=rawget(value,({"x","y","z"})[i]) end
            end
            if not finite(v) or not spend(b,33) then return bad(b) end
            out[i]=v;canonical+=canonical_index_bytes(i)+32
        end
        return table.freeze(out),canonical
    else
        if not plain(value) then return bad(b) end
        if not spend(b,2) then return nil end
        local out={}
        local canonical=2
        if shape.item then
            local count=#value
            if count>shape.limit then b.lost=true;count=shape.limit end
            for i=1,count do
                local item=rawget(value,i)
                if item==nil then b.lost=true;break end
                local v,bytes=copy(item,shape.item,b)
                if v==nil then break end
                local index=#out+1;out[index]=v
                canonical+=canonical_index_bytes(index)+bytes
                if not spend(b,1) then break end
            end
        else
            for name,kind in pairs(shape) do
                if b.full then break end
                local raw=rawget(value,name)
                if raw~=nil and spend(b,#name+4) then
                    local v,bytes=copy(raw,kind,b)
                    out[name]=v
                    if v~=nil then canonical+=#name+4+bytes end
                end
            end
        end
        return table.freeze(out),canonical
    end
    return nil
end
local function sanitized(value,shape,limit)
    local b={bytes=0,nodes=0,limit=limit}
    local out,canonical=copy(value,shape,b)
    return out,b,canonical
end
-- Both arguments are our bounded, detached plain copies, never caller tables.
local function same(a,b)
    if type(a)=="number" and type(b)=="number" and a==0 and b==0 then return 1/a==1/b end
    if a==b then return true end
    if type(a)~="table" or type(b)~="table" then return false end
    for k,v in pairs(a) do if not same(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function fault(s,why)
    if s.unload_scope and s.unload_writer_spent and not s.interrupted then
        s.interrupted=true;s.version+=1
    end
    if not s.observation_loss or not s.stop_requested or not s.first_fault then s.version+=1 end
    s.observation_loss=true;s.stop_requested=true;s.first_fault=s.first_fault or why
end
-- A spent unload writer cannot certify facts that arrived after its snapshot.
-- Retention still records them; only completion is revoked, without another I/O.
local function unload_tail_changed(s)
    if s.unload_scope and s.unload_writer_spent then fault(s,"unload_tail_changed") end
end
local function begin_unload(s)
    if s.unload_scope then return end
    s.unload_scope=true
    if s.busy then
        -- The already entered normal writer consumes this same lifecycle budget.
        s.unload_writer_spent=true;fault(s,"unload_writer_in_flight")
    end
end
local function get(self) return assert(states[self],"unknown hop recorder") end
local function known_identity(kind,row)
    if kind=="terminal" then return true end
    if kind=="follow" or kind=="lease" then return row.sequence~=nil end
    if kind=="receipt" then return row.sequence~=nil and row.requested_serial~=nil end
    if kind=="source" then return row.sequence~=nil and row.observation_serial~=nil end
    return false
end
local function capacity_fault(s,critical,why)
    s.dropped+=1;fault(s,why or (critical and "critical_capacity" or "regular_capacity"))
    return false,s.first_fault
end
local function encoded_time(value)
    if value==nil then return false end
    if value==0 and 1/value==-math.huge then return "-0" end
    return value
end
local function retained_row(s,entry)
    if not entry.critical then
        local base=s.bases[entry.key]
        return base and base.first_call==entry.first_call and base or nil
    end
    return Codec.decode_row(entry.wire)
end
local function retain(s,kind,data,canonical_bytes,critical,at_ms,incomplete)
    s.calls+=1;s.version+=1;unload_tail_changed(s)
    local slot=kind=="lease" and (data.call=="input.lease_state" and 1 or data.call=="input.lease_capture_state" and 2) or nil
    local eligible=slot and not critical and not incomplete and Codec.pair_data_known(data)
    local prior=s.last[kind]
    local previous=prior and retained_row(s,prior)
    if not incomplete and known_identity(kind,data) and prior and previous and not prior.flushed and not prior.writing
        and prior.critical==critical and not prior.wire[12] and same(previous.data,data) then
        -- Replacing the positional occurrence metadata is itself an admission.
        -- A writer's frozen row and all encoded bases stay immutable.
        local wire={};for i=1,12 do wire[i]=prior.wire[i] end
        wire[6]=s.calls;wire[7]=prior.repeats+1;wire[9]=encoded_time(at_ms)
        local size=Codec.wire_bytes(wire)
        if not size or size>LIMITS.row_bytes then return capacity_fault(s,critical,"invalid_encoding") end
        local used=critical and s.critical_bytes or s.regular_bytes
        local cap=critical and LIMITS.critical_bytes or LIMITS.regular_bytes
        if used+size-prior.bytes>cap then return capacity_fault(s,critical) end
        if critical then s.critical_bytes+=size-prior.bytes
        else s.regular_wire_bytes+=size-prior.bytes;s.regular_bytes+=size-prior.bytes end
        prior.wire=table.freeze(wire);prior.bytes=size;prior.repeats+=1;prior.last_call=s.calls;prior.last_at_ms=at_ms
        if not critical then
            local cached={};for k,v in pairs(previous) do cached[k]=v end
            cached.last_call=s.calls;cached.repeats=prior.repeats;cached.last_at_ms=at_ms
            s.bases[prior.key]=table.freeze(cached)
        end
        if slot then s.pair_candidates[slot]=false end
        s.coalesced+=1;return true,"coalesced"
    end
    local candidate=eligible and s.pair_candidates[slot]
    if candidate and not plain(candidate) then return capacity_fault(s,false,"invalid_pair_state") end
    if candidate and not candidate.flushed and not candidate.writing then
        local key=kind.."|"..data.call
        local cached=s.bases[key]
        local old_state=cached and Codec.state_bytes(cached)
        local old_wire=Codec.wire_bytes(candidate.wire)
        -- Refuse malformed private bookkeeping before any arithmetic or mutation.
        -- Frozen original wire nodes retain their already-admitted historical ref.
        if candidate.key~=key or candidate.kind~=kind or candidate.critical~=false or candidate.repeats~=1
            or candidate.first_call~=candidate.last_call or not finite(old_state) or not finite(old_wire)
            or old_state<0 or old_wire<0 or old_state%1~=0 or old_wire%1~=0 or old_wire>LIMITS.row_bytes
            or not table.isfrozen(candidate.wire) or candidate.bytes~=old_wire or s.base_bytes[key]~=old_state
            or cached.kind~=kind or cached.critical~=false or cached.incomplete~=false or cached.paired~=nil or cached.repeats~=1
            or cached.first_call~=candidate.first_call or cached.last_call~=candidate.last_call
            or not same(cached.first_at_ms,candidate.first_at_ms) or not same(cached.last_at_ms,candidate.last_at_ms)
            or not same(candidate.first_at_ms,candidate.last_at_ms)
            or candidate.wire[1]~=false or candidate.wire[2]~=12 or candidate.wire[3]~=data.call
            or candidate.wire[5]~=candidate.first_call or candidate.wire[6]~=candidate.last_call or candidate.wire[7]~=1
            or not same(candidate.wire[8],encoded_time(candidate.first_at_ms)) or not same(candidate.wire[9],encoded_time(candidate.last_at_ms))
            or candidate.wire[10]~=false or candidate.wire[12]~=false
            or candidate.wire[4]~=0 and candidate.wire[4]>=candidate.first_call
            or not finite(s.regular_wire_bytes) or not finite(s.regular_state_bytes) or not finite(s.regular_bytes)
            or s.regular_wire_bytes<0 or s.regular_state_bytes<Codec.pair_pointer_bytes
            or s.regular_bytes~=s.regular_wire_bytes+s.regular_state_bytes then
            return capacity_fault(s,false,"invalid_pair_state")
        end
        if same(cached.data,data) then
            -- Every fallible size/metadata operation precedes mutation. Reuse
            -- the immutable DTO and add only the exact second endpoint.
            local wire={};for i=1,12 do wire[i]=candidate.wire[i] end
            wire[6]=s.calls;wire[7]=2;wire[9]=encoded_time(at_ms);wire[12]=true
            local next_cached={};for k,v in pairs(cached) do next_cached[k]=v end
            next_cached.last_call=s.calls;next_cached.repeats=2;next_cached.last_at_ms=at_ms;next_cached.paired=true
            local size=Codec.wire_bytes(wire)
            local state_size=Codec.state_bytes(next_cached)
            if not finite(size) or not finite(state_size) or size<0 or state_size<0 or size%1~=0 or state_size%1~=0
                or size>LIMITS.row_bytes then return capacity_fault(s,false,"invalid_encoding") end
            local wire_delta=size-old_wire
            local state_delta=state_size-old_state
            if s.regular_bytes+wire_delta+state_delta>LIMITS.regular_bytes then return capacity_fault(s,false) end
            local frozen_wire=table.freeze(wire);local frozen_cached=table.freeze(next_cached)
            candidate.wire=frozen_wire;candidate.bytes=size;candidate.repeats=2;candidate.last_call=s.calls;candidate.last_at_ms=at_ms
            s.bases[key]=frozen_cached;s.base_bytes[key]=state_size
            s.regular_wire_bytes+=wire_delta;s.regular_state_bytes+=state_delta
            s.regular_bytes=s.regular_wire_bytes+s.regular_state_bytes
            s.last[kind]=candidate;s.pair_candidates[slot]=false
            s.coalesced+=1;return true,"paired"
        end
    end
    local rows=critical and s.critical or s.regular
    local cap=critical and LIMITS.critical_rows or LIMITS.regular_rows
    if #rows>=cap then return capacity_fault(s,critical) end
    local row={kind=kind,data=data,first_call=s.calls,last_call=s.calls,repeats=1,
        first_at_ms=at_ms,last_at_ms=at_ms,incomplete=incomplete==true,critical=critical==true}
    local call=rawget(data,"call") or ""
    local key=kind.."|"..call
    local base;if not critical then base=s.bases[key] end
    local wire,size=Codec.encode_row(row,base)
    if not wire then return capacity_fault(s,critical,"invalid_encoding") end
    local state_size
    if critical then
        if s.critical_bytes+size>LIMITS.critical_bytes then return capacity_fault(s,true) end
    else
        -- encode_row has already fully validated the same copied DATA. The
        -- count comes only from our private sanitizer/transition construction.
        if not finite(canonical_bytes) or canonical_bytes%1~=0 or canonical_bytes<2
            or canonical_bytes>LIMITS.row_bytes-384 then return capacity_fault(s,false,"invalid_encoding") end
        state_size=canonical_bytes+64+string_cost(kind)+string_cost(call)
        local projected=s.regular_bytes+size+state_size-(s.base_bytes[key] or 0)
        if projected>LIMITS.regular_bytes or not base and s.base_count>=64 then return capacity_fault(s,false) end
    end
    local entry={wire=wire,key=key,kind=kind,bytes=size,critical=critical,flushed=false,
        first_call=s.calls,last_call=s.calls,repeats=1,first_at_ms=at_ms,last_at_ms=at_ms}
    rows[#rows+1]=entry;s.last[kind]=entry
    if critical then s.critical_bytes+=size
    else
        if not base then s.base_count+=1 end
        s.regular_state_bytes+=state_size-(s.base_bytes[key] or 0)
        s.base_bytes[key]=state_size;s.bases[key]=table.freeze(row)
        s.regular_wire_bytes+=size;s.regular_bytes=s.regular_wire_bytes+s.regular_state_bytes
    end
    if slot then s.pair_candidates[slot]=eligible and entry or false end
    return not incomplete,incomplete and "observation_loss" or "recorded"
end
-- Call with the real storage.set function and a fresh private run's ASCII ID.
-- The caller must use a fresh private package/store; this module never reads,
-- deletes or overwrites prior runs intentionally, and performs no admission I/O.
function Recorder.new(storage_set,run_id)
    assert(type(storage_set)=="function","storage.set function required")
    assert(type(run_id)=="string" and #run_id>=1 and #run_id<=32 and
        string.match(run_id,"^[A-Za-z0-9_-]+$"),"fresh run ID must be 1..32 ASCII letters, digits, _ or -")
    local self=setmetatable({},Object)
    states[self]={writer=storage_set,run_id=run_id,regular={},critical={},last={},regular_bytes=Codec.pair_pointer_bytes,critical_bytes=0,pair_candidates={false,false},
        bases={},base_bytes={},base_count=0,regular_wire_bytes=0,regular_state_bytes=Codec.pair_pointer_bytes,store_bytes=2,
        regular_next=1,critical_next=1,calls=0,coalesced=0,dropped=0,chunks=0,stored_rows=0,
        latest_revision=0,version=0,saved_revision=-1,cleanup_observed=false,unresolved_debt=true,
        observation_loss=false,stop_requested=false,storage_fault=false,stopping=false,busy=false}
    return table.freeze(self)
end
function Object:append(kind,payload)
    local s=get(self)
    local shape=type(kind)=="string" and event_schemas[kind]
    if not shape or not plain(payload) then fault(s,"invalid_event");return false,"invalid_event" end
    local data,b,canonical_bytes=sanitized(payload,shape,LIMITS.row_bytes-384)
    local at_ms=rawget(payload,"at_ms")
    if at_ms~=nil and not finite(at_ms) then b.lost=true;at_ms=nil end
    if b.lost or not data then fault(s,"invalid_observation") end
    local critical=s.stopping or s.stop_requested or (data and (data.unknown==true or data.quarantined==true or data.terminal==true or data.call_ok==false))
    if data==nil then data=table.freeze({});canonical_bytes=2 end
    return retain(s,kind,data,canonical_bytes,critical,at_ms,b.lost==true)
end
local function board_debt(board)
    return board~=nil and (board.restore_pending==true or board.drop_inflight==true or board.restore_inflight==true
        or board.state=="unknown" or board.state=="restore_unknown" or board.state=="dropped")
end
local function pose_debt(pose_row)
    return pose_row~=nil and (((pose_row.sends or 0)>0 and (pose_row.stopped~=true or pose_row.nil_accepted~=true))
        or (pose_row.nil_calls or 0)>0 and pose_row.nil_accepted~=true)
end
local function debt(snapshot)
    if snapshot.cleanup_pending~=false or snapshot.cleanup_unknown~=false or snapshot.bike_authority~=false then return true end
    if snapshot.force_cleanup_unknown==true or snapshot.handoff_unknown==true or snapshot.reserve_unknown==true
        or snapshot.marker_unknown==true or snapshot.retained_reload_marker==true then return true end
    local ride=snapshot.ride
    if ride and (ride.force_pending~=false or ride.unknown~=false or (ride.pending_count or 0)>0) then return true end
    local src=snapshot.source
    if src and (src.cleanup_pending~=false or src.cleanup_unknown~=false or src.lease_handle_present==true) then return true end
    if src and src.capture_state and (src.capture_state.report_debt==true or src.capture_state.quarantined==true) then return true end
    if snapshot.equipment and (snapshot.equipment.retained==true or snapshot.equipment.unknown==true) then return true end
    if board_debt(snapshot.board_drop) or pose_debt(snapshot.mounted_pose) then return true end
    return false
end
local function terminal_same(a,b)
    if not a or not b then return false end
    for k,v in pairs(a) do if k~="wall_ms" and not same(v,b[k]) then return false end end
    for k in pairs(b) do if k~="wall_ms" and a[k]==nil then return false end end
    return true
end
function Object:terminal(snapshot)
    local s=get(self)
    local row,b=sanitized(snapshot,terminal_schema,LIMITS.summary_bytes-4096)
    if not row or b.lost then fault(s,"invalid_terminal_snapshot") end
    -- Latest raw copied flags remain independent of both event capacities.
    local changed=not terminal_same(s.latest,row)
    s.latest=row or table.freeze({});s.cleanup_observed=true
    -- Repeated cached terminal ticks update the latest wall time in memory,
    -- without making an already saved semantic snapshot perpetually dirty.
    if changed then s.latest_revision+=1;s.version+=1;unload_tail_changed(s) end
    s.unresolved_debt=b.lost==true or debt(s.latest)
    local board=s.latest.board_drop
    s.board_restore_unresolved=board_debt(board);s.pose_release_unresolved=pose_debt(s.latest.mounted_pose)
    s.cleanup_unknown_seen=s.cleanup_unknown_seen==true or s.latest.cleanup_unknown==true or b.lost==true
        or (board~=nil and (board.state=="unknown" or board.state=="restore_unknown"))
    if s.latest.stop_latched==true then s.stopping=true end
    local t=s.latest
    local transition={phase=t.phase,stop_reason=t.stop_reason,stop_latched=t.stop_latched,
        bike_authority=t.bike_authority,cleanup_pending=t.cleanup_pending,cleanup_unknown=t.cleanup_unknown,
        bike_cleanup_complete=t.bike_cleanup_complete,force_cleanup_clear=t.force_cleanup_clear,
        force_cleanup_unknown=t.force_cleanup_unknown,acknowledged=t.acknowledged,
        completed_acknowledged=t.completed_acknowledged,unresolved_debt=s.unresolved_debt,
        board_state=board and board.state,board_reason=board and board.reason,board_issue=board and board.issue,
        board_restore_pending=board and board.restore_pending,board_drop_inflight=board and board.drop_inflight,
        board_restore_inflight=board and board.restore_inflight,board_restore_unresolved=s.board_restore_unresolved,
        pose_release_unresolved=s.pose_release_unresolved}
    table.freeze(transition)
    if s.last_terminal and same(s.last_terminal,transition) then return not b.lost,"snapshot_updated" end
    s.last_terminal=transition
    local transition_bytes=2
    for name,value in pairs(transition) do
        transition_bytes+=#name+4+(type(value)=="string" and string_cost(value) or type(value)=="number" and 32 or 5)
    end
    return retain(s,"terminal",transition,transition_bytes,s.stopping,t.wall_ms,b.lost==true)
end
local function summary(s)
    return table.freeze({schema=1,encoding=Codec.encoding,kind="hop-trial-evidence",run_id=s.run_id,
        observation_loss=s.observation_loss,unqualified=s.observation_loss or s.storage_fault or s.unresolved_debt or s.cleanup_unknown_seen==true,
        stop_requested=s.stop_requested,first_fault=s.first_fault,storage_fault=s.storage_fault,storage_error=s.storage_error,
        interrupted=s.interrupted==true,emergency_attempted=s.emergency_attempted==true,
        final_snapshot_unavailable=s.final_snapshot_unavailable==true,
        calls=s.calls,coalesced=s.coalesced,dropped=s.dropped,regular_rows=#s.regular,critical_rows=#s.critical,
        regular_bytes=s.regular_bytes,critical_bytes=s.critical_bytes,
        regular_wire_bytes=s.regular_wire_bytes,regular_state_bytes=s.regular_state_bytes,chunks=s.chunks,stored_rows=s.stored_rows,
        cleanup_observed=s.cleanup_observed,unresolved_debt=s.unresolved_debt,cleanup_unknown_seen=s.cleanup_unknown_seen==true,
        board_restore_unresolved=s.board_restore_unresolved==true,pose_release_unresolved=s.pose_release_unresolved==true,
        latest_revision=s.latest_revision,latest=s.latest,
        storage_scope="Host cache acceptance only; disk durability unobserved.",
        native_qualified=false,native_retirement_known=false})
end
function Object:status()
    local s=get(self)
    local out={summary=summary(s),stop_requested=s.stop_requested,observation_loss=s.observation_loss,
        unqualified=s.observation_loss or s.storage_fault or s.unresolved_debt or s.cleanup_unknown_seen==true,
        storage_fault=s.storage_fault,first_fault=s.first_fault,latest=s.latest,
        interrupted=s.interrupted==true,emergency_cached=s.emergency_cached==true,
        regular_rows=#s.regular,critical_rows=#s.critical,dropped=s.dropped,coalesced=s.coalesced,
        stored_rows=s.stored_rows,chunks=s.chunks,unresolved_debt=s.unresolved_debt,
        flushed=s.regular_next>#s.regular and s.critical_next>#s.critical and s.saved_revision==s.version and not s.storage_fault and not s.interrupted}
    return table.freeze(out)
end
local function row_copy(entry)
    -- The codec recursively freezes data nodes; copy/freeze the occurrence
    -- header so a reentrant storage callback cannot mutate retained history.
    local out={};for i=1,12 do out[i]=entry.wire[i] end
    return table.freeze(out)
end
-- One storage call at most. The wrapper must witness actual terminal/watchdog
-- inactivity; a recorder overflow alone is never that witness. Unknown cleanup
-- is saved faithfully, not used to suppress evidence or authorize a restart.
function Object:flush(gate)
    local s=get(self)
    if not plain(gate) or rawget(gate,"inactive")~=true or rawget(gate,"terminal")~=true then return false,"active" end
    if s.unload_scope then return false,"unload" end
    if s.busy then return false,"busy" end
    if s.storage_fault then return false,"storage_fault" end
    if s.interrupted then return false,"interrupted" end
    if not s.cleanup_observed then return false,"terminal_unobserved" end
    local ri,ci=s.regular_next,s.critical_next
    local picked,rows,bytes={},{},1024
    while #rows<LIMITS.chunk_rows do
        local a,b=s.regular[ri],s.critical[ci]
        local next_row=(not b or a and a.first_call<b.first_call) and a or b
        if not next_row or bytes+next_row.bytes>LIMITS.chunk_bytes then break end
        picked[#picked+1]=next_row;rows[#rows+1]=row_copy(next_row);bytes+=next_row.bytes
        if next_row==a then ri+=1 else ci+=1 end
    end
    local key,value,revision
    if #rows>0 then
        key="hop."..s.run_id..".chunk."..tostring(s.chunks+1)
        value=table.freeze({schema=2,encoding=Codec.encoding,run_id=s.run_id,chunk=s.chunks+1,rows=table.freeze(rows)})
    else
        if s.saved_revision==s.version then return true,"complete" end
        key="hop."..s.run_id..".summary";revision=s.version;value=summary(s)
    end
    local charge=0
    if #rows>0 then
        charge=Codec.envelope_bytes(value)
        if not charge or s.store_bytes+charge+LIMITS.summary_bytes>1024*1024 then
            s.storage_fault=true;fault(s,"storage_capacity");s.storage_error="encoded evidence exceeds the private store budget"
            return false,"storage_fault"
        end
    end
    for _,entry in ipairs(picked) do entry.writing=true end
    s.busy=true
    local result=table.pack(pcall(s.writer,key,value))
    s.busy=false
    for _,entry in ipairs(picked) do entry.writing=false end
    -- The actual SDK returns no Lua values. Neither false nor true is that ABI.
    if not result[1] or result.n~=1 then
        s.storage_fault=true;s.stop_requested=true;s.first_fault=s.first_fault or "storage_failure"
        s.storage_error=not result[1] and type(result[2])=="string" and string.sub(result[2],1,LIMITS.text_bytes)
            or "storage call failed or returned an unexpected result"
        return false,"storage_fault"
    end
    if s.unload_scope then
        fault(s,"unload_writer_in_flight")
        return false,"interrupted"
    end
    if revision then s.saved_revision=revision
    else
        for _,entry in ipairs(picked) do entry.flushed=true end
        s.regular_next,s.critical_next=ri,ci;s.chunks+=1;s.stored_rows+=#rows;s.store_bytes+=charge
    end
    return true,revision and "summary_cached" or "chunk_cached"
end
-- Begin before Core cleanup can reenter a writer. This is a pure scope signal;
-- no snapshot copy, storage call, physical cleanup or permission is added here.
function Object:begin_unload()
    begin_unload(get(self));return true
end
local function clean_unload(s,witnessed)
    local t=s.latest
    return witnessed and s.cleanup_observed and t and t.phase=="done"
        and t.stop_latched==true and t.unloaded==true and t.bike_cleanup_complete==true
        and t.bike_authority==false and t.cleanup_pending==false and t.cleanup_unknown==false
        and not s.unresolved_debt and not s.cleanup_unknown_seen and not s.observation_loss
        and not s.storage_fault and not s.interrupted and not s.busy
        and s.regular_next>#s.regular and s.critical_next>#s.critical
end
local function unload_failed(s,why)
    if not s.interrupted then s.interrupted=true;s.version+=1 end
    fault(s,why)
    s.unload_success=false
end
local function unload_storage_failed(s,result,why)
    s.storage_fault=true
    s.storage_error=not result[1] and type(result[2])=="string" and string.sub(result[2],1,LIMITS.text_bytes)
        or "storage call failed or returned an unexpected result"
    unload_failed(s,why)
    return false,"storage_fault"
end
local function observe_unload(self,s,snapshot)
    if plain(snapshot) then self:terminal(snapshot)
    else
        s.final_snapshot_unavailable=true;s.unresolved_debt=true;s.cleanup_unknown_seen=true
        fault(s,"final_snapshot_unavailable")
    end
end
local function finalize_unload(self,snapshot,gate,incomplete_only)
    local s=get(self)
    begin_unload(s)
    local first=not s.unload_attempted
    s.unload_attempted=true -- Shared finish/interrupt claim, before copying/callbacks.
    observe_unload(self,s,snapshot)
    local witnessed=plain(gate) and rawget(gate,"inactive")==true and rawget(gate,"terminal")==true
    if not first then
        -- A former success is never a memoized certificate for later facts.
        if s.unload_success and clean_unload(s,true) and s.saved_revision==s.version then
            if incomplete_only then return false,"already_finalized" end
            return witnessed,witnessed and "complete" or "active"
        end
        if s.unload_success then unload_failed(s,"unload_tail_changed") end
        return false,s.busy and "busy" or "already_interrupted"
    end
    local clean=not incomplete_only and clean_unload(s,witnessed)
    if not clean then
        s.emergency_attempted=true
        unload_failed(s,"explicit_unload_incomplete")
    end
    if s.busy then return false,"busy" end
    if s.unload_writer_spent then return false,"already_interrupted" end
    s.unload_writer_spent=true -- One writer budget, including failures/reentry.
    local revision=s.version
    local key,value
    if clean then
        key="hop."..s.run_id..".summary";value=summary(s)
    else
        key="hop."..s.run_id..".incomplete";value={}
        for name,item in pairs(summary(s)) do value[name]=item end
        value.interrupted=true;value.complete=false;table.freeze(value)
    end
    s.busy=true
    local result=table.pack(pcall(s.writer,key,value))
    s.busy=false
    if not result[1] or result.n~=1 then
        return unload_storage_failed(s,result,clean and "storage_failure" or "emergency_storage_failure")
    end
    if clean then
        if s.version~=revision or not clean_unload(s,witnessed) then
            unload_failed(s,"unload_tail_changed")
            return false,"unload_tail_changed"
        end
        -- Summary only: row/chunk cursors never advance during unload.
        s.saved_revision=revision;s.unload_success=true
        return true,"summary_cached"
    end
    s.emergency_cached=true
    return true,"incomplete_cached"
end
-- Only an actual clean unloaded snapshot with drained own cursors can replace
-- the summary. Any real pending/unknown tail keeps the old incomplete record.
function Object:finish_unload(snapshot,witness)
    return finalize_unload(self,snapshot,witness,false)
end
-- Existing explicit interruption shares the same scope/claim with clean finish
-- and ordinary flush. It cannot spend a second writer after another path won.
function Object:interrupt(snapshot)
    return finalize_unload(self,snapshot,nil,true)
end
return table.freeze(Recorder)
-- One Lua owner for stock switching and a private, fixed zero-force qualification.
-- Require/new are inert. Public mounting remains unavailable: native park and
-- attachment qualification are unresolved. No riding/consumption claim is made.
local EquipmentRuntime=require("./equipment_runtime")
local Admission=require("./bike_admission")
local BikeRuntime={}
local PROBE_BATCHES_PER_SERIAL=4
BikeRuntime.probe_batches_per_serial=PROBE_BATCHES_PER_SERIAL
local vm_attempt_used=false
local KEY="bmx_bike_lifecycle_v1"
local MAX=9007199254740991
-- Source proposal only. No option, public request or manifest can open this.
-- The separate Ride469D activation literal also remains false.
local RIDE_COMPOSITION_QUALIFIED=true
-- M1-derived provisional pelvis target P=(0,.95,-.10) in the body frame.
-- Only a reviewed trial enables P-G.com; the tracked -G.com stays unchanged.
local M1_PROVISIONAL_FOLLOW_OFFSET=true
-- LUA-12. Only a reviewed trial copy, whose manifest also adds
-- world.physics.follow.renew, reserves a renewable Follow and renews it. The
-- tracked false reserves the fixed three-second lease and never renews.
local FOLLOW_RENEWAL_QUALIFIED=true
local receipt_revisions={"final_revision","final_native_epoch","returned_revision"}
local receipt_flags={"claim_known","orphaned","park_observed","native_retirement_known","terminal"}

-- The ride window and the Follow lease (B5). A ride ends at
-- min(publish + RIDE_WINDOW_MS, lease_until - LEASE_MARGIN_MS). lease_until has
-- one source: the documented fixed three seconds from the reserve clock read,
-- refined only by an S2 lease report or, for a renewable reserve (LUA-12), an
-- accepted renewal, each anchored to a Lua clock read taken before that call.
-- Only the renewal moves it later. The native clock is not reskate.time.now,
-- so no native deadline is ever compared with a Lua timestamp; only
-- milliseconds left are. Trial copies change RIDE_WINDOW_MS by the same
-- reviewed substitution as the gate literals.
local RIDE_WINDOW_MS=60000
local BASE_LEASE_MS=3000
-- The 100 ms force command lifetime, plus clock resolution and call time.
local LEASE_MARGIN_MS=150
-- S2's fixed report bounds. A report that disagrees is refused, not used.
local RENEWAL_WINDOW_MS=500
local LIFETIME_CEILING_MS=120000
-- The longest step Core accepts: a larger dt stops the ride as a stalled tick.
local MAX_TICK_MS=250
-- A renewable Follow is renewed on its first following tick (see
-- renew_follow_once), then only when Core's lease has less than this left, not
-- on every following tick (S1b in game: 137 us a renewal). It is the 150 ms
-- margin, the longest gap to the next tick that Core accepts (MAX_TICK_MS), and
-- 75 ms of that tick's own reads before its renewal, so a lease not renewed now
-- is still live, with its margin, when the next tick renews. An accepted
-- renewal leaves RENEWAL_WINDOW_MS, which must be more. After the first tick's
-- renewal, Core renews none while this much or more is left (about the first
-- 2.5 s of the 3 s base lease), and then every second tick at 60 Hz.
local RENEW_BELOW_MS=LEASE_MARGIN_MS+MAX_TICK_MS+75
local LEASE_REPORT="world.physics.read_follow_lease"
-- S2 accepts one renewal a plugin tick; a renewable Core asks at most once a
-- following tick, after the body read, and only below RENEW_BELOW_MS.
local RENEW_FOLLOW="world.physics.renew_follow"
local SDK_RENEWALS_PER_TICK=1
local RENEWALS_PER_TICK=1
-- Follow reads (B9). A following tick reads the receipt once, then once in
-- the guard before each probe batch and before the one submit; the post-call
-- owner checks read nothing: 1+b+1, 6 with four batches. A stop tick adds at
-- most one throttled cleanup read: 7, under the SDK's 8 receipt reads a tick.
-- The lease report is on its own SDK counter of 8; Core reads it at most once
-- a following tick. Cleanup reads are one per 50 ms poll for the 20 s cleanup
-- watchdog: 400. These replace the old per-VM cap of 400 reads.
local SDK_FOLLOW_READS_PER_TICK=8
local SDK_LEASE_READS_PER_TICK=8
local FOLLOW_READS_PER_TICK=6
local LEASE_READS_PER_TICK=1
local FOLLOW_POLL_MS=50
local CLEANUP_WATCHDOG_MS=20000
local CLEANUP_READS=400
assert(2+PROBE_BATCHES_PER_SERIAL<=FOLLOW_READS_PER_TICK and FOLLOW_READS_PER_TICK+1<=SDK_FOLLOW_READS_PER_TICK
    and LEASE_READS_PER_TICK<=SDK_LEASE_READS_PER_TICK and CLEANUP_READS*FOLLOW_POLL_MS>=CLEANUP_WATCHDOG_MS
    and RENEWALS_PER_TICK<=SDK_RENEWALS_PER_TICK,
    "Follow read budget exceeds the SDK's per-tick quota or the cleanup watchdog")
assert(RENEW_BELOW_MS<RENEWAL_WINDOW_MS and RENEW_BELOW_MS<BASE_LEASE_MS,"a renewal must outlast its threshold")
BikeRuntime.ride_limits=table.freeze({ride_window_ms=RIDE_WINDOW_MS,base_lease_ms=BASE_LEASE_MS,
    lease_margin_ms=LEASE_MARGIN_MS,renewal_window_ms=RENEWAL_WINDOW_MS,lifetime_ceiling_ms=LIFETIME_CEILING_MS,
    max_tick_ms=MAX_TICK_MS,renew_below_ms=RENEW_BELOW_MS,
    renewals_per_tick=RENEWALS_PER_TICK,sdk_renewals_per_tick=SDK_RENEWALS_PER_TICK,
    follow_renewal_qualified=FOLLOW_RENEWAL_QUALIFIED,
    follow_reads_per_tick=FOLLOW_READS_PER_TICK,lease_reads_per_tick=LEASE_READS_PER_TICK,
    sdk_follow_reads_per_tick=SDK_FOLLOW_READS_PER_TICK,sdk_lease_reads_per_tick=SDK_LEASE_READS_PER_TICK,
    follow_poll_ms=FOLLOW_POLL_MS,cleanup_watchdog_ms=CLEANUP_WATCHDOG_MS,cleanup_reads=CLEANUP_READS})
local function wall(v) return type(v)=="number" and v==v and v>=0 and v<=MAX end

-- Pure read budget. Before the stop, receipt reads count per tick; after it,
-- against the cleanup total. A read at the cap is refused before the SDK call.
function BikeRuntime.follow_read_admitted(tick_reads,cleanup_reads,stopping)
    local function count(v,most) return type(v)=="number" and v%1==0 and v>=0 and v<=most end
    if stopping==true then return count(cleanup_reads,CLEANUP_READS) and cleanup_reads<CLEANUP_READS end
    return stopping==false and count(tick_reads,FOLLOW_READS_PER_TICK) and tick_reads<FOLLOW_READS_PER_TICK
end
function BikeRuntime.lease_read_admitted(tick_reads)
    return type(tick_reads)=="number" and tick_reads%1==0 and tick_reads>=0 and tick_reads<LEASE_READS_PER_TICK
end
function BikeRuntime.renew_admitted(tick_renewals)
    return type(tick_renewals)=="number" and tick_renewals%1==0 and tick_renewals>=0 and tick_renewals<RENEWALS_PER_TICK
end

-- One window check for publication, the following tick and every force guard.
function BikeRuntime.lease_live(now,publish_at,lease_until,session_renewable)
    return wall(now) and wall(publish_at) and wall(lease_until) and now>=publish_at
        and (session_renewable==true or now-publish_at<RIDE_WINDOW_MS) and now<lease_until-LEASE_MARGIN_MS
end
-- The only lease fact before a report: three seconds from the last clock read
-- before reserve_follow. That read precedes the native reserve, so it errs early.
function BikeRuntime.lease_seed(reserve_at)
    if not wall(reserve_at) or reserve_at+BASE_LEASE_MS>MAX then return nil end
    return reserve_at+BASE_LEASE_MS
end

local lease_report_fields={sequence=true,renewable=true,active=true,renewals=true,last_serial=true,remaining_ms=true,
    lifetime_remaining_ms=true,base_ms=true,renewal_ms=true,lifetime_ms=true,revocation=true,dispatch_busy=true}
local session_lease_report_fields=table.clone(lease_report_fields)
session_lease_report_fields.session_renewable=true
local lease_revocations={none=true,deadline=true,lifetime=true,clock=true,client_not_ready=true,focus_lost=true,
    menu_open=true,pause_menu_open=true,debug_control=true,actor_state=true,other=true}
-- S2's read_follow_lease report against Core's single lease source. Returns
-- lease_until, renewals, verdict and why. "refined" may move the deadline
-- earlier, or later only when the report shows more accepted renewals than
-- the last one used. "ignored" leaves both unchanged: a malformed report never
-- extends anything. "stop" is a native lease that is no longer active.
function BikeRuntime.lease_from_report(identity,lease_until,renewals,row,before,sequence,renewable,session_renewable)
    local function ignored(why) return lease_until,renewals,"ignored",why end
    if not wall(lease_until) or not identity.is_u64(renewals) or not identity.is_nonzero_u64(sequence)
        or type(renewable)~="boolean" then return ignored("lease_state_invalid") end
    local is_session=session_renewable==true
    if is_session and renewable~=true then return ignored("lease_state_invalid") end
    if not wall(before) then return ignored("lease_clock_invalid") end
    if type(row)~="table" or getmetatable(row)~=nil then return ignored("lease_report_malformed") end
    -- New SDKs also label finite leases false; old12-field finite DTOs remain valid.
    local session_field=is_session or row.session_renewable==false
    local n=0
    for key in pairs(row) do
        if not (session_field and session_lease_report_fields or lease_report_fields)[key] then return ignored("lease_report_malformed") end
        n+=1
    end
    local function whole(v,most) return type(v)=="number" and v==v and v%1==0 and v>=0 and v<=most end
    -- Session reports explicitly remove only the absolute lifetime. The same
    -- native base/renewal windows and positive active lease remain mandatory.
    local lifetime_ok
    if is_session then
        lifetime_ok=row.session_renewable==true and row.lifetime_ms==0 and row.lifetime_remaining_ms==0
            and whole(row.remaining_ms,BASE_LEASE_MS)
    else
        lifetime_ok=row.lifetime_ms==(renewable and LIFETIME_CEILING_MS or BASE_LEASE_MS)
            and whole(row.lifetime_remaining_ms,row.lifetime_ms) and whole(row.remaining_ms,row.lifetime_remaining_ms)
    end
    if n~=(session_field and 13 or 12) or row.sequence~=sequence or row.renewable~=renewable or type(row.active)~="boolean"
        or not identity.is_u64(row.renewals) or not identity.is_u64(row.last_serial) or not identity.is_u64(row.dispatch_busy)
        or (row.renewals=="0")~=(row.last_serial=="0") or type(row.revocation)~="string" or not lease_revocations[row.revocation]
        or row.base_ms~=BASE_LEASE_MS or row.renewal_ms~=RENEWAL_WINDOW_MS
        or not lifetime_ok
        or not renewable and (row.renewals~="0" or row.remaining_ms~=row.lifetime_remaining_ms)
        or row.active and (row.revocation~="none" or row.remaining_ms==0)
        or row.revocation~="none" and (row.remaining_ms~=0 or row.lifetime_remaining_ms~=0) then
        return ignored("lease_report_malformed")
    end
    if row.revocation~="none" then return lease_until,renewals,"stop","Follow lease revoked: "..row.revocation end
    if not row.active then return lease_until,renewals,"stop","Follow lease is no longer active" end
    local order=identity.compare(row.renewals,renewals)
    if order==nil or order<0 then return ignored("lease_renewals_regressed") end
    local candidate=before+row.remaining_ms
    if candidate>MAX then return ignored("lease_clock_invalid") end
    if order>0 then return candidate,row.renewals,"refined","renewed" end
    if candidate<lease_until then return candidate,renewals,"refined","shortened" end
    return lease_until,renewals,"refined","unchanged"
end

-- S2's renew_follow refusals (contrib/plugin-body-follow.md, Renewal), each the
-- lease source's own fact. "stop": the Follow is stopped or no longer
-- following. "off": this Follow cannot be renewed again, so its lease runs
-- down. Anything else, an unknown or malformed answer included, waits for a
-- later tick and extends nothing.
local renewal_refusals={expired="stop",not_following="stop",client_not_ready="stop",focus_lost="stop",menu_open="stop",
    pause_menu_open="stop",debug_control="stop",actor_state="stop",not_renewable="off",lifetime_exhausted="off"}
-- One renew_follow result r (as table.pack(pcall(...)) packs it) against Core's
-- single lease source. Returns lease_until, verdict and why. Only "renewed"
-- changes the deadline: the native milliseconds left, from the clock read
-- before the call, so call time can only shorten it.
function BikeRuntime.renewal_outcome(lease_until,before,r,session_renewable)
    if not wall(lease_until) or not wall(before) or type(r)~="table" then return lease_until,"wait","renewal_state_invalid" end
    if not r[1] then return lease_until,"off","renewal raised; the lease runs down unrenewed" end
    local v=r[3]
    if r.n==3 and r[2]==true and type(v)=="number" and v%1==0 and v>=1 and v<=(session_renewable==true and BASE_LEASE_MS or LIFETIME_CEILING_MS) then
        if before+v>MAX then return lease_until,"wait","lease_clock_invalid" end
        return before+v,"renewed",before+v<lease_until and "renewed_earlier" or "renewed"
    end
    if r.n==3 and r[2]==false and type(v)=="string" and #v>0 and #v<=200 then
        return lease_until,renewal_refusals[v] or "wait",v
    end
    return lease_until,"wait","renewal returned malformed results"
end

-- An upper bound on the bytes reskate.json.encode makes of a value, or nil
-- where Core gives none; Core's ledger size check then encodes the ledger as
-- before. Under the 48000-byte limit the ledger fits, so a save skips that
-- encode and the ledger is converted once, by storage.set (S1b in game: 641 us
-- an encode, besides storage.set's own conversion). The bound follows the
-- SDK's writer (lua_to_json, then RapidJSON): an integral number within 2^53
-- is an integer of at most 17 bytes and any other finite number at most 26; a
-- string is quoted, with only '"', '\' and control bytes escaped, at most 6
-- bytes each; a list is keys 1 to n alone, and mixed keys are refused. A
-- string with a byte above 127 gets no bound, as the writer validates UTF-8.
-- A table frozen all through cannot change, so its bound is kept.
local bound_cache=setmetatable({},{__mode="k"})
local function json_bound(value,depth)
    local kind=type(value)
    if kind=="boolean" then return 5,true end
    if kind=="number" then
        if value~=value or math.abs(value)==math.huge then return nil end
        return (value%1==0 and math.abs(value)<=9007199254740992) and 17 or 26,true
    end
    if kind=="string" then
        if not string.find(value,'[%c"\\\128-\255]') then return #value+2,true end
        if string.find(value,"[\128-\255]") then return nil end
        local _,special=string.gsub(value,'[%c"\\]',"")
        return #value+2+5*special,true
    end
    if kind~="table" or depth>32 or getmetatable(value)~=nil then return nil end
    local known=bound_cache[value]
    if known then return known,true end
    local length,count,named,listed,frozen=#value,0,false,false,table.isfrozen(value)
    local n=2
    for k,v in pairs(value) do
        count+=1
        local inner,inner_frozen=json_bound(v,depth+1)
        if not inner then return nil end
        frozen=frozen and inner_frozen
        if type(k)=="string" then
            local key=json_bound(k,depth+1)
            if not key then return nil end
            named=true;n+=key+1+inner
        elseif type(k)=="number" and k%1==0 and k>=1 and k<=length then listed=true;n+=inner
        else return nil end
        n+=1 -- A comma; one more than the writer makes.
    end
    if listed and (named or count~=length) then return nil end
    if frozen then bound_cache[value]=n end
    return n,frozen
end
function BikeRuntime.ledger_bound(value)
    local ok,n=pcall(json_bound,value,0)
    return ok and n or nil
end

local pad_axes={"left_x","left_y","right_x","right_y","left_trigger","right_trigger"}
local pad_buttons={"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"}
-- Pure selected-pad policy (B4), not a mount or force capability. Before
-- publication the selected pad must be neutral: the SDK's sample.neutral, its
-- XInput rest thresholds, which Core does not copy, so a controller resting in
-- the hands passes. Without that fact (an older runtime) the pad must be exactly
-- zero, as before. Only the production caller supplies riding, after the private
-- gate and observed publication join; the ride's mapper then acts on bounded
-- axes and boolean buttons.
function BikeRuntime.selected_pad_admitted(frame,slot,riding)
    local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
    if type(slot)~="number" or slot%1~=0 or slot<0 or slot>3 then return false end
    if not plain(frame) or frame.input_ok~=true or not plain(frame.sample) or frame.sample.user~=slot
        or not plain(frame.sample.pad) or frame.sample.pad.playstation~=false
        or not plain(frame.sample.pad.buttons) then return false end
    local pad=frame.sample.pad
    local zero=true
    for _,key in ipairs(pad_axes) do
        local value=pad[key]
        local low=(key=="left_trigger" or key=="right_trigger") and 0 or -1
        if type(value)~="number" or value~=value or value<low or value>1 then return false end
        zero=zero and value==0
    end
    local pressed=false
    for _,key in ipairs(pad_buttons) do
        if type(pad.buttons[key])~="boolean" then return false end
        pressed=pressed or pad.buttons[key]
    end
    if riding==true then return true end
    local neutral=frame.sample.neutral
    if neutral==nil then return zero and not pressed end
    return neutral==true and not pressed
end
-- The pose the follow visual draws the bike's own parts in: Ride's presentation
-- pose (its accepted steer, wheel and crank phases) from Ride's latest status,
-- or nil, the neutral pose, while there is no Ride. Spawn checks it before
-- drawing it, so a malformed pose is refused there with its own reason.
function BikeRuntime.follow_pose(ride_status)
    return type(ride_status)=="table" and ride_status.presentation_pose or nil
end
-- The stop text for a follow visual that did not draw. A refusal carries
-- Spawn's own reason (a pose, the body, the envelope, its clock or a part
-- request), which the plain text hid. A call that threw or was cancelled keeps
-- the plain text, and a stop latched before it keeps its own first cause.
function BikeRuntime.follow_visual_stop(label,r)
    if type(r)=="table" and r[1]==true and r.n==3 and r[2]==false and type(r[3])=="string" and #r[3]>0 then
        return label.." refused: "..r[3]
    end
    return label.." refused or cancelled"
end

-- Bind only callbacks, never an SDK object or activation option. Keeping this
-- adapter inert lets constructed tests exercise the private query path while
-- both riding gates stay closed. Only create_ride supplies the real closures.
function BikeRuntime.probe_batch_adapter(identity,guard,read_serial,invoke,current_owner,stop,category_lane_qualified)
    local allow_category_lane=category_lane_qualified==true
    local last_serial,count=nil,0
    return function(epoch,rays,query_options)
        if type(query_options)~="table" or getmetatable(query_options)~=nil or query_options.require_contact~=true then return nil end
        local identity_lane=query_options.exclude_local_actor==true
        local category_lane=allow_category_lane and query_options.query_preset=="camera"
            and query_options.require_named_actor_categories_absent==true
        local count_options=0
        for key in pairs(query_options) do
            count_options+=1
            if count_options>3 or not (key=="require_contact" or identity_lane and key=="exclude_local_actor"
                or category_lane and (key=="query_preset" or key=="require_named_actor_categories_absent")) then return nil end
        end
        if not (identity_lane and not category_lane and count_options==2
            or category_lane and not identity_lane and count_options==3) or not guard(epoch) then return nil end
        local serial=read_serial()
        local order=1
        if last_serial then order=identity.compare(serial,last_serial) end
        if not identity.is_nonzero_u64(serial) or order==nil or order<0 then
            stop("contact batch native serial regressed or invalid");return nil
        end
        if order>0 then last_serial=serial;count=0 end
        if count>=PROBE_BATCHES_PER_SERIAL then
            stop("fifth contact batch for one native serial refused");return nil
        end
        -- Reserve before invoking a callback: failure or reentry refunds nothing.
        count+=1
        local r=invoke(epoch,rays,query_options)
        if not current_owner(epoch) then stop("Core guard changed during contact query") end
        if not r[1] then error("contact query result unknown",0) end
        return table.unpack(r,2,r.n)
    end
end

-- Three accepted commands leave one slot free in the SDK's four-receipt ring.
-- Sequence and serial high-water marks are exact decimal uint64 strings, never
-- floating point IDs. The native mailbox requires both to increase.
local FORCE_PIPELINE_CAPACITY=3
BikeRuntime.force_pipeline_capacity=FORCE_PIPELINE_CAPACITY
function BikeRuntime.force_transactions_clear(binding)
    return type(binding)=="table" and type(binding.pending)=="table" and #binding.pending==0
        and not binding.inflight and not binding.unknown
end
-- Inert transport seam for constructed tests. Only create_ride supplies the
-- original owner and SDK callbacks; this factory grants no native authority.
function BikeRuntime.force_transaction_adapter(identity,binding,guard,read_serial,invoke,current_owner,stop,unknown)
    assert(binding.pending==nil and not binding.inflight and not binding.unknown,"force transport already bound")
    local original_body=binding.owner.body
    binding.pending={}
    local pending=binding.pending
    local api={}
    local function retain_unknown(why)
        binding.unknown=true;unknown(why);stop(why)
    end
    local function call_transport(operation,...)
        local wrapped=table.pack(pcall(invoke,operation,original_body,...))
        local r=wrapped[2]
        if not wrapped[1] then return table.pack(false,r) end
        if wrapped.n~=2 or type(r)~="table" or type(r.n)~="number" or r.n%1~=0 or r.n<1 or r.n>8
            or type(r[1])~="boolean" then return table.pack(false,"malformed protected force result") end
        return r
    end
    local function selected(sequence)
        if not identity.is_nonzero_u64(sequence) then return nil end
        for _,row in ipairs(pending) do if row.sequence==sequence then return row end end
        return nil
    end
    api.submit=function(epoch,command)
        if binding.inflight or binding.unknown then
            stop("current Core Source/Follow/body/epoch force guard refused")
            return false,"Core force publication guard refused before SDK call"
        end
        local serial=read_serial()
        local order=1
        if binding.last_submit then order=identity.compare(serial,binding.last_submit) end
        if not identity.is_nonzero_u64(serial) or order==nil or order<=0 then
            stop("duplicate or regressed force publication refused")
            return false,"one force transaction per measured serial"
        end
        -- Backpressure is not a publication attempt and consumes no serial,
        -- Follow-read allowance, SDK call or receipt slot. Existing debt stays.
        if #pending>=FORCE_PIPELINE_CAPACITY then return false,"force_pipeline_full" end
        if not guard(epoch) then return false,"Core force publication guard refused before SDK call" end
        binding.last_submit=serial;binding.inflight=true
        local r=call_transport("submit",epoch,command)
        local accepted=r[1] and r.n==4 and r[2]==true and r[3]==nil and identity.is_nonzero_u64(r[4])
        if accepted then
            local next_sequence=not binding.highest_sequence or identity.compare(r[4],binding.highest_sequence)==1
            if next_sequence then
                -- Record admission before a post-call owner check: stop/unload
                -- cannot turn an actual late publication into a clean refusal.
                pending[#pending+1]={sequence=r[4],serial=serial,ack_attempted=false}
                binding.highest_sequence=r[4];binding.sequence=pending[1].sequence
            else
                accepted=false;retain_unknown("force publication reused or regressed its sequence")
            end
        elseif not (r[1] and r.n==3 and r[2]==false and type(r[3])=="string") then
            retain_unknown("force publication outcome unknown")
        end
        binding.inflight=false
        if not current_owner(epoch) then stop("Core guard changed during force publication") end
        if (not accepted and binding.unknown) or not r[1] then error("force publication outcome unknown",0) end
        return table.unpack(r,2,r.n)
    end
    api.receipt=function(sequence)
        -- Cleanup keeps the original body after Core has cleared T.body. It
        -- may inspect every known slot, including when another slot is unknown.
        if binding.inflight or not selected(sequence) then
            retain_unknown("exact original pending receipt sequence required");return nil
        end
        binding.inflight=true
        local r=call_transport("receipt",sequence)
        binding.inflight=false
        if not r[1] or r.n~=2 or type(r[2])~="table" then retain_unknown("force receipt unknown") end
        if not r[1] then error("force receipt unknown",0) end
        return table.unpack(r,2,r.n)
    end
    api.acknowledge=function(sequence)
        local row=selected(sequence)
        if binding.inflight or not row or row~=pending[1] or row.ack_attempted then
            retain_unknown("exact oldest pending sequence required")
            return false,"exact oldest pending sequence required"
        end
        row.ack_attempted=true;binding.inflight=true
        local r=call_transport("acknowledge",sequence)
        if r[1] and r.n==2 and r[2]==true then
            table.remove(pending,1);binding.sequence=pending[1] and pending[1].sequence or nil
        else retain_unknown("force acknowledgement outcome unknown") end
        binding.inflight=false
        if not r[1] then error("force acknowledgement outcome unknown",0) end
        return table.unpack(r,2,r.n)
    end
    return table.freeze(api)
end

local function new_core(services,options,shared_state,session)
local supplied=services or reskate
local R=type(supplied)=="table" and supplied or {}
local qualification_only=type(options)=="table" and options.qualification_only==true
local session_renewable=type(options)=="table" and options.session_renewable==true
local T=shared_state or {phase="idle",detail="Stock switching and inspection only; native bike qualification unavailable.",
    generation=0,cancel_version=0,calls={},counts={},receipts={},omitted_calls=0,omitted_receipts=0,
    remove_attempted={},remove_accepted={}}
local object={}
local mount_attempt_used=false
local stop_all,latch_stop,source,spawn,equipment,facts,closed_ready,snapshot,flush_removals
local ride,ride_binding,selected_source_frame,stop_ride,drain_ride,observe_ride
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function short(v) return type(v)=="string" and v:gsub("[%c]"," "):sub(1,180) or "unavailable or malformed result" end
local function reason(v) return type(v)=="string" and #v>0 and #v<=200 end
-- Every call resolves its path afresh, so a replaced or removed function is
-- seen at once. Only the split of each literal path is kept: about a hundred
-- lookups a following tick each split their string again (S1 profile).
local path_parts={}
local function lookup(path)
    local parts=path_parts[path]
    if not parts then
        parts={}
        for part in path:gmatch("[^.]+") do parts[#parts+1]=part end
        path_parts[path]=parts
    end
    local value=R
    for i=1,#parts do value=type(value)=="table" and value[parts[i]] or nil end
    return type(value)=="function" and value or nil
end
-- plain's record of deep-frozen tables it may share (see frozen_shape).
local shapes=setmetatable({},{__mode="k"})
local row_shapes={}
for n=4,8 do row_shapes[n]=table.freeze({fields=n,depth=0}) end
local function event(name, result)
    T.counts[name]=(T.counts[name] or 0)+1
    local row={call=name,at_ms=T.now,called=result[1]==true,returns=result[1] and result.n-1 or 0,
        first_type=typeof(result[2])}
    if type(result[2])=="boolean" then row.accepted=result[2] end
    if type(result[3])=="string" then row.reason=short(result[3]) end
    if not result[1] then row.error=short(result[2]) end
    -- A row is never changed once written. Frozen, the snapshot shares it
    -- instead of copying the whole call history every tick.
    table.freeze(row)
    -- Its shape, so plain shares it without walking it: each field is a
    -- boolean, a string of at most 180 bytes or a whole count by construction,
    -- leaving the name's length and the clock to check.
    local at=row.at_ms
    if type(name)=="string" and #name<=1200 and (at==nil or finite(at)) then
        shapes[row]=row_shapes[4+(at~=nil and 1 or 0)+(row.accepted~=nil and 1 or 0)
            +(row.reason~=nil and 1 or 0)+(row.error~=nil and 1 or 0)]
    end
    local calls=T.calls
    local n=#calls
    if n==64 then table.remove(calls,1);T.omitted_calls+=1;n=63 end
    calls[n+1]=row
end
local function call(name, fn, ...)
    if T.session_retired then return {false,"retired Lua session",n=2} end
    local result=table.pack(pcall(fn,...))
    event(name,result)
    return result
end
local function yes(r) return r[1]==true and r.n==2 and r[2]==true end
local function current(g) return not T.stop_latched and not T.unloaded and T.generation==g end
local function clock()
    local r=call("time.now",lookup("time.now"))
    local value=r[2]
    if not r[1] or r.n~=2 or not finite(value) or value<0 or value>MAX or T.now and value<T.now then
        T.clock_unknown=true
        if stop_all then stop_all("invalid or reversed Lua wall clock") end
        return nil
    end
    T.now=value
    return value
end
-- A frozen table whose every nested table is frozen too, with no metatable
-- anywhere, can never change. Once it has passed plain's own checks it is
-- remembered with its field count and depth, and plain shares it instead of
-- copying it: the same checks and limits, applied to a table that cannot
-- differ from what was checked. Call rows, receipts, readiness facts and
-- Ride's status are such tables, and copying them was most of a tick's
-- snapshot (S1 profile). false marks a table that cannot be shared.
local function frozen_shape(value)
    local shape=shapes[value]
    if shape~=nil then return shape end
    shape=false
    shapes[value]=false -- While it is walked: a table that contains itself is copied, never shared.
    if table.isfrozen(value) and getmetatable(value)==nil then
        local fields,depth=0,0
        local ok=true
        for k,v in pairs(value) do
            fields+=1
            if not (type(k)=="string" or type(k)=="number" and finite(k)) then ok=false;break end
            local kind=type(v)
            if kind=="number" then
                if not finite(v) then ok=false;break end
            elseif kind=="string" then
                if #v>1200 then ok=false;break end
            elseif kind=="table" then
                local inner=frozen_shape(v)
                if not inner then ok=false;break end
                fields+=inner.fields
                if inner.depth+1>depth then depth=inner.depth+1 end
            elseif kind~="boolean" then ok=false;break end
        end
        if ok then shape={fields=fields,depth=depth} end
    end
    shapes[value]=shape
    return shape
end
local function plain(value, depth, budget)
    local kind=type(value)
    if kind=="nil" or kind=="boolean" then return value end
    if kind=="number" then assert(finite(value),"nonfinite diagnostic");return value end
    if kind=="string" then assert(#value<=1200,"oversized diagnostic");return value end
    assert(kind=="table" and depth<8,"opaque or deep diagnostic refused")
    local shape=frozen_shape(value)
    if shape then
        budget.n+=shape.fields;assert(budget.n<=3000,"diagnostic field limit")
        assert(depth+shape.depth<8,"opaque or deep diagnostic refused")
        return value
    end
    local out={}
    for k,v in pairs(value) do
        budget.n+=1;assert(budget.n<=3000,"diagnostic field limit")
        assert(type(k)=="string" or type(k)=="number" and finite(k),"invalid diagnostic key")
        -- A scalar value gets plain's own checks here, without a call per field.
        local inner=type(v)
        if inner=="boolean" then out[k]=v
        elseif inner=="number" then assert(finite(v),"nonfinite diagnostic");out[k]=v
        elseif inner=="string" then assert(#v<=1200,"oversized diagnostic");out[k]=v
        else out[k]=plain(v,depth+1,budget) end
    end
    return out
end
local function copied(value) return plain(value,0,{n=0}) end
-- Freezes what copied returned: its own fresh tables, around any it shared.
local function freeze_tree(value)
    if type(value)=="table" and not table.isfrozen(value) then
        for _,v in pairs(value) do freeze_tree(v) end
        table.freeze(value)
    end
    return value
end
local function source_record(f,defer_copy)
    if type(f)~="table" then return nil end
    -- Opaque lease handles and private input epochs never enter the storage DTO.
    local record={phase=f.phase,reason=f.reason,input_ok=f.input_ok,new_observation=f.new_observation,
        generation=f.generation,lease_handle_present=f.lease_handle~=nil,cleanup_pending=f.cleanup_pending,cleanup_unknown=f.cleanup_unknown,
        sample=f.sample,lease_state=f.lease_state,capture_state=f.capture_state}
    -- snapshot immediately validates and detaches the whole DTO with copied;
    -- its source subtree need not be recursively copied twice. Stored step
    -- records still take their own copy and never retain dependency state;
    -- frozen, so each snapshot shares that copy instead of copying it again.
    return defer_copy and record or freeze_tree(copied(record))
end
local function status_of(object)
    if not object then return nil end
    local ok,value=pcall(object.status,object)
    return ok and type(value)=="table" and value or nil
end
local function force_clear()
    if T.ride_unknown==true then return false end
    if not ride_binding then return T.ride_construct_attempted~=true end
    if not BikeRuntime.force_transactions_clear(ride_binding) then return false end
    local row=T.ride_status
    -- This is only the subordinate's local force ledger gate. Native body,
    -- Follow, Source and equipment still require their independent conjunction.
    return type(row)=="table" and row.force_pending==false and row.unknown==false
end
local function source_clean(read_status)
    local f=(read_status or status_of)(source)
    return f and f.phase=="complete" and f.lease_handle==nil and f.cleanup_pending==false and f.cleanup_unknown==false
end
local function visuals_accepted()
    for id=1,8 do if not T.remove_attempted[id] or not T.remove_accepted[id] then return false end end
    return true
end
local function spawn_cleanup_allowed()
    -- Unknown handoff/reservation results can hide SDK ownership even without a handle.
    if not force_clear() or T.handoff_unknown or T.reserve_unknown or T.follow then return false end
    if T.transferred then
        return T.completed_ack==true and T.acknowledged==true
            or T.release_accepted==true and not T.published_seen
    end
    return not T.reserve_attempted and not T.publish_attempted and not T.published_seen
end
local function stop_spawn_when_allowed(why)
    if not spawn then return end
    T.visual_cleanup_deferred=not spawn_cleanup_allowed()
    if T.visual_cleanup_deferred then return end
    -- Removal can advance the native entity lifetime stamp. Keep visuals frozen
    -- while Follow still needs that same lifetime to observe park and complete.
    call("spawn.stop",spawn.stop,spawn,why)
    if flush_removals then flush_removals() end
end

local function equipment_clear(read_status)
    local e=(read_status or status_of)(equipment)
    return e and not e.retained and not e.unloaded and (e.phase=="idle" or e.phase=="done")
end
local function source_clear(read_status)
    if not source then return not T.source_armed end
    local read=read_status or status_of
    local s=read(source)
    return s and (not T.source_armed and s.phase=="idle" or source_clean(read))
end
local function unknown_duty(read_status)
    local read=read_status or status_of
    local s=read(source);local b=read(spawn);local e=read(equipment)
    return T.reload_blocked==true or T.marker_unknown==true or T.storage_fault==true or T.clock_unknown==true
        or T.handoff_unknown==true or T.reserve_unknown==true or T.gear_unknown==true
        or T.cleanup_expired==true or T.protocol_unknown==true or T.ride_unknown==true
        or T.stop_latched==true and not force_clear()
        or T.ack_attempted==true and T.acknowledged~=true
        or T.release_attempted==true and T.release_accepted~=true
        or s and s.cleanup_unknown==true or b and (b.cleanup_unknown==true or b.creation_unknown==true)
        or e and e.outcome=="unresolved" or T.removal_unknown==true
end
local function stock_blocked(read_status)
    if T.unloaded or T.busy or T.gear_requested or T.startup_pending or T.startup_closed or unknown_duty(read_status) then return true end
    local e=(read_status or status_of)(equipment)
    if e and e.storage_fault==true then return true end
    if not force_clear() or not equipment_clear(read_status) or not source_clear(read_status) then return true end
    if T.intent_inflight or T.active or T.follow or T.body or T.handoff_unknown or T.reserve_unknown then return true end
    if T.used and T.phase~="done" and not T.startup_handoff then return true end
    return false
end
snapshot=function()
    local native_retirement_known
    if session then native_retirement_known=false end
    -- These dependency status methods read only local cached state. Reuse one
    -- detached observation inside this diagnostic copy, never across a call,
    -- tick or actuator callback. Authority helpers keep their ordinary reader.
    local s,b,e=status_of(source),status_of(spawn),status_of(equipment)
    local function read_cached(object)
        if object==source then return s end
        if object==spawn then return b end
        if object==equipment then return e end
        return nil
    end
    return copied({schema=1,kind="bike-lifecycle-v1",storage_key=KEY,
        mount_enabled=false,qualification_only=qualification_only,used=T.used==true,
        bike_authority=T.active==true or T.follow~=nil or T.body~=nil or T.handoff_unknown==true or T.reserve_unknown==true,
        cleanup_pending=T.stop_latched==true and not T.bike_cleanup_complete or T.gear_requested==true
            or T.reload_blocked==true or T.marker_unknown==true,
        cleanup_unknown=unknown_duty(read_cached)==true,stock_toggle_blocked=stock_blocked(read_cached),
        retained_reload_marker=T.reload_blocked==true,marker_unknown=T.marker_unknown==true,
        bike_cleanup_complete=T.bike_cleanup_complete==true,
        stock_requested=T.gear_requested==true,equipment_purpose=T.gear_purpose,
        native_follow_lease_ms=BASE_LEASE_MS,qualification_ms=session_renewable and 0 or RIDE_WINDOW_MS,ride_window_ms=session_renewable and 0 or RIDE_WINDOW_MS,
        session_renewable=session_renewable or nil,
        lease_margin_ms=LEASE_MARGIN_MS,reserve_ms=T.reserve_at,publish_ms=T.publish_at,lease_until_ms=T.lease_until,
        lease_renewals=T.lease_renewals,lease_reports=T.lease_reports or 0,lease_report_last=T.lease_report_last,
        lease_report_refused=T.lease_report_refused==true,
        follow_renewal_qualified=FOLLOW_RENEWAL_QUALIFIED,lease_renewable=T.lease_renewable==true,
        lease_renew_calls=T.lease_renew_calls or 0,lease_renew_accepted=T.lease_renew_accepted or 0,
        lease_renew_last=T.lease_renew_last,lease_renew_off=T.lease_renew_off==true,
        renewals_this_tick=T.renewals_tick or 0,
        one_attempt_per_vm=session==nil,experimental_session=session and session.index or nil,
        experimental_attempt_limit=session and 2 or nil,native_retirement_known=native_retirement_known,session_retired=session and T.session_retired==true or nil,retained_body_slot_limit=8,
        limit_scope=T.lease_renewable and "Eight retained native body slots may already be exhausted; not a retry budget. Core renews its one Follow and requests no body reuse."
            or "Eight retained native body slots may already be exhausted; not a retry budget. Core requests no Follow renewal or body reuse.",
        source_freshness_scope=T.lease_renewable and "Selected-input lease renewal. The Follow lease moves later only by an accepted Follow renewal; a copied lease report can only shorten it."
            or "Selected-input lease renewal only. The Follow lease is the reserve seed, which a copied lease report can only shorten.",
        phase=T.phase,detail=T.detail,selected_slot=T.slot,wall_ms=T.now,arm_ms=T.arm_at,
        effect_start_ms=T.effect_at,stop_ms=T.stop_at,stop_reason=T.stop_reason,
        stop_latched=T.stop_latched==true,unloaded=T.unloaded==true,clock_unknown=T.clock_unknown==true,
        storage_fault=T.storage_fault==true,readiness=T.facts,initial_readiness=T.initial_facts,
        capture_attempted=T.capture_attempted==true,source=source_record(s,true),last_source_step=T.source_record,
        spawn=b,equipment=e,
        ride_composition_qualified=RIDE_COMPOSITION_QUALIFIED,ride=T.ride_status,
        pose=T.pose_status, -- S2 declared change: the Poser's status and the last sent plan's targets
        board=T.board_status, -- S2c declared change: the Dropper's status, the floor read and the drop and restore times
        force_cleanup_clear=force_clear(),force_cleanup_unknown=T.ride_unknown==true,
        handoff_attempted=T.handoff_attempted==true,body_transferred=T.transferred==true,
        handoff_unknown=T.handoff_unknown==true,reserve_attempted=T.reserve_attempted==true,
        reserve_unknown=T.reserve_unknown==true,reserve_refused=T.reserve_refused==true,
        sequence=T.sequence,publish_attempted=T.publish_attempted==true,published_seen=T.published_seen==true,
        follow_stop_attempted=T.follow_stop_attempted==true,follow_stop_accepted=T.follow_stop_accepted==true,
        receipt=T.receipt,terminal_receipt=T.terminal,receipt_history=T.receipts,omitted_receipts=T.omitted_receipts,
        acknowledge_attempted=T.ack_attempted==true,acknowledged=T.acknowledged==true,
        completed_acknowledged=T.completed_ack==true,ordinary_release_attempted=T.release_attempted==true,
        ordinary_release_accepted=T.release_accepted==true,visual_remove_attempted=T.remove_attempted,
        visual_remove_call_accepted=T.remove_accepted,visual_cleanup_deferred=T.visual_cleanup_deferred==true,
        calls=T.calls,call_counts=T.counts,omitted_calls=T.omitted_calls,
        equipment_storage_prefix="",ledger_limit_bytes=48000,call_history_limit=64,
        follow_history_limit=16,follow_reads_per_tick=FOLLOW_READS_PER_TICK,lease_reads_per_tick=LEASE_READS_PER_TICK,
        follow_reads_this_tick=T.follow_reads_tick or 0,lease_reads_this_tick=T.lease_reads_tick or 0,
        follow_cleanup_reads=CLEANUP_READS,follow_cleanup_reads_used=T.cleanup_reads or 0,
        startup={pending=T.startup_pending==true,loaded=T.startup_loaded or 0,last_module=T.startup_last,
            core_ready=T.core_ready==true,backend_ready=T.backend_ready==true,
            ride_modules_bound=T.ride_modules_bound==true,ride_trick_adapter=T.ride_trick_adapter==true,
            core_instances=T.core_instances or 0,equipment_instances=T.equipment_instances or 0,
            source_instances=T.source_instances or 0,spawn_instances=T.spawn_instances or 0},
        geometry_scope="Original actor+3m/+0.5m spawn; COM attachment and anchor remain unqualified",
        evidence_scope="Host storage cache acceptance only; no disk durability, native consumption or mounted success inferred"})
end
-- Tick-end saves are throttled: every 200 ms, and every second while
-- following (S1b in game: a save and its encode took 1.6 ms, five times a
-- second). Forced saves (each phase change, publication, stop and terminal
-- receipt) are never throttled.
local SAVE_MS,FOLLOW_SAVE_MS,LEDGER_LIMIT=200,1000,48000
local function persist(force)
    if not T.ledger_owned or T.saving or T.storage_fault then return false end
    local throttle=T.phase=="following" and not T.stop_latched and FOLLOW_SAVE_MS or SAVE_MS
    if not force and T.saved_at and T.now and T.now-T.saved_at<throttle then
        -- A quiescent tick makes no later tick-end save; it flushes this once.
        T.persist_dirty=true;return true
    end
    T.saving=true
    local ok,record=pcall(snapshot)
    local fits=false
    if ok then
        local bound=BikeRuntime.ledger_bound(record)
        fits=bound~=nil and bound<=LEDGER_LIMIT
        if not fits then
            local encoded=call("json.encode",lookup("json.encode"),record)
            fits=encoded[1] and encoded.n==2 and type(encoded[2])=="string" and #encoded[2]<=LEDGER_LIMIT
        end
    end
    local accepted=false
    if fits then
        local stored=call("storage.set",lookup("storage.set"),KEY,record)
        accepted=stored[1]==true and stored.n==1 -- Actual API returns zero values; this is not a durability proof.
    end
    T.saving=false
    if accepted then T.saved_at=T.now;T.persist_dirty=false;return true end
    T.storage_fault=true
    if stop_all then stop_all("ledger cache failed; no retry or replacement") end
    return false
end
-- S2 declared change: the rider's mounted pose (mounted_pose.lua, qualified in this trial copy).
-- Its one SDK function, skater.pose, goes through call(), so the call ledger and the per-call
-- timing see it; a raise is raised again with its own value, which MP.classify_probe reads.
-- prepare_backend makes the Poser (it calls nothing). pose_tick runs once a following tick, after
-- the follow visual drew the bike on the same body read: mount once, then one tick a tick, with
-- Ride's presentation steer and crank phase. A refusal is kept in T.pose_issue and never stops
-- the ride; the Poser then sends nothing more (Poser:tick on a refused state). pose_stop ends the
-- pose once (skater.pose(nil) when one is held), from stop_all and from unload.
local MP,poser
local pose_api={skater={pose=function(...)
    local first=...
    local r=call("skater.pose",lookup("skater.pose"),...)
    if first==nil then T.pose_nil_calls=(T.pose_nil_calls or 0)+1;T.pose_nil_accepted=r[1]==true and r[2]==true end
    if not r[1] then error(r[2],0) end
    return table.unpack(r,2,r.n)
end}}
-- S2c declared change: the rider drops his skateboard as he mounts and has it back when the ride ends
-- (board_drop.lua, byte for byte from work/board-drop b043e07a). Its three SDK functions, board.bones,
-- board.toss and board.clear, go through call(), so the call ledger and the per-call timing see them; one
-- the services table lacks reads as missing, and the Dropper then refuses with no call. A raise is raised
-- again with its own value. prepare_backend requires the module under pcall and makes the Dropper (it calls
-- nothing); a module that does not load leaves board nil, so every board step below does nothing. pose_step
-- drops the board once, right after the Poser's first mount and only when that mount was accepted, onto the
-- floor height Spawn's one floor ray measured (without one the Dropper refuses with no call and keeps why).
-- pose_stop gives it back, so every stop_all and the unload do, and so does pose_tick as soon as the pose is
-- lost mid-ride. A board result is kept in T.board_status and never stops the ride or raises.
local BD,board
local board_calls={}
for _,name in ipairs({"bones","toss","clear"}) do
    local label="board."..name
    board_calls[name]=function(...)
        local r=call(label,lookup(label),...)
        if not r[1] then error(r[2],0) end
        return table.unpack(r,2,r.n)
    end
end
local board_api={board=setmetatable({},{__index=function(_,name)
    local wrapped=board_calls[name]
    if wrapped and lookup("board."..name) then return wrapped end
    return nil
end})}
-- The Dropper's status with the floor read and the drop and restore times; frozen, so the snapshot shares it.
local function board_status()
    if not board then return end
    local st=board:status()
    T.board_status=freeze_tree({state=st.state,reason=st.reason~=nil and short(st.reason) or nil,ground=st.ground,
        floor=T.board_floor,up_y=st.up_y,upside=st.upside,place_above_floor=st.place_above_floor,
        toss_calls=st.toss_calls,clear_calls=st.clear_calls,bones_calls=st.bones_calls,
        toss_result=st.toss_result,clear_result=st.clear_result,
        bones_result=st.bones_result~=nil and short(st.bones_result) or nil,calibration=st.calibration,
        drop_ms=T.board_drop_ms,restore_ms=T.board_restore_ms,issue=T.board_issue})
end
local function board_drop(mounted,now)
    if not board or T.board_drop_tried or T.pose_stopped then return end
    T.board_drop_tried=true
    local ok,why=pcall(function()
        if not mounted then T.board_issue="the pose did not mount: the board stays in the hand";return end
        -- Spawn's own accessor: what its one floor ray returned, not an SDK call.
        local got,floor=false,nil
        if spawn and type(spawn.floor_height)=="function" then got,floor=pcall(spawn.floor_height,spawn) end
        T.board_floor=got and finite(floor) and floor or nil
        local r=board:drop(T.board_floor)
        if r.called then T.board_drop_ms=now end
    end)
    if not ok then T.board_issue=short("board drop raised: "..tostring(why)) end
    pcall(board_status)
end
local function board_restore()
    if not board or T.board_restore_tried then return end
    T.board_restore_tried=true
    local ok,why=pcall(function()
        local r=board:restore()
        if r.called then T.board_restore_ms=T.now end
    end)
    if not ok then T.board_issue=T.board_issue or short("board restore raised: "..tostring(why)) end
    pcall(board_status)
end
local function pose_xyz(p) return {p[1],p[2],p[3]} end
-- The Poser's status with this copy's counters and, after a sent tick, the plan's hips, wrists
-- (left, right) and ankles (left, right) in the world; frozen, so the snapshot shares it.
local function pose_status(plan)
    local st=poser:status()
    local row={state=st.state,blend=st.blend,weight=st.weight,reason=st.reason~=nil and short(st.reason) or nil,
        capability=st.capability,sends=st.sends,ends=st.ends,last_sent=st.last_sent,qualified=st.qualified,
        issue=T.pose_issue,mount_ms=T.pose_mount_ms,mounted_ms=T.pose_mounted_ms,ticks=T.pose_ticks or 0,
        sent_ticks=T.pose_sent_ticks or 0,nil_calls=T.pose_nil_calls or 0,nil_accepted=T.pose_nil_accepted,
        stopped=T.pose_stopped==true,memo_hits=poser.memo_hits or 0,memo_misses=poser.memo_misses or 0}
    if plan then
        local t=plan.targets
        row.plan={at_ms=T.now,hips=pose_xyz(t.hips),wrists={pose_xyz(t.wrists[1]),pose_xyz(t.wrists[2])},
            ankles={pose_xyz(t.ankles[1]),pose_xyz(t.ankles[2])}}
    end
    T.pose_status=freeze_tree(row)
end
local POSE_RELEASED={barspin=0,tailwhip=0,movement_bike_pitch=0,movement_bike_roll=0,barspin_release=0,
    tailwhip_release=0,release_left_hand=0,release_right_hand=0,release_left_foot=0,release_right_foot=0}
local function pose_step(sample,pose,now)
    T.pose_ticks=(T.pose_ticks or 0)+1
    if not T.pose_mount_ms then
        T.pose_mount_ms=now
        local m=poser:mount(now/1000)
        if m.ok~=true then T.pose_issue=T.pose_issue or short("mount: "..tostring(m.reason)) end
        board_drop(m.ok==true,now) -- S2c declared change: the rider drops his board as he mounts
    end
    local a=type(pose)=="table" and pose or {}
    local articulation=table.clone(POSE_RELEASED)
    articulation.steer=a.steer or 0;articulation.crank_phase=a.crank_phase or 0
    local r=poser:tick(now/1000,{bike={center_of_mass=sample.position,rotation=sample.rotation},articulation=articulation})
    if r.sent==true then T.pose_sent_ticks=(T.pose_sent_ticks or 0)+1 end
    if r.ok~=true and r.reason~=nil then T.pose_issue=T.pose_issue or short(r.reason) end
    if not T.pose_mounted_ms and r.state=="mounted" then T.pose_mounted_ms=now end
    pose_status(r.sent==true and r.plan or nil)
end
local function pose_tick(sample,pose,now)
    if T.pose_dead or T.pose_stopped then return end
    local ok,why=pcall(pose_step,sample,pose,now)
    if not ok then T.pose_dead=true;T.pose_issue=T.pose_issue or short("pose step raised: "..tostring(why)) end
    -- S2c declared change: a pose lost mid-ride (its step raised, or the Poser refused and ended it with
    -- skater.pose(nil); it stays refused, since Core mounts once) leaves the native rider drawn on foot, so
    -- his board goes back to his hand then rather than at the ride's end. board_restore runs once at most.
    if T.board_drop_tried and (T.pose_dead or (poser and poser.state=="refused")) then board_restore() end
end
local function pose_stop()
    if not poser or T.pose_stopped then return end
    T.pose_stopped=true
    local ok,why=pcall(poser.stop,poser)
    if not ok then T.pose_issue=T.pose_issue or short("pose stop raised: "..tostring(why)) end
    pcall(pose_status,nil)
    board_restore() -- S2c declared change: the board back in his hand as the pose ends
end
local function follow_stop_once()
    if not T.follow or T.follow_stop_attempted then return end
    T.follow_stop_attempted=true
    local r=call("follow.stop",lookup("world.physics.stop_follow"),T.follow)
    T.follow_stop_accepted=yes(r)
end
latch_stop=function(why)
    if not T.stop_latched then
        T.stop_latched=true;T.generation+=1;T.stop_at=T.now;T.stop_reason=short(why)
        T.phase="stopping";T.detail=T.stop_reason;T.stop_needs_cleanup=true
        -- Pure local Ride stop precedes any reentrant Follow/Source callback.
        if stop_ride then stop_ride(T.stop_reason) end
    end
end
stop_all=function(why)
    latch_stop(why)
    T.cancel_version+=1
    if T.bike_cleanup_complete and T.gear_requested then
        T.phase="stock_stopping";T.detail=short(why)
    end
    if T.cleanup_busy then return end
    T.cleanup_busy=true
    -- Stop known follow FIRST, before Source can release capture or another body read occurs.
    follow_stop_once()
    pose_stop() -- S2 declared change: the rider's pose ends with the Follow
    if T.source_inflight then T.cleanup_busy=false;return end
    if source then call("source.stop",source.stop,source,T.stop_reason) end
    stop_spawn_when_allowed(T.stop_reason)
    if equipment and T.gear_requested and not T.gear_cancelled then
        T.gear_cancelled=true
        call("equipment.unload",equipment.unload,equipment)
    end
    T.stop_needs_cleanup=false
    T.cleanup_busy=false
end

local function removal_allowed()
    if not force_clear() then return false end
    if T.transferred then
        return spawn_cleanup_allowed()
    end
    local b=status_of(spawn)
    return b and not b.creation_unknown and not b.cleanup_unknown and not b.body
        and (b.creation_attempts==0 or T.spawn_release_accepted==true or T.preallocation_refused==true)
end
local function remove_once(id)
    if T.remove_attempted[id] then return end
    T.remove_attempted[id]=true
    local r=call("entities.remove",lookup("entities.remove"),id)
    T.remove_accepted[id]=r[1]==true and r.n==1
    if not T.remove_accepted[id] then T.removal_unknown=true end
end
flush_removals=function()
    if not T.deferred_removals then return end
    if not removal_allowed() then T.visual_cleanup_deferred=true;return end
    T.visual_cleanup_deferred=false
    for id=1,8 do if T.deferred_removals[id] then remove_once(id) end end
end
-- Reconciliation can observe only this stopped owner's original cleanup window.
-- Check fresh clocks around each native read/ACK, not just the tick's old clock:
-- a callback crossing the deadline must not authorize the next call or completion.
local function source_cleanup_open(now)
    local start=T.stop_at or T.effect_at
    return T.stop_latched==true and not T.unloaded and not T.cleanup_expired and not T.clock_unknown
        and finite(now) and finite(start) and now>=start and now-start<CLEANUP_WATCHDOG_MS
end
local input_proxy={}
local input_methods={"lease","lease_read","lease_renew","lease_state","lease_release","lease_acknowledge",
    "lease_capture","lease_capture_state","lease_release_capture","lease_acknowledge_capture"}
for _,method in ipairs(input_methods) do
    local name=method
    local label="input."..name -- The ledger name and SDK path, built once.
    input_proxy[name]=function(...)
        local cleanup_observation=T.stop_latched and (name=="lease_capture_state" or name=="lease_acknowledge_capture"
            or name=="lease_state" or name=="lease_acknowledge")
        if cleanup_observation and not source_cleanup_open(clock()) then
            return nil,"bike source cleanup window closed"
        end
        if T.stop_latched and name=="lease" then return nil,"bike lifecycle cancelled before lease acquisition" end
        if T.stop_latched and name=="lease_renew" then return false,"bike lifecycle cancelled before lease renewal" end
        if name=="lease_release" or name=="lease_release_capture" then
            latch_stop("input source began cleanup")
            follow_stop_once()
        end
        if name=="lease_capture" then
            if T.capture_attempted or T.stop_latched then latch_stop("second or cancelled capture attempt refused");return false,"one-shot capture only" end
            T.capture_attempted=true
        end
        local r=call(label,lookup(label),...)
        if cleanup_observation and not source_cleanup_open(clock()) then
            return nil,"bike source cleanup window closed during callback"
        end
        -- Let Source classify known false versus unknown before outer cleanup.
        if name=="lease_capture" and not yes(r) then latch_stop("capture refusal, exception or malformed result") end
        if not r[1] then error("input "..name.." callback failed",0) end
        return table.unpack(r,2,r.n)
    end
end
local Identity,G,RideRuntime,ride_models
local spawn_api={input=R.input,skater=R.skater,world={physics={}},entities={}}
for _,method in ipairs({"create","read","release"}) do
    local name=method
    local label,path="spawn.body."..name,"world.physics."..name
    spawn_api.world.physics[name]=function(...)
        if name~="release" and T.stop_latched then return nil,"bike lifecycle cancelled before spawn body operation" end
        if name=="release" and T.transferred then return false,"spawn no longer owns body release" end
        local r=call(label,lookup(path),...)
        if name=="create" and r[1] and r.n==3 and r[2]==nil
            and r[3]=="body_preallocation_unavailable" then
            T.preallocation_refused=true
        end
        if name=="release" then
            T.spawn_release_accepted=yes(r)
            if not T.spawn_release_accepted then T.protocol_unknown=true end
        end
        if not r[1] then error("spawn body "..name.." callback failed",0) end
        return table.unpack(r,2,r.n)
    end
end
for _,method in ipairs({"bounds","set","status","remove"}) do
    local name=method
    local label="entities."..name
    spawn_api.entities[name]=function(...)
        if name=="set" and T.stop_latched then return false,"bike lifecycle cancelled before visual publication" end
        local args=table.pack(...)
        if name=="remove" and type(args[1])=="number" then
            T.deferred_removals=T.deferred_removals or {}
            T.deferred_removals[args[1]]=true
            if not removal_allowed() then T.visual_cleanup_deferred=true;return end
            remove_once(args[1])
            -- Spawn's void adapter receives request acceptance; the owner keeps
            -- actual native return arity separately and never retries a failure.
            return
        end
        local r=call(label,lookup(label),...)
        if not r[1] then error("entity "..name.." callback failed",0) end
        return table.unpack(r,2,r.n)
    end
end


local gear_api={time=R.time,input={focus=R.input and R.input.focus},
    skater={get=R.skater and R.skater.get},level=R.level,json=R.json,storage=R.storage}
gear_api.skater.telemetry=function(...)
    local r=call("equipment.skater.telemetry",lookup("skater.telemetry"),...)
    if not r[1] then error("equipment telemetry callback failed",0) end
    -- Bind the requested direction before EquipmentRuntime takes its baseline.
    if T.gear_arming and (r.n~=2 or type(r[2])~="table" or type(r[2].watch)~="table"
        or r[2].watch.state~=T.gear_initial) then return nil end
    return table.unpack(r,2,r.n)
end
for _,method in ipairs({"pulse","pulse_state","pulse_cancel","pulse_acknowledge"}) do
    local name=method
    gear_api.input[name]=function(...)
        if name=="pulse" then
            if T.unloaded or T.gear_cancelled or T.storage_fault or T.clock_unknown or not T.gear_requested then
                return nil,"stock intent cancelled before pulse"
            end
            local version=T.cancel_version
            local direction=status_of(equipment)
            local observed=facts()
            if T.cancel_version~=version or T.unloaded or T.gear_cancelled or T.storage_fault or T.clock_unknown
                or not T.gear_requested or not direction or direction.initial_state~=T.gear_initial
                or direction.expected_state~=T.gear_expected or not closed_ready(observed,true,true)
                or observed.state~=T.gear_initial then
                return nil,"bound stock direction or fresh readiness refused before pulse"
            end
        end
        local r=call("equipment.input."..name,lookup("input."..name),...)
        -- A Stop during pulse cannot erase a subsequently returned real handle.
        if name=="pulse" and r[1] and typeof(r[2])=="userdata"
            and (T.unloaded or T.gear_cancelled) and not T.late_gear_cancel then
            T.late_gear_cancel=true
            call("equipment.input.late_cancel",lookup("input.pulse_cancel"),r[2])
        end
        if not r[1] then error("equipment input "..name.." callback failed",0) end
        return table.unpack(r,2,r.n)
    end
end
equipment=EquipmentRuntime.new(gear_api)
T.equipment_instances=(T.equipment_instances or 0)+1

local required={"time.now","input.focus","input.allowed","skater.get","skater.telemetry","level.current",
    "menu.game","json.encode","storage.get","storage.set","entities.bounds","entities.set","entities.status","entities.remove",
    "world.physics.create","world.physics.read","world.physics.release","world.physics.reserve_follow","world.physics.publish_follow",
    "world.physics.read_follow","world.physics.stop_follow","world.physics.acknowledge_follow",
    -- The four force closures in create_ride call these; refuse at mount, not mid-ride.
    "world.physics.probe_batch","world.physics.submit","world.physics.receipt","world.physics.acknowledge",
    "input.pulse","input.pulse_state","input.pulse_cancel","input.pulse_acknowledge"}
local function available()
    for _,path in ipairs(required) do if not lookup(path) then return false,path end end
    for _,name in ipairs(input_methods) do if not lookup("input."..name) then return false,"input."..name end end
    return type(vector)=="table" and type(vector.create)=="function","vector.create"
end

-- Frozen: a facts table is never changed after it is read, and the snapshot
-- then shares it rather than copying it each tick.
facts=function()
    local f=Admission.facts(call,lookup)
    if type(f)=="table" then table.freeze(f) end
    return f
end
local function base_ready(f,stock)
    return f and f.focused and f.gameplay and (stock and f.upright_stock or f.upright_onfoot)
        and (not T.level or f.level==T.level) and (not T.wipeouts or f.wipeouts==T.wipeouts)
end
closed_ready=function(f,grounded,stock)
    return base_ready(f,stock) and f.interface_closed and f.game_menu_closed and f.input_allowed
        and (not grounded or f.grounded)
end
local phases={reserved=true,following=true,stopping=true,retained=true,abandoned=true,completed=true}
local reasons={none=true,invalid_owner=true,invalid_kind=true,unavailable=true,busy=true,receipt_capacity=true,context_changed=true,
    focus_changed=true,teleporting=true,motion_owned=true,actor_changed=true,actor_destroyed=true,world_changed=true,
    unsupported_state=true,protection_conflict=true,request_bits_conflict=true,request_write_failed=true,request_restore_failed=true,
    native_refused=true,selector_overridden=true,cancelled=true,expired=true,owner_released=true,native_lifetime_changed=true}
local fields={phase=true,reason=true,park_reason=true,sequence=true,final_revision=true,final_native_epoch=true,returned_revision=true,
    pending=true,in_flight=true,claim_known=true,orphaned=true,park_observed=true,native_retirement_known=true,terminal=true}
local function receipt_copy(row)
    if type(row)~="table" then return nil end
    local n=0;for key in pairs(row) do if not fields[key] then return nil end;n+=1 end
    if n~=14 or not phases[row.phase] or not reasons[row.reason] or not reasons[row.park_reason]
        or not Identity.is_nonzero_u64(row.sequence) or T.sequence and row.sequence~=T.sequence then return nil end
    for _,key in ipairs(receipt_revisions) do if not Identity.is_u64(row[key]) then return nil end end
    if Identity.compare(row.returned_revision,row.final_revision)>0 or (row.final_revision=="0")~=(row.final_native_epoch=="0")
        or not finite(row.in_flight) or row.in_flight<0 or row.in_flight>255 or row.in_flight%1~=0 then return nil end
    for _,key in ipairs(receipt_flags) do
        if type(row[key])~="boolean" then return nil end
    end
    if row.native_retirement_known or row.terminal~=(row.phase=="abandoned" or row.phase=="completed") or type(row.pending)~="table" then return nil end
    local count=0;for key,value in pairs(row.pending) do if key~=1 or value~="body_parked" then return nil end;count+=1 end
    if count>1 then return nil end
    if row.phase=="reserved" and (row.final_revision~="0" or row.park_observed or count~=0) then return nil end
    if row.phase=="abandoned" and (row.final_revision~="0" or row.in_flight~=0 or row.park_observed or count~=0 or T.published_seen) then return nil end
    if row.phase=="completed" and (not row.park_observed or row.in_flight~=0 or count~=0 or row.returned_revision~=row.final_revision) then return nil end
    if T.receipt and (Identity.compare(row.final_revision,T.receipt.final_revision)<0 or
        Identity.compare(row.returned_revision,T.receipt.returned_revision)<0) then return nil end
    local out=copied(row);table.freeze(out.pending);table.freeze(out)
    return out
end
local function release_once()
    if not force_clear() or T.unloaded or T.release_attempted or not T.body or T.follow or T.reserve_unknown or T.handoff_unknown or T.published_seen then return end
    local handoff_without_reserve=T.transferred==true and T.handoff_attempted==true
        and T.handoff_unknown==false and T.reserve_attempted~=true
    if not handoff_without_reserve and not T.reserve_refused
        and not (T.acknowledged and T.terminal and T.terminal.phase=="abandoned") then return end
    T.release_attempted=true
    local r=call("body.release",lookup("world.physics.release"),T.body)
    T.release_accepted=yes(r)
    if T.release_accepted then T.body=nil end
end
local function accept_terminal(dto)
    if T.terminal then return end
    stop_all("native follow terminal receipt observed")
    T.terminal=dto
    if not persist(true) or T.unloaded then return end
    T.ack_attempted=true
    local r=call("follow.acknowledge",lookup("world.physics.acknowledge_follow"),T.follow)
    T.acknowledged=yes(r)
    if T.acknowledged then
        T.follow=nil
        if dto.phase=="completed" then T.completed_ack=true;T.body=nil else release_once() end
    end
    stop_spawn_when_allowed(T.stop_reason)
    persist(true)
end
local function read_follow(force)
    if not T.follow or T.ack_attempted then return false end
    if not force and T.follow_read_at and T.now and T.now-T.follow_read_at<FOLLOW_POLL_MS then return false end
    local stopping=T.stop_latched==true
    if not BikeRuntime.follow_read_admitted(T.follow_reads_tick or 0,T.cleanup_reads or 0,stopping) then
        -- Core's own cap stops the ride before the SDK's quota would refuse.
        if not stopping then stop_all("Follow receipt reads for this tick exhausted") end
        return false
    end
    if stopping then T.cleanup_reads=(T.cleanup_reads or 0)+1 else T.follow_reads_tick=(T.follow_reads_tick or 0)+1 end
    T.follow_read_at=T.now
    local r=call("follow.read",lookup("world.physics.read_follow"),T.follow)
    local dto=r[1] and r.n==2 and receipt_copy(r[2]) or nil
    if not dto then T.follow_unknown=true;stop_all("follow receipt unavailable or contradictory");return false end
    T.sequence=T.sequence or dto.sequence;T.receipt=dto
    if dto.phase=="following" or dto.final_revision~="0" then T.published_seen=true end
    if #T.receipts==16 then table.remove(T.receipts,1);T.omitted_receipts+=1 end
    table.insert(T.receipts,copied(dto))
    if dto.orphaned and not dto.terminal then stop_all("native receipt reports orphaned ownership") end
    if dto.phase=="stopping" or dto.phase=="retained" or T.published_seen and dto.phase=="reserved" then
        stop_all("native follow is no longer following")
    end
    if dto.terminal then accept_terminal(dto) end
    return true
end
local function session_following() return session_renewable and T.phase=="following" and T.published_seen==true end
local function lease_live(now) return BikeRuntime.lease_live(now,T.publish_at,T.lease_until,session_following()) end
local function read_lease()
    -- Optional, feature-detected by lookup like the required list: SDKs before
    -- S2 lack it, and without world.physics.follow.renew it raises. Either way
    -- the reserve seed alone bounds the ride; a raise is not retried.
    local report=lookup(LEASE_REPORT)
    if not report or T.lease_report_refused then
        if session_renewable then stop_all("session Follow lease report unavailable") end
        return
    end
    if not T.follow or T.ack_attempted or not BikeRuntime.lease_read_admitted(T.lease_reads_tick or 0) then return end
    T.lease_reads_tick=(T.lease_reads_tick or 0)+1
    local before=clock() -- Before the call, so call time can only shorten the lease.
    if not before then return end
    local r=call("follow.lease",report,T.follow)
    if not r[1] then
        T.lease_report_refused=true;T.lease_report_last="lease report raised; reserve seed only"
        if session_renewable then stop_all("session Follow lease report raised") end
        return
    end
    if r.n~=2 then
        T.lease_report_last=r.n==3 and r[2]==nil and reason(r[3]) and short(r[3]) or "lease report returned malformed results"
        if session_renewable then stop_all("session Follow lease report malformed") end
        return
    end
    -- The report must match the lifetime Core reserved. Only an accepted
    -- renewal moves the deadline later (LUA-12); a report can only shorten it,
    -- which for a fixed lease is all lease_from_report can return anyway.
    local until_ms,renewals,verdict,why=BikeRuntime.lease_from_report(Identity,T.lease_until,T.lease_renewals or "0",
        r[2],before,T.sequence,T.lease_renewable==true,session_renewable)
    T.lease_report_last=why
    if verdict=="stop" then stop_all(why);return end
    if session_renewable and verdict=="ignored" then stop_all("session Follow lease report invalid: "..short(why));return end
    if verdict=="refined" then
        T.lease_until=math.min(until_ms,T.lease_until);T.lease_renewals=renewals;T.lease_reports=(T.lease_reports or 0)+1
    end
end
-- Feature detection that spends nothing: with no arguments, renew_follow is
-- refused by the binding before its quota or the backend, by the missing
-- permission first. Only the arity refusal means the permission is granted;
-- any other answer keeps the fixed lease Core reserved before LUA-12.
local function renewal_available()
    local renew=lookup(RENEW_FOLLOW)
    if not renew then T.lease_renew_last="renew_follow absent; fixed lease";return false end
    local r=call("follow.renew_probe",renew)
    local why=not r[1] and type(r[2])=="string" and r[2] or "renewal probe was not refused"
    if string.find(why,"renew_follow takes",1,true) and not string.find(why,"permission",1,true) then return true end
    T.lease_renew_last="fixed lease: "..short(why)
    return false
end
-- At most once a following tick, after the body read and with that read's
-- epoch, the newest sample this VM holds. Never after a stop, never twice in
-- one tick. The first following tick renews once, so the Host's answer (a
-- refusal, or a lease that cannot be renewed) is known while the 3 s base lease
-- still covers the ride; after that only when less than RENEW_BELOW_MS of
-- Core's lease is left, measured by the clock read just after the body read.
-- A refused or wait answer is handled as before; a wait leaves the lease below
-- the threshold, so the next tick asks again. Returns false only when the tick
-- must not go on (stopped or cancelled).
local function renew_follow_once(sample,generation)
    if not T.lease_renewable or T.lease_renew_off then return true end
    if not current(generation) then return false end
    if (T.lease_renew_calls or 0)>0 and wall(T.now) and wall(T.lease_until)
        and T.lease_until-T.now>=RENEW_BELOW_MS then return true end
    local renew=lookup(RENEW_FOLLOW)
    if not renew or not T.follow or T.ack_attempted or not BikeRuntime.renew_admitted(T.renewals_tick or 0) then return true end
    if typeof(sample.epoch)~="userdata" then T.lease_renew_last="body read carried no epoch";return true end
    T.renewals_tick=(T.renewals_tick or 0)+1
    local before=clock() -- Before the call, so call time can only shorten the lease.
    if not before or not current(generation) then return false end
    -- A lease Core already holds ended is stopped, never renewed.
    if not lease_live(before) then stop_all("ride window or Follow lease ended before renewal");return false end
    T.lease_renew_calls=(T.lease_renew_calls or 0)+1
    local r=call("follow.renew",renew,T.follow,sample.epoch)
    local until_ms,verdict,why=BikeRuntime.renewal_outcome(T.lease_until,before,r,session_renewable)
    T.lease_renew_last=short(why)
    if verdict=="renewed" then T.lease_until=until_ms;T.lease_renew_accepted=(T.lease_renew_accepted or 0)+1
    elseif verdict=="off" then T.lease_renew_off=true
    elseif verdict=="stop" then stop_all("Follow renewal refused: "..short(why));return false end
    local after=clock()
    if not after or not current(generation) then return false end
    if not lease_live(after) then stop_all("ride window or Follow lease ended during renewal");return false end
    return true
end
local source_identity_names={"sequence","source_epoch","context_generation"}
local function same_selected(frame,bound)
    if type(frame)~="table" or frame.input_ok~=true or frame.cleanup_pending or frame.cleanup_unknown
        or frame.lease_handle~=bound.lease_handle or frame.generation~=bound.generation
        or type(frame.sample)~="table" or frame.sample.user~=bound.user then return false end
    for _,name in ipairs(source_identity_names) do if frame.sample[name]~=bound[name] then return false end end
    return true
end
local function remember_ride(row)
    if type(row)~="table" or type(row.force_pending)~="boolean" or type(row.unknown)~="boolean"
        or type(row.stop_requested)~="boolean" or not finite(row.submitted) or row.submitted<0 or row.submitted%1~=0
        or not finite(row.acknowledged) or row.acknowledged<0 or row.acknowledged%1~=0 then
        T.ride_unknown=true;return false
    end
    local ok,detached=pcall(copied,row)
    if not ok then T.ride_unknown=true;return false end
    T.ride_status=detached
    if row.unknown then T.ride_unknown=true end
    return true
end
stop_ride=function(why)
    if not ride then return end
    local r=call("ride.stop",ride.stop,ride,why)
    if not r[1] or r.n~=2 or not remember_ride(r[2]) then T.ride_unknown=true end
end
drain_ride=function()
    if not ride then return end
    local r=call("ride.drain",ride.drain,ride)
    if not r[1] or r.n~=2 or not remember_ride(r[2]) then T.ride_unknown=true end
end
-- An owner check runs before and after each contact batch and the submit
-- (B9). A following tick reads the six readiness facts and Source's three
-- lease reads twice. The first time is at its start: the tick's own facts, and
-- Source's step, which reads the lease and capture state after its renewal.
-- Every check that publishes nothing shares those reads: the checks around a
-- contact batch, which only reads the world. The check immediately before the
-- force submit reads all nine afresh (fresh=true), because Contact, the kernel
-- and the packet ran since the tick began, and focus, the menu or the lease can
-- change in that time. The check after the submit shares those fresh reads. A
-- change between the tick's start and the submit is therefore seen at the
-- submit's check, before any force is published. Every Lua-side test, both
-- clock reads and the Follow read still run in every check (S1b in game: the
-- nine reads, six times a tick, were about 0.56 ms of a 3.7 ms tick).
local tick_facts,tick_authorization
local function current_ride_owner(binding,epoch,read,fresh)
    local owner=binding.owner
    if not current(owner.generation) or ride_binding~=binding or not binding.observing
        or not T.active or T.body~=owner.body or T.follow~=owner.follow or T.input_current~=true
        or T.phase~="following" or not same_selected(selected_source_frame,owner.source)
        or not binding.sample or epoch~=binding.sample.epoch then return false end
    local now=clock()
    if not now or not current(owner.generation) then return false end
    -- S1 declared change: the window or lease ending inside a subordinate step is that end, not a guard change.
    if not lease_live(now) then stop_all("ride window or Follow lease ended during subordinate step");return false end
    local f=not fresh and tick_facts or facts();T.facts=f
    -- The latest facts this tick read; later checks that publish nothing use them.
    tick_facts=f
    if not current(owner.generation) or not closed_ready(f,false) then return false end
    -- A post-call owner check (read=false) keeps every Lua-side check but reuses
    -- this tick's receipt, so each guarded SDK call costs one Follow read (B9).
    if read~=false and (not read_follow(true) or not current(owner.generation)) then return false end
    local receipt=T.receipt
    if not receipt or receipt.phase~="following" or receipt.claim_known~=true or receipt.orphaned
        or receipt.terminal or receipt.park_observed then return false end
    -- Source owns this read-only lease/capture check. It does not publish
    -- another model input or native body sample. All earlier guard callbacks
    -- run first; a post-effect failure still retains the accepted sequence.
    -- Afresh it makes the three lease reads; otherwise Source answers from the
    -- rows its step read this tick, with no SDK call, or the latest answer this
    -- tick for the same binding and frame is used.
    local authorization
    local held=tick_authorization
    if not fresh and held and held.binding==binding and held.frame==selected_source_frame then
        authorization=held.result
    else
        authorization=fresh and call("source.authorize",source.authorize,source,selected_source_frame)
            or call("source.authorize_step",source.authorize,source,selected_source_frame,true)
        tick_authorization={binding=binding,frame=selected_source_frame,result=authorization}
    end
    now=clock() -- Include authorization time in the ride window and lease bound.
    -- S1 declared change: every identity and authorization check first; only then the clock, whose
    -- failure is the window or lease ending (a stop with the window text), never a guard change.
    local held=now~=nil and current(owner.generation) and T.body==owner.body and T.follow==owner.follow
        and T.input_current==true and same_selected(selected_source_frame,owner.source)
        and binding.observing and binding.sample and epoch==binding.sample.epoch
        and authorization[1] and authorization.n==2 and authorization[2]==true
    if held and not lease_live(now) then stop_all("ride window or Follow lease ended during subordinate step");return false end
    return held
end
local transport_labels={submit="ride.submit",receipt="ride.receipt",acknowledge="ride.acknowledge"}
local transport_paths={submit="world.physics.submit",receipt="world.physics.receipt",acknowledge="world.physics.acknowledge"}
local function create_ride(frame)
    if not RIDE_COMPOSITION_QUALIFIED or ride or T.ride_construct_attempted then return end
    T.ride_construct_attempted=true
    local source_key={lease_handle=frame.lease_handle,generation=frame.generation,user=frame.sample.user}
    for _,name in ipairs(source_identity_names) do source_key[name]=frame.sample[name] end
    table.freeze(source_key)
    local owner=table.freeze({body=T.body,follow=T.follow,generation=T.generation,
        source=source_key,incarnation=table.freeze({})})
    local binding={owner=owner}
    ride_binding=binding -- Reserve before constructors/callbacks can reenter.
    local api={}
    local function guard(epoch,fresh)
        if binding.inflight or binding.unknown or not current_ride_owner(binding,epoch,nil,fresh) then
            stop_all("current Core Source/Follow/body/epoch force guard refused")
            return false
        end
        return true
    end
    local function after_call(epoch) return current_ride_owner(binding,epoch,false) end
    api.probe_batch=BikeRuntime.probe_batch_adapter(Identity,guard,
        function() return binding.sample.serial end,
        function(epoch,rays,query_options)
            return call("ride.probe_batch",lookup("world.physics.probe_batch"),owner.body,epoch,rays,query_options)
        end,
        after_call,stop_all,ride_models.contact.CATEGORY_WHEEL_LANE_QUALIFIED)
    -- The check before a force publication always reads afresh (B9); a contact
    -- batch's checks share the tick's reads.
    local function submit_guard(epoch) return guard(epoch,true) end
    local transport=BikeRuntime.force_transaction_adapter(Identity,binding,submit_guard,
        function() return binding.sample and binding.sample.serial end,
        function(operation,body,...)
            return call(transport_labels[operation] or "ride."..operation,
                lookup(transport_paths[operation] or "world.physics."..operation),body,...)
        end,
        after_call,stop_all,
        function() T.ride_unknown=true end)
    api.submit=transport.submit;api.receipt=transport.receipt;api.acknowledge=transport.acknowledge
    table.freeze(api)
    -- Ride and its models were bound by prepare_backend from staged modules, so
    -- this first following tick resolves no module. No trick adapter: it refuses
    -- support that is not measured_support, which Contact never reports.
    local built=call("ride.new",function()
        return RideRuntime.new(api,ride_models,{body_handle=owner.body,incarnation=owner.incarnation})
    end)
    if built[1] and built.n==2 and type(built[2])=="table" then ride=built[2] end
    if not ride or not remember_ride(status_of(ride)) then
        T.ride_unknown=true;stop_all("subordinate construction or force ledger unavailable");return
    end
    if not current(owner.generation) then stop_ride("cancelled during subordinate construction") end
end
observe_ride=function(frame,sample,now)
    if not RIDE_COMPOSITION_QUALIFIED then return end
    if not ride then create_ride(frame) end
    if not ride or not ride_binding or T.stop_latched then return end
    -- Freeze this exact same-read sample; both Ride and the visual update use
    -- these userdata/vector values. No extra body read or receipt surrogate.
    if type(sample)~="table" or getmetatable(sample)~=nil or typeof(sample.epoch)~="userdata"
        or not Identity.is_nonzero_u64(sample.serial) or type(sample.rotation)~="table" then
        stop_all("same-read body sample unavailable for subordinate");return
    end
    if not table.isfrozen(sample.rotation) then table.freeze(sample.rotation) end
    if not table.isfrozen(sample) then table.freeze(sample) end
    local binding=ride_binding
    binding.sample=sample;binding.observing=true
    local r=call("ride.observe",ride.observe,ride,frame,sample,
        {now_ms=now,focused=T.facts.focused,menu_open=not T.facts.interface_closed or not T.facts.game_menu_closed,loaded=true})
    binding.observing=false;binding.sample=nil
    if not r[1] or r.n~=2 or not remember_ride(r[2]) then
        T.ride_unknown=true;stop_all("subordinate observation outcome unknown")
    elseif r[2].stop_requested then stop_all("subordinate requested stop") end
end

local function handoff_and_follow()
    local generation=T.generation
    T.handoff_attempted=true;T.handoff_unknown=true
    local h=call("spawn.handoff_follow",spawn.handoff_follow,spawn)
    if h[1] and typeof(h[2])=="userdata" then T.body=h[2];T.transferred=true end
    if not h[1] or h.n~=4 or typeof(h[2])~="userdata" or type(h[3])~="table" or h[4]~=nil then
        if h[1] and h.n==4 and h[2]==nil and h[3]==nil and reason(h[4]) then T.handoff_unknown=false end
        stop_all("spawn handoff refused or unknown");return
    end
    T.handoff_unknown=false
    local at=clock();if not at or not current(generation) then stop_all("cancelled during body handoff");return end
    local v=call("spawn.follow_visual",spawn.follow_visual,spawn,h[3],at)
    if not yes(v) or not clock() or not current(generation) then
        stop_all(BikeRuntime.follow_visual_stop("initial follow visual",v));return
    end
    -- A renewable lease starts from the same three-second floor as the fixed one.
    T.lease_renewable=FOLLOW_RENEWAL_QUALIFIED and renewal_available()
    if session_renewable and not T.lease_renewable then stop_all("session Follow renewal unavailable");return end
    T.reserve_attempted=true;T.reserve_unknown=true;T.reserve_at=T.now
    -- The single lease source starts here, from the clock read before reserve.
    T.lease_until=BikeRuntime.lease_seed(T.reserve_at);T.lease_renewals="0"
    -- The policy pair CE2 ran in game. callback_entry needs explicit owned_body cleanup;
    -- it changes no lease, quota, permission or receipt shape (contrib/plugin-body-follow.md).
    local attachment={offset_from_com=M1_PROVISIONAL_FOLLOW_OFFSET
            -- S1 declared change: R2 cannot lead Follow per tick, so P leads by a fixed 0.035 m along +Z,
            -- the measured two-tick lag (33 ms) at 1.06 m/s; within 5 cm of P from 0 to 2.57 m/s.
            and vector.create(-G.com[1],.95-G.com[2],-.065-G.com[3])
            or vector.create(-G.com[1],-G.com[2],-G.com[3]),root_in_body={0,0,0,1},cleanup="owned_body",motion_policy="callback_entry"}
    if T.lease_renewable then attachment.lifetime=session_renewable and "session_renewable" or "renewable" end
    local reserved=call("follow.reserve",lookup("world.physics.reserve_follow"),T.body,attachment)
    -- Adopt any returned userdata BEFORE inspecting why or cancellation.
    if reserved[1] and typeof(reserved[2])=="userdata" then T.follow=reserved[2];T.reserve_unknown=false end
    local after=clock()
    if not T.follow then
        -- Protocol strings can hide a backend reservation whose handle was lost.
        if reserved[1] and reserved.n==3 and reserved[2]==nil and type(reserved[3])=="string"
            and reserved[3]~="none" and reasons[reserved[3]]==true then T.reserve_unknown=false;T.reserve_refused=true end
        stop_all("follow reserve refused or unknown");release_once();return
    end
    if not after or not current(generation) or not T.lease_until or after>=T.lease_until then stop_all("reserve callback cancelled or exceeded native lease");return end
    if reserved.n~=3 or reserved[3]~=nil then stop_all("partial or malformed follow reserve; never publish");return end
    read_follow(true)
    if not current(generation) or not T.receipt or T.receipt.phase~="reserved" then stop_all("reservation receipt did not qualify publication");return end
    after=clock()
    if not after or not current(generation) or after>=T.lease_until then stop_all("reservation lease elapsed before publish");return end
    T.publish_attempted=true;T.publish_at=after
    local published=call("follow.publish",lookup("world.physics.publish_follow"),T.follow)
    if published[1] and published[2]==true then T.published_seen=true end
    after=clock()
    if not yes(published) or not after or not current(generation) or not lease_live(after) then stop_all("publish refused, cancelled or bounded interval elapsed");return end
    T.phase="following";T.detail="Published one zero-force attachment; sampled alignment is not claimed."
    persist(true)
end

local function cleanup_tick()
    -- A separately requested stock transaction cannot reopen completed bike
    -- history or inherit the old qualification cleanup deadline.
    if T.bike_cleanup_complete then return end
    local previous=T.phase
    follow_stop_once()
    -- Follow cancellation/park is immediate. It never fabricates force ACK;
    -- cleanup capabilities retain the original body after Follow clears T.body.
    drain_ride()
    -- Cleanup has its full watchdog from the stop; Source arm is only the
    -- fallback when no clock had been read when the stop latched.
    local start=T.stop_at or T.effect_at
    if not T.cleanup_expired and T.now and start and T.now-start>=CLEANUP_WATCHDOG_MS then
        T.cleanup_expired=true;T.detail="Cleanup watchdog expired; unresolved duty retained for SDK VM close."
    end
    if not T.cleanup_expired then read_follow(false) end
    release_once()
    stop_spawn_when_allowed(T.stop_reason)
    flush_removals()
    local b=status_of(spawn)
    local body_clear=not spawn and not T.spawn_requested
        or not T.transferred and b and not b.cleanup_unknown and not b.creation_unknown and not b.body
        or T.completed_ack or T.release_accepted
    local follow_clear=not T.follow and not T.reserve_unknown and not T.handoff_unknown
    local removals_clear=not b or not b.visual_remove_requested or visuals_accepted()
    local e=status_of(equipment)
    local equipment_clean=e and not e.retained and (e.phase=="idle" or e.phase=="done")
    if force_clear() and source_clear() and body_clear and follow_clear and removals_clear and equipment_clean
        and not unknown_duty() then
        T.active=false;T.gear_requested=false;T.bike_cleanup_complete=true;T.phase="done"
        T.detail=T.completed_ack and "Completed + ACK; input drained. Stock return requires a separate explicit request."
            or "No published bike authority remains; stock switching is a separate explicit request."
    elseif T.cleanup_expired or unknown_duty() then
        T.phase="retained_unknown"
    end
    if T.phase~=previous then persist(true) end
end
local function valid_slot(slot)
    return finite(slot) and slot>=0 and slot<=3 and slot%1==0
end
local function marker_clear()
    if T.ledger_owned then return true end
    if T.reload_blocked or T.marker_unknown then return false end
    local old=call("storage.get",lookup("storage.get"),KEY)
    if not old[1] or old.n~=2 then
        T.marker_unknown=true;T.phase="blocked";T.detail="Bike marker unreadable; no adoption, rearm or stock pulse."
        return false
    end
    if old[2]~=nil then
        T.reload_blocked=true;T.phase="blocked";T.detail="Prior bike marker retained; no handle adoption, rearm or stock pulse."
        return false
    end
    return true
end
local function begin_equipment(slot,purpose,initial)
    T.gear_purpose=purpose;T.gear_initial=initial;T.gear_expected=initial==100 and 504 or 100
    T.gear_requested=true;T.gear_cancelled=false;T.late_gear_cancel=false;T.gear_arming=true
    local version=T.cancel_version
    local r=call("equipment.request",equipment.request,equipment,slot,T.gear_admission_at)
    T.gear_arming=false
    if not yes(r) or T.cancel_version~=version or T.unloaded or T.gear_cancelled then
        local known_false=r[1] and r.n==3 and r[2]==false and reason(r[3])
        if not known_false or not equipment_clear() then T.gear_unknown=true
        else T.gear_requested=false end
        if purpose=="mount" or T.gear_unknown then stop_all("stock request refused, cancelled or unknown") end
        return false,"Stock request refused, cancelled or unresolved"
    end
    T.phase=purpose=="mount" and "equipment_acquiring" or "stock_switching"
    T.detail=purpose=="mount" and "Board100 to feet504 acquisition; capture waits for matching report ACK and stable target."
        or "Explicit stock toggle armed; close menus and keep the selected controller neutral."
    return true
end
local function equipment_tick()
    if not T.gear_requested or T.gear_cancelled then return end
    local version=T.cancel_version
    local r=call("equipment.update",equipment.update,equipment)
    local e=status_of(equipment)
    if not r[1] or r.n~=2 or type(r[2])~="table" or not e then
        T.gear_unknown=true;stop_all("equipment update unavailable or malformed");return
    end
    if T.cancel_version~=version or T.gear_cancelled or T.unloaded then
        stop_all("equipment callback cancelled");return
    end
    if e.outcome=="unresolved" then
        T.gear_unknown=true;stop_all("equipment report cleanup is unresolved");return
    end
    if not e.retained and (e.phase=="done" or e.phase=="idle") then
        if T.gear_purpose=="mount" then
            if e.initial_state~=100 or e.expected_state~=504 or not e.qualified_transition
                or not e.acknowledged or e.unloaded then
                stop_all("board-to-feet transition did not qualify with cleared ACK duty");return
            end
            T.gear_requested=false;T.phase="armed"
            T.detail="Feet504 acquisition complete; waiting for closed-menu neutral source qualification."
            T.ready_since=nil;T.ready_ticks=0;T.ready_last=nil
            persist(true)
        else
            T.gear_requested=false;T.phase=T.used and "done" or "idle"
            T.detail=e.current_transition==true and "Stock target observed; consumption remains unobserved."
                or "Stock request ended without a qualified target; no automatic retry."
        end
    end
end
function object:prepare_backend()
    if T.session_retired then return false end
    if source or spawn then return source~=nil and spawn~=nil end
    if T.unloaded or T.stop_latched or not qualification_only then return false end
    -- Dependencies were staged individually. These require calls are cache hits.
    local Source=require("./lease_source")
    local BikeSpawn=require("./bike_spawn")
    Identity=require("./lease_identity")
    G=require("./bike_geometry")
    -- The facade stages Ride, Contact and every module they require before this
    -- call. Binding them here keeps require off the first following tick, where
    -- create_ride runs. Neither module calls reskate.* when it loads.
    local Ride=require("./ride_runtime")
    local Contact=require("./contact_runtime")
    local ForceStage=require("./force_stage")
    -- S2 declared change: the facade staged bones and mounted_pose; the Poser calls nothing when made.
    MP=require("./mounted_pose");poser=MP.new(pose_api)
    -- S2c declared change: the board drop. Required here under pcall, not staged by the facade: its first
    -- require compiles it in this startup tick (the startup keeps S2b's ticks), and a board_drop.lua that does
    -- not load leaves the ride without the drop (board stays nil; Core's board status says why) rather than
    -- ending the startup. The Dropper calls nothing when made.
    do
        local loaded,mod,made=pcall(function() local m=require("./board_drop");return m,m.new(board_api) end)
        if loaded and type(made)=="table" then BD,board=mod,made
        else
            T.board_issue=short("board_drop.lua did not load; the board stays in his hand: "..tostring(mod))
            T.board_status=freeze_tree({state="unavailable",issue=T.board_issue,toss_calls=0,clear_calls=0,bones_calls=0})
        end
    end
    if type(Ride)~="table" or type(Ride.new)~="function" or type(Contact)~="table"
        or type(Contact.decode)~="function" or type(ForceStage)~="table" or type(ForceStage.new)~="function" then return false end
    RideRuntime=Ride;ride_models=table.freeze({contact=Contact,force=ForceStage.new()})
    T.ride_modules_bound=true;T.ride_trick_adapter=ride_models.tricks~=nil
    source=Source.new(input_proxy,{setup_ms=15000,capture_ms=4000,cleanup_ms=4000})
    T.source_instances=(T.source_instances or 0)+1
    if BikeSpawn.floor_spawn_qualified()==true and lookup("world.raycast") then
        -- Keep the default proxy unchanged. The private floor query shares
        -- Core's call ledger and cancellation boundary, with one attempt only.
        local floor_query_used=false
        spawn_api.world.raycast=function(...)
            if T.stop_latched or T.unloaded or floor_query_used then
                error("spawn floor ray cancelled or already consumed",0)
            end
            floor_query_used=true
            local generation=T.generation
            local r=call("spawn.world.raycast",lookup("world.raycast"),...)
            if not current(generation) then error("spawn floor ray cancelled during callback",0) end
            if not r[1] then error("spawn floor ray callback failed",0) end
            return table.unpack(r,2,r.n)
        end
    end
    spawn=BikeSpawn.new(spawn_api)
    T.spawn_instances=(T.spawn_instances or 0)+1
    return true
end
function object:status()
    -- All three dependency status methods are local cached reads. Detached
    -- copying strips private epochs/handles and refuses opaque nested values.
    local ok,result=pcall(snapshot)
    if ok then return result end
    return {phase="retained_unknown",detail="Diagnostic copy refused; preserve SDK cleanup duty.",
        mount_enabled=false,qualification_only=qualification_only,bike_authority=true,
        cleanup_pending=true,cleanup_unknown=true,stock_toggle_blocked=true,used=T.used==true,
        unloaded=T.unloaded==true,equipment={phase="unknown",retained=true},storage_key=KEY}
end
function object:request_mount(slot,admitted)
    if not valid_slot(slot) then return false,"Choose an XInput slot from0 to3" end
    -- This branch precedes clock, storage, facts and all other API calls.
    if not qualification_only then return false,"Native bike lifecycle qualification unavailable" end
    if T.busy then
        if T.intent_inflight or T.active or T.gear_requested then stop_all("reentrant mount request") end
        return false,"Bike lifecycle operation already in progress"
    end
    if (T.used and admitted~=T) or mount_attempt_used or T.session_retired or (vm_attempt_used and not (session and session.index==2)) or T.unloaded or stock_blocked() then return false,session and "Consumed attempt, busy or retained duty prevents admission" or "One attempt per VM; busy or retained duty prevents rearm" end
    mount_attempt_used=true;T.busy=true;T.intent_inflight=true;T.used=true;vm_attempt_used=true;T.slot=slot
    local generation=T.generation
    local clear=marker_clear()
    if clear and current(generation) then
        T.ledger_owned=true;T.phase="armed";T.detail="One explicit zero-force qualification intent; no native acquisition yet."
        clear=persist(true) and current(generation)
    end
    local ok,missing=available()
    local now=clear and ok and clock() or nil
    local observed=now and facts() or nil
    if now then now=clock() end
    local accepted=false
    if not clear or not current(generation) then
        if not T.reload_blocked and not T.marker_unknown then stop_all("mount cancelled before acquisition") end
    elseif not ok then stop_all("Required API unavailable: "..short(missing))
    elseif not now or not base_ready(observed,true) or not observed.grounded
        or admitted==T and not Admission.matches(T.admitted_facts,observed) then
        stop_all("Grounded upright board100 or on-foot504 and focused gameplay required")
    else
        T.arm_at=T.arm_at or now;T.level=observed.level;T.wipeouts=observed.wipeouts
        T.initial_facts=observed;T.facts=observed;T.active=true
        if persist(true) and current(generation) then
            if observed.state==100 then accepted=begin_equipment(slot,"mount",100)
            else T.phase="armed";T.detail="Armed once; close both menus and rest the selected controller: sticks centred, triggers and buttons released.";accepted=true end
        end
    end
    T.intent_inflight=false;T.busy=false
    if not accepted then return false,short(T.detail) end
    return true
end
function object:request_stop(why)
    if T.session_retired or T.unloaded then return false,"Runtime is retired or unloaded; SDK retains cleanup" end
    if not T.used and not T.gear_requested and not T.intent_inflight then return true end
    stop_all(reason(why) and why or "explicit Stop")
    if T.ledger_owned then persist(true) end
    return true
end
function object:request_stock_toggle(slot,admitted)
    if T.session_retired then return false,"Retired session" end
    if not valid_slot(slot) then return false,"Choose an XInput slot from0 to3" end
    if stock_blocked() then
        if T.busy and (T.intent_inflight or T.active or T.gear_requested) then stop_all("reentrant stock request") end
        return false,"Bike, input, equipment or retained reload cleanup blocks stock switching"
    end
    -- Latch before marker/facts callbacks, before EquipmentRuntime sets pending.
    T.busy=true;T.intent_inflight=true
    local version=T.cancel_version
    local clear=marker_clear()
    local observed=clear and facts() or nil
    local accepted=false
    if clear and T.cancel_version==version and not T.unloaded and not T.storage_fault and not T.clock_unknown
        and base_ready(observed,true) and observed.grounded
        and (admitted~=T or Admission.matches(T.admitted_facts,observed)) then
        accepted=begin_equipment(slot,"stock",observed.state)
    elseif clear then T.detail="Stock request refused by fresh readiness or cancelled intent." end
    T.intent_inflight=false;T.busy=false
    if not accepted then
        -- A refused or cancelled request is terminal. The next quiescent tick
        -- saves it, after a deferred startup caller has restored its phase.
        T.persist_dirty=true
        return false,short(T.detail)
    end
    return true
end
local function tick(dt)
    -- Core's per-tick Follow counters reset with each Core step, which is not
    -- an SDK tick credential: the SDK's own quota stays authoritative.
    T.follow_reads_tick=0;T.lease_reads_tick=0;T.renewals_tick=0
    selected_source_frame=nil;tick_facts=nil;tick_authorization=nil
    if T.session_retired or T.unloaded or T.phase=="blocked" then return end
    if not T.used and not T.gear_requested or T.phase=="done" and not T.gear_requested then
        -- No tick-end save runs from here, so a throttled snapshot would
        -- otherwise remain the cached ledger for the rest of this VM.
        if T.persist_dirty then persist(true) end
        return
    end
    -- The tick that completes or cancels a stock request leaves the next tick
    -- on the quiescent return above, so that terminal record is saved now.
    local stock_open=T.gear_purpose=="stock" and T.gear_requested==true and not T.gear_cancelled
    local published_now=false
    local now=clock()
    if not finite(dt) or dt<=0 or dt>MAX_TICK_MS or now and T.last_step_at and now<=T.last_step_at then
        stop_all("invalid, stalled or reversed wall tick")
    end
    if now then T.last_step_at=now end
    if T.gear_requested and not T.gear_cancelled then equipment_tick() end
    if T.active and now and not T.stop_latched then
        local f=facts();T.facts=f;tick_facts=f
        if not base_ready(f,T.gear_requested and T.gear_purpose=="mount") then
            stop_all("fresh sampled upright/focus/context/fall readiness lost")
        elseif T.gear_requested then
            -- Equipment owns its report transaction. No selected source yet.
        elseif not T.source_armed then
            if now-T.arm_at>=60000 then stop_all("mount intent expired before acquisition")
            elseif closed_ready(f,true) then
                if not T.ready_since then T.ready_since=now;T.ready_last=now;T.ready_ticks=0
                elseif now>T.ready_last then T.ready_ticks+=1;T.ready_last=now end
                if now-T.ready_since>=600 and T.ready_ticks>=10 then
                    T.source_armed=true;T.effect_at=now
                    local generation=T.generation
                    local r=call("source.arm",source.arm,source,T.slot,now)
                    if not yes(r) or not current(generation) then stop_all("source Arm refused, cancelled or unknown")
                    else T.phase="capturing" end
                end
            else T.ready_since=nil;T.ready_ticks=0;T.ready_last=nil end
        elseif not closed_ready(f,T.phase~="following") then stop_all("fresh menu/input/grounded acquisition gate lost") end
        -- S2 declared change: the 60 s window needs the effect watchdog past it (65 s from source Arm).
        if T.effect_at and now-T.effect_at>=65000 and not session_following() then stop_all("total effect watchdog expired") end
    end
    if T.source_armed and not source_clean() then
        local generation=T.generation
        local allow=not T.stop_latched and closed_ready(T.facts,T.phase~="following")
        T.source_inflight=true;T.input_current=false
        local frame=call("source.step",source.step,source,T.now or 0,{allow_acquire=allow,allow_drive=allow,
            allow_cleanup_reconcile=source_cleanup_open(T.now)})
        T.source_inflight=false
        if T.stop_needs_cleanup then stop_all(T.stop_reason) end
        if frame[1] and frame.n==2 and type(frame[2])=="table" then
            T.source_record=source_record(frame[2])
            if not T.stop_latched and T.input_seen and frame[2].input_ok~=true then stop_all("current selected-stream input permission lost") end
            if not T.stop_latched and (frame[2].cleanup_pending or frame[2].cleanup_unknown
                or frame[2].phase=="complete" or frame[2].phase=="stopping" or frame[2].phase=="draining") then
                stop_all("source stopped or retained cleanup duty")
            end
            if current(generation) and frame[2].input_ok then
                T.input_seen=true;T.input_current=true
                selected_source_frame=frame[2] -- Exact private Source output, never source_record DTO.
                local riding=RIDE_COMPOSITION_QUALIFIED and T.phase=="following" and T.published_seen==true
                if not BikeRuntime.selected_pad_admitted(frame[2],T.slot,riding) then
                    stop_all(riding and "selected riding pad unavailable or malformed" or "selected pad left neutral")
                elseif not T.spawn_requested then
                    T.spawn_requested=true
                    local r=call("spawn.request",spawn.request,spawn)
                    if not yes(r) or not current(generation) then stop_all("one spawn request refused, cancelled or unknown")
                    else T.phase="spawning" end
                end
            end
        else stop_all("source step exception or malformed frame") end
    end
    if not T.stop_latched and T.input_current and T.spawn_requested and not T.handoff_attempted then
        local generation=T.generation
        call("spawn.update",spawn.update,spawn,dt)
        local b=status_of(spawn)
        if not current(generation) then stop_all("cancelled during spawn callback")
        elseif not b or b.cleanup_unknown or b.phase=="closed" or b.phase=="cleanup_unknown" or b.phase=="clock_prepared" then
            stop_all("spawn stopped; no retry")
        elseif b.phase=="spawned" then handoff_and_follow();published_now=true end
    end
    -- The publish tick has already read the reservation receipt; its first
    -- following read, lease report and body read come on the next tick (B9).
    if T.phase=="following" and not T.stop_latched and T.input_current and not published_now then
        now=clock()
        if not lease_live(now) then stop_all("ride window or Follow lease ended")
        else
            local generation=T.generation
            if not read_follow(true) and current(generation) then stop_all("bounded follow receipt unavailable before body read") end
            if current(generation) then read_lease() end
            if current(generation) then
                now=clock()
                if not lease_live(now) then stop_all("ride window or Follow lease ended during receipt or lease read")
                elseif current(generation) then
                    local measured_body=T.body
                    local r=call("body.read",lookup("world.physics.read"),measured_body)
                    now=clock()
                    if not lease_live(now) then stop_all("ride window or Follow lease ended during body read")
                    elseif not r[1] or r.n~=2 or type(r[2])~="table" then stop_all("following body observation unavailable")
                    elseif RIDE_COMPOSITION_QUALIFIED and T.body~=measured_body then
                        stop_all("body owner changed during same-read subordinate observation")
                    elseif current(generation) and renew_follow_once(r[2],generation) then
                        now=T.now -- The renewal's own clock reads, if it made any.
                        observe_ride(selected_source_frame,r[2],now)
                        -- The same read, drawn in the pose of Ride's step on it (or its last accepted one).
                        local pose=BikeRuntime.follow_pose(ride and T.ride_status)
                        local v=current(generation) and call("spawn.follow_visual",spawn.follow_visual,spawn,r[2],now,pose) or {false,n=1}
                        now=clock()
                        if not yes(v) or not now or not current(generation) then
                            stop_all(BikeRuntime.follow_visual_stop("follow visual",v))
                        elseif not lease_live(now) then stop_all("ride window or Follow lease ended during visual update")
                        -- S2 declared change: the rider posed on the bike just drawn, from the same read and pose.
                        elseif poser then pose_tick(r[2],pose,now) end
                    end
                end
            end
        end
    end
    if T.stop_latched and not T.bike_cleanup_complete then cleanup_tick() end
    persist(stock_open and (not T.gear_requested or T.gear_cancelled==true))
end
function object:step(dt_ms)
    if T.busy then
        if T.intent_inflight or T.active or T.gear_requested then stop_all("reentrant lifecycle step") end
        return self:status()
    end
    T.busy=true
    local ok=pcall(tick,dt_ms)
    if not ok then
        T.source_inflight=false
        stop_all("lifecycle exception; no retry")
        persist(true)
    end
    T.busy=false
    return self:status()
end
function object:unload()
    if T.session_retired or T.unloaded then return self:status() end
    T.unloaded=true;T.generation+=1
    if T.used or T.gear_requested or T.intent_inflight then stop_all("unload; SDK retains unresolved native duty") end
    drain_ride()
    pose_stop() -- S2 declared change: and on unload
    if source then call("source.unload",source.unload,source) end
    call("equipment.unload",equipment.unload,equipment)
    if T.used then stop_spawn_when_allowed("unload visual cleanup");persist(true) end
    return self:status()
end
-- These hooks stay inside one facade-owned experimental factory. They never
-- expose or recycle native handles, and default Core.new has no such handoff.
local function cycle_ready(expected,after_attempt)
    if not session or not mount_attempt_used or T.session_retired or T.unloaded or T.busy or T.saving
        or T.gear_requested or T.intent_inflight or T.cleanup_expired or T.storage_fault or T.clock_unknown
        or not T.ledger_owned or T.reload_blocked or T.marker_unknown or T.phase~="done"
        or T.bike_cleanup_complete~=true or stock_blocked() or not source_clean() or not force_clear()
        or T.follow~=nil or T.body~=nil or T.completed_ack~=true or T.acknowledged~=true
        or T.ack_attempted~=true or not visuals_accepted() then return false,"Prior lifecycle is not fully clean" end
    local terminal=T.terminal
    if type(terminal)~="table" or terminal.phase~="completed" or terminal.terminal~=true
        or terminal.park_observed~=true or terminal.in_flight~=0 or type(terminal.pending)~="table" or next(terminal.pending)~=nil
        or terminal.final_revision=="0" or terminal.final_revision~=terminal.returned_revision
        or terminal.sequence~=T.sequence or terminal.orphaned~=false then return false,"Matched park/Follow ACK required" end
    local pose,board=T.pose_status,T.board_status
    if type(pose)~="table" or pose.stopped~=true or pose.state~="off" or pose.nil_accepted~=true
        or pose.issue~=nil or type(board)~="table" or board.state~="restored" or board.clear_result~="cleared"
        or board.issue~=nil then return false,"Pose and board cleanup must be confirmed" end
    local e=status_of(equipment)
    if not e or e.phase~="done" or e.retained~=false or e.unloaded or e.storage_fault
        or e.storage_accepted~=true or e.acknowledged~=true or e.qualified_transition~=true
        or e.current_transition~=true or e.expected_state~=expected or e.outcome~="target_observed"
        or type(e.attempt)~="number" or e.attempt%1~=0 or e.attempt<1
        or after_attempt and e.attempt<=after_attempt then return false,"Fresh target and equipment ACK required" end
    local receipt=e.terminal_receipt
    if type(receipt)~="table" or receipt.terminal~=true or receipt.report_debt~=false
        or receipt.claim_released~=true or receipt.quarantined~=false or receipt.orphaned~=false then
        return false,"Equipment terminal debt remains"
    end
    return true,e.attempt
end
local function cycle_checkpoint(expected,after_attempt,key,retire)
    local ok,attempt=cycle_ready(expected,after_attempt)
    if not ok then return false,attempt end
    -- Capture the already-clean detached record before the callback-exclusion
    -- latch: stock_blocked truthfully treats busy as blocked during callbacks.
    local got,row=pcall(snapshot)
    if not got then return false,"Terminal snapshot unavailable" end
    T.busy=true
    local version=T.cancel_version
    local now=clock()
    local f=now and facts() or nil
    local valid=now and f and base_ready(f,true) and f.grounded and f.state==expected
        and T.cancel_version==version and not T.unloaded and not T.session_retired
    if valid and key then
        local fits=BikeRuntime.ledger_bound(row)
        if not fits or fits>LEDGER_LIMIT then
            local encoded=call("json.encode",lookup("json.encode"),row)
            valid=encoded[1] and encoded.n==2 and type(encoded[2])=="string" and #encoded[2]<=LEDGER_LIMIT
        end
        if valid and T.cancel_version==version and not T.unloaded then
            local saved=call("storage.set",lookup("storage.set"),key,row)
            valid=saved[1] and saved.n==1 -- Host cache acceptance only.
            if not valid then T.storage_fault=true end
        else valid=false end
    end
    valid=valid and T.cancel_version==version and not T.unloaded and not T.session_retired
        and not T.storage_fault and not T.clock_unknown
    T.busy=false
    if not valid then return false,"Cycle archive/readiness changed or storage failed" end
    local still,why=cycle_ready(expected,after_attempt)
    if not still then return false,why end
    if retire then
        -- No callback follows until this owner is irreversibly inert. Old
        -- step/stop/unload and all its SDK closures can no longer write.
        T.session_retired=true;T.generation+=1;T.cancel_version+=1
    end
    return true,attempt
end
local hooks={
    checkpoint=cycle_checkpoint,
    can_return=function() return cycle_ready(100,nil) end,
    ready=function(after_attempt)
        if T.session_retired or T.unloaded or T.gear_unknown or T.gear_cancelled or T.storage_fault
            or T.clock_unknown or T.startup_closed then return false,"On-foot preparation failed or became uncertain" end
        if T.gear_requested then return false,"pending" end
        return cycle_checkpoint(504,after_attempt,nil,false)
    end,
    initialize=function() return persist(true) end,
}
return table.freeze(object),hooks
end

function BikeRuntime.new(services,options,shared_state)
    return (new_core(services,options,shared_state,nil))
end
local experimental_owner_created=false
function BikeRuntime.experimental_two_cycle_owner()
    if experimental_owner_created or vm_attempt_used then return nil,"VM already has a bike owner or attempt" end
    experimental_owner_created=true
    local made,hooks,failed,return_attempt,epoch=0,nil,false,nil,0
    local owner={}
    function owner:abort_preparation() epoch+=1;failed=true end
    function owner:first(services,options,state)
        if failed or made~=0 or vm_attempt_used then return nil,"First private session unavailable" end
        made=1
        local object
        object,hooks=new_core(services,options,state,{index=1})
        return object
    end
    function owner:can_archive_return()
        if failed or made~=1 or return_attempt then return false,"Second intent unavailable" end
        return hooks.can_return()
    end
    function owner:archive_return()
        if failed or made~=1 or return_attempt then return false,"Second intent already consumed or unavailable" end
        -- Burn before fallible callbacks: a failed archive can never be retried.
        failed=true
        local version=epoch
        local ok,attempt=hooks.checkpoint(100,nil,"bmx_bike_cycle_1_stock100_v1",false)
        if not ok or epoch~=version then return false,epoch~=version and "Preparation cancelled" or attempt end
        return_attempt=attempt;failed=false
        return true
    end
    function owner:ready()
        if failed or made~=1 or not return_attempt then return false,"Second preparation is unavailable" end
        local version=epoch
        local ok,why=hooks.ready(return_attempt)
        if failed or epoch~=version then return false,"Preparation cancelled" end
        return ok,why
    end
    function owner:successor(services,options,state)
        if failed or made~=1 or not return_attempt then return nil,"No private successor available" end
        failed=true;made=2
        local version=epoch
        local ok,why=hooks.checkpoint(504,return_attempt,"bmx_bike_cycle_1_onfoot504_v1",true)
        if not ok then return nil,why end
        state.ledger_owned=true
        local object,next_hooks=new_core(services,options,state,{index=2})
        -- Replace the active marker only after both old snapshots were saved
        -- and old callbacks are inert, before any successor actuator exists.
        if not next_hooks.initialize() or epoch~=version then return nil,"Successor active marker failed or intent cancelled" end
        return object
    end
    return table.freeze(owner)
end
return table.freeze(BikeRuntime)

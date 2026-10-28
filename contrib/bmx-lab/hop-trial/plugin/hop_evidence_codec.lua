-- Private evidence format only. No SDK, storage, game or qualification authority.
local Codec={version=4,encoding='hop-delta-v4',pair_pointer_bytes=2048,pair_wire_meta_bytes=16,pair_state_meta_bytes=256}
local field_text=[[
__index
__mode
a
accounting_known
ack
ack_attempted
acknowledge_attempted
acknowledged
active
actor_lane
angular_impulse
angular_speed
angular_velocity
ankles
arguments
arity
at_ms
attempts
b
back
balance_normal
balance_normal_available
base_ms
bike_authority
bike_cleanup_complete
blend
board_drop
board_drop_inflight
board_issue
board_reason
board_restore_inflight
board_restore_pending
board_restore_unresolved
board_return
board_state
body
bones_calls
bones_result
boolean
brake
budget_exhausted
buttons
call
call_ok
capability
capture
capture_reserved
capture_state
capturing
center_of_mass
chunk_bytes
chunk_rows
claim_known
cleanup_disposition
cleanup_pending
cleanup_unknown
clear_calls
clear_result
clock_unknown
command_state
common
completed_acknowledged
confirmed
contact
contact_scale
context_generation
controls
critical_bytes
critical_rows
detail
diagnostic
diagnostic_only
disposition
down
drop_inflight
drop_ms
ends
epoch_matches
equipment
equipment_purpose
event_schemas
expires_ms
final_native_epoch
final_revision
follow
force
force_applied
force_attempted
force_cleanup_clear
force_cleanup_unknown
force_model
force_pending
force_ready
force_reason
forward
fraction
generation
grounded
grounded_known
handoff_unknown
hips
hop
hop_applied
hop_disposition
hop_event_id
hop_impulse
hop_strength
id
identity
impulse
impulse_id
in_flight
inertia
inertia_body
input_ok
issue
item
k
known
last_observation
last_sent
last_serial
last_source_step
lb
lease
lease_handle_present
lease_state
left
left_stick
left_trigger
left_x
left_y
lifetime_ms
lifetime_remaining_ms
limit
limits
linear_impulse
linear_velocity
local_actor_excluded
mapped_hop
marker_unknown
mass
measurements_complete
model
model_body
model_steps
motion
mount_deadline_ms
mount_ms
mounted_ms
mounted_pose
named_actor_categories_absent
native_casts
native_preparation
native_retirement_known
neutral
neutral_releases
new_observation
nil_accepted
nil_calls
normal
normal_available
number
observation_serial
observed_ms
observed_steps
ordinary_release_accepted
ordinary_release_attempted
orientation
orphaned
out
outcome
owned_bodies_excluded
packet
pad
park_observed
park_reason
pedal
pending
pending_commands
pending_count
pending_hop
pending_limit
pending_sequence
phase
plan
playstation
point
pose
pose_plan
pose_release_unresolved
position
preparation
prepare
preview
preview_model
produced_serial
provenance
publications
qualified
qualified_transition
quarantined
query
radius
ray
rays
rb
ready_ms
reason
receipt
regular_bytes
regular_rows
remaining_ms
renewable
renewal_ms
renewals
report_debt
requested_ms
requested_query_preset
requested_serial
reserve_unknown
restore_inflight
restore_ms
restore_pending
restore_tried
result
retained
retained_reload_marker
returned_revision
revision
revocation
ride
right
right_stick
right_trigger
right_x
right_y
rotation
rotation_reserved
row_bytes
sample
samples
scope
seconds
selected_slot
sends
sent_ticks
separation
sequence
serial
source
source_epoch
source_released
source_state
spawn
start
state
states
status
steer
stock_requested
stock_toggle_blocked
stop_latched
stop_ms
stop_reason
stop_requested
stopped
storage_fault
strength
submit
submitted
subordinate
successor
successor_available
summary_bytes
support
surface_velocity
surface_velocity_available
table
terminal
terminal_receipt
terminal_schema
text
text_bytes
ticks
time
torque
torque_attempted
toss_calls
toss_result
trick_scope
tried
unknown
unloaded
unresolved_debt
up
user
v
valid
vec3
vec4
velocity
verified_plane
visual_cleanup_deferred
visual_hit
wall_ms
weight
wheel
wheel_contact
wheel_sample
wheels
wrists
x
y
]]
local fields,field_ids={},{}
for name in field_text:gmatch("%S+") do fields[#fields+1]=name;field_ids[name]=#fields end
Codec.fields=table.freeze(fields)
local kinds={"source","body","contact","force_pending","mapped_hop","preview","submit","receipt","ack","pose","follow","lease","prepare","terminal"}
local kind_ids={};for i,name in ipairs(kinds) do kind_ids[name]=i end
Codec.kinds=table.freeze(kinds)
local DATA_MAX,ROW_MAX,NODE_MAX,DEPTH_MAX=11904,12288,768,32
local row_keys={kind=true,data=true,first_call=true,last_call=true,repeats=true,first_at_ms=true,last_at_ms=true,incomplete=true,critical=true,paired=true}
local function fail(why) error("hop codec: "..why,0) end
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function integer(v,lo,hi) return finite(v) and v%1==0 and v>=lo and v<=hi end
local function string_cost(v)
    local n=2
    for i=1,#v do local c=string.byte(v,i);n+=((c<32 or c==34 or c==92 or c>=127) and 6 or 1) end
    return n
end
local function digits(v) return #tostring(v) end
-- The SDK writes integral doubles through int64 JSON, up to inclusive 2^53.
-- Count decimal characters without Luau tostring's scientific notation.
-- Canonical expanded/state data keeps its separate 32-byte numeric charge.
local function number_wire_cost(v)
    local magnitude=math.abs(v)
    if v==math.floor(v) and magnitude<=9007199254740992 then
        local bytes,threshold=1,10
        while magnitude>=threshold do bytes+=1;threshold*=10 end
        return bytes+(v<0 and 1 or 0)
    end
    return 32
end
local function dense(v,n)
    if not plain(v) then fail("dense plain array required") end
    local count=0
    for k in pairs(v) do if not integer(k,1,n) then fail("array key or arity") end;count+=1 end
    if count~=n then fail("array key or arity") end
end
local function array_count(v,limit)
    if not plain(v) then fail("plain array required") end
    local n=#v;if n>limit then fail("array limit") end;dense(v,n);return n
end
local function token(key)
    if type(key)=="string" then local id=field_ids[key];if not id then fail("unknown data field") end;return id end
    if integer(key,1,32) then return -key end
    fail("invalid data key")
end
local function key_for(id)
    if integer(id,1,#fields) then return fields[id] end
    if integer(id,-32,-1) then return -id end
    fail("invalid field token")
end
local function sorted_tokens(value)
    local out={};for key in pairs(value) do out[#out+1]=token(key) end;table.sort(out);return out
end
local function data_size(value,depth,b,seen)
    if depth>DEPTH_MAX then fail("expanded depth limit") end
    b.nodes+=1;if b.nodes>NODE_MAX then fail("expanded node limit") end
    local t=type(value)
    if t=="number" then if not finite(value) then fail("nonfinite data") end;return 32 end
    if t=="boolean" then return 5 end
    if t=="string" then if #value>192 then fail("text limit") end;return string_cost(value) end
    if not plain(value) or seen[value] then fail("nonplain or cyclic data") end
    seen[value]=true
    local bytes=2
    for key,child in pairs(value) do
        token(key);b.nodes+=1;if b.nodes>NODE_MAX then fail("expanded node limit") end
        bytes+=(type(key)=="string" and #key+4 or digits(key)+4)+data_size(child,depth+1,b,seen)
        if bytes>DATA_MAX then fail("expanded data byte limit") end
    end
    seen[value]=nil
    return bytes
end
local function checked_data(value)
    if not plain(value) then fail("data root must be a plain table") end
    local n=data_size(value,1,{nodes=0},{})
    if n>DATA_MAX then fail("expanded data byte limit") end
    return n
end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b and (type(a)~="number" or a~=0 or 1/a==1/b) end
    for k,v in pairs(a) do if not equal(v,rawget(b,k)) then return false end end
    for k in pairs(b) do if rawget(a,k)==nil then return false end end
    return true
end
local function full(value)
    if type(value)~="table" then return type(value)=="number" and value==0 and 1/value==-math.huge and {4} or {1,value} end
    local pairs_out={}
    for _,id in ipairs(sorted_tokens(value)) do pairs_out[#pairs_out+1]={id,full(rawget(value,key_for(id)))} end
    if #pairs_out==0 then return {2,false} end
    return {2,pairs_out}
end
local function node_cost(node,depth,b,seen)
    if depth>DEPTH_MAX or 4+3*(depth-1)>32 then fail("wire JSON depth limit") end
    if not plain(node) or seen[node] then fail("nonplain or cyclic wire") end
    seen[node]=true;b.nodes+=1;if b.nodes>4096 then fail("wire node limit") end
    local tag=rawget(node,1)
    local bytes
    if tag==0 or tag==4 then dense(node,1);bytes=3
    elseif tag==1 then
        dense(node,2);local v=node[2];local t=type(v)
        if t=="number" then if not finite(v) or v==0 and 1/v==-math.huge then fail("nonfinite or noncanonical wire scalar") end;bytes=4+number_wire_cost(v)
        elseif t=="boolean" then bytes=9
        elseif t=="string" and #v<=192 then bytes=4+string_cost(v)
        else fail("invalid wire scalar") end
    elseif tag==2 or tag==3 then
         dense(node,2);local list=node[2];local count=0
        if list~=false then
            count=array_count(list,768);if count==0 then fail("empty pair sentinel required") end
            if seen[list] then fail("cyclic pair list") end;seen[list]=true
        end
        bytes=list==false and 9 or 6+math.max(0,count-1);local prior=-33
        for _,pair in ipairs(list==false and {} or list) do
            dense(pair,2);local id=pair[1];key_for(id)
            if id<=prior then fail("duplicate or unordered field") end;prior=id
            bytes+=3+digits(id)+node_cost(pair[2],depth+1,b,seen)
        end
        if list~=false then seen[list]=nil end
    else fail("unknown node tag") end
    seen[node]=nil;return bytes
end
local function cost(node) return node_cost(node,1,{nodes=0},{}) end
local function delta(value,base)
    if type(value)~="table" or type(base)~="table" then return full(value) end
    local changed,all={},{}
    for key in pairs(value) do all[token(key)]=true end
    for key in pairs(base) do all[token(key)]=true end
    local ids={};for id in pairs(all) do ids[#ids+1]=id end;table.sort(ids)
    for _,id in ipairs(ids) do
        local key=key_for(id);local v,old=rawget(value,key),rawget(base,key)
        if v==nil then changed[#changed+1]={id,{0}}
        elseif old==nil then changed[#changed+1]={id,full(v)}
        elseif not equal(v,old) then changed[#changed+1]={id,delta(v,old)} end
    end
    local patch=#changed==0 and {3,false} or {3,changed};local anchor=full(value)
    return cost(patch)<cost(anchor) and patch or anchor
end
-- Only share an inherited branch if every descendant is already immutable.
-- Validation has bounded depth/nodes and rejected cycles before this walk.
-- Never freeze a caller-owned base to obtain immutability.
local function deeply_frozen(value)
    if type(value)~="table" then return true end
    if not table.isfrozen(value) then return false end
    for _,child in pairs(value) do if not deeply_frozen(child) then return false end end
    return true
end
local function detached(value)
    if type(value)~="table" or deeply_frozen(value) then return value end
    local out={};for key,child in pairs(value) do out[key]=detached(child) end
    return table.freeze(out)
end
local function apply(node,base,allow_delta,depth)
    if depth>DEPTH_MAX then fail("expanded depth limit") end
    local tag=node[1]
    if tag==0 then fail("root deletion") end
    if tag==1 then return node[2] end
    if tag==4 then return -1/math.huge end
    if tag~=2 and tag~=3 then fail("unknown node tag") end
    if tag==3 and (not allow_delta or not plain(base)) then fail("delta without table base") end
    local out={}
    if tag==3 then for key,v in pairs(base) do out[key]=detached(v) end end
    for _,pair in ipairs(node[2]==false and {} or node[2]) do
        local key,child=key_for(pair[1]),pair[2]
        if child[1]==0 then
            if tag~=3 or rawget(base,key)==nil then fail("invalid deletion") end;out[key]=nil
        else
            if tag==2 and child[1]~=1 and child[1]~=2 and child[1]~=4 then fail("nonfull anchor child") end
            out[key]=apply(child,tag==3 and rawget(base,key) or nil,tag==3,depth+1)
        end
    end
    return table.freeze(out)
end
local function projection(row)
    local p=rawget(row.data,"call")
    if p==nil then return "" end
    if type(p)~="string" or #p>192 then fail("invalid projection") end
    return p
end
-- This conservative subset matches the exact sanitized public SDK DTO builders.
-- Unknown/contradictory results stay separately retained under legacy rules.
local state_fields={}
for key in ("call arity call_ok sequence user source_epoch context_generation status reason terminal requested_ms expires_ms observed_ms last_observation renewals source_released capture_reserved orphaned capturing report_debt"):gmatch("%S+") do state_fields[key]=true end
local capture_fields={}
for key in ("call arity call_ok sequence user source_epoch context_generation phase reason terminal quarantined capturing report_debt generation revision expires_ms publications neutral_releases"):gmatch("%S+") do capture_fields[key]=true end
local shared_ids=table.freeze({"sequence","source_epoch","context_generation","expires_ms"})
local state_ids=table.freeze({"requested_ms","observed_ms","last_observation"})
local capture_ids=table.freeze({"generation","revision"})
local function decimal_id(value,nonzero)
    return type(value)=="string" and #value>=1 and #value<=20 and value:match("^%d+$")~=nil
        and (value=="0" and not nonzero or value:sub(1,1)~="0")
        and (#value<20 or value<="18446744073709551615")
end
local function decimal_le(a,b) return #a<#b or #a==#b and a<=b end
local function add250(value)
    local text="";local carry=250
    for at=#value,1,-1 do
        local n=string.byte(value,at)-48+carry
        text=string.char(48+n%10)..text;carry=math.floor(n/10)
    end
    while carry>0 do text=string.char(48+carry%10)..text;carry=math.floor(carry/10) end
    return text
end
local function known_pair_data(data)
    local state=data.call=="input.lease_state"
    if not state and data.call~="input.lease_capture_state" then return false end
    local allowed=state and state_fields or capture_fields
    for key in pairs(data) do if not allowed[key] then return false end end
    for key in pairs(allowed) do if rawget(data,key)==nil then return false end end
    if data.call_ok~=true or data.arity~=1 or not integer(data.user,0,3)
        or data.user==0 and 1/data.user==-math.huge or data.reason~="none" or data.terminal~=false then return false end
    for _,key in ipairs(shared_ids) do
        if not decimal_id(data[key],true) then return false end
    end
    if state then
        if data.status~="active" or data.capturing~=false or data.report_debt~=false or data.source_released~=false
            or data.orphaned~=false or type(data.capture_reserved)~="boolean" or not decimal_id(data.renewals,false) then return false end
        for _,key in ipairs(state_ids) do if not decimal_id(data[key],true) then return false end end
        return decimal_le(data.requested_ms,"18446744073709551365")
            and decimal_le(add250(data.requested_ms),data.expires_ms) and decimal_le(data.requested_ms,data.observed_ms)
            and not decimal_le(data.expires_ms,data.observed_ms)
    end
    local capturing=data.phase=="capturing"
    if not capturing and data.phase~="waiting_neutral" then return false end
    if data.quarantined~=false or data.capturing~=capturing or data.report_debt~=capturing then return false end
    for _,key in ipairs(capture_ids) do if not decimal_id(data[key],true) then return false end end
    if not decimal_id(data.publications,false) or not decimal_id(data.neutral_releases,false)
        or not decimal_le(data.neutral_releases,data.publications) then return false end
    return capturing and data.publications~="0" or not capturing and data.publications=="0" and data.neutral_releases=="0"
end
local function validate_row(row)
    if not plain(row) then fail("plain logical row required") end
    for key in pairs(row) do if not row_keys[key] then fail("unknown row field") end end
    if not kind_ids[row.kind] or type(row.critical)~="boolean" or type(row.incomplete)~="boolean"
        or not integer(row.first_call,1,10000000) or not integer(row.last_call,row.first_call,10000000)
        or not integer(row.repeats,1,row.last_call-row.first_call+1) then fail("invalid row metadata") end
    for _,key in ipairs({"first_at_ms","last_at_ms"}) do local v=rawget(row,key);if v~=nil and (not finite(v) or v<0) then fail("invalid row time") end end
    checked_data(row.data);projection(row)
    if rawget(row,"paired")~=nil then
        if row.paired~=true or row.critical or row.incomplete or row.kind~="lease" or row.repeats~=2
            or row.first_call>=row.last_call or not known_pair_data(row.data) then fail("invalid sealed pair") end
    end
end
local function valid_base(row,base,expected)
    if base~=nil then
        validate_row(base)
        if row.critical or base.critical or row.kind~=base.kind or projection(row)~=projection(base)
            or base.first_call>=row.first_call or expected and expected~=base.first_call then fail("wrong or forward base") end
    elseif expected and expected~=0 then fail("missing base") end
end
local function negative_zero(v) return type(v)=="number" and v==0 and 1/v==-math.huge end
local function pack_time(v) if v==nil then return false end;if negative_zero(v) then return "-0" end;return v end
local function time_cost(v)
    if v==false then return 5 end
    if v=="-0" then return 4 end
    if not finite(v) or v<0 or negative_zero(v) then fail("invalid wire time") end
    return number_wire_cost(v)
end
local function row_cost(wire)
    dense(wire,12)
    if type(wire[1])~="boolean" or not integer(wire[2],1,#kinds) or type(wire[3])~="string" or #wire[3]>192
        or not integer(wire[4],0,10000000) or not integer(wire[5],1,10000000)
        or not integer(wire[6],wire[5],10000000) or not integer(wire[7],1,wire[6]-wire[5]+1)
        or type(wire[10])~="boolean" or type(wire[12])~="boolean" then fail("invalid wire metadata") end
    if wire[12] and (wire[1] or wire[10] or wire[2]~=kind_ids.lease or wire[7]~=2 or wire[6]<=wire[5]
        or wire[3]~="input.lease_state" and wire[3]~="input.lease_capture_state") then fail("invalid sealed pair metadata") end
    return 13+5+digits(wire[2])+string_cost(wire[3])+digits(wire[4])+digits(wire[5])+digits(wire[6])+digits(wire[7])
        +time_cost(wire[8])+time_cost(wire[9])+5+cost(wire[11])+5+Codec.pair_wire_meta_bytes
end
local function freeze_tree(value)
    if type(value)=="table" and not table.isfrozen(value) then
        for _,child in pairs(value) do freeze_tree(child) end;table.freeze(value)
    end
    return value
end
local function encode_row(row,base)
    validate_row(row);valid_base(row,base)
    local node=base and delta(row.data,base.data) or full(row.data)
    local wire={row.critical,kind_ids[row.kind],projection(row),base and base.first_call or 0,
        row.first_call,row.last_call,row.repeats,pack_time(row.first_at_ms),
        pack_time(row.last_at_ms),row.incomplete,node,row.paired==true}
    local bytes=row_cost(wire);if bytes>ROW_MAX then fail("wire row byte limit") end
    return freeze_tree(wire),bytes
end
local function decode_row(wire,base)
    dense(wire,12)
    if type(wire[1])~="boolean" or not integer(wire[2],1,#kinds) or type(wire[3])~="string" or #wire[3]>192
        or not integer(wire[4],0,10000000) or type(wire[10])~="boolean" or type(wire[12])~="boolean" then fail("invalid wire metadata") end
    for _,i in ipairs({8,9}) do time_cost(wire[i]) end
    local bytes=row_cost(wire);if bytes>ROW_MAX then fail("wire row byte limit") end
    if wire[1] and (wire[4]~=0 or base~=nil) then fail("critical base forbidden") end
    if wire[4]==0 and base~=nil then fail("unexpected base") end
    if wire[4]==0 and wire[11][1]~=2 then fail("anchor root required") end
    local metadata={kind=kinds[wire[2]],critical=wire[1],first_call=wire[5],last_call=wire[6],repeats=wire[7],
        incomplete=wire[10],data={call=wire[3]}}
    if base then valid_base(metadata,base,wire[4]) elseif wire[4]~=0 then fail("missing base") end
    local data=apply(wire[11],base and base.data or nil,wire[4]~=0,1)
    local row={kind=metadata.kind,critical=wire[1],first_call=wire[5],last_call=wire[6],repeats=wire[7],
        incomplete=wire[10],data=data}
    if wire[8]~=false then row.first_at_ms=wire[8]=="-0" and -1/math.huge or wire[8] end;if wire[9]~=false then row.last_at_ms=wire[9]=="-0" and -1/math.huge or wire[9] end
    if wire[12] then row.paired=true end
    validate_row(row);if projection(row)~=wire[3] then fail("projection mismatch") end
    return table.freeze(row),bytes
end
local function public(fn,...)
    local ok,a,b=pcall(fn,...)
    if not ok then return nil,type(a)=="string" and a or "hop codec: invalid input" end
    return a,b
end
local function checked_pair_data(data) checked_data(data);return known_pair_data(data) end
function Codec.pair_data_known(data)
    local ok,result=pcall(checked_pair_data,data)
    return ok and result or false
end
function Codec.wire_bytes(wire) return public(row_cost,wire) end
function Codec.data_bytes(value) return public(checked_data,value) end
function Codec.encode_row(row,base) return public(encode_row,row,base) end
function Codec.decode_row(wire,base) return public(decode_row,wire,base) end
local function chunk_fields(chunk)
    if not plain(chunk) then fail("plain chunk required") end
    local known={schema=true,encoding=true,run_id=true,chunk=true,rows=true}
    for key in pairs(chunk) do if not known[key] then fail("unknown chunk field") end end
end
local function chunk_shape(chunk)
    chunk_fields(chunk)
    local n=array_count(chunk.rows,16);if n<1 then fail("empty chunk") end
    return n
end
local function chunk_envelope(n,index,run_id,sum)
    return 2+(#"schema"+4)+1+(#"encoding"+4)+string_cost(Codec.encoding)
        +(#"run_id"+4)+string_cost(run_id)+(#"chunk"+4)+digits(index)+(#"rows"+4)+2+math.max(0,n-1)+sum
end
local function chunk_cost(chunk,index,run_id)
    local n=chunk_shape(chunk)
    local sum=0;for _,wire in ipairs(chunk.rows) do dense(wire,12);sum+=row_cost(wire) end
    if sum+1024>24576 then fail("chunk byte limit") end
    return chunk_envelope(n,index,run_id,sum),sum
end
function Codec.envelope_bytes(chunk)
    return public(function()
        if not plain(chunk) or not integer(chunk.chunk,1,2176) or type(chunk.run_id)~="string"
            or #chunk.run_id<1 or #chunk.run_id>32 or not chunk.run_id:match("^[A-Za-z0-9_-]+$")
            or chunk.schema~=2 or chunk.encoding~=Codec.encoding then fail("invalid chunk") end
        local n=chunk_cost(chunk,chunk.chunk,chunk.run_id)
        return n+string_cost("hop."..chunk.run_id..".chunk."..tostring(chunk.chunk))+4
    end)
end
function Codec.chunk_bytes(chunk)
    return public(function()
        if not plain(chunk) or not integer(chunk.chunk,1,2176) or type(chunk.run_id)~="string"
            or #chunk.run_id<1 or #chunk.run_id>32 or not chunk.run_id:match("^[A-Za-z0-9_-]+$")
            or chunk.schema~=2 or chunk.encoding~=Codec.encoding then fail("invalid chunk") end
        local _,n=chunk_cost(chunk,chunk.chunk,chunk.run_id);return 1024+n
    end)
end
function Codec.state_bytes(row)
    return public(function() validate_row(row);return checked_data(row.data)+64+string_cost(row.kind)+string_cost(projection(row))+(row.paired and Codec.pair_state_meta_bytes or 0) end)
end
function Codec.projection(row) return public(function() validate_row(row);return row.kind.."|"..projection(row) end) end
-- Public cursors borrow immutable input; bulk decode uses this same admission
-- core synchronously with its original eager chunk preflight and mutable inputs.
local Cursor={};Cursor.__index=Cursor
local cursors=setmetatable({}, {__mode="k"})
local function immutable_wire(value)
    if type(value)~="table" then return true end
    if not plain(value) or not table.isfrozen(value) then return false end
    for _,child in pairs(value) do if not immutable_wire(child) then return false end end
    return true
end
local function decoder_state(chunks,run_id,immutable,eager)
    if type(run_id)~="string" or #run_id<1 or #run_id>32 or not run_id:match("^[A-Za-z0-9_-]+$") then fail("invalid run") end
    local count=array_count(chunks,2176)
    if immutable and not table.isfrozen(chunks) then fail("immutable cursor archive required") end
    return {input=chunks,count=count,run_id=run_id,immutable=immutable,eager=eager,
        index=1,current=nil,row_index=0,chunk_rows=0,chunk_wire=0,chunk_base_store=2,
        bases={},state_costs={},regular=0,critical=0,regular_wire=0,critical_bytes=0,
        state_bytes=Codec.pair_pointer_bytes,base_count=0,last=0,store=2,rows=0,chunks=0,
        complete=false,failed=false}
end
local function enter_chunk(s)
    local chunk=s.input[s.index]
    -- Keep the legacy bulk ordering: fields, identity, full wire/envelope
    -- preflight, then rows. Public cursors only inspect this bounded header.
    chunk_fields(chunk)
    if chunk.schema~=2 or chunk.encoding~=Codec.encoding or chunk.run_id~=s.run_id or chunk.chunk~=s.index then fail("chunk identity or version") end
    if s.eager then
        local envelope=chunk_cost(chunk,s.index,s.run_id)
        local projected=s.store+envelope+string_cost("hop."..s.run_id..".chunk."..tostring(s.index))+4
        if projected>1048576 then fail("encoded store byte limit") end
    end
    local n=chunk_shape(chunk)
    if s.immutable and (not table.isfrozen(chunk) or not table.isfrozen(chunk.rows)) then fail("immutable cursor chunk required") end
    s.current=chunk;s.row_index=1;s.chunk_rows=n;s.chunk_wire=0;s.chunk_base_store=s.store
end
local function admit_row(s,row,bytes,key)
    if row.first_call<=s.last then fail("row ordering") end
    local regular,critical,regular_wire,critical_bytes,state_bytes,base_count=
        s.regular,s.critical,s.regular_wire,s.critical_bytes,s.state_bytes,s.base_count
    local size
    if row.critical then
        critical+=1;critical_bytes+=bytes
        if critical>128 or critical_bytes>131072 then fail("critical capacity") end
    else
        regular+=1;regular_wire+=bytes
        if not s.bases[key] then base_count+=1 end
        if base_count>64 then fail("projection capacity") end
        size=checked_data(row.data)+64+string_cost(row.kind)+string_cost(projection(row))+(row.paired and Codec.pair_state_meta_bytes or 0)
        state_bytes+=size-(s.state_costs[key] or 0)
        if regular>2048 or regular_wire+state_bytes>524288 then fail("regular capacity") end
    end
    local chunk_wire=s.chunk_wire+bytes
    if not s.eager and chunk_wire+1024>24576 then fail("chunk byte limit") end
    local store=s.chunk_base_store+chunk_envelope(s.chunk_rows,s.index,s.run_id,chunk_wire)
        +string_cost("hop."..s.run_id..".chunk."..tostring(s.index))+4
    if not s.eager and store>1048576 then fail("encoded store byte limit") end
    -- Nothing observable is committed until all row/base/cap checks succeed.
    if not row.critical then s.state_costs[key]=size;s.bases[key]=row end
    s.regular=regular;s.critical=critical;s.regular_wire=regular_wire;s.critical_bytes=critical_bytes
    s.state_bytes=state_bytes;s.base_count=base_count;s.last=row.first_call;s.store=store
    s.chunk_wire=chunk_wire;s.rows+=1;s.row_index+=1
    if s.row_index>s.chunk_rows then s.chunks+=1;s.index+=1;s.current=nil end
end
local function advance_decoder(s)
    if s.index>s.count then s.complete=true;return nil end
    if s.current==nil then enter_chunk(s) end
    local wire=s.current.rows[s.row_index]
    dense(wire,12)
    if not integer(wire[2],1,#kinds) or type(wire[3])~="string" then fail("invalid projection identity") end
    local key=kinds[wire[2]].."|"..wire[3]
    local base=wire[4]~=0 and s.bases[key] or nil
    local row,bytes=decode_row(wire,base)
    -- Existing strict parsing has bounded every table/node/depth and rejected
    -- cycles before this lazy read-only check; never walk the whole archive.
    if s.immutable and not immutable_wire(wire) then fail("immutable cursor wire required") end
    admit_row(s,row,bytes,key)
    return row
end
local function next_decoded(s)
    if s.failed then return nil,s.reason end
    if s.complete then return nil,nil end
    local ok,row=pcall(advance_decoder,s)
    if not ok then
        s.failed=true;s.complete=false
        s.reason=type(row)=="string" and row or "hop codec: invalid input"
        return nil,s.reason
    end
    return row,nil
end
function Codec.open_chunks(chunks,run_id)
    return public(function()
        local s=decoder_state(chunks,run_id,true,false)
        local self=setmetatable({},Cursor);cursors[self]=s
        return table.freeze(self)
    end)
end
function Cursor:next()
    local s=cursors[self]
    if not s then return nil,"hop codec: invalid decoder cursor" end
    return next_decoded(s)
end
function Cursor:status()
    local s=cursors[self]
    if not s then return nil,"hop codec: invalid decoder cursor" end
    return table.freeze({complete=s.complete,failed=s.failed,reason=s.reason,rows=s.rows,
        regular_rows=s.regular,critical_rows=s.critical,chunks=s.chunks,
        regular_wire_bytes=s.regular_wire,regular_state_bytes=s.state_bytes,
        regular_bytes=s.regular_wire+s.state_bytes,critical_bytes=s.critical_bytes,encoded_store_bytes=s.store})
end
local function decode_chunks(chunks,run_id)
    local s=decoder_state(chunks,run_id,false,true)
    local rows={}
    while true do
        local row,why=next_decoded(s)
        if why~=nil then error(why,0) end
        if row==nil then return rows end
        rows[#rows+1]=row
    end
end
function Codec.decode_chunks(chunks,run_id) return public(decode_chunks,chunks,run_id) end
table.freeze(Cursor)
return table.freeze(Codec)
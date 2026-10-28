-- Private evidence format only. No SDK, storage, game or qualification authority.
local Codec={version=2,encoding='hop-delta-v2'}
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
local row_keys={kind=true,data=true,first_call=true,last_call=true,repeats=true,first_at_ms=true,last_at_ms=true,incomplete=true,critical=true}
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
        if t=="number" then if not finite(v) or v==0 and 1/v==-math.huge then fail("nonfinite or noncanonical wire scalar") end;bytes=36
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
local function validate_row(row)
    if not plain(row) then fail("plain logical row required") end
    for key in pairs(row) do if not row_keys[key] then fail("unknown row field") end end
    if not kind_ids[row.kind] or type(row.critical)~="boolean" or type(row.incomplete)~="boolean"
        or not integer(row.first_call,1,10000000) or not integer(row.last_call,row.first_call,10000000)
        or not integer(row.repeats,1,row.last_call-row.first_call+1) then fail("invalid row metadata") end
    for _,key in ipairs({"first_at_ms","last_at_ms"}) do local v=rawget(row,key);if v~=nil and (not finite(v) or v<0) then fail("invalid row time") end end
    checked_data(row.data);projection(row)
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
    return 32
end
local function row_cost(wire)
    dense(wire,11)
    if type(wire[1])~="boolean" or not integer(wire[2],1,#kinds) or type(wire[3])~="string" or #wire[3]>192
        or not integer(wire[4],0,10000000) or not integer(wire[5],1,10000000)
        or not integer(wire[6],wire[5],10000000) or not integer(wire[7],1,wire[6]-wire[5]+1)
        or type(wire[10])~="boolean" then fail("invalid wire metadata") end
    return 12+5+digits(wire[2])+string_cost(wire[3])+digits(wire[4])+digits(wire[5])+digits(wire[6])+digits(wire[7])
        +time_cost(wire[8])+time_cost(wire[9])+5+cost(wire[11])
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
        pack_time(row.last_at_ms),row.incomplete,node}
    local bytes=row_cost(wire);if bytes>ROW_MAX then fail("wire row byte limit") end
    return freeze_tree(wire),bytes
end
local function decode_row(wire,base)
    dense(wire,11)
    if type(wire[1])~="boolean" or not integer(wire[2],1,#kinds) or type(wire[3])~="string" or #wire[3]>192
        or not integer(wire[4],0,10000000) or type(wire[10])~="boolean" then fail("invalid wire metadata") end
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
    validate_row(row);if projection(row)~=wire[3] then fail("projection mismatch") end
    return table.freeze(row),bytes
end
local function public(fn,...)
    local ok,a,b=pcall(fn,...)
    if not ok then return nil,type(a)=="string" and a or "hop codec: invalid input" end
    return a,b
end
function Codec.wire_bytes(wire) return public(row_cost,wire) end
function Codec.data_bytes(value) return public(checked_data,value) end
function Codec.encode_row(row,base) return public(encode_row,row,base) end
function Codec.decode_row(wire,base) return public(decode_row,wire,base) end
local function chunk_cost(chunk,index,run_id)
    if not plain(chunk) then fail("plain chunk required") end
    local known={schema=true,encoding=true,run_id=true,chunk=true,rows=true}
    for key in pairs(chunk) do if not known[key] then fail("unknown chunk field") end end
    local n=array_count(chunk.rows,16);if n<1 then fail("empty chunk") end
    local sum=0;for _,wire in ipairs(chunk.rows) do dense(wire,11);sum+=row_cost(wire) end
    if sum+1024>24576 then fail("chunk byte limit") end
    local bytes=2+(#"schema"+4)+1+(#"encoding"+4)+string_cost(Codec.encoding)
        +(#"run_id"+4)+string_cost(run_id)+(#"chunk"+4)+digits(index)+(#"rows"+4)+2+math.max(0,n-1)+sum
    return bytes,sum
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
    return public(function() validate_row(row);return checked_data(row.data)+64+string_cost(row.kind)+string_cost(projection(row)) end)
end
function Codec.projection(row) return public(function() validate_row(row);return row.kind.."|"..projection(row) end) end
local function decode_chunks(chunks,run_id)
    if type(run_id)~="string" or #run_id<1 or #run_id>32 or not run_id:match("^[A-Za-z0-9_-]+$") then fail("invalid run") end
    local count=array_count(chunks,2176)
    local rows,bases,state_costs={}, {}, {}
    local regular,critical,regular_wire,critical_bytes,state_bytes,base_count,last,store=0,0,0,0,0,0,0,2
    for index=1,count do
        local chunk=chunks[index]
        if not plain(chunk) then fail("plain chunk required") end
        local known={schema=true,encoding=true,run_id=true,chunk=true,rows=true}
        for key in pairs(chunk) do if not known[key] then fail("unknown chunk field") end end
        if chunk.schema~=2 or chunk.encoding~=Codec.encoding or chunk.run_id~=run_id or chunk.chunk~=index then fail("chunk identity or version") end
        local envelope=chunk_cost(chunk,index,run_id)
        store+=envelope+string_cost("hop."..run_id..".chunk."..tostring(index))+4
        if store>1048576 then fail("encoded store byte limit") end
        for _,wire in ipairs(chunk.rows) do
            dense(wire,11)
            if not integer(wire[2],1,#kinds) or type(wire[3])~="string" then fail("invalid projection identity") end
            local key=kinds[wire[2]].."|"..wire[3]
            local base=wire[4]~=0 and bases[key] or nil
            local row,bytes=decode_row(wire,base)
            if row.first_call<=last then fail("row ordering") end;last=row.first_call
            if row.critical then
                critical+=1;critical_bytes+=bytes
                if critical>128 or critical_bytes>131072 then fail("critical capacity") end
            else
                regular+=1;regular_wire+=bytes
                if not bases[key] then base_count+=1 end
                if base_count>64 then fail("projection capacity") end
                local size=checked_data(row.data)+64+string_cost(row.kind)+string_cost(projection(row))
                state_bytes+=size-(state_costs[key] or 0)
                state_costs[key]=size;bases[key]=row
                if regular>2048 or regular_wire+state_bytes>524288 then fail("regular capacity") end
            end
            rows[#rows+1]=row
        end
    end
    return rows
end
function Codec.decode_chunks(chunks,run_id) return public(decode_chunks,chunks,run_id) end
return table.freeze(Codec)
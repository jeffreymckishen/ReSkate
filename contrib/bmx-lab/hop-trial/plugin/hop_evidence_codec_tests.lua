-- Independent contract fixtures. This module has no effects until run() is called.
-- Pure codec success does not prove SDK persistence, native physics or game qualification.
local Codec=require("./hop_evidence_codec")
local Tests={}
local expected_fields=string.split([=[
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
y]=],"\n")
local expected_kinds={"source","body","contact","force_pending","mapped_hop","preview","submit","receipt","ack","pose","follow","lease","prepare","terminal"}

function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn) cases+=1;fn();return name end
    local function copy(value)
        if type(value)~="table" then return value end
        local out={};for key,child in pairs(value) do out[key]=copy(child) end;return out
    end
    local function same(a,b)
        if type(a)~=type(b) then return false end
        if type(a)~="table" then
            if type(a)=="number" and a==0 and b==0 then return 1/a==1/b end
            return a==b
        end
        local an,bn=0,0
        for key,value in pairs(a) do an+=1;if not same(value,b[key]) then return false end end
        for _ in pairs(b) do bn+=1 end
        return an==bn
    end
    local function row(kind,data,first,critical)
        return {kind=kind,data=data,first_call=first,last_call=first,repeats=1,incomplete=false,critical=critical==true}
    end
    local function wire(kind_id,projection,first,node,base,critical)
        return {critical==true,kind_id,projection,base or 0,first,first,1,false,false,false,node}
    end
    local function chunk(rows,index,run)
        return {schema=2,encoding="hop-delta-v2",run_id=run or "codec_fixture",chunk=index or 1,rows=rows}
    end
    local function pack(wires,width)
        local chunks={}
        for first=1,#wires,width do
            local rows={};for at=first,math.min(first+width-1,#wires) do rows[#rows+1]=wires[at] end
            chunks[#chunks+1]=chunk(rows,#chunks+1)
        end
        return chunks
    end
    local function encoded(value,base)
        local out,bytes=Codec.encode_row(value,base)
        check(type(out)=="table" and type(bytes)=="number","valid row must encode with a byte charge: "..tostring(bytes))
        return out,bytes
    end
    local function decoded(value,base)
        local out,bytes=Codec.decode_row(value,base)
        check(type(out)=="table" and type(bytes)=="number","valid wire must decode with a byte charge: "..tostring(bytes))
        return out,bytes
    end
    local function stream(chunks,run)
        local out,why=Codec.decode_chunks(chunks,run or "codec_fixture")
        check(type(out)=="table","valid stream must decode: "..tostring(why))
        return out
    end
    local function refuses(fn,why)
        local ok,value,reason=pcall(fn)
        check(ok,why.." must return a refusal without throwing")
        check(value==nil and type(reason)=="string" and #reason>0,why.." must return nil and a reason")
    end
    local function escaped_string_bytes(value)
        local bytes=2
        for at=1,#value do
            local byte=string.byte(value,at)
            if byte<32 or byte==34 or byte==92 or byte>=127 then bytes+=6 else bytes+=1 end
        end
        return bytes
    end
    local function object_bytes(value)
        local kind=type(value)
        if kind=="number" then return 32 end
        if kind=="boolean" then return 5 end
        if kind=="string" then return escaped_string_bytes(value) end
        local bytes=2
        for key,child in pairs(value) do bytes+=#tostring(key)+4+object_bytes(child) end
        return bytes
    end
    -- This is the published fixed storage shape, not the 1024-byte chunk reserve.
    local function envelope_bytes(row_costs,run,index)
        local rows_bytes=2+math.max(0,#row_costs-1)
        for _,cost in ipairs(row_costs) do rows_bytes+=cost end
        local object=2+(6+4+1)+(8+4+escaped_string_bytes("hop-delta-v2"))
            +(6+4+escaped_string_bytes(run))+(5+4+#tostring(index))+(4+4+rows_bytes)
        local key="hop."..run..".chunk."..tostring(index)
        return object+escaped_string_bytes(key)+4
    end
    local function large_data()
        local data={}
        for at=1,44 do data[expected_fields[at]]=string.rep("x",192) end
        return data
    end

    case("frozen public version and complete static dictionaries",function()
        check(Codec.version==2 and Codec.encoding=="hop-delta-v2","wire version is explicit")
        check(#expected_fields==314 and same(Codec.fields,expected_fields),"all 314 field slots match the independent contract")
        check(same(Codec.kinds,expected_kinds),"kind IDs retain their specified order")
        check(table.isfrozen(Codec.fields) and table.isfrozen(Codec.kinds),"public dictionaries are immutable")
    end)
    case("literal standalone row and exact conservative arithmetic",function()
        local literal={false,13,"",0,1,1,1,false,false,false,{2,false}}
        local expected=row("prepare",{},1)
        local actual,bytes=decoded(literal)
        check(same(actual,expected) and bytes==49,"independent empty prepare wire is 49 bytes")
        local written,charged=encoded(expected)
        check(same(written,literal) and charged==49,"encoder uses the same literal and charge")
        check(Codec.data_bytes({})==2,"empty object includes its braces")
        check(Codec.data_bytes({mass=1})==42,"ordinary numbers retain the 32-byte upper bound")
        check(Codec.data_bytes({result=false})==17,"false is a five-byte value, not absence")
        check(Codec.data_bytes({[1]=0,[2]=false})==49,"numeric table keys retain object key costs")
    end)
    case("literal scalar values provenance Unicode and absent timestamp",function()
        local literal=wire(1,"probe",7,{2,{
            {43,{1,"probe"}}, {142,{1,0}}, {209,{1,"caf\195\169 / \230\188\162\229\173\151"}},
            {226,{1,false}}, {249,{1,"9007199254740993"}}, {252,{1,"18446744073709551615"}},
        }})
        literal[6]=11;literal[7]=3;literal[8]=0;literal[11][2][#literal[11][2]+1]={286,{1,1/60}}
        local actual=decoded(literal)
        local expected=row("source",{call="probe",mass=0,reason="caf\195\169 / \230\188\162\229\173\151",result=false,
            sequence="9007199254740993",source_epoch="18446744073709551615",time=1/60},7)
        expected.last_call=11;expected.repeats=3;expected.first_at_ms=0
        check(same(actual,expected),"literal decode preserves every scalar and optional-key absence")
        check(actual.last_at_ms==nil and actual.first_at_ms==0,"zero timestamp does not fabricate its absent partner")
    end)
    case("finite doubles are exact through full anchors and deltas",function()
        local values={0,1/60,-1/60,1e-300,-1e-300,1e300,-1e300,9007199254740991}
        local base=nil
        for at,value in ipairs(values) do
            local expected=row("body",{mass=value,time=value,position={value,0,-value}},at)
            local literal=encoded(expected,base)
            check(same(decoded(literal,base),expected),"finite doubles do not subtract, round or quantize")
            base=expected
        end
    end)
    case("signed zero has explicit JSON-safe wire forms",function()
        local negative_zero=-1/math.huge
        local literal=wire(2,"",1,{2,{{142,{4}}}})
        literal[8]="-0";literal[9]=0
        local actual=decoded(literal)
        check(1/actual.data.mass==-math.huge and 1/actual.first_at_ms==-math.huge,"tag 4 and timestamp sentinel reconstruct negative zero")
        check(1/actual.last_at_ms==math.huge,"numeric timestamp zero remains positive")
        local expected=row("body",{mass=negative_zero},1)
        expected.first_at_ms=negative_zero;expected.last_at_ms=0
        local actual_wire=encoded(expected)
        check(same(actual_wire,literal),"encoder does not rely on JSON retaining integral -0")
        local positive=row("body",{mass=0},2)
        local changed=encoded(positive,expected)
        check(same(decoded(changed,expected),positive),"delta distinguishes negative and positive zero")
        refuses(function() return Codec.decode_row(wire(2,"",1,{2,{{142,{1,negative_zero}}}})) end,"noncanonical scalar negative zero")
        for _,bad in ipairs({{4,0},{4,false},{4,{}}}) do
            refuses(function() return Codec.decode_row(wire(2,"",1,{2,{{142,bad}}})) end,"negative zero tag arity")
        end
    end)
    case("string lengths are UTF-8 bytes and escaping is conservatively charged",function()
        local text=string.rep("\195\169",96)
        local expected=row("prepare",{reason=text},1)
        local written,bytes=encoded(expected)
        check(same(decoded(written),expected),"192 raw UTF-8 bytes retain their exact bytes")
        check(Codec.data_bytes({reason=text})==2+10+2+192*6,"non-ASCII escaped upper bound counts each raw byte")
        check(bytes>192*6,"wire charge includes escaped value and structure")
        refuses(function() return Codec.encode_row(row("prepare",{reason=text.."\195\169"},1)) end,"194-byte UTF-8 scalar")
        local controls="\0\1\n\r\t\"\\"
        local n=Codec.data_bytes({text=controls})
        check(n==2+8+2+#controls*6,"controls quote and slash all receive the conservative escape cost")
    end)
    case("false zero empty string empty table and absence remain distinct",function()
        local a=row("ack",{result=false,mass=0,reason="",source={}},1)
        local b=row("ack",{call="",result=false,mass=0,reason="",source={}},2)
        check(same(decoded((encoded(a))),a),"false and zero values survive a full anchor")
        local transition=encoded(b,a)
        check(same(decoded(transition,a),b),"absent call and explicit empty call share a projection without losing presence")
        local back=row("ack",{result=false,mass=0,reason="",source={}},3)
        check(same(decoded(encoded(back,b),b),back),"deleting the explicit empty call restores absence")
    end)
    case("encoder and decoder detach caller data and inherited bases",function()
        local original=row("body",{position={1,2,3},source={result=false}},1)
        local written=encoded(original)
        local expected=copy(original)
        original.data.position[1]=999;original.data.source.result=true
        local first=decoded(written)
        check(same(first,expected),"wire does not retain caller mutable tables")
        local mutable_first=pcall(function() first.data.position[2]=888 end)
        check(mutable_first or table.isfrozen(first.data.position),"frozen decoder output is an acceptable detachment policy")
        check(same(decoded(written),expected),"decoded output does not mutate its wire")
        local base=row("body",{position={1,2,3},source={result=false}},1)
        local delta=wire(2,"",2,{3,false},1)
        local inherited=decoded(delta,base)
        check(not table.isfrozen(base) and not table.isfrozen(base.data) and not table.isfrozen(base.data.position),"decoder does not freeze caller-owned mutable bases")
        check(inherited.data.position~=base.data.position,"decoded inherited table has an independent identity")
        local mutable_inherited=pcall(function() inherited.data.position[1]=777 end)
        check(mutable_inherited or table.isfrozen(inherited.data.position),"inherited output may be frozen")
        check(base.data.position[1]==1,"delta output does not alias the inherited canonical base")
    end)
    case("coalesced occurrence metadata is preserved without invented samples",function()
        local first=row("source",{call="sample",sequence="9"},3)
        first.last_call=19;first.repeats=5;first.first_at_ms=0;first.last_at_ms=4.125;first.incomplete=true
        local second=row("source",{call="sample",sequence="10"},23)
        second.last_call=29;second.repeats=2;second.last_at_ms=8
        local rows=stream({chunk({(encoded(first))}),chunk({(encoded(second,first))},2)})
        check(#rows==2 and same(rows[1],first) and same(rows[2],second),"logical rows remain ordered exact occurrence ranges")
        check(rows[2].first_at_ms==nil,"decoder does not invent an intermediate or first timestamp")
    end)
    case("literal nested deletion removes existing false and zero only",function()
        local base=row("body",{mass=0,result=false,source={known=true,result=false}},1)
        local delta=wire(2,"",2,{3,{{142,{0}},{226,{0}},{251,{3,{{119,{0}}}}}}},1)
        local actual=decoded(delta,base)
        check(same(actual,row("body",{source={result=false}},2)),"deletion is separate from falsy scalar values")
        check(same(base,row("body",{mass=0,result=false,source={known=true,result=false}},1)),"base remains unchanged")
        refuses(function() return Codec.decode_row(wire(2,"",2,{3,{{209,{0}}}},1),base) end,"deletion of missing key")
        refuses(function() return Codec.decode_row(wire(2,"",2,{3,{{142,{3,false}}}},1),base) end,"nested delta over scalar base")
    end)
    case("validated references allow full replacement and exact no-change deltas",function()
        local base=row("body",{mass=106,reason="old"},1)
        local replacement=wire(2,"",2,{2,{{226,{1,false}}}},1)
        check(same(decoded(replacement,base),row("body",{result=false},2)),"full replacement drops unlisted old keys")
        check(same(decoded(wire(2,"",2,{3,false},1),base),row("body",{mass=106,reason="old"},2)),"empty sparse delta inherits the prior data")
        refuses(function() return Codec.decode_row(wire(2,"",2,{3,{}},1),base) end,"empty pair table is not the JSON-safe delta sentinel")
    end)
    case("encode rejects mismatched critical and forward base identities",function()
        local base=row("body",{call="A",mass=1},1)
        for _,value in ipairs({row("source",{call="A",mass=2},2),row("body",{call="B",mass=2},2),row("body",{call="A"},2,true)}) do
            refuses(function() return Codec.encode_row(value,base) end,"incompatible supplied base")
        end
        local critical=copy(base);critical.critical=true
        refuses(function() return Codec.encode_row(row("body",{call="A"},2),critical) end,"critical row as regular base")
        refuses(function() return Codec.encode_row(row("body",{call="A"},1),base) end,"same-call base reference")
        refuses(function() return Codec.encode_row(row("body",{call="A"},1),row("body",{call="A"},3)) end,"forward base reference")
    end)
    case("stream rejects missing forward skipped kind and projection refs",function()
        local a=wire(2,"A",1,{2,{{43,{1,"A"}}}})
        local b=wire(2,"A",2,{3,false},1)
        local third=wire(2,"A",3,{3,false},2)
        check(#stream({chunk({a,b,third})})==3,"latest same-projection references decode")
        refuses(function() return Codec.decode_chunks({chunk({b})},"codec_fixture") end,"missing regular anchor")
        local forward=copy(b);forward[4]=3
        refuses(function() return Codec.decode_chunks({chunk({a,forward})},"codec_fixture") end,"forward reference")
        local skipped=copy(third);skipped[4]=1
        refuses(function() return Codec.decode_chunks({chunk({a,b,skipped})},"codec_fixture") end,"skipped latest base")
        local wrong_kind=copy(b);wrong_kind[2]=12
        refuses(function() return Codec.decode_chunks({chunk({a,wrong_kind})},"codec_fixture") end,"cross-kind reference")
        local wrong_projection=copy(b);wrong_projection[3]="B"
        refuses(function() return Codec.decode_chunks({chunk({a,wrong_projection})},"codec_fixture") end,"cross-projection reference")
    end)
    case("projection identities remain separate and reconstructed calls are checked",function()
        local a=wire(1,"A",1,{2,{{43,{1,"A"}},{249,{1,"one"}}}})
        local b=wire(1,"B",2,{2,{{43,{1,"B"}},{249,{1,"two"}}}})
        local again=wire(1,"A",3,{3,false},1)
        local rows=stream({chunk({a,b,again})})
        check(rows[3].data.sequence=="one" and rows[2].data.sequence=="two","interleaved projections cannot share a canonical base")
        refuses(function() return Codec.decode_row(wire(1,"A",1,{2,{{43,{1,"B"}}}})) end,"projection differs from reconstructed call")
        refuses(function() return Codec.decode_row(wire(1,"",1,{2,{{43,{1,false}}}})) end,"false call is not absence")
        refuses(function() return Codec.encode_row(row("source",{call=false},1)) end,"encoder false call is not absence")
    end)
    case("each decode stream binds a fresh exact run identity",function()
        local anchor=wire(1,"",1,{2,false})
        local delta=wire(1,"",2,{3,false},1)
        check(#stream({chunk({anchor},1,"run_A")},"run_A")==1,"first run decodes")
        refuses(function() return Codec.decode_chunks({chunk({delta},1,"run_B")},"run_B") end,"previous run must not leave an anchor")
        refuses(function() return Codec.decode_chunks({chunk({anchor},1,"run_A"),chunk({delta},2,"run_B")},"run_A") end,"mixed-run envelopes")
        check(#stream({chunk({anchor},1,"run_A")},"run_A")==1,"prior refusal cannot poison a fresh invocation")
    end)
    case("critical rows decode independently and do not replace regular bases",function()
        local terminal=wire(14,"",7,{2,{{56,{1,true}},{185,{1,"cleanup_unknown"}},{226,{1,false}}}},0,true)
        local expected=row("terminal",{cleanup_unknown=true,phase="cleanup_unknown",result=false},7,true)
        check(same(stream({chunk({terminal})})[1],expected),"standalone critical evidence needs no regular anchor or encoder")
        local anchor=wire(2,"",1,{2,{{142,{1,1}}}})
        local critical=wire(2,"",2,{2,{{142,{1,2}}}},0,true)
        local regular=wire(2,"",3,{3,false},1)
        local rows=stream({chunk({anchor,critical,regular})})
        check(rows[3].data.mass==1 and rows[2].data.mass==2,"critical row does not alter regular dictionary")
        local bad=copy(regular);bad[4]=2
        refuses(function() return Codec.decode_chunks({chunk({anchor,critical,bad})},"codec_fixture") end,"reference to critical row")
        local dependent=copy(terminal);dependent[4]=1
        refuses(function() return Codec.decode_row(dependent,row("terminal",{},1)) end,"critical wire with nonzero base")
    end)
    case("unsupported envelopes ordering run IDs and chunk holes fail closed",function()
        local valid=chunk({wire(13,"",1,{2,false})})
        for _,change in ipairs({{"schema",1},{"schema",3},{"encoding","hop-delta-v3"},{"chunk",0},{"chunk",2},{"run_id","other"},{"unknown",false}}) do
            local invalid=copy(valid);invalid[change[1]]=change[2]
            refuses(function() return Codec.decode_chunks({invalid},"codec_fixture") end,"malformed or unsupported chunk")
        end
        for _,key in ipairs({"schema","encoding","run_id","chunk","rows"}) do
            local invalid=copy(valid);invalid[key]=nil
            refuses(function() return Codec.decode_chunks({invalid},"codec_fixture") end,"missing envelope field")
        end
        for _,run in ipairs({"",string.rep("a",33),"\195\169"}) do
            refuses(function() return Codec.decode_chunks({chunk({wire(13,"",1,{2,false})},1,run)},run) end,"invalid run identifier")
        end
        local next_chunk=chunk({wire(13,"",2,{2,false})},3)
        refuses(function() return Codec.decode_chunks({valid,next_chunk},"codec_fixture") end,"chunk numbering gap")
        local hole={[1]=valid,[3]=next_chunk}
        refuses(function() return Codec.decode_chunks(hole,"codec_fixture") end,"sparse chunk array")
        refuses(function() return Codec.decode_chunks({chunk({})},"codec_fixture") end,"empty chunk")
        refuses(function() return Codec.decode_chunks({valid,chunk({wire(13,"",1,{2,false})},2)},"codec_fixture") end,"nonincreasing first call")
    end)
    case("wire metadata must have exact dense arity and valid ranges",function()
        local valid=wire(13,"",1,{2,false})
        for _,slot_value in ipairs({{1,0},{2,0},{2,15},{3,false},{4,-1},{5,0},{5,10000001},{5,1.5},{6,0},{7,0},{7,2},{8,-1},{9,"0"},{10,0}}) do
            local invalid=copy(valid);invalid[slot_value[1]]=slot_value[2]
            refuses(function() return Codec.decode_row(invalid) end,"invalid wire metadata")
        end
        local truncated=copy(valid);truncated[11]=nil
        local extra=copy(valid);extra[12]=false
        local hole=copy(valid);hole[5]=nil
        for _,invalid in ipairs({truncated,extra,hole}) do refuses(function() return Codec.decode_row(invalid) end,"wire array arity or hole") end
        local unexpected=row("prepare",{},1);unexpected.run_id="codec_fixture"
        refuses(function() return Codec.encode_row(unexpected) end,"unknown logical metadata")
        refuses(function() return Codec.encode_row(row("prepare",false,1)) end,"non-table root data")
        for _,value in ipairs({math.huge,-math.huge,0/0}) do
            local bad_time=copy(valid);bad_time[8]=value
            refuses(function() return Codec.decode_row(bad_time) end,"non-finite timestamp")
        end
    end)
    case("node tags arities key tokens and ordering are strict",function()
        local invalid_nodes={
            {0}, {1,false}, {2,{}}, {3,false}, {9,{}}, {2}, {2,{},false},
            {2,{{0,{1,true}}}}, {2,{{315,{1,true}}}}, {2,{{-33,{1,true}}}},
            {2,{{1.5,{1,true}}}}, {2,{{false,{1,true}}}},
            {2,{{142,{1,1}},{142,{1,2}}}}, {2,{{226,{1,false}},{142,{1,0}}}},
            {2,{{142,{0}}}}, {2,{{251,{3,false}}}}, {2,{{142,{1,1,false}}}}, {2,{{142,{1}}}},
        }
        for _,node in ipairs(invalid_nodes) do
            refuses(function() return Codec.decode_row(wire(2,"",1,node)) end,"malformed full node")
        end
        local pair_extra={2,{{142,{1,1},false}}}
        local pair_hole={2,{[2]={142,{1,1}}}}
        for _,node in ipairs({pair_extra,pair_hole}) do refuses(function() return Codec.decode_row(wire(2,"",1,node)) end,"malformed pair array") end
        local vector_literal=wire(2,"",1,{2,{{192,{2,{{-3,{1,3}},{-2,{1,2}},{-1,{1,1}}}}}}})
        check(same(decoded(vector_literal).data.position,{1,2,3}),"negative tokens are sorted tokens and reconstruct positive numeric indices")
        check(same(decoded(wire(2,"",1,{2,{{-32,{1,false}},{-1,{1,0}}}})).data,{[32]=false,[1]=0}),"sparse numeric index 32 remains within the allowed boundary")
    end)
    case("cycles unsupported values and metatables refuse without callbacks",function()
        local cycle={};cycle.source=cycle
        refuses(function() return Codec.data_bytes(cycle) end,"data recursion cycle")
        refuses(function() return Codec.encode_row(row("source",cycle,1)) end,"encoded recursion cycle")
        local cyclic_wire={2,{}};cyclic_wire[2][1]={251,cyclic_wire}
        refuses(function() return Codec.decode_row(wire(1,"",1,cyclic_wire)) end,"wire recursion cycle")
        for _,value in ipairs({function() error("must not call") end,newproxy(),math.huge,-math.huge,0/0}) do
            refuses(function() return Codec.encode_row(row("source",{result=value},1)) end,"unsupported scalar")
        end
        local callbacks=0
        local hostile=setmetatable({mass=1},{__index=function() callbacks+=1;error("must not index") end,__iter=function() callbacks+=1;error("must not iterate") end})
        refuses(function() return Codec.encode_row(row("body",hostile,1)) end,"metatable-bearing data")
        check(callbacks==0,"validation does not execute untrusted data callbacks")
        local hostile_wire=setmetatable(wire(2,"",1,{2,false}),{__index=function() callbacks+=1;error("must not index") end})
        refuses(function() return Codec.decode_row(hostile_wire) end,"metatable-bearing wire")
        check(callbacks==0,"wire validation does not execute callbacks")
    end)
    case("acyclic aliases count each serialized occurrence and do not count as cycles",function()
        local shared={mass=0,result=false}
        local alias={source=shared,sample=shared}
        local copies={source={mass=0,result=false},sample={mass=0,result=false}}
        check(Codec.data_bytes(alias)==object_bytes(copies),"shared tables have the same charge as expanded copies")
        check(same(decoded((encoded(row("body",alias,1)))),row("body",copies,1)),"alias values are accepted without collapsing occurrences")
        local leaf={};for at=1,31 do leaf[at]=false end
        local at_limit={};for at=1,11 do at_limit[expected_fields[at]]=leaf end
        check(type(Codec.data_bytes(at_limit))=="number","705 expanded nodes including keys fit the 768-node cap")
        local too_many=copy(at_limit);too_many[expected_fields[12]]=leaf
        refuses(function() return Codec.data_bytes(too_many) end,"769 expanded nodes from repeated aliases")
        local leaf_pairs={}
        for index=31,1,-1 do leaf_pairs[#leaf_pairs+1]={-index,{1,false}} end
        local expanding=wire(1,"",2,{3,{{12,{2,leaf_pairs}}}},1)
        refuses(function() return Codec.decode_row(expanding,row("source",at_limit,1)) end,"compact delta reconstructs 769 expanded nodes")
    end)
    case("depth and expanded data limits are independent of compact references",function()
        local deep={};local cursor=deep
        for _=1,34 do cursor.source={};cursor=cursor.source end
        refuses(function() return Codec.data_bytes(deep) end,"table depth beyond 32")
        refuses(function() return Codec.encode_row(row("source",deep,1)) end,"encoded depth beyond 32")
        local large={};for at=1,64 do large[expected_fields[at]]=string.rep("x",192) end
        check(object_bytes(large)>11904,"fixture exceeds DATA11904 without exceeding string or node limits")
        refuses(function() return Codec.data_bytes(large) end,"expanded data bound")
        refuses(function() return Codec.encode_row(row("source",large,1)) end,"expanded row data bound")
        local base_data=large_data()
        local additions={}
        for field=45,64 do additions[#additions+1]={field,{1,string.rep("x",192)}} end
        local expanding=wire(2,base_data.call,2,{3,additions},1)
        refuses(function() return Codec.decode_row(expanding,row("body",base_data,1)) end,"compact delta reconstructs expanded DATA above11904")
    end)
    case("wire row bound includes duplicated escaped projection metadata",function()
        local data={call=string.rep("\1",192)}
        for _,field in ipairs(expected_fields) do
            if field~="call" then
                local remaining=11904-object_bytes(data)-(#field+4)-2
                if remaining>=0 then data[field]=string.rep("x",math.min(192,remaining)) end
                if object_bytes(data)==11904 then break end
            end
        end
        check(object_bytes(data)==11904 and Codec.data_bytes(data)==11904,"expanded data fits its exact independent cap")
        refuses(function() return Codec.encode_row(row("source",data,1)) end,"wire row over 12288 including escaped projection")
    end)
    case("projection cache admits 64 regular identities and refuses the 65th",function()
        local wires={}
        for at=1,64 do wires[#wires+1]=encoded(row("source",{call="P"..tostring(at),sequence=tostring(at)},at)) end
        local rows=stream(pack(wires,16))
        check(#rows==64 and rows[1].data.sequence=="1" and rows[64].data.sequence=="64","independent regular projection bases are retained")
        wires[#wires+1]=encoded(row("source",{call="P65",sequence="65"},65))
        refuses(function() return Codec.decode_chunks(pack(wires,16),"codec_fixture") end,"65th regular projection base")
        local critical={}
        for at=1,65 do critical[#critical+1]=encoded(row("terminal",{call="C"..tostring(at)},at,true)) end
        check(#stream(pack(critical,16))==65,"critical identities never consume the regular projection cache")
    end)
    case("stream preserves the full independent regular and critical row allowances",function()
        local wires={}
        for at=1,2048 do wires[#wires+1]=wire(13,"",at,{2,false}) end
        for at=2049,2176 do wires[#wires+1]=wire(14,"",at,{2,false},0,true) end
        local rows=stream(pack(wires,16))
        check(#rows==2176 and not rows[2048].critical and rows[2049].critical,"2048 regular plus 128 critical rows fit their independent caps")
        local extra_regular=copy(wires);extra_regular[#extra_regular+1]=wire(13,"",2177,{2,false})
        refuses(function() return Codec.decode_chunks(pack(extra_regular,16),"codec_fixture") end,"2049th regular row")
        local extra_critical=copy(wires);extra_critical[#extra_critical+1]=wire(14,"",2177,{2,false},0,true)
        refuses(function() return Codec.decode_chunks(pack(extra_critical,16),"codec_fixture") end,"129th critical row")
    end)
    case("short chunks remain valid beyond an assumed 136-chunk fill count",function()
        local chunks={}
        for at=1,137 do chunks[at]=chunk({wire(13,"",at,{2,false})},at) end
        local rows=stream(chunks)
        check(#rows==137 and rows[137].first_call==137,"maximum 16 rows is not a requirement to fill every chunk")
    end)
    case("high-byte rows force fewer than 16 rows per chunk",function()
        local data=large_data()
        local wires,costs={},{}
        for at=1,3 do wires[at],costs[at]=encoded(row("body",copy(data),at)) end
        check(costs[1]+costs[2]+1024<=24576 and costs[1]+costs[2]+costs[3]+1024>24576,"three legal rows cross chunk bytes before row count")
        local chunks={chunk({wires[1],wires[2]}),chunk({wires[3]},2)}
        local rows=stream(chunks)
        check(#rows==3 and same(rows[3].data,data),"two-row and one-row byte-bounded chunks both decode")
        refuses(function() return Codec.decode_chunks({chunk(wires)},"codec_fixture") end,"three-row oversized chunk")
        local too_many={};for at=1,17 do too_many[at]=wire(13,"",at,{2,false}) end
        refuses(function() return Codec.decode_chunks({chunk(too_many)},"codec_fixture") end,"17 compact rows exceed the separate row cap")
    end)
    case("regular byte admission includes its current canonical base",function()
        local data=large_data()
        local cache_cost=object_bytes(data)+64+escaped_string_bytes("body")+escaped_string_bytes(data.call)
        local wires,total={},0
        for at=1,128 do
            local next_wire,bytes=encoded(row("body",copy(data),at))
            if total+bytes>512*1024 then break end
            total+=bytes;wires[#wires+1]=next_wire
        end
        check(total<=512*1024 and total+cache_cost>512*1024,"encoded rows alone fit but their required full canonical base exceeds 512KiB")
        check(#wires<2048,"regular row count is below its independent cap")
        local legal_prefix,legal_wire_bytes={},0
        for at=1,#wires-2 do
            legal_prefix[at]=wires[at]
            local _,bytes=decoded(wires[at]);legal_wire_bytes+=bytes
        end
        check(legal_wire_bytes+cache_cost<=512*1024,"prefix fits wire plus one replacement canonical state")
        check(#stream(pack(legal_prefix,2))==#legal_prefix,"replacing a projection does not accumulate old expanded snapshots")
        refuses(function() return Codec.decode_chunks(pack(wires,2),"codec_fixture") end,"regular cache plus wire budget")
    end)
    case("critical byte admission is separate from its row count",function()
        local wires,total={},0
        local data=large_data()
        for at=1,32 do
            local next_wire,bytes=encoded(row("terminal",copy(data),at,true))
            wires[#wires+1]=next_wire;total+=bytes
            if total>128*1024 then break end
        end
        check(total>128*1024 and #wires<128,"critical wire bytes exceed 128KiB while row count fits")
        local legal_prefix={};for at=1,#wires-1 do legal_prefix[at]=wires[at] end
        check(#stream(pack(legal_prefix,2))==#legal_prefix,"critical rows below the byte boundary remain independently readable")
        refuses(function() return Codec.decode_chunks(pack(wires,2),"codec_fixture") end,"critical wire budget")
    end)
    case("small envelopes use actual aggregate shape rather than the per-chunk reserve",function()
        local chunks,aggregate_bytes={},2
        for at=1,1000 do
            chunks[at]=chunk({wire(13,"",at,{2,false})},at)
            local row_bytes=49+2*(#tostring(at)-1)
            aggregate_bytes+=envelope_bytes({row_bytes},"codec_fixture",at)
        end
        check(1000*(1024+49)>1024*1024,"the intentionally larger per-chunk reserve would reject this legal stream")
        check(aggregate_bytes<1024*1024,"the independently counted actual fixed envelopes fit the aggregate cap")
        check(#stream(chunks)==1000,"aggregate accounting does not charge the 1024-byte chunk reserve a thousand times")
    end)
    case("physical SDK JSON depth is stricter than the expanded data depth cap",function()
        local shallow={};local cursor=shallow
        for _=1,8 do cursor.source={};cursor=cursor.source end
        cursor.result=false
        local expected=row("source",shallow,1)
        check(same(decoded((encoded(expected))),expected),"ten wire-node levels including scalar fit the SDK depth limit")
        local deep={};cursor=deep
        for _=1,9 do cursor.source={};cursor=cursor.source end
        cursor.result=false
        check(type(Codec.data_bytes(deep))=="number","eleven wire-node levels still fit expanded DATA bounds")
        refuses(function() return Codec.encode_row(row("source",deep,1)) end,"encoded physical JSON depth beyond 32")
        local node={1,false}
        for _=1,10 do node={2,{{251,node}}} end
        refuses(function() return Codec.decode_row(wire(1,"",1,node)) end,"decoded physical JSON depth beyond 32")
    end)
    return {cases=cases,assertions=assertions}
end
return table.freeze(Tests)

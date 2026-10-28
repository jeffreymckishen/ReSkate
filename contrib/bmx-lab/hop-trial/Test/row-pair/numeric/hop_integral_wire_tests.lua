-- Independent numeric JSON accounting regressions. SOURCE ONLY / AUTHOR UNRUN.
-- Uses the existing standalone runner's SDK-compatible conversion + real JSON writer.
-- Profile4 ordinary rows add marker JSON6 and separately charged TValue16.
-- It does not establish plugin Host, persistence, cadence, native or game qualification.
local Codec=require("./hop_evidence_codec")
local Tests={}
function Tests.run(runner)
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,run) cases+=1;local ok,why=pcall(run);assert(ok,name..": "..tostring(why)) end
    local function from_bits(lo,hi)
        local bytes=buffer.create(8);buffer.writeu32(bytes,0,lo);buffer.writeu32(bytes,4,hi)
        return buffer.readf64(bytes,0)
    end
    local function same_bits(a,b)
        if type(a)~="number" or type(b)~="number" then return false end
        local bytes=buffer.create(16);buffer.writef64(bytes,0,a);buffer.writef64(bytes,8,b)
        return buffer.readu32(bytes,0)==buffer.readu32(bytes,8) and buffer.readu32(bytes,4)==buffer.readu32(bytes,12)
    end
    local negative_zero=from_bits(0,0x80000000)
    local max_safe=from_bits(0,0x43400000)
    local next_inside=from_bits(0xFFFFFFFF,0x433FFFFF)
    local next_outside=from_bits(1,0x43400000)
    local subnormal=from_bits(1,0)
    local largest_subnormal=from_bits(0xFFFFFFFF,0x000FFFFF)
    local min_normal=from_bits(0,0x00100000)
    local largest_finite=from_bits(0xFFFFFFFF,0x7FEFFFFF)
    local next_after_one=from_bits(1,0x3FF00000)
    local next_before_one=from_bits(0xFFFFFFFF,0x3FEFFFFF)
    local integer_texts={"0","1","2","8","9","10","11","98","99","100","101",
        "999","1000","1001","9999","10000","10001","99999","100000","100001",
        "999999","1000000","1000001","9999999","10000000","10000001",
        "99999999","100000000","100000001","999999999","1000000000","1000000001",
        "9999999999","10000000000","10000000001","99999999999","100000000000","100000000001",
        "999999999999","1000000000000","1000000000001","9999999999999","10000000000000","10000000000001",
        "99999999999999","100000000000000","100000000000001","999999999999999","1000000000000000","1000000000000001"}
    local double_values={.5,-.5,1/60,-1/60,subnormal,-subnormal,largest_subnormal,-largest_subnormal,
        min_normal,-min_normal,next_after_one,-next_after_one,next_before_one,-next_before_one,
        next_outside,-next_outside,1e16,-1e16,2^63,-2^63,1e100,-1e100,largest_finite,-largest_finite}
    local function row(data,index)
        local at=index or 1
        return {kind="source",data=data,first_call=at,last_call=at,repeats=1,critical=false,incomplete=false}
    end
    local function encoded(logical,base)
        local wire,cost=Codec.encode_row(logical,base)
        check(type(wire)=="table" and type(cost)=="number","row encodes with a charge: "..tostring(cost))
        check(#wire==12 and wire[12]==false,"ordinary numeric rows carry explicit false marker, never an inferred pair")
        return wire,cost
    end
    local function decoded(wire,base)
        local logical,cost=Codec.decode_row(wire,base)
        check(type(logical)=="table" and type(cost)=="number","row decodes with a charge: "..tostring(cost))
        check(rawget(logical,"paired")==nil,"ordinary numeric rows never acquire logical paired metadata")
        return logical,cost
    end
    local function refuses(fn,why)
        local ok,value,reason=pcall(fn)
        check(ok and value==nil and type(reason)=="string" and #reason>0,why.." must return nil plus a reason")
    end
    local function copy(value)
        if type(value)~="table" then return value end
        local out={};for k,v in pairs(value) do out[k]=copy(v) end;return out
    end
    local function mass_node(wire)
        check(wire[11][1]==2 and #wire[11][2]==1 and wire[11][2][1][1]==142,"independent mass slot142 anchor shape")
        return wire[11][2][1][2]
    end
    local encode=runner and runner.json_encode
    local function scalar_integer(value,text)
        check(value==math.floor(value) and math.abs(value)<=max_safe,"integer fixture is exact and within the SDK int64 policy")
        check(encode(value)==text,"actual writer must emit exact invariant integer decimal "..text)
        local wire,cost=encoded(row({mass=value}))
        local node=mass_node(wire)
        check(node[1]==1 and same_bits(node[2],value),"integer wire retains binary64 payload")
        -- Independent arithmetic:v3 charge55+decimal plus false-marker JSON6 and pinned TValue16.
        check(cost==77+#text and Codec.wire_bytes(wire)==77+#text,"integral charge keeps exact decimal length plus explicit22 profile reserve")
        check(#encode(wire)==61+#text and cost==#encode(wire)+16,"ASCII integer physical JSON is exact; charged bytes additionally retain TValue16")
        local logical,read_cost=decoded(wire)
        check(same_bits(logical.data.mass,value) and read_cost==cost,"integer survives decode with the same exact charge")
    end
    case("private real-writer helper and strict v4 profile",function()
        check(reskate==nil and bmx_luau_runner==nil,"test helper has no module global")
        check(type(runner)=="table" and table.isfrozen(runner) and type(encode)=="function","frozen explicit real-writer helper required")
        check(getfenv(Codec.encode_row).bmx_luau_runner==nil,"production codec receives no helper global")
        check(Codec.version==4 and Codec.encoding=="hop-delta-v4" and table.isfrozen(Codec),"v4 is explicit and immutable")
        check(Codec.pair_pointer_bytes==2048 and Codec.pair_wire_meta_bytes==16 and Codec.pair_state_meta_bytes==256,"profile4 reserves are exact while ordinary canonical numeric32 stays unchanged")
        check(Codec.fields[142]=="mass" and Codec.kinds[1]=="source","literal arithmetic uses unchanged dictionary identities")
    end)
    case("signed decimal powers and adjacent integer boundaries",function()
        for _,text in ipairs(integer_texts) do
            local value=tonumber(text);scalar_integer(value,text)
            if value~=0 then scalar_integer(-value,"-"..text) end
        end
    end)
    case("inclusive safe integer boundary and exact IEEE neighbors",function()
        check(max_safe==9007199254740992 and next_inside==9007199254740991 and next_outside==9007199254740994,"fixtures are distinct binary64 neighbors")
        scalar_integer(max_safe,"9007199254740992");scalar_integer(-max_safe,"-9007199254740992")
        scalar_integer(next_inside,"9007199254740991");scalar_integer(-next_inside,"-9007199254740991")
        for _,value in ipairs({next_outside,-next_outside}) do
            local wire,cost=encoded(row({mass=value}));check(cost==109,"just-outside integer retains32-byte double cost plus explicit22 row reserve")
            check(#encode(wire)<=cost-16,"outside-boundary physical JSON excludes the pinned TValue16 charge")
            check(same_bits(decoded(wire).data.mass,value),"outside value is not coerced or rounded to the boundary")
        end
    end)
    case("rounded decimal input is classified by represented binary64 value",function()
        local rounded=9007199254740993
        check(same_bits(rounded,max_safe),"2^53+1 source literal rounds to2^53, never an outside-boundary fixture")
        scalar_integer(rounded,"9007199254740992")
    end)
    case("fraction subnormal normal and huge finite values retain32",function()
        check(subnormal>0 and subnormal<min_normal and largest_subnormal<min_normal,"IEEE subnormal fixtures are not zero")
        check(next_before_one<1 and next_after_one>1 and largest_finite<math.huge,"nonintegral/maximum fixtures are distinct and finite")
        for _,value in ipairs(double_values) do
            check(value==value and math.abs(value)<math.huge and (value~=math.floor(value) or math.abs(value)>max_safe),"fixture uses SDK double branch")
            local wire,cost=encoded(row({mass=value}));local node=mass_node(wire)
            check(node[1]==1 and same_bits(node[2],value) and cost==109,"double scalar retains32 plus wrapper4 and explicit22 profile reserve")
            check(Codec.wire_bytes(wire)==109 and #encode(wire)<=93,"conservative32 covers physical numeric JSON plus marker6; TValue16 remains separately charged")
            check(same_bits(decoded(wire).data.mass,value),"IEEE finite bits survive, with no quantization")
        end
    end)
    case("integer clocks use exact positive decimal cost",function()
        for _,text in ipairs({"0","1","9","10","16","99","100","1000","1500","1234567890123","9007199254740992"}) do
            local value=tonumber(text);local logical=row({});logical.first_at_ms=value;logical.last_at_ms=value
            local wire,cost=encoded(logical)
            check(wire[8]==value and wire[9]==value and cost==60+2*#text,"integer clocks retain exact decimal lengths plus explicit22 row reserve")
            check(#encode(wire)==44+2*#text and cost==#encode(wire)+16 and Codec.wire_bytes(wire)==cost,"integer-clock physical JSON stays exact, separate from TValue16 policy charge")
            local restored=decoded(wire);check(same_bits(restored.first_at_ms,value) and same_bits(restored.last_at_ms,value),"integer clock values remain exact")
        end
    end)
    case("fractional and beyond-safe clocks retain32",function()
        for _,value in ipairs({.5,1/60,subnormal,min_normal,next_after_one,next_outside,1e16,largest_finite}) do
            local logical=row({});logical.first_at_ms=value;logical.last_at_ms=value
            local wire,cost=encoded(logical)
            check(cost==124 and Codec.wire_bytes(wire)==124 and #encode(wire)<=108,"two noninteger-policy clocks retain32 plus marker6; TValue16 remains charged")
            local restored=decoded(wire);check(same_bits(restored.first_at_ms,value) and same_bits(restored.last_at_ms,value),"clock payload is never approximated for byte accounting")
        end
    end)
    case("negative zero scalar retains tag4 despite SDK integer zero",function()
        check(1/negative_zero==-math.huge and encode(negative_zero)=="0","SDK scalar conversion would discard the zero sign")
        local wire,cost=encoded(row({mass=negative_zero}));local node=mass_node(wire)
        check(#node==1 and node[1]==4 and cost==76 and #encode(wire)==60 and cost==#encode(wire)+16,"negative zero retains exact tag4 physical JSON plus separate TValue16")
        check(same_bits(decoded(wire).data.mass,negative_zero),"tag4 decode restores the IEEE sign")
        local positive,positive_cost=encoded(row({mass=0}));check(mass_node(positive)[1]==1 and positive_cost==78 and #encode(positive)==62,"positive zero keeps one-digit physical branch and explicit22 row charge")
    end)
    case("negative zero clocks retain quoted minus-zero sentinels",function()
        local logical=row({});logical.first_at_ms=negative_zero;logical.last_at_ms=negative_zero
        local wire,cost=encoded(logical)
        check(wire[8]=="-0" and wire[9]=="-0" and cost==68 and #encode(wire)==52 and cost==#encode(wire)+16,"clock sentinels retain quoted4-byte physical cost plus separate TValue16")
        local restored=decoded(wire);check(same_bits(restored.first_at_ms,negative_zero) and same_bits(restored.last_at_ms,negative_zero),"clock zero signs survive both sentinels")
    end)
    case("canonical data and retained state keep32 for every finite scalar",function()
        local values={0,negative_zero,1,-1,10,-10,next_inside,-next_inside,max_safe,-max_safe}
        for _,v in ipairs(double_values) do values[#values+1]=v end
        for _,v in ipairs(values) do
            check(Codec.data_bytes({mass=v})==42,"canonical mass object keeps numeric32 regardless of wire saving")
            check(Codec.state_bytes(row({mass=v}))==116,"retained state is canonical42 plus unchanged metadata74")
        end
        local _,small=encoded(row({mass=1}));local _,fractional=encoded(row({mass=.5}))
        check(small==78 and fractional==109,"v4 row charges do not alter identical ordinary canonical state116")
    end)
    case("expanded canonical byte cap cannot be bypassed with tiny integers",function()
        local function groups(count)
            local out={};for group=1,count do local values={};for index=1,32 do values[index]=1 end;out[group]=values end
            return {mass=out}
        end
        local valid=groups(9);check(Codec.data_bytes(valid)==10938,"independent canonical arithmetic still charges288 numbers at32 each")
        local wire,cost=encoded(row(valid));check(cost<10938 and #encode(wire)<=cost-16,"physical JSON and TValue16 policy reserve stay separate from canonical memory")
        check(decoded(wire).data.mass[9][32]==1,"every accepted tiny integer remains present")
        refuses(function() return Codec.data_bytes(groups(10)) end,"canonical12153 exceeds unchanged11904")
        refuses(function() return Codec.encode_row(row(groups(10))) end,"wire-small object cannot bypass expanded byte cap")
    end)
    case("delta integer decimal changes preserve values and exact charges",function()
        local base=row({mass=9,x=1,y=1},1)
        for index,text in ipairs({"10","100","1000","10000"}) do
            local next_row=row({mass=tonumber(text),x=1,y=1},index+1)
            local wire,cost=encoded(next_row,base)
            check(wire[11][1]==3 and cost==77+#text,"one-field delta retains decimal accounting plus explicit22 row reserve")
            check(#encode(wire)==61+#text and cost==#encode(wire)+16,"integer delta physical JSON stays exact while TValue16 remains charged")
            local restored=decoded(wire,base)
            check(same_bits(restored.data.mass,next_row.data.mass) and restored.data.x==1 and restored.data.y==1,"changed and inherited fields remain exact")
            base=restored
        end
    end)
    case("delta positive and negative zero retain distinct identities",function()
        local base=row({mass=0,x=1,y=1},1)
        local neg=row({mass=negative_zero,x=1,y=1},2);local wire=encoded(neg,base)
        check(wire[11][1]==3 and wire[11][2][1][2][1]==4,"zero sign change is emitted as a real delta")
        local restored=decoded(wire,base);check(same_bits(restored.data.mass,negative_zero),"negative zero delta remains negative")
        local pos=row({mass=0,x=1,y=1},3);local back=encoded(pos,restored)
        check(back[11][1]==3 and back[11][2][1][2][1]==1 and same_bits(decoded(back,restored).data.mass,0),"positive zero return is emitted and restored")
    end)
    case("noncanonical negative-zero numeric wire forms refuse",function()
        local wire={false,1,"",0,1,1,1,false,false,false,{2,{{142,{1,negative_zero}}}},false}
        refuses(function() return Codec.wire_bytes(wire) end,"negative zero numeric scalar")
        refuses(function() return Codec.decode_row(wire) end,"negative zero numeric scalar decode")
        local valid=encoded(row({mass=0}));wire=copy(valid);wire[8]=negative_zero
        refuses(function() return Codec.wire_bytes(wire) end,"negative zero numeric timestamp")
        refuses(function() return Codec.decode_row(wire) end,"negative zero numeric timestamp decode")
    end)
    case("nonfinite values refuse actual writer and codec",function()
        for _,v in ipairs({0/0,math.huge,-math.huge}) do
            local ok=pcall(encode,v);check(not ok,"actual SDK-compatible writer rejects nonfinite JSON")
            refuses(function() return Codec.data_bytes({mass=v}) end,"nonfinite canonical data")
            refuses(function() return Codec.encode_row(row({mass=v})) end,"nonfinite logical data")
        end
    end)
    case("negative and nonfinite clock observations refuse",function()
        for _,v in ipairs({-1,-.5,0/0,math.huge,-math.huge}) do
            local logical=row({});logical.first_at_ms=v;logical.last_at_ms=v
            refuses(function() return Codec.encode_row(logical) end,"invalid logical timestamps")
        end
    end)
    case("mixed sixteen-row envelope bound covers the actual JSON writer",function()
        local values={0,negative_zero,1,-1,10,-10,max_safe,-max_safe,next_outside,-next_outside,.5,-.5,subnormal,-subnormal,largest_finite,-largest_finite}
        local wires={};local sum=0
        for i,v in ipairs(values) do local wire,cost=encoded(row({mass=v},i));wires[i]=wire;sum+=cost end
        local chunk={schema=2,encoding="hop-delta-v4",run_id="integral_fixture",chunk=1,rows=wires}
        local key="hop.integral_fixture.chunk.1"
        check(Codec.chunk_bytes(chunk)==1024+sum,"chunk1024 reserve is unchanged; each row sum includes its explicit22 charge")
        local bound=Codec.envelope_bytes(chunk);check(type(bound)=="number" and #encode({[key]=chunk})<=bound-16*#wires,"envelope physical JSON is bounded separately from TValue16 per ordinary row")
        local rows,why=Codec.decode_chunks({chunk},"integral_fixture")
        check(type(rows)=="table" and #rows==16,"all mixed rows decode: "..tostring(why))
        for i,v in ipairs(values) do check(same_bits(rows[i].data.mass,v),"envelope retains exact finite bits at row"..i) end
    end)
    case("integral savings never widen the sixteen-row chunk cap",function()
        local wires={};for i=1,17 do wires[i]=encoded(row({mass=1},i)) end
        local chunk={schema=2,encoding="hop-delta-v4",run_id="integral_fixture",chunk=1,rows=wires}
        refuses(function() return Codec.chunk_bytes(chunk) end,"seventeen rows remain forbidden")
        refuses(function() return Codec.envelope_bytes(chunk) end,"seventeen-row envelope remains forbidden")
        refuses(function() return Codec.decode_chunks({chunk},"integral_fixture") end,"seventeen physical observations cannot hide inside a chunk")
    end)
    case("v4 envelope rejects legacy accounting while ordinary rows retain first11 slots",function()
        local wire=encoded(row({mass=1}));check(decoded(wire).data.mass==1 and #wire==12 and wire[12]==false,"ordinary row keeps first11 slots plus explicit false marker")
        local old={schema=2,encoding="hop-delta-v4",run_id="integral_fixture",chunk=1,rows={wire}}
        for _,legacy in ipairs({"hop-delta-v3","hop-delta-v2"}) do
            old.encoding=legacy
            refuses(function() return Codec.chunk_bytes(old) end,"legacy accounting profile "..legacy)
            refuses(function() return Codec.envelope_bytes(old) end,"legacy envelope "..legacy)
            refuses(function() return Codec.decode_chunks({old},"integral_fixture") end,"legacy stream "..legacy)
        end
        old.encoding="hop-delta-v4";check(Codec.chunk_bytes(old)~=nil,"schema2 is retained and only explicit v4 accounting is accepted")
    end)
    case("clock stream through1500 retains every occurrence and IEEE value",function()
        local clocks={};for at=0,1488,16 do clocks[#clocks+1]=at end;clocks[#clocks+1]=1500
        check(#clocks==95,"fixed16ms sample sequence plus final1500 observation")
        local chunks={};local wires={};local sum=0
        for i,at in ipairs(clocks) do
            local logical=row({at_ms=at,sequence=i,time=at/1000},i);logical.first_at_ms=at;logical.last_at_ms=at
            local wire,cost=encoded(logical);sum+=cost;wires[#wires+1]=wire
            check(Codec.data_bytes(logical.data)==127 and Codec.state_bytes(logical)==201,"three canonical numbers retain original memory accounting")
            if #wires==16 or i==#clocks then
                local chunk={schema=2,encoding="hop-delta-v4",run_id="clock_fixture",chunk=#chunks+1,rows=wires}
                local key="hop.clock_fixture.chunk."..tostring(chunk.chunk)
                check(#encode({[key]=chunk})<=Codec.envelope_bytes(chunk)-16*#wires,"every clock chunk separates physical JSON from TValue16 per ordinary row")
                chunks[#chunks+1]=chunk;wires={}
            end
        end
        local rows,why=Codec.decode_chunks(chunks,"clock_fixture")
        check(type(rows)=="table" and #rows==95 and #chunks==6,"all95 occurrences retained in six legal chunks: "..tostring(why))
        for i,at in ipairs(clocks) do
            local actual=rows[i]
            check(actual.first_call==i and actual.last_call==i and actual.repeats==1 and actual.data.sequence==i,"occurrence metadata is never dropped/coalesced")
            check(same_bits(actual.first_at_ms,at) and same_bits(actual.last_at_ms,at) and same_bits(actual.data.at_ms,at) and same_bits(actual.data.time,at/1000),"clock facts and fractional seconds remain exact")
        end
        check(sum>0,"charges exist for every retained observation; this is not full Host/native row-cap qualification")
    end)
    check(cases==20,"complete independent20-case source-authored matrix")
    return {cases=cases,assertions=assertions,native_actions=0,host_actions=0,observations_dropped=0}
end
return table.freeze(Tests)

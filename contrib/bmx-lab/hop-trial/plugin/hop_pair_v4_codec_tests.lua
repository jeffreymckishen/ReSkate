-- Independent concrete profile4/SDK marker regressions. SOURCE ONLY / AUTHOR UNRUN.
-- Contract885A; immutable CODE-v2 Codec9454; exact sanitized SDK fixturesB14B.
-- Constructed DTOs confer no lease/capture/native/context or execution authority.
local Codec=require("./hop_evidence_codec")
local F=require("./hop_pair_sdk_fixtures")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn) cases+=1;local ok,why=pcall(fn);assert(ok,name..": "..tostring(why)) end
    local function refuses(fn,why)
        local ok,value,reason=pcall(fn)
        check(ok and value==nil and type(reason)=="string" and #reason>0,why.." returns nil plus reason")
    end
    local function encoded(row,base)
        local wire,cost=Codec.encode_row(row,base)
        check(type(wire)=="table" and type(cost)=="number","valid logical row encodes: "..tostring(cost))
        return wire,cost
    end
    local function decoded(wire,base)
        local row,cost=Codec.decode_row(wire,base)
        check(type(row)=="table" and type(cost)=="number","valid wire decodes: "..tostring(cost))
        return row,cost
    end
    local function unknown(data,why) check(Codec.pair_data_known(data)==false,why.." makes fallback ineligible without inventing known state") end
    local function count(value) local n=0;for _ in pairs(value) do n+=1 end;return n end
    case("explicit profile constants and ordinary71 prepare charge",function()
        check(Codec.version==4 and Codec.encoding=="hop-delta-v4" and table.isfrozen(Codec),"strict profile4 is explicit")
        check(Codec.pair_pointer_bytes==2048 and Codec.pair_wire_meta_bytes==16 and Codec.pair_state_meta_bytes==256,"exact fixed/TValue/current-paired reserves")
        local ordinary={kind="prepare",data={},first_call=1,last_call=1,repeats=1,critical=false,incomplete=false}
        local wire,cost=encoded(ordinary)
        check(#wire==12 and wire[12]==false and cost==71 and Codec.wire_bytes(wire)==71,"ordinary empty prepare is old49 plus22, not a physical JSON equality")
        local row,read_cost=decoded(wire)
        check(rawget(row,"paired")==nil and read_cost==71,"false marker roundtrips to paired absence")
        check(Codec.data_bytes({mass=1})==42,"canonical numeric32 remains unchanged")
        local numeric={kind="source",data={mass=1},first_call=1,last_call=1,repeats=1,critical=false,incomplete=false}
        check(Codec.state_bytes(numeric)==116,"ordinary retained numeric state is unchanged, not charged paired metadata")
    end)
    case("valid SDK state waiting and capturing pairs retain a true origin marker",function()
        for _,data in ipairs({F.lease_state(),F.capture_state("waiting_neutral"),F.capture_state("capturing")}) do
            check(Codec.pair_data_known(data)==true,"exact SDK DTO is an eligible known fact")
            local marked=F.logical(data,1,3,2,true);local ordinary=F.logical(F.copy(data),1,3,2)
            local wire,cost=encoded(marked);local unmarked,ordinary_cost=encoded(ordinary)
            check(wire[12]==true and unmarked[12]==false and cost==ordinary_cost,"true/false markers have the same conservative wire charge")
            for i=1,11 do check(F.same(wire[i],unmarked[i]),"origin marker changes no existing wire slot"..i) end
            check(Codec.state_bytes(marked)-Codec.state_bytes(ordinary)==256,"only marked current projection state adds256")
            local restored,read_cost=decoded(wire)
            check(restored.paired==true and F.same(restored.data,data) and restored.first_call==1 and restored.last_call==3 and restored.repeats==2 and read_cost==cost,"marked pair retains exact endpoints/data/cost")
            check(rawget(decoded(unmarked),"paired")==nil,"legacy unmarked repeats2 is never reclassified as a fallback pair")
            if data.phase=="capturing" then check(restored.data.report_debt==true and restored.data.capturing==true,"known capture debt is retained, never discharged by pairing") end
        end
    end)
    case("absent-first present-last edge reserves possible hash growth",function()
        local singleton=F.logical(F.lease_state(),1)
        local marked=F.logical(F.lease_state(),1,3,2,true);marked.last_at_ms=16
        check(count(singleton)==7 and count(marked)==9,"absent-time singleton gains last_at and paired keys across8-to16 growth edge")
        local old_wire,old_cost=encoded(singleton);local wire,cost=encoded(marked)
        check(old_wire[8]==false and old_wire[9]==false and wire[8]==false and wire[9]==16 and wire[12]==true,"first timestamp stays absent while exact second endpoint is present")
        check(cost==old_cost-3,"one false5 time becomes integer16 length2; marker cost stays the same upperbound")
        check(Codec.state_bytes(marked)-Codec.state_bytes(singleton)==256,"metadata key-growth reserve is exactly256, not32")
        local restored=decoded(wire)
        check(restored.first_at_ms==nil and restored.last_at_ms==16 and restored.paired==true,"decode never fabricates the absent first time")
        local large=F.logical(F.lease_state(),1,3,2,true);large.last_at_ms=9007199254740992
        local _,large_cost=encoded(large)
        check(large_cost==old_cost+11 and Codec.state_bytes(large)-Codec.state_bytes(singleton)==256,"exact16-digit second endpoint costs eleven wire bytes plus256 state, total267")
    end)
    case("logical paired metadata accepts only true or absence",function()
        for _,flag in ipairs({false,0,1,"true",{}}) do
            local row=F.logical(F.lease_state(),1,3,2,flag)
            refuses(function() return Codec.encode_row(row) end,"explicit false or nonboolean paired")
            refuses(function() return Codec.state_bytes(row) end,"noncanonical paired state metadata")
        end
        local ordinary=F.logical(F.lease_state(),1,3,2)
        check(rawget(ordinary,"paired")==nil and encoded(ordinary)[12]==false,"paired absence remains ordinary even at repeats2")
    end)
    case("wire slot12 is mandatory and exactly boolean",function()
        local valid=encoded(F.logical(F.lease_state(),1))
        local missing=F.copy(valid);missing[12]=nil
        refuses(function() return Codec.wire_bytes(missing) end,"missing wire marker")
        refuses(function() return Codec.decode_row(missing) end,"missing wire marker decode")
        for _,flag in ipairs({0,1,"false","true",{}}) do
            local wire=F.copy(valid);wire[12]=flag
            refuses(function() return Codec.wire_bytes(wire) end,"wrong-type wire marker")
            refuses(function() return Codec.decode_row(wire) end,"wrong-type wire marker decode")
        end
        local extra=F.copy(valid);extra[13]=false
        refuses(function() return Codec.wire_bytes(extra) end,"extra thirteenth wire slot")
    end)
    case("true marker refuses wrong kind class or occurrence metadata",function()
        local valid=encoded(F.logical(F.lease_state(),1,3,2,true))
        local mutations={function(w)w[1]=true end,function(w)w[10]=true end,function(w)w[2]=1 end,
            function(w)w[7]=1 end,function(w)w[7]=3 end,function(w)w[6]=w[5] end}
        for _,change in ipairs(mutations) do
            local wire=F.copy(valid);change(wire)
            refuses(function() return Codec.wire_bytes(wire) end,"structurally invalid true origin marker")
            refuses(function() return Codec.decode_row(wire) end,"invalid true marker decode")
        end
        for _,change in ipairs({function(r)r.kind="source" end,function(r)r.critical=true end,function(r)r.incomplete=true end,
            function(r)r.repeats=1 end,function(r)r.last_call=r.first_call end}) do
            local row=F.logical(F.lease_state(),1,3,2,true);change(row)
            refuses(function() return Codec.encode_row(row) end,"invalid logical paired kind/class/count")
        end
    end)
    case("structural wire costing does not falsely attest full SDK debt consistency",function()
        local contradictory=F.capture_state("capturing");contradictory.report_debt=false
        unknown(contradictory,"capturing with absent report duty")
        local ordinary=F.logical(contradictory,1,3,2)
        local wire=F.copy(encoded(ordinary));wire[12]=true
        check(type(Codec.wire_bytes(wire))=="number","wire_bytes checks marker structure; no fabricated full-DTO validation claim")
        refuses(function() return Codec.decode_row(wire) end,"true marker debt contradiction is rejected after data expansion")
        refuses(function() return Codec.encode_row(F.logical(contradictory,1,3,2,true)) end,"logical true marker requires a fully known SDK DTO")
        local ordinary_wire=encoded(ordinary);local preserved=decoded(ordinary_wire)
        check(rawget(preserved,"paired")==nil and preserved.data.report_debt==false,"ineligible facts still remain ordinary evidence under the unchanged format")
    end)
    case("exact required SDK fields and presence define the known subset",function()
        check(#F.state_fields==20 and #F.capture_fields==18,"independent builder field inventories are exact")
        for _,item in ipairs({{data=F.lease_state(),fields=F.state_fields},{data=F.capture_state("capturing"),fields=F.capture_fields},
            {data=F.capture_state("waiting_neutral"),fields=F.capture_fields}}) do
            check(count(item.data)==#item.fields and Codec.pair_data_known(item.data)==true,"complete exact builder DTO")
            for _,name in ipairs(item.fields) do
                local missing=F.copy(item.data);missing[name]=nil;unknown(missing,"missing required field "..name)
            end
        end
        local state_extra=F.lease_state();state_extra.phase="active";unknown(state_extra,"sanitized lease field absent from actual state builder")
        local capture_extra=F.capture_state("capturing");capture_extra.capture_reserved=true;unknown(capture_extra,"sanitized lease field absent from actual capture builder")
        -- Raw caller extras can be discarded by Recorder sanitization. These are exact sanitized DTO tests only.
    end)
    case("canonical unsigned64 IDs and exact250 time windows do not coerce to numbers",function()
        local edge=F.lease_state();edge.requested_ms="18446744073709551365";edge.expires_ms="18446744073709551615"
        edge.observed_ms=edge.requested_ms;edge.last_observation=edge.requested_ms
        check(Codec.pair_data_known(edge)==true,"MAX-250 plus exact250 reaches MAX without overflow")
        local beyond_double=F.lease_state();beyond_double.requested_ms="9007199254740993";beyond_double.expires_ms="9007199254741243"
        beyond_double.observed_ms=beyond_double.requested_ms;beyond_double.last_observation=beyond_double.requested_ms
        check(Codec.pair_data_known(beyond_double)==true,"exact ID arithmetic beyond2^53 remains decimal-string based")
        local large_id_wire=encoded(F.logical(beyond_double,1,3,2,true));local restored=decoded(large_id_wire)
        check(restored.data.requested_ms=="9007199254740993" and restored.data.expires_ms=="9007199254741243","large u64 strings are never rounded in wire payloads")
        local minimum=F.lease_state();minimum.expires_ms="1250";check(Codec.pair_data_known(minimum)==true,"request1000 plus exact250 is admitted")
        local mutations={function(d)d.requested_ms="18446744073709551366";d.expires_ms="18446744073709551615";d.observed_ms=d.requested_ms;d.last_observation=d.requested_ms end,
            function(d)d.expires_ms="1249" end,function(d)d.observed_ms="2000" end,function(d)d.observed_ms="999" end,
            function(d)d.requested_ms="0" end,function(d)d.source_epoch="07" end,function(d)d.sequence="0" end,
            function(d)d.sequence="18446744073709551616" end,function(d)d.context_generation="100000000000000000000" end,
            function(d)d.renewals="00" end,function(d)d.expires_ms=2000 end}
        for _,change in ipairs(mutations) do local invalid=F.lease_state();change(invalid);unknown(invalid,"noncanonical or contradictory exact-u64 window") end
        for _,name in ipairs({"sequence","source_epoch","context_generation","expires_ms"}) do
            local full=F.capture_state("capturing");full[name]="18446744073709551615"
            check(Codec.pair_data_known(full)==true,"capture shared nonzero ID allows exact MAX at "..name)
        end
    end)
    case("capture debt flags counters and known phases stay exact",function()
        local capturing=F.capture_state("capturing");check(capturing.report_debt and Codec.pair_data_known(capturing)==true,"known report_debt=true is permitted, not unknown")
        local fully_neutral=F.capture_state("capturing");fully_neutral.publications="100";fully_neutral.neutral_releases="100"
        check(Codec.pair_data_known(fully_neutral)==true,"equal counters do not invent debt discharge or completion")
        local mutations={function(d)d.report_debt=false end,function(d)d.capturing=false end,function(d)d.publications="0" end,
            function(d)d.neutral_releases="2" end,function(d)d.neutral_releases="00" end,function(d)d.phase="unknown" end,
            function(d)d.phase="capturing_unknown" end,function(d)d.reason="unknown" end,function(d)d.quarantined=true end,
            function(d)d.terminal=true end,function(d)d.capturing=1 end}
        for _,change in ipairs(mutations) do local invalid=F.capture_state("capturing");change(invalid);unknown(invalid,"capture phase/flag/counter contradiction") end
        local waiting=F.capture_state("waiting_neutral");check(Codec.pair_data_known(waiting)==true,"known waiting state has both counters zero and no report duty")
        for _,change in ipairs({function(d)d.publications="1" end,function(d)d.report_debt=true end,function(d)d.capturing=true end}) do
            local invalid=F.capture_state("waiting_neutral");change(invalid);unknown(invalid,"waiting-neutral contradiction")
        end
        for _,change in ipairs({function(d)d.status="unknown" end,function(d)d.status="active_unknown" end,function(d)d.reason="none:cached" end,
            function(d)d.report_debt=true end,function(d)d.capturing=true end,function(d)d.source_released=true end,function(d)d.orphaned=true end}) do
            local invalid=F.lease_state();change(invalid);unknown(invalid,"strict active state subset")
        end
        local known_other=F.lease_state();known_other.capture_reserved=false;check(Codec.pair_data_known(known_other)==true,"both actual boolean capture-reservation values are preserved")
    end)
    case("SDK user publication excludes same-negative-zero and wrong scalar types",function()
        for user=0,3 do local data=F.lease_state();data.user=user;check(Codec.pair_data_known(data)==true,"SDK uint32 user0..3") end
        local negative=F.lease_state();negative.user=-1/math.huge
        check(F.same(negative,F.copy(negative)),"same negativezero data would pass bitwise equality; eligibility must still reject impossible SDK user")
        unknown(negative,"signed-negative-zero SDK user")
        refuses(function() return Codec.encode_row(F.logical(negative,1,3,2,true)) end,"same-negative-zero logical pair")
        for _,user in ipairs({-1,4,.5,"0",false}) do local invalid=F.lease_state();invalid.user=user;unknown(invalid,"wrong user scalar/range") end
        for _,change in ipairs({function(d)d.call_ok=false end,function(d)d.call_ok=1 end,function(d)d.arity=2 end,function(d)d.arity="1" end,
            function(d)d.capture_reserved=1 end}) do local invalid=F.lease_state();change(invalid);unknown(invalid,"exact SDK scalar publication") end
    end)
    case("strict v4 envelope accepts schema2 and rejects v3 or v2 without fallback",function()
        local wire=encoded(F.logical(F.lease_state(),1))
        local chunk={schema=2,encoding="hop-delta-v4",run_id="pair_codec_fixture",chunk=1,rows={wire}}
        check(Codec.chunk_bytes(chunk)~=nil and Codec.envelope_bytes(chunk)~=nil,"schema2 and explicit v4 remain accepted")
        local rows,why=Codec.decode_chunks({chunk},"pair_codec_fixture")
        check(type(rows)=="table" and #rows==1 and rawget(rows[1],"paired")==nil,"ordinary v4 stream decodes once: "..tostring(why))
        for _,encoding in ipairs({"hop-delta-v3","hop-delta-v2","hop-delta-v5"}) do
            local old=F.copy(chunk);old.encoding=encoding
            refuses(function() return Codec.chunk_bytes(old) end,"non-v4 chunk")
            refuses(function() return Codec.envelope_bytes(old) end,"non-v4 envelope")
            refuses(function() return Codec.decode_chunks({old},"pair_codec_fixture") end,"non-v4 stream has no fallback")
        end
    end)
    check(cases==12,"complete independent12-case Codec/SDK marker matrix")
    return {cases=cases,assertions=assertions,native_actions=0,context_authority=false}
end
return table.freeze(Tests)

-- Independent source-only decoder cursor regressions. Root must bind both exact
-- codecs and explicitly call run(); this module performs no native/game action.
local Codec=require("./hop_evidence_codec")
local Before=require("./hop_evidence_codec_before")
local Tests={}
local RUN="cursor_fixture"
local minus_zero=-1/math.huge
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn) cases+=1;local ok,why=pcall(fn);assert(ok,name..": "..tostring(why)) end
    local function copy(value)
        if type(value)~="table" then return value end
        local out={};for key,child in pairs(value) do out[key]=copy(child) end;return out
    end
    local function frozen(value)
        if type(value)=="table" and not table.isfrozen(value) then
            for _,child in pairs(value) do frozen(child) end;table.freeze(value)
        end
        return value
    end
    local function same(a,b)
        if type(a)~=type(b) then return false end
        if type(a)~="table" then return a==b and (type(a)~="number" or a~=0 or 1/a==1/b) end
        for key,value in pairs(a) do if not same(value,rawget(b,key)) then return false end end
        for key in pairs(b) do if rawget(a,key)==nil then return false end end
        return true
    end
    local function row(kind,data,call,critical)
        return {kind=kind,data=data,first_call=call,last_call=call,repeats=1,incomplete=false,critical=critical==true}
    end
    local function literal(call,critical)
        return {critical==true,critical and 14 or 13,"",0,call,call,1,false,false,false,{2,false},false}
    end
    local function encoded(value,base)
        local wire,why=Before.encode_row(value,base)
        check(type(wire)=="table","independent before-codec fixture encodes: "..tostring(why))
        return wire
    end
    local function chunk(rows,index,run)
        return {schema=2,encoding="hop-delta-v4",run_id=run or RUN,chunk=index or 1,rows=rows}
    end
    local function pack(wires,width,run)
        local chunks={}
        for first=1,#wires,width do
            local rows={};for at=first,math.min(first+width-1,#wires) do rows[#rows+1]=wires[at] end
            chunks[#chunks+1]=chunk(rows,#chunks+1,run)
        end
        return chunks
    end
    local function before_bulk(chunks,run)
        return Before.decode_chunks(chunks,run or RUN)
    end
    local function opened(chunks,run)
        local cursor,why=Codec.open_chunks(chunks,run or RUN)
        check(type(cursor)=="table","valid frozen cursor opens: "..tostring(why))
        check(table.isfrozen(cursor),"public cursor object is frozen")
        return cursor
    end
    local counter_keys={"rows","regular_rows","critical_rows","chunks","regular_wire_bytes","regular_state_bytes",
        "regular_bytes","critical_bytes","encoded_store_bytes"}
    local function same_counters(actual,expected,why)
        for _,key in ipairs(counter_keys) do check(actual[key]==expected[key],why.." unchanged "..key) end
    end
    local function failed(cursor,previous,why)
        local value,reason=cursor:next()
        check(value==nil and type(reason)=="string" and #reason>0,why.." returns a refusal, never a prefix row")
        local status=cursor:status()
        check(table.isfrozen(status) and status.failed and not status.complete and status.reason==reason,why.." status is failed and unqualified")
        if previous then same_counters(status,previous,why) end
        local again,sticky=cursor:next()
        check(again==nil and sticky==reason,why.." first reason is sticky")
        same_counters(cursor:status(),status,why.." retry")
        return reason,status
    end
    local function drain(cursor,maximum)
        local rows={}
        for _=1,maximum or 2177 do
            local value,reason=cursor:next()
            check(reason==nil,"valid cursor row/EOF has no refusal: "..tostring(reason))
            if value==nil then
                local status=cursor:status();check(status.complete and not status.failed,"only actual EOF marks complete")
                return rows,status
            end
            rows[#rows+1]=value
            check(not cursor:status().complete,"last yielded row is still not an EOF acceptance")
        end
        error("bounded cursor fixture did not reach EOF")
    end
    local function expected_costs(chunks,rows)
        local regular,critical,wire_bytes,critical_bytes,store=0,0,0,0,2
        local latest={}
        for _,part in ipairs(chunks) do
            local bytes,why=Before.envelope_bytes(part);check(type(bytes)=="number","before envelope fixture valid: "..tostring(why));store+=bytes
            for _,wire in ipairs(part.rows) do
                local n=Before.wire_bytes(wire)
                if wire[1] then critical_bytes+=n else wire_bytes+=n end
            end
        end
        for _,value in ipairs(rows) do
            if value.critical then critical+=1 else
                regular+=1;latest[value.kind.."|"..(value.data.call or "")]=value
            end
        end
        local state_bytes=2048
        for _,value in pairs(latest) do state_bytes+=Before.state_bytes(value) end
        return {rows=#rows,regular_rows=regular,critical_rows=critical,chunks=#chunks,
            regular_wire_bytes=wire_bytes,regular_state_bytes=state_bytes,regular_bytes=wire_bytes+state_bytes,
            critical_bytes=critical_bytes,encoded_store_bytes=store}
    end
    local function capture_data()
        return {call="input.lease_capture_state",arity=1,call_ok=true,sequence="1",user=0,source_epoch="7",context_generation="9",
            phase="capturing",reason="none",terminal=false,quarantined=false,capturing=true,report_debt=true,
            generation="21",revision="22",expires_ms="900000",publications="1",neutral_releases="0"}
    end
    local function diverse_rows()
        local a=row("body",{mass=minus_zero,time=1/60,position={1e300,5e-324,0}},1)
        a.first_at_ms=minus_zero;a.last_at_ms=0
        local b=row("source",{call="sample",sequence="9007199254740993",source_epoch="18446744073709551615",result=false,reason="caf\195\169"},2)
        b.last_at_ms=4.25
        local c=row("lease",capture_data(),3);c.last_call=5;c.repeats=2;c.first_at_ms=minus_zero;c.paired=true
        local d=row("body",{mass=106,position={0,0,0}},4)
        local e=row("lease",capture_data(),6);e.first_at_ms=0;e.last_at_ms=6.125
        local f=row("terminal",{phase="cleanup_unknown",cleanup_unknown=true,result=false},7,true)
        local g=row("follow",{sequence="3",phase="following",claim_known=true},8)
        g.last_call=12;g.repeats=3;g.first_at_ms=0;g.last_at_ms=20
        return {a,b,c,d,e,f,g}
    end
    local function encode_rows(rows)
        local wires,bases={},{}
        for _,value in ipairs(rows) do
            local key=value.kind.."|"..(value.data.call or "")
            wires[#wires+1]=encoded(value,value.critical and nil or bases[key])
            if not value.critical then bases[key]=value end
        end
        return wires
    end
    local function large_data()
        local data={};for at=1,44 do data[Before.fields[at]]=string.rep("x",192) end;return data
    end

    case("public profile and before oracle are bound to profile4",function()
        check(Codec.version==4 and Before.version==4 and Codec.encoding=="hop-delta-v4" and Before.encoding=="hop-delta-v4","profile identity remains strict4")
        check(Codec.pair_pointer_bytes==2048 and Codec.pair_wire_meta_bytes==16 and Codec.pair_state_meta_bytes==256,"accounting constants remain original profile4")
        check(type(Codec.open_chunks)=="function" and type(Codec.decode_chunks)=="function","new cursor and old bulk interfaces coexist")
    end)
    case("valid bulk and cursor preserve exact values across chunk partitions",function()
        local expected=diverse_rows();local wires=encode_rows(expected)
        for _,width in ipairs({1,2,4,16}) do
            local mutable=pack(wires,width)
            local old,why=before_bulk(mutable);check(type(old)=="table","before valid bulk: "..tostring(why))
            local actual=Codec.decode_chunks(copy(mutable),RUN)
            check(same(actual,old) and same(actual,expected),"new bulk preserves every exact decoded value and metadata")
            local cursor=opened(frozen(copy(mutable)))
            local streamed,status=drain(cursor)
            check(same(streamed,old),"streaming preserves signs, absence, paired markers and opaque legacy counts")
            check(1/streamed[1].data.mass==-math.huge and 1/streamed[1].first_at_ms==-math.huge and streamed[2].first_at_ms==nil,"zero signs and absent first timestamp stay exact")
            check(streamed[3].paired==true and streamed[3].data.report_debt==true and streamed[3].last_at_ms==nil and streamed[5].paired==nil,"new pair provenance and known unresolved report debt are not cleared")
            same_counters(status,expected_costs(mutable,old),"complete valid partition")
        end
    end)
    case("bulk retains mutable input compatibility without freezing callers",function()
        local input=copy(pack(encode_rows(diverse_rows()),3))
        check(not table.isfrozen(input) and not table.isfrozen(input[1]) and not table.isfrozen(input[1].rows[1]),"fixture is genuinely mutable at all borrowed levels")
        local old=before_bulk(input);local result=Codec.decode_chunks(input,RUN)
        check(same(result,old),"mutable bulk returns the old exact values")
        check(not table.isfrozen(input) and not table.isfrozen(input[1]) and not table.isfrozen(input[1].rows)
            and not table.isfrozen(input[1].rows[1]) and not table.isfrozen(input[1].rows[1][11]),"bulk does not freeze caller-owned archive or node tables")
        input[1].rows[1][11][1]=99
        check(result[1].data.mass==minus_zero and 1/result[1].data.mass==-math.huge,"output is detached from later caller mutations")
    end)
    case("open validates only outer metadata and rejects hostile outer shapes",function()
        local callbacks=0
        local hostile=setmetatable({}, {__len=function() callbacks+=1;error("must not measure") end,__iter=function() callbacks+=1;error("must not iterate") end})
        local sparse=table.freeze({[1]=frozen(chunk({literal(1)})),[3]=frozen(chunk({literal(2)},3))})
        for _,input in ipairs({{},hostile,newproxy(),sparse}) do
            local cursor,why=Codec.open_chunks(input,RUN)
            check(cursor==nil and type(why)=="string" and #why>0,"invalid or unfrozen outer input refuses")
        end
        for _,run in ipairs({"",string.rep("a",33),"\195\169"}) do local cursor,why=Codec.open_chunks(frozen({}),run);check(cursor==nil and type(why)=="string","invalid run refuses") end
        check(callbacks==0,"invalid outer shapes invoke no caller callback")
    end)
    case("public cursor refuses mutable current layers lazily",function()
        local cases_input={}
        local a=chunk({literal(1)});frozen(a.rows);cases_input[#cases_input+1]=table.freeze({a})
        local b=chunk({literal(1)});frozen(b.rows[1]);table.freeze(b);cases_input[#cases_input+1]=table.freeze({b})
        local c=chunk({literal(1)});table.freeze(c.rows);table.freeze(c);cases_input[#cases_input+1]=table.freeze({c})
        local d=chunk({literal(1)});table.freeze(d.rows[1]);table.freeze(d.rows);table.freeze(d);cases_input[#cases_input+1]=table.freeze({d})
        for _,input in ipairs(cases_input) do
            local cursor=opened(input);local before=cursor:status()
            failed(cursor,before,"mutable current borrowed layer")
        end
    end)
    case("a mutable later chunk is not walked at open or before first row",function()
        local first=frozen(chunk({literal(1)}))
        local later=chunk({literal(2)},2)
        local input=table.freeze({first,later})
        local cursor=opened(input);local value,why=cursor:next()
        check(value~=nil and value.first_call==1 and why==nil,"first valid frozen chunk is decoded before later borrowed immutability check")
        local previous=cursor:status();check(previous.rows==1 and previous.chunks==1 and not previous.complete,"prefix is explicitly incomplete")
        failed(cursor,previous,"later mutable chunk")
    end)
    case("one next yields one row and consumed chunks count only completed rows",function()
        local cursor=opened(frozen({chunk({literal(1),literal(2)}),chunk({literal(3)},2)}))
        local initial=cursor:status();check(initial.rows==0 and initial.chunks==0 and not initial.complete and not initial.failed,"open performs no header or row work")
        local a=cursor:next();check(a.first_call==1 and cursor:status().rows==1 and cursor:status().chunks==0,"first row does not consume the whole two-row chunk")
        local b=cursor:next();check(b.first_call==2 and cursor:status().rows==2 and cursor:status().chunks==1,"second row fully consumes first chunk only")
        local c=cursor:next();check(c.first_call==3 and cursor:status().rows==3 and cursor:status().chunks==2 and not cursor:status().complete,"last row is not an EOF certificate")
        local eof,why=cursor:next();check(eof==nil and why==nil and cursor:status().complete,"separate O(1) EOF call completes the archive")
        local repeated,again=cursor:next();check(repeated==nil and again==nil and cursor:status().complete,"EOF is stable")
    end)
    case("empty archive completes only on EOF with fixed reserve",function()
        local cursor=opened(table.freeze({}))
        local before=cursor:status()
        check(before.rows==0 and before.chunks==0 and before.regular_state_bytes==2048 and before.regular_bytes==2048
            and before.encoded_store_bytes==2 and not before.complete and not before.failed,"empty open reports only initial fixed accounting")
        local eof,why=cursor:next();check(eof==nil and why==nil,"empty EOF returns no row or refusal")
        local after=cursor:status();check(after.complete and not after.failed,"empty archive is complete only now");same_counters(after,before,"empty EOF")
    end)
    case("late invalid row does not make earlier prefix accepted evidence",function()
        local invalid=literal(2);invalid[7]=0
        local cursor=opened(frozen({chunk({literal(1),invalid})}))
        local first=cursor:next();check(first.first_call==1,"first row precedes later row validation")
        local before=cursor:status();check(not before.complete and before.rows==1 and before.chunks==0,"prefix is neither complete nor a fully consumed chunk")
        failed(cursor,before,"later invalid metadata")
    end)
    case("late invalid header is not opened until its own next call",function()
        local later=chunk({literal(2)},2);later.encoding="hop-delta-v3"
        local cursor=opened(frozen({chunk({literal(1)}),later}))
        local first=cursor:next();check(first.first_call==1 and cursor:status().chunks==1,"old profile in later header is not bulk-scanned at open")
        failed(cursor,cursor:status(),"later unsupported header")
    end)
    case("empty tail chunk refuses without scanning or accepting a later header",function()
        local cursor=opened(frozen({chunk({literal(1)}),chunk({},2),chunk({literal(3)},3)}))
        local first=cursor:next();check(first.first_call==1,"initial row remains a prefix observation")
        local reason,status=failed(cursor,cursor:status(),"empty second chunk")
        check(reason:find("empty chunk",1,true)~=nil and status.rows==1 and status.chunks==1,"empty header is refused rather than skipped toward third chunk")
    end)
    case("bulk keeps eager old error precedence while cursor has lazy row precedence",function()
        local missing={false,2,"",1,2,2,1,false,false,false,{3,false},false}
        local later=literal(3);later[11]={9,false}
        local input={chunk({missing,later})}
        local old,old_reason=before_bulk(copy(input))
        local actual,actual_reason=Codec.decode_chunks(copy(input),RUN)
        check(old==nil and actual==nil and actual_reason==old_reason and old_reason:find("unknown node tag",1,true)~=nil,"bulk preflights the whole chunk before row-reference admission, exactly as before")
        local _,first_reason=Before.decode_row(missing)
        local cursor=opened(frozen(copy(input)));local reason=failed(cursor,cursor:status(),"first lazy missing base")
        check(reason==first_reason and reason~=old_reason,"public cursor validates one current row instead of borrowing eager-bulk precedence")
    end)
    case("old and new bulk refusal strings match across malformed archives",function()
        local malformed={}
        local bad=chunk({literal(1)});bad.unknown=false;malformed[#malformed+1]={bad}
        bad=chunk({literal(1)});bad.schema=1;malformed[#malformed+1]={bad}
        bad=chunk({literal(1)});bad.encoding="hop-delta-v3";malformed[#malformed+1]={bad}
        bad=chunk({literal(1)});bad.chunk=2;malformed[#malformed+1]={bad}
        bad=literal(1);bad[12]=0;malformed[#malformed+1]={chunk({bad})}
        bad=literal(1);bad[11]={2,{{315,{1,true}}}};malformed[#malformed+1]={chunk({bad})}
        bad=literal(1);bad[12]=true;malformed[#malformed+1]={chunk({bad})}
        malformed[#malformed+1]={chunk({literal(1),literal(1)})}
        malformed[#malformed+1]={chunk({literal(1)}),chunk({literal(2)},3)}
        malformed[#malformed+1]={chunk({})}
        for _,input in ipairs(malformed) do
            local old,old_reason=before_bulk(copy(input));local actual,reason=Codec.decode_chunks(copy(input),RUN)
            check(old==nil and type(old_reason)=="string" and actual==nil and reason==old_reason,"bulk returns the identical first refusal and no row-prefix array")
        end
    end)
    case("status snapshots are immutable and methods refuse invalid selves",function()
        local cursor=opened(frozen({chunk({literal(1)})}))
        local status=cursor:status();check(table.isfrozen(status),"status snapshot is frozen")
        check(not pcall(function() status.rows=999 end),"caller cannot alter reported prefix counters")
        local next_method,status_method=cursor.next,cursor.status
        local value,why=next_method({});check(value==nil and type(why)=="string","invalid next self refuses")
        value,why=status_method({});check(value==nil and type(why)=="string","invalid status self refuses")
        check(cursor:status().rows==0 and cursor:status().failed==false,"bad external self does not mutate valid owner")
    end)
    case("all logical row and chunk allowances remain independently bounded",function()
        local wires={};for call=1,2048 do wires[#wires+1]=literal(call) end
        for call=2049,2176 do wires[#wires+1]=literal(call,true) end
        local input=pack(wires,1,string.rep("r",32))
        local expected=before_bulk(input,string.rep("r",32));check(type(expected)=="table" and #expected==2176,"before accepts maximum logical classes without expansion")
        local cursor=opened(frozen(copy(input)),string.rep("r",32));local result,status=drain(cursor)
        check(#result==2176 and status.regular_rows==2048 and status.critical_rows==128 and status.chunks==2176,"same logical rows, not per-occurrence expansion, consume the old allowances")
        same_counters(status,expected_costs(input,expected),"maximum legal archive")
        local too_many=copy(input);too_many[#too_many+1]=chunk({literal(2177)},2177,string.rep("r",32))
        local refused,why=Codec.open_chunks(frozen(too_many),string.rep("r",32));check(refused==nil and type(why)=="string","2177th chunk exceeds unchanged outer bound")
    end)
    case("regular and critical excess rows refuse atomically",function()
        for _,critical in ipairs({false,true}) do
            local cap=critical and 128 or 2048;local wires={}
            for call=1,cap+1 do wires[#wires+1]=literal(call,critical) end
            local cursor=opened(frozen(pack(wires,16)))
            for _=1,cap do local value,why=cursor:next();check(value~=nil and why==nil,"each in-cap row remains valid") end
            local reason,status=failed(cursor,cursor:status(),"excess logical class row")
            check(reason:find(critical and "critical capacity" or "regular capacity",1,true)~=nil,"same original class guard refuses")
            check(status.rows==cap,"failed extra row is not counted")
        end
    end)
    case("projection65 refuses without installing an unadmitted base",function()
        local wires={}
        for call=1,65 do wires[#wires+1]=encoded(row("source",{call="P"..tostring(call),sequence=tostring(call)},call)) end
        local cursor=opened(frozen(pack(wires,16)))
        for _=1,64 do check(cursor:next()~=nil,"known in-cap independent projection retained") end
        local reason,status=failed(cursor,cursor:status(),"projection65")
        check(reason:find("projection capacity",1,true)~=nil and status.rows==64,"65th base is refused at the existing projection cap")
    end)
    case("regular byte and current-base accounting refuse before commit",function()
        local data=large_data();local wires,total={},0
        local base_cost=Before.state_bytes(row("body",data,1))
        for call=1,128 do
            local wire=encoded(row("body",copy(data),call));wires[#wires+1]=wire;total+=Before.wire_bytes(wire)
            if total+base_cost+2048>524288 then break end
        end
        check(#wires<2048 and total+base_cost+2048>524288,"bounded fixture crosses byte admission before row count")
        local cursor=opened(frozen(pack(wires,2)))
        for _=1,#wires-1 do local value,why=cursor:next();check(value~=nil and why==nil,"prior bytes and replacement bases fit") end
        local reason=failed(cursor,cursor:status(),"regular byte boundary")
        check(reason:find("regular capacity",1,true)~=nil,"original regular byte cap remains authoritative")
    end)
    case("critical byte accounting remains independent of regular reserve",function()
        local data=large_data();local wires,total={},0
        for call=1,128 do
            local wire=encoded(row("terminal",copy(data),call,true));wires[#wires+1]=wire;total+=Before.wire_bytes(wire)
            if total>131072 then break end
        end
        check(#wires<128 and total>131072,"critical bytes exceed before critical rows")
        local cursor=opened(frozen(pack(wires,2)))
        for _=1,#wires-1 do check(cursor:next()~=nil,"in-cap independent critical row") end
        local reason,status=failed(cursor,cursor:status(),"critical byte boundary")
        check(reason:find("critical capacity",1,true)~=nil and status.regular_state_bytes==2048,"critical-only cursor retains fixed reserve without charging these rows as regular")
    end)
    case("incremental chunk bytes refuse the offending row without eager scanning",function()
        local data=large_data();local wires={}
        for call=1,3 do wires[call]=encoded(row("body",copy(data),call)) end
        local old,why=before_bulk({chunk(wires)})
        check(old==nil and why:find("chunk byte limit",1,true)~=nil,"before bulk rejects the complete oversized chunk eagerly")
        local cursor=opened(frozen({chunk(copy(wires))}))
        for _=1,2 do local value,reason=cursor:next();check(value~=nil and reason==nil,"only the current valid row is charged incrementally") end
        local reason,status=failed(cursor,cursor:status(),"third large row exceeds chunk")
        check(reason:find("chunk byte limit",1,true)~=nil and status.rows==2 and status.chunks==0,"oversized row does not commit or consume the chunk")
    end)
    case("frozen cursor and method table reject tampering without exposing private state",function()
        local cursor=opened(frozen({chunk({literal(1)})}))
        local methods=getmetatable(cursor)
        check(table.isfrozen(cursor) and type(methods)=="table" and table.isfrozen(methods),
            "unprotected getmetatable exposes only the frozen method table")
        check(methods.__index==methods and rawget(methods,"__metatable")==nil,
            "method dispatch is frozen without a protected-metatable sentinel")
        local original_next,original_status,original_index=methods.next,methods.status,methods.__index
        local replacement=function() error("tampered decoder must never run") end
        check(not pcall(function() cursor.rows=999 end),"cursor field assignment is refused")
        check(not pcall(function() rawset(cursor,"next",replacement) end),"rawset cannot replace cursor dispatch")
        check(not pcall(function() setmetatable(cursor,{__index={next=replacement}}) end),"readonly cursor rejects metatable replacement")
        check(not pcall(function() setmetatable(cursor,nil) end),"readonly cursor rejects metatable removal")
        check(not pcall(function() methods.next=replacement end),"method-table next assignment is refused")
        check(not pcall(function() rawset(methods,"next",replacement) end),"method-table rawset is refused")
        check(not pcall(function() methods.__index={} end),"method-table __index replacement is refused")
        check(not pcall(function() methods.__metatable="locked" end),"method-table protected sentinel cannot be installed")
        check(not pcall(function() setmetatable(methods,{}) end),"readonly method table rejects its own metatable replacement")
        check(methods.next==original_next and methods.status==original_status and methods.__index==original_index
            and rawget(methods,"__metatable")==nil,"all method identities remain unchanged after tampering attempts")
        local cloned=table.clone(cursor)
        local forged=setmetatable({rows=999,complete=true,failed=false},methods)
        check(cloned~=cursor and getmetatable(cloned)==methods and getmetatable(forged)==methods,
            "clones and forgeries can borrow dispatch but are distinct object identities")
        for _,other in ipairs({cloned,forged}) do
            local value,why=original_next(other)
            check(value==nil and type(why)=="string" and #why>0,"borrowed methods grant no private decoder state")
            value,why=original_status(other)
            check(value==nil and type(why)=="string" and #why>0,"forged public counters grant no private status")
        end
        local untouched=cursor:status()
        check(untouched.rows==0 and untouched.chunks==0 and not untouched.complete and not untouched.failed,
            "invalid identities do not advance or poison the real cursor")
        local value,why=cursor:next()
        check(value~=nil and value.first_call==1 and why==nil,"real cursor still decodes the original row")
        local prefix=cursor:status()
        check(prefix.rows==1 and prefix.chunks==1 and not prefix.complete and not prefix.failed,
            "valid status survives with no fabricated EOF")
        local eof,reason=cursor:next()
        check(eof==nil and reason==nil and cursor:status().complete and not cursor:status().failed,
            "real cursor reaches verified EOF after every refused tamper")
    end)
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)

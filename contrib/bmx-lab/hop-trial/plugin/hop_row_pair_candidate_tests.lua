-- CONCRETE PROFILE4 TEST SOURCE ONLY. Author/reviewer execution UNRUN.
-- Exact SDK DTOs and marker/accounting expectations follow producer contract885A.
-- Root binds exact reviewed production modules in a NEW fixture; no runtime approval.
local Recorder=require("./hop_recorder")
local Codec=require("./hop_evidence_codec")
local Fixture=require("./hop_pair_sdk_fixtures")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local A,B="input.lease_state","input.lease_capture_state"
    local minus_zero=-1/math.huge
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn) cases+=1;local ok,why=pcall(fn);assert(ok,name..": "..tostring(why)) end
    local function copy(value)
        if type(value)~="table" then return value end
        local out={};for k,v in pairs(value) do out[k]=copy(v) end;return out
    end
    local function same(a,b)
        if type(a)~=type(b) then return false end
        if type(a)~="table" then return a==b and (type(a)~="number" or a~=0 or 1/a==1/b) end
        for k,v in pairs(a) do if not same(v,rawget(b,k)) then return false end end
        for k in pairs(b) do if rawget(a,k)==nil then return false end end
        return true
    end
    local function dto(call,sequence) return Fixture.data(call,sequence) end
    local function event(call,at,patch)
        local data=dto(call);if patch then for k,v in pairs(patch) do data[k]=v end end
        return {kind="lease",data=data,at=at}
    end
    local function emit(rec,ev)
        local payload=copy(ev.data);payload.at_ms=ev.at
        return rec:append(ev.kind,payload)
    end
    local function fresh(hook)
        local writes={};local recorder
        recorder=Recorder.new(function(key,value)
            writes[#writes+1]={key=key,value=value}
            if hook then hook(recorder,key,value) end
        end,"pair_candidate_fixture")
        return recorder,writes
    end
    local function terminal(stop)
        return {phase="done",stop_latched=stop==true,bike_authority=false,cleanup_pending=false,cleanup_unknown=false,
            bike_cleanup_complete=true,force_cleanup_clear=true,force_cleanup_unknown=false,
            source={cleanup_pending=false,cleanup_unknown=false,lease_handle_present=false},stop_reason="synthetic fixture"}
    end
    local function drain(rec)
        for _=1,2200 do
            if rec:status().flushed then return end
            local ok,why=rec:flush({inactive=true,terminal=true});check(ok,"synthetic flush: "..tostring(why))
        end
        error("bounded synthetic drain exceeded")
    end
    local function rows(writes)
        local chunks={};for _,write in ipairs(writes) do if write.value.rows then
            for _,wire in ipairs(write.value.rows) do check(#wire==12 and type(wire[12])=="boolean","every persisted row has its explicit v4 marker slot") end
            chunks[#chunks+1]=write.value
        end end
        local decoded,why=Codec.decode_chunks(chunks,"pair_candidate_fixture")
        check(type(decoded)=="table","strict unchanged codec must decode candidate rows: "..tostring(why))
        return decoded
    end
    local function finished(rec,writes)
        rec:terminal(terminal(true));drain(rec);return rows(writes)
    end
    local function lease_rows(decoded)
        local out={};for _,r in ipairs(decoded) do if r.kind=="lease" then out[#out+1]=r end end;return out
    end
    local function exact(r,first,last,repeats,data,first_at,last_at,critical,incomplete,paired)
        check(r~=nil and r.first_call==first and r.last_call==last and r.repeats==repeats,"manual exact occurrence endpoints/count")
        check(r.kind=="lease" and r.critical==(critical==true) and r.incomplete==(incomplete==true),"kind/class/completeness remain exact")
        check(same(r.data,data),"every DTO key/value/type/presence/zero sign remains exact")
        check(rawget(r,"paired")==((paired==true) and true or nil),"only a new fallback pair has logical paired=true; ordinary marker is absent")
        check(same(r.first_at_ms,first_at) and same(r.last_at_ms,last_at),"endpoint time presence and zero sign remain exact")
    end
    local function append_trace(rec,trace)
        for _,ev in ipairs(trace) do local ok,why=emit(rec,ev);check(ok,"original singleton accepted: "..tostring(why)) end
    end
    case("limits and construction stay unchanged",function()
        local expected={regular_rows=2048,regular_bytes=524288,critical_rows=128,critical_bytes=131072,
            summary_bytes=16384,row_bytes=12288,chunk_bytes=24576,chunk_rows=16,text_bytes=192}
        check(same(Recorder.limits,expected) and table.isfrozen(Recorder.limits),"no cap is renamed or widened")
        check(Codec.version==4 and Codec.encoding=="hop-delta-v4" and Codec.pair_pointer_bytes==2048 and Codec.pair_wire_meta_bytes==16 and Codec.pair_state_meta_bytes==256,"exact v4 profile and conservative charges")
        local rec,writes=fresh();check(#writes==0 and rec:status().regular_rows==0,"construction has no storage or observations")
        check(rec:status().summary.regular_bytes==2048 and rec:status().summary.regular_state_bytes==2048 and rec:status().summary.regular_wire_bytes==0,"fixed reserve is charged before empty/critical-only observations")
        check(not rec:flush({inactive=true,terminal=true}),"no terminal witness cannot flush")
    end)
    case("A1 B2 A3 becomes one exact sealed pair plus B2",function()
        local rec,writes=fresh();append_trace(rec,{event(A,10),event(B,20),event(A,30)})
        local st=rec:status();check(st.regular_rows==2 and st.coalesced==1 and st.summary.calls==3 and st.dropped==0,"one genuine fallback saving")
        local r=lease_rows(finished(rec,writes));check(#r==2,"two logical regular lease rows, no physical child bundle")
        exact(r[1],1,3,2,dto(A),10,30,false,false,true);exact(r[2],2,2,1,dto(B),20,20)
    end)
    case("sealed A1 A3 cannot absorb later A4 through legacy path",function()
        local rec,writes=fresh();append_trace(rec,{event(A,10),event(B,20),event(A,30),event(A,40)})
        local st=rec:status();check(st.regular_rows==3 and st.coalesced==1,"gross pair1 minus prevented legacy merge1 is NET0")
        local current=Codec.state_bytes(Fixture.logical(dto(A),4,4,1))+Codec.state_bytes(Fixture.logical(dto(B),2,2,1))
        check(st.summary.regular_state_bytes==2048+current,"historical sealed A1 wire remains, but ordinary current A4 releases paired-base256")
        local r=lease_rows(finished(rec,writes));check(#r==3,"pair plus B plus fresh A4")
        exact(r[1],1,3,2,dto(A),10,30,false,false,true);exact(r[2],2,2,1,dto(B),20,20);exact(r[3],4,4,1,dto(A),40,40)
    end)
    case("new later legacy span preserves known endpoints and total count",function()
        local rec,writes=fresh();append_trace(rec,{event(A,10),event(B,20),event(A,30),event(A,40),event(A,50),event(A,60)})
        local r=lease_rows(finished(rec,writes));check(#r==3,"candidate segmentation stays two A rows and B")
        exact(r[1],1,3,2,dto(A),10,30,false,false,true);exact(r[2],2,2,1,dto(B),20,20);exact(r[3],4,6,3,dto(A),40,60)
        check(r[1].repeats+r[3].repeats==5,"all five A occurrences counted; later legacy interior remains opaque")
        -- Manual baseline is A1 singleton + A3..A6 repeats4; its known1/3/6 endpoints are preserved.
        check(r[1].first_call==1 and r[1].last_call==3 and r[3].last_call==6,"no previously known endpoint is lost")
    end)
    case("alternating A B eight-call trace has four exact pairs",function()
        local rec,writes=fresh();append_trace(rec,{event(A,10),event(B,20),event(A,30),event(B,40),event(A,50),event(B,60),event(A,70),event(B,80)})
        local st=rec:status();check(st.regular_rows==4 and st.coalesced==4 and st.summary.calls==8,"manual NET4 against baseline eight rows")
        local r=lease_rows(finished(rec,writes));check(#r==4,"codec still returns four logical rows")
        exact(r[1],1,3,2,dto(A),10,30,false,false,true);exact(r[2],2,4,2,dto(B),20,40,false,false,true)
        exact(r[3],5,7,2,dto(A),50,70,false,false,true);exact(r[4],6,8,2,dto(B),60,80,false,false,true)
    end)
    case("other-kind barrier keeps existing legacy span unsealed",function()
        local rec,writes=fresh();append_trace(rec,{event(A,10),{kind="body",data={serial="20",mass=1},at=20},event(A,30),event(A,40)})
        local st=rec:status();check(st.regular_rows==2 and st.coalesced==2,"body does not change last lease; legacy already saves")
        local r=lease_rows(finished(rec,writes));check(#r==1,"legacy span is not spuriously sealed at repeats2")
        exact(r[1],1,4,3,dto(A),10,40)
    end)
    case("changed then returned data cannot pair with stale historical A1",function()
        local rec,writes=fresh();append_trace(rec,{event(A,10),event(B,20,{revision="20"}),event(A,30,{capture_reserved=false}),event(B,40,{revision="40"}),event(A,50)})
        local st=rec:status();check(st.regular_rows==5 and st.coalesced==0,"latest A3 data supersedes historical A1 candidate")
        local r=lease_rows(finished(rec,writes));check(#r==5,"every changed/returned fact is retained")
        exact(r[1],1,1,1,dto(A),10,10);exact(r[3],3,3,1,event(A,nil,{capture_reserved=false}).data,30,30);exact(r[5],5,5,1,dto(A),50,50)
    end)
    case("full DTO provenance presence and signed-zero equality are mandatory",function()
        local mutations={function(d)d.sequence="3" end,function(d)d.source_epoch="70" end,function(d)d.context_generation="90" end,
            function(d)d.capture_reserved=false end,function(d)d.reason="" end,function(d)d.report_debt=nil end,
            function(d)d.terminal=nil end,function(d)d.arity=0 end,function(d)d.user=minus_zero end}
        for _,change in ipairs(mutations) do
            local rec,writes=fresh();local last=event(A,30);change(last.data)
            append_trace(rec,{event(A,10),event(B,20),last});check(rec:status().regular_rows==3 and rec:status().coalesced==0,"subset or normalized equality must not merge")
            local r=lease_rows(finished(rec,writes));exact(r[1],1,1,1,dto(A),10,10);exact(r[3],3,3,1,last.data,30,30)
        end
    end)
    case("unknown identity and non-whitelisted call projections cannot fallback pair",function()
        for _,mode in ipairs({"identityless","absent-call","other-call"}) do
            local rec,writes=fresh();local first,last=event(A,10),event(A,30)
            if mode=="identityless" then first.data.sequence=nil;last.data.sequence=nil
            elseif mode=="absent-call" then first.data.call=nil;last.data.call=nil
            else first.data.call="input.other";last.data.call="input.other" end
            append_trace(rec,{first,event(B,20),last});check(rec:status().regular_rows==3 and rec:status().coalesced==0,"exact two-call whitelist and known_identity required")
            local r=lease_rows(finished(rec,writes));exact(r[1],1,1,1,first.data,10,10);exact(r[3],3,3,1,last.data,30,30)
        end
    end)
    case("contact and mapped rows never enter lease fallback slots",function()
        for _,kind in ipairs({"contact","mapped_hop"}) do
            local rec,writes=fresh()
            append_trace(rec,{{kind=kind,data={call=A,sequence="1"},at=10},{kind=kind,data={call=B,sequence="2"},at=20},{kind=kind,data={call=A,sequence="1"},at=30}})
            check(rec:status().regular_rows==3 and rec:status().coalesced==0,"matching call text alone cannot widen kind scope")
            local decoded=finished(rec,writes);local n=0;for _,r in ipairs(decoded) do if r.kind==kind then n+=1;check(r.repeats==1,"no unapproved semantic row paired") end end
            check(n==3,"all other-kind observations retained separately")
        end
    end)
    case("precoalesced prior span is never mistaken for a singleton",function()
        local rec,writes=fresh();append_trace(rec,{event(A,10),event(A,20),event(B,30),event(A,40)})
        check(rec:status().regular_rows==3 and rec:status().coalesced==1,"only original adjacent A1 A2 legacy coalesce")
        local r=lease_rows(finished(rec,writes));exact(r[1],1,2,2,dto(A),10,20);exact(r[2],3,3,1,dto(B),30,30);exact(r[3],4,4,1,dto(A),40,40)
    end)
    case("two exact endpoint times preserve absence and signed zero",function()
        for _,times in ipairs({{nil,16},{0,nil},{minus_zero,0}}) do
            local rec,writes=fresh();append_trace(rec,{event(A,times[1]),event(B,8),event(A,times[2])})
            local r=lease_rows(finished(rec,writes));check(#r==2,"different endpoint times do not change identical fact DTO")
            exact(r[1],1,3,2,dto(A),times[1],times[2],false,false,true)
            check(r[1].first_at_ms==times[1] and r[1].last_at_ms==times[2],"absence-to-present pairing never fills a missing first timestamp")
        end
    end)
    case("caller mutation cannot rewrite or freeze a retained singleton",function()
        local rec,writes=fresh();local payload=dto(A);payload.at_ms=10
        check(rec:append("lease",payload),"initial singleton")
        payload.phase="mutated";payload.sequence="999";check(not table.isfrozen(payload),"caller table must remain caller-owned")
        check(emit(rec,event(B,20)) and emit(rec,event(A,30)),"later originals")
        local r=lease_rows(finished(rec,writes));exact(r[1],1,3,2,dto(A),10,30,false,false,true)
    end)
    case("critical quarantined and incomplete observations refuse fallback",function()
        for _,mode in ipairs({"terminal","quarantined","incomplete"}) do
            local rec,writes=fresh();append_trace(rec,{event(A,10),event(B,20)})
            local last=event(A,30)
            if mode=="incomplete" then last.data.report_debt="invalid-boolean" else last.data[mode]=true end
            local ok=emit(rec,last);check(ok==(mode~="incomplete"),"incomplete retains loss, complete critical remains a fact")
            local st=rec:status();check(st.regular_rows==2 and st.critical_rows==1 and st.coalesced==0,"critical reserve never hides an ordinary fallback")
            if mode=="incomplete" then check(st.observation_loss and st.stop_requested,"invalid listed type remains sticky observation loss") end
            local r=lease_rows(finished(rec,writes));exact(r[1],1,1,1,dto(A),10,10)
            check(r[3].critical and r[3].incomplete==(mode=="incomplete") and r[3].first_call==3 and r[3].last_call==3,"critical/incomplete endpoint remains separate")
        end
    end)
    case("writing rows cannot be edited by reentrant pair admission",function()
        local entered=false
        local rec,writes=fresh(function(active,_,value)
            if value.rows and not entered then entered=true;check(emit(active,event(A,40)),"reentrant observation uses a new row") end
        end)
        append_trace(rec,{event(A,10),event(B,20)});rec:terminal(terminal(false))
        check(rec:flush({inactive=true,terminal=true}),"one synthetic captured chunk")
        check(entered and rec:status().regular_rows==4 and rec:status().coalesced==0,"writing A1 is ineligible; terminal call3 retains original ordinal")
        local captured=writes[1].value.rows;check(captured[1][5]==1 and captured[1][6]==1 and captured[1][7]==1,"captured frozen A1 header unchanged")
        drain(rec);local r=lease_rows(rows(writes));exact(r[1],1,1,1,dto(A),10,10);exact(r[3],4,4,1,dto(A),40,40)
    end)
    case("flushed singleton cannot be retroactively paired",function()
        local rec,writes=fresh();append_trace(rec,{event(A,10),event(B,20)});rec:terminal(terminal(false));drain(rec)
        local captured=writes[1].value.rows[1];check(emit(rec,event(A,40)),"new observation after a synthetic flush")
        check(rec:status().regular_rows==4 and rec:status().coalesced==0,"flushed A1 cannot pair with call4")
        drain(rec);check(captured[6]==1 and captured[7]==1,"old persisted header stays immutable")
        local r=lease_rows(rows(writes));exact(r[1],1,1,1,dto(A),10,10);exact(r[3],4,4,1,dto(A),40,40)
    end)
    case("latest exact base first_call survives interleaved pair updates",function()
        local rec,writes=fresh();append_trace(rec,{event(A,10),event(B,20),event(A,30),event(A,40,{capture_reserved=false}),event(B,50)})
        local r=lease_rows(finished(rec,writes));check(#r==3,"A pair, B pair and changed A4")
        exact(r[1],1,3,2,dto(A),10,30,false,false,true);exact(r[2],2,5,2,dto(B),20,50,false,false,true);exact(r[3],4,4,1,event(A,nil,{capture_reserved=false}).data,40,40)
        local found=false
        for _,write in ipairs(writes) do for _,wire in ipairs(write.value.rows or {}) do
            if wire[5]==4 then found=true;check(wire[4]==1,"changed A4 references current A1 base identity, never invented call3") end
        end end
        check(found,"changed row wire inspected")
    end)
    case("pair maps and seals have a positive regular-budget charge",function()
        local rec=fresh();append_trace(rec,{event(A,10),event(B,20),event(A,30)})
        local summary=rec:status().summary
        local paired=Fixture.logical(dto(A),1,3,2,true);local plain=Fixture.logical(dto(A),1,3,2)
        check(Codec.state_bytes(paired)-Codec.state_bytes(plain)==256,"paired current-base surcharge is exactly256, not the fixed reserve")
        local current=Codec.state_bytes(paired)+Codec.state_bytes(Fixture.logical(dto(B),2,2,1))
        check(summary.regular_state_bytes==2048+current,"reserve and paired current-base charge are both inside regular state")
        check(summary.regular_bytes==summary.regular_wire_bytes+summary.regular_state_bytes and summary.regular_bytes<=524288 and summary.regular_rows==2,"all charged metadata remains inside unchanged capacity")
    end)
    case("ordinary and critical logical row caps remain exact",function()
        local rec,writes=fresh()
        for _=1,2048 do check(rec:append("ack",{result=true}),"unpairable ordinary row") end
        check(not rec:append("ack",{result=true}),"2049th ordinary logical row refuses")
        check(rec:status().regular_rows==2048 and rec:status().dropped==1 and rec:status().observation_loss,"no row counter reset or critical spill")
        for _=1,128 do check(rec:append("ack",{result=true}),"bounded critical reserve") end
        check(not rec:append("ack",{result=true}) and rec:status().critical_rows==128,"129th critical row refuses")
        check(rec:status().summary.regular_bytes<=524288 and rec:status().summary.critical_bytes<=131072,"both byte budgets stay independent")
    end)
    case("failed noneligible admission leaves earlier endpoint metadata intact",function()
        local rec,writes=fresh();append_trace(rec,{event(A,10),event(B,20)})
        for _=1,2046 do check(rec:append("ack",{result=true}),"fill original row cap without eligible pairing") end
        check(not emit(rec,event(A,30,{capture_reserved=false})),"different DTO cannot exploit pairing to bypass row cap")
        local st=rec:status();check(st.regular_rows==2048 and st.coalesced==0 and st.dropped==1,"failed admission keeps prior counts, aside from explicit fault/drop")
        local r=lease_rows(finished(rec,writes));check(#r==2,"failed call adds no row and mutates neither prior endpoint")
        exact(r[1],1,1,1,dto(A),10,10);exact(r[2],2,2,1,dto(B),20,20)
        -- Exact private pair-metadata preflight injection is a separate mandatory proof obligation.
    end)
    case("known capturing debt survives pairing and remains unresolved",function()
        local rec,writes=fresh();append_trace(rec,{event(A,10),event(B,20),event(A,30),event(B,40)})
        check(rec:status().regular_rows==2 and rec:status().coalesced==2,"both exact known SDK projections can pair")
        local snap=terminal(true);snap.phase="cleanup_unknown";snap.cleanup_pending=true;snap.cleanup_unknown=true
        snap.source.capture_state={phase="capturing",report_debt=true,quarantined=false};snap.source.cleanup_pending=true
        rec:terminal(snap);drain(rec)
        local r=lease_rows(rows(writes));exact(r[1],1,3,2,dto(A),10,30,false,false,true);exact(r[2],2,4,2,dto(B),20,40,false,false,true)
        check(r[2].data.report_debt==true and r[2].data.capturing==true,"known report debt is retained, not classified unknown or discharged")
        check(rec:status().unresolved_debt and rec:status().unqualified and rec:status().summary.latest.source.capture_state.report_debt,"pairing cannot turn debt into cleanup completion")
    end)
    case("non-target follow legacy309 remains one unmarked opaque span",function()
        local rec,writes=fresh()
        for i=1,309 do check(rec:append("follow",{call="skater.follow_state",sequence="31",phase="pending",claim_known=true,at_ms=i-1}),"original follow observation") end
        local st=rec:status();check(st.regular_rows==1 and st.coalesced==308 and st.summary.calls==309,"all309 original follow calls retain legacy behavior")
        local found
        for _,r in ipairs(finished(rec,writes)) do if r.kind=="follow" then check(found==nil,"one logical follow row");found=r end end
        check(found and found.first_call==1 and found.last_call==309 and found.repeats==309 and found.first_at_ms==0 and found.last_at_ms==308,"legacy count/range endpoints stay exact")
        check(rawget(found,"paired")==nil,"legacy span never acquires the new-origin marker")
    end)
    case("same negative-zero user DTOs remain ineligible SDK states",function()
        local rec,writes=fresh();local first,last=event(A,10),event(A,30);first.data.user=minus_zero;last.data.user=minus_zero
        check(not Codec.pair_data_known(first.data),"SDK uint32 user cannot publish signed negative zero")
        append_trace(rec,{first,event(B,20),last})
        check(rec:status().regular_rows==3 and rec:status().coalesced==0 and not rec:status().observation_loss,"ineligible complete DTO is retained under original rules, not paired")
        local r=lease_rows(finished(rec,writes));exact(r[1],1,1,1,first.data,10,10);exact(r[3],3,3,1,last.data,30,30)
    end)
    case("known waiting-neutral capture DTOs pair without inventing debt",function()
        local rec,writes=fresh();local waiting=Fixture.capture_state("waiting_neutral")
        append_trace(rec,{{kind="lease",data=waiting,at=10},event(A,20),{kind="lease",data=Fixture.copy(waiting),at=30}})
        local r=lease_rows(finished(rec,writes));check(#r==2,"known waiting-neutral projection remains eligible")
        exact(r[1],1,3,2,waiting,10,30,false,false,true);exact(r[2],2,2,1,dto(A),20,20)
        check(r[1].data.capturing==false and r[1].data.report_debt==false and r[1].data.publications=="0" and r[1].data.neutral_releases=="0","all original waiting-state flags and counters remain exact")
    end)
    check(cases==24,"complete concrete24-case Recorder matrix")
    return {cases=cases,assertions=assertions,native_actions=0,implementation_qualified=false}
end
return table.freeze(Tests)

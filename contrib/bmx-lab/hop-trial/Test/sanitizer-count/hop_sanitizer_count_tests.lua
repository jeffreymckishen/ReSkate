-- TEST ONLY / SOURCE AUTHORED / UNRUN by this author.
-- Root supplies exact inverse-proved factories; none belongs in a staged mod.
local Baseline=require("./hop_sanitizer_baseline_factory")
local Candidate=require("./hop_sanitizer_candidate_factory")
local Codec=require("./hop_evidence_codec")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn)
        cases+=1
        local ok,why=pcall(fn)
        assert(ok,name..": "..tostring(why))
    end
    local function equal(a,b)
        if type(a)~=type(b) then return false end
        if type(a)=="number" then
            if a~=a or b~=b then return a~=a and b~=b end
            return a==b and (a~=0 or 1/a==1/b)
        end
        if type(a)~="table" then return a==b end
        if getmetatable(a)~=getmetatable(b) then return false end
        for k,v in pairs(a) do if not equal(v,rawget(b,k)) then return false end end
        for k in pairs(b) do if rawget(a,k)==nil then return false end end
        return true
    end
    local function eq(a,b,why) check(equal(a,b),why) end
    local function frozen(value)
        if type(value)~="table" then return true end
        if getmetatable(value)~=nil or not table.isfrozen(value) then return false end
        for _,child in pairs(value) do if not frozen(child) then return false end end
        return true
    end
    local function copy(value)
        if type(value)~="table" then return value end
        local out={};for k,v in pairs(value) do out[k]=copy(v) end;return out
    end
    local function probe(kind,payload,limit)
        local before,oldBudget=Baseline.probe(kind,payload,limit)
        local after,newBudget,count=Candidate.probe(kind,payload,limit)
        eq(after,before,"sanitizer output preserves exact key types/presence/scalars/zero signs")
        eq(newBudget,oldBudget,"legacy budget values and absent/full/lost fields remain exact")
        check(after==nil or frozen(after),"copied DTO is deeply plain/frozen")
        local expected,why=Codec.data_bytes(after)
        if expected~=nil then
            check(type(count)=="number" and count==expected,"private count equals independent Codec DATA count")
            check(count>=2 and count<=11904 and count%1==0,"accepted DTO count is a bounded exact integer")
        else
            check(type(why)=="string","rejected DTO has an independent Codec refusal")
        end
        return after,newBudget,count,expected,why
    end
    local gate=table.freeze({inactive=true,terminal=true})
    local function closed(unloaded)
        return {phase="done",detail="constructed complete observation",stop_reason="fixture stop",
            wall_ms=100,stop_latched=true,unloaded=unloaded==true,bike_authority=false,
            cleanup_pending=false,cleanup_unknown=false,bike_cleanup_complete=true,
            force_cleanup_clear=true,force_cleanup_unknown=false,
            ride={phase="off",force_pending=false,unknown=false,pending_count=0,submitted=1,acknowledged=1},
            source={phase="complete",cleanup_pending=false,cleanup_unknown=false,lease_handle_present=false,
                capture_state={report_debt=false,quarantined=false}},
            equipment={phase="idle",retained=false,unknown=false,unloaded=unloaded==true},
            board_drop={state="restored",restore_pending=false,drop_inflight=false,restore_inflight=false},
            mounted_pose={sends=1,stopped=true,nil_calls=1,nil_accepted=true}}
    end
    local function fresh(factory)
        local f={writes={}}
        local recorder
        recorder=factory.Recorder.new(function(key,value)
            f.writes[#f.writes+1]={key=key,value=value}
            if f.during then f.during(recorder,key,value) end
            if f.mode=="throw" then error("constructed writer refusal",0) end
            if f.mode=="true" then return true end
            if f.mode=="false" then return false end
            if f.mode=="nil" then return nil end
            if f.mode=="number" then return 0 end
            if f.mode=="string" then return "unexpected" end
        end,"sanitizer_count")
        f.recorder=recorder;f.private=factory.state(recorder)
        return f
    end
    local function pair() return fresh(Baseline),fresh(Candidate) end
    local function public_equal(a,b,why)
        eq(a.recorder:status(),b.recorder:status(),why.." public status")
        eq(a.writes,b.writes,why.." complete writer key/value trace")
        eq(a.private.base_bytes,b.private.base_bytes,why.." projection state charges")
        eq(a.private.bases,b.private.bases,why.." exact retained projection DTOs")
        eq(a.private.regular,b.private.regular,why.." complete regular wire/entry history")
        eq(a.private.critical,b.private.critical,why.." complete critical wire/entry history")
    end
    local function append(a,b,kind,payload,...)
        local x=table.pack(a.recorder:append(kind,payload,...))
        local y=table.pack(b.recorder:append(kind,payload,...))
        eq(x,y,"public append return arity/value/refusal remains exact")
        return x
    end
    local function terminal(a,b,snapshot,...)
        local x=table.pack(a.recorder:terminal(snapshot,...))
        local y=table.pack(b.recorder:terminal(snapshot,...))
        eq(x,y,"public terminal return arity/value/refusal remains exact")
        return x
    end
    local function drain(a,b)
        for _=1,2200 do
            local x,y=a.recorder:status(),b.recorder:status()
            eq(x,y,"flush progress status remains equal")
            if x.flushed then public_equal(a,b,"drained archive");return end
            eq(table.pack(a.recorder:flush(gate)),table.pack(b.recorder:flush(gate)),
                "ordinary flush return/ABI remains exact")
        end
        error("bounded test trace did not drain")
    end
    local function decoded(writes)
        local chunks={}
        for _,write in ipairs(writes) do
            if type(write.value)=="table" and write.value.schema==2 then chunks[#chunks+1]=write.value end
        end
        if #chunks==0 then return {} end
        local rows,why=Codec.decode_chunks(chunks,"sanitizer_count")
        check(rows~=nil,"full wire trace independently decodes: "..tostring(why))
        return rows
    end
    local function escaped(value)
        local n=2
        for i=1,#value do
            local c=string.byte(value,i)
            n+=(c<32 or c==34 or c==92 or c>=127) and 6 or 1
        end
        return n
    end
    local function lease_state()
        return {call="input.lease_state",arity=1,call_ok=true,sequence="1",user=0,source_epoch="7",context_generation="9",
            status="active",reason="none",terminal=false,requested_ms="1000",expires_ms="2000",observed_ms="1010",last_observation="1010",
            renewals="0",source_released=false,capture_reserved=true,orphaned=false,capturing=false,report_debt=false}
    end
    local function capture_state()
        return {call="input.lease_capture_state",arity=1,call_ok=true,sequence="2",user=0,source_epoch="7",context_generation="9",
            phase="capturing",reason="none",terminal=false,quarantined=false,capturing=true,report_debt=true,
            generation="3",revision="4",expires_ms="2000",publications="1",neutral_releases="0"}
    end
    case("01 empty copied roots and invalid-child empty DTOs charge two",function()
        check(Codec.version==4 and Codec.encoding=="hop-delta-v4","unchanged profile4 reference")
        local out,b,count=probe("ack",{})
        check(next(out)==nil and count==2 and b.bytes==2 and b.nodes==1,"empty root literal cost and legacy spend")
        local a,c=pair()
        check(append(a,c,"ack",{})[1],"empty valid public observation retained")
        check(a.recorder:status().summary.regular_state_bytes==2121,
            "empty ack state is fixed2048 plus DATA2/header64/kind5/projection2")
        public_equal(a,c,"empty ordinary state")
        local invalid,old=probe("ack",{acknowledged="false"})
        check(next(invalid)==nil and old.lost==true,"invalid known child leaves actual empty DTO and loss")
        a,c=pair();check(not append(a,c,"ack",{acknowledged="false"})[1],"invalid field does not become accepted")
        public_equal(a,c,"empty invalid-observation fallback")
    end)
    case("02 finite numbers keep DATA32 and exact signed-zero values",function()
        for _,value in ipairs({0,-1/math.huge,1,-2,.125,1e300,2^-1074}) do
            local out,b,count=probe("body",{time=value})
            check(equal(out.time,value) and count==42 and not b.lost,"time key plus exact DATA32")
        end
        for _,value in ipairs({0/0,math.huge,-math.huge}) do
            local out,b,count=probe("body",{time=value})
            check(out.time==nil and b.lost and count==2,"nonfinite child omitted with original loss")
        end
    end)
    case("03 boolean presence is distinct from false and nil",function()
        for _,value in ipairs({false,true}) do
            local out,b,count=probe("ack",{acknowledged=value})
            check(rawget(out,"acknowledged")==value and count==23 and not b.lost,"present boolean costs five")
        end
        local out,b,count=probe("ack",{acknowledged=nil})
        check(rawget(out,"acknowledged")==nil and count==2 and not b.lost,"absent flag costs no key/value")
        for _,value in ipairs({0,1,"true",{}}) do
            out,b,count=probe("ack",{acknowledged=value})
            check(out.acknowledged==nil and b.lost and count==2,"wrong boolean type remains omitted")
        end
    end)
    case("04 text limits and byte escaping count the retained prefix",function()
        local samples={{"",14},{string.rep("x",192),206},{"A\n\"\\\195\169",45}}
        for _,sample in ipairs(samples) do
            local out,b,count=probe("prepare",{reason=sample[1]})
            check(out.reason==sample[1] and count==sample[2] and not b.lost,"independent retained text literal cost")
        end
        local out,b,count=probe("prepare",{reason=string.rep("x",193)})
        check(out.reason==string.rep("x",192) and b.lost and count==206,"193-byte input retains exact192-byte prefix")
        local text=string.rep("x",191).."\195\169"
        out,b=probe("prepare",{reason=text})
        check(#out.reason==192 and out.reason==string.sub(text,1,192) and b.lost,"legacy byte truncation is unchanged")
    end)
    case("05 legacy decimal IDs are not newly strengthened or coerced",function()
        for _,value in ipairs({"0","0001","18446744073709551615","99999999999999999999"}) do
            local out,b,count=probe("body",{serial=value})
            check(out.serial==value and not b.lost and count==#value+14,"legacy exact1..20 decimal bytes retained")
        end
        for _,value in ipairs({"","-1","1.0","1e1","a",string.rep("1",21),1}) do
            local out,b,count=probe("body",{serial=value})
            check(out.serial==nil and b.lost and count==2,"legacy malformed ID remains omitted")
        end
    end)
    case("06 vec3 numeric named and mixed components keep precedence",function()
        local zero=-1/math.huge
        local inputs={{1,2,3},{x=1,y=2,z=3},{[1]=zero,[3]=3,x=99,y=2,z=98}}
        for i,input in ipairs(inputs) do
            local out,b,count=probe("body",{position=input})
            check(count==127 and not b.lost,"position root/key plus barevec113")
            check(Codec.data_bytes(out.position)==113,"independent bare vec3 literal cost")
            if i==3 then check(1/out.position[1]==-math.huge and out.position[2]==2 and out.position[3]==3,"numeric zero beats named fallback") end
            check(not table.isfrozen(input),"observation never freezes caller vector table")
        end
    end)
    case("07 vec4 and native vec3 preserve the existing shape rule",function()
        local out,b,count=probe("body",{rotation={0,0,0,1}})
        check(count==164 and Codec.data_bytes(out.rotation)==150 and not b.lost,"barevec4 literal150")
        out,b,count=probe("body",{position=vector.create(1,2,3)})
        check(count==127 and out.position[3]==3 and not b.lost,"native vector is copied as ordinary vec3")
        out,b,count=probe("body",{rotation=vector.create(1,2,3)})
        check(out.rotation==nil and count==2 and b.lost,"native three-vector is not accepted as vec4")
        out,b=probe("body",{rotation={x=0,y=0,z=0,w=1}})
        check(out.rotation==nil and b.lost,"vec4 gains no named-component fallback")
    end)
    case("08 failed vectors discard every attempted component from canonical DATA",function()
        for component=1,3 do
            for _,bad in ipairs({false,0/0,math.huge,"1"}) do
                local input={1,2,3};input[component]=bad
                local out,b,count=probe("body",{position=input})
                check(out.position==nil and count==2 and b.lost,"invalid vector discards complete parent field")
            end
            local input={1,2,3};input[component]=nil
            local out,b,count=probe("body",{position=input})
            check(out.position==nil and count==2 and b.lost,"missing vector component discards complete vector")
        end
        for _,limit in ipairs({16,48,49,81,82,114}) do
            local out,b,count=probe("body",{position={1,2,3}},limit)
            check(out.position==nil and count==2 and b.lost and b.full,"component spend failure retains only root")
        end
    end)
    case("09 omitted empty and partial named children use only actual output",function()
        local out,b,count=probe("contact",{support=false})
        check(out.support==nil and count==2 and b.lost,"attempted key with invalid child contributes nothing")
        out,b,count=probe("contact",{support={}})
        check(next(out.support)==nil and count==15 and not b.lost,"emitted empty support table contributes two")
        out,b,count=probe("contact",{query={status=false}})
        check(next(out.query)==nil and count==13 and b.lost,"nested invalid field leaves actual empty query")
        out,b=probe("contact",{support={known=true,grounded=false,reason="retained",normal={1,2,3}}},35)
        check(b.lost and b.full and type(out.support)=="table","partial nested object remains the legacy returned table")
    end)
    case("10 body position literal separates legacy115 from canonical127",function()
        local out,b,count=probe("body",{position={1,2,3}})
        check(b.bytes==115 and count==127 and out.position[2]==2,"independent legacy/canonical complete literals")
        out,b,count=probe("body",{position={1,2,3}},114)
        check(b.bytes==115 and b.full and b.lost and out.position==nil and count==2,"114 limit loses entire attempted vector")
        out,b,count=probe("body",{position={1,2,3}},115)
        check(b.bytes==115 and not b.full and not b.lost and count==127,"exact115 legacy threshold accepts unchanged DTO")
    end)
    case("11 empty and singleton lists retain canonical numeric-key costs",function()
        local out,b,count=probe("follow",{pending={}})
        check(count==15 and #out.pending==0 and not b.lost,"empty pending table literal")
        out,b,count=probe("follow",{pending={"x"}})
        check(count==23 and b.bytes==19 and out.pending[1]=="x" and not b.lost,"list key is digits1 plus four, not separator1")
        out,b,count=probe("contact",{rays={}})
        check(count==12 and #out.rays==0 and not b.lost,"empty rays table literal")
    end)
    case("12 list indices9 10 and32 use decimal digit lengths",function()
        for _,sample in ipairs({{9,75},{10,83},{32,259},{33,259}}) do
            local rays={};for i=1,sample[1] do rays[i]={} end
            local out,b,count=probe("contact",{rays=rays})
            check(count==sample[2] and #out.rays==math.min(sample[1],32),"independent rays canonical literal")
            check((b.lost==true)==(sample[1]>32),"list limit33 truncates through original loss flag")
            check(out.rays[10]==nil or type(next(out.rays,9))=="number","retained numeric keys remain numeric")
        end
    end)
    case("13 sparse inputs keep the legacy selected length and ignore foreign keys",function()
        local samples={
            {[1]={},[3]={},[20]={},foreign={}},
            {[2]={},[10]={}},
            {["1"]={},foreign={}},
            {[1]={},[2]={},[32]={},[-1]={}},
        }
        for _,rays in ipairs(samples) do
            local payload={rays=rays}
            local out=probe("contact",payload)
            check(out.rays.foreign==nil and out.rays["1"]==nil and out.rays[-1]==nil,"only selected dense output keys survive")
            for k in pairs(out.rays) do check(type(k)=="number" and k>=1 and k<=#out.rays and k%1==0,"no sparse input key is copied wholesale") end
            check(not table.isfrozen(payload) and not table.isfrozen(rays),"sparse caller objects remain mutable")
        end
    end)
    case("14 list failure preserves append-before-spend and nested partial items",function()
        local out,b,count=probe("contact",{rays={{},false,{}}})
        check(#out.rays==1 and count==19 and b.lost,"invalid item stops before append and later items stay absent")
        out,b,count=probe("follow",{pending={"x"}},18)
        check(out.pending[1]=="x" and b.bytes==19 and b.full and b.lost and count==23,
            "successful item survives its failing trailing spend: legacy19 versus canonical23")
        out,b=probe("contact",{rays={{position={1,2,3},fraction=.5}}},28)
        check(#out.rays==1 and type(out.rays[1])=="table" and b.full and b.lost,"nested partial item is still appended")
    end)
    case("15 aliases are copied per occurrence without freezing caller references",function()
        local shared={1,2,3}
        local payload={position=shared,velocity=shared}
        local out,b,count=probe("body",payload)
        check(count==252 and not b.lost,"two vector occurrences each contribute113")
        check(out.position~=out.velocity and equal(out.position,out.velocity),"shared input produces distinct owned copies")
        check(not table.isfrozen(payload) and not table.isfrozen(shared),"shared caller graph remains mutable")
        shared[1]=99
        check(out.position[1]==1 and out.velocity[1]==1,"caller alias mutation cannot rewrite either occurrence")
        local distinct=probe("body",{position={1,2,3},velocity={1,2,3}})
        eq(out,distinct,"equal distinct inputs retain identical values")
    end)
    case("16 unknown and known cycles preserve finite schema-directed behavior",function()
        local payload={acknowledged=false};payload.foreign=payload
        local out,b,count=probe("ack",payload)
        check(out.acknowledged==false and out.foreign==nil and count==23 and not b.lost,"unknown cyclic input is never traversed")
        local scalar={};scalar.time=scalar
        out,b,count=probe("body",scalar)
        check(out.time==nil and b.lost and count==2,"known scalar cycle is original type failure")
        local vectorCycle={};vectorCycle[1]=vectorCycle;vectorCycle[2]=2;vectorCycle[3]=3
        out,b,count=probe("body",{position=vectorCycle})
        check(out.position==nil and b.lost and count==2,"known vector cycle remains original invalid component")
        local listCycle={};listCycle[1]=listCycle
        out,b=probe("contact",{rays=listCycle})
        check(#out.rays==1 and next(out.rays[1])==nil and not b.lost,"finite ray schema ignores its unrelated numeric cycle")
        check(payload.foreign==payload and scalar.time==scalar and vectorCycle[1]==vectorCycle,"cyclic caller graph is unchanged")
    end)
    case("17 legacy byte and768-node cutoffs retain exact partial-copy budgets",function()
        for _,limit in ipairs({0,1,2,3,13,14,15,18,19,114,115,116}) do
            probe("body",{position={1,2,3}},limit)
            probe("follow",{pending={"x"}},limit)
        end
        local rays={}
        for i=1,32 do rays[i]={status="hit",motion="measured",fraction=.5,visual_hit=true,
            normal_available=true,surface_velocity_available=true,position={1,2,3},normal={0,1,0},surface_velocity={0,0,0}} end
        local _,b=probe("contact",{rays=rays},100000)
        check(b.nodes>768 and b.full and b.lost,"existing node spend cutoff is still independently active")
        check(not pcall(Baseline.probe,"not_an_event",{}),"baseline test probe rejects unknown schema")
        check(not pcall(Candidate.probe,"not_an_event",{}),"candidate test probe rejects unknown schema")
    end)
    case("18 Codec still rejects canonical overflow after sanitizer-valid copying",function()
        local bytesRays={};for i=1,32 do bytesRays[i]={status=string.rep("a",172),motion=string.rep("b",172)} end
        local nodeRays={};for i=1,30 do nodeRays[i]={position={1,2,3},normal={0,1,0},surface_velocity={0,0,0}} end
        for index,payload in ipairs({{rays=bytesRays},{rays=nodeRays}}) do
            local _,b,_,expected,why=probe("contact",payload)
            check(not b.full and not b.lost and expected==nil,"legacy-valid copied DTO remains independently Codec-invalid")
            if index==1 then check(b.bytes==11884 and string.find(why,"expanded data byte limit",1,true)~=nil,"independent byte-overflow construction") end
            if index==2 then check(b.bytes==10452 and string.find(why,"expanded node limit",1,true)~=nil,"independent node-overflow construction") end
            local a,c=pair();local result=append(a,c,"contact",payload)
            check(result[1]==false and result[2]=="invalid_encoding","full Codec refusal occurs before count range admission")
            check(a.recorder:status().regular_rows==0 and a.recorder:status().dropped==1,"no row is admitted by a cheap internal count")
            public_equal(a,c,"canonical overflow refusal")
        end
    end)
    case("19 public append extra arguments and forged count fields are ignored",function()
        for _,fake in ipairs({0,-1,1e300,0/0,"2",{},false}) do
            local a,c=pair()
            local payload={acknowledged=false,canonical_count=fake,count=fake,C=fake,data_bytes=fake}
            check(append(a,c,"ack",payload,fake,{trusted=true,count=fake})[1],"extra append arguments cannot change ordinary acceptance")
            local plainA,plainC=pair();append(plainA,plainC,"ack",{acknowledged=false})
            eq(a.recorder:status(),plainA.recorder:status(),"baseline ignores forged count fields/extra arguments")
            eq(c.recorder:status(),plainC.recorder:status(),"candidate ignores forged count fields/extra arguments")
            public_equal(a,c,"public count provenance")
        end
        for _,factory in ipairs({Baseline,Candidate}) do
            local f=fresh(factory)
            check(table.isfrozen(factory.Recorder) and factory.Recorder.probe==nil and factory.Recorder.state==nil,
                "production Recorder exports no probe or private state helper")
            check(f.recorder.probe==nil and f.recorder.state==nil and f.recorder.append_trusted==nil and f.recorder.set_count==nil,
                "no production count receiver or trusted append entry point")
        end
    end)
    case("20 terminal count belongs to emitted scalar transition not whole snapshot",function()
        local a,c=pair()
        local snapshot=closed(false);snapshot.phase="following";snapshot.stop_latched=false
        snapshot.ride.submitted=42;snapshot.ride.acknowledged=41;snapshot.mount_deadline_ms=1500.5
        snapshot.wall_ms=-1/math.huge
        terminal(a,c,snapshot,0,{trusted_count=2})
        public_equal(a,c,"ordinary terminal transition")
        local row=a.private.bases["terminal|"]
        check(row~=nil and row.data.ride==nil and row.data.wall_ms==nil and row.data.mount_deadline_ms==nil,
            "nested numeric observations stay in latest, not the emitted scalar transition")
        local actual=Codec.data_bytes(row.data)
        check(a.recorder:status().summary.regular_state_bytes==2048+actual+64+escaped("terminal")+escaped(""),
            "ordinary terminal state uses independent count of actual transition only")
        check(a.recorder:status().latest.ride.submitted==42 and a.recorder:status().latest.ride.acknowledged==41,
            "numeric ACK totals are retained in the larger actual snapshot")
        snapshot=copy(snapshot);snapshot.ride.submitted=100;snapshot.ride.acknowledged=99;snapshot.wall_ms=200
        terminal(a,c,snapshot,0/0,"fake_count")
        public_equal(a,c,"changed latest numeric snapshot")
        check(a.recorder:status().regular_rows==1 and a.recorder:status().latest.ride.acknowledged==99,
            "unchanged scalar transition is not replaced by a larger snapshot count")
    end)
    case("21 ordinary full delta critical coalesced and sealed-pair traces stay exact",function()
        local a,c=pair()
        append(a,c,"body",{serial="1",position={1,2,3},velocity={0,0,0},at_ms=-1/math.huge})
        append(a,c,"body",{serial="2",position={1,2,3},velocity={0,0,0},at_ms=16})
        append(a,c,"follow",{call="world.physics.follow",sequence="9",phase="following",at_ms=17})
        append(a,c,"follow",{call="world.physics.follow",sequence="9",phase="following",at_ms=18})
        local la=lease_state();la.at_ms=19;append(a,c,"lease",la)
        local lb=capture_state();lb.at_ms=20;append(a,c,"lease",lb)
        la=lease_state();la.at_ms=21;append(a,c,"lease",la)
        lb=capture_state();lb.at_ms=22;append(a,c,"lease",lb)
        la=lease_state();la.at_ms=23;append(a,c,"lease",la)
        append(a,c,"receipt",{sequence="40",requested_serial="39",produced_serial="40",outcome="applied",quarantined=true,at_ms=24})
        public_equal(a,c,"all public retention branches")
        terminal(a,c,closed(false));drain(a,c)
        local rows=decoded(a.writes);eq(rows,decoded(c.writes),"all twelve wire slots reconstruct exactly")
        local full,delta,legacy,pairsSeen,critical=false,false,false,0,false
        for _,write in ipairs(a.writes) do if write.value.schema==2 then for _,wire in ipairs(write.value.rows) do
            check(#wire==12,"profile4 positional row shape unchanged")
            full=full or wire[4]==0;delta=delta or wire[4]~=0
            if wire[12] then pairsSeen+=1 end
            if wire[1] then check(wire[4]==0,"critical cleanup remains self-contained");critical=true end
        end end end
        for _,row in ipairs(rows) do
            if row.kind=="follow" then legacy=row.repeats==2 end
            if row.kind=="lease" and row.paired then check(row.repeats==2 and row.first_call<row.last_call,"new pairs remain exact two endpoints") end
        end
        check(full and delta and legacy and pairsSeen==2 and critical,"full/delta/legacy/pair/critical coverage is actual")
        check(1/rows[1].first_at_ms==-math.huge,"wire roundtrip retains source timestamp negative zero")
    end)
    case("22 first regular capacity refusal preserves prior rows bases and charges atomically",function()
        local a,c=pair();local refused=false
        for i=1,2049 do
            local payload={serial=tostring(i),time=i/60,seconds=1/60,mass=100+i,
                position={i,i+1,i+2},velocity={i+.1,i+.2,i+.3},
                angular_velocity={i+.4,i+.5,i+.6},inertia={i+.7,i+.8,i+.9},rotation={i/10000,.1,.2,1},at_ms=i}
            local data=Baseline.probe("body",payload)
            local state=a.private;local key="body|";local base=state.bases[key]
            local logical={kind="body",data=data,first_call=state.calls+1,last_call=state.calls+1,repeats=1,
                first_at_ms=i,last_at_ms=i,incomplete=false,critical=false}
            local wire,bytes=Codec.encode_row(logical,base)
            check(wire~=nil,"capacity fixture remains independently Codec-valid")
            local canonical=Codec.data_bytes(data)
            local nextState=canonical+64+escaped("body")+escaped("")
            local projected=state.regular_bytes+bytes+nextState-(state.base_bytes[key] or 0)
            local expected=#state.regular<2048 and projected<=512*1024
            local oldRows=#state.regular;local oldBase=base;local oldCharge=state.regular_bytes
            local oldWire=oldRows>0 and state.regular[oldRows].wire or nil
            local result=append(a,c,"body",payload)
            check(result[1]==expected,"first public capacity decision matches independent wire plus DATA state arithmetic")
            if expected then
                check(a.private.regular_bytes==projected,"successful admission charges exact independent state replacement")
            else
                refused=true
                check(result[2]=="regular_capacity" and projected>512*1024,"concrete byte boundary is reached before row2048")
                check(#a.private.regular==oldRows and a.private.bases[key]==oldBase and a.private.regular_bytes==oldCharge,
                    "refused row mutates no entries/base/byte admission state")
                check(oldRows==0 or a.private.regular[oldRows].wire==oldWire,"prior frozen wire reference remains unchanged")
                check(a.recorder:status().dropped==1 and a.recorder:status().observation_loss,"capacity failure is sticky and explicit")
                public_equal(a,c,"first capacity refusal")
                break
            end
        end
        check(refused,"bounded fixture actually reaches the unchanged regular byte cap")
    end)
    case("23 ordinary writer ABI failures reentry and frozen history remain baseline-exact",function()
        for _,mode in ipairs({"zero","throw","true","false","nil","number","string"}) do
            local a,c=pair()
            append(a,c,"ack",{acknowledged=true,sequence="7"})
            terminal(a,c,closed(false));a.mode=mode;c.mode=mode
            local x=table.pack(a.recorder:flush(gate));local y=table.pack(c.recorder:flush(gate));eq(x,y,"writer return ABI outcome unchanged")
            public_equal(a,c,"writer mode "..mode)
            if mode=="zero" then drain(a,c);check(a.recorder:status().flushed,"zero-return ABI drains normally")
            else check(a.recorder:status().storage_fault and not a.recorder:status().flushed,"nonzero/throw remains a storage fault") end
        end
        local a,c=pair()
        local function during(f,recorder,_,value)
            if value.rows and not f.changed then
                f.changed=true
                check(not pcall(function() value.rows[1][6]=999 end),"writer cannot edit frozen occurrence metadata")
                check(not pcall(function() value.rows[1][11][1]=99 end),"writer cannot edit frozen data node")
                recorder:append("ack",{sequence="88",acknowledged=true})
            end
        end
        a.during=function(...) during(a,...) end;c.during=function(...) during(c,...) end
        append(a,c,"ack",{sequence="7",acknowledged=true});terminal(a,c,closed(false))
        drain(a,c)
        check(a.changed and c.changed,"both real writer paths actually exercised reentrant retention")
    end)
    case("24 pure end-to-end archive and clean-unload tail retain all lifecycle guards",function()
        local a,c=pair()
        for i=1,20 do
            append(a,c,"source",{call="input.lease_read",sequence="1",source_epoch="2",context_generation="3",
                observation_serial=tostring(i),observed_ms=tostring(16*i),packet=i,
                pad={left_x=-1/math.huge,right_y=0,playstation=false,buttons={a=false}},at_ms=16*i})
        end
        terminal(a,c,closed(false));drain(a,c)
        local before=#a.writes;local rows=a.recorder:status().stored_rows;local chunks=a.recorder:status().chunks
        check(a.recorder:begin_unload() and c.recorder:begin_unload(),"private unload scope is present on final clean baseline")
        eq(table.pack(a.recorder:finish_unload(closed(true),gate)),table.pack(c.recorder:finish_unload(closed(true),gate)),
            "clean final summary outcome remains exact")
        public_equal(a,c,"clean unload finalization")
        check(#a.writes==before+1 and a.writes[#a.writes].key=="hop.sanitizer_count.summary",
            "one summary replacement and no new chunk/incomplete write")
        local status=a.recorder:status()
        check(status.flushed and not status.observation_loss and not status.interrupted and status.latest.unloaded,
            "actual constructed unloaded snapshot remains clean and complete")
        check(status.stored_rows==rows and status.chunks==chunks,"clean finalizer preserves original archive counts")
        local repeatSnapshot=closed(true);repeatSnapshot.wall_ms=200
        eq(table.pack(a.recorder:finish_unload(repeatSnapshot,gate)),table.pack(c.recorder:finish_unload(repeatSnapshot,gate)),
            "wall-only repeat has the same read-only result")
        check(#a.writes==before+1 and #c.writes==before+1,"unchanged repeated unload spends no second writer")
        append(a,c,"ack",{sequence="99",acknowledged=true,at_ms=400},2)
        eq(table.pack(a.recorder:finish_unload(repeatSnapshot,gate)),table.pack(c.recorder:finish_unload(repeatSnapshot,gate)),
            "real late observation cannot reuse earlier success")
        public_equal(a,c,"late post-finalization observation")
        status=a.recorder:status()
        check(status.observation_loss and status.interrupted and status.stop_requested and not status.flushed,
            "new semantic tail revokes current completion without discarding evidence")
        check(#a.writes==before+1 and #c.writes==before+1,"spent shared claim forbids a later writer")
        eq(decoded(a.writes),decoded(c.writes),"complete persisted prefix remains independently decodable")
    end)
    check(cases==24,"exactly24 authored pure groups ran")
    return {cases=cases,assertions=assertions}
end
return table.freeze(Tests)

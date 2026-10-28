-- TEST ONLY. Uses an exact one-return Recorder factory and exact private Main
-- lexical fixture; no factory/proxy belongs in runtime or a Stage graph.
local Factory=require("./hop_recorder_private_test_factory")
local Recorder=Factory.Recorder
local Context=require("./hop_context")
local Entry=require("./hop_main_unload_fixture")
local P0Context=require("./hop_context_p0")
local P0Entry=require("./hop_main_unload_p0_fixture")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn) cases+=1;local ok,why=pcall(fn);assert(ok,name..": "..tostring(why)) end
    local function copy(v)
        if type(v)~="table" then return v end
        local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out
    end
    local function closed(unloaded)
        return {phase="done",detail="actual constructed completion",stop_latched=true,unloaded=unloaded==true,
            stop_reason="fixture stopped",wall_ms=100,bike_cleanup_complete=true,bike_authority=false,
            cleanup_pending=false,cleanup_unknown=false,force_cleanup_clear=true,force_cleanup_unknown=false,
            ride={phase="off",force_pending=false,unknown=false,pending_count=0,submitted=1,acknowledged=1},
            source={phase="complete",cleanup_pending=false,cleanup_unknown=false,lease_handle_present=false,
                capture_state={report_debt=false,quarantined=false}},
            equipment={phase="idle",retained=false,unknown=false,unloaded=false},
            board_drop={state="restored",restore_pending=false,drop_inflight=false,restore_inflight=false},
            mounted_pose={sends=1,stopped=true,nil_calls=1,nil_accepted=true}}
    end
    local gate=table.freeze({inactive=true,terminal=true})
    local function fresh()
        local f={calls={},mode=nil};local recorder
        recorder=Recorder.new(function(key,value)
            f.calls[#f.calls+1]={key=key,value=value}
            if f.during then f.during(recorder,key,value) end
            if f.mode=="throw" then error("constructed SDK storage quota refusal",0) end
            if f.mode=="true" then return true end
            if f.mode=="false" then return false end
            if f.mode=="nil" then return nil end
            if f.mode=="number" then return 0 end
            if f.mode=="string" then return "unexpected" end
        end,"unload_contract")
        f.recorder=recorder;f.private=Factory.state(recorder)
        return f
    end
    local function drain(f)
        for _=1,8 do
            if f.recorder:status().flushed then return end
            check(f.recorder:flush(gate),"ordinary baseline flush accepted")
        end
        error("small baseline did not flush")
    end
    local function ready()
        local f=fresh();f.snapshot=closed(false)
        check(f.recorder:terminal(f.snapshot),"clean actual pre-unload snapshot accepted");drain(f)
        f.baseline=#f.calls;f.saved=f.private.saved_revision;f.ri=f.private.regular_next;f.ci=f.private.critical_next
        f.rows=f.recorder:status().stored_rows;f.chunks=f.recorder:status().chunks
        return f
    end
    local function final(f,snapshot,witness)
        f.recorder:begin_unload()
        return f.recorder:finish_unload(snapshot or closed(true),witness or gate)
    end
    local function failed(f,why,storage)
        local s=f.recorder:status()
        check(s.interrupted and s.observation_loss and s.stop_requested and s.unqualified and not s.flushed,why.." is sticky/unqualified")
        check(s.storage_fault==storage,why.." exact storage classification")
        check(f.private.saved_revision==f.saved and f.private.regular_next==f.ri and f.private.critical_next==f.ci,
            why.." advances no saved revision or row cursor")
        check(s.stored_rows==f.rows and s.chunks==f.chunks,why.." advances no chunk/count")
    end
    local function no_more(f,snapshot)
        local n=#f.calls
        check(not f.recorder:finish_unload(snapshot or closed(true),gate),"failed finish never promotes later success")
        check(not f.recorder:interrupt(snapshot or closed(true)),"interrupt cannot spend another writer")
        check(not f.recorder:flush(gate),"ordinary flush cannot spend another writer")
        check(#f.calls==n,"shared writer budget is lifetime-wide")
    end
    case("construction and unload scope are pure",function()
        local f=fresh();check(#f.calls==0,"construction is inert")
        check(f.recorder:begin_unload() and f.recorder:begin_unload(),"pure scope is idempotent")
        check(#f.calls==0 and not f.recorder:flush(gate),"scope writes nothing and blocks ordinary chunks")
    end)
    case("actual unloaded change replaces only a fully drained final summary",function()
        local f=ready();f.recorder:begin_unload();local snapshot=closed(true)
        check(f.recorder:terminal(snapshot),"actual unloaded observation retained")
        check(not f.recorder:status().flushed and f.recorder:status().latest.unloaded,"unloaded dirties old summary rather than disappearing")
        check(f.recorder:finish_unload(snapshot,gate),"clean final summary accepted")
        local s=f.recorder:status();local write=f.calls[#f.calls]
        check(#f.calls==f.baseline+1 and write.key=="hop.unload_contract.summary","one final summary, no chunk/incomplete write")
        check(write.value.latest.unloaded==true and not write.value.interrupted and not write.value.observation_loss,"final copied status remains actual")
        check(s.flushed and not s.unqualified and not s.storage_fault and not s.interrupted,"original complete formula holds")
        check(f.private.regular_next==f.ri and f.private.critical_next==f.ci and s.stored_rows==f.rows and s.chunks==f.chunks,
            "clean finalizer advances only saved summary revision")
    end)
    case("unchanged repeats and wall-only facts add no writer",function()
        local f=ready();check(final(f),"initial clean finalization")
        local n=#f.calls;local saved=f.private.saved_revision;local snapshot=closed(true);snapshot.wall_ms=200
        check(f.recorder:finish_unload(snapshot,gate),"wall-only repeat remains complete")
        check(not f.recorder:interrupt(snapshot) and not f.recorder:flush(gate),"other methods cannot write again")
        check(#f.calls==n and f.private.saved_revision==saved and f.recorder:status().flushed,"wall-only latest update is not semantic dirt")
        check(f.recorder:status().latest.wall_ms==200,"latest actual wall observation preserved")
    end)
    case("invalid repeated caller witness cannot invent a second write or erase known clean facts",function()
        local f=ready();check(final(f),"initial clean finalization");local n=#f.calls
        check(not f.recorder:finish_unload(closed(true),{inactive=false,terminal=true}),"repeat still requires caller witness")
        check(f.recorder:status().flushed and not f.recorder:status().unqualified and #f.calls==n,"bad repeat query does not fabricate a changed observation")
    end)
    case("an unsaved real observation tail keeps existing incomplete contract",function()
        local f=ready();f.recorder:begin_unload();check(f.recorder:append("ack",{acknowledged=true,sequence="2"}),"real tail retained")
        check(f.recorder:finish_unload(closed(true),gate),"one incomplete cache attempt accepted")
        failed(f,"pending tail",false)
        check(#f.calls==f.baseline+1 and f.calls[#f.calls].key=="hop.unload_contract.incomplete","no chunk drain or summary promotion")
        check(f.calls[#f.calls].value.complete==false and f.calls[#f.calls].value.latest.unloaded,"actual unloaded status in incomplete record")
        check(f.recorder:status().summary.critical_rows+f.recorder:status().summary.regular_rows>f.rows,"unsaved row was not discarded")
        no_more(f)
    end)
    case("every actual debt category refuses clean promotion",function()
        local changes={
            function(s)s.bike_authority=true end,function(s)s.cleanup_pending=true end,function(s)s.cleanup_unknown=true end,
            function(s)s.ride.force_pending=true end,function(s)s.ride.unknown=true end,function(s)s.ride.pending_count=1 end,
            function(s)s.source.cleanup_pending=true end,function(s)s.source.cleanup_unknown=true end,
            function(s)s.source.lease_handle_present=true end,function(s)s.source.capture_state.report_debt=true end,
            function(s)s.source.capture_state.quarantined=true end,function(s)s.equipment.retained=true end,
            function(s)s.equipment.unknown=true end,function(s)s.board_drop.state="restore_unknown" end,
            function(s)s.board_drop.restore_pending=true end,function(s)s.mounted_pose.nil_accepted=false end,
            function(s)s.phase="retained_unknown" end,function(s)s.stop_latched=false end,
            function(s)s.bike_cleanup_complete=false end,function(s)s.unloaded=false end}
        for i,change in ipairs(changes) do
            local f=ready();local snapshot=closed(true);change(snapshot)
            check(final(f,snapshot),"one incomplete debt record "..tostring(i));failed(f,"debt category "..tostring(i),false)
            check(f.calls[#f.calls].key=="hop.unload_contract.incomplete","no debt category uses clean summary")
        end
    end)
    case("historical unknown remains visible after current cleanup clears",function()
        local f=fresh();local unknown=closed(false);unknown.cleanup_unknown=true
        f.recorder:terminal(unknown);f.recorder:terminal(closed(false));drain(f)
        f.baseline=#f.calls;f.saved=f.private.saved_revision;f.ri=f.private.regular_next;f.ci=f.private.critical_next
        f.rows=f.recorder:status().stored_rows;f.chunks=f.recorder:status().chunks
        check(final(f),"historical unknown incomplete cache accepted");failed(f,"historical unknown",false)
        check(f.calls[#f.calls].value.cleanup_unknown_seen,"historical unknown never erased")
    end)
    case("prior observation loss remains first fault",function()
        local f=ready();check(not f.recorder:append("invalid",{}),"actual invalid event refused")
        local first=f.recorder:status().first_fault
        check(final(f),"failed history gets one incomplete attempt");failed(f,"prior loss",false)
        check(f.recorder:status().first_fault==first,"first fault survives finalization")
    end)
    case("prior storage failure remains failed and is not retried by clean path",function()
        local f=fresh();f.snapshot=closed(false);f.recorder:terminal(f.snapshot);f.mode="throw"
        check(not f.recorder:flush(gate),"constructed real writer failure")
        f.saved=f.private.saved_revision;f.ri=f.private.regular_next;f.ci=f.private.critical_next
        f.rows=f.recorder:status().stored_rows;f.chunks=f.recorder:status().chunks;f.baseline=#f.calls
        f.mode=nil;check(final(f),"existing incomplete path may make its one distinct attempt")
        failed(f,"prior storage failure",true);no_more(f)
    end)
    case("missing and malformed final observations remain explicit",function()
        for _,mode in ipairs({"missing","malformed"}) do
            local f=ready();f.recorder:begin_unload()
            local snapshot;if mode=="malformed" then snapshot={phase={},unloaded=true} end
            check(f.recorder:finish_unload(snapshot,gate),"one incomplete attempt "..mode);failed(f,mode,false)
            check(f.calls[#f.calls].key=="hop.unload_contract.incomplete","no final observation was invented")
            if mode=="missing" then check(f.recorder:status().summary.final_snapshot_unavailable,"missing final observation explicit") end
        end
    end)
    case("no caller terminal witness refuses a clean-only opportunity",function()
        local f=ready();check(f.recorder:finish_unload(closed(true),{inactive=true,terminal=false}),"existing incomplete attempt")
        failed(f,"no caller witness",false)
    end)
    case("explicit interrupt and clean finish share one writer",function()
        local f=ready();check(f.recorder:interrupt(closed(true)),"explicit incomplete attempt accepted")
        failed(f,"explicit interrupt",false);no_more(f)
        check(#f.calls==f.baseline+1,"not one attempt per public method")
    end)
    case("scope begun inside an existing normal writer spends the same budget",function()
        local f=fresh();f.recorder:terminal(closed(false));f.saved=f.private.saved_revision
        f.ri=f.private.regular_next;f.ci=f.private.critical_next;f.rows=0;f.chunks=0
        f.during=function(rec)
            check(rec:begin_unload(),"pure scope observes in-flight writer")
            check(not rec:interrupt(closed(true)),"cannot nest emergency writer")
            check(not rec:finish_unload(closed(true),gate),"cannot nest clean writer")
        end
        check(not f.recorder:flush(gate),"normal writer cannot commit after unload began")
        f.during=nil;failed(f,"in-flight writer",false);no_more(f)
        check(#f.calls==1,"only already-entered writer ran")
    end)
    case("unchanged nested finalizer calls cannot add I/O",function()
        for _,method in ipairs({"finish","interrupt","flush"}) do
            local f=ready()
            f.during=function(rec)
                if method=="finish" then check(not rec:finish_unload(closed(true),gate),"nested finish refused")
                elseif method=="interrupt" then check(not rec:interrupt(closed(true)),"nested interrupt refused")
                else check(not rec:flush(gate),"nested flush refused") end
            end
            check(final(f),"same facts need no invented loss for "..method)
            check(#f.calls==f.baseline+1 and f.recorder:status().flushed,"exactly one successful writer")
        end
    end)
    case("semantic writer reentry never advances the final revision",function()
        for _,kind in ipairs({"row","terminal","fault"}) do
            local f=ready()
            f.during=function(rec)
                if kind=="row" then check(rec:append("ack",{sequence="7",acknowledged=true}),"reentrant actual row retained")
                elseif kind=="terminal" then local s=closed(true);s.detail="new actual detail";rec:terminal(s)
                else check(not rec:append("invalid",{}),"invalid reentrant observation fails closed") end
            end
            check(not final(f),"successful ABI with changed "..kind.." cannot finalize")
            f.during=nil;failed(f,"semantic reentry "..kind,false);no_more(f)
            check(#f.calls==f.baseline+1,"no second fallback write")
        end
    end)
    case("all unexpected storage ABI returns and quota throws are failures",function()
        for _,mode in ipairs({"throw","true","false","nil","number","string"}) do
            local f=ready();f.mode=mode
            check(not final(f),"bad storage ABI "..mode.." refused")
            failed(f,"storage failure "..mode,true)
            check(type(f.recorder:status().summary.storage_error)=="string" and #f.recorder:status().summary.storage_error<=192,"bounded precise storage error")
            f.mode=nil;no_more(f);check(#f.calls==f.baseline+1,"failed call consumes sole unload budget")
        end
    end)
    case("failed incomplete write cannot retry across other entry points",function()
        local f=ready();f.mode="throw";check(not f.recorder:interrupt(closed(true)),"incomplete writer failed")
        failed(f,"incomplete writer failure",true);f.mode=nil;no_more(f)
        check(#f.calls==f.baseline+1,"no second emergency/clean call")
    end)
    case("later actual row after a former success invalidates every stale certificate",function()
        local f=ready();check(final(f),"first finalization")
        f.saved=f.private.saved_revision;f.ri=f.private.regular_next;f.ci=f.private.critical_next
        check(f.recorder:append("ack",{sequence="8",acknowledged=true}),"late real observation is still retained")
        failed(f,"late real row",false);no_more(f)
        check(#f.calls==f.baseline+1,"spent writer cannot repair the later tail")
    end)
    case("later actual terminal semantics invalidate former success but wall does not",function()
        local f=ready();check(final(f),"first finalization");f.saved=f.private.saved_revision
        local wall=closed(true);wall.wall_ms=200;f.recorder:terminal(wall)
        check(f.recorder:status().flushed,"wall-only update remains original non-dirty behavior")
        wall.detail="later actual state";f.recorder:terminal(wall)
        failed(f,"late semantic snapshot",false);no_more(f,wall)
        check(f.recorder:status().latest.detail==wall.detail,"actual later semantic observation retained")
    end)
    case("opaque fields are never copied and invalid summary text does not qualify",function()
        local f=ready();local snapshot=closed(true);snapshot.opaque=newproxy()
        check(final(f,snapshot),"unlisted opaque field remains ignored")
        check(f.calls[#f.calls].value.latest.opaque==nil,"no capability enters summary")
        local bad=ready();local large=closed(true);large.detail=string.rep("x",193)
        check(final(bad,large),"invalid bounded observation gets incomplete record")
        failed(bad,"oversized named text",false)
        check(#bad.recorder:status().latest.detail<=192,"named text cap unchanged")
    end)
    case("large escaped clean snapshot uses the original bounded summary schema",function()
        local f=ready();local snapshot=closed(true);local text=string.rep("\n",192)
        snapshot.detail=text;snapshot.stop_reason=text;snapshot.source.reason=text
        snapshot.equipment.detail=text;snapshot.mounted_pose.reason=text;snapshot.board_drop.reason=text
        -- The changed stop_reason creates a real terminal row, so first admit
        -- and flush this pre-unload semantic observation using ordinary ticks.
        local pre=copy(snapshot);pre.unloaded=false;f.recorder:terminal(pre);drain(f)
        f.baseline=#f.calls;f.saved=f.private.saved_revision;f.ri=f.private.regular_next;f.ci=f.private.critical_next
        f.rows=f.recorder:status().stored_rows;f.chunks=f.recorder:status().chunks
        check(final(f,snapshot),"large already-drained final snapshot admitted")
        local out=f.calls[#f.calls].value
        check(out.latest.detail==text and out.latest.stop_reason==text and out.latest.source.reason==text,
            "escaped192-byte strings remain exact, never silently shortened")
        check(not out.observation_loss and f.recorder:status().flushed and #f.calls==f.baseline+1,"large summary still has one bounded writer")
    end)    case("public resource limits and wire identity stay unchanged",function()
        check(Recorder.limits.regular_rows==2048 and Recorder.limits.regular_bytes==524288
            and Recorder.limits.critical_rows==128 and Recorder.limits.critical_bytes==131072
            and Recorder.limits.summary_bytes==16384 and Recorder.limits.row_bytes==12288
            and Recorder.limits.chunk_bytes==24576 and Recorder.limits.chunk_rows==16,"all Recorder caps unchanged")
        local f=ready();check(final(f),"final cache accepted")
        local summary=f.calls[#f.calls].value
        check(summary.schema==1 and summary.encoding=="hop-delta-v4" and summary.run_id=="unload_contract","no wire/schema/profile relabel")
        check(summary.native_qualified==false and summary.native_retirement_known==false,"no native or durability claim")
    end)
    -- Exact current private Main + real proposed Context/Recorder. Only facade
    -- cleanup/status and scheduling dependencies are constructed, no Game SDK.
    local function main_fixture(options)
        options=options or {};local f={events={},loads={},steps=0,unloads=0,stops=0,game_calls=0,now=100,snapshot=closed(false),readiness_constructs=0,readiness_steps=0}
        local storage=fresh();f.storage=storage
        local services={storage={set=function(key,value)
            storage.calls[#storage.calls+1]={key=key,value=value}
            if options.writer then options.writer(f,key,value) end
        end},time={now=function()return f.now end},menu={}}
        function services.on(name,fn)check(f.events[name]==nil,"one Main event owner");f.events[name]=fn end
        function services.menu.page(_,fn)f.page=fn end
        local guard={configure=function()return true end,stop=function()return true end,
            status=function()return {hop_attempts=0} end}
        local readiness={after_step=function()f.readiness_steps+=1;return true end,stop=function()return true end}
        local bike={status=function()if options.status_error and f.unloads>0 then error("constructed final status unavailable",0) end;return f.snapshot end,
            step=function()f.steps+=1;return f.snapshot end,request_stop=function()f.stops+=1;return true end,
            unload=function()f.unloads+=1;f.snapshot.unloaded=true;if options.unload then options.unload(f) end end}
        local modules={
            ["./hop_config"]={schema=1,admission_enabled=true,phase=options.p0 and "P0" or "H1",run_id="main_unload",source_commit="062db162248d6b21c686f588924e0abc5954e99c",
                slot=0,ride_window_ms=1500,hop_strength=.25,mass=106,max_hop_attempts=1,caps={force=6000,speed=3,torque=2000,vertical_speed=3}},
            ["./h1_readiness_config"]={},["./lease_identity"]={},["./catalog"]={},
            ["./h1_readiness"]={new=function()f.readiness_constructs+=1;return readiness end},["./hop_guard"]={new=function()return guard end},
            ["./hop_recorder"]={new=function(writer,id)f.recorder=Recorder.new(writer,id);return f.recorder end},
            ["./hop_context"]={new=function(g,r,ready)f.context=(options.p0 and P0Context or Context).new(g,r,ready);return f.context end,bind=function()end},
            ["./hop_services"]={wrap=function(s)return s end},["./bike_admission"]={},["./bike_runtime"]={new=function()return bike end}}
        local run_entry=options.p0 and P0Entry or Entry
        run_entry(services,function(name)f.loads[name]=true;check(modules[name]~=nil,"exact Main dependency closure");return modules[name] end)
        for _=1,20 do f.now+=16;f.events.tick(16);if f.recorder and f.recorder:status().flushed then break end end
        check(f.recorder and f.recorder:status().flushed,"exact Main clean pre-unload baseline")
        f.baseline=#storage.calls;f.before_steps=f.steps;f.state=Factory.state(f.recorder)
        return f
    end
    case("exact private Main preserves and saves clean unloaded status",function()
        local f=main_fixture();check(f.readiness_constructs==1 and f.readiness_steps>0 and f.loads["./h1_readiness"],"H1 readiness construction/after-step stays connected");f.events.unload()
        check(f.unloads==1 and f.steps==f.before_steps and f.game_calls==0,"one existing cleanup call, no added Core/game step")
        local s=f.recorder:status();check(s.flushed and s.latest.unloaded and not s.unqualified,"actual clean final snapshot saved")
        check(#f.storage.calls==f.baseline+1 and f.storage.calls[#f.storage.calls].key=="hop.main_unload.summary","one final Main summary")
        f.events.unload();f.events.tick(16)
        check(f.unloads==1 and #f.storage.calls==f.baseline+1 and f.steps==f.before_steps,"repeat event cannot rerun cleanup or writer")
    end)
    case("exact Main scopes before cleanup reentry and preserves a new actual tail",function()
        local f=main_fixture({unload=function(owner)
            check(not owner.recorder:flush(gate),"scope established before facade cleanup callback")
            check(owner.recorder:append("ack",{sequence="9",acknowledged=true}),"unload observation retained")
        end})
        local stored=f.recorder:status().stored_rows;f.events.unload();local s=f.recorder:status()
        check(s.interrupted and s.observation_loss and not s.flushed and s.stored_rows==stored,"new tail never drained/dropped during Main unload")
        check(#f.storage.calls==f.baseline+1 and f.storage.calls[#f.storage.calls].key=="hop.main_unload.incomplete","one shared incomplete call")
    end)
    case("exact Main pending or unavailable final status remains incomplete",function()
        for _,mode in ipairs({"unknown","missing"}) do
            local f=main_fixture({status_error=mode=="missing",unload=mode=="unknown" and function(owner)owner.snapshot.cleanup_unknown=true end or nil})
            f.events.unload();local s=f.recorder:status()
            check(s.interrupted and s.observation_loss and s.unqualified and not s.flushed,"actual "..mode.." remains unqualified")
            check(#f.storage.calls==f.baseline+1 and f.storage.calls[#f.storage.calls].key=="hop.main_unload.incomplete","one incomplete Main writer")
        end
    end)
    case("current P0 variant retains the same clean and incomplete unload contract",function()
        for _,tail in ipairs({false,true}) do
            local f=main_fixture({p0=true,unload=tail and function(owner)
                check(owner.recorder:append("ack",{sequence="10",acknowledged=true}),"P0 actual new tail retained")
            end or nil})
            check(f.readiness_constructs==0 and not f.loads["./h1_readiness"],"P0 remains the exact non-readiness variant")
            f.events.unload();local s=f.recorder:status()
            check(s.latest.unloaded==true and s.flushed==(not tail) and s.observation_loss==tail and s.interrupted==tail,
                "P0 clean/tail classification matches H1 without replacing its entry")
            check(f.unloads==1 and f.steps==f.before_steps and #f.storage.calls==f.baseline+1,"P0 has one cleanup/no extra step/one writer")
        end
    end)    return {cases=cases,assertions=assertions,native_actions=0,private_factory_fixture=true,
        host_qualified=false,unload20ms_qualified=false,game_evidence=false}
end
return table.freeze(Tests)

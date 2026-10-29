-- Constructed Core lifetime/guard tests. SDK-shaped userdata and DTOs are
-- fixtures, never native ownership, consumed input, force or gameplay evidence.
local BuildCore=require("./core_session_renewable_fixture")
local BuildFacade=require("./two_cycle_facade_fixture")
local Main=require("./playable_main_fixture")
local Entry=require("./bmx_playable_entry")
local Identity=require("./lease_identity")
local Tests={}
local function copy(row)
    if type(row)~="table" then return row end
    local out={};for k,v in pairs(row) do out[k]=copy(v) end;return out
end
local function fixture(session,options)
    options=options or {}
    local f={now=1000,body=newproxy(),follow=newproxy(),source_handle=newproxy(),epoch=nil,
        body_reads=0,renews=0,accepted=0,probes=0,authorizes=0,stops=0,acks=0,source_stops=0,
        focused=true,menu=false,level="constructed",context="13",park=options.park~=false,source_serial=1}
    local R={time={},input={},menu={},skater={},level={},json={},storage={},entities={},world={physics={}}}
    function R.time.now() return f.now end
    function R.input.focus() return {focused=f.focused,interface_open=f.menu,gameplay=true} end
    function R.input.allowed() return true end
    function R.menu.game() return {open=false} end
    function R.skater.get() return {airborne=false,position=vector.create(0,0,0),heading=0} end
    function R.skater.telemetry() return {skater=true,airborne=false,teleport_pending=false,
        watch={valid=true,state=504,ragdoll_known=true,ragdoll=false,wipeouts=0}} end
    function R.skater.pose() return true end
    function R.level.current() return {name=f.level} end
    function R.json.encode() return "bounded constructed Core diagnostic" end
    function R.storage.get() return nil end
    function R.storage.set() end
    function R.entities.remove() end
    local P=R.world.physics
    function P.reserve_follow(body,attachment)
        assert(body==f.body,"same handed-off body")
        f.attachment=attachment;f.is_session=attachment.lifetime=="session_renewable"
        f.renewable=attachment.lifetime=="renewable" or f.is_session
        f.deadline=f.now+3000;f.ceiling=f.now+120000
        return f.follow,nil
    end
    function P.publish_follow(handle) assert(handle==f.follow);f.published=true;return true end
    function P.read_follow(handle)
        assert(handle==f.follow)
        local terminal=f.stops>0 and f.park
        local active=f.published
        local serial=tostring(f.body_reads+1)
        return {phase=terminal and "completed" or f.stops>0 and "retained" or active and "following" or "reserved",
            reason=terminal and "cancelled" or "none",park_reason="none",sequence="7",
            final_revision=active and serial or "0",final_native_epoch=active and serial or "0",
            returned_revision=active and serial or "0",pending={},in_flight=0,
            claim_known=not terminal,orphaned=false,park_observed=terminal,native_retirement_known=false,terminal=terminal}
    end
    function P.read_follow_lease(handle)
        assert(handle==f.follow)
        local remaining=math.max(0,f.deadline-f.now)
        local row={sequence="7",renewable=f.renewable,active=remaining>0,
            renewals=tostring(f.accepted),last_serial=f.accepted==0 and "0" or f.last_renew_serial,
            remaining_ms=remaining,base_ms=3000,renewal_ms=500,revocation="none",dispatch_busy="0"}
        if f.is_session and not f.legacy_row then
            row.session_renewable=true;row.lifetime_ms=0;row.lifetime_remaining_ms=0
        else
            row.session_renewable=false
            row.lifetime_ms=f.renewable and 120000 or 3000
            row.lifetime_remaining_ms=f.renewable and math.max(0,f.ceiling-f.now) or remaining
        end
        if f.mutate_row then f.mutate_row(row) end
        return row
    end
    function P.renew_follow(...)
        if select("#",...)~=2 then error("renew_follow takes one opaque follow handle and one measured body epoch",0) end
        local handle,epoch=...
        assert(handle==f.follow and typeof(epoch)=="userdata" and epoch==f.epoch,
            "renewal uses this tick's exact latest body epoch")
        assert(f.tick_renews==0,"one renewal per SDK-shaped tick")
        f.tick_renews+=1;f.renews+=1
        if f.refuse_renewal then return false,"sample_not_advanced" end
        if f.now>=f.deadline then return false,"expired" end
        if not f.is_session and f.now>=f.ceiling then return false,"lifetime_exhausted" end
        local proposed=f.now+500
        if not f.is_session then proposed=math.min(proposed,f.ceiling) end
        f.deadline=math.max(f.deadline,proposed);f.accepted+=1
        f.last_renew_serial=tostring(f.body_reads+1)
        return true,f.deadline-f.now
    end
    function P.read(body)
        assert(body==f.body)
        f.body_reads+=1;f.epoch=newproxy()
        return {serial=tostring(f.body_reads+1),epoch=not f.omit_epoch and f.epoch or nil,
            time=f.now/1000,seconds=.2,position=vector.create(0,1,0),rotation={0,0,0,1},
            velocity=vector.create(0,0,0),angular_velocity=vector.create(0,0,0),mass=106,inertia=vector.create(26,32,10)}
    end
    function P.probe_batch(body,epoch)
        assert(body==f.body and epoch==f.epoch,"query keeps the same measured body/epoch")
        f.probes+=1;return {}
    end
    function P.stop_follow(handle) assert(handle==f.follow);f.stops+=1;return true end
    function P.acknowledge_follow(handle) assert(handle==f.follow);f.acks+=1;return true end
    function P.release(body) assert(body==f.body);return true end
    local function frame()
        local buttons={};for _,name in {"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"} do buttons[name]=false end
        f.source_serial+=1
        return {phase="capturing",input_ok=true,new_observation=true,generation=1,lease_handle=f.source_handle,
            cleanup_pending=false,cleanup_unknown=false,sample={user=0,sequence="11",source_epoch="12",
                context_generation=f.context,observation_serial=tostring(f.source_serial),observed_ms=tostring(f.now),
                neutral=true,pad={buttons=buttons,left_x=0,left_y=0,right_x=0,right_y=0,
                    left_trigger=0,right_trigger=0,playstation=false}}}
    end
    local source={};f.current_frame=frame()
    function source:status()
        if f.source_stopped then return {phase="complete",input_ok=false,cleanup_pending=false,cleanup_unknown=false,generation=1} end
        return f.current_frame
    end
    function source:step()
        if f.source_stopped then return self:status() end
        f.current_frame=frame();return f.current_frame
    end
    function source:authorize(actual)
        f.authorizes+=1
        return not f.source_stopped and actual==f.current_frame
    end
    function source:stop() f.source_stops+=1;f.source_stopped=true;return true end
    function source:arm() return true end
    local spawn={phase="armed"}
    function spawn:request() return true end
    function spawn:update() self.phase="spawned" end
    function spawn:status() return {phase=self.phase,cleanup_unknown=false,creation_unknown=false,body=false,visual_remove_requested=false} end
    function spawn:handoff_follow() self.phase="follow_owned";return f.body,{serial="1"},nil end
    function spawn:follow_visual() return true end
    function spawn:floor_height() return 0 end
    function spawn:stop() self.phase="closed";return true end
    local FakeRide={}
    function FakeRide.new(api)
        local ride={stopped=false}
        function ride:status() return {phase=self.stopped and "stopped" or "running",force_pending=false,
            unknown=false,stop_requested=self.stopped,submitted=0,acknowledged=0} end
        function ride:observe(_,sample)
            api.probe_batch(sample.epoch,{{}}, {require_contact=true,exclude_local_actor=true})
            return self:status()
        end
        function ride:stop() self.stopped=true;return self:status() end
        function ride:drain() return self:status() end
        return ride
    end
    local FakePose={}
    function FakePose.new(api)
        local poser={state="unmounted"}
        function poser:mount() self.state="mounted";return {ok=true} end
        function poser:tick() return {ok=true,sent=false,state=self.state} end
        function poser:stop() self.state="off";api.skater.pose(nil) end
        function poser:status() return {state=self.state,blend=0,weight=0,qualified=true,capability=true,sends=0,ends=0} end
        return poser
    end
    local FakeBoard={}
    function FakeBoard.new()
        local board={state="held"}
        function board:drop() self.state="dropped";return {called=true} end
        function board:restore() self.state="restored";return {called=true} end
        function board:status() return {state=self.state,clear_result=self.state=="restored" and "cleared" or nil} end
        return board
    end
    local overrides={
        ["./lease_source"]={new=function(_,limits)
            assert(limits.setup_ms==15000 and limits.capture_ms==4000 and limits.cleanup_ms==4000,
                "Source watchdogs remain exact")
            return source
        end},
        ["./bike_spawn"]={new=function()return spawn end,floor_spawn_qualified=function()return false end},
        ["./ride_runtime"]=FakeRide,["./mounted_pose"]=FakePose,["./board_drop"]=FakeBoard,
    }
    f.Core=BuildCore(function(name) return overrides[name] or require(name) end)
    local state={phase="spawning",generation=1,cancel_version=1,counts={},calls={},receipts={},
        omitted_calls=0,omitted_receipts=0,remove_attempted={},remove_accepted={},used=true,
        active=true,source_armed=true,input_current=true,spawn_requested=true,ledger_owned=true,
        slot=0,level="constructed",wipeouts=0,arm_at=f.now,effect_at=f.now}
    f.T=state;f.P=P
    f.core=f.Core.new(R,{qualification_only=true,session_renewable=session},state)
    assert(f.core:prepare_backend(),"construct inert test dependencies")
    function f.tick(ms)
        ms=ms or 200;f.now+=ms;f.tick_renews=0
        return f.core:step(ms)
    end
    function f.start()
        f.tick_renews=0
        local out=f.core:step(16)
        assert(out.phase=="following","actual Core reserve/receipt/publish transition")
        f.published_at=f.now
        return out
    end
    return f
end

function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn) cases+=1;local ok,why=pcall(fn);assert(ok,name..": "..tostring(why)) end
    case("session report is explicit and legacy reports remain exact",function()
        local f=fixture(true);f.start();local row=f.P.read_follow_lease(f.follow)
        local until_ms,_,verdict=f.Core.lease_from_report(Identity,f.T.lease_until,"0",row,f.now,"7",true,true)
        check(until_ms==f.T.lease_until and verdict=="refined","new13-field session DTO is admitted")
        _,_,verdict=f.Core.lease_from_report(Identity,f.T.lease_until,"0",row,f.now,"7",true)
        check(verdict=="ignored","default validator refuses the extra session field")
        f.legacy_row=true;row=f.P.read_follow_lease(f.follow)
        _,_,verdict=f.Core.lease_from_report(Identity,f.T.lease_until,"0",row,f.now,"7",true,true)
        check(verdict=="ignored","opt-in cannot adopt an ordinary finite-lifetime DTO")
        _,_,verdict=f.Core.lease_from_report(Identity,f.T.lease_until,"0",row,f.now,"7",true)
        check(verdict=="refined","new13-field false renewable DTO remains valid")
        row.session_renewable=nil
        _,_,verdict=f.Core.lease_from_report(Identity,f.T.lease_until,"0",row,f.now,"7",true)
        check(verdict=="refined","old12-field renewable DTO remains valid")
        for _,value in {true,0,"false"} do
            row.session_renewable=value
            _,_,verdict=f.Core.lease_from_report(Identity,f.T.lease_until,"0",row,f.now,"7",true)
            check(verdict=="ignored","legacy mode refuses session true and nonboolean forgery")
        end
        row.session_renewable=false;row.extra=true
        _,_,verdict=f.Core.lease_from_report(Identity,f.T.lease_until,"0",row,f.now,"7",true)
        check(verdict=="ignored","legacy optional field never admits unrelated keys")
        row.extra=nil;row.renewable=false;row.lifetime_ms=3000;row.lifetime_remaining_ms=row.remaining_ms
        _,_,verdict=f.Core.lease_from_report(Identity,f.T.lease_until,"0",row,f.now,"7",false)
        check(verdict=="refined","new13-field false fixed DTO keeps the old finite lifetime")
    end)
    case("session renewal preserves initial base and strict maximum",function()
        local f=fixture(true)
        local packed=function(...)return table.pack(true,...)end
        local until_ms,verdict=f.Core.renewal_outcome(4000,1200,packed(true,2800),true)
        check(until_ms==4000 and verdict=="renewed","first native3s seed is never shortened")
        for _,remaining in {0,3001,500.5,math.huge} do
            local u,v=f.Core.renewal_outcome(4000,1200,packed(true,remaining),true)
            check(u==4000 and v=="wait","bad session remaining extends nothing")
        end
        until_ms,verdict=f.Core.renewal_outcome(4000,1200,packed(true,120000))
        check(until_ms==121200 and verdict=="renewed","legacy120s result bound is unchanged")
        check(f.Core.lease_live(130000,1000,131000,true) and not f.Core.lease_live(130000,1000,131000),
            "only explicit session policy crosses the old absolute ride bound")
    end)
    case("actual Core follows beyond120s with fresh DTO and body proof",function()
        local f=fixture(true);f.start();local out
        for _=1,626 do out=f.tick() end
        check(f.now-f.published_at>120000 and out.phase=="following" and not out.stop_latched,"no60s/65s/120s session ceiling")
        check(f.attachment.lifetime=="session_renewable" and out.session_renewable and out.ride_window_ms==0,"explicit mode is visible")
        check(f.accepted>500 and f.probes>600 and f.authorizes>600,"renewals use fresh epochs and original subordinate owner guards")
        check(out.lease_until_ms>f.now+150 and out.source.cleanup_pending==false,"only a live short native lease sustains authority")
        check(f.core:request_stop("explicit session stop"),"ordinary stop still accepted")
        out=f.tick()
        check(out.phase=="done" and out.bike_cleanup_complete and not out.cleanup_unknown,"same original cleanup conjunction finishes")
        check(f.stops==1 and f.acks==1 and f.source_stops>=1,"same Follow stop/terminal ACK and Source stop")
        check(not f.core:request_mount(0),"continuous following does not rearm a consumed Core")
    end)
    case("default Core still stops at60s",function()
        local f=fixture(false);f.start();local out
        for _=1,300 do out=f.tick() end
        check(out.stop_latched and out.stop_reason=="ride window or Follow lease ended","default ride window unchanged")
        check(f.attachment.lifetime=="renewable" and out.session_renewable==nil and out.ride_window_ms==60000,"default DTO/admission shape unchanged")
    end)
    case("removing renewal cannot sustain a session",function()
        local f=fixture(true);f.start();f.tick();local last=f.T.lease_until
        f.P.renew_follow=nil
        local out
        for _=1,20 do out=f.tick() end
        check(out.stop_latched and out.stop_reason:find("lease",1,true)~=nil,"missing renewal runs down the original lease")
        check(f.T.lease_until==last and out.phase=="done","no source report or option renews authority")
    end)
    case("missing or malformed session DTO stops before renewal",function()
        for _,mutate in {
            function(r)r.session_renewable=false end,
            function(r)r.lifetime_ms=120000 end,
            function(r)r.lifetime_remaining_ms=1 end,
            function(r)r.remaining_ms=3001 end,
            function(r)r.extra=true end,
        } do
            local f=fixture(true);f.start();f.mutate_row=mutate
            local out=f.tick()
            check(out.stop_latched and f.renews==0 and f.body_reads==0,"a malformed session proof cannot reach body/renewal")
        end
        local f=fixture(true);f.start();f.P.read_follow_lease=nil
        check(f.tick().stop_latched and f.renews==0,"session report availability is mandatory")
    end)
    case("menu and context loss still stop and clean",function()
        for _,gate in {
            {name="menu",change=function(f)f.menu=true end,why="fresh menu/input/grounded acquisition gate lost"},
            {name="level",change=function(f)f.level="another" end,why="fresh sampled upright/focus/context/fall readiness lost"},
            {name="focus",change=function(f)f.focused=false end,why="fresh sampled upright/focus/context/fall readiness lost"},
        } do
            local f=fixture(true);f.start();f.tick()
            local reads,renews,probes=f.body_reads,f.renews,f.probes
            gate.change(f);local out=f.tick()
            check(out.stop_latched and out.stop_reason==gate.why and f.stops==1,gate.name.." readiness guard stops immediately")
            check(f.body_reads==reads and f.renews==renews and f.probes==probes,gate.name.." refuses before any ride work")
            check(out.phase=="done" and out.bike_cleanup_complete and not out.cleanup_unknown
                and out.force_cleanup_clear and f.acks==1 and f.source_stops>=1,gate.name.." finishes original cleanup conjunction")
            check(out.pose.stopped and out.pose.nil_accepted and out.board.state=="restored",gate.name.." releases pose and restores board")
        end
        local f=fixture(true);f.start();f.tick()
        local reads,renews,probes=f.body_reads,f.renews,f.probes
        f.context="14";local out=f.tick();local stopped_at=f.T.stop_at
        check(out.stop_latched and out.stop_reason=="current Core Source/Follow/body/epoch force guard refused"
            and f.stops==1,"selected context change stops at the original bound owner guard")
        check(f.body_reads==reads+1 and f.renews==renews and f.probes==probes,
            "changed context refuses SDK query; body "..f.body_reads.."/"..reads..", renew "..f.renews.."/"..renews..", query "..f.probes.."/"..probes)
        check(f.T.lease_until==f.published_at+3000,"context tick does not shorten or unnecessarily renew the original3s base")
        -- This guard runs after this tick's Follow read. Preserve Core's50ms
        -- cleanup poll interval: stop now, then observe the park and ACK later.
        check(out.phase=="stopping" and out.cleanup_pending and not out.bike_cleanup_complete
            and not out.cleanup_unknown and f.acks==0 and f.T.follow==f.follow,"no same-tick terminal receipt or ACK is fabricated")
        reads,renews=f.body_reads,f.renews
        out=f.tick(49)
        check(out.phase=="stopping" and f.acks==0 and not out.bike_cleanup_complete,"cleanup receipt poll remains throttled before50ms")
        out=f.tick(1)
        check(out.phase=="done" and out.bike_cleanup_complete and not out.cleanup_unknown
            and out.force_cleanup_clear and f.stops==1 and f.acks==1 and f.source_stops>=1,"first permitted50ms poll completes original cleanup")
        check(f.T.stop_at==stopped_at and f.now-stopped_at==50 and not f.T.cleanup_expired,"cleanup keeps its original stop time and20s watchdog")
        check(f.body_reads==reads and f.renews==renews and f.probes==probes,"stopped cleanup never reads, renews or queries another ride sample")
        check(out.pose.stopped and out.pose.nil_accepted and out.board.state=="restored","context stop releases pose and restores board")
    end)
    case("missing body epoch cannot bypass owner proof",function()
        local f=fixture(true);f.start();f.tick();f.omit_epoch=true
        local out=f.tick()
        check(out.stop_latched and f.stops==1,"same-read body epoch still required after opt-in")
    end)
    case("startup60s and pre-follow effect65s remain",function()
        local f=fixture(true)
        f.T.phase="armed";f.T.source_armed=false;f.T.arm_at=f.now-60000;f.menu=true
        local out=f.tick()
        check(out.stop_reason=="mount intent expired before acquisition","startup60s never becomes renewable")
        local g=fixture(true)
        g.T.phase="capturing";g.T.effect_at=g.now-65000
        out=g.tick()
        check(out.stop_reason=="total effect watchdog expired","only successful following can omit65s absolute stop")
    end)
    case("stalled ticks and original20s cleanup remain",function()
        local f=fixture(true);f.start()
        check(f.tick(251).stop_reason=="invalid, stalled or reversed wall tick","250ms tick cap unchanged")
        local g=fixture(true,{park=false});g.start();g.tick();g.core:request_stop("retained park")
        local stop=g.T.stop_at
        g.now=stop+20000;g.tick_renews=0
        local out=g.core:step(16)
        check(g.T.cleanup_expired and out.phase=="retained_unknown" and not out.bike_cleanup_complete,"20s retains unresolved native duty")
        check(g.acks==0 and g.T.stop_at==stop,"no fabricated terminal ACK or cleanup reset")
    end)
    case("Main remains closed, finite and inert by default",function()
        local options_seen,menu,notes
        notes={}
        local object={step=function()end,unload=function()end,mount=function()error("draw never mounts")end,
            return_to_skateboard=function()error("draw never returns")end,cancel=function()error("draw never cancels")end,
            status=function()return{phase="idle",admitted=false,detail="closed",attempts_used=0,attempt_limit=2,
                terrain_refusal_count=0,terrain_refusal_limit=8,cleanup_pending=false,cleanup_unknown=false}end}
        local Runtime,Survey={},{}
        local modules={["./bike_runtime"]=Runtime,["./ride_r1_record"]=Survey,
            ["./bmx_playable_entry"]={new=function(_,r,s,opts)
                check(r==Runtime and s==Survey,"same Main dependencies")
                options_seen=opts;return object
            end}}
        Main({input={bind=function(name,key)check(name=="bmx_return" and key=="F8","closed Main registers only the keyboard Return action");return true end},on=function()end,menu={page=function(_,fn)menu=fn end}},function(name)return modules[name]end)
        local ui={warn=function()end,info=function()end,button=function()return false end,
            note=function(_,text)notes[#notes+1]=text end}
        menu(ui)
        check(options_seen.admitted==false and options_seen.session_renewable==false
            and options_seen.experimental_two_cycle==true,"no source admission or continuous activation")
        local finite=false;for _,text in notes do if text:find("Each ride is bounded to60s.",1,true)then finite=true end end
        check(finite,"legacy60s UI remains the default")
    end)
    case("Entry forwards only a boolean opt-in without admission",function()
        for _,value in {{},{value=false},{value=true},{value="true"},{value=1}} do
            local captured,calls=nil,0
            local Runtime={}
            function Runtime.new_experimental_two_cycle(_,opts)
                captured=opts;calls+=1;return {}
            end
            local entry=Entry.new({storage={keys=function()return {} end}},Runtime,{},
                {admitted=false,slot=0,experimental_two_cycle=true,session_renewable=value.value})
            local state=entry:status()
            check(calls==1 and captured.qualification_only==true and type(captured.session_renewable)=="boolean",
                "one inert constructor receives boolean options")
            check(captured.session_renewable==(value.value==true) and state.admitted==false and state.attempt_limit==2,
                "only explicit true selects session and no option admits source or extra attempts")
        end
    end)
    case("facade forwards opt-in to first and successor Core only",function()
        local f={now=1000,state=504,seen={},count=0,done504=true}
        local Admission={}
        function Admission.snapshot(t)return{phase=t.phase,stock_toggle_blocked=false}end
        function Admission.ready(o)return o and o.grounded and o.upright_stock end
        function Admission.matches(a,b)return a.state==b.state and a.level==b.level end
        function Admission.bind(t)
            return {marker_clear=function()return true end,persist=function()return true end,available=function()return true end,
                clock=function()f.now+=16;t.now=f.now;return f.now end,
                facts=function()return{state=f.state,grounded=true,upright_stock=true,level="constructed",wipeouts=0}end}
        end
        local Core={}
        local function make(t,opts)
            f.seen[#f.seen+1]=copy(opts);f.count+=1
            local o={}
            function o:status()return{phase=t.phase,stock_toggle_blocked=false,bike_cleanup_complete=true,cleanup_unknown=false}end
            function o:prepare_backend()return true end
            function o:request_mount()t.phase="following";return true end
            function o:request_stock_toggle()return true end
            function o:request_stop()return true end
            function o:step()return self:status()end
            function o:unload()return self:status()end
            return o
        end
        function Core.new(_,opts,t)return make(t,opts)end
        function Core.experimental_two_cycle_owner()
            local owner={}
            function owner:first(_,opts,t)f.old=t;return make(t,opts)end
            function owner:can_archive_return()return true end
            function owner:archive_return()return true end
            function owner:ready()return true end
            function owner:abort_preparation()end
            function owner:successor(_,opts,t)return make(t,opts)end
            return owner
        end
        local Runtime=BuildFacade(function(name)
            if name=="./bike_admission"then return Admission elseif name=="./bike_runtime_core"then return Core end
            return {}
        end)
        local manager=assert(Runtime.new_experimental_two_cycle({}, {qualification_only=true,session_renewable=true}))
        check(manager:request_mount(0),"first facade request")
        for _=1,80 do manager:step(16)end
        check(f.count==1 and f.seen[1].session_renewable==true,"explicit option reaches first Core")
        f.old.phase="done";f.old.bike_cleanup_complete=true;f.state=100
        check(manager:prepare_next_mount(0),"unchanged second preparation")
        f.state=504
        check(manager:request_mount(0),"second facade request")
        for _=1,80 do manager:step(16)end
        check(f.count==2 and f.seen[2].session_renewable==true,"same opt-in reaches only the bounded successor")
        check(not manager:request_mount(0) and f.count==2,"two-attempt policy remains")
    end)
    return {cases=cases,assertions=assertions,constructed=true,native_authority=false}
end
return table.freeze(Tests)

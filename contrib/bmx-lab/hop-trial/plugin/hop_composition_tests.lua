-- Source-authored composition regressions using constructed SDK services only.
-- These exercise forwarding and facade scheduling, not native execution or cold
-- compiler work: the runner may already have cached a required production module.
local Services=require("./hop_services")
local Context=require("./hop_context")
local Runtime=require("./bike_runtime")
local Tests={}

local function observer()
    local f={seen={},stops=0,submits=0}
    local context={}
    function context:observe_service(path,args,result)
        f.seen[#f.seen+1]={path=path,args=args,result=result}
        if f.observer_error then error(f.observer_error,0) end
        if f.observer_refused then return false,"constructed recorder full" end
        return true
    end
    function context:request_stop(why)
        f.stops+=1;f.reason=f.reason or why
    end
    function context:submit(body,epoch,packet,delegate)
        f.submits+=1;f.submit_args=table.pack(body,epoch,packet)
        return delegate(body,epoch,packet)
    end
    function context:status() return {stop_requested=f.stops>0,reason=f.reason} end
    f.context=context
    return f
end

local function context_fixture()
    local f={configured=0,stops=0,begins=0,previews=0,submits=0,rows={},terminals={},flushes={},interrupts={}}
    local guard={}
    function guard:configure(config) f.configured+=1;f.config=config;return true end
    function guard:stop(why) f.stops+=1;f.reason=f.reason or why end
    function guard:begin(...) f.begins+=1;f.begin_args=table.pack(...);return true end
    function guard:observe(...)
        f.previews+=1;f.preview_args=table.pack(...)
        if f.preview_refused then return false,"constructed force refusal" end
        return true
    end
    function guard:submit(body,epoch,packet,delegate)
        f.submits+=1;return delegate(body,epoch,packet)
    end
    function guard:status() return {stopped=f.stops>0,reason=f.reason} end
    local recorder={}
    function recorder:append(kind,payload)
        f.rows[#f.rows+1]={kind=kind,payload=payload}
        if f.append_error then error(f.append_error,0) end
        if f.append_refused then return false,"constructed recorder full" end
        return true
    end
    function recorder:terminal(snapshot)
        f.terminals[#f.terminals+1]=snapshot
        if f.terminal_error then error(f.terminal_error,0) end
        if f.terminal_refused then return false,"constructed terminal capacity" end
        return true
    end
    function recorder:status() return {stop_requested=f.recorder_stop==true,first_fault="constructed recorder fault"} end
    function recorder:flush(gate) f.flushes[#f.flushes+1]=gate;return true,nil,"constructed flush" end
    function recorder:interrupt(...)
        f.interrupts[#f.interrupts+1]=table.pack(...)
        if f.interrupt_error then error(f.interrupt_error,0) end
        local result=f.interrupt_result or table.pack(true,nil,"constructed interrupt")
        return table.unpack(result,1,result.n)
    end
    f.context=Context.new(guard,recorder);f.guard=guard;f.recorder=recorder
    return f
end
local function ready_services()
    local f={now=1000,calls=0,native=0,storage_reads=0,storage_writes=0,prepares=0,menu_open=true}
    local s={time={},input={},skater={},level={},storage={},json={},menu={},entities={},world={physics={}}}
    local function touch() f.calls+=1 end
    function s.time.now() touch();return f.now end
    function s.input.focus() touch();return {focused=true,interface_open=f.menu_open,gameplay=true} end
    function s.input.allowed() touch();return true end
    function s.menu.game() touch();return {open=f.menu_open} end
    function s.skater.get() touch();return {airborne=false,position=vector.create(0,0,0),heading=0} end
    function s.skater.telemetry()
        touch();return {skater=true,airborne=false,teleport_pending=false,
            watch={valid=true,state=504,ragdoll_known=true,ragdoll=false,wipeouts=0}}
    end
    function s.level.current() touch();return {name="constructed-hop-stage"} end
    function s.storage.get() touch();f.storage_reads+=1;return nil end
    function s.json.encode() touch();return "constructed lifecycle record" end
    function s.storage.set() touch();f.storage_writes+=1 end
    local function forbidden() f.native+=1;error("no native acquisition is allowed in startup",0) end
    for _,name in ipairs({"lease","lease_read","lease_renew","lease_state","lease_release","lease_acknowledge",
        "lease_capture","lease_capture_state","lease_release_capture","lease_acknowledge_capture",
        "pulse","pulse_state","pulse_cancel","pulse_acknowledge"}) do s.input[name]=forbidden end
    for _,name in ipairs({"bounds","set","status","remove"}) do s.entities[name]=forbidden end
    for _,name in ipairs({"create","read","release","reserve_follow","publish_follow","read_follow",
        "stop_follow","acknowledge_follow","probe_batch","submit","receipt","acknowledge"}) do
        s.world.physics[name]=forbidden
    end
    function s.world.physics.prepare(...)
        touch();f.prepares+=1
        assert(select("#",...)==0,"preparation preserves zero-argument SDK contract")
        if f.on_prepare then return f.on_prepare() end
        return true
    end
    f.services=s
    return f
end

-- Only entry control is under test here. The lexical fixture contains the exact
-- main.lua source; its injected facade/guard/recorder are protocol spies. The
-- separate final case below still drives the actual production facade and Core.
local function entry_fixture(options)
    options=options or {}
    local Entry=require("./hop_entry_fixture")
    local Admission=require("./bike_admission")
    local f=ready_services();local s=f.services
    f.events={};f.trace={};f.loads={};f.buttons={};f.shown={}
    f.created=0;f.mounts=0;f.steps=0;f.stops=0;f.unloads=0;f.flushes=0;f.interrupts=0
    f.ready=false;f.flushed=false;f.mount_result=options.mount_result~=false
    f.snapshot={phase="idle",bike_authority=false,cleanup_pending=false,cleanup_unknown=false,
        startup={pending=false},stop_latched=false}
    local function mark(name) f.trace[#f.trace+1]=name end
    function s.input.focus() f.calls+=1;return {focused=true,interface_open=not f.ready,gameplay=true} end
    function s.input.allowed() f.calls+=1;return f.ready end
    function s.menu.game() f.calls+=1;return {open=not f.ready} end
    function s.on(name,callback) assert(f.events[name]==nil,"entry registered an event twice");f.events[name]=callback end
    function s.menu.page(_,callback) assert(f.page==nil,"entry registered its menu twice");f.page=callback end
    local config=table.freeze({schema=1,admission_enabled=options.admitted==true,
        phase=options.phase or (options.admitted and "H1" or "P0"),run_id="entry_fixture",source_commit="062db162248d6b21c686f588924e0abc5954e99c",
        slot=0,ride_window_ms=1500,hop_strength=.25,mass=106,max_hop_attempts=1,
        caps=table.freeze({force=6000,speed=3,torque=2000,vertical_speed=3})})
    local recorder={}
    function recorder:status()
        mark("recorder.status")
        return {flushed=f.flushed,storage_fault=f.storage_fault==true,observation_loss=f.observation_loss==true,unqualified=false}
    end
    local context={}
    function context:configure(c) mark("context.configure");f.configured=c;if not c.admission_enabled then self:request_stop("closed") end end
    function context:request_stop(why) mark("context.stop");f.stop_requested=true;f.stop_reason=f.stop_reason or why end
    function context:status() mark("context.status");return {stop_requested=f.stop_requested==true,reason=f.stop_reason} end
    function context:after_step(snapshot)
        mark("context.after_step");f.recorded=snapshot
        if snapshot.stop_latched then self:request_stop(snapshot.stop_reason or "Core stopped") end
    end
    function context:flush(gate) mark("writer.flush");f.flushes+=1;f.flush_gate=gate;f.flushed=true;return true end
    function context:interrupt(snapshot) mark("writer.interrupt");f.interrupts+=1;f.interrupted=table.pack(snapshot);return true end
    local bike={}
    function bike:status() mark("bike.status");if f.status_error then error(f.status_error,0) end;return f.snapshot end
    function bike:request_mount(slot)
        mark("bike.mount");f.mounts+=1;f.mount_slot=slot
        if not f.mount_result then return false,"constructed mount refusal" end
        f.snapshot={phase="following",bike_authority=true,cleanup_pending=true,cleanup_unknown=false,startup={pending=false}}
        return true
    end
    function bike:request_stop(why) mark("bike.stop");f.stops+=1;f.snapshot.stop_latched=true;f.snapshot.stop_reason=why;return true end
    function bike:step(dt) mark("bike.step");f.steps+=1;f.last_dt=dt;return f.snapshot end
    function bike:unload() mark("bike.unload");f.unloads+=1 end
    local guard={}
    function guard:status()
        mark("guard.status")
        return {hop_attempts=f.hop_attempts or 0,last_outcome=f.hop_outcome or "none"}
    end
    local modules={
        ["./hop_config"]=config,["./lease_identity"]={},["./catalog"]={},
        ["./hop_guard"]={new=function() mark("guard.new");return guard end},
        ["./hop_recorder"]={new=function(set,run_id) mark("recorder.new");f.writer=set;f.run_id=run_id;return recorder end},
        ["./hop_context"]={new=function(g,r) mark("context.new");f.guard_arg=g;f.recorder_arg=r;return context end,
            bind=function(c) mark("context.bind");f.bound=c end},
        ["./hop_services"]={wrap=function(real,c) mark("services.wrap");f.wrapped_real=real;f.wrapped_context=c;return real end},
        ["./bike_admission"]=Admission,
        ["./bike_runtime"]={new=function(real,settings) mark("bike.new");f.created+=1;f.runtime_services=real;f.runtime_options=settings;return bike end},
    }
    Entry(s,function(name)
        f.loads[#f.loads+1]=name
        assert(modules[name]~=nil,"unexpected entry dependency")
        return modules[name]
    end)
    function f.tick(dt) dt=dt or 16;f.now+=dt;f.events.tick(dt) end
    function f.prepare() for _=1,10 do f.tick() end end
    function f.draw(click)
        if click then f.buttons[click]=true end
        f.shown={}
        f.page({note=function() end,button=function(_,id)
            f.shown[id]=true
            local clicked=f.buttons[id]==true;f.buttons[id]=nil;return clicked
        end})
    end
    function f.overlay()
        local out={}
        f.events.draw({text=function(_,point,value,style)
            out[#out+1]={point=point,value=value,style=style}
        end})
        return out
    end
    f.context=context;f.recorder=recorder;f.guard=guard
    return f
end
function Tests.run()
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    local function case(run) cases+=1;run() end
    local function tuple(actual,expected,why)
        check(actual.n==expected.n,why..": exact arity")
        for i=1,expected.n do check(actual[i]==expected[i],why..": value "..i) end
    end
    case(function()
        local f=observer();local calls=0
        local real={world={physics={}},storage={}}
        function real.world.physics.read() calls+=1;return "first" end
        function real.storage.set() calls+=1 end
        local s=Services.wrap(real,f.context)
        check(table.isfrozen(s) and calls==0 and #f.seen==0,"constructing frozen namespace proxies calls no service or observer")
        tuple(table.pack(s.storage.set("key",{})),table.pack(),"void storage acceptance stays void")
        check(s.world.physics.read()=="first","the first namespace resolves the real function")
        local saved_read=s.world.physics.read
        real.world={physics={read=function() calls+=1;return "replacement" end}}
        check(saved_read()=="replacement","a saved wrapper resolves the replacement function when invoked")
        check(s.world.physics.read()=="replacement","replacing a whole namespace is visible to the next lookup")
        real.world.physics.read=nil
        check(s.world.physics.read==nil,"a missing service stays missing for Core admission checks")
        check(pcall(saved_read)==false,"a saved wrapper cannot call a removed SDK function")
        check(calls==4,"proxy lookup and missing-function refusal add no hidden native call")
    end)
    for _,returned in ipairs({table.pack(nil,"unavailable",nil),table.pack(true,nil,"0000000000000001"),
        table.pack(false,"busy"),table.pack()}) do
        case(function()
            local f=observer();local reads,receipts=0,0;local body,epoch={},{}
            local args=table.pack(body,nil,epoch,nil)
            local real={world={physics={}}}
            function real.world.physics.read(...)
                reads+=1;tuple(table.pack(...),args,"plain SDK arguments, including nil holes")
                return table.unpack(returned,1,returned.n)
            end
            function real.world.physics.receipt() receipts+=1;error("no extra receipt poll",0) end
            local s=Services.wrap(real,f.context)
            tuple(table.pack(s.world.physics.read(table.unpack(args,1,args.n))),returned,"native tuple is untouched")
            check(reads==1 and receipts==0 and #f.seen==1,"one read yields one observation and no extra poll")
            local row=f.seen[1]
            check(row.path=="world.physics.read","observation carries the original dotted service name")
            tuple(row.args,args,"observer sees the same argument identities")
            local expected=table.pack(true,table.unpack(returned,1,returned.n))
            tuple(row.result,expected,"observer sees the complete pcall tuple")
        end)
    end
    case(function()
        local f=observer();local thrown={marker="SDK failure"};local calls=0
        local real={world={physics={read=function() calls+=1;error(thrown,0) end}}}
        local s=Services.wrap(real,f.context)
        tuple(table.pack(pcall(s.world.physics.read,{})),table.pack(false,thrown),"SDK error object identity")
        check(calls==1 and #f.seen==1,"a thrown SDK call is observed exactly once")
        tuple(f.seen[1].result,table.pack(false,thrown),"observer receives the same SDK error")
        f.observer_error={marker="observer exception"}
        tuple(table.pack(pcall(s.world.physics.read,{})),table.pack(false,thrown),
            "an observer exception cannot replace the original SDK error")
        check(calls==2 and #f.seen==2 and f.stops==1,"a failing observer adds only deferred stop, never a retry")
    end)
    for _,mode in ipairs({"accepted","refused","throw"}) do
        case(function()
            local f=observer();local body,epoch,packet={},{},{};local calls=0
            local thrown={marker="submit exception"}
            local returned=mode=="accepted" and table.pack(true,nil,"0000000000000007") or table.pack(false,"capacity")
            local real={world={physics={submit=function(...)
                calls+=1;tuple(table.pack(...),table.pack(body,epoch,packet),"guard delegate gets original submit arguments")
                if mode=="throw" then error(thrown,0) end
                return table.unpack(returned,1,returned.n)
            end}}}
            local s=Services.wrap(real,f.context)
            local out=table.pack(pcall(s.world.physics.submit,body,epoch,packet))
            local expected=mode=="throw" and table.pack(false,thrown) or table.pack(true,table.unpack(returned,1,returned.n))
            tuple(out,expected,"guarded publication preserves its real outcome")
            check(calls==1 and f.submits==1,"submit passes through the guard once and delegates once")
            tuple(f.submit_args,table.pack(body,epoch,packet),"context receives exact publication ownership")
        end)
    end
    for _,mode in ipairs({"refused","throw"}) do
        case(function()
            local f=observer();local native_active=false;local reads=0;local cleanup={}
            local original_stop=f.context.request_stop
            function f.context:request_stop(why)
                check(not native_active,"observer failure cannot stop while the native callback is on stack")
                original_stop(self,why)
            end
            f.observer_refused=mode=="refused";f.observer_error=mode=="throw" and {} or nil
            local sample={serial="0000000000000001"}
            local real={world={physics={}}}
            function real.world.physics.read()
                native_active=true;reads+=1;native_active=false;return sample
            end
            for _,name in ipairs({"release","stop_follow","receipt","acknowledge","acknowledge_follow"}) do
                real.world.physics[name]=function(...)
                    cleanup[#cleanup+1]={name=name,args=table.pack(...)}
                    return true,nil,name
                end
            end
            local s=Services.wrap(real,f.context)
            tuple(table.pack(s.world.physics.read("body")),table.pack(sample),"observer failure cannot replace a successful read")
            check(f.stops>0 and reads==1,"observer refusal or exception latches deferred stop without rereading")
            for _,name in ipairs({"release","stop_follow","receipt","acknowledge","acknowledge_follow"}) do
                tuple(table.pack(s.world.physics[name]("original-body",nil,"original-sequence")),table.pack(true,nil,name),
                    "cleanup still forwards after observation failure")
                tuple(cleanup[#cleanup].args,table.pack("original-body",nil,"original-sequence"),"cleanup retains original ownership")
            end
            real.input={}
            for _,name in ipairs({"lease_release","lease_acknowledge","lease_release_capture","lease_acknowledge_capture"}) do
                real.input[name]=function(...)
                    cleanup[#cleanup+1]={name=name,args=table.pack(...)};return true
                end
                tuple(table.pack(s.input[name]("original-lease","original-generation")),table.pack(true),
                    "input cleanup survives the same observer failure")
                tuple(cleanup[#cleanup].args,table.pack("original-lease","original-generation"),"input cleanup retains exact ownership")
            end
            check(#cleanup==9 and reads==1,"recording failure neither blocks cleanup nor adds native work")
        end)
    end
    case(function()
        local f=context_fixture();local context=f.context
        check(context:configure({phase="H1",admission_enabled=true}),"context configures its pure guard once")
        check(f.configured==1 and f.config.phase=="H1" and f.config.admitted==true,"reviewed admission is passed explicitly to the guard")
        local handle,epoch={},{}
        local raw={epoch=epoch,serial="0000000000000001",position=vector.create(1,2,3),rotation={0,0,0,1}}
        local mapped={source={generation=1,sequence="0000000000000001"},force_controls={hop_strength=.25}}
        local measured,frame,contact={},{},{}
        check(context:before_force(handle,raw,mapped,measured,frame,contact),"the context passes the original frame to guard admission")
        tuple(f.begin_args,table.pack(handle,raw,mapped,measured,frame,contact),"all six guard inputs retain identity")
        local recorded_body
        for _,row in ipairs(f.rows) do if row.kind=="body" then recorded_body=row.payload end end
        check(recorded_body~=nil and recorded_body.epoch==nil and recorded_body.position[1]==1,
            "body evidence is a projection and contains no opaque epoch authority")
        raw.position=vector.create(9,9,9);raw.rotation[1]=9
        check(recorded_body.position[1]==1 and recorded_body.rotation[1]==0,"later sample changes cannot rewrite recorded body fields")
        local folded,controls,model,candidate={mass=106},{},{valid=true},{}
        check(context:observe_preview(.01,folded,controls,model,candidate),"the context observes the actual preview")
        tuple(f.preview_args,table.pack(.01,folded,controls,model,candidate),"preview and candidate reach the guard unchanged")
        local packet={};local delegated=0
        tuple(table.pack(context:submit(handle,epoch,packet,function(...)
            delegated+=1;tuple(table.pack(...),table.pack(handle,epoch,packet),"context submits original ownership")
            return true,nil,"0000000000000009"
        end)),table.pack(true,nil,"0000000000000009"),"context preserves accepted publication tuple")
        check(delegated==1 and f.submits==1,"the context does not retry an accepted publication")
        check(context:configure({phase="H1",admission_enabled=true})==false and f.configured==1,
            "a second configuration revokes without reconfiguring the guard")
        check(context:status().stop_requested and f.stops==1,"revocation is sticky and pure")
        local gate={inactive=true,terminal=true}
        tuple(table.pack(context:flush(gate)),table.pack(true,nil,"constructed flush"),"flush delegates its exact result")
        check(#f.flushes==1 and f.flushes[1]==gate,"flush retains the explicit terminal inactivity witness")
    end)
    for _,mode in ipairs({"refused","throw","extra_nil"}) do
        case(function()
            local f=context_fixture();local native=0;local cleanup=0;local publication=0
            local thrown={marker="pose exception"};local plan={weight=1}
            local expected=mode=="throw" and table.pack(false,thrown)
                or mode=="extra_nil" and table.pack(true,true,nil) or table.pack(true,false,"unavailable")
            local real={skater={},world={physics={}}}
            function real.skater.pose(value)
                native+=1;check(value==plan,"pose forwarding retains the actual supplied plan")
                if mode=="throw" then error(thrown,0) end
                if mode=="extra_nil" then return true,nil end
                return false,"unavailable"
            end
            function real.world.physics.release(body) cleanup+=1;check(body=="original-body","release retains original body");return true end
            function real.world.physics.submit() publication+=1;return true,nil,"0000000000000001" end
            local s=Services.wrap(real,f.context)
            tuple(table.pack(pcall(s.skater.pose,plan)),expected,"pose refusal preserves the real return or error")
            check(native==1 and f.context:status().stop_requested and f.stops==1,
                "pose refusal, exception or malformed arity only latches pure revocation")
            check(cleanup==0,"observing pose failure cannot initiate native cleanup inside the callback")
            check(s.world.physics.release("original-body")==true and cleanup==1,"the later owner cleanup still forwards")
            local out=table.pack(s.world.physics.submit("original-body",{},{}))
            check(out.n==2 and out[1]==false and publication==0 and f.submits==0,
                "deferred cleanup does not permit another force publication")
            check(f.stops==1,"cleanup observations cannot repeatedly revoke the guard")
        end)
    end
    for _,mode in ipairs({"refused","throw"}) do
        case(function()
            local f=context_fixture();local sample={serial="0000000000000002"};local reads,acks=0,0
            f.append_refused=mode=="refused";f.append_error=mode=="throw" and {} or nil
            local real={world={physics={
                read=function() reads+=1;return sample end,
                acknowledge=function(body,sequence)
                    acks+=1;check(body=="body" and sequence=="sequence","cleanup carries original receipt ownership");return true
                end}}}
            local s=Services.wrap(real,f.context)
            tuple(table.pack(s.world.physics.read("body")),table.pack(sample),"recorder capacity or error cannot alter a native sample")
            check(f.context:status().stop_requested and f.stops==1 and reads==1 and acks==0,
                "recording failure requests later stop without polling or cleanup")
            check(s.world.physics.acknowledge("body","sequence")==true and acks==1 and reads==1,
                "exact receipt cleanup survives further recorder failures")
            check(f.stops==1,"recorder faults retain the original stop reason")
        end)
    end
    for _,mode in ipairs({"refused","throw","status"}) do
        case(function()
            local f=context_fixture()
            f.terminal_refused=mode=="refused";f.terminal_error=mode=="throw" and {} or nil
            f.recorder_stop=mode=="status"
            local snapshot={phase="following",bike_authority=true,cleanup_pending=true,cleanup_unknown=false}
            -- No ride or mounted_pose row: no later append may accidentally mask
            -- a failure to propagate the terminal recorder's own result/status.
            f.context:after_step(snapshot)
            check(#f.terminals==1 and f.terminals[1]==snapshot and #f.rows==0,
                "after_step passes the copied Core snapshot once without inventing diagnostic rows")
            check(f.context:status().stop_requested and f.stops==1,
                "terminal refusal, exception or recorder stop status requests deferred stop in this step")
        end)
    end
    for _,mode in ipairs({"accepted","refused","throw","no_snapshot"}) do
        case(function()
            local f=context_fixture()
            local snapshot={phase="draining",cleanup_pending=true,cleanup_unknown=true,bike_authority=false,
                ride={force_pending=true,pending_count=1,unknown=false}}
            if mode=="no_snapshot" then snapshot=nil end
            if mode=="refused" then f.interrupt_result=table.pack(false,"emergency summary already attempted",nil) end
            if mode=="throw" then f.interrupt_error={marker="interrupt writer failure"} end
            local out=table.pack(pcall(f.context.interrupt,f.context,snapshot))
            local result=f.interrupt_result or table.pack(true,nil,"constructed interrupt")
            local expected=f.interrupt_error and table.pack(false,f.interrupt_error)
                or table.pack(true,table.unpack(result,1,result.n))
            tuple(out,expected,"interrupt delegates the exact recorder result or error")
            check(#f.interrupts==1,"one interrupted unload causes one recorder delegation without retry")
            tuple(f.interrupts[1],table.pack(snapshot),"interrupt preserves the supplied Core snapshot, including absent snapshot")
            check(#f.flushes==0 and #f.terminals==0 and #f.rows==0,
                "interrupt delegation cannot advance normal flush or fabricate a terminal witness")
        end)
    end
    for _,spec in ipairs({
        {name="accepted",values=table.pack(true),acknowledged=true},
        {name="refused",values=table.pack(false,"busy"),acknowledged=false},
        {name="throw",thrown={marker="ACK exception"}},
        {name="true_nil",values=table.pack(true,nil)},
        {name="true_extra",values=table.pack(true,"unexpected","tail")},
        {name="false_only",values=table.pack(false)},
        {name="false_extra",values=table.pack(false,"busy",nil)},
        {name="empty",values=table.pack()},
        {name="nil_result",values=table.pack(nil,"unknown")},
    }) do
        case(function()
            local f=context_fixture();local calls=0;local body={};local sequence="0000000000000011"
            local s=Services.wrap({world={physics={acknowledge=function(...)
                calls+=1;tuple(table.pack(...),table.pack(body,sequence),"ACK retains exact original ownership")
                if spec.thrown then error(spec.thrown,0) end
                return table.unpack(spec.values,1,spec.values.n)
            end}}},f.context)
            local out=table.pack(pcall(s.world.physics.acknowledge,body,sequence))
            local expected=spec.thrown and table.pack(false,spec.thrown)
                or table.pack(true,table.unpack(spec.values,1,spec.values.n))
            tuple(out,expected,"ACK "..spec.name.." preserves the SDK result tuple/error")
            check(calls==1 and #f.rows==1 and f.rows[1].kind=="ack","each SDK ACK attempt is observed once without retry")
            local row=f.rows[1].payload
            local raw_result
            if not spec.thrown and type(spec.values[1])=="boolean" then raw_result=spec.values[1] end
            check(row.sequence==sequence and row.call=="world.physics.acknowledge" and row.call_ok==(spec.thrown==nil)
                and row.arity==(spec.thrown and 0 or spec.values.n) and row.result==raw_result,
                "ACK diagnostics preserve original sequence, raw boolean result and exact result arity")
            check(row.acknowledged==spec.acknowledged,
                "only canonical ACK acceptance or refusal creates a known acknowledged flag")
        end)
    end
    for _,mode in ipairs({"expected","extra_argument","extra_joint","extra_field","filled_place","wrong_weight",
        "different_error","malformed_result"}) do
        case(function()
            local f=context_fixture();local calls=0
            local joints={[49]={place={}}};local weight=2
            local message="place has a position, a rotation or both"
            if mode=="extra_joint" then joints[50]={} end
            if mode=="extra_field" then joints[49].unexpected=true end
            if mode=="filled_place" then joints[49].place.position=vector.create(0,0,0) end
            if mode=="wrong_weight" then weight=1 end
            if mode=="different_error" then message="weight must be between zero and one" end
            local args=mode=="extra_argument" and table.pack(joints,weight,nil) or table.pack(joints,weight)
            local s=Services.wrap({skater={pose=function(...)
                calls+=1;tuple(table.pack(...),args,"capability query retains its exact joint/weight tuple")
                if mode=="malformed_result" then return false,message end
                error(message,0)
            end}},f.context)
            local out=table.pack(pcall(s.skater.pose,table.unpack(args,1,args.n)))
            local expected=mode=="malformed_result" and table.pack(true,false,message) or table.pack(false,message)
            tuple(out,expected,"capability observation forwards the actual SDK result untouched")
            check(calls==1 and #f.rows==1 and f.rows[1].kind=="pose","one capability query produces one evidence row")
            if mode=="expected" then
                check(not f.context:status().stop_requested and f.stops==0 and f.rows[1].payload.state=="capability_probe",
                    "only the exact empty-place validator exception keeps admission available")
            else
                check(f.context:status().stop_requested and f.stops==1,
                    "similar arguments, another exception or a returned refusal cannot masquerade as capability success")
            end
        end)
    end
    case(function()
        local f=context_fixture();local context=f.context
        local snapshot={phase="following",bike_authority=true,cleanup_pending=true,cleanup_unknown=false,
            ride={force_pending=true,unknown=false,pending_count=1,pending_commands={{sequence="0000000000000001",serial="0000000000000002"}}},
            mounted_pose={qualified=true,sends=1,stopped=false},
            last_source_step={generation=1,input_ok=true,phase="ready",sample={sequence="0000000000000003",packet=7}}}
        context:observe_service("time.now",table.pack(),table.pack(true,1000))
        context:after_step(snapshot)
        check(#f.rows==3 and #f.terminals==1,"the first Core snapshot records force, pose and source projections")
        context:observe_service("time.now",table.pack(),table.pack(true,1016))
        context:after_step(snapshot)
        check(#f.rows==3 and #f.terminals==2,"wall time alone cannot duplicate cached Core projections")
        snapshot.ride.force_pending=false;snapshot.ride.pending_count=0;snapshot.ride.pending_commands={};snapshot.ride.acknowledged=1
        context:observe_service("time.now",table.pack(),table.pack(true,1032))
        context:after_step(snapshot)
        local changed=f.rows[#f.rows]
        check(#f.rows==4 and #f.terminals==3 and changed.kind=="force_pending" and changed.payload.force_pending==false
            and changed.payload.unknown==false and changed.payload.pending_count==0 and changed.payload.acknowledged==1,
            "late settled debt and explicit false fields produce exactly one changed projection")
        check(changed.payload.at_ms==1032 and f.rows[1].payload.force_pending==true,
            "changed debt gets its current timestamp without rewriting earlier evidence")
        local sample={serial="0000000000000004"}
        context:observe_service("world.physics.read",table.pack("body"),table.pack(true,sample))
        context:observe_service("world.physics.read",table.pack("body"),table.pack(true,sample))
        check(#f.rows==6 and f.rows[5].kind=="body" and f.rows[6].kind=="body",
            "cached status suppression never hides two actual SDK reads of the same sample")
        check(not context:status().stop_requested and f.stops==0,"unchanged diagnostics and settled debt do not revoke healthy admission")
    end)
    case(function()
        local Stage=require("./hop_force_stage")
        local Base=require("./force_stage")
        local f=context_fixture()
        Context.bind(f.context)
        check(pcall(Context.bind,context_fixture().context)==false,"a second context cannot replace the bound owner")
        local stage,base=Stage.new(),Base.new()
        check(table.isfrozen(stage) and stage.hop_policy==base.hop_policy and table.isfrozen(stage.tuning),"force observer retains the original policy and frozen tuning")
        for i=1,3 do check(stage.tuning.gravity[i]==base.tuning.gravity[i],"force observer retains authored gravity") end
        check(pcall(Stage.new,{})==false,"force observer preserves the zero-argument constructor contract")
        local folded,controls={},{}
        local out=table.pack(stage:preview(0,folded,{}, {},controls))
        check(out.n==2 and out[1].valid==false and out[1].issue=="unsupported_step" and type(out[2])=="table",
            "the actual force stage returns its invalid model and opaque candidate unchanged")
        tuple(f.preview_args,table.pack(0,folded,controls,out[1],out[2]),"the observer receives the very model and candidate returned to Ride")
        f.preview_refused=true
        out=table.pack(stage:preview(0,folded,{}, {},controls))
        check(out.n==2 and out[1]==f.preview_args[4] and out[2]==f.preview_args[5],
            "guard refusal cannot substitute a different preview or candidate")
        check(f.context:status().stop_requested and f.stops==1,"force observer refusal revokes only later publication")
    end)
    case(function()
        local touched=0
        local forbidden=setmetatable({}, {__index=function() touched+=1;error("cold public runtime resolved an SDK API",0) end})
        local owner=Runtime.new(forbidden)
        check(owner:request_mount(0)==false,"public mounting remains closed before any startup work")
        owner:status();owner:score_feed();owner:request_stop("cold");owner:unload()
        check(touched==0,"cold diagnostics, stop and unload remain actuator inert")
    end)
    case(function()
        local f=entry_fixture()
        check(#f.loads==0 and f.created==0 and f.calls==0,"entry registration is inert before the first tick")
        check(type(f.events.tick)=="function" and type(f.events.unload)=="function" and type(f.events.draw)=="function" and type(f.page)=="function",
            "the real entry registers only its ordinary event/menu owners")
        f.prepare();f.ready=true;f.draw("hop-trial-start")
        for _=1,3 do f.tick() end
        check(f.configured.admission_enabled==false and f.runtime_options.qualification_only==false,
            "default-closed configuration reaches the injected facade without opening qualification")
        check(not f.shown["hop-trial-start"] and f.mounts==0 and f.native==0,
            "default closure permits diagnostics/cleanup but never mounts or calls a body, Follow or input actuator")
    end)
    case(function()
        local f=entry_fixture({admitted=true})
        local names={"./hop_config","./lease_identity","./catalog","./hop_guard","./hop_recorder",
            "./hop_context","./hop_services","./bike_admission","./bike_runtime"}
        for i,name in ipairs(names) do
            local before=#f.loads;f.tick()
            check(#f.loads==before+1 and f.loads[i]==name and f.created==0,
                "each preparation tick asks the injected loader for exactly its next named module")
        end
        f.tick()
        check(#f.loads==#names and f.created==1 and f.steps==0 and f.mounts==0,
            "entry construction has a separate tick after all named loads")
        check(f.writer==f.services.storage.set and f.wrapped_real==f.services and f.wrapped_context==f.bound
            and f.runtime_services==f.services and f.runtime_options.qualification_only==true,
            "entry composes the single recorder/context/services/facade owner")
        f.tick()
        check(#f.loads==#names and f.created==1 and f.steps==1 and f.last_dt==16 and f.native==0,
            "the next ordinary tick starts lifecycle stepping without reloading or reconstructing")
    end)
    case(function()
        for _,accepted in ipairs({true,false}) do
            local f=entry_fixture({admitted=true,mount_result=accepted});f.prepare()
            f.ready=true;f.tick();check(f.mounts==0,"fresh readiness alone cannot start a trial")
            f.draw("hop-trial-start");f.ready=false;local steps=f.steps;f.tick()
            check(f.mounts==0 and f.steps==steps+1,"an explicit start waits for actual Admission menu/input facts while lifecycle ticks continue")
            f.ready=true;steps=f.steps;f.tick()
            check(f.mounts==1 and f.mount_slot==0 and f.steps==steps,"one freshly ready tick hands off exactly one mount request")
            f.draw("hop-trial-start");f.tick();f.tick()
            check(f.mounts==1 and not f.shown["hop-trial-start"],"accepted or refused mount consumes the entry attempt without retry")
            check(f.native==0,"entry-control mocks never stand in for native qualification")
        end
        local expired=entry_fixture({admitted=true});expired.prepare();expired.draw("hop-trial-start");expired.tick()
        expired.now+=60000;expired.tick();expired.ready=true;expired.draw("hop-trial-start");expired.tick()
        check(expired.mounts==0 and expired.stops==1 and not expired.shown["hop-trial-start"],
            "an expired readiness window cancels the explicit intent without rearming")
    end)
    case(function()
        local f=entry_fixture({admitted=true});f.prepare();f.ready=true;f.draw("hop-trial-start");f.tick()
        f.draw("hop-trial-stop");local steps=f.steps;f.tick();f.tick()
        check(f.stops==1 and f.steps==steps+2 and f.mounts==1,"explicit Stop sends one facade stop and continues ordinary cleanup steps")
        f.now+=1500;f.tick();f.now+=20001;f.tick()
        check(f.stops==1 and f.steps==steps+4 and f.flushes==0 and f.interrupts==0,
            "elapsed driving/cleanup time cannot replace a terminal snapshot or stop draining unresolved following duty")
        f.snapshot={phase="done",bike_cleanup_complete=true,bike_authority=false,cleanup_pending=false,
            cleanup_unknown=false,startup={pending=false},stop_latched=true}
        f.tick()
        check(f.steps==steps+5 and f.flushes==1 and f.interrupts==0 and f.flush_gate.inactive and f.flush_gate.terminal,
            "a later injected facade snapshot supplies the terminal witness for ordinary evidence flush")
    end)
    case(function()
        local cold=entry_fixture({admitted=true});cold.events.unload();cold.tick()
        check(#cold.loads==0 and cold.unloads==0 and cold.flushes==0 and cold.interrupts==0,
            "unload before construction cannot invent an evidence writer or lifecycle owner")
        for _,mode in ipairs({"default","early","done_unflushed","done_flushed","status_error"}) do
            local f=entry_fixture({admitted=mode~="default"});f.prepare()
            if mode=="early" or mode=="status_error" then
                f.snapshot={phase="following",bike_authority=true,cleanup_pending=true,cleanup_unknown=true,startup={pending=false}}
            elseif mode=="done_unflushed" or mode=="done_flushed" then
                f.snapshot={phase="done",bike_cleanup_complete=true,bike_authority=false,cleanup_pending=false,cleanup_unknown=false}
            end
            f.flushed=mode=="done_flushed"
            if mode=="status_error" then f.status_error={marker="final Core status unavailable"} end
            f.trace={};f.events.unload()
            local first={}
            for i,name in ipairs(f.trace) do if not first[name] then first[name]=i end end
            check(first["context.stop"]<first["bike.unload"] and first["bike.unload"]<first["bike.status"],
                "unload revokes first, then calls the injected facade unload, then obtains its final status")
            local expected=mode=="done_flushed" and 0 or 1
            check(f.unloads==1 and f.stops==0 and f.flushes==0 and f.interrupts==expected,
                "unload selects at most one interrupt writer, never a normal flush or duplicate Stop")
            if expected==1 then
                check(first["writer.interrupt"]>first["bike.status"],"emergency evidence is attempted only after facade cleanup/status")
                if mode=="status_error" then
                    tuple(f.interrupted,table.pack(nil),"unavailable final status remains absent in the emergency record")
                    check(first["context.after_step"]==nil,"a failed final status cannot fabricate terminal diagnostics")
                else
                    check(first["context.after_step"]>first["bike.status"] and first["context.after_step"]<first["writer.interrupt"],
                        "the final actual snapshot is recorded before the selected emergency writer")
                    tuple(f.interrupted,table.pack(f.snapshot),"interrupt receives the exact final snapshot")
                end
            end
            local steps=f.steps;local loads=#f.loads;f.tick()
            check(f.steps==steps and #f.loads==loads and f.native==0,"unloaded entry never restarts stepping, loading or native actions")
        end
    end)
    case(function()
        local f=entry_fixture()
        local cold=f.overlay()
        check(#cold==2 and cold[1].value:find("PREPARING",1,true)~=nil,"cold entry draws its cached preparation cue")
        f.prepare();local rows=f.overlay()
        check(rows[1].value:find("CLOSED",1,true)~=nil,"default-closed entry draws no mount cue")
        local bytes=0
        for _,row in ipairs(rows) do
            bytes+=#row.value
            check(row.value:find("[^ -~]")==nil,"overlay text is printable ASCII")
            check(table.isfrozen(row.style) and row.style==cold[1].style,"draw reuses the frozen style created at entry")
        end
        check(#rows==2 and bytes<=180 and rows[1].point==vector.create(24,40,0)
            and rows[2].point==vector.create(24,64,0),"overlay has two bounded text calls at fixed positions")
        local before={calls=f.calls,loads=#f.loads,trace=#f.trace,steps=f.steps,mounts=f.mounts,
            writes=f.storage_writes,reads=f.storage_reads,native=f.native,flushes=f.flushes}
        f.now+=10000;local again=f.overlay();f.overlay()
        check(again[1].value==rows[1].value and again[2].value==rows[2].value,"draw cannot recompute cached text from a changed clock")
        check(f.calls==before.calls and #f.loads==before.loads and #f.trace==before.trace and f.steps==before.steps
            and f.mounts==before.mounts and f.storage_writes==before.writes and f.storage_reads==before.reads
            and f.native==before.native and f.flushes==before.flushes,
            "draw performs no clock, status, import, storage, lifecycle, body, Follow or input call")
        check(f.guard_arg==f.guard,"overlay samples the same guard owned by the trial context")
    end)
    case(function()
        local f=entry_fixture({admitted=true});f.prepare()
        f.snapshot={phase="following",publish_ms=900,lease_until_ms=5000,wall_ms=1000}
        f.tick();local rows=f.overlay()
        check(rows[1].value:find("H1 FOLLOWING sampled / await reviewed .25 gesture",1,true)~=nil
            and rows[2].value:find("Sampled window 1400 ms",1,true)~=nil,"H1 cue uses the sampled publication window")
        f.snapshot.lease_until_ms=1200;f.tick();rows=f.overlay()
        check(rows[2].value:find("Sampled window 50 ms",1,true)~=nil,"earlier lease minus 150 ms controls the sampled window")
        f.snapshot.wall_ms=1100;f.tick();rows=f.overlay()
        check(rows[2].value:find("Sampled window 0 ms",1,true)~=nil and rows[1].value:find("window expired; neutral",1,true)~=nil,
            "expired sampled window has no gesture cue")
        f.snapshot.wall_ms=1000;f.snapshot.lease_until_ms=5000;f.tick();rows=f.overlay()
        f.snapshot.publish_ms=nil;f.hop_attempts=1;local trace=#f.trace;local cached=f.overlay()
        check(cached[1].value==rows[1].value and cached[2].value==rows[2].value and #f.trace==trace,
            "draw never resamples mutated lifecycle or guard state between ticks")
    end)
    case(function()
        local f=entry_fixture({admitted=true});f.prepare()
        local invalid={
            {phase="following",lease_until_ms=5000,wall_ms=1000},
            {phase="following",publish_ms=900,wall_ms=1000},
            {phase="following",publish_ms=900,lease_until_ms=5000},
            {phase="following",publish_ms=-1,lease_until_ms=5000,wall_ms=1000},
            {phase="following",publish_ms=900,lease_until_ms=0/0,wall_ms=1000},
            {phase="following",publish_ms=900,lease_until_ms=math.huge,wall_ms=1000},
            {phase="following",publish_ms=900,lease_until_ms=5000,wall_ms=899},
            {phase="following",publish_ms=900,lease_until_ms=149,wall_ms=1000},
            {phase="following",publish_ms=9007199254740991,lease_until_ms=9007199254740991,wall_ms=9007199254740991},
            {phase="following",publish_ms=900,lease_until_ms=5000,wall_ms=1000,clock_unknown=true},
        }
        for _,snapshot in ipairs(invalid) do
            f.snapshot=snapshot;f.tick();local rows=f.overlay()
            check(rows[1].value:find("deadline unknown; neutral",1,true)~=nil
                and rows[2].value:find("Sampled window unknown",1,true)~=nil,"invalid or missing sampled time cannot manufacture a countdown")
        end
    end)
    case(function()
        local f=entry_fixture({admitted=true});f.prepare()
        f.snapshot={phase="following",publish_ms=900,lease_until_ms=5000,wall_ms=1000}
        for _,outcome in ipairs({"accepted","refused","unknown","exception"}) do
            f.hop_attempts=1;f.hop_outcome=outcome;f.tick();local rows=f.overlay()
            check(rows[1].value:find("attempt consumed / no retry",1,true)~=nil
                and rows[1].value:find("await",1,true)==nil and rows[1].value:find("success",1,true)==nil,
                "any attempted native hop consumes the cue without inferring success or offering retry")
            check(#rows[1].value+#rows[2].value<=180,"consumed attempt cue retains its text budget")
        end
    end)
    case(function()
        local f=entry_fixture({admitted=true,phase="P0"});f.prepare()
        check(f.overlay()[1].value:find("READY",1,true)~=nil,"prepared admitted trial waits for explicit menu intent")
        f.draw("hop-trial-start");f.tick()
        check(f.overlay()[1].value:find("WAIT",1,true)~=nil,"closed readiness shows a cached waiting cue")
        f.snapshot={phase="following",publish_ms=900,lease_until_ms=5000,wall_ms=1000};f.tick()
        check(f.overlay()[1].value:find("P0 FOLLOWING sampled / no hop",1,true)~=nil,"P0 never invites a hop")
        f.draw("hop-trial-stop");f.storage_fault=true;f.tick();local rows=f.overlay()
        check(rows[1].value:find("STOP/CLEANUP",1,true)~=nil and rows[2].value:find("evidence cache FAULT",1,true)~=nil,
            "stop and evidence fault remain visible while ordinary cleanup continues")
        f.storage_fault=false;f.snapshot={phase="done",bike_cleanup_complete=true,stop_latched=true};f.tick();rows=f.overlay()
        check(rows[2].value:find("evidence cache complete",1,true)~=nil and rows[2].value:find("unqualified",1,true)~=nil,
            "a complete host cache does not turn the trial into native qualification")
        f.events.unload();check(#f.overlay()==0,"unload stops drawing without restarting cleanup or evidence writes")
    end)
    case(function()
        -- One real mount lifecycle per module VM: another Runtime.new would not
        -- reset the facade or Core attempt latch. This measures scheduling only.
        local f=ready_services();local watch=observer();local s=Services.wrap(f.services,watch.context)
        local owner=Runtime.new(s,{qualification_only=true})
        check(f.calls==0,"real facade construction performs no SDK service call")
        check(owner:request_mount(0),"grounded on-foot admission enters the real staged facade")
        local first=owner:status()
        check(first.startup.pending and not first.startup.core_ready and first.startup.loaded==1,
            "only synchronous admission has been scheduled before the first lifecycle step")
        local state,constructed,prepared,handoff
        for tick=1,40 do
            local before=owner:status();local calls=f.calls
            owner:score_feed();owner:status()
            check(f.calls==calls,"reading facade status/feed never advances scheduling or polls the SDK")
            f.now+=16;state=owner:step(16)
            local delta=state.startup.loaded-before.startup.loaded
            check(delta==0 or delta==1,"a facade step schedules at most one named module")
            check(state.startup.work_this_tick==true,"every step begun with pending startup reports its scheduling work")
            if not before.startup.core_ready and state.startup.core_ready then
                constructed=tick
                check(delta==0 and before.startup.last_module=="./bike_runtime_core",
                    "Core construction occurs after its module-scheduling step")
            end
            if not before.startup.backend_ready and state.startup.backend_ready then
                prepared=tick
                check(constructed~=nil and tick==constructed+1 and delta==0,
                    "backend preparation has a separate step after Core construction")
            end
            if not state.startup.pending then
                handoff=tick
                check(prepared~=nil and tick==prepared+1 and before.startup.backend_ready,
                    "mount handoff has its own step after backend preparation")
                break
            end
        end
        check(constructed~=nil and prepared~=nil and handoff~=nil and state.phase=="armed",
            "the actual facade and Core reach armed state while menus keep acquisition closed")
        check(f.native==0 and f.prepares==0 and f.storage_reads==1 and f.storage_writes>0,
            "startup preserves nil marker/void storage contracts and makes no preparation or acquisition call")
        local original_deadline=state.mount_deadline_ms
        f.on_prepare=function()
            if f.prepares==1 then return false,"native body producer setup pending; call prepare again explicitly" end
            return true
        end
        f.menu_open=false;f.now+=16;state=owner:step(16)
        check(state.native_preparation.phase=="pending" and f.prepares==1 and f.native==0
            and not state.call_counts["source.arm"],"actual wrapped Core waits without Source, floor or body acquisition")
        f.now+=400;state=owner:step(400)
        check(not state.stop_latched and f.prepares==1 and f.native==0 and state.mount_deadline_ms==original_deadline,
            "deferred setup gap makes no extra preparation call and cannot reset the original deadline")
        f.now+=16;state=owner:step(16)
        local ready_at=state.native_preparation.ready_ms
        check(state.native_preparation.phase=="ready" and f.prepares==2 and f.native==0
            and not state.call_counts["source.arm"],"observed preparation yields before any selected Source acquisition")
        local preparation_rows=0
        for _,row in ipairs(watch.seen) do
            if row.path=="world.physics.prepare" then preparation_rows+=1 end
        end
        check(preparation_rows==2,"the actual SDK proxy observes both calls without an extra readiness poll")
        f.lease_calls=0
        function f.services.input.lease()
            f.calls+=1;f.lease_calls+=1;f.first_lease_prepares=f.prepares;f.first_lease_at=f.now
            return nil,"constructed lease unavailable"
        end
        for _=1,60 do
            if f.lease_calls>0 then break end
            f.now+=16;state=owner:step(16)
        end
        check(f.lease_calls==1 and f.first_lease_prepares==2 and f.first_lease_at>=ready_at+600
            and state.call_counts["source.arm"]==1 and f.native==0,
            "the real Source starts only after preparation and its later readiness dwell; refused lease acquires no body")
        check(state.mount_deadline_ms==original_deadline and f.prepares==2,
            "Source admission does not replay preparation or restart the original mount deadline")
        local other=Runtime.new(s,{qualification_only=true});local calls=f.calls
        check(other:request_mount(0)==false and f.calls==calls,"a second owner cannot reset the consumed VM attempt")
        check(owner:request_stop("constructed scheduling complete"),"the original owner accepts cleanup stop")
        state=owner:unload()
        check(state.unloaded and f.native==0,"stopping before acquisition unloads without inventing native debt")
    end)
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
-- Shared constructed services only; each consuming suite owns a fresh VM.
Tests.ready_services=ready_services
return Tests

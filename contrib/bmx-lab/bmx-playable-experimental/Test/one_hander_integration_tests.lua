-- One focused integration trace over the real Ride and selected-source mapper.
-- Every SDK/body/ray/receipt below is CONSTRUCTED; this is not game evidence.
local Fixtures=require("./ride_runtime_tests")
local Identity=require("./lease_identity")
local BuildCore=require("./core_session_renewable_fixture")
local MP=require("./mounted_pose")
local Tests={}
local function copy(v)
    if type(v)~="table" then return v end
    local out={} for k,c in pairs(v) do out[k]=copy(c) end return out
end
local function inc(v)
    local out,carry={},1
    for i=#v,1,-1 do
        local n=string.byte(v,i)-48+carry
        out[i]=string.char(48+n%10);carry=n>=10 and 1 or 0
    end
    return (carry==1 and "1" or "")..table.concat(out)
end
local function fixture()
    -- Explicit false bypasses the old fixture's optional observed-step mock;
    -- the new accepted-step adapter is the actual one constructed by Ride.
    local f=Fixtures.fixture({models={tricks=false}})
    local controls=f.mapping.controls
    function f.mapping:controls(...)
        local out=controls(self,...);f.mapped_actions=out.actions;return out
    end
    local decode=f.contact.decode
    function f.contact.decode(...)
        local out=decode(...)
        -- Match current planar Contact.decode metadata; support itself stays
        -- unknown here. Ride alone derives its distinct ray support record.
        out.status="available";out.query.accounting_known=true
        out.query.measurements_complete=true
        return out
    end
    f.native={};f.rows={};f.commands={};f.next_sequence="9007199254745001"
    local function refresh()
        for _,r in ipairs(f.native) do
            if r.outcome=="queued" and Identity.compare(f.serial,r.produced)>=0 then r.outcome="applied" end
            if r.outcome=="applied" and not r.successor and Identity.compare(f.serial,r.produced)>0 then
                r.successor=copy(f.sample())
            end
        end
    end
    function f.api.submit(epoch,command)
        refresh()
        assert(epoch==f.read.epoch,"constructed admission names current read epoch")
        if f.refusal then return false,f.refusal end
        f.next_sequence=inc(f.next_sequence)
        local r={sequence=f.next_sequence,requested=f.serial,produced=inc(f.serial),outcome="queued"}
        f.rows[r.sequence]=r;f.native[#f.native+1]=r;f.commands[#f.commands+1]=copy(command)
        return true,nil,r.sequence
    end
    function f.api.receipt(sequence)
        refresh()
        local r=f.rows[sequence];assert(r,"retained exact constructed sequence")
        local applied=r.outcome=="applied"
        return {sequence=r.sequence,requested_serial=r.requested,produced_serial=applied and r.produced or "0",
            outcome=r.outcome,force_attempted=applied,torque_attempted=applied,retained=false,quarantined=false,
            cleanup_disposition="none",successor=r.successor}
    end
    function f.api.acknowledge(sequence)
        refresh();assert(f.native[1] and f.native[1].sequence==sequence,"oldest exact sequence only")
        table.remove(f.native,1);return true
    end
    function f.tick(grounded,selection)
        if f.started then f.advance() end
        f.started=true;f.clear=not grounded
        local tail=selection=="tail_right" or selection=="tail_left"
        local foot_left,foot_right=selection=="one_foot_left",selection=="one_foot_right"
        f.pad.right_x=(selection=="tail_right" or selection=="one_hand_right" or foot_right) and 1 or (selection=="tail_left" or selection=="one_hand_left" or foot_left) and -1 or 0
        f.pad.right_y=selection=="bar_left" and -1 or 0
        f.pad.buttons.lb=selection=="bar_left" or selection=="one_hand_left";f.pad.buttons.rb=selection=="one_hand_right"
        f.pad.left_trigger=(tail or foot_left) and 1 or 0;f.pad.right_trigger=(tail or foot_right) and 1 or 0
        return f.observe()
    end
    return f
end
local function core_fixture(session,options)
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
            unknown=false,stop_requested=self.stopped,submitted=0,acknowledged=0,presentation_pose=f.presented_pose} end
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
        function poser:tick(_,input) f.pose_input=input;return {ok=true,sent=false,state=self.state} end
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

-- One accepted-step pose only: existing catalog/motions ID36, One Hander Left.
-- Existing constructed real Ride/mapper and Core wrapper fixtures are reused.
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not same(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function fields(t) local n=0 for _ in pairs(t) do n+=1 end return n end
local function distance2(a,b)
    local n=0 for i=1,3 do n+=(a[i]-b[i])^2 end return n
end
local function normal(pose)
    return {barspin=0,tailwhip=0,movement_bike_pitch=0,movement_bike_roll=0,barspin_release=0,
        tailwhip_release=0,release_left_hand=0,release_right_hand=0,release_left_foot=0,release_right_foot=0,
        steer=pose.steer or 0,crank_phase=pose.crank_phase or 0}
end
function Tests.run()
    local cases,assertions=1,0
    local function check(v,why) assertions+=1;assert(v,why) end
    local f=fixture()
    local neutral=f.tick(true)
    check(not neutral.stop_requested and fields(neutral.presentation_pose)==8,"normal riding keeps eight fields")
    f.tick(false)
    local prior=f.ride:status()
    f.refusal="force_pipeline_full"
    local refused=f.tick(false,"one_hand_left")
    check(f.mapped_actions.movement==36 and f.mapped_actions.handlebar=="none" and f.mapped_actions.tailwhip=="none"
        and f.pad.buttons.lb and not f.pad.buttons.rb and f.pad.right_x==-1
        and f.pad.left_trigger==0 and f.pad.right_trigger==0,
        "actual existing LB plus right-stick-left selects ID36 without new bindings")
    check(not refused.stop_requested and refused.presentation_pose==prior.presentation_pose
        and refused.model.accepted_barspin.revision==prior.model.accepted_barspin.revision,
        "refused pose candidate changes no accepted release/articulation state")
    f.refusal=nil
    local held=f.tick(false,"one_hand_left")
    check(not held.stop_requested and held.presentation_pose.release_left_hand==nil and fields(held.presentation_pose)==8,
        "held refused selector cannot replay a one-hander")
    f.tick(false)
    local start=f.tick(false,"one_hand_left")
    check(not start.stop_requested and start.presentation_pose.release_left_hand==nil,
        "fresh accepted selection starts pose at sample end")
    local posing
    for _=1,14 do posing=f.tick(false,"one_hand_left");check(not posing.stop_requested,"bounded held authored pose remains running") end
    local target=posing.presentation_trick.visual_targets
    check(posing.presentation_pose.release_left_hand==1 and target.release_left_hand==1,
        "existing .18 second entry and release-mask1 reach authored left-hand release")
    check(posing.presentation_pose.barspin==0 and posing.presentation_pose.tailwhip==0
        and posing.presentation_pose.release_right_hand==nil and posing.presentation_pose.barspin_release==nil
        and posing.presentation_pose.tailwhip_release==nil and posing.presentation_pose.release_left_foot==nil
        and posing.presentation_pose.release_right_foot==nil,"only the authored left hand is released")
    check(not posing.model.accepted_barspin.rotation_reserved,"pose adds no force/rotation reservation")
    check(posing.presentation_trick.accepted_sequence==posing.model_history.sequence,
        "hand target names the exact accepted advancing force command")
    local c=core_fixture(true);c.start()
    local function capture(pose)
        c.presented_pose=pose;c.pose_input=nil
        local status=c.tick(17)
        check(status.phase=="following" and c.pose_input~=nil,"unchanged actual Core forwards accepted pose to mounted poser")
        return c.pose_input
    end
    local function plan(input)
        local out,why=MP.compose(input);check(out~=nil,"existing mounted pose: "..tostring(why));return out
    end
    local input=capture(posing.presentation_pose)
    check(input.articulation.release_left_hand==1 and input.articulation.release_right_hand==0
        and input.articulation.barspin==0 and input.articulation.tailwhip==0,"unchanged Core forwards only accepted left release")
    local moved=plan(input)
    local base=plan({bike=input.bike,articulation=normal(posing.presentation_pose)})
    check(distance2(moved.targets.wrists[1],base.targets.wrists[1])>1e-8,
        "existing mounted_pose places the authored left hand away from its grip")
    check(same(moved.targets.wrists[2],base.targets.wrists[2]) and same(moved.targets.ankles,base.targets.ankles),
        "right hand and both foot target points remain at existing contacts")
    local recovering=f.tick(false)
    check(recovering.presentation_pose.release_left_hand==1,"neutral starts existing recover phase at sample end")
    local revision=recovering.model.accepted_barspin.revision
    local kept=recovering.presentation_pose
    f.refusal="force_pipeline_full"
    local recovery_refusal=f.tick(false,"one_hand_left")
    check(not recovery_refusal.stop_requested and recovery_refusal.presentation_pose==kept
        and recovery_refusal.model.accepted_barspin.revision==revision,
        "refused recovery/busy selection holds the previous accepted release")
    f.refusal=nil
    local resumed=f.tick(false,"one_hand_left")
    local p=f.read.seconds/.12;local expected=1-p*p*(3-2*p)
    check(math.abs(resumed.presentation_pose.release_left_hand-expected)<1e-9,
        "next acceptance advances one .12 second recover step without filling refused time")
    local finished
    for _=1,10 do
        local row=f.tick(false,"one_hand_left")
        check(not row.stop_requested,"bounded accepted recovery continues")
        if row.presentation_pose.release_left_hand==nil then finished=row;break end
    end
    check(finished~=nil and fields(finished.presentation_pose)==8,"existing recovery returns to normal eight-field pose")
    for _=1,3 do
        local row=f.tick(false,"one_hand_left")
        check(row.presentation_pose.release_left_hand==nil,"held busy/refused selection cannot start a late pose")
    end
    f.tick(false);f.tick(false,"one_hand_left")
    local fresh=f.tick(false,"one_hand_left")
    check((fresh.presentation_pose.release_left_hand or 0)>0,"new neutral/fresh source selection can start again")
    local commands=#f.commands
    local stopped=f.ride:stop("constructed switch or fall recovery")
    check(stopped.stop_requested and stopped.presentation_trick==nil and stopped.presentation_pose.release_left_hand==nil
        and fields(stopped.presentation_pose)==8,"existing stop/switch/recovery clears the sole authored hand release")
    check(same(capture(stopped.presentation_pose).articulation,normal(stopped.presentation_pose)),"unchanged Core restores normal contacts")
    check(#f.commands==commands,"pose cleanup adds no physics command")
    check(posing.presentation_trick.realized==false and posing.presentation_trick.completion_qualified==false
        and target.native_collision_contact==false and target.landing_quality_available==false
        and posing.presentation_trick.score==nil and posing.presentation_trick.model_events==nil,
        "pose never becomes physical completion/catch/landing or awarded score")
    local bar=fixture();bar.tick(true);bar.tick(false);bar.tick(false,"bar_left")
    -- The bar turns in .31 s and the tail in .34 s since the full hop came down to .61 m (.45 and .55 before).
    local b=bar.tick(false);local bp=bar.read.seconds/.31
    check(not b.stop_requested and math.abs(b.presentation_pose.barspin+2*math.pi*bp*bp*(3-2*bp))<1e-9,
        "existing barspin equation remains unchanged when one-hander is idle")
    local tail=fixture();tail.tick(true);tail.tick(false);tail.tick(false,"tail_right")
    local t=tail.tick(false);local tp=tail.read.seconds/.34
    check(not t.stop_requested and math.abs(t.presentation_pose.tailwhip-2*math.pi*tp*tp*(3-2*tp))<1e-9,
        "existing tailwhip equation remains unchanged when one-hander is idle")
    -- Four more constructed adapter paths; the original complete left trace above
    -- remains the compatibility oracle. Neither side proves physical catch/landing.
    local function one_event(row)
        local p=row.presentation_trick
        if p and p.authored_events then
            for _,e in ipairs(p.authored_events) do if e.channel=="one_hander" then return e end end
        end
        return nil
    end
    local function right_full()
        local r=fixture();r.tick(true);r.tick(false)
        local selected=r.tick(false,"one_hand_right")
        check(not selected.stop_requested and r.mapped_actions.movement==42 and r.pad.buttons.rb and not r.pad.buttons.lb
            and r.pad.right_x==1 and r.mapped_actions.handlebar=="none" and r.mapped_actions.tailwhip=="none",
            "existing RB plus right-stick-right mapping selects catalog ID42")
        check(selected.presentation_pose.release_right_hand==nil,"right selection arrives at accepted sample end")
        local held
        for _=1,12 do held=r.tick(false,"one_hand_right") end
        check(not held.stop_requested and held.presentation_pose.release_right_hand==1
            and held.presentation_pose.release_left_hand==nil and one_event(held)==nil,
            "full .18 second entry releases only the right hand without a completion event")
        return r,held
    end
    local function right_case(name,body)
        cases+=1;local ok,why=pcall(body);if not ok then error(name..": "..tostring(why),0) end
    end
    right_case("right full entry and accepted neutral recovery",function()
        local r,held=right_full()
        local received=capture(held.presentation_pose)
        check(received.articulation.release_right_hand==1 and received.articulation.release_left_hand==0,
            "existing Core forwards the right release through its existing field")
        local right_plan=plan(received)
        local right_base=plan({bike=received.bike,articulation=normal(held.presentation_pose)})
        check(distance2(right_plan.targets.wrists[2],right_base.targets.wrists[2])>1e-8
            and same(right_plan.targets.wrists[1],right_base.targets.wrists[1])
            and same(right_plan.targets.ankles,right_base.targets.ankles),
            "existing mounted pose moves the right wrist only")
        local onset=r.tick(false)
        check(onset.presentation_pose.release_right_hand==1 and one_event(onset)==nil,
            "neutral starts .12 second recovery at sample end rather than completing it")
        local completed,completion_source,count
        count=0
        for _=1,8 do
            local row=r.tick(false)
            local e=one_event(row)
            if e then completed=row;completion_source=r.input_serial;count+=1 end
        end
        check(completed~=nil and count==1,"one accepted recovery emits one right-hand completion")
        local e=one_event(completed)
        check(e.kind=="authored_pose_recovery" and e.channel=="one_hander" and e.movement_id==42
            and e.side=="right" and e.direction==nil and e.scope=="mod_authored_accepted_step",
            "right recovery preserves the existing bounded authored event schema")
        check(e.body_serial==completed.model_history.serial and e.accepted_sequence==completed.model_history.sequence
            and e.source_observation_serial==completion_source,"right event names exact accepted body/source/sequence")
        check(e.prediction_only and e.native_application=="unobserved" and e.native_application_observed==false
            and e.native_catch==false and e.native_landing==false and e.landing_quality_available==false
            and e.completion_qualified==false and table.isfrozen(e),"right authored event invents no native completion")
        check(completed.presentation_pose.release_right_hand==nil and fields(completed.presentation_pose)==8,
            "completed right recovery restores the unchanged normal pose")
        for _=1,3 do check(one_event(r.tick(false))==nil,"right completion never repeats") end
        r.ride:stop("constructed right full cleanup")
    end)
    right_case("partial right entry is not completion",function()
        local r=fixture();r.tick(true);r.tick(false);r.tick(false,"one_hand_right")
        for _=1,4 do r.tick(false,"one_hand_right") end
        check((r.ride:status().presentation_pose.release_right_hand or 0)>0,
            "partial right entry has an authored release")
        check(one_event(r.tick(false))==nil,"early neutral does not complete entry")
        local last
        for _=1,8 do last=r.tick(false);check(one_event(last)==nil,"partial recovery never fabricates a full-entry event") end
        check(last.presentation_pose.release_right_hand==nil and last.presentation_pose.release_left_hand==nil,
            "partial pose returns both hands to normal")
        r.ride:stop("constructed partial cleanup")
    end)
    right_case("busy opposite selection cannot switch or queue a hand",function()
        local r=fixture();r.tick(true);r.tick(false);r.tick(false,"one_hand_right")
        local held
        for _=1,12 do held=r.tick(false,"one_hand_left") end
        check(held.presentation_pose.release_right_hand==1 and held.presentation_pose.release_left_hand==nil,
            "opposite busy selections keep the original right side latched")
        r.tick(false)
        local count=0
        for _=1,8 do
            local row=r.tick(false,"one_hand_left");local e=one_event(row)
            check(row.presentation_pose.release_left_hand==nil,"opposite side stays gripped throughout right recovery")
            if e then count+=1;check(e.movement_id==42 and e.side=="right","recovery event retains its original side") end
        end
        check(count==1,"busy opposite selection does not replace or duplicate the right completion")
        for _=1,3 do
            local row=r.tick(false,"one_hand_left")
            check(row.presentation_pose.release_left_hand==nil and row.presentation_pose.release_right_hand==nil
                and one_event(row)==nil,"consumed opposite request cannot start later")
        end
        r.tick(false);r.tick(false,"one_hand_left")
        local fresh=r.tick(false,"one_hand_left")
        check((fresh.presentation_pose.release_left_hand or 0)>0 and fresh.presentation_pose.release_right_hand==nil,
            "new neutral then fresh selection may deliberately start the other hand")
        r.ride:stop("constructed side-change cleanup")
    end)
    right_case("refusal stop and measured recontact cancel right completion",function()
        local r=right_full();r.tick(false)
        for _=1,7 do r.tick(false) end
        local before_stop=r.ride:status()
        r.refusal="force_pipeline_full"
        local refused=r.tick(false)
        check(not refused.stop_requested and refused.presentation_pose==before_stop.presentation_pose
            and refused.model.accepted_barspin.revision==before_stop.model.accepted_barspin.revision
            and one_event(refused)==nil,"refused recovery cannot adopt its would-be completion")
        r.refusal=nil
        local commands=#r.commands
        local stopped_right=r.ride:stop("constructed switch or fall recovery")
        check(stopped_right.presentation_trick==nil and stopped_right.presentation_pose.release_right_hand==nil
            and fields(stopped_right.presentation_pose)==8 and #r.commands==commands,
            "stop clears right presentation without an extra force or completion")
        local landed=right_full()
        local ground=landed.tick(true)
        check(one_event(ground)==nil and ground.presentation_pose.release_right_hand==nil
            and ground.presentation_pose.release_left_hand==nil,"actual fixture recontact resets hand state without an airborne recovery event")
        landed.ride:stop("constructed recontact cleanup")
    end)
    -- The existing authored footer masks4/8 use the same .18/.12 pose phase.
    -- These four groups remain constructed Ride/Core/pose traces only.
    local function foot_event(row)
        local p=row.presentation_trick
        if p and p.authored_events then
            for _,e in ipairs(p.authored_events) do if e.channel=="one_footer" then return e end end
        end
        return nil
    end
    local function foot_full(side)
        local selection=side=="left" and "one_foot_left" or "one_foot_right"
        local r=fixture();r.tick(true);r.tick(false)
        local selected=r.tick(false,selection)
        check(not selected.stop_requested and r.mapped_actions.movement==(side=="left" and 66 or 72)
            and not r.pad.buttons.lb and not r.pad.buttons.rb
            and r.pad.left_trigger==(side=="left" and 1 or 0) and r.pad.right_trigger==(side=="right" and 1 or 0)
            and r.pad.right_x==(side=="left" and -1 or 1)
            and r.mapped_actions.handlebar=="none" and r.mapped_actions.tailwhip=="none",
            "existing single trigger and lateral rear stick select the exact footer catalog ID")
        check(selected.presentation_pose.release_left_foot==nil and selected.presentation_pose.release_right_foot==nil,
            "footer selection starts at accepted sample end")
        local held
        for _=1,12 do held=r.tick(false,selection) end
        local release,opposite="release_"..side.."_foot","release_"..(side=="left" and "right" or "left").."_foot"
        check(not held.stop_requested and held.presentation_pose[release]==1 and held.presentation_pose[opposite]==nil
            and held.presentation_pose.release_left_hand==nil and held.presentation_pose.release_right_hand==nil
            and held.presentation_pose.barspin==0 and held.presentation_pose.tailwhip==0 and foot_event(held)==nil,
            "full footer entry releases only the selected foot without rotation or completion")
        return r,held,selection,release,opposite
    end
    local function complete_footer(side)
        local r,held,selection,release,opposite=foot_full(side)
        local input=capture(held.presentation_pose)
        check(input.articulation[release]==1 and input.articulation[opposite]==0,
            "unchanged Core forwards the existing independent footer pose field")
        local posed=plan(input);local normal_plan=plan({bike=input.bike,articulation=normal(held.presentation_pose)})
        local index=side=="left" and 1 or 2;local other=index==1 and 2 or 1
        check(distance2(posed.targets.ankles[index],normal_plan.targets.ankles[index])>1e-8
            and same(posed.targets.ankles[other],normal_plan.targets.ankles[other])
            and same(posed.targets.wrists,normal_plan.targets.wrists),
            "existing mounted pose moves the selected ankle while the other foot and both hands retain contacts")
        local onset=r.tick(false)
        check(onset.presentation_pose[release]==1 and foot_event(onset)==nil,
            "neutral begins the existing recovery rather than completing it immediately")
        local completed,count,completion_source
        count=0
        for _=1,8 do
            local row=r.tick(false);local e=foot_event(row)
            if e then completed=row;count+=1;completion_source=r.input_serial end
        end
        check(completed~=nil and count==1,"one full adopted footer recovery emits one bounded completion")
        local e=foot_event(completed)
        check(e.kind=="authored_pose_recovery" and e.scope=="mod_authored_accepted_step" and e.channel=="one_footer"
            and e.movement_id==(side=="left" and 66 or 72) and e.side==side and e.direction==nil and e.name==nil,
            "footer event names the latched catalog ID and side without extra metadata")
        check(e.body_serial==completed.model_history.serial and e.accepted_sequence==completed.model_history.sequence
            and e.source_observation_serial==completion_source and e.catch_phase=="regrip_complete" and e.authored_completion,
            "footer event binds exact adopted completion body source sequence and phase")
        check(e.prediction_only and e.native_application=="unobserved" and e.native_application_observed==false
            and e.native_catch==false and e.native_landing==false and e.landing_quality_available==false
            and e.completion_qualified==false and table.isfrozen(e),"footer authored completion grants no physical authority")
        check(fields(completed.presentation_pose)==8 and completed.presentation_pose[release]==nil
            and completed.presentation_pose[opposite]==nil,"full footer recovery restores the unchanged normal pose")
        for _=1,3 do check(foot_event(r.tick(false))==nil,"footer completion does not repeat") end
        r.ride:stop("constructed full footer cleanup")
    end
    right_case("left footer full entry recovery and existing ankle target",function() complete_footer("left") end)
    right_case("right footer full entry recovery and existing ankle target",function() complete_footer("right") end)
    right_case("partial refused stopped and recontact footer paths never fabricate completion",function()
        local r=fixture();r.tick(true);r.tick(false);r.tick(false,"one_foot_left")
        for _=1,4 do r.tick(false,"one_foot_left") end
        check((r.ride:status().presentation_pose.release_left_foot or 0)>0,"partial footer has an authored release")
        check(foot_event(r.tick(false))==nil,"early neutral does not finish full footer entry")
        local last
        for _=1,8 do last=r.tick(false);check(foot_event(last)==nil,"partial footer recovery never emits full-entry completion") end
        check(fields(last.presentation_pose)==8,"partial footer restores the normal pose")
        r.ride:stop("constructed partial footer cleanup")
        local refused=foot_full("right");refused.tick(false)
        for _=1,7 do refused.tick(false) end
        local previous=refused.ride:status();refused.refusal="force_pipeline_full"
        local blocked=refused.tick(false)
        check(not blocked.stop_requested and blocked.presentation_pose==previous.presentation_pose
            and blocked.model.accepted_barspin.revision==previous.model.accepted_barspin.revision and foot_event(blocked)==nil,
            "refused completion candidate changes no accepted footer phase or event")
        refused.refusal=nil
        local count=#refused.commands;local stopped=refused.ride:stop("constructed switch or fall recovery")
        check(stopped.presentation_trick==nil and fields(stopped.presentation_pose)==8 and #refused.commands==count,
            "stop clears footer presentation and candidate without an extra force command")
        local landed=foot_full("left");local ground=landed.tick(true)
        check(foot_event(ground)==nil and fields(ground.presentation_pose)==8,
            "measured fixture recontact resets footer state without an airborne recovery event")
        landed.ride:stop("constructed footer recontact cleanup")
    end)
    right_case("footer side is latched and busy hand or turn requests never queue",function()
        local r=foot_full("left");r.tick(false)
        local count=0
        for _=1,8 do
            local row=r.tick(false,"one_foot_right");local e=foot_event(row)
            check(row.presentation_pose.release_right_foot==nil,"opposite footer side stays held during original recovery")
            if e then count+=1;check(e.movement_id==66 and e.side=="left","footer event retains its original latched side") end
        end
        check(count==1,"opposite busy footer selection neither replaces nor duplicates the original completion")
        for _=1,3 do
            local row=r.tick(false,"one_foot_right")
            check(fields(row.presentation_pose)==8 and foot_event(row)==nil,"held busy footer selection cannot start later")
        end
        r.tick(false);r.tick(false,"one_foot_right")
        local fresh=r.tick(false,"one_foot_right")
        check((fresh.presentation_pose.release_right_foot or 0)>0 and fresh.presentation_pose.release_left_foot==nil,
            "only a new neutral then fresh selection may deliberately choose the other foot")
        r.ride:stop("constructed latched footer cleanup")
        local busy=foot_full("left");busy.tick(false)
        local hand=busy.tick(false,"one_hand_right")
        check(busy.mapped_actions.movement==42 and hand.presentation_pose.release_right_hand==nil
            and (hand.presentation_pose.release_left_foot or 0)>0,"active footer consumes a fresh hand selection without releasing that hand")
        busy.tick(false)
        local bars=busy.tick(false,"bar_left")
        check(busy.mapped_actions.movement==34 and not bars.model.accepted_barspin.rotation_reserved
            and bars.presentation_pose.barspin==0,"active footer consumes fresh bar rotation selection")
        busy.tick(false)
        local tails=busy.tick(false,"tail_right")
        check(busy.mapped_actions.movement==52 and not tails.model.accepted_barspin.rotation_reserved
            and tails.presentation_pose.tailwhip==0,"active footer consumes fresh tail rotation selection")
        local events=0
        for _=1,5 do local row=busy.tick(false,"tail_right");if foot_event(row) then events+=1 end end
        check(events==1,"only the original footer recovery completes while busy turn selections stay consumed")
        local held=busy.tick(false,"tail_right")
        check(not held.model.accepted_barspin.rotation_reserved and fields(held.presentation_pose)==8,
            "a held busy turn does not start after footer recovery")
        busy.ride:stop("constructed busy footer cleanup")
    end)
    bar.ride:stop("constructed bar cleanup");tail.ride:stop("constructed tail cleanup");c.core:request_stop("constructed receiver cleanup")
    return {cases=cases,assertions=assertions}
end
return table.freeze(Tests)
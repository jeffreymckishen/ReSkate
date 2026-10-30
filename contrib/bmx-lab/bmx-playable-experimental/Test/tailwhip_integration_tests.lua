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
        f.pad.right_x=selection=="tail_right" and 1 or selection=="tail_left" and -1 or 0
        f.pad.right_y=selection=="bar_left" and -1 or 0
        f.pad.buttons.lb=selection=="bar_left";f.pad.buttons.rb=false
        f.pad.left_trigger=tail and 1 or 0;f.pad.right_trigger=tail and 1 or 0
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

-- One focused accepted-step tail trace, plus a bounded check that the existing
-- barspin timing and neutral pose stay unchanged. All boundaries constructed.
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
    local assertions=0
    local function check(v,why) assertions+=1;assert(v,why) end
    local f=fixture()
    local neutral=f.tick(true)
    check(not neutral.stop_requested and fields(neutral.presentation_pose)==8,"normal riding keeps eight fields")
    f.tick(false)
    local prior=f.ride:status()
    f.refusal="force_pipeline_full"
    local refused=f.tick(false,"tail_right")
    check(f.mapped_actions.tailwhip=="right" and f.mapped_actions.movement==52 and f.mapped_actions.handlebar=="none"
        and f.pad.left_trigger==1 and f.pad.right_trigger==1 and not f.pad.buttons.lb and not f.pad.buttons.rb,
        "existing real mapper selects right tailwhip with LT+RT and right-stick right, without invented shoulder buttons")
    check(not refused.stop_requested and refused.presentation_pose==prior.presentation_pose
        and refused.model.accepted_barspin.revision==prior.model.accepted_barspin.revision,
        "refused actual mapped tail candidate changes no accepted state or pose")
    f.refusal=nil
    local held=f.tick(false,"tail_right")
    check(not held.stop_requested and held.presentation_pose.tailwhip==0 and not held.model.accepted_barspin.rotation_reserved,
        "held refused selecting input cannot replay a tailwhip")
    f.tick(false)
    local selected=f.tick(false,"tail_right")
    check(not selected.stop_requested and selected.model.accepted_barspin.rotation_reserved
        and selected.presentation_pose.tailwhip==0,"fresh neutral then selection starts tail at sample end")
    local turning=f.tick(false)
    check(not turning.stop_requested and turning.presentation_pose.tailwhip>0,"next accepted step publishes authored right tail motion")
    check(turning.presentation_pose.barspin==0 and turning.presentation_pose.barspin_release==nil
        and turning.presentation_pose.release_left_hand==nil and turning.presentation_pose.release_right_hand==nil,
        "tail channel leaves the bar/hand channel idle")
    local target=turning.presentation_trick.visual_targets
    check(turning.presentation_trick.accepted_sequence==turning.model_history.sequence,
        "tail angle and foot releases bind the same exact accepted command")
    for _,name in ipairs({"tailwhip_release","release_left_foot","release_right_foot"}) do
        check(turning.presentation_pose[name]==target[name] and target[name]>0,"accepted pose carries "..name)
    end
    local c=core_fixture(true);c.start()
    local function capture(pose)
        c.presented_pose=pose;c.pose_input=nil
        local status=c.tick(17)
        check(status.phase=="following" and c.pose_input~=nil,"actual Core pose_step feeds its mounted poser")
        return c.pose_input
    end
    local function plan(input)
        local out,why=MP.compose(input);check(out~=nil,"existing mounted pose: "..tostring(why));return out
    end
    local input=capture(turning.presentation_pose)
    for _,name in ipairs({"tailwhip","tailwhip_release","release_left_foot","release_right_foot"}) do
        check(input.articulation[name]==target[name],"actual Core forwards accepted "..name)
    end
    local moved=plan(input)
    local base=plan({bike=input.bike,articulation=normal(turning.presentation_pose)})
    check(distance2(moved.targets.ankles[1],base.targets.ankles[1])>1e-8
        and distance2(moved.targets.ankles[2],base.targets.ankles[2])>1e-8,
        "existing mounted_pose releases both feet with the authored tail rather than fixing them to neutral pedals")
    local kept=turning.presentation_pose
    local revision=turning.model.accepted_barspin.revision
    f.refusal="force_pipeline_full"
    local active_refusal=f.tick(false)
    check(not active_refusal.stop_requested and active_refusal.presentation_pose==kept
        and active_refusal.model.accepted_barspin.revision==revision,"active tail refusal holds accepted angle/releases")
    local held_input=capture(active_refusal.presentation_pose)
    check(same(held_input.articulation,input.articulation) and same(plan(held_input).targets.ankles,moved.targets.ankles),
        "refused active candidate cannot advance Core foot targets")
    f.refusal=nil
    local wrapped
    for _=1,40 do
        local row=f.tick(false)
        check(not row.stop_requested,"bounded constructed tail trace remains running")
        if math.abs(row.presentation_pose.tailwhip)<1e-9 and (row.presentation_pose.tailwhip_release or 0)>0 then
            wrapped=row;break
        end
    end
    check(wrapped~=nil,"authored .55 second turn reaches wrapped-zero while feet remain in neutral blend")
    local commands=#f.commands
    local stopped=f.ride:stop("constructed switch or recovery")
    check(stopped.stop_requested and stopped.presentation_trick==nil and fields(stopped.presentation_pose)==8
        and stopped.presentation_pose.barspin==0 and stopped.presentation_pose.tailwhip==0,
        "switch/recovery stop clears both authored angles and all optional releases")
    for _,name in ipairs({"barspin_release","release_left_hand","release_right_hand","tailwhip_release","release_left_foot","release_right_foot"}) do
        check(stopped.presentation_pose[name]==nil,"stop omits "..name)
    end
    check(same(capture(stopped.presentation_pose).articulation,normal(stopped.presentation_pose)),
        "actual Core returns to the old normal articulation")
    check(#f.commands==commands,"tail cleanup creates no physics command")
    check(turning.presentation_trick.realized==false and turning.presentation_trick.completion_qualified==false
        and target.native_collision_contact==false and target.landing_quality_available==false
        and turning.presentation_trick.score==nil and turning.presentation_trick.model_events==nil,
        "no physical tail catch/completion/landing or score is invented")
    local bar=fixture();bar.tick(true);bar.tick(false);bar.tick(false,"bar_left")
    local existing=bar.tick(false)
    local h=bar.read.seconds;local p=h/.45;local expected=-2*math.pi*p*p*(3-2*p)
    check(not existing.stop_requested and math.abs(existing.presentation_pose.barspin-expected)<1e-9,
        "existing left barspin retains the .45 second smooth channel equation")
    check(existing.presentation_pose.tailwhip==0 and existing.presentation_pose.tailwhip_release==nil
        and existing.presentation_pose.release_left_foot==nil and existing.presentation_pose.release_right_foot==nil,
        "bar-only riding retains zero tail/foot articulation")
    bar.ride:stop("constructed bar cleanup");c.core:request_stop("constructed receiver cleanup")
    return {cases=1,assertions=assertions}
end
return table.freeze(Tests)
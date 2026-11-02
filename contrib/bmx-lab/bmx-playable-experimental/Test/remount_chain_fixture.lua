-- The whole player lifecycle in one world, for following a fall through to the next ride.
-- REAL here: bmx_playable_entry, ride_r1_record (survey), bike_runtime (facade), bike_runtime_core,
-- bike_admission, equipment_runtime, equipment_transition, lease_source, lease_identity.
-- CONSTRUCTED here: the SDK surface (input lease/capture, pulses, Follow, body reads, storage), plus Spawn, pose and
-- board fakes copied from core_session_renewable_tests.lua. Ride is a fake unless options.real_ride is set.
-- Nothing here is the plugin Host, a native pulse, or the game.
local BuildFacade=require("./two_cycle_facade_fixture")
local BuildCore=require("./core_session_renewable_fixture")
local Entry=require("./bmx_playable_entry")
local Survey=require("./ride_r1_record")
local M={}

local function copy(v)
    if type(v)~="table" then return v end
    local out={};for k,c in pairs(v) do out[k]=copy(c) end;return out
end
local function str(n) return string.format("%d",n) end
local button_names={"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"}
local function neutral_pad()
    local pad={left_x=0,left_y=0,right_x=0,right_y=0,left_trigger=0,right_trigger=0,playstation=false,buttons={}}
    for _,name in ipairs(button_names) do pad.buttons[name]=false end
    return pad
end
local function pad_zero(p)
    for _,k in {"left_x","left_y","right_x","right_y","left_trigger","right_trigger"} do if p[k]~=0 then return false end end
    for _,k in ipairs(button_names) do if p.buttons[k] then return false end end
    return true
end
local function metadata(row,mode)
    row.transport,row.source_identity,row.physical_device_identity="xinput","observed_stream","unobserved"
    row.mode,row.capturing,row.report_debt=mode or "observe",false,false
    return row
end

function M.new(options)
    options=options or {}
    local w={now=1000,stock=504,ragdoll=false,ragdoll_known=true,wipeouts=0,airborne=false,level="constructed",
        focused=true,gameplay=true,interface_open=false,game_menu=false,pad=neutral_pad(),records={},saves=0,
        context="13",serial=100,body_serial=0,lease_n=0,pulse_n=0,pulses={},events={},renewed={},issued={},
        pulse_mode=options.pulse_mode or "neutral",press_ms=options.press_ms or 330,flip_ms=options.flip_ms or 30,
        release_ms=options.release_ms or 50,park=options.park~=false,tick_n=0}
    local function log(s) w.events[#w.events+1]=string.format("%8d %s",w.now-(w.stop_seen_at or w.now),s) end
    w.log=log
    local R={time={},input={},menu={},skater={},level={},json={},storage={},entities={},world={physics={}}}
    R.log=options.log
    function R.time.now() return w.now end
    function R.input.focus() return {focused=w.focused,interface_open=w.interface_open,gameplay=w.gameplay} end
    function R.input.allowed() return true end
    function R.input.gamepad() return copy(w.pad) end
    function R.menu.game() return {open=w.game_menu} end
    function R.skater.get() return {airborne=w.airborne,position=vector.create(0,.5,0),heading=0} end
    function R.skater.telemetry()
        return {skater=true,airborne=w.airborne,teleport_pending=false,
            watch={valid=true,state=w.stock,ragdoll_known=w.ragdoll_known,ragdoll=w.ragdoll,wipeouts=w.wipeouts}}
    end
    function R.skater.pose() return true end
    function R.skater.teleport() return true end
    function R.level.current() return {name=w.level} end
    function R.json.encode() return "constructed bounded diagnostic" end
    function R.storage.get(k) return w.records[k] end
    function R.storage.set(k,v) w.saves+=1;w.records[k]=copy(v) end
    function R.storage.keys()
        local out={};for k in pairs(w.records) do out[#out+1]=k end;return out
    end
    function R.entities.bounds() return {} end
    function R.entities.set() return true end
    function R.entities.status() return {} end
    function R.entities.remove() end
    -- Survey ground: flat at y=0, nothing in the way.
    function R.world.probe(from,to)
        if from.y-to.y>1 then return {status="hit",position=vector.create(from.x,0,from.z)} end
        return {status="clear"}
    end

    ---------------- Input lease and capture (ported from Test/two_cycle_fixture.lua, with a renewing expiry) ----------------
    local api=R.input
    local function owns(h) return h~=nil and h==w.handle end
    local function sync()
        if not w.passive then return end
        local retained=w.capture and not w.capture.terminal
        w.passive.capture_reserved=retained==true
        if w.passive.terminal then w.passive.source_released=not retained end
    end
    function w.publish()
        w.serial+=1
        w.sample=metadata({sequence=w.seq,source_epoch="15",context_generation=w.context,observation_serial=str(w.serial),
            observed_ms=str(w.now),user=0,packet=23,pad=copy(w.pad),neutral=pad_zero(w.pad)})
        if w.passive then w.passive.status,w.passive.observed_ms,w.passive.last_observation="active",str(w.now),str(w.serial) end
    end
    local function complete_capture()
        local c=w.capture
        c.phase,c.terminal,c.capturing,c.report_debt="complete",true,false,false
        c.quarantined=false
        c.publications=str(tonumber(c.publications)+1);c.neutral_releases=str(tonumber(c.neutral_releases)+1)
        c.generation=str(tonumber(c.generation)+1);c.revision=str(tonumber(c.revision)+1)
        sync()
    end
    function api.lease(user)
        if w.handle then return nil,"busy" end
        w.lease_n+=1;w.seq=str(10+w.lease_n)
        w.handle,w.sample=newproxy(),nil
        w.passive=metadata({sequence=w.seq,source_epoch="15",context_generation=w.context,user=user,status="warming",
            reason="none",terminal=false,requested_ms=str(w.now),expires_ms=str(w.now+250),observed_ms="0",last_observation="0",
            renewals="0",source_released=false,capture_reserved=false,orphaned=false})
        return w.handle
    end
    function api.lease_read(h)
        if not owns(h) or not w.sample or w.passive.terminal then return nil,"unavailable" end
        local row,epoch=copy(w.sample),newproxy()
        row.epoch=epoch;w.issued[epoch]=row.observation_serial
        return row
    end
    function api.lease_renew(h,epoch)
        local serial=w.issued[epoch]
        if not owns(h) or serial~=w.sample.observation_serial or w.renewed[serial] then return false,"stale_epoch" end
        w.renewed[serial]=true
        w.passive.renewals=str(tonumber(w.passive.renewals)+1);w.passive.expires_ms=str(w.now+250)
        return true
    end
    function api.lease_state(h)
        if not owns(h) or not w.passive then return nil,"unavailable" end
        sync();return copy(w.passive)
    end
    function api.lease_release(h)
        if not owns(h) or not w.passive or w.passive.terminal then return false,"unavailable" end
        w.passive.status,w.passive.reason,w.passive.terminal="released","cancelled",true
        if w.capture and not w.capture.terminal then
            if w.capture.phase~="releasing" then
                w.capture.generation=str(tonumber(w.capture.generation)+1);w.capture.revision=str(tonumber(w.capture.revision)+1)
                w.capture_release_at=w.now
            end
            w.capture.phase,w.capture.capturing,w.capture.reason="releasing",false,"cancelled"
            if not w.capture.report_debt then w.capture.phase,w.capture.terminal="complete",true end
        end
        sync();return true
    end
    function api.lease_acknowledge(h)
        sync()
        if not owns(h) or not w.passive or not w.passive.terminal or not w.passive.source_released
            or w.passive.capture_reserved then return false,"busy" end
        w.passive,w.handle,w.sample=nil,nil,nil
        return true
    end
    function api.lease_capture(h,epoch)
        if not owns(h) or w.issued[epoch]~=w.sample.observation_serial then return false,"authority_lost" end
        if w.capture then return false,"busy" end
        w.capture=metadata({sequence=w.seq,source_epoch="15",context_generation=w.context,user=0,phase="waiting_neutral",
            reason="none",terminal=false,quarantined=false,generation="20",revision="22",expires_ms=str(w.now+60000),
            publications="0",neutral_releases="0"},"capture")
        w.capture.capture_scope,w.capture.publication_scope="selected_observed_xinput_stream","process_outer_xinput_buffer"
        w.capture.consumption,w.capture.semantic_completion="unobserved","unobserved"
        sync();return true
    end
    function api.lease_capture_state(h)
        if not owns(h) or not w.capture then return nil,"unavailable" end
        return copy(w.capture)
    end
    function api.lease_release_capture(h)
        if not owns(h) or not w.capture or w.capture.terminal then return false,"unavailable" end
        if w.capture.phase~="releasing" then
            w.capture.generation=str(tonumber(w.capture.generation)+1);w.capture.revision=str(tonumber(w.capture.revision)+1)
            w.capture_release_at=w.now
        end
        w.capture.reason,w.capture.capturing="cancelled",false
        if w.capture.report_debt then w.capture.phase="releasing" else w.capture.phase,w.capture.terminal="complete",true end
        sync();return true
    end
    function api.lease_acknowledge_capture(h)
        if not owns(h) or not w.capture or not w.capture.terminal or w.capture.report_debt or w.capture.quarantined then
            return false,"busy"
        end
        w.capture=nil;sync();return true
    end

    ---------------- Pulses: a receipt timeline taken from the measured ledgers ----------------
    -- neutral: warming, press about 330 ms after the request (c19/c23/c25/c28), then released.
    -- held: a non-neutral pad keeps warming to the 1000 ms expiry with no press (c22 shape).
    -- refuse: the SDK refuses the pulse outright, the shape of a disconnected virtual pad.
    -- never: the receipt stays warming for ever (constructed worst case, no real pulse does this).
    local function receipt(p)
        local age=w.now-p.at
        local status,reason,terminal,press,neutral,debt,claim="warming","none",false,"0","0",false,false
        local mask=0
        if p.cancelled_at and not p.pressed then
            status,reason,terminal,claim="cancelled","cancelled",true,true
        elseif p.mode=="held" then
            if age>=1000 then status,reason,terminal,claim,mask="expired","deadline",true,true,65536 end
        elseif p.mode=="never" then
            status="warming"
        elseif p.pressed then
            if p.mode=="stuck_release" then
                status,press,debt="releasing","50",true
            else
                status,terminal,press,neutral,claim="released",true,"50","1",true
            end
        end
        return {sequence=str(p.n),status=status,reason=reason,user=0,button=0x8000,requested_ms=str(p.at),
            expires_ms=str(p.at+1000),observed_ms=str(w.now),source_epoch="19",transport="xinput",
            source_identity="observed_stream",publication_scope="process_outer_xinput_buffer",consumption="unobserved",
            semantic_completion="unobserved",terminal=terminal,report_debt=debt,claim_released=claim,actor_retired=p.retired==true,
            orphaned=false,quarantined=false,original_result_known=true,original_result=0,first_rejection_mask=mask,
            first_rejection_stage="none",press_candidates=press,press_publications=press,neutral_publications=neutral,
            original_failures="0",contentions="0",warmup_deferrals="0"}
    end
    function api.pulse(slot,button)
        assert(slot==0 and button=="y","same selected pulse")
        if w.pulse_mode=="refuse" then log("pulse refused by constructed SDK");return nil,"source_unavailable" end
        w.pulse_n+=1
        local p={h=newproxy(),n=w.pulse_n,at=w.now,mode=w.pulse_mode,reads=0}
        w.pulses[w.pulse_n]=p;w.pulse=p
        log("pulse "..p.n.." requested mode="..p.mode)
        if w.on_pulse then w.on_pulse(p) end
        return p.h
    end
    function api.pulse_state(h)
        assert(w.pulse and h==w.pulse.h,"pulse read keeps its exact handle")
        w.pulse.reads+=1;w.pulse.last=receipt(w.pulse)
        return copy(w.pulse.last)
    end
    function api.pulse_cancel(h)
        if not w.pulse or h~=w.pulse.h then return false end
        w.pulse.cancelled_at=w.pulse.cancelled_at or w.now;log("pulse cancelled");return true
    end
    function api.pulse_acknowledge(h)
        assert(w.pulse and h==w.pulse.h,"pulse ACK keeps its exact handle")
        w.pulse.acked=true;log("pulse acknowledged");w.pulse=nil
        return true
    end

    ---------------- Follow and body (ported from Test/core_session_renewable_tests.lua) ----------------
    local P=R.world.physics
    function P.prepare() return true end
    local function forbidden() error("constructed chain has no native body creation",0) end
    P.create=forbidden
    function P.reserve_follow(body,attachment)
        assert(body==w.body,"same handed-off body")
        w.follow=newproxy();w.follow_stops=0;w.follow_acks=0;w.published=false
        w.is_session=attachment.lifetime=="session_renewable";w.renewable=attachment.lifetime=="renewable" or w.is_session
        w.deadline=w.now+3000;w.ceiling=w.now+120000;w.accepted=0
        return w.follow,nil
    end
    function P.publish_follow(h) assert(h==w.follow);w.published=true;return true end
    function P.read_follow(h)
        assert(h==w.follow)
        local terminal=w.follow_stops>0 and w.park
        local active=w.published
        local serial=str(math.max(1,w.body_serial))
        return {phase=terminal and "completed" or w.follow_stops>0 and "retained" or active and "following" or "reserved",
            reason=terminal and "cancelled" or "none",park_reason="none",sequence="7",final_revision=active and serial or "0",
            final_native_epoch=active and serial or "0",returned_revision=active and serial or "0",pending={},in_flight=0,
            claim_known=not terminal,orphaned=false,park_observed=terminal,native_retirement_known=false,terminal=terminal}
    end
    function P.read_follow_lease(h)
        assert(h==w.follow)
        local remaining=math.max(0,w.deadline-w.now)
        return {sequence="7",renewable=w.renewable,active=remaining>0,renewals=str(w.accepted),
            last_serial=w.accepted==0 and "0" or w.last_renew_serial,remaining_ms=remaining,base_ms=3000,renewal_ms=500,
            revocation="none",dispatch_busy="0",session_renewable=true,lifetime_ms=0,lifetime_remaining_ms=0}
    end
    function P.renew_follow(...)
        if select("#",...)~=2 then error("renew_follow takes one opaque follow handle and one measured body epoch",0) end
        local h,epoch=...
        assert(h==w.follow and epoch==w.epoch,"renewal uses the latest body epoch")
        if w.now>=w.deadline then return false,"expired" end
        w.deadline=math.max(w.deadline,w.now+500);w.accepted+=1;w.last_renew_serial=str(w.body_serial+1)
        return true,w.deadline-w.now
    end
    function P.read(body)
        assert(body==w.body)
        w.body_serial+=1;w.epoch=newproxy()
        if options.on_body_read then return options.on_body_read(w) end
        return {serial=str(w.body_serial+1),epoch=w.epoch,time=w.body_serial/60,seconds=1/60,position=vector.create(0,1,0),
            rotation={0,0,0,1},velocity=vector.create(0,0,0),angular_velocity=vector.create(0,0,0),mass=106,inertia=vector.create(26,32,10)}
    end
    function P.probe_batch() return {} end
    function P.submit() error("constructed fake Ride never submits",0) end
    function P.receipt() error("constructed fake Ride never reads a receipt",0) end
    function P.acknowledge() error("constructed fake Ride never acknowledges",0) end
    if options.real_ride then
        -- A static body on flat ground, and a native force pipeline with the shapes ride_runtime_tests validates:
        -- applied one serial after the request, successor one serial later, and after Follow stops an applied record
        -- with no successor is sealed parked_without_successor while a queued one is rejected. Nothing integrates: the
        -- body does not move, so this proves the bookkeeping, not the riding.
        local Forces=require("./forces")
        local Contact=require("./contact_runtime")
        local lane=Contact.CATEGORY_WHEEL_LANE_QUALIFIED==true
        local seconds=Forces.native_seconds
        w.tx,w.tx_seq,w.tx_acked={},7000,0
        local function body_row(serial)
            local rotation={0,0,0,1}
            if w.tilt_deg then local a=math.rad(w.tilt_deg)/2;rotation={0,0,math.sin(a),math.cos(a)} end
            local t=1+serial*seconds
            -- A native step whose clock copy was dropped: the serial advanced, the time did not.
            if w.time_skew_from and serial>=w.time_skew_from then t-=seconds end
            return {epoch=newproxy(),serial=str(serial),time=t,seconds=seconds,position=vector.create(0,.9,-.05),
                rotation=rotation,velocity=vector.create(.75,0,-.4),angular_velocity=vector.create(0,0,0),mass=83,inertia=vector.create(26,32,10)}
        end
        function P.read(body)
            assert(body==w.body)
            w.body_serial+=1
            local row=body_row(w.body_serial+1)
            w.epoch=row.epoch
            return row
        end
        function P.probe_batch(_,epoch,rays,settings)
            local batch={status="available",epoch=epoch,native_casts=#rays,budget_exhausted=false,
                local_actor_excluded=not lane,owned_bodies_excluded=true,rays={}}
            if lane then batch.requested_query_preset="camera";batch.named_actor_categories_absent=true end
            if #rays==3 then
                batch.rays={{status="clear"},{status="clear"},{status="clear"}}
                return batch
            end
            for i=1,#rays do
                local from,to=rays[i].from,rays[i].to
                batch.rays[i]={status="hit",fraction=Forces.wheel_radius/(from.y-to.y),
                    position=vector.create(from.x,from.y-Forces.wheel_radius,from.z),normal_available=true,
                    normal=vector.create(0,1,0),motion="measured",surface_velocity_available=true,
                    surface_velocity=vector.create(.75,0,-.4)}
            end
            return batch
        end
        function P.submit(_,_,command)
            w.tx_seq+=1
            local key=str(w.tx_seq)
            local requested=w.body_serial+1
            w.tx[key]={requested=requested}
            if command and command.impulse then w.impulses=(w.impulses or 0)+1;w.log("force command carries an impulse (the hop)") end
            return true,nil,key
        end
        function P.receipt(_,sequence)
            local t=assert(w.tx[sequence],"exact sequence")
            local current=w.body_serial+1
            local produced=t.requested+1
            local base={sequence=sequence,requested_serial=str(t.requested),retained=false,quarantined=false,cleanup_disposition="none"}
            if current<produced then
                if w.follow_stops and w.follow_stops>0 then
                    base.produced_serial,base.outcome,base.force_attempted,base.torque_attempted="0","rejected",false,false
                    return base
                end
                base.produced_serial,base.outcome,base.force_attempted,base.torque_attempted="0","queued",false,false
                return base
            end
            base.produced_serial,base.outcome,base.force_attempted,base.torque_attempted=str(produced),"applied",true,true
            if current>=produced+1 then base.successor=body_row(produced+1)
            elseif w.follow_stops and w.follow_stops>0 then
                base.cleanup_disposition="parked_without_successor";base.retained=true
            end
            return base
        end
        function P.acknowledge(_,sequence)
            assert(w.tx[sequence],"exact sequence");w.tx[sequence]=nil;w.tx_acked+=1
            return true
        end
    end
    function P.stop_follow(h) assert(h==w.follow);w.follow_stops+=1;return true end
    function P.acknowledge_follow(h) assert(h==w.follow);w.follow_acks+=1;return true end
    function P.release(body) assert(body==w.body);return true end

    ---------------- Fakes for what the session's ledger shows finished cleanly ----------------
    local FakeSpawn={}
    function FakeSpawn.new(spawn_api)
        local spawn={phase="armed",removed=false}
        function spawn:request() return true end
        function spawn:update() self.phase="spawned" end
        function spawn:status() return {phase=self.phase,cleanup_unknown=false,creation_unknown=false,body=false,
            visual_remove_requested=self.removed} end
        function spawn:handoff_follow()
            self.phase="follow_owned";w.body=newproxy();w.body_serial=0
            return w.body,{serial="1"},nil
        end
        function spawn:follow_visual() return true end
        function spawn:floor_height() return 0 end
        function spawn:actor_floor_clearance() return .8 end
        function spawn:set_playable_grade() return true end
        function spawn:stop()
            self.phase="closed"
            if not self.removed then
                self.removed=true
                for id=1,8 do spawn_api.entities.remove(id) end
            end
            return true
        end
        return spawn
    end
    FakeSpawn.floor_spawn_qualified=function() return false end
    local FakeRide={}
    function FakeRide.new()
        local ride={stopped=false,issue=nil}
        w.ride=ride
        function ride:status()
            return {phase=self.stopped and "stopped" or "running",force_pending=w.ride_force_pending==true,
                unknown=w.ride_unknown==true,stop_requested=self.stopped,issue=self.issue,submitted=0,acknowledged=0}
        end
        function ride:observe()
            if w.ride_issue and not self.stopped then self.stopped=true;self.issue=w.ride_issue;w.ride_issue=nil end
            return self:status()
        end
        function ride:stop(why)
            if not self.stopped then self.stopped=true;self.issue=self.issue or why end
            return self:status()
        end
        function ride:drain()
            if w.on_ride_drain then w.on_ride_drain() end
            return self:status()
        end
        return ride
    end
    local FakePose={}
    function FakePose.new(pose_api)
        local poser={state="unmounted"}
        function poser:mount() self.state="mounted";return {ok=true} end
        function poser:tick() return {ok=true,sent=false,state=self.state} end
        function poser:stop() self.state="off";pose_api.skater.pose(nil) end
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
    local overrides={["./bike_spawn"]=FakeSpawn,["./mounted_pose"]=FakePose,["./board_drop"]=FakeBoard}
    if options.real_ride then overrides["./ride_runtime"]=require("./ride_runtime_qualified_fixture")
    else overrides["./ride_runtime"]=FakeRide end
    if options.overrides then for k,v in pairs(options.overrides) do overrides[k]=v end end

    ---------------- The real chain ----------------
    local core_module
    local function hook(name)
        if overrides[name] then return overrides[name] end
        if name=="./bike_runtime_core" then
            if not core_module then
                local C=BuildCore(hook)
                core_module=setmetatable({experimental_two_cycle_owner=function()
                    local real,why=C.experimental_two_cycle_owner()
                    if not real then return real,why end
                    w.session_owner=real
                    local owner={}
                    function owner:abort_preparation() return real:abort_preparation() end
                    function owner:first(s,o,t) w.T=t;return real:first(s,o,t) end
                    function owner:can_archive_return() return real:can_archive_return() end
                    function owner:archive_return() return real:archive_return() end
                    function owner:ready() return real:ready() end
                    function owner:successor(s,o,t)
                        local object,why2=real:successor(s,o,t)
                        if object then w.T=t;w.old_T=w.old_T or {};table.insert(w.old_T,w.T) end
                        return object,why2
                    end
                    return table.freeze(owner)
                end},{__index=C})
            end
            return core_module
        end
        return require(name)
    end
    local Facade=BuildFacade(hook)
    local Runtime={new=Facade.new}
    function Runtime.new_experimental_two_cycle(s,o)
        local m,why=Facade.new_experimental_two_cycle(s,o)
        w.manager=m
        if m then return m end -- Entry requires exactly one return value here.
        return nil,why
    end
    w.R=R
    w.make_entry=function()
        return Entry.new(R,Runtime,Survey,{admitted=true,slot=0,experimental_two_cycle=true,session_renewable=true,auto_return=true})
    end
    if options.storage then w.records=options.storage end
    w.entry=w.make_entry()

    ---------------- One game tick ----------------
    local last_entry,last_core,last_eq
    function w.world_tick()
        if w.on_tick then w.on_tick() end
        if w.handle and w.passive and not w.passive.terminal then w.publish() end
        local c=w.capture
        if c and c.phase=="waiting_neutral" and pad_zero(w.pad) then
            c.phase,c.capturing,c.report_debt="capturing",true,true
            c.publications="1"
        elseif c and c.phase=="releasing" and w.now-(w.capture_release_at or w.now)>=w.release_ms
            and not w.capture_hold then
            complete_capture()
        end
        local p=w.pulse
        if p and p.mode~="held" and p.mode~="never" and not p.pressed and not p.cancelled_at and w.now-p.at>=w.press_ms then
            p.pressed=true;log("pulse "..p.n.." pressed")
            p.flip_at=w.now+w.flip_ms
        end
        if p and p.flip_at and w.now>=p.flip_at then
            p.flip_at=nil
            w.stock=w.stock==100 and 504 or 100
            log("stock state now "..w.stock)
        end
    end
    function w.tick(n)
        for _=1,n or 1 do
            w.now+=16;w.tick_n+=1
            w.world_tick()
            w.entry:step(16)
            local s=w.entry:status()
            local core=w.manager and w.manager:status()
            local e=core and core.equipment
            if s.phase~=last_entry then log("entry phase "..tostring(last_entry).." -> "..s.phase);last_entry=s.phase end
            if core and core.phase~=last_core then log("core phase "..tostring(last_core).." -> "..tostring(core.phase));last_core=core.phase end
            if e then
                local key=tostring(e.phase).."/"..tostring(e.outcome).."/"..tostring(e.reason)
                if key~=last_eq then log("equipment "..key);last_eq=key end
            end
            if core and core.stop_latched and not w.stop_seen_at then
                w.stop_seen_at=w.now;log("stop latched: "..tostring(core.stop_reason))
            end
        end
    end
    function w.until_phase(name,limit)
        for _=1,limit or 4000 do
            w.tick()
            local s=w.entry:status()
            if s.phase==name then return true end
            if s.phase=="blocked" then return false,"blocked: "..tostring(s.detail) end
        end
        return false,"timed out in phase "..w.entry:status().phase.." core "..tostring(w.entry:status().core_phase)
    end
    function w.mount_and_ride()
        local ok,why=w.entry:mount()
        assert(ok,"first Mount accepted: "..tostring(why))
        local reached,detail=w.until_phase("riding")
        if not reached then w.show("mount did not reach riding");w.timeline(40) end
        assert(reached,"reached riding: "..tostring(detail))
    end
    function w.ride_ms(ms) w.tick(math.ceil(ms/16)) end
    function w.tilt_stop(deg) w.ride_issue=string.format("measured tilt %.1f deg over the 55 deg Ride stop",deg or 59.7) end
    function w.snapshot()
        local s=w.entry:status();local c=w.manager:status();local e=c.equipment or {}
        local T=w.T or {}
        local r=e.receipt
        return {entry_phase=s.phase,entry_detail=s.detail,help=w.entry.help_line and w.entry:help_line() or nil,
            return_requested=s.return_requested,stock_attempted=s.stock_attempted,recovery_pending=s.recovery_pending,
            recovery_available=s.recovery_available,fall_reason=s.fall_reason,attempts_used=s.attempts_used,
            core_phase=c.phase,core_detail=c.detail,cleanup_unknown=c.cleanup_unknown,cleanup_pending=c.cleanup_pending,
            stock_toggle_blocked=c.stock_toggle_blocked,bike_cleanup_complete=c.bike_cleanup_complete,bike_authority=c.bike_authority,
            stop_reason=c.stop_reason,ride_issue=c.ride and c.ride.issue,ride_unknown=c.force_cleanup_unknown,
            force_clear=c.force_cleanup_clear,stock_requested=c.stock_requested,equipment_purpose=c.equipment_purpose,
            eq_phase=e.phase,eq_outcome=e.outcome,eq_reason=e.reason,eq_retained=e.retained,eq_acknowledged=e.acknowledged,
            eq_attempt=e.attempt,eq_unloaded=e.unloaded,
            calls=e.calls and string.format("request=%d read=%d cancel=%d store=%d ack=%d",e.calls.request,e.calls.read,
                e.calls.cancel,e.calls.store,e.calls.acknowledge) or nil,
            receipt=r and string.format("status=%s terminal=%s press_publications=%s claim_released=%s",r.status,tostring(r.terminal),
                r.press_publications,tostring(r.claim_released)) or nil,
            T_gear_unknown=T.gear_unknown,T_gear_cancelled=T.gear_cancelled,T_gear_requested=T.gear_requested,
            T_cleanup_expired=T.cleanup_expired,T_startup_closed=T.startup_closed,T_ride_unknown=T.ride_unknown}
    end
    local order={"entry_phase","entry_detail","help","return_requested","stock_attempted","recovery_pending","recovery_available",
        "fall_reason","attempts_used","core_phase","core_detail","cleanup_unknown","cleanup_pending","stock_toggle_blocked",
        "bike_cleanup_complete","bike_authority","stop_reason","ride_issue","ride_unknown","force_clear","stock_requested",
        "equipment_purpose","eq_phase","eq_outcome","eq_reason","eq_retained","eq_acknowledged","eq_attempt","eq_unloaded","calls",
        "receipt","T_gear_unknown","T_gear_cancelled","T_gear_requested","T_cleanup_expired","T_startup_closed","T_ride_unknown"}
    function w.show(label,fields)
        local s=w.snapshot()
        print("-- "..label.." (now="..str(w.now-(w.stop_seen_at or w.now)).." ms after stop, stock="..w.stock..")")
        local parts={}
        for _,k in ipairs(fields or order) do
            local v=s[k]
            if v~=nil then parts[#parts+1]=k.."="..tostring(v) end
        end
        print("   "..table.concat(parts," | "))
        return s
    end
    function w.timeline(limit)
        local from=math.max(1,#w.events-(limit or 400)+1)
        for i=from,#w.events do print("   "..w.events[i]) end
    end
    return w
end
M.wedged=function(s)
    return s.entry_phase=="returning" and s.core_phase=="stock_stopping" and s.cleanup_unknown==true and s.stock_toggle_blocked==true
end
M.neutral_pad=neutral_pad
return M

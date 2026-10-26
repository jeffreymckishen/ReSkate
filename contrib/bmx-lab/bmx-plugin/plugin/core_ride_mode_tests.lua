-- Constructed Core ride-mode policies (B4, B5, B8, B9) and visual requests, and
-- Core's own Source step over constructed SDK-shaped services. No Host, native
-- handle or native effect. The tracked literals are checked here, in the
-- luau-runner, never in a ReSkate Host fixture.
local Core=require("./bike_runtime_core")
local Spawn=require("./bike_spawn")
local G=require("./bike_geometry")
local M=require("./force_math")
local Tests={}
local axes={"left_x","left_y","right_x","right_y","left_trigger","right_trigger"}
local buttons={"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"}
local function frame()
    local pad={playstation=false,buttons={}}
    for _,key in ipairs(axes) do pad[key]=0 end
    for _,key in ipairs(buttons) do pad.buttons[key]=false end
    return {input_ok=true,sample={user=0,pad=pad}}
end
local function v(a) return vector.create(a[1],a[2],a[3]) end
local function visual_fixture(rotation,root)
    local f={sets=0}
    local owner=Spawn.new({entities={set=function() f.sets+=1;return true end}})
    -- Exact zero COM in the identity boundary cases avoids float-vector
    -- quantization masquerading as an envelope-policy disagreement.
    owner.root,owner.rotation=root or {0,-G.com[2],-G.com[3]},rotation or {0,0,0,1}
    local base=M.add(owner.root,M.turn(owner.rotation,G.com))
    local function sample(serial,time,delta)
        return {epoch=newproxy(),serial=serial,time=time,seconds=1/60,mass=G.mass,
            position=v(M.add(base,delta or {0,0,0})),rotation=table.clone(owner.rotation),
            velocity=vector.create(0,0,0),angular_velocity=vector.create(0,0,0),inertia=v(G.inertia)}
    end
    owner.sample=sample("1",0)
    owner.phase,owner.follow_handed_off="follow_owned",true
    return owner,f,sample
end

-- Core's Source step (B4) with the real lease_source over a constructed
-- ten-method input lease, a stand-in spawn owner and constructed Follow
-- results. newproxy values are test identities, not native handles. Core is
-- built already armed, because request_mount allows one attempt per VM. A
-- force, contact or stock call fails the case.
local function source_fixture(options)
    options=options or {}
    local f={now=1000,slot=options.slot or 0,serial=5,renewals=0,reserves=0,publishes=0,follow_reads=0,
        body_reads=0,stops=0,spawn_requests=0,visuals=0,published=false,follow=newproxy(),body=newproxy()}
    f.pad=frame().sample.pad
    local s={time={},input={},skater={},level={},storage={},json={},menu={},entities={},world={physics={}}}
    local function forbidden(name) return function() error(name.." must not be reached",0) end end
    function s.time.now() return f.now end
    -- Closed menus, focused gameplay, an upright, grounded on-foot (504) rider.
    function s.input.focus() return {focused=true,interface_open=false,gameplay=true} end
    function s.input.allowed() return true end
    function s.menu.game() return {open=false} end
    function s.skater.get() return {airborne=false,position=vector.create(0,0,0),heading=0} end
    function s.skater.telemetry() return {skater=true,airborne=false,teleport_pending=false,
        watch={valid=true,state=504,ragdoll_known=true,ragdoll=false,wipeouts=0}} end
    function s.level.current() return {name="sanvan"} end
    function s.json.encode() return "bounded constructed encoding" end
    function s.storage.get() return nil end
    function s.storage.set() end
    for _,name in {"pulse","pulse_state","pulse_cancel","pulse_acknowledge"} do s.input[name]=forbidden("input."..name) end
    for _,name in {"probe_batch","submit","receipt","acknowledge"} do s.world.physics[name]=forbidden(name) end
    -- One selected stream. Each pad change is a new observation, as Source requires.
    local function stream(row)
        row.transport,row.source_identity,row.physical_device_identity="xinput","observed_stream","unobserved"
        row.user,row.sequence,row.source_epoch,row.context_generation=f.user,"11","12","13"
        return row
    end
    function s.input.lease(user)
        if f.lease then return nil,"busy" end
        f.user,f.lease,f.lease_status=user,newproxy(),"active"
        return f.lease
    end
    function s.input.lease_read(handle)
        if handle~=f.lease or f.lease_status~="active" then return nil,"unavailable" end
        local row=stream({mode="observe",capturing=false,report_debt=false,observation_serial=tostring(f.serial),
            observed_ms=tostring(2000+f.serial),packet=f.serial,pad=f.pad})
        row.epoch=newproxy()
        return row
    end
    function s.input.lease_renew(handle)
        if handle~=f.lease then return false,"stale_epoch" end
        f.renewals+=1
        return true
    end
    function s.input.lease_state(handle)
        if handle~=f.lease then return nil,"unavailable" end
        local terminal=f.lease_status~="active"
        local reserved=f.capture~=nil and not f.capture_acked
        return stream({mode="observe",capturing=false,report_debt=false,status=f.lease_status,
            reason=terminal and "cancelled" or "none",terminal=terminal,requested_ms="1000",expires_ms="900000",
            observed_ms=tostring(2000+f.serial),last_observation=tostring(f.serial),renewals=tostring(f.renewals),
            source_released=terminal and not reserved,capture_reserved=reserved,orphaned=false})
    end
    function s.input.lease_release(handle)
        if handle~=f.lease or f.lease_status~="active" then return false,"unavailable" end
        f.lease_status="released"
        return true
    end
    function s.input.lease_acknowledge(handle)
        if handle~=f.lease or f.lease_status=="active" or (f.capture and not f.capture_acked) then return false,"busy" end
        return true
    end
    local function capture_row()
        local c=f.capture
        return stream({mode="capture",capture_scope="selected_observed_xinput_stream",
            publication_scope="process_outer_xinput_buffer",consumption="unobserved",semantic_completion="unobserved",
            capturing=c.phase=="capturing",report_debt=c.phase=="capturing",phase=c.phase,reason=c.reason,
            terminal=c.phase=="complete",quarantined=false,generation=c.generation,revision=c.revision,
            expires_ms="900000",publications=c.publications,neutral_releases=c.neutral_releases})
    end
    function s.input.lease_capture(handle)
        if handle~=f.lease or f.capture then return false,"busy" end
        f.capture={phase="waiting_neutral",reason="none",generation="21",revision="22",
            publications="0",neutral_releases="0",reads=0}
        return true
    end
    function s.input.lease_capture_state(handle)
        if handle~=f.lease or not f.capture then return nil,"unavailable" end
        local c=f.capture
        c.reads+=1
        -- Constructed: the second read reports the selected stream as captured.
        if c.phase=="waiting_neutral" and c.reads>1 then c.phase,c.publications="capturing","1" end
        return capture_row()
    end
    function s.input.lease_release_capture(handle)
        local c=f.capture
        if handle~=f.lease or not c or c.phase=="complete" then return false,"unavailable" end
        c.phase,c.reason,c.generation,c.revision,c.neutral_releases="complete","cancelled","23","24",c.publications
        return true
    end
    function s.input.lease_acknowledge_capture(handle)
        if handle~=f.lease or not f.capture or f.capture.phase~="complete" then return false,"busy" end
        f.capture_acked=true
        return true
    end
    local P=s.world.physics
    function P.reserve_follow() f.reserves+=1;return f.follow,nil end
    function P.read_follow()
        f.follow_reads+=1
        local following=f.published
        return {phase=following and "following" or "reserved",reason="none",park_reason="none",sequence="7",
            final_revision=following and "1" or "0",final_native_epoch=following and "5" or "0",
            returned_revision=following and "1" or "0",pending={},in_flight=0,claim_known=true,orphaned=false,
            park_observed=false,native_retirement_known=false,terminal=false}
    end
    function P.publish_follow() f.publishes+=1;f.published=true;return true end
    function P.read() f.body_reads+=1;return {serial=tostring(f.body_reads+1)} end
    function P.stop_follow() f.stops+=1;return true end
    function P.acknowledge_follow() return true end
    function P.release() return true end
    -- Spawn reports spawned after options.spawn_ticks updates.
    local owner={phase="armed",waits=options.spawn_ticks or 0}
    function owner:request() f.spawn_requests+=1;return true end
    function owner:update()
        if self.phase~="armed" then return end
        if self.waits>0 then self.waits-=1 else self.phase="spawned" end
    end
    function owner:status()
        return {phase=self.phase,cleanup_unknown=false,creation_unknown=false,body=false,visual_remove_requested=false}
    end
    function owner:handoff_follow() self.phase="follow_owned";return f.body,{serial="1"},nil end
    function owner:follow_visual() f.visuals+=1;return true end
    function owner:stop() self.phase="closed" end
    local state={phase="armed",detail="constructed armed owner",generation=1,cancel_version=1,calls={},counts={},
        receipts={},omitted_calls=0,omitted_receipts=0,remove_attempted={},remove_accepted={},used=true,
        ledger_owned=true,active=true,slot=f.slot,arm_at=f.now,level="sanvan",wipeouts=0}
    local core=Core.new(s,{qualification_only=true},state)
    local original=Spawn.new
    Spawn.new=function() return owner end
    local ok,bound=pcall(core.prepare_backend,core)
    Spawn.new=original
    assert(ok and bound==true,"constructed backend binds the real Source and the stand-in spawn owner")
    function f.step()
        f.now+=16
        local before=f.body_reads
        local out=core:step(16)
        return out,f.body_reads-before
    end
    -- Neutral ticks until Core reaches phase, or a stop.
    function f.until_phase(phase)
        local out=core:status()
        for _=1,200 do
            if out.phase==phase or out.stop_latched then break end
            out=f.step()
        end
        return out
    end
    function f.set_pad(edit)
        local pad=table.clone(f.pad);pad.buttons=table.clone(f.pad.buttons)
        edit(pad);f.pad=pad;f.serial+=1
    end
    return f,core,state
end

function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,run) cases+=1;run(name) end
    case("tracked literals and read budget arithmetic",function()
        local limits=Core.ride_limits
        check(table.isfrozen(Core) and table.isfrozen(limits),"Core policy cannot be raised by a caller")
        check(not pcall(function() limits.ride_window_ms=2500 end),"ride-window export is read-only")
        check(limits.ride_window_ms==500 and limits.base_lease_ms==3000 and limits.lease_margin_ms==150,
            "tracked window, lease seed and margin")
        check(limits.renewal_window_ms==500 and limits.lifetime_ceiling_ms==120000,"S2's fixed report bounds")
        -- 1 tick receipt + one guard read per probe batch + one for submit.
        check(limits.follow_reads_per_tick==1+Core.probe_batches_per_serial+1 and limits.follow_reads_per_tick==6,
            "four batches and submit fit the per-tick receipt budget exactly")
        check(limits.follow_reads_per_tick+1<=limits.sdk_follow_reads_per_tick and limits.sdk_follow_reads_per_tick==8,
            "a stop tick's one cleanup read still fits under the SDK's eight")
        check(limits.lease_reads_per_tick==1 and limits.sdk_lease_reads_per_tick==8,
            "one lease report a tick, on the SDK's separate counter of eight")
        check(limits.cleanup_reads==400 and limits.cleanup_reads*limits.follow_poll_ms==limits.cleanup_watchdog_ms
            and limits.cleanup_watchdog_ms==20000,"cleanup reads cover the 20 s watchdog at one per 50 ms")
        check(table.isfrozen(Spawn.limits) and Spawn.limits.envelope_m==2
            and not pcall(function() Spawn.limits.envelope_m=6 end),"the tracked envelope literal is 2 m and read-only")
    end)
    case("one window check",function()
        local live=Core.lease_live
        check(live(1000,1000,4000),"opens at publication")
        check(live(1499.9,1000,4000),"stays open under 500 ms")
        check(not live(1500,1000,4000),"tracked window ends at 500 ms")
        check(live(2849.9,2500,3000) and not live(2850,2500,3000),"the lease ends LEASE_MARGIN_MS before lease_until")
        check(not live(1100,1000,1250) and live(1099,1000,1250),"the earlier of window and lease wins")
        check(not live(999,1000,4000),"time before publication refused")
        check(not live(1000,nil,4000) and not live(1000,1000,nil),"missing publication or lease refused")
        check(not live(math.huge,1000,4000) and not live(0/0,1000,4000) and not live(-1,0,4000),"invalid clocks refused")
        check(not live("1000",1000,4000) and not live(1000,1000,"4000"),"strings are not clocks")
    end)
    case("the lease seed",function()
        check(Core.lease_seed(1000)==4000 and Core.lease_seed(0)==3000,"three seconds from the reserve clock read")
        check(Core.lease_seed(nil)==nil and Core.lease_seed(-1)==nil and Core.lease_seed(0/0)==nil
            and Core.lease_seed(9007199254740990)==nil,"invalid or overflowing reserve clock gives no lease")
    end)
    case("neutral selected pad",function()
        local row=frame()
        check(Core.selected_pad_admitted(row,0,false),"neutral acquisition admitted")
        check(Core.selected_pad_admitted(row,0,true),"neutral riding admitted")
    end)
    for _,key in ipairs(axes) do
        case("post-publication axis "..key,function()
            local row=frame()
            row.sample.pad[key]=key:find("trigger",1,true) and .5 or -.5
            check(not Core.selected_pad_admitted(row,0,false),"before publication the pad must be exactly zero")
            check(not Core.selected_pad_admitted(row,0,1),"truthy mode does not enable driving")
            check(Core.selected_pad_admitted(row,0,true),"riding admits the selected bounded axis")
        end)
    end
    for _,key in ipairs(buttons) do
        case("post-publication button "..key,function()
            local row=frame();row.sample.pad.buttons[key]=true
            check(not Core.selected_pad_admitted(row,0,false),"before publication buttons must be released")
            check(not Core.selected_pad_admitted(row,0,"true"),"a string does not enable driving")
            check(Core.selected_pad_admitted(row,0,true),"riding admits the selected boolean button")
        end)
    end
    local invalid={
        {"input unavailable",function(r) r.input_ok=false end},
        {"other slot",function(r) r.sample.user=1 end},
        {"missing pad",function(r) r.sample.pad=nil end},
        {"platform",function(r) r.sample.pad.playstation=true end},
        {"missing axis",function(r) r.sample.pad.left_x=nil end},
        {"large axis",function(r) r.sample.pad.left_x=1.01 end},
        {"small axis",function(r) r.sample.pad.left_x=-1.01 end},
        {"negative trigger",function(r) r.sample.pad.left_trigger=-.01 end},
        {"large trigger",function(r) r.sample.pad.right_trigger=1.01 end},
        {"NaN",function(r) r.sample.pad.left_y=0/0 end},
        {"infinite",function(r) r.sample.pad.right_x=math.huge end},
        {"string axis",function(r) r.sample.pad.right_y="0" end},
        {"missing button",function(r) r.sample.pad.buttons.a=nil end},
        {"nonboolean button",function(r) r.sample.pad.buttons.b=1 end},
        {"frame metatable",function(r) setmetatable(r,{}) end},
        {"sample metatable",function(r) setmetatable(r.sample,{}) end},
        {"pad metatable",function(r) setmetatable(r.sample.pad,{}) end},
        {"buttons metatable",function(r) setmetatable(r.sample.pad.buttons,{}) end},
    }
    for _,edit in ipairs(invalid) do
        case("riding refuses "..edit[1],function()
            local row=frame();edit[2](row)
            check(not Core.selected_pad_admitted(row,0,true),"riding never accepts malformed or unselected input")
            check(not Core.selected_pad_admitted(row,0,false),"nor does acquisition")
        end)
    end
    case("invalid selected slots",function()
        local row=frame()
        check(not Core.selected_pad_admitted(row,nil,true),"missing slot refused")
        check(not Core.selected_pad_admitted(row,-1,true),"negative slot refused")
        check(not Core.selected_pad_admitted(row,4,true),"slot beyond native range refused")
        check(not Core.selected_pad_admitted(row,.5,true),"fractional slot refused")
    end)
    -- B4 at Core's own call site: riding is the join of the gate, following and
    -- observed publication. The tracked gate is false, so there is no mapper and
    -- exact zero applies both before and after publication.
    for _,edit in ipairs({{"an axis",function(p) p.left_y=.5 end},{"a button",function(p) p.buttons.a=true end}}) do
        case("Core stops when "..edit[1].." leaves exact zero before publication",function()
            local f=source_fixture({spawn_ticks=3})
            local out=f.until_phase("spawning")
            check(out.phase=="spawning" and out.stop_reason==nil and f.spawn_requests==1 and f.reserves==0,
                "a neutral selected pad reaches the spawn request")
            f.set_pad(edit[2])
            out=f.step()
            check(out.stop_reason=="selected raw pad left exact zero" and out.published_seen==false,
                "before publication the selected pad must stay exactly zero")
            for _=1,4 do out=f.step() end
            check(f.reserves==0 and f.publishes==0,"nothing is reserved or published after the stop")
        end)
    end
    case("with the gate false, exact zero still applies after publication",function()
        local f=source_fixture()
        local out=f.until_phase("following")
        check(out.ride_composition_qualified==false and out.published_seen==true and out.stop_reason==nil
            and f.publishes==1,"the tracked gate is false and publication was observed")
        local body
        out,body=f.step()
        check(out.phase=="following" and out.stop_reason==nil and body==1,"a neutral following tick reads the body")
        f.set_pad(function(p) p.right_trigger=.25 end)
        out,body=f.step()
        check(out.stop_reason=="selected raw pad left exact zero" and body==0 and f.stops==1,
            "with no mapper, a pad off zero stops the ride before its body read")
    end)
    case("Core admits the selected slot's pad, not slot 0's",function()
        local f=source_fixture({slot=2})
        local out=f.until_phase("following")
        check(out.phase=="following" and out.stop_reason==nil and out.selected_slot==2 and f.user==2,
            "slot 2's neutral pad reaches publication")
        local body
        out,body=f.step()
        check(out.phase=="following" and out.stop_reason==nil and body==1,"and the ride keeps following")
    end)
    case("receipt reads at the per-tick cap",function()
        local admitted=Core.follow_read_admitted
        local used=0
        -- The tick's own receipt, then four probe guards, then the submit guard.
        for _=1,1+Core.probe_batches_per_serial+1 do
            check(admitted(used,0,false),"read "..(used+1).." of the following tick fits")
            used+=1
        end
        check(used==6 and not admitted(used,0,false),"a seventh following read is refused before the SDK call")
        check(not admitted(7,0,false) and not admitted(8,0,false),"overshot counts fail closed")
        check(admitted(6,0,true),"after the stop, reads count against cleanup instead")
    end)
    case("cleanup reads at the cap",function()
        local admitted=Core.follow_read_admitted
        check(admitted(0,399,true) and not admitted(0,400,true) and not admitted(0,401,true),"cleanup stops at 400 reads")
    end)
    case("lease reads at the cap",function()
        check(Core.lease_read_admitted(0) and not Core.lease_read_admitted(1) and not Core.lease_read_admitted(2),
            "one lease report a tick")
    end)
    for _,values in ipairs({{-1,0,false},{.5,0,false},{0/0,0,false},{math.huge,0,false},{"0",0,false},
        {0,-1,true},{0,.5,true},{0,"0",true},{0,0,nil},{0,0,1},{0,0,"true"}}) do
        case("malformed Follow budget",function()
            check(not Core.follow_read_admitted(values[1],values[2],values[3]),"malformed counters or mode cannot admit a read")
        end)
    end
    for _,value in ipairs({-1,.5,0/0,math.huge,"0",nil}) do
        case("malformed lease budget",function()
            check(not Core.lease_read_admitted(value),"malformed lease counter cannot admit a read")
        end)
    end
    local envelopes={
        {"inside",{1.5,0,0},true},
        {"edge",{2,0,0},true},
        {"outside",{2.01,0,0},false},
        {"vertical outside",{0,2.01,0},false},
        {"former ride envelope",{5.9,0,0},false},
    }
    for _,spec in ipairs(envelopes) do
        case("envelope "..spec[1],function()
            local owner,f,sample=visual_fixture()
            local ok,why=owner:follow_visual(sample("2",1/60,spec[2]),1000)
            check(ok==spec[3],"the one tracked envelope literal decides admission")
            check(spec[3] or why=="Body left the 2 m spawn envelope","the refusal names the literal")
            check(f.sets==(spec[3] and 8 or 0),"a refused pose is never placed")
            check(owner.sample.serial==(spec[3] and "2" or "1") and owner.updates==(spec[3] and 1 or 0),
                "a refused pose does not advance visual history")
        end)
    end
    case("envelope uses rotated COM and original spawn origin",function()
        local q={0,math.sqrt(.5),0,math.sqrt(.5)}
        local owner,f,sample=visual_fixture(q,{10,4,-7})
        check(owner:follow_visual(sample("2",1/60,{1.9,0,0}),1000),"translated and rotated spawn accepts bounded movement")
        check(not owner:follow_visual(sample("3",2/60,{2.1,0,0}),1017),"movement stays bounded to the original spawn")
        check(f.sets==8 and owner.sample.serial=="2","an out-of-envelope successor places nothing")
    end)
    case("envelope keeps body and clock checks",function()
        local owner,f,sample=visual_fixture()
        local bad=sample("2",1/60,{1,0,0});bad.mass=0
        check(not owner:follow_visual(bad,1000) and f.sets==0,"sample validation still applies inside the envelope")
        check(owner:follow_visual(sample("2",1/60,{1,0,0}),1000),"a valid pose is admitted")
        check(not owner:follow_visual(sample("3",2/60,{1.1,0,0}),999),"a reversed wall clock is still refused")
        check(not owner:follow_visual(sample("1",0,{1,0,0}),1017),"a regressed native serial is still refused")
    end)
    -- The unmounted spawn's own update loop checks the same literal (Spawn:_update),
    -- with the body still owned by Spawn, so a breach also removes and releases.
    local function update_fixture()
        local f={sets=0,removes=0,releases=0,reads=0}
        local body=newproxy()
        local api={input={focus=function() return {focused=true,gameplay=true,interface_open=false} end},
            entities={set=function() f.sets+=1;return true end,remove=function() f.removes+=1 end},
            world={physics={read=function(b) f.reads+=1;assert(b==body);return f.next end,
                release=function(b) f.releases+=1;return b==body end}}}
        local owner=Spawn.new(api)
        owner.root,owner.rotation={0,-G.com[2],-G.com[3]},{0,0,0,1}
        local base=M.add(owner.root,M.turn(owner.rotation,G.com))
        local function sample(serial,time,delta)
            return {epoch=newproxy(),serial=serial,time=time,seconds=1/60,mass=G.mass,
                position=v(M.add(base,delta or {0,0,0})),rotation=table.clone(owner.rotation),
                velocity=vector.create(0,0,0),angular_velocity=vector.create(0,0,0),inertia=v(G.inertia)}
        end
        owner.body,owner.sample,owner.phase,owner.visual_requested=body,sample("1",0),"spawned",true
        owner.wall,owner.phase_wall,owner.read_wall=1000,1000,1000
        return owner,f,sample
    end
    for _,spec in ipairs({{"inside",{1.5,0,0},true},{"edge",{2,0,0},true},{"outside",{2.01,0,0},false},
        {"vertical outside",{0,-2.01,0},false}}) do
        case("spawn update envelope "..spec[1],function()
            local owner,f,sample=update_fixture()
            f.next=sample("2",1/60,spec[2])
            owner:update(16)
            check(f.reads==1,"one body read per update")
            if spec[3] then
                check(owner.phase=="spawned" and owner.updates==1 and f.sets==8 and owner.sample.serial=="2",
                    "a pose inside the literal is placed and becomes the visual history")
                check(f.removes==0 and f.releases==0,"nothing is cleaned up inside the envelope")
            else
                check(owner.phase=="closed" and owner.detail=="body left the 2 m spawn envelope",
                    "the update loop stops on the one tracked literal and names it")
                check(f.sets==0 and owner.updates==0 and owner.sample.serial=="1","a breaching pose is never placed")
                check(f.removes==8 and f.releases==1 and owner.body==nil and owner.body_release_accepted,
                    "a breach removes all eight parts and releases the Spawn-owned body")
            end
        end)
    end
    return {cases=cases,assertions=assertions,native_actions=0}
end

return table.freeze(Tests)

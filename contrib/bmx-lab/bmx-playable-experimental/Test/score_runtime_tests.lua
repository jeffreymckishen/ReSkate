-- Constructed local ledger facts only. The fixture's newproxy handles and
-- manually qualified landing never prove a real owner, receipt or landing.
local Score=require("./score_runtime")
local Tests={}
local H=1/60
local function fixture()
    local f={body=newproxy(),lease=newproxy(),score=Score.new()}
    function f:at(n)
        local epoch=newproxy()
        local source={lease_handle=self.lease,generation=1,user=0,sequence="7",
            source_epoch="8",context_generation="9",observation_serial=tostring(500+n),
            observed_ms=tostring(1000+n),packet=n}
        local sample={epoch=epoch,serial=tostring(100+n),time=1+n*H,seconds=H,mass=106,
            inertia={x=26,y=32,z=10},position={x=0,y=0,z=0},velocity={x=0,y=0,z=0},
            angular_velocity={x=0,y=0,z=0},rotation={0,0,0,1}}
        return {valid=true,fresh=true,body_handle=self.body,physics_epoch=epoch,
            serial=sample.serial,time=sample.time,seconds=sample.seconds,sample=sample,source=source,
            body={mass=106,inertia_body={26,32,10},center_of_mass={0,0,0},
                linear_velocity={0,0,0},angular_velocity={0,0,0},orientation={0,0,0,1}},
            owner={body_handle=self.body,lease_handle=self.lease},gates={focused=true,menu_open=false}}
    end
    function f:presentation(frame,sequence,channels)
        local events={}
        for _,channel in ipairs(channels or {"barspin"}) do
            events[#events+1]={kind="authored_channel_catch",scope="mod_authored_accepted_step",
                catch_phase="regrip_complete",authored_completion=true,channel=channel,direction=1,
                body_serial=frame.serial,accepted_sequence=sequence,
                source_observation_serial=frame.source.observation_serial,
                prediction_only=true,native_application="unobserved",native_application_observed=false,
                native_catch=false,native_landing=false,landing_quality_available=false,completion_qualified=false}
        end
        return {valid=true,scope="predictive_accepted_ray_barspin_only",serial=frame.serial,
            accepted_sequence=sequence,realized=false,completion_qualified=false,authored_events=events}
    end
    function f:receipt(n,sequence)
        return {sequence=sequence,requested_serial=tostring(100+n),produced_serial=tostring(101+n),
            outcome="applied",force_attempted=true,torque_attempted=true,retained=false,quarantined=false,
            cleanup_disposition="none",successor=self:at(n+2).sample}
    end
    function f:quality(frame)
        return {available=true,qualified=true,scope="measured_mod_landing_v1",serial=frame.serial,
            physics_epoch=frame.physics_epoch,source_observation_serial=frame.source.observation_serial,
            grounded=true,support_known=true,observations_complete=true,owned_bodies_excluded=true,
            native_landing=false,body_up_alignment=1,support_up_alignment=1,heading_cos=1,
            closing_normal_speed=1,settled_seconds=.06666666666666667,settled_samples=4}
    end
    return f
end
function Tests.run()
    local cases,assertions=0,0
    local function check(v,why) assertions+=1;assert(v,why) end
    local function case(name,body)
        cases+=1;local ok,why=pcall(body)
        if not ok then error(name..": "..tostring(why),0) end
    end
    case("queued catch is pending, not applied, landed or banked",function()
        local f=fixture();local frame=f:at(0);local p=f:presentation(frame,"1")
        local quiet=f:presentation(frame,"1");quiet.authored_events=nil
        check(f.score:queue(frame,quiet) and not f.score:view().active,"ordinary adoption is not a trick")
        check(f.score:queue(frame,p),"one accepted regrip prediction")
        local v=f.score:view()
        check(v.pending_points==200 and v.pending_score==300 and v.eligible_pending_score==0,"pending authored values only")
        check(v.banked_total==0 and v.observed_command_tricks==0 and not v.native_score and v.calibration=="C0_UNRUN","no native/calibrated claim")
        for _=1,4 do f.score:view() end
        check(f.score.advance==nil and f.score:view().banked_total==0,"HUD reads and elapsed time cannot credit")
        local receipt=f:receipt(0,"1");receipt.successor=nil
        check(f.score:observe(f:at(1),receipt),"application without successor remains pending")
        check(f.score:view().observed_command_tricks==0,"no N+1-only eligibility")
        receipt.successor=f:at(2).sample
        check(f.score:observe(f:at(2),receipt),"coherent N+2 application observation")
        check(f.score:view().eligible_pending_score==300 and f.score:view().banked_total==0,"application still does not land")
        local land=f:at(6)
        local ok,why=f.score:land(land,{available=false})
        check(not ok and why=="landing_quality_unavailable" and not f.score:view().active,"unqualified contact discards pending air")
        check(f.score:view().banked_total==0 and not f.score:observe(f:at(7),receipt),"late proof cannot resurrect discarded air")
    end)
    case("one confirmed catch banks once after a qualified measured mod landing",function()
        local f=fixture();local frame=f:at(0);local p=f:presentation(frame,"1")
        check(f.score:queue(frame,p),"queue")
        p.authored_events[1].channel="tailwhip"
        check(f.score:view().rows[1].channel=="barspin","caller mutation cannot alter retained edge")
        check(f.score:observe(f:at(2),f:receipt(0,"1")),"observe")
        local land=f:at(6)
        local ok,closed=f.score:land(land,f:quality(land))
        check(ok and closed.outcome=="landed" and closed.score==300 and closed.authored and not closed.native_score,"authored local landing")
        local v=f.score:view()
        check(v.banked_total==300 and v.best_combo==300 and v.landed_combos==1 and not v.active,"one local credit")
        check(not f.score:land(land,f:quality(land)) and f.score:view().banked_total==300,"landing replay cannot credit")
        check(not f.score:queue(frame,f:presentation(frame,"1")) and f.score:view().banked_total==300,"old catch cannot re-enter after bank")
        check(not pcall(function() v.last_closed.score=99999 end),"returned records immutable")
    end)
    case("bar and tail in the same accepted command share one receipt and combo",function()
        local f=fixture();local frame=f:at(0)
        check(f.score:queue(frame,f:presentation(frame,"1",{"barspin","tailwhip"})),"two distinct channels")
        check(f.score:view().tricks==2 and f.score:view().pending_score==1320,"authored combination and category factors")
        check(f.score:observe(f:at(2),f:receipt(0,"1")) and f.score:view().observed_command_tricks==2,"one exact receipt confirms both edges")
        local land=f:at(6);local ok,closed=f.score:land(land,f:quality(land))
        check(ok and closed.points==550 and closed.combo_factor==1.2 and closed.multiplier==2 and closed.score==1320,"bounded combo bank")
    end)
    case("repeated tricks diminish and repeated accepted sequences cannot duplicate them",function()
        local f=fixture();local a=f:at(0);local p=f:presentation(a,"1")
        check(f.score:queue(a,p),"first")
        local ok,why=f.score:queue(a,p)
        check(not ok and why=="stale_sequence" and f.score:view().tricks==1,"same queue edge deduplicated")
        check(f.score:observe(f:at(2),f:receipt(0,"1")),"first observe")
        local b=f:at(4)
        check(f.score:queue(b,f:presentation(b,"2")) and f.score:observe(f:at(6),f:receipt(4,"2")),"second genuine edge")
        local land=f:at(10);local landed,closed=f.score:land(land,f:quality(land))
        check(landed and closed.points==350 and closed.score==525,"same-family repeat penalty from authored defaults")
    end)
    case("partial, refused, expired and stopped work cannot later earn points",function()
        for _,outcome in ipairs({"partial","rejected","expired"}) do
            local f=fixture();local frame=f:at(0)
            check(f.score:queue(frame,f:presentation(frame,"1")),"queue")
            local r=f:receipt(0,"1");r.outcome=outcome
            check(not f.score:observe(f:at(2),r),"unsuccessful command closes pending air")
            local v=f.score:view()
            check(v.stopped and not v.active and v.banked_total==0 and v.last_closed.score==0,"unbanked line lost")
            check(not f.score:observe(f:at(3),f:receipt(0,"1")),"later success cannot promote terminal line")
        end
        local f=fixture();local frame=f:at(0)
        check(f.score:queue(frame,f:presentation(frame,"1")),"cancel queue")
        f.score:cancel("switch")
        check(not f.score:queue(f:at(4),f:presentation(f:at(4),"2")) and f.score:view().banked_total==0,"switch stops this owner ledger")
    end)
    case("exact IDs above double integer precision remain distinct",function()
        local f=fixture();local frame=f:at(0)
        frame.serial,frame.sample.serial="9007199254740993","9007199254740993"
        check(f.score:queue(frame,f:presentation(frame,"9007199254740997")),"exact high serial and sequence")
        local r=f:receipt(0,"9007199254740997")
        r.requested_serial,r.produced_serial="9007199254740993","9007199254740994"
        r.successor.serial="9007199254740995"
        local seen=f:at(2);seen.serial,seen.sample.serial="9007199254740995","9007199254740995"
        check(f.score:observe(seen,r),"exact high successor correlation")
        local land=f:at(6);land.serial,land.sample.serial="9007199254740999","9007199254740999"
        check(f.score:land(land,f:quality(land)) and f.score:view().banked_total==300,"no rounded alias")
    end)
    case("malformed/onset edges and unsupported landing facts fail closed",function()
        for _,mutate in ipairs({
            function(p) p.authored_events[1].catch_phase="started" end,
            function(p) p.authored_events[1].completion_qualified=true end,
            function(p) p.authored_events[1].source_observation_serial="499" end,
            function(p) p.authored_events[3]=p.authored_events[1] end,
        }) do
            local f=fixture();local frame=f:at(0);local p=f:presentation(frame,"1");mutate(p)
            check(not f.score:queue(frame,p) and f.score:view().stopped and f.score:view().banked_total==0,"malformed catch is not HUD credit")
        end
        local f=fixture();local frame=f:at(0)
        check(f.score:queue(frame,f:presentation(frame,"1")) and f.score:observe(f:at(2),f:receipt(0,"1")),"valid pending")
        local land=f:at(6);local quality=f:quality(land);quality.closing_normal_speed=0/0
        check(not f.score:land(land,quality) and f.score:view().banked_total==0 and not f.score:view().active,"nonfinite measured fact cannot land")
        local g=fixture();local start=g:at(0)
        check(g.score:queue(start,g:presentation(start,"1")),"owner queue")
        local changed=g:at(2);changed.source.source_epoch="10"
        check(not g.score:observe(changed,g:receipt(0,"1")) and g.score:view().stopped,"changed source owner cancels")
    end)
    case("capacity is bounded and overflow loses the whole pending air",function()
        local f=fixture()
        for i=0,7 do
            local frame=f:at(i*4)
            check(f.score:queue(frame,f:presentation(frame,tostring(i+1),{"barspin","tailwhip"})),"bounded edge pair")
        end
        local v=f.score:view()
        check(v.tricks==16 and #v.rows==4,"fixed occurrence capacity and four-row HUD")
        local frame=f:at(32);local ok,why=f.score:queue(frame,f:presentation(frame,"9"))
        check(not ok and why=="event_capacity","no silent row drop or capacity widening")
        v=f.score:view()
        check(v.stopped and not v.active and v.banked_total==0 and v.last_closed.tricks==16,"all unbanked work remains lost")
        local kept=v.last_closed.rows
        check(#kept==4 and kept[1].accepted_sequence=="7" and kept[2].accepted_sequence=="7"
            and kept[3].accepted_sequence=="8" and kept[4].accepted_sequence=="8"
            and kept[1].name=="Barspin" and kept[2].name=="Tailwhip"
            and kept[3].name=="Barspin" and kept[4].name=="Tailwhip"
            and kept[1].state=="prediction_only" and kept[4].state=="prediction_only",
            "loss retains only the last four original rows without changing total16 or promoting unconfirmed commands")
    end)
    case("landed labels keep original order and last four detached command states",function()
        local f=fixture();local live
        local channels={"barspin","tailwhip","barspin","tailwhip","barspin"}
        for i,channel in ipairs(channels) do
            local at=(i-1)*4;local frame=f:at(at);local p=f:presentation(frame,tostring(i),{channel})
            check(f.score:queue(frame,p),"one original authored occurrence")
            if i==5 then live=f.score:view().rows end
            p.authored_events[1].channel=channel=="barspin" and "tailwhip" or "barspin"
            check(f.score:observe(f:at(at+2),f:receipt(at,tostring(i))),"matching actual constructed application")
        end
        local land=f:at(22);local ok,closed=f.score:land(land,f:quality(land))
        check(ok and closed.outcome=="landed" and closed.tricks==5 and #closed.rows==4,"five total tricks retain only four original labels")
        local names={"Tailwhip","Barspin","Tailwhip","Barspin"}
        local channel_names={"tailwhip","barspin","tailwhip","barspin"}
        for i,r in ipairs(closed.rows) do
            check(r.name==names[i] and r.channel==channel_names[i]
                and r.body_serial==tostring(100+i*4) and r.accepted_sequence==tostring(i+1)
                and r.state=="force_applied_observed","kept rows2..5 remain in original occurrence order")
        end
        check(live[4].state=="prediction_only" and closed.rows[4].state=="force_applied_observed",
            "earlier pending snapshot is not mutated by later confirmation")
        check(not rawequal(live,closed.rows) and not rawequal(live[1],closed.rows[1]),"closed array and rows are detached snapshots")
        check(table.isfrozen(closed.rows) and table.isfrozen(closed.rows[1]),"dense closed rows and members are frozen")
        check(not pcall(function() closed.rows[1].name="forged" end),"caller cannot rewrite a retained authored label")
        check(not pcall(function() table.insert(closed.rows,closed.rows[1]) end),"caller cannot grow the closed history")
        local banked=f.score:view().banked_total
        f.score:cancel("later empty owner stop")
        check(f.score:view().last_closed==closed and f.score:view().banked_total==banked,"empty stop preserves the closed names and existing bank")
    end)
    case("lost labels retain confirmed and unconfirmed states without promoting either",function()
        local f=fixture();local first=f:at(0)
        check(f.score:queue(first,f:presentation(first,"1")),"first authored row")
        check(f.score:observe(f:at(2),f:receipt(0,"1")),"only first command confirmed")
        local second=f:at(4);local p=f:presentation(second,"2",{"tailwhip"})
        check(f.score:queue(second,p),"second command remains unconfirmed")
        p.authored_events[1].channel="barspin"
        check(f.score:cancel("bail"),"terminal loss")
        local view=f.score:view();local closed=view.last_closed
        check(closed.outcome=="lost" and closed.score==0 and closed.tricks==2 and #closed.rows==2 and view.banked_total==0,
            "lost labels add no banked points")
        check(closed.rows[1].name=="Barspin" and closed.rows[1].body_serial=="100"
            and closed.rows[1].accepted_sequence=="1" and closed.rows[1].state=="force_applied_observed",
            "first row keeps only its command-observation fact")
        check(closed.rows[2].name=="Tailwhip" and closed.rows[2].channel=="tailwhip"
            and closed.rows[2].body_serial=="104" and closed.rows[2].accepted_sequence=="2"
            and closed.rows[2].state=="prediction_only","unconfirmed original second row never becomes an observed catch")
        check(closed.authored and not closed.native_score and not closed.native_landing,"closed provenance stays local authored")
        check(not pcall(function() closed.rows[2].state="force_applied_observed" end),"caller cannot promote lost command evidence")
        check(not f.score:observe(f:at(6),f:receipt(4,"2")) and f.score:view().last_closed.rows[2].state=="prediction_only",
            "late application cannot alter a frozen terminal loss")
    end)
    return {cases=cases,assertions=assertions,constructed=true,native_authority=false,qualification="SOURCE_FIXTURE_ONLY"}
end
return Tests

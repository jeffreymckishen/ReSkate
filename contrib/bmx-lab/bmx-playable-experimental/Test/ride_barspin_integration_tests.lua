-- One focused integration trace over the real Ride and selected-source mapper.
-- Every SDK/body/ray/receipt below is CONSTRUCTED; this is not game evidence.
local Fixtures=require("./ride_runtime_tests")
local Identity=require("./lease_identity")
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
    function f.tick(grounded,left)
        if f.started then f.advance() end
        f.started=true;f.clear=not grounded
        f.pad.right_y=left and -1 or 0;f.pad.buttons.lb=left==true
        return f.observe()
    end
    return f
end
function Tests.run()
    local assertions=0
    local function check(v,why) assertions+=1;assert(v,why) end
    local f=fixture()
    local prime=f.tick(true)
    check(not prime.stop_requested and prime.submitted==1,"qualified constructed neutral ground rides")
    check(prime.model.accepted_barspin.revision==1 and prime.presentation_pose.barspin==0,
        "neutral bar channel adopts only with first exact command")
    local air=f.tick(false)
    check(not air.stop_requested and air.submitted==2,"paired clear rays retain existing force path")
    local revision=air.model.accepted_barspin.revision
    local kept=air.presentation_pose
    f.refusal="force_pipeline_full"
    local refused=f.tick(false,true)
    check(not refused.stop_requested and refused.submitted==2,"constructed native capacity refusal keeps Ride alive")
    check(refused.model.accepted_barspin.revision==revision and refused.presentation_pose==kept,
        "true mapped barspin candidate changes neither accepted state nor pose on refusal")
    check(not refused.model.accepted_barspin.rotation_reserved,"unadopted gesture never reserves accepted channel")
    f.refusal=nil
    local held=f.tick(false,true)
    check(not held.stop_requested and held.submitted==3 and held.presentation_pose.barspin==0,
        "next accepted held selection does not replay the refused source edge")
    check(not held.model.accepted_barspin.rotation_reserved,"discarded edge leaves no latent spin")
    f.tick(false)
    local selected=f.tick(false,true)
    check(not selected.stop_requested and selected.model.accepted_barspin.rotation_reserved,
        "fresh neutral then real LB/down selection starts accepted bar channel")
    check(selected.presentation_pose.barspin==0,"existing model starts rotation at selecting sample end")
    check(selected.presentation_trick.accepted_sequence==selected.model_history.sequence
        and selected.model.accepted_barspin.accepted_sequence==selected.model_history.sequence,
        "barspin adoption names that exact advancing native command")
    local turning=f.tick(false)
    check(not turning.stop_requested and turning.presentation_pose.barspin<0,
        "next accepted body step publishes existing authored left-barspin motion")
    check(turning.presentation_trick.visual_targets.barspin==turning.presentation_pose.barspin,
        "visible angle comes from that accepted candidate")
    check(turning.presentation_trick.realized==false and turning.presentation_trick.completion_qualified==false
        and turning.presentation_trick.visual_targets.native_collision_contact==false
        and turning.presentation_trick.visual_targets.landing_quality_available==false,
        "ray policy never becomes physical completion or landing proof")
    check(turning.presentation_trick.score==nil and turning.presentation_trick.model_events==nil,
        "no invented score or completed-trick events")
    local count=#f.commands
    local duplicate=f.observe()
    check(duplicate.model.accepted_barspin.revision==turning.model.accepted_barspin.revision
        and duplicate.presentation_pose==turning.presentation_pose and #f.commands==count,
        "duplicate body reading cannot adopt a barspin twice")
    local stopped=f.ride:stop("constructed recovery or switch")
    check(stopped.stop_requested and stopped.model.accepted_barspin.stopped,
        "existing owner stop cancels accepted-step channel")
    check(stopped.presentation_pose.barspin==0 and stopped.presentation_trick==nil,
        "cancel clears authored angle and targets for recovery/switch")
    check(#f.commands==count,"barspin cleanup adds no native command")
    return {cases=1,assertions=assertions}
end
return table.freeze(Tests)
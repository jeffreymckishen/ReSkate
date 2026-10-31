-- Constructed Ride/native boundaries only. A test landing record cannot prove
-- native catch, physical landing, calibration or the historical R57 gesture.
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
        local n=string.byte(v,i)-48+carry;out[i]=string.char(48+n%10);carry=n>=10 and 1 or 0
    end
    return (carry==1 and "1" or "")..table.concat(out)
end
local function fixture()
    local f
    local landing={}
    function landing:step(frame,contact,proof)
        assert(#proof.applied_successors<=3,"same bounded actual receipt projection")
        local landed=f.want_land and contact.grounded
        local quality=landed and {available=true,qualified=true,scope="measured_mod_landing_v1",
            serial=frame.serial,physics_epoch=frame.physics_epoch,source_observation_serial=frame.source.observation_serial,
            grounded=true,support_known=true,observations_complete=true,owned_bodies_excluded=true,native_landing=false,
            body_up_alignment=1,support_up_alignment=1,heading_cos=1,closing_normal_speed=0,
            settled_seconds=.06666666666666667,settled_samples=4} or nil
        return {serial=frame.serial,phase=landed and "landed" or contact.grounded and "grounded" or "airborne",
            landed=landed==true,quality=quality,accepting_catches=not contact.grounded}
    end
    function landing:cancel() end
    f=Fixtures.fixture({models={tricks=false,score_landing=landing}})
    local decode=f.contact.decode
    function f.contact.decode(...)
        local out=decode(...);out.status="available"
        out.query.accounting_known=true;out.query.measurements_complete=true
        return out
    end
    f.native={};f.rows={};f.commands={};f.next_sequence="9007199254745001"
    local function refresh()
        for _,r in ipairs(f.native) do
            if r.outcome=="queued" and Identity.compare(f.serial,r.produced)>=0 then r.outcome="applied" end
            if r.outcome=="applied" and not r.successor and Identity.compare(f.serial,r.produced)>0 then r.successor=copy(f.sample()) end
        end
    end
    function f.api.submit(epoch,command)
        refresh();assert(epoch==f.read.epoch,"current original constructed admission")
        if f.refusal then return false,f.refusal end
        f.next_sequence=inc(f.next_sequence)
        local r={sequence=f.next_sequence,requested=f.serial,produced=inc(f.serial),outcome="queued"}
        f.rows[r.sequence]=r;f.native[#f.native+1]=r;f.commands[#f.commands+1]=copy(command)
        return true,nil,r.sequence
    end
    function f.api.receipt(sequence)
        refresh();local r=f.rows[sequence];assert(r,"same retained constructed sequence")
        local applied=r.outcome=="applied"
        return {sequence=r.sequence,requested_serial=r.requested,produced_serial=applied and r.produced or "0",
            outcome=r.outcome,force_attempted=applied,torque_attempted=applied,retained=false,quarantined=false,
            cleanup_disposition="none",successor=r.successor}
    end
    function f.api.acknowledge(sequence)
        refresh();assert(f.native[1] and f.native[1].sequence==sequence,"same oldest-first native ACK")
        table.remove(f.native,1);return true
    end
    function f.tick(grounded,held)
        if f.started then f.advance() end
        f.started=true;f.clear=not grounded
        f.pad.right_x=held and -1 or 0;f.pad.right_y=0
        f.pad.buttons.lb=held==true;f.pad.buttons.rb=false
        f.pad.left_trigger=0;f.pad.right_trigger=0
        return f.observe()
    end
    function f.start_full()
        f.tick(true);f.tick(false);f.tick(false,true)
        local row
        for _=1,12 do row=f.tick(false,true) end
        return row
    end
    return f
end
local function pose_event(row)
    local p=row.presentation_trick
    if p and p.authored_events then
        for _,e in ipairs(p.authored_events) do if e.channel=="one_hander" then return e end end
    end
    return nil
end
function Tests.run()
    local cases,assertions=0,0
    local function check(v,why) assertions+=1;assert(v,why) end
    local function case(name,body)
        cases+=1;local ok,why=pcall(body);if not ok then error(name..": "..tostring(why),0) end
    end
    case("full entry and completed airborne recovery seed local pending points only",function()
        local f=fixture();local held=f.start_full()
        check(not held.stop_requested and held.presentation_pose.release_left_hand==1,"full held authored pose")
        check(pose_event(held)==nil and held.mod_score.tricks==0,"holding a released hand earns nothing")
        local completed
        for _=1,12 do
            local row=f.tick(false)
            check(not row.stop_requested,"accepted recovery remains in the same ride")
            if pose_event(row) then completed=row;break end
            check(row.mod_score.tricks==0,"incomplete recovery remains unscored")
        end
        check(completed~=nil,"one full accepted airborne recovery edge")
        local e=pose_event(completed)
        check(e.kind=="authored_pose_recovery" and e.movement_id==36 and e.side=="left" and e.direction==nil,
            "pose identity has no fabricated rotation direction")
        check(e.catch_phase=="regrip_complete" and e.authored_completion and e.prediction_only
            and e.native_application=="unobserved" and not e.native_application_observed
            and not e.native_catch and not e.native_landing and not e.completion_qualified,"truthful local completion only")
        check(completed.presentation_pose.release_left_hand==nil or completed.presentation_pose.release_left_hand==0,"accepted hand release returns to zero")
        check(completed.mod_score.tricks==1 and completed.mod_score.pending_score==150
            and completed.mod_score.observed_command_tricks==0 and completed.mod_score.banked_total==0,"authored100 plus category, not yet applied/landed")
        local read=f.ride:status();check(read.mod_score.tricks==1,"status reread cannot repeat the edge")
        f.tick(false);local observed=f.tick(false)
        check(observed.mod_score.observed_command_tricks==1 and observed.mod_score.eligible_pending_score==150
            and observed.mod_score.banked_total==0,"matching full native successor establishes only eligibility")
        f.want_land=true;local landed=f.tick(true)
        check(landed.mod_score.banked_total==150 and landed.mod_score.last_closed.outcome=="landed"
            and landed.mod_score.calibration=="C0_UNRUN" and not landed.mod_score.native_score,
            "only separately fixture-qualified mod landing banks local uncalibrated points")
        f.ride:stop("constructed completed pose cleanup")
    end)
    case("a brief visible hand release does not count as full authored entry",function()
        local f=fixture();f.tick(true);f.tick(false);f.tick(false,true)
        local partial=f.tick(false,true)
        check(partial.presentation_pose.release_left_hand>0,"visible partial release exists")
        for _=1,12 do
            local row=f.tick(false)
            check(not row.stop_requested and pose_event(row)==nil and row.mod_score.tricks==0,"early recovery is not a completed full pose")
        end
        f.want_land=true;local land=f.tick(true)
        check(land.mod_score.banked_total==0 and land.mod_score.landed_combos==0,"a later clean support record cannot invent the missing pose")
        f.ride:stop("constructed early release cleanup")
    end)
    case("measured recontact cancels an unfinished recovery rather than manufacturing catch",function()
        local f=fixture();f.start_full();f.tick(false);local recovering=f.tick(false)
        check(recovering.presentation_pose.release_left_hand>0 and pose_event(recovering)==nil,"recovery not complete")
        f.want_land=true;local land=f.tick(true)
        check(not land.stop_requested and pose_event(land)==nil and land.mod_score.tricks==0 and land.mod_score.banked_total==0,
            "ground reset is not an authored recovery event")
        for _=1,3 do
            local later=f.tick(true)
            check(pose_event(later)==nil and later.mod_score.banked_total==0,"no late grounded completion or replay")
        end
        f.ride:stop("constructed partial landing cleanup")
    end)
    case("a refused final recovery candidate earns nothing and a later accepted edge is one shot",function()
        local f=fixture();f.start_full();f.tick(false)
        for _=1,7 do f.tick(false) end
        local before=#f.commands;f.refusal="force_pipeline_full"
        for _=1,2 do
            local refused=f.tick(false)
            check(not refused.stop_requested and pose_event(refused)==nil and refused.mod_score.tricks==0
                and #f.commands==before,"unadopted final recovery does not publish a local score edge")
        end
        f.refusal=nil;local completed=f.tick(false)
        check(pose_event(completed)~=nil and completed.mod_score.tricks==1 and completed.mod_score.banked_total==0,
            "only the next exact accepted recovery creates pending points")
        local later=f.tick(false)
        check(pose_event(later)==nil and later.mod_score.tricks==1,"new ordinary adoption does not re-emit pose recovery")
        f.ride:stop("constructed refused candidate cleanup")
        check(f.ride:status().mod_score.banked_total==0,"stop never banks pending authored points")
    end)
    return {cases=cases,assertions=assertions,constructed=true,native_authority=false,qualification="SOURCE_FIXTURE_ONLY"}
end
return Tests

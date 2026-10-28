local Fixture=require("./two_cycle_fixture")
local Tests={}
function Tests.run()
    local n=0
    local function check(v,why) n+=1;assert(v,why) end
    local f=Fixture.new(check)
    check(Fixture.Core.experimental_two_cycle_owner()==nil,"another experimental manager cannot reset VM ownership")
    local legacy=Fixture.Core.new(f.R,{qualification_only=true})
    check(not legacy:request_mount(f.user),"a legacy Core cannot bypass the consumed VM attempt")
    local old_stop=f.T.stop_at
    f.prepare_504()
    local tests={
        {"Source pending",function(t)t.source_armed=true;t.source_record={cleanup_pending=true}end},
        {"Follow unACKed",function(t)t.acknowledged=false end},
        {"Follow incomplete",function(t)t.completed_ack=false end},
        {"force unknown",function(t)t.ride_unknown=true end},
        {"pose not released",function(t)t.pose_status={state="off",stopped=true,nil_accepted=false}end},
        {"board restore unknown",function(t)t.board_status={state="restore_unknown",clear_result="raised"}end},
        {"park absent",function(t)local x=Fixture.copy(t.terminal);x.park_observed=false;t.terminal=x end},
        {"unmatched revision",function(t)local x=Fixture.copy(t.terminal);x.returned_revision="8";t.terminal=x end},
        {"pending final",function(t)local x=Fixture.copy(t.terminal);x.pending={1};t.terminal=x end},
        {"expired cleanup",function(t)t.cleanup_expired=true end},
        {"clock unknown",function(t)t.clock_unknown=true end},
        {"marker unknown",function(t)t.marker_unknown=true end},
    }
    -- Each check changes exactly one PRIVATE constructed proof, restores it,
    -- and calls only the non-consuming readiness query. Public Entry failure
    -- tests separately require irreversible intent consumption.
    for _,spec in tests do
        local before={}
        for k,v in f.T do before[k]=v end
        spec[2](f.T)
        local ok=f.owner:ready()
        -- source_record is diagnostic, not authority: the actual Source below
        -- is already ACKed. This first mutation must not forge a new debt fact.
        if spec[1]=="Source pending" then check(ok,"a forged diagnostic cannot replace actual Source proof")
        else check(not ok,"reject one missing clean conjunct: "..spec[1]) end
        for k in f.T do f.T[k]=nil end
        for k,v in before do f.T[k]=v end
    end
    check(f.owner:ready(),"all actual private clean proofs restored")
    local old_core=f.core
    local next_state=f.second_state()
    local next_core,why=f.owner:successor(f.R,{qualification_only=true},next_state)
    check(next_core~=nil,"exact two-archive private handoff succeeds: "..tostring(why))
    check(f.T.session_retired==true and f.T.stop_at==old_stop,"old session is inert without changing its watchdog")
    check(f.records.bmx_bike_cycle_1_stock100_v1.equipment.expected_state==100,"original Return100 archive retained")
    check(f.records.bmx_bike_cycle_1_onfoot504_v1.equipment.expected_state==504,"distinct post504 archive retained")
    check(f.records.bmx_bike_cycle_1_onfoot504_v1.equipment.attempt>
        f.records.bmx_bike_cycle_1_stock100_v1.equipment.attempt,"old100 ACK cannot credit the newer504 target")
    check(f.records.bmx_bike_cycle_1_stock100_v1.terminal_receipt.native_retirement_known==false,
        "archive never promotes native retirement")
    for _,key in {"bmx_bike_cycle_1_stock100_v1","bmx_bike_cycle_1_onfoot504_v1"} do
        local row=f.records[key]
        check(row.phase=="done" and row.bike_cleanup_complete and row.bike_authority==false
            and row.cleanup_pending==false and row.cleanup_unknown==false and row.stock_toggle_blocked==false,
            "actual archived row retains all clean conjuncts without busy contamination")
        check(row.native_retirement_known==false,"experimental top-level history explicitly retains unknown native retirement")
    end
    check(f.records.bmx_bike_lifecycle_v1.experimental_session==2,"successor active marker is accepted before actuation")
    local calls,saves=#f.calls,#f.saves
    old_core:step(16);old_core:request_stop("late old callback");old_core:unload()
    check(#f.calls==calls and #f.saves==saves,"old callback/step/unload cannot issue any SDK call or ledger write")
    check(f.owner:successor(f.R,{qualification_only=true},f.second_state())==nil,"third Core is denied before construction")
    check(next_core:prepare_backend(),"fresh Core binds fresh Source/Spawn/pose owners")
    check(next_core:request_mount(f.user),"second private Core consumes a distinct original mount attempt")
    check(not next_core:request_mount(f.user),"the second Core cannot request a second allocation itself")
    for _=1,42 do f.now+=16;next_core:step(16) end
    check(f.count("lease")==2 and f.handle~=nil,"second Core obtains a NEW selected lease after prior ACK")
    check(next_core:status().experimental_attempt_limit==2,"scope is explicitly bounded")
    return {cases=1,assertions=n,native_authority=false,constructed=true}
end
return Tests

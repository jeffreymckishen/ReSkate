-- Constructed accepted-command traces only; no game, physical catch, or score proof.
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
    local f=Fixtures.fixture({models={tricks=false}})
    local decode=f.contact.decode
    function f.contact.decode(...)
        local out=decode(...)
        out.status="available";out.query.accounting_known=true;out.query.measurements_complete=true
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
        refresh();assert(epoch==f.read.epoch,"current constructed body epoch")
        if f.refusal then return false,f.refusal end
        f.next_sequence=inc(f.next_sequence)
        local r={sequence=f.next_sequence,requested=f.serial,produced=inc(f.serial),outcome="queued"}
        f.rows[r.sequence]=r;f.native[#f.native+1]=r;f.commands[#f.commands+1]=copy(command)
        return true,nil,r.sequence
    end
    function f.api.receipt(sequence)
        refresh();local r=f.rows[sequence];assert(r,"retained exact constructed sequence")
        local applied=r.outcome=="applied"
        return {sequence=r.sequence,requested_serial=r.requested,produced_serial=applied and r.produced or "0",
            outcome=r.outcome,force_attempted=applied,torque_attempted=applied,retained=false,quarantined=false,
            cleanup_disposition="none",successor=r.successor}
    end
    function f.api.acknowledge(sequence)
        refresh();assert(f.native[1] and f.native[1].sequence==sequence,"oldest exact sequence")
        table.remove(f.native,1);return true
    end
    function f.tick(grounded,selection)
        if f.started then f.advance() end
        f.started=true;f.clear=not grounded
        local tail=selection=="tail_right"
        f.pad.right_x=tail and 1 or 0;f.pad.right_y=selection=="bar_left" and -1 or 0
        f.pad.buttons.lb=selection=="bar_left";f.pad.buttons.rb=false
        f.pad.left_trigger=tail and 1 or 0;f.pad.right_trigger=tail and 1 or 0
        return f.observe()
    end
    return f
end
local function events(row)
    local p=row.presentation_trick
    return p and p.authored_events or nil
end
function Tests.run()
    local assertions=0
    local function check(v,why) assertions+=1;assert(v,why) end
    for _,channel in ipairs({{name="barspin",selection="bar_left",direction=-1},
        {name="tailwhip",selection="tail_right",direction=1}}) do
        local f=fixture();f.tick(true);f.tick(false)
        local selected=f.tick(false,channel.selection)
        check(selected.model.accepted_barspin.rotation_reserved,"fresh selection starts authored turn")
        local release=channel.name.."_release"
        local onset
        for _=1,40 do
            local row=f.tick(false)
            check(not row.stop_requested,"bounded constructed turn remains running")
            -- Smoothstep can round the wrapped angle to neutral one step before
            -- elapsed reaches the turn duration. Require the accepted phase too.
            if not row.model.accepted_barspin.rotation_reserved
                and math.abs(row.presentation_pose[channel.name])<1e-9 and row.presentation_pose[release]==1 then
                onset=row;break
            end
        end
        check(onset~=nil,"authored turn reaches wrapped neutral and starts its re-grip blend")
        check(events(onset)==nil,"starting a catch blend is not its completed authored catch")
        local busy=f.tick(false,channel.selection)
        check(not busy.stop_requested and not busy.model.accepted_barspin.rotation_reserved,
            "a fresh request cannot truncate the previous catch blend")
        check(math.abs(busy.presentation_pose[channel.name])<1e-9
            and busy.presentation_pose[release]>0 and busy.presentation_pose[release]<1,
            "accepted busy selection advances only the incomplete re-grip")
        check(events(busy)==nil,"partial catch blend emits no completion fact")
        local kept=busy.presentation_pose;local revision=busy.model.accepted_barspin.revision
        f.refusal="force_pipeline_full"
        local refused=f.tick(false,channel.selection)
        check(not refused.stop_requested and refused.presentation_pose==kept
            and refused.model.accepted_barspin.revision==revision,"refusal changes neither blend nor accepted facts")
        f.refusal=nil
        local held,completed,event_count,completion_source
        event_count=0
        for _=1,4 do
            held=f.tick(false,channel.selection)
            if events(held) then completed=held;completion_source=f.input_serial;event_count+=#events(held) end
        end
        check(completed~=nil and event_count==1,"re-grip completion emits exactly one accepted catch edge")
        local rows=events(completed)
        check(#rows==1 and rows[1].channel==channel.name and rows[1].direction==channel.direction,
            "one bounded fact names the completed channel and direction")
        local e=rows[1]
        check(e.kind=="authored_channel_catch" and e.scope=="mod_authored_accepted_step"
            and e.catch_phase=="regrip_complete" and e.authored_completion==true,
            "catch fact names the completed authored phase rather than native catch")
        check(e.body_serial==completed.model_history.serial and e.accepted_sequence==completed.model_history.sequence,
            "catch fact binds exact completion body and admission sequence")
        check(e.source_observation_serial==completion_source,"catch fact retains the exact completion source observation")
        check(e.prediction_only==true and e.native_application=="unobserved" and e.native_application_observed==false
            and e.native_catch==false and e.native_landing==false and e.landing_quality_available==false
            and e.completion_qualified==false and e.score==nil,"queued prediction fabricates no physical completion or score")
        check(table.isfrozen(rows) and table.isfrozen(e),"adopted catch facts are immutable")
        check(math.abs(completed.presentation_pose[channel.name])<1e-9 and completed.presentation_pose[release]==nil,
            "authored completion reaches neutral with zero release")
        check(not held.model.accepted_barspin.rotation_reserved and math.abs(held.presentation_pose[channel.name])<1e-9
            and held.presentation_pose[release]==nil,"busy held request stays consumed after the blend finishes")
        check(events(held)==nil,"completed catch edge does not repeat on the next accepted step")
        f.tick(false)
        local fresh=f.tick(false,channel.selection)
        check(fresh.model.accepted_barspin.rotation_reserved,"new neutral then selection starts the next turn")
        local count=#f.commands
        local stopped=f.ride:stop("constructed switch or recovery")
        check(stopped.model.accepted_barspin.stopped and stopped.presentation_trick==nil
            and stopped.presentation_pose[channel.name]==0,"stop cancels presentation and pending catch facts")
        check(#f.commands==count,"catch stop creates no additional physics command")
    end
    -- Offset starts by six accepted samples: the .55/.45 second turns and
    -- original .06 second re-grip blends complete together at this cadence.
    local both=fixture();both.tick(true);both.tick(false);both.tick(false,"tail_right")
    for _=1,5 do both.tick(false) end
    both.tick(false,"bar_left")
    local paired
    for _=1,45 do
        local row=both.tick(false)
        check(not row.stop_requested,"bounded paired turn remains running")
        if events(row) then paired=row;break end
    end
    check(paired~=nil and #events(paired)==2,"one accepted command carries at most two completed catch edges")
    local a,b=events(paired)[1],events(paired)[2]
    check(a.channel=="barspin" and b.channel=="tailwhip" and a.accepted_sequence==b.accepted_sequence
        and a.body_serial==b.body_serial,"paired catch facts retain stable order and exact common admission")
    local next_row=both.tick(false)
    check(events(next_row)==nil,"paired catch edges do not replay on the next accepted step")
    both.ride:stop("constructed paired cleanup")
    return {cases=3,assertions=assertions}
end
return table.freeze(Tests)

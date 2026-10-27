-- Independently authored gesture traces over the real Lua mapper. All source,
-- support and body-step facts below are constructed; none is game authority.
-- No API, force solver, native owner or runner is invoked at module load.
local Mapping = require("./ride_input_mapping")
local Input = require("./input")
local Tests = {}
local function copy(value)
    if type(value)~="table" then return value end
    local out={} for key,child in pairs(value)do out[key]=copy(child)end return out
end
local function increment(value)
    local out,carry={},1
    for at=#value,1,-1 do
        local n=string.byte(value,at)-48+carry
        if n==10 then n,carry=0,1 else carry=0 end
        table.insert(out,1,string.char(48+n))
    end
    if carry==1 then table.insert(out,1,"1")end
    return table.concat(out)
end
local function pad(changes)
    local p={left_x=0,left_y=0,right_x=0,right_y=0,left_trigger=0,right_trigger=0,
        playstation=false,buttons={a=false,b=false,right_stick=false,lb=false,rb=false}}
    for key,value in pairs(changes or{})do
        if key=="buttons" then for name,pressed in pairs(value)do p.buttons[name]=pressed end else p[key]=value end
    end
    return p
end
local function fixture(settings)
    local f={mapping=Mapping.new(settings),serial="9007199254741001",ms="9007199254742000",generation=1,lease_handle=newproxy(),
        sequence="9007199254740995",source_epoch="9007199254741009",context_epoch="9007199254741011",user=2,
        context={grounded=true,focused=true,menu_open=false,rotation_reserved=false},pad=pad()}
    function f.frame()
        return {input_ok=true,phase="capturing",reason="fixture",generation=f.generation,new_observation=true,lease_handle=f.lease_handle,
            sample={pad=copy(f.pad),user=f.user,sequence=f.sequence,source_epoch=f.source_epoch,
                context_generation=f.context_epoch,observation_serial=f.serial,observed_ms=f.ms,packet=17}}
    end
    function f.observe(p,elapsed,context)
        f.serial=increment(f.serial)
        for _=1,elapsed or 10 do f.ms=increment(f.ms)end
        f.pad=copy(p or pad())
        f.last_frame=f.frame()
        return f.mapping:observe(f.last_frame,context or f.context)
    end
    function f.controls(changes)
        local step={physics_epoch=newproxy(),h=.01666666567325592,grounded=f.context.grounded,rotation_reserved=f.context.rotation_reserved}
        for key,value in pairs(changes or{})do step[key]=value end
        return f.mapping:controls(step)
    end
    function f.prime()
        f.observe(pad(),0)
        return f.observe(pad(),10)
    end
    function f.r3()
        return f.observe(pad({buttons={right_stick=true}}),1)
    end
    return f
end

-- Local suppression either retires unclaimed intent or drops a new edge
-- beside a constructed receipt owner. No fixture supplies native evidence.
function Tests.run()
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    cases+=1 do
        local f=fixture();f.prime();f.r3()
        local before=f.controls();local id=before.hop.id
        check(f.mapping:retire_hop(id+1,"suppressed")==false and f.mapping:status().pending_hop.id==id,
            "a wrong identity cannot suppress a different pending request")
        local ok,why=f.mapping:retire_hop(id,"suppressed")
        local state,row=f.mapping:status(),f.controls()
        check(ok==true and why=="none" and state.valid and state.active and state.pending_hop==nil,
            "the exact suppressed ID retires without invalidating active continuous input")
        check(state.last_retired.disposition=="suppressed" and state.last_retired.event.id==id and state.uncertain==nil,
            "suppression remains distinct from accepted, cancelled and uncertain native outcomes")
        check(row.valid and row.submission_allowed and row.hop==nil and row.force_controls.hop_event_id==0
            and row.force_controls.hop_strength==0 and row.actions.hop_pressed==false and row.actions.hop_strength==0,
            "fresh controls and actions contain no stale hop after retirement")
        check(row.source.observation_serial==before.source.observation_serial and row.source.observed_ms==before.source.observed_ms
            and state.hop_counter==1,"pure retirement consumes no source observation, clock step or event ID")
        check(f.mapping:retire_hop(id,"suppressed")==false and f.mapping:status().last_retired.disposition=="suppressed",
            "policy retirement cannot be replayed as a second disposition")
    end
    cases+=1 do
        local f=fixture();f.prime();f.r3();local id=f.controls().hop.id
        check(f.mapping:retire_hop(id,"suppressed"),"retire initial policy-only hop")
        for _=1,12 do f.observe(pad({buttons={right_stick=true,a=true}}),17) end
        local state,row=f.mapping:status(),f.controls()
        check(state.pending_hop==nil and state.hop_counter==1 and row.valid and row.force_controls.pedal==1,
            "held hop and pedal stay usable for 204 ms without minting repeated events or needing neutral")
        f.observe(pad({buttons={a=true}}),17);f.r3()
        local second=f.controls().hop.id
        check(second==id+1 and f.mapping:retire_hop(second,"suppressed"),"a new physical edge keeps the lifetime ID monotonic")
        check(f.controls().valid and f.mapping:status().last_retired.event.id==second,"second suppression preserves valid input")
    end
    for _,disposition in ipairs({"accepted","cancelled","uncertain"}) do cases+=1 do
        local f=fixture();f.prime();f.r3();local id=f.controls().hop.id
        check(f.mapping:retire_hop(id,disposition) and f.mapping:status().last_retired.disposition==disposition,
            "the pre-existing explicit disposition remains unchanged")
        local row,state=f.controls(),f.mapping:status()
        if disposition=="accepted" then
            check(row.valid and row.force_controls.hop_event_id==0 and state.uncertain==nil,"accepted retains its prior active control behavior")
        elseif disposition=="cancelled" then
            check(not row.valid and state.uncertain==nil,"cancelled retains its prior neutral re-prime requirement")
        else check(not row.valid and state.uncertain and state.uncertain.id==id,"uncertain still retains the original unresolved event") end
    end end
    cases+=1 do
        local f=fixture();f.prime()
        f.observe(pad({right_y=-1}),10);f.observe(pad(),1)
        f.observe(pad({right_y=1}),1)
        local original=f.controls().hop
        check(original.strength>=.25 and original.strength<1 and f.mapping:claim_hop(original.id),
            "a weak first hop has an exact accepted command owner")
        f.observe(pad({buttons={a=true}}),1)
        local dropped=f.observe(pad({buttons={right_stick=true,a=true}}),1)
        local state,row=f.mapping:status(),f.controls()
        check(f.context.grounded and dropped.valid and dropped.active and dropped.new_observation
            and dropped.issue=="hop_press_suppressed" and state.issue=="hop_press_suppressed",
            "a second grounded R3 press is recorded as dropped without breaking input cadence")
        check(not dropped.actions.hop_pressed and dropped.actions.hop_strength==0
            and not row.actions.hop_pressed and row.actions.hop_strength==0,
            "the new gesture pulse and strength cannot reach another consumer")
        check(row.valid and row.submission_allowed and row.force_controls.pedal==1 and row.force_controls.pump_inhibited,
            "continuous input survives while the original pending hop still inhibits pump")
        check(state.pending_hop.id==original.id and state.pending_hop.strength==original.strength
            and row.force_controls.hop_event_id==original.id and row.force_controls.hop_strength==original.strength,
            "a full-strength second press neither replaces nor strengthens the accepted weak hop")
        check(state.hop_counter==original.id and state.last_retired==nil and state.uncertain==nil,
            "dropping the new press mints no ID and assigns no disposition to the original")
        check(state.pending_hop.observation_serial==original.observation_serial
            and state.pending_hop.observed_ms==original.observed_ms,
            "accepted event provenance remains the original observation")
        for name,value in pairs(original.source) do
            if type(value)~="table" then
                check(state.pending_hop.source[name]==value,"accepted source field remains exact: "..name)
            end
        end
        check(state.pending_hop.source.pad.right_y==1 and not state.pending_hop.source.pad.buttons.right_stick,
            "the retained source pad is the original weak flick, not the suppressed R3 press")
        local claimed,claim_issue=f.mapping:claim_hop(original.id)
        local retired,retire_issue=f.mapping:retire_hop(original.id,"suppressed")
        check(not claimed and claim_issue=="hop_receipt_pending" and not retired and retire_issue=="hop_receipt_pending",
            "dropping a press preserves receipt ownership and forbids policy retirement")
        local duplicate=f.mapping:observe(f.last_frame,f.context)
        check(duplicate.valid and not duplicate.new_observation and not duplicate.actions.hop_pressed
            and f.mapping:status().hop_counter==original.id,
            "re-reading the suppressed source observation cannot replay its pulse")
        check(f.mapping:retire_hop(original.id,"accepted"),"only the actual accepted disposition retires the old hop")
        for _=1,3 do
            f.observe(pad({buttons={right_stick=true,a=true}}),17)
            local held=f.controls()
            check(held.valid and held.hop==nil and not held.actions.hop_pressed and held.force_controls.hop_event_id==0,
                "holding the dropped press through ACK never replays it")
        end
        check(f.mapping:status().hop_counter==original.id,"ACK and held observations do not consume another lifetime ID")
        f.observe(pad(),1);local next=f.r3()
        check(next.actions.hop_pressed and next.hop.id==original.id+1,
            "only a fresh release and press after ACK creates the next lifetime hop")
    end
    for _,disposition in ipairs({"cancelled","uncertain"}) do cases+=1 do
        local f=fixture();f.prime();f.r3();local original=f.controls().hop
        check(f.mapping:claim_hop(original.id),"terminal receipt fixture claims the first hop")
        f.observe(pad(),1);local dropped=f.r3()
        check(dropped.valid and dropped.issue=="hop_press_suppressed","second press stays local while receipt is outstanding")
        check(f.mapping:retire_hop(original.id,disposition),"original receipt retains its terminal disposition")
        local state,row=f.mapping:status(),f.controls()
        check(state.pending_hop==nil and state.hop_counter==original.id and not row.valid
            and state.last_retired.disposition==disposition and state.last_retired.event.id==original.id,
            "dropped press cannot hide or replace a terminal receipt")
        if disposition=="uncertain" then
            check(state.uncertain.id==original.id and state.uncertain.observation_serial==original.observation_serial,
                "uncertainty remains attached to the original accepted event")
        else check(state.uncertain==nil,"a rejected command's cancellation does not invent uncertainty") end
        f.r3()
        check(f.mapping:status().hop_counter==original.id and not f.controls().valid,
            "holding the second press cannot bypass terminal outcome handling")
    end end
    cases+=1 do
        local f=fixture();f.prime();f.r3();local original=f.controls().hop
        f.observe(pad(),1);local second=f.r3()
        local state=f.mapping:status()
        check(not second.valid and second.issue=="hop_pending_conflict" and not f.controls().valid,
            "a conflicting unclaimed hop still refuses instead of silently dropping intent")
        check(state.pending_hop.id==original.id and state.hop_counter==original.id and state.last_retired==nil,
            "unclaimed conflict preserves its original unresolved event")
    end
    return {cases=cases,assertions=assertions,native_actions=0}
end
return Tests

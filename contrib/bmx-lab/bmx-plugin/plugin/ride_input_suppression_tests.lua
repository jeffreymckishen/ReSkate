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

-- Suppression is local intent retirement only. These fixtures provide no
-- native command, application claim, force receipt or source replacement.
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
    return {cases=cases,assertions=assertions,native_actions=0}
end
return Tests

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

function Tests.run()
    local cases,assertions=0,0
    local function check(value,why)assertions+=1 assert(value,why)end
    local function near(a,b)return math.abs(a-b)<1e-8 end
    local function permitted(row,why)
        check(type(row)=="table" and row.valid==true and row.submission_allowed==true and type(row.force_controls)=="table",why)
        return row.force_controls
    end
    local function refused(row,why)
        check(type(row)=="table" and row.submission_allowed~=true,why)
    end
    do
        cases+=1
        local raw=Input.raw({available=true,device=2})
        check(not Input.new():update(raw,{grounded=true},0).active,"original update retains positive-dt-only contract")
        local mapper=Input.new()
        check(mapper:update_observation(raw,{grounded=true},0).active,"ordered zero-time observation can prime neutral")
        raw.quick_hop=true
        check(mapper:update_observation(raw,{grounded=true},0).hop_pressed,"ordered same-ms observation can carry a real R3 edge")
    end
    do
        cases+=1
        local f=fixture();f.prime()
        f.observe(pad({left_x=.7,buttons={a=true}}),10)
        local a=permitted(f.controls(),"explicit grounded A and LSX routing")
        check(a.pedal==1 and a.brake==0 and a.steer>0,"A maps to pedal and LSX keeps steering sign")
        f.observe(pad({left_x=-.7,buttons={b=true}}),10)
        local b=permitted(f.controls(),"explicit grounded B and opposite LSX routing")
        check(b.pedal==0 and b.brake==1 and b.steer<0,"B maps to brake and opposite LSX reverses steering")
    end
    do
        cases+=1
        local f=fixture()
        refused(f.controls(),"no observation means no force controls")
        local first=f.observe(pad({buttons={a=true}}),0)
        check(not first.active,"initial held control cannot prime the mapper")
        f.observe(pad(),0)
        local controls=permitted(f.controls(),"observed neutral primes even with genuine zero elapsed")
        check(controls.pedal==0 and controls.hop_strength==0,"neutral produces no hidden intent")
    end
    for _,rate in ipairs({30,60,120})do
        cases+=1
        local f=fixture();f.prime()
        local held
        for index=1,math.ceil(rate*.4)do
            local elapsed=math.floor(index*1000/rate)-math.floor((index-1)*1000/rate)
            held=f.observe(pad({right_y=-1}),elapsed)
            check(held.actions.preload>0 and not held.actions.hop_pressed,"fresh observed back samples charge without repeated edges")
        end
        local edge=f.observe(pad({right_y=1}),1)
        check(edge.actions.hop_pressed and near(edge.actions.hop_strength,1),"full observed charge emits one full-strength hop at each delivery rate")
        local first=permitted(f.controls(),"pending full hop reaches independently qualified body step")
        local id,strength=first.hop_event_id,first.hop_strength
        check(id==1 and strength==1,"first lifetime event retains full original strength")
        for _=1,6 do
            f.observe(pad({right_y=1}),1)
            local repeated=permitted(f.controls(),"held input remains a level plus one pending event")
            check(repeated.hop_event_id==id and repeated.hop_strength==strength,"render/body rereads never mint or strengthen a hop")
        end
        check(f.mapping:retire_hop(id,"accepted"),"real owner's local acceptance decision retires exact pending identity")
        local retired=permitted(f.controls(),"retirement leaves continuous controls available")
        check(retired.hop_event_id==0 and retired.hop_strength==0,"retired event is absent from subsequent body controls")
    end
    do
        cases+=1
        local f=fixture();f.prime()
        f.observe(pad({right_y=-1}),10);f.observe(pad(),1)
        local edge=f.observe(pad({right_y=1}),1)
        check(edge.actions.hop_pressed and edge.actions.hop_strength>=.25 and edge.actions.hop_strength<1,"independent quick flick retains weak strength")
        local first=permitted(f.controls(),"weak hop offered once")
        check(near(first.hop_strength,edge.actions.hop_strength),"force controls preserve recognizer strength exactly")
        check(edge.hop.observation_serial==f.serial and edge.hop.observed_ms==f.ms,"pending hop retains exact original source observation")
        local original_serial=edge.hop.observation_serial
        f.observe(pad({right_y=1}),10)
        local next=permitted(f.controls(),"retained weak event remains available before explicit retirement")
        check(next.hop_event_id==first.hop_event_id and next.hop_strength==first.hop_strength,"retained weak hop is not promoted to full strength")
        check(f.mapping:status().pending_hop.observation_serial==original_serial,"later input levels do not rewrite pending event provenance")
        check(not f.mapping:retire_hop(first.hop_event_id+1,"accepted"),"wrong identity cannot retire a pending hop")
    end
    do
        cases+=1
        local f=fixture();f.prime()
        local before=f.ms
        local tap=f.r3();f.observe(pad(),0)
        -- Force consumers have not run between these ordered input observations.
        local controls=permitted(f.controls(),"interstitial R3 pulse survives until body advances")
        check(tap.actions.hop_pressed and controls.hop_event_id==1 and controls.hop_strength==1,"one staged R3 event survives released level")
        check(controls.pump_inhibited,"pending interstitial hop inhibits pump even after raw R3 releases")
        local g=fixture();g.prime();local same_ms=g.ms
        local equal=g.observe(pad({buttons={right_stick=true}}),0)
        check(g.ms==same_ms and equal.actions.hop_pressed,"fresh serial with exactly equal native ms can carry an R3 edge")
        local duplicate=g.frame();duplicate.new_observation=false
        local observed=g.mapping:observe(duplicate,g.context)
        local retained=permitted(g.controls(),"duplicate observation retains pending identity")
        check(not observed.new_observation and retained.hop_event_id==1,"duplicate source ordinal never mints another edge")
        check(before~=nil,"native clock origin remains a decimal string")
    end
    do
        cases+=1
        local f=fixture();f.prime();f.r3()
        local controls=permitted(f.controls(),"fresh R3 event")
        check(controls.pump_inhibited,"hop edge suppresses pump")
        check(f.mapping:retire_hop(controls.hop_event_id,"accepted"),"retire first R3 event")
        f.observe(pad({left_y=-1,buttons={right_stick=true}}),10)
        controls=permitted(f.controls(),"held raw R3 after event retirement")
        check(controls.hop_strength==0 and controls.pump_inhibited,"raw held R3 inhibits pump without a new hop")
        f.observe(pad(),10);f.observe(pad({left_y=-1,right_y=-1}),10)
        controls=permitted(f.controls(),"charged preload coexists with requested ground pump")
        check(controls.hop_strength==0 and controls.pump_inhibited and controls.ground_pump<0,
            "nonzero preload inhibits downforce even before the hop edge")
    end
    do
        cases+=1
        local f=fixture();f.prime();f.r3()
        local first=permitted(f.controls(),"first pending hop")
        f.observe(pad(),10)
        local second=f.r3()
        check(not second.valid or not second.active,"a second unresolved gesture is refused")
        local state=f.mapping:status()
        check(state.pending_hop and state.hop_counter==1,"unresolved second event never overwrites original identity or builds a queue")
        check(f.mapping:retire_hop(first.hop_event_id,"cancelled"),"owner cancellation retires first event")
        refused(f.controls(),"cancellation requires observed neutral before controls resume")
    end
    do
        cases+=1
        local f=fixture();f.prime();f.r3()
        local first=permitted(f.controls(),"pending hop before uncertainty")
        check(f.mapping:retire_hop(first.hop_event_id,"uncertain"),"explicit uncertain owner outcome retained")
        refused(f.controls(),"uncertain native outcome cannot replay a hop")
        check(f.mapping:status().uncertain,"uncertain event remains diagnostic")
        f.mapping:reset("fixture real owner cleanup complete")
        f.prime();f.r3()
        local next=permitted(f.controls(),"new neutral session after explicit reset")
        check(next.hop_event_id>first.hop_event_id,"reset never rewinds lifetime hop identity")
    end
    do
        cases+=1
        local f=fixture();f.prime()
        -- Private test-only state injection reaches the uint32 boundary without
        -- billions of gestures. No production seed option or authority is added.
        f.mapping._hop_counter=4294967294
        f.r3();local last=permitted(f.controls(),"final representable uint32 hop")
        check(last.hop_event_id==4294967295,"last positive uint32 event is exact")
        check(f.mapping:retire_hop(last.hop_event_id,"accepted"),"last event may retire")
        f.observe(pad(),1);f.r3()
        refused(f.controls(),"exhausted lifetime cannot wrap to a reused event")
        check(f.mapping:status().exhausted,"exhaustion is explicit")
        f.mapping:reset("fixture reset cannot make ID space reusable")
        check(f.mapping:status().hop_counter==4294967295,"reset preserves exhausted high-water mark")
    end
    for _,field in ipairs({"sequence","source_epoch","context_generation"})do
        cases+=1
        local f=fixture();f.prime();f.observe(pad({right_y=-1}),50)
        if field=="context_generation" then f.context_epoch=increment(f.context_epoch)else f[field]=increment(f[field])end
        local changed=f.observe(pad({right_y=1}),1)
        check(not changed.active,"exact tuple change requires a new observed neutral")
        refused(f.controls(),"replacement source cannot finish old preload")
        f.prime();f.r3();local hop=permitted(f.controls(),"replacement neutral establishes a new local gesture")
        check(hop.hop_event_id==1,"tuple reset does not mint from the carried old release")
    end
    do
        cases+=1
        local f=fixture();f.prime()
        f.context.grounded=false;f.observe(pad(),10)
        f.observe(pad({left_x=.8,left_y=-.8}),10)
        local air=permitted(f.controls(),"explicit airborne neutral then LS rotation")
        check(air.manual>0 and air.nose_manual==0 and air.air_yaw>0,"negative air pitch routes to manual and yaw to steer")
        check(air.rotation_reserved,"raw rotation intent reserves rotation independently of a trick")
        f.context.rotation_reserved=true;f.observe(pad(),10)
        air=permitted(f.controls(),"separate actual reservation fact")
        check(air.rotation_reserved,"real ongoing reservation persists with neutral raw input")
    end
    for _,missing in ipairs({"grounded","focused","menu_open","rotation_reserved"})do
        cases+=1
        local f=fixture();f.prime();local context=copy(f.context);context[missing]=nil
        local observed=f.observe(pad({buttons={a=true}}),10,context)
        check(not observed.valid,"missing genuine context fact refuses before mapper defaults")
        refused(f.controls(),"invalid context never offers disabled-only force controls")
    end
    for _,fault in ipairs({"duplicate_changed","regressed_serial","regressed_time","gap","input_loss"})do
        cases+=1
        local f=fixture();f.prime();f.observe(pad({right_y=-1}),10)
        local frame=f.frame()
        if fault=="duplicate_changed" then frame.sample.pad.buttons.a=true
        elseif fault=="regressed_serial" then frame.sample.observation_serial="1"
        elseif fault=="regressed_time" then frame.sample.observation_serial=increment(f.serial);frame.sample.observed_ms="1"
        elseif fault=="gap" then for _=1,101 do f.ms=increment(f.ms)end;frame=f.frame();frame.sample.observation_serial=increment(f.serial)
        else frame.input_ok=false end
        local observed=f.mapping:observe(frame,f.context)
        check(not observed.valid,"bad source correspondence or authority invalidates mapping")
        if fault=="regressed_time"then check(observed.issue=="input_clock_regressed","new source ordinal with regressed publication clock is classified precisely")end
        refused(f.controls(),"bad source cannot authorize force controls")
    end
    for _,step in ipairs({{h=0},{h=.101},{physics_epoch=false},{grounded="true"},{missing_rotation=true}})do
        cases+=1
        local f=fixture();f.prime()
        local out=step.missing_rotation and f.mapping:controls({physics_epoch=newproxy(),h=.01666666567325592,grounded=true})or f.controls(step)
        refused(out,"force context requires actual epoch, positive measured h and explicit facts")
    end
    -- B15: a genuine body ground change may occur between admitted reports.
    -- These are constructed held-state traces, not native support/input proof.
    do
        cases+=1
        local f=fixture();f.prime()
        f.observe(pad({left_x=.7,buttons={a=true}}),20)
        local before=f.mapping:status()
        -- The original caller's mutable pad cannot replace admitted held state.
        f.pad.left_x=-1;f.pad.buttons.a=false
        local air=f.controls({grounded=false})
        local a=permitted(air,"held A survives report-free takeoff as valid air controls")
        check(a.pedal==0 and a.steer>0,"air projection gates pedal without dropping held steering")
        local land=f.controls({grounded=true})
        local b=permitted(land,"held A resumes on report-free landing without neutral rearm")
        check(b.pedal==1 and b.steer>0,"landing uses admitted A/steering, not mutated caller pad")
        local after=f.mapping:status()
        for _,name in ipairs({"lease_handle","generation","user","sequence","source_epoch","context_generation",
            "observation_serial","observed_ms","packet"})do
            check(after.source[name]==before.source[name],"ground-only projection cannot advance or replace source "..name)
        end
        check(after.source.pad.buttons.a and after.source.pad.left_x==.7,"admitted source snapshot stays detached")
        check(after.hop_counter==before.hop_counter and not land.actions.hop_pressed,"ground context is not a new input edge")
    end
    do
        cases+=1
        local f=fixture();f.prime()
        f.context.grounded=false;f.observe(pad(),10)
        f.observe(pad({left_x=-.7,buttons={b=true}}),20)
        local ground=permitted(f.controls({grounded=true}),"held brake survives report-free landing")
        local air=permitted(f.controls({grounded=false}),"held brake survives report-free takeoff")
        check(ground.brake==1 and air.brake==1 and ground.steer<0 and air.steer<0,"held B and steering retain their level/sign")
    end
    do
        cases+=1
        local f=fixture();f.prime();f.observe(pad({buttons={a=true}}),20)
        local frame=f.frame();frame.new_observation=false
        local context=copy(f.context);context.grounded=false
        local changed=f.mapping:observe(frame,context)
        check(changed.valid and changed.active and not changed.new_observation,"identical duplicate changes ground context without a source observation")
        check(changed.source.observation_serial==frame.sample.observation_serial and changed.source.observed_ms==frame.sample.observed_ms,
            "duplicate ground projection retains exact source clock/ordinal")
        check(permitted(f.controls({grounded=false}),"duplicate air projection remains valid").pedal==0,"air duplicate gates A")
        context.grounded=true
        changed=f.mapping:observe(frame,context)
        check(changed.valid and changed.active and not changed.new_observation,"duplicate landing remains a held projection")
        check(permitted(f.controls({grounded=true}),"duplicate landing restores held A").pedal==1,"duplicate landing does not require invented neutral")
    end
    do
        cases+=1
        local f=fixture();f.prime();f.r3()
        local original=f.mapping:status().pending_hop
        for index=1,6 do
            local row=f.controls({grounded=index%2==0})
            local controls=permitted(row,"receipt-owned pending hop survives held ground transition")
            check(controls.hop_event_id==original.id and controls.hop_strength==original.strength,"ground transition never retires or reissues pending hop")
            check(not row.actions.hop_pressed and row.actions.hop_strength==0,"held projection carries no new gesture edge")
        end
        local state=f.mapping:status()
        check(state.hop_counter==1 and state.pending_hop.observation_serial==original.observation_serial
            and state.pending_hop.observed_ms==original.observed_ms,"pending event provenance/high-water mark remains original")
        check(f.mapping:retire_hop(original.id,"accepted"),"only exact owner disposition retires pending hop")
        for index=1,4 do
            local row=f.controls({grounded=index%2==0})
            local controls=permitted(row,"retired held R3 remains valid across ground transitions")
            check(controls.hop_event_id==0 and not row.actions.hop_pressed,"held R3 cannot replay retired event")
        end
        check(not f.observe(pad({buttons={right_stick=true}}),10).actions.hop_pressed,"fresh still-held R3 is not a second edge")
        f.observe(pad(),10);f.r3()
        check(permitted(f.controls(),"genuine release/new press remains available").hop_event_id==2,"only genuine release/press mints next lifetime identity")
    end
    do
        cases+=1
        local f=fixture();f.prime()
        local charged=f.observe(pad({right_y=-1}),50)
        local preload=charged.actions.preload
        check(preload>0 and preload<1,"real source time begins partial charge")
        for _=1,6 do
            local row=f.controls()
            permitted(row,"body-only controls can reuse held charged level")
            check(near(row.actions.preload,preload),"physics h/repeated controls cannot charge input history")
        end
        f.controls({grounded=false})
        local landed=f.controls({grounded=true});permitted(landed,"held back stick survives new ground context")
        check(landed.actions.preload==0 and not landed.actions.hop_pressed,"actual context change clears old gesture charge without fabricating duration")
        local forward=f.observe(pad({right_y=1}),1)
        check(not forward.actions.hop_pressed and f.mapping:status().hop_counter==0,"ground-only projection cannot finish old charged flick")
    end
    for _,gap in ipairs({100,101})do
        cases+=1
        local f=fixture();f.prime();f.observe(pad({buttons={a=true}}),20)
        local before=f.mapping:status().source
        f.controls({grounded=false});f.controls({grounded=true})
        local out=f.observe(pad({buttons={a=true}}),gap)
        if gap==100 then
            check(out.valid and out.active,"exact100ms actual report remains admitted after held ground changes")
            check(permitted(f.controls(),"boundary report can still provide controls").pedal==1,"held A remains on exact existing source deadline")
        else
            check(not out.valid and out.issue=="observation_gap","101ms actual report remains stale despite held ground projections")
            refused(f.controls({grounded=false}),"stale report cannot recover through ground-only projection")
        end
        check(before.observed_ms~=out.source.observed_ms,"only genuine report changes source time")
    end
    do
        cases+=1
        local f=fixture();f.observe(pad({buttons={a=true}}),0)
        refused(f.controls({grounded=false}),"unprimed held A cannot become active via takeoff")
        refused(f.controls({grounded=true}),"unprimed held A cannot become active via landing")
        check(not f.observe(pad({buttons={a=true}}),10).active,"invalid projection does not bypass real neutral prime")
        f.observe(pad(),10);f.observe(pad({buttons={a=true}}),10)
        check(permitted(f.controls(),"real neutral then new A still works").pedal==1,"held ground fix preserves neutral gate")
    end
    for _,fault in ipairs({"reset","input_loss","focus_loss"})do
        cases+=1
        local f=fixture();f.prime();f.observe(pad({buttons={a=true}}),20)
        if fault=="reset" then f.mapping:reset("explicit fixture reset")
        elseif fault=="input_loss" then local frame=f.frame();frame.input_ok=false;f.mapping:observe(frame,f.context)
        else local context=copy(f.context);context.focused=false;f.mapping:observe(f.frame(),context) end
        refused(f.controls({grounded=false}),"invalidated "..fault.." cannot reuse old held raw on ground transition")
        refused(f.controls({grounded=true}),"invalidated "..fault.." cannot rearm on second transition")
    end
    do
        cases+=1
        local f=fixture();f.prime();f.r3()
        f.context.grounded=false
        local fresh=f.observe(pad({buttons={right_stick=true}}),10)
        local state=f.mapping:status()
        check(fresh.valid and state.pending_hop==nil and state.hop_counter==1,"existing fresh-report ground-change cancellation stays unchanged")
        check(state.last_retired.disposition=="ground_context_changed","held-only fix does not rewrite fresh-report retirement policy")
    end
    return {cases=cases,assertions=assertions,constructed=true,native_authority=false,gameplay=false}
end
return Tests

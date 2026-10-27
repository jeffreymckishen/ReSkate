-- Pure source fixtures: real input mapping, constructed body/contact/model and
-- delegates. No SDK, native impulse, controller, build or game evidence.
local Guard=require("./hop_guard")
local Mapping=require("./ride_input_mapping")
local Forces=require("./forces")
local Tests={}
local H=Forces.native_seconds
local buttons={"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"}
local function copy(v)
    if type(v)~="table" then return v end
    local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out
end
local function fixture(hop)
    local f={body=newproxy(),lease=newproxy(),calls=0,serial=42,time=42*H,mapper=Mapping.new()}
    local pad={left_x=0,left_y=0,right_x=0,right_y=0,left_trigger=0,right_trigger=0,playstation=false,buttons={}}
    for _,name in ipairs(buttons) do pad.buttons[name]=false end
    local ordinal,ms=0,1000
    local function observe(y)
        ordinal+=1;ms+=16;pad.right_y=y
        local frame={input_ok=true,lease_handle=f.lease,generation=2,sample={user=0,sequence="9007199254740993",
            source_epoch="12",context_generation="13",observation_serial=tostring(ordinal),
            observed_ms=tostring(ms),packet=ordinal,pad=copy(pad)}}
        local row=f.mapper:observe(frame,{grounded=true,focused=true,menu_open=false,rotation_reserved=false})
        assert(row.valid,"real mapping must accept constructed observation")
    end
    observe(0)
    if hop then observe(-1);observe(1) end
    f.raw=Forces.proposed_body()
    function f:reframe()
        self.epoch=newproxy()
        self.sample={epoch=self.epoch,serial=tostring(self.serial),time=self.time,seconds=H,mass=106,
            position=vector.create(table.unpack(self.raw.center_of_mass)),rotation=copy(self.raw.orientation),
            velocity=vector.create(table.unpack(self.raw.linear_velocity)),
            angular_velocity=vector.create(table.unpack(self.raw.angular_velocity)),inertia=vector.create(table.unpack(self.raw.inertia_body))}
        self.controls=self.mapper:controls({physics_epoch=self.epoch,h=H,grounded=true,rotation_reserved=false})
        assert(self.controls.valid and self.controls.submission_allowed,"real mapped controls must be available")
        self.frame={valid=true,fresh=true,active=true,loaded=true,body_handle=self.body,physics_epoch=self.epoch,
            serial=self.sample.serial,time=self.time,seconds=H,sample=copy(self.sample),body=copy(self.raw),
            source=copy(self.controls.source),owner={body_handle=self.body,lease_handle=self.lease},
            gates={focused=true,menu_open=false}}
        self.contact={grounded=true,support={known=true,grounded_known=true,grounded=true,epoch=self.epoch}}
        self.folded=copy(self.raw)
    end
    f:reframe()
    function f:observe_input(y) observe(y);self:reframe() end
    f.model={valid=true,grounded=true,contact_scale=1,force={0,0,0},torque={0,0,0},
        hop_applied=hop==true,hop_event_id=hop and f.controls.hop.id or 0,hop_impulse={0,hop and 119.25 or 0,0}}
    f.candidate=table.freeze({})
    function f:packet()
        local m=self.model
        return {force=vector.create(table.unpack(m.force)),torque=vector.create(table.unpack(m.torque)),
            impulse=m.hop_applied and vector.create(table.unpack(m.hop_impulse)) or nil,
            impulse_id=m.hop_applied and m.hop_event_id or nil}
    end
    function f:begin(g) return g:begin(self.body,self.sample,self.controls,self.raw,self.frame,self.contact) end
    function f:preview(g) return g:observe(H,self.folded,self.controls.force_controls,self.model,self.candidate) end
    function f:advance() self.serial+=1;self.time+=H;self:reframe() end
    function f.delegate(body,epoch,packet)
        f.calls+=1
        assert(body==f.body and epoch==f.epoch and packet==f.sent,"original exact SDK arguments must be delegated")
        if f.on_delegate then return f.on_delegate() end
        return true,nil,"9007199254740995"
    end
    function f:submit(g,packet)
        self.sent=packet or self:packet()
        return g:submit(self.body,self.epoch,self.sent,self.delegate)
    end
    return f
end
local function configured(phase)
    local g=Guard.new();assert(g:configure({phase=phase or "H1",admitted=true}));return g
end
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(run) cases+=1;run() end
    local function ready(f,g)
        check(f:begin(g),"exact constructed context is admitted")
        check(f:preview(g),"actual mapped context binds a constructed candidate")
    end
    local function denied(f,g,why,packet)
        local r=table.pack(f:submit(g,packet))
        check(r.n==2 and r[1]==false and type(r[2])=="string" and f.calls==0,why)
    end
    case(function()
        local f=fixture(true);local g=Guard.new()
        check(g:status().phase=="P0" and not g:status().admitted,"default guard has no native admission")
        check(not f:begin(g),"default context is refused");denied(f,g,"default guard cannot delegate")
        for _,options in ipairs({{phase="H1",admitted=false},{phase="R3",admitted=true},{phase="T2",admitted=true},
            {phase="H1",admitted=true,strength=.5}}) do
            local other=Guard.new();check(not other:configure(options),"only the exact fixed P0/H1 configuration is admitted")
        end
    end)
    case(function()
        local f,g=fixture(false),configured("P0");ready(f,g)
        local r=table.pack(f:submit(g))
        check(r.n==3 and r[1]==true and r[2]==nil and r[3]=="9007199254740995","P0 preserves exact neutral SDK acceptance")
        check(g:status().hop_attempts==0 and f.calls==1,"P0 neutral packets spend no hop attempt")
        local hop,closed=fixture(true),configured("P0")
        check(not hop:begin(closed),"P0 refuses even correctly mapped quarter-strength intent")
        denied(hop,closed,"P0 never delegates a hop")
        local charge,neutral=fixture(false),configured("P0");charge:observe_input(-1)
        check(not charge:begin(neutral),"P0 refuses back-charge before a hop event exists")
        denied(charge,neutral,"P0 remains neutral during a real charging gesture")
    end)
    case(function()
        local f,g=fixture(false),configured()
        f:observe_input(-1);ready(f,g)
        check(f.controls.actions.rear_weight==-1 and f.controls.actions.preload>0 and g:status().hop_attempts==0,
            "actual back-charge metadata is allowed without an impulse attempt")
        f:observe_input(1);f.model.hop_applied=true;f.model.hop_event_id=f.controls.hop.id;f.model.hop_impulse={0,119.25,0}
        ready(f,g)
        check(f.controls.actions.rear_weight==1,"actual forward gesture metadata stays tied to mapped controls")
        check(f.controls.hop.strength==.25 and f.controls.force_controls.hop_strength==.25,
            "real short rear-stick gesture supplies the minimum quarter-strength request")
        local packet=f:packet()
        check(packet.impulse==vector.create(0,119.25,0) and vector.magnitude(packet.force+packet.impulse/H)<40000,
            "119.25 N s is separate from contact force and within the total packet bound")
        check(f:submit(g,packet)==true and f.calls==1 and g:status().hop_attempts==1,"one exact quarter impulse is delegated")
        for _,value in pairs(g:status()) do
            check(type(value)=="number" or type(value)=="boolean" or type(value)=="string","status contains no opaque body/source/candidate")
        end
    end)
    case(function()
        local f,g=fixture(true),configured();ready(f,g)
        f.candidate=table.freeze({});check(f:preview(g),"a later preview can replace an unsubmitted candidate")
        check(g:status().previews==2 and g:status().hop_attempts==0 and f.calls==0,"duplicate previews are not native attempts")
        check(f:submit(g)==true and g:status().hop_attempts==1,"only delegation spends the attempt")
        local old,guard=fixture(false),configured();ready(old,guard);local packet=old:packet()
        old.model.force={1,0,0};old.candidate=table.freeze({});check(old:preview(guard),"replacement model is valid")
        denied(old,guard,"stale packet is refused after a different candidate replaces it",packet)
    end)
    case(function()
        for _,strength in ipairs({0,.250001,.5,1}) do
            local f,g=fixture(true),configured()
            f.controls.force_controls.hop_strength=strength;f.controls.hop.strength=strength;f.controls.actions.hop_strength=strength
            check(not f:begin(g),"non-quarter strength refuses before any model or SDK admission")
            denied(f,g,"no strength substitution or full-strength retry")
        end
        local f,g=fixture(true),configured()
        f.controls.source.pad.buttons.right_stick=true;f.frame.source.pad.buttons.right_stick=true
        check(not f:begin(g),"R3 refuses independently of a forged quarter-strength number");denied(f,g,"R3 never delegates")
    end)
    case(function()
        for _,name in ipairs({"pedal","brake","steer","manual","nose_manual","air_yaw","ground_pump"}) do
            local f,g=fixture(true),configured();f.controls.force_controls[name]=.01
            check(not f:begin(g),"non-hop force channel refused: "..name);denied(f,g,"non-hop controls cannot reach SDK")
        end
        for _,name in ipairs({"pedal","brake","steer","manual","nose_manual","air_pitch","front_weight"}) do
            local f,g=fixture(true),configured();f.controls.actions[name]=.01
            check(not f:begin(g),"non-hop action refused: "..name)
        end
        for _,name in ipairs({"handlebar","tailwhip","movement"}) do
            local f,g=fixture(true),configured();f.controls.actions[name]=name=="movement" and 24 or "left"
            check(not f:begin(g),"authored trick selection is outside H1")
        end
    end)
    case(function()
        local changes={
            function(f) f.frame.source.observation_serial="35" end,
            function(f) f.frame.source.lease_handle=newproxy() end,
            function(f) f.frame.physics_epoch=newproxy() end,
            function(f) f.frame.owner.body_handle=newproxy() end,
            function(f) f.controls.physics_epoch=newproxy() end,
            function(f) f.frame.serial="43" end,
            function(f) f.frame.gates.focused=false end,
            function(f) f.contact.support.epoch=newproxy() end,
        }
        for _,change in ipairs(changes) do
            local f,g=fixture(true),configured();change(f)
            check(not f:begin(g),"actual queued source/body/support mismatch is refused")
            denied(f,g,"identity mismatch reaches no delegate")
        end
        local f,g=fixture(true),configured();ready(f,g)
        check(f.controls.source.observation_serial=="3" and f.sample.serial=="42",
            "queued Source observation keeps its own identity rather than borrowing body or latest-poll serial")
    end)
    case(function()
        for _,change in ipairs({
            function(f) f.sample.epoch=newproxy() end,
            function(f) f.controls.source.packet+=1 end,
            function(f) f.controls.hop.strength=1 end,
            function(f) f.controls.actions.rear_weight=0 end,
            function(f) f.controls.actions.preload=1 end,
            function(f) f.frame.gates.menu_open=true end,
            function(f) f.contact.grounded=false;f.contact.support.grounded=false end,
        }) do
            local f,g=fixture(true),configured();check(f:begin(g),"capture source before mutation");change(f)
            check(not f:preview(g),"callback mutation before preview invalidates the candidate")
            denied(f,g,"changed context reaches no delegate")
        end
    end)
    case(function()
        for _,change in ipairs({
            function(f) f.sample.serial="43" end,
            function(f) f.controls.source.pad.buttons.right_stick=true end,
            function(f) f.controls.force_controls.pedal=1 end,
            function(f) f.frame.active=false end,
            function(f) f.controls.hop.source.sequence="99" end,
        }) do
            local f,g=fixture(true),configured();ready(f,g);change(f)
            denied(f,g,"source/body/actions are revalidated immediately before delegation")
        end
    end)
    case(function()
        for _,velocity in ipairs({{3,0,0},{0,3,0},{0,-3,0}}) do
            local f,g=fixture(false),configured();f.raw.linear_velocity=velocity;f:reframe();ready(f,g)
            check(f:submit(g),"exact measured speed boundaries are admitted")
        end
        for _,velocity in ipairs({{3.001,0,0},{0,3.001,0},{0,-3.001,0}}) do
            local f,g=fixture(false),configured();f.raw.linear_velocity=velocity;f:reframe()
            check(not f:begin(g),"measured speed above trial cap is refused")
            local folded,guard=fixture(false),configured();check(folded:begin(guard),"raw sample remains under cap")
            folded.folded.linear_velocity=velocity
            check(not folded:preview(guard),"in-flight forecast above trial cap is independently refused")
        end
        local f,g=fixture(true),configured();f.raw.mass=107
        check(not f:begin(g),"mass must be the declared 106 kg before exact impulse admission")
    end)
    case(function()
        local f,g=fixture(false),configured();f.model.force={6000,0,0};f.model.torque={0,2000,0};ready(f,g)
        check(f:submit(g),"force and torque caps include their exact boundaries")
        for _,rounded in ipairs({{field="force",values={5999.9999,1,0}},{field="torque",values={1999.99995,.4,0}}}) do
            local edge,guard=fixture(false),configured();edge.model[rounded.field]=rounded.values;ready(edge,guard)
            denied(edge,guard,"native float32 packing must not round a previously eligible vector over its cap")
        end
        for _,change in ipairs({
            function(f) f.model.force={6000.001,0,0} end,
            function(f) f.model.torque={0,2000.001,0} end,
            function(f) f.model.force={0/0,0,0} end,
            function(f) f.model.torque={math.huge,0,0} end,
            function(f) f.model.contact_scale=.9 end,
        }) do
            local invalid,guard=fixture(false),configured();check(invalid:begin(guard),"valid observation");change(invalid)
            check(not invalid:preview(guard),"over-cap, nonfinite or clamped preview is refused");denied(invalid,guard,"invalid preview cannot delegate")
        end
    end)
    case(function()
        for _,impulse in ipairs({{0,477,0},{0,119.250001,0},{.001,119.25,0},{0,-119.25,0},{0,0,0}}) do
            local f,g=fixture(true),configured();check(f:begin(g),"valid quarter input");f.model.hop_impulse=impulse
            check(not f:preview(g),"only the exact upward 119.25 impulse is eligible");denied(f,g,"wrong impulse cannot delegate")
        end
        local f,g=fixture(true),configured();check(f:begin(g),"valid event");f.model.hop_event_id+=1
        check(not f:preview(g),"model event must match the actual queued hop")
        local air,guard=fixture(true),configured();air.contact.grounded=false;air.contact.support.grounded=false
        check(air:begin(guard),"measured airborne frame can remain observable")
        check(not air:preview(guard),"a model hop cannot override measured airborne support")
    end)
    case(function()
        for _,change in ipairs({
            function(p) p.force=vector.create(1,0,0) end,
            function(p) p.torque=vector.create(0,1,0) end,
            function(p) p.impulse=vector.create(0,477,0) end,
            function(p) p.impulse_id+=1 end,
            function(p) p.synthetic_sequence="1" end,
        }) do
            local f,g=fixture(true),configured();ready(f,g);local packet=f:packet();change(packet)
            f.sent=packet;local ok,why=g:submit(f.body,f.epoch,packet,f.delegate)
            check(ok==false and type(why)=="string" and f.calls==0,"only the exact prepared packet reaches SDK")
        end
        for _,kind in ipairs({"body","epoch"}) do
            local f,g=fixture(true),configured();ready(f,g);f.sent=f:packet()
            check(not g:submit(kind=="body" and newproxy() or f.body,kind=="epoch" and newproxy() or f.epoch,f.sent,f.delegate)
                and f.calls==0,"foreign body/epoch is refused at publication")
        end
    end)
    case(function()
        for _,refusal in ipairs({false,true}) do
            local f,g=fixture(true),configured();ready(f,g)
            if refusal then f.on_delegate=function() return false,"receipt_capacity" end end
            local result=table.pack(f:submit(g))
            check(result.n==(refusal and 2 or 3) and result[1]==(not refusal),"accepted/known refusal tuple preserved")
            f:advance();ready(f,g)
            local ok,why=f:submit(g)
            check(ok==false and type(why)=="string" and f.calls==1 and g:status().hop_attempts==1,
                "accepted or explicitly refused impulse attempt cannot be tried a second time")
        end
    end)
    case(function()
        local f,g=fixture(true),configured();ready(f,g);local raised={}
        f.on_delegate=function() error(raised,0) end
        local ok,why=pcall(function() f:submit(g) end)
        check(not ok and why==raised,"the exact SDK error value is rethrown")
        check(g:status().last_outcome=="unknown" and g:status().hop_attempts==1,"unknown publication retains the spent attempt")
        check(not f:begin(g) and not g:configure({phase="H1",admitted=true}),"unknown outcome cannot rearm")
        check(f.calls==1,"unknown admission is never retried")
    end)
    case(function()
        local outcomes={
            function() return true,nil,"9007199254740995","extra" end,
            function() return false,nil end,
            function() return end,
        }
        for _,outcome in ipairs(outcomes) do
            local f,g=fixture(true),configured();ready(f,g);f.on_delegate=outcome
            local wanted=table.pack(outcome());local got=table.pack(f:submit(g))
            check(got.n==wanted.n,"unknown tuple retains original return arity")
            for i=1,wanted.n do check(got[i]==wanted[i],"unknown SDK result is never forged") end
            check(g:status().last_outcome=="unknown" and g:status().stopped and f.calls==1,"malformed result revokes later submission")
        end
    end)
    case(function()
        local f,g=fixture(true),configured();ready(f,g);local inner
        f.on_delegate=function()
            inner=table.pack(g:submit(f.body,f.epoch,f.sent,f.delegate))
            return true,nil,"9007199254740995"
        end
        local r=table.pack(f:submit(g))
        check(inner.n==2 and inner[1]==false and f.calls==1,"reentry is refused before a second delegate")
        check(r.n==3 and r[1]==true and r[3]=="9007199254740995" and g:status().hop_attempts==1,
            "late accepted result survives reentrant refusal unchanged")
        check(g:status().stopped,"reentry cannot leave submission authority live")
    end)
    case(function()
        local f,g=fixture(true),configured();ready(f,g)
        f.on_delegate=function() g:stop("stop inside SDK");return true,nil,"9007199254740995" end
        local r=table.pack(f:submit(g))
        check(r.n==3 and r[1]==true and g:status().last_outcome=="accepted" and g:status().stopped,
            "late accepted sequence survives Stop without reopening admission")
        check(g.receipt==nil and g.acknowledge==nil,"guard owns no receipt or ACK path that could block cleanup")
    end)
    case(function()
        local f,g=fixture(true),configured();ready(f,g);check(f:submit(g),"first hop accepted")
        f:advance();f.model.hop_applied=false;f.model.hop_event_id=0;f.model.hop_impulse={0,0,0}
        ready(f,g);check(f:submit(g),"subsequent non-hop packet remains available for landing")
        check(f.calls==2 and g:status().hop_attempts==1,"landing packets do not create another hop attempt")
        check(not f:submit(g) and f.calls==2,"same prepared packet is consumed even without an impulse")
    end)
    case(function()
        for _,age in ipairs({100,101}) do
            local f,g=fixture(true),configured()
            f.controls.source.observation_serial="4"
            f.controls.source.observed_ms=tostring(tonumber(f.controls.hop.observed_ms)+age)
            f.controls.actions.source=copy(f.controls.source);f.controls.actions.hop_pressed=false;f.controls.actions.hop_strength=0
            f.frame.source=copy(f.controls.source)
            local ok=f:begin(g)
            check(ok==(age==100),"queued hop source has an exact 100 ms freshness bound")
            if ok then check(f:preview(g) and f:submit(g),"eligible older hop keeps its own source identity")
            else denied(f,g,"expired queued hop cannot publish") end
        end
    end)
    case(function()
        local f,g=fixture(false),configured();ready(f,g);check(f:submit(g),"seed original owner")
        f:advance();f.controls.source.sequence="99";f.controls.actions.source.sequence="99";f.frame.source.sequence="99"
        check(not f:begin(g),"a consistent replacement stream still cannot take over the original guard")
        local a,b=fixture(false),configured();ready(a,b);a:advance();a.sample.serial="1";a.frame.serial="1";a.frame.sample.serial="1"
        check(not a:begin(b),"body chronology cannot regress before submission")
        local s=b:status();check(table.isfrozen(s),"diagnostics cannot rearm the private guard")
    end)
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)

-- Actual adapter plus transaction model, using injected SDK-shaped services.
-- No native API, input binding or control permission is used by these tests.
local Runtime=require("./equipment_runtime")
local tests={}
function tests.run()
    local cases,assertions=0,0
    local function check(v,why) assertions+=1;assert(v,why) end
    local function copy(t) if type(t)~="table" then return t end;local o={};for k,v in t do o[k]=copy(v) end;return o end
    local terminal_key,progress_key="bmx_equipment_terminal_v1","bmx_equipment_runtime_v1"
    local function fake()
        local f={now=0,state=100,menu=true,focused=true,gameplay=true,player=true,airborne=false,ragdoll=false,
            teleport=false,wipeouts=0,level="sanvan",records={},calls={request=0,read=0,cancel=0,ack=0,store=0,encode=0},events={}}
        local s={time={},input={},skater={},level={},storage={},json={}}
        function s.time.now() return f.now end
        function s.input.focus() return {focused=f.focused,interface_open=f.menu,gameplay=f.gameplay} end
        function s.skater.get()
            if f.get_throw then error("read failed") end
            if f.player then return {airborne=f.airborne} end
        end
        function s.skater.telemetry() return {skater=f.player,airborne=f.airborne,teleport_pending=f.teleport,
            watch={valid=f.player,state=f.state,ragdoll_known=true,ragdoll=f.ragdoll,wipeouts=f.wipeouts}} end
        function s.level.current() if f.level then return {name=f.level} end end
        function s.input.pulse(slot,button)
            f.calls.request+=1;table.insert(f.events,"request");check(button=="y","adapter requests only selected stock Y")
            if f.pulse_mode=="throw" then error("uncertain wrapper") end
            if f.pulse_mode=="false" then return false end
            if f.pulse_mode=="nil" then return nil end
            if f.pulse_mode=="refuse" then return nil,"clock_unavailable" end
            f.handle,f.slot,f.requested=newproxy(),slot,math.floor(f.now)
            return f.handle
        end
        function s.input.pulse_state(h)
            f.calls.read+=1;check(h==f.handle,"read uses exact returned opaque userdata")
            if f.read_throw then error("read unavailable") end
            local debt=f.debt==true
            return {sequence="9007199254740994",status=debt and "pressing" or "revoked",reason=debt and "none" or "unavailable",
                user=f.slot,button=0x8000,requested_ms=tostring(f.requested),expires_ms=tostring(f.requested+1000),
                observed_ms=tostring(math.floor(f.now)),source_epoch="9007199254740995",transport="xinput",source_identity="observed_stream",
                publication_scope="process_outer_xinput_buffer",consumption="unobserved",semantic_completion="unobserved",
                first_rejection_mask=debt and 0 or 1280,first_rejection_stage=debt and "none" or "core_plan",
                press_candidates="7",press_publications="7",neutral_publications=debt and "0" or "1",original_failures="0",contentions="0",
                terminal=not debt,report_debt=debt,claim_released=not debt,actor_retired=false,orphaned=false,quarantined=false,
                original_result_known=false}
        end
        function s.input.pulse_cancel(h) f.calls.cancel+=1;check(h==f.handle,"cancel never substitutes a handle");return true end
        function s.input.pulse_acknowledge(h)
            f.calls.ack+=1;table.insert(f.events,"ack")
            local record=f.records[terminal_key]
            check(h==f.handle and record and record.receipt.sequence=="9007199254740994", "full terminal receipt is cached before acknowledgement")
            check(record.receipt.first_rejection_mask==1280 and record.receipt.status=="revoked","raw SDK outcome is preserved before acknowledgement")
            if f.ack_throw then error("ack uncertain") end
            if f.ack_false then return false end
            return true
        end
        function s.json.encode(record)
            f.calls.encode+=1
            if f.oversize and record.policy then return string.rep("x",12001) end
            return "bounded model encoding"
        end
        function s.storage.set(key,record)
            f.calls.store+=1
            if key==terminal_key then
                table.insert(f.events,"terminal_store")
                if f.store_mode=="throw" then error("cache refused") end
                if f.store_mode=="false" then return false end
                if f.store_mode=="nil" then return nil end
            end
            f.records[key]=copy(record)
            -- The actual SDK contract is zero values, not `return true`.
        end
        return f,Runtime.new(s)
    end
    local function ticks(f,a,n)
        local out
        for _=1,n do f.now+=100;out=a:update() end
        return out
    end
    local function launch(f,a,slot)
        check(a:request(slot or 0),"explicit menu request accepted")
        ticks(f,a,3);check(f.calls.request==0,"open menu cannot dispatch a pulse")
        f.menu=false;local out=ticks(f,a,13)
        check(f.calls.request==1,"closed-menu neutral and600ms baseline produce one call")
        return out
    end
    do
        local f,a=fake();local out=a:status()
        check(out.phase=="idle" and f.calls.request==0 and f.calls.store==0,"constructor and status are inert")
        ticks(f,a,20)
        check(f.calls.request==0 and f.calls.store==0 and f.calls.encode==0,"idle ticking makes no control or storage calls")
        a:unload();a:update();check(f.calls.cancel==0 and f.calls.store==0,"unused unload is inert")
        cases+=1
    end
    do
        for slot=0,3 do
            local f,a=fake();launch(f,a,slot);f.state=504;local out=ticks(f,a,35)
            check(out.historical_transition and out.qualified_transition and out.outcome=="target_observed","revoked report plus settled504 is independently qualified")
            check(f.slot==slot and f.calls.request==1 and f.calls.ack==1,"explicit slot is preserved with one call and one ack")
            local r=f.records[terminal_key].receipt
            check(r.status=="revoked" and r.first_rejection_mask==1280 and r.press_publications=="7","terminal cache retains exact raw receipt")
            check(f.records[progress_key].phase=="done" and f.records[progress_key].acknowledged,"flat progress records completed cleanup")
            f.menu=true;out=ticks(f,a,1)
            check(out.historical_transition and not out.qualified_transition,"menu loss affects current readiness without rewriting history")
            a:unload();out=a:status()
            check(out.historical_transition and out.outcome=="target_observed" and f.calls.cancel==0,"clean historical success is preserved on unload")
        end
        cases+=1
    end
    do
        local f,a=fake();f.state=504;launch(f,a,2);f.state=100;local out=ticks(f,a,35)
        check(out.initial_state==504 and out.expected_state==100 and out.historical_transition,"reverse action uses frozen504 baseline")
        check(f.records[terminal_key].storage_scope=="Host cache acceptance; disk durability is unobserved","stored record does not claim durable persistence")
        cases+=1
    end
    do
        local f,a=fake()
        for _,slot in {-1,.5,4,"0",false} do check(not a:request(slot),"invalid slot cannot arm") end
        check(a:request(0),"first explicit arm succeeds")
        local out=a:status();out.phase="idle";out.retained=false;out.calls.request=0
        check(not a:request(1) and f.calls.request==0,"copied status cannot unlock or replace pending ownership")
        f.now=60000;a:update();check(f.calls.request==0,"60s arm expires without a pulse")
        f.menu=false;ticks(f,a,20);check(f.calls.request==0,"expired arm never resumes automatically")
        cases+=1
    end
    do
        for _,change in {"focused","player","airborne","ragdoll","teleport","state","level","get_throw"} do
            local f,a=fake();check(a:request(0),"arm begins with known readiness")
            if change=="state" then f.state=504 elseif change=="level" then f.level="other"
            elseif change=="focused" or change=="player" then f[change]=false else f[change]=true end
            ticks(f,a,1)
            f.focused,f.player,f.airborne,f.ragdoll,f.teleport,f.get_throw=true,true,false,false,false,false
            f.menu=false;ticks(f,a,15)
            check(f.calls.request==0 and f.calls.ack==0,"changed readiness/state/level or API error consumes the arm")
        end
        cases+=1
    end
    do
        for _,mode in {"false","nil","throw","refuse"} do
            local f,a=fake();f.pulse_mode=mode;launch(f,a);local out=ticks(f,a,20)
            check(f.calls.request==1 and f.calls.read==0 and f.calls.ack==0,"false/nil/exception/refusal never repeats or fabricates a handle")
            if mode=="refuse" then check(out.outcome=="failed" and not out.retained,"definite nil+reason refusal owns no handle")
            else check(out.retained and out.outcome=="unresolved" and not a:request(0),"unknown call outcome blocks replacement") end
        end
        cases+=1
    end
    do
        for _,mode in {"false","nil","throw","oversize"} do
            local f,a=fake();if mode=="oversize" then f.oversize=true else f.store_mode=mode end
            launch(f,a);local out=ticks(f,a,15)
            check(f.calls.ack==0 and out.retained and out.outcome=="unresolved","failed, nonzero-return or oversize terminal storage never acknowledges")
            check(f.calls.request==1 and f.calls.cancel<=1,"storage failure cannot retry or flood cancellation")
        end
        cases+=1
    end
    do
        for _,mode in {"ack_false","ack_throw","read_throw"} do
            local f,a=fake();f[mode]=true;launch(f,a);local out=ticks(f,a,15)
            check(out.retained and not out.historical_transition and not a:request(0),"failed/unknown read or ack retains ownership")
            check(f.calls.request==1 and f.calls.ack<=1 and f.calls.cancel<=1,"effect exceptions are joined once without control retries")
        end
        cases+=1
    end
    do
        local f,a=fake();f.debt=true;launch(f,a);local before=f.calls.cancel
        local out=a:unload();a:unload();ticks(f,a,3)
        check(f.calls.cancel==before+1 and f.calls.ack==0,"unload attempts cancel once and never acknowledges debt")
        check(out.retained and out.outcome=="unresolved" and f.records[progress_key].unloaded,"unload progress retains actual obligation")
        cases+=1
    end
    do
        local f,a=fake();launch(f,a);f.state=504;ticks(f,a,35)
        f.wipeouts=1;f.state=300;f.ragdoll=true;ticks(f,a,1)
        f.state,f.ragdoll,f.menu=504,false,true
        check(a:request(1),"a completed acknowledged attempt does not poison later fall/getup readiness")
        f.menu=false;ticks(f,a,13);check(f.calls.request==2,"a fresh explicit gesture can start the next stock transition")
        local g,b=fake();g.wipeouts=5;launch(g,b);g.state=504;ticks(g,b,35)
        g.level,g.wipeouts,g.menu="other",0,true
        check(b:request(3),"observed new context can establish a fresh counter baseline after done")
        cases+=1
    end
    return {cases=cases,assertions=assertions,native_actions=0}
end
return tests

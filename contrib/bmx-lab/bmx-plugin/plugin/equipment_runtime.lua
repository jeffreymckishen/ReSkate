-- Explicit menu adapter for stock board/on-foot transitions. No effect occurs
-- on require/new, and no physical button is bound or captured here. The SDK
-- owns unload cleanup; this adapter never claims native consumption or BMX mount.
local Transition=require("./equipment_transition")
local Runtime,Adapter={},{}
Adapter.__index=Adapter
local maximum_integer=9007199254740991
local arm_ms,ledger_bytes=60000,12000
local storage_key="bmx_equipment_terminal_v1"
local progress_key="bmx_equipment_runtime_v1"
local function integer(v,max) return type(v)=="number" and v==v and v>=0 and v<=max and v%1==0 end
local function short(v)
    return type(v)=="string" and v:gsub("[%c]"," "):sub(1,120) or "Unavailable or malformed API result"
end
local function copy(t)
    if type(t)~="table" then return t end
    local out={};for k,v in t do out[k]=copy(v) end;return out
end
local function api(s,group,name)
    local t=type(s)=="table" and s[group]
    return type(t)=="table" and type(t[name])=="function" and t[name] or nil
end
local function call(fn,...)
    if type(fn)~="function" then return false,"API unavailable" end
    return pcall(fn,...)
end
local function boolean(v) if type(v)=="boolean" then return v end;return nil end
local function store(fn,key,record)
    if type(fn)~="function" then return false end
    local result=table.pack(pcall(fn,key,record))
    return result[1]==true and result.n==1 -- storage.set succeeds with zero values, not a truthy result.
end
local function common(o,menu)
    return o.focused==true and (menu or o.menu_closed==true) and o.gameplay==true and o.local_player==true
        and o.teleport_pending==false
end
local function ready(o,menu)
    return common(o,menu) and o.grounded==true and o.ragdoll_known==true and o.ragdoll==false
        and o.fallen==false and (o.state==100 or o.state==504)
end

function Runtime.new(services)
    local s=services or reskate
    return setmetatable({_model=Transition.new(),_generation=1,_context="equipment-local-1",_api={
        now=api(s,"time","now"),focus=api(s,"input","focus"),get=api(s,"skater","get"),
        telemetry=api(s,"skater","telemetry"),level=api(s,"level","current"),
        pulse=api(s,"input","pulse"),read=api(s,"input","pulse_state"),cancel=api(s,"input","pulse_cancel"),
        ack=api(s,"input","pulse_acknowledge"),encode=api(s,"json","encode"),store=api(s,"storage","set")},
        _output={phase="idle",outcome="idle",attempt=0,retained=false,reason="none"},_replies={},_sent={},
        _calls={request=0,read=0,cancel=0,store=0,acknowledge=0},_detail="Idle; stock equipment only, BMX is not mounted."},Adapter)
end
function Adapter:_facts()
    local a=self._api
    local time_ok,t=call(a.now)
    local clock=time_ok and type(t)=="number" and t==t and t>=0 and t<=maximum_integer
    if clock then t=math.floor(t);clock=not self._last_clock or t>=self._last_clock end
    if clock then self._last_clock=t else t=nil end
    local fok,f=call(a.focus);local pok,p=call(a.get);local wok,w=call(a.telemetry);local lok,l=call(a.level)
    f=fok and type(f)=="table" and f or nil;p=pok and type(p)=="table" and p or nil
    w=wok and type(w)=="table" and w or nil;l=lok and type(l)=="table" and l or nil
    local watch=w and type(w.watch)=="table" and w.watch or nil
    local level=l and type(l.name)=="string" and #l.name>0 and #l.name<=200 and l.name or nil
    local present=p~=nil and w~=nil and w.skater==true and watch~=nil and watch.valid==true
    -- This generation records observed local continuity only. It cannot detect
    -- an unobserved same-name reload or prove native actor/allocation identity.
    if self._seen and (level~=self._level or present~=self._present) then
        if self._generation<maximum_integer then self._generation+=1;self._context="equipment-local-"..tostring(self._generation)
        else self._context=nil end
    end
    self._seen,self._level,self._present=true,level,present
    local state=watch and watch.valid==true and integer(watch.state,4294967295) and watch.state or nil
    local grounded
    if p and w and type(p.airborne)=="boolean" and type(w.airborne)=="boolean" then grounded=not p.airborne and not w.airborne end
    local ragdoll_known=watch and boolean(watch.ragdoll_known)
    local ragdoll=watch and boolean(watch.ragdoll)
    local fallen
    if state~=nil and ragdoll_known~=nil and ragdoll~=nil then
        fallen=state==300 or ragdoll_known and ragdoll
        local active=self._pending~=nil or self._handle~=nil or self._unknown_request or self._output.retained
            or self._output.phase~="idle" and self._output.phase~="done"
        if active and self._wipeouts and watch and integer(watch.wipeouts,maximum_integer) then
            if watch.wipeouts>self._wipeouts then fallen=true
            elseif watch.wipeouts<self._wipeouts then state=nil end
        end
    end
    local menu_closed
    if f and type(f.interface_open)=="boolean" then menu_closed=not f.interface_open end
    local o={focused=f and boolean(f.focused),menu_closed=menu_closed,
        gameplay=f and boolean(f.gameplay),local_player=present,teleport_pending=w and boolean(w.teleport_pending),
        grounded=grounded,ragdoll_known=ragdoll_known,ragdoll=ragdoll,state=state,fallen=fallen}
    local facts={now_ms=t,context=self._context,observation=o,level=level,
        wipeouts=watch and integer(watch.wipeouts,maximum_integer) and watch.wipeouts or nil}
    self._facts_now=facts
    return facts
end
function Adapter:request(slot,admitted_at_ms)
    if self._closed or self._storage_fault then return false,"Adapter is closed or storage is unresolved" end
    if not integer(slot,3) then return false,"Choose an XInput slot from0 to3" end
    local out=self._output
    if self._pending or self._handle or self._unknown_request or out.retained or out.phase~="idle" and out.phase~="done" then
        return false,"Busy or unresolved; no second equipment request"
    end
    local f=self:_facts()
    if not f.now_ms or not f.level or not f.context or not ready(f.observation,true) then
        self._detail="Arm refused: settled focused stock equipment is unavailable."
        return false,self._detail
    end
    -- A same-owner deferred caller may preserve its original admission deadline.
    -- Existing callers omit this argument and retain the original request timing.
    if admitted_at_ms~=nil and (not integer(admitted_at_ms,maximum_integer)
        or admitted_at_ms>f.now_ms or f.now_ms-admitted_at_ms>=arm_ms) then
        self._detail="Arm refused: original admission deadline elapsed or clock is invalid."
        return false,self._detail
    end
    self._pending={slot=slot,at=admitted_at_ms or f.now_ms,last=f.now_ms,context=f.context,level=f.level,state=f.observation.state,neutral=false}
    self._wipeouts=f.wipeouts
    self._ever_requested=true
    self._detail="Armed for60s: close the menu; leave the physical controller neutral."
    if not self:_progress(true) then self._pending=nil;return false,"Arm refused: progress cache unavailable" end
    return true
end
function Adapter:_progress(force)
    if not self._ever_requested then return true end
    if self._progress_disabled then return false end
    if not force and self._progress_at and self._last_clock and self._last_clock-self._progress_at<200 then return true end
    local record=self:status()
    record.schema,record.kind,record.wall_ms=1,"stock-equipment-runtime-v1",self._last_clock
    record.context_generation,record.level=self._generation,self._level
    record.arm_started_ms,record.arm_ms=self._pending and self._pending.at,arm_ms
    record.storage_scope="Host cache snapshot; no disk durability, native consumption or BMX mount proof"
    local ok,text=call(self._api.encode,record)
    if not ok or type(text)~="string" or #text>ledger_bytes or not store(self._api.store,progress_key,record) then
        self._progress_disabled,self._storage_fault=true,true
        self._detail="Progress cache failed; no replacement request or automatic retry."
        return false
    end
    self._progress_at=self._last_clock
    return true
end
function Adapter:_dispatch(out)
    local intents=out.intents or {};local a=self._api;local replies={}
    local function bound(e) return type(e)=="table" and e.attempt==out.attempt and e.attempt==self._binding and e.handle==self._handle end
    local e=intents.request
    if e and self._sent.request~=e.attempt then
        self._sent.request=e.attempt
        local ok,h,why
        if e.attempt==out.attempt and e.user==self._selected and e.button=="y" and not self._handle and self:_progress(true) then
            self._calls.request+=1;ok,h,why=call(a.pulse,e.user,"y")
        elseif self._storage_fault then ok,h,why=true,nil,"progress_store_failed" end
        if ok and type(h)=="userdata" then
            self._binding,self._handle=e.attempt,h
            self._request_response={known=true,accepted=true}
            replies.request_result={attempt=e.attempt,accepted=true,handle=h}
        elseif ok and h==nil and type(why)=="string" and #why>0 and #why<=160 then
            self._request_response={known=true,accepted=false,reason=short(why)}
            replies.request_result={attempt=e.attempt,accepted=false,reason=why}
        else
            self._request_response={known=false,accepted=false,reason="unknown"}
            self._unknown_request=true;replies.request_result={attempt=e.attempt}
            self._detail="Pulse outcome unknown; no retry or replacement request."
        end
    end
    e=intents.cancel
    if e and self._sent.cancel~=e.attempt then
        self._sent.cancel=e.attempt;self._calls.cancel+=1
        local ok,accepted=false,nil
        if bound(e) then ok,accepted=call(a.cancel,e.handle) end
        replies.cancel_result={attempt=e.attempt,handle=e.handle,accepted=ok and type(accepted)=="boolean" and accepted or nil}
        if ok and accepted==false then replies.cancel_result.accepted=false end
    end
    e=intents.read
    if e and (self._sent.read_attempt~=e.attempt or self._sent.read_id~=e.read_id) then
        self._sent.read_attempt,self._sent.read_id=e.attempt,e.read_id;self._calls.read+=1
        local ok,r=false,nil
        if bound(e) then ok,r=call(a.read,e.handle) end
        replies.receipt_result={attempt=e.attempt,handle=e.handle,read_id=e.read_id,receipt=ok and r or nil}
    end
    e=intents.store
    if e and self._sent.store~=e.attempt then
        self._sent.store=e.attempt
        local record={schema=1,policy="stock-equipment-transition-v1",attempt=e.attempt,user=self._selected,button="y",
            initial_state=out.initial_state,expected_state=out.expected_state,context_generation=self._generation,
            level=self._level,receipt=copy(e.receipt),
            storage_scope="Host cache acceptance; disk durability is unobserved",
            observation_scope="Sampled Lua readiness; native consumption and semantic causality are unobserved"}
        local ok,text=false,nil
        if bound(e) and e.sequence==e.receipt.sequence then ok,text=call(a.encode,record) end
        local stored=false
        if ok and type(text)=="string" and #text<=ledger_bytes then
            self._calls.store+=1
            stored=store(a.store,storage_key,record)
        end
        if stored then self._cached=copy(record) end
        replies.store_result={attempt=e.attempt,handle=e.handle,sequence=e.sequence,accepted=stored}
    end
    e=intents.acknowledge
    if e and self._sent.acknowledge~=e.attempt then
        self._sent.acknowledge=e.attempt;self._calls.acknowledge+=1
        local ok,accepted=false,nil
        if bound(e) and self._cached and self._cached.attempt==e.attempt and self._cached.receipt.sequence==e.sequence then
            ok,accepted=call(a.ack,e.handle)
        end
        replies.ack_result={attempt=e.attempt,handle=e.handle,sequence=e.sequence,accepted=ok and type(accepted)=="boolean" and accepted or nil}
        if ok and accepted==false then replies.ack_result.accepted=false end
        if ok and accepted==true then self._handle=nil end
    end
    self._replies=replies
end
function Adapter:update()
    if self._closed then return self:status() end
    local f=self:_facts();local down=false
    if self._pending then
        local p=self._pending
        if not f.now_ms or not f.level or f.context~=p.context or f.level~=p.level or not ready(f.observation,true)
            or f.observation.state~=p.state or f.now_ms-p.at>=arm_ms then
            self._pending=nil;self._detail="Arm cancelled by deadline or changed readiness; no pulse requested."
        elseif f.observation.menu_closed==true and f.now_ms>p.last then
            if p.neutral then
                down=true;self._selected=p.slot;self._pending=nil
                self._selected_context=p.context;self._request_response=nil
                self._calls={request=0,read=0,cancel=0,store=0,acknowledge=0}
                self._cached=nil;self._detail="Qualifying the stock baseline; no automatic retries."
            else p.neutral=true end
            p.last=f.now_ms
        end
    end
    local frame={now_ms=f.now_ms,context=f.context,slot=self._selected or (self._pending and self._pending.slot) or 0,
        gesture_down=down,loaded=true,allowed=not self._storage_fault,observation=f.observation}
    for k,v in self._replies do frame[k]=v end
    self._replies={}
    local previous=self._output.phase
    self._output=self._model:update(frame)
    self:_dispatch(self._output)
    if self._output.reason~="none" then self._detail=short(self._output.reason)
    elseif self._output.historical_transition then self._detail="Expected stock state observed; native consumption remains unobserved." end
    self:_progress(previous~=self._output.phase)
    return self:status()
end
function Adapter:unload()
    if self._closed then return self:status() end
    self._closed=true;self._pending=nil
    if self._handle and self._sent.cancel~=self._binding then
        self._sent.cancel=self._binding;self._calls.cancel+=1
        local ok,accepted=call(self._api.cancel,self._handle)
        self._unload_cancel={attempted=true,known=ok and type(accepted)=="boolean",accepted=ok and accepted==true}
    end
    local duty=self._handle~=nil or self._unknown_request==true or self._output.retained==true
    self._detail=duty and "Unloaded; SDK retains any actual report cleanup duty." or "Unloaded; no equipment request is active."
    -- No acknowledgement or fabricated neutral publication on unload. The
    -- mandatory VM-close backend cleanup retains any actual report obligation.
    self:_progress(true)
    return self:status()
end
function Adapter:status()
    local o=self._output
    local f=self._facts_now
    local currently_ready=f and f.now_ms and f.context==self._selected_context and ready(f.observation,false)
        and f.observation.state==o.expected_state
    local retained=o.retained==true or self._handle~=nil or self._unknown_request==true
    return {phase=self._pending and "armed" or self._closed and retained and "unloaded" or o.phase,
        outcome=self._closed and retained and "unresolved" or o.outcome,reason=short(o.reason),detail=short(self._detail),
        attempt=o.attempt,slot=self._selected,initial_state=o.initial_state,expected_state=o.expected_state,
        retained=retained,acknowledged=o.acknowledged==true,
        qualified_transition=not self._closed and currently_ready==true and o.qualified_transition==true,historical_transition=o.historical_transition==true,
        calls=copy(self._calls),receipt=copy(o.receipt),terminal_receipt=copy(o.terminal_receipt),suffix=copy(o.suffix),
        request_result=copy(self._request_response),
        storage_key=storage_key,progress_key=progress_key,storage_accepted=self._cached~=nil,
        unloaded=self._closed==true,unload_cancel=copy(self._unload_cancel),scope="Stock board/on-foot only; BMX is not mounted"}
end
return Runtime

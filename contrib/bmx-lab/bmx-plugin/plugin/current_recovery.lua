-- Explicit current-local-skater recovery, after the bike owner proves cleanup.
-- This adapter uses the SDK's recover handle. It does not manufacture the actor,
-- session or epoch observations required by the separate RecoveryRuntime model.
-- The string passed to Recovery is local policy bookkeeping, not native identity.
-- Require/new are inert. One explicit arm per adapter; no automatic remount/retry.
local Recovery=require("./recovery")
local Current,Adapter={},{}
Adapter.__index=Adapter
local MAX=9007199254740991
local ARM_MS,RECORD_BYTES=60000,16000
local KEY="bmx_current_recovery_v1"
local function finite(v) return type(v)=="number" and v==v and v>=0 and v<=MAX end
local function copy(v)
    if type(v)~="table" then return v end
    local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out
end
local function short(v) return type(v)=="string" and v:gsub("[%c]"," "):sub(1,180) or "unavailable or malformed result" end
local function yes(r) return r[1]==true and r.n==2 and r[2]==true end
function Current.new(lookup,call,clean)
    return setmetatable({_lookup=lookup,_call=call,_clean=clean,_policy=Recovery.new(),
        _out={outcome="idle",reason="none",retained=false,intents={}},_phase="idle",_calls={request=0,poll=0,cancel=0,store=0,acknowledge=0}},Adapter)
end
function Adapter:_invoke(name,...)
    return self._call("recovery."..name,self._lookup(name),...)
end
function Adapter:_facts()
    local f=self:_invoke("input.focus")
    local a=self:_invoke("input.allowed")
    local m=self:_invoke("menu.game")
    local w=self:_invoke("skater.telemetry")
    local l=self:_invoke("level.current")
    if not f[1] or f.n~=2 or not a[1] or a.n~=2 or not m[1] or m.n~=2
        or not w[1] or w.n~=2 or not l[1] or l.n~=2 then return nil end
    f,a,m,w,l=f[2],a[2],m[2],w[2],l[2]
    local watch=type(w)=="table" and w.watch or nil
    if type(f)~="table" or type(f.focused)~="boolean" or type(f.gameplay)~="boolean"
        or type(f.interface_open)~="boolean" or type(a)~="boolean" or type(m)~="table" or type(m.open)~="boolean"
        or type(w)~="table" or w.skater~=true or w.teleport_pending~=false or type(watch)~="table"
        or watch.valid~=true or watch.ragdoll_known~=true or type(watch.ragdoll)~="boolean"
        or type(watch.state)~="number" or watch.state%1~=0 or watch.state<0 or watch.state>4294967295
        or not finite(watch.wipeouts) or watch.wipeouts%1~=0 or type(l)~="table"
        or type(l.name)~="string" or #l.name==0 or #l.name>200 then return nil end
    return {focused=f.focused,gameplay=f.gameplay,closed=not f.interface_open and not m.open,input_allowed=a,
        level=l.name,wipeouts=watch.wipeouts,fallen=watch.ragdoll or watch.state==300}
end
function Adapter:_ready(f,menu)
    return not self._closed and not self._boundary and f and self._clean()==true and f.focused and f.gameplay and (menu or f.closed and f.input_allowed)
        and (not self._level or f.level==self._level and f.wipeouts==self._wipeouts)
end
function Adapter:request(now)
    if self._closed or self._attempted or self._busy then return false,"Get-up already requested or recovery is closed" end
    if not finite(now) or now>MAX-ARM_MS or self._clean()~=true then return false,"Complete bike cleanup is required before get-up" end
    -- Latch before callbacks: nested requests cannot replace or extend this arm.
    self._busy=true
    local f=self:_facts()
    local available=true
    for _,name in ipairs({"skater.recover","skater.recovery_state","skater.recovery_cancel","skater.recovery_acknowledge",
        "json.encode","storage.set"}) do available=available and self._lookup(name)~=nil end
    local accepted=not self._closed and not self._boundary and available and self:_ready(f,true) and f.fallen
    if accepted then
        self._attempted,self._armed,self._at,self._deadline=true,true,now,now+ARM_MS
        self._level,self._wipeouts=f.level,f.wipeouts
        self._phase,self._detail="armed","Close both menus for one current-local-skater get-up request."
    else self._detail="Get-up refused: focused fallen local skater, APIs and complete bike cleanup are required." end
    self._busy=false
    return accepted,accepted and nil or self._detail
end
function Adapter:_store(receipt)
    local record={schema=1,kind="current-local-recovery-v1",receipt=copy(receipt),
        scope="Exact native recover handle receipt; historical completion, not current actor identity or remount authority",
        storage_scope="Host cache acceptance; disk durability is unobserved"}
    local encoded=self:_invoke("json.encode",record)
    if not encoded[1] or encoded.n~=2 or type(encoded[2])~="string" or #encoded[2]>RECORD_BYTES then return false end
    self._calls.store+=1
    local stored=self:_invoke("storage.set",KEY,record)
    if stored[1] and stored.n==1 then self._saved=copy(record);return true end
    return false
end
function Adapter:_dispatch(out)
    local intents,replies=out.intents or {},{}
    local e=intents.request
    if e and not self._request_sent then
        self._request_sent=true
        local r
        local final=self:_facts()
        if not self._closed and self:_ready(final,false) and final.fallen then
            self._calls.request+=1;r=self:_invoke("skater.recover")
        else r={true,nil,"readiness_lost_before_recovery",n=3} end
        if r[1] and r.n==2 and type(r[2])=="userdata" then
            self._handle=r[2];replies.request_result={attempt=e.attempt,accepted=true,handle=r[2]}
        elseif r[1] and r.n==3 and r[2]==nil and type(r[3])=="string" and #r[3]>0 and #r[3]<=160 then
            replies.request_result={attempt=e.attempt,accepted=false,reason=r[3]}
        else self._unknown=true;replies.request_result={attempt=e.attempt} end
    end
    e=intents.poll
    if e and e.handle==self._handle and not self._closed then
        self._calls.poll+=1
        local r=self:_invoke("skater.recovery_state",e.handle)
        replies.receipt_handle=e.handle
        replies.receipt=r[1] and r.n==2 and type(r[2])=="table" and copy(r[2]) or {}
    end
    e=intents.cancel
    if e and e.handle==self._handle and not self._cancel_sent and not self._closed then
        self._cancel_sent=true;self._calls.cancel+=1
        local r=self:_invoke("skater.recovery_cancel",e.handle)
        self._cancel={attempted=true,known=r[1] and (r.n==2 or r.n==3) and type(r[2])=="boolean",accepted=yes(r)}
    end
    e=intents.acknowledge
    if e and e.handle==self._handle and not self._ack_sent and not self._closed then
        self._ack_sent=true
        -- A full validated terminal receipt is retained before the native ACK.
        -- A failed store cannot become an ACK or a fresh recovery attempt.
        if out.receipt and self:_store(out.receipt) and not self._closed then
            self._calls.acknowledge+=1
            local r=self:_invoke("skater.recovery_acknowledge",e.handle)
            local accepted=r[1] and r.n==2 and type(r[2])=="boolean" and r[2] or nil
            if r[1] and (r.n==2 or r.n==3) and r[2]==false then accepted=false end
            replies.ack_result={attempt=e.attempt,handle=e.handle,accepted=accepted}
            if accepted==true then self._handle=nil end
        else self._storage_fault=true end
    end
    self._replies=replies
end
function Adapter:active()
    return self._armed==true or self._handle~=nil or self._unknown==true or self._out.retained==true
end
function Adapter:update(now)
    if self._closed or not self._attempted then return self:status() end
    if self._busy then self._boundary=true;return self:status() end
    self._busy=true
    local clock=finite(now) and (not self._last or now>=self._last)
    local fresh=clock and (not self._last or math.floor(now)>math.floor(self._last))
    if clock then self._last=now else self._boundary=true end
    local f=self:_facts()
    local ready=not self._boundary and not self._storage_fault and self:_ready(f,false)
    local down=false
    if self._armed then
        if self._boundary or not clock or now<self._at or now>=self._deadline or not self:_ready(f,true) or not f.fallen then
            self._armed=false;self._phase="cancelled";self._detail="Get-up arm cancelled; no automatic retry."
        elseif fresh and ready then
            if self._neutral then down=true;self._armed=false else self._neutral=true end
        end
    end
    local frame={now_ms=clock and math.floor(now) or nil,actor="explicit-current-local-recovery",source_epoch=1,fall_epoch=1,
        gesture_down=down,allowed=ready==true,loaded=not self._closed,fallen=f and f.fallen==true or false,
        park_ready=self._clean()==true,release_ready=self._clean()==true}
    for k,v in pairs(self._replies or {}) do frame[k]=v end
    self._replies={}
    self._out=self._policy:update(frame)
    self:_dispatch(self._out)
    if self._request_sent then self._phase=self._out.outcome end
    self._busy=false
    return self:status()
end
function Adapter:stop(why)
    if not self._attempted and not self._busy then return end
    self._boundary=true;self._armed=false
    self._phase="cancelled";self._detail=short(why)
end
function Adapter:unload()
    if self._closed then return self:status() end
    -- No new request, poll or ACK from an unloaded VM. SDK release owns any
    -- pending/entered handle, including an uncertain request without a handle.
    self._closed=true;self._armed=false
    self._phase=self:active() and "unloaded_retained" or "unloaded"
    return self:status()
end
function Adapter:status()
    return {phase=self._phase,detail=self._detail,attempted=self._attempted==true,armed=self._armed==true,
        retained=self:active(),unknown=self._unknown==true,storage_fault=self._storage_fault==true,
        native_completed=self._out.native_completed==true,acknowledged=self._out.acknowledged==true,
        receipt=copy(self._out.receipt),saved=copy(self._saved),calls=copy(self._calls),cancel=copy(self._cancel),
        unloaded=self._closed==true,storage_key=KEY,arm_started_ms=self._at,deadline_ms=self._deadline,
        scope="Explicit current local skater selected by SDK; no native actor token synthesized, no automatic remount"}
end
return table.freeze(Current)

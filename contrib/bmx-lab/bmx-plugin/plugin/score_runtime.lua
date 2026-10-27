-- Unbound local scoring service. The later entry calls advance(dt_ms/1000),
-- ride(log, context) or composer(sample, context), and draw(d). Host elapsed time
-- advances only banner expiry; physical accounting uses the Feed step's own h.
-- No global reskate access or native score/progression/HUD calls live here.
local Line=require("./score_line")
local Rules=require("./score_rules")
local Catalog=require("./score_catalog")
local Feed=require("./score_feed")
local Hud=require("./score_hud")
local Runtime={}
local Object={}
Object.__index=Object
local MAX=Rules.MAX_SCORE
local KEY="bmx_score_v1"
local MAX_STEPS=8
local modes={rolling=true,airborne=true,manual=true,nose_manual=true,grinding=true,stalling=true,bailed=true}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function finite(v) return Rules.finite(v) end
local function uint(v) return finite(v) and v>=0 and v<=MAX and v==math.floor(v) end
local function sat(v) return math.floor(math.clamp(v,0,MAX)) end
local function short(v,fallback)
    return type(v)=="string" and #v>0 and #v<=160 and v or fallback
end
local function dense(t,limit)
    if not plain(t) then return nil end
    local n,highest=0,0
    for key in next,t do
        n+=1
        if n>limit or not uint(key) or key<1 or key>limit then return nil end
        highest=math.max(highest,key)
    end
    return highest==n and n or nil
end
local function freeze(t) return table.freeze(t) end
local function initial_snapshot()
    return {active=false,airborne=false,points=0,score=0,multiplier=1,tricks=0,links=0,categories=0,
        remaining=0,manual_seconds=0,grind_points=0}
end
local function stats_copy(s)
    return {best_line=s.best_line,best_single_air=s.best_single_air,session_total=s.session_total,
        session_best_line=s.session_best_line,session_best_air=s.session_best_air}
end
local function loaded_record(v)
    return plain(v) and v.version==1 and uint(v.best_line) and uint(v.best_single_air) and uint(v.session_total)
end
function Runtime.new(options)
    options=plain(options) and options or {}
    local rules=Rules.sanitize(options.rules)
    local self=setmetatable({_rules=rules,_line=Line.new(rules),_cursor=0,_generation=nil,_seconds=nil,
        _previous_mode=nil,_source=nil,_terminal=false,_busy=false,_snapshot=initial_snapshot(),
        _rows=freeze({}),_closed=nil,_closed_remaining=0,_live_name=nil,_manual_kind=nil,
        _stats={best_line=0,best_single_air=0,session_total=0,session_best_line=0,session_best_air=0},
        _storage_issue="unavailable",_save=nil,_pending_save=false,_issue="none",_view=nil,
        _ops=nil,_ops_view=nil,_ops_width=nil,_ops_height=nil,_layout_builds=0},Object)
    local storage=options.storage
    if plain(storage) and type(storage.get)=="function" and type(storage.set)=="function" then
        local got=table.pack(pcall(storage.get,KEY))
        if got[1] and got.n==2 and (got[2]==nil or loaded_record(got[2])) then
            if got[2] then
                self._stats.best_line=got[2].best_line
                self._stats.best_single_air=got[2].best_single_air
                self._stats.session_total=got[2].session_total
            end
            self._save,self._storage_issue=storage.set,"none"
        else
            -- Preserve unknown prior storage. Memory scoring remains available.
            self._storage_issue="read_fault"
        end
    end
    self:_refresh()
    return self
end
function Object:_persist()
    if not self._save then return end
    local s=self._stats
    local record={version=1,best_line=s.best_line,best_single_air=s.best_single_air,session_total=s.session_total}
    local wrote=table.pack(pcall(self._save,KEY,record))
    -- Native storage.set returns zero values. Retry only on a later normal bank.
    if wrote[1] and wrote.n==1 then self._pending_save=false;self._storage_issue="none"
    else self._pending_save=true;self._storage_issue="write_fault" end
end
local function same_view(a,b)
    if not a then return false end
    for _,key in ipairs({"active","airborne","live_name","rows","points","score","multiplier",
        "remaining","timer_total","manual_seconds","manual_kind","closed"}) do
        if a[key]~=b[key] then return false end
    end
    -- Banner expiry is discrete; its positive remaining time does not change ops.
    return (a.closed_remaining>0)==(b.closed_remaining>0)
end
function Object:_refresh()
    local s=self._snapshot
    local view={active=s.active,airborne=s.airborne or (not self._closed and not self._terminal and self._previous_mode=="airborne"),live_name=self._live_name,rows=self._rows,
        points=s.points,score=s.score,multiplier=s.multiplier,
        remaining=math.ceil(s.remaining/self._rules.line_seconds*24)/24*self._rules.line_seconds,
        timer_total=self._rules.line_seconds,manual_seconds=math.floor(s.manual_seconds*10)/10,
        manual_kind=self._manual_kind,closed=self._closed,closed_remaining=self._closed_remaining}
    if not same_view(self._view,view) then self._view=freeze(view) end
end
function Object:_remember(out,feed)
    self._snapshot=out.snapshot
    if #out.credits>0 then
        local rows={}
        for _,v in ipairs(self._rows) do table.insert(rows,v) end
        for _,credit in ipairs(out.credits) do
            if #rows==4 then table.remove(rows,1) end
            table.insert(rows,freeze({name=credit.name,points=credit.points,landing=credit.landing}))
        end
        self._rows=freeze(rows)
        local a=feed and feed.air and feed.air.landed
        -- Line emits the air credit last. A sub-threshold partless hop emits none.
        if out.issue=="none" and a and (#a.sequence>0 or (a.spin_half_turns or 0)>0
            or (a.front_flips or 0)>0 or (a.back_flips or 0)>0 or (a.barrel_rolls or 0)>0
            or a.air_seconds>=self._rules.hop_min_seconds) then
            local points=out.credits[#out.credits].points
            local stats=self._stats
            stats.best_single_air=math.max(stats.best_single_air,points)
            stats.session_best_air=math.max(stats.session_best_air,points)
            self._pending_save=true
        end
    end
    if out.closed then
        local c=out.closed
        local stats=self._stats
        local new_best=c.outcome~="lost" and c.score>stats.best_line
        if c.outcome=="banked" or c.outcome=="interrupted" then
            stats.best_line=math.max(stats.best_line,c.score)
            stats.session_best_line=math.max(stats.session_best_line,c.score)
            stats.session_total=sat(stats.session_total+c.score)
            self._pending_save=true
        end
        self._closed=freeze({outcome=c.outcome,reason=c.reason,score=c.score,points=c.points,
            multiplier=c.multiplier,tricks=c.tricks,new_best=new_best})
        self._closed_remaining=c.outcome=="lost" and 1.2 or 1.5
        self._live_name,self._manual_kind=nil,nil
        -- Interrupted credit counts in memory, but strict bank-only persistence
        -- defers it until the next normal bank. Unload before then can lose it.
        if c.outcome=="banked" then self:_persist() end
    end
end
function Object:_generation_change(generation)
    if generation==nil or generation==0 then return true end
    if not uint(generation) or generation<1 then return false end
    if self._generation==generation then return true end
    if self._generation and generation<self._generation then return false end
    if self._generation then self:_remember(self._line:finish("generation_changed","interrupted"),nil) end
    self._generation,self._cursor,self._seconds=generation,0,nil
    self._line,self._snapshot=Line.new(self._rules),initial_snapshot()
    self._previous_mode,self._terminal=nil,false
    self._rows,self._closed,self._closed_remaining=freeze({}),nil,0
    self._live_name,self._manual_kind=nil,nil
    return true
end
local function terminal_only(batch)
    return plain(batch) and dense(batch.steps,MAX_STEPS)==1 and plain(batch.steps[1]) and batch.steps[1].terminal~=nil
end
local function valid_batch(batch,cursor,last_seconds)
    if not plain(batch) then return false end
    local count=dense(batch.steps,MAX_STEPS)
    if not count or (batch.mode~=nil and not modes[batch.mode])
        or (batch.cursor~=nil and (not uint(batch.cursor) or batch.cursor<cursor or (not terminal_only(batch) and count>batch.cursor-cursor))) then return false end
    local previous,terminal=last_seconds,false
    for i=1,count do
        local step=batch.steps[i]
        if not plain(step) or terminal then return false end
        if step.terminal~=nil then
            local t=step.terminal
            if not plain(t) or step.feed~=nil or step.h~=nil or not short(t.reason,nil)
                or (t.outcome~="banked" and t.outcome~="lost" and t.outcome~="interrupted") then return false end
            terminal=true
        else
            local f=step.feed
            if not plain(f) or not finite(step.h) or step.h<0 or step.h>10
                or not finite(f.seconds) or f.seconds<0 or f.seconds>MAX
                or (previous~=nil and f.seconds<=previous) then return false end
            previous=f.seconds
        end
    end
    return true
end
function Object:_apply(batch)
    if plain(batch) and batch.generation==0 then
        if dense(batch.steps,MAX_STEPS)==0 then self._issue="no_stream";return true end
        batch={steps={{terminal={reason="ride_log_unavailable",outcome="interrupted"}}},issue="ride_log_unavailable"}
    end
    if not self:_generation_change(batch and batch.generation) then self._issue="stale_generation";return false end
    if self._terminal then self._issue="finished";return false end
    if plain(batch) and not terminal_only(batch) and batch.cursor==self._cursor and (dense(batch.steps,MAX_STEPS) or 0)>0 then
        self._issue="stale_batch";return false
    end
    if not valid_batch(batch,self._cursor,self._seconds) then
        self:_remember(self._line:finish("invalid_batch","interrupted"),nil)
        self._terminal,self._issue=true,"invalid_batch";self:_refresh();return false
    end
    local issue=short(batch.issue,"none")
    for _,step in ipairs(batch.steps) do
        local out
        if step.terminal then
            out=self._line:finish(step.terminal.reason,step.terminal.outcome)
            self._terminal=true
        else
            local f=step.feed
            out=self._line:step(step.h,f)
            self._seconds=f.seconds
            self._live_name=nil
            if f.mode=="airborne" or out.snapshot.airborne then
                local live=f.live
                local info=plain(live) and Catalog.get(live.movement_id) or nil
                if info then self._live_name=info.display
                elseif plain(live) and live.bar_rotating and live.tail_rotating then self._live_name="Barspin + Tailwhip"
                elseif plain(live) and live.bar_rotating then self._live_name="Barspin"
                elseif plain(live) and live.tail_rotating then self._live_name="Tailwhip"
                else self._live_name="Bunny Hop" end
            end
            if f.manual and f.manual.event=="balancing" then self._manual_kind=f.manual.kind end
            if f.manual and f.manual.event=="ended" then self._manual_kind=nil end
        end
        self:_remember(out,step.feed)
        if out.issue~="none" then issue=out.issue;break end
    end
    if batch.cursor~=nil then self._cursor=batch.cursor end
    if issue=="none" and #batch.steps>0 and batch.mode~=nil then self._previous_mode=batch.mode
    elseif issue~="none" then self._previous_mode=nil end
    self._issue=issue;self:_refresh();return true
end
function Object:update(batch)
    if self._busy then return false,"busy" end
    self._busy=true
    local ok,accepted=pcall(self._apply,self,batch)
    if not ok then
        self._issue="runtime_fault"
        self._terminal=true
        local closed_ok,out=pcall(self._line.finish,self._line,"runtime_fault","interrupted")
        if closed_ok then self:_remember(out,nil) end
        self:_refresh()
    end
    self._busy=false
    return ok and accepted or false,self._issue
end
local function context_copy(self,context)
    context=plain(context) and context or {}
    local out={}
    -- Copy only the adapter's declared context, never arbitrary caller fields.
    for _,key in ipairs({"seconds","h","speed","mode","ended","gap","interrupted","generation"}) do out[key]=context[key] end
    out.after_seconds,out.previous_mode=self._seconds,self._previous_mode
    return out
end
function Object:ride(log,context)
    if self._busy then return false,"busy" end
    if self._source and self._source~="ride" then return false,"source_mismatch" end
    self._source="ride"
    if not plain(log) or not self:_generation_change(log.generation) then return false,"stale_generation" end
    if log.generation==0 and log.n==0 and log.gap==false and plain(log.rows) and next(log.rows)==nil then
        self._issue="no_stream";return true,self._issue
    end
    local called,batch=pcall(Feed.ride,log,self._cursor,context_copy(self,context))
    if not called then
        self:update(nil);self._issue="adapter_fault";return false,self._issue
    end
    return self:update(batch)
end
function Object:composer(sample,context)
    if self._busy then return false,"busy" end
    if self._source and self._source~="composer" then return false,"source_mismatch" end
    if not plain(context) or not uint(context.generation) or context.generation<1 then return false,"generation_required" end
    if not self:_generation_change(context.generation) then return false,"stale_generation" end
    self._source="composer"
    local called,batch=pcall(Feed.composer,sample,context_copy(self,context))
    if not called then return self:update(nil) end
    return self:update(batch)
end
function Object:advance(seconds)
    if self._busy then return false,"busy" end
    if not finite(seconds) or seconds<0 or seconds>10 then return false,"invalid_elapsed" end
    self._closed_remaining=math.max(0,self._closed_remaining-seconds)
    if self._closed_remaining==0 then self._closed=nil end
    self:_refresh()
    return true
end
function Object:view() return self._view end
function Object:status()
    local stats=stats_copy(self._stats)
    return {cursor=self._cursor,generation=self._generation,last_seconds=self._seconds,source=self._source,
        terminal=self._terminal,issue=self._issue,storage_issue=self._storage_issue,pending_save=self._pending_save,
        stats=stats,layout_builds=self._layout_builds,closed_remaining=self._closed_remaining}
end
function Object:draw(d)
    if self._busy then return false,"busy" end
    self._busy=true
    local ok,accepted,detail=pcall(function()
        local size=d:size()
        local width,height=size.x,size.y
        if not finite(width) or not finite(height) or width<=0 or height<=0 then return false,"invalid_size" end
        if self._ops_view~=self._view or self._ops_width~=width or self._ops_height~=height then
            self._ops=Hud.layout(self._view,size)
            self._ops_view,self._ops_width,self._ops_height=self._view,width,height
            self._layout_builds+=1
        end
        return Hud.draw(d,self._ops)
    end)
    self._busy=false
    if not ok then return false,"draw_fault" end
    return accepted,detail
end
return freeze(Runtime)

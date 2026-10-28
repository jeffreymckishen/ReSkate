-- Pure normalization of bounded observations. No clocks, native calls or score
-- ownership: the caller owns its cursor, previous endpoint mode and Line.
local TrickRuntime = require("./trick_runtime")
local Feed = {}
local MAX = 9007199254740991
local modes = {rolling=true,airborne=true,manual=true,nose_manual=true,grinding=true,stalling=true,bailed=true}
local grinds = {double_peg=true,feeble=true,smith=true,icepick=true,toothpick=true,stall=true}
local deliberate = {["explicit Stop"]=true,["explicit menu stop"]=true,
    ["explicit board return; drain before stock input"]=true,stop=true,dismount=true}
local bails = {bail=true,bailed=true,loop_out=true,nose_over=true,tilt_stop=true,roll_stop=true}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function number(v,lo,hi) return finite(v) and v>=lo and v<=hi end
local function integer(v) return number(v,0,MAX) and v%1==0 end
local function reason(v,fallback) return type(v)=="string" and #v>0 and string.sub(v,1,160) or fallback end
local function is_bail(v)
    return bails[v]==true or type(v)=="string" and
        (string.match(v,"^measured tilt .+ over the %d+ deg Ride stop$")~=nil
        or string.match(v,"^measured roll rate .+ over the %d+ rad/s Ride stop$")~=nil)
end
local function terminal(why,outcome)
    why=reason(why,"score observation unavailable")
    return {terminal={reason=why,outcome=outcome or (is_bail(why) and "lost" or deliberate[why] and "banked" or "interrupted")}}
end
local function dense(rows,limit)
    if not plain(rows) then return nil end
    local n=0
    for k in pairs(rows) do n+=1;if n>limit or not integer(k) or k<1 or k>limit then return nil end end
    for i=1,n do if rawget(rows,i)==nil then return nil end end
    return n
end
local function context_copy(context)
    if context==nil then return {} end
    if not plain(context) or context.after_seconds~=nil and not number(context.after_seconds,0,MAX)
        or context.previous_mode~=nil and not modes[context.previous_mode]
        or context.generation~=nil and (not integer(context.generation) or context.generation==0) then return nil end
    return context
end
local function observation(seconds,h,speed,after)
    if not number(seconds,0,MAX) or not number(h,0,10) or h==0 or not number(speed,-1000,1000) then return "invalid_observation" end
    if after~=nil and seconds<=after then return "stale_observation" end
    if after~=nil and math.abs(seconds-after-h)>1e-6 then return "observation_gap" end
    return nil
end
local function air_event(raw)
    if raw==nil then return nil end
    if not plain(raw) then return nil,"invalid_trick_event" end
    -- Losing an air cannot earn its coincident landed credit, even if the
    -- producer's detail is malformed. Literal failure is the safe precedence.
    if raw.failed==true then return {failed=reason(raw.failure,"failed_trick")} end
    if raw.canceled==true then return nil,reason(raw.failure,"canceled_trick") end
    local projected=TrickRuntime.public_snapshot({valid=true,fresh=true,advanced=true,issue="none",model_events=raw})
    if not projected then return nil,"invalid_trick_event" end
    local e=projected.model_events
    if e.took_off and e.landed then return nil,"invalid_trick_event" end
    if e.landed then return {landed=e} end
    if e.took_off then return {took_off=true} end
    return nil
end
local function interrupted_feed(seconds,speed,mode,why,air)
    return {h=0,feed={seconds=seconds,speed=speed,mode=mode or "rolling",gap=true,
        interrupted=why,air=air and air.failed and air or nil}}
end
local function invalid_batch(batch,why,failed)
    batch.steps={terminal(failed or why,failed and "lost" or "interrupted")};batch.issue=why
    return batch
end

-- Each physical row uses its own measured time and duration. Terminal controls
-- have neither and use Line.finish instead. A log gap never partially credits.
function Feed.ride(log,after_n,context)
    local batch={steps={},issue="none",cursor=after_n}
    context=context_copy(context)
    if not context or not integer(after_n) or not plain(log) or not integer(log.generation)
        or not integer(log.n) or type(log.gap)~="boolean" then return invalid_batch(batch,"invalid_ride_log") end
    batch.generation=log.generation
    local count=dense(log.rows,8)
    if not count or log.n<after_n then return invalid_batch(batch,"invalid_ride_log") end
    if log.generation==0 then
        if log.n~=0 or count~=0 or log.gap then return invalid_batch(batch,"ride_log_unavailable") end
        batch.issue="idle";return batch
    end
    local gap=log.gap or count==0 and log.n~=after_n
    local previous_n,seconds,mode=after_n,context.after_seconds,context.previous_mode
    local latest,failed,last_terminal
    local function reject(why)
        -- A later malformed row cannot turn an already admitted bail into a
        -- retained interruption. Drop the whole batch and preserve its loss.
        return invalid_batch(batch,why,failed)
    end
    for i=1,count do
        local row=log.rows[i]
        if not plain(row) or not integer(row.n) or row.n<=previous_n or row.n>log.n then return reject("invalid_ride_row") end
        if row.n~=previous_n+1 then gap=true end
        previous_n=row.n
        if row.control~=nil then
            if row.control~="ended" or i~=count or type(row.reason)~="string" or #row.reason==0 or #row.reason>180
                or row.seconds~=nil or row.h~=nil or row.events~=nil or row.mode~=nil or row.speed~=nil then
                return reject("invalid_terminal_row")
            end
            last_terminal=terminal(row.reason)
            if last_terminal.terminal.outcome=="lost" then failed=last_terminal.terminal.reason end
            table.insert(batch.steps,last_terminal)
        else
            if not modes[row.mode] or type(row.landing_pending)~="boolean" then return reject("invalid_ride_row") end
            local why=observation(row.seconds,row.h,row.speed,seconds)
            if why=="invalid_observation" or why=="stale_observation" then return reject(why) end
            if why then gap=true end
            local air,refusal=air_event(row.events)
            local interrupted=row.interrupted~=nil and reason(row.interrupted,"invalid_trick_refusal") or refusal
            local feed={source="ride",seconds=row.seconds,speed=row.speed,mode=mode or row.mode,
                landing_pending=row.landing_pending,air=air,interrupted=interrupted}
            if air and air.failed or row.mode=="bailed" then
                feed.mode="bailed";failed=air and air.failed or "bailed"
            end
            table.insert(batch.steps,{h=row.h,feed=feed})
            seconds,mode=row.seconds,row.mode;latest=feed
        end
    end
    if previous_n~=log.n then return reject("incomplete_ride_log") end
    batch.cursor,batch.mode=log.n,mode
    if gap then
        batch.issue="feed_gap";batch.steps={}
        if last_terminal then
            batch.steps[1]=terminal(failed or "feed_gap",failed and "lost" or "interrupted")
        elseif latest then
            batch.steps[1]=interrupted_feed(latest.seconds,latest.speed,failed and "bailed" or mode,"feed_gap",
                failed and {failed=failed} or nil)
        else
            batch.steps[1]=terminal("feed_gap","interrupted")
        end
    end
    return batch
end

local function grind_kind(v) return (v=="peg_stall" or v=="tire_stall") and "stall" or grinds[v] and v or nil end
local function known_ground_bail(rows)
    local count=dense(rows,32)
    if not count then return nil,nil end
    for i=1,count do
        local wrapper=rows[i];local e=plain(wrapper) and wrapper.event
        if plain(e) and is_bail(e.reason) then
            if wrapper.name=="balance" and e.name=="ended" and (e.kind=="manual" or e.kind=="nose_manual") then
                return {event="ended",kind=e.kind,reason=reason(e.reason,"bail")},nil
            elseif wrapper.name=="grind" and e.name=="exit" and grind_kind(e.grind) then
                return nil,{event="exit",grind=grind_kind(e.grind),reason=reason(e.reason,"bail")}
            end
        end
    end
    return nil,nil
end
local function ground_events(rows,feed)
    local count=dense(rows,32)
    if not count then return "invalid_composer_events" end
    for i=1,count do
        local wrapper=rows[i]
        if not plain(wrapper) then return "invalid_composer_events" end
        if wrapper.name=="balance" then
            local e=wrapper.event
            if not plain(e) then return "invalid_balance_event" end
            if e.name=="balancing" or e.name=="ended" then
                if feed.manual or e.kind~="manual" and e.kind~="nose_manual" then return "invalid_balance_event" end
                feed.manual={event=e.name,kind=e.kind,reason=reason(e.reason,nil)}
            end
        elseif wrapper.name=="grind" then
            local e=wrapper.event
            if not plain(e) then return "invalid_grind_event" end
            if e.name=="lock_on" or e.name=="grind_changed" or e.name=="stalled" or e.name=="exit" then
                local kind=e.name=="stalled" and "stall" or grind_kind(e.name=="grind_changed" and e.to or e.grind)
                if feed.grind or not kind then return "invalid_grind_event" end
                feed.grind={event=e.name=="stalled" and "grind_changed" or e.name,grind=kind,reason=reason(e.reason,nil)}
            end
        end
    end
    return nil
end
function Feed.composer(sample,context)
    local batch={steps={},issue="none"}
    context=context_copy(context)
    if not context or not plain(sample) then return invalid_batch(batch,"invalid_composer_sample") end
    batch.generation=context.generation
    if sample.issue=="duplicate_read" then batch.issue="stale_observation";return batch end
    local why=observation(context.seconds,context.h,context.speed,context.after_seconds)
    if why=="stale_observation" then batch.issue=why;return batch end
    if why=="invalid_observation" then return invalid_batch(batch,why) end
    local d=plain(sample.diagnostics) and sample.diagnostics or {}
    local mode=sample.mode=="none" and "rolling" or sample.mode
    if mode=="grinding" and plain(d.grind) and d.grind.state=="stalled" then mode="stalling" end
    if not modes[mode] then return invalid_batch(batch,"invalid_composer_mode") end
    batch.mode=mode
    local feed={source="composer",seconds=context.seconds,speed=context.speed,mode=context.previous_mode or mode,
        gap=context.gap==true or why=="observation_gap" or context.after_seconds~=nil and d.consecutive==false,
        interrupted=context.interrupted~=nil and reason(context.interrupted,"invalid_interruption") or nil}
    if sample.valid~=true then feed.interrupted=reason(sample.issue,"composer_refused") end
    local trick=plain(d.trick) and d.trick or nil
    if trick then
        local air,refusal=air_event(trick.events);feed.air=air
        if refusal then feed.interrupted=refusal end
        feed.landing_pending=plain(trick.state) and trick.state.landing_pending==true or false
        if trick.valid~=true and (mode=="airborne" or context.previous_mode=="airborne") then
            feed.interrupted=reason(trick.issue,"trick_adapter_refused")
        end
    elseif mode=="airborne" or context.previous_mode=="airborne" then feed.interrupted="trick_adapter_unavailable" end
    local ground_rows=sample.events or {}
    local invalid=ground_events(ground_rows,feed)
    if invalid then
        -- An unrelated malformed wrapper cannot downgrade a recognized bail
        -- to a banked interruption. Preserve only its bounded failure fields.
        feed.manual,feed.grind=known_ground_bail(ground_rows);feed.interrupted=invalid
    end
    if (context.previous_mode=="manual" or context.previous_mode=="nose_manual") and plain(d.balance)
        and (d.balance.stepped==false or d.balance.issue=="support_unknown") then feed.interrupted="balance_observation_unavailable" end
    if (context.previous_mode=="grinding" or context.previous_mode=="stalling") and plain(d.grind)
        and d.grind.issue~=nil and d.grind.issue~="none" then feed.interrupted=reason(d.grind.issue,"grind_observation_unavailable") end
    if mode=="bailed" or feed.air and feed.air.failed then feed.mode="bailed" end
    batch.steps[1]={h=feed.gap and 0 or context.h,feed=feed}
    if feed.gap then batch.issue="feed_gap" end
    return batch
end
return table.freeze(Feed)

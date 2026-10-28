-- Exact persisted endpoints only. This view grants no completion/absence facts.
-- One preallocated heap index per original row; no expanded occurrence archive.
local Codec=require("./hop_evidence_codec")
local View={}
local Object={};Object.__index=Object
local states=setmetatable({}, {__mode="k"})
local function plain(value) return type(value)=="table" and getmetatable(value)==nil end
local function same_time(a,b)
    return a==b and (type(a)~="number" or a~=0 or 1/a==1/b)
end
local function integer(value,low,high)
    return type(value)=="number" and value==value and value%1==0 and value>=low and value<=high
end
local function immutable(value)
    if type(value)~="table" then return true end
    if not plain(value) or not table.isfrozen(value) then return false end
    for _,child in pairs(value) do if not immutable(child) then return false end end
    return true
end
local function endpoint(row,last)
    local out={row=row,call_id=last and row.last_call or row.first_call}
    local at=last and row.last_at_ms or row.first_at_ms
    -- Lua's and/or would replace an absent last timestamp with the first one.
    if last then at=row.last_at_ms end
    if at~=nil then out.at_ms=at end
    return table.freeze(out)
end
local function call_of(state,index)
    local row=state.rows[math.abs(index)]
    return index<0 and row.last_call or row.first_call
end
local function up(state,at)
    local heap=state.heap
    while at>1 do
        local parent=math.floor(at/2)
        if call_of(state,heap[parent])<=call_of(state,heap[at]) then break end
        heap[parent],heap[at]=heap[at],heap[parent];at=parent
    end
end
local function down(state,at)
    local heap=state.heap
    while at*2<=state.size do
        local child=at*2
        if child<state.size and call_of(state,heap[child+1])<call_of(state,heap[child]) then child+=1 end
        if call_of(state,heap[at])<=call_of(state,heap[child]) then break end
        heap[at],heap[child]=heap[child],heap[at];at=child
    end
end
local function open(rows)
    if not plain(rows) or not table.isfrozen(rows) then error("endpoint view: frozen plain row array required",0) end
    local n=#rows;local count=0
    if n>2176 then error("endpoint view: logical row cap",0) end
    for key in pairs(rows) do if not integer(key,1,n) then error("endpoint view: dense row array required",0) end;count+=1 end
    if count~=n then error("endpoint view: dense row array required",0) end
    local regular,critical=0,0
    for _,row in ipairs(rows) do
        if not plain(row) or not table.isfrozen(row) then error("endpoint view: frozen plain row required",0) end
        local size=Codec.state_bytes(row)
        -- Validate metadata/data directly, never re-encode a valid delta as a
        -- possibly larger standalone anchor or mutate/freeze caller tables.
        if not size or not immutable(row.data) then error("endpoint view: invalid immutable row",0) end
        if row.repeats==1 then
            if row.first_call~=row.last_call or not same_time(row.first_at_ms,row.last_at_ms) then error("endpoint view: inconsistent singleton",0) end
        elseif row.first_call>=row.last_call then error("endpoint view: inconsistent endpoints",0) end
        if row.critical then critical+=1 else regular+=1 end
        if regular>2048 or critical>128 then error("endpoint view: logical class cap",0) end
    end
    local self=setmetatable({},Object)
    local state={rows=rows,heap=table.create(n,0),size=0}
    -- table.create reserves exactly n live TValue slots; ordinary growth is not
    -- allowed to round a 2176-row reference heap into a larger occurrence index.
    for at=1,n do state.size=at;state.heap[at]=at;up(state,at) end
    states[self]=state
    return table.freeze(self)
end
function View.open(rows)
    local ok,value=pcall(open,rows)
    if not ok then return nil,type(value)=="string" and value or "endpoint view: invalid input" end
    return value
end
function Object:next()
    local state=states[self]
    if not state then return nil,"endpoint view: invalid cursor" end
    if state.fault then return nil,state.fault end
    if state.size==0 then return nil,nil end
    local index=state.heap[1];local row=state.rows[math.abs(index)]
    local call=call_of(state,index)
    if index>0 and row.first_call<row.last_call then state.heap[1]=-index
    else
        state.heap[1]=state.heap[state.size];state.heap[state.size]=nil;state.size-=1
    end
    if state.size>0 then down(state,1) end
    if state.size>0 and call_of(state,state.heap[1])==call then
        state.fault="endpoint view: duplicate known call"
        return nil,state.fault
    end
    return endpoint(row,index<0)
end
function Object:lookup(call)
    local state=states[self]
    if not state then return nil,"endpoint view: invalid cursor" end
    if state.fault then return nil,state.fault end
    if not integer(call,1,10000000) then return nil,"endpoint view: invalid call" end
    local found,last,interior=nil,false,false
    for _,row in ipairs(state.rows) do
        local first_match=row.first_call==call
        local last_match=row.last_call~=row.first_call and row.last_call==call
        if first_match or last_match then
            if found then state.fault="endpoint view: duplicate known call";return nil,state.fault end
            found,last=row,last_match
        elseif row.repeats>2 and call>row.first_call and call<row.last_call then interior=true end
    end
    if found then return endpoint(found,last) end
    return nil,interior and "UNKNOWN_INTERIOR" or "UNKNOWN"
end
return table.freeze(View)

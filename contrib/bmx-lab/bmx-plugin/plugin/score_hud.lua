-- Local score presentation only. The runtime owns snapshots, caching and timers.
-- Native overlay positions are pixels, while style sizes/thickness already scale
-- by display height / 1080 in plugin_overlay.cpp. Do not scale them a second time.
local HUD = { MAX_OPS=120, MAX_TEXT=500, RING_SEGMENTS=24 }
local empty = table.freeze({})
local styles = {
    panel=table.freeze({colour="#10151DE6",fill=true,rounding=8}),
    accent=table.freeze({colour="#BDFB77",fill=true}),
    header=table.freeze({colour="#FFFFFF",size=24,font="bold",shadow=true}),
    row=table.freeze({colour="#E0E5EB",size=18,font="body",shadow=true}),
    total=table.freeze({colour="#FFFFFF",size=32,font="bold",shadow=true}),
    multiplier=table.freeze({colour="#BDFB77",size=18,font="bold",shadow=true}),
    ring_on=table.freeze({colour="#BDFB77",thickness=3}),
    ring_off=table.freeze({colour="#46515E",thickness=3}),
    bank=table.freeze({colour="#BDFB77",size=36,font="bold",shadow=true}),
    best=table.freeze({colour="#BDFB77",size=18,font="bold",shadow=true}),
    lost=table.freeze({colour="#FF8C84",size=28,font="bold",shadow=true}),
    crossed=table.freeze({colour="#D6DCE4",size=36,font="bold",shadow=true}),
    strike=table.freeze({colour="#FF8C84",thickness=3}),
}
local allowed_styles = {}
for _, style in pairs(styles) do allowed_styles[style]=true end
table.freeze(styles)
table.freeze(allowed_styles)
local function plain(value) return type(value)=="table" and getmetatable(value)==nil end
local function finite(value)
    return type(value)=="number" and value==value and math.abs(value)<math.huge
end
local function bounded(value, low, high, fallback)
    return finite(value) and math.clamp(value,low,high) or fallback
end
local function amount(value)
    return string.format("%.0f",math.floor(bounded(value,0,9007199254740992,0)))
end
local function label(value, limit, fallback)
    if type(value)~="string" or value=="" then return fallback or "" end
    -- Bound the work before removing controls; all output is printable ASCII.
    local text=string.gsub(string.sub(value,1,limit+1),"[^ -~]","?")
    if #text>limit then text=string.sub(text,1,math.max(0,limit-3)).."..." end
    return text
end
local function dimensions(size)
    local x,y
    if type(size)=="vector" then x,y=size.x,size.y
    elseif plain(size) then x,y=rawget(size,"x"),rawget(size,"y") end
    if not finite(x) or not finite(y) or x<=0 or y<=0 or x>16384 or y>16384 then return nil end
    local scale=y/1080
    if x/scale<320 then return nil end
    return x,y,scale
end
function HUD.layout(view,size)
    if not plain(view) then return empty end
    local width,height,scale=dimensions(size)
    if not width then return empty end
    local airborne=rawget(view,"airborne")==true
    local active=rawget(view,"active")==true
    local manual_kind=rawget(view,"manual_kind")
    local manual_seconds=rawget(view,"manual_seconds")
    local manual=(manual_kind=="manual" or manual_kind=="nose_manual") and finite(manual_seconds)
        and manual_seconds>=0
    local closed=rawget(view,"closed")
    local closing=plain(closed) and bounded(rawget(view,"closed_remaining"),0,10,0)>0
        and (rawget(closed,"outcome")=="banked" or rawget(closed,"outcome")=="lost"
            or rawget(closed,"outcome")=="interrupted")
    if not active and not airborne and not manual and not closing then return empty end
    local ops,text_bytes={},0
    local function add(op)
        if #ops<HUD.MAX_OPS then table.insert(ops,table.freeze(op)) end
    end
    local function rect(x,y,x2,y2,style)
        add({kind="rect",x=x,y=y,x2=x2,y2=y2,style=style})
    end
    local function line(x,y,x2,y2,style)
        add({kind="line",x=x,y=y,x2=x2,y2=y2,style=style})
    end
    local function text(x,y,value,style)
        value=string.sub(value,1,HUD.MAX_TEXT-text_bytes)
        if value=="" then return end
        text_bytes+=#value
        add({kind="text",x=x,y=y,text=value,style=style})
    end
    local panel_width=math.min(620,width/scale-72)
    local left,bottom=36*scale,height-42*scale
    local right=left+panel_width*scale
    if closing and not active and not airborne and not manual then
        local top=bottom-132*scale
        rect(left,top,right,bottom,styles.panel)
        rect(left,top,left+4*scale,bottom,styles.accent)
        local outcome=rawget(closed,"outcome")
        if outcome=="lost" then
            text(left+20*scale,top+14*scale,"BAIL",styles.lost)
            local points=bounded(rawget(closed,"points"),0,9007199254740992,0)
            local multiplier=bounded(rawget(closed,"multiplier"),1,16,1)
            local lost_score=amount(math.min(9007199254740992,points*multiplier))
            text(left+20*scale,top+59*scale,lost_score,styles.crossed)
            local strike_width=math.min(panel_width-40,math.max(24,#lost_score*22))
            line(left+18*scale,top+80*scale,left+(20+strike_width)*scale,top+80*scale,styles.strike)
        else
            text(left+20*scale,top+20*scale,"LINE "..amount(rawget(closed,"score")),styles.bank)
            if outcome=="banked" and rawget(closed,"new_best")==true then
                text(left+20*scale,top+80*scale,"NEW BEST",styles.best)
            elseif outcome=="interrupted" then
                text(left+20*scale,top+80*scale,"INTERRUPTED",styles.row)
            end
        end
        return table.freeze(ops)
    end
    local top=bottom-276*scale
    rect(left,top,right,bottom,styles.panel)
    rect(left,top,left+4*scale,bottom,styles.accent)
    local header="BMX LINE"
    if airborne then
        header=label(rawget(view,"live_name"),math.min(44,math.floor((panel_width-40)/13)),"Bunny Hop")
    elseif manual then
        header=(manual_kind=="nose_manual" and "Nose Manual " or "Manual ")
            ..string.format("%.1fs",bounded(manual_seconds,0,10,0))
    end
    text(left+20*scale,top+16*scale,header,styles.header)
    local rows=rawget(view,"rows")
    if plain(rows) then
        for i=1,4 do
            local row=rawget(rows,i)
            if plain(row) then
                local landing=rawget(row,"landing")
                local suffix=" +"..amount(rawget(row,"points"))
                if landing=="Clean" or landing=="Sketchy" then suffix..=" "..landing end
                local limit=math.min(64,math.max(16,math.floor((panel_width-40)/9)))
                local name=label(rawget(row,"name"),math.max(6,limit-#suffix),"Trick")
                text(left+20*scale,top+(62+(i-1)*31)*scale,name..suffix,styles.row)
            end
        end
    end
    text(left+20*scale,bottom-63*scale,"LINE "..amount(rawget(view,"score")),styles.total)
    local multiplier=bounded(rawget(view,"multiplier"),1,16,1)
    text(right-126*scale,bottom-54*scale,string.format("x%.2f",multiplier),styles.multiplier)
    local total=bounded(rawget(view,"timer_total"),.01,60,2.5)
    local remaining=bounded(rawget(view,"remaining"),0,total,0)
    local fraction=remaining/total
    local cx,cy,radius=right-42*scale,bottom-43*scale,22*scale
    for i=1,HUD.RING_SEGMENTS do
        local a=-math.pi/2+(i-1)*2*math.pi/HUD.RING_SEGMENTS
        local b=a+2*math.pi/HUD.RING_SEGMENTS*.82
        line(cx+math.cos(a)*radius,cy+math.sin(a)*radius,
            cx+math.cos(b)*radius,cy+math.sin(b)*radius,
            i<=fraction*HUD.RING_SEGMENTS and styles.ring_on or styles.ring_off)
    end
    return table.freeze(ops)
end
local function coordinate(value)
    return finite(value) and math.abs(value)<=1000000
end
-- Frozen layout records cannot change after preflight when a draw method runs.
function HUD.draw(d,ops)
    if not plain(ops) or not table.isfrozen(ops) then return false,"invalid_ops" end
    local count,highest,text_bytes,needed=0,0,0,{}
    for key in next,ops do
        count+=1
        if count>HUD.MAX_OPS or not finite(key) or key%1~=0 or key<1 or key>HUD.MAX_OPS then
            return false,"invalid_ops"
        end
        highest=math.max(highest,key)
    end
    if highest~=count then return false,"invalid_ops" end
    -- Validate every op before any draw call; malformed later entries cannot
    -- leave a partially drawn HUD or reach arbitrary methods on d.
    for i=1,count do
        local op=rawget(ops,i)
        if not plain(op) or not table.isfrozen(op) then return false,"invalid_ops" end
        local kind=rawget(op,"kind")
        if (kind~="text" and kind~="line" and kind~="rect")
            or not coordinate(rawget(op,"x")) or not coordinate(rawget(op,"y"))
            or type(rawget(op,"style"))~="table" or not allowed_styles[rawget(op,"style")] then return false,"invalid_ops" end
        if kind=="text" then
            local value=rawget(op,"text")
            if type(value)~="string" or #value>HUD.MAX_TEXT or string.find(value,"[^ -~]") then
                return false,"invalid_ops"
            end
            text_bytes+=#value
            if text_bytes>HUD.MAX_TEXT then return false,"invalid_ops" end
        elseif not coordinate(rawget(op,"x2")) or not coordinate(rawget(op,"y2")) then
            return false,"invalid_ops"
        end
        needed[kind]=true
    end
    if count==0 then return true,0 end
    if type(d)~="table" then return false,"draw_unavailable" end
    local methods={}
    for kind in pairs(needed) do
        local method=rawget(d,kind)
        if type(method)~="function" then return false,"draw_unavailable" end
        methods[kind]=method
    end
    local drawn=0
    local ok=pcall(function()
        for i=1,count do
            local op=ops[i]
            local at=vector.create(op.x,op.y,0)
            if op.kind=="text" then methods.text(d,at,op.text,op.style)
            else methods[op.kind](d,at,vector.create(op.x2,op.y2,0),op.style) end
            drawn+=1
        end
    end)
    if not ok then return false,"draw_failed",drawn end
    return true,drawn
end
return table.freeze(HUD)

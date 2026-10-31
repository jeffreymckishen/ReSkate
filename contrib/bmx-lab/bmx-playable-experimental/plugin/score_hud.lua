-- Read-only authored score text. No SDK calls, timers, ledgers or game effects.
local HUD={MAX_LINES=6,MAX_TEXT=96}
local HEADER="MOD SCORE | UNCALIBRATED"
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function number(v,lo,hi,integer)
    return finite(v) and v>=lo and v<=hi and (not integer or v%1==0)
end
local function label(v,limit,fallback)
    if type(v)~="string" or v=="" then return fallback end
    -- Slice before sanitizing so malformed diagnostics cannot expand the work.
    return string.gsub(string.sub(v,1,limit),"[^ -~]","?")
end
local function fit(v,limit)
    if #v<=limit then return v end
    return string.sub(v,1,limit-3).."..."
end
local function lines(values)
    for i=1,HUD.MAX_LINES do values[i]=fit(values[i],HUD.MAX_TEXT) end
    return table.freeze(values)
end
local function unavailable(issue,phase)
    return lines({HEADER,"Scoring unavailable: "..label(issue,48,"unknown"),
        "Pending: unavailable","Observed-force candidate: unavailable",
        "Qualified local bank: unavailable",
        "Landing: "..label(phase,20,"unavailable").." | native score not used"})
end
local function valid(view)
    if not plain(view) or rawget(view,"scope")~="authored_mod_score_only"
        or rawget(view,"calibration")~="C0_UNRUN" or rawget(view,"native_score")~=false
        or type(rawget(view,"active"))~="boolean" or type(rawget(view,"stopped"))~="boolean" then return false end
    for _,key in {"pending_score","eligible_pending_score","banked_total","best_combo"} do
        if not number(rawget(view,key),0,999999999,true) then return false end
    end
    return number(rawget(view,"tricks"),0,16,true)
        and number(rawget(view,"multiplier"),1,4,false)
        and number(rawget(view,"combo_factor"),1,2,false)
        and plain(rawget(view,"rows"))
end
function HUD.lines(view,issue,landing_phase)
    -- An absent Ride is hidden. A real Ride with unavailable scoring is visible
    -- as unavailable, never as an invented zero-point or landed result.
    if view==nil and issue=="ride_unavailable" then return nil end
    if not valid(view) then return unavailable(issue or "unqualified view",landing_phase) end
    local names={}
    local rows=rawget(view,"rows")
    for i=1,4 do
        local row=rawget(rows,i)
        if row==nil then break end
        if not plain(row) then return unavailable("unqualified trick row",landing_phase) end
        names[#names+1]=label(rawget(row,"name"),20,"Trick")
    end
    local state="READY"
    if rawget(view,"stopped") then state="STOPPED: "..label(rawget(view,"issue"),30,"unknown")
    elseif rawget(view,"active") then state="PENDING"
    else
        local closed=rawget(view,"last_closed")
        if plain(closed) and rawget(closed,"authored")==true and rawget(closed,"native_score")==false
            and rawget(closed,"native_landing")==false then
            if rawget(closed,"outcome")=="landed" then state="LOCAL COMBO BANKED"
            elseif rawget(closed,"outcome")=="lost" then state="LOCAL COMBO LOST" end
        end
    end
    return lines({HEADER,
        string.format("Pending %.0f | %.0f tricks | x%.2f / combo x%.2f",
            view.pending_score,view.tricks,view.multiplier,view.combo_factor),
        "Tricks: "..(#names>0 and table.concat(names," + ") or "none"),
        string.format("Observed-force candidate %.0f | UNBANKED",view.eligible_pending_score),
        string.format("Qualified local bank %.0f | best %.0f",view.banked_total,view.best_combo),
        "Landing: "..label(landing_phase,20,"unavailable").." | "..state})
end
function HUD.fit(text,limit)
    if type(text)~="string" or not number(limit,16,HUD.MAX_TEXT,true) then return "" end
    return fit(label(text,HUD.MAX_TEXT,""),limit)
end
-- Positions are scaled by the hook. SDK style sizes already scale by screen
-- height in the overlay, so these font sizes must not be multiplied again.
HUD.header_style=table.freeze({colour="#BDFB77",size=20,font="bold",shadow=true})
HUD.row_style=table.freeze({colour="#FFFFFF",size=18,font="body",shadow=true})
return table.freeze(HUD)

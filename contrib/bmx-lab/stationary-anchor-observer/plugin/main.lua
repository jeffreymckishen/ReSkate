-- Candidate only. No body, Follow, pose, input-control or equipment operation.
local R=reskate
local KEY="stationary_anchor_measurement_v1"
local bones,model,blocked,loading=nil,nil,nil,1
local persist_attempted,persisted=false,false
local function one(fn,...)
    if type(fn)~="function" then error("required read API unavailable",0) end
    local r=table.pack(pcall(fn,...))
    if not r[1] or r.n~=2 then error("read API refused or returned an unknown shape",0) end
    return r[2]
end
local function point(v)
    if typeof(v)~="vector" then return nil end
    return {v.x,v.y,v.z}
end
local function facts()
    local f=one(R.input.focus)
    local m=one(R.menu.game)
    local p=one(R.skater.get)
    local t=one(R.skater.telemetry)
    local l=one(R.level.current)
    if type(f)~="table" or type(m)~="table" or type(p)~="table" or type(t)~="table" or
        type(t.watch)~="table" or type(l)~="table" then return nil end
    return {level=l.name,focused=f.focused,gameplay=f.gameplay,interface_open=f.interface_open,native_menu_open=m.open,
        skater=t.skater,watch_valid=t.watch.valid,state=t.watch.state,ragdoll_known=t.watch.ragdoll_known,
        ragdoll=t.watch.ragdoll,teleport_pending=t.teleport_pending,airborne=p.airborne,telemetry_airborne=t.airborne,
        position=point(p.position),telemetry_position=point(t.position),heading=p.heading,telemetry_heading=t.heading,
        speed=p.speed,vertical_speed=p.vertical_speed,telemetry_speed=t.speed,telemetry_vertical=t.vertical}
end
local function joint(id)
    local row=one(R.skater.joint,id)
    if type(row)~="table" then return row end
    return {parent=row.parent,position=point(row.position),rotation=row.rotation,scale=row.scale}
end
local function hand(side)
    local row=one(R.skater.hand,side)
    if type(row)~="table" then return row end
    return {position=point(row.position),rotation=row.rotation}
end
local function persist_terminal()
    if not model or persist_attempted then return end
    local dto=model:result();if not dto then return end
    persist_attempted=true
    local encoded=table.pack(pcall(R.json.encode,dto))
    if not encoded[1] or encoded.n~=2 or type(encoded[2])~="string" or #encoded[2]>24576 then
        blocked="Finite DTO export exceeded its 24KiB bound or encoding failed.";return
    end
    local saved=table.pack(pcall(R.storage.set,KEY,dto))
    persisted=saved[1]==true and saved.n==1
    if not persisted then blocked="Own storage cache write unknown; no retry." end
end
R.on("tick",function()
    if blocked then return end
    -- Two small cold imports in separate default-budget calls.
    if loading==1 then bones=require("./bones");loading=2;return end
    if loading==2 then
        local Sampler=require("./sampler")
        local existing=table.pack(pcall(R.storage.get,KEY))
        if not existing[1] or existing.n~=2 or existing[2]~=nil then blocked="Existing or unknown storage blocks this one-shot package.";return end
        model=Sampler.new({now=function()return one(R.time.now)end,facts=facts,joint=joint,hand=hand},bones)
        loading=3;return
    end
    model:step();persist_terminal()
end)
R.menu.page("Stationary Anchors",function(ui)
    ui:warn("Read-only stationary observations. No coherent pose, native owner or body-relative calibration.")
    ui:note("Remain upright on foot and still. The SDK overlay may stay open; keep the native game menu closed.")
    if blocked then ui:note(blocked);return end
    if not model then ui:note("Loading the two small sampler modules.");return end
    local s=model:status()
    ui:note(string.format("%s; %d/%d pose reads; %d finite joints",s.phase,s.pose_reads,s.limit,s.joints))
    if not s.used and ui:button("anchor_capture_once","Capture once") then model:request() end
    if s.used and not model:result() and ui:button("anchor_cancel","Cancel capture") then model:cancel();persist_terminal() end
    if s.issue then ui:note(s.issue) end
    if persisted then ui:note("Own storage cache accepted the bounded DTO; disk durability is not inferred.") end
end)
R.on("unload",function()
    if model then model:cancel();persist_terminal() end
end)

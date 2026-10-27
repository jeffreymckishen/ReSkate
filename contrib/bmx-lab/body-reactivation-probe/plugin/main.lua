-- Draft only. Deployment requires Root's exact ON-build/operator receipts.
local Probe=require("./probe")
local R=reskate
local ID="LuaBodyReactivation_20261027_q1"
local RUN="body-reactivation-20261027-q1" -- External expectation, not an environment attestation.
local KEY="body_reactivation_q1"
local P=R.world and R.world.physics
local original={world=R.world,physics=P,menu=R.menu,skater=R.skater,input=R.input,
    level=R.level,time=R.time,storage=R.storage,json=R.json}
local names={prepare=P and P.prepare,create=P and P.create,read=P and P.read,
    begin=P and P.begin_body_reactivation_probe,poll=P and P.poll_body_reactivation_probe,
    release=P and P.release,ray=R.world and R.world.probe,actor=R.skater and R.skater.get,
    telemetry=R.skater and R.skater.telemetry,focus=R.input and R.input.focus,
    game=R.menu and R.menu.game,level=R.level and R.level.current,now=R.time and R.time.now}
local function binding_ok()
    if reskate~=R or R.world~=original.world or R.world.physics~=P or R.menu~=original.menu
        or R.skater~=original.skater or R.input~=original.input or R.level~=original.level
        or R.time~=original.time or R.storage~=original.storage or R.json~=original.json then return false end
    if not P then return false end
    local current={prepare=P.prepare,create=P.create,read=P.read,begin=P.begin_body_reactivation_probe,
        poll=P.poll_body_reactivation_probe,release=P.release,ray=R.world.probe,actor=R.skater.get,
        telemetry=R.skater.telemetry,focus=R.input.focus,game=R.menu.game,level=R.level.current,now=R.time.now}
    for key in pairs({prepare=true,create=true,read=true,begin=true,poll=true,release=true,ray=true,
        actor=true,telemetry=true,focus=true,game=true,level=true,now=true}) do
        if type(names[key])~="function" or current[key]~=names[key] then return false end
    end
    return true
end
local function invoke(name,...)
    if not binding_ok() then error("API binding changed or qualification capability absent",0) end
    return names[name](...)
end
local function array(v)
    if typeof(v)~="vector" then return nil end
    return {v.x,v.y,v.z}
end
local function native(v) return vector.create(v[1],v[2],v[3]) end
local function normal(value,depth,count)
    depth=depth or 0;count=count or {n=0};count.n+=1
    if depth>12 or count.n>4096 then error("diagnostic normalization bound",0) end
    if typeof(value)=="vector" then return array(value) end
    local kind=type(value)
    if kind=="nil" or kind=="boolean" then return value end
    if kind=="number" then
        if value~=value or math.abs(value)==math.huge then error("nonfinite diagnostic",0) end
        return value
    end
    if kind=="string" then if #value>512 then error("diagnostic text bound",0) end;return value end
    if kind~="table" or getmetatable(value)~=nil then error("non-data diagnostic",0) end
    local out,n={},0
    for k,v in pairs(value) do
        n+=1
        if n>64 or (type(k)~="string" and type(k)~="number") then error("diagnostic table bound",0) end
        out[k]=normal(v,depth+1,count)
    end
    return out
end
local api={}
function api.now() return names.now() end
function api.capabilities() return binding_ok() end
function api.context()
    local level=invoke("level");local a=invoke("actor");local t=invoke("telemetry")
    local f=invoke("focus");local m=invoke("game")
    if type(level)~="table" or type(a)~="table" or type(t)~="table" or type(t.watch)~="table"
        or type(f)~="table" or type(m)~="table" then return nil end
    return {level=level.name,position=array(a.position),heading=a.heading,speed=a.speed,airborne=a.airborne,
        on_foot=t.skater==true and t.watch.valid==true and t.watch.state==504 and t.teleport_pending==false
            and t.slam==false and t.struck==false and t.airborne==false,
        focused=f.focused,gameplay=f.gameplay,interface_open=f.interface_open,menu_known=m.known,menu_open=m.open}
end
function api.ray(a,b) return normal(invoke("ray",native(a),native(b))) end
function api.prepare() return invoke("prepare") end
function api.create(d)
    return invoke("create",{mass=d.mass,inertia=native(d.inertia),position=native(d.position),rotation=d.rotation,
        capsules={{a=native(d.capsules[1].a),b=native(d.capsules[1].b),radius=d.capsules[1].radius}}})
end
function api.read(body)
    local s,why=invoke("read",body)
    if type(s)~="table" then return nil,why end
    -- The opaque epoch is intentionally excluded. The ordinary read's copied
    -- serial remains a decimal string; no diagnostic is submit authority.
    return {serial=s.serial,time=s.time,seconds=s.seconds,position=array(s.position),rotation=normal(s.rotation),
        velocity=array(s.velocity),angular_velocity=array(s.angular_velocity),mass=s.mass,inertia=array(s.inertia)}
end
function api.begin(body) return invoke("begin",body) end
function api.poll(probe)
    local result,why=invoke("poll",probe)
    if result==nil then return nil,why end
    return normal(result)
end
function api.release(body) return invoke("release",body) end
local trial=Probe.new(api)
local storage_error,blocked,last_write,last_phase,terminal_saved=nil,nil,-math.huge,nil,false
local prior_ok,prior=pcall(R.storage.get,KEY)
if not prior_ok or prior~=nil then blocked="Fresh namespace/store required; prior receipt is preserved" end
local function report(force)
    local snap=trial:snapshot()
    local ok,t=pcall(api.now)
    if not ok or type(t)~="number" then t=last_write end
    if not force and snap.phase==last_phase and t-last_write<1000 then return end
    if terminal_saved then return end
    snap.expected_plugin_id=ID;snap.expected_run_id=RUN
    snap.external_environment_and_process_pins_verified=false
    snap.source_basis="integrated 6fb77a09; source draft, execution UNRUN"
    if blocked then snap.preparation_block=blocked end
    local encoded,text=pcall(R.json.encode,snap)
    if not encoded or type(text)~="string" or #text>60000 then storage_error="Receipt serialization or size refused";return end
    local written,why=pcall(R.storage.set,KEY,snap) -- Successful API returns no values.
    if not written then storage_error="Storage acceptance failed: "..string.sub(tostring(why),1,120);return end
    last_write,last_phase=t,snap.phase;storage_error=nil
    terminal_saved=snap.terminal
end
R.menu.panel("Body reactivation: one cycle",function(ui)
    local s=trial:snapshot()
    ui:note("Private diagnostic. Root must approve the exact runtime/profile/package before deployment. Warm-up is not qualification.")
    ui:info("Phase",s.phase);ui:info("Reason",s.reason or "none")
    if blocked then ui:note(blocked);return end
    if s.phase=="idle" or s.phase=="prepare_pending" then
        if ui:button("brq_prepare","Prepare once; then close interface") then trial:prepare() end
    elseif s.phase=="prepared" then
        if ui:button("brq_survey","Measure candidate three metres ahead") then trial:survey() end
    elseif s.phase=="await_visual_approval" and s.candidate then
        local p=s.candidate.position
        ui:info("Candidate metres",string.format("X %.6f  Y %.6f  Z %.6f",p[1],p[2],p[3]))
        ui:note("Inspect the scene: candidate is three metres ahead, one metre above measured floor. Approve only an empty area with generous margins. Rays do not prove clear volume.")
        if ui:button("brq_approve","I visually approve this candidate; run once") then trial:approve(s.candidate.id) end
    end
    ui:note("After Prepare or Approve, close the interface and remain still on foot. No input is sent by this plugin.")
    if not s.terminal and ui:button("brq_stop","Stop admission; preserve pending cleanup") then trial:stop() end
    ui:info("Cleanup",s.cleanup)
    if s.operator_end_required then ui:note("Cleanup unconfirmed: preserve evidence; Root must end this exact isolated process. Do not retry.") end
    if storage_error then ui:note(storage_error) end
end)
R.on("tick",function()
    if blocked or trial:snapshot().phase=="idle" then return end
    local ok,why=pcall(function() trial:tick() end)
    if not ok then
        trial:unload() -- Marks uncertainty; never asserts cleanup from an exception.
        pcall(R.log,"Body reactivation draft exception: "..string.sub(tostring(why),1,180),"warn")
    end
    local saved,why_save=pcall(report,false)
    if not saved then storage_error="Receipt unavailable: "..string.sub(tostring(why_save),1,140) end
end)
R.on("unload",function()
    if blocked then return end
    pcall(function() trial:unload();report(true) end)
end)

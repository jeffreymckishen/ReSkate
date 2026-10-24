-- One owned context capsule and one passive local-actor synchronizer probe.
-- No target, pose, command, force, input, follow or recovery is published here.
local P, V = reskate.world.physics, vector.create
local ID, RUN, KEY = "LuaPassiveSyncProbe_20261024_v2", "a22f6ade-3380-41a0-99ed-45d3a5ed84ec", "passive_sync_native_v2"
local ARM_MS, BODY_MS, WATCH_MS = 120000, 3000, 1500
local phase, detail = "idle", "Arm explicitly, then close the menu."
local body, probe, origin, level_name, last_now, arm_at, body_at, probe_at, poll_at
local used, retry_available, retried, finished, release_sent = false, false, false, false, false
local report = {id=ID,run_id=RUN,scope="passive actor packets with an owned context capsule",
    calls={create=0,read=0,begin=0,poll=0,release=0,store=0},creates={},polls={},creation_unknown=false,
    native_consumed=false,follow_published=false,park_observed=false,submitted_commands=0}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function vec(v) return v and finite(v.x) and finite(v.y) and finite(v.z) end
local function xyz(v) return {v.x,v.y,v.z} end
local function clipped(s)
    local t=type(s)
    return string.sub((t=="string" or t=="number" or t=="boolean" or t=="nil") and tostring(s) or "<"..typeof(s)..">",1,240)
end
local function return_detail(r)
    if r[1] then return clipped(r[3]) end
    return clipped(r[2])
end
local function serial(s)
    return type(s)=="string" and #s>0 and #s<=20 and s:match("^[1-9][0-9]*$")~=nil
        and (#s<20 or s<="18446744073709551615")
end
local function clock()
    local ok,n=pcall(reskate.time.now)
    if not ok or not finite(n) or n<0 or (last_now and n<last_now) then return nil end
    last_now=n return n
end
local function epoch(e)
    if type(e)~="table" or not serial(e.serial) or not finite(e.time) or e.time<0
        or not finite(e.seconds) or math.abs(e.seconds-1/60)>1e-7 then return nil end
    return {serial=e.serial,time=e.time,seconds=e.seconds}
end
local function numbers(t,n)
    if type(t)~="table" or #t~=n then return nil end
    local out={} for i=1,n do if not finite(t[i]) then return nil end out[i]=t[i] end return out
end
local function sample(s)
    if type(s)~="table" or not epoch(s) or s.mass~=12 or not vec(s.position) or not vec(s.velocity)
        or not vec(s.angular_velocity) or not vec(s.inertia) or not numbers(s.rotation,4) then return nil end
    return {serial=s.serial,time=s.time,seconds=s.seconds,mass=s.mass,position=xyz(s.position),
        velocity=xyz(s.velocity),angular_velocity=xyz(s.angular_velocity),inertia=xyz(s.inertia),rotation=numbers(s.rotation,4)}
end
local function packed(r)
    if type(r)~="table" or not ({pending=true,observed=true,expired=true,invalidated=true})[r.status]
        or type(r.terminal)~="boolean" or r.terminal~=(r.status~="pending") or not epoch(r.armed_epoch)
        or type(r.records)~="table" or #r.records~=4 then return nil end
    local out={status=r.status,terminal=r.terminal,armed_epoch=epoch(r.armed_epoch),records={}}
    for _,name in {"observed_mask","rejected","dropped"} do
        local n=r[name] if not finite(n) or n<0 or n%1~=0 or n>4294967295 then return nil end out[name]=n
    end
    if r.observed_mask>15 then return nil end
    if type(r.routing)~="table" or type(r.routing.matches)~="table" then return nil end
    local routing={matches={}}
    for name in r.routing do
        if name~="entries" and name~="matches" and name~="other" and name~="already_recorded" and name~="expired_entries" then return nil end
    end
    for _,name in {"entries","other","already_recorded","expired_entries"} do
        local n=r.routing[name] if not finite(n) or n<0 or n%1~=0 or n>4294967295 then return nil end routing[name]=n
    end
    local count=0
    for i,n in r.routing.matches do
        if not finite(i) or i%1~=0 or i<1 or i>4 or not finite(n) or n<0 or n%1~=0 or n>4294967295 then return nil end
        routing.matches[i]=n count+=1
    end
    if count~=4 then return nil end
    -- Independent raw lower bounds: do not sum, order or infer native invocations.
    out.routing=routing
    if r.status=="observed" then out.observed_epoch=epoch(r.observed_epoch) if not out.observed_epoch then return nil end end
    local mismatches=0
    for i=1,4 do
        local a=r.records[i] if type(a)~="table" or type(a.present)~="boolean" then return nil end
        local b={present=a.present} out.records[i]=b
        if a.present then
            if type(a.pending_before)~="boolean" or type(a.pending_after)~="boolean" or type(a.transform_matches)~="boolean"
                or not finite(a.before_flags) or a.before_flags%1~=0 or a.before_flags<0 or a.before_flags>4294967295
                or not finite(a.after_flags) or a.after_flags%1~=0 or a.after_flags<0 or a.after_flags>4294967295
                or not numbers(a.supplied,16) or not vec(a.com_position) or not vec(a.origin) or not vec(a.local_com)
                or not numbers(a.rotation,4) or not numbers(a.local_rotation,4) or not epoch(a.epoch) then return nil end
            b.pending_before,b.pending_after,b.transform_matches=a.pending_before,a.pending_after,a.transform_matches
            b.before_flags,b.after_flags=a.before_flags,a.after_flags
            b.supplied,b.com_position,b.origin=numbers(a.supplied,16),xyz(a.com_position),xyz(a.origin)
            b.local_com,b.rotation,b.local_rotation,b.epoch=xyz(a.local_com),numbers(a.rotation,4),numbers(a.local_rotation,4),epoch(a.epoch)
            if not a.transform_matches then mismatches+=1 end
        end
    end
    out.mismatching_records=mismatches return out
end
local function persist()
    report.phase,report.detail=phase,detail
    local ok,encoded=pcall(reskate.json.encode,report)
    if not ok or type(encoded)~="string" or #encoded>62000 then detail="bounded ledger encoding failed" return false end
    report.calls.store+=1
    local saved,why=pcall(reskate.storage.set,KEY,report)
    if not saved then detail="storage cache refused: "..clipped(why) end
    return saved -- Zero return values from storage.set are successful acceptance, not disk durability.
end
local function finish(reason)
    if finished then return end finished=true retry_available=false
    report.stop_reason=clipped(reason)
    report.outcome=report.outcome or "stopped_without_terminal_probe"
    if body and not release_sent then
        release_sent=true report.calls.release+=1
        local r=table.pack(pcall(P.release,body))
        report.release={pcall_ok=r[1]==true,arity=r.n-1,accepted=r[1]==true and r[2]==true,
            detail=return_detail(r)}
        if report.release.accepted then body=nil end
    end
    report.body_handle_retained=body~=nil
    report.cleanup_unknown=report.creation_unknown or (report.release~=nil and not report.release.accepted)
    phase=report.cleanup_unknown and "cleanup unknown" or "stopped"
    detail=clipped(reason).."; release acceptance is not a parked witness."
    persist()
end
local function facts()
    local ok,f=pcall(reskate.input.focus)
    if not ok or type(f)~="table" or f.focused~=true or f.gameplay~=true then return nil,"focus/gameplay unavailable" end
    if f.interface_open~=false then return nil,"menu open" end
    local got,p=pcall(reskate.skater.get)
    local loaded,l=pcall(reskate.level.current)
    if not got or type(p)~="table" or not vec(p.position) or not finite(p.heading)
        or not loaded or type(l)~="table" or type(l.name)~="string" or #l.name==0 then return nil,"local actor/level unavailable" end
    if level_name and l.name~=level_name then return nil,"level changed" end
    if origin then
        local dx,dz=p.position.x-origin.x,p.position.z-origin.z
        if dx*dx+dz*dz<=2.25 then return nil,"actor entered 1.5m horizontal capsule clearance" end
    end
    return p,l.name
end
local function poll(now)
    if #report.polls>=16 then finish("bounded poll count reached") return end
    report.calls.poll+=1 poll_at=now
    local r=table.pack(pcall(P.poll_sync_probe,probe))
    if not r[1] or type(r[2])~="table" then
        report.poll_refusal={pcall_ok=r[1]==true,arity=r.n-1,detail=return_detail(r)}
        finish("probe poll refused or unknown") return
    end
    local copied=packed(r[2])
    if not copied then report.poll_refusal={detail="malformed copied probe facts"} finish("malformed probe result") return end
    report.last_probe=copied
    report.polls[#report.polls+1]={elapsed_ms=now-probe_at,status=copied.status,mask=copied.observed_mask,
        rejected=copied.rejected,dropped=copied.dropped,routing=copied.routing}
    if copied.terminal then
        report.terminal_probe=copied
        report.outcome=copied.status=="observed" and (copied.mismatching_records==0 and "observed_matches" or "observed_with_mismatch") or copied.status
        report.calls.read+=1 local s=table.pack(pcall(P.read,body))
        report.final_sample=s[1] and sample(s[2]) or nil
        report.final_read={pcall_ok=s[1]==true,arity=s.n-1,detail=return_detail(s)}
        finish("terminal passive observation: "..report.outcome)
    end
end
local function create_and_begin(now,p,name)
    level_name=name
    if not origin then origin=p.position+V(math.cos(p.heading)*2.5,1.0,-math.sin(p.heading)*2.5) end
    report.actor_before={position=xyz(p.position),heading=p.heading,level=name}
    report.definition={mass=12,inertia={.4,.1,.4},position=xyz(origin),rotation={0,0,0,1},
        capsules={{a={0,-.25,0},b={0,.25,0},radius=.12}}}
    report.calls.create+=1 report.creation_unknown=true
    local r=table.pack(pcall(P.create,{mass=12,inertia=V(.4,.1,.4),position=origin,rotation={0,0,0,1},
        capsules={{a=V(0,-.25,0),b=V(0,.25,0),radius=.12}}}))
    report.last_create={pcall_ok=r[1]==true,arity=r.n-1,value_type=typeof(r[2]),
        detail=return_detail(r)}
    report.creates[#report.creates+1]=report.last_create
    if r[1] and r[2]==nil and r[3]=="waiting for a fresh qualified 60 Hz physics step" then
        report.creation_unknown=false
        if retried then finish("second known preallocation refusal; no body allocated") return end
        retry_available=true phase="readiness wait"
        detail="No slot reserved. Use the separate explicit retry once; original arm deadline remains."
        persist() return
    end
    if not r[1] or typeof(r[2])~="userdata" then finish("body create refused or unknown; no automatic retry") return end
    body=r[2] report.creation_unknown=false body_at=now phase="observing"
    report.calls.read+=1 local measured=table.pack(pcall(P.read,body))
    report.initial_read={pcall_ok=measured[1]==true,arity=measured.n-1,value_type=typeof(measured[2]),
        detail=return_detail(measured)}
    report.initial_sample=measured[1] and sample(measured[2]) or nil
    if not report.initial_sample then finish("initial measured sample refused or malformed") return end
    report.calls.begin+=1 local b=table.pack(pcall(P.begin_sync_probe,body))
    report.begin={pcall_ok=b[1]==true,arity=b.n-1,value_type=typeof(b[2]),detail=return_detail(b)}
    if not b[1] or typeof(b[2])~="userdata" then finish("passive begin refused or unknown") return end
    probe=b[2] probe_at=now detail="One fixed SDK one-second request; no consumption inference."
    persist() poll(now)
end
local fresh,prior=pcall(reskate.storage.get,KEY)
if not fresh or prior~=nil then used,finished=true,true phase="existing storage" detail="Fresh storage required; no trial calls allowed." end
reskate.menu.page("Passive Sync Routes V2",function(ui)
    ui:warn("One 12kg context capsule; four passive actor-packet records. No follow or forces.")
    ui:note("Root must bind fresh process/package and archive storage. Neutral input is an external trial condition.")
    if ui:button("arm","Arm one passive probe") and not used then
        local now=clock() used=true
        if not now then finish("invalid arm clock") else arm_at=now phase="armed" detail="Close menu within 120 seconds." persist() end
    end
    if ui:button("retry","Retry readiness once") and retry_available and not finished then
        local now=clock()
        if not now or now-arm_at>=ARM_MS-BODY_MS then finish("retry clock/deadline refused")
        else retried=true retry_available=false phase="armed" detail="Close menu; explicit second preallocation attempt." persist() end
    end
    if ui:button("stop","Release / stop") and used and not finished then finish("explicit stop") end
    ui:info("Phase",phase) ui:info("Detail",string.sub(detail,1,200))
    ui:info("Probe polls",tostring(report.calls.poll)) ui:info("Outcome",tostring(report.outcome or "not observed"))
end)
reskate.on("tick",function()
    if not used or finished then return end
    local now=clock()
    if not now then finish("invalid or reversed fixture clock") return end
    if now-arm_at>=ARM_MS then finish("original arm watchdog") return end
    if phase=="readiness wait" then return end
    if body_at and now-body_at>=BODY_MS then finish("body watchdog") return end
    local p,name=facts()
    if not p then
        if phase=="armed" and name=="menu open" then return end
        finish(name) return
    end
    report.actor_after={position=xyz(p.position),heading=p.heading,level=name}
    if phase=="armed" then create_and_begin(now,p,name) return end
    if probe then
        if now-probe_at>=WATCH_MS then finish("probe delivery watchdog; SDK limit remains one second") return end
        if not poll_at or now-poll_at>=100 then poll(now) end
    end
end)
reskate.on("unload",function() if used and not finished then finish("plugin unload; SDK retains actual body duty") end end)

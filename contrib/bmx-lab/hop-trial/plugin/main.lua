-- Private P0/H1 runner. Reviewed staging freezes phase/config and copied source;
-- the shipped default remains closed. No key press or hop is generated here.
local modules={"./hop_config","./lease_identity","./catalog","./hop_guard","./hop_recorder",
    "./hop_context","./hop_services","./bike_admission","./bike_runtime"}
local loaded,index={},1
local bike,context,wrapped,config,recorder,Admission,guard
local prepared,failed,intent,attempted,stop_sent,unloaded=false,false,false,false,false,false
local evidence
local last,detail,intent_at,last_wait_clock=nil,"Preparing the private trial observer.",nil,nil
local startup_cancelled=false
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function config_valid(c)
    return type(c)=="table" and c.schema==1 and type(c.admission_enabled)=="boolean"
        and (c.phase=="P0" or c.phase=="H1") and type(c.run_id)=="string" and #c.run_id>0 and #c.run_id<=32 and c.run_id:match("^[A-Za-z0-9_-]+$")~=nil
        and c.source_commit=="062db162248d6b21c686f588924e0abc5954e99c" and c.slot==0 and c.ride_window_ms==1500
        and c.hop_strength==.25 and c.mass==106 and c.max_hop_attempts==1
        and type(c.caps)=="table" and c.caps.force==6000 and c.caps.speed==3
        and c.caps.torque==2000 and c.caps.vertical_speed==3
end
local function fail(reason)
    detail=reason
    if context then context:request_stop(reason) end
end
local function lookup(path)
    local value=wrapped
    for part in path:gmatch("[^.]+") do value=type(value)=="table" and value[part] or nil end
    return type(value)=="function" and value or nil
end
local function fresh_ready()
    local function call(_,fn,...) return table.pack(pcall(fn,...)) end
    local facts=Admission.facts(call,lookup)
    return Admission.ready(facts) and facts.interface_closed and facts.game_menu_closed and facts.input_allowed
        and finite(facts.wipeouts)
end
local function prepare()
    local name=modules[index]
    if name then
        local ok,value=pcall(require,name)
        if not ok then failed=true;detail="Trial module unavailable; no attempt was started.";return end
        loaded[name]=value;index+=1;return
    end
    -- A separate tick performs construction. No native body is created here.
    config=loaded["./hop_config"]
    if not config_valid(config) then failed=true;detail="Frozen trial configuration is invalid.";return end
    Admission=loaded["./bike_admission"]
    local Guard,Recorder=loaded["./hop_guard"],loaded["./hop_recorder"]
    local Context,Services=loaded["./hop_context"],loaded["./hop_services"]
    recorder=Recorder.new(reskate.storage.set,config.run_id)
    guard=Guard.new()
    context=Context.new(guard,recorder)
    Context.bind(context)
    wrapped=Services.wrap(reskate,context)
    context:configure(config)
    bike=loaded["./bike_runtime"].new(wrapped,{qualification_only=config.admission_enabled})
    prepared=true
    last=bike:status();evidence=recorder:status()
    detail=config.admission_enabled and "Ready for one explicit "..config.phase.." start."
        or "Admission is closed in this source package."
end
local function request_stop_once()
    if not bike or stop_sent then return end
    local state=context:status()
    if not state.stop_requested then return end
    stop_sent=true;intent=false
    local ok=bike and pcall(bike.request_stop,bike,state.reason or "Trial stopped")
    if not ok then detail="Ordinary Stop raised; cleanup ticks continue and uncertainty is retained." end
end
local function terminal_witness(snapshot)
    if type(snapshot)~="table" or not context:status().stop_requested then return false end
    if snapshot.phase=="done" and snapshot.bike_cleanup_complete==true then return true end
    if snapshot.stop_latched==true and snapshot.phase=="retained_unknown"
        and finite(snapshot.wall_ms) and finite(snapshot.stop_ms) and snapshot.wall_ms>=snapshot.stop_ms
        and snapshot.wall_ms-snapshot.stop_ms>=20000 then
        -- This is Core's pinned cleanup watchdog, not the 1500 ms driving
        -- window or 150 ms lease margin. Unresolved debt remains in evidence.
        return true
    end
    return snapshot.bike_authority==false and snapshot.cleanup_pending==false
        and snapshot.cleanup_unknown==false and snapshot.startup and snapshot.startup.pending==false
        and (snapshot.stop_latched==true or startup_cancelled)
end
local function record_status(snapshot,on_unload)
    last=snapshot
    context:after_step(snapshot)
    request_stop_once()
    if on_unload then
        -- Only an already drained, actually clean owner may save its changed
        -- final summary. The recorder refuses chunks and shares one unload I/O.
        local witnessed=terminal_witness(snapshot)
        local ok,accepted=pcall(context.finish_unload,context,snapshot,{inactive=witnessed,terminal=witnessed})
        if not ok or accepted~=true then detail="Final evidence incomplete; actual cleanup duty remains visible." end
    elseif terminal_witness(snapshot) then
        -- inactive means this trial can issue no new commands. It does not
        -- mean retained native debt was cleared or an allocation was retired.
        local ok,accepted=pcall(context.flush,context,{inactive=true,terminal=true})
        if not ok or accepted~=true then detail="Evidence flush unconfirmed; retained cleanup remains visible." end
    end
    local checked,current=pcall(recorder.status,recorder)
    if checked then evidence=current end
end
local function tick(dt_ms)
    if unloaded or failed then return end
    if not prepared then
        local ok=pcall(prepare)
        if not ok then failed=true;detail="Trial preparation raised; no mount request was made." end
        return
    end
    if intent and not attempted then
        local now=table.pack(pcall(wrapped.time.now))
        if not now[1] or now.n~=2 or not finite(now[2]) or now[2]<0
            or last_wait_clock and now[2]<last_wait_clock then
            intent=false;startup_cancelled=true;fail("Readiness clock unavailable; one-shot intent cancelled.")
        else
            last_wait_clock=now[2];intent_at=intent_at or now[2]
            if now[2]-intent_at>=60000 then
                intent=false;startup_cancelled=true;fail("Readiness window expired; no retry in this VM.")
            elseif fresh_ready() then
                -- The facade burns its VM attempt before callbacks. Never
                -- invoke it speculatively while a menu or readiness gate fails.
                attempted=true;intent=false
                local ok,accepted,why=pcall(bike.request_mount,bike,config.slot)
                detail=ok and accepted==true and "One mount request admitted; close menus and use only the reviewed controls."
                    or type(why)=="string" and why or "Mount request refused or raised; no retry."
                if not ok or accepted~=true then fail(detail) end
                record_status(bike:status())
                return
            end
        end
    end
    request_stop_once()
    -- Always continue Core cleanup after guard/recorder/pose failure. The
    -- facade alone controls cold imports and reports its handoff work tick.
    local ok,snapshot=pcall(bike.step,bike,dt_ms)
    if not ok then
        fail("Core step raised; cleanup duty retained.");request_stop_once()
        local known,value=pcall(bike.status,bike)
        if known then record_status(value) end
        return
    end
    record_status(snapshot)
end
-- This is an operator cue, not a current native observation, hop permission or
-- reproducible HID synchronization. Every value and string is cached on tick.
local overlay_title="BMX trial PREPARING / no automatic input"
local overlay_detail="Sampled window unknown / evidence cache pending / unqualified"
local overlay_style=table.freeze({colour="#FFFFFF",size=18,font="body",shadow=true})
local overlay_top=vector.create(24,40,0)
local overlay_bottom=vector.create(24,64,0)
local function cache_overlay()
    local state=context and context:status() or nil
    local guarded=guard and guard:status() or nil
    local consumed=guarded and finite(guarded.hop_attempts) and guarded.hop_attempts>0
    local remaining
    if last and last.clock_unknown~=true and finite(last.publish_ms) and last.publish_ms>=0 and last.publish_ms<=9007199254739491
        and finite(last.lease_until_ms) and last.lease_until_ms>=150 and last.lease_until_ms<=9007199254740991
        and finite(last.wall_ms) and last.wall_ms>=last.publish_ms and last.wall_ms<=9007199254740991 then
        remaining=math.floor(math.clamp(math.min(last.publish_ms+1500,last.lease_until_ms-150)-last.wall_ms,0,1500))
    end
    if failed then overlay_title="BMX trial STOP / preparation unavailable"
    elseif config and not config.admission_enabled then overlay_title="BMX trial CLOSED / no mount"
    elseif not prepared then overlay_title="BMX trial PREPARING / no automatic input"
    elseif state and state.stop_requested or last and last.stop_latched then
        overlay_title="BMX trial STOP/CLEANUP"
    elseif last and last.phase=="following" then
        if config.phase=="P0" then overlay_title="P0 FOLLOWING sampled / no hop"
        elseif consumed then overlay_title="H1 FOLLOWING sampled"
        elseif remaining==nil then overlay_title="H1 FOLLOWING sampled / deadline unknown; neutral"
        elseif remaining==0 then overlay_title="H1 FOLLOWING sampled / window expired; neutral"
        else overlay_title="H1 FOLLOWING sampled / await reviewed .25 gesture" end
    elseif attempted then overlay_title="BMX trial PREPARING / mount attempt consumed"
    elseif intent then overlay_title="BMX trial WAIT / close menus for readiness"
    else overlay_title="BMX trial READY / start once in menu" end
    if consumed then overlay_title..=" / attempt consumed / no retry" end
    local saved=evidence and evidence.flushed and "complete" or "pending"
    if evidence and (evidence.storage_fault or evidence.observation_loss) then saved="FAULT" end
    overlay_detail="Sampled window "..(remaining and tostring(remaining).." ms" or "unknown")
        .." / evidence cache "..saved.." / unqualified"
    -- Only fixed ASCII labels and a clamped integer enter these two strings.
    overlay_title=string.sub(overlay_title,1,90);overlay_detail=string.sub(overlay_detail,1,90)
end
reskate.on("tick",function(dt_ms)
    tick(dt_ms)
    if not unloaded then cache_overlay() end
end)
reskate.on("draw",function(d)
    if unloaded then return end
    d:text(overlay_top,overlay_title,overlay_style)
    d:text(overlay_bottom,overlay_detail,overlay_style)
end)
reskate.menu.page("Private BMX hop trial",function(ui)
    ui:note(detail)
    if not prepared then return end
    ui:note("Phase "..config.phase.." / run "..config.run_id..". One mount attempt; no automatic hop.")
    if config.admission_enabled and not attempted and not intent and not startup_cancelled and not context:status().stop_requested then
        if ui:button("hop-trial-start","Start "..config.phase.." once") then
            intent=true;detail="Start requested. Close menus; waiting for grounded stock readiness."
        end
    end
    if ui:button("hop-trial-stop","Stop trial") then
        startup_cancelled=true;intent=false;fail("Explicit trial Stop")
    end
    if last then ui:note("Lifecycle: "..tostring(last.phase)..". Cleanup continues after driving stops.") end
    if evidence then
        ui:note("Evidence host cache: "..(evidence.flushed and "complete" or "pending")..
            "; storage fault="..tostring(evidence.storage_fault).."; observation loss="..tostring(evidence.observation_loss)..
            "; unqualified="..tostring(evidence.unqualified)..". Disk durability is unobserved.")
    end
end)
reskate.on("unload",function()
    if unloaded then return end
    unloaded=true;intent=false
    if not bike then return end
    context:begin_unload()
    context:request_stop("Trial unload");stop_sent=true
    -- Unload is the facade's existing cleanup path, not an evidence shortcut.
    pcall(bike.unload,bike)
    local ok,snapshot=pcall(bike.status,bike)
    if ok and type(snapshot)=="table" then record_status(snapshot,true)
    else
        -- The recorder preserves its last actual snapshot and marks the final
        -- status unavailable; no invented cleanup-clear or terminal fields.
        pcall(context.interrupt,context,nil)
    end
end)

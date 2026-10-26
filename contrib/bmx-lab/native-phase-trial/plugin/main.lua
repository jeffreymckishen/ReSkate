-- Private native pipeline qualification; inert until an explicit page action.
-- This is one test capsule, not BMX gameplay, and never integrates a pose in Lua.
local P = reskate.world.physics
local TARGET, ARM_MS, BODY_MS = 120, 120000, 6000
local offsets = {-48, 48, 24, -24, 48, -48, 0}
local function command_force(index)
    return vector.create(0, 117.6 + offsets[(index-1) % #offsets + 1], 0)
end
local body, sample, origin, previous
local phase, detail = "idle", "Start explicitly, then close the menu."
local armed, used, retry_clock, flushed = false, false, false, false
local wall_ms, observed_at, submitted, acknowledged, repeats = 0, 0, 0, 0, 0
local records, pending, serial_conflict = {}, {}, nil
if reskate.storage.get("phase_native_v1") ~= nil then
    used, phase, detail = true, "previous trial", "Previous trial storage exists; archive it before another trial."
end
local function finite(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
local function vec(v) return v and finite(v.x) and finite(v.y) and finite(v.z) end
local function xyz(v) return {v.x, v.y, v.z} end
local function log(s) reskate.log("owned-phase-native-v1 " .. s) end
local function serial(s)
    return type(s) == "string" and #s > 0 and #s <= 20 and s:match("^[1-9][0-9]*$") ~= nil
end
local function next_serial(s)
    if not serial(s) then return nil end
    local result, carry = {}, 1
    for i = #s, 1, -1 do
        local n = string.byte(s, i) - 48 + carry
        if n == 10 then result[i], carry = "0", 1 else result[i], carry = string.char(48+n), 0 end
    end
    return (carry == 1 and "1" or "") .. table.concat(result)
end
local function valid(s)
    return s and serial(s.serial) and finite(s.time) and finite(s.seconds)
        and math.abs(s.seconds - 1/60) < 1e-7 and s.mass == 12
        and vec(s.position) and vec(s.velocity) and vec(s.angular_velocity)
        and vec(s.inertia) and type(s.rotation) == "table" and finite(s.rotation[1])
        and finite(s.rotation[2]) and finite(s.rotation[3]) and finite(s.rotation[4])
        and math.abs(s.rotation[1]^2+s.rotation[2]^2+s.rotation[3]^2+s.rotation[4]^2-1) < .001
end
local function copy_sample(s)
    return {serial=s.serial, time=s.time, seconds=s.seconds, mass=s.mass,
        position=xyz(s.position), velocity=xyz(s.velocity), angular_velocity=xyz(s.angular_velocity),
        inertia=xyz(s.inertia), rotation={s.rotation[1],s.rotation[2],s.rotation[3],s.rotation[4]}}
end
local function same_sample(a,b)
    if a.serial ~= b.serial or a.time ~= b.time or a.seconds ~= b.seconds or a.mass ~= b.mass then return false end
    for _, field in {"position","velocity","angular_velocity","inertia"} do
        if a[field].x ~= b[field].x or a[field].y ~= b[field].y or a[field].z ~= b[field].z then return false end
    end
    for i=1,4 do if a.rotation[i] ~= b.rotation[i] then return false end end
    return true
end
local function flush(reason, released, release_detail)
    if flushed then return end
    flushed = true
    -- Logs truncate at 2000 bytes. Keep the complete bounded ledger in the
    -- plugin's own 1 MiB storage; Host polls dirty storage every two seconds
    -- and also saves it on explicit plugin close.
    -- Queued storage is not a disk-persistence claim: root verifies the file.
    local summary = {reason=reason, submitted=submitted,
        acknowledged=acknowledged, repeated_observations=repeats,
        released=released, release_detail=release_detail or "retained parked slot; not destroyed",
        profile="seven_step_vertical_v1", offsets=offsets, base_force=117.6,
        serial_conflict=serial_conflict, last=sample and copy_sample(sample) or nil}
    local saved, why = pcall(reskate.storage.set, "phase_native_v1", {summary=summary, records=records})
    summary.storage_queued, summary.storage_detail = saved, tostring(why)
    -- Full conflicting pairs live only in storage, never in a capped log line.
    log("finish " .. reskate.json.encode({reason=reason, submitted=submitted,
        acknowledged=acknowledged, repeated_observations=repeats, released=released,
        profile=summary.profile, serial_conflict=serial_conflict ~= nil,
        last_serial=sample and sample.serial or nil, storage_queued=saved, storage_detail=tostring(why)}))
end
local function stop(reason)
    if phase == "previous trial" then return end -- Never overwrite an archived ledger from the UI.
    armed, used, retry_clock = false, true, false
    local ok, why = true, "no body allocated"
    if body then
        ok, why = P.release(body)
        -- Revocation can expire a queued packet. Preserve that final outcome as
        -- distinct from the last observation made while the body was active.
        for _, row in ipairs(pending) do
            local r, receipt_why = P.receipt(body, row.sequence)
            row.release_receipt = r and {outcome=r.outcome, produced_serial=r.produced_serial,
                retained=r.retained, quarantined=r.quarantined,
                successor=r.successor and copy_sample(r.successor) or nil} or nil
            row.release_receipt_detail = receipt_why
        end
        if ok then body = nil end -- A refused handle remains inspectable/releasable.
    end
    phase, detail = "stopped", reason .. "; release=" .. tostring(ok) .. "; " .. tostring(why or "parked and retained")
    flush(reason, ok, why)
end
local function check_receipts()
    -- Select every retained command, so a later failure cannot hide behind an older head.
    for _, row in ipairs(pending) do
        local r, why = P.receipt(body, row.sequence)
        if not r then stop("receipt unavailable: " .. tostring(why)); return false end
        row.outcome, row.produced_serial = r.outcome, r.produced_serial
        row.force_attempted, row.torque_attempted = r.force_attempted, r.torque_attempted
        row.retained, row.quarantined = r.retained, r.quarantined
        if r.sequence ~= row.sequence or r.requested_serial ~= row.before.serial
            or r.retained or r.quarantined then stop("receipt identity or owner failed"); return false end
        if r.outcome ~= "queued" and r.outcome ~= "applied" then
            stop("terminal command outcome " .. r.outcome .. "; no retry"); return false
        end
        if r.outcome == "applied" then
            if r.produced_serial ~= next_serial(row.before.serial)
                or not r.force_attempted or not r.torque_attempted then
                stop("producer skipped its exact next epoch or setters"); return false
            end
            if r.successor then
                if not valid(r.successor) or r.successor.serial ~= next_serial(r.produced_serial)
                    or math.abs(r.successor.time-row.before.time-2*row.before.seconds) > 1e-7 then
                    stop("first measured successor skipped an epoch or changed clock"); return false
                end
                row.successor = copy_sample(r.successor)
            end
        end
    end
    -- Release receipt slots only in order, after their independent measurement exists.
    while #pending > 0 and pending[1].successor do
        local row = pending[1]
        local ok, why = P.acknowledge(body, row.sequence)
        row.acknowledged, row.acknowledge_detail = ok, why
        if not ok then stop("ordered acknowledgement refused: " .. tostring(why)); return false end
        acknowledged = acknowledged + 1
        table.remove(pending, 1)
    end
    return true
end
reskate.menu.page("Owned Phase Trial", function(ui)
    ui:note("One 12 kg capsule; 120 measured steps; seven-step varying upward force, 69.6 to 165.6 N.")
    ui:note("No rider, camera or controller ownership. Marker is measured overlay, not a body mesh.")
    if (not used or retry_clock) and not body then
        if ui:button("start", retry_clock and "Retry after clock warmup" or "Start force timing trial", true) then
            armed, retry_clock, wall_ms = true, false, 0
            phase, detail = "armed", "Close menu within two minutes, with the game focused."
            log("armed; explicit page action")
        end
    end
    if ui:button("stop", "Release / stop") then
        if phase ~= "idle" then stop("explicit page action") end
    end
    ui:info("Phase", phase); ui:info("Status", detail)
    ui:info("Published / acknowledged", tostring(submitted) .. " / " .. tostring(acknowledged))
    ui:info("Repeated observations", tostring(repeats))
    if sample then
        ui:info("Last measured serial", sample.serial)
        ui:info("Measured Y / velocity Y", string.format("%.9g / %.9g", sample.position.y, sample.velocity.y))
    end
end)
reskate.on("tick", function(dt_ms)
    if phase == "stopped" or (not armed and not body) then return end
    if not finite(dt_ms) or dt_ms < 0 then stop("invalid wall clock"); return end
    wall_ms = wall_ms + dt_ms
    if wall_ms > (body and BODY_MS or ARM_MS) then stop(body and "six-second body watchdog" or "two-minute arming watchdog"); return end
    local focus = reskate.input.focus()
    if not focus or not focus.focused or not focus.gameplay or focus.interface_open then
        if body then stop("focus, gameplay or interface ownership changed") end
        return
    end
    if armed then
        armed, used, wall_ms = false, true, 0
        local player = reskate.skater.get()
        if not player or not vec(player.position) or not finite(player.heading) then stop("no finite local player placement"); return end
        origin = player.position + vector.create(math.cos(player.heading)*2, 1.5, -math.sin(player.heading)*2)
        local why
        body, why = P.create({mass=12, inertia=vector.create(.4,.1,.4), position=origin,
            rotation={0,0,0,1}, capsules={{a=vector.create(0,-.25,0),b=vector.create(0,.25,0),radius=.12}}})
        log("create accepted=" .. tostring(body ~= nil) .. " detail=" .. tostring(why or "owned opaque handle"))
        if not body then
            retry_clock = why == "body_preallocation_unavailable"
            phase, detail = "refused", tostring(why or "no body returned")
            return -- Only this preallocation clock refusal offers an explicit retry.
        end
        phase, detail = "waiting sample", "No command until first measured placement and clock qualify."
    end
    -- Receipt inspection can itself obtain a native sample. Drain first, then
    -- take the fresh observation used for this publication as late as possible.
    if not check_receipts() then return end
    if acknowledged == TARGET then stop("completed 120 consecutive publications and measured acknowledgements"); return end
    local current, why = P.read(body)
    if not current then
        if phase == "waiting sample" then detail = tostring(why); return end
        stop("active sample unavailable: " .. tostring(why)); return
    end
    if not valid(current) then stop("invalid native sample or calibrated step changed"); return end
    sample, observed_at = current, wall_ms
    local offset = current.position - origin
    if offset.x^2 + offset.y^2 + offset.z^2 > (previous and 3^2 or .35^2)
        or current.velocity.x^2 + current.velocity.y^2 + current.velocity.z^2 > 5^2 then
        stop("measured placement or speed left bounded trial"); return
    end
    if previous and current.serial == previous.serial then
        repeats = repeats + 1
        if not same_sample(previous,current) then
            serial_conflict = {source="repeated P.read", first=copy_sample(previous), later=copy_sample(current)}
            stop("native state changed inside one listener serial; no serial-only phase admission")
        end
        return
    end
    if previous and (current.serial ~= next_serial(previous.serial)
        or math.abs(current.time-previous.time-previous.seconds) > 1e-7) then
        stop("client observation skipped or reversed a native step; no catch-up or retry"); return
    end
    previous = current
    if submitted < TARGET then
        local force = command_force(submitted+1)
        local ok, refusal, sequence = P.submit(body, current.epoch, {force=force})
        local row = {index=submitted+1, force=xyz(force), before=copy_sample(current), accepted=ok, refusal=refusal, sequence=sequence}
        records[#records+1] = row
        if not ok or not serial(sequence) then stop("publication refused: " .. tostring(refusal)); return end
        submitted = submitted + 1
        pending[#pending+1] = row
        phase, detail = "running", "Publishing only from fresh consecutive measured samples."
    else phase, detail = "draining", "All 120 published; waiting for exact measured successors and ordered acknowledgement." end
end)
reskate.on("draw", function(d)
    if phase == "stopped" or not body or not sample or wall_ms-observed_at > 250 then return end
    local p, style = sample.position, {colour="#40FFD0FF",thickness=3}
    d:world_line(p-vector.create(.2,0,0),p+vector.create(.2,0,0),style)
    d:world_line(p-vector.create(0,.35,0),p+vector.create(0,.35,0),style)
    d:world_text(p+vector.create(0,.5,0),"Measured force timing: " .. submitted .. "/120",{colour="#40FFD0FF",size=16})
end)
reskate.on("unload", function() if body or armed then stop("plugin unload") end end)

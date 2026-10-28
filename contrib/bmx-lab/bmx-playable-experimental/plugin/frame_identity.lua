-- Pure structural checks and continuity facts, never native/effect authority.
-- Native userdata types cannot be authenticated by Lua. The actual owners and
-- current Source guard remain mandatory. Epoch userdata is a per-read token.
local Identity = require("./lease_identity")
local Frame = {}
local MAX_SAFE = 9007199254740991
local source_u64 = { "sequence", "source_epoch", "context_generation", "observation_serial", "observed_ms" }
local body_arrays = { "inertia_body", "orientation", "center_of_mass", "linear_velocity", "angular_velocity" }
local sample_vectors = { "position", "velocity", "angular_velocity", "inertia" }

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end
local function integer(value, lo, hi)
    return finite(value) and value >= lo and value <= hi and math.floor(value) == value
end
local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end
local function frozen(value) return table.freeze(value) end
local function same_number(a, b)
    return a == b and (a ~= 0 or 1 / a == 1 / b)
end
local function array(value, count)
    if not plain(value) then return nil end
    local out = {}
    for i = 1, count do
        local n = rawget(value, i)
        if not finite(n) then return nil end
        out[i] = n
    end
    return frozen(out)
end
local function vector(value)
    local native_vector = type(value) == "vector"
    if not native_vector and not plain(value) then return nil end
    local out = {}
    for _, axis in ipairs({ "x", "y", "z" }) do
        local n
        if native_vector then n = value[axis] else n = rawget(value, axis) end
        if not finite(n) then return nil end
        out[axis] = n
    end
    return frozen(out)
end
local function array_equal(a, b, count)
    for i = 1, count do if not same_number(a[i], b[i]) then return false end end
    return true
end
local function vector_array_equal(v, a)
    return same_number(v.x, a[1]) and same_number(v.y, a[2]) and same_number(v.z, a[3])
end
local function sample_copy(raw)
    if not plain(raw) or type(rawget(raw, "epoch")) ~= "userdata"
        or not Identity.is_nonzero_u64(rawget(raw, "serial"))
        or not finite(rawget(raw, "time")) or raw.time < 0
        or not finite(rawget(raw, "seconds")) or raw.seconds <= 0 or raw.seconds > .1
        or not finite(rawget(raw, "mass")) or raw.mass <= 0 then return nil end
    local out = { epoch = raw.epoch, serial = raw.serial, time = raw.time, seconds = raw.seconds, mass = raw.mass }
    for _, name in ipairs(sample_vectors) do
        out[name] = vector(rawget(raw, name))
        if not out[name] then return nil end
    end
    if out.inertia.x <= 0 or out.inertia.y <= 0 or out.inertia.z <= 0 then return nil end
    out.rotation = array(rawget(raw, "rotation"), 4)
    if not out.rotation then return nil end
    local norm = 0
    for i = 1, 4 do norm = norm + out.rotation[i] * out.rotation[i] end
    if not finite(norm) or math.abs(norm - 1) > .0001 then return nil end
    return frozen(out)
end
local function body_copy(raw, sample)
    if not plain(raw) or not same_number(rawget(raw, "mass"), sample.mass) then return nil end
    local out = { mass = sample.mass }
    for _, name in ipairs(body_arrays) do
        out[name] = array(rawget(raw, name), name == "orientation" and 4 or 3)
        if not out[name] then return nil end
    end
    if not vector_array_equal(sample.inertia, out.inertia_body)
        or not vector_array_equal(sample.position, out.center_of_mass)
        or not vector_array_equal(sample.velocity, out.linear_velocity)
        or not vector_array_equal(sample.angular_velocity, out.angular_velocity)
        or not array_equal(sample.rotation, out.orientation, 4) then return nil end
    return frozen(out)
end
local function source_copy(raw)
    if not plain(raw) or type(rawget(raw, "lease_handle")) ~= "userdata"
        or not integer(rawget(raw, "generation"), 0, MAX_SAFE)
        or not integer(rawget(raw, "user"), 0, 3)
        or not integer(rawget(raw, "packet"), 0, 4294967295) then return nil end
    local out = { lease_handle = raw.lease_handle, generation = raw.generation, user = raw.user, packet = raw.packet }
    for _, name in ipairs(source_u64) do
        local value = rawget(raw, name)
        local valid = name == "observed_ms" and Identity.is_u64(value) or Identity.is_nonzero_u64(value)
        if not valid then return nil end
        out[name] = value
    end
    return frozen(out)
end

function Frame.copy(raw)
    if not plain(raw) or rawget(raw, "valid") ~= true or type(rawget(raw, "fresh")) ~= "boolean"
        or type(rawget(raw, "body_handle")) ~= "userdata"
        or type(rawget(raw, "physics_epoch")) ~= "userdata" then return nil, "invalid_frame" end
    local sample = sample_copy(rawget(raw, "sample"))
    if not sample then return nil, "invalid_sample" end
    if not rawequal(raw.physics_epoch, sample.epoch) or rawget(raw, "serial") ~= sample.serial
        or not same_number(rawget(raw, "time"), sample.time)
        or not same_number(rawget(raw, "seconds"), sample.seconds) then return nil, "sample_alias_mismatch" end
    local body = body_copy(rawget(raw, "body"), sample)
    if not body then return nil, "body_alias_mismatch" end
    local source = source_copy(rawget(raw, "source"))
    if not source then return nil, "invalid_source" end
    local owner = rawget(raw, "owner")
    if not plain(owner) or not rawequal(rawget(owner, "body_handle"), raw.body_handle)
        or not rawequal(rawget(owner, "lease_handle"), source.lease_handle) then return nil, "owner_alias_mismatch" end
    local gates = rawget(raw, "gates")
    if not plain(gates) or type(rawget(gates, "focused")) ~= "boolean"
        or type(rawget(gates, "menu_open")) ~= "boolean" then return nil, "invalid_gates" end
    -- Project only the contract's specified fields; unknown extras (including
    -- cycles/functions/userdata) are never traversed, invoked or serialized.
    -- Optional bail_state/fall_generation have no agreed type/meaning here and
    -- are omitted. The real owner must validate them before using their facts.
    return frozen({ valid = true, fresh = raw.fresh, body_handle = raw.body_handle,
        physics_epoch = sample.epoch, serial = sample.serial, time = sample.time, seconds = sample.seconds,
        body = body, sample = sample, source = source,
        owner = frozen({ body_handle = raw.body_handle, lease_handle = source.lease_handle }),
        gates = frozen({ focused = gates.focused, menu_open = gates.menu_open }) })
end
Frame.validate = Frame.copy

function Frame.wall_time(now_ms, previous_now_ms)
    if not finite(now_ms) or now_ms < 0 or now_ms > MAX_SAFE then return false, "invalid_wall_time" end
    if previous_now_ms ~= nil then
        if not finite(previous_now_ms) or previous_now_ms < 0 or previous_now_ms > MAX_SAFE then
            return false, "invalid_previous_wall_time"
        end
        if now_ms < previous_now_ms then return false, "wall_time_regressed" end
    end
    return true
end
local function same_source(a, b)
    return rawequal(a.lease_handle, b.lease_handle) and a.generation == b.generation and a.user == b.user
        and a.sequence == b.sequence and a.source_epoch == b.source_epoch and a.context_generation == b.context_generation
end
local function same_measurement(a, b)
    if a.serial ~= b.serial or not same_number(a.time, b.time) or not same_number(a.seconds, b.seconds)
        or not same_number(a.body.mass, b.body.mass) then return false end
    for _, name in ipairs(body_arrays) do
        if not array_equal(a.body[name], b.body[name], name == "orientation" and 4 or 3) then return false end
    end
    return true
end
local function verdict(kind, source_kind, reason, elapsed, delta)
    return frozen({ kind = kind, source_kind = source_kind, reason = reason,
        physical_elapsed = elapsed, serial_delta = delta })
end

function Frame.classify(previous_raw, current_raw)
    local current, why = Frame.copy(current_raw)
    if not current then return verdict("invalid", "invalid", why) end
    if previous_raw == nil then return verdict("prime", "first", "first_frame") end
    local previous, old_why = Frame.copy(previous_raw)
    if not previous then return verdict("invalid", "invalid", "invalid_previous_" .. old_why) end
    if not rawequal(previous.body_handle, current.body_handle) or not same_source(previous.source, current.source) then
        return verdict("changed", "changed", "body_or_source_identity_changed")
    end
    local serial = Identity.compare(current.source.observation_serial, previous.source.observation_serial)
    local ms = Identity.compare(current.source.observed_ms, previous.source.observed_ms)
    if serial < 0 or ms < 0 then return verdict("invalid", "invalid", "source_observation_regressed") end
    if serial == 0 and (ms ~= 0 or current.source.packet ~= previous.source.packet) then
        return verdict("invalid", "invalid", "source_duplicate_changed")
    end
    local source_kind = serial == 0 and "repeat" or "advanced"
    if current.gates.focused ~= previous.gates.focused or current.gates.menu_open ~= previous.gates.menu_open then
        return verdict("changed", source_kind, "gate_facts_changed")
    end
    local order = Identity.compare(current.serial, previous.serial)
    if order < 0 then return verdict("invalid", source_kind, "body_serial_regressed") end
    if order == 0 then
        if not same_measurement(previous, current) then return verdict("invalid", source_kind, "body_duplicate_changed") end
        -- New read credentials on the identical measurement are normal.
        return verdict("duplicate", source_kind, "unchanged_body_measurement", 0, 0)
    end
    if rawequal(previous.physics_epoch, current.physics_epoch) then
        return verdict("invalid", source_kind, "read_credential_relabelled")
    end
    local elapsed = current.time - previous.time
    if not finite(elapsed) or elapsed <= 0 then return verdict("invalid", source_kind, "physical_time_regressed") end
    if not same_number(current.seconds, previous.seconds) then
        return verdict("invalid", source_kind, "physical_step_changed")
    end
    local delta = Identity.bounded_delta(current.serial, previous.serial, 1)
    if delta ~= 1 then return verdict("gap", source_kind, "body_serial_gap", elapsed) end
    -- This checks the sealed boundary's one-step policy, not an SDK proof that
    -- serials count physics steps. Keep current step and elapsed separately.
    if math.abs(elapsed - current.seconds) > 1e-6 then
        return verdict("invalid", source_kind, "physical_elapsed_mismatch", elapsed, delta)
    end
    if not current.fresh then return verdict("not_fresh", source_kind, "owner_did_not_mark_fresh", elapsed, delta) end
    return verdict("successor", source_kind, "coherent_measured_successor", elapsed, delta)
end

function Frame.public_snapshot(raw)
    local value, why = Frame.copy(raw)
    if not value then return nil, why end
    local source = { generation = value.source.generation, user = value.source.user, packet = value.source.packet }
    for _, name in ipairs(source_u64) do source[name] = value.source[name] end
    local body = { mass = value.body.mass }
    for _, name in ipairs(body_arrays) do
        local out = {}
        for i = 1, name == "orientation" and 4 or 3 do out[i] = value.body[name][i] end
        body[name] = frozen(out)
    end
    -- No handles/epochs, token strings, hashes or source/body identity claims.
    return frozen({ valid = true, fresh = value.fresh, serial = value.serial, time = value.time,
        seconds = value.seconds, body = frozen(body), source = frozen(source),
        gates = frozen({ focused = value.gates.focused, menu_open = value.gates.menu_open }) })
end

return frozen(Frame)

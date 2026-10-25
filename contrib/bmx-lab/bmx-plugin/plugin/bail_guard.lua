-- Guard-sphere ray plans for bail_policy and the decoding of their rows.
-- Pure arithmetic: it never queries, never steps the policy and never asks
-- for a fall. A missing, unavailable or unmeasured ray never becomes clear;
-- it makes the whole guard sample unavailable, as impact_contacts does in
-- Extension/BMX/bmx_chassis_ride.cpp when body_guard::search is unavailable.
--
-- The eight guard spheres are those of Extension/BMX/bmx_collision_envelope.h
-- ("env:N"), built from bike_geometry.capsules. Each guard is inspected along
-- the directions of Extension/BMX/bmx_body_guard.h ("guard:N"): world down,
-- the incoming movement direction, and the swept center path.
--
-- It takes two probe batches, because the C++ aims its witness ray along a
-- normal it has only just measured (guard:66-74). Guard.plan gives the
-- inspection rays. Guard.witness reads that batch and gives one witness ray
-- along each measured normal through the guard center, from radius + .16 in
-- front of it to radius + .06 behind it. Guard.decode reads both. A contact
-- that is not a crossing counts only when its witness hits within 2.5 mm of
-- the measured plane, so a finite lip's plane cannot become contact beyond its
-- edge. Oblique faces are found down to the .3 alignment gate, as in the C++.
-- The probe's measured hit normal stands in for the C++ five-ray patch fit
-- (guard:47-56). A crossing needs no extra ray: its swept ray is the same
-- historical segment that the C++ crossing witness casts (guard:71-72).
--
-- Both batches must be raw probe_batch results: only the raw fields, Luau
-- vectors in their rows, a read epoch, and both returned exclusion facts true.
-- A Contact.decode copy or public snapshot is refused. Every plan is bound to
-- the Ride Framev1 of its read (query_frame), and a frame without one has no
-- plan: a caller's own epoch check cannot stand in for it, because only the
-- frame lets the guard run the real Contact.decode. Both batches must carry
-- that frame's exact physics epoch and pass Contact.decode, with valid cast
-- accounting, no reason on an available batch and measured surface motion.
local Geometry = require("./bike_geometry")
local Frame = require("./frame_identity")
local Contact = require("./contact_runtime")
local Guard = {}
local MAX_RAYS = 32 -- contact_runtime.lua MAX_RAYS, the probe_batch limit
local MAX_SAFE = 9007199254740991
local MAX_U64 = "18446744073709551615"
local issued = setmetatable({}, {__mode = "k"}) -- plan -> private geometry
local pending = setmetatable({}, {__mode = "k"}) -- witness plan -> first-batch candidates
local decoded_by = setmetatable({}, {__mode = "k"}) -- decode -> plan
-- The raw probe_batch fields and hit-row fields (contact_runtime.lua
-- batch_fields and hit_fields). A decoded copy has others.
local raw_batch = table.freeze({status = true, reason = true, native_casts = true, budget_exhausted = true,
    epoch = true, local_actor_excluded = true, owned_bodies_excluded = true, rays = true, requested_query_preset = true})
local raw_hit = table.freeze({status = true, position = true, fraction = true, motion = true, normal_available = true,
    surface_velocity_available = true, normal = true, surface_velocity = true, body = true})

local function plain(v) return type(v) == "table" and getmetatable(v) == nil end
local function only(t, allowed)
    for key in pairs(t) do if not allowed[key] then return false end end
    return true
end
local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function add(a, b) return {a[1]+b[1], a[2]+b[2], a[3]+b[3]} end
local function sub(a, b) return {a[1]-b[1], a[2]-b[2], a[3]-b[3]} end
local function mul(a, s) return {a[1]*s, a[2]*s, a[3]*s} end
local function dot(a, b) return a[1]*b[1] + a[2]*b[2] + a[3]*b[3] end
local function cross(a, b) return {a[2]*b[3]-a[3]*b[2], a[3]*b[1]-a[1]*b[3], a[1]*b[2]-a[2]*b[1]} end
-- The force_math.lua quaternion convention: {x, y, z, w}.
local function turn(q, v)
    local axis = {q[1], q[2], q[3]}
    local twice = mul(cross(axis, v), 2)
    return add(v, add(mul(twice, q[4]), cross(axis, twice)))
end
local function unit(v) -- wheel_surface::detail::unit: refuse a near-zero direction
    local square = dot(v, v)
    if not finite(square) or square < 1e-12 then return nil end
    return mul(v, 1/math.sqrt(square))
end
local function frozen(v) return table.freeze({v[1], v[2], v[3]}) end
-- Accepts a Luau vector or a 3-array. Probe rows must use vectors (raw_vec).
local function read_vec(v, bound)
    local x, y, z
    if typeof(v) == "vector" then x, y, z = v.x, v.y, v.z
    elseif plain(v) then x, y, z = rawget(v, 1), rawget(v, 2), rawget(v, 3)
    else return nil end
    if not finite(x) or not finite(y) or not finite(z)
        or math.abs(x) > bound or math.abs(y) > bound or math.abs(z) > bound then return nil end
    return {x, y, z}
end
local function raw_vec(v, bound) return typeof(v) == "vector" and read_vec(v, bound) or nil end
local function in_world(v) return read_vec(v, 99000) ~= nil end

-- The same u64 serial keys as bail_policy.lua.
local function serial_key(v)
    if type(v) == "number" then
        if v == v and v >= 0 and v <= MAX_SAFE and v % 1 == 0 then return string.format("%d", v) end
        return nil
    end
    if type(v) ~= "string" or #v == 0 or #v > 20 or not string.match(v, "^%d+$") then return nil end
    if #v > 1 and string.sub(v, 1, 1) == "0" then return nil end
    if #v == 20 and v > MAX_U64 then return nil end
    return v
end
local function successor(key)
    local digits = {string.byte(key, 1, #key)}
    local i = #digits
    while i >= 1 and digits[i] == 57 do digits[i] = 48; i -= 1 end
    if i == 0 then table.insert(digits, 1, 49) else digits[i] += 1 end
    return string.char(table.unpack(digits))
end
local function token(v)
    return type(v) == "userdata" or (type(v) == "string" and #v > 0 and #v <= 128)
        or (type(v) == "number" and v == v and v >= 1 and v <= MAX_SAFE and v % 1 == 0)
end

-- env:41-50. Lua capsules are 1-based, so C++ capsules[2] is C[3]. The torso
-- and head centers are the C++ literals; their radii equal capsules 6 and 8.
local C = Geometry.capsules
local function guard(center, radius, region)
    return table.freeze({center = frozen(center), radius = radius, region = region})
end
local guards = table.freeze({
    guard(C[3].a, C[3].radius, "frame"), guard(C[3].b, C[3].radius, "frame"),
    guard(C[4].a, C[4].radius, "frame"), guard(C[4].b, C[4].radius, "frame"),
    guard({0, .89, -.305}, C[6].radius, "torso"),
    guard(C[7].a, C[7].radius, "torso"), guard(C[7].b, C[7].radius, "torso"),
    guard({0, 1.385, .135}, C[8].radius, "head"),
})
local com_from_root = frozen(Geometry.com)
Guard.guards = guards
Guard.MAX_RAYS = MAX_RAYS
-- The inspection and witness constants of guard:20-95.
Guard.limits = table.freeze({
    minimum_radius = .02, maximum_radius = .35, -- guard:23
    start_clearance = .15, -- guard:42, the ray starts radius + .15 above the center
    reach_alignment = .3, reach_extra = .06, -- guard:45, ends radius / .3 + .06 below
    minimum_alignment = .3, -- guard:54, contact_patch minimum_up_alignment
    maximum_gap = .06, maximum_overlap = .15, maximum_crossing = 1.5, -- guard:65
    minimum_movement_speed_squared = .25, maximum_movement_up = .98, -- guard:84-85
    minimum_sweep_squared = .0004, maximum_sweep_squared = 2.25, -- guard:90
    hit_tolerance = .025, -- guard:33, ray interpolation error
    witness_clearance = .16, witness_reach = .06, -- guard:71-72
    plane_tolerance = .0025, -- guard:74, the witness hit's distance from the plane
})
local L = Guard.limits

local function body_copy(raw)
    if not plain(raw) then return nil end
    local com = read_vec(rawget(raw, "center_of_mass"), 90000)
    local v, w = read_vec(rawget(raw, "linear_velocity"), 1000), read_vec(rawget(raw, "angular_velocity"), 1000)
    local q = rawget(raw, "orientation")
    if not com or not v or not w or not plain(q) then return nil end
    local quat, norm = {}, 0
    for i = 1, 4 do
        local x = rawget(q, i)
        if not finite(x) or math.abs(x) > 2 then return nil end
        quat[i] = x; norm += x*x
    end
    if math.abs(norm - 1) > .001 then return nil end
    norm = math.sqrt(norm)
    for i = 1, 4 do quat[i] /= norm end
    return {com = com, q = quat, v = v, w = w}
end
local function same_array(a, b, count)
    if not plain(a) then return false end
    for i = 1, count do
        local value = rawget(a, i)
        if value ~= b[i] or (value == 0 and 1/value ~= 1/b[i]) then return false end
    end
    return true
end
local function frame_copy(raw)
    if not plain(raw) then return nil end
    local raw_body = rawget(raw, "body")
    local key, body, owner = serial_key(rawget(raw, "serial")), body_copy(raw_body), rawget(raw, "owner")
    if not key or key == "0" or not body or not token(owner) then return nil end
    -- The read this frame came from, which is required: fresh, focused,
    -- outside the menu, with the same serial, step and body arrays. The SDK
    -- batch carries only its epoch, so no body or source field is looked for
    -- on the batch itself.
    local query = Frame.copy(rawget(raw, "query_frame"))
    local seconds = rawget(raw, "seconds")
    if not query or not query.fresh or not query.gates.focused or query.gates.menu_open
        or key ~= query.serial or seconds ~= query.seconds then return nil end
    for _, name in ipairs({"center_of_mass", "orientation", "linear_velocity", "angular_velocity"}) do
        if not same_array(rawget(raw_body, name), query.body[name], name == "orientation" and 4 or 3) then return nil end
    end
    return {key = key, body = body, owner = owner, seconds = seconds, query_frame = query}
end

-- frame and previous are {serial, seconds, owner, body, query_frame}. body
-- has the force_math shape: center_of_mass, orientation {x,y,z,w},
-- linear_velocity and angular_velocity, all in world metres. owner is the
-- same opaque mount token later given to bail_policy. query_frame is the Ride
-- Framev1 of the read (frame_identity.lua) and is required; the plan keeps a
-- private copy and binds both batches to it. previous lends history only
-- when it is the same owner's exactly preceding serial (chassis_ride.cpp:
-- 205-207) and Framev1 calls it the same body and source's coherent measured
-- successor; otherwise every previous center is the current one, as in the
-- C++. The caller still owns the policy's history: it pauses or resets
-- bail_policy when that continuity is lost.
-- Returns a frozen plan whose rays list is exactly probe_batch shaped, or nil
-- and why: invalid_guard_frame for a frame without a qualified Framev1.
function Guard.plan(frame, previous)
    local now = frame_copy(frame)
    if not now then return nil, "invalid_guard_frame" end
    local old = previous ~= nil and frame_copy(previous) or nil
    if old and (not rawequal(old.owner, now.owner) or successor(old.key) ~= now.key
        or Frame.classify(old.query_frame, now.query_frame).kind ~= "successor") then
        old = nil
    end
    local consecutive = old ~= nil
    local body = now.body
    local rays, slots, public_slots, state = {}, {}, {}, {}
    for index, g in ipairs(guards) do
        if not finite(g.radius) or g.radius < L.minimum_radius or g.radius > L.maximum_radius then
            return nil, "invalid_guard_geometry"
        end
        local offset = sub(g.center, com_from_root)
        local center = add(body.com, turn(body.q, offset))
        local velocity = add(body.v, cross(body.w, sub(center, body.com)))
        local previous_center, previous_velocity = center, velocity
        if consecutive then
            previous_center = add(old.body.com, turn(old.body.q, offset))
            previous_velocity = add(old.body.v, cross(old.body.w, sub(previous_center, old.body.com)))
        end
        state[index] = {center = center, previous_center = previous_center, velocity = velocity,
            previous_velocity = previous_velocity, radius = g.radius, region = g.region}
        local function inspect(kind, up, swept) -- guard:42-46
            local start = swept and previous_center or add(center, mul(up, g.radius + L.start_clearance))
            local finish = sub(center, mul(up, g.radius/L.reach_alignment + L.reach_extra))
            if not in_world(start) or not in_world(finish) then return false end
            local from = vector.create(start[1], start[2], start[3])
            local to = vector.create(finish[1], finish[2], finish[3])
            rays[#rays + 1] = table.freeze({from = from, to = to})
            -- The decode checks hits against the vector components actually sent.
            slots[#slots + 1] = {guard = index, kind = kind, up = up, swept = swept,
                from = {from.x, from.y, from.z}, to = {to.x, to.y, to.z}}
            public_slots[#public_slots + 1] = table.freeze({guard = index, kind = kind, region = g.region})
            return true
        end
        if not inspect("down", {0, 1, 0}, false) then return nil, "guard_ray_outside_world" end -- guard:82
        local incoming = consecutive and previous_velocity or velocity -- guard:84-86
        if dot(incoming, incoming) > L.minimum_movement_speed_squared then
            local up = unit(mul(incoming, -1))
            if up and up[2] < L.maximum_movement_up and not inspect("movement", up, false) then
                return nil, "guard_ray_outside_world"
            end
        end
        if consecutive then -- guard:87-90
            local displacement = sub(previous_center, center)
            local distance2 = dot(displacement, displacement)
            if distance2 > L.minimum_sweep_squared and distance2 <= L.maximum_sweep_squared then
                local up = unit(displacement)
                if up and not inspect("swept", up, true) then return nil, "guard_ray_outside_world" end
            end
        end
    end
    if #rays < 1 or #rays > MAX_RAYS then return nil, "guard_ray_budget" end
    local plan = table.freeze({serial = now.key, owner = now.owner, seconds = now.seconds,
        consecutive = consecutive, body_up = frozen(turn(body.q, {0, 1, 0})),
        rays = table.freeze(rays), slots = table.freeze(public_slots),
        -- Normals are required; the riding caller must also exclude its rider.
        options = table.freeze({require_contact = true, exclude_local_actor = true})})
    issued[plan] = {slots = slots, guards = state, query_frame = now.query_frame}
    return plan
end

local function unavailable(reason)
    return table.freeze({available = false, reason = reason, contacts = table.freeze({})})
end
local function dense(t, count)
    if not plain(t) then return false end
    local n = 0
    for key in pairs(t) do
        n += 1
        if n > count or type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > count then return false end
    end
    return n == count
end
-- An unavailable, rejected, exhausted, decoded or unqualified batch is never
-- clear space. A ray that may have stopped on the rider or on the bike's own
-- bodies says nothing, so both returned exclusion facts must be true. The
-- epoch and Contact.decode are checked by Guard.witness and Guard.decode.
local function batch_rows(batch, count)
    if not plain(batch) or rawget(batch, "valid") == false then return nil, "guard_query_unavailable" end
    if rawget(batch, "status") ~= "available" then
        local reason = rawget(batch, "reason")
        return nil, type(reason) == "string" and #reason > 0 and #reason <= 200 and reason
            or "guard_query_unavailable"
    end
    if not only(batch, raw_batch) then return nil, "guard_batch_not_raw" end
    if rawget(batch, "budget_exhausted") ~= false then return nil, "guard_query_unavailable" end
    if rawget(batch, "local_actor_excluded") ~= true or rawget(batch, "owned_bodies_excluded") ~= true then
        return nil, "guard_exclusion_unqualified"
    end
    local rows = rawget(batch, "rays")
    if not dense(rows, count) then return nil, "guard_rays_incomplete" end
    return rows
end
-- The real raw-query decoder on the plan's own frame copy, for both batches
-- of every plan, so the epoch, cast accounting, exclusions and measured
-- contact fields are checked as contact integration checks them. An
-- available decode with an actor_exclusion_unqualified force_reason is
-- refused. force_ready is not guard-query authority and is not read. The
-- epoch, accounting and exclusion checks below (and the force_reason one)
-- cannot be reached today: batch_rows, the epoch check or Contact.decode's
-- own rejection refuses those batches first, as bail_policy_tests' table of
-- edits to both batches shows. Only the measured-motion check refuses on its
-- own. The others are kept so this verdict stands if those checks move.
local function contact_issue(query_frame, rays, batch)
    local decoded = Contact.decode(query_frame, rays, batch)
    if not decoded.valid or decoded.status ~= "available" then return decoded.reason or "guard_query_unavailable" end
    local facts = decoded.query
    if facts.epoch_matches ~= true or facts.accounting_known ~= true then return "guard_query_unavailable" end
    if facts.local_actor_excluded ~= true or facts.owned_bodies_excluded ~= true
        or decoded.force_reason == "actor_exclusion_unqualified" then return "guard_exclusion_unqualified" end
    if facts.measurements_complete ~= true then return "guard_measurements_unavailable" end
    return nil
end
-- guard:31-35: a hit must lie on its own segment. The normal must be measured,
-- unit and facing the ray, as contact_runtime.lua also requires. Rows are raw:
-- Luau vectors and the raw fields only.
local function hit_copy(raw, slot)
    local body = rawget(raw, "body")
    if not only(raw, raw_hit) or (body ~= nil and type(body) ~= "userdata") then return nil, "malformed_guard_hit" end
    local fraction = rawget(raw, "fraction")
    local point = raw_vec(rawget(raw, "position"), 100000)
    if not finite(fraction) or fraction < 0 or fraction > 1 or not point then return nil, "malformed_guard_hit" end
    local delta = sub(slot.to, slot.from)
    local error = sub(add(slot.from, mul(delta, fraction)), point)
    if dot(error, error) > L.hit_tolerance*L.hit_tolerance then return nil, "malformed_guard_hit" end
    if rawget(raw, "normal_available") ~= true then return nil, "guard_normal_unavailable" end
    local normal = raw_vec(rawget(raw, "normal"), 1.01)
    if not normal or math.abs(dot(normal, normal) - 1) > .001 then return nil, "malformed_guard_normal" end
    if dot(delta, normal) > 1e-4*math.sqrt(dot(delta, delta)) then return nil, "backfacing_guard_normal" end
    return {point = point, normal = normal}
end
-- Returns a hit, false for a clear row, or nil and why the row is unusable.
-- Unavailable, unknown or missing rows are never evidence of space. A raw
-- clear row carries nothing but its status.
local function row_copy(raw, slot)
    local status = plain(raw) and rawget(raw, "status")
    if status == "hit" then return hit_copy(raw, slot) end
    if status ~= "clear" then return nil, "guard_ray_unavailable" end
    if not only(raw, {status = true}) then return nil, "malformed_guard_clear" end
    return false
end
-- guard:57-65 and 75-76, with the measured normal in place of the fit.
local function candidate(counts, g, slot, hit, consecutive)
    local n = hit.normal
    if dot(n, slot.up) < L.minimum_alignment then counts.grazing += 1; return nil end
    local center_side = dot(sub(g.center, hit.point), n)
    local previous_side = consecutive and dot(sub(g.previous_center, hit.point), n) or center_side
    local gap = center_side - g.radius
    -- guard:61-64: a sphere may already overlap before its center crosses the
    -- face; only a new center-side crossing on the swept path counts.
    local crossed = slot.swept and previous_side > 0 and center_side < 0
    if not finite(gap) or gap > L.maximum_gap or gap < -(crossed and L.maximum_crossing or L.maximum_overlap) then
        counts.outside_gap += 1; return nil
    end
    local now = -dot(g.velocity, n)
    return {guard = slot.guard, point = hit.point, normal = n, separation = gap, crossed = crossed,
        closing_speed = math.max(now, consecutive and -dot(g.previous_velocity, n) or now)}
end

-- batch is the raw probe_batch result for plan.rays, cast in the plan's own
-- read. Returns a frozen witness plan: {available=true, rays, slots, options}
-- with 0 to 24 probe_batch-shaped rays to cast for the same body step, or
-- {available=false, reason} when the first batch is unusable. Either one goes
-- to Guard.decode; an unavailable one decodes to its own reason.
function Guard.witness(plan, batch)
    local function refuse(reason)
        local out = table.freeze({available = false, reason = reason, rays = table.freeze({})})
        pending[out] = {reason = reason}
        return out
    end
    local private = issued[plan]
    if not private then return refuse("unknown_guard_plan") end
    local rows, why = batch_rows(batch, #plan.rays)
    if not rows then return refuse(why) end
    -- Each read has its own epoch, so a batch from an earlier read cannot be
    -- taken for this one's.
    local epoch = rawget(batch, "epoch")
    if not rawequal(epoch, private.query_frame.physics_epoch) then return refuse("query_epoch_mismatch") end
    local counts = {hits = 0, grazing = 0, outside_gap = 0, unwitnessed = 0}
    local candidates, crossing = {}, {}
    for i, slot in ipairs(private.slots) do
        local hit, reason = row_copy(rawget(rows, i), slot)
        if hit == nil then return refuse(reason) end
        if hit then
            counts.hits += 1
            local c = candidate(counts, private.guards[slot.guard], slot, hit, plan.consecutive)
            if c then
                candidates[#candidates + 1] = c
                if c.crossed then crossing[c.guard] = true end
            end
        end
    end
    local issue = contact_issue(private.query_frame, plan.rays, batch)
    if issue then return refuse(issue) end
    -- guard:66-74: each other candidate needs a fresh witness through the
    -- guard center along its own normal. A guard with a crossing needs none:
    -- the swept inspection runs last and a crossing always wins (guard:77), so
    -- those witnesses could change only availability, never the contact.
    -- Candidates of one guard with the same measured normal share one ray,
    -- since the C++ would cast that identical ray twice.
    local rays, slots, public_slots, keys = {}, {}, {}, {}
    for _, c in ipairs(candidates) do
        if not c.crossed and not crossing[c.guard] then
            local key = string.format("%d %.17g %.17g %.17g", c.guard, c.normal[1], c.normal[2], c.normal[3])
            local index = keys[key]
            if not index then
                local g = private.guards[c.guard]
                local start = add(g.center, mul(c.normal, g.radius + L.witness_clearance))
                local finish = sub(g.center, mul(c.normal, g.radius + L.witness_reach))
                if not in_world(start) or not in_world(finish) then return refuse("guard_ray_outside_world") end
                local from = vector.create(start[1], start[2], start[3])
                local to = vector.create(finish[1], finish[2], finish[3])
                rays[#rays + 1] = table.freeze({from = from, to = to})
                slots[#slots + 1] = {from = {from.x, from.y, from.z}, to = {to.x, to.y, to.z}}
                public_slots[#public_slots + 1] = table.freeze({guard = c.guard, kind = "witness",
                    region = g.region})
                index = #rays
                keys[key] = index
            end
            c.witness = index
        end
    end
    if #rays > MAX_RAYS then return refuse("guard_ray_budget") end
    local frozen_rays = table.freeze(rays)
    local out = table.freeze({available = true, serial = plan.serial, owner = plan.owner,
        rays = frozen_rays, slots = table.freeze(public_slots), options = plan.options})
    pending[out] = {plan = plan, guards = private.guards, candidates = candidates, slots = slots,
        rays = frozen_rays, counts = counts, first_rays = #plan.rays, epoch = epoch,
        query_frame = private.query_frame}
    return out
end

-- witness is what Guard.witness returned. witness_batch is the raw
-- probe_batch result for witness.rays, or nil when witness.rays is empty
-- (nothing to cast; it is then not read). It must come from the same read as
-- the first batch and carry that batch's epoch, which is the plan's Framev1
-- epoch, and is checked as the first batch was, Contact.decode included.
-- Returns {available=true, serial, contacts} with one GuardContact row per
-- guard, every row available and stamped with the plan's serial, or
-- {available=false, reason} with no rows at all.
function Guard.decode(witness, witness_batch)
    local private = pending[witness]
    if not private then return unavailable("unknown_guard_witness") end
    if private.reason then return unavailable(private.reason) end
    local seen = {}
    if #private.slots > 0 then
        local rows, why = batch_rows(witness_batch, #private.slots)
        if not rows then return unavailable(why) end
        if not rawequal(rawget(witness_batch, "epoch"), private.epoch) then
            return unavailable("guard_witness_epoch_mismatch")
        end
        for i, slot in ipairs(private.slots) do
            local hit, reason = row_copy(rawget(rows, i), slot)
            if hit == nil then return unavailable(reason) end
            seen[i] = hit
        end
        local issue = contact_issue(private.query_frame, private.rays, witness_batch)
        if issue then return unavailable(issue) end
    end
    local counts = table.clone(private.counts)
    local best = {}
    for _, c in ipairs(private.candidates) do
        local point, separation = nil, c.separation
        if c.crossed then
            point = c.point -- the swept ray's own hit on the historical segment
        elseif c.witness then
            local w = seen[c.witness]
            if w and math.abs(dot(sub(w.point, c.point), c.normal)) <= L.plane_tolerance then
                point = w.point -- guard:78 reports the witness point
                -- A reported hit may lie up to 25 mm off its own ray, so
                -- the separation is never less than the sphere's distance to
                -- the point it reports: a finite face beside the witness
                -- line cannot earn proximity from its extended plane.
                local g = private.guards[c.guard]
                local delta = sub(g.center, point)
                separation = math.max(separation, math.sqrt(dot(delta, delta)) - g.radius)
                if not finite(separation) or separation > L.maximum_gap then
                    counts.outside_gap += 1
                    point = nil
                end
            else
                counts.unwitnessed += 1
            end
        end
        if point then
            local out = best[c.guard]
            if not out or c.crossed or separation < out.separation then -- guard:77
                best[c.guard] = {point = point, normal = c.normal, separation = separation,
                    closing_speed = c.closing_speed, swept_crossing = c.crossed}
            end
        end
    end
    local contacts = {}
    for index, g in ipairs(private.guards) do
        local found = best[index]
        -- chassis_ride.cpp:224-227. A guard without a hit keeps zero geometry.
        contacts[index] = table.freeze({region = g.region, available = true, hit = found ~= nil,
            query_serial = private.plan.serial, point = frozen(found and found.point or {0, 0, 0}),
            normal = frozen(found and found.normal or {0, 0, 0}), separation = found and found.separation or 0,
            closing_speed = found and found.closing_speed or 0, swept_crossing = found and found.swept_crossing or false})
    end
    local out = table.freeze({available = true, serial = private.plan.serial,
        rays = private.first_rays + #private.slots, witness_rays = #private.slots,
        contacts = table.freeze(contacts), counts = table.freeze(counts)})
    decoded_by[out] = private.plan
    return out
end

-- Assembles the bail_policy sample for this plan's own decode. An unavailable
-- decode has no sample: the caller must not step the policy as if it were
-- clear. residual_impulse_ns is the caller's force/velocity residual proxy
-- (chassis_ride.cpp:229-236), or nil when it has none.
function Guard.policy_sample(plan, decoded, residual_impulse_ns)
    if not issued[plan] or decoded_by[decoded] ~= plan or decoded.available ~= true then return nil end
    local contacts = {}
    for i, row in ipairs(decoded.contacts) do contacts[i] = row end
    return {owner = plan.owner, serial = plan.serial, seconds = plan.seconds, mounted = true,
        body_up = {plan.body_up[1], plan.body_up[2], plan.body_up[3]}, contacts = contacts,
        residual_available = residual_impulse_ns ~= nil, residual_impulse_ns = residual_impulse_ns}
end
return table.freeze(Guard)

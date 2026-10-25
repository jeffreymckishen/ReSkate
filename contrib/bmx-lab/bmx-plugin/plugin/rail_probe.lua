-- Rail and edge detection from one probe_batch around the pegs and wheels.
-- Pure arithmetic over a measured body pose and the rows of that batch: it
-- never queries, never applies a force and never moves the bike. plan builds
-- a probe_batch-shaped layout (five straight-down rays per site, six sites,
-- 30 of the 32 allowed rays); decode turns the rows into one edge estimate per
-- site and into the contact rows grind_policy.lua and grind_contact.lua take.
-- A missing, unavailable or normal-less ray never becomes clear: the site it
-- belongs to is unavailable. RAIL_PROBE.md has the layout, classes and limits.
local G = require("./bike_geometry")
local Pegs = require("./peg_geometry")
local M = require("./force_math")
local Probe = {}
local MAX_RAYS = 32 -- the probe_batch limit, contact_runtime.lua MAX_RAYS
local WORLD = 99000 -- probe_batch refuses positions beyond 100 km of the origin
-- contact_runtime.lua's tolerance between a hit and the segment it was cast on.
local HIT_TOLERANCE = .025
-- Below this squared normal difference two normals are the same direction
-- within float noise, so they carry no curvature to fit a radius from.
local SPREAD = 1e-6
-- A fitted rail direction must be this close to perpendicular to every
-- normal it was fitted from, or the surface is not the cylinder assumed.
local FIT_ORTHOGONALITY = .02
local FIT_RESIDUAL = .005
Probe.MAX_RAYS = MAX_RAYS
-- Ray order inside each site. left is the bike's +X (rider left) and ahead its
-- +Z, both laid flat against gravity.
Probe.samples = table.freeze({ "center", "left", "right", "ahead", "behind" })
local PER_SITE = #Probe.samples
local issued = setmetatable({}, { __mode = "k" }) -- plan -> private geometry

local finite = M.finite
local function plain(v) return type(v) == "table" and getmetatable(v) == nil end
-- Accepts a Luau vector (raw probe_batch rows) or a 3-array (Contact.decode rows).
local function read_vec(v, bound)
    local x, y, z
    if typeof(v) == "vector" then x, y, z = v.x, v.y, v.z
    elseif plain(v) then x, y, z = rawget(v, 1), rawget(v, 2), rawget(v, 3)
    else return nil end
    if not finite(x) or not finite(y) or not finite(z)
        or math.abs(x) > bound or math.abs(y) > bound or math.abs(z) > bound then return nil end
    return { x, y, z }
end
local function freeze(t)
    for _, v in pairs(t) do if type(v) == "table" and not table.isfrozen(v) then freeze(v) end end
    return table.isfrozen(t) and t or table.freeze(t)
end

-- Sites in a fixed order, which is also the ray order. Pegs come from
-- peg_geometry.lua; tires probe from the bike_geometry.lua axles.
local sites = {}
for _, name in ipairs(Pegs.names()) do
    local peg = Pegs.peg(name)
    table.insert(sites, { name = name, kind = "peg", group = "pegs", center = peg.center, radius = peg.radius })
end
for _, name in ipairs({ "front", "rear" }) do
    table.insert(sites, { name = name, kind = "tire", group = "tires", center = G[name .. "_axle"], radius = G.wheel_radius })
end
assert(#sites * PER_SITE <= MAX_RAYS, "rail probe layout exceeds the probe_batch ray limit")
function Probe.sites()
    local out = {}
    for _, site in ipairs(sites) do table.insert(out, site.name) end
    return out
end

-- Authored tuning, not measured game values. The peg's lateral offset is half
-- its length, so an edge seen between the centre and an end ray is under the
-- peg. The along offsets stay short so a 50 mm rail crossed at the grind
-- policy's 0.7 rad approach limit still lies under both along rays.
local defaults = {
    peg_lateral_offset = Pegs.length / 2, peg_along_offset = .03,
    tire_lateral_offset = .05, tire_along_offset = .04,
    start_clearance = .05, reach = .25, step = .02, level_tolerance = .01, curve_angle = .25,
    max_incline = 1, max_radius = .2, proximity = .1, friction = .12,
}
local bounds = {
    peg_lateral_offset = { .01, .15 }, peg_along_offset = { .01, .15 },
    tire_lateral_offset = { .01, .15 }, tire_along_offset = { .01, .15 },
    start_clearance = { 0, .3 }, reach = { .05, 1 }, step = { .005, .1 }, level_tolerance = { .001, .05 },
    curve_angle = { .05, .8 }, max_incline = { .1, 1.4 }, max_radius = { .01, .5 }, proximity = { .01, .5 },
    friction = { 0, 10 },
}
local function sanitize(source)
    source = plain(source) and source or {}
    local out = {}
    for name, fallback in pairs(defaults) do
        local value = rawget(source, name)
        out[name] = math.clamp(finite(value) and value or fallback, bounds[name][1], bounds[name][2])
    end
    -- A level sample must not also count as a step.
    out.level_tolerance = math.min(out.level_tolerance, out.step)
    return out
end
function Probe.settings(source) return sanitize(source) end

local function pose_copy(raw)
    if not plain(raw) then return nil end
    local com, q = read_vec(rawget(raw, "center_of_mass"), WORLD), rawget(raw, "orientation")
    if not com or not plain(q) then return nil end
    local quat, norm = {}, 0
    for i = 1, 4 do
        local x = rawget(q, i)
        if not finite(x) or math.abs(x) > 2 then return nil end
        quat[i] = x
        norm += x * x
    end
    if math.abs(norm - 1) > .001 then return nil end
    return { center_of_mass = com, orientation = M.normalized(quat) }
end

-- pose is the measured body in the force_math.lua shape; only center_of_mass
-- and orientation {x,y,z,w} are read. options: gravity (default {0,-9.8,0}),
-- settings (see defaults) and epoch, the opaque sample epoch the batch will
-- be cast against; when given, decode accepts only a batch carrying it.
-- Returns a frozen plan whose rays list is exactly probe_batch shaped and
-- whose options are the ones that batch needs.
function Probe.plan(pose, options)
    if options ~= nil and not plain(options) then return nil, "invalid_options" end
    options = options or {}
    local t = sanitize(rawget(options, "settings"))
    local body = pose_copy(pose)
    if not body then return nil, "invalid_pose" end
    local gravity = rawget(options, "gravity")
    local g = gravity == nil and { 0, -9.8, 0 } or read_vec(gravity, 100)
    if not g or M.length(g) < .1 then return nil, "invalid_gravity" end
    local up = M.unit(M.mul(g, -1))
    -- The rays fall along gravity, so the sample frame lies flat. The bike's
    -- lateral axis sets it; a bike rolled onto its side has no flat frame.
    local left = M.turn(body.orientation, { 1, 0, 0 })
    local flat = M.sub(left, M.mul(up, M.dot(left, up)))
    if M.length(flat) < .2 then return nil, "pose_unprobeable" end
    local lateral = M.unit(flat)
    local forward = M.cross(lateral, up)
    local rays, slots, public = {}, {}, {}
    for index, site in ipairs(sites) do
        local center = Pegs.to_world(body, site.center)
        local peg = site.kind == "peg"
        local w = peg and t.peg_lateral_offset or t.tire_lateral_offset
        local a = peg and t.peg_along_offset or t.tire_along_offset
        -- A peg ray starts above the peg so a rail pressed into it is still
        -- seen from outside. A tire ray starts at the axle, inside the
        -- excluded bike body, so it cannot meet the rider above the wheel.
        local start = M.add(center, M.mul(up, peg and site.radius + t.start_clearance or 0))
        local finish = M.sub(center, M.mul(up, site.radius + t.reach))
        local offsets = { { 0, 0, 0 }, M.mul(lateral, w), M.mul(lateral, -w), M.mul(forward, a), M.mul(forward, -a) }
        local first, cast = #rays + 1, {}
        for k, offset in ipairs(offsets) do
            local a0, b0 = M.add(start, offset), M.add(finish, offset)
            if not M.vec(a0, WORLD) or not M.vec(b0, WORLD) then return nil, "ray_outside_world" end
            local from, to = vector.create(a0[1], a0[2], a0[3]), vector.create(b0[1], b0[2], b0[3])
            table.insert(rays, table.freeze({ from = from, to = to }))
            -- Decode checks hits against the float components actually sent.
            local f = { from.x, from.y, from.z }
            local delta = M.sub({ to.x, to.y, to.z }, f)
            cast[k] = { from = f, delta = delta, distance = M.length(delta) }
        end
        slots[index] = { site = site, center = center, bottom = M.sub(center, M.mul(up, site.radius)),
            lateral = lateral, forward = forward, lateral_offset = w, along_offset = a, cast = cast }
        table.insert(public, table.freeze({ name = site.name, kind = site.kind, first = first, count = PER_SITE }))
    end
    local epoch = rawget(options, "epoch")
    local plan = table.freeze({ rays = table.freeze(rays), sites = table.freeze(public),
        -- Normals are required; the riding caller must also exclude its rider.
        options = table.freeze({ require_contact = true, exclude_local_actor = true }),
        up = table.freeze({ up[1], up[2], up[3] }), epoch = epoch })
    issued[plan] = { settings = t, up = up, slots = slots, epoch = epoch, count = #rays }
    return plan
end

-- One row, or nil and why. A clear row has no geometry, so anything else it
-- carries is not read. A hit needs a measured, unit, front-facing normal.
local function read_row(raw, cast)
    if not plain(raw) then return nil, "malformed_row" end
    local status = rawget(raw, "status")
    if status == "unavailable" then return nil, "ray_unavailable" end
    if status == "clear" then return { hit = false } end
    if status ~= "hit" then return nil, "malformed_row" end
    local fraction, point = rawget(raw, "fraction"), read_vec(rawget(raw, "position"), 100000)
    if not finite(fraction) or fraction < 0 or fraction > 1 or not point then return nil, "malformed_row" end
    for axis = 1, 3 do
        if math.abs(point[axis] - (cast.from[axis] + cast.delta[axis] * fraction)) > HIT_TOLERANCE then
            return nil, "inconsistent_hit"
        end
    end
    local available = rawget(raw, "normal_available")
    if available == nil or available == false then return nil, "normal_unavailable" end
    if available ~= true then return nil, "malformed_row" end
    if rawget(raw, "normal") == nil then return nil, "normal_unavailable" end
    local normal = read_vec(rawget(raw, "normal"), 1.01)
    if not normal then return nil, "invalid_normal" end
    local square = M.dot(normal, normal)
    -- The SDK refuses nonunit and backfacing normals; a constructed or copied
    -- row is held to the same rule instead of being normalized or flipped.
    if square < .98 or square > 1.02 or M.dot(cast.delta, normal) > 1e-4 * cast.distance then
        return nil, "invalid_normal"
    end
    normal = M.mul(normal, 1 / math.sqrt(square))
    local moving, surface = rawget(raw, "surface_velocity_available"), nil
    if moving == true then
        surface = read_vec(rawget(raw, "surface_velocity"), 100)
        if not surface then return nil, "malformed_row" end
    elseif moving ~= false and moving ~= nil then return nil, "malformed_row" end
    return { hit = true, point = point, normal = normal, surface_velocity = surface }
end

-- Side names for each sampling axis: along runs with the edge, cross over it.
local names = {
    forward = { along = { "ahead", "behind" }, cross = { "left", "right" } },
    lateral = { along = { "left", "right" }, cross = { "ahead", "behind" } },
}
local function unavailable(reason) return { status = "unavailable", reason = reason } end
local function none(class) return { status = "none", class = class, reason = "none" } end

-- Radius from cross samples that landed on the same rail's flank, for a rail
-- whose along samples share one normal (it runs straight along that axis).
local function flank_radius(t, c, tangent, list)
    local total, count = 0, 0
    for _, r in ipairs(list) do
        if r.hit and M.dot(r.normal, c.normal) < math.cos(t.curve_angle) then
            local dp, dn = M.sub(r.point, c.point), M.sub(r.normal, c.normal)
            dp = M.sub(dp, M.mul(tangent, M.dot(dp, tangent)))
            dn = M.sub(dn, M.mul(tangent, M.dot(dn, tangent)))
            local spread = M.dot(dn, dn)
            if spread > SPREAD then
                local radius = M.dot(dp, dn) / spread
                if radius > 0 and radius <= t.max_radius and M.length(M.sub(dp, M.mul(dn, radius))) <= FIT_RESIDUAL then
                    total += radius
                    count += 1
                end
            end
        end
    end
    return count > 0 and total / count or nil
end

-- One site's five records into an estimate. Heights are judged against the
-- plane through the centre hit with its own normal, so a banked or sloped
-- surface still reads as flat and an inclined rail still reads as a line.
local function classify(t, up, slot, rows)
    local c = rows[1]
    local near = false
    for _, r in ipairs(rows) do
        if r.hit and M.dot(M.sub(r.point, slot.bottom), up) >= -t.proximity then near = true end
    end
    -- Something close to the site that cannot be read as an edge is not proof
    -- there is nothing to grind, so it is unavailable rather than clear.
    if not c.hit then return near and unavailable("unclassified_surface") or none("clear") end
    local cos_curve = math.cos(t.curve_angle)
    local function plane(r) return M.dot(M.sub(r.point, c.point), c.normal) end
    local function cross_state(r)
        if not r.hit then return "away" end
        local d = plane(r)
        if d > t.step then return "rise" end
        if d < -t.step then return "away" end
        if M.dot(r.normal, c.normal) < cos_curve then return d < -t.level_tolerance and "away" or "uncertain" end
        return math.abs(d) <= t.level_tolerance and "level" or "uncertain"
    end
    -- Along samples may curve: on a rail crossed at a yaw they land on its
    -- flanks, lower than the crest by less than a step.
    local function along_state(r)
        if not r.hit then return "away" end
        local d = plane(r)
        if d > t.step then return "rise" end
        return d < -t.step and "away" or "on"
    end
    local function hypothesis(axis, cp, cn, ap, an)
        local sp, sn = cross_state(cp), cross_state(cn)
        if sp == "rise" or sn == "rise" or sp == "uncertain" or sn == "uncertain" then return nil, "irregular" end
        if sp ~= "away" and sn ~= "away" then return nil, "flat" end
        local tp, tn = along_state(ap), along_state(an)
        if tp == "rise" or tn == "rise" or (tp == "away" and tn == "away") then return nil, "irregular" end
        return { axis = axis, class = (sp == "away" and sn == "away") and "round_rail" or "ledge",
            drop = sp == "away" and 1 or -1, cross = { cp, cn },
            along_pos = tp == "on" and ap or nil, along_neg = tn == "on" and an or nil }
    end
    -- The forward axis is tried first: pegs ride rails that run with the bike.
    -- A ledge corner that fits both axes therefore reads the same every time.
    local h, fore_issue = hypothesis("forward", rows[2], rows[3], rows[4], rows[5])
    local side_issue = "none"
    if not h then h, side_issue = hypothesis("lateral", rows[4], rows[5], rows[2], rows[3]) end
    if not h then
        if fore_issue == "flat" and side_issue == "flat" then return none("flat") end
        return near and unavailable("irregular_surface") or none("far")
    end
    local forward_axis = h.axis == "forward"
    local u_cross = forward_axis and slot.lateral or slot.forward
    local cross_offset = forward_axis and slot.lateral_offset or slot.along_offset
    local label = names[h.axis]
    local A, B = h.along_pos or c, h.along_neg or c
    local edge_end = not h.along_pos and label.along[1] or not h.along_neg and label.along[2] or "none"
    local D, E = M.sub(A.point, B.point), M.sub(A.normal, B.normal)
    local tangent, radius, source = nil, nil, "along_samples"
    if h.class == "round_rail" and M.dot(E, E) > SPREAD then
        -- Two hits on one cylinder sit at p - R n on its axis, so D - R E runs
        -- along the axis and R = D.E / E.E (exact for a cylinder). This is
        -- what recovers a rail crossed at a yaw, where D alone follows the bike.
        local r = M.dot(D, E) / M.dot(E, E)
        if r > 0 and r <= t.max_radius then
            local fit = M.unit(M.sub(D, M.mul(E, r)))
            if fit and math.abs(M.dot(fit, A.normal)) <= FIT_ORTHOGONALITY
                and math.abs(M.dot(fit, B.normal)) <= FIT_ORTHOGONALITY
                and math.abs(M.dot(fit, c.normal)) <= FIT_ORTHOGONALITY then
                tangent, radius, source = fit, r, "normal_fit"
            end
        end
    end
    if not tangent then
        tangent = M.unit(M.sub(D, M.mul(c.normal, M.dot(D, c.normal))))
        if not tangent then return unavailable("edge_direction_unavailable") end
    end
    -- One deterministic sign: with the bike, or toward rider left when square.
    local facing = M.dot(tangent, slot.forward)
    if facing < -1e-6 or (math.abs(facing) <= 1e-6 and M.dot(tangent, slot.lateral) < 0) then
        tangent = M.mul(tangent, -1)
    end
    local incline = math.asin(math.clamp(math.abs(M.dot(tangent, up)), 0, 1))
    if incline > t.max_incline then return unavailable("edge_incline") end
    local out = { status = "edge", class = h.class, axis = h.axis, reason = "none", tangent = tangent,
        tangent_source = source, edge_end = edge_end, incline = incline }
    if h.class == "round_rail" then
        -- The outward normal is the crest's, where a peg or tire rests on the
        -- rail under gravity, not the normal of whichever flank a ray met.
        out.normal = M.unit(M.sub(up, M.mul(tangent, M.dot(up, tangent))))
        if not out.normal then return unavailable("edge_direction_unavailable") end
        radius = radius or flank_radius(t, c, tangent, h.cross)
        out.radius, out.crest_observed = radius, radius ~= nil
        out.point = radius and M.add(M.sub(c.point, M.mul(c.normal, radius)), M.mul(out.normal, radius)) or M.copy(c.point)
        out.lateral_uncertainty = 0
    else
        -- A ledge lip lies between the level centre hit and the dropped ray.
        -- The point is the middle of that interval, on the top plane.
        out.normal = M.unit(M.sub(c.normal, M.mul(tangent, M.dot(c.normal, tangent))))
        local toward = out.normal and M.unit(M.cross(out.normal, tangent))
        if not toward then return unavailable("edge_direction_unavailable") end
        if M.dot(toward, M.mul(u_cross, h.drop)) < 0 then toward = M.mul(toward, -1) end
        out.point = M.add(c.point, M.mul(toward, cross_offset / 2))
        out.lateral_uncertainty = cross_offset / 2
        out.drop_side = h.drop > 0 and label.cross[1] or label.cross[2]
    end
    out.separation = M.dot(M.sub(slot.center, out.point), out.normal) - slot.site.radius
    out.motion = c.surface_velocity and "measured" or "unknown"
    out.surface_velocity = c.surface_velocity and M.copy(c.surface_velocity) or nil
    return out
end

-- The grind_contact shape: {available, touching, point, normal, tangent,
-- separation, surface_velocity, friction}. An edge whose surface motion was
-- not measured cannot become a contact; zero motion is never assumed.
local function row_for(t, estimate)
    if estimate.status == "none" then return { available = true, touching = false } end
    if estimate.status ~= "edge" or estimate.motion ~= "measured" then return { available = false } end
    return { available = true, touching = true, point = M.copy(estimate.point), normal = M.copy(estimate.normal),
        tangent = M.copy(estimate.tangent), separation = estimate.separation,
        surface_velocity = M.copy(estimate.surface_velocity), friction = t.friction }
end
local function result(t, status, reason, estimates)
    local out = { valid = t ~= nil, status = status, reason = reason, sites = {}, contacts = { pegs = {}, tires = {} } }
    for index, site in ipairs(sites) do
        local estimate = estimates and estimates[index] or unavailable(reason)
        estimate.site, estimate.kind = site.name, site.kind
        out.sites[site.name] = estimate
        out.contacts[site.group][site.name] = t and row_for(t, estimate) or { available = false }
    end
    return freeze(out)
end

-- A raw probe_batch carries its exclusion facts on the batch; a
-- Contact.decode copy carries them under query. Rows count only when the
-- rider and the bike's own bodies were excluded and the budget held:
-- otherwise a ray that stopped on the rider would read as a rail and reach a
-- force solver. These are the facts trick_runtime.lua and ride_runtime.lua
-- refuse as contact_query_unqualified, so the same name is used here.
local exclusion_facts = { "local_actor_excluded", "owned_bodies_excluded", "budget_exhausted" }
local function query_qualified(batch)
    local facts, query = batch, rawget(batch, "query")
    if query ~= nil then
        -- A copy has already matched its epoch; one that has not, or a batch
        -- carrying both shapes, says two things and is believed in neither.
        if not plain(query) or rawget(query, "epoch_matches") ~= true then return false end
        for _, name in ipairs(exclusion_facts) do
            if rawget(batch, name) ~= nil then return false end
        end
        facts = query
    end
    return rawget(facts, "local_actor_excluded") == true and rawget(facts, "owned_bodies_excluded") == true
        and rawget(facts, "budget_exhausted") == false
end

local function decode(plan, private, batch)
    local t = private.settings
    if not plain(batch) then return result(t, "unavailable", "malformed_batch") end
    if private.epoch ~= nil and not rawequal(rawget(batch, "epoch"), private.epoch) then
        return result(t, "unavailable", "epoch_mismatch")
    end
    local status = rawget(batch, "status")
    if status == "unavailable" then
        local reason = rawget(batch, "reason")
        return result(t, "unavailable", type(reason) == "string" and #reason > 0 and #reason <= 200 and reason
            or "batch_unavailable")
    end
    local rays = rawget(batch, "rays")
    if status ~= "available" or not plain(rays) or #rays ~= private.count then
        return result(t, "unavailable", "malformed_batch")
    end
    if not query_qualified(batch) then return result(t, "unavailable", "contact_query_unqualified") end
    local estimates = {}
    for index, slot in ipairs(private.slots) do
        local rows, refusal = {}, nil
        for k = 1, PER_SITE do
            local row, why = read_row(rawget(rays, (index - 1) * PER_SITE + k), slot.cast[k])
            if not row then refusal = why; break end
            rows[k] = row
        end
        estimates[index] = refusal and unavailable(refusal) or classify(t, private.up, slot, rows)
    end
    return result(t, "available", nil, estimates)
end

-- plan is a value returned by Probe.plan; batch is the probe_batch result for
-- plan.rays (or its Contact.decode copy, which carries no epoch). An
-- available batch decodes only with the rider and owned bodies excluded and
-- the budget unspent; anything else is contact_query_unqualified. Returns a
-- frozen {valid, status, reason, sites = {name = estimate}, contacts = {pegs,
-- tires}}; contacts has every grind_policy row, unavailable when not known.
function Probe.decode(plan, batch)
    local private = type(plan) == "table" and issued[plan] or nil
    if not private then return result(nil, "unavailable", "unknown_plan") end
    local ok, out = pcall(decode, plan, private, batch)
    if ok then return out end
    return result(private.settings, "unavailable", "malformed_batch")
end
return table.freeze(Probe)

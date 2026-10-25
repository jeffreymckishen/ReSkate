-- Constructed scenes exercise the rail probe and the grind_contact port. Rows
-- come from an analytic raycaster over cylinders, boxes and planes in this
-- file, shaped like probe_batch rows; they are not native contacts, retail
-- rays or in-game evidence. The grind_contact cases mirror
-- standalone/bmx-movement/tests/tests.cpp observed_grind_contract and the
-- 100 Hz rail checks of configurable_fixed_step. run() is the entry.
local Probe = require("./rail_probe")
local Contact = require("./grind_contact")
local Grind = require("./grind_policy")
local Pegs = require("./peg_geometry")
local G = require("./bike_geometry")
local M = require("./force_math")
local Tests = {}
local row_fields = { "available", "touching", "point", "normal", "tangent", "separation", "surface_velocity", "friction" }

local function qaxis(axis, angle)
    local s = math.sin(angle / 2)
    return { axis[1] * s, axis[2] * s, axis[3] * s, math.cos(angle / 2) }
end
local function qmul(a, b)
    return { a[4] * b[1] + a[1] * b[4] + a[2] * b[3] - a[3] * b[2],
        a[4] * b[2] - a[1] * b[3] + a[2] * b[4] + a[3] * b[1],
        a[4] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[4],
        a[4] * b[4] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3] }
end
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end
local function keys(t)
    local out = {}
    for key in pairs(t) do table.insert(out, key) end
    table.sort(out)
    return out
end
local function site_center(body, name)
    if name == "front" or name == "rear" then return Pegs.to_world(body, G[name .. "_axle"]), G.wheel_radius end
    local peg = Pegs.peg(name)
    return Pegs.to_world(body, peg.center), peg.radius
end
-- yaw + turns the nose left, pitch + lifts it, roll + leans right. The body is
-- placed so the anchor site's underside sits `gap` above `at`.
local function pose(o)
    o = o or {}
    local q = qmul(qaxis({ 0, 1, 0 }, o.yaw or 0), qmul(qaxis({ 1, 0, 0 }, -(o.pitch or 0)), qaxis({ 0, 0, 1 }, o.roll or 0)))
    local body = { mass = G.mass, inertia_body = M.copy(G.inertia), orientation = q, center_of_mass = { 0, 0, 0 },
        linear_velocity = o.velocity or { 0, 0, 4 }, angular_velocity = { 0, 0, 0 } }
    local center, radius = site_center(body, o.anchor or "rear_left")
    body.center_of_mass = M.add(M.sub(o.at or { 0, 1, 0 }, center), { 0, radius + (o.gap or 0), 0 })
    return body
end

-- Analytic ray casts. Each returns the segment fraction and outward normal of
-- the front face, or nil. A ray starting inside a shape meets no front face.
local function cast_plane(o, d, s)
    local denom = M.dot(d, s.normal)
    if denom >= 0 then return nil end
    local f = M.dot(M.sub(s.point, o), s.normal) / denom
    if f < 0 or f > 1 then return nil end
    return f, s.normal
end
local function cast_cylinder(o, d, s)
    local k, w = s.direction, M.sub(o, s.point)
    local dp, wp = M.sub(d, M.mul(k, M.dot(d, k))), M.sub(w, M.mul(k, M.dot(w, k)))
    local a, b, c = M.dot(dp, dp), 2 * M.dot(wp, dp), M.dot(wp, wp) - s.radius * s.radius
    if a < 1e-12 or c <= 0 then return nil end
    local disc = b * b - 4 * a * c
    if disc < 0 then return nil end
    local f = (-b - math.sqrt(disc)) / (2 * a)
    if f < 0 or f > 1 then return nil end
    local axial = M.dot(M.add(w, M.mul(d, f)), k)
    if s.length and (axial < 0 or axial > s.length) then return nil end
    return f, M.unit(M.add(wp, M.mul(dp, f)))
end
local function yawed(v, angle)
    local c, s = math.cos(angle), math.sin(angle)
    return { c * v[1] + s * v[3], v[2], -s * v[1] + c * v[3] }
end
local function cast_box(o, d, s)
    local lo, ld = yawed(M.sub(o, s.center), -(s.yaw or 0)), yawed(d, -(s.yaw or 0))
    local near, far, axis, sign = -math.huge, math.huge, 0, 0
    for i = 1, 3 do
        if math.abs(ld[i]) < 1e-12 then
            if math.abs(lo[i]) > s.half[i] then return nil end
        else
            local t1, t2 = (-s.half[i] - lo[i]) / ld[i], (s.half[i] - lo[i]) / ld[i]
            local entry_sign = ld[i] > 0 and -1 or 1
            if t1 > t2 then t1, t2 = t2, t1 end
            if t1 > near then near, axis, sign = t1, i, entry_sign end
            far = math.min(far, t2)
        end
    end
    if near < 0 or near > far or near > 1 then return nil end
    local n = { 0, 0, 0 }
    n[axis] = sign
    return near, yawed(n, s.yaw or 0)
end
local casters = { plane = cast_plane, cylinder = cast_cylinder, box = cast_box }
local function trace(scene, ray, o)
    o = o or {}
    local from, to = { ray.from.x, ray.from.y, ray.from.z }, { ray.to.x, ray.to.y, ray.to.z }
    local d = M.sub(to, from)
    local best, normal, shape = math.huge, nil, nil
    for _, s in ipairs(scene) do
        local f, n = casters[s.kind](from, d, s)
        if f and f < best then best, normal, shape = f, n, s end
    end
    if not normal then return { status = "clear" } end
    local p, v = M.add(from, M.mul(d, best)), shape.velocity or { 0, 0, 0 }
    local row = { status = "hit", position = vector.create(p[1], p[2], p[3]), fraction = best,
        motion = o.unknown_motion and "unknown" or "measured", normal_available = o.no_normals ~= true,
        surface_velocity_available = o.unknown_motion ~= true }
    if row.normal_available then row.normal = vector.create(normal[1], normal[2], normal[3]) end
    if row.surface_velocity_available then row.surface_velocity = vector.create(v[1], v[2], v[3]) end
    return row
end
local function batch_for(plan, scene, o)
    local rays = {}
    for i, ray in ipairs(plan.rays) do rays[i] = trace(scene, ray, o) end
    return { status = "available", native_casts = #rays, budget_exhausted = false, local_actor_excluded = true,
        owned_bodies_excluded = true, epoch = o and o.epoch, rays = rays }
end
local function ray_index(plan, site, sample)
    for _, entry in ipairs(plan.sites) do
        if entry.name == site then
            for k, name in ipairs(Probe.samples) do
                if name == sample then return entry.first + k - 1 end
            end
        end
    end
    error("no ray " .. site .. "." .. sample)
end
-- A rail of radius r whose crest runs through `crest` along `direction`.
local function rail(crest, direction, r, o)
    o = o or {}
    local k = M.unit(direction)
    local up = M.unit(M.sub({ 0, 1, 0 }, M.mul(k, k[2])))
    local start = M.sub(crest, M.mul(up, r))
    if o.length then start = M.sub(start, M.mul(k, o.back or 0)) end
    return { kind = "cylinder", point = start, direction = k, radius = r, length = o.length, velocity = o.velocity }
end
local ground = { kind = "plane", point = { 0, 0, 0 }, normal = { 0, 1, 0 } }
local function underside(body, name)
    local center, radius = site_center(body, name)
    return M.sub(center, { 0, radius, 0 })
end

function Tests.run()
    local cases, assertions = 0, 0
    local function check(value, why) assertions += 1; assert(value, why) end
    local function near(a, b, e) return math.abs(a - b) <= (e or 1e-9) end
    local function vnear(a, b, e) return M.length(M.sub(a, b)) <= (e or 1e-9) end
    local function case(name, fn)
        cases += 1
        local ok, issue = pcall(fn)
        if not ok then error(name .. ": " .. tostring(issue), 0) end
    end
    local function probe(body, scene, o)
        local plan = assert(Probe.plan(body, o and o.plan))
        return Probe.decode(plan, batch_for(plan, scene, o)), plan
    end
    local function touching_row(row, why)
        check(equal(keys(row), (function() local k = table.clone(row_fields); table.sort(k); return k end)()),
            why .. ": a touching row has exactly the grind_contact fields")
        check(Grind.contact(row) ~= nil, why .. ": grind_policy accepts the row")
    end

    -- Layout -----------------------------------------------------------------
    case("layout is probe_batch shaped and bounded", function()
        local body = pose()
        local plan = assert(Probe.plan(body))
        check(#plan.rays == 30 and #plan.rays <= Probe.MAX_RAYS, "six five-ray sites fit within 32 rays")
        local dense = 0
        for i, ray in pairs(plan.rays) do
            dense += 1
            check(type(i) == "number" and equal(keys(ray), { "from", "to" }), "each ray is exactly {from, to}")
            check(typeof(ray.from) == "vector" and typeof(ray.to) == "vector", "ray ends are Luau vectors")
            check(near(ray.from.x, ray.to.x, 0) and near(ray.from.z, ray.to.z, 0) and ray.from.y > ray.to.y,
                "level gravity casts straight down")
        end
        check(dense == #plan.rays, "the ray list is dense")
        check(plan.options.require_contact == true and plan.options.exclude_local_actor == true,
            "the plan asks for measured normals and rider exclusion")
        check(equal(Probe.sites(), { "front_left", "front_right", "rear_left", "rear_right", "front", "rear" }),
            "sites are the four pegs then both tires")
        for index, entry in ipairs(plan.sites) do
            check(entry.first == (index - 1) * 5 + 1 and entry.count == 5, "sites own consecutive ray blocks")
        end
        local center = site_center(body, "front_left")
        local c = plan.rays[ray_index(plan, "front_left", "center")]
        check(near(c.from.x, center[1], 1e-6) and near(c.from.z, center[3], 1e-6), "the centre ray falls through the peg centre")
        local l = plan.rays[ray_index(plan, "rear_left", "left")]
        local rc = plan.rays[ray_index(plan, "rear_left", "center")]
        check(near(l.from.x - rc.from.x, Pegs.length / 2, 1e-6), "the left ray sits at the peg's outer end")
        local tire = plan.rays[ray_index(plan, "front", "center")]
        local axle = site_center(body, "front")
        check(near(tire.from.y, axle[2], 1e-6) and near(tire.to.y, axle[2] - G.wheel_radius - .25, 1e-6),
            "a tire ray runs from the axle to the reach below the tire")
        local again = assert(Probe.plan(body))
        for i, ray in ipairs(plan.rays) do
            check(ray.from == again.rays[i].from and ray.to == again.rays[i].to, "the same pose gives the same rays")
        end
        check(not pcall(function() plan.rays[1] = nil end) and not pcall(function() plan.rays[1].from = vector.create(0, 0, 0) end),
            "a plan cannot be edited after it is issued")
    end)
    case("plan refuses unusable poses", function()
        local body = pose()
        local bad = M.copy(body); bad.orientation = { 0, 0, 0, 2 }
        check(select(2, Probe.plan(bad)) == "invalid_pose", "non-unit orientation")
        bad = M.copy(body); bad.center_of_mass = { 0 / 0, 0, 0 }
        check(select(2, Probe.plan(bad)) == "invalid_pose", "nonfinite centre of mass")
        check(select(2, Probe.plan({ center_of_mass = { 0, 0, 0 } })) == "invalid_pose", "missing orientation")
        check(select(2, Probe.plan(body, { gravity = { 0, 0, 0 } })) == "invalid_gravity", "zero gravity")
        check(select(2, Probe.plan(body, 5)) == "invalid_options", "non-table options")
        check(select(2, Probe.plan(pose({ roll = math.pi / 2 }))) == "pose_unprobeable", "a bike on its side has no flat frame")
        -- The body is inside the world but the rear-left peg's outer ray is not.
        check(select(2, Probe.plan(pose({ at = { 98999.98, 1, 0 } }))) == "ray_outside_world", "rays stay inside the 100 km world")
        check(select(2, Probe.plan(pose({ at = { 99500, 1, 0 } }))) == "invalid_pose", "a body outside the world is refused")
    end)

    -- Refusals: unavailable is never clear ------------------------------------
    case("an unavailable batch makes every row unavailable", function()
        local plan = assert(Probe.plan(pose()))
        local rays = {}
        for i = 1, #plan.rays do rays[i] = { status = "unavailable" } end
        local out = Probe.decode(plan, { status = "unavailable", reason = "local_actor_exclusion_unavailable",
            budget_exhausted = false, local_actor_excluded = false, owned_bodies_excluded = false, rays = rays })
        check(out.valid and out.status == "unavailable" and out.reason == "local_actor_exclusion_unavailable",
            "the batch reason is kept")
        for _, group in ipairs({ "pegs", "tires" }) do
            for name, row in pairs(out.contacts[group]) do
                check(equal(row, { available = false }), "unavailable row " .. name)
                local copied, issue = Grind.contact(row)
                check(copied == nil and issue == "unavailable_contact", "grind_policy does not read it as clear")
                check(out.sites[name].status == "unavailable", "unavailable estimate " .. name)
            end
        end
        local unknown = Probe.decode(table.clone(plan), batch_for(plan, { ground }))
        check(not unknown.valid and unknown.reason == "unknown_plan" and unknown.contacts.pegs.rear_left.available == false,
            "only an issued plan decodes")
        check(Probe.decode(plan, "batch").reason == "malformed_batch", "a non-table batch is malformed")
        local short = batch_for(plan, { ground }); table.remove(short.rays)
        check(Probe.decode(plan, short).reason == "malformed_batch", "a batch of the wrong length is malformed")
        local token, other = table.freeze({}), table.freeze({})
        local bound = assert(Probe.plan(pose(), { epoch = token }))
        check(Probe.decode(bound, batch_for(bound, { ground }, { epoch = other })).reason == "epoch_mismatch",
            "a batch cast for another epoch is refused")
        check(Probe.decode(bound, batch_for(bound, { ground }, { epoch = token })).status == "available",
            "the bound epoch decodes")
    end)
    case("an available batch counts only with its exclusions and budget", function()
        local body = pose()
        local scene = { rail(underside(body, "rear_left"), { 0, 0, 1 }, .025), ground }
        local plan = assert(Probe.plan(body))
        local function refused(out, why)
            check(out.valid and out.status == "unavailable" and out.reason == "contact_query_unqualified", why .. " is refused")
            for _, group in ipairs({ "pegs", "tires" }) do
                for name, row in pairs(out.contacts[group]) do
                    check(equal(row, { available = false }) and out.sites[name].reason == "contact_query_unqualified",
                        why .. ": every row is unavailable, " .. name)
                end
            end
            check(select(2, Grind.contact(out.contacts.pegs.rear_left)) == "unavailable_contact",
                why .. ": grind_policy does not read the rail row")
            return out
        end
        for _, edit in ipairs({ { "local_actor_excluded", false }, { "owned_bodies_excluded", false },
            { "budget_exhausted", true }, { "local_actor_excluded", "nil" }, { "owned_bodies_excluded", "nil" },
            { "budget_exhausted", "nil" }, { "local_actor_excluded", 1 }, { "budget_exhausted", 0 } }) do
            local batch = batch_for(plan, scene)
            if edit[2] == "nil" then batch[edit[1]] = nil else batch[edit[1]] = edit[2] end
            refused(Probe.decode(plan, batch), edit[1] .. " = " .. tostring(edit[2]))
        end
        -- Rows that may have stopped on the rider never reach a force solver.
        local batch = batch_for(plan, scene)
        batch.local_actor_excluded, batch.owned_bodies_excluded, batch.budget_exhausted = false, false, true
        local out = refused(Probe.decode(plan, batch), "a batch with no exclusions and a spent budget")
        local judged = Grind.evaluate({ body = body, contacts = out.contacts, ground_support = false })
        check(judged.grind == "none" and judged.issue == "unavailable_contact", "grind_policy admits no grind from it")
        check(not Contact.solve(body, out.contacts.pegs.rear_left).valid, "grind_contact applies nothing from it")
        local good = Probe.decode(plan, batch_for(plan, scene))
        check(good.status == "available" and good.contacts.pegs.rear_left.touching == true,
            "the same rails decode once the batch is qualified")
        -- The Contact.decode copy shape: the facts live under query.
        local function copy(query)
            return { valid = true, status = "available", rays = batch_for(plan, scene).rays, query = query }
        end
        local function facts(edit)
            local q = { epoch_matches = true, accounting_known = true, budget_exhausted = false,
                local_actor_excluded = true, owned_bodies_excluded = true }
            for key, value in pairs(edit or {}) do q[key] = value end
            return q
        end
        check(Probe.decode(plan, copy(facts())).contacts.pegs.rear_left.touching == true, "a qualified copy decodes")
        for _, edit in ipairs({ { local_actor_excluded = false }, { owned_bodies_excluded = false },
            { budget_exhausted = true }, { epoch_matches = false } }) do
            local key, value = next(edit)
            refused(Probe.decode(plan, copy(facts(edit))), "a copy with " .. key .. " = " .. tostring(value))
        end
        refused(Probe.decode(plan, copy("query")), "a copy whose query is not a table")
        local hybrid = batch_for(plan, scene); hybrid.query = facts()
        refused(Probe.decode(plan, hybrid), "a raw batch that also carries a query")
    end)
    case("a bad ray refuses only its own site", function()
        local body = pose()
        local scene = { rail(underside(body, "rear_left"), { 0, 0, 1 }, .025), ground }
        local plan = assert(Probe.plan(body))
        local function refused(edit)
            local batch = batch_for(plan, scene)
            edit(batch.rays[ray_index(plan, "rear_left", "center")], batch)
            local out = Probe.decode(plan, batch)
            check(out.sites.front_left.status == "edge", "the other sites still decode")
            check(out.contacts.pegs.rear_left.available == false, "the refused site's row is unavailable")
            return out.sites.rear_left.status == "unavailable" and out.sites.rear_left.reason
        end
        check(refused(function(_, batch) batch.rays[ray_index(plan, "rear_left", "left")] = { status = "unavailable" } end)
            == "ray_unavailable", "an unavailable ray")
        check(refused(function(row) row.normal_available, row.normal = false, nil end) == "normal_unavailable",
            "a hit without a normal")
        check(refused(function(row) row.normal = nil end) == "normal_unavailable", "a hit flagged with a normal it lacks")
        check(refused(function(row) row.normal = -row.normal end) == "invalid_normal", "a backfacing normal")
        check(refused(function(row) row.normal = row.normal * 1.5 end) == "invalid_normal", "a nonunit normal")
        -- Each component of these is within the 1.01 read bound, so only the
        -- .98..1.02 squared length refuses them.
        check(refused(function(row) row.normal = row.normal * .98 end) == "invalid_normal", "a short normal")
        check(refused(function(row) row.normal = vector.create(.72, .72, 0) end) == "invalid_normal",
            "a long tilted normal")
        check(refused(function(row) row.surface_velocity_available = "yes" end) == "malformed_row",
            "a surface velocity flag that is not a boolean")
        local batch = batch_for(plan, scene)
        local row = batch.rays[ray_index(plan, "rear_left", "center")]
        row.normal = row.normal * .995
        check(Probe.decode(plan, batch).sites.rear_left.status == "edge", "a normal within float noise of unit is read")
        check(refused(function(row) row.position = row.position + vector.create(.05, 0, 0) end) == "inconsistent_hit",
            "a hit off its segment")
        check(refused(function(row) row.fraction = 1.5 end) == "malformed_row", "a fraction past the segment")
        check(refused(function(row) row.position = nil end) == "malformed_row", "a hit without a position")
        check(refused(function(row) row.status = "maybe" end) == "malformed_row", "an unknown status")
    end)
    case("default probe rows without normals are refused", function()
        local body = pose()
        local out = probe(body, { rail(underside(body, "rear_left"), { 0, 0, 1 }, .025), ground }, { no_normals = true })
        check(out.sites.rear_left.reason == "normal_unavailable" and out.sites.front_left.reason == "normal_unavailable",
            "probe_batch without require_contact cannot classify an edge")
        check(out.sites.front_right.status == "none", "a site whose rays are all clear needs no normals")
    end)

    -- Round rails --------------------------------------------------------------
    case("double peg on a straight round rail", function()
        local body = pose()
        local out = probe(body, { rail(underside(body, "rear_left"), { 0, 0, 1 }, .025), ground })
        for _, name in ipairs({ "front_left", "rear_left" }) do
            local e = out.sites[name]
            check(e.status == "edge" and e.class == "round_rail" and e.axis == "forward", name .. " sees a round rail")
            check(vnear(e.tangent, { 0, 0, 1 }, 1e-6) and vnear(e.normal, { 0, 1, 0 }, 1e-6), name .. " tangent and normal")
            check(near(e.separation, 0, 1e-5) and vnear(e.point, underside(body, name), 1e-5), name .. " rests on the crest")
            check(e.edge_end == "none" and e.tangent_source == "along_samples" and e.crest_observed == false,
                name .. ": a centred straight rail shows no curvature to fit")
            touching_row(out.contacts.pegs[name], name)
        end
        for _, name in ipairs({ "front_right", "rear_right" }) do
            check(out.sites[name].status == "none" and out.sites[name].class == "clear", name .. " is clear")
            check(equal(out.contacts.pegs[name], { available = true, touching = false }), name .. " clear row")
        end
        check(equal(out.contacts.tires.front, { available = true, touching = false })
            and equal(out.contacts.tires.rear, { available = true, touching = false }), "both tires are clear")
        local judged = Grind.evaluate({ body = body, contacts = out.contacts, ground_support = false })
        check(judged.issue == "none" and judged.grind == "double_peg" and judged.side == "left",
            "grind_policy reads the probe rows as a left double peg")
        local solved = Contact.solve(body, out.contacts.pegs.rear_left, { 0, -9.8, 0 }, 1 / 60)
        check(solved.valid and solved.active and solved.force[2] > 0, "grind_contact supports the bike on the probed row")
    end)
    case("a rail crossed at a yaw is fitted from its normals", function()
        for _, setup in ipairs({ { yaw = .3, offset = 0 }, { yaw = -.5, offset = .01 }, { yaw = .65, offset = -.008 } }) do
            local body = pose()
            local direction = { math.sin(setup.yaw), 0, math.cos(setup.yaw) }
            local crest = M.add(underside(body, "rear_left"), { setup.offset, 0, 0 })
            local out = probe(body, { rail(crest, direction, .025), ground })
            local e = out.sites.rear_left
            check(e.status == "edge" and e.class == "round_rail" and e.tangent_source == "normal_fit", "fitted round rail")
            check(M.dot(e.tangent, direction) >= math.cos(1e-3), "the tangent follows the rail, not the bike")
            check(near(e.radius, .025, 1e-4) and e.crest_observed, "the radius is recovered")
            -- The crest line is level here, so every crest point has the crest height.
            local off = M.sub(e.point, crest)
            check(near(off[2], 0, 1e-4) and M.length(M.sub(off, M.mul(direction, M.dot(off, direction)))) <= 1e-4,
                "the contact point lies on the crest line")
            check(near(e.separation, 0, 1e-4) and vnear(e.normal, { 0, 1, 0 }, 1e-4), "crest separation and normal")
            check(math.abs(M.dot(e.normal, e.tangent)) <= 1e-9, "the row passes grind_contact's orthogonality check")
            touching_row(out.contacts.pegs.rear_left, "yawed")
            check(out.sites.front_left.status == "none", "the front peg is off a rail crossed at a yaw")
        end
    end)
    case("an off-centre rail and a fat pipe", function()
        local body = pose()
        local crest = M.add(underside(body, "rear_left"), { .012, 0, 0 })
        local e = probe(body, { rail(crest, { 0, 0, 1 }, .025), ground }).sites.rear_left
        local drop = .025 - math.sqrt(.025 * .025 - .012 * .012)
        check(e.class == "round_rail" and e.crest_observed == false and vnear(e.tangent, { 0, 0, 1 }, 1e-6),
            "an off-centre straight rail is still a round rail")
        check(near(e.separation, drop, 1e-5) and vnear(e.normal, { 0, 1, 0 }, 1e-6),
            "without a radius the separation is measured at the centre hit")
        crest = M.add(underside(body, "rear_left"), { .01, 0, 0 })
        e = probe(body, { rail(crest, { 0, 0, 1 }, .08), ground }).sites.rear_left
        check(e.class == "round_rail" and e.crest_observed and near(e.radius, .08, 1e-4),
            "a pipe wider than the peg shows its radius on the flank rays")
        check(vnear(e.point, crest, 1e-4) and near(e.separation, 0, 1e-4), "and the crest is recovered")
    end)
    case("the normal fit is refused outside its guards", function()
        local body = pose()
        local direction = { math.sin(.3), 0, math.cos(.3) }
        local scene = { rail(underside(body, "rear_left"), direction, .025), ground }
        local e = probe(body, scene, { plan = { settings = { max_radius = .02 } } }).sites.rear_left
        check(e.status == "edge" and e.class == "round_rail" and e.tangent_source == "along_samples" and e.radius == nil,
            "a fitted radius above max_radius is not used")
        -- A centre normal leaning 0.1 rad along the rail fits no cylinder
        -- through the along samples, so the fit is not trusted.
        local plan = assert(Probe.plan(body))
        local batch = batch_for(plan, scene)
        local row = batch.rays[ray_index(plan, "rear_left", "center")]
        local lean = M.add(M.mul({ 0, 1, 0 }, math.cos(.1)), M.mul(direction, math.sin(.1)))
        row.normal = vector.create(lean[1], lean[2], lean[3])
        e = Probe.decode(plan, batch).sites.rear_left
        check(e.status == "edge" and e.class == "round_rail" and e.tangent_source == "along_samples",
            "a centre normal off the fitted axis is not used")
    end)
    case("a fitted tangent is turned to run with the bike", function()
        -- Coping yawed so its raw fitted direction leans backward.
        local body = pose({ anchor = "front", velocity = { 0, 0, 0 } })
        local direction = { math.cos(.2), 0, -math.sin(.2) }
        local e = probe(body, { rail(underside(body, "front"), direction, .03), ground }).sites.front
        check(e.status == "edge" and e.class == "round_rail" and e.axis == "lateral" and e.tangent_source == "normal_fit",
            "yawed coping is fitted across the bike")
        check(M.dot(e.tangent, M.mul(direction, -1)) >= math.cos(1e-3) and e.tangent[3] > 0,
            "the tangent is flipped to point with the bike")
        check(near(e.separation, 0, 1e-4) and vnear(e.normal, { 0, 1, 0 }, 1e-4), "the crest is still found")
    end)
    case("inclined rails", function()
        local body = pose()
        local direction = { 0, -math.sin(.5), math.cos(.5) }
        local e = probe(body, { rail(underside(body, "rear_left"), direction, .025), ground }).sites.rear_left
        check(e.class == "round_rail" and M.dot(e.tangent, direction) >= math.cos(1e-5) and near(e.incline, .5, 1e-5),
            "a handrail's incline is measured along its crest")
        check(math.abs(M.dot(e.normal, e.tangent)) <= 1e-9 and near(e.normal[2], math.cos(.5), 1e-5),
            "the crest normal is square to the inclined rail")
        -- The peg sits with its underside straight above the crest, so its axis
        -- is r cos(0.5) from the inclined crest line: it is pressed in.
        local r = Pegs.peg("rear_left").radius
        check(near(e.separation, r * (math.cos(.5) - 1), 1e-5), "separation is measured along the crest normal")
        local steep = { 0, -math.sin(1.2), math.cos(1.2) }
        e = probe(body, { rail(underside(body, "rear_left"), steep, .025), ground }).sites.rear_left
        check(e.status == "unavailable" and e.reason == "edge_incline", "a rail steeper than max_incline is not offered")
    end)
    case("rail end and moving rails", function()
        local body = pose()
        local peg = underside(body, "rear_left")
        -- The rail ends 15 mm ahead of the rear peg, short of its ahead ray.
        local out = probe(body, { rail(peg, { 0, 0, 1 }, .025, { length = 1, back = .985 }), ground })
        local e = out.sites.rear_left
        check(e.status == "edge" and e.edge_end == "ahead" and vnear(e.tangent, { 0, 0, 1 }, 1e-6),
            "the end is reported and the tangent comes from the remaining pair")
        check(out.sites.front_left.status == "none", "past the end the front peg is clear")
        out = probe(body, { rail(peg, { 0, 0, 1 }, .025, { velocity = { 0, 0, 3 } }), ground })
        check(vnear(out.contacts.pegs.rear_left.surface_velocity, { 0, 0, 3 }, 1e-6), "the rail's measured motion is carried")
        out = probe(body, { rail(peg, { 0, 0, 1 }, .025), ground }, { unknown_motion = true })
        check(out.sites.rear_left.status == "edge" and out.sites.rear_left.motion == "unknown",
            "geometry is still estimated without measured motion")
        check(equal(out.contacts.pegs.rear_left, { available = false }), "but unknown motion never becomes a contact")
    end)

    -- Ledges and coping --------------------------------------------------------
    case("double peg on a ledge", function()
        local body = pose()
        local center = site_center(body, "rear_left")
        local lip = center[1] - .03 -- between the centre ray and the inner end ray
        local box = { kind = "box", center = { lip + .5, .5, 0 }, half = { .5, .5, 5 } }
        local out = probe(body, { box, ground })
        for _, name in ipairs({ "front_left", "rear_left" }) do
            local e = out.sites[name]
            check(e.status == "edge" and e.class == "ledge" and e.drop_side == "right", name .. " sees a ledge dropping inward")
            check(vnear(e.tangent, { 0, 0, 1 }, 1e-6) and vnear(e.normal, { 0, 1, 0 }, 1e-6), name .. " ledge frame")
            check(near(e.lateral_uncertainty, Pegs.length / 4, 1e-9) and near(e.point[1], center[1] - Pegs.length / 4, 1e-5),
                name .. ": the lip is placed mid-way to the dropped ray")
            check(near(e.separation, 0, 1e-5), name .. " rests on the top")
            touching_row(out.contacts.pegs[name], name)
        end
        check(out.sites.front.status == "none" and out.sites.rear.status == "none", "the tires hang clear beside the box")
        local judged = Grind.evaluate({ body = body, contacts = out.contacts, ground_support = false })
        check(judged.issue == "none" and judged.grind == "double_peg" and judged.side == "left",
            "grind_policy reads the ledge rows as a left double peg")
    end)
    case("tire stall on coping square to the bike", function()
        local body = pose({ anchor = "front", velocity = { 0, 0, 0 } })
        local out = probe(body, { rail(underside(body, "front"), { 1, 0, 0 }, .03), ground })
        local e = out.sites.front
        check(e.status == "edge" and e.class == "round_rail" and e.axis == "lateral", "the coping runs across the bike")
        check(vnear(e.tangent, { 1, 0, 0 }, 1e-6) and vnear(e.normal, { 0, 1, 0 }, 1e-6) and near(e.separation, 0, 1e-5),
            "a square edge takes the rider-left sign")
        touching_row(out.contacts.tires.front, "coping")
        local peg = out.sites.front_left
        check(peg.status == "edge" and peg.separation > .2, "the front pegs see the same coping well below them")
        local judged = Grind.evaluate({ body = body, contacts = out.contacts, ground_support = false })
        check(judged.issue == "none" and judged.grind == "tire_stall", "grind_policy reads a tire stall")
    end)

    -- Surfaces that are not edges ------------------------------------------------
    case("flat and banked ground are not edges", function()
        local body = pose({ anchor = "rear", at = { 0, 0, 0 } })
        local out = probe(body, { ground })
        for _, name in ipairs(Probe.sites()) do
            check(out.sites[name].status == "none" and out.sites[name].class == "flat", name .. " reads flat ground")
        end
        check(equal(out.contacts.tires.rear, { available = true, touching = false }), "riding on the ground is not a rail contact")
        local bank = { kind = "plane", point = { 0, 0, 0 }, normal = { math.sin(.26), math.cos(.26), 0 } }
        out = probe(body, { bank })
        check(out.sites.rear.class == "flat" and out.sites.front.class == "flat", "a 15 degree bank is still flat")
    end)
    case("irregular surfaces near a site are unavailable, far ones are clear", function()
        local body = pose()
        local center = site_center(body, "rear_left")
        local function scene(height)
            return { { kind = "plane", point = { 0, height, 0 }, normal = { 0, 1, 0 } },
                { kind = "box", center = { center[1] + .03 + .5, height, 0 }, half = { .5, .05, 5 } } }
        end
        local out = probe(body, scene(1))
        check(out.sites.rear_left.status == "unavailable" and out.sites.rear_left.reason == "irregular_surface",
            "a step up beside the peg is not read as clear")
        check(out.contacts.pegs.rear_left.available == false, "so its row is unavailable")
        out = probe(body, scene(.85))
        check(out.sites.rear_left.status == "none" and out.sites.rear_left.class == "far", "the same shape far below is clear")
    end)
    case("a surface under only a peg end is unavailable, not clear", function()
        local body = pose()
        local plan = assert(Probe.plan(body))
        local outer = plan.rays[ray_index(plan, "rear_left", "left")]
        local function thin(drop)
            return { rail({ outer.from.x, underside(body, "rear_left")[2] - drop, outer.from.z }, { 0, 0, 1 }, .01) }
        end
        local out = probe(body, thin(0))
        check(out.sites.rear_left.status == "unavailable" and out.sites.rear_left.reason == "unclassified_surface",
            "a thin rail under the outer end with the centre ray clear is unclassified")
        check(equal(out.contacts.pegs.rear_left, { available = false }), "so its row is unavailable")
        check(select(2, Grind.contact(out.contacts.pegs.rear_left)) == "unavailable_contact",
            "and grind_policy does not read it as clear")
        out = probe(body, thin(.2))
        check(out.sites.rear_left.status == "none" and out.sites.rear_left.class == "clear"
            and equal(out.contacts.pegs.rear_left, { available = true, touching = false }),
            "the same rail beyond the proximity is clear")
    end)
    case("surfaces between flat and an edge are irregular", function()
        local body = pose()
        local center, bottom = site_center(body, "rear_left"), underside(body, "rear_left")[2]
        local function judged(scene, why)
            local e = probe(body, scene).sites.rear_left
            check(e.status == "unavailable" and e.reason == "irregular_surface", why)
        end
        -- A top under the centre and inner end ray, with the outer end ray on a
        -- surface 15 mm away: more than the level tolerance, less than a step.
        local top = { kind = "box", center = { center[1] + .03 - .5, bottom - .5, 0 }, half = { .5, .5, 5 } }
        judged({ top, { kind = "plane", point = { 0, bottom - .015, 0 }, normal = { 0, 1, 0 } } }, "a 15 mm step down")
        judged({ top, { kind = "box", center = { center[1] + .03 + .5, bottom + .015 - .5, 0 }, half = { .5, .5, 5 } } },
            "a 15 mm step up")
        -- A 180 mm pipe tilts 0.3 rad under the end rays but drops only 8 mm.
        judged({ rail(underside(body, "rear_left"), { 0, 0, 1 }, .18) }, "a curve too shallow to fall away")
        -- A rail with a block on it 20 mm ahead of the peg: the ahead ray rises.
        local crest = underside(body, "rear_left")
        judged({ rail(crest, { 0, 0, 1 }, .025),
            { kind = "box", center = { crest[1], crest[2] + .03 - .05, crest[3] + .12 }, half = { .02, .05, .1 } } },
            "an along sample that rises")
        -- A post narrower than every offset: only the centre ray meets it.
        judged({ { kind = "box", center = { crest[1], crest[2] - .5, crest[3] }, half = { .012, .5, .012 } } },
            "both along samples away")
    end)

    -- Row forms and determinism ------------------------------------------------
    case("copied 3-array rows decode exactly like vector rows", function()
        local body = pose()
        local plan = assert(Probe.plan(body))
        local batch = batch_for(plan, { rail(underside(body, "rear_left"), { .2, 0, 1 }, .025), ground })
        -- Contact.decode moves the batch's exclusion facts under query.
        local copied = { valid = true, status = "available", rays = {}, query = { epoch_matches = true,
            accounting_known = true, budget_exhausted = false, local_actor_excluded = true, owned_bodies_excluded = true } }
        for i, row in ipairs(batch.rays) do
            if row.status == "clear" then
                -- contact_runtime.lua's clear rows carry flags but no geometry.
                copied.rays[i] = { status = "clear", visual_hit = false, normal_available = false,
                    surface_velocity_available = false, motion = "unknown", position = vector.create(9, 9, 9) }
            else
                local r = table.clone(row)
                for _, key in ipairs({ "position", "normal", "surface_velocity" }) do
                    r[key] = { row[key].x, row[key].y, row[key].z }
                end
                copied.rays[i] = r
            end
        end
        local a, b = Probe.decode(plan, batch), Probe.decode(plan, copied)
        check(equal(a, b), "the decode does not depend on the row form or clear-row garbage")
        check(equal(a, Probe.decode(plan, batch)), "decoding is deterministic")
        check(not pcall(function() a.contacts.pegs.rear_left.separation = 1 end), "results are frozen")
    end)

    -- grind_contact: observed_grind_contract ------------------------------------
    local function rail_body()
        return { mass = 100, inertia_body = { 25, 30, 20 }, orientation = { 0, 0, 0, 1 }, center_of_mass = { 0, 1, 0 },
            linear_velocity = { 0, 0, 5 }, angular_velocity = { 0, 0, 0 } }
    end
    local function rail_contact(body)
        return { available = true, touching = true, point = M.copy(body.center_of_mass), normal = { 0, 1, 0 },
            tangent = { 0, 0, 1 }, separation = 0, surface_velocity = { 0, 0, 0 }, friction = .12 }
    end
    local function zero(r) return M.length(r.force) == 0 and M.length(r.torque) == 0 end
    case("observed grind contract", function()
        local body = rail_body()
        local c = rail_contact(body)
        local solved = Contact.solve(body, c)
        check(solved.valid and solved.active, "observed rail contact supports load")
        check(near(solved.force[2], 980, 1e-8), "rail support balances measured mass times gravity")
        check(solved.speed >= 0 and solved.speed < 5 and solved.force[3] < 0, "rail friction dissipates forward slip without reversal")
        check(near(solved.force[3], -.12 * 980, 1e-8), "sliding friction is the Coulomb limit")
        local moving = rail_body(); moving.linear_velocity[3] += 3
        local platform = rail_contact(body); platform.surface_velocity[3] = 3
        local shifted = Contact.solve(moving, platform)
        check(shifted.valid and near(shifted.speed, solved.speed, 1e-10) and vnear(shifted.force, solved.force, 1e-9),
            "rail response invariant to common platform velocity")
        c.available = false
        local unavailable = Contact.solve(body, c)
        check(not unavailable.valid and zero(unavailable), "unavailable rail contact cannot apply forces")
        c.available, c.touching = true, false
        local missing = Contact.solve(body, c)
        check(missing.valid and not missing.active and zero(missing), "missing rail cannot attract bike")
        c.touching, c.separation = true, .05
        local apart = Contact.solve(body, c)
        check(apart.valid and not apart.active and zero(apart), "separated rail cannot snap bike")
        c.separation, c.surface_velocity, body.linear_velocity = 0, { 0, 0, 0 }, { 0, 0, .001 }
        local stop = Contact.solve(body, c)
        check(stop.valid and math.abs(stop.speed) < 1e-10, "rail friction clamps at zero rather than reversing")
        local clear = Contact.solve(rail_body(), { available = true, touching = false })
        check(clear.valid and not clear.active and zero(clear), "a grind_policy clear row solves as a default contact")
        local lifting = rail_body(); lifting.linear_velocity = { 0, 1, 0 }
        local away = Contact.solve(lifting, rail_contact(lifting))
        check(away.valid and not away.active and zero(away), "the rail never pulls a bike moving away")
    end)
    case("explicit clock", function()
        local body = { mass = 100, inertia_body = { 1, 1, 1 }, orientation = { 0, 0, 0, 1 }, center_of_mass = { 0, 1, 0 },
            linear_velocity = { 0, 0, 0 }, angular_velocity = { 0, 0, 0 } }
        local c = rail_contact(body)
        local r = Contact.solve(body, c, { 0, -12.5, 0 }, .01)
        check(r.valid and near(r.force[2], 1250, 1e-8) and near(r.normal_impulse, 12.5, 1e-8),
            "100Hz rail impulse and force use the same explicit clock")
        for _, seconds in ipairs({ 0, -.01, .001, .1, 0 / 0 }) do
            check(not Contact.solve(body, c, { 0, -12.5, 0 }, seconds).valid, "rail solver rejects invalid timestep")
        end
        check(Contact.solve(body, c, nil, 1 / 240).valid and Contact.solve(body, c, nil, 1 / 30).valid,
            "both timestep bounds are inclusive")
        check(not Contact.solve(body, c, { 0, -101, 0 }).valid, "gravity is bounded like grind.cpp")
    end)
    case("validity checks", function()
        local body = rail_body()
        local function with(field, value)
            local c = rail_contact(body); c[field] = value
            return Contact.solve(body, c)
        end
        check(with("tangent", { 0, 5e-4, 1 }).valid, "a tangent within 1e-3 of square to the normal is accepted")
        check(not with("tangent", { 0, 2e-3, 1 }).valid, "a tangent leaning into the normal is refused")
        check(not with("normal", { 0, 0, 0 }).valid, "a zero normal is refused")
        check(with("friction", 0).valid and with("friction", 10).valid, "friction 0 and 10 are accepted")
        check(not with("friction", -.01).valid and not with("friction", 10.01).valid, "friction outside 0..10 is refused")
        local frictionless = with("friction", 0)
        check(frictionless.force[3] == 0 and near(frictionless.speed, 5, 1e-12), "zero friction removes no slip")
        check(not with("touching", "yes").valid and not with("separation", 1 / 0).valid, "malformed fields are refused")
        check(not with("point", { 2e6, 0, 0 }).valid and not with("surface_velocity", { 2e5, 0, 0 }).valid,
            "the point and surface velocity bounds of grind.cpp")
        local light = rail_body(); light.mass = 0
        check(not Contact.solve(light, rail_contact(light)).valid, "a massless body is refused")
        local skewed = rail_body(); skewed.inertia_orientation = { 0, 0, 0, 2 }
        check(not Contact.solve(skewed, rail_contact(skewed)).valid, "a non-unit inertia frame is refused")
        -- A principal frame turned 90 degrees about Y swaps the X and Z moments.
        local turned = rail_body(); turned.inertia_orientation = qaxis({ 0, 1, 0 }, math.pi / 2)
        local swapped = rail_body(); swapped.inertia_body = { 20, 30, 25 }
        local c = rail_contact(turned); c.point = { .3, .8, -.2 }
        local a, b = Contact.solve(turned, c), Contact.solve(swapped, c)
        check(a.valid and vnear(a.force, b.force, 1e-9) and vnear(a.torque, b.torque, 1e-9),
            "inertia_orientation enters as the C++ principal frame")
    end)
    case("penetration window, surface motion and impulse order", function()
        local body = rail_body()
        local deep = rail_contact(body); deep.separation = -.04
        local buried = Contact.solve(body, deep)
        check(buried.valid and not buried.active and zero(buried), "a rail 40 mm into the peg is valid and inactive")
        deep.separation = -.029
        check(Contact.solve(body, deep).active, "a rail 29 mm in is still inside grind.cpp's 30 mm window")
        local far = rail_contact(body); far.touching, far.point = false, { 2e6, 0, 0 }
        check(not Contact.solve(body, far).valid, "the point bound refuses even a contact that is not touching")
        -- Surface motion along the normal: a rising platform carrying the bike
        -- is the same contact as still ground under a bike at rest vertically.
        local still = Contact.solve(body, rail_contact(body))
        local riding = rail_body(); riding.linear_velocity = { 0, 1, 5 }
        local lift = rail_contact(riding); lift.surface_velocity = { 0, 1, 0 }
        local lifted = Contact.solve(riding, lift)
        check(lifted.valid and lifted.active and vnear(lifted.force, still.force, 1e-9) and near(lifted.speed, still.speed, 1e-10),
            "a rising platform supports the bike as still ground does")
        -- A slip small enough that friction is not at its Coulomb limit, on a
        -- moving surface: friction stops the slip relative to that surface.
        local creeping = rail_body(); creeping.linear_velocity = { 0, 0, 3.001 }
        local belt = rail_contact(creeping); belt.surface_velocity = { 0, 0, 3 }
        local held = Contact.solve(creeping, belt)
        check(held.valid and held.active and math.abs(held.speed) < 1e-10 and near(held.friction_impulse, -.1, 1e-9),
            "friction removes slip relative to the moving surface, not to the world")
        -- A contact below and ahead of the centre of mass: the normal impulse
        -- spins the body and so makes slip along the rail, which the friction
        -- solve must see. Rigid-body arithmetic for this arm and inertia:
        local pivot = rail_body(); pivot.linear_velocity = { 0, 0, 0 }
        local arm = rail_contact(pivot); arm.point, arm.friction = { 0, .5, .3 }, 1
        local push = (9.8 / 60) / (1 / 100 + .3 * .3 / 25)
        local slip = .5 * .3 * push / 25
        local turned = Contact.solve(pivot, arm)
        check(turned.valid and turned.active and near(turned.normal_impulse, push, 1e-9), "the normal impulse at an arm")
        check(near(turned.friction_impulse, -slip / (1 / 100 + .5 * .5 / 25), 1e-9) and math.abs(turned.speed) < 1e-10,
            "friction removes the slip the normal impulse made")
    end)
    case("force and torque caps refuse rather than clip", function()
        local body = rail_body(); body.linear_velocity = { 0, -10, 0 }
        local hard = Contact.solve(body, rail_contact(body))
        check(not hard.valid and not hard.active and zero(hard) and hard.normal_impulse == 0, "a slam over 40000 N is refused")
        body.linear_velocity = { 0, -6, 0 }
        local firm = Contact.solve(body, rail_contact(body))
        check(firm.valid and firm.active and near(firm.force[2], 36980, 1e-6), "a 36980 N stop is under the cap")
        local wide = { mass = 100, inertia_body = { 1000, 1000, 1000 }, orientation = { 0, 0, 0, 1 },
            center_of_mass = { 0, 1, 0 }, linear_velocity = { 0, -2, 0 }, angular_velocity = { 0, 0, 0 } }
        local c = rail_contact(wide); c.point = { 1, 1, 0 }
        local twisted = Contact.solve(wide, c)
        check(not twisted.valid and zero(twisted), "an 11800 N m torque over a 1 m arm is refused")
        wide.linear_velocity = { 0, -.3, 0 }
        local gentle = Contact.solve(wide, c)
        check(gentle.valid and gentle.active and M.length(gentle.torque) < 4000 and gentle.torque[3] > 0,
            "the same arm under 4000 N m is accepted")
    end)
    return { cases = cases, assertions = assertions, constructed = true, native_authority = false, gameplay = false }
end
return Tests

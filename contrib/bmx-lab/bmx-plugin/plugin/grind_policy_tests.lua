-- Constructed poses and contact rows exercise the authored grind policy and
-- peg geometry only. They are not rail-probe output, native contacts or
-- in-game evidence. No code below executes on require; run() is the entry.
local Grind = require("./grind_policy")
local Pegs = require("./peg_geometry")
local G = require("./bike_geometry")
local M = require("./force_math")
local Tests = {}
local H = .01666666567325592
-- The top of a round rail one metre up, running along world +Z.
local rail_point = { 0, 1, 0 }

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
-- yaw + turns the nose left, pitch + lifts the nose, roll + leans right. The
-- body is placed so the anchor peg's underside sits on rail_point.
local function pose(o)
    o = o or {}
    local q = qmul(qaxis({ 0, 1, 0 }, o.yaw or 0), qmul(qaxis({ 1, 0, 0 }, -(o.pitch or 0)), qaxis({ 0, 0, 1 }, o.roll or 0)))
    local body = { orientation = q, center_of_mass = { 0, 0, 0 },
        linear_velocity = { 0, -(o.closing or 1), o.speed or 4 }, angular_velocity = o.omega or { 0, 0, 0 } }
    local peg = Pegs.peg(o.anchor or "rear_left")
    body.center_of_mass = M.add(M.sub(rail_point, Pegs.to_world(body, peg.center)), { 0, peg.radius, 0 })
    return body
end
local function clear() return { available = true, touching = false } end
local function row(point)
    return { available = true, touching = true, point = point, normal = { 0, 1, 0 }, tangent = { 0, 0, 1 },
        separation = 0, surface_velocity = { 0, 0, 0 }, friction = .12 }
end
local function peg_row(body, name)
    local peg = Pegs.peg(name)
    return row(M.sub(Pegs.to_world(body, peg.center), { 0, peg.radius, 0 }))
end
local function tire_row(body, name)
    local axle = name == "front" and G.front_axle or G.rear_axle
    return row(M.sub(Pegs.to_world(body, axle), { 0, G.wheel_radius, 0 }))
end
local function observe(body, touching, o)
    o = o or {}
    local contacts = { pegs = {}, tires = { front = clear(), rear = clear() } }
    for _, name in ipairs(Pegs.names()) do contacts.pegs[name] = clear() end
    for _, name in ipairs(touching or {}) do
        if name == "front_tire" then contacts.tires.front = tire_row(body, "front")
        elseif name == "rear_tire" then contacts.tires.rear = tire_row(body, "rear")
        else contacts.pegs[name] = peg_row(body, name) end
    end
    return { seconds = o.seconds or H, body = body, ground_support = o.ground == true, contacts = contacts,
        input = { enabled = o.enabled ~= false, lean = o.lean or 0, hop = o.hop == true } }
end
local double_left = { "rear_left", "front_left" }

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
    local function lock(c, body, touching, o)
        c:step(observe(body, {}, { hop = o and o.hop, lean = o and o.lean }))
        return c:step(observe(body, touching, o))
    end
    local function run_steps(c, count, body, touching, o)
        local last
        for _ = 1, count do last = c:step(observe(body, touching, o)) end
        return last
    end

    case("peg geometry is four authored pegs on the bike_geometry axles", function()
        local names = Pegs.names()
        check(equal(names, { "front_left", "front_right", "rear_left", "rear_right" }), "fixed peg order")
        check(near(Pegs.length, .14 * G.scale) and near(Pegs.radius, .0245 * G.scale)
            and near(Pegs.inner_offset, .065 * G.scale), "pegs use bike_geometry's scale")
        for _, name in ipairs(names) do
            local peg = Pegs.peg(name)
            local axle = peg.axle == "front" and G.front_axle or G.rear_axle
            check(peg.center[2] == axle[2] and peg.center[3] == axle[3], "peg is coaxial with its axle " .. name)
            check((peg.side == "left") == (peg.center[1] > 0), "+X is rider left " .. name)
            check((peg.axle == "front") == (peg.center[3] > 0), "+Z is forward " .. name)
            check(near(math.abs(peg.center[1]), Pegs.inner_offset + Pegs.length / 2), "centre is mid-peg " .. name)
            check(near(math.abs(peg.outer[1]) - math.abs(peg.inner[1]), Pegs.length), "inner to outer is the peg length " .. name)
            check(peg.axis[1] == Pegs.side_sign(peg.side) and peg.axis[2] == 0 and peg.axis[3] == 0, "axis points outward " .. name)
        end
        check(Pegs.peg("front_left").center[1] == -Pegs.peg("front_right").center[1], "left and right mirror")
        local copy = Pegs.peg("rear_left") copy.center[1] = 99 names[1] = "moved"
        check(Pegs.peg("rear_left").center[1] ~= 99 and Pegs.names()[1] == "front_left", "readback is detached")
        check(Pegs.peg("nose") == nil, "unknown peg is nil")
    end)
    case("peg frame transforms and relation", function()
        local identity = { orientation = { 0, 0, 0, 1 }, center_of_mass = M.copy(G.com) }
        local peg = Pegs.peg("front_right")
        check(vnear(Pegs.to_world(identity, peg.center), peg.center), "authored COM at its own place is the bike frame")
        local body = pose({ yaw = .4, pitch = -.3, roll = .2 })
        local world = Pegs.to_world(body, peg.outer)
        check(vnear(Pegs.to_local(body, world), peg.outer, 1e-12), "world and bike frame round trip")
        check(vnear(Pegs.world(body).front_right.outer, world), "world() matches to_world")
        check(near(M.length(Pegs.world(body).front_right.axis), 1), "world axis stays unit")
        local under = M.sub(peg.center, { 0, peg.radius, 0 })
        local r = Pegs.relation("front_right", under)
        check(near(r.surface_offset, 0) and r.edge_offset == 0, "underside sits on the peg")
        r = Pegs.relation("front_right", M.add(peg.outer, { -.01, 0, 0 }))
        check(near(r.edge_offset, .01) and near(r.axial, Pegs.outer_offset + .01), "past the outer end by 1 cm")
        r = Pegs.relation("front_right", M.add(peg.inner, { .01, 0, 0 }))
        check(near(r.edge_offset, .01), "inside the inner face by 1 cm")
        check(Pegs.relation("front_right", { 0 / 0, 0, 0 }) == nil, "non-finite point has no relation")
    end)

    case("double peg on both sides", function()
        local out = lock(Grind.new(), pose(), double_left, {})
        check(out.valid and out.state == "locked" and out.grind == "double_peg" and out.side == "left", "left double peg")
        check(#out.events == 1 and out.events[1].name == "lock_on" and out.events[1].grind == "double_peg", "one lock_on event")
        check(out.refusal == "none" and out.exit_reason == "none" and out.bail_request == nil, "no refusal on lock")
        check(out.balance.tilt > .1 and out.balance.tilt < .2, "upright on a left rail the COM hangs right of it")
        out = lock(Grind.new(), pose({ anchor = "rear_right" }), { "rear_right", "front_right" }, {})
        check(out.grind == "double_peg" and out.side == "right" and out.balance.tilt < -.1, "right double peg mirrors")
    end)
    case("feeble, smith, icepick and toothpick", function()
        local out = lock(Grind.new(), pose({ yaw = .3 }), { "rear_left" }, {})
        check(out.grind == "feeble" and out.side == "left", "nose over a left rail is a feeble")
        out = lock(Grind.new(), pose({ yaw = -.3, anchor = "rear_right" }), { "rear_right" }, {})
        check(out.grind == "feeble" and out.side == "right", "mirrored feeble")
        out = lock(Grind.new(), pose(), { "rear_left", "front_tire" }, {})
        check(out.grind == "feeble", "front tire resting over the rail is a feeble")
        out = lock(Grind.new(), pose({ yaw = -.3 }), { "rear_left" }, {})
        check(out.grind == "smith" and out.side == "left", "nose dropped on the approach side is a smith")
        out = lock(Grind.new(), pose({ yaw = .3, anchor = "rear_right" }), { "rear_right" }, {})
        check(out.grind == "smith" and out.side == "right", "mirrored smith")
        out = lock(Grind.new(), pose({ pitch = .8 }), { "rear_left" }, {})
        check(out.grind == "icepick" and out.state == "locked", "rear peg nose high is an icepick")
        out = lock(Grind.new(), pose({ pitch = .8 }), { "rear_left", "front_tire" }, {})
        check(out.grind == "feeble", "a front tire on the rail is not an icepick")
        out = lock(Grind.new(), pose({ pitch = -.8, anchor = "front_left" }), { "front_left" }, {})
        check(out.grind == "toothpick" and out.side == "left", "front peg tail high is a toothpick")
        out = lock(Grind.new(), pose({ pitch = -.8, anchor = "front_left" }), { "front_left", "rear_tire" }, {})
        check(out.refusal == "unclassified", "a rear tire on the rail is not a toothpick")
    end)
    case("peg stall and tire stall", function()
        local out = lock(Grind.new(), pose({ speed = .3 }), double_left, {})
        check(out.state == "stalled" and out.grind == "peg_stall" and out.side == "left", "slow pegs lock straight into a stall")
        check(#out.events == 1 and out.events[1].state == "stalled", "one transition event")
        out = lock(Grind.new(), pose({ speed = -.3 }), { "rear_left" }, {})
        check(out.grind == "peg_stall", "a slow single peg of any shape stalls")
        out = lock(Grind.new(), pose({ speed = .2 }), { "front_tire" }, {})
        check(out.state == "stalled" and out.grind == "tire_stall" and out.side == "none", "slow tire on the edge is a tire stall")
        out = lock(Grind.new(), pose({ speed = .2, yaw = 1.3 }), { "front_tire" }, {})
        check(out.grind == "tire_stall", "tire stalls are not limited by approach yaw")
        local e = Grind.evaluate(observe(pose(), double_left))
        check(e.grind == "double_peg" and e.side == "left" and e.refusal == "none" and e.rail.kind == "pegs", "stateless evaluate")
        e = Grind.evaluate(observe(pose({ speed = .2 }), { "rear_tire" }))
        check(e.grind == "tire_stall" and e.rail.kind == "tires", "evaluate tire stall")
    end)

    case("refusals in order", function()
        local body = pose()
        local function refused(o, touching, why, settings)
            local out = lock(Grind.new(settings), o.body or body, touching or double_left, o)
            check(out.state == "idle" and out.grind == "none" and #out.events == 0, "refused stays idle: " .. why)
            check(out.refusal == why, "expected " .. why .. ", got " .. tostring(out.refusal))
            return out
        end
        local c = Grind.new()
        c:step(observe(body, {}, { ground = true }))
        check(c:step(observe(body, double_left)).refusal == "not_from_air", "riding into a rail from the ground")
        c = Grind.new()
        c:step(observe(body, {}))
        check(c:state().airborne_seen, "a clear step arms")
        local grounded = c:step(observe(body, {}, { ground = true }))
        check(grounded.refusal == "none" and not c:state().airborne_seen, "landing on the ground disarms")
        check(c:step(observe(body, double_left)).refusal == "not_from_air", "air, ground, then rolling onto a rail")
        c = Grind.new()
        c:step(observe(body, {}))
        check(c:step(observe(body, double_left, { ground = true })).refusal == "ground_supported", "wheels on the ground")
        check(c:step(observe(body, double_left)).refusal == "not_from_air", "ground support on the rail also disarms")
        refused({ body = pose({ yaw = .701 }) }, { "rear_left" }, "approach_yaw")
        check(lock(Grind.new(), pose({ yaw = .699 }), { "rear_left" }, {}).grind == "feeble", "just inside the yaw limit")
        refused({ body = pose({ closing = 6.001 }) }, nil, "closing_speed")
        check(lock(Grind.new(), pose({ closing = 5.999 }), double_left, {}).grind == "double_peg", "just inside the closing bound")
        refused({ body = pose({ closing = -.501 }) }, nil, "separating")
        check(lock(Grind.new(), pose({ closing = -.499 }), double_left, {}).grind == "double_peg", "just inside the opening bound")
        refused({}, { "rear_left" }, "unclassified")
        refused({}, { "front_left" }, "unclassified")
        refused({ body = pose({ speed = 4 }) }, { "front_tire" }, "unclassified")
        refused({}, { "rear_left", "rear_right" }, "mixed_peg_sides")
        local function edited(edit)
            local o = observe(body, double_left)
            edit(o.contacts.pegs.rear_left, o.contacts.pegs.front_left)
            local k = Grind.new()
            k:step(observe(body, {}))
            return k:step(o)
        end
        local half = Pegs.length / 2
        check(edited(function(r) r.point[1] += half + .026 end).refusal == "peg_edge_offset", "past the outer end")
        check(edited(function(r) r.point[1] -= half + .026 end).refusal == "peg_edge_offset", "inside the hub face")
        check(edited(function(r) r.point[1] += half + .024 end).grind == "double_peg", "just inside the edge tolerance")
        check(edited(function(r) r.point[2] -= .031 end).refusal == "peg_radial_offset", "a row off the peg's surface")
        check(edited(function(r) r.point[2] -= .029 end).grind == "double_peg", "just inside the radial tolerance")
        check(edited(function(_, f) f.tangent = { math.sin(.36), 0, math.cos(.36) } end).refusal == "rail_mismatch",
            "two pegs on different rails")
        check(edited(function(_, f) f.tangent = { math.sin(.34), 0, math.cos(.34) } end).grind == "double_peg",
            "a slight kink is one rail")
        check(edited(function(r, f)
            for _, x in ipairs({ r, f }) do x.tangent = { 0, math.sin(1.1), math.cos(1.1) } x.normal = { 0, math.cos(1.1), -math.sin(1.1) } end
        end).refusal == "rail_incline", "a rail steeper than the authored incline")
        -- Two tires on edges at different angles are not one edge either.
        local slow = pose({ speed = .2 })
        local function tires(angle)
            local o = observe(slow, { "front_tire", "rear_tire" })
            o.contacts.tires.rear.tangent = { math.sin(angle), 0, math.cos(angle) }
            return o
        end
        local k = Grind.new()
        k:step(observe(slow, {}))
        check(k:step(tires(.36)).refusal == "rail_mismatch", "two tires on different edges")
        check(Grind.evaluate(tires(.36)).refusal == "rail_mismatch", "evaluate refuses the same tire set")
        k = Grind.new()
        k:step(observe(slow, {}))
        check(k:step(tires(.34)).grind == "tire_stall", "two tires on one slightly kinked edge stall")
    end)
    case("admission window and closing history", function()
        local body = pose()
        local c = Grind.new()
        c:step(observe(body, {}))
        check(c:step(observe(body, { "rear_left" })).refusal == "unclassified", "rear peg lands first")
        local out = c:step(observe(body, double_left))
        check(out.grind == "double_peg" and out.state == "locked", "front peg lands inside the window")
        c = Grind.new()
        c:step(observe(body, {}))
        for i = 1, 7 do check(c:step(observe(body, { "rear_left" })).refusal == "unclassified", "inside window " .. i) end
        check(c:step(observe(body, { "rear_left" })).refusal == "admission_window", "window closes")
        check(c:step(observe(body, double_left)).refusal == "not_from_air", "a closed window needs air again")
        c = Grind.new()
        c:step(observe(body, {}))
        c:step(observe(pose({ closing = 7 }), { "rear_left" }))
        check(c:step(observe(body, double_left)).refusal == "closing_speed", "a slam cannot be hidden by waiting a step")
        -- A slam on a step refused for another reason is still on record.
        c = Grind.new()
        c:step(observe(body, {}))
        local slam = observe(pose({ closing = 9 }), double_left)
        slam.contacts.pegs.rear_left.point[1] += Pegs.length / 2 + .03
        check(c:step(slam).refusal == "peg_edge_offset", "the slam step is refused off the peg")
        check(c:step(observe(body, double_left)).refusal == "closing_speed", "a slam on a refused step still counts")
        -- The worst row of one step counts, not the gentlest: the front rail
        -- surface rises into its peg 1.5 m/s faster than under the rear.
        local function rising(closing, lift)
            local o = observe(pose({ closing = closing }), double_left)
            o.contacts.pegs.front_left.surface_velocity = { 0, lift, 0 }
            local k = Grind.new()
            k:step(observe(body, {}))
            return k:step(o), o
        end
        local out, o = rising(5, 1.5)
        check(out.refusal == "closing_speed", "one peg closing above the bound refuses")
        check(near(out.rail.closing, 6.5, 1e-9), "rail closing reports the worst rail row")
        check(Grind.evaluate(o).refusal == "closing_speed", "evaluate uses the same worst row")
        check(rising(-.6, .2).grind == "double_peg", "one rail row still pressing in is not separating")
        check(rising(-.6, -.2).refusal == "separating", "every rail row opening is separating")
        -- In a feeble the front tire is in contact but not a rail row; a tire
        -- slam beside a gentle peg still counts.
        o = observe(body, { "rear_left", "front_tire" })
        o.contacts.tires.front.surface_velocity = { 0, 6, 0 }
        check(Grind.evaluate(o).refusal == "closing_speed", "evaluate counts a non-rail row's slam")
        c = Grind.new()
        c:step(observe(body, {}))
        out = c:step(o)
        check(out.refusal == "closing_speed" and near(out.rail.closing, 1, 1e-9), "and so does the controller")
        o.contacts.tires.front.surface_velocity = { 0, 4, 0 }
        check(Grind.evaluate(o).grind == "feeble", "a firm tire inside the bound is a feeble")
    end)

    case("unavailable is never clear", function()
        local body = pose()
        local function with_unavailable(touching, name)
            local o = observe(body, touching)
            if name == "front" or name == "rear" then o.contacts.tires[name] = { available = false, touching = false }
            elseif name then o.contacts.pegs[name] = { available = false, touching = true } end
            return o
        end
        local c = Grind.new()
        c:step(observe(body, {}, { ground = true }))
        local held = c:step(with_unavailable({}, "front"))
        check(held.issue == "unavailable_contact" and held.state == "idle", "unavailable tire row reported")
        check(not c:state().airborne_seen, "an unavailable sample cannot prove air")
        check(c:step(observe(body, double_left)).refusal == "not_from_air", "so the next contact is not from air")
        c = Grind.new()
        c:step(observe(body, {}))
        c:step(with_unavailable({}, "rear_right"))
        check(c:step(observe(body, double_left)).refusal == "not_from_air", "unavailable disarms an armed approach")
        local o = observe(body, {})
        o.contacts.pegs.front_left = nil
        check(Grind.new():step(o).issue == "unavailable_contact", "a missing row is unavailable")
        o = observe(body, {})
        o.contacts.tires = nil
        check(Grind.new():step(o).issue == "unavailable_contact", "a missing tire set is unavailable")
        o = observe(body, double_left)
        o.contacts.pegs.rear_left.tangent = { 0, 1, 0 }
        check(Grind.new():step(o).issue == "invalid_contact", "tangent along the normal is malformed, not clear")
        for _, edit in ipairs({
            function(r) r.friction = 10.5 end, function(r) r.separation = 0 / 0 end,
            function(r) r.point = { 1e7, 0, 0 } end, function(r) r.normal = { 0, 0, 0 } end,
            function(r) r.available = "yes" end, function(r) r.separation = -.031 end,
        }) do
            o = observe(body, double_left)
            edit(o.contacts.pegs.rear_left)
            check(Grind.new():step(o).issue == "invalid_contact", "malformed touching row is a hold")
        end
        -- A clear row's leftover geometry is not read.
        c = Grind.new()
        o = observe(body, {})
        o.contacts.pegs.rear_left = { available = true, touching = false, point = "x", normal = { 0 / 0, 0, 0 }, separation = 0 / 0 }
        c:step(o)
        check(c:state().airborne_seen and c:step(observe(body, double_left)).grind == "double_peg", "clear garbage stays clear")
        o = observe(body, double_left)
        o.contacts.pegs.rear_left.separation = .006
        local e = Grind.evaluate(o)
        check(e.refusal == "unclassified", "a touching row past the contact gap is not a contact")
        e = Grind.evaluate(observe(body, {}))
        check(e.grind == "none" and e.refusal == "none" and e.issue == "none" and e.rail == nil, "evaluate in the air")
        e = Grind.evaluate(observe(body, {}, { ground = true }))
        check(e.refusal == "none", "riding on the ground away from any rail is not a refusal")
        -- A row deeper than max_penetration is malformed even where a locked
        -- grind would leave it out (the far-side peg here).
        c = Grind.new()
        lock(c, body, double_left, {})
        o = observe(body, double_left)
        o.contacts.pegs.rear_right = peg_row(body, "rear_right")
        o.contacts.pegs.rear_right.separation = -.05
        local held = c:step(o)
        check(held.state == "locked" and held.issue == "invalid_contact" and held.balance == nil,
            "a malformed far-side row holds the locked step")
    end)
    case("unavailable during a grind holds, then cancels without reading as rail end", function()
        local body = pose()
        local c = Grind.new()
        lock(c, body, double_left, {})
        local all = observe(body, {})
        for _, name in ipairs(Pegs.names()) do all.contacts.pegs[name] = { available = false, touching = false } end
        for i = 1, 5 do
            local out = c:step(all)
            check(out.state == "locked" and out.issue == "unavailable_contact" and #out.events == 0, "held " .. i)
            check(out.assist_torque == nil and out.balance == nil, "no request from unknown contact " .. i)
        end
        local out = c:step(all)
        check(out.state == "ended" and out.exit_reason == "contact_unavailable", "cancels after the authored hold")
        c = Grind.new()
        lock(c, body, double_left, {})
        c:step(observe(body, {}))
        for _ = 1, 5 do c:step(all) end
        check(c:step(observe(body, {})).state == "locked", "unavailable steps do not advance the rail-end timer")
        out = c:step(observe(body, {}))
        check(out.exit_reason == "rail_end", "only observed clear steps end the rail")
        -- Separate short holds do not add up across a long grind.
        c = Grind.new()
        lock(c, body, double_left, {})
        for _ = 1, 5 do c:step(all) end
        check(c:step(observe(body, double_left)).issue == "none" and c:state().unavailable_seconds == 0,
            "an available step resets the hold")
        for i = 1, 5 do check(c:step(all).state == "locked", "second hold " .. i) end
        check(c:step(all).exit_reason == "contact_unavailable", "a full hold still cancels")
    end)

    case("balance: lean input plus measured roll", function()
        local c = Grind.new()
        lock(c, pose(), double_left, {})
        local out = run_steps(c, 60, pose(), double_left, { lean = -1 })
        check(out.state == "locked" and out.bail_request == nil, "leaning into the rail holds")
        check(near(out.balance.effective, out.balance.tilt - Grind.settings().lean_authority), "lean moves the balance point")
        c = Grind.new()
        lock(c, pose(), double_left, {})
        for i = 1, 14 do check(c:step(observe(pose(), double_left, { lean = 1 })).state == "locked", "failing " .. i) end
        out = c:step(observe(pose(), double_left, { lean = 1 }))
        check(out.exit_reason == "bail" and out.bail_request.side == "right" and out.bail_request.reason == "balance_lost",
            "leaning off the rail for the authored time bails right")
        check(#out.events == 1 and out.events[1].name == "exit", "bail is one exit event")
        local rolled = pose({ roll = .35 })
        c = Grind.new()
        lock(c, pose(), double_left, {})
        out = c:step(observe(rolled, double_left))
        check(out.balance.roll > .3 and out.balance.tilt > Grind.settings().fail_angle, "measured roll right tips the COM over")
        out = run_steps(c, 60, rolled, double_left, { lean = -1 })
        check(out.state == "locked", "leaning left recovers a right roll")
        out = run_steps(c, 15, rolled, double_left, {})
        check(out.exit_reason == "bail", "the same roll without lean bails")
        c = Grind.new()
        lock(c, pose(), double_left, {})
        out = c:step(observe(pose({ roll = 1.2 }), double_left, { lean = -1 }))
        check(out.balance.effective > Grind.settings().hard_fail_angle, "even full counter-lean is past the hard limit")
        check(out.exit_reason == "bail" and out.bail_request.side == "right", "past the hard limit bails at once")
        check(c:state().bail_latched, "bail latches")
        check(lock(c, pose(), double_left, {}).refusal == "bail_latched", "no rail lock while the bail is pending")
        c:reset()
        check(lock(c, pose(), double_left, {}).grind == "double_peg", "reset clears the latch")
        out = lock(Grind.new(), pose(), double_left, { lean = 5 })
        check(out.balance.lean == 1, "lean is clamped to the stick range")
    end)
    case("exits: rail end, hop-out rearm, stall then exit, ground", function()
        local body = pose()
        local c = Grind.new()
        lock(c, body, double_left, {})
        check(c:step(observe(body, {})).state == "locked" and c:step(observe(body, {})).state == "locked", "short gaps hold")
        local out = c:step(observe(body, {}))
        check(out.state == "ended" and out.exit_reason == "rail_end" and out.grind == "double_peg", "rail end")
        check(c:state().phase == "idle" and not c:state().airborne_seen, "after an exit the next lock needs air again")
        check(c:step(observe(body, double_left)).refusal == "not_from_air", "no relock without a clear step")
        -- Separate short gaps do not add up to a rail end.
        c = Grind.new()
        lock(c, body, double_left, {})
        c:step(observe(body, {}))
        c:step(observe(body, {}))
        check(c:step(observe(body, double_left)).state == "locked" and c:state().contact_lost_seconds == 0,
            "contact again resets the gap")
        check(run_steps(c, 2, body, {}).state == "locked", "a second short gap holds")
        check(c:step(observe(body, {})).exit_reason == "rail_end", "a full gap still ends the rail")

        c = Grind.new()
        out = lock(c, body, double_left, { hop = true })
        check(out.state == "locked" and not c:state().hop_rearmed, "a held hop locks but is not rearmed")
        check(run_steps(c, 5, body, double_left, { hop = true }).state == "locked", "held hop never pops out")
        check(c:step(observe(body, double_left)).state == "locked", "release rearms")
        out = c:step(observe(body, double_left, { hop = true }))
        check(out.exit_reason == "hop_out" and out.hop_request, "fresh hop after neutral hops out")
        c = Grind.new()
        lock(c, body, double_left, {})
        out = c:step(observe(body, double_left, { hop = true }))
        check(out.exit_reason == "hop_out" and out.hop_request and #out.events == 1, "neutral at lock-on is already rearmed")

        c = Grind.new()
        lock(c, body, double_left, {})
        local slow = pose({ speed = .3 })
        out = c:step(observe(slow, double_left))
        check(out.state == "stalled" and out.grind == "peg_stall" and #out.events == 1 and out.events[1].name == "stalled"
            and out.events[1].from == "double_peg", "slowing below the stall speed stalls")
        for i = 1, 44 do check(c:step(observe(slow, double_left)).state == "stalled", "stall hold " .. i) end
        out = c:step(observe(slow, double_left))
        check(out.exit_reason == "stall_end" and out.grind == "peg_stall", "stall exits after the authored hold")
        c = Grind.new()
        lock(c, body, double_left, {})
        c:step(observe(slow, double_left))
        check(c:step(observe(pose(), double_left)).state == "stalled", "speeding up again does not unstall")

        c = Grind.new()
        lock(c, body, double_left, {})
        out = c:step(observe(body, double_left, { ground = true }))
        check(out.exit_reason == "grounded", "wheel ground support ends the grind")
        c = Grind.new()
        lock(c, pose({ speed = .2 }), { "front_tire" }, {})
        out = run_steps(c, 3, pose({ speed = .2 }), { "rear_left" }, {})
        check(out.exit_reason == "rail_end", "a tire stall ends when its tire leaves the edge")
    end)
    case("grind changes settle before switching", function()
        local c = Grind.new()
        lock(c, pose(), double_left, {})
        local feeble = pose({ yaw = .3 })
        for i = 1, 6 do
            local out = c:step(observe(feeble, { "rear_left" }))
            check(out.grind == "double_peg" and out.classified == "feeble" and #out.events == 0, "settling " .. i)
        end
        local out = c:step(observe(feeble, { "rear_left" }))
        check(out.grind == "feeble" and #out.events == 1 and out.events[1].name == "grind_changed"
            and out.events[1].from == "double_peg" and out.events[1].to == "feeble", "one change event")
        out = c:step(observe(pose(), { "rear_left" }))
        check(out.grind == "feeble" and out.classified == "none" and out.state == "locked", "an unclassified step keeps the type")
        out = c:step(observe(pose({ anchor = "rear_right" }), { "rear_right" }))
        check(out.state == "locked" and out.balance == nil, "a peg on the far side is not this grind's contact")
        -- A change must hold unbroken: a step of the current type restarts it.
        c = Grind.new()
        lock(c, pose(), double_left, {})
        run_steps(c, 3, feeble, { "rear_left" })
        out = c:step(observe(pose(), double_left))
        check(out.grind == "double_peg" and c:state().pending_grind == "none", "the current type clears a pending change")
        for i = 1, 6 do
            check(c:step(observe(feeble, { "rear_left" })).grind == "double_peg", "settling again " .. i)
        end
        out = c:step(observe(feeble, { "rear_left" }))
        check(out.grind == "feeble" and out.events[1].name == "grind_changed", "the full settle time from the restart")
    end)

    case("assist torque is optional, bounded and only a request", function()
        local body = pose({ yaw = .2 })
        local out = lock(Grind.new(), body, double_left, {})
        check(out.assist_torque == nil and not out.assist_limited, "assist is off by default")
        local c = Grind.new({ assist_enabled = true })
        out = lock(c, body, double_left, {})
        local t = c:settings()
        local expected = { 0, -t.assist_yaw_stiffness * (out.rail.yaw - t.assist_yaw_deadband), -t.assist_roll_stiffness * out.balance.effective }
        check(vnear(out.assist_torque, expected, 1e-9), "yaw outside the window and tilt are both restored")
        check(out.assist_torque[2] < 0 and out.assist_torque[3] < 0 and not out.assist_limited, "signs turn back and lean into the rail")
        out = c:step(observe(pose({ yaw = .2, omega = { 0, 1, 0 } }), double_left))
        check(near(out.assist_torque[2], expected[2] - t.assist_yaw_damping), "yaw damping")
        c = Grind.new({ assist_enabled = true })
        out = lock(c, pose({ yaw = .05 }), double_left, {})
        check(near(out.assist_torque[2], 0), "inside the yaw window there is no yaw request")
        out = c:step(observe(pose({ yaw = .05, omega = { 0, 1, 0 } }), double_left))
        check(out.assist_torque[2] == 0, "and no yaw damping inside the window either")
        -- Roll damping: on this rail the tangent is world +Z, and +Z angular
        -- velocity rolls the bike right, so damping pushes back left (-Z).
        c = Grind.new({ assist_enabled = true })
        lock(c, pose(), double_left, {})
        local still = c:step(observe(pose(), double_left))
        check(near(still.assist_torque[3], -t.assist_roll_stiffness * still.balance.effective), "roll stiffness alone when still")
        out = c:step(observe(pose({ omega = { 0, 0, 1 } }), double_left))
        check(near(out.balance.effective, still.balance.effective) and out.assist_torque[2] == 0, "same pose, only a roll rate")
        check(near(out.assist_torque[3] - still.assist_torque[3], -t.assist_roll_damping), "roll damping opposes a right roll")
        out = c:step(observe(pose({ omega = { 0, 0, -1 } }), double_left))
        check(near(out.assist_torque[3] - still.assist_torque[3], t.assist_roll_damping), "and a left roll")
        c = Grind.new({ assist_enabled = true, assist_yaw_stiffness = 1000, assist_roll_stiffness = 1000 })
        out = lock(c, body, double_left, {})
        check(out.assist_limited and near(M.length(out.assist_torque), c:settings().assist_torque_limit), "torque is capped")
        -- Yaw .3 is well outside any deadband, so a yaw window would show.
        out = lock(Grind.new({ assist_enabled = true }), pose({ speed = .2, yaw = .3 }), { "front_tire" }, {})
        check(out.grind == "tire_stall" and out.assist_torque[2] == 0, "tire stalls get no yaw request")
        out = lock(Grind.new({ assist_enabled = true }), pose({ speed = .2, yaw = .3 }), { "rear_left" }, {})
        check(out.grind == "peg_stall" and out.assist_torque[2] == 0, "peg stalls get no yaw request")
        c = Grind.new({ assist_enabled = true })
        lock(c, body, double_left, {})
        out = c:step(observe(body, {}))
        check(out.assist_torque == nil, "no request while the contact is lost")
    end)
    case("settings, inputs and invalid samples", function()
        local c = Grind.new({ approach_yaw_limit = 0 / 0, max_closing_speed = 1e9, fail_angle = 1, hard_fail_angle = .2,
            feeble_min_yaw = 1, assist_enabled = "yes", unknown = 4 })
        local s = c:settings()
        check(s.approach_yaw_limit == .7 and s.max_closing_speed == 20, "non-finite uses default, large clamps")
        check(s.hard_fail_angle == 1 and s.feeble_min_yaw == .7 and s.assist_enabled == false and s.unknown == nil,
            "cross-limits hold and only true enables assist")
        s.stall_speed = 99
        check(c:settings().stall_speed == .6, "settings readback is detached")
        local st = c:state() st.phase = "locked"
        check(c:state().phase == "idle", "state readback is detached")
        local body = pose()
        c = Grind.new()
        c:step(observe(body, {}))
        local o = observe(body, double_left)
        o.input = nil
        local out = c:step(o)
        check(not out.valid and out.issue == "disabled" and out.state == "idle", "a missing input is inert")
        c = Grind.new()
        lock(c, body, double_left, {})
        out = c:step(observe(body, double_left, { enabled = false }))
        check(not out.valid and out.exit_reason == "cancelled", "disable cancels")
        for _, edit in ipairs({
            function(x) x.seconds = 0 end, function(x) x.seconds = .2 end, function(x) x.seconds = 0 / 0 end,
            function(x) x.body.orientation = { 0, 0, 0, 2 } end, function(x) x.body.linear_velocity = { 0, 1e3, 0 } end,
            function(x) x.input.lean = 0 / 0 end, function(x) x.input.hop = 1 end, function(x) x.ground_support = nil end,
        }) do
            c = Grind.new()
            lock(c, body, double_left, {})
            o = observe(pose(), double_left)
            edit(o)
            out = c:step(o)
            check(not out.valid and out.state == "ended" and out.exit_reason == "invalid_sample", "invalid sample cancels")
            check(c:step(observe(body, double_left)).refusal == "not_from_air", "and needs air again")
        end
        check(Grind.new():step(nil).issue == "disabled" and Grind.new():step(5).valid == false, "non-table observation")
        check(Grind.evaluate({ body = body }).issue == "unavailable_contact", "evaluate without contacts")
        check(Grind.evaluate({}).issue == "invalid_body", "evaluate without body")
    end)
    case("deterministic, inputs untouched, requests only", function()
        local script = { observe(pose(), {}) }
        local function add(count, body, touching, o) for _ = 1, count do table.insert(script, observe(body, touching, o)) end end
        add(1, pose(), { "rear_left" }) add(4, pose(), double_left, { hop = true }) add(3, pose(), double_left, { lean = -.5 })
        add(8, pose({ yaw = .3 }), { "rear_left" }) add(2, pose({ speed = .3 }), double_left) add(1, pose(), {})
        add(1, pose(), double_left, { hop = true }) add(3, pose(), {}) add(1, pose({ yaw = -.3 }), { "rear_left" })
        add(20, pose({ roll = .5 }), { "rear_left" }) add(2, pose(), {}) add(1, pose({ speed = .2 }), { "front_tire" })
        local before = M.copy(script)
        local a, b = Grind.new({ assist_enabled = true }), Grind.new({ assist_enabled = true })
        local forbidden = { "position", "orientation", "center_of_mass", "linear_velocity", "angular_velocity", "velocity",
            "pose", "transform", "teleport", "snap", "impulse", "force" }
        local names = {}
        for i, o in ipairs(script) do
            local x, y = a:step(o), b:step(o)
            check(equal(x, y), "same observations give the same result " .. i)
            check(equal(a:state(), b:state()), "same history " .. i)
            check(#x.events <= 1, "at most one transition per step " .. i)
            for _, key in ipairs(forbidden) do check(x[key] == nil, "no " .. key .. " write in a result") end
            for _, event in ipairs(x.events) do table.insert(names, event.name .. ":" .. (event.grind or event.to or "")) end
        end
        check(equal(script, before), "observations are not modified")
        check(table.concat(names, ",") == "lock_on:double_peg,grind_changed:feeble,stalled:peg_stall,exit:peg_stall," ..
            "lock_on:smith,exit:smith", "the scripted run visits the expected transitions: " .. table.concat(names, ","))
        check(a:state().bail_latched and a:step(script[#script]).refusal == "bail_latched", "the run ends latched by its bail")
    end)
    return { cases = cases, assertions = assertions, constructed = true, native_authority = false, gameplay = false }
end
return Tests

-- B18 regressions for the composer's plan/witness/step join (RIDE_COMPOSER.md,
-- The same-table contract). These constructed reads prove no native effect.
local Composer = require("./ride_composer")
local World = require("./sim_world")
local Forces = require("./forces")
local Tests = {}
local H = Forces.native_seconds

local axes = { "left_x", "left_y", "right_x", "right_y" }
local triggers = { "left_trigger", "right_trigger" }
local buttons = { "up", "down", "left", "right", "start", "back", "left_stick", "right_stick",
    "lb", "rb", "a", "b", "x", "y" }

local function v(a) return vector.create(a[1], a[2], a[3]) end
local function pad()
    local out = { left_x = 0, left_y = 0, right_x = 0, right_y = 0,
        left_trigger = 0, right_trigger = 0, playstation = false, buttons = {} }
    for _, name in ipairs(buttons) do out.buttons[name] = false end
    return out
end
local function qualified_query()
    return { epoch_matches = true, accounting_known = true, budget_exhausted = false,
        local_actor_excluded = true, owned_bodies_excluded = true }
end
local function tick_of(body, wheels, handle, lease, serial, time)
    return { body_handle = handle, owner = "mount-1", wheels = { table.clone(wheels[1]), table.clone(wheels[2]) },
        sample = { epoch = newproxy(), serial = serial, time = time, seconds = H, mass = body.mass,
            position = vector.create(0, 5, 0), velocity = v(body.linear_velocity),
            angular_velocity = v(body.angular_velocity), inertia = v(body.inertia_body), rotation = { 0, 0, 0, 1 } },
        wheel_rows = { { contact = { status = "clear" } }, { contact = { status = "clear" } } },
        wheel_query = qualified_query(),
        gates = { focused = true, menu_open = false }, support = { provenance = "measured_support", grounded = false },
        input = { input_ok = true, lease_handle = lease, generation = 1,
            sample = { user = 0, packet = 1, sequence = "7", source_epoch = "11", context_generation = "13",
                observation_serial = "1001", observed_ms = "50017", pad = pad() } } }
end
-- Rewrites tick in place as read n of the same mount: a new epoch, serial,
-- time and observation, with nothing cast for it yet.
local function next_read(tick, n)
    tick.sample.epoch = newproxy()
    tick.sample.serial = tostring(100 + n)
    tick.sample.time = (n - 1) * H
    tick.input.sample.packet = n
    tick.input.sample.observation_serial = tostring(1000 + n)
    tick.input.sample.observed_ms = tostring(50017 + 17 * (n - 1))
    tick.rail, tick.guard, tick.witness = nil, nil, nil
    return tick
end
local function clear_batch(rays, epoch)
    local rows = {}
    for i = 1, #rays do rows[i] = { status = "clear" } end
    return { status = "available", epoch = epoch, native_casts = #rows, budget_exhausted = false,
        local_actor_excluded = true, owned_bodies_excluded = true, rays = rows }
end
local function append_queries(tick, plan)
    if plan.rail then tick.rail = clear_batch(plan.rail.rays, tick.sample.epoch) end
    if plan.guard then tick.guard = clear_batch(plan.guard.rays, tick.sample.epoch) end
end
local function witness(ride, tick)
    local w = ride:witness(tick)
    if #w.rays > 0 then tick.witness = clear_batch(w.rays, tick.sample.epoch) end
    return w
end
-- One read of a fresh composer, planned with its own bound guard and its
-- queries appended. before_plan edits the tick first.
local function fixture(before_plan)
    local body, wheels = World.place(World.terrain.flat(), { speed = 0 })
    local ride, handle, lease = Composer.new(), newproxy(), newproxy()
    local tick = tick_of(body, wheels, handle, lease, "101", 0)
    if before_plan then before_plan(tick) end
    local plan = ride:plan(tick)
    assert(plan.valid and plan.guard and plan.guard_binding == "bound", "fixture requires its own bound guard")
    append_queries(tick, plan)
    return ride, tick, plan, body, wheels, handle, lease
end
-- A read planned, appended and witnessed on its own table.
local function planned(ride, tick)
    local plan = ride:plan(tick)
    assert(plan.valid and plan.guard, "a planned read with a guard")
    append_queries(tick, plan)
    assert(witness(ride, tick).available, "its witnesses are available")
    return plan
end
-- Exact structural equality of two result or status tables. Results carry no
-- opaque handle, so two composers stepped on equal reads compare equal.
local function same(a, b, depth)
    depth = depth or 0
    if type(a) ~= type(b) then return false end
    if type(a) == "number" then return a == b or (a ~= a and b ~= b) end
    if type(a) ~= "table" then return a == b end
    if depth > 32 then return false end
    for k, x in pairs(a) do if not same(x, b[k], depth + 1) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

function Tests.run()
    local cases, assertions = 0, 0
    local function check(ok, why)
        assertions += 1
        assert(ok, why)
    end
    local function case(name, run)
        cases += 1
        run(name)
    end
    local function refused(ride, result, issue, serial)
        check(not result.valid and result.issue == issue, "drift has its own refusal: " .. issue)
        check(result.commands.submit == false and result.commands.force == nil and result.commands.torque == nil
            and result.commands.hop_impulse == nil, "no submit, force, torque or impulse")
        check(result.diagnostics.bail == nil and #result.events == 0, "no bail judgment or mode advancement")
        check(ride:status().serial == serial, "no body serial advancement")
    end

    -- Every protected field, changed before witness and after witness. Each
    -- refusal is the field's own reason.
    local edits = {
        { "body handle", "planned_body_changed", function(t) t.body_handle = newproxy() end },
        { "serial", "planned_body_changed", function(t) t.sample.serial = "102" end },
        { "time", "planned_body_changed", function(t) t.sample.time = H end },
        { "seconds", "planned_body_changed", function(t) t.sample.seconds = H + 1e-10 end },
        { "mass", "planned_body_changed", function(t) t.sample.mass += 1 end },
        { "position", "planned_body_changed", function(t) t.sample.position = vector.create(1, 5, 0) end },
        { "velocity", "planned_body_changed", function(t) t.sample.velocity = vector.create(0, 0, 1) end },
        { "angular velocity", "planned_body_changed", function(t) t.sample.angular_velocity = vector.create(0, 1, 0) end },
        { "inertia", "planned_body_changed", function(t) t.sample.inertia += vector.create(1, 0, 0) end },
        { "rotation alias", "planned_body_changed", function(t) t.sample.rotation[4] = -1 end },
        { "mount owner", "planned_owner_changed", function(t) t.owner = "mount-2" end },
        { "lease", "planned_source_changed", function(t) t.input.lease_handle = newproxy() end },
        { "generation", "planned_source_changed", function(t) t.input.generation = 2 end },
        { "user", "planned_source_changed", function(t) t.input.sample.user = 1 end },
        { "sequence", "planned_source_changed", function(t) t.input.sample.sequence = "8" end },
        { "source epoch", "planned_source_changed", function(t) t.input.sample.source_epoch = "12" end },
        { "context generation", "planned_source_changed", function(t) t.input.sample.context_generation = "14" end },
        { "observation serial", "planned_source_changed", function(t) t.input.sample.observation_serial = "1002" end },
        { "observed ms", "planned_source_changed", function(t) t.input.sample.observed_ms = "50018" end },
        { "packet", "planned_source_changed", function(t) t.input.sample.packet = 2 end },
        { "focus", "planned_gates_changed", function(t) t.gates.focused = false end },
        { "menu", "planned_gates_changed", function(t) t.gates.menu_open = true end },
        { "gates replaced", "planned_gates_changed", function(t) t.gates = { focused = false, menu_open = true } end },
        { "input absent", "planned_frame_unavailable", function(t) t.input = nil end },
        { "input unavailable", "planned_frame_unavailable", function(t) t.input.input_ok = false end },
        { "playstation", "planned_input_changed", function(t) t.input.sample.pad.playstation = true end },
        -- A key outside the mapper's pad or button set makes the pad one the
        -- mapper refuses (ride_input_mapping.lua sample_valid).
        { "unknown pad key", "planned_input_changed", function(t) t.input.sample.pad.extra = 0 end },
        { "unknown button", "planned_input_changed", function(t) t.input.sample.pad.buttons.turbo = true end },
        { "invalid sample", "planned_read_invalid_invalid_sample", function(t) t.sample.mass = 0 end },
        { "epoch hidden", "planned_read_invalid_invalid_sample", function(t) t.sample.epoch = "epoch" end },
        { "metatable sample", "planned_read_invalid_invalid_sample", function(t) setmetatable(t.sample, {}) end },
        { "invalid wheels", "planned_read_invalid_invalid_wheels", function(t) t.wheels = nil end },
        { "metatable gates", "planned_read_invalid_invalid_gates", function(t) setmetatable(t.gates, {}) end },
        { "metatable input", "planned_frame_unavailable", function(t) setmetatable(t.input, {}) end },
        { "metatable tick", "planned_read_invalid_invalid_tick", function(t) setmetatable(t, {}) end },
    }
    -- Every pad axis, trigger and button the projection keeps.
    for _, name in ipairs(axes) do
        table.insert(edits, { "axis " .. name, "planned_input_changed", function(t) t.input.sample.pad[name] = .5 end })
    end
    for _, name in ipairs(triggers) do
        table.insert(edits, { "trigger " .. name, "planned_input_changed", function(t) t.input.sample.pad[name] = .5 end })
    end
    for _, name in ipairs(buttons) do
        table.insert(edits, { "button " .. name, "planned_input_changed",
            function(t) t.input.sample.pad.buttons[name] = true end })
    end
    for _, stage in ipairs({ "before witness", "after witness" }) do
        for _, edit in ipairs(edits) do
            case(stage .. ": " .. edit[1], function()
                local ride, tick = fixture()
                if stage == "after witness" then assert(witness(ride, tick).available) end
                edit[3](tick)
                if stage == "before witness" then
                    local w = ride:witness(tick)
                    check(not w.available and w.reason == edit[2] and #w.rays == 0, "drift cannot request witnesses")
                end
                refused(ride, ride:step(tick), edit[2])
            end)
        end
    end

    -- Step runs on the plan's own read. Wheel facts changed after plan reach
    -- nothing: the result and the composer's state equal those of the same
    -- read stepped unchanged, both ways round for the wheel batch's facts.
    local unqualified = function(t) t.wheel_query.local_actor_excluded = false end
    local hit_row = function()
        return { contact = { status = "hit", point = { 0, 4.55, .55 }, normal = { 0, 1, 0 }, forward = { 0, 0, 1 },
            surface_velocity = { 0, 0, 0 } }, separation = 0, verified_plane = false, balance_normal_available = false }
    end
    local wheel_edits = {
        { "wheel query loses local actor exclusion", nil, function(t) t.wheel_query.local_actor_excluded = false end },
        { "wheel query replaced, budget exhausted", nil, function(t)
            t.wheel_query = qualified_query()
            t.wheel_query.budget_exhausted = true
        end },
        { "wheel query removed", nil, function(t) t.wheel_query = nil end },
        { "wheel query accounting lost", nil, function(t) t.wheel_query.accounting_known = false end },
        { "wheel query gains local actor exclusion", unqualified, function(t) t.wheel_query.local_actor_excluded = true end },
        { "wheel query replaced, qualified", unqualified, function(t) t.wheel_query = qualified_query() end },
        { "wheel speeds edited", nil, function(t)
            t.wheels[1].angular_speed += 40
            t.wheels[2].angular_speed += 40
        end },
        { "wheels replaced", nil, function(t)
            local front, rear = table.clone(t.wheels[1]), table.clone(t.wheels[2])
            front.angular_speed += 20
            rear.angular_speed -= 20
            rear.radius *= 1.1
            t.wheels = { front, rear }
        end },
        { "wheel rows replaced, unavailable", nil, function(t)
            t.wheel_rows = { { contact = { status = "unavailable" } }, { contact = { status = "unavailable" } } }
        end },
        { "wheel rows replaced, hit", nil, function(t) t.wheel_rows = { hit_row(), hit_row() } end },
        { "wheel row edited in place", nil, function(t)
            t.wheel_rows[1].contact.status = "unavailable"
            t.wheel_rows[2].contact = hit_row().contact
            t.wheel_rows[2].separation = 0
        end },
        { "unqualified wheel rows replaced, hit", unqualified, function(t) t.wheel_rows = { hit_row(), hit_row() } end },
    }
    -- The step's result, status() and the kernel history the submitted
    -- command would adopt on accept (forces.lua keeps each supported wheel's
    -- normal, balance normal, point, surface velocity, separation and
    -- verified_plane there, and verified_plane nowhere else).
    local function stepped(initial, edit, stage)
        local ride, tick = fixture(initial)
        if edit and stage == "before witness" then edit(tick) end
        assert(witness(ride, tick).available, "wheel facts do not touch the guard's witnesses")
        if edit and stage == "after witness" then edit(tick) end
        local result = ride:step(tick)
        local outstanding = ride._outstanding
        return result, ride:status(), outstanding and Composer.scrub(outstanding.candidate.normals) or nil
    end
    for _, stage in ipairs({ "before witness", "after witness" }) do
        for _, edit in ipairs(wheel_edits) do
            case(stage .. ": " .. edit[1], function()
                local control, control_status, control_history = stepped(edit[2], nil, stage)
                local result, status, history = stepped(edit[2], edit[3], stage)
                check(control.valid and control.diagnostics.bail.evaluated, "the control read is planned and judged")
                check(result.commands.submit == control.commands.submit
                    and result.diagnostics.kernel.issue == control.diagnostics.kernel.issue
                    and result.diagnostics.bail.guarded == control.diagnostics.bail.guarded,
                    "the submit gate is the plan's")
                check(same(result.commands, control.commands), "commands are the plan's")
                check(same(result, control) and same(status, control_status) and same(history, control_history),
                    "nothing step returns or keeps drifts")
            end)
        end
    end
    case("the wheel controls differ, so the comparisons above have something to see", function()
        local qualified = stepped(nil, nil, "after witness")
        local held = stepped(unqualified, nil, "after witness")
        check(qualified.commands.submit and not held.commands.submit
            and held.diagnostics.kernel.issue == "wheel_query_unqualified", "qualified submits, unqualified holds")
    end)
    case("the wheel batch's facts reach the trick packet as planned", function()
        -- trick_runtime refuses a packet unless all five facts qualify it;
        -- accounting is the one a qualified wheel read may still lack.
        local qualified = stepped(nil, nil, "after witness")
        local unaccounted = stepped(function(t) t.wheel_query.accounting_known = false end, nil, "after witness")
        check(qualified.diagnostics.input.active and qualified.diagnostics.trick.issue ~= "contact_query_unqualified",
            "the planned facts qualify the trick packet")
        check(unaccounted.diagnostics.input.active and unaccounted.diagnostics.trick.issue == "contact_query_unqualified",
            "and a read planned without accounting does not")
    end)

    -- Every wheel-row field the read keeps reaches step as the caller gave it
    -- at plan, with the result the caller's own rows gave before B18, and
    -- none is read from the caller's table again. The control is two hit rows
    -- with a verified plane and a tilted balance normal. Each field is changed
    -- on both rows: before plan, it gives forces.lua's own result for that
    -- value; in place after plan, before or after witness, it reaches nothing.
    local function verified_row()
        return { contact = { status = "hit", point = { 0, 4.55, .55 }, normal = { 0, 1, 0 }, forward = { 0, 0, 1 },
            surface_velocity = { 0, 0, 0 } }, separation = 0, verified_plane = true, balance_normal_available = true,
            balance_normal = { .2, 1, 0 } }
    end
    local verified = function(t) t.wheel_rows = { verified_row(), verified_row() } end
    local function unit(x)
        local n = math.sqrt(x[1] * x[1] + x[2] * x[2] + x[3] * x[3])
        return { x[1] / n, x[2] / n, x[3] / n }
    end
    local function near(a, b)
        return type(a) == "table" and math.abs(a[1] - b[1]) < 1e-9 and math.abs(a[2] - b[2]) < 1e-9
            and math.abs(a[3] - b[3]) < 1e-9
    end
    -- Both supported wheels' kept history satisfies field(history row).
    local function kept(history, field)
        return history ~= nil and history[1].valid == true and history[2].valid == true
            and field(history[1]) and field(history[2])
    end
    local function withheld(result, issue)
        return result.valid and not result.commands.submit and result.commands.force == nil
            and result.diagnostics.kernel.issue == issue
    end
    local row_fields = {
        { "a clear contact status", function(row) row.contact.status = "clear" end, function(result, history)
            return result.commands.submit and history ~= nil and not history[1].valid and not history[2].valid
        end },
        { "a moved contact point", function(row) row.contact.point[2], row.contact.point[3] = 4.5, .6 end,
            function(_, history) return kept(history, function(h) return near(h.point, { 0, 4.5, .6 }) end) end },
        { "a tilted contact normal", function(row) row.contact.normal[1] = .1 end, function(_, history)
            return kept(history, function(h) return near(h.normal, unit({ .1, 1, 0 })) end)
        end },
        { "a contact forward along the normal", function(row) row.contact.forward[2], row.contact.forward[3] = 1, 0 end,
            function(result) return withheld(result, "invalid_sample") end },
        { "a moving surface", function(row) row.contact.surface_velocity[3] = 1 end, function(_, history)
            return kept(history, function(h) return near(h.surface_velocity, { 0, 0, 1 }) end)
        end },
        { "a small penetration", function(row) row.separation = -.004 end, function(_, history)
            return kept(history, function(h) return h.separation == -.004 end)
        end },
        { "a penetration past the limit", function(row) row.separation = -.2 end,
            function(result) return withheld(result, "penetration_limit") end },
        { "no verified plane", function(row) row.verified_plane = false end, function(_, history)
            return kept(history, function(h) return h.verified_plane == false end)
        end },
        { "no balance normal", function(row) row.balance_normal_available = false end, function(result, history)
            return result.commands.submit and math.abs(result.commands.force[1]) < 1e-9
                and kept(history, function(h) return near(h.balance_normal, { 0, 1, 0 }) end)
        end },
        { "a mirrored balance normal", function(row) row.balance_normal[1] = -.2 end, function(_, history)
            return kept(history, function(h) return near(h.balance_normal, unit({ -.2, 1, 0 })) end)
        end },
        { "an opposed balance normal", function(row) row.balance_normal[1], row.balance_normal[2] = 0, -1 end,
            function(result) return withheld(result, "invalid_sample") end },
    }
    local function both_rows(edit) return function(t) edit(t.wheel_rows[1]); edit(t.wheel_rows[2]) end end
    case("verified rows with a balance normal: the control", function()
        local result, _, history = stepped(verified, nil, "after witness")
        check(result.valid and result.commands.submit and result.diagnostics.kernel.issue == "none"
            and result.diagnostics.kernel.enabled, "the control submits with rider controls")
        check(kept(history, function(h)
            return h.verified_plane == true and near(h.balance_normal, unit({ .2, 1, 0 })) and near(h.normal, { 0, 1, 0 })
                and near(h.point, { 0, 4.55, .55 }) and near(h.surface_velocity, { 0, 0, 0 }) and h.separation == 0
        end), "both wheels keep the rows' own values")
        check(result.commands.force[1] > 0 and result.commands.torque[2] ~= 0,
            "the tilted balance normal shapes the command")
    end)
    for _, field in ipairs(row_fields) do
        case("planned with " .. field[1] .. ": forces.lua's own result", function()
            local control, _, control_history = stepped(verified, nil, "after witness")
            local result, _, history = stepped(function(t)
                verified(t)
                both_rows(field[2])(t)
            end, nil, "after witness")
            check(field[3](result, history), "the planned value reaches step")
            check(not (same(result, control) and same(history, control_history)), "and differs from the control")
        end)
        for _, stage in ipairs({ "before witness", "after witness" }) do
            case(stage .. ": " .. field[1] .. ", made in place after plan", function()
                local control, control_status, control_history = stepped(verified, nil, stage)
                local result, status, history = stepped(verified, both_rows(field[2]), stage)
                check(same(result, control) and same(status, control_status) and same(history, control_history),
                    "the edit reaches nothing step returns or keeps")
            end)
        end
    end

    -- The refusal is final for that read, by epoch.
    case("restoring a refused read and planning it again revives nothing", function()
        local ride, tick = fixture()
        assert(witness(ride, tick).available)
        tick.input.sample.packet = 2
        refused(ride, ride:step(tick), "planned_source_changed")
        tick.input.sample.packet = 1
        local p = ride:plan(tick)
        check(not p.valid and p.issue == "planned_source_changed" and p.guard == nil, "a new plan for it is refused")
        local w = ride:witness(tick)
        check(not w.available and w.reason == "planned_source_changed" and #w.rays == 0, "no witnesses for it")
        refused(ride, ride:step(tick), "planned_source_changed")
    end)
    case("a kept drift cannot re-arm a guard on the table's old rows", function()
        local ride, tick = fixture()
        assert(witness(ride, tick).available)
        tick.sample.position = vector.create(1, 5, 0)
        refused(ride, ride:step(tick), "planned_body_changed")
        local p = ride:plan(tick)
        check(not p.valid and p.issue == "planned_body_changed" and p.guard == nil, "no guard is planned on the drifted body")
        check(not ride:witness(tick).available, "the old same-epoch rows grant nothing")
        refused(ride, ride:step(tick), "planned_body_changed")
    end)
    case("a refused read stays refused after a newer read was planned", function()
        local ride, tick, _, body, wheels, handle, lease = fixture()
        tick.input.sample.packet = 2
        local w = ride:witness(tick)
        check(not w.available and w.reason == "planned_source_changed", "refused at witness")
        local newer = next_read(tick_of(body, wheels, handle, lease, "101", 0), 2)
        local plan = planned(ride, newer)
        tick.input.sample.packet = 1
        local p = ride:plan(tick)
        check(not p.valid and p.issue == "planned_source_changed", "the old read cannot be planned again")
        refused(ride, ride:step(tick), "planned_source_changed")
        check(rawequal(ride:plan(newer), plan), "the newer read keeps its plan")
        local result = ride:step(newer)
        check(result.valid and result.commands.submit and result.diagnostics.bail.evaluated
            and ride:status().serial == "102", "and is stepped and judged as usual")
    end)

    -- A plan dropped before its step is final for its read too
    -- (planned_read_abandoned). The hazard: the body drifts while the plan is
    -- pending, nothing looks before the plan is dropped, and the read is then
    -- planned again, binding fresh guard rays that the table's old same-epoch
    -- rows would answer. One case per way a pending plan is dropped.
    local function abandoned(ride, tick, serial)
        local p = ride:plan(tick)
        check(not p.valid and p.issue == "planned_read_abandoned" and p.guard == nil,
            "the abandoned read cannot be planned again")
        local w = ride:witness(tick)
        check(not w.available and w.reason == "planned_read_abandoned" and #w.rays == 0,
            "its old same-epoch rows grant nothing")
        refused(ride, ride:step(tick), "planned_read_abandoned", serial)
    end
    local function newer_read(ctx) return next_read(tick_of(ctx[1], ctx[2], ctx[3], ctx[4], "101", 0), 2) end
    local routes = {
        { "an invalid read planned", function(ride)
            check(not ride:plan({}).valid, "an invalid read is not planned")
        end },
        { "an invalid read stepped", function(ride)
            local result = ride:step({})
            check(not result.valid and result.issue == "invalid_sample", "an invalid read is not stepped")
        end },
        { "another table's read planned", function(ride, _, ctx)
            local newer = newer_read(ctx)
            planned(ride, newer)
            return function()
                local result = ride:step(newer)
                check(result.valid and result.commands.submit and result.diagnostics.bail.evaluated
                    and ride:status().serial == "102", "the newer read keeps its plan and is judged")
            end
        end },
        { "another table's read stepped without a plan", function(ride, _, ctx)
            local result = ride:step(newer_read(ctx))
            check(result.valid and result.diagnostics.queries.uncast and not result.commands.submit,
                "the newer read plans itself uncast")
        end, "102" },
        { "the planned table reused and planned, then restored", function(ride, tick)
            local s, i = tick.sample, tick.input.sample
            local kept_read = { s.epoch, s.serial, s.time, i.packet, i.observation_serial, i.observed_ms,
                tick.rail, tick.guard, tick.witness }
            next_read(tick, 2)
            local plan = ride:plan(tick)
            check(plan.valid and plan.serial == "102", "the reused table's read is planned")
            s.epoch, s.serial, s.time, i.packet, i.observation_serial, i.observed_ms = table.unpack(kept_read, 1, 6)
            tick.rail, tick.guard, tick.witness = kept_read[7], kept_read[8], kept_read[9]
        end },
    }
    for _, route in ipairs(routes) do
        case("a drifted pending read abandoned by " .. route[1] .. " stays abandoned", function()
            local ride, tick, _, body, wheels, handle, lease = fixture()
            assert(witness(ride, tick).available)
            tick.sample.position = vector.create(1, 5, 0)
            local after = route[2](ride, tick, { body, wheels, handle, lease })
            abandoned(ride, tick, route[3])
            if after then after() end
        end)
    end
    case("a drifted pending read abandoned by a duplicate read planned stays abandoned", function()
        local ride, tick, _, body, wheels, handle, lease = fixture()
        assert(witness(ride, tick).available)
        check(ride:step(tick).commands.submit and ride:accept("101"), "read 101 is stepped and accepted")
        local pending = newer_read({ body, wheels, handle, lease })
        planned(ride, pending)
        pending.sample.position = vector.create(1, 5, 0)
        local duplicate = tick_of(body, wheels, handle, lease, "101", 0)
        local stale = ride:plan(duplicate)
        check(stale.valid and stale.issue == "duplicate_read", "the duplicate read gets its stale plan")
        abandoned(ride, pending, "101")
    end)
    case("an abandoned read stays abandoned with no drift at all", function()
        local ride, tick, _, body, wheels, handle, lease = fixture()
        assert(witness(ride, tick).available)
        planned(ride, newer_read({ body, wheels, handle, lease }))
        abandoned(ride, tick)
    end)

    -- A reused table: a different epoch on the planned table is a new read.
    case("the planned table reused for the next read plans that read", function()
        local ride, tick, first = fixture()
        next_read(tick, 2)
        local plan = ride:plan(tick)
        check(plan.valid and plan.issue == "none" and plan.serial == "102" and plan.guard ~= nil
            and not rawequal(plan, first), "a fresh plan for the new read, not planned_body_changed")
        append_queries(tick, plan)
        check(witness(ride, tick).available, "its own casts serve its witnesses")
        local result = ride:step(tick)
        check(result.valid and result.commands.submit and result.diagnostics.bail.evaluated
            and ride:status().serial == "102", "the new read is judged and submits")
    end)
    case("a reused table keeps nothing cast for the abandoned read", function()
        local ride, tick = fixture()
        local old_guard = tick.guard
        next_read(tick, 2)
        local plan = ride:plan(tick)
        check(plan.valid and plan.serial == "102", "the new read is planned")
        tick.guard = old_guard
        local w = ride:witness(tick)
        check(not w.available and w.reason == "guard_epoch_mismatch", "the old read's guard rows are refused")
        local result = ride:step(tick)
        check(result.valid and not result.commands.submit and not result.diagnostics.bail.evaluated
            and result.commands.force == nil, "an unjudged new read submits nothing")
    end)
    case("a new epoch on the planned table after witness steps uncast", function()
        local ride, tick = fixture()
        assert(witness(ride, tick).available)
        tick.sample.epoch = newproxy()
        local w = ride:witness(tick)
        check(not w.available and w.reason == "plan_required", "the new read has no plan yet")
        local result = ride:step(tick)
        check(result.valid and result.diagnostics.queries.uncast and not result.diagnostics.bail.evaluated
            and not result.commands.submit and result.commands.force == nil, "it plans itself uncast and sends nothing")
    end)
    case("a table reused after its read was stepped keeps the guard's sweep history", function()
        -- The guard sweeps from the last judged read's frozen Framev1, so the
        -- caller rewriting the table in place for the next read cannot alias
        -- it. Before B18 the composer kept the caller's sample there and lost the
        -- history on a reused table (sample_alias_mismatch).
        local function next_plan(reuse)
            local ride, tick, _, body, wheels, handle, lease = fixture()
            assert(witness(ride, tick).available)
            assert(ride:step(tick).commands.submit and ride:accept("101"), "read 101 is judged and accepted")
            local next_tick = reuse and tick or tick_of(body, wheels, handle, lease, "101", 0)
            return ride:plan(next_read(next_tick, 2))
        end
        local reused, fresh = next_plan(true), next_plan(false)
        check(reused.valid and reused.guard ~= nil and reused.guard.consecutive == true,
            "the reused table's read sweeps from the read before it")
        check(same(Composer.scrub(reused), Composer.scrub(fresh)), "as a fresh table's read does")
    end)

    -- Pad values the mapper refuses are its refusal at step, as before, not
    -- drift: a NaN never equals itself, so it is never compared by value, and
    -- a key outside the mapper's pad or button set makes the whole pad one it
    -- refuses. Each refused pad, made valid again after plan, is drift.
    local refused_pads = {
        { "NaN axis", function(t) t.input.sample.pad.left_x = 0 / 0 end, function(t) t.input.sample.pad.left_x = 0 end },
        { "infinite trigger", function(t) t.input.sample.pad.right_trigger = math.huge end,
            function(t) t.input.sample.pad.right_trigger = 0 end },
        { "negative infinite axis", function(t) t.input.sample.pad.right_y = -math.huge end,
            function(t) t.input.sample.pad.right_y = 0 end },
        { "unknown pad key", function(t) t.input.sample.pad.extra = 0 end, function(t) t.input.sample.pad.extra = nil end },
        { "unknown button", function(t) t.input.sample.pad.buttons.turbo = true end,
            function(t) t.input.sample.pad.buttons.turbo = nil end },
    }
    for _, entry in ipairs(refused_pads) do
        for _, stage in ipairs({ "before witness", "after witness" }) do
            case(stage .. ": " .. entry[1] .. " made valid is drift", function()
                local ride, tick = fixture(entry[2])
                if stage == "after witness" then assert(witness(ride, tick).available) end
                entry[3](tick)
                if stage == "before witness" then
                    local w = ride:witness(tick)
                    check(not w.available and w.reason == "planned_input_changed", "drift cannot request witnesses")
                end
                refused(ride, ride:step(tick), "planned_input_changed")
            end)
        end
        case(entry[1] .. " is the mapper's refusal, not drift", function()
            local ride, tick, plan = fixture(entry[2])
            check(rawequal(ride:plan(tick), plan), "the repeated plan is the cached one")
            local w = witness(ride, tick)
            check(w.available and rawequal(ride:witness(tick), w), "witnesses and the cached witness stay available")
            local result = ride:step(tick)
            check(result.valid and result.issue == "none" and result.diagnostics.bail.evaluated
                and result.diagnostics.bail.guarded, "the read is judged")
            check(result.diagnostics.input.observe == "invalid_source_sample" and not result.diagnostics.input.active,
                "the mapper refuses the input")
            check(result.commands.submit and result.diagnostics.kernel.enabled == false,
                "passive support only, as without the projection")
        end)
    end
    case("a finite pad that becomes NaN is drift", function()
        local ride, tick = fixture()
        assert(witness(ride, tick).available)
        tick.input.sample.pad.left_y = 0 / 0
        refused(ride, ride:step(tick), "planned_input_changed")
    end)
    local swaps = {
        { "a NaN axis for an infinite one", refused_pads[1][2], function(t) t.input.sample.pad.left_x = math.huge end },
        { "an unknown pad key for an unknown button", refused_pads[4][2], function(t)
            t.input.sample.pad.extra = nil
            t.input.sample.pad.buttons.turbo = true
        end },
    }
    for _, swap in ipairs(swaps) do
        case("one refused pad for another is no drift: " .. swap[1], function()
            local ride, tick = fixture(swap[2])
            assert(witness(ride, tick).available)
            swap[3](tick)
            local result = ride:step(tick)
            check(result.valid and result.diagnostics.bail.evaluated
                and result.diagnostics.input.observe == "invalid_source_sample",
                "the mapper refuses either; nothing reads the pad it refused")
        end)
    end

    -- Controls and the remaining join rules.
    case("unchanged projections and appended results", function()
        local ride, tick, plan = fixture()
        -- Replacing nested tables with equal plain values is fine; the outer
        -- tick is the protocol's same table. Unknown extras are not traversed.
        tick.sample = table.clone(tick.sample)
        tick.sample.rotation = table.clone(tick.sample.rotation)
        tick.input = table.clone(tick.input)
        tick.input.sample = table.clone(tick.input.sample)
        tick.input.sample.pad = table.clone(tick.input.sample.pad)
        tick.input.sample.pad.buttons = table.clone(tick.input.sample.pad.buttons)
        tick.gates = table.clone(tick.gates)
        tick.unread_extra = tick
        check(rawequal(ride:plan(tick), plan), "equal protected projections keep the cached plan")
        local w = witness(ride, tick)
        check(w.available and #w.rays == 0 and rawequal(ride:witness(tick), w), "query appends and cached witness work")
        local result = ride:step(tick)
        check(result.valid and result.commands.submit and result.diagnostics.bail.evaluated
            and result.diagnostics.bail.valid, "unchanged read submits only after its own bail judgment")
        check(ride:accept(result.commands.serial), "ordinary receipt still settles")
    end)
    case("different outer tick with the same epoch", function()
        local ride, tick = fixture()
        local clone = table.clone(tick)
        local w = ride:witness(clone)
        check(not w.available and w.reason == "planned_tick_changed", "same-table protocol is enforced")
        refused(ride, ride:step(clone), "planned_tick_changed")
        check(not ride:witness(tick).available and not ride:plan(tick).valid, "the original table is refused too")
    end)
    case("repeated plan refusal is sticky", function()
        local ride, tick = fixture()
        tick.input.sample.packet = 2
        local p = ride:plan(tick)
        check(not p.valid and p.issue == "planned_source_changed" and p.guard == nil, "cached plan revalidates")
        tick.input.sample.packet = 1
        check(not ride:plan(tick).valid, "restoration cannot revive a refused plan")
        local w = ride:witness(tick)
        check(not w.available and w.reason == "planned_source_changed", "restoration cannot revive witnesses")
        refused(ride, ride:step(tick), "planned_source_changed")
    end)
    case("cached witness revalidates and stays refused", function()
        local ride, tick = fixture()
        assert(witness(ride, tick).available)
        tick.gates.focused = false
        local w = ride:witness(tick)
        check(not w.available and w.reason == "planned_gates_changed", "cached witness checks gates")
        tick.gates.focused = true
        check(not ride:witness(tick).available, "restored gates do not revive cached witnesses")
        refused(ride, ride:step(tick), "planned_gates_changed")
    end)
    case("outer tick structural refusal is sticky", function()
        local ride, tick = fixture()
        assert(witness(ride, tick).available)
        setmetatable(tick, {})
        local w = ride:witness(tick)
        check(not w.available and w.reason == "planned_read_invalid_invalid_tick", "outer structure checked before cached witness")
        setmetatable(tick, nil)
        check(not ride:witness(tick).available, "restored outer structure cannot revive cached witness")
        refused(ride, ride:step(tick), "planned_read_invalid_invalid_tick")
        local p = ride:plan(tick)
        check(not p.valid and p.issue == "planned_read_invalid_invalid_tick", "nor can a new plan for it")
    end)
    case("unbound plan cannot be upgraded by late input", function()
        local body, wheels = World.place(World.terrain.flat(), { speed = 0 })
        local ride = Composer.new()
        local tick = tick_of(body, wheels, newproxy(), newproxy(), "101", 0)
        local input = tick.input
        tick.input = nil
        local p = ride:plan(tick)
        check(p.guard == nil and p.guard_issue == "bail_guard_unbound", "initial source absence is unbound")
        tick.input = input
        check(not witness(ride, tick).available, "late source grants no old guard")
        local result = ride:step(tick)
        check(not result.commands.submit and result.commands.force == nil and result.commands.torque == nil
            and result.commands.hop_impulse == nil and not result.diagnostics.bail.evaluated, "unbound read still fails closed")
    end)
    case("an unbound plan steps on its plan-time body", function()
        local function run(edit)
            local body, wheels = World.place(World.terrain.flat(), { speed = 0 })
            local ride = Composer.new()
            local tick = tick_of(body, wheels, newproxy(), newproxy(), "101", 0)
            local input = tick.input
            tick.input = nil
            local p = ride:plan(tick)
            assert(p.valid and p.guard == nil, "unbound plan")
            tick.input = input
            if edit then edit(tick) end
            local result = ride:step(tick)
            return result, ride:status(), ride._last_command
        end
        local control, control_status, control_last = run(nil)
        local result, status, last = run(function(t)
            t.sample.position = vector.create(3, 5, 0)
            t.sample.velocity = vector.create(0, 0, 3)
            t.wheels[1].angular_speed += 10
        end)
        check(result.valid and not result.commands.submit and result.commands.force == nil, "it submits nothing")
        check(same(result, control) and same(status, control_status), "the drifted body is not read")
        check(last ~= nil and same(last, control_last) and last.velocity[3] == 0, "the residual baseline is the plan's")
        -- The rotation is the sample's one nested table: edited in place, it
        -- would reach the trick frame (frame_identity's body_alias_mismatch).
        local turned = run(function(t) t.sample.rotation[3], t.sample.rotation[4] = .6, .8 end)
        check(control.diagnostics.input.active and same(turned, control), "the sample rotation edited in place is not read")
    end)
    -- An unbound plan's gates are the plan's copy too: the mapper reads them
    -- at step, and a read planned unfocused or in the menu stays so.
    local gate_edits = {
        { "focus regained in place", function(t) t.gates.focused = false end, function(t) t.gates.focused = true end,
            "focus_lost" },
        { "focus regained by replacing the gates", function(t) t.gates.focused = false end,
            function(t) t.gates = { focused = true, menu_open = false } end, "focus_lost" },
        { "menu closed in place", function(t) t.gates.menu_open = true end, function(t) t.gates.menu_open = false end,
            "menu_open" },
    }
    for _, entry in ipairs(gate_edits) do
        case("an unbound plan steps on its plan-time gates: " .. entry[1], function()
            local function run(edit)
                local body, wheels = World.place(World.terrain.flat(), { speed = 0 })
                local ride = Composer.new()
                local tick = tick_of(body, wheels, newproxy(), newproxy(), "101", 0)
                entry[2](tick)
                local p = ride:plan(tick)
                assert(p.valid and p.guard == nil and p.guard_issue == "bail_guard_unbound", "unbound plan")
                if edit then edit(tick) end
                return ride:step(tick), ride:status()
            end
            local control, control_status = run(nil)
            local result, status = run(entry[3])
            check(control.diagnostics.input.observe == entry[4] and not control.diagnostics.input.active,
                "the mapper refuses the planned gates")
            check(same(result, control) and same(status, control_status), "the step-time gates are not read")
        end)
    end
    case("no-plan fallback stays uncast", function()
        local body, wheels = World.place(World.terrain.flat(), { speed = 0 })
        local ride = Composer.new()
        local tick = tick_of(body, wheels, newproxy(), newproxy(), "101", 0)
        local result = ride:step(tick)
        check(not result.commands.submit and result.commands.force == nil and result.commands.torque == nil
            and result.commands.hop_impulse == nil, "no-plan read sends nothing")
        check(result.diagnostics.queries.uncast and not result.diagnostics.bail.evaluated, "no invented query or judgment")
    end)
    case("a drift refusal clears the guard's sweep history and the residual baseline", function()
        local ride, tick, _, body, wheels, handle, lease = fixture()
        assert(witness(ride, tick).available)
        local first = ride:step(tick)
        check(first.commands.submit and ride:accept("101"), "a judged read submits and is accepted")
        check(ride._guard_previous ~= nil and ride._last_command ~= nil, "it lends sweep history and a residual baseline")
        local next_tick = next_read(tick_of(body, wheels, handle, lease, "101", 0), 2)
        planned(ride, next_tick)
        check(ride._guard_previous ~= nil and ride._last_command ~= nil, "plan and witness keep both")
        next_tick.input.sample.packet = 3
        refused(ride, ride:step(next_tick), "planned_source_changed", "101")
        check(ride._guard_previous == nil and ride._last_command == nil, "the refused read clears both")
    end)
    case("drift preserves outstanding receipt debt", function()
        local ride, tick, _, body, wheels, handle, lease = fixture()
        assert(witness(ride, tick).available)
        local first = ride:step(tick)
        check(first.commands.submit and ride:status().outstanding == "101", "control leaves a receipt outstanding")
        local next_tick = next_read(tick_of(body, wheels, handle, lease, "101", 0), 2)
        planned(ride, next_tick)
        next_tick.sample.position = vector.create(1, 5, 0)
        local result = ride:step(next_tick)
        check(not result.valid and result.issue == "planned_body_changed" and not result.commands.submit,
            "successor drift is refused")
        check(ride:status().outstanding == "101" and ride:status().serial == "101", "debt and chronology stay with the submitted read")
        check(ride:accept("101") and ride:status().outstanding == nil, "the existing receipt can still settle")
    end)
    return { cases = cases, assertions = assertions, native_actions = 0 }
end

return Tests

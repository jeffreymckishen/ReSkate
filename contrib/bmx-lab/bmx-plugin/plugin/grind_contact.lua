-- Lua port of solve_grind from standalone/bmx-movement/src/grind.cpp and its
-- contract in include/bmx/grind.hpp. That solver is this repository's own
-- reference code (commit 29e541f), written on the portable contact arithmetic
-- of include/bmx/detail/source/bmx_tire_dynamics.h; it is not game code.
-- It is fixed-step unilateral contact plus dissipative sliding friction for
-- ONE observed peg or rail contact. It never searches for a rail, snaps a
-- pose or pulls the bike toward a path: the rail probe observes the contact
-- and the force owner applies the result. Gravity predicts this step but is
-- not part of the returned force, because the host applies gravity itself.
-- Replace the host's response for this same contact with the result; never
-- apply both this and another contact solver to one contact. Pure.
local M = require("./force_math")
local Contact = {}
-- movement.hpp fixed_step, minimum_fixed_step and maximum_fixed_step.
Contact.fixed_step = 1 / 60
Contact.minimum_fixed_step = 1 / 240
Contact.maximum_fixed_step = 1 / 30
-- grind.cpp refuses a result above either cap rather than clipping it, so an
-- impossible impulse never reaches the body as a smaller plausible one.
Contact.force_limit = 40000
Contact.torque_limit = 4000
Contact.default_friction = .12 -- GrindContact::friction
-- Frozen because the module table's freeze is shallow: no caller can change
-- every other caller's default gravity.
Contact.default_gravity = table.freeze({ 0, -9.8, 0 })

local finite = M.finite
local function zero()
    return { valid = false, active = false, force = { 0, 0, 0 }, torque = { 0, 0, 0 }, speed = 0,
        normal_impulse = 0, friction_impulse = 0 }
end
local function qmul(a, b)
    return { a[4] * b[1] + a[1] * b[4] + a[2] * b[3] - a[3] * b[2],
        a[4] * b[2] - a[1] * b[3] + a[2] * b[4] + a[3] * b[1],
        a[4] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[4],
        a[4] * b[4] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3] }
end
-- tire::valid(Body) plus its inertia_orientation check. Lua bodies (the
-- force_math.lua shape) usually omit inertia_orientation, which is the C++
-- default identity. The returned working copy carries the combined principal
-- frame as its orientation, as tire::detail::inertia_rotation builds it, so
-- force_math's tensor, response and apply_impulse see the same inertia.
local function working_body(body)
    if not M.valid_body(body) then return nil end
    local frame = body.inertia_orientation
    if frame == nil then return M.copy(body) end
    if type(frame) ~= "table" then return nil end
    local square = 0
    for i = 1, 4 do
        if not finite(frame[i]) then return nil end
        square += frame[i] * frame[i]
    end
    if math.abs(square - 1) > .001 then return nil end
    local out = M.copy(body)
    out.inertia_orientation = nil
    if frame[1] ~= 0 or frame[2] ~= 0 or frame[3] ~= 0 or frame[4] ~= 1 then
        out.orientation = M.normalized(qmul(M.normalized(body.orientation), { frame[1], frame[2], frame[3], frame[4] }))
    end
    return out
end
-- GrindContact's member defaults stand in for absent fields, so a clear row of
-- the grind_policy shape ({available = true, touching = false}) solves the way
-- a default-constructed C++ contact does. A present field of the wrong type is
-- invalid, never defaulted.
local function field(contact, name, fallback)
    local value = contact[name]
    if value == nil then return M.copy(fallback) end
    return value
end

-- solve_grind(body, contact, gravity = {0,-9.8,0}, seconds = fixed_step).
-- Returns {valid, active, force, torque, speed, normal_impulse,
-- friction_impulse}; force and torque are about the body's centre of mass.
function Contact.solve(body, contact, gravity, seconds)
    local out = zero()
    if gravity == nil then gravity = Contact.default_gravity end
    if seconds == nil then seconds = Contact.fixed_step end
    if not finite(seconds) or seconds < Contact.minimum_fixed_step or seconds > Contact.maximum_fixed_step then return out end
    local b = working_body(body)
    if not b or type(contact) ~= "table" or contact.available ~= true or not M.vec(gravity, 100) then return out end
    local touching = field(contact, "touching", false)
    local point = field(contact, "point", { 0, 0, 0 })
    local surface = field(contact, "surface_velocity", { 0, 0, 0 })
    local separation = field(contact, "separation", 0)
    local friction = field(contact, "friction", Contact.default_friction)
    if type(touching) ~= "boolean" or not M.vec(point, 1e6) or not M.vec(surface, 1e5) or not finite(separation)
        or not finite(friction) or friction < 0 or friction > 10 then return out end
    local normal = M.unit(field(contact, "normal", { 0, 1, 0 }))
    local tangent = M.unit(field(contact, "tangent", { 0, 0, 1 }))
    if not normal or not tangent or math.abs(M.dot(normal, tangent)) > 1e-3 then return out end
    out.valid = true
    out.speed = M.dot(M.sub(M.point_velocity(b, point), surface), tangent)
    -- The same 5 mm gap and 3 cm penetration window as grind.cpp: a separated
    -- or missing rail is valid and inactive, so it can never attract the bike.
    if not touching or separation > .005 or separation < -.03 then return out end
    local arm = M.sub(point, b.center_of_mass)
    local predicted = M.copy(b)
    predicted.linear_velocity = M.add(predicted.linear_velocity, M.mul(gravity, seconds))
    local at_point = M.sub(M.point_velocity(predicted, point), surface)
    local normal_mass = M.dot(normal, M.response(predicted, arm, normal))
    if not finite(normal_mass) or normal_mass <= 1e-9 then out.valid = false; return out end
    -- Unilateral: the rail pushes and never pulls.
    out.normal_impulse = math.max(0, -M.dot(at_point, normal) / normal_mass)
    local normal_impulse = M.mul(normal, out.normal_impulse)
    predicted = M.apply_impulse(predicted, point, normal_impulse)
    if not predicted then out.valid = false; return out end
    local tangential_mass = M.dot(tangent, M.response(predicted, arm, tangent))
    if not finite(tangential_mass) or tangential_mass <= 1e-9 then out.valid = false; return out end
    local slip = M.sub(M.point_velocity(predicted, point), surface)
    -- Coulomb limit: friction only removes slip along the rail, and stops at
    -- zero relative speed rather than reversing it.
    local limit = friction * out.normal_impulse
    out.friction_impulse = math.clamp(-M.dot(slip, tangent) / tangential_mass, -limit, limit)
    local impulse = M.add(normal_impulse, M.mul(tangent, out.friction_impulse))
    out.force = M.mul(impulse, 1 / seconds)
    out.torque = M.mul(M.cross(arm, impulse), 1 / seconds)
    if not M.vec(out.force, 1e9) or not M.vec(out.torque, 1e9)
        or M.dot(out.force, out.force) > Contact.force_limit * Contact.force_limit
        or M.dot(out.torque, out.torque) > Contact.torque_limit * Contact.torque_limit then return zero() end
    predicted = M.apply_impulse(predicted, point, M.mul(tangent, out.friction_impulse))
    if not predicted then return zero() end
    out.speed = M.dot(M.sub(M.point_velocity(predicted, point), surface), tangent)
    out.active = out.normal_impulse > 0
    return out
end
return table.freeze(Contact)

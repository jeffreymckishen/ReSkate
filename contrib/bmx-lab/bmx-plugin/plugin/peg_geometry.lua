-- Authored peg geometry for the grind policy. The supplied-FBX prototype and
-- the native pack have no pegs, so these are our own nominal pegs, not game
-- data. They sit on the bike_geometry.lua axles in the same authored frame
-- (Y up, +Z forward, +X rider left) and are multiplied by the same G.scale, so
-- a change of bike scale moves the pegs with the wheels. Pure: no SDK access.
local G = require("./bike_geometry")
local M = require("./force_math")
local P = {}
local s = G.scale
P.scale = s
-- Unscaled values are in bike_geometry.lua's units. After scaling, the inner
-- face sits 50 mm out from the hub centre (a 100 mm hub's locknut), and the
-- peg is 108 mm long and 38 mm across: an ordinary 4.25 inch steel peg.
P.inner_offset = .065 * s
P.length = .14 * s
P.outer_offset = P.inner_offset + P.length
P.radius = .0245 * s
-- The fixed order is the iteration order everywhere, which keeps the policy
-- deterministic. Axle names match bike_geometry.lua's front_axle/rear_axle.
local layout = {
    { name = "front_left", axle = "front", side = "left" },
    { name = "front_right", axle = "front", side = "right" },
    { name = "rear_left", axle = "rear", side = "left" },
    { name = "rear_right", axle = "rear", side = "right" },
}
local pegs, order = {}, {}
for _, entry in ipairs(layout) do
    local axle = G[entry.axle .. "_axle"]
    local sign = entry.side == "left" and 1 or -1
    local function at(offset) return { axle[1] + sign * offset, axle[2], axle[3] } end
    pegs[entry.name] = {
        name = entry.name, axle = entry.axle, side = entry.side, sign = sign,
        axle_center = { axle[1], axle[2], axle[3] }, axis = { sign, 0, 0 },
        inner = at(P.inner_offset), outer = at(P.outer_offset),
        center = at(P.inner_offset + P.length / 2), radius = P.radius, length = P.length,
    }
    table.insert(order, entry.name)
end

function P.names() return { table.unpack(order) } end
-- Readback is a copy, so a caller cannot move a peg for everyone else.
function P.peg(name)
    local peg = pegs[name]
    return peg and M.copy(peg) or nil
end
function P.side_sign(side) return side == "left" and 1 or side == "right" and -1 or 0 end

-- The bike frame's origin is the measured centre of mass minus the rotated
-- authored COM, the same convention bike_visual.lua and bike_spawn.lua use.
function P.to_world(body, point)
    local q = M.normalized(body.orientation)
    return M.add(body.center_of_mass, M.turn(q, M.sub(point, G.com)))
end
function P.to_local(body, point)
    local q = M.normalized(body.orientation)
    return M.add(M.turn({ -q[1], -q[2], -q[3], q[4] }, M.sub(point, body.center_of_mass)), G.com)
end
function P.world(body)
    local out = {}
    for _, name in ipairs(order) do
        local peg = pegs[name]
        local q = M.normalized(body.orientation)
        out[name] = { center = P.to_world(body, peg.center), inner = P.to_world(body, peg.inner),
            outer = P.to_world(body, peg.outer), axis = M.turn(q, peg.axis), radius = peg.radius }
    end
    return out
end

-- Where a bike-frame point sits relative to one peg. `axial` is the outward
-- distance from the hub centre along the peg axis, `radial` the distance from
-- that axis, `edge_offset` how far the point falls past either end of the peg
-- (zero on the peg) and `surface_offset` its distance off the peg's surface.
function P.relation(name, point)
    local peg = pegs[name]
    if not peg or not M.vec(point) then return nil end
    local d = M.sub(point, peg.axle_center)
    local axial = M.dot(d, peg.axis)
    local radial = M.length(M.sub(d, M.mul(peg.axis, axial)))
    return { axial = axial, radial = radial, surface_offset = radial - peg.radius,
        edge_offset = math.max(0, P.inner_offset - axial, axial - P.outer_offset) }
end
return P

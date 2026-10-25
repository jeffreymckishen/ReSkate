# Rail probe and peg contact

`plugin/rail_probe.lua` finds rails, ledges and coping under the pegs and tires
from one `reskate.world.physics.probe_batch`. `plugin/grind_contact.lua` is a
Lua port of the standalone peg/rail contact solver. Both are pure: neither
queries, applies a force, moves the bike or keeps state. Neither is wired into
`main.lua`, and the runtime gates are unchanged (`RIDE_COMPOSITION_QUALIFIED`
and `ACTIVATION_QUALIFIED` stay false). Every tuning value below is our own
authored choice, not a measured game value.

```lua
local Probe = require("./rail_probe")
-- frame.body is the measured pose (force_math.lua shape); body is the
-- physics.create handle and sample its physics.read sample.
local plan = assert(Probe.plan(frame.body, {epoch = sample.epoch}))
local batch = reskate.world.physics.probe_batch(body, sample.epoch, plan.rays, plan.options)
local seen = Probe.decode(plan, batch)
-- seen.contacts = {pegs = {front_left, front_right, rear_left, rear_right},
--                  tires = {front, rear}}, ready for grind_policy.lua.
-- seen.sites[name] is the edge estimate behind each row.
```

## Today's SDK refuses this batch

The plan asks for `{require_contact = true, exclude_local_actor = true}`.

- Without `require_contact`, probe_batch hits carry `normal_available = false`
  and no `normal`. The decode needs a measured normal for every hit, so those
  sites are refused with `normal_unavailable`; it never guesses a normal.
- `exclude_local_actor = true` currently returns
  `local_actor_exclusion_unavailable` before any cast
  ([plugin-body-query.md](../../plugin-body-query.md)). The whole batch is then
  unavailable and so is every row.
- Dropping the option to get rows does not help. Decode reads an available
  batch only when `local_actor_excluded == true`,
  `owned_bodies_excluded == true` and `budget_exhausted == false`, the same
  facts `trick_runtime.lua` and `ride_runtime.lua` require. Otherwise every
  site is unavailable with `contact_query_unqualified`, because a ray that
  stopped on the rider or on the bike's own bodies would read as a rail and
  reach a force solver. A `Contact.decode` copy carries these facts under
  `query`, and there `epoch_matches` must also be true. A batch carrying both
  shapes is refused.

So the probe yields no contact in-game until the SDK qualifies actor exclusion,
and its classification has only been run on constructed rows.

## Layout

Six sites, in this order: `front_left`, `front_right`, `rear_left`,
`rear_right` (from `peg_geometry.lua`) and the `front` and `rear` tires (the
`bike_geometry.lua` axles). Each site casts five rays along gravity in the
order `center`, `left`, `right`, `ahead`, `behind`. `left` is the bike's +X
(rider left) and `ahead` its +Z, both laid flat against gravity, so a pitched
bike still samples level offsets. That is 30 rays; probe_batch allows 32.

| Site | Lateral offset | Along offset | Ray start | Ray end |
| --- | --- | --- | --- | --- |
| Peg | half the peg length (54 mm) | 30 mm | 50 mm above the peg's top | 250 mm below its underside |
| Tire | 50 mm | 40 mm | the axle | 250 mm below the tire |

The peg's lateral rays sit at its ends, so an edge found between the centre
and an end ray is under the peg. The along offset is short so a 50 mm rail
crossed at `grind_policy.lua`'s 0.7 rad approach limit still lies under both
along rays. Peg rays start above the peg so a rail pressed into it is still
seen from outside. Tire rays start at the axle, inside the excluded bike body.

The plan freezes its rays and keeps the float components each `vector`
actually carries; decode accepts only a plan that `plan` issued and checks
each hit against the segment really cast. With an `epoch`, decode accepts only
a batch carrying that exact epoch.

Budget: 30 rays spend 30 of the 64 logical requests per VM tick and between 30
and 60 of the shared 64 native casts (a ray may take two). With the two wheel
rays and up to 24 `bail_guard.lua` rays that is 56 requests, which fits, but
the worst case of 112 native casts does not. A ride that runs all three in
one tick will sometimes see `budget_exhausted`, which this decode refuses as
`contact_query_unqualified`.

## Decode

Rows may be raw probe_batch rows (Luau vectors) or `contact_runtime.lua`
copies (3-arrays). A clear row has no geometry and anything else it carries is
ignored. A site is refused, with its row unavailable, when any of its rows is
`unavailable` (`ray_unavailable`), is a hit without a normal
(`normal_unavailable`), has a nonunit or backfacing normal (`invalid_normal`),
lies more than 25 mm off its segment (`inconsistent_hit`), or is malformed.
Other sites still decode. A batch that is unavailable, malformed, of the wrong
length, for another epoch, or available without the rider and owned bodies
excluded and the budget unspent makes every site unavailable.

Heights are judged against the plane through the centre hit with its own
normal, so a banked or sloped surface reads as flat and an inclined rail reads
as a straight line.

- A **cross** sample (across the edge) is `level` within 10 mm with a normal
  within 0.25 rad of the centre's; `away` when it is clear, more than 20 mm
  below, or curving away (normal tilted more than 0.25 rad and more than 10 mm
  below); `rise` when more than 20 mm above; otherwise `uncertain`.
- An **along** sample (with the edge) is `on` within 20 mm of the plane, which
  lets it land on the flank of a rail crossed at a yaw; `away` or `rise`
  otherwise.

The edge is first assumed to run with the bike: `left`/`right` are the cross
pair and `ahead`/`behind` the along pair. Failing that it is assumed to run
across the bike (a tire on coping square to the edge), with the pairs swapped.
A hypothesis holds when no cross sample rises or is uncertain, at least one
cross sample falls away, no along sample rises and at least one stays on. Both
cross samples away is a **round rail**; one is a **ledge**. One along sample
away is reported as `edge_end` (`ahead`, `behind`, `left` or `right`), and the
centre stands in for it.

Tangent. Two hits on one cylinder sit at `p - R n` on its axis, so with
`D = p_a - p_b` and `E = n_a - n_b` the axis runs along `D - R E` and
`R = D.E / E.E`. For a round rail whose along normals differ, that fit gives
the tangent and radius (`tangent_source = "normal_fit"`), provided the radius
is within 0.2 m and the fitted direction is square to all three normals within
0.02. This is what recovers a rail crossed at a yaw, where `D` alone follows
the bike. Otherwise the tangent is `D` laid in the centre's plane
(`"along_samples"`). The sign points with the bike, or toward rider left when
the edge is square to it. An edge steeper than 1 rad is unavailable
(`edge_incline`).

Point and normal. A round rail's outward normal is its crest's (gravity up,
made square to the tangent), where a peg or tire rests under load. With a
radius, from the fit or from cross samples on the same rail's flank, the point
is on the crest (`crest_observed`); without one it is the centre hit. A
ledge's normal is the top's, and its lip is placed half-way between the level
centre hit and the dropped ray (`lateral_uncertainty`, 27 mm for a peg) on the
top plane, with `drop_side` naming the dropped side. `separation` is the
distance from the peg or tire surface to that point along the normal.

## Rows for grind_policy and grind_contact

Each row has the shape `grind_policy.lua` and `grind_contact.lua` share:
`{available, touching, point, normal, tangent, separation, surface_velocity,
friction}`, with friction 0.12 (the `GrindContact` default).

- An edge within reach is `touching = true` with its measured separation,
  however far below. grind.cpp acts only within 5 mm and grind_policy
  only within its `contact_gap`, so a distant edge never pulls the bike.
- Flat ground, a clear centre ray with no other hit within 100 mm of the
  site, or an irregular surface more than 100 mm below it is
  `{available = true, touching = false}`. A tire on flat ground is wheel
  support, not a rail contact; that stays with the wheel path.
- An irregular surface within 100 mm of the site, or under one end of a peg
  but not its centre, is unavailable (`irregular_surface`,
  `unclassified_surface`), never clear: it might be a rail.
- An edge whose centre hit has no measured surface velocity is reported as an
  estimate but its row is unavailable. Zero motion is never assumed.

## grind_contact.lua

`Contact.solve(body, contact, gravity, seconds)` ports `solve_grind` from
`standalone/bmx-movement/src/grind.cpp` with its contract in
`include/bmx/grind.hpp`. That solver is this repository's own reference code,
added in 29e541f on the portable arithmetic of
`include/bmx/detail/source/bmx_tire_dynamics.h` (itself from
`Engine/Game/BMX/bmx_tire_dynamics.h`); it is not game code, and both trees are
GPL-3.0. The port keeps its order of operations:

- Refuse a timestep outside 1/240 to 1/30 s, an invalid body, an unavailable
  contact, a gravity component over 100, a point coordinate over 1e6, a
  surface velocity component over 1e5, friction outside 0 to 10, or a unit
  normal and unit tangent whose dot product exceeds 1e-3.
- A contact not touching, more than 5 mm apart or more than 30 mm deep is
  valid and inactive, with zero force.
- Predict this step's gravity, then a unilateral normal impulse, then a
  friction impulse clamped to `friction * normal impulse`.
- A force over 40000 N or a torque over 4000 N m returns the zero, invalid
  result rather than a clipped one.

Gravity is not in the returned force; the host applies it. Replace the host's
response for this contact with the result and never solve one contact twice.
Lua bodies use the `force_math.lua` shape; an optional `inertia_orientation`
enters as the C++ principal frame. Absent contact fields take the
`GrindContact` defaults, so a clear grind_policy row solves as a default
contact.

## Tests

`plugin/rail_probe_tests.lua` (25 cases, 477 assertions) builds rows with an
analytic raycaster over cylinders, boxes and planes:

- the bounded layout and pose refusals;
- unavailable batches, and available batches (raw or `Contact.decode`
  copies) whose exclusion or budget facts are wrong or missing;
- per-site refusals (unavailable rays, missing, backfacing, short and long
  normals, off-segment hits, a malformed surface velocity flag);
- a surface under only a peg end, 15 mm steps, a curve too shallow to fall
  away, an along sample that rises and a post narrower than the offsets;
- the normal fit's radius and centre-normal guards, and the tangent sign on
  yawed coping;
- double pegs on a straight rail and a ledge, which `Grind.evaluate` reads as
  left double pegs, and a tire stall on coping square to the bike;
- rails crossed at yaws up to 0.65 rad (tangent within 1 mrad), off-centre
  rails, a fat pipe's radius, inclined and too-steep rails, a rail end, moving
  and unmeasured surfaces;
- flat and banked ground, near and far irregular surfaces, row-form
  independence and determinism.

The grind_contact cases mirror `observed_grind_contract` and the 100 Hz rail
checks in `standalone/bmx-movement/tests/tests.cpp`, plus the validity bounds,
both caps, the inertia frame, the 30 mm penetration window, surface motion
along the normal and along the rail with friction under its limit, and a
contact off the centre of mass where the normal impulse makes the slip that
friction removes.

```powershell
& 'C:\Users\Jeffr\Desktop\reskate\build\bmx\parallel-tricks-presentation-proposal-v1\harness\build\Release\presentation_luau_tests.exe' 'C:\Users\Jeffr\Desktop\reskate\contrib\bmx-lab\bmx-plugin\plugin' rail_probe_tests
```

These are constructed rows, not native contacts or in-game evidence.

## Limits

- Ledge yaw is not observed. A ledge top has one normal everywhere, so the
  tangent follows the along rays: a ledge crossed at a yaw reads as running
  with the bike, and a lip crossing an along ray can read as an edge end.
  Round rails do not have this limit because their normals show the yaw.
- Rails can fall between samples. A rail narrower than the gap between the
  peg's centre and end rays (54 mm) can lie under the peg yet miss all three.
- The lip of a ledge is known only to half the lateral offset.
- A peg pressed against a rail's side by a hard lean still gets the crest
  normal.
- Hits on different bodies are not told apart; the current native adapter
  omits the optional hit `body` token.
- One static batch cannot aim a follow-up ray, so nothing is refined within
  a tick.

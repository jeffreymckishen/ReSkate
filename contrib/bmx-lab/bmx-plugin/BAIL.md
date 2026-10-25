# Bail detection

`plugin/bail_policy.lua` is a Lua port of
[`Engine/Game/BMX/bmx_bail_policy.h`](../../../Engine/Game/BMX/bmx_bail_policy.h).
`plugin/bail_guard.lua` builds the guard-sphere rays it needs and decodes their
results. Both only compute results. Neither calls `reskate.*`, requests a fall,
moves a body or starts a recovery. Requiring them does nothing, and `main.lua`
and the package manifest do not load them yet. The runtime gates stay false.

```lua
local Bail = require("./bail_policy")
local Guard = require("./bail_guard")
local policy = Bail.new()            -- or Bail.new({slow_tilt_steps = 3})
-- Once per native body step, for the current mount, with one body and epoch:
local probe = reskate.world.physics.probe_batch
local plan = Guard.plan(frame, previous_frame)   -- frames: {serial, seconds, owner, body, query_frame}
if not plan then return end                     -- no qualified Framev1: no guard, so submit nothing
local q = frame.query_frame                     -- the read's Ride Framev1
local witness = Guard.witness(plan, probe(q.body_handle, q.physics_epoch, plan.rays, plan.options))
local second = witness.available and #witness.rays > 0
    and probe(q.body_handle, q.physics_epoch, witness.rays, witness.options) or nil
local decoded = Guard.decode(witness, second)    -- both raw probe_batch results
if decoded.available then
    local result = policy:step(Guard.policy_sample(plan, decoded, residual_or_nil))
    -- result.bail is true once per mount; the fall itself belongs to the caller.
else
    policy:pause()                              -- an unavailable read lends no tilt history,
end                                             -- and nothing is submitted for it
```

## Policy

The thresholds are the C++ initial prototype values (header lines 46-51), written
for this project. They are not BMX Streets settings. `Bail.defaults()`,
`Bail.tuning(overrides)` and `Bail.valid_tuning(t)` expose them and the bounds from
lines 72-85. An invalid tuning makes every mounted step report `invalid_sample`,
as the C++ does. A misspelt key also makes the tuning invalid.

`policy:step(sample)` returns a frozen result with `valid`, `bail`, `latched`,
`issue` (`none`, `invalid_sample`, `unsupported_step`, `stale_contact`), `reason`
(`none`, `hard_rider_contact`, `severe_contact_tilt`, `large_frame_impact_proxy`,
`swept_body_crossing`), `region` (`none`, `frame`, `torso`, `head`),
`contact_index`, `alignment`, `closing_speed` and `tilt_steps`. The checks run in
the same order as the C++. A duplicate serial changes nothing and is checked
before its rows are read. A run of slow severe-tilt frames needs consecutive
serials, the same region and continuous normals. Every hit row is validated
before any trigger fires, so a stale or malformed later row cannot be hidden by an
earlier severe one. A bail stays latched until `policy:reset()` or a new owner.
`policy:pause()` and a dismounted sample clear history only.

The C++ types do not map one to one onto Lua, so the port makes these choices:

- `owner` is one opaque token compared with `rawequal`: userdata, a string of 1 to
  128 bytes, or an integer from 1 to 2^53-1. It is never a game address. The
  C++ `Owner` bundles native pointers with `mount_token`, so the caller must give
  every new mount a new token. The string `"9"` and the integer `9` are different
  owners.
- `serial` and `query_serial` are u64 values. Each is either an exact integer up
  to 2^53-1 or a canonical decimal string, like native sample serials. Both forms
  of one value are the same serial. The consecutive check counts in decimal, so a
  large serial never passes through a double.
- `contact_index` is 1-based. It is 0 when there is no bail, while the C++ index
  starts at 0.
- `contacts` is a dense list of at most eight rows. A row that is not a plain
  table, or whose `hit` is not a boolean, counts as a malformed hit. A missing
  `query_serial` is malformed, while the C++ default of 0 would be stale. A row
  with `hit = false` is skipped, as in the C++. `mounted` must be a boolean.
  When `residual_available` or `swept_crossing` is missing, it counts as false.

## Guard rays

The eight guard spheres and their regions are those of
`Extension/BMX/bmx_collision_envelope.h`, read from `bike_geometry.capsules`
without changing it. Each guard is inspected the way `bmx_body_guard.h` does it.
There is always a world-down ray. A movement ray along the incoming velocity is
added when the speed is over 0.5 m/s and the direction is not nearly straight
down. A swept ray along the center path from the previous step is added when
the previous frame is the same owner's exact predecessor, `frame_identity`
calls the previous read the same body and source's coherent measured
successor, and the center moved between 2 cm and 1.5 m. A previous frame
without its Framev1 lends no history. That gives 8 to 24 rays, within the 32-ray
`probe_batch` limit. `plan.rays` has exactly the `{from = vector, to = vector}`
shape that `probe_batch` accepts. `plan.options` asks for measured contact
normals and for the rider to be excluded. Each guard's velocity is its point
velocity `v + w x (center - com)`, now and on the previous step, with that
step's own orientation, as in `impact_contacts`.

Each hit is then tested as in `bmx_body_guard.h` lines 57-80: it must face the
ray's direction to at least the 0.3 alignment gate, and its gap must lie between
6 cm clear and 15 cm overlap. A new center crossing on the swept path may reach
1.5 m. The C++ fits a five-ray patch at each hit. This port uses the probe's
measured hit normal instead, because the probe returns one.

A contact that is not a crossing also needs a witness, as in the C++. It is a
fresh ray along the measured normal through the guard center, from radius + 16
cm in front of the center to radius + 6 cm behind it. It must hit within 2.5 mm
of the measured plane. That witness can only be aimed after the first batch has
measured the normal, so it goes in a second batch. `Guard.witness(plan, batch)`
reads the first batch and returns the witness rays, from 0 to 24 of them.
`Guard.decode(witness, second_batch)` reads both. Pass nil as the second batch
when there are no witness rays. A witness that misses, or hits off the plane, is
counted in `decoded.counts.unwitnessed` and is never reported as contact. So a
finite lip's plane cannot become contact beyond its edge, while faces up to the
0.3 gate (about 72 degrees) are still found. A reported hit may lie up to 25 mm
off its own ray, so a witness row could report a point on a small face beside
the witness line. The separation is therefore never less than the sphere's
distance to the witness point it reports, minus its radius; a witness at the
foot of the perpendicular gives the plane separation unchanged. Two shortcuts keep the second batch
small, and neither changes a result. Hits of one guard with an identical normal
share one witness ray, because the C++ would cast the same ray twice. A guard
whose swept ray proves a crossing needs no witness, because the swept inspection
runs last and a crossing always wins (line 77). The swept ray is itself the
historical segment that the C++ casts as the crossing witness. Within a guard,
the smallest witnessed gap wins. Closing speed is the guard center's world
velocity along the normal, as in the C++. Surface velocity is not subtracted.

Budget: the two batches count against the 64 raycasts each plugin may start in
one VM tick (`plugin_vm.h`). Going over that limit is a Lua error, not an
unavailable batch. A step uses 8 to 24 rays plus 0 to 24 witnesses. In clear air
there are no witnesses, and a guard resting on one face needs one. The
`RAIL_PROBE.md` budget counts only the first 24 guard rays.

An unavailable batch is never treated as clear. The same holds for an exhausted
or unreported budget, a missing, extra, unknown or unavailable row, a hit with
no measured normal, a malformed hit, a batch whose rider or owned-body exclusion
fact is not true, or a witness batch from another epoch. This applies to either
batch. Any of these makes the whole decode unavailable, with no rows.
`Guard.policy_sample` then returns nil, so the policy cannot be stepped as if the
space were empty. This matches `impact_contacts` in
`Extension/BMX/bmx_chassis_ride.cpp`, which refuses the sample when a guard
search is unavailable.

Both batches must be raw `probe_batch` results: only the raw batch and row
fields, Luau vectors, and the read's epoch, which must be native userdata and
the same on both batches. A `Contact.decode` copy or its public snapshot is
refused. A ray that may have stopped on the rider or the bike's own bodies says
nothing about the world, so `local_actor_excluded` and `owned_bodies_excluded`
must both be true.

`frame.query_frame` is the read's Ride Framev1, and every plan needs one. It
must copy through `frame_identity` and be fresh, focused and outside the menu,
and the guard's serial, step and body arrays must be that read's. A frame
without it, or with one that fails any of this, has no plan
(`invalid_guard_frame`). The plan keeps a private copy. Both batches must then
carry its exact physics epoch, so a batch from another read, even one with the
same pose and ray count, is refused. Each batch also goes through the real
`Contact.decode` for that frame, which checks the raw schema, cast accounting
(`native_casts` present and between one and two per ray), that an available
batch has no reason, and measured surface motion on every hit. A decode that
is available with an `actor_exclusion_unqualified` force reason is refused.
`force_ready` is not read. The SDK batch carries only its epoch, so no body or
source field is looked for on it; the epoch ties it to the frame's body and
source.

There is no caller-bound plan. An earlier revision gave a frame without
`query_frame` a plan (`plan.bound == false`) and left its caller to match each
batch's epoch. On that path the guard checked no cast accounting, no reason on
an available batch, no measured surface motion and no body or source binding,
and lent history on the owner and serial alone. `ride_composer.lua` made every
plan that way, so the counterexamples the review packet
(`build/bmx/bail-guard-review-fix-v1`) refuses still passed on the path the
game would use. The plan now requires the frame, and the composer passes its
Framev1 or plans no guard. It submits a command only for a read that
`bail_policy` judged on that read's own decoded guard sample; a read with no
plan, a refused, missing or never-cast batch, witnesses that did not fit, or a
sample the policy refused submits no force, torque or hop impulse
(`RIDE_COMPOSER.md`, Guard binding).

In `contact_issue`, the checks of the facts read back from `Contact.decode`
(epoch match, cast accounting, both exclusion facts, and the
`actor_exclusion_unqualified` force reason) cannot be reached: `batch_rows`,
the epoch check or `Contact.decode`'s own rejection refuses those batches
first. Only its measured-surface-motion check refuses on its own. The others
are kept, so the decoder's verdict stands on its own if the earlier checks are
ever reordered, and the both-batches table in `bail_policy_tests.lua` pins
which check refuses each case, and with what reason, on each batch.

These are structural checks on constructed values. Lua cannot authenticate
native userdata, and none of this authorizes a fall. The caller also owns the
policy's history: it pauses or resets the policy when body, source, gate or
read continuity is lost, and gives each new mount a new owner token. The
composer passes a previous frame only from a read the policy judged, so the
guard's sweep history and the policy's serial history restart together: the
policy refuses a swept crossing on a step that does not follow its last one,
so history lent across an unjudged read would turn the next crossing into
`invalid_sample`.

## Evidence and limits

`bail_policy_tests.lua` runs on the isolated presentation Luau runner and reports
`cases=21 assertions=1430`. It ports every case of
`Engine/Game/BMX/Test/bmx_bail_policy_tests.cpp`. It adds 28 parity steps
worked out by hand from the header, checks each threshold 1e-6 either side,
and covers every reason and issue, the latch, malformed and stale rows, owner
and serial forms, and the tuning bounds. It runs the
`bmx_body_guard_tests.cpp` scenarios on whole bike poses, including the oblique
45 degree face and the finite lip. It also checks:

- exact ray endpoints, and every ray gate on both sides of its limit;
- faces from 0 to 70 degrees, which are witnessed;
- the smallest-gap rule;
- witness refusals;
- spinning and rotating bodies, where the guard velocity and the previous center
  come from the angular velocity and the previous orientation;
- the raw-query binding of both batches: another read's epoch (including a stale
  all-clear batch of the same size), a missing epoch, either exclusion fact false
  or missing, bad cast accounting, a missing budget fact, invented or decoded
  fields, unmeasured surface motion, and a `Contact.decode` that is available
  with `actor_exclusion_unqualified`;
- a table of 26 edits made to each batch in turn (52 refusals), from a wrong
  epoch to a decoded row field, with the reason each is refused with;
- Framev1 coherence of the frame and the history it lends, and no plan for a
  frame without its Framev1, the composer's former `{serial, seconds, owner,
  body}` frame included;
- a witness point beside its own ray on a small face, which keeps its distance
  and cannot seed a tilt.

The test frames carry synthetic Framev1 values with `newproxy` handles. The
revision that first bound plans to a Framev1 recorded 67 of its checks failing
against the guard before it. Against the guard just before the binding became
mandatory (the one with the caller-bound path), 3 of these 1430 checks fail,
the three that ask for no caller-bound plan: that guard already held a frame
with its Framev1 to everything above. What it lacked was refusing a frame
without one, which was the path the composer used.

`ride_composer_tests.lua` now drives the guard through the composer, with a
Framev1 on every read and raw batches shaped as `plugin_api_physics.cpp`
builds them. It refuses each of the review packet's nine counterexamples
through the composer's `plan`, `witness` and `step`, on both batches, and
checks that the composer's own bound plan refuses them in the guard too. A
scratch run through the composer before this change (not in the tree) showed
two of the nine reaching `bail_policy`: a guard batch without `native_casts`,
and a read with no coherent frame, which also submitted its command. Four
related cases did too: zero casts, an available batch with a reason, an
unmeasured hit, and an unfocused read. The other seven were already refused on
that path, by the composer's own epoch check, the guard's exclusion check and
the finite-face separation bound. After the change all of them are refused and
the unbound reads submit nothing. Every riding scenario number in
`RIDE_COMPOSER.md` is unchanged.

A refused read at first still submitted its command. Through `plan`, `witness`
and `step` on a rider rolling at 4 m/s with R3 pressed, every refused
counterexample batch gave a submitted command with the hop impulse (477 N s),
the same as the judged control, and so did a guard or witness batch never
cast, a witness never called, refused witnesses, a one-batch allowance and a
sample the policy refused (a scratch run of today's composer test against the
earlier composer, not in the tree: all 23 such reads submitted). The composer now
fails closed on every read `bail_policy` does not judge, and its tests check,
for each of those reads, that no force, torque or hop impulse is submitted and
the hop is cancelled. The finite-edge cases are judged without the false
contact and submit normally. The 4-batch riding scenarios in `RIDE_COMPOSER.md`
are unchanged; under an explicit one-batch allowance nothing is submitted at
all. Core grants four probe batches per native serial (`bike_runtime_core.lua`,
`probe_batch_adapter`, `:21-43`), the composer defaults to that allowance, and
so the guard and witness lanes can be cast through Core, each as its own batch.

A 1000-sample seeded run matches line for line the output of a scratch C++
program built `/W4 /WX` against the real header. That program is not in the
tree. The intended `Extension/Plugins/Test/bmx_bail_parity_fixture.inc` has not
been written yet.

All of this is constructed evidence, not evidence from the game. Several things
remain unproven. The probe normals and the rider exclusion have not been
qualified in the game. The constructed casts are exact planes. On a real
triangle mesh, one face may report slightly different normals to different
rays, which costs more witness rays, and a measured normal may differ from the
C++ patch fit on curved or broken surfaces. Neither batch has run against the
game. The native adapter currently refuses
`exclude_local_actor` with `local_actor_exclusion_unavailable`, so a riding guard
query is always unavailable today. Nothing computes the force/velocity residual
proxy yet; the caller passes it in. No fall is dispatched, and no recovery module
is changed. `ride_composer.lua` submits nothing for a read `bail_policy` did not
judge, so with that native refusal it would submit nothing in game today
(`RIDE_COMPOSER.md`, Gaps found, 13). The batch allowance is not what stops it:
Core grants four probe batches per native serial (`probe_batch_adapter`), the
composer defaults to that allowance, and the guard and witness lanes can
therefore be cast through Core. The native exclusion refusal leaves every
riding guard query unavailable, and an unavailable guard is never clear.

# Ray batches beside an owned body: `reskate.world.physics.probe_batch`

`reskate.world.physics.probe_batch(body, epoch, rays, options?)` needs both `world.physics` and
`world.raycast`, and is client phase only. `body` is an opaque handle from `physics.create`
([owned native bodies](plugin-owned-bodies.md)); `epoch` is the opaque token from that body's
`physics.read` sample, which keeps the whole sample (position, rotation, velocities, mass and
inertia) inside. A batch grants no force, motion, pose or ownership.

The native side sends no ignored-owner IDs or ignored entities and looks up no owner. Each actual
nearest hit must pass the pinned native shape reader, the current shape-to-body association, the
body's own capacity and allocation check and its current generation. An excluded or unqualified
nearest hit makes the whole batch unavailable; the batch never skips it, casts through it or
substitutes a farther surface. The reason says which: `owned_body_hit` or
`hit_identity_unqualified`.

```lua
local sample = assert(reskate.world.physics.read(body))
local batch = reskate.world.physics.probe_batch(body, sample.epoch, {
    {from = sample.position, to = sample.position - vector.create(0, 1, 0)},
})
if batch.status == "available" then
    local ray = batch.rays[1]
    -- What a contact means, and what to do about it, is the plugin's decision.
elseif batch.reason == "body_epoch_or_observation_changed" then
    -- Decide later. The SDK does not relabel or replay the query or a command.
elseif batch.reason == "body_exclusions_unavailable" then
    -- The native association data is unavailable; no ray was cast.
end
```

## Rays and options

There are 1 to 32 rays, each exactly `{from = vector, to = vector}` in world metres. Positions must
be finite and within 100 km of the map origin; a segment must be at least 10 micrometres and at
most 1000 m long (or the host's lower limit). Invalid arguments are Lua errors. Lists must be
dense arrays, and any other field is refused.

The options are `exclude_bodies`, `exclude_local_actor`, `require_contact`, `query_preset`,
`include_shape_categories`, `require_named_actor_categories_absent` and `include_hit_owner`, each
described below; every boolean option takes only an actual boolean.

`exclude_bodies = {other_owned_body, ...}` adds at most eight more of this VM's bodies, each in the
same native world and still owned. The anchoring body is always excluded. The native ray filter
takes owner indices, not body or shape handles, and owned capsules have no native owner, so the
batch sends an empty filter and checks the nearest hit's body against the owned exclusions
instead. Plugins cannot supply addresses, native indices or actor IDs.

`exclude_local_actor` defaults to false. `true` returns `local_actor_exclusion_unavailable` before
any cast: the placement root lookup takes a packed entity key, while the local skater is known
here only as a SkaterEntity pointer, and a verified conversion does not exist yet. Leaving it out
does not make a batch safe from hitting the local skater.

## The result

The result has `status = "available"|"unavailable"`, `native_casts`, `budget_exhausted`, the exact
`epoch` passed in, and a dense `rays` list of the requested length; an unavailable batch also has
a `reason`. `local_actor_excluded` reports whether the backend established that exclusion for an
available result that asked for it. It is the backend's fact, never a copy of the request's flag,
and the native backend never sets it, so it is false today. A backend result that claims it, or
`named_actor_categories_absent`, without the matching request, or claims both, is refused as
`invalid_query_backend_result`. `owned_bodies_excluded` on an available batch says the nearest hits
were checked against the owned bodies; it is not native filtering, and not proof that a whole ray
is empty.

Each available ray has `status = "clear"|"hit"`. A hit adds its `position` and `fraction` on the
segment, the flags `normal_available` and `surface_velocity_available`, and `motion`. With the
default options the measurements are left out and `motion` is `"unknown"`. A clear ray has no
geometry or measurements. A hit may also carry an opaque, equality-only body observation token;
no native body, collider, face or feature identity is exposed. The current native adapter omits
that optional token.

## Measured contact

`require_contact = true` turns on the contact readers (their bytes are compared first), the reads
of the hit's result vectors and of the hit body's motion, and their closing checks. Every hit then
needs both a validated `normal` and `surface_velocity`, or the whole batch is
`contact_measurement_unavailable` with its actual cast count. A clear ray stays clear.

The hit point and normal are copied while the native ray result is still alive. The point must lie
on the segment within 2 cm; a malformed, non-finite, non-unit or backfacing normal is refused,
never normalised or flipped. The point's motion is read from the hit body's own current arrays as
`linear + angular x (contact_point - body_position)`. An available value has `motion =
"measured"`; zero motion is an instantaneous measurement, not proof that a surface never moves.
Every accepted hit's rings are read again in the final whole-batch check, even when several shapes
share one body. These are endpoint observations: they do not pin a native allocation or rule out
reuse between reads.

## Query presets

`query_preset` chooses the fixed native filter every ray in the batch sends. `"camera"`, the
default, is the filter the game's camera ray sends, as `world.raycast` and `world.probe` do. `"terrain"`
sends the game's own physics query preset of that name: one category bit. `"all"` is a diagnostic
with every filter bit set, so the ray tests every shape whose categories are nonzero, actors'
shapes included; it also needs `world.physics.observe`, checked before any budget or cast is
spent. An `"all"` hit may be the local skater's own shape. Any other value, a number or another
spelling is a Lua error before anything is spent, and no raw mask can be passed: the native values
live in `Engine/Game/Build/20260929/park_editor.h`.

A preset selects which shapes the ray tests; it does not say what a hit belongs to. A `"terrain"`
hit is not proof of terrain, static geometry or a surface free of the skater and board, and a
`"terrain"` clear means only that no shape with that one bit was on the segment. The game's Static
preset lacks the Terrain bit, so some ramps and props are not tested at all. Every other rule is
the same, and a refused terrain ray falls back to nothing.

A batch that names a preset gets one more field on every result, `requested_query_preset`, which
repeats the request; `status`, `native_casts` and each ray say what actually ran. A batch without
the option does not have that field.

## Shape categories

`include_shape_categories = true` asks for `in_categories` on each qualified hit: the hit shape's
InCategories mask as read after the ray, a whole number from 0 to 4294967295. It needs
`world.physics.observe` as well, checked only when the option is true and before anything is
spent; without it the call is a Lua error. Leaving it out reads nothing and adds no field.

`in_categories` appears only on a hit row of an available batch that asked for it. Missing means
unavailable; `0` is a known empty mask. It is missing when the build's category getter no longer
has its pinned bytes, when the array or element cannot be read, or when either changed between the
paired reads or before the closing check. It is read only after the hit passed the shape reader,
the association and the owned-body exclusion, at the hit's own shape index (so two shapes of one
body keep their own values), and copied into the result only after the closing check. An identity
change seen then still refuses the whole batch as `body_epoch_or_observation_changed`; a change to
the category alone drops that ray's value.

This is one mask as read after the ray. It does not identify an actor, a floor or static geometry,
says nothing about collision-time filtering, excludes nothing and grants no force.

## Named actor categories

`require_named_actor_categories_absent = true` is a refusal-only check on the hits a batch returns.
It needs only `world.physics` and `world.raycast` and shows no category. A call that names the
option, true or false, gets `named_actor_categories_absent` on every result. The named actor
categories are the build's category bits whose definitions name a character, ragdoll, character
proxy, skateboard or skater (bits 2, 3, 21, 25, 26, 28 and 29), plus bit 31, which only the
SkateboardCollisionHelper shape template carries: `0xB620000C`, in `park_editor.h`. Bits 6 and 12
of the Character template are left out, because the Terrain and DynamicGameplay templates carry
them too and real floors would be refused.

Before any cast the batch is refused as `named_actor_categories_unavailable` when the preset's
filter shares a bit with those categories (`"all"`) or the category getter's bytes do not match;
`exclude_local_actor = true` is still refused first. Otherwise each hit's InCategories is read as
`include_shape_categories` reads it, and after the closing check every hit row is judged in order:
an unreadable or dropped value refuses the batch as `hit_categories_unavailable`, a value sharing
no bit with the filter as `hit_categories_inconsistent`, and a value with a named bit as
`hit_named_actor_category`. Each refusal keeps its actual cast count. Clear rays pass.

`named_actor_categories_absent = true` means the filter the ray sent shares no bit with the named
categories, every returned hit had a readable mask unchanged at the closing check, and each mask
overlapped the filter and had no named bit. It is not actor exclusion and never sets
`local_actor_excluded`: a shape of an actor or prop that carries only world-like bits passes, and
`"camera"` also tests bits that other players, vehicles or Build Kit pieces may carry.

## Hit owners

`include_hit_owner = true` asks for each qualified hit's shape owner slot, read and checked exactly
as `in_categories` is. It needs `world.physics.observe`. A hit row then has `owner_assigned`
(false for the build's unassigned slot) and, only when that is true, `owner`: a locked userdata
that supports `==` and nothing else. Both are missing when the slot could not be read or changed
before the closing check. Two `owner` tokens are equal when they come from the same plugin
instance, SDK world generation and measured epoch serial and their slots were equal, so single-ray
batches against one epoch can be compared. The slot, its index, kind and generation never reach
Lua, and equal tokens say nothing about whose owner it is.

## Optional body observations

An optional `body` token compares equal only within that returned batch: two qualified hits on the
same current native body compare equal. Tokens from different batches compare unequal, even if the
physical body happens to be the same. A token cannot be submitted, read, released or used as an
exclusion handle. It represents a body observation, not a collider, face or surface feature, and
carries no proof of static or moving contact. An unqualified identity is omitted while otherwise
valid hit geometry may still be returned.

The native adapter's private association check uses the actual hit shape, the shape-to-body index
table and then the distinct body's capacity, allocation and u32 generation. Matching shape and
body index/generation numbers cannot establish that conversion. Every returned pair is checked
again before publication, including different shapes sharing one body. These checks establish a
current association only: the hit reader obtains a byte generation after the ray, so collision-time
index reuse and generation wrap are not ruled out. No arbitrary-index conversion API or universal
foreign shape-array capacity is exposed or claimed.

## The observation window

Before and after the rays, the batch checks the owned anchor, the client context, the native world
and state, the SDK world and body generations, the owned exclusions and the exact step epoch of the
sample. Both checks also need the latest published sample and a fresh read-only native read to
match every lane of the token's sample exactly, so even a same-epoch `read` or `receipt` that
replaced the latest sample cannot rebind an older token. A changed observation discards **every**
ray. These checks qualify one local observation window; they do not lock the physics world or
freeze its arrays between reads, and a clear result does not prove a whole region has streamed.

A batch publishes no sample, observes no successor, consumes no pending command and acknowledges
nothing. A later command from the same epoch still has to pass `submit`'s own checks.

## Budgets and reasons

Each ray spends one of the VM's 64 raycasts per tick, the limit `world.raycast`, `world.pick`,
`world.probe` and `session.raycast` share, even when the backend is unavailable and casts nothing.
Separately, all Lua `world.raycast`, `world.pick`, `world.probe`, `session.raycast` occlusion and
body-batch paths share a hard limit of 64 **actual native casts** per tick, including exclusion
retries. Each batch ray may use at most two. The native body-batch ray uses one: it ignores nothing
and never casts through its nearest hit. Other bounded query paths may spend their permitted
exclusion retry, so the shared native budget can run out before the logical requests do.
`native_cast_budget_exhausted` means the shared casts ran out; `ray_cast_limit_exhausted` means a
ray's two casts could not settle a result. Both refuse the whole batch and set `budget_exhausted`.

Before any cast: `client_phase_unavailable`, `local_actor_exclusion_unavailable`,
`named_actor_categories_unavailable`, `body_exclusions_unavailable` (association data
unavailable) and `query_preconditions_unavailable` (the backend could not run before any ray). A
C++ exception that escapes the query adapter after entry is `query_backend_exception`, which
closes the rest of the tick's casts and leaves out `native_casts`; a malformed backend count does
the same as `invalid_query_backend_result`. The helper counts immediately before a native call
and installs result cleanup first, so an exception it catches can retain that exact attempted-call
count as an ordinary unavailable result, without retrying. These C++ boundaries do not establish
recovery from every native fault or a failing cleanup routine. After casting: `query_unavailable`, `owned_body_hit`,
`hit_identity_unqualified` (each with the cast that found it), `contact_measurement_unavailable`,
`body_epoch_or_observation_changed`, `invalid_query_backend_result`, and the three named-category
reasons. An identity lost while reading a hit's category or owner is
`body_epoch_or_observation_changed`, because the closing check sees the same loss.

## Tests, and the game

`Engine/Game/World/Test/body_query_tests.cpp`, `body_contact_read_tests.cpp` and
`body_shape_categories_tests.cpp` cover the batch contract, contact reads and categories over
constructed values and fake memory. `Extension/World/Test/owned_body_source_tests.cpp` runs the
service's `probe_batch` over a constructed world. The plugin tests cover the binding:
`owned_body_batches_*`, `body_contact_details_are_known_and_epoch_bound`, the shape-category and
exclusion-fact fixtures, and the measured-contact fixture
(`Extension/Plugins/Test/fixtures/measured-contact`), a diagnostic mod that can also be run in the
game.

These constructed tests do not run the game's ray or physics. The merged source composition still
needs its own native qualification; measurements and observations from another source/runtime do
not qualify it. The historical checkpoints below retain their original limits and identities.

## Historical BMX branch checkpoints

The earlier geometry-only replacement passed a clean Release runtime build and
six focused CTest suites. The bounded in-game result below qualifies one positive geometry batch.
It does not activate a vehicle or establish complete contact accuracy, motion
qualification or performance.

The first native query-plus-force trial used source `716f2ddd` and runtime
`06E9CEA1755B156034575327A20474A1E84FD27A5CF5E7763BFEAD2BDA43858C`.
Two explicit Start actions covered clock warmup and the trial; one 12 kg capsule
was created. Its first batch returned `query_unavailable`, zero reported native casts and
zero submitted force packets, then release was accepted. The archived ledger is
`build/bmx/lua-owned-query-phase-trial-v1/native-storage.json`. Query composition
is unqualified, and that result does not identify the refusal's actual cause.
The typed-reason source changes above add diagnosis; they do not establish a
runtime repair or a successful query.

A second trial used source `f395757d` and runtime
`21BABF8D4E6B18BC4C3ED45A2B3AA74AF86A08140623B25A5961B94793E2AC21`.
The unchanged Lua fixture again requested actor exclusion. Its first batch returned
the precise reason `local_actor_exclusion_unavailable`, with zero native casts,
zero published commands and an accepted release to a retained parked slot.
The ledger is `build/bmx/lua-owned-query-phase-refusal-native-trial-v2/native-storage.json`.
This identifies the refused stage, not a successful query. The unqualified
pointer-to-key lookup has now been removed; requested actor exclusion remains
unavailable until the native conversion and exclusion contract are established.

Static inspection of the supported build also identified a separate handle-domain
error: the hit reader and its validator use the shape pool and byte generations.
The adapter previously tested those bits against the distinct rigid-body pool
before creating a body token. That interpretation is removed. A second inspection
proved that the ignored-ID list is compared with a shape's owner index, not its
shape or rigid-body index. Owned capsules require an unassigned owner, which
bypasses that list's membership loop. Commit `4222ecf` withdrew that incorrect
native path. The replacement uses zero native ignored IDs and a conservative
post-hit current-body check. A retail query consumer confirms the actual
ray-result-to-shape-reader interface; the native association getter independently
confirms the shape-to-body index table. This static evidence supports the source
implementation; actor coverage, normals and surface velocity remain unqualified.

On 2026-10-23, the [inert geometry diagnostic](bmx-lab/native-geometry-trial/README.md)
created one 12 kg capsule and checked two actual world-surface hits in one batch.
With actor exclusion requested, it first returned the expected
`local_actor_exclusion_unavailable` and zero native casts. With that option
explicitly false, it returned two hits from two actual casts, matching their
four-metre segments and leaving the full published body sample unchanged.
It published no force command and accepted release to a retained parked slot.
The runtime SHA256 was
`EB601CF97A0719FCC1F6159E5C9E50083AFB254D807BFFED34BA1C4474C63798`;
the tested source patch was committed as `25913f2`.

The two rays did not intersect the small owned capsule, so this does not exercise
native self-hit rejection. It also does not qualify requested actor exclusion,
contact-query/force composition, normals, surface velocity, active-body unload,
wheel support, rider control or vehicle behavior. Both hit motions remain
`unknown`. The diagnostic manifest was withdrawn after release, its watcher
unloaded the VM, and the isolated game then exited normally.

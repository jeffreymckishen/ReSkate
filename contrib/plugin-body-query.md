# Ray batches tied to an owned body's measured epoch

`reskate.world.physics.probe_batch(body, epoch, rays, options?)` requires both
`world.physics` and `world.raycast`, and is client phase only. `body` is an opaque
handle from `physics.create`; `epoch` is the opaque observation token from that
body's `physics.read` sample. It retains that immutable complete sample internally,
including position, rotation, linear/angular velocity, mass and inertia. A query
grants no force, motion, pose or ownership authority.

The native adapter has a conservative query path with actor exclusion disabled.
It sends no native ignored-owner IDs or ignored entities, and does no owner
lookup. Each actual nearest hit must pass the pinned native shape reader,
current shape-to-body association, independent body capacity/allocation and
current generation checks. An excluded or unqualified nearest hit makes the
whole batch unavailable; the adapter never skips it, retries through it or
substitutes a farther surface. The reason says which: `owned_body_hit` or
`hit_identity_unqualified`. In-game qualification of this replacement path
remains required. Actor exclusion still returns
`local_actor_exclusion_unavailable` before any native cast.

```lua
local sample = assert(reskate.world.physics.read(body))
local batch = reskate.world.physics.probe_batch(body, sample.epoch, {
    {from = sample.position, to = sample.position - vector.create(0, 1, 0)},
}, {exclude_local_actor = true})
if batch.status == "available" then
    local ray = batch.rays[1]
    -- Contact fitting and vehicle decisions belong to the plugin.
elseif batch.reason == "body_epoch_or_observation_changed" then
    -- Defer this decision. The SDK does not relabel or replay the query or a command.
elseif batch.reason == "local_actor_exclusion_unavailable" then
    -- The current native adapter cannot qualify this exclusion. Keep the vehicle inactive.
elseif batch.reason == "body_exclusions_unavailable" then
    -- Native association metadata is unavailable; no ray was attempted.
end
```

There are 1 to 32 rays, each exactly `{from = vector, to = vector}` in world
metres. Positions must be finite and within 100 km of the map origin. Segments
must have a nonzero direction, be at least 10 micrometres long and at most 1000 m
long, subject to a lower configured host limit. Invalid arguments raise a Lua
error. Lists must be dense arrays; extra fields are refused.

Options are `exclude_bodies = {other_owned_body, ...}`,
`exclude_local_actor = true|false`, `require_contact = true|false`,
`query_preset = "camera"|"terrain"|"all"`, `include_shape_categories = true|false`,
`require_named_actor_categories_absent = true|false` and
`include_hit_owner = true|false` (all described below). At most eight additional opaque body handles
are accepted. Every exclusion must still belong to this VM, its current native
world and a fresh owned generation. The anchoring body must always be excluded.
The native ray filter consumes owner indices, not body or shape handles, and the
SDK-owned capsules have no native owner. The adapter supplies an empty filter
list and checks the nearest hit's current body against the owned exclusions.
Native body references are resolved internally; plugins cannot supply addresses, native
body indices or actor IDs. `exclude_local_actor` defaults to false. Setting it to
true currently returns `local_actor_exclusion_unavailable` before any native cast.
The placement root resolver accepts a packed entity key; the current local actor
anchor is a raw SkaterEntity pointer. Passing that pointer as a key is invalid.
A verified actor conversion and a compatible exclusion domain are still required.
Omitting actor exclusion does not establish rider-safe vehicle contact queries.

The result has `status = "available"|"unavailable"`, `native_casts`,
`budget_exhausted`, the exact supplied opaque `epoch`, and a dense `rays` list
of the requested length. An unavailable batch also has a `reason`.
`local_actor_excluded` reports whether the backend established that exclusion
for an available result that asked for it. It is the backend's fact, never a copy
of the request's flag; an earlier binding echoed `exclude_local_actor` there, and
that echo is removed. The native backend never sets it, so it is false today. A
backend result that claims it, or `named_actor_categories_absent`, without the
matching request, or claims both at once, is refused as
`invalid_query_backend_result`. The available
`owned_bodies_excluded` flag describes nearest-hit postclassification against
owned exclusions, not native ignored-owner filtering or proof the whole ray is empty.
Each available ray has `status = "clear"|"hit"`. A hit adds its segment
`position` and `fraction`, known flags `normal_available` and
`surface_velocity_available`, `motion`, and optionally an opaque `body` token.
With default options the new measurements are omitted and `motion` is `"unknown"`.
Surface/feature IDs and native identity fields stay private. A clear ray has no
geometry, contact measurements or body token.

`require_contact` defaults to false. Only an explicit true value enables the new
contact fingerprints, native result-vector reads, foreign-body motion reads and
their closing fences. Every hit then needs both a validated `normal` and
`surface_velocity`; otherwise the entire batch reports
`contact_measurement_unavailable`, retaining its actual cast count. A clear ray
remains clear without invented contact values. The option does not imply actor
exclusion: a riding caller must still request `exclude_local_actor=true` and keep
the vehicle inactive on its current zero-cast refusal.

The contact path copies the actual native hit point and normal while the ray
result's release scope remains alive. The point must agree with the segment
interpolation within 2 cm; malformed, nonfinite, nonunit or backfacing normals
are refused, never normalized or flipped. Point motion comes from that hit's
separately qualified current body arrays as
`linear + angular cross (contact_point - body_position)`.
An available value has `motion="measured"`; zero motion is an instantaneous
measurement, not proof that a surface is permanently static. No dynamic bit,
inverse mass or stationary image substitutes for this measurement. Every
accepted hit's ring headers and values are rechecked separately during the final
whole-batch shape/body/clock fence, even when several shapes share one body.
These remain endpoint observations; they do not pin native allocations or rule
out same-value reuse, generation wrap, or a write after the last observation.

**Query presets.** `query_preset` chooses which fixed native filter every ray in the batch sends.
It defaults to `"camera"`, the filter the native camera ray uses and the one
every earlier batch sent. `"terrain"` sends the game's own physics query preset
of that name instead: one category bit, nothing else. `"all"` is a diagnostic
preset with every filter bit set, so the native ray tests every shape whose
InCategories is nonzero, actors' shapes included; a shape whose categories are zero
is still never tested. It needs `world.physics.observe` as well, checked before the
logical ray budget or any native call is spent; without it the call raises a Lua
error. It is for seeing what the other presets skip, never for support: an `"all"`
hit may be the local actor's own shape. Any other value, a number
or a differently cased name raises a Lua error before the logical ray budget or
any native call is spent. There is no way to pass a raw mask; the native values
live only in the supported build's `park_editor.h`.

A preset selects which shapes the native ray tests. It does not classify what a
hit belongs to. A `"terrain"` hit is not proof that the surface is terrain,
static, part of the map or free of the rider and board, and a `"terrain"` clear
means only that no shape matching that one category was on the segment. The
game's Static preset lacks the Terrain bit, so some ramps and props can be
missed entirely; a clear is never "no collision exists". Every other rule is
unchanged: one nearest hit per ray, the same owned-body and identity refusals,
the same `require_contact` measurements and closing fences, and
`exclude_local_actor = true` still returns `local_actor_exclusion_unavailable`
before any native cast. No camera fallback or retry is made when a terrain ray
is refused, and no zero velocity is assumed from the preset's name.

A batch that names a preset gets one more field, `requested_query_preset`, on
every result (hit, clear or refusal). It repeats the request. It is not evidence
of which filter the native ray applied or of what was hit; `status`,
`native_casts` and each ray's fields describe what actually ran. A batch without
the option has exactly the earlier fields, so code that allow-lists them keeps
working. `local_actor_excluded` stays false on a terrain refusal.

```lua
-- A read-only observation: two downward wheel rays over a floor the plugin
-- already knows is clear, with no force, impulse or follow command.
-- front and rear are the plugin's own wheel positions.
local batch = reskate.world.physics.probe_batch(body, sample.epoch, {
    {from = front + vector.create(0, .5, 0), to = front - vector.create(0, .5, 0)},
    {from = rear + vector.create(0, .5, 0), to = rear - vector.create(0, .5, 0)},
}, {query_preset = "terrain", require_contact = true, exclude_local_actor = false})
if batch.status == "available" then
    -- batch.requested_query_preset == "terrain"; each hit has a measured normal
    -- and surface_velocity. Decide yourself whether this is the floor you expected.
elseif batch.reason == "contact_measurement_unavailable" then
    -- A hit lacked a measured normal or motion. Nothing was guessed.
end
```

The preset lane is covered by source and constructed-ABI tests. No in-game
terrain batch has been run yet: whether `"terrain"` reaches a given floor, ramp
or prop, and whether it can return the rider's own shapes, is still unmeasured.

**Shape categories.** `include_shape_categories = true` asks for one optional,
read-only number on each qualified hit: `in_categories`, the hit shape's
InCategories mask as read after the ray, an exact whole number from 0 to
4294967295. The option needs three permissions: `world.physics` and
`world.raycast` as for every batch, and `world.physics.observe`, which is checked
only when the option is true, before the logical ray budget or any native call is
spent. Without it the call raises a Lua error; the same plugin's ordinary batches
still run. Only an actual boolean is accepted. Leaving the option out, or `false`,
reads no category and adds no field.

`in_categories` appears only on a `status = "hit"` row of an available batch that
asked for it. Missing means unavailable; `0` is a known empty mask. It is missing
when the supported build's own category getter no longer has its pinned bytes,
when the category array or element cannot be read, or when the array or value
changed between the paired reads or before the closing fence. A clear ray never
has one, and a refused batch has none. The option adds no availability flag,
reason, native index, handle, generation or owner, and no batch-level field.

The adapter reads the value only after the nearest hit has passed the shape
reader, the shape-to-body association and the owned-body exclusion. It indexes
the native category array with the hit's own shape, not its mapped body, so two
shapes of one body keep their own values. It reads the array pointer and value
twice, between two checks of the same World/state, listener epoch and sample, and
shape/body association, and the closing fence repeats all of that. An identity
change found there still refuses the whole batch as
`body_epoch_or_observation_changed`; a change to the category alone only drops
that ray's value. Values are copied into the result after the closing fence, so a
refused batch can never carry one. Native cast and logical ray accounting,
contact requirements, presets and exclusions are unchanged.

This is read-time evidence about one mask. It does not identify an actor, a
floor, terrain, static geometry or support, says nothing about the filter the
native ray applied at collision time, does not exclude the local actor and grants
no force. The ray supplies no collision-time shape generation, so a category that
changed before the first read, or changed and returned between reads, cannot be
seen. A clear ray says nothing about categories beyond its own segment. There is
no raw filter option, ignored-ID list, farther-hit search, extra native ray or
fallback query. The field is covered by source and constructed-memory tests only;
no in-game batch has asked for it yet.

**Named actor categories.** `require_named_actor_categories_absent = true` is a
refusal-only check on the hits a batch returns. It needs only `world.physics` and
`world.raycast` and shows no category. A call that names the option, true or
false, gets one more batch field, `named_actor_categories_absent`, on every result,
in the same way as `requested_query_preset`; a call without it keeps the earlier
fields. The named actor categories are the supported build's category bits whose
definitions name a character, ragdoll, character proxy, skateboard or skater (bits
2, 3, 21, 25, 26, 28 and 29), plus bit 31, which only the SkateboardCollisionHelper
shape template carries: `0xB620000C`, in `park_editor.h`. Bits 6 and 12 of the
Character template are left out, because the Terrain and DynamicGameplay templates
carry them too and real floors would be refused.

Before any cast, the batch is refused as `named_actor_categories_unavailable` when
the preset's native filter shares a bit with those categories, which is `"all"`, or
when the category getter's pinned bytes do not match. `exclude_local_actor = true`
is still refused first. Otherwise the adapter reads each hit's InCategories exactly
as `include_shape_categories` does, whether or not that option was also asked for.
After the closing fence, and before anything is published, it judges every hit row
in order. A value that could not be read, or was dropped at the fence, refuses the
batch as `hit_categories_unavailable`. A value that shares no bit with the preset's
filter, which the native gate should never return, refuses it as
`hit_categories_inconsistent`. A value with a named bit refuses it as
`hit_named_actor_category`. Each makes the whole batch unavailable with no rows and
keeps its actual cast count. Clear rays pass: nothing was returned to classify.
`named_actor_categories_absent` is true only on an available batch that passed
every rule, and false on every unavailable one. The values themselves appear only
when `include_shape_categories = true` was also asked for, with its permission.

`named_actor_categories_absent = true` means three things: the filter the native ray
sent shares no bit with the named categories (a compile-time check for `"camera"`
and `"terrain"`); every returned hit had a readable InCategories word that was
unchanged at the closing fence; and each word overlapped that filter and carried no
named bit. It is not actor exclusion and never sets `local_actor_excluded`. It does
not show that an actor's shapes carry only named bits: an actor or prop shape that
carries only world-like filter bits passes. It says nothing about collision-time
categories, about every native dispatch route, or about support or force, and
`"camera"` also tests bits that other players, vehicles or Build Kit pieces may
carry. The check is covered by source and constructed-memory tests only.

**Hit owners.** `include_hit_owner = true` asks for each qualified hit's shape owner
slot, read and fenced exactly as `in_categories` is: at the hit's own shape index,
after the hit passed the shape reader, the association and the owned-body
exclusion, read twice between identity checks, read again at the closing fence and
copied in only after it. It needs `world.physics.observe`, checked before the logical
ray budget or any native call is spent. A hit row then has `owner_assigned`, which
is false for the build's unassigned slot, and, only when that is true, `owner`: an
opaque locked userdata that supports `==` and nothing else. Both are missing when
the slot could not be read or changed before the closing fence; an identity change
still refuses the whole batch as `body_epoch_or_observation_changed`. The option
adds no batch-level field.

Two `owner` tokens compare equal when they come from the same plugin instance, the
same SDK world generation and the same measured epoch serial, and their read-time
slots were equal, so single-ray batches cast against one epoch can be compared.
Tokens from different epochs never compare equal. The slot itself, its index, kind
and generation never reach Lua. Equal tokens mean equal read-time owner slots, each
stable through its own fence; they say nothing about whose owner it is, and
`owner_assigned = false` proves nothing about a shape. The slot layout is the one
`set_shape_owner`'s pinned bytes show, which the owned-body service checks before it
creates any body. The token is covered by source and constructed-memory tests only.

The contact-vector roles are supported by static consumers in the one supported
game build. The source and constructed-memory tests do not demonstrate the new
measurements in a retail native ray. Known flat and moving surfaces, normal
conventions, actor coverage and body/query/force composition still need distinct
in-game qualification before this API can support a riding controller.

The optional `body` token supports equality **only within that returned batch**:
two qualified hits on the same current native body compare equal. Tokens from
different batches compare unequal, even if the physical body happens to be the
same. A token cannot be submitted, read, released or used as an exclusion handle.
It represents a qualified body observation, not a collider, face or surface
feature, and carries no proof of static or moving contact. Unqualified identities
are omitted while valid hit geometry may still be returned.
The current native adapter omits this optional token. Its private association
check uses the actual hit shape, the native shape-to-body index table, then the
distinct body's capacity, allocation and u32 generation. Matching shape and body
index/generation numbers cannot establish that conversion. Every returned
shape/body pair is rechecked before publication, including different shapes
sharing one body. These checks establish current association only: the native
hit reader obtains a byte generation after the ray, so collision-time index
reuse and generation wrap are not ruled out. No arbitrary-index conversion API
or universal foreign shape-array capacity is exposed or claimed.

Before and after any executed batch, the native adapter rechecks
the owned anchor, context, native world/state, SDK world and body generations, owned exclusions, and
the exact listener sample epoch. Both fences also require the latest published
sample and a fresh read-only native body observation to match every numeric lane
of the token's canonical sample exactly. Even a read or receipt that replaces
`latest` in the same listener epoch cannot rebind an older token. A changed
observation discards **every** ray; no partial
contact set escapes. These checks qualify one local observation window. They do
not lock the native physics world or freeze native position, rotation or velocity
arrays between those reads, and do not prove globally atomic collision geometry.
The Lua vehicle adapter must still qualify how it pairs its body/contact
observations and uses them for a later command.
A clear result does not prove that an entire surrounding region is streamed.

The batch contract repeats the existing native observation reads through a pure read-only
path. It does not publish `latest`, observe a successor, consume a pending command,
acknowledge a receipt or advance the command epoch. The native clock may naturally advance
during the query. Any subsequent same-epoch command must still pass the existing
submission gate; the SDK never relabels or retries it.

Each input ray spends one of the existing logical 64 requests per VM tick, even
when the backend is unavailable and performs zero native casts. Separately, all
Lua world raycast, probe, pick, session occlusion and body-batch paths share a hard
64 **actual native cast** limit. Each batch ray permits at most two actual casts,
including an exclusion retry. `native_cast_budget_exhausted` means the shared
allowance ended; `ray_cast_limit_exhausted` means that ray's two attempts could
not establish a result. Both defer the whole batch and set `budget_exhausted`.
Other reasons are `query_unavailable`, `contact_measurement_unavailable`,
`body_epoch_or_observation_changed`, `invalid_ray_batch`, `invalid_query_backend_result`,
`owned_body_hit`, `hit_identity_unqualified`, and, for
`require_named_actor_categories_absent`, `hit_categories_unavailable`,
`hit_categories_inconsistent` and `hit_named_actor_category`. A malformed internal
accounting result closes the remaining tick budget and omits `native_casts`
rather than inventing an actual count.

Pre-cast refusals distinguish `client_phase_unavailable` (initial client gate),
`local_actor_exclusion_unavailable` (the requested actor exclusion is unqualified),
`named_actor_categories_unavailable` (the named-category check cannot be backed
for this preset or build),
`body_exclusions_unavailable` (association metadata is unavailable before casting),
and `query_preconditions_unavailable` (the backend was unavailable before any batch
ray cast). A C++ exception escaping the counted helper after query entry reports
`query_backend_exception`, closes the remaining budget and omits `native_casts`
because the adapter's accounting may be incomplete. The helper itself counts
immediately before each native ray invocation; a C++ exception it catches can
retain that exact attempted-call count as an ordinary unavailable result, without
retrying. Its result cleanup guard is installed before the invocation. Exceptions
before entering the query path report `query_preconditions_unavailable` with known
zero casts instead. These C++ exception boundaries do not establish recovery from
every native fault or from a failing cleanup routine.
An accounted native ray with an ordinary unavailable result reports
`query_unavailable`. A nearest hit on an excluded owned body reports
`owned_body_hit`, and one whose shape or shape-to-body association could not be
qualified reports `hit_identity_unqualified`; each keeps the actual cast that found
it. An identity lost while reading a hit's category or owner slot reports
`body_epoch_or_observation_changed`, because the fence that settles the reason sees
the same loss. Missing required contact details report
`contact_measurement_unavailable`; malformed available geometry or contact
details report `invalid_query_backend_result`. Observation changes and budget
failures retain their existing precedence. These categories do not identify an individual failed native
contract or relax any guard.

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

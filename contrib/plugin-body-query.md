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
substitutes a farther surface. In-game qualification of this replacement path
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
`exclude_local_actor = true|false`, and `require_contact = true|false`. At most eight additional opaque body handles
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
`local_actor_excluded` reports whether an available result honored that explicit
request; it currently cannot be true in the native backend. The available
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
`body_epoch_or_observation_changed`, `invalid_ray_batch` or `invalid_query_backend_result`. A malformed internal
accounting result closes the remaining tick budget and omits `native_casts`
rather than inventing an actual count.

Pre-cast refusals distinguish `client_phase_unavailable` (initial client gate),
`local_actor_exclusion_unavailable` (the requested actor exclusion is unqualified),
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
`query_unavailable`. Missing required contact details report
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

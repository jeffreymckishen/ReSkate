# Ray batches tied to an owned body's measured epoch

`reskate.world.physics.probe_batch(body, epoch, rays, options?)` requires both
`world.physics` and `world.raycast`, and is client phase only. `body` is an opaque
handle from `physics.create`; `epoch` is the opaque observation token from that
body's `physics.read` sample. It retains that immutable complete sample internally,
including position, rotation, linear/angular velocity, mass and inertia. A query
grants no force, motion, pose or ownership authority.

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
end
```

There are 1 to 32 rays, each exactly `{from = vector, to = vector}` in world
metres. Positions must be finite and within 100 km of the map origin. Segments
must have a nonzero direction, be at least 10 micrometres long and at most 1000 m
long, subject to a lower configured host limit. Invalid arguments raise a Lua
error. Lists must be dense arrays; extra fields are refused.

Options are `exclude_bodies = {other_owned_body, ...}` and
`exclude_local_actor = true|false`. At most eight additional opaque body handles
are accepted. Every exclusion must still belong to this VM, its current native
world and a fresh owned generation. The anchoring body is always excluded. Native
body references are resolved internally; plugins cannot supply addresses, native
body indices or actor IDs. The optional actor exclusion resolves and rechecks the
current canonical local actor root through the existing picking contract. If that
cannot be qualified, the batch is unavailable.

The result has `status = "available"|"unavailable"`, `native_casts`,
`budget_exhausted`, and a dense `rays` list of the requested length. An unavailable
batch also has a `reason`. Each available ray has `status = "clear"|"hit"`.
A hit adds its actual segment `position` and `fraction`, `motion = "unknown"`,
and optionally an opaque `body` token. Normals, velocity, surface/feature IDs and
native identity fields are omitted. A clear ray has no geometry or body token.

The optional `body` token supports equality **only within that returned batch**:
two qualified hits on the same current native body compare equal. Tokens from
different batches compare unequal, even if the physical body happens to be the
same. A token cannot be submitted, read, released or used as an exclusion handle.
It represents a qualified body observation, not a collider, face or surface
feature, and carries no proof of static or moving contact. Unqualified identities
are omitted while valid hit geometry may still be returned.

Before and after the batch, the adapter rechecks the owned anchor, context,
native world/state, SDK world and body generations, actor root, exclusions, and
the exact listener sample epoch. Both fences also require the latest published
sample and a fresh read-only native body observation to match every numeric lane
of the token's canonical sample exactly. Even a read or receipt that replaces
`latest` in the same listener epoch cannot rebind an older token. Qualified foreign hit generations are checked
again before publication. A changed observation discards **every** ray; no partial
contact set escapes. These checks qualify one local observation window. They do
not lock the native physics world or freeze native position, rotation or velocity
arrays between those reads, and do not prove globally atomic collision geometry.
The Lua vehicle adapter must still qualify how it pairs its body/contact
observations and uses them for a later command.
A clear result does not prove that an entire surrounding region is streamed.

The query repeats the existing native observation reads through a pure read-only
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
Other reasons are `query_unavailable`, `body_epoch_or_observation_changed`,
`invalid_ray_batch` or `invalid_query_backend_result`. A malformed internal
accounting result closes the remaining tick budget and omits `native_casts`
rather than inventing an actual count.

This source change requires runtime build, portable and plugin contract checks,
then native query validation. It does not itself activate a vehicle or establish
in-game contact accuracy, motion qualification or performance.

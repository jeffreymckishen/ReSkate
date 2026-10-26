# Generic owned-body follow API

The permissioned Luau bindings and generic native service compile in the normal
Windows Release build. The motion selector passed 12 constructed Host scenarios,
and its native support passed 44 constructed provider cases. The normal regression
run passed all 13 selected test groups with the unchanged 50 ms VM limit.
In-game follow remains unqualified; these tests do not establish
mounted gameplay, airborne continuity, switching reliability or BMX Streets likeness.
All attachment geometry, input, vehicle handling, mounting policy and equipment
transactions belong in the Luau mod. The SDK supplies generic body/actor joining.

The runtime uses the follow Service's `Phase::completed`, exact completed
retirement, and clean-only abandonment ACK. It dispatches through the existing
native actor callback and ticks retained cleanup after the owned-body service.
The synchronous Service requires body park; the existing portable ownership
policy's stronger dual-barrier contract is preserved separately. This adapter
refuses unknown pending duties rather than silently translating their meaning.

## Permission and scope

Every method needs both `world.physics` and `world.physics.follow`.
`renew_follow`, `read_follow_lease` and a reserve with `lifetime="renewable"` also
need `world.physics.follow.renew` (see [Sustained Follow](#sustained-follow)).
Every method is client phase only, including receipt reads and cleanup requests.
The dedicated permission is warranted because ordinary body creation/forces do
not authorize replacing the local actor's root transform. It grants no input
lease/capture, controller write, equipment action, recovery, teleport, raw native
identity or way to provide a claim/barrier/park proof.

Reserve and publish use the fixed internal eligibility predicate: known on-foot state `504`,
known ragdoll state with value `false`, and known airborne state. Either airborne
value is allowed. The default `native_lifetime` policy repeats the full actor and
state inspection during each callback. The experimental `callback_entry` policy has
the same truthful eligible start, then a separate scoped continuation contract
described below; it does not claim continued upright state. Whether the retail
actor supports a usable hop/ride still needs direct testing.

The underlying Service has one process-wide receipt slot. A Follow reserved
without `lifetime`, or with `lifetime="fixed"`, keeps a fixed three-second lease
from reservation, and the motion selector does not change that. `publish_follow`
cannot extend it, and repeated publication or new Lua timers do not renew it.
A longer Follow opts in to a renewable lease, described under
[Sustained Follow](#sustained-follow): it is extended only by presenting the
followed body's latest sample, and never past two minutes from reservation.

## Calls

```lua
local P = reskate.world.physics
local follow, why = P.reserve_follow(body, {
    offset_from_com = vector.create(0, 0.4, 0),
    root_in_body = {0, 0, 0, 1},
    -- Omit cleanup, or use nil or "actor_lifetime", for the strict default.
    cleanup = "owned_body", -- Explicit stopped-cleanup opt-in.
})
```

`body` is this exact VM's opaque owned-body handle. The runtime captures a fresh
measured source itself and the Service independently repeats the same-allocation
join. No Lua body sample, epoch, native address, eligibility callback or proof
boolean substitutes for either check.

The attachment table requires `offset_from_com` and `root_in_body` and accepts
optional `cleanup` and `motion_policy`. The COM offset is finite, within +/-10 meters per axis, and
expressed in the measured principal-body basis. `root_in_body` is a unit Hamilton
XYZW quaternion expressing the actor root basis in that same body basis. The
runtime never chooses vehicle geometry or a yaw-only orientation for the mod.

Omitting `cleanup`, passing `nil`, or using the exact string `"actor_lifetime"`
keeps the existing default. The only opt-in is `cleanup="owned_body"`. Non-nil
values must be strings with exactly one of those two spellings; other types,
unknown names, whitespace/case changes and NUL-suffixed strings are rejected
before the reserve attempt reaches the backend. The policy is copied at reserve
and cannot be changed by editing the attachment or a returned receipt. Both
existing permissions and the client-phase restriction still apply.

## Experimental motion selector

The exact strings are `motion_policy="native_lifetime"` and
`motion_policy="callback_entry"`. Omission or `nil` selects `native_lifetime`,
preserving the existing cross-callback global lifetime and full State checks.
Every non-nil value must be a string with exactly one spelling; unknown names,
other types, whitespace/case changes and NUL suffixes are rejected before the
backend or reserve quota. This field changes no permission, owner/opaque-handle
boundary, source-allocation check, fixed quota, lease or SDK cleanup duty.

`callback_entry` requires explicitly supplied `cleanup="owned_body"`.
Omitted/nil cleanup and `cleanup="actor_lifetime"` are rejected; the runtime never
silently selects another cleanup policy. The pair is copied at reserve and cannot
be changed by editing the Lua attachment afterward.

Select the experimental callback-entry behavior with both policies explicitly:

```lua
local follow, why = P.reserve_follow(body, {
    offset_from_com = vector.create(0, 0.4, 0),
    root_in_body = {0, 0, 0, 1},
    cleanup = "owned_body",
    motion_policy = "callback_entry",
})
```

This branch includes both the binding and its native implementation. Constructed
tests cover parsing, permissions, defaults and provider behavior; they do not
qualify the game's callback ABI, actor lifetime or safe body reuse. Validate those
properties in a bounded isolated game trial before relying on this policy for riding.

Scoped continuation must originate at the genuine current motion wrapper on the
same thread, exact current rig/context/original arguments, and one original-call
commit. It rechecks current root/watched actor identity, controls and paired idle
teleport views, protection, within-entry global observations, exact owned-body
allocation/World/clock/source and the actual SDK claim. It neither renews the
historical global Actor stamp nor reads optional selector/cause/trick/offboard
state to assert continued uprightness. It grants no durable child-incarnation
proof, additional direct root/camera writes, future native queue or extra actuation method.

The receipt schema is unchanged and contains no requested-policy echo. A mod can
record its requested string as a request; that is not evidence of a native borrow,
return, cleanup or safe retention. The original-call argument and lifetime checks
still require direct game validation; a passing Host scenario is not that evidence.

## Cleanup authority for both motion policies

`owned_body` changes only stopped cleanup, using the existing fresh owned-body/
World checks instead of the adapter's additional old actor-lifetime rechecks.
The fresh Anchor, current World/state, exact body and every shape allocation
and generation, and current physics-clock checks remain in force.
For a published follow, cleanup still needs the exact stopped/revoked/drained
claim, every committed original's normal return, unchanged fresh World/body
qualification, actual guarded park with a matching later receipt, and exact SDK
claim retirement. It does not change live admission, publication or the lease,
pin the old actor's native lifetime, or prove native consumption, destruction or
reuse. The public receipt shape and ACK rules are unchanged: completed park and
SDK retirement are history, `native_retirement_known` stays `false`, and unknown
duties remain retained. Clean never-published abandonment still follows the
separate body-ownership rule below.

The reserve results have three meanings:

| Results | Meaning |
| --- | --- |
| `handle, nil` | The reservation was accepted; publication remains explicit. |
| `nil, reason` | No usable follow handle was returned. No request is queued for retry. |
| `handle, reason` | Admission was refused after acquiring cleanup duty. Keep the handle, stop/read/ACK it as eligible, and do not publish it. |

Checking only `assert(handle)` is insufficient. A non-nil reason must route to
cleanup. A false reserve result with a nonzero native handle is preserved by the
binding, including a malformed reason; it is never silently dropped.

`publish_follow(handle)` explicitly publishes the reserved attachment. It returns
`true`, or `false, reason`. It neither changes equipment nor renews the lease.
An admission refusal uses the Service's reason such as `unsupported_state`; the
plugin does not invent an alternate actor state.

`read_follow(handle)` returns a fresh copied receipt, or `nil, reason`. A read
that finds the Service lock busy returns `nil, "follow receipt busy"`; a foreign,
reset or unknown receipt still returns `nil, "follow receipt unavailable"`. The DTO
contains `phase`, `reason`, `park_reason`, `sequence`, `final_revision`,
`final_native_epoch`, `returned_revision`, `pending`, `in_flight`, `claim_known`,
`orphaned`, `park_observed`, `native_retirement_known`, and `terminal`. All four
64-bit identifiers/revisions are decimal strings, including zero. `pending` is
an array containing either no entries or `"body_parked"`. Editing the DTO changes
no native state and cannot provide authority to any later call.

`stop_follow(handle)` returns `true` if the exact stop request was accepted, or
`false, reason`. Stop acceptance alone establishes no completion, drain or park.
The existing native invocation may still be returning; cleanup remains owned.

`acknowledge_follow(handle)` returns `true` only when one of the internal exact
ACK paths succeeds, or `false, reason`. It accepts just the opaque handle. It
does not accept a receipt, phase string, boolean, epoch or proof from the plugin.

## Completion and body ownership

`reserved` and `following` are active stages. `stopping` and `retained` still
require cleanup. Only the Service's explicit `abandoned` and `completed`
transitions are terminal. Snapshot absence, zero observed in-flight count, a
native return, and an observed park alone do not synthesize either transition.

`abandoned` means the never-published claim was actually abandoned, the actual
release hold was released, and no follow invocation/work remains. The caller's
body can remain owned and unparked. ACK frees the follow receipt; it does not
release that body. Luau must separately call `P.release(body)` when its policy
requires body cleanup, using the ordinary body release contract.

`completed` means the published follow actually stopped/drained, the release
hold was released, the dependent body release started, a matching retained park
was observed, and the exact SDK actor claim retired under the revised contract.
World body release and its matching retained park have already occurred; after
a matching `completed` receipt and successful ACK, no second ordinary
`P.release(body)` is needed. ACK frees only that follow receipt.
This does not erase copied native transform
history, prove native consumers forgot a value, recover a fallen actor or switch
back to the skateboard. `native_retirement_known` remains `false` even when the
phase is `completed`. Any later stock action/recovery is a separate explicitly
authorized transaction with its own current-actor checks.

Every handle is owner-bound locked userdata. Numbers, strings, tables, other
opaque types and another VM's handle cannot replace it. There is no `__gc`
actuator: dropping a handle cannot stop, release or acknowledge a native claim.
VM close calls Service `release_all(owner)` before owned-body cleanup; unresolved
duty remains in the retaining Service. For an orphan, the host can call its
internal ACK with the stored old owner/sequence only after the published path's
actual matching park and exact SDK retirement, or the never-published path's
actual clean abandonment/hold release plus known accepted World body-release
handoff. Unknown or active duty retains the slot. The World service keeps any
remaining body/mailbox cleanup. No native follow target existed on that clean
never-published path. This is authenticated host cleanup, not a cross-owner
transfer or a public proof flag. A replacement VM can reserve a fresh handle
only after the old host cleanup succeeds; it can never adopt the old handle.
Live owners still explicitly ACK their own completed or abandoned receipt.

## Sustained Follow

A Follow that should last longer than three seconds opts in at reserve with
`lifetime="renewable"`. Nothing about it is specific to one kind of mod: any mod
that attaches the actor to an owned body (a vehicle, a carried object, a rig)
uses the same calls.

```lua
local P = reskate.world.physics
local follow, why = P.reserve_follow(body, {
    offset_from_com = vector.create(0, 0.4, 0), root_in_body = {0, 0, 0, 1},
    cleanup = "owned_body", motion_policy = "callback_entry",
    lifetime = "renewable",
})
assert(follow and why == nil) -- a non-nil why still owns cleanup, as above
assert(P.publish_follow(follow))
-- each tick while following:
local sample = P.read(body)
if sample then
    local ok, v = P.renew_follow(follow, sample.epoch)
    -- ok: v is the native milliseconds left on the lease
    -- not ok: v names the refusal; the lease still bounds a retryable one
end
```

### Opting in

`lifetime` is optional. Omitted, `nil` or the exact string `"fixed"` keep the
fixed three-second lease and need no new permission. The exact string
`"renewable"` needs `cleanup="owned_body"` (either motion policy) and the
permission `world.physics.follow.renew`, which also requires `world.physics` and
`world.physics.follow`. Any other value raises before the backend, including
another type, a case or whitespace change and a NUL suffix. The attachment is
parsed first, then the renewal permission is checked, then the reserve quota: a
malformed attachment raises its own error, and a denied renewable reserve raises
without spending the tick's reserve. The lifetime is copied at reserve; editing
the table afterwards changes nothing, and the receipt does not echo it.

The permission is separate because minutes of root control are more than three
seconds of it. It grants no input, equipment, recovery, force, raw native
identity or new actor state.

### Renewal

`renew_follow(follow, epoch)` takes exactly two arguments: the opaque Follow
handle and a body epoch from `read(body)` or a receipt's `successor`. The epoch
must belong to this VM and to the followed body, or the call raises, as do a
wrong arity, a forged handle and any other value. It returns `true,
remaining_ms` (whole native milliseconds from 1 to 120000) or `false, why`.

The runtime accepts the epoch only as proof that this VM holds the followed
body's **most recently issued sample**, newer than the last accepted renewal,
at most six physics steps behind the body's current step, with that step
observed less than 100 ms ago. A timer, a counter, an old or replayed sample or
repeated publication never renews. An accepted renewal moves the deadline to
`max(deadline, min(now + 500 ms, reservation + 120 s))`; it never shortens it,
and a lease that has lapsed is never revived.

| `why` | Meaning | The Follow stops? | Try again later? |
| --- | --- | --- | --- |
| `not_renewable` | Reserved without `lifetime="renewable"` | no | no |
| `not_following` | Not published, already stopped, or the receipt changed during the renewal | no (already) | no |
| `sample_not_advanced` | The epoch is not newer than the last accepted one, for example no new physics step this tick | no | yes |
| `sample_stale` | Not the body's latest issued sample, more than 6 steps behind, or the current step is 100 ms old or more | no | yes |
| `body_unavailable` | The body is released, retained, quarantined or no longer the reserved allocation | no; World's release stops it on the next client tick | yes |
| `busy` | A lock was busy: the Follow's, World's, or the physics clock's while a step wrote it | no | yes |
| `lifetime_exhausted` | The deadline already equals the 120 s ceiling | no; it ends at the ceiling | not useful |
| `expired` | The deadline passed before or during this renewal, so the renewal stopped the Follow | yes | no |
| `client_not_ready`, `focus_lost`, `menu_open`, `pause_menu_open`, `debug_control`, `actor_state` | A revocation fact (below) | yes | no |
| `asked to renew follow more than once in one tick` | Quota | no | no |

A malformed backend result returns `false, "follow renewal returned invalid
observations"`, never `true`.

### Bounds

| Bound | Value |
| --- | --- |
| Base lease from reservation, also the floor of a renewable lease | 3000 ms |
| Window after an accepted renewal | 500 ms |
| Ceiling from reservation | 120000 ms |
| Renewals per plugin tick per VM | 1 |
| Proof age | at most 6 steps behind the current step, observed under 100 ms ago |
| Revocation facts' age | under 250 ms |
| Lease reads per plugin tick per VM | 8, on their own counter |
| Slots | one process-wide Follow, unchanged |

A plugin that stops renewing is released at `max(reservation + 3000,
last renewal + 500)`. Each renewable Follow still spends one of the eight
owned-body slots that are never reused.

### Revocation

Once per client tick, before the Follow lock is taken, the client tick samples
these facts and publishes them as one atomic word: the client is ready (named
context, no debug request, not loading), the game window has focus, the ReSkate
interface is closed, the game's own menu state was read and no game menu is up,
no noclip or free camera is active, and the local actor is upright on foot (the
same sampled state `504` and known non-ragdoll reading that `skater.telemetry`
serves). For a renewable Follow, reserve, publish, the client tick, every renewal
and every native callback refuse or stop when a fact is false or the sample is
250 ms old or more. A Try that misses the lock never hides the facts, because
they are stored first. A fixed Follow ignores every fact but readiness, as before.

The first failing fact names the cause, in this order: `client_not_ready` (also
an unsampled or stale guard, or an unknown game menu state), `focus_lost`,
`menu_open`, `pause_menu_open`, `debug_control`, `actor_state`. A renewable
reserve refused this way occupies nothing and owes no cleanup. Every other stop
goes through the existing stop, park and ACK path.

The receipt keeps its fourteen fields and its existing reason names:

| Cause | Receipt `reason` | Lease `revocation` |
| --- | --- | --- |
| Deadline passed | `expired` | `deadline` |
| Ceiling passed | `expired` | `lifetime` |
| Native clock before reservation | `expired` | `clock` |
| Client not ready, stale or unsampled facts, game menu state unknown | `unavailable` | `client_not_ready` |
| Focus lost | `focus_changed` | `focus_lost` |
| ReSkate interface open | `focus_changed` | `menu_open` |
| Game menu open | `focus_changed` | `pause_menu_open` |
| Noclip or free camera | `focus_changed` | `debug_control` |
| Actor not upright on foot | `unsupported_state` | `actor_state` |
| Anything else (explicit stop, VM close, level or body change, native fault, revision exhaustion) | unchanged | `other` |

The revocation is kept only when the lease caused the receipt's **first** stop,
so it always describes the same stop as `reason`.

### Lease report

`read_follow_lease(follow)` returns a freshly copied table, or `nil, why`
(`"follow lease busy"`, `"follow lease unavailable"` after ACK or for a foreign
handle, or `"follow lease returned invalid observations"`). It works for either
lifetime.

| Field | Type | Meaning |
| --- | --- | --- |
| `sequence` | u64 string | The Follow sequence, as in `read_follow` |
| `renewable` | boolean | A renewable lease started at reserve |
| `active` | boolean | Published, not stopped, and before the deadline now |
| `renewals` | u64 string | Accepted renewals |
| `last_serial` | u64 string | Body serial of the last accepted proof; `"0"` before any |
| `remaining_ms` | number | Native milliseconds to the deadline; 0 once passed or stopped |
| `lifetime_remaining_ms` | number | Native milliseconds to the ceiling; equal to `remaining_ms` for a fixed lease; 0 once passed or stopped |
| `base_ms`, `renewal_ms`, `lifetime_ms` | number | 3000, 500, and 120000 (3000 for a fixed lease) |
| `revocation` | string | One of the names in the table above, or `none` |
| `dispatch_busy` | u64 string | Native callbacks since reserve that found the Follow lock busy and were not followed |

The times are milliseconds left, never deadlines: the native clock is not
`reskate.time.now`, so compare them only with a plugin clock read before the call.

### Not established

These are constructed tests and source reading only. Nobody has observed a
published Follow longer than about half a second in game, so whether the
callback continuation, the actor root and the body stay coherent for ten or
thirty seconds, whether the body parks after sustained motion, and which thread
runs the motion callbacks are open. The window, ceiling, proof age and guard age
are authored values, not measured ones. A callback that meets a client-thread
exclusive World window still stops the Follow at provider stage `measure`.

## Internal failure diagnostics

The SDK log records the first stop separately from the first published-cleanup
observation, using the Service's process-local, nonreused sequence. Each record
contains its origin, reached provider stage, last evaluated actor observation
and stored cleanup state, and a lease line with the receipt's renewals, its
latched revocation and its skipped callbacks. These records add no plugin
methods or receipt fields.
The client tick copies at most one record of each kind, then logs outside SDK
locks. Native dispatch does not format or log messages.

An unknown comparison was not evaluated. An aggregate binding mismatch does
not identify the changed member. The first cleanup observation can be ordinary
pending work, and later failures do not replace it. ACK or receipt reuse can
discard an undrained record, so a missing log is not proof that no failure
occurred. Stored flags and diagnostic stages do not prove native consumption,
parking, retirement or successful gameplay.

## Fixed bounds and validation

Per VM per plugin tick, calls reaching a well-formed handle/body argument may
attempt at most one reserve, one publish, eight reads, one stop, one ACK, one
renewal and eight lease reads. Each category has its own counter so read/publish
traffic cannot exhaust the stop quota, and lease traffic cannot exhaust the
receipt reads. Native refusals, busy and unavailable receipts and malformed
backend results consume their attempt. Counters reset only on the actual plugin
tick. The native Service's one-slot capacity and its lease (three seconds fixed,
or renewable up to two minutes) remain independent limits.

Receipt serialization rejects invalid enums, foreign returned sequences,
impossible revision relations, excess in-flight count, unknown pending duties,
a positive `native_retirement_known`, and malformed terminal combinations. These
checks reject bad copied facts; they do not turn a DTO into native authority.

The Host fixture uses actual manifest/VM/API code over constructed Game
leaf results: missing permission, server side, strict arguments, opaque transport,
fixed quotas, partial reserve cleanup, separate body cleanup after abandonment,
owner reload/sequence reuse, copied precision and fifteen malformed receipts.
It also checks the fixed eligibility policy on constructed states. Eight groups
ran 26 constructed Host scenarios. A separate 17-translation-unit composition
ran 26 cases and 334 checks through the actual Service, Actor/Arbiter, World,
Profile, Delivery and wrapper implementations with constructed native inputs.
The [validation checkpoint](bmx-lab/judging/checkpoints/2026-10-24-body-follow-luau.md)
records the preserved failures, later results and build identities. These code
tests do not prove retail follow, native pose consumption, airborne continuity,
visible rider alignment or likeness.

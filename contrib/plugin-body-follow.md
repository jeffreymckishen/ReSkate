# Generic owned-body follow API

The permissioned Luau bindings and generic native service compile in the normal
Windows Release build. Host and composed SDK tests have run with constructed
game inputs. In-game follow remains unqualified; these tests do not establish
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

Every method needs both `world.physics` and the new `world.physics.follow`.
Every method is client phase only, including receipt reads and cleanup requests.
The dedicated permission is warranted because ordinary body creation/forces do
not authorize replacing the local actor's root transform. It grants no input
lease/capture, controller write, equipment action, recovery, teleport, raw native
identity or way to provide a claim/barrier/park proof.

The fixed internal eligibility predicate requires a known on-foot state `504`,
known ragdoll state with value `false`, and known airborne state. Either airborne
value is allowed. That avoids an accidental grounded-only requirement at every
callback. Whether the retail actor remains in this state through a hop has not
been observed and must be tested before claiming usable riding.

The underlying Service has a fixed three-second lease from reservation, one
process-wide receipt slot, and no renewal API. `publish_follow` cannot extend it.
This API therefore supports only a bounded first-mount interval. A longer
ride requires a separately justified lifetime policy; repeated publication or
new Lua timers must not be used to imply renewal.

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
optional `cleanup`. The COM offset is finite, within +/-10 meters per axis, and
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

`read_follow(handle)` returns a fresh copied receipt, or `nil, reason`. The DTO
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

## Internal failure diagnostics

The SDK log records the first stop separately from the first published-cleanup
observation, using the Service's process-local, nonreused sequence. Each record
contains its origin, reached provider stage, last evaluated actor observation
and stored cleanup state. These records add no plugin methods or receipt fields.
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
attempt at most one reserve, one publish, eight reads, one stop, and one ACK.
Each category has its own counter so read/publish traffic cannot exhaust the
stop quota. Native refusals, unavailable receipts and malformed backend results
consume their attempt. Counters reset only on the actual plugin tick. The native
Service's one-slot capacity and three-second lease remain independent limits.

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

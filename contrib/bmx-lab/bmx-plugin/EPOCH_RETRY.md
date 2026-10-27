# Retrying a refused body snapshot

Core may retry this exact `world.physics.read(body)` refusal once:

```text
body snapshot or native epoch changed; no sample published
```

This is bounded recovery from a transient observation failure. It is not a
confirmed fix for sleeping bodies. The refusal observed when a body settled in
game does not identify which native check failed.

## What the SDK establishes

[`owned_bodies.cpp`](../../../Extension/World/owned_bodies.cpp), `read`, first
checks the client phase, owner and live slot. The error above means `sample`
failed. `observe_checked` can reject an unavailable or changing clock, changed
ring headers or values, invalid pose or motion, changed configuration, or a
failed anchor/allocation check. It does not report a sleep state or reinsertion.
The serial comes from the actor physics clock, not a body-specific sleep epoch.

`sample` publishes `latest` and attaches mailbox successors only after the whole
observation succeeds. A failed read does not release or rekey the body, erase
its latest issued sample, or clear command receipts. A later coherent read
already returns a current opaque epoch; this case needs no new SDK capability.
The opaque epoch must come from that successful read. A failed read does not
make an older epoch current.

[`owned_body.h`](../../../Engine/Game/World/owned_body.h), `Mailbox::submit`,
keeps monotonic serial/time, world/body identity, step duration and impulse ID
checks. The service additionally requires the command epoch to equal both the
latest issued sample and the current clock. A successful reread may supply a
successor to an already applied command. Recovery must preserve that command's
receipt and accepted hop ID rather than resubmit it.

[`owned_bodies.h`](../../../Extension/World/owned_bodies.h),
`MeasuredSource::same_allocation`, pins owner, SDK handle, native world/state,
SDK world generation, body index and native generation. It permits newer sample
serials within that identity. A replacement native allocation is never adopted.
World/context changes retire the old slots; released slots are not recycled.

[`native_body_follow.cpp`](../../../Extension/Skater/native_body_follow.cpp)
measures this same allocation afresh at each dispatch. The public body read
failure itself does not stop Follow. However, a failed native Follow
prepare/current check enters `stop_locked` in
[`native_body_follow_service.cpp`](../../../Extension/Skater/native_body_follow_service.cpp):
it marks the binding stopped, requests the held body's release and revokes the
claim. Renewal cannot revive it. Re-reserving Follow on that releasing body is
not recovery.

## Lua recovery contract

The retry in [`bike_runtime_core.lua`](plugin/bike_runtime_core.lua) and
[`ride_runtime.lua`](plugin/ride_runtime.lua) is limited to one immediate reread
of the same owned body after the exact refusal above. All other errors, thrown
calls, malformed results and a second refusal retain their stop behavior.

Fresh source, readiness, ownership and active Follow checks must still pass.
Recovery retains the existing live Follow; it does not reserve a replacement,
renew away a stopped lease, allocate a body, or infer native lifetime from a
Lua handle. Normal serial/time continuity rules remain: recovery grants no
serial gap, replay, backward clock or changed step duration.

Only a coherent successful reread allows force-history continuity to be
invalidated before the next force preview. Pending command receipts, accepted
hop IDs and uncertain outcomes remain intact. Recovery does not replay a
command or turn an uncertain native result into an accepted one.

The healthy Core path permits at most six Follow reads per tick. The recovery
path has a scoped allowance of seven, leaving one cleanup read within the SDK's
eight-read quota. This is not a general increase for healthy ticks. The retry
must preserve cleanup and stop capacity.

A recovery tick costs about 11 more SDK calls than a healthy one, all inside
the per-tick time budget: fresh readiness facts (6), one Follow read, a fresh
Source authorization (3 lease reads) and the reread itself, plus about five
`time.now` reads. Healthy ticks make no extra calls.

Core reports `body_read_retries` for actual retry calls and
`body_read_recoveries` for returned sample tables after its ownership/lease
checks. The latter does not establish coherent cadence or continued riding:
Ride still validates the complete sample and serial/time sequence. Ride's
`continuity.body_read_recoveries` counts valid sample shapes before its cadence
checks. Judge either counter alongside the final phase and stop reason.

## Coordinator's in-game check

Claude owns the game trial. Compare the ordinary path and the retry build with
the same package gates, runtime, pad input and floor location. Let the bike
settle, hold the brakes at rest, wait, pedal, brake to rest and repeat. Include
stationary startup and a normal moving control.

Record the first refusal and the single retry result; sample serial, time and
step duration; Follow phase, lease/revocation and first-stop provider stage;
force-continuity invalidations; command sequence, receipt outcome and successor;
and hop acceptance/retirement. Confirm no duplicate submit, hop or body/Follow
allocation, and that stop/cleanup still completes when recovery is refused.

A source or constructed-suite pass is not native rest or gameplay evidence.
If refusals persist, identify the failing native qualification first: clock
availability/coherence, allocation generation and dynamic bit, ring storage and
values, configuration, and native Follow measurement stage. The current API
does not expose enough facts to distinguish sleep from those failures. Do not
add a blind wake call, adopt a new handle, or relax lifetime checks on the
strength of this error text alone.

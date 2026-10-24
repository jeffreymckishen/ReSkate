# Owned native bodies

`world.physics` lets a client plugin create and control its own physical capsule compound.
It grants no access to the skater's bodies, native pointers, collision masks, console,
progression or paid content. This is a generic SDK building block. Vehicle policy,
contacts, controls, hop strength and steering belong in a Luau mod.

The [first native trial](bmx-lab/luau-native-body-trial.md) created one 12 kg capsule,
applied one 48 Ns impulse, obtained its independently measured successor and parked
the allocation on release. A [second native diagnostic](bmx-lab/native-pipeline-trial/README.md)
completed 120 consecutive constant-force commands with exact next-step application,
independent successors and ordered acknowledgements over one two-second burst.
Whole-session control, torque, other compounds and cleanup of an active body
during unload, world changes or partial failures remain unqualified in the game. Portable
and Host tests qualify the contracts and sandbox; they do not prove those native cases
or a playable vehicle. There is no actor motion, pose or render binding in this slice.

## API

Declare `"world.physics"` in `reskate-plugin.json`. All calls are client phase only.
Creation, observation and submission refuse multiplayer or an unavailable/changed native
owner. Receipt inspection and acknowledgement remain available for retained records;
release without fresh ownership quarantines without touching an old native handle.
Nothing activates on load.
The plugin must explicitly call `reskate.world.physics.create`:

```lua
local P, v = reskate.world.physics, vector.create
local body, why = P.create({
    mass = 12,
    inertia = v(2, 3, 4), -- principal moments, kg m^2
    position = v(0, 2, 0),
    rotation = {0, 0, 0, 1}, -- unit Hamilton XYZW
    capsules = {{a = v(0, 0, 0), b = v(0, .5, 0), radius = .1}},
})
```

The values are examples, not SDK defaults. The body has zero local COM and an identity
local frame; all capsule endpoints are in that frame. Bounds: 1..8 capsules, endpoints
within +/-10 m, radius .01..2 m, mass 1..1000 kg, principal inertia .01..10000 kg m^2,
world position within +/-100 km and a unit quaternion. Collision filtering is a fixed
SDK world-only policy inherited from the qualified native path; a mod cannot supply masks.

`create` returns opaque userdata or `nil, why`. Its first call may install the guarded
producer hook and return `waiting for a fresh qualified 60 Hz physics step` before any
allocation. A later explicit create request can use the now-observed clock. Allocation
itself has no automatic retry.

`P.read(body)` returns a measured sample or `nil, why`:

```
{epoch=<opaque>, serial=<decimal string>, time=<accumulated callback seconds>, seconds=<step h>,
 position=<vector>, rotation={x,y,z,w}, velocity=<vector>, angular_velocity=<vector>,
 mass=<kg>, inertia=<vector>}
```

The opaque epoch binds the VM instance, body generation and world generation. It cannot
be constructed from numbers, transplanted to another body or adopted after plugin reload.
The native snapshot repeats ring headers, contents, direct arrays and complete ownership
checks. A raced or changed read publishes no sample. These repeated reads are not an
engine-wide atomic snapshot guarantee.

`P.submit(body, sample.epoch, command)` returns `true, nil, sequence_string` or
`false, why`. Existing callers using one or two return values keep their behavior.
The service assigns each accepted command a process-wide unique sequence, returned as
a decimal string without a Lua-number uint64 conversion. `command` has
optional `force`, `torque` and `impulse` vectors (zero when omitted), plus a positive uint32
`impulse_id` for a nonzero one-shot impulse. Bounds are 40000 N force norm, 4000 Nm torque
norm, 600 Ns impulse norm and 40000 N for the combined `force + impulse / h`. These are
safety limits, not vehicle tuning. Each body has one immutable pending inbox and a fixed
four-record receipt ring. Publication reserves a ring slot before any native setter.
A pending inbox cannot be replaced, and a full ring refuses publication without
consuming the caller's serial or impulse event.

The command computed from sample epoch **N** targets only listener epoch **N+1**, with
the same calibrated h and time `sample.time + h`. A same-N producer invocation waits;
a missed N+1 or 100 ms wall deadline expires the packet. Listener serials advance even
when a nonblocking listener copy is dropped, so a later native step cannot be relabelled
as the missing target. One matching native wrapper consumes the packet before attempting
either setter. Duplicate wrappers and partial native calls can never replay its impulse.
This clock is the guarded local participant listener's monotonic serial and accumulated
callback seconds since its current owner, not a sampled global world clock.
Each accepted clock copy is independently bound to that callback's current game
context, native world and world-state pointer, as well as its local participant.

`P.receipt(body)` returns the oldest unacknowledged record (or outcome `none` when
empty). `P.receipt(body, sequence_string)` selects that body's retained record with a
bounded four-slot lookup; an absent, freed or other body's sequence returns `nil, why`.
The selector must be an exact string, as returned by `submit`. It returns:

```
{outcome="none"|"queued"|"applied"|"partial"|"rejected"|"expired",
 cleanup_disposition="none"|"parked_without_successor",
 sequence=<decimal string>, requested_serial=<string>, produced_serial=<string>,
 force_attempted=<bool>, torque_attempted=<bool>, retained=<bool>, quarantined=<bool>,
 successor=<measured sample, only when available>}
```

`applied` means both guarded native setters returned and their owner/clock checks held.
It does not assert that integration completed. `successor` is a later independently copied
sample in the same body/world generation, with serial and time strictly beyond the
producer epoch. Each record freezes its **first** independently observed successor;
later reads never substitute a more convenient sample. The plugin can inspect the actual resulting motion. Neither the API nor
the tests fabricate an integrated result from the command.

A [varying-force native diagnostic](bmx-lab/native-phase-trial/README.md) found
that command C_N was applied at N+1 but first affected measured velocity at N+2.
Only that offset matched the same 117 transitions with fixed native mass, h and
gravity; shifted controls failed. This qualifies one short linear-force burst,
not the internal consumption boundary, angular/position timing or a closed-loop
vehicle. Preserve modeled command history separately from measured confirmation.

`cleanup_disposition` is always a string in current successful receipt tables;
`"none"` is the default and grants no alternative ACK eligibility. Clients supporting
an older SDK may treat a missing/nil field as `"none"`. Only the SDK can issue
`"parked_without_successor"`, after its exact owned-body Follow binding is stopped
and drained, its normal-return history matches, and the nonquarantined body has a
positive retained-park receipt. Plugins cannot mint that SDK proof.

With this disposition, `outcome` remains `"applied"` and `successor` remains absent.
It permits only an explicit, once-only FIFO command-record ACK. It does not adopt a
model result, confirm a hop or rearm, erase native pose history, or prove native
retirement, destruction or allocation reuse. Receipt/ACK permission remains
`"world.physics"`; existing VM/body/sequence ownership checks and budgets are unchanged.

`P.acknowledge(body, receipt.sequence)` frees only the oldest terminal record, once;
an applied command additionally requires its actual measured successor or the SDK's
`"parked_without_successor"` disposition. Selecting a later record for inspection never
permits unordered acknowledgement or waives proof.
An acknowledged record cannot be selected again, and only its slot becomes reusable.
Another publication cannot overwrite any retained record or reuse a submitted serial.
The same observed body can publish N, N+1 and N+2 commands for consecutive N+1, N+2
and N+3 native targets while earlier records await measurement or acknowledgement.
A client that observes/publishes every native step can therefore request 60 Hz control;
the bounded ring applies backpressure when receipts are not drained. This removes the
previous every-other-step contract limit, not native-thread scheduling or integration
uncertainty. One controlled native trial has now qualified 120 consecutive commands
on one capsule; it does not qualify whole-session scheduling or a riding controller.

A partial/uncertain setter permanently fails the body for all later commands. Its
retained failure record remains selectable even if an older applied head never obtained
a successor. Quarantine does not manufacture that missing proof; ordered acknowledgement
of the older head remains unavailable. Release/unload cancels the pending inbox while
preserving earlier outcomes. An expired packet cannot replay its submitted serial;
an impulse event is consumed before setters, not by an expired unconsumed packet.

`P.release(body)` revokes its commands and attempts to clear pending force, torque and
velocities, zero and read back all shape masks, then park the exact owned body keyframed.
VM close also releases all bodies of that instance. Successful release means **retained
and parked**, not destroyed. If fresh ownership is unavailable, no old native handle is
dereferenced and the retained allocation is quarantined. Such a body is not claimed to be
stopped. A rejected/partial producer is also retired on the next qualified client tick.

## Native boundary

The service supports the repository's one pinned game build. All native operation bytes
and layouts are in `Engine/Game/Build/20260929/rigid_bodies.h` or the existing build headers.
The hook calls the native original exactly once, then tries the bounded mailbox consumer
and preserves the original's LastError. It installs with Detours/HookBatch and refuses an
already patched or registered synchronizer. The legacy experimental producer and this
service have mutually exclusive admission; this service never calls that backend.

Creation and parking execute in the qualified local client/TLS phase, as the existing
known allocation path does. That qualification and repeated ownership checks do not prove
a native physics-world mutex or universal mutation barrier. The consumer is qualified by
the exact local participant wrappers, current world/state, allocated/dynamic bitsets,
body/shape generations, configuration, watched canonical owner chain and 60 Hz listener
clock. It is not a world-wide phase guarantee. Native experimentation must retain that
limit until the actual single-capsule trial qualifies the path.

Native callbacks use fixed process-lifetime storage and try-locks only. They do no Lua,
JSON, allocation, formatting, logging or blocking SDK lock acquisition. Eight allocation
attempts are retained for the process lifetime, including failed or partially observed
attempts. No slot or old-world handle is recycled. A native destructor is unproven; pool
exhaustion is explicit and never triggers another hidden allocation or a fake deletion.
An uncertain constructor result keeps quarantine even when the confirmed subset can be
parked. A partial creation also prohibits another allocation attempt in that same world.

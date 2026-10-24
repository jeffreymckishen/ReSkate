# BMX Luau migration

This integration gives the entry one bike lifecycle owner. Private v3 Host
validation with constructed fixtures passed startup (14 cases, 2,790 assertions)
and lifecycle (14 cases, 2,884 assertions). The normal Release plugin regression suite also passed; 15 optional contributor examples were absent. Public mounting
remains disabled, and this package is not rideable; native gameplay and performance
parity remain unverified.

This package starts the migration of **all** BMX feature policy to a Lua mod.
`plugin/input.lua` is a real pure-Luau port of the current
`Engine/Game/BMX/bmx_input.h`: settings sanitation, radial normalization, source
and lifecycle gates, pedal/brake mapping, charged and R3 hops, manuals, airborne
pitch, modifier priority, neutral rearming and all trick-selector sectors.
`plugin/catalog.lua` preserves all58 named IDs and the six empty cells in the
eight-by-eight authored selector. These are requests, not executed or landed tricks.

`plugin/tricks.lua` ports the trick controller into Lua. It tracks neutral-rearmed
bar/whip channels, all catalog movements, timed catches and recovery, limb release,
measured body-local quaternion turns, canceled attempts and its own landing tally.
`plugin/motions.lua` contains our bounded retargeting targets and timings for all
58 IDs; it contains no extracted clips or source asset IDs. These targets do not
rotate a native body. The inspector does not activate this controller for riding.

`plugin/forces.lua` and its math, tire, brake and pump modules now port our ordinary
single-body riding policy. The actual Host tests passed 17 groups, 2,565 assertions,
83 force comparisons and 18 projection comparisons against our retained C++
model. This preserves our proposed laws; it is not recovered Streets physics or
verified riding feel.
See [FORCES.md](FORCES.md) for inputs, candidate history and remaining limits.
The reviewed optimization reduced offline actual-Host braking from about 17.2ms
to 0.82ms, with default slope cases around 1.79ms. The selected fixed-input runs
passed the normal rolling watchdog, but whole-plugin/native performance and
optional 128 iterations remain unqualified. Gameplay stays inactive pending
correct native contacts and complete-adapter performance evidence.

`plugin/equipment.lua` ports the neutral-rearmed toggle, North tap/hold and
LB/L1+North shortcut into pure Lua request policy. It consumes invalidated
shortcuts without leaking a tap, hold or deferred switch to another source or
owner. Its separate Host case loads the actual modules without permissions and
compares typed traces against the retained C++ gesture rules. See
[EQUIPMENT.md](EQUIPMENT.md) for composition and ownership requirements.
Release Host execution passed **8 groups, 1,269 assertions and 160 C++
comparisons**, with zero native actions, under the normal VM limits.
The explicit menu adapter now composes the generic bounded input-report API
with `plugin/equipment_transition.lua`. It preserves the full terminal receipt
before acknowledgement, then independently observes a stable target state.
See [EQUIPMENT_RUNTIME.md](EQUIPMENT_RUNTIME.md) for the stock switching path
and its validation boundaries. The bike lifecycle owner now decides whether a stock request is allowed; the stock adapter itself does not own a bike or rider.

Create it with `require("./tricks").new(settings)` and call
`controller:update(native_seconds, Tricks.input(observation))`. The adapter must
supply measured heading/orientation, actual support and qualified native elapsed
time. Ground must be observed before a flight; first contact freezes channels and
cannot complete a trick or manufacture a catch. Enable landing quality on clear
frames as well as contacts. A settle-hold flag requires fresh adapter proof and
is capped at 200ms; it never counts as actual support. Those observations still
need the generic native transport below before gameplay activation.

The Lua owner token is a stable nonempty string (up to 128 bytes), or a positive
integer up to 2^53-1. Do not cast a native uint64 pointer or generation to a Lua
number. Device epochs remain uint32. Tallies saturate at 2^53-1, the last exactly
represented integer, rather than C++'s uint64 maximum. Failure IDs are enum names
such as `under_rotated` and `invalid_sample`. Lua also rejects malformed boolean,
direction/device fields and nonfinite heading differences. State/settings readback
is detached; caller-owned quaternion tables are copied when retained.

The entry constructs exactly one `BikeRuntime.new()` with default options. That
owner creates the equipment adapter, selected input source and spawner; main
never constructs or drives a second owner. Requiring modules and constructing
it perform no reskate API calls, storage access or actuators. Main only registers
its menu and tick/unload callbacks at load. An idle tick remains inert while the
inspector is stopped. The Host's automatic storage-file loading is separate from
Lua entry behavior.

The public page remains PLUGINS → BMX Lua migration. Its slot-specific **Mount
bike (unavailable)** actions call the owner and return the native lifecycle
qualification denial before any game or storage call. There is no UI, storage
or configuration setting that enables qualification. **Stop bike / cleanup**
latches stop through the same owner. Cleanup continues on ticks even when
controller inspection is stopped. Stop freezes further body reads and entity
SETs; unresolved Follow/body duty remains visible and cannot silently re-arm.
The SDK's VM-close cleanup remains authoritative and is not a successful dismount.

**Switch skateboard / on foot** still requests one bounded Y report after the
menu closes and a settled baseline is observed. Choose an explicit XInput slot
from0 through3 and release every control; reopening the menu interrupts an
active attempt. The owner rejects stock switching while any bike authority,
acquisition, retained reload marker, or unknown/unresolved cleanup exists. The
switch phase and result distinguish input-report cleanup from the observed
stock state. No physical LB+Y shortcut is bound and no automatic board return
occurs. Nothing invokes the old BMX console, C++ controller or private mode.

The extracted lifecycle also contains a separate private qualification mode for
reviewed Host/native development. Public main never passes that option. It is
one zero-force Follow attempt per VM, bounded to500ms, with no automatic retry,
body reuse or continuous Follow renewal. Existing input-lease freshness renewals
do not extend Follow. The native Follow service independently has a fixed
three-second lease from reservation, one process-wide receipt slot and no
renewal API. The SDK retains at most eight native body allocation slots for the
process lifetime, including failed/partial attempts. Native destruction remains
unproven and slots are not recycled; capacity may already be exhausted before
this VM starts. One attempt per VM is not an eight-retry entitlement, and VM
unload does not reset native capacity. These are development bounds, not a
playable session policy.

The promoted `bike_spawn.lua` is the reviewed FirstFollow extension: it transfers
future body-release ownership before Follow reserve, keeps that transfer
permanent after failed/partial reserve, and updates visuals only from supplied
measured samples. Main never exposes its standalone diagnostic request/retry
methods. Published/transferred visuals remain until the owner observes matching
completed Follow cleanup and accepted ACK, or accepted ordinary caller release
for a provably never-published abandonment. Unknown outcomes retain duty. The
latest separate native archive reached twelve normal FOLLOW returns but stopped
on a lifetime change with body park and retirement unresolved; it proves no
mounted alignment, native input consumption or riding.

The manifest preserves `input`, `input.control`, `skater.read`, `menu` and
`storage` for the inspector, bounded stock reports, current actor facts, menu
registration and explicit-intent ledgers. Five additional permissions match
actual transitive lifecycle calls, rather than enabling public mounting:

| Permission | Transitive use |
| --- | --- |
| `input.lease` | Selected-source lease/read/state/freshness/release/ACK calls. |
| `input.capture` | Selected-source capture/state/release/ACK calls. |
| `world.physics` | Spawner body create/read/release and the Follow prerequisite. |
| `world.physics.follow` | The lifecycle's reserve/publish/read/stop/ACK Follow calls. |
| `world.entities` | Eight-part bounds/readiness checks and visual SET/removal requests. |

No mesh assets ship in this source package. Qualification requires a separate
compatible resource layer registering `reskate/bmx/{frame,fork,rear_wheel,
front_wheel,cranks,handlebars,left_pedal,right_pedal}`. Asset preflight stays
bounded to one bounds lookup per tick and eight ready IDs. The isolated
prototype resource pack used in prior development remains private and retains
donor native material/LOD dependencies; it is not a distributable free-asset
pack. A raw FBX in a Lua folder does not register native meshes. Original or
verified reusable resource assets and a clean-install test remain necessary.

For the separate read-only inspector, choose a model context and Observe
controller, close the menu, then release every control. Reopen the page to see
the last sampled requests. The selected grounded/airborne context is a model
argument, **not measured support**. Tick timing is wall-time, **not the native
physics clock**. Opening a menu, focus loss or gaps above100ms resets the model.
The panel does not claim that a hop or selected trick reached the game.

The pure mapper takes `update(raw, {grounded = boolean}, seconds)`. Build raw
values with `Input.raw`; its defaults match the original C++ aggregate. `device`
is a caller-supplied uint32 source epoch, changed on source replacement. The
current `reskate.input.gamepad()` supplies sticks/buttons but lacks device ID,
packet identity and sampling epoch. The inspector therefore uses an explicitly
manual source epoch and resets it on request; it cannot detect a replacement
pad reusing the same slot. This inspector remains separate from the lifecycle's
selected-source lease/capture path. Neither path invents physical-device identity
from the PS flag or claims native input consumption.

`plugin/tests.lua` contains portable tests of the actual Lua policy.
Requiring it does not run tests. The unconditional plugin Host regression loads
these actual package modules and calls `require("./tests").run()`. Coverage
includes all16 modifier combinations over8 directions, the full64-cell catalog,
empty slots, selector angle/radius/trigger boundaries, held and canceled hops,
manual and quick-hop context transitions, airborne pitch, neutral rearm,
focus/source/timing resets and sanitized settings. The Release build and actual
Host execution passed on 2026-10-23: **12 cases, 1,216 assertions, zero native
actions**. Unfiltered CTest reported 192 passes and one explicit rootless
trainer-tuning skip; other optional contributed-plugin fixtures and game-resource
branches also reported missing inputs. The BMX and Camera Inspector Host cases
run unconditionally. The separate `plugin/trick_tests.lua` suite also passed
actual Host execution: **16 groups and over 300 assertions**, including all 58
movement identities, catches, recovery, frozen landing settlement, interrupted
attempts, body-local quaternion turns, busy-request consumption and tally bounds.
This validates Lua model and sandbox integration;
this package has not yet been installed or tested for real riding in the game.

The experimental [`world.physics` API](../../Owned%20Bodies%20API.md) now provides
opaque owned bodies, measured state and bounded commands with a four-record
receipt pipeline. Portable and Host tests pass. A [native one-body trial](../luau-native-body-trial.md)
also created one 12 kg capsule, applied one 48 Ns impulse, observed its successor
and parked the allocation on release after explicit clock warmup. A
[separate native diagnostic](../native-pipeline-trial/README.md) then completed
120 consecutive constant-force commands with measured successors and ordered
acknowledgements. Whole-session 60 Hz operation, the BMX controller, other body
compounds and cleanup of an active body during unload, world changes or partial
failures remain unqualified.
A [varying-force diagnostic](../native-phase-trial/README.md) also measured
N+2 velocity visibility for commands requested at N and applied at N+1. The
adapter must reconcile that phase before pairing modeled history with measured
body state; applied setters do not prove an integrated N+1 response.

Generic input lease/capture, owned-body query and Follow APIs now exist. These
native integration boundaries remain unqualified for riding:

- Actor-safe wheel support, contact normals and surface velocity must be composed
  with measured body/epoch facts before force publication. [Owned-body batches](../../plugin-body-query.md)
  bind observations and bounded exclusions; API availability does not prove that
  native actor/self-hit exclusion or complete contact/force composition works.
  The earlier [native geometry diagnostic](../native-geometry-trial/README.md)
  returned two hits with actor exclusion explicitly false and no force commands.
- Selected-source capture reports process input-buffer publication, not native
  input consumption or physical-device identity. The lifecycle does not infer
  those facts from a successful lease, report, capture or transport completion.
- [Follow](../../plugin-body-follow.md) supplies a bounded local-actor/body
  binding with strict lifetime checks. The latest normal-return evidence still
  leaves body park/cleanup unresolved. It establishes neither mounted alignment
  nor a renewable riding lifetime, and does not connect pose, force or recovery.

Upstream35824f4 adds `skater.carry`, pose/reach visibility options and
`camera.cycle`. Reuse them in the full migration. The latter integrates the
camera-height button's enter/leave cycle; it is not a render-phase callback or
a physics step fence. Existing `events.physics` is delayed skater telemetry,
and `skater.set_velocity` acts on the native skateboard, not a plugin bike body.

The target architecture keeps all BMX mapping, hop/turn/contact laws, geometry,
part articulation, rider IK/pose choices, trick judging, equipment sequencing,
carry, fall and recovery policy in Luau. C++ provides only reusable, permissioned,
bounded native ownership/physics/render/input/action primitives. No legacy
BMX-specific C++ baseline is proposed as the final implementation. This first
package changes no ride feel yet; future hop/steering policy changes belong here
once the real generic body transport can execute and acknowledge them safely.

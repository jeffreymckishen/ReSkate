# BMX Luau migration

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
single-body riding policy. The actual Host tests passed 16 groups, 654 assertions
and 19 representative comparisons against our retained C++ model. This preserves
our proposed laws; it is not recovered Streets physics or verified riding feel.
See [FORCES.md](FORCES.md) for inputs, candidate history and remaining limits.
A separate actual-Host performance check currently fails the normal 2ms average
budget under strong braking. Gameplay stays inactive pending optimization and
the same performance check with adequate headroom.

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

The current entry is deliberately a **temporary read-only migration inspector**.
It asks for only `input` and `menu`. Nothing loads or calls the old BMX console,
C++ controller, physics backend or private environment modes. It acquires no
input/camera/body/pose ownership, moves nothing, installs nothing and creates no
fake or kinematic movement. Loading it does not start observation automatically.
This package is not yet a playable BMX implementation or a completed migration.

After independent validation and a separately coordinated private installation,
its page is PLUGINS → BMX Lua migration. Choose a model context and Observe
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
pad reusing the same slot. This must be replaced by a generic fenced input
snapshot before gameplay activation. No identity is invented from the PS flag.

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
receipt pipeline. Portable and Host tests pass; actual native allocation,
integration, sustained 60 Hz operation and cleanup remain unqualified. The first
private game trial reached a pre-allocation clock-warmup refusal; it did not
demonstrate a body or impulse.

The following generic SDK pieces are still missing for real riding:

- Contact normals, surface velocity and owned body/world/epoch provenance.
  The generic `world.probe` now distinguishes unavailable, clear and hit and
  returns hit position/fraction; it does not yet supply those contact properties.
- Input ownership independent of owning a camera, with original-device epochs
  and atomic local-actor motion/pose/input handoff and observed native actions.
- Native-phase bindings of plugin entities and the local actor to an owned body,
  with generation checks and actual publication/consumption receipts.

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

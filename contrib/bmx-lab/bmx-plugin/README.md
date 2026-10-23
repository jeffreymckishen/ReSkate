# BMX Luau migration

This package starts the migration of **all** BMX feature policy to a Lua mod.
`plugin/input.lua` is a real pure-Luau port of the current
`Engine/Game/BMX/bmx_input.h`: settings sanitation, radial normalization, source
and lifecycle gates, pedal/brake mapping, charged and R3 hops, manuals, airborne
pitch, modifier priority, neutral rearming and all trick-selector sectors.
`plugin/catalog.lua` preserves all58 named IDs and the six empty cells in the
eight-by-eight authored selector. These are requests, not executed or landed tricks.

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
branches also reported missing inputs. The two new BMX and Camera Inspector Host
cases run unconditionally. This validates the Lua model and sandbox integration;
this package has not yet been installed or tested for real riding in the game.

The following generic SDK pieces are still missing for real riding:

- Plugin-owned generation-fenced dynamic bodies, actual pose/velocity/mass/
  inertia observations, bounded forces/impulses and exact native-step receipts.
- Collision queries with clear/unavailable/hit separation, normals and owned
  body/world/epoch provenance; current raycast gives only a position or nil.
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

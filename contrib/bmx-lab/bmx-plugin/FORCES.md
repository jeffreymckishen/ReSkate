# Portable riding forces

`plugin/forces.lua` moves the ordinary single-body force-preparation policy into
Luau. Its math, tire, coupled-brake and pump modules derive from our own
`Engine/Game/BMX/bmx_chassis_control.h`, `bmx_tire_dynamics.h`,
`bmx_coupled_brake.h`, `bmx_ground_pump.h` and fitted constants in
`bmx_geometry.h` at `df1d5ad4c341fcb6f85661ba88017c0991b003b0`.
These are authored ReSkate laws and proposed tuning, not recovered BMX Streets
physics or a demonstrated likeness score. No parameter or input sign was
deliberately retuned during this port.

The entry point stays the read-only input inspector. It neither requires these
modules nor creates a body. This source slice is not a playable bike.

## Call contract

```lua
local Forces = require("./forces")
local controller = Forces.new() -- optional overrides from Forces.tuning()
local output, candidate = controller:preview(
    Forces.native_seconds, measured_body, measured_wheels, contacts, controls)
-- A future adapter may adopt candidate only after native acceptance and the
-- corresponding receipts. Merely calculating a preview consumes no live event.
```

`step` commits model history immediately and is useful for portable tests;
`preview` returns an isolated candidate controller. Each controller has detached
history for support normals, steering, neutral-air reservations, pump windows and
the last consumed hop ID. `reset` clears all of them. Inputs are not modified.

Vectors are three-element double-number tables. Quaternions are Hamilton XYZW,
body axes to world. The body has `mass`, `inertia_body`, `orientation`,
`center_of_mass`, `linear_velocity` and `angular_velocity`. Wheels are front then
rear, with `radius`, axial `inertia` and absolute `angular_speed`. Proposed
106kg/26,32,10 moments and geometry are Lua policy defaults only; actual measured
mass, moments and supplied wheel properties remain authoritative.

Each contact sample has a `contact` table (`status`: `unavailable`, `clear` or
`hit`; `point`, `normal`, `forward`, `surface_velocity`), signed `separation`,
and optional `balance_normal_available`/`balance_normal` and `verified_plane`.
Even clear samples require a valid current wheel plane and finite fields in the
chassis kernel. A wider query skin can produce contact response; it cannot grant
a grounded hop or landing. Unavailable contacts invalidate the calculation.

`Forces.controls()` supplies the original typed defaults. Pass partial overrides
to `step`/`preview`: `enabled`, `pedal`, `brake`, `steer`, `manual`, `nose_manual`,
`air_yaw`, `hop_strength`, `hop_event_id`, `recovery_step_verified`,
`rotation_reserved`, `pump_operator_available`, `pump_inhibited`, `ground_pump`.
Scalar fields must be finite and boolean fields must be booleans. Hop IDs are
monotonic exact nonnegative integers through 2^53-1, rather than C++ uint64.
Unknown control or tuning keys raise an error. Full contact/body/wheel tables
are required, as with the source's typed aggregates.

The caller must prove `recovery_step_verified` from the same owned body/world,
consecutive native serials and calibrated native time, after current queries.
This module accepts only the source's approximately 60Hz interval. A doubled
interval invalidates history rather than integrating through a clock gap. The
eventual adapter must also reject duplicate, backward, stale or changed-owner
samples; a caller-provided boolean is not independent native proof.

Output `force`/`torque` are world-space, bounded, and exclude native gravity.
`hop_impulse` is separate: never add it to force and submit it again. A valid
new airborne/disabled hop ID is consumed without deferring it until landing.
The result retains normal and tangential impulses, wheel speeds, brake impulses,
shared contact scale, requested/achieved steering, balance/air/pump attribution,
and qualification flags. Adopt returned wheel speeds only for an accepted step.
The tire and brake helpers return a result plus new body/wheel tables; rejection
keeps the original body/wheel identities instead of partially mutating inputs.

The ordinary kernel preserves the same twelve contact iterations, 96 braking
iterations, 64-iteration brake projection, forty-step steering envelope search
and shared force/torque/rotor budget. It keeps the original reservation rule:
deliberate air rotation survives release until strict recontact. The adapter must
continue to reserve raw gestures and pending tricks; this port does not guess a
new distinction between a held hop stroke and a deliberate rotation.

## Scope and validation

Private contact-compliance, landing-compliance and speculative-normal branches
are outside this ordinary slice. Selecting their flags/rows returns
`unsupported_policy`; they do not silently become rigid or fabricated support.
The zero-camber wheel contact model, fitted steerer, balance assist and proposed
gains retain the original model's limits. No pose integration, position repair,
heading servo or native backend call is present.

`plugin/force_tests.lua` exercises actual modules: supported and clear air,
one-shot and preview hops, left/right turn symmetry and moving ground,
steer/lean limits and actuator slew, coupled braking and energy, manual/nose,
neutral versus held-turn flight, unavailable contacts, skin/penetration limits,
clock gaps and pump windows. An unconditional Host test additionally generates
nineteen representative single-step flat-frame fixtures using the original
portable C++ kernel and compares the actual Luau outputs. This is not exhaustive
numerical parity. A separate loaded-pair recovery test mutates the caller's old
platform-velocity arrays and checks that retained history and admission stay
unchanged. That C++ code is an offline regression oracle only; it
is not reachable from the plugin and is not a runtime facade. Test execution is
verified through the actual vendored Luau Host: **16 groups, 654 assertions,
nineteen C++ comparisons, zero native actions**. The focused Release plugin
target built cleanly, and `ctest -R '^plugins$'` passed in 1.70s. Fifteen optional
contributed-plugin fixtures were absent; this force case ran unconditionally.
The first run stopped before this case because the existing trick suite exceeded
its unchanged 50ms load ceiling during concurrent compilation. A quiet rerun
passed; no runtime or existing test ceiling was widened.

The regression's enlarged per-call test ceiling accommodates many model steps
inside one load call. It makes no claim that this table-heavy implementation fits
the normal 2ms plugin tick budget. Native-phase transport, performance and actual
feel must be measured before activation.

A separate standalone actual-Host benchmark with the unchanged normal limits
found a concrete activation blocker: strong braking took about 17ms per step,
and the 2ms rolling watchdog stopped the plugin after 183 ticks in each of three
repeats, for both direct steps and preview/adopt. Coasting averaged about 1.8ms,
leaving little headroom and sometimes stopping under desktop load. This is
offline Host evidence, not a native frame measurement. Keep gameplay inactive
until the Lua solver is optimized and the same benchmark passes with headroom.

The generic owned-body service now has a four-record receipt ring and a separate
pending inbox, so its tested contract permits consecutive 60Hz publications.
A separate native trial has now confirmed one 12kg capsule and one48Ns impulse
with an actual measured successor and accepted park/release. Sustained every-step
transport and this riding kernel remain unqualified in the game. The
generic probe still lacks qualified contact normals, surface velocity and body/
world/epoch provenance required here. Input device epochs/atomic actor handoff,
part rendering, rider pose binding, fall and recovery also remain to be wired
through generic APIs. This port changes no in-game handling until those bridges
are implemented and tested.

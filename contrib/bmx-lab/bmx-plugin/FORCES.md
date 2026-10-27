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
history for support normals, steering, neutral-air reservations, pump windows, the
pedaling latch and the last consumed hop ID. `reset` clears all of them. Inputs are not modified.

At `pedal_top_speed` (7.9 m/s, just under the 8 m/s `pedal_cutoff`, which a flat road with no drag
only creeps toward) the rider stops pedaling even with the pedal held, and starts again only at or
below `pedal_resume_speed` (7.4 m/s), so the drawn cranks no longer spin with the wheel past the
speed pedaling can reach. `Forces.pedal_cadence` makes that decision and the result's `pedaling`
reports it; the rear drive, the pump's pedal factor and the composer's crank all follow it, and
the latch survives `invalidate_continuity` and a refused step. Only a rider who would pedal at the
top speed arms the latch. Once armed it follows speed alone, so letting go and pressing again inside
the band does not start a spin back up, while a bike that coasted down from above can be pedaled at
once. `bmx_chassis_control.h` has no such latch; the Host's 83 C++ parity rows pedal only at 5 m/s,
so they do not cover it.

Native acceptance and measured response have different phases. The
[varying-force diagnostic](../native-phase-trial/README.md) observed command C_N
applied at N+1 with its velocity effect first visible at N+2. Pairing the full
modeled step for C_N with measured body B_N+1 would advance the model ahead of
that body. Keep immutable, epoch-labeled command/controller/wheel histories;
an older confirmation must not replace a newer applied checkpoint or replay a
hop. The adapter needs a qualified earlier producer or delay-aware reconciliation.
Waiting for confirmation before every solve would reduce cadence and would not
preserve this module's fixed-step contract. This module predicts velocities;
it does not integrate future pose or establish future contact geometry.

`ride_inflight.lua` now carries the trial's pure forecast into the tracked Ride
path. Before preview, Ride folds its exact accepted commands that are younger
than two native serials into detached body and wheel-contact copies. Only the
age-one command acts during this forecast: velocity changes by `F*h/m + J/m`
plus gravity, angular velocity changes through the world inertia, then pose and
hit separations advance one step. An age-zero command waits; an age-two command
is already visible and is not added again. Duplicate active ages or impulse IDs,
invalid command data and incomplete hit geometry refuse the fold. Clear rays
stay clear. Measured samples, contact provenance, receipt records and acceptance
history are not replaced by these predicted copies.

The forecast is an authored model of the measured N+2 phase, not an independent
physics observation. It grants no support or command authority. Ride keeps the
accepted impulse and ID beside force and torque, so an unconfirmed hop is also
included once in the appropriate forecast interval. A ForceStage refusal now
names its issue and the unsent force/torque magnitudes and forecast velocities.

ForceStage's source-only `AUTHORED_CAPS` may include an optional positive
`torque` no greater than the kernel's 4,000 N*m limit. Legacy `{force, speed}`
caps remain valid. The cap refuses the full torque magnitude without clipping
it and retains the untrimmed model only as diagnostics. The tracked `STAGE`
stays `"zero_force"`, caps stay `nil`, and Ride's activation gate stays false.

Vectors are three-element double-number tables. Quaternions are Hamilton XYZW,
body axes to world. The body has `mass`, `inertia_body`, `orientation`,
`center_of_mass`, `linear_velocity` and `angular_velocity`. Wheels are front then
rear, with `radius`, axial `inertia` and absolute `angular_speed`. Proposed
106kg/26,32,10 moments and geometry are Lua policy defaults only; actual measured
mass, moments and supplied wheel properties remain authoritative.

Each contact sample has a `contact` table with `status`: `unavailable`, `clear`
or `hit`. A hit requires finite `point`, `normal`, `forward`, `surface_velocity`
and signed `separation`, with optional `balance_normal_available`/`balance_normal`
and `verified_plane`. A clear row needs only `{contact={status="clear"}}`; its
absent geometry is never filled with a plane, point or surface velocity. Clear
rows contribute no tire/contact impulses and grant no support, hop or landing.
Airborne drive/brake reaction retains the documented zero-camber approximation.
The free front axle is the lateral basis of body-up and steered body-forward
projected onto that body-derived model plane; the rear axle is body-left. This
authored frame is not terrain, support or measured steering-induced camber.
Supplied clear-row geometry is ignored. The inclined-steerer/front-brake
regression checks axle orientation, opposite chassis/rotor angular impulse and
absent/poisoned clear-terrain invariance. This conservative contract choice is
not a matched BMX Streets camber measurement. A wider query skin can produce contact response; it cannot grant a
grounded hop or landing. Unavailable contacts invalidate the calculation.

`Forces.controls()` supplies the original typed defaults. Pass partial overrides
to `step`/`preview`: `enabled`, `pedal`, `brake`, `steer`, `manual`, `nose_manual`,
`air_yaw`, `hop_strength`, `hop_event_id`, `recovery_step_verified`,
`rotation_reserved`, `pump_operator_available`, `pump_inhibited`, `ground_pump`.
Scalar fields must be finite and boolean fields must be booleans. Hop IDs are
monotonic exact nonnegative integers through 2^53-1, rather than C++ uint64.
Unknown control or tuning keys raise an error. Full body/wheel tables and full
measured hit fields are required; clear rows carry no terrain geometry.

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
iterations, forty-step steering envelope search and shared force/torque/rotor
budget. It keeps the original reservation rule:
deliberate air rotation survives release until strict recontact. The adapter must
continue to reserve raw gestures and pending tricks; this port does not guess a
new distinction between a held hop stroke and a deliberate rotation.

## Numerical implementation

`force_solver.lua` prepares the fixed-pose contact Jacobians, inverse-inertia
responses and coupled-brake matrices once per step. Its private scalar velocity
workspace replaces repeated body copies and tensor reconstruction inside the
alternating iterations. Each original iteration and normal/tangent replacement
still runs, with validation before and after the same impulse boundaries.
Returned body, wheel and history tables remain detached from the inputs.
A two-entry, step-local cache stores successful projections only for numerically
equal velocity/limit tuples and the same prepared matrix; it retains no state
across steps or controllers.
Three additional scalar root hints belong to each prepared wheel for this step
only. A previously measured feasible multiplier, normalized by its old search
high, is merely an initial guess against the current high. It never reuses an
impulse for different inputs. Invalid or endpoint hints use a finite interior
Rayleigh estimate or the zero start instead. The first guess spends one of the
same twelve probes and must pass the current original classifier. Failed whole
projections leave the previous hints unchanged; no hint survives the model step.

The public `Brake.constrained` helper retains the original 64 disk-search
iterations. The private solver may accelerate that same constrained objective.
Original zero-multiplier and high-end finite/SPD/rejection checks run first,
including the original early return when the zero-multiplier solution is inside
the disk. Inlined endpoint arithmetic keeps that evaluation order and checks the
determinant before division. Each public projection argument still has its own
type guard before numeric comparisons, rejecting nonnumbers, NaN and infinity.
A strictly diagonal, one-coordinate problem then has a direct interval
solution. Other moderately conditioned problems may spend at most twelve
Newton/adjacent-number probes inside an outside-low, feasible-high bracket.
Every probe uses the original square-root feasibility classification. A Newton
result returns directly only when the bracket midpoint rounds to an endpoint;
the retained high solution is feasible under that original test. Twelve valid
probes or a finite proposal exactly at an endpoint retain the proven bracket for
up to 64 ordinary bisections, with early return only at representable adjacency.
Nonfinite derivatives, uncertain conditioning or a genuinely out-of-bracket
probe instead fall back to the original 64 searches from the original endpoints.
This bounds a fallback at 76 search probes plus two original endpoint
evaluations, not 76 total point evaluations. Extreme and ill-conditioned inputs
bypass acceleration.

This changes private arithmetic order and the numerical root-finding algorithm,
not friction, braking, steering or hop laws. It does not promise universal
bit-identical output to the legacy finite search. Differential tests retain
their existing tolerances and exact qualification, rejection and event-history
checks.

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
clock gaps and pump windows. An unconditional Host test generates **83** original
C++ kernel fixtures, retaining the first nineteen flat-frame cases and adding
nonidentity orientation, asymmetric inertia, translated COM/contact points,
unequal wheels, mixed hit/clear, zero friction/brake axes, odd iteration counts
and rejection/event-history checks. Another **18** direct projection fixtures
compare the public and private paths to the C++ constrained solver: they include
nonsymmetric coefficients, invalid reduced matrices, extreme conditioning, the
early-at0/high-overflow trap and observed narrow slope brackets. Changed-input
warm starts and invalid hints are checked independently, as are thirty direct
bad-type/nonfinite argument cases. Existing comparison tolerances are unchanged.
This is representative coverage, not exhaustive numerical parity.

A separate loaded-pair recovery test mutates the caller's old platform-velocity
arrays and checks that retained history and admission stay unchanged. C++ is an
offline regression oracle only; it is not reachable from the plugin and is not
a runtime facade. The selected optimization runs through the actual vendored
Luau Host: **17 groups, 2,565 assertions, 83 force comparisons, 18 direct
projections, zero native actions**. The focused Release plugin target built
cleanly, and `ctest -R '^plugins$'` passed in 1.63s. Fifteen optional contributed
plugin fixtures were absent; this force case ran unconditionally. The test's
existing enlarged per-call ceiling accommodates many model steps inside one
load call; the normal runtime limits were not widened. The earlier committed
port's 16/654/19 result remains a separate historical checkpoint.

## Offline performance evidence

On an i7-9700K (eight cores), Windows 11 Pro 10.0.26200, approximately 32GiB RAM,
an ignored Release /O2 harness links the actual Host and vendored Luau libraries.
It performs one actual model call per tick with the unchanged 50ms call, 2ms
rolling average and 64MiB heap limits. Three repeats per case request sixty
warmup and 1,200 measured ticks, both `step` and `preview`/adopt. The measured
body/contact inputs remain fixed while controller/rotor history advances; this
does not invent native motion. Timings include Host dispatch, with no empty-tick
cost subtracted. The selected source completed all 27 original and 24 challenge
windows without watchdog stops.

| Actual workload | Step mean / p95 / max ms | Preview/adopt mean / p95 / max ms |
|---|---:|---:|
| Coasting | 0.298 / 0.352 / 2.260 | 0.310 / 0.361 / 0.713 |
| Held steering | 0.430 / 0.484 / 0.779 | 0.442 / 0.502 / 0.779 |
| Strong braking | 0.816 / 0.920 / 1.585 | 0.825 / 0.911 / 2.100 |
| Hop / neutral air | 0.226 / 0.338 / 0.646 | 0.234 / 0.349 / 0.542 |
| Rotated slope, 96 iterations | 1.790 / 1.925 / 2.618 | 1.790 / 1.899 / 3.887 |
| Mixed hit / clear | 0.885 / 0.959 / 1.297 | 0.902 / 0.980 / 1.383 |
| Zero longitudinal friction | 1.025 / 1.103 / 1.616 | 1.047 / 1.140 / 2.086 |
| Optional 128 iterations | 1.951 / 2.083 / 7.819 | 1.952 / 2.085 / 3.363 |

The retained unoptimized `ce628b9` braking baseline averaged about 17.2ms and
stopped every repeat. Failed intermediate optimizations and partial runs are
preserved. A final derivative regrouping gave no meaningful improvement and
stopped **three of six** optional-128 windows; it was dropped. That difference
does not isolate a code effect from changing desktop load. The selected simpler
source has little margin on the default slope case, and **128 iterations are
not performance-qualified** despite one complete window. Tail maxima exceed 2ms;
neither these runs nor the rolling-average limit promise every call below 2ms.

Peak observed VM heaps stayed below 1.4MiB. Frequent post-tick heap decreases are
reclamation lower bounds, not exact allocation bytes, GC cycles or pause times;
collections within a tick are invisible. No affinity, power profile, clocks or
other desktop applications were controlled. Recorded busy ranges include this
benchmark itself. The raw cases, hardware capture, unsuccessful experiments,
aggregates and manifests remain in ignored `build/bike-forces-perf-v1`, `-v2`,
`-v3` and `build/bike-forces-optimization-author-v1` evidence folders.

The generic owned-body service has a four-record receipt ring and a separate
pending inbox. Native diagnostics separately demonstrated one 12kg capsule with
one48Ns impulse and a 120-command constant-force burst with measured successors
and ordered acknowledgements. Those short transport trials do not qualify this
force kernel or a whole riding session; see [the native evidence](../luau-native-body-trial.md).

This is solver-only offline improvement, not native frame or whole-plugin budget
admission. Current queries, input, presentation and competing game work can erase
the remaining margin. Future performance work must measure the complete adapter
after correct contacts rather than repeat borderline solver windows. Qualified
contact normals, surface velocity and body/world/epoch provenance, atomic actor
handoff, rendering, rider pose, fall and recovery still require generic API
integration and actual-game tests. This package changes no handling until those
bridges are connected and tested; its entry point remains inert.

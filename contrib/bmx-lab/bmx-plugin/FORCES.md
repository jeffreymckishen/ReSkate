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
hit separations advance one step. Each hit's forward tangent is projected from
the forecast heading onto its retained measured normal, so yaw cannot create
false steering or turn lean. Missing or degenerate tangents refuse; clear rays
remain clear. An age-zero command waits; an age-two command
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
`rotation_reserved`, `pump_operator_available`, `pump_inhibited`, `ground_pump`,
`contact_compliance_available`, `landing_contact_compliance_selected`.
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

## Authored hop stage (offline only)

`plugin/force_stage.lua` also defines a source-selected `hop` stage. The offline
runner creates its qualified copy with these authored caps:

| Quantity | Fixture cap |
|---|---:|
| Full output force magnitude, excluding the separate hop impulse | 6,000 N |
| Speed perpendicular to gravity | 3 m/s |
| Absolute speed parallel to gravity | 6 m/s |
| Full output torque magnitude | 2,000 N*m |

The hop stage requires its own positive `vertical_speed` cap. Other nonzero
stages retain their existing three-dimensional speed check. Both hop speed
checks first run on the unchanged measured body, before queries, model work or
command backpressure. Accepted braking cannot conceal a measured over-cap
speed. Preview then checks the in-flight forecast against the same caps as an
additional bound. Measured admission never adopts or invalidates force history,
and a refusal leaves exact accepted receipts available for cleanup. Force and
torque caps refuse an excessive full result; they never trim it into an admitted
packet. Any kernel contact-budget scaling also refuses the nonzero stage.
The existing SDK command limits still apply to the submitted packet.

Only pedal and hop intent pass through this stage. Brake, steer, manuals, pump
and deliberate air rotation remain neutral. The pedaling latch described above
is unchanged. Stage hop IDs are exact integers from 1 through 4,294,967,295 with
strength in `(0, 1]`; no event is the pair `0, 0`. A full grounded event requests
`mass * 4.5` N*s along the kernel's hop direction. This impulse remains separate
from force in both submission and the in-flight forecast.

The frozen stage capability reports `hop_policy = "grounded_once"` and a frozen
`wheel_probe_extra = 0.75` metres. `plugin/ride_runtime.lua` snapshots this value
at construction and issues each current wheel ray from its axle centre down by
wheel radius plus that extra length. Other stages keep the existing 0.15 m
extra. The longer query supplies current geometry sooner; it does not widen the
5 mm support threshold or turn a clear ray into a floor. It neither caches a
landing plane nor grants support or native command authority.

Once the exact SDK packet is accepted, Ride adopts that preview once and
`plugin/ride_input_mapping.lua` claims its event for the receipt owner. A fresh
input report that changes grounded state cannot erase the claimed ID, and
local airborne suppression cannot retire it. Receipt disposition and ordered
acknowledgement retain their existing ownership rules; an acknowledgement never
adopts or replays the force candidate. A new unaccepted airborne press is
locally suppressed before expiry instead of being deferred to landing. If the
current sample is grounded but the forecast is already airborne, an accepted
non-hop command also suppresses that unowned event. Repeated held input or
preview calls cannot replay an adopted hop. Unknown or partial transport
outcomes retain the existing stop and receipt handling.

The tracked source still has `STAGE = "zero_force"`, `AUTHORED_CAPS = nil` and
false Ride/Core activation gates. There is no runtime setting that selects hop,
changes its probe length or supplies these caps.

### Landing policy and its geometry boundary

The hop wrapper selects both `contact_compliance_available` and
`landing_contact_compliance_selected`. The flags must agree: selecting only one
returns `unsupported_policy`; selecting neither retains the ordinary rigid law.
This is an authored Luau policy, not proof of a native compliance selection.
Caller-supplied private solver fields are cleared before the policy is derived.

`plugin/forces.lua` selects a landing row only from a valid current hit while
enabled, with `dot(normal, gravity_up) >= 0.95` and measured surface speed at most
0.0001 m/s. That is a nearly stationary measured-floor assumption, not independent
proof that the object is static. It does not invent or require `verified_plane`
as evidence for this policy. A clear ray gets no landing response; unavailable
geometry refuses calculation. Ineligible hits follow the ordinary contact law
and remain subject to the same final authored caps. The detached forecast may
advance a current hit's separation, but cannot create geometry for a clear ray.

For a selected row with gap `d` in `(0.005, 0.65]` metres, the anticipatory
approach uses `a = 25 m/s^2` and the actual fixed step `h`:

```text
allowed_closing_speed = sqrt((a*h)^2 + 2*a*d) - a*h
solver_surface_velocity = measured_surface_velocity - normal*allowed_closing_speed
```

This is a normal-only velocity constraint in `plugin/force_solver.lua`. It
allows the closing speed above and resists faster approach. Its impulse is
reported separately from actual normal load, supplies no tangent friction, and
does not establish grounded state, balance support or hop eligibility. The
body-derived free-wheel axle remains the airborne coupling model. The approach
impulse still contributes to the submitted force and torque budget. This
anticipation is authored braking before contact, not a collision observation.

At gap `d <= 0.005` m, an eligible row uses the native-style paired compliance
selection with stiffness `K = 100,000 N/m`, maximum deflection `D = 0.015 m` and
the existing recovery fraction `erp = 0.15`. Let `k` be the positive inverse
effective normal mass and `u` the solver's relative normal speed after its
surface-velocity and bias terms. The normal replacement uses:

```text
gamma = erp / (K*h*h)
target = min(0.4, erp*max(0, -d)/h) - max(0, d)/h
floor_delta = (-D-d)/h - target
normal_impulse = max(0, -u/(k+gamma), (floor_delta-u)/k)
```

The compliant replacement and the 15 mm backstop participate in the existing
alternating solve. Already excessive deflection refuses with
`landing_deflection_limit`. The final bounded output is checked again against
its one-step point-gap prediction, including gravity and the actual returned
impulses, with a 1e-8 m arithmetic tolerance. This check predicts against current
geometry; it is not a guarantee about future native collision geometry. A
landing seen too late may demand more than the authored force or torque budget
and must refuse. Neither the kernel nor the fixture repairs body position or
clips a failed landing into success.

### Offline fixture boundary

`plugin/hop_offline_fixture.lua` drives the actual Ride, Mapping, Contact,
ForceStage, force kernel, presentation and pose modules through a constructed
SDK transport. Its separate rigid-body integrator consumes the submitted
force, torque and impulse plus gravity. Commands act at N+1 and appear in the
measured sample at N+2; model predictions do not stand in for measurements.
The fixture has no collision floor clamp. Rotor startup is allowed to settle
before the measured rolling takeoff.

`plugin/hop_offline_tests.lua` requires the full-strength hop to start at
1.95--2.05 m/s, pass every ForceStage preview without contact scaling, submit
exactly one impulse per event, remain below 6,000 N and at or below 2,000 N*m,
and keep horizontal/vertical speeds within 3/6 m/s. It requires a substantial
airborne arc, settling back to the measured floor, deflection within the
fixture's 16 mm numerical allowance and final tilt below ten degrees. Separate
cases cover a held press, a second grounded hop after landing, a successor
receipt delayed one extra sample, suppression of an airborne press, no-floor
free fall and a too-late high-energy landing that sends no cropped packet.
Fresh input reports include takeoff, so event ownership is exercised across
the actual grounded-state transition.

Every measured body sample is passed through actual air-extension,
rider-offset and pose composition/validation at both posture endpoints, using
a two-step delayed skater root. All four limbs must remain reachable without
reach clamps or release, and the sent-joint root bound still applies. A separate
out-of-range root case checks the four-metre placement guard. This checks authored pose reach
under simulated delay, not live Follow rendering, animation or rider attachment.

The eight-case offline suite passed 113 assertions. The full rolling hop reached
0.991 m, with peak submitted force 3,522.45 N and torque 105.00 N*m. Minimum
measured wheel clearance was -5.74 mm and final tilt was 0.0672 degrees. It
checked 364 poses through both posture endpoints; the largest two-step root lag
across the positive scenarios was 0.157 m. This uses a 106 kg body and an exact
upward 477 N*s impulse, independently applied once.

Each positive scenario deliberately stops after settling, measures the final
body, and drains every exact accepted receipt without another submit or history
adoption. All terminal bodies receive pose checks. The delayed-publication case
also measures its bounded gravity-only coast after the last accepted packet.
Zero pending receipts describe this constructed transport, not native cleanup.

These checks do not qualify native contact geometry, receipt timing under game
load, a complete plugin frame budget or live riding. The ordinary-kernel parity
and performance results below are historical evidence for their stated slice
and do not qualify this new hop stage.

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

The ordinary default slice keeps the rigid law. The separate paired compliance
selection and hop-only anticipatory approach above are authored additions;
selecting only one compliance flag still returns `unsupported_policy`. No
caller-supplied solver policy field can fabricate these rows or support.
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

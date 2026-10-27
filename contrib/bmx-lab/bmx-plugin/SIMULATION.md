# Offline ride simulator

`plugin/sim_world.lua` and `plugin/sim_scenarios.lua` are test-only tooling. They ride one rigid body
over an authored heightfield by driving the actual `input.lua` mapper into the actual `forces.lua`
kernel, integrating the body themselves, and reducing the run to rubric-scenario numbers.
`plugin/sim_tests.lua` checks the simulator and records those numbers as a BASELINE.

Every number here is a model metric: it says what today's `forces.lua` defaults and `input.lua`
gestures do in a constructed world. It is not gameplay or native evidence, a likeness score, or
a target. Nothing was taken from `standalone/bmx-movement/reference/*`, the Streets notes or any
BMX Streets data. Any comparison target must come from the user's own observations.

Nothing is wired into `main.lua`. `RIDE_COMPOSITION_QUALIFIED` and `ACTIVATION_QUALIFIED` stay
false. The modules make no `reskate.*` call, own no SDK object and run nothing on require.
`forces.lua`, its tuning and `input.lua` are unchanged.

```lua
local World = require("./sim_world")
local sim = World.new({ speed = 4, terrain = World.terrain.ramp() }) -- optional tuning/input/yaw/x/z
local record = sim:step({ right_y = -.75 })  -- Input.raw field names; omitted fields are neutral
local Scenarios = require("./sim_scenarios")
local metrics = Scenarios.run(progress)      -- frozen; progress(id, steps) after each chunk
local runner = Scenarios.runner("S05")       -- or resumable: runner:advance(4) until true
```

A chunk budget, `run`'s optional second argument (default `chunk_steps`, 4) or `advance`'s
argument, must be a positive finite integer. Anything else raises `scenario chunk budget must be
a positive finite integer` before any work. Zero, a negative or NaN would otherwise never let
`advance` take a step, so `run` would loop forever.

## One step

`Sim:step(changes)` does, in order:

1. **Query.** A downward ray from each hub, `wheel_radius + 0.15` m long, as `ride_runtime.lua`'s
   `wheel_plan` casts it. The hubs are `bike_geometry.lua`'s axles relative to its authored COM.
2. **Contact rows**, built the way `ride_runtime.lua`'s `wheel_contacts` builds them from measured
   rays, in the FORCES.md call-contract shape. A hit has the surface point, the basis of the hit
   normal and the unsteered body forward, a zero surface velocity, `separation` measured from the
   hub along that normal minus the radius, `verified_plane=false` and
   `balance_normal_available=false`. A clear row is exactly `{contact={status="clear"}}`. A hub
   below its own column's surface (riding into a wall face) is `unavailable`, because no honest
   row exists there. Per-wheel `supported` uses `Forces.eligible_support`, as the runtime does.
3. **Input.** `Input.new():update(raw, {grounded=...}, h)`, then `World.controls` turns the
   actions into force controls by the same law as `ride_input_mapping.lua`'s `Mapper:controls`.
   A test compares the two field by field. Each hop press becomes the next hop ID, presented once
   and retired after that step. While `input.lua` is still gated the real mapping submits
   nothing; here the kernel is the only ground, so a gated step solves passive support with
   `enabled=false`.
4. **Kernel.** `Forces.new(tuning):step(Forces.native_seconds, body, wheels, rows, controls)` with
   the default tuning unless a caller passes overrides.
5. **Integrate.** Semi-implicit Euler at `Forces.native_seconds`: `v += (force/m + g) h + hop/m`,
   `w += I_world^-1 (torque h)` using the body table's `inertia_body` at the step's starting
   orientation (the response `forces.lua` predicts with, so the kernel's solved velocities are
   reproduced exactly), then the position moves by the new velocity and the orientation turns by
   the exact rotation of the new angular velocity over `h`. Gravity is added here because the
   kernel excludes it. The hop impulse is applied once and never folded into the force. Wheel
   speeds are adopted from the result. There is no gyroscopic term.
6. **Stop on refusal.** An invalid result (`penetration_limit`, `unavailable_contact`, ...) stops
   the simulation with that issue. It never integrates through it.

Each step returns a frozen record: position, velocity, horizontal and forward speed, yaw, pitch
(nose-up positive) and lean (positive toward body +X, rider left), both wheel rows' status,
separation, vertical clearance, hub and support, the controls used, hop flags, and the total
energy (body, body rotation, rotors and gravity) before and after.

## Terrain

Profiles `y = height(z)`, extruded along world X. All shapes are authored here.

| Kind | Shape |
| --- | --- |
| `flat()` | Level ground. |
| `ramp{start_z, angle, blend, top}` | Defaults 3 m, 15 degrees, 0.5 m, 3 m: a straight face with a quadratic blend at the foot and the lip, so the slope is continuous, then a level deck. |
| `ledge{edge_z, height}` | Defaults 2 m, 0.3 m: a raised deck for `z < edge_z`, then ground level. |
| `gap{near_z, far_z, depth}` | Defaults 4 m, 5.5 m, 1 m: a pit between the edges. |

## Not modelled

- **Native command latency.** FORCES.md records command C_N applied at N+1 and visible at N+2.
  The simulator applies each command within its own step.
- **Native collision.** The frame, rider and wheel capsules collide with nothing. The kernel's
  tyre impulses are the only ground, so a crash stops the run instead of tumbling.
- **Rolling resistance and drag.** `forces.lua` has neither and none was added. A coast keeps its
  speed, so coast "distance" is speed times time, and top speed is 7.9 m/s, where the rider stops
  pedaling just under the 8 m/s pedal cutoff (FORCES.md).
- **Recovery proof.** `recovery_step_verified` stays false as in `ride_input_mapping.lua`, so
  neutral air damping and recovery continuation never engage.
- Lease, source and epoch identity, receipts and the owner's stop hook. Only the control law is
  cross-checked against the mapping.
- Moving surfaces, lateral terrain variation, non-vertical gravity, rider pose, presentation,
  tricks, grinds and bails.

## Scenarios

Rubric IDs are those of `judging/rubric-v1.json`. Each scenario is one deterministic trial. Speeds
are initial rolling speeds along +Z from a placed, touching body. Times are in seconds, distances
in metres and angles in radians.

| ID | Runs | Script |
| --- | --- | --- |
| S01 | `flat` | 1 neutral step, 6 s pedal, 3 s coast, brake until below 0.05 m/s (6 s cap), 0.5 s rest, 2 s pedal. |
| S02 | `left_3`, `right_3`, `left_6`, `right_6` | 0.5 s straight, 3 s full left stick X, then 1 s released. |
| S04 | `speed_3`, `speed_6` | No input on the default ramp at `start_z=2`, until the COM rolls back behind its start (8 s cap). |
| S05 | `r3_quick_hop`, `full_charge_flick`, `minimum_flick` | 4 m/s on flat. R3 for one sample; right stick back 0.3 s then forward; one sample back then forward. |
| S05 | `gap_r3`, `gap_no_hop` | 5 m/s at the default gap: R3 once the front hub is within 1.5 m of the near edge, or no input. |
| S06 | `speed_2`, `speed_5` | No input off a 0.3 m ledge at `edge_z=1.5`. |
| S07 | `manual_075`, `manual_070`, `manual_060`, `nose_075` | 4 m/s, 2 s with the right stick held at Y = -0.75, -0.70, -0.60 or +0.75 and nothing else, then 1 s neutral. |

The metric definitions:

- **S01.** `time_to_3`, `time_to_6`, `time_to_7_5` are from the first pedal step to that
  horizontal speed (-1 if never reached). `top_speed` is the speed after 6 s. Brake `seconds` and
  `distance` run from brake onset to the stop. `mean_deceleration` is the speed lost over that
  time and `peak_deceleration` the largest single-step loss. `creep_distance` is the distance
  rolled during the rest.
- **S02.** In the last 1.5 s of the hold, `radius` is the path length over the heading change,
  `yaw_rate` the heading change per second (left positive), plus the mean lean, the mean speed and
  the fraction of steps where the kernel limited steering. `hold_speed_change` and
  `hold_energy_change` cover the whole hold. `release_heading_change` is the heading still turned
  after release. `release_settle_seconds` is the time until the yaw rate is below 0.05 rad/s.
- **S04.** `peak_rise` is the COM's highest point above its start. `ideal_rise` is the start's
  kinetic energy (body and rotors) over m g, and `rise_ratio` is the first over the second.
  `return_speed` is the signed forward speed once rolled back.
- **S05.** `apex_rise` is the COM's height above where it was before the hop step.
  `apex_clearance` is the largest lowest-tyre clearance. Impact is the first step after both tyres
  have left the 0.02 m contact gap whose query puts a tyre back inside it. `airtime` runs from
  the end of the hop step to the start of the impact step. `landing_vertical_speed` and
  `landing_pitch` are taken entering impact. `impact_to_support` is the time until the
  eligibility test passes again. In the gap runs, `takeoff_front_to_edge` and
  `landing_rear_past_far` place the hop, and `cleared` means the run was valid and the rear hub
  was past the far edge when support returned.
- **S06.** `first_landing` is the first wheel supported past the edge. `front_to_rear_landing` is
  the time until both are, `airborne_seconds` the time with neither wheel supported,
  `settle_seconds` the time from the rear leaving the deck until pitch is within 0.01 rad,
  `energy_loss` the total energy lost and `drop_potential` m g 0.3.
- **S07.** `control` is the `manual` or `nose_manual` the stick produced. `lifted` means the
  lifted wheel left the contact gap. Then come `time_to_lift`, the peak pitch, the mean pitch over
  the last 0.5 s of the hold, the maximum wheel clearance and the lifted and base-supported
  fractions. `release_drop_seconds` is how long the lifted wheel stays up at neutral input (0 if
  it was not up when the stick let go).

## Current baseline

Recorded 2026-10-25 with forces.lua's defaults (106 kg, 26/32/10 kg m^2, hop_delta_speed 4.5,
pedal_cutoff 8). S01 was recorded again on 2026-10-26, when the rider began to stop pedaling at
7.9 m/s; no other scenario changed. These are today's values, not goals.

| Scenario | Numbers |
| --- | --- |
| S01 accelerate | 3 m/s in 1.20 s, 6 m/s in 2.38 s, 7.5 m/s in 3.47 s. The rider stops pedaling at 7.90 m/s after 4.72 s with A still held. 7.90 m/s and 34.6 m after 6 s. No lean or lateral drift. |
| S01 coast, 3 s | -4.1e-10 m/s, 23.7 m, +6.6e-7 J (see below). |
| S01 brake | From 7.90 m/s: 2.22 s and 8.74 m to rest, 3.54 m/s^2 mean, the same as the peak. |
| S01 rest, restart | 23.3 mm creep after release (the brake stopped at 0.047 m/s). 5.11 m/s and 5.20 m after 2 s of pedal. |
| S02, 3 m/s | Radius 3.22 m, 0.944 rad/s, lean 0.183, steering not limited. +0.015 m/s and +8.6 J with no pedal. 0.140 rad more heading after release, settled in 0.45 s. |
| S02, 6 m/s | Radius 7.13 m, 0.854 rad/s, lean 0.294, steering limited every step. +0.053 m/s and +19.0 J. 0.122 rad more heading after release, settled in 0.42 s. Left and right mirror exactly. |
| S04, 3 m/s | Rise 0.449 of an ideal 0.488 m (92.0%). Rolls back at 2.79 m/s (93.1%), -67 J, peak pitch 0.270. |
| S04, 6 m/s | Rise 1.906 of an ideal 1.952 m (97.6%). Rolls back at 5.78 m/s (96.3%), -149 J, peak pitch 0.326 against the 0.262 face. |
| S05, R3 and full charge | Strength 1. Takeoff 4.34 m/s, COM apex and tyre clearance 0.996 m, airtime 0.883 s, 3.53 m in the air. Lands level on both tyres at -4.32 m/s. The full charge spends 0.30 s before the hop. |
| S05, minimum flick | Strength 0.25. Takeoff 0.96 m/s, apex 0.055 m, airtime 0.183 s. |
| S05, gap | R3 1.40 m before the lip clears 1.5 m with the rear landing 0.75 m past the far edge. With no hop, the front hub reaches the far wall at 1.05 s and the run stops with `unavailable_contact`. |
| S06, 2 m/s | Never fully airborne: noses down to -0.328 with the rear still on the deck. Front first, rear 0.30 s later, at most 0.76 m/s down, settled 0.25 s after the rear leaves. |
| S06, 5 m/s | Airborne 0.183 s, pitch -0.227. Front first, rear 0.15 s later, 1.70 m/s down, 4.1 mm deepest penetration, settled in 0.28 s. |
| S06, both | Energy lost equals m g 0.3 (311.6 J) and the exit speed equals the entry speed. |
| S07 manual | Stick -0.75 gives manual 0.992: lifts in 0.13 s, holds 0.224 with 0.207 m of clearance and drops 0.25 s after neutral. Stick -0.70 gives 0.878: holds 0.140 and 0.130 m, drops in 0.20 s. Stick -0.60 gives 0.651 and never lifts. |
| S07 nose manual | Stick +0.75 gives 0.992: the rear lifts in 0.23 s, holds 0.101 with 0.094 m and drops in 0.17 s. |

What these say about the model, not about any game:

- The hop is a fixed 4.5 m/s velocity change scaled by strength. Every strength-1 input gives
  about 1 m of COM rise and 0.88 s in the air. Height goes with strength squared (0.25 gives
  0.055 m). By construction, R3 and a full charge are identical.
- The manual is a static equilibrium of the balance assist. It settles where
  `1600 sin(target - pitch)` meets the weight's moment about the rear contact (about 432 Nm with
  the authored COM 0.416 m ahead of the rear axle). Below about manual 0.68 the assist cannot
  lift the front at all. There is no balance point: at neutral input the wheel is down within
  0.17-0.25 s. `manual_balance.lua` is a separate item.
- Held steering adds energy with no pedal (+8.6 J and +19 J), because the balance-assist torque
  is an actuator.
- Coasting gains energy in one way only. Pedalling squats the rear tyre into its contact gap
  (about 5 mm after 0.5 s from rest). When the pedal stops, the kernel's recovery bias lifts the
  COM back to the placed ride height: about +3 J after a 0.5 s pedal. S01's rider stops pedaling
  1.3 s before its coast, so that lift is over by then and the coast gains only 6.6e-7 J. The tests
  check two things. A coast from a
  placed, settled body never gains energy. A coast after pedalling may gain only that lift:
  kinetic energy does not rise, the COM stays at or below the placed ride height, and the gain is
  at most m g times the height recovered.
- Braking is limited by brake torque (constant 3.54 m/s^2), not friction. Landings are fully
  plastic. The ramp foot and the return dissipate energy, and the 6 m/s entry briefly unloads the
  front tyre.
- Numerically, semi-implicit Euler loses m g^2 h^2 / 2 (about 1.41 J) per airborne step. That is
  integrator drift, not modelled drag.

## Tests

```powershell
& 'C:\Users\Jeffr\Desktop\reskate\build\bmx\parallel-tricks-presentation-proposal-v1\harness\build\Release\presentation_luau_tests.exe' 'C:\Users\Jeffr\Desktop\reskate\contrib\bmx-lab\bmx-plugin\plugin' sim_tests
```

The run prints `cases=12 assertions=208006` (with `os.clock` present). How long it takes depends
on what else the desktop is doing. One sample on the i7-9700K at about 44% load took 7.1 s.
`run(progress)` returns `{cases, assertions, native_actions=0}` and the chunk count. It also
returns advisory wall-clock figures: `chunk_ms_median`, `chunk_ms_p99`, `chunk_ms_max` and
`chunks_over_20ms`.

| Case | What it checks |
| --- | --- |
| inert modules | Every table reachable from either module is frozen, including the terrain kinds, the scenario order and the hub offsets. Also the native interval and the kernel's radius. A new runner has created no simulator and taken no step. |
| terrain profiles | Heights, continuous slopes through both ramp blends, the ledge, the gap, and ray hit, clear and inside results. |
| contact rows | Hit rows in the call-contract shape. Clear rows are exactly one field and stay clear through `forces.lua`. Ramp separation is measured along the face normal. A wall-face hub is unavailable. |
| rigid-body integrator | Closed-form semi-implicit Euler under gravity, inertia taken from the body table (scaled and yawed), a one-time hop impulse, exact rotation over 60 steps, and ballistic flight through the whole kernel step. |
| controls mirror the mapping | `World.controls` equals `ride_input_mapping.lua`'s `force_controls`, field by field, over a 19-sample pad sequence: pedal, brake, steer with pump, manual, charge, flick, R3, triggers and shoulders, and airborne pitch. At least 12 rows must compare, including two with a pending hop and two airborne. |
| input drives the kernel | The neutral gate, R3 as one consumed hop event, a gated trigger, the pedal moving the bike, and a refused step stopping the run. |
| no energy gain coasting | At 0, 1, 4 and 8 m/s for 2 s each, from a placed body: the total never rises and no step gains more than 1e-6 J. Then 2 s of coast after 0.5 s of pedal from rest, held to the recovery-lift bound above. The bound must cover a gain over 1 J, so it is not vacuous. |
| metrics finite and frozen | Every number is finite and the table is frozen. All runs are valid except the expected gap wall strike. Turns mirror, and the hop strengths are 1, 1 and 0.25. S01's coast is held to the same recovery-lift bound, and its `energy_change` is that lift. |
| repeat run is bit-identical | A second full run gives `==` equality on every metric and on every field of every step record. |
| BASELINE | Every metric matches the record, numbers within 1e-6 relative. `lua_source` produces an exact expected string for a constructed table (integers, -0, a 17-digit double, an array, a nested table, quoted strings and keys, booleans). It refuses inf and nan. On the metrics, every leaf line reads back with `tonumber` or `%q` to the identical value, in sorted key order. |
| chunk budget | A chunk is exactly `chunk_steps` (4) native steps. For both full runs, each scenario gets one progress call per `advance()`. Every call but the last follows exactly 4 steps and the last fewer, and the steps add up to the traced steps. The median chunk time is under 20 ms. |
| invalid chunk budget | Zero, -0, negatives, NaN, both infinities, fractions, a string, booleans and a table are refused by `advance` and by `run` before any work or progress call, and a missing `advance` budget too. The runner's first attempt at work and the first progress call both raise, so the check stays bounded on code that would loop. A refusal part way through S01 leaves the run as it was, and a valid budget resumes it. |

**Chunk timing.** The hard bound is deterministic: a progress call never waits on more than four
kernel steps. Wall time is only advisory. Luau's `os.clock` is a wall clock, so a chunk that
another process preempts counts that process's time, and no chunk size prevents this. The only
timing assertion is the median under 20 ms, because the median survives preemption. The tail is
reported, not asserted.

Two samples on the i7-9700K:

- At about 44% load: median 1.6 ms, p99 6.5-7.9 ms, max 13.6-17.6 ms, none over 20 ms.
- With eight copies running at once to saturate the CPU: median 2.5-2.9 ms, p99 24-60 ms, max
  79-277 ms, and 39-121 of 2148 chunks over 20 ms. All eight passed.

So "each chunk under 20 ms" holds for the work in a chunk. It does not hold for every wall-clock
measurement on a busy desktop.

Perturbation checks were done in a private copy outside the repository and not committed. Each
one made the suite fail where it should:

| Change | Failed on |
| --- | --- |
| `hop_delta_speed` 4.4 | BASELINE, `S05.r3_quick_hop.apex_clearance` (0.951 against 0.996) |
| `Scenarios.run` chunks of 5 steps | Chunk budget, S01 progress call 1 |
| One progress call skipped | Chunk budget, S01 progress call 10 |
| Forward speed scaled by 1+1e-6 while a tyre is in its gap | The post-pedal coast, on kinetic energy. With that check disabled, the S01 coast check failed instead. |
| Number keys quoted by `%q` again, or `%.15g` | The constructed `lua_source` string |
| `%.15g` only above magnitude 1 | The metrics round-trip, first leaf |
| `Terrain` left unfrozen | Inert modules, `frozen World.terrain` |

## Re-recording the baseline

Only re-record when a change to `forces.lua`, `input.lua` or the simulator is intended:

1. Copy the plugin folder outside the repository.
2. Add a throwaway module whose `run()` prints `Scenarios.lua_source((Scenarios.run()))` and
   returns a nonzero `{cases, assertions}`.
3. Run it with the runner above.
4. Paste the output over `BASELINE` in `sim_tests.lua` and review the diff as a behaviour change.

Never tune toward these numbers.

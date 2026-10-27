# Offline rubric metrics

`bmx-plugin/plugin/rubric_metrics.lua` turns step traces into the measurable quantities that
[rubric-v2.json](rubric-v2.json) describes: how fast the bike pedals up to speed, how it coasts and
brakes, how tight it turns at each speed, how high and how long it hops, how a landing compresses,
how steady a manual is, the entry and exit speeds of a grind, and how smoothly a camera follows.
It reads the traces that `sim_world.lua` and `sim_scenarios.lua` produce. Grind and camera
reductions also take plain traces from `grind_policy.lua` and `camera_policy.lua`.

For seven of these metrics the project's own notes record what BMX Streets did when it was run and
measured. For those seven the module also computes an offline score with the tolerance stated below.
All other metrics are reported with no score and marked `no_recorded_target`.

**An offline score is not the human-judged likeness score.** The rubric is unrated until current-build
footage covers every category, and it says test counts, telemetry and source review cannot stand in
for that ([rubric-v2.json:9](rubric-v2.json), [:115](rubric-v2.json)). The owner's controller gate
([:17](rubric-v2.json)) is separate again. An offline score measures how close one model number,
from a constructed world, is to one recorded observation. It runs from 0 to 1, deliberately not on
the rubric's 0 to 10 scale. It is not gameplay or native evidence, and it is not a tuning target on
its own.

The module is test-only tooling. It makes no `reskate.*` call, owns no SDK object and runs nothing on
require. Nothing is wired into `main.lua`, and `RIDE_COMPOSITION_QUALIFIED` and
`ACTIVATION_QUALIFIED` stay false. No existing module was changed.

```lua
local Scenarios = require("./sim_scenarios")
local Metrics = require("./rubric_metrics")
local _, runners = Scenarios.run()
local report, metrics = Metrics.evaluate(runners)   -- collect, extract, flatten, report
-- or step by step:
local collected = Metrics.collect(runners)          -- {S01 = {flat = {trace, tags, initial, terrain, valid, issue}}, ...}
local nested = Metrics.extract(collected)           -- frozen: scenario -> run -> metric
local values = Metrics.flatten(nested)              -- {["S05.r3_quick_hop.airtime"] = 0.883, ...}
local owner = Metrics.report(values, my_targets)    -- any target table; Metrics.targets by default
```

`report.rows` has one row per metric, sorted by id: `id`, `category`, `unit`, `value`, `scored`,
and either `reason` or `score`, `within`, `low`, `high`, `midpoint`, `relative_error`, `sources`,
`caveats` and `definition`. A target with no matching metric gets a `metric_missing` row.
`report.summary` holds `kind = "offline_model_closeness"`, the disclaimer, the counts and the
`lowest_score`. It never holds an average, because the rubric takes the minimum so a weak category
is not hidden ([rubric-v2.json:14](rubric-v2.json)).

## Trace conventions

A `sim_world.lua` record holds the state after its step: `time`, `position`, `velocity`, `speed`
(horizontal), `forward_speed`, `yaw`, `pitch` and `lean`. Its `front` and `rear` rows come from the
query before the step, and each has `status`, `separation`, `clearance`, `hub` and `supported`.
Windows are the runs' own `sim_scenarios.lua` tags. A window starts from the record before it, or
from the run's placed initial state when it opens the trace. A step's length is the difference
between record times. A tyre is touching when its row is a hit within forces.lua's 0.02 m contact
gap. The extractors read only these fields, so a native trace with the same fields would go
through the same code. No such trace exists yet.

## Metrics by rubric category

Ids are `<scenario>.<run>.<metric>`, for example `S02.left_6.radius`. Rubric categories follow the
scenario numbers in rubric-v2.json: S01-S03 riding, S04-S06 ramps and landings, S07-S10 tricks,
S22-S26 grinds and S27-S32 camera. The current extraction produces 466 values.

**Riding and steering (S01, S02).**

| Metric | Definition |
| --- | --- |
| `accel.early_acceleration` | Least-squares slope of speed on time while pedalling, using only records between 0.52 and 3.87 m/s. That band is the native fit window's first and last speed. |
| `accel.mean_acceleration`, `peak_acceleration`, `plateau_acceleration` | Speed gained over the window, the largest single step, and the slope over the last 0.5 s, which is near zero at top speed. |
| `accel.time_to_3`, `time_to_6`, `time_to_7_5`, `speed_at_0_5` ... `speed_at_4` | The pedal curve. A key is absent when the window never reaches that speed or time. |
| `coast.*`, `brake.*` | Start and end speed, `mean_deceleration`, `ols_deceleration`, `peak_deceleration`, `stopped` (below 0.05 m/s), `stopping_seconds`, `stopping_distance` and distance. |
| `brake.moving_brake_deceleration`, `brake.later_brake_deceleration` | Least-squares deceleration over the brake records between 0.08 and 4.52 m/s, and between 0.08 and 2.67 m/s. These are the native fit windows' speeds. |
| `rest.creep_distance` | Distance rolled at rest. |
| `<turn>.radius`, `yaw_rate`, `lateral_acceleration`, `mean_lean`, `mean_speed` | Over the last 1.5 s (90 steps) of the held turn: path length over heading change, heading change per second (left positive), mean speed times yaw rate, and so on. |
| `<turn>.release_heading_change`, `release_settle_seconds` | Heading still turned after the stick lets go, and time until the yaw rate is under 0.05 rad/s. |
| `summary.radius_growth_per_speed`, `yaw_rate_growth_per_speed`, `mirror_radius_error`, `mirror_yaw_rate_error` | Turning radius against speed: least-squares growth over all four turns, and the largest left-right difference relative to the pair's mean. |

**Ramps and landings (S04, S05, S06).**

| Metric | Definition |
| --- | --- |
| `peak_rise`, `momentum_retained`, `max_pitch`, `max_pitch_rate`, `unsupported_seconds` | Ramp: highest COM rise, speed rolled back with over the entry speed, steepest pitch, fastest pitch change (a snap reads here), and time with neither tyre supported (hovering or launching). |
| `apex_rise`, `apex_seconds`, `apex_clearance`, `airtime`, `air_distance` | Hop: COM rise above the step before the hop step, time to apex, highest lowest-tyre clearance, time from the end of the hop step to the step whose query puts a tyre back in the contact gap, and horizontal travel. These are `sim_scenarios.lua`'s S05 definitions, recomputed from the raw trace. |
| `takeoff_vertical_speed`, `landing_vertical_speed`, `landing_pitch`, `impact_to_support`, `first_contact` | Takeoff and landing state. |
| `landing.compression_depth`, `com_dip`, `compression_seconds`, `rebounded`, `rebound_seconds`, `max_rebound_speed`, `pitch_excursion`, `speed_retained`, `supported_at_end` | The 0.5 s after the last airborne record: deepest tyre penetration, COM sink below where it ends the window, and time to the lowest point. The COM has settled from the first record after which it stays within 1 mm of its end height. `rebounded` says that happened before the window's last record, so a COM still rising or sinking when the window closes has not rebounded. `rebound_seconds` runs from the lowest point to the settled record, and is 0 for a dip under 1 mm. Then the fastest upward COM speed (bounce), the largest pitch difference from the window's end, speed at the end over the last airborne speed, and whether both tyres carry the bike at the end. |
| `first_landing`, `front_to_rear_seconds`, `airborne_seconds`, `max_drop_speed`, `min_pitch` | Ledge drop. A wheel has landed once it is supported past the edge. |

**Tricks (S07).** `time_to_lift`, `longest_hold_seconds` (longest unbroken lift), `touchdowns`,
`lifted_fraction`, `base_supported_fraction`, and over the lifted steps `lift_pitch_mean`,
`lift_pitch_std`, `lift_pitch_range` and `max_lift_pitch_rate`. There is also `peak_lift_pitch`,
`hold_lift_pitch` (the last 0.5 s), `release_drop_seconds` and `lift`, the wheel that the stick's own
control lifted.

**Grinds (S22-S26).** `Metrics.grind(trace)` reads a trace whose records carry grind_policy's
`state`, `grind` and `exit_reason`, plus `rail_speed` (or `speed`). One grind is the run of `locked`
or `stalled` records, so a grind that slows into grind_policy's stall is still one grind. Its
metrics are `entry_speed` and `exit_speed` (first and last grind record), `seconds`, `mean_speed`,
`speed_change`, `speed_retained`, `deceleration` (a least-squares fit), `grind` (the type it locked
as), `exit_reason` (the first reported after the grind) and `count`. The simulator has no rails, so `sim_scenarios.lua` produces
no grind trace. The test drives the actual `grind_policy.lua` with constructed peg rows.

**Camera (S27-S32).** `Metrics.camera(views, subjects, {seconds, aspect})` reads
`{eye, target, fov, reset}` views beside subject positions. It reports `min_distance` and
`max_distance`, `max_eye_speed`, `max_eye_acceleration` (second difference over h^2, where snaps
and jitter show), `max_aim_rate` (the aim's turn per second), `max_subject_angle` (the subject's
angle from the aim), `min_frame_margin`, `out_of_frame_steps`, `min_fov`, `max_fov`, `resets` and
`own_view_steps`.

The frame test uses the view's rectangle. `camera.look`'s field of view is vertical: the SDK's
camera contract says `set_camera` takes "a vertical field of view in degrees (0 the camera's own)"
(`Extension/Plugins/plugin_game.h:678-679`). `camera.look` passes its `fov` straight to
`set_camera` (`Extension/Plugins/plugin_api_world.cpp:205`, `:219`). The test builds
`camera.look`'s own basis, which has a level right axis and no roll (`plugin_api_world.cpp:206-218`).
A subject is in frame when its vertical angle from the aim is within half the field of view, and
its horizontal angle is within `atan(aspect * tan(fov/2))`. `min_frame_margin` is the smaller of
the two angular margins, and it is negative when the subject is out of frame. The views do not
record the viewport, so `aspect` defaults to `Metrics.camera_aspect`, which is 16/9. That matches
the project's 1280x720 game captures ([REFERENCE.md:52](../../../standalone/bmx-movement/REFERENCE.md)).
It is an assumption about the player's screen, not a measurement of it. A `fov` of 0 or none means
the camera's own field of view, which a view does not carry. Such a step counts in
`own_view_steps` and is left out of the frame test and the fov range. `camera_policy.lua` never
asks for 0.

`camera_policy.lua` returns Luau vectors, which are single precision, so a second difference
carries their rounding over h^2. That was about 2e-3 m/s^2 near the origin in the test, and it
grows with distance from the origin.

**Every run.** `continuity.max_position_residual` is the largest distance between where a record is
and where its own velocity carried it from the last one. `teleports` and `first_teleport` count
residuals over 0.25 m. `max_speed_step`, `max_pitch_step`, `max_lean_step` and `max_yaw_step`
(wrapped) are the largest single-step changes. Records with `valid=false` are skipped, because the
simulator does not integrate a refused step. `valid` and `issue` say whether the run finished.

Rider movement, falls and recovery, and equipment transitions have no trace quantity here. S03 and
S08-S21 are not in `sim_scenarios.lua`.

## Recorded targets

Each value below is BMX Streets behaviour that was measured from the running game and recorded in
the project's own notes, cited by file and line. The two speed bands come from the fit file behind
the note. The module copies only these few numbers. The "band" column is the observed range widened
by the tolerance.

| Metric id | Observed | Band | Sources |
| --- | --- | --- | --- |
| `S01.flat.accel.early_acceleration` | 2.4911 m/s^2 | 2.2420-2.7402 | [comparison-v1-history.md:37](../../../standalone/bmx-movement/reference/comparison-v1-history.md); band from actual-flat04-fits.json:180-184 |
| `S01.flat.brake.moving_brake_deceleration` | 3.7318 m/s^2 | 3.3586-4.1050 | comparison-v1-history.md:37; actual-flat04-fits.json:207-211 |
| `S01.flat.brake.later_brake_deceleration` | 3.1465 m/s^2 | 2.83185-3.46115 | comparison-v1-history.md:37; actual-flat04-fits.json:261-265 |
| `S05.r3_quick_hop.apex_rise` | 2.510, 2.404, 2.3476, 2.3279, 2.3997 m | 2.0860-2.7519 | [COMPARISON.md:36](../../../standalone/bmx-movement/COMPARISON.md), :37; comparison-v1-history.md:25, :37; actual-flat04-fits.json:46-47 |
| `S05.r3_quick_hop.airtime` | 1.430, 1.390, 1.3700, 1.3600 s | 1.2205-1.5695 | COMPARISON.md:36, :37; comparison-v1-history.md:26; actual-flat04-fits.json:61 |
| `S05.full_charge_flick.apex_rise` | 1.452 m | 1.3068-1.5972 | COMPARISON.md:38 |
| `S05.full_charge_flick.airtime` | 1.140 s | 1.0260-1.2540 | COMPARISON.md:38 |

The fit file is `standalone/bmx-movement/recordings/comparison-session01/actual-flat04-fits.json`.
The R3 rise and airtime targets read the same three native captures. These are the two hops of
COMPARISON.md:36-37, the full v1 sequence (comparison-v1-history.md:25-26), and the short v1
session. The short session's hop is in the fit file: its rise is at lines 46-47 (chassis and
combined COM) and its airtime at line 61, inside the file's `native` block. The other hop block
(lines 120-140) belongs to the file's `demo` run, which is the C++ model, so it is not used.

Each target in `Metrics.targets` carries its own caveats. The main ones are these:

- **Different world.** The game was observed with runtime gravity of -12.5 m/s^2
  ([REFERENCE.md:50](../../../standalone/bmx-movement/REFERENCE.md)). forces.lua uses -9.8
  (`forces.lua:11`). Rise and airtime are compared as observed, with no gravity scaling. The rise
  and airtime of one hop are not independent scores.
- **Different body.** The native rise is the chassis or combined vehicle COM of a multi-body rig.
  The model's is the one 106 kg body.
- **Different clock and contact.** Native airtime is engine-clock time between ground flags
  (COMPARISON.md:67). The model's is the contact-gap definition above. Under observation, native
  engine time ran at 0.93 of wall time (comparison-v1-history.md:41).
- **Few captures.** Acceleration, braking and the flick are single captures. R3 has five rise
  readings and four airtime readings from three captures. The two brake windows come from the
  same brake. Native braking also depends on speed (REFERENCE.md:58 lists it as a
  fidelity gap), while the model's is constant. The model brakes from about 8 m/s, so only its
  samples inside each band are fitted.
- **Input.** The native flick is a full right-stick flick. Its counterpart here is S05's
  `full_charge_flick`. R3 is the quick hop in both.

## Tolerance and score

The band is `[min(observed) - m*|mid|, max(observed) + m*|mid|]`, where `mid` is the middle of the
observed range and `m` is the margin, 0.10. The score is 1 inside the band. Beyond it the score
falls linearly to 0 at a distance of `f*|mid|` from the band edge, where `f` is the falloff, 0.50.
These are authored values:

- The 10% margin covers the spread the observations already show. The five R3 rise readings span
  2.33-2.51 m, 7.5% of their midpoint, across three captures. The four R3 airtimes span
  1.36-1.43 s, 5.0% of theirs. It also covers a single capture's clock uncertainty (the 0.93
  engine-to-wall ratio).
- The 50% falloff means a metric that is off by half again scores 0. It is a presentation choice,
  not evidence.

`Metrics.score(value, target)` refuses a non-finite value and a malformed target. A target table is
plain data: `{observed = {...}, margin, falloff, unit, sources, caveats, definition}`. An owner who
measures the game by hand can pass their own table to `Metrics.report`, and nothing else changes.

## What was left out, and why

- **Decompiled or decoded values.** The hop velocity table and impulses, the flick thresholds and
  timeout, landing and pump timers, decoded serialized settings (including a top speed and masses)
  and the IK and rider constants are extracted game data. Their sources include REFERENCE.md:42-46
  and :54-56, the decoded-settings sentence of REFERENCE.md:50,
  `standalone/bmx-movement/reference/calibration-current.*`, the
  `bmx-streets-*-reference-2026-10-22.md` notes and `streets-rider-landing-reference.md`. None of
  their numbers is copied here or used. REFERENCE.md:50 mixes two kinds of statement. Its runtime
  observation of a 0.01 s step and -12.5 m/s^2 gravity is cited above, only as a caveat. Its
  sentence on decoded serialized settings is excluded. The test refuses a target source whose path
  names calibration, evidence or streets notes.
- **Manual and nose-manual peak pitch** (COMPARISON.md:34-35). These were partial-stick requests
  (COMPARISON.md:45) on a chassis/spring split, and the native Manny movement mode was not captured
  (COMPARISON.md:71). S07 holds a fixed stick on one body. They are not comparable, so they are
  unscored.
- **Airborne left-stick yaw** (COMPARISON.md:39). No simulator scenario steers in the air.
- **Older pilot hop rises** (COMPARISON.md:65). They come from a different capture context, and the
  note does not name the hop input.
- **Posture errors** (COMPARISON.md:21, :33). These describe pose, not a trace quantity.

[SIMULATION.md:9-11](../bmx-plugin/SIMULATION.md) asks that comparison targets come from the
user's own observations. The cited values are the project's recordings of the user's installed
BMX Streets, driven by the virtual controller. They are not the owner's judgment of feel, and the
repository records no owner feel numbers. To follow SIMULATION.md's stricter reading, pass `{}` or
an owner table as `targets`. The extraction does not change.

## Current offline readings

These were recorded on 2026-10-25 with today's forces.lua and input.lua defaults, the same model as
SIMULATION.md's baseline. The S01 coast and brake readings were taken again on 2026-10-26, when the
rider began to stop pedaling at 7.9 m/s; no score and no other scenario changed. They describe that
model in an authored world, not the game. They were read by running the extractors over
`Scenarios.run()` in a scratch copy. The tests check every field quoted here on constructed traces
with known answers, but they do not assert these model values, because forces.lua is tuned
elsewhere.

| Metric | Model | Band | Score |
| --- | --- | --- | --- |
| `S01.flat.accel.early_acceleration` | 2.531 m/s^2 | 2.242-2.740 | 1.000 |
| `S01.flat.brake.moving_brake_deceleration` | 3.543 m/s^2 | 3.359-4.105 | 1.000 |
| `S01.flat.brake.later_brake_deceleration` | 3.543 m/s^2 | 2.832-3.461 | 0.948 |
| `S05.full_charge_flick.airtime` | 0.883 s | 1.026-1.254 | 0.750 |
| `S05.full_charge_flick.apex_rise` | 0.996 m | 1.307-1.597 | 0.572 |
| `S05.r3_quick_hop.airtime` | 0.883 s | 1.2205-1.5695 | 0.517 |
| `S05.r3_quick_hop.apex_rise` | 0.996 m | 2.086-2.752 | 0.099 |

Seven metrics are scored, 459 are unscored, none is missing, and the lowest score is 0.099. Some
unscored readings, for context:

- Pedal: 3 m/s in 1.20 s, 2.53 m/s after 1 s, and 7.75 m/s after 4 s.
- Coast: deceleration about 1e-10 m/s^2, because the model has no rolling resistance or drag.
- Brake: 3.543 m/s^2 in every band, stopping in 8.74 m and 2.22 s from 7.90 m/s.
- Turns: radius 3.22 m at 3 m/s and 7.13 m at 6 m/s, so the radius grows 1.28 m per m/s.
  Lateral acceleration is 2.87 and 5.20 m/s^2, and left and right mirror exactly.
- Ramp: 93.1% and 96.3% of the entry speed is kept. At 6 m/s the bike spends 0.27 s with neither
  tyre supported, and its pitch changes at up to 2.35 rad/s.
- Hop landing: compression depth about 1.6e-9 m and COM dip about 7e-10 m. The rigid model's
  landings are fully plastic and there is no suspension. The 5 m/s ledge drop compresses 4.1 mm.
  Every S05 and S06 landing dips under 1 mm, so it settles at once: `rebounded` is true and
  `rebound_seconds` is 0.
- Manual at stick -0.75: lifts in 0.13 s and holds 1.88 s with no touchdown. Lift pitch is
  0.188 rad mean with 0.052 spread. At -0.70 the spread is 0.030, and the nose manual's is 0.020.
- Camera over an R3 hop at 4 m/s: 3.69-4.97 m from the body and one placement reset. The field of
  view runs from 73.1 to 76.8 degrees. The subject is at most 0.357 rad from the aim, and the
  smallest frame margin in a 16:9 frame is 0.301 rad. The aim turns at up to 0.205 rad/s. The eye
  acceleration stays under 10 m/s^2 until the landing, then peaks at 37.9 m/s^2 in the steps
  right after it. The cause was not investigated.

Read as model facts, not game facts:

- Pedal acceleration and moving-brake deceleration fall inside their bands.
- The constant, torque-limited brake is a little harder than the later native window.
- The hop is the largest gap. The model rises 0.996 m against 2.33-2.51 m for R3, and it gives R3
  and the full-charge flick the same hop. The observations separate them, at about 2.4 m against
  1.45 m.

## Tests

```powershell
& 'C:\Users\Jeffr\Desktop\reskate\build\bmx\parallel-tricks-presentation-proposal-v1\harness\build\Release\presentation_luau_tests.exe' 'C:\Users\Jeffr\Desktop\reskate\contrib\bmx-lab\bmx-plugin\plugin' rubric_metrics_tests
```

The run prints `cases=16 assertions=3933`. Two runs on the i7-9700K on 2026-10-25 took 1.9 s and
2.0 s. Earlier runs took up to 13 s, depending on what else the desktop was doing. Wall time is
advisory and not asserted.

| Case | What it checks |
| --- | --- |
| inert module and cited targets | Frozen module, targets, tolerance and bands, and the disclaimer. Each of the seven targets is on an extracted scenario, has finite observations, cites `file:line`, is not from a decoded-settings or decompiler note, has caveats, matches its metric's unit and uses the stated tolerance. The R3 rise and airtime targets cite the same three captures, and the airtime holds four readings from 1.36 to 1.43 s. Also the rubric category mapping. |
| score against a constructed target | Band edges, the linear falloff on both sides, a multi-value range, refusal of nan and inf, and refusal of malformed targets. |
| pedal curve | Constant 1 m/s^2: the early slope, band samples, mean, peak and plateau, time to 3 m/s, 6 m/s never reached, curve samples, distance. Then a saturating curve with a zero plateau. Then 2 m/s^2 for a second and 0.5 after: a peak of 2 apart from a mean of 0.8, and a plateau of 0.5. |
| brake and coast | Constant 3 m/s^2 to rest: every fit, band samples, stopping time and distance. Then a constant-speed coast. |
| turns | A 5 m circle at 3 m/s each way: radius, yaw rate, lateral acceleration, lean, the steady window, and release. A turn of more than pi whose steady window crosses the yaw wrap. Steps a hair over 1/60 s, where only the slack keeps 90 of them in the 1.5 s window. Growth with speed and mirror errors. |
| hop and landing | A constructed ballistic hop with a 10 mm penetration: apex height and time from the hop step, airtime, first contact, takeoff vertical and horizontal speed, compression, rebound timing, and support. |
| landing with a bounce, a pitch swing and no settle | Impact at 4 m/s after 5 m/s in the air, a 12 mm penetration, a 0.12 m/s bounce, a pitch swing of 0.13 rad, and a COM still rising 2 mm a step at the window end: compression, dip, bounce, swing, `rebounded` false, rebound time, and speed retained over the airborne speed. Then a COM still sinking (not rebounded), and a sub-millimetre dip (settled at once). |
| ledge drop | Front first, front-to-rear time, airborne time, drop speed and pitch. An 8 mm front penetration on landing: the landing window opens there and reads the compression, the 0.2 rad pitch swing, settling and support. |
| ramp on a constructed climb and roll-back | A 0.5 m rise at a known time, a pitch climb and a 0.1 rad snap in one step (6 rad/s), 15 steps with neither tyre supported beside 5 with one, and a roll-back at 3 m/s from 4 (0.75 retained). Then a climb that does not roll back. |
| manual | Two lifted runs with one touchdown: lift time, longest hold, fractions, pitch mean, spread, range and rate, the release drop, and the mirrored nose manual. Also a hold that never lifts. |
| segments and grind | Mode segments. Then the actual `grind_policy.lua`: one airborne step, a double-peg lock-on at 4 m/s, an authored 1.2 m/s^2 decay and a hop-out. Entry and exit speed, duration, decay and exit reason. Then a lock-on at 1 m/s that decays under the policy's 0.6 m/s stall speed: it stalls on record 21 and ends with `stall_end` 45 steps later, and the stalled records count in the grind's duration, exit speed and mean. |
| continuity | A consistent line, then a 1 m teleport, a pitch snap, a lean snap, a wrapped yaw step and a skipped invalid record. |
| camera on constructed views | Constant eye acceleration, subject angle, frame margin, a subject above the frame, and single-precision vector input. An aim turning at 0.8 rad/s about a fixed eye. A subject 45 degrees to the side is inside a 16:9 frame 70 degrees tall but outside a square one, and 40 degrees up is outside both. A view with field of view 0 is counted and left out of the frame test. |
| extraction agrees with sim_scenarios | One `Scenarios.run()`. Every extracted number is finite and frozen, and 129 of them match `sim_scenarios.lua`'s own metrics within 1e-9 relative: S01 accel, coast, brake, rest and restart; S02 turns; S04; S05 hops; S06; S07. Each S06 landing compression is within the run's deepest separation. Every valid step is continuous (residual at most 1e-9, no teleport), only the gap wall strike stops, and a second extraction is identical. |
| offline report | Sorted rows, each with the extracted value, its category and a unit. Exactly the seven targets are scored, the rest are `no_recorded_target`, and the summary keeps the lowest score. Missing metrics are named, `evaluate` equals the step-by-step path, and an owner target table replaces the recorded one. |
| camera driven by the simulator | The actual `camera_policy.lua` follows a simulated R3 hop: finite metrics, one placement reset, distances and field of view in range, and the hop lands. |

Perturbations were one-line changes to `rubric_metrics.lua`, each run against the suite in a copy
outside the repository and not kept. All 34 ran in one pass on 2026-10-25, and each failed the
suite where it should. An earlier version of this table claimed that removing the steady-window
slack failed, but it did not. Ninety float32 native steps come to just under 1.5 s, so the slack
never mattered. The turns case now has steps where it does.

| Change | Failed on |
| --- | --- |
| Hop airtime ends on the impact step | hop and landing, airtime |
| Steady-window slack removed | turns, steps within the slack |
| Score falloff not scaled by the midpoint | score, half the falloff |
| Yaw differences not wrapped | turns, wrapped headings |
| A target source without a line number | inert module, file:line |
| Continuity reads invalid records | continuity, the teleport count |
| Touchdowns counted on every grounded step | manual, one touchdown |
| Unscored reason renamed | offline report, unscored row |
| Early acceleration replaced by the mean | pedal, the early slope |
| One target given its own tolerance | inert module, stated tolerance |
| S07 always lifts the front | sim scenarios, S07 lift flags |
| Initial speed 1% high | sim scenarios, S04 return |
| Landing measured from the impact step | hop and landing, compression timing |
| Ramp return speed doubled | ramp, three quarters retained |
| Turn release lean read at the release's first record | sim scenarios, S02 release lean |
| Camera aim rate doubled | camera, 0.8 rad/s aim |
| Ramp unsupported time forced to 0 | ramp, neither tyre supported |
| Ramp pitch rate forced to 0 | ramp, the snap |
| Landing bounce sign flipped | landing, the bounce |
| Landing pitch swing forced to 0 | landing, the pitch swing |
| Lean step read from pitch | continuity, the lean snap |
| Apex time made absolute | hop and landing, apex time |
| Takeoff speed forced to 0 | hop and landing, takeoff speed |
| Grind ignores the `stalled` state | grind, stalled records in the grind |
| Ledge drop's landing replaced by `{}` | ledge drop, landing window |
| Speed retained over the impact record's speed | landing, speed retained |
| `rebounded` forced true | landing, still rising |
| Rebound timed from impact, not the low point | landing, still rising |
| Settle threshold 1 cm instead of 1 mm | hop and landing, rebound timing |
| Pedal peak replaced by the mean | pedal, the peak |
| Frame test back to a cone of the vertical field of view | camera, 45 degrees in 16:9 |
| Aspect ignored | camera, 45 degrees in 16:9 |
| Field of view 0 not skipped | camera, the camera's own view |
| R3 airtime without the 1.36 s reading | inert module, four airtimes |

## Not proven

- Every number comes from constructed traces. These are the authored heightfield driving the actual
  forces.lua and input.lua, constructed grind rows driving grind_policy.lua, and camera_policy.lua
  with no raycasts. None of it is in-game or native evidence.
- The comparisons pair different worlds: gravity, rig, clock, terrain, camera and controller
  context all differ. Each metric definition only approximates the native measurement it is set
  beside.
- No native ReSkate trace has been run through these extractors.
- The frame test rests on the SDK's own statement that the field of view is vertical, and on a
  16:9 viewport. Neither has been checked against what the game draws.
- The grind and camera metrics have no recorded target. Rider movement, falls and recovery, and
  equipment transitions have no metrics here.
- A higher offline score does not show better likeness. The judged footage and the owner's
  controller gate still decide that.

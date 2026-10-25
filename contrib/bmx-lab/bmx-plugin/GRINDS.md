# Grinds, pegs and stalls

`plugin/peg_geometry.lua` and `plugin/grind_policy.lua` are a pure, inactive
grind model. Observed contact rows go in. Only requests come out: a grind type,
transition events, a bail request, a hop-out request and an optional bounded
alignment torque. The model never sets a pose, position or velocity, never
snaps or teleports the bike, and never searches for a rail. The rail probe owns
every query and row; see RAIL_PROBE.md once that item lands.

Nothing here is wired into `main.lua`. `RIDE_COMPOSITION_QUALIFIED` and
`ACTIVATION_QUALIFIED` stay false. Grind names are new identifiers of our own,
not catalog IDs. Every threshold is authored tuning. None of them comes from
BMX Streets, EA data or `standalone/bmx-movement/reference`.

## Frame and peg geometry

Everything uses the authored bike frame from `bike_geometry.lua`: +Y up,
+Z forward, +X rider left. The frame origin is the measured centre of mass
minus the rotated `G.com`, which is the convention `bike_visual.lua` and
`bike_spawn.lua` already use. `Pegs.to_world(body, p)` and
`Pegs.to_local(body, p)` convert points.

The supplied FBX prototype and the native pack have no pegs, so these are our
own nominal 4.25 inch pegs. They are coaxial with `G.front_axle` and
`G.rear_axle` and multiplied by the same `G.scale` (0.77377), so rescaling the
bike moves them with the wheels.

| Value | Unscaled | Scaled (m) |
| --- | --- | --- |
| inner face from hub centre (`inner_offset`) | 0.065 | 0.0503 |
| peg length (`length`) | 0.14 | 0.1083 |
| outer end from hub centre (`outer_offset`) | 0.205 | 0.1586 |
| peg radius (`radius`) | 0.0245 | 0.0190 |
| axle height, axle ±Z (from bike_geometry) | 0.3399, ±0.6020 | 0.2630, ±0.4658 |

The four pegs are `front_left`, `front_right`, `rear_left` and `rear_right`,
always visited in that order. Each has `center`, `inner` and `outer` points,
an outward unit `axis` (+X for left pegs, -X for right pegs), `radius`,
`length`, `side` and `axle`. `Pegs.peg(name)` and `Pegs.names()` return copies.

`Pegs.relation(name, local_point)` places a bike-frame point against one peg:

- `axial` is the outward distance from the hub centre along the peg axis.
- `radial` is the distance from that axis, and `surface_offset` is `radial - radius`.
- `edge_offset` is how far the point lies past either end of the peg:
  `max(0, inner_offset - axial, axial - outer_offset)`. It is zero on the peg.

## Contact rows

The policy reads the row shape the rail probe produces and standalone
`grind.cpp` consumes. These field names are shared with rail-probe and must
not change:

```lua
row = {available, touching, point, normal, tangent, separation, surface_velocity, friction}
observation = {
    seconds = h, ground_support = false,       -- forces.lua's measured wheel ground support
    body = {orientation = {x,y,z,w}, center_of_mass = {...}, linear_velocity = {...}, angular_velocity = {...}},
    contacts = {pegs = {front_left = row, front_right = row, rear_left = row, rear_right = row},
                tires = {front = row, rear = row}},  -- tire-to-edge rows, not ground support
    input = {enabled = true, lean = 0, hop = false},  -- lean +1 is right, like the ride stick's +X
}
```

The checks match `solve_grind`:

- `point` must be finite and within 1e6.
- `surface_velocity` must be finite and within 1e5.
- `separation` must be finite.
- `friction` must be between 0 and 10.
- `normal` and `tangent` must normalise, and `|n·t| ≤ 1e-3`.

A row counts as a contact when `touching` is true and
`-max_penetration ≤ separation ≤ contact_gap` (0.03 m and 0.005 m, the same
window `solve_grind` uses). A touching row that penetrates deeper than that is
treated as malformed, wherever it is: it holds the step even when it is a row
a locked grind would otherwise leave out, such as the far-side peg.

**Unavailable is never clear.** A row that is missing, has `available=false`
or is malformed makes the whole step a hold, with issue `unavailable_contact`
or `invalid_contact`, because it could hide a contact that changes the grind:

- While idle, a hold disarms the airborne requirement. An unknown sample cannot
  prove the bike was in the air.
- While grinding, a hold freezes every timer except its own. After
  `max_unavailable_seconds` the grind ends with `contact_unavailable`. It never
  ends with `rail_end`, and a hold never produces an assist torque.

A clear row (`available=true, touching=false`) needs no geometry. Anything left
in its other fields is not read.

## Rail frame and angles

The rail rows are the touching pegs, or the touching tires when no peg
touches. The tangent `t` is the sign-aligned mean of their tangents, oriented
along the bike's forward axis. A row more than `rail_tangent_tolerance` away
from the first row is on another rail. Balance is judged against gravity
(forces.lua's default `{0,-9.8,0}`), so the rail's up axis is
`u = unit(world_up - t (world_up·t))` and its left axis is `l = u × t`. A
vertical rail has no such frame and is a hold.

With bike forward `f`, bike up `b`, contact point `c` (the mean of the rail
rows) and centre of mass `m`:

| Quantity | Definition | Sign |
| --- | --- | --- |
| `yaw` | `atan2(f·l, f·t)` | + nose toward the rail's left |
| `pitch` | `asin(f·u)` | + nose up, relative to the rail, so a down-rail double peg is 0 |
| `roll` | `atan2(-(b·l), b·u)` | + leaning right |
| `tilt` | `atan2(-((m-c)·l), (m-c)·u)` | + COM right of the rail |
| `speed` | `(v(c) - surface_velocity)·t` | along the rail |
| `closing` | the largest `-(v(p) - surface_velocity)·n` over the rail rows | + into the rail |
| step closing | the same, over every row in contact, before any row is refused or left out | + into the rail |
| `incline` | `asin(|t·world_up|)` | |

`toward = yaw × side_sign`, where `side_sign` is +1 for left pegs and -1 for
right pegs. It is positive when the front of the bike swings over the rail,
away from the side the bike approached on.

## Classifier

The classifier reads the peg set, the tire set, pitch, yaw and the speed along
the rail. Rules are applied top to bottom:

| Contacts | Condition | Grind |
| --- | --- | --- |
| pegs on both sides | | none (`mixed_peg_sides`) |
| any peg | `|speed| < stall_speed` | `peg_stall` |
| front and rear peg, one side | | `double_peg` |
| rear peg only | `pitch ≥ icepick_min_pitch` and front tire clear | `icepick` |
| rear peg only | `-toward ≥ smith_min_yaw` (front dropped on the approach side) | `smith` |
| rear peg only | `toward ≥ feeble_min_yaw`, or the front tire is on the rail | `feeble` |
| front peg only | `-pitch ≥ toothpick_min_pitch` and rear tire clear | `toothpick` |
| other peg sets | | none (`unclassified`) |
| tires only | `|speed| < stall_speed` | `tire_stall` |
| tires only, moving | | none (`unclassified`) |

`Grind.evaluate(observation, settings)` runs the classifier and the admission
checks on one observation, without history.

## Lock-on admission

A grind starts only when the bike comes from the air onto the rail. A clear,
fully available step without ground support arms admission. A step with
ground support disarms it, so air, then ground, then rolling onto a rail is
refused. The first contact after an armed step opens a window of `admission_seconds`, so
a rear peg that lands one step before the front peg can still become a double
peg. The closing speed checked is the worst step closing seen since the first
contact. It is recorded on every touching step in the window before any
refusal, so a slam cannot be hidden by waiting a step or behind a step that
was refused for another reason, such as an off-peg row.

Refusals are reported on `out.refusal` in this order:

1. `ground_supported`: the wheels are on the ground. This also disarms.
2. `bail_latched`: a bail is pending until `reset()`.
3. `not_from_air`: no armed airborne step came before.
4. `admission_window`: the window expired. Admission needs air again.
5. Per touching peg, in peg order:
   - `peg_radial_offset`: `|surface_offset| > peg_radial_tolerance`.
   - `peg_edge_offset`: `edge_offset > peg_edge_tolerance` (lateral peg-edge offset).
   - `rail_mismatch`: this row lies on a rail at a different angle from the first row.
     Two tire rows on edges at different angles are refused the same way.
6. `mixed_peg_sides`: pegs on both sides touch.
7. `rail_incline`: `incline > max_rail_incline`.
8. `separating`: the rail `closing < -max_opening_speed`, so every rail row is
   opening. One rail row still pressing in is not separating.
9. `closing_speed`: the worst step closing in the window is above
   `max_closing_speed`. `Grind.evaluate` uses that step's value.
10. `approach_yaw`: `|yaw| > approach_yaw_limit`. This applies to peg lock-ons
    only, since a tire stall on coping is often square to the edge.
11. `unclassified`: the classifier returned none.

On lock-on the state becomes `locked`, or `stalled` for `peg_stall` and
`tire_stall`. Exactly one `lock_on` event is emitted.

## While grinding

- **Rows.** While locked, a peg row that is off its peg, on another rail or on
  the far side from the grind's side is not that peg's contact and is left out.
  A tire stall reads only tire rows. A row left out this way is still checked
  for availability and depth: a malformed or unavailable row anywhere holds the
  step, because it could hide a contact that changes the grind.
- **Balance.** `effective = tilt + lean × lean_authority`. Measured roll enters
  through `tilt`, the measured contact-to-COM line. Upright on a left rail, the
  COM hangs about 0.158 rad right of it, so the rider leans into the rail.
  The grind fails when `|effective| > fail_angle` for `fail_seconds`, or at
  once when `|effective| > hard_fail_angle`. Failure produces
  `bail_request = {reason="balance_lost", side, grind}`, exits with `bail` and
  latches until `reset()`. Balance is reported from the lock-on step but judged
  only from the next step.
- **Type changes.** A different moving type on the same side must hold for
  `type_settle_seconds` before one `grind_changed` event fires. Any step that
  does not show that type restarts the wait. An unclassified step keeps the
  current type.
- **Stall.** When `|speed|` drops below `stall_speed`, the grind becomes
  `peg_stall` with one `stalled` event. It does not resume grinding, and it
  exits with `stall_end` after `stall_seconds`.

## Exits

Exits are checked in this order. Each produces one `exit` event and
`state="ended"` for that step; the controller is then idle and needs air again.

1. `cancelled` (input disabled) or `invalid_sample` (bad step, body or input).
2. `contact_unavailable`: held unavailable for `max_unavailable_seconds`.
3. `grounded`: wheel ground support while grinding.
4. `hop_out`: the hop input is pressed after it has been released at least once
   since lock-on. This sets `hop_request=true`, and the hop that carried the
   bike onto the rail cannot pop it straight off.
5. `rail_end`: every rail row is observed clear for `rail_end_seconds`.
6. `bail`: balance failure, as described above.
7. `stall_end`: the stall hold expired.

Timers compare with a 1e-6 s slack so whole native steps land on the authored
boundary. At most one transition happens per step.

## Outputs

`out` has these fields:

- `valid`, `state` (`idle`, `locked`, `stalled` or `ended`), `grind`, `side`
  and `classified` (this step's classifier result).
- `refusal`, `issue`, `exit_reason` and `events`.
- `bail_request`, `hop_request` and `balance` (`tilt`, `roll`, `lean`,
  `effective`, `normalized`, `failing_seconds`).
- `rail`, a diagnostic copy of the frame and angles.
- `assist_torque` and `assist_limited`.

The assist is off unless `assist_enabled=true`. It is a world-space torque
request that the force owner would add. It never writes a pose. It combines
two terms:

- About `u`: a PD term, stiffness and damping, that acts only outside the
  grind's yaw window. Inside it there is no yaw request at all. That
  window is ±`assist_yaw_deadband` for double peg, icepick and toothpick,
  `toward ∈ [feeble_min_yaw, approach_yaw_limit]` for feeble, and the mirror of
  that for smith. Stalls get no yaw term.
- About `t`: a PD term toward `effective = 0`, damped by the angular velocity
  about `t`.

The sum is capped at `assist_torque_limit` (120 N·m, far below forces.lua's
4000 N·m cap).

## Authored settings

`Grind.new(settings)` sanitises overrides. A non-finite value takes its
default, and every value is clamped to its bounds. `hard_fail_angle` is raised
to at least `fail_angle`, and the feeble and smith minimum yaws are lowered to
at most the approach limit. `settings()` and `state()` return copies.

| Setting | Default | Bounds |
| --- | --- | --- |
| approach_yaw_limit | 0.70 rad | 0.05–1.2 |
| max_closing_speed / max_opening_speed | 6 / 0.5 m/s | 0.5–20 / 0–5 |
| peg_edge_tolerance / peg_radial_tolerance | 0.025 / 0.03 m | 0–0.1 / 0.005–0.1 |
| contact_gap / max_penetration | 0.005 / 0.03 m | 0–0.05 / 0–0.1 |
| rail_tangent_tolerance / max_rail_incline | 0.35 / 1.0 rad | 0.02–0.8 / 0.1–1.4 |
| admission_seconds | 0.1 s | 0–0.5 |
| feeble_min_yaw / smith_min_yaw | 0.2 rad | 0.02–1 |
| icepick_min_pitch / toothpick_min_pitch | 0.6 rad | 0.2–1.5 |
| stall_speed / stall_seconds | 0.6 m/s / 0.75 s | 0.05–3 / 0.05–5 |
| rail_end_seconds / type_settle_seconds | 0.05 / 0.1 s | 0–0.5 |
| lean_authority / fail_angle / hard_fail_angle | 0.35 / 0.45 / 0.9 rad | 0–0.8 / 0.1–1.2 / 0.1–1.5 |
| fail_seconds / max_unavailable_seconds | 0.25 / 0.1 s | 0–2 / 0–1 |
| max_sample_seconds | 0.1 s | 0.001–0.25 |
| assist_yaw_deadband | 0.08 rad | 0–0.5 |
| assist yaw stiffness / damping | 60 N·m/rad / 8 N·m·s/rad | 0–1000 / 0–200 |
| assist roll stiffness / damping | 40 N·m/rad / 6 N·m·s/rad | 0–1000 / 0–200 |
| assist_torque_limit | 120 N·m | 0–400 |

## Tests and what is not proven

Run the tests with:

```
presentation_luau_tests.exe <plugin folder> grind_policy_tests
```

They cover:

- The peg geometry.
- Every grind type, including mirrored sides.
- Every refusal, with ±0.001 boundaries for yaw (rad), closing and opening
  (m/s), and edge and radial offset (m), plus ±0.01 rad around the tangent
  mismatch, for peg pairs and tire pairs.
- Ground support disarming an armed approach.
- The admission window and closing history, including a slam on a refused step,
  the worst of several rows on one step, and a tire slam beside a feeble peg.
- Unavailable, missing and malformed rows against clear rows, the hold
  resetting between separate holds, and a malformed far-side row holding.
- Balance through lean and through measured roll, plus the hard limit and the
  bail latch.
- Each exit, the rail-end gap resetting on contact, and type settling
  restarting when the change is interrupted.
- The assist: yaw stiffness and damping outside the window, no yaw request
  inside it or for either stall, roll stiffness and damping with their signs,
  and the cap.
- Settings sanitising and detached readback.
- Invalid samples.
- A deterministic scripted run whose observations are left unmodified.

All of these are constructed fixtures. Nothing has been checked in game:

- No rail-probe rows exist in game yet. Today's `probe_batch` hits carry no
  native normals unless `require_contact` is set.
- `ground_support` would come from forces.lua, which is not composed with this
  model.
- forces.lua's hop needs wheel ground support, so a grind `hop_request` has no
  physical realisation yet.
- No assist torque is applied anywhere.
- The peg collision shape does not exist in the native pack.
- The thresholds have not been tuned by riding.

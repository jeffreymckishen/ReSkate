# Manual balance policy

`plugin/manual_balance.lua` is an authored balance model for manuals (front wheel up, riding the
rear) and nose manuals (rear wheel up, riding the front). It turns the rider's stick, the measured
pitch and the per-wheel support into the `manual` / `nose_manual` force controls that `forces.lua`
already accepts. It is pure: it owns no SDK object, makes no `reskate.*` call and runs nothing on
require. Nothing in it comes from BMX Streets: the model, the constants and the reasoning below are
ours, and no value was taken from `standalone/bmx-movement/reference/*` or the Streets notes.

It is not wired into `main.lua` in this wave. `RIDE_COMPOSITION_QUALIFIED` and
`ACTIVATION_QUALIFIED` stay false, Mount stays denied, and the manifest is unchanged. Everything
below has been checked only against a constructed point-pitch model; none of it is in-game
evidence.

```lua
local Balance = require("./manual_balance")
local balance = Balance.new()            -- optional settings table, sanitized
local out = balance:step(sample, dt)     -- once per native physics step
force_controls.manual, force_controls.nose_manual = out.manual, out.nose_manual
```

## Inputs

`sample` is a plain table read once per step:

| Field | Meaning |
| --- | --- |
| `manual`, `nose_manual` | `input.lua` actions, each in [0, 1]. Values outside [0, 1] are refused, not clamped, because a negative manual usually means a sign error upstream. |
| `preload` | Optional `input.lua` hop charge in [0, 1], default 0. |
| `hop` | Optional boolean, true on the step a hop is requested (`actions.hop_pressed`). |
| `rear_neutral` | Optional boolean, default true. `ride_input_mapping` actions carry it. Pass it when wired, because `input.lua` reports a zero manual both at a centred stick and with the stick held in the hop zone. |
| `pitch`, `pitch_rate` | Measured pitch against the support plane, in radians and rad/s, nose-up positive. |
| `front_support`, `rear_support` | Measured support for each wheel. In `forces.lua`, `samples[1]` is the front wheel and `samples[2]` the rear. |
| `speed` | Forward speed in m/s, signed, with a magnitude of at most 100. Entry, the hold band and the stall read its magnitude, so riding backwards rolls like riding forwards. The kinds, the wheels and the pitch signs follow the bike, not the travel direction. |

`dt` is the native step. A non-finite step, a step of zero or less, or one longer than
`max_step_seconds` resets the model. So does a malformed sample.

`Balance.measure(orientation, angular_velocity, support_up)` computes `pitch` and `pitch_rate` from
a Hamilton XYZW body orientation, the world angular velocity and the support normal. It works in
the authored bike basis (+Y up, +Z forward, +X rider-left). It returns nil for a non-unit
orientation, a non-finite value or a degenerate frame.

## Outputs

Every step returns a fresh table:

- `manual`, `nose_manual`: force-control fractions in [0, 1]. `forces.lua` reads them as
  `pitch = nose_manual - manual` and tilts its balance target by `pitch * manual_pitch` radians
  (forces.lua:210-215). Only the active kind is ever nonzero. Both are 0 while idle, after an end
  and on any refused step.
- `state` (`idle`, `entering`, `balancing`, `ended`), `kind` (`manual`, `nose_manual`, `none`)
  and `armed`.
- `balance_point`, `lift` and `target`, in radians of lift for the active kind. `balance` is a
  presentation meter in [-1, 1]: -1 at the drop angle, 0 at the point, +1 at over-rotation.
- `event`: nil, or one table per transition carrying `name` (the new state), `from`, `to`,
  `kind`, `reason`, `bail_request` and a monotonic `sequence`.
- `end_reason` while ended; `issue` names a refusal (`neutral_required`, `unsupported`,
  `entry_speed_low`, `base_wheel_unsupported`, `conflicting_input`, `hop_pending`, `invalid_dt`,
  `invalid_sample`); `valid` is false only on a reset.
- `bail_request`: true only on the step a manual loops out or a nose manual goes over. It is a
  request. Nothing here bails the rider; another policy decides. `status().bail_pending` keeps it
  latched until the stick returns to neutral.
- `scope = "model_request_only"`, `realized = false`.

`settings()` and `status()` return copies, and events are new tables, so changing anything read
back cannot change the model. `configure(settings)` sanitizes and applies new settings, and
`cancel()` ends an active lift as `cancelled`. Both return the event, if any, and consume the arm.

## States and ends

```
idle -> entering -> balancing -> ended -> idle
           \____________________/
```

There is at most one transition per step, and each one emits exactly one event. These are the end
reasons:

| Reason | Kind | When |
| --- | --- | --- |
| `front_drop` | manual | Front support while balancing; or lift at or below `manual_drop`; or rocking onto the front with the rear unsupported; or the entry timing out. |
| `rear_drop` | nose manual | The same conditions, mirrored. |
| `loop_out` | manual | `max(measured lift, target) >= manual_loop_out`. Requests a bail. |
| `nose_over` | nose manual | `max(measured lift, target) >= nose_over`. Requests a bail. |
| `hop_out` | either | A hop request while entering or balancing. Not a bail. |
| `airborne` | either | Both wheels unsupported for `airborne_grace`. |
| `cancelled` | either | A release before the lift, `cancel()`, `configure()`, an invalid step or an invalid sample. |

Over-rotation is judged on the rider's target as well as the measured lift. `forces.lua` caps its
command at `manual_pitch`, so a rider who keeps leaning back may never be measured past the point
of no return. Inside the airborne grace the stick reads as air input, because `input.lua` zeroes
manuals off the ground. So the lift is held rather than treated as a release.

## Neutral rearm

Entry follows the rules in `tests.lua:108-118`:

- A new model refuses a held stick.
- Arming needs one neutral observation on the ground: both fractions at or below `neutral_input`,
  no preload, no hop, and `rear_neutral` true.
- A ground/air change consumes the arm. An airborne stick cannot claim a manual, a stick held
  through landing needs neutral, and neutral in the air does not arm the landing.
- Any attempt consumes the arm, whether it is accepted or refused (too slow, wrong wheel down, both
  sides at once, a hop pending). A refusal therefore cannot become a late entry while the stick
  stays held.
- A stick between `neutral_input` and `engage_input` is neither neutral nor an attempt, so it
  keeps the arm. `input.lua` ramps its manual output up from zero, and a slow pull passes through
  that range before it engages.
- After any end, the model stays `ended` until neutral, and only then returns to `idle`.

Pushing the stick to the other side during a lift releases the current kind. It never swaps
manual and nose manual mid-lift.

## The model

**Entry.** On entry, the target lift starts from the measured lift and ramps toward the balance
point at `entry_rate`. A pull below the sweet spot aims proportionally lower, so a shallow pull
cannot reach the entry window and times out as a drop. `balancing` begins once the ramp is done,
the lifted wheel is clear and the lift is within `entry_window` of the point. Releasing before
then cancels the attempt; `entry_seconds` without balancing ends it as a drop.

**Holding.** While balancing, the stick is a rate control on the target, not a position:

- Inside the sweet spot (`sweet_spot` plus or minus half of `sweet_spot_width`, narrowed at low
  speed) the stick adds nothing.
- Above it, the target climbs in proportion to how far past the band the stick is, reaching
  `climb_rate` at full stick.
- Below it, the target falls the same way, reaching `fall_rate` at a released stick.
- A tipping term, `instability * (target - balance_point)`, pushes the target further from the
  point. A lift left off-centre therefore needs small corrections, while one parked exactly on the
  point stays there.
- Below `stall_speed`, an extra fall grows linearly to `stall_fall_rate` at a standstill.
- The target never goes below level (zero lift).
- A hop charge (`preload > 0`) freezes the target, so the pop leaves from a held lift. While
  entering, a charge is not read as a release either.

**Command.** The command closes the loop on the measured lift:

```
command = target + lift_gain * (target - lift) + integral - rate_gain * lift_rate
```

The result is clamped to [0, `manual_pitch`] and divided by it. `forces.lua` holds whatever pitch
it is asked for, less the sag gravity causes, and the integral removes that sag. It integrates
only while the lifted wheel is clear, it stops whenever the command is saturated in the error's
direction, and it is bounded by `settle_limit`. Without the saturation stop, a lift that cannot
reach its target (a heavy rider, a kernel short of authority) would wind the integral to its
limit, and the lift would then overshoot when the bike could follow again. Inside the airborne
grace the command is computed without integrating, so it holds the last support step's lift.

## Tuning rationale

All values are authored for this kernel and this stick mapping. The constructed plant used below
is described in the next section.

| Setting | Default | Why |
| --- | --- | --- |
| `manual_pitch` | 0.4 rad | Must equal `forces.lua` `manual_pitch`, because the output is a fraction of it. A test asserts that the two defaults match. Change them together. |
| `neutral_input`, `engage_input` | 0.02, 0.08 | Just above `input.lua`'s exact zero, so float noise neither arms nor engages. |
| `sweet_spot`, `sweet_spot_width` | 0.5, 0.3 | The `input.lua` manual output spans stick deflection 0.22 to 0.72; full back is a hop charge. The band therefore covers roughly 0.40 to 0.55 of deflection, about 15% of the throw, centred on a half pull. |
| `manual_balance_point` | 0.22 rad (12.6°) | Holdable by the default kernel with headroom: the command needs room above the point to cancel sag before it saturates at 0.4. Sanitizing enforces at most 0.8 × `manual_pitch`. |
| `nose_balance_point` | 0.16 rad (9.2°) | Lower than the manual's. In the `force_tests` fixture the proposed centre of mass sits further behind the front contact (0.575 m) than ahead of the rear (0.475 m), so the same command holds less lift on the front wheel. |
| `manual_loop_out`, `nose_over` | 0.36, 0.30 rad | 0.14 rad above each point. In the plant, a deep pull (0.95) crosses in 0.3 s, a moderate over-pull (0.75) in 0.8 s, and a pull just over the band (0.66) in about 3.2 s. Holding a deep pull is punished quickly; a slight over-pull leaves time to correct. |
| `manual_drop`, `nose_drop` | 0.04, 0.03 rad | A small fallback, so a contact report that lags still ends the lift. |
| `entry_rate` | 1.4 rad/s | The target reaches the point in about 0.16 s, well before the kernel lifts the wheel. In the plant the kernel takes 0.47 to 0.57 s, dominated by `balance_damping` 360. |
| `entry_window` | 0.05 rad | Balancing starts within about 3° of the point. It is bounded below every drop angle. |
| `entry_seconds` | 1.0 s | Covers the slowest constructed plants that balance: about 0.75 s for a manual at a 0.4 m lever and 0.82 s for a nose manual at 0.475 m. A pull that never lifts ends as a drop. |
| `climb_rate`, `fall_rate` | 0.5, 0.6 rad/s | In the plant, a full release ends as a front drop (the lift falling through `manual_drop`) 0.48 s after a settled 2 s hold, or 0.53 s when released as balancing begins. That is quick, but rate-limited rather than a slam; the test bounds both at 0.4 to 0.6 s. Climbing is slower, so a loop-out comes from a held mistake. |
| `instability` | 0.6 /s | An e-folding time of 1.7 s: a 0.02 rad offset doubles in about 1.2 s. That needs occasional corrections without being twitchy at 60 Hz. It is zero at the point, so an in-band entry is stable. |
| `min_entry_speed`, `stall_speed`, `stall_fall_rate` | 1.0 m/s, 0.6 m/s, 0.5 rad/s | No manual from a standstill. A manual that bleeds to a crawl comes down in about 0.5 s. |
| `band_full_speed`, `band_min_scale` | 4 m/s, 0.5 | Below 4 m/s the band narrows linearly, down to half width at 2 m/s and below. A 0.62 pull holds at 4 m/s but loops out in 1.55 s at 1.2 m/s. |
| `lift_gain`, `rate_gain`, `settle_gain`, `settle_limit` | 2.0, 0.3 s, 3.0 /s, 0.3 rad | Chosen by a sweep over the plant with weight-shift levers of 0.1 to 0.4 m. Every lever in that range balances and stays within 0.005 rad of the point after 2.5 s. Peak overshoot is 0.07 rad at 0.1 m and 0.02 rad at the 0.3 m test lever. A 0.6 rad/s kick either way is rejected without an end for both kinds. A 1.2 rad/s kick is rejected for the manual but drops a nose manual, whose rear sits only 0.13 rad above its drop angle. |
| `airborne_grace` | 0.05 s | Three native steps. One- or two-step support flicker on rough ground is held, and any supported step resets the count, so repeated short gaps never add up to an end. A real takeoff ends on its fourth clear native step. The grace is inclusive: a gap of exactly 0.05 s ends the lift. |
| `max_step_seconds` | 0.05 s | Three native steps. Anything longer is a hitch and resets the model. |

Sanitizing keeps the order between related settings: neutral < engage, the sweet spot inside
(engage, 1), drop < point < over-rotation, an entry window below every drop, and an entry speed
no lower than the stall speed. Non-finite values fall back to the defaults and unknown keys are
dropped.

Each balance point is kept between 0.05 rad and 0.8 × `manual_pitch`. Below a `manual_pitch` of
0.0625 rad that ceiling is under 0.05, and the floor gives way to it: at the minimum
`manual_pitch` of 0.05 both points are 0.04 rad, with the drop at 0 and the entry window at most
0.03. `manual_pitch` itself is never raised, since the outputs are fractions of it.

## Constructed plant and what it shows

The tests drive the model with one rigid bike that pitches about whichever wheel stays down. It
uses the default `forces.lua` balance law (stiffness 1600, damping 360, torque limit 1200),
mass 106 and pitch inertia 26 from `forces.proposed_body()`, and gravity acting at an authored
weight-shifted centre of mass, 0.3 m from the pivot wheel and 0.9 m high. Contact is perfectly
plastic. Against that plant:

- Zero input leaves the plant exactly level for 600 steps.
- An in-band stick holds within 0.02 rad of the point from 2 s to 10 s, with no events after
  `balancing`.
- A deep stick emits `loop_out` or `nose_over` once.
- A release, a stall and front contact each end as a drop.
- A 0.6 rad/s kick during a manual is rejected without an end.
- A replay is bitwise identical.

Other cases use constructed samples without the plant. They pin the parts of the law that the
plant runs would not catch if they changed:

- The target rate for each stick depth and speed, matching the law in "Holding" to 1e-12, and
  the tipping term on the next step.
- The entry ramp, which starts from the measured lift and aims proportionally lower on a
  shallow pull.
- The integral, which grows at `settle_gain` times the error and stops once the command pins at
  0 or 1. With `lift_gain` at 0 the command never pins, and `settle_limit` bounds it in both
  directions.
- The airborne grace, which holds the command, survives 20 cycles of two clear steps and one
  supported step, and ends a gap of exactly `airborne_grace`.
- Every idle refusal, and the arm kept through a stick below engagement, including a slow pull
  through `input.lua`.
- The balance points at every `manual_pitch` from 0.05 to 0.6: each stays at or under
  0.8 × `manual_pitch` with its drop and over-rotation clearances, and a lift held at the point
  commands at most 0.8 of `manual_pitch`, never saturation.
- Reverse travel: entry, refusals, the hold band and the stall give the same outputs and state at
  -v as at +v, from a standstill to 100 m/s, and out-of-range reverse speeds are still refused.

A scratch mutation pass made 70 single changes to the module, each run against the suite. All
were caught except one: removing the context reset in `cancel()`. That change is equivalent,
because cancel already consumes the arm.

**Kernel finding, not fixed here.** With the centre of mass in the proposed rest geometry instead
(0.475 m ahead of the rear contact and 0.575 m behind the front, as in the `force_tests`
fixture), the default `manual_pitch` of 0.4 cannot hold either balance point:

- The manual stalls near 0.17 rad until the entry times out.
- The nose manual lifts the rear only about 0.03 rad.

With `manual_pitch` at 0.6, the most `forces.lua` accepts, set in both `forces.lua` and this
module, both kinds balance in that plant: the manual at 0.58 s and the nose manual at 0.77 s. A
working manual therefore needs either that extra authority or a kernel that models rider weight
shift toward the pivot wheel. That is a `forces.lua` tuning question for a later wave, and it can
only be settled in game. This module follows whatever `manual_pitch` is chosen.

## Wiring notes for a later wave

Feed the module these inputs:

- the `input.lua` grounded actions;
- `rear_neutral` from `ride_input_mapping`;
- `Balance.measure` on the measured body and support normal;
- per-wheel support from the same measured contact samples that `forces.lua` consumes;
- the native step.

While grounded, the module should own `force_controls.manual` and `nose_manual`, including the
zeros while idle; otherwise the raw stick still pitches the bike. The air-pitch mapping in
`ride_input_mapping` stays as it is in the air. `pump.lua` already inhibits ground pump while
`manual > 0.05`. `bail_request` needs a consumer.

## Tests and limits

```powershell
& 'C:\Users\Jeffr\Desktop\reskate\build\bmx\parallel-tricks-presentation-proposal-v1\harness\build\Release\presentation_luau_tests.exe' 'C:\Users\Jeffr\Desktop\reskate\contrib\bmx-lab\bmx-plugin\plugin' manual_balance_tests
```

`run(progress)` returns `{cases, assertions, native_actions = 0}` and calls `progress(cases,
assertions)` after each case. On the development machine the whole run, 28 cases, takes under
a second including process start. The standalone runner is not the Host, so the suite is not yet
registered in `plugin_tests.cpp`.

These things are unproven:

- How the real kernel and body respond: lift-off torque, sag, contact flicker and noise in the
  measured pitch.
- How the band, the rates and the tipping term feel on a controller.
- Whether any bail policy honours `bail_request`.
- Any in-game behaviour at all, since the module is not wired.

# Chase-camera policy

`plugin/camera_policy.lua` is a chase camera for a ridden bike. It turns the measured bike pose and
velocity into `{eye, target, fov}` that `reskate.camera.look` accepts. It is pure: it owns no SDK
object, makes no `reskate.*` call (no camera lease, `camera.look`, `camera.cycle` or
`world.raycast`) and runs nothing on require. The model and every constant here are ours. None of
it comes from BMX Streets.

It is not wired into `main.lua` in this wave. The manifest is unchanged, no camera lease is taken,
and `RIDE_COMPOSITION_QUALIFIED` and `ACTIVATION_QUALIFIED` stay false. It has been checked only
against authored motions and constructed walls in `plugin/camera_policy_tests.lua`. None of that
is in-game evidence of framing, occlusion or acceptance by the real camera.

```lua
local CameraPolicy = require("./camera_policy")
local rig = CameraPolicy.new()              -- optional tuning table, sanitized
local plan = rig:step(sample, seconds)      -- once per tick; nil, issue if refused
local hit = nil                             -- or the caller's raycast of plan.ray.from -> plan.ray.to
local view = rig:resolve(hit)               -- {eye, target, fov, ...}; nil, issue if refused
```

## What camera.look accepts

`camera_look` in `Extension/Plugins/plugin_api_world.cpp` (lines 195-221) takes two Luau vectors,
each component finite and within 100 km (`position_of`), with `eye - target` longer than 0.01 m
as floats. The field of view is 10 to 150 degrees, or 0 or none for the camera's own (`fov_at`).
When the view looks straight up or down, the function picks an arbitrary roll.

`CameraPolicy.valid_look(eye, target, fov)` repeats those checks on the float vectors. Every view
`resolve` returns has passed it. If a view could not pass, `resolve` returns `nil, issue` instead.
The policy also keeps a margin over those limits:

- Bike positions more than 99,900 m out on any axis are refused. The sanitized tuning cannot place
  an eye or target more than about 30 m from the bike.
- Eye and target are kept at least `min_separation` (0.3 m) apart horizontally, so the float
  rounding near 100 km cannot bring them within 1 cm.
- The view never pitches past `max_pitch` (1.2 rad), so it does not get near the straight-down
  case where the roll is arbitrary. The limit is held on the float vectors `camera.look` reads,
  because near 100 km their rounding alone can tip a view a few thousandths of a radian past it.
- The field of view is clamped to 10-150 degrees. The policy never asks for 0.

## Inputs

`sample` is a plain table:

| Field | Meaning |
| --- | --- |
| `position` | The measured body position: a Luau vector, `{x =, y =, z =}` or `{x, y, z}`. |
| `velocity` | The measured linear velocity in m/s, in the same forms. Up to 150 m/s. |
| `rotation` | The body quaternion `{x, y, z, w}` (array or named fields), its squared length within 1e-3 of 1 as `forces.lua` accepts. As in `forces.lua`, it turns the bike's local +Z (forward) into the world, and +Y is up. |
| `grounded` | Required boolean, the ride's own support decision. It has no default, because a forgotten field would quietly turn airborne framing off. |
| `teleport` | Optional boolean. True places the rig behind the bike again. |

`seconds` is the tick length, more than 0 and at most 1. A malformed sample or step is refused
with a named issue (`invalid_position`, `position_out_of_range`, `invalid_velocity`,
`invalid_rotation`, `invalid_grounded`, `invalid_teleport`, `invalid_sample`, `invalid_seconds`).
A refused step leaves the rig unchanged.

`rig:step` returns `{ray = {from, to}, reset, airborne}`. The ray runs from the pivot to
`clearance` past the free eye, as float vectors ready for a raycast. `rig:resolve(hit)` takes what
that raycast returned: a position, or nil when the way is clear or no ray was cast. A hit that is
not on the step's ray (`hit_off_ray`) or is not a position (`invalid_hit`) is refused, and the plan
stays pending so the caller can resolve it again. Each step resolves once (`no_plan` otherwise).
If a step is replaced before it is resolved, its reset is kept and the release time adds up.

`resolve` returns `{eye, target, fov, distance, pull, occluded, airborne, reset}`. `eye` and
`target` are Luau vectors. `distance` is the eye's distance along the arm. `pull` is the fraction
of the free arm in use. `rig:status()`, `rig:tuning()` and `rig:reset()` report the rig's state,
report its tuning and empty it.

## Behaviour

- **Pivot.** The pivot is the bike's horizontal position, `pivot_height` (1.1 m) above the body
  position. Horizontally it is locked to the bike, so the subject never lags and only the arm
  does. Vertically it follows a spring: 9 rad/s on the ground, which smooths bumps, and 3.5 rad/s
  in the air, which lets the rider rise in frame. The vertical lag is held to
  `vertical_lag_limit` (1 m), so a drop never loses the rider.
- **Follow distance and height.** The arm is `distance` (3 m) plus `distance_per_speed` (0.08 s) of
  speed, up to `max_distance` (4.6 m). The eye sits `height` (0.9 m) above the pivot. Both follow
  critically damped springs (3 and 3.5 rad/s), so a sudden speed or takeoff moves the camera
  smoothly and never overshoots.
- **Heading.** On the ground the arm follows the bike's facing, turned towards the line of travel
  as the speed along that line grows: none below 0.8 m/s, all of it by 3 m/s, on a smoothstep in
  between. Travel against the facing (rolling backwards, fakie) is read as that line reversed, so
  the arm stays behind the rider. Travel square to the facing has no speed along the line and
  leaves the facing. The heading goal is therefore continuous at every direction of travel, and
  sideways drift that changes sign while rolling backwards does not swing the arm between the two
  sides of a half turn. One result: after landing a 180 to fakie at speed, the arm swings round
  behind the rider on the ground. The heading spring runs at 3.2 rad/s and always turns the short
  way round.
- **Velocity look-ahead.** The aim leads the bike by 0.25 s of horizontal travel, at most 1.5 m, on
  a 4 rad/s spring. Look-ahead pointing back at the camera (rolling backwards) is dropped,
  so the aim never closes on the eye.
- **Airborne framing.** In the air the arm keeps the line of travel instead of the bike's facing,
  taken in whichever direction is nearer its own heading, so spins, flips and a backwards hop turn
  the rider inside a steady frame. With no line of travel (straight up), it holds its heading.
  The arm pulls back 0.8 m and rises 0.5 m. The heading spring softens to 1.5 rad/s. While
  falling, the aim drops ahead of the bike by 0.2 s of vertical speed, at most 1.2 m, so the
  landing comes into frame.
- **Field of view.** From `fov` (70 degrees) at a standstill to `fast_fov` (82 degrees) at
  `fov_full_speed` (12 m/s), on a smoothstep of speed, plus `air_fov` (3 degrees) in the air. It
  approaches that goal at 2.5/s.
- **Pull-in.** A hit snaps the eye in along the arm on the same tick, `clearance` (0.2 m) short of
  the hit, so a wall is never looked through. It goes no closer than `min_distance` (0.6 m); a wall
  nearer than that is not avoided. Clear space then eases the eye back out at `release_rate`
  (2/s), so the camera does not flick in and out along a fence. A hit at the ray's end, within the
  float rounding of the ray and the hit, is not an obstruction. That allowance is 1 mm plus 1.2e-7
  of the pivot's distance from the origin on each axis, about 4 cm at most near 100 km.
- **Reset.** The rig snaps behind the bike, in the rest framing for the current speed, on the first
  step, after `rig:reset()`, when `teleport` is true, after a gap longer than `reset_gap` (0.5 s),
  or when the bike is more than `reset_distance` (3 m) from where its measured velocity put it. A
  respawn or teleport therefore never sweeps the camera through the world.

All of these are tuning fields. `CameraPolicy.defaults()` lists them, and `CameraPolicy.new`
clamps each to a range that keeps the guarantees above. An unknown name or a non-number is an
error.

## Frame-rate independence

Each spring and each first-order approach is solved exactly for a goal that moves in a straight line
from the last tick's value to this tick's. Any tick length integrates the same curve, and ticks at
different rates differ only in how finely they sample the goal. The test rides two authored seconds
at 60, 120 and 144 Hz:

- a 10 m turn at 6 m/s, with a hop and a 360;
- an 8 m/s² launch away from a wall that starts inside the arm.

At 0.5 s and 1 s, eye and target agree within 1 cm, the field of view within 0.05 degrees and the
pull within 0.005. The worst differences measured were 7.2 mm for the eye, 1.5 mm for the target,
0.024 degrees and a pull of 0.0023. They come from the discrete airborne switch and from when the
pull-in snaps. Holding each goal for the whole tick instead gave up to 14 mm and 0.047 degrees.

Rates are also checked against fine Runge-Kutta solutions of the same spring and approach, for
the launch with no wall. At 60 and 120 Hz the arm is within 1e-9 m of its solution (the test allows
1e-6) and the field of view within 0.0003 degrees (it allows 0.003). Holding the goal instead
missed the field of view by 0.08 degrees at 60 Hz. The pull-in release is checked against its
exact exponential within 1e-9. A stepped (Euler) release was 0.0026 off it after a second.

## Later integration (not done here)

A later wave that wires this in needs these steps. Each one is a manifest or `main.lua` change for
that wave's review:

1. Add `"camera"` to `reskate-plugin.json` permissions, and `"world.raycast"` for pull-in. Without
   `"world.raycast"`, always call `rig:resolve(nil)`; the policy then never pulls in.
2. Join the camera height button's cycle with `reskate.camera.cycle(state)`. The plugin calls it
   every tick, because a step is held for only 300 ms: `"ready"` while a ride is live but the chase
   camera is off, `"active"` while it is on, and nil to leave the cycle. One plugin is in the cycle
   at a time; a refusal names the plugin that holds it. The button's steps come back through
   `reskate.on("camera_cycle", function(step) ... end)` as `"enter"` or `"leave"`
   (`plugin_host.cpp`), which turns the chase camera on or off.
3. While active, on each tick (`dt_ms / 1000` seconds): read the body sample the ride already
   measures and its grounded decision, call `rig:step`, cast `plan.ray.from` to `plan.ray.to`
   with `reskate.world.raycast` (one of the 64 rays a tick allows), call `rig:resolve(hit)`, and
   pass `view.eye, view.target, view.fov` to `reskate.camera.look`. The first `look` takes the
   plugin's camera lease. `look` returns a refusal while another plugin holds the camera or is
   following a player. `reskate.camera.held()` says whether this plugin's view is the one shown.
4. On an `"enter"` step, report `"active"` and start the ticks in step 3; the rig's first step
   places the camera behind the bike. On a `"leave"` step, call `reskate.camera.release()` and
   `rig:reset()`, then report `"ready"` again. `"leave"` means only that the button moved on from
   this camera to the high camera (`Engine/Game/Skater/first_person_cycle.h`), and the plugin stays
   in the cycle. On a bail or a teleport the ride did not make, call `rig:reset()` so the next view
   is placed, not swept there. Pass `teleport = true` on the first sample after any reposition the
   ride makes itself. Only when the ride ends or the plugin unloads, call
   `reskate.camera.release()` and `rig:reset()`, then `reskate.camera.cycle(nil)` to leave the
   cycle.

## Not proven

- Nothing here has run in the game. Framing, smoothness and feel are unjudged, and so is every
  default value.
- Whether `world.raycast` hits the plugin's own bike body or the rider, which would pull the eye
  to `min_distance` every tick. The ray starts at the pivot, inside the rider's envelope.
  Native actor and self-hit exclusion are still unresolved (see [README.md](README.md)).
- Whether `pivot_height` above the body position frames the rider. The body origin's height
  above the ground has not been measured for this purpose.
- Whether a `camera.look` every tick shows each pose on the frame it was asked for, and how the
  queued native camera path interacts with the game's own camera height cycle.
- An eye at `min_distance` can still be inside geometry nearer than that. The camera's near plane
  has not been checked.
- Whether the arm should swing round behind the rider after a 180 to fakie, or keep to the side
  of the line of travel it was on, has not been judged in play.

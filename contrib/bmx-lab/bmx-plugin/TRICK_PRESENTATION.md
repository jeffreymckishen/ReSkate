# Trick presentation stage

`plugin/trick_presentation.lua` turns one measured frame and the tracked trick adapter's model targets
into the eight authored bike part matrices. It is inactive: `main.lua` does not load it, nothing else
requires it, and the `RIDE_COMPOSITION_QUALIFIED` and `ACTIVATION_QUALIFIED` gates stay `false`. It
makes no `reskate.*` call and writes no entity. The visual owner (today `bike_spawn.lua`) remains the
only writer of part transforms.

It was promoted from the private proposal in `build/bmx/parallel-tricks-presentation-proposal-v1`
and rewritten for the tracked `plugin/trick_runtime.lua`, which is a different adapter from the
proposal's copy. `trick_runtime.lua`, `tricks.lua`, `motions.lua` and `bike_visual.lua` are unchanged.
`plugin/trick_runtime_tests.lua` is the first suite that drives the tracked adapter directly. It ports
the proposal's cases to the tracked contract. Its fixture follows the earlier pure adapter work in
`E:/RESKATE DEV/chat-2-reskate-bmx/lua-integration-parallel-v1/01-trick-runtime`.

## Calls

```lua
local Presentation = require("./trick_presentation")
local stage = Presentation.new(settings)               -- owns one trick_runtime.new(settings)
local stage = Presentation.over(runtime)               -- the same stage over an adapter already held
local out = stage:prepare(frame, contact, actions, base_pose)
local out = Presentation.present(frame, trick_result, base_pose)
stage:cancel(reason); stage:status()                  -- the adapter's own cancel and status
```

`frame`, `contact` and `actions` are the records `ride_runtime.lua` already gives
`trick_runtime:step`: the immutable Frame v1 (`frame_identity.lua`), the decoded contact packet bound
to that read, and the bound action snapshot. `base_pose` is the bike owner's articulation for the same
read:

```lua
base_pose = {physics_epoch = frame.physics_epoch,   -- this exact read, compared with rawequal
    steer = 0, front_wheel_phase = 0, rear_wheel_phase = 0, crank_phase = 0}  -- finite radians, |x| <= 10000
```

Nothing in the tracked tree produces a base pose yet. A missing one is refused, never assumed neutral.

`present` places a result some other owner already stepped. The Ride coordinator steps one adapter
per frame, so wiring should hand it that result rather than run a second, diverging trick model
through `stage:prepare`. `present` steps and cancels nothing, so it cannot give the ordering
guarantee below, and it cannot see the adapter's generation (see `duplicate_frame_cancelled`).

`over` builds the stage around an adapter the caller already holds, which must be a plain table with
`step`, `cancel` and `status`. A caller that owns the one adapter can then keep a single model and
still get the ordering guarantee, provided it steps that adapter only through `prepare`. Nothing
uses it that way yet; the tests use it to hand the stage an adapter whose results are broken.

## Result

A successful result has `valid = true`, `fresh = true`, `issue` (`"primed"` or `"none"`, from the
adapter), `serial`, `time`, and:

- `blueprints`: a copy of `bike_geometry.blueprints`: frame, fork, rear wheel, front wheel, cranks,
  handlebars, left pedal, right pedal. `matrices[i]` and `offsets[i]` are that part.
- `pose`: the eight `bike_visual` angles. Steer and wheel phases come from `base_pose` unchanged.
  `crank_phase` is the base phase plus `movement_crank_angle`. Barspin, tailwhip and the movement bike
  pitch and roll are the adapter's targets.
- `offsets`: each part's articulation in the authored bike frame, as 16 column-major numbers. A
  neutral pose gives the identity for every part (within 1e-12). World placement is
  `[measured rotation | root] * offset`.
- `matrices`: `bike_visual.from_sample(frame.sample, pose)`, the placement `bike_spawn` uses, so the
  measured COM minus the rotated authored COM is the root.
- `binding`: the adapter's private binding (body, physics epoch, lease, serial, time, seconds, source),
  so the owner can check the work still names its current read before placing it. The stage has
  already checked all of it against the frame (see `trick_frame_mismatch`).
- `trick`: the adapter's own step result, untouched. Its `model_state` and `model_events` are model
  policy only. They are not a native catch, grip, landing or score.

Everything a successful `prepare` returns is built for that call. Changing it reaches neither the
adapter nor a later result.

## Refusals

A refusal is `{valid = false, fresh, issue}` with no pose, offsets or matrices. There is no neutral
fallback.

| Issue | Cause | Adapter |
|---|---|---|
| `invalid_frame`, `invalid_sample`, `*_alias_mismatch`, ... | `Frame.copy` refused the frame (non-finite, non-unit or malformed) | cancelled by the stage |
| `visual_position_unavailable` | measured COM beyond 999000 m, which `bike_visual` could not place | cancelled by the stage |
| `base_pose_unavailable` | base pose missing, not this read's epoch, not plain, or an angle not finite or above 10000 | cancelled by the stage |
| any adapter issue (`physical_support_unqualified`, `invalid_actions`, `neutral_ground_prime_required`, `body_serial_gap`, `owner_or_focus_gate`, ...) | the adapter refused the frame | already cancelled itself |
| `duplicate_frame` | a new read of a measurement the adapter already consumed, under the same source and gates | kept running; nothing new to show, so the owner may keep what it placed |
| `duplicate_frame_cancelled` | the same, but the source identity or the gate facts changed (for example a new `source_epoch` on the same serial). The adapter cancels its model for that and still returns a valid `duplicate_frame`; `prepare` sees its generation move | already cancelled itself; the owner must drop the old trick pose, and the next frame needs a neutral ground prime |
| `trick_frame_mismatch`, `trick_result_unavailable` | the step result is malformed, not this read's, valid without targets but not the adapter's duplicate, or the step threw. "This read's" means the whole read: the result's public `serial` and `time`, and every field of the binding `trick_runtime` builds (body, physics epoch, lease, serial, time, seconds, the source lease and all eight scalar source fields), must equal the frame's, and a missing one refuses | cancelled by the stage (`present` cancels nothing) |
| `invalid_presentation`, `visual_transform_unavailable` | a composed angle or a `bike_visual` placement failed | cancelled by the stage. Defensive only: with the frame, position and base pose already checked and the adapter's targets bounded to 10000 rad, nothing reaches these, and no test does |

`stage:prepare` validates the frame, the visual position and the base pose before the adapter sees
the frame. A frame that cannot be presented therefore never advances the model, and cannot settle a
landing that the owner would never show. The adapter then sees the next frame as a serial gap and
needs a fresh neutral ground prime.

## Differences from the proposal

These follow from the tracked adapter. They were adapted to, not patched.

- The proposal's `update(body, sample, support, controls, base_pose)` is now
  `step(frame, contact, actions)`, which takes no base pose and returns `visual_targets` rather than a
  pose. The stage composes the pose itself and binds the base pose to `frame.physics_epoch` instead of
  the proposal's per-record `epoch`.
- The first accepted frame is `valid` with `issue = "primed"` and neutral targets. The proposal refused
  it as `"priming"`. The tracked prime also needs measured ground with both neutrals held
  (`neutral_ground_prime_required`).
- A duplicate read is `valid` with `issue = "duplicate_frame"` and no targets. The proposal refused it
  as `no_new_native_sample`. With the source unchanged the stage refuses it with the adapter's issue
  and the model keeps running.
- A duplicate read under a changed source is also a valid `duplicate_frame`, but the adapter has
  cancelled its model for the new source. The proposal refused a changed owner on a duplicate as
  `input_identity_changed`. The stage reports `duplicate_frame_cancelled` from the generation;
  `present` cannot and reports `duplicate_frame`.
- A duplicate read still enforces lost authority, as in the proposal: focus loss gives
  `owner_or_focus_gate` and an inactive action snapshot gives `invalid_actions`, and both cancel.
- The adapter keeps no per-body serial watermark. It compares a frame only with the last one, so
  after body B a retained grounded, neutral read of body A is a changed identity and a new valid
  `"primed"` result, and `stage:prepare` presents it. The proposal refused that replay as
  `stale_native_sample`. Guarding it needs the owner, or a change to the adapter, not this stage.
- A replay of the read before a refusal shows nothing but is not called stale: it is
  `body_serial_regressed` when the refused read anchored chronology (focus loss) and a target-free
  `duplicate_frame` when it did not (`invalid_actions`). The proposal refused both as
  `stale_native_sample`.
- Every serial gap is refused (`body_serial_gap`) and needs a new prime. The proposal accepted N+2
  observations whose time matched.
- Identity is the source namespace (lease, generation, user, sequence, source epoch, context
  generation) and the body handle. The proposal used an owner string and device number.
- The proposal's `policy_state` and `policy_event` become the adapter's projected `model_state` and
  `model_events`. Tallies, `bar_angle`, `air_seconds` and `spin_radians` are not projected, so the
  ported tests check events (`combo_landed`, `units`, `failure`) instead.
- The tracked adapter has no `reset()` or `policy_state()`. The stage offers `cancel` and `status`.
- Landing quality is computed by the adapter from the measured body, the pre-impact approach and the
  support normal, not passed in by the caller.

## Tests

```powershell
$run = 'build\bmx\parallel-tricks-presentation-proposal-v1\harness\build\Release\presentation_luau_tests.exe'
& $run contrib\bmx-lab\bmx-plugin\plugin trick_presentation_tests   # cases=18 assertions=866
& $run contrib\bmx-lab\bmx-plugin\plugin trick_runtime_tests        # cases=28 assertions=431
```

Both also pass in `contrib/bmx-lab/luau-runner` (`bmx_luau_tests.exe`), whose `*_tests.lua` glob
registers them as `bmx_lua.trick_presentation_tests` and `bmx_lua.trick_runtime_tests` on the next
build. `trick_presentation_tests` reuses the fixture `trick_runtime_tests` exports.

The last case in `trick_presentation_tests` covers the Codex review finding "Trick presentation
incomplete binding". Before the fix, a result was placed as long as its binding named this read's
body, physics epoch and serial, so a result kept from another input lease or source read of the same
physics step, or one with its lease, clock or source left out, still got matrices. That case changes
or removes each bound field, both on the result and on the frame, and checks that copied, frozen and
extra-metadata bindings still present. Three broken-adapter entries in the `over` case (another lease,
another observation serial, another time) check that `prepare` cancels for the same faults. On the
old module 46 checks failed: 37 in the new case and 9 in the three `over` entries.

The re-entrant cancel case in `trick_runtime_tests` patches `tricks.lua`'s module table and one
model object, so it needs both to stay unfrozen. It checks that first and restores the constructor
before any other check.

## Not proven

- Nothing here ran in the game. Every positive support fact in both suites is constructed. The actual
  `contact_runtime.lua` decoder still reports support unknown, so with it every `prepare` refuses with
  `physical_support_unqualified` and no matrix is produced. One case pins that.
- No owner places these matrices. `bike_spawn.lua` still places the neutral `from_sample(sample)`.
- No producer of the base pose exists, so real steer, wheel and crank phases are unknown.
- The part pivots and axes are `bike_geometry.lua`'s authored values. Only the matrix arithmetic is
  checked, not how the parts look on the bike in game.
- Timing at the native rate is a constructed 60 Hz case in `trick_runtime_tests`, not a measurement.
- The broken adapter results behind the stage's cancel path come from a test double handed in
  through `over`. The tracked adapter has not been seen to return one.
- A retained read of an earlier body is accepted as a new prime (see above). Whether a real owner
  can ever hand one back is not known.

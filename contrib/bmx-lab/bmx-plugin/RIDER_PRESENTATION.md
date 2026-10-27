# Rider presentation cues

`plugin/rider_presentation.lua` is a pure Luau port of three of this repo's own C++ presentation
policies, plus the step that turns their cues into rider offsets:

| Lua | C++ source |
| --- | --- |
| `step_posture` | `Engine/Game/BMX/bmx_rider_posture_presentation.h` (uphill counterpitch) |
| `step_crank`, `suspend_crank` | `Engine/Game/BMX/bmx_crank_presentation.h` (coasting crank leveling) |
| `step_landing`, `step_air_extension` | `Engine/Game/BMX/bmx_landing_presentation.h` (landing compression, air extension) |
| `rider_offsets` | `posture_targets` and the stance terms in `Extension/BMX/bmx_rider_pose.h` |
| `new()` presenter | the order and resets `Extension/BMX/bmx_chassis_ride.cpp` uses |

It is presentation only. Nothing in it changes a force, contact, input, trick phase or score, it
owns no SDK object, makes no `reskate.*` call and runs nothing on require. The constants are the
adaptation tuning written in those headers, not values recovered from BMX Streets, and nothing was
taken from game data or decompiled code.

It is not wired into `main.lua` in this wave. `RIDE_COMPOSITION_QUALIFIED` and
`ACTIVATION_QUALIFIED` stay false. `bike_visual.lua` and `rider_alignment.lua` are unchanged; this
module only produces values in the shapes they already read.

```lua
local Presentation = require("./rider_presentation")
local presenter = Presentation.new()
local out = presenter:step(sample)       -- once per accepted native physics step
-- out.articulation -> bike_visual.matrices(root, rotation, out.articulation)
-- out.rider        -> rider_alignment visual_targets.rider (hip_offset, torso_offset)
```

## The three cues

**Uphill counterpitch** (`step_posture(previous, sample)`). `sample` carries `seconds`, `serial`,
`supported` and `normal_available` (two booleans each), `normal` (two vectors) and `forward` (the
chassis forward axis). Only two actually supported wheels with measured unit normals, both with
`y > .7` and agreeing to within 15 degrees (dot at least cos 15 deg), make a measured plane. Its
grade is eased through a smoothstep from 3 to 20 degrees into `uphill` in [0, 1], slewed at 4 per
second. `counterpitch` targets `uphill` times the chassis elevation, capped at 25 degrees, slewed at
90 degrees per second. One-wheel support (a manual), a missing or disagreeing normal, and a measured
plane under 3 degrees can only fade the cues, never grow them, so a nose-up chassis or a takeoff
cannot manufacture an incline.

**Crank leveling** (`step_crank(previous, sample)`). `sample` carries `identity`, `raw_phase`,
`time`, `seconds`, `serial` and the `enabled`, `pedaling` and `reserved` flags. While coasting, the
displayed crank turns at most 4.5 rad/s to the nearest level stance, chosen once per coast so the
front foot does not swap. Pedaling and reserved (trick) cadence apply only the fresh raw increment,
so the display never snaps back to the raw angle. `ride_composer.lua` takes `pedaling` from the
force kernel's decision (FORCES.md), so with the pedal held at the top pedaling speed the crank
levels as it does for a released pedal. A new identity reseeds from its own raw phase;
`suspend_crank` lets the same bike resume at its displayed phase. The level angle is measured from
`bike_geometry.lua`'s left pedal spindle and bottom bracket, the geometry `bike_visual.lua` rotates.

**Landing compression** (`step_landing(previous, seconds, serial, supported, evidence)`) and **air
extension** (`step_air_extension(previous, seconds, airborne)`). Both are stateless; the caller
owns clock continuity. `evidence` carries the `bmx_landing_approach` Evidence fields this needs:
`valid`, `first_contact`, `post_available`, `contact_serial`, `post_closing_speed` and
`scoring_closing_speed`. The retained first-touch scoring speed makes a pulse of `speed / 6` only on
the first-touch sample itself; later support uses only the fresh post-contact closing speed, and
compression recovers at 4 per second. Air extension slews to 1 in the air and 0 on the ground at 5
per second. The Tracker that builds the evidence is not ported here.

## Refusals

Every policy refuses rather than clamps. Paused samples (`seconds == 0`) are valid and change
nothing. Refused results carry an `issue`; held ones carry `hold` (`paused` or `duplicate`).

| | posture | crank | landing / air |
| --- | --- | --- | --- |
| seconds outside 0..0.1, or not finite | refused | refused | refused, value 0 |
| zero or non-uint64 serial | refused | refused | refused (landing) |
| serial lower than the previous | refused (`serial_regressed`) | rebased, as in the C++ | caller's job |
| same serial again | held | held; at another time refused and suspended | caller's job |
| non-unit forward | refused | | |
| non-unit or missing normal | valid, fades only | | |
| malformed previous state | refused | refused | refused, value 0 |
| incomplete identity, raw phase above 1e6 | | refused | |
| contact serial in the future, a replayed first touch, support without evidence | | | refused, value 0 |

Serials are decimal uint64 strings, as `frame_identity.lua` carries them, compared exactly with
`lease_identity.lua`. A crank identity is `{body_handle, lease_handle}` compared by reference; the
per-read `physics_epoch` is left out because every measurement brings a new one.

## Mapping to the rig

`articulation(crank, raw_phase, base)` returns a full `bike_visual.neutral()` pose with
`crank_phase` set to the displayed phase, or to the raw phase before the crank is seeded, which is
what the C++ bridge shows.

`rider_offsets(cues, context)` returns `hip_offset` and `torso_offset` in bike space, in the shape
`rider_alignment.lua` adds to its neutral hip `(0, .9578988338, -.2877711058)` and chest
`(0, 1.476639786, .015)`:

- hip: `y = .04 air - .08 compression - .018 a`, `z = .010 a - .004 c`
- chest: `y = .04 air - .06 compression - .012 a`, `z = min(.075, .075 a + .015 c)`

with `a = .25 scale uphill (1 - .5 air) neutral upright (1 - .6 preload)` and
`c = scale compression neutral upright`. `neutral` is one minus the largest limb release or
movement phase, and `upright` fades the incline terms on a rolled or steep chassis. The vertical
landing and air terms apply with or without posture. `gaze_counterpitch` is returned too, but
`rider_alignment.lua` has no head channel yet, so nothing reads it. Preload, weight shift, pedal bob
and seat fitting belong to other cues and are not included.

The presenter steps the four policies in the bridge's order, returns the previous output for a
duplicate serial or a pause, clears posture, compression and air extension and suspends the crank
on a new owner, a rewound serial or a refused step, and drops only the posture cue when the posture
policy refuses.

It checks the clock and the raw crank phase before those shortcuts: a time that is not finite or is
negative, or a raw phase that is not finite or is beyond 1e6, refuses the whole sample and resets,
so neither a duplicate nor a pause can hold an older valid pose behind a bad reading. The same
serial at a time other than the one the crank consumed is refused as `duplicate_changed` rather
than held; a pause spends no clock, so a paused time need not match. A finite raw phase change on
an identical serial and time is still a duplicate, as in `step_crank`. When the crank step refuses,
the presenter resets and returns that issue before the air, landing and posture cues advance, so a
crank phase seeded earlier cannot make the composite valid.

## Parity with the C++

`plugin/rider_presentation_tests.lua` holds generated parity rows: 98 posture, 145 crank, 98
landing, 52 air extension and 31 offset samples. They come from compiling the C++ headers above in
a scratch program (not in the repository), driving them through the ride sequences of their C++
tests, extra edge segments, and seeded random stretches, and printing every input with the C++
result. The landing rows are evidence from the real `landing_approach::Tracker` over a constructed
fall, touch, settle, seam, jolt and hard landing. The Lua replays each row and must agree within
2e-6 (posture, which the C++ computes in float), 1e-7 rad (crank phase and target: the C++ level
angle uses float-rounded pedal geometry and sits 3e-8 rad from the Lua one) or 1e-6 (landing, air,
offsets). Hand-written cases port the assertions of
`bmx_crank_presentation_tests.cpp`, `bmx_landing_presentation_tests.cpp` and the uphill cases of
`bmx_rider_pose_tests.cpp`, and check that the outputs are accepted by `bike_visual.matrices` and
move `rider_alignment.solve`'s hip and chest targets. Three presenter cases drive a seeded presenter
with a NaN, infinite or negative time and a NaN, infinite or out-of-bound raw phase on fresh,
duplicate and paused samples, a duplicate serial at a changed time, and the valid pause, duplicate,
repeated raw phase, posture-only refusal and owner rebase paths that must keep working.

The optional C++ fixture `Extension/Plugins/Test/bmx_rider_presentation_parity_fixture.inc` was not
written in this wave; the parity rows live in the Lua tests instead.

```powershell
& 'build\bmx\parallel-tricks-presentation-proposal-v1\harness\build\Release\presentation_luau_tests.exe' 'contrib\bmx-lab\bmx-plugin\plugin' rider_presentation_tests
```

## Not proven

These are constructed samples. Nothing here shows that the cues look right in the game, that the
measured wheel normals the SDK reports are the ones the C++ bridge used, that a real Luau body
frame supplies these fields, or that the plugin VM's per-step budget fits the presenter. The
rows also share the C++ policies' assumptions, so a design fault in the C++ would be repeated here.

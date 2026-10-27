# Mounted rider pose v1

Status: in the tree but not wired in. It has not been run in the game. The gate
`local MOUNTED_POSE_QUALIFIED = false` appears exactly once, and nothing in the mod requires the module.

`plugin/mounted_pose.lua` computes the `reskate.skater.pose` table for each tick. That table puts the rider's hands on
the grips and the feet on the pedals as the cranks turn. It holds the pelvis over the saddle, leaning toward the bars.
It uses the joint places that upstream PR #365 added (merged as 8fe5d019; upstream/main 3d706383). Its only call is
`skater.pose`; everything else is pure maths.

This is the second revision. It answers the first review; [Review 1](#review-1-what-changed-and-why) lists each
finding and what was done about it.

## Files

| File | What it is |
|---|---|
| `plugin/mounted_pose.lua` | The module (pure `compose` and a `Poser` that sends) |
| `plugin/mounted_pose_tests.lua` | The suite: fakes, an emulation of the SDK's pose maths, and the cases |
| `plugin/bones.lua` | A byte-identical copy of `contrib/bmx-lab/stationary-anchor-observer/plugin/bones.lua` |

The suite needs `mounted_pose_qualified_fixture.lua`, which is `mounted_pose.lua` with its one gate turned on. Like
the ride and contact fixtures, it exists only in the luau-runner's staged test copy, never in the plugin; the runner
refuses it there.

## Using it

```lua
local MP = require("./mounted_pose")
local plan, why = MP.compose({
    bike = {center_of_mass = com, rotation = q},   -- or root = ...; exactly one of the two
    articulation = {crank_phase = phase, steer = s, barspin = 0, tailwhip = 0,
        movement_bike_pitch = 0, movement_bike_roll = 0,   -- bike_visual.lua's names; crank_phase is required
        release_left_hand = 0, release_right_hand = 0,     -- trick_runtime visual_targets' names, 0 to 1
        release_left_foot = 0, release_right_foot = 0,
        barspin_release = 0, tailwhip_release = 0},        -- bmx_rider_pose.h's frame names, 0 to 1
    rider = {crouch = 0.05, lean = 0.55, hip_offset = {0, 0, 0}},   -- optional
    skater_root = p,   -- optional: the skater's joint 1, for the 4 m check
}, options)

local poser = MP.new(reskate, options)   -- constructing it calls nothing
poser:mount(now)            -- probes skater.pose once, then starts blending in
poser:tick(now, input)      -- every tick: blend, compose, send
poser:refresh(now)          -- resends the last pose (no fresh frame), only within 0.3 s of when it was composed
poser:dismount(now)         -- blends out; at weight 0 it sends skater.pose(nil)
poser:stop()                -- ends the pose at once
```

- `bike` is the bike's world transform as the ride runtime has it. `center_of_mass` is the body's position, and
  `bike_visual.from_sample` uses it the same way: the root is the centre of mass minus the rotated `geometry.com`.
- `crank_phase` uses the same convention as `bike_visual.lua`: a rotation about bike +X through the bottom bracket. A
  positive value pedals forward (tested). `rider_presentation`'s crank presenter supplies it.
- A hand's release is the larger of `barspin_release` and its own `release_*_hand`; a foot's, of `tailwhip_release`
  and its own `release_*_foot`. The module may let go further on its own (see [Holds](#limits)).
- Options are `lean`, `crouch`, `follow_bars`, `forearm_twist_share`, `wrist_slope`, `foot_fore_aft`,
  `pin_shoulders`, `elbow_pole`, `knee_pole`, `seat_clearance`, `max_fit`, `min_knee`, `max_wrist_bend`,
  `barspin_hold`, `tailwhip_hold`, `hold_ramp`, `rig`, `geometry`, `head`, `shown`, `blend_in` and `blend_out`.
  Unknown names are refused, and so are values out of range. `pin_hands` and `pin_feet` are gone: a hand or foot is
  never given a position (see [Weight](#limits)). `MP.options` returns a frozen table.

## Frames

- **Bike frame.** +X is the rider's left, +Y up and +Z forward, as in `bike_geometry.lua`. Grips and pedals move the
  way `bike_visual.lua` moves its parts:
  - The bars turn about the steering axis by steer plus barspin.
  - The cranks turn about +X through the bottom bracket.
  - The pedals move with their spindles and turn only in a tailwhip.
  - The whole bike pitches, then rolls, about the steering pivot.

  The tests check the planned grips, spindles and pedal platforms against the matrices `bike_visual.matrices`
  produces, to within 1e-7 m, through steer, barspin, tailwhip, pitch and roll.
- **Seat frame.** The saddle as `bike_visual` draws the frame (part 1): the bike frame turned by the whole-bike pitch
  and roll about the steering pivot. The seat clamp and the knee floor work in it. It is that drawn frame while both
  hands hold the bars, and turns back toward the bike frame as they let go (a slerp by the hands' hold): a rider who
  lets go of the bars leaves the saddle, and the bike turns under them. A tailwhip is not in it, because a whip swings
  the saddle out from under the hips.
- **World.** Every place the module sends is `relative_to = "world"`, in the joint's parent frame, or (the upper arms
  only) in the hips' frame, joint 7. It never uses `"skater"`, because the skater's placement joint 1 is the game's
  own skater and is not tied to the bike entity.
- **Rider frame.** The bike frame, used for calibrations. `MP.rider_rotation(root_q, joint_q)` converts a standing
  `skater.joint` read into this frame. The rider frame is joint 1 turned a quarter turn about +Y, because in the r3
  capture joint 1 has +X forward, +Y up and +Z to the right.

## Joints, and why each one is placed the way it is

There are 13 joints, or 14 with the head option, against a cap of 128. Every key is a number from bones.lua, and the
head is 103, one of skater.pose's own names. Every joint has `keep_children = false`, because each placed joint's
children have to move with it: the spine and head with the hips, the fingers with a hand, the toes with a foot.
`keep_children = true` on the hips would leave the torso wherever the animation had it.

skater.pose blends each joint's own value in its parent's frame by the weight (`pose_place.cpp` `apply`). That fixes
which joints may be given a position. A joint given only a turn keeps its offset from its parent at every weight, so
it stays on the end of its parent. A joint given a position is pulled toward a place measured against a parent that
is itself only part blended, so below weight 1 it comes off its parent's end (the first revision's hands and feet did,
by up to 31 cm). So below the hips only the pinned shoulders have a position, and they have it in the hips' frame.

| Joint | id | Sends | relative_to | Why |
|---|---|---|---|---|
| hips | 7 | position and rotation | world | The pelvis is placed from the bike's transform. Its parent, joint 1, is the skater's own placement and is not tied to the bike. |
| right_arm / left_arm | 47 / 276 | position (the stance's shoulder) and rotation | the hips (7) | The upper arm is aimed at the IK elbow. The shoulder depends on the animated spine, so it is pinned where this stance puts it, and that keeps the arm chain exact at weight 1. In the hips' frame, part way through a blend it is off the animation's shoulder only by that share of the stance's difference (2.95 cm at weight 1, linear in the weight), not by how far the hips still have to go. The hips are posed first and are the arm's ancestor, so the order is fixed and has no circle. |
| right_fore_arm / left_fore_arm | 48 / 277 | rotation | parent | The elbow bends about the +Z it shares with the upper arm. Placing it in the parent frame keeps it a hinge at any weight. A share of the pronation is added about the forearm's own +X (`forearm_twist_share`, 0.5). |
| right_hand / left_hand | 49 / 278 | rotation (the grip's, capped at the wrist) | world | Turned, never placed. The wrist is wherever the forearm ends; at weight 1 that is the IK target: 5.5 cm back along the hand and the tube radius plus 4 mm off the palm, so the palm closes over the grip. |
| right_up_leg / left_up_leg | 8 / 341 | rotation | world | The thigh is aimed at the IK knee. The hip socket is the skeleton's own, under the placed hips, so no position is sent. |
| right_leg / left_leg | 9 / 342 | rotation | parent | A pure hinge about the shared +Z. |
| right_foot / left_foot | 10 / 343 | rotation (sole flat on the pedal) | world | Turned, never placed. The ankle is where the shin ends; at weight 1 that is `ankle_from_sole` (0.09 m) above the level pedal face. +Z points to the bike's left and +X slopes `foot_slope` below the pedal. |
| head (option) | 103 | rotation | world | Only from a calibrated rider-frame rotation (`head = {rotation, follow}`), because the head's own axes were not in the capture. Without it, the head rides with the torso. |

The chest follows the bars through the hips. The hips turn with the bike, lean forward by `lean` (0.55 rad), and turn
toward the bars by `follow_bars` × steer (0.35) about the bike's up axis. Barspin does not turn the chest.

## Measured joint conventions

All of these come from the r3 capture: `build/bmx/alignment-actual-v3/storage-after-stop.json`,
`observations.joints`. That is 14 joints read with `skater.joint` while the default skater stood still on MPR (state
504). The suite holds those rows and checks each convention against them.

- Every arm and leg joint points at its child along its own +X. The local direction has an x component above 0.9999.
- The elbow and knee bend about the +Z they share with the joint above. In local rotations, x and y are under 1e-3,
  and the angle is positive when the joint folds.
- The module's rule for the hinge is +Z = cross(the side the joint points out to, the limb's line), with +Y = +Z × +X.
  On the four measured limbs this rule gives the measured hinge axes (dot product above 0.999).
- The hips have +X up the spine, +Y forward and +Z to the left. They are within 6.6° of {.5, .5, .5, .5}, the rest
  frame `Extension/BMX/bmx_rider_pose.h` uses.
- Bone lengths:

  | Segment | Right (m) | Left (m) |
  |---|---|---|
  | Upper arm | .295377 | .295098 |
  | Forearm | .273984 | .273530 |
  | Thigh | .408592 | .408563 |
  | Shin | .438451 | .438445 |

- The leg roots are at ±.087 m along the hips' +Z. The shoulders are .5215 m up the hips' +X and ±.1728 m to the side:
  the mean of the two sides, mirrored, because the standing capture leaned a little.
- With the sole flat, the foot's +X is 29.1° (right) and 30.0° (left) below level. The module uses the mean, .516 rad.
- A hand's +Z points to the rider's right on both hands, so the left palm (+Z) and the right palm (-Z) both face inward.

Because no tip is placed, the hands and feet land on the grips and pedals only as well as these lengths match the
skeleton the game draws. On another avatar the `rig` option (lengths and roots, read with `skater.joint`) has to be
calibrated; otherwise the hands and feet miss by the length error rather than stretching to cover it.

The authored stance and contact numbers come from our own C++ for the same bike, which the Lua geometry does not
carry:

- Stance, from `bmx_rider_pose.h` `small_bike_stance`: hip height .9579 and hip z −.2878, elbow pole (±.12, −1.70,
  −.05), knee pole forward, wrist slope .30. The 50° knee bound is that file's (`knee<=50` is rejected).
- Free places, from `bmx_rider_pose.h` `palm_target` and `foot_target` (the same numbers `rider_alignment.lua` uses):
  a released hand 8 cm out, 12 cm up and 8 cm back of its unspun grip; a released foot parked at ±.279 m, .52 m above
  and .08 m behind the bottom bracket, its sole level with the bike.
- The wrist cap is `rider_alignment.lua`'s `maximum_tip_rotation` (0.8 rad).
- Contacts, from `Engine/Game/BMX/bmx_geometry.h`: the grip outward axes and radius, the pedal face centroids, an
  ankle height of .09, and a seat mesh top of .7026 m.

The saddle's midline and fore-and-aft span come from capsule 5 of `bike_geometry.capsules`. The collision envelope
lists its capsules in this order: wheels, frame, bars, saddle, then the seated rider.

## Limits

- **Joints.** The pose has 13 (14) joints. `MP.validate_pose` refuses more than 128, unknown ids, keys that are not
  numbers, and any `relative_to` other than world, parent, or the hips for a joint other than the hips. It runs before
  every send, a tick's or a refresh's.
- **Hold.** A pose holds for 0.3 s, so every tick sends again. A gap longer than 0.3 s since the last send is reported
  as `lapsed`. `refresh` resends the last pose only while it is less than 0.3 s old. After that it refuses and ends the
  pose, so it never holds a stale one.
- **Weight.** The weight is smoothstep of a blend that rises over `blend_in` (0.25 s) and falls over `blend_out`
  (0.2 s). At 0 the module sends `skater.pose(nil)` once. A remount partway out carries on from the current blend, so
  there is no jump. At every weight, through the blend in, the blend out and a refresh at part weight, every elbow,
  hand, knee and foot keeps its own offset from its parent (tested to 1e-6 m at weights 0, .1, .25, .5, .75, .9 and 1).
  The pinned shoulders move off the animation's by the weight times 2.95 cm.
- **Sent-joint cut.** Since 3d706383, other players get no joint further than 4 m from its parent. The hips' parent is
  joint 1, so if `skater_root` is given and is more than 4 m from the hips, the pose is refused.
- **Positions.** The bike is accepted within 99 km, so every place stays inside skater.pose's 100 km. Positions are
  sent as Luau vectors, which hold 32-bit floats: about 0.2 mm of precision at 2 km.
- **Reach.**
  - The two-bone IK never stretches a limb, and no hand or foot is placed, so nothing is stretched at any weight.
  - Out of reach, the pelvis moves into all four reach spheres by at most `max_fit` (0.15 m), then goes back over the
    saddle and above the knee floor.
  - A limb that still cannot reach is bent straight toward its target and ends short of it.
- **Saddle.** In the seat frame, the hips stay over the saddle's midline (within its half-width), inside its
  fore-and-aft span, and above a seat floor: the seat top plus half the pelvis width plus 0.03 m, which is 0.820 m.
  So while both hands hold the bars the hips are never below the floor of the saddle bike_visual draws, through any
  pitch or roll (tested against bike_visual's frame matrix at pitch ±.35 and ±.2, roll ±.3 and crouch to 0.3). A
  deeper crouch stops on the floor and is reported as `seat_limited`. Held bars carry the pelvis 0.75 of the grips'
  displacement in a pitch or roll, all of it with both feet off, scaled down as the hands let go, as
  `bmx_rider_pose.h` does.
- **Knees.** A held foot's knee folds no tighter than `min_knee` (50°): the pelvis rises along the seat's up until each
  hip socket is far enough from its ankle (the `proposed_hip_band` rule of `bmx_rider_pose.h`). It is reported as
  `knee_limited`. A released foot's share of that rise goes with its release, so a parked foot can tuck (its knee
  folds to about 35° at the parked place, as in the C++) without lifting the hips. With the default crouch of 0 the
  floor never acts; a crouch past about 0.04 m now stops at the top pedal, so the hips rise and fall with the crank
  (by up to 6 cm at a 0.1 m crouch and 10 cm at 0.138 m).
- **Wrists.** No hand turns further than `max_wrist_bend` (0.8 rad, 45.8°) off its forearm. A capped hand turns less
  than the grip asks, and the wrist moves so the palm stays on its point (a few rounds, because the forearm's line moves
  with the wrist). It is reported as `wrist_limited`. At the default steer limit of the ride, 0.4 rad, the outer
  wrist bends 42.7° and is not capped; from about 0.43 rad it is held at 45.8°.
- **Releases and holds.** A released hand goes to its free place beside the unspun grip and turns with the steer
  alone; a released foot parks off the pedals, stops cycling and lies level with the bike. Part released is part of
  the way, in place and in turn. A hand also lets go of a bar spun more than `barspin_hold` (0.3 rad) from where it
  started, and a foot of a pedal whipped more than `tailwhip_hold` (0.1 rad), smoothly over the next `hold_ramp`
  (0.3 rad), and takes hold again as the part comes back round (the angle is wrapped, so a whole turn is home). The
  trick model already releases within a tenth of a spin, but `trick_runtime.lua`'s `visual_targets` do not pass its
  bar and tail releases on, so without this a caller sending only the angles would cross the arms over a spun bar or
  chase a whipped pedal with straight legs. An X-up holds the spun bars by choice: `barspin_hold = math.pi`.

## Refusals

Each refusal returns `ok = false` and a reason. If something was being held, it is ended first with
`skater.pose(nil)`.

- **No API.** There is no API table, no `skater`, or `skater.pose` is not a function.
- **Older ReSkate.** On the first mount the module sends one probe: `skater.pose({[49] = {place = {}}}, 2)`.
  - PR #365 refuses it while reading the joints: "a joint's place has a position, a rotation or both".
  - An older skater.pose reads no place, so it refuses the weight instead: "a weight is 0 to 1".
  - A missing permission refuses it first, with the SDK's own message.

  None of these poses anything. Anything that accepts the probe is not trusted, and the module ends whatever it might
  hold.
- **Bad input.** Non-finite input is refused: the position, the rotation (non-unit within 1e-3, or non-finite), the
  crank phase or other angles, a release outside 0 to 1, crouch, lean and hip_offset. So are unknown fields and both
  or neither of root/center_of_mass. Time going backwards is refused too.
- **Unknown joints.** A rig override naming a joint outside the chains (for example "unknown joint left_tail in the
  rig's lengths") is refused, and so is a pose containing an id that is not the module's.
- **Changed after the fact.** A validated options table is frozen and cannot change. The poser checks its options
  again on every mount, tick and send, so a table put in their place is checked as if new and refused if it is bad.
  The plan a tick returns is the caller's to read; if it is changed, the refresh that would resend it refuses.
- **skater.pose itself.** If it returns false with a reason ("skater.pose refused: unavailable") or raises an error,
  the poser stays refused until the next `mount`.
- **The gate.** With `MOUNTED_POSE_QUALIFIED = false`, every Poser method returns `MP.NOT_QUALIFIED` without even
  reading the API table.

## What the pure run shows

CTest runs it as `bmx_lua.mounted_pose_tests`, against the runner's staged copy (the mod's modules byte for byte
plus the qualified fixtures). By hand:

```powershell
build\luau-runner\Release\bmx_luau_tests.exe --stage-qualified-ride contrib\bmx-lab\bmx-plugin\plugin <copy>
build\luau-runner\Release\bmx_luau_tests.exe <copy> mounted_pose_tests
```

Result when it was authored: **cases=27 assertions=47612, exit 0.**

- **The fakes enforce the real rules.** The fake `skater.pose` follows `plugin_api_world.cpp`'s order and messages:
  - joint keys: six names or a whole number from 0 to 394, never "7" or 7.5, never 0 or 1
  - entries must be tables, with scale from 0 to 10
  - a place needs a position or a rotation; positions are vectors within 100 km; rotations are 4 finite numbers with
    a length
  - `relative_to` forms: world, skater, a joint, and "moon" refused
  - keep_children must be a boolean; a joint posed twice is refused
  - 128 joints are accepted and 129 refused
  - the pose order, including placed relative to itself, to a joint hanging from it, and in a circle
  - the weight from 0 to 1, and `shown`

  It reproduces the order PR #365's own plugin test expects, `42 103 278 49`. There is also an older-API mode: no
  places and 64 joints.
- **The emulator matches upstream's tests.** An emulation of `pose_place.cpp` (apply, keep and put_back) and of
  `skater_animation.cpp`'s order of application passes the cases of upstream `pose_place_tests.cpp` before the rider is
  checked with it.
- **Geometry, through the fake and the emulator:**
  - **Hands.** Both palms land on bike_visual's grips to within 2 mm. That covers 4 bike transforms (identity, a
    MPR-like yaw, an uphill pitch about 2.7 km from the origin, a roll) and 4 articulations (steer ±, a held barspin
    of 1.3, whole-bike pitch and roll): 32 hand placements. The palms face down, and each hand's +Y runs along the tube.
  - **Feet.** The feet stand on the spindles at crank angles 0, π/2, π, 3π/2, 1.234, −2.5 and 31.7, and on
    bike_visual's drawn pedals (position and platform turn) through held tailwhips and whole-bike pitch and roll. They
    stay on the crank circle, the two cranks stay opposite, the soles stay flat on the pedals, and a positive phase
    pedals forward.
  - **Hips.** The hips stay over the saddle as the crouch rises from 0 to 0.13 m. A crouch into the seat stops on the
    floor, an offset outside the saddle is clamped, and through pitch and roll the hips stay above the drawn saddle.
    The carry is 0.75 of the grips' displacement (1 with both feet off, 0 with the hands off).
  - **Chest.** The chest turns by follow_bars × steer and leans by lean.
  - **Limbs.** Segments keep their lengths, and at every weight no elbow, hand, knee or foot leaves its parent's end.
    Over a full crank turn with steer, elbows stay between 65° and 125° and knees between 50° and 176°. No wrist bends
    past 45.8°; no held knee folds past 50° at any crouch.
  - **Releases.** Released hands and feet go to their free places; a barspin and a tailwhip swept over a whole turn in
    0.01 rad steps let go and take hold smoothly (each target moves less than 2 cm and 3.5 cm per step), never cross
    the arms and never leave a leg straight.
  - **Animation.** At weight 1 the result is the same for two different animations underneath.
  - **Reach.** The pelvis fit moves the hips 1 to 5 cm to reach a shortened leg. With max_fit too small, the leg is
    straight, short of its pedal, and still on the end of its shin.
- **Blending and hold.** Weights follow smoothstep rising and fall back to 0. `nil` is sent once, and nothing is sent
  while off. At 60 Hz the largest gap between sends is 1/60 s. A 0.35 s gap is reported as lapsed. refresh resends the
  same table, then ends a stale one, and refuses a table changed since it was sent.
- **Isolation.** A trapped reskate table records every key read. Over a full mount, ride, refresh, dismount, remount
  and stop, only `skater` and `skater.pose` are read and only `skater.pose` is called. The production module (gate
  false) reads nothing.
- **Negative controls.** While it was authored, 36 curated single-line mutations of the module were run against the
  suite, and each was caught (36/36). They are a chosen list, not every possible single-line change. They include:
  - the first revision's 14 that still apply (the 15th, pinning a stretched tip, has no line left to change): a
    reversed crank, a flipped palm side or hinge, keep_children true, the hips in the skater frame, no end on refusal,
    no probe, no 4 m check, crouch, seat floor, foot slope and follow_bars ignored, unsmoothed or unreported weights
  - the four the review showed were missed: tailwhip off the spindle, tailwhip off the platform, no hip carry, and no
    check before sending
  - a hand or foot given a position, the shoulder placed in the world, the seat frame unpitched or ignoring release,
    the carry ignoring release, releases and holds ignored, the hold not wrapped, the wrist cap off or leaving the
    wrist, the knee floor off or lifting for parked feet, options not frozen or not checked again, and the hips
    allowed relative to themselves

Numbers at the defaults (lean .55, crouch 0):

- **Elbows:** about 111° inside.
- **Knees:** 55° to 130° over a turn (top and bottom pedal).
- **Pronation:** each palm-down grip needs 89° of pronation, split half into the forearm and half into the wrist.
- **Hips:** 0.255 m above the seat top.
- **Shoulders:** against the standing animation, a pinned shoulder sits 2.95 cm from where the clavicle ends.
- **Wrists:** 12.9° at steer 0, 42.7° at 0.4, capped at 45.8° beyond.
- **Ordinary riding** (4 bikes, 36 crank angles, steer −0.4 to 0.4, pitch ±0.2, roll ±0.25: 4320 poses): every limb
  reaches; knees 50.0° to 174.4°; elbows 92.5° to 174.9° (a nose-down pitch lifts the seat, and with it the hips, so
  the arms straighten); hips 0.144 m to 0.365 m above the drawn seat; the pelvis fit at most 2.6 cm.

## What only the game can show

None of the following has been seen:

- **The rider on the bike.** Whether the posed skater looks seated on the bike at all. That means hands visibly
  closed on the grips (the fingers are left to the animation, and nothing curls them), and soles on the pedals rather
  than ankles at a proxy height. It also means whether the pelvis clears the saddle mesh. The seat floor is a proxy:
  the seat top plus half the pelvis plus 3 cm.
- **The skater's animation underneath.** Which animation the mounted skater plays: on foot, standing or a hidden
  board. That decides the spine, clavicles, neck and head the module leaves alone, and so the shoulder gap and the
  torso's real lean. 2.95 cm against the standing idle says nothing about the riding state.
- **The skeleton's lengths.** The hands and feet are not placed, so they land on the grips and pedals only as well as
  the rig's lengths match the drawn skeleton. On the default skater the capture says they do; on another avatar they
  have to be calibrated.
- **Skinning.** How the skin takes 89° of pronation split 50/50 between the forearm and the wrist (the game's twist
  helpers may handle it, or the wrist or elbow may candy-wrap). The same goes for the shoulder gap, for wrists at the
  45.8° cap, for knees at 50° and for the tucked 35° of a parked foot.
- **Releases.** Whether bmx_rider_pose.h's free places look right on this skeleton, and whether the module's own holds
  (0.3 rad of barspin, 0.1 rad of tailwhip) let go early enough at the speeds the trick model spins.
- **Players and plugins.** How other players see it. Joint 1 must stay within 4 m of the bike, which the module can
  check only when given `skater_root`. It is also unknown whether another plugin's skater.pose (one plugin at a time),
  or this mod's own `skater.reach`/`skater.carry` (applied after the pose), would override it.
- **The probe.** That the probe's refusal text in the live build is the one in upstream's source, and that the
  probe really poses nothing there.
- **Timing.** Frame timing: whether the bike transform and crank phase the runtime gives, one tick after physics, put
  the hands where the drawn grips are or leave them lagging at speed.

## Before it can be wired in

- The mod's `reskate-plugin.json` must list `"skater.animation"`; the current manifest does not.
- The ride runtime should pass `frame.body.center_of_mass` and `orientation`, the presented crank phase and steer, the
  trick targets' barspin, tailwhip, pitch and roll with their four `release_*` values, and `skater_root` (joint 1) if
  it reads it. If `trick_runtime` later passes the model's bar and tail releases, they go in `barspin_release` and
  `tailwhip_release`. It should call `mount` on mount and `tick` every tick, and call `dismount` or `stop` on the way
  out.
- `MOUNTED_POSE_QUALIFIED` stays false until a supervised game run has shown the pose.

## The board while riding

The posed rider is still, to the game, a skater on foot in state 504, and 504 is the state in which the skater
carries his board. Without more, the board is drawn in his hand all through the ride. `plugin/board_drop.lua` makes
him drop it as he mounts and gives it back when the ride ends. `plugin/board_drop_tests.lua` checks it against fakes
of `reskate.board` that keep the SDK's argument checks, messages, rate and one-owner rule.

- **What happens.** At the mount, `Dropper:drop(floor)` reads `board.bones()` once and keeps bones 1 and 2 for
  calibration. Then it calls `board.toss({2}, {velocity = (0, 0.6, 0), spin = (0, 1.5, 0), ground = floor +
  GROUND_OFFSET_M})`. Bone 2, the deck's mount, carries the deck, trucks and wheels, so the whole visible board leaves
  his hand as one piece. It rises about 2 cm, falls, lands flat pointing the way it was, slides a little and lies where
  he got on. When the ride ends, `Dropper:restore()` calls `board.clear()` once and the board is in his hand again.
- **Why a drop and not `board.hide`.** A board that falls and lies where he got on reads as put down, and the same
  board comes back to his hand at the end. A hidden one would vanish from his hand.
- **The ground.** A board in the hand does not tell where the floor is: a piece tossed from there hung at hand height
  (`contrib/board-break.md`). The drop uses the floor the spawn measured with its one ray: `bike_spawn.lua`
  `Runtime:floor_height()`, the height of the hit it accepted. Without a measured floor nothing is dropped. The piece
  lands when its frame, the board's place (bone 1), reaches `floor + GROUND_OFFSET_M`. `GROUND_OFFSET_M = 0` assumes
  bone 1 lies on the wheels' contact plane when the board lies flat, which is unproved. If the board floats d m above
  the floor, set -d; if it sinks d m into it, set +d. The recorded bone 2 says how far the deck's mount sits above
  bone 1.
- **Only this screen.** Only what this machine draws changes. The game still has the skater carrying the board, and
  toss is local: other players are sent the board as the game holds it, in his hand. Only `board.hide` with
  `others = true` filters the pose that is sent.
- **Unload.** The SDK clears what a plugin holds of the board when the plugin unloads or the Host stops it
  (`plugin_game_runtime.cpp` release), so a board left lying by a crash comes back then.
- **Another plugin.** One plugin holds the local board at a time. While another holds it, toss refuses ("<plugin>
  holds the board"), the board stays in his hand, nothing is cleared and the ride goes on. Toss also shares the SDK's
  four-a-second control rate with input leases and pulses; a refusal there is kept the same way.
- **Not in tracked Core yet.** Tracked Core does not mount the pose, so it does not drop the board either. The private
  trial packages wire the drop with the pose: once, right after the Poser's first accepted mount, and the restore
  wherever the pose ends (every stop and the unload). The manifest lists `board`.

None of this has been seen in the game: where the board lands, whether it lands on its wheels or upside down (that
follows how bone 1 is turned in the hand), whether bone 1 lies on the contact plane, and how the piece looks while the
rider rides away.

## Review 1: what changed and why

Every finding was checked with probes on a scratch copy before it was changed, and all of them held. Each is fixed;
two of them also carry a note on the fix.

1. **HIGH: hands and feet came loose during the blend.** Confirmed: with the suite's emulator (bike 2, crank 1.0,
   steer .2) the tips were .103/.229/.172/.307 m off their parents' ends at weight .5. Fixed by never giving a hand,
   foot, elbow or knee a position. At weight 1 the chain itself ends on the grip and pedal, so the pins added nothing
   there; below weight 1 they were what pulled the tips off. The review's other first choice, sending weight 1 and
   blending mod-side, would need the animated pose to blend from, and reading it takes `skater.joint` and the
   `skater.read` permission. The module calls only skater.pose, so that route was not taken. The finding also applies
   to the shoulders: at weight .5 a world-frame shoulder pin sat 9 to 24 cm off the end of its clavicle (both sides,
   two bikes). The shoulders are now pinned in the hips' frame, so the gap is the weight times 2.95 cm. Tested at seven
   weights, three bikes, three articulations, with and without the shoulder pin, and for a refresh at part weight.
2. **MEDIUM: the seat floor ignored pitch and roll.** Confirmed: at pitch .35, crouch .13 the hips were 6.1 cm below the
   drawn seat top in this probe (the review's own measure gave 3.2 cm), with `seat_limited` false. Fixed: the clamp
   and floor work in the seat frame. With the knee floor now also acting, the review's two cases end 0.224 m and
   0.208 m above the drawn seat; with the knee floor lowered out of the way they end on the 0.117 m floor with
   `seat_limited` true. Tested against bike_visual's frame matrix over 90 pitch, roll and crouch combinations on two
   bikes, plus the carry's 0.75 and 1, and a hands-off rider.
3. **MEDIUM: no hand or foot release and no cap on how far they turn.** Confirmed: barspin π crossed the arms with
   elbows at 173° and wrists at 64°; tailwhip π/2 straightened a knee to 178°; steer ±.9 bent the outer wrist 91°.
   Fixed with the release inputs, the module's own holds on spun bars and whipped pedals, and the wrist cap. At barspin
   π the hands are now let go (elbows 76°, wrists 25°); through a whole tailwhip every leg reaches; at steer ±.9 the
   wrist is held at 45.8° with the palm still on the grip. Steer itself is not limited: the cap covers it.
4. **LOW: knees went tighter than the C++ allows.** Confirmed: 49.8° from a crouch of 0.04 m, 36.5° at 0.138 m. Fixed
   with the 50° knee floor, tested over 36 crank angles at seven crouches, against the emulated skeleton too.
5. **LOW: test gaps.** All four mutations the review showed were missed are now caught, by tests that run the
   tailwhip, pitch and roll against bike_visual's pedal matrices, check the carry's value, and change a sent plan
   before a refresh (the check before sending now sits in the send that both tick and refresh use). On the wording:
   the first revision's DESIGN.md said that 15 single-line mutations were each caught, which was so, but did not say
   the 15 were a chosen list. This revision says so, and adds `run-mutations.sh` so the list can be rerun.
6. **LOW: the options cache could be bypassed.** Confirmed. Fixed: `MP.options` freezes what it returns, and the poser
   checks its options again on every mount, tick and send. Tested by trying to change a validated table and by
   swapping the poser's options for a bad table and then for a good one.

The review's verified points still hold, with one change to point 3. The upper arms are now placed relative to joint
7, the hips. That is an ancestor of each upper arm, not a joint that hangs from it, so upstream's `order` puts the hips
first and accepts it. `validate_pose` allows that one joint frame and refuses the hips relative to themselves.

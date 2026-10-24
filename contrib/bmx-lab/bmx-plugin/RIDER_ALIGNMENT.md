# Pure rider alignment targets

This inactive package includes the reviewed quaternion successor6B87. The solver
owns no SDK objects and supplies no actual rig observation or native pose writer.
Its default remains disabled. Core and Ride source gates also remain false;
package Mount denial and permissions are unchanged. See RIDE_RUNTIME.md for the
current dormant Core/Source composition and its separate evidence boundaries.

Interpolation now normalizes both operands and consumes checked normalized root
source/calibration quaternions. A zero angular cap preserves the normalized
measured source exactly; positive caps remain angular bounds for tolerated
near-unit inputs. This corrects the raw-dot bypass without changing input
tolerance, rejection policy, private Trick provenance, target-only outputs or
the authored bike basis. It does not calibrate a real native skeleton.

`plugin/rider_alignment.lua` implements `solve(frame, geometry, visual_or_private_trick_result, options)`,
`two_bone(root, target, pole_direction, upper_length, lower_length, fallback_direction)`,
and checked `to_world` / `to_local` transform helpers. It has no SDK access or
module dependencies. It defaults to `disabled` unless `options.enabled == true`.
All vectors are three-number arrays, quaternions Hamilton XYZW, distances meters.

The solver explicitly requires `options.bike_basis = "y_up_z_forward_x_left"`.
This declares the authored bike frame only. It makes no native-skeleton basis
assumption. The implementation retains the existing authored Y-up, +Z-forward,
+X-rider-left basis; a head-on image is not evidence for a 90-degree correction.

## Immutable Frame v1 and visual contract

The solver reads these `ride_runtime` Frame v1 fields without changing them:

```lua
frame = {
    valid = true, fresh = true,
    serial = "123",             -- canonical nonzero uint64 decimal string
    physics_epoch = epoch,       -- exact opaque identity, never reconstructed
    body_handle = body,
    body = {orientation = {x,y,z,w}, center_of_mass = {x,y,z}},
    gates = {focused = true, menu_open = false, falling = false}, -- optional measured gates
}
```

It consumes the copied arrays in `frame.body`, not native Luau vector values in
`frame.sample`. Missing/stale frames, non-unit/non-finite quaternions, unknown
basis, closed measured gates and malformed geometry return `unavailable`.

Optional visual input is a pure request bound to this exact measured frame:

```lua
visual = {
    valid = true, fresh = true,
    serial = frame.serial, physics_epoch = frame.physics_epoch,
    body_handle = frame.body_handle,
    articulation = {steer=0, barspin=0, tailwhip=0, crank_phase=0,
        movement_bike_pitch=0, movement_bike_roll=0},
    rider = {hip_offset={0,0,0}, torso_offset={0,0,0}, hip_yaw=0, hip_roll=0,
        release={left_arm=0,right_arm=0,left_leg=0,right_leg=0},
        local_targets={left_arm={x,y,z}}},
}
```

`local_targets` are authored free-limb targets in bike-root space; they are blended
with the bike anchor by the explicit 0..1 release amount. They can receive a
motion sampler's palm/ankle targets after a schema adapter. Catalog entries in
the current `motions.lua` provide presentation parameters, not measured native
bone samples.

The current source also accepts helper 2's flat `visual_targets` schema:
`scope="model_target_only"`, `barspin`, `tailwhip`, `movement_bike_pitch`,
`movement_bike_roll`, `movement_crank_angle`, `movement_id`, `phase`, `progress`,
`release_left_hand`, `release_right_hand`, `release_left_foot`,
`release_right_foot`, `bar_neutral`, `rear_neutral`,
`pose_provenance="authored_motions_policy"`, `realized=false`.
For a separately bound authored test DTO it requires `valid=true`, `fresh=true`,
an exact Frame serial and `physics_epoch` (or `epoch`), plus an exact body handle
if the visual DTO includes one. Conflicting epoch aliases reject the input.
Radians/releases/progress and boolean neutral flags are checked. Release values
remain continuous weights in 0..1; easing is preserved.
Flat `barspin` and `tailwhip` already contain helper 2's summed channels, so the
solver uses each once. Flat `movement_crank_angle` adds to the explicit
`options.base_articulation.crank_phase`; `base_articulation.steer` provides the
base steering channel. Missing base channels are authored zero requests.
An explicit invalid/inactive flat input returns `unavailable`; it cannot silently
become a neutral target. `movement_id` is metadata, not a native motion selector.
The actual helper 2 producer at
`E:/RESKATE DEV/chat-2-reskate-bmx/lua-integration-parallel-v1/01-trick-runtime/plugin/trick_runtime.lua`
puts identities in its **full private step result**, not in `visual_targets`.
The coordinator should pass that full result as the third `solve` argument:
`scope="model_adapter_only"`, `valid/fresh/advanced=true`, `realized=false`,
`serial/time`, `binding={body_handle,physics_epoch,lease_handle,serial,time,seconds,source}`,
and nested `visual_targets`. The solver validates all binding identities and
every source metadata field against Frame v1 before deliberately unwrapping the
targets. Its public snapshot/status strips opaque identities and is rejected.
The bare actual `visual_targets` object also rejects because it is unbound.
Duplicate, invalid or absent-target private results cannot authorize a fallback.
Only a literal nil third argument means no optional visual request; the
coordinator must not substitute an empty table for nil.

These compatibility edits were kept source-only during Root's normal Host HOLD,
then executed after explicit DONE. Both the existing generic Lua 5.4 runtime and
the authorized existing vendored Luau runner passed the full current suite.

No visual field is interpreted as ground/contact/ragdoll/upright proof. The
root is `COM - rotate(body.orientation, geometry.com)`. Bars rotate around the
authored oblique steering axis/pivot. Crank movement translates the independent
pedal platform instead of rotating its sole offset with the crank. Whole-bike
pitch then roll uses the same pivot/order as `bike_visual.lua`. Released limbs
have independent authored targets instead of chasing spinning bars or pedals.

`geometry` consumes existing `bike_geometry.lua` fields: `com`, `left_grip`,
`right_grip`, `steering_pivot`, `steering_axis`, `bottom_bracket`, `pedals`.
That module exports pedal spindles, so foot targets are explicitly marked
`spindle_proxy`. A caller can supply `pedal_contact_offsets = {left,right}`
(authored, level local offsets, each component within 0.3 m) to obtain
`authored_pedal_contact`. Neither marker claims shoe contact was observed.

## Optional calibrated rig and outputs

Without a rig, the result is `targets_only`, `pose_request = nil`, with detached
root/COM/hip/chest/limb target arrays. `native_alignment` is always false.
There is no inferred rig and no SDK call. The existing physics Frame contains
no measured native skeleton.

An explicit `options.rig` can exercise the pure articulation request path:

```lua
rig = {
    valid=true, fresh=true, serial=frame.serial,
    physics_epoch=frame.physics_epoch, body_handle=frame.body_handle,
    basis="calibrated", bike_to_root_rotation={x,y,z,w},
    root={position={x,y,z},rotation={x,y,z,w},parent_rotation={x,y,z,w}},
    chains={left_arm={
        parent_rotation={x,y,z,w}, bike_to_tip_rotation={x,y,z,w},
        contact_offset={x,y,z},
        upper={position={x,y,z},rotation={x,y,z,w}},
        middle={position={x,y,z},rotation={x,y,z,w}},
        tip={position={x,y,z},rotation={x,y,z,w}},
    }, right_arm=..., left_leg=..., right_leg=...},
}
```

Positions/rotations are coherent measured world transforms. `contact_offset`
is a calibrated tip-local meter offset from the wrist/ankle to its contact point,
already accounting for measured scale; it is not a guessed bind-unit offset.
`bike_to_root_rotation` and each `bike_to_tip_rotation` are explicit calibration,
not identities the module can guess. Parent rotations are actual measured world
rotations. All four chains are required, and each measured segment must be
0.04..1 m. The current SDK does not supply this whole coherent contract.

The `request_ready` path preserves measured segment lengths, projects impossible
targets into the two-bone reach annulus, handles coincident targets and degenerate
poles, retains residual contact error, and emits world plus absolute local
rotations. Root shift defaults to 0.18 m (maximum configurable 0.35 m). Root and
tip rotation changes default to 0.75 and 0.8 rad (maximum configurable pi).
These are per-request authored presentation bounds, not anatomical measurement
or a time/rate guarantee. The result does not claim joint-limit/anatomical
acceptance. A native consumer still needs admission, rate/ownership/lifecycle
guards and real bone/contact observation. `applied` and `contact_observed`
remain false even for a numerically exact request.

Opaque body/epoch identities are intentionally passed through for provenance;
all numeric/vector/quaternion target/request data is newly allocated. No mutable
solver state persists between calls. Inputs remain unchanged.

## Existing SDK and minimal general capability gap

Source inspection found existing general APIs in `Extension/Plugins/plugin_api_world.cpp`:

- `skater.joint` returns one joint's position, rotation, scale and parent under `skater.read`.
- `skater.pose` adds local rotation/offset overlays on animation for 0.3 s under `skater.animation`.
- `skater.reach` requests a single hand's world target under `skater.animation`.

Those are real APIs. This module deliberately calls none. Individual reads do
not carry a common pose serial/actor epoch tied to Frame v1, and the additive
pose API does not accept this solver's absolute local rotations unchanged.

The minimal general bridge is a coherent, epoch/serial-bound local-actor rig
snapshot (hierarchy, measured local/world transforms, scales, base pose and
explicit availability/basis) plus a bounded multi-joint override referencing
that snapshot, with declared absolute-versus-additive semantics and observed
apply/release receipt. Existing additive `skater.pose` could be reused only
after the exact base is exposed and absolute targets are converted to its
documented multiplication/offset semantics. The bridge should remain generic,
permission checked, owner scoped, and expired/restored by SDK lifecycle. BMX
target selection, contact/release decisions and IK remain in Lua. This handoff
does not invent an API name, permission, native call, bone identity or receipt.

## Validation and boundaries

The final composing artifact records fresh exact pure-Luau source/fixture/runner
pins and raw outputs. The quaternion aggregate includes the retained geometry
suite and eight focused cases; its retained suite is not counted a second time.
Pure target, normalization, reach and binding checks do not establish actual rig
sampling, bone identity, native pose application, consumer retirement, contacts,
fall recovery, mounting, performance or BMX Streets likeness.

The SDK/native rig basis, coherent current rig snapshot and absolute-pose bridge
with apply/retirement acknowledgments remain missing. A separate native body1
cleanup observation and a failed controller trial cannot supply those facts.
No pure or native component result is relabeled as this package's gameplay pass.
Root owns final source review, promotion and later native validation.

# BMX integration direction

Source review and isolated game tests: October 21, 2026, starting from checkpoint
`4ede3bc`. This records the integration direction and bounded acceptance evidence.
The process-bound receipts below define the tested scope.
The October 22 [private forearm checkpoint](judging/checkpoints/2026-10-22-forearm-repair.md)
records the pedaling repair, independent reviews, 93-test MSVC build and its
performance/native acceptance limits. The [matched Streets reference](bmx-streets-reference-2026-10-22.md)
supersedes historical method offsets for the currently installed reference.
The [controller recovery checkpoint](judging/checkpoints/2026-10-22-controller-recovery-gap.md)
separates the existing equipment/typed-GetUp evidence from the remaining normal
controller mapping test and its fresh observation window.

## Decision

Keep ReSkate's native world renderer, the existing Skate skeleton, the guarded
input/animation hooks and the Frostbite body adapter. Improve the controller and
rider presentation behind those boundaries. A standalone movement module can
supply controller logic and procedural posture; it does not replace the game's
world, contacts, animation lifecycle or equipment state machine.

Use the existing single-body native chassis as the ordinary offline baseline.
Continue the two-body bike/Spring adapter as an explicit private experiment.
Promote it only after its independent collision, command-consumption, presentation
and fall/recovery gates pass. Do not make a compile flag or successful fixture
silently select a different live physics backend.

The completed implementation adds a successor-body receipt check before the
ordinary chassis reuses predicted controller state. A queued command must have
exactly one completed native application and the expected hop count. Missing,
partial or discontinuous consumption stops the ride.

It also integrates neutral-relative procedural hip/chest motion into the paired
pose solver. `RESKATE_BMX_COUPLED_POSTURE=1` selects this presentation only inside
the existing explicitly selected private coupled trial. It requires acknowledged
logical state, the current actual successor pair, completed neutral calibration
and unchanged IK/anatomy checks. Normal backend adoption remains closed; this
flag does not activate paired physics or change ordinary riding presentation.

## Options compared

| Approach | What already exists | Decision and remaining cost |
|---|---|---|
| Single-body native chassis | `Extension/BMX/bmx_native_chassis.cpp` owns a real native dynamic body; `bmx_chassis_ride.cpp` turns measured state and wheel queries into forces. `bmx_world.cpp` places articulated native props. The native on-foot actor follows the chassis. | Retain as ordinary baseline. This is already native dynamics, but has an approximate combined bike/rider body, query-driven wheels and a separate rider-follow path. Equipment round trips, terrain/contact response and rendered rider quality still need work. |
| Paired native bike/Spring with standalone controller | `bmx_native_coupled.inc`, `bmx_standalone_coupled.h` and `bmx_coupled_ride.cpp` adapt actual native bodies to the standalone controller and await producer receipts. `bmx_coupled_avatar_entry.inc` calibrates and publishes the real Spring-to-avatar mapping. | Best existing experiment for independent rider mass/rotation. Keep its bounded private trial. Normal collision/force adoption is deliberately closed, and momentum transfer to the native falling rider remains unproved. |
| Replace rendering, skeleton and world with the standalone demo | The independent demo supplies a simple host and its own presentation. | No current benefit for adding BMX inside Skate. This would discard the existing native integration and require a new world/render/avatar bridge. Reuse its portable controller and procedural pose functions instead. |
| Create a complete game-native BMX actor/controller | Existing source exposes guarded skater, prop and physics contracts. | No complete BMX vehicle actor, wheel/joint backend or animation state machine is established by this source review. Investigate a specific missing native contract when necessary; do not plan around an assumed vehicle API. |

## Important distinctions in the current code

- The paired adapter's intermediate `rider_mode = none` in `bmx_coupled_ride.cpp`
  is intentional. `coupled_avatar_entry::bind_active` enables the riding pose only
  after current pair, calibration, motion-lease and previous-render checks. The
  paired rider binding exists; its remaining acceptance work must not be described
  as a wholly missing rider.
- `collision_adoption_ready()` in `bmx_native_coupled.inc` is hard false. Ordinary
  `activate` and `submit` reject. `bmx_native_coupled_trial.inc` supplies a separate
  explicitly selected ten-second controller trial. A successful private trial
  does not establish normal backend adoption.
- On a paired bail, `bmx_coupled_ride.cpp` parks both roles because Spring-to-native
  ragdoll momentum transfer is unproved. This is a known lifecycle boundary.
- The ordinary chassis wheel adapter assumes zero moving-surface velocity and
  accepts only the calibrated native 60 Hz timing. Its capsules are coarse impact
  backup, not spinning native wheel bodies or a full bike collision mesh.
- Native prop placement receipts and CPU bone readbacks do not prove final GPU
  consumption. The recorded descent hand/grip mismatch remains a render-timing
  investigation; a guessed grip offset would not address the established gap.
- The coupled Spring pose has a calibrated neutral hip/chest relationship. Merely
  selecting observed trick cues cannot provide ordinary preload articulation.
  The existing observed adapter uses semantic landmark cues, not a complete
  transfer of every source skeleton channel.

## Source and build identity

The inspected `build/vs2022-x64/CMakeCache.txt` enables both developer adapter
features and selects this immutable source cut:

`C:/Users/Jeffr/Desktop/reskate/build/bmx/standalone-msvc-integration32/source`

Its pins are in
`build/bmx/standalone-msvc-integration32/source-pins.json`; its change list from
cut 31 is in `changes-from31.json`. Editing `standalone/bmx-movement/` does not
automatically change a runtime built against this cached cut. Keep using the same
MSVC toolchain as ReSkate and record the selected source cut with each build.

Several overview documents retain different historical stopping points:
`native-prototype.md` begins with attempt 30, `README.md` with attempt 21, while
later numbered build artifacts and paired trials exist under `build/bmx/`.
Read those records as history. Before a new comparison, bind the current source,
selected movement cut, executable/DLL hashes and actual launched profile to its
own receipt. Do not infer current acceptance from the largest test or run number.

## Next acceptance milestones

1. **Repeatable equipment round trip.** Exercise ordinary riding, stop, LB+Y to
   native skateboard, release, then LB+Y back to BMX in the same isolated process.
   The committed `bmx_human_native_return.h` and runtime reverse path already
   provide an original-input dismount experiment; verify this before adding more
   selector writes. Preserve original-source identity, real press/release, the
   settled native offboard gate, collision readiness and cancellation. Require
   sustained visible board stance and BMX remount. Runs 281 and 284 now cover
   repeated virtual-controller round trips, console interruption and a fresh
   explicit retry. Focus loss and physical-controller acceptance remain separate.
2. **Paired command and observation continuity.** In the existing private trial,
   account for each accepted bike/rider command, producer receipt and genuine
   successor body observation. Distinguish duplicate reads, missing producer
   consumption and skipped native epochs. Do not advance logical controller
   state from a prediction or waive a failed receipt to keep the trial running.
3. **Bounded paired rider articulation.** After neutral calibration, compute
   procedural animated-minus-neutral hip/chest deltas in the same current actual
   bike/Spring frame. Use acknowledged logical state and its exact successor
   epoch, native rig dimensions, fixed current grip/pedal anchors and existing
   candidate strengths/anatomy checks. Preserve exact neutral and opt-out
   behavior. Keep the experiment separately selected; it changes presentation,
   not COM, inertia, forces or backend adoption. Test neutral, preload, intended
   release targets and stale/foreign observations before a recorded native
   preload/trick comparison. A passed pure fixture is not rendered acceptance.
4. **Rendered contact and ride quality.** Compare continuous footage of neutral,
   preload, steering, hop, ramp ascent/descent, landing and the equipment round
   trip on the same identified build. Join actual bike/rider publications to
   image measurements before changing anchor offsets. Retain the existing
   independent judging rubric and human handling feedback; report still-image
   and full-motion evidence separately.
5. **Backend promotion and release.** Prove paired self/world collision behavior,
   interruption/teardown ownership, falls and recovery, broader static terrain
   and moving-support policy before ordinary adoption. Then validate clean local
   bike-pack installation. Multiplayer and replay need their own protocols and
   acceptance work; they are not implied by offline riding.

## Completed validation

The latest MSVC Release build passes **87/87 CTest fixtures** (10.75 seconds),
including 12 fake-only tests for the new single-leg controller wrapper. Current
runtime SHA-256:
`8F880DE8E36D452AA3AC4B245E5344186F34D2D9D816693A1F0EA4F5542A739E`.
See the [CTest log](../../build/bmx/switch-reliability281/ctest-console.log).
Source comparison after the native tests matches all 22 supplemental workspace
files, 43 selected movement files and three build-configuration files against
the prelaunch snapshot; documentation is updated after that comparison. See
[source verification](../../build/bmx/integration-review-20261021/post-switch-and-fall-source-check.json).

### Equipment switching

Run 280 exposed a test-driver discovery race: each driver invocation reconnects
its virtual controller, while the SDK discovers disconnected XInput slots at
one-second intervals. An immediate chord can reach the original game before the
SDK has discovered the pad. This is evidence about hotplug timing; it does not
establish a stale equipment-state defect in the normal connected-pad path.

`Bmx-SwitchLeg.py` pins the unchanged guarded driver and holds the connected pad
neutral for two seconds before publishing its ready gate. It sends one chord,
retains the report deadline and owner/foreground guards, and always releases and
disconnects. The neutral wait allows discovery; only native receipts establish
the switch outcome. Each direction starts separately after the previous native
completion, so the reverse cannot cancel the forward settling period.

**Run 281 passes three BMX → native skateboard → BMX round trips** in one game
process. Each forward reaches native state 100 and holds it for 2.2667 native
seconds with BMX publication withdrawn and cleanup counters stable. Each reverse
reaches native offboard state 504 and completes a natural BMX mount, with tokens
2, 3 and 4. All six controller legs complete 301 reports and release/disconnect.
Its runtime is `075C6FF4858AC045273F419763CCC7B2392247F309F4A109437424A79FB465E0`;
the later rebuild adds CTest registration without changing the riding/switch code.
See the [six-leg summary](../../build/bmx/switch-reliability281/switch-summary.json)
and [continuous recording](../../build/bmx/switch-reliability281/three-roundtrips.mp4).

**Run 284 covers console interruption and fresh recovery** on the current
runtime. The console opens during native state 100 after only 0.3833 seconds of
qualifying dwell. Generation 1 aborts, reports no handoff completion, and performs
no automatic retry. The actual skateboard stays equipped, so the cancellation
notice now accurately says the switch was canceled instead of claiming the rider
is on foot. After an idle observation interval, one fresh LB+Y produces generation
2, native state 504 and natural BMX mount token 2. See the
[cancellation receipt](../../build/bmx/switch-interruption284/canceled-forward-native.json),
[reverse receipt](../../build/bmx/switch-interruption284/explicit-reverse-native.json)
and [continuous recording](../../build/bmx/switch-interruption284/console-cancel-and-fresh-retry.mp4).

These are actual game-facing virtual XInput tests. They do not qualify a physical
controller, every focus/menu interruption, transition smoothness or final contacts.

### Fall, get-up and remount

**Run 283 passes** the existing private side-impact/GetUp/remount sequence on the
current runtime. A 5.3883 m/s closing impact triggers the native fall and detaches
the bike. One private typed GetUp/reset succeeds, and standing persists for 17
native seconds in the 30.0167-second passive trace. A later explicit interaction
remounts using token 2 and the same single allocation. Post-remount force/render
counts advance from 492 to 667; pose counts advance from 984 to 1334. Both the
terminal receipt and final archived assessment pass. Exact game teardown is
verified twice. See the
[independent assessment](../../build/bmx/native-postfall-remount-run283/independent-review.json),
[final run](../../build/bmx/native-postfall-remount-run283/run.json) and
[continuous recording](../../build/bmx/native-postfall-remount-run283/fall-getup-remount.mp4).

The sparse auxiliary capture has an initial 43-second gap and cannot establish
the impact/get-up visuals; the continuous NVIDIA recording covers that period.
This validates the private typed action and explicit remount, with ordinary fall
guards retained. The physical-controller GetUp binding is still unqualified.

### Rider alignment and remaining boundaries

Rear switch views show no accumulating gross rider offset or duplicate equipment.
The post-fall side views show the mounted shoes at the pedals and the near hand at
the bar, but the hands still need close rendered inspection. Do not move anchors
to compensate for a presumed missing finger solver: all ten finger chains already
curl around the fitted grip, and historical run 247 has exact solved/native bone
readbacks for those joints. CPU readback does not prove the rendered skin consumed
the same pose or that its surface fits the bar.

The next alignment comparison should join side/three-quarter rendered hands with
finger writes/readbacks and the same bike publication. The current grip probe is
restricted to the private airborne ramp run; it cannot silently be repurposed as
a stationary human-ride probe. Final skinned contact, saddle clearance, ramp
descent and motion quality remain open. No new paired-posture native trial or
ordinary paired-backend promotion is claimed.

### Earlier chassis regression

Native **Flat run 279 passes** on runtime
`ECAB99C2A84B945D358BE28F1A8AF0B10329E9EEAF8E72AE6F103F925DC0502C`:
maximum native travel 23.416 m,
maximum air height 0.9963 m, 541 native force applications and an observed
right-turn bike rotation of -0.2056 radians. Native and supplemental 19-source
identities remain unchanged, as does the runtime. Exact process 11576 was closed
and its absence verified twice. See
[`validation.json`](../../build/bmx/integration-review-20261021/validation.json)
and the [native run archive](../../build/bmx/chassis-ride-run279/run.json).

Attempt 278 is preserved as a prelaunch failure with no game PID: strict
PowerShell exposed a missing deferred-arm selector field. The narrow helper fix
passes 18 positive/95 negative selector cases, including strict-mode sparse
options, and 124 offline suite checks. Retry 279 uses the corrected helper.

Pure posture fixtures establish bounded solver behavior, not improved in-game
appearance or handling. Paired collision, fall momentum transfer, broader terrain
and final physical-controller acceptance remain release work.

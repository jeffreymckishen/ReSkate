# Private pedaling forearm repair

The ordinary pose solver can place an elbow more than 10 cm above or below its
wrist during strong pedaling and steering. On the captured native rig, the
full-pedal, 45-degree crank, +0.4 steer case reaches 104.9 mm; changing the elbow
pole alone cannot satisfy the retained arm lengths and hand contact target.

This candidate first solves the baseline. A valid baseline retains every pose
byte. An invalid neutral/pedaling pose can search up to 1 cm of additional
clavicle aim drop using the existing rotation-based articulation. Every trial
starts from the same source and must pass the unchanged 3 mm contact and anatomy
checks. All local positions/scales and unrelated rotations must match the
baseline. At most nine candidate evaluations run; only a verified candidate is
adopted. No anatomy threshold or native write permission is widened.

Selection is default off and requires this exact isolated human Ride profile:

```powershell
contrib/bmx-lab/Start-BmxGame.ps1 -ForearmRepairCandidate -Ride -NativeChassis -ProfileName bmx-user-data-forearm-repair-test
```

The client publishes selection with the immutable rider frame. The render
callback uses the existing placement/lease/readback gates, and status separates
attempts from completed render receipts. Spring, entry, carry, tricks, releases,
airborne, loaded and uphill posture routes retain their current behavior.

Two independent judges accept this private checkpoint, each scoring engineering
correctness 9.0. Likeness remains unrated. Their frozen source reviews and pins
are under `build/bmx/overnight-review20261021/`.

Validation:

- MSVC Release builds and passes all 93 CTests in 40.02 seconds. Runtime SHA-256:
  `4DF7995E1CA08470EBF7E662C80D261297F242FD1D697C44267305CC2F77154F`.
- The fixture suite passes 1,018,336 checks across 13,321 cases: 36 original and
  216 neighboring eligible failures repaired; 13,057 valid baselines preserved
  byte for byte. Maximum extra aim drop is 9.141 mm; maximum measured contact
  error is 0.06824 mm. These are CPU fixture measurements on one captured rig.
- Twelve existing rejected uphill cases remain: full pedal, steer +/-0.4,
  uphill blend 0.5/gaze 0.1 rad, crank 30/45/60 and 210/225/240 degrees.
  The candidate does not repair those existing posture rejections.
- Native startup 287 loaded the world but timed out its normal mount at the
  readiness gate. The controller driver's read-only foreground guard failed.
  No controller was created, no rider pose was applied and no visual acceptance
  was obtained. The owned game exited at the shutdown deadline, but that
  watcher's receipt encountered the separately recorded pending-exit image race.
  Two subsequent CIM observations verified the PID absent.

The full repair search is too expensive to promote without further work. A GCC
O2 microbenchmark measured baseline 318 us, selected valid baseline 330 us, and
repair median 3.227 ms/p95 3.797 ms/worst 6.950 ms. Repair made 511 allocation calls
with about 5.53 MB cumulative allocation traffic per solve, and it may run in
both animation and render callbacks. These measurements are not a native frame
budget. A scratch optimization and actual callback/visual trials remain required.

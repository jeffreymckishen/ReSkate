# Native force timing diagnostic

This inert Luau mod measures when a varying force becomes visible in the
generic `reskate.world.physics` body's measured velocity. It creates one 12 kg
capsule and publishes 120 commands. It contains no bike controller, rider,
camera ownership or controller capture. The overlay marks measured state;
it does not render a capsule mesh.

Copy the folder into an isolated installation's `Mods` with a fresh diagnostic
folder name. Open **Owned Phase Trial**, explicitly Start, then close the menu
with gameplay focused. A missing qualified clock may refuse creation before
allocation; only that exact refusal offers another explicit Start. There are
no command retries, catch-up steps or Lua pose integration. Arming expires after
120 seconds; an allocated body has a six-second wall watchdog. Focus/menu loss,
clock gaps, conflicting same-serial samples or failed receipts stop the trial.
Successful release parks a retained allocation; it does not destroy it.

Each command applies an upward force of `117.6 + offset` N, repeating offsets
`{-48, 48, 24, -24, 48, -48, 0}`. Torque and impulse are zero. The command
computed from observation N must apply at N+1 and acquire its first actual
successor at N+2 before ordered acknowledgement. All retained receipts are
inspected before the final read used for another publication. The ledger keeps
complete snapshots, including quaternion, inertia and native time, and rejects
different state values sharing one serial.

The full ledger is queued under storage key `phase_native_v1` after the release
attempt. The Host checks dirty storage every two seconds and also saves on VM
close. Inspect the actual file before accepting a run:
`%LOCALAPPDATA%/ReSkate/Plugins/<mod-folder-name>/storage.json`.
This namespace is independent of the isolated game profile. An existing ledger
prevents another Start or overwrite. Archive it and use a fresh mod identity for
another run. Logs contain a short summary because VM log lines truncate at
2,000 bytes.

## Verified native result

On 2026-10-23, one run completed 120 publications and 120 ordered measured
acknowledgements in 2.036 wall seconds, with zero repeated client observations.
Requested serials were 4804..4923, producer serials 4805..4924 and first
successors 4806..4925. The ledger contains 122 consistent full snapshots and
native step duration `0.01666666567325592` seconds. Release was accepted, the
saved ledger survived explicit mod withdrawal/unload, and Skate exited normally.
The body had already been released before unload; this does not qualify unloading
an active body or independently measure post-release motion.

For each candidate delay d, the analyzer compares the same 117 interior velocity
transitions against `h * (force_requested_at_N_minus_d / 12 - 9.8)`. It uses
measured mass and h, fixed gravity, and no fitted gain or replacement trajectory.

| Requested-to-observed delay | Maximum velocity residual (m/s) |
|---|---:|
| 0, acausal control | 0.1000000174 |
| 1 | 0.1333333499 |
| **2** | **0.0000000139** |
| 3 | 0.1333333424 |

Only delay 2 passes the `0.00002 m/s` tolerance; RMS residual is
`4.44e-9 m/s`. Thus command C_N is marked applied at N+1, while its force's
effect first appears in measured velocity at N+2. This identifies end-to-end
velocity visibility. It does not distinguish force-consumption timing from
published-ring latency or establish a global physics-world barrier. A controller
must not treat APPLIED as proof that its modeled body response is already
present in the N+1 sample. See [the force call contract](../bmx-plugin/FORCES.md).

- Runtime source build: `f3880a287292fd71e2a6f2bfb0dbea22554f9918`.
- Runtime SHA256: `65EB08AFD7EEE43319161D59A40EC2F8D0588203DE6D43E4AB049171EA6870CF`.
- This `plugin/main.lua` SHA256: `8F2A7C12CA8A883D8CB01D1590FFEA1C7EA306367B97DD05FB9B3A1665A7C1DE`.
- This manifest SHA256: `727BEAC5B7647350F92784A6E03114459CF66BE810ABC69DAF1FC96562A238A8`.
- Native ledger SHA256: `1784B09DC289CFAD276D8CFD3FDACBE0577D7FEAB4C3E4850B89747E1AA4E343` (104,025 bytes).
- Owned process: PID 52748, process-start FILETIME 134372058893724368.
  Executable/loaded-runtime paths and disk hashes were checked; memory was not hashed.

Analyze an archived ledger with Python's standard library:

```powershell
python analyze_phase.py <storage.json> <analysis.json>
```

Nine offline cases exercised these exact Lua bytes through the actual sandboxed
Host at unchanged limits: success, clock warmup, skipped step, partial receipt,
focus loss, refused release, identical repeat, changed repeated velocity and
changed repeated position. Fake observations in those cases do not simulate the
native force response. `test_analysis.py` separately passes 16 synthetic
classifier checks; running it writes `analysis-test-results.json` beside it.
Neither offline group establishes native timing. An independent reviewer
recomputed the real ledger without using this analyzer and admitted the bounded
native result, engineering 9.3; BMX Streets likeness remains unscored.

Private source freezes, results, raw native log, screenshot, process receipts
and independent admission are under `build/bmx/lua-owned-phase-native-trial-v1/`.
No game binaries or extracted assets are included here. This proves one short
linear-force burst. Closed-loop control, angular/position timing, composed ray
queries, wheel contacts, moving surfaces, active-body cleanup, rider alignment,
switching, fall recovery and BMX Streets likeness require separate evidence.

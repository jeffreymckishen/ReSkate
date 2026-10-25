# Stationary rider observations

A read-only Luau lab plugin for measuring the rider before fitting a bike. It reads 14 joints,
both hand copies and two root checks, then saves one bounded result in its own plugin storage.
It never moves the rider, creates a body, submits controller input or changes a pose.

Copy this folder into the isolated game build's `Mods` directory under a **fresh folder name**.
The folder name selects the storage namespace. Preserve earlier results and use another name
for another observation; the plugin deliberately refuses existing storage and has no rearm.
The manifest requests only `skater.read`, `input`, `menu` and `storage`.

Stand upright on foot, remain still and close the native game menu. Open ReSkate with Insert,
select **Stationary Anchors**, then click **Capture once**. The ReSkate overlay may remain open.
Unknown facts, movement, missing transforms or a 1,500 ms deadline produce a partial result.
At most two pose reads occur per tick, with 32 total calls including discarded warmup reads.
The normal Host callback and rolling tick budgets remain unchanged.

`stationary_anchor_measurement_v1` contains the result. Transforms are sequential SDK
last-evaluated world copies. A complete result does not establish a coherent pose, actor
identity, body-relative calibration, sole contact or a mounted riding pose. Raw telemetry
heading is degrees; the public skater heading and drift limit are radians.

## Verification

Run the pure suite using the [vendored Luau runner](../luau-runner/README.md):

```powershell
<runner.exe> contrib/bmx-lab/stationary-anchor-observer/plugin sampler_tests
```

The suite passed 46 cases / 104 assertions. Its degree/radian alias regression fails against
the previous sampler. It uses constructed providers and does not load the Host adapter.

On 2026-10-25, the preceding sampler loaded in the isolated supported 20260929 game with
runtime SHA-256 `3B25624D2E0C104DDA935C2A47D21A1087CCF44E91776A112DC22F44B101DB09`.
One capture completed 32 reads, 14 finite joints and both hands in 280.1574 ms; its result
was read back from disk. The adapter, manifest and bone list here are byte-identical.
This revision corrects telemetry heading drift units; that correction has pure regression
coverage and has not been rerun in game. It does not change the earlier static observation.

Raw game observations and screenshots stay outside Git. The local receipt is
`E:\RESKATE DEV\stationary-anchor-observation-20261025T101842799Z`, with storage snapshot
SHA-256 `D5596B5A06F1C9EC0346710E73BB83AED3699BBE8E53A74988AD6BC8E51BDBC2`.

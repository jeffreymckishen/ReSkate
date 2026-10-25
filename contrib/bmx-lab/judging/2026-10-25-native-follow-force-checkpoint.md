# Native Follow, force and visual checkpoint — 2026-10-25

Private in-game diagnostics demonstrated separate visual, Follow-cleanup and
force-command building blocks. These were separate bodies and trials, not one
combined riding lifecycle. Public mounting and both riding-composition gates remain
disabled in [main](../bmx-plugin/plugin/main.lua),
[Core](../bmx-plugin/plugin/bike_runtime_core.lua) and
[Ride](../bmx-plugin/plugin/ride_runtime.lua). No BMX Streets likeness rating is assigned.

The Follow, force and controller attempts used isolated Skate build 20260929,
PID 40988 / creation FILETIME `134374216264733260`, runtime
`EAFD2EFB9D0A25CD2957998D6527F55BCB82A7509AA3E3C07675E178117C6E4D`.
Earlier Axis visuals used a different process. All BMX behavior remains Luau;
these results do not enable the public mod.

**Visual comparison.** Six set calls and six cached `ready` reads were recorded.
One matrix-transform trio and one structured-yaw trio were both rendered in the
camera-a2 view, looking broadly alike in upright orientation. This is coarse
visual agreement, not applied-matrix readback, measured axle alignment or rider
fit. The 2-second deadline limits placement; shown visuals have no 2-second expiry.
All six void remove calls returned, and the same saved view subsequently showed
the bikes absent. That does not prove native removal ACK or destruction.
[Axis evidence and images](<E:/RESKATE DEV/static-bike-axis-actual-a1-20261025T1706Z/ACTUAL-OBSERVATION.md>).

**UI-only Follow park.** One arm configured a 500 ms interval, with one Lua
body-create call, reserve, publish, stop and ACK. Actual retained sequence 1 ended
`completed`, final revision 24 = returned revision 24, native epoch 64391,
in-flight 0 and empty pending work, with `park_observed=true` and actual ACK true.
Eight void visual remove calls returned; no ordinary second body release was
attempted. The earlier logged `clock_serial` observation was transient, not the
final result. `native_retirement_known=false`: park/ACK is not destruction or
history erasure. Neither the exact elapsed interval nor a W-only causal change
was established; this attempt did not measure a new angular-fourth value.
[Follow receipt and UI evidence](<E:/RESKATE DEV/ui-only-park-native-pass-v2-20261025T1734Z/ACTUAL-OBSERVATION.md>).

**One force command, on another body.** A horizontal magnitude 106 request with
zero torque and no impulse returned exactly `true, nil, "1"`. The applied receipt
advanced request serial 105143 → produced 105144 → successor 105145, then one force
ACK returned true. Six fresh samples recorded forward velocity 0 → 0.01666666649
and final horizontal displacement 0.0013647876 world units (about 1.365 mm under the
metre convention). Force units and physical-response attribution remain
uncalibrated; grounding, rolling and riding were not proved. One ordinary release
returned true and eight void removals returned. This body's
`native_park_observed=false` and `native_retirement_proven=false` remain explicit;
the separate Follow result supplies neither for it.
[Force receipt, measurements and UI](<E:/RESKATE DEV/ui-only-one-force-native-pass-v1-20261025T1746Z/ACTUAL-OBSERVATION.md>).

**Controller timing failed.** The separate instrumented neutral diagnostic
submitted eight scheduled reports, then refused at planned 160 ms, observed
elapsed 1301.4604 ms / lateness 1141.4604 ms against the unchanged 120 ms limit.
Neutral release and disconnect succeeded; AboveNormal priority was observed.
Its trace contains a 941.6916 ms sleep-call wall bracket followed by a 207.4662 ms
guard wall bracket with 15.625 ms thread CPU. These intervals include blocking and
descheduling; they identify neither a specific native call nor rendering as the
cause. The child exited 2 without retry. It is diagnostic evidence, not a passed
controller baseline; no force or input-source trial ran during it.
[Diagnostic ledger](<E:/RESKATE DEV/controller-neutral-diagnostic-40988-20261025T1801Z/attempt/controller.jsonl>) and
[verified archive](<E:/RESKATE DEV/controller-neutral-diagnostic-40988-20261025T1801Z/archive-verification.json>).

The same game owner later exited normally with code 0 at 18:04:23.8247941Z, without
forced termination. Its [ordinary-close receipt](<E:/RESKATE DEV/ui-only-one-force-native-pass-v1-20261025T1746Z/ordinary-close-exit.json>)
was copied and verified byte-for-byte; exit is not native cleanup ACK. No mounted
switching, rider alignment, fall recovery or gameplay parity was demonstrated.

Primary raw SHA256 pins:

- Follow DTO: `008D64C8BA2A0447BB9F722B3E099EE01BE029580CE4AB2AAA66056A64B1D379`.
- Force DTO: `0B4F7E9BAFDB2F15CC1C566D24733EF78FA4C682897D56C234D8C27CC3FFF73C`.
- Diagnostic ledger: `DDE3DEC6C600C4CE02DB5F76B165499E59837ED6D118C4984FBC3510824FF193`.
- Ordinary close: `35805AD5956BF8701A79368F030DA9655846256E0AFDEDD069771A0D95E91EC6`.

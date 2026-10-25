# Input, Follow and force checkpoint (M4) — 2026-10-25

One private Luau attempt held a passive input lease, handed one owned body to Follow
and submitted one force command in a single plugin lifecycle. All three cleanup
duties finished with their real acknowledgements. This adds the input lease to the
[M3 Follow and force checkpoint](../2026-10-25-combined-follow-force-checkpoint.md).
Public mounting in [main](../../bmx-plugin/plugin/main.lua) and the
[Core](../../bmx-plugin/plugin/bike_runtime_core.lua) and
[Ride](../../bmx-plugin/plugin/ride_runtime.lua) composition gates remain disabled.
The bike is not qualified for riding; BMX Streets likeness remains unmeasured.

The attempt used isolated Skate build 20260929, PID 15648 / creation FILETIME
`134374340792485227`, started by launcher PID 23372 / FILETIME `134374340784424993`.
Runtime SHA256 is `EAFD2EFB9D0A25CD2957998D6527F55BCB82A7509AA3E3C07675E178117C6E4D`,
the same preserved runtime as M3, not a binary rebuilt from later Lua commits.
Runtime, launcher, game executable and controller source hashes were unchanged
after the attempt. Namespace `LuaUIInputFollowOneForceM4_20261025_r1`, run UUID
`26359f26-2bfb-4da5-99c7-d15151392632`, one Arm at 20:37:17.601Z. That namespace
is spent and the result grants no retry.

The twelve-leaf trial package is private and lives on the development drive; its
trial and input modules are not in this repository. The
[sealed source](<E:/RESKATE DEV/ui-input-follow-one-force-m4-native-pass-v1-20261025T2044Z/sealed-source/SOURCE-SEAL.json>)
is source-only with `M4_TRIAL_ADMITTED=false`. The deployed `main.lua` differs from
it only in that flag and the run's identity literals (UUID, storage key, kind,
namespace, page title, button ids); the other eleven leaves are byte-identical.
The log records the plugin loading once with `input`, `input.lease`, `menu`,
`skater.read`, `storage`, `world.entities`, `world.physics` and
`world.physics.follow`. No capture, report writing or new SDK API was involved.
Prep V4 reached sampled-ready on its second of at most 20 prepare calls.

**Body, Follow and force.** One body creation, then one Follow reserve, publish,
Stop and ACK. Force submit returned `true, nil, "1"` for the vector
`[-39.09312057552331, 0, 98.5278027952902]`, magnitude 106 SDK units, zero torque
and no impulse. The applied receipt advanced requested serial 4189 → produced 4190
→ coherent successor 4191, sequence 1; the retained final row is applied and not
quarantined. One force ACK returned true. The terminal Follow receipt is
`completed`, reason `cancelled`, `park_observed=true`, final and returned revision 9,
final native epoch 4196, in-flight 0, no pending revisions. One Follow ACK returned
true. The receipt keeps `claim_known=false` and `native_retirement_known=false`.
The retained `force.body_present=true` is the Lua reference used for receipt and
ACK accounting, not evidence that native ownership continued.

**Input lease.** One observe-mode lease on XInput user 0, source epoch 1, context
generation 13, sequence 1, with 21 reads and 19 renewals. Its latest sample is
observation 7911, packet 3, neutral, `physical_device_identity=unobserved`.
Release returned true, the terminal state is `released`, reason `cancelled`, with
`source_released=true` and capture reserved, capturing, report debt and orphaned
all false. The input ACK then returned true; release acceptance alone was not
counted. Input sequence 1 and body sequence 1 are separate authority domains, not
an atomic input/body join. The ledger keeps counters and the latest sample, not a
history of every read and renewal.

All three ACKs preceded the eight returned void visual-remove calls; no ordinary
second body release was attempted. The ledger was copied after the first Arm and
again after close, and the two copies are byte-identical. Storage writes return
nothing, so the page itself reports durability as not acknowledged.
[Raw copied ledger](<E:/RESKATE DEV/ui-input-follow-one-force-m4-native-pass-v1-20261025T2044Z/actual/storage-after-first-arm.json>).

**Timing and motion.** The run stopped on its 100 ms limit after the first
Lua-seen applied receipt. In Lua wall time, that receipt came about 17.7 ms after
submit, the last measurement 98.2 ms after that receipt, and the final force
cleanup poll 148.4 ms after that receipt; that poll is cleanup observation, not
continued force. The 500 ms Follow figure is a cap; the actual active duration was
not persisted. Native input `observed_ms` values were not joined to Lua time. Seven measurements, serials 4190–4196, recorded final horizontal
displacement 0.0016377451 world units (about 1.64 mm under the metre convention)
and forward velocity about 0.01666666577, while Y fell from 201.3141632 to
201.2188873. This was a falling body. The native log's first cleanup observation
at 20:37:24.169Z reported `park=false` with check `clock_serial`; that was the
first observation, not the terminal receipt.

**Controller, separate evidence.** Controller child PID 20084 / FILETIME
`134374342108583275` ran the unchanged `B0B78C74…` driver. Its bootstrap sent one
raw left-X one-LSB probe and two neutral reports, with two exact-zero readbacks on
slot 0, packet 3, so the session was not neutral-only. Ready at 20:36:52.486939Z
matched game PID, FILETIME and nonce `e18b622e565d433db04910e6a35a3657`. The M4
operation ran during the neutral hold that followed: its first Stop/cleanup log at
20:37:24.169Z was about 10.5 s before the go signal at 20:37:34.668946Z (the Arm,
at 20:37:17.601Z, was about 17.1 s before it). The later 1,001 scheduled all-zero reports over 20 s
(maximum lateness 6.929 ms against the unchanged 120 ms guard) did not drive it.
Neutral release and disconnect succeeded and the child exited 0 at
20:37:54.7379284Z. `input_consumed` and `native_quality` are null. Slot 0 and
packet 3 matching between readback and lease sample is corroboration only.
[Controller ledger](<E:/RESKATE DEV/ui-input-follow-one-force-m4-native-pass-v1-20261025T2044Z/actual/controller/controller.jsonl>).

The saved [done view](<E:/RESKATE DEV/ui-input-follow-one-force-m4-native-pass-v1-20261025T2044Z/actual/done-three-acks.png>)
shows `done`, the stop reason, all three ACKs and eight removal calls. The
[post-cleanup view](<E:/RESKATE DEV/ui-input-follow-one-force-m4-native-pass-v1-20261025T2044Z/actual/post-cleanup-view.png>)
shows the on-foot skater with no obvious BMX in that camera view, which is not
scene-wide absence. No rider pose was captured while Follow was active.

Root sent an ordinary Alt+F4 at 20:38:42.624Z, after the controller finished. The
held exact game process exited 0 at 20:38:50.9361721Z without forced termination.
The complete log reaches Shutdown [25] and has no “did not finish closing” or
“ending it” warning; that is a log observation, not proof of every shutdown path.
Postflight at 20:39:37.9597526Z found no game, launcher, build, test or controller
owners. Process exit is not a native cleanup ACK.
[Held exit receipt](<E:/RESKATE DEV/ui-input-follow-one-force-m4-native-pass-v1-20261025T2044Z/actual/held-process-exit.json>)
and [complete log](<E:/RESKATE DEV/ui-input-follow-one-force-m4-native-pass-v1-20261025T2044Z/actual/ReSkate-complete.log>).

Independent review rated this bounded native evidence **9.4/10**, GO, with no
likeness score; it is not the 9.5 likeness target.
[Native evidence review](<E:/RESKATE DEV/ui-input-follow-one-force-m4-native-pass-v1-20261025T2044Z/actual/INDEPENDENT-REVIEW.md>).
The coordinator's [pure-suite receipt](<E:/RESKATE DEV/ui-input-follow-one-force-m4-native-pass-v1-20261025T2044Z/pure-provenance/claude-result.md>)
reports `combined_trial_tests` at 20 cases and 50 assertions, exit 0, run on a
scratch copy with vendored Luau over constructed SDK fixtures. It is a prose
report with no saved raw stdout or exit record; Root matched its source and test
pins but did not rerun it. The seal's earlier UNRUN status stays as history.

The [archive](<E:/RESKATE DEV/ui-input-follow-one-force-m4-native-pass-v1-20261025T2044Z/ARCHIVE-MANIFEST.json>)
is a copy-only set of 85 payloads. For this checkpoint, all 85 were re-hashed
against the manifest and against their original paths, with no mismatch.

## Not proven

- Grounding or ground support, and rolling.
- Riding, mounting or any controller-driven ride.
- Physical response attribution or force units; the force is uncalibrated.
- Native retirement, destruction or ownership after park and ACK.
- Input consumption by Skate.
- Physical device identity, or an atomic input/body identity.
- Rider alignment, switching, fall recovery and local actor exclusion.
- BMX Streets likeness.

## Primary SHA256 pins

All re-hashed for this checkpoint.

- Copied M4 ledger (both copies): `7C4DB3FC75B44DA6392D310FB043207A10FE598EC5D6A79E48887A9BB72A15D6`.
- Deployed private main: `CFEB0A20B0AB41A4836354549B069364DAEDF0E8A0447ECD501E09367950F54D`.
- Sealed main: `E5A363080FF7C1947C251533C2657FB162DB91657E41BFA158A5A16BEEE655B3`.
- Source seal: `92AFE1645DA8F3EFA7A6460A3C6835359D707E75FD08C91897E9D99B92684DCF`.
- Sealed pure test: `3AD55D5382A6CAC3A7EA8F14EEB731D16C24072F2E90EFF95A43428ECF7B0DF7`.
- Deployment manifest: `31277611BCC38F9BF26F36425527B0B2FF41C9E497D7947C9732DBAF616CB026`.
- Launcher: `E4B0AE99637C018C386ED2117BAC85E6CA0CEAE044574EA7CBB6162C66D0DA55`.
- Game executable: `FBCE74D5E28EF525DBBA2CB4ADBEBC13405BDBD88F31BC940BCA45E4AE88B8F9`.
- Controller source: `B0B78C74B77D1651188BFC5A1AC71E362A45BB5F1FAEA3AE25F2946C0E1D8986`.
- Controller ledger: `B0F60010086E16297CC031FB5CA92F05C1CF18C796FBD3E8D0F4025D1F69F31A`.
- Held game exit: `22D79D8E1F8EDC0B11483FB9B2C36560966D001AD66763A99EB019BF13F17FB7`.
- Complete log: `80B813977A67C1942139101B0BB85697AFD79650008125B473C0F9857E741036`.
- Done view: `79EFD96FE0EC143C2F38DD9C11E8E87AEB2FDB333CA1057E730963321730D19C`.
- Post-cleanup view: `BF3E4F634111416F848FF37753807C8439F598C8A66D273E58A63F2FAA03CE62`.
- Independent review: `D47605A811D470546655F7B4C75C6FFB3700F0833F2EC61090BB84014B28D225`.
- Pure-suite receipt: `BA87344E1225BEB7E07773172A3C12A6E108DC98C743D307CBD20F039B50624A`.
- Root's result: `7DB2D1085DD4B0BDA9934EA6E83001453919A4428C81E7EFB226D4E7C1386F99`.
- Archive manifest: `FF027B4E728C1BBE26732E5E1F7E92AEAF52D6A16A312321EACD7D416C3D3408`.
- Archive verification: `BC162F229A32066693C646D71BC426F6689F1EDB53B8EBCB9F9EAD4F0C158C22`.

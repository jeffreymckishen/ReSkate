# Controller GetUp observed in three native trials

Fresh isolated runs 290, 291 and 292 recovered from recognized native ragdoll
after one bounded North/Y controller pulse. Each then remained standable for
more than 21 native seconds in its sealed fall trace. This closes the missing
game-facing recovery observation from the [neutral-only checkpoint](2026-10-22-controller-recovery-gap.md)
for this specific scripted side-impact case. Ordinary remount and broader
recovery coverage remain open.

All three ran runtime
`AE0DC907BEA9C505A952FCCE4CF9F92601DB1CE91215B1497BBB4DEF1D2C6076`
in the isolated `bmx-user-data-chassis-probe` unattended NativeChassis profile,
at the Sun Peak Lodge scene in MPR. The same scripted side-impact recipe
accepted and reset a native `RequestWipeout` intent, then detached the bike.
This is not an ordinary collision or varied-terrain qualification. Rider
comparison stayed Default; the private forearm repair candidate was unselected.
The build's 95 passing Release CTests are engineering evidence, separate from
these native observations.

| Run / PID | Fall samples / recognized ragdoll | First standing, seconds from fall snapshot | First ragdoll to first standing | Continuous standing tail |
| --- | --- | --- | --- | --- |
| 290 / 43604 | 315 / 96 | 8.4500 | 8.4167 | 21.5667 |
| 291 / 46884 | 314 / 94 | 8.3167 | 8.2833 | 21.7000 |
| 292 / 21248 | 315 / 94 | 8.3000 | 8.2667 | 21.7167 |

Times are native simulation seconds. Each sealed trace spans 30.0167 seconds.
The first recognized ragdoll sample follows the initial fall snapshot by
0.0333 seconds, which explains the two recovery-time columns. Both clocks and
serials increase coherently at the recorded 60 Hz step, with no snapshot
failures or overwritten samples.

The guarded driver submitted ten North reports at planned 20 ms spacing, requesting a
200 ms pulse between neutral reports. Each native trace independently contains
two focused, recognized-ragdoll samples with observed pad bits `32768` and
input-device value `1`, followed by standing with the button released. PID,
creation FILETIME, runtime, gate nonce and source pins agree across the owner,
driver and native receipts. The binder checks the loaded module path and
on-disk hash; it does not hash the in-memory image. This establishes the observed
virtual-controller action in these cases, without identifying a physical
controller or universal binding.

All five BMX capture leases were false during every recognized-ragdoll sample.
Bike drive, BMX, rider motion and board-switch-pending stayed false throughout
each sealed trace. The interaction lease reacquired after standing. Completed
force/velocity/pose/render counters remained `34/34/68/34`; no queued automatic
BMX remount appears. Focus is true at the observed pulses and first recovery;
run 291 has 16 late standing samples with unavailable focus/device fields.
Every controller ledger records successful final neutral and disconnect, and
the worker exited. Held-process guardians and two separate CIM observations
confirm teardown of each original owner.

No typed GetUp pulse, native GetUp setter or forced mount was used. The passive
canonical GetUp getter remained false in all 300 observer rows per run, while
`binding_present` remained null. That value cannot establish a known binding
or override the directly observed standing recovery. The controller ledger's
`input_consumed` and `native_quality` fields also remain null; the separate
native trace supplies the pad/state observations.

Run 292 later received a separate, operator-requested fresh Y tap after a live
standing image. Its driver completed and released normally, but no remount was
confirmed: the later image still shows the standing rider beside the visible
unmounted bike, with no new mount log or ride trace. This tap occurred after
the sealed fall window, so that window cannot qualify its native input/state
outcome. The automatic sealed-report remount protocol was held and never ran.

The profile explains why that probe cannot test ordinary manual remount.
`Start-BmxGame.ps1` sets `RESKATE_BMX_AUTOMATED_RIDE=1` for the exact unattended
chassis profile. `automated_ride::enabled()` caches that process selection;
`bmx_runtime.cpp` excludes it from `manual_interaction`, even after the
rehearsal finishes. Ending a rehearsal does not enable manual BMX requests in
the same process. The next remount test therefore requires a fresh ordinary
`Ride NativeChassis HumanNativeSwitch` process without automated flags. Its
result must be recorded separately.

Evidence is retained in `build/bmx/controller-recovery290`, `291` and `292`,
including immutable archive/source manifests, both run-292 controller ledgers,
sealed falls, owner bindings, impact reports, logs, endpoint images and
teardown receipts. The independent three-case review is
`build/bmx/overnight-review20261021/controller-recovery290-292-fresh-judge.json`,
SHA256 `B64C8D037B05D5DD4049E3188A2466EAAD8B7249B65A059E88CAB767870A2322`.
Its scoped engineering evidence score is 9.0; BMX Streets likeness is unrated.
These three repeated scripted cases do not cover ordinary ride-away remount,
high-speed frontal impacts, failed landings, focus interruption, varied terrain,
physical-controller feel or full-speed visual continuity. They do not satisfy
the rubric's 9.5 recovery or likeness requirements.

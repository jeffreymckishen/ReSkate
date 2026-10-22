# Private forearm selection without repair activation — run 304

Run 304 selected the private forearm candidate and observed its valid-baseline
path, but did not exercise a repair. The final native status reports selection1,
attempted/unrepaired render solves `0/0`, and posture requested/applied `0/0`.
An earlier status reports baseline valid1, applied0 and zero extra clavicle
drop. These observations do not qualify repair appearance, native repair cost
or default adoption.

PID `34444`, creation FILETIME `134371663122160124`, used runtime SHA256
`E073F373BA936E6259FBDA4F596B635AD31955ECA68FAC80222AF122AA3302DD`
and the exact private `bmx-user-data-forearm-repair-test` profile. The admitted
launcher selects `ForearmRepairCandidate` without `HumanNativeSwitch`.
The runtime's existing build validation is 97/97 CTests; this episode adds no
full-suite or measured repair-performance claim.

The straight request stopped after 45 scheduled reports: 12 neutral and 33 A,
with no B phase. Its original 120ms scheduler timing refusal is preserved;
the next planned900ms report was not submitted. A separately chosen left
request completed all 201 reports: 100 A with left-stick X `-.4`, 50 B and
51 neutral. Right was never attempted. Both workers retained exact pinned
source/owner/nonce ready/GO checks and completed final neutral, disconnect and
parent-observed exit. There were 246 scheduled reports in total, with bootstrap
operations additional. The timing refusal's cause remains unresolved.

Raw stick magnitude `.4` also differs from a pose fixture's `Frame.steer=.4`
radians. The default [input mapper](../../../../Engine/Game/BMX/bmx_input.h)
maps an axis-aligned `.4` through its `.12` deadzone to `.318182`. The default
[chassis request](../../../../Engine/Game/BMX/bmx_chassis_control.h) is
`-mapped_steer * .4 / (1 + abs(longitudinal_speed)/8)`: about `.127273` radians
at zero speed, before actuator/lean filtering. The
[ride adapter](../../../../Extension/BMX/bmx_chassis_ride.cpp) assigns the solved
fork angle to `Frame.steer`. This source comparison identifies different input
units; it does not measure the missing action-phase angle or establish why
repair attempts stayed zero. Actual frame extents, valid geometry and exclusion
gates still need to be distinguished; no rig mismatch is inferred.

The native log records reason2/region1 bail at serial15267,
`18:17:02.659 UTC`, and accepts fall request1/generation1 two milliseconds later.
This is `4.663344 s` after the left worker ended, `6.444156 s` after its last A
report and `5.444047 s` after its last B report. These are host ledger/log
intervals, not an exact native-clock join. The retained 240 native rows span
`3.983333 s` immediately before bail; raw and sampled pedal/brake are all zero.
They preserve the late fall phase and cannot establish earlier A/B consumption
or isolate braking/collision forces. Six independently viewed Sky JPEGs show
mounted endpoints, then the grounded rider and overturned bike on the stairs.
No passive fall lifecycle JSON, recovery or remount is retained for this run.

The [independent audit](../../../../build/bmx/overnight-review20261021/forearm-controller304-fresh-judge.json)
passed 500 checks against 80 pre-video files, including 32 selected sources
and the original admitted 4,900-byte launcher and 4,389-byte controller parent.
Manifest SHA256:
`0BA9447FE8A09E10BDD168CB1EAA7F51472E19D66B9DB02386EC48718A6DACB1`.
Selected sources and admission copies are not complete compiler-input
provenance. The recorder START completed at `18:13:12.399 UTC`; STOP completed
at `18:17:40.215 UTC`. Continuous media review remains separate from these
endpoint observations.

The first Alt+F4 request, with the console open, did not close the process.
The second request removed the owned window at `18:20:42.058 UTC`. The guardian
then returned `refused`, reporting a process-image read failure; it did not
qualify termination or held-handle absence. Final fresh CIM observations at
`18:21:12.6153615` and `18:21:13.4720768 UTC` both found no isolated process,
before the original deadline. Two later independent process-list checks also
found none. The guardian refusal is preserved separately from verified manual
closure. Private repair rendering, its cost, physical-controller feel and
BMX Streets likeness remain unqualified.

## Subsequent targeted video review

Original video SHA256:
`ACBE3FCB50D42D0C35C69645829E0CDF0259CCE46C8A7EB1379EB4DC1879F107`.
The media reviewer decoded 27 targeted seconds, retaining 110 previews from
1,670 local frames including preroll. A second independent view covered three
of the eight sheets: 48 preview timestamps, plus two standalone images at
already represented timestamps. The samples show forward advance and a left
turn, then stair descent near the left rail and a fall around video seconds
`230.00..230.77`. The grounded rider and overturned bike remain visible.

The [independent pixel addendum](../../../../build/bmx/overnight-review20261021/forearm-controller304-pixel-addendum-fresh-judge.json)
pins those existing images. It adds no native force or fine hand/foot contact
measurement. HUD point values do not establish the scheduler refusal's cause
or repair cost. Repair attempts remain zero; there is no paired native repair
render, full-file PTS validation, exact native-clock video join or likeness
upgrade.

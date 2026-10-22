# Private forearm mirror capture 306 — October 22, 2026

Run 306 captured the opposite high-angle, pedal-loaded native baseline on the
same private diagnostic runtime as [305](2026-10-22-private-forearm-capture-305.md).
That baseline was valid. Repair attempts and applications remained zero, so this
run does not qualify a repaired pose or default adoption.

PID `46796`, creation FILETIME `134371703177974388`, used runtime
`D35662D87EFCFE3447C140CF39AFDB878D5A6D083B420D73CDD1DCA9339EF2D6`
and the exact private forearm profile, without HumanNativeSwitch. The source
was built at `a00b8c7` with selected uncommitted inputs later recorded by
`7c893dd`; the existing release passed 101/101 CTests. No additional full build
was performed for this mirror trial.

## Input, native response and park

The separately selected `ordinary-posture-capture-right` request completed
201 scheduled reports: 50 B with left-stick X `+1` requesting a right turn,
50 A with the same steering, 50 centered B, 10 ordinary Y, and 41 neutral.
Right-stick axes stayed zero. The original owner, foreground, Escape, nonce/GO and scheduler guards
remained active. Final neutral, disconnect and worker exit succeeded.

The default 240-row native trace retains 57 pre-brake rows, 60 pedal rows and
60 post-brake rows, with raw and policy-stage A/B values matching. Its remaining
63 rows are neutral. These 60 Hz native rows are not the 50 Hz driver reports.
Across all 239 available successor pairs, producer applications advance by one,
producer serial matches the prior submitted command, and force/torque vectors
match exactly.

Using velocity projected onto each observed, normalized body quaternion's +Z,
the pedal phase increases signed forward speed from `0.000105` to
`2.353554 m/s`. The following brake phase reduces it to `-0.000873 m/s`.
These endpoints use the successor observation after the final phase command.
Total three-dimensional speed still measures `0.105015 m/s`, so complete rest
is not established. Gravity, contact and braking forces are not isolated.
Native ordinary park was logged at `19:20:15.989 UTC`; the trace flushed at
`19:20:17.114 UTC`, with no bail in the retained window.

## Diagnostic and attributed replay

The exported diagnostic contains 2,579 selected, ready and completed render
solves, with 1,343 eligible/requested/valid baseline results. Attempts,
applications and requested-unready results are all zero. Its first high-angle
loaded snapshot has steering `-0.399040967 rad`, crank phase `-0.906523466 rad`
and pedal effort 1. Client preparation and export used thread `50476`; the
callback completed its render write. The invalid/requested-attempt slot remains
unclaimed. These are source callback witnesses, not GPU output measurements.

The diagnostic author's [mirror replay](../../../../build/bmx/overnight-review20261021/forearm306-actual-replay-v1/actual-native-analysis-receipt.json),
SHA-256 `0B826BB59D7F3DDC05BD210F683D5ED427F641694D952429BC646DC3967D0A44`,
compares two CPU solves of this exact frame. All 26 serialized Result fields
match the native callback, all 395 selected-versus-disabled solved bone records
are identical, and the existing strict anatomy check passes. Native post-write
bones were not read back. This attributed author analysis does not qualify
rendered wrist roll, palm/finger contact or repair appearance.

## Video, closure and boundaries

The preserved source recording is 479,785,689 bytes, SHA-256
`080B463B21B360A80930E955F218E1FDFEE6F04873927C5FD35D78B41AC4EB1D`.
The media reviewer decoded only 11 targeted seconds around the action: 685 local
frames including preroll and 45 quarter-second previews across three sheets.
Those samples show a right turn, short advance and step-off beside the retained
upright bike. Rear camera and clothing obscure fine elbow, wrist and grip
alignment. There is no full-file PTS validation or exact native/video clock join.

Recording stopped at `19:22:14.419 UTC`, before the ordinary close request.
The guardian refused an image read during manual exit; it receives no
held-handle or deadline termination credit. Exact-path CIM observations at
`19:23:07.1927768` and `19:23:08.1647876 UTC` were empty. Two later independent
process-list checks were also empty.

The independent native/controller audit passed 1,668 checks against 77 frozen
pre-video files and 38 selected sources. Manifest SHA-256:
`DF95F358BCB8038AC5AB18D374A0581A920C3BA35825830081E130B77D9EEA3A`.
Its [audit](../../../../build/bmx/overnight-review20261021/forearm-controller306-fresh-judge.json)
is `EB0B2AF8E2C87E710F9DDADB50F94B4FC02F207FF2FD3D5E5D749AA469767B06`.
The separate media/native calculation packet is
`B68059F27582E63E1250E03550DF259749FCAE179466A5C028BD2E13E7D76183`.
Selected-source snapshots are supplemental provenance, not complete compiler
inputs. Repair cost, repaired rendering, physical-controller feel and BMX
Streets likeness remain unqualified.

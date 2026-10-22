# Private forearm capture 305 — October 22, 2026

Run 305 qualifies the new native diagnostic export and a completed high-angle,
pedal-loaded baseline pose. It does **not** qualify an applied repair: the
captured baseline was already valid and repair attempts/applied remained 0.

The isolated process was PID 22832, creation FILETIME 134371693685787708,
runtime `D35662D87EFCFE3447C140CF39AFDB878D5A6D083B420D73CDD1DCA9339EF2D6`.
It selected the exact private ForearmRepairCandidate profile without
HumanNativeSwitch. The release passed 101/101 CTests in 22.91 seconds; the build
receipt preserves the initial test-only `/WX` failure and corrected retry.
Its actual build HEAD was `a00b8c7` with selected uncommitted inputs, subsequently
recorded by `7c893dd`. Neither the 9-file build selection nor 38-file trial selection
is complete compiler provenance.

## Actual controller and diagnostic evidence

One fixed `ordinary-posture-capture-left` leg completed all 201 scheduled reports:
50 brake reports with left stick −1, 50 pedal reports with left stick −1, 50 brake
reports with centered stick, 10 ordinary Y reports and 41 neutral reports. The
original foreground/identity/nonce/GO/deadline/scheduler guards remained active;
final neutral, disconnect and worker exit succeeded. Native ordinary park was
logged at 19:04:23.521 UTC and the default 240-sample trace flushed at 19:04:24.643.
That trace retains 60 pedal and 120 brake samples with matching policy-stage values
and no bail. Those rows provide stronger action coverage than 304's neutral tail.

The explicit `bmx forearm-dump` command saved 406,616 bytes at 19:05:26.862 UTC.
Prepared client thread and export thread were both 51804, distinct from the
console submission thread 31524. Preparation succeeded with no shape/rig mismatch.

| Diagnostic count | Observed |
| --- | ---: |
| Selected render solves / ready / completed render writes | 2260 / 2260 / 2260 |
| Neutral eligible / requested / baseline valid | 1236 / 1236 / 1236 |
| Ineligible / uphill eligible | 1024 / 0 |
| Repair attempts / applied / requested unready | 0 / 0 / 0 |

The first eligible high-angle-loaded snapshot contains 395 original bones and
a 386-joint rig. Its actual Frame has fork steering +0.39930728 rad,
crank phase −0.90652078 rad and pedal effort 1. The callback exited at `completed`
with completed-render-write true. Existing Result reports full hand/foot
contacts, each target error 0.0000305176 m, baseline valid and zero extra drop/search
evaluations. Three later matches were counted without replacement; the separate
first-attempt/requested-invalid slot remained unclaimed. These are CPU callback
and source-solver receipts, not proof of final GPU skinning or glove contact.
The exact captured source supports the separate CPU replay described below.

## Bounded visual and closure evidence

Independent review of three existing contact sheets covers 45 previews from
11 targeted seconds, approximately 13–24 seconds in the recording. They show a
left turn, short advance and ordinary step-off beside the retained upright
bike. Rear-view clothing and scale leave fine elbow/wrist/grip appearance
unrated. The source archive is 397,565,529 bytes, SHA-256
`D9C185A6B12AFE149166923B2EF13A4285112B764C459B61CD71F11F4170A68E`;
the media author decoded 685 local frames including preroll. This is neither a
full-file PTS review nor an exact native-clock/video join.

Recording stopped at 19:05:56.548 UTC, before the ordinary close request.
Initial CIM observations still found the process. The guardian then **refused**
an image read and earns no held-handle/deadline closure credit. Final exact-path
CIM observations at 19:06:45.7709462 and 19:06:46.7616166 UTC were empty;
two separate Get-Process checks were also empty. Actual absence was verified
before the 600-second deadline.

Evidence is frozen under `build/bmx/forearm-controller305`:
the 80-file pre-video manifest is
`F9DE9D8A94AD0C1E9492B6E13B638F53B612F70A985651E354173C74186DE33F`.
The independent native/controller audit passed 1675 assertions
(`forearm-controller305-fresh-judge.json`, SHA-256
`7339AEE12B87D4D72D6BFB8EDCCFCB563A99BDA40760846F687DE9DCAAD2EA7C`).
The separate media packet is `EF082F6DE0C3798F023231E726652FAF3B9F613E497627431688E2C82DB7A52B`;
the independent pixel addendum remains a separate receipt.

Default adoption, native diagnostic/repair timing cost, repaired-pose rendering,
physical-controller feel and 9.5 BMX Streets likeness remain unqualified.

## Subsequent CPU replay

The diagnostic author replayed this exact captured frame twice: once with the
private selector restored and once with it disabled. The selected replay matched
all 26 serialized native Result fields exactly. All 395 solved bone records were
identical between the selected and disabled CPU solves, and the existing strict
anatomy check passed. The captured baseline therefore required no repair in
these two solves. This is attributed author analysis, not a second independent
engineering or gameplay score.

The [replay receipt](../../../../build/bmx/overnight-review20261021/forearm305-actual-replay-v1/actual-native-analysis-receipt.json)
has SHA-256 `D64E641B2FDBAF411B5D63AAA19E54E8D17380EEE54EAD335E08D4F8A95471B8`.
It preserves the failed ignored fixture-generation attempt and corrected retry.
Native post-write output bones were not read back: the byte comparison is
between two CPU outputs, while the native completed-write flag remains a
separate callback witness. Neither this replay nor the rear-view footage
qualifies wrist roll, fingers, glove skinning or repaired rendering.

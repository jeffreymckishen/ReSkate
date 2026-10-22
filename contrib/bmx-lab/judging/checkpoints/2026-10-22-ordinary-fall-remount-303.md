# Ordinary fall, remount and short response — run 303

Run 303 qualified one ordinary impact fall, visible standing after a separate
Y request, retained-bike owner requalification, a natural nearby remount and a
short forward response followed by ordinary park. It used PID `32680`, creation
FILETIME `134371651249749064`, in `Ride -NativeChassis -HumanNativeSwitch`,
with runtime SHA256
`E073F373BA936E6259FBDA4F596B635AD31955ECA68FAC80222AF122AA3302DD`.
Both native ride exports confirm the ordinary 240-sample history; the private
long selector was off. This runtime previously passed 97/97 CTests.

Five separately selected controller workers completed before the deadline:
right approach301, Y1 301, walk-right151, Y2 301 and departure/park201 reports.
The total is 1,255 scheduled reports, with bootstrap operations additional.
Every worker retained exact source/owner/nonce ready/GO checks, the two-second
neutral preflight and 120ms scheduler guard, then completed final neutral,
disconnect and parent-observed exit. No automatic retry or typed GetUp request
was scheduled.

The log accepts reason2 fall request1/generation1 at `17:54:43.227 UTC`.
The token1 ride trace retains 117 native pedal samples and the final bail.
Its separate early fall window contains 314 samples over `30.016665` native
seconds: 312 recognized ragdoll samples, all BMX leases released, frozen
completed counters and zero snapshot failures. It completes while ragdoll;
there is no same-owner standing transition or Y observation within that window.
The later Y1 worker and standing pixels qualify the visible recovery separately.
The canonical GetUp getter remains false with unknown binding presence; that
does not establish an input binding or typed setter use.

At `17:59:16.756 UTC`, the native log requalifies custody token `1 -> 2` with
no native setters or allocation and requires explicit retry. After the deliberate
walk request, a fresh Y2 starts a natural token3 mount at `18:00:09.876 UTC`:
root distance `0.651443 m`, duration `1.252775 s`. It completes at
`18:00:11.139 UTC`, with observed root error `0.000167 m`. An independently
viewed image shows the mounted BMX. This is a natural remount following the
ordinary fall, rather than the requalification token being treated as a mount.

The subsequent token3 departure trace retains 240 consecutive samples over
`3.983333` native seconds, including 60 actual pedal and 60 actual brake samples.
Raw and sampled controls agree, with focused device1, adapter input source and
submitted chassis commands. Signed velocity is projected onto normalized
observed body-quaternion +Z, the longitudinal axis used by the controller.
From the first pedal sample to the successor after its last command it changes
from `-0.012207` to `+2.467809 m/s`; the corresponding brake interval changes
from `+2.470047` to approximately `+0.000001 m/s`. The retained COM deltas sum
to `+1.723868 m` along successive observed forward axes, with `1.720326 m` net
displacement and `2.090409 m` sampled path length. Final three-dimensional speed
is `0.030436 m/s`. There is no second bail in this retained interval.

Ordinary park is logged at `18:00:46.906 UTC`; the final images show a standing
rider beside the upright bike near the stone wall. This qualifies a short
forward response and stop/park in this scene. Wall/contact effects, steering and
external forces were not isolated, and the route was not verified clear.
There is no unrestricted ride-away or isolated brake-force claim.

The [independent audit](../../../../build/bmx/overnight-review20261021/human-controller303-fresh-judge.json)
passed 1,852 checks against 98 pre-video files. Manifest SHA256:
`8DBC4DB29653944BB9771FE71330E44C67F97BD61E098D8565B11FFB6F8042F0`.
It includes 30 selected source files, admission copies and one additional
analysis header; these are not complete compiler-input provenance. All seven
saved Sky JPEGs were independently viewed. The recorder START completed at
`17:53:52.435 UTC` and STOP at `18:01:29.280 UTC`; continuous video review is
separate from these endpoint observations.

The held-process guardian completed at `18:02:07.5587857 UTC`. Root's two fresh
CIM observations and the reviewer's two independent process-list observations
found no isolated game. The reviewer's sandbox CIM API was unavailable; this
limitation is retained in the audit. Repeated ordinary falls, broad handling,
carry/set-down, alignment quality, physical-controller feel and BMX Streets
likeness remain unqualified.

## Subsequent targeted video review

The archived original is pinned as
`71B4D67BD5F661769AFCCD82D25C0FCAC6937EDBE1A5B9B1F539CA73C29C68AD`.
The media reviewer decoded 42 targeted seconds: 2,648 local frames including
preroll, with 173 selected previews in 14 sheets. An independent second view
covered eight existing sheets and 128 previews for fall, GetUp, remount and
departure/park. The continuous walk window remains the media reviewer's scope;
the second reviewer separately viewed its saved endpoint image.

These samples corroborate the visible fall, later standing, remount and short
constrained advance/park. GetUp changes from prone at video `323.016500 s` to
standing at `323.266078 s` across a camera/pose cut; smooth GetUp animation is
not qualified. During remount the lying bike becomes upright before the settled
riding pose. Fine contact and prop-transition quality remain ungraded. No
full-file PTS validation, exact video/native-clock join, clear ride-away or
likeness score is inferred. The
[independent pixel addendum](../../../../build/bmx/overnight-review20261021/human-controller303-pixel-addendum-fresh-judge.json)
pins the exact viewed sheets and preserves these limits.

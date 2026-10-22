# Ordinary fall and controller GetUp — run 302

Run 302 qualified an ordinary impact fall followed by a visible standing rider
after one ordinary Y request. It did not test postfall remount. PID `27252`,
creation FILETIME `134371640701057324`, ran `Ride -NativeChassis
-HumanNativeSwitch -LongRideTrace` with runtime SHA256
`E073F373BA936E6259FBDA4F596B635AD31955ECA68FAC80222AF122AA3302DD`.
The build passed 97/97 CTests. The private long capture changed retention only;
its native serialization cost remains unqualified.

The right approach submitted 301 scheduled reports: 100 A with left-stick X
`+.8` and 201 neutral. The 39,850,720-byte native ride export retains 3,600
consecutive samples, serials `729..4328`, over `59.983330` native seconds.
Its metadata reports 4,328 accepted samples and 728 overwritten. It preserves
120 actual native samples with raw and sampled pedal `1`, left-stick X
`0.80001223`, focused device `1`, adapter input source and submitted chassis
commands. The final sample records reason2 bail, with the new command withheld.
The log accepts fall request1/generation1 at `17:36:47.196 UTC`. This establishes
coverage of the action and fall; it does not isolate the collision or force law.

The passive fall report ends after `29.249998` native seconds. Its 306 retained
samples span `29.216665` seconds and include 304 recognized ragdoll samples.
BMX leases are released throughout;
completed counters stay frozen and snapshot failures are zero. A separate
plain-Y request submitted 301 reports, including ten Y reports. The native fall
samples actually observe Y (`32768`) twice while the rider remains recognized
as ragdoll. Later pixels show the rider standing beside the retained lying bike.
The final native log records owner requalification at `17:37:18.027 UTC`, token
`1 -> 2`, with no native setters or allocation and explicit retry required.

That identity replacement ends the fall observer. `window_complete` and
`standable_after_ragdoll_observed` are false: this is not a same-owner sampled
ragdoll-to-standing transition. The canonical GetUp getter stays false with
unknown binding presence; it does not identify the Y binding or show use of a
typed GetUp setter. Standing is independently supported by the later images.

A deliberate walk-right request submitted 151 reports: 30 with left-stick X
`+.65`, all buttons zero, and 121 neutral. The standing rider changes facing
and nearby screen position while the bike remains visible. These endpoints
do not measure world displacement, proximity or remount readiness. All three
completed workers retained distinct ready/GO nonces, final neutral,
disconnect and parent-observed exit: 753 scheduled reports in total, with
bootstrap operations additional.

The intended fresh Y2 began at `17:44:39.168701 UTC`, after both the process
deadline and guardian closure. The foreground guard refused it before backend
initialization, READY or GO; it submitted zero scheduled reports. This is an
untested remount, not a remount failure. No second natural mount completes in
the retained native log.

The [independent audit](../../../../build/bmx/overnight-review20261021/human-controller302-fresh-judge.json)
passed 1,034 checks against 84 pre-video files, including 29 selected source
pins and frozen walk/parent admission supplements. Archive manifest SHA256:
`1B5AFF59B1203A9230BD7FF1DA6CF9FDC8D65579AF0C12575790164DB78431C6`.
These selected sources are not a complete compiler-input manifest. All five
saved Sky JPEGs were independently viewed: mounted before approach, fallen
with lying bike, standing after Y1, standing before walk, and unmounted after
walk. Recorder START completed at `17:35:43.311 UTC`; no STOP was sent. Video
finalization and continuous review remain separate work.

The guardian closed the held process at `17:44:32.5672638 UTC`; two later CIM
checks found no isolated game. This is one ordinary scene-specific fall and
visible recovery. Repeated falls, postfall remount/ride-away, native capture
cost, physical-controller feel and BMX Streets likeness remain unqualified.

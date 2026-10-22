# Ordinary Y park and nearby remount — run 296

Run 296 verifies one ordinary Y dismount and a later fresh Y remount of the parked
upright BMX. Native lifecycle logs and three independent endpoint image checks
agree. This is an ordinary parked-bike interaction, with no fall preparation or
typed GetUp request; it does not qualify postfall recovery or physical-controller
feel.

The isolated human Ride process was PID `45768`, creation FILETIME
`134371549115237952`, with `NativeChassis -HumanNativeSwitch` and profile
`bmx-user-data-human-native-test`. Its runtime matches
[run 295](2026-10-22-human-switch-295.md):
`BB69367312CBB49A0BEB506113134540C3D07D58ED7CD1CD8BF0B36F61204182`.

The first virtual-controller action schedules one 200ms plain Y pulse. The native
log records “Off the bike” at `15:04:15.551 UTC`, and the image captured at
`15:05:39.956 UTC` shows the rider standing beside the visible upright parked bike.
A separately requested fresh Y pulse starts a natural token2 mount with root
distance `0.6586649m`. It completes at `15:06:21.217 UTC`, with recorded transition
duration `1.2666632` seconds and root error `0.000114186325m`.
The `15:08:34.664 UTC` image shows the mounted rider. No LB chord is scheduled in
either action. The harness label `native-north-recovery-candidate` is reused
protocol naming; it is not a recovery claim.

Each Y session submits 301 scheduled reports: ten Y and 291 neutral, with scheduled
axes/triggers zero. A later existing `ground-pump` timeline submits 161 reports:
38 A reports for 0.76 seconds and 15 left-stick-Y `-0.7` reports for 0.3 seconds,
otherwise neutral. All three sessions have distinct matching ready/GO nonces,
matching owner/runtime/source, final neutral, disconnect and observed worker exit.
Constructor/bootstrap operations are additional to those scheduled counts.

The `15:10:59.966 UTC` endpoint still shows mounted BMX. This audit does not prove
native pedal or pump consumption, applied force, trajectory or ride quality. The
only exported ride trace is token1, ending at the earlier ordinary dismount; no
token2 ride export is available. Video preservation and subsequent motion review
remain separate evidence.

Recording was stopped at `15:10:59.246 UTC`. The 600-second guardian closed the
original process at `15:11:53.3585355 UTC` and observed it signaled twice. Two later
CIM observations at `15:13:24.7661969` and `15:13:25.3286186 UTC` found no isolated
process. The independent [case audit](../../../../build/bmx/overnight-review20261021/human-controller296-fresh-judge.json)
checks finite original JSON, all 62 pre-video archive files and 20 frozen source
files. Archive-manifest SHA256:
`01FFAA4AC61BC222E3E7489B99A244EE9A4318F48C1B2C1AFD918648657F24FE`.

One parked remount does not complete the repeated walk-away, carry/set-down,
postfall, focus interruption or physical-controller scenarios. The
[293](2026-10-22-human-switch-293.md) and
[294](2026-10-22-human-switch-294.md) switch failures remain unresolved.
No 9.5 likeness or complete equipment-reliability acceptance is claimed.

Subsequent targeted video review adds 67 selected frames from four windows
(1,065 locally decoded frames including preroll). They show the ordinary step-off,
leg-over remount and retained mounted endpoint. The short ride begins close to a
central wooden bollard and shows little clear sustained travel; it does not
qualify a clean ride-away or native pedal/pump forces. A future dynamic trial needs
a clear route and heading. The [pixel addendum](../../../../build/bmx/overnight-review20261021/human-controller296-targeted-pixel-judge.json)
pins the source video `3C5963F5E2B6F23949A26E71E207AE90EA6A9A63FC08D99158363850D3BBB900`
and targeted receipt `767FB8EED069B6B67814519CC7B982C9F25EBD043D3305961AAF17ECDBA91E69`.
These bounded samples have no full-file PTS validation or exact native-clock join.

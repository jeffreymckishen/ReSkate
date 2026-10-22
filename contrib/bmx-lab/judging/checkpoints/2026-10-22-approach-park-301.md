# Approach requests and ordinary park — run 301

Run 301 did not qualify an ordinary fall, GetUp or postfall remount. It retained
one partial left approach, two completed approach requests and a later ordinary
Y park in `Ride -NativeChassis -HumanNativeSwitch` mode. PID `48188`, creation
FILETIME `134371617184024275`, used runtime SHA256
`9CA7EF4A0CAB864E588850091497200E3C5A72AEF58A51C631B8A1A63E86A034`.

The first left request stopped after 29 submitted reports: 12 neutral and 17 A
with stick X `-.8`. The original scheduler refusal is preserved; the next
planned580ms report was never submitted. This was a partial request, not a
completed two-second approach. Final neutral, disconnect and worker exit passed.
The existing 120ms lateness guard was retained.

A separate fresh left request and a straight request each submitted 301 reports:
100 A and 201 neutral. Left used X `-.8` during A; straight used zero axes.
A later plain-Y request submitted 301 reports: ten Y and 291 neutral. All four
sessions had distinct matching ready/GO nonces, coherent owner/runtime/source,
final neutral, disconnect and parent-observed exit. There were 932 scheduled
submitted reports in total; bootstrap operations are additional. These transport
receipts alone do not establish native A/steering consumption or forces.

The native log records ordinary park at `17:04:44.220 UTC` and token1 trace flush
at `17:04:45.305 UTC`. The retained 240 rows span native seconds
`507.233303..511.216636`; raw and sampled pedal/brake are all zero. This later
neutral tail excludes the approach phases and cannot qualify their motion or
force response. The three independently viewed post-action Sky samples show an
upright mounted rider/BMX, with no ragdoll at those samples. There is no final
park snapshot. Apparent movement direction remains unproven pending continuous
video and native basis/producer evidence.

The [independent audit](../../../../build/bmx/overnight-review20261021/human-controller301-fresh-judge.json)
passed 289 checks against 80 pre-video files in frozen manifest
`ED3FB81CD602CA8137ADFAF1946B1F97CF99982935190EA6097428FFBBF50EA2`,
including 25 selected source pins and four admission supplements. These are not
a complete compiler-input manifest. The recorder START toggle completed at
`16:55:56.806 UTC`; STOP was refused by fresh deadline checks before any UI key
was sent. Automatic recording finalization/archive and video review require
separate qualification.

The guardian closed the held original process at `17:05:20.5278456 UTC`; two
later CIM checks found no isolated process. No collision-recovery, backward
motion cause, broad handling, physical-controller feel or 9.5 likeness claim is
made. [Run 299's short measured response](2026-10-22-departure-remount-switch-299.md)
remains separate evidence.

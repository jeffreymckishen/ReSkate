# Post-upstream BMX switching and riding checks

The merged build completed five ordinary bike-to-skateboard-to-bike cycles in
trial 308. Trial 309 also verified ordinary parking, a fresh natural remount,
and a short pedal/brake/park sequence. Its two collision approaches produced
no fall, so post-upstream GetUp and fall recovery remain untested. These results
do not establish BMX Streets likeness or resolve the earlier 293/294 failures.

## Source and build

The upstream agent fetched official ReSkate main at
`45346b122c911c8c4dcd2bbfb4ef86f5fd621b7f` and preserved both histories in
`929520e05c550228a421b43754c9a49b1ae78fff`. The private grip-marker work was
then merged as `897a647cdbb9e19a9ded38aa24f322028772e88c`, the clean source HEAD
used for the primary Release build and both native trials.

The MSVC all-target Release build and full primary CTest run passed:
191 tests passed and one trainer tuning-name test explicitly skipped because
that CTest configuration had no game-data root. The canonical watchdog and
all three grip-marker test suites passed. A separate direct run against the
actual isolated game data returned exit 0, with 3,801 named values, zero unnamed
values and 89 curves. That direct run supplements the skipped CTest case.

Built and deployed isolated runtime:
`0855D8652E434100DD0632FCADC07A104BA4460AB9D1C8EA2DFB2EAD00C34874`.
Only `build/bmx-game` was used for Skate testing. The ordinary profile selected
neither private pose experiments nor the long ride trace.

The independent source/resource/build judge scored its scoped engineering
checkpoint 9.5/10. BMX Streets likeness remains unscored. The final DLL contains
the legacy reference geometry resource; actual native bike rendering depends
on the external BMX prototype pack. Trial 309's startup status separately
reported eight of eight native parts and matching completed placement revisions.

## Trial 308: five native round trips

PID 39296 / creation FILETIME 134371818507585199 completed ten separate,
nonce-gated controller legs. Each submitted 301 reports: 283 neutral, eight LB
and ten LB+Y. All 3,010 reports passed the unchanged 120 ms scheduling guard;
maximum lateness was 65.8917 ms. Every leg verified final neutral, disconnect
and worker exit. The declared discovery bootstrap was additional input.

Every forward leg observed native 103 followed by 100, with current qualifying
100 dwell of 2.266666532 native seconds and 2,265–2,281 wall milliseconds.
Owner, body, cleanup counters and released leases qualified. Every first rejected
guard was null and every forward BUSY count was zero. Every reverse observed
standable/offboard 504 before a fresh natural bike mount, progressing through
tokens 2–6. These were low-speed admission cycles; zero speed throughout the
session was not established.

Nine live endpoint screenshots were saved. The final live screenshot was missed
near the 600-second deadline. A separate bounded recording review decoded 827
local frames and independently confirmed the final mounted bike endpoint in
the recording. It does not qualify transition smoothness or fine hand contact.
The endpoint-only review scored 9.0/10, separately from likeness.

## Trial 309: ordinary remount and measured riding

PID 46064 / creation FILETIME 134371831718190843 used the same runtime. The
closed profile preflight found explicit No Bail=false and Dark Pop=false in a
coherent database-plus-WAL copy. Trainer override storage was absent. These
are persisted-state and loader checks, not exhaustive native settings readback.

The right and straight approaches each submitted 100 pedal reports in a
301-report leg. Both ended with the rider still mounted. No collision fall or
GetUp was accepted as evidence. The later native tail had already overwritten
those approach input windows, so their native pedal response is unqualified.

An ordinary Y press parked the bike. A second ordinary Y press beside the bike
completed natural mount token 2. The subsequent four-second departure leg
submitted 201 reports and ended in an ordinary park. All five controller legs
completed with final neutral, disconnect and worker exit: 1,405 reports total.

The retained 240-sample departure trace includes 60 actual pedal samples and
60 actual brake samples, with focused/available device 1, no input
neutralization and submitted native commands. Its 239 successor witnesses
matched the producer command serial, application, force and torque. Pedaling
raised signed body-forward speed from -0.037785 to +2.466148 m/s through the
last pedal command's successor. Braking reduced +2.473741 m/s to approximately
0.000000188 m/s longitudinally; 3D residual speed was 0.031283 m/s at that
brake endpoint. This supports the bounded pedal/brake behavior, not complete
rest or BMX Streets physics parity.

The successor witnesses establish command submission; body velocity supplies
the observed response. This does not isolate the physics engine's integration
of those forces from its other forces and contacts.

An initial visual suspicion of filtered or reversed pedal input was not
supported by that trace. Negative world X/Z velocity matched the bike's
observed forward basis. No speculative input or basis fix was made.

Both guardians terminated their exact held game process at the deadline and
verified it signaled twice. Separate root CIM checks then found no isolated
game and no old-PID matches. Complete before/after profiles, controller ledgers,
native JSON, logs and recordings were preserved locally.

## Evidence and remaining work

Local ignored receipts retain the full identities and verification boundaries:

- `build/bmx/primary-resource-build-independent-review-v1/independent-primary-admission.json`
  — `6783630A71879D414D29A67B9DF16A6148A901A4D16E01889EEA020DCF02AA7E`.
- `build/bmx/primary-resource-build-independent-review-v1/real-data-tuning-addendum.json`
  — `BBA0535C7040564A9B00860745C51294BF75202B6BB2AA21EEA5C887B4FC40AD`.
- `build/bmx/overnight-review20261021/human308-independent-review-v1/final-native-controller-audit.json`
  — `978D90730515F31D13F18F17A9936DCBF01A18D5AB8531C40E2E0A1393483224`.
- `build/bmx/overnight-review20261021/human308-independent-review-v1/tail-video-independent-addendum.json`
  — `8F2042FBB83DEA9630B0BE6B2932FF20140AC12889AEF1E233E130C53FC8B9C6`.
- `build/bmx/primary-resource-build-independent-review-v1/input309/input309-audit.json`
  — `A7874C66E5D40D3124CA9FB802D321B71757EE3BF79C19FC489FE0E2F2BA44C5`.
- `build/bmx/overnight-review20261021/human309-independent-review-v1/final-native-controller-composite-audit.json`
  — `BD3E2C965E966F0B1275A2B4E537F3AA7FCFCEEA6E3ECBAA4B643CF0F07B3565`;
  its referenced `departure-signed-native-audit.json` verifies the successor response.

Remaining native checks are post-upstream collision/GetUp recovery, moving
skateboard actions and interrupted switching, rendered hand/grip alignment,
and a reference comparison with BMX Streets assists verified off. Private
grip markers are compiled and source-tested but were not armed in either trial.
No 1:1 or 9.5 likeness claim follows from these engineering results.

# Short departure, ordinary remount and switching — run 299

Run 299 retained a short pedal/left-steer/brake departure followed by ordinary
Y park, a fresh Y remount, and one BMX → skateboard → BMX roundtrip in
`Ride -NativeChassis -HumanNativeSwitch` mode. PID `49716`, creation FILETIME
`134371584421575965`, used runtime SHA256
`B087931D6BE6656EE7D3DC0BE0829A1083DCA60A6D77B2A4D429357ABC0B59C4`.
This run predates the later typed clock-BUSY observation change.

Four separately gated controller sessions submitted 1,104 scheduled reports:
201 for the fixed departure/park sequence, then 301 each for remount and the two
switch directions. The departure contained one second of A with stick X `-.45`,
200ms coast, one second of B, then one 200ms Y tap. Each session ended with
neutral release, disconnect and parent-observed worker exit. Bootstrap operations
are additional; driver submission alone does not prove game consumption.

Unlike [run 297](2026-10-22-departure-capture-297.md), the retained 240-row token1
trace covers the action: native seconds `105.066660..109.049994`, including 60
pedal and 60 brake samples with available, focused, unneutralized device1 input
and submitted commands. The independent producer-aligned calculation pairs
commands with the following native velocity sample: pedal speed changed from
approximately `0.2587` to `2.2491 m/s`, then brake speed from `2.2536` to
`0.0274 m/s`; final speed was about `0.00825 m/s`. COM net displacement was
`1.80003 m`, with `2.56982 m` sampled path length. These measurements qualify
this short response; acceleration was not constant and individual force
contributions were not isolated.

The native log records ordinary park, then natural remount token2. Forward
generation1 observed native103 followed by100 and approximately `2.2667`
native seconds / `2,281ms` wall dwell. Reverse generation2 observed native504,
followed by natural BMX remount token3. Both first-rejected-guard receipts were
null. These are one successful roundtrip and one ordinary parked remount;
earlier run293/294 failure causes remain unresolved.

The [native/controller audit](../../../../build/bmx/human-controller299/independent-native-controller-review.json),
SHA256 `7025A4391DE220E0042D8F7FF56C56F9627F4B446B702D480BA27CFF1B029A7C`,
verified 80 frozen files, 20 source pins and three movement/parent supplements.
Its numerical findings come from original telemetry. The reviewer authored the
departure wrapper and transport fix; independent source review is a separate scope.

The preserved video source/copy SHA256 is
`4A6FC6F1002F8253EEF1F925B02970B8BFD690B8FB6177F049EFF2A7279E2EC6`.
Five bounded windows contain 126 selected frames from 2,015 locally decoded
frames. Independent contact-sheet review shows the short approach relative to
nearby posts, stop and upright park, fresh leg-over remount, skateboard and BMX
endpoints, and final mounted BMX. The [visual packet](../../../../build/bmx/human-controller299/video/human299-targeted-visual-review.json)
pins exact frame PTS/hashes separately from native measurements. No full-file
PTS validation, exact native-clock/scanout join or transition-quality score is claimed.

The guardian closed the original held process at `16:10:44.0921481 UTC`; two
later CIM observations found no isolated process. This scoped result does not
qualify sustained riding, collision/carrying, fall recovery or postfall remount,
physical-controller feel, broad switching reliability, or 9.5 BMX Streets likeness.

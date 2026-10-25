# Combined Follow and force checkpoint — 2026-10-25

A private Luau trial completed body Follow, one force command and both required
acknowledgements on the same owned body. This closes the gap between the separate
Follow and force trials in the [earlier checkpoint](2026-10-25-native-follow-force-checkpoint.md).
Public mounting and the [Core](../bmx-plugin/plugin/bike_runtime_core.lua) and
[Ride](../bmx-plugin/plugin/ride_runtime.lua) composition gates remain disabled.
The bike is not yet qualified for riding; BMX Streets likeness remains unmeasured.

The trial used isolated Skate build 20260929, PID 19460 / creation FILETIME
`134374296062399649`, with runtime SHA256
`EAFD2EFB9D0A25CD2957998D6527F55BCB82A7509AA3E3C07675E178117C6E4D`.
This is the pre-existing runtime compiled from the then-current whole C++ worktree,
not a binary rebuilt solely from the later Lua checkpoint. All trial behavior is
Luau. Exact deployed sources and receipts are preserved in the
[verified archive](<E:/RESKATE DEV/ui-follow-one-force-m3-native-pass-v3-20261025T1927Z/ARCHIVE-PINS.json>).

One arm created one body, handed it to Follow, reserved and published once, then
submitted one horizontal magnitude-106 force with zero torque and no impulse.
The actual applied receipt advanced request serial 1776 → produced 1777 → coherent
successor 1778, sequence 1. One force ACK returned true. One Stop was accepted;
the actual terminal Follow receipt was `completed`, final and returned revision 9,
in-flight 0, no pending revisions, `park_observed=true`, reason `cancelled`.
One Follow ACK returned true. Both acknowledgements preceded the eight returned
void visual-remove calls; no ordinary second body release was attempted.
[Raw copied ledger](<E:/RESKATE DEV/ui-follow-one-force-m3-native-pass-v3-20261025T1927Z/attempt/storage-after-first-arm.json>).

The saved [done/ACK view](<E:/RESKATE DEV/ui-follow-one-force-m3-native-pass-v3-20261025T1927Z/attempt/done-both-acks.png>)
shows completion, and the [subsequent camera view](<E:/RESKATE DEV/ui-follow-one-force-m3-native-pass-v3-20261025T1927Z/attempt/post-cleanup-view.png>)
shows no obvious BMX assembly. Void removal returns and one camera view do not
prove per-object destruction or scene-wide absence. The terminal receipt explicitly
keeps `native_retirement_known=false` and `claim_known=false`; park/ACK does not
establish exhaustive native retirement or ownership semantics.

The configured Follow interval was an at-most-500 ms cap, with an earlier stop
150 ms after force submission or 100 ms after the first Lua-seen applied receipt.
This run ended through the latter deadline. Exact active Follow duration was not
persisted. Eight fresh measurements, serials 1777–1784, recorded final horizontal
displacement 0.0019107026 world units and forward velocity about 0.01666666577 while
vertical position fell from 201.3141632 to 201.1943817. Force units, causal response
and grounded rolling remain unproved. This was a falling-body integration trial,
with no mounting, switching, rider alignment, fall recovery or handling comparison.

A separate guarded controller check on the same game owner completed 301 scheduled
neutral reports over six seconds. Maximum elapsed-minus-planned lateness was
24.2255 ms, below the unchanged 120 ms refusal threshold. Its bootstrap also sent
one explicit left-X one-LSB probe and two neutral reports; the entire session was
not exclusively neutral. Child PID 24856 / creation FILETIME
`134374297361752121` exited 0, with neutral release and disconnect successful.
Skate device selection, input consumption and native quality remain unmeasured.
This check ended before the M3 arm and was not a controller-driven riding test.
[Controller ledger](<E:/RESKATE DEV/ui-follow-one-force-m3-native-pass-v3-20261025T1927Z/controller/controller.jsonl>)
and [exit receipt](<E:/RESKATE DEV/ui-follow-one-force-m3-native-pass-v3-20261025T1927Z/controller/exit.json>).

The held game process later exited 0 at 19:26:33.5123400Z after Root requested
Alt+F4, without Root forcing termination. The complete saved shutdown log contains
no “did not finish closing” or “ending it” watchdog warning; this is a log
observation, not proof of every internal shutdown mechanism. The earlier PID 54848
attempt remains a separate unknown-exit result with a watchdog warning.
[Held exit receipt](<E:/RESKATE DEV/ui-follow-one-force-m3-native-pass-v3-20261025T1927Z/attempt/held-process-exit.json>)
and [complete shutdown log](<E:/RESKATE DEV/ui-follow-one-force-m3-native-pass-v3-20261025T1927Z/runtime/ReSkate-complete-shutdown.log>).

Independent review rated this bounded native evidence **9.4/10**, with no likeness
score. The separate `1b5e57f` Lua/Host checkpoint received **9.3/10** for source
engineering and passed its targeted plugin build and one `plugins` CTest at the
unchanged 50 ms call / 2 ms tick defaults. That constructed check included disclosed
whole-worktree test diagnostics; it is not an index-only or gameplay result.
[Native evidence review](<E:/RESKATE DEV/ui-follow-one-force-m3-native-pass-v3-20261025T1927Z/attempt/INDEPENDENT-REVIEW.md>).

Primary SHA256 pins:

- Actual copied M3 ledger: `0B95DB9A4F281ED393610C9C3B05F6C29D26FB85C8279915145459A620288F5F`.
- Deployed entry: `CDE16437224A1A95F16C2C5A689338C5166C76FA372CD7A1C5D988BA70424999`.
- Deployed combined model: `CCD31ABD6D6E5F9DEB0FA937C7F8B6641C2A37542E75910339DBECD16AAC641E`.
- Canonical controller source: `B0B78C74B77D1651188BFC5A1AC71E362A45BB5F1FAEA3AE25F2946C0E1D8986`.
- Controller ledger: `76A452F4766E556A33DD2EBA24A71EC626F0E3F5EFF640C0162E79451B1E9C0C`.
- Held game exit: `F8512A44CA1B0F63E7AD7D97DBEE12847920A7972825786830F4FC750023B14A`.
- Complete shutdown log: `4C1EE410B9B1F523274D4997468B417E9BD8FD43FB37CFFB736FD485C6447B3B`.
- Archive file pins: `73395C196835F227D74035C6B6C74898A87A9396691FAE7677F63D61E235EE62`.

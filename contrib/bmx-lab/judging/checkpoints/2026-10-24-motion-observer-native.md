# Actor motion observer: refusals and an Arm timeout — 2026-10-24

V1 reached two admission refusals. V2 timed out before calling the observer API.
Neither trial qualified actual mover observation, mounted Lua bike riding,
reliable bike/board switching, rider alignment or fall recovery. BMX Streets
likeness remains unscored; the requested 9.5 has not been established.

## Focused API checkpoint

[Commit receipt](../../../../build/bmx/native-motion-refresh-integration-v1/commit-checkpoint-v2/commit.json)
records pushed BMX commit `f96ba723c333d1287cf9d8bba1296cb9fa71a9d1`:
13 general API/support/test paths and the [mod-author guide](../../../plugin-motion-refresh-probe.md).
BMX behavior stays in Luau; C++ provides general SDK support. The old native
BMX prototype behavior remained disabled for these observer trials.
The Release runtime built with `/W4 /WX` on parent `b1446540` plus those 13
frozen code paths; the final documentation-only phrase followed the build.
Final freeze `476488A7` / [execution](../../../../build/bmx/native-motion-refresh-integration-v1/execution.json)
`8C5C8144` bind World Service 19 groups / 524 checks with zero native mutations.
The first five-group run preserved an older Lua fixture's 50ms budget failure;
an unchanged quiet plugin retry passed 1/1 in 6.63s. Contention was not proven.
Eight new Host groups ran 73 constructed cases, with ten source-bound wrapper
checks separately passing. The private [trial Host run](../../../../build/bmx/motion-refresh-lua-trial-host-validation-v1/execution.json)
passed eight groups / 20 constructed scenarios. These are code tests, not native results.

Both trials used runtime `D022359D` / launcher `2D18248C`, matching that code.
V1 updated the isolated pair and preserved the prior `EBA86093` / `659E8528`
rollback on E:. V2 retained D022/2D18 and separately preserved that pair as rollback.
Module-path and disk-hash receipts do not supply an in-memory image hash.

## V1: independently reviewed admission refusals

The [V1 ledger](../../../../build/bmx/actor-motion-refresh-native-v1/storage-final.json)
records `begin=2`, `poll=0`. Both calls completed `pcall`, returning nil and a reason:
`native motion observation waiting for deferred read-only clock setup; begin again explicitly`,
then, after one separate authorized Retry,
`native motion observation waiting for an actual attested mover hook entry`.
The original 120s Arm deadline was retained. No opaque probe or copied DTO returned.
The second combined availability gate does not identify which condition failed;
it precedes helper-prefix, actor and native-clock validation. It proves no clock
failure, universal absence of mover calls, or on-foot cause.

[Independent V1 review](../../../../build/bmx/actor-motion-refresh-native-v1/independent-outcome-review.json)
`5D257215` accepts the bounded refusal evidence, with native observation unqualified.
Its sampled 600ms/ten-tick Lua readiness guards were not native-clock proof.
Saved frames show the rider on foot carrying a board; no causal comparison followed.
The verified [V1 archive](../../../../build/bmx/actor-motion-refresh-native-v1/archive-location.json)
contains 58 leaves, verification `B69CAF21`, including evidence and preserved rollback;
originals remain. This supersedes the earlier private draft's pending review/archive status.

## V2: stock-board preparation, then zero API calls

Before Arm, guarded [Y](../../../../build/bmx/actor-motion-refresh-native-v2/pad-native-y.jsonl)
and [A/left-stick](../../../../build/bmx/actor-motion-refresh-native-v2/pad-ground-pump.jsonl)
sessions completed 181 and 161 scheduled reports. Both ledgers report successful
neutral release and removal/disconnect wrappers; `input_consumed` remains null.
Saved [image metadata](../../../../build/bmx/actor-motion-refresh-native-v2/screenshots.json)
and frames show the stock skateboard under the rider after Y and later board
activity. Driver submission and sampled images do not prove which native consumer
used those reports, continuous state, mover attestation, or BMX switching.

The actual [V2 ledger](../../../../build/bmx/actor-motion-refresh-native-v2/storage-final.json)
`34866A73` stopped with `arm_timeout`, `begin=0`, `poll=0`, terminal ready samples 0;
last sampled focus reported the interface open. The original 120s watchdog ran
before API admission. Root reports missing the menu-close window during context
continuation; the saved source/counters establish the stop, not an independently
timed continuation or exact Arm instant. There is no V2 native refusal, opaque
probe, DTO, actor record or routing result to classify.

The [V2 owner](../../../../build/bmx/actor-motion-refresh-native-v2/owner.json) records
PID `16776` / creation FILETIME `134373077459242921`, on D022/2D18.
[Closure](../../../../build/bmx/actor-motion-refresh-native-v2/closure.json) `0E45DFE9`
and [final log](../../../../build/bmx/actor-motion-refresh-native-v2/runtime-final.log)
`101027A0` record normal Alt+F4, owner-PID native Shutdown25, elevated CIM zero
game processes, exact manifest withdrawal and zero active manifests.
Two storage cache calls are not two independent durable-write witnesses;
the actual final disk ledger is retained. The [independent V2 review](../../../../build/bmx/actor-motion-refresh-native-v2/independent-outcome-review.json)
`9E75AF8F` confirms an operational timeout before API admission. Image metadata
records archive times; the earlier armed frame was saved after context continuation,
so its save time is not a fresh capture time. The verified [V2 archive](../../../../build/bmx/actor-motion-refresh-native-v2/archive-location.json)
contains 72 leaves, verification `22583311`, with originals and rollback retained.
Neither spent trial was rearmed or overwritten.

The observer requested no body, force, follow, mount or recovery action.
Pre-Arm HID preparation was separate. No native consumer completion, lifetime
pin, target retirement or follow authority is established. The remaining gate
is a separately admitted observation under unchanged bounds, not a parity upgrade.

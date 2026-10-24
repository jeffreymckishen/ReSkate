# Passive synchronization routing — 2026-10-24

Native V3 recorded synchronizer hook traffic but retained no match for the
selected four packet slots. Mounted Lua bike riding, reliable bike/board
switching, rider alignment and fall recovery remain undemonstrated. BMX Streets
likeness remains unscored; the requested 9.5 has not been established.
The earlier [contact/input](2026-10-24-lua-contact-and-input.md) and
[input/passive](2026-10-24-lua-input-and-sync.md) documents remain historical.

## Implemented and tested source

SDK commit `319ae483` changed five general API/support paths. Its
[full Release execution](../../../../build/bmx/sync-probe-routing-integration-v1/execution.json)
passed; the actual Service target passed 14 groups / 374 checks. Selected CTests
were 91/92: unchanged `bmx_recovery_leg_python` still refused the stale controller
source hash. Its guard was neither bypassed nor repinned; this is not an all-green run.
Lua commit `64e60ed9` changed six paths. The separate normal
[Host execution](../../../../build/bmx/passive-sync-routes-host-integration-v1/execution.json)
passed 1/1 plugin CTest, including 17 actual Host/VM cases with constructed native
facts; 15 optional fixtures were absent. These counts are not additive native coverage.
All BMX behavior remains Lua; routing counters are general permissioned diagnostics.

## V2 preserved its original watchdog failure

The [V2 failure audit](../../../../build/bmx/passive-sync-native-v2/independent-outcome-review.json)
`76BF8AEC` verifies that the original 120-second Arm watchdog stopped the trial
before any create, read, begin, poll or release call: all five counts were zero.
There was no accepted release or routing result. Root reported compaction delay;
the saved evidence does not independently time compaction or the exact Arm instant.
The verified [V2 archive](../../../../build/bmx/passive-sync-native-v2/archive-location.json)
contains 22 planned leaves and four screenshots, verification `03A150F1`.
V2 was not reset or rearmed.

## V3 observed entries, then expired without mapping

Fresh V3 main `DE27AEBC` differs from tested main `8B86AB19` only in package ID,
run UUID, storage key and menu page. Reversing those four identities restores
the exact tested bytes: [source equivalence](../../../../build/bmx/passive-sync-native-v3/source-equivalence.json).
The [package source review](../../../../build/bmx/passive-sync-native-v3/review.json)
`80A9779A` and separate [operational source review](../../../../build/bmx/passive-sync-v3-operations-review-v1/review.json)
`D2C01BD2` have distinct scopes; neither is a native outcome verdict.

The saved [owner](../../../../build/bmx/passive-sync-native-v3/owner.json) binds
PID `34956` / creation FILETIME `134372977822948605` to runtime `EBA86093` /
launcher `659E8528`, SDK freeze `C68894F5` / execution `FD098512`.
This is module-path and disk-hash evidence, not an in-memory image hash.
The [persisted result](../../../../build/bmx/passive-sync-native-v3/storage-final.json)
records two creates: the exact known preallocation refusal, then one explicit retry;
two reads, one begin, 11 polls and one accepted release. Cleanup-unknown was false.
No force, HID, follow, pose or recovery request ran. Release acceptance does not
establish native parking, destruction, reusable-slot availability or target retirement.

The first terminal result was `expired`: mask 0, four absent rows, rejected 0,
dropped 0. Raw routing was `entries=358`, `other=357`, `expired_entries=1`,
`matches={0,0,0,0}`, `already_recorded=0`. These are independent saturating lower
bounds: no cross-field sum/order guarantee or universal zero-call inference follows.
Positive entries establish recorded hook traffic; absent records do not establish
selected-wrapper mapping, transform/flag/closing-epoch agreement or native consumption.
The context body advanced from serial `2383` / time `39.71666429936886` to
`2448` / `40.79999756813049`; this does not identify it as a retail packet body.
Final Lua poll elapsed was `1083.7674000263214ms`, not the exact native begin/expiry clock.

The [closure](../../../../build/bmx/passive-sync-native-v3/closure.json) `CE8444AD`,
persisted storage `81BC28BE` and [runtime log](../../../../build/bmx/passive-sync-native-v3/runtime-final.log)
`34819CF8` retain the raw result. Root recorded normal shutdown, zero game processes,
exact manifest withdrawal and zero active manifests. The
[independent outcome audit](../../../../build/bmx/passive-sync-native-v3/independent-outcome-review.json) `894023CB`
confirms narrow routing activity without qualifying the selected four packets.
The verified [V3 archive](../../../../build/bmx/passive-sync-native-v3/archive-location.json) contains
29 planned leaves and six screenshots; C: originals and the EBA/659 rollback remain.
Verification `9D49C392` records planned source/target bytes and hashes matching,
with no moves, deletions or overwrites. The audit's earlier archive-pending text is historical.

## Next diagnostic gate

Identify the wrapper classes and call sites behind recorded synchronizer traffic,
then qualify the probe's four-slot identity domain against them.
This checkpoint admits no dispatch change, deadline widening, force, target
publication or follow activation. Exact-target retirement and mounted gameplay
remain separate gates; positive hook traffic does not establish BMX parity.

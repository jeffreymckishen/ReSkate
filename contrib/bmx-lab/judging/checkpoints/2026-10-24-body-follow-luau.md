# General body-follow SDK and Luau bindings — 2026-10-24

The general owned-body follow service and permissioned Luau API compile and pass
their focused code checks. No mounted Lua BMX bike, reliable bike/board switch,
rider alignment, fall recovery or BMX Streets likeness score has been established
by this checkpoint. BMX behavior remains in Luau; C++ supplies general SDK support.

## Change and ownership contract

The SDK joins a VM-owned measured body to the local actor through the existing
fingerprinted actor callback. Attachment geometry comes from the mod. The API
requires both `world.physics` and `world.physics.follow`, uses owner-bound opaque
handles, and supplies reserve, publish, read, stop and acknowledge operations.
Its one receipt slot and nonrenewable three-second lease support a bounded trial,
not sustained riding. Publication does not change equipment or renew the lease.

Stop retains unfinished work. Published SDK completion requires actual stop/drain,
dependent-body release, matching park and exact actor-claim retirement. A live
caller then explicitly acknowledges the receipt. Clean never-published abandonment
leaves the caller's body separately owned. Authenticated VM cleanup retains unknown
duty and cannot transfer an old handle to a replacement VM. Completion never claims
that all native consumers forgot a copied pose: `native_retirement_known` stays false.

General optional SDK writers now participate in the actor-control exclusion.
Current motion-observer behavior, teleport queue locking and the existing portable
body-follow policy remain preserved. No additional game build or game address was added.

## Build and regression results

The normal full Release build passed with `/W4 /WX`. Runtime `4735191F` and launcher
`9191A1C5` were built on `dd50b3da` plus the frozen implementation changes; this is
a source-composition identity, not a claim that a later commit SHA was compiled.
The isolated game still has `D022359D` / `2D18248C`; the new pair was not deployed
or loaded for this checkpoint. Full hashes and commands are in the
[normal execution receipt](../../../../build/bmx/follow-full-integration-v1/checkpoint-review-prep-v1/execution-receipt.json).

The first focused CTest run passed 88 of 89 tests. `plugins` failed because its
new fake cleanup handler overwrote the first cleanup-order observation when Host
destruction closed it again. A test-only idempotence correction preserves the first
observation, including failure. Its independent source review accepted that change.
The plugin-only rebuild and retry then passed 1/1. These are separate attempts;
the original failure is retained. Fifteen absent optional sample mods were skipped.
The follow Host fixture ran eight groups / 26 constructed scenarios, plus seven
separate C++ eligibility assertions. The unchanged portable ownership test passed
895 checks with zero native actions. None of these counts is an in-game result.

## Composed SDK execution

The private composition uses a 17-translation-unit harness and one canonical SDK
source tree. Its first link failed on a duplicate scripted query
already supplied by the actual Profile implementation. Removing only that test
duplicate allowed the incremental link; the original failure and object were
preserved. Sixteen objects and nine libraries from the first build were reused,
and only the World test object was rebuilt. They are not labeled fresh second-build
dependencies. CRT startup was audited before execution; cold boundary calls fail the test.

[The final test receipt](../../../../build/bmx/follow-current-fixture-target-v2/test-receipt.json)
records 26 fresh processes, one execution each, all passing: 334 checks, no timeout
or cold-boundary exit. Coverage includes transform forwarding, writer exclusion,
stop/drain and matching park, clean abandonment, receipt reuse, stale handles,
orphan cleanup, identity changes, failed park, unknown holds and exceptional-return
debt. The older nine-case result remains seven passes / two failures; its fixture
assumption corrections and changed SDK completion contract are recorded separately.

These executions use constructed native-provider facts. They install no retail
hook and establish no native pose-history consumption, actual rider coupling,
controller suppression coverage or gameplay parity. The next game trial must bind
its own package, fresh storage, process and deployed runtime identities.

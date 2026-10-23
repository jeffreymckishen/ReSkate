# Stock equipment interruption diagnostic

This fixture tests the unchanged production Lua equipment adapter. It is inert
until one menu Arm, uses slot 0 only, and can call `skater.wipeout(0.5)` once.
It does not activate BMX, recover the rider, synthesize another input path or
relax any production readiness/deadline rule. One mode consumes the fresh VM.

## Package the exact production sources

Create a fresh private package from this directory. **At packaging time only**,
copy these repository files beside `plugin/fixture.lua`:

- `../bmx-plugin/plugin/equipment_runtime.lua` → `plugin/equipment_runtime.lua`
- `../bmx-plugin/plugin/equipment_transition.lua` → `plugin/equipment_transition.lua`

Hash both source files before and after packaging and require byte-identical
copies. Do not commit or maintain forks in this fixture. The sandbox cannot
require modules from another installed package. Source/Host tests must likewise
load the actual fixture with exact production module copies in one test package.

Use a fresh installation folder/plugin storage identity for **each** case, with
empty storage. The first Arm consumes the VM even if refused. Any existing
storage key blocks the fixture without overwriting old evidence. The ledger's
`id`/`run_id` are provenance labels, not native identity or crash-durable locks.
An accepted storage write is Host-cache acceptance; archive the later disk
snapshot before admitting another case. Source preparation is not game admission.

## Explicit modes

| Mode | Required starting state | One permitted interruption |
| --- | --- | --- |
| A: baseline | Grounded board `100`, known not ragdolled | Once the production adapter reports `baseline` and zero input requests, queue one wipeout. Coverage also requires actual fall evidence, zero input requests through failure, and no qualified transition. |
| B: post-terminal | Grounded on foot `504`, known not ragdolled | Mount through the production adapter. Only in `settling`, on board `100`, after an exact clean `released` terminal receipt, stored receipt and acknowledgement, queue one wipeout before the 2.5-second suffix qualifies. |

Keep the validated slot-0 source neutral and close the menu after Arm. Preserve
the original 60-second adapter Arm and its 15-second intent/cleanup rules. The
fixture observes at most 75 seconds overall and five seconds after its wipeout
call. A missed window, refusal, exception, storage fault or missing witness is
**NOT COVERED**; no retry or automatic recovery occurs.

Wipeout `true` only accepts a queue request, which has no VM-owned cancellation
handle and can expire or be refused later. Coverage requires a later valid
watch showing state `300`, known ragdoll, or an increased wipeout count, with a
present local player/skater in the same nonempty sampled level as the fire
snapshot, plus a production attempt whose final reason is `fall_observed`.
Post-fire missing reads, level/presence changes or lost focus/readiness latch
NOT COVERED; a later good sample cannot repair the boundary. These Lua checks
do not prove native actor identity or semantic causality.

The ledger key is `equipment_interruption_v1`. It retains immutable full window
and terminal receipt snapshots, first fall facts, a full final adapter snapshot
when cleanup resolves, and at most 64 projected sample rows. Encoding is capped
at 50,000 bytes; capped rows are marked, and storage faults invalidate coverage
even at the final save. A failed write cannot retract an older cached record;
compare the current diagnostic status with the archived ledger.
Samples are Lua observations, not a native global-step trace.

Qualification stopping never stops adapter ticking: the single already-armed
production attempt keeps its original cleanup/watchdogs. It may still have
pending work; a diagnostic stop is not cancellation or rollback. Historical
coverage freezes at that boundary while later cleanup snapshots keep updating.
Unload delegates
to the production adapter, and SDK VM-close handling retains real cleanup debt.

Before native admission, compile/load the actual package and test inert startup,
both initial-state guards, one-shot behavior, observed fall versus queue
acceptance, missed windows, receipt preservation, storage failures/bounds and
continued cleanup after a diagnostic stop. No build, installation, HID or native
execution is claimed by this source fixture.

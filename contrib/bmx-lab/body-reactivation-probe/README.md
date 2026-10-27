# Body-only reactivation diagnostic package

This private diagnostic package is tracked at
`contrib/bmx-lab/body-reactivation-probe`, initially committed as `5b7a643a`.
Its first draft was authored outside the checkout without executing project code.
Subsequent pure-Luau tests passed. OFF Host validation found one test expectation
error; its correction awaits rerun, and ON execution remains pending. The dated
evidence and remaining execution checks are listed below.
MainRoot owns OFF/ON builds, tests and any isolated deployment.

Source API basis: integrated `6fb77a09`, including the private diagnostic
introduced by `3a51a7cc`. Record the final runtime build identity separately;
a source checkpoint or pure test result is not a binary provenance receipt.

## Purpose and limits

One explicit operator-approved experiment creates one original capsule body,
reads it, then requests one park/reactivate/repark cycle at its immutable creation
pose. There is no rider attachment, Follow, force submission, board operation,
input control, teleport, retry of create/begin, replacement allocation or reusable
body result. The `input` permission is used solely for `input.focus()` observation;
there is no `input.control`, lease, capture or HID operation.

The location check is deliberately **bounded ray samples plus explicit visual
approval**, not a capsule overlap test, complete volume-clearance proof, streaming
proof or native contact qualification. Current `world.probe` has no region/actor
identity fence. `skater.get` and `level.current` provide no actor generation or
world generation: the harness compares fresh observed level name, on-foot state,
position, heading, focus and menus. The provider's native identity and
supported-build checks still apply; no actor generation is synthesized by Lua.
Process ownership is external to this package.

A successful cycle proves neither repeated mounting, changed-pose contacts,
absence of old-pose contacts, more than eight reuse cycles, dependent-consumer
retirement nor destruction. `native_retirement_known` stays false.

## Files and permission scope

- `reskate-plugin.json`: client API 1; namespace is the enclosing deployed folder.
- `plugin/main.lua`: documented API adapters, action panel and bounded storage.
- `plugin/probe.lua`: private lifecycle state with an injected API seam.
- `plugin/probe_tests.lua`: synthetic source tests; never loaded by main.lua.

The diagnostic requires both `world.physics` and
`world.physics.qualify_body_reactivation`. `world.raycast` supplies explicit
hit/clear/unavailable rays; `skater.read`, `menu` and read-only `input` gate actions;
`storage` preserves copied receipts. No extra native permission or raw handles
are introduced. The injected callbacks are a test seam, not a native API or a
way to choose a native owner, run ID, eligibility flag or transform at begin.

## Preconditions for a later operator run

1. Root must hold the exact isolated game/deployment execution slot. Existing
   Root integration/build/test ownership is not such a grant. Honor HID-HOLD and
   preserve all other work/packages.
2. Run and retain normal OFF and qualification ON Release build/test receipts.
   ON means `DINGOSDK_BODY_REACTIVATION_QUALIFICATION=ON`; it includes the API but
   does not arm it. OFF must omit the API and reject its permission. Retain the
   missing-permission, server, foreign/forged/reloaded handle, package/profile,
   consumed-arm and cleanup failure tests. Synthetic tests are not native proof.
3. Seal exact source/tree, CMake options, executable hashes, this five-file
   inventory, active plugin inventory, isolated profile and operator scripts.
   Do not reuse or relabel S2c/R3 hashes as this diagnostic's build. No startup
   admission literals need changing in these source files.
4. Proposed isolated game: `C:\Users\Jeffr\Desktop\reskate\build\bmx-game`.
   Supported Skate SHA256 is
   `FBCE74D5E28EF525DBBA2CB4ADBEBC13405BDBD88F31BC940BCA45E4AE88B8F9`.
   Proposed existing data root:
   `C:\Users\Jeffr\Desktop\reskate\build\bmx-user-data-luau-native-body`.
   Preserve it and prior packages; use only a reviewed noncompeting plugin inventory.
5. Proposed new deployed directory and plugin ID:
   `C:\Users\Jeffr\Desktop\reskate\build\bmx-game\Mods\LuaBodyReactivation_20261027_q1`.
   Proposed external evidence directory:
   `E:\RESKATE DEV\body-reactivation-native-20261027-q1`.
   Both are proposals, not created or approved deployment receipts.

Before any plugin starts, the operator must supply these exact values using the
resolved canonical native path strings. A normal profile or alias/mismatch must
refuse, never fall back:

| Environment | Required value |
| --- | --- |
| `RESKATE_BODY_REACTIVATION_QUALIFY` | `1` |
| `RESKATE_BODY_REACTIVATION_ROOT` | Canonical isolated data root above |
| `RESKATE_DATA_ROOT` / `--dev-data-root` | Same isolated data root |
| `RESKATE_BODY_REACTIVATION_PLUGIN_ROOT` | Canonical new deployed directory above |
| `RESKATE_BODY_REACTIVATION_PLUGIN_ID` | `LuaBodyReactivation_20261027_q1` |
| `RESKATE_BODY_REACTIVATION_RUN_ID` | `body-reactivation-20261027-q1` |

The sandbox cannot read these launch values. The labels in main.lua are external
expectations only, recorded with `external_environment_and_process_pins_verified=false`.
Successful begin is the provider's gated admission, not a fabricated Lua arm.
Record fresh launcher PID, game PID plus creation FILETIME, executable/module
paths and hashes, inherited arm values, launch UTC and final exit. Old PID 39960
and S2c's spent namespace must not be adopted. No launcher/process code is included.

## Operator action sequence

- Stand still on foot (observed state 504) in an open isolated scene. Open the
  panel and choose **Prepare once**, then close the interface. This queues one
  prepare call on a focused gameplay tick with both interfaces closed. Cold
  setup can return pending: a later explicit click may recheck, at most eight
  clicks in this VM. There is no automatic prepare retry. Warm-up is not native
  qualification. A ready result permits only the separate survey action.
- Choose **Measure candidate**. One candidate is measured three metres along the
  current actor heading. Five downward rays sample the floor at its centre and
  half-metre offsets, refusing missing/unknown hits or more than 30 mm height spread.
  Creation position is exactly one metre above the centre floor hit. The original
  shape is one capsule from `(0,0,0)` to `(0,0.2,0)`, radius 0.1 m, mass 12 and authored
  inertia `(2,3,4)`, with identity rotation. Its surveyed horizontal margin is 0.75 m.
- The survey adds 24 horizontal obstacle diameters at floor heights 0.35/1/1.65 m
  and nine vertical segments. All 33 must be explicitly clear, never nil. Each
  tick casts at most eight rays; the whole 38-ray survey is bounded to 500 ms.
  These finite segments can miss intervening geometry: Root must visually inspect
  the displayed exact candidate and surrounding scene, with generous margins.
- Within 15 s, choose **I visually approve this candidate**, then close the interface
  and remain still. This authorizes only the displayed candidate. It does not
  transfer to a new location. Every reviewing tick and the approval itself check
  context; observed invalidity stays refused even if it later recovers.
- A fresh survey repeats the same rays at the same X/Z, requiring the floor to
  remain within 10 mm; creation stays at the original approved position. Actor
  movement beyond 50 mm, heading change beyond 0.03 rad, level/menu/on-foot/focus loss,
  unknown rays, stale approval or API binding change refuses. No replacement survey
  or second candidate is created. Entire refresh must be <=500 ms old at allocation
  and begin; completion is <=100 ms old at create. Read admission is <=250 ms old.
- One create is attempted; on the following tick, one coherent ordinary read and
  one begin are attempted. Physics-provider refusal ends this attempt. The body
  never acquires a dependency or normal command debt. The target is its immutable
  native float creation definition, not the latest measured pose.

## Receipt and stop semantics

The pure module polls once per tick after begin. The provider's deadlines are
2,000 ms for activation and 3,000 ms for cleanup. A local 4,000 ms **tick-observed**
watchdog retains unknown cleanup; it is not independent of Lua/game ticks. The
external operator must watch the exact process and retain a stalled-run outcome.

A nil/error poll or first failure does not unload the plugin or discard the probe.
Failure may still be pending while cleanup is owed. Stop before begin releases an
owned ordinary body at most once, recording only release acceptance. Stop after
begin prevents a success claim but keeps polling; there is no public probe cancel
API. Ordinary release cannot repark an admitted retained body and is never used
as its finalizer. An unknown begin outcome is not retried.

Success requires terminal observed status, confirmed cleanup, no cleanup owed,
no first failure, one planned cycle and ten passing ordered stage records with
later park/dynamic epochs. Masks must be categories 0, collisions 257 while active
and 0 when parked. Parked XYZ velocities and pending forces/torques must be zero;
the angular fourth lane is recorded without interpreting it. The transform stage
must match the original creation target; later gravity motion/repark need not.

Receipts are bounded plain copied data (vectors become arrays; epoch serials stay
exact decimal strings; no body/probe userdata). Main writes at transitions or at
most once a second, with a 60,000-byte encoded limit, under `body_reactivation_q1`.
Existing storage refuses the run and is preserved. `storage.set` has no return
value; accepted storage is not disk-durability proof. Preserve exported storage,
logs, screen observations and hashes before unloading. Unload loses probe access;
unconfirmed cleanup requires Root to end the exact isolated process, never retry
or assert native destruction. Collect process exit separately from park evidence.

## Validation evidence and remaining work

Evidence snapshot: 2026-10-27. Keep these separate qualification levels:

- **Pure Luau: PASS, 21 cases / 7,788 assertions.** Root ran `probe_tests` with
  the pinned vendored-Luau runner; exit code 0, `native_calls=0` and
  `game_evidence=false`. Durable external receipts are
  [body_harness.log](<E:/RESKATE DEV/codex-reports/root-extra-validation-20261027T1752Z/body_harness.log>)
  and [results.json](<E:/RESKATE DEV/codex-reports/root-extra-validation-20261027T1752Z/results.json>).
  The receipt records runner SHA256
  `AC92AA044E439C3E00D90D5F5A9B4AF80E0C25416FEA28D38CBDF0523264B385`
  and the exact module hashes. This executed constructed pure fixtures, without
  the plugin Host, permissions, Host time limits or game. Although `main.lua` was
  included in the hash inventory, this result does not validate its Host entry.
- **Actual-main Host smoke: SOURCE GO.** Independent reviewer
  `geometry_contract_review` reviewed the test committed as `1326a7af` in
  `Extension/Plugins/Test/plugin_tests.cpp`, SHA256
  `3F31E9EA765D7D48935542FE04A8B20D3E5018D142C555D9F0A839C99743FAB2`.
  The test loads the tracked package unchanged, exercises explicit cold Prepare,
  a constructed 38-ray survey, waiting without visual approval, Stop and stored
  unload receipt. It checks zero attempted body/reactivation/Follow/input
  authority. Its default-OFF branch requires unknown-permission rejection before
  entry or provider dispatch. This source review did not execute those assertions;
  the subsequent execution status follows.
- **OFF at `23c3e903`: normal full build PASS; SDK 329 passed, 1 failed, 1 skipped.**
  The plugin suite failed its new assertion after `host.apply({})`: it incorrectly
  expected no cleanup bookkeeping for a manifest-rejected candidate. The
  [full SDK log](<E:/RESKATE DEV/worktrees/port-validation-20261027/evidence/23c3e903f0fbce225e2927ec1369927af026724b-full/sdk-tests-20261027T1814328254849Z-8ba9e1fd.log>)
  preserves that failure. `Host::unload` always releases the candidate name;
  `FakeGame::release` records one released ID and one `entities clear` call even
  when rejection prevented VM creation. Only that post-unload expectation was
  corrected. Pre-dispatch checks, all authority guards and the no-storage-ledger
  check remain unchanged. Independent reviewer `geometry_contract_review` gave
  SOURCE GO for corrected `plugin_tests.cpp`, SHA256
  `ED8F1EF5BD4590F70EB9C5C1F087FBE04ADC34E770E19E19AAD9B4240CAE7936`.
  **The corrected OFF test has not been rerun; this is not a full-suite pass.**
- **ON at `23c3e903`: pending.** Root's qualification build and 25 SDK tests were
  still active at this snapshot. No passing result is inferred from active work
  or an earlier SDK test run.
- **Native/game trial: pending.** Exact runtime/package/profile/process pins,
  operator visual approval, native timing and cleanup evidence remain required.
  No test above establishes native reactivation or repeated mounting qualification.

Root must retain fresh OFF/ON compilation and Host smoke results before any
native trial, including real API/UI behavior and bounded serialization/timing.
There is no package verification/launch script here and no native outcome claim.
Never infer the user's 9.5 BMX Streets likeness target from this mechanism experiment.

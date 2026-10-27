# Body-only reactivation harness draft

SOURCE ONLY / UNRUN, 2026-10-27. This folder is outside all checkouts and is not
installed. MainRoot owns subsequent review, checkpoint, OFF/ON builds, tests and
any isolated deployment. No generator, parser, import, test, build or game was
run to author this draft. Source API basis: integrated `6fb77a09`, including the
private diagnostic introduced by `3a51a7cc`. The final runtime build identity
must be recorded separately; this statement is not a binary provenance receipt.

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

## Validation remaining

All synthetic cases and parser/Host/runtime checks are UNRUN. Root must bind a
runner to these exact files, run probe_tests independently, review real API/UI
behavior and validate bounded serialization and timing. There is no package
verification/launch script here and no native outcome claim. Never infer the
user's 9.5 BMX Streets likeness target from this mechanism experiment.

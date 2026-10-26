# BMX takeover runbook

This is the handover for whoever continues the BMX branch. It records what the evidence shows at
HEAD `2584bcd` ("BMX Lua: composer review fixes for freshness wording, torque and line anchors",
also `origin/BMX`), how to run the tests, where evidence lives, the in-game procedure that last
worked, and the next three in-game trials.

Nothing here claims riding or BMX Streets likeness. The Lua package cannot be ridden yet, and no
likeness score has been awarded under either rubric. In-game evidence still does not include
mounted riding, grounded rolling, wheel ground support, switching through Lua, rider alignment on
the bike or likeness.

Sources: the checkpoints listed under [What the game has shown](#what-the-game-has-shown), the
terrain probe results
`build\bmx\claude-handoff\to-claude\terrain-probe-trial-20261025T2130Z\RESULT.md` (r1) and
`build\bmx\claude-handoff\to-claude\terrain-probe-trial-r2-20261025T2202Z\RESULT.md` (r2), the
static actor-exclusion research in `build\bmx\actor-exclusion-research-v1\` (`STAGE-2.md`,
`STAGE-3.md`, `STAGE-4.md`), the [stationary rider observer](stationary-anchor-observer/README.md),
and the receipts named below. Everything under `build/` is gitignored (`.gitignore:1` is `/build/`),
so those paths exist only on the development machine. `E:\RESKATE DEV` is the evidence drive. Every
path cited below as evidence was checked to exist on 2026-10-25 at about 21:50Z, except the terrain
probe r2 paths, the operator copies on `E:` and the Mods folder, which were checked at about 22:25Z.
The SHA-256 of every file named here with one was recomputed between 21:38Z and 21:50Z, and the r2
files and the binary table again at 22:28Z; runtime hashes quoted for past trials come from their
receipts and checkpoints. Files that the next trials are still to create are named as such. Line
numbers refer to HEAD `2584bcd`.

## Where things stand

- **Not rideable.** `RIDE_COMPOSITION_QUALIFIED=false` (`bmx-plugin/plugin/bike_runtime_core.lua:12`)
  and `ACTIVATION_QUALIFIED = false` (`bmx-plugin/plugin/ride_runtime.lua:3`). Both date from
  `49ae4d3` and nothing public opens them. `main.lua` builds the runtime with no options, so
  `qualification_only` is false, and a Mount click (`bmx-plugin/plugin/main.lua:70-73`) gets
  "Native bike lifecycle qualification unavailable" from `bmx-plugin/plugin/bike_runtime.lua:122`
  before any game call (the core refuses with the same text at `bike_runtime_core.lua:837`). The
  page shows that text under "Last mount click" (`main.lua:96`), whose initial value is
  "Unavailable: native lifecycle qualification has not completed." (`main.lua:6`).
- **Core ride prerequisites are committed but unrun.** `3e686fc` makes Core build Ride with no
  trick adapter, reserve Follow with `cleanup="owned_body"` and `motion_policy="callback_entry"`
  (`bike_runtime_core.lua:674-675`), require `probe_batch`, `submit`, `receipt` and `acknowledge`
  before any body exists (`bike_runtime_core.lua:399`, `bike_admission.lua:128`), and stage Ride,
  Contact and their dependencies at mount (`bike_runtime.lua:11-14`). The ride path stays
  unreachable while the gates are false, and the tracked core has never run in game.
- **Manifest.** `bmx-plugin/reskate-plugin.json` asks for `input`, `input.control`,
  `input.lease`, `input.capture`, `skater.read`, `menu`, `storage`, `world.physics`,
  `world.physics.follow` and `world.entities`. It has no `world.raycast` and no `camera`.
- **The proven in-game packages are private.** CE2's `first_follow_core.lua` lives only in
  `build\bmx\callback-entry-follow-ce2-package-v2\`. Codex's M3 and M4 packages are sealed on `E:`
  (see below), and their trial modules are not in the repository.
- **The newer pure modules are committed and unwired.** Bail, grinds and rail probe, manual
  balance, rider and trick presentation, camera, input presets, the simulator, the rubric metrics
  and the ride composer are listed with their commits and counts in
  [bmx-plugin/README.md](bmx-plugin/README.md#modules-committed-since-aad4248). None is loaded by
  `main.lua`, and none has run in game.
- **The next SDK needs** are actor-safe wheel contacts, a general per-read probe batch budget and
  sustained Follow. [INTEGRATION_PLAN.md](bmx-plugin/INTEGRATION_PLAN.md) lists every blocker.

### What the game has shown

All on the supported build 20260929, with the native BMX build options off. The checkpoints are
in `judging/checkpoints/`, except the two Follow and force checkpoints of 2026-10-25, which are in
`judging/` itself.

| Trial | What was observed | Evidence |
| --- | --- | --- |
| Force7 | Lua created one owned body and sent one zero-force, zero-torque command, queued then applied (serial 140354 to 140355). Follow revision 1 completed, park observed, acknowledged. 301 and 1,001 neutral reports. | [Luau native transport checkpoint](judging/checkpoints/2026-10-25-luau-native-transport.md) (`aad4248`) lines 26-56; `E:\RESKATE DEV\native-force-cleanup-trial-v7-20261025T055804419Z` |
| CE1 | Follow with the `callback_entry` policy returned 30 of 30 revisions. The bike was visible beside a standing rider. Cleanup failed: `retained_unknown`, `pending=[body_parked]`, no acknowledgement. | Same checkpoint, lines 58-79; `E:\RESKATE DEV\callback-entry-follow-trial-ce1-20261025T062525536Z` |
| CE2 | PID 63876. Follow returned 31 of 31, park observed, acknowledged. Input drained with no report debt. Eight visual-removal calls accepted. The Board return was refused before GO (see below). | Same checkpoint, lines 93-206; `E:\RESKATE DEV\callback-entry-follow-trial-ce2-20261025T075707911Z\priority-attempt-result-v1\actual-result.json` |
| Stationary anchors | PID 57708. Standing still on foot with the overlay open, one Capture completed 32 pose reads and 14 finite joints in 280.16 ms. Its warm pass first read every one of the 14 joints as nil (`warm_nil` 14); the reads after a two-tick settle were all finite. The joints are separate last-evaluated world copies, not a body-relative calibration. | `E:\RESKATE DEV\stationary-anchor-observation-20261025T101842799Z\storage-after-capture.json` (SHA-256 `D5596B5A…`); [observer README](stationary-anchor-observer/README.md) |
| Separate visuals, Follow and force | PID 40988. Two static bike trios rendered upright, and after six void removal calls the same view showed them absent. A Follow alone completed at revision 24, park observed, ACK. On another body one magnitude-106 force was applied (serial 105143 to 105145) and acknowledged; that body's park was not observed. A separate neutral controller diagnostic failed at 1,141 ms lateness. | [Native Follow, force and visual checkpoint](judging/2026-10-25-native-follow-force-checkpoint.md) (`7b12f43`) |
| M3 | PID 19460. One body under Follow took one horizontal magnitude-106 force with zero torque and no impulse: applied receipt (1776 to 1778), force ACK, Follow completed at revision 9 with park observed, Follow ACK, then eight removal calls. The body fell from Y 201.314 to 201.194. Independent review: 9.4/10 bounded native evidence, no likeness score. | [Combined Follow and force checkpoint](judging/2026-10-25-combined-follow-force-checkpoint.md) (`588f930`); `E:\RESKATE DEV\ui-follow-one-force-m3-native-pass-v3-20261025T1927Z` |
| M4 | PID 15648, namespace `LuaUIInputFollowOneForceM4_20261025_r1`. As M3, plus one observe-mode input lease on XInput user 0 (21 reads, 19 renewals, released, ACK). Applied receipt 4189 to 4191; all three ACKs before the removals. The body fell from Y 201.314 to 201.219. Independent review: 9.4/10, no likeness score. | [M4 input, Follow and force checkpoint](judging/checkpoints/2026-10-25-m4-input-follow-force-checkpoint.md) (`4b75b2a`); `E:\RESKATE DEV\ui-input-follow-one-force-m4-native-pass-v1-20261025T2044Z` |
| Terrain probe r1 | PID 20772. Refused before creating a body: the first `skater.joint("root")` returned nil. See below. | `build\bmx\claude-handoff\to-claude\terrain-probe-trial-20261025T2130Z\RESULT.md`; `build\bmx\terrain-probe-actual-v1\` |
| Terrain probe r2 | PID 25760, namespace `LuaTerrainActorProbe_20261025_r2`. The joint warm-up worked: root, hips, spine and head each read nil once (`warm_nil` 4), then finite. One diagnostic body was created, and one `terrain` batch with `exclude_local_actor=false` came back `available` with `native_casts` 6. All six rays were clear, both floor rays included, so there is no positive floor control. Release accepted; phase `done_retained`. Review HOLD. See below. | `build\bmx\claude-handoff\to-claude\terrain-probe-trial-r2-20261025T2202Z\RESULT.md`; `build\bmx\terrain-probe-actual-v2\`; `E:\RESKATE DEV\terrain-probe-native-all-clear-v2-20261025T2202Z` |
| Alignment r3 | PID 2812, namespace `LuaRiderBikeAlignment_20261026_r3`. The eight-part bike rendered upright beside the sampled rider, then between the rider's legs pointing the rider's way, from `reskate.entities.set` with numeric ids 101-108 and 201-208; Stop removed all 16. No body, Follow, force or bone write. Wheel-to-floor contact and seat fit were not measured. | `build\bmx\alignment-actual-v3\RESULT.md`; `E:\RESKATE DEV\alignment-native-r3-20261026T0155Z` |
| S1 category probe P1 | PID 29704, namespace `LuaS1CategoryProbe_20261026_p1`, runtime `E21F6710…` (BMX `4613baa6`). Verdict `P1_PASS_CANDIDATE`: Q1-Q3, Q6, Q7 and Q8 pass. The `camera` preset hit the MPR floor at y 274.361 with `in_categories` 0x00002FF0 (no named-actor bit). The production request (camera plus `require_named_actor_categories_absent`) was available with `named_actor_categories_absent=true` and 3 floor hits at T0 and at T30. `all` rays through the rider hit the rider proxy 0x10000040 and the local skater shape 0x04001008, neither of which shares a bit with camera, and camera rays on the same segments stayed clear. The zero-command body was still falling at T30, so S8 is unanswered. | `build\bmx\s1-p1-actual-v2\RESULT.md`; `E:\RESKATE DEV\s1-p1-native-20261026T1339Z` |

"M3" and "M4" are Codex's trial labels. They are not the milestones M3 and M4 of
[INTEGRATION_PLAN.md](bmx-plugin/INTEGRATION_PLAN.md#milestone-status-at-2584bcd), which need the
tracked core with the gates flipped in a trial copy.

Not shown in game: mounted riding, grounded rolling, wheel ground support, a force on a body
standing on the floor, calibrated force units, a mounted rider pose, rider alignment on the bike,
bike-to-board switching through Lua, fall recovery through Lua, tricks, grinds, a BMX camera, a
floor hit from a `terrain`-preset ray, local actor exclusion, and any likeness score. P1 showed a
`camera`-preset floor hit and a rider-free production wheel request, on sampled segments only. The retired
C++ prototype's in-game runs are history, not evidence for the Lua mod.

### The terrain probe r1 refusal at 21:25Z

Terrain probe r1 was meant to answer whether `query_preset="terrain"` rays hit the rider. Its one Arm, at
21:25:15.921Z, reached `done_no_body` with detail `joint pose unavailable`: the first
`reskate.skater.joint("root")` call succeeded and returned nil. The source stops at the first
missing joint, so hips, spine and head were not sampled, no body was created and none of the six
planned rays (front and rear floor, an upward control, and hips, spine and head crossings) was
cast. The rider was on foot and stationary in MPR. Both storage copies are byte-identical, SHA-256
`8DC0ABB43F7BF5AEA09D777565DCA6480C201AFC67A9047D20CD2FC4630763A5`. The game was closed with an
ordinary Alt+F4 and exited 0 at 21:29:03Z. The copy-only archive
`E:\RESKATE DEV\terrain-probe-native-refusal-v1-20261025T2130Z` holds 53 payloads with no
mismatch (`ARCHIVE-RECEIPT.json` beside the result). The closing review
(`build\bmx\terrain-probe-actual-v1\INDEPENDENT-REVIEW.md`) is HOLD. Namespace
`LuaTerrainActorProbe_20261025_r1` is spent.

A plausible cause, not tested: `Extension/Skater/skater_animation.cpp:1182-1201` registers a joint
request on the first `joint` call, publishes it, and returns only a sample that has already
arrived, so a first call can return nil. The stationary capture is consistent with that: its
warm pass read nil for all 14 joints and its later reads were finite. Terrain probe r2, below,
warmed up first, and each of its four joints read nil once and then finite. That also fits this
cause, but neither run proves it.

### Terrain probe r2 at 21:58Z

Terrain probe r2 asked r1's question again, with a joint warm-up first. Its source is sealed in
`E:\RESKATE DEV\chat-2-reskate-bmx\terrain-preset-actor-probe-v2`, and its one-use operator is
`build\bmx\terrain-probe-operator-v2\`. The launch was at 21:55:58Z, game PID 25760, and the one
Arm at 21:58:30.936Z, with the rider standing on foot in MPR. The warm-up took eight reads in
50.03 ms: root, hips, spine and head each returned nil once (`warm_nil` 4) and then a finite
pose. Those samples were discarded, and fresh poses were captured for the body and for the query.
The probe created one 1 kg capsule beside the rider, read it once, and cast one batch of six rays
with `query_preset="terrain"`, `exclude_local_actor=false` and `require_contact=false`. The batch
came back `available` with `native_casts=6` and `local_actor_excluded=false`, and every row was
`clear`, with no fraction, normal or body token.

That includes the two floor rays, cast straight down 3 m from Y 276.553 to Y 273.553 while the
rider's root joint read Y 275.311. With no floor hit there is no positive control, so the clear
hips, spine and head rays say nothing about whether terrain rays miss the rider. `RESULT.md`
leaves the cause of the misses open: ray placement, the terrain mask or native query semantics.
The terrain question is still unanswered, and r2 proves nothing about actor exclusion.

The one release returned true, the receipt after it was an empty FIFO with `retained=true`, and
the phase ended `done_retained`; exact park and destruction are unproven. No force, Follow or
rendered entity was used. Both storage copies are byte-identical, SHA-256
`A778B4ED63173C8F4C9D6CC000C0C05979D5F00ADBA7F65C27782C5AF103488C`. The game was closed with one
ordinary Alt+F4 at 22:01:36Z and exited 0 at 22:01:41Z. The copy-only archive
`E:\RESKATE DEV\terrain-probe-native-all-clear-v2-20261025T2202Z` holds 57 payloads with no
mismatch (`ARCHIVE-RECEIPT.json` beside the result). The closing review
(`build\bmx\terrain-probe-actual-v2\INDEPENDENT-REVIEW.md`, SHA-256 `D94E2832…`) is HOLD.
Namespace `LuaTerrainActorProbe_20261025_r2` and its operator are spent.

### Actor exclusion: static research

`exclude_local_actor=true` still returns `local_actor_exclusion_unavailable` before any native cast
(`contrib/plugin-body-query.md:52-53`; `Extension/World/owned_bodies.cpp:1178`), and every riding
lane demands it. Read-only analysis of the supported `Skate.exe`, in
`build\bmx\actor-exclusion-research-v1\`, found that the native query compares shape-owner indices
against an ignore list (`STAGE-3.md`), that the nominated skater-creation query passes an empty
ignore list, and that the body and shape owner extractors feed one owner-handle constructor
(`STAGE-4.md`). A complete current local-actor owner set is not yet producible from that evidence,
so no SDK change follows. `STAGE-2.md` rejects an earlier owner lead. Terrain probe r2 adds
nothing here: its batch did not ask for exclusion, and with no floor hit its clear rays say nothing
about the rider.

### The CE2 board refusal at 08:51:28Z

The receipt (`actual-refusal.json` in `...\stock-board-return\attempt-v1-refused\` of the CE2 case,
`utc` 2026-10-25T08:51:28.0410119Z) records `publication_refusal: "ready age exceeded 40000 ms"`,
`go_published: false`, `scheduled_reports: 0`, neutral release and disconnect both true, and
`cached_board_pending: true`, for PID 63876.

What happened, from the operator folder
`build\bmx\ce2-stock-board-return-operator-v1\controller-gate\` (steps 1, 3 and 4) and Codex's log
as read by the scouts (steps 2 and 5):

1. The driver wrote `start-gate\ready.json` at 08:48:28.25Z.
2. The gate call came back with no output after its 10 s yield. A resume call plus a screenshot
   took about 22 s, so the Arm click came at about 08:49:14Z.
3. `publish-go.ps1` refused: "Ready is outside the <=40s publication window" (`publish-go.ps1:45`).
4. The driver timed out at its 60 s limit: `stdout.log` says "Start trigger read exceeded
   deadline/clock", 0 reports.
5. The Board intent then expired 60 s after Arm.

That run also exposed a Lua bug. The page showed "Board intent cancelled" (screenshot
`build\bmx\ce2-board-intent-cancelled.png`), while saved storage still had `board_pending=true`.
In `build\bmx\callback-entry-follow-ce2-package-v2\candidate\follow\plugin\first_follow_core.lua`,
`persist(false)` skips the save when the last one was under 200 ms ago yet returns true (lines
131-133), `board_tick()` clears `board_pending` on cancel without a forced save (lines 476-478), the
tick's only save is `persist(false)` (line 573), and the next tick returns early (line 495), so the
cancel is never saved.

The tracked core had the same pattern. `ad1516e` and `3587d78` now save the lifecycle ledger when a
stock transition finishes or expires, even inside the throttle. That is constructed-test evidence
only (`bike_runtime_core_persist_tests` 5 / 78, `runtime_progress_fault_tests` 1 / 12). The private
successor `build\bmx\callback-entry-follow-ce2-package-v3\` carries the same kind of fix for the CE2
core; its README says it was tested only on the pure runner and has not been deployed.

### Eight body slots per process

The World backend allows at most eight body allocations per game process and keeps parked bodies. A
parked body cannot be reused (`Extension/World/owned_bodies.cpp:744`, "the eight retained body slots
are exhausted; native destruction is unproven"). Failed and partial attempts also use up a slot.
Unloading the plugin VM does not give slots back, and native destruction is unproven. So every
body-creating trial spends one slot for that process, and repeated trials need a fresh process.
Resetting counters or reviving retained bodies would not count as a supported lifetime path.

### Fresh VM for spent intents

Prep, Follow and Board each arm once per plugin VM:

- Follow Arm is refused when a storage ledger already exists: "Existing or unreadable ledger blocks
  this package" (`first_follow_core.lua:460-462` in the CE2 v2 package). Every run therefore needs a
  new mod namespace and storage key. The M3, M4 and both terrain probe runs each used a fresh
  namespace.
- Board is offered only while `board_eligible()` holds, which needs a completed and acknowledged
  Follow with no live Follow or body (lines 471-474). Board is also one-shot through
  `board_intent_used` (lines 584-591).

### Machine state

At 17:00Z on 2026-10-26 no `Skate.exe` or `ReSkateLauncher.exe` was running. Every lifetime since
M3, including alignment r3 and P1, ended with an ordinary close and exit code 0, with a held-exit
receipt in its evidence folder. Two mod folders in `build\bmx-game\Mods` have an enabled
`reskate-plugin.json`: `LuaS1CategoryProbe_20261026_p1` (spent) and
`LuaUIOnlyParkPrepare_20261025_v4` (Prep V4, which every run since M3 armed first). Each
deployment since the terrain probes moved the previous probe's manifest into its own evidence
folder (for example `build\bmx\s1-p1-actual-v1\spent-alignment-r3-reskate-plugin.json`). Retire the
spent P1 manifest the same way before the next run; `build\bmx\m1-operator-v1\launch-m1.ps1` does.
The CE2 operators' `Assert-SpentDisabled` (`common.ps1:57`) refuses any other enabled mod folder,
and their `Assert-Ce2Closed` (`common.ps1:110`) expects closure receipts that the CE2 lifetime never
got; a CE2-derived run needs a revised operator.

The isolated game has run `ReSkate.dll` `E21F6710…` since P1. It was built from BMX `4613baa6`
(the S1 SDK set and the upstream merge to `3d706383`); it has no renewable Follow (S2, `5ec1fd90`).
The previous runtime is kept byte-exact as `build\bmx-game\ReSkate.dll.EAFD2EFB.bak`.

SHA-256 values, re-hashed at 17:00Z on 2026-10-26:

| File | SHA-256 |
| --- | --- |
| `build\bmx-game\Skate.exe` | `FBCE74D5E28EF525DBBA2CB4ADBEBC13405BDBD88F31BC940BCA45E4AE88B8F9` |
| `build\bmx-game\ReSkate.dll` | `E21F67106D3DDB57A1C73509361FDC6C0EE8A87AE86FC4F1300008AE07B00B56` |
| `build\bmx-game\ReSkate.dll.EAFD2EFB.bak` | `EAFD2EFB9D0A25CD2957998D6527F55BCB82A7509AA3E3C07675E178117C6E4D` |
| `build\bmx-game\ReSkateLauncher.exe` | `E4B0AE99637C018C386ED2117BAC85E6CA0CEAE044574EA7CBB6162C66D0DA55` |
| `contrib\bmx-lab\Bmx-VirtualGamepad.py` (since `475028f4`; M1 and every earlier run used `B0B78C74…`) | `802642A2C13C48DEEAC36B6B3B18ACD46A98701D513FC4C7C3EA014CEEA9F065` |
| `build\bmx\gamepad-setup\dependency-verification.json` | `635314F50ECE83E1456ED5E4A0318DBF6BD51CBD2006355865145979C310DB67` |

Alignment r3 also ran on `EAFD2EFB…`, and P1 on `E21F6710…`. The PID 40988 trials, M3, M4 and both terrain probes all ran on runtime `EAFD2EFB…`. The M3
checkpoint describes it as compiled from the whole C++ worktree of that time, not rebuilt from
the later Lua commits; which commit's C++ it matches is not recorded in these receipts. Force7 ran
on `4B7BD8D7…` and CE2 and the stationary capture on `3B25624D…`. Re-hash before relying on the
table.

The driver row is the checkout's driver at 17:00Z. M1's package pins it, so the checkout keeps
`B0B78C74…` until M1 has run. The tracked driver has moved on since `0d3dbd3b` (TOOL-1(b) and
TOOL-2). With the start-gate requirement for its new scenarios it hashes to
`802642A2C13C48DEEAC36B6B3B18ACD46A98701D513FC4C7C3EA014CEEA9F065`; re-hash and re-pin the row when
the checkout moves to it. Two older pins match neither driver: `Bmx-SwitchLeg.py`'s
`APPROVED_BASE_SHA256`, which the six `Test-Bmx*Leg.py` suites check, and
`Bmx-CoupledVirtualTest.py`'s `APPROVED_DRIVER_SHA` (asserted by `Test-BmxCoupledVirtualTest.py`
and quoted in `coupled-virtual-test.md`). Both are `3F756CE2…`, the driver at `5975efd8`, and have
been stale since `ec0b8ea8`, so those wrappers and their suites refuse today's driver.

What the driver work leaves open (details in [virtual-gamepad.md](virtual-gamepad.md)):

- **TOOL-1(b) stays open.** `pedal-straight` refuses until `PEDAL_LEAD_MS` is set from TR-M1's
  measured lead, and the two `3F756CE2…` pins are re-pinned in the change that sets it, because
  setting it moves the driver's hash again.
- **TOOL-2 is partly done.** `neutral-window-30s` serves M6e and `pause-menu-20s` serves M6c only;
  `ride-10s` (M6f) and `ride-s01-30s` (M6g) refuse until the lead is set. M6d's overlay event is not
  covered, since the overlay opens only from the keyboard and the driver sends no keyboard input.
- **The 30 s timelines end 30 s after go**, before a 30 s window opened at publication closes. That
  is open with COORD and the owner.
- **The two ride input profiles** are the driver author's proposals; JUDGE or the owner accepts them
  before M6f or M6g is judged.

## Running the tests

Constructed tests prove model and sandbox behavior only. They are never in-game evidence and never
earn a rubric score.

### Pure Luau runner

The fast runner is private:
`build\bmx\parallel-tricks-presentation-proposal-v1\harness\build\Release\presentation_luau_tests.exe`,
SHA-256 `B1B76FC23C32B8E46D6FDF39022385197EF012713C02E84DAA73BFAACA6AD559`. It runs vendored Luau
with `require("./x")` limited to one folder, calls `<module>.run()`, prints
`presentation_luau_tests: module=M cases=N assertions=K` and exits 0 on success. It has no
`reskate` API and no time limits. With no folder argument it uses its own proposal folder, so always
pass the folder:

```powershell
& 'C:\Users\Jeffr\Desktop\reskate\build\bmx\parallel-tricks-presentation-proposal-v1\harness\build\Release\presentation_luau_tests.exe' `
  'C:\Users\Jeffr\Desktop\reskate\contrib\bmx-lab\bmx-plugin\plugin' equipment_runtime_tests
```

Most modules take tens of milliseconds and runs can go in parallel. To rebuild the runner, configure
`build\bmx\parallel-tricks-presentation-proposal-v1\harness` into your own folder with
`-G "Visual Studio 17 2022" -A x64 -DRESKATE_REPO_ROOT=C:/Users/Jeffr/Desktop/reskate`, then build
Release.

**Receipt at HEAD.** On 2026-10-25 at 21:39Z this runbook's author took the 77 tracked files of
`bmx-plugin/plugin` at `2584bcd` out of git with `git archive` and line-ending conversion off (all
77 blob hashes checked) into a folder under the session's temp directory, and ran every tracked
suite there. All 31 passed, 668 cases and 479,538 assertions in total:

| Module | Cases | Assertions |
| --- | ---: | ---: |
| `tests` | 12 | 1,216 |
| `equipment_tests` | 7 | 309 |
| `equipment_runtime_tests` | 13 | 260 |
| `equipment_transition_tests` | 32 | 2,538 |
| `force_tests` | 23 | 217 |
| `lease_source_tests` | 43 | 178 |
| `recovery_tests` | 18 | 379 |
| `recovery_runtime_tests` | 22 | 533 |
| `ride_input_tests` | 52 | 247 |
| `ride_input_mapping_tests` | 42 | 321 |
| `rider_alignment_tests` | 21 | 3,494 |
| `trick_tests` | 16 | 371 |
| `bike_runtime_core_persist_tests` | 5 | 78 |
| `runtime_progress_fault_tests` | 1 | 12 |
| `contact_runtime_preset_echo_tests` | 32 | 91 |
| `core_ride_staging_tests` | 2 | 130 |
| `bail_policy_tests` | 21 | 1,430 |
| `camera_policy_tests` | 20 | 57,198 |
| `grind_policy_tests` | 15 | 1,019 |
| `input_presets_tests` | 13 | 99,231 |
| `manual_balance_tests` | 28 | 11,915 |
| `rail_probe_tests` | 25 | 477 |
| `ride_composer_tests` | 27 | 72,222 |
| `rider_presentation_tests` | 27 | 12,226 |
| `rubric_metrics_tests` | 16 | 3,933 |
| `sim_tests` | 12 | 208,006 |
| `trick_presentation_tests` | 18 | 866 |
| `trick_runtime_tests` | 28 | 431 |
| `ride_runtime_tests` (fixture) | 48 | 128 |
| `ride_runtime_join_tests` (fixture) | 4 | 16 |
| `ride_runtime_b10_b16_tests` (fixture) | 25 | 66 |

The three fixture suites require `ride_runtime_qualified_fixture.lua`, which the Host generates by
copying `ride_runtime.lua` with `local ACTIVATION_QUALIFIED = false` changed to `true`
(`Extension/Plugins/Test/bmx_contact_runtime_host_fixture.inc:16-22`). For the pure runner, do the
same in a second copied folder, never in the tracked tree; the receipt above did, and the copy
differed from `ride_runtime.lua` only in that line. Without it, all three fail on the missing file.
The Luau runner below stages it for you. `equipment-interruption-trial/plugin/fixture_tests` needs
`bmx-plugin` modules beside it and only runs in the Host. Keep the copied folder's path short: from
a 292-character folder (module paths of about 300 characters) every module once failed with
"canonical: The system cannot find the path specified" although the files existed, and the same
files passed from a short folder under `%TEMP%`. The Windows 260-character path limit is the likely
cause.

Outside `bmx-plugin`, the tracked observer has its own pure suite, which neither the Host nor the
Luau runner runs. At 21:39Z, from `git archive 2584bcd`:

```powershell
& '<runner>' '<copy of contrib\bmx-lab\stationary-anchor-observer\plugin>' sampler_tests
# presentation_luau_tests: module=sampler_tests cases=46 assertions=104
```

Run against the live tree to test your own change; use an archive copy like the one above for a
HEAD receipt. The older totals (341 cases and 10,115 assertions over 14 suites at `aad4248` and
`8ac7917`, and "286 cases / 5,778 assertions" from a private 71-file snapshot) are superseded.

### Luau runner (tracked CTest)

[`luau-runner/`](luau-runner/README.md) (`10445a3`, staging rules in `fac039c`) builds the same
vendored Luau into its own tree and registers every `bmx-plugin/plugin/*_tests.lua` and `tests.lua`
as a CTest named `bmx_lua.<suite>`. It builds no SDK target, so it works while the main tree is
mid-build. From a Developer PowerShell at the repository root:

```powershell
cmake -S contrib/bmx-lab/luau-runner -B build/luau-runner -G "Visual Studio 17 2022" -A x64
cmake --build build/luau-runner --config Release --parallel 2
ctest --test-dir build/luau-runner -C Release --output-on-failure
```

Before each run that needs it, `bmx_lua.stage_qualified_ride` copies the plugin's modules into
`build/luau-runner/qualified-plugin/` and writes the qualified fixture there, so the three fixture
suites run against that copy. Eight `bmx_lua_runner.*` tests check the runner's own boundaries and
its staging refusals. `ctest -V` shows each suite's counts.

Its last run in this checkout passed 39 of 39 tests at 19:49-19:50Z on 2026-10-25
(`build\luau-runner\Testing\Temporary\LastTest.log`): 30 suites, the staging test and the eight
runner tests, against the working tree of that time. That run predates `3e686fc`, so it is not a
HEAD receipt. At `2584bcd` the glob finds 31 suites, so the next build reconfigures and registers 40
tests. It was not built or run for this runbook.

### Host suites (CTest `plugins`)

`dingosdk_plugin_tests.exe` runs the real plugin Host. It reads the Lua files from the source tree
when it runs (`RESKATE_SOURCE_DIR`, `CMakeLists.txt:586`), so a Lua edit needs no rebuild; a change
to `plugin_tests.cpp` or an `.inc` fixture does. It runs every case and cannot run one alone. The 15
"skipped: contrib/plugins/… is not on this machine" lines are expected.

BMX cases and their counts, from the receipt
`E:\RESKATE DEV\park-diagnostic-normal-20261025T065911109Z\ctest.stdout.log` (2026-10-25 06:59Z,
sources pinned in its `context.json`; `plugins` passed in 15.55 s). That receipt is older than
every commit since `aad4248`. Later commit messages report the `plugins` CTest passing
(`ad1516e` also lists runtime 13 / 260, persistence 5 / 78, fault 1 / 12 and contact 48 / 128 from
a combined working tree; `3e686fc` and `d403c25` give no Host counts), and the Host was not rerun
for this runbook.

| Host case | Lua suite | Count at 06:59Z |
| --- | --- | --- |
| `bmx_lua_policy_runs_as_modules_and_the_inspector_starts_inert` | `tests` | 12 cases, 1,216 assertions (asserted exactly by the test) |
| `bmx_lua_equipment_requests_match_the_retained_gesture_rules` | `equipment_tests` plus C++ reference rows | 8 cases, 1,269 assertions, 160 C++ comparisons |
| `bmx_lua_equipment_transitions_keep_cleanup_and_target_observation_separate` | `equipment_transition_tests` | 32 cases, 2,538 assertions |
| `bmx_lua_equipment_runtime_uses_typed_services_without_native_permissions` | `equipment_runtime_tests` | 13 cases, 260 assertions |
| `bmx_lua_persistence_keeps_terminal_records_and_public_fault_gates` (added in `ad1516e`) | `bike_runtime_core_persist_tests`, `runtime_progress_fault_tests` | not in that receipt |
| `equipment_interruption_fixture_keeps_effects_one_shot` | `equipment-interruption-trial/plugin/fixture_tests` | 13 cases, 1,542 assertions |
| `bmx_lua_recovery_policy_keeps_native_cleanup_separate` | `recovery_tests` | 18 cases, 379 assertions |
| `bmx_lua_trick_policy_uses_actual_package_modules` | `trick_tests` | 16 cases, over 300 assertions (asserted by the test) |
| `bmx_lua_forces_use_actual_modules_and_match_the_portable_kernel` | `force_tests` plus C++ reference rows | 25 cases, 2,618 assertions, 83 C++ comparisons, 18 direct projections |
| `bmx_lua_contacts_use_actual_decoder_and_force_modules` | `ride_runtime_tests` (generated fixture) | 48 cases, 128 assertions |
| `bmx_lua_spawn_uses_owned_chassis_and_measured_part_placement` | spawn scenarios in C++ | 22 Host scenarios, 2,048 comparisons |
| `bmx_lua_first_ride_imports_stay_inert`, `bmx_lua_public_bike_facade_denies_mount_before_service_access`, `bmx_lua_menu_switches_explicit_slots_and_retains_cleanup_duty` | imports, facade, menu | no count printed |

The Host adds C++ reference rows for equipment and forces, so its counts differ from the pure
runner's for those two suites. At HEAD the Host runs 10 of the 31 suites in `bmx-plugin/plugin`.
The other 21 run only on the pure runner and the Luau runner: `lease_source_tests`,
`ride_input_tests`, `ride_input_mapping_tests`, `rider_alignment_tests`, `recovery_runtime_tests`,
`ride_runtime_join_tests`, `ride_runtime_b10_b16_tests`, `contact_runtime_preset_echo_tests`,
`core_ride_staging_tests` and every suite of the newer pure modules.

Build and run. AGENTS.md's `cmake --build --preset release` always builds the shared tree
`build\vs2022-x64`. Use it only when you are the only builder. Never use it while other agents or
chats are building. Codex's proven form is a `.cmd` file:

```bat
call "C:\BuildTools\VS2022\VC\Auxiliary\Build\vcvars64.bat"
"C:\Users\Jeffr\AppData\Local\ImpetusDev\mingw64\bin\cmake.exe" --build "C:\Users\Jeffr\Desktop\reskate\build\vs2022-x64" --config Release --target dingosdk_plugin_tests dingosdk_owned_body_source_tests --parallel 4 -- /nr:false /p:CL_MPCount=4
"C:\Users\Jeffr\AppData\Local\ImpetusDev\mingw64\bin\ctest.exe" --test-dir "C:\Users\Jeffr\Desktop\reskate\build\vs2022-x64" -C Release --output-on-failure --no-tests=error --timeout 300 -R "^(plugins|owned_body_source)$"
```

- `/nr:false` stops leftover MSBuild workers from holding files locked.
- Always pass `-C Release`; the CTest file also registers Debug paths.
- Pass `--timeout`: the `plugins` test has no timeout of its own.
- Add `dingosdk_runtime` to the targets to build `ReSkate.dll`.
- A `-D` reconfigure of the shared tree costs everyone a 12-15 minute rebuild.
- `/W4 /WX`: any warning fails the build.

To build in parallel with others, configure your own folder:
`cmake.exe --preset vs2022-x64 -B "E:\RESKATE DEV\<case>\build" -DCMAKE_GENERATOR_INSTANCE=C:/BuildTools/VS2022 -DDINGOSDK_BUILD_PLUGIN_TESTS=ON -DDINGOSDK_BUILD_BMX_TESTS=ON`,
then `--build` that folder. It still reads Lua and fixtures from the one source checkout; for a
frozen source, configure from a staged copy or a git worktree. Give each test run its own temp folder
(`set TEMP=E:\RESKATE DEV\<case>\tmp` and the same for `TMP`): `dingosdk_plugin_tests` deletes and
recreates `%TEMP%\reskate-plugin-tests` (`Extension/Plugins/Test/plugin_tests.cpp:8354`), so two runs
collide whichever build folder they use.

Durations from earlier receipts: `plugins` 8-16 s; a plugin-tests-only rebuild about 83 s;
`ReSkate.dll` with 7 changed files about 76 s; configuring a fresh folder about 28 s plus generation.

### Other test groups

- In the shared tree these groups are ON: BMX, PLUGIN, CAPTURE, LAUNCHER, MULTIPLAYER, PARK_EDITOR
  and TRAINER (`build\vs2022-x64\CMakeCache.txt`). `DINGOSDK_BMX_STANDALONE_MOVEMENT` and
  `DINGOSDK_BMX_NATIVE_COUPLED` stay OFF.
- The BMX group, 99 `bmx_*` tests in the shared tree's `ctest -N -R "^bmx_"` list at 11:27Z, covers
  the older native C++ prototype. Select it with `-R "^bmx_"` rather than `-L BMX`; add
  `-LE "Python|PowerShell"` to skip the script tests.
- Codex's 46-test Lua-route selection (passed 46 of 46 in 10.8 s, receipt
  `E:\RESKATE DEV\lua-api-modal-normal-20261025T050117464Z\test-counts.json`):
  `^(launcher_mod_manager|mod_store_view|launcher_mod_profiles|native_menu_browser|native_menu_lifetime|trainer_session_extras|trainer_landing|trainer_presets|owned_body|actor_control|body_follow|owned_body_source|plugins|question_ownership_fresh_refusal|question_ownership_other_prompt|question_ownership_reentrant|input_lease_capture_native_.*)$`.
- The Python tests (`cmake/BmxTests.cmake`) use fakes only and the `build\bmx-gamepad-runtime`
  environment. The PowerShell tests run with the only PowerShell 7 on this machine, Codex's copy at
  `C:\Users\Jeffr\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe`.
- `standalone/bmx-movement` is a separate CMake project with five tests (see its README). It is not
  linked into `ReSkate.dll` and the Lua plugin does not use it. Its reference files hold values
  recovered from BMX Streets; do not import them.
- `contrib/bmx-lab/CMakeLists.txt` builds the portable lab harness; see
  [README.md](README.md#build-and-fixtures).

### Lua time limits

The Host defaults are 50 ms per call, 20 ms for unload, and a 2 ms average tick over 1 s windows,
with a stop after 3 windows in a row over it (`Extension/Plugins/plugin_vm.h:30-33`). The in-game
Host uses those defaults (`Extension/Plugins/plugin_runtime.cpp:308`). The BMX Host suites spread
imports and cases across ticks and check that the plugin still runs after each tick, so in practice
they test only the 50 ms limit. Two cases raise `call_ms` to 2000 for themselves only: equipment
interruption (`Extension/Plugins/Test/plugin_tests.cpp:5237`) and forces (`:5617`); these are
HEAD's line numbers, and the working tree holds an uncommitted edit to that file that shifts them,
and `:8354` above, by 20 or 21 lines. The pure runner
and the Luau runner have no limits. The composer's module chain takes 34-43 ms to require offline
(`bmx-plugin/RIDE_COMPOSER.md`, "Per-tick cost"). The real plugin's in-game startup and tick costs
are unmeasured ([LUA_RUNTIME_BUDGET.md](bmx-plugin/LUA_RUNTIME_BUDGET.md)).

## Evidence locations and conventions

- **`build\bmx\<name>\`** (gitignored): one folder per package, operator, review or proposal.
  Frozen packages carry `SOURCE-FREEZE.json` and `CANDIDATE-PINS.json`; operators carry
  `SOURCE-PINS.json` and `EXACT-INVERSE.json`. Screenshots go to `build\bmx\*.png`, written without
  overwrite (Node `fs.writeFile` with flag `wx`). The proven CE2 package (`first_follow_core.lua`
  in `build\bmx\callback-entry-follow-ce2-package-v2\`) has no copy on `E:`, and neither do the M3
  operator (`build\bmx\ui-follow-one-force-m3-operator-v3\`) or the unrun board-return operator, so
  losing `build\` loses them. Most other operators have a copy on `E:`: the CE1 and CE2 case
  folders hold theirs (for example `...\priority-attempt-result-v1\operator\` and
  `...\stock-board-return\attempt-v1-refused\operator\` in the CE2 case, with `publish-go.ps1` and
  `common.ps1`), and the M4 and both terrain probe archives hold an `operator\` folder.
- **`E:\RESKATE DEV\<case>-<UTC>\`**: one case folder per trial, holding `owner.json`,
  `binding.json`, the copied operator folder, the controller ledgers, the saved storage and log,
  screenshots, and `actual-result.json` or `actual-refusal.json` with SHA-256 values. The M3, M4
  and both terrain probe cases also hold a held-process exit receipt and an archive manifest.
- **Plugin storage**: `%LOCALAPPDATA%\ReSkate\Plugins\<namespace>\storage.json` or
  `build\bmx-game\ReSkate.Plugins\<namespace>\storage.json` (`publish-go.ps1:60` in
  `build\bmx\ce2-stock-board-return-operator-v1\`).
- **Game log**: `build\bmx-user-data-luau-native-body\logs\ReSkate.log`.
- **Checkpoints**: `contrib/bmx-lab/judging/checkpoints/<date>-<topic>.md`, written after an
  independent reader has reviewed the evidence; two checkpoints of 2026-10-25 sit in
  `contrib/bmx-lab/judging/` itself. Commit subjects follow AGENTS.md.

Rules Codex kept, which keep the evidence comparable:

- One attempt per operator folder, with a fresh controller-gate folder and nonce. A refusal is
  preserved and never retried, extended, re-armed or killed; the next attempt gets a new folder.
- The guards stay unchanged: 40 s from ready to GO, the driver's 60 s gate, 120 ms report lateness
  and the 50 ms Lua call limit.
- Every step is bound to one exact Skate PID plus its creation FILETIME.
- Close the game with an ordinary close only; never force-terminate.
- HID HOLD: before any controller window, every other chat or agent stops builds, heavy I/O and
  screenshots until the window ends.
- An independent reviewer gives SOURCE GO before each live run.

## In-game trial procedure

Only the root session runs this, and only with the user's approval. Subagents never launch Skate,
the launcher, Steam, the controller driver or an operator script. Before relying on this procedure,
note two limits:

- The CE2 operator scripts need PowerShell 7.5 or later (`common.ps1` line 2 refuses older).
  Claude's PowerShell tool is 5.1. The only `pwsh` found is Codex's copy named above.
- Codex drove the UI with its own `sky` tool. Claude would need computer use, and its coordinates
  and timing will differ. One screenshot round trip has already used up a 40 s window.

This is the last working CE2 sequence (07:56-08:27Z) plus the refused Board attempt (08:47-08:51Z).
Folder names are those used then; every new run needs new ones. The later M3, M4 and terrain probe
runs used their own operators (`build\bmx\ui-follow-one-force-m3-operator-v3\`,
`build\bmx\ui-input-follow-one-force-m4-operator-v1\`, `build\bmx\terrain-probe-operator-v1\`,
`build\bmx\terrain-probe-operator-v2\`), armed Prep V4 from the overlay first, and closed the game
with an ordinary Alt+F4; their checkpoints and `RESULT.md` files record each step.

1. **Prerequisites.** Use only `build\bmx-game\Skate.exe`, never a Steam or `D:\Games` copy. Check
   the hashes in the table above. The scouts found ViGEmBus 1.22.0 installed. The controller Python
   is `build\bmx-gamepad-runtime\Scripts\python.exe`, and no `Skate.exe` may be running.
2. **Deploy** only when the runtime changed: archive the old pair to `E:`, copy `ReSkate.dll` and
   `ReSkateLauncher.exe` from `build\vs2022-x64\Release` into `build\bmx-game`, then re-hash both.
   Example record: `E:\RESKATE DEV\park-diagnostic-game-deploy-20261025T071135023Z\deployment.json`.
3. **Install the mod.** Copy the frozen package (for example
   `build\bmx\callback-entry-follow-ce2-package-v2\candidate\follow` and `\prepare`) into
   `build\bmx-game\Mods\<Namespace>\`, with `reskate-plugin.json` copied last. Disable every spent mod
   by renaming its `reskate-plugin.json` to `reskate-plugin.json.disabled-before-<run>`;
   `Assert-SpentDisabled` refuses any other enabled mod folder. Use a fresh namespace, because an
   existing ledger blocks Arm.
4. **Prelaunch.** `pwsh -File build\bmx\<operator>\prelaunch.ps1 -ExecuteRoot` checks the hashes and
   that every storage path is absent, then writes `prelaunch.json`.
5. **Launch.** `build\bmx\ce2-profile-boot-launch-root-v1.ps1 -ExecuteRoot` clears
   `RESKATE_STARTUP_COMMANDS` and sets `RESKATE_BMX_LOCAL_PROFILE=1` in its own child environment
   only. It starts `ReSkateLauncher.exe --no-gui --no-update --offline --no-discord --dev-data-root C:\Users\Jeffr\Desktop\reskate\build\bmx-user-data-luau-native-body`,
   hidden and with no `-map`. It then waits up to 15 s for the one `Skate.exe` child with
   `ReSkate.dll` loaded, and writes `actual-new-owner.json` (example:
   `E:\RESKATE DEV\ce2-profile-boot-launch-20261025T075648878Z\actual-new-owner.json`). The
   FILETIME must come from `Get-Process` `StartTime.ToUniversalTime().ToFileTimeUtc()`; CIM rounds
   it, and a 300 ns difference was once refused.
6. **Bind.** `bind-attempt.ps1 -ExecuteRoot -OwnerReceipt <actual-new-owner.json>` writes
   `owner.json` and `binding.json` and creates the `E:` case folder.
7. **Admission.** `ReSkate.log` must show, in this order, "BMX native storage path verified inside
   the isolated test profile." and "BMX native local storage configuration returned 0."
8. **Reach gameplay.** Escape twice closes the character menu. Insert opens the ReSkate overlay; use
   its travel control to go to MPR, then Insert closes it. Wait for the skater factory, then confirm
   an on-foot skater in a screenshot.
9. **Prep.** Insert, open the "Physics Prep …" page and click "Arm once" (a 30 s arm window, at most
   20 calls). Insert to close; Prep runs only with menus closed. Insert again and read "ready" with
   its call count (CE2: 3 of 20; M4 and the terrain probes: 2 of 20), then record
   `prepare-observation-input.json`.
10. **HID HOLD.** Tell every other chat or agent to stop builds, heavy I/O and screenshots.
11. **Baseline.** With the overlay closed, `controller.ps1 -Mode baseline` runs scenario
    `neutral-follow`: 301 reports over 6 s, from a hidden Python child raised to AboveNormal and read
    back before bootstrap. It needs a slot-0 bootstrap with two raw-zero readbacks, then final
    neutral release and disconnect. Then run `verify-priority-result.ps1 -Mode baseline`.
12. **Gate.** `controller.ps1 -Mode gate` runs `neutral-window-20s` with a fresh start-gate folder
    and nonce and writes `go-payload.json`. The driver bootstraps, writes `ready.json` and holds a
    neutral pad for at most 60 s.
13. **Arm and GO in one tool call:** click the plugin's Arm button, read back text only (no
    screenshot), and run `publish-go.ps1 -ExecuteRoot`. It refuses when `ready.json` is older than
    40 s or storage is older than 5 s, and otherwise renames `go.pending.json` to `go.json`. The
    working Follow run published at a ready age of 32.5 s (`...\pre-go\checks.json` in the CE2 case).
14. **Only if publish-go exits 0**, in the same call: press Insert once to close the overlay, then
    wait 20 s with no input and no screenshots.
15. **Verify.** `controller-gate\stdout.log` must show completed true, 1,001 reports, and neutral
    release and disconnect true. Confirm the child PID is gone, run the verify script, read
    `storage.json`, save page screenshots, then copy the operator folder and the log into the `E:`
    case and write `actual-result.json` with hashes.
16. **Close.** Copy the log with a shared read, close the exact process with an ordinary close
    (`CloseMainWindow()` then `WaitForExit(10000)`, or Alt+F4 as in M3, M4 and the terrain probes),
    confirm the PID is gone and write the exit receipt. If it does not exit, stop and preserve;
    never force. A clean close is not evidence of a park.

### Known failure modes

| Symptom | Cause found | What to do |
| --- | --- | --- |
| MPR stays on "Loading…" | Launch without `RESKATE_BMX_LOCAL_PROFILE=1` (three stalls) | Launch as in step 5. The underlying timeout is unexplained. |
| Plugin fails at startup | Page title longer than 24 characters | Keep titles at 24 characters or fewer. |
| Lease refused with `source_unavailable` | Armed before the virtual pad was connected (`Engine/Game/Input/input_lease_policy.h:21`) | Start the gate first so the pad is held neutral, then Arm. A driver readback does not prove the game polled the pad. |
| Driver aborts on lateness | A 50 Hz report more than 120 ms late (`Bmx-VirtualGamepad.py:28`) | Keep the machine quiet (HID HOLD). AboveNormal priority passed once; that it caused the pass is unproven. One diagnostic on PID 40988 failed at 1,141 ms even so. |
| `publish-go` refuses on ready age | More than 40 s from `ready.json` to GO | Nothing slow between ready and GO; the deferred Board plan moves Arm earlier. |
| Saved status disagrees with the page | Throttled save before an early-returning tick | Fixed in the tracked core (`ad1516e`, `3587d78`) and in the unrun CE2 v3 package, not in CE2 v2. Compare page and storage after every trial. |
| `joint pose unavailable` before any body | The first `skater.joint` call can return nil before a sample arrives (terrain probe r1) | Warm the joints up on earlier ticks, as the stationary observer does, before any body or ray. r2 did, and got past this. |
| Every terrain ray clear, floor rays included | Unknown: ray placement, the terrain mask or native query semantics (terrain probe r2) | Read no clear ray as a miss of the rider unless a floor ray in the same run hit. |
| `native_lifetime_changed` | Some native entity was destroyed across the lifetime fence | The body stays allocated; use a fresh process. |
| Driver stops when focus changes | Escape or focus loss aborts the driver | Nobody touches the game during the window. |
| A fresh DLL is blocked | Windows Smart App Control | See [application-control-block.md](application-control-block.md). |

## Next in-game trials

Each needs its own reviewed operator and the user's approval. Each trial is one attempt, and
failures are preserved.

1. **A terrain probe with a positive floor control (ng-terrain-floor-control).**
   - Purpose: the r1 question, still open after r2. Do terrain-preset rays hit the floor and miss
     the rider? r2 ran its warm-up and all six rays (see
     [Terrain probe r2](#terrain-probe-r2-at-2158z)), but its floor rays also came back clear, so
     it could not tell a miss of the rider from a ray that finds nothing.
   - Not designed yet. First work out offline, from r2's saved ray geometry
     (`build\bmx\terrain-probe-actual-v2\DERIVED-SUMMARY.json` and the raw storage beside it) and
     the SDK source, why both floor rays missed: placement, the terrain mask or native query
     semantics. Then derive a new package from the r2 source
     (`E:\RESKATE DEV\chat-2-reskate-bmx\terrain-preset-actor-probe-v2`), keeping its warm-up, with
     a floor control that is expected to hit. Use a new namespace, and disable the spent r2
     manifest first.
   - The rider crossings stay as in r1 and r2, with `exclude_local_actor=false`, on a clear MPR
     floor patch. Record the preset echo, native casts, hit, clear or unavailable per ray, points,
     normals, surface velocities and any body token, per "One bounded future MPR observation" in
     `build\bmx\first-static-wheel-contacts-source-strategy-v1\query-preset-refinement-v1\PLAN.md`.
   - Done: a floor ray hits in the same run as the crossings, or the run refuses with its reason
     saved. Only then does a crossing count. One that hits the rider rules out the terrain-lane path
     (D1b in the integration plan). A clear crossing beside a floor hit is only a terrain-mask
     clear, not proof of empty space or of actor exclusion. It uses one of the eight body slots if
     it creates a body, as r2 did.
2. **Rider and bike alignment visuals (ng-alignment-visuals).**
   - Purpose: the first in-game look at where the bike parts sit against a measured rider, before
     any riding. Nothing in game has shown rider alignment on the bike.
   - Inputs: a warmed-up joint sample (r2's warm-up is the latest that worked in game; the tracked
     observer's warm pass, `stationary-anchor-observer/plugin/sampler.lua:191-197`, is the
     pattern), the static part placement already seen upright in game
     (`7b12f43`, `E:\RESKATE DEV\static-bike-axis-actual-a1-20261025T1706Z\ACTUAL-OBSERVATION.md`),
     and the authored grips and pedals (`bmx-plugin/plugin/bike_geometry.lua:13-16`). An earlier
     aligned-root Follow diagnostic (`E:\RESKATE DEV\aligned-root-follow-20261025T1147Z`) kept its
     alignment acceptance on hold because its rows lacked same-epoch coherence
     (`build\bmx\follow-body-authority-cleanup-cross-review-v1\aligned-root-actual-review-v1\JUDGMENT.md`).
   - A new candidate places the eight static parts once, through `world.entities` as the axis
     trial did, at a pose derived from the rider's measured root, and saves screenshots from fixed
     camera views together with the joint and part transforms it used. It needs no body, Follow,
     force or pose write.
   - Done: screenshots and transforms saved, with the hand-to-grip and foot-to-pedal distances
     computed from the saved transforms. The rider is still standing on foot, so this is a fit
     check of placement, not a mounted pose. A mounted posture needs a pose path (S7 in the plan).
3. **A first grounded or mounted step, once ground support exists (ng-first-ground-step).**
   - Not ready. It needs actor-safe wheel contacts (the SDK refusal of `exclude_local_actor`
     lifted, or a reviewed terrain lane after trial 1 passes), `world.raycast` in the trial
     manifest, and the tracked core repeating CE2 in game (milestone M1 in the integration plan).
     The composer's grinds and bail also need a per-read probe batch budget; the first step does
     not use them.
   - Then: the integration plan's M3 (zero-force cadence with the gates flipped in a trial copy)
     and M4 (the first nonzero force on a body standing on the floor), each one attempt.
   - Done for M4: the body holds its height and position within 2 cm on the floor under the Lua
     ground forces and then parks with every ACK. That would be the first evidence of wheel
     ground support.

**Deferred: stock board return in a fresh process (ng-board-return).** The CE2 Board refusal above
is still unanswered. `build\bmx\callback-entry-follow-ce2-package-v3\` (pure-runner tests only, not
deployed) and `build\bmx\board-return-prearm-operator-v3\` (parser and pure decision checks only)
exist; neither has run in game. The plan from the previous revision still holds: fresh launch, new
namespace, Prep, a Follow that completes and is acknowledged, then Board armed while the menu is
open, then the gate, so that no screenshot round trip falls between ready and GO.

## Judging

[judging/rubric-v2.json](judging/rubric-v2.json), committed in `e2055ab`, copies
[rubric-v1.json](judging/rubric-v1.json) unchanged and adds two categories: `grinds_pegs_stalls`
(S22-S26) and `camera` (S27-S32), each with judge points, scenarios, category hard failures and a
9.5 requirement. v1 stays as it was. [OFFLINE_METRICS.md](judging/OFFLINE_METRICS.md) describes the
offline metrics from simulator traces; an offline score is not the human-judged likeness score.
Both rubrics are unrated: no current-build footage covers any category, and test counts never earn
a score. The 9.4/10 ratings on the M3 and M4 checkpoints rate bounded native engineering evidence,
not likeness.

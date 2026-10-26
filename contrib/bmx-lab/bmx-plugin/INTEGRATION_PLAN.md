# Integration plan: from the Follow trial to a first mounted ride

This is a plan, not a result. It says how to get from what the game has shown today (Follow
returns and parks, and single force commands have been applied to owned bodies) to a first mounted
ride in game: which gates open when, where the ride composer is called, what the SDK still lacks,
the in-game trial for each step with its pass and fail rules, and the risks. Nothing in this file
changes code. Every gate stays false, `main.lua` is unchanged, and no likeness score is claimed.

The first version was written from the working tree at about 14:00Z on 2026-10-25 (HEAD `2cab0be`
plus uncommitted edits). This revision, from about 21:50Z the same day, brings it to HEAD `2584bcd`,
which is also `origin/BMX`. The header, "Where things stand", the call path, the blockers table,
"The composer and Ride", "SDK capabilities still missing", the gates table and "Milestone status"
were re-read at HEAD, and their line numbers are HEAD's. The milestone details, the risks and the
decisions keep their first-read line numbers except where a line was rechecked; Core, Ride and the
composer have changed since, so recheck those before review. Terrain probe r2, which ended at
22:01Z, was added at about 22:30Z to the in-game table, S1, the milestone status and M2. On
2026-10-26 at about 17:00Z the commit list, the in-game table and the S1 and S2 rows were brought up
to `f40a866c`; nothing else was re-read then. Paths
under `build/` are gitignored private packages on the development machine, and paths under
`E:/RESKATE DEV/` are on the evidence drive. Paths starting `plugin/` are relative to this folder;
all others are relative to the repository root. Three checkpoints are abbreviated:

- `CP`: `contrib/bmx-lab/judging/checkpoints/2026-10-25-luau-native-transport.md`.
- `M3CP`: `contrib/bmx-lab/judging/2026-10-25-combined-follow-force-checkpoint.md` (`588f930`).
- `M4CP`: `contrib/bmx-lab/judging/checkpoints/2026-10-25-m4-input-follow-force-checkpoint.md`
  (`4b75b2a`).

**A naming note.** Codex's checkpoints call two private trials "M3" and "M4". Those labels are not
this plan's milestones M3 and M4. Codex's M3 put one owned body under Follow and sent it one force
command; its M4 added an input lease. Both ran private trial packages, not the tracked core, and
the gates stayed false in the tracked tree. This plan's M3 and M4 need the tracked core with both
gates flipped in a trial copy. [Milestone status](#milestone-status-at-2584bcd) says what each trial
shows for each milestone.

## What "first mounted ride" means here

The first mounted ride (milestone M5 below) is: the local actor is attached by Follow to an owned
physics body; the Lua ride model moves that body with nonzero force commands in response to the
player's pedal input for at least one second, inside one Follow lease; and the ride ends with a
completed, parked and acknowledged Follow, a cleared force ledger and drained input. The rider is
still the game's on-foot skater, posed by the game. A visible BMX riding posture is a later
milestone (M8), because no pose-apply path exists yet (`RIDE_RUNTIME.md:37`). If the owner wants
the first ride to include rider posture, that is decision D3 below.

## Where things stand

**Public package.** `main.lua` builds the lifecycle with no options (`plugin/main.lua:5`), so
`qualification_only` is false (`plugin/bike_runtime.lua:19`) and Mount is refused before any game
call (`plugin/bike_runtime.lua:122`, again in the core at `plugin/bike_runtime_core.lua:837`). The
two source gates are literals: `RIDE_COMPOSITION_QUALIFIED=false`
(`plugin/bike_runtime_core.lua:12`) and `ACTIVATION_QUALIFIED = false` (`plugin/ride_runtime.lua:3`).
The Host fixture copies `ride_runtime.lua` with the gate set true in memory, and checks that the
shipped core gate is still false (`Extension/Plugins/Test/bmx_contact_runtime_host_fixture.inc:16-24`).
The manifest has no `world.raycast` and no `camera` permission (`reskate-plugin.json:5`).

**Committed since the first version.** Each of these is source and constructed-test evidence only;
none has run in game.

- `3e686fc` closes B3, B7, B13 and B14 in Core and the facade (see the blockers table).
- `1b5e57f` changes Ride for B10 and B16 and the mapper for B15(a).
- `d403c25` lets Contact accept the SDK's `requested_query_preset` echo, which was half of B2.
- `c1ec154` adds `query_preset = "camera"|"terrain"` to `world.physics.probe_batch`
  (`contrib/plugin-body-query.md:96-121`).
- `0b4c3e3` and `2584bcd` commit `plugin/ride_composer.lua` (see "The composer and Ride").
- `e1dc8e0` (bail), `439ed37` (grinds and rail probe), `94f7bf2` (manual balance), `5bd211b`
  (rider and trick presentation), `f3cc0c8` (camera), `4e5a4c2` (input presets), `acb1dae`
  (simulator) and `e2055ab` (rubric metrics) add pure modules. Neither `main.lua` nor Core loads
  any of them.
- On 2026-10-26: `71f0b9d1` adds `require_named_actor_categories_absent`, `query_preset="all"`,
  `include_hit_owner` and per-ray refusal reasons to `probe_batch` (S1). `6a19f97c` lets Contact,
  Core and Ride accept that lane behind `CATEGORY_WHEEL_LANE_QUALIFIED=false`. `818dfa32` is the
  composer's plan/step contract (B18). `c69b0ca8` adds `plugin/mounted_pose.lua`, gated off and
  unwired ([MOUNTED_POSE.md](MOUNTED_POSE.md)). `5ec1fd90` adds renewable Follow to the SDK
  (`renew_follow`, `read_follow_lease`, permission `world.physics.follow.renew`). `f40a866c`
  (LUA-4) gives Core one lease deadline, refined from `read_follow_lease` when it exists, and a
  per-tick Follow read budget.

**In game, all on build 20260929 with the native BMX options off:**

| Trial | What was observed | Source |
| --- | --- | --- |
| Force7 | One owned body, one zero-force/zero-torque command queued then applied (serial 140354 to 140355), Follow revision 1 completed, park observed, ACK. The force receipt was acknowledged as `parked_without_successor`. | `CP:28-45` |
| CE1 | `callback_entry` Follow returned 30 of 30 revisions; the bike was seen beside a standing rider; cleanup failed with `retained_unknown`, `pending=[body_parked]`. | `CP:58-79` |
| CE2 | Follow returned 31 of 31, park observed, ACK; input drained with no report debt; eight visual removals accepted. | `CP:174-200` |
| Earlier `native_lifetime` runs, before `callback_entry` existed (`46a1526`) | Follow stopped after 12 and 16 revisions with `native_lifetime_changed` or a global-epoch change; park never observed. | `contrib/bmx-lab/judging/checkpoints/2026-10-24-follow-first-native-returns.md:3-7`, `contrib/bmx-lab/judging/checkpoints/2026-10-24-follow-lifetime-witness.md:5-7` |
| Separate Follow and force, PID 40988 (17:34-17:46Z) | A Follow alone completed at revision 24 with park observed and ACK. On a different body, one magnitude-106 force was applied (serial 105143 to 105145) and acknowledged; that body's park was not observed. | `contrib/bmx-lab/judging/2026-10-25-native-follow-force-checkpoint.md` (`7b12f43`) |
| Codex M3, PID 19460 | One body under Follow took one horizontal magnitude-106 force with zero torque and no impulse: applied receipt (serial 1776 to 1778), force ACK, Follow completed at revision 9 with park observed, Follow ACK, then eight visual removals. Over eight samples the body fell from Y 201.314 to 201.194 and moved 0.0019 world units horizontally. | `M3CP` |
| Codex M4, PID 15648 | The same, plus one observe-mode input lease on XInput user 0 (21 reads, 19 renewals, released, ACK). Applied receipt 4189 to 4191; all three ACKs came before the removals. The body fell from Y 201.314 to 201.219. | `M4CP` |
| Terrain probe r1, PID 20772 | Refused before creating a body: the first `skater.joint("root")` returned nil, so none of its six rays was cast. | `build/bmx/claude-handoff/to-claude/terrain-probe-trial-20261025T2130Z/RESULT.md` |
| Terrain probe r2, PID 25760 | A joint warm-up worked (each of four joints read nil once, then finite). One diagnostic body was created, and one `terrain` batch with `exclude_local_actor=false` came back `available` with `native_casts=6`. All six rays were clear, both floor rays included, so the batch has no positive floor control. Release accepted; phase `done_retained`; review HOLD. | `build/bmx/claude-handoff/to-claude/terrain-probe-trial-r2-20261025T2202Z/RESULT.md`; `build/bmx/terrain-probe-actual-v2/INDEPENDENT-REVIEW.md` |

| Alignment r3, PID 2812 (2026-10-26) | The eight-part bike rendered upright beside the sampled rider and then between the rider's legs, from `reskate.entities.set`; Stop removed all 16 requests. No body, Follow or force. | `build/bmx/alignment-actual-v3/RESULT.md` |
| S1 category probe P1, PID 29704 (2026-10-26) | `P1_PASS_CANDIDATE` on runtime `E21F6710…` (`4613baa6`). The `camera` preset hit the MPR floor (y 274.361, `in_categories` 0x00002FF0). The production request, camera plus `require_named_actor_categories_absent`, was available with `named_actor_categories_absent=true` and 3 floor hits at T0 and T30. `all` rays through the rider hit 0x10000040 and 0x04001008, disjoint from camera; camera rays on the same segments stayed clear. The zero-command body was still falling at T30. | `build/bmx/s1-p1-actual-v2/RESULT.md` |
| M1, PID 23224 (2026-10-26) | The tracked core at `f40a866c` (trial window 2,800 ms, envelope 6 m) ran its whole lifecycle: Completed + ACK, park observed, 8 removals, ended on its window. The page judged `NOT_PASSED` on the first-500 ms 5 cm rule, but the actor follows the body in position, heading and tilt. Two corrections follow: spawn under the rider (the 3 m spawn made Follow's spring-like pull overshoot 1.3 m and settle only at 563 ms), and an offset whose target the actor can reach (`-G.com` aimed at wheel-bottom level; the actor stood 0.46 m above it). The body landed and rested on the floor: S8 holds at MPR. | `build/bmx/m1-actual-v1/RESULT.md` |

Both checkpoints record a falling body and say grounding, rolling, riding, force units, rider
alignment and actor exclusion are not proven (`M3CP`, `M4CP` "Not proven").

**None of those ran the tracked code that would ride.** Force7 ran a private core,
`build/bmx/native-force-cleanup-trial-proposal-v7/candidate/follow/plugin/force_cleanup_core.lua`,
which submits a literal zero vector (`:478-479`) and reads `cleanup_disposition` (`:363-422`). CE2
ran `build/bmx/callback-entry-follow-ce2-package-v2/candidate/follow/plugin/first_follow_core.lua`,
which reserves with `cleanup="owned_body",motion_policy="callback_entry"` (`:404-405`). Codex's M3
and M4 ran private packages whose trial modules are not in the repository (`M4CP`). Since `3e686fc`
the tracked core reserves Follow the way CE2 did (`plugin/bike_runtime_core.lua:674-675`), but the
tracked core has never run in game, and Ride's submit path (`plugin/ride_runtime.lua:515`) has
never run in game.

## The call path a ride step would take

When both gates are true, one Lua tick in the following phase runs, in order:

1. `tick` reads the Follow receipt, then the body, inside the 500 ms window
   (`plugin/bike_runtime_core.lua:982-999`).
2. `observe_ride(selected_source_frame, sample, now)` (`plugin/bike_runtime_core.lua:1000`, defined at
   `:636-656`) constructs Ride once through `create_ride` (`:553-635`) and calls `ride:observe`.
   `create_ride` uses the Ride and Contact that `prepare_backend` bound at mount (`:812-817`) from the
   facade's staged list (`plugin/bike_runtime.lua:11-14`), so this tick requires no module.
3. `Ride.observe` (`plugin/ride_runtime.lua:407-525`) stages the input (a duplicate report is not
   queued, `:110-129`), checks the body serial is exactly one step on (`:432-433`), plans two wheel
   rays from authored geometry (`:327-342`, called at `:450`), and calls Core's `probe_batch`
   closure (`:452`; closure at `plugin/bike_runtime_core.lua:571-581`).
4. The contact batch is decoded (`plugin/ride_runtime.lua:454`) and turned into wheel rows and a
   `grounded` flag (`:343-381`). If a fresh input report was staged, the mapper observes it
   (`:461-469`); on a body step with no fresh report it does not. Either way Ride then asks the
   mapper for controls with this step's `grounded` (`:470-472`). Once a model step has run,
   controls that are not valid stop the ride (`:474-481`; B15). Companions run (`:285-326`, called
   at `:489`).
5. The force kernel previews with Ride's carried wheel pair (`:501`; B16), the packet is bounded
   (`:382-406`) and submitted through Core's closure (`:515`; closure at
   `plugin/bike_runtime_core.lua:582-600`).
6. On later ticks the receipt is polled and acknowledged (`plugin/ride_runtime.lua:229-284`) through
   Core's closures (`plugin/bike_runtime_core.lua:601-620`). After a stop, `cleanup_tick` keeps
   draining it (`plugin/bike_runtime_core.lua:700-708`, `:524-528`).
7. The same body sample then places the visuals (`plugin/bike_runtime_core.lua:1001`).

## Blockers in the existing code

Flipping the two literals alone would not give a ride. Each open row below would stop it, and none
of them is a gate. Rows marked done or changed in source are closed only in source and constructed
tests; none has run in game.

| # | Blocker | Where | Status at `2584bcd`, and what has to change |
| --- | --- | --- | --- |
| B1 | `probe_batch` needs `world.raycast`, which the manifest lacks. The call raises a Lua error. | `Extension/Plugins/plugin_api_physics.cpp:561`; `reskate-plugin.json:5` | **Open.** Add the permission in the trial manifest at M2 and in the tracked manifest at promotion. |
| B2 | Ride, Core and Contact demand `exclude_local_actor=true` and `local_actor_excluded==true`. The SDK refuses that option before any cast. | `plugin/ride_runtime.lua:452`, `:350-352`; `plugin/bike_runtime_core.lua:572-573`; `contrib/plugin-body-query.md:52-53`, `:112-113`; `Extension/World/owned_bodies.cpp:1178` | **Open: actor-safe wheel contacts (S1).** The second half of the first version's B2 is done: Contact rejected the SDK's `requested_query_preset` field as `malformed_batch`, and since `d403c25` it accepts `"camera"` or `"terrain"` as request metadata only (`plugin/contact_runtime.lua:6`, `:120-127`). |
| B3 | Core built Ride with `tricks=Trick.new()`. The trick adapter refuses support that is not `measured_support`, which Contact never reports, and Ride stopped on that refusal. | `plugin/bike_runtime_core.lua:816`, `:628`; `plugin/trick_runtime.lua:97-101` | **Done in `3e686fc`.** Core passes `{contact=Contact}` with no trick adapter; status reports `ride_trick_adapter=false`. A trick adapter returns at M8. |
| B4 | Core stops when the selected pad leaves exact zero. | `plugin/bike_runtime_core.lua:418-425`, `:963` | **Open.** Ride mode admits input after publication; core change. |
| B5 | The whole following phase, and every force guard, ends 500 ms after publish. | `plugin/bike_runtime_core.lua:536`, `:550`, `:695`, `:984`, `:990`, `:995`, `:1003` | **Open.** A ride-window constant, bounded by the Follow lease (B6). |
| B6 | Follow has a fixed 3 s lease from reservation and no renewal. | `contrib/plugin-body-follow.md:36-41`; `Extension/Skater/native_body_follow_service.cpp:71` | **Open: sustained Follow (S2).** SDK work for anything past about 2.9 s. |
| B7 | The tracked core reserved Follow with the default `native_lifetime` policy. | `plugin/bike_runtime_core.lua:674-675` | **Done in `3e686fc`.** Core reserves with `cleanup="owned_body"`, `motion_policy="callback_entry"`, the pair CE2, Codex's M3 and M4 ran. The tracked core has not run with it in game (M1). |
| B8 | The visual owner refuses a body more than 2 m from its spawn point, and Core stops on that refusal. | `plugin/bike_spawn.lua:118`, `:249`; `plugin/bike_runtime_core.lua:1001-1005` | **Open.** A ride envelope constant in `bike_spawn.lua`. |
| B9 | Core reads Follow at most 400 times per VM, and each guarded probe or submit reads it again inside its owner check, before and after the call. With the tick's own read that is five reads a tick, which at 60 ticks/s uses 400 in about 1.3 s. The SDK allows 8 reads per tick. | `plugin/bike_runtime_core.lua:482`, `:533-552`; `Extension/Plugins/plugin_api_physics.cpp:395` | **Open.** Size the cap to the ride window; core change. |
| B10 | Ride waited forever for a successor on an applied receipt and never read `cleanup_disposition`, so a command whose body parked first left the force ledger uncleared and Core in `retained_unknown`. | `plugin/ride_runtime.lua:210-221`, `:247-251`, `:274` | **Changed in source in `1b5e57f`.** Ride accepts `parked_without_successor` only on an applied, retained, unquarantined row with no successor, stops the ride, ACKs, and retires the hop as `uncertain`; `ride_runtime_b10_b16_tests` covers it. |
| B11 | Ride keeps one command in flight, and Core refuses a submit while one is pending. A command for serial N applies at N+1 and its successor arrives at N+2, so commands land on every other step. Every ACK also resets the force histories. | `plugin/ride_runtime.lua:497-498`, `:276-279`; `plugin/bike_runtime_core.lua:585-588`; `Engine/Game/World/owned_body.h:164-176` | **Open.** Measure at M3. Pipelining up to the four-receipt ring (`Engine/Game/World/owned_body.h:12`, `:118-120`) is a later Ride/Core change (decision D2). |
| B12 | Any skipped physics step stops the ride. Any submit whose epoch no longer matches the current clock or latest body sample stops it too (`body_epoch_expired`; `body_clock_unavailable` separately identifies an unqualified clock). | `plugin/ride_runtime.lua:432-433`; `Extension/World/owned_bodies.cpp:1361-1362` | **Open.** Measure at M1 and M3; then decide skip-or-stop. |
| B13 | Core's required-API list omitted `probe_batch`, `submit`, `receipt` and `acknowledge`, so a missing function would show up only as a mid-ride exception. | `plugin/bike_runtime_core.lua:394-400`; `plugin/bike_admission.lua:121-129` | **Done in `3e686fc`.** Both lists now require the four functions before any ride or body exists. Presence only: `probe_batch` still needs `world.raycast` at call time (B1). |
| B14 | `create_ride` required `ride_runtime`, `contact_runtime` and `trick_runtime` on the first following tick, inside the 50 ms call limit and the 500 ms window. | `plugin/bike_runtime.lua:11-14`; `plugin/bike_runtime_core.lua:812-817`, `:627-629`; `Extension/Plugins/plugin_vm.h:30` | **Done in `3e686fc`.** The facade stages Ride, Contact and their dependencies at mount, one cold module per startup tick, and `prepare_backend` binds them, so `create_ride` has no `require`. `core_ride_staging_tests` (2 cases, 130 assertions) checks this; `create_ride` itself is unreachable while the gates are false. |
| B15 | The mapper reset itself, and Ride then stopped with "non-initial model cadence unavailable", in two cases. (a) On a body step with no fresh input report, `controls` saw a `grounded` different from the one it last saw. Ride's `grounded` is true when any wheel row is within 5 mm and separates at no more than 0.05 m/s. (b) A report more than `max_sample_seconds` (0.10 s) after the last one is refused as `observation_gap`. The driver sends reports at 50 Hz while bodies step at 60 Hz. | `plugin/ride_input_mapping.lua:132-142`, `:181`, `:190-196`, `:240`; `plugin/input.lua:12`; `plugin/ride_runtime.lua:374`, `:474-481`; `plugin/forces.lua:58-67`; `contrib/bmx-lab/virtual-gamepad.md:53`, `:81-82` | **(a) changed in source in `1b5e57f`; (b) kept by design.** For a primed mapper, a ground change re-projects the last admitted held state at zero elapsed time instead of resetting, keeps the source and time marks and the receipt-owned hop, and cannot mint a hop (`_held_ground`). This is D7's proposal. A report gap over 100 ms still stops the ride. Measure the report cadence at M1 and every ground change at M3-M5. |
| B16 | Ride gave the force kernel a fresh pair of non-spinning wheels on every command. | `plugin/ride_runtime.lua:173-182`, `:282`, `:508-510` | **Changed in source in `1b5e57f`.** Ride keeps the bounded wheel speeds of the command whose receipt was applied, after a coherent successor and ACK; force histories still reset. These are model wheel speeds, not native wheel observations. This is D8. |
| B17 | One probe batch per read. Core's closure stops the runtime on a second batch for one native serial, and the wheels already use it. The composer needs a rail lane (30 rays), a guard lane (8 to 24) and witnesses (0 to 24), each its own batch of at most 32 rays. | `plugin/bike_runtime_core.lua:575`; `plugin/ride_composer.lua:68`, `:340-355`; `RIDE_COMPOSER.md` "Batches and the request budget" and "Gaps found" item 1 | **Open: a general per-read probe batch budget (S9).** Offline, 3 batches per read reproduce the rail lock-on and both bails, and 4 carry every lane. Under Core's 1 the composer plans no rail or guard and submits nothing. Not needed for M3-M5 under D6a. |
| B18 | The composer's plan/step contract. `step` matches a pending plan only by the sample's epoch, rereads `tick.input`, and aliases `tick.gates`. Its own-read guarantee holds only while the protected fields stay unchanged between `plan`, `witness` and `step`. | `plugin/ride_composer.lua:474-478`, `:815-819`, `:919-923`, `:1133-1137`; `build/bmx/follow-body-authority-cleanup-cross-review-v1/bail-composer-claude-review-v1/REVIEW.md` (the first of its two P2 findings, "The own-read guarantee depends on protected fields staying unchanged after plan"; SHA-256 `A32A9E75…`) | **Open.** Before a native caller is wired, either revalidate body, serial, source and gates against the planned frame at `step`, or have the adapter enforce an immutable snapshot of those fields across the three calls and append only query results. `2584bcd` fixed that review's wording, torque and line-anchor findings, not this one. |

## The composer and Ride

`plugin/ride_composer.lua` was committed in `0b4c3e3` with review fixes in `2584bcd`. Its contract is
in `RIDE_COMPOSER.md`. The first version of this section was written against a 14:10Z draft. The
committed composer differs from that draft in how it handles receipts, batches and unguarded
reads, so this section is rewritten for HEAD. It is pure: it owns no SDK object and makes no
`reskate.*` call (`plugin/ride_composer.lua:1-3`).

**What the composer is.** `Composer.new(options)` takes optional `forces`, `input`, `balance`,
`grind`, `bail`, `tricks`, `camera`, `crank_ratio`, `command_limits`, `batches_per_read` and
`matrices` (`plugin/ride_composer.lua:243-252`; `RIDE_COMPOSER.md:18-34`). It owns its own Forces
kernel and its own Mapping. For each native step the caller makes three calls on one tick table:
`plan(tick)` (`:387`), `witness(tick)` (`:486`) and `step(tick)` (`:803`), then answers with
`accept(serial)` or `reject(serial)` once the native receipt arrives (`:746-778`). The kernel
previews each read and adopts the candidate only on `accept`, which also retires the hop
(`RIDE_COMPOSER.md` "Receipts and the force kernel"). One command waits at a time. A read that
`bail_policy` did not judge on its own guard rows submits no force, torque or hop impulse
(`:1100-1157`; `RIDE_COMPOSER.md` "Guard binding"). `batches_per_read` defaults to
`Composer.core_batches = 1` (`:68`), and with that default no read has a guard lane, so the
composer submits nothing (`RIDE_COMPOSER.md` "Gaps found" item 13). `status()` returns a copy with
userdata and functions removed (`:130-140`, `:1282-1289`).

**Where it does not fit today's Ride and Core.**

| # | The composer | Ride and Core today |
| --- | --- | --- |
| C1 | Runs its own Mapping on the tick's input and retires hops on the command's receipt through `accept` and `reject` (`plugin/ride_composer.lua:746-778`). | Ride runs its own Mapping and gates submission on its controls (`plugin/ride_runtime.lua:461-481`, `:532`), and retires a hop from the native receipt. Two mappers must not both run on one source. |
| C2 | Previews every read and commits only on `accept`. A read that does not follow the last accepted read previews from a reset kernel. Native latency is not modelled: the offline owner answers before the next read (`RIDE_COMPOSER.md` "Gaps found" item 11). | Ride previews without committing and resets force histories after every ACK (`plugin/ride_runtime.lua:276-282`, `:501`). One command is in flight, so commands land every other step (B11). |
| C3 | The caller carries wheel speeds in `tick.wheels` and adopts `commands.wheels` (`plugin/ride_composer.lua:293-294`, `:1133-1137`). | Since `1b5e57f` Ride carries the applied command's wheels too (B16). |
| C4 | Plans a rail lane (30 rays), a guard lane (8 to 24) and witnesses (0 to 24) inside its `batches_per_read` allowance, and refuses a lane past it as `batch_allowance` (`:340-355`). | Core allows one batch per native serial, only with `exclude_local_actor=true` (`plugin/bike_runtime_core.lua:571-581`). B17. |
| C5 | Grants support and runs its kernel only when the wheel batch reports `local_actor_excluded==true` (`plugin/ride_composer.lua:175-178`). | The same rule in Ride (`plugin/ride_runtime.lua:350-352`). D1b would need it relaxed in both. |
| C6 | The owner token must be userdata, a short string or a safe integer, and must change for every new mount (`plugin/ride_composer.lua:113-116`; `RIDE_COMPOSER.md:57`). | Core's `incarnation` is a frozen table (`plugin/bike_runtime_core.lua:559-560`). |
| C7 | Its pending plan is matched by epoch alone and `step` rereads the tick's input and gates (B18). | Core's closures check the owner, Follow, source and epoch before and after each call (`plugin/bike_runtime_core.lua:533-552`). |
| C8 | Its suite gives a fresh input report on every step and applies every command within its own step (`RIDE_COMPOSER.md` "Offline scenarios"). | Neither holds in game today (B11, B15), so the suite's numbers do not predict M3 to M5. |

The first version's C7 (an unfiltered `status()` holding the lease userdata) no longer applies:
`status()` now scrubs opaque values.

**Two ways to join them (decision D6).**

- **D6a, a stage wrapper for M3 to M5 (recommended).** The first ride uses Ride's own Mapping and a
  small trial-only wrapper in the `models.force` slot Ride already takes
  (`plugin/ride_runtime.lua:527-545`). Presenting the composer itself as `models.force` and
  `models.mapping` does not work without a Ride change: `force.preview` receives only
  `(h, body, wheels, samples, controls)` (`plugin/ride_runtime.lua:501`), not the raw sample,
  epoch, serial, body handle, owner, query facts or input frame that `composer:step` reads. Under
  D6a the composer joins at M7 through D6b. This keeps C1 to C7 off the path to the first nonzero
  force.
- **D6b, a composer lane in Ride (from M7, or earlier if the owners choose).** Ride keeps the
  chronology, the wheel batch, receipts, ACK and the force ledger. It replaces its Mapping,
  companions and preview (`plugin/ride_runtime.lua:461-510`) with one `composer:step(tick)` built
  from what it already holds, and answers the composer's `accept` or `reject` from the native
  receipt. Before it sends a nonzero force it needs: one mapper (the composer's) (C1); pipelined
  commands (D2) or an agreed one-in-flight cadence (C2); a token owner (C6); B18 closed (C7); and
  either B17 closed or the composer left with no guard lane, in which case it submits nothing.

**Call site.** Core constructs Ride in one place: the `call("ride.new", ...)` closure in
`create_ride` (`plugin/bike_runtime_core.lua:627-629`), which since `3e686fc` runs
`RideRuntime.new(api,ride_models,{body_handle=owner.body,incarnation=owner.incarnation})` with
`ride_models={contact=Contact}` bound at mount (`:816`). Under D6a the models become
`{contact=Contact,force=ForceStage.new()}`, where `ForceStage` is the trial-only wrapper below (not
written yet), still with no `tricks`. Under D6b they become
`{contact=Contact,composer=Composer.new(options)}`, a new Ride slot, and the composer and its
modules join the mount staging list (B14's pattern). Core keeps building `api` and its four
owner-bound closures (`:571-620`) and stays the only caller of Ride. `create_ride` runs once per
VM (`:554`), on the first following tick, after Follow is published. Per step, only `observe_ride`
(`:636-656`) calls `ride:observe`, and Ride calls the wrapper or the composer from inside it
(`plugin/ride_runtime.lua:407-525`). Cleanup stays in `drain_ride` and `stop_ride`
(`plugin/bike_runtime_core.lua:519-528`).

**What the D6a wrapper hands Ride** (`plugin/ride_runtime.lua:527-545`):

- `preview(h, body, wheels, samples, controls)` returning `model, candidate` (`:501`), `reset()`
  and `tuning.gravity` (`:450`). A model must be `valid` with finite `force`, `torque` and
  `hop_impulse`, and wheels Ride can copy (`:382-406`, `:508-510`). An invalid model stops the ride
  ("bounded force packet unavailable", `:507`).
- Ride keeps `models.mapping` empty, so it builds `Mapping.new(options.input)` (`:532`);
  `options.input` may come from `input_presets.lua`. `models.contact` is `contact_runtime`.
  `models.tricks`, `models.recovery` and `models.alignment` stay nil until their milestone. Core
  supplies `body_handle` and `incarnation` (`plugin/bike_runtime_core.lua:559-560`, `:628`); the
  wrapper must not.

**Stages, and where the literal lives.** One literal, for example `local STAGE = "zero_force"`, at
the top of the wrapper's trial copy (under D6b, in Ride's composer lane), changed only by the same
reviewed text substitution as the gates, never by an option, menu, manifest field or storage value:

| Stage | Milestone | What the wrapper's `preview` returns |
| --- | --- | --- |
| `zero_force` | M3 | A valid model with zero force, torque and impulse, after running the real kernel for diagnostics only. |
| `support` | M4 | The real kernel, with pedal, brake, steer, manual, nose manual and hop set to zero in the controls it passes on. The pad itself is not changed. |
| `pedal` | M5 | The real kernel with only `pedal` kept. A force above the authored cap (D5) gives an invalid model, so the ride stops instead of being clamped. |
| `full` | M7+ | D6b. |

**What neither may do.** Call any `reskate.*` function; own or construct a Source, body or Follow
(`plugin/ride_input.lua` is a separate input orchestrator, used only by its tests, and must not run
beside Core's Source); cast probes outside Core's closure, which allows one batch per native serial
(`plugin/bike_runtime_core.lua:575`); keep opaque handles past a step; return opaque or nonfinite
values in a status Core stores (`plugin/bike_runtime_core.lua:62-76`); flip a gate; or `require` on
the hot path (B14). Each pure suite must run on the standalone runner with no `reskate` API.

**Where the newer pure modules enter.** Under D6a, none before M7. `manual_balance.lua`,
`grind_policy.lua`, `bail_guard.lua`, `rail_probe.lua`, `trick_presentation.lua`,
`rider_presentation.lua` and `camera_policy.lua` all arrive together through the composer under
D6b. Their own limits still apply: `bail_guard.lua` needs a guard batch and witnesses and actor
exclusion (BAIL.md); `rail_probe.lua` needs a 30-ray batch and actor exclusion (RAIL_PROBE.md); the
presentation modules need a visual consumer that Core does not have, because `follow_visual` takes
only the body sample (`plugin/bike_runtime_core.lua:1001`; TRICK_PRESENTATION.md);
`camera_policy.lua` needs the `camera` permission (CAMERA.md). `input_presets.lua` is not read by
the mapper yet (INPUT_PRESETS.md). `sim_world.lua` and `sim_scenarios.lua` stay offline and predict
the M3 to M5 numbers.

## SDK capabilities still missing

| # | Capability | Evidence of the gap | Needed by |
| --- | --- | --- | --- |
| S1 | Actor-safe wheel rays. **Lane D1c (2026-10-26):** `71f0b9d1` adds `require_named_actor_categories_absent`, and P1 showed in game that the production request (camera preset plus that flag) hits the MPR floor and that camera rays crossing the rider stay clear, on sampled segments only. P2 (riding pose under Follow, with visual parts, falsifier F8) must pass before `CATEGORY_WHEEL_LANE_QUALIFIED` flips in a trial copy. Before that: `exclude_local_actor=true` returns `local_actor_exclusion_unavailable` before any cast. `query_preset="terrain"` sends one category bit, but nobody has measured whether the rider's shapes carry it. Terrain probe r1 was refused before casting. Terrain probe r2 cast all six of its rays and every one came back clear, its two floor rays included, so with no positive floor control its clear rider crossings answer nothing, and it says nothing about actor exclusion. Static research found that the native query compares shape-owner indices against an ignore list and that the nominated skater-creation query passes an empty list, but a complete current local-actor owner set is not yet producible from the qualified evidence. | `contrib/plugin-body-query.md:52-53`, `:96-121`, `:140`; `Engine/Game/Build/20260929/park_editor.h:75-84`; `Extension/World/owned_bodies.cpp:1178`; `build/bmx/actor-exclusion-research-v1/STAGE-2.md`, `STAGE-3.md`, `STAGE-4.md` | M3 |
| S2 | Sustained Follow. The lease is 3 s from reservation with no renewal in any runtime that has run in game. `5ec1fd90` adds an opt-in renewable lease (500 ms per accepted proof of the body's latest sample, 120 s ceiling) and `read_follow_lease`; it is built and tested on BMX but has not run in game. `callback_entry` continuation has been seen for 31 revisions (about half a second). | `contrib/plugin-body-follow.md:36-41`; `CP:185` | M6 |
| S3 | Evidence that nonzero forces move a body under the ride model. Three private trials applied one horizontal magnitude-106 command each and acknowledged it, twice on a body under Follow. Each body was falling, force units are uncalibrated, and no command has pushed a body standing on the floor. | `7b12f43`; `M3CP`; `M4CP`; `Engine/Game/World/owned_body.h:15`, `:107-117` | M4 |
| S4 | Park after motion. Park requires zero linear and angular velocity, force and torque. Codex's M3 and M4 observed park and ACK after one force on a falling body, and `0e0ddc8` made the angular zero check use XYZ. Park after sustained, Lua-driven motion on the ground is unproven; CE1's moving body never parked. | `Extension/World/owned_bodies.cpp:1066-1070`; `M3CP`; `M4CP`; `CP:65-70` | M4 |
| S5 | A body lifetime that can be reused. Eight body slots per process, parked bodies are never reused, so every body trial spends one slot. | `Engine/Game/World/owned_body.h:12`; `Extension/World/owned_bodies.cpp:744`; `CP:85-91` | M6 and later |
| S6 | Gap-free body samples. `read` returns the latest sample only, and Ride stops on any skipped serial (B12). Whether the Lua tick sees every 60 Hz step in practice is unmeasured, and so is whether each step has a fresh input observation (B15). | `contrib/plugin-body-query.md`; `plugin/ride_runtime.lua:432-433` | M1 (measure), M6 (fix) |
| S7 | A rider pose path for the mounted posture. Alignment produces requested targets only. | `RIDE_RUNTIME.md:37`; `plugin/rider_alignment.lua:329` | M8 |
| S8 | Known native collision for owned capsules. **M1 (2026-10-26): the world supports the body.** It touched down at 547 ms and rested with its wheel-bottom point 0.001 to 0.053 m above the MPR floor until it tipped over with no Lua forces. Before M1: whether the world also supports the body, on top of the Lua tire forces, was unknown. Every body in the force trials fell, which is consistent with no support at those spawn points but was not a ground test. | `Extension/World/owned_bodies.cpp:588-596`; `Engine/Game/Build/20260929/rigid_bodies.h:68`; `M3CP`; `M4CP` | M3 (measure) |
| S9 | A general per-read probe batch budget, so that Core can grant one read more than one `probe_batch` and account for the 64 shared logical requests per tick. Grinds and bail need at least 3 batches per read offline. | `Extension/Plugins/plugin_vm.h:43`; `plugin/bike_runtime_core.lua:575`; `RIDE_COMPOSER.md` "Gaps found" item 1 | M7 |

S1 has two possible paths, and decision D1 picks one:

- **D1a, SDK.** The general building block: honor `exclude_local_actor=true` only when the SDK can
  prove that no local-actor shape is tested, either by real exclusion or by checking the actor's
  shape categories against the preset mask. The result stays honest: `local_actor_excluded=true`
  only when proven. If the wheel batch names no preset, Ride, Contact, the composer, the trick
  adapter, the rail probe and the bail guard need no policy change. If it names one, Contact already
  accepts the echo (`d403c25`). This needs native work under the AGENTS.md address rules, and the
  static research above has not yet found a complete owner-set producer to build it on.
- **D1b, Lua lane.** After M2 shows terrain rays never return rider shapes in the riding pose, Ride,
  Core, Contact and the composer accept `exclude_local_actor=false` plus
  `requested_query_preset="terrain"` as a separately named provenance, never reported as
  actor-excluded. That touches Ride's exclusion check (`plugin/ride_runtime.lua:350-352`), Core's
  closure (`plugin/bike_runtime_core.lua:572-573`) and the composer's
  (`plugin/ride_composer.lua:175-178`). It relaxes the rule in `RIDE_RUNTIME.md:35` ("there is no
  `exclude_local_actor=false` fallback"), so it needs the owner's explicit approval. It should stay
  inside private trial copies.

## Gates and when they open

| Gate | Where | Today | Opens |
| --- | --- | --- | --- |
| `qualification_only` | `plugin/main.lua:5`, read at `plugin/bike_runtime.lua:19` and `plugin/bike_runtime_core.lua:19` | false; private trial mains pass true | Stays false in the tracked `main.lua` until M9. |
| `RIDE_COMPOSITION_QUALIFIED` | `plugin/bike_runtime_core.lua:12` | false | True only in private frozen trial copies from M3. In the tracked tree, only after M5 passes review; public Mount is still denied by the row above. |
| `ACTIVATION_QUALIFIED` | `plugin/ride_runtime.lua:3` | false | Together with the row above, by the same reviewed source transform the Host fixture uses (`Extension/Plugins/Test/bmx_contact_runtime_host_fixture.inc:16-22`). |
| Stage literal (proposed) | The D6a wrapper's trial copy; under D6b, Ride's composer lane | Neither exists. `plugin/ride_composer.lua` has no stage literal (its `Composer.modes`, `:76`, are riding modes). | `zero_force` M3, `support` M4, `pedal` M5; the full composer at M7 (D6b). |
| Ride limits (proposed literals in Core and `bike_spawn.lua`) | B4, B5, B8, B9 | exact zero, 500 ms, 2 m, 400 reads | Raised in the M5 trial copy only; see M5. |
| `world.raycast` permission | `reskate-plugin.json:5` | absent | M2 trial manifest; tracked manifest at promotion. |
| `camera` permission | same | absent | M8. |

Keep every gate a literal. A private copy flips it by a reviewed text substitution with pinned
hashes, as the earlier packages did (runbook, [Evidence locations and
conventions](../RUNBOOK.md#evidence-locations-and-conventions)). No option, menu click, manifest
field or storage value opens one.

## Milestones

Each milestone needs the one before it. Each trial is one attempt in its own operator folder; a
refusal is kept, never retried, extended or re-armed (runbook, [Evidence locations and
conventions](../RUNBOOK.md#evidence-locations-and-conventions)). Every trial that creates a body
spends one of the eight slots for that process (S5), and a fresh plugin VM needs a new namespace and
storage key (runbook, [Fresh VM for spent intents](../RUNBOOK.md#fresh-vm-for-spent-intents)).

### Milestone status at `2584bcd`

| Milestone | Status | Evidence |
| --- | --- | --- |
| M0, offline readiness | Partly done in source. B3, B7, B13 and B14 in `3e686fc`; B10, B16 (D8) and B15(a) (D7's proposal) in `1b5e57f`; Contact's preset echo in `d403c25`. Not written: the D6a stage wrapper and its suite, Ride's stop-reason and cadence counters, and a kept offline M3-M5 prediction. D2 and D6 are not taken. | Commits above; pure-runner receipt in the runbook |
| M1, tracked core repeats CE2 | Not run. The tracked core has never run in game. Codex's M3 and M4 covered part of what M1 would show, on private packages: Follow completed, parked and was acknowledged with a force on the same body, and an input lease was released and acknowledged in the same lifecycle. They did not record actor-root tracking, Follow publish time against the controller, or report cadence. | `M3CP`, `M4CP` |
| M2, wheel rays in the riding pose | Not answered. Terrain probe r1 was refused before any cast. Terrain probe r2 (M2a's attempt) cast its six rays and all came back clear, both floor rays included, so it has no positive floor control and does not pass M2a. | `build/bmx/claude-handoff/to-claude/terrain-probe-trial-20261025T2130Z/RESULT.md`; `build/bmx/claude-handoff/to-claude/terrain-probe-trial-r2-20261025T2202Z/RESULT.md` |
| M3, composed zero-force cadence | Not run. The gates have never been true in game. | |
| M4, first nonzero force standing still | Not run as defined. The force trials (S3, S4) are partial SDK evidence only: one command each, on a falling body, with uncalibrated units. | `7b12f43`, `M3CP`, `M4CP` |
| M5 to M9 | Not started. | |

### M0. Offline readiness (no game)

- Decisions taken at review: D6 (how the composer joins) and D2 (pipelining) before M4. D7 and D8
  are implemented in source by `1b5e57f` and need only the owners' confirmation.
- Under D6a, the stage wrapper lands with its pure suite. A gate-flipped scratch copy runs it with
  the real Ride, Contact, Forces and Mapper, the way `ride_runtime_tests` runs today.
- Core changes B7, B13 and B14 are done (`3e686fc`). Still to do in Core: the ride-limit literals
  for B4, B5 and B9, left at today's values.
- Ride: B10 and B16 are done (`1b5e57f`). Still to do: a recorded counter for each stop reason, and
  bounded counters for body steps without a fresh report, the largest report gap and `grounded`
  changes (split by whether that step had a report), so M3 can tell B12's two causes and B15's two
  causes apart.
- A kept offline prediction of M3 to M5 with Ride's real cadence: commands on every other step
  (B11), carried wheels (B16 as now committed), and 50 Hz reports against 60 Hz steps. The
  simulator's own baseline, with a command every step and carried wheels, is 3 m/s after 1.20 s
  (`SIMULATION.md:149`); the composer suite has the same assumptions (C8).
- A scratch probe run during the first review gives a first estimate. It used a flat `sim_world`
  heightfield, `World.place` at rest, the real `forces.lua` kernel (either `step` with carried
  wheels, the simulator's pattern, or `preview` then `reset`, Ride's pattern before `1b5e57f`),
  `World.integrate` with zero force on uncommanded steps, and no native collision. "Every other"
  sends a command on odd steps only. A step j had a fresh report when `floor(50 j / 60)` advanced.
  `grounded` is `World.supported` on either wheel; pedal is taken from the latest report and is zero
  when that report was not grounded (`plugin/input.lua:231`). A held, 1 s pedal followed by a 0.5 s
  coast gave:

  | Commands | Wheels | Speed after 1 s | Distance after 1.5 s | Speed after the coast | `grounded` changes in 90 steps | On steps without a report | First such step |
  | --- | --- | --- | --- | --- | --- | --- | --- |
  | Every step | Carried | 2.49 m/s | 2.51 m | 2.53 m/s | 0 | 0 | none |
  | Every step | Zero each command | 0.70 m/s | 0.68 m | 0.12 m/s | 0 | 0 | none |
  | Every other | Carried | 0.89 m/s | 0.90 m | 0.89 m/s | 79 | 13 | 13 |
  | Every other | Zero each command (Ride before `1b5e57f`) | 0.42 m/s | 0.41 m | 0.17 m/s | 79 | 13 | 13 |

  At rest with neutral input, every-other-step support changed `grounded` on 83 of 90 steps, 13 of
  them on steps without a report, and the body settled 9 mm. Under the B15 rule before `1b5e57f`,
  the first such change would have stopped the ride at step 13, about 0.2 s in. These are model
  numbers from a suite that is not in the tree. They depend on S8 (no native collision was
  modelled) and on the unmeasured report phase. They are not in-game evidence, and they have not
  been rerun against `1b5e57f`.
- Pass: every pure suite passes; CTest `plugins` passes; the Host still finds both literals false in
  the tracked tree (`Extension/Plugins/Test/bmx_contact_runtime_host_fixture.inc:18-24`).

### M1. The tracked core repeats CE2 (gates false)

Purpose: run the tracked core in game for the first time, and measure what M3 to M5 depend on.

- Package: tracked modules (B7 is now in them), a private `main.lua` that passes
  `{qualification_only=true}`, the CE2 manifest, a new namespace. Add bounded diagnostics: the
  actor position from `skater.get` against the body position plus the rotated Follow offset on each
  following tick; the Lua wall time of `follow.publish`; a histogram of body serial steps between
  successive reads; a histogram of Lua tick `dt`; and, for each following tick, whether the
  selected source's `observation_serial` advanced, its `observed_ms` delta, and how many body steps
  passed between fresh observations.
- Sequence: the runbook's [In-game trial procedure](../RUNBOOK.md#in-game-trial-procedure),
  steps 1 to 16 unchanged, scenario `neutral-window-20s`.
- Pass: phase Done with Completed+ACK; final revision equals returned revision; park observed;
  Source complete with no report debt; eight removals accepted; saved storage matches the page; the
  actor root stays within 5 cm of the body-derived root on at least 90% of following ticks.
- Fail: `retained_unknown`, unobserved park, a root that does not follow, or any page/storage
  mismatch. Stop the ladder and diagnose. CE1's screenshot showed the bike beside the rider after 30
  returned revisions (`CP:61-62`), so "Follow published" is not yet proof that the root moves.
- Record for later steps: the time from the controller's first scheduled report to Follow publish
  (it sets the neutral lead in M5; the driver ledger logs UTC per report,
  `contrib/bmx-lab/virtual-gamepad.md:97`, so the diagnostic must log publish in UTC too); how
  often a read skipped a physics step; the share of body steps with no fresh observation and the
  largest observation gap. If observations arrive at the game's poll rate rather than the 50 Hz
  report rate, B15's remaining risk shrinks; if gaps over 100 ms appear with a quiet machine,
  B15(b) needs a driver or scheduling fix before M3.

### M2. Wheel rays in the riding pose (gates false)

- M2a: an owned diagnostic body, zero force, no Follow, `query_preset="terrain"`,
  `exclude_local_actor=false`, with a joint warm-up before any cast. The r1 attempt was refused at
  its first joint read. The r2 attempt warmed up and cast all six rays, but every ray came back
  clear, its two floor rays included (runbook, [Terrain probe
  r2](../RUNBOOK.md#terrain-probe-r2-at-2158z)). With no floor hit, its clear rider crossings
  cannot be read as misses of the rider, so M2a is still open, and r2 says nothing about actor
  exclusion. The next attempt needs a floor control that hits (runbook, [Next in-game
  trials](../RUNBOOK.md#next-in-game-trials), trial 1).
- M2b repeats it during a published Follow interval with the actor attached. It casts the two
  wheel rays Ride would cast (`plugin/ride_runtime.lua:327-342`), one control ray down through the
  actor's own column, and one batch with `exclude_local_actor=true` to confirm the zero-cast refusal.
  The diagnostic reads the batch itself; Contact would now accept the preset echo (`d403c25`), but a
  terrain batch still reports `local_actor_excluded=false`, which Ride refuses.
- Pass: available batches; both wheel rays hit within 2 cm of the known floor height with
  `normal·up >= 0.99` and surface speed below 0.01 m/s; the control ray hits the floor below the
  actor, or is clear, never a point above the floor inside the actor's column;
  `requested_query_preset` echoes `"terrain"`; `native_casts` lies between the ray count and twice
  it (`contrib/plugin-body-query.md`).
- Fail: any hit inside the actor's column above floor height. That rules out D1b.
- If D1a lands first, M2b instead checks that `exclude_local_actor=true` returns available batches
  with `local_actor_excluded=true` and the same floor hits. M2 is needed either way, because no
  exclusion path has been seen working in game.
- Then the owner takes decision D1.

### M3. Composed zero-force cadence (gates true in the trial copy)

- Package: M1's package with both literals flipped, the D6a wrapper at `zero_force`, no tricks,
  recovery or alignment, `world.raycast` in the manifest, the D1 contact lane, and the M0 Ride
  counters. The 500 ms window is unchanged.
- Sequence: as M1.
- Record: every stop reason with its counter; each body step without a fresh report; the largest
  report gap; every `grounded` change with its serial and whether that step had a fresh report;
  the body height over the window (S8: does native collision hold the body under zero force?).
- Pass: the ride stops only with a reason that begins "ride window or Follow lease ended"; every observed
  body step was one serial on; every receipt was `applied`; no `expired` or `rejected` receipt and no
  `body_epoch_expired` or `body_clock_unavailable` refusal; `submitted` equals `acknowledged` (or the last one
  closes as `parked_without_successor`); `force_cleanup_clear` true; then all of M1's cleanup checks.
  The Host must not stop the plugin for its time limits.
- Fail: any other stop reason, `force_cleanup_unknown`, or `retained_unknown`. A failure caused by
  B12 needs a Ride decision before M4: skip a late step, or keep stopping. A stop with "non-initial
  model cadence unavailable" is classified from the record as a ground change the held projection
  did not cover, or B15(b) (a report gap), and goes back to D7.

### M4. First nonzero force, standing still

- Package: M3's package with the wrapper at `support`, on the floor patch M2 measured, with D2
  decided.
- Expectation: the kernel supplies roughly the 1,039 N weight of the 106 kg body
  (`plugin/bike_geometry.lua:33`) through the tire rows on commanded steps. With commands on every
  other step (B11), Lua alone supplies about half the weight on average. In the M0 probe, with no
  native collision, that made `grounded` change on nearly every step. `1b5e57f`'s held projection
  now tolerates a ground change between reports for a primed mapper; whether native collision also
  holds the body (S8) is what M3's height record says.
- Record: as M3.
- Pass: over the window the body height stays within 2 cm and horizontal drift within 2 cm, speed
  stays below 0.2 m/s, all of M3's receipt rules hold, and the body then parks and Follow completes
  with ACK. This is the first park after motion the Lua model caused on the ground, so it also tests
  S4 beyond Codex's M3 and M4.
- Fail: sinking or lifting past those limits, a failed park, or a stop with "non-initial model
  cadence unavailable" (classified as in M3). Compare with M3's zero-force run to learn whether
  native collision is also holding the body up (S8).

### M5. First mounted ride: pedal in a straight line

- Package: M4's package with the wrapper at `pedal`, and these limits raised in the trial copy
  only:
  - Ride window: up to 2,500 ms after publish, and never past 2,900 ms after reservation, inside
    the 3,000 ms Follow lease (`plugin/bike_runtime_core.lua:685`, `:690`;
    `Extension/Skater/native_body_follow_service.cpp:71`).
  - Visual envelope: 2 m to 6 m (`plugin/bike_spawn.lua:118`, `:249`).
  - Follow read cap: sized to five reads per tick over the window (B9).
  - Input: exact zero until Follow publishes, as today; after that the mapper's actions.
  - An authored cap on speed and force (D5).
- Scenario: a new fixed timeline. Hold neutral for a lead taken from M1's report-to-publish time
  plus a margin, press A for 1,000 ms, then neutral to 6 s. The driver allows fixed timelines up
  to 6 s only (`contrib/bmx-lab/virtual-gamepad.md:77`). The existing `ground-pump` row presses A
  at 240 ms (`contrib/bmx-lab/virtual-gamepad.md:85`), before publication, so Core would stop on
  B4 first. The new scenario needs its own reviewed driver change (decision D4). It must end
  neutral, or the capture keeps report debt (`contrib/plugin-input-lease.md:171-177`).
- Record: as M3, plus distance, speed and yaw over the window.
- Pass: while A is held, the body moves along its own +Z by between 0.3 m and 3 m, its speed rises,
  lateral drift stays under 0.3 m and yaw change under 0.2 rad; the actor root follows as in M1; the
  ride ends only on the planned window; Follow completes and parks with ACK after motion; the force
  ledger clears; input drains; eight removals are accepted. The measured distance is compared with
  M0's prediction for the cadence and wheel handling actually shipped. The simulator is a model,
  not a target. If M0 predicts less than 0.3 m for that build, fix the cause before spending a
  slot on M5.
- Fail: any other stop, including "non-initial model cadence unavailable" (classified as in M3),
  a body that does not move under A, a body that moves without A, a park failure, or a root that
  does not follow.
- Only after M5 passes review do the literals flip in the tracked tree, with
  `qualification_only` still false in `main.lua`.

### M6 to M9. After the first ride

- **M6, rides longer than 3 s.** Needs S2 and a qualified `callback_entry` continuation for that
  long, park after longer motion (S4), and a decision on B12 (S6). Then the S01 flat-ground trials of
  `contrib/bmx-lab/judging/rubric-v2.json` become possible.
- **M7, controls and the composer.** The composer joins through D6b, with C1, C2, C6 and B18 done.
  Steering, braking, hops (the existing `bunnyhop-tailwhip` timeline,
  `contrib/bmx-lab/virtual-gamepad.md:88`) and manual balance come with it. The bail guard and rail
  probe stay uncast, and so the composer submits nothing, until S9 lets Core grant more than one
  batch per read and S1 is settled.
- **M8, presentation.** Rider posture (S7, and the rider alignment visuals the runbook lists under
  [Next in-game trials](../RUNBOOK.md#next-in-game-trials)), bike articulation from
  `rider_presentation.lua`, tricks once a native owner reports `measured_support`, and the chase
  camera with the `camera` permission.
- **M9, public Mount.** `main.lua` construction, manifest, README and judged footage.

## Risks

1. **Rider hits on terrain rays.** If any rider shape carries the terrain bit, D1b would let the
   rider's own body read as ground (`contrib/plugin-body-query.md:104-110`). The Static preset also
   lacks that bit, so some ramps and props are not tested at all. M5 stays on M2's measured patch.
2. **Lua cadence against 60 Hz physics.** One frame longer than a step, or one late submit, ends
   the ride (B12). An open-world game has hitches; the ride may last only until the first one.
3. **Input cadence against 60 Hz physics (B15).** With 50 Hz reports, any report gap over 100 ms
   ends the ride. `1b5e57f` covers a ground change between reports for a primed mapper; an
   unprimed or blocked mapper still resets on one.
4. **Half-rate forces and per-command resets (B11).** Handling will differ from the simulator,
   which applies a command every step. In the M0 probe, every-other-step commands with carried
   wheels reached 0.89 m/s after 1 s of pedal, against 2.49 m/s with a command every step.
5. **Park after motion (S4).** If a body moving on the ground does not park, each ride leaves
   `retained_unknown`, holds a slot and blocks stock switching (`plugin/bike_runtime_core.lua:151-159`).
6. **Follow and the native skater.** The root may not track a moving body. If the game changes
   the actor's state while it is dragged, Core stops on readiness
   (`plugin/bike_runtime_core.lua:927`, `plugin/bike_admission.lua:106-115`). That stop is safe,
   but it ends the ride.
7. **Double or missing support (S8).** If the world also collides with the capsules, Lua forces and
   native contact fight; if it does not, the body falls on every uncommanded step.
8. **Two ride models.** Under D6a the first ride runs Ride's own Mapping and kernel, not the
   composer. What M5 shows about handling then says little about the composer, and D6b's changes
   still have to be proven at M7.
9. **Time budgets.** 50 ms per call and a 2 ms average tick (`Extension/Plugins/plugin_vm.h:30-33`).
   Ride adds up to 12 input reads per body observation (`RIDE_RUNTIME.md:13`), the composer chain
   takes 34-43 ms to require (`RIDE_COMPOSER.md` "Per-tick cost"), and the composed tick's cost in
   game is unmeasured (`LUA_RUNTIME_BUDGET.md:9`).
10. **Ray budget.** 64 logical requests per tick shared by every query
    (`Extension/Plugins/plugin_vm.h:43`); the composer's worst read is 81 (`RIDE_COMPOSER.md`
    "Gaps found" item 1).
11. **Storage size.** The ledger refuses over 48,000 bytes and stops everything on a storage fault
    (`plugin/bike_runtime_core.lua:222`, `:228-230`). New diagnostics must stay bounded.
12. **Operator timing.** The 40 s ready-to-GO limit and the 60 s driver gate stay as they are, and
    one screenshot round trip has already used up a 40 s window (runbook, [In-game trial
    procedure](../RUNBOOK.md#in-game-trial-procedure)).
13. **A runaway force.** The SDK accepts 40,000 N (`Engine/Game/World/owned_body.h:15`). With the
    actor attached, a launched body drags the rider, a rubric hard failure. The envelope stop and the
    authored caps in D5 bound this; nothing else does.
14. **Shared working tree.** Several agents have edited Core, the World backend and this folder in
    one day. Line numbers here will drift; recheck them before review.

## Decisions for the owner

- **D1.** Actor exclusion: SDK (D1a, recommended) or a terrain lane in private trials (D1b).
  Contact already accepts the preset echo either way (`d403c25`).
- **D2.** Accept every-other-step forces for M4 and M5, or pipeline commands first (B11).
- **D3.** Whether the first mounted ride must show a BMX riding posture (moves S7 before M5).
- **D4.** Approve a new fixed `pedal-straight` controller timeline for M5.
- **D5.** Authored caps for M4 and M5: maximum force magnitude, maximum speed and envelope radius.
  These are our own choices, not measured or recovered values.
- **D6.** How the composer joins Ride: a stage wrapper for M3 to M5 with the composer at M7 (D6a,
  recommended), or a Ride composer lane earlier (D6b). A cross-item decision for the composer,
  Ride and Core owners.
- **D7.** B15 tolerance. `1b5e57f` implements the proposal: for a ground change between reports a
  primed mapper re-derives its actions from its last admitted raw snapshot with zero elapsed time
  instead of resetting, and a late report keeps stopping, since the lease itself treats
  observations older than 100 ms as stale (`contrib/plugin-input-lease.md:96`). The Ride and
  Mapper owners confirm or change it.
- **D8.** Wheel speeds (B16). `1b5e57f` implements the proposal: Ride keeps the wheel speeds of the
  command whose receipt was `applied`. The Ride owner confirms or changes it.
- **D9.** How the composer gets more than one batch per read (B17, S9): a general SDK per-read
  budget that Core grants, a merged wheel-plus-rail batch, or a native guard query
  (`RIDE_COMPOSER.md` "Gaps found" item 1). Needed before M7.

## What this plan does not establish

It is read-only analysis of the source, docs and checkpoints. It ran no game. The pass thresholds
are authored proposals. Constructed suites, including every pure module suite and the composer's,
are not in-game evidence. Codex's M3 and M4 checkpoints are private trials of single force
commands on falling bodies; they show neither riding nor ground support. The M0 probe numbers come
from a scratch suite run once during the first review on the standalone runner from a temporary
copy of `plugin/`; it is not in the tree, modelled no native collision and has not been rerun since
`1b5e57f`. An independent review reported reproducing B15's two stop paths and B2's preset
rejection with scratch suites against the Ride and Contact of that time; those suites were not
kept, and `1b5e57f` and `d403c25` have since changed both paths. None of the open blockers above has
been confirmed in game, because the gates stay false; each one follows from the cited code.

# BMX Luau migration

This integration gives the entry one bike lifecycle owner. Private v3 Host
validation with constructed fixtures passed startup (14 cases, 2,790 assertions)
and lifecycle (14 cases, 2,884 assertions). The normal Release plugin regression suite also passed; 15 optional contributor examples were absent. Public mounting
remains disabled, and this package is not rideable; native gameplay and performance
parity remain unverified.

This package starts the migration of **all** BMX feature policy to a Lua mod.
`plugin/input.lua` is a real pure-Luau port of the current
`Engine/Game/BMX/bmx_input.h`: settings sanitation, radial normalization, source
and lifecycle gates, pedal/brake mapping, charged and R3 hops, manuals, airborne
pitch, modifier priority, neutral rearming and all trick-selector sectors.
`plugin/catalog.lua` preserves all58 named IDs and the six empty cells in the
eight-by-eight authored selector. These are requests, not executed or landed tricks.

`plugin/tricks.lua` ports the trick controller into Lua. It tracks neutral-rearmed
bar/whip channels, all catalog movements, timed catches and recovery, limb release,
measured body-local quaternion turns, canceled attempts and its own landing tally.
`plugin/motions.lua` contains our bounded retargeting targets and timings for all
58 IDs; it contains no extracted clips or source asset IDs. These targets do not
rotate a native body. The inspector does not activate this controller for riding.

`plugin/forces.lua` and its math, tire, brake and pump modules now port our ordinary
single-body riding policy. The actual Host test passed 25 cases, 2,618 assertions,
83 C++ comparisons and 18 direct projections against our retained C++ model in the
2026-10-25 receipt listed under [Tests](#tests). This preserves our proposed laws;
it is not recovered Streets physics or verified riding feel.
See [FORCES.md](FORCES.md) for inputs, candidate history and remaining limits.
The reviewed optimization reduced offline actual-Host braking from about 17.2ms
to 0.82ms, with default slope cases around 1.79ms. The selected fixed-input runs
passed the normal rolling watchdog, but whole-plugin/native performance and
optional 128 iterations remain unqualified. Gameplay stays inactive pending
correct native contacts and complete-adapter performance evidence.

`plugin/equipment.lua` ports the neutral-rearmed toggle, North tap/hold and
LB/L1+North shortcut into pure Lua request policy. It consumes invalidated
shortcuts without leaking a tap, hold or deferred switch to another source or
owner. Its separate Host case loads the actual modules without permissions and
compares typed traces against the retained C++ gesture rules. See
[EQUIPMENT.md](EQUIPMENT.md) for composition and ownership requirements.
Release Host execution passed **8 groups, 1,269 assertions and 160 C++
comparisons**, with zero native actions, under the normal VM limits.
The explicit menu adapter now composes the generic bounded input-report API
with `plugin/equipment_transition.lua`. It preserves the full terminal receipt
before acknowledgement, then independently observes a stable target state.
See [EQUIPMENT_RUNTIME.md](EQUIPMENT_RUNTIME.md) for the stock switching path
and its validation boundaries. The bike lifecycle owner now decides whether a stock request is allowed; the stock adapter itself does not own a bike or rider.

Create it with `require("./tricks").new(settings)` and call
`controller:update(native_seconds, Tricks.input(observation))`. The adapter must
supply measured heading/orientation, actual support and qualified native elapsed
time. Ground must be observed before a flight; first contact freezes channels and
cannot complete a trick or manufacture a catch. Enable landing quality on clear
frames as well as contacts. A settle-hold flag requires fresh adapter proof and
is capped at 200ms; it never counts as actual support. Those observations still
need the generic native transport below before gameplay activation.

The Lua owner token is a stable nonempty string (up to 128 bytes), or a positive
integer up to 2^53-1. Do not cast a native uint64 pointer or generation to a Lua
number. Device epochs remain uint32. Tallies saturate at 2^53-1, the last exactly
represented integer, rather than C++'s uint64 maximum. Failure IDs are enum names
such as `under_rotated` and `invalid_sample`. Lua also rejects malformed boolean,
direction/device fields and nonfinite heading differences. State/settings readback
is detached; caller-owned quaternion tables are copied when retained.

The entry constructs exactly one `BikeRuntime.new()` with default options. That
owner creates the equipment adapter, selected input source and spawner; main
never constructs or drives a second owner. Requiring modules and constructing
it perform no reskate API calls, storage access or actuators. Main only registers
its menu and tick/unload callbacks at load. An idle tick remains inert while the
inspector is stopped. The Host's automatic storage-file loading is separate from
Lua entry behavior.

The public page remains PLUGINS → BMX Lua migration. Its slot-specific **Mount
bike (unavailable)** actions call the owner and return the native lifecycle
qualification denial before any game or storage call. There is no UI, storage
or configuration setting that enables qualification. **Stop bike / cleanup**
latches stop through the same owner. Cleanup continues on ticks even when
controller inspection is stopped. Stop freezes further body reads and entity
SETs; unresolved Follow/body duty remains visible and cannot silently re-arm.
The SDK's VM-close cleanup remains authoritative and is not a successful dismount.

**Switch skateboard / on foot** still requests one bounded Y report after the
menu closes and a settled baseline is observed. Choose an explicit XInput slot
from0 through3 and release every control; reopening the menu interrupts an
active attempt. The owner rejects stock switching while any bike authority,
acquisition, retained reload marker, or unknown/unresolved cleanup exists. The
switch phase and result distinguish input-report cleanup from the observed
stock state. No physical LB+Y shortcut is bound and no automatic board return
occurs. Nothing invokes the old BMX console, C++ controller or private mode.

The extracted lifecycle also contains a separate private qualification mode for
reviewed Host/native development. Public main never passes that option. It is
one zero-force Follow attempt per VM, bounded to500ms, with no automatic retry,
body reuse or continuous Follow renewal. Existing input-lease freshness renewals
do not extend Follow. The native Follow service independently has a fixed
three-second lease from reservation and one process-wide receipt slot; its
opt-in renewable lease (`renew_follow`, permission `world.physics.follow.renew`)
is used only by a reviewed trial copy of `bike_runtime_core.lua` with
`FOLLOW_RENEWAL_QUALIFIED=true` and that permission in its manifest, which
renews on its first following tick and then only while less than 475 ms of its
lease is left, each time with that tick's body sample (LUA-12). The
tracked source and manifest do neither. The SDK retains at most eight native body allocation slots for the
process lifetime, including failed/partial attempts. Native destruction remains
unproven and slots are not recycled; capacity may already be exhausted before
this VM starts. One attempt per VM is not an eight-retry entitlement, and VM
unload does not reset native capacity. These are development bounds, not a
playable session policy.

The promoted `bike_spawn.lua` is the reviewed FirstFollow extension: it transfers
future body-release ownership before Follow reserve, keeps that transfer
permanent after failed/partial reserve, and updates visuals only from supplied
measured samples. Main never exposes its standalone diagnostic request/retry
methods. Published/transferred visuals remain until the owner observes matching
completed Follow cleanup and accepted ACK, or accepted ordinary caller release
for a provably never-published abandonment. Unknown outcomes retain duty. A
native archive of 2026-10-24, from before the `callback_entry` Follow policy,
reached twelve normal FOLLOW returns but stopped on a lifetime change with body
park and retirement unresolved; it proves no mounted alignment, native input
consumption or riding. Later private trials on 2026-10-25, among them CE2 and
Codex's M3 and M4, observed park and ACK (see
[the takeover runbook](../RUNBOOK.md#what-the-game-has-shown)); they prove none
of those either.

The manifest preserves `input`, `input.control`, `skater.read`, `menu` and
`storage` for the inspector, bounded stock reports, current actor facts, menu
registration and explicit-intent ledgers. Five additional permissions match
actual transitive lifecycle calls, rather than enabling public mounting:

| Permission | Transitive use |
| --- | --- |
| `input.lease` | Selected-source lease/read/state/freshness/release/ACK calls. |
| `input.capture` | Selected-source capture/state/release/ACK calls. |
| `world.physics` | Spawner body create/read/release and the Follow prerequisite. |
| `world.physics.follow` | The lifecycle's reserve/publish/read/stop/ACK Follow calls. |
| `world.entities` | Eight-part bounds/readiness checks and visual SET/removal requests. |

No mesh assets ship in this source package. Qualification requires a separate
compatible resource layer registering `reskate/bmx/{frame,fork,rear_wheel,
front_wheel,cranks,handlebars,left_pedal,right_pedal}`. Asset preflight stays
bounded to one bounds lookup per tick and eight ready IDs. The isolated
prototype resource pack used in prior development remains private and retains
donor native material/LOD dependencies; it is not a distributable free-asset
pack. A raw FBX in a Lua folder does not register native meshes. Original or
verified reusable resource assets and a clean-install test remain necessary.

For the separate read-only inspector, choose a model context and Observe
controller, close the menu, then release every control. Reopen the page to see
the last sampled requests. The selected grounded/airborne context is a model
argument, **not measured support**. Tick timing is wall-time, **not the native
physics clock**. Opening a menu, focus loss or gaps above100ms resets the model.
The panel does not claim that a hop or selected trick reached the game.

The pure mapper takes `update(raw, {grounded = boolean}, seconds)`. Build raw
values with `Input.raw`; its defaults match the original C++ aggregate. `device`
is a caller-supplied uint32 source epoch, changed on source replacement. The
current `reskate.input.gamepad()` supplies sticks/buttons but lacks device ID,
packet identity and sampling epoch. The inspector therefore uses an explicitly
manual source epoch and resets it on request; it cannot detect a replacement
pad reusing the same slot. This inspector remains separate from the lifecycle's
selected-source lease/capture path. Neither path invents physical-device identity
from the PS flag or claims native input consumption.

`plugin/tests.lua` contains portable tests of the actual Lua policy.
Requiring it does not run tests. The unconditional plugin Host regression loads
these actual package modules and calls `require("./tests").run()`. Coverage
includes all16 modifier combinations over8 directions, the full64-cell catalog,
empty slots, selector angle/radius/trigger boundaries, held and canceled hops,
manual and quick-hop context transitions, airborne pitch, neutral rearm,
focus/source/timing resets and sanitized settings. The Release build and actual
Host execution passed on 2026-10-23: **12 cases, 1,216 assertions, zero native
actions**. Unfiltered CTest reported 192 passes and one explicit rootless
trainer-tuning skip; other optional contributed-plugin fixtures and game-resource
branches also reported missing inputs. The BMX and Camera Inspector Host cases
run unconditionally. The separate `plugin/trick_tests.lua` suite also passed
actual Host execution: **16 groups and over 300 assertions**, including all 58
movement identities, catches, recovery, frozen landing settlement, interrupted
attempts, body-local quaternion turns, busy-request consumption and tally bounds.
This validates Lua model and sandbox integration;
this package has not yet been installed or tested for real riding in the game.

The experimental [`world.physics` API](../../Owned%20Bodies%20API.md) now provides
opaque owned bodies, measured state and bounded commands with a four-record
receipt pipeline. Portable and Host tests pass. A [native one-body trial](../luau-native-body-trial.md)
also created one 12 kg capsule, applied one 48 Ns impulse, observed its successor
and parked the allocation on release after explicit clock warmup. A
[separate native diagnostic](../native-pipeline-trial/README.md) then completed
120 consecutive constant-force commands with measured successors and ordered
acknowledgements. Whole-session 60 Hz operation, the BMX controller, other body
compounds and cleanup of an active body during unload, world changes or partial
failures remain unqualified.
A [varying-force diagnostic](../native-phase-trial/README.md) also measured
N+2 velocity visibility for commands requested at N and applied at N+1. The
adapter must reconcile that phase before pairing modeled history with measured
body state; applied setters do not prove an integrated N+1 response.

Generic input lease/capture, owned-body query and Follow APIs now exist. These
native integration boundaries remain unqualified for riding:

- Actor-safe wheel support, contact normals and surface velocity must be composed
  with measured body/epoch facts before force publication. [Owned-body batches](../../plugin-body-query.md)
  bind observations and bounded exclusions; API availability does not prove that
  native actor/self-hit exclusion or complete contact/force composition works.
  The earlier [native geometry diagnostic](../native-geometry-trial/README.md)
  returned two hits with actor exclusion explicitly false and no force commands.
- Selected-source capture reports process input-buffer publication, not native
  input consumption or physical-device identity. The lifecycle does not infer
  those facts from a successful lease, report, capture or transport completion.
- [Follow](../../plugin-body-follow.md) supplies a bounded local-actor/body
  binding with strict lifetime checks. The normal-return evidence of 2026-10-24
  left body park/cleanup unresolved; on 2026-10-25 CE2 and Codex's M3 and M4
  private trials observed park and ACK with `callback_entry`, over at most 31
  revisions. None of it establishes mounted alignment or a renewable riding
  lifetime, and none connects the ride model's pose, forces or recovery.

Upstream35824f4 adds `skater.carry`, pose/reach visibility options and
`camera.cycle`. Reuse them in the full migration. The latter integrates the
camera-height button's enter/leave cycle; it is not a render-phase callback or
a physics step fence. Existing `events.physics` is delayed skater telemetry,
and `skater.set_velocity` acts on the native skateboard, not a plugin bike body.

The target architecture keeps all BMX mapping, hop/turn/contact laws, geometry,
part articulation, rider IK/pose choices, trick judging, equipment sequencing,
carry, fall and recovery policy in Luau. C++ provides only reusable, permissioned,
bounded native ownership/physics/render/input/action primitives. No legacy
BMX-specific C++ baseline is proposed as the final implementation. This first
package changes no ride feel yet; future hop/steering policy changes belong here
once the real generic body transport can execute and acknowledge them safely.

## Tests

Each tracked suite below is a Lua module whose `run()` returns its case and
assertion counts. These are constructed tests of the Lua model and the sandbox.
They are not in-game evidence and earn no rubric score. Commands, build rules
and the in-game procedure are in [the takeover runbook](../RUNBOOK.md).

There are three harnesses:

- **Host**: CTest `plugins` (`dingosdk_plugin_tests.exe`) loads the actual modules
  into the real plugin Host with no permissions and the default 50 ms call limit
  (two suites raise it for themselves, as marked). It reads the Lua from the source
  tree at run time. At `2584bcd` it runs 10 of the 31 suites in `plugin/`. Its
  counts below come from the receipt
  `E:\RESKATE DEV\park-diagnostic-normal-20261025T065911109Z\ctest.stdout.log`
  (2026-10-25 06:59Z). That receipt is older than every commit since `aad4248`,
  and the Host was not rerun for this table.
- **Luau runner**: the tracked [`luau-runner`](../luau-runner/README.md) registers
  every `*_tests.lua` and `tests.lua` in `plugin/` as its own CTest,
  `bmx_lua.<suite>`, and stages the qualified Ride copy itself. Its last run in
  `build/luau-runner` passed 39 of 39 tests at 19:49-19:50Z on 2026-10-25, against
  the working tree of that time. It has not been run at `2584bcd`, where its glob
  finds 31 suites and it would register 40 tests.
- **Pure runner**: the private `presentation_luau_tests.exe <plugin folder> <module>`
  runs one module in vendored Luau with no `reskate` API and no time limits. The
  counts below come from a copy of the 77 tracked `plugin/` files taken out of git at
  `2584bcd` (blob hashes checked), run on 2026-10-25 at 21:39Z. All 31 suites
  passed: 668 cases, 479,538 assertions.

| Suite | Host case | Host count (06:59Z) | Pure runner at `2584bcd` |
| --- | --- | --- | --- |
| `tests` | `bmx_lua_policy_runs_as_modules_and_the_inspector_starts_inert` | 12 cases, 1,216 assertions | 12 / 1,216 |
| `equipment_tests` | `bmx_lua_equipment_requests_match_the_retained_gesture_rules` (adds C++ reference rows) | 8 cases, 1,269 assertions, 160 C++ comparisons | 7 / 309 |
| `equipment_transition_tests` | `bmx_lua_equipment_transitions_keep_cleanup_and_target_observation_separate` | 32 cases, 2,538 assertions | 32 / 2,538 |
| `equipment_runtime_tests` | `bmx_lua_equipment_runtime_uses_typed_services_without_native_permissions` | 13 cases, 260 assertions | 13 / 260 |
| `recovery_tests` | `bmx_lua_recovery_policy_keeps_native_cleanup_separate` | 18 cases, 379 assertions | 18 / 379 |
| `trick_tests` | `bmx_lua_trick_policy_uses_actual_package_modules` | 16 cases, over 300 assertions | 16 / 371 |
| `force_tests` | `bmx_lua_forces_use_actual_modules_and_match_the_portable_kernel` (adds C++ reference rows; `call_ms` 2000) | 25 cases, 2,618 assertions | 23 / 217 |
| `ride_runtime_tests` | `bmx_lua_contacts_use_actual_decoder_and_force_modules` | 48 cases, 128 assertions | 48 / 128 (fixture) |
| `bike_runtime_core_persist_tests` | `bmx_lua_persistence_keeps_terminal_records_and_public_fault_gates` (added in `ad1516e`) | not in that receipt | 5 / 78 |
| `runtime_progress_fault_tests` | the same case | not in that receipt | 1 / 12 |
| `ride_runtime_join_tests` | none | not run | 4 / 16 (fixture) |
| `ride_runtime_b10_b16_tests` | none | not run | 25 / 66 (fixture) |
| `lease_source_tests` | none | not run | 43 / 178 |
| `ride_input_tests` | none | not run | 52 / 247 |
| `ride_input_mapping_tests` | none | not run | 42 / 321 |
| `rider_alignment_tests` | none | not run | 21 / 3,494 |
| `recovery_runtime_tests` | none | not run | 22 / 533 |
| `contact_runtime_preset_echo_tests` | none | not run | 32 / 91 |
| `core_ride_staging_tests` | none | not run | 2 / 130 |
| `bail_policy_tests` | none | not run | 21 / 1,430 |
| `camera_policy_tests` | none | not run | 20 / 57,198 |
| `grind_policy_tests` | none | not run | 15 / 1,019 |
| `input_presets_tests` | none | not run | 13 / 99,231 |
| `manual_balance_tests` | none | not run | 28 / 11,915 |
| `rail_probe_tests` | none | not run | 25 / 477 |
| `ride_composer_tests` | none | not run | 27 / 72,222 |
| `rider_presentation_tests` | none | not run | 27 / 12,226 |
| `rubric_metrics_tests` | none | not run | 16 / 3,933 |
| `sim_tests` | none | not run | 12 / 208,006 |
| `trick_presentation_tests` | none | not run | 18 / 870 |
| `trick_runtime_tests` | none | not run | 28 / 431 |
| `../equipment-interruption-trial/plugin/fixture_tests` | `equipment_interruption_fixture_keeps_effects_one_shot` (`call_ms` 2000) | 13 cases, 1,542 assertions | Host only |
| `../stationary-anchor-observer/plugin/sampler_tests` | none | not run | 46 / 104 (its own folder at `2584bcd`; not in the 668 total) |

The Host also runs `bmx_lua_spawn_uses_owned_chassis_and_measured_part_placement`
(22 scenarios, 2,048 comparisons) and three cases that print no count:
`bmx_lua_first_ride_imports_stay_inert`,
`bmx_lua_public_bike_facade_denies_mount_before_service_access` and
`bmx_lua_menu_switches_explicit_slots_and_retains_cleanup_duty`.

"Fixture" means the suite needs `ride_runtime_qualified_fixture.lua`: a copy of
`ride_runtime.lua` with `local ACTIVATION_QUALIFIED = false` changed to `true`.
Without it, those three suites fail on the missing file. The Host builds it in
memory (`Extension/Plugins/Test/bmx_contact_runtime_host_fixture.inc`), and the
Luau runner's `bmx_lua.stage_qualified_ride` test writes it into its own copy,
`build/luau-runner/qualified-plugin/`. For the private pure runner, build it in a
copied folder, never in this one; the public gate stays off. Equipment and forces
count differently in the two harnesses because the Host adds C++ reference rows.

Earlier figures elsewhere in this file, such as the 2026-10-23 counts, are kept as
dated history. The 14-suite total of 341 cases and 10,115 assertions at `aad4248`
and `8ac7917` is superseded by the table above. The "286 cases / 5,778 assertions"
total from 2026-10-24 came from a private 71-file snapshot
(`build/bmx/lua-force-clear-zero-camber-v1/verification/full/plugin`). At `2584bcd`
25 of its files are not tracked, one of them the generated
`ride_runtime_qualified_fixture.lua` (26 at `aad4248`, before `5bd211b` committed
`trick_runtime_tests.lua`), so the total cannot be reproduced from HEAD.

## Modules committed since `aad4248`

These commits add or change Lua under `plugin/` after the Luau native transport
checkpoint (`aad4248`). The new pure modules each document themselves in their own
`.md` beside this README. None of them is loaded by `main.lua` or by the lifecycle
it builds, both `RIDE_COMPOSITION_QUALIFIED` and `ACTIVATION_QUALIFIED` stay
false, and none has run in game. Counts are pure-runner cases and assertions at
`2584bcd`, from the table above.

| Commit | Files | What it is | Suite: cases / assertions |
| --- | --- | --- | --- |
| `5bd211b` | `rider_presentation.lua`, `trick_presentation.lua` ([RIDER_PRESENTATION.md](RIDER_PRESENTATION.md), [TRICK_PRESENTATION.md](TRICK_PRESENTATION.md)) | Rider posture, crank and landing cues turned into rider offsets, and trick targets turned into the eight bike part matrices. Presentation only; no visual consumer exists yet. | `rider_presentation_tests` 27 / 12,226; `trick_presentation_tests` 18 / 866; `trick_runtime_tests` 28 / 431, the first dedicated suite for the tracked trick adapter (`ride_runtime_join_tests`, tracked since `49ae4d3`, already drove it through Ride) |
| `f3cc0c8` | `camera_policy.lua` ([CAMERA.md](CAMERA.md)) | A chase camera that turns the bike pose and velocity into `{eye, target, fov}` for `camera.look`. The manifest has no `camera` permission. | `camera_policy_tests` 20 / 57,198 |
| `4e5a4c2` | `input_presets.lua` ([INPUT_PRESETS.md](INPUT_PRESETS.md)) | Named control presets whose default is today's binding. The mapper does not read them yet. | `input_presets_tests` 13 / 99,231 |
| `94f7bf2` | `manual_balance.lua` ([MANUAL_BALANCE.md](MANUAL_BALANCE.md)) | An authored manual and nose-manual balance model that produces the `manual` and `nose_manual` controls `forces.lua` takes. | `manual_balance_tests` 28 / 11,915 |
| `439ed37` | `peg_geometry.lua`, `grind_policy.lua`, `rail_probe.lua`, `grind_contact.lua` ([GRINDS.md](GRINDS.md), [RAIL_PROBE.md](RAIL_PROBE.md)) | Peg geometry and a grind and stall policy that turns contact rows into requests; a rail probe planned as one `probe_batch`; a port of the standalone peg and rail contact solver. | `grind_policy_tests` 15 / 1,019; `rail_probe_tests` 25 / 477 |
| `acb1dae` | `sim_world.lua`, `sim_scenarios.lua` ([SIMULATION.md](SIMULATION.md)) | Test-only tooling that rides one rigid body over an authored heightfield through the actual `input.lua` and `forces.lua`. Its numbers are model metrics, not targets. | `sim_tests` 12 / 208,006 |
| `e2055ab` | `rubric_metrics.lua`, [`../judging/OFFLINE_METRICS.md`](../judging/OFFLINE_METRICS.md), [`../judging/rubric-v2.json`](../judging/rubric-v2.json) | Reduces simulator, grind and camera traces to rubric quantities. An offline score is not the human-judged likeness score. | `rubric_metrics_tests` 16 / 3,933 |
| `e1dc8e0` | `bail_policy.lua`, `bail_guard.lua` ([BAIL.md](BAIL.md)) | A port of `Engine/Game/BMX/bmx_bail_policy.h` and the guard rays it needs. Every guard plan must be bound to its read's Ride Framev1, and both batches to that read's epoch. | `bail_policy_tests` 21 / 1,430 |
| `0b4c3e3`, `2584bcd` | `ride_composer.lua` ([RIDE_COMPOSER.md](RIDE_COMPOSER.md)) | One per-read pipeline over the modules above. It fails closed: a read that `bail_policy` did not judge sends no force, torque or hop impulse, and under Core's one probe batch per read it sends nothing at all. | `ride_composer_tests` 27 / 72,222 |

These commits change modules inside the lifecycle `main.lua` builds. Public Mount is
still refused before any game call, and the ride path stays unreachable while the
gates are false:

| Commit | Files | What changed | Suite: cases / assertions |
| --- | --- | --- | --- |
| `ad1516e`, `3587d78` | `bike_runtime_core.lua`, `equipment_runtime.lua` | The lifecycle ledger is saved when a stock transition finishes or expires, even inside the save throttle, and a new stock intent is blocked when that save fails. This fixes, in the tracked core, the throttled-save pattern behind the CE2 board-cancel mismatch the runbook describes; the private CE2 package is unchanged. | `bike_runtime_core_persist_tests` 5 / 78; `runtime_progress_fault_tests` 1 / 12 |
| `1b5e57f` | `ride_runtime.lua`, `ride_input_mapping.lua` | Ride accepts `parked_without_successor` as a terminal cleanup receipt and keeps the applied command's wheel speeds; the mapper re-projects held input when the ground changes between reports. | `ride_runtime_b10_b16_tests` 25 / 66; `ride_input_mapping_tests` 42 / 321 |
| `d403c25` | `contact_runtime.lua` | Contact accepts the SDK's `requested_query_preset` echo (`camera` or `terrain`) as request metadata only. Since `3e686fc` the facade stages Contact at mount (`plugin/bike_runtime.lua:11-14`) and Core binds it in `prepare_backend` (`plugin/bike_runtime_core.lua:813-816`). | `contact_runtime_preset_echo_tests` 32 / 91 |
| `3e686fc` | `bike_runtime_core.lua`, `bike_runtime.lua`, `bike_admission.lua` | Core builds Ride with no trick adapter, reserves Follow with `cleanup="owned_body"` and `motion_policy="callback_entry"`, requires `probe_batch`, `submit`, `receipt` and `acknowledge` before any body exists, and stages Ride, Contact and their dependencies at mount. | `core_ride_staging_tests` 2 / 130 |

[INTEGRATION_PLAN.md](INTEGRATION_PLAN.md) says how these would join a first
mounted ride and what still blocks it.

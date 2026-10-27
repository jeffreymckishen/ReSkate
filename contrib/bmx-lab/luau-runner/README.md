# BMX Lua suite runner

Runs every pure Lua suite of the BMX plugin (`../bmx-plugin/plugin/*_tests.lua` and `tests.lua`) as
its own CTest, on the vendored Luau alone. It compiles the same five Luau parts as
`cmake/Dependencies.cmake` (Common, Ast, Bytecode, Compiler, VM) into its own build tree, builds no
SDK target and reads no shared build output, so it works while the main tree is mid-build. The
runner itself is built `/W4 /WX` (`-Wall -Wextra -Wpedantic -Werror` elsewhere); the vendored
sources keep their usual warning level.

## Build and run

From a Developer PowerShell at the repository root:

```powershell
cmake -S contrib/bmx-lab/luau-runner -B build/luau-runner -G "Visual Studio 17 2022" -A x64
cmake --build build/luau-runner --config Release --parallel 2
ctest --test-dir build/luau-runner -C Release --output-on-failure
```

`ctest -V` shows each suite's counts. One suite: `ctest --test-dir build/luau-runner -C Release -R
bmx_lua.force_tests -V`, or run the executable directly:

```powershell
build/luau-runner/Release/bmx_luau_tests.exe contrib/bmx-lab/bmx-plugin/plugin force_tests
```

It prints `bmx_luau_tests: module=<suite> cases=<n> assertions=<n>`, then any other number or boolean
the suite's `run()` returned (`comparisons=0`, `native_actions=0` and so on), shown but not judged.
It exits nonzero, with the message and Lua stack, on a load, compile or assertion failure, or when
`run()` does not return whole, positive `cases` and `assertions` counts.

The same project can be built inside the BMX development harness with
`cmake -S contrib/bmx-lab -B <dir> -DRESKATE_BMX_LUAU_RUNNER=ON`. The option is off by default, and
the root build never includes either.

## Suites

The suite list is a `CONFIGURE_DEPENDS` glob, so a new `*_tests.lua` is registered as
`bmx_lua.<name>` on the next build without editing anything here. Each ordinary suite returns a table
whose `run()` needs no arguments. Suites that take optional reference rows (`equipment_tests`,
`force_tests`) run without them here; their C++ comparisons stay in `Extension/Plugins/Test`.

`ride_runtime_tests` requires `ride_runtime_qualified_fixture`, which must never ship in the plugin.
Before every run that needs it, the `bmx_lua.stage_qualified_ride` fixture copies the plugin's
modules byte for byte into `build/luau-runner/qualified-plugin/` and writes the fixture there as
`ride_runtime.lua` with its single `local ACTIVATION_QUALIFIED = false` flipped to `true`, as
`Extension/Plugins/Test/bmx_contact_runtime_host_fixture.inc` does in memory. It refuses if that
literal is missing or appears twice, or if the fixture already exists in the plugin. The same copy also
holds `contact_runtime_category_qualified_fixture.lua` and, when the plugin has `mounted_pose.lua`,
`mounted_pose_qualified_fixture.lua`, each its module with its one gate flipped and each refused in the
plugin. When `bike_spawn.lua` is present, it also receives
`bike_spawn_floor_qualified_fixture.lua`, with only `local FLOOR_SPAWN_QUALIFIED=false` changed to
`true`. The floor suite checks the inactive shipped module and this private trial copy; the normal
plugin keeps the airborne default. A separate `floor-manifest` staging regression checks exact bytes,
owned files, reruns and true/duplicate/planted floor gate refusals. It also stages
`bike_runtime_core_provisional_follow_fixture.lua` from Core with only
`local M1_PROVISIONAL_FOLLOW_OFFSET=false` changed to `true`,
`bike_runtime_core_follow_renewal_fixture.lua` from Core with only
`local FOLLOW_RENEWAL_QUALIFIED=false` changed to `true` (LUA-12), and
`bike_runtime_core_follow_lead_fixture.lua` with only `local FOLLOW_LEAD_QUALIFIED=false`
changed to `true`. The same regression checks all three independent literals and
their owned files, including true, missing, duplicate and planted lead refusals. `core_follow_renewal_tests` runs the
tracked Core and that renewal copy against constructed `renew_follow` and `read_follow_lease`
fakes shaped like the C++ binding. `core_follow_lead_tests` uses the real public
Core mount, Source and Spawn with constructed SDK services. It captures the actual
reserve table with the literal off and on, then reaches a known refusal. The trial
adds only `lead={steps=2,angular=true}`; other attachment fields and the constructed
lifecycle/call reports remain equal. This does not prove SDK permission or native
lead behavior. The provisional-offset suite
uses the existing staging suite's constructed service factory and the real
public Core mount/Source, without changing existing suite counts. Any suite that mentions a fixture, `./ride_runtime_tests` or `./ride_runtime_join_tests` runs
against that copy; the others run against the plugin folder itself. The production gates (`ACTIVATION_QUALIFIED`,
`RIDE_COMPOSITION_QUALIFIED`) are never changed in the source.

When `force_stage.lua` exists, that copy also holds private `force_stage_*_fixture.lua` modules.
The source must keep exactly one `local STAGE = "zero_force"` and one
`local AUTHORED_CAPS = nil`. It is copied unchanged; the fixtures replace only those literals:

| Fixture suffix | Stage | Synthetic caps |
| --- | --- | --- |
| `support_fixture` | `support` | `{force=20000,speed=10}` |
| `pedal_fixture` | `pedal` | `{force=20000,speed=10}` |
| `support_uncapped_fixture` | `support` | `nil` |
| `pedal_uncapped_fixture` | `pedal` | `nil` |
| `low_cap_fixture` | `support` | `{force=100,speed=10}` |
| `invalid_fixture` | `invalid_stage` | `nil` |

Each full name begins with `force_stage_`. Every fixture name is refused in the plugin source.
Missing, repeated or nonbaseline stage/cap literals refuse before destination mutation.
These are constructed policy values, not calibrated native force or speed limits.
The ride-control suite additionally stages `ride_fixture` with
`{force=6000,speed=3,torque=2000}`, `ride_uncapped_fixture` with `nil`,
`ride_low_force_fixture` with `{force=100,speed=3,torque=2000}`, and
`ride_low_torque_fixture` with `{force=6000,speed=3,torque=35}`. All select
`ride` only inside the owned test copy. Exact-manifest regression checks cover
these four names and refuse each if planted in the source package.

When Core is present, the copy also includes `bike_runtime_core_mounted_pose_fixture.lua`.
It replaces exactly one `MountedPose=require("./mounted_pose")` with
`MountedPose=require("./mounted_pose_qualified_fixture")`; every Core literal, the Ride binding,
and native gate remain unchanged. Staging requires the real `mounted_pose.lua` dependency,
whose separately generated qualified fixture is already checked above. Missing or duplicate
canonical bindings, an already qualified binding, and a planted Core pose fixture refuse before
any destination change. `floor-manifest` checks the exact Core and dependency bytes, lexical
owned-file manifest, identical rerun, binding refusals and missing-dependency refusals against
both an absent destination and an existing owned copy. The suite's constructed presentation
callbacks do not establish Host permission, rider alignment or native presentation qualification.

Every qualified copy also contains `main_score_entry_fixture.lua`, built from the current
`main.lua` bytes between exactly `return function(reskate, require)\n` and `\nend`.
The wrapper supplies function parameters for the entry suite's constructed SDK and module
loader; it does not alter the ordinary runner globals or any production gate. The original
`main.lua` is copied unchanged. A missing main dependency or source-planted wrapper is refused
before destination mutation. `stage_writes_exact_manifest` independently checks the complete
wrapper bytes, including the stand-in's CRLF endings, exact ownership, identical reruns and both
refusals against absent and existing destinations. CMake routes suites mentioning this fixture
through the staged copy. This exercises entry wiring under fakes, not the plugin Host or game.

## What it is not

This is **not the ReSkate plugin Host** and stands in for none of its checks. Modules are compiled
from text with optimization and debug level 1 and the standard libraries sandboxed, as in
`Extension/Plugins/plugin_vm.cpp`, but there is no `reskate` API, no manifest or permission, no call
or tick time limit, no multiplayer and no game. Every gameplay boundary a suite touches is a fixture
the suite constructs itself, so a pass here is not in-game evidence.

The ordinary module-loading environment is stricter in two ways:

- `require` accepts only `./name`, a `.lua` file directly in the one folder the runner was given,
  in its exact case. No `.luau`, subfolders, `..` or bare names.
- Globals are read-only for modules too (the Host's script thread lets a chunk set its own), and a
  module that returns `nil` is refused instead of being kept as `true`.

The two JSON-specific suites, `json_encoding_tests` and `bike_runtime_ledger_size_tests`, are an
explicit harness exception: only when selected directly do they receive a frozen `run(runner)`
argument containing `json_encode`. It uses the SDK-compatible Lua conversion and the actual
`Engine/Core/Json` writer to measure escaped JSON bytes. It is never installed as a
`bmx_luau_runner` global. Imported production dependencies and ordinary suites keep their ordinary
sandbox globals; importing either JSON suite does not grant its argument.
`runner_helper_isolation_tests` checks the actual `force_math` environment, the ordinary suite's
zero-argument call and the refusal when an imported JSON suite is called without its helper.
This helper proves no Host permission, persistence durability, time budget or gameplay behavior.

`bmx_lua_runner.*` tests check these boundaries: the self-test confirms refused `require` forms, a
module kept once, read-only globals and libraries and no `reskate`, and three more confirm that a bad
suite name, a module without `run()` and a missing suite are refused with their reasons. The plugin
folder is never written; `--stage-qualified-ride` writes `.lua` files and an explicit owned-file
manifest into a separate copy folder. Fresh or empty destinations are accepted. Reruns require the
`.bmx-qualified-ride-files-v1` manifest and its exact declared file set; unexpected files, subfolders,
source/destination aliases and reparse paths are refused before mutation. A legacy fixture filename
alone proves no ownership, so old copies without a manifest are refused: choose a fresh destination.

The staging `bmx_lua_runner.*` tests use `--stage-regression <case>
<scratch-folder>`. Each case builds a small stand-in plugin (one module with CRLF line endings,
plus a non-Lua note) and its destinations in `build/luau-runner/stage-regression-<case>/`, so it
neither reads nor writes the real plugin. A case refuses to run if its folder already exists, so it
never removes anything an earlier run left; the `bmx_lua_runner.stage_regression_reset` setup test
clears each registered case's scratch folder first.

- `stage_refuses_unrelated_destination`: a destination holding someone's `unrelated.lua` is refused
  and keeps every byte, whether the file is alone, beside a file named like the fixture (the old
  filename heuristic took that as ownership and deleted every direct `.lua` file), or dropped into a
  real earlier copy whose manifest does not list it.
- `stage_refuses_planted_fixture`: a source with `ride_runtime_qualified_fixture.lua` planted in it is
  refused before any copy folder exists, and the same stand-in without the plant stages. A planted
  `mounted_pose_qualified_fixture.lua` is refused the same way, a stand-in `mounted_pose.lua` stages
  its fixture with only the gate flipped, and one with the gate twice is refused.
- `stage_writes_exact_manifest`: a fresh stage holds exactly the stand-in's `.lua` modules byte for
  byte, the gate fixture, the entry wrapper and a manifest naming exactly those five files. A
  rerun leaves the copy identical, and a module dropped from the source leaves the copy and its
  manifest on the next stage.

- `stage_writes_category_manifest`: the Contact test copy changes only its one category literal,
  enters the exact manifest, survives an identical rerun and refuses malformed or planted fixtures.
- `stage_writes_force_stage_manifest`: all six ForceStage copies preserve every other byte,
  including CRLF endings, and enter the exact owned-file manifest. It checks an identical rerun,
  removal when the source module is dropped, every reserved fixture name, and missing, repeated or
  nonbaseline literals against both absent destinations and earlier owned copies.
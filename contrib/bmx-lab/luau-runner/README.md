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
`bmx_lua.<name>` on the next build without editing anything here. Each suite must return a table whose
`run()` needs no arguments. Suites that take optional reference rows (`equipment_tests`,
`force_tests`) run without them here; their C++ comparisons stay in `Extension/Plugins/Test`.

`ride_runtime_tests` requires `ride_runtime_qualified_fixture`, which must never ship in the plugin.
Before every run that needs it, the `bmx_lua.stage_qualified_ride` fixture copies the plugin's
modules byte for byte into `build/luau-runner/qualified-plugin/` and writes the fixture there as
`ride_runtime.lua` with its single `local ACTIVATION_QUALIFIED = false` flipped to `true`, as
`Extension/Plugins/Test/bmx_contact_runtime_host_fixture.inc` does in memory. It refuses if that
literal is missing or appears twice, or if the fixture already exists in the plugin. The same copy also
holds `contact_runtime_category_qualified_fixture.lua` and, when the plugin has `mounted_pose.lua`,
`mounted_pose_qualified_fixture.lua`, each its module with its one gate flipped and each refused in the
plugin. Any suite that mentions a fixture, `./ride_runtime_tests` or `./ride_runtime_join_tests` runs
against that copy; the others run against the plugin folder itself. The production gates (`ACTIVATION_QUALIFIED`,
`RIDE_COMPOSITION_QUALIFIED`) are never changed in the source.

## What it is not

This is **not the ReSkate plugin Host** and stands in for none of its checks. Modules are compiled
from text with optimization and debug level 1 and the standard libraries sandboxed, as in
`Extension/Plugins/plugin_vm.cpp`, but there is no `reskate` API, no manifest or permission, no call
or tick time limit, no multiplayer and no game. Every gameplay boundary a suite touches is a fixture
the suite constructs itself, so a pass here is not in-game evidence.

Differences from the Host, each stricter:

- `require` accepts only `./name`, a `.lua` file directly in the one folder the runner was given,
  in its exact case. No `.luau`, subfolders, `..` or bare names.
- Globals are read-only for modules too (the Host's script thread lets a chunk set its own), and a
  module that returns `nil` is refused instead of being kept as `true`.

`bmx_lua_runner.*` tests check these boundaries: the self-test confirms refused `require` forms, a
module kept once, read-only globals and libraries and no `reskate`, and three more confirm that a bad
suite name, a module without `run()` and a missing suite are refused with their reasons. The plugin
folder is never written; `--stage-qualified-ride` writes `.lua` files and an explicit owned-file
manifest into a separate copy folder. Fresh or empty destinations are accepted. Reruns require the
`.bmx-qualified-ride-files-v1` manifest and its exact declared file set; unexpected files, subfolders,
source/destination aliases and reparse paths are refused before mutation. A legacy fixture filename
alone proves no ownership, so old copies without a manifest are refused: choose a fresh destination.

Three more `bmx_lua_runner.*` tests check staging itself through `--stage-regression <case>
<scratch-folder>`. Each case builds a two-module stand-in plugin (one module with CRLF line endings,
plus a non-Lua note) and its destinations in `build/luau-runner/stage-regression-<case>/`, so it
neither reads nor writes the real plugin. A case refuses to run if its folder already exists, so it
never removes anything an earlier run left; the `bmx_lua_runner.stage_regression_reset` setup test
clears the three folders first.

- `stage_refuses_unrelated_destination`: a destination holding someone's `unrelated.lua` is refused
  and keeps every byte, whether the file is alone, beside a file named like the fixture (the old
  filename heuristic took that as ownership and deleted every direct `.lua` file), or dropped into a
  real earlier copy whose manifest does not list it.
- `stage_refuses_planted_fixture`: a source with `ride_runtime_qualified_fixture.lua` planted in it is
  refused before any copy folder exists, and the same stand-in without the plant stages. A planted
  `mounted_pose_qualified_fixture.lua` is refused the same way, a stand-in `mounted_pose.lua` stages
  its fixture with only the gate flipped, and one with the gate twice is refused.
- `stage_writes_exact_manifest`: a fresh stage holds exactly the stand-in's `.lua` modules byte for
  byte, the fixture with only its gate flipped and a manifest naming exactly those three files. A
  rerun leaves the copy identical, and a module dropped from the source leaves the copy and its
  manifest on the next stage.

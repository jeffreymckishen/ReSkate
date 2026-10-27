# Sealed private hop package: actual Host bootstrap fixture

`the_sealed_private_hop_fixture_loads_inert_when_selected` loads the reviewed
runtime package's unchanged `plugin/main.lua` and manifest through the real
sandbox Host, module loader, permissions, UI API and callback budgets. Every Game
service is the existing constructed `FakeGame`. No game or native provider runs.
This is pre-Start bootstrap evidence; it does not qualify native preparation,
Follow, equipment, lifetime, hop forces, cleanup or gameplay.

The optional selector is `RESKATE_HOP_INERT_FIXTURE`. An absent variable prints an
explicit skip and **provides no bootstrap proof**. An empty value, another path,
a supplied missing package, changed seal, changed file or extra file fails.
The exact selected directory is:

```text
E:\RESKATE DEV\warmup-hop-validation-20261027-v1\runtime\BMX_Hop_Trial_warmup-p0-20261027-v1
```

The existing `dingosdk_plugin_tests` target links the existing
`dingosdk_launcher_support` library solely to reuse its cross-platform
`launcher::sha256_file`. Its existing BCrypt/OpenSSL platform dependencies are
unchanged; no third-party dependency or production API is added.

## Reviewed identity

| Field | Pinned value |
| --- | --- |
| Source package revision | `fd9c45aee7a84912d26d670cd6a1733b74068156` |
| Canonical Lua source revision | `062db162248d6b21c686f588924e0abc5954e99c` |
| Run | `warmup-p0-20261027-v1` |
| Review | `root-fd9c45ae-20261027-p0-v1` |
| Phase | `P0` |
| Namespace | `BMX_Hop_Trial_warmup-p0-20261027-v1` |
| Parent `PACKAGE.json` SHA-256 | `0F26F3780EC1104C94799A61CD5DDADD6B1D19FD247313ADF2490B75F41E31FE` |
| Parent `FILES.json` SHA-256 | `BBF70085A922DB639A7350587B82645A2F208F6855A8C4FF4357F9CCC3C0FC41` |
| Package file count | `72` |

The pinned external `FILES.json` covers all package files, including the internal
inventory. Length and SHA-256 of each file and the exact path set are checked
before and after Host use. The package is loaded in place, with no entry wrapper,
manifest rewrite, staging invocation, permission injection or asset extraction.
The inherited pinned `plugin/tests.lua` is part of those 72 files; there is no
blanket filename exclusion. The five private qualification suites and their
lexical fixture are absent from this runtime artifact.

The manifest contract is API 1, client side, entry `plugin/main.lua`, permissions:
`input`, `input.control`, `input.lease`, `input.capture`, `skater.read`,
`skater.animation`, `menu`, `storage`, `overlay`, `board`, `world.physics`,
`world.physics.follow`, `world.entities`, `world.raycast`.

## Assertions and limits

The fixture uses `game_limits(6)`, matching Main's reviewed P0 launcher setting.
The ordinary 50 ms per-callback cap, 20 ms unload budget, 64 MiB heap and three consecutive average
budget windows remain enforced. It does not increase the load timeout. It checks
that the plugin is running immediately after load and after each of 432 ticks at
16.7 ms. Cold loading starts with the menu open; subsequent 120-tick stages close,
open and close it, then 12 ticks rebuild the final open menu at its real 100 ms
cadence. Constructed ready stock facts and closed-menu stages avoid hiding an
automatic admission behind missing focus, skater, telemetry or input permission.

After cold loading and each stage, the exact plugin must show:

- `BMX trial READY / start once in menu` and the explicitly unqualified cached
  overlay detail, in that plugin's two-shape layer;
- its registered `Private BMX hop trial` page;
- when open, the exact phase/run note, `Ready for one explicit P0 start.`, one
  `hop-trial-start` button labelled `Start P0 once`, one Stop button, and
  `Lifecycle: idle. Cleanup continues after driving stops.`

READY means imports and construction finished. The overlay itself has no run
identity; the matching plugin's menu note supplies it. No Start or Stop action is
dispatched. This test checks the pre-Start control presentation, not a post-Start
one-shot transition. The separate Lua composition suites cover that behavior.

Each tick checks zero entries at the fake Game boundary for native prepare,
body create/read/release, force submission, command receipts/acknowledgements,
Follow, native probes, world probe/pick/native casts, input leases/capture/pulses/traces, equipment/recovery,
legacy game input filters, entity removal and the existing recorded control/pose
calls. Lease/capture overrides delegate to the unchanged base refusals after
counting; body receipt/ack, filter and entity removal counters also count before
results. This observes attempted backend calls, including refused ones, rather
than only the final empty ownership state. Calls rejected earlier inside the API
are outside those Game-entry counters; affirmative UI and running-state checks
separately catch a failed bootstrap. Pre-Start storage must remain absent.
Before PASS, the fixture calls `Host::shutdown()` explicitly and repeats the
boundary-counter assertions, allowing only the fake's one framework
`entities clear <id>` call from `Game::release`. It checks the actual idempotent
close bookkeeping: `Plugin::unload` and the plugin destructor each close the same
nonzero owner, yielding two entries in the pulse/trace/recovery/equipment/body
release vectors; `Game::release` runs once. Those framework close receipts are
separate from plugin-driven requests and do not qualify native cleanup.

Idle unload intentionally writes the actual entry's emergency evidence because
its cached observations were not flushed. The test requires exactly one storage
key, `hop.warmup-p0-20261027-v1.incomplete`, with `complete=false`,
`interrupted=true`, `observation_loss=true`, `unqualified=true`,
`first_fault=explicit_unload_incomplete` and both native qualification flags false.
No lifecycle mount ledger, completed summary or evidence chunks may appear. Its
last facade snapshot is `done`/unloaded, with no authority or acquired cleanup
debt; absent native facts remain absent. This diagnostic is expected even though
Start was never dispatched. The explicit shutdown completes before PASS; later
Host destruction has no plugin entry left to unload.

## Main-owned execution

The authoring lane does not build or run this fixture. After integrating the
source commit, Main builds the normal `dingosdk_plugin_tests` target and runs the
full plugin suite in its approved offline slot. In that process environment set:

```powershell
$env:RESKATE_HOP_INERT_FIXTURE = 'E:\RESKATE DEV\warmup-hop-validation-20261027-v1\runtime\BMX_Hop_Trial_warmup-p0-20261027-v1'
```

The required result contains `sealed private hop Host inert-load PASS`, the exact
run, `files=72`, `ticks=432 tick_ms=6 call_ms=50`, the READY/start-once/idle cues,
and zero native-control Game entries, followed by the checked idle-shutdown diagnostic and expected framework cleanup. A skip is not a passing bootstrap receipt.
Restore the prior process environment value afterwards. Record the executed
binary identity, integrated revision and full suite result separately. A native
P0/H1 game run still needs its own operator protocol, execution window and facts.

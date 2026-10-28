# Private P0/H1 hop trial source

This folder prepares a bounded lab trial against the production Lua modules at
`062db162248d6b21c686f588924e0abc5954e99c`. It is not a rideable public mod, a game result or a completed BMX port.
`plugin/hop_config.lua` has `admission_enabled=false`. The source directory is
intentionally incomplete as an installed package: the reviewed stager supplies
hash-pinned production modules in a new output directory. Nothing in this folder
installs, deploys, launches the game or drives a controller.

The main ReSkate chat owns execution and deployment. Work here is restricted to
this new revision in `reskate-hop-prepare-20261027`. Production files, the
other worktrees and the game packages remain outside this source lane. During
an exclusive game window there is no Git, build, test, import, staging or game
input from this lane. Both coordinator HID-HOLD files must be absent before
filesystem work; a timed hold also defers coordination messages.

## What P0 and H1 can establish

- **P0:** current ordinary mounted pose, native support, receipt flow and recorder
  behavior, with neutral controls. The guard refuses hop and pedal intent.
- **H1:** the same composition with one actual mapped quarter-strength hop. The
  guard admits only strength `.25` and one native hop attempt. There is no retry,
  second event or R3 shortcut. R3 requests full strength and is refused.

Neither trial enables Ride tricks, TrickRuntime physical support, Follow lead or
Follow renewal. Neither proves a completed trick, repeated mounts, native body
retirement, collision wheel behavior or long-duration performance. T1 partial
pose and T2 full One Hander are described in `OPERATOR_PLAN.md`; this package does
not enable them.

## Source and package boundaries

`source-pins.json` records exact bytes and SHA-256 for the 59 production modules
used as the copy source. Its commit label is provenance; the file hashes are the
actual content check. The canonical source root for this revision is the sealed
`E:\RESKATE DEV\worktrees\reskate-native-prepare-20261027` checkout. Core and Admission
are the only changed canonical pins. `forces.lua` remains exactly 37,599 bytes with
SHA-256 `3BB16CB48F0A3304F651346FBD97A97D8CF4FE023E12B0E7FC7073429DD9C5E5`.
A mixed-line-ending integration checkout is not an interchangeable source: no
normalization or fallback is permitted. Frozen `cfcabecf` worktrees, packages,
receipts and operator instructions remain intact; this revision needs a fresh
run identity and its own reviewed operator package.
Production `main.lua`, tests and fixtures are excluded.
The stager must refuse changed, missing, added or duplicate input, and must not
rewrite the source tree. Its declared private transformations are reviewed in
`stage-plan.json`; closed admission leaves production gates closed.

The private modules have separate responsibilities:

| Module | Responsibility |
| --- | --- |
| `hop_config` | Closed admission, fixed P0/H1 settings and run identity |
| `hop_guard` | Bind actual Source, body, preview and submitted packet; enforce one bounded hop |
| `hop_recorder` | Bounded, detached evidence with independent terminal/debt state |
| `hop_context` | Share one private guard/recorder instance between copied composition hooks |
| `hop_force_stage` | Observe the real ForceStage preview and candidate without replacing the solver |
| `hop_services` | Observe existing SDK calls and preserve their actual returns and failures |
| `main` | Staged startup, explicit one-shot intent, stop observer and cleanup/flush scheduling |

The instrumentation has no new native API. A declared hook in the **copied**
Ride module observes `s.body`, the actual sample, mapped controls, measured body,
model frame and contact before force preview. It keeps the original queued
Source. The copied Core binds the private ForceStage wrapper, and the copied
facade stages it after its production dependency. No handle or epoch is exported
in recorder data; those authorities stay private for exact comparisons.

## Fixed proposed envelope

These are review inputs, not measured native qualification or minimum safe caps.
They must be pinned with the staged package and cannot be supplied by a runtime
menu or manifest.

| Setting | P0/H1 proposal |
| --- | --- |
| Force stage | `hop` |
| Ordinary model force | at most 6000 N |
| Horizontal measured and folded speed | at most 3 m/s |
| Torque | at most 2000 N m |
| Absolute measured and folded vertical speed | at most 3 m/s |
| H1 mapped hop strength | exactly `.25` |
| Authored mass | 106 kg |
| H1 impulse | 119.25 N s along authored gravity-up |
| Native hop attempts | at most one, consumed before calling the SDK |
| Private ride window | 1500 ms from publication, also limited by the fixed lease |
| Follow lease | fixed 3000 ms from the reserve clock read |
| Lease safety margin | 150 ms; not a cleanup-completion deadline |

The ideal neutral support force is about 1038.8 N. Actual contact correction,
settling and landing loads depend on measurements. The ordinary force cap does
**not** include hop impulse. The requested quarter-hop delta-v is 1.125 m/s;
`J/h` is about 7155 N at 60 Hz. The real packet must also satisfy its existing
600 N s impulse and 40000 N combined force/impulse limits. Gravity, initial
motion and accepted in-flight work consume the vertical speed allowance.

The guard does not convert a refusal into SDK acceptance. A native hop attempt
is spent even if its result is refused, unknown or raises; no replay is allowed.
Neutral support/landing work after the one hop remains subject to the same
identity, receipt and cap checks. A preview alone does not spend an attempt.

## Native preparation and evidence

The copied production Core now calls the existing `world.physics.prepare()`
within the original admitted mount deadline, before equipment, Source, floor
sampling or body creation. No companion preparation plugin is needed for this
revision. Construction and backend binding remain inert. Exact setup-pending or
fresh-physics-step responses permit a later call; all other failures close the
intent. Stop, unload and lost readiness cancel it. A pending phase with no acquired
authority may wait through a long setup tick without calling preparation again or
extending the deadline. After success, later ticks still qualify acquisition.

The service observer forwards each actual return or exception unchanged and
records it under a separate `prepare` category. The bounded terminal copy keeps
`native_preparation` and `mount_deadline_ms`; opaque handles and native identities
are not preparation evidence. Pending calls consume the existing evidence budget;
exhaustion stops and disqualifies the trial rather than increasing capacity.
Preparation success is sampled readiness, not allocation, a Follow receipt,
cleanup completion, reuse authority or native body/ride qualification. A later
create refusal still consumes the existing floor query and cannot restart warmup.

## Evidence and failure handling

Record actual Source scalars, body identity and vectors, measured contacts,
selected hop, preview, packet, SDK submission, receipt, coherent successor and
ACK. `predictive_accepted` is model history, not proof that the native hop was
applied. A physical H1 pass also needs measured takeoff and landing under the
actual support predicates. Ray-derived support does not qualify collision
wheels. A score or visible jump alone is insufficient.

The recorder lives outside Core's 3000-field/48000-byte snapshot. It has bounded
normal and reserved critical storage, explicit observation-loss flags and a
latest terminal/debt snapshot independent of row capacity. Exhaustion stops the
trial and disqualifies its evidence; it does not clear pending commands or
cleanup debt. Repeated identical receipt polls may be counted together; changed
identity, outcome and terminal transitions must remain distinguishable.

No storage writes occur from the observation append path. After actual
terminal/watchdog state and no new Ride commands, flush at most one bounded
chunk per idle tick. This also permits retaining failed/unknown cleanup evidence.
A storage failure stays visible, keeps buffered data and never fabricates a
successful cursor. SDK zero-return acceptance proves host cache acceptance,
not durable disk persistence. Use a fresh private package/run identity and
storage namespace for each attempt.

If explicit unload arrives before a complete normal flush, revoke admission and
let the actual Core unload path run first. Then attempt at most one distinct
incomplete summary containing the latest known snapshot and remaining debt.
It is marked interrupted, incomplete and unqualified; it does not advance normal
row/chunk cursors or claim terminal cleanup. A missing final status preserves the
prior snapshot and marks that loss. An early unload cannot wait for later native
receipts. Wait for the normal evidence-flushed indicator before ending a trial;
cache acceptance still does not promise persistence through a crash.

Core treats pose refusal as optional. This trial's observer must explicitly
request ordinary Stop when the SDK pose fails. Stop also on Source/focus/menu,
owner, body, contact, caps, unexpected input, second-hop, receipt or deadline
failure. Keep cleanup processing and evidence after the ride window through the
existing watchdog. Unknown/partial/parked-without-successor results stay unknown;
never call them clean because a timer or buffer ended.

The closed-menu overlay is a sampled operator cue. Tick prepares at most two
short text lines from cached lifecycle, recorder and guard state; draw only
renders those strings. A displayed deadline uses the smaller of publication
plus 1500 ms and lease end minus 150 ms, and stays unknown when either clock
fact is unavailable. Any attempted native hop displays consumed/no retry,
including refused or unknown outcomes. The cue does not authorize a hop, prove
SDK success or provide reproducible synchronization for automated controller
input. Include its cost in the measured callback budget.

## Performance and verification boundaries

Keep the host at the reviewed 6 ms average per tick over one-second windows and
its unchanged 50 ms per-call ceiling. Three consecutive over-budget windows stop a plugin;
absence of that stop in a short trial is not performance qualification. Capture
host windows and maximum callback time, including observer, recorder, UI and
storage work. Preserve one cold module per startup tick and separate constructor
work; a new recorder must not eagerly compile the whole dependency graph.

Older S2c used rounded pose inputs. Its timing and joint observations do not
qualify the current exact-angle poser or this instrumented composition. Fresh
P0/H1 evidence is required. Source tests exercise only the constructed guard,
recorder and composition contracts; they cannot prove native motion or lifetime.

At source handoff, the main chat should validate the stager/refusal cases and
run the new Lua suites in isolated output using the existing vendored runner.
The production warmup validation is separate from these revised private tests.
Builds, new tests, staging and in-game checks are **not run by this helper lane**.
Record their eventual exact commands, source/package/runtime hashes and results
in the execution evidence rather than changing this boundary by assumption.

## Commands for the execution owner after release

These are proposed future commands, not a record of execution. Run from the
assigned source checkout, after the main chat releases its exclusive game
window. Keep test/staging output outside source and game directories. The output
parent must already exist, and the output directory must be new and named
`BMX_Hop_Trial_<RunId>`.

```powershell
$trialSource = 'E:\RESKATE DEV\worktrees\reskate-native-prepare-20261027'
$trialTools = (Resolve-Path '.\contrib\bmx-lab\hop-trial').Path
& (Join-Path $trialTools 'Stage-Trial.Tests.ps1') -SourceRoot $trialSource -RunReviewedTests
```

For the six pure Lua suites, first stage a **closed**, test-only artifact into
a new output directory with `Stage-Trial.ps1 -Mode Stage -SourceRoot $trialSource
-OutputDirectory <new-output> -IncludeTests`, then use the same arguments with
`-Mode Verify`. Run the existing, separately reviewed `bmx_luau_tests.exe` against
its `plugin` directory and each module `hop_guard_tests`, `hop_evidence_codec_tests`, `hop_recorder_tests`,
`hop_composition_tests`, `hop_prepare_evidence_tests` and `hop_prepare_cancel_tests`,
each in a fresh runner process. The runtime inventory is 73 files; the test
artifact has 80. The unchanged 13 production transforms and four private identity
transforms remain the only admitted substitutions. The test-only lexical fixture wraps exact private
`main.lua` bytes with injected SDK/module-loader parameters; it tests entry
control flow without changing production or registering a new native API. It
must be absent from runtime output.

An admitted P0/H1 artifact needs a distinct fresh output and the explicit
`-ReviewedAdmission -Phase P0` (or H1), `-RunId` and `-ReviewId` parameters. Those
flags apply the declared transformation plan; they are not an execution grant.
Verify it with identical parameters. Inspection of transform-report.json and
artifact-inventory.json is required before the main operator considers any
separate deployment. A stale artifact after any source change must fail Verify;
never repair it in place or reuse a partial output.

## Encoded evidence

New recorder chunks use schema 2 and `encoding="hop-delta-v2"`. The pure
`plugin/hop_evidence_codec.lua` codec and `Decode-HopEvidence.ps1` consumer share
fixed field/kind tables and reconstruct the logical rows before semantic checks.
They preserve field absence, false, zero, signed zero, exact numbers and occurrence
metadata. Regular deltas reference only the previous row in the same projection;
critical rows are complete anchors and can be decoded independently as rows.
The strict stream reader still requires every ordered chunk from the run.

The 2,048-row/512 KiB regular budget, separate cleanup budget, storage quota,
readiness gates and 1,500 ms driving window remain unchanged. Retained projection
bases are charged to the regular budget. Overflow still marks observation loss
and stops the trial. Flushing remains terminal-only and failed writes do not
advance the cursor. `Read-HopEvidenceChunks` rejects malformed v2 evidence;
operators must explicitly decode it before applying their existing predicates.
Frozen schema-1 operators and packages remain separate and cannot qualify a new
encoding without their own reviewed integration.

Pure codec tests, exact recorded-prefix replay and packaging tests establish their
stated boundaries. They do not establish the complete 16 ms composition, SDK tick
budget, persistent storage, native input consumption, a hop or landing.
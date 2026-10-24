# Fall recovery adapter candidate

Implementation lane10 is `/root/fall_recovery`, working in main thread
`01a16107-d0c3-7492-b4c6-9433219879f0`. All files in this candidate are confined
to `build/bmx/fall-recovery-parallel-lane-v1`. Nothing here is promoted or wired
to `main.lua`; the default adapter is inactive. No C++ production source,
manifest, sealed42 source, normal build, game, HID or Git state was changed.

`plugin/recovery_runtime.lua` composes the existing pure `recovery.lua` policy
with exact selected-source identities and canonical bike lifecycle cleanup.
It never constructs a `Source`, calls `reskate.*`, captures input, releases a
body, removes a visual, requests Follow, or owns an acknowledgement. The ride
coordinator remains the only effect owner. This candidate produces requests
and detached diagnostics, including zero `native_actions`.

```lua
local recovery = require("./recovery_runtime").new({enabled = true})
local result = recovery:update(frame)
if result.requests.stop then
    -- The existing sole coordinator receives this once; it owns cleanup.
    bike_runtime:request_stop(result.requests.stop.reason)
end
```

At present lane8 recognizes only `requests.stop`. Other outputs remain inert.
The caller must not dispatch `requests.recovery` unless it deliberately enables
`allow_get_up`, supplies the four actual generic functions in `skater_api`,
and can provide the independently qualified actor observations described below.
Passing function references checks availability without invoking them.

The existing API names are `reskate.skater.recover()` and
`reskate.skater.recovery_state(handle)`, `recovery_cancel(handle)` and
`recovery_acknowledge(handle)`. They are installed by
`Extension/Plugins/plugin_api_actions.cpp` behind `skater.control`. No new
native call or permission is invented here. Their request/reply/receipt mapping
is unchanged from `contrib/bmx-lab/bmx-plugin/RECOVERY.md`.

## Observations and ownership

The adapter accepts lane8 Framev1's `valid`, `fresh`, `body_handle` and exact
`source` key: lease userdata, safe local generation, actual slot, and canonical
decimal uint64 `sequence`, `source_epoch` and `context_generation`. It accepts
`now_ms`, strict `loaded` and `active` booleans and `gates.focused/menu_open`.
Caller milliseconds are validated and floored only for the pre-existing
recovery policy. They never become native simulation time.

`telemetry.watch.valid/ragdoll_known/ragdoll` can conservatively stop on an
actual sampled ragdoll even without the strong actor observation. A known
exact source change or strong measured actor/session change stops publication
before further force or Follow. An actual telemetry wipeout-counter advance
also stops; a rewind conservatively invalidates continuity without pretending
to prove a particular session change. Body-handle replacement and readiness
loss do the same. A prior owned
body/source/Follow sequence is retained across replacement; a new source must
never inherit the previous duties. Missing owned identity produces a retained
unknown; later focus, timeout, ordinary release return or visual target cannot
repair it.

An optional `observed` record is deliberately stronger than current telemetry:
actual opaque `actor` and `session` identities, same-read native `epoch`,
canonical decimal native `serial`, native `time/seconds`, observed
`committed_state`, known boolean `ragdoll/in_air`, and actual `offboard/standable`
facts. This is a caller qualification contract, not a new API and not proof
that any arbitrary userdata is a native actor. New opaque epoch wrappers at an
unchanged actual serial/time are allowed; wrapper equality never establishes
an actor, world, session or native lifetime. Duplicate facts cannot accumulate
time. Contradictory duplicates, regressed clocks and invalid facts fail closed.

Framev1's generic body sample has no actor identity, ragdoll, in-air or on-foot
observation. Public `skater.telemetry()` exposes sampled ragdoll, state and
wipeouts but no opaque generational actor/session identity or coherent native
clock. **Live get-up admission and neutral rearm therefore remain unavailable**
without a genuinely general, qualified native actor observation. Do not borrow
the body's epoch, a pose target, `level.name`, or a locally invented token to
fill this gap. The constructed tests provide synthetic identities visibly.

## Cleanup and explicit get-up

The first stop latches `suppress_forces` and `suppress_follow`, emits one stop
request and retains a snapshot of the exact duties. This latch is never cleared
by time, returned stop calls, focus or a completed recovery receipt.

`frame.cleanup` is the sole coordinator's bound snapshot:

- `incident` matches the emitted incident; `body_handle` and `source` match the
  retained exact body/source key.
- `bike` is the canonical `bike-lifecycle-v1` snapshot, `phase="done"`, no bike
  authority/pending/unknown cleanup, and no unload.
- The exact retained Follow sequence has a completed, terminal, park-observed
  receipt, zero in-flight and pending work, canonical final revision/native
  epoch with matching zero/nonzero presence, and returned revision equal to
  final revision. The published API permits both final values to be zero when
  no Follow command was copied; park and positive ACK remain required.
- Completed Follow ACK is positive, and the canonical source is complete with
  no handle/debt/quarantine, matching exact native lease identities, source
  released, capture released, and equipment clear.

The final canonical state orders visual removal/body retirement after park and
ACK. This adapter neither performs those effects nor derives proof from a
released-call return. It intentionally refuses ordinary-release-only paths.
The default strict Follow park remains unresolved; the unpromoted
`attachment.cleanup="owned_body"` candidate is not assumed.

Only after that barrier may a fresh neutral then explicit `get_up_down` press
request one `recover` intent. Known refusal spends the incident; missing
returns retain unknown authority. The existing model retains/polls/cancels only
its exact handle as allowed, preserves full receipts and emits one resolved
ACK. It never retries an unknown request or refused/unknown recovery ACK.
`recovery_reply` joins the original model's `request_result`, `receipt_handle`,
`receipt` and `ack_result` fields.

An independent contract audit remains in canonical `plugin/lease_source.lua`:
its drain loop revisits capture/source ACK after a non-true or thrown result.
A specifically known not-ready refusal may permit another state poll under
the SDK contract; it must be distinguished from an unknown dispatched ACK or
an already accepted ACK. This adapter owns none of those effects. Root is
auditing that contract with the actor-exclusion lane. Current source DTOs expose
final completion but no full ACK attempt history; these constructed completion
fixtures do not settle dispatch/acceptance semantics or unknown outcomes.

## Standing and rearm

After cleanup and any retained recovery authority resolves, the adapter needs
a fresh actual standing suffix for the same actor/session: state504,
offboard/standable, known false ragdoll/in-air, at least30 distinct native
samples and at least2 seconds. Gaps over250ms interrupt that suffix. Native
samples and elapsed native time are counted only after a real post-cleanup
anchor. The completed recovery receipt is useful historical evidence but
does not substitute for the suffix.

A new exact selected source plus a fresh all-zero original report can set
`rearm_ready`. This is eligibility for another explicit coordinator decision;
it never acquires a source, resets a mapper, publishes Follow or restores force.
The stop latch and historical incident remain. A current readiness failure
revokes eligibility. There is no automatic new attempt or reset that discards
retained unknown authority.

The source's original report includes exact `observation_serial`, `observed_ms`
and `pad`. The adapter requires progress in that source's native observation
serial for current neutral eligibility. A cached neutral report cannot rearm.
Lane8's enriched Framev1 can carry the selected source's copied pad. It still
lacks a qualified native actor/session observation and cleanup/recovery dispatch
wiring, so that frame alone provides no live get-up or rearm capability.

## Offline verification

An already-built portable vendored-Luau runner, inspected before execution,
loads this candidate using its explicit module-root argument:

```powershell
& build/bmx/parallel-tricks-presentation-proposal-v1/harness/build/Release/presentation_luau_tests.exe `
    build/bmx/fall-recovery-parallel-lane-v1/plugin recovery_runtime_tests
```

This executes constructed transitions and negative cases without a compiler,
SDK Host or native/game interfaces. The test receipt contains the actual count.
Coverage includes inactive defaults, exact large source keys, actor/session
replacement, one stop, missing identity,22 incomplete cleanup mutations,
unknown get-up returns, refused ACK, held gestures, duplicate wrapper reads,
stale/contradictory samples, standing gaps, source-neutral eligibility and focus
revocation. This is source/pure-Luau evidence, not an observed in-game get-up,
native park, collision quality or restored BMX ownership.

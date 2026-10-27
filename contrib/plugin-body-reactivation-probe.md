# Private one-cycle body reactivation probe

This diagnostic is an isolated mechanism experiment. It qualifies one parked owned
body, activates that same allocation once at its immutable creation pose, then
explicitly parks it again. It does not return a reusable body, free an allocation,
qualify a rider attachment, or establish native retirement.

Normal builds omit this API. Building with
`DINGOSDK_BODY_REACTIVATION_QUALIFICATION=ON` only includes the diagnostic; it does
not arm it. A separately approved isolated launch and an exact matching plugin
instance are also required. Do not enable it in a normal release profile.

## Permission and opaque request

A qualification plugin declares both `world.physics` and
`world.physics.qualify_body_reactivation`. The latter permission is unknown when
the diagnostic is compiled out. Permission and client/server checks precede
argument parsing and provider access. The existing `world.physics.observe` APIs
remain passive and cannot authorize this diagnostic.

| Method | Result |
| --- | --- |
| `reskate.world.physics.begin_body_reactivation_probe(body)` | Opaque probe, or `nil, why` |
| `reskate.world.physics.poll_body_reactivation_probe(probe)` | Copied diagnostic result, or `nil, why` |

Begin takes exactly one body userdata issued to the same VM. It takes no pose,
repeat count, run identity, owner number, native address, or eligibility flag.
The caller creates that body through the ordinary API before beginning. Admission
has two internal paths, selected by retained SDK history rather than a Lua flag:

- An active body that never held a dependent native service follows the original
  body-only park/reactivate/repark experiment.
- A retained body previously held by Follow requires its exact completed live-owner
  ACK handoff. The trusted service records that optional handoff only after a real
  published Follow has stopped, drained its invocations and final return, released
  its body hold, observed a later park, retired its claim and sealed command cleanup.
  Orphan cleanup does not issue it. The provider also requires a fresh parked
  observation strictly later than the recorded handoff observation.

Both paths require no pending, producing or unacknowledged body commands. Follow
ACK does not ACK body receipts: their ring must be emptied separately by exact
receipt ACKs. Released hold alone, a stopped claim or a fresh park alone cannot
substitute for completed handoff history. Ordinary Follow ACK still succeeds when
optional provenance is unavailable; the diagnostic refuses that missing history.
The historical `never_held` flag, failed mailbox and lifetime fault latches are
never reset. Pending sync or motion probes, including unknown/busy or in-flight
motion observation, also refuse the post-Follow path.

The admitted body is retained and inactive before begin returns. Its
original body handle cannot be used for normal source reads, force commands or
Follow admission during or after the experiment. An opaque probe is diagnostic
access only; it is not an owned body or submit epoch. Tables, numbers, copied
fields, other VMs and a reloaded VM cannot recreate its identity.

Begin and poll share the existing per-plugin probe budgets of one begin attempt
and eight polls per tick. A matching launch arm permits only one begin attempt
for the process, including a provider refusal. Polling never starts a run,
advances a native stage, renews a deadline, acknowledges cleanup, or grants
ordinary body access.

## Launch arm

Before any plugin starts, the runtime freezes all of these operator-provided
launch values:

| Variable | Required value |
| --- | --- |
| `RESKATE_BODY_REACTIVATION_QUALIFY` | Exactly `1` |
| `RESKATE_BODY_REACTIVATION_ROOT` | The approved canonical isolated data root |
| `RESKATE_BODY_REACTIVATION_PLUGIN_ROOT` | The approved canonical plugin directory |
| `RESKATE_BODY_REACTIVATION_PLUGIN_ID` | The exact approved plugin ID |
| `RESKATE_BODY_REACTIVATION_RUN_ID` | A bounded nonempty run identifier |

The data root must match the validated `RESKATE_DATA_ROOT` override. Missing,
malformed, ordinary-profile or mismatching values leave the process unarmed.
There is no fallback package or profile. Setting values after startup cannot
arm it. Observed changes revoke activation permanently for that process.

The Lua binding forwards the plugin's trusted instance, ID and directory; Lua
cannot choose those fields. The first matching begin binds one numeric VM owner
and consumes the arm. Reloading cannot transfer that consumed arm to another
instance. These gates limit the diagnostic to the approved run; they do not
prove that a native setter is safe or that cleanup completed.

## One cycle and separate cleanup

The provider admits only a complete original allocation with the same qualified
owner, world, full actor context, native body and shape identities. Quarantine,
partial construction, sticky lifetime faults, owner closure, uncertain closure,
existing dependencies, competing diagnostic work and any body receipt debt
refuse admission. No fallback allocation is attempted.

After initial parking, a later coherent physics observation must confirm the
park. The activation uses only the existing byte-pinned setters and the body's
validated creation position and rotation. It checks identities around each call,
checks both exact collision masks, requests dynamic motion and wake, then waits
for a genuinely later coherent observation. Setter return alone is insufficient.
The native body may be dynamic privately while its SDK slot remains retained and
inactive; normal APIs stay closed.

On the post-Follow path, begin performs only fresh reads and takes cleanup
responsibility before a later activation tick; it does not issue another initial
park. The `initial_park` row sets `historical_park_basis=true` and copies the prior
completed park's original write-floor epoch without an observation;
`initial_park_observed` records the new parked observation. These two
rows must not be counted as a new park command. The same unchanged allocation,
shapes and original definition are used throughout. Missing or changed handoff
history invalidates later activation and observations without dropping cleanup.
The final explicit repark remains a new command followed by a later observation.

The run deadline is fixed at 2,000 ms after admission and the cleanup deadline at
3,000 ms after admission. Neither renews. Existing physics-clock freshness and
identity checks remain in force. Metadata revocation and timeout accounting run
even when normal client readiness is lost; an eligible frame or surviving plugin
poll is not required to record failure.

Final parking uses an explicit qualified path. Ordinary `release()` would skip
an already-retained SDK slot, so it cannot finalize this experiment. The
original SDK park timestamp and terminal history stay unchanged; diagnostic
re-park observations and timestamps are separate.

Timeout, cancellation, owner unload, or partial native failure stops activation
and preserves the first failure. It does not erase an admitted native cleanup
duty. Cleanup writes are attempted only while the exact current native identity
still qualifies. A later cleanup result cannot turn an earlier failed activation
into a successful experiment. If cleanup remains unconfirmed, retain that fact
and end the isolated process under the execution owner's control. There is no
blind rollback, automatic retry, destructor or allocation recycling.

## Copied diagnostics

The result reports a bounded status (`pending`, `observed`, `expired` or
`invalidated`), phase, first failing check/phase, cleanup disposition
(`pending`, `confirmed` or `unconfirmed`), outstanding cleanup duty, elapsed time,
target pose and a cycle count bounded to one. `native_retirement_known` remains
false. Fixed-capacity stage records copy qualified epochs, measured body facts,
mask values and pending force/torque facts. Records expose no raw pointers or
native handles. The binding validates enums, counts and finite-value/epoch
relationships before copying a result to Lua.

Every stage row explicitly reports `historical_park_basis`. It defaults to false;
true is valid only for a passed `initial_park` row without an observation. A true
row records prior completed Follow cleanup, not an initial native park command
issued by this diagnostic. Count native actions accordingly; the flag does not
turn historical evidence into a fresh observation or add another cycle.

`observed` describes only the completed diagnostic mechanism and its verified
cleanup. Mask/dynamic-bit readback does not establish contact or broadphase
participation. No result is reuse eligibility, an acknowledgement of a dependent
consumer, or permission to revive the old body handle.

## Validation boundary

This change is a source-only checkpoint until the execution owner runs both
normal and qualification Release builds and the focused provider/Host tests.
Source fixtures use constructed native data and counted stand-ins; they cannot
establish actual game behavior.

Post-Follow source fixtures construct the trusted service handoff precondition;
they exercise the World provider, retained history and refusal paths with counted
stand-ins. They do not execute the real Follow callback/drain/ACK chain. A native
post-Follow experiment must separately retain evidence of that actual chain,
unchanged allocation and shapes, fresh parked state, activation and final repark.
The earlier never-held experiment supplies no post-Follow qualification.

Even a successful one-cycle game experiment is only a prerequisite. Real contact
behavior at changed poses, absence of old-pose contacts, more than eight cycles
on one allocation, and the complete Follow stop/ACK/body-command-ACK lifecycle
remain separate required qualifications before repeatable mounting can be
claimed. Cross-owner or cross-VM adoption, destruction and native pose-consumer
retirement remain outside this diagnostic.

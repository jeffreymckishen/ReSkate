# Portable input report pulses

`Engine/Game/Input/input_pulse.h` supplies a generic, portable policy for one owned XInput
button report. The permissioned client API requests this transport explicitly; loading a plugin
or ReSkate does not itself request a pulse. Equipment mappings and gameplay success checks belong
in Lua. Portable and Host tests use constructed facts, not native-consumption evidence.

## Client API

Declare `input.control` in `reskate-plugin.json`. Existing `input` permission alone does not grant
pulse control. The four methods refuse on the dedicated/server side before touching the backend.

```lua
local h, why = reskate.input.pulse(0, "a")
if h then
    local receipt, read_why = reskate.input.pulse_state(h)
    -- Cancel only stops future assertions; cleanup can still be pending.
    local accepted, cancel_why = reskate.input.pulse_cancel(h)
    -- Only a terminal record with no report debt and a released claim can be acknowledged.
    local removed, ack_why = reskate.input.pulse_acknowledge(h)
end
```

The first argument is an integral XInput user slot 0..3, an observed stream rather than a physical
device identity. The second is one canonical name (`up`, `down`, `left`, `right`, `start`, `back`,
`left_stick`, `right_stick`, `lb`, `rb`, `a`, `b`, `x`, `y`) or one valid numeric button bit.
Fractions, coercible numeric strings, unknown/embedded-NUL names, reserved bits, combinations and
extra arguments refuse. There are no equipment action names or axis/trigger writes.

The opaque userdata is bound to its VM instance. A reload cannot use an older VM's handles.
Starts share the VM's four-control-attempt fixed-window budget; the service additionally enforces
four starts per rolling 1000 ms globally, one active/unresolved request and eight retained records.
Read/cancel/ack are not starts. Unsupported/unobserved transports refuse; no fake connection or
fallback to another input API is provided. Dropping a userdata is not a cleanup mechanism.
This is state-buffer transport through outer GetState/GetStateEx/front wrappers; it synthesizes
no GetKeystroke, DirectInput or raw-HID events. An observed state poll does not identify a gameplay consumer.

`pulse_state` returns status/reason, `terminal`, requested user/button, and decimal strings for
sequence, source epoch, times and 64-bit counters. It exposes `press_candidates`, `press_publications`,
`neutral_publications`, `warmup_deferrals`, `original_failures`, `contentions`, `report_debt`, `claim_released`,
`actor_retired`, `orphaned` and `quarantined`. A known original error code is optional. Epochs label
SDK observations, not GUIDs. Terminal status alone does not authorize acknowledgement.

`first_rejection_mask` is an exact integer bitmask of failed checks at the first rejected owned
decision. `first_rejection_stage` identifies that decision: `service_plan` for the service's
source/deadline checks, `core_plan` for the initial policy decision, `prepublish` for its repeated
publication-boundary checks, `tick_ready` or `tick_deadline` for client-tick revocation, and
`publication` for an uncertain output write. Before rejection it is `0`/`none`. Explicit cancellation
also retains `0`/`none`; tick readiness loss retains `0`/`tick_ready` with reason `unavailable`,
and an uncertain write can retain `0`/`publication`. Zero is not proof that providers stayed available.

| Bit | Failed check |
| --- | --- |
| 0 | Original return code was not success. |
| 1 | No readable successful returned output was available. |
| 2 | The bound source observation was not fresh/current. |
| 3 | Returned and original transport result codes differed. |
| 4 | The broker reported competing capture/filter interference. |
| 5 | The full supplied owner/sequence/source/actor key differed. |
| 6 | Full raw and returned pads differed. |
| 7 | Source timestamp was absent, future, stale, or decision wall time rewound. |
| 8 | Native sample was absent, nonfinite, negative, future, stale, or decision wall time rewound. |
| 9 | A usable native sample did not preserve serial/time progression. |
| 10 | The actor claim was not current. |
| 11 | Focus was not qualified. |
| 12 | Gameplay was not active. |
| 13 | The menu was not closed. |
| 14 | A usable native sample exceeded the .25-second native gap. |
| 15 | Owned decision gap exceeded 100 ms. |
| 16 | Request age reached its one-second deadline. |
| 17 | Physical input became nonneutral during the press phase. |

Bits 9 and 14 require a usable native sample; an absent clock records bit 8 rather than invented
continuity facts. Unrelated slots, inner calls and stale generation tickets bypass evaluation and
cannot replace the witness. Service source rejection records its decisive source check plus
original/output/transport/source-timestamp failures already known there; it does not infer native
clock or actor failures that it has not evaluated. Several failed checks may coexist. A singleton
focus/menu/gameplay/interference/actor/native-clock/continuity failure maps to the corresponding
typed reason; combined masks can retain the generic `unavailable` reason. These are sampled facts,
not proof of which failure caused another or why a native provider refused.

The first mask and stage remain unchanged through later cleanup, retirement and retained reads.
The core also preserves its mask across acknowledgement until a fresh accepted request resets it;
the service's acknowledged record is removed. This adds no retry, weaker guard, raw data or address.

The same first decision now retains bounded actor-observation diagnostics. The eight Boolean
fields are `first_actor_observation_known`, `first_actor_owner_present`, `first_actor_call_active`,
`first_actor_inspect_attempted`, `first_actor_inspect_succeeded`, `first_actor_equal`,
`first_actor_clock_attempted` and `first_actor_clock_known`. Four enum strings retain
`first_actor_enter_phase`, `first_actor_enter_reason`, `first_actor_inspect_phase` and
`first_actor_inspect_reason`. No native actor address, identity tuple or handle is included.

`first_actor_observation_known=false` means no poll observation was captured at that first
decision, such as an explicit cancellation or client-tick stop. Before a rejection, phases are
`not_attempted` and reasons are `none`. A failed call admission skips inspection; failed
inspection or actor equality skips the clock probe. In particular, `clock_attempted=false`
with `clock_known=false` does not show that a clock provider failed. Later positive observations,
cleanup and retirement never replace these first-decision facts.

Phases name existing refusal edges: entry/inspection owner Try-locks, ownership/claim checks,
controls, validation, capture, actor/world/lifetime fences and final identity. The strings
`qualified` and `not_attempted` distinguish successful and skipped probes. Grouped edges such
as `controls_profile`, `capture`, `context` and `final_lifetime` do not identify which constituent
condition failed. `enter_claim` means arbiter entry refused; its `busy` reason does not prove
lock contention. These diagnostics classify the existing provider calls and short circuits;
the narrow no-output warmup rule below is a separate service decision.

Profile refusal now identifies the existing failed edge with `controls_profile_lock`,
`controls_profile_inactive`, `controls_profile_manager_read`, `controls_profile_manager_null`,
`controls_profile_phase_read` or `controls_profile_exception`. The native reason remains
`unavailable`. A lock refusal means the nonblocking acquisition failed; it does not identify the
lock holder or establish profile readiness. The input callback never waits for that lock. A queued teleport
still reports known/pending, and successful native-phase reads retain the existing Boolean result.

Before any press candidate, press publication, neutral publication or report debt, the same
warming request may discard one sample whose complete typed observation identifies only
`controls_profile_lock`/`unavailable`: call admission succeeded, inspection actually ran and
refused at that edge, and the actor clock was skipped. The original source, exact raw-neutral
report, clean transport, focus, gameplay, closed menu and wall/deadline guards must still pass.
That sample publishes no SDK button, claims no actor or native-clock success, and resets the
neutral dwell/sample count. It keeps the original key, native high-water marks and one-second
deadline; four fresh advancing native samples over 100 ms are required before a later press.
There is no new request, claim acquisition, callback wait or automatic retry of a failed output.

The decimal counter `warmup_deferrals` counts only accepted discarded warmup samples on that
handle. It is unknown-actor/no-output bookkeeping, not an output-publication, profile-readiness
or native-consumption witness. A refused deferral follows the normal rejection path, including
every other profile phase, any other failed guard, an earlier rejection, or any prior candidate.
After assertion, the exact same lock refusal still revokes and retains the first failure witness;
fresh same-source raw-neutral cleanup remains independently qualified. Deferral preserves the
normal packet finalizer and passes through the current report without pulse confirmation.

The publication scope is `process_outer_xinput_buffer`. SDK output-buffer publication does not
prove the wrapper subsequently returned normally. Both `consumption` and `semantic_completion`
remain `"unobserved"`, including after `released`. No receipt grants raw memory or an actor ticket.
VM unload requests stop but retains outstanding report cleanup duty instead of releasing it as completed.
The native adapter waits for its first claim-bound clock observation without resetting the one-second
request deadline. A failed original poll ends the observed source epoch. If a possible press is still
unresolved, a new epoch cannot discharge it and new requests remain blocked. Actor destruction is
not used to excuse process-wide report debt. `contentions` does not classify failures in the provider's
Try locks; a zero value is not proof that those providers never became unavailable.

A refused start has no handle. Admission reasons identify the failed phase: `client_not_ready`
means the latest client tick did not enable the service, `wrong_thread` means the request was not
on that tick's thread, and `client_tick_stale` means its timestamp was future or older than 250 ms.
`actor_unavailable` means actor acquisition returned an otherwise unclassified refusal; existing
specific focus, actor/world, protection and busy classifications are preserved. `clock_unavailable`
means actor acquisition succeeded but clock enabling failed and the newly acquired claim was
retired. `cleanup_pending` means that retirement could not be proved: a private orphan retains the
claim, exposes no usable handle to the failed requester, and blocks another start until cleanup.
These phase labels do not establish which native condition caused a refusal or authorize retry.

One-time clock enabling on the client thread waits for the SDK's owner/clock bookkeeping locks,
as actor acquisition already does. The owner lock is released before the clock lock is acquired,
and the clock lock is released before final owner checks; they are never held together. Full
thread, owner, world, generation and scope-specific native checks remain on both sides of initialization.
Native feed, clock reads and disable paths retain their existing nonblocking Try-lock behavior.
Waiting is not a bounded-latency guarantee or permission to use an obsolete identity.

Input-buffer pulses explicitly use the shared actor service's `observed_context` continuity scope.
It retains the original owner, sequence, ticket, full local ownership chain, watched-actor destruction
counter and local context generation. Each assertion and claim-clock observation freshly qualifies
that context and brackets its work with the same current idle global destruction epoch. A completed
destruction between operations does not by itself change the local context; a destruction during an
operation, watched-actor destruction, changed ownership/world, unavailable context or stale clock
still refuses. The original claim key, deadline and accumulated clock are never rebound or restarted.
Observed clock publication and reads also require the exact claim to remain published; a revoking
claim can retain cleanup ownership without retaining clock authority. Candidate clock changes are
staged and discarded if their closing observation or claim check fails.

Teleport readiness uses a separate guard owning the actual queued teleport data.
Native observers Try-lock that guard, without taking the broad profile mutex used
by catalog updates and saves. They freshly read the native manager and phase at
both ends of each idle observation. Position requests and both native teleport
dispatch paths remain pending through transition destruction, including recursive
callbacks. Merely queued placement tokens retain their previous omitted-pending
semantics. Queue changes and profile activation/invalidation advance a nonwrapping
revision. Actor validation brackets its full ownership recapture with current
idle views of the same revision, base and native manager. No idle native state is
cached. These endpoint observations do not pin native lifetime or exclude same-value
native ABA or a change after the closing read. All other assertion guards remain.
The historical profile-lock refusal identifies no actual holder or duration; this
source change still needs its own in-game validation. Post-press unavailability
continues to stop assertion immediately, without deferral or automatic retry.

This is sampled local-context continuity for process input publication. An unchanged watched-root
counter does not identify which other entity was destroyed, or prove that every child component or
world object could not have been retired and reused at the same address between observations.
It is not permission for a typed native setter to reuse such a context. Native action writes and
recovery retain the default `native_lifetime` scope and its admission-global-epoch requirement.
The explicit scope is internal; a plugin cannot choose it, receive an actor identity or use it to
access memory. Report publication, consumption and semantic-completion claims remain separate.

## Caller contract

A broker must supply a nonzero VM owner, globally nonreused sequence, source-observation epoch,
opaque actor claim ticket and user slot. These are admission inputs, not identities discovered
by this policy. An observed slot, packet or source epoch does not prove physical device identity
or connection continuity. The broker must independently qualify the current actor ticket, fresh
native clock, foreground ownership, gameplay, closed menu and absence of competing input filters.
No game address, native state number or equipment/button mapping is part of this component.

Every operation requires caller serialization. Snapshot `ticket()` before the original poll;
then hold the same service gate across `poll`, actual output-buffer publication and `confirm`.
Revocation invalidates earlier generations. Copying/recreating the policy per callback or allowing
another thread to publish outside that gate breaks the contract. `confirm` is an at-most-once
caller operation; the caller must not submit an obsolete candidate after a newer owned poll.

`Input.source_observed_ms` records the successful original report; `Input.now_ms` must be a fresh post-original decision timestamp, with a further publication-time
deadline check in the eventual wrapper. The policy cannot bound OS scheduling latency. All native
readiness facts need a real producer; changing booleans in a test is not that producer.

## Report behavior

The caller selects one valid XInput button bit. Before pressing, the policy requires exact raw
neutral input, four distinct advancing native samples, at least 100 wall milliseconds of neutral
warmup, and an advancing sample at launch. Repeated samples cannot complete the warmup. Exact
neutral means all buttons, triggers and axes are zero; this component defines no stick deadzone.
Native observations and owned poll gaps may be at most 100 ms old. Native time must be finite and
monotonic; a gap exceeding .25 simulated seconds revokes assertion.

The only pad edit is OR of the selected button while raw remains neutral. Any physical activity
revokes further assertion, preserving every physical field rather than making an unintended chord
or clearing a real button. Failed-original return codes and output values remain unchanged.
Inner/overlay polls and other user slots pass through without altering the bound transaction.
Existing scripted replacement, filters and hidden-button transformations must be excluded or
accounted for by the broker; full raw/returned equality alone does not establish clean ownership.

No new assertion is planned when elapsed wall time reaches 200 ms, or when request age reaches
1000 ms. These deadlines are checked on subsequent owned outer polls. With no such poll, phase
does not advance by itself: the runtime broker revokes on its client deadline. Neither expiry
nor revocation invents an asynchronous release of a report already cached by the game.

Once a press is possible, source loss, disconnection, unload and uncertain publication retain
potential report-release debt. A successful unchanged, fresh, same-source raw-neutral
publication, followed by `confirm(output, true)`, clears it. A failed neutral confirmation or stale
generation does not. Cleanup requires a fresh monotonic original-report timestamp, including after
a poll gap and a qualified clean transport. It may qualify despite actor or native-clock loss because it only forwards
the current raw neutral report, without dereferencing or resetting a native actor. Actor and native
clock qualification remain mandatory for assertion. A new source epoch cannot stand in for the
previous stream, and actor destruction cannot prove that a cached process-wide report was released.
Focus/menu loss cannot authorize another assertion. A competing menu/capture/script filter defers
cleanup even if its bytes happen to equal raw neutral. Unknown source retirement leaves debt
unresolved and prevents acknowledgement/rearming.

`press_candidate` and `release_candidate` are publication intentions. `confirm` records a caller's
output-buffer publication, **not** normal wrapper return, native input consumption, an animation,
equipment switching, recovery or gameplay completion. Those need separate evidence.

Request admission reserves three generation and six revision advances. Revocation is idempotent;
neither counter wraps. Exhausted counters refuse new requests. Optional initial counter values
exist for boundary testing; the runtime service constructs the persistent policy once at zero.

## Packet continuity

Use one persistent `PacketContinuity` per admitted slot, shared across every outer GetState,
GetStateEx and front wrapper. Finalize exactly once on every successful outer return, after all
permitted transformations, including after request retirement. Never reset it on VM unload or
acknowledgement. The policy revision must likewise persist across requests.

Before first assertion, the actual pre-finalizer returned packet passes through, preserving existing
filter/XOR tags. The overload accepting separate raw and returned packet numbers tracks both.
Afterwards the helper retains a private
modulo-32-bit domain. Epoch, revision, raw packet, full raw pad or final pad changes advance it.
This distinguishes adjacent changed publications, including same-raw-packet press/release,
retirement, raw-counter collisions and wrap. It does not promise global uniqueness across 2^32
changes, or repair a wrapper that bypasses the shared finalizer. Do not rewind the domain after
uncertain publication.

## Tests

With `DINGOSDK_BUILD_PLUGIN_TESTS=ON`, build `dingosdk_input_pulse_tests` and run CTest `input_pulse`.
The portable suite covers readiness failures, duplicate-clock warmup, the 200 ms boundary,
deadline revocation, physical-field preservation, stale in-flight generations, uncertain
publication, release debt, counter exhaustion and a complete same-packet report lifecycle.
It also isolates every failed-check bit, combined failures, and first-witness retention across
cleanup/acknowledgement and fresh-request reset.
It neither invokes the game nor establishes that any report is consumed there. The actual Host
suite also checks permission/side denial, strict arguments, opaque owner-bound handles, receipt
validation and large integer serialization, shared request limits, and unload debt semantics.
On Windows, `dingosdk_game_input_pulse_tests` links the actual runtime service against constructed
private providers, exercising its real locks, claim cookies and output buffers. Those tests cover
deterministic cancellation/unload interleavings, retained debt, source failures and the publication
deadline. Their fake actor facts do not qualify native guards or demonstrate gameplay parity.

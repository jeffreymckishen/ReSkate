# Portable input report pulses

`Engine/Game/Input/input_pulse.h` supplies a generic, portable policy for one owned XInput
button report. It is currently **unconnected to runtime input**: there is no hook, OS call,
Luau API, input lease or active gameplay integration. Loading ReSkate does not run it.
The tests use constructed facts; they do not qualify the native source or an actor.

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

`Input.now_ms` must be a fresh post-original decision timestamp, with a further publication-time
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
does not advance by itself: a future broker must revoke on its client deadline. Neither expiry
nor revocation invents an asynchronous release of a report already cached by the game.

Once a press is possible, source loss, disconnection, unload and uncertain publication retain
potential report-release debt. A successful unchanged, fresh, same-source/same-actor raw-neutral
publication, followed by `confirm(output, true)`, clears it. A failed neutral confirmation or stale
generation does not. Fresh monotonic post-gap input may qualify cleanup despite focus/menu loss;
it only forwards raw neutral. A new source epoch or actor cannot stand in for the previous one.
Unknown retirement leaves debt unresolved and prevents acknowledgement/rearming.

`press_candidate` and `release_candidate` are publication intentions. `confirm` records a caller's
output-buffer publication, **not** normal wrapper return, native input consumption, an animation,
equipment switching, recovery or gameplay completion. Those need separate evidence.

Request admission reserves three generation and six revision advances. Revocation is idempotent;
neither counter wraps. Exhausted counters refuse new requests. Optional initial counter values
exist for boundary testing; an eventual service constructs the persistent policy once at zero.

## Packet continuity

Use one persistent `PacketContinuity` per admitted slot, shared across every outer GetState,
GetStateEx and front wrapper. Finalize exactly once on every successful outer return, after all
permitted transformations, including after request retirement. Never reset it on VM unload or
acknowledgement. The policy revision must likewise persist across requests.

Before first assertion, raw packet numbers pass through. Afterwards the helper retains a private
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
It neither invokes the game nor establishes that any report is consumed there.

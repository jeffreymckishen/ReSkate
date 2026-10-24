# Selected-source input leases and capture

The client API reserves one explicitly selected observed XInput stream for fresh
read-only snapshots. Optional capture neutralizes that stream's admitted outer
XInput output reports. Loading a plugin does not acquire a lease or start capture.
Input mappings and gameplay policy belong to the plugin.

An observed XInput slot is not a physical controller identity. These operations
do not establish physical-device replacement, every route a controller might use,
or which native gameplay consumer read a report. They grant no actor, rider,
body, camera, or raw-memory ownership.

## Client API

Declare `input.lease` in `reskate-plugin.json` for all ten methods. The four capture
methods also require `input.capture`. Existing `input` permission alone grants
neither capability. Permission and client-phase checks precede argument parsing
and backend access; these methods refuse on the dedicated/server side.

| Method | Successful result | Ordinary refusal |
| --- | --- | --- |
| `reskate.input.lease(user)` | Opaque lease userdata | `nil, why` |
| `reskate.input.lease_read(handle)` | Observation table | `nil, why` |
| `reskate.input.lease_renew(handle, sample.epoch)` | `true` | `false, why` |
| `reskate.input.lease_state(handle)` | Lease receipt table | `nil, why` |
| `reskate.input.lease_release(handle)` | `true` | `false, why` |
| `reskate.input.lease_acknowledge(handle)` | `true` | `false, why` |
| `reskate.input.lease_capture(handle, sample.epoch)` | `true`; capture admitted | `false, why` |
| `reskate.input.lease_capture_state(handle)` | Capture receipt table | `nil, why` |
| `reskate.input.lease_release_capture(handle)` | `true` | `false, why` |
| `reskate.input.lease_acknowledge_capture(handle)` | `true` | `false, why` |

Each method takes exactly the listed arguments. Permission, side, argument-type,
arity, forged-userdata and cross-owner failures raise Lua errors. Backend
unavailability and normal lifecycle refusals use the results above. Malformed
backend observations are refused rather than exposed as valid receipts.

`user` is an integral **number** from 0 through 3. Numeric strings, fractions,
nonfinite values and extra arguments refuse. The slot is separate from the exact
uint64 source epoch. There is no aggregate-pad selection or transport fallback.

Handles and sample epochs are locked opaque userdata bound to one VM instance
and one lease. A reload cannot reuse the previous VM's handle. Editing or copying
visible sample fields cannot create an issued epoch. Use the returned `sample.epoch`
with that same lease; a table, number, another lease's epoch, or a physics epoch
is not an input proof. Dropping userdata is not a cleanup mechanism.

Lease acquisition attempts share the VM's four-control-attempt fixed-window
budget per second. Read, renewal, release and acknowledgement are not lease starts.
The service also enforces source reservations, pulse/capture interference and
bounded retained records; ordinary refusal does not authorize weaker fallback.

## Read observations

Acquisition records a continuity boundary, not a readable input sample. A later
eligible outer poll must carry the lease's begin cookie captured before its
original XInput call. A poll already running when the lease was acquired cannot
seed the new lease's cache. A lease can therefore be `warming` while `lease_read`
returns unavailable. The API does not invent a connection or force a poll.

`lease_read` returns these fields:

| Field | Meaning |
| --- | --- |
| `epoch` | Opaque issued snapshot proof for this VM and lease |
| `sequence` | Lease sequence, exact uint64 decimal string |
| `source_epoch` | Observed-stream epoch, exact uint64 decimal string |
| `context_generation` | Observed readiness/context generation, exact uint64 decimal string |
| `observation_serial` | Source observation ordinal, exact uint64 decimal string |
| `observed_ms` | Source observation timestamp, exact uint64 decimal string |
| `user` | Selected numeric XInput slot 0..3 |
| `packet` | Original observed uint32 packet counter, exactly representable as a number |
| `pad` | Saved original-source pad described below |

The pad fields are `sample.pad.left_x`, `sample.pad.left_y`,
`sample.pad.right_x`, `sample.pad.right_y`, `sample.pad.left_trigger`,
`sample.pad.right_trigger`, `sample.pad.buttons` and `sample.pad.playstation`.
Sticks are linearly normalized to [-1,1], preserving both endpoints; triggers
are normalized to [0,1]. No stick deadzone is applied. `playstation=false` names
this XInput representation, not the physical hardware behind it.

The Boolean button names are `up`, `down`, `left`, `right`, `start`, `back`,
`left_stick`, `right_stick`, `lb`, `rb`, `a`, `b`, `x`, `y`.
For example, the original A state is `sample.pad.buttons.a`.

Read and lease-state tables include `transport="xinput"`,
`source_identity="observed_stream"`, `physical_device_identity="unobserved"`,
`mode="observe"`, `capturing=false`, and `report_debt=false`.
These describe observation itself. They do not mean an associated capture has
no report debt: check `capture_reserved` on the lease receipt and the separate capture receipt.
The original cache remains the read source while capture publishes neutral
output. Do not substitute aggregate `input.gamepad()` or suppressed output.

## Freshness and renewal

Source observations may be at most **100 ms** old. A lease deadline is **250 ms**
from acquisition or successful renewal; it expires at `now >= expires_ms`.
These are separate bounds: a stale source can expire sooner than the deadline,
including warming without a qualifying post-acquisition observation.

Only the exact most recently issued snapshot can renew, once for each strictly
advancing observation ordinal. A later accepted native report alone does not
invalidate an already issued, still-fresh snapshot, but a later `lease_read`
replaces the most recently issued snapshot. Replaying a renewed ordinal does
not renew again. A successful renewal extends the deadline from the checked
current time; repeated reads and receipt inspection do not extend it.

Do not convert uint64 strings through `tonumber` or truncate them into a slot or
local numeric epoch. Packet equality does not imply observation equality, and a
changed packet does not identify a physical controller. Cached Lua tables and
old receipt timestamps are not continuing authority.

`lease_state` returns `status`, `reason`, `terminal`, `sequence`, `user`,
`source_epoch`, `context_generation`, `requested_ms`, `expires_ms`, `observed_ms`,
`last_observation`, `renewals`, `source_released`, `capture_reserved`, and `orphaned`,
plus the observation metadata above. All listed times, epochs, ordinals and
counters are exact uint64 decimal strings. Before the first accepted sample,
`last_observation` and `observed_ms` are both `"0"`; acquisition does not fabricate
a source observation timestamp.

Statuses are `warming`, `active`, `released`, `revoked`, and `expired`; the last
three are terminal. Focus, menu, gameplay, context, source, timing and interference
changes can revoke or expire the lease. Reasons classify checked refusal/state
edges; they are not proof of native consumption or a physical causal diagnosis.

## Optional neutral capture

Capture requires both permissions and a current active lease. Its proof must be
the exact issued snapshot **and** match the currently accepted source ordinal and
pad. The native route must be capture-eligible and earlier source calls drained.
This is stricter than ordinary renewal. A `busy` admission can refuse without
capturing; do not infer suppression from a request or a Boolean permission.

Successful `lease_capture` initially admits `waiting_neutral`. Capture begins
only on a strictly later fresh outer report whose complete original pad is
exactly zero: all buttons, triggers and both sticks. There is no deadzone.
Admission itself need not prove that later neutral report exists.

Once capture publishes neutral reports, the original pad remains available from
`lease_read`; authorized capture suppresses the selected output report, including
later nonneutral original input. It does not synthesize button presses, control
another slot, or promise GetKeystroke, DirectInput, raw-HID or other-route coverage.

The capture deadline follows the admitted lease deadline. Renew the passive
lease with a fresh issued epoch while continuing capture, and independently
inspect capture state: successful lease renewal alone is not proof capture
remains active. Each lease permits at most one successful capture admission,
even if released before suppression starts. A failed admission does not consume
that opportunity; a completed capture requires a new lease for a new capture.

`lease_capture_state` exposes `phase`, `reason`, `terminal`, `sequence`, `user`,
`source_epoch`, `context_generation`, `generation`, `revision`, `expires_ms`,
`publications`, `neutral_releases`, `report_debt`, and `quarantined`.
Sequence, epochs, generations, revision, deadline and counters are exact uint64
decimal strings. No native owner key or memory identity is exposed.

Its metadata is `transport="xinput"`, `source_identity="observed_stream"`,
`physical_device_identity="unobserved"`, `mode="capture"`,
`capture_scope="selected_observed_xinput_stream"`,
`publication_scope="process_outer_xinput_buffer"`,
`consumption="unobserved"`, and `semantic_completion="unobserved"`.
`capturing` is true only in phase `capturing`.

Phases are `waiting_neutral`, `capturing`, `releasing`, and `complete`; `terminal`
means `complete`. `publications` counts confirmed owned output-buffer writes;
`neutral_releases` counts confirmed neutral handoffs. Neither is proof the wrapper
returned normally or that native gameplay consumed the report.

## Release, retained duty and acknowledgement

`lease_release_capture` requests capture stop. `lease_release` stops observation
and also requests stop for its associated capture. Stopping does not invent an
asynchronous neutral handoff. Release before any possible owned write can
complete without debt; a published or uncertain attempted write retains debt.

Debt clears only after a later qualifying clean, same-source, raw-neutral report
is successfully published as neutral. Returning to neutral matters during release
as well as admission. Source change/loss can quarantine retained debt; a new
source epoch cannot discharge the old stream's duty. Competing filters, captures
or scripts can defer cleanup even if their bytes happen to equal neutral.
Loss of capture authority stops assertion; cleanup uses its separate safe
same-source/freshness/interference checks. Expiry never clears debt by itself.

`capture_reserved=true` means associated capture duty or in-flight source calls
still reserve the source. It can coexist with a terminal observation receipt
and `source_released=false`. Observation's `report_debt=false` is not a statement
about that separate capture. Capture state remains inspectable after passive
release until capture acknowledgement succeeds.

Capture acknowledgement requires `complete`, no report debt, and drained source
calls. A terminal receipt or `quarantined=false` alone is insufficient. Lease
acknowledgement is blocked while associated capture remains busy. An accepted
release is not an accepted acknowledgement; preserve handles and inspect refusal.

For a bounded client lifecycle, use this order rather than an immediate-call
example that assumes future polls or successful cleanup:

1. Explicitly choose a slot and acquire one lease. Wait for actual post-cookie
   input while retaining a finite caller watchdog; do not capture through a menu.
2. Read an actual fresh snapshot. If capture is needed, request it with that
   snapshot's epoch and wait for measured `capturing` state. Keep original-source
   reads and exact-epoch renewal bounded; stop on failed authority or watchdog.
3. Request capture release and passive lease release. Keep controls neutral and
   inspect retained receipts; do not replace unobserved cleanup with a timeout.
4. Acknowledge capture only after its actual complete/debt-free/drained handoff;
   respect an acknowledgement refusal. Then require terminal passive state,
   `source_released=true`, and `capture_reserved=false` before acknowledging the lease.
5. If the caller watchdog expires first, retain/report cleanup as unknown. Do not
   force-clear debt, acquire a replacement source, or count refusal as completion.

VM unload requests cleanup before other owned resources are released. Passive
receipts can be removed, while native orphaned capture duty and source reservations
remain until qualified cleanup and poll drain. Reloading a plugin neither proves
neutral release nor gives the new VM access to the old owner's handle. No API
receipt grants gameplay completion, input-consumption proof, or a physical-device
identity beyond the selected observed stream.

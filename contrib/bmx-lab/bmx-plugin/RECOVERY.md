# Recovery request policy

`plugin/recovery.lua` is a deterministic BMX recovery policy over the public
native recovery receipts. It returns intents and never calls `reskate.*`.
Requiring it performs no tests, input capture or gameplay action. `main.lua`
and the package manifest remain unchanged and inert.

```lua
local Recovery = require("./recovery")
local recovery = Recovery.new()
-- The integration adapter supplies a complete frame on each observation.
local decision = recovery:update(frame)
```

A frame contains exact nonnegative integer `now_ms` through2^53-1, a stable
opaque `actor` token, nonzero uint32 `source_epoch` and `fall_epoch`, and strict
booleans `gesture_down`, `allowed`, `loaded`, `fallen`, `park_ready` and
`release_ready`. The public `reskate.time.now()` is fractional milliseconds;
an adapter must validate it and use `math.floor(now)` for this model's clock.
Equal clocks may join returned results but dispatch no new intents. A down
observation at an equal clock consumes its edge, so the held gesture cannot
fire on a later clock. Invalid or backward clocks stop dispatch and invalidate
active policy context.

The model accepts opaque userdata or bounded primitive tokens for portable
tests. Token shape is not actor ownership. The caller must provide real actor
and source generations; the current gamepad API does not establish a device
replacement epoch. `fall_epoch` is monotonic per actor and denotes a new
caller-qualified incident, not a counter to increment merely to retry.

Request admission needs a neutral observation followed by an explicit fresh
gesture while focused/allowed, loaded and fallen, with both caller handoff
conditions true. `park_ready` means the adapter independently qualified the
bike body's park barrier; `release_ready` means it independently qualified
actor-control release. This module creates neither witness, issues neither
release, and proves neither condition from a flag. The useful body-follow and
quiescent body-release integration remains missing. Do not wire these fields
to unconditional true in a live adapter.

A denied gesture is consumed: becoming ready while still holding it does not
request recovery. A fresh gesture can be tried after readiness arrives if no
request was issued. Once a request intent is emitted, that fall epoch is spent
even if the API refuses. No held gesture, focus return, new source or native
failure automatically retries. Another incident and explicit gesture are
needed; an outstanding unknown/debt-bearing call blocks even a new incident.

## Joining the caller's calls

Every returned `intents` table and receipt is a fresh copy. Dispatch only the
specific intent once, and supply its result on a later `update` frame:

- `request={attempt,actor,source_epoch,fall_epoch}` requests one external
  `reskate.skater.recover()` call. Join its returned handle as
  `request_result={attempt,accepted=true,handle=handle}`. A known `nil,reason`
  return joins `{attempt,accepted=false,reason=reason}`. An exception or lost
  return with uncertain native entry joins `{attempt,uncertain=true}`; it is
  retained without guessing that nothing happened or issuing another call.
- `poll={attempt,handle}` requests one read of that same opaque handle. Supply
  `receipt_handle=handle, receipt=full_public_table`. An unavailable read adds
  no receipt and does not clear the retained handle. Sequence and native/wall
  identifiers remain canonical decimal uint64 strings, including adjacent
  values above2^53. Do not convert them with `tonumber`.
- `cancel={attempt,handle}` is emitted at most once after a policy boundary,
  only for a known pending receipt with no true entry. The adapter reports
  subsequent receipts; cancellation never constitutes native rollback.
- `acknowledge={attempt,handle}` is emitted once only for a resolved terminal
  receipt, after returning its full copied contents. Store that receipt before
  making the external acknowledgement. Join
  `ack_result={attempt,handle,accepted=boolean}` exactly once. Failed
  acknowledgement is retained and not retried; a second changed result cannot
  rewrite the first call's outcome.

Negative terminal receipts cancelled or expired before a qualified callback
may omit `observed_ms`, as the public API omits a zero native timestamp. They
can still be acknowledged without inventing an observation. Completed recovery
requires its actual observed timestamp and full native/reset proof.

The schema rejects unknown fields, malformed counts/times/flags, changed
sequences, backward receipt phases and changed true/reset witnesses. An invalid
receipt retains the handle and stops standing acceptance; a later valid receipt
can still resolve its cleanup. A native failed terminal outcome cannot become
completed. Policy snapshots are Lua bookkeeping, not native authority or a
replacement for the SDK's own lifetime guards.

## Outcomes and cleanup

`pending`, `entered` and `reset` are separate observations. `unresolved` keeps
possible true/reset debt, even after a terminal failure. Focus, source, actor,
clock or unload loss never erases it. While the same VM remains loaded, the
policy may continue read-only polling and the single pending-only cancel.
`loaded=false` produces no API intents. Actual VM unload destroys this Lua
state and its handles; the generic SDK retains required native cleanup through
`release_all`. Do not serialize a handle and restore it into a new VM.

`standing` requires completed/none, exactly one actual true setter entry,
returned true plus true readback, a strictly later serial/time with verified
false reset, no unresolved/quarantined/retired actor, and a qualified observed
504 suffix with known false ragdoll/in_air, at least2 simulated seconds and
at least30 distinct native samples. The SDK's `stable_observed` flag supplies
its bounded-gap qualification; this model does not recreate unobserved steps.
`completed` without those fields becomes `completion_not_accepted`. A boundary
also prevents an old completion from granting current standing authority to
another actor/source/incident. Neither outcome proves rendering or future
balance.

Resolved negative terminal receipts remain `terminal_failure`. Independently
proven exact actor retirement permits acknowledging a terminal unresolved
record only with quarantine cleared; its outcome is `actor_retired`, never
standing or false verification. An unknown request without a returned handle
remains `request_unknown`; no policy timeout fabricates release.

## Validation boundary

`plugin/recovery_tests.lua` exports an inert `run()` model regression suite.
The actual vendored Luau Host should load these two modules with no permissions
and execute `require("./recovery_tests").run()`. It returns
`{cases,assertions,native_actions=0}`. Coverage includes barriers, held gestures,
one request per fall, exact receipt identity, cleanup across context loss,
pending-only cancel, uncertain returns, terminal failure/retirement, malformed
proofs and one-result acknowledgement. Host execution is pending for these
revised files; pure policy results alone establish no native recovery. The first
Host run passed15 groups and316 assertions, but subsequent source review found
the omitted negative-terminal timestamp and equal-clock held-edge cases. Their
direct regressions are now included; that earlier passing run does not validate
these revised bytes. Private execution evidence is retained in
`build/bmx/lua-recovery-policy-v1/`.

One separate staged native case used source `02473fc` and runtime SHA256
`CC8F68CA25086A49EFE555AFDF6BB98020A3B2C3C28F3E898505613093E05C11`.
After one SDK-induced lab wipeout, it accepted one recovery request, recorded
one true and one false native setter entry, verified reset at the next native
clock, and retained122 qualified standing samples over2.016666546 seconds
before one acknowledgement. The closed receipt and raw evidence are in
`build/bmx/lua-native-recovery-native-guard-v1/`. This module did not drive that
case. It establishes one staged recovery path, not bike parking, actor release,
ordinary fall coverage, repeated equipment switching or BMX riding.

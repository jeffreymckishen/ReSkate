# Native board and on-foot requests

The client-only `reskate.skater.action` API uses `skater.control` permission.
It requests one ordinary native equipment transition. It provides no movement,
pose or input lease, bike behavior, GetUp action or progression access.
The implementation is under development; native round trips remain unqualified.

```lua
local action, reason = reskate.skater.action("on_foot") -- or "board"
if not action then
    reskate.log(reason)
    return
end

-- On later client ticks, inspect the same opaque handle; do not repeat the request.
local receipt = reskate.skater.action_state(action)
if receipt and receipt.terminal and not receipt.quarantined then
    reskate.log(receipt.status .. ": " .. receipt.reason)
    assert(reskate.skater.action_acknowledge(action))
end
```

Request from an explicit user action with gameplay focused and the menu closed.
The native adapter rechecks the local actor, supported contracts, gameplay phase,
teleport/world state and conflicting motion/protection ownership before offering
the request. A refusal returns `nil, reason`. The API shares the existing limit
of four skater control requests per second. Invalid kinds fail before enqueueing;
the only kinds are exactly `"on_foot"` and `"board"`.

The opaque handle belongs to the current VM instance. A reload cannot inherit a
previous instance's native authority. It is not a pointer, body handle or actor
identifier and cannot be reconstructed from a sequence string. No other plugin
can read, cancel or acknowledge that instance's action.

`action_state(handle)` returns a fresh receipt table or `nil, reason`. Changing
the table does not change the request. Status distinguishes:

- `pending`: accepted for a bounded future native selector opportunity.
- `offered`: a new transient request bit was offered around a native selector call.
- `selected`: the native result survived the SDK's later selection filters.
- `completed`: a strictly later qualified observation found the requested state
  committed in the same actor's native context.
- `already_target`: the actor already satisfied the target; no transition was offered.
- `rejected`, `cancelled`, `expired` or `invalidated`: terminal, with a typed reason.

An offer is not proof that native code consumed a bit. The original selector
candidate, final SDK candidate and later committed state are separate optional
fields: `original_candidate`, `final_candidate` and `committed_state`. A native
board mount may select state 103 or 200 before reaching grounded state 100.
Those intermediate candidates retain the request and do not complete it.
On-foot completion requires committed 504 plus independently known false ragdoll
and airborne flags. State 504 alone includes falls and does not prove walking.
This slice recognizes board completion at grounded 100; it does not use a broad
numeric range or treat an intermediate air state as completed equipment.

Receipts include `kind`, `status`, `reason`, `terminal`, `sequence`,
`requested_ms`, optional `offered_ms`/`observed_ms`, `flag_restored` and `quarantined`.
`ragdoll` and `in_air` are omitted when unknown, rather than replaced with false.
Sequence and timestamp values are exact decimal strings. State numbers are
ordinary numeric observations; they grant no authority.

There is one active action across plugins and at most 32 retained receipts.
Pending offers expire after 250 ms; offered actions have a bounded four-second
window for observing completion. There is no automatic retry or forced state.
A pre-existing same/opposite request bit is a conflict, not a newly offered SDK
request. Restoration preserves unrelated word changes; it cannot prove exclusive
ownership of a bit or detect identical same-bit reassertion.

`action_cancel(handle)` cancels only a request that has not been claimed for an
offer. After an offer, cancellation cannot promise native rollback. Terminal
receipts remain readable until `action_acknowledge(handle)` frees their slot.
Acknowledgement refuses an in-flight or quarantined receipt. Failed restoration
retains the action/motion guard while its request bits remain unresolved. A later
qualified read that both bits cleared, or proof that the exact actor retired,
can clear quarantine; it does not turn the failed action into completion or
change `flag_restored` to true. No forced bit clear or repeated offer is attempted.
If an unrelated destruction changed the lifetime epoch, old-context bit reads
cannot clear quarantine; it can remain held until exact actor retirement or
process restart. VM shutdown releases only that instance's resolved records;
a native call already executing still performs its bounded
cleanup attempt. A false `flag_restored` is not successful rollback. Actor
destruction, replacement and world/phase invalidation retire the
corresponding authority instead of applying it to a new actor.
The initial lifetime fence conservatively invalidates an action when any native
entity destruction crosses it; `native_lifetime_changed` does not identify which
entity was destroyed. Busy worlds can therefore refuse an otherwise useful
request. This observation fence is not a lock on the native world's lifetime.

This API is a building block for Lua equipment policy. Native action transport,
repeatable equipment switching and full movement/input/pose handoff need separate
in-game evidence. No BMX riding or BMX Streets likeness is established here.

Two isolated native diagnostics on 2026-10-23 used the tested source committed as
`6eeddc8` and runtime SHA256
`CED4DA76C307F8785FDE3C2D626362D50C85255C8B695A85D0505570EA25B160`.
Each completed an already-on-foot baseline and one actual board/on-foot pair;
neither completed the required three pairs. The first stopped at the next board
request's `unsupported_state` refusal. The second waited for fresh grounded
physics flags, then its second mount selected 200 but entered ragdoll before
terminal invalidation with `request_bits_conflict`. That reason does not identify
the fall's cause; the adapter uses it for either an unreadable request word or
nonclear request bits. Its retained physics observations also show that cleared
airborne/ragdoll flags alone do not establish a physically settled body.

Both diagnostics stopped without retry, stored their terminal receipts before
acknowledgement, withdrew their manifests and unloaded before normal game exit.
The private evidence is in `build/bmx/lua-native-equipment-actions-trial-v1/` and
`build/bmx/lua-native-equipment-actions-trial-v2/`. These results qualify a narrow
transport path and failure handling; repeated switching remains unqualified.

A third diagnostic additionally required fresh finite physics velocity throughout
its readiness window. Its first mount still selected 200, passed through 201,
and entered known ragdoll before the later `request_bits_conflict` invalidation;
it completed none of the six requested transitions. Quiet velocity alone did
not prevent the failure. Its evidence is in
`build/bmx/lua-native-equipment-actions-trial-v3/`.

Two subsequent read-only captures in that same process observed ordinary Y input
from the guarded virtual controller. Each controller sequence completed all 181
reports. The first capture observed a Y press/release and watched states
504, 103 and 100, with a visible mounted rider. The second observed a Y
press/release and watched states 100 and 504, with a visible upright rider
carrying the board. Neither retained physics stream recorded a new wipeout or
known ragdoll. Both captures stopped when the controller disconnected, before
their twelve-second limits; the interval between captures was not recorded.
These observations establish a useful route-level contrast with the failed SDK
mount, not its cause: the starting conditions were different, and the observer
has no native producer or animation-state identity. The evidence is in
`build/bmx/lua-native-equipment-hid-observer-v2/` and
`build/bmx/lua-native-equipment-hid-observer-v3/`. All three diagnostic manifests
were withdrawn and unloaded before normal process exit; their saved ledgers
were unchanged after exit. This is an ordinary-input baseline, not a switching
fix, a repeatability result or BMX likeness evidence.

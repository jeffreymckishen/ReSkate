# Passive actor motion-refresh observation

This client API copies diagnostics around the existing local actor mover relay.
It allocates no body and grants no movement, input, attachment or follow authority.
Declare both `world.physics` and `world.physics.observe` in `reskate-plugin.json`.
Permission and client/server checks run before argument parsing or backend access.

| Method | Success | Ordinary refusal |
| --- | --- | --- |
| `reskate.world.physics.begin_motion_refresh_probe()` | Opaque probe userdata | `nil, why` |
| `reskate.world.physics.poll_motion_refresh_probe(probe)` | Copied result table | `nil, why` |

Begin takes exactly zero arguments; poll takes exactly one issued probe.
Permission, server-side, arity, wrong-userdata and cross-VM ownership failures raise
Lua errors. Unavailable backend/state, stale requests and invalid backend results
return `nil, why`. A probe is neither an owned body nor a body-submit epoch.
It belongs to the issuing VM instance; tables, copied fields or a reloaded VM
cannot recreate its authority. The methods expose no native pointers or sequence IDs.

## Admission, lifetime and polling

Motion-refresh and body-sync probes share one begin attempt and eight poll
attempts per plugin tick. Refused backend calls consume those same budgets.
Only one motion-refresh request can be pending globally. Each admitted request
has a fixed 1,000ms wall deadline and a 128-entry admission cap; these do not
promise 128 callbacks, every native call, or an exact physics-step interval.

A cold begin requests deferred read-only clock setup and returns a known refusal.
It does not arm a request: begin again only through a later explicit action.
Admission also requires an actual attested entry on the existing mover relay,
current local actor/clock qualification and matching supported source bytes.
Begin neither forces a mover call nor installs a new mover detour or motion claim.
Poll never starts a request. There is no public cancel method or body prerequisite.
Terminal results remain unchanged until another admitted begin replaces them or
the issuing owner closes. Owner close cancels pending and terminal requests even
when that owner has no bodies; replaced/closed handles cannot recover old results.
Dropping the userdata does not itself cancel a request.

## Copied result fields

| Field | Type and meaning |
| --- | --- |
| `status` | `pending`, `observed`, `expired` or `invalidated` |
| `armed_epoch` | Qualified epoch at admission |
| `confirmed_epoch` | Later qualified client epoch for `observed`; otherwise all-zero epoch |
| `client_revalidated` | Boolean; true only for `observed` |
| `elapsed_ms` | Finite nonnegative wall elapsed at poll/closure; not clamped to 1,000 |
| `record` | Copied native normal-return record described below |
| `routing` | Copied bounded counters described below |

Every epoch has `world_generation`, `lifetime_epoch`, `actor_epoch` and `serial`
as exact uint64 decimal **strings**, plus numeric `time` and `seconds`.
A qualified epoch has nonzero world/lifetime/serial; `actor_epoch="0"` is valid.
Record and confirmation epochs retain the admitted world/lifetime/actor identity.
Time is finite/nonnegative and seconds passes the calibrated 60Hz step predicate.
The all-zero epoch is a sentinel, not a qualified sample. Keep integers as strings.

`record` always contains `present`, `unchanged_forwarding`, `flag`, `input`,
`before_epoch`, `after_epoch`, `before` and `after`. `present` and
`unchanged_forwarding` are booleans; `flag` is a numeric uint8; `input` is a
one-based array of four finite float values copied before the relay call.
It is an input sample, not proof that a gameplay consumer used those values.
Each endpoint (`before`/`after`) contains flat one-based 16-number matrices
`root` and `inverse`, `caches` with three such matrices, `packets` with four,
and `flags`, a one-based array of four numeric uint32 values. Values are copied,
not writable native handles. An absent record retains zero/false default fields.

A present record brackets a normal relay return, with each endpoint stable within
its own copy; before/after matrices may differ. `before_epoch` is newer than
`armed_epoch` in both serial and time; `after_epoch` equals `before_epoch` exactly. `observed`
additionally requires later client actor/clock and packet-chain revalidation,
with `confirmed_epoch` newer in both serial and time, strictly before the deadline.
Pending, expired and invalidated results may still retain a present record.
`unchanged_forwarding` means the existing relay received the same caller values;
it establishes neither upstream stock provenance nor absence of other writers.

`routing` contains numeric uint32 `entries`, `matching`, `other`, `rejected`,
`dropped`, and boolean `limit_reached`. The five counters are independent
generation-qualified saturating lower bounds; contention/closure can omit counts.
Do not sum them or infer universal absence from zero. `matching` means sampled
rig/context equality, not an accepted endpoint record. `entries` is at most 128;
`limit_reached` is derived from that same returned `entries == 128`. It does not
mean global quiescence, and 128 does not bound the independent `dropped` count.

## One explicit attempt

```lua
local P = reskate.world.physics
local probe
local function start_explicit_attempt() -- Bind to an explicit user action.
    if probe then return end
    local handle, why = P.begin_motion_refresh_probe() -- Exactly one attempt.
    if not handle then print(why); return end
    probe = handle
end
reskate.on("tick", function()
    if not probe then return end
    local result, why = P.poll_motion_refresh_probe(probe)
    if not result then probe = nil; print(why); return end
    if result.status ~= "pending" then probe = nil; print(result.status) end
end)
```

The example does not retry an error/refusal automatically. A later explicit
action may attempt begin again, including after the cold-setup refusal.
No result supplies an allocation/lifetime pin, ABA exclusion, atomic snapshot,
native consumption, final revision fence, acknowledgement or target retirement.
This API provides no actuation or follow capability.

## Validation boundary

The normal Release runtime built with `/W4 /WX`; actual World Service tests passed
19 groups / 524 checks with zero native mutations. Eight new Host groups ran
73 constructed cases. The first plugin run preserved an older fixture's 50ms
Lua-budget failure while another compile was active; an unchanged quiet retry
passed 1/1 in 6.63s. Ten source-bound mover-wrapper checks also passed.
These are source/code tests. No native game result, mounted riding, switching,
recovery or BMX Streets likeness is established by this API documentation.

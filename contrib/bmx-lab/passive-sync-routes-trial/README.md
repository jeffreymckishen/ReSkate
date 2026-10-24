# Passive synchronizer routing diagnostic V2

This separately versioned diagnostic creates one 12 kg owned context capsule and
reads one passive actor-packet observation. It publishes no command, force, pose,
follow, controller or recovery request. It is not a playable bike, a native
invocation count, or proof that an actor consumed a packet.

V1 remains at `contrib/bmx-lab/passive-sync-trial` with its source, 15 Host cases
and separately recorded expired native history unchanged. V2 requires the
additive generic SDK `routing` result field; do not run it with the older API.
The normal plugin Host suite passed 17 constructed V2 cases (1/1 CTest, 5.48s;
15 unrelated optional fixtures absent). The [execution receipt](../../../build/bmx/passive-sync-routes-host-integration-v1/execution.json)
records the exact source and tested Host binary. These checks establish no
native V2 game result.

The page is `Passive Sync Routes V2` (22 bytes), package label
`LuaPassiveSyncProbe_20261024_v2`, run label
`a22f6ade-3380-41a0-99ed-45d3a5ed84ec`, and storage key
`passive_sync_native_v2`. Use a fresh package/storage/process evidence identity.
The package is inactive unless explicitly enabled. Loading or viewing its page
is inert. Existing storage, or a refused storage read, prevents admission.

Compared with V1, the only operational addition is strict copied routing facts
in `packed()` and the bounded poll ledger. The exact shape is:

```lua
routing = {
    entries = 0,
    matches = {0, 0, 0, 0},
    other = 0,
    already_recorded = 0,
    expired_entries = 0,
}
```

Each counter must be an integer number in 0..4294967295. `matches` must contain
exactly numeric indices 1..4, with no holes or additional keys. Missing, extra,
wrong-type, nonfinite, fractional, negative or oversized facts are rejected as
a malformed probe result. Each pending/terminal poll keeps its own copied raw
snapshot; terminal history is never relabeled or repolled by this diagnostic.

These counters are independent, saturating lower bounds. Matches count exact
wrapper routes before duplicate suppression; expired entries have a separate
counter. Counter sums and ordering are not validated or inferred. A zero value
does not prove universal absence of native invocations, and nonzero values do
not establish packet consumption, actor following or retirement. An expired
terminal result remains expired even when its routing counters are nonzero.

All V1 bounds remain: one explicit Arm, 120-second original Arm deadline, one
SDK request with its unchanged fixed 1-second observer window, 1.5-second Lua
delivery watchdog, 3-second body window, maximum 16 polls separated by at least
100 ms, at most two create calls, and only one separate explicit retry after the
exact known preallocation refusal. The body remains 12 kg at 2.5 m horizontal/1 m
vertical offset, with 1.5 m actor clearance. A stationary actor, neutral controls
and a clear placement are experiment conditions, not script measurements.
Known bodies receive one release attempt. Acceptance is not proof of parking,
destruction or command consumption; refused/unknown cleanup stays uncertain.

The additive Host fixture imports this exact V2 entry and real manifest, uses
the actual Host/VM/menu/opaque API/storage, and seeds constructed C++ native
result counters. Fault-only cases wrap the frozen entry with an injected
services table and modify only the actual API's returned routing facts. They
exercise the real entry's validation, rather than claiming an unchanged global
entry in those fault cases. Existing actual API permission-denial coverage and
the exact V1 tests remain. The Host result covers constructed backend facts;
each native trial requires its own process, binary and persisted-result evidence.

# Logical input observations

A client plugin with `skater.input_trace` may observe arguments delivered to two
verified dispatch lanes of the game's registered Boolean-input Update callback.
This diagnostic does not deliver input or change a skater's state. It is useful
when comparing physical input with native callback and state observations.

```lua
local trace, why = reskate.skater.input_trace()
if not trace then return end
-- Read on later ticks. The window ends after five seconds.
local receipt = reskate.skater.input_trace_state(trace)
if receipt and receipt.terminal then
    for _, row in receipt.records do
        if row.condition_known then
            print(row.asset_token, row.condition, row.snapshot_stable)
        end
    end
    reskate.skater.input_trace_acknowledge(trace)
end
```

`input_trace()` takes no arguments and returns an opaque handle or `nil, reason`.
There is one active window per VM, eight retained windows across the service,
and a maximum of four starts per VM per second. A window retains at most 128
changes. Repeated equal observations for the most recent row of an asset token
and dispatch lane increment `duplicates`; a false/true/false transition remains
three rows. Distinct changes beyond the capacity increment `dropped`. `seen`,
`duplicates`, `dropped`, sequence and millisecond times are decimal strings so
Lua's number representation cannot round them.

`input_trace_state(handle)` returns a snapshot or `nil, reason`. Status is
`active`, `stopped`, or `expired`; `terminal` means the window no longer accepts
observations. `input_trace_stop(handle)` closes an active window early.
`input_trace_acknowledge(handle)` frees a terminal window. VM shutdown revokes
all its windows, including callbacks already in flight. Handles cannot cross VM
instances or be constructed from a table or sequence string.

Each row has an `observed_ms`, `thread_id`, `lane` (`interpreter` or `alternate`),
an opaque `asset_token`, condition and qualification flags, and an adapter `issue`
code. `condition` is present only when `condition_known` is true. Tokens express
address equality within a window; zero means unavailable. They are not asset
names, pointers, retained native objects, or proof against allocation reuse.
`condition` is the raw second-argument byte when it is exactly zero or one.
It is not an inferred physical button level, an asset's Boolean value, or an
identification of the Y button. A zero byte skips the native publication branch;
the observer does not infer the input's clear or delivery semantics from that.

`local_tuple_known` means a validated local actor and its sampled input tuple
were readable. `container_matches_local` compares an opaque value in that tuple
with the callback's retained container. `snapshot_stable` additionally requires
matching observations before and after the normal callback and an unchanged idle
entity destruction epoch. These observations do not prove exclusive actor
control, a world lock, a coherent physics snapshot, or successful mounting.
An unknown or changing tuple remains explicitly unqualified.

The native callback uses nonblocking locks. `observer_busy_at_start` and
`observer_busy_total` are service-wide cumulative omission witnesses; their
difference is not an exact count of rows lost by this particular window.
Expiry, row caps and contention mean the receipt is a bounded sample, not a
complete input history. The observer only samples the two verified dispatch
lanes for the pinned game build. Other callers tail-forward without sampling.

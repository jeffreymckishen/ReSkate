# Passive body synchronizer probes

Use a probe to collect copied diagnostics around four native actor-packet
synchronizer calls. One existing owned body qualifies ownership, actor/world and
native clock; the probe creates no body, submits no command and publishes no target.

## API and admission

Declare both `world.physics` and `world.physics.observe` in the client plugin's
`reskate-plugin.json`. `world.physics` alone does not permit these observations.

| Call | Success | Ordinary refusal |
| --- | --- | --- |
| `reskate.world.physics.begin_sync_probe(body)` | Opaque probe userdata | `nil, why` |
| `reskate.world.physics.poll_sync_probe(probe)` | Result table | `nil, why` |

Each call takes exactly one argument. Permission, server-side, argument-type,
arity and foreign-VM userdata failures raise Lua errors. Native unavailability,
changed ownership/generation, an unavailable lifetime/clock, and an already
pending probe normally return `nil, why`. Treat refusal as unavailable data.

Pass one current body previously created by this VM through `world.physics`.
No epoch argument is accepted. The locked probe userdata privately binds the
VM, body generation and native observation sequence. A table, copied epoch,
numeric sequence, another VM's token or a token from before reload cannot replace it.

Limits are **one begin attempt and eight poll attempts per plugin tick**, shared
by all callbacks in that VM. Backend refusals and terminal polls consume attempts.
These are SDK tick budgets, not native physics-step or per-body allowances.

The native service has one shared probe slot. An unexpired pending probe blocks
another start, including another owner's. A successful start fixes a **1000 ms**
deadline; polling and receiving records never renew it. There is no duration,
renewal, cancel or acknowledge API. Stopping polls/dropping userdata does not cancel.

## Result and partial observations

| Field | Meaning |
| --- | --- |
| `status` | `pending`, `observed`, `expired` or `invalidated` |
| `terminal` | `false` only while pending |
| `armed_epoch` | Copied native clock metadata at arm |
| `observed_epoch` | Present only for `observed`; a qualified later native clock |
| `observed_mask` | Bits 0..3 identify present records 1..4; full mask is 15 |
| `rejected` | Saturating count of matched candidate observations that failed qualification |
| `dropped` | Bounded lower-bound count of observation losses under contention |
| `records` | Four entries, each always containing `present` |

Epoch metadata is `{serial, time, seconds}`: `serial` is an exact uint64 decimal
string; `time` and `seconds` are native numeric time/step values. Keep serials as
strings. These tables are not the opaque epoch accepted by `physics.submit`.

`pending` can contain partial records, or all four while awaiting the later clock.
`observed` requires all four and a qualified native epoch later than every record.
It does **not** require matching transforms or a pending-bit transition.
`expired` means the fixed deadline was reached; `invalidated` means the pending
probe lost its qualified context, including body retirement/VM cleanup.
Both can retain partial records. Neither API refusal nor a nonzero counter is a
separate status. Zero counters do not establish complete callback coverage.

Absent entries contain only `present=false`. Present entries additionally contain:

| Record field | Shape / meaning |
| --- | --- |
| `pending_before`, `pending_after` | Boolean snapshots of the native pending bit around the original call |
| `before_flags`, `after_flags` | Copied uint32 flag words, represented as numbers |
| `supplied` | Flat, 1-based array of 16 copied transform numbers, including supplied padding words |
| `com_position`, `origin`, `local_com` | Luau vectors: incoming packet body's COM, recomposed origin and local COM |
| `rotation`, `local_rotation` | Four-number arrays; recomposed/local Hamilton XYZW rotations |
| `transform_matches` | Origin and nine basis components agree within 0.002 each; padding is not compared |
| `epoch` | Copied native clock metadata for that record |

Records 1..4 are fixed actor packet-array slots 0..3, not callback order or
anatomical names. Their transform and body-pose diagnostics describe the native
body supplied to that actor-packet call, **not the SDK-owned body passed to begin**.
The owned body qualifies the owner/world/actor/clock context. Record epochs do not
expose native actor-body identities. Each slot retains its first qualified record;
this is a bounded snapshot, not a full motion trace.

## Example: one explicit request, one poll per client tick

The body owner calls `start_probe(existing_body)` from its existing explicit
client action after obtaining a current same-VM body. Nothing starts on load.

```lua
local physics = reskate.world.physics
local requested, probe, last_result = false, nil, nil

local function start_probe(body)
    if requested then return false, "already requested" end
    requested = true
    local why
    probe, why = physics.begin_sync_probe(body)
    if not probe then reskate.log(tostring(why), "warn"); return false, why end
    return true
end

reskate.on("tick", function()
    if not probe then return end
    local result, why = physics.poll_sync_probe(probe)
    if not result then
        reskate.log("Probe unavailable: " .. tostring(why), "warn")
        probe = nil -- Stops this example's polling; does not cancel native work.
        return
    end
    last_result = result -- Copied diagnostics, including any partial records.
    if not result.terminal then return end
    reskate.log(result.status .. " mask=" .. tostring(result.observed_mask))
    for i, record in ipairs(result.records) do
        if record.present then
            reskate.log(tostring(i) .. " match=" .. tostring(record.transform_matches))
        end
    end
    probe = nil
end)
-- Wire start_probe(existing_body) into your existing explicit client action.
```

## Lifetime and limits of the evidence

A successful start replaces the shared record after its terminal state or deadline,
making its old token unavailable. Preserve results before another start. Terminal
polls return historical snapshots; they do not revalidate current actor/body state.
Body/VM cleanup invalidates a pending probe. Manage the body's lifecycle separately.

`observed`, pending bits, matching transforms and zero loss counts are passive
facts. They grant no actor/input lease, follow authority, command receipt or
native-consumption/retirement barrier. Editing result tables changes no native state.
A successful body `release` return is not a post-drain park witness; probe output
proves neither park, native destruction, allocation reuse nor safe follow handoff.

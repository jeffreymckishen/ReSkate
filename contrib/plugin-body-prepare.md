# Explicit native-body preparation

`reskate.world.physics.prepare()` lets a mod
request the generic producer setup before its first actual allocation attempt.
The API builds in normal full Release and passes its focused constructed tests.
Native readiness and a successful first mount remain unverified.

The call requires the existing `world.physics` permission and client phase. It
takes no arguments, including no owner, body definition, handle, callback or
proof. Permission/phase/arity errors use the ordinary Lua API error behavior.
Every VM may attempt it at most once per actual plugin tick. Pending, unavailable
and ready calls all consume the attempt. A second well-formed call that tick
returns `false, reason` without reaching the native service.

```lua
local ready, why = reskate.world.physics.prepare()
-- ready is a boolean, never a body, probe, claim or native identity.
```

`true` means the existing body producer is marked hooked and the call could
freshly capture the local client/world chain and a matching qualified 60 Hz
clock. It is a sampled prerequisite, not a reserved allocation, capacity promise,
native callback-consumption witness, follow admission or gameplay completion.
Slots can still be exhausted, a prior partial allocation can prohibit another,
or state can change before the later explicit `create` call.

`false, reason` reports one of these native readiness results:

| Reason | Meaning |
| --- | --- |
| `native body producer setup pending; call prepare again explicitly` | The cold call queued only the existing deferred process-lifetime initializer flag. |
| `waiting for a fresh qualified 60 Hz physics step` | The producer is marked hooked but current actor/world/clock capture is unavailable. |
| `native body ABI or producer hook unavailable; another producer may own it` | The existing one-shot initializer was already attempted and the producer is unavailable. The API does not retry or bypass it. |
| `owned bodies require the current local client phase outside multiplayer` | SDK client readiness is ineligible, stale, from another thread or multiplayer. |
| `native body preparation failed closed` | An exception was refused without constructing a body request. |

The Lua quota has its own `asked to prepare native bodies more than once in one
tick` reason. An unavailable Game façade retains its ordinary unavailable reason.

Cold preparation uses the same existing eligible/local-only setup gate as cold
`create`. It retains no plugin owner, definition, position, pending allocation or
slot. Only the existing later `owned_bodies::tick` may run the initializer, outside
the plugin VM budget and service lock. An ineligible tick drops the request; a
later return to eligibility does not requeue it. The request does not register a
new hook, skip prefix/build checks, change an RVA or retry a failed initializer.
An already warm read-only motion clock alone does not prepare the body producer.

The warm path reads only `capture` and `clock`. It does not reconcile SDK worlds,
retire existing slots, release/park a body, change a mailbox, reserve a generation,
call a native body/shape allocator, set transforms or apply forces. Diagnostics
and fixed stack copies are ordinary SDK/VM values, not native body allocations.
The existing `create` implementation and its cold behavior remain unchanged.

A one-shot body trial should have an explicit preparation stage, wait for a
later fresh eligible tick after a pending result, and separately call `prepare`
again under its own bounded policy. A fresh `true` can permit its single explicit
`create` attempt. That attempt remains exactly one; do not use failed `create`
calls as readiness probes, replay a retained definition or silently retry a
native allocation. The API performs no retries for the caller.

The actual Host fixture checks missing permissions, server side,
argument rejection, per-tick quota charging/reset, explicit pending/ready/refused
results, independent VMs and reload without body side effects. Its native leaves
are constructed and cannot prove the real initializer worked.

The World fixture calls the actual native-service source over existing
constructed arrays/TLS, clock and counted ABI leaves. It checks flag-only cold
requests with zero attempted slots/native mutator calls, the existing deferred
initializer's fail-closed outside-lock path, warm capture/clock and foreign-phase
refusals, and unchanged pre-existing slot/world/mailbox state. Its seeded hooked
state is not a retail hook installation witness.

## Validation checkpoint — 2026-10-24

The normal full Release build passed with `/W4 /WX` on `5769d6a6` plus the
twelve-path API promotion. The focused CTest selection passed 6/6:
`server_plugins`, `owned_body`, `actor_control`, `body_follow`,
`owned_body_source` and `plugins`. Fifteen absent optional sample mods were
skipped. [Saved commands, source pins, output hashes and test logs](../build/bmx/body-prepare-api-integration-v1/checkpoint-review-prep-v1/execution-receipt.json)
identify that source composition; the later documentation update changes no code.

The Host prepare fixture ran six groups / nine constructed scenarios. The World
source target ran 23 cases / 587 checks, including four new prepare cases, with
zero native mutations. These results cover the API contract and constructed
native prerequisites. They do not show a retail initializer, body allocation or
rider following working in Skate.

The built runtime is `B812D53D` and the launcher is `9191A1C5`; full hashes are in
the execution receipt. That pair was not deployed or loaded for this checkpoint.
The separate Luau trial's Host validation is not part of this six-test result.

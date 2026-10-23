# Explicit stock equipment adapter

The source entry connects menu-driven stock board/on-foot transitions to the
existing **BMX Lua migration** page. Actual Host verification and a native
trial of this adapter are pending. It does not make
the bike rideable, activate the force/trick model, or qualify riding feel.

The page offers four explicit XInput slot choices, 0 through 3. One click arms
one stock toggle; the adapter waits for the menu to close and qualifies its
sampled baseline before making at most one `reskate.input.pulse(slot, "y")`
request. A refused or uncertain call is not retried. An active or unresolved
request blocks another. A slot is an observed XInput stream, not a physical
controller identity, and the aggregate `input.gamepad()` inspector cannot
identify which slot to choose.

There is no automatic bike activation or physical LB+Y binding in this slice.
The pure gesture mapper remains separate from this explicit menu path. Buttons
must check the adapter's own request result: the fourth `ui:button` argument is
presentation styling, not an enabled/disabled security gate.

## Integration boundary

The package needs `input`, `input.control`, `skater.read`, `menu` and `storage`.
It does not require camera, body/force or `skater.control` permissions for this
report transport. Missing permissions must remain visible refusals, with no
fallback actuator.

The adapter interface is `require("./equipment_runtime").new(services?)`,
`:request(slot)`, `:update()`, `:status()` and `:unload()`. Request returns an
accepted flag and detail; update/status return copied status fields. Constructing
the module or adapter does not arm a request. Run update on every client tick,
before the controller inspector's `observing` early return: stopping that
inspector must not stop receipt polling, cancellation or cleanup bookkeeping.
Menu callbacks should only make explicit requests and display bounded status.

Read-only context comes from `input.focus()`, `skater.get()`,
`skater.telemetry()` and `level.current()`. Level name and sampled local presence
can establish an observed continuity boundary; they do not identify a native
actor allocation, physical controller or unobserved same-name reload. The SDK
repeats its own authoritative owner/world/lifetime/input guards.

## Separate report and observation facts

Keep the full receipt's status, reason, first-rejection mask/stage and counters.
A published state buffer does not prove a normal wrapper return, native input
consumption, animation or semantic completion. Cleanup requires the SDK's
terminal, debt-free, unquarantined receipt with a released claim; a terminal
status alone does not authorize acknowledgement.

After storing the terminal receipt and receiving acknowledgement, the Lua
policy can qualify a fresh expected-state suffix. A clean revoked report with
nonzero press and neutral publications may precede that sampled transition;
it must still be displayed as revoked, independently of the observation.
Historical qualification is not current readiness after a context change.

Display stock state 100 as an observed stock board state, qualified standing
state 504 as observed on-foot, and intermediate, fallen or unknown states
explicitly. Never label any of these observations “bike mounted” or “BMX
rideable.” Even an uninterrupted sampled suffix can miss events between ticks
and cannot establish that the report caused the transition.

## Storage and unload

The adapter keeps bounded terminal/progress snapshots in the plugin's storage.
`reskate.storage.set` succeeds with zero return values after accepting the value
into the Host's VM cache and checking quota. It does not synchronously flush the
file or prove disk durability. Host periodic saves and unload perform the file
write; write failures are separately logged. “Stored before acknowledgement”
therefore means accepted into that cache, not a durable transaction with the SDK.
Storage failure must prevent acknowledgement or a claim of saved evidence.

Call `unload()` from the plugin's unload handler. It may attempt cancellation
once for a known, unacknowledged handle; it must never acknowledge pending duty
or claim rollback. The SDK's mandatory VM-close `release_all` still owns stopping
future assertions and retaining unresolved report-publication cleanup duty.
Losing focus, unloading Lua or losing an actor does not prove a cached report
was released. Retained orphan duty can block another VM's request. A reloaded
plugin receives a new VM identity and cannot recover authority by replaying a
stored sequence or old handle.

## Required verification

Load the actual entry and modules through the Host with the declared
permissions, then verify inert load/ticks/menu, all four explicit slot buttons,
no request while the menu is open, and no repeated request while busy. Exercise
permission refusal before backend calls, sampled context loss, clean/revoked
receipt classification, storage failure before acknowledgement, and unload with
both acknowledged and retained duty. FakeGame receipts and context are
constructed facts; these checks cannot qualify the native actor/input guards.
Any later native trial needs its own exact build, source, receipt and observed
state evidence. No new native pass is claimed here.

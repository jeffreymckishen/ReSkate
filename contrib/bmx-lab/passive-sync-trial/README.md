# Passive synchronizer diagnostic

This Lua mod creates one owned context capsule and reads one bounded passive
actor-packet observation. It publishes no force, pose, follow, controller, or
recovery request. It is a diagnostic, not a playable bike or a consumption proof.

The main entry and manifest are exact copies of the independently reviewed
source proposal v2: main SHA256
`5B3EDF61DAFF904F0B51C14E9221DBCA027785C2D00FEE7D6519AD1C089D3EF6`,
manifest SHA256
`8D656AE763971FF9C2AEBFC16F4B225394B6169D2383B29D77AC0D8D1258CB6D`.
The package is inactive unless the user enables it. Loading and viewing the page
remain inert. Each trial requires fresh storage and one explicit Arm action.

The page is `Passive Sync Probe V1`; its package label is
`LuaPassiveSyncProbe_20261023_v1`, run label
`b70cbb1f-e024-4603-bb1a-0ab3ff5dd1c4`, and storage key
`passive_sync_native_v1`. These labels identify a diagnostic; they grant no native
authority. Existing storage or a refused storage read prevents trial admission.

Arm permits 120 seconds to close the menu in focused gameplay with a finite
current actor and level. A 12 kg capsule is requested 2.5 m horizontally from
the actor and 1 m up. A stationary actor, neutral controls and a clear safe
placement are experiment preconditions; this script does not measure them.
One exact known preallocation refusal permits a separate explicit retry before
the original deadline. A second exact refusal ends with known no-allocation.
Other creation refusals retain allocation uncertainty and never retry.

One measured read precedes one passive probe. The SDK retains its fixed 1-second
observer limit; the Lua delivery watchdog is 1.5 seconds, total body window
3 seconds, and polls are at most 16 and at least 100 ms apart. Context loss or
an explicit Stop ends the trial. One known body gets one release attempt.
Release acceptance does not prove parking, destruction, or command consumption.
A refused release remains cleanup-unknown; no retry clears that debt.

The normal plugin-test group requires this source folder and exercises the real
Host, resolver, VM, UI limits, permissions and storage using explicitly constructed
FakeGame facts. Its fault-only storage test wraps the exact body in a module and
replaces only storage.set to throw; it does not claim the global entry unchanged
in that fault case. Host success cannot establish retail callback behavior or
BMX Streets likeness. Native/game execution requires separate recorded evidence.

On 2026-10-24 the Release plugin-test target built cleanly after correcting a
test-helper const mismatch. The complete CTest plugins suite passed, including
these 15 constructed Host cases; 15 unrelated optional fixtures were absent.
No native/game result is established by that test run.

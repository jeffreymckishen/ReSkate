# Private floor spawn and provisional Follow offset

`bike_spawn.lua` keeps `local FLOOR_SPAWN_QUALIFIED=false`, and
`bike_runtime_core.lua` keeps `local M1_PROVISIONAL_FOLLOW_OFFSET=false`.
There is no menu, storage value or option that enables either. With both off,
the actor +3 m / +0.5 m airborne placement, heading, reserve offset `-G.com`, API
calls, readiness retry and diagnostics retain the tracked defaults. LUA-5(a)
must not ship active without at least LUA-5(b-prov). M1 and P2 keep the airborne
spawn. A reviewed M3 trial substitutes both literals and grants the existing
`world.raycast` permission; neither is a game verdict.

The M1 steering removes the approach displacement and supplies a provisional
pelvis target. It does not establish a fitted rider pose or every Follow motion
case. The M1 page's strict first-500-ms position rule did not pass; the coordinator
judged the rows as demonstrating following with an approach swing and a floor
height constraint. This trial must still be confirmed in game.

## Floor placement

After mesh bounds are ready and before initial visuals or `physics.create`, the
floor trial feature-detects `world.raycast` and sends one vertical ray at the
reported rider X/Z, from actor Y +0.5 m to actor Y -3 m. A hit above the actor or
more than 2 m below is refused, as are invalid geometry, off-segment results,
API errors and a missing API. There is no second ray, fallback floor or automatic
retry. The SDK returns nil for both miss and unavailable, including some native
budget refusals; the stop text preserves that ambiguity.

The trial places the body-frame origin directly under the reported rider, 2 cm
above the returned hit. Authored wheel bottoms sit about 0.053 mm below that
origin and remain above the sampled height. `Visual.definition` adds the rotated
COM; subtracting COM from the floor root would sink the wheels. The existing yaw
quaternion is retained: SDK heading zero faces +Z, so bike +Z points along
`(sin(heading),0,cos(heading))`, including quarter turns and wrapped headings.
There is no 90-degree compensation. The original 3 m displacement was lateral,
not the definition of heading.

`Runtime:floor_height()` returns the height of the hit the trial accepted and
placed the bike on, and nil otherwise (the airborne path, or a refused, missed or
cancelled ray). It stays known after a stop. It is the only floor the rider's
dropped board uses (`board_drop.lua`, MOUNTED_POSE.md); nothing else is inferred
from it.

A hit older than 100 ms of Lua wall time before creation ends the attempt and
removes visuals without resampling. Phase/age checks after entity callbacks
prevent a cancelled or expired attempt from reopening or allocating. This local
bound is not an allocation pin or a native freshness guarantee. A consumed floor
trial closes on a clock-readiness refusal and does not advertise or accept the
airborne path's separate retry.

This is authored clearance relative to a returned point, not qualified floor
identity, a surface plane or the ground under both wheel locations. The native
ray allows up to 25 mm of hit/segment disagreement; it cannot establish native
accuracy within 2 cm, moving-floor stability or slope fit. M1's support finding
applies to that recorded native run, not every future placement. P1's qualified
camera plus named-category query uses `physics.probe_batch(body, measured_epoch,
...)`, which cannot run before the first body exists. This ray is not that P1
qualification.

## Provisional attachment

The independent Core trial literal changes only `offset_from_com`. For authored
body-frame pelvis `P=(0,.95,-.10)`, reserve uses `P-G.com=(0,.05,-.05)`.
The false branch still constructs exact `-G.com`. `root_in_body` remains identity;
`cleanup="owned_body"` and `motion_policy="callback_entry"` are unchanged.
No Follow lease, renewal, lifetime, permission or command authority is added.
This M1-derived provisional target still needs a short native confirmation.

Core reads Spawn's private literal through `floor_spawn_qualified()` when it
prepares the backend. Only the floor trial with an available SDK function gets
a `world.raycast` proxy. It accounts for the one call in Core's ledger, refuses
repeat or cancelled calls, checks cancellation after the callback, and preserves
the returned value count. The default proxy gains no function and makes no extra
SDK calls. The provisional attachment literal does not control this forwarding.

The tracked manifest remains unchanged and lacks `world.raycast`. The
coordinator-owned trial must grant that existing permission before activation;
no fallback bypasses it. No game or controller was launched for this source fix.

## Pure checks

`bike_spawn_floor_tests.lua` checks default and trial placement, heading, valid
bounds, miss/unavailable/refused/malformed/too-low/above-actor results, missing
API, one attempt, callback cancellation/reentry, hit age and preallocation refusal.
`core_provisional_follow_tests.lua` uses the real public Core mount and Source
with the existing staging suite's shared constructed service factory and a fake
Spawn. It captures the actual reserve attachment, then returns a known refusal:
no Follow or force is published. Both literal branches check exact offsets and
unchanged attachment policy. This is fixture behavior, not native ownership.

The `core_floor_spawn_*_tests.lua` suites drive the real public Core mount,
Source and Spawn with both literals off and on. They check proxy presence,
mixed gates, exact placement and reserve offset, call accounting and order,
missing API, callback failure, cancellation/reentry, and cleanup. Their shared
fixture temporarily selects the existing generated Spawn's real exports while
Core prepares its backend, then restores them on success or failure. The actual
Spawn instance retains its module's literal; no fake Spawn is used. The runner
needs no change because these suites import its existing generated module names.

The standalone runner makes each private module copy with exactly one literal
substitution, registers the suites in CTest, and checks exact copied bytes,
manifest ownership, reruns and true/duplicate/planted-gate refusals. Production
source stays false; existing suite case/assertion pins remain unchanged.
Pure success verifies no SDK permission, native placement/support, Follow motion,
lifetime, rider pose or gameplay result.

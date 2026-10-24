# BMX as a Luau mod

The October 22 maintainer direction, confirmed by the user, applies to **all**
BMX functionality. The final implementation is a mod using ReSkate's Luau API.
This supersedes the earlier plan to keep a BMX-specific C++ controller as the
ordinary implementation. Existing native trials remain useful comparison evidence;
they do not establish the intended architecture or BMX Streets parity.

The default runtime no longer dispatches the legacy C++ riding, chassis-probe
or ramp controllers, and its console no longer registers the legacy `bmx`
commands. This retirement requires a fresh process; it is not a live stop of an
already mounted bike. Preserved older DLLs remain historical comparison builds.
The current Lua package is still a migration in progress and cannot yet ride a
bike. New native trials must use the generic API.
The ordinary force policy passes portable regression comparisons. A reviewed
Lua optimization reduced offline actual-Host braking from about 17.2ms to 0.82ms;
default slope cases average about 1.79ms. The selected fixed-input windows passed
the normal rolling watchdog, but complete-adapter/native performance still needs
proof and optional 128 iterations remain unqualified. Gameplay stays inactive.

## Latest upstream inspected

Official `Dingo-Shenanigans/ReSkate` main was last fetched at
`194942779cdef48a3646aecdecfcd99ac966b39c` on October 23 and integrated on `BMX`
in two-parent merge `6aad1bed14c4f9c7373a272af31f134222f6dda6`, preserving both
histories. This follows the tested Lua spawn checkpoint `e3c6db54` below.

The earlier 17 commits from `e35e33d` through `7fa407a` were integrated in
`d6f1497`; its clean Release build and 39 focused CTests passed, with runtime and
launcher rebuilt together for protocol 54. The later server-documentation-only
commit was integrated separately as `8e0d5c8`.

These changes add shared plugin content, world-to-screen bounds validation,
server roles/cards/polls and other server/launcher improvements. They do not
add a rider-to-owned-body follow API. Earlier carried-object posing and camera
cycle APIs remain useful presentation tools; the camera cycle is an enter/exit
event, not a callback at the render handoff.

The first merged-build stock mount reached the board, but its input receipt
was revoked after publication when the profile Try-lock was unavailable.
`ae81c79` moved queued-teleport observation to its own narrow Try-lock and
bracketed native dispatch. Its clean Release build and 41 focused tests passed.
One fresh in-game forward stock mount then recorded `released / none`, zero
rejection mask, cleared report debt and a 2.5-second qualified board suffix;
the endpoint image shows an upright rider on the board. The earlier actual
lock holder and native contention were not observed, so this one regression
does not establish broad switching reliability or prove the causal fix under
contention. The [checkpoint](judging/checkpoints/2026-10-23-lua-stock-switching.md)
keeps the raw transport, sampled endpoint and later shutdown invalidation separate.
Neither stock mount is a BMX switch or mounted-bike test.

During ongoing work, refresh both `origin` and `upstream` at least hourly and
before another Lua API expansion. Fetch and inspect first, then integrate at a
clean focused checkpoint on `BMX`. Preserve local work and both histories; do
not reset, discard, automatically stash, push or merge into an active game/build.
Rebuild affected binaries and tests, and reconcile their identity before using
new game evidence. Inspection of the current API must precede implementation;
older recovered method offsets are not contracts for the installed Streets build.

## Current Lua bike checkpoint

`334c9c98` added an explicit unmounted Lua bike/chassis diagnostic. `e3c6db54`
replaced its global asset catalog scan with one exact mesh-bounds lookup per
tick, retaining all eight parts, the original total deadline and separate
preallocation retry. Its integrated Release build and plugin suite passed;
the actual Host case passed 21 scenarios and 2048 authored/COM comparisons with
zero driving calls. The earlier 50 ms math-fixture failure remains archived;
the unchanged rerun passed without increasing budgets.

The earlier `BMX_LuaSpawn_20261023_v2` game trial confirmed a recognizable
Lua-driven bike portion rendered at the left edge of the scene. It was clipped
and elevated; a later image shows no bike there. This is native visual progress,
not a verified eight-part render, successful chassis creation or a mounted ride.
All eight bounds calls have before/after markers. Create's log bracket spans
71 ms, followed by removal and the unchanged 50 ms tick watchdog. Its return
arity/value/reason was not retained; the last stored marker is before remove3.
Body success, native measurements and cleanup remain unknown. Normal shutdown
and subsequent manifest withdrawal recorded zero processes and active Lua manifests.

This trial used runtime `DEB56DE0` and launcher `81B0D462`; keep it separate from
the clean stock forward regression on runtime `9005C913` / launcher `7E506E09`.
The [checkpoint](judging/checkpoints/2026-10-23-lua-stock-switching.md#lua-bike-visual-checkpoint)
pins both builds, raw C:/E: evidence and the independent native outcome audit.
No riding, tricks, rider alignment, fall recovery or 9.5 likeness is established.

The fourteen-path generic contact measurement checkpoint `2a98eb9c` passed
Release, all 43 focused CTests (15.54 s), and the separate server configuration
test (0.47 s) on its first build/test attempt. Its `5CC87656` runtime and
`D149BD35` launcher were not deployed for that earlier visual trial. Native
contact measurements, positive actor exclusion and wheel-force composition
remain unqualified.

`43e6d1ef` then moved requested first-use generic producer setup outside the Lua
callback and service lock, retaining the original readiness and VM limits.
Full Release, six focused CTests and the plugin suite passed on the first attempt:
11 Service cases/274 checks and 22 Host scenarios/2048 comparisons, with zero
native mutations in the Service fixture and zero driving calls in the Host fixture.

The fresh `BMX_LuaSpawn_20261023_v3` native diagnostic used runtime `7F33A210`
and launcher `D149BD35`. Its first create returned the exact preallocation
readiness refusal; one separate explicit retry returned a body userdata. Lua
adopted 143 advancing measured chassis samples and submitted all eight visual
transforms for each before the two-metre envelope closed the diagnostic. The
release API returned true and the adapter recorded `cleanup_unknown=false`.
No 50 ms watchdog or plugin-budget error appears in this v3 runtime log.

This proves a bounded native chassis observation milestone through the Lua API.
The count records adopted measurements and accepted visual submissions, not 143
archived snapshots or all-eight-part rendering. Release acceptance is not a later
native parking, destruction or reuse witness. The [checkpoint](judging/checkpoints/2026-10-23-lua-stock-switching.md#native-chassis-after-deferred-setup)
pins the fresh identity, result arities and raw C:/E: evidence. The earlier v2
failure remains archived; its cause and cleanup are not resolved retrospectively.
Mounted riding, rider alignment, contacts, forces, tricks, fall recovery and the
requested 9.5 likeness remain unqualified.

The later owned-self-ray native check returned three world hits at one capsule
placement, with owned bodies excluded and the complete before/after body sample
unchanged. Requested local-actor exclusion still refused before any cast. This
does not qualify actor-safe wheel contacts, contact normals, forces or riding.
The [bounded ray result](judging/checkpoints/2026-10-23-lua-stock-switching.md#owned-self-ray-native-check)
retains its one explicit readiness retry and proof limits.

The general permissioned Lua input lease/capture expansion passed full Release
and 105 focused CTests on its first composed attempt; fifteen optional plugin
fixtures were absent. The later bounded native trial failed before capture:
its observation lease was revoked for `interference` before any admitted fresh
sample. A separately admitted controller run completed 301 neutral reports;
that does not prove capture or native consumption. The [native refusal](judging/checkpoints/2026-10-23-lua-stock-switching.md#native-input-capture-refusal)
retains both attempts, known cleanup and the unproved cause.

Generic passive synchronization observation is committed as `5e0c732`; its
corrected full Release and 105 selected CTests passed after an initial
test-fixture link failure. A separate eleven-path Lua input composition passed
the normal Host suite in 5.22 seconds, checking inert imports and construction.
Neither result qualifies native rider attachment or activates riding. Actual
force-stop, rider-follow and parking providers remain unbound, and actor-safe
wheel contacts remain unavailable. The [source checkpoints](judging/checkpoints/2026-10-23-lua-stock-switching.md#passive-observer-and-lua-input-composition)
keep these offline results separate from gameplay. Mounted switching, alignment,
fall recovery and the requested likeness remain unfinished.

The [general input API guide](../plugin-input-lease.md) describes the new
permissions, source identity, capture and cleanup contracts. Preserve existing
scripting behavior; add only the API bindings and general native support
required by the Lua mod.

## Where the implementation belongs

| Function | Luau mod | Generic SDK support |
|---|---|---|
| Controls | Device rearm, hop gesture, steering, manual and trick selection | Original input snapshot, source identity and owner-scoped input lease |
| Riding | Bike/rider parameters, wheel geometry, steering/hop/pump/brake/contact policy | Owned dynamic bodies, measured state, bounded collision queries and native force submission |
| Tricks | Catalog, progress, catch, landing and combo state | Observed body orientation and command receipts |
| Appearance | Bike part transforms, grips/pedals, posture, IK targets, contact decisions | Owned entities, animation/pose/reach/carry primitives and publication receipts |
| Equipment | Bike/board/park/carry states, shortcut timing, cancellation and recovery sequencing | Typed native actor actions with observed completion and exclusive movement/pose/input leases |
| Tools | Settings, diagnostics, recordings and camera UI | Existing sandboxed menu, storage, events and camera APIs |

No `reskate.bmx.*` facade should call the old controller, console commands or
feature-specific native routines. Moving a C++ mode behind one Lua function
would leave its policy in the SDK and would not satisfy this migration.

The SDK may implement reusable native mechanics and numerical primitives. It
must not contain BMX gestures, dimensions, steering curves, trick names, rider
postures, equipment policy or special BMX profile selectors. Bike assets and
parameters belong to the mod package; no extracted game content enters Git.

## Generic API contracts and remaining gaps

The existing API already offers gamepad input, bindings, input hiding, owned
visual entities, raycasts, local pose/reach/carry, board presentation, cameras,
menus and skater physics events. These contracts determine whether a Lua mod can
replace the physical prototype; implemented contracts still require native proof:

1. **Owned bodies.** Create/configure an authorized body with plugin-supplied
   mass, inertia and bounded collision shapes. Return opaque handles scoped to
   the plugin and world generation. Read actual position, orientation, linear
   and angular velocity, native step serial/time and validity. Never expose
   pointers or permit foreign/stock actor mutation through an object handle.
   The experimental `world.physics` implementation now supplies this contract
   with permission and ownership tests. A [native one-body trial](luau-native-body-trial.md)
   now proves one 12kg capsule and one48Ns impulse/application/successor/park
   sequence after explicit clock warmup. A [second native diagnostic](native-pipeline-trial/README.md)
   completed 120 consecutive constant-force commands and measured acknowledgements.
   A [varying-force diagnostic](native-phase-trial/README.md) independently
   identified N+2 measured velocity visibility for commands requested at N and
   applied at N+1; its internal consumption/publication cause remains unknown.
   Other compounds, whole-session control and cleanup of an active body during
   unload, world changes or partial failures remain unqualified in the game.
2. **Contacts.** Return the actual hit point, normal, surface velocity when
   available, feature, ignored-owned-body status and world/step provenance.
   Existing raycasts do not expose enough information to implement wheel forces;
   a missing normal or velocity cannot be silently replaced by an invented one.
   [Owned-body batch contracts](../plugin-body-query.md) have portable tests for
   complete-sample fences, same-VM owned exclusions and shared actual-cast accounting. Their
   first native query-plus-force attempt refused its first query with zero
   reported casts and zero published packets, then accepted release. Native
   query composition remains unqualified. A second native trial localized the
   refusal to `local_actor_exclusion_unavailable`. Static inspection also proved
   the placement resolver expects a packed entity key, while the actor anchor
   holds a raw pointer. That invalid lookup is removed; requested actor exclusion
   remains unavailable pending a verified conversion and exclusion domain.
   Native ray hits were also confirmed to be shape handles, not rigid-body
   handles, and the ignored-ID list compares native owner indices. Owned capsules
   have no native owner; body or shape IDs cannot implement that exclusion.
   The incorrect native batch path was removed in `4222ecf`. Its replacement
   queries with no native ignored IDs or owner lookup, qualifies the actual
   nearest hit's current shape-to-body association, and refuses the whole batch
   for excluded or unknown identity. Every returned pair is rechecked. Native
   validation now includes one [two-hit native geometry batch](native-geometry-trial/README.md)
   with actor exclusion explicitly false, no submitted force commands and an
   unchanged full body sample. Broad native self-hit rejection and contact/force
   composition remain unqualified; actor exclusion remains unavailable. The later
   three-ray result above qualifies one capsule placement only.
   Vehicle queries must retain actor exclusion and the observation checks.
3. **Commands and receipts.** Queue finite bounded force, torque and one-shot
   impulse against an exact observed body epoch. Commit once in the supported
   native phase, then expose applied/rejected/expired and the actual successor.
   A queue acknowledgement is not a completed native application.
   The generic implementation now separates one immutable pending command from
   four retained receipt records, allowing consecutive publications while older
   commands await their first independently measured successor. Contract tests
   pass. One native trial has now demonstrated a 120-command burst at the qualified
   60Hz clock; sustained riding with the BMX controller remains unqualified.
4. **Actor ownership and actions.** Obtain and release exclusive movement,
   pose and input ownership together. Bind the local actor to an owned body
   through generic transform/pose primitives. Typed board/on-foot/GetUp actions
   need observed completion, cancellation and owner identity; a timer or a
   copied animation alone cannot establish a completed equipment transition.
5. **Input identity.** The new permissioned input lease/capture API observes an
   original selected XInput stream with an opaque source epoch, fresh-observation
   ordinals and renewable ownership. Capture waits for a later raw-neutral
   observation and retains cleanup duties until a qualified neutral handoff.
   Build and regression tests passed; the native trial stopped at observation
   lease revocation, before any fresh sample or capture. Successful native
   capture/release remains unqualified.
   This input source is not physical-device, actor or body authority; the Lua
   mod must join the actual independent ownership and body observations.

Permissions and limits belong at each API boundary. Existing single supported
game hashes, per-build address/fingerprint headers, paid-content restrictions,
No Bail priority, foreground/menu ownership and unload cleanup remain enforced.

## Timing and migration order

Luau runs in the plugin host's supported client phase. `events.physics` delivers
retrospective skater observations, buffered up to 512 steps; it is not permission
to execute a script on the physics or render thread. The native adapter commits
only current qualified commands. Gaps, stale epochs and missing receipts must
be visible and stop control; the mod must not replay an old impulse or integrate
an assumed native result to conceal a missing application.

First port the actual portable input/catalog/trick/controller policies into Lua
and exercise them against the retained C++ baseline. In parallel, implement and
review the generic body/contact/command contract. Then wire those Lua modules to
real owned bodies, followed by rider presentation and the complete equipment and
fall lifecycle. The legacy BMX dispatcher is already retired, so keep the new
gameplay entry inactive until these native bridges are qualified. Keeping
historical source during this process is not approval to add more BMX policy to C++.

Current human feedback identifies **hops and turning** as the main feel problem.
The recorded ReSkate test contains full-strength hops and repeated tilted frame
contacts. Mixed inputs do not isolate a steering or damping defect. Reuse that
recording for comparison, then test neutral hops, held-turn hops and intentional
air rotation separately in the Lua controller. Do not raise bail thresholds or
guess extra hop force from a successful scripted fixture.

## Acceptance

The replacement must launch as an ordinary sandboxed mod with the legacy BMX
runtime disabled. Verify actual native body/command ownership, unload and world
changes, steady riding/turning, hop/trick/landing behavior, rendered hands/feet,
repeated board round trips and controller fall/GetUp/remount continuity. Compare
continuous gameplay with the current Streets reference with assists off. Pure
tests, source ports and engineering review scores do not establish likeness.
The requested 9.5 likeness and full parity remain unachieved.

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
The ordinary force policy now passes portable regression comparisons, but an
actual-Host benchmark exposes a normal 2ms budget failure under strong braking.
Optimization and repeat performance evidence are required before activation.

## Latest upstream inspected

Official `Dingo-Shenanigans/ReSkate` main is
`35824f4d1c1380a7e36f8dbedcaeba9866f32cc6`, eight commits after `45346b1`.
Commit `118c489f` adds generic carried-object posing, pose/reach visibility and a
plugin entry in the camera-height-button cycle. It also extends board visibility.
The camera cycle is an enter/exit event, not a callback at the render handoff.
Other changes include dedicated-server park APIs and launcher changes.

These additions help with carrying, rider presentation and camera policy. They
do not provide an owned dynamic-body/force API. Inspection of the current API
must precede implementation; older recovered method offsets are not contracts
for the currently installed Streets build.

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
   Other compounds, whole-session control and cleanup of an active body during
   unload, world changes or partial failures remain unqualified in the game.
2. **Contacts.** Return the actual hit point, normal, surface velocity when
   available, feature, ignored-owned-body status and world/step provenance.
   Existing raycasts do not expose enough information to implement wheel forces;
   a missing normal or velocity cannot be silently replaced by an invented one.
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
5. **Input identity.** Include a source/device epoch. The current gamepad API
   does not establish replacement identity for a held gesture. Extend ownership
   beyond camera-only capture without coupling a vehicle mod to a free camera.

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

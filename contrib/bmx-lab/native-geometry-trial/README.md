# Native owned-body geometry diagnostic

This inert Luau mod creates one 12 kg capsule, requests one expected actor-exclusion
refusal, then queries two downward four-metre segments with actor exclusion
explicitly false. Both must return actual qualified world hits. It submits no
force commands and takes no rider, camera or controller ownership.

Copy this folder into an isolated installation's `Mods` using a fresh diagnostic
folder name. Open **Owned Geometry Trial**, explicitly Start, then close the menu
with gameplay focused. Only the exact pre-allocation clock-warmup refusal offers
another explicit Start. Existing saved results prevent another run. The storage
namespace is `%LOCALAPPDATA%/ReSkate/Plugins/<mod-folder-name>/storage.json`,
independent of the game's profile. Use a fresh mod identity for another trial.

The body starts two metres horizontally ahead of the actor and 1.5 metres above
the actor position. Rays run on either side, 0.35 metres from the capsule centre.
Both need at least one metre of horizontal actor clearance before and after the
query. Arming expires after 120 seconds; an allocated body has a six-second wall
watchdog. Focus/menu loss, changed body samples or unavailable geometry stops the
trial. An accepted release parks a retained allocation; it does not destroy it.

The ledger records complete body samples, request segments, returned fractions,
positions, actual cast counts, body/normal/velocity presence flags, actor positions
and release. A successful batch requires unchanged serial, native time, duration, mass, inertia,
position, quaternion and velocities, including signed zero in the live comparison.
The reported native step is checked against 1/60 second. Hit positions must match
their measured segment/fraction within 25 mm on each coordinate. Logs contain a
short result; inspect the persisted ledger before accepting the run.

## Verified native result

On 2026-10-23, one isolated run refused creation during clock warmup, then accepted
one explicit retry. The actor-exclusion request refused with
`local_actor_exclusion_unavailable`, zero actual casts and no geometry. The next
batch, with actor exclusion explicitly false, returned two actual surface hits
from two native casts. Their fractions were approximately 0.615540 and 0.610172.
The complete published body sample was unchanged at serial 2006, mass 12 kg and
native duration `0.01666666567325592` seconds. No force command was submitted.
Release was accepted; the manifest was then withdrawn and the watcher unloaded
the VM. Skate exited normally, with the exact trial PID and executable path
subsequently absent from a successful process query. The persisted ledger hash
was unchanged after unload and exit.

- Tested patch committed as `25913f2d653aaddaea8220ca9da3a172a9888886`; the
  compiler checkout was `5bd7fbe94659cc42d30d6d1ba3e950f6dbdcb605` plus that
  exact reviewed patch, whose SHA256 was
  `CF0C46184D46620AFDF04A50AA785EE40DE5DE68C7F6CEE9EF7CD7150F6476F6`.
- Runtime SHA256:
  `EB601CF97A0719FCC1F6159E5C9E50083AFB254D807BFFED34BA1C4474C63798`.
- This `plugin/main.lua` SHA256:
  `B61CD7DD3DD332E34B4E35D1D4069937EB6D920728BAD9C181DFCA0B00CBB2A7`.
- This manifest SHA256:
  `052D960A7267EC5D4280F101FFCEBDE58D908285E387B0655CEC7B87EFFD2C3B`.
- Native ledger SHA256:
  `43321384F9418CFD9B27E783B145C832AB7052E648BBF70AB96C6D9291417B1D`.
- Owned process: PID 49016, process-start FILETIME 134372183774689187.
  Executable and loaded-runtime paths plus disk hashes were checked; this was
  not a memory-image hash.

Private raw logs, source freezes, screenshot, ledger, process receipts and review
are under `build/bmx/lua-owned-geometry-native-trial-v1/`. The runtime passed seven
Release build targets and six focused CTest suites before the native trial.

This verifies one positive geometry batch. The rays miss the small owned capsule,
so they do not exercise native self-hit rejection. Native actor coverage remains
unavailable; the diagnostic's deliberate false option must not be adopted as a
rider-safe vehicle query. Both hit motions remain `unknown`; there is no normal,
surface velocity or opaque body token. Contact/force composition, moving surfaces,
active-body cleanup, switching, rider alignment, fall recovery and riding need
separate evidence. BMX Streets likeness remains unscored.

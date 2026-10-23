# First native Luau body trial

On 2026-10-23 UTC (2026-10-22 local), an ordinary sandboxed Lua plugin created and controlled one
physical capsule in the isolated supported Skate build. It used only the generic
`reskate.world.physics` API. The legacy BMX dispatcher and console were disabled,
and the riding force modules remained inactive.

## Provenance and method

- Source/runtime build: `f3880a287292fd71e2a6f2bfb0dbea22554f9918`.
- Runtime SHA256: `65EB08AFD7EEE43319161D59A40EC2F8D0588203DE6D43E4AB049171EA6870CF`.
- Fixture SHA256: `AC4711EF77F53B951F7A0B54EB3613BF54857E4DC2886227706850444C5509A1`.
- Exact owned process: PID 52116, GetProcessTimes FILETIME 134371982707182106.
  Executable path, supported executable hash and loaded runtime path were checked;
  disk hashes are not an in-memory image hash.
- The plugin was inert on load. An explicit menu action armed the test, and
  closing the menu in focused gameplay allowed the native request. UI arming had
  a separate 120-second deadline; the body had a six-second wall watchdog.
- One 12 kg body, principal inertia `(0.4, 0.1, 0.4)`, one capsule with endpoints
  `(0, -0.25, 0)` / `(0, 0.25, 0)` and radius 0.12 m. The requested spawn was two
  metres beside the current local actor and 1.5 m higher; the fixture checked the
  first measured position within 0.35 m of that request. These are test parameters,
  not bike tuning.
- The first create request refused before allocation while the guarded native
  clock warmed up. One later explicit request succeeded. No uncertain allocation
  or command was retried.

## Actual native observations

| Event | Observed result |
|---|---|
| Measured predecessor | Serial 3600, mass 12 kg, vertical velocity 0 m/s |
| One command | Upward impulse 48 Ns, event ID 1, accepted into the queue |
| Native application | Requested 3600, produced 3601, both setters returned, no quarantine |
| Independently measured successor | Serial 3602, vertical velocity 3.67333364 m/s |
| Acknowledgement | Accepted after the actual successor was available |
| Observation | Fixture counted 76 distinct observations; 19 sample rows logged; reported peak rose about 0.717 m |
| Release | Accepted; retained true, quarantined false; allocation parked, not destroyed |

The preceding 3601 sample had vertical velocity -0.163333327 m/s. With the
measured step of about 1/60 s, the successor is consistent with `48 / 12 = 4 m/s`
of impulse velocity and two gravity intervals of about -0.16333 m/s each
(about -9.8 m/s²). Later
samples show rising and falling motion. This result uses actual native ring
observations; the fixture does not integrate or reposition the body in Lua.

The body was released after about 1.25 native seconds from the predecessor. The
game then exited normally. Raw log, source, process metadata, completed-panel
image and build receipts are retained privately under
`build/bmx/lua-owned-body-native-trial-v2/`. No extracted game content is committed.

## Remaining qualification

This proves one capsule allocation and one impulse/application/successor/release
sequence. A [separate native diagnostic](native-pipeline-trial/README.md) subsequently
completed one 120-command constant-force burst with measured successors and ordered
acknowledgements. Whole-session control, torque, other body compounds, cleanup
of an active body during unload or world changes, and partial native failures
still need separate trials.
The overlay marked measured positions; it was not a rendered capsule mesh.
Controller consumption, rider binding, wheel contacts, bike/board switching,
fall recovery and BMX Streets likeness were not tested by this fixture.

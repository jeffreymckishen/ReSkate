# Measured-contact diagnostic

This explicitly started Lua mod checks three measured contacts at one capsule
placement. Loading only reads its prior ledger and registers the **Measured
contacts** page. It issues no force, torque, impulse, input, or rider commands.
The six manifest permissions cover physics, raycasts, skater and focus reads,
menu, and storage. Actor exclusion is always requested as false.

## Running a separately admitted game trial

Copy this complete folder to a fresh mod folder in an isolated supported ReSkate
installation. Preserve the source and manifest hashes in the trial record. With
the game focused at a roughly flat placement, open **Measured contacts**, press
**Start measured contacts**, then close the menu. Do not treat repeated menu
builds or loading as consent to create a body. A previous stored trial prevents
another start; preserve its storage namespace and use a fresh mod folder for a
separately admitted trial.

The diagnostic creates one 12 kg capsule two metres horizontally from the
observed actor and 1.5 metres above it. It reads a qualified body sample and
requests one three-ray batch with require_contact=true. The rays start inside
the capsule, above it through its centre, and 0.6 metres to the side. Accepted
contacts must be below the capsule bound; the first two points must agree within
25 mm and the adjacent height within 0.15 m. Those are checks on returned
measurements; the script never fabricates a floor or normal, flips a normal, or
assumes a zero surface velocity.

Only the exact preallocation refusal "waiting for a fresh qualified 60 Hz
physics step" permits one separately pressed readiness retry. Other exceptions
or missing handles retain allocation uncertainty and prohibit a retry. There
are at most two create calls and one query batch. Session watchdogs bound the
whole attempt to 120,000 ms or 36,000 callbacks; the allocated-body phase has
6,000 ms or 1,800 callbacks. Focus/menu changes with a body, changed samples,
unavailable or malformed measurements, or 0.35 m placement drift stop it.

## Evidence and cleanup

The stored measured_contact_trial_v1 report records actual requests, counts,
sample snapshots, normals, surface point velocities, availability flags,
placement checks, and failures. It keeps the original opaque epoch for the
query and checks exact numeric equality against a subsequent body read,
including zero signs. The two opaque epoch userdata are distinct. JSON numeric
arrays do not preserve zero signs; the recorded exact-comparison fact is
separate evidence.

Terminal state is set before one explicit release attempt and one storage
attempt. The finish log records storage queue acceptance, which does not prove
that storage.json reached disk. Inspect the actual per-mod persisted file after
normal unload and preserve save warnings. An accepted physics.release is a
release request accepted by the SDK; this diagnostic supplies no independent
native post-drain park, destruction, or reusable-capacity witness. The script's
release text must not be promoted to such proof. Failed/unknown outcomes remain
failed/unknown and never rearm.

The one-metre horizontal actor clearance check uses two observed endpoints.
It does not prove continuous clearance, complete rider/equipment exclusion,
static-world membership, all geometry support, or a mounted/drivable bicycle.
Even a successful native run demonstrates three contacts at one placement,
not BMX handling or likeness.

## Normal Host regression fixture

Extension/Plugins/Test/measured_contact_host_fixture.inc is registered in the
ordinary dingosdk_plugin_tests target and CTest plugins. It reads this exact
tracked manifest and complete entry as mandatory files; a missing fixture fails
instead of taking the optional contrib/plugins skip path.

The authored 20-case fixture uses the production Host, bindings, menus, logs,
JSON, and storage with a constructed Game. It covers 24/25 ASCII-byte page-title
limits, six isolated permission categories, sample/opaque-epoch/vector shape,
inert load and actual start timing, three measured contacts, persistence/reload,
preexisting ledger bytes, two unload states, the explicit readiness retry,
four contact failures, and quota/save failures. Constructed plane geometry and
nonzero point velocity test serialization and guards; they are not native
terrain evidence. Exact-entry denied-manifest variants and broad high-serial,
producer-advancement, and changed-zero-sign matrices remain outside this fixture.

On 2026-10-24 the Release dingosdk_plugin_tests target built cleanly and the
complete CTest plugins suite passed, including these 20 production Host cases
(15 unrelated optional plugin fixtures were absent). This validates constructed
Host behavior. A separately recorded game trial is still required; prior native
geometry tests do not qualify these measured fields.

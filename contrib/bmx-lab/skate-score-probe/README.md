# Skate score probe (developer calibration only)

Source for the separate L0/C0 skateboard scoring recorder. **C0 is UNKNOWN; this checkpoint has not been executed, built, tested, deployed or calibrated.** Keep this folder outside the BMX mod and its release package. The probe observes the existing SDK and writes only its own private plugin storage; it never changes game score, progression, challenges, labels, controls or physics.

The manifest requests exactly `events.tricks` and `storage`. The entry uses SDK event subscriptions, steady-clock time, JSON encoding, score reads and private storage. It needs no console, menu, input, skater-control, throwdown or network permission. No SDK code or host-pinned test suite is changed.

## Captured observations

- `trick_started`: occurrence only; no invented name/points or retained position.
- `trick_landed`: SDK `points`, `multiplier`, `name` and `ms` (watch-start to score-detection duration).
- `line_broken`: the SDK's reason text.
- `trick_notes`: flatten the actual `{notes = {{entry, kind, text}, ...}}` payload into bounded note rows. `entry` stays an opaque string.
- `score.current`: the six actual fields `line`, `multiplier`, `in_trick`, `trick`, `detail`, `manual`, recorded on observed change; nil is an unavailable snapshot, not zero.

The recorder timestamps delivery in SDK steady-clock milliseconds and gives rows sequence numbers. It samples current score on ticks; it does not observe every native write between SDK updates. See [the calibration ledger](../bmx-plugin/SKATE_SCORING.md) for exact source provenance, unsupported observations and all authored scoring defaults.

`trick_landed.points` is inferred by the SDK from HUD changes; it must not serve as independent proof of that same formula. The duration includes delayed score detection. The last HUD header may not uniquely identify a complete trick. The SDK supplies no explicit banked/stopped/timeout event, and its note buffer can drop entries before the probe sees them. C0 therefore needs external sequence timing/video/operator notes.

## Bounds and evidence handling

The collection limits are **AUTHORED instrumentation settings**, not measured game rules: at most 2,000 retained rows, 256 KiB (262,144 bytes) of compact serialized storage including the key/envelope, and bounded text of at most 160 UTF-8 bytes per field. The AUTHORED note limit is 32 rows per callback. Note-container validation accepts at most 256 entries, with a bounded extra-key check; an invalid/sparse/oversized container is refused with an unknown-loss diagnostic, rather than an invented dropped-note count. An interval above the AUTHORED 250 ms threshold between observed ticks adds a `probe.tick_gap` instrumentation row with the previous/current observation times and gap, plus summary counters. A conservative 240 KiB row-byte budget leaves room for metadata; the complete keyed JSON envelope is still checked against the hard 256 KiB limit before storage. A rolling buffer retains recent observations; discarded older observations must remain visible in counters. Malformed values, text changes, bounded-note losses, clock/timing gaps and storage errors limit the evidence. Zero recorder-side losses do not prove zero upstream losses.

The private storage key is `skate_score_probe_v1`. A new capture refuses existing nonnil data under this key or other existing plugin storage keys; it must not silently overwrite an earlier experiment. Storage snapshots are throttled to an AUTHORED 1,000 ms cadence, plus final unload handling. This is an in-memory SDK checkpoint, not a disk flush: `storage.set` only marks SDK storage dirty. The SDK writes its private storage on close/unload; file failures are reported to the SDK log, not synchronously returned by `storage.set`. A crash can lose the session. Verify the final file and logs after unloading before describing any capture as saved.

The byte limit is a serialized-data limit, not a claim about Luau heap usage or callback cost. Runtime cost and the final-unload budget remain UNRUN. The SDK's existing call/tick/unload limits stay intact. Do not raise them to obtain a passing calibration result.

## Future coordinator-owned capture

These are instructions for a later authorized execution slot, not actions performed by this source checkpoint.

1. Select the supported isolated game/profile and record exact SDK/probe source hashes. Keep the probe separate from the BMX mod and other trials. The coordinator must own the execution slot and honor both HID-HOLD locations.
2. Confirm this probe's private storage is fresh. If it already exists, unload first, archive its exact private storage file with an experiment ID/hash, then deliberately reset only this probe's storage while unloaded. Do not overwrite prior evidence or modify other plugin storage. The SDK resolves storage as `<configured storage root>/<plugin id>/storage.json`; do not guess the active root or profile.
3. Stage this standalone developer plugin only under the coordinator's normal reviewed trial process. Loading starts observation automatically; there is no in-game reset or scoring command. Run one of the seven C0 sequences from the calibration ledger, documenting timing and initial/final conditions externally.
4. Unload cleanly, inspect the SDK log for errors/time-budget stops/storage-write warnings, and verify the resulting private JSON file's size, snapshot state, counters and retained interval. A successful `storage.set` callback alone does not establish durable recording. Archive raw evidence privately; never commit raw captures or extracted game data.
5. Summarize only supported findings in `SKATE_SCORING.md`, with private capture hashes, trial IDs, timing resolution and limitations. Leave every unresolved rule UNKNOWN and its numerical default AUTHORED.

There is no auto-install, no deployment script and no automatic promotion of a capture to calibrated rules.

## Source tests (authored, not run)

The new synthetic suite lives only inside this probe. It uses a fake SDK and source-defined observations, not game recordings. It is not registered into existing host-pinned BMX suites or the runner's BMX-only glob. After an execution slot is granted, use the existing standalone runner with this plugin directory explicitly:

```powershell
build/luau-runner/Release/bmx_luau_tests.exe contrib/bmx-lab/skate-score-probe/plugin score_probe_tests
```

This command assumes the coordinator already has a reviewed build of the runner; no runner build or invocation was performed here. Synthetic success would qualify only the recorder behavior exercised by those fixtures. Real SDK JSON/storage behavior, runtime timing, clean unload/disk save and C0 still need coordinator-owned validation.
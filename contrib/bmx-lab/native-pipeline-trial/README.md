# Native command-pipeline diagnostic

This inert Luau mod tests the generic `reskate.world.physics` transport. It is
not a bike controller. Its exact source was exercised through the real sandboxed
Host with fake native observations, then in the isolated supported Skate build.

Copy this folder into an isolated installation's `Mods` under a fresh diagnostic
name. Open its **Owned Pipeline Trial** page, explicitly Start, then close the
menu with gameplay focused. It creates one 12 kg capsule beside the local actor
and requests 120 consecutive 117.6 N upward force commands. There is no impulse,
torque policy, rider binding, camera ownership or controller capture. The overlay
is a marker of measured state, not a rendered capsule mesh.

The first create may refuse before allocation while the qualified 60 Hz clock
warms up. Only that exact refusal offers another explicit Start. No allocation
or command retries, missed-step catch-up or Lua pose integration occur. UI arming
has 120 seconds; an allocated body has a six-second wall watchdog. Clock gaps,
stale samples, failed receipts and focus/menu changes stop and release it.
Successful release parks a retained allocation; it does not destroy it.

Each command uses the last actual sample N, must apply at N+1, and must acquire
its first independent successor at N+2 before ordered acknowledgement. Every
retained receipt is inspected, so a later partial failure cannot hide behind an
older record. Receipt draining precedes the final read used for publication.

The complete bounded ledger goes to the plugin's `pipeline_native_v1` storage
key after the release attempt. Logs contain only a short summary: VM log lines truncate at
2,000 bytes. The normal Host checks dirty storage every two seconds and also
saves it when closing the VM. Verify the actual saved file before accepting
evidence; a successful `storage.set` only queues the data. Storage is in
`%LOCALAPPDATA%/ReSkate/Plugins/<mod-folder-name>/storage.json`, independent of the
isolated game profile. An existing ledger prevents another Start or overwrite.
Archive it and use a fresh diagnostic mod identity for another trial.

## Verified run

On 2026-10-23 UTC (2026-10-22 local), the native fixture completed one two-second
burst: 120 publications, 120 measured ordered acknowledgements and zero repeated
client observations. The requested serials were 1838 through 1957; their native
producer serials were 1839 through 1958, and their independent successors were
1840 through 1959. The allocation was released successfully. The full 78,394-byte
ledger was saved before the mod was explicitly withdrawn and unloaded; the game
then shut down normally.

After the initial gravity step, measured vertical velocity stayed about
-0.16333 m/s and height fell 0.32864 m. This is consistent with the constant
force balancing gravity while retaining the initial downward velocity; it is
not a perfect-hover result. The summary's last sample precedes the final receipt
successor by one epoch, so the per-command ledger is the qualification evidence.

- Runtime source build: `f3880a287292fd71e2a6f2bfb0dbea22554f9918`.
- Runtime SHA256: `65EB08AFD7EEE43319161D59A40EC2F8D0588203DE6D43E4AB049171EA6870CF`.
- This `plugin/main.lua` SHA256: `036604D668BA339F6370B643D35F0EC09C6FBAC4EFB649BB9CA74F1E4D5E238A`.
- This manifest SHA256: `727BEAC5B7647350F92784A6E03114459CF66BE810ABC69DAF1FC96562A238A8`.
- Native ledger SHA256: `C444476179AAC2CFBB0D7AA326EB5C224682B6F6435ACCC9CF36C3E1AE8D8AA1`.
- Owned process: PID 54352, GetProcessTimes FILETIME 134372014484782026;
  executable/loaded runtime paths and disk hashes checked, not in-memory hashes.

Six focused offline Host cases passed at unchanged limits: ideal 120 commands,
explicit clock warmup, skipped step, later partial failure, focus loss and
refused release with stopped-marker suppression. They qualify the fixture's
state machine; native scheduling is established only by the separate real run.
Private source freezes, test results, process receipts, screenshot, raw native
log and ledger are under `build/bmx/lua-owned-pipeline-native-trial-v1/` and
`build/bmx/owned-pipeline-fixture-review-v1/`. No game binaries or extracted assets
are included here.

This proves one capsule and one constant-force burst. It does not qualify a
whole riding session, the BMX force kernel, torque, wheel contacts, moving
surfaces, cleanup of an active body during unload or world changes, partial
native failures, rider presentation, controller consumption, switching, fall recovery
or BMX Streets likeness. The requested 9.5 likeness remains unverified.

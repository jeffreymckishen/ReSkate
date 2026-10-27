# Python virtual controller harness

`Bmx-VirtualGamepad.py` submits short, fixed Xbox controller report sequences to the isolated Skate process only when `--execute` is supplied. The default is a fast dry-run that does not import vgamepad, inspect a game, connect a device, change focus, inject keyboard input, or install anything. It writes a new JSONL plan/ledger under `build/bmx/virtual-gamepad`.

Run with Python3.11 or newer, from the repository root:

```powershell
python -B contrib/bmx-lab/Bmx-VirtualGamepad.py --scenario native-y
python -I -B contrib/bmx-lab/Test-BmxVirtualGamepad.py
```

The focused tests use fake backends, clocks and Win32 metadata adapters. They exercise the actual runtime guard check body, report sender, abort/release/disconnect paths, invalid timelines, inherited-free dry-run boundary and owner-file validation. They also pin, byte for byte, the reports, SDK calls and dry-run ledger rows of the nine scenarios that predate `pedal-straight` and TOOL-2 (digests taken from driver `B0B78C74…`). They create no real controller and do not import vgamepad. They are not native gameplay evidence. CTest runs them as `bmx_virtual_gamepad_python` (`cmake/BmxTests.cmake`), on Windows only, because they patch the Win32 adapters.

## Dependencies and host setup

Execution requires a separately approved and verified ViGEmBus driver installation and the exact private Python environment with the **six reviewed vgamepad0.1.0 files**. The user has approved driver setup in this development session; the setup/install verification is handled separately. This script neither installs dependencies nor launches an installer, and it does not prompt for another installation approval.

Use the separately verified official ViGEmBus1.22.0 setup, whose release removes the updater. The upstream driver project is archived. Preserve its Authenticode/hash/install verification receipt. Installing a kernel driver on another machine or changing the approved installation remains a separate setup action. See the [official release](https://github.com/nefarius/ViGEmBus/releases/tag/v1.22.0).

The published PyPI0.1.0 artifact is a source archive whose setup script can launch its bundled older driver MSI and **does not honor** `VGAMEPAD_SKIP_VIGEMBUS_INSTALL`. Upstream main's0.1.3 setup has that flag; it must not be assumed to protect0.1.0. Do not pip-install the source archive, execute setup.py, or run the bundled MSI. The separately reviewed setup copies only five package Python files and the adjacent x64 ViGEmClient.dll from the hash-verified archive into the private environment, with no setup execution. The harness never calls pip. For future package versions, prefer a separately verified binary wheel and re-review the backend; do not fall back silently to source setup. See the [published package artifacts](https://pypi.org/project/vgamepad/0.1.0/#files) and [upstream setup source](https://github.com/yannbouteiller/vgamepad/blob/main/setup.py).

The private environment is `build/bmx-gamepad-runtime`, and its sole supported package root is `Lib/site-packages/vgamepad`. Execution reads `build/bmx/gamepad-setup/dependency-verification.json` (overridable only with an equally strict receipt via `--dependency-receipt`). It must bind schema1/event `bmx_virtual_gamepad_dependency`, version0.1.0, source SHA256 `57F6BD01AEC0C172947517FB782D150EF9B285F7F4D524C317374FA5C24A89DE`, the exact private interpreter/package paths, all six relative path/hash/size entries, and both setup/installer-executed fields false. The harness independently pins the six hashes, checks the actual files and package inventory, refuses reparse paths/extra files/bytecode caches, and checks the top-level import origin before importing anything from vgamepad. It requires a fresh Python process with no preimported vgamepad and disables package bytecode creation.

The six files are `__init__.py`, `win/__init__.py`, `win/vigem_client.py`, `win/vigem_commons.py`, `win/virtual_gamepad.py`, and `win/vigem/client/x64/ViGEmClient.dll`. No dist-info version lookup is needed for the manual copy. The first import occurs only after the owned-process/focus guard has passed. vgamepad opens its bus during import; its Xbox controller constructor submits an initial neutral report. That submission alone does not establish neutral XInput readback: the driver has a cached startup packet with nonzero axes. The reviewed0.1.0 backend removes/frees the device in its destructor. The wrapper makes that owner cleanup idempotent and calls it explicitly in `finally`, after sending neutral. The corresponding [upstream backend](https://github.com/yannbouteiller/vgamepad/blob/main/vgamepad/win/virtual_gamepad.py) explains the API; the exact published0.1.0 bytes are pinned locally. No optional driver/client API is loaded by dry-run or tests.

Before any scenario, the harness explicitly submits one raw left-stick X unit (`1` out of32767), with all buttons, triggers and other axes zero, followed by neutral. This bootstrap clears the driver's zero-report duplicate cache. The startup byte pattern and duplicate-cache behavior are documented in the [driver source](https://github.com/nefarius/ViGEmBus/blob/master/sys/XusbPdo.cpp). Every bootstrap attempt/result is timestamped separately in the ledger and guarded by owned-process, foreground and Escape checks. The public driver `vigem_target_x360_get_user_index` API supplies the actual XInput slot; the internal device index is not used as an XInput slot. Two exact all-zero XInput report observations on the same slot are required within1s before scenario inputs are allowed. A failed or late bootstrap aborts and still attempts neutral and removal. The initial device attachment and SDK constructor update precede this verification; the controller is globally visible during that short interval.

## Ownership and execution

An operator must first launch the exact isolated game, choose the intended test state and begin a separate genuine screen capture if needed. The harness never starts a game, arms a native observer, activates a window, changes the camera, captures an image, or posts to Reddit. A captured midtrick frame must come from the actual game recording and be tied to the ledger; a submitted trick input alone is not a trick screenshot.

Write a **new, explicit** owner receipt under `build/bmx`, using the supervisor's actual current PID, its exact Windows creation FILETIME and the installed runtime SHA256. Never copy an old PID/time. This example is a schema only; placeholder values are deliberately unusable:

```json
{
  "schema": 1,
  "event": "bmx_virtual_gamepad_owner",
  "process_id": 12345,
  "process_creation_filetime": "REPLACE_WITH_EXACT_CURRENT_FILETIME",
  "game_exe": "C:\\Users\\Jeffr\\Desktop\\reskate\\build\\bmx-game\\Skate.exe",
  "runtime_sha256": "REPLACE_WITH_VERIFIED_CURRENT_RUNTIME_SHA256"
}
```

Select the approved local Python environment, focus the game externally, and run one explicit scenario:

```powershell
build\bmx-gamepad-runtime\Scripts\python.exe -B contrib/bmx-lab/Bmx-VirtualGamepad.py --execute --owner build/bmx/current-virtual-pad-owner.json --scenario native-y
```

The execution guard binds the exact workspace, isolated executable path, PID, creation FILETIME, supported game hash and runtime disk hash. It holds a process metadata handle, checks process liveness/path/creation, foreground PID and Escape on each report and during waits. It checks file identity/size/timestamps each time, and re-enumerates the exact loaded ReSkate.dll path at least every200ms. Runtime hash is a disk identity; it is not an in-memory image hash or proof of loaded configuration. The receipt is an explicit operator assertion bound to actual process metadata, not a signed attestation or proof of gameplay state.

**Escape, focus loss, process exit, identity/file change, driver error, scheduler delay over120ms, keyboard interrupt or a ledger failure abort the scenario.** Cleanup still attempts a full neutral report and device removal even when focus is lost. Results record cleanup failures rather than claiming release. The guard polls every10ms between50Hz reports; this is not atomic OS routing or a real-time watchdog. A blocked Python/driver call can delay detection. Virtual controllers are visible to Windows globally, and game-side selection among multiple pads must be measured independently. The one scheduled Start press in `pause-menu-20s` is a pad report like any other: the guard does not change for it and still reads the real keyboard's Escape and the real foreground window before every report and during every wait. The driver injects no keyboard input. If some layer (for example a Steam Input desktop configuration) turned the virtual Start into a keyboard Escape, the guard would see that Escape and abort; that is a refusal, not a pass.

## Ready/go coordination

`--start-gate <fresh-directory> --start-nonce <32-hex-characters>` is available only with `--execute`; both options are required together. The directory must not already exist and must be inside `build/bmx`. The harness creates it exclusively. It refuses existing directories, preexisting ready/go files, path escapes and reparse paths. Defaults and fixed input timelines are unchanged when these options are absent.

The gate is required for a live run of `pedal-straight` and every registered long scenario: `neutral-window-30s`, `pause-menu-20s`, `ride-10s`, `ride-s01-30s`, `ride-steer-brake` and `coast-long`. Without it, `--execute` with one of those names refuses before any owner receipt, ledger, game inspection or device step. Their times are counted from go, so go has to be an operator's deliberate act. The nine older scenarios keep the gate optional, as it always was; their leg wrappers (`Bmx-*Leg.py`, `Bmx-CoupledVirtualTest.py`) require it themselves. Dry runs need no gate.

Use this option to construct and verify the neutral controller while the game console remains open. After bootstrap, the harness writes an exclusive `ready.json` containing schema1/event `bmx_virtual_gamepad_ready`, PID, exact creation FILETIME string, executable/runtime identities, nonce, scenario, source hash and UTC. It keeps the neutral device and checks the owned process, focus and Escape every10ms while waiting up to60s. No scheduled scenario report is submitted until a valid trigger arrives. This neutral preflight wait is separate from the scenario timelines below, the fixed20s and30s windows included.

The operator must read and verify the ready receipt, close the console using the supported UI tool, then write a complete temporary JSON file in that gate directory and **atomically rename** it to `go.json`. Do not create or write `go.json` in place. Its exact five fields are:

```json
{
  "schema": 1,
  "event": "bmx_virtual_gamepad_go",
  "process_id": 12345,
  "process_creation_filetime": "REPLACE_WITH_CURRENT_READY_FILETIME",
  "nonce": "REPLACE_WITH_CURRENT_32_HEX_NONCE"
}
```

The PID, FILETIME string and nonce must exactly match the running harness owner and ready receipt. These placeholder values are unusable. Extra fields, malformed or oversized JSON, changed files, mismatches, timeouts, focus loss, Escape or owner failure abort before scenario inputs; cleanup still attempts neutral and device removal. The scenario timer starts after matching go acceptance. Ready/wait/go events are recorded in the ledger. The trigger is an operator assertion, not evidence that the console closed, the native observer armed or the game consumed input. Each retry needs a new gate directory and nonce; old receipts are retained as evidence.

## Fixed scenarios and current controls

All scenarios begin/end neutral and leave the virtual D-pad untouched; only `pause-menu-20s` presses a menu button, once. Every timeline stays within6s except the exact two-event `neutral-window-20s` (20s) and six exact registered long timelines of at most30s: `neutral-window-30s`, `pause-menu-20s`, `ride-10s`, `ride-s01-30s`, `ride-steer-brake` and `coast-long`. Only those exact tuples qualify for the longer limit. An extra intermediate event, another nonneutral report, another duration or Start in any other timeline refuses before a device exists. These scenarios do not alter the physical controller's D-pad mappings. Durations below are planned wall timing; the ledger records actual host times and lateness as well.

| Scenario | Inputs requested | Required starting state / evidence boundary |
|---|---|---|
| `neutral-follow` | All scheduled buttons, sticks and triggers remain zero through6000ms (301 reports at50Hz) | Bounded neutral device for the first500ms of Lua follow selected-source acquisition. Verify source acquisition and follow separately; this submits no bike movement or switch request. |
| `neutral-window-20s` | Exact neutral events at0ms and20000ms;1001 scheduled zero reports at50Hz | Longer fixed reporting availability only. No movement, source eligibility, selected slot, input consumption or timing-cause inference. |
| `native-y` | Neutral240ms, North/Y200ms, release through3.6s | Fresh isolated NativeOnly session, observer already armed, zero BMX activity. A **virtual North** comparison, not a physical-controller baseline. |
| `native-b` | Neutral240ms, B200ms, release through1.2s | One ordinary Back/Brake pulse in the observed isolated game state. Menu closure and input consumption require a separate screen observation. |
| `ground-pump` | Neutral240ms, A to1000ms, coast to1200ms, LS Y=-0.7 for300ms, release and settle to3200ms | Already mounted on clear supported ground. Checks the direct pump channel; reports alone do not establish force submission or handling quality. |
| `ground-pump-switch` | Same pump, brake1500–2300ms, then one LB+Y chord and release through4000ms | Already mounted; normal parking may retain the pump window in a ride trace. Verify the new trace and actual switch separately. |
| `equipment-switch` | LB prehold, LB+Y200ms, release, settle to4.4s | Ordinary Ride session with the current equipment-switch path. Excluded from NativeOnly isolation. |
| `bunnyhop-tailwhip` | A pedal, release, rear stick back340ms then forward80ms, neutral, both triggers+rear stick right180ms | Already mounted, clear ground. Rear-flick hop and tailwhip-right request use the current mapper. Airborne eligibility and completion remain unknown. |
| `quickhop-barspin` | A pedal, release, R3 quick hop120ms, neutral, LB+rear stick back180ms | Already mounted. R3 and left-barspin request use the current mapper. An insufficient hop may refuse the trick. |
| `pedal-straight` | Neutral for the configured lead, A for1000ms, neutral to6000ms (301 reports) | TOOL-1(b), DEC-6, TR-M45's pedal segment. **Refuses while the lead is unset.** Already mounted on clear flat ground; the lead's last500ms or more after publication is the standing segment. |
| `neutral-window-30s` | Exact neutral events at0ms and30000ms;1501 scheduled zero reports | TOOL-2(a), M6e. Reporting availability only, with the same boundaries as `neutral-window-20s`. **Ends 30s after go, before a30s window opened at publication closes**; see [the 30s timelines](#the-30s-timelines-and-the-ride-window). |
| `pause-menu-20s` | Neutral to3000ms, Start200ms (ten reports), neutral to20000ms;1001 reports | TOOL-2(b), M6c only: the game's pause menu at3s (S2 section 9). **Valid only if Follow was published before the first Start report**; see [the pause-menu event](#the-pause-menu-event-tool-2b). The driver does not close the menu. Whether it opened is a separate screen observation. |
| `ride-10s` | Neutral for the configured lead, A from the lead to10000ms, neutral to20000ms;1001 reports | TOOL-2(c), M6f. **Refuses while the lead is unset.** Pedal stops10s after go, before a10s ride window opened at publication ends; the neutral tail covers the window's close. Neither the roadmap nor S2 sets M6f's inputs: pedalling without a break is the driver author's proposal, and JUDGE or the owner accepts it before M6f is judged. |
| `ride-s01-30s` | After the configured lead: A6s, neutral3s, B6s, neutral0.5s, A2s, neutral to30000ms;1501 reports | TOOL-2(c), M6g: S01 as `bmx-plugin/SIMULATION.md` scripts it. A fixed timeline cannot see S01's "brake until below0.05m/s", so B holds for S01's6s cap. The simulation comes to rest about2.22s into the brake from7.90m/s, so if the game matches it, B is held at a standstill for about3.78s, and the rest and the restart come about3.78s later than in S01's simulated run. This profile is the driver author's proposal; JUDGE or the owner accepts it before M6g is judged. **Refuses while the lead is unset. Ends 30s after go, before a30s window opened at publication closes**; see [the 30s timelines](#the-30s-timelines-and-the-ride-window). |
| `ride-steer-brake` | Neutral240ms, B until60ms before the lead, neutral60ms, A1500ms, neutral240ms, LS X=-0.8 for2000ms, neutral240ms, LS X=+0.8 for2000ms, neutral240ms, B1000ms, neutral to14000ms;701 reports | Already mounted on clear supported ground. The initial brake requests a hold against slope drift; actual holding, mapper acquisition, steering and stopping need native evidence. **Refuses while the lead is unset.** |
| `coast-long` | Neutral until the lead, A4000ms, neutral to12000ms;601 reports | Already mounted on clear supported ground. Requests acceleration followed by coast; reaching the pedal cutoff and coasting behavior require game evidence. **Refuses while the lead is unset.** |

For neutral-follow, only the scheduled timeline is all neutral. The unchanged mandatory bootstrap still sends one raw left-stick X unit before its two exact-zero readback samples; device attachment and the SDK constructor update also precede the timeline. The scenario name does not mean the entire process lifetime is free of active input. The existing ownership, foreground, Escape, dependency, slot, nonce, lateness and cleanup checks still apply. Six seconds of submitted neutral reports do not establish the game's selected source, a Lua lease, follow publication, safe switching or gameplay quality.

The20s neutral window has the same mandatory bootstrap and all the same guards. Its default CLI ledger uses a separate fixed1200-row bound, enough for1001 scheduled reports plus the bounded bootstrap, ready/go and cleanup records. The registered long timelines use `LongTimelineLedger`, whose fixed bound is the timeline's scheduled reports plus the same199-row margin: 800 rows at12s, 900 at14s, 1200 at20s and1700 at30s. Every other scenario, `pedal-straight` included, keeps the unchanged512-row ledger, and every row keeps the same format. No duration or ledger-cap option is exposed. This longer availability window changes no source eligibility rule and does not prove why an earlier acquisition was unavailable. The scheduled count excludes bootstrap and final neutral/disconnect as before.

### The pedal lead (DEC-6)

`pedal-straight`, `ride-10s`, `ride-s01-30s`, `ride-steer-brake` and `coast-long` start pedalling after a configured lead. Supply `--pedal-lead-ms` for a trial, or the driver uses the `PEDAL_LEAD_MS` literal in `Bmx-VirtualGamepad.py`. The tracked literal remains `None`: omitting the option keeps the previous refusal for lead-dependent scenarios. An unset or invalid lead refuses before any owner receipt, ledger, game inspection or device step. The option accepts only integers from500ms to4980ms inclusive, in20ms steps, and refuses for any other scenario. That upper bound leaves a neutral report before6s in `pedal-straight`. Times are counted from go acceptance.

Choose the lead using M1's measured report-to-publish time, plus a margin, plus at least500ms after publication (DEC-6, TR-M45's standing segment). Range validation does not establish that publication happened or that a particular lead covers this requirement. Check the current trial's publication evidence. The command-line override avoids editing the driver and leaves its source hash unchanged; `controller_session_start` records the explicit `pedal_lead_ms` when supplied and always records the complete resolved timeline.

These commands are dry runs only;1500ms is an example, not an automatically calibrated lead:

```powershell
python -B contrib/bmx-lab/Bmx-VirtualGamepad.py --scenario ride-steer-brake --pedal-lead-ms 1500
python -B contrib/bmx-lab/Bmx-VirtualGamepad.py --scenario coast-long --pedal-lead-ms 1500
```

A live run still needs `--execute`, the exact owner and dependency receipts, and a fresh start gate and nonce as described above. A dry-run ledger or passing fake-backend test does not qualify a live controller, mapper, bike or rider.

### Steering/braking and coast timelines

For `ride-steer-brake`, the initial240ms neutral interval permits acquisition but does not prove it. B is then held until60ms before the lead, followed by60ms neutral before A. That release gives the mapper's neutral gate another opportunity after publication; it is a deliberate addition to the brief's initial brake hold. It schedules three neutral reports but does not prove the mapper observed one or that the brake prevented slope drift. The unchanged120ms scheduler-lateness limit can allow those reports to arrive close together. Before counting pedal movement, the trial capture and native trace must show a fresh neutral sample and an active mapper. Successful HID reports alone do not establish that the mapper passed its neutral gate. The measured publication prerequisite still applies.

With `--pedal-lead-ms 1500`, the exact requested intervals are:

| Scenario | Time from go (ms) | Requested state |
|---|---|---|
| `ride-steer-brake` | 0–240 | Neutral |
| `ride-steer-brake` | 240–1440 | B |
| `ride-steer-brake` | 1440–1500 | Neutral |
| `ride-steer-brake` | 1500–3000 | A |
| `ride-steer-brake` | 3000–3240 | Neutral |
| `ride-steer-brake` | 3240–5240 | Left-stick X=-0.8 |
| `ride-steer-brake` | 5240–5480 | Neutral |
| `ride-steer-brake` | 5480–7480 | Left-stick X=+0.8 |
| `ride-steer-brake` | 7480–7720 | Neutral |
| `ride-steer-brake` | 7720–8720 | B |
| `ride-steer-brake` | 8720–14000 | Neutral |
| `coast-long` | 0–1500 | Neutral |
| `coast-long` | 1500–5500 | A |
| `coast-long` | 5500–12000 | Neutral |

Intervals include their start and exclude their end; each timeline also submits its final neutral endpoint. Unlisted buttons, axes and triggers remain zero. The50Hz scheduler requests701 reports for `ride-steer-brake` and601 for `coast-long`, excluding bootstrap and cleanup. Changing the lead shifts the lead-relative phases but keeps the final endpoints at14000ms and12000ms respectively. The fixed scripts do not observe speed, drift or stopping, and four seconds of A does not guarantee reaching the pedal cutoff. Join the ledger with genuine game capture and native traces before judging those results.

### The pause-menu event (TOOL-2(b))

`pause-menu-20s` sends one virtual **Start** (`XUSB_GAMEPAD_START`, 0x0010) for200ms,3s after go. Start, not Back, because ReSkate already treats Start as the pad's pause key: its challenge-menu capture hides `XINPUT_GAMEPAD_START` and `VK_PAD_START`, together with the keyboard's `VK_ESCAPE`, to keep the game's pause menu shut (`Extension/UI/Overlay/input_capture.cpp`). That capture leaves Back alone. That Start opens build 20260929's pause menu from a ViGEm pad is inferred from that code, not yet observed in the game. Start is not an allowed button anywhere else; only this exact tuple may press it.

The SDK does use Back, though: it reports Start and Back alike, with Escape, as a menu request (`bmx_menu_requested`, `Engine/Game/Input/bmx_input_sample.h`), and a rider holding a BMX input capture lease is to release it on that request so that the native menu can take the press (`Extension/UI/Overlay/overlay.h`, `DingoSDKOverlaySetBmxInputCapture`). So if such a lease is live in M6c, the virtual Start can end BMX capture as well as open the pause menu, as a user's Escape would. That is the game's behaviour, not the driver's guard, but the trial's record has to tell a capture release apart from the `pause_menu_open` revocation it is looking for.

The press is the same kind of XInput report as A or B, and nothing about the guard changes for it. A real Escape key or a real change of foreground window still aborts before the next report, during the press or after it, and cleanup still sends neutral and removes the device. The driver never closes the menu: the operator does that after the session, or a later reviewed timeline adds a second event.

The3s is counted from go acceptance, where the scheduler's clock starts, not from Follow publication, and it does not depend on `PEDAL_LEAD_MS` or M1's measured lead. M6c's pass is `revocation=pause_menu_open`, which needs a live Follow when the menu opens. So this timeline fits M6c only if Follow is published well before3s after go: M1's report-to-publish time plus its margin must stay under3000ms. Before judging an M6c attempt, check in the trial's own record that publication came before the ledger's first Start report (the `controller_report` at `planned_ms` 3000, with its UTC and host monotonic time). If it did not, the menu opened before Follow was live: the attempt does not test M6c and is recorded as void, and a retry needs a new gate directory and nonce.

The ReSkate overlay (M6d) opens only from keyboard keys (`overlay_keys()`: Insert and the console key by default). This driver sends no keyboard input, so it cannot open the overlay. `pause-menu-20s` covers M6c only; TOOL-2's overlay event, and with it M6d, stays open and needs another route.

### The 30s timelines and the ride window

Every timeline is timed from go, and the long ones end at their last event: `neutral-window-30s` and `ride-s01-30s` stop30s after go, then the driver sends neutral and removes the device. M6e's window (`RIDE_WINDOW_MS=30000`, passing only on `explicit_stop` at Core's window end) and M6g's window open at Follow publication, which comes after go by M1's report-to-publish time. So the pad is released and removed about that long before a30s window closes, and before Core's cleanup runs. A pad that disappears mid-window may change Core's input facts or the game's state, and spoil the pass for a reason that has nothing to do with Follow. `ride-10s` avoids this with its10s neutral tail. The30s timelines have no tail, because TOOL-2 caps timelines at30s.

This is open with COORD and the owner. Until they choose, use these two timelines only with a trial window that closes, tail included, before30s after go: `RIDE_WINDOW_MS` no longer than30000ms minus M1's report-to-publish time minus a tail. The other choice is a reviewed change that lets these exact tuples run to30s plus the lead plus a tail.

The Luau ride bindings are in `bmx-plugin/plugin/ride_input_mapping.lua` and `bmx-plugin/plugin/input.lua`: A pedals, B brakes, and left-stick X steers after the mapper's normalization. R3 requests quick hop, LB+rear-back selects left barspin, and both triggers+rear-right selects right tailwhip. Right stick controls rear gestures. These tests do not change either stick mapping. No arbitrary external timeline, unbounded hold, replay loop or synthetic native state is accepted.

The JSONL ledger records UTC and host monotonic time for each report, the requested full controller state, whether the backend update returned, owner/source/dependency identities, final neutral attempt and disconnect result. `driver_report_count` counts scheduled updates that returned; it excludes the SDK constructor update, explicit bootstrap and final neutral release, and is not a count of submission attempts. A failing update or partial constructor may have delivered an uncertain report, so a zero count is not proof that no driver input occurred. Factory failure records delivery as unknown. `neutral_release_succeeded` means the neutral update returned; `disconnect_succeeded` means the SDK remove/free wrapper returned. The pinned SDK ignores the native removal status, so these fields do not independently verify XInput neutral or post-removal absence. Measure those separately when required. Dry-run explicitly marks timing simulated and every driver submission false. `input_consumed` and `native_quality` stay null in every result. Successful report submission is not evidence of native input consumption, mounting, a trick, a landing, a good pose or a quality score. Join genuine capture and native trace evidence separately before judging any of those outcomes.

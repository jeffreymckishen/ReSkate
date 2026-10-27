# Skate scoring calibration (C0)

**C0 evidence: UNKNOWN.** No skateboard calibration, probe execution or scoring comparison has been performed for this source checkpoint. The separate developer probe lives in [`../skate-score-probe/`](../skate-score-probe/README.md); it must never ship with the BMX mod. The probe records SDK observations and writes only its own private storage. It never writes game score, progression, challenges or trick labels.

All scoring values below are **AUTHORED defaults**, taken from the corrected scoring plan dated 2026-10-27, not measured Skate rules. This ledger does not implement them or override the scoring-core lane. C0 can replace a value only after a reviewed observation identifies the trial, source version, measurement and its limits. No raw dumps, game assets or extracted scorable definitions belong in Git.

## What the current SDK actually observes

| SDK source | Actual payload / meaning | Limit |
|---|---|---|
| `trick_started` | `{at}` with a position vector. The probe records the occurrence and its observation time. | No points, name, trick ID or native start timestamp is supplied. The probe intentionally omits position. |
| `trick_landed` | `{points, multiplier, name, ms, started_at, landed_at}`. Probe keeps the four scalar/text scoring fields. | `points` is calculated by SDK `TrickWatch` from the HUD line change; it is not a direct native per-trick ledger. `name` is the last nonempty HUD header. `ms` is elapsed watch-start to score-detection, including delayed credit; it is not certified airborne time. |
| `line_broken` | `{reason}`, currently `slam` or `wipeout`. | Emitted only when the watcher has an active or pending trick. Its absence cannot prove that a stopped line was banked or that no bail happened. |
| `trick_notes` | `{notes = {{entry, kind, text}, ...}}`. `entry` is an opaque decimal string, preserved as text. | The plan's prose `{kind,text}` describes each note, not the event wrapper. Notes are UI writes, not completed trick records. |
| `score.current()` | A table with `line`, `multiplier`, `in_trick`, `trick`, `detail`, `manual`, or nil when unavailable. | Cached state sampled by the SDK, not every native write. `in_trick` is watcher state; `manual` is inferred from HUD naming. Unavailable is recorded separately from zero. |
| `time.now()` | SDK steady-clock milliseconds, used for local observation timing. | No wall-clock/UTC or native event-time claim. Callback order and sequence numbers order observations, not all underlying game actions. |

Note kinds are `n` name, `s` side, `l` landing, `b` body spin, `r` board spin, `k` stance and `m` modifier. Record the delivered text rather than translating it into invented numeric quality or stance fields. An entry can receive several notes; retain its opaque identity when correlating them. The SDK's feed buffer itself stops accepting notes at 256 pending entries without exposing an upstream loss count. The probe can report its own dropped rows and notes, not certify complete native coverage.

Source references: `Extension/Plugins/plugin_vm.cpp` (`Plugin::trick`), `plugin_host.cpp` (trick-notes delivery), `plugin_api.cpp` (`score`, `now`, JSON/storage), `plugin_runtime.cpp` (`read_tricks`), and `Extension/Skater/trick_watch.h/.cpp`, `trick_feed.h/.cpp`. These source observations are not a C0 run. In particular, `trick_watch.h` calls the line-score/multiplier interpretation provisional and unchecked against the game's own trick list.

No SDK event supplies a line timeout, banked amount, stopped-speed measurement, numeric landing quality or authoritative point multiplier for stance. The probe's two permissions provide no input injection or speed/control telemetry. Use external trial timing and video/operator notes to interpret those questions; do not infer them from a missing event.

## C0 measurement ledger

Every measured result and evidence reference is **UNKNOWN** until Claude completes the coordinator-owned skateboard trial. A source test or recorder output alone cannot promote these rows to measured rules.

| Question | Current authored default / policy | C0 result and evidence |
|---|---|---|
| Multiplier start, step, category/link effects and cap | `min(4, 1 + 0.5 * distinct_categories + 0.25 * min(4, links))`; every constant and the formula are AUTHORED. | UNKNOWN |
| Repeat decay | `max(0.1, 1 - 0.25 * (occurrence - 1))`, ignoring left/right in the key; AUTHORED. | UNKNOWN |
| Score aggregation | Floor of accumulated credit times line multiplier; AUTHORED, despite the SDK's provisional HUD interpretation. | UNKNOWN |
| Line timeout and pauses | 2.5 s rolling timeout; frozen during air/pending landing/manual/grind/stall; AUTHORED. | UNKNOWN |
| Stopping or deliberate dismount | Bank after speed below 0.3 m/s for 1 s, or deliberate stop/dismount; AUTHORED. | UNKNOWN |
| Slam/bail | Lose current line; no credit for failed air; AUTHORED policy. | UNKNOWN |
| Interrupted input/infrastructure | Bank prior credit, discard the unfinished air; AUTHORED policy. | UNKNOWN |
| Landing labels and factors | Clean 1.0, Sketchy 0.7, unknown 0.7 without label; AUTHORED. | UNKNOWN |
| Stance/side effect on points | No measured modifier. Authored names/policy are not Skate evidence. | UNKNOWN |
| Individual trick values | Difficulty D1-D5 = 100/200/350/550/800; Barspin D2 and Tailwhip D3; AUTHORED. | UNKNOWN |

The remaining corrected-plan numerical choices are also **AUTHORED**, including choices that C0's seven basic sequences cannot resolve:

| Authored area | Authored values / policy |
|---|---|
| Pose holds | `1 + 0.5 * min(1, hold / 0.5 s)` |
| Repeated catch and overlap | Catch `0.5 + 0.5*k`; bar/tail overlap at least 50% gives each part 1.25 |
| Rotation factor | `min(3, 1 + 0.25*half_turns + 0.5*(flips + rolls))` |
| Spin/flip points | Spin `150*n*(1+0.25*(n-1))*repeat`; flip/roll 600 for one or 1500 for a double per axis |
| Combo factor | `min(2, 1 + 0.2*(distinct_keys - 1))`; a spin and each flip/roll axis count as keys |
| Air time and partless hop | `floor(100*max(0, air_s-0.5))`; hop base 50, minimum air 0.25 s |
| Clean landing thresholds | Absolute body-up/support-normal and heading cosines at least 0.966, closing speed at most 5.5 m/s |
| Link interval | 0.5 s between credits where one is manual/grind/stall |
| Manual | 120 points/s or nose manual 150; start after 0.3 s, cap at 10 s |
| Grind | Lock-on 100; points/metre 60 double-peg, 80 feeble, 100 smith, 110 icepick/toothpick; change bonus 100 |
| Stall | 150 + 200/s, cap at 0.75 s |
| Categories, names and termination outcomes | The scoring plan's classification, key normalization, display labels and credit/bank/loss/interruption rules are AUTHORED choices |

These tables preserve provenance; the implemented scoring module and its own documentation remain the authority for its exact current defaults and order of operations. If that lane changes a default, update its authored provenance here before calling it calibrated. Do not copy the plan's ambiguous formula parentheses as a measured equation.

## Coordinator-owned C0 protocol (not yet run)

Run on a skateboard on flat ground, with the BMX mod and this developer probe kept separate. The coordinator must first own the execution slot. Use a fresh private probe capture for each sequence, archive it after a clean unload, and record exact SDK/probe hashes, supported build 20260929, start/end conditions, video/operator time marks and any gaps or errors. Probe setup and collection thresholds are AUTHORED instrumentation settings, not game rules.

1. One ollie.
2. Four ollies 1.5 s apart.
3. The same kickflip four times.
4. An ollie followed by 1 through 6 s of rolling before the next trick, with separate timing notes.
5. Ollie to manual to ollie.
6. A bail mid-line.
7. Stopping mid-line.

Use `score.current` line/multiplier changes and note labels as evidence alongside the SDK-inferred landed rows. Avoid using the watcher's points formula to prove that same formula. Confirm comparable tricks and labels before attributing a change to repeat decay or stance. A nil snapshot, dropped/truncated row, timing gap, upstream uncertainty, missing unload snapshot or SDK storage warning limits the usable interval. Report that limitation instead of synthesizing a missing observation.

No bank/timeout/stance/landing-value rule may be marked measured solely because the recorder stored a row. A reviewed calibration update should state the measured rule or uncertainty, contributing sequence IDs, capture file hashes retained privately, timing resolution, contradictory cases and remaining authored defaults. Commit only that written summary. Runtime cost, capture durability, C0 completion and all measured values remain UNKNOWN for this source checkpoint.
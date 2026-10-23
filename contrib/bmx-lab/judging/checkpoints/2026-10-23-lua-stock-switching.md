# Lua stock switching checkpoint — 2026-10-23

Two clean stationary stock on-foot → skateboard → on-foot roundtrips were recorded
across separate game launches through
the production [Lua adapter](../../bmx-plugin/plugin/equipment_runtime.lua) and
[transition model](../../bmx-plugin/plugin/equipment_transition.lua). This is
stock equipment switching. Rider follow, rider alignment and rideable BMX are
still not connected.

The independent [native and closure audit](../../../../build/bmx/input-pulse-profile-observation-independent-v1/trial-2-roundtrip-closure-audit-v1.json)
passed for this one roundtrip. Its SHA-256 is
`411C1C2053B7008A3354987E93E0C2203131962B05BD6C3C47151834A036394F`.
General reliability and BMX Streets likeness remain unscored.

## Recorded build and offline validation

- Source checkpoint: `8b4a497`.
- ReSkate.dll SHA-256:
  `D131AD9ADBC4F8B8B914DA258880B06B3093F464534135F54A038DD79CC11823`.
- Launcher SHA-256:
  `66298E2143344FE902C3BA6DEFF0EEB8FD281EE70E17ABD31C9D9427F7A3B66D`.
- The pinned Release build completed cleanly and all 28 focused CTests passed.
  These are source/offline checks, not a gameplay likeness score.

## First native session

Private evidence remains in the ignored
[session folder](../../../../build/bmx/input-pulse-profile-observation-v1/).
Each leg was explicitly armed once; no automatic request retry was used.

| Leg | Stock states | SDK sequence | Terminal report | Target suffix |
| --- | --- | --- | --- | --- |
| Trial 1 | On foot `504` → board `100` | `1` | `released / none`, mask `0` | 2.5 s; 151 qualified / 174 total samples |
| Trial 2 | Board `100` → on foot `504` | `2` | `released / none`, mask `0` | 2.5 s; 151 qualified / 151 total samples |

Both receipts recorded 51 press publications and one neutral publication,
released claims, no report debt, successful acknowledgement and no retained
handle. Each leg recorded one request, three reads, one terminal store and one
acknowledgement. Fresh baseline and final screenshots support the endpoint states.
Lua suffixes are sampled observations, not a native global-clock trace.

Each unchanged driver's scheduled interval contained 301 neutral reports;
completion, final neutral release and disconnect were recorded as successful.
Publication counts do not establish the wrapper's later normal return, native
input consumption or semantic causality. Terminal storage acceptance describes
the Host cache; archived files are later persisted snapshots.

Root recorded normal Alt+F4 shutdown and a CIM check finding zero Skate
processes. The v4 manifest was withdrawn after process absence. Closure is retained
in [session-shutdown.json](../../../../build/bmx/input-pulse-profile-observation-v1/session-shutdown.json),
with final storage and runtime log in the same folder.

The earlier context-continuity-v2 trial failed at grouped `controls_profile`
before any publication. These successful probes do not identify that failure's
precise cause and do not justify adding waiting, deferral or retry behavior.

## Fresh-session repeat

The unchanged package and binaries completed one further explicitly armed pair
in a fresh v5 package/storage identity and process. The
[repeat evidence](../../../../build/bmx/lua-stock-switching-repeat-v1/) retains
the fresh owner, original deadlines, separate per-leg gates and raw driver ledgers.

| Leg | Stock states | SDK sequence | Terminal report | Target suffix |
| --- | --- | --- | --- | --- |
| Trial 1 | On foot `504` → board `100` | `1` | `released / none`, mask `0` | 2.5 s; 151 qualified / 175 total samples |
| Trial 2 | Board `100` → on foot `504` | `2` | `released / none`, mask `0` | 2.5 s; 151 qualified / 151 total samples |

Each repeat leg recorded 49 press publications and one neutral publication,
the same clean claim/debt/acknowledgement and `1/3/1/1` request/read/store/ack
counts, and 301 completed neutral driver reports with successful release and
disconnect. Separate endpoint images show the expected standing states.
Normal game exit, process absence and subsequent v5 manifest withdrawal were
recorded; zero Lua manifests remained active. The independent
[repeat and closure audit](../../../../build/bmx/lua-stock-switching-repeat-v1/independent-repeat-closure-audit-v1.json)
passed, SHA-256
`3EEB9E0674529F6BA67AEC180FA76D19E875D9661BF81A94E7449AC7E406A0EC`.

## Later profile lock refusal

The subsequent post-terminal fall probe did not reach its intended window.
One accepted pulse was revoked after 16 ms with `controls_profile_lock / unavailable`:
the profile Try-lock was refused, actor inspection did not complete and the
native clock was not queried. There were zero candidates or publications, no
report debt, and one accepted acknowledgement after storing the terminal receipt.
The diagnostic recorded `NOT_COVERED` and made zero wipeout calls. The endpoint
remained upright on foot; there was no retry. Normal shutdown and manifest
withdrawal are retained with the [failed probe](../../../../build/bmx/lua-equipment-interruption-postterminal-v1/).
The independent [refusal and closure audit](../../../../build/bmx/lua-equipment-interruption-postterminal-v1/independent-refused-probe-closure-audit-v1.json)
has SHA-256 `B12DBA1519084CDED4C848EF23CE2C0D5943567D7C3B4F313CEADACC1CC6E239`.
This identifies one lock-acquisition failure, not its holder, duration or every
earlier grouped refusal. The two successful roundtrips do not erase it.

## Minimal next checks

These are proposed bounded tests, not completed coverage or new native admission.
Stop on an unexpected refusal, unresolved duty, readiness loss or fall; preserve
the full receipt and require an explicit new Arm for every later experiment.

| Check | Required result |
| --- | --- |
| Fall before SDK dispatch | No SDK request; the armed/baseline attempt stops without retry or qualified transition. |
| Fall after terminal acknowledgement but before the target suffix completes | Preserve the transport receipt, latch the fall/readiness boundary and refuse a qualified transition even if the rider later stands. |

A fall outside the intended window leaves that interruption case untested.
No automatic GetUp, body following or BMX activation is part of this matrix.
Two stationary roundtrips are concrete progress, not broad switching reliability,
rideable-bike acceptance or a 9.5 likeness claim.

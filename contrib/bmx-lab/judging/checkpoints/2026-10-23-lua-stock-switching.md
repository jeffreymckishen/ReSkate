# Lua stock switching checkpoint â€” 2026-10-23

Two clean stationary stock on-foot â†’ skateboard â†’ on-foot roundtrips were recorded
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
| Trial 1 | On foot `504` â†’ board `100` | `1` | `released / none`, mask `0` | 2.5 s; 151 qualified / 174 total samples |
| Trial 2 | Board `100` â†’ on foot `504` | `2` | `released / none`, mask `0` | 2.5 s; 151 qualified / 151 total samples |

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
| Trial 1 | On foot `504` â†’ board `100` | `1` | `released / none`, mask `0` | 2.5 s; 151 qualified / 175 total samples |
| Trial 2 | Board `100` â†’ on foot `504` | `2` | `released / none`, mask `0` | 2.5 s; 151 qualified / 151 total samples |

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

## Post-terminal sampled fall boundary

After `762f4da`, one fresh v2 interruption probe reached its intended window.
The [archived trial](../../../../build/bmx/lua-equipment-interruption-postterminal-v2/)
used the reviewed runtime, exact production Lua modules, one explicit Arm and
one accepted sequence-1 pulse. Its terminal receipt was `released / none`, mask
`0`, with 50 press publications and one neutral publication. The request-to-terminal
observation interval was 329 ms. The
claim was released, debt was clear, and request/read/store/ack counts were
`1/3/1/1`, with no retained handle.

The fixture queued one `wipeout(0.5)` only after terminal storage and
acknowledgement, while the adapter was settling on board `100`. Nineteen
milliseconds later, the same sampled-level watch reported selected state `300`
and an increased wipeout count. The adapter ended `failed / fall_observed` and
retained neither historical nor currently qualified transition success. Cleanup
resolved, and the fixture recorded `COVERED` under its sampled criterion.
These state/counter facts share the physics-watch route; they are not independent
visual or body-dynamics evidence. The watch records the selector's chosen return
state before the caller commits it. Its `telemetry.physics_state` is the same
watch copy, not an independent committed-state read. The first fall sample's
known ragdoll false is the watch's shortcut for selected states other than
`504`, not a native ragdoll flag read. The later endpoint image shows an upright
rider on the board; no recovery API was called or qualified by this trial.

The receipt recorded `warmup_deferrals = "0"`, so the new lock-deferral path
was not exercised in game. Its source and offline regressions passed; native
effectiveness remains unverified. The unchanged driver completed 301 neutral
reports, final neutral release and disconnect. Full storage was archived before
Go, within the original gate deadline. Normal shutdown, process absence and
subsequent manifest withdrawal left zero active Lua manifests.

The independent [coverage and closure audit](../../../../build/bmx/lua-equipment-interruption-postterminal-v2/independent-covered-window-closure-audit-v1.json)
has SHA-256 `F502A6146B01BC7E80B881333A2FEDB020879B9BA00113E95D29E5BC082A697D`.
Fall before dispatch remains untested. This checkpoint demonstrates receipt
composition and a latched sampled fall boundary, not rideable BMX or likeness.

## First mount after the upstream merge

The [fresh merged-build session](../../../../build/bmx/lua-stock-switching-upstream-7fa-v1/)
ran only its admitted forward leg. Source merge `d6f1497` includes upstream
`7fa407a`. The exact runtime was
`D7671D3EA5569AB561124DAE5E7ED9F84C47DB45C4B91CD8A6BE93DFF078B246`,
and its matched launcher was
`238B44ED98D4EB6F79602A316849C00D0A836CA0E00F845AD93E5BEB84054AAC`.
Both were built from the frozen merge tree before creating the merge commit;
their compiled Git stamp alone does not identify that later commit.

The production Lua adapter recorded `done / target_observed`: board `100`
remained sampled for 2.515 seconds, with 152 qualified samples out of 176.
Separate baseline/final images show the rider carrying the board and standing
on it. The raw sequence-1 receipt nevertheless ended `revoked / unavailable`,
mask `1280`, after 27 press publications and one neutral publication. Its first
failed inspection was `controls_profile_lock / unavailable`; the native clock
was not queried for that rejected assertion. The 250 ms request-to-terminal
interval is not a measurement of press duration. No lock holder or contention
duration was established.

This is an observed target endpoint with an interrupted input transaction,
not another clean roundtrip or proof of broad switching reliability. Native
consumption and semantic causality remain unobserved. Claim release, cleared
report debt, terminal storage and acknowledgement succeeded; no handle was
retained or quarantined. Request/read/store/ack counts were `1/3/1/1`.
`warmup_deferrals` remained `"0"`, and a post-press lock refusal still correctly
stops assertion immediately.

The unchanged guarded driver completed 301 neutral reports, final neutral
release and disconnect. The full terminal storage was archived before Go
within the original gate deadline. No reverse, retry, wipeout, recovery or
follow action was run. After normal Alt+F4, the first process check still saw
shutdown in progress, so the manifest stayed active. A subsequent check found
zero Skate processes before manifest withdrawal. Final storage, runtime log
and the zero-process/zero-active-manifest closure are retained in the session
folder. That session left a profile-lock reliability failure to investigate;
the next section records the subsequent source change and bounded regression.

## Forward regression after narrowing teleport observation

Source `ae81c7924cfdf746768374533cf5cd3feb5b6f26` replaces the broad profile
lock in native teleport observation with the actual narrow queue guard and
opening/closing dispatch checks. Release built cleanly and all 41 focused
CTests passed. This changes readiness observation, not input retry or deadlines.
It does not identify the lock holder in the previous failed trial.

The [fresh one-forward session](../../../../build/bmx/lua-stock-switching-teleport-guard-v1/)
used runtime `9005C91376D141F4DBF2D5AE559BBC1307611558F025A0D0431A3D1E9F46D7EC`
and matched launcher
`7E506E09BE32F4E7E7D48D35D0718F37B4F7A0E8C41707878D99C9290BF67247`.
The binaries were built from the frozen reviewed sources before that commit;
the compiled Git stamp alone does not identify the later source commit.
The process was PID 30756, creation FILETIME `134372726952330594`, with the
supported executable, loaded runtime and guarded neutral controller bound
before the single Arm/request. A fresh private v7 mod/storage identity was used.

The first terminal archive recorded `done / target_observed`, a `released / none`
sequence-1 receipt, rejection mask zero, 50 press publications and one neutral
publication. Request-to-terminal was 312 ms; this is not measured press duration.
Claim release, cleared report debt, storage and acknowledgement succeeded, with
no orphan, retained handle or quarantine. Request/read/store/ack counts were
`1/3/1/1`. The sampled board `100` suffix was 2.5 seconds, with 151 qualified
samples out of 173. Baseline/final images show an upright rider carrying the
board and then standing on it. Native input consumption and semantic causality
remain unobserved. `warmup_deferrals` was `"0"`; no native contention was proved.

Full storage was archived before Go, within the unchanged 45/58/60-second
guards. The driver completed 301 neutral reports, final neutral release and
disconnect. No reverse, retry, wipeout, recovery, follow or BMX action ran.
After normal Alt+F4, process absence was confirmed before manifest withdrawal,
leaving zero active Lua manifests. Final storage later invalidated current
qualification at context generation 6 while preserving historical success,
the original suffix and the terminal receipt. The first qualified result is
an observation at that time, not an indefinitely current qualification.

The independent outcome audit has SHA-256
`4A10C8139647DB73887295C241725A3E332166981CD2BDF004C0FC15CFBD715B`.
The first storage archive has SHA-256
`3A76E4B48086E043CE652BB009FBD1A60C033BD27979594EE3B74DC163B36F36`.
Screenshots are stored at
`E:\RESKATE DEV\reskate\screenshots\lua-stock-switching-teleport-guard-v1`;
raw logs and receipts are also archived under the corresponding `artifacts`
folder on E:. This is one successful stock regression, not proof of broad
switching reliability, a Lua BMX ride or a gameplay likeness score.

## Lua bike visual checkpoint

This is separate from the stock switching results above. Source `334c9c98`
introduced the explicit unmounted Lua diagnostic; `e3c6db54` added one exact
mesh-bounds lookup per tick and trial API breadcrumbs. Full Release and the
integrated plugin suite passed (1/1, 6.06 s): 21 Host scenarios, 2048 authored/COM
comparisons and zero driving calls, with 15 reported skips. The first
private math-fixture run hit the unchanged 50 ms watchdog; its unchanged rerun
passed. These are Host/FakeGame checks, not native riding evidence.

The fresh package `BMX_LuaSpawn_20261023_v2` used runtime
`DEB56DE02629AAE83A36913BB2A90219A1C3DBAC27FD8C3C171E8659B6F66E3F`
and launcher
`81B0D4626A54E3ECDBCE5A22F76208340DB0BD1B4AEE536A23C169EFC93137C1`.
This is a different build from the stock guard regression's `9005C913` runtime
and `7E506E09` launcher. PID 5544 / creation FILETIME `134372760586865999` was
bound before the single explicit spawn; no readiness retry or controller action ran.

The after-close image confirms a recognizable bike frame/front-wheel/handlebar/
seat/crank portion rendered at the left edge, clipped and elevated above ground.
The later first-observation image shows no bike at that location. All eight
exact bounds requests have before/after markers. Create1541-before at
20:43:48.958 and create1542-after at 20:43:49.029 bracket 71 ms. This includes
wrapper/logging/scheduling work and is not isolated native CPU time. The after
marker proves the protected call returned without a Lua error; it does not prove
a nonnil body. Removal then began and the 50 ms watchdog stopped the tick.
No create return arity/reason, body read, release receipt or final spawn status
was retained. Final storage contains only before-remove3, sequence1547.
Visible rendering of a bike portion is proved; chassis success, body measurements, parking
and cleanup remain unknown. Later visual absence does not establish destruction.

Raw files are retained in
`C:\Users\Jeffr\Desktop\reskate\build\bmx\lua-bike-spawn-native-v2` and identically
archived at `E:\RESKATE DEV\reskate\artifacts\lua-bike-spawn-native-v2`.
The [independent outcome audit](../../../../build/bmx/actor-exclusion-proposal-v1/native-spawn-v3-package-v2-independent-outcome-audit.json)
has SHA-256 `6A02EB8A44514F7E8FB910415367FF824D4970600BED0889044DEA4BFC618456`.
Key raw SHA-256 pins are:

| Evidence | SHA-256 |
| --- | --- |
| Integrated `lua-spawn-integration-v2/execution.json` | `C64A27C9F4EA1BBB0CA9CC251AE571CD6901E6BE21A6F94743A8B5C0C9BCB791` |
| `session-final-runtime.log` | `ADE9B9CB6A172A445E371A65BCE9C665F33BC5FE5C9EC7DE80E8745C57454E3B` |
| `first-storage.json` and identical `session-final-storage.json` | `2C96C9AF9C41D7C628E03AB6211929C96C255E808A9D5880BE3223ACB6C45522` |
| `session-shutdown.json` | `60163CB7148CCB0B4CAA2BADF48321DCF07BC3B61F4101800704E2582F48698B` |
| `screenshots.json` | `6F03B5BD672DF10C2F2020B156CB843741CF86E8684954BCDE91E2E8C418E55C` |
| `after-close.jpg` | `0689C36410D50688CA9C2F9DC4B76F55BA16B5F7A4C4355DACEAD00DA7ADDD8A` |
| `first-observation.jpg` | `22DAA8968F55FA369F5D47C68441AA112221B88E757FF78597099652ACCFD091` |

Images are under `E:\RESKATE DEV\reskate\screenshots\lua-bike-spawn-native-v2`.
Normal close, process absence and later manifest withdrawal recorded zero Skate
processes and active Lua manifests. This ends the failed bounded session;
it does not qualify native body cleanup.

Upstream `1949427` is merged as `6aad1bed`. The separate fourteen-path generic
contact checkpoint `2a98eb9c` passed configure/Release, 43/43 focused CTests
in 15.54 s and server configuration 1/1 in 0.47 s on its first build/test attempt.
Its [execution receipt](../../../../build/bmx/contact-integration-v1/execution.json)
has SHA-256 `59370DEDF3272485C1D4E9DB05B97F4329E9D1F623A96308DA42131C93E81D5F`.
That built runtime `5CC87656` and launcher `D149BD35` were not deployed; the
visual evidence above remains bound to `DEB56DE0` / `81B0D462`. No native
contact trial or positive actor exclusion is established. The separate private
first-use SDK setup/create-read-release result proposal passed 22 Host scenarios,
2048 comparisons and 11 Service cases/274 checks with zero native mutations.
Its [private receipt](../../../../build/bmx/owned-body-deferred-initialization-proposal-v1/receipt.json)
has SHA-256 `54B409454607E8C0F291A5F4D62943821AF3F315B73DC13E6B613CC4E9FAD5B1`.
Those private tests preceded integration `43e6d1ef` and the bounded native
chassis result below. They do not independently establish native gameplay.

## Native chassis after deferred setup

Seven-path source `43e6d1ef555698bd64cf3c5fb355ac3e98fa5d5d` moves requested
generic producer initialization to a later eligible SDK tick, outside the Lua
callback and service lock. It queues no owner, definition or body operation;
a later explicit create still requires the original fresh anchor and clock.
Setup does not refresh old readiness and failure remains sticky. The original
50 ms VM budget is unchanged. Full Release and the six focused CTests passed
on the first attempt (0.30 s), followed by plugins 1/1 (5.32 s test time).
The integrated fixtures report 11 Service cases/274 checks with zero native
mutations and 22 Host scenarios/2048 comparisons with zero driving calls.
Fifteen optional plugin fixtures were absent. These tests alone are not native
successful-hook or body evidence.

Fresh package `BMX_LuaSpawn_20261023_v3` used runtime
`7F33A210396719301B6A3843D93D0AA7F62F59C196A2F3CE3E0C16E60611988B`
and matched launcher
`D149BD35EFA00756EE1BD9A8484AD227FFDB50245C083FE62479E7A55CB25E64`.
PID 55440 / creation FILETIME `134372787447790207` was bound to the isolated
supported game and loaded runtime. These binaries were built from the reviewed
source before the source commit; their compiled Git stamp alone does not name
the later commit. Keep this body result separate from the earlier `DEB56DE0`
visual evidence and the `9005C913` stock switching regression.

The first protected create returned `(nil, "waiting for a fresh qualified 60 Hz
physics step")`: `pcall_ok=true`, arity 2, first value nil and `body_returned=false`.
This exact known refusal precedes slot reservation; it does not distinguish
queued setup, anchor capture or clock qualification. One separate explicit
readiness retry returned a userdata with arity 1. The latest read returned a
table with arity 1. Lua adopted 143 valid advancing measured chassis samples,
with all eight visual transform submissions accepted for each, then stopped
because the body left the two-metre spawn envelope. This is an aggregate
adoption/submission count, not 143 archived native snapshots or render receipts.
Stored serial `5452` is the last adopted within-envelope measurement, not the
later out-of-envelope read that triggered the stop.

Release returned one boolean true. Final status is `closed`,
`body_release_attempted=true`, `body_release_accepted=true`,
`visual_remove_requested=true` and `cleanup_unknown=false`. These are the API
and Lua adapter results; a later native parked witness, destruction, slot reuse
and complete visual teardown were not observed. The seven saved images confirm
the readiness/retry/final UI states, but do not show all eight parts rendered
or a continuous body trajectory. No 50 ms watchdog or plugin-budget error
appears in the saved v3 log. No HID/controller input, contact probe, submitted
force, mounted rider, trick or recovery action was used. There is no gameplay
likeness score.

Raw files are retained in
`C:\Users\Jeffr\Desktop\reskate\build\bmx\lua-bike-spawn-native-v3` and identically
archived at `E:\RESKATE DEV\reskate\artifacts\lua-bike-spawn-native-v3`.
Screenshots are under `E:\RESKATE DEV\reskate\screenshots\lua-bike-spawn-native-v3`.
The [integrated execution](../../../../build/bmx/deferred-initialization-integration-v1/execution.json)
binds the reviewed source and binaries. The [independent native outcome audit](../../../../build/bmx/actor-exclusion-proposal-v1/native-spawn-package-v3-independent-outcome-audit-v1.json),
SHA-256 `651BBAE50B0C08FDEF5BEEE192BCD4B6FBE34CCF754BA7F099FF472C4CE1B217`,
pins all raw files and screenshots. Key raw pins are storage
`497283E2CFB58B38B35CD9E899D029261F586142DA1F9704CE693B684852D78D`
and closure `3679D945806151D55779051DFB09F60067BB153B2A13719625FCACE7E1E86808`.
A [second raw-result review](../../../../build/bmx/actor-exclusion-proposal-v1/spawn-v3-raw-review.json)
independently agrees on the arities and proof limits.

Closure records normal shutdown, fresh zero Skate processes and manifest
withdrawal leaving zero active spawn manifests. All eleven C:/E: raw files and
seven screenshot hashes match. This bounded result does not establish the cause or cleanup of
the earlier v2 failure, broad switching reliability, mounted riding, rider
alignment, contact/force composition, fall recovery or the requested 9.5 likeness.

## Owned-self-ray native check

The later [bounded ray session](../../../../build/bmx/owned-self-ray-native-v1/)
used the same `7F33A210` runtime and `D149BD35` launcher as the native chassis
trial, in a fresh process and package. One initial preallocation refusal was
followed by one explicit readiness retry. The accepted 12kg capsule then
produced three counted geometry casts: inside and crossing rays reached the
same world point below it, and an adjacent ray reached a nearby point. The
result reported owned bodies excluded; the complete measured body sample was
unchanged. A separate actor-exclusion request returned
`local_actor_exclusion_unavailable` with zero casts. No force or rider action ran.

Release returned true. Normal shutdown, process absence and subsequent manifest
withdrawal were recorded, with zero active plugin manifests. The
[independent native outcome audit](../../../../build/bmx/owned-self-ray-native-v1/independent-native-outcome-audit-v1.json)
verified the raw C:/E: archive and eight screenshots. This qualifies three rays
at one capsule placement, without distinguishing filtering from native
start-inside behavior. It does not qualify all shapes, local-actor exclusion,
contact normals or surface motion, native parking/destruction, wheel support,
contact forces, mounted riding or likeness.

## Lua input lease and capture build

The general permissioned Lua input lease/capture expansion passed configure
and full Release on its first composed attempt. Plugins passed 1/1 plus
104 relevant input/UI/actor/body and legacy handoff CTests. The Host included
42 input-observation and 46 capture scenarios; fifteen optional plugin fixtures
were absent. The [execution receipt](../../../../build/bmx/input-capture-integration-v1/execution.json)
binds the frozen source, logs and binaries. These are 105 selected CTest passes,
not the entire repository suite or native input evidence.

The built runtime `8F6B51B6` and matched launcher `573BD3BF` have not yet been
deployed. The isolated game evidence above remains on `7F33A210` / `D149BD35`;
native input capture and neutral release remain untested. All BMX behavior
stays in Lua; native changes provide only the general API support required by
that mod. The immediate next check is bounded native capture/release, before
connecting Lua controls to rider attachment and mount/dismount cleanup.
Mounted bike/skateboard switching, rider alignment and fall recovery remain
unfinished, and BMX Streets likeness remains unscored.

The [general API guide](../../../plugin-input-lease.md) documents the input
contract. Existing scripting behavior stays intact; the new BMX mod supplies
the bike policy.

## Remaining checks

These are proposed bounded tests, not completed coverage or new native admission.
Stop on an unexpected refusal, unresolved duty, readiness loss or fall; preserve
the full receipt and require an explicit new Arm for every later experiment.

| Check | Required result |
| --- | --- |
| Fall before SDK dispatch | No SDK request; the armed/baseline attempt stops without retry or qualified transition. |
| Independent visual/body-dynamics fall evidence | Supplement the covered watch-based boundary with an observed physical fall; do not treat the shared watch's state and counter as independent witnesses. |

A fall outside the intended window leaves that interruption case untested.
No automatic GetUp, body following or BMX activation is part of this matrix.
Two stationary roundtrips are concrete progress, not broad switching reliability,
rideable-bike acceptance or a 9.5 likeness claim.

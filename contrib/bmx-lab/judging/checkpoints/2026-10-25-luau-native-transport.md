# Luau native transport checkpoint, October 25

The isolated supported Skate build completed one Luau-controlled owned-body and
zero-command cleanup trial. This qualifies a narrow SDK transport path. It does
not qualify riding or BMX Streets likeness. All BMX behavior in this trial is Lua;
the runtime supplies general permissioned input, body and Follow APIs.

The tested runtime was built from `8d29091a8add8b3f5d21414ffd3b6eab8008d0b3`:

- Runtime SHA-256: `4B7BD8D7C2D256D2C78315624E81FF50E105DFF6169547B324D5414C0D790D66`.
- Launcher SHA-256: `DF0589DB9A2FB1805967B43932A124DFB1F4284EB07FF573A71F574D02C467E6`.
- Both native BMX prototype build options were off.
- The merged checkpoint passed 46 selected normal test groups and five additional
  incoming-change groups. These results precede the later contact-test promotion.

The later contact promotion built the normal plugin target and passed CTest's
`plugins` group, including the exact 48-case/128-assertion Lua contact marker once.
The default 50 ms call and 2 ms average tick limits stayed unchanged. Fifteen
unavailable optional sample mods still earned no pass credit. The first attempt
stopped in an existing cold-import fixture before reaching the contact suite; its
failure remains preserved. After scheduling those imports across ticks, the fresh
run passed. The local result is `D92D5BD656D538BE9DBEBF7153530D009BD2C80DF8A35BD1C25B0C82BE07CACD`
in `contact-normal-host-20261025T061827729Z`. This is constructed Host integration,
not another native gameplay result.

## Observed in Skate

The private Force7 trial used UUID `5c1db549-702c-44ce-a61c-7a37403970a7`.
The controller first completed 301 neutral reports, then a separate 1,001-report
20-second window. Both runs had actual slot-zero neutral readbacks, final neutral
release and disconnect. The existing 120 ms lateness guard remained unchanged.

Lua acquired the observed input stream and capture, created one owned physics
body, and submitted exactly one zero-force/zero-torque command. Its receipt changed
from queued to applied: requested physics serial `140354`, produced serial `140355`.
Follow returned revision `1`, completed, observed a park and was acknowledged.
The force receipt was acknowledged as `parked_without_successor`; input and capture
finished without report debt. Eight visual-removal requests were accepted. No
Board action or equipment pulse was requested. The plugin was then unloaded with
cleanup clear.

These observations do not establish physical response to a nonzero force, engine
consumption beyond the reported setter path, native allocation destruction, rendered
grip/pedal alignment, repeated switching, fall recovery, sustained riding or tricks.
Accepted removal requests do not prove rendered absence. No likeness score is awarded.

## Evidence and remaining work

The local evidence case is `native-force-cleanup-trial-v7-20261025T055804419Z`
on the development drive. Its actual result hash is
`6132EC45E63319AF4563FFE3C967982CD0D5FA90328BCF5DA756810D152E337F`;
terminal storage is `AD17818D3280C53D151077E2CDEA7C76F3F099E90665205588D176D2A0EEA357`;
post-unload storage is `4CE179B0D2077FB6EA17F75B55874806AFAA1E02B6ED46140016539ADD7EDBDF`.
Independent actual-evidence review is `E906C8F6FEDB59AB80B143E1BCA4051A1A931214A9C3A4DA90E04C6D9C03F5F5`,
with post-unload addendum `4A36262B10D44E89585A5F558C7EF5A2B4ED00E579A56BC8D14D39E2FFB190EB`.
Earlier refused attempts remain preserved and earn no native-trial credit.

The later CE1 trial requested a 500 ms Follow interval using the callback-entry
policy and created one new active body. Its controller baseline and separate
20-second window passed. Follow returned revision `30` of final revision `30`,
with no invocation in flight. A screenshot showed the bike beside a standing
rider carrying a skateboard; mounted alignment and riding were not demonstrated.
Input and capture drained without report debt.

CE1 then failed its separate body cleanup barrier: `retained_unknown`,
`pending=[body_parked]`, `park_observed=false`, and no completed acknowledgement.
CE1's sequence-2 cleanup diagnostic records release requested/started and a
captured fence; it does not identify which later World park condition kept failing.
Force7's success does not
qualify cleanup after the callback-entry trial's moving body.

CE1 evidence is in `callback-entry-follow-trial-ce1-20261025T062525536Z` on the
development drive. Retained storage is
`F9470EF47402FEDC6DD3ACA8094B76B0A5D492BC545D7CE45DB0E12C579BD82D`;
post-unload storage is `0BCF322FD08206A01CA3E95F67E897FF02076746C53041E8A84A7E36EBACECBB`.
The exact plugin was withdrawn at 06:38:34Z. Its unloaded snapshot still had no
park acknowledgement. The isolated process was subsequently closed and its exact
PID was absent at 06:40:11Z. Process closure does not establish a successful park
or native destruction acknowledgement. No new body or equipment request followed.

The next live check needs predicate-level park diagnostics and a fresh process
identity. Actor-excluded native contacts, measured nonzero-force response and
rendered rider alignment remain open. The Lua ride activation gates stay off.

The current World backend retains parked allocations and permits only eight
attempted allocations per process. Preparation alone spends no slot; Force7 and
CE1 each created one body. A fresh allocation may be admitted after completed
Follow acknowledgement,
but a parked body cannot be reused. Reliable repeated bike/board cycling still
needs a supported ownership/lifetime path; resetting counters or reviving retained
bodies would not establish one.

## CE2 startup attempt and ordinary close

CE2 did not reach a native bike trial. Its isolated owner was PID `54692`, creation
FILETIME `134373859556082181`, using diagnostic runtime
`3B25624D2E0C104DDA935C2A47D21A1087CCF44E91776A112DC22F44B101DB09`.
At 03:13:11 local time, Follow startup failed because its 25-character page title
exceeded the Host's 24-character limit. That call precedes tick registration.
The one-file correction shortened the title to 19 characters; all other 13 package
leaves stayed exact. Host reloaded it in the same process at 07:24:49Z, and its
page was visibly idle with no Follow receipt. This was a title-only hot reload,
not a fresh cold lifetime or native policy qualification.

One ordinary MPR reload reached level-content-active at 03:23:43 local time.
The saved log's multiplayer counters reported zero session players/skaters; those
counters do not establish local actor absence. Separately, no subsequent skater-
factory construction event was observed. The screen still showed “Loading…” after a
completed controller baseline. That baseline delivered 301 scheduled neutral
reports over six seconds, following its declared one-LSB bootstrap and two exact
slot-zero neutral samples, then final neutral release and disconnect. Its ledger
reports no issue and leaves input consumption unknown; it does not establish
gameplay readiness or explain the stalled startup.

V3 actually failed its static source scan because bind-attempt.ps1 was omitted.
Source review then found that V3/V4's Int32-only lineage contract would reject
persisted Int64 indices; Root did not run admission under either version.
V5 accepted exactly Int32 or Int64 line indices with the same ordering checks.
Its actual constructed title-contract suite, including a JSON roundtrip, passed
30 cases/32 checks; the unchanged pure suites remain separate from gameplay.
The same-owner title-reload lineage was admitted, but Root confirmed no Prep or
Follow Arm and no native bike trial. Both known CE2 storage locations for each
package were recorded absent before close.

The exact process received an ordinary close request at 07:33:40Z and was recorded
absent at 07:33:48Z, with no forced termination. The log records Shutdown [25].
This closes a stalled startup lifetime; it is not a park, cleanup acknowledgement
or native destruction result. No riding, switching, alignment, recovery or likeness
score is demonstrated. The separate six-case actual-Service operator remained
unexecuted at this first case's closure. The preceding observations concern only
the lifetime ending at 07:33:48Z.

The preserved case is `ce2-stalled-startup-20261025T073340674Z` on the development
drive. Exact-owner closure hash:
`B82178D681DA0CA429372663CD158FCC9DD30AC77DBF5231C63700E6D8229AFF`.

Separately, a later cold lifetime, PID `13400` / FILETIME `134373874322929113`,
loaded both plugins without the title error but still showed MPR “Loading…”; Root
confirmed no Prep/Follow Arm or controller test in that lifetime. Its exact PID was
recorded absent after ordinary close at 07:43:28Z in
`ce2-second-stalled-startup-20261025T074323161Z` (closure hash
`8D7063DA50BA4BCD74D6A44C739E462DA4E2E97D70C008352C0E12BDDDD28C41`),
which establishes startup-process closure, not a native bike trial or park/ACK result.

## CE2 profile boot and first-baseline failure

A further no-map/default-boot lifetime, PID `51088`, also stalled and was ordinarily
closed at 07:52:53Z without Prep, Follow Arm or a controller trial. Its closure is
`1538C3F02D5BDD17D7CD5C57211C758D24090351B505CED6034F4EC187E033FE`.
The launch helpers had omitted `RESKATE_BMX_LOCAL_PROFILE=1`, which the existing
guarded isolated-profile adapter requires. Root set it only in the next helper's
child environment; no runtime code or global environment setting changed.

That next owner was PID `63876`, FILETIME `134373886098290746`, with the same
`3B25624D…` runtime. Its log records the isolated profile path accepted and native
storage configuration returning 0. After ordinary SDK travel to MPR, a skater
factory returned at 03:59:55 local time (07:59:55Z); Root reported a controllable
on-foot skater, and the saved screenshot shows the skater carrying the board.
This sequence does not establish a matched causal test of all earlier stalls.

Root armed Prep once. Its sampled page reached ready after 3 of at most 20 calls;
that is setup readiness, not a mounted bike or Follow result. Follow was never
armed and no bike body was created in these observations. The first neutral
baseline failed after 11 reports on the unchanged 120 ms scheduler-lateness guard.
The checked monotonic QPC path distinguishes that failure from clock reversal;
the cause of the scheduling delay is unknown. Final neutral release and disconnect
both succeeded, but the attempted baseline did not pass.

No graphics settings were changed; saved Uncapped values do not measure effective
frame rate. The history here stops at the preserved first-baseline failure in
`ce2-first-baseline-lateness-20261025T081608834Z`; it includes no later scheduling
experiment, native bike trial, park/ACK, riding or likeness score.

## Later CE2 attempt: completed Follow, park and acknowledgement

A later attempt used the same PID `63876` / FILETIME `134373886098290746` and
runtime. Only the owned controller children were prospectively assigned AboveNormal
priority, which was read back before bootstrap and the first scheduled reports.
The baseline completed 301 reports; the separate 20-second gate completed 1,001.
Both reported final neutral release and disconnect, and Root observed both owned
children exit. The unchanged 120 ms lateness guard stayed active. This is one
successful scheduling attempt, not proof that priority caused the improvement.
The first failed baseline remains preserved.

CE2 then reached Done / Completed + ACK: final and returned revision `31`,
`in_flight=0`, terminal true, park observed and acknowledgement true. The first
cleanup diagnostic reported `clock_serial`; that was an initial observation,
not a persistent terminal failure. The later completed receipt is the outcome.
It does not resolve CE1's different lifetime or prove native history erasure.

The source drained with both cleanup-pending and cleanup-unknown false, no report
debt, 172 outer-XInput-buffer publications and 42 renewals. Lua recorded one body-create call.
Eight visual-removal calls were accepted. Root's saved view shows the standing
skater carrying the board with no bike visible in that view; this does not prove
absence outside that view, native body destruction or erased native history.
The receipt still reports native_retirement_known=false.

At this pre-board snapshot, no Board action had been requested. A Board trial
remains a separate explicit gate. No mounted riding, rider alignment, repeated
switching, fall recovery or BMX Streets likeness score is demonstrated.

The actual result is `priority-attempt-result-v1/actual-result.json` in the CE2
case on the development drive, hash
`90CCD00C3E4644EC12BAB2D82C2DD2E55EA72CB06ECEA038DCEE3C3F8375470B`.
Pre-board storage hash:
`B72E63A6B0485C6C066A11F6EF0E0995E9CDEADE2D38F27D204226CC42E570AF`.

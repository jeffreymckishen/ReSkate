# Follow supplied-lane native checkpoint — 2026-10-24

The new native observation identified the first non-finite copied supplied lane:
zero-based index 15, classified `fourth`. Actor inspection qualified, but no follow
target was committed. The native meaning of that word, whether it is harmless
padding, and any appropriate contract change remain unproved. The prior
[first-fault checkpoint](2026-10-24-follow-first-fault-native.md) remains historical.

Recorded source is `c7577fa206aa502769f0f214b6ef3846d3cc79a1`, runtime
`7AE57F2B6E9BBB73E14E58F111E17D89A3B402250B521E571809ABB35040A90C`.
The isolated game process was `17212`, creation FILETIME `134373240161240678`.
Loaded module-path/disk identity does not supply an in-memory image hash.
BMX behavior remains Luau over generic SDK APIs.

## Build and constructed validation

[Completed validation](../../../../build/bmx/follow-supplied-lane-integration-v1/validation-complete.json)
`FC47803C` records normal Release exit 0 and six of six focused CTest groups passing
in 6.62 seconds. The [actual-source case summary](../../../../build/bmx/follow-supplied-lane-fixture-v1/case-execution-v1/summary.json)
`2688FDF8` records 34 passed cases / 486 checks and zero failed cases. These are
constructed validation, separate from native gameplay.
The commit receipt reconciles the exact three source contents with their precommit
build pins; generated Git metadata may name the earlier document checkpoint.
An initial receipt-summary parser refused after successful CTest; correction read
the unchanged log without rerunning those tests.

## Controller and native observations

The retained [neutral baseline](<E:/RESKATE DEV/follow-supplied-lane-native-v1/controller-baseline/controller.jsonl>)
and [attachment timeline](<E:/RESKATE DEV/follow-supplied-lane-native-v1/controller-gate/controller.jsonl>)
each completed 301 scheduled reports with successful neutral release/disconnect.
The operator record reports no screenshot during the actual timeline and a
successful text-only refresh after GO. A text-only refresh also completed around
the baseline operator run; its exact overlap with scheduled reports was not
recorded and is not claimed. Native input consumption remains unobserved.

The [preclose result](<E:/RESKATE DEV/follow-supplied-lane-native-v1/preclose-result.json>)
`C5A1FD12` and raw log record one body creation/read, one reserve, one publish,
`published_seen=true`, 335 follow reads, eight bounds calls, 16 visual transform
sets and eight accepted visual-remove calls. Rendered absence was not established.

The immutable first-stop record is `origin=dispatch_prepare`,
`stage=supplied_finite`, `supplied_failed_lane=15`, `supplied_lane_class=fourth`,
with `actor_stage=inspect_first`, `actor_phase=qualified`, `actor_reason=none`.
Final and returned revisions were both 0. This records the first failing lane of
the existing finiteness check before body remeasurement or target commit;
`fourth` is a diagnostic classification, not native ABI or padding semantics.
The client-side log-drain thread tag does not identify the originating callback thread.

The separate first-cleanup record is `origin=observe_park`, `stage=park_observe`,
with actor inspection qualified, fence present, release hold absent, and internal
release requested/started. Its `supplied_failed_lane=16` / `unknown` is the sentinel
for no observed supplied-lane failure in that cleanup call, not a failure at lane 16.
World park observation remained unresolved. The later receipt's
`park_reason=native_lifetime_changed` is separate from both immutable records.

The final receipt remained `stopping`, `pending=[body_parked]`, `claim_known=true`,
`park_observed=false`, with final revision/native epoch/returned revision all 0.
Selected input capture/lease cleanup completed with 47 outer-buffer publications,
one neutral release and no remaining report debt. Semantic consumption is still
unobserved. Follow ended `retained_unknown` without ACK; Lua made no ordinary body
release after handoff, while the native cleanup record shows internal release progress.

## Evidence recovery and closure

The sealed archiver copied the preclose storage and log snapshots, then live-log
hashing hit a sharing violation. A separate recovery preserved those snapshots,
copied the closed controller ledgers and hashed private copies. It neither edited
the sealed archiver nor retried the game trial. The recovered result retains this
failure and recovery explicitly.

[Closure](<E:/RESKATE DEV/follow-supplied-lane-native-v1/closure.json>) `56390A68`
records normal Alt+F4, SDK Shutdown25, an absent game window, and zero game processes,
controller processes and active trial manifests. Actual pre/post-close storage
hashes match `01A882AD`. All ledgers and snapshots remain on E:.
Process exit does not prove native parking or retirement.

SDK park completion, claim/native pose-history retirement, riding, reliable
bike/board switching, rider alignment, fall recovery and the requested 9.5 BMX
Streets likeness remain unproved.

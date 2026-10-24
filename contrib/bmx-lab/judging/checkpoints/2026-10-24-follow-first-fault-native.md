# Follow first-fault native checkpoint — 2026-10-24

The new diagnostic identified the first native follow stop: preparation refused a
non-finite supplied matrix before committing any follow target. Actor inspection
had qualified. Cleanup separately reached World park observation, but successful
parking, retirement and ACK remain unproved. BMX behavior remains Luau over generic SDK APIs.

Recorded source is `3e235d110fe91384c01798e0b1b80a3eb50eceed`, runtime
`931DEC6EEE0217F3EF1C7126C7920BB3D76F00464AC107360F2C6BBACF9826FF`.
The successful controller/native attempt used the isolated game process `11224`,
creation FILETIME `134373217423176564`. Module-path/disk identity is not an in-memory hash.

## Build and constructed validation

[Normal validation](../../../../build/bmx/follow-first-fault-integration-v1/normal-validation.json)
`4A67A1AE` records Release exit 0 and six of six focused CTest groups passing.
[Completed actual-source validation](../../../../build/bmx/follow-first-fault-integration-v1/validation-complete-v1.json)
`F1578066` records 32 passing cases / 430 checks: 26 existing cases / 334 checks
plus six diagnostic cases / 96 checks, with no retry or timeout. These constructed
cases establish diagnostic behavior, not native gameplay. The commit receipt
records the same source contents as the precommit build pins.

## Preserved failed attempts

The first [operator-gate attempt](<E:/RESKATE DEV/follow-first-fault-native-v1/attempt1-timeout-result.json>)
`15D0656F` expired before close/go: zero scheduled scenario reports, zero bodies,
no capture/reserve/publish. A separate raw bootstrap input is recorded; zero scenario
reports does not mean no earlier input. Neutral release and disconnect succeeded.

The [second attempt](<E:/RESKATE DEV/follow-first-fault-native-v1/attempt2-preclose-result.json>)
`A92AF119` stopped on scheduler clock/lateness refusal after 24 neutral reports.
The Lua 600 ms readiness window was reached and capture was attempted; this was
not a refusal before 600 ms elapsed. No body was created and no follow reservation
or publication was attempted. Capture cleanup retained report debt and ended
`retained_unknown`; neutral controller release/disconnect did not prove capture
completion. [Closure](<E:/RESKATE DEV/follow-first-fault-native-v1/attempt2-closure.json>)
`C9EDEDD5` preserves normal exit and withdrawal without claiming debt was semantically cleared.

## New process: controller completion and native first fault

The [baseline](<E:/RESKATE DEV/follow-first-fault-native-v2/controller-baseline/controller.jsonl>)
and [actual attachment timeline](<E:/RESKATE DEV/follow-first-fault-native-v2/controller-attachment-trial/controller.jsonl>)
each completed 301 scheduled reports plus successful neutral release/disconnect.
No screenshot was taken during the actual timeline. The cause of the earlier
lateness is unproved; this successful timeline does not establish that screenshots
caused it. Native input consumption and physical-device identity remain unobserved.

The [native result](<E:/RESKATE DEV/follow-first-fault-native-v2/preclose-result.json>)
`1248F195` and retained log record one body creation/read, eight bounds calls,
16 visual transform sets, one reserve, one publish and `published_seen=true`.
There were 333 follow reads and eight accepted visual-remove calls.

The immutable first-stop record is `origin=dispatch_prepare`,
`stage=supplied_finite`, `actor_stage=inspect_first`, `actor_phase=qualified`,
`actor_reason=none`, with public reason `unavailable` and final/returned revisions 0.
It places refusal at the copied supplied matrix's finiteness check before body
remeasurement or target commit. The failed lane index was not captured; a padding
or ABI explanation remains unproved. The log's thread tag belongs to client-side
diagnostic draining and does not identify the originating native callback thread.

The separate first-cleanup record is `origin=observe_park`, `stage=park_observe`,
with actor inspection qualified, fence present, release hold absent, and internal
release requested/started. This establishes more cleanup progress than Lua's
ordinary-release flag exposes, while `park=false` leaves successful park unproved.
The later receipt's `park_reason=native_lifetime_changed` is a separate observation;
it does not replace either immutable first-fault record.

The final receipt remained `stopping`, `pending=[body_parked]`, `claim_known=true`,
`park_observed=false`, with final revision/native epoch/returned revision all 0.
Input capture/lease cleanup completed. Follow ended `retained_unknown` without ACK;
SDK parking, claim retirement and native pose-history retirement were not demonstrated.

## Closure and remaining goal

[Closure](<E:/RESKATE DEV/follow-first-fault-native-v2/closure.json>) `D01ABBEE`
records normal Alt+F4, SDK Shutdown25, and zero game processes, controller processes
and active trial manifests. Actual pre/post-close storage copies match `FD5FAC32`.
All failed/successful ledgers, logs and closure records remain on E:. Process exit
does not prove native parking or retirement.

Riding, reliable bike/board switching, rider alignment, fall recovery and the
requested 9.5 BMX Streets likeness remain unproved. This checkpoint narrows a
refusing native guard; it does not establish a mounted or playable BMX bike.

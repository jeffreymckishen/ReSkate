# Lua first-follow native checkpoint — 2026-10-24

Native preparation reached sampled readiness; the first follow trial reached
body creation and accepted target publication. A native follow pose, successful
parking/retirement and a ridden BMX bike were not demonstrated.
Recorded source was `9a9788b3`, runtime `B812D53D`, launcher `9191A1C5`, PID `24136`.
Exact process creation FILETIME was `134373169694117563`; module-path/disk identity
does not supply an in-memory image hash. BMX behavior remains Luau over generic SDK APIs.

## Constructed Host validation

The thin preparation [Host receipt](../../../../build/bmx/body-prepare-lua-host-validation-v1/receipt.json)
`731EEFFE` passed six constructed timelines. Corrected first-follow
[v2 Host validation](../../../../build/bmx/first-follow-lua-host-validation-v2/receipt.json)
`9C5641E2` passed eight groups / 35 scenario invocations / 23,408 runtime assertions.
These execute the actual Host/VM with constructed leaves, not native gameplay.
Original v1 [compilation](../../../../build/bmx/first-follow-lua-host-validation-v1/compile-receipt.json)
passed, but its [run failed](../../../../build/bmx/first-follow-lua-host-validation-v1/run-receipt.json)
on missing expected fixture storage, diagnosed as lost Arm; that failure remains historical.

## Actual preparation and first follow

Preparation attempt 1 preserved `arm_timeout` with zero prepare calls.
The separate [attempt 2 result](<E:/RESKATE DEV/body-prepare-native-v1/attempt2-result.json>)
`B7505321` records pending at logged local `08:06:45.123`, then sampled ready at
`08:06:45.224`: 101ms between log lines, with UI showing `2 / 20` calls.
This is sampled producer/client/clock readiness, not reserved capacity or future allocation proof.

The actual [first-follow result](<E:/RESKATE DEV/first-follow-native-20261024-v1/preclose-result.json>)
`A8051AAF` and raw ledger record one body creation/read path, eight bounds calls,
16 visual transform sets, one accepted reserve and one accepted publish,
with `published_seen=true`.
The final receipt retained `final_revision="0"`, `final_native_epoch="0"`,
`park_reason=native_lifetime_changed`, `pending=[body_parked]`, and `park_observed=false`.
These labels establish neither a native follow pose nor the stop's source cause.
No ACK occurred; the cleanup watchdog ended in `retained_unknown`.
No ordinary body release was attempted after handoff to follow ownership.
The receipt does not expose SDK internal release or park-fence progress. Actor
cleanup checks can fail before or after World work; the park reason identifies
neither the initial stop nor whether internal release/park was attempted.
Selected input capture/lease cleanup completed, independently of unresolved follow cleanup.
Eight visual-remove calls were accepted; rendered absence was not established.

## Guarded controller evidence

The [first session](<E:/RESKATE DEV/first-follow-native-20261024-v1/controller-attempt1-rounded-time-refusal/controller.jsonl>)
refused before input, with zero reports: CIM rounded creation `.4117563` to `.4117560`
(300ns). The [second session](<E:/RESKATE DEV/first-follow-native-20261024-v1/controller-attempt2-and-actual-follow/controller.jsonl>)
used exact GetProcess/StartTime FILETIME `134373169694117563` with unchanged guards
and driver source `28AA47D7`. It completed 301 scheduled neutral-follow reports,
then final neutral release and disconnect-wrapper success. Native input consumption
and physical-device identity remain unobserved.

## Persistence and closure

The same game/tool account, `JEFF\Jeffr`, used actual global storage at
`C:\Users\Jeffr\AppData\Local\ReSkate\Plugins\LuaFirstFollow_20261024_v2a\storage.json`.
The namespace was absent before Arm, with no storage warnings. Actual disk reads
matched [pre-close](<E:/RESKATE DEV/first-follow-native-20261024-v1/preclose-actual-storage.json>)
and [post-close](<E:/RESKATE DEV/first-follow-native-20261024-v1/postclose-actual-storage.json>)
copies (`A123B855`); cache-call acceptance alone is not this persistence evidence.
[Closure](<E:/RESKATE DEV/first-follow-native-20261024-v1/closure.json>) records overlay close,
normal Alt+F4, SDK Shutdown25 and zero game/controller processes and active manifests.
Exactly `LuaFirstFollow_20261024_v2a` and `LuaBodyPrepare_20261024_v2` manifests
were withdrawn. Process exit does not prove body parking or native retirement.
Original evidence and storage remain retained; the Steam installation was untouched.
The isolated B812/9191 pair remains, with the older D022/2D18 rollback preserved on E:.

The stop's source cause remains under investigation. Riding, reliable bike/board
switching, rider alignment, fall recovery and the requested 9.5 BMX Streets likeness
remain unproved; constructed tests and accepted publication do not supply that evidence.

# Inactive Core, Source and Ride composition

This package combines the reviewed Core/Source v3 pair, the dormant Ride coordinator and the corrected quaternion alignment module. Core's `RIDE_COMPOSITION_QUALIFIED=false` and Ride's `ACTIVATION_QUALIFIED = false` remain literal source gates. There is no public option to open them. Public Mount is denied before game API calls; the existing private500ms exact-zero, zero-force qualification path remains separate. Main, entry, package README, manifests and permissions are unchanged. The manifest still lacks `world.raycast`.

Core owns Source construction/arm/step/stop, the SDK body, Follow, stock switching, equipment, visuals and overall cleanup. Ride is subordinate: it receives Core's exact successful Source step frame and the same actual body-read sample used for Follow, owns pure model cadence and one bounded force transaction, and cannot acquire or replace those owners. Alignment produces requested targets only. Recovery remains default inactive and stop/suppression-only in this seam.

## Current selected-input authorization

`Source:authorize(exact_last_successful_step_frame)` validates the exact private frozen table issued by the latest successful ordinary Source step. Equal copied fields, a status DTO, an older frame or another Source cannot create a publication token. An ordinary step clears the old token before native callbacks; stop invalidates it before release. Busy/reentrant operations refuse.

An eligible authorization performs at most three existing selected-handle reads, in order: `lease_read`, `lease_state`, `lease_capture_state`. They must still describe the same selected user/sequence/source epoch/context, an active captured lease and the original capture generation without quarantine or orphaned/released duty. Exact decimal uint64 and monotonic receipt validation remain. New native publications may confirm the live stable stream, but authorization does not adopt their pad/actions/opaque epoch, renew the lease, advance a model cursor or perform another body read. Only ordinary Source step adopts the next input report. Existing read APIs may themselves discover and revoke invalid native state.

Core runs fresh readiness and Follow callbacks, then Source authorization, then its final finite clock sample and pure local owner checks before probe or submit. It checks again after each effect. The maximum added input-read budget is12 calls for pre/post probe plus pre/post submit in a full fresh body observation; a pending force can still run probe/model cadence with up to6. An early refusal does less. The final sample includes time spent authorizing within the existing500ms boundary.

These are sequential sampled checks, **not an atomic native selected-lease/body transaction**. Native authority can change after the final read/clock and before SDK entry. No alternating guard loop, rollback or native consumption proof is supplied. Whole-Host/native timing for the additional calls is unqualified.

## Cadence and model boundaries

Source identity and native input observation times remain canonical decimal strings, independent from Lua wall time and physics time. Ride stages at most32 ordered source observations over100 native input milliseconds. It consumes at most one queued observation on a real consecutive body step, preserving a non-hop selection followed by neutral release. A bounded older consumed model input is not restamped as the newest native report. Higher source cadence that overflows the FIFO stops; no coalescing, dropped-edge or synthetic-dt policy is added.

Each fresh body sample builds immutable Frame v1, performs one current actor-excluded contact query, decodes contacts, and runs the selected models. Duplicate/changed/regressed samples refuse; pending command receipts do not hide new real body samples. Measured serial consumption occurs before callbacks so reentry cannot retry that serial. Frame body/source/incarnation bindings are private correlations, never caller-supplied native authority.

Ride's four force capabilities are closed over one exact original body/Core incarnation: probe, submit, receipt and ACK. A late accepted submit after reentrant stop retains the actual admitted sequence before the post-check stops the owner. It is not rewritten as clean refusal. Receipt and ACK continue to use that original body and sequence after stop, unload or Follow clearing Core's current body field. One command may be pending; unknown admission/receipt/ACK remains debt, including cases with no returned sequence.

SDK `applied` receipts describe their existing setter/receipt protocol. They do not establish physical consumption. Applied cleanup still requires a real coherent later native successor; stop cannot manufacture one. Cleanup can validate a real later successor outside the stricter drive gap without advancing skipped model steps. Partial writes and their uncertainty remain retained. ACK is attempted at most once and positive ACK clears only the exact force transaction, never Core's independent body/Follow/park duty.

## Stop and retained cleanup

Stop latches Core generation and Ride's pure terminal stop, stops Follow immediately, then permits Source/capture release through the existing proxy. It does not defer Follow stop to wait for a force successor. Both local force ledgers must clear together with all existing independent Core duties before ordinary body release, visual removal, aggregate done, stock handoff or rearm. Follow completion, retained allocation flags and a future rig witness cannot erase force debt.

Immediate native stop can leave an applied command without a later successor indefinitely unresolved. The separately proposed SDK force terminal-retirement marker/API is **not consumed by this Core/Ride composition**; no new marker, caller boolean or fabricated disposition closes that debt. No rig/alignment/recovery retirement authority is introduced.

## Missing native truth

Wheel rays and ray-derived force rows are authored geometry policy. A hit is not a native collision-support witness. Actual Contact keeps support unknown and `force_ready=false`; actual BFAF Trick refuses before submit. Positive support used in pure coordinator tests is explicitly constructed model policy. Actor exclusion remains a real prerequisite; there is no `exclude_local_actor=false` fallback, skipped nearest hit or invented ground. Clear rows do not invent planes, points, surface motion or tire support.

The quaternion correction normalizes interpolation operands and measured/calibration roots, including exact normalized measured-root preservation at zero angular cap. It does not provide coherent actual rig sampling, native bone mapping, absolute pose application or retirement ACK. Recovery similarly lacks the required general actor/session observation and native dispatch/cleanup truth. Those gaps block riding and recovery regardless of the pure model results.

## Evidence boundary

The final package's source pins and fresh raw pure-Luau execution receipt are held by the composing artifact. Core seam fixtures explicitly substitute Source/Spawn/Admission/Equipment and no-effect Trick; the separate Source and default whole-module suites run their actual modules with constructed SDK rows/services. Any lexical gate-qualified test copies exist only in verification scratch. The shipped package retains both false gates.

A separate Root-owned native body1 cleanup result and a failed controller trial are distinct evidence. They are not executions of this new composed Lua package and do not establish reliable controller input or riding. This package makes no SDK Host, normal-build, native contact/command-consumption, actual rig, fall-recovery, gameplay parity or9.5 BMX Streets likeness claim. Root owns final review, promotion and later appropriately scoped native validation.

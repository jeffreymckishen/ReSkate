# Lua contact and input checkpoint — 2026-10-24

Source checkpoint: `b3edf3ae6c165c0a2294656805f4520327ddd850` on `BMX`.
All BMX behavior stays in Lua; native changes supply general API support.

## Offline implementation and checks

- [Measured-contact Host](../../../../build/bmx/measured-contact-host-integration-v1/execution.json):
  20 constructed cases in the normal plugin suite, 1/1 CTest passed in 5.39s.
- [Passive-sync Host](../../../../build/bmx/passive-sync-host-integration-v2/execution.json):
  15 constructed cases, normal plugins 1/1 passed in 5.44s. The first build's
  const test-helper failure is preserved; only that fixture helper was corrected.
- [Input deadline fix](../../../../build/bmx/input-grind-publication-integration-v1/execution.json):
  full Release and **85 total selected CTests** (`input|plugins`) passed in 6.79s,
  including six normal regression groups / 353 checks using actual setters and
  the broker. Host cases and assertions above are not additional CTests.

Two general deadline expressions now keep identical disabled grind-turn/lean
maintenance calls from falsely revoking leases as time advances. Changed
arguments and active renewals retain existing invalidation behavior. The
[private attempt-4 review](../../../../build/bmx/input-lease-native-refusal-review-v1/test-link-proposal-v4/execution-review-v4.json)
confirms the unchanged original failed the exact intended assertion:
`input capture native: repeated inactive actual setter does not invalidate publication authority`.
The first three failed private build attempts remain archived. Fifteen unrelated
optional plugin fixtures were absent; no broader repository test total is claimed.

The new matched runtime/launcher `8E3FA8FE` / `61344FF0` is qualified by these
offline checks only. The caller behind the earlier native `interference`
incident was not observed; this source defect does not establish its cause.

## Native measured-contact result

The [independently audited trial](../../../../build/bmx/measured-contact-native-v1/independent-native-outcome-audit.json)
passed one three-ray batch with `require_contact=true` at one 12kg capsule
placement. One exact preallocation refusal preceded one explicit readiness retry.
Original sample serial `2081`, time `34.68333126604557`, and all stored numeric
before/after sample fields matched. All three contacts returned measured normals
and measured-computed point velocities `(0,0,0)`; zero is not a static-world
classification. No force, torque, impulse, HID, rider-follow or equipment action ran.

This used the **older** runtime `AFA3C80D` / launcher `8EA93F3C`, bound to source
freeze `EA7DDB4C` and [execution receipt](../../../../build/bmx/passive-observer-integration-v2/execution.json)
`FEBC89BF`. It is not game evidence for the new input-fix pair. Actor exclusion
was explicitly false. Endpoint actor clearance, nearby hits and matched normals
do not prove whole-actor exclusion, a safe wheel footprint or all shape types.
SDK release returned true; no later native park, destruction or reuse was observed.

[Closure](../../../../build/bmx/measured-contact-native-v1/closure.json) records normal
shutdown, process absence and subsequent exact manifest withdrawal, leaving zero
active manifests.
Actual persisted storage and full logs are retained. The [archive record](../../../../build/bmx/measured-contact-native-v1/archive-location.json)
binds the verified E: archive and nine screenshots moved after hash verification.
The independent audit preserves signed-zero/opaque-epoch and sampled-read limits;
rendered UI alone does not measure contacts or establish native cleanup.

## Current gates

The next native input-capture preparation is pending; the new input pair has no
game qualification yet. Passive native mapping awaits that input priority.
Its 15-case Host result supplies no retail packet or consumption witness.
The [28-path follow-service composition](../../../../build/bmx/general-follow-service-composition-v1/handoff-receipt-v1.json)
is source-only: full composed validation and exact copied-target retirement
remain unqualified. A passive `observed` result or equal pose cannot close that gap.
Actor exclusion is still unavailable. Lua mounted riding, reliable bike/board
switching, rider alignment and fall recovery are unfinished. BMX Streets likeness
has no score; the requested 9.5 target remains unmet.

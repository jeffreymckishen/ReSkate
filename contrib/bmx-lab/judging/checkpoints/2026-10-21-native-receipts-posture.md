# Native receipts and optional coupled posture checkpoint

Parent: `4ede3bc3700551fa8b09ba62b80c24eaed60d73e`.

The ordinary chassis now requires the exact next native-body observation and
producer receipt before advancing controller state. The separately selected
paired experiment can apply calibrated neutral-relative hip/chest deltas, with
existing ownership, contact and anatomy rejection retained. Ordinary paired
backend adoption remains closed and this posture option defaults off.

Three reviews found no commit-blocking defect in the frozen checkpoint:

| Judge | Independent scope | Engineering result | BMX Streets likeness |
| --- | --- | --- | --- |
| integration_architecture | Native receipt and optional posture | Correctness 8.5; architecture 9.0 | Unrated |
| physics_review | Optional posture and selector helper; receipt author re-review excluded | Posture 9.0; selector 9.5; regression confidence 9.0 | Unrated |
| checkpoint_judge | Fresh review of the complete frozen checkpoint | Correctness 9.0; regression confidence 9.0 | Unrated |

The archived reviews and source pins are in
`build/bmx/overnight-review20261021/`. They include author-independence boundaries.
The native receipt has 31 focused checks; posture fixtures cover enabled and
compile-disabled integration. The pre-diagnostic Release build passed all 87
CTest fixtures. Flat run 279, repeated switches 281, fall/GetUp/remount 283, and
console interruption/retry 284 remain separately bound native evidence.

The 9.5 likeness target is **not achieved** by this checkpoint. Native paired
posture footage, broader riding/trick/landing coverage and controller handling
remain required under `rubric-v1.json`. The later installed BMX Streets binary
also differs from the October 18 reference; its method identities are being
refreshed before new reference-derived changes. The new stationary diagnostic
and controller recovery experiment are excluded from this checkpoint.

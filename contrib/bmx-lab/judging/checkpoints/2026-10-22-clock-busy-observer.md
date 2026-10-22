# Bounded observation pause after a completed switch input

The forward human switch observer can now pause for a typed native clock mutex
BUSY result after its one input pulse has finished. It performs no input retry,
selector write or new native-state acceptance while the clock is unreadable.
Other read failures, changing owners, device/source loss, activity, focus/menu
changes and cleanup counter/lease changes remain terminal.

The pause is bounded by the original fifteen-second deadline and strictly less
than 250ms from the last coherent time-feed observation. That timestamp comes
from the successful clock read's existing mutex; caller sample time cannot renew
it. The adapter includes its lock-wait time in the refusal check. A BUSY frame's
unknown physics never replaces the last accepted native sample.

Every pause interrupts the current native100 dwell and invalidates callback
readiness. A later fully validated coherent sample must start a fresh complete
2.25-second native and wall dwell. Previously observed native103 remains required;
a missing103 cannot be invented. Reports distinguish historical first100 from
the current qualifying dwell and retain the first BUSY refusal's actual evidence.

Production MSVC build passed. The full configured suite passed 95/95 in32.80s;
the subsequently extended handoff test passed 1,502 assertions with MSVC. The
independent [architecture review](../../../../build/bmx/overnight-review20261021/human-clock-busy-production-architecture-judge.json)
accepted the six production-file pins. A separate [test review](../../../../build/bmx/overnight-review20261021/clock-busy-independent-matrix-review-v1/independent-test-judge.json)
ran 28 additional checks, including fresh-feed absolute expiry, first-refusal
retention and an unread103 field. Those cases are now also tracked regressions.

This is a general observation-resilience change. It does not establish the causes
of the earlier293 callback-state failure or294 confirmation failure. Native
regression and actual BUSY-path observation remain separate from these source and
unit results; no BMX Streets likeness score is claimed.

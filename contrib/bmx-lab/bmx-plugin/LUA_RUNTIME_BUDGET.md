# Lua runtime work and budget boundary

The current inactive Core/Source composition retains the reviewed diagnostic optimization: each diagnostic snapshot gathers one locally cached Source/Spawn/Equipment status, uses it only inside that snapshot, and makes one whole-tree copy of its source subtree. Retained source-step records still copy independently. Ordinary authority checks continue to read current status; no diagnostic cache survives a call, tick, exception or actuator callback. Fixed private validation-key arrays are allocated once per module.

Diagnostic finite-number,1200-character string, depth and3000-field limits remain. Opaque nested values fail closed and whole snapshots remain detached. JSON preflight, storage writes, persistence cadence, first-marker handling and permissions are unchanged. No VM budget or timeout was relaxed.

Core/Source v3 adds a separate fresh authorization cost when the dormant force seam is tested with qualified scratch copies. Each Source authorization can call `lease_read`, `lease_state` and `lease_capture_state` through the selected existing handle. Four pre/post probe/submit guards can add at most12 such input reads per fresh body observation; probe-only cadence while force debt is pending can add up to6. Ordinary Source step and once-per-new-report renewal remain separate. Authorization does not adopt model input, renew, read another body or mint native authority.

The final clock is sampled after authorization, including its elapsed time within the existing500ms qualification boundary. This is sequential sampled validation, not an atomic lease/body transaction. The additional Host/native call cost and the whole plugin's startup/tick budgets remain unmeasured by this package's pure CLI tests. No50ms pass, latency speedup or cause for an earlier timeout is claimed.

Prior isolated diagnostic operation counts are historical component evidence; they are not timings or results of this final package. Fresh exact composed execution belongs to the final artifact's raw receipts. Both Core/Ride source gates remain false and public Mount remains denied; pure fixtures cannot activate the package or establish gameplay parity.

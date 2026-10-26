# Ride diagnostic bounds

`ride_runtime.status().metrics.stop_counts` counts every observed stop request,
including later cleanup causes and repeated requests. The first lifecycle cause
remains in `status().issue`; later requests do not advance cancellation generation
again. Counts describe stop observations, not independent failures or completed
native effects.

At most eight distinct exact reason strings are retained, in first-seen order.
Their complete compact JSON-encoded keys, including surrounding quotes and all
escapes, may total at most 1,024 bytes. Existing keys always increment even after
either limit is reached. Keys use the complete textual reason; they are not
truncated to the 180-byte display bound, so distinct long reasons cannot silently
merge. New malformed UTF-8 keys are refused.

`stop_counts_overflow` counts every occurrence whose new reason cannot be kept
because of either capacity limit or invalid UTF-8. Repeated unrecorded reasons
increment this count each time; it is not a count of distinct omitted reasons.
No reason is evicted and no unrecorded key changes an existing counter. The
cardinality and key-byte bookkeeping remain private and do not become authority.

The wheel/body sample ring now retains 24 rows rather than 32. This deliberate
tradeoff makes space for the stop counters within Core's existing 48,000-byte
ledger limit. `samples_total` and `samples_omitted` still describe all validated
observations and every overwritten row. The grounded-transition ring remains 16
rows with its own total and omitted counts. Core's 3,000-field, depth and string
limits remain unchanged.

The standalone ledger regression uses the actual SDK-compatible JSON conversion
and writer. It keeps 64 call rows, 16 Follow receipts, 16 grounded transitions, 24
wheel/body samples and three pending commands while filling all eight reason
keys to exactly 1,024 encoded bytes and recording overflow. It checks the full
persisted Core schema, preserves the 48,000-byte and 3,000-field limits, and retains
negative tests for oversized JSON and copier fallback. Its model window uses 151
pinned native-shaped intervals, reports the actual duration separately from the
2,500 ms target, and is constructed serialization evidence rather than an admitted
Core/native/game ride.
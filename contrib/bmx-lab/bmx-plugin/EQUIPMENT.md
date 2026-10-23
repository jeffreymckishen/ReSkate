# Equipment request policy

`plugin/equipment.lua` ports our retained `bmx_interaction.h` gestures and the
toggle/dismount predicates from `equipment_switch.h`. It returns requests and
owns no native resources. Requiring it performs no tests or gameplay actions.
The package entry exposes a separate explicit stock switching adapter; this
gesture module itself remains an offline request policy. See
[EQUIPMENT_RUNTIME.md](EQUIPMENT_RUNTIME.md).

The toggle needs a neutral sample before each press. Ordinary North/Y produces
one tap on release or one hold at 500ms; a hold's release never produces a tap.
Loss of readiness or a backward clock resets its arming. Timestamps are exact,
nonnegative integer milliseconds through 2^53-1.

The quick equipment gesture claims a fresh North edge while LB/L1 is held.
Adding the shoulder after an ordinary North press preserves that ordinary
interaction. A claimed shortcut stays captured through its release observation;
the next full neutral observation ends capture. A device/clock change, missing
owner or changed owner consumes an attempted shortcut without deferring its
request until a later valid observation. Holding either button cannot replay it.

Call `quick:owner_sample_needed(north, shoulder)` before the corresponding
`quick:update(...)` to decide whether a fresh canonical owner is required. An
owner is a stable opaque userdata token, bounded string or exact positive model
integer, never a native pointer converted to a Lua number. This module checks
token shape and equality; the SDK adapter must establish actual actor ownership.
The device field is a nonzero uint32 source epoch, not an invented pad-slot ID.

Compose the ordinary latch with `allowed and not event.suppress_north`. Both
latches must receive the same validated source/readiness decision. A malformed
or absent source must invalidate or reset both, even though the quick latch
returns an empty event. The adapter must also reset the ordinary latch on actor
loss or replacement; a held ordinary press cannot transfer to a new owner.
`capture_north` is a requested input lease; it does not
prove that native Skate was prevented from consuming the button.

`quick_action(active, pending, mounting, parked, crashed)` rejects incomplete or
nonboolean state. Pending work or mounting produces no action; riding requests
the skateboard, a retained parked/crashed bike requests the nearby-bike path,
and other states request equipping a bike. Natural dismount requires matching
current/committed native state 100 or 103. These state numbers reproduce the
supported-build predicate; supplying them manually does not establish readiness.

No automatic native retry, park, teleport, mount, carry, recovery or equipment
handoff is implemented in this gesture module. The separate adapter uses the
generic report service and independently checks sampled stock equipment state;
it does not restore the retired BMX C++ dispatcher or connect BMX riding.

`plugin/equipment_tests.lua` exercises the portable policy. The unconditional
plugin Host case also compares 160 typed gesture observations against the
retained C++ rules, with source/clock/owner/focus changes and ordinary-latch
composition. The C++ rules are an offline test oracle only; the tested package
has no gameplay permissions. Successful execution establishes policy agreement,
not native button consumption or equipment completion.

The Release Host target built cleanly and focused `plugins` CTest passed on
2026-10-23 in 1.83 seconds with the normal VM limits. Equipment coverage was
**8 groups, 1,269 assertions, 160 C++ comparisons and zero native actions**.
Fifteen unrelated optional contributed-plugin fixtures were absent; this case
runs unconditionally. An independent source review accepted the three tested
source files before execution. The private evidence receipt is
`build/bmx/lua-equipment-host-v1/receipt.json` (SHA-256
`AF54112C498E49D6F4B6AB49A40429F02BE205DEF94CA085B4F00E7D0E11CAD1`).

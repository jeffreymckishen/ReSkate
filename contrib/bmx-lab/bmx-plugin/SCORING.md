# Local BMX scoring

This is a pure Lua scoring model for the mod. All point values, difficulty assignments, decay,
multipliers, quality thresholds and timers below are **authored defaults**. They are not measured Skate
scoring and do not demonstrate BMX Streets likeness. C0 skateboard calibration is still pending.
Replace measured rules with cited C0 findings before describing these numbers as Skate's rules.

The modules do not access reskate, storage, overlays, native scoring, progression, challenges,
cosmetics, entitlement data, controllers or physics. A later local display/storage adapter can consume
their output. No manifest, main entry, existing pinned module or qualification gate changes are needed.
The public ride and presentation gates stay closed.

## Modules and contract

- score_rules.lua: immutable defaults, bounded numeric sanitization, integer-score ceiling 2^53.
- score_catalog.lua: direction-neutral key, display, category, authored difficulty and pose metadata
  for the existing catalog. The catalog and its six holes are untouched.
- trick_names.lua: bounded formatting of normalized completed parts.
- score_line.lua: Line.new(rules) and line:step(h, feed).

step returns {snapshot, credits, closed, issue}. credits is a fresh list, at most three entries
(one manual, one grind/stall, one air). Each credit is {name, points, landing, multiplier, score}.
landing is Clean, Sketchy or nil for unknown quality. closed is nil or
{outcome="banked"|"lost"|"interrupted", reason, score, points, multiplier, tricks}.
points is the line's unmultiplied completed credit, including on a loss; a lost score is zero.

The detached snapshot contains active, points, score, multiplier, tricks, links, categories (count),
remaining, airborne, manual_seconds, and grind_points. It contains no growing event log or input tables.
issue is none, stale_feed, invalid_feed, invalid_air, or repeat_capacity.
Mutating returned tables does not alter the line.

The feed adapter owns observation deduplication and native provenance. The scorer accepts a plain
table with finite, strictly increasing seconds, speed in [-1000,1000] and a known mode.
Duplicate or older timestamps return stale_feed unchanged. A restarted feed clock needs a new Line.
h is elapsed time in [0,10] seconds; live callers should supply their actual tick interval and mark
missing observations with gap=true. Seconds order credits/links; h advances duration/timers.
This module cannot independently verify a claimed landing or elapsed time.

Known modes: rolling, airborne, manual, nose_manual, grinding, stalling, bailed.
air is nil, {took_off=true}, {landed=Air}, or {failed=reason}.
Air contains air_seconds, sequence, spin_half_turns, front_flips, back_flips, barrel_rolls,
fakie_takeoff, overflow, and optional landing={body_up,heading_cos,closing}.
Each sequence row is {kind="bar"|"tail"|"move",id,dir,start,finish,hold}.

Sequences have at most 16 dense rows, ordered by start. Same-family intervals may not overlap,
and bar/tail families must use their own channel kinds. Only completed/caught rows belong here. start and finish
are seconds since takeoff, with finish at the end of rotation/entry for cycles or release for poses;
hold is the pose's plateau duration. Thus overlap measures actual rotations, not catch/recovery time.
The scorer groups L/R by catalog key, retaining each actual interval for naming.
Raw signed rotation radians may accompany Air but integer counts are authoritative.
Bounds: air duration 120 s, 32 half-turns, two flips/rolls per direction.
Front and back flips cannot both be nonzero: the current projector derives them from one signed pitch.
Landing body-up admits the projector's +/-1.000001 tolerance then clamps to +/-1; heading is signed
[-1,1], closing [0,1000000]. Malformed/overflowed Air interrupts before any credit in that feed; it never awards a partial sequence.

landing_pending=true freezes the timer. gap=true, non-nil interrupted=reason, or
ended={reason,infrastructure=true} interrupts. ended={reason,deliberate=true} banks.
Other unclassified ends interrupt conservatively. Known bail reasons, composer bailed, failed air,
manual loop-out/nose-over, grind bail, and Ride's measured tilt/roll-limit stop strings lose the line.
Failure takes precedence over landing or infrastructure flags.

Ground input is normalized by the future feed adapter:

- manual={event="balancing",kind="manual"|"nose_manual"} begins duration at zero.
  event="ended" plus reason ends it. Accumulate only observed balancing mode intervals after start.
  Credit exits: front_drop, rear_drop, hop_out, airborne; cancelled and unknown exits credit zero.
- grind={event="lock_on",grind=kind} begins lock credit.
  event="grind_changed" changes kind and adds the change bonus; event="exit" ends it.
  Kinds: double_peg, feeble, smith, icepick, toothpick, stall.
  contact_unavailable interrupts; bail loses. Other exits credit the observed total.
- h belongs to the interval preceding the endpoint event. Existing activities accrue it before their
  endpoint; new starts do not retroactively accrue it. Mode must describe that observed interval.
  A stall transition preserves prior points, and its duration is bounded across that lock.

## Authored formula and golden values

Difficulty bases D1..D5: 100, 200, 350, 550, 800. Barspin is D2; Tailwhip D3.
Each completed pose contributes base times 1 + .5*min(1, hold/.5).
For a channel with catches, **sum each catch's value**: catch k contributes
base*(1 + .5*(k-1)). All catches on that channel form one part/key.
Consequently double barspin is 200 + 300 = 500, not 300. No repeat decay is applied between catches
in the same air. Repeat decay applies once per key per completed air:
max(.1,1-.25*(previous airs using key)).

A bar part and tail part get 1.25 each when any of their actual rotation intervals overlap by at
least half of the shorter interval. Zero-duration rows cannot establish overlap.
Part value = accumulated completed values * overlap factor * per-line repeat factor.

For n half-turns, S = 150*n*(1+.25*(n-1))*repeat("rotation:"..n).
A flip/roll axis scores 600 single, 1500 double, with its own repeat key.
R = min(3,1+.25*n+.5*(flips+rolls)).
C = min(2,1+.2*(distinct keys-1)), including a spin and each flip/roll axis.
A = floor(100*max(0,air_seconds-.5)).
Air points = floor(((sum(parts)*R + S + F)*C + A)*L).

Clean L=1 needs absolute body-up and signed-heading magnitude >=.966, closing <=5.5 m/s.
Otherwise accepted known quality is Sketchy L=.7. Missing quality also uses .7 without a label.
A partless hop of at least .25 s scores floor((50*repeat("bunny_hop")+A)*L).
A partless hop uses only category air; other tricks do not gain air category for their airtime bonus.

| Golden | Points / line |
|---|---|
| G1 .90 s clean Bunny Hop | 90 / 135 |
| G2 .90 s clean Barspin | 240 / 360 |
| G3 same Barspin two seconds later | 190, sum430 / 645 |
| G4 1.20 s clean Truckdriver | 880 |
| G5 1.10 s clean double Barspin | 500+60 = 560 |
| G6 .90 s Sketchy Tailwhip | 273 |
| G7 Barspin then Tailwhip | sum630 at2x / 1260 |
| G8 failed Tailwhip after G2 | lost / zero |
| G9 .90 s overlapping Barspin + Tailwhip | 865 |

## Lines, ground credit, names and bounds

Multiplier = min(4,1+.5*distinct_categories+.25*min(4,links)).
A link joins credits within .5 s when either credit is manual/grind/stall.
A single credit never links to itself. Categories are the closed set air, variation, bar, frame,
rotation, flip, manual, grind, stall. Line score = floor(sum completed points * multiplier).

Credits open the line and refill 2.5 s. Rolling drains it; pedalling neither credits nor refills.
Airborne, landing-pending, manual and grind/stall intervals freeze it. Timeout, deliberate stop/dismount,
or one continuous second below .3 m/s banks. Interruption banks only completed credit, dropping active
air/ground work. Bail loses it. The first failed air still reports a zero-score loss.

Manual/nose manual rates are 120/150 points/s after at least .3 s; once qualified, the whole observed
balancing duration is credited, capped at10 s. Grinds start at100, gain100 per change and points/metre:
60 double peg, 80 feeble, 100 smith, 110 icepick/toothpick. Distance uses absolute observed speed.
A stall starts at150 and adds200/s for at most .75 s. Ground credit is not repeat-decayed.

Names strip Left/Right, normalize Whip to Tailwhip and Xup to X-Up; sequential parts use " to ",
actual overlaps " + ", repeated catches Double/Triple. Spin and flip prefixes precede parts.
360 Barspin is Truckdriver; 720 double Barspin is Double Truckdriver.
Fakie takeoff prefixes Fakie; its180 is Half Cab. Negative landing heading adds " to Fakie".

State is bounded: at most16 sequence rows and groups per air,128 repeat keys per line,9 categories,
one active manual and one grind, and no history list. Overlap is at most16x16 comparisons.
Per-credit values, accumulated points, line score and trick count saturate at2^53.
Rules accept only named finite numeric settings, clamp their bounds, copy bases, and freeze results.
A scoring caller must own the Line object; this is a pure local model, not a security boundary.

## Validation status

Source authored only: **UNRUN**. The new suites cover the golden scores, naming/catalog coverage,
repeat/reset, malformed/overflow input, stale-feed deduplication, frozen timers, every loss/interruption
route, manual/grind/stall limits, links, caps and2^53 arithmetic saturation.
The saturation test seeds an existing subtotal near2^53; it does not simulate an impossible-length ride.
The step-cost test records median wall-clock cost across nine chunks of64 maximum-size air packets,
with an authored1 ms per-step gate. This is a runner cost check, not an in-game tick-budget result.
Root/Claude owns all runner, Host and in-game validation. No C0 scoring calibration, gameplay scoring,
native HUD, storage, trick qualification or BMX Streets parity is claimed by this source handoff.

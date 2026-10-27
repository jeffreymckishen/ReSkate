# Native trial operator plan

This is a source proposal, not execution approval or a game result. The main
ReSkate chat releases each exact package, runtime and bounded operator trial.
The P0/H1 harness is the only implementation in this folder. T1 and T2 require
separate reviewed source and are not selectable modes in this harness.

## Before an attempt

1. Pin the supported game build 20260929, DLL/launcher, production source pins,
   private source, every declared copy transformation, permissions and output
   inventory. Keep the normal Steam installation separate from the mod-managed
   test installation. Use the exact operator-approved game path.
2. Review the staged copy with admission still disabled. An admitted copy must
   explicitly record P0 or H1, a fresh run/package identity and review identity.
   Use a new process/VM, body and Follow for every attempt. No reload/remount retry
   can establish the same authority or repair an unknown cleanup.
3. Verify the one-shot start, guard, recorder, stop and cleanup behavior through
   the actual source tests and staging refusal tests before game execution.
   All of those checks remain unrun by the source-authoring helper.
4. Arrange measured input and phase evidence, external video/joint observation,
   host timing and terminal readback before starting. Never infer a successful
   pose from only a model projection or SDK acceptance. Sparse once-per-second
   persistence and the old six-tick joint cadence can miss the short movement.
5. Confirm 6 ms per-tick average over one-second host windows and unchanged
   50 ms per-call ceiling. Include the recorder and all UI/storage costs. A run
   shorter than the host's three over-budget windows cannot establish sustained
   performance simply because the host did not stop it.

This operator plan does not drive HID, stage files into the game, edit packages,
launch the game or grant an execution lease. Any separate body diagnostic
must finish and release exclusive ownership before a hop trial.

## P0: current mounted baseline

Use the paired floor-spawn and M1 provisional Follow offset, ordinary MountedPose,
Core composition, Ride activation and category wheel lane in the reviewed copy.
The added permissions are `skater.animation` and `world.raycast`. Keep
`RIDE_TRICKS_QUALIFIED`, TrickRuntime `RIDE_SUPPORT_QUALIFIED`, Follow lead and
Follow renewal false. No renewal permission is needed for this fixed lease.

After explicit start, wait for real Source/input, body and Follow readiness.
Keep every movement control neutral. Check the current exact-angle mounted pose,
board state, actual body/support samples and receipt/ACK flow. The pose observer
must request Stop on failure; production Core by itself may continue Ride after
an optional pose refusal. Record the full cleanup and verify the final state.

Older S2c rounded steer/crank before caching. Its 3.986 ms maximum one-second
average and 11.1 ms maximum callback are historical results for that copy, not
qualification of this exact-angle composition or added instrumentation.

## H1: one quarter-strength hop

Use the fixed P0/H1 caps documented in README. P0 must first establish suitable
initial support and instrumentation without suppressing or fabricating contact.

The gesture is neutral right stick, short straight back, straight forward, then
neutral; all other controls remain neutral. The mapper requires normalized back
at most -.72, forward at least +.55 and lateral magnitude at most .35. Release
must reach forward within .30 s. Actual accumulated charge at most 62.5 ms
produces the minimum `.25` strength. The pre-submit guard checks the actual
mapped value, so HID wall-clock timing alone cannot authorize a hop. R3 requests
strength 1 and is refused. One native attempt consumes the guard even on refused,
unknown or exceptional return. No second gesture is allowed.

Correlate the original queued Source and the actual body sample with the hop ID,
119.25 N s impulse, ordinary force, `J/h`, combined packet, submitted sequence,
requested and produced serials, applied receipt, coherent later body successor
and positive ACK. Check both measured and folded speed, including gravity and
pending work. A neutral support packet and a predicted model step are not hop
application evidence.

Require actual body takeoff and return under declared support predicates. Keep
ray-derived support distinct from native collision wheels. The requested delta-v
is 1.125 m/s. Ideal ballistic airtime about .23 s and height about .065 m are
calculations only; the contact/landing law and actual native motion can differ.
H1 has no scoring qualification: its trick gates stay closed and its private
entry does not promise score processing. The .25 s ordinary air-credit threshold
is relevant only to a later enabled scoring composition.

Stop on any failed identity, unexpected input/strength/second impulse, pose,
contact, force/speed/torque, receipt or deadline check. Continue cleanup through
actual terminal state or the existing watchdog. Retain debt on partial/unknown
results. A parked result without the required successor/ACK is not clean.

## T1: partial One Hander routing, separately reviewed

Only after H1 evidence is accepted, prepare a fresh private package/process.
Additionally open the Ride tricks and TrickRuntime support gates while keeping
rotation-force gates closed. Do not reuse the body from H1 or a separate body diagnostic.

Obtain a real supported neutral prime, then an actual neutral unsupported body
frame. On a later Source observation use LB plus right stick left, other
controls neutral. This selects One Hander Left, ID36. The request starts at phase
zero; subsequent fresh body/model steps must show nonzero left-hand release,
authored arm/torso targets, SDK pose acceptance and an observed matching effect.
The six releases and pose plan must stay correlated with the original queued
Source and advancing model-history sequence.

The quarter-hop proposal does not justify full .18 s entry plus .12 s recovery.
T1 claims partial target routing and cleanup only. Stationary vertical
motion may correctly refuse landing quality because no relative horizontal
heading exists. Neither that refusal nor early touchdown may be relabeled a
completed trick, caught landing, score pass or sustained-performance pass.

## T2: full One Hander, catch, landing and local score

The complete objective remains a later full trial, not an optional substitute
for T1. The proposed source envelope is:

| Setting | Conditional T2 proposal |
| --- | --- |
| Stage and caps | `hop`; force 6000, speed 3, torque 2000, vertical_speed 3 |
| Motion before hop | measured aligned forward surface-relative speed .50-.75 m/s |
| Vertical speed before hop | absolute value at most .10 m/s, admitted flat support |
| Hop strength | actual consumed Source in [.50,.60], one attempt |
| Target charge | 133-134 ms actual accumulated source time, about .532-.536 |
| Ride window | 1500 ms, still bounded by fixed lease remainder |
| Launch remainder | at least 800 ms before the effective ride deadline |
| Lead / renewal | off; no silent extension or stronger-hop fallback |

A pedals; B brakes; right-stick forward is part of the hop gesture. Under the
`hop` stage, A-only pedaling can establish the forward speed without enabling
`hop_ride`, steering, brake or manual inputs. Release A and verify neutral before
charging. No fixed duration of A proves the required velocity.

This envelope requests delta-v 2.25-2.70 m/s and impulse 238.5-286.2 N s. At nominal
60 Hz, the worst triangle bound `6000 + 286.2/h` is about 23172 N, below 40000 N;
impulse is below 600 N s. Measured/folded speed and the real packet still govern.
No source calculation proves that native support, landing force or actual
vertical speed stays within the proposed caps.

The .50-.60 strength envelope has ideal ballistic airtime .459-.551 s. Weak
H1/T1 at .25 cannot supply measured air evidence for this stronger envelope.
Before claiming a qualified T2 envelope, separately review a straight moderate
hop calibration H2, or explicitly designate T2 itself as the first unqualified
attempt at that envelope. Do not scale weak-hop observations into native proof.

Set `D=min(publish+1500, lease_until-150)`, with the fixed lease anchored to the
reserve clock read. A full 1500 ms requires more than 1650 ms of actual lease
remaining at publication. Abort before hopping if measured setup cannot fit;
target launch by publication+500 ms and require at least 800 ms before D.

1. Obtain a neutral unsupported body frame. On a later genuine Source use LB
   plus right stick `(-1,0)`, other modifiers and left stick neutral. The default
   selector needs normalized magnitude at least .7, raw radius at least .736.
   Confirm accepted ID36 with its original queued Source.
2. Immediately return right stick to `(0,0)` after selection and release LB.
   Releasing LB alone does not catch. Neutral must be observed by the mapper.
   Early neutral does not shorten entry: .18 s entry completes before recovery
   starts at zero; subsequent unsupported steps accumulate .12 s recovery.
   At 60 Hz this needs about 11 later entry frames and 8 recovery frames.
3. Observe `movement_caught=true`, incremented movement count and completed
   `{kind="move",id=36}` on a fresh unsupported frame **before first eligible
   support**. With selection latency at most 66.7 ms and one confirmation frame,
   .400 s of usable measured air is a planning floor. Elapsed air alone never
   replaces the caught-state observation. Touchdown during entry or recovery
   fails; later grounded waiting cannot finish or repair the trick.
4. Accept only measured support: separation [-.10,.005] m, point-relative normal
   opening speed at most .05 m/s and qualified source/body/query identities.
   Distant ray hits are not necessarily support. Landing quality needs body-up
   at least .5, normalY at least .15, closing speed at most 7 m/s and absolute
   heading cosine at least cos 35 degrees. Use measured forward relative travel,
   not drift barely above the numerical .0001 m/s heading threshold. Never
   substitute world-up or zero surface velocity for unavailable native data.
5. Accumulate .06 s of subsequent supported samples; impact itself does not
   count. At 60 Hz that is four further samples. Unsupported gaps reset settling
   and must stay at most .04 s. Require no failure, `combo_landed=true`, intended
   completed ID36, movements 1 and units 1. `landed=true` alone may include failure.
6. Let the real contiguous ScoreFeed credit One Hander. Its base is 100; measured
   air, hold and landing quality affect points, so do not hard-code the total.
   Default banking after 1 s below .3 m/s or 2.5 s timeout does not fit this window.
   A separately reviewed wrapper should call ordinary
   `bike:request_stop("explicit Stop")` only **after actual settled credit**,
   targeting credit by 1250 ms and Stop by 1300 ms, always before D. Keep the real
   score drain running after Core stops. Do not open a last-moment menu and
   assume Stop wins over the focus/menu guard.
7. Require `view.closed.outcome=="banked"` and the actual ID36 credit. Expiry or
   focus interruption cannot be renamed successful Stop. Best-score/session
   changes alone are insufficient. `storage_issue=="none"` and
   `pending_save==false` establish host-cache save acceptance, not durable disk.

A full pass combines actual entry/recovery, accepted SDK pose and observed
visual/joint effect, catch before contact, measured settled landing, the intended
banked score, hop applied/successor/ACK, and every later packet/Follow/Source/pose
cleanup result. Draining the hop alone does not drain subsequent support packets.
Continue recording beyond D as required; no 150 ms cleanup guarantee exists.

## Lifetime qualification stays separate

The separate body diagnostic design permits one park/reactivate/repark cycle.
That permission is not evidence of an executed cycle. It is not a
repeat-switching test and does not establish release of every native reference,
retained Follow dependency, native retirement or collision participation. Its
diagnostic body cannot be adopted into this hop composition. Logical cleanup
and native retirement remain distinct evidence fields.

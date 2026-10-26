# Ride composer

`plugin/ride_composer.lua` is one per-tick pipeline over the wave-1 policies. Input goes through
`ride_input_mapping.lua`, then the mode is settled from `manual_balance.lua`, `grind_policy.lua` (fed
by `rail_probe.lua`) and `bail_policy.lua` (fed by `bail_guard.lua`). Forces come from `forces.lua`
plus `grind_contact.lua` for pegs on a rail. Trick requests go to `trick_runtime.lua`, presentation
to `rider_presentation.lua` and `trick_presentation.lua`, and the camera to `camera_policy.lua`. Each
tick returns one result table: the commands to submit, the mode, the presentation, the camera view
and diagnostics.

It is pure. It owns no SDK object, makes no `reskate.*` call and runs nothing on require. Every
native read arrives in the caller's tick table, and every native write leaves as a request in the
result. Nothing is wired into `main.lua`, and `RIDE_COMPOSITION_QUALIFIED` and
`ACTIVATION_QUALIFIED` stay false. The composer changes no wave-1 module; the mandatory Framev1
binding it relies on lives in `bail_guard.lua` (BAIL.md). Every number below comes from an
offline world built for the tests. None of it is in-game evidence.

```lua
local Composer = require("./ride_composer")   -- at plugin load: the chain takes 34-43 ms to require
local ride = Composer.new()            -- optional {forces, input, balance, grind, bail, tricks, camera,
                                       --           crank_ratio, command_limits, batches_per_read, matrices}
-- One native step, three calls on one tick table. Each lane is its own probe_batch call, cast
-- against this read's sample.epoch; the wheel batch (cast before plan) is batch 1.
local queries = ride:plan(tick)         -- the rail probe, guard and camera plans for this read
tick.rail = probe_batch(epoch, queries.rail.rays, queries.rail.options)    -- when queries.rail
tick.guard = probe_batch(epoch, queries.guard.rays, queries.guard.options) -- when queries.guard
tick.camera_hit = raycast(queries.camera)  -- reskate.world.raycast, not a batch
local witness = ride:witness(tick)      -- the guard's 0..24 witness rays
tick.witness = #witness.rays > 0 and probe_batch(epoch, witness.rays, witness.options) or nil
local result = ride:step(tick)          -- submit result.commands only if result.commands.submit
-- Then the native owner's receipt for that command, before the next step if it can:
ride:accept(result.commands.serial)     -- or ride:reject(serial) / ride:reject(serial, "uncertain")
local placed = ride:matrices()          -- the eight part matrices, on demand
```

`batches_per_read` is how many `probe_batch` calls the caller's native owner lets one read make,
the wheel batch included. It defaults to `Composer.core_batches`, 4, the same as Core's read-only
`probe_batches_per_serial` export (see Batches). The composer writes it as a literal so that
requiring it does not load Core, and `ride_composer_tests` checks the two are equal. Each lane
keeps its own batch and decoder. Four batches do not increase the SDK's ray, request or
native-cast limits, and a read the guard policy did not judge still submits nothing. The offline
four-batch scenarios use this default; smaller allowances are explicit counterexamples.

Every guard plan is bound to the read's Ride Framev1, and a command leaves only from a read that
`bail_policy` judged on that read's own guard rows. Every other read fails closed and submits
nothing (see Guard binding).

`step(tick)` without a `plan` plans itself. The queries were then never cast, so rail and guard
rows count as unavailable, the camera resolves as clear, and the read submits nothing (`uncast`). `plan` runs once per read: a repeated
`plan` for the same read returns the same plan, and a plan for a read already stepped (a duplicate
or a regressed serial) asks for no rail, guard or camera query and does not advance the camera.

## The tick

| Field | What the caller supplies |
| --- | --- |
| `sample` | The `physics.read` record of this read: `epoch` (userdata), `serial` (decimal u64), `time`, `seconds` (forces.lua's native interval), `mass`, and Luau vectors `position`, `velocity`, `angular_velocity`, `inertia`, plus a `rotation` `{x, y, z, w}`. The body comes from it as `ride_runtime.lua`'s `sample_copy` builds it. |
| `body_handle` | The owned body's opaque handle (userdata). |
| `owner` | The mount token `bail_policy` and `bail_guard` compare. It must change for every new mount. |
| `wheels` | Front and rear `{radius, inertia, angular_speed}`: the wheel speeds adopted after the last accepted step. |
| `wheel_rows` | Two FORCES.md contact samples from this read's two wheel rays, built as `ride_runtime.lua`'s `wheel_contacts` builds them. |
| `wheel_query` | That batch's facts: `epoch_matches`, `local_actor_excluded`, `owned_bodies_excluded`, `budget_exhausted`, and `accounting_known` (true only when the caller knows it; `trick_runtime` requires it). Unqualified rows grant no support and run no kernel step, and the read is a hold (see Modes). |
| `gates` | `{focused, menu_open}`. |
| `input` | The selected-source observation in `ride_input_mapping.lua`'s frame shape, or nil when there is none this step. It is also the source of the read's Framev1, which every guard plan needs: a read without it plans no guard and submits nothing (see Guard binding). |
| `support` | The native support owner's fact for this read: `{provenance = "measured_support", grounded, point, normal, surface_velocity}` (the last three when grounded). Only a native or receipt owner may set it. Without it `trick_runtime` refuses, by design. |
| `rail`, `guard`, `witness` | Each is the raw `probe_batch` result for that lane's own rays, cast against this read's `sample.epoch`, and nothing else. `probe_batch` returns the epoch it was given as `batch.epoch` (`plugin_api_physics.cpp:671`), and the composer refuses any batch whose `epoch` is not this read's (`<lane>_epoch_mismatch`). A `Contact.decode` copy carries its facts under `query` and has no `epoch`, so it is refused by name (`<lane>_batch_contact_copy`), as are a missing (`<lane>_batch_missing`) or non-table (`<lane>_batch_malformed`) batch. For the rail this is the module's own rule too: `plan` builds the rail plan with `Probe.plan(body, {epoch = sample.epoch})`, and `Probe.decode` then refuses any batch not carrying that epoch as `epoch_mismatch` (`rail_probe.lua:391-392`). The guard requires the read's Framev1 epoch on the guard batch (`bail_guard.lua:376`) and that batch's epoch on the witnesses (`:448`), and runs both through the real `Contact.decode` (`contact_issue`, `:303`), so each needs `native_casts`, no `reason` when available, and `motion = "measured"` with a measured surface velocity on every hit, as `probe_batch` returns them (`plugin_api_physics.cpp:666-709`). The refusal reason is in `diagnostics.grind.rows`, `diagnostics.queries.witness` and `diagnostics.bail.guard`. A refused rail batch is a hold, never clear rows. A refused, missing or never-cast guard or witness batch leaves the read unguarded, so it submits nothing. |
| `camera_hit` | The raycast hit for `queries.camera`, or nil. |
| `recovered` | True on the read where the caller's own fall and recovery are done and the bike is placed again. |

## The result

- `commands`: `submit`, `serial` (the read this command was made for, which the receipt names),
  `force` and `torque` (world space, without gravity), `hop_impulse` (kept separate, never folded
  into the force), `hop_event_id`, and `wheels` (the speeds to adopt once the command is accepted).
  `submit` is false on a refused, duplicate or bailed read, on every read `bail_policy` did not
  judge (no guard plan, a guard or witness batch refused, missing or not fitting, an uncast read,
  a sample the policy refused, or the read that leaves bailed; see Guard binding), when the kernel
  refuses, when the summed command is over its cap, and while an earlier command waits for its
  receipt.
- `mode` and `events`: mode transitions, plus balance, grind and trick events. A lock-on the mode
  graph refused is reported as a grind event named `lock_on_refused`, never as `lock_on`.
- `presentation`: `bike` (the eight `bike_visual` angles, with offsets and matrices only under
  `matrices = true`), `rider` (the `rider_presentation` output: articulation, hip and torso offsets,
  posture, landing and crank), and the balance meters.
- `camera`: `{eye, target, fov}` from `camera_policy`, already checked against `camera.look`.
- `diagnostics`: support (with `owner`, the support owner's verdict), input, balance, grind (with
  `refused`, and `rows`: `available`, the rail probe's reason, or why there were no rows), rail
  contacts, bail (with the residual, `guard`, why the guard was or was not judged, and `guarded`
  and `unguarded`, whether the read may submit and, when not, why), kernel
  (with `committed_serial` and `consumed_hop` for the committed kernel), `hop` (what happened to
  this read's hop request), `outstanding`, `receipt`, trick, landing, queries (`requests`,
  `batches` cast, `batch_allowance`, `witness_batch`, the rail, guard and witness issues, and
  `guard_binding`: `bound` or why the read has no qualified Framev1), camera, `transition_refused`
  and `edge_refused`. `plan` reports `guard_binding` too.

No result, `matrices()` or `status()` table holds an opaque handle. The caller keeps the handles
it supplied. `status()` is a detached snapshot for logging.

## Receipts and the force kernel

`forces.lua` reserves `step` for portable tests: it commits history and consumes the hop at once.
The composer calls `preview` instead and keeps the candidate until the native owner answers
(FORCES.md: adopt a candidate only after native acceptance and receipts).

- The submit decision comes first, before anything is committed or retired: whether the read is
  guarded, kernel validity, the rail contacts, the summed command's cap, and whether an earlier
  command still waits.
- `accept(serial)` adopts that read's candidate as the committed kernel and retires its hop as
  `accepted` when the kernel applied it (`cancelled` when the kernel consumed it without an impulse,
  in the air or disabled). `reject(serial)` (or `"expired"`) drops the candidate and cancels the hop.
  `reject(serial, "uncertain")` marks the hop uncertain, and `ride_input_mapping` then refuses input
  until a reset, as its contract requires for an unknown outcome. A receipt for another serial, a
  second receipt, or one with nothing waiting is refused.
- One command waits at a time, as in `ride_runtime.lua`. A read stepped while one waits is withheld
  (`receipt_pending`). Its hop stays pending in the mapping (`diagnostics.hop = "held"`) for up to
  100 ms of observed input time, and the next submitted read sends it. A hop the waiting command
  already carries is left to that command's receipt.
- A hop the composer refuses itself (an unguarded read, over the cap, an invalid rail contact, a
  refused kernel) is retired as `cancelled`, because nothing was sent. A hop on an unguarded read is
  cancelled rather than held, because nothing says the next read will be guarded.
- The committed kernel advances only through `accept`. A read that does not directly follow the last
  accepted read previews from a reset kernel, as after a serial gap.
- A bail makes the waiting command's candidate unadoptable, and recovery drops it
  (`recovered.dropped_command`).
- `command_limits = {force, torque}` caps the submit path below the kernel's 40000 N and 4000 N m.
  The force cap applies to the summed force and to that force plus the hop impulse spread over the
  step, the kernel's own rule.

## Modes

```
none ──> rolling <──> manual / nose_manual
            │  ^            │
            v  │            v
          airborne ──> grinding ──> rolling / airborne
   any state, the first read too ──> bailed ──(caller's recovered)──> rolling / airborne
```

| Edge | When |
| --- | --- |
| rolling -> airborne | Neither wheel passes `Forces.eligible_support` on a read that knows its wheels (`wheel_contact_lost`). |
| airborne -> rolling | A wheel is supported again (`landed`). |
| rolling -> manual, nose_manual | `manual_balance` is entering or balancing, and the lifted wheel has left support or the balance is already balancing (`lift_started`). While the pull lifts the wheel, the mode stays rolling. |
| manual -> rolling, airborne | The balance ends (`lift_ended_<reason>`). A lift keeps its mode through the balance's own airborne grace. |
| airborne -> manual | Not an edge. The settle step refuses it (`airborne_to_manual_refused`) and cancels the lift. In practice the balance cannot enter from the air: `input.lua` consumes the manual gesture on landing until the stick returns to neutral. |
| airborne -> grinding | Only on the read whose `grind_policy` step emitted `lock_on`. A policy that reports locked without that event is refused (`grind_without_lock_on`). |
| rolling, manual -> grinding | Not edges. A lock-on there (pegs on a rail inside a manual's airborne grace, say) is refused, reported as `lock_on_refused`, and `grind_policy` is reset, so it never stays locked under another mode and a later grind needs a fresh lock-on from the air. The lift continues. |
| grinding -> airborne, rolling | A `grind_policy` exit (`grind_exit_<reason>`). |
| any -> bailed | Only on a `bail_policy` bail, including on the first read (none -> bailed). The kernel, balance, grind and trick models are cancelled, and nothing is submitted while bailed. |
| bailed -> rolling, airborne | On `tick.recovered`, completed on the first read that knows where the wheels are. Every model restarts as on a new mount, and the input needs a neutral prime. That read submits nothing (`recovered_unjudged`): `bail_policy` did not step on it, because the ride was still bailed when its bail was judged. The next read is judged afresh, with no sweep history. |
| (hold) | A read with unqualified wheel rows, or with an unavailable row and no supported wheel, does not know the ground. It takes no edge (except out of a grind `grind_policy` itself ended), plans no rail probe, keeps the input's and the camera's last known ground context, holds `manual_balance` (not stepped) and `grind_policy` (no rows, so it disarms while idle and counts toward its own cancel while locked), and steps no rider cue. |

`Composer.allowed(from, to)`, `Composer.edges()` and `Composer.settle(from, wanted, supported,
lock_on)` expose the graph. Every edge the composer takes goes through `allowed`.

## How each module is composed

- **Input.** `ride_input_mapping` observes the pad and binds the force controls and trick actions to
  this read's `physics_epoch`. Its ground context is wheel support, a locked grind, or an active lift,
  so a support flicker during a manual or a grind does not clear `input.lua`'s gestures. Hops are
  retired through the receipts above.
- **Manual.** `manual_balance` owns `manual` and `nose_manual` whenever a wheel is supported or a lift
  is active. Its `manual_pitch` is set to the kernel's. Pitch comes from `Balance.measure` against the
  mean supported wheel normal. It is stepped only on reads that know both wheels' support.
- **Grind.** `rail_probe` is planned while the bike is known to be unsupported, or grinding, when the
  read's batch allowance has a batch for it. Its rows are decoded from the raw batch on this read's
  epoch only (see The tick) and given to `grind_policy`. A read without rail rows is a hold, never
  clear. Touching peg
  rows (and tire rows whose ground row is clear) go to `grind_contact.solve`, one after another,
  twice, on the body as the kernel left it. That way two pegs on one rail do not each stop the whole
  closing speed. The contact force is applied whenever a peg touches, locked or not, because the rail
  is physical either way. While grinding, the kernel runs with `enabled = false`, and the policy's
  assist torque, when enabled, is added to the command.
- **Bail.** `bail_guard` plans the guard rays and its witnesses (each in its own batch, inside the
  allowance) on the read's Framev1 (see Guard binding), and `bail_policy` judges the decoded
  sample with the force/velocity residual proxy of `bmx_chassis_ride.cpp`. The residual pairs the
  last read's command (accepted, rejected, or never sent) with this read's velocity, and is unknown
  after an uncertain or still-waiting command. Bail requests from `manual_balance` (loop-out) and
  `grind_policy` (balance lost) are reported, not executed. If the rider is on the wheels again with
  no `bail_policy` bail, the request is reported as `unrealized` and the grind latch is cleared. Only
  a read the policy judged submits a command, and the guard lends sweep history only from such a
  read (see Guard binding).
- **Forces.** `forces.lua` previews every read with qualified rows. It runs passive (`enabled =
  false`) while the input is gated or the bike is grinding. The peg forces and the assist are added
  to its force and torque, and the sum is held to the caps above.
- **Tricks.** `trick_runtime` is stepped once per read. Its contact packet uses this read's wheel
  batch facts and the caller's `tick.support`, copied as given. The composer never labels its own
  geometry `measured_support`, so without a support owner every trick step is refused
  (`physical_support_unqualified`), which keeps INTEGRATION_PLAN.md's B3 gate. The bike pose
  follows `trick_presentation`'s law: this read's steer and wheel phases, last read's presented
  crank plus the movement crank angle, and the trick targets. `Ride:matrices()` places that pose
  through `trick_presentation.present`.
- **Rider.** `rider_presentation` gets the crank cadence (rear wheel at an authored 25/9 drive while
  pedalling), the support and wheel normals, the trick releases and landing evidence. The C++
  landing Tracker is not ported. The composer's own evidence uses the last unsupported read's
  velocity into the normal as the approach speed.
- **Camera.** `camera_policy` steps in `plan` with grounded meaning a supported wheel or a grind, and
  resolves in `step` with the caller's hit. It is reset and teleported on recovery.

## Guard binding

`bail_guard.lua` plans only on a frame that carries its read's Ride Framev1 (`frame_identity.lua`).
It holds both guard batches to that frame's epoch, runs them through the real `Contact.decode`, and
lends sweep history only from the same body and source's coherent successor (BAIL.md). The composer
builds that frame in `plan` (`guard_frame`, `ride_composer.lua:210`) from this read's `sample`,
`body_handle` and `gates` and the selected-source observation in `tick.input`, so it names this
read's body and source and nothing older. `fresh` is the composer's own verdict: it builds a frame
only for a read whose serial follows the last read it stepped. A planned but unstepped read is not
tracked, so a pending higher plan can be replaced before it is stepped. The trick frame has the
same shape (`read_frame`, `:198`), with the source `ride_input_mapping` last accepted.

`plan.guard_binding` and `diagnostics.queries.guard_binding` say whether the read is bound:

| `guard_binding` | When |
| --- | --- |
| `bound` | The frame qualifies and the guard planned on it. |
| `input_source_absent` | `tick.input` is nil. |
| `input_source_unavailable` | `tick.input` is not `input_ok`, or its lease handle is not userdata. |
| `frame_<reason>` | `Frame.copy` refuses the frame, for example `frame_invalid_source` for a source sequence of 0. |
| `frame_unfocused`, `frame_menu_open` | The read's gates. The guard refuses such a frame too. |
| `guard_frame_refused` | `Guard.plan` still refuses the frame (`invalid_guard_frame`), for example a body inside the composer's bounds but outside the guard's. |

**The composer fails closed.** A read is guarded only when `bail_policy` stepped on that read's
own decoded guard sample and accepted it (`diagnostics.bail.guarded`). Every other read that is not
bailed submits nothing: no force, torque or hop impulse. Its withheld issue
(`diagnostics.kernel.issue`, and `diagnostics.bail.unguarded`) says why:

| Withheld issue | When |
| --- | --- |
| `bail_guard_unbound` | No qualified Framev1, so no guard plan and no witness (`guard_binding` says why). |
| the guard's own refusal | The guard will not plan for a qualified frame (`guard_ray_outside_world`, `guard_ray_budget`). |
| `batch_allowance` | The chosen allowance has no batch for the guard lane. An explicit one-batch caller has only the wheels; Core defaults to four. |
| `uncast` | `step` without `plan`: nothing planned was cast. |
| `guard_batch_missing`, `<lane>_batch_malformed`, `<lane>_batch_contact_copy`, `<lane>_epoch_mismatch` | The guard or witness batch handed back is not this read's raw `probe_batch` result (The tick). A stale batch relabelled for this read is an epoch mismatch. |
| `witness_not_called`, `witness_batch_missing` | `witness` was never called, or its rays were not cast and handed back. |
| `witness_batch_allowance`, `witness_batch_rays`, `witness_budget` | The witnesses did not fit the allowance, a batch or the request budget. The guard gets priority on the next read. |
| any reason `Guard.witness` or `Guard.decode` gives | `guard_exclusion_unqualified`, `malformed_available_batch` (no or zero `native_casts`, a reason on an available batch), `guard_measurements_unavailable` (unmeasured surface motion), an unavailable or exhausted batch, a malformed row, and the rest (BAIL.md). |
| `bail_policy_<issue>` | The policy refused the sample (`invalid_sample`, `unsupported_step`, `stale_contact`), for example under an invalid bail tuning. |
| `recovered_unjudged` | The read that leaves bailed. |

A hop the kernel applied on an unguarded read is retired `cancelled` and never sent later.
Riding without bail protection is unsafe, so the composer stops pushing the body rather than ride
it unguarded; native physics still holds a bike nobody pushes. Everything else about the read
still runs: support, input, balance, the rail probe, `grind_policy`, modes, rider cues and the
camera.

The guard lends sweep history only from a read `bail_policy` accepted. After an unguarded read the
policy's own serial history has a gap, and it refuses a swept crossing on a step that does not
follow its last one (`invalid_sample`, `bail_policy.lua`, from `bmx_bail_policy.h:117-129`), then
clears its history again. Lending the guard's history across that gap turned a crossing on the next
read into a refused sample rather than a judgement: before this change, 1 read in the 2-batch
head-height bar run (step 57, the read where the 3- and 4-batch runs bail) and 3 in the 2-batch nose
dive, each right after a read whose witnesses had no batch; none after it. The next plan after an
unguarded read therefore has no sweep history, and the one after a judged read has it again. Without
that history the 2-batch bar run still does not bail: the crossing happens on the read after the
refused witnesses, which now casts no swept ray. Two batches do not protect this rider.

This changed four behaviours. A read with no `tick.input` used to be stepped with passive support,
and so did a read that was unfocused or in the menu (its input refused); both now submit nothing.
A bound read whose guard or witness batch was refused, missing or did not fit, an uncast read, a
read whose guard lane the batch allowance refused, and a read the policy refused all used to
submit their command with `bail_policy` not stepped (gap 13 of the previous revision); they now
submit nothing. The read that leaves bailed used to submit; it now submits nothing. And the guard
used to lend history from the previous read whether or not the policy judged it.

An explicit one-batch caller carries no guard lane and submits nothing at all. Core now grants
four batches per native serial, but in game the composer still submits nothing until the native
adapter accepts `exclude_local_actor` (BAIL.md). That is intended: those are exactly the reads it
cannot protect. The constructed offline caller uses the same four-batch allowance and returns
both exclusion facts true; those facts have not been established for the native adapter.

## Batches and the request budget

One composer read needs up to four separate `probe_batch` calls, one per lane:

| Lane | Rays | Why it is its own batch |
| --- | --- | --- |
| wheels | 2 | `ride_runtime.lua` casts them before `plan` (`ride_runtime.lua:450-452`) and decodes them through `Contact.decode` (`:454`), and `plan` reads their rows to decide whether to probe the rail at all. |
| rail | 30 | Six sites of five rays (`rail_probe.lua:1-6`, `:58`). Rail plus the smallest guard is 38 rays. |
| guard | 8 to 24 | One to three rays for each of eight spheres (`bail_guard.lua:207-250`). |
| witnesses | 0 to 24 | Aimed along normals that the guard batch has just measured, so they cannot share its batch (`bail_guard.lua:12-16`, `:364-430`). `Guard.decode` refuses a witness batch whose epoch is not the guard batch's (`:448-449`), and every `physics.read` sample has its own epoch (`frame_identity.lua:3`), so they cannot move to a later read either. |

Every lane still shares these fixed limits:

- **A batch holds 1 to 32 rays.** `probe_batch` refuses anything else with "a ray batch has 1 to 32
  rays" (`Extension/Plugins/plugin_api_physics.cpp:578`, from `body_query::maximum_rays = 32` at
  `Engine/Game/World/body_query.h:11`; `contact_runtime.lua:4` and `:67` hold plans to the same 32).
- **Core permits four batches per native serial, including the wheels.** Its read-only
  `probe_batches_per_serial` export is the composer's default. The private adapter runs the
  existing epoch/Source/Follow/body guard and checks `require_contact` and `exclude_local_actor`
  on every batch, then checks the current owner again after every SDK call. The fifth stops the
  runtime with "fifth contact batch for one native serial refused". Only an exact uint64 serial
  advance refreshes the count; duplicates retain it and regression stops the runtime. Callback
  failure and reentry do not refund a call. The wheel lane still uses `Contact.decode`; rail and
  Guard retain their own plans and batches, and Guard additionally validates each used batch
  through `Contact.decode`.
- **64 logical requests and 64 native casts per tick.** `plugin_vm.h:43` sets 64 requests, counted
  per batch at `plugin_api_physics.cpp:638-640`. `body_query.h:10` sets 64 native casts with up to 2
  per ray. All four lanes plus the camera ray come to 81 in the worst case.

Four batches can carry all four lanes separately. They are not merged or staged: rail plus guard
is at least 38 rays, and witnesses depend on the current guard's rows and epoch. Each decoder
keeps its own per-batch accounting, ray plan and row count. The composer still refuses explicitly:

- `batches_per_read` (default `Composer.core_batches = 4`, tested equal to Core's
  `probe_batches_per_serial`) is the read's allowance, the wheel batch included.
  `Composer.layout(allowance, lanes)` gives each lane in priority order its own batch.
  The order is guard, rail, then a batch reserved for the witnesses. While grinding it is rail,
  guard, witnesses. Under guard pressure the rail yields (`guard_priority`). A lane past the
  allowance is refused as `batch_allowance`, and a lane outside 1 to 32 rays as `batch_rays`. A
  lane is never split, merged or deferred.
- Witnesses that turn out to be needed with no batch reserved for them are refused as
  `witness_batch_allowance`. That makes the guard unavailable for that read (an uncast witness is
  never clear) and gives it priority on the next read, the same as `witness_budget`.
- The request budget still applies: the rail is planned only if it fits after the wheels, camera
  and guard, and a witness set larger than what is left is refused as `witness_budget`.
- The 64 shared native casts are not modelled. The caller reports `budget_exhausted` in each batch,
  and every decoder refuses it.
- `plan` reports `batches` (the wheel batch, plus rail and guard when planned), `batch_allowance`
  and `witness_batch`, and `diagnostics.queries.batches` counts the witness batch once it is cast.

What each allowance carries in the offline world (`one read carries one batch per lane` case). A
read whose witnesses are refused is unguarded and submits nothing; the constructed ground holds
the bike for that step if a wheel was supported, and otherwise it falls freely (see Offline
scenarios).

| Batches per read | Lanes | Rail flick | Head-height bar | Nose dive |
| --- | --- | --- | --- | --- |
| 1 (explicit limit) | wheels | Nothing is submitted on any of its 151 reads (`batch_allowance`), so the flick's hop is cancelled and the bike coasts on the ground: no rail, no lock-on. (A separate unsupported read is refused the rail as `batch_allowance`.) | Nothing submitted on any of 90 reads; coasts through to z 4.45, never bails. Every read reports `batch_allowance`. | Not run. With no guard batch, nothing can bail, and nothing is submitted. |
| 2 | wheels, guard | Rail refused on 28 reads, no lock-on. Every read guarded. | Witnesses refused on 5 reads, each submitting nothing; no bail in 120. | Witnesses refused on 10 reads (8 before reads failed closed), each submitting nothing; no bail. |
| 3 | wheels, guard, rail or witnesses | Lock-on at the same read as with 4. Witnesses refused on 9 reads (6 before) while the rail held a batch, each submitting nothing, and the rail yielded on 3 (4 before). | Bails at the same read (`swept_body_crossing`). | Bails at the same read (`hard_rider_contact`); witnesses refused on 1 read, which submits nothing. |
| 4 (Core default and lab) | all four | As in Offline scenarios. | As in Offline scenarios. | As in Offline scenarios. |

The 2- and 3-batch counts moved when unguarded reads began to fail closed: a read that submits
nothing leaves the body where native physics would, so the later reads differ.

The tests check every read: at most its allowance of batches, each cast batch 1 to 32 rays, and at
most 64 requests. The most any read used was 59 requests: 57 while airborne at speed, plus 2
witness rays.

## Offline scenarios

`ride_composer_tests.lua` rides the composer through a constructed world: level ground at y = 0,
authored 50 mm round rails along +Z, and a bar along X. Rays are cast analytically into raw
`probe_batch` results shaped as `plugin_api_physics.cpp:666-709` builds them: `native_casts` (one
per ray), `budget_exhausted`, the read's epoch and both exclusion facts true, and hit rows with
vector position and normal, the fraction, and measured zero surface motion with `motion =
"measured"`. Every read carries its selected source, so every guard plan is bound to a qualified
Framev1, which the invariants check on every read. Wheel rows are built from those rays as
`ride_runtime.lua` builds them. `sim_world.lua`'s integrator stands in for native
physics, applying each submitted command within its own step, and the test then accepts it. The
test also stands in for the native support owner: it reports the world's wheel contact as
`measured_support` and knows nothing of pegs, as native collision does not. The constructed caller
casts every lane as its own batch, so these scenarios run with `batches_per_read = 4`, Core's
default allowance (see Batches). The pad goes through the real mapping, and every module above is
the real one with its own defaults unless stated. A read that submits nothing leaves the body to
the constructed stand-in for native physics: the ground holds it up for that step if a wheel was
supported, and otherwise it falls freely. Measured 2026-10-25, and measured again after the guard
binding became mandatory: every number in this table and in the Batches table was unchanged, line
for line. Measured again after every unguarded read began to fail closed: every number in this
table is unchanged, line for line (pedal, brake, hop, manual, barspin, nose-dive bail and
recovery, head-height bar, rail). With 4 batches no riding read is unguarded except the one
recovery read of the nose dive, which now submits nothing and leaves the 2.489 m/s unchanged. The
Batches table's 1- to 3-batch rows changed as stated there.

| Scenario | Script | Measured |
| --- | --- | --- |
| Pedal, coast, brake | From rest: A for 4 s, 0.5 s coast, B to a stop. | 3 m/s in 1.200 s, 6 m/s in 2.383 s, 7.751 m/s after 4 s. Coast loses nothing. Brake: 2.183 s and 8.414 m to rest, 3.55 m/s^2 mean. Rolling throughout. |
| Bunny hop | R3 at 4 m/s. | Takeoff 4.337 m/s up, COM apex 0.996 m, 0.900 s from the hop read to the first supported read. Lands at 4.32 m/s down and rides on at 4.0 m/s. rolling -> airborne -> rolling, and the trick model sees take-off and landing. |
| Manual | Right stick -0.53 (input manual 0.492) for 2 s at 4 m/s, then neutral. | The pull starts the balance; the mode stays rolling until the front tyre leaves support 0.100 s later, then manual. The tyre clears its 2 cm contact gap 0.083 s after that, then goes past the 0.15 m wheel ray. `balancing` from 0.617 s after lift-off until the release 1.900 s after it: 1.283 s, 101 samples. Peak pitch 0.217 rad, mean balancing pitch 0.193 rad, below the 0.22 rad point (the sag MANUAL_BALANCE.md records). Front down 0.400 s after release (`front_drop`). 2.3 s in manual mode in all. |
| Manual held through a landing | R3, then the -0.53 pull held in the air and after landing. | No lift for the 40 held samples after landing. The balance is idle with manual 0. After 6 neutral samples, a fresh pull enters a manual from rolling. |
| Manual loop-out | -0.74 (manual 0.969) held. | `loop_out` 0.900 s after lift-off, at pitch 0.203 rad. A bail request; bail_policy saw no contact, so it is reported as unrealized and the mode returns to rolling. |
| Barspin | R3, then LB + right stick back for one sample in the air, then neutral. | Selected 0.067 s after take-off, caught 0.467 s later, combo landed 0.433 s after the catch with 1 barspin. The presented bar turns exactly 2 pi. The pose is identical with and without matrices. |
| Barspin without a support owner | The same, with `tick.support` absent, labelled `geometry`, or grounded without a point. | `trick_runtime` refuses every read (`physical_support_unqualified`) and no trick event fires. The ride still hops and lands. |
| Hard landing | R3 at 4 m/s with the left stick held forward (air nose-down) until the bail. | Bail 0.967 s after the hop: `hard_rider_contact`, head, closing 5.49 m/s, alignment -0.873 (inverted), COM 0.592 m up. Nothing submitted while bailed. After 30 reads the caller places the bike again: `recovered` -> rolling, and that read submits nothing (`recovered_unjudged`); the next is judged without sweep history. 2.489 m/s after 1 s of pedal. |
| Head-height bar | Coast at 3 m/s into a 60 mm bar at 1.40 m. | rolling -> bailed at z 2.80: `swept_body_crossing`, head, 2.60 m/s, alignment -0.498. |
| First-read bail | Start at z 2.77 under the same bar. | none -> bailed on the first read (`hard_rider_contact`), inside the graph. |
| Rail, default grind tuning | 8-sample charged flick (take-off 2.231 m/s) at 5 m/s onto a rail with a 0.45 m crest. | `double_peg` lock-on 0.350 s after the hop at 1.036 m/s closing. A peg touches on 2 reads, then the bike rolls off to its right side: `rail_end` after 0.133 s at z 7.23. It lands next to the rail, leaning right. |
| Rail, assist at its maxima plus a feedback rider | As above, with `grind_policy` roll and yaw assist at stiffness 1000, damping 200, cap 400 N m, no yaw deadband. The scripted left stick is steer 0.14 right plus ten times the measured roll. | The same lock-on. A peg touches on 51 reads; 0.850 s grinding along the whole 4 m rail. Exit `grounded` at z 10.31, when the front tyre touches down past the rail's end with the rear peg still on. 5.0 -> 4.01 m/s (peg friction 0.12). |
| Rail, full R3 hop | R3 from five take-off points. | 0 of 5 lock on. Each time the pegs go from more than 5 mm above the crest to more than 30 mm into it within one step, `grind_policy` holds on `invalid_contact`, and the bike falls through. |
| Rail at peg height, rolling | Coast through it at 3 m/s. | Never grinds, and no rail probe is planned while supported. |
| Preset | `trigger_pedal` settings, RT held 1 s, then A held 1 s. | RT: 0 m/s. A: 2.489 m/s. Only the settings compose. |

The receipt, refusal and hold cases are listed under Tests.

## Per-tick cost

Each tick's cost is the time inside `plan`, `witness` and `step` together, measured with `os.clock`
in the pure runner. It excludes the test's ray casting and integration, the Host's dispatch and the
native calls. `plugin_vm.h` allows 50 ms for each call and a 2 ms average per tick over 1 s windows,
which stops the plugin after three windows in a row over it. The average is the bound that matters
here. Three scenarios were each run three times, and the per-tick minimum of the three is the
estimate least disturbed by other work. The desktop (i7-9700K) was shared with other agents during
every run below.

| Run (load before / after) | Kernel alone, coasting preview/adopt | Composer, least-disturbed mean: hop, rail, barspin, barspin with matrices | All 3793 ticks of one pass (before the batch cases) |
| --- | --- | --- | --- |
| 74% / 86% | 0.270 ms (FORCES.md: 0.310 ms idle) | 0.84, 0.91, 0.70, 1.08 ms | median 1.02 ms, p95 3.19, p99 5.69, max 50.7 |
| 71% / 39% | 0.255 ms | 0.95, 0.86, 0.68, 1.01 ms | median 1.59 ms, p95 7.28, p99 23.6, max 130 |

- The earlier revision, on a quieter desktop, measured 0.65-0.84 ms (and 1.00-1.16 ms with
  matrices) with the kernel at 0.227-0.268 ms; an independent rerun of it measured 0.69, 0.80, 0.71
  and 1.12 ms with the kernel at 0.239 ms. This revision adds a preview clone of the kernel per tick
  (FORCES.md: 0.310 ms preview/adopt against 0.298 ms step) and a copy of the rider output without
  its handles. At the barspin's 0.70 ms against a 0.270 ms kernel, the two revisions are within the
  noise of a shared desktop. No idle-desktop figure was taken for this revision.
- The batch layout and the batch source checks, one run each with the load not recorded. Before
  them: 1.30, 1.34, 1.28 and 1.64 ms least-disturbed, with the kernel at 0.350 ms. After them:
  0.88, 1.40, 1.09 and 1.47 ms, with the kernel at 0.272 ms, and the whole 5034-tick pass (the batch
  cases included) at median 1.27 ms, p95 4.39, p99 8.25 and max 22.5. Both runs are inside the
  shared desktop's noise, so no cost is attributed to the change.
- The mandatory guard binding (a `Frame.copy` in `plan`, the guard's own copy and history
  `Frame.classify`, and `Contact.decode` on the guard and witness batches), one run each before and
  after on the shared desktop, with the kernel calibration at 0.250 and 0.244 ms: least-disturbed
  means 0.59 -> 0.72 ms (hop), 0.67 -> 0.79 (rail), 0.62 -> 0.82 (barspin) and 0.90 -> 1.07 (barspin
  with matrices); whole pass median 0.80 -> 0.88 ms, p95 1.61 -> 1.67, max 4.15 -> 3.01. About
  0.1-0.2 ms per tick, from one run each.
- Failing closed on every unguarded read (a few comparisons in `step`), one run each before and
  after on the shared desktop, with the kernel calibration at 0.248 and 0.245 ms: least-disturbed
  means 0.75 -> 0.72 ms (hop), 0.80 -> 0.82 (rail), 0.76 -> 0.73 (barspin) and 1.02 -> 0.97 (barspin
  with matrices); whole pass median 0.86 -> 0.85 ms, p95 1.61 -> 1.67, max 2.88 -> 8.96 (one tick,
  over 5034 and 5037 ticks). Inside the noise; no cost is attributed to the change.
- Building the eight part matrices costs 0.3-0.4 ms per tick. `trick_presentation`'s own stage
  builds them twice per step. That is why the composer steps `trick_runtime` itself and builds them
  on demand.
- The least-disturbed per-tick work fits the 2 ms average. It does not include the Host's call
  overhead, the native cost of up to 57 raycasts, or the rest of the plugin. Under this load the
  whole-pass p95 is over 2 ms and the maxima reach 51-130 ms: stalls a Host would count.
- The only cost assertions are that the median least-disturbed tick is inside 20 ms and the
  suite-wide median is inside 20 ms. The tails are reported, not asserted.
- **Require.** `require("./ride_composer")` loads the whole chain (28 modules, the composer
  included). From a cold VM in the pure runner it took 34.3, 37.3, 43.5, 39.6 and 35.7 ms (warm
  file cache), and `Composer.new` 0.14-0.39 ms. An earlier independent run measured 326 ms with a
  cold file cache. The chain does not include `bike_runtime_core`: importing Core for its batch
  allowance cold-loaded Core, `equipment_runtime`, `equipment_transition` and `bike_admission`
  too, and in six interleaved cold runs on a busy machine took 51.7-58.5 ms against 43.4-49.1 ms
  without it, so the composer writes the allowance as a literal. `plugin_vm.h`'s 50 ms limit
  covers the load call too, so requiring the composer at load leaves little room, and requiring
  it inside a handler would spend a whole call on it.

## Gaps found

Each of these keeps the composition short of riding, and each would take a change outside this
item to close. Native exclusion remains a blocker (gap 13); several other limits show only once
it is gone.

1. **Four batches still share the SDK budgets.** Core's former one-batch restriction is closed
   in Lua: four separate lanes fit its per-serial call allowance. Each batch still holds 1 to 32
   rays, every VM tick still has 64 logical requests and 64 native casts, and the worst-case four
   lanes plus camera ask for 81 requests. The composer refuses lanes that do not fit rather than
   splitting, merging or deferring them. The offline 3-batch result holds for its three scripts
   only; four Core calls do not prove a native four-batch result or bypass actor exclusion.
2. **No roll balance on a rail.** A rail row carries only the crest normal, which is vertical, and
   friction along the rail. A grinding bike therefore gets no lateral force, and its centre of mass
   cannot move sideways. `grind_policy`'s assist works from `tilt`, the contact-to-COM line, which
   cannot change with roll in that case, so no assist gain alone gives a restoring torque in roll.
   Holding a left-peg double peg needs about m g x 0.104 m = 108 N m against the rail's lever. The
   assist is off by default, and the default 40 N m/rad with its 120 N m cap is far short of that.
   Measured: 2 contact reads with the defaults. With the assist at its maxima plus a rider leaning
   on the measured roll at every 60 Hz sample, the grind held 0.85 s. A roll term in the assist, a
   radial normal on round rails, or a lateral constraint would each be a change to `grind_policy`,
   `rail_probe` or `grind_contact`.
3. **Peg tunnelling at 60 Hz.** `grind_contact` acts only from 5 mm above to 30 mm into the rail.
   That window is 35 mm wide, so a peg closing faster than about 0.035 m / (1/60 s) = 2.1 m/s can
   skip it in one step. `grind_policy`'s `max_penetration` can be raised, but `grind_contact`'s
   30 mm is fixed. Measured: a full R3 hop meets the rail at about 3.9 m/s and tunnelled 5 times out
   of 5.
4. **Rail under the centre ray.** `rail_probe` needs its centre ray on a 50 mm rail, which allows
   ±25 mm. That is about 2 degrees of roll. Past it the probe reads `unclassified_surface` and the
   grind holds and then ends `contact_unavailable` (RAIL_PROBE.md lists this limit).
5. **No hop off a rail.** `forces.lua` applies a hop only with wheel support, so `grind_policy`'s
   `hop_out` has nothing to realise it. It is reported as `diagnostics.grind.hop_unrealized`.
6. **Policy bail requests have no route into `bail_policy`.** `bail_policy` reads only guard contacts,
   so the loop-out and balance-lost requests are reported, not executed.
7. **A flat hard landing cannot bail, and the residual sees nothing offline.** The frame guards sit
   0.25 m or more above the ground while the wheels stay within the kernel's 0.10 m penetration. Only
   over-rotation or a rider or frame contact bails. The residual proxy was evaluated on the 4656
   scenario reads that follow a submitted command and never exceeded 0.000047 N s, the rounding of
   the float vector samples, because `sim_world` applies exactly the submitted command and nothing
   else touches the body. (After a read that submitted nothing while the constructed ground held the
   bike, it rightly sees about m g h = 17.3 N s; those reads are left out of the summary.) Its bail
   branch is therefore never exercised here. It also pairs command N with read N+1, which is
   `sim_world`'s phase; FORCES.md observed native commands applied at N+1 with their effect at N+2,
   so in game it would need the delayed pairing.
8. **Presets bind nothing yet.** `ride_input_mapping.lua`'s `raw_input` hardcodes the default
   binding, so only an `input_presets` settings bundle composes. `trigger_pedal`'s RT does not pedal.
9. **No support owner exists in game.** `trick_runtime` requires `measured_support`, and the
   composer now takes it only from `tick.support`. `Contact.decode` reports support as unknown, so in
   game every trick step is refused until a native owner reports it (B3, M8). Even then, pegs do not
   exist in native collision, so `trick_runtime` would read a grind as air.
10. **Pegs while rolling.** While both wheels are supported the rail probe is not planned, so a peg
   striking a rail from the ground gets no contact response here. Pegs do not exist in native
   collision.
11. **Receipt cadence.** One command waits for its receipt at a time. The offline owner answers
    before the next read, so nothing is withheld here. A native receipt that arrives two reads later
    would withhold every other read's command, and each preview after it starts from a reset kernel.
    A receipt that arrives after the mapping has already dropped the hop (on a ground-context
    change) reports `hop_identity_mismatch` in `last_receipt.hop`.
12. **Require cost.** See Per-tick cost: 34-43 ms of a 50 ms load call.
13. **Nothing is submitted in game today.** Every read `bail_policy` does not judge fails closed
    (see Guard binding). Core's four-call allowance leaves the per-tick SDK limits intact (gap 1),
    and in game every riding guard query is unavailable because the native adapter refuses
    `exclude_local_actor` with `local_actor_exclusion_unavailable` (BAIL.md). So the composer would
    submit no force, torque or hop impulse in game until native exclusion is qualified. This replaces the
    previous revision's gap 13, where those reads still submitted with `bail_policy` not stepped;
    it was closed by choosing to fail closed, not left to the integration.

## Tests

```powershell
& 'C:\Users\Jeffr\Desktop\reskate\build\bmx\parallel-tricks-presentation-proposal-v1\harness\build\Release\presentation_luau_tests.exe' 'C:\Users\Jeffr\Desktop\reskate\contrib\bmx-lab\bmx-plugin\plugin' ride_composer_tests
```

The run prints `cases=27 assertions=72222` and one `ride_composer:` line per measured number. It
took 10-20 s on the shared desktop.

| Case | What it checks |
| --- | --- |
| graph and refusals | The edges (none -> bailed included), `settle`'s refusals including `grind_without_lock_on`, a detached `edges()` copy, malformed ticks submitting nothing, unknown force tuning and out-of-range command limits refused, and receipts refused with nothing waiting or an unknown outcome. |
| duplicate, gap and unknown-support reads | A read without its selected source fails closed: no guard plan, `bail_guard_unbound`, nothing submitted. An unplanned step plans itself uncast and submits nothing (`uncast`). A fully cast and judged read with a neutral pad gives support with no rider control. A command waits for its receipt and the kernel adopts it only on `accept`; a wrong-serial or second receipt is refused. A duplicate submits nothing, a regression is refused, a gap previews from a reset kernel. One budget-exhausted wheel batch while rolling takes no edge, holds the balance, does not arm `grind_policy`, and the next read continues rolling with no landing. Under an explicit one-batch allowance the same fully cast read submits nothing (`batch_allowance`). |
| scenarios | Each row of the table above, with its numbers asserted only where they define the behaviour: speeds reached, airborne on the read after the hop, the manual mode starting at lift-off and more than 1 s balancing, one caught barspin of exactly 2 pi, the bail made by `bail_policy`, the recovery read submitting nothing (`recovered_unjudged`) and the next read judged afresh, 0 of 5 R3 lock-ons. |
| receipts gate the kernel and the hop | A hop arriving while an older command waits: the kernel's preview applies it, the command is withheld, the hop is held, neither retired nor consumed, then sent once and accepted once. A rejected hop is cancelled, the kernel keeps its last accepted history, and the hop never fires later. An uncertain hop blocks the input and leaves the residual unknown. With `command_limits.force = 1`, the composer refuses the hop the kernel applied and cancels it. |
| support provenance belongs to the caller | No support owner, a `geometry` label, or an incomplete grounded fact: every trick step is refused and no trick event fires, while the ride still hops and lands. |
| a refused lock-on is undone in grind_policy | With stubbed balance and grind policies: a lock-on inside a manual is reported as `lock_on_refused`, the manual continues, and the policy is reset; a lingering lock is refused again; in the air, locked without a `lock_on` never enters grinding. |
| a first-read bail is an edge of the graph | none -> bailed on the first read, inside the graph. |
| one plan per read; stale reads move nothing | A repeated plan returns the same plan without stepping the camera; three duplicate reads plan, witness and step nothing and leave the camera exactly where it was. |
| one read carries one batch per lane, inside its allowance | `Composer.layout` at 1 to 4 batches, while grinding too, and a lane of 0 or 33 rays refused as `batch_rays`. Bad `batches_per_read` values refused, and the default is 4, the composer's literal checked equal to Core's `probe_batches_per_serial`. With an explicit one-batch allowance, the rail flick plans only the wheel batch on every read, reports `batch_allowance` for the guard, never steps `bail_policy` as if clear, submits no force, torque or impulse on any read, cancels the flick's hop, never leaves the ground and never locks on; an unsupported read is refused the rail as `batch_allowance`; the head-height bar is coasted through without a bail or a command. At 2 batches: no rail probe and no lock-on, and refused witnesses leave the bar and the nose dive without a bail, each of those reads submitting nothing. At 3: the lock-on and both bails, with witnesses refused while the rail holds a batch, each of those reads submitting nothing. |
| the rail batch is the raw probe_batch on this read's epoch | Control: raw rows on this read's epoch lock on. The previous read's epoch on every rail batch: each is refused as `rail_epoch_mismatch` (and `Probe.decode` says `epoch_mismatch`), with no lock-on. A real `Contact.decode` copy of each read's own raw rows, matched to that read and carrying no epoch, is refused as `rail_batch_contact_copy` (`Probe.decode`: `epoch_mismatch`), with no lock-on. A guard batch on another epoch is refused as `guard_epoch_mismatch` and `bail_policy` is not stepped. |
| a read without a qualified Framev1 plans no guard and submits nothing | While riding at 4 m/s: no source, an `input_ok = false` source, a lease that is not userdata, a source `frame_identity` refuses, an unfocused read and a menu-open read. Each plans no guard and no witness, submits no force, torque or impulse, reports `bail_guard_unbound` with its `guard_binding`, and leaves `bail_policy` unstepped. The next bound read is guarded with no sweep history, and its successor has history again. A hop the kernel applies on an unbound read (held behind an older receipt) is cancelled and never fires later. |
| the guard packet's counterexamples are refused through the composer | A body on its side 5 m up over the review fixture's tiny face under the right grip, on fresh composers. Control: a witness at the foot is contact and seeds a severe tilt, and the judged read submits. A witness beside its line keeps the measured point's distance (0.0063 m) and seeds none; a witness that misses is no contact; both are judged and submit. Eight guard-batch and seven witness-batch edits (wrong and missing epoch, either exclusion false, no or zero `native_casts`, an available batch with a reason, unmeasured surface motion) are refused through `plan`, `witness` and `step` with `bail_policy` unstepped and nothing submitted, and the composer's own bound plan refuses each in the guard too. The previous read's guard batch and witness batch are refused on the next read of the same pose and submit nothing; the plan after the unjudged read has no sweep history. A read with no source has no guard plan and submits nothing. |
| an unguarded read submits no force, torque or hop impulse | A rider rolling at 4 m/s presses R3. Control: the same read with the tiny face under the grip and its witness at the foot is judged (one frame contact, no bail) and submits a 477 N s hop. Each of 24 unguarded reads submits no force, torque or impulse, names its reason as the withheld issue, and retires the hop the kernel applied as `cancelled`: the 8 guard-batch and 7 witness-batch edits, the previous read's guard and witness batches, a guard batch never handed back (`guard_batch_missing`), a witness never called (`witness_not_called`), a witness batch never handed back (`witness_batch_missing`), witnesses with no batch at 2 batches (`witness_batch_allowance`), an explicit one-batch allowance (`batch_allowance`), an invalid bail tuning (`bail_policy_invalid_sample`) and a read with no source (`bail_guard_unbound`). After an unjudged read the next plan has no sweep history and submits; its successor has history again. |
| no opaque handles in status or results | Every result of a barspin run with matrices, `status()` and `matrices()` hold no userdata or function. |
| invariants, every read of every run | Valid results. Every read of a riding scenario plans its guard on a qualified Framev1, and a command leaves only from a bound read that `bail_policy` judged and accepted; every unguarded read submits no force or impulse and names its reason as the withheld issue. Every mode edge is in the graph and starts from the previous mode. Grinding begins only with a `lock_on`, bailed only with a `bail_policy` bail, and leaves only on `recovered`. Never airborne -> manual. Nothing submitted while bailed. Every command names its read. Requests within 64, no more batches than the read's allowance, every cast batch 1 to 32 rays, the composer's own batch count matching the batches cast, finite commands, and camera views `camera.look` accepts. |
| per-tick cost | Three-run minima for the hop, the balanced rail and the barspin with and without matrices, plus the kernel's preview/adopt calibration. |

## Not proven

- None of this ran in the game. The world, its rays, its zero surface motion, its exclusion facts,
  its cast counts and its support owner are constructed. The Framev1 the guard is bound to is
  built from constructed sources with `newproxy` handles; Lua cannot authenticate native userdata,
  and no native source adapter has supplied `tick.input` to the composer. Native command latency (applied at N+1, FORCES.md) is not
  modelled, and the offline receipt always arrives before the next read. The frame, rider and pegs
  collide with nothing except through the composer's own contacts.
- That native physics holds a bike the composer stops pushing is assumed, not measured. On a read
  that submits nothing, the constructed ground only cancels gravity for one step while a wheel was
  supported; no native body has been left unpushed under the composer.
- The ordinary scenarios use Core's four-batch default; the 1-, 2- and 3-batch counterexamples
  request smaller allowances explicitly. Nothing here demonstrates four batches through the
  native Core adapter in game. The 3-batch result holds for this world's three scripts only.
- The scripted rider on the rail is faster and steadier than a person. It shows the composition can
  carry a grind when roll is held, not that a player could hold one.
- The landing evidence and the crank cadence are the composer's own stand-ins for the C++ landing
  Tracker and a measured crank. The receipt join is the composer's side only; no native receipt
  has been read through it.
- The refused lock-on case uses stubbed policies; the real `grind_policy` was not driven onto a rail
  inside a manual.
- Whether the Host's call overhead and the native raycasts leave the per-tick work inside the 2 ms
  average is unmeasured, and no idle-desktop cost was taken for this revision.

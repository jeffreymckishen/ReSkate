# Named control presets

`plugin/input_presets.lua` turns one SDK pad table into the fields of
`Input.raw` and carries a complete Input settings bundle for that binding. It
calls no `reskate.*` service, and requiring it runs no tests. Nothing reads it
yet: `ride_input_mapping.lua` still builds its raw table by hand, and `main.lua`
and the manifest are unchanged. Wiring a preset into the mapper is a later change.

```lua
local Presets = require("./input_presets")
local preset = Presets.get("trigger_pedal")
local mapper = Input.new(preset:settings())
-- pad is reskate.input.gamepad() or an input-lease sample's pad; device is the
-- uint32 routing key Input expects (the mapper passes the selected slot).
local raw, issue = preset:raw(pad, device)
```

| Role (Input.raw field) | `default` | `trigger_pedal` | `left_handed` |
|---|---|---|---|
| `pedal` | A (South), 1 or 0 | RT, analog | A (South) |
| `brake` | B (East), 1 or 0 | LT, analog | X (West) |
| `quick_hop` | R3 | R3 | L3 |
| `left_shoulder` | LB | LB | RB |
| `right_shoulder` | RB | RB | LB |
| `left_trigger` (trick modifier) | LT | X (West), 1 or 0 | RT |
| `right_trigger` (trick modifier) | RT | B (East), 1 or 0 | LT |
| Settings | Input defaults | `trigger_neutral` = 30/255 | Input defaults |

`default` is the binding at `ride_input_mapping.lua:98-105`.

`trigger_pedal` moves pedalling and braking to analog triggers. That frees the
right thumb on the ground: under `default`, pedalling on A takes it off the
stick that manuals and preloads hops. The cost is in the air. Its trick
modifier roles move to X (West) and B (East), but Input reads the modifiers in
the same frame the right stick selects a trick, and on a standard grip the
right thumb presses both. So on a standard grip only the shoulder sets (2, 3
and 4) can be selected. Sets 0, 1, 5, 6 and 7 need a claw grip, with an index
finger on the face buttons. With LT and RT taken, L3 is the only other control
a standard grip leaves free, and there are two modifier roles to place. Its
`trigger_neutral` is `XINPUT_GAMEPAD_TRIGGER_THRESHOLD` (30/255) from
Microsoft's published XInput.h: a trigger resting just above 0.05 would
otherwise pedal and keep the neutral gate shut.

`left_handed` is `default` mirrored across the pad's vertical centre line:
LB/RB, LT/RT, L3/R3 and West/East trade roles. Trick names and directions do
not change; only the physical button that supplies each role moves.

The same rules hold for every preset, including custom ones from
`Presets.compile(descriptor)` (start from `Presets.descriptor(name)`):

- The sticks pass through unchanged and cannot be bound. The left stick
  steers and rotates, the right stick hops, manuals and selects tricks. The
  judging rubric fails any mapping that contradicts that.
- The D-pad (`dpad_reserved`), North/Y (`north_reserved`, the equipment toggle
  and dismount gesture) and Start/Back (`menu_reserved`) cannot be bound. Tests
  also flip each of them on every sampled pad and check that the output does not
  change.
- All seven roles must be bound, each to a different control. If one control
  fed both the pedal and a trick modifier, pedalling would reserve rotation
  through the mapper's raw modifier check.
- A button feeding a numeric role reads 1 or 0. A trigger may feed only a
  numeric role.
- Settings may name only Input settings, with finite values. Input clamps
  values silently, so a value the clamp would change is refused
  (`setting_out_of_range`) rather than replaced. Some bounds depend on another
  setting, so a named value can also move a default the preset did not name:
  `{ trigger_neutral = 0.2 }` would lift `modifier_threshold` from 0.2 to 0.25.
  That is refused too (`dependent_setting_out_of_range`, naming the moved
  setting). Naming the dependent value as well, here
  `modifier_threshold = 0.25`, compiles. Every value in a bundle is therefore
  one the preset named or Input's own default.
- A pad must have the shape `ride_input_mapping.lua` admits, and it must contain
  every button the preset reads. Every pad that mapper accepts is accepted by
  `default`.

`get` returns only the built-ins, and `compile` registers nothing. Each handle
and the method table behind it are frozen, so neither assignment nor `rawset`
can change a handle or shadow a method, and the metatable cannot be swapped.
The compiled bindings are held outside the handle, and accessors return copies.

## Tests

`plugin/input_presets_tests.lua` (13 cases, 99,231 assertions on 2026-10-25,
`presentation_luau_tests.exe <plugin> input_presets_tests`):

- **The default against the real mapper.** Each sample goes through
  `ride_input_mapping.lua`'s `observe`, and the raw table it built (its private
  `_raw`, read only by the test) is compared with `default:raw` on the same pad.
  The samples are all 16,384 combinations of the 14 SDK buttons, every stick
  extreme and trigger end against all 32 combinations of the five buttons it
  reads, exact int16 and uint8 endpoints, 3,000 random pads over users 0-3 in
  both contexts, a five-button pad and a frozen lease-style pad.
- **The action stream.** Two 3,000-step traces, one grounded and one airborne,
  compare the mapper's actions with a separate Input mapper fed only
  `default:raw`. Hops and tricks are both exercised.
- **The alternatives through Input.** For `trigger_pedal`: a proportional
  throttle, a resting trigger that does not pedal, X/B selecting the trigger
  trick sets and tailwhip (a claw-grip input), and a held throttle that never
  selects a set. For `left_handed`: RB reaching the LB trick set, L3 hopping
  and R3 not hopping. `left_handed:raw(mirror(pad))` equals `default:raw(pad)`
  for all 16,384 button combinations.
- **A grip model.** Each preset is run through Input in the air with the right
  stick in each of the eight slot directions. The modifiers held are every
  combination of the controls a standard grip leaves free while the right thumb
  is on that stick: LB, RB, LT and RT. `default` and `left_handed` reach all
  eight sets. `trigger_pedal` reaches only sets 2, 3 and 4, and reaches all
  eight once X and B are added (a claw grip). The model only says which
  controls can be held together. It says nothing about comfort.
- **Refusals.** 76 invalid descriptors, the dependent-default refusal naming
  `modifier_threshold`, 15 malformed pads (the hardcoded mapper refuses the same
  15), invalid devices, forged handles, and `rawset`, metatable and
  method-table edits on every built-in handle.

Mutation check, 2026-10-25: 18 hand-made faults, each applied in turn to
`input_presets.lua`, and each made the suite fail. The file was restored after
each run and its hash checked at the end. The faults were brake on West, R3
moved to L3, a 0.99 press value, `right_y` dropped, a thresholded trigger axis,
North bindable, D-pad up bindable, duplicate sources allowed, silent clamping
of a named setting, silent clamping of a dependent default, an unfrozen handle,
an unfrozen method table, the needed-button check dropped, the playstation type
check dropped, `trigger_pedal` modifiers swapped, `trigger_pedal` threshold
dropped, `left_handed` shoulders unmirrored, and a `trigger_pedal` modifier on L3.

These are constructed pads. They show agreement with the hardcoded mapper. They
do not show native button consumption or in-game feel. They also do not show
that left-handed players want this mirror, that 30/255 suits a worn trigger, or
that the shoulder-only air game `trigger_pedal` leaves a standard grip is worth
having.
No preset has been tried in the game. Presets do not cover the equipment
shortcut. `equipment.lua` takes its North and shoulder booleans from its own
caller, and no preset defines them; under `left_handed` that caller would have
to decide which physical shoulder to pass.

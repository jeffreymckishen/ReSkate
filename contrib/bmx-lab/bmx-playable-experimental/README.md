# BMX beta

Ride a BMX in skate. It is a plugin mod: the bike's physics, the rider's pose, hops, tricks and the score panel
are all Luau on ReSkate's general plugin APIs.

It needs the separately installed `BMX_Prototype` asset pack for the bike's model, which is not part of this
package, and a ReSkate build with the session follow API. The pack must have its wheels and cranks authored about
their own hubs; the mod refuses an older one and says so.

## Playing

Put this folder in `Mods`, start the game and turn the plugin on when it asks.

Stand on foot on fairly level ground with a little room around you, hold LB, then press A, and let go of the
controls while the bike gets ready. The BMX page in the Insert menu says the same and shows what the mod is doing.

- A pedals, B brakes, the left stick steers.
- Click the right stick to hop. For a smaller hop, pull the right stick back and flick it forward: the longer it was
  held back, the higher the hop.
- F8, or hold LB + RB and click R3, goes back to the skateboard.
- From the skateboard, hold LB, then press A to ride again. Stand still and let go while the rider steps off.

Mounting and going back to the skateboard can be changed in Binds. Pedal, brake, steering and hop cannot.

## Smooth riding

Set Settings, Graphics, Target frame rate to **60 FPS** and VSync to **Off**. On a high refresh screen VSync On
makes the game's 60 steps a second land on uneven refreshes, which reads as judder in everything, the bike
included. Measured on a 170 Hz screen, frames arrive 16.7 ms apart with VSync Off, and at a mix of 12, 18 and 24 ms
with it On. Every 2nd refresh with Uncapped is also steady, at 85 frames a second. The change applies at once. Played
offline the game does not keep it, so set it again each launch.

## What to expect

- Each game launch allows eight mounts. ReSkate keeps the bodies and input leases of a mount for the whole launch,
  so a ninth needs a restart.
- Pausing, opening Insert or leaving the game ends the ride. The rider goes back to the skateboard on their own once
  the menu is closed and the controls are released.
- Top speed is about 7.7 m/s on the flat. The rider stops pedalling there and coasts down to about 7.2 m/s before
  pedalling again. A hill can take the bike much faster than that, and a coast slows by itself.
- A stopped bike holds on a street grade, so hold A for a moment to start down a gentle hill. Ramps steeper than about 15% roll back.
- A crash (the bike going over, a hit at speed, or the rider being knocked off) gets back on the bike after a few
  seconds, which spends a mount. On the last mount of a launch it goes back to the skateboard instead. Banks and
  quarter pipes do not count as going over. If there is no room to get back on, move and mount again.
- A slower bump into something just stops the bike, and it has no reverse. If it is stuck, go back to the skateboard.
- Riding into a parked car stops the bike at the bumper. Faster than about 4 m/s it is a crash, over the bars.
- Mounting refuses ground steeper than 12 degrees and anywhere without room for the bike.
- The score panel is the mod's own, and its numbers are not yet tuned against the game's scoring.

## Tests

`Test/` holds the Lua suites and `Test/two_cycle_tests.json` lists them. See `Test/README.md`.

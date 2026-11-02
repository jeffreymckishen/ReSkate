# BMX beta

Ride a BMX in skate. It is a plugin mod: the bike's physics, the rider's pose, hops, tricks and the score panel
are all Luau on ReSkate's general plugin APIs.

It needs the separately installed `BMX_Prototype` asset pack for the bike's model, which is not part of this
package, and a ReSkate build with the session follow API.

## Playing

Put this folder in `Mods`, start the game and turn the plugin on when it asks.

Stand on foot on fairly level ground with a little room around you, hold LB, then press A, and let go of the
controls while the bike gets ready. The BMX page in the Insert menu says the same and shows what the mod is doing.

- A pedals, B brakes, the left stick steers.
- Click the right stick to hop.
- F8, or hold LB + RB and click R3, goes back to the skateboard.
- From the skateboard, hold LB, then press A to ride again. Stand still and let go while the rider steps off.

All of these can be changed in Binds.

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
- A crash (tipping past 55 degrees, a hard roll, or the rider being knocked off) gets back on the bike after
  a few seconds, which spends a mount.
- The bike rolls through parked cars. The rider does not, which counts as a crash.
- Mounting refuses ground steeper than 12 degrees and anywhere without room for the bike.
- The score panel is the mod's own, and its numbers are not yet tuned against the game's scoring.

## Tests

`Test/` holds the Lua suites and `Test/two_cycle_tests.json` lists them. See `Test/README.md`.

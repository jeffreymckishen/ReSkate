# BMX beta

Ride a BMX in skate. It is a plugin mod: the bike's physics, the rider's pose, hops, tricks and the score panel
are all Luau on ReSkate's general plugin APIs.

The bike comes with it. The mod folder holds the plugin and the bike's own native pack (`layout.toc`,
`.reskate-studio-patch`, `BMX-NATIVE.txt` and `Win32`), so there is nothing else to install. It needs a ReSkate build
with the session follow API. The bike is "BMX (Free)" by Ermakov, CC BY 4.0: see `CREDITS.md`.

An older separate `BMX_Prototype` pack is no longer needed. Remove it from `Mods`, or turn it off: both add the same
bike, and whichever is higher in the mod list supplies it, so an old copy can stand in for this mod's bike. The mod
refuses a bike whose wheels are not authored about their own hubs and says so.

Do not turn this mod on together with the ReSkate FPV Drone mod. The bike is built on the drone's template and uses
its frame texture's names, so with both on, one of them is drawn with the other's texture.

## Playing

Put this folder in `Mods`, start the game and turn the plugin on when it asks. The bike's model loads with the
game's data, so a mod turned on while the game runs needs APPLY TO LOAD in the modding menu, or a restart, before
the bike can spawn; until then the mod says the bike's model is not loaded.

Stand on foot on fairly level ground with a little room around you, hold LB, then press A, and let go of the
controls while the bike gets ready. The BMX page in the Insert menu says the same and shows what the mod is doing.

- A pedals, B brakes, the left stick steers.
- Click the right stick to hop. For a smaller hop, pull the right stick all the way back and flick it forward: the
  longer it was held back, the higher the hop.
- Pull the right stick part of the way back for a manual: the front wheel comes up and the bike rolls on its back
  wheel. A little back holds it low, about 20 degrees, further back holds it higher, up to about 36, just past where
  the rider balances. A little past the end of that, the manual stays at its highest. Let the stick go and the
  front comes down.
- A manual lifts from a little faster than a walk, so with A and the stick held from a stop the bike pedals up to
  that first. A manual coasts: the rider stops pedalling while the front is up, even with A held, and puts the
  front down once the bike slows to a walk. A manual that ends because the bike slowed to a walk does not start
  again until the stick is let go, so with A held the rider pedals on instead of lifting the front again.
- Steer a manual with the left stick. The bike carves on its back wheel, more gently than on two.
- Hold B in a manual and the front comes down: in under a second from a low manual, in about two from the highest.
  It stays down while B is held. Tap B to save a manual going over backwards.
- To hop out of a manual, pull the right stick all the way back and flick it forward, as for any hop. The front
  stays up while the stick is held back. Clicking the right stick hops at once. Either way the rider pushes the
  bars forward as the bike pops, and it lands near level.
- Hold the stick part way back as the bike lands and it lands into a manual.
- Thrown back past about 45 degrees, by a bump or a landing too steep, the bike goes over backwards and it is a
  crash. The stick alone never takes it that far.
- Push the right stick part of the way forward for a nose manual: the back wheel comes up and the bike rolls on its
  front wheel, the rider's weight over the bars. A little forward holds it low, about 23 degrees, further forward
  holds it higher, up to about 30, short of where it would tip over the bars. All the way forward holds it at its
  highest. Let the stick go and the back wheel comes down.
- A nose manual starts, coasts and ends like a manual: it lifts from a little faster than a walk, the rider stops
  pedalling while the back wheel is up, and puts it down once the bike slows to a walk.
- Steer a nose manual with the left stick: the back of the bike swings round the front wheel.
- Hold B in a nose manual and the back wheel comes down in under half a second. It stays down while B is held. Past
  the balance the rider eases off the front brake, so B does not throw the bike over the bars.
- To hop out of a nose manual, click the right stick. Pulling the stick back to charge a flick hop lets the nose
  manual go, but the back wheel takes about a third of a second to come down, so a flick pops with it still up and
  the bike leaves nose down. For a level hop, let the stick go and flick once the back wheel is down. Hold the stick
  part way forward as the bike lands front first and it lands into a nose manual.
- Tipped on past about 50 degrees, by a bump, a kerb or a landing too steep, the bike goes over the bars and it is a
  crash. The stick alone never takes it that far.
- In the air, hold a button and push the right stick all the way over for a trick: LB or RB and down for a barspin
  left or right, LB or RB and left or right for a one hander, LT and RT together and left or right for a tailwhip,
  LT or RT and left or right for a one footer. Let the stick come back to the middle before the next one, and finish
  it before landing.
- F8, or hold LB + RB and click R3, goes back to the skateboard.
- From the skateboard, hold LB, then press A to ride again. Stand still and let go while the rider steps off.

Mounting and going back to the skateboard can be changed in Binds. Pedal, brake, steering, hop and the manuals cannot.

## Smooth riding

Set Settings, Graphics, Target frame rate to **60 FPS** and VSync to **Off**. On a high refresh screen VSync On
makes the game's 60 steps a second land on uneven refreshes, which reads as judder in everything, the bike
included. Measured on a 170 Hz screen, frames arrive 16.7 ms apart with VSync Off, and at a mix of 12, 18 and 24 ms
with it On. Every 2nd refresh with Uncapped is also steady, at 85 frames a second. The change applies at once. Played
offline the game does not keep it, so set it again each launch.

## What to expect

- Getting back on reuses the bike from the last ride, so mounts are not limited. Changing level or reloading the mod
  needs a new one, and a game launch can make eight, shared with other mods: past that, restart the game.
- Pausing, opening Insert or leaving the game ends the ride. The rider goes back to the skateboard on their own once
  the menu is closed and the controls are released.
- Top speed is about 7.7 m/s on the flat. The rider stops pedalling there and coasts down to about 7.2 m/s before
  pedalling again. A hill can take the bike much faster than that, and a coast slows by itself.
- Pedalling has a rider's power, not a motor's. Up a ramp steeper than about 15% the bike slows with A held, the
  steeper the slower, while the city's hills still climb at close to full speed.
- Riding into a kerb costs some speed as each tyre strikes it, more for a taller one. Hop clear of its top to keep
  your speed: a hop that falls short still strikes it.
- A stopped bike holds on a street grade, so hold A for a moment to start down a gentle hill. Ramps steeper than about 15% roll back.
- A crash (the bike going over, a hit at speed, or the rider being knocked off) gets back on the bike after a few
  seconds. Banks and quarter pipes do not count as going over. If there is no room to get back on, move and mount
  again.
- A slower bump into something just stops the bike, and it has no reverse. If it is stuck, go back to the skateboard.
- A nose manual rides over small bumps and kerb ramps. With the stick past about half way, a steep kerb face or a
  bump of about 12 cm often throws it over the bars below about 3 m/s and can still do it at 5 m/s, and so can a
  pothole or dip of 6 to 10 cm met at 2.5 to 3 m/s. Held low, with the stick a little forward, it rides a 12 cm bump
  at a jog, and on two wheels or in a manual the same kerb face just stops the bike.
  Carved at full lock, a bump of about 8 cm met at 4 to 6.5 m/s can swing the back of the bike right round, and now
  and then throws it over; carved at full lock down a steep hill, a 5 cm bump met faster than about 7.5 m/s can too.
  The rider is drawn hips up over the bars, which shows less of the weight shift than the physics uses.
- Riding into a parked car stops the bike at the bumper, in a nose manual too: the back wheel comes down with the
  front tyre at the bumper. Faster than about 4 m/s it is a crash, over the bars.
- Mounting refuses ground steeper than 12 degrees and anywhere without room for the bike.
- The score panel is the mod's own, and its numbers are not yet tuned against the game's scoring.

## Tests

`Test/` holds the Lua suites and `Test/two_cycle_tests.json` lists them. See `Test/README.md`.

## Rebuilding the bike

In the source, `bike/` holds the bike's own data: the lightened model and its atlas. The native pack is built from
it and the game's own files when the mod is packaged (`assets/models/bmx/build_bike_pack.py`), because the pack's
indexes and shader tables come from the game and are not kept in the repository. `bike/README.md` says how to
rebuild the pack, and the data itself from the model.

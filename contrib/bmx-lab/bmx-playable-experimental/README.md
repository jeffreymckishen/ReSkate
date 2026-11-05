# BMX beta

Ride a BMX in skate. It is a plugin mod: the bike's physics, the rider's pose, hops, tricks and the score panel
are all Luau on ReSkate's general plugin APIs.

The bike comes with it. The mod folder holds the plugin and the bike's own native pack (`layout.toc`,
`.reskate-studio-patch`, `BMX-NATIVE.txt` and `Win32`), so there is nothing else to install. It needs a ReSkate build
with the session follow API and body reuse (`world.physics.reuse`): an older one refuses to load it. The bike is
"BMX (Free)" by Ermakov, CC BY 4.0: see `CREDITS.md`.

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
If there is no room or the ground is too steep, move and mount again. If the rider is on the skateboard, or moves
while the bike gets ready, the HUD says to step off or stand still, and the next Mount tries again.

- A pedals, B brakes, the left stick steers.
- Click the right stick to hop. A full hop rises about 0.6 m, a street bunny hop, with about three quarters of a
  second in the air. For a smaller hop, pull the right stick all the way back and flick it forward: the longer it
  was held back, the higher the hop, up to the full hop at a quarter of a second.
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
  bars forward as the bike pops, and a full hop lands near level. A smaller flick out of a high manual has less
  time to come level and lands nose up, more so the smaller it is.
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
  it before landing. A full hop has room for one trick started within about a third of a second of the hop: a
  barspin or a tailwhip takes about 0.4 s with the catch, and the stick has to be back in the middle within about a
  third of a second of starting it, or the bike lands mid-turn. A one hander or one footer can be held over for
  about 0.3 s and still come back before the wheels touch; held longer, the wheels touch with the hand or foot off.
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

- Getting back on reuses the bike from the last ride, so mounts are not limited. Reloading the mod needs a new one,
  and a game launch can make eight, shared with other mods: past that, restart the game. After changing level,
  restart the game to ride again.
- Pausing, opening Insert or leaving the game ends the ride, and the HUD says "The ride stopped. Going back to the
  skateboard." The rider goes back to the skateboard on their own once the menu is closed and the controls are
  released. Then hold LB and press A to ride again.
- Top speed is about 7.7 m/s on the flat. The rider stops pedalling there and coasts down to about 7.2 m/s before
  pedalling again. A hill can take the bike much faster than that, and a coast slows by itself.
- Whenever the rider stops pedalling, coasting, at top speed or in a manual, the cranks come round to level, feet
  at 3 and 9 o'clock, within about half a second at 1 m/s and up: back, as a rider backpedals, or forward with
  the back wheel when that is sooner. A tap of A from level cranks finishes its half stroke forward with the back
  wheel, about a second at 2 m/s and half a second at 4 m/s and faster, instead of going back. Stopped, the rider only
  backpedals the short way to the nearer level, and otherwise leaves the cranks where they are. They never turn the
  wheel. Pedalling again starts them from there.
- Into a manual or a nose manual the rider stands up on the pedals over about half a second, and the hips follow
  where the physics puts the weight, about a fifteenth of a second behind it: a manual's throw is drawn two thirds
  of the way in a tenth of a second and all of it in about a third. They move back and sit down the same way after
  it, without a jump.
- At a walk the bars turn up to about 32 degrees, so the bike turns round inside about 3.3 m, where it used to take
  5.3 m. They come back to the old lock by 3 m/s, and from there steering is as before. With the bars that far round
  the rider's near hand is drawn turned a little short of its grip, its wrist at the end of its bend.
- B in a corner keeps the corner. The bike stands up a little as the brake comes on and the turn opens for a moment,
  by about a fifth on the flat and up to a third down a steep street, then tightens as the bike slows, rather than
  running wide.
- Weaving does not make speed. Throwing the bike from lean to lean is paid from its speed, so a coast weaving from
  side to side slows a little faster than a straight one, and pedalling through a weave still stops at top speed.
- Pedalling has a rider's power, not a motor's. Up a ramp steeper than about 15% the bike slows with A held, the
  steeper the slower, while the city's hills still climb at close to full speed.
- Riding into a kerb costs some speed as each tyre strikes it, more for a taller one. Hop clear of its top to keep
  your speed: a hop that falls short still strikes it.
- A stopped bike holds on a street grade, so hold A for a moment to start down a gentle hill. Ramps steeper than about 15% roll back.
- A crash (the bike going over, a hit at speed, or the rider being knocked off, as by a car) gets back on the bike
  after a few seconds: the HUD says "The rider came off. Getting back on the bike." While the game keeps the rider
  down the HUD says "Press A to get up.": the game leaves a crashed rider lying until a button is pressed, and the
  mod waits for that, up to three minutes. Once the rider is up, let go of the controls: the switch to the skateboard
  waits for that. If the rider is left standing on
  foot as they are put back on the bike, the HUD says "Press Y for your skateboard, then let go of the controls."
  Banks and quarter pipes do not count as going over. If there is no room to get back on, move and mount again.
- If something does not finish, the HUD says what to do next, usually "That didn't finish. Get on your skateboard,
  then hold LB and press A." On the first ride of a launch a few failures cannot be tried again, and the HUD then
  says "The bike is stuck: restart the game to ride again." The reason the mod stopped, in its own words, is in the
  ReSkate log and on the BMX page.
- A slower bump into something just stops the bike, and it has no reverse. If it is stuck, go back to the skateboard.
- A nose manual rides over small bumps and kerb ramps. With the stick past about half way, a steep kerb face or a
  bump of about 12 cm often throws it over the bars below about 3 m/s and can still do it at 5 m/s, and so can a
  pothole or dip of 6 to 10 cm met at 2.5 to 3 m/s. Held low, with the stick a little forward, it rides a 12 cm bump
  at a jog, and on two wheels or in a manual the same kerb face just stops the bike.
  Carved at full lock, a bump of about 8 cm met at 4 to 6.5 m/s can swing the back of the bike right round, and now
  and then throws it over; carved at full lock down a steep hill, a 5 cm bump met faster than about 7.5 m/s can too.
  The rider is drawn with the hips forward over the bars as far as the physics shifts the weight, once the cranks
  have come level. Until then, with a pedal high in front, the hips go up over the bars instead, so the knees clear
  them.
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

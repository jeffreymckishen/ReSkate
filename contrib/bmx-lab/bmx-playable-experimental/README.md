# Local BMX one-session playtest

This package is an experimental Lua entry over the exact runtime modules used by the successful Root3 mounted ride and observational hop. The new Mount/Return/Cancel entry itself has not yet been tested in the game. It is not a completed BMX Streets port or a distributable visible-bike release.

It requires the separately installed private BMX_Prototype asset pack. That pack, its FBX/material payloads, game content, game binaries and controller tools are not included. The original-asset dependency is being resolved separately. Missing assets remain a visible lifecycle refusal; this entry does not substitute assets or bypass spawning guards.

Use only Root's separately reviewed compatible ReSkate/SDK binding and the supported Skate20260929 installation. Root3 used R3 DLL04806F90471A46C2EEF269E0905621838D1C3D8ADF60B78E7E50FAF45F1E94E3; a newer SDK/build or this changed entry needs its own validation. This package does not install or select an SDK. Its source admission is closed by default; Root owns the exact reviewed experimental build identity and any deployment decision.

Once Root validates and admits a local playtest build:

1. Start on foot, upright and still, in a flat area with10m clear all round. This profile preserves Root3's on-foot-only Mount; direct skateboard-to-bike and repeat mounting are not enabled.
2. Open BMX experimental and choose Mount bike. The entry performs bounded native preparation and a fresh survey of the bike-sized 1.25 m spawn clearance. Stay still; when prompted, close menus and release every control. The lifecycle owns all input/physics/pose work.
3. Ride within the existing bounded profile. The pinned runtime keeps its60s window, force/speed/tilt/envelope/lease/watchdog/cleanup limits and existing hop policy.
4. Choose Return to skateboard. Stop and full bike/input cleanup come first. One existing stock transition then needs its actual100 target, ACK and clean lifecycle. The single measured placement runs only after that stock transition completes; release controls and wait for actual grounded100 position/heading convergence before Return completes or another Mount becomes available.
5. Cancel revokes a pending entry or equipment transaction and leaves the lifecycle ticking cleanup. Refusal, uncertainty and failure are shown; no retry is hidden. Unload never requests a stock switch.

One BikeRuntime owner is created. Its once-per-VM mount policy is unchanged and never reset. After one intent, failure, cancellation or completed ride, remounting is unavailable in this session. A repeat-session contract, full fall recovery, complete tricks/scoring, multiplayer presentation and public release assets are separate work. Do not delete or reset retained lifecycle evidence to force another attempt.

The benchmark recorder, scripted HID timeline and formal HopTrial qualification framework are not needed to use this entry. The original lifecycle's real readiness, permissions, lease/authority, neutral/closed-menu, physics, equipment and cleanup guards remain. Source tests and Root3's old game result do not qualify this new entry, Return behavior, performance, durability or a different SDK.

Return captures the current live measured bike/support location before stopping. After full bike/input cleanup AND the original stock100 target+ACK, the mod uses the existing permissioned skater.teleport API once, preserving measured actor-root height. It then requires actual grounded100 position/heading convergence inside the original stop+20s window before final Return or remount; the existing5s queue lifetime plus100ms observation is reserved before sending. No placement runs on504 and no second teleport retries it. Queued is not completion; refusal, position reset or missing convergence keeps final Return blocked. This preserves no momentum and adds no already-stopped recovery qualification. R50 onfoot placement converged but later stock position reset about55m; this poststock successor is native UNRUN.

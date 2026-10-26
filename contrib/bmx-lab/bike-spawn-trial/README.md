# Lua bike spawn trial

This diagnostic creates eight private supplied-FBX bike parts through
`reskate.entities` and one owned chassis through `reskate.world.physics`.
Lua places the parts from measured chassis position and XYZW rotation. It does
not mount the rider, acquire input, submit forces, query contacts or run tricks.
It is a partial spawn/body/visual proof, not a playable bike or Streets likeness.

Package the exact `bike_spawn.lua`, `bike_visual.lua`, `bike_geometry.lua` and
`force_math.lua` files from `../bmx-plugin/plugin/` beside `plugin/main.lua`, with
this manifest at the mod folder root. Do not enable the old C++ BMX mode. Use
the existing isolated supported Skate build and private local eight-part asset
pack; no asset copying or redistribution is part of this fixture.

Open **Lua Bike Spawn Trial**, choose **Spawn one Lua bike**, then close the
menu. Startup and menu rebuilds are inert until this explicit action. The
request expires after 30 seconds. The preflight requires all eight loaded
blueprints and both wheel bounds to match the Lua fitted radius within 2 mm.
No floor or native collision result is inferred. The unmounted root begins
three metres to the actor's right and half a metre above their reported origin.

The fixture first waits for the eight entity statuses to become `ready`, then
attempts one body creation. The exact SDK refusal, `body_preallocation_unavailable`,
covers queued producer setup, unavailable anchor capture or clock qualification in
`owned_bodies.cpp`. It proves that this attempt reserved no slot or body, but does
not establish which prerequisite failed or prove clock initialization. Only that
preallocation readiness refusal exposes **Retry after readiness wait**. This
requires a separate explicit action and is allowed once; it never loops. Every
other creation refusal or exception reports cleanup uncertainty and prohibits
another creation in this VM.

After creation, the fixture accepts immutable measured native epochs with exact
decimal serial strings, including serials above 2^53. It never extrapolates a
body pose or invents wheel/crank motion. Duplicate observations do not advance
presentation; a native clock stalled for over 100 ms, a 2 m body displacement,
five elapsed seconds, focus/menu change, unavailable sample, or malformed sample
stops the trial. **Release bike / stop** also stops it explicitly.

The receipt is `lua_bike_spawn_v1` in the plugin's SDK storage. Its last
measurement is informational; it contains no replayable epoch or ownership
token. `body_release_accepted` means the SDK accepted release/parking of a
retained allocation. `visual_remove_requested` means removal was requested;
the current void entity API does not prove native retirement. Unknown cleanup
keeps the debt visible and never retries silently. Unload requests stop too.

The chassis uses the existing authored eight-capsule **combined 106 kg
bike/rider** model with COM `{0,.9,-.05}` and inertia `{26,32,10}`. Three proxies
represent the planned rider while this diagnostic itself is unmounted. These
are proposed tuning, not recovered Streets physics, measured material mass or
proof of native collision suitability. A successful trial must include visible
native geometry and measured native advancement; Host fakes cannot establish
either. Each successful creation consumes one of eight retained process slots;
native destruction/reuse is unproven, so restart the isolated game for repeated
allocation trials.

The next riding milestone requires qualified contact normals and surface motion,
same-epoch local-rider/self exclusions, controller provenance and an actual native
rider ownership/follow/release path. None is bypassed by this spawn diagnostic.

Cold producer setup is requested without hooks or allocation inside the Lua call.
The SDK performs its one-time generic setup on a later eligible client tick,
then the existing separate explicit retry remains necessary. Initialization
failure is sticky and is reported as ABI/producer unavailable. No definition or
body creation is queued. Setup may complete after caller unload because the
generic producer hooks have process lifetime and grant no plugin ownership.

The trial stores separate bounded `lua_bike_api_create_result_v4`,
`lua_bike_api_read_result_v4` and `lua_bike_api_release_result_v4` records as soon
as each protected API call returns. Cleanup cannot overwrite those records.
They contain only observed return type/arity/booleans and a bounded reason, never
raw tokens or a handle string. A missing result after a watchdog stop remains
unknown; a returned body handle alone is not a native measurement or cleanup proof.

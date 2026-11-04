# The bike's own data

These files are ours: Ermakov's "BMX (Free)" (CC BY 4.0, see `../CREDITS.md`), lightened and repacked. Nothing in
this folder comes from the game.

| File | What it is |
|---|---|
| `bike-geometry.npz` | All 185 objects of the model, lightened to 49,405 triangles, in the drawn bike's frame. Our own format, described in `assets/models/bmx/lighten_free_model.py` (`write_geometry`); numpy reads it. |
| `albedo.png` | A 2048x1024 atlas of two tiles side by side: the model's "rul" colour map (its grips and bars), which its "base" parts are drawn with too, and its "extra" map. `bike-data.json` (`atlas`) names each map, its entry in the download's zip and its sha256, and the "base" map that is not used. |
| `bike-data.json` | The hashes of the two files above and of the sources they came from, the goals, the triangle count of every object and part, and the source model's own anchor fits. |
| `pack-files.json` | The size and sha256 of every file `build_bike_pack.py` writes from this data with the supported game. They are only hashes; the files themselves are not committed. |

## Why the native pack is not here

A native pack also needs pieces taken from Skate's own files: a full copy of the `dingolevel_root` bundle's manifest
and table of contents, the game's two `dingolevel_root` shader tables with the drone material's rows added, and the
LOD group the drone mesh imports. Upstream's own `assets/builtin/throwdown_menu.zip` does carry game-derived pack
files (the game's `initfs_win32`, a template `layout.toc`, level tables of contents and bundle manifests), but this
mod keeps everything built from the game's files out of the repository, so the pack is built from this data and the
player's own game by the machine that packages the mod:

```powershell
$py = 'C:\path\to\python.exe'   # a Python with numpy and Pillow
& $py -I -B assets\models\bmx\validate_lightened_bike.py --data contrib\bmx-lab\bmx-playable-experimental\bike
& $py -I -B assets\models\bmx\build_bike_pack.py --game-root <the supported Skate folder> `
    --builder build\vs2022-x64\Release\dingosdk_bmx_native_pack_builder.exe --output <a new folder> `
    --expect contrib\bmx-lab\bmx-playable-experimental\bike\pack-files.json
```

Copy the output folder's contents (`layout.toc`, `.reskate-studio-patch`, `BMX-NATIVE.txt`, `Win32\`) into the mod
folder beside `reskate-plugin.json`. The build is deterministic: with the supported game it gives the bytes
`pack-files.json` records.

## The FPV Drone mod

The pack is built on the FPV Drone template and keeps its asset names. The bike's atlas and flat normal replace the
drone's `reskate/drone/fpv_drone/textures/frame_2_basecolor` and `frame_2_normal` in place, because the compiled
shader tables bind those texture identities, and the drone's own blueprint, mesh and other textures stay in the pack.
The ReSkate FPV Drone mod (zeex64) adds the same names, and the merge keeps only the higher mod's copy: with both
turned on, either the drone is drawn with the bike's atlas or the bike with the drone's frame texture. The merge
notes the shared names but does not stop it. Until the bike has texture and material identities of its own, only
one of the two can be on.

## Rebuilding this data from the model

With the "BMX (Free)" download from Sketchfab, `bmx-free.zip`, and its `source/BMX_sf.fbx` extracted. The colour maps
are read from the zip itself, by entry: it holds two different `textures/base_BaseColor.png` (the "base" and the
"rul" material's), and an extracted folder keeps only one of them.

```powershell
& $py -I -B assets\models\bmx\lighten_free_model.py --fbx <download>\source\BMX_sf.fbx `
    --zip <download>.zip --output <a new folder> `
    --expect contrib\bmx-lab\bmx-playable-experimental\bike\bike-data.json
& $py -I -B assets\models\bmx\validate_lightened_bike.py --data <that folder> --fbx <download>\source\BMX_sf.fbx
```

It takes about 10 minutes on 7 processes, and `--expect` stops it unless it gives these exact files. The goals and
locks are in `lighten_free_model.py`; after changing them, run the validator, copy the three files here, rebuild the
pack and record its new `pack-files.json`.

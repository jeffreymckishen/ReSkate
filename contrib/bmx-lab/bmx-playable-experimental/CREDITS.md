# Credits

## The bike

The bike is **"BMX (Free)" by Ermakov** (<https://sketchfab.com/Ermakovv>),
<https://sketchfab.com/3d-models/bmx-free-547a95dab9dd4f598237f7ab2885443d>, licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

What was changed for this mod:

- **Lightened** from 206,424 to 49,405 triangles. Every corner that is left is one of the model's own, with its own
  position, normal and texture coordinate; each object keeps its exact size and stays within half a millimetre of
  its original surface (a millimetre on the tyres, 0.7 mm on the spokes). The grip tape's hidden, overlapping
  layers were removed.
- **Split into 8 parts**: its 185 objects grouped into the frame, fork, rear wheel, front wheel, cranks,
  handlebars and the two pedals, so the wheels, cranks, bars and pedals can move.
- **Rescaled** to a 0.2630808 m wheel radius and re-centred, and the wheels and cranks given their origins at their
  hubs, so they spin in place.
- **Re-textured**: the model's two base-colour maps packed into one 2048 by 1024 atlas. Its normal, roughness and
  metallic maps are not used; the bike has a flat normal.
- **Converted** to the game's native meshes.

## The native material and mesh template

The bike's parts are built on **"FPV Drone" by PinaPipe**,
<https://sketchfab.com/3d-models/fpv-drone-92152c31ec9a4a87b2a0478bd114d293>, licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), as built into a pack by ReSkate Studio. Its frame
textures were replaced with the bike's atlas and a flat normal, and the bike's parts reuse its mesh and blueprint
structure.

## Where the files are

The mod's own bike data is in `bike/` in its source. The native pack in the mod folder (`layout.toc`,
`.reskate-studio-patch`, `BMX-NATIVE.txt` and `Win32/`) is built from that data and from the game's own files on
the machine that packages the mod; `BMX-NATIVE.txt` repeats these credits. See `bike/README.md`.

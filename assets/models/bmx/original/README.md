# Original procedural BMX geometry

This is an original, deterministic source recipe for the Lua BMX mod's eight visual parts. It uses only Python's standard library, authored mathematical surfaces and the adjacent scalar compatibility contract. It imports no FBX, Streets triangles, game content, donor materials or external texture files.

On 2026-10-27, MainRoot verified **13 tests passed** and generated the eight-part package at source `5315396e5c27a3870c16d1fbd61a22f7b05ecfe7`, with the current recipe inputs unchanged. The software assembly and steering/pedal articulation preview passed independent visual review. Native packing/loading, rider clearance and likeness remain unverified; no in-game appearance or 9.5 likeness score is claimed. Further execution still requires the coordinator's slot.

The output is an OBJ/MTL authoring intermediate. It cannot be installed directly into ReSkate. A separate native resource recipe must bind the original geometry to permitted resources through the normal content/VFS path, then qualify loading, bounds and rendering in the supported isolated game build. That later work may reference resources already present in the user's supported installation; this generator neither extracts nor packages them.

## Files and provenance

- `generate_geometry.py` constructs closed cylinders, tori, boxes and an ellipsoid, assembles the bike and writes the intermediate package. It has no network access, subprocesses or third-party imports.
- `geometry_contract.json` copies only the existing repository's functional scalar anchors, coordinate conventions, part names and articulation roles. Its authoring dimensions are original choices for a generic BMX frame, fork, saddle, tires, spokes, bars and pedals.
- `provenance.json` records the original construction, empty external asset inputs and repository license. Generated packages carry their own `LICENSE` and a local license reference.
- `Test/test_original_geometry.py` contains contract, primitive volume/winding, serialized bounds/index, articulation anchor, deterministic hash and writer regressions.

The source recipe and generated original geometry use the repository's `LICENSE`. They do not grant rights to any game, supplied FBX or previously extracted reference model. This recipe does not read the private conversion tools, their outputs or a development game profile.

## Coordinate and articulation contract

Every vertex is already in metres in the **same bike-space coordinate frame**: +X toward the named left grip/pedal, +Y up, +Z forward. Scale is applied exactly once. Parts are not recentered around their individual origins, and `G.com` is not subtracted from their vertices. `bike_visual.lua` computes the body-to-bike-root transform separately.

The compatibility scale is `0.7737670588235294`; tire outer radius is `0.34 * scale`. The actual axle Y coordinates are slightly below that radius. The recipe preserves them, including the small neutral tire extent below Y=0, rather than changing the Lua geometry or silently raising the mesh. A future floor-placement trial must account for the same existing contract.

Part order is fixed:

| Index | Part / future blueprint suffix | Articulation before measured body placement |
| --- | --- | --- |
| 1 | `frame` | Tailwhip about the tilted steering axis |
| 2 | `fork` | Steer + barspin about the steering axis |
| 3 | `rear_wheel` | +X spin about rear axle, then tailwhip |
| 4 | `front_wheel` | +X spin about front axle, then steer + barspin |
| 5 | `cranks` | +X spin about bottom bracket, then tailwhip |
| 6 | `handlebars` | Steer + barspin |
| 7 | `left_pedal` | Crank spindle orbit **translation**, then tailwhip |
| 8 | `right_pedal` | Crank spindle orbit **translation**, then tailwhip |

Each name maps to `reskate/bmx/<name>`. All parts then receive bike pitch about +X and roll about +Z at the steering pivot, in that order. Pedal platforms are separate meshes: their local orientation stays level during crank rotation; fusing them to `cranks` would tumble them. The source tests check common-frame wheel/fork and crank/pedal anchor relationships. They do not execute Lua matrices or qualify native animation.

The contract validator refuses altered part roles, pivots, group assignments or pose ordering. The regression fixture also reads the actual repository Lua geometry constants so compatibility changes require a deliberate update. No handling, collision, mass, inertia or Lua code is changed here.

## Future execution

Use Python 3.10 or newer, without installing anything. From the repository root, after a coordinator grants the execution slot:

```powershell
python -B -m unittest discover -s assets/models/bmx/original/Test -p 'test_*.py' -v
python -B assets/models/bmx/original/generate_geometry.py --check-only
python -B assets/models/bmx/original/generate_geometry.py --output 'E:\RESKATE DEV\artifacts\bmx-original-v1'
```

The output's parent must already exist, and the output path must be new. The writer refuses every existing directory/file/symlink and never deletes or replaces it. A write failure may leave an incomplete new directory; only a final `manifest.json` indicates that all writes finished. Inspect and remove an incomplete directory explicitly before choosing another run path.

The writer tests create and clean one fresh, path-checked temporary directory under `Test/` by default, keeping scratch on the assigned E drive. Set `BMX_ORIGINAL_TEST_TMP` to another existing assigned scratch parent if desired. `-B` avoids Python bytecode artifacts in the source worktree.

## Intermediate format and validation

The package contains eight `.obj` files, `materials.mtl`, `materials.json`, the scalar contract, provenance, `LICENSE` and `manifest.json`. OBJ uses 1-based `v/vt/vn` indices with one position, UV and explicit normal per corner vertex. Primitive groups preserve material assignments. Seam and hard-edge vertices may be duplicated; overlapping closed tubes are intentional visual construction, not a welded/manufacturable solid or a collision mesh.

Normals and triangle winding are outward in the authored right-handed frame. Cylinders have explicit end caps and the saddle ellipsoid uses pole fans, avoiding duplicate-pole degenerate triangles. The validator checks finite positions/normals/UVs, unit normals, index ranges, ownership of every vertex/triangle, nonzero triangle area, winding agreement and independently positive enclosed volume per primitive. It validates again at the serialized nine-decimal precision. Both wheel Y/Z spans, bounds centers and radial extents must still match the Lua anchors/radius; the default wheel tessellation samples cardinal extrema exactly.

The JSON manifest records part bounds, counts, primitive groups, anchor/pose conventions, exact input hashes and SHA-256/size of every payload. It intentionally excludes itself from that payload table; the CLI reports the manifest hash. No timestamp, absolute output path or random identifier enters generated content. Determinism means identical input bytes and Python/math environment give identical payload bytes. Cross-platform libm or source line-ending changes can change exact input/output hashes and require new evidence.

Material values are original constant paint, rubber, alloy and steel parameters. OBJ/MTL is a preview approximation; `materials.json` records base color, roughness, metallic values and a flat tangent-space normal. There is no compiled native shader, material graph, game texture or copied LOD payload.

## Still required

The reviewed assembly and articulation are coherent, but the chain is still two thin straight spans; wrapped links and drivetrain detail remain incomplete. Improve those details and re-run generation, regressions and the software preview after any geometry change. Rider clearance and likeness need their own evidence. This initial generic construction is not a finished visual likeness target.

Then separately validate the native resource dependency recipe, exact eight blueprint bounds, clean installation, materials/shadows, articulation and complete removal in the pinned isolated Skate build. Original source meshes alone establish none of those runtime outcomes.

# Original left-pedal native canary

This is the admission-first checkpoint for a one-part native pack. It admits the
original generator's package and preserves the selected mesh for a later encoder.
**It does not yet emit an installable native pack.** The checked-in recipe is
unqualified; the command refuses native output before creating a cache directory
or reading any game archive. A working native canary remains the next checkpoint.

The historical `build_native_bike_pack` modes retain their existing behavior.
The new `--original-canary` branch runs before their template/archive operations
and never falls through to the private FPV/Streets path.

## Original input and coordinate frame

The selected input is `left_pedal.obj` from
`assets/models/bmx/original/generate_geometry.py`. The package has eight original
OBJ parts plus materials, contract, provenance and license metadata. Admission
checks the closed manifest schema, the six reviewed source-input hashes, and the
size/SHA-256 of all thirteen payloads. Manifest-supplied names are not arbitrary
paths. The CLI additionally requires the reviewed complete manifest hash:

`882fb6ba4e3f01d3ea08cfba3c231d37c53eca1a0a0275e193d93dd8835183d9`

The pure admission library can inspect synthetic self-consistent fixtures; that
alone does not authenticate provenance. The CLI's reviewed manifest pin is a
separate boundary. Changed generator inputs or generated payloads require a new
reviewed source/pin update, not a recipe flag claiming qualification.

The selected part contains 264 vertices, 204 triangles and nine components: an
alloy platform and eight steel pins. Its OBJ uses only the generator's fixed
ASCII/LF subset: one object, positions, UVs, normals, ordered groups/materials and
triangles with equal positive `v/vt/vn` indices. Unknown directives, malformed
numbers/indices, mismatched hashes/counts, nonfinite or invalid geometry and
inconsistent component ranges are refused.

Positions are already scaled metres in the shared right-handed bike frame:
+X left, +Y up, +Z forward. The reader does not recenter, rescale or subtract COM.
It retains source positions, normals, UVs and the `alloy`/`steel` component labels.
This is preservation of admitted source data; no native stream conversion or
normal/tangent encoding has yet been qualified.

## Metadata recipe and cache boundary

`assets/models/bmx/original/native-canary.recipe.json` is a closed metadata schema.
It selects only `left_pedal`, pins the original manifest, requires a new local
cache and disables automatic installation. Unknown fields, changed qualification
claims or filled-in native identities are refused in this checkpoint. Native
template, declaration, LOD and both material identities remain null.

The future output namespace is `reskate/original_canary/left_pedal`, separate
from the historical `reskate/bmx/left_pedal` pack and its GUID namespace. No native
identity is generated or qualified yet.

The builder's cache root is fixed at configure time to
`<source-root>/build/bmx-original-canary-cache`. A requested output must be a new
descendant of that root and separate from input locations. Input reads are bounded
and reject unsafe path/reparse cases; hash and parsing use the same read bytes.
The current mode writes nothing, including after valid original admission.

## Future authorized validation

Do not run these while a coordinator execution hold is active. The Windows BMX
test configuration registers `bmx_original_canary`, backed by
`dingosdk_bmx_original_canary_tests`. Its default fixtures use synthetic geometry
and source metadata, without game archives or generator execution. An optional
original-package argument exercises the reviewed package's admission and expected
unqualified refusal. Source-authored tests are not test-pass evidence.

After a coordinator builds and grants execution, the command shape is:

```text
dingosdk_bmx_native_pack_builder.exe --original-canary ABSOLUTE_ORIGINAL_PACKAGE ABSOLUTE_RECIPE ABSOLUTE_NEW_CACHE_OUTPUT
```

All three input/output arguments must be absolute local drive paths. For this
checkpoint, valid reviewed inputs must still report unqualified native emission,
return status 2 and leave the requested output absent. They must
not invoke the historical archive/template path. This expected refusal is an
admission check, not a successful native pack build or installation.

## Exact inputs needed for the emission checkpoint

The next source change needs a reviewed, non-paid stock template/declaration
record tied to supported build 20260929. Asset names or `non_paid=true` assertions
are insufficient. Required evidence is:

- Exact source bundle, asset/type/GUID/resource identities and content hashes for
  the MeshAsset, ObjectBlueprint and their typed EBX reflection/descriptors/fixups.
- The static MeshSet section and stream declaration: strides, semantic offsets,
  position/normal/UV/tangent encodings, index width, bounds and chunk/name fields.
- Exact root-resident compatible material identities, with an explicit mapping
  for both `alloy` and `steel`, plus their understood dependency/shader closure.
- A qualified root-domain LOD identity/placement and bounded import closure.
- A reviewed original manifest pin and distinct canary identities, followed by
  emitted-byte readback and a new-cache publication check.

The existing typed EBX reader/writer, mesh checks and native bundle/TOC writers
are the reuse points. They do not supply an arbitrary OBJ-to-MeshSet encoder.
The old FPV layout, copied city LOD and historical GUID salt must not become
implicit defaults. `check_mesh_lod` alone does not verify static normal/UV/tangent
encoding. No new SDK/VFS framework, runtime BMX mode or arbitrary shader compiler
is part of this lane.

Once those inputs are supplied, implement only the declaration-driven one-part
stream and typed-EBX emission, then validate the output in a separately owned
supported-build trial. Admission, native compilation, installation and visible
runtime correctness remain separate milestones.

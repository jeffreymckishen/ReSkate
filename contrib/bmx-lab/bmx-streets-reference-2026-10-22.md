# Matched BMX Streets reference: October 22, 2026

The installed reference changed since the October 18 extraction. These are
read-only local artifact observations, not a handling or visual comparison.

| Installed input | SHA-256 |
|---|---|
| `GameAssembly.dll` (113,271,808 bytes) | `3EBD5AB08931C3BB35E1264739975F0EB6FD2AD56EDFD99E5FA48DA7EABD6E85` |
| `global-metadata.dat` | `280626C43E5048615BB190031025B17AEA57BE733367C59C19BF79A6EAB533AE` |
| `resources.assets` | `BA9AD7C82E8AF01248FD3AD6DC396F729B593F88AAFCE605FC627E301B41640F` |

The metadata identifies Unity 2022.3.62f2 and metadata version 31.1. Current
Cpp2IL address/signature output was regenerated from this binary/metadata pair.
It supplies method and field identities; its empty generated C# method bodies
are not recovered implementations. All 20 selected historical method-offset
body comparisons failed against the installed DLL. Historical offsets and
serialized object identities must therefore be matched again before reuse.

## Current native contact target evidence

REA/Ghidra 12.1.4 analyzed exact original code retained in an analyst-generated
carrier. The carrier includes only selected code pages, original data and
synthetic method-name exports; it is incomplete and must never be executed.
Its SHA-256 is
`7C2A222C122141C8DF3ED5773ABCD0F7B4C558BCDED76D0A1A0F46A675779174`.
The manifest retains each original file offset, byte range and hash.

`IKTargetManager.Update` at RVA `0x8B94F0` calls `UpdateTarget` four times with
separate left/right hand and foot target, anchor, position-offset and
rotation-offset fields. `UpdateTarget` at RVA `0x8B9270` transforms each local
position offset through its anchor, then publishes the target position. It
combines the anchor rotation with its Euler rotation offset and publishes the
target rotation. Unity callee identities match the current metadata; those
callee implementations were not themselves analyzed. This supports keeping
four contact targets tied to their actual moving bike anchors. It does not
establish avatar proportions, authored offset values or rendered contact.

Evidence IDs:

- `ev_14e3f0db998af3278cd4623701bc512d0d75c2516d8a720a1c6d9510c4632ce6`
  (`IKTargetManager.Update`, 345 native bytes).
- `ev_97a18a23b2ee23435c96e33f671502d0e11101e450e9b49bad523f120067b5ba`
  (`IKTargetManager.UpdateTarget`, 626 native bytes).

The carrier also seeds other methods. Their presence in the carrier is not
evidence that their bodies have been analyzed. The initial two-function export is retained locally at
`build/bmx-streets-current-20261021/rea-contact-landing-evidence.json`, with
the provider snapshot and exact source manifest beside it.

## Current authored input evidence

The current metadata input literals retain identical BMX and Tricking action
and binding definitions compared with the historical extraction. General and
Freerunning maps changed. The current Ragdoll maps bind `Stand Up` to
`<Gamepad>/buttonSouth` and `Get Up` to `<XInputController>/buttonSouth`.
This makes South a reasonable reference candidate for a separate controller
trial. It does not prove Skate's mapping, active runtime overrides, actual
controller consumption or recovery. ReSkate's existing Skate D-pad behavior
remains the requested control contract.

The extraction inventory, complete authored literals and comparison are retained
in `build/bmx-streets-current-20261021/`. Live comparison of ordinary riding,
contact timing, tricks, landings and recovery is still required for the requested
9.5 likeness score. No result in this reference note awards that score.

## Landing timer follow-up

Current `VehicleController.OnLanded` at RVA `0x8F9A40` is a 62-byte leaf.
Its matched fields are `_timeInAir` at `+0x6C8`, `_mannyInput` at `+0x580`,
`_noseyInput` at `+0x584`, and `_autoPumpTimeRemaining` at `+0x734`. For ordered
finite values, airtime greater than nominal 0.15 and both manual inputs at most
0.05 set the timer to nominal 0.3. A failed gate returns without clearing the
existing timer. Evidence:
`ev_1094a38bc24b0053ff50257834f4e57ca7b665f8f10a71fbc95394029e92cc9b`.

This confirms the existing adaptation's landing eligibility constants and timer
initialization. It does not establish force magnitude/direction, automatic
strength, timer decrement, continuous manual cancellation, support predicates
or wheel/contact stiffness. Those require their own current caller/consumer
evidence; this leaf is not a full landing physics implementation.

`LandActivity.Land` was also analyzed, but its tracker/trick-detection bookkeeping
and unresolved callees do not establish a wheel force recipe. Ghidra reports
1,667 analyzed bytes over a 1,668-byte noncontiguous span, with terminal-call
limitations. Its evidence ID is
`ev_f26faf7461acac880ea2649c3ca58b6516e5cd3c27bb6311c8c9920d04ad9ef4`.
Both additional dossiers are retained in
`build/bmx-streets-current-20261021/rea-landing-extension-evidence.json`.
Remaining seeded methods still need separate analysis. No physics behavior was
changed from this narrow reference confirmation.

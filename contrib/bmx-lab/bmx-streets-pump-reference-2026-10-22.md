# BMX Streets pump reference, 2026-10-22

This records the current installed BMX Streets pump bodies and freshly decoded authored settings. It supplies a current reference for the [ground pump adaptation](ground-pump-adaptation.md); it does not establish the active runtime prefab, effective player settings, equivalent handling or a likeness score. No physics changes accompany this note. The earlier C1C8 reference is historical.

## Source identity and evidence

The matched installation is Unity `2022.3.62f2`, IL2CPP metadata `31.1`. These are full-file SHA-256 pins, not carrier hashes:

| Current source | Bytes | SHA-256 |
|---|---:|---|
| `GameAssembly.dll` | 113271808 | `3EBD5AB08931C3BB35E1264739975F0EB6FD2AD56EDFD99E5FA48DA7EABD6E85` |
| `BMX Streets_Data/il2cpp_data/Metadata/global-metadata.dat` | 33152468 | `280626C43E5048615BB190031025B17AEA57BE733367C59C19BF79A6EAB533AE` |
| `BMX Streets_Data/resources.assets` | 296434144 | `BA9AD7C82E8AF01248FD3AD6DC396F729B593F88AAFCE605FC627E301B41640F` |
| `BMX Streets_Data/globalgamemanagers.assets` | 19617936 | `7C99E689330EE7B3C474CE609ED825088AF49AD69E3012AAFE38D8C42145B315` |
| `BMX Streets_Data/globalgamemanagers` | 3408732 | `FF37BAA60738D44592D92F455AA98E59ECD85A1B809DC3F4EC5FA0363657F58E` |

The current Cpp2IL output supplies matched names, field offsets, tokens and native addresses. Its empty C# method bodies are identity stubs. Native behavior below comes from the REA/Ghidra dossiers, with original source bytes retained and matched by the slice manifests.

| Evidence | SHA-256 |
|---|---|
| [TickAutoPump dossier](../../build/bmx-streets-current-20261021/rea-current-tickautopump-evidence.json) | `95DECBFB16D1C9837F5DC3DE0868B700C4C78618699EBAFB34E1A8CB258C11CE` |
| [SimplePumpForce dossier](../../build/bmx-streets-current-20261021/rea-current-pumpforce-evidence.json) | `CF8364E99DB07E2D245A9FF67E7E1E839DC56A9C60EFA9DB634E9C5CBEA74AD0` |
| [Vehicle forwarding and Manny dossier](../../build/bmx-streets-current-20261021/rea-current-pumpflow-evidence.json) | `28196796CB54E32328FC7AED70578BCC352EB69D98E288B0082B1967FA9C3F91` |
| [Independent current native ABI and vector binding proof](../../build/bmx/overnight-review20261021/current-pump-bindings-fresh.json) | `18ABB5A10708DF633F0DE89F2CA7AA1C2B7C582882777E4F459E406B73D973A6` |
| [Fresh SimplePumpForce authored objects](../../build/bmx-streets-current-20261021/pump-current-assets/current-simple-pump-configurations.json) | `272D9A0C53F9F5AA0F552C5138577F7ED3B5B18919A83BE3E0173CC4727068F0` |
| [Authored timestep, SmartData and wrapper proof V3](../../build/bmx-streets-current-20261021/pump-current-assets/current-pump-authored-basis-v3.json) | `3951162D95A6500DB94B0E47304B86DE82F2A03F0930A91D2AAD0D352F4CF783` |

Original-address provenance is in the [pump](../../build/bmx-streets-current-20261021/pump-native-slice-manifest.json), [pumpforce](../../build/bmx-streets-current-20261021/pumpforce-native-slice-manifest.json) and [pumpflow](../../build/bmx-streets-current-20261021/pumpflow-native-slice-manifest.json) manifests. The carriers retain selected original code pages and data, with synthetic exports for method discovery. They are incomplete, analysis-only PE carriers and must never execute. Their file offsets differ from original source offsets.

## Matched native methods

Addresses below are RVAs and file offsets in the original `3EBD…` DLL, in hexadecimal. Lengths are bytes: metadata span / Ghidra body coverage. OnLanded is in the [landing extension dossier](../../build/bmx-streets-current-20261021/rea-landing-extension-evidence.json).

| Method | RVA | Original file offset | Length | REA evidence ID |
|---|---|---|---|---|
| `VehicleController.OnLanded` | `0x8F9A40` | `0x8F8440` | 62 / 62 | `ev_1094a38bc24b0053ff50257834f4e57ca7b665f8f10a71fbc95394029e92cc9b` |
| `VehicleController.TickAutoPump` | `0x9022E0` | `0x900CE0` | 132 / 132 | `ev_2a49c8f7f26b685c16a3f87eb66f80ab8b737aaa0c6628e31e6093ea5e28f8a7` |
| `Vehicle.AddPump` | `0x2DE31C0` | `0x2DE1BC0` | 93 / 93 | `ev_a32049d8c6eabe4514472e1dc10f707675e55e6b11bed3b88410e69778a9a6a1` |
| `Vehicle.Pump` | `0x2DE3950` | `0x2DE2350` | 90 / 90 | `ev_b31e35580a683ce872203a0ba6893bfcffe3c0f947acd1e94764319e5790c6b6` |
| `VehicleController.Manny` | `0x8F8E20` | `0x8F7820` | 89 / 89 | `ev_95c97f95bda5cd4c5ad0c7a18bca00826977856e71899a98e822a38281b6ca62` |
| `SimplePumpForce.AddPump` | `0x9D6C50` | `0x9D5650` | 6 / 6 | `ev_3bb1817b03ef94488ed288c491a5f637b19c62d1667b6019b1ef714bc37a0da6` |
| `SimplePumpForce.Pump` | `0x71BD30` | `0x71A730` | 6 / 6 | `ev_d996f51ac9f9411b1b7cddc86357f89a322c122e9c8f1c169c1c4078feb97c26` |
| `SimplePumpForce.FixedUpdate` | `0x9D6DB0` | `0x9D57B0` | 332 / 332 | `ev_59a991fb3cd64d9c43eaa8cbaa424b2acd485ec2028710c6b81142562493ca60` |
| `SimplePumpForce.PumpPhysics` | `0x9D6F00` | `0x9D5900` | 1206 / 1172 | `ev_d29b0730cdc2a66f1d9b9e0bc3721b98128e03d2f619ea6be1dae1c911066862` |

PumpPhysics has a noncontiguous analyzed body and terminal/null-call boundary limitations. The 1206-byte span must not be described as 1206 analyzed instruction bytes. Called Unity APIs, SmartData getters and interface implementations are not all independently decompiled here.

## Landing, automatic command and input window

The numerical branch descriptions below concern ordinary finite inputs and ordered comparisons. Native validation of nonfinite inputs was not established by these bodies.

`OnLanded` sets `_autoPumpTimeRemaining` at native object offset `+0x734` to nominal `.3` when `_timeInAir` (`+0x6C8`) is greater than `.15`, `_mannyInput` (`+0x580`) is no greater than `.05`, and `_noseyInput` (`+0x584`) is no greater than `.05`. A failed gate returns without clearing an existing timer. This leaf does not define the caller's landing/contact predicate or the origin of its air clock.

`TickAutoPump` acts only while that remaining time is positive. It calls the virtual method with nominal `-.4` (`0xBECCCCCD`), subtracts its supplied delta time, and, if the result is no greater than zero, calls the same method with negative zero (`0x80000000`). It leaves the possibly negative remaining time as computed. This body has no partial-final-step scaling or continuous manual, hop or support cancellation branch. Caller order and invocation cadence remain unproven; the final clearing call could matter to which value the consumer observes.

The called pointer is at class `+0x7F8`, with its MethodInfo at `+0x800`. The independent proof derives the **current** vtable function-pointer base `+0x138` and 16-byte function/MethodInfo pairs from `il2cpp_object_get_virtual_method` (thunk RVA `0x59ABF0`, implementation `0x5DE510`). Therefore `(0x7F8 - 0x138) / 16 = 108`. The current VehicleController vtable entry `0x6001E8C3`, at metadata file offset `27151088`, resolves to inherited **`Vehicle.AddPump`**, token `0x060017FC`, slot 108. It is not a call to `Manny` slot 109.

`Vehicle.AddPump` forwards its supplied float to the nonnull `_pumper` field (`+0xD8`), using interface slot 2; `Vehicle.Pump` uses slot 0. Current metadata names that field/interface as `IPumper`, whose slot 2 is `AddPump(float)` and slot 0 is `Pump(float)`. This establishes the forwarding contract, while the concrete runtime `_pumper` instance remains unknown.

In `SimplePumpForce`, `AddPump` **assigns** `_addedPump` (`+0x54`); it does not accumulate with `+=`. `Pump` assigns `_inputValue` (`+0x50`). `FixedUpdate` then:

1. Computes `_finalInput` (`+0x88`) as `clamp(_inputValue + _addedPump, -1, 1)`.
2. If that sum is strictly below `-_downPumpThreshold` (`+0x60`), adds `Time.fixedDeltaTime` to `_pumpTimer` (`+0x58`). It zeros the force input only when the updated timer is **strictly greater than** `_maxPumpForceDuration` (`+0x5C`); equality is allowed. For positive duration it also publishes clamped `1 - timer / duration` window progress.
3. Otherwise resets the timer to zero and zeros the force input. It does not reset `_addedPump` in this body.
4. Calls the `_preloader` getter when that interface is present, but the returned value is not used in the subsequent pump arithmetic in this body. It adds literal zero, clamps again, calls `PumpPhysics`, and stores its result in `_isApplyingPumpForce` (`+0x64`). This does not rule out getter side effects or preload behavior elsewhere.

For example, stored direct input `-.5` and added input `-.4` produce `-.9` before force/window gates. The adapter instead selects magnitude `.5`. The Streets timer follows the combined input; the adapter keeps direct and automatic windows separately. These are material semantic differences.

## Force consumer

`PumpPhysics` clamps its supplied input to `[-1, +.5]`, takes the absolute magnitude, and rejects magnitudes no greater than `.0001`. If its configured `_grounded` interface wrapper (`+0x28`) is present, it queries grounded state and rejects false. That does not recover the implementation's exact contact/support definition; the optional wrapper also differs from the adapter's unconditional strict support requirement.

It obtains `_body` linear velocity via the current metadata-identified `RigidbodyVelocityCompat.GetLinearVelocity` (RVA `0x2D2C3D0`) and rejects world Y velocity greater than `.5`. The `_pumpForceMult` PlayerSmartFloat wrapper (`+0x70`) must exist. When its underlying `_definition` (`wrapper +0x10`) passes the Unity object check, it calls current `PlayerSmartFloat.get_Value` (RVA `0x2E8C3F0`) and multiplies the magnitude. A null definition skips that multiplication branch. If `_accelerationInputProvider` (`+0x80`) exists and its absolute input exceeds `.0001`, another factor `.75` applies.

The force vector is current `UnityEngine.Vector3.down` multiplied by the resulting input magnitude (including the applicable multiplier and acceleration-input factors) and `_pumpForce` (`+0x4C`). The vector identity is bound by the current encoded TypeInfo usage and current Vector3 static field metadata in the independent binding proof, rather than by assuming a historical header layout.

The main `_body` branch calls `Rigidbody.AddForce` (RVA `0x4DAC090`), applying the vector in world space. When `_includeChildBodies` (`+0x30`) is true, the child list branch calls `Rigidbody.AddRelativeForce` (RVA `0x4DAC1A0`), applying that vector in each child's local space. Both pass stored `_forceMode` (`+0x48`). There is also a configured managed-body interface branch. Which bodies/interfaces are present at runtime, and the actual populated child list, are not established by these bodies.

## Fresh authored values and conditional nominal conversion

The current `SimplePumpForce` MonoScript is ID **451**. A custom tree generated from the matched `3EBD…` DLL and `280626…` metadata, with the standard Unity 2022.3 MonoBehaviour header, exactly consumed and roundtripped all 16 located current components. Every reported field has an absolute source byte offset. Historical object IDs were not reused as identities.

Three current BMX hierarchy paths were decoded from `resources.assets`:

| Current component ID | Hierarchy | Object file offset / bytes | Multiplier definition |
|---|---|---|---|
| 49473 | `Proto_BMX/Root` | 293883840 / 108 | 47567 |
| 57005 | `MB Character (Networked) Variant/Proto Sports (Freerun) Variant/Proto_BMX/Root` | 295338880 / 108 | null |
| 58267 | `Proto_BMX_LONG Variant/Root` | 295566288 / 108 | 47567 |

All three are authored enabled, with `_pumpForce = 0.10999999940395355` (nominal `.11`), `_maxPumpForceDuration = 0.44999998807907104` (nominal `.45`), `_downPumpThreshold = 0.30000001192092896` (nominal `.3`), `_forceMode = 2` (current `ForceMode.VelocityChange` enum), `_includeChildBodies = true`, and a null `_managedBody` object. These are serialized configurations, not proof of selected runtime objects.

For component 49473, original `resources.assets` offsets are: `_includeChildBodies` at `293883896`; `_forceMode` at `293883912`; `_pumpForce` at `293883916` (`AE47E13D`); duration at `293883920` (`6666E63E`); threshold at `293883924` (`9A99993E`); and the 20-byte `_pumpForceMult` wrapper at `293883928`. The current owning-tree PlayerSmartFloat subtree was independently consumed and roundtripped for all three BMX wrappers: `_definition` occupies 12 bytes, followed by aligned `_isProxy` and `_proxyValue`. Primary/long wrappers contain definition 47567, proxy false and proxy value zero; the embedded component's definition is null.

Current SmartDataFloat **47567**, `SmartData_Settings_Physics_Pump Mult`, is a 212-byte object at `resources.assets` offset `292765776`, with current script ID 1352. Two generated trees (AssetsTools and AssetStudio) independently agree after exact consumption, roundtrip and source-offset rereads. Its serialized, typo-named `_defualtValue` is **1.0** at `292765948`; `_persistUserChanges` is false at `292765952`, minimum `.5` at `292765956`, maximum `2` at `292765960`, and `_savable` is true. This authored default does not confirm `PlayerSmartFloat.get_Value`'s runtime result. Runtime player/container binding and overrides remain unknown; the V3 receipt explicitly records `runtime_effective_multiplier: null`.

The authored fixed step is independently current: TimeManager object **8** in **`globalgamemanagers`**, not `globalgamemanagers.assets`, is 16 bytes at file offset `361416`, object SHA-256 `4D1CCAA9F5A0084E7E66EDEFC089267E1CB327E0AA2C8B4CCB7C978A5586884A`. A standard Unity 2022.3 tree exactly consumes and roundtrips it. `Fixed Timestep` is `0.009999999776482582` at `361416` (`0AD7233C`); `Maximum Allowed Timestep` is `0.03333330154418945` at `361420`; `m_TimeScale` is `1` at `361424`; maximum particle timestep is `0.029999999329447746` at `361428`.

Thus `.10999999940395355 / .009999999776482582 = 11.000000186264518`, or nominal **11 m/s² per unit input**, **conditionally** assuming one full-input VelocityChange application each unchanged authored fixed step and a unit multiplier. This is a per-body reference conversion. Runtime timestep changes, player values, consumer cadence, support, acceleration-input scaling, local child forces and selected prefab can change the result. It is not a measured effective chassis acceleration. V3 is authoritative for the wrapper proof; it retains failed alternate extraction/helper attempts rather than treating them as successful validation.

## Adapter-owned choices and remaining fidelity work

The current adapter source is [bmx_ground_pump.h](../../Engine/Game/BMX/bmx_ground_pump.h), SHA-256 `7334479C1AA48B588DACC836D287491DC474EFC206F811D26EB77CD3FD4B024B`. The following distinctions remain deliberate implementation choices or unresolved fidelity questions:

| Concern | Current Streets evidence | Current adapter |
|---|---|---|
| Input combination | AddPump assigns; FixedUpdate sums direct + added, then clamps | Stronger direct/automatic magnitude, without summation |
| Timer boundary | Combined-input timer increments before strict `> duration` rejection | Separate bounded windows with partial-final-step integral scaling |
| Support | Configured grounded interface can reject force; exact predicate unknown | Actual wheel support with separation `<= .005 m` and opening speed `<= .05 m/s`; excludes continuation/speculative support |
| Arming/cancellation | OnLanded gates and TickAutoPump expiry are recovered; continuous caller behavior unknown | Fresh operator and release arming, observed flight history, continuous hop/preload/manual interruption and ownership/reset gates |
| Force | Stored ForceMode; main world AddForce, children local AddRelativeForce, optional managed-body path | Nominal 11 world-down acceleration at one chassis COM before current tire contacts |
| Runtime configuration | Authored component/default/timestep values decoded; active selection/effective multiplier unknown | Explicit portable constants and finite input validation |

The [adaptation note](ground-pump-adaptation.md) describes its integration and portable checks. Those checks establish adapter behavior, not Streets runtime behavior or handling likeness. The full Streets PumpSystem is outside this SimplePumpForce reference. A handling comparison still needs observed active bindings/settings, caller cadence and controlled runtime traces; neither a passing portable suite nor these static bodies supplies that acceptance.

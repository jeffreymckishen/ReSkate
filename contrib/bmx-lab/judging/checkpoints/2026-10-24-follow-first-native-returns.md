# BMX development checkpoint: native FOLLOW returns through revision 12

2026-10-24. The isolated XYZ trial recorded 12 committed SDK FOLLOW revisions whose native original calls returned normally. Its saved receipt reached `final_revision=12` and `returned_revision=12`, with latest forwarded native epoch `8934`. The next observed preparation failed a strict actor-lifetime check. Body parking and native cleanup remain unresolved.

The first stop was `dispatch_prepare/inspect_first`, actor phase `lifetime`, reason `native_lifetime_changed`. This rejection precedes supplied-transform validation; lane 16/class unknown does not identify a finite-value failure. The first cleanup observation was `capture_fence/fence_actor`, with aggregate `binding=different`. Its release/fence/park flags describe that first snapshot and do not establish a complete later history or identify which binding member changed.

The final saved phase was `retained_unknown`. The native receipt remained stopping and nonterminal, with `claim_known=true`, `in_flight=0`, `pending=[body_parked]`, `park_observed=false` and `native_retirement_known=false`. No cleanup ACK or ordinary caller release was attempted. Saved Lua counts contain no `entities.remove` entry, visual cleanup was deferred and the removal-attempt map is empty. Native DestroyEntity and the lifetime/global-epoch cause were not instrumented and remain unknown.

Baseline and actual controller runs each completed 301 scheduled neutral reports over six seconds. Each had a separate bootstrap LSB followed by neutral reports/readbacks. Final neutral release and disconnect were recorded. Input capture and lease bookkeeping completed without report debt; game consumption and physical-controller identity remain unobserved.

The archived still image shows an on-foot skater holding the board and a floating bike visual. It supplies no mounted, alignment, riding, trajectory or parity proof. The closure receipt records ordinary exit and manifest withdrawal; identical pre/post storage bytes retain the nonterminal preclose result. Exit does not prove body park, body-specific retirement or visual deletion.

Keep the strict lifetime checks and retained cleanup duty. Diagnose the lifetime change and close the same-body fence/park/retirement contract before claiming cleanup completion. XYZ handling and delayed Lua visual removal changed together, so their effects cannot be isolated from this run. The trial also predates integration of the public transform regression extraction and does not validate that proposal.

Evidence is archived under `E:\RESKATE DEV\follow-xyz-transform-native-v1`. The recorded source commit is `79b90525fc125ca3f4cb75058af84e4c9c750af4`; no fresh Git or source-to-binary verification is claimed. The preserved runtime was independently rehashed as `C10F2467DCC49B9F6848A9FD13DA0643ED7921BDB79DBBD18F4228873326D6DE`. All 13 post-trial staged package files match preflight `8C217ABB45EE61DC62665C751B75F5A40BE0D24E85550AAABC7C084362A8D7BC`, including FOLLOW main `FF0692E85487DFBC661B48BE6CAFD1973D3BCA640F2E1B7528A14B131EDD6782`; this does not independently recreate launch-time mounting or in-memory identity.

| Archived record | SHA256 |
| --- | --- |
| preclose-result.json | `08BBE0D899A4E89E60A7ECE7571245914E219E2812C770269B7B449E5D83107B` |
| preclose-actual-storage.json and postclose-actual-storage.json | `EA31B07A34F2F23C3E9CD56079B91FDAA9F47E96E6A5694823CEC7935AA95DF4` |
| preclose-ReSkate.log | `EED2ECB732F6215C75B76B835DB62029CC903BE506BBC7E19962DB76B5B98309` |
| closure.json | `1619E8E742ABA641D117419CBE5185901BAF37BB42F0B4150CB0CBD0521A4292` |
| postclose-ReSkate.log | `AE1B3B61C5021E8E4157602F1C078B42CD56B0337985A046BCA928FF8933A6D7` |

First diagnostics are at preclose log lines 494-495; shutdown is at postclose line 535. The preclose log was copied while actively written. Its hash pins the archived bytes, not an atomic or complete live event history. Receipt and call histories are bounded. This checkpoint reports the native archive; separate constructed Host validation is outside its scope.

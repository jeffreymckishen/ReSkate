# Profile4 portable source checkpoint with bounded decoder cursor

This is a portable source checkpoint, not a completed BMX port or a qualified game package. BMX behavior stays in the installable Lua mod. The checkpoint adds no SDK/native feature, private C++/header fixture, binary, game data, runtime package, controller input or process framework.

At the historical de52aa28 checkpoint on2026-10-28, exact matched offline sources passed:

| Scope | Cases | Meaning |
| --- | --- | --- |
| Existing Codec/Recorder/Preparation |31+31+13=75 | Pure Luau assertions |
| Independent public pair/View/Codec/real JSON/private fault |24+12+12+20+17=85 | Pure Luau assertions,160total/21,393assertions with prior75 |
| PowerShell consumer |65 | Strict wire/known-endpoint assertions |
| PowerShell P0 evidence |77legacy+82codec=159 | Recorded SDK evidence predicates; native qualification staysfalse |

The ordinary non-proxy Host gesture fixture passed over constructed SDK services. The full original1500ms neutral Host leg FAILED because a tick handler exceeded the existing50ms callback limit. That failed leg produced no complete failure-JSON/full-window counters. A separately archived diagnostic saw outertick318/54.4308ms, but internal phase, recorder counters and store progress remainedUNKNOWN. No cause, storage-phase attribution, full-window success, native P0/H1, actual takeoff/landing or BMX Streets parity is established. Preserve the failure; do not increase a timeout, heap, row cap or driving window to relabel it successful.

These are separate immutable Root receipts, not results produced by these instructions. Fresh preparations and future commits must identify their own exact source/runtime/runner and rerun only checks justified by changed bytes. A pure/PS success does not qualify the plugin Host or the game.

## Source and Test-only boundary

Runtime-facing source remains in `../../plugin`: Codec0DBDEC3F, Recorder116FE2AA and lazy EndpointView2A5646B6. The existing Stage-Trial graph lists Codec and Recorder; it does NOT list EndpointView, the new public/View/Codec suites or SDK fixture. The existing canonical59-module pins,13transforms, default closed config and graph are unchanged by this checkpoint. Adding a source file beside private plugin modules does not silently add it to any staged runtime.

`numeric/` and `private/` here are TEST ONLY. The numeric `json_encoding_tests` wrapper receives the existing Luau runner's explicit real JSON argument only when selected directly. The private Codec proxy and cost control are never staged into a plugin or used for normal Host/native qualification. `private/LEXICAL-RECIPE.json` retains the exact Recorder116FE/factoryD8CF recipe; only its selected production_codec_sha256 now binds Codec0DBD. Its absolute production_recorder_path is archival provenance only, NOT a portable dependency. Preparation below always uses the current repository Recorder bytes and exact declared hash.

Do NOT commit generated `hop_recorder_private_test_factory.lua` or `hop_evidence_codec_real.lua`. Generate/copy them only inside a fresh external unit folder. The factory is the current exact Recorder with only its final return replaced, then inverted byte-exact; it is not another maintained production source body or a public private-state API.

## Bounded cursor source and separate evidence

This successor adds `Codec.open_chunks` with the [portable cursor contract](../decoder-cursor/CONTRACT.md). It preserves wire/accounting4 and the legacy bulk decoder, adds no SDK API and keeps the same runtime Stage graph. Current source uses Codec0DBD, not the Codec9454 contained in historical de52aa28. Recorder116FE, its one-return private factoryD8CF, all original160 suite source bytes and all PowerShell consumer sources remain unchanged.

`../decoder-cursor/hop_evidence_codec_before.lua` is the exact frozen9454 TEST-ONLY legacy oracle. `hop_decoder_cursor_tests.lua` there is the independently authored21-case successor; it requires the current Codec and this before oracle in a fresh external unit folder. Neither file is a runtime dependency, optional staged test, emitted mod or alternate live codec. Do not copy them to the closed base or runtime graph.

Current0DBD has two matched Root pure receipts:75existing/1612assertions plus21cursor/9592assertions in the96-case receipt, then the remaining85/19781assertions. Together they cover the original160/21393 and181unique/30985 with the new cursor; no duplicate executions are counted. These are constructed standalone Luau/real-writer/fault fixtures, not normal Host budgets or gameplay. Full original Host composition and future native trials remain separate. Its predecessor865E failed cursor open because vendored Luau forbids freezing a protected metatable. Current0DBD removes only that sentinel while freezing both cursor and method table; the21st case exercises tampering and clone/forgery refusal. Preserve both actual receipts, never relabel the failure.

The exact current pure receipts are Root2 RESULT505B2526248D2CA93F12A1AB2CCE5FA13828D9172C8B871DAD6EAECC47F1F295 and remaining85 RESULT5D7A0019FE6240828DC4AEFDC0D83FF621608CD8CB04039FCCB6A46245688A33. They bind Codec0DBD and runner9DD1090A; the latter records five exact suite counts/exit0/emptyerrors. These hashes document completed Root runs, not commands executed by this runbook or a claim that future source/output copies pass. Keep their archived source/argv/log boundaries.

The earlier37CC/EBDB full original1500ms Host failures remain FAILED with their private phases unknown. A separate15BE diagnostic reached finish_entered and before_bulk_decode at outertick318 after terminal flush, without any after_bulk_decode or correlation marker. Those separate markers do not backfill the earlier failures, isolate decoder cost or establish one failure cause. The separate16D01A7B bounded neutral Host run has now finished with strict EOF at349ticks,1993verifiedrows and93acknowledgedcommands, but its adapter result is FAILED: sampled maximum average tick6.1869ms exceeds the unchanged6ms boundary. Sampled heap peak21,456,055bytes is not allocator/process high water. Child exit0/EOF does not qualify the resource-failed composition; no full-window or native acceptance is claimed. Exact RESULTD184498629B84F0496BEC0501D803BAFD1EE2289A44C4A618B62B599479E21E4 preserves that failure; a C++ timeline/cost cause is still unmeasured. The EOF349/1993rows/93ACK result describes PRE-UNLOAD stream verification only. D184 separately retains post_unload_observation_loss=true, interrupted=true, flushed=false, first_fault="explicit_unload_incomplete" and storage_fault=false; the unload tail is incomplete and no global-lossless claim is made. No change here raises64MiB/6ms/50ms,16ms/1500ms/400ticks, row/byte/depth/node/store limits or changes game/native policy. Source review and pure tests do not establish full-window or gameplay qualification.
## Closed base using the EXISTING stager

Commands below are a source-only runbook. Nothing runs merely by reading this file. Root must own an offline execution/preparation slot, reconcile all active processes/HID-HOLDs and choose fresh E-drive output. No native/game/deployment authority is supplied.

From the repository root, set your actual source/runner paths. All NEW artifacts stay under E:\RESKATE DEV. Do not create a new Desktop folder or reuse a frozen result directory.

```powershell
$ErrorActionPreference='Stop'
$Repo=(Get-Location).Path # CURRENT checkpoint/private source and stager
$Trial=Join-Path $Repo 'contrib\bmx-lab\hop-trial'
$CanonicalSourceRoot='E:\RESKATE DEV\worktrees\reskate-native-prepare-20261027' # Existing checkout matching every062 raw pin
# $CanonicalSourceRoot may equal $Repo ONLY if ALL59 pinned raw files below match.
$Lab='E:\RESKATE DEV\profile4-portable-unit-UNIQUE'
if(Test-Path -LiteralPath $Lab){throw 'Choose a fresh external lab directory'}
if((Get-FileHash -LiteralPath (Join-Path $Trial 'Stage-Trial.ps1')).Hash -cne 'E27F0732A44436C2BB16C671B302B49D709848D7B9ED6FE124E8BA63EE22DDF2'){throw 'Existing stager differs; obtain separate source review'}
if((Get-FileHash -LiteralPath (Join-Path $Trial 'stage-plan.json')).Hash -cne 'C8184385495B011BC5754F31AC3DBDF5EA89B4860AFF04270D8A425F32EC005C'){throw 'Existing stage graph differs; obtain separate source review'}
$pinPath=Join-Path $Trial 'source-pins.json'
if((Get-FileHash -LiteralPath $pinPath).Hash -cne '3E7FF0DE0DBCEF178B8CCF3B0D8237A71E364F0F35F20C6397DE01F34C92E7E1'){throw 'Canonical pin manifest differs; do not rewrite it'}
$canonicalPins=Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json
if($canonicalPins.source_commit -cne '062db162248d6b21c686f588924e0abc5954e99c' -or $canonicalPins.source_directory -cne 'contrib/bmx-lab/bmx-plugin' -or @($canonicalPins.files).Count -ne 59){throw 'Expected exact062 canonical59 contract'}
$CanonicalPluginRoot=Join-Path $CanonicalSourceRoot $canonicalPins.source_directory
foreach($pin in $canonicalPins.files){
    $canonicalFile=Join-Path $CanonicalPluginRoot $pin.path
    if((Get-Item -LiteralPath $canonicalFile).Length -ne $pin.bytes -or (Get-FileHash -LiteralPath $canonicalFile).Hash -cne $pin.sha256){throw ('Canonical source differs; choose a matching frozen checkout: '+$pin.path)}
}
# Existing Stage/Verify also enforce the exact flat selected set and path/reparse rules.
$null=New-Item -ItemType Directory -Path $Lab
$Base=Join-Path $Lab 'BMX_Hop_Trial_unreviewed'
& (Join-Path $Trial 'Stage-Trial.ps1') -Mode Stage -SourceRoot $CanonicalSourceRoot -OutputDirectory $Base -IncludeTests
& (Join-Path $Trial 'Stage-Trial.ps1') -Mode Verify -SourceRoot $CanonicalSourceRoot -OutputDirectory $Base -IncludeTests
```

`$Repo` and `$Trial` always identify the CURRENT private source/stager (Codec0DBD/Recorder116FE), not the frozen canonical checkout. `-SourceRoot` identifies the separate canonical checkout; the existing stager reads its private modules from its own `$PSScriptRoot`, so invoking `$Trial/Stage-Trial.ps1` preserves that split. Its report records both source_root and private_root. Never run the old checkout's stager/private folder by accident.

A whole repository HEAD or branch name is not proof that its canonical subtree equals062. Read/hash ALL59 entries in the pinned `source-pins.json`, including each raw byte length. At this checkpoint the current private worktree's canonical bike_runtime_core hasC3BD7813 rather than required887D5405, so `$CanonicalSourceRoot=$Repo` correctly refuses. Root's validated existing example is `E:\RESKATE DEV\worktrees\reskate-native-prepare-20261027`; other users must choose an existing checkout matching all59 pins, or separately arrange a frozen source checkout under their own authorized workflow. These instructions create no worktree and never rewrite pins/graph or substitute individual files to hide a mismatch. The current committed private sources and this runbook remain the checkpoint inputs; canonical062 is only the separate unchanged staging input.
Keep admission CLOSED: no ReviewedAdmission, alternate Phase/RunId/ReviewId or native config changes. The existing stager emits `transform-report.json` with exact raw `inputs` and `artifact-inventory.json` with exact output `files`; it does not emit a SOURCE-INVENTORY file. Its canonical source_commit062 describes that pinned canonical subtree, not the entire checkpoint/repository head. Check the CURRENT private Codec0DBD/Recorder116FE raw source, recorded input, recorded output and actual staged output explicitly before any unit copy:

```powershell
$stageReport=Get-Content -LiteralPath (Join-Path $Base 'transform-report.json') -Raw | ConvertFrom-Json
$stageInventory=Get-Content -LiteralPath (Join-Path $Base 'artifact-inventory.json') -Raw | ConvertFrom-Json
$privatePins=[ordered]@{
    'plugin/hop_evidence_codec.lua'='0DBDEC3FCBEDE4C47A5E4B063DAD833F67919B2BFE19BBDCFB680F99182B47F8'
    'plugin/hop_recorder.lua'='116FE2AA7F708DCE2DA28745535A89F75766CD85074113C4253AD3737C6039AA'
}
foreach($relative in $privatePins.Keys){
    $rawSha=(Get-FileHash -LiteralPath (Join-Path $Trial $relative)).Hash
    $stagedSha=(Get-FileHash -LiteralPath (Join-Path $Base $relative)).Hash
    $inputRows=@($stageReport.inputs | Where-Object {$_.origin -ceq 'private' -and $_.path -ceq $relative})
    $outputRows=@($stageInventory.files | Where-Object {$_.path -ceq $relative})
    if($rawSha -cne $privatePins[$relative] -or $stagedSha -cne $rawSha -or $inputRows.Count -ne 1 -or $outputRows.Count -ne 1 -or $inputRows[0].sha256 -cne $rawSha -or $outputRows[0].sha256 -cne $rawSha){throw ('Current profile4 source/input/output hashes differ: '+$relative)}
}
```

Those Stage/Verify commands apply ONLY to that unchanged base artifact and must actually pass before anyone claims verification. The following external unit directories are NOT staged mods. Do not copy base manifest/transform-report/artifact-inventory files as a unit admission identity; they must NEVER receive a Stage-Trial Verify claim after their unit-only additions. No stager graph/pin update or runtime packaging integration is implied. A future actual runtime migration needs separately sealed source/profile/build evidence.

## PREPARE only: fresh external unit folders

This inline byte-copy recipe does not import Lua, run a test, launch a process or change repository files. It leaves the verified base untouched. Root first confirms ordinary canonical, non-reparse and disjoint source/output paths and current exact checkpoint identity.

```powershell
function Copy-UnitBytes([string]$Source,[string]$Destination,[string]$Expected=''){
    if(Test-Path -LiteralPath $Destination){throw ('Fresh unit file already exists: '+$Destination)}
    $bytes=[IO.File]::ReadAllBytes($Source)
    $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    if($Expected -and $sha -cne $Expected){throw ('Source pin differs: '+$Source)}
    [IO.File]::WriteAllBytes($Destination,$bytes)
    if((Get-FileHash -LiteralPath $Destination).Hash -cne $sha){throw 'Byte-copy differs'}
}
$Normal=Join-Path $Lab 'unit-normal'
$Numeric=Join-Path $Lab 'unit-numeric'
$Fault=Join-Path $Lab 'unit-private-fault'
$Ps=Join-Path $Lab 'unit-powershell'
$Cursor=Join-Path $Lab 'unit-decoder-cursor'
foreach($directory in @($Normal,$Numeric,$Fault,$Ps,$Cursor)){if(Test-Path -LiteralPath $directory){throw 'Unit destination must be fresh'};$null=New-Item -ItemType Directory -Path $directory}
foreach($file in Get-ChildItem -LiteralPath (Join-Path $Base 'plugin') -File -Filter '*.lua'){Copy-UnitBytes $file.FullName (Join-Path $Normal $file.Name)}
foreach($name in @('hop_endpoint_view.lua','hop_row_pair_candidate_tests.lua','hop_endpoint_view_contract_tests.lua','hop_pair_v4_codec_tests.lua','hop_pair_sdk_fixtures.lua')){Copy-UnitBytes (Join-Path $Trial ('plugin\'+$name)) (Join-Path $Normal $name)}
$Codec=Join-Path $Trial 'plugin\hop_evidence_codec.lua'
$Recorder=Join-Path $Trial 'plugin\hop_recorder.lua'
$codecSha='0DBDEC3FCBEDE4C47A5E4B063DAD833F67919B2BFE19BBDCFB680F99182B47F8'
$recorderSha='116FE2AA7F708DCE2DA28745535A89F75766CD85074113C4253AD3737C6039AA'
Copy-UnitBytes $Codec (Join-Path $Numeric 'hop_evidence_codec.lua') $codecSha
foreach($name in @('hop_integral_wire_tests.lua','json_encoding_tests.lua')){Copy-UnitBytes (Join-Path $Trial ('Test\row-pair\numeric\'+$name)) (Join-Path $Numeric $name)}
foreach($name in @('hop_evidence_codec.lua','hop_pair_fault_control.lua','hop_pair_preflight_fault_tests.lua')){Copy-UnitBytes (Join-Path $Trial ('Test\row-pair\private\'+$name)) (Join-Path $Fault $name)}
Copy-UnitBytes (Join-Path $Trial 'plugin\hop_pair_sdk_fixtures.lua') (Join-Path $Fault 'hop_pair_sdk_fixtures.lua') 'B14BFE28CF4AC44D2AE412FCA2D0C1A3EAF7660C1B23E24247B7C34089109146'
Copy-UnitBytes $Codec (Join-Path $Fault 'hop_evidence_codec_real.lua') $codecSha
foreach($name in @('Decode-HopEvidence.ps1','Decode-HopEvidence.Tests.ps1','P0-Evidence.ps1','P0-Evidence.Tests.ps1')){Copy-UnitBytes (Join-Path $Trial $name) (Join-Path $Ps $name)}
Copy-UnitBytes $Codec (Join-Path $Cursor 'hop_evidence_codec.lua') $codecSha
Copy-UnitBytes (Join-Path $Trial 'Test\decoder-cursor\hop_evidence_codec_before.lua') (Join-Path $Cursor 'hop_evidence_codec_before.lua') '9454BD22F7CD24D570CD4BFBEB82C41981AE8F469DCE7CB71A9991844342BF9B'
Copy-UnitBytes (Join-Path $Trial 'Test\decoder-cursor\hop_decoder_cursor_tests.lua') (Join-Path $Cursor 'hop_decoder_cursor_tests.lua') '5F5C1FB664DC38191A0C85EE1F9E0C21411E67303B94AB42B54C4179EC360E8E'
```

Generate the private factory ONLY from the current exact Recorder and the reviewed one-return recipe. Byte-preserving inverse and expected factory hash are mandatory before writing it:

```powershell
$recipe=Get-Content -LiteralPath (Join-Path $Trial 'Test\row-pair\private\LEXICAL-RECIPE.json') -Raw | ConvertFrom-Json
$original=[IO.File]::ReadAllBytes($Recorder)
if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($original)) -cne $recorderSha){throw 'Current Recorder pin differs'}
if($recipe.production_recorder_sha256 -cne $recorderSha -or $recipe.production_codec_sha256 -cne $codecSha -or $recipe.occurrences -ne 1){throw 'Lexical recipe differs'}
$utf8=[Text.UTF8Encoding]::new($false,$true)
$text=$utf8.GetString($original)
$position=$text.IndexOf([string]$recipe.before,[StringComparison]::Ordinal)
if($position -lt 0 -or $position -ne $text.LastIndexOf([string]$recipe.before,[StringComparison]::Ordinal) -or $text.Substring($position+$recipe.before.Length) -cnotmatch '^\s*$'){throw 'Final return is not unique and canonical'}
$factory=$text.Remove($position,$recipe.before.Length).Insert($position,[string]$recipe.after)
$inverse=$factory.Remove($position,$recipe.after.Length).Insert($position,[string]$recipe.before)
if([Convert]::ToBase64String($utf8.GetBytes($inverse)) -cne [Convert]::ToBase64String($original)){throw 'Factory inverse changed production bytes/newlines/EOF'}
$factoryBytes=$utf8.GetBytes($factory)
if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($factoryBytes)) -cne 'D8CFF34CA53F064395D98110D218B90F7A904648C26E538C4873B7155E15F9F1' -or $recipe.factory_sha256 -cne 'D8CFF34CA53F064395D98110D218B90F7A904648C26E538C4873B7155E15F9F1'){throw 'Generated factory differs'}
$factoryPath=Join-Path $Fault 'hop_recorder_private_test_factory.lua'
if(Test-Path -LiteralPath $factoryPath){throw 'Factory destination must be fresh'}
[IO.File]::WriteAllBytes($factoryPath,$factoryBytes)
```

The private factory and codec_real exist only in `unit-private-fault`, NEVER the repository plugin, closed base, Host package or game. The proxy/cost-control source stays Test-only. Preserve prepared folder hashes/commands/results under the fresh lab root; record them as unit-artifact provenance, never as Stage Verify or native qualification.

## Existing runner invocations, execution separately owned

Use the existing built standalone Luau runner whose source is `contrib/bmx-lab/luau-runner`. Build outside the repository only when Root separately assigns that work; this checkpoint changes no runner/CMake/process/deadline policy. Set the actual reviewed runner path and verify its identity first. Root's matched receipt used9DD1090A; a different runner needs its own source/build identity.

```powershell
$Runner='E:\RESKATE DEV\builds\luau-runner-f4b0d9a2-20261028\Release\bmx_luau_tests.exe'
# Run only under Root-owned offline validation, with retained argv/exit/log evidence.
foreach($suite in @('hop_evidence_codec_tests','hop_recorder_tests','hop_prepare_evidence_tests','hop_row_pair_candidate_tests','hop_endpoint_view_contract_tests','hop_pair_v4_codec_tests')){& $Runner $Normal $suite;if($LASTEXITCODE -ne 0){throw ('Unit suite failed: '+$suite)}}
& $Runner $Numeric 'json_encoding_tests'
if($LASTEXITCODE -ne 0){throw 'Real JSON numeric suite failed'}
& $Runner $Fault 'hop_pair_preflight_fault_tests'
if($LASTEXITCODE -ne 0){throw 'Private preflight suite failed'}
& $Runner $Cursor 'hop_decoder_cursor_tests'
if($LASTEXITCODE -ne 0){throw 'Bounded decoder cursor suite failed'}
```

The wrapper name `json_encoding_tests` is essential for the EXISTING real-writer argument; never inject a global helper or route the fault proxy through normal tests. These commands do not establish normal Host timing or SDK permission. Use the current approved Root capture harness if retained process/deadline evidence is required; this runbook adds none.

PowerShell suites use their exact adjacent four-file unit copy, with Root's already reviewed offline process-capture policy:

```powershell
$Pwsh='C:\Users\Jeffr\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe'
& $Pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $Ps 'Decode-HopEvidence.Tests.ps1') -RunReviewedTests
if($LASTEXITCODE -ne 0){throw 'Consumer suite failed'}
& $Pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $Ps 'P0-Evidence.Tests.ps1') -RunReviewedTests
if($LASTEXITCODE -ne 0){throw 'P0 evidence suite failed'}
```

Do not repeat unchanged65/159 solely because this runbook exists. Source edits, integration changes or a fresh checkpoint's acceptance requirements determine which checks Root reruns. No command here authorizes API expansion, PR publication, live game/HID, installation or native trials.
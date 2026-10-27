# Authored regression suite; not run as part of staging or verification.
# Run only in a separately assigned source-test slot. No Lua/native/game execution.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SourceRoot,[switch]$RunReviewedTests)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if (-not $RunReviewedTests) { throw 'Explicit RunReviewedTests is required; this file is inert by default' }
foreach ($hold in @('C:\Users\Jeffr\Desktop\reskate\build\bmx\HID-HOLD','E:\RESKATE DEV\reskate\build\bmx\HID-HOLD')) {
    if (Test-Path -LiteralPath $hold) { throw "HID-HOLD active: $hold" }
}
$source=[IO.Path]::GetFullPath($SourceRoot)
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('reskate-hop-stage-'+[Guid]::NewGuid().ToString('N'))
$clone=Join-Path $testRoot 'source'
$tool=Join-Path $testRoot 'tool'
$null=New-Item -ItemType Directory -Path $testRoot -ErrorAction Stop
$null=New-Item -ItemType Directory -Path $clone
$null=New-Item -ItemType Directory -Path $tool
$null=New-Item -ItemType Directory -Path (Join-Path $tool 'plugin')
$canonical=Join-Path $clone 'contrib\bmx-lab\bmx-plugin\plugin'
$null=New-Item -ItemType Directory -Path $canonical -Force
$pins=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'source-pins.json') -Raw | ConvertFrom-Json
foreach ($pin in @($pins.files)) {
    $original=Join-Path (Join-Path $source 'contrib\bmx-lab\bmx-plugin') $pin.path
    [IO.File]::WriteAllBytes((Join-Path $canonical ([IO.Path]::GetFileName($pin.path))),[IO.File]::ReadAllBytes($original))
}
foreach ($name in @('Stage-Trial.ps1','stage-plan.json','source-pins.json','manifest.json','reskate-plugin.json',
    'plugin/main.lua','plugin/hop_config.lua','plugin/hop_context.lua','plugin/hop_force_stage.lua',
    'plugin/hop_services.lua','plugin/hop_guard.lua','plugin/hop_recorder.lua',
    'plugin/hop_guard_tests.lua','plugin/hop_recorder_tests.lua','plugin/hop_composition_tests.lua',
    'plugin/hop_prepare_evidence_tests.lua','plugin/hop_prepare_cancel_tests.lua')) {
    [IO.File]::WriteAllBytes((Join-Path $tool $name),[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $name)))
}
$script=Join-Path $tool 'Stage-Trial.ps1'
$utf8=[Text.UTF8Encoding]::new($false)
$cases=0
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Out([string]$Bucket,[string]$Run='unreviewed') {
    $parent=Join-Path $testRoot $Bucket
    if (-not (Test-Path -LiteralPath $parent)) { $null=New-Item -ItemType Directory -Path $parent }
    return Join-Path $parent ('BMX_Hop_Trial_'+$Run)
}
function Refuses([scriptblock]$Action,[string]$Absent) {
    $failed=$false
    try { $null=& $Action } catch { $failed=$true }
    Check $failed 'Expected refusal'
    if ($Absent) { Check (-not (Test-Path -LiteralPath $Absent)) 'Refusal created an output path' }
}
function Snapshot([string]$Directory) {
    $rows=@(Get-ChildItem -LiteralPath $Directory -File -Force -Recurse | Sort-Object FullName |
        ForEach-Object { $_.FullName.Substring($Directory.Length)+':'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
    return [string]::Join('|',$rows)
}
function Case([string]$Name,[scriptblock]$Action) {
    foreach ($hold in @('C:\Users\Jeffr\Desktop\reskate\build\bmx\HID-HOLD','E:\RESKATE DEV\reskate\build\bmx\HID-HOLD')) {
        if (Test-Path -LiteralPath $hold) { throw "HID-HOLD active: $hold" }
    }
    & $Action
    $script:cases++
    Write-Output "PASS $Name"
}
$closed=Out 'closed'
$admitted=Out 'admitted' 'p0test'
$h1=Out 'h1' 'h1test'
Case 'closed copy and read-only verification' {
    $result=& $script -Mode Stage -SourceRoot $clone -OutputDirectory $closed
    Check ($result.files -eq 72 -and -not $result.reviewed_admission) 'Closed inventory/admission'
    foreach ($pin in @($pins.files)) {
        $copied=Join-Path $closed $pin.path
        Check ((Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash -ceq $pin.sha256) 'Closed canonical bytes changed'
    }
    $before=Snapshot $closed
    $null=& $script -SourceRoot $clone -OutputDirectory $closed
    Check ((Snapshot $closed) -ceq $before) 'Verify wrote files'
    Check ((Get-Content -LiteralPath (Join-Path $closed 'plugin/hop_config.lua') -Raw).Contains('admission_enabled=false')) 'Closed config opened'
    Check (-not (Test-Path -LiteralPath (Join-Path $closed 'plugin/hop_guard_tests.lua'))) 'Tests copied by default'
}
Case 'explicit admitted P0 exact changes and unchanged gates' {
    $result=& $script -Mode Stage -SourceRoot $clone -OutputDirectory $admitted -ReviewedAdmission -Phase P0 -RunId p0test -ReviewId review1
    Check ($result.files -eq 72 -and $result.reviewed_admission) 'Admitted inventory'
    $null=& $script -SourceRoot $clone -OutputDirectory $admitted -ReviewedAdmission -Phase P0 -RunId p0test -ReviewId review1
    $core=Get-Content -LiteralPath (Join-Path $admitted 'plugin/bike_runtime_core.lua') -Raw
    Check ($core.Contains('local RIDE_COMPOSITION_QUALIFIED=true') -and $core.Contains('local RIDE_WINDOW_MS=1500')) 'Core transforms absent'
    Check ($core.Contains('local FOLLOW_RENEWAL_QUALIFIED=false') -and $core.Contains('local FOLLOW_LEAD_QUALIFIED=false')) 'Follow gates changed'
    $ride=Get-Content -LiteralPath (Join-Path $admitted 'plugin/ride_runtime.lua') -Raw
    Check ($ride.Contains('local RIDE_TRICKS_QUALIFIED = false') -and $ride.Contains('TrialContext.before_force(s.body,sample,controls,body,frame,contact)')) 'Ride guard/trick contract'
    $report=Get-Content -LiteralPath (Join-Path $admitted 'transform-report.json') -Raw | ConvertFrom-Json
    Check (@($report.transforms).Count -eq 17) 'Declared transform report count'
    Check ($report.source_commit -ceq '062db162248d6b21c686f588924e0abc5954e99c') 'Canonical revision changed'
    Check ($core.Contains('local function prepare_native(generation,before)') -and
        $core.Contains('T.mount_deadline_at') -and $core.Contains('native_preparation=')) 'Production preparation phase absent'
    $admission=Get-Content -LiteralPath (Join-Path $admitted 'plugin/bike_admission.lua') -Raw
    Check ($admission.Contains('"world.physics.prepare"')) 'Preparation admission dependency absent'
}
Case 'H1 explicit identity and isolated optional test inventory' {
    $result=& $script -Mode Stage -SourceRoot $clone -OutputDirectory $h1 -ReviewedAdmission -Phase H1 -RunId h1test -ReviewId review2 -IncludeTests
    Check ($result.files -eq 78) 'Optional tests and exact-entry fixture inventory'
    $null=& $script -SourceRoot $clone -OutputDirectory $h1 -ReviewedAdmission -Phase H1 -RunId h1test -ReviewId review2 -IncludeTests
    $config=Get-Content -LiteralPath (Join-Path $h1 'plugin/hop_config.lua') -Raw
    Check ($config.Contains('admission_enabled=true') -and $config.Contains('phase="H1"') -and $config.Contains('run_id="h1test"')) 'H1 config'
    Refuses { & $script -SourceRoot $clone -OutputDirectory $h1 -ReviewedAdmission -Phase H1 -RunId h1test -ReviewId wrongreview -IncludeTests } ''
}
Case 'canonical mutations including duplicate and alternate declarations refuse before creation' {
    $path=Join-Path $canonical 'bike_runtime_core.lua'
    $saved=[IO.File]::ReadAllBytes($path)
    $original=$utf8.GetString($saved)
    $variants=@(($original+[char]10),
        $original.Replace('local RIDE_COMPOSITION_QUALIFIED=false','local RIDE_COMPOSITION_QUALIFIED=true'),
        $original.Replace('local RIDE_COMPOSITION_QUALIFIED=false',('local RIDE_COMPOSITION_QUALIFIED=false'+[char]10+'local RIDE_COMPOSITION_QUALIFIED=false')))
    $n=0
    try {
        foreach ($variant in $variants) {
            [IO.File]::WriteAllText($path,$variant,$utf8)
            $out=Out ('changed-'+$n)
            Refuses { & $script -Mode Stage -SourceRoot $clone -OutputDirectory $out } $out
            $n++
        }
    } finally { [IO.File]::WriteAllBytes($path,$saved) }
}
Case 'Admission and fixed forces bytes remain independently pinned' {
    foreach ($name in @('bike_admission.lua','forces.lua')) {
        $path=Join-Path $canonical $name
        $saved=[IO.File]::ReadAllBytes($path)
        try {
            [IO.File]::AppendAllText($path,[string][char]10,$utf8)
            $out=Out ('changed-'+$name.Replace('.','-'))
            Refuses { & $script -Mode Stage -SourceRoot $clone -OutputDirectory $out } $out
        } finally { [IO.File]::WriteAllBytes($path,$saved) }
    }
    $forcePin=@($pins.files | Where-Object { $_.path -ceq 'plugin/forces.lua' })
    Check ($forcePin.Count -eq 1 -and $forcePin[0].bytes -eq 37599 -and
        $forcePin[0].sha256 -ceq '3BB16CB48F0A3304F651346FBD97A97D8CF4FE023E12B0E7FC7073429DD9C5E5') 'Fixed canonical forces pin changed'
}
Case 'extra selected source module refuses before creation' {
    $extra=Join-Path $canonical 'extra_production.lua'
    try {
        [IO.File]::WriteAllText($extra,'return {}',$utf8)
        $out=Out 'extra-source'
        Refuses { & $script -Mode Stage -SourceRoot $clone -OutputDirectory $out } $out
    } finally { Remove-Item -LiteralPath $extra }
}
Case 'missing private dependency refuses before creation' {
    $path=Join-Path $tool 'plugin/hop_recorder.lua'
    $saved=[IO.File]::ReadAllBytes($path)
    try {
        Remove-Item -LiteralPath $path
        $out=Out 'missing-private'
        Refuses { & $script -Mode Stage -SourceRoot $clone -OutputDirectory $out } $out
    } finally { [IO.File]::WriteAllBytes($path,$saved) }
}
Case 'changed pins or plan cannot redefine expected output' {
    foreach ($name in @('source-pins.json','stage-plan.json')) {
        $path=Join-Path $tool $name
        $saved=[IO.File]::ReadAllBytes($path)
        try {
            [IO.File]::AppendAllText($path,[string][char]10,$utf8)
            $out=Out ('changed-'+$name.Replace('.','-'))
            Refuses { & $script -Mode Stage -SourceRoot $clone -OutputDirectory $out } $out
        } finally { [IO.File]::WriteAllBytes($path,$saved) }
    }
}
Case 'manifest config module inventory and report tampering are read-only refusals' {
    foreach ($name in @('manifest.json','reskate-plugin.json','plugin/hop_config.lua','plugin/ride_runtime.lua','artifact-inventory.json','transform-report.json')) {
        $path=Join-Path $closed $name
        $saved=[IO.File]::ReadAllBytes($path)
        try {
            [IO.File]::AppendAllText($path,[string][char]10,$utf8)
            $before=Snapshot $closed
            Refuses { & $script -SourceRoot $clone -OutputDirectory $closed } ''
            Check ((Snapshot $closed) -ceq $before) 'Verify repaired a tampered artifact'
        } finally { [IO.File]::WriteAllBytes($path,$saved) }
    }
    $path=Join-Path $closed 'plugin/extra.lua'
    try {
        [IO.File]::WriteAllText($path,'return {}',$utf8)
        $before=Snapshot $closed
        Refuses { & $script -SourceRoot $clone -OutputDirectory $closed } ''
        Check ((Snapshot $closed) -ceq $before) 'Verify removed an extra file'
    } finally { Remove-Item -LiteralPath $path }
    $path=Join-Path $closed 'plugin/input.lua'
    $saved=[IO.File]::ReadAllBytes($path)
    try {
        Remove-Item -LiteralPath $path
        Refuses { & $script -SourceRoot $clone -OutputDirectory $closed } ''
        Check (-not (Test-Path -LiteralPath $path)) 'Verify restored a missing file'
    } finally { [IO.File]::WriteAllBytes($path,$saved) }
}
Case 'existing empty output is refused without additions' {
    $out=Out 'existing'
    $null=New-Item -ItemType Directory -Path $out
    Refuses { & $script -Mode Stage -SourceRoot $clone -OutputDirectory $out } ''
    Check (@(Get-ChildItem -LiteralPath $out -Force).Count -eq 0) 'Existing output was changed'
}
Case 'source overlap and deployment paths refuse before creation' {
    $out=Join-Path $clone 'BMX_Hop_Trial_unreviewed'
    Refuses { & $script -Mode Stage -SourceRoot $clone -OutputDirectory $out } $out
    $parent=Join-Path $testRoot 'Mods'
    $null=New-Item -ItemType Directory -Path $parent
    $out=Join-Path $parent 'BMX_Hop_Trial_unreviewed'
    Refuses { & $script -Mode Stage -SourceRoot $clone -OutputDirectory $out } $out
}
Case 'review and run metadata cannot implicitly arm' {
    $out=Out 'missing-review' 'run1'
    Refuses { & $script -Mode Stage -SourceRoot $clone -OutputDirectory $out -ReviewedAdmission -RunId run1 } $out
    Refuses { & $script -Mode Stage -SourceRoot $clone -OutputDirectory $out -RunId run1 -Phase H1 } $out
    $out=Out 'private-config'
    $path=Join-Path $tool 'plugin/hop_config.lua'
    $saved=[IO.File]::ReadAllBytes($path)
    try {
        [IO.File]::WriteAllText($path,$utf8.GetString($saved).Replace('hop_strength=.25','hop_strength=.5'),$utf8)
        Refuses { & $script -Mode Stage -SourceRoot $clone -OutputDirectory $out } $out
    } finally { [IO.File]::WriteAllBytes($path,$saved) }
}
Case 'junction output ancestor refuses without touching target' {
    $target=Join-Path $testRoot 'junction-target'
    $link=Join-Path $testRoot 'junction-link'
    $null=New-Item -ItemType Directory -Path $target
    # Junction creation is a test prerequisite, not silently skipped.
    $null=New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop
    $out=Join-Path $link 'BMX_Hop_Trial_unreviewed'
    Refuses { & $script -Mode Stage -SourceRoot $clone -OutputDirectory $out } $out
    Check (@(Get-ChildItem -LiteralPath $target -Force).Count -eq 0) 'Junction target changed'
}
Case 'safe run identifier length agrees with recorder' {
    $longrun='r'*32
    $out=Out 'run32' $longrun
    $null=& $script -Mode Stage -SourceRoot $clone -OutputDirectory $out -ReviewedAdmission -RunId $longrun -ReviewId review3
    $null=& $script -SourceRoot $clone -OutputDirectory $out -ReviewedAdmission -RunId $longrun -ReviewId review3
    $longrun+='r'
    $out=Out 'run33' $longrun
    Refuses { & $script -Mode Stage -SourceRoot $clone -OutputDirectory $out -ReviewedAdmission -RunId $longrun -ReviewId review3 } $out
}
Case 'private permission manifest rejects extra and duplicate keys before output' {
    $path=Join-Path $tool 'reskate-plugin.json'
    $saved=[IO.File]::ReadAllBytes($path)
    $text=$utf8.GetString($saved)
    $variants=@(
        ($text.Replace('"api": 1','"unexpected": true, "api": 1')),
        ($text.Replace('"permissions": [','"permissions": ["world.physics.follow.renew"], "permissions": [')))
    $n=0
    try {
        foreach ($variant in $variants) {
            [IO.File]::WriteAllText($path,$variant,$utf8)
            $out=Out ('manifest-contract-'+$n)
            Refuses { & $script -Mode Stage -SourceRoot $clone -OutputDirectory $out } $out
            $n++
        }
    } finally { [IO.File]::WriteAllBytes($path,$saved) }
}
Case 'private package manifest schema and description are exact review inputs' {
    $path=Join-Path $tool 'manifest.json'
    $saved=[IO.File]::ReadAllBytes($path)
    $text=$utf8.GetString($saved)
    $variants=@(
        ($text.Replace('admission defaults to disabled','admission enabled by default')),
        ($text.Replace('"name":','"unexpected": true, "name":')),
        ($text.Replace('"name":','"name": "BMX_Hop_Trial_unreviewed", "name":')))
    $n=0
    try {
        foreach ($variant in $variants) {
            [IO.File]::WriteAllText($path,$variant,$utf8)
            $out=Out ('package-contract-'+$n)
            Refuses { & $script -Mode Stage -SourceRoot $clone -OutputDirectory $out } $out
            $n++
        }
    } finally { [IO.File]::WriteAllBytes($path,$saved) }
}
Case 'actual-entry fixture is exact and absent without IncludeTests' {
    Check (-not (Test-Path -LiteralPath (Join-Path $closed 'plugin/hop_entry_fixture.lua'))) 'Closed runtime copy contains test fixture'
    Check (-not (Test-Path -LiteralPath (Join-Path $admitted 'plugin/hop_entry_fixture.lua'))) 'Admitted runtime copy contains test fixture'
    $body=[IO.File]::ReadAllBytes((Join-Path $tool 'plugin/main.lua'))
    $prefix=$utf8.GetBytes('return function(reskate, require)'+[char]10)
    $suffix=$utf8.GetBytes([string][char]10+'end'+[char]10)
    $expectedBytes=[byte[]]::new($prefix.Length+$body.Length+$suffix.Length)
    [Buffer]::BlockCopy($prefix,0,$expectedBytes,0,$prefix.Length)
    [Buffer]::BlockCopy($body,0,$expectedBytes,$prefix.Length,$body.Length)
    [Buffer]::BlockCopy($suffix,0,$expectedBytes,$prefix.Length+$body.Length,$suffix.Length)
    $path=Join-Path $h1 'plugin/hop_entry_fixture.lua'
    $actual=[IO.File]::ReadAllBytes($path)
    Check ([Convert]::ToBase64String($actual) -ceq [Convert]::ToBase64String($expectedBytes)) 'Fixture changed actual entry bytes or wrapper'
    $report=Get-Content -LiteralPath (Join-Path $h1 'transform-report.json') -Raw | ConvertFrom-Json
    $generated=@($report.transforms | Where-Object { $_.id -ceq 'test-only-actual-entry' })
    Check ($generated.Count -eq 1 -and $generated[0].generated -and $generated[0].source_bytes -eq $body.Length) 'Fixture provenance missing'
    try {
        [IO.File]::AppendAllText($path,'-- changed fixture body',$utf8)
        $before=Snapshot $h1
        Refuses { & $script -SourceRoot $clone -OutputDirectory $h1 -ReviewedAdmission -Phase H1 -RunId h1test -ReviewId review2 -IncludeTests } ''
        Check ((Snapshot $h1) -ceq $before) 'Verify repaired modified fixture'
    } finally { [IO.File]::WriteAllBytes($path,$actual) }
}
Check ($cases -eq 17) 'Unexpected regression case count'
# Preserve this isolated evidence folder. No recursive deletion or deployment follows.
[pscustomobject]@{cases=$cases;artifact_root=$testRoot;native_execution=$false}

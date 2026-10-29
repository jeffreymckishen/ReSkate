param(
    [Parameter(Mandatory)][string]$TestRoot,
    [ValidateSet('entry','two-cycle')][string]$Matrix='entry'
)
# File preparation only. Root separately owns the runner and execution grant.
$ErrorActionPreference='Stop'
$Package=Split-Path -Parent $PSScriptRoot
if(-not [IO.Path]::IsPathFullyQualified($TestRoot) -or [IO.Path]::GetFullPath($TestRoot) -cne $TestRoot -or
    (Split-Path -Parent $TestRoot) -cne 'E:\RESKATE DEV' -or
    (Split-Path -Leaf $TestRoot) -notmatch '^bmx-playable-tests-[a-z0-9-]{1,64}$' -or
    (Test-Path -LiteralPath $TestRoot)){throw 'New direct E bmx-playable-tests-* directory required'}
function Assert-PlainPath([string]$Path){
    $p=$Path
    while($p){
        if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse path refused'}
        $next=[IO.Path]::GetDirectoryName($p);if($next -ceq $p){break};$p=$next
    }
}
Assert-PlainPath $Package
Assert-PlainPath $TestRoot
$manifestPath=Join-Path $PSScriptRoot 'two_cycle_tests.json'
Assert-PlainPath $manifestPath
if((Get-FileHash -LiteralPath $manifestPath).Hash -cne '4CC4C90D90039F7283C33679406CE91C12415FBEBEBD6C0F108CA68E9D8AD655'){throw 'Exact matrix manifest changed'}
$plan=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
if($plan.schema -ne 1 -or $plan.flat_file_count -ne 56 -or $plan.quota_file_count -ne 57 -or
    @($plan.files).Count -ne 56 -or @($plan.runtime_files).Count -ne 32 -or @($plan.suites).Count -ne 22){throw 'Unexpected matrix shape'}
function Assert-Source($Row){
    if($Row.source -notmatch '^(plugin|Test)/[A-Za-z0-9_-]+\.lua$' -and $Row.source -notin @('README.md','reskate-plugin.json')){throw 'Non-relative matrix input refused'}
    $source=Join-Path $Package $Row.source
    Assert-PlainPath $source
    if(-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-Item -LiteralPath $source).Length -ne $Row.bytes -or
        (Get-FileHash -LiteralPath $source).Hash -cne $Row.sha256){throw ('Exact source changed: '+$Row.source)}
}
$destinations=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($row in $plan.files){
    if($row.destination -notmatch '^[A-Za-z0-9_-]+\.lua$' -or -not $destinations.Add($row.destination)){throw 'Duplicate/invalid flat destination'}
    Assert-Source $row
}
foreach($row in $plan.runtime_files){Assert-Source $row}
$wanted=@($plan.runtime_files|Where-Object {$_.source.StartsWith('plugin/',[StringComparison]::Ordinal)}|ForEach-Object {[IO.Path]::GetFileName($_.source)}|Sort-Object)
$actual=@(Get-ChildItem -LiteralPath (Join-Path $Package 'plugin') -File|ForEach-Object Name|Sort-Object)
if(($wanted -join "`n") -cne ($actual -join "`n")){throw 'Shipping plugin has missing/extra files; no tests or wrappers may be installed there'}
$main=[IO.File]::ReadAllText((Join-Path $Package 'plugin/main.lua'))
if(([regex]::Matches($main,[regex]::Escape('local EXPERIMENTAL_ADMITTED=false'))).Count -ne 1){throw 'Closed admission changed'}
$utf=[Text.UTF8Encoding]::new($false)
foreach($wrapper in $plan.wrappers){
    $source=Join-Path $Package $wrapper.source;$fixture=Join-Path $Package $wrapper.fixture
    Assert-PlainPath $source;Assert-PlainPath $fixture
    if((Get-FileHash -LiteralPath $source).Hash -cne $wrapper.source_sha256 -or
        (Get-FileHash -LiteralPath $fixture).Hash -cne $wrapper.fixture_sha256){throw 'Wrapper source pin changed'}
    $expected=$utf.GetBytes($wrapper.prefix+[IO.File]::ReadAllText($source)+$wrapper.suffix)
    if([Convert]::ToBase64String($expected) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture))){throw 'Wrapper raw inverse differs'}
}
$entryNames=@('bmx_playable_entry.lua','ride_r1_record.lua','bmx_playable_entry_tests.lua','playable_main_fixture.lua','bmx_playable_main_tests.lua','force_math.lua','bike_geometry.lua')
$files=if($Matrix -ceq 'entry'){@($plan.files|Where-Object {$_.destination -in $entryNames})}else{@($plan.files)}
if($Matrix -ceq 'entry' -and $files.Count -ne 7){throw 'Seven-file legacy unit differs'}
$null=New-Item -ItemType Directory -Path $TestRoot -ErrorAction Stop
function Copy-Files([string]$Destination,$Rows){
    foreach($row in $Rows){
        $to=Join-Path $Destination $row.destination
        [IO.File]::Copy((Join-Path $Package $row.source),$to,$false)
        if((Get-Item -LiteralPath $to).Length -ne $row.bytes -or (Get-FileHash -LiteralPath $to).Hash -cne $row.sha256){throw 'Copied source differs; preserve partials'}
    }
}
$invocations=@()
if($Matrix -ceq 'entry'){
    Copy-Files $TestRoot $files
    foreach($name in @('bmx_playable_entry_tests','bmx_playable_main_tests')){$invocations+=[ordered]@{directory=$TestRoot;module=$name;suite=$name}}
}else{
    $flat=Join-Path $TestRoot 'flat';$quota=Join-Path $TestRoot 'quota-flat'
    $null=New-Item -ItemType Directory -Path $flat,$quota -ErrorAction Stop
    Copy-Files $flat $files
    Copy-Files $quota $files
    $alias=Join-Path $quota $plan.quota.destination
    [IO.File]::Copy((Join-Path $Package $plan.quota.source),$alias,$false)
    if((Get-FileHash -LiteralPath $alias).Hash -cne $plan.quota.sha256){throw 'Quota alias differs; preserve partials'}
    foreach($run in $plan.suites){$invocations+=[ordered]@{directory=(Join-Path $TestRoot $run.context);module=$run.invoked;suite=$run.suite;expected_cases=$run.expected_cases;expected_assertions=$run.expected_assertions}}
}
$result=[ordered]@{matrix=$Matrix;flat_files=$files.Count;quota_files=$(if($Matrix -ceq 'two-cycle'){55}else{0});destination=$TestRoot;source_admission='UNCHANGED_FALSE';executed=$false;invocations=$invocations}
[IO.File]::WriteAllText((Join-Path $TestRoot 'preparation.json'),($result|ConvertTo-Json -Depth 8),$utf)
$result|ConvertTo-Json -Depth 8 -Compress

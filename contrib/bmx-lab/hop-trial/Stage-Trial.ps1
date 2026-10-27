# Source-only artifact preparation. This script never imports Lua, runs tests or launches a game.
[CmdletBinding()]
param(
    [ValidateSet('Verify','Stage')][string]$Mode = 'Verify',
    [Parameter(Mandatory=$true)][string]$SourceRoot,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [switch]$ReviewedAdmission,
    [ValidateSet('P0','H1')][string]$Phase = 'P0',
    [string]$RunId = 'unreviewed',
    [string]$ReviewId = '',
    [switch]$IncludeTests
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$comparison = [StringComparison]::Ordinal
$pathComparison = [StringComparison]::OrdinalIgnoreCase
$planSha256 = 'EE88B7BB749AD581C4B3AB419C576196B641A3E8006CB681741DA92348830CF2'
$pinsSha256 = '529ED8E62B3791A4FF5811E85E3F156B970FFC830E7DD2C4F7AD79B58E68CA44'

function Assert-NoHold {
    foreach ($hold in @('C:\Users\Jeffr\Desktop\reskate\build\bmx\HID-HOLD',
                        'E:\RESKATE DEV\reskate\build\bmx\HID-HOLD')) {
        if (Test-Path -LiteralPath $hold) { throw "HID-HOLD active: $hold" }
    }
}
function Full-Path([string]$Value) {
    if ($Value -notmatch '^[A-Za-z]:[\\/]' -or $Value -match '[*?"<>|]' -or
        $Value.Substring(2).Contains(':')) { throw 'An ordinary absolute local drive path is required' }
    foreach ($part in ($Value.Substring(3) -split '[\\/]')) {
        if ($part -eq '.' -or $part -eq '..' -or $part -match '[. ]$') { throw 'Ambiguous path component' }
    }
    $full = [IO.Path]::GetFullPath($Value)
    if ($full.Length -le 3) { throw 'Drive roots are not source or artifact directories' }
    return $full.TrimEnd('\','/')
}
function Assert-NoReparse([string]$Path) {
    $cursor = $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse traversal refused: $cursor"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}
function Is-Within([string]$Candidate, [string]$Root) {
    return $Candidate.Equals($Root,$pathComparison) -or
        $Candidate.StartsWith($Root + '\',$pathComparison)
}
function Read-Bytes([string]$Path) {
    Assert-NoReparse $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file missing: $Path" }
    return ,([IO.File]::ReadAllBytes($Path))
}
function Digest([byte[]]$Bytes) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-','') }
    finally { $hash.Dispose() }
}
function Occurrences([string]$Text, [string]$Needle) {
    if (-not $Needle) { throw 'Empty exact-text declaration' }
    $count = 0
    $offset = 0
    while (($offset = $Text.IndexOf($Needle,$offset,$comparison)) -ge 0) {
        $count++
        $offset += $Needle.Length
    }
    return $count
}
function Exact-Declaration([string]$Text,[string]$Literal,[string]$Declaration,[string]$Label) {
    if ((Occurrences $Text $Literal) -ne 1 -or (Occurrences $Text $Declaration) -ne 1) {
        throw "Missing, duplicate or alternate declaration: $Label"
    }
}
function Local-Newlines([string]$Text,[string]$Value) {
    # Only declared insertions acquire the source file's newline convention.
    $crlf = [string][char]13 + [char]10
    if ($Text.Contains($crlf)) { return $Value.Replace([string][char]10,$crlf) }
    return $Value
}
function Json-Bytes($Value) {
    return ,($utf8.GetBytes(($Value | ConvertTo-Json -Depth 30) + [char]10))
}
function Assert-Relative([string]$Path) {
    if ($Path -notmatch '^(plugin/[a-z0-9_]+\.lua|[a-z0-9-]+\.json)$') {
        throw "Unexpected artifact path: $Path"
    }
}
function Add-File([string]$Path,[byte[]]$Bytes) {
    Assert-Relative $Path
    if ($expected.ContainsKey($Path)) { throw "Duplicate artifact path: $Path" }
    $expected.Add($Path,$Bytes)
}
function Add-Input([string]$Origin,[string]$Path,[byte[]]$Bytes) {
    $inputs.Add([ordered]@{origin=$Origin;path=$Path;bytes=$Bytes.Length;sha256=(Digest $Bytes)})
}
function Assert-OutputLocation([string]$Output,[string]$Root,[string]$Private) {
    Assert-NoReparse $Output
    if ((Is-Within $Output $Root) -or (Is-Within $Root $Output) -or
        (Is-Within $Output $Private) -or (Is-Within $Private $Output)) {
        throw 'Output/source overlap refused'
    }
    foreach ($part in ($Output -split '[\\/]')) {
        if ($part -match '^(mods?|plugins?|profiles?|steamapps|steamlibrary|build|release|debug|binaries|games?|skate|bmx streets)$') {
            throw "Game, deployment or build path refused: $part"
        }
    }
    $cursor = [IO.Path]::GetDirectoryName($Output)
    while ($cursor) {
        foreach ($marker in @('Skate.exe','ReSkateLauncher.exe','ReSkate.dll','reskate-plugin.json')) {
            if (Test-Path -LiteralPath (Join-Path $cursor $marker)) {
                throw "Game or plugin deployment ancestor refused: $cursor"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}
function Read-ArtifactFiles([string]$Root) {
    $found = [Collections.Generic.Dictionary[string,byte[]]]::new([StringComparer]::Ordinal)
    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($Root)
    while ($queue.Count) {
        $directory = $queue.Dequeue()
        Assert-NoReparse $directory
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse artifact refused: $($item.FullName)"
            }
            $relative = $item.FullName.Substring($Root.Length+1).Replace('\','/')
            if ($item.PSIsContainer) {
                if ($relative -cne 'plugin') { throw "Unexpected artifact directory: $relative" }
                $queue.Enqueue($item.FullName)
            } else {
                Assert-Relative $relative
                if ($found.ContainsKey($relative)) { throw "Duplicate artifact: $relative" }
                $found.Add($relative,(Read-Bytes $item.FullName))
            }
        }
    }
    return ,$found
}

Assert-NoHold
$root = Full-Path $SourceRoot
$private = Full-Path $PSScriptRoot
$output = Full-Path $OutputDirectory
Assert-NoReparse $root
Assert-NoReparse $private
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'SourceRoot must exist' }
Assert-OutputLocation $output $root $private
if ($RunId -cnotmatch '^[a-z0-9][a-z0-9_-]{0,31}$') { throw 'RunId is not a safe lowercase identifier' }
if ($ReviewedAdmission) {
    if ($RunId -ceq 'unreviewed' -or $ReviewId -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$') {
        throw 'Reviewed admission requires explicit safe non-default RunId and ReviewId'
    }
} elseif ($Phase -cne 'P0' -or $RunId -cne 'unreviewed' -or $ReviewId -ne '') {
    throw 'Closed copies require default P0/unreviewed identity and no ReviewId'
}
if ([IO.Path]::GetFileName($output) -cne "BMX_Hop_Trial_$RunId") {
    throw 'Output leaf must equal the declared fresh mod namespace'
}
if ($Mode -eq 'Stage') {
    if (Test-Path -LiteralPath $output) { throw 'Stage refuses every existing output path' }
    if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($output)) -PathType Container)) {
        throw 'Output parent must already exist'
    }
} elseif (-not (Test-Path -LiteralPath $output -PathType Container)) {
    throw 'Verify requires an existing artifact directory'
}

# The plan and canonical pins are review inputs, not output-supplied trust anchors.
$planBytes = Read-Bytes (Join-Path $private 'stage-plan.json')
if ((Digest $planBytes) -cne $planSha256) { throw 'Reviewed stage plan changed' }
$plan = $utf8.GetString($planBytes) | ConvertFrom-Json
$pinsBytes = Read-Bytes (Join-Path $private 'source-pins.json')
if ((Digest $pinsBytes) -cne $pinsSha256 -or $plan.source_pins_sha256 -cne $pinsSha256) {
    throw 'Frozen canonical source pins changed'
}
$pins = $utf8.GetString($pinsBytes) | ConvertFrom-Json
if ($pins.schema -ne 1 -or $pins.source_commit -cne '430b98c5' -or
    $pins.source_directory -cne 'contrib/bmx-lab/bmx-plugin' -or @($pins.files).Count -ne 59) {
    throw 'Unexpected canonical pin contract'
}
$canonicalRoot = Join-Path $root 'contrib\bmx-lab\bmx-plugin'
$canonicalPlugin = Join-Path $canonicalRoot 'plugin'
Assert-NoReparse $canonicalPlugin
if (-not (Test-Path -LiteralPath $canonicalPlugin -PathType Container)) { throw 'Canonical plugin directory missing' }
$expected = [Collections.Generic.Dictionary[string,byte[]]]::new([StringComparer]::Ordinal)
$inputs = [Collections.Generic.List[object]]::new()
$changes = [Collections.Generic.List[object]]::new()
$pinNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($pin in @($pins.files)) {
    $path = [string]$pin.path
    Assert-Relative $path
    if ($path -cnotmatch '^plugin/[a-z0-9_]+\.lua$' -or $path -cmatch '/main\.lua$|_tests\.lua$|fixture' -or
        -not $pinNames.Add($path) -or $pin.sha256 -cnotmatch '^[A-F0-9]{64}$') { throw 'Invalid or duplicate canonical pin' }
    $bytes = Read-Bytes (Join-Path $canonicalRoot $path)
    if ($bytes.Length -ne $pin.bytes -or (Digest $bytes) -cne $pin.sha256) { throw "Canonical source changed: $path" }
    Add-File $path $bytes
    Add-Input 'canonical' $path $bytes
}
$selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($item in @(Get-ChildItem -LiteralPath $canonicalPlugin -Force)) {
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Canonical reparse entry refused' }
    if ($item.PSIsContainer) { throw 'Canonical module inventory must remain flat' }
    if ($item.Extension -ieq '.lua' -and $item.Name -ine 'main.lua' -and
        $item.Name -inotmatch '_tests\.lua$' -and $item.Name -inotmatch 'fixture') {
        if (-not $selected.Add('plugin/'+$item.Name)) { throw 'Duplicate selected canonical module' }
    }
}
if ($selected.Count -ne 59 -or -not $selected.SetEquals($pinNames)) { throw 'Selected canonical inventory changed' }

# Validate every canonical transform even for closed copies.
foreach ($transform in @($plan.transforms)) {
    $beforeBytes = $expected[[string]$transform.path]
    $text = $utf8.GetString($beforeBytes)
    $before = Local-Newlines $text ([string]$transform.before)
    $after = Local-Newlines $text ([string]$transform.after)
    Exact-Declaration $text $before ([string]$transform.declaration) ([string]$transform.id)
    if ($transform.count -ne 1 -or (Occurrences $text $after) -ne 0) { throw "Alternate transform already present: $($transform.id)" }
    if ($ReviewedAdmission) { $expected[[string]$transform.path] = $utf8.GetBytes($text.Replace($before,$after)) }
    $changes.Add([ordered]@{id=$transform.id;path=$transform.path;applied=[bool]$ReviewedAdmission;
        replacements=([int][bool]$ReviewedAdmission);before_sha256=(Digest $beforeBytes);
        after_sha256=(Digest $expected[[string]$transform.path])})
}
foreach ($assertion in @($plan.unchanged_assertions)) {
    Exact-Declaration ($utf8.GetString($expected[[string]$assertion.path])) $assertion.text $assertion.declaration $assertion.text
}
foreach ($name in @($plan.private_modules)) {
    $path = 'plugin/'+$name
    $bytes = Read-Bytes (Join-Path $private $path)
    Add-File $path $bytes
    Add-Input 'private' $path $bytes
}
foreach ($name in @('manifest.json','reskate-plugin.json')) {
    $bytes = Read-Bytes (Join-Path $private $name)
    Add-File $name $bytes
    Add-Input 'private' $name $bytes
}
if ($IncludeTests) {
    foreach ($name in @($plan.optional_tests)) {
        $path = 'plugin/'+$name
        $bytes = Read-Bytes (Join-Path $private $path)
        Add-File $path $bytes
        Add-Input 'private-test' $path $bytes
    }
    # A lexical test seam around the exact entry bytes; never part of a runtime copy.
    $definition = $plan.test_fixture
    $body = $expected[[string]$definition.source]
    $prefix = $utf8.GetBytes([string]$definition.prefix)
    $suffix = $utf8.GetBytes([string]$definition.suffix)
    $fixture = [byte[]]::new($prefix.Length+$body.Length+$suffix.Length)
    [Buffer]::BlockCopy($prefix,0,$fixture,0,$prefix.Length)
    [Buffer]::BlockCopy($body,0,$fixture,$prefix.Length,$body.Length)
    [Buffer]::BlockCopy($suffix,0,$fixture,$prefix.Length+$body.Length,$suffix.Length)
    Add-File ([string]$definition.path) $fixture
    $changes.Add([ordered]@{id=$definition.id;path=$definition.path;applied=$true;generated=$true;
        source=$definition.source;source_bytes=$body.Length;before_sha256=(Digest $body);after_sha256=(Digest $fixture)})
}
$config = $utf8.GetString($expected['plugin/hop_config.lua'])
foreach ($literal in @('schema=1','admission_enabled=false','phase="P0"','run_id="unreviewed"',
    'source_commit="430b98c5"','slot=0','ride_window_ms=1500',
    'caps=table.freeze({force=6000,speed=3,torque=2000,vertical_speed=3})','hop_strength=.25','mass=106','max_hop_attempts=1')) {
    $declaration = $literal.Substring(0,$literal.IndexOf('=')+1)
    Exact-Declaration $config $literal $declaration "private config $declaration"
}
foreach ($pin in @($plan.private_immutable_pins)) {
    if (-not $expected.ContainsKey([string]$pin.path) -or
        (Digest $expected[[string]$pin.path]) -cne $pin.sha256) { throw "Reviewed private manifest changed: $($pin.path)" }
}
$pluginManifest = $utf8.GetString($expected['reskate-plugin.json']) | ConvertFrom-Json
$permissions = @('input','input.control','input.lease','input.capture','skater.read','skater.animation',
    'menu','storage','overlay','board','world.physics','world.physics.follow','world.entities','world.raycast')
if ($pluginManifest.api -ne 1 -or $pluginManifest.entry -cne 'plugin/main.lua' -or
    $pluginManifest.side -cne 'client' -or
    [string]::Join('|',@($pluginManifest.permissions)) -cne [string]::Join('|',$permissions)) {
    throw 'Private manifest permission/entry contract changed'
}
$manifest = $utf8.GetString($expected['manifest.json'])
Exact-Declaration $manifest '"name": "BMX_Hop_Trial_unreviewed"' '"name":' 'private package name'
foreach ($transform in @($plan.private_transforms)) {
    $path = [string]$transform.path
    $beforeBytes = $expected[$path]
    $text = $utf8.GetString($beforeBytes)
    $before = [string]$transform.before
    $after = ([string]$transform.after).Replace('<P0-or-H1>',$Phase).Replace('<safe-runid>',$RunId)
    if ((Occurrences $text $before) -ne 1) { throw "Private transform declaration changed: $($transform.id)" }
    if ($ReviewedAdmission) { $expected[$path] = $utf8.GetBytes($text.Replace($before,$after)) }
    $changes.Add([ordered]@{id=$transform.id;path=$path;applied=[bool]$ReviewedAdmission;
        replacements=([int][bool]$ReviewedAdmission);before_sha256=(Digest $beforeBytes);after_sha256=(Digest $expected[$path])})
}
Add-File 'source-pins.json' $pinsBytes
Add-File 'stage-plan.json' $planBytes
$report = [ordered]@{schema=1;source_commit='430b98c5';source_root=$root;private_root=$private;
    source_pins_sha256=$pinsSha256;stage_plan_sha256=$planSha256;reviewed_admission=[bool]$ReviewedAdmission;
    review_id=$ReviewId;run_id=$RunId;phase=$Phase;include_tests=[bool]$IncludeTests;
    qualification='No execution, native qualification, deployment or repeat-use authority is granted.';
    inputs=@($inputs.ToArray());transforms=@($changes.ToArray())}
Add-File 'transform-report.json' (Json-Bytes $report)
$inventory = [Collections.Generic.List[object]]::new()
foreach ($path in @($expected.Keys | Sort-Object -CaseSensitive)) {
    $bytes = $expected[$path]
    $inventory.Add([ordered]@{path=$path;bytes=$bytes.Length;sha256=(Digest $bytes)})
}
Add-File 'artifact-inventory.json' (Json-Bytes ([ordered]@{schema=1;
    self_excluded='artifact-inventory.json';files=@($inventory.ToArray())}))

# Everything, including optional test dependencies, is in memory before this branch.
Assert-NoHold
Assert-OutputLocation $output $root $private
if ($Mode -eq 'Verify') {
    $actual = Read-ArtifactFiles $output
    if ($actual.Count -ne $expected.Count) { throw 'Artifact file count changed' }
    foreach ($path in $expected.Keys) {
        if (-not $actual.ContainsKey($path) -or $actual[$path].Length -ne $expected[$path].Length -or
            (Digest $actual[$path]) -cne (Digest $expected[$path])) { throw "Artifact missing or changed: $path" }
    }
} else {
    # No overwrite, rollback deletion, or reuse of a partly-created directory.
    if (Test-Path -LiteralPath $output) { throw 'Output appeared during preflight' }
    $null = New-Item -ItemType Directory -Path $output -ErrorAction Stop
    Assert-NoReparse $output
    $null = New-Item -ItemType Directory -Path (Join-Path $output 'plugin') -ErrorAction Stop
    foreach ($path in @($expected.Keys | Sort-Object -CaseSensitive)) {
        Assert-NoHold
        $target = Join-Path $output $path
        Assert-NoReparse $target
        if (-not (Is-Within $target $output)) { throw 'Artifact escaped output' }
        $stream = [IO.FileStream]::new($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write($expected[$path],0,$expected[$path].Length); $stream.Flush() }
        finally { $stream.Dispose() }
    }
}
if ($Mode -eq 'Stage') {
    $written = Read-ArtifactFiles $output
    if ($written.Count -ne $expected.Count) { throw 'Written artifact inventory differs' }
    foreach ($path in $expected.Keys) {
        if (-not $written.ContainsKey($path) -or $written[$path].Length -ne $expected[$path].Length -or
            (Digest $written[$path]) -cne (Digest $expected[$path])) { throw "Written artifact differs: $path" }
    }
}
[pscustomobject]@{mode=$Mode;output=$output;files=$expected.Count;reviewed_admission=[bool]$ReviewedAdmission;
    phase=$Phase;run_id=$RunId;include_tests=[bool]$IncludeTests;verified=$true}

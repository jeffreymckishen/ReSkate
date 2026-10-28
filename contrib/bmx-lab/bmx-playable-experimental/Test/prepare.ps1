param([Parameter(Mandatory)][string]$TestRoot)
# File preparation only. Root owns the separate offline execution grant and runner.
$ErrorActionPreference='Stop'
$Package=Split-Path -Parent $PSScriptRoot
if(-not [IO.Path]::IsPathFullyQualified($TestRoot) -or [IO.Path]::GetFullPath($TestRoot) -cne $TestRoot -or (Split-Path -Parent $TestRoot) -cne 'E:\RESKATE DEV' -or (Split-Path -Leaf $TestRoot) -notmatch '^bmx-playable-tests-[a-z0-9-]{1,64}$' -or (Test-Path -LiteralPath $TestRoot)){throw 'New direct E bmx-playable-tests-* directory required'}
foreach($root in @($Package,$TestRoot)){$p=$root;while($p){if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse path refused'};$next=[IO.Path]::GetDirectoryName($p);if($next -ceq $p){break};$p=$next}}
$files=@(
 @{source='plugin\bmx_playable_entry.lua';destination='bmx_playable_entry.lua';sha256='DB50098F1A406E3CCD94147464C603B735F587CFE96AAE58B20345E3B32E2D37'},
 @{source='plugin\ride_r1_record.lua';destination='ride_r1_record.lua';sha256='295F18623F6809FC97419A24DB283013F9E3D2B530A989A70A09DA8720F13577'},
 @{source='Test\bmx_playable_entry_tests.lua';destination='bmx_playable_entry_tests.lua';sha256='9EB27D0713DF4B693D5300B0E04FE3BB6BDB02EA91544940F62287E72A077D11'},
 @{source='Test\playable_main_fixture.lua';destination='playable_main_fixture.lua';sha256='583E6243C84F87D546572B352BA4FD97D0B2D2A0DD240B7F74434632528BCA9D'},
 @{source='Test\bmx_playable_main_tests.lua';destination='bmx_playable_main_tests.lua';sha256='E29F35B4FEF9F346943A55FF9F8CC5962F2BC385A860C46D81886064BCC80133'},
 @{source='plugin\force_math.lua';destination='force_math.lua';sha256='3690E55D0B3330889C70EFD8D8EABF24CF64DC6EC28BBE8FB9C415DD82C2E1DC'},
 @{source='plugin\bike_geometry.lua';destination='bike_geometry.lua';sha256='4FA05633F54D0A2026B6CAC128FC61EF12A9E4B864B4A9758350B330100DBA9C'}
)
foreach($row in $files){if((Get-FileHash -LiteralPath (Join-Path $Package $row.source)).Hash -cne $row.sha256){throw 'Exact tested unit source changed'}}
$main=Join-Path $Package 'plugin\main.lua'
if((Get-FileHash -LiteralPath $main).Hash -cne '97E74EC1497B02CD5F14DFA8A7425577142083D9B54B7B6E2569DD3A18233012'){throw 'Closed main changed'}
$utf=[Text.UTF8Encoding]::new($false)
$expected=$utf.GetBytes("return function(reskate, require)`n"+[IO.File]::ReadAllText($main)+"`nend`n")
if([Convert]::ToBase64String($expected) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'playable_main_fixture.lua')))){throw 'Test wrapper is not the exact closed main body'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
foreach($row in $files){$to=Join-Path $TestRoot $row.destination;[IO.File]::Copy((Join-Path $Package $row.source),$to,$false);if((Get-FileHash -LiteralPath $to).Hash -cne $row.sha256){throw 'Copied unit differs; preserve partials'}}
[ordered]@{files=7;destination=$TestRoot;source_admission='UNCHANGED_FALSE';executed=$false;modules=@('bmx_playable_entry_tests','bmx_playable_main_tests')}|ConvertTo-Json -Compress
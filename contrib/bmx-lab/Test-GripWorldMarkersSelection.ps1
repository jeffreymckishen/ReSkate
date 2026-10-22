$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'StationaryGripEvidence.ps1')
$script:checks=0
function Require([bool]$Pass,[string]$Label){if(-not $Pass){throw $Label};++$script:checks}
function Reject([scriptblock]$Action,[string]$Label){$refused=$false;try{& $Action}catch{$refused=$true};Require $refused $Label}
$repo='C:\Users\Jeffr\Desktop\reskate';$profile='bmx-user-data-grip-stationary-test'
$good=@{Ride=$true;NativeChassis=$true;RiderPoseMode='Default';MotionBasisMode='Default';BoardHandoffMode='None'}
Assert-BmxGripWorldMarkersSelection $true $true $repo $profile $good @{}
Require $true 'exact private stationary selection allowed'
Assert-BmxGripWorldMarkersSelection $false $false 'unused' 'unused' @{} @{}
Require $true 'unselected helper remains inert'
Reject {Assert-BmxGripWorldMarkersSelection $true $false $repo $profile $good @{}} 'stationary selector required'
foreach($key in @('ForearmRepairCandidate','LongRideTrace','HumanNativeSwitch','GripProbe','RampRideTest','ProfilePerformance','UseSteam')){
    $bad=$good.Clone();$bad[$key]=$true
    Reject {Assert-BmxGripWorldMarkersSelection $true $true $repo $profile $bad @{}} ('conflicting '+$key)
}
foreach($key in @('Ride','NativeChassis')){
    $bad=$good.Clone();$bad[$key]=$false
    Reject {Assert-BmxGripWorldMarkersSelection $true $true $repo $profile $bad @{}} ('required '+$key)
}
foreach($pair in @(@('RiderPoseMode','RenderOnly'),@('MotionBasisMode','PreserveSuppliedBasis'),@('BoardHandoffMode','NativeOnly'),
    @('ImpactTest','side'),@('Map','MPR'),@('CaptureGateDirectory','C:\capture'),@('CaptureGateNonce','a'))){
    $bad=$good.Clone();$bad[$pair[0]]=$pair[1]
    Reject {Assert-BmxGripWorldMarkersSelection $true $true $repo $profile $bad @{}} ('nondefault '+$pair[0])
}
foreach($wrong in @('bmx-user-data','bmx-user-data-forearm-repair-test','BMX-user-data-grip-stationary-test')){
    Reject {Assert-BmxGripWorldMarkersSelection $true $true $repo $wrong $good @{}} 'foreign profile refused'
}
Reject {Assert-BmxGripWorldMarkersSelection $true $true ($repo+'-other') $profile $good @{}} 'foreign workspace refused'
foreach($key in @('RESKATE_BMX_NATIVE_COUPLED','RESKATE_BMX_COUPLED_RIDE','RESKATE_BMX_COUPLED_CONTROLLER_TRIAL',
    'RESKATE_BMX_COUPLED_FORCE_PROBE','RESKATE_BMX_COUPLED_CALIBRATION','RESKATE_BMX_COUPLED_POSTURE',
    'RESKATE_BMX_PROP_TRANSFORM_TRACE','RESKATE_BMX_OBSERVED_POSTURE')){
    $inherited=@{};$inherited[$key]='1'
    Reject {Assert-BmxGripWorldMarkersSelection $true $true $repo $profile $good $inherited} ('inherited conflict '+$key)
}
$envMap=@{RESKATE_BMX_GRIP_WORLD_MARKERS='1';Untouched='keep'}
Set-BmxGripWorldMarkersEnvironment $envMap $false
Require ($envMap.RESKATE_BMX_GRIP_WORLD_MARKERS -ceq '0' -and $envMap.Untouched -ceq 'keep') 'ordinary launch clears inherited marker flag only'
Set-BmxGripWorldMarkersEnvironment $envMap $true
Require ($envMap.RESKATE_BMX_GRIP_WORLD_MARKERS -ceq '1') 'explicit flag selected without arming'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Start-BmxGame.ps1'),[ref]$tokens,[ref]$errors)
Require ($errors.Count -eq 0) 'launcher parses'
Require ($ast.ParamBlock.Parameters.Name.VariablePath.UserPath -contains 'GripWorldMarkers') 'explicit marker switch declared'
$commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true))
$asserts=@($commands|Where-Object {$_.GetCommandName() -ceq 'Assert-BmxGripWorldMarkersSelection'})
$sets=@($commands|Where-Object {$_.GetCommandName() -ceq 'Set-BmxGripWorldMarkersEnvironment'})
Require ($asserts.Count -eq 1 -and $sets.Count -eq 1) 'selection and clearing integrated once'
$firstLaunch=@($commands|Where-Object {$_.GetCommandName() -ceq 'Copy-Item'}|Select-Object -First 1)
Require ($firstLaunch.Count -eq 1 -and $asserts[0].Extent.StartOffset -lt $firstLaunch[0].Extent.StartOffset) 'marker validation precedes artifact/profile mutation'
Write-Output "PASS $script:checks world grip marker launch checks; no game, profile, native or input action."

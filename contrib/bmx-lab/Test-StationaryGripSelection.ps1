#requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'StationaryGripEvidence.ps1')
$script:checks=0
function Require($Value,[string]$Why){$script:checks++;if(-not $Value){throw $Why}}
function Reject([scriptblock]$Body,[string]$Why){$rejected=$false;try{& $Body|Out-Null}catch{$rejected=$true};Require $rejected $Why}
$repo='C:\Users\Jeffr\Desktop\reskate';$profile='bmx-user-data-grip-stationary-test'
$good=@{Ride=$true;NativeChassis=$true;RiderPoseMode='Default';MotionBasisMode='Default';BoardHandoffMode='None'}
Assert-BmxStationaryGripSelection $true $repo $profile $good @{};Require $true 'exact explicit human stationary selection accepted'
Assert-BmxStationaryGripSelection $false 'elsewhere' 'ordinary' @{} @{};Require $true 'ordinary off selection unchanged'
foreach($key in @('Ride','NativeChassis')){$bad=$good.Clone();$bad[$key]=$false
    Reject {Assert-BmxStationaryGripSelection $true $repo $profile $bad @{}} ('explicit '+$key+' required')}
foreach($key in @('GripProbe','GripRequestHud','HumanNativeSwitch','NativeInputHandoff','NativeBoardControl','DeferNativeBoardArm',
    'UnattendedTest','SwitchTest','QuickSwitchTest','TrickTest','RampTest','RampRideTest','ChassisProbe','ChassisPulse','ChassisCalibration',
    'IntentActivation','ImpactRecovery','GetUpPulse','PostFallRemountTest','PhaseProbe','FirstMountProducerProbe','IntentObserver',
    'BindingObserver','CatalogTest','NativeFallTest','ProfilePerformance','SmokeTest','NativeTestSkater','NativeStartupDelay',
    'NativePlayerStartup','NativeObserveOnly','UseSteam','UseLooseFiles','DisableNativeLocalProfile','ApproachWitness','ApproachNormal',
    'ContactCompliance','LandingContactCompliance')){
    $bad=$good.Clone();$bad[$key]=$true;Reject {Assert-BmxStationaryGripSelection $true $repo $profile $bad @{}} ('conflicting '+$key+' rejected')
}
foreach($pair in @(@('RiderPoseMode','RenderOnly'),@('MotionBasisMode','PreserveSuppliedBasis'),@('BoardHandoffMode','NativeOnly'),
    @('ImpactTest','side'),@('Map','MPR'),@('CaptureGateDirectory','C:\capture'),@('CaptureGateNonce','11111111111111111111111111111111'))){
    $bad=$good.Clone();$bad[$pair[0]]=$pair[1];Reject {Assert-BmxStationaryGripSelection $true $repo $profile $bad @{}} ('non-default '+$pair[0]+' rejected')
}
foreach($wrong in @('bmx-user-data','bmx-user-data-ramp-test','bmx-user-data-human-native-test','BMX-user-data-grip-stationary-test')){
    Reject {Assert-BmxStationaryGripSelection $true $repo $wrong $good @{}} 'other profile rejected'
}
Reject {Assert-BmxStationaryGripSelection $true ($repo+'-other') $profile $good @{}} 'other workspace rejected'
foreach($key in @('RESKATE_BMX_NATIVE_COUPLED','RESKATE_BMX_COUPLED_RIDE','RESKATE_BMX_COUPLED_CONTROLLER_TRIAL',
    'RESKATE_BMX_COUPLED_FORCE_PROBE','RESKATE_BMX_COUPLED_CALIBRATION','RESKATE_BMX_COUPLED_POSTURE',
    'RESKATE_BMX_PROP_TRANSFORM_TRACE','RESKATE_BMX_OBSERVED_POSTURE')){
    foreach($value in @('1','true','unexpected')){$inherited=@{};$inherited[$key]=$value
        Reject {Assert-BmxStationaryGripSelection $true $repo $profile $good $inherited} ('inherited '+$key+'='+$value+' rejected')}
    $inherited=@{};$inherited[$key]='0';Assert-BmxStationaryGripSelection $true $repo $profile $good $inherited
    Require $true ('explicit zero '+$key+' compatible')
}
$environment=@{RESKATE_BMX_GRIP_STATIONARY_PROBE='1';Untouched='value'}
Set-BmxStationaryGripEnvironment $environment $false
Require ($environment.RESKATE_BMX_GRIP_STATIONARY_PROBE -ceq '0' -and $environment.Untouched -ceq 'value') 'ordinary launch clears inherited stationary selector only'
Set-BmxStationaryGripEnvironment $environment $true
Require ($environment.RESKATE_BMX_GRIP_STATIONARY_PROBE -ceq '1') 'explicit selected launch writes stationary selector'
$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Start-BmxGame.ps1'),[ref]$tokens,[ref]$errors)
Require ($errors.Count -eq 0) 'dedicated selector integration parses without any launch'
Write-Output "PASS $script:checks stationary grip selection checks; no game, profile or input action performed."

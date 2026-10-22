$ErrorActionPreference='Stop'
# Execute only the actual parameter block, two rejection guards and environment
# assignment. The launcher body, filesystem, process start and HID never run.
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Start-BmxGame.ps1'),[ref]$tokens,[ref]$errors)
if($errors){throw 'Launcher parse failed'}
$guards=@($ast.EndBlock.Statements|Where-Object {$_.Extent.Text.StartsWith('if ($LongRideTrace -and') -or $_.Extent.Text.StartsWith('if ($HumanNativeSwitch -and')})
if($guards.Count -ne 2){throw 'Missing actual private launch guards'}
$assignment=@($ast.EndBlock.Statements|Where-Object {$_.Extent.Text.StartsWith('$start.Environment[''RESKATE_BMX_LONG_RIDE_TRACE''] =')})
if($assignment.Count -ne 1){throw 'Long trace selector must be overwritten exactly once'}
$body=$ast.ParamBlock.Extent.Text+"`n"+($guards.Extent.Text -join "`n")+"`n"+@'
$start=[Diagnostics.ProcessStartInfo]::new()
$start.Environment['RESKATE_BMX_LONG_RIDE_TRACE']='1'
'@+"`n"+$assignment[0].Extent.Text+"`n"+'$start.Environment[''RESKATE_BMX_LONG_RIDE_TRACE'']'
$select=[scriptblock]::Create($body)
$valid=@{LongRideTrace=$true;HumanNativeSwitch=$true;Ride=$true;NativeChassis=$true;ProfileName='bmx-user-data-human-native-test'}
if((& $select @valid) -cne '1'){throw 'Exact explicit long trace refused'}
$checks=1
foreach($missing in @('HumanNativeSwitch','Ride','NativeChassis')){
    $bad=$valid.Clone();$bad.Remove($missing);$rejected=$false
    try{& $select @bad|Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw "Missing $missing accepted"};++$checks
}
foreach($profile in @('bmx-user-data','bmx-user-data-working-profile','bmx-user-data-chassis-probe','bmx-user-data-human-native-test-extra','BMX-USER-DATA-HUMAN-NATIVE-TEST')){
    $bad=$valid.Clone();$bad.ProfileName=$profile;$rejected=$false
    try{& $select @bad|Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw "Invalid profile $profile accepted"};++$checks
}
foreach($conflict in @('UnattendedTest','SwitchTest','QuickSwitchTest','NativeInputHandoff','NativeBoardControl','DeferNativeBoardArm','RampTest','RampRideTest','ChassisProbe','ChassisPulse','ChassisCalibration','SmokeTest','TrickTest','NativeObserveOnly','NativeFallTest','IntentActivation','ImpactRecovery','GetUpPulse','PostFallRemountTest','PhaseProbe','FirstMountProducerProbe','StationaryGripProbe','GripProbe','GripRequestHud','ApproachWitness','ApproachNormal','ContactCompliance','LandingContactCompliance','IntentObserver','BindingObserver','CatalogTest','NativeTestSkater','NativeStartupDelay','NativePlayerStartup','UseSteam','UseLooseFiles','DisableNativeLocalProfile','ForearmRepairCandidate','ProfilePerformance')){
    $bad=$valid.Clone();$bad[$conflict]=$true;$rejected=$false
    try{& $select @bad|Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw "Conflicting $conflict accepted"};++$checks
}
foreach($pair in @(@('BoardHandoffMode','QuickSwitch'),@('RiderPoseMode','RenderOnly'),@('MotionBasisMode','PreserveSuppliedBasis'),@('ImpactTest','side'),@('Map','different'))){
    $bad=$valid.Clone();$bad[$pair[0]]=$pair[1];$rejected=$false
    try{& $select @bad|Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw "Conflicting $($pair[0]) accepted"};++$checks
}
foreach($ordinary in @(@{},@{Ride=$true;NativeChassis=$true},@{HumanNativeSwitch=$true;Ride=$true;NativeChassis=$true;ProfileName='bmx-user-data-human-native-test'})){
    if((& $select @ordinary) -cne '0'){throw 'Inherited long trace selector leaked into an unselected launch'};++$checks
}
Write-Output "Long ride trace selection: $checks source-derived cases passed; no launch/HID."

# Data-only selection. Dot-sourcing does not launch, arm, write a profile, or change input.
function Assert-BmxStationaryGripSelection {
    param([bool]$Selected,[string]$RepoRoot,[string]$ProfileName,[hashtable]$Options=@{},[hashtable]$InheritedEnvironment=@{})
    if(-not $Selected){return}
    if(-not [IO.Path]::GetFullPath($RepoRoot).Equals('C:\Users\Jeffr\Desktop\reskate',[StringComparison]::OrdinalIgnoreCase) -or
       $ProfileName -cne 'bmx-user-data-grip-stationary-test' -or -not $Options['Ride'] -or -not $Options['NativeChassis']){
        throw 'StationaryGripProbe requires explicit Ride NativeChassis in the exact private stationary workspace/profile.'
    }
    foreach($key in @('GripProbe','GripRequestHud','HumanNativeSwitch','NativeInputHandoff','NativeBoardControl','DeferNativeBoardArm',
        'UnattendedTest','SwitchTest','QuickSwitchTest','TrickTest','RampTest','RampRideTest','ChassisProbe','ChassisPulse','ChassisCalibration',
        'IntentActivation','ImpactRecovery','GetUpPulse','PostFallRemountTest','PhaseProbe','FirstMountProducerProbe','IntentObserver',
        'BindingObserver','CatalogTest','NativeFallTest','ProfilePerformance','SmokeTest','NativeTestSkater','NativeStartupDelay',
        'NativePlayerStartup','NativeObserveOnly','UseSteam','UseLooseFiles','DisableNativeLocalProfile','ApproachWitness','ApproachNormal',
        'ContactCompliance','LandingContactCompliance')){
        if($Options[$key]){throw ('StationaryGripProbe conflicts with '+$key)}
    }
    foreach($key in @('RiderPoseMode','MotionBasisMode')){
        if($Options[$key] -cne 'Default'){throw ('StationaryGripProbe requires Default '+$key)}
    }
    if($Options['BoardHandoffMode'] -cne 'None' -or $Options['ImpactTest'] -or $Options['Map'] -or
       $Options['CaptureGateDirectory'] -or $Options['CaptureGateNonce']){
        throw 'StationaryGripProbe requires normal MPR startup without board, impact, custom map or capture-gate selection.'
    }
    foreach($key in @('RESKATE_BMX_NATIVE_COUPLED','RESKATE_BMX_COUPLED_RIDE','RESKATE_BMX_COUPLED_CONTROLLER_TRIAL',
        'RESKATE_BMX_COUPLED_FORCE_PROBE','RESKATE_BMX_COUPLED_CALIBRATION','RESKATE_BMX_COUPLED_POSTURE',
        'RESKATE_BMX_PROP_TRANSFORM_TRACE','RESKATE_BMX_OBSERVED_POSTURE')){
        $value=[string]$InheritedEnvironment[$key]
        if($value -and $value -cne '0'){throw ('StationaryGripProbe conflicts with inherited '+$key)}
    }
}
function Set-BmxStationaryGripEnvironment {
    param($Environment,[bool]$Selected)
    # Every launch clears inherited selection unless explicitly validated above.
    $Environment['RESKATE_BMX_GRIP_STATIONARY_PROBE']=$(if($Selected){'1'}else{'0'})
}

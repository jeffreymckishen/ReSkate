#requires -Version 7.5
# Fake process/clock/files only. Compiles interop declarations without invoking
# any native API, opening a process, terminating a process or sending input.
param([Parameter(Mandatory)][string]$FixtureParent)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Watch-BmxOwnedTrial.ps1')
$script:checks=0
function Check([bool]$Value,[string]$Reason){++$script:checks;if(-not $Value){throw $Reason}}
function Reject([scriptblock]$Action,[string]$Pattern){
    $errorText=$null;try{& $Action|Out-Null}catch{$errorText=$_.Exception.Message}
    Check ($null -ne $errorText -and $errorText -match $Pattern) ('Expected refusal '+$Pattern+'; observed '+$errorText)
}

function Invoke-FakeWatchdog {
    param([double]$Age=0,[double]$NaturalExit=[double]::PositiveInfinity,[double]$ExitDelay=0,
        [string]$Fault='',[double]$FaultAt=0)
    $created=[DateTime]::Parse('2026-10-22T12:00:00.1234567Z',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $fakeOwner=[pscustomobject]@{process_id=1234;creation_filetime=$created.ToFileTimeUtc();created_utc=$created;
        game_exe='C:\Users\Jeffr\Desktop\reskate\build\bmx-game\Skate.exe';runtime_path='C:\Users\Jeffr\Desktop\reskate\build\bmx-game\ReSkate.dll'}
    $state=[pscustomobject]@{now=0.0;opened=0;closed=0;terminations=0;full=0;files=0;ready=0;exit_at=$NaturalExit;observations=0}
    $fakeHandle=[pscustomobject]@{id='held-original-process-object'}
    $result=Invoke-BmxWatchdogCore $fakeOwner 60 `
        -Open {param($o) Check ($o -eq $fakeOwner) 'Open received wrong owner';++$state.opened;return $fakeHandle} `
        -Observe {param($h,$full,$exitOnly)
            Check ([object]::ReferenceEquals($h,$fakeHandle)) 'A fresh PID lookup replaced the held handle'
            if($exitOnly){Check ($state.terminations -eq 1 -and -not $full) 'Exit-only observation preceded final binding/termination attempt'}
            if($Fault -eq 'image-read' -and -not $exitOnly){throw 'fake live process image read failed'}
            if($Fault -eq 'pending-image' -and $state.terminations -gt 0 -and -not $exitOnly){throw 'fake terminating process image unavailable'}
            ++$state.observations;if($full){++$state.full}
            $value=[pscustomobject]@{available=$true;running=($state.now -lt $state.exit_at);creation_filetime=$fakeOwner.creation_filetime;
                image_path=$fakeOwner.game_exe;runtime_loaded=$true}
            if($state.now -ge $FaultAt) {
                switch($Fault) {
                    'creation' {$value.creation_filetime++}
                    'image' {$value.image_path='C:\unrelated\Skate.exe'}
                    'runtime' {if($full){$value.runtime_loaded=$false}}
                    'unavailable' {$value.available=$false}
                }
            }
            if($exitOnly){$value.image_path='';$value.runtime_loaded=$false}
            return $value
        } `
        -VerifyFiles {param($o) ++$state.files;if($Fault -eq 'files' -and $state.now -ge $FaultAt){throw 'fake runtime hash changed'}} `
        -Terminate {param($h,$o)
            Check ([object]::ReferenceEquals($h,$fakeHandle)) 'Termination used a new PID lookup'
            ++$state.terminations;$state.exit_at=$state.now+$ExitDelay;return $Fault -ne 'terminate-exited'
        } `
        -Close {param($h) Check ([object]::ReferenceEquals($h,$fakeHandle)) 'Closed wrong handle';++$state.closed;if($Fault -eq 'close'){throw 'fake close failure'}} `
        -Now {$state.now} -UtcNow {$created.AddSeconds($Age)} `
        -Sleep {param($seconds) $state.now+=$seconds;if($Fault -eq 'clock' -and $state.now -ge $FaultAt){$state.now=-1.0}} `
        -Ready {param($o,$deadline) ++$state.ready;if($Fault -eq 'ready'){throw 'fake ready publication failure'};Check ($deadline -eq [Math]::Max(0,60-$Age)) 'Deadline failed to include process age'}
    return [pscustomobject]@{result=$result;state=$state}
}

$normal=Invoke-FakeWatchdog -NaturalExit 3
Check ($normal.result.outcome -ceq 'normal_exit' -and $normal.result.absence_verified) 'Natural exit was not independently observed'
Check ($normal.result.absence_observations -eq 2 -and $normal.state.now -ge 3.1) 'Natural exit needs two separated absence samples'
Check ($normal.state.terminations -eq 0 -and $normal.state.closed -eq 1) 'Natural exit terminated a process or leaked handle'
Check ($normal.result.guardian_succeeded) 'Successful normal shutdown failed guardian acceptance'
Check (-not $normal.result.controller_input_sent -and -not $normal.result.game_launched -and $null -eq $normal.result.trial_passed) 'Guardian falsely claimed controller/gameplay results'

$deadline=Invoke-FakeWatchdog
Check ($deadline.result.outcome -ceq 'deadline_terminated' -and $deadline.result.absence_verified) 'Deadline failed to close the owned fake process'
Check ($deadline.state.terminations -eq 1 -and $deadline.state.closed -eq 1) 'Deadline must terminate the held handle once and close it'
Check ($deadline.state.full -eq 2 -and $deadline.state.files -eq 2 -and $deadline.state.ready -eq 1) 'Deadline did not revalidate full runtime/file binding'
Check ($deadline.state.now -ge 60.1 -and $deadline.state.now -lt 60.3) 'Watchdog deadline drifted from60seconds'
Check ($deadline.result.guardian_succeeded) 'Verified deadline shutdown failed guardian acceptance'
$racedTermination=Invoke-FakeWatchdog -Fault terminate-exited
Check ($racedTermination.result.outcome -ceq 'exited_at_deadline' -and $racedTermination.result.absence_verified -and $racedTermination.result.guardian_succeeded) 'Natural exit racing termination failed separate exit verification'
Check ($racedTermination.result.termination_requested -and -not $racedTermination.result.termination_accepted -and $racedTermination.result.absence_observations -eq 2) 'Natural exit race falsely claimed accepted termination or omitted two observations'

$aged=Invoke-FakeWatchdog -Age 50
Check ($aged.state.now -ge 10.1 -and $aged.state.now -lt 10.3 -and $aged.state.terminations -eq 1) 'Late arming extended the process wall lifetime'
$expired=Invoke-FakeWatchdog -Age 61
Check ($expired.result.deadline_reached -and $expired.state.terminations -eq 1 -and $expired.state.ready -eq 0) 'Already expired receipt must close immediately without publishing ready'
$future=Invoke-FakeWatchdog -Age -3
Check ($future.result.outcome -ceq 'refused' -and $future.state.opened -eq 0 -and $future.state.terminations -eq 0) 'Future receipt reached a process operation'

$delayed=Invoke-FakeWatchdog -ExitDelay 2
Check ($delayed.result.absence_verified -and $delayed.state.now -ge 62.1 -and $delayed.state.now -lt 62.4) 'Asynchronous termination exit delay was not awaited'
Check ($delayed.state.terminations -eq 1) 'Exit delay triggered a second termination'
$pendingImage=Invoke-FakeWatchdog -Fault pending-image -ExitDelay 2
Check ($pendingImage.result.guardian_succeeded -and $pendingImage.result.absence_observations -eq 2 -and $pendingImage.state.now -ge 62.1) 'Pending exit image loss prevented held-handle completion'
$liveImageFailure=Invoke-FakeWatchdog -Fault image-read
Check (-not $liveImageFailure.result.ready_published -and -not $liveImageFailure.result.guardian_succeeded -and $liveImageFailure.state.terminations -eq 0) 'Live image failure before deadline was treated as exit-only'
foreach($fault in @('creation','unavailable')) {
    $exitMismatch=Invoke-FakeWatchdog -Fault $fault -FaultAt 61 -ExitDelay 2
    Check (-not $exitMismatch.result.guardian_succeeded -and -not $exitMismatch.result.absence_verified -and $exitMismatch.state.terminations -eq 1) ('Exit-only identity failure was accepted: '+$fault)
}
$stuck=Invoke-FakeWatchdog -ExitDelay 30
Check ($stuck.result.outcome -ceq 'deadline_exit_unverified' -and -not $stuck.result.absence_verified) 'Never-exiting process received a false absence claim'
Check ($stuck.state.now -ge 70 -and $stuck.state.now -lt 70.3 -and $stuck.state.terminations -eq 1) 'Exit grace is unbounded or repeated termination occurred'

foreach($fault in @('creation','image','runtime','unavailable','files')) {
    foreach($at in @(0,60)) {
        $mismatch=Invoke-FakeWatchdog -Fault $fault -FaultAt $at
        Check ($mismatch.result.outcome -ceq 'refused' -and $mismatch.state.terminations -eq 0) ('Identity/runtime mismatch still terminated: '+$fault+'/'+$at)
        Check (-not $mismatch.result.absence_verified -and $mismatch.state.closed -eq 1) ('Mismatch claimed exit or leaked handle: '+$fault)
    }
}
$reversed=Invoke-FakeWatchdog -Fault clock -FaultAt 1
Check ($reversed.result.outcome -ceq 'refused' -and $reversed.state.terminations -eq 0 -and $reversed.state.closed -eq 1) 'Clock reversal authorized termination'
$readyFailure=Invoke-FakeWatchdog -Fault ready
Check (-not $readyFailure.result.ready_published -and -not $readyFailure.result.guardian_succeeded -and $readyFailure.state.terminations -eq 0 -and $readyFailure.state.closed -eq 1) 'Failed ready publication still armed or authorized process termination'
$closeFailure=Invoke-FakeWatchdog -Fault close -NaturalExit 1
Check ($closeFailure.result.absence_verified -and -not $closeFailure.result.guardian_succeeded -and $closeFailure.result.issue -match 'close failed') 'Close failure falsely returned a successful guardian result'
Reject {Invoke-BmxWatchdogCore -LimitSeconds 59} 'range|greater|less|60'
Reject {Invoke-BmxWatchdogCore -LimitSeconds 601} 'range|greater|less|600'

# Keep the production guardian's exact installation guard unchanged. File tests
# use one disposable helper copy with only its evidence-root literal adapted.
if(-not [IO.Path]::IsPathFullyQualified($FixtureParent)){throw 'An absolute binary fixture parent is required.'}
$base=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($FixtureParent))
if($base -ieq [IO.Path]::GetPathRoot($base) -or $base -ieq 'C:\Users\Jeffr\Desktop' -or $base.StartsWith('C:\Users\Jeffr\Desktop\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture parent must be outside drive roots and the Desktop.'}
$parent=Get-Item -LiteralPath $base -ErrorAction Stop
if($parent -isnot [IO.DirectoryInfo]){throw 'Fixture parent must be an existing directory.'}
for($cursor=$parent;$null -ne $cursor;$cursor=$cursor.Parent){
    if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Fixture parent refuses reparse ancestors.'}
}
$guardian=Join-Path $PSScriptRoot 'Watch-BmxOwnedTrial.ps1'
$guardianHash=(Get-FileHash -LiteralPath $guardian -Algorithm SHA256).Hash
$guardianText=[IO.File]::ReadAllText($guardian)
$rootLiteral='$root=''C:\Users\Jeffr\Desktop\reskate\build\bmx'''
Check ([regex]::Matches($guardianText,[regex]::Escape($rootLiteral)).Count -eq 1) 'Expected exactly one production evidence-root binding'
$fixture=Join-Path $base ('watchdog-fixtures-'+[Guid]::NewGuid().ToString('N'))
if(Test-Path -LiteralPath $fixture){throw 'Fresh watchdog fixture already exists.'}
[IO.Directory]::CreateDirectory($fixture)|Out-Null
try {
    Reject {Assert-BmxWatchdogPath $fixture -Directory} 'beneath'
    $fixtureGuardian=Join-Path $fixture 'Watch-BmxOwnedTrial.ps1'
    $fixtureText=$guardianText.Replace($rootLiteral,('$root='''+$base.Replace("'","''")+''''))
    [IO.File]::WriteAllText($fixtureGuardian,$fixtureText,[Text.UTF8Encoding]::new($false))
    . $fixtureGuardian
    Check ((Assert-BmxWatchdogPath $fixture -Directory) -ceq $fixture) 'Adapted real path guard rejected its disposable fixture'
    Reject {Assert-BmxWatchdogPath (Join-Path ($base+'-sibling') 'owner.json')} 'beneath'
    $created=[DateTime]::Parse('2026-10-22T12:00:00.1234567Z',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $receipt=[ordered]@{schema=1;event='bmx_owned_trial_watchdog_owner';process_id=1234;
        process_creation_filetime=[string]$created.ToFileTimeUtc();owned_created_utc=$created.ToString('o');
        game_exe='C:\Users\Jeffr\Desktop\reskate\build\bmx-game\Skate.exe';
        game_sha256='FBCE74D5E28EF525DBBA2CB4ADBEBC13405BDBD88F31BC940BCA45E4AE88B8F9';
        runtime_path='C:\Users\Jeffr\Desktop\reskate\build\bmx-game\ReSkate.dll';runtime_sha256=('A'*64)}
    $path=Join-Path $fixture 'owner.json'
    [IO.File]::WriteAllText($path,($receipt|ConvertTo-Json))
    $owner=Read-BmxWatchdogOwner $path
    Check ($owner.creation_filetime -eq $created.ToFileTimeUtc() -and $owner.created_utc.Ticks -eq $created.Ticks) 'Exact native UTC creation ticks were lost'
    Check ($owner.receipt_sha256 -ceq (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) 'Receipt hash does not pin bytes that were parsed'
    foreach($pair in @(@('schema',$true),@('schema','1'),@('event','bmx_virtual_gamepad_owner'),@('process_id',$true),@('process_id',1.5),
        @('process_creation_filetime',[long]$created.ToFileTimeUtc()),@('process_creation_filetime','01'),
        @('owned_created_utc',$created.AddTicks(1).ToString('o')),@('owned_created_utc','2026-10-22T12:00:00+00:00'),
        @('game_exe','D:\SteamLibrary\steamapps\common\Skate\Skate.exe'),@('runtime_path','C:\other\ReSkate.dll'),
        @('game_sha256',('B'*64)),@('runtime_sha256','bad'))) {
        $bad=@{};foreach($key in $receipt.Keys){$bad[$key]=$receipt[$key]};$bad[$pair[0]]=$pair[1]
        [IO.File]::WriteAllText($path,($bad|ConvertTo-Json))
        Reject {Read-BmxWatchdogOwner $path} 'watchdog|creation|FILETIME|owned'
    }
    Reject {Assert-BmxWatchdogPath (Join-Path $PSScriptRoot 'Watch-BmxOwnedTrial.ps1')} 'beneath'
    [IO.File]::WriteAllText($path,'{"schema":1,"event":"bad"}')
    $refused=Invoke-BmxOwnedTrialWatchdog $path $fixture 60
    $resultPath=Join-Path $fixture 'owned-trial-watchdog.result.json'
    $before=[IO.File]::ReadAllText($resultPath)
    $json=ConvertFrom-Json $before
    Check ($json.outcome -ceq 'refused' -and -not $json.absence_verified -and -not $json.controller_input_sent) 'Fresh refusal result was not preserved'
    Check ($json.guardian_source_sha256 -ceq (Get-FileHash -LiteralPath $fixtureGuardian -Algorithm SHA256).Hash) 'Result did not pin the actual disposable guardian source'
    Reject {Invoke-BmxOwnedTrialWatchdog $path $fixture 60} 'already exists|exists'
    Check ([IO.File]::ReadAllText($resultPath) -ceq $before) 'Repeated guardian overwrote prior evidence'
    $second=Join-Path $fixture 'existing-ready';[IO.Directory]::CreateDirectory($second)|Out-Null
    [IO.File]::WriteAllText((Join-Path $second 'owned-trial-watchdog.ready.json'),'retained')
    Reject {Invoke-BmxOwnedTrialWatchdog $path $second 60} 'already exists'
    Check (-not(Test-Path -LiteralPath (Join-Path $second 'owned-trial-watchdog.result.json'))) 'Existing ready receipt still reserved a new result'
} finally {
    # Restore the original definitions before any later declaration-only checks.
    . $guardian
    Check ((Get-FileHash -LiteralPath $guardian -Algorithm SHA256).Hash -ceq $guardianHash) 'Production guardian bytes changed'
    Reject {Assert-BmxWatchdogPath $fixture -Directory} 'beneath'
    $cleanup=[IO.Path]::GetFullPath($fixture)
    if(-not $cleanup.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture cleanup escaped its binary parent.'}
    Remove-Item -LiteralPath $cleanup -Recurse -Force
}

# Declaration compilation only: constructor/Observe/TerminateOwned are NOT run.
Initialize-BmxWatchdogNative
Check ($null -ne ('BmxOwnedTrial.NativeProcess' -as [type])) 'Native interop declarations failed compilation'
function Invoke-FakeObservation {
    param([uint32[]]$WaitStates,[string]$Fault='',[bool]$Full=$true,[bool]$ExitOnly=$false)
    $calls=[pscustomobject]@{wait=0;creation=0;image=0;loaded=0}
    $observation=[BmxOwnedTrial.ObservationReader]::Read(
        [Func[uint32]]{if($calls.wait -ge $WaitStates.Count){throw 'Unexpected extra wait'};return $WaitStates[$calls.wait++]},
        [Func[long]]{++$calls.creation;if($Fault -eq 'creation'){throw 'fake creation failed'};return 134371424265471298L},
        [Func[string]]{++$calls.image;if($Fault -eq 'image'){throw 'fake image failed'};return 'bound-image'},
        [Func[bool]]{++$calls.loaded;if($Fault -eq 'loaded'){throw 'fake loaded failed'};return $true},$Full,$ExitOnly)
    return [pscustomobject]@{value=$observation;calls=$calls}
}
$alreadyExited=Invoke-FakeObservation -WaitStates @(0) -Fault image
Check (-not $alreadyExited.value.running -and $alreadyExited.value.available -and $alreadyExited.value.creation_filetime -eq 134371424265471298L) 'Already exited held handle lost creation identity'
Check ($alreadyExited.calls.wait -eq 1 -and $alreadyExited.calls.creation -eq 1 -and $alreadyExited.calls.image -eq 0 -and $alreadyExited.calls.loaded -eq 0) 'Exited process still queried image/modules'
$live=Invoke-FakeObservation -WaitStates @(258,258)
Check ($live.value.running -and $live.value.image_path -ceq 'bound-image' -and $live.value.runtime_loaded) 'Live full observation lost binding'
Check ($live.calls.wait -eq 2 -and $live.calls.loaded -eq 1) 'Live full observation omitted final wait or module query'
$partial=Invoke-FakeObservation -WaitStates @(258,258) -Full $false -Fault loaded
Check ($partial.value.running -and $partial.calls.loaded -eq 0 -and $partial.calls.wait -eq 2) 'Partial observation queried modules or skipped final same-handle wait'
$pending=Invoke-FakeObservation -WaitStates @(258) -Full $false -ExitOnly $true -Fault image
Check ($pending.value.running -and $pending.value.creation_filetime -eq 134371424265471298L -and $pending.calls.image -eq 0 -and $pending.calls.loaded -eq 0) 'Pending exit performed a live binding query or lost creation identity'
Reject {Invoke-FakeObservation -WaitStates @(258) -Full $true -ExitOnly $true} 'Full binding'
Reject {Invoke-FakeObservation -WaitStates @(258) -Full $false -ExitOnly $true -Fault creation} 'creation failed'
Reject {Invoke-FakeObservation -WaitStates @([uint32]::MaxValue) -Full $false -ExitOnly $true} 'wait failed'
foreach($fault in @('','image','loaded')) {
    $raced=Invoke-FakeObservation -WaitStates @(258,0) -Fault $fault
    Check (-not $raced.value.running -and $raced.value.available -and $raced.value.creation_filetime -eq 134371424265471298L) ('Exit race did not retain original creation: '+$fault)
    Check ($raced.value.image_path -ceq '' -and -not $raced.value.runtime_loaded -and $raced.calls.wait -eq 2) ('Exit race retained stale live binding or skipped recheck: '+$fault)
}
foreach($fault in @('image','loaded')) {
    Reject {Invoke-FakeObservation -WaitStates @(258,258) -Fault $fault} ('fake '+$fault+' failed')
    Reject {Invoke-FakeObservation -WaitStates @(258,[uint32]::MaxValue) -Fault $fault} 'wait failed'
}
Reject {Invoke-FakeObservation -WaitStates @([uint32]::MaxValue)} 'wait failed'
foreach($initial in @(0,258)) {
    Reject {Invoke-FakeObservation -WaitStates @($initial) -Fault creation} 'creation failed'
}
function Invoke-FakeTermination {
    param([bool]$Accepted,[uint32]$WaitState=258)
    $calls=[Collections.Generic.List[string]]::new()
    $value=[BmxOwnedTrial.TerminationAttempt]::Run(
        [Func[bool]]{$calls.Add('terminate');return $Accepted},
        [Func[uint32]]{$calls.Add('wait');return $WaitState},
        [Func[Exception]]{$calls.Add('error');return [InvalidOperationException]::new('fake termination failed')})
    return [pscustomobject]@{value=$value;calls=$calls}
}
$acceptedTermination=Invoke-FakeTermination -Accepted $true
Check ($acceptedTermination.value -and ($acceptedTermination.calls -join ',') -ceq 'terminate') 'Accepted termination queried error or wait'
$exitedTermination=Invoke-FakeTermination -Accepted $false -WaitState 0
Check (-not $exitedTermination.value -and ($exitedTermination.calls -join ',') -ceq 'terminate,error,wait') 'Natural exit race lost original error before wait or claimed termination'
Reject {Invoke-FakeTermination -Accepted $false -WaitState 258} 'fake termination failed'
Reject {Invoke-FakeTermination -Accepted $false -WaitState ([uint32]::MaxValue)} 'termination wait failed'
Write-Output "Owned-trial watchdog: $script:checks fake assertions passed. No game/process/controller/native API action; pure C# observation reader and interop declaration compilation only."

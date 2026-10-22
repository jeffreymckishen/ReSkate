#requires -Version 7.5
<#!
.SYNOPSIS
Independent wall-clock guardian for one explicitly owned isolated BMX trial.
.DESCRIPTION
No launch, controller, window or keyboard operation. Start this script in a
hidden independent pwsh process and wait for its fresh ready JSON before any
potentially blocking UI call. MaxWallSeconds is measured from process creation,
not from a later UI operation. A native process handle prevents PID-reuse kills.

OwnerReceipt (JSON schema1/event bmx_owned_trial_watchdog_owner) must contain
process_id, process_creation_filetime (canonical decimal string),
owned_created_utc (UTC ISO string with matching exact FILETIME ticks), game_exe,
game_sha256, runtime_path and runtime_sha256. Both paths are fixed below.
RunDirectory must already exist beneath this workspace's build/bmx. Fresh
owned-trial-watchdog.ready.json and owned-trial-watchdog.result.json are never
overwritten. A ready receipt proves guardian arming only, never gameplay quality.
#>
param(
    [string]$OwnerReceipt,
    [string]$RunDirectory,
    [ValidateRange(60,600)][int]$MaxWallSeconds=300
)

function Assert-BmxWatchdogPath {
    param([string]$Path,[switch]$Directory)
    $root='C:\Users\Jeffr\Desktop\reskate\build\bmx'
    $full=[IO.Path]::GetFullPath($Path)
    if(-not $full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Watchdog evidence must be beneath the exact workspace build/bmx.'}
    $item=Get-Item -LiteralPath $full -ErrorAction Stop
    if(($item -is [IO.DirectoryInfo]) -ne [bool]$Directory){throw 'Watchdog evidence path has the wrong type.'}
    for($cursor=$item;$null -ne $cursor;$cursor=if($cursor -is [IO.DirectoryInfo]){$cursor.Parent}else{$cursor.Directory}) {
        if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Watchdog refuses reparse paths.'}
    }
    return $full
}

function Read-BmxWatchdogOwner {
    param([string]$Path)
    $full=Assert-BmxWatchdogPath $Path
    $stream=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if($stream.Length -lt 1 -or $stream.Length -gt 8192){throw 'Watchdog owner receipt must fit within8KiB.'}
        $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$true,1024,$true)
        try {$text=$reader.ReadToEnd()}finally{$reader.Dispose()}
        $value=ConvertFrom-Json -InputObject $text -AsHashtable -DateKind String -ErrorAction Stop
        $stream.Position=0;$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))
    } finally {$stream.Dispose()}
    $exe='C:\Users\Jeffr\Desktop\reskate\build\bmx-game\Skate.exe'
    $runtime='C:\Users\Jeffr\Desktop\reskate\build\bmx-game\ReSkate.dll'
    $gameHash='FBCE74D5E28EF525DBBA2CB4ADBEBC13405BDBD88F31BC940BCA45E4AE88B8F9'
    if($value -isnot [System.Collections.IDictionary] -or ($value['schema'] -isnot [int] -and $value['schema'] -isnot [long]) -or $value['schema'] -ne 1 -or
       $value['event'] -cne 'bmx_owned_trial_watchdog_owner'){throw 'A dedicated owned-trial watchdog receipt is required.'}
    if(($value['process_id'] -isnot [long] -and $value['process_id'] -isnot [int]) -or
       $value['process_id'] -lt 1 -or $value['process_id'] -gt [uint32]::MaxValue){throw 'Watchdog requires an integer owned PID.'}
    if($value['process_creation_filetime'] -isnot [string] -or $value['process_creation_filetime'] -cnotmatch '^[1-9][0-9]{0,18}$'){
        throw 'Watchdog requires exact canonical creation FILETIME.'
    }
    $created=[DateTime]::FromFileTimeUtc([long]::Parse($value['process_creation_filetime'],[Globalization.CultureInfo]::InvariantCulture))
    if($value['owned_created_utc'] -isnot [string] -or $value['owned_created_utc'] -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?Z$'){
        throw 'Watchdog requires an explicit UTC creation string.'
    }
    $utc=[DateTime]::Parse($value['owned_created_utc'],[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    if($utc.Kind -ne [DateTimeKind]::Utc -or $utc.Ticks -ne $created.Ticks){throw 'Watchdog UTC creation differs from exact native FILETIME.'}
    if($value['game_exe'] -ine $exe -or $value['runtime_path'] -ine $runtime -or
       $value['game_sha256'] -ine $gameHash -or $value['runtime_sha256'] -isnot [string] -or
       $value['runtime_sha256'] -cnotmatch '^[A-Fa-f0-9]{64}$'){throw 'Watchdog isolated executable/runtime binding is invalid.'}
    return [pscustomobject]@{process_id=[uint32]$value['process_id'];creation_filetime=[long]$value['process_creation_filetime'];
        created_utc=$created;game_exe=$exe;game_sha256=$gameHash;runtime_path=$runtime;runtime_sha256=$value['runtime_sha256'].ToUpperInvariant();
        receipt_path=$full;receipt_sha256=$hash}
}

function Assert-BmxWatchdogObservation {
    param($Owner,$Observation,[switch]$Full)
    if(-not $Observation.available -or $Observation.creation_filetime -ne $Owner.creation_filetime){throw 'Watchdog process identity unavailable or creation changed.'}
    if($Observation.running -and $Observation.image_path -ine $Owner.game_exe){throw 'Watchdog process image differs; no termination authorized.'}
    if($Full -and $Observation.running -and -not $Observation.runtime_loaded){throw 'Watchdog exact runtime is not loaded; no termination authorized.'}
}

function Invoke-BmxWatchdogCore {
    param($Owner,[ValidateRange(60,600)][int]$LimitSeconds,
        [scriptblock]$Open,[scriptblock]$Observe,[scriptblock]$VerifyFiles,[scriptblock]$Terminate,
        [scriptblock]$Close,[scriptblock]$Now,[scriptblock]$UtcNow,[scriptblock]$Sleep,[scriptblock]$Ready)
    $result=[ordered]@{schema=1;event='bmx_owned_trial_watchdog_result';outcome='refused';deadline_reached=$false;
        termination_requested=$false;termination_accepted=$false;absence_observations=0;absence_verified=$false;
        guardian_succeeded=$false;
        controller_input_sent=$false;game_launched=$false;trial_passed=$null;issue=$null;max_wall_seconds=$LimitSeconds;
        absence_scope='Original held process object signaled twice; no claim about a replacement process reusing the PID.';
        elapsed_guardian_seconds=0.0;owned_process_age_at_arm_seconds=$null;ready_published=$false}
    $handle=$null;$started=& $Now;$last=$started
    try {
        if(-not [double]::IsFinite($started)){throw 'Watchdog monotonic start is invalid.'}
        $age=((& $UtcNow)-$Owner.created_utc).TotalSeconds
        if(-not [double]::IsFinite($age) -or $age -lt -1){throw 'Watchdog creation is in the future.'}
        $age=[Math]::Max(0.0,$age);$result.owned_process_age_at_arm_seconds=$age
        $deadline=$started+[Math]::Max(0.0,$LimitSeconds-$age)
        $handle=& $Open $Owner
        $first=& $Observe $handle $true
        Assert-BmxWatchdogObservation $Owner $first -Full
        if($first.running) {
            & $VerifyFiles $Owner
            $armedAt=& $Now
            if(-not [double]::IsFinite($armedAt) -or $armedAt -lt $started){throw 'Watchdog monotonic arm clock failed.'}
            if($armedAt -lt $deadline){& $Ready $Owner $deadline;$result.ready_published=$true}
        }
        $exitDeadline=$null
        while($true) {
            $current=& $Now
            if(-not [double]::IsFinite($current) -or $current -lt $last){throw 'Watchdog monotonic clock failed.'}
            $last=$current;$result.elapsed_guardian_seconds=$current-$started
            $observation=& $Observe $handle $false
            Assert-BmxWatchdogObservation $Owner $observation
            if(-not $observation.running) {
                ++$result.absence_observations
                if($result.absence_observations -ge 2) {
                    $result.absence_verified=$true
                    $result.outcome=if($result.termination_accepted){'deadline_terminated'}elseif($result.deadline_reached){'exited_at_deadline'}else{'normal_exit'}
                    break
                }
                & $Sleep 0.1
                continue
            }
            $result.absence_observations=0
            if($null -ne $exitDeadline) {
                if($current -ge $exitDeadline){$result.outcome='deadline_exit_unverified';$result.issue='Original process handle did not signal exit within10seconds.';break}
                & $Sleep 0.1
                continue
            }
            if($current -ge $deadline) {
                $result.deadline_reached=$true
                $final=& $Observe $handle $true
                Assert-BmxWatchdogObservation $Owner $final -Full
                if($final.running) {
                    & $VerifyFiles $Owner
                    $result.termination_requested=$true
                    $result.termination_accepted=[bool](& $Terminate $handle $Owner)
                }
                $exitDeadline=$current+10
                continue
            }
            & $Sleep ([Math]::Min(0.25,$deadline-$current))
        }
    } catch {$result.issue=$_.Exception.Message;$result.outcome='refused'}
    finally {if($null -ne $handle){try{& $Close $handle}catch{$result.issue='Process-handle close failed: '+$_.Exception.Message}}}
    $result.guardian_succeeded=$result.absence_verified -and $null -eq $result.issue
    return [pscustomobject]$result
}

function Initialize-BmxWatchdogNative {
    if('BmxOwnedTrial.NativeProcess' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace BmxOwnedTrial {
public sealed class Observation {
    public bool available, running, runtime_loaded;
    public long creation_filetime;
    public string image_path = "";
}
// Pure reader, also exercised with deterministic fake native-call delegates.
public static class ObservationReader {
    static bool Running(Func<uint> wait) {
        uint state=wait();
        if(state!=0 && state!=258)throw new InvalidOperationException("Watchdog process wait failed");
        return state==258;
    }
    static Observation Exited(Observation result) {
        result.running=false;result.image_path="";result.runtime_loaded=false;
        return result;
    }
    public static Observation Read(Func<uint> wait, Func<long> creation, Func<string> image, Func<bool> loaded, bool full) {
        bool running=Running(wait);
        var result=new Observation {available=true,running=running,creation_filetime=creation()};
        if(!running)return result;
        try {
            result.image_path=image();
            result.runtime_loaded=!full || loaded();
        } catch {
            // A process may finish exiting after the initial unsignaled wait.
            // Only this same held object's signaled handle can turn that read
            // failure into an exit observation. Live failures remain failures.
            if(!Running(wait))return Exited(result);
            throw;
        }
        return Running(wait)?result:Exited(result);
    }
}
public static class TerminationAttempt {
    public static bool Run(Func<bool> terminate, Func<uint> wait, Func<Exception> failure) {
        if(terminate())return true;
        Exception original=failure(); // Capture native error before the wait.
        uint state=wait();
        if(state==0)return false; // This same object naturally exited first.
        if(state!=258)throw new InvalidOperationException("Watchdog termination wait failed");
        throw original;
    }
}
public sealed class NativeProcess : IDisposable {
    IntPtr handle;
    readonly uint pid;
    [StructLayout(LayoutKind.Sequential)] struct FileTime { public uint low, high; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Module {
        public uint size, id, pid, globalUsage, processUsage;
        public IntPtr baseAddress; public uint baseSize; public IntPtr module;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string path;
    }
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint id);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr value);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr value, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr value, out FileTime created, out FileTime exit, out FileTime kernel, out FileTime user);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr value, uint flags, StringBuilder path, ref uint length);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint id);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool Module32First(IntPtr snapshot, ref Module module);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool Module32Next(IntPtr snapshot, ref Module module);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr value, uint code);
    static Exception Error(string operation) { return new Win32Exception(Marshal.GetLastWin32Error(), operation); }
    public NativeProcess(uint id) {
        pid=id;handle=OpenProcess(0x1000|0x100000|0x1,false,id);
        if(handle==IntPtr.Zero)throw Error("Watchdog could not open owned process");
    }
    bool Loaded(string path) {
        IntPtr snapshot=CreateToolhelp32Snapshot(0x8|0x10,pid);
        if(snapshot==new IntPtr(-1))throw Error("Watchdog module snapshot failed");
        try {
            Module module=new Module();module.size=(uint)Marshal.SizeOf<Module>();
            bool more=Module32First(snapshot,ref module);
            for(int i=0;i<512 && more;i++) {
                if(module.baseSize>0 && String.Equals(module.path,path,StringComparison.OrdinalIgnoreCase))return true;
                more=Module32Next(snapshot,ref module);
            }
            return false;
        } finally {CloseHandle(snapshot);}
    }
    public Observation Observe(string runtimePath, bool full) {
        if(handle==IntPtr.Zero)throw new ObjectDisposedException("NativeProcess");
        return ObservationReader.Read(
            () => {uint state=WaitForSingleObject(handle,0);if(state!=0 && state!=258)throw Error("Watchdog process wait failed");return state;},
            () => {FileTime created,exit,kernel,user;
                if(!GetProcessTimes(handle,out created,out exit,out kernel,out user))throw Error("Watchdog creation read failed");
                return ((long)created.high<<32)|created.low;},
            () => {uint length=32768;var path=new StringBuilder((int)length);
                if(!QueryFullProcessImageName(handle,0,path,ref length))throw Error("Watchdog process image read failed");return path.ToString();},
            () => Loaded(runtimePath),full);
    }
    public bool TerminateOwned(long created, string image, string runtimePath) {
        var current=Observe(runtimePath,true);
        if(current.creation_filetime!=created || (current.running && (!String.Equals(current.image_path,image,StringComparison.OrdinalIgnoreCase)||!current.runtime_loaded)))
            throw new InvalidOperationException("Final owned-handle binding differs; termination refused");
        if(!current.running)return false;
        return TerminationAttempt.Run(() => TerminateProcess(handle,124),
            () => WaitForSingleObject(handle,0),() => Error("Owned trial termination failed"));
    }
    public void Dispose() { if(handle!=IntPtr.Zero){var value=handle;handle=IntPtr.Zero;if(!CloseHandle(value))throw Error("Watchdog handle close failed");} }
}
}
'@
}

function Test-BmxWatchdogFiles {
    param($Owner)
    foreach($pair in @(@($Owner.game_exe,$Owner.game_sha256),@($Owner.runtime_path,$Owner.runtime_sha256))) {
        $item=Get-Item -LiteralPath $pair[0] -ErrorAction Stop
        for($cursor=$item;$null -ne $cursor;$cursor=if($cursor -is [IO.DirectoryInfo]){$cursor.Parent}else{$cursor.Directory}) {
            if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Watchdog isolated file is a reparse path.'}
        }
        if($item -is [IO.DirectoryInfo] -or (Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash -ine $pair[1]){throw 'Watchdog isolated file SHA256 changed; termination refused.'}
    }
}

function Invoke-BmxOwnedTrialWatchdog {
    param([string]$ReceiptPath,[string]$EvidenceDirectory,[ValidateRange(60,600)][int]$LimitSeconds=300)
    $directory=Assert-BmxWatchdogPath $EvidenceDirectory -Directory
    $resultPath=Join-Path $directory 'owned-trial-watchdog.result.json'
    $readyPath=Join-Path $directory 'owned-trial-watchdog.ready.json'
    if(Test-Path -LiteralPath $readyPath){throw 'Watchdog ready path already exists.'}
    $output=[IO.File]::Open($resultPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $owner=$null;$result=$null;$startedUtc=[DateTime]::UtcNow.ToString('o');$scriptHash=$null
    try {
        $scriptHash=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
        $owner=Read-BmxWatchdogOwner $ReceiptPath
        Initialize-BmxWatchdogNative
        $result=Invoke-BmxWatchdogCore $owner $LimitSeconds `
            -Open {param($o) [BmxOwnedTrial.NativeProcess]::new($o.process_id)} `
            -Observe {param($h,$full) $h.Observe($owner.runtime_path,$full)} `
            -VerifyFiles {param($o) Test-BmxWatchdogFiles $o} `
            -Terminate {param($h,$o) $h.TerminateOwned($o.creation_filetime,$o.game_exe,$o.runtime_path)} `
            -Close {param($h) $h.Dispose()} `
            -Now {[double][Diagnostics.Stopwatch]::GetTimestamp()/[Diagnostics.Stopwatch]::Frequency} `
            -UtcNow {[DateTime]::UtcNow} -Sleep {param($seconds) Start-Sleep -Milliseconds ([int][Math]::Ceiling($seconds*1000))} `
            -Ready {param($o,$deadline)
                $ready=[ordered]@{schema=1;event='bmx_owned_trial_watchdog_ready';guardian_pid=$PID;armed_utc=[DateTime]::UtcNow.ToString('o');
                    process_id=$o.process_id;process_creation_filetime=[string]$o.creation_filetime;owned_created_utc=$o.created_utc.ToString('o');
                    game_exe=$o.game_exe;runtime_path=$o.runtime_path;runtime_sha256=$o.runtime_sha256;owner_receipt_sha256=$o.receipt_sha256;
                    guardian_source_sha256=$scriptHash;max_wall_seconds=$LimitSeconds;deadline_utc=$o.created_utc.AddSeconds($LimitSeconds).ToString('o');
                    controller_input_sent=$false;game_launched=$false;boundary='Guardian armed; no controller, gameplay or visual acceptance.'}
                $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($ready|ConvertTo-Json -Depth 6)+"`n")
                $temporary=$readyPath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
                $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
                try{$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
                [IO.File]::Move($temporary,$readyPath)
            }
    } catch {$result=[pscustomobject]@{schema=1;event='bmx_owned_trial_watchdog_result';outcome='refused';issue=$_.Exception.Message;
        absence_verified=$false;guardian_succeeded=$false;controller_input_sent=$false;game_launched=$false;trial_passed=$null}}
    finally {
        if($null -ne $result) {
            $result|Add-Member -NotePropertyName guardian_pid -NotePropertyValue $PID
            $result|Add-Member -NotePropertyName guardian_source_sha256 -NotePropertyValue $scriptHash
            $result|Add-Member -NotePropertyName started_utc -NotePropertyValue $startedUtc
            $result|Add-Member -NotePropertyName completed_utc -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
            if($null -ne $owner){$result|Add-Member -NotePropertyName owner -NotePropertyValue $owner}
            $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($result|ConvertTo-Json -Depth 8)+"`n")
            try{$output.Write($bytes);$output.Flush($true)}finally{$output.Dispose()}
        }else{$output.Dispose()}
    }
    return $result
}

if($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference='Stop'
    try {
        if(-not $OwnerReceipt -or -not $RunDirectory){throw 'Explicit OwnerReceipt and existing RunDirectory are required.'}
        $result=Invoke-BmxOwnedTrialWatchdog $OwnerReceipt $RunDirectory $MaxWallSeconds
        $result|ConvertTo-Json -Depth 8
        if(-not $result.guardian_succeeded){exit 2}
    } catch {Write-Error $_ -ErrorAction Continue;exit 2}
}

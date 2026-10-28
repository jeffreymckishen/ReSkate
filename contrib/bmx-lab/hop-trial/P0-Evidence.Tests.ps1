#requires -Version 7.5
[CmdletBinding()]
param([switch]$RunReviewedTests)
if(-not $RunReviewedTests){throw 'Pass -RunReviewedTests only in an owned offline validation window.'}
# SOURCE-ONLY fixture suite. UNRUN by the author. Root may run after seal validation.
# No operator import, file writes, game, process, controller or native calls.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'P0-Evidence.ps1')
$script:P0Cases=0
$script:Run='warmup-p0-20261027-v1';$script:Plugin='BMX_Hop_Trial_warmup-p0-20261027-v1'
function New-P0Fixture {
    $body=@{serial='10';position=@(0,1,0);velocity=@(0,0,0);rotation=@(0,0,0,1);angular_velocity=@(0,0,0);inertia=@(1,1,1);time=1;seconds=.01666666567325592;mass=106}
    $next=@{};foreach($k in $body.Keys){$next[$k]=$body[$k]};$next.serial='11';$next.time=1.01666666567325592
    $body.call='world.physics.read';$body.call_ok=$true
    # Actual pre-submit source_record shape: full pad/identity, no neutral/input_ok.
    $buttons=@{};foreach($name in @('up','down','left','right','start','back','left_stick','right_stick','lb','rb','a','b','x','y')){$buttons[$name]=$false}
    $pad=@{playstation=$false;left_x=0;left_y=0;right_x=0;right_y=0;left_trigger=0;right_trigger=0;buttons=$buttons}
    $events=@(
        @('prepare',@{call='world.physics.prepare';call_ok=$true;result=$true;arity=1;arguments=0;phase='ready'}),
        @('lease',@{call='input.lease_capture_state';call_ok=$true;sequence='2';source_epoch='3';context_generation='4';user=0;phase='capturing';capturing=$true;report_debt=$true;quarantined=$false}),
        @('body',$body),
        @('source',@{sequence='2';source_epoch='3';context_generation='4';user=0;observation_serial='4';pad=$pad}),
        @('mapped_hop',@{hop=$false;rotation_reserved=$false;hop_event_id=0;pedal=0;steer=0;brake=0}),
        @('contact',@{valid=$true;force_ready=$true;query=@{epoch_matches=$true;accounting_known=$true;measurements_complete=$true;budget_exhausted=$false};support=@{known=$true;grounded_known=$true;grounded=$true}}),
        @('lease',@{call='world.physics.read_follow_lease';call_ok=$true;sequence='8';active=$true;renewable=$false;renewals='0'}),
        @('follow',@{call='world.physics.read_follow';call_ok=$true;sequence='8';phase='following';claim_known=$true}),
        @('pose',@{call='skater.pose';call_ok=$true;result=$true}),
        @('pose',@{qualified=$true;sends=1}),
        @('submit',@{call='world.physics.submit';call_ok=$true;result=$true;arity=3;sequence='9';serial='10';force=@(0,1060,0);torque=@(0,0,0)}),
        @('receipt',@{call='world.physics.receipt';call_ok=$true;sequence='9';requested_serial='10';produced_serial='11';outcome='applied';quarantined=$false;successor=$next}),
        @('ack',@{call='world.physics.acknowledge';call_ok=$true;arity=1;sequence='9';acknowledged=$true})
    )
    $rows=@();$at=0
    foreach($event in $events){$at++;$rows+=@{kind=$event[0];data=$event[1];first_call=$at;last_call=$at;repeats=1;incomplete=$false}}
    $latest=@{phase='done';bike_cleanup_complete=$true;native_preparation=@{phase='ready'};
        cleanup_pending=$false;cleanup_unknown=$false;bike_authority=$false;force_cleanup_unknown=$false;handoff_unknown=$false;reserve_unknown=$false;marker_unknown=$false;retained_reload_marker=$false;
        ride=@{force_pending=$false;unknown=$false;pending_count=0};source=@{cleanup_pending=$false;cleanup_unknown=$false;lease_handle_present=$false;capture_state=@{phase='complete';capturing=$false;report_debt=$false;quarantined=$false}};
        equipment=@{retained=$false;unknown=$false};board_drop=@{state='restored';restore_pending=$false;drop_inflight=$false;restore_inflight=$false};mounted_pose=@{sends=1;nil_calls=1;stopped=$true;nil_accepted=$true}}
    $summary=@{schema=1;kind='hop-trial-evidence';run_id=$script:Run;chunks=1;calls=$rows.Count;regular_rows=$rows.Count;critical_rows=0;stored_rows=$rows.Count;coalesced=0;dropped=0;
        observation_loss=$false;unqualified=$false;storage_fault=$false;interrupted=$false;final_snapshot_unavailable=$false;unresolved_debt=$false;cleanup_unknown_seen=$false;board_restore_unresolved=$false;pose_release_unresolved=$false;cleanup_observed=$true;latest=$latest}
    $doc=@{};$doc['hop.'+$script:Run+'.summary']=$summary;$doc['hop.'+$script:Run+'.chunk.1']=@{schema=1;run_id=$script:Run;chunk=1;rows=$rows}
    $routes=@(@{source='route0';namespace=$script:Plugin;state='copied';sha256=('A'*64);short_read=$false;changed_during_read=$false;document=$doc},
        @{source='route1';namespace=$script:Plugin;state='missing'},@{source='route2';namespace=$script:Plugin;state='missing'})
    return @{routes=$routes;document=$doc;summary=$summary;rows=$rows;latest=$latest}
}
function Assert-P0([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-P0Unknown($Result){foreach($value in $Result.flags.Values){Assert-P0 ($value -ceq 'unverified') 'An invalid fixture earned a reported flag'}}
function Test-P0([string]$Name,[scriptblock]$Mutate,[scriptblock]$Check){
    $f=New-P0Fixture;& $Mutate $f
    $r=Get-P0EvidenceSummary -Routes $f.routes -RunId $script:Run -PluginId $script:Plugin -EvidenceEncoding legacy-v1
    & $Check $r;$script:P0Cases++;Write-Output ('PASS '+$Name)
}
$unknown={param($r) Assert-P0Unknown $r;Assert-P0 ($r.issues.Count -gt 0) 'Refusal has no diagnostic'}
$allReported={param($r) foreach($v in $r.flags.Values){Assert-P0 ($v -ceq 'reported') 'Complete detached fixture lost a reported stage'};Assert-P0 ($r.issues.Count -eq 0) 'Complete fixture has issues'}
Test-P0 'complete detached fixture, one present route and two absent' {} $allReported
Test-P0 'all routes absent' {param($f) $f.routes[0].state='missing'} $unknown
Test-P0 'route count is exactly three' {param($f) $f.routes=@($f.routes[0],$f.routes[1])} $unknown
Test-P0 'short raw snapshot' {param($f) $f.routes[0].short_read=$true} $unknown
Test-P0 'changed raw snapshot' {param($f) $f.routes[0].changed_during_read=$true} $unknown
Test-P0 'malformed JSON route diagnostic' {param($f) $f.routes[0].state='error';$f.routes[0].error='Invalid JSON'} $unknown
Test-P0 'short valid JSON lacks summary' {param($f) $f.routes[0].document=@{}} $unknown
Test-P0 'malformed decoded scalar' {param($f) $f.routes[0].document=1} $unknown
Test-P0 'namespace mismatch' {param($f) $f.routes[0].namespace='another-package'} $unknown
Test-P0 'duplicate source route' {param($f) $f.routes[1].source='ROUTE0'} $unknown
Test-P0 'run mismatch' {param($f) $f.summary.run_id='stale'} $unknown
Test-P0 'different present raw hashes never last wins' {param($f) $r=@{};foreach($k in $f.routes[0].Keys){$r[$k]=$f.routes[0][$k]};$r.source='route1';$r.sha256='B'*64;$f.routes[1]=$r} $unknown
Test-P0 'different same-run summaries despite claimed same hash' {param($f) $other=New-P0Fixture;$other.summary.calls=999;$other.routes[0].source='route1';$f.routes[1]=$other.routes[0]} $unknown
Test-P0 'identical present routes agree' {param($f) $r=@{};foreach($k in $f.routes[0].Keys){$r[$k]=$f.routes[0][$k]};$r.source='route1';$f.routes[1]=$r} $allReported
Test-P0 'incomplete marker cannot be overridden by older summary' {param($f) $f.document['hop.'+$script:Run+'.incomplete']=@{interrupted=$true}} $unknown
Test-P0 'unexpected prior-run key' {param($f) $f.document['hop.prior.summary']=@{}} $unknown
Test-P0 'missing chunk revision' {param($f) $f.summary.chunks=2} $unknown
Test-P0 'chunk extends past summary' {param($f) $f.summary.chunks=0} $unknown
Test-P0 'chunk identity contradiction' {param($f) $f.document['hop.'+$script:Run+'.chunk.1'].chunk=2} $unknown
Test-P0 'chunk run contradiction' {param($f) $f.document['hop.'+$script:Run+'.chunk.1'].run_id='wrong'} $unknown
Test-P0 'stored-row total contradiction' {param($f) $f.summary.stored_rows++} $unknown
Test-P0 'call tail missing' {param($f) $f.summary.calls++} $unknown
Test-P0 'coalescing total contradiction' {param($f) $f.summary.coalesced++} $unknown
Test-P0 'dropped row refuses' {param($f) $f.summary.dropped=1} $unknown
Test-P0 'row incomplete refuses' {param($f) $f.rows[0].incomplete=$true} $unknown
Test-P0 'observation loss refuses' {param($f) $f.summary.observation_loss=$true} $unknown
Test-P0 'unresolved summary debt refuses' {param($f) $f.summary.unresolved_debt=$true} $unknown
Test-P0 'missing summary loss flag refuses' {param($f) $f.summary.Remove('observation_loss')} $unknown
Test-P0 'latest top-level debt contradicts clean summary' {param($f) $f.latest.cleanup_pending=$true} $unknown
Test-P0 'latest ride debt contradicts clean summary' {param($f) $f.latest.ride.pending_count=1} $unknown
Test-P0 'latest input capture debt contradicts clean summary' {param($f) $f.latest.source.capture_state.report_debt=$true} $unknown
Test-P0 'latest equipment debt contradicts clean summary' {param($f) $f.latest.equipment.retained=$true} $unknown
Test-P0 'latest dropped board contradicts clean summary' {param($f) $f.latest.board_drop.state='dropped'} $unknown
Test-P0 'latest in-flight restoration contradicts clean summary' {param($f) $f.latest.board_drop.restore_inflight=$true} $unknown
Test-P0 'latest pose debt contradicts clean summary' {param($f) $f.latest.mounted_pose.nil_accepted=$false} $unknown
Test-P0 'missing required terminal debt fact' {param($f) $f.latest.Remove('cleanup_unknown')} $unknown
Test-P0 'missing terminal completion is unverified' {param($f) $f.latest.Remove('bike_cleanup_complete')} {param($r) Assert-P0 ($r.flags.terminal_cleanup -ceq 'unverified') 'Missing terminal flag was inferred'}
Test-P0 'watchdog terminal is not cleanup' {param($f) $f.latest.phase='retained_unknown'} {param($r) Assert-P0 ($r.flags.terminal_cleanup -ceq 'unverified') 'Watchdog terminal became cleanup'}
Test-P0 'nonneutral input refuses' {param($f) $f.rows[3].data.neutral=$false} $unknown
Test-P0 'hop intent refuses' {param($f) $f.rows[4].data.hop_event_id=1} $unknown
Test-P0 'impulse packet contradicts P0' {param($f) $f.rows[10].data.impulse=@(0,1,0)} $unknown
Test-P0 'accepted packet malformed force refuses' {param($f) $f.rows[10].data.force=@(0,1)} $unknown
Test-P0 'submit ABI mismatch refuses' {param($f) $f.rows[10].data.arity=2} $unknown
Test-P0 'ACK ABI mismatch is not acknowledged evidence' {param($f) $f.rows[12].data.arity=2} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'unverified') 'Bad ACK ABI reported'}
Test-P0 'submit body identity mismatch stays unverified' {param($f) $f.rows[10].data.serial='99'} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'unverified') 'Wrong submitted serial accepted'}
Test-P0 'successor body identity mismatch stays unverified' {param($f) $f.rows[11].data.successor.serial='99'} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'unverified') 'Wrong successor accepted'}
Test-P0 'incomplete successor body stays unverified' {param($f) $f.rows[11].data.successor.Remove('angular_velocity')} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'unverified') 'Incomplete successor accepted'}
Test-P0 'pose release alone does not prove sent pose' {param($f) $f.rows[9].data.sends=0} {param($r) Assert-P0 ($r.flags.pose_api -ceq 'unverified') 'Release alone became pose send'}
Test-P0 'fixed Follow evidence is not dependent on first-call order' {param($f) $d=$f.rows[6].data;$f.rows[6].kind='follow';$f.rows[6].data=$f.rows[7].data;$f.rows[7].kind='lease';$f.rows[7].data=$d} $allReported
Test-P0 'Follow must match fixed lease sequence' {param($f) $f.rows[7].data.sequence='99'} {param($r) Assert-P0 ($r.flags.fixed_follow -ceq 'unverified') 'Unmatched Follow sequence accepted'}
Test-P0 'no native, visual, environment, memory or durability claims' {} {param($r)
    foreach($n in @('qualified','native_qualified','native_retirement_verified','visual_pose_verified','runtime_environment_verified','runtime_memory_verified','storage_durability_verified')){Assert-P0 ($r[$n] -is [bool] -and $r[$n] -eq $false) ('Unsupported claim: '+$n)}
    Assert-P0 ($r.limitations.Count -ge 3) 'Evidence limitations missing'
}
foreach($missing in @('capture_state','equipment','board_drop')){
    $f=New-P0Fixture
    if($missing -ceq 'capture_state'){$f.latest.source.Remove($missing)}else{$f.latest.Remove($missing)}
    $r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin -EvidenceEncoding legacy-v1
    Assert-P0 ($r.flags.terminal_cleanup -ceq 'unverified') ('Missing terminal map promoted: '+$missing);$script:P0Cases++
}
foreach($pair in @(@('capture_state','report_debt'),@('capture_state','quarantined'),@('equipment','retained'),@('equipment','unknown'),@('board_drop','restore_pending'),@('board_drop','drop_inflight'),@('board_drop','restore_inflight'),@('board_drop','state'))){
    $f=New-P0Fixture;$map=if($pair[0] -ceq 'capture_state'){$f.latest.source.capture_state}else{$f.latest[$pair[0]]};$map.Remove($pair[1])
    $r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin -EvidenceEncoding legacy-v1
    Assert-P0 ($r.flags.terminal_cleanup -ceq 'unverified') ('Missing terminal fact promoted: '+($pair -join '.'));$script:P0Cases++
}
Test-P0 'source belongs to another capture sequence' {param($f) $f.rows[3].data.sequence='99'} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'unverified') 'Unrelated source sequence accepted'}
Test-P0 'source belongs to another capture epoch' {param($f) $f.rows[3].data.source_epoch='99'} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'unverified') 'Unrelated source epoch accepted'}
Test-P0 'source belongs to another capture context' {param($f) $f.rows[3].data.context_generation='99'} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'unverified') 'Unrelated source context accepted'}
Test-P0 'source belongs to another capture user' {param($f) $f.rows[3].data.user=1} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'unverified') 'Unrelated source user accepted'}
Test-P0 'active capture cannot claim debt already cleared' {param($f) $f.rows[1].data.report_debt=$false} {param($r) Assert-P0 ($r.flags.input_capture -ceq 'unverified' -and $r.flags.neutral_receipt_ack -ceq 'unverified') 'Impossible capturing/debt-free state accepted'}
Test-P0 'real pre-submit projection omits optional neutral/cache facts' {} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'reported') 'Real mapped source projection cannot report neutral receipt chain'}
Test-P0 'missing projected pad stays unverified' {param($f) $f.rows[3].data.Remove('pad')} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'unverified') 'Missing pad inferred neutral'}
Test-P0 'missing projected button stays unverified' {param($f) $f.rows[3].data.pad.buttons.Remove('y')} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'unverified') 'Missing button inferred released'}
Test-P0 'nonzero projected axis stays unverified' {param($f) $f.rows[3].data.pad.left_x=.1} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'unverified') 'Nonzero projected axis inferred zero'}
Test-P0 'pressed projected button stays unverified' {param($f) $f.rows[3].data.pad.buttons.a=$true} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'unverified') 'Pressed projected button inferred neutral'}
Test-P0 'explicit input refusal cannot be overridden by zero pad' {param($f) $f.rows[3].data.input_ok=$false} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'unverified') 'Explicit cache refusal ignored'}
Test-P0 'malformed optional neutral fact cannot be ignored' {param($f) $f.rows[3].data.neutral=1} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'unverified') 'Malformed neutral fact ignored'}
Test-P0 'explicit null optional neutral fact is not absent' {param($f) $f.rows[3].data.neutral=$null} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'unverified') 'Explicit null neutral fact ignored'}
# The singleton-array case exercises the actual map accessor; no filesystem fixture needed.
$single=P0-EvField @{rows=@(@{kind='prepare'})} 'rows'
Assert-P0 ($single -is [Collections.IList] -and $single.Count -eq 1) 'Singleton array collapsed';$script:P0Cases++
# Strict decoder uses the same runtime helper as collection, only with an in-memory literal.
$j=[System.Text.Json.JsonDocument]::Parse('{"key":1,"key":2}')
try{$refused=$false;try{$null=P0-EvDecode $j.RootElement @{nodes=0}}catch{$refused=$true};Assert-P0 $refused 'Duplicate JSON fields were silently selected';$script:P0Cases++}finally{$j.Dispose()}
Write-Output ('P0 evidence source suite: '+$script:P0Cases+' cases passed; no native/gameplay qualification.')
# Codec fixtures are synthetic, never native captures. The complete frozen
# Root5 suite above still tests explicit legacy selection and its old predicates.
$script:P0CodecCases=0
function P0-TestStringCost([string]$Value){
    [long]$cost=2;foreach($b in [Text.UTF8Encoding]::new($false,$true).GetBytes($Value)){$cost+=$(if($b -lt 32 -or $b -eq 34 -or $b -eq 92 -or $b -ge 127){6}else{1})};return $cost
}
function P0-TestScalarCost($Value){if($Value -is [string]){return (P0-TestStringCost $Value)};if($Value -is [bool]){return 5L};return 32L}
# Independent digit-count oracle: powers of ten rather than the consumer's
# InvariantCulture Int64 formatting. Canonical P0-TestScalarCost remains32.
function P0-TestWireScalarCost($Value){
    if($Value -is [string]){return (P0-TestStringCost $Value)};if($Value -is [bool]){return 5L}
    if($Value -is [double] -or $Value -is [single]){
        $n=[double]$Value
        if(-not(P0-EvNumber $n) -or [Math]::Floor($n) -ne $n -or [Math]::Abs($n) -gt 9007199254740992.0){return 32L}
        $integer=[long]$n
    }else{
        $n=[decimal]$Value
        if([decimal]::Truncate($n) -ne $n -or $n -lt -9007199254740992D -or $n -gt 9007199254740992D){return 32L}
        $integer=[long]$n
    }
    [long]$magnitude=[Math]::Abs($integer);[long]$threshold=10;$digits=1
    while($magnitude -ge $threshold){$digits++;$threshold*=10}
    if($integer -lt 0){$digits++};return $digits
}
function P0-TestDataCost($Value){
    if($Value -is [Collections.IDictionary]){[long]$cost=2;foreach($key in $Value.Keys){$cost+=([string]$key).Length+4+(P0-TestDataCost $Value[$key])};return $cost}
    if($Value -is [Collections.IList]){[long]$cost=2;for($i=0;$i -lt $Value.Count;$i++){$cost+=($i+1).ToString([Globalization.CultureInfo]::InvariantCulture).Length+4+(P0-TestDataCost $Value[$i])};return $cost}
    return (P0-TestScalarCost $Value)
}
function P0-TestNodeCost($Node){
    # Independent structural-array arithmetic: brackets, commas and each slot.
    [long]$cost=2+([int]$Node[0]).ToString([Globalization.CultureInfo]::InvariantCulture).Length
    if($Node.Count -eq 1){return $cost};$cost++
    if($Node[0] -eq 1){return ($cost+(P0-TestWireScalarCost $Node[1]))}
    if($Node[1] -is [bool]){return ($cost+5)}
    $cost+=2
    for($i=0;$i -lt $Node[1].Count;$i++){
        if($i -gt 0){$cost++};$pair=$Node[1][$i]
        $cost+=2+([int]$pair[0]).ToString([Globalization.CultureInfo]::InvariantCulture).Length+1+(P0-TestNodeCost $pair[1])
    };return $cost
}
function P0-TestRowCost($Wire){
    [long]$cost=18
    for($i=0;$i -lt 12;$i++){
        if($i -gt 0){$cost++}
        if($i -eq 10){$cost+=P0-TestNodeCost $Wire[$i]}
        elseif($i -in @(1,3,4,5,6)){$cost+=([long]$Wire[$i]).ToString([Globalization.CultureInfo]::InvariantCulture).Length}
        else{$cost+=P0-TestWireScalarCost $Wire[$i]}
    };return $cost
}
function P0-TestEncodeNode($Value){
    if($Value -is [Collections.IDictionary] -or $Value -is [Collections.IList]){
        $entries=[Collections.Generic.List[object]]::new()
        if($Value -is [Collections.IDictionary]){foreach($key in $Value.Keys){$token=$script:HopEvidenceFields.IndexOf([string]$key)+1;Assert-P0 ($token -gt 0) ('Unknown fixture field '+$key);$entries.Add(@{token=$token;value=$Value[$key]})}}
        else{for($i=0;$i -lt $Value.Count;$i++){$entries.Add(@{token=(-$i-1);value=$Value[$i]})}}
        $node=[object[]]::new(2);$node[0]=2
        if($entries.Count -eq 0){$node[1]=$false}
        else{
            $sorted=@($entries.ToArray() | Sort-Object token);$pairs=[object[]]::new($sorted.Count)
            for($i=0;$i -lt $sorted.Count;$i++){$pair=[object[]]::new(2);$pair[0]=$sorted[$i].token;$pair[1]=P0-TestEncodeNode $sorted[$i].value;$pairs[$i]=$pair};$node[1]=$pairs
        };return ,$node
    }
    if((P0-EvNumber $Value) -and $Value -eq 0 -and [BitConverter]::DoubleToInt64Bits([double]$Value) -eq [long]::MinValue){$node=[object[]]::new(1);$node[0]=4;return ,$node}
    $node=[object[]]::new(2);$node[0]=1;$node[1]=$Value;return ,$node
}
function P0-TestUpdateCodecTotals($Fixture){
    $states=[Collections.Generic.Dictionary[string,long]]::new([StringComparer]::Ordinal)
    [long]$regularWire=0;[long]$criticalBytes=0;[long]$stateBytes=2048;[long]$calls=0;$regular=0;$critical=0;$rowIndex=0
    foreach($wire in $Fixture.wires){
        $row=$Fixture.rows[$rowIndex];$rowIndex++;$calls+=$row.repeats
        if($wire[0]){$critical++;$criticalBytes+=P0-TestRowCost $wire}
        else{
            $regular++;$regularWire+=P0-TestRowCost $wire
            $key=([int]$wire[1]).ToString()+':'+$wire[2]
            if($states.ContainsKey($key)){$stateBytes-=$states[$key]}
            $states[$key]=(P0-TestDataCost $row.data)+64+(P0-TestStringCost $row.kind)+(P0-TestStringCost $wire[2])+$(if($wire[11]){256}else{0});$stateBytes+=$states[$key]
        }
    }
    $Fixture.summary.calls=$calls;$Fixture.summary.coalesced=$calls-$Fixture.rows.Count;$Fixture.summary.regular_rows=$regular;$Fixture.summary.critical_rows=$critical;$Fixture.summary.stored_rows=$Fixture.rows.Count
    $Fixture.summary.regular_wire_bytes=$regularWire;$Fixture.summary.regular_state_bytes=$stateBytes;$Fixture.summary.regular_bytes=$regularWire+$stateBytes;$Fixture.summary.critical_bytes=$criticalBytes
}
function Convert-P0FixtureCodec($Fixture,[int]$RowsPerChunk=16){
    foreach($key in @($Fixture.document.Keys)){if([string]$key -clike ('hop.'+$script:Run+'.chunk.*')){$Fixture.document.Remove($key)}}
    $wires=[object[]]::new($Fixture.rows.Count)
    for($i=0;$i -lt $Fixture.rows.Count;$i++){
        $row=$Fixture.rows[$i];$wire=[object[]]::new(12);$wire[11]=(P0-EvBool $row 'paired' $true);$wire[0]=(P0-EvBool $row 'critical' $true);$wire[1]=$script:HopEvidenceKinds.IndexOf($row.kind)+1
        $wire[2]=$(if(P0-EvHasField $row.data 'call'){$row.data.call}else{''});$wire[3]=0;$wire[4]=$row.first_call;$wire[5]=$row.last_call;$wire[6]=$row.repeats
        foreach($slot in @(7,8)){
            $name=$(if($slot -eq 7){'first_at_ms'}else{'last_at_ms'})
            if(P0-EvHasField $row $name){$time=$row[$name];$wire[$slot]=$(if($time -eq 0 -and [BitConverter]::DoubleToInt64Bits([double]$time) -eq [long]::MinValue){'-0'}else{$time})}else{$wire[$slot]=$false}
        }
        $wire[9]=$row.incomplete;$wire[10]=P0-TestEncodeNode $row.data;$wires[$i]=$wire
    }
    $Fixture['wires']=$wires;$Fixture.summary['encoding']='hop-delta-v4';$number=0
    for($start=0;$start -lt $wires.Count;$start+=$RowsPerChunk){
        $number++;$n=[Math]::Min($RowsPerChunk,$wires.Count-$start);$chunkRows=[object[]]::new($n)
        for($j=0;$j -lt $n;$j++){$chunkRows[$j]=$wires[$start+$j]}
        $Fixture.document['hop.'+$script:Run+'.chunk.'+$number]=@{schema=2;encoding='hop-delta-v4';run_id=$script:Run;chunk=$number;rows=$chunkRows}
    }
    $Fixture.summary.chunks=$number;P0-TestUpdateCodecTotals $Fixture
}
function Test-P0Codec([string]$Name,[scriptblock]$Mutate,[scriptblock]$Check,[scriptblock]$BeforeEncode={}){
    $f=New-P0Fixture;& $BeforeEncode $f;Convert-P0FixtureCodec $f;& $Mutate $f
    $r=Get-P0EvidenceSummary -Routes $f.routes -RunId $script:Run -PluginId $script:Plugin
    & $Check $r;$script:P0CodecCases++;Write-Output ('PASS codec '+$Name)
}
Test-P0Codec 'complete decoded P0 has unchanged recorded flags' {} $allReported
Test-P0Codec 'summary remains bounded by its reserved16KiB' {param($f) $f.summary['diagnostic']=('x'*16384)} $unknown
Test-P0Codec 'coalesced occurrence ranges still reach unchanged P0 predicates' {} $allReported {param($f)
    $f.rows[0].last_call=3;$f.rows[0].repeats=3;$f.rows[0]['first_at_ms']=[BitConverter]::Int64BitsToDouble([long]::MinValue);$f.rows[0]['last_at_ms']=.01666666567325592
    for($i=1;$i -lt $f.rows.Count;$i++){$f.rows[$i].first_call+=2;$f.rows[$i].last_call+=2}
}
Test-P0Codec 'codec success never promotes native qualification' {} {param($r)
    foreach($name in @('qualified','native_qualified','native_retirement_verified','visual_pose_verified','runtime_environment_verified','runtime_memory_verified','storage_durability_verified')){Assert-P0 ($r[$name] -is [bool] -and -not $r[$name]) ('Unsupported codec claim '+$name)}
    Assert-P0 ($r.evidence_encoding -ceq 'hop-delta-v4' -and $null -ne $r.codec_accounting) 'Codec provenance is missing'
}
foreach($name in @('regular_bytes','regular_wire_bytes','regular_state_bytes','critical_bytes')){
    $f=New-P0Fixture;Convert-P0FixtureCodec $f;$f.summary[$name]++
    $r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
    Assert-P0Unknown $r;Assert-P0 (($r.issues -join '|') -match ('Codec byte accounting contradicts summary: '+$name)) 'Accounting refusal was not specific';$script:P0CodecCases++
}
Test-P0Codec 'missing state accounting cannot inherit old384 estimate' {param($f) $f.summary.Remove('regular_state_bytes')} $unknown
Test-P0Codec 'regular critical split must match wire flags' {param($f) $f.summary.regular_rows--;$f.summary.critical_rows++} $unknown
Test-P0Codec 'unknown summary encoding never downgrades' {param($f) $f.summary.encoding='hop-delta-v2'} $unknown
Test-P0Codec 'null summary encoding never downgrades' {param($f) $f.summary.encoding=$null} $unknown
Test-P0Codec 'v4 summary requires schema1 integer' {param($f) $f.summary.schema='1'} $unknown
Test-P0Codec 'legacy-shaped summary is not implicit legacy selection' {param($f) $f.summary.Remove('encoding')} $unknown
Test-P0Codec 'unknown chunk encoding never downgrades' {param($f) $f.document['hop.'+$script:Run+'.chunk.1'].encoding='hop-delta-v2'} $unknown
Test-P0Codec 'v4 summary cannot carry legacy chunk' {param($f) $c=$f.document['hop.'+$script:Run+'.chunk.1'];$c.schema=1;$c.Remove('encoding');$c.rows=$f.rows} $unknown
Test-P0Codec 'row call exceeding summary calls cannot pass codec alone' {param($f) $f.summary.calls--} $unknown
Test-P0Codec 'incomplete decoded row cannot report native stages' {param($f) $f.wires[0][9]=$true} $unknown
Test-P0Codec 'mismatched chunk run stays unverified' {param($f) $f.document['hop.'+$script:Run+'.chunk.1'].run_id='other'} $unknown
Test-P0Codec 'unordered decoded row stays unverified' {param($f) $f.wires[1][4]=1} $unknown
Test-P0Codec 'forward projection reference stays unverified' {param($f) $f.wires[1][3]=99} $unknown
Test-P0Codec 'legacy row object cannot enter strict wire decoder' {param($f) $f.document['hop.'+$script:Run+'.chunk.1'].rows=$f.rows} $unknown
Test-P0Codec 'cleanup unknown remains fatal after decode' {param($f) $f.latest.cleanup_unknown=$true} $unknown
Test-P0Codec 'summary observation loss remains fatal after decode' {param($f) $f.summary.observation_loss=$true} $unknown
Test-P0Codec 'encoded impulse remains prohibited in P0 submit' {} $unknown {param($f) $f.rows[10].data.impulse=@(0,1,0)}
Test-P0Codec 'submit ABI remains unchanged after decode' {} $unknown {param($f) $f.rows[10].data.arity=2}
Test-P0Codec 'body mass mismatch stays unverified' {} {param($r) Assert-P0 ($r.flags.body -ceq 'unverified' -and $r.flags.neutral_receipt_ack -ceq 'unverified') 'Wrong mass reported after codec'} {param($f) $f.rows[2].data.mass=107}
Test-P0Codec 'missing projected button remains unverified' {} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'unverified') 'Codec inferred missing button'} {param($f) $f.rows[3].data.pad.buttons.Remove('y')}
Test-P0Codec 'wrong capture identity remains unverified' {} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'unverified') 'Codec bypassed capture identity'} {param($f) $f.rows[3].data.context_generation='99'}
Test-P0Codec 'Follow must still match fixed lease' {} {param($r) Assert-P0 ($r.flags.fixed_follow -ceq 'unverified') 'Codec bypassed fixed Follow identity'} {param($f) $f.rows[7].data.sequence='99'}
Test-P0Codec 'ACK ABI must remain exact' {} {param($r) Assert-P0 ($r.flags.neutral_receipt_ack -ceq 'unverified') 'Codec accepted wrong ACK ABI'} {param($f) $f.rows[12].data.arity=2}
Test-P0Codec 'pose send still needs positive sends' {} {param($r) Assert-P0 ($r.flags.pose_api -ceq 'unverified') 'Codec converted pose release into send'} {param($f) $f.rows[9].data.sends=0}
Test-P0Codec 'incomplete terminal debt remains unverified' {param($f) $f.latest.board_drop.Remove('restore_pending')} {param($r) Assert-P0 ($r.flags.terminal_cleanup -ceq 'unverified') 'Codec inferred missing restoration fact'}
$f=New-P0Fixture;$legacy=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin -EvidenceEncoding legacy-v1
Convert-P0FixtureCodec $f;$codec=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
Assert-P0 ((ConvertTo-Json $legacy.flags -Compress) -ceq (ConvertTo-Json $codec.flags -Compress)) 'Legacy versus decoded flags differ'
Assert-P0 ((ConvertTo-Json $legacy.counts -Compress) -ceq (ConvertTo-Json $codec.counts -Compress)) 'Legacy versus decoded P0 counts differ';$script:P0CodecCases++
foreach($mode in @('v3_as_legacy','null_as_legacy','legacy_chunk_v2')){
    $f=New-P0Fixture
    if($mode -ceq 'legacy_chunk_v2'){$f.document['hop.'+$script:Run+'.chunk.1'].schema=2}
    else{Convert-P0FixtureCodec $f;if($mode -ceq 'null_as_legacy'){$f.summary.encoding=$null}}
    $r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin -EvidenceEncoding legacy-v1
    Assert-P0Unknown $r;Assert-P0 ($r.issues.Count -gt 0) 'Explicit legacy accepted an encoded marker';$script:P0CodecCases++
}
# These intact historical rows/chunks would satisfy every P0 predicate if an
# accidental default-selector fallback were allowed. Keep the refusal observable.
foreach($marker in @('absent','unknown','null')){
    $f=New-P0Fixture
    if($marker -ceq 'unknown'){$f.summary['encoding']='hop-delta-v2'}elseif($marker -ceq 'null'){$f.summary['encoding']=$null}
    $r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
    Assert-P0Unknown $r;Assert-P0 ($r.issues.Count -gt 0) 'Default selector silently qualified actual legacy rows';$script:P0CodecCases++
}
foreach($selector in @('HOP-DELTA-V4','Hop-Delta-v4','LEGACY-V1','Legacy-v1')){
    $f=New-P0Fixture;$refused=$false
    try{$null=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin -EvidenceEncoding $selector}
    catch{$refused=$true;Assert-P0 ($_.FullyQualifiedErrorId -match '^ParameterArgumentValidationError') 'Selector failed for an unrelated reason'}
    Assert-P0 $refused 'Case-variant selector selected implicit legacy';$script:P0CodecCases++
}
# Literal profile4 accounting anchors: empty body wire48+22=70,
# state2048+2+64+6+2=2122; regular wire+state=2192.
$f=New-P0Fixture;$f.rows=@(@{kind='body';data=@{};first_call=1;last_call=1;repeats=1;incomplete=$false});Convert-P0FixtureCodec $f
Assert-P0 ($f.summary.regular_wire_bytes -eq 70 -and $f.summary.regular_state_bytes -eq 2122 -and $f.summary.regular_bytes -eq 2192) 'Independent fixture anchor arithmetic drifted'
$r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
Assert-P0 ($r.issues.Count -eq 0 -and $r.codec_accounting.regular_wire_bytes -eq 70 -and $r.codec_accounting.regular_state_bytes -eq 2122 -and $r.codec_accounting.regular_bytes -eq 2192 -and $r.codec_accounting.encoded_envelope_bytes -eq 203) 'Literal codec byte anchors differ';$script:P0CodecCases++
$f=New-P0Fixture;$f.rows=@(@{kind='body';data=@{};first_call=1;last_call=1;repeats=1;incomplete=$false;critical=$true});Convert-P0FixtureCodec $f
$r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
Assert-P0 ($r.issues.Count -eq 0 -and $r.codec_accounting.critical_bytes -eq 70 -and $r.codec_accounting.regular_bytes -eq 2048 -and $r.codec_accounting.regular_state_bytes -eq 2048) 'Critical row installed regular state';$script:P0CodecCases++
$f=New-P0Fixture;$f.rows=@(@{kind='body';data=@{};first_call=1;last_call=1;repeats=1;incomplete=$false},@{kind='body';data=@{};first_call=2;last_call=2;repeats=1;incomplete=$false});Convert-P0FixtureCodec $f
$f.wires[1][3]=1;$f.wires[1][10][0]=3;P0-TestUpdateCodecTotals $f
$r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
Assert-P0 ($r.issues.Count -eq 0 -and $r.codec_accounting.regular_wire_bytes -eq 140 -and $r.codec_accounting.regular_state_bytes -eq 2122 -and $r.codec_accounting.regular_bytes -eq 2262) 'Delta failed to replace one canonical projection state';$script:P0CodecCases++
$f=New-P0Fixture;$f.rows=[object[]]::new(137)
for($i=0;$i -lt 137;$i++){$f.rows[$i]=@{kind='body';data=@{};first_call=($i+1);last_call=($i+1);repeats=1;incomplete=$false}}
Convert-P0FixtureCodec $f -RowsPerChunk 1;$r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
Assert-P0 ($r.issues.Count -eq 0 -and $r.codec_accounting.regular_rows -eq 137) 'Valid short chunks hit old136 cap';$script:P0CodecCases++
$f=New-P0Fixture;Convert-P0FixtureCodec $f -RowsPerChunk 1
$f.document['hop.'+$script:Run+'.chunk.2'].schema=1;$r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
Assert-P0Unknown $r;Assert-P0 ($r.issues.Count -gt 0) 'Mixed-version stream silently downgraded';$script:P0CodecCases++
# Additional v4 regression groups below still return only recorded SDK facts.
foreach($profile in @('hop-delta-v2','hop-delta-v3')){
    $f=New-P0Fixture;Convert-P0FixtureCodec $f;$f.summary.encoding=$profile
    foreach($key in $f.document.Keys){if([string]$key -clike ('hop.'+$script:Run+'.chunk.*')){$f.document[$key].encoding=$profile}}
    $r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
    Assert-P0Unknown $r;Assert-P0 ($r.issues.Count -gt 0) 'Old/unknown complete profile was selected as v3';$script:P0CodecCases++
}
foreach($selector in @('hop-delta-v2','HOP-DELTA-V2')){
    $f=New-P0Fixture;$refused=$false
    try{$null=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin -EvidenceEncoding $selector}
    catch{$refused=$true;Assert-P0 ($_.FullyQualifiedErrorId -match '^ParameterArgumentValidationError') 'Old-profile selector failed for an unrelated reason'}
    Assert-P0 $refused 'New adapter accepted an old-v2 selector';$script:P0CodecCases++
}
# Exact two-endpoint x=0 with first_at=0,last_at=10: wire49+22=71,
# state2048+111=2159 and regular2230. Canonical numeric32 stays unchanged.
foreach($pair in @(@([double]0,49),@([double]-1,50),@([double]9007199254740992,64),@([double]-9007199254740992,65),@([double]9007199254740994,80),@([double]-9007199254740994,80),@([double]1.25,80),@([long]9007199254740993,80))){
    $f=New-P0Fixture;$f.rows=@(@{kind='body';data=@{x=$pair[0]};first_call=1;last_call=2;repeats=2;incomplete=$false;first_at_ms=0;last_at_ms=10});Convert-P0FixtureCodec $f
    Assert-P0 ($f.summary.regular_wire_bytes -eq ($pair[1]+22) -and $f.summary.regular_state_bytes -eq 2159) 'Independent signed numeric oracle differs'
    $r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
    Assert-P0 ($r.issues.Count -eq 0 -and $r.codec_accounting.regular_wire_bytes -eq ($pair[1]+22) -and $r.codec_accounting.regular_state_bytes -eq 2159 -and $r.codec_accounting.regular_bytes -eq ($pair[1]+22+2159)) 'v4 P0 wire/state accounting conflated widths or changed values';$script:P0CodecCases++
}
$f=New-P0Fixture;$f.rows=@(@{kind='body';data=@{x=0};first_call=1;last_call=2;repeats=2;incomplete=$false;critical=$true;first_at_ms=0;last_at_ms=10});Convert-P0FixtureCodec $f
$r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
Assert-P0 ($r.issues.Count -eq 0 -and $r.codec_accounting.critical_bytes -eq 71 -and $r.codec_accounting.regular_bytes -eq 2048 -and $r.codec_accounting.regular_state_bytes -eq 2048) 'v4 numeric critical anchor installed state or retained old wire cost';$script:P0CodecCases++
$f=New-P0Fixture;$f.rows=@(@{kind='body';data=@{x=0};first_call=1;last_call=1;repeats=1;incomplete=$false},@{kind='body';data=@{x=0};first_call=2;last_call=2;repeats=1;incomplete=$false});Convert-P0FixtureCodec $f
$delta=[object[]]::new(2);$delta[0]=3;$delta[1]=$false;$f.wires[1][3]=1;$f.wires[1][10]=$delta;P0-TestUpdateCodecTotals $f
$r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
Assert-P0 ($r.issues.Count -eq 0 -and $r.codec_accounting.regular_wire_bytes -eq 148 -and $r.codec_accounting.regular_state_bytes -eq 2159 -and $r.codec_accounting.regular_bytes -eq 2307) 'v4 delta failed to retain one canonical numeric projection';$script:P0CodecCases++
$f=New-P0Fixture;$f.rows=@(@{kind='body';data=@{x=0};first_call=1;last_call=2;repeats=2;incomplete=$false;first_at_ms=0;last_at_ms=10});Convert-P0FixtureCodec $f
$f.summary.regular_wire_bytes=141;$f.summary.regular_state_bytes=111;$f.summary.regular_bytes=252
$r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
Assert-P0Unknown $r;Assert-P0 (($r.issues -join '|') -match 'Codec byte accounting contradicts summary') 'Relabeled v2 numeric accounting passed as v3';$script:P0CodecCases++
$previousCulture=[Threading.Thread]::CurrentThread.CurrentCulture
try{
    $culture=[Globalization.CultureInfo]::InvariantCulture.Clone();$culture.NumberFormat.NegativeSign='minus';$culture.NumberFormat.NumberDecimalSeparator=','
    [Threading.Thread]::CurrentThread.CurrentCulture=$culture
    $f=New-P0Fixture;Convert-P0FixtureCodec $f;$r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
    & $allReported $r;Assert-P0 ($r.codec_accounting.regular_bytes -eq $f.summary.regular_bytes) 'P0 v4 replay used culture-sensitive widths';$script:P0CodecCases++
}finally{[Threading.Thread]::CurrentThread.CurrentCulture=$previousCulture}
$f=New-P0Fixture;Convert-P0FixtureCodec $f -RowsPerChunk 1;$f.document['hop.'+$script:Run+'.chunk.2'].encoding='hop-delta-v2'
$r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
Assert-P0Unknown $r;Assert-P0 ($r.issues.Count -gt 0) 'Mixed v3/v2 chunks were retried through an old profile';$script:P0CodecCases++
# Exercise the actual collection helper's TryGetInt64 path, not only typed
# fixtures. JSON2^53+1 must remain an exact Int64 and stay on32 wire bytes.
foreach($pair in @(@('9007199254740992',[long]9007199254740992,16),@('-9007199254740992',[long]-9007199254740992,17),@('9007199254740993',[long]9007199254740993,32),@('-9007199254740993',[long]-9007199254740993,32),@('9007199254740994',[long]9007199254740994,32),@('-9007199254740994',[long]-9007199254740994,32))){
    $document=[Text.Json.JsonDocument]::Parse($pair[0])
    try{$parsed=P0-EvDecode $document.RootElement @{nodes=0}}finally{$document.Dispose()}
    Assert-P0 ($parsed -is [long] -and $parsed -eq $pair[1] -and (Get-HopEvidenceNumericWireBytes $parsed) -eq $pair[2]) 'Parsed JSON Int64 boundary was rounded or mischarged'
    $f=New-P0Fixture;$f.rows=@(@{kind='body';data=@{x=$parsed};first_call=1;last_call=2;repeats=2;incomplete=$false;first_at_ms=0;last_at_ms=10});Convert-P0FixtureCodec $f
    $chunk=P0-EvField $f.document ('hop.'+$script:Run+'.chunk.1');$read=P0-EvReadCodec -Chunks @($chunk) -RunId $script:Run
    Assert-P0 ($read.rows[0].data['x'] -is [long] -and $read.rows[0].data['x'] -eq $pair[1]) 'P0 codec replay changed a parsed exact Int64 value'
    $r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
    Assert-P0 ($r.issues.Count -eq 0 -and $r.codec_accounting.regular_wire_bytes -eq (70+$pair[2]) -and $r.codec_accounting.regular_state_bytes -eq 2159) 'Parsed JSON boundary bypassed strict v4 P0 accounting';$script:P0CodecCases++
}
# Profile4 pair/chronology regressions. These remain source-owned SDK fixtures,
# not evidence that controller input was consumed or native retirement occurred.
function P0-NewKnownCapture{
    return @{call='input.lease_capture_state';arity=1;call_ok=$true;sequence='2';user=0;source_epoch='3';context_generation='4';phase='capturing';reason='none';terminal=$false;quarantined=$false;capturing=$true;report_debt=$true;generation='6';revision='7';expires_ms='1000';publications='1';neutral_releases='0'}
}
Test-P0Codec 'sealed pair captures retain active report debt and two exact known endpoints' {} {param($r)
    & $allReported $r;Assert-P0 ($r.counts.capture_samples -eq 2 -and $r.codec_accounting.regular_rows -eq 13) 'capture pair expanded rows or erased active debt'
} {param($f)
    $f.rows[1].data=P0-NewKnownCapture;$f.rows[1].last_call=4;$f.rows[1].repeats=2;$f.rows[1]['paired']=$true
    for($i=3;$i -lt $f.rows.Count;$i++){$f.rows[$i].first_call++;$f.rows[$i].last_call++}
}
Test-P0Codec 'known body endpoint after intervening body drives unchanged submit predicate' {} $allReported {param($f)
    $f.rows[2].last_call=12;$f.rows[2].repeats=2
    for($i=10;$i -lt $f.rows.Count;$i++){$f.rows[$i].first_call+=2;$f.rows[$i].last_call+=2}
    $other=@{};foreach($key in $f.rows[2].data.Keys){$other[$key]=$f.rows[2].data[$key]};$other.serial='99'
    $barrier=@{kind='body';data=$other;first_call=11;last_call=11;repeats=1;incomplete=$false}
    $f.rows=@($f.rows[0..9]) + @($barrier) + @($f.rows[10..12])
}
Test-P0Codec 'known endpoint collisions invalidate all flags after prior observations' {param($f)
    $f.wires[2][5]=5;$f.wires[2][6]=2;$f.rows[2].last_call=5;$f.rows[2].repeats=2;P0-TestUpdateCodecTotals $f
} {param($r) & $unknown $r;Assert-P0 (($r.issues -join '|') -match 'duplicate known endpoint') 'collision refused for unrelated reason'}
Test-P0Codec 'full legacy count309 remains opaque interior and never309 copied facts' {} {param($r)
    & $allReported $r;Assert-P0 ($r.counts.follow_samples -eq 2 -and $r.counts.prepare_ready -eq 1 -and $r.codec_accounting.regular_rows -eq 13) 'opaque count expanded or lost known endpoint'
} {param($f)
    $f.rows[7].last_call=316;$f.rows[7].repeats=309
    for($i=8;$i -lt $f.rows.Count;$i++){$f.rows[$i].first_call+=308;$f.rows[$i].last_call+=308}
}
$f=New-P0Fixture;$f.rows=@();Convert-P0FixtureCodec $f
$r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
Assert-P0 ($r.issues.Count -eq 0 -and $r.codec_accounting.regular_rows -eq 0 -and $r.codec_accounting.regular_wire_bytes -eq 0 -and $r.codec_accounting.regular_state_bytes -eq 2048 -and $r.codec_accounting.regular_bytes -eq 2048) 'empty profile4 omitted fixed reserve';$script:P0CodecCases++
$f=New-P0Fixture;$f.rows=@(@{kind='lease';data=(P0-NewKnownCapture);first_call=1;last_call=2;repeats=2;incomplete=$false;paired=$true});Convert-P0FixtureCodec $f
$r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
$ordinaryState=2048+(P0-TestDataCost $f.rows[0].data)+64+(P0-TestStringCost 'lease')+(P0-TestStringCost 'input.lease_capture_state')
Assert-P0 ($r.issues.Count -eq 0 -and $r.codec_accounting.regular_rows -eq 1 -and $r.codec_accounting.regular_state_bytes -eq $ordinaryState+256 -and $r.counts.capture_samples -eq 2) 'current paired state omitted conservative256 charge';$script:P0CodecCases++
$pairedWire=$f.summary.regular_wire_bytes
$f.rows+=@{kind='lease';data=$f.rows[0].data;first_call=3;last_call=3;repeats=1;incomplete=$false};Convert-P0FixtureCodec $f
$r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
Assert-P0 ($r.issues.Count -eq 0 -and $r.codec_accounting.regular_rows -eq 2 -and $r.codec_accounting.regular_state_bytes -eq $ordinaryState -and $r.codec_accounting.regular_wire_bytes -gt $pairedWire) 'ordinary replacement retained paired charge or erased prior wire';$script:P0CodecCases++
$f=New-P0Fixture;$f.rows=@(@{kind='lease';data=(P0-NewKnownCapture);first_call=1;last_call=2;repeats=2;incomplete=$false;paired=$true});Convert-P0FixtureCodec $f
$f.summary.regular_state_bytes-=224;$f.summary.regular_bytes-=224;$r=Get-P0EvidenceSummary $f.routes $script:Run $script:Plugin
Assert-P0Unknown $r;Assert-P0 (($r.issues -join '|') -match 'Codec byte accounting contradicts summary') 'old32 paired-state charge silently admitted';$script:P0CodecCases++
Test-P0Codec 'v4 refuses old eleven-slot rows without fallback' {param($f) $chunk=$f.document['hop.'+$script:Run+'.chunk.1'];$chunk.rows[0]=$f.wires[0][0..10]} $unknown
Test-P0Codec 'pair marker cannot manufacture capture completion or discharge active debt' {param($f) $f.wires[1][11]=$true} $unknown
[pscustomobject]@{suite='P0 evidence integral-wire-v4 successor';legacy_cases=$script:P0Cases;codec_cases=$script:P0CodecCases;status='PASS';native_gameplay='UNRUN'}
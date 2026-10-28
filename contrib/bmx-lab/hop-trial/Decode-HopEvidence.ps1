#requires -Version 7.5
# Pure consumer for the versioned private evidence wire. Dot-sourcing performs
# no IO. Legacy evidence belongs to the caller's explicitly selected old parser;
# malformed encoded input is never retried as unencoded evidence.
# Contract C3F6BE7DFBA89AC2815DD5C58139E482E330D3CA54CA93D9F578E5EA9CFE1B5C;
# static FIELDS.txt SHA256 0DDC1E87FE212DA9471238FB1165F3574197EB720A7D51AE763740A99689C2B3.
Set-StrictMode -Version Latest
$script:HopEvidenceFields=[Array]::AsReadOnly([string[]]@(
    '__index',
    '__mode',
    'a',
    'accounting_known',
    'ack',
    'ack_attempted',
    'acknowledge_attempted',
    'acknowledged',
    'active',
    'actor_lane',
    'angular_impulse',
    'angular_speed',
    'angular_velocity',
    'ankles',
    'arguments',
    'arity',
    'at_ms',
    'attempts',
    'b',
    'back',
    'balance_normal',
    'balance_normal_available',
    'base_ms',
    'bike_authority',
    'bike_cleanup_complete',
    'blend',
    'board_drop',
    'board_drop_inflight',
    'board_issue',
    'board_reason',
    'board_restore_inflight',
    'board_restore_pending',
    'board_restore_unresolved',
    'board_return',
    'board_state',
    'body',
    'bones_calls',
    'bones_result',
    'boolean',
    'brake',
    'budget_exhausted',
    'buttons',
    'call',
    'call_ok',
    'capability',
    'capture',
    'capture_reserved',
    'capture_state',
    'capturing',
    'center_of_mass',
    'chunk_bytes',
    'chunk_rows',
    'claim_known',
    'cleanup_disposition',
    'cleanup_pending',
    'cleanup_unknown',
    'clear_calls',
    'clear_result',
    'clock_unknown',
    'command_state',
    'common',
    'completed_acknowledged',
    'confirmed',
    'contact',
    'contact_scale',
    'context_generation',
    'controls',
    'critical_bytes',
    'critical_rows',
    'detail',
    'diagnostic',
    'diagnostic_only',
    'disposition',
    'down',
    'drop_inflight',
    'drop_ms',
    'ends',
    'epoch_matches',
    'equipment',
    'equipment_purpose',
    'event_schemas',
    'expires_ms',
    'final_native_epoch',
    'final_revision',
    'follow',
    'force',
    'force_applied',
    'force_attempted',
    'force_cleanup_clear',
    'force_cleanup_unknown',
    'force_model',
    'force_pending',
    'force_ready',
    'force_reason',
    'forward',
    'fraction',
    'generation',
    'grounded',
    'grounded_known',
    'handoff_unknown',
    'hips',
    'hop',
    'hop_applied',
    'hop_disposition',
    'hop_event_id',
    'hop_impulse',
    'hop_strength',
    'id',
    'identity',
    'impulse',
    'impulse_id',
    'in_flight',
    'inertia',
    'inertia_body',
    'input_ok',
    'issue',
    'item',
    'k',
    'known',
    'last_observation',
    'last_sent',
    'last_serial',
    'last_source_step',
    'lb',
    'lease',
    'lease_handle_present',
    'lease_state',
    'left',
    'left_stick',
    'left_trigger',
    'left_x',
    'left_y',
    'lifetime_ms',
    'lifetime_remaining_ms',
    'limit',
    'limits',
    'linear_impulse',
    'linear_velocity',
    'local_actor_excluded',
    'mapped_hop',
    'marker_unknown',
    'mass',
    'measurements_complete',
    'model',
    'model_body',
    'model_steps',
    'motion',
    'mount_deadline_ms',
    'mount_ms',
    'mounted_ms',
    'mounted_pose',
    'named_actor_categories_absent',
    'native_casts',
    'native_preparation',
    'native_retirement_known',
    'neutral',
    'neutral_releases',
    'new_observation',
    'nil_accepted',
    'nil_calls',
    'normal',
    'normal_available',
    'number',
    'observation_serial',
    'observed_ms',
    'observed_steps',
    'ordinary_release_accepted',
    'ordinary_release_attempted',
    'orientation',
    'orphaned',
    'out',
    'outcome',
    'owned_bodies_excluded',
    'packet',
    'pad',
    'park_observed',
    'park_reason',
    'pedal',
    'pending',
    'pending_commands',
    'pending_count',
    'pending_hop',
    'pending_limit',
    'pending_sequence',
    'phase',
    'plan',
    'playstation',
    'point',
    'pose',
    'pose_plan',
    'pose_release_unresolved',
    'position',
    'preparation',
    'prepare',
    'preview',
    'preview_model',
    'produced_serial',
    'provenance',
    'publications',
    'qualified',
    'qualified_transition',
    'quarantined',
    'query',
    'radius',
    'ray',
    'rays',
    'rb',
    'ready_ms',
    'reason',
    'receipt',
    'regular_bytes',
    'regular_rows',
    'remaining_ms',
    'renewable',
    'renewal_ms',
    'renewals',
    'report_debt',
    'requested_ms',
    'requested_query_preset',
    'requested_serial',
    'reserve_unknown',
    'restore_inflight',
    'restore_ms',
    'restore_pending',
    'restore_tried',
    'result',
    'retained',
    'retained_reload_marker',
    'returned_revision',
    'revision',
    'revocation',
    'ride',
    'right',
    'right_stick',
    'right_trigger',
    'right_x',
    'right_y',
    'rotation',
    'rotation_reserved',
    'row_bytes',
    'sample',
    'samples',
    'scope',
    'seconds',
    'selected_slot',
    'sends',
    'sent_ticks',
    'separation',
    'sequence',
    'serial',
    'source',
    'source_epoch',
    'source_released',
    'source_state',
    'spawn',
    'start',
    'state',
    'states',
    'status',
    'steer',
    'stock_requested',
    'stock_toggle_blocked',
    'stop_latched',
    'stop_ms',
    'stop_reason',
    'stop_requested',
    'stopped',
    'storage_fault',
    'strength',
    'submit',
    'submitted',
    'subordinate',
    'successor',
    'successor_available',
    'summary_bytes',
    'support',
    'surface_velocity',
    'surface_velocity_available',
    'table',
    'terminal',
    'terminal_receipt',
    'terminal_schema',
    'text',
    'text_bytes',
    'ticks',
    'time',
    'torque',
    'torque_attempted',
    'toss_calls',
    'toss_result',
    'trick_scope',
    'tried',
    'unknown',
    'unloaded',
    'unresolved_debt',
    'up',
    'user',
    'v',
    'valid',
    'vec3',
    'vec4',
    'velocity',
    'verified_plane',
    'visual_cleanup_deferred',
    'visual_hit',
    'wall_ms',
    'weight',
    'wheel',
    'wheel_contact',
    'wheel_sample',
    'wheels',
    'wrists',
    'x',
    'y'
))
$script:HopEvidenceKinds=[Array]::AsReadOnly([string[]]@('source','body','contact','force_pending','mapped_hop','preview','submit','receipt','ack','pose','follow','lease','prepare','terminal'))
function Assert-HopEvidence([bool]$Condition,[string]$Reason){if(-not $Condition){throw ('Hop evidence: '+$Reason)}}
function Test-HopEvidenceList($Value){
    return $Value -is [Collections.IList] -and $Value -isnot [string] -and
        ($Value -isnot [Array] -or ($Value.Rank -eq 1 -and $Value.GetLowerBound(0) -eq 0))
}
function Test-HopEvidenceNumber($Value){
    return ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) -and
        -not [double]::IsNaN([double]$Value) -and -not [double]::IsInfinity([double]$Value)
}
function Test-HopEvidenceInteger($Value,[long]$Minimum,[long]$Maximum){
    return (Test-HopEvidenceNumber $Value) -and [double]$Value -ge $Minimum -and [double]$Value -le $Maximum -and
        [double]$Value -eq [Math]::Floor([double]$Value)
}
function Get-HopEvidenceStringBytes([string]$Value){
    try{$bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes($Value)}
    catch{throw 'Hop evidence: text is not valid UTF-8'}
    Assert-HopEvidence ($bytes.Length -le 192) 'text exceeds 192 UTF-8 bytes'
    [long]$cost=2
    foreach($b in $bytes){$cost+=$(if($b -lt 32 -or $b -eq 34 -or $b -eq 92 -or $b -ge 127){6}else{1})}
    return $cost
}
# Match plugin_api.cpp's int64 JSON branch for already finite numeric values.
# Inspect exact integral/Decimal inputs before Double conversion: otherwise an
# out-of-profile Int64 value 2^53+1 could round into the inclusive cheap boundary.
# Canonical DATA/state sizing still charges 32 bytes for every number.
function Get-HopEvidenceNumericWireBytes($Value){
    Assert-HopEvidence (Test-HopEvidenceNumber $Value) 'numeric wire value must be finite'
    if($Value -is [double] -or $Value -is [single]){
        $number=[double]$Value
        if([Math]::Abs($number) -le 9007199254740992.0 -and [Math]::Floor($number) -eq $number){
            return ([long]$number).ToString([Globalization.CultureInfo]::InvariantCulture).Length
        }
    }else{
        $exact=[decimal]$Value
        if($exact -ge -9007199254740992D -and $exact -le 9007199254740992D -and [decimal]::Truncate($exact) -eq $exact){
            return ([long]$exact).ToString([Globalization.CultureInfo]::InvariantCulture).Length
        }
    }
    return 32L
}
function Get-HopEvidenceDigits([long]$Value){return $Value.ToString([Globalization.CultureInfo]::InvariantCulture).Length}
function Assert-HopEvidenceKeys($Value,[string[]]$Keys){
    Assert-HopEvidence ($Value -is [Collections.IDictionary] -and $Value.Count -eq $Keys.Count) 'envelope keys differ'
    foreach($k in $Value.Keys){Assert-HopEvidence ($k -is [string] -and $k -cin $Keys) 'unknown or wrongly cased envelope key'}
}
function Get-HopEvidenceField($Value,[string]$Key){
    foreach($k in $Value.Keys){if($k -is [string] -and $k -ceq $Key){return ,$Value[$k]}}
    throw ('Hop evidence: missing field '+$Key)
}
function Copy-HopEvidenceTable($Value){
    $copy=[Collections.Generic.Dictionary[object,object]]::new()
    foreach($key in $Value.Keys){$v=$Value[$key];if($v -is [Collections.IDictionary]){$v=Copy-HopEvidenceTable $v};$copy.Add($key,$v)}
    return ,$copy
}
function Get-HopEvidenceDataMeasure($Value,$Budget,[int]$Depth=0){
    Assert-HopEvidence ($Depth -le 32) 'expanded data depth exceeds 32'
    $Budget.nodes++
    Assert-HopEvidence ($Budget.nodes -le 768) 'expanded data exceeds 768 nodes'
    if($Value -is [Collections.IDictionary]){
        [long]$cost=2
        foreach($key in $Value.Keys){
            $Budget.nodes++;Assert-HopEvidence ($Budget.nodes -le 768) 'expanded data exceeds 768 nodes'
            $name=$(if($key -is [string]){$key}else{([int]$key).ToString([Globalization.CultureInfo]::InvariantCulture)})
            $cost+=$name.Length+4
            $cost+=Get-HopEvidenceDataMeasure $Value[$key] $Budget ($Depth+1)
            Assert-HopEvidence ($cost -le 11904) 'expanded data exceeds 11904 bytes'
        }
        return $cost
    }
    if($Value -is [string]){return (Get-HopEvidenceStringBytes $Value)}
    if($Value -is [bool]){return 5L}
    Assert-HopEvidence (Test-HopEvidenceNumber $Value) 'unsupported expanded scalar'
    return 32L
}
function ConvertTo-HopEvidencePublicValue($Value){
    if($Value -isnot [Collections.IDictionary]){return ,$Value}
    $dense=$Value.Count -gt 0
    foreach($key in $Value.Keys){if($key -isnot [int] -or $key -lt 1 -or $key -gt $Value.Count){$dense=$false;break}}
    if($dense){
        $items=[object[]]::new($Value.Count)
        for($i=1;$i -le $Value.Count;$i++){$items[$i-1]=ConvertTo-HopEvidencePublicValue $Value[$i]}
        return ,$items
    }
    $map=[Collections.Generic.Dictionary[object,object]]::new()
    foreach($key in $Value.Keys){$map.Add($key,(ConvertTo-HopEvidencePublicValue $Value[$key]))}
    return ,$map
}
function Read-HopEvidenceNode($Node,$Base,[bool]$HasBase,$Active,[int]$Depth=0){
    Assert-HopEvidence ($Depth -le 32) 'wire depth exceeds 32'
    Assert-HopEvidence (4+3*$Depth -le 32) 'wire exceeds SDK JSON nesting depth'
    Assert-HopEvidence ((Test-HopEvidenceList $Node) -and $Node.Count -ge 1 -and $Node.Count -le 2) 'node arity differs'
    Assert-HopEvidence ($Active.Add($Node)) 'wire contains a cycle'
    try{
        Assert-HopEvidence (Test-HopEvidenceInteger $Node[0] 0 4) 'unknown node tag'
        $tag=[int]$Node[0]
        if($tag -eq 0){throw 'Hop evidence: deletion outside an existing delta key'}
        if($tag -eq 4){
            Assert-HopEvidence ($Node.Count -eq 1) 'negative-zero node arity differs'
            return @{value=[BitConverter]::Int64BitsToDouble([long]::MinValue);wire_bytes=3L}
        }
        Assert-HopEvidence ($Node.Count -eq 2) 'node arity differs'
        if($tag -eq 1){
            $v=$Node[1]
            if($v -is [string]){$cost=Get-HopEvidenceStringBytes $v}
            elseif($v -is [bool]){$cost=5L}
            else{Assert-HopEvidence (Test-HopEvidenceNumber $v) 'unsupported scalar';Assert-HopEvidence ($v -ne 0 -or [BitConverter]::DoubleToInt64Bits([double]$v) -ne [long]::MinValue) 'negative zero requires tag 4';$cost=Get-HopEvidenceNumericWireBytes $v}
            return @{value=$v;wire_bytes=(4L+$cost)}
        }
        if($Node[1] -is [bool]){
            Assert-HopEvidence (-not $Node[1]) 'empty table sentinel must be false'
            $pairs=[object[]]::new(0)
        }else{
            Assert-HopEvidence ((Test-HopEvidenceList $Node[1]) -and $Node[1].Count -ge 1 -and $Node[1].Count -le 346) 'table pairs differ or use a noncanonical empty array'
            $pairs=$Node[1]
        }
        if($tag -eq 3){Assert-HopEvidence ($HasBase -and $Base -is [Collections.IDictionary]) 'delta requires an existing table';$value=Copy-HopEvidenceTable $Base}
        else{$value=[Collections.Generic.Dictionary[object,object]]::new()}
        [long]$cost=$(if($pairs.Count -eq 0){9}else{6})
        $previous=-2147483648
        $pairCount=0
        if($pairs.Count -gt 0){Assert-HopEvidence ($Active.Add($pairs)) 'wire contains a cycle'}
        try{
            foreach($pair in $pairs){
                Assert-HopEvidence ((Test-HopEvidenceList $pair) -and $pair.Count -eq 2) 'pair arity differs'
                Assert-HopEvidence ($Active.Add($pair)) 'wire contains a cycle'
                try{
                    $token=$pair[0]
                    Assert-HopEvidence ((Test-HopEvidenceInteger $token -32 314) -and $token -ne 0 -and $token -gt $previous) 'invalid, duplicate or unsorted key token'
                    $previous=[int]$token
                    $key=$(if($token -gt 0){$script:HopEvidenceFields[[int]$token-1]}else{[int](-$token)})
                    $child=$pair[1]
                    Assert-HopEvidence (4+3*($Depth+1) -le 32) 'wire exceeds SDK JSON nesting depth'
                    Assert-HopEvidence ((Test-HopEvidenceList $child) -and $child.Count -ge 1) 'child node is malformed'
                    Assert-HopEvidence (Test-HopEvidenceInteger $child[0] 0 4) 'unknown child tag'
                    if([int]$child[0] -eq 0){
                        Assert-HopEvidence ($tag -eq 3 -and $child.Count -eq 1 -and $value.ContainsKey($key)) 'deletion requires an existing delta key'
                        $null=$value.Remove($key);$childCost=3L
                    }else{
                        $exists=$value.ContainsKey($key)
                        if($tag -eq 2){Assert-HopEvidence ([int]$child[0] -ne 3) 'full table contains a delta'}
                        $baseChild=$(if($exists){$value[$key]}else{$null})
                        $decoded=Read-HopEvidenceNode $child $baseChild ($tag -eq 3 -and $exists) $Active ($Depth+1)
                        $value[$key]=$decoded.value;$childCost=[long]$decoded.wire_bytes
                    }
                    if($pairCount -gt 0){$cost++};$pairCount++
                    $cost+=3+(Get-HopEvidenceDigits ([long]$token))+$childCost
                    Assert-HopEvidence ($cost -le 12288) 'encoded node exceeds row bound'
                }finally{$null=$Active.Remove($pair)}
            }
        }finally{if($pairs.Count -gt 0){$null=$Active.Remove($pairs)}}
        return @{value=$value;wire_bytes=$cost}
    }finally{$null=$Active.Remove($Node)}
}
function Read-HopEvidenceChunks {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Chunks,[Parameter(Mandatory)][string]$RunId)
    Assert-HopEvidence ($RunId -cmatch '^[A-Za-z0-9_-]{1,32}$') 'run identity differs'
    Assert-HopEvidence ($Chunks.Count -le 2176) 'chunk count exceeds 2176'
    $rows=[Collections.Generic.List[object]]::new()
    $bases=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    [long]$regularWire=0;[long]$criticalWire=0;[long]$stateBytes=0;[long]$envelopeBytes=2
    [long]$expandedBytes=0;[long]$priorFirst=0
    $regular=0;$critical=0;$expectedChunk=1
    foreach($chunk in $Chunks){
        Assert-HopEvidenceKeys $chunk @('schema','encoding','run_id','chunk','rows')
        $schema=Get-HopEvidenceField $chunk 'schema';$encoding=Get-HopEvidenceField $chunk 'encoding';$run=Get-HopEvidenceField $chunk 'run_id';$number=Get-HopEvidenceField $chunk 'chunk';$wireRows=Get-HopEvidenceField $chunk 'rows'
        Assert-HopEvidence ((Test-HopEvidenceInteger $schema 2 2) -and $encoding -is [string] -and $encoding -ceq 'hop-delta-v3') 'unsupported schema or encoding; no legacy fallback'
        Assert-HopEvidence ($run -is [string] -and $run -ceq $RunId -and (Test-HopEvidenceInteger $number $expectedChunk $expectedChunk)) 'run or contiguous chunk identity differs'
        Assert-HopEvidence ((Test-HopEvidenceList $wireRows) -and $wireRows.Count -ge 1 -and $wireRows.Count -le 16) 'chunk requires 1..16 rows'
        [long]$chunkWire=0
        foreach($wire in $wireRows){
            Assert-HopEvidence ((Test-HopEvidenceList $wire) -and $wire.Count -eq 11) 'row requires eleven dense slots'
            Assert-HopEvidence ($wire[0] -is [bool] -and $wire[9] -is [bool]) 'critical/incomplete flags require booleans'
            Assert-HopEvidence (Test-HopEvidenceInteger $wire[1] 1 14) 'unknown kind'
            $kind=$script:HopEvidenceKinds[[int]$wire[1]-1]
            $projection=$wire[2];Assert-HopEvidence ($projection -is [string]) 'projection requires a string';$projectionCost=Get-HopEvidenceStringBytes $projection
            foreach($slot in @(3,4,5,6)){Assert-HopEvidence (Test-HopEvidenceInteger $wire[$slot] $(if($slot -eq 3){0}else{1}) 10000000) 'call/reference/count bound differs'}
            $baseFirst=[long]$wire[3];$first=[long]$wire[4];$last=[long]$wire[5];$repeats=[long]$wire[6]
            Assert-HopEvidence ($first -gt $priorFirst -and $last -ge $first -and $repeats -le $last-$first+1) 'occurrence order or range differs'
            foreach($slot in @(7,8)){
                $time=$wire[$slot]
                $numberTime=(Test-HopEvidenceNumber $time) -and $time -ge 0 -and
                    ($time -ne 0 -or [BitConverter]::DoubleToInt64Bits([double]$time) -ne [long]::MinValue)
                Assert-HopEvidence (($time -is [bool] -and -not $time) -or ($time -is [string] -and $time -ceq '-0') -or $numberTime) 'timestamp requires a nonnegative number, negative-zero string or false sentinel'
            }
            $key=([int]$wire[1]).ToString([Globalization.CultureInfo]::InvariantCulture)+':'+$projection
            $prior=$null
            if($wire[0]){Assert-HopEvidence ($baseFirst -eq 0) 'critical rows cannot reference regular state'}
            if($baseFirst -ne 0){
                Assert-HopEvidence ($baseFirst -lt $first -and $bases.ContainsKey($key)) 'missing, forward or cross-projection base'
                $prior=$bases[$key];Assert-HopEvidence ($prior.first_call -eq $baseFirst) 'base skipped the last regular occurrence'
            }
            Assert-HopEvidence ((Test-HopEvidenceList $wire[10]) -and $wire[10].Count -ge 1) 'root node is malformed'
            Assert-HopEvidence (($baseFirst -eq 0 -and (Test-HopEvidenceInteger $wire[10][0] 2 2)) -or ($baseFirst -ne 0 -and (Test-HopEvidenceInteger $wire[10][0] 2 3))) 'root data requires a full table or bound table delta'
            $active=[Collections.Generic.HashSet[object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
            $baseData=$(if($prior){$prior.data}else{$null})
            $decoded=Read-HopEvidenceNode $wire[10] $baseData ($null -ne $prior) $active
            $data=$decoded.value;Assert-HopEvidence ($data -is [Collections.IDictionary]) 'root data is not a table'
            if($data.ContainsKey('call')){Assert-HopEvidence ($data['call'] -is [string] -and $data['call'] -ceq $projection) 'projection does not match reconstructed call'}
            else{Assert-HopEvidence ($projection -ceq '') 'projection is missing its reconstructed call'}
            $measure=@{nodes=0};[long]$dataBytes=Get-HopEvidenceDataMeasure $data $measure
            Assert-HopEvidence ($dataBytes -le 11904) 'expanded data exceeds 11904 bytes'
            [long]$wireCost=12+5+(Get-HopEvidenceDigits ([long]$wire[1]))+$projectionCost+5+[long]$decoded.wire_bytes
            foreach($slot in @(3,4,5,6)){$wireCost+=Get-HopEvidenceDigits ([long]$wire[$slot])}
            foreach($slot in @(7,8)){$wireCost+=$(if($wire[$slot] -is [bool]){5}elseif($wire[$slot] -is [string]){4}else{Get-HopEvidenceNumericWireBytes $wire[$slot]})}
            Assert-HopEvidence ($wireCost -le 12288) 'encoded row exceeds 12288 bytes'
            $chunkWire+=$wireCost;Assert-HopEvidence (1024+$chunkWire -le 24576) 'encoded chunk exceeds 24576 bytes'
            if($wire[0]){$critical++;$criticalWire+=$wireCost;Assert-HopEvidence ($critical -le 128 -and $criticalWire -le 131072) 'critical stream capacity exceeded'}
            else{
                $regular++;$regularWire+=$wireCost
                if($bases.ContainsKey($key)){$stateBytes-=[long]$bases[$key].cost}else{Assert-HopEvidence ($bases.Count -lt 64) 'projection state exceeds 64 bases'}
                $cost=$dataBytes+64+(Get-HopEvidenceStringBytes $kind)+$projectionCost
                $bases[$key]=@{first_call=$first;data=$data;cost=$cost};$stateBytes+=$cost
                Assert-HopEvidence ($regular -le 2048 -and $regularWire+$stateBytes -le 524288) 'regular wire and canonical state capacity exceeded'
            }
            $expandedBytes+=$dataBytes;Assert-HopEvidence ($expandedBytes -le 2176L*12288) 'total expanded output bound exceeded'
            $row=[ordered]@{kind=$kind;data=(ConvertTo-HopEvidencePublicValue $data);first_call=$first;last_call=$last;repeats=$repeats;incomplete=$wire[9];critical=$wire[0]}
            if($wire[7] -isnot [bool]){$row.first_at_ms=$(if($wire[7] -is [string]){[BitConverter]::Int64BitsToDouble([long]::MinValue)}else{$wire[7]})};if($wire[8] -isnot [bool]){$row.last_at_ms=$(if($wire[8] -is [string]){[BitConverter]::Int64BitsToDouble([long]::MinValue)}else{$wire[8]})}
            $rows.Add($row);$priorFirst=$first
        }
        # Bound the provided encoded documents and their storage-key wrappers.
        # The complete SDK store and summary are outside this function's input.
        $arrayBytes=2+($wireRows.Count-1)+$chunkWire
        $envelope=2+('schema'.Length+4)+1+('encoding'.Length+4)+(Get-HopEvidenceStringBytes 'hop-delta-v3')+
            ('run_id'.Length+4)+(Get-HopEvidenceStringBytes $RunId)+('chunk'.Length+4)+(Get-HopEvidenceDigits $expectedChunk)+('rows'.Length+4)+$arrayBytes
        $storageKey='hop.'+$RunId+'.chunk.'+$expectedChunk
        $envelopeBytes+=$storageKey.Length+4+$envelope
        Assert-HopEvidence ($envelopeBytes -le 1048576) 'aggregate encoded envelopes exceed 1 MiB'
        $expectedChunk++
    }
    return ,([ordered]@{rows=$rows.ToArray();encoding='hop-delta-v3'})
}
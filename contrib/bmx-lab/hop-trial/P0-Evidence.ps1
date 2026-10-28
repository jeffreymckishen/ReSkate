#requires -Version 7.5
# Source-only strict-v4 successor; not an operator or execution grant.
# Root6's closed source seal must include the exact adjacent decoder dependency:
# 04A90D3A93C9666F44C83B19B604ADF4D04DF1AFCB8596D34EAAD871F01ABB90.
. (Join-Path $PSScriptRoot 'Decode-HopEvidence.ps1')
# Contract: Copy-P0Evidence reads THREE supplied storage.json paths, writes only
# fresh bounded raw snapshots under Destination, and returns {routes,summary}.
# Get-P0EvidenceSummary is pure: Routes contain source, namespace, state, sha256,
# short_read, changed_during_read and document. Flags mean recorded API evidence,
# never visual/native qualification. Missing/conflicting/lost evidence stays unverified.
function P0-EvField($Map,[string]$Name){
    if($Map -is [Collections.IDictionary]){foreach($key in $Map.Keys){if([string]$key -ceq $Name){return ,$Map[$key]}}}
    return $null
}
function P0-EvBool($Map,[string]$Name,[bool]$Expected){$v=P0-EvField $Map $Name;return ($v -is [bool] -and $v -eq $Expected)}
function P0-EvNumber($Value){
    return ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) -and
        -not [double]::IsNaN([double]$Value) -and -not [double]::IsInfinity([double]$Value)
}
function P0-EvInt($Value,[long]$Min,[long]$Max){return (P0-EvNumber $Value) -and [double]$Value -ge $Min -and [double]$Value -le $Max -and [double]$Value -eq [Math]::Floor([double]$Value)}
function P0-EvId($Value){$n=0UL;return $Value -is [string] -and $Value -cmatch '^[0-9]{1,20}$' -and [UInt64]::TryParse($Value,[ref]$n)}
function P0-EvArray($Value){return $Value -is [Collections.IList] -and $Value -isnot [string]}
function P0-EvVector($Value,[int]$Size){
    if(-not(P0-EvArray $Value) -or $Value.Count -ne $Size){return $false}
    foreach($n in $Value){if(-not(P0-EvNumber $n)){return $false}};return $true
}
function P0-EvBody($Data){
    return (P0-EvId (P0-EvField $Data 'serial')) -and (P0-EvVector (P0-EvField $Data 'position') 3) -and
        (P0-EvVector (P0-EvField $Data 'velocity') 3) -and (P0-EvVector (P0-EvField $Data 'rotation') 4) -and
        (P0-EvVector (P0-EvField $Data 'angular_velocity') 3) -and (P0-EvVector (P0-EvField $Data 'inertia') 3) -and
        (P0-EvNumber (P0-EvField $Data 'time')) -and (P0-EvField $Data 'time') -ge 0 -and
        (P0-EvNumber (P0-EvField $Data 'seconds')) -and (P0-EvField $Data 'seconds') -eq .01666666567325592 -and
        (P0-EvNumber (P0-EvField $Data 'mass')) -and (P0-EvField $Data 'mass') -eq 106
}
# lease_source.sample_copy and capture_copy share bound_matches(user, sequence,
# source_epoch, context_generation); capture generation is a different counter.
function P0-EvStream($Data){
    $parts=@();foreach($n in @('sequence','source_epoch','context_generation')){$v=P0-EvField $Data $n;if(-not(P0-EvId $v) -or [UInt64]$v -eq 0){return $null};$parts+=$v}
    $user=P0-EvField $Data 'user';if(-not(P0-EvInt $user 0 3)){return $null};return (($parts+@([string]$user)) -join ':')
}
# ride_input_mapping.source_record exports the original pad, not neutral/input_ok.
# A complete exact-zero projection is sufficient for this recorded neutral fact;
# optional native/cache facts may contradict it but cannot replace missing pad data.
function P0-EvZeroPad($Data){
    $pad=P0-EvField $Data 'pad';$buttons=P0-EvField $pad 'buttons'
    if(-not(P0-EvBool $pad 'playstation' $false)){return $false}
    foreach($n in @('left_x','left_y','right_x','right_y','left_trigger','right_trigger')){if(-not(P0-EvNumber (P0-EvField $pad $n)) -or (P0-EvField $pad $n) -ne 0){return $false}}
    foreach($n in @('up','down','left','right','start','back','left_stick','right_stick','lb','rb','a','b','x','y')){if(-not(P0-EvBool $buttons $n $false)){return $false}}
    return $true
}
function P0-EvPlain([string]$Path){
    if(-not[IO.Path]::IsPathFullyQualified($Path) -or [IO.Path]::GetFullPath($Path) -cne $Path){throw 'Evidence path must be canonical and absolute'}
    $part=$Path
    while($part){if(Test-Path -LiteralPath $part){if(((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Evidence path has a reparse ancestor'}};$next=[IO.Path]::GetDirectoryName($part);if($next -ceq $part){break};$part=$next}
}
function P0-EvDecode($Element,$Budget,[int]$Depth=0){
    $Budget.nodes++;if($Depth -gt 32 -or $Budget.nodes -gt 200000){throw 'Evidence JSON structural bound exceeded'}
    switch($Element.ValueKind.ToString()){
        'Object' {
            $map=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
            foreach($p in $Element.EnumerateObject()){
                if($map.ContainsKey($p.Name)){throw 'Duplicate JSON property refused'}
                $map.Add($p.Name,(P0-EvDecode $p.Value $Budget ($Depth+1)))
            }
            return ,$map
        }
        'Array' {$items=[Collections.Generic.List[object]]::new();foreach($item in $Element.EnumerateArray()){$items.Add((P0-EvDecode $item $Budget ($Depth+1)))};return ,($items.ToArray())}
        'String' {return $Element.GetString()}
        'Number' {$n=0L;if($Element.TryGetInt64([ref]$n)){return $n};$d=$Element.GetDouble();if(-not(P0-EvNumber $d)){throw 'Nonfinite JSON number'};return $d}
        'True' {return $true}
        'False' {return $false}
        'Null' {return $null}
        default {throw 'Unsupported evidence JSON token'}
    }
}
function P0-EvHasField($Map,[string]$Name){
    if($Map -is [Collections.IDictionary]){foreach($key in $Map.Keys){if($key -is [string] -and $key -ceq $Name){return $true}}}
    return $false
}
# The decoder's public dense arrays are converted back only for canonical-state
# byte measurement. This is not another decoder and cannot admit wire input.
function P0-EvCodecCanonical($Value){
    if($Value -is [Collections.IDictionary]){
        $out=[Collections.Generic.Dictionary[object,object]]::new()
        foreach($key in $Value.Keys){$out.Add($key,(P0-EvCodecCanonical $Value[$key]))};return ,$out
    }
    if(P0-EvArray $Value){
        $out=[Collections.Generic.Dictionary[object,object]]::new()
        for($i=0;$i -lt $Value.Count;$i++){$out.Add(($i+1),(P0-EvCodecCanonical $Value[$i]))};return ,$out
    }
    return ,$Value
}
# Called only after the pinned strict decoder accepted the entire stream.
function P0-EvCodecNodeCost($Node){
    $tag=[int]$Node[0]
    if($tag -eq 0 -or $tag -eq 4){return 3L}
    if($tag -eq 1){$v=$Node[1];return (4L+$(if($v -is [string]){Get-HopEvidenceStringBytes $v}elseif($v -is [bool]){5L}else{Get-HopEvidenceNumericWireBytes $v}))}
    if($Node[1] -is [bool]){return 9L}
    [long]$cost=6;[int]$count=0
    foreach($pair in $Node[1]){if($count -gt 0){$cost++};$count++;$cost+=3+(Get-HopEvidenceDigits ([long]$pair[0]))+(P0-EvCodecNodeCost $pair[1])}
    return $cost
}
function P0-EvReadCodec([object[]]$Chunks,[string]$RunId){
    # No fallback, partial output or fact promotion: validation precedes all
    # accounting, and P0's original semantic predicates run afterward.
    $decoded=Read-HopEvidenceChunks -Chunks $Chunks -RunId $RunId
    $states=[Collections.Generic.Dictionary[string,long]]::new([StringComparer]::Ordinal)
    [long]$regularWire=0;[long]$stateBytes=2048;[long]$criticalWire=0;[long]$store=2
    $regular=0;$critical=0;$rowIndex=0
    foreach($chunk in $Chunks){
        $wireRows=P0-EvField $chunk 'rows';[long]$chunkWire=0
        foreach($wire in $wireRows){
            $row=$decoded.rows[$rowIndex];$rowIndex++
            [long]$cost=22+12+5+(Get-HopEvidenceDigits ([long]$wire[1]))+(Get-HopEvidenceStringBytes $wire[2])+5+(P0-EvCodecNodeCost $wire[10])
            foreach($slot in @(3,4,5,6)){$cost+=Get-HopEvidenceDigits ([long]$wire[$slot])}
            foreach($slot in @(7,8)){$cost+=$(if($wire[$slot] -is [bool]){5}elseif($wire[$slot] -is [string]){4}else{Get-HopEvidenceNumericWireBytes $wire[$slot]})}
            $chunkWire+=$cost
            if($wire[0]){$critical++;$criticalWire+=$cost}
            else{
                $regular++;$regularWire+=$cost
                $key=([int]$wire[1]).ToString([Globalization.CultureInfo]::InvariantCulture)+':'+$wire[2]
                $canonical=P0-EvCodecCanonical $row.data
                [long]$state=(Get-HopEvidenceDataMeasure $canonical @{nodes=0})+64+(Get-HopEvidenceStringBytes $row.kind)+(Get-HopEvidenceStringBytes $wire[2])+$(if($wire[11]){256}else{0})
                if($states.ContainsKey($key)){$stateBytes-=$states[$key]};$states[$key]=$state;$stateBytes+=$state
            }
        }
        $index=P0-EvField $chunk 'chunk'
        $envelope=2+('schema'.Length+4)+1+('encoding'.Length+4)+(Get-HopEvidenceStringBytes 'hop-delta-v4')+
            ('run_id'.Length+4)+(Get-HopEvidenceStringBytes $RunId)+('chunk'.Length+4)+(Get-HopEvidenceDigits $index)+('rows'.Length+4)+2+($wireRows.Count-1)+$chunkWire
        # Match Recorder.Codec.envelope_bytes, including quoted-key allowance.
        # This reserves its summary budget; it does not prove other SDK keys or
        # disk persistence, which remain outside these supplied chunk documents.
        $store+=$envelope+(Get-HopEvidenceStringBytes ('hop.'+$RunId+'.chunk.'+$index))+4
    }
    if($store+16384 -gt 1048576){throw 'Encoded chunks plus reserved summary exceed the recorder private store budget'}
    return @{rows=$decoded.rows;accounting=[ordered]@{regular_rows=$regular;critical_rows=$critical;regular_wire_bytes=$regularWire;regular_state_bytes=$stateBytes;regular_bytes=($regularWire+$stateBytes);critical_bytes=$criticalWire;encoded_envelope_bytes=$store;summary_reserve_bytes=16384}}
}
function Get-P0EvidenceSummary([object[]]$Routes,[string]$RunId,[string]$PluginId,[ValidateSet('hop-delta-v4','legacy-v1',IgnoreCase=$false)][string]$EvidenceEncoding='hop-delta-v4'){
    $flags=[ordered]@{preparation='unverified';input_capture='unverified';body='unverified';contact='unverified';fixed_follow='unverified';pose_api='unverified';neutral_receipt_ack='unverified';terminal_cleanup='unverified'}
    $issues=[Collections.Generic.List[string]]::new();$present=[Collections.Generic.List[object]]::new();$rows=[Collections.Generic.List[object]]::new()
    $counts=[ordered]@{prepare_ready=0;capture_samples=0;body_samples=0;contact_samples=0;fixed_leases=0;follow_samples=0;pose_accepts=0;pose_sent=0;submits=0;applied_successors=0;acks=0}
    $result=[ordered]@{schema=1;kind='P0-recorded-evidence-review';run_id=$RunId;plugin_id=$PluginId;qualified=$false;flags=$flags;counts=$counts;issues=@();selected_sha256=$null;evidence_encoding=$EvidenceEncoding;codec_accounting=$null;
        native_qualified=$false;native_retirement_verified=$false;visual_pose_verified=$false;runtime_environment_verified=$false;runtime_memory_verified=$false;storage_durability_verified=$false;
        limitations=@('Flags report bounded SDK/host-cache records only.','Raw snapshots may be live; unchanged length/time does not prove an atomic snapshot.','No visual pose, physical parity, runtime environment/memory, native retirement or storage durability is established.','Chronological checks use known endpoint references only; legacy repeats greater than two retain unknown interiors without a complete raw timeline or absence claim.')}
    try{
        if($RunId -cnotmatch '^[A-Za-z0-9_-]{1,32}$' -or $PluginId -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or @($Routes).Count -ne 3){throw 'Exactly three routes and explicit valid run/package identities are required'}
        $routeNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($route in $Routes){
            $source=P0-EvField $route 'source';$state=P0-EvField $route 'state'
            if($source -isnot [string] -or -not $routeNames.Add($source) -or (P0-EvField $route 'namespace') -cne $PluginId){throw 'Duplicate or mismatched route namespace'}
            if($state -ceq 'missing'){continue}
            if($state -cne 'copied' -or -not(P0-EvBool $route 'short_read' $false) -or -not(P0-EvBool $route 'changed_during_read' $false)){throw 'A present route failed capture or changed during its bounded snapshot'}
            if((P0-EvField $route 'sha256') -cnotmatch '^[A-Fa-f0-9]{64}$' -or (P0-EvField $route 'document') -isnot [Collections.IDictionary]){throw 'Malformed route hash or document'}
            $present.Add($route)
        }
        if($present.Count -eq 0){throw 'No storage route contains evidence'}
        $selected=$present[0];$doc=P0-EvField $selected 'document';$fingerprint=ConvertTo-Json -InputObject $doc -Depth 40 -Compress
        foreach($route in $present){
            if((P0-EvField $route 'sha256') -cne (P0-EvField $selected 'sha256') -or (ConvertTo-Json -InputObject (P0-EvField $route 'document') -Depth 40 -Compress) -cne $fingerprint){throw 'Conflicting present storage routes; none selected'}
        }
        $result.selected_sha256=P0-EvField $selected 'sha256'
        $prefix='hop.'+$RunId+'.';$summary=P0-EvField $doc ($prefix+'summary')
        if($summary -isnot [Collections.IDictionary] -or -not(P0-EvInt (P0-EvField $summary 'schema') 1 1) -or (P0-EvField $summary 'kind') -cne 'hop-trial-evidence' -or (P0-EvField $summary 'run_id') -cne $RunId){throw 'Missing or mismatched run summary'}
        if($EvidenceEncoding -ceq 'hop-delta-v4'){
            if((P0-EvField $summary 'encoding') -isnot [string] -or (P0-EvField $summary 'encoding') -cne 'hop-delta-v4'){throw 'Expected explicit hop-delta-v4 summary; legacy requires explicit selection'}
        }elseif(P0-EvHasField $summary 'encoding'){throw 'Explicit legacy-v1 selection refuses any encoded summary; no downgrade'}
        if($null -ne (P0-EvField $doc ($prefix+'incomplete'))){throw 'An incomplete run marker is present'}
        $chunks=P0-EvField $summary 'chunks';$chunkMax=$(if($EvidenceEncoding -ceq 'hop-delta-v4'){2176}else{136})
        if(-not(P0-EvInt $chunks 0 $chunkMax)){throw 'Invalid chunk count'}
        foreach($key in $doc.Keys){
            if([string]$key -clike 'hop.*' -and [string]$key -cne ($prefix+'summary')){
                $pattern='^'+[regex]::Escape($prefix)+'chunk\.([1-9][0-9]*)$'
                if([string]$key -cnotmatch $pattern){throw 'Unexpected run or evidence key'}
                $index=[long]$Matches[1];if($index -gt $chunks){throw 'Chunk extends past summary revision'}
            }
        }
        $calls=P0-EvField $summary 'calls';if(-not(P0-EvInt $calls 0 10000000)){throw 'Invalid call count'}
        $lastFirst=0L;$repeatTotal=0L;$codecRead=$null
        if($EvidenceEncoding -ceq 'hop-delta-v4'){
            $encoded=[object[]]::new([int]$chunks)
            for($i=1;$i -le $chunks;$i++){$encoded[$i-1]=P0-EvField $doc ($prefix+'chunk.'+$i)}
            $codecRead=P0-EvReadCodec -Chunks $encoded -RunId $RunId
            foreach($row in $codecRead.rows){$rows.Add($row)}
        }else{
            # Historical schema1 remains an explicitly selected parser. A
            # schema2 chunk is refused here, never treated as ordinary rows.
            for($i=1;$i -le $chunks;$i++){
                $chunk=P0-EvField $doc ($prefix+'chunk.'+$i);$chunkRows=P0-EvField $chunk 'rows'
                if((P0-EvField $chunk 'schema') -ne 1 -or (P0-EvField $chunk 'run_id') -cne $RunId -or (P0-EvField $chunk 'chunk') -ne $i -or -not(P0-EvArray $chunkRows) -or $chunkRows.Count -lt 1 -or $chunkRows.Count -gt 16 -or (P0-EvHasField $chunk 'encoding')){throw 'Missing, mismatched or malformed legacy chunk'}
                foreach($row in $chunkRows){$rows.Add($row)}
            }
        }
        foreach($row in $rows){
            $first=P0-EvField $row 'first_call';$last=P0-EvField $row 'last_call';$repeats=P0-EvField $row 'repeats'
            if(-not(P0-EvInt $first 1 $calls) -or $first -le $lastFirst -or -not(P0-EvInt $last $first $calls) -or -not(P0-EvInt $repeats 1 ($last-$first+1)) -or -not(P0-EvBool $row 'incomplete' $false) -or (P0-EvField $row 'data') -isnot [Collections.IDictionary]){throw 'Malformed, incomplete or contradictory event ordering'}
            $lastFirst=$first;$repeatTotal+=$repeats
        }
        $regular=P0-EvField $summary 'regular_rows';$critical=P0-EvField $summary 'critical_rows'
        if(-not(P0-EvInt $regular 0 2048) -or -not(P0-EvInt $critical 0 128) -or $rows.Count -ne (P0-EvField $summary 'stored_rows') -or $rows.Count -ne ($regular+$critical) -or $repeatTotal -ne $calls -or (P0-EvField $summary 'coalesced') -ne ($calls-$rows.Count) -or (P0-EvField $summary 'dropped') -ne 0){throw 'Missing evidence tail or contradictory recorder totals'}
        if($null -ne $codecRead){
            $a=$codecRead.accounting
            if($a.regular_rows -ne $regular -or $a.critical_rows -ne $critical){throw 'Codec critical and regular row counts contradict summary'}
            foreach($field in @('regular_bytes','regular_wire_bytes','regular_state_bytes','critical_bytes')){
                $value=P0-EvField $summary $field;$maximum=$(if($field -ceq 'critical_bytes'){131072}else{524288})
                if(-not(P0-EvInt $value 0 $maximum) -or $value -ne $a[$field]){throw ('Codec byte accounting contradicts summary: '+$field)}
            }
            $summaryText=ConvertTo-Json -InputObject $summary -Depth 40 -Compress
            if([Text.UTF8Encoding]::new($false,$true).GetByteCount($summaryText) -gt 16384){throw 'Encoded run summary exceeds its reserved 16 KiB'}
            $result.codec_accounting=$a
        }
        foreach($name in @('observation_loss','unqualified','storage_fault','interrupted','final_snapshot_unavailable','unresolved_debt','cleanup_unknown_seen','board_restore_unresolved','pose_release_unresolved')){if(-not(P0-EvBool $summary $name $false)){throw ('Recorder evidence is missing or unqualified: '+$name)}}
        if(-not(P0-EvBool $summary 'cleanup_observed' $true)){throw 'Cleanup snapshot was not observed'}
        $latest=P0-EvField $summary 'latest';if($latest -isnot [Collections.IDictionary]){throw 'Final snapshot missing'}
        # Reconcile independently copied terminal debt; a clean summary cannot override it.
        foreach($n in @('cleanup_pending','cleanup_unknown','bike_authority','force_cleanup_unknown','handoff_unknown','reserve_unknown','marker_unknown','retained_reload_marker')){
            if(-not(P0-EvBool $latest $n $false)){throw ('Final debt is missing or contradicts summary: '+$n)}
        }
        $ride=P0-EvField $latest 'ride';$src=P0-EvField $latest 'source';$poseEnd=P0-EvField $latest 'mounted_pose'
        if($ride -is [Collections.IDictionary]){if(-not(P0-EvBool $ride 'force_pending' $false) -or -not(P0-EvBool $ride 'unknown' $false) -or -not(P0-EvInt (P0-EvField $ride 'pending_count') 0 0)){throw 'Final ride debt contradicts summary'}}
        if($src -is [Collections.IDictionary]){if(-not(P0-EvBool $src 'cleanup_pending' $false) -or -not(P0-EvBool $src 'cleanup_unknown' $false) -or (P0-EvBool $src 'lease_handle_present' $true)){throw 'Final source debt contradicts summary'}}
        $capture=P0-EvField $src 'capture_state';$equipment=P0-EvField $latest 'equipment';$board=P0-EvField $latest 'board_drop'
        if((P0-EvBool $capture 'report_debt' $true) -or (P0-EvBool $capture 'quarantined' $true) -or (P0-EvBool $equipment 'retained' $true) -or (P0-EvBool $equipment 'unknown' $true)){throw 'Capture or equipment debt contradicts summary'}
        if((P0-EvBool $board 'restore_pending' $true) -or (P0-EvBool $board 'drop_inflight' $true) -or (P0-EvBool $board 'restore_inflight' $true) -or (P0-EvField $board 'state') -cin @('unknown','restore_unknown','dropped')){throw 'Board restoration debt contradicts summary'}
        if(((P0-EvNumber (P0-EvField $poseEnd 'sends')) -and (P0-EvField $poseEnd 'sends') -gt 0 -and (-not(P0-EvBool $poseEnd 'stopped' $true) -or -not(P0-EvBool $poseEnd 'nil_accepted' $true))) -or
            ((P0-EvNumber (P0-EvField $poseEnd 'nil_calls')) -and (P0-EvField $poseEnd 'nil_calls') -gt 0 -and -not(P0-EvBool $poseEnd 'nil_accepted' $true))){throw 'Pose release debt contradicts summary'}
        # Totals/accounting above remain coalesced; only known endpoint references enter chronological predicates.
        $endpointCursor=New-HopEvidenceEndpointCursor -Rows $rows.ToArray()
        $captures=@{}
        while($null -ne ($endpoint=Read-HopEvidenceEndpoint $endpointCursor)){
            $event=$endpoint.row
            $d=P0-EvField $event 'data';$key=P0-EvStream $d
            # Active capture owes a later neutral release; complete terminal capture must not.
            if((P0-EvField $event 'kind') -ceq 'lease' -and (P0-EvField $d 'call') -ceq 'input.lease_capture_state' -and
                (P0-EvBool $d 'call_ok' $true) -and (P0-EvField $d 'phase') -ceq 'capturing' -and (P0-EvBool $d 'capturing' $true) -and
                (P0-EvBool $d 'report_debt' $true) -and (P0-EvBool $d 'quarantined' $false) -and $null -ne $key){
                $counts.capture_samples++;if(-not $captures.ContainsKey($key)){$captures[$key]=$endpoint.call_id}
            }
        }
        $submits=@{};$receipts=@{};$acked=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $lastBody=$null;$neutralSource=$false;$neutralMapped=$false;$nonneutral=$false;$fixedSequences=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$followSequences=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        Reset-HopEvidenceEndpointCursor $endpointCursor
        while($null -ne ($endpoint=Read-HopEvidenceEndpoint $endpointCursor)){
            $row=$endpoint.row
            $kind=P0-EvField $row 'kind';$data=P0-EvField $row 'data';$call=P0-EvField $data 'call';$sequence=P0-EvField $data 'sequence';$at=$endpoint.call_id
            switch($kind){
                'prepare' {if($call -ceq 'world.physics.prepare' -and (P0-EvBool $data 'call_ok' $true) -and (P0-EvBool $data 'result' $true) -and (P0-EvField $data 'arguments') -eq 0 -and (P0-EvField $data 'arity') -eq 1 -and (P0-EvField $data 'phase') -ceq 'ready'){$counts.prepare_ready++}}
                'source' {
                    $stream=P0-EvStream $data;$neutralSource=(P0-EvZeroPad $data) -and (P0-EvId (P0-EvField $data 'observation_serial')) -and $null -ne $stream -and $captures.ContainsKey($stream) -and $captures[$stream] -le $at
                    foreach($optional in @('neutral','input_ok')){foreach($key in $data.Keys){if([string]$key -ceq $optional -and -not(P0-EvBool $data $optional $true)){$neutralSource=$false}}}
                    if(P0-EvBool $data 'neutral' $false){$nonneutral=$true}
                }
                'mapped_hop' {$neutralMapped=(P0-EvBool $data 'hop' $false) -and (P0-EvBool $data 'rotation_reserved' $false);foreach($n in @('pedal','steer','brake','hop_event_id')){if(-not(P0-EvNumber (P0-EvField $data $n)) -or (P0-EvField $data $n) -ne 0){$neutralMapped=$false}};if($null -ne (P0-EvField $data 'pending_hop')){$neutralMapped=$false};if(-not $neutralMapped){$nonneutral=$true}}
                'body' {if(P0-EvBody $data){$lastBody=P0-EvField $data 'serial';if($call -ceq 'world.physics.read' -and (P0-EvBool $data 'call_ok' $true)){$counts.body_samples++}}else{$lastBody=$null}}
                'contact' {$query=P0-EvField $data 'query';$support=P0-EvField $data 'support';if((P0-EvBool $data 'valid' $true) -and (P0-EvBool $data 'force_ready' $true) -and (P0-EvBool $query 'epoch_matches' $true) -and (P0-EvBool $query 'accounting_known' $true) -and (P0-EvBool $query 'measurements_complete' $true) -and (P0-EvBool $query 'budget_exhausted' $false) -and (P0-EvBool $support 'known' $true) -and (P0-EvBool $support 'grounded_known' $true) -and (P0-EvBool $support 'grounded' $true)){$counts.contact_samples++}}
                'lease' {

                    if($call -ceq 'world.physics.read_follow_lease' -and (P0-EvBool $data 'call_ok' $true) -and (P0-EvBool $data 'active' $true) -and (P0-EvBool $data 'renewable' $false) -and (P0-EvField $data 'renewals') -ceq '0' -and (P0-EvId $sequence)){$counts.fixed_leases++;$null=$fixedSequences.Add($sequence)}
                }
                'follow' {if($call -ceq 'world.physics.read_follow' -and (P0-EvBool $data 'call_ok' $true) -and (P0-EvField $data 'phase') -ceq 'following' -and (P0-EvBool $data 'claim_known' $true) -and (P0-EvId $sequence) ){$counts.follow_samples++;$null=$followSequences.Add($sequence)}}
                'pose' {if($call -ceq 'skater.pose' -and (P0-EvBool $data 'call_ok' $true) -and (P0-EvBool $data 'result' $true) -and (P0-EvField $data 'state') -cne 'capability_probe'){$counts.pose_accepts++};if((P0-EvBool $data 'qualified' $true) -and (P0-EvNumber (P0-EvField $data 'sends')) -and (P0-EvField $data 'sends') -gt 0){$counts.pose_sent++}}
                'submit' {if($call -ceq 'world.physics.submit' -and (P0-EvBool $data 'call_ok' $true) -and (P0-EvBool $data 'result' $true) -and (P0-EvId $sequence)){
                    if($submits.ContainsKey($sequence)){throw 'Duplicate submit sequence'}
                    if((P0-EvField $data 'arity') -ne 3 -or -not(P0-EvVector (P0-EvField $data 'force') 3) -or -not(P0-EvVector (P0-EvField $data 'torque') 3) -or $null -ne (P0-EvField $data 'impulse') -or $null -ne (P0-EvField $data 'impulse_id')){throw 'Accepted P0 submit packet is malformed or carries an impulse'}
                    $counts.submits++;$submits[$sequence]=@{serial=(P0-EvField $data 'serial');at=$at;neutral=($neutralSource -and $neutralMapped -and $null -ne $lastBody -and (P0-EvField $data 'serial') -ceq $lastBody)}
                }}
                'receipt' {if($call -ceq 'world.physics.receipt' -and (P0-EvBool $data 'call_ok' $true) -and (P0-EvField $data 'outcome') -ceq 'applied' -and (P0-EvId $sequence) -and $submits.ContainsKey($sequence)){
                    $submission=$submits[$sequence];$successor=P0-EvField $data 'successor';$produced=P0-EvField $data 'produced_serial'
                    if($submission.neutral -and $at -gt $submission.at -and (P0-EvField $data 'requested_serial') -ceq $submission.serial -and (P0-EvId $produced) -and (P0-EvId $submission.serial) -and [UInt64]$produced -gt [UInt64]$submission.serial -and (P0-EvBody $successor) -and (P0-EvField $successor 'serial') -ceq $produced -and (P0-EvBool $data 'quarantined' $false)){
                        if(-not $receipts.ContainsKey($sequence)){$counts.applied_successors++;$receipts[$sequence]=@{at=$at;produced=$produced}}
                        elseif($receipts[$sequence].produced -cne $produced){throw 'Contradictory applied successor for one sequence'}
                    }
                }}
                'ack' {if($call -ceq 'world.physics.acknowledge' -and (P0-EvBool $data 'call_ok' $true) -and (P0-EvBool $data 'acknowledged' $true) -and (P0-EvField $data 'arity') -eq 1 -and (P0-EvId $sequence) -and $receipts.ContainsKey($sequence) -and $at -gt $receipts[$sequence].at -and $acked.Add($sequence)){$counts.acks++}}
            }
        }
        if($nonneutral){throw 'P0 neutral controls contradicted by recorded input'}
        if($counts.prepare_ready -gt 0 -and (P0-EvField (P0-EvField $latest 'native_preparation') 'phase') -ceq 'ready'){$flags.preparation='reported'}
        if($counts.capture_samples -gt 0){$flags.input_capture='reported'}
        if($counts.body_samples -gt 0){$flags.body='reported'}
        if($counts.contact_samples -gt 0){$flags.contact='reported'}
        foreach($fixed in $fixedSequences){if($followSequences.Contains($fixed)){$flags.fixed_follow='reported'}}
        if($counts.pose_accepts -gt 0 -and $counts.pose_sent -gt 0){$flags.pose_api='reported'}
        if($counts.submits -gt 0 -and $counts.submits -eq $counts.applied_successors -and $counts.submits -eq $counts.acks){$flags.neutral_receipt_ack='reported'}
        $terminal=(P0-EvField $latest 'phase') -ceq 'done' -and (P0-EvBool $latest 'bike_cleanup_complete' $true)
        foreach($n in @('cleanup_pending','cleanup_unknown','bike_authority','force_cleanup_unknown','handoff_unknown','reserve_unknown','marker_unknown','retained_reload_marker')){if(-not(P0-EvBool $latest $n $false)){$terminal=$false}}
        $ride=P0-EvField $latest 'ride';$source=P0-EvField $latest 'source';$pose=P0-EvField $latest 'mounted_pose'
        if(-not(P0-EvBool $ride 'force_pending' $false) -or -not(P0-EvBool $ride 'unknown' $false) -or (P0-EvField $ride 'pending_count') -ne 0 -or
            -not(P0-EvBool $source 'cleanup_pending' $false) -or -not(P0-EvBool $source 'cleanup_unknown' $false) -or -not(P0-EvBool $source 'lease_handle_present' $false) -or
            -not(P0-EvBool $pose 'stopped' $true) -or -not(P0-EvBool $pose 'nil_accepted' $true)){$terminal=$false}
        $terminalCapture=P0-EvField $source 'capture_state';$terminalEquipment=P0-EvField $latest 'equipment';$terminalBoard=P0-EvField $latest 'board_drop'
        if((P0-EvField $terminalCapture 'phase') -cne 'complete' -or -not(P0-EvBool $terminalCapture 'capturing' $false) -or
            -not(P0-EvBool $terminalCapture 'report_debt' $false) -or -not(P0-EvBool $terminalCapture 'quarantined' $false) -or
            -not(P0-EvBool $terminalEquipment 'retained' $false) -or -not(P0-EvBool $terminalEquipment 'unknown' $false) -or
            (P0-EvField $terminalBoard 'state') -cnotin @('idle','refused','restored')){$terminal=$false}
        foreach($n in @('restore_pending','drop_inflight','restore_inflight')){if(-not(P0-EvBool $terminalBoard $n $false)){$terminal=$false}}
        if($terminal){$flags.terminal_cleanup='reported'}
    }catch{$issues.Add($_.Exception.Message);foreach($key in @($flags.Keys)){$flags[$key]='unverified'}}
    $result.issues=$issues.ToArray();return $result
}
function Copy-P0Evidence([string[]]$StoragePaths,[string]$Destination,[string]$RunId,[string]$PluginId,[int]$MaxBytes=8388608,[ValidateSet('hop-delta-v4','legacy-v1',IgnoreCase=$false)][string]$EvidenceEncoding='hop-delta-v4'){
    if(@($StoragePaths).Count -ne 3 -or $MaxBytes -lt 1 -or $MaxBytes -gt 33554432){throw 'Capture requires three bounded storage paths'}
    if($RunId -cnotmatch '^[A-Za-z0-9_-]{1,32}$' -or $PluginId -cnotmatch '^[A-Za-z0-9_-]{1,128}$'){throw 'Invalid capture identity'}
    P0-EvPlain $Destination;if(Test-Path -LiteralPath $Destination){throw 'Capture destination must be fresh'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($path in $StoragePaths){P0-EvPlain $path;if(-not $seen.Add($path) -or [IO.Path]::GetFileName($path) -cne 'storage.json' -or [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($path)) -cne $PluginId){throw 'Storage path namespace differs'}
        if($Destination.StartsWith([IO.Path]::GetDirectoryName($path)+'\',[StringComparison]::OrdinalIgnoreCase) -or $Destination -ieq [IO.Path]::GetDirectoryName($path)){throw 'Capture destination may not be inside plugin storage'}
    }
    $null=[IO.Directory]::CreateDirectory($Destination);$routes=[Collections.Generic.List[object]]::new();$index=0
    foreach($path in $StoragePaths){
        $route=@{source=$path;namespace=$PluginId;state='missing';sha256=$null;short_read=$false;changed_during_read=$false;document=$null;capture_atomicity_verified=$false};$output=Join-Path $Destination ('storage-'+$index+'.json');$index++
        try{
            if(Test-Path -LiteralPath $path){
                $before=Get-Item -LiteralPath $path;$initialWrite=$before.LastWriteTimeUtc.Ticks
                $sourceStream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
                try{
                    $length=$sourceStream.Length;if($length -gt $MaxBytes){throw 'Storage snapshot exceeds byte bound'}
                    $snapshotStream=[IO.FileStream]::new($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
                    try{$remaining=$length;$buffer=[byte[]]::new(65536);while($remaining -gt 0){$n=$sourceStream.Read($buffer,0,[int][Math]::Min($remaining,$buffer.Length));if($n -eq 0){break};$snapshotStream.Write($buffer,0,$n);$remaining-=$n};$snapshotStream.Flush($true)}finally{$snapshotStream.Dispose()}
                    $route.changed_during_read=$sourceStream.Length -ne $length
                }finally{$sourceStream.Dispose()}
                $after=Get-Item -LiteralPath $path;$route.changed_during_read=$route.changed_during_read -or $after.LastWriteTimeUtc.Ticks -ne $initialWrite
                $route.state='copied';$route.file=$output;$route.bytes=$length-$remaining;$route.short_read=$remaining -ne 0;$route.sha256=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
                $options=[System.Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=32
                $raw=[System.Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($output,[Text.UTF8Encoding]::new($false,$true)),$options)
                try{$route.document=P0-EvDecode $raw.RootElement @{nodes=0}}finally{$raw.Dispose()}
            }
        }catch{$route.state='error';$route.error=$_.Exception.Message;if(Test-Path -LiteralPath $output){$route.file=$output;$route.sha256=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash}}
        $routes.Add($route)
    }
    $summary=Get-P0EvidenceSummary $routes.ToArray() $RunId $PluginId -EvidenceEncoding $EvidenceEncoding
    $metadata=@($routes.ToArray()|ForEach-Object{$copy=@{};foreach($key in $_.Keys){if($key -cne 'document'){$copy[$key]=$_[$key]}};$copy})
    return @{routes=$metadata;summary=$summary}
}
#requires -Version 7.5
# Synthetic source-owned fixtures only. MainRoot must own an offline test slot.
# Authored tests are not evidence of execution until the explicit switch is run.
[CmdletBinding()]
param([switch]$RunReviewedTests)
if(-not $RunReviewedTests){throw 'Pass -RunReviewedTests only in an owned offline validation window.'}
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Decode-HopEvidence.ps1')
$script:caseCount=0
function Assert-Codec([bool]$Condition,[string]$Message){if(-not $Condition){throw ('Fixture assertion: '+$Message)}}
function Invoke-CodecCase([string]$Name,[scriptblock]$Body){try{& $Body;$script:caseCount++}catch{throw ('Codec fixture '+$Name+': '+$_.Exception.Message)}}
function Expect-CodecFailure([scriptblock]$Body,[string]$Reason='Hop evidence:'){
    $failed=$false
    try{$null=& $Body}catch{$failed=$true;Assert-Codec ($_.Exception.Message -match $Reason) ('wrong refusal: '+$_.Exception.Message)}
    Assert-Codec $failed 'invalid input was accepted'
}
function New-Scalar($Value){$v=[object[]]::new(2);$v[0]=1;$v[1]=$Value;return ,$v}
function New-Delete{$v=[object[]]::new(1);$v[0]=0;return ,$v}
function New-NegativeZero{$v=[object[]]::new(1);$v[0]=4;return ,$v}
function New-Pair([int]$Token,$Node){$v=[object[]]::new(2);$v[0]=$Token;$v[1]=$Node;return ,$v}
function New-Table([object[]]$Pairs=@(),[int]$Tag=2){$v=[object[]]::new(2);$v[0]=$Tag;$v[1]=$(if($Pairs.Count -eq 0){$false}else{,$Pairs});return ,$v}
function Get-FieldId([string]$Name){$id=$script:HopEvidenceFields.IndexOf($Name)+1;Assert-Codec ($id -gt 0) ('unknown fixture field '+$Name);return $id}
function New-Data([Collections.IDictionary]$Fields,[int]$Tag=2){
    $entries=@($Fields.Keys | ForEach-Object {[pscustomobject]@{token=(Get-FieldId $_);node=$Fields[$_]}} | Sort-Object token)
    $pairs=[object[]]::new($entries.Count)
    for($i=0;$i -lt $entries.Count;$i++){$pairs[$i]=New-Pair $entries[$i].token $entries[$i].node}
    return ,(New-Table -Pairs $pairs -Tag $Tag)
}
function New-Row($Node=(New-Table),[long]$First=1,[long]$Base=0,[string]$Projection='',[int]$Kind=2,[bool]$Critical=$false){
    $v=[object[]]::new(12);$v[11]=$false;$v[0]=$Critical;$v[1]=$Kind;$v[2]=$Projection;$v[3]=$Base;$v[4]=$First;$v[5]=$First;$v[6]=1;$v[7]=$false;$v[8]=$false;$v[9]=$false;$v[10]=$Node;return ,$v
}
function New-Chunk([object[]]$Rows,[int]$Number=1,[string]$Run='fixture'){
    return [ordered]@{schema=2;encoding='hop-delta-v4';run_id=$Run;chunk=$Number;rows=$Rows}
}
function Read-Rows([object[]]$Rows){return (Read-HopEvidenceChunks -Chunks @((New-Chunk -Rows $Rows)) -RunId 'fixture')}
function Assert-Value($Actual,$Expected){
    if($Expected -is [Collections.IDictionary]){
        Assert-Codec ($Actual -is [Collections.IDictionary] -and $Actual.Count -eq $Expected.Count) 'map shape differs'
        foreach($k in $Expected.Keys){
            $found=$false
            foreach($actualKey in $Actual.Keys){if($actualKey.GetType() -eq $k.GetType() -and $actualKey -ceq $k){$found=$true;break}}
            Assert-Codec $found ('missing key '+$k);Assert-Value $Actual[$k] $Expected[$k]
        };return
    }
    if($Expected -is [Collections.IList]){
        Assert-Codec ($Actual -is [Collections.IList] -and $Actual.Count -eq $Expected.Count) 'array shape differs'
        for($i=0;$i -lt $Expected.Count;$i++){Assert-Value $Actual[$i] $Expected[$i]};return
    }
    if($Expected -is [bool] -or $Expected -is [string]){Assert-Codec ($Actual.GetType() -eq $Expected.GetType() -and $Actual -ceq $Expected) 'scalar type/value differs';return}
    Assert-Codec ((Test-HopEvidenceNumber $Actual) -and [BitConverter]::DoubleToInt64Bits([double]$Actual) -eq [BitConverter]::DoubleToInt64Bits([double]$Expected)) 'numeric bits differ'
}
Invoke-CodecCase 'full semantic roundtrip and metadata' {
    $vector=New-Table -Pairs @((New-Pair -3 (New-Scalar 3.0)),(New-Pair -2 (New-Scalar 2.0)),(New-Pair -1 (New-Scalar 1.0)))
    $data=New-Data @{call=(New-Scalar 'world.physics.read');valid=(New-Scalar $false);id=(New-Scalar '18446744073709551615');fraction=(New-Scalar (1.0/60));position=$vector;normal=(New-Table);pending_count=(New-Scalar 0)}
    $wire=New-Row -Node $data -Projection 'world.physics.read';$wire[5]=7;$wire[6]=4;$wire[7]=0;$wire[8]=1.0/60;$wire[9]=$true
    $result=Read-Rows (,$wire)
    Assert-Codec ($result.encoding -ceq 'hop-delta-v4' -and $result.rows.Count -eq 1) 'result shape differs'
    Assert-Value $result.rows[0].data @{call='world.physics.read';valid=$false;id='18446744073709551615';fraction=(1.0/60);position=@(1.0,2.0,3.0);normal=@{};pending_count=0}
    Assert-Codec ($result.rows[0].first_call -eq 1 -and $result.rows[0].last_call -eq 7 -and $result.rows[0].repeats -eq 4 -and $result.rows[0].incomplete -and -not $result.rows[0].critical) 'coalesced metadata differs'
    Assert-Value $result.rows[0].first_at_ms 0;Assert-Value $result.rows[0].last_at_ms (1.0/60)
}
Invoke-CodecCase 'nested sparse delta deletion and detached prior snapshots' {
    $first=New-Row (New-Data @{position=(New-Data @{x=(New-Scalar 1);y=(New-Scalar 2)});valid=(New-Scalar $true)})
    $second=New-Row -First 2 -Base 1 -Node (New-Data -Tag 3 @{position=(New-Data -Tag 3 @{x=(New-Delete);y=(New-Scalar 0)});valid=(New-Delete)})
    $result=Read-Rows @($first,$second)
    Assert-Value $result.rows[0].data @{position=@{x=1;y=2};valid=$true};Assert-Value $result.rows[1].data @{position=@{y=0}}
    Assert-Codec (-not $result.rows[0].Contains('first_at_ms') -and -not $result.rows[0].Contains('last_at_ms')) 'absent times appeared'
}
Invoke-CodecCase 'full replacement retains checked prior reference' {
    $result=Read-Rows @((New-Row (New-Data @{valid=(New-Scalar $true)})),(New-Row -First 2 -Base 1 -Node (New-Table)))
    Assert-Value $result.rows[1].data @{}
}
Invoke-CodecCase 'critical standalone does not replace regular base' {
    $first=New-Row (New-Data @{valid=(New-Scalar $true)})
    $critical=New-Row -First 2 -Critical $true -Node (New-Data @{valid=(New-Scalar $false)})
    $third=New-Row -First 3 -Base 1 -Node (New-Table -Tag 3)
    $result=Read-Rows @($first,$critical,$third);Assert-Value $result.rows[2].data @{valid=$true};Assert-Codec $result.rows[1].critical 'critical flag lost'
}
Invoke-CodecCase 'negative zero data and timestamps preserve sign bit' {
    $wire=New-Row (New-Data @{x=(New-NegativeZero);y=(New-Scalar 0)});$wire[7]='-0';$wire[8]=0
    $row=(Read-Rows (,$wire)).rows[0]
    Assert-Codec ([BitConverter]::DoubleToInt64Bits([double]$row.data['x']) -eq [long]::MinValue) 'data negative zero lost'
    Assert-Codec ([BitConverter]::DoubleToInt64Bits([double]$row.first_at_ms) -eq [long]::MinValue) 'time negative zero lost'
    Assert-Codec ([BitConverter]::DoubleToInt64Bits([double]$row.data['y']) -eq 0 -and [BitConverter]::DoubleToInt64Bits([double]$row.last_at_ms) -eq 0) 'positive zero changed'
}
Invoke-CodecCase 'mixed sparse and numeric tables retain key types' {
    $mixed=New-Table -Pairs @((New-Pair -2 (New-Scalar 2)),(New-Pair (Get-FieldId 'x') (New-Scalar 9)))
    # A singleton pair list requires an explicit outer array, not @((pair)),
    # whose expression result can enumerate the pair itself into two items.
    $sparse=New-Table -Pairs (,(New-Pair -2 (New-Scalar 4)))
    Assert-Codec ($sparse[1].Count -eq 1 -and $sparse[1][0] -is [Collections.IList] -and $sparse[1][0].Count -eq 2) 'singleton pair-list constructor shape differs'
    Assert-Codec ($sparse[1][0][0] -eq -2 -and $sparse[1][0][1].Count -eq 2) 'singleton pair contents differ'
    $data=(Read-Rows (,(New-Row (New-Data @{position=$mixed;normal=$sparse})))).rows[0].data
    Assert-Value $data @{position=@{2=2;x=9};normal=@{2=4}}
}
Invoke-CodecCase 'acyclic aliases accepted and materialized independently' {
    $shared=New-Data @{x=(New-Scalar 1)}
    $data=(Read-Rows (,(New-Row (New-Data @{position=$shared;normal=$shared})))).rows[0].data
    Assert-Value $data @{position=@{x=1};normal=@{x=1}}
    Assert-Codec (-not [object]::ReferenceEquals($data['position'],$data['normal'])) 'public aliases were retained'
}
Invoke-CodecCase 'short chunks exceed obsolete 136 ceiling' {
    $chunks=[object[]]::new(137);for($i=0;$i -lt $chunks.Count;$i++){$chunks[$i]=New-Chunk -Rows (,(New-Row -First ($i+1))) -Number ($i+1)}
    Assert-Codec ((Read-HopEvidenceChunks -Chunks $chunks -RunId fixture).rows.Count -eq 137) 'short chunk stream rejected'
}
Invoke-CodecCase 'all 2176 permitted occurrences survive contiguous chunks' {
    $chunks=[object[]]::new(2176);for($i=0;$i -lt $chunks.Count;$i++){$chunks[$i]=New-Chunk -Rows (,(New-Row -First ($i+1) -Critical ($i -ge 2048))) -Number ($i+1)}
    Assert-Codec ((Read-HopEvidenceChunks -Chunks $chunks -RunId fixture).rows.Count -eq 2176) 'maximum occurrence stream rejected'
}
Invoke-CodecCase 'empty input yields one explicit v4 result' {
    $result=Read-HopEvidenceChunks -Chunks @() -RunId fixture;Assert-Codec ($result.rows.Count -eq 0 -and $result.encoding -ceq 'hop-delta-v4') 'empty result differs'
}
Invoke-CodecCase 'legacy and unsupported encodings never downgrade' {
    foreach($schema in @(1,3,'2',$true)){$chunk=New-Chunk -Rows (,(New-Row));$chunk.schema=$schema;Expect-CodecFailure {Read-HopEvidenceChunks -Chunks @($chunk) -RunId fixture}}
    $chunk=New-Chunk -Rows (,(New-Row));$chunk.encoding='hop-delta-v2';Expect-CodecFailure {Read-HopEvidenceChunks -Chunks @($chunk) -RunId fixture}
}
Invoke-CodecCase 'exact envelope keys run and chunk identity' {
    $chunk=New-Chunk -Rows (,(New-Row));$chunk['extra']=0;Expect-CodecFailure {Read-HopEvidenceChunks -Chunks @($chunk) -RunId fixture}
    $chunk=New-Chunk -Rows (,(New-Row));$chunk.Remove('schema');$chunk['Schema']=2;Expect-CodecFailure {Read-HopEvidenceChunks -Chunks @($chunk) -RunId fixture}
    foreach($run in @('other','Fixture','fixture!','')){$chunk=New-Chunk -Rows (,(New-Row)) -Run $run;Expect-CodecFailure {Read-HopEvidenceChunks -Chunks @($chunk) -RunId fixture}}
    foreach($number in @(0,2)){$chunk=New-Chunk -Rows (,(New-Row)) -Number $number;Expect-CodecFailure {Read-HopEvidenceChunks -Chunks @($chunk) -RunId fixture}}
    Expect-CodecFailure {Read-HopEvidenceChunks -Chunks @((New-Chunk -Rows (,(New-Row))),(New-Chunk -Rows (,(New-Row -First 2)))) -RunId fixture}
}
Invoke-CodecCase 'empty oversized and reordered chunks refuse' {
    Expect-CodecFailure {Read-HopEvidenceChunks -Chunks @((New-Chunk -Rows @())) -RunId fixture}
    $rows=[object[]]::new(17);for($i=0;$i -lt 17;$i++){$rows[$i]=New-Row -First ($i+1)};Expect-CodecFailure {Read-Rows $rows}
    Expect-CodecFailure {Read-Rows @((New-Row -First 2),(New-Row -First 1))}
    Expect-CodecFailure {Read-Rows @((New-Row),(New-Row))}
    # Null input is refused by the mandatory parameter before decoder validation.
    Expect-CodecFailure {Read-HopEvidenceChunks -Chunks $null -RunId fixture} "Cannot bind argument to parameter 'Chunks' because it is null"
    # Non-null, well-shaped chunks are needed to reach the explicit count guard.
    $chunks=[object[]]::new(2177)
    for($i=0;$i -lt $chunks.Count;$i++){$chunks[$i]=New-Chunk -Rows (,(New-Row -First ($i+1) -Critical ($i -ge 2048))) -Number ($i+1)}
    Expect-CodecFailure {Read-HopEvidenceChunks -Chunks $chunks -RunId fixture} 'chunk count exceeds'
}
Invoke-CodecCase 'metadata exact arity types and ranges' {
    Expect-CodecFailure {Read-Rows (,([object[]]::new(10)))}
    foreach($slot in @(0,9)){$row=New-Row;$row[$slot]=0;Expect-CodecFailure {Read-Rows (,$row)}}
    foreach($kind in @(0,15,'2',$false)){$row=New-Row;$row[1]=$kind;Expect-CodecFailure {Read-Rows (,$row)}}
    foreach($slot in @(3,4,5,6)){$row=New-Row;$row[$slot]=1.5;Expect-CodecFailure {Read-Rows (,$row)}}
    $row=New-Row;$row[4]=0;Expect-CodecFailure {Read-Rows (,$row)}
    $row=New-Row;$row[5]=0;Expect-CodecFailure {Read-Rows (,$row)}
    $row=New-Row;$row[6]=2;Expect-CodecFailure {Read-Rows (,$row)}
    $row=New-Row;$row[4]=10000001;Expect-CodecFailure {Read-Rows (,$row)}
    foreach($time in @($true,'0',-1,[double]::NaN,[double]::PositiveInfinity,([BitConverter]::Int64BitsToDouble([long]::MinValue)))){$row=New-Row;$row[7]=$time;Expect-CodecFailure {Read-Rows (,$row)}}
}
Invoke-CodecCase 'base missing forward skipped cross kind and projection' {
    Expect-CodecFailure {Read-Rows (,(New-Row -First 2 -Base 1 -Node (New-Table -Tag 3)))}
    Expect-CodecFailure {Read-Rows (,(New-Row -Base 1 -Node (New-Table -Tag 3)))}
    Expect-CodecFailure {Read-Rows @((New-Row),(New-Row -First 2 -Base 1 -Kind 1 -Node (New-Table -Tag 3)))}
    Expect-CodecFailure {Read-Rows @((New-Row),(New-Row -First 2 -Base 1 -Projection 'other' -Node (New-Table -Tag 3)))}
    Expect-CodecFailure {Read-Rows @((New-Row),(New-Row -First 2),(New-Row -First 3 -Base 1 -Node (New-Table -Tag 3)))}
    Expect-CodecFailure {Read-Rows @((New-Row),(New-Row -First 2 -Base 1 -Critical $true -Node (New-Table -Tag 3)))}
}
Invoke-CodecCase 'projection exactly matches reconstructed call' {
    Expect-CodecFailure {Read-Rows (,(New-Row -Projection 'missing'))}
    Expect-CodecFailure {Read-Rows (,(New-Row -Node (New-Data @{call=(New-Scalar 'other')})))}
    Expect-CodecFailure {Read-Rows (,(New-Row -Node (New-Data @{call=(New-Scalar 0)})))}
}
Invoke-CodecCase 'root and child node arities tags and canonical empty shape' {
    foreach($node in @((New-Scalar 1),(New-Delete),(New-NegativeZero),(New-Table -Tag 3))){Expect-CodecFailure {Read-Rows (,(New-Row $node))}}
    $node=[object[]]::new(2);$node[0]=2;$node[1]=[object[]]::new(0);Expect-CodecFailure {Read-Rows (,(New-Row $node))}
    $node=[object[]]::new(2);$node[0]=2;$node[1]=$true;Expect-CodecFailure {Read-Rows (,(New-Row $node))}
    $bad=[object[]]::new(2);$bad[0]=4;$bad[1]=0;Expect-CodecFailure {Read-Rows (,(New-Row (New-Data @{x=$bad})))}
    $bad=[object[]]::new(2);$bad[0]=5;$bad[1]=0;Expect-CodecFailure {Read-Rows (,(New-Row (New-Data @{x=$bad})))}
}
Invoke-CodecCase 'pair tokens must be valid unique and ordered' {
    foreach($token in @(0,315,-33,1.5,'1')){$pair=New-Pair 1 (New-Scalar 0);$pair[0]=$token;Expect-CodecFailure {Read-Rows (,(New-Row (New-Table -Pairs (,$pair))))}}
    Expect-CodecFailure {Read-Rows (,(New-Row (New-Table -Pairs @((New-Pair 3 (New-Scalar 1)),(New-Pair 3 (New-Scalar 2))))))}
    Expect-CodecFailure {Read-Rows (,(New-Row (New-Table -Pairs @((New-Pair 4 (New-Scalar 1)),(New-Pair 3 (New-Scalar 2))))))}
}
Invoke-CodecCase 'deletion and delta require existing table base' {
    Expect-CodecFailure {Read-Rows (,(New-Row (New-Data @{x=(New-Delete)})))}
    Expect-CodecFailure {Read-Rows @((New-Row),(New-Row -First 2 -Base 1 -Node (New-Data -Tag 3 @{x=(New-Delete)})))}
    Expect-CodecFailure {Read-Rows @((New-Row (New-Data @{position=(New-Scalar 1)})),(New-Row -First 2 -Base 1 -Node (New-Data -Tag 3 @{position=(New-Table -Tag 3)})))}
    Expect-CodecFailure {Read-Rows (,(New-Row (New-Data @{position=(New-Table -Tag 3)})))}
}
Invoke-CodecCase 'scalar types finite strings and canonical negative zero' {
    foreach($value in @($null,[double]::NaN,[double]::PositiveInfinity,([BitConverter]::Int64BitsToDouble([long]::MinValue)),('a'*193),([string][char]0xd800))){Expect-CodecFailure {Read-Rows (,(New-Row (New-Data @{x=(New-Scalar $value)})))}}
}
Invoke-CodecCase 'cycles and physical SDK wire depth refuse before projection admission' {
    $cycle=New-Table;$pair=New-Pair (Get-FieldId 'position') $cycle;$cycle[1]=[object[]]::new(1);$cycle[1][0]=$pair
    Expect-CodecFailure {Read-Rows (,(New-Row $cycle))} 'cycle'
    $node=New-Table;for($i=0;$i -lt 10;$i++){$node=New-Data @{position=$node}}
    Expect-CodecFailure {Read-Rows (,(New-Row $node))} 'SDK JSON nesting'
}
Invoke-CodecCase 'deepest delta deletion obeys physical JSON depth' {
    $delta=New-Data -Tag 3 @{x=(New-Delete)}
    for($i=0;$i -lt 9;$i++){$delta=New-Data -Tag 3 @{position=$delta}}
    # A valid deepest base is empty. The deletion must receive the same depth
    # refusal as every other child, before checking its missing-key status.
    $baseNode=New-Table
    for($i=0;$i -lt 9;$i++){$baseNode=New-Data @{position=$baseNode}}
    Expect-CodecFailure {Read-Rows @((New-Row $baseNode),(New-Row -First 2 -Base 1 -Node $delta))} 'SDK JSON nesting'
}
Invoke-CodecCase 'expanded node budget counts every aliased occurrence and keys' {
    $innerFields=@{};foreach($name in $script:HopEvidenceFields){$innerFields[$name]=New-Scalar $false};$inner=New-Data $innerFields
    $outerFields=@{};foreach($name in $script:HopEvidenceFields){if($name -ne 'call' -and $outerFields.Count -lt 100){$outerFields[$name]=New-Scalar $false}};$outerFields['position']=$inner
    Expect-CodecFailure {Read-Rows (,(New-Row (New-Data $outerFields)))} '768 nodes'
}
Invoke-CodecCase 'expanded byte bound is distinct from encoded row bound' {
    $fields=@{};foreach($name in @($script:HopEvidenceFields | Where-Object {$_.Length -ge 12 -and $_ -ne 'call'} | Sort-Object Length -Descending | Select-Object -First 68)){$fields[$name]=New-Scalar ('a'*160)}
    Expect-CodecFailure {Read-Rows (,(New-Row (New-Data $fields)))} '11904 bytes'
}
Invoke-CodecCase 'regular and critical occurrence capacity refuse' {
    $chunks=[object[]]::new(129);for($i=0;$i -lt 129;$i++){$chunks[$i]=New-Chunk -Rows (,(New-Row -First ($i+1) -Critical $true)) -Number ($i+1)}
    Expect-CodecFailure {Read-HopEvidenceChunks -Chunks $chunks -RunId fixture} 'critical stream capacity'
    $chunks=[object[]]::new(2049);for($i=0;$i -lt 2049;$i++){$chunks[$i]=New-Chunk -Rows (,(New-Row -First ($i+1))) -Number ($i+1)}
    Expect-CodecFailure {Read-HopEvidenceChunks -Chunks $chunks -RunId fixture} 'regular wire and canonical state'
}
Invoke-CodecCase 'projection dictionary is bounded at 64' {
    $chunks=[object[]]::new(65);for($i=0;$i -lt 65;$i++){$call='projection'+$i;$chunks[$i]=New-Chunk -Rows (,(New-Row -First ($i+1) -Projection $call -Node (New-Data @{call=(New-Scalar $call)}))) -Number ($i+1)}
    Expect-CodecFailure {Read-HopEvidenceChunks -Chunks $chunks -RunId fixture} '64 bases'
}
Invoke-CodecCase 'literal independent dictionary and kind anchors' {
    $node=New-Table -Pairs @((New-Pair 43 (New-Scalar 'literal')),(New-Pair 313 (New-Scalar 7)),(New-Pair 314 (New-Scalar 8)))
    $rows=[object[]]::new(14);for($i=0;$i -lt 14;$i++){$rows[$i]=New-Row -Node $node -First ($i+1) -Projection literal -Kind ($i+1)}
    $result=Read-Rows $rows
    $expected=@('source','body','contact','force_pending','mapped_hop','preview','submit','receipt','ack','pose','follow','lease','prepare','terminal')
    for($i=0;$i -lt 14;$i++){Assert-Codec ($result.rows[$i].kind -ceq $expected[$i]) 'literal kind mapping drifted';Assert-Value $result.rows[$i].data @{call='literal';x=7;y=8}}
}
Invoke-CodecCase 'case-distinct projection lanes use ordinal references' {
    $a=New-Row -Projection A -Node (New-Data @{call=(New-Scalar 'A');valid=(New-Scalar $true)})
    $b=New-Row -First 2 -Projection a -Node (New-Data @{call=(New-Scalar 'a');valid=(New-Scalar $false)})
    $c=New-Row -First 3 -Base 1 -Projection A -Node (New-Table -Tag 3)
    $d=New-Row -First 4 -Base 2 -Projection a -Node (New-Table -Tag 3)
    $result=Read-Rows @($a,$b,$c,$d);Assert-Value $result.rows[2].data @{call='A';valid=$true};Assert-Value $result.rows[3].data @{call='a';valid=$false}
    $c[3]=2;Expect-CodecFailure {Read-Rows @($a,$b,$c)} 'base skipped'
}
Invoke-CodecCase 'late malformed row emits no partial pipeline result' {
    $seen=[Collections.Generic.List[object]]::new();$bad=New-Row -First 2;$bad[1]=99
    Expect-CodecFailure {Read-HopEvidenceChunks -Chunks @((New-Chunk -Rows @((New-Row),$bad))) -RunId fixture | ForEach-Object {$seen.Add($_)}}
    Assert-Codec ($seen.Count -eq 0) 'partial successful output preceded failure'
}
function New-WideData([string]$Call=''){
    $fields=@{};foreach($name in @($script:HopEvidenceFields | Where-Object {$_ -ne 'call'} | Select-Object -First 80)){$fields[$name]=New-Scalar ('a'*90)}
    if($Call -cne ''){$fields['call']=New-Scalar $Call}
    return ,(New-Data $fields)
}
Invoke-CodecCase 'encoded row byte cap refuses wire overhead independently' {
    $outer=[object[]]::new(32)
    for($i=0;$i -lt 32;$i++){$inner=[object[]]::new(9);for($j=0;$j -lt 9;$j++){$inner[$j]=New-Pair ($j-9) (New-Scalar 1.5)};$outer[$i]=New-Pair ($i-32) (New-Table -Pairs $inner)}
    Expect-CodecFailure {Read-Rows (,(New-Row (New-Table -Pairs $outer)))} 'encoded (node|row) exceeds'
}
Invoke-CodecCase 'encoded chunk byte cap refuses three individually valid rows' {
    $node=New-WideData
    Assert-Codec ((Read-Rows (,(New-Row $node))).rows.Count -eq 1) 'wide individual row was invalid'
    Expect-CodecFailure {Read-Rows @((New-Row $node),(New-Row -First 2 -Node $node),(New-Row -First 3 -Node $node))} 'encoded chunk exceeds'
}
Invoke-CodecCase 'critical byte cap refuses before critical count cap' {
    $node=New-WideData;$chunks=[object[]]::new(20)
    for($i=0;$i -lt 20;$i++){$chunks[$i]=New-Chunk -Rows (,(New-Row -First ($i+1) -Critical $true -Node $node)) -Number ($i+1)}
    Expect-CodecFailure {Read-HopEvidenceChunks -Chunks $chunks -RunId fixture} 'critical stream capacity'
}
Invoke-CodecCase 'regular cap includes current canonical projection data' {
    $chunks=[object[]]::new(40)
    for($i=0;$i -lt 40;$i++){$call='state'+$i;$chunks[$i]=New-Chunk -Rows (,(New-Row -First ($i+1) -Projection $call -Node (New-WideData $call))) -Number ($i+1)}
    # Forty rows carry well below 512KiB of wire, but retained current states
    # plus those wires exceed 512KiB while count40 and bases40 remain legal.
    Expect-CodecFailure {Read-HopEvidenceChunks -Chunks $chunks -RunId fixture} 'regular wire and canonical state'
}
Invoke-CodecCase 'aggregate envelope cap is subsumed by tighter present limits' {
    # A worst-case envelope/storage-key wrapper with run32, chunk2176 and
    # sixteen row commas is under175 bytes. Use that larger bound per chunk:
    # sumwire<=512KiB+128KiB, chunks<=2176 => aggregate<=1,036,160<1MiB.
    # Therefore no admitted present-version stream can isolate this refusal.
    # Keep the decoder guard for defense if tighter caps change in the future.
    [long]$upper=524288+131072+2176*175
    Assert-Codec ($upper -eq 1036160 -and $upper -lt 1048576) 'aggregate subsumption proof differs'
}
Invoke-CodecCase 'v4 signed integral wire decimal widths across powers of ten' {
    foreach($pair in @(@(0,1),@(-1,2),@(1,1),@(9,1),@(-9,2),@(10,2),@(-10,3),@(99,2),@(-99,3),@(100,3),@(-100,4),@(999,3),@(-999,4),@(1000,4),@(-1000,5),@(1000000000000000,16),@(-1000000000000000,17),@(9007199254740991,16),@(-9007199254740991,17),@(9007199254740992,16),@(-9007199254740992,17))){
        Assert-Codec ((Get-HopEvidenceNumericWireBytes $pair[0]) -eq $pair[1]) 'Signed invariant integer wire width differs'
    }
}
Invoke-CodecCase 'v4 inclusive Double boundary and exact integral Decimal inputs' {
    foreach($pair in @(@([double]9007199254740991,16),@([double]-9007199254740991,17),@([double]9007199254740992,16),@([double]-9007199254740992,17),@([double]9007199254740994,32),@([double]-9007199254740994,32),@([long]9007199254740993,32),@([long]-9007199254740993,32),@([uint64]9007199254740993,32),@([double]1.5,32),@([double]1e-300,32),@([double]::MaxValue,32))){
        Assert-Codec ((Get-HopEvidenceNumericWireBytes $pair[0]) -eq $pair[1]) 'Boundary input rounded into a cheaper wire branch'
    }
    foreach($pair in @(@('9007199254740992',16),@('-9007199254740992',17),@('9007199254740993',32),@('-9007199254740993',32),@('9007199254740991.5',32),@('-9007199254740991.5',32),@('9007199254740992.5',32),@('-9007199254740992.5',32))){
        $value=[decimal]::Parse($pair[0],[Globalization.CultureInfo]::InvariantCulture)
        Assert-Codec ((Get-HopEvidenceNumericWireBytes $value) -eq $pair[1]) 'Exact Decimal boundary or fractional value was rounded'
    }
    # 2^53+1 is not an above-boundary Double fixture: it rounds to 2^53.
    $rounded=[double]9007199254740993
    Assert-Codec ($rounded -eq [double]9007199254740992 -and (Get-HopEvidenceNumericWireBytes $rounded) -eq 16) 'Already-rounded Double profile differs'
}
Invoke-CodecCase 'v4 integer wire agrees with independently serialized Int64 literals' {
    foreach($pair in @(@(0,'0'),@(-1,'-1'),@(10,'10'),@(-1000,'-1000'),@(9007199254740992,'9007199254740992'),@(-9007199254740992,'-9007199254740992'))){
        $json=ConvertTo-Json -InputObject ([long]$pair[0]) -Compress
        Assert-Codec ($json -ceq $pair[1]) 'Independent Int64 JSON literal changed'
        $bytes=[Text.UTF8Encoding]::new($false,$true).GetByteCount($json)
        Assert-Codec ((Get-HopEvidenceNumericWireBytes $pair[0]) -eq $bytes) 'Wire estimate differs from Int64 JSON byte width'
    }
}
Invoke-CodecCase 'v4 numeric wire saving leaves canonical DATA and values unchanged' {
    $active=[Collections.Generic.HashSet[object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
    $zero=Read-HopEvidenceNode (New-Scalar 0) $null $false $active
    Assert-Codec ($zero.wire_bytes -eq 5) 'Positive-zero scalar must be4 wrapper plus1 numeric byte'
    $table=New-Data @{x=(New-Scalar 0);y=(New-Scalar 1)}
    $node=Read-HopEvidenceNode $table $null $false $active
    Assert-Codec ((Get-HopEvidenceDataMeasure $node.value @{nodes=0}) -eq 76) 'Canonical numeric DATA stopped charging32 per number'
    foreach($value in @([double]0,[double]-1,[double]1.25,[double]9007199254740992,[double]-9007199254740992,[double]9007199254740994)){
        $row=(Read-Rows (,(New-Row (New-Data @{x=(New-Scalar $value)})))).rows[0]
        Assert-Value $row.data['x'] $value
    }
    $exact=[long]9007199254740993;$row=(Read-Rows (,(New-Row (New-Data @{x=(New-Scalar $exact)})))).rows[0]
    Assert-Codec ($row.data['x'] -is [long] -and $row.data['x'] -eq $exact) 'Structured exact Int64 value was changed by accounting'
}
Invoke-CodecCase 'v4 numeric timestamps and signed zero keep exact metadata' {
    $wire=New-Row (New-Data @{x=(New-Scalar 0)});$wire[7]=0;$wire[8]=10
    $row=(Read-Rows (,$wire)).rows[0]
    Assert-Codec ((Get-HopEvidenceNumericWireBytes $wire[7]) -eq 1 -and (Get-HopEvidenceNumericWireBytes $wire[8]) -eq 2) 'Integral timestamp widths differ'
    Assert-Value $row.first_at_ms 0;Assert-Value $row.last_at_ms 10
    $wire[7]='-0';$wire[8]=1.25;$row=(Read-Rows (,$wire)).rows[0]
    Assert-Codec ([BitConverter]::DoubleToInt64Bits([double]$row.first_at_ms) -eq [long]::MinValue -and (Get-HopEvidenceNumericWireBytes $wire[8]) -eq 32) 'Signed-zero time or fractional fallback changed'
    $active=[Collections.Generic.HashSet[object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
    Assert-Codec ((Read-HopEvidenceNode (New-NegativeZero) $null $false $active).wire_bytes -eq 3) 'Negative-zero node cost changed'
}
Invoke-CodecCase 'v4 wire accounting is invariant under a nonstandard current culture' {
    # Command-mode negative literals can bind as strings under a custom sign.
    # Prepare the intended numeric arguments and complete wire before the swap.
    [long]$negative=-1000;[long]$boundary=-9007199254740992;[double]$fraction=1.25
    $wire=New-Row (New-Data @{x=(New-Scalar $negative)})
    $previous=[Threading.Thread]::CurrentThread.CurrentCulture
    try{
        $culture=[Globalization.CultureInfo]::InvariantCulture.Clone();$culture.NumberFormat.NegativeSign='minus';$culture.NumberFormat.NumberDecimalSeparator=','
        [Threading.Thread]::CurrentThread.CurrentCulture=$culture
        Assert-Codec ((Get-HopEvidenceNumericWireBytes $negative) -eq 5 -and (Get-HopEvidenceNumericWireBytes $boundary) -eq 17 -and (Get-HopEvidenceNumericWireBytes $fraction) -eq 32) 'Current culture changed numeric wire lengths'
        $row=(Read-Rows (,$wire)).rows[0]
        Assert-Codec ($row.data['x'] -is [long] -and $row.data['x'] -eq $negative) 'Culture fixture lost its exact numeric Int64 value'
        Assert-Value $row.data['x'] $negative
    }finally{[Threading.Thread]::CurrentThread.CurrentCulture=$previous}
}
Invoke-CodecCase 'v4 numeric helper refuses coercion and nonfinite values' {
    foreach($value in @($null,'1',$true,[double]::NaN,[double]::PositiveInfinity,[double]::NegativeInfinity)){
        Expect-CodecFailure {Get-HopEvidenceNumericWireBytes $value} 'numeric wire value must be finite'
    }
}
Invoke-CodecCase 'v4 rejects old v2 and mixed streams without partial output or fallback' {
    $old=New-Chunk -Rows (,(New-Row));$old.encoding='hop-delta-v2'
    Expect-CodecFailure {Read-HopEvidenceChunks -Chunks @($old) -RunId fixture} 'unsupported schema or encoding'
    $first=New-Chunk -Rows (,(New-Row));$second=New-Chunk -Rows (,(New-Row -First 2)) -Number 2;$second.encoding='hop-delta-v2'
    $seen=[Collections.Generic.List[object]]::new()
    Expect-CodecFailure {Read-HopEvidenceChunks -Chunks @($first,$second) -RunId fixture|ForEach-Object {$seen.Add($_)}} 'unsupported schema or encoding'
    Assert-Codec ($seen.Count -eq 0) 'Mixed-profile failure emitted partial v4 rows'
}
# Counts are synthetic test-case groups, not native/gameplay qualification.
function New-KnownPairData([string]$Call='input.lease_capture_state'){
    if($Call -ceq 'input.lease_state'){
        return @{call=$Call;arity=1;call_ok=$true;sequence='2';user=0;source_epoch='3';context_generation='4';status='active';reason='none';terminal=$false;requested_ms='100';expires_ms='1000';observed_ms='101';last_observation='5';renewals='0';source_released=$false;capture_reserved=$true;orphaned=$false;capturing=$false;report_debt=$false}
    }
    return @{call=$Call;arity=1;call_ok=$true;sequence='2';user=0;source_epoch='3';context_generation='4';phase='capturing';reason='none';terminal=$false;quarantined=$false;capturing=$true;report_debt=$true;generation='6';revision='7';expires_ms='1000';publications='1';neutral_releases='0'}
}
function New-SealedPair($Data=(New-KnownPairData),[long]$First=1,[long]$Last=3){
    $fields=@{};foreach($key in $Data.Keys){$value=$Data[$key];$fields[$key]=$(if((Test-HopEvidenceNumber $value) -and $value -eq 0 -and [BitConverter]::DoubleToInt64Bits([double]$value) -eq [long]::MinValue){New-NegativeZero}else{New-Scalar $value})}
    $wire=New-Row -First $First -Kind ($script:HopEvidenceKinds.IndexOf('lease')+1) -Projection $Data.call -Node (New-Data $fields)
    $wire[5]=$Last;$wire[6]=2;$wire[11]=$true;return ,$wire
}
function New-ViewRow([long]$First=1,[long]$Last=$First,[long]$Repeats=1,[bool]$Critical=$false){return [ordered]@{kind='body';data=@{};first_call=$First;last_call=$Last;repeats=$Repeats;incomplete=$false;critical=$Critical}}
Invoke-CodecCase 'v4 twelve-slot marker is explicit and old profiles never retry' {
    $row=New-Row;Assert-Codec ($row.Count -eq 12 -and $row[11] -is [bool] -and -not $row[11]) 'fixture marker is not explicit false'
    foreach($profile in @('hop-delta-v2','hop-delta-v3','HOP-DELTA-V4')){$chunk=New-Chunk -Rows (,$row);$chunk.encoding=$profile;Expect-CodecFailure {Read-HopEvidenceChunks -Chunks @($chunk) -RunId fixture} 'unsupported schema or encoding'}
    Expect-CodecFailure {Read-Rows (,$row[0..10])} 'twelve dense slots'
    foreach($marker in @(0,1,'true',$null)){$row=New-Row;$row[11]=$marker;Expect-CodecFailure {Read-Rows (,$row)} 'pair flags'}
}
Invoke-CodecCase 'sealed active capture retains full DTO and exact endpoint absence and sign' {
    $data=New-KnownPairData;$wire=New-SealedPair $data;$wire[7]='-0';$wire[8]=$false
    $row=(Read-Rows (,$wire)).rows[0]
    Assert-Value $row.data $data;Assert-Codec ($row.paired -and $row.repeats -eq 2 -and $row.data['report_debt']) 'pair or active debt changed'
    Assert-Codec ([BitConverter]::DoubleToInt64Bits([double]$row.first_at_ms) -eq [long]::MinValue -and -not $row.Contains('last_at_ms')) 'endpoint absence/sign changed'
}
Invoke-CodecCase 'sealed passive lease full DTO and UInt64 boundary relations' {
    $data=New-KnownPairData 'input.lease_state';$data.requested_ms='18446744073709551365';$data.observed_ms='18446744073709551365';$data.expires_ms='18446744073709551615'
    Assert-Codec ((Read-Rows (,(New-SealedPair $data))).rows[0].paired) 'exact max UInt64 relation refused'
    foreach($bad in @('18446744073709551366','18446744073709551616','0100','0')){$data=New-KnownPairData 'input.lease_state';$data.requested_ms=$bad;Expect-CodecFailure {Read-Rows (,(New-SealedPair $data))} 'sealed pair'}
}
Invoke-CodecCase 'sealed marker cannot relabel critical incomplete singleton or nontarget data' {
    foreach($slot in @(0,9)){$wire=New-SealedPair;$wire[$slot]=$true;Expect-CodecFailure {Read-Rows (,$wire)} 'sealed pair'}
    $wire=New-SealedPair;$wire[6]=1;Expect-CodecFailure {Read-Rows (,$wire)} 'sealed pair'
    $wire=New-SealedPair;$wire[1]=2;Expect-CodecFailure {Read-Rows (,$wire)} 'sealed pair'
    $data=New-KnownPairData;$data.call='world.physics.read_follow_lease';Expect-CodecFailure {Read-Rows (,(New-SealedPair $data))} 'sealed pair'
}
Invoke-CodecCase 'sealed marker requires every exact DTO field and rejects extras and case variants' {
    foreach($call in @('input.lease_state','input.lease_capture_state')){
        $basis=New-KnownPairData $call
        foreach($key in @($basis.Keys)){$data=New-KnownPairData $call;$data.Remove($key);if($key -ceq 'call'){Assert-Codec (-not(Test-HopEvidencePairedData $data)) 'missing call admitted'}else{Expect-CodecFailure {Read-Rows (,(New-SealedPair $data))} 'sealed pair'}}
        $data=New-KnownPairData $call;$data['known']=$true;Expect-CodecFailure {Read-Rows (,(New-SealedPair $data))} 'sealed pair'
    }
    $basis=New-KnownPairData;Assert-Codec (Test-HopEvidencePairedData $basis) 'canonical positive control refused'
    $data=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($key in $basis.Keys){$data.Add($key,$basis[$key])}
    $arity=$data['arity'];$null=$data.Remove('arity');$data.Add('Arity',$arity)
    Assert-Codec ($data.Count -eq $basis.Count -and -not $data.ContainsKey('arity') -and $data.ContainsKey('Arity')) 'wrong-case fixture is not complete and ordinal'
    Assert-Codec (-not(Test-HopEvidencePairedData $data)) 'complete wrong-case DTO admitted'
}
Invoke-CodecCase 'sealed marker refuses semantic unknown and contradictory debt counters' {
    foreach($change in @(@('phase','complete'),@('reason','unknown'),@('terminal',$true),@('quarantined',$true),@('report_debt',$false),@('capturing',$false),@('publications','0'),@('neutral_releases','2'),@('sequence','02'),@('generation','0'),@('revision','18446744073709551616'))){$data=New-KnownPairData;$data[$change[0]]=$change[1];Expect-CodecFailure {Read-Rows (,(New-SealedPair $data))} 'sealed pair'}
    $data=New-KnownPairData;$data.phase='waiting_neutral';$data.capturing=$false;$data.report_debt=$false;$data.publications='0';Assert-Codec ((Read-Rows (,(New-SealedPair $data))).rows[0].paired) 'complete waiting-neutral subset refused'
}
Invoke-CodecCase 'paired projection reference retains original first identity and replaces current state only' {
    $first=New-SealedPair;$second=New-Row -First 2;$fourth=New-Row -First 4 -Base 1 -Kind ($script:HopEvidenceKinds.IndexOf('lease')+1) -Projection 'input.lease_capture_state' -Node (New-Table -Tag 3)
    $rows=(Read-Rows @($first,$second,$fourth)).rows
    Assert-Codec ($rows.Count -eq 3 -and $rows[0].first_call -eq 1 -and $rows[0].last_call -eq 3 -and $rows[0].paired -and -not $rows[2].Contains('paired')) 'row/base identity or paired presence changed'
    Assert-Value $rows[0].data $rows[2].data
}
Invoke-CodecCase 'ordinary legacy Follow309 remains one unpaired coalesced row' {
    $wire=New-Row -Kind ($script:HopEvidenceKinds.IndexOf('follow')+1);$wire[5]=309;$wire[6]=309
    $rows=(Read-Rows (,$wire)).rows;Assert-Codec ($rows.Count -eq 1 -and $rows[0].repeats -eq 309 -and -not $rows[0].Contains('paired')) 'legacy Follow relabeled or expanded'
    $cursor=New-HopEvidenceEndpointCursor $rows;Assert-Codec ((Read-HopEvidenceEndpoint $cursor).call_id -eq 1 -and (Read-HopEvidenceEndpoint $cursor).call_id -eq 309 -and $null -eq (Read-HopEvidenceEndpoint $cursor)) 'legacy known endpoints expanded'
    Assert-Codec ((Find-HopEvidenceEndpoint $cursor 150).reason -ceq 'UNKNOWN_INTERIOR') 'dense count fabricated interior call'
}
Invoke-CodecCase 'lazy endpoints globally merge pair with intervening singleton by call ID' {
    $a=New-ViewRow 1 3 2;$b=New-ViewRow 2;$rows=@($a,$b);$cursor=New-HopEvidenceEndpointCursor $rows
    Assert-Codec ($cursor.heap -is [int[]] -and $cursor.heap.Length -eq 2 -and [object]::ReferenceEquals($cursor.rows,$rows)) 'cursor copied rows or grew heap'
    foreach($id in @(1,2,3)){$endpoint=Read-HopEvidenceEndpoint $cursor;Assert-Codec ($endpoint.call_id -eq $id) 'known order differs';Assert-Codec ([object]::ReferenceEquals($endpoint.row,$(if($id -eq 2){$b}else{$a}))) 'original row reference lost'}
    Assert-Codec ($null -eq (Read-HopEvidenceEndpoint $cursor)) 'EOF produced an endpoint'
}
Invoke-CodecCase 'two overlapping pair ranges merge endpoints without inventing range members' {
    $cursor=New-HopEvidenceEndpointCursor @((New-ViewRow 1 3 2),(New-ViewRow 2 5 2),(New-ViewRow 4))
    foreach($id in @(1,2,3,4,5)){Assert-Codec ((Read-HopEvidenceEndpoint $cursor).call_id -eq $id) 'overlapping endpoint merge differs'}
    Assert-Codec ($null -eq (Read-HopEvidenceEndpoint $cursor)) 'pair ranges expanded'
}
Invoke-CodecCase 'lookup is nonconsuming and known other rows override opaque range uncertainty' {
    $opaque=New-ViewRow 1 5 3;$b=New-ViewRow 2;$d=New-ViewRow 4;$cursor=New-HopEvidenceEndpointCursor @($opaque,$b,$d)
    $found=Find-HopEvidenceEndpoint $cursor 2;Assert-Codec ([object]::ReferenceEquals($found.endpoint.row,$b) -and $null -eq $found.reason) 'known row inside opaque range lost'
    Assert-Codec ((Find-HopEvidenceEndpoint $cursor 3).reason -ceq 'UNKNOWN_INTERIOR' -and (Find-HopEvidenceEndpoint $cursor 6).reason -ceq 'UNKNOWN') 'unknown was promoted to absence/interpolated call'
    Assert-Codec ((Read-HopEvidenceEndpoint $cursor).call_id -eq 1) 'lookup consumed cursor'
}
Invoke-CodecCase 'lazy timestamps retain absent positive-zero negative-zero and ignore clock ordering' {
    $negative=[BitConverter]::Int64BitsToDouble([long]::MinValue);$a=New-ViewRow 1 3 2;$a['last_at_ms']=$negative;$b=New-ViewRow 2;$b['first_at_ms']=0;$b['last_at_ms']=0
    $cursor=New-HopEvidenceEndpointCursor @($a,$b);$first=Read-HopEvidenceEndpoint $cursor;Assert-Codec (-not $first.Contains('at_ms')) 'absent time appeared'
    $second=Read-HopEvidenceEndpoint $cursor;$last=Read-HopEvidenceEndpoint $cursor
    Assert-Codec ($first.call_id -eq 1 -and $second.call_id -eq 2 -and $last.call_id -eq 3 -and [BitConverter]::DoubleToInt64Bits([double]$second.at_ms) -eq 0 -and [BitConverter]::DoubleToInt64Bits([double]$last.at_ms) -eq [long]::MinValue) 'time bits or call authority changed'
}
Invoke-CodecCase 'exact endpoint collision refuses before either colliding ID is yielded' {
    $cursor=New-HopEvidenceEndpointCursor @((New-ViewRow 1 3 2),(New-ViewRow 2 3 2));$seen=[Collections.Generic.List[long]]::new()
    Expect-CodecFailure {while($null -ne ($ep=Read-HopEvidenceEndpoint $cursor)){$seen.Add($ep.call_id)}} 'duplicate known endpoint'
    Assert-Codec ($seen.Count -eq 2 -and $seen[0] -eq 1 -and $seen[1] -eq 2 -and $cursor.failed) 'collision yielded partial tied endpoint'
    Expect-CodecFailure {Read-HopEvidenceEndpoint $cursor} 'invalidated'
}
Invoke-CodecCase 'lookup collision invalidates cursor without deduplication' {
    $cursor=New-HopEvidenceEndpointCursor @((New-ViewRow 1 3 2),(New-ViewRow 2 3 2))
    Expect-CodecFailure {Find-HopEvidenceEndpoint $cursor 3} 'duplicate known endpoint'
    Assert-Codec $cursor.failed 'duplicate lookup did not poison cursor'
}
Invoke-CodecCase 'malformed singleton and repeated metadata refuse before cursor publication' {
    foreach($row in @((New-ViewRow 1 3 1),(New-ViewRow 1 1 2),(New-ViewRow 1 2 3))){Expect-CodecFailure {New-HopEvidenceEndpointCursor (,$row)} 'view'}
    $row=New-ViewRow;$row['first_at_ms']=0;Expect-CodecFailure {New-HopEvidenceEndpointCursor (,$row)} 'singleton endpoints'
    $row=New-ViewRow;$row['first_at_ms']=0;$row['last_at_ms']=[BitConverter]::Int64BitsToDouble([long]::MinValue);Expect-CodecFailure {New-HopEvidenceEndpointCursor (,$row)} 'timestamp bits'
    $row=New-ViewRow;$row['paired']=$false;Expect-CodecFailure {New-HopEvidenceEndpointCursor (,$row)} 'sealed pair'
}
Invoke-CodecCase 'cursor reset reuses fixed heap and never mutates row or payload references' {
    $row=New-ViewRow 1 3 2;$payload=$row.data;$cursor=New-HopEvidenceEndpointCursor @($row,(New-ViewRow 2));$heap=$cursor.heap
    $null=Read-HopEvidenceEndpoint $cursor;Reset-HopEvidenceEndpointCursor $cursor
    Assert-Codec ([object]::ReferenceEquals($cursor.heap,$heap) -and [object]::ReferenceEquals($row.data,$payload) -and $row.first_call -eq 1 -and $row.last_call -eq 3 -and $row.repeats -eq 2) 'reset copied or mutated evidence'
    Assert-Codec ((Read-HopEvidenceEndpoint $cursor).call_id -eq 1) 'reset changed first endpoint'
}
Invoke-CodecCase 'endpoint input bounds stay 2176 total 2048 regular 128 critical' {
    $rows=[object[]]::new(2176);for($i=0;$i -lt $rows.Count;$i++){$rows[$i]=New-ViewRow ($i+1) ($i+1) 1 ($i -ge 2048)}
    $cursor=New-HopEvidenceEndpointCursor $rows;Assert-Codec ($cursor.heap.Length -eq 2176) 'maximum coalesced inputs rejected or expanded'
    Expect-CodecFailure {New-HopEvidenceEndpointCursor ($rows+@((New-ViewRow 2177 2177 1 $true)))} '2176'
    $rows[2048].critical=$false;Expect-CodecFailure {New-HopEvidenceEndpointCursor $rows} 'regular/critical'
    $rows=[object[]]::new(129);for($i=0;$i -lt 129;$i++){$rows[$i]=New-ViewRow ($i+1) ($i+1) 1 $true};Expect-CodecFailure {New-HopEvidenceEndpointCursor $rows} 'regular/critical'
}
Invoke-CodecCase 'empty cursor has fixed zero-length heap and no absence certificate' {
    $cursor=New-HopEvidenceEndpointCursor @();Assert-Codec ($cursor.heap.Length -eq 0 -and $null -eq (Read-HopEvidenceEndpoint $cursor) -and (Find-HopEvidenceEndpoint $cursor 1).reason -ceq 'UNKNOWN') 'empty view fabricated a fact'
}
Invoke-CodecCase 'known marker rejects nonscalar strings and negative-zero user' {
    foreach($key in @('call','reason','phase')){$data=New-KnownPairData;$data[$key]=@($data[$key]);Assert-Codec (-not(Test-HopEvidencePairedData $data)) ('array field admitted: '+$key)}
    $data=New-KnownPairData 'input.lease_state';$data.status=@('active');Assert-Codec (-not(Test-HopEvidencePairedData $data)) 'array status admitted'
    $data=New-KnownPairData;$data.user=[BitConverter]::Int64BitsToDouble([long]::MinValue);Expect-CodecFailure {Read-Rows (,(New-SealedPair $data))} 'sealed pair'
}
Invoke-CodecCase 'singleton exact parsed Int64 and Decimal timestamps cannot alias through Double' {
    $json=[Text.Json.JsonDocument]::Parse('[9007199254740992,9007199254740993]')
    try{$times=[long[]]@($json.RootElement[0].GetInt64(),$json.RootElement[1].GetInt64())}finally{$json.Dispose()}
    Assert-Codec ([double]$times[0] -eq [double]$times[1]) 'fixture does not exercise Double alias'
    $row=New-ViewRow;$row['first_at_ms']=$times[0];$row['last_at_ms']=$times[1];Expect-CodecFailure {New-HopEvidenceEndpointCursor (,$row)} 'timestamp bits'
    $row=New-ViewRow;$row['first_at_ms']=[decimal]::Parse('9007199254740991.5',[Globalization.CultureInfo]::InvariantCulture);$row['last_at_ms']=[decimal]::Parse('9007199254740992',[Globalization.CultureInfo]::InvariantCulture);Expect-CodecFailure {New-HopEvidenceEndpointCursor (,$row)} 'timestamp bits'
    $row=New-ViewRow;$row['first_at_ms']=[double]9007199254740992;$row['last_at_ms']=$times[1];Expect-CodecFailure {New-HopEvidenceEndpointCursor (,$row)} 'timestamp bits'
    $row.last_at_ms=$times[0];Assert-Codec ((New-HopEvidenceEndpointCursor (,$row)).count -eq 1) 'exact same mixed numeric timestamp refused'
}
Invoke-CodecCase 'lookup refuses coercible strings booleans fractions and range overflow' {
    $cursor=New-HopEvidenceEndpointCursor (,(New-ViewRow))
    foreach($id in @('1',$true,1.5,0,10000001,[double]::NaN,[double]::PositiveInfinity)){Expect-CodecFailure {Find-HopEvidenceEndpoint $cursor $id} 'lookup/cursor'}
    Assert-Codec ((Find-HopEvidenceEndpoint $cursor 1).endpoint.call_id -eq 1 -and -not $cursor.failed) 'invalid query consumed or poisoned valid cursor'
}
Invoke-CodecCase '2048 coalesced rows lazily yield4096 endpoints within the same fixed row heap' {
    $rows=[object[]]::new(2048)
    for($i=0;$i -lt $rows.Count;$i++){$rows[$i]=New-ViewRow ($i*2+1) ($i*2+2) 2}
    $cursor=New-HopEvidenceEndpointCursor $rows;$heap=$cursor.heap
    Assert-Codec ($heap -is [int[]] -and $heap.Length -eq 2048 -and @($cursor.Keys).Count -eq 4 -and [object]::ReferenceEquals($cursor.rows,$rows)) 'cursor changed coalesced row count or allocated an occurrence archive'
    for($id=1;$id -le 4096;$id++){
        $endpoint=Read-HopEvidenceEndpoint $cursor;$index=[int][Math]::Floor(($id-1)/2)
        Assert-Codec ($endpoint.call_id -eq $id -and [object]::ReferenceEquals($endpoint.row,$rows[$index]) -and [object]::ReferenceEquals($endpoint.row.data,$rows[$index].data)) 'maximum lazy endpoints changed order or copied payloads'
        Assert-Codec ([object]::ReferenceEquals($cursor.heap,$heap) -and $heap.Length -eq 2048) 'heap grew with emitted endpoint count'
    }
    Assert-Codec ($null -eq (Read-HopEvidenceEndpoint $cursor) -and $rows.Count -eq 2048 -and $rows[2047].repeats -eq 2) 'EOF expanded or mutated coalesced records'
    Expect-CodecFailure {New-HopEvidenceEndpointCursor ($rows+@((New-ViewRow 4097 4098 2)))} 'regular/critical'
}
Invoke-CodecCase 'mixed numeric singleton times compare exact rationals not shortest decimal aliases' {
    [double]$floating=1e23
    $exactText='99999999999999991611392'
    Assert-Codec (([Numerics.BigInteger]::new($floating)).ToString([Globalization.CultureInfo]::InvariantCulture) -ceq $exactText) 'literal binary64 represented-integer oracle differs'
    $shortDecimal=[decimal]::Parse('100000000000000000000000',[Globalization.CultureInfo]::InvariantCulture)
    $actualDecimal=[decimal]::Parse($exactText,[Globalization.CultureInfo]::InvariantCulture)
    foreach($times in @(@($floating,$shortDecimal),@($shortDecimal,$floating))){
        Assert-Codec ([double]$times[0] -eq [double]$times[1]) 'large alias fixture does not share rounded bits'
        $row=New-ViewRow;$row['first_at_ms']=$times[0];$row['last_at_ms']=$times[1];Expect-CodecFailure {New-HopEvidenceEndpointCursor (,$row)} 'timestamp bits'
    }
    foreach($times in @(@($floating,$actualDecimal),@($actualDecimal,$floating),@([double]1e20,[decimal]::Parse('100000000000000000000',[Globalization.CultureInfo]::InvariantCulture)),@([double]0.5,[decimal]::Parse('0.5',[Globalization.CultureInfo]::InvariantCulture)),@([double]0,[decimal]0))){
        $row=New-ViewRow;$row['first_at_ms']=$times[0];$row['last_at_ms']=$times[1];Assert-Codec ((New-HopEvidenceEndpointCursor (,$row)).count -eq 1) 'exact mixed rational positive control refused'
    }
    foreach($times in @(@([double]0.1,[decimal]::Parse('0.1',[Globalization.CultureInfo]::InvariantCulture)),@([double][decimal]::MaxValue,[decimal]::MaxValue),@([double]::Epsilon,[decimal]0),@([BitConverter]::Int64BitsToDouble([long]::MinValue),[decimal]0))){
        $row=New-ViewRow;$row['first_at_ms']=$times[0];$row['last_at_ms']=$times[1];Expect-CodecFailure {New-HopEvidenceEndpointCursor (,$row)} 'timestamp bits'
    }
}
[pscustomobject]@{suite='hop-delta-v4 PowerShell consumer';cases=$script:caseCount;status='PASS';native_gameplay='UNRUN'}
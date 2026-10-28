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
    $v=[object[]]::new(11);$v[0]=$Critical;$v[1]=$Kind;$v[2]=$Projection;$v[3]=$Base;$v[4]=$First;$v[5]=$First;$v[6]=1;$v[7]=$false;$v[8]=$false;$v[9]=$false;$v[10]=$Node;return ,$v
}
function New-Chunk([object[]]$Rows,[int]$Number=1,[string]$Run='fixture'){
    return [ordered]@{schema=2;encoding='hop-delta-v2';run_id=$Run;chunk=$Number;rows=$Rows}
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
    Assert-Codec ($result.encoding -ceq 'hop-delta-v2' -and $result.rows.Count -eq 1) 'result shape differs'
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
Invoke-CodecCase 'empty input yields one explicit v2 result' {
    $result=Read-HopEvidenceChunks -Chunks @() -RunId fixture;Assert-Codec ($result.rows.Count -eq 0 -and $result.encoding -ceq 'hop-delta-v2') 'empty result differs'
}
Invoke-CodecCase 'legacy and unsupported encodings never downgrade' {
    foreach($schema in @(1,3,'2',$true)){$chunk=New-Chunk -Rows (,(New-Row));$chunk.schema=$schema;Expect-CodecFailure {Read-HopEvidenceChunks -Chunks @($chunk) -RunId fixture}}
    $chunk=New-Chunk -Rows (,(New-Row));$chunk.encoding='hop-delta-v3';Expect-CodecFailure {Read-HopEvidenceChunks -Chunks @($chunk) -RunId fixture}
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
    for($i=0;$i -lt 32;$i++){$inner=[object[]]::new(9);for($j=0;$j -lt 9;$j++){$inner[$j]=New-Pair ($j-9) (New-Scalar 1)};$outer[$i]=New-Pair ($i-32) (New-Table -Pairs $inner)}
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
# Counts are synthetic test-case groups, not native/gameplay qualification.
[pscustomobject]@{suite='hop-delta-v2 PowerShell consumer';cases=$script:caseCount;status='PASS';native_gameplay='UNRUN'}
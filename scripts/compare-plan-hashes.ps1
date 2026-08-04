param(
  [Parameter(Mandatory=$true)][ValidateScript({Test-Path -LiteralPath $_})][string]$BluePlansPath,
  [Parameter(Mandatory=$true)][ValidateScript({Test-Path -LiteralPath $_})][string]$GreenPlansPath,
  [string]$OutputPath = "$PSScriptRoot/../docs/evidence/generated/plan-hash-comparison.json",
  [string]$MarkdownOutputPath
)
$ErrorActionPreference='Stop'
$volatileKeys = @(
  'Actual Startup Time','Actual Total Time','Actual Rows','Actual Loops','Startup Cost','Total Cost','Plan Rows','Plan Width',
  'Planning Time','Execution Time','Workers Launched','Workers','Planning','Triggers','JIT','Settings',
  'Shared Hit Blocks','Shared Read Blocks','Shared Dirtied Blocks','Shared Written Blocks','Local Hit Blocks','Local Read Blocks',
  'Local Dirtied Blocks','Local Written Blocks','Temp Read Blocks','Temp Written Blocks','I/O Read Time','I/O Write Time',
  'Rows Removed by Filter','Rows Removed by Index Recheck','Heap Fetches','WAL Records','WAL FPI','WAL Bytes',
  'Sort Space Used'
)
function ConvertTo-Canonical($value) {
  if($null -eq $value){return $null}
  if($value -is [System.Collections.IEnumerable] -and $value -isnot [string] -and $value -isnot [System.Collections.IDictionary] -and $value -isnot [pscustomobject]){ return @($value | ForEach-Object { ConvertTo-Canonical $_ }) }
  if($value -is [System.Collections.IDictionary]){ $props=$value.Keys } elseif($value -is [pscustomobject]){ $props=$value.PSObject.Properties.Name } else { return $value }
  $ordered=[ordered]@{}
  foreach($name in @($props | Where-Object {$_ -notin $volatileKeys} | Sort-Object)){ $child=if($value -is [System.Collections.IDictionary]){$value[$name]}else{$value.$name}; $ordered[$name]=ConvertTo-Canonical $child }
  return [pscustomobject]$ordered
}
function Read-Plans([string]$path){
  $text=Get-Content -Raw -LiteralPath $path; $map=@{}
  foreach($m in [regex]::Matches($text,'(?ms)^PLAN_BEGIN=(?<name>[a-z0-9_-]+)\s*\r?\n(?<json>.*?)^PLAN_END=\k<name>\s*$')){
    $parsed=$m.Groups['json'].Value.Trim() | ConvertFrom-Json
    $canonical=ConvertTo-Canonical $parsed
    $json=$canonical | ConvertTo-Json -Depth 100 -Compress
    $sha=[Security.Cryptography.SHA256]::Create(); try{$hash=(($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json))|ForEach-Object{$_.ToString('x2')})-join'')}finally{$sha.Dispose()}
    $map[$m.Groups['name'].Value]=[pscustomobject]@{hash=$hash;canonical_plan=$canonical}
  }
  if($map.Count -eq 0){throw "No marked JSON plans found in $path"}; return $map
}
$blue=Read-Plans $BluePlansPath; $green=Read-Plans $GreenPlansPath
$names=@($blue.Keys+$green.Keys|Sort-Object -Unique)
$report=foreach($name in $names){
  $bluePlan=$blue[$name];$greenPlan=$green[$name]
  $changed=if($bluePlan -and $greenPlan){$bluePlan.hash -ne $greenPlan.hash}else{$true}
  [pscustomobject][ordered]@{
    name=$name
    blue_hash=if($bluePlan){$bluePlan.hash}else{$null}
    green_hash=if($greenPlan){$greenPlan.hash}else{$null}
    plan_changed=$changed
    review_status=if(-not $bluePlan){'MISSING_BLUE'}elseif(-not $greenPlan){'MISSING_GREEN'}elseif($changed){'REVIEW_PLAN_CHANGE'}else{'UNCHANGED'}
  }
}
if(-not $MarkdownOutputPath){$MarkdownOutputPath=[IO.Path]::ChangeExtension($OutputPath,'.md')}
New-Item -Force -ItemType Directory -Path (Split-Path -Parent $OutputPath)|Out-Null
New-Item -Force -ItemType Directory -Path (Split-Path -Parent $MarkdownOutputPath)|Out-Null
$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $OutputPath -Encoding UTF8
$changedCount=@($report|Where-Object{$_.review_status -ne 'UNCHANGED'}).Count
$lines=@(
  '# PostgreSQL plan hash comparison','',
  "- Generated (UTC): $((Get-Date).ToUniversalTime().ToString('o'))",
  "- Blue raw plans: ``$([IO.Path]::GetFileName($BluePlansPath))``",
  "- Green raw plans: ``$([IO.Path]::GetFileName($GreenPlansPath))``",
  "- Plans compared: $($report.Count)",
  "- Plans requiring review: $changedCount",'',
  '| SQL label | Blue plan hash | Green plan hash | Changed | Review status |',
  '|---|---|---|:---:|---|'
)
foreach($item in $report){
  $blueShort=if($item.blue_hash){$item.blue_hash.Substring(0,16)}else{'-'}
  $greenShort=if($item.green_hash){$item.green_hash.Substring(0,16)}else{'-'}
  $lines+="| ``$($item.name)`` | ``$blueShort`` | ``$greenShort`` | $($item.plan_changed) | **$($item.review_status)** |"
}
$lines+=@(
  '', '## Interpretation', '',
  '- `UNCHANGED`: the canonical plan structure is identical after volatile fields were removed.',
  '- `REVIEW_PLAN_CHANGE`: inspect node, join and index changes together with execution time and buffer statistics.',
  '- `MISSING_BLUE` / `MISSING_GREEN`: the approved SQL was not captured on one side and the evidence is incomplete.',
  '- A changed hash is a review signal, not automatic proof of performance regression.', '',
  'Full SHA-256 values are retained in the adjacent JSON report.'
)
$lines|Set-Content -LiteralPath $MarkdownOutputPath -Encoding UTF8
$report|Format-Table -AutoSize
Write-Host "JSON report: $([IO.Path]::GetFullPath($OutputPath))"
Write-Host "Markdown report: $([IO.Path]::GetFullPath($MarkdownOutputPath))"

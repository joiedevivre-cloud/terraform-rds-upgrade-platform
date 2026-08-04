param(
  [string]$Region='ca-central-1',[string]$Profile='portfolio-bootstrap',
  [Parameter(Mandatory=$true)][string]$InstanceId,
  [Parameter(Mandatory=$true)][string]$SecretArn,
  [Parameter(Mandatory=$true)][string]$DbHost,
  [string]$DbName='upgrade_lab',[Parameter(Mandatory=$true)][string]$EnvironmentLabel,
  [string]$SqlPath="$PSScriptRoot/../sql/critical-plans.sql",
  [string]$OutputPath,[ValidateRange(30,1800)][int]$TimeoutSeconds=300
)
$ErrorActionPreference='Stop'
if(-not(Test-Path -LiteralPath $SqlPath)){throw "SQL file not found: $SqlPath"}
if(-not $OutputPath){$stamp=(Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ');$OutputPath="$PSScriptRoot/../docs/evidence/generated/$EnvironmentLabel-critical-plans-$stamp.txt"}
$sql64=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path $SqlPath)))
$template=@'
set -euo pipefail
printf '%s' '__SQL__' | base64 --decode > /tmp/critical-plans.sql
SECRET_JSON="$(aws secretsmanager get-secret-value --secret-id '__SECRET__' --region '__REGION__' --query SecretString --output text)"; export SECRET_JSON
PGUSER="$(python3 -c 'import json,os; print(json.loads(os.environ["SECRET_JSON"])["username"])')"
PGPASSWORD="$(python3 -c 'import json,os; print(json.loads(os.environ["SECRET_JSON"])["password"])')"; export PGPASSWORD
psql "host=__HOST__ port=5432 dbname=__DB__ user=$PGUSER sslmode=require connect_timeout=10" -X -A -t -v ON_ERROR_STOP=1 -f /tmp/critical-plans.sql > /tmp/critical-plans.txt
printf 'PLANS_GZIP_BASE64_BEGIN\n'; gzip -c /tmp/critical-plans.txt | base64 -w 0; printf '\nPLANS_GZIP_BASE64_END\n'
unset SECRET_JSON PGUSER PGPASSWORD; rm -f /tmp/critical-plans.sql /tmp/critical-plans.txt
'@
$command=$template.Replace('__SQL__',$sql64).Replace('__SECRET__',$SecretArn).Replace('__REGION__',$Region).Replace('__HOST__',$DbHost).Replace('__DB__',$DbName)
$requestPath=[IO.Path]::GetTempFileName();$utf8=New-Object Text.UTF8Encoding($false)
try{
  [IO.File]::WriteAllText($requestPath,(@{InstanceIds=@($InstanceId);DocumentName='AWS-RunShellScript';Comment='Capture approved PostgreSQL JSON plans';Parameters=@{commands=@($command)}}|ConvertTo-Json -Depth 8),$utf8)
  $send=aws ssm send-command --cli-input-json "file://$requestPath" --region $Region --profile $Profile --output json|ConvertFrom-Json
  if($LASTEXITCODE-ne 0-or-not $send.Command.CommandId){throw 'SSM rejected plan capture.'};$deadline=(Get-Date).AddSeconds($TimeoutSeconds)
  do{Start-Sleep 3;$result=aws ssm get-command-invocation --command-id $send.Command.CommandId --instance-id $InstanceId --region $Region --profile $Profile --output json|ConvertFrom-Json;if((Get-Date)-ge $deadline){throw 'Plan capture timed out.'}}while($result.Status-in@('Pending','InProgress','Delayed'))
  if($result.Status-ne'Success'){throw "Plan capture failed: $($result.StandardErrorContent)"}
  $m=[regex]::Match($result.StandardOutputContent,'PLANS_GZIP_BASE64_BEGIN\s*(?<data>[A-Za-z0-9+/=]+)\s*PLANS_GZIP_BASE64_END');if(-not$m.Success){throw 'Plan payload missing.'}
  $input=[IO.MemoryStream]::new([Convert]::FromBase64String($m.Groups['data'].Value));$gzip=[IO.Compression.GzipStream]::new($input,[IO.Compression.CompressionMode]::Decompress);$output=[IO.MemoryStream]::new()
  try{$gzip.CopyTo($output);$raw=$utf8.GetString($output.ToArray())}finally{$gzip.Dispose();$input.Dispose();$output.Dispose()}
  New-Item -ItemType Directory -Force -Path(Split-Path -Parent $OutputPath)|Out-Null;[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),$raw,$utf8);Write-Host "Raw plans: $([IO.Path]::GetFullPath($OutputPath))"
}finally{Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue}

param(
  [string]$Region = "ca-central-1", [string]$Profile = "portfolio-bootstrap",
  [Parameter(Mandatory = $true)][string]$InstanceId,
  [Parameter(Mandatory = $true)][string]$SecretArn,
  [Parameter(Mandatory = $true)][string]$DbHost,
  [string]$DbName = "upgrade_lab",
  [ValidateRange(0, 100)][int]$WarmupIterations = 5,
  [ValidateRange(1, 10000)][int]$MeasuredIterations = 50,
  [string]$SqlPath = "$PSScriptRoot/../sql/representative-workload.sql",
  [ValidateRange(30, 3600)][int]$TimeoutSeconds = 900
)
$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $SqlPath)) { throw "SQL file not found: $SqlPath" }
$sqlBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path $SqlPath)))
$template = @'
set -euo pipefail
printf '%s' '__SQL__' | base64 --decode > /tmp/representative-workload.sql
SECRET_JSON="$(aws secretsmanager get-secret-value --secret-id '__SECRET__' --region '__REGION__' --query SecretString --output text)"; export SECRET_JSON
PGUSER="$(python3 -c 'import json,os; print(json.loads(os.environ["SECRET_JSON"])["username"])')"
PGPASSWORD="$(python3 -c 'import json,os; print(json.loads(os.environ["SECRET_JSON"])["password"])')"; export PGPASSWORD
CONN="host=__HOST__ port=5432 dbname=__DB__ user=$PGUSER sslmode=require connect_timeout=10 application_name=ranked-workload"
for i in $(seq 1 __WARMUP__); do psql "$CONN" -X -q -v ON_ERROR_STOP=1 -f /tmp/representative-workload.sql >/dev/null; done
psql "$CONN" -X -q -v ON_ERROR_STOP=1 -c 'SELECT pg_stat_statements_reset();' >/dev/null
for i in $(seq 1 __MEASURED__); do psql "$CONN" -X -q -v ON_ERROR_STOP=1 -f /tmp/representative-workload.sql >/dev/null; done
printf 'RANKED_WORKLOAD_RESULT=PASS WARMUP=__WARMUP__ MEASURED=__MEASURED__\n'
unset SECRET_JSON PGUSER PGPASSWORD CONN; rm -f /tmp/representative-workload.sql
'@
$command = $template.Replace('__SQL__',$sqlBase64).Replace('__SECRET__',$SecretArn).Replace('__REGION__',$Region).Replace('__HOST__',$DbHost).Replace('__DB__',$DbName).Replace('__WARMUP__',$WarmupIterations).Replace('__MEASURED__',$MeasuredIterations)
$requestPath = [IO.Path]::GetTempFileName(); $utf8 = New-Object Text.UTF8Encoding($false)
try {
  [IO.File]::WriteAllText($requestPath, (@{InstanceIds=@($InstanceId);DocumentName='AWS-RunShellScript';Comment='Reset and run fixed PostgreSQL workload';Parameters=@{commands=@($command)}} | ConvertTo-Json -Depth 8), $utf8)
  $send = aws ssm send-command --cli-input-json "file://$requestPath" --region $Region --profile $Profile --output json | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or -not $send.Command.CommandId) { throw 'SSM rejected workload command.' }
  $deadline=(Get-Date).AddSeconds($TimeoutSeconds)
  do { Start-Sleep 3; $result=aws ssm get-command-invocation --command-id $send.Command.CommandId --instance-id $InstanceId --region $Region --profile $Profile --output json | ConvertFrom-Json; if((Get-Date)-ge $deadline){throw 'Workload timed out.'} } while($result.Status -in @('Pending','InProgress','Delayed'))
  if($result.Status -ne 'Success' -or $result.StandardOutputContent -notmatch 'RANKED_WORKLOAD_RESULT=PASS'){throw "Workload failed: $($result.StandardErrorContent)"}
  Write-Host $result.StandardOutputContent.Trim()
  Write-Host 'Capture query statistics now, before any unrelated SQL contaminates the window.'
} finally { Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue }

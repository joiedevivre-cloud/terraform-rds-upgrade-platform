param(
  [string]$Region = "ca-central-1",
  [string]$Profile = "portfolio-bootstrap",
  [Parameter(Mandatory = $true)][string]$InstanceId,
  [Parameter(Mandatory = $true)][string]$SecretArn,
  [Parameter(Mandatory = $true)][string]$DbHost,
  [string]$DbName = "upgrade_lab",
  [Parameter(Mandatory = $true)][string]$EnvironmentLabel,
  [ValidateRange(1, 100000)][int]$Iterations = 200,
  [string]$OutputPath,
  [ValidateRange(30, 1800)][int]$TimeoutSeconds = 600
)

$ErrorActionPreference = "Stop"
if ($InstanceId -notmatch '^i-[0-9a-f]+$') { throw "Invalid EC2 instance ID." }
if ($DbHost -notmatch '^[a-zA-Z0-9.-]+\.rds\.amazonaws\.com$') { throw "Invalid RDS hostname." }

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
if (-not $OutputPath) { $OutputPath = "$PSScriptRoot/../docs/evidence/generated/$EnvironmentLabel-latency-$timestamp.csv" }

# Green is enforced read-only at the database level until switchover (AWS blocks
# writes, including CREATE TEMP TABLE, from client sessions) — confirmed live when
# this script's original temp-table version failed with "cannot execute CREATE
# TABLE in a read-only transaction" against Green. This version never writes:
# it repeats the same read-only representative query N times behind \timing and
# parses the client-side "Time: ... ms" lines psql prints after each statement.
# Using the identical technique on Blue keeps the comparison apples-to-apples.
$query = "SELECT customer_id, count(*), sum(total_amount) FROM portfolio_orders WHERE created_at >= now() - interval '30 days' GROUP BY customer_id ORDER BY sum(total_amount) DESC LIMIT 100;"
$sqlLines = @('\timing on', '\pset tuples_only on', '\pset format unaligned', '\o /dev/null')
for ($i = 0; $i -lt $Iterations; $i++) { $sqlLines += $query }
$sqlLines += '\o'
$sql = ($sqlLines -join "`n") + "`n"
$sqlBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($sql))

$remoteTemplate = @'
set -euo pipefail
printf '%s' '__SQL_BASE64__' | base64 --decode > /tmp/latency-samples.sql
SECRET_JSON="$(aws secretsmanager get-secret-value --secret-id '__SECRET_ARN__' --region '__REGION__' --query SecretString --output text)"
export SECRET_JSON
PGUSER="$(python3 -c 'import json,os; print(json.loads(os.environ["SECRET_JSON"])["username"])')"
PGPASSWORD="$(python3 -c 'import json,os; print(json.loads(os.environ["SECRET_JSON"])["password"])')"
export PGPASSWORD
CAPTURE_TS="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
psql "host=__DB_HOST__ port=5432 dbname=__DB_NAME__ user=$PGUSER sslmode=require connect_timeout=10 application_name=latency-capture" -X -f /tmp/latency-samples.sql > /tmp/latency-raw.txt
echo "timestamp_utc,latency_ms,success" > /tmp/latency-samples.csv
grep -oE 'Time: [0-9.]+ ms' /tmp/latency-raw.txt | awk -v ts="$CAPTURE_TS" '{print ts","$2",true"}' >> /tmp/latency-samples.csv
printf 'LATENCY_GZIP_BASE64_BEGIN\n'
gzip -c /tmp/latency-samples.csv | base64 -w 0
printf '\nLATENCY_GZIP_BASE64_END\n'
unset SECRET_JSON PGUSER PGPASSWORD
rm -f /tmp/latency-samples.sql /tmp/latency-raw.txt /tmp/latency-samples.csv
'@
$remoteCommand = $remoteTemplate.Replace('__SQL_BASE64__', $sqlBase64).Replace('__SECRET_ARN__', $SecretArn).Replace('__REGION__', $Region).Replace('__DB_HOST__', $DbHost).Replace('__DB_NAME__', $DbName)

$requestPath = [System.IO.Path]::GetTempFileName()
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try {
  $request = @{ InstanceIds = @($InstanceId); DocumentName = "AWS-RunShellScript"; Comment = "Capture per-sample workload latency"; Parameters = @{ commands = @($remoteCommand) } } | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText($requestPath, $request, $utf8NoBom)

  $send = aws ssm send-command --cli-input-json "file://$requestPath" --region $Region --profile $Profile --output json | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or -not $send.Command.CommandId) { throw "SSM rejected the latency-capture command." }
  $commandId = $send.Command.CommandId
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    Start-Sleep -Seconds 3
    $invocation = aws ssm get-command-invocation --command-id $commandId --instance-id $InstanceId --region $Region --profile $Profile --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Unable to retrieve SSM command result $commandId." }
    if ((Get-Date) -ge $deadline) { throw "Timed out waiting for latency-capture command $commandId." }
  } while ($invocation.Status -in @("Pending", "InProgress", "Delayed"))
  if ($invocation.Status -ne "Success" -or $invocation.ResponseCode -ne 0) { throw "Latency capture failed: $($invocation.StandardErrorContent)" }

  $match = [regex]::Match($invocation.StandardOutputContent, 'LATENCY_GZIP_BASE64_BEGIN\s*(?<data>[A-Za-z0-9+/=]+)\s*LATENCY_GZIP_BASE64_END')
  if (-not $match.Success) { throw "SSM output did not contain a latency-sample payload." }
  $compressed = [Convert]::FromBase64String($match.Groups['data'].Value)
  $inputStream = [System.IO.MemoryStream]::new($compressed)
  $gzipStream = [System.IO.Compression.GzipStream]::new($inputStream, [System.IO.Compression.CompressionMode]::Decompress)
  $outputStream = [System.IO.MemoryStream]::new()
  try {
    $gzipStream.CopyTo($outputStream)
    $csv = $utf8NoBom.GetString($outputStream.ToArray())
  }
  finally {
    $gzipStream.Dispose(); $inputStream.Dispose(); $outputStream.Dispose()
  }

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
  [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutputPath), $csv, $utf8NoBom)
  $rows = @($csv | ConvertFrom-Csv)
  $successCount = @($rows | Where-Object { $_.success -eq "true" }).Count
  Write-Host "Captured $($rows.Count) latency samples ($successCount succeeded, $($rows.Count - $successCount) failed)."
  Write-Host "Evidence: $([System.IO.Path]::GetFullPath($OutputPath))"
}
finally {
  if (Test-Path -LiteralPath $requestPath) { Remove-Item -LiteralPath $requestPath -Force }
}

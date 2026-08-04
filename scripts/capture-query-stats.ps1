param(
  [string]$Region = "ca-central-1",
  [string]$Profile = "portfolio-bootstrap",
  [Parameter(Mandatory = $true)][string]$InstanceId,
  [Parameter(Mandatory = $true)][string]$SecretArn,
  [Parameter(Mandatory = $true)][string]$DbHost,
  [string]$DbName = "upgrade_lab",
  [Parameter(Mandatory = $true)][string]$EnvironmentLabel,
  [ValidateRange(1, 100)][int]$TopNPerDimension = 20,
  [string]$SqlPath = "$PSScriptRoot/../sql/query-stats-snapshot.sql",
  [string]$OutputPath,
  [ValidateRange(30, 1800)][int]$TimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"
if ($InstanceId -notmatch '^i-[0-9a-f]+$') { throw "Invalid EC2 instance ID." }
if ($DbHost -notmatch '^[a-zA-Z0-9.-]+\.rds\.amazonaws\.com$') { throw "Invalid RDS hostname." }
if (-not (Test-Path -LiteralPath $SqlPath)) { throw "SQL file not found: $SqlPath" }

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
if (-not $OutputPath) { $OutputPath = "$PSScriptRoot/../docs/evidence/generated/$EnvironmentLabel-query-stats-$timestamp.csv" }
$sqlBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $SqlPath)))
$remoteTemplate = @'
set -euo pipefail
printf '%s' '__SQL_BASE64__' | base64 --decode > /tmp/query-stats.sql
SECRET_JSON="$(aws secretsmanager get-secret-value --secret-id '__SECRET_ARN__' --region '__REGION__' --query SecretString --output text)"
export SECRET_JSON
PGUSER="$(python3 -c 'import json,os; print(json.loads(os.environ["SECRET_JSON"])["username"])')"
PGPASSWORD="$(python3 -c 'import json,os; print(json.loads(os.environ["SECRET_JSON"])["password"])')"
export PGPASSWORD
psql "host=__DB_HOST__ port=5432 dbname=__DB_NAME__ user=$PGUSER sslmode=require connect_timeout=10" -X --csv -v ON_ERROR_STOP=1 -v top_n=__TOP_N__ -f /tmp/query-stats.sql > /tmp/query-stats.csv
printf 'QUERY_STATS_GZIP_BASE64_BEGIN\n'
gzip -c /tmp/query-stats.csv | base64 -w 0
printf '\nQUERY_STATS_BASE64_END\n'
unset SECRET_JSON PGUSER PGPASSWORD
rm -f /tmp/query-stats.sql /tmp/query-stats.csv
'@
$remoteCommand = $remoteTemplate.Replace('__SQL_BASE64__', $sqlBase64).Replace('__SECRET_ARN__', $SecretArn).Replace('__REGION__', $Region).Replace('__DB_HOST__', $DbHost).Replace('__DB_NAME__', $DbName).Replace('__TOP_N__', $TopNPerDimension.ToString())
$requestPath = [System.IO.Path]::GetTempFileName()
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try {
  $request = @{ InstanceIds = @($InstanceId); DocumentName = "AWS-RunShellScript"; Comment = "Capture impact-ranked PostgreSQL statistics"; Parameters = @{ commands = @($remoteCommand) } } | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText($requestPath, $request, $utf8NoBom)
  $send = aws ssm send-command --cli-input-json "file://$requestPath" --region $Region --profile $Profile --output json | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or -not $send.Command.CommandId) { throw "SSM rejected the query-statistics command." }
  $commandId = $send.Command.CommandId
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    Start-Sleep -Seconds 3
    $invocation = aws ssm get-command-invocation --command-id $commandId --instance-id $InstanceId --region $Region --profile $Profile --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Unable to retrieve SSM command result $commandId." }
    if ((Get-Date) -ge $deadline) { throw "Timed out waiting for query-statistics command $commandId." }
  } while ($invocation.Status -in @("Pending", "InProgress", "Delayed"))
  if ($invocation.Status -ne "Success" -or $invocation.ResponseCode -ne 0) { throw "Query-statistics capture failed: $($invocation.StandardErrorContent)" }
  $match = [regex]::Match($invocation.StandardOutputContent, 'QUERY_STATS_GZIP_BASE64_BEGIN\s*(?<data>[A-Za-z0-9+/=]+)\s*QUERY_STATS_BASE64_END')
  if (-not $match.Success) { throw "SSM output did not contain a query-statistics payload." }
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
  $rows = @($csv | ConvertFrom-Csv)
  foreach ($row in $rows) {
    $bytes = $utf8NoBom.GetBytes($row.normalized_query.ToLowerInvariant())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $fingerprint = (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
    $row | Add-Member -NotePropertyName sql_fingerprint_sha256 -NotePropertyValue $fingerprint
    $row | Add-Member -NotePropertyName environment -NotePropertyValue $EnvironmentLabel
    $row | Add-Member -NotePropertyName captured_at_utc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o'))
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
  $rows | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
  Write-Host "Captured $($rows.Count) impact-ranked statements without executing application SQL."
  Write-Host "Evidence: $([System.IO.Path]::GetFullPath($OutputPath))"
}
finally { if (Test-Path -LiteralPath $requestPath) { Remove-Item -LiteralPath $requestPath -Force } }

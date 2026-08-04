param(
  [string]$Region = "ca-central-1",
  [string]$Profile = "portfolio-bootstrap",
  [Parameter(Mandatory = $true)][string]$InstanceId,
  [Parameter(Mandatory = $true)][string]$SecretArn,
  [Parameter(Mandatory = $true)][string]$DbHost,
  [string]$DbName = "upgrade_lab",
  [string]$SqlPath = "$PSScriptRoot/../sql/precheck.sql",
  [string]$OutputPath,
  [ValidateRange(30, 1800)][int]$TimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"
if ($InstanceId -notmatch '^i-[0-9a-f]+$') { throw "Invalid EC2 instance ID." }
if ($DbHost -notmatch '^[a-zA-Z0-9.-]+\.rds\.amazonaws\.com$') { throw "Invalid RDS hostname." }
if (-not (Test-Path -LiteralPath $SqlPath)) { throw "SQL file not found: $SqlPath" }

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
if (-not $OutputPath) { $OutputPath = "$PSScriptRoot/../docs/evidence/generated/postgresql-precheck-$timestamp.json" }
$sqlBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $SqlPath)))

$remoteTemplate = @'
set -euo pipefail
printf '%s' '__SQL_BASE64__' | base64 --decode > /tmp/portfolio-precheck.sql
SECRET_JSON="$(aws secretsmanager get-secret-value --secret-id '__SECRET_ARN__' --region '__REGION__' --query SecretString --output text)"
export SECRET_JSON
PGUSER="$(python3 -c 'import json,os; print(json.loads(os.environ["SECRET_JSON"])["username"])')"
PGPASSWORD="$(python3 -c 'import json,os; print(json.loads(os.environ["SECRET_JSON"])["password"])')"
export PGPASSWORD
psql "host=__DB_HOST__ port=5432 dbname=__DB_NAME__ user=$PGUSER sslmode=require connect_timeout=10" -X -v ON_ERROR_STOP=1 -f /tmp/portfolio-precheck.sql
unset SECRET_JSON PGUSER PGPASSWORD
rm -f /tmp/portfolio-precheck.sql
'@
$remoteCommand = $remoteTemplate.Replace('__SQL_BASE64__', $sqlBase64).Replace('__SECRET_ARN__', $SecretArn).Replace('__REGION__', $Region).Replace('__DB_HOST__', $DbHost).Replace('__DB_NAME__', $DbName)

$requestPath = [System.IO.Path]::GetTempFileName()
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try {
  $request = @{
    InstanceIds  = @($InstanceId)
    DocumentName = "AWS-RunShellScript"
    Comment      = "Aurora PostgreSQL major-upgrade SQL precheck"
    Parameters   = @{ commands = @($remoteCommand) }
  } | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText($requestPath, $request, $utf8NoBom)

  $send = aws ssm send-command --cli-input-json "file://$requestPath" --region $Region --profile $Profile --output json | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or -not $send.Command.CommandId) { throw "SSM rejected the SQL precheck command." }
  $commandId = $send.Command.CommandId
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    Start-Sleep -Seconds 3
    $invocation = aws ssm get-command-invocation --command-id $commandId --instance-id $InstanceId --region $Region --profile $Profile --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Unable to retrieve SSM command result $commandId." }
    if ((Get-Date) -ge $deadline) { throw "Timed out waiting for SQL precheck command $commandId." }
  } while ($invocation.Status -in @("Pending", "InProgress", "Delayed"))

  $summaryMatch = [regex]::Match($invocation.StandardOutputContent, 'PRECHECK_JSON=(\{.*\})')
  $summary = if ($summaryMatch.Success) { $summaryMatch.Groups[1].Value | ConvertFrom-Json } else { $null }
  $result = if ($invocation.Status -eq "Success" -and $invocation.ResponseCode -eq 0 -and $summary.result -eq "PASS") { "PASS" } else { "FAIL" }
  $report = [ordered]@{
    schema_version = 1; result = $result; checked_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    instance_id = $InstanceId; database_host = $DbHost; database_name = $DbName; command_id = $commandId
    ssm_status = $invocation.Status; response_code = $invocation.ResponseCode; summary = $summary
    stdout = $invocation.StandardOutputContent; stderr = $invocation.StandardErrorContent
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
  $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
  Write-Host "SQL precheck result: $result"
  Write-Host "Evidence: $([System.IO.Path]::GetFullPath($OutputPath))"
  if ($result -ne "PASS") { throw "SQL precheck failed. Review the evidence JSON before Blue/Green creation." }
}
finally {
  if (Test-Path -LiteralPath $requestPath) { Remove-Item -LiteralPath $requestPath -Force }
}

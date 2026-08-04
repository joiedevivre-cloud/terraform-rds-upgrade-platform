param(
  [string]$Region = "ca-central-1",
  [string]$Profile = "portfolio-bootstrap",
  [Parameter(Mandatory = $true)][string]$SecretArn,
  [Parameter(Mandatory = $true)][string]$DbHost,
  [int]$DbPort = 5432,
  [string]$DbName = "upgrade_lab",
  [string]$DbUser = "portfolio_admin",
  [Parameter(Mandatory = $true)][string]$EngineLabel,
  [ValidateRange(1, 100000)][int]$Iterations = 200,
  [string]$OutputPath,
  [ValidateRange(1, 300)][int]$ConnectTimeoutSeconds = 10
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
  throw "psql was not found on PATH. Install the PostgreSQL client on this runner before replaying the workload."
}

if (-not $OutputPath) {
  $OutputPath = "$PSScriptRoot/../docs/evidence/generated/$EngineLabel-metrics.csv"
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath) -replace '\\', '/'

Write-Host "Fetching database credentials from Secrets Manager"
$secretString = aws secretsmanager get-secret-value `
  --secret-id $SecretArn `
  --region $Region `
  --profile $Profile `
  --query SecretString `
  --output text
if ($LASTEXITCODE -ne 0 -or -not $secretString) {
  throw "Failed to retrieve secret $SecretArn from Secrets Manager."
}

$dbUser = $DbUser
$dbPassword = $null
try {
  $secretObject = $secretString | ConvertFrom-Json -ErrorAction Stop
  if ($secretObject.PSObject.Properties.Name -contains "password") {
    $dbPassword = $secretObject.password
  }
  if ($secretObject.PSObject.Properties.Name -contains "username" -and -not $PSBoundParameters.ContainsKey("DbUser")) {
    $dbUser = $secretObject.username
  }
}
catch {
  # Independently managed secrets may store a bare password string instead of the
  # RDS-managed {username,password,...} JSON shape.
  $dbPassword = $secretString
}
if (-not $dbPassword) {
  throw "Secret $SecretArn did not contain a usable password."
}

# The workload query mirrors sql/performance.sql exactly, so Blue and Green are
# compared on identical query shape/plan surface.
$query = @'
SELECT customer_id, count(*), sum(total_amount)
FROM portfolio_orders
WHERE created_at >= now() - interval '30 days'
GROUP BY customer_id
ORDER BY sum(total_amount) DESC
LIMIT 100
'@

# A single psql connection drives the whole loop in PL/pgSQL so per-sample latency
# reflects database execution time only, not repeated process-spawn overhead.
$workloadSqlTemplate = @'
\set ON_ERROR_STOP on

CREATE TEMP TABLE workload_samples (
  sample_no      integer,
  started_at_utc timestamptz,
  latency_ms     numeric(12,3),
  success        boolean,
  error_message  text
);

DO $do$
DECLARE
  i        integer;
  start_ts timestamptz;
  end_ts   timestamptz;
BEGIN
  FOR i IN 1..__ITERATIONS_COUNT__ LOOP
    start_ts := clock_timestamp();
    BEGIN
      PERFORM 1 FROM (__QUERY__) AS workload_query;
      end_ts := clock_timestamp();
      INSERT INTO workload_samples
        VALUES (i, start_ts, EXTRACT(EPOCH FROM (end_ts - start_ts)) * 1000, true, NULL);
    EXCEPTION WHEN OTHERS THEN
      end_ts := clock_timestamp();
      INSERT INTO workload_samples
        VALUES (i, start_ts, EXTRACT(EPOCH FROM (end_ts - start_ts)) * 1000, false, SQLERRM);
    END;
  END LOOP;
END
$do$;

\copy (SELECT to_char(started_at_utc AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS timestamp_utc, latency_ms, CASE WHEN success THEN 'true' ELSE 'false' END AS success FROM workload_samples ORDER BY sample_no) TO '__OUTPUT_PATH__' WITH CSV HEADER
'@

$workloadSql = $workloadSqlTemplate.Replace('__QUERY__', $query).Replace('__OUTPUT_PATH__', $resolvedOutputPath).Replace('__ITERATIONS_COUNT__', $Iterations.ToString())

$tempSqlPath = Join-Path ([System.IO.Path]::GetTempPath()) "run-workload-$([guid]::NewGuid()).sql"
[System.IO.File]::WriteAllText($tempSqlPath, $workloadSql, (New-Object System.Text.UTF8Encoding($false)))

$env:PGPASSWORD = $dbPassword
try {
  $connString = "host=$DbHost port=$DbPort dbname=$DbName user=$dbUser sslmode=require connect_timeout=$ConnectTimeoutSeconds application_name=workload-runner"
  Write-Host "Replaying $Iterations workload iterations against $DbHost (engine label '$EngineLabel')"
  psql $connString -f $tempSqlPath
  if ($LASTEXITCODE -ne 0) {
    throw "psql exited with code $LASTEXITCODE while replaying the workload."
  }
}
finally {
  Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tempSqlPath -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $OutputPath)) {
  throw "Expected metrics file was not created at $OutputPath."
}
$rows = @(Import-Csv -LiteralPath $OutputPath)
$successCount = @($rows | Where-Object { $_.success -eq "true" }).Count
$failureCount = $rows.Count - $successCount
Write-Host "Wrote $($rows.Count) samples to $OutputPath ($successCount succeeded, $failureCount failed)."

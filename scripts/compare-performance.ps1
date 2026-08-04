param(
  [Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ })][string]$BlueMetricsPath,
  [Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ })][string]$GreenMetricsPath,
  [Parameter(Mandatory = $true)][ValidateRange(0, 9223372036854775807)][long]$BlueRowCount,
  [Parameter(Mandatory = $true)][ValidateRange(0, 9223372036854775807)][long]$GreenRowCount,
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$BlueChecksum,
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$GreenChecksum,
  [string]$BlueVersion = "15.10",
  [string]$GreenVersion = "16.8",
  [string]$OutputDirectory = "$PSScriptRoot/../docs/evidence/generated",
  [ValidateRange(0, 100)][double]$MaximumP95RegressionPercent = 15,
  [ValidateRange(0, 100)][double]$MaximumErrorRatePercent = 1,
  [switch]$EnforceGates
)

$ErrorActionPreference = "Stop"

function Get-Percentile {
  param([double[]]$Values, [ValidateRange(0, 1)][double]$Percentile)
  if ($Values.Count -eq 0) { throw "Cannot calculate a percentile from an empty dataset." }
  $sorted = @($Values | Sort-Object)
  $index = [Math]::Max(0, [Math]::Ceiling($Percentile * $sorted.Count) - 1)
  return [double]$sorted[$index]
}

function Get-WorkloadSummary {
  param([string]$Path, [string]$Version)
  $rows = @(Import-Csv -LiteralPath $Path)
  if ($rows.Count -eq 0) { throw "Metrics file is empty: $Path" }
  $requiredColumns = @("latency_ms", "success")
  foreach ($column in $requiredColumns) {
    if ($rows[0].PSObject.Properties.Name -notcontains $column) {
      throw "Metrics file $Path is missing required column '$column'."
    }
  }

  $latencies = @()
  $errors = 0
  foreach ($row in $rows) {
    $latency = 0.0
    if (-not [double]::TryParse($row.latency_ms, [ref]$latency) -or $latency -lt 0) {
      throw "Invalid latency_ms '$($row.latency_ms)' in $Path."
    }
    $latencies += $latency
    if ($row.success.ToString().Trim().ToLowerInvariant() -notin @("true", "1", "yes")) {
      $errors++
    }
  }

  [pscustomobject]@{
    Version          = $Version
    Samples          = $rows.Count
    ErrorCount       = $errors
    ErrorRatePercent = [Math]::Round(($errors * 100.0) / $rows.Count, 4)
    P50Milliseconds  = [Math]::Round((Get-Percentile -Values $latencies -Percentile 0.50), 3)
    P95Milliseconds  = [Math]::Round((Get-Percentile -Values $latencies -Percentile 0.95), 3)
    P99Milliseconds  = [Math]::Round((Get-Percentile -Values $latencies -Percentile 0.99), 3)
  }
}

$blue = Get-WorkloadSummary -Path $BlueMetricsPath -Version $BlueVersion
$green = Get-WorkloadSummary -Path $GreenMetricsPath -Version $GreenVersion
if ($blue.P95Milliseconds -eq 0) {
  $p95Regression = if ($green.P95Milliseconds -eq 0) { 0 } else { [double]::PositiveInfinity }
}
else {
  $p95Regression = (($green.P95Milliseconds - $blue.P95Milliseconds) / $blue.P95Milliseconds) * 100
}

$rowCountMismatch = [Math]::Abs($GreenRowCount - $BlueRowCount)
$checksumMatch = $BlueChecksum -ceq $GreenChecksum
$gates = [ordered]@{
  P95RegressionPass = $p95Regression -lt $MaximumP95RegressionPercent
  ErrorRatePass     = $green.ErrorRatePercent -lt $MaximumErrorRatePercent
  RowCountPass      = $rowCountMismatch -eq 0
  ChecksumPass      = $checksumMatch
}
$allGatesPass = ($gates.Values -notcontains $false)

$report = [ordered]@{
  GeneratedAtUtc      = (Get-Date).ToUniversalTime().ToString("o")
  Blue                = $blue
  Green               = $green
  P95RegressionPercent = if ([double]::IsInfinity($p95Regression)) { "Infinity" } else { [Math]::Round($p95Regression, 4) }
  BlueRowCount        = $BlueRowCount
  GreenRowCount       = $GreenRowCount
  RowCountMismatch    = $rowCountMismatch
  BlueChecksum        = $BlueChecksum
  GreenChecksum       = $GreenChecksum
  Gates               = $gates
  AllGatesPass        = $allGatesPass
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$jsonPath = Join-Path $OutputDirectory "performance-comparison.json"
$markdownPath = Join-Path $OutputDirectory "performance-comparison.md"
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding utf8

$markdown = @"
# Aurora PostgreSQL performance comparison

| Metric | Blue ($BlueVersion) | Green ($GreenVersion) | Gate |
|---|---:|---:|---|
| Samples | $($blue.Samples) | $($green.Samples) | - |
| Error rate | $($blue.ErrorRatePercent)% | $($green.ErrorRatePercent)% | Green < $MaximumErrorRatePercent% |
| p50 latency | $($blue.P50Milliseconds) ms | $($green.P50Milliseconds) ms | - |
| p95 latency | $($blue.P95Milliseconds) ms | $($green.P95Milliseconds) ms | Regression < $MaximumP95RegressionPercent% |
| p99 latency | $($blue.P99Milliseconds) ms | $($green.P99Milliseconds) ms | - |
| Row count | $BlueRowCount | $GreenRowCount | Exact match |
| Checksum | $BlueChecksum | $GreenChecksum | Exact match |

- p95 regression: $($report.P95RegressionPercent)%
- row-count mismatch: $rowCountMismatch
- all gates pass: $allGatesPass
"@
$markdown | Set-Content -LiteralPath $markdownPath -Encoding utf8

$report | ConvertTo-Json -Depth 6
if ($EnforceGates -and -not $allGatesPass) {
  throw "One or more performance/data gates failed. See $markdownPath"
}

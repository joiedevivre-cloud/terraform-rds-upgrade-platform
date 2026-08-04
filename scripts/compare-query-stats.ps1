param(
  [Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ })][string]$BlueStatsPath,
  [Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ })][string]$GreenStatsPath,
  [string]$OutputDirectory = "$PSScriptRoot/../docs/evidence/generated",
  [ValidateRange(0, 1000)][double]$WarningMeanRegressionPercent = 15
)
$ErrorActionPreference = "Stop"
function As-Double($value) { if ($null -eq $value -or $value -eq '') { return 0.0 }; return [double]::Parse($value, [Globalization.CultureInfo]::InvariantCulture) }
function Percent-Change([double]$blue, [double]$green) { if ($blue -eq 0) { return $null }; return [Math]::Round((($green - $blue) / $blue) * 100, 2) }
$blueRows = @(Import-Csv -LiteralPath $BlueStatsPath)
$greenRows = @(Import-Csv -LiteralPath $GreenStatsPath)
$blueByFingerprint = @{}; foreach ($row in $blueRows) { $blueByFingerprint[$row.sql_fingerprint_sha256] = $row }
$greenByFingerprint = @{}; foreach ($row in $greenRows) { $greenByFingerprint[$row.sql_fingerprint_sha256] = $row }
$allFingerprints = @($blueByFingerprint.Keys + $greenByFingerprint.Keys | Sort-Object -Unique)
$comparisons = foreach ($fingerprint in $allFingerprints) {
  $blue = $blueByFingerprint[$fingerprint]
  $green = $greenByFingerprint[$fingerprint]
  $meanChange = if ($blue -and $green) { Percent-Change (As-Double $blue.mean_exec_time_ms) (As-Double $green.mean_exec_time_ms) } else { $null }
  $readChange = if ($blue -and $green) { Percent-Change (As-Double $blue.shared_blks_read) (As-Double $green.shared_blks_read) } else { $null }
  [pscustomobject][ordered]@{
    sql_fingerprint_sha256 = $fingerprint; selected_by = if ($green) { $green.selected_by } else { $blue.selected_by }
    blue_queryid = if ($blue) { $blue.queryid } else { $null }; green_queryid = if ($green) { $green.queryid } else { $null }
    blue_calls = if ($blue) { $blue.calls } else { $null }; green_calls = if ($green) { $green.calls } else { $null }
    blue_mean_exec_ms = if ($blue) { $blue.mean_exec_time_ms } else { $null }; green_mean_exec_ms = if ($green) { $green.mean_exec_time_ms } else { $null }
    mean_exec_change_percent = $meanChange; shared_reads_change_percent = $readChange
    status = if (-not $blue) { 'NEW_TOP_SQL_ON_GREEN' } elseif (-not $green) { 'NOT_OBSERVED_ON_GREEN' } elseif ($null -ne $meanChange -and $meanChange -ge $WarningMeanRegressionPercent) { 'REVIEW_REGRESSION' } else { 'PASS' }
    normalized_query = if ($blue) { $blue.normalized_query } else { $green.normalized_query }
  }
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$comparisons | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'query-stats-comparison.csv') -NoTypeInformation -Encoding UTF8
$comparisons | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'query-stats-comparison.json') -Encoding UTF8
$review = @($comparisons | Where-Object { $_.status -ne 'PASS' })
$lines = @('# Impact-ranked SQL metadata comparison', '', '> Matching uses normalized-SQL SHA-256 because PostgreSQL does not guarantee queryid stability across major versions.', '', '| Fingerprint | Blue queryid | Green queryid | Mean change | Reads change | Status |', '|---|---:|---:|---:|---:|---|')
foreach ($item in $comparisons) { $lines += "| $($item.sql_fingerprint_sha256.Substring(0,12)) | $($item.blue_queryid) | $($item.green_queryid) | $($item.mean_exec_change_percent)% | $($item.shared_reads_change_percent)% | $($item.status) |" }
$lines += ''; $lines += "Review candidates: $($review.Count)"; $lines += ''; $lines += 'A warning is triage, not an automatic failure. Review plans, buffers, cache state, calls and business criticality.'
$markdownPath = Join-Path $OutputDirectory 'query-stats-comparison.md'
$lines | Set-Content -LiteralPath $markdownPath -Encoding UTF8
Write-Host "Compared $($comparisons.Count) Blue candidates; $($review.Count) require review."
Write-Host "Report: $([System.IO.Path]::GetFullPath($markdownPath))"

param(
  [string]$Region = "ca-central-1",
  [string]$Profile = "portfolio-bootstrap",
  [Parameter(Mandatory = $true)][string]$BlueGreenDeploymentIdentifier,
  [Parameter(Mandatory = $true)][ValidateRange(-100, 100000)][double]$P95RegressionPercent,
  [Parameter(Mandatory = $true)][ValidateRange(0, 100)][double]$ErrorRatePercent,
  [Parameter(Mandatory = $true)][ValidateRange(0, 9223372036854775807)][long]$ReplicationLsnDistanceBytes,
  [Parameter(Mandatory = $true)][ValidateRange(0, 2147483647)][int]$RowCountMismatch,
  [int]$SwitchoverTimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"

if ($P95RegressionPercent -ge 15) { throw "Gate failed: p95 regression must be below 15%." }
if ($ErrorRatePercent -ge 1) { throw "Gate failed: error rate must be below 1%." }
if ($ReplicationLsnDistanceBytes -ne 0) { throw "Gate failed: logical replication LSN distance must be zero bytes." }
if ($RowCountMismatch -ne 0) { throw "Gate failed: row-count mismatch must be zero." }

$deploymentStatus = aws rds describe-blue-green-deployments `
  --blue-green-deployment-identifier $BlueGreenDeploymentIdentifier `
  --region $Region `
  --profile $Profile `
  --query "BlueGreenDeployments[0].Status" `
  --output text
if ($deploymentStatus.Trim() -ne "AVAILABLE") {
  throw "Blue/Green deployment is not ready; status is $deploymentStatus."
}

Write-Host "All quantitative gates passed. Requesting switchover."
aws rds switchover-blue-green-deployment `
  --blue-green-deployment-identifier $BlueGreenDeploymentIdentifier `
  --switchover-timeout $SwitchoverTimeoutSeconds `
  --region $Region `
  --profile $Profile `
  --output json

if ($LASTEXITCODE -ne 0) {
  throw "AWS rejected the Blue/Green switchover request."
}

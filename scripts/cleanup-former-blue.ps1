param(
  [string]$Region = "ca-central-1",
  [string]$Profile = "portfolio-bootstrap",
  [Parameter(Mandatory = $true)][string]$BlueGreenDeploymentIdentifier,
  [Parameter(Mandatory = $true)][string]$FormerBlueClusterIdentifier,
  [Parameter(Mandatory = $true)][string]$FormerBlueInstanceIdentifier,
  [string]$CurrentProductionClusterIdentifier = "rds-upgrade-portfolio-blue",
  [string]$CurrentProductionInstanceIdentifier = "rds-upgrade-portfolio-blue-writer",
  [Parameter(Mandatory = $true)][ValidateSet("DELETE-FORMER-BLUE")][string]$ConfirmationToken,
  [switch]$Execute
)

$ErrorActionPreference = "Stop"

if ($FormerBlueClusterIdentifier -eq $CurrentProductionClusterIdentifier) {
  throw "Refusing to delete the current production cluster identifier."
}
if ($FormerBlueInstanceIdentifier -eq $CurrentProductionInstanceIdentifier) {
  throw "Refusing to delete the current production instance identifier."
}

$deploymentStatus = aws rds describe-blue-green-deployments `
  --blue-green-deployment-identifier $BlueGreenDeploymentIdentifier `
  --region $Region --profile $Profile `
  --query "BlueGreenDeployments[0].Status" --output text
if ($deploymentStatus.Trim() -ne "SWITCHOVER_COMPLETED") {
  throw "Former Blue deletion requires SWITCHOVER_COMPLETED; current status is $deploymentStatus."
}

$formerCluster = aws rds describe-db-clusters `
  --db-cluster-identifier $FormerBlueClusterIdentifier `
  --region $Region --profile $Profile `
  --query "DBClusters[0].{Id:DBClusterIdentifier,Version:EngineVersion,Status:Status,DeletionProtection:DeletionProtection}" `
  --output json | ConvertFrom-Json
$formerInstance = aws rds describe-db-instances `
  --db-instance-identifier $FormerBlueInstanceIdentifier `
  --region $Region --profile $Profile `
  --query "DBInstances[0].{Id:DBInstanceIdentifier,Cluster:DBClusterIdentifier,Version:EngineVersion,Status:DBInstanceStatus}" `
  --output json | ConvertFrom-Json
if ($formerInstance.Cluster -ne $formerCluster.Id) {
  throw "The supplied former Blue instance does not belong to the supplied cluster."
}

Write-Host "Former Blue deletion candidate: $($formerCluster | ConvertTo-Json -Compress)"
Write-Host "Former Blue instance candidate: $($formerInstance | ConvertTo-Json -Compress)"
if (-not $Execute) {
  Write-Host "Dry run only. Re-run with -Execute after retaining required rollback evidence."
  exit 0
}

if ($formerCluster.DeletionProtection) {
  Write-Host "Disabling deletion protection on former Blue cluster $FormerBlueClusterIdentifier"
  aws rds modify-db-cluster --db-cluster-identifier $FormerBlueClusterIdentifier `
    --no-deletion-protection --apply-immediately `
    --region $Region --profile $Profile | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed to disable deletion protection on the former Blue cluster." }
  aws rds wait db-cluster-available --db-cluster-identifier $FormerBlueClusterIdentifier `
    --region $Region --profile $Profile
  if ($LASTEXITCODE -ne 0) { throw "Timed out waiting for deletion protection to be disabled." }
  $recheck = aws rds describe-db-clusters --db-cluster-identifier $FormerBlueClusterIdentifier `
    --region $Region --profile $Profile `
    --query "DBClusters[0].DeletionProtection" --output text
  if ($recheck.Trim() -ne "False") { throw "Deletion protection is still enabled on $FormerBlueClusterIdentifier; refusing to proceed." }
}

aws rds delete-db-instance --db-instance-identifier $FormerBlueInstanceIdentifier `
  --skip-final-snapshot --region $Region --profile $Profile | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to request former Blue instance deletion." }
aws rds wait db-instance-deleted --db-instance-identifier $FormerBlueInstanceIdentifier `
  --region $Region --profile $Profile
if ($LASTEXITCODE -ne 0) { throw "Timed out deleting former Blue instance." }

aws rds delete-db-cluster --db-cluster-identifier $FormerBlueClusterIdentifier `
  --skip-final-snapshot --region $Region --profile $Profile | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to request former Blue cluster deletion." }
aws rds wait db-cluster-deleted --db-cluster-identifier $FormerBlueClusterIdentifier `
  --region $Region --profile $Profile
if ($LASTEXITCODE -ne 0) { throw "Timed out deleting former Blue cluster." }

aws rds delete-blue-green-deployment `
  --blue-green-deployment-identifier $BlueGreenDeploymentIdentifier `
  --region $Region --profile $Profile | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to delete the Blue/Green deployment record." }

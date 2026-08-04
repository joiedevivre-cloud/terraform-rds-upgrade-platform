param(
  [string]$Region = "ca-central-1",
  [string]$Profile = "portfolio-bootstrap",
  [Parameter(Mandatory = $true)][string]$BlueGreenDeploymentIdentifier,
  [string]$ClusterIdentifier = "rds-upgrade-portfolio-blue",
  [string]$InstanceIdentifier = "rds-upgrade-portfolio-blue-writer",
  [string]$TerraformDirectory = "$PSScriptRoot/../rds-upgrade",
  [switch]$RepairImport
)

$ErrorActionPreference = "Stop"

$deployment = aws rds describe-blue-green-deployments `
  --blue-green-deployment-identifier $BlueGreenDeploymentIdentifier `
  --region $Region `
  --profile $Profile `
  --query "BlueGreenDeployments[0].{Status:Status,Source:Source,Target:Target,Details:SwitchoverDetails}" `
  --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $deployment) { throw "Blue/Green deployment was not found." }
if ($deployment.Status -ne "SWITCHOVER_COMPLETED") {
  throw "State reconciliation is allowed only after SWITCHOVER_COMPLETED; current status is $($deployment.Status)."
}

$clusterVersion = aws rds describe-db-clusters `
  --db-cluster-identifier $ClusterIdentifier --region $Region --profile $Profile `
  --query "DBClusters[0].EngineVersion" --output text
$instanceVersion = aws rds describe-db-instances `
  --db-instance-identifier $InstanceIdentifier --region $Region --profile $Profile `
  --query "DBInstances[0].EngineVersion" --output text
if ($clusterVersion -notlike "16.*" -or $instanceVersion -notlike "16.*") {
  throw "The production identifiers do not resolve to PostgreSQL 16. Cluster=$clusterVersion Instance=$instanceVersion"
}

Push-Location $TerraformDirectory
try {
  $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $stateJson = terraform state pull | Out-String
  if ($LASTEXITCODE -ne 0) { throw "Could not back up remote state." }
  $backupPath = Join-Path (Get-Location) "state-before-reconcile-$timestamp.json"
  $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($backupPath, $stateJson, $utf8WithoutBom)

  $state = terraform state list
  if ($RepairImport) {
    if ($state -contains "aws_rds_cluster.blue[0]") {
      terraform state rm "aws_rds_cluster.blue[0]"
    }
    terraform import "aws_rds_cluster.blue[0]" $ClusterIdentifier
    if ($state -contains "aws_rds_cluster_instance.blue_writer[0]") {
      terraform state rm "aws_rds_cluster_instance.blue_writer[0]"
    }
    terraform import "aws_rds_cluster_instance.blue_writer[0]" $InstanceIdentifier
  }

  Write-Host "Set upgrade_complete=true, then review the normal Terraform plan."
  terraform plan -refresh-only
  if ($LASTEXITCODE -ne 0) { throw "Refresh-only reconciliation plan failed." }
}
finally {
  Pop-Location
}

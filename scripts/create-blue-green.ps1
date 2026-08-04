param(
  [string]$Region = "ca-central-1",
  [string]$Profile = "portfolio-bootstrap",
  [string]$DeploymentName = "aurora-postgresql-15-to-16",
  [Parameter(Mandatory = $true)][string]$SourceClusterArn,
  [string]$TargetVersion = "16.8",
  [string]$TargetClusterParameterGroup = "rds-upgrade-portfolio-aurora-postgresql16-cluster",
  [string]$TargetInstanceParameterGroup = "rds-upgrade-portfolio-aurora-postgresql16-instance",
  [ValidateRange(60, 7200)][int]$WaitTimeoutSeconds = 3600,
  [ValidateRange(5, 300)][int]$PollIntervalSeconds = 30
)

$ErrorActionPreference = "Stop"

$sourceClusterId = ($SourceClusterArn -split ":cluster:")[-1]
$managedSecretArn = aws rds describe-db-clusters `
  --db-cluster-identifier $sourceClusterId `
  --region $Region `
  --profile $Profile `
  --query "DBClusters[0].MasterUserSecret.SecretArn" `
  --output text
if ($LASTEXITCODE -ne 0) { throw "Unable to inspect source-cluster credential mode." }
if ($managedSecretArn -and $managedSecretArn.Trim() -notin @("", "None", "null")) {
  throw "Blue/Green blocked: AWS does not support RDS-managed master passwords. Run convert-master-password.ps1 first."
}

$created = aws rds create-blue-green-deployment `
  --blue-green-deployment-name $DeploymentName `
  --source $SourceClusterArn `
  --target-engine-version $TargetVersion `
  --target-db-cluster-parameter-group-name $TargetClusterParameterGroup `
  --target-db-parameter-group-name $TargetInstanceParameterGroup `
  --region $Region `
  --profile $Profile `
  --query "BlueGreenDeployment.{Identifier:BlueGreenDeploymentIdentifier,Status:Status,Source:Source,Target:Target}" `
  --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $created.Identifier) {
  throw "AWS did not create the Blue/Green deployment."
}

$deadline = (Get-Date).AddSeconds($WaitTimeoutSeconds)
do {
  $deployment = aws rds describe-blue-green-deployments `
    --blue-green-deployment-identifier $created.Identifier `
    --region $Region `
    --profile $Profile `
    --query "BlueGreenDeployments[0].{Identifier:BlueGreenDeploymentIdentifier,Status:Status,StatusDetails:StatusDetails,Source:Source,Target:Target}" `
    --output json | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) { throw "Failed to read Blue/Green deployment status." }

  Write-Host "Blue/Green status: $($deployment.Status)"
  if ($deployment.Status -eq "AVAILABLE") {
    $deployment | ConvertTo-Json -Depth 5
    exit 0
  }
  if ($deployment.Status -in @("INVALID_CONFIGURATION", "SWITCHOVER_FAILED", "DELETING")) {
    throw "Blue/Green creation failed: $($deployment.Status) $($deployment.StatusDetails)"
  }
  if ((Get-Date) -ge $deadline) {
    throw "Timed out after $WaitTimeoutSeconds seconds waiting for AVAILABLE."
  }
  Start-Sleep -Seconds $PollIntervalSeconds
} while ($true)

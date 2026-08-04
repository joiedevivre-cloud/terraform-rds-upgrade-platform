param(
  [string]$Region = "ca-central-1",
  [string]$Profile = "portfolio-bootstrap",
  [string]$SourceVersion = "15.10",
  [string]$TargetVersion = "16.8",
  [string]$ClusterIdentifier = "rds-upgrade-portfolio-blue"
)

$ErrorActionPreference = "Stop"

Write-Host "[1/5] Verifying AWS identity"
aws sts get-caller-identity --profile $Profile | Out-Host

Write-Host "[2/5] Verifying the exact regional upgrade path"
$targets = aws rds describe-db-engine-versions `
  --engine aurora-postgresql `
  --engine-version $SourceVersion `
  --region $Region `
  --profile $Profile `
  --query "DBEngineVersions[0].ValidUpgradeTarget[?EngineVersion=='$TargetVersion' && IsMajorVersionUpgrade==``true``].EngineVersion" `
  --output text
if ($targets.Trim() -ne $TargetVersion) {
  throw "Unsupported Aurora PostgreSQL upgrade path in ${Region}: ${SourceVersion} -> ${TargetVersion}"
}

Write-Host "[3/5] Checking the source cluster, backups, maintenance and pending changes"
$cluster = aws rds describe-db-clusters `
  --db-cluster-identifier $ClusterIdentifier `
  --region $Region `
  --profile $Profile `
  --query "DBClusters[0].{Status:Status,EngineVersion:EngineVersion,BackupRetentionPeriod:BackupRetentionPeriod,StorageEncrypted:StorageEncrypted,DeletionProtection:DeletionProtection,PendingModifiedValues:PendingModifiedValues}" `
  --output json | ConvertFrom-Json
if ($cluster.Status -ne "available") { throw "Cluster must be available; status is $($cluster.Status)." }
if ($cluster.EngineVersion -ne $SourceVersion) { throw "Expected $SourceVersion; found $($cluster.EngineVersion)." }
if ($cluster.BackupRetentionPeriod -lt 1) { throw "Automated backups must be enabled." }
if (-not $cluster.StorageEncrypted) { throw "Storage encryption must be enabled." }

$pending = aws rds describe-pending-maintenance-actions `
  --region $Region `
  --profile $Profile `
  --filters "Name=db-cluster-id,Values=$ClusterIdentifier" `
  --query "PendingMaintenanceActions[].PendingMaintenanceActionDetails" `
  --output json
if (($pending | ConvertFrom-Json).Count -gt 0) { throw "Resolve pending maintenance before Blue/Green creation: $pending" }

Write-Host "[4/5] Confirming a recent automated or manual cluster snapshot"
$snapshot = aws rds describe-db-cluster-snapshots `
  --db-cluster-identifier $ClusterIdentifier `
  --region $Region `
  --profile $Profile `
  --query "reverse(sort_by(DBClusterSnapshots[?Status=='available'],&SnapshotCreateTime))[0].{Id:DBClusterSnapshotIdentifier,Created:SnapshotCreateTime,Status:Status}" `
  --output json | ConvertFrom-Json
if (-not $snapshot.Id) { throw "No available cluster snapshot found." }
if ((New-TimeSpan -Start $snapshot.Created -End (Get-Date)).TotalHours -gt 24) {
  throw "Latest snapshot is older than 24 hours: $($snapshot.Created)"
}

Write-Host "[5/5] AWS precheck passed"
[pscustomobject]@{
  Region        = $Region
  UpgradePath   = "$SourceVersion -> $TargetVersion"
  Cluster       = $ClusterIdentifier
  Snapshot      = $snapshot.Id
  SnapshotTime  = $snapshot.Created
  Result        = "PASS"
} | Format-List

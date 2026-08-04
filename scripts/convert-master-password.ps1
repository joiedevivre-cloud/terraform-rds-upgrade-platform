param(
  [string]$Region = "ca-central-1",
  [string]$Profile = "portfolio-bootstrap",
  [string]$ClusterIdentifier = "rds-upgrade-portfolio-blue",
  [string]$SecretName = "rds-upgrade-portfolio/postgresql/master",
  [string]$MasterUsername = "portfolio_admin",
  [switch]$ResumeExistingSecret,
  [switch]$Execute
)

$ErrorActionPreference = "Stop"

$cluster = aws rds describe-db-clusters `
  --db-cluster-identifier $ClusterIdentifier `
  --region $Region `
  --profile $Profile `
  --query "DBClusters[0].{Status:Status,ManagedSecretArn:MasterUserSecret.SecretArn,ManagedSecretStatus:MasterUserSecret.SecretStatus,Endpoint:Endpoint}" `
  --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $cluster.Endpoint) { throw "Unable to inspect the Aurora cluster." }
if ($cluster.Status -ne "available") { throw "Cluster must be available; current status is $($cluster.Status)." }
if ([string]::IsNullOrWhiteSpace($cluster.ManagedSecretArn)) {
  throw "Cluster already uses a self-managed master password. No conversion was performed."
}

Write-Host "Planned one-time credential transition:"
Write-Host "  Cluster: $ClusterIdentifier"
Write-Host "  Secret:  $SecretName"
Write-Host "  Mode:    RDS-managed -> independently stored Secrets Manager secret"
Write-Host "Terraform will never receive the password value."
if (-not $Execute) {
  Write-Host "Dry run only. Re-run with -Execute after reviewing the recovery procedure."
  exit 0
}

$existingSecret = aws secretsmanager list-secrets `
  --region $Region `
  --profile $Profile `
  --filters "Key=name,Values=$SecretName" `
  --query "SecretList[?Name=='$SecretName'] | [0].ARN" `
  --output text
if ($LASTEXITCODE -ne 0) { throw "Unable to check whether the target secret already exists." }
if ($existingSecret -and $existingSecret.Trim() -notin @("", "None", "null") -and -not $ResumeExistingSecret) {
  throw "Secret $SecretName already exists. Refusing to overwrite it."
}
$resume = $existingSecret -and $existingSecret.Trim() -notin @("", "None", "null")
if ($ResumeExistingSecret -and -not $resume) {
  throw "-ResumeExistingSecret was specified, but $SecretName does not exist."
}

$randomPasswordResponse = aws secretsmanager get-random-password `
  --password-length 40 `
  --exclude-characters '"/@ ' `
  --require-each-included-type `
  --region $Region `
  --profile $Profile `
  --output json | ConvertFrom-Json
$password = [string]$randomPasswordResponse.RandomPassword
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($password) -or $password.Length -ne 40) {
  throw "Secrets Manager did not generate a password."
}

$secretFile = [System.IO.Path]::GetTempFileName()
$modifyFile = [System.IO.Path]::GetTempFileName()
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try {
  $secretValue = @{ username = $MasterUsername; password = $password } | ConvertTo-Json -Compress
  if ($resume) {
    $createSecretInput = @{
      SecretId     = $SecretName
      SecretString = $secretValue
    } | ConvertTo-Json -Depth 5
  }
  else {
    $createSecretInput = @{
      Name         = $SecretName
      Description  = "Self-managed Aurora PostgreSQL master credential required for Blue/Green Deployments"
      SecretString = $secretValue
      Tags         = @(
        @{ Key = "Project"; Value = "aurora-postgresql-upgrade-platform" },
        @{ Key = "ManagedBy"; Value = "credential-transition-script" }
      )
    } | ConvertTo-Json -Depth 5
  }
  [System.IO.File]::WriteAllText($secretFile, $createSecretInput, $utf8NoBom)

  if ($resume) {
    $secretArn = aws secretsmanager put-secret-value `
      --cli-input-json "file://$secretFile" `
      --region $Region `
      --profile $Profile `
      --query "ARN" `
      --output text
  }
  else {
    $secretArn = aws secretsmanager create-secret `
      --cli-input-json "file://$secretFile" `
      --region $Region `
      --profile $Profile `
      --query "ARN" `
      --output text
  }
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($secretArn)) {
    throw "Failed to create or update the independent Secrets Manager secret."
  }

  Write-Warning "The independent secret now contains the proposed password, but it will not match the live database until modify-db-cluster succeeds in this same run. Do not use the secret yet."

  $modifyClusterInput = @{
    DBClusterIdentifier       = $ClusterIdentifier
    ManageMasterUserPassword = $false
    MasterUserPassword       = $password
    ApplyImmediately         = $true
  } | ConvertTo-Json
  [System.IO.File]::WriteAllText($modifyFile, $modifyClusterInput, $utf8NoBom)

  aws rds modify-db-cluster `
    --cli-input-json "file://$modifyFile" `
    --region $Region `
    --profile $Profile `
    --output json | Out-Null
  if ($LASTEXITCODE -ne 0) {
    $secretAction = if ($resume) { "updated" } else { "created" }
    throw "Secret was $secretAction, but RDS rejected the credential transition. It does not match the live database. Retain secret ARN $secretArn and rerun only through the documented recovery path."
  }

  aws rds wait db-cluster-available `
    --db-cluster-identifier $ClusterIdentifier `
    --region $Region `
    --profile $Profile
  if ($LASTEXITCODE -ne 0) { throw "Timed out waiting for the cluster after credential conversion." }

  $managedSecretAfter = aws rds describe-db-clusters `
    --db-cluster-identifier $ClusterIdentifier `
    --region $Region `
    --profile $Profile `
    --query "DBClusters[0].MasterUserSecret.SecretArn" `
    --output text
  if ($LASTEXITCODE -ne 0 -or ($managedSecretAfter -and $managedSecretAfter.Trim() -notin @("", "None", "null"))) {
    throw "Credential transition could not be verified."
  }

  [pscustomobject]@{
    ClusterIdentifier       = $ClusterIdentifier
    SecretArn               = $secretArn
    ManagedByRds            = $false
    ControlPlaneTransition  = "PASS"
    DatabaseLoginValidation = "PENDING - run scripts/run-workload.ps1 from the private SSM runner before Blue/Green creation"
    NextStep                = "Validate a real DB login, then set manage_master_user_password=false and external_master_secret_arn to this ARN."
  } | Format-List
}
finally {
  $password = $null
  if (Test-Path -LiteralPath $secretFile) { Remove-Item -LiteralPath $secretFile -Force }
  if (Test-Path -LiteralPath $modifyFile) { Remove-Item -LiteralPath $modifyFile -Force }
}

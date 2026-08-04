param(
  [string]$Profile = "portfolio-bootstrap",
  [string]$TerraformDirectory = "$PSScriptRoot/../rds-upgrade",
  [Parameter(Mandatory = $true)][ValidateSet("DELETE-ONE-DAY-LAB")][string]$ConfirmationToken,
  [switch]$Execute
)

$ErrorActionPreference = "Stop"
$commonArgs = @(
  "-var=enable_database=true",
  "-var=deletion_protection=false",
  "-var=skip_final_snapshot=true"
)

$env:AWS_PROFILE = $Profile
Push-Location $TerraformDirectory
try {
  terraform plan @commonArgs -out=cleanup-unprotect.tfplan
  if ($LASTEXITCODE -ne 0) { throw "Failed to create deletion-protection plan." }
  if (-not $Execute) {
    Write-Host "Dry run only. Re-run with -Execute to apply unprotection and create the destroy plan."
    exit 0
  }

  terraform apply -auto-approve cleanup-unprotect.tfplan
  if ($LASTEXITCODE -ne 0) { throw "Failed to disable deletion protection." }
  terraform plan -destroy @commonArgs -out=cleanup-destroy.tfplan
  if ($LASTEXITCODE -ne 0) { throw "Failed to create destroy plan." }

  Write-Host "Destroy plan created. Review cleanup-destroy.tfplan before the final command:"
  Write-Host "terraform apply cleanup-destroy.tfplan"
}
finally {
  Pop-Location
}

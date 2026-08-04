output "state_bucket_name" {
  description = "S3 bucket used for Terraform remote state and native lockfiles."
  value       = aws_s3_bucket.terraform_state.bucket
}

output "rds_backend_example" {
  description = "Backend settings to copy into the RDS upgrade stack."
  value = {
    bucket       = aws_s3_bucket.terraform_state.bucket
    key          = "rds-upgrade/prod.tfstate"
    region       = var.aws_region
    encrypt      = true
    use_lockfile = true
  }
}


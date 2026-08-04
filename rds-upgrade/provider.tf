provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      ManagedBy   = "Terraform"
      Project     = "aurora-postgresql-upgrade-platform"
      Environment = var.environment
    }
  }
}

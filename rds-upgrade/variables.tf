variable "aws_region" {
  description = "AWS Region for the Aurora upgrade lab."
  type        = string
  default     = "ca-central-1"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "portfolio"
}

variable "name_prefix" {
  description = "Prefix used for resource names. Kept stable to preserve existing network state."
  type        = string
  default     = "rds-upgrade-portfolio"
}

variable "enable_database" {
  description = "Creates the billable Aurora cluster and writer when true."
  type        = bool
  default     = false
}

variable "baseline_engine_version" {
  description = "Exact Aurora PostgreSQL 15 version. Verify the regional upgrade path before apply."
  type        = string
  default     = "15.10"
}

variable "target_engine_version" {
  description = "Exact Aurora PostgreSQL 16 target used by the Blue/Green workflow."
  type        = string
  default     = "16.8"
}

variable "upgrade_complete" {
  description = "Set true only after a successful Blue/Green switchover so Terraform adopts the PostgreSQL 16 production configuration."
  type        = bool
  default     = false
}

variable "manage_master_user_password" {
  description = "Use only for initial baseline creation. Must be false before Aurora Blue/Green creation; transition with scripts/convert-master-password.ps1."
  type        = bool
  default     = false
}

variable "external_master_secret_arn" {
  description = "ARN of the independently managed Secrets Manager secret after converting the master password. Terraform never reads its SecretString."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.external_master_secret_arn == null || can(regex("^arn:aws:secretsmanager:", var.external_master_secret_arn))
    error_message = "external_master_secret_arn must be a Secrets Manager ARN or null."
  }
}

variable "instance_class" {
  description = "Lowest-cost instance class shared by the selected Aurora versions."
  type        = string
  default     = "db.t4g.medium"
}

variable "backup_retention_days" {
  description = "Automated-backup retention required for Blue/Green."
  type        = number
  default     = 1

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 1 and 35."
  }
}

variable "deletion_protection" {
  description = "Prevents accidental cluster deletion; false is appropriate only for the one-day disposable lab."
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Skips the final snapshot during approved lab cleanup."
  type        = bool
  default     = false
}

variable "allowed_client_cidrs" {
  description = "Client CIDRs allowed to reach PostgreSQL; empty means deny by default."
  type        = list(string)
  default     = []
}

variable "log_min_duration_statement_ms" {
  description = "Logs PostgreSQL statements whose execution time reaches this threshold; avoids logging every statement and its literals."
  type        = number
  default     = 1000

  validation {
    condition     = var.log_min_duration_statement_ms >= 0
    error_message = "log_min_duration_statement_ms must be zero or greater."
  }
}

variable "enable_workload_runner" {
  description = "Creates the private SSM-managed workload runner (EC2, VPC endpoints, IAM role) when true."
  type        = bool
  default     = false
}

variable "workload_runner_instance_type" {
  description = "Lowest-cost Graviton instance type for the temporary workload runner."
  type        = string
  default     = "t4g.micro"
}

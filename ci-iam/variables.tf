variable "aws_region" {
  type    = string
  default = "ca-central-1"
}

variable "github_repository" {
  description = "GitHub owner/repository, for example joiedevivre-cloud/terraform-rds-upgrade-platform."
  type        = string
}

variable "github_oidc_subject_repository" {
  description = "Repository portion used in the OIDC sub claim. Set owner@OWNER_ID/repository@REPOSITORY_ID when GitHub subject customization includes stable IDs; otherwise leave empty."
  type        = string
  default     = ""
}

variable "github_oidc_provider_arn" {
  description = "Existing GitHub OIDC provider ARN. Leave empty only when create_github_oidc_provider is true."
  type        = string
  default     = ""
}

variable "create_github_oidc_provider" {
  description = "Creates token.actions.githubusercontent.com when the account does not already have it."
  type        = bool
  default     = false
}

variable "state_bucket_name" {
  description = "Bootstrap-created Terraform state bucket."
  type        = string
}

variable "state_key" {
  type    = string
  default = "rds-upgrade/prod.tfstate"
}

variable "state_admin_principal_arns" {
  description = "Exact IAM role/user ARNs allowed to assume TerraformStateAdminRole."
  type        = list(string)

  validation {
    condition     = length(var.state_admin_principal_arns) > 0 && alltrue([for arn in var.state_admin_principal_arns : startswith(arn, "arn:aws:iam::")])
    error_message = "Provide at least one explicit IAM role or user ARN for state administration."
  }
}

variable "developer_user_names" {
  description = "Human IAM users that receive the explicit production RDS mutation deny policy."
  type        = set(string)
  default     = []
}

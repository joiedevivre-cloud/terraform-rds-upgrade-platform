variable "aws_region" {
  description = "AWS Region that stores the Terraform remote state."
  type        = string
  default     = "ca-central-1"
}

variable "bucket_name_prefix" {
  description = "Globally unique state-bucket prefix; the AWS account ID and Region are appended."
  type        = string
  default     = "portfolio-terraform-state"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,35}[a-z0-9]$", var.bucket_name_prefix))
    error_message = "Use 3-37 lowercase letters, digits, or hyphens, starting and ending with a letter or digit."
  }
}

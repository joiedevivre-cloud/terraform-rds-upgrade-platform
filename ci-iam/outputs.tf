output "terraform_plan_role_arn" {
  value = aws_iam_role.terraform_plan.arn
}

output "terraform_apply_role_arn" {
  value = aws_iam_role.terraform_apply.arn
}

output "terraform_state_admin_role_arn" {
  value = aws_iam_role.terraform_state_admin.arn
}

output "developer_production_deny_policy_arn" {
  value = aws_iam_policy.deny_direct_production_changes.arn
}

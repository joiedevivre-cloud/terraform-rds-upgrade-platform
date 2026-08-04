output "blue_cluster_identifier" {
  value = try(aws_rds_cluster.blue[0].cluster_identifier, null)
}

output "blue_writer_endpoint" {
  value = try(aws_rds_cluster.blue[0].endpoint, null)
}

output "master_user_secret_arn" {
  description = "RDS-managed secret during baseline creation, or the independent secret ARN after conversion."
  value = var.manage_master_user_password ? (
    try(aws_rds_cluster.blue[0].master_user_secret[0].secret_arn, null)
  ) : var.external_master_secret_arn
  sensitive = true
}

output "workload_runner_instance_id" {
  description = "Start a session with: aws ssm start-session --target <this-id>"
  value       = try(aws_instance.workload_runner[0].id, null)
}

output "blue_green_inputs" {
  description = "Inputs consumed by the gated Blue/Green workflow."
  value = {
    source_cluster_arn              = try(aws_rds_cluster.blue[0].arn, null)
    target_engine_version           = var.target_engine_version
    target_cluster_parameter_group  = aws_rds_cluster_parameter_group.postgres16.name
    target_instance_parameter_group = aws_db_parameter_group.postgres16.name
  }
}

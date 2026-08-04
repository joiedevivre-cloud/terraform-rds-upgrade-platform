locals {
  common_tags = {
    Environment = var.environment
    Project     = "aurora-postgresql-upgrade-platform"
    ManagedBy   = "Terraform"
  }
  production_engine_version = var.upgrade_complete ? var.target_engine_version : var.baseline_engine_version
  production_cluster_parameter_group = var.upgrade_complete ? (
    aws_rds_cluster_parameter_group.postgres16.name
  ) : aws_rds_cluster_parameter_group.postgres15.name
  production_instance_parameter_group = var.upgrade_complete ? (
    aws_db_parameter_group.postgres16.name
  ) : aws_db_parameter_group.postgres15.name
}

resource "aws_rds_cluster_parameter_group" "postgres15" {
  name        = "${var.name_prefix}-aurora-postgresql15-cluster"
  family      = "aurora-postgresql15"
  description = "Aurora PostgreSQL 15 baseline cluster parameters"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  tags = local.common_tags
}

resource "aws_rds_cluster_parameter_group" "postgres16" {
  name        = "${var.name_prefix}-aurora-postgresql16-cluster"
  family      = "aurora-postgresql16"
  description = "Aurora PostgreSQL 16 green cluster parameters"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  tags = local.common_tags
}

resource "aws_db_parameter_group" "postgres15" {
  name        = "${var.name_prefix}-aurora-postgresql15-instance"
  family      = "aurora-postgresql15"
  description = "Aurora PostgreSQL 15 baseline instance parameters"
  tags        = local.common_tags
}

resource "aws_db_parameter_group" "postgres16" {
  name        = "${var.name_prefix}-aurora-postgresql16-instance"
  family      = "aurora-postgresql16"
  description = "Aurora PostgreSQL 16 green instance parameters"
  tags        = local.common_tags
}

resource "aws_rds_cluster" "blue" {
  count = var.enable_database ? 1 : 0

  cluster_identifier = "${var.name_prefix}-blue"
  engine             = "aurora-postgresql"
  engine_version     = local.production_engine_version
  engine_mode        = "provisioned"
  database_name      = "upgrade_lab"
  master_username    = "portfolio_admin"

  # Aurora Blue/Green does not support an RDS-managed master password. The
  # baseline may start managed, then scripts/convert-master-password.ps1 performs
  # the one-time transition without putting plaintext in Terraform configuration.
  manage_master_user_password     = var.manage_master_user_password
  storage_encrypted               = true
  db_subnet_group_name            = aws_db_subnet_group.database.name
  vpc_security_group_ids          = [aws_security_group.database.id]
  db_cluster_parameter_group_name = local.production_cluster_parameter_group
  backup_retention_period         = var.backup_retention_days
  preferred_backup_window         = "05:00-05:30"
  preferred_maintenance_window    = "sun:06:00-sun:07:00"
  copy_tags_to_snapshot           = true
  deletion_protection             = var.deletion_protection
  skip_final_snapshot             = var.skip_final_snapshot
  final_snapshot_identifier       = var.skip_final_snapshot ? null : "${var.name_prefix}-blue-final"
  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = merge(local.common_tags, {
    Name         = "${var.name_prefix}-blue"
    UpgradePhase = var.upgrade_complete ? "production-postgresql-16" : "baseline-postgresql-15"
  })

  lifecycle {
    precondition {
      condition     = var.backup_retention_days > 0
      error_message = "Aurora Blue/Green requires automated backups to be enabled."
    }
    precondition {
      condition     = var.manage_master_user_password || var.external_master_secret_arn != null
      error_message = "When RDS password management is disabled, provide the ARN created by convert-master-password.ps1."
    }
  }
}

resource "aws_rds_cluster_instance" "blue_writer" {
  count = var.enable_database ? 1 : 0

  identifier                   = "${var.name_prefix}-blue-writer"
  cluster_identifier           = aws_rds_cluster.blue[0].id
  instance_class               = var.instance_class
  engine                       = aws_rds_cluster.blue[0].engine
  engine_version               = aws_rds_cluster.blue[0].engine_version
  db_parameter_group_name      = local.production_instance_parameter_group
  publicly_accessible          = false
  auto_minor_version_upgrade   = false
  performance_insights_enabled = var.performance_insights_enabled
  monitoring_interval          = 0

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-blue-writer"
  })
}

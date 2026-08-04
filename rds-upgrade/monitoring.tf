resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  count = var.enable_database ? 1 : 0

  alarm_name          = "${var.name_prefix}-high-cpu"
  alarm_description   = "Aurora writer CPU exceeded 80 percent for ten minutes"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    DBInstanceIdentifier = aws_rds_cluster_instance.blue_writer[0].identifier
  }
}

resource "aws_cloudwatch_metric_alarm" "oldest_replication_slot_lag" {
  count = var.enable_database ? 1 : 0

  alarm_name          = "${var.name_prefix}-oldest-replication-slot-lag"
  alarm_description   = "Aurora PostgreSQL logical replication slot retained more than 16 MiB"
  namespace           = "AWS/RDS"
  metric_name         = "OldestReplicationSlotLag"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 16777216
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.blue[0].cluster_identifier
  }
}

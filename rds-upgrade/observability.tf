data "aws_iam_policy_document" "vpc_flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/${var.name_prefix}/flow-logs"
  retention_in_days = 30

  tags = local.common_tags
}

resource "aws_iam_role" "vpc_flow_logs" {
  name               = "${var.name_prefix}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.vpc_flow_logs_assume.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "vpc_flow_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  name   = "write-vpc-flow-logs"
  role   = aws_iam_role.vpc_flow_logs.id
  policy = data.aws_iam_policy_document.vpc_flow_logs.json
}

resource "aws_flow_log" "database" {
  vpc_id                   = aws_vpc.database.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.vpc_flow_logs.arn
  iam_role_arn             = aws_iam_role.vpc_flow_logs.arn
  max_aggregation_interval = 60

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-vpc-flow-logs"
  })
}

data "aws_iam_policy_document" "rds_enhanced_monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_enhanced_monitoring" {
  name               = "${var.name_prefix}-enhanced-monitoring"
  assume_role_policy = data.aws_iam_policy_document.rds_enhanced_monitoring_assume.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

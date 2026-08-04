data "aws_ami" "workload_runner" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-kernel-*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_prefix_list" "s3" {
  name = "com.amazonaws.${var.aws_region}.s3"
}

# No NAT/IGW exists in this VPC (see network.tf). SSM and Secrets Manager reach the
# runner only through these interface endpoints; Amazon Linux package repos reach it
# through the free S3 gateway endpoint. This keeps the "no internet gateway" network
# story intact instead of reopening the VPC to the internet for one temporary box.

resource "aws_security_group" "vpc_endpoints" {
  count = var.enable_workload_runner ? 1 : 0

  name_prefix = "${var.name_prefix}-endpoints-"
  description = "Allows the workload runner to reach the SSM and Secrets Manager interface endpoints"
  vpc_id      = aws_vpc.database.id

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${var.name_prefix}-endpoints" }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_runner" {
  count = var.enable_workload_runner ? 1 : 0

  security_group_id            = aws_security_group.vpc_endpoints[0].id
  description                  = "HTTPS from the workload runner"
  referenced_security_group_id = aws_security_group.workload_runner[0].id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "endpoints_to_vpc" {
  count = var.enable_workload_runner ? 1 : 0

  security_group_id = aws_security_group.vpc_endpoints[0].id
  description       = "Responses back into the VPC"
  cidr_ipv4         = aws_vpc.database.cidr_block
  ip_protocol       = "-1"
}

resource "aws_vpc_endpoint" "ssm" {
  count = var.enable_workload_runner ? 1 : 0

  vpc_id              = aws_vpc.database.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.database_a.id]
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-ssm" }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  count = var.enable_workload_runner ? 1 : 0

  vpc_id              = aws_vpc.database.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.database_a.id]
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-ssmmessages" }
}

resource "aws_vpc_endpoint" "ec2messages" {
  count = var.enable_workload_runner ? 1 : 0

  vpc_id              = aws_vpc.database.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.database_a.id]
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-ec2messages" }
}

resource "aws_vpc_endpoint" "secretsmanager" {
  count = var.enable_workload_runner ? 1 : 0

  vpc_id              = aws_vpc.database.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.database_a.id]
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-secretsmanager" }
}

resource "aws_vpc_endpoint" "s3" {
  count = var.enable_workload_runner ? 1 : 0

  vpc_id            = aws_vpc.database.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_vpc.database.default_route_table_id]

  tags = { Name = "${var.name_prefix}-s3" }
}

# --- Runner instance: SSM-only management, no key pair, no public IP.

resource "aws_security_group" "workload_runner" {
  count = var.enable_workload_runner ? 1 : 0

  name_prefix = "${var.name_prefix}-runner-"
  description = "Private SSM-managed workload runner; no inbound access required"
  vpc_id      = aws_vpc.database.id

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${var.name_prefix}-runner" }
}

resource "aws_vpc_security_group_egress_rule" "runner_to_vpc" {
  count = var.enable_workload_runner ? 1 : 0

  security_group_id = aws_security_group.workload_runner[0].id
  description       = "SSM/Secrets Manager endpoints and Aurora, all inside the VPC"
  cidr_ipv4         = aws_vpc.database.cidr_block
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "runner_to_s3_prefix_list" {
  count = var.enable_workload_runner ? 1 : 0

  security_group_id = aws_security_group.workload_runner[0].id
  description       = "Amazon Linux package repos via the S3 gateway endpoint"
  prefix_list_id    = data.aws_prefix_list.s3.id
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "runner_postgres_client" {
  count = var.enable_workload_runner ? 1 : 0

  security_group_id            = aws_security_group.database.id
  description                  = "Workload runner reaches Aurora for precheck and workload replay"
  referenced_security_group_id = aws_security_group.workload_runner[0].id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_instance" "workload_runner" {
  count = var.enable_workload_runner ? 1 : 0

  ami                         = data.aws_ami.workload_runner.id
  instance_type               = var.workload_runner_instance_type
  subnet_id                   = aws_subnet.database_a.id
  vpc_security_group_ids      = [aws_security_group.workload_runner[0].id]
  iam_instance_profile        = "${var.name_prefix}-workload-runner"
  associate_public_ip_address = false

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  # Best-effort convenience install over the S3 gateway endpoint; the operator can
  # also run this by hand in the SSM session if a package version needs adjusting.
  user_data = <<-EOF
    #!/bin/bash
    dnf install -y postgresql16 aws-cli
  EOF

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-workload-runner"
  })
}

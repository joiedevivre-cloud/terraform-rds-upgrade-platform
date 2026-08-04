resource "aws_vpc" "database" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# Explicitly manage the VPC default security group so no resource can inherit
# permissive default ingress or egress rules by accident.
resource "aws_default_security_group" "database" {
  vpc_id = aws_vpc.database.id

  ingress = []
  egress  = []

  tags = {
    Name = "${var.name_prefix}-default-deny-all"
  }
}

resource "aws_subnet" "database_a" {
  vpc_id                  = aws_vpc.database.id
  cidr_block              = "10.20.10.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-db-a"
    Tier = "database"
  }
}

resource "aws_subnet" "database_b" {
  vpc_id                  = aws_vpc.database.id
  cidr_block              = "10.20.20.0/24"
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-db-b"
    Tier = "database"
  }
}

resource "aws_db_subnet_group" "database" {
  name       = "${var.name_prefix}-subnets"
  subnet_ids = [aws_subnet.database_a.id, aws_subnet.database_b.id]

  tags = {
    Name = "${var.name_prefix}-subnets"
  }
}

resource "aws_security_group" "database" {
  name_prefix = "${var.name_prefix}-postgres-"
  description = "Deny-by-default ingress for the Aurora PostgreSQL upgrade portfolio"
  vpc_id      = aws_vpc.database.id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.name_prefix}-postgres"
  }
}

resource "aws_vpc_security_group_ingress_rule" "approved_postgres_clients" {
  for_each = toset(var.allowed_client_cidrs)

  security_group_id = aws_security_group.database.id
  description       = "Approved PostgreSQL client CIDR"
  cidr_ipv4         = each.value
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
}

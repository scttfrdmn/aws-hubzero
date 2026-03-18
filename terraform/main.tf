terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "hubzero-terraform-state"
    key            = "hubzero/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "hubzero-terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "hubzero"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

locals {
  env_config = {
    test    = { instance_type = "t3.xlarge", volume_size = 100 }
    staging = { instance_type = "m6i.2xlarge", volume_size = 500 }
    prod    = { instance_type = "m6i.4xlarge", volume_size = 1000 }
  }
  rds_config = {
    test    = { instance_class = "db.t3.medium", storage = 20, multi_az = false }
    staging = { instance_class = "db.r6g.xlarge", storage = 100, multi_az = false }
    prod    = { instance_class = "db.r6g.2xlarge", storage = 500, multi_az = true }
  }
  config  = local.env_config[var.environment]
  rds     = local.rds_config[var.environment]
  db_host = var.use_rds ? aws_db_instance.hubzero[0].address : "localhost"
}

# --- AMI ---
data "aws_ami" "rocky8" {
  most_recent = true
  owners      = ["792107900819"]
  filter {
    name   = "name"
    values = ["Rocky-8-EC2-Base-8.*-x86_64-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --- Networking (existing VPC) ---
data "aws_vpc" "selected" {
  id = var.vpc_id
}

data "aws_subnet" "selected" {
  id = var.subnet_id
}

resource "aws_security_group" "hubzero" {
  name_prefix = "hubzero-${var.environment}-"
  description = "HubZero ${var.environment} instance"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }
  egress {
    description = "HTTPS outbound"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "HTTP outbound"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "DNS UDP outbound"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "DNS TCP outbound"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "MySQL to RDS"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
  }
}

# --- IAM ---
resource "aws_iam_role" "hubzero" {
  name_prefix = "hubzero-${var.environment}-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.hubzero.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ssm_messages" {
  name = "hubzero-ssm-messages"
  role = aws_iam_role.hubzero.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "secrets_read" {
  count = var.use_rds ? 1 : 0
  name  = "hubzero-secrets-read"
  role  = aws_iam_role.hubzero.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_db_instance.hubzero[0].master_user_secret[0].secret_arn]
    }]
  })
}

resource "aws_iam_instance_profile" "hubzero" {
  name_prefix = "hubzero-${var.environment}-"
  role        = aws_iam_role.hubzero.name
}

# --- RDS (optional) ---
resource "aws_security_group" "rds" {
  count       = var.use_rds ? 1 : 0
  name_prefix = "hubzero-rds-${var.environment}-"
  description = "HubZero RDS ${var.environment}"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description     = "MariaDB from EC2"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.hubzero.id]
  }
  egress {
    description = "No egress required"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = []
  }
}

resource "aws_db_subnet_group" "hubzero" {
  count       = var.use_rds ? 1 : 0
  name_prefix = "hubzero-${var.environment}-"
  subnet_ids  = var.rds_subnet_ids
}

resource "aws_db_instance" "hubzero" {
  count                       = var.use_rds ? 1 : 0
  identifier_prefix           = "hubzero-${var.environment}-"
  engine                      = "mariadb"
  engine_version              = "10.11"
  instance_class              = local.rds.instance_class
  allocated_storage           = local.rds.storage
  storage_type                = "gp3"
  storage_encrypted           = true
  multi_az                    = local.rds.multi_az
  publicly_accessible         = false
  db_name                     = "hubzero"
  username                    = "hubzero"
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.hubzero[0].name
  vpc_security_group_ids      = [aws_security_group.rds[0].id]
  skip_final_snapshot         = var.environment != "prod"
  final_snapshot_identifier   = var.environment == "prod" ? "hubzero-${var.environment}-final" : null
  deletion_protection         = var.environment == "prod"
  backup_retention_period     = var.environment == "prod" ? 14 : 7

  tags = { Name = "hubzero-${var.environment}" }
}

# --- EC2 ---
resource "aws_instance" "hubzero" {
  ami                         = data.aws_ami.rocky8.id
  instance_type               = local.config.instance_type
  subnet_id                   = data.aws_subnet.selected.id
  vpc_security_group_ids      = [aws_security_group.hubzero.id]
  iam_instance_profile        = aws_iam_instance_profile.hubzero.name
  key_name                    = var.key_name != "" ? var.key_name : null
  associate_public_ip_address = var.environment == "test"
  disable_api_termination     = var.environment == "prod"

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = local.config.volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = base64encode(join("\n", [
    "#!/usr/bin/env bash",
    "export HUBZERO_DOMAIN='${var.domain_name}'",
    "export HUBZERO_INSTALL_PLATFORM='${tostring(var.install_platform)}'",
    "export HUBZERO_USE_RDS='${tostring(var.use_rds)}'",
    "export HUBZERO_DB_HOST='${local.db_host}'",
    "export HUBZERO_DB_NAME='hubzero'",
    "export HUBZERO_DB_USER='hubzero'",
    "export HUBZERO_DB_SECRET_ARN='${var.use_rds ? aws_db_instance.hubzero[0].master_user_secret[0].secret_arn : ""}'",
    "export HUBZERO_CERTBOT_EMAIL='${var.certbot_email}'",
    file("${path.module}/../scripts/userdata.sh"),
  ]))

  tags = { Name = "hubzero-${var.environment}" }

  lifecycle {
    precondition {
      condition     = var.allowed_cidr != "0.0.0.0/0" || var.environment == "test"
      error_message = "allowed_cidr=0.0.0.0/0 is not permitted for staging/prod. Restrict to your IP."
    }
    precondition {
      condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/3[0-2]$", var.allowed_cidr)) || var.environment == "test"
      error_message = "For staging/prod, allowed_cidr must be a /30 or narrower CIDR (e.g. x.x.x.x/32)."
    }
  }
}

# --- EBS Snapshot Lifecycle ---
resource "aws_iam_role" "dlm" {
  name_prefix = "hubzero-dlm-${var.environment}-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "hubzero" {
  description        = "HubZero ${var.environment} daily EBS snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  lifecycle {
    prevent_destroy = true
  }

  policy_details {
    resource_types = ["INSTANCE"]

    schedule {
      name = "daily-snapshot"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }

      retain_rule {
        count = var.environment == "prod" ? 30 : 7
      }

      tags_to_add = {
        SnapshotCreator = "DLM"
        Environment     = var.environment
      }
    }

    target_tags = {
      Name = "hubzero-${var.environment}"
    }
  }
}

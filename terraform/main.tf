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
  monitoring_config = {
    test    = { log_retention = 7, cpu_threshold = 80, alarm_period = 300, eval_periods = 2 }
    staging = { log_retention = 14, cpu_threshold = 75, alarm_period = 300, eval_periods = 2 }
    prod    = { log_retention = 30, cpu_threshold = 70, alarm_period = 60, eval_periods = 3 }
  }
  config  = local.env_config[var.environment]
  rds     = local.rds_config[var.environment]
  mon     = local.monitoring_config[var.environment]
  db_host = var.use_rds ? aws_db_instance.hubzero[0].address : "localhost"
}

# --- AMI ---
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["137112412989"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
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

resource "aws_iam_role_policy" "cloudwatch" {
  name = "hubzero-cloudwatch"
  role = aws_iam_role.hubzero.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cloudwatch:PutMetricData",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
        "logs:DescribeLogGroups"
      ]
      Resource = "*"
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
  ami                         = data.aws_ami.al2023.id
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
    "export HUBZERO_ENABLE_MONITORING='${tostring(var.enable_monitoring)}'",
    "export HUBZERO_CW_LOG_GROUP_PREFIX='/aws/ec2/hubzero-${var.environment}'",
    "export HUBZERO_S3_BUCKET='${var.enable_s3_storage ? aws_s3_bucket.hubzero[0].id : ""}'",
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
    precondition {
      condition     = var.use_rds || var.environment == "test"
      error_message = "use_rds=false is not recommended for staging/prod. Set use_rds=true or acknowledge with environment=test."
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

# --- CloudWatch Monitoring (conditional) ---
resource "aws_cloudwatch_log_group" "userdata" {
  count             = var.enable_monitoring ? 1 : 0
  name              = "/aws/ec2/hubzero-${var.environment}/userdata"
  retention_in_days = local.mon.log_retention
}

resource "aws_cloudwatch_log_group" "apache_access" {
  count             = var.enable_monitoring ? 1 : 0
  name              = "/aws/ec2/hubzero-${var.environment}/apache-access"
  retention_in_days = local.mon.log_retention
}

resource "aws_cloudwatch_log_group" "apache_error" {
  count             = var.enable_monitoring ? 1 : 0
  name              = "/aws/ec2/hubzero-${var.environment}/apache-error"
  retention_in_days = local.mon.log_retention
}

resource "aws_sns_topic" "hubzero" {
  count = var.enable_monitoring ? 1 : 0
  name  = "hubzero-${var.environment}-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.enable_monitoring && var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.hubzero[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "ec2_cpu" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "hubzero-${var.environment}-ec2-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = local.mon.eval_periods
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = local.mon.alarm_period
  statistic           = "Average"
  threshold           = local.mon.cpu_threshold
  alarm_description   = "EC2 CPU utilization above ${local.mon.cpu_threshold}%"
  dimensions          = { InstanceId = aws_instance.hubzero.id }
  alarm_actions       = [aws_sns_topic.hubzero[0].arn]
  ok_actions          = [aws_sns_topic.hubzero[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "ec2_status" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "hubzero-${var.environment}-ec2-status"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "EC2 status check failed"
  dimensions          = { InstanceId = aws_instance.hubzero.id }
  alarm_actions       = [aws_sns_topic.hubzero[0].arn]
  ok_actions          = [aws_sns_topic.hubzero[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "ec2_memory" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "hubzero-${var.environment}-ec2-memory"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = local.mon.eval_periods
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = local.mon.alarm_period
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "EC2 memory usage above 80%"
  dimensions          = { InstanceId = aws_instance.hubzero.id }
  alarm_actions       = [aws_sns_topic.hubzero[0].arn]
  ok_actions          = [aws_sns_topic.hubzero[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "ec2_disk" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "hubzero-${var.environment}-ec2-disk"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = local.mon.eval_periods
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = local.mon.alarm_period
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "EC2 disk usage above 85%"
  dimensions = {
    InstanceId = aws_instance.hubzero.id
    path       = "/"
  }
  alarm_actions = [aws_sns_topic.hubzero[0].arn]
  ok_actions    = [aws_sns_topic.hubzero[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  count               = var.enable_monitoring && var.use_rds ? 1 : 0
  alarm_name          = "hubzero-${var.environment}-rds-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = local.mon.eval_periods
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = local.mon.alarm_period
  statistic           = "Average"
  threshold           = local.mon.cpu_threshold
  alarm_description   = "RDS CPU utilization above ${local.mon.cpu_threshold}%"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.hubzero[0].identifier }
  alarm_actions       = [aws_sns_topic.hubzero[0].arn]
  ok_actions          = [aws_sns_topic.hubzero[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  count               = var.enable_monitoring && var.use_rds ? 1 : 0
  alarm_name          = "hubzero-${var.environment}-rds-connections"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = local.mon.eval_periods
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = local.mon.alarm_period
  statistic           = "Average"
  threshold           = 100
  alarm_description   = "RDS connection count above 100"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.hubzero[0].identifier }
  alarm_actions       = [aws_sns_topic.hubzero[0].arn]
  ok_actions          = [aws_sns_topic.hubzero[0].arn]
}

# --- S3 File Storage (optional) ---
resource "aws_s3_bucket" "hubzero" {
  count         = var.enable_s3_storage ? 1 : 0
  bucket_prefix = "hubzero-${var.environment}-"
}

resource "aws_s3_bucket_versioning" "hubzero" {
  count  = var.enable_s3_storage ? 1 : 0
  bucket = aws_s3_bucket.hubzero[0].id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "hubzero" {
  count  = var.enable_s3_storage ? 1 : 0
  bucket = aws_s3_bucket.hubzero[0].id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "aws:kms" }
  }
}

resource "aws_s3_bucket_public_access_block" "hubzero" {
  count                   = var.enable_s3_storage ? 1 : 0
  bucket                  = aws_s3_bucket.hubzero[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "hubzero" {
  count  = var.enable_s3_storage ? 1 : 0
  bucket = aws_s3_bucket.hubzero[0].id
  rule {
    id     = "transition-to-ia"
    status = "Enabled"
    filter {}
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
  }
}

resource "aws_iam_role_policy" "s3" {
  count = var.enable_s3_storage ? 1 : 0
  name  = "hubzero-s3"
  role  = aws_iam_role.hubzero.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.hubzero[0].arn,
        "${aws_s3_bucket.hubzero[0].arn}/*"
      ]
    }]
  })
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  count               = var.enable_monitoring && var.use_rds ? 1 : 0
  alarm_name          = "hubzero-${var.environment}-rds-storage"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = local.mon.eval_periods
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = local.mon.alarm_period
  statistic           = "Average"
  threshold           = 5368709120
  alarm_description   = "RDS free storage below 5 GB"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.hubzero[0].identifier }
  alarm_actions       = [aws_sns_topic.hubzero[0].arn]
  ok_actions          = [aws_sns_topic.hubzero[0].arn]
}

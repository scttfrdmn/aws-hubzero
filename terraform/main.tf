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
  # Deployment profile → compute defaults.
  # instance_type var overrides the profile default when set.
  profile_config = {
    minimal  = { instance_type = "t3.medium",  cpu_arch = "x86_64", use_spot = false }
    graviton = { instance_type = "t4g.medium", cpu_arch = "arm64",  use_spot = false }
    spot     = { instance_type = "t3.medium",  cpu_arch = "x86_64", use_spot = true }
  }
  cpu_arch          = local.profile_config[var.deployment_profile].cpu_arch
  use_spot          = local.profile_config[var.deployment_profile].use_spot
  ec2_instance_type = var.instance_type != "" ? var.instance_type : local.profile_config[var.deployment_profile].instance_type

  env_config = {
    test    = { volume_size = 30 }
    staging = { volume_size = 100 }
    prod    = { volume_size = 200 }
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
    values = ["al2023-ami-2023.*-${local.cpu_arch}"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "architecture"
    values = [local.cpu_arch]
  }
}

# Baked HubZero AMI (built by Packer); falls back to AL2023 when not found.
# Packer bakes per-arch AMIs — filter by architecture to avoid cross-arch mismatch.
data "aws_ami" "hubzero_baked" {
  count       = var.use_baked_ami ? 1 : 0
  most_recent = true
  owners      = ["self"]
  filter {
    name   = "name"
    values = ["hubzero-base-*"]
  }
  filter {
    name   = "architecture"
    values = [local.cpu_arch]
  }
}

locals {
  selected_ami = (
    var.use_baked_ami && length(data.aws_ami.hubzero_baked) > 0
    ? data.aws_ami.hubzero_baked[0].id
    : data.aws_ami.al2023.id
  )
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

  # Direct HTTP/HTTPS ingress only when ALB is not in front
  dynamic "ingress" {
    for_each = var.enable_alb ? [] : [80, 443]
    content {
      description = ingress.value == 80 ? "HTTP" : "HTTPS"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = [var.allowed_cidr]
    }
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

# --- EC2: Launch Template + Auto Scaling Group (min=1) ---
locals {
  userdata_script = base64encode(join("\n", [
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
    "export HUBZERO_ENABLE_ALB='${tostring(var.enable_alb)}'",
    "export HUBZERO_ENVIRONMENT='${var.environment}'",
    "export HUBZERO_ENABLE_PARAMETER_STORE='${tostring(var.enable_parameter_store)}'",
    "export HUBZERO_EFS_ID='${var.enable_efs ? aws_efs_file_system.hubzero[0].id : ""}'",
    "export HUBZERO_EFS_ACCESS_POINT_ID='${var.enable_efs ? aws_efs_access_point.hubzero[0].id : ""}'",
    var.use_baked_ami ? "" : file("${path.module}/../scripts/bake.sh"),
    file("${path.module}/../scripts/userdata.sh"),
  ]))
}

resource "aws_launch_template" "hubzero" {
  name_prefix   = "hubzero-${var.environment}-"
  image_id      = local.selected_ami
  instance_type = local.ec2_instance_type
  key_name      = var.key_name != "" ? var.key_name : null

  iam_instance_profile { name = aws_iam_instance_profile.hubzero.name }

  vpc_security_group_ids = [aws_security_group.hubzero.id]

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = local.config.volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = local.userdata_script

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name          = "hubzero-${var.environment}"
      "Patch Group" = "hubzero-${var.environment}"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = { Name = "hubzero-${var.environment}" }
  }

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

resource "aws_autoscaling_group" "hubzero" {
  name_prefix         = "hubzero-${var.environment}-"
  vpc_zone_identifier = [data.aws_subnet.selected.id]
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  health_check_type   = var.enable_alb ? "ELB" : "EC2"

  # mixed_instances_policy handles both on-demand (minimal/graviton) and spot profiles.
  # For on-demand: on_demand_percentage=100. For spot: on_demand_percentage=0.
  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = local.use_spot ? 0 : 1
      on_demand_percentage_above_base_capacity = local.use_spot ? 0 : 100
      spot_allocation_strategy                 = "capacity-optimized"
    }
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.hubzero.id
        version            = "$Latest"
      }
    }
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
    }
  }

  tag {
    key                 = "Name"
    value               = "hubzero-${var.environment}"
    propagate_at_launch = true
  }
  tag {
    key                 = "Project"
    value               = "hubzero"
    propagate_at_launch = true
  }
  tag {
    key                 = "Patch Group"
    value               = "hubzero-${var.environment}"
    propagate_at_launch = true
  }

  lifecycle {
    precondition {
      condition     = !local.use_spot || (var.use_rds && var.enable_efs)
      error_message = "deployment_profile=\"spot\" requires use_rds=true and enable_efs=true to prevent data loss on spot interruption."
    }
    ignore_changes = [desired_capacity]
  }
}

# Attach ASG to ALB target group (replaces direct instance attachment)
resource "aws_autoscaling_attachment" "hubzero" {
  count                  = var.enable_alb ? 1 : 0
  autoscaling_group_name = aws_autoscaling_group.hubzero.id
  lb_target_group_arn    = aws_lb_target_group.hubzero[0].arn
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
  # ASG: EC2 namespace supports AutoScalingGroupName dimension
  dimensions    = { AutoScalingGroupName = aws_autoscaling_group.hubzero.name }
  alarm_actions = [aws_sns_topic.hubzero[0].arn]
  ok_actions    = [aws_sns_topic.hubzero[0].arn]
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
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.hubzero.name }
  alarm_actions       = [aws_sns_topic.hubzero[0].arn]
  ok_actions          = [aws_sns_topic.hubzero[0].arn]
}

# NOTE: CWAgent publishes mem/disk metrics with InstanceId dimension. After moving
# to ASG, these alarms require per-instance configuration (e.g. via EventBridge →
# Lambda creating alarms on instance launch). For v0.6.0 the alarms are created
# without an InstanceId filter; they will not fire automatically but document intent.
# See CHANGELOG for details.
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
  alarm_description   = "EC2 memory usage above 80% (requires per-instance alarm update post ASG launch)"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.hubzero.name }
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
  alarm_description   = "EC2 disk usage above 85% (requires per-instance alarm update post ASG launch)"
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.hubzero.name
    path                 = "/"
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

# --- ALB + ACM (optional) ---
resource "aws_security_group" "alb" {
  count       = var.enable_alb ? 1 : 0
  name_prefix = "hubzero-alb-${var.environment}-"
  description = "HubZero ALB ${var.environment}"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description = "HTTP from allowed CIDR"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }
  ingress {
    description = "HTTPS from allowed CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }
  egress {
    description     = "To EC2 HTTP"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.hubzero.id]
  }
}

# Allow ALB SG to reach EC2 on port 80
resource "aws_security_group_rule" "ec2_from_alb" {
  count                    = var.enable_alb ? 1 : 0
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb[0].id
  security_group_id        = aws_security_group.hubzero.id
  description              = "HTTP from ALB"
}

resource "aws_acm_certificate" "hubzero" {
  count             = var.enable_alb && var.acm_certificate_arn == "" && var.domain_name != "" ? 1 : 0
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  acm_cert_arn = var.acm_certificate_arn != "" ? var.acm_certificate_arn : (
    length(aws_acm_certificate.hubzero) > 0 ? aws_acm_certificate.hubzero[0].arn : ""
  )
}

resource "aws_lb" "hubzero" {
  count              = var.enable_alb ? 1 : 0
  name_prefix        = "hz-${substr(var.environment, 0, 3)}-"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb[0].id]
  subnets            = [data.aws_subnet.selected.id]
}

resource "aws_lb_target_group" "hubzero" {
  count       = var.enable_alb ? 1 : 0
  name_prefix = "hz-${substr(var.environment, 0, 3)}-"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.selected.id

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
}

resource "aws_lb_listener" "http" {
  count             = var.enable_alb ? 1 : 0
  load_balancer_arn = aws_lb.hubzero[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = var.enable_alb && local.acm_cert_arn != "" ? 1 : 0
  load_balancer_arn = aws_lb.hubzero[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.acm_cert_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.hubzero[0].arn
  }
}

# --- WAF v2 (optional, requires ALB) ---
resource "aws_wafv2_web_acl" "hubzero" {
  count = var.enable_waf && var.enable_alb ? 1 : 0
  name  = "hubzero-${var.environment}"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "KnownBadInputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 3
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesSQLiRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "SQLiRuleSet"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "hubzero-${var.environment}"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "hubzero" {
  count        = var.enable_waf && var.enable_alb ? 1 : 0
  resource_arn = aws_lb.hubzero[0].arn
  web_acl_arn  = aws_wafv2_web_acl.hubzero[0].arn
}

resource "aws_cloudwatch_metric_alarm" "waf_blocked" {
  count               = var.enable_waf && var.enable_alb && var.enable_monitoring ? 1 : 0
  alarm_name          = "hubzero-${var.environment}-waf-blocked"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "BlockedRequests"
  namespace           = "AWS/WAFV2"
  period              = 300
  statistic           = "Sum"
  threshold           = 100
  alarm_description   = "WAF blocked requests spike (informational — check for false positives)"
  dimensions = {
    WebACL = "hubzero-${var.environment}"
    Region = var.aws_region
    Rule   = "ALL"
  }
  alarm_actions = [aws_sns_topic.hubzero[0].arn]
}

# --- VPC Endpoints (optional) ---
resource "aws_security_group" "vpc_endpoints" {
  count       = var.enable_vpc_endpoints ? 1 : 0
  name_prefix = "hubzero-vpce-${var.environment}-"
  description = "HubZero VPC endpoint interfaces ${var.environment}"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description     = "HTTPS from EC2"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.hubzero.id]
  }
}

resource "aws_vpc_endpoint" "s3" {
  count             = var.enable_vpc_endpoints ? 1 : 0
  vpc_id            = data.aws_vpc.selected.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
}

resource "aws_vpc_endpoint" "ssm" {
  count               = var.enable_vpc_endpoints ? 1 : 0
  vpc_id              = data.aws_vpc.selected.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [data.aws_subnet.selected.id]
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ssmmessages" {
  count               = var.enable_vpc_endpoints ? 1 : 0
  vpc_id              = data.aws_vpc.selected.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [data.aws_subnet.selected.id]
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ec2messages" {
  count               = var.enable_vpc_endpoints ? 1 : 0
  vpc_id              = data.aws_vpc.selected.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [data.aws_subnet.selected.id]
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "secretsmanager" {
  count               = var.enable_vpc_endpoints ? 1 : 0
  vpc_id              = data.aws_vpc.selected.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [data.aws_subnet.selected.id]
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "logs" {
  count               = var.enable_vpc_endpoints ? 1 : 0
  vpc_id              = data.aws_vpc.selected.id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [data.aws_subnet.selected.id]
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true
}

# --- SSM Patch Manager (optional) ---
resource "aws_ssm_patch_baseline" "hubzero" {
  count            = var.enable_patch_manager ? 1 : 0
  name             = "hubzero-${var.environment}"
  operating_system = "AMAZON_LINUX_2023"
  description      = "HubZero ${var.environment} security patch baseline"

  approval_rule {
    approve_after_days = 7
    patch_filter {
      key    = "CLASSIFICATION"
      values = ["Security"]
    }
    patch_filter {
      key    = "SEVERITY"
      values = ["Critical", "Important"]
    }
  }
}

resource "aws_ssm_patch_group" "hubzero" {
  count       = var.enable_patch_manager ? 1 : 0
  baseline_id = aws_ssm_patch_baseline.hubzero[0].id
  patch_group = "hubzero-${var.environment}"
}

resource "aws_ssm_maintenance_window" "hubzero" {
  count    = var.enable_patch_manager ? 1 : 0
  name     = "hubzero-${var.environment}-patches"
  schedule = "cron(0 3 ? * SUN *)"
  duration = 2
  cutoff   = 1
}

resource "aws_ssm_maintenance_window_target" "hubzero" {
  count         = var.enable_patch_manager ? 1 : 0
  window_id     = aws_ssm_maintenance_window.hubzero[0].id
  name          = "hubzero-${var.environment}-instances"
  resource_type = "INSTANCE"

  targets {
    key    = "tag:Project"
    values = ["hubzero"]
  }
}

resource "aws_ssm_maintenance_window_task" "patch" {
  count            = var.enable_patch_manager ? 1 : 0
  window_id        = aws_ssm_maintenance_window.hubzero[0].id
  task_type        = "RUN_COMMAND"
  task_arn         = "AWS-RunPatchBaseline"
  priority         = 1
  service_role_arn = aws_iam_role.hubzero.arn

  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window_target.hubzero[0].id]
  }

  task_invocation_parameters {
    run_command_parameters {
      parameter {
        name   = "Operation"
        values = ["Install"]
      }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "ssm_compliance" {
  count               = var.enable_patch_manager && var.enable_monitoring ? 1 : 0
  alarm_name          = "hubzero-${var.environment}-ssm-compliance"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "NonCompliantCount"
  namespace           = "AWS/SSM"
  period              = 86400
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "SSM Patch Manager found non-compliant instances"
  dimensions = {
    PatchGroup = "hubzero-${var.environment}"
  }
  alarm_actions = [aws_sns_topic.hubzero[0].arn]
}

# --- SSM Parameter Store (optional) ---
resource "aws_ssm_parameter" "domain_name" {
  count = var.enable_parameter_store ? 1 : 0
  name  = "/hubzero/${var.environment}/domain_name"
  type  = "String"
  value = var.domain_name != "" ? var.domain_name : "unset"
}

resource "aws_ssm_parameter" "db_host" {
  count = var.enable_parameter_store ? 1 : 0
  name  = "/hubzero/${var.environment}/db_host"
  type  = "String"
  value = local.db_host
}

resource "aws_ssm_parameter" "db_name" {
  count = var.enable_parameter_store ? 1 : 0
  name  = "/hubzero/${var.environment}/db_name"
  type  = "String"
  value = "hubzero"
}

resource "aws_ssm_parameter" "db_user" {
  count = var.enable_parameter_store ? 1 : 0
  name  = "/hubzero/${var.environment}/db_user"
  type  = "String"
  value = "hubzero"
}

resource "aws_ssm_parameter" "s3_bucket" {
  count = var.enable_parameter_store && var.enable_s3_storage ? 1 : 0
  name  = "/hubzero/${var.environment}/s3_bucket"
  type  = "String"
  value = aws_s3_bucket.hubzero[0].id
}

resource "aws_ssm_parameter" "enable_monitoring" {
  count = var.enable_parameter_store ? 1 : 0
  name  = "/hubzero/${var.environment}/enable_monitoring"
  type  = "String"
  value = tostring(var.enable_monitoring)
}

resource "aws_ssm_parameter" "cw_log_prefix" {
  count = var.enable_parameter_store ? 1 : 0
  name  = "/hubzero/${var.environment}/cw_log_prefix"
  type  = "String"
  value = "/aws/ec2/hubzero-${var.environment}"
}

resource "aws_iam_role_policy" "parameter_store" {
  count = var.enable_parameter_store ? 1 : 0
  name  = "hubzero-parameter-store"
  role  = aws_iam_role.hubzero.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParametersByPath", "ssm:GetParameter"]
      Resource = "arn:aws:ssm:*:*:parameter/hubzero/${var.environment}/*"
    }]
  })
}

# --- EFS Shared Web Root (optional) ---
resource "aws_efs_file_system" "hubzero" {
  count            = var.enable_efs ? 1 : 0
  encrypted        = true
  performance_mode = "generalPurpose"

  tags = { Name = "hubzero-${var.environment}" }
}

resource "aws_security_group" "efs" {
  count       = var.enable_efs ? 1 : 0
  name_prefix = "hubzero-efs-${var.environment}-"
  description = "HubZero EFS ${var.environment}"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description     = "NFS from EC2"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.hubzero.id]
  }
}

locals {
  efs_subnet_ids = length(var.efs_subnet_ids) > 0 ? var.efs_subnet_ids : [var.subnet_id]
}

resource "aws_efs_mount_target" "hubzero" {
  count           = var.enable_efs ? length(local.efs_subnet_ids) : 0
  file_system_id  = aws_efs_file_system.hubzero[0].id
  subnet_id       = local.efs_subnet_ids[count.index]
  security_groups = [aws_security_group.efs[0].id]
}

resource "aws_efs_access_point" "hubzero" {
  count          = var.enable_efs ? 1 : 0
  file_system_id = aws_efs_file_system.hubzero[0].id

  posix_user {
    uid = 48
    gid = 48
  }

  root_directory {
    path = "/hubzero"
    creation_info {
      owner_uid   = 48
      owner_gid   = 48
      permissions = "755"
    }
  }
}

resource "aws_iam_role_policy" "efs" {
  count = var.enable_efs ? 1 : 0
  name  = "hubzero-efs"
  role  = aws_iam_role.hubzero.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "elasticfilesystem:ClientMount",
        "elasticfilesystem:ClientWrite",
        "elasticfilesystem:ClientRootAccess"
      ]
      Resource = aws_efs_file_system.hubzero[0].arn
    }]
  })
}

# --- CloudFront CDN (optional, requires ALB) ---
resource "aws_cloudfront_distribution" "hubzero" {
  count   = var.enable_cdn && var.enable_alb ? 1 : 0
  enabled = true
  comment = "HubZero ${var.environment} CDN"

  origin {
    domain_name = aws_lb.hubzero[0].dns_name
    origin_id   = "alb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Static assets: long TTL (CachingOptimized managed policy)
  dynamic "ordered_cache_behavior" {
    for_each = ["/media/*", "/assets/*", "/css/*", "/js/*"]
    content {
      path_pattern           = ordered_cache_behavior.value
      allowed_methods        = ["GET", "HEAD", "OPTIONS"]
      cached_methods         = ["GET", "HEAD"]
      target_origin_id       = "alb"
      compress               = true
      viewer_protocol_policy = "redirect-to-https"
      cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    }
  }

  # Dynamic content: pass-through (CachingDisabled managed policy)
  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb"
    compress               = true
    viewer_protocol_policy = "redirect-to-https"
    cache_policy_id        = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
  }

  price_class = "PriceClass_100"

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  # NOTE: To attach a WAF to CloudFront, the WAF ACL must be CLOUDFRONT-scoped
  # and provisioned in us-east-1 (regardless of the stack region). This requires
  # a separate provider alias. Enable enable_cloudfront_waf=true and configure a
  # us-east-1 provider alias to use this feature — see CHANGELOG for details.
}

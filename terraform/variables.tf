variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Deployment environment (test, staging, or prod)"
  validation {
    condition     = contains(["test", "staging", "prod"], var.environment)
    error_message = "Environment must be test, staging, or prod."
  }
}

variable "vpc_id" {
  type        = string
  description = "ID of the existing VPC"
}

variable "subnet_id" {
  type        = string
  description = "ID of a public subnet in the VPC"
}

variable "key_name" {
  type        = string
  default     = ""
  description = "EC2 key pair name for SSH access (optional — SSM Session Manager is the recommended access method)"
}

variable "allowed_cidr" {
  type        = string
  description = "CIDR for inbound HTTP/HTTPS — do NOT use 0.0.0.0/0 in staging/prod"
  validation {
    condition     = can(cidrhost(var.allowed_cidr, 0))
    error_message = "allowed_cidr must be a valid CIDR block (e.g. 203.0.113.5/32)."
  }
}

variable "domain_name" {
  type    = string
  default = ""
}

variable "certbot_email" {
  type        = string
  default     = ""
  description = "Email for Let's Encrypt certificate expiry notifications (recommended for staging/prod)"
}

variable "install_platform" {
  type    = bool
  default = false
}

variable "use_rds" {
  type    = bool
  default = true
}

variable "enable_s3_storage" {
  type        = bool
  default     = true
  description = "Provision an S3 bucket for HubZero file storage with versioning and lifecycle management"
}

variable "rds_subnet_ids" {
  type        = list(string)
  default     = []
  description = "Subnet IDs for the RDS subnet group (required when use_rds=true, needs at least 2 AZs)"
  validation {
    condition     = length(var.rds_subnet_ids) == 0 || length(var.rds_subnet_ids) >= 2
    error_message = "rds_subnet_ids must contain at least 2 subnets in different AZs when provided."
  }
}

variable "enable_monitoring" {
  type        = bool
  default     = true
  description = "Enable CloudWatch monitoring, log shipping, and alarms"
}

variable "alarm_email" {
  type        = string
  default     = ""
  description = "Email for CloudWatch alarm SNS notifications (empty = topic created, no subscription)"
}

variable "enable_alb" {
  type        = bool
  default     = true
  description = "Provision an Application Load Balancer with HTTPS termination"
}

variable "acm_certificate_arn" {
  type        = string
  default     = ""
  description = "Existing ACM certificate ARN for the ALB HTTPS listener. If empty and domain_name is set, a new certificate with DNS validation is created."
}

variable "enable_waf" {
  type        = bool
  default     = true
  description = "Attach AWS WAF v2 (regional) to the ALB. Requires enable_alb=true."
}

variable "enable_vpc_endpoints" {
  type        = bool
  default     = true
  description = "Create VPC endpoints for S3 (gateway) and SSM/Secrets Manager/CloudWatch (interface) services"
}

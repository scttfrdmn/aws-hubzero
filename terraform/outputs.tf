output "asg_name" {
  description = "Auto Scaling Group name (use to find the running instance)"
  value       = aws_autoscaling_group.hubzero.name
}

output "public_dns" {
  description = "ALB DNS name or empty when ALB is disabled"
  value       = var.enable_alb ? aws_lb.hubzero[0].dns_name : ""
}

output "web_url" {
  description = "Web URL for the HubZero instance"
  value = (
    var.enable_cdn && var.enable_alb ? "https://${aws_cloudfront_distribution.hubzero[0].domain_name}" :
    var.enable_alb && var.domain_name != "" ? "https://${var.domain_name}" :
    var.enable_alb ? "https://${aws_lb.hubzero[0].dns_name}" :
    var.domain_name != "" ? "https://${var.domain_name}" :
    "(no public IP — use SSM to connect)"
  )
}

output "cloudfront_domain" {
  description = "CloudFront distribution domain name (empty if CDN is disabled)"
  value       = var.enable_cdn && var.enable_alb ? aws_cloudfront_distribution.hubzero[0].domain_name : ""
}

output "efs_id" {
  description = "EFS file system ID (empty if EFS is disabled)"
  value       = var.enable_efs ? aws_efs_file_system.hubzero[0].id : ""
}

output "alb_dns_name" {
  description = "ALB DNS name (empty if ALB is disabled)"
  value       = var.enable_alb ? aws_lb.hubzero[0].dns_name : ""
}

output "acm_certificate_validation_cname" {
  description = "ACM DNS validation CNAME record details (add to your DNS provider)"
  value = (
    var.enable_alb && var.acm_certificate_arn == "" && var.domain_name != ""
    ? tomap({
      for dvo in aws_acm_certificate.hubzero[0].domain_validation_options :
      dvo.domain_name => {
        name  = dvo.resource_record_name
        type  = dvo.resource_record_type
        value = dvo.resource_record_value
      }
    })
    : {}
  )
}

output "rds_endpoint" {
  description = "RDS endpoint (if enabled)"
  value       = var.use_rds ? aws_db_instance.hubzero[0].endpoint : "N/A (local MariaDB)"
}

output "db_secret_arn" {
  description = "RDS-managed Secrets Manager ARN for DB credentials"
  value       = var.use_rds ? aws_db_instance.hubzero[0].master_user_secret[0].secret_arn : "N/A (local MariaDB)"
  sensitive   = true
}

output "ssm_connect_command" {
  description = "Command to find the running instance and connect via SSM Session Manager"
  value       = "aws ec2 describe-instances --filters 'Name=tag:aws:autoscaling:groupName,Values=${aws_autoscaling_group.hubzero.name}' 'Name=instance-state-name,Values=running' --query 'Reservations[0].Instances[0].InstanceId' --output text | xargs -I{} aws ssm start-session --target {}"
}

output "sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarms (empty if monitoring disabled)"
  value       = var.enable_monitoring ? aws_sns_topic.hubzero[0].arn : ""
}

output "s3_bucket_name" {
  description = "S3 bucket name for HubZero file storage (empty if disabled)"
  value       = var.enable_s3_storage ? aws_s3_bucket.hubzero[0].id : ""
}

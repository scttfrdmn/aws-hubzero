output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.hubzero.id
}

output "public_ip" {
  description = "Public IP (test environment only)"
  value       = aws_instance.hubzero.public_ip
}

output "public_dns" {
  description = "Public DNS hostname"
  value       = aws_instance.hubzero.public_dns
}

output "web_url" {
  description = "Web URL for the HubZero instance"
  value = (
    var.enable_alb && var.domain_name != "" ? "https://${var.domain_name}" :
    var.enable_alb ? "https://${aws_lb.hubzero[0].dns_name}" :
    var.domain_name != "" ? "https://${var.domain_name}" :
    "http://${aws_instance.hubzero.public_ip}"
  )
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
  description = "Command to connect via SSM Session Manager"
  value       = "aws ssm start-session --target ${aws_instance.hubzero.id}"
}

output "sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarms (empty if monitoring disabled)"
  value       = var.enable_monitoring ? aws_sns_topic.hubzero[0].arn : ""
}

output "s3_bucket_name" {
  description = "S3 bucket name for HubZero file storage (empty if disabled)"
  value       = var.enable_s3_storage ? aws_s3_bucket.hubzero[0].id : ""
}

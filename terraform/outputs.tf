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
  value       = var.domain_name != "" ? "https://${var.domain_name}" : "http://${aws_instance.hubzero.public_ip}"
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

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-03-18

### Added
- **Issue #12**: Application Load Balancer + ACM TLS via `enable_alb` variable (default: `true`)
  - EC2 security group: HTTP/HTTPS ingress from `allowed_cidr` is removed when ALB is enabled; ALB SG → EC2 ingress rule added via `aws_security_group_rule`
  - `aws_security_group.alb`, `aws_lb`, `aws_lb_target_group`, `aws_lb_target_group_attachment`
  - `aws_lb_listener.http` (HTTP→HTTPS 301 redirect), `aws_lb_listener.https` (TLS forward)
  - `aws_acm_certificate` with DNS validation (created when `acm_certificate_arn` is empty and `domain_name` is set)
  - `web_url` output updated: uses ALB DNS name or custom domain when ALB is enabled
  - New outputs: `alb_dns_name`, `acm_certificate_validation_cname`
  - `scripts/userdata.sh`: certbot section guarded by `HUBZERO_ENABLE_ALB != true`
  - CDK: `ApplicationLoadBalancer`, `ApplicationTargetGroup`, `ListenerAction.redirect`, `acm.Certificate`, `SslPolicy.RECOMMENDED_TLS`
- **Issue #13**: AWS WAF v2 (regional) via `enable_waf` variable (default: `true`, requires `enable_alb`)
  - `aws_wafv2_web_acl` with three managed rule groups in Block mode: CommonRuleSet, KnownBadInputsRuleSet, SQLiRuleSet
  - `aws_wafv2_web_acl_association` attaches WAF to ALB
  - CloudWatch alarm: `BlockedRequests` spike > 100 (informational)
  - CDK: `CfnWebACL` + `CfnWebACLAssociation` constructs
- **Issue #14**: VPC endpoints via `enable_vpc_endpoints` variable (default: `true`)
  - Gateway endpoint: S3 (free)
  - Interface endpoints: SSM, SSMMessages, EC2Messages, SecretsManager, CloudWatch Logs
  - Dedicated VPC endpoint security group allowing HTTPS from EC2 SG
  - CDK: `GatewayVpcEndpoint` for S3, `InterfaceVpcEndpoint` for remaining services

## [0.3.0] - 2026-03-18

### Added
- **Issue #9**: Migrated from Rocky Linux 8 to Amazon Linux 2023 (AL2023)
  - Replaced Rocky 8 AMI data source with AL2023 (`owners = ["137112412989"]`, name filter `al2023-ami-2023.*-x86_64`)
  - CDK: replaced `MachineImage.lookup` with `MachineImage.latestAmazonLinux2023`
  - `scripts/userdata.sh`: removed EPEL install; switched to MariaDB community repo (`mariadb_repo_setup`) with capital-M packages (`MariaDB-server`, `MariaDB-client`); switched to versioned PHP packages (`php8.2`, `php8.2-fpm`, etc.); replaced S3 RPM CloudWatch Agent install with `dnf install -y amazon-cloudwatch-agent`
- **Issue #10**: S3-backed file storage via `enable_s3_storage` variable (default: `true`)
  - Terraform: `aws_s3_bucket` with versioning, KMS SSE, public access block, 90-day STANDARD_IA lifecycle; `aws_iam_role_policy` granting `s3:GetObject/PutObject/DeleteObject/ListBucket` to EC2 role
  - CDK: `s3.Bucket` construct with equivalent properties; `grantReadWrite` to instance role
  - `userdata.sh`: exports `HUBZERO_S3_BUCKET`; note in credentials file for filesystem adapter config
  - Terraform: `s3_bucket_name` output
- **Issue #11**: RDS is now the recommended default
  - `use_rds` default changed from `false` to `true`
  - `aws_instance` lifecycle precondition: `use_rds=false` raises an error for staging/prod (use `environment=test` to bypass)
  - `staging.tfvars` and `prod.tfvars`: added `use_rds = true` with commented example `rds_subnet_ids`
  - CDK `cdk.context.example.json`: `useRds` default changed to `"true"`; added `enableS3Storage: "true"`
  - README: architecture section updated to reflect AL2023 and RDS-as-default

## [0.2.0] - 2026-03-18

### Added
- CloudWatch monitoring and alerting gated by `enable_monitoring` flag (default: true)
- **Terraform**: `enable_monitoring` and `alarm_email` variables; `monitoring_config`
  locals with per-environment log retention, CPU thresholds, alarm periods, and
  evaluation periods
- **Terraform**: IAM policy `cloudwatch` granting `PutMetricData` and log management
  actions to the EC2 instance role (unconditional, required for CWAgent to start)
- **Terraform**: Three CloudWatch log groups per environment (`/userdata`,
  `/apache-access`, `/apache-error`) with environment-specific retention
- **Terraform**: SNS topic `hubzero-{env}-alarms` with optional email subscription
- **Terraform**: Four EC2 CloudWatch alarms: CPU, StatusCheckFailed, mem_used_percent,
  disk_used_percent; three RDS alarms (CPU, DatabaseConnections, FreeStorageSpace),
  all conditional on `enable_monitoring` (RDS alarms also require `use_rds=true`)
- **Terraform**: `sns_topic_arn` output
- **CDK**: Equivalent monitoring block with `MONITORING_CONFIG` constant,
  `enableMonitoring`/`alarmEmail` context reads, log groups, SNS topic, all 7 alarms,
  and `SnsTopicArn` CfnOutput
- **`scripts/userdata.sh`**: Section 9 — CloudWatch Agent install via S3 RPM,
  JSON config (mem + disk metrics, 3 log file tails), agent start; wrapped in
  `HUBZERO_ENABLE_MONITORING` guard
- `cdk/cdk.context.example.json`: `enableMonitoring` and `alarmEmail` keys

## [0.1.0] - 2026-03-18

### Added
- Terraform implementation: EC2, optional RDS MariaDB 10.11, EBS DLM snapshots,
  IAM roles, Secrets Manager integration, SSM Session Manager access
- AWS CDK (TypeScript) implementation with feature parity to Terraform
- Three environments (test / staging / prod) with environment-specific instance
  types, storage, RDS sizing, backup retention, and deletion protection
- EC2 bootstrap script (`scripts/userdata.sh`) for Rocky Linux 8: Apache 2.4 +
  PHP-FPM 8.2, HubZero CMS v2.4 via Composer, optional MariaDB 10.11, optional
  Docker + Apache Solr 9.7
- On-premises migration script (`scripts/migrate.sh`) with SSH-based data
  transfer, database export/import, and Solr index rebuild
- On-premises migration guide (`docs/migration-guide.md`)
- Terraform state backend bootstrap script (`scripts/bootstrap-terraform-backend.sh`)
- GitHub Actions CI: Terraform fmt/validate, CDK TypeScript build and lint
- Apache 2.0 LICENSE
- Security hardening: IMDSv2 enforcement, fail2ban, HSTS + security headers,
  PHP hardening, Docker user namespace remapping, Composer integrity checks,
  encrypted EBS and RDS at rest, Secrets Manager for RDS credentials

[Unreleased]: https://github.com/scttfrdmn/aws-hubzero/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/scttfrdmn/aws-hubzero/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/scttfrdmn/aws-hubzero/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/scttfrdmn/aws-hubzero/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/scttfrdmn/aws-hubzero/releases/tag/v0.1.0

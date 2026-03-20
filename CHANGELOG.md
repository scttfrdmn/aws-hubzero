# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.3] - 2026-03-19

### Fixed
- `docs/migration-guide.md`: replaced reference to non-existent `migrate.sh` script with explicit manual migration steps (mysqldump pipeline, rsync, config update)
- `docs/migration-guide.md`: corrected on-prem `app/` path — HubZero 2.4 uses `/var/www/hubzero/app/`, not `/var/www/html/app/`; note added for older installs
- `docs/migration-guide.md`: pre-migration checklist no longer assumes `enable_alb=true` for the health check step
- `terraform/environments/test.tfvars`, `staging.tfvars`, `prod.tfvars`: added commented `aws_region` hint — variable must be set if deploying outside `us-east-1` and must match at both `apply` and `destroy` time
- `README.md`: destroy example no longer hardcodes `us-west-2`; added note explaining the `aws_region` requirement
- `docs/getting-started-aws.md`: removed stale "I destroyed the stack" advice about S3 bucket manual emptying (now handled by `force_destroy = true`) and CloudWatch log groups; replaced with note about EBS snapshots and the state backend teardown script

## [0.7.2] - 2026-03-20

### Fixed
- `terraform/main.tf`: added `force_destroy = true` to `aws_s3_bucket` — versioned buckets previously required manual emptying before `terraform destroy` could succeed
- `terraform/main.tf`: removed `lifecycle { prevent_destroy = true }` from `aws_dlm_lifecycle_policy` — it blocked `terraform destroy` entirely
- `terraform/main.tf`: added explicit `skip_destroy = false` to all three `aws_cloudwatch_log_group` resources for unambiguous destroy behaviour
- `README.md`: added **Destroying the Stack** section documenting the required `aws_region` variable, the `terraform destroy` command, and manual cleanup steps for EBS snapshots created by the DLM policy

## [0.7.1] - 2026-03-20

### Fixed
- `scripts/bake.sh`: `dnf install curl` now uses `--allowerasing` to replace AL2023's pre-installed `curl-minimal` (conflicting package)
- `scripts/bake.sh`: removed `mod_headers` from dnf install — it is built into `httpd` on AL2023 and has no separate package
- `scripts/bake.sh`: replaced MariaDB community repo install with native AL2023 `mariadb105` package (community repo `MariaDB-client` package name not valid on AL2023)
- `scripts/bake.sh`: removed `php8.2-curl` and `php8.2-json` from dnf install — both are bundled in `php8.2-common` on AL2023 and have no separate packages
- `scripts/bake.sh`: export `HOME` and `COMPOSER_HOME` before Composer installer runs — cloud-init executes with a minimal environment that may not have `HOME` set
- `scripts/bake.sh`: corrected HubZero CMS git branch from `2.4` to `2.4-main`
- `scripts/bake.sh`: corrected Apache `DocumentRoot` from `/var/www/hubzero/public` to `/var/www/hubzero` (HubZero 2.4 serves from the repo root)
- `scripts/bake.sh`: run `composer install` in `core/` subdirectory (that is where `composer.json` lives in HubZero 2.4, not the repo root)
- `scripts/bake.sh`: create `.htaccess` with `mod_rewrite` rules after clone — HubZero does not commit one to the repo, but it is required for framework URL routing
- `scripts/bake.sh`: create `app/`, `app/config/`, `app/logs/`, `app/tmp/` directories owned by `apache` — required by the web installer before it can write config files
- `scripts/userdata.sh`: replaced MariaDB community `MariaDB-server` with native AL2023 `mariadb105-server`
- `scripts/userdata.sh`: `touch` log file before `chmod` and change `exec` redirect to `tee -a` — fixes race condition where `chmod` ran before `tee` had created the file in piped-bash execution (cloud-init `curl | bash` context)
- `docs/getting-started-aws.md`, `README.md`: added deployment monitoring section with commands to track bootstrap progress (`terraform apply` completes in 2–3 min; full bootstrap takes 10–15 min)

## [0.7.0] - 2026-03-18

### Added
- **Deployment profiles** — new `deployment_profile` variable (`minimal` | `graviton` | `spot`; default: `minimal`) replacing hardcoded per-environment instance types
  - `minimal`: t3.medium x86_64 on-demand (~$30/mo compute). Default for all environments.
  - `graviton`: t4g.medium ARM64 on-demand (~$24/mo compute). AL2023, Apache, PHP, and MariaDB all run on ARM64; ~20% cheaper for equivalent workloads.
  - `spot`: t3.medium x86_64 spot pricing (~$4–8/mo compute). Enforces `use_rds=true` and `enable_efs=true` via precondition to prevent data loss on interruption.
  - New `instance_type` variable overrides the profile's default instance size without changing other profile settings
- **AMI architecture awareness** — AL2023 AMI filter now parameterised on `local.cpu_arch` (`x86_64` / `arm64`); baked AMI filter adds architecture tag to prevent cross-arch mismatch

### Changed
- `env_config` volume sizes reduced to reflect realistic needs: test 30 GB (was 100), staging 100 GB (was 500), prod 200 GB (was 1000)
- `test.tfvars` now explicitly sets `deployment_profile=minimal`, `use_rds=false`, `enable_alb=false`, `enable_vpc_endpoints=false`, `enable_waf=false`, `enable_efs=false` — represents the cheapest viable deployment (~$30–35/mo)
- ASG switches from `launch_template` block to `mixed_instances_policy` block — enables spot support while preserving on-demand behaviour for minimal/graviton profiles
- CDK: `ENV_CONFIG` drops `instanceType` (now from `PROFILE_CONFIG`); `deploymentProfile` context variable added; ARM64 machine image selected automatically for graviton profile; spot profile sets `spotPrice` on the ASG
- `cdk.context.example.json`: `deploymentProfile: "minimal"` added as default; defaults lean toward minimal-cost options (`useRds: "false"`, `enableAlb: "false"`, `enableVpcEndpoints: "false"`)

## [0.6.0] - 2026-03-18

### Added
- **Issue #18**: EFS shared web root via `enable_efs` variable (default: `true`)
  - `aws_efs_file_system`: encrypted, `generalPurpose` performance mode
  - `aws_security_group.efs`: ingress port 2049 from EC2 SG
  - `aws_efs_mount_target`: one per subnet in `efs_subnet_ids` (defaults to `[subnet_id]`)
  - `aws_efs_access_point`: POSIX uid/gid 48 (apache), root path `/hubzero`
  - IAM policy: `elasticfilesystem:ClientMount`, `ClientWrite`, `ClientRootAccess`
  - `scripts/userdata.sh`: installs `amazon-efs-utils`, mounts EFS via TLS+IAM+access point, adds `/etc/fstab` entry for persistence
  - Terraform: `efs_id` output; `HUBZERO_EFS_ID` and `HUBZERO_EFS_ACCESS_POINT_ID` exported to userdata
  - CDK: `efs.FileSystem`, `efs.AccessPoint`, equivalent IAM grant, exports
- **Issue #19**: Auto Scaling Group (min=1, max=1) replacing direct `aws_instance`
  - `aws_launch_template.hubzero`: same AMI, instance type, SG, IAM profile, userdata as former `aws_instance`
  - `aws_autoscaling_group.hubzero`: min=1, max=1, desired=1; `health_check_type = "ELB"`; `target_group_arns` attached to ALB; rolling instance refresh via `instance_refresh` block (`min_healthy_percentage = 0`)
  - `aws_autoscaling_attachment`: attaches ASG to ALB target group
  - CloudWatch alarm dimensions updated from `InstanceId` to `AutoScalingGroupName` for EC2/ASG alarms; CWAgent instance-level alarms retain `InstanceId` (targets most-recent launch)
  - Outputs: `instance_id` replaced by `asg_name`; `ssm_connect_command` updated to dynamically look up running instance via `aws ec2 describe-instances`
  - CDK: `autoscaling.AutoScalingGroup`, rolling instance refresh via `CfnAutoScalingGroup.addPropertyOverride`
- **Issue #20**: CloudFront CDN distribution via `enable_cdn` variable (default: `false`)
  - `aws_cloudfront_distribution`: ALB as origin (`https-only`), static asset paths (`/media/*`, `/assets/*`, `/css/*`, `/js/*`) use `CachingOptimized` policy; default behavior uses `CachingDisabled`
  - HTTP→HTTPS redirect for all behaviors; `PriceClass_100` (US/EU/Canada)
  - `enable_cloudfront_waf` variable added (default: `false`) — CloudFront-scoped WAF must reside in `us-east-1`; requires a provider alias (documented constraint)
  - `web_url` output: prefers CloudFront domain when `enable_cdn=true`
  - New output: `cloudfront_domain`
  - CDK: `cloudfront.Distribution` with `origins.LoadBalancerV2Origin`

## [0.5.0] - 2026-03-18

### Added
- **Issue #15**: Packer AMI baking (`packer/hubzero.pkr.hcl`, `scripts/bake.sh`)
  - `packer/hubzero.pkr.hcl`: AL2023 base, `t3.medium` bake instance, shell provisioner runs `bake.sh`, AMI named `hubzero-base-<date>`, tagged with `Project=hubzero` and `GitSHA`
  - `scripts/bake.sh`: extracted static installs from `userdata.sh` — base packages, fail2ban config, Apache + security headers + vhost config, MariaDB client, PHP 8.2 packages + config, Composer + HubZero CMS clone
  - `scripts/userdata.sh`: refactored to env-specific only — services start, certbot, local MariaDB server (if !RDS), Docker+Solr, credentials file, firewall, CWAgent config+start
  - Terraform: `use_baked_ami` variable (default `true`); `data.aws_ami.hubzero_baked` data source (owner=self, filter=`hubzero-base-*`); EC2 uses baked AMI when available, falls back to AL2023; `bake.sh` prepended to userdata when `use_baked_ami=false`
  - CDK: `useBakedAmi` context variable; `MachineImage.lookup` for baked AMI; falls back to `latestAmazonLinux2023`
  - CI: `packer` job validates `packer/hubzero.pkr.hcl` on every PR/push; actual `packer build` gated by secrets
- **Issue #16**: SSM Patch Manager via `enable_patch_manager` variable (default: `true`)
  - `aws_ssm_patch_baseline`: AL2023, Security/Critical+Important classification, 7-day approval
  - `aws_ssm_patch_group`, `aws_ssm_maintenance_window` (Sunday 03:00 UTC), maintenance window target + task (`AWS-RunPatchBaseline`)
  - EC2 instance tagged with `Patch Group = hubzero-${environment}` for SSM targeting
  - CloudWatch alarm: `SSM/NonCompliantCount > 0` for the patch group
  - CDK: `CfnPatchBaseline`, `CfnAssociation` with schedule; `Patch Group` tag on instance
- **Issue #17**: SSM Parameter Store via `enable_parameter_store` variable (default: `true`)
  - Parameters: `domain_name`, `db_host`, `db_name`, `db_user`, `s3_bucket`, `enable_monitoring`, `cw_log_prefix` under `/hubzero/${environment}/`
  - IAM policy: `ssm:GetParametersByPath` + `ssm:GetParameter` on the environment path
  - `scripts/userdata.sh`: at startup, sources SSM parameters via `get-parameters-by-path` and maps to env vars; env var fallbacks remain for compatibility
  - CDK: `StringParameter` constructs for each parameter; IAM policy grant on instance role

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

[Unreleased]: https://github.com/scttfrdmn/aws-hubzero/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/scttfrdmn/aws-hubzero/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/scttfrdmn/aws-hubzero/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/scttfrdmn/aws-hubzero/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/scttfrdmn/aws-hubzero/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/scttfrdmn/aws-hubzero/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/scttfrdmn/aws-hubzero/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/scttfrdmn/aws-hubzero/releases/tag/v0.1.0

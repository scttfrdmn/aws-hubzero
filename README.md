# HubZero AWS Deployment

Deploy the [HubZero](https://help.hubzero.org/) platform on AWS using either
Terraform or AWS CDK (TypeScript). Both tools produce identical infrastructure.

> **New to AWS?** Start with [docs/getting-started-aws.md](docs/getting-started-aws.md)
> — it walks through account setup, CLI configuration, and finding the IDs you need
> before running any deployment commands.

## Deployment Profiles

Choose a profile to match your cost and reliability needs. The profile sets the
EC2 instance type and compute strategy; all other features (RDS, ALB, EFS, etc.)
are controlled independently.

| Profile | Instance | Arch | Pricing | Est. compute/mo | Best for |
|---|---|---|---|---|---|
| **`minimal`** *(default)* | t3.medium | x86_64 | On-demand | ~$30 | Development, small hubs |
| **`graviton`** | t4g.medium | ARM64 | On-demand | ~$24 | Same as minimal, ~20% cheaper |
| **`spot`** | t3.medium | x86_64 | Spot | ~$4–8 | Cost-sensitive; requires RDS + EFS |

**Override the instance size without changing the profile:**

```hcl
# Terraform — use a larger instance when needed, keep all other profile settings
deployment_profile = "minimal"
instance_type      = "t3.large"
```

```bash
# CDK
npx cdk deploy -c deploymentProfile=minimal -c instanceType=t3.large
```

**Spot profile note:** when AWS reclaims a spot instance the ASG launches a
replacement in ~3–5 minutes. Data survives because the web root lives on EFS and
the database lives on RDS. The spot profile enforces both via a deploy-time
precondition.

---

## Architecture

```
Internet ──► CloudFront (CDN, optional)
                 │
                 ▼
         Application Load Balancer (HTTPS)
         AWS WAF v2 (managed rules)
                 │
                 ▼
         Auto Scaling Group (min=1 / max=1)
         ┌───────────────────────────────┐
         │  EC2 — Amazon Linux 2023      │
         │  Apache 2.4 + PHP-FPM 8.2    │
         │  HubZero CMS v2.4            │
         │  Optional: Docker + Solr     │
         └───────────────────────────────┘
              │            │
              ▼            ▼
         RDS MariaDB    EFS (shared
         10.11          web root)
              │
              ▼
         S3 (file storage)
```

**Key properties:**

| Property | Detail |
|---|---|
| OS | Amazon Linux 2023 |
| Web | Apache 2.4 + PHP-FPM 8.2 |
| Database | RDS MariaDB 10.11 (default) or local MariaDB |
| TLS | ACM certificate on ALB — no certbot required |
| Access | SSM Session Manager only — no SSH port exposed |
| AMI | Pre-baked with all packages (Packer); falls back to base AL2023 |
| Scaling | ASG min=1/max=1 with ELB health check and rolling refresh |

All optional features (ALB, WAF, EFS, S3, CDN, monitoring, VPC endpoints,
Parameter Store, Patch Manager) are individually toggleable with boolean variables.

## Prerequisites

- AWS account with permissions to create EC2, RDS, ALB, IAM, and related resources
  (see [docs/getting-started-aws.md](docs/getting-started-aws.md) for IAM setup)
- AWS CLI v2 configured (`aws configure`)
- Terraform >= 1.5 **or** Node.js >= 18 with AWS CDK

Verify your credentials:

```bash
aws sts get-caller-identity
```

## Quick Start — Test Environment

The fastest path is a test deployment with all defaults. You need a VPC ID,
one public subnet ID, and your current public IP.

**Find your VPC and subnet:**

```bash
# List VPCs
aws ec2 describe-vpcs \
  --query 'Vpcs[*].[VpcId,IsDefault,Tags[?Key==`Name`].Value|[0]]' \
  --output table

# List public subnets in a VPC
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<vpc-id>" \
            "Name=map-public-ip-on-launch,Values=true" \
  --query 'Subnets[*].[SubnetId,AvailabilityZone,CidrBlock]' \
  --output table

# Your current public IP
curl -s https://checkip.amazonaws.com
```

### Terraform

```bash
# Bootstrap state backend (one-time per account/region)
bash scripts/bootstrap-terraform-backend.sh

cd terraform
terraform init

# Edit environments/test.tfvars and add your three required values:
#   vpc_id       = "vpc-..."
#   subnet_id    = "subnet-..."
#   allowed_cidr = "YOUR_IP/32"
#
# The test.tfvars already sets deployment_profile=minimal with the
# cost-saving options (no RDS, no ALB, no VPC endpoints) — total ~$35/mo.

terraform apply -var-file=environments/test.tfvars
```

### CDK

```bash
cd cdk
npm install
cp cdk.context.example.json cdk.context.json
# Edit cdk.context.json: set vpcId and allowedCidr
# The example already uses deploymentProfile=minimal with cost-saving defaults

npx cdk bootstrap   # one-time per account/region
npx cdk deploy -c environment=test
```

## Deployment Guide

### Terraform State Backend

Before `terraform init`, create the state S3 bucket and DynamoDB lock table:

```bash
bash scripts/bootstrap-terraform-backend.sh
```

Or update the `backend "s3"` block in `terraform/main.tf` to reference your
existing state bucket.

### Terraform Environments

```bash
cd terraform
terraform init

# Test (minimal, single subnet OK)
terraform apply -var-file=environments/test.tfvars \
  -var='vpc_id=vpc-xxx' \
  -var='subnet_id=subnet-xxx' \
  -var='allowed_cidr=1.2.3.4/32'

# Staging (RDS requires 2 subnets in different AZs)
terraform apply -var-file=environments/staging.tfvars \
  -var='vpc_id=vpc-xxx' \
  -var='subnet_id=subnet-xxx' \
  -var='allowed_cidr=0.0.0.0/0' \
  -var='domain_name=hub.example.com' \
  -var='rds_subnet_ids=["subnet-aaa","subnet-bbb"]'

# Production
terraform apply -var-file=environments/prod.tfvars \
  -var='vpc_id=vpc-xxx' \
  -var='subnet_id=subnet-xxx' \
  -var='allowed_cidr=0.0.0.0/0' \
  -var='domain_name=hub.example.com' \
  -var='alarm_email=ops@example.com' \
  -var='rds_subnet_ids=["subnet-aaa","subnet-bbb","subnet-ccc"]'
```

### CDK Environments

```bash
cd cdk
npm install
cp cdk.context.example.json cdk.context.json
# Edit cdk.context.json

npx cdk bootstrap   # one-time per account/region

npx cdk deploy -c environment=test
npx cdk deploy -c environment=staging -c domainName=hub.example.com
npx cdk deploy -c environment=prod    -c domainName=hub.example.com \
                                       -c alarmEmail=ops@example.com
```

## Instance Access

There is no SSH port — access is exclusively via **SSM Session Manager**.
No EC2 key pair is required.

The deploy outputs a ready-to-run `ssm_connect_command` / `SsmConnect` that
looks up the running instance dynamically:

```bash
# Terraform — copy the ssm_connect_command output value, e.g.:
aws ec2 describe-instances \
  --filters 'Name=tag:aws:autoscaling:groupName,Values=hubzero-test-...' \
            'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].InstanceId' --output text \
  | xargs -I{} aws ssm start-session --target {}

# CDK — copy the SsmConnect output value (same pattern)
```

Once connected, monitor the bootstrap log:

```bash
sudo tail -f /var/log/hubzero-userdata.log
```

Bootstrap completes in roughly 3–5 minutes when using a pre-baked AMI, or
10–15 minutes from the base AL2023 AMI.

## Environments

Instance type is set by `deployment_profile` (default: t3.medium). Use
`instance_type` to override. EBS volume and RDS sizing are per-environment:

| Environment | EBS    | RDS Class (when `use_rds=true`) | RDS Storage | Multi-AZ |
|-------------|--------|----------------------------------|-------------|----------|
| test        | 30 GB  | db.t3.medium                     | 20 GB       | No       |
| staging     | 100 GB | db.r6g.xlarge                    | 100 GB      | No       |
| prod        | 200 GB | db.r6g.2xlarge                   | 500 GB      | Yes      |

## TLS / HTTPS

When `enable_alb=true` (default) and a `domain_name` is set:

1. An ACM certificate is provisioned with DNS validation.
2. The deploy outputs a CNAME record under `acm_certificate_validation_cname`.
3. Add that CNAME to your DNS provider.
4. Once ACM validates the domain, the ALB HTTPS listener activates.

No certbot is involved. TLS terminates at the ALB; the EC2 instance receives
plain HTTP from the load balancer on port 80.

For test environments without a domain name, set `enable_alb=false` to skip
the ALB entirely and access the instance directly over HTTP.

## Building a Baked AMI (Packer)

Using a pre-baked AMI makes instance launches 3–5× faster and ensures
identical environments across replacements.

```bash
cd packer
packer init .

# Build (requires AWS credentials with EC2 permissions)
GIT_SHA=$(git rev-parse --short HEAD) packer build hubzero.pkr.hcl
```

The resulting AMI is named `hubzero-base-YYYY-MM-DD`. Terraform and CDK
automatically prefer it over the base AL2023 AMI when `use_baked_ami=true`
(the default).

To bake a new AMI after system updates:

```bash
GIT_SHA=$(git rev-parse --short HEAD) packer build \
  -var aws_region=us-east-1 hubzero.pkr.hcl
```

## Security Features

- **No SSH port** — SSM Session Manager is the only access path
- **IMDSv2 enforced** — token-based instance metadata, hop limit 1
- **ALB + WAF v2** — CommonRuleSet, KnownBadInputsRuleSet, SQLiRuleSet in Block mode
- **ACM TLS** — AWS-managed certificate with automatic renewal
- **VPC endpoints** — S3 (gateway), SSM, SSMMessages, EC2Messages, SecretsManager, Logs (interface); no internet egress required for AWS API calls
- **Encrypted storage** — EBS, RDS, EFS, and S3 all encrypted at rest (AES-256 / KMS)
- **RDS managed credentials** — master password in Secrets Manager, never in state
- **SSM Parameter Store** — runtime configuration injected at boot, not hard-coded
- **SSM Patch Manager** — weekly Sunday 03:00 UTC maintenance window; Security/Critical+Important patches; 7-day auto-approval
- **fail2ban** — Apache brute-force rate limiting
- **HSTS + security headers** — `Strict-Transport-Security`, `X-Content-Type-Options`, `X-Frame-Options`, `Content-Security-Policy`, and more
- **PHP hardening** — `expose_php = Off`, `open_basedir`, secure session cookies
- **Daily EBS snapshots** — DLM lifecycle policy (7-day retention; 30 days for prod)
- **RDS automated backups** — 7-day retention (14 days for prod), deletion protection in prod
- **Docker hardening** — user namespace remapping, read-only filesystem, digest-pinned images, resource limits (when `install_platform=true`)

## Configuration Variables

### Core (required)

| Variable | Description |
|---|---|
| `vpc_id` / `vpcId` | Existing VPC ID |
| `subnet_id` | Public subnet for EC2 / ALB (Terraform) |
| `allowed_cidr` / `allowedCidr` | CIDR for ALB ingress — use `0.0.0.0/0` only when behind WAF |
| `environment` | `test`, `staging`, or `prod` |

### Networking & TLS

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | AWS region |
| `domain_name` / `domainName` | `""` | Domain for ACM cert + HTTPS |
| `enable_alb` / `enableAlb` | `true` | ALB with HTTPS termination |
| `acm_certificate_arn` | `""` | Bring-your-own ACM cert ARN (empty = create new) |
| `enable_cdn` / `enableCdn` | `false` | CloudFront CDN in front of ALB |
| `enable_vpc_endpoints` | `true` | VPC endpoints for AWS services |

### Compute & Storage

| Variable | Default | Description |
|---|---|---|
| `deployment_profile` / `deploymentProfile` | `minimal` | `minimal`, `graviton`, or `spot` — see [Deployment Profiles](#deployment-profiles) |
| `instance_type` / `instanceType` | `""` | Override the profile's instance size (e.g. `t3.large`) |
| `use_baked_ami` / `useBakedAmi` | `true` | Prefer pre-baked `hubzero-base-*` AMI; auto-selects correct architecture |
| `key_name` / `keyName` | `""` | EC2 key pair (optional; SSM is preferred) |
| `use_rds` / `useRds` | `true` | RDS MariaDB; `false` = local DB. Required `true` for `spot` profile |
| `rds_subnet_ids` | `[]` | ≥2 subnet IDs in different AZs (required when `use_rds=true`) |
| `enable_s3_storage` / `enableS3Storage` | `true` | S3 bucket for HubZero file uploads |
| `enable_efs` / `enableEfs` | `true` | EFS shared web root. Required `true` for `spot` profile |
| `efs_subnet_ids` | `[]` | EFS mount target subnets (defaults to `subnet_id`) |

### Security

| Variable | Default | Description |
|---|---|---|
| `enable_waf` / `enableWaf` | `true` | WAF v2 on ALB (requires `enable_alb`) |
| `enable_patch_manager` | `true` | SSM Patch Manager weekly patching |

### Observability

| Variable | Default | Description |
|---|---|---|
| `enable_monitoring` / `enableMonitoring` | `true` | CloudWatch metrics, alarms, log groups |
| `alarm_email` / `alarmEmail` | `""` | SNS email for CloudWatch alarm notifications |
| `enable_parameter_store` | `true` | Store config in SSM Parameter Store |

### Application

| Variable | Default | Description |
|---|---|---|
| `install_platform` / `installPlatform` | `false` | Docker + Apache Solr 9.7 |
| `certbot_email` / `certbotEmail` | `""` | Email for certbot (only used when `enable_alb=false`) |

## Outputs

| Output | Description |
|---|---|
| `web_url` | Full URL (CloudFront > domain > ALB DNS) |
| `asg_name` | Auto Scaling Group name |
| `alb_dns_name` | ALB DNS name (empty if ALB disabled) |
| `cloudfront_domain` | CloudFront domain (empty if CDN disabled) |
| `ssm_connect_command` | Ready-to-run SSM session command |
| `rds_endpoint` | RDS endpoint (N/A if local DB) |
| `efs_id` | EFS file system ID |
| `s3_bucket_name` | S3 bucket name for file storage |
| `acm_certificate_validation_cname` | DNS CNAME to add for ACM validation |
| `sns_topic_arn` | SNS alarm topic ARN |

## Migrating from On-Premises

See [docs/migration-guide.md](docs/migration-guide.md) for a step-by-step guide
to migrating an existing on-premises HubZero instance, including a migration
script at `scripts/migrate.sh`.

## Teardown

```bash
# Terraform
cd terraform
terraform destroy -var-file=environments/test.tfvars \
  -var='vpc_id=vpc-xxx' -var='subnet_id=subnet-xxx' -var='allowed_cidr=0.0.0.0/0'

# CDK
cd cdk
npx cdk destroy -c environment=test
```

Production resources have deletion protection. Disable before destroying:

```bash
# RDS deletion protection
aws rds modify-db-instance \
  --db-instance-identifier <id> --no-deletion-protection --apply-immediately

# EFS (must delete mount targets first)
aws efs describe-mount-targets --file-system-id <efs-id> \
  --query 'MountTargets[*].MountTargetId' --output text \
  | xargs -n1 aws efs delete-mount-target --mount-target-id
```

## Project Structure

```
├── docs/
│   ├── getting-started-aws.md   # AWS primer for new users
│   └── migration-guide.md       # On-prem to AWS migration guide
├── packer/
│   └── hubzero.pkr.hcl          # Packer template for baked AMI
├── scripts/
│   ├── bake.sh                  # Static installs baked into AMI
│   ├── userdata.sh              # Launch-time env-specific bootstrap
│   ├── migrate.sh               # On-prem migration script
│   └── bootstrap-terraform-backend.sh
├── terraform/
│   ├── main.tf                  # All AWS resources
│   ├── variables.tf
│   ├── outputs.tf
│   └── environments/
│       ├── test.tfvars
│       ├── staging.tfvars
│       └── prod.tfvars
└── cdk/
    ├── bin/app.ts
    ├── lib/hubzero-stack.ts     # CDK stack (feature-parity with Terraform)
    ├── cdk.context.example.json
    └── package.json
```

## Cost Estimate

Costs in us-east-1 (on-demand pricing). Profile determines the EC2 cost;
other services are the same across profiles.

### By deployment profile (test environment, minimal services)

| Profile | EC2 | Local MariaDB | No ALB | No VPC endpoints | **Total** |
|---|---|---|---|---|---|
| `minimal` (t3.medium) | ~$30/mo | $0 | $0 | $0 | **~$35/mo** |
| `graviton` (t4g.medium) | ~$24/mo | $0 | $0 | $0 | **~$29/mo** |
| `spot` (t3.medium spot) | ~$5/mo | — | — | — | **~$65/mo** (spot + RDS + EFS required) |

### Full production stack (all features enabled)

| Resource | minimal | graviton | spot |
|---|---|---|---|
| EC2 | ~$30/mo | ~$24/mo | ~$5/mo |
| RDS db.r6g.2xlarge (Multi-AZ, prod) | ~$740/mo | ~$740/mo | ~$740/mo |
| ALB | ~$20/mo | ~$20/mo | ~$20/mo |
| EFS (10 GB) | ~$3/mo | ~$3/mo | ~$3/mo |
| S3 + CloudWatch | ~$15/mo | ~$15/mo | ~$15/mo |
| VPC endpoints (5 interface) | ~$35/mo | ~$35/mo | ~$35/mo |
| **Total** | **~$843/mo** | **~$837/mo** | **~$818/mo** |

For a typical small research hub the RDS instance can be sized down significantly
(db.t3.medium at ~$55/mo instead of db.r6g.2xlarge). Use
[AWS Pricing Calculator](https://calculator.aws) for precise estimates.

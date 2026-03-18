# HubZero AWS Deployment

Deploy the [HubZero](https://help.hubzero.org/) platform on AWS using either Terraform or AWS CDK (TypeScript).

## Architecture

**Current**: Single EC2 instance (Rocky Linux 8) running Apache 2.4, PHP 8.2, MariaDB 10.11 (local or RDS), and HubZero CMS v2.4. Optional Docker-based Solr search.

**Future**: Split-tier with ALB, private subnets, EFS for shared storage, and Docker-based tool sessions.

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.5 (for Terraform deployments)
- Node.js >= 18 (for CDK deployments)

### 1. Verify AWS credentials

```bash
aws sts get-caller-identity
```

### 2. Identify your VPC and public subnet

```bash
aws ec2 describe-vpcs \
  --query 'Vpcs[*].[VpcId,Tags[?Key==`Name`].Value|[0]]' --output table

aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<your-vpc-id>" \
            "Name=map-public-ip-on-launch,Values=true" \
  --query 'Subnets[*].[SubnetId,AvailabilityZone]' --output table
```

## Deploying

### Terraform State

Terraform state is stored in an encrypted S3 backend with DynamoDB locking (configured in `main.tf`). Before running `terraform init`, create the S3 bucket and DynamoDB table, or update the backend block to match your existing state infrastructure:

```hcl
backend "s3" {
  bucket         = "hubzero-terraform-state"
  key            = "hubzero/terraform.tfstate"
  region         = "us-east-1"
  encrypt        = true
  dynamodb_table = "hubzero-terraform-locks"
}
```

### Terraform

```bash
cd terraform
terraform init
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values:

```hcl
aws_region   = "us-east-1"
environment  = "test"             # test, staging, or prod
vpc_id       = "vpc-xxxxxxxxxxxxxxxxx"
subnet_id    = "subnet-xxxxxxxxxxxxxxxxx"
allowed_cidr = "YOUR_IP/32"       # e.g. "203.0.113.5/32"
domain_name  = ""                 # optional
certbot_email = ""                # recommended for staging/prod
install_platform = false          # set true for Docker + Solr
```

Deploy:

```bash
terraform plan -var-file=environments/test.tfvars
terraform apply -var-file=environments/test.tfvars
```

For other environments:

```bash
terraform apply -var-file=environments/staging.tfvars
terraform apply -var-file=environments/prod.tfvars
```

### CDK

```bash
cd cdk
npm install
cp cdk.context.example.json cdk.context.json
```

Edit `cdk.context.json` with your values:

```json
{
  "vpcId": "vpc-xxxxxxxxxxxxxxxxx",
  "environment": "test",
  "allowedCidr": "YOUR_IP/32",
  "domainName": "",
  "certbotEmail": "",
  "installPlatform": "false"
}
```

Deploy:

```bash
npx cdk bootstrap   # one-time per account/region
npx cdk deploy -c environment=test
```

For other environments:

```bash
npx cdk deploy -c environment=staging -c installPlatform=true
npx cdk deploy -c environment=prod -c installPlatform=true
```

## Instance Access

Access is via **SSM Session Manager** only — SSH (port 22) is not exposed. No EC2 key pair is required.

```bash
# Connect using the instance ID from the deploy output
aws ssm start-session --target <instance-id>
```

An optional `key_name` / `keyName` variable is available if you need SSH for debugging, but it requires manually adding port 22 to the security group.

## Environments

| Environment | Instance Type | Disk   | Notes                     |
|-------------|---------------|--------|---------------------------|
| test        | t3.xlarge     | 100GB  | Single user dev/testing   |
| staging     | m6i.2xlarge   | 500GB  | Pre-production validation |
| prod        | m6i.4xlarge   | 1000GB | Full production workload  |

## Monitoring the Bootstrap

The instance takes ~10–15 minutes to finish installing all software. Monitor progress:

```bash
aws ssm start-session --target <instance-id>
sudo tail -f /var/log/hubzero-userdata.log
```

Once the log shows `HubZero bootstrap completed`, the web interface is available at `http://<public-ip>/` (test) or `https://<domain>` (if TLS was configured).

## Security Features

- **SSM-only access** — no SSH port exposed, no key pair required
- **IMDSv2 enforced** — token-based instance metadata
- **Encrypted storage** — EBS and RDS volumes encrypted at rest
- **RDS-managed credentials** — master password managed by RDS via Secrets Manager (never in Terraform state)
- **Restricted egress** — outbound limited to HTTPS, HTTP, DNS, and MySQL (VPC only)
- **fail2ban** — Apache brute-force protection
- **Automated TLS** — certbot with auto-renewal and syslog error logging
- **HSTS + security headers** — X-Content-Type-Options, X-Frame-Options, Referrer-Policy, Strict-Transport-Security, Content-Security-Policy, Permissions-Policy, X-Permitted-Cross-Domain-Policies
- **ServerTokens Prod / ServerSignature Off** — suppresses Apache version disclosure
- **PHP hardening** — `expose_php = Off`, secure session cookies (httponly, secure, samesite)
- **Directory hardening** — `-Indexes`, `SymLinksIfOwnerMatch`, restricted config file permissions
- **Daily EBS snapshots** — via DLM lifecycle policy (7-day retention, 30 for prod)
- **RDS automated backups** — 7-day retention (14 for prod) with deletion protection in prod
- **EC2 termination protection** — enabled for production instances
- **Docker hardening** — user namespace remapping, read-only container filesystem, digest-pinned images, resource limits
- **Composer integrity** — installer checksum verification, `--no-scripts` flag

## Configuration Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `aws_region` | AWS region | `us-east-1` |
| `vpc_id` / `vpcId` | Existing VPC ID | (required) |
| `subnet_id` | Public subnet ID (Terraform only) | (required) |
| `key_name` / `keyName` | EC2 key pair name (optional) | `""` |
| `environment` | `test`, `staging`, or `prod` | `test` |
| `allowed_cidr` / `allowedCidr` | CIDR for inbound HTTP/HTTPS | (required) |
| `domain_name` / `domainName` | Domain for HTTPS (optional) | `""` |
| `certbot_email` / `certbotEmail` | Email for TLS cert expiry alerts | `""` |
| `install_platform` / `installPlatform` | Install full platform (Docker + Solr) | `false` |
| `use_rds` / `useRds` | Use RDS MariaDB instead of local | `false` |
| `rds_subnet_ids` | Subnet IDs for RDS (Terraform, ≥2 AZs) | `[]` |

### RDS Option

Set `use_rds=true` / `useRds=true` to provision an RDS MariaDB 10.11 instance instead of running MariaDB locally on the EC2 instance. The EC2 userdata will skip the local database install and connect to RDS instead. The RDS master password is managed by RDS itself via Secrets Manager — it never appears in Terraform state or CDK outputs.

| Environment | RDS Instance Class | Storage | Multi-AZ | Backup Retention |
|-------------|-------------------|---------|----------|------------------|
| test        | db.t3.medium      | 20GB    | No       | 7 days           |
| staging     | db.r6g.xlarge     | 100GB   | No       | 7 days           |
| prod        | db.r6g.2xlarge    | 500GB   | Yes      | 14 days          |

**Terraform** requires `rds_subnet_ids` with at least 2 subnets in different AZs:

```bash
terraform apply -var-file=environments/test.tfvars -var="use_rds=true" \
  -var='rds_subnet_ids=["subnet-aaa","subnet-bbb"]'
```

**CDK** uses the VPC's existing subnets automatically:

```bash
npx cdk deploy -c environment=test -c useRds=true
```

## Migrating from On-Prem

See [docs/migration-guide.md](docs/migration-guide.md) for a complete guide to migrating an existing on-premises HubZero deployment to AWS, including a migration script at `scripts/migrate.sh`.

## Teardown

```bash
# Terraform
cd terraform
terraform destroy -var-file=environments/test.tfvars

# CDK
cd cdk
npx cdk destroy -c environment=test
```

Note: Production RDS has deletion protection enabled. Disable it manually before destroying:

```bash
aws rds modify-db-instance --db-instance-identifier <id> --no-deletion-protection
```

Production EC2 has termination protection enabled. Disable it before destroying:

```bash
aws ec2 modify-instance-attribute --instance-id <id> --no-disable-api-termination
```

## Project Structure

```
├── docs/
│   └── migration-guide.md      # On-prem to AWS migration guide
├── scripts/
│   ├── userdata.sh              # Shared bootstrap script
│   └── migrate.sh               # On-prem migration script
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── environments/            # Per-environment tfvars
│   │   ├── test.tfvars
│   │   ├── staging.tfvars
│   │   └── prod.tfvars
│   └── terraform.tfvars.example
└── cdk/
    ├── bin/app.ts
    ├── lib/hubzero-stack.ts
    ├── eslint.config.mjs
    ├── package.json
    ├── tsconfig.json
    ├── cdk.json
    └── cdk.context.example.json
```

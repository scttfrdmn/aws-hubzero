# Getting Started with AWS — HubZero Deployment Guide

This guide is for people who are new to AWS or have used it only occasionally.
It covers everything you need before running your first `terraform apply` or
`cdk deploy`: account setup, CLI configuration, understanding the key services
this project uses, and finding the resource IDs you will be asked to provide.

If you are already comfortable with AWS, VPCs, IAM, and the CLI, you can skip
to the [Prerequisites section of the README](../README.md#prerequisites).

---

## Table of Contents

1. [What AWS services does this project use?](#1-what-aws-services-does-this-project-use)
2. [Create an AWS account](#2-create-an-aws-account)
3. [Set up IAM — create a deployment user](#3-set-up-iam--create-a-deployment-user)
4. [Install and configure the AWS CLI](#4-install-and-configure-the-aws-cli)
5. [Understand regions and availability zones](#5-understand-regions-and-availability-zones)
6. [Find your VPC and subnet IDs](#6-find-your-vpc-and-subnet-ids)
7. [Understand what this deployment creates](#7-understand-what-this-deployment-creates)
8. [Estimated costs](#8-estimated-costs)
9. [Common first-timer mistakes](#9-common-first-timer-mistakes)
10. [Monitoring your deployment](#10-monitoring-your-deployment)
11. [Next step: deploy](#11-next-step-deploy)

---

## 1. What AWS services does this project use?

You do not need deep expertise in all of these before deploying — the
Terraform/CDK code creates and wires them together. But knowing what each
service is helps when reading deploy output or troubleshooting.

| Service | What it does in this project |
|---|---|
| **EC2** | Virtual machine that runs Apache, PHP, and HubZero |
| **RDS** | Managed MariaDB database (no OS to maintain) |
| **S3** | Object storage for HubZero file uploads |
| **EFS** | Network file system — shared web root, survives instance replacement |
| **ALB** | Application Load Balancer — terminates HTTPS, distributes traffic |
| **ACM** | Manages the TLS certificate (free, auto-renewed) |
| **WAF** | Web Application Firewall — blocks common web attacks |
| **CloudFront** | Global CDN — caches static assets near users (optional) |
| **IAM** | Identity and access control — the EC2 instance gets a role to call AWS APIs |
| **SSM** | Systems Manager — lets you open a shell on the EC2 instance without SSH |
| **Secrets Manager** | Stores the RDS password securely |
| **Parameter Store** | Stores configuration (domain, DB host, S3 bucket, etc.) |
| **CloudWatch** | Logs, metrics, and alarms |
| **VPC** | Your private network inside AWS — required before anything else |

---

## 2. Create an AWS account

If you already have an AWS account, skip to section 3.

1. Go to [https://aws.amazon.com](https://aws.amazon.com) and choose **Create an
   AWS Account**.
2. You will need an email address, phone number, and credit card. AWS will not
   charge you unless you deploy resources beyond the free tier.
3. Choose the **Basic (free) support plan** unless you need paid support.
4. After your account is active, sign in to the **AWS Management Console**.

**Enable MFA on the root account immediately.** The root account has unrestricted
access to everything. Go to the top-right menu → Security Credentials →
Multi-factor authentication → Assign MFA device.

---

## 3. Set up IAM — create a deployment user

Never use your root account for day-to-day work. Create an IAM user (or role)
with just enough permissions to deploy this project.

### Option A: Quick start (AdministratorAccess)

This is the fastest path but grants broad permissions. Acceptable for personal
or lab accounts; not appropriate for shared or production accounts.

1. In the AWS Console, search for **IAM** and open the service.
2. Go to **Users** → **Create user**.
3. Username: `hubzero-deploy` (or any name you prefer).
4. Select **Attach policies directly** and search for `AdministratorAccess`.
5. Attach it and create the user.
6. On the user page, go to **Security credentials** → **Create access key**.
7. Select **Command Line Interface (CLI)** as the use case.
8. Download the CSV file — you will not be able to see the secret key again.

### Option B: Least-privilege policy

For team or production use, create a custom policy that grants only what
Terraform/CDK needs. The services required are:

```
ec2:*, rds:*, s3:*, iam:*, autoscaling:*, elasticloadbalancing:*,
acm:*, wafv2:*, cloudfront:*, cloudwatch:*, logs:*, sns:*,
ssm:*, secretsmanager:*, kms:*, elasticfilesystem:*,
sts:GetCallerIdentity, sts:AssumeRole (for CDK bootstrap role)
```

A ready-made policy document is beyond the scope of this guide; the AWS
documentation has a [policy generator](https://awspolicygen.s3.amazonaws.com/policygen.html)
and the [IAM policy simulator](https://policysim.aws.amazon.com) can validate
your policy before deploying.

---

## 4. Install and configure the AWS CLI

### Install

**macOS (Homebrew):**
```bash
brew install awscli
```

**macOS / Linux (official installer):**
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install
```

**Windows:** Download the MSI installer from
[https://aws.amazon.com/cli/](https://aws.amazon.com/cli/).

Verify:
```bash
aws --version
# aws-cli/2.x.x ...
```

### Configure

```bash
aws configure
```

Enter the four values when prompted:

```
AWS Access Key ID [None]:     <paste your access key ID>
AWS Secret Access Key [None]: <paste your secret access key>
Default region name [None]:   us-east-1
Default output format [None]: json
```

The credentials are saved to `~/.aws/credentials` and the region/format to
`~/.aws/config`.

Verify it works:

```bash
aws sts get-caller-identity
```

Expected output:
```json
{
    "UserId": "AIDAXXXXXXXXXXXXXXXXX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/hubzero-deploy"
}
```

If you see an error, double-check the access key and secret key values.

### Multiple AWS accounts or profiles

If you have multiple accounts or want to keep this project's credentials
separate, use a named profile:

```bash
aws configure --profile hubzero
```

Then prefix all commands with `--profile hubzero`, or set the environment
variable for a session:

```bash
export AWS_PROFILE=hubzero
aws sts get-caller-identity
```

---

## 5. Understand regions and availability zones

**Region** — a geographic area containing AWS data centers. Examples:
`us-east-1` (North Virginia), `eu-west-1` (Ireland), `ap-southeast-1`
(Singapore). Every resource you create lives in one region.

**Availability Zone (AZ)** — a physically separate data center within a region.
Each region has 2–6 AZs. AZs are named like `us-east-1a`, `us-east-1b`, etc.
Deploying across multiple AZs protects against single-facility failures.

**Why this matters for your deployment:**

- All resources must be in the same region (set via `aws_region` variable).
- RDS requires subnets in **at least 2 different AZs** (`rds_subnet_ids`).
  This is an AWS requirement for creating a DB subnet group.
- EFS mount targets are created per AZ.

**Choose a region close to your users.** For most US deployments, `us-east-1`
is a safe default. Check the
[AWS regional services list](https://aws.amazon.com/about-aws/global-infrastructure/regional-product-services/)
if you need a specific service to be available.

---

## 6. Find your VPC and subnet IDs

Every AWS account gets a **default VPC** in each region with public subnets
already created. For a test deployment you can use the default VPC. For
staging and production, you should use or create a dedicated VPC.

### Find your default VPC

```bash
aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[*].[VpcId,CidrBlock]' \
  --output table
```

Example output:
```
-----------------------------------------
|           DescribeVpcs                |
+------------------------+--------------+
|  vpc-0123456789abcdef0 |  172.31.0.0/16 |
+------------------------+--------------+
```

Your `vpc_id` is the value in the first column, e.g. `vpc-0123456789abcdef0`.

### Find public subnets

Public subnets automatically assign a public IP to instances — you want these
for the EC2 instance and ALB.

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<your-vpc-id>" \
            "Name=map-public-ip-on-launch,Values=true" \
  --query 'Subnets[*].[SubnetId,AvailabilityZone,CidrBlock]' \
  --output table
```

Example output:
```
-----------------------------------------------------------------
|                       DescribeSubnets                         |
+----------------------------+--------------+------------------+
|  subnet-0aaaaaaaaaaaaaaaa  |  us-east-1a  |  172.31.0.0/20  |
|  subnet-0bbbbbbbbbbbbbbbbb |  us-east-1b  |  172.31.16.0/20 |
|  subnet-0ccccccccccccccccc |  us-east-1c  |  172.31.32.0/20 |
+----------------------------+--------------+------------------+
```

For the deployment you need:

| Variable | What to use |
|---|---|
| `subnet_id` | Any one subnet ID (e.g. `subnet-0aaaaaaaaaaaaaaaa`) |
| `rds_subnet_ids` | At least 2 subnet IDs in **different** AZs (e.g. `["subnet-0aaa...","subnet-0bbb..."]`) |
| `efs_subnet_ids` | Same or subset of the above (defaults to `subnet_id` if omitted) |

### Find your current public IP

The `allowed_cidr` variable controls who can reach the ALB. For a test
deployment, restrict it to your IP address:

```bash
curl -s https://checkip.amazonaws.com
# 203.0.113.42
```

Use that as `203.0.113.42/32` (the `/32` means "exactly this one address").

For staging and production with a real domain, set `allowed_cidr=0.0.0.0/0`
— the WAF managed rules will handle filtering.

---

## 7. Understand what this deployment creates

When you run `terraform apply` or `cdk deploy` for the first time, AWS
provisions the following (with default settings):

```
VPC (yours, existing)
  ├── Security Groups
  │   ├── hubzero-ec2      — allows HTTP from ALB SG, all egress
  │   ├── hubzero-alb      — allows HTTP/HTTPS from allowed_cidr
  │   ├── hubzero-efs      — allows NFS from EC2 SG
  │   └── hubzero-endpoints — allows HTTPS from EC2 SG
  │
  ├── EC2 (via Auto Scaling Group)
  │   └── Launch Template → Amazon Linux 2023 instance
  │       ├── IAM instance profile (access to S3, SSM, Secrets, EFS)
  │       └── userdata.sh (runs at first boot)
  │
  ├── RDS MariaDB 10.11 (db.t3.medium for test)
  │   └── Secrets Manager (auto-generated password)
  │
  ├── EFS File System
  │   └── Access Point (Apache user uid/gid 48)
  │
  ├── S3 Bucket
  │   ├── Versioning enabled
  │   ├── AES-256 encryption
  │   └── 90-day STANDARD_IA lifecycle transition
  │
  ├── Application Load Balancer
  │   ├── HTTP listener → redirect to HTTPS
  │   └── HTTPS listener → EC2 target group
  │
  ├── WAF v2 Web ACL
  │   ├── AWS Managed CommonRuleSet (Block)
  │   ├── AWS Managed KnownBadInputsRuleSet (Block)
  │   └── AWS Managed SQLiRuleSet (Block)
  │
  ├── ACM Certificate (DNS-validated)
  │
  ├── VPC Endpoints
  │   ├── S3 (gateway — free)
  │   ├── SSM (interface)
  │   ├── SSMMessages (interface)
  │   ├── EC2Messages (interface)
  │   ├── SecretsManager (interface)
  │   └── CloudWatch Logs (interface)
  │
  ├── SSM Parameter Store parameters
  │   └── /hubzero/<environment>/{domain,db_host,db_name,...}
  │
  ├── SSM Patch Manager
  │   └── Weekly Sunday 03:00 UTC maintenance window
  │
  ├── CloudWatch
  │   ├── Log groups (userdata, apache-access, apache-error)
  │   ├── Alarms (CPU, StatusCheck, memory, disk, RDS, WAF)
  │   └── SNS topic for alarm notifications
  │
  └── IAM
      ├── EC2 instance role + profile
      ├── DLM role (EBS snapshots)
      └── Inline policies for S3, EFS, SSM, CloudWatch
```

The HubZero application itself is installed during the first EC2 boot (or
pre-installed in the baked AMI) by `scripts/userdata.sh`.

### What gets billed immediately

All resources start billing as soon as they are created — even before the
instance finishes booting. The main cost drivers are EC2, RDS, and the five
interface VPC endpoints. See [Cost Estimate](#8-estimated-costs) below.

### What happens on first boot

1. The EC2 instance starts and runs `userdata.sh`.
2. The script reads configuration from SSM Parameter Store.
3. It mounts EFS at `/var/www/hubzero`.
4. It starts Apache, PHP-FPM, and fail2ban (pre-installed in baked AMI).
5. It configures the CloudWatch Agent and starts shipping logs.
6. Bootstrap log is at `/var/log/hubzero-userdata.log`.

After ~3–5 minutes (baked AMI) or 10–15 minutes (base AMI), the ALB health
check will pass and the load balancer will start forwarding traffic.

---

## 8. Estimated costs

These are rough on-demand estimates for `us-east-1`. Actual costs depend on
traffic volume, data transfer, and any savings plans or reserved instances.

The default `deployment_profile=minimal` with the cost-saving options in
`test.tfvars` gives you:

| Resource | Cost | Notes |
|---|---|---|
| EC2 t3.medium (minimal profile) | ~$30/mo | |
| Local MariaDB (`use_rds=false`) | $0 | Included on EC2 |
| EBS 30 GB gp3 | ~$2.40/mo | |
| S3 + CloudWatch | ~$3/mo | |
| **Total** | **~$35/mo** | |

To go even cheaper, use the `graviton` profile (t4g.medium ARM64, ~$24/mo
compute) — total ~$29/month.

The `spot` profile gets EC2 compute down to ~$4–8/month but requires
`use_rds=true` and `enable_efs=true`, which adds ~$58/month, for a total of
~$65/month. Worth it for longer-running deployments where spot interruptions
(3–5 min downtime) are tolerable.

---

## 9. Common first-timer mistakes

**"I got an error about insufficient IAM permissions"**

Your deploy user is missing a permission. The error message will say which
action is denied, e.g.:
```
AccessDenied: User is not authorized to perform: iam:CreateRole
```
Add the missing permission to your IAM user's policy, or use `AdministratorAccess`
for a test deployment.

**"Terraform says it can't find my VPC / subnet"**

Make sure you are deploying to the same region as your VPC. Check that
`aws_region` in your tfvars matches the region where the VPC exists.

**"RDS creation failed with 'DB subnet group does not cover enough AZs'"**

`rds_subnet_ids` must include subnets from at least 2 different AZs. Check
the AZ column in the subnet list command from section 6.

**"The ALB health check is failing / the instance is unhealthy"**

The instance may still be bootstrapping. Wait 10–15 minutes and check the
bootstrap log via SSM:

```bash
# Use the ssm_connect_command from the Terraform/CDK output
sudo tail -f /var/log/hubzero-userdata.log
```

**"ACM certificate is stuck in 'Pending validation'"**

You need to add the DNS CNAME record that ACM provides. The deploy output
includes the exact record name and value under `acm_certificate_validation_cname`.
Add it to your DNS provider (Route 53, Cloudflare, etc.) and wait a few
minutes for validation to complete.

**"I can't connect via SSM"**

- The VPC endpoints for SSM may still be provisioning (takes 2–5 minutes).
- If `enable_vpc_endpoints=false`, the instance needs outbound internet access
  (NAT gateway or internet gateway) to reach the SSM endpoint.
- Verify the instance has the `AmazonSSMManagedInstanceCore` policy (attached
  by default via the IAM role in this project).

**"I destroyed the stack but I'm still being charged"**

Check for:
- RDS with deletion protection (`aws rds describe-db-instances`)
- EBS snapshots created by the DLM lifecycle policy — Terraform does not
  delete snapshots automatically; see the
  [Destroying the Stack](../README.md#destroying-the-stack) section for commands
- The Terraform state S3 bucket and DynamoDB table — these are created by
  `bootstrap-terraform-backend.sh` and are not part of `terraform destroy`;
  run `scripts/teardown-terraform-backend.sh` after destroy to remove them

**"I get a 403 or 'blocked' response from the ALB"**

The WAF is blocking a request that matched one of the managed rules. Check
CloudWatch → Log groups for the WAF log stream. You can temporarily switch
a rule to `COUNT` mode in the AWS Console to diagnose false positives.

---

## 10. Monitoring your deployment

`terraform apply` creates the AWS infrastructure in **2–3 minutes**, but the
EC2 instance then bootstraps in the background. With the default `minimal` profile
(no baked AMI), **expect 10–15 minutes** before HubZero is reachable.

### What's happening during that time

1. The Auto Scaling Group launches an EC2 instance
2. User data runs: exports env vars, then fetches `bake.sh` and `userdata.sh` from GitHub
3. `bake.sh` installs Apache, PHP 8.2, MariaDB client, Composer, and clones HubZero CMS (~8–12 min)
4. `userdata.sh` configures the environment, wires the database, starts services (~1–2 min)

### Commands to follow along

```bash
# Find the instance launched by your ASG
ASG_NAME=$(terraform -chdir=terraform output -raw asg_name)
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=${ASG_NAME}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
echo "Instance: $INSTANCE_ID"

# Check instance state and public IP
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress,LaunchTime]' \
  --output table

# Wait ~60–90 seconds for SSM agent to register, then run a log check
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["tail -100 /var/log/cloud-init-output.log"]' \
  --output text --query 'Command.CommandId'

# Retrieve the output (replace COMMAND_ID with the ID printed above)
aws ssm get-command-invocation \
  --command-id COMMAND_ID --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' --output text
```

You can also open a live shell (requires the [SSM Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)):

```bash
aws ssm start-session --target "$INSTANCE_ID"

# Inside the session — follow each log in sequence:
sudo tail -f /var/log/cloud-init-output.log   # overall cloud-init progress
sudo tail -f /var/log/hubzero-bake.log        # package install phase
sudo tail -f /var/log/hubzero-userdata.log    # configuration phase
```

### Success indicators

Bootstrap is complete when you see:

```
=== HubZero bootstrap completed at <timestamp> ===
```

At that point, HubZero is reachable at:
- Without ALB: `http://<public-ip>/` (port 80)
- With ALB: `https://<your-domain>/`

---

## 11. Next step: deploy

Once you have:

- [ ] An AWS account with CLI access configured
- [ ] Your VPC ID (`vpc-...`)
- [ ] At least one public subnet ID (`subnet-...`)
- [ ] Two subnet IDs in different AZs for RDS (if using RDS)
- [ ] Your public IP for `allowed_cidr`

You are ready to deploy. Return to the [README](../README.md#quick-start--test-environment)
and follow the Quick Start instructions.

For your first deployment, use `environment=test` with a single subnet. The
full production configuration with a domain name, TLS certificate, and
multi-AZ RDS can come once you have a working test deployment.

When you are done testing and want to remove all resources, see
[Destroying the Stack](../README.md#destroying-the-stack) in the README.
After `terraform destroy`, also run `scripts/teardown-terraform-backend.sh`
to remove the Terraform state S3 bucket and DynamoDB table.

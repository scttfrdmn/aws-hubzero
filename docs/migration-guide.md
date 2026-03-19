# Migrating On-Prem HubZero to AWS

This guide covers migrating an existing on-premises HubZero deployment to the
AWS infrastructure in this project.

## Pre-Migration Checklist

- [ ] AWS deployment is running and healthy (ALB target group shows instance as
  healthy; see [README](../README.md) for deployment instructions)
- [ ] SSH or SCP access from the AWS instance to the on-prem server
- [ ] On-prem HubZero version is v2.4 (or migration SQL adjustments are planned)
- [ ] Sufficient disk space: on EFS (`/var/www/hubzero`) for app files, and
  `/tmp` for the database dump
- [ ] Maintenance window scheduled and users notified
- [ ] DNS TTL lowered to 300 seconds at least 24 hours before cutover

### What Gets Migrated

| Component | Method | Notes |
|---|---|---|
| MariaDB database | `mysqldump` → import | All users, content, config, CMS data |
| App files (`app/`) | `rsync` | Uploads, custom extensions, templates, project files |
| Configuration | Automated rewrite | DB host and credentials updated by the script |
| Solr search index | Rebuilt from DB | Faster and more reliable than transferring |

### What Needs Manual Attention After Migration

| Component | Action Required |
|---|---|
| **DNS** | Point A/CNAME to the ALB DNS name (not the EC2 IP — the instance may be replaced by the ASG) |
| **TLS** | Handled by ACM on the ALB automatically — no certbot needed |
| **SMTP/Email** | Configure SES or update SMTP settings in hub config |
| **LDAP/SSO** | Update authentication config to reach identity providers from AWS |
| **Tool sessions** | Export/import Docker images if using the full Platform (`install_platform=true`) |
| **Custom cron jobs** | Recreate system-level cron jobs not managed by HubZero |

### DNS cutover note

With this deployment, the load balancer DNS name (e.g.
`hubzero-prod-xxxx.us-east-1.elb.amazonaws.com`) is the target for your
CNAME — not an EC2 IP address. The Auto Scaling Group may replace the EC2
instance at any time (e.g. during SSM Patch Manager maintenance), so do not
use the instance's IP.

If you provisioned an ACM certificate with `domain_name` set, the ALB already
serves HTTPS. Update your DNS CNAME record to point to the `alb_dns_name`
output value.

---

## Running the Migration

### 1. Connect to the AWS instance via SSM

There is no SSH port. Use SSM Session Manager:

```bash
# Use the ssm_connect_command from your Terraform/CDK output, or:
aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=<asg-name>" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text \
  | xargs -I{} aws ssm start-session --target {}
```

Replace `<asg-name>` with the `asg_name` / `AsgName` output from your deploy.

### 2. Ensure SSH connectivity from the AWS instance to on-prem

The migration script runs on the AWS instance and pulls data from the on-prem
server over SSH. If your on-prem server is not publicly reachable, you will
need to set up a bastion or VPN.

```bash
# From within the SSM session on the AWS instance:
ssh -i /path/to/key user@onprem-server hostname
```

If you have no direct path, use the S3 bucket as an intermediary (see
[Manual migration via S3](#manual-migration-via-s3) below).

### 3. Run the migration script

```bash
sudo bash /var/www/hubzero-aws/scripts/migrate.sh \
  <on-prem-host> [ssh-user] [ssh-key-path]
```

Example:

```bash
sudo bash /var/www/hubzero-aws/scripts/migrate.sh \
  hub.example.edu root ~/.ssh/onprem_key
```

The script:

1. Puts the source hub into maintenance mode
2. Dumps the database with `mysqldump` over SSH
3. Transfers the dump to the AWS instance
4. Imports into RDS (or local MariaDB if `use_rds=false`)
5. Rsyncs the `app/` directory (uploads, extensions, config) to EFS
6. Rewrites database connection settings for the new environment
7. Rebuilds the Solr search index (if `install_platform=true`)
8. Restarts Apache and PHP-FPM

Progress is logged to `/var/log/hubzero-migration.log`.

### 4. Verify before switching DNS

Test the migrated site using a hosts-file override on your local machine
(bypasses DNS; talks directly to the ALB):

```bash
# Get the ALB's IP (will change over time — use only for testing)
dig +short <alb-dns-name>
# e.g. dig +short hubzero-prod-xxxx.us-east-1.elb.amazonaws.com

# Add to /etc/hosts (macOS/Linux) or
# C:\Windows\System32\drivers\etc\hosts (Windows):
<alb-ip>  hub.example.edu
```

Verify:

- [ ] Homepage loads over HTTPS with a valid certificate
- [ ] You can log in with an existing account
- [ ] Uploaded files and images are accessible (served from EFS / S3)
- [ ] Search returns results (index rebuild may take a few minutes)
- [ ] Admin panel accessible

Remove the hosts-file entry after testing.

### 5. Switch DNS

Update your DNS provider to point the hub domain to the ALB DNS name:

```
hub.example.edu.  CNAME  hubzero-prod-xxxx.us-east-1.elb.amazonaws.com.
```

Do not use an A record pointing to the EC2 IP — the ASG may replace the
instance. An A record works for testing but is not safe for production.

DNS propagation with a 300-second TTL takes 5–10 minutes globally.

### 6. Post-migration tasks

**Configure email (SES recommended):**

```bash
# In the HubZero admin panel:
# Admin → Global Configuration → Mail Settings
# Or edit app/config/mail.php

# To use SES:
# 1. Verify your domain in SES
# 2. Request production access (to send to non-verified addresses)
# 3. Create SMTP credentials in SES
# 4. Update mail settings: SMTP host = email-smtp.us-east-1.amazonaws.com, port 587
```

**Migrate tool session Docker images (if using full Platform):**

```bash
# On the on-prem server — save and compress the image
docker save <image-name> | gzip > tool-image.tar.gz

# Upload to the S3 bucket provisioned by this project
aws s3 cp tool-image.tar.gz s3://<s3-bucket-name>/tool-images/

# In the SSM session on the AWS instance — download and load
aws s3 cp s3://<s3-bucket-name>/tool-images/tool-image.tar.gz /tmp/
docker load < /tmp/tool-image.tar.gz
```

**Remove or disable the on-prem server** once the migration is verified and
DNS has propagated. The migration script does not modify the source server
(except to temporarily set maintenance mode), so it is safe to keep running
in parallel for a rollback window.

---

## Manual Migration via S3

If direct SSH from AWS to on-prem is not available, use S3 as an intermediary:

```bash
# On the on-prem server — dump and upload
mysqldump -u root hubzero | gzip | \
  aws s3 cp - s3://<s3-bucket>/migration/hubzero-db.sql.gz

rsync -az --delete /var/www/html/app/ /tmp/hubzero-app-snapshot/
tar czf - /tmp/hubzero-app-snapshot/ | \
  aws s3 cp - s3://<s3-bucket>/migration/hubzero-app.tar.gz

# On the AWS instance (via SSM session) — download and import
aws s3 cp s3://<s3-bucket>/migration/hubzero-db.sql.gz /tmp/
gunzip < /tmp/hubzero-db.sql.gz | \
  mysql -h "${HUBZERO_DB_HOST}" -u "${HUBZERO_DB_USER}" \
        -p"${HUBZERO_DB_PASS}" "${HUBZERO_DB_NAME}"

aws s3 cp s3://<s3-bucket>/migration/hubzero-app.tar.gz /tmp/
tar xzf /tmp/hubzero-app.tar.gz -C /var/www/hubzero/app/
chown -R apache:apache /var/www/hubzero/app/
```

The credentials file at `/root/.hubzero-credentials` contains the DB
host, name, user, and password (or Secrets Manager ARN) for use in the
import commands above.

---

## Rollback

The migration script only reads from the on-prem server (except maintenance
mode). If anything goes wrong:

1. Revert DNS to the on-prem server's address.
2. Clear the maintenance mode on the on-prem server if it was set.
3. The database dump is preserved at `/root/hubzero-migration-<timestamp>/`
   on the AWS instance for post-mortem analysis.

The AWS deployment is unaffected by a DNS rollback — you can re-attempt the
migration after addressing any issues.

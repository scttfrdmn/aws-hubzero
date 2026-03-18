# Migrating On-Prem HubZero to AWS

This guide covers migrating an existing on-premises HubZero deployment to the AWS infrastructure in this project.

## Pre-Migration Checklist

- [ ] AWS deployment is running and accessible (see main [README](../README.md))
- [ ] SSH access from the AWS instance to the on-prem server (or vice versa)
- [ ] On-prem HubZero version matches target (v2.4)
- [ ] Sufficient disk space on the AWS instance for the database dump + app files
- [ ] Notify users of the planned maintenance window

### What Gets Migrated

| Component | Method | Notes |
|-----------|--------|-------|
| MariaDB database | `mysqldump` → import | Users, content, config, all CMS data |
| App files (`app/`) | `rsync` | Uploads, custom extensions, templates, project files |
| Configuration | Automated rewrite | Database host, credentials updated by script |
| Solr search index | Rebuilt from DB | Faster than transferring the index |

### What Needs Manual Attention

| Component | Action Required |
|-----------|----------------|
| DNS | Update A/CNAME record to point to AWS instance IP |
| SSL/TLS | Automatic via certbot if `domain_name` is set during bootstrap; otherwise provision manually |
| SMTP/Email | Configure SES or update SMTP settings in hub config |
| LDAP/SSO | Update authentication config to reach identity providers from AWS |
| Tool sessions | Export/import Docker images if using full Platform |
| Custom cron jobs | Recreate any system-level cron jobs not managed by HubZero |

## Running the Migration

### 1. Ensure SSH connectivity

The migration script runs on the AWS instance and pulls data from the on-prem server via SSH.

```bash
# From the AWS instance, verify you can reach the on-prem server
ssh -i /path/to/key user@onprem-server hostname
```

### 2. Run the migration script

```bash
# Connect to the AWS instance via SSM Session Manager
aws ssm start-session --target <instance-id>

sudo /var/www/hubzero-aws/scripts/migrate.sh <on-prem-host> [ssh-user] [ssh-key]
```

Example:

```bash
sudo /var/www/hubzero-aws/scripts/migrate.sh hub.example.edu root ~/.ssh/onprem_key
```

The script will:

1. Set maintenance mode on the source
2. Dump and transfer the database
3. Import the database (local MariaDB or RDS)
4. Rsync the `app/` directory (uploads, extensions, config)
5. Update database connection settings for the new environment
6. Rebuild the Solr search index
7. Restart Apache and PHP-FPM

Progress is logged to `/var/log/hubzero-migration.log`.

### 3. Verify before switching DNS

Test the migrated site by adding a hosts-file entry on your local machine:

```bash
# /etc/hosts (macOS/Linux) or C:\Windows\System32\drivers\etc\hosts
<aws-public-ip>  hub.example.edu
```

Browse to `http://hub.example.edu` and verify:

- [ ] Homepage loads
- [ ] You can log in with an existing account
- [ ] Uploaded content and files are accessible
- [ ] Search returns results (may take a few minutes after re-index)

### 4. Switch DNS

Update your DNS provider to point the hub's domain to the AWS instance public IP (or ALB if applicable). TTL should be lowered ahead of time to speed propagation.

### 5. Post-migration tasks

- Configure SMTP (SES recommended for AWS):
  ```bash
  # In the hub admin panel: Admin → Global Configuration → Mail
  # Or edit app/config/mail.php
  ```
- Set up SSL manually only if certbot did not run during bootstrap (i.e. no `domain_name` was set at deploy time):
  ```bash
  sudo certbot --apache -d hub.example.edu
  ```
- Migrate tool session Docker images if using the full Platform:
  ```bash
  # On source — save and compress the image
  docker save <image> | gzip > tool-image.tar.gz

  # Transfer to AWS instance via SSM + S3 (SSH is not exposed):
  aws s3 cp tool-image.tar.gz s3://<your-bucket>/tool-image.tar.gz

  # On target (via SSM session):
  aws s3 cp s3://<your-bucket>/tool-image.tar.gz /tmp/tool-image.tar.gz
  docker load < /tmp/tool-image.tar.gz
  ```
- Remove the maintenance flag on the on-prem server or decommission it

## Rollback

If something goes wrong, the original on-prem server is untouched (the script only reads from it). Simply revert DNS back to the on-prem IP.

The migration backup (database dump) is stored on the AWS instance at `/root/hubzero-migration-<timestamp>/`.

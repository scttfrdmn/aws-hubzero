#!/usr/bin/env bash
# HubZero Platform launch-time bootstrap for Amazon Linux 2023 on EC2
# Handles env-specific configuration only; static software installs are
# pre-baked into the AMI via scripts/bake.sh (Packer).
# When using the base AL2023 AMI (use_baked_ami=false), bake.sh is prepended
# to this script by the Terraform/CDK launcher.
set -euo pipefail

exec > >(tee /var/log/hubzero-userdata.log) 2>&1
chmod 600 /var/log/hubzero-userdata.log

# IMDSv2 token-based metadata retrieval
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
imds_get() {
  curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
    "http://169.254.169.254/latest/meta-data/$1"
}
AWS_REGION=$(imds_get placement/region)

###############################################################################
# 0. Optional: source configuration from SSM Parameter Store
###############################################################################
HUBZERO_ENABLE_PARAMETER_STORE="${HUBZERO_ENABLE_PARAMETER_STORE:-false}"
HUBZERO_ENVIRONMENT="${HUBZERO_ENVIRONMENT:-}"

if [ "${HUBZERO_ENABLE_PARAMETER_STORE}" = "true" ] && [ -n "${HUBZERO_ENVIRONMENT}" ]; then
    echo "=== Sourcing configuration from SSM Parameter Store ==="
    SSM_PATH="/hubzero/${HUBZERO_ENVIRONMENT}"
    if aws ssm get-parameters-by-path \
          --region "${AWS_REGION}" \
          --path "${SSM_PATH}" \
          --with-decryption \
          --query 'Parameters[*].[Name,Value]' \
          --output text 2>/dev/null | \
        while IFS=$'\t' read -r name value; do
            key="${name##*/}"
            # Map SSM parameter names to env vars
            case "${key}" in
                domain_name)      export HUBZERO_DOMAIN="${value}" ;;
                db_host)          export HUBZERO_DB_HOST="${value}" ;;
                db_name)          export HUBZERO_DB_NAME="${value}" ;;
                db_user)          export HUBZERO_DB_USER="${value}" ;;
                s3_bucket)        export HUBZERO_S3_BUCKET="${value}" ;;
                enable_monitoring) export HUBZERO_ENABLE_MONITORING="${value}" ;;
                cw_log_prefix)    export HUBZERO_CW_LOG_GROUP_PREFIX="${value}" ;;
            esac
        done; then
        echo "=== SSM Parameter Store sourced successfully ==="
    else
        echo "WARNING: SSM Parameter Store sourcing failed — using env var fallbacks"
    fi
fi

# Environment variable defaults (override with Terraform/CDK exports or SSM values above)
HUBZERO_DOMAIN="${HUBZERO_DOMAIN:-$(imds_get public-ipv4)}"
HUBZERO_DB_HOST="${HUBZERO_DB_HOST:-localhost}"
HUBZERO_DB_NAME="${HUBZERO_DB_NAME:-hubzero}"
HUBZERO_DB_USER="${HUBZERO_DB_USER:-hubzero}"
HUBZERO_USE_RDS="${HUBZERO_USE_RDS:-false}"
HUBZERO_INSTALL_PLATFORM="${HUBZERO_INSTALL_PLATFORM:-false}"
HUBZERO_CERTBOT_EMAIL="${HUBZERO_CERTBOT_EMAIL:-}"
HUBZERO_ENABLE_MONITORING="${HUBZERO_ENABLE_MONITORING:-false}"
HUBZERO_CW_LOG_GROUP_PREFIX="${HUBZERO_CW_LOG_GROUP_PREFIX:-/aws/ec2/hubzero}"
HUBZERO_S3_BUCKET="${HUBZERO_S3_BUCKET:-}"
HUBZERO_ENABLE_ALB="${HUBZERO_ENABLE_ALB:-false}"

# Retrieve DB password: from Secrets Manager if ARN provided, else generate locally
HUBZERO_DB_SECRET_ARN="${HUBZERO_DB_SECRET_ARN:-}"
{
    if [ -n "${HUBZERO_DB_SECRET_ARN}" ]; then
        HUBZERO_DB_PASS=$(aws secretsmanager get-secret-value \
          --region "${AWS_REGION}" \
          --secret-id "${HUBZERO_DB_SECRET_ARN}" \
          --query 'SecretString' --output text | \
          python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")
    else
        HUBZERO_DB_PASS="${HUBZERO_DB_PASS:-$(openssl rand -base64 24)}"
    fi
} 2>/dev/null

echo "=== HubZero bootstrap started at $(date) ==="
echo "Domain: ${HUBZERO_DOMAIN}"
echo "Database host: ${HUBZERO_DB_HOST}"
echo "Use RDS: ${HUBZERO_USE_RDS}"
echo "Install full platform: ${HUBZERO_INSTALL_PLATFORM}"

###############################################################################
# 1. Start baked services (fail2ban, httpd, php-fpm are already installed/enabled
#    by bake.sh; just start them here with current config)
###############################################################################
systemctl start fail2ban || true
systemctl start php-fpm  || true
systemctl start httpd    || true

###############################################################################
# 2a. TLS via certbot (if domain is set, not an IP, and ALB is not handling TLS)
###############################################################################
if [[ "${HUBZERO_ENABLE_ALB}" != "true" && -n "${HUBZERO_DOMAIN}" && ! "${HUBZERO_DOMAIN}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    dnf -y install certbot python3-certbot-apache

    CERTBOT_EMAIL_OPTS="--register-unsafely-without-email"
    if [ -n "${HUBZERO_CERTBOT_EMAIL}" ]; then
        CERTBOT_EMAIL_OPTS="--email ${HUBZERO_CERTBOT_EMAIL} --no-eff-email"
    fi

    # shellcheck disable=SC2086
    certbot --apache --non-interactive --agree-tos \
      ${CERTBOT_EMAIL_OPTS} \
      -d "${HUBZERO_DOMAIN}" || \
      echo "WARNING: certbot failed — TLS not configured. Set up manually."

    if [ -f /etc/httpd/conf.d/hubzero-le-ssl.conf ]; then
        if ! grep -q "Strict-Transport-Security" /etc/httpd/conf.d/hubzero-le-ssl.conf; then
            sed -i '/<\/VirtualHost>/i \    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains"' \
              /etc/httpd/conf.d/hubzero-le-ssl.conf
        fi
        if ! grep -q "Strict-Transport-Security" /etc/httpd/conf.d/hubzero-le-ssl.conf; then
            echo "WARNING: Failed to inject HSTS into SSL vhost. Add manually."
        fi
    fi

    echo "0 3 * * * root certbot renew --deploy-hook 'systemctl reload httpd' 2>&1 | logger -t certbot-renew" > /etc/cron.d/certbot-renew
    chmod 644 /etc/cron.d/certbot-renew
fi

###############################################################################
# 3. MariaDB 10.11 (local install, skipped when using RDS)
###############################################################################
if [ "${HUBZERO_USE_RDS}" = "true" ]; then
    echo "=== Skipping local MariaDB install (using RDS at ${HUBZERO_DB_HOST}) ==="
else
    # AL2023: MariaDB community repo (bake.sh installs client; add server here)
    if ! systemctl is-active --quiet mariadb; then
        # MariaDB repo already configured by bake.sh
        dnf install -y MariaDB-server
        systemctl enable --now mariadb
    fi

    {
        mysql -e "CREATE DATABASE IF NOT EXISTS \`${HUBZERO_DB_NAME}\`;"
        mysql -e "CREATE USER IF NOT EXISTS '${HUBZERO_DB_USER}'@'localhost' IDENTIFIED BY '${HUBZERO_DB_PASS}';"
        mysql -e "GRANT ALL PRIVILEGES ON \`${HUBZERO_DB_NAME}\`.* TO '${HUBZERO_DB_USER}'@'localhost';"
        mysql -e "FLUSH PRIVILEGES;"
    } 2>/dev/null
    echo "=== Local MariaDB configured ==="
fi

###############################################################################
# 6. Full Platform components (optional)
###############################################################################
SOLR_IMAGE="solr:9.7@sha256:a09daa1b5960b5cb2b590218baf733b6c7a95b29be29ae066421079c5ea9b987"
if [ "${HUBZERO_INSTALL_PLATFORM}" = "true" ]; then
    echo "=== Installing full HubZero Platform components ==="

    dnf -y install dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf -y install docker-ce docker-ce-cli containerd.io

    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'DOCKERCONF'
{
  "userns-remap": "default"
}
DOCKERCONF
    systemctl enable --now docker

    docker pull "${SOLR_IMAGE}"
    docker run -d --name hubzero-solr --restart unless-stopped \
        --memory=1g --cpus=1.0 \
        --read-only \
        --tmpfs /tmp \
        -v hubzero-solr-data:/var/solr:rw \
        -p 127.0.0.1:8983:8983 "${SOLR_IMAGE}" solr-precreate hubzero
fi

###############################################################################
# 7. Store credential reference
###############################################################################
{
    umask 077
    echo "HUBZERO_DB_HOST=${HUBZERO_DB_HOST}"
    echo "HUBZERO_DB_NAME=${HUBZERO_DB_NAME}"
    echo "HUBZERO_DB_USER=${HUBZERO_DB_USER}"
    echo "HUBZERO_DB_SECRET_ARN=${HUBZERO_DB_SECRET_ARN}"
    echo "HUBZERO_S3_BUCKET=${HUBZERO_S3_BUCKET}"
    if [ "${HUBZERO_USE_RDS}" != "true" ]; then
        echo "HUBZERO_DB_PASS=${HUBZERO_DB_PASS}"
    fi
} > /root/.hubzero-credentials 2>/dev/null
# NOTE: HubZero S3 filesystem adapter config is required to use the S3 bucket.
# Configure the HubZero filesystem plugin to point to HUBZERO_S3_BUCKET.
chmod 600 /root/.hubzero-credentials

###############################################################################
# 8. Firewall
###############################################################################
if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
fi

###############################################################################
# 9. CloudWatch Agent (optional; binary already installed by bake.sh)
###############################################################################
if [ "${HUBZERO_ENABLE_MONITORING}" = "true" ]; then
    echo "=== Configuring CloudWatch Agent ==="

    CW_LG_USERDATA="${HUBZERO_CW_LOG_GROUP_PREFIX}/userdata"
    CW_LG_APACHE_ACCESS="${HUBZERO_CW_LOG_GROUP_PREFIX}/apache-access"
    CW_LG_APACHE_ERROR="${HUBZERO_CW_LOG_GROUP_PREFIX}/apache-error"

    cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<CWCONF
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "root"
  },
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": {
      "InstanceId": "\${aws:InstanceId}"
    },
    "metrics_collected": {
      "mem": {
        "measurement": ["mem_used_percent"]
      },
      "disk": {
        "measurement": ["disk_used_percent"],
        "resources": ["/"]
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/hubzero-userdata.log",
            "log_group_name": "${CW_LG_USERDATA}",
            "log_stream_name": "\${aws:InstanceId}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/httpd/hubzero-access.log",
            "log_group_name": "${CW_LG_APACHE_ACCESS}",
            "log_stream_name": "\${aws:InstanceId}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/httpd/hubzero-error.log",
            "log_group_name": "${CW_LG_APACHE_ERROR}",
            "log_stream_name": "\${aws:InstanceId}",
            "timezone": "UTC"
          }
        ]
      }
    }
  }
}
CWCONF

    amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 \
      -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s
    echo "=== CloudWatch Agent started ==="
fi

echo "=== HubZero bootstrap completed at $(date) ==="

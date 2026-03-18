#!/usr/bin/env bash
# HubZero Platform bootstrap for Rocky Linux 8 on EC2
# Installs: Apache 2.4, PHP 8.2, (optionally) MariaDB 10.11, HubZero CMS v2.4
set -euo pipefail

# Separate log for sensitive operations (not logged)
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

HUBZERO_DOMAIN="${HUBZERO_DOMAIN:-$(imds_get public-ipv4)}"
HUBZERO_DB_HOST="${HUBZERO_DB_HOST:-localhost}"
HUBZERO_DB_NAME="${HUBZERO_DB_NAME:-hubzero}"
HUBZERO_DB_USER="${HUBZERO_DB_USER:-hubzero}"
HUBZERO_USE_RDS="${HUBZERO_USE_RDS:-false}"
HUBZERO_INSTALL_PLATFORM="${HUBZERO_INSTALL_PLATFORM:-false}"
HUBZERO_CERTBOT_EMAIL="${HUBZERO_CERTBOT_EMAIL:-}"

# Retrieve DB password: from Secrets Manager if ARN provided, else generate locally
HUBZERO_DB_SECRET_ARN="${HUBZERO_DB_SECRET_ARN:-}"
{
    # Credential retrieval in a subshell — output not sent to main log
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
# 1. System updates & base packages
###############################################################################
dnf -y update
dnf -y install epel-release
dnf -y install vim wget curl unzip git tar policycoreutils-python-utils \
  cronie logrotate jq fail2ban

###############################################################################
# 1a. fail2ban (apache jails only — SSH port is not exposed)
###############################################################################
cat > /etc/fail2ban/jail.local <<'F2BCONF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[apache-auth]
enabled  = true
port     = http,https
logpath  = /var/log/httpd/*error*log

[apache-badbots]
enabled  = true
port     = http,https
logpath  = /var/log/httpd/*access*log
F2BCONF
systemctl enable --now fail2ban

###############################################################################
# 2. Apache 2.4
###############################################################################
dnf -y install httpd mod_ssl mod_headers
systemctl enable --now httpd

# Shared security headers (loaded by both HTTP and HTTPS vhosts)
# NOTE: CSP uses unsafe-inline/unsafe-eval for script-src because HubZero's
# legacy JS requires it. Track https://github.com/hubzero/hubzero-cms/issues
# for future nonce-based CSP migration.
cat > /etc/httpd/conf.d/security-headers.conf <<'HEADERSCONF'
ServerTokens Prod
ServerSignature Off
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "SAMEORIGIN"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
Header always set Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'self'"
Header always set Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()"
Header always set X-Permitted-Cross-Domain-Policies "none"
HEADERSCONF

cat > /etc/httpd/conf.d/hubzero.conf <<'APACHECONF'
<VirtualHost *:80>
    DocumentRoot /var/www/hubzero/public
    <Directory /var/www/hubzero/public>
        Options -Indexes +SymLinksIfOwnerMatch
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog  /var/log/httpd/hubzero-error.log
    CustomLog /var/log/httpd/hubzero-access.log combined
</VirtualHost>
APACHECONF

###############################################################################
# 2a. TLS via certbot (if domain is set and not an IP)
###############################################################################
if [[ -n "${HUBZERO_DOMAIN}" && ! "${HUBZERO_DOMAIN}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
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

    # Add HSTS to the SSL vhost created by certbot and verify
    if [ -f /etc/httpd/conf.d/hubzero-le-ssl.conf ]; then
        if ! grep -q "Strict-Transport-Security" /etc/httpd/conf.d/hubzero-le-ssl.conf; then
            sed -i '/<\/VirtualHost>/i \    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains"' \
              /etc/httpd/conf.d/hubzero-le-ssl.conf
        fi
        if ! grep -q "Strict-Transport-Security" /etc/httpd/conf.d/hubzero-le-ssl.conf; then
            echo "WARNING: Failed to inject HSTS into SSL vhost. Add manually."
        fi
    fi

    # Auto-renew via cron — log errors, reload Apache on success
    echo "0 3 * * * root certbot renew --deploy-hook 'systemctl reload httpd' 2>&1 | logger -t certbot-renew" > /etc/cron.d/certbot-renew
    chmod 644 /etc/cron.d/certbot-renew
fi

###############################################################################
# 3. MariaDB 10.11 (local install, skipped when using RDS)
###############################################################################
if [ "${HUBZERO_USE_RDS}" = "true" ]; then
    echo "=== Skipping local MariaDB install (using RDS at ${HUBZERO_DB_HOST}) ==="
    dnf -y install mariadb
else
    dnf -y module reset mariadb
    dnf -y module install mariadb:10.11/server
    systemctl enable --now mariadb

    # Credential operations not logged
    {
        mysql -e "CREATE DATABASE IF NOT EXISTS \`${HUBZERO_DB_NAME}\`;"
        mysql -e "CREATE USER IF NOT EXISTS '${HUBZERO_DB_USER}'@'localhost' IDENTIFIED BY '${HUBZERO_DB_PASS}';"
        mysql -e "GRANT ALL PRIVILEGES ON \`${HUBZERO_DB_NAME}\`.* TO '${HUBZERO_DB_USER}'@'localhost';"
        mysql -e "FLUSH PRIVILEGES;"
    } 2>/dev/null
    echo "=== Local MariaDB configured ==="
fi

###############################################################################
# 4. PHP 8.2
###############################################################################
dnf -y module reset php
dnf -y module install php:8.2
dnf -y install php php-cli php-common php-mysqlnd php-xml php-mbstring \
  php-json php-gd php-curl php-zip php-intl php-ldap php-opcache php-soap

cat > /etc/php.d/99-hubzero.ini <<'PHPINI'
upload_max_filesize = 128M
post_max_size = 128M
memory_limit = 256M
max_execution_time = 120
date.timezone = UTC
expose_php = Off
session.cookie_httponly = On
session.cookie_secure = On
session.cookie_samesite = Lax
PHPINI

systemctl enable --now php-fpm
systemctl restart httpd

###############################################################################
# 5. HubZero CMS v2.4 (Composer-based install)
###############################################################################
# Install Composer with hash verification
EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
    echo "ERROR: Composer installer checksum mismatch" >&2
    rm composer-setup.php
    exit 1
fi
php composer-setup.php --install-dir=/usr/local/bin --filename=composer
rm composer-setup.php

mkdir -p /var/www/hubzero
chown apache:apache /var/www/hubzero
cd /var/www/hubzero

# Clone pinned release at a specific commit and install as the apache user
HUBZERO_COMMIT="${HUBZERO_COMMIT:-}"
if [ ! -f composer.json ]; then
    sudo -u apache git clone --branch 2.4 \
      https://github.com/hubzero/hubzero-cms.git .
    if [ -n "${HUBZERO_COMMIT}" ]; then
        sudo -u apache git checkout "${HUBZERO_COMMIT}"
    fi
    sudo -u apache composer install --no-dev --no-scripts --optimize-autoloader
fi

chown -R apache:apache /var/www/hubzero
chmod -R 755 /var/www/hubzero

# Restrict config files to owner-only read (defense-in-depth)
if [ -d /var/www/hubzero/app/config ]; then
    chmod 750 /var/www/hubzero/app/config
    chmod 640 /var/www/hubzero/app/config/*.php 2>/dev/null || true
fi

###############################################################################
# 6. Full Platform components (optional)
###############################################################################
SOLR_IMAGE="solr:9.7@sha256:a09daa1b5960b5cb2b590218baf733b6c7a95b29be29ae066421079c5ea9b987"
if [ "${HUBZERO_INSTALL_PLATFORM}" = "true" ]; then
    echo "=== Installing full HubZero Platform components ==="

    # Docker with user namespace remapping
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

    # Solr bound to localhost only, with resource limits and read-only filesystem
    docker pull "${SOLR_IMAGE}"
    docker run -d --name hubzero-solr --restart unless-stopped \
        --memory=1g --cpus=1.0 \
        --read-only \
        --tmpfs /tmp \
        -v hubzero-solr-data:/var/solr:rw \
        -p 127.0.0.1:8983:8983 "${SOLR_IMAGE}" solr-precreate hubzero
fi

###############################################################################
# 7. Store credential reference (includes local DB password when not using RDS)
###############################################################################
{
    umask 077
    echo "HUBZERO_DB_HOST=${HUBZERO_DB_HOST}"
    echo "HUBZERO_DB_NAME=${HUBZERO_DB_NAME}"
    echo "HUBZERO_DB_USER=${HUBZERO_DB_USER}"
    echo "HUBZERO_DB_SECRET_ARN=${HUBZERO_DB_SECRET_ARN}"
    if [ "${HUBZERO_USE_RDS}" != "true" ]; then
        echo "HUBZERO_DB_PASS=${HUBZERO_DB_PASS}"
    fi
} > /root/.hubzero-credentials 2>/dev/null
chmod 600 /root/.hubzero-credentials

###############################################################################
# 8. Firewall
###############################################################################
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
fi

echo "=== HubZero bootstrap completed at $(date) ==="

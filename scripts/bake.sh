#!/usr/bin/env bash
# HubZero AMI bake script — runs inside Packer during image build
# Installs all static packages and configuration; does NOT configure
# environment-specific settings (those are done at launch by userdata.sh).
set -euo pipefail

exec > >(tee /var/log/hubzero-bake.log) 2>&1
echo "=== HubZero bake started at $(date) ==="

###############################################################################
# 1. System updates & base packages
###############################################################################
dnf -y update
# AL2023 ships curl-minimal; --allowerasing replaces it with full curl.
dnf -y install --allowerasing vim wget curl unzip git tar \
  policycoreutils-python-utils cronie logrotate jq fail2ban \
  amazon-cloudwatch-agent

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
systemctl enable fail2ban

###############################################################################
# 2. Apache 2.4
###############################################################################
dnf -y install httpd mod_ssl
# mod_headers is included in httpd on AL2023 — no separate package needed
systemctl enable httpd

# Shared security headers
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
# 3. MariaDB client (server install is skipped at bake time —
#    either RDS is used or MariaDB server is installed at launch)
# AL2023 ships mariadb105 natively; no community repo needed for client-only.
###############################################################################
dnf install -y mariadb105

###############################################################################
# 4. PHP 8.2
###############################################################################
# AL2023: versioned PHP packages
dnf -y install php8.2 php8.2-cli php8.2-common php8.2-mysqlnd php8.2-xml \
  php8.2-mbstring php8.2-gd php8.2-zip php8.2-intl \
  php8.2-ldap php8.2-opcache php8.2-soap php8.2-fpm
# json is built into PHP 8.2 core; curl extension is bundled in php8.2-common

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

systemctl enable php-fpm

###############################################################################
# 5. HubZero CMS v2.4 (Composer-based install)
###############################################################################
# Ensure HOME is set — cloud-init may run with a minimal environment
export HOME="${HOME:-/root}"
export COMPOSER_HOME="${COMPOSER_HOME:-/root/.composer}"
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

if [ ! -f composer.json ]; then
    sudo -u apache git clone --branch 2.4-main \
      https://github.com/hubzero/hubzero-cms.git .
    sudo -u apache composer install --no-dev --no-scripts --optimize-autoloader
fi

chown -R apache:apache /var/www/hubzero
chmod -R 755 /var/www/hubzero

if [ -d /var/www/hubzero/app/config ]; then
    chmod 750 /var/www/hubzero/app/config
    chmod 640 /var/www/hubzero/app/config/*.php 2>/dev/null || true
fi

echo "=== HubZero bake completed at $(date) ==="

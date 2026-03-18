#!/usr/bin/env bash
# Migrate an on-prem HubZero deployment to an AWS instance.
# Run this script FROM the AWS target instance.
#
# Usage:
#   sudo ./migrate.sh <source-host> [ssh-user] [ssh-key]
#
# Example:
#   sudo ./migrate.sh onprem.example.edu rocky ~/.ssh/onprem_key
set -euo pipefail
exec > >(tee /var/log/hubzero-migration.log) 2>&1
chmod 600 /var/log/hubzero-migration.log

SOURCE_HOST="${1:?Usage: $0 <source-host> [ssh-user] [ssh-key]}"
SSH_USER="${2:-root}"
SSH_KEY="${3:-}"
SSH_OPTS=""
[ -n "${SSH_KEY}" ] && SSH_OPTS="-i ${SSH_KEY}"

HUBZERO_DIR="/var/www/hubzero"
BACKUP_DIR="/root/hubzero-migration-$(date +%Y%m%d-%H%M%S)"
DB_DUMP="${BACKUP_DIR}/hubzero-db.sql"

# Temp files to clean up on exit
MYSQL_CNF=""
cleanup() {
    [ -n "${MYSQL_CNF}" ] && rm -f "${MYSQL_CNF}"
}
trap cleanup EXIT INT TERM

# Load credential references
# shellcheck source=/dev/null
source /root/.hubzero-credentials

# Retrieve DB password from Secrets Manager if using RDS
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
AWS_REGION=$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
  "http://169.254.169.254/latest/meta-data/placement/region")

if [ -n "${HUBZERO_DB_SECRET_ARN:-}" ]; then
    HUBZERO_DB_PASS=$(aws secretsmanager get-secret-value \
      --region "${AWS_REGION}" \
      --secret-id "${HUBZERO_DB_SECRET_ARN}" \
      --query 'SecretString' --output text | \
      python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")
fi

echo "=== HubZero migration started at $(date) ==="
echo "Source: ${SSH_USER}@${SOURCE_HOST}"
echo "Target DB host: ${HUBZERO_DB_HOST}"
mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

###############################################################################
# 0. Verify SSH host key (fail if unknown — do NOT skip verification)
###############################################################################
echo "=== Verifying SSH host key for ${SOURCE_HOST} ==="
if ! ssh-keygen -F "${SOURCE_HOST}" > /dev/null 2>&1; then
    echo "ERROR: Host key for ${SOURCE_HOST} not found in known_hosts."
    echo "Run: ssh-keyscan ${SOURCE_HOST} >> ~/.ssh/known_hosts"
    echo "Verify the fingerprint before proceeding."
    exit 1
fi

###############################################################################
# 1. Enable maintenance mode on source
###############################################################################
echo "=== Step 1: Enabling maintenance mode on source ==="
# shellcheck disable=SC2029,SC2086
ssh ${SSH_OPTS} "${SSH_USER}@${SOURCE_HOST}" \
  "touch ${HUBZERO_DIR}/app/maintenance.flag" || \
  echo "WARNING: Could not set maintenance mode. Continue manually if needed."

###############################################################################
# 2. Export database from source (HubZero database only)
###############################################################################
echo "=== Step 2: Exporting database from source ==="
# shellcheck disable=SC2029,SC2086
ssh ${SSH_OPTS} "${SSH_USER}@${SOURCE_HOST}" \
  "mysqldump --single-transaction --routines --triggers \
   ${HUBZERO_DB_NAME}" > "${DB_DUMP}"

chmod 600 "${DB_DUMP}"
echo "Database dump: $(du -h "${DB_DUMP}" | cut -f1)"

# Validate dump integrity — check for MySQL completion marker
if ! tail -1 "${DB_DUMP}" | grep -q "^-- Dump completed"; then
    echo "ERROR: Database dump appears truncated (missing completion marker)."
    echo "Check network connectivity and disk space on the source."
    exit 1
fi

###############################################################################
# 3. Import database to target
###############################################################################
echo "=== Step 3: Importing database ==="
if [ "${HUBZERO_DB_HOST}" = "localhost" ]; then
  mysql "${HUBZERO_DB_NAME}" < "${DB_DUMP}"
else
  # Use option file to avoid password in process list
  MYSQL_CNF=$(mktemp /tmp/.hubzero-mysql-XXXXXX.cnf)
  chmod 600 "${MYSQL_CNF}"
  cat > "${MYSQL_CNF}" <<MYCNF
[client]
host=${HUBZERO_DB_HOST}
user=${HUBZERO_DB_USER}
password=${HUBZERO_DB_PASS}
MYCNF
  mysql --defaults-extra-file="${MYSQL_CNF}" "${HUBZERO_DB_NAME}" < "${DB_DUMP}"
  rm -f "${MYSQL_CNF}"
  MYSQL_CNF=""
fi

###############################################################################
# 4. Sync application files
###############################################################################
echo "=== Step 4: Syncing application files ==="

# Back up target app directory before destructive rsync
if [ -d "${HUBZERO_DIR}/app" ]; then
    echo "Backing up existing app/ to ${BACKUP_DIR}/app-pre-sync/"
    cp -a "${HUBZERO_DIR}/app" "${BACKUP_DIR}/app-pre-sync/"
fi

RSYNC_SSH="ssh"
[ -n "${SSH_KEY}" ] && RSYNC_SSH="ssh -i ${SSH_KEY}"

rsync -az --delete \
  -e "${RSYNC_SSH}" \
  "${SSH_USER}@${SOURCE_HOST}:${HUBZERO_DIR}/app/" \
  "${HUBZERO_DIR}/app/"

chown -R apache:apache "${HUBZERO_DIR}/app"

###############################################################################
# 5. Update configuration for new environment
###############################################################################
echo "=== Step 5: Updating configuration ==="
CONFIG_FILE="${HUBZERO_DIR}/app/config/database.php"
if [ -f "${CONFIG_FILE}" ]; then
  {
      sed -i "s|'host'.*=>.*|'host' => '${HUBZERO_DB_HOST}',|" "${CONFIG_FILE}"
      sed -i "s|'user'.*=>.*|'user' => '${HUBZERO_DB_USER}',|" "${CONFIG_FILE}"
      sed -i "s|'password'.*=>.*|'password' => '${HUBZERO_DB_PASS}',|" "${CONFIG_FILE}"
  } 2>/dev/null
  chmod 640 "${CONFIG_FILE}"
  chown apache:apache "${CONFIG_FILE}"
  echo "Updated database.php"
fi

###############################################################################
# 6. Rebuild search index
###############################################################################
echo "=== Step 6: Rebuilding Solr search index ==="
if command -v php &>/dev/null && [ -f "${HUBZERO_DIR}/cli/muse.php" ]; then
  php "${HUBZERO_DIR}/cli/muse.php" search:rebuild || \
    echo "WARNING: Search rebuild failed. Run manually after migration."
fi

###############################################################################
# 7. Restart services
###############################################################################
echo "=== Step 7: Restarting services ==="
systemctl restart httpd php-fpm

###############################################################################
# 8. Remove maintenance flag on target
###############################################################################
rm -f "${HUBZERO_DIR}/app/maintenance.flag"

IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
  "http://169.254.169.254/latest/meta-data/public-ipv4")

echo ""
echo "=== HubZero migration completed at $(date) ==="
echo ""
echo "Next steps:"
echo "  1. Verify the site at http://${PUBLIC_IP}/"
echo "  2. Test with a hosts-file override before switching DNS"
echo "  3. Update DNS to point to this instance"
echo "  4. Remove maintenance mode on source: rm ${HUBZERO_DIR}/app/maintenance.flag"
echo "     (or decommission the source server)"
echo "  5. Migrate tool session Docker images if applicable"
echo "  6. Configure SES or other SMTP for outbound email"
echo ""
echo "Migration backup stored at: ${BACKUP_DIR}"

#!/usr/bin/env bash
# Teardown the Terraform S3 backend.
#
# Removes the S3 bucket and DynamoDB table created by bootstrap-terraform-backend.sh.
# Run this AFTER `terraform destroy` has been completed and you no longer need
# the state for this account/region.
#
# Safety checks:
#   - Verifies the Terraform state file is empty (no managed resources remain)
#   - Requires explicit confirmation unless --force is passed
#
# Usage:
#   ./scripts/teardown-terraform-backend.sh
#   ./scripts/teardown-terraform-backend.sh --force   # skip confirmation prompt
#
# Environment variables (must match bootstrap-terraform-backend.sh):
#   TF_STATE_BUCKET  S3 bucket name   (default: hubzero-terraform-state)
#   TF_LOCK_TABLE    DynamoDB table   (default: hubzero-terraform-locks)
#   AWS_REGION       AWS region       (default: us-east-1)
set -euo pipefail

BUCKET="${TF_STATE_BUCKET:-hubzero-terraform-state}"
TABLE="${TF_LOCK_TABLE:-hubzero-terraform-locks}"
REGION="${AWS_REGION:-us-east-1}"
FORCE="${1:-}"

echo "==> Terraform backend teardown"
echo "    Bucket : ${BUCKET}"
echo "    Table  : ${TABLE}"
echo "    Region : ${REGION}"
echo

# ---------------------------------------------------------------------------
# Safety check: ensure the state file contains no resources
# ---------------------------------------------------------------------------
STATE_KEY="hubzero/test/terraform.tfstate"
echo "==> Checking state file for live resources..."

STATE_JSON=$(aws s3 cp "s3://${BUCKET}/${STATE_KEY}" - \
  --region "${REGION}" 2>/dev/null || echo '{"resources":[]}')

RESOURCE_COUNT=$(echo "${STATE_JSON}" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(len([r for r in d.get('resources',[]) if r.get('type','') != 'data']))" \
  2>/dev/null || echo "unknown")

if [ "${RESOURCE_COUNT}" != "0" ] && [ "${RESOURCE_COUNT}" != "unknown" ]; then
  echo
  echo "ERROR: Terraform state still contains ${RESOURCE_COUNT} resource(s)."
  echo "       Run 'terraform destroy' first, then re-run this script."
  exit 1
fi

if [ "${RESOURCE_COUNT}" = "unknown" ]; then
  echo "    WARNING: Could not parse state file. Proceeding with caution."
else
  echo "    State is empty (${RESOURCE_COUNT} resources). Safe to remove backend."
fi

# ---------------------------------------------------------------------------
# Confirmation prompt
# ---------------------------------------------------------------------------
if [ "${FORCE}" != "--force" ]; then
  echo
  echo "This will permanently delete:"
  echo "  S3 bucket  : ${BUCKET} (including all state file versions)"
  echo "  DynamoDB   : ${TABLE}"
  echo
  read -r -p "Type 'yes' to confirm: " CONFIRM
  if [ "${CONFIRM}" != "yes" ]; then
    echo "Aborted."
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Delete all object versions in the state bucket, then the bucket itself
# ---------------------------------------------------------------------------
if aws s3api head-bucket --bucket "${BUCKET}" --region "${REGION}" 2>/dev/null; then
  echo "==> Emptying S3 bucket (versions + delete markers)..."

  # Delete versioned objects
  VERSIONS=$(aws s3api list-object-versions \
    --bucket "${BUCKET}" \
    --region "${REGION}" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    --output json 2>/dev/null)
  if [ "$(echo "${VERSIONS}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('Objects') or []))" 2>/dev/null)" != "0" ]; then
    aws s3api delete-objects --bucket "${BUCKET}" --region "${REGION}" \
      --delete "${VERSIONS}" > /dev/null
  fi

  # Delete delete-markers
  MARKERS=$(aws s3api list-object-versions \
    --bucket "${BUCKET}" \
    --region "${REGION}" \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
    --output json 2>/dev/null)
  if [ "$(echo "${MARKERS}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('Objects') or []))" 2>/dev/null)" != "0" ]; then
    aws s3api delete-objects --bucket "${BUCKET}" --region "${REGION}" \
      --delete "${MARKERS}" > /dev/null
  fi

  echo "==> Deleting S3 bucket: ${BUCKET}"
  aws s3api delete-bucket --bucket "${BUCKET}" --region "${REGION}"
  echo "    Done."
else
  echo "    S3 bucket '${BUCKET}' not found — skipping."
fi

# ---------------------------------------------------------------------------
# Delete DynamoDB table
# ---------------------------------------------------------------------------
if aws dynamodb describe-table \
     --table-name "${TABLE}" \
     --region "${REGION}" \
     --output text 2>/dev/null | grep -q ACTIVE; then
  echo "==> Deleting DynamoDB table: ${TABLE}"
  aws dynamodb delete-table \
    --table-name "${TABLE}" \
    --region "${REGION}" > /dev/null
  echo "    Done."
else
  echo "    DynamoDB table '${TABLE}' not found — skipping."
fi

echo
echo "==> Backend teardown complete."
echo "    To redeploy, run bootstrap-terraform-backend.sh followed by terraform init."

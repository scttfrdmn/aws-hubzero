#!/usr/bin/env bash
# Bootstrap the Terraform S3 backend.
#
# Creates the S3 bucket and DynamoDB table referenced in terraform/main.tf.
# Run this ONCE before the first `terraform init`. Safe to re-run — existing
# resources are detected and skipped.
#
# Usage:
#   ./scripts/bootstrap-terraform-backend.sh
#
# Environment variables (all optional, defaults match main.tf):
#   TF_STATE_BUCKET  S3 bucket name   (default: hubzero-terraform-state)
#   TF_LOCK_TABLE    DynamoDB table   (default: hubzero-terraform-locks)
#   AWS_REGION       AWS region       (default: us-east-1)
set -euo pipefail

BUCKET="${TF_STATE_BUCKET:-hubzero-terraform-state}"
TABLE="${TF_LOCK_TABLE:-hubzero-terraform-locks}"
REGION="${AWS_REGION:-us-east-1}"

echo "==> Terraform backend bootstrap"
echo "    Bucket : ${BUCKET}"
echo "    Table  : ${TABLE}"
echo "    Region : ${REGION}"
echo

# ---------------------------------------------------------------------------
# S3 bucket
# ---------------------------------------------------------------------------
if aws s3api head-bucket --bucket "${BUCKET}" --region "${REGION}" 2>/dev/null; then
  echo "    S3 bucket '${BUCKET}' already exists — skipping."
else
  echo "==> Creating S3 bucket: ${BUCKET}"
  if [ "${REGION}" = "us-east-1" ]; then
    aws s3api create-bucket \
      --bucket "${BUCKET}" \
      --region "${REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET}" \
      --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi

  echo "==> Enabling versioning"
  aws s3api put-bucket-versioning \
    --bucket "${BUCKET}" \
    --versioning-configuration Status=Enabled

  echo "==> Enabling server-side encryption (AES-256)"
  aws s3api put-bucket-encryption \
    --bucket "${BUCKET}" \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

  echo "==> Blocking all public access"
  aws s3api put-public-access-block \
    --bucket "${BUCKET}" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
fi

# ---------------------------------------------------------------------------
# DynamoDB table
# ---------------------------------------------------------------------------
if aws dynamodb describe-table \
     --table-name "${TABLE}" \
     --region "${REGION}" \
     --output text 2>/dev/null | grep -q ACTIVE; then
  echo "    DynamoDB table '${TABLE}' already exists — skipping."
else
  echo "==> Creating DynamoDB table: ${TABLE}"
  aws dynamodb create-table \
    --table-name "${TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}"

  echo "==> Waiting for table to become active..."
  aws dynamodb wait table-exists \
    --table-name "${TABLE}" \
    --region "${REGION}"
fi

echo
echo "==> Done. Run 'terraform init' inside the terraform/ directory."

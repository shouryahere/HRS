#!/usr/bin/env bash
# bootstrap.sh — Run ONCE before `terraform init`.
# Creates the S3 bucket and DynamoDB table that backend.tf points at.
# Terraform cannot manage its own state backend, so this must exist first.
set -euo pipefail

REGION="${1:-eu-central-1}"
BUCKET="hrs-platform-terraform-state"
TABLE="hrs-platform-terraform-locks"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Bootstrapping Terraform state backend in ${REGION} (account: ${ACCOUNT_ID})"

# S3 bucket
if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo "  S3 bucket ${BUCKET} already exists — skipping"
else
  aws s3api create-bucket \
    --bucket "${BUCKET}" \
    --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}"

  aws s3api put-bucket-versioning \
    --bucket "${BUCKET}" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption \
    --bucket "${BUCKET}" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}
      }]
    }'

  aws s3api put-public-access-block \
    --bucket "${BUCKET}" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  echo "  S3 bucket ${BUCKET} created"
fi

# DynamoDB table for state locking
if aws dynamodb describe-table --table-name "${TABLE}" --region "${REGION}" 2>/dev/null; then
  echo "  DynamoDB table ${TABLE} already exists — skipping"
else
  aws dynamodb create-table \
    --table-name "${TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}"

  echo "  DynamoDB table ${TABLE} created"
fi

echo ""
echo "Bootstrap complete. Run:"
echo "  cd 2_infrastructure/terraform && terraform init"

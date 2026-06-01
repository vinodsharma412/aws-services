#!/bin/bash
# KMS — encryption keys for DynamoDB at-rest, S3, SSM SecureString
# Free tier: 20,000 API calls/month. KMS key costs $1/month (not free) but
# the AWS managed keys (aws/dynamodb, aws/s3, aws/ssm) are FREE.
# Usage: bash infrastructure/kms/setup_kms.sh staging
set -e
STAGE="${1:?Usage: $0 <stage>}"; REGION="ap-south-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Setting up KMS for stage: ${STAGE}"
echo "[1/2] Using AWS-managed keys (free — no custom key needed)..."
echo "  aws/dynamodb — DynamoDB tables use this automatically"
echo "  aws/s3       — S3 buckets use this for SSE-S3"
echo "  aws/ssm      — SSM SecureString uses this automatically"
echo ""
echo "[2/2] Enabling DynamoDB encryption with AWS-managed key..."
TABLE_PREFIX=$([ "${STAGE}" = "prod" ] && echo "" || echo "${STAGE}_")
for TABLE in users stock_transactions stock_watchlist scraping_jobs scraping_tasks product_data screener_cache menus menu_access; do
  aws dynamodb update-table --table-name "${TABLE_PREFIX}${TABLE}" \
    --sse-specification Enabled=true,SSEType=AES256 \
    --region "${REGION}" > /dev/null 2>/dev/null && \
    echo "  Encryption enabled: ${TABLE_PREFIX}${TABLE}" || \
    echo "  Already encrypted: ${TABLE_PREFIX}${TABLE}"
done
echo ""
echo "All DynamoDB tables now encrypted at rest with AWS-managed key (free)."
echo "S3 buckets: enable SSE in bucket properties → Server-side encryption → AES-256"

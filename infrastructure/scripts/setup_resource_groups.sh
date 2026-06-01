#!/bin/bash
# Resource Groups + Tagging — organize all AWS resources by stage
# Free tier: Resource Groups is always free.
# Usage: bash infrastructure/scripts/setup_resource_groups.sh staging
set -e
STAGE="${1:?Usage: $0 <stage>}"; REGION="ap-south-1"

echo "Setting up Resource Groups for stage: ${STAGE}"

# Tag all Lambda functions
echo "[1/3] Tagging Lambda functions..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
for FUNC in nse-api nse-scraping-worker nse-ws nse-dynamo-streams nse-ses-notifications nse-dlq-alert nse-screener-refresh nse-universe-refresh; do
  aws lambda tag-resource \
    --resource "arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNC}-${STAGE}" \
    --tags "Project=NSEDashboard,Stage=${STAGE},ManagedBy=Infrastructure" \
    --region "${REGION}" 2>/dev/null || true
done
echo "  Lambda functions tagged"

# Create Resource Group
echo "[2/3] Creating Resource Group..."
aws resource-groups create-group \
  --name "NSEDashboard-${STAGE}" \
  --resource-query '{
    "Type": "TAG_FILTERS_1_0",
    "Query": "{\"ResourceTypeFilters\":[\"AWS::AllSupported\"],\"TagFilters\":[{\"Key\":\"Project\",\"Values\":[\"NSEDashboard\"]},{\"Key\":\"Stage\",\"Values\":[\"'"${STAGE}"'\"]}]}"
  }' \
  --region "${REGION}" > /dev/null 2>/dev/null && \
  echo "  Resource Group created: NSEDashboard-${STAGE}" || \
  echo "  Resource Group already exists"

echo "[3/3] Done!"
echo "  View: AWS Console → Resource Groups → NSEDashboard-${STAGE}"
echo "  See all Lambda, DynamoDB, S3, SQS resources for ${STAGE} in one view"

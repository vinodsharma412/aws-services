#!/bin/bash
# SES — transactional email (scraping reports, portfolio summaries, alerts)
# Free tier: 62,000 emails/month when sent FROM Lambda (forever free)
# Usage: bash infrastructure/ses/setup_ses.sh staging your@email.com
set -e
STAGE="${1:?Usage: $0 <stage> <email>}"; EMAIL="${2:?Provide email}"
REGION="ap-south-1"

echo "Setting up SES for stage: ${STAGE}"
echo "[1/3] Verifying sender email identity..."
aws ses verify-email-identity --email-address "${EMAIL}" --region "${REGION}"
echo "  → Check ${EMAIL} for verification link and click it."

echo "[2/3] Setting up email sending configuration..."
aws ses put-account-sending-enabled --enabled --region "${REGION}" 2>/dev/null || true

echo "[3/3] Saving to SSM..."
aws ssm put-parameter --name "/nse/${STAGE}/ses-sender-email" \
  --value "${EMAIL}" --type String --overwrite --region "${REGION}" > /dev/null
echo "SES setup complete. Verify ${EMAIL} in your inbox before sending emails."

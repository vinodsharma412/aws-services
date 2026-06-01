#!/bin/bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Configure ~/.aws/config and ~/.aws/credentials for Switch Role
#
#  This sets up your LOCAL LAPTOP so that:
#    aws <cmd> --profile aws-staging  →  auto assumes role in staging account
#    aws <cmd> --profile aws-prod     →  auto assumes role in prod account
#
#  Prerequisites:
#    1. Run setup_switch_role.sh in staging account → get staging role ARN
#    2. Run setup_switch_role.sh in prod account    → get prod role ARN
#    3. Have your master account access key ID and secret
#
#  Usage:
#    bash infrastructure/iam/configure_aws_profiles.sh \
#      <master-key-id> \
#      <master-secret-key> \
#      <staging-account-id> \
#      <prod-account-id>
#
#  Example:
#    bash infrastructure/iam/configure_aws_profiles.sh \
#      AKIAIOSFODNN7EXAMPLE \
#      wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
#      111111111111 \
#      222222222222
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
set -e

MASTER_KEY_ID="${1:?Usage: $0 <master-key-id> <master-secret> <staging-account-id> <prod-account-id>}"
MASTER_SECRET="${2:?}"
STAGING_ACCOUNT_ID="${3:?}"
PROD_ACCOUNT_ID="${4:?}"
REGION="ap-south-1"
ROLE_NAME="CrossAccountAccessRole"

STAGING_ROLE_ARN="arn:aws:iam::${STAGING_ACCOUNT_ID}:role/${ROLE_NAME}"
PROD_ROLE_ARN="arn:aws:iam::${PROD_ACCOUNT_ID}:role/${ROLE_NAME}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Configuring ~/.aws/credentials and ~/.aws/config"
echo "  Staging account: ${STAGING_ACCOUNT_ID}"
echo "  Prod account:    ${PROD_ACCOUNT_ID}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Write ~/.aws/credentials (master account keys only) ───────────────────────
cat >> ~/.aws/credentials << EOF

[default]
aws_access_key_id = ${MASTER_KEY_ID}
aws_secret_access_key = ${MASTER_SECRET}
EOF
echo "  ✓ ~/.aws/credentials — master account (default profile)"

# ── Write ~/.aws/config (switch role profiles) ────────────────────────────────
cat >> ~/.aws/config << EOF

# Master account (your personal/org account)
[default]
region = ${REGION}
output = json

# aws-staging account — switch role from master
[profile aws-staging]
role_arn = ${STAGING_ROLE_ARN}
source_profile = default
external_id = nse-staging-access
region = ${REGION}
output = json
role_session_name = aws-staging-session
# Uncomment next line if MFA is enabled on your master account:
# mfa_serial = arn:aws:iam::<MASTER_ACCOUNT_ID>:mfa/<your-mfa-device>

# aws-prod account — switch role from master
[profile aws-prod]
role_arn = ${PROD_ROLE_ARN}
source_profile = default
external_id = nse-prod-access
region = ${REGION}
output = json
role_session_name = aws-prod-session
# Uncomment next line if MFA is enabled on your master account:
# mfa_serial = arn:aws:iam::<MASTER_ACCOUNT_ID>:mfa/<your-mfa-device>
EOF
echo "  ✓ ~/.aws/config — aws-staging and aws-prod switch role profiles"

# ── Test both profiles ────────────────────────────────────────────────────────
echo ""
echo "  Testing profiles..."
echo ""
STAGING_ACCT=$(aws sts get-caller-identity --profile aws-staging \
  --query Account --output text 2>/dev/null || echo "FAILED")
PROD_ACCT=$(aws sts get-caller-identity --profile aws-prod \
  --query Account --output text 2>/dev/null || echo "FAILED")

echo "  aws-staging profile → account: ${STAGING_ACCT}"
echo "  aws-prod    profile → account: ${PROD_ACCT}"

if [ "${STAGING_ACCT}" = "${STAGING_ACCOUNT_ID}" ] && \
   [ "${PROD_ACCT}" = "${PROD_ACCOUNT_ID}" ]; then
  echo ""
  echo "  ✓ Both profiles working!"
else
  echo ""
  echo "  ✗ One or both profiles failed."
  echo "    Check: did you run setup_switch_role.sh in each account?"
  echo "    Check: is the master account user allowed to assume these roles?"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Now use like this:"
echo ""
echo "  # Staging"
echo "  export AWS_PROFILE=aws-staging"
echo "  aws s3 ls  (lists staging S3 buckets)"
echo "  make setup-infra STAGE=staging"
echo ""
echo "  # Prod"
echo "  export AWS_PROFILE=aws-prod"
echo "  aws lambda list-functions  (lists prod Lambda functions)"
echo "  make deploy STAGE=prod"
echo ""
echo "  # Switch in console (browser)"
echo "  Console → click your name → Switch Role"
echo "  Account: ${STAGING_ACCOUNT_ID}  Role: CrossAccountAccessRole"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

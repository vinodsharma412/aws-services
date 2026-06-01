#!/bin/bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  STAGING ACCOUNT — Full one-time infrastructure setup
#
#  Run this script once inside your aws-staging AWS account.
#  After this script, every git push to 'develop' auto-deploys here.
#
#  Time required: ~30 minutes
#
#  Prerequisites:
#    1. AWS CLI configured with staging account credentials:
#       export AWS_PROFILE=aws-staging
#       OR
#       export AWS_ACCESS_KEY_ID=<staging-key>
#       export AWS_SECRET_ACCESS_KEY=<staging-secret>
#
#    2. GitHub repo name (e.g. vinodsharma412/aws-services)
#    3. Your email address for alerts
#
#  Usage:
#    AWS_PROFILE=aws-staging bash infrastructure/scripts/setup_staging_account.sh \
#      vinodsharma412/aws-services your@email.com
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
set -e

GITHUB_REPO="${1:?Usage: $0 <github-org/repo> <email>}"
EMAIL="${2:?Provide your email address}"
STAGE="staging"
REGION="ap-south-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   STAGING ACCOUNT SETUP                                      ║"
echo "║   Account: ${ACCOUNT_ID}                        ║"
echo "║   Region:  ${REGION}                                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

log() { echo ""; echo "▶ $1"; echo "  $(date '+%H:%M:%S')"; }

# ── STEP 1: IAM roles ─────────────────────────────────────────────────────────
log "[1/15] Creating Lambda execution role (NSELambdaRole)..."
bash "${REPO_ROOT}/infrastructure/iam/setup_lambda_role.sh"

log "[2/15] Setting up GitHub Actions OIDC (no access keys needed)..."
bash "${REPO_ROOT}/infrastructure/iam/setup_oidc_github.sh" "${STAGE}" "${GITHUB_REPO}"

# ── STEP 2: Storage ───────────────────────────────────────────────────────────
log "[3/15] Creating S3 buckets (frontend + avatars)..."
bash "${REPO_ROOT}/infrastructure/scripts/s3_setup.sh"

# ── STEP 3: Database ──────────────────────────────────────────────────────────
log "[4/15] Creating DynamoDB tables (12 tables, no prefix, account-isolated)..."
AWS_REGION="${REGION}" python3 "${REPO_ROOT}/infrastructure/dynamodb/create_tables.py"

# ── STEP 4: Secrets ───────────────────────────────────────────────────────────
log "[5/15] Setting up SSM Parameter Store secrets..."
bash "${REPO_ROOT}/infrastructure/ssm/setup_ssm.sh" "${STAGE}"

# ── STEP 5: Auth ──────────────────────────────────────────────────────────────
log "[6/15] Creating Cognito User Pool (replaces JWT auth)..."
bash "${REPO_ROOT}/infrastructure/cognito/setup_cognito.sh" "${STAGE}" "${EMAIL}"

# ── STEP 6: Messaging ─────────────────────────────────────────────────────────
log "[7/15] Creating SQS queues (scraping + DLQ)..."
bash "${REPO_ROOT}/infrastructure/sqs/setup_sqs.sh" "${STAGE}"

log "[8/15] Creating SNS alert topic..."
bash "${REPO_ROOT}/infrastructure/sns/setup_sns.sh" "${STAGE}" "${EMAIL}"

log "[9/15] Setting up SES email..."
bash "${REPO_ROOT}/infrastructure/ses/setup_ses.sh" "${STAGE}" "${EMAIL}"

# ── STEP 7: Lambda Layer ──────────────────────────────────────────────────────
log "[10/15] Deploying shared Lambda Layer (X-Ray + AppConfig utils)..."
bash "${REPO_ROOT}/infrastructure/lambda/layer/deploy.sh" "${STAGE}"

# ── STEP 8: Lambda functions ──────────────────────────────────────────────────
log "[11/15] Deploying Lambda functions..."
bash "${REPO_ROOT}/infrastructure/lambda/api/deploy.sh" "${STAGE}"
bash "${REPO_ROOT}/infrastructure/lambda/scraping_worker/deploy.sh" "${STAGE}"

# ── STEP 9: API Gateway ───────────────────────────────────────────────────────
log "[12/15] Creating API Gateway HTTP API → Lambda..."
bash "${REPO_ROOT}/infrastructure/scripts/api_gateway_setup.sh" "${STAGE}"

# ── STEP 10: Real-time + Orchestration ────────────────────────────────────────
log "[13/15] Setting up WebSocket API + DynamoDB Streams..."
bash "${REPO_ROOT}/infrastructure/websocket/setup_websocket_api.sh" "${STAGE}"

log "[14/15] Creating Step Functions state machine..."
bash "${REPO_ROOT}/infrastructure/stepfunctions/setup_stepfunctions.sh" "${STAGE}"

# ── STEP 11: Monitoring ───────────────────────────────────────────────────────
log "[15/15] Setting up EventBridge + CloudWatch alarms + CloudFront..."
bash "${REPO_ROOT}/infrastructure/eventbridge/setup_eventbridge.sh" "${STAGE}"

API_GW_ID=$(aws ssm get-parameter --name "/nse/${STAGE}/api-gateway-id" \
  --query "Parameter.Value" --output text --region "${REGION}" 2>/dev/null || echo "")
bash "${REPO_ROOT}/infrastructure/cloudwatch/setup_alarms.sh" "${STAGE}" "${API_GW_ID}"
bash "${REPO_ROOT}/infrastructure/cloudfront/setup_cloudfront.sh" "${STAGE}"
bash "${REPO_ROOT}/infrastructure/appconfig/setup_appconfig.sh" "${STAGE}"
bash "${REPO_ROOT}/infrastructure/kms/setup_kms.sh" "${STAGE}"
bash "${REPO_ROOT}/infrastructure/scripts/setup_resource_groups.sh" "${STAGE}"

# ── Done ──────────────────────────────────────────────────────────────────────
API_URL=$(aws ssm get-parameter --name "/nse/${STAGE}/api-gateway-url" \
  --query "Parameter.Value" --output text --region "${REGION}" 2>/dev/null || echo "not-set")
STAGING_ROLE=$(aws ssm get-parameter --name "/nse/github-actions-role-arn" \
  --query "Parameter.Value" --output text --region "${REGION}" 2>/dev/null || echo "not-set")
S3_BUCKET=$(aws s3 ls | grep nse-frontend | awk '{print $3}' | head -1)

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   ✓ STAGING ACCOUNT SETUP COMPLETE                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Account ID:    ${ACCOUNT_ID}"
echo "  API URL:       ${API_URL}"
echo "  S3 bucket:     ${S3_BUCKET}"
echo ""
echo "  Add these to GitHub repo → Settings → Secrets → Actions:"
echo ""
echo "    STAGING_ROLE_ARN     = ${STAGING_ROLE}"
echo "    STAGING_ACCOUNT_ID   = ${ACCOUNT_ID}"
echo "    STAGING_API_URL      = ${API_URL}/api/v1"
echo "    S3_FRONTEND_BUCKET_STAGING = ${S3_BUCKET}"
echo ""
echo "  Health check:"
echo "    curl ${API_URL}/api/v1/health/"
echo ""
echo "  Next: run setup_prod_account.sh in your aws-prod account"
echo ""

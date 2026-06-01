#!/bin/bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  PROD ACCOUNT — Full one-time infrastructure setup
#
#  Run this script once inside your aws-prod AWS account.
#  After staging is tested and approved, changes promote here manually.
#
#  IMPORTANT: This script does NOT auto-deploy code. It only creates
#  infrastructure. Code deploys require manual GitHub approval.
#
#  Usage:
#    AWS_PROFILE=aws-prod bash infrastructure/scripts/setup_prod_account.sh \
#      vinodsharma412/aws-services your@email.com
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
set -e

GITHUB_REPO="${1:?Usage: $0 <github-org/repo> <email>}"
EMAIL="${2:?Provide your email address}"
STAGE="prod"
REGION="ap-south-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   PROD ACCOUNT SETUP                                         ║"
echo "║   Account: ${ACCOUNT_ID}                        ║"
echo "║   Region:  ${REGION}                                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  ⚠  PRODUCTION environment — be careful!"
echo "  This creates infrastructure. Code deploys require approval."
echo ""
read -p "  Continue? (yes/no): " CONFIRM
if [ "${CONFIRM}" != "yes" ]; then echo "Aborted."; exit 0; fi

log() { echo ""; echo "▶ $1"; echo "  $(date '+%H:%M:%S')"; }

# ── STEP 1: IAM ────────────────────────────────────────────────────────────────
log "[1/15] Creating Lambda execution role..."
bash "${REPO_ROOT}/infrastructure/iam/setup_lambda_role.sh"

log "[2/15] Setting up GitHub Actions OIDC (prod environment gate)..."
bash "${REPO_ROOT}/infrastructure/iam/setup_oidc_github.sh" "${STAGE}" "${GITHUB_REPO}"

# ── STEP 2: Storage ───────────────────────────────────────────────────────────
log "[3/15] Creating S3 buckets..."
bash "${REPO_ROOT}/infrastructure/scripts/s3_setup.sh"

# ── STEP 3: Database ──────────────────────────────────────────────────────────
log "[4/15] Creating DynamoDB tables (production — same names as staging, different account)..."
AWS_REGION="${REGION}" python3 "${REPO_ROOT}/infrastructure/dynamodb/create_tables.py"

# ── STEP 4: Secrets ───────────────────────────────────────────────────────────
log "[5/15] Setting up SSM secrets..."
bash "${REPO_ROOT}/infrastructure/ssm/setup_ssm.sh" "${STAGE}"

# ── STEP 5: Auth ──────────────────────────────────────────────────────────────
log "[6/15] Creating Cognito User Pool (prod — separate from staging)..."
bash "${REPO_ROOT}/infrastructure/cognito/setup_cognito.sh" "${STAGE}" "${EMAIL}"

# ── STEP 6: Messaging ─────────────────────────────────────────────────────────
log "[7/15] Creating SQS + SNS + SES..."
bash "${REPO_ROOT}/infrastructure/sqs/setup_sqs.sh" "${STAGE}"
bash "${REPO_ROOT}/infrastructure/sns/setup_sns.sh" "${STAGE}" "${EMAIL}"
bash "${REPO_ROOT}/infrastructure/ses/setup_ses.sh" "${STAGE}" "${EMAIL}"

# ── STEP 7: Lambda ────────────────────────────────────────────────────────────
log "[8/15] Deploying Lambda Layer..."
bash "${REPO_ROOT}/infrastructure/lambda/layer/deploy.sh" "${STAGE}"

log "[9/15] Deploying Lambda functions..."
bash "${REPO_ROOT}/infrastructure/lambda/api/deploy.sh" "${STAGE}"
bash "${REPO_ROOT}/infrastructure/lambda/scraping_worker/deploy.sh" "${STAGE}"

# ── STEP 8: API Gateway ───────────────────────────────────────────────────────
log "[10/15] Creating API Gateway (prod account)..."
bash "${REPO_ROOT}/infrastructure/scripts/api_gateway_setup.sh" "${STAGE}"

# ── STEP 9: Real-time ─────────────────────────────────────────────────────────
log "[11/15] Setting up WebSocket API + DynamoDB Streams..."
bash "${REPO_ROOT}/infrastructure/websocket/setup_websocket_api.sh" "${STAGE}"

log "[12/15] Creating Step Functions..."
bash "${REPO_ROOT}/infrastructure/stepfunctions/setup_stepfunctions.sh" "${STAGE}"

# ── STEP 10: Monitoring ───────────────────────────────────────────────────────
log "[13/15] EventBridge scheduled jobs..."
bash "${REPO_ROOT}/infrastructure/eventbridge/setup_eventbridge.sh" "${STAGE}"

log "[14/15] CloudWatch alarms + dashboard..."
API_GW_ID=$(aws ssm get-parameter --name "/nse/${STAGE}/api-gateway-id" \
  --query "Parameter.Value" --output text --region "${REGION}" 2>/dev/null || echo "")
bash "${REPO_ROOT}/infrastructure/cloudwatch/setup_alarms.sh" "${STAGE}" "${API_GW_ID}"

log "[15/15] CloudFront + AppConfig + KMS + Resource Groups..."
bash "${REPO_ROOT}/infrastructure/cloudfront/setup_cloudfront.sh" "${STAGE}"
bash "${REPO_ROOT}/infrastructure/appconfig/setup_appconfig.sh" "${STAGE}"
bash "${REPO_ROOT}/infrastructure/kms/setup_kms.sh" "${STAGE}"
bash "${REPO_ROOT}/infrastructure/scripts/setup_resource_groups.sh" "${STAGE}"

# ── Done ──────────────────────────────────────────────────────────────────────
API_URL=$(aws ssm get-parameter --name "/nse/${STAGE}/api-gateway-url" \
  --query "Parameter.Value" --output text --region "${REGION}" 2>/dev/null || echo "not-set")
PROD_ROLE=$(aws ssm get-parameter --name "/nse/github-actions-role-arn" \
  --query "Parameter.Value" --output text --region "${REGION}" 2>/dev/null || echo "not-set")
S3_BUCKET=$(aws s3 ls | grep nse-frontend | awk '{print $3}' | head -1)

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   ✓ PROD ACCOUNT SETUP COMPLETE                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Account ID:    ${ACCOUNT_ID}"
echo "  API URL:       ${API_URL}"
echo "  S3 bucket:     ${S3_BUCKET}"
echo ""
echo "  Add these to GitHub repo → Settings → Secrets → Actions:"
echo ""
echo "    PROD_ROLE_ARN          = ${PROD_ROLE}"
echo "    PROD_ACCOUNT_ID        = ${ACCOUNT_ID}"
echo "    PROD_API_URL           = ${API_URL}/api/v1"
echo "    S3_FRONTEND_BUCKET_PROD = ${S3_BUCKET}"
echo ""
echo "  Health check (after first code deploy):"
echo "    curl ${API_URL}/api/v1/health/"
echo ""
echo "  Next: Add secrets to GitHub, then push to 'develop' branch."
echo "  Staging deploys automatically. Approve prod in GitHub UI."
echo ""

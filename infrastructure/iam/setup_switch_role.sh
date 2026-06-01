#!/bin/bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Cross-Account Switch Role Setup
#
#  Pattern:
#    Master account  →  STS AssumeRole  →  aws-staging / aws-prod accounts
#
#  You only need ONE IAM user (in your master/personal account).
#  No separate access keys for staging or prod.
#
#  How it works:
#    1. In staging account  → create IAM role "CrossAccountAccessRole"
#                              with trust policy allowing YOUR master account
#    2. In prod account     → same role, same trust policy
#    3. On your laptop      → ~/.aws/config has profiles that auto-assume those roles
#    4. CLI/SDK             → `aws s3 ls --profile aws-staging` auto-switches
#    5. Console             → click username → Switch Role → enter account + role
#
#  Run this script INSIDE each child account:
#    # First, log in to staging account (temporary credentials or root)
#    AWS_PROFILE=staging-temp bash infrastructure/iam/setup_switch_role.sh staging <MASTER_ACCOUNT_ID>
#
#    # Then, log in to prod account
#    AWS_PROFILE=prod-temp bash infrastructure/iam/setup_switch_role.sh prod <MASTER_ACCOUNT_ID>
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
set -e

STAGE="${1:?Usage: $0 <stage> <master-account-id>   e.g.  $0 staging 123456789012}"
MASTER_ACCOUNT_ID="${2:?Provide your master AWS account ID (12 digits)}"
REGION="ap-south-1"
ROLE_NAME="CrossAccountAccessRole"
CHILD_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Cross-Account Role Setup"
echo "  Child account : ${CHILD_ACCOUNT_ID}  (${STAGE})"
echo "  Master account: ${MASTER_ACCOUNT_ID}  (your personal/master account)"
echo "  Role name     : ${ROLE_NAME}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Trust policy: only allow master account to assume this role ──────────────
TRUST_POLICY=$(cat << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${MASTER_ACCOUNT_ID}:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "nse-${STAGE}-access"
        },
        "BoolIfExists": {
          "aws:MultiFactorAuthPresent": "true"
        }
      }
    }
  ]
}
EOF
)

# ── Create the cross-account role ────────────────────────────────────────────
echo "[1/3] Creating IAM role: ${ROLE_NAME}..."
aws iam create-role \
  --role-name "${ROLE_NAME}" \
  --assume-role-policy-document "${TRUST_POLICY}" \
  --description "Cross-account access from master account ${MASTER_ACCOUNT_ID} to ${STAGE}" \
  --region "${REGION}" > /dev/null 2>/dev/null && \
  echo "  Role created" || echo "  Role already exists — updating trust policy"

# Update trust policy if role exists
aws iam update-assume-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-document "${TRUST_POLICY}" > /dev/null

# ── Attach permissions policy ────────────────────────────────────────────────
echo "[2/3] Attaching permissions..."

# For staging: full admin to all NSE resources
if [ "${STAGE}" = "staging" ]; then
  # PowerUser allows everything except IAM user/group management
  aws iam attach-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/PowerUserAccess" > /dev/null
  echo "  Policy: PowerUserAccess (staging — full service access)"
else
  # Prod: more restricted — only what's needed for operations
  PROD_POLICY=$(cat << PRODPOL
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LambdaReadDeploy",
      "Effect": "Allow",
      "Action": [
        "lambda:GetFunction", "lambda:ListFunctions",
        "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration",
        "lambda:InvokeFunction", "lambda:GetFunctionConfiguration",
        "logs:DescribeLogGroups", "logs:FilterLogEvents", "logs:GetLogEvents",
        "cloudwatch:GetMetricData", "cloudwatch:DescribeAlarms",
        "xray:GetServiceGraph", "xray:GetTraceSummaries",
        "dynamodb:DescribeTable", "dynamodb:ListTables", "dynamodb:Scan", "dynamodb:GetItem",
        "s3:GetObject", "s3:ListBucket", "s3:PutObject",
        "apigateway:GET",
        "ssm:GetParameter", "ssm:GetParameters",
        "cognito-idp:ListUsers", "cognito-idp:AdminGetUser",
        "sqs:GetQueueAttributes", "sqs:ReceiveMessage",
        "stepfunctions:ListExecutions", "stepfunctions:DescribeExecution",
        "sts:GetCallerIdentity",
        "cloudfront:CreateInvalidation",
        "iam:ListRoles", "iam:GetRole"
      ],
      "Resource": "*"
    }
  ]
}
PRODPOL
  )
  aws iam put-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-name "NSEProdReadAndDeploy" \
    --policy-document "${PROD_POLICY}" > /dev/null
  echo "  Policy: NSEProdReadAndDeploy (prod — read + deploy only, no delete)"
fi

# Also create the Lambda execution role in this account
echo "[3/3] Creating NSELambdaRole for Lambda functions..."
bash "$(dirname "${BASH_SOURCE[0]}")/setup_lambda_role.sh" 2>/dev/null || \
  echo "  NSELambdaRole already exists"

ROLE_ARN="arn:aws:iam::${CHILD_ACCOUNT_ID}:role/${ROLE_NAME}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ Cross-account role created"
echo ""
echo "  Role ARN: ${ROLE_ARN}"
echo "  External ID: nse-${STAGE}-access"
echo ""
echo "  Next: add to ~/.aws/config on your laptop:"
echo ""
echo "  [profile aws-${STAGE}]"
echo "  role_arn = ${ROLE_ARN}"
echo "  source_profile = default"
echo "  external_id = nse-${STAGE}-access"
echo "  mfa_serial = arn:aws:iam::${MASTER_ACCOUNT_ID}:mfa/YOUR_MFA_DEVICE"
echo "  region = ${REGION}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

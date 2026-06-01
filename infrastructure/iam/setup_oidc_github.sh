#!/bin/bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  GitHub Actions OIDC — passwordless AWS authentication
#
#  Run this script INSIDE each AWS account (staging + prod separately).
#  It creates an OIDC identity provider and IAM role that GitHub Actions
#  can assume WITHOUT storing any AWS access keys in GitHub Secrets.
#
#  Security benefit: No long-lived credentials anywhere. GitHub Actions
#  gets a temporary 1-hour token per job. If GitHub is breached, the
#  token is useless after 1 hour. If you delete the role, access stops.
#
#  Usage:
#    # In aws-staging account
#    AWS_PROFILE=aws-staging bash infrastructure/iam/setup_oidc_github.sh staging vinodsharma412/aws-services
#
#    # In aws-prod account
#    AWS_PROFILE=aws-prod bash infrastructure/iam/setup_oidc_github.sh prod vinodsharma412/aws-services
#
#  After running, add to GitHub repo Settings → Secrets:
#    STAGING_ACCOUNT_ID = <staging-account-id>
#    PROD_ACCOUNT_ID    = <prod-account-id>
#
#  DO NOT add AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY.
#  OIDC makes them unnecessary.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
set -e

STAGE="${1:?Usage: $0 <stage> <github-org/repo>  e.g. $0 staging vinodsharma412/aws-services}"
GITHUB_REPO="${2:?Provide github-org/repo}"
REGION="ap-south-1"
ROLE_NAME="GitHubActionsRole-${STAGE}"
OIDC_URL="https://token.actions.githubusercontent.com"
OIDC_THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  GitHub OIDC Setup"
echo "  Account:    ${ACCOUNT_ID}  (${STAGE})"
echo "  GitHub repo: ${GITHUB_REPO}"
echo "  Role name:  ${ROLE_NAME}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Create OIDC Provider ───────────────────────────────────────────────────
echo "[1/3] Creating GitHub OIDC identity provider..."
aws iam create-open-id-connect-provider \
  --url "${OIDC_URL}" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "${OIDC_THUMBPRINT}" \
  --region "${REGION}" > /dev/null 2>/dev/null && \
  echo "  OIDC provider created" || echo "  OIDC provider already exists"

OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

# ── 2. Create IAM Role with trust policy ─────────────────────────────────────
echo "[2/3] Creating IAM role: ${ROLE_NAME}..."

# Trust only the specific GitHub repo + branch (develop for staging, main for prod)
if [ "${STAGE}" = "prod" ]; then
  BRANCH_CONDITION="repo:${GITHUB_REPO}:environment:prod"
else
  BRANCH_CONDITION="repo:${GITHUB_REPO}:ref:refs/heads/develop"
fi

TRUST_POLICY=$(cat << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "${BRANCH_CONDITION}"
        }
      }
    }
  ]
}
EOF
)

aws iam create-role \
  --role-name "${ROLE_NAME}" \
  --assume-role-policy-document "${TRUST_POLICY}" \
  --description "GitHub Actions OIDC role for ${STAGE} — repo: ${GITHUB_REPO}" \
  --region "${REGION}" > /dev/null 2>/dev/null || true

# Attach policies — least privilege for CI/CD
PERMISSIONS_POLICY=$(cat << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LambdaDeploy",
      "Effect": "Allow",
      "Action": [
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "lambda:CreateFunction",
        "lambda:GetFunction",
        "lambda:PublishVersion",
        "lambda:ListEventSourceMappings",
        "lambda:CreateEventSourceMapping",
        "lambda:PublishLayerVersion",
        "lambda:AddPermission",
        "lambda:TagResource",
        "lambda:WaitForFunctionActive",
        "lambda:WaitForFunctionUpdated"
      ],
      "Resource": "*"
    },
    {
      "Sid": "S3FrontendDeploy",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetObject"],
      "Resource": ["arn:aws:s3:::nse-*", "arn:aws:s3:::nse-*/*"]
    },
    {
      "Sid": "CloudFrontInvalidate",
      "Effect": "Allow",
      "Action": ["cloudfront:CreateInvalidation"],
      "Resource": "*"
    },
    {
      "Sid": "SSMReadSecrets",
      "Effect": "Allow",
      "Action": ["ssm:GetParameter", "ssm:GetParameters", "ssm:PutParameter"],
      "Resource": "arn:aws:ssm:*:${ACCOUNT_ID}:parameter/nse/*"
    },
    {
      "Sid": "STSGetCallerIdentity",
      "Effect": "Allow",
      "Action": ["sts:GetCallerIdentity"],
      "Resource": "*"
    }
  ]
}
EOF
)

aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "GitHubActionsDeploy-${STAGE}" \
  --policy-document "${PERMISSIONS_POLICY}" > /dev/null
echo "  Role created: ${ROLE_NAME}"

# ── 3. Output ─────────────────────────────────────────────────────────────────
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
aws ssm put-parameter \
  --name "/nse/github-actions-role-arn" \
  --value "${ROLE_ARN}" \
  --type String --overwrite --region "${REGION}" > /dev/null

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ OIDC configured"
echo ""
echo "  Add to GitHub repo Settings → Secrets → Actions:"
if [ "${STAGE}" = "staging" ]; then
  echo "    STAGING_ROLE_ARN  =  ${ROLE_ARN}"
  echo "    STAGING_ACCOUNT_ID = ${ACCOUNT_ID}"
else
  echo "    PROD_ROLE_ARN  =  ${ROLE_ARN}"
  echo "    PROD_ACCOUNT_ID = ${ACCOUNT_ID}"
fi
echo ""
echo "  GitHub Actions will assume this role automatically."
echo "  NO AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY needed."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

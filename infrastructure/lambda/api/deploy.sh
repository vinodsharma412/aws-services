#!/bin/bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Deploy the FastAPI application as an AWS Lambda function.
#
#  Architecture:
#    API Gateway HTTP API  →  Lambda: nse-api-{stage}  →  DynamoDB / S3 / SQS
#    (Mangum adapter translates API GW events into ASGI for FastAPI)
#
#  What this does:
#    1. pip install all deps into a build directory (targeting Linux x86_64)
#    2. Copies the app/ package + lambda_handler.py
#    3. Creates a zip file and uploads to Lambda
#    4. Creates OR updates the Lambda function
#
#  Package size note:
#    pandas + numpy + yfinance ≈ 100 MB.
#    AWS provides a managed Lambda Layer for pandas/numpy.
#    This script attaches it automatically so the zip stays under 50 MB.
#
#  Usage:
#    bash infrastructure/lambda/api/deploy.sh staging
#    bash infrastructure/lambda/api/deploy.sh prod
#
#  Prerequisites:
#    - AWS CLI configured
#    - NSELambdaRole already created:
#        bash infrastructure/iam/setup_lambda_role.sh
#    - DynamoDB tables created:
#        STAGE=<stage> python3 infrastructure/dynamodb/create_tables.py
#    - SSM parameters set:
#        bash infrastructure/ssm/setup_ssm.sh <stage>
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

set -e

STAGE="${1:?Usage: $0 <stage>   e.g.  $0 staging  or  $0 prod}"
REGION="ap-south-1"
FUNC_NAME="nse-api-${STAGE}"
HANDLER="lambda_handler.handler"
RUNTIME="python3.12"
TIMEOUT=30           # API Gateway max is 29 s; give Lambda 30 s buffer
MEMORY=512           # MB — yfinance + pandas need headroom

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
LAMBDA_ROLE="arn:aws:iam::${ACCOUNT_ID}:role/NSELambdaRole"

# AWS-managed AWSSDKPandas layer (pandas + numpy pre-built for Lambda)
PANDAS_LAYER="arn:aws:lambda:${REGION}:336392948345:layer:AWSSDKPandas-Python312:16"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../" && pwd)"
BACKEND_DIR="${REPO_ROOT}/backend"
BUILD_DIR="${REPO_ROOT}/infrastructure/lambda/api/build_${STAGE}"
ZIP_FILE="${REPO_ROOT}/infrastructure/lambda/api/api_${STAGE}.zip"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Deploy: ${FUNC_NAME}"
echo "  Stage:  ${STAGE}"
echo "  Region: ${REGION}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Build package ─────────────────────────────────────────────────────────────
echo "[1/4] Building Lambda package..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Install Python deps for Lambda (Linux x86_64, exclude playwright, exclude pandas — use layer)
pip install \
  -r "${BACKEND_DIR}/requirements.txt" \
  -t "${BUILD_DIR}/" \
  -q \
  --platform manylinux2014_x86_64 \
  --implementation cp \
  --python-version 3.12 \
  --only-binary=:all: \
  --exclude pandas \
  --exclude numpy 2>/dev/null || \
pip install \
  -r "${BACKEND_DIR}/requirements.txt" \
  -t "${BUILD_DIR}/" \
  -q \
  --exclude pandas \
  --exclude numpy

# Remove playwright (not used in Lambda; scraping is done by scraping_worker Lambda)
rm -rf "${BUILD_DIR}/playwright" "${BUILD_DIR}/playwright-*" 2>/dev/null || true

# Copy the FastAPI app and Lambda handler
cp -r "${BACKEND_DIR}/app" "${BUILD_DIR}/"
cp "${BACKEND_DIR}/lambda_handler.py" "${BUILD_DIR}/"

# Strip __pycache__ and .pyc to reduce size
find "${BUILD_DIR}" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
find "${BUILD_DIR}" -name "*.pyc" -delete 2>/dev/null || true

cd "${BUILD_DIR}" && zip -r "${ZIP_FILE}" . -q && cd -
SIZE=$(du -sh "${ZIP_FILE}" | cut -f1)
echo "  Package size: ${SIZE}"

# ── Get SSM environment values for Lambda config ──────────────────────────────
echo "[2/4] Reading SSM parameters for Lambda environment..."
S3_BUCKET=$(aws ssm get-parameter --name "/nse/${STAGE}/s3-assets-bucket" \
  --query "Parameter.Value" --output text --region "${REGION}" 2>/dev/null || echo "")
SQS_URL=$(aws ssm get-parameter --name "/nse/${STAGE}/sqs-jobs-url" \
  --query "Parameter.Value" --output text --region "${REGION}" 2>/dev/null || echo "")
SNS_ARN=$(aws ssm get-parameter --name "/nse/${STAGE}/sns-alerts-arn" \
  --query "Parameter.Value" --output text --region "${REGION}" 2>/dev/null || echo "")

ENV_VARS="Variables={STAGE=${STAGE},AWS_REGION=${REGION}"
[ -n "${S3_BUCKET}" ]  && ENV_VARS="${ENV_VARS},S3_ASSETS_BUCKET=${S3_BUCKET}"
[ -n "${SQS_URL}" ]    && ENV_VARS="${ENV_VARS},SQS_SCRAPING_JOBS_URL=${SQS_URL}"
[ -n "${SNS_ARN}" ]    && ENV_VARS="${ENV_VARS},SNS_ALERTS_ARN=${SNS_ARN}"
ENV_VARS="${ENV_VARS}}"

# ── Create or update Lambda function ──────────────────────────────────────────
echo "[3/4] Deploying Lambda function..."

if aws lambda get-function --function-name "${FUNC_NAME}" \
   --region "${REGION}" > /dev/null 2>&1; then
  aws lambda update-function-code \
    --function-name "${FUNC_NAME}" \
    --zip-file "fileb://${ZIP_FILE}" \
    --region "${REGION}" > /dev/null
  aws lambda wait function-updated --function-name "${FUNC_NAME}" --region "${REGION}"
  aws lambda update-function-configuration \
    --function-name "${FUNC_NAME}" \
    --timeout "${TIMEOUT}" \
    --memory-size "${MEMORY}" \
    --layers "${PANDAS_LAYER}" \
    --environment "${ENV_VARS}" \
    --region "${REGION}" > /dev/null
  echo "  Updated: ${FUNC_NAME}"
else
  aws lambda create-function \
    --function-name "${FUNC_NAME}" \
    --runtime "${RUNTIME}" \
    --handler "${HANDLER}" \
    --zip-file "fileb://${ZIP_FILE}" \
    --role "${LAMBDA_ROLE}" \
    --timeout "${TIMEOUT}" \
    --memory-size "${MEMORY}" \
    --layers "${PANDAS_LAYER}" \
    --environment "${ENV_VARS}" \
    --region "${REGION}" > /dev/null
  echo "  Created: ${FUNC_NAME}"
  aws lambda wait function-active --function-name "${FUNC_NAME}" --region "${REGION}"
fi

echo "[4/4] Done!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Lambda: ${FUNC_NAME}"
echo "  Handler: ${HANDLER}"
echo "  Memory: ${MEMORY} MB  |  Timeout: ${TIMEOUT} s"
echo "  Layer: AWSSDKPandas (pandas + numpy)"
echo ""
echo "  Next: wire this Lambda to API Gateway"
echo "    bash infrastructure/scripts/api_gateway_setup.sh ${STAGE}"
echo ""
echo "  Monitor:"
echo "  CloudWatch → Log groups → /aws/lambda/${FUNC_NAME}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

rm -rf "${BUILD_DIR}"

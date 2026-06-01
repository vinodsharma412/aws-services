#!/bin/bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Deploy the SQS-triggered scraping worker Lambda.
#
#  What this does:
#    1. Packages handler.py + httpx + beautifulsoup4 into a zip
#    2. Creates OR updates the Lambda function
#    3. Wires the SQS queue as event source (batch size = 1)
#    4. Sets up Dead Letter Queue for failed scrapes
#
#  Usage:
#    bash infrastructure/lambda/scraping_worker/deploy.sh staging
#    bash infrastructure/lambda/scraping_worker/deploy.sh prod
#
#  Prerequisites:
#    - AWS CLI configured (or running on EC2 with IAM role)
#    - NSELambdaRole already created:
#        bash infrastructure/iam/setup_lambda_role.sh
#    - SQS queue + DLQ already created:
#        bash infrastructure/sqs/setup_sqs.sh <stage>
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

set -e

STAGE="${1:?Usage: $0 <stage>   e.g.  $0 staging  or  $0 prod}"
REGION="ap-south-1"
FUNC_NAME="nse-scraping-worker-${STAGE}"
HANDLER="handler.lambda_handler"
RUNTIME="python3.12"
TIMEOUT=120          # 2 minutes per scrape task
MEMORY=256           # MB (httpx is lightweight)
QUEUE_NAME="nse-scraping-jobs-${STAGE}"
DLQ_NAME="${QUEUE_NAME}-dlq"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
LAMBDA_ROLE="arn:aws:iam::${ACCOUNT_ID}:role/NSELambdaRole"
QUEUE_URL=$(aws sqs get-queue-url --queue-name "${QUEUE_NAME}" \
  --region "${REGION}" --query QueueUrl --output text 2>/dev/null || echo "")
QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "${QUEUE_URL}" \
  --attribute-names QueueArn --query 'Attributes.QueueArn' \
  --output text --region "${REGION}" 2>/dev/null || echo "")

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${DIR}/build_${STAGE}"
ZIP_FILE="${DIR}/worker_${STAGE}.zip"

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
cp "${DIR}/handler.py" "${BUILD_DIR}/"
pip install -r "${DIR}/requirements.txt" -t "${BUILD_DIR}/" -q \
  --platform manylinux2014_x86_64 \
  --implementation cp \
  --python-version 3.12 \
  --only-binary=:all: 2>/dev/null || \
pip install -r "${DIR}/requirements.txt" -t "${BUILD_DIR}/" -q

cd "${BUILD_DIR}" && zip -r "${ZIP_FILE}" . -q && cd -
echo "  Package: $(du -sh "${ZIP_FILE}" | cut -f1)"

# ── Create or update Lambda function ──────────────────────────────────────────
echo "[2/4] Deploying Lambda function..."

if aws lambda get-function --function-name "${FUNC_NAME}" \
   --region "${REGION}" > /dev/null 2>&1; then
  aws lambda update-function-code \
    --function-name "${FUNC_NAME}" \
    --zip-file "fileb://${ZIP_FILE}" \
    --region "${REGION}" > /dev/null
  aws lambda update-function-configuration \
    --function-name "${FUNC_NAME}" \
    --timeout "${TIMEOUT}" \
    --memory-size "${MEMORY}" \
    --environment "Variables={STAGE=${STAGE},AWS_REGION=${REGION}}" \
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
    --environment "Variables={STAGE=${STAGE},AWS_REGION=${REGION}}" \
    --region "${REGION}" > /dev/null
  echo "  Created: ${FUNC_NAME}"
  # Wait for function to be active
  aws lambda wait function-active --function-name "${FUNC_NAME}" --region "${REGION}"
fi

# ── Wire SQS event source ─────────────────────────────────────────────────────
echo "[3/4] Wiring SQS event source..."

if [ -z "${QUEUE_ARN}" ]; then
  echo "  WARN: SQS queue ${QUEUE_NAME} not found — skipping event source mapping."
  echo "        Run: bash infrastructure/sqs/setup_sqs.sh ${STAGE}"
else
  # Check if mapping already exists
  EXISTING_UUID=$(aws lambda list-event-source-mappings \
    --function-name "${FUNC_NAME}" \
    --event-source-arn "${QUEUE_ARN}" \
    --region "${REGION}" \
    --query "EventSourceMappings[0].UUID" --output text 2>/dev/null || echo "None")

  if [ "${EXISTING_UUID}" = "None" ] || [ -z "${EXISTING_UUID}" ]; then
    aws lambda create-event-source-mapping \
      --function-name "${FUNC_NAME}" \
      --event-source-arn "${QUEUE_ARN}" \
      --batch-size 1 \
      --function-response-types ReportBatchItemFailures \
      --region "${REGION}" > /dev/null
    echo "  Event source mapping created (batch size = 1)"
  else
    echo "  Event source mapping already exists (${EXISTING_UUID})"
  fi
fi

# ── Publish CloudWatch alarm ──────────────────────────────────────────────────
echo "[4/4] Done!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Lambda: ${FUNC_NAME}"
echo "  Trigger: SQS ${QUEUE_NAME} (batch=1)"
echo "  Retry:   3x then DLQ → SNS email alert"
echo ""
echo "  Monitor:"
echo "  AWS Console → Lambda → ${FUNC_NAME} → Monitor tab"
echo "  CloudWatch → Log groups → /aws/lambda/${FUNC_NAME}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

rm -rf "${BUILD_DIR}"

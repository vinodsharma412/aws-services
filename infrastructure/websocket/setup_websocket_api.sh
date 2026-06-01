#!/bin/bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  API Gateway WebSocket API — real-time scraping progress
#
#  Replaces polling: browser connects ONCE, server pushes updates.
#  DynamoDB Streams → ws_push Lambda → API GW Management API → browser.
#
#  Routes:
#    $connect     → Lambda: nse-ws-{stage}  (store connection)
#    $disconnect  → Lambda: nse-ws-{stage}  (remove connection)
#    $default     → Lambda: nse-ws-{stage}  (subscribe/ping)
#
#  DynamoDB table created: {prefix}ws_connections
#    connection_id (PK), user_id, job_id, ttl (2h auto-expire)
#
#  Usage:
#    bash infrastructure/websocket/setup_websocket_api.sh staging
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
set -e
STAGE="${1:?Usage: $0 <stage>}"
REGION="ap-south-1"
API_NAME="nse-ws-${STAGE}"
FUNC_NAME="nse-ws-${STAGE}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TABLE_PREFIX=$([ "${STAGE}" = "prod" ] && echo "" || echo "${STAGE}_")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  WebSocket API: ${API_NAME}"
echo "  Stage: ${STAGE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── DynamoDB: WebSocket connections table ─────────────────────────────────────
echo "[1/6] Creating ws_connections DynamoDB table..."
TABLE_NAME="${TABLE_PREFIX}ws_connections"
aws dynamodb create-table \
  --table-name "${TABLE_NAME}" \
  --attribute-definitions \
    AttributeName=connection_id,AttributeType=S \
    AttributeName=job_id,AttributeType=S \
  --key-schema AttributeName=connection_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --global-secondary-indexes '[{
    "IndexName":"job-connections-index",
    "KeySchema":[{"AttributeName":"job_id","KeyType":"HASH"}],
    "Projection":{"ProjectionType":"ALL"}
  }]' \
  --region "${REGION}" > /dev/null 2>/dev/null && \
  echo "  Created: ${TABLE_NAME}" || echo "  Exists: ${TABLE_NAME}"

# Enable TTL on ws_connections (auto-delete stale connections)
aws dynamodb update-time-to-live \
  --table-name "${TABLE_NAME}" \
  --time-to-live-specification "Enabled=true,AttributeName=ttl" \
  --region "${REGION}" > /dev/null 2>/dev/null || true
echo "  TTL enabled on ${TABLE_NAME}.ttl"

# ── Enable DynamoDB Streams on scraping_tasks ─────────────────────────────────
echo "[2/6] Enabling DynamoDB Streams on scraping_tasks..."
TASKS_TABLE="${TABLE_PREFIX}scraping_tasks"
STREAM_ARN=$(aws dynamodb update-table \
  --table-name "${TASKS_TABLE}" \
  --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
  --region "${REGION}" \
  --query "TableDescription.LatestStreamArn" --output text 2>/dev/null || \
aws dynamodb describe-table --table-name "${TASKS_TABLE}" \
  --query "Table.LatestStreamArn" --output text --region "${REGION}")
echo "  Stream ARN: ${STREAM_ARN}"

# ── Deploy WebSocket Lambda ───────────────────────────────────────────────────
echo "[3/6] Deploying WebSocket Lambda..."
BUILD_DIR="/tmp/ws-lambda-${STAGE}"
ZIP_FILE="/tmp/ws-lambda-${STAGE}.zip"
rm -rf "${BUILD_DIR}" && mkdir -p "${BUILD_DIR}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cp "${REPO_ROOT}/backend/handlers/websocket.py" "${BUILD_DIR}/handler.py"
cp "${REPO_ROOT}/backend/handlers/_base.py" "${BUILD_DIR}/_base.py"
pip install aws-xray-sdk boto3 -t "${BUILD_DIR}/" -q \
  --platform manylinux2014_x86_64 --implementation cp \
  --python-version 3.12 --only-binary=:all: 2>/dev/null || \
pip install aws-xray-sdk boto3 -t "${BUILD_DIR}/" -q
cd "${BUILD_DIR}" && zip -r "${ZIP_FILE}" . -q && cd -

LAMBDA_ROLE="arn:aws:iam::${ACCOUNT_ID}:role/NSELambdaRole"
if aws lambda get-function --function-name "${FUNC_NAME}" --region "${REGION}" > /dev/null 2>&1; then
  aws lambda update-function-code --function-name "${FUNC_NAME}" \
    --zip-file "fileb://${ZIP_FILE}" --region "${REGION}" > /dev/null
else
  aws lambda create-function --function-name "${FUNC_NAME}" \
    --runtime python3.12 --handler handler.handler \
    --zip-file "fileb://${ZIP_FILE}" --role "${LAMBDA_ROLE}" \
    --timeout 30 --memory-size 256 \
    --environment "Variables={STAGE=${STAGE},AWS_REGION=${REGION}}" \
    --region "${REGION}" > /dev/null
  aws lambda wait function-active --function-name "${FUNC_NAME}" --region "${REGION}"
fi
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNC_NAME}"
echo "  Lambda: ${FUNC_NAME}"

# ── Create WebSocket API ──────────────────────────────────────────────────────
echo "[4/6] Creating WebSocket API..."
API_ID=$(aws apigatewayv2 create-api \
  --name "${API_NAME}" \
  --protocol-type WEBSOCKET \
  --route-selection-expression "\$request.body.action" \
  --region "${REGION}" \
  --query "ApiId" --output text)
echo "  API ID: ${API_ID}"

# Create Lambda integration
INT_ID=$(aws apigatewayv2 create-integration \
  --api-id "${API_ID}" \
  --integration-type AWS_PROXY \
  --integration-uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations" \
  --region "${REGION}" \
  --query "IntegrationId" --output text)

for ROUTE in "\$connect" "\$disconnect" "\$default"; do
  aws apigatewayv2 create-route --api-id "${API_ID}" \
    --route-key "${ROUTE}" --target "integrations/${INT_ID}" \
    --region "${REGION}" > /dev/null
done
echo "  Routes: \$connect, \$disconnect, \$default"

# Deploy
aws apigatewayv2 create-stage --api-id "${API_ID}" \
  --stage-name "${STAGE}" --auto-deploy --region "${REGION}" > /dev/null 2>/dev/null || true

WS_URL="wss://${API_ID}.execute-api.${REGION}.amazonaws.com/${STAGE}"
MGMT_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/${STAGE}"

# Grant API Gateway invoke permission
aws lambda add-permission --function-name "${FUNC_NAME}" \
  --statement-id "ws-${STAGE}-invoke" --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*" \
  --region "${REGION}" > /dev/null 2>/dev/null || true

# Wire DynamoDB Streams to dynamo_streams Lambda
echo "[5/6] Wiring DynamoDB Streams..."
STREAMS_FUNC="nse-dynamo-streams-${STAGE}"
if [ -n "${STREAM_ARN}" ] && [ "${STREAM_ARN}" != "None" ]; then
  aws lambda create-event-source-mapping \
    --function-name "${STREAMS_FUNC}" \
    --event-source-arn "${STREAM_ARN}" \
    --starting-position LATEST \
    --batch-size 10 \
    --region "${REGION}" > /dev/null 2>/dev/null || \
  echo "  (DynamoDB Streams mapping already exists or ${STREAMS_FUNC} not deployed yet)"
fi

# Save to SSM
echo "[6/6] Saving to SSM..."
aws ssm put-parameter --name "/nse/${STAGE}/websocket-url" \
  --value "${WS_URL}" --type String --overwrite --region "${REGION}" > /dev/null
aws ssm put-parameter --name "/nse/${STAGE}/websocket-endpoint" \
  --value "${MGMT_URL}" --type String --overwrite --region "${REGION}" > /dev/null
aws ssm put-parameter --name "/nse/${STAGE}/websocket-api-id" \
  --value "${API_ID}" --type String --overwrite --region "${REGION}" > /dev/null

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  WebSocket URL: ${WS_URL}"
echo "  Connect: wscat -c '${WS_URL}?user_id=<id>'"
echo "  Subscribe: {\"action\":\"subscribe\",\"job_id\":\"<uuid>\"}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
rm -rf "${BUILD_DIR}"

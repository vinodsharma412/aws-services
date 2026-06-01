#!/bin/bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  API Gateway HTTP API — Lambda integration (fully serverless, no EC2)
#
#  Architecture:
#    Browser → API Gateway HTTP API → Lambda nse-api-{stage}
#
#  Two stages, two APIs (isolated):
#    staging  →  nse-api-staging  (auto-deploys on every push to develop)
#    prod     →  nse-api-prod     (requires manual approval in GitHub)
#
#  Each API gets:
#    - Its own HTTP API
#    - A $default stage with auto-deploy enabled
#    - Lambda proxy integration (ANY /{proxy+})
#    - CORS headers pre-configured
#    - Throttling: 20 req/s sustained, 50 burst (free tier friendly)
#    - Access logs to CloudWatch
#
#  Usage:
#    bash infrastructure/scripts/api_gateway_setup.sh staging
#    bash infrastructure/scripts/api_gateway_setup.sh prod
#
#  Prerequisites:
#    - Lambda function already deployed:
#        bash infrastructure/lambda/api/deploy.sh <stage>
#    - AWS CLI configured
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

set -e

STAGE="${1:?Usage: $0 <stage>   e.g.  $0 staging  or  $0 prod}"
REGION="ap-south-1"
API_NAME="nse-api-${STAGE}"
FUNC_NAME="nse-api-${STAGE}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNC_NAME}"
LOG_GROUP="/aws/apigateway/${API_NAME}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  API Gateway setup: ${API_NAME}"
echo "  Stage: ${STAGE}"
echo "  Lambda: ${FUNC_NAME}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Verify Lambda exists ──────────────────────────────────────────────────────
if ! aws lambda get-function --function-name "${FUNC_NAME}" \
   --region "${REGION}" > /dev/null 2>&1; then
  echo "ERROR: Lambda ${FUNC_NAME} does not exist."
  echo "  Run first: bash infrastructure/lambda/api/deploy.sh ${STAGE}"
  exit 1
fi
echo "[0/6] Lambda ${FUNC_NAME} verified ✓"

# ── Create CloudWatch log group ───────────────────────────────────────────────
echo "[1/6] Creating CloudWatch log group..."
aws logs create-log-group --log-group-name "${LOG_GROUP}" \
  --region "${REGION}" 2>/dev/null || true
aws logs put-retention-policy --log-group-name "${LOG_GROUP}" \
  --retention-in-days 30 --region "${REGION}"
LOG_GROUP_ARN="arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}"

# ── Create HTTP API ───────────────────────────────────────────────────────────
echo "[2/6] Creating HTTP API..."

# Check for existing API with same name
EXISTING_API=$(aws apigatewayv2 get-apis --region "${REGION}" \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text 2>/dev/null || echo "")

if [ -n "${EXISTING_API}" ] && [ "${EXISTING_API}" != "None" ]; then
  API_ID="${EXISTING_API}"
  echo "  Using existing API: ${API_ID}"
else
  API_ID=$(aws apigatewayv2 create-api \
    --name "${API_NAME}" \
    --protocol-type HTTP \
    --description "NSE Stock Dashboard ${STAGE} — FastAPI via Mangum on Lambda" \
    --cors-configuration \
      AllowOrigins='["*"]',AllowMethods='["GET","POST","PUT","DELETE","OPTIONS"]',AllowHeaders='["Authorization","Content-Type","Accept"]',MaxAge=300 \
    --region "${REGION}" \
    --query "ApiId" --output text)
  echo "  Created API: ${API_ID}"
fi

# ── Create Lambda integration ─────────────────────────────────────────────────
echo "[3/6] Creating Lambda proxy integration..."

INTEGRATION_ID=$(aws apigatewayv2 create-integration \
  --api-id "${API_ID}" \
  --integration-type AWS_PROXY \
  --integration-subtype Lambda-InvokeFunction \
  --credentials-arn "arn:aws:iam::${ACCOUNT_ID}:role/NSEApiGatewayRole" \
  --request-parameters 'IntegrationParameters={"lambda:path": "2015-03-31/functions/'${LAMBDA_ARN}'/invocations"}' \
  --payload-format-version "2.0" \
  --region "${REGION}" \
  --query "IntegrationId" --output text 2>/dev/null || \
aws apigatewayv2 create-integration \
  --api-id "${API_ID}" \
  --integration-type AWS_PROXY \
  --integration-uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations" \
  --payload-format-version "2.0" \
  --region "${REGION}" \
  --query "IntegrationId" --output text)

echo "  Integration: ${INTEGRATION_ID}"

# ── Create catch-all route ────────────────────────────────────────────────────
echo "[4/6] Creating routes..."
aws apigatewayv2 create-route \
  --api-id "${API_ID}" \
  --route-key "ANY /{proxy+}" \
  --target "integrations/${INTEGRATION_ID}" \
  --region "${REGION}" > /dev/null 2>/dev/null || true

aws apigatewayv2 create-route \
  --api-id "${API_ID}" \
  --route-key "\$default" \
  --target "integrations/${INTEGRATION_ID}" \
  --region "${REGION}" > /dev/null 2>/dev/null || true
echo "  Routes: ANY /{proxy+}  +  \$default"

# ── Deploy $default stage with access logging ─────────────────────────────────
echo "[5/6] Creating \$default stage..."
aws apigatewayv2 create-stage \
  --api-id "${API_ID}" \
  --stage-name "\$default" \
  --auto-deploy \
  --access-log-settings "DestinationArn=${LOG_GROUP_ARN},Format='{\"requestId\":\"\$context.requestId\",\"ip\":\"\$context.identity.sourceIp\",\"requestTime\":\"\$context.requestTime\",\"httpMethod\":\"\$context.httpMethod\",\"routeKey\":\"\$context.routeKey\",\"status\":\"\$context.status\",\"responseLength\":\"\$context.responseLength\",\"integrationError\":\"\$context.integrationErrorMessage\"}'" \
  --default-route-settings "ThrottlingBurstLimit=50,ThrottlingRateLimit=20" \
  --region "${REGION}" > /dev/null 2>/dev/null || \
aws apigatewayv2 update-stage \
  --api-id "${API_ID}" \
  --stage-name "\$default" \
  --auto-deploy \
  --default-route-settings "ThrottlingBurstLimit=50,ThrottlingRateLimit=20" \
  --region "${REGION}" > /dev/null

# ── Grant API Gateway permission to invoke Lambda ─────────────────────────────
echo "[6/6] Granting invoke permission to API Gateway..."
aws lambda add-permission \
  --function-name "${FUNC_NAME}" \
  --statement-id "apigateway-${STAGE}-invoke" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*" \
  --region "${REGION}" > /dev/null 2>/dev/null || true

# ── Get invoke URL ────────────────────────────────────────────────────────────
INVOKE_URL=$(aws apigatewayv2 get-api \
  --api-id "${API_ID}" \
  --region "${REGION}" \
  --query "ApiEndpoint" --output text)

# Save config to SSM for CI/CD to reference
aws ssm put-parameter \
  --name "/nse/${STAGE}/api-gateway-id" \
  --value "${API_ID}" \
  --type String \
  --overwrite \
  --region "${REGION}" > /dev/null
aws ssm put-parameter \
  --name "/nse/${STAGE}/api-gateway-url" \
  --value "${INVOKE_URL}" \
  --type String \
  --overwrite \
  --region "${REGION}" > /dev/null

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  API Gateway: ${API_NAME}  (${API_ID})"
echo "  Stage: ${STAGE}"
echo ""
echo "  API URL (use in React frontend):"
echo "  ${INVOKE_URL}"
echo ""
echo "  Full API base:"
echo "  ${INVOKE_URL}/api/v1"
echo ""
echo "  Health check:"
echo "  curl ${INVOKE_URL}/api/v1/health/"
echo ""
echo "  Saved to SSM:"
echo "  /nse/${STAGE}/api-gateway-id"
echo "  /nse/${STAGE}/api-gateway-url"
echo ""
echo "  Add to GitHub Secrets:"
echo "  ${STAGE^^}_API_URL = ${INVOKE_URL}/api/v1"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

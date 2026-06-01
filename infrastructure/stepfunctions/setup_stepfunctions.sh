#!/bin/bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Step Functions — scraping job orchestration with parallel Map state
#
#  Pattern: Fan-out + Fan-in
#    POST /scraping/jobs
#      → Start Step Functions execution {job_id, tasks:[{task_id, asin},...]}
#      → Map state fans out to N parallel Lambda invocations
#      → Each Lambda scrapes one ASIN, updates DynamoDB
#      → When all complete → SNS notification
#
#  Free tier: 4,000 state transitions/month FOREVER
#  A 10-ASIN job = ~30 transitions. So ~130 free jobs/month.
#
#  Type: STANDARD (up to 1 year execution, async)
#
#  Usage:
#    bash infrastructure/stepfunctions/setup_stepfunctions.sh staging
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
set -e
STAGE="${1:?Usage: $0 <stage>}"
REGION="ap-south-1"
SFN_NAME="nse-scraping-${STAGE}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

WORKER_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:nse-scraping-worker-${STAGE}"
SNS_ARN=$(aws ssm get-parameter --name "/nse/${STAGE}/sns-alerts-arn" \
  --query "Parameter.Value" --output text --region "${REGION}" 2>/dev/null || echo "")

SFN_ROLE="arn:aws:iam::${ACCOUNT_ID}:role/NSEStepFunctionsRole"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step Functions: ${SFN_NAME}"
echo "  Worker Lambda:  ${WORKER_ARN}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Create IAM role for Step Functions
echo "[1/4] Creating IAM role for Step Functions..."
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"states.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "NSEStepFunctionsRole" \
  --assume-role-policy-document "${TRUST}" > /dev/null 2>/dev/null || true

POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"lambda:InvokeFunction\"],\"Resource\":\"arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:nse-scraping-worker-*\"},{\"Effect\":\"Allow\",\"Action\":[\"sns:Publish\"],\"Resource\":\"*\"},{\"Effect\":\"Allow\",\"Action\":[\"xray:PutTraceSegments\",\"xray:PutTelemetryRecords\"],\"Resource\":\"*\"},{\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogDelivery\",\"logs:PutLogEvents\"],\"Resource\":\"*\"}]}"
aws iam put-role-policy --role-name "NSEStepFunctionsRole" \
  --policy-name "NSEStepFunctionsPolicy" \
  --policy-document "${POLICY}" > /dev/null
echo "  Role: NSEStepFunctionsRole"

# Substitute ARNs in state machine definition
echo "[2/4] Building state machine definition..."
DEFINITION=$(sed \
  -e "s|\${ScrapingWorkerArn}|${WORKER_ARN}|g" \
  -e "s|\${AlertsTopicArn}|${SNS_ARN}|g" \
  "${DIR}/scraping_workflow.json")

# Create log group for Step Functions
aws logs create-log-group \
  --log-group-name "/aws/states/nse-scraping-${STAGE}" \
  --region "${REGION}" 2>/dev/null || true

# Create or update state machine
echo "[3/4] Creating/updating state machine..."
EXISTING=$(aws stepfunctions list-state-machines --region "${REGION}" \
  --query "stateMachines[?name=='${SFN_NAME}'].stateMachineArn | [0]" \
  --output text 2>/dev/null || echo "")

if [ -n "${EXISTING}" ] && [ "${EXISTING}" != "None" ]; then
  aws stepfunctions update-state-machine \
    --state-machine-arn "${EXISTING}" \
    --definition "${DEFINITION}" \
    --role-arn "${SFN_ROLE}" \
    --region "${REGION}" > /dev/null
  SFN_ARN="${EXISTING}"
  echo "  Updated: ${SFN_ARN}"
else
  SFN_ARN=$(aws stepfunctions create-state-machine \
    --name "${SFN_NAME}" \
    --definition "${DEFINITION}" \
    --role-arn "${SFN_ROLE}" \
    --type STANDARD \
    --tracing-config enabled=true \
    --region "${REGION}" \
    --query "stateMachineArn" --output text)
  echo "  Created: ${SFN_ARN}"
fi

# Save ARN to SSM
echo "[4/4] Saving ARN to SSM..."
aws ssm put-parameter --name "/nse/${STAGE}/stepfunctions-scraping-arn" \
  --value "${SFN_ARN}" --type String --overwrite --region "${REGION}" > /dev/null

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step Functions ARN: ${SFN_ARN}"
echo "  Saved: /nse/${STAGE}/stepfunctions-scraping-arn"
echo ""
echo "  View executions:"
echo "  AWS Console → Step Functions → ${SFN_NAME}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

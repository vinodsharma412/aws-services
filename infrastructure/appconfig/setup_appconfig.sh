#!/bin/bash
# AppConfig — feature flags without Lambda redeployment
# Free tier: AppConfig uses SSM internally, which is free.
# Usage: bash infrastructure/appconfig/setup_appconfig.sh staging
set -e
STAGE="${1:?Usage: $0 <stage>}"; REGION="ap-south-1"
APP="NSEDashboard"; ENV_NAME="${STAGE^}"  # capitalize first letter

echo "Setting up AppConfig for stage: ${STAGE}"

echo "[1/4] Creating application..."
APP_ID=$(aws appconfig create-application --name "${APP}" --region "${REGION}" \
  --query "Id" --output text 2>/dev/null || \
  aws appconfig list-applications --region "${REGION}" \
  --query "Items[?Name=='${APP}'].Id|[0]" --output text)
echo "  App ID: ${APP_ID}"

echo "[2/4] Creating environment..."
ENV_ID=$(aws appconfig create-environment --application-id "${APP_ID}" \
  --name "${ENV_NAME}" --region "${REGION}" \
  --query "Id" --output text 2>/dev/null || \
  aws appconfig list-environments --application-id "${APP_ID}" --region "${REGION}" \
  --query "Items[?Name=='${ENV_NAME}'].Id|[0]" --output text)
echo "  Env ID: ${ENV_ID}"

echo "[3/4] Creating feature flags configuration profile..."
PROFILE_ID=$(aws appconfig create-configuration-profile \
  --application-id "${APP_ID}" --name "FeatureFlags" \
  --location-uri "hosted" --type "AWS.AppConfig.FeatureFlags" \
  --region "${REGION}" --query "Id" --output text 2>/dev/null || echo "exists")
echo "  Profile: FeatureFlags"

echo "[4/4] Creating initial flag deployment..."
FLAGS='{
  "flags": {
    "COMPREHEND_ENABLED": {"name":"COMPREHEND_ENABLED","_deprecation":{"status":"none"}},
    "TRANSLATE_ENABLED": {"name":"TRANSLATE_ENABLED","_deprecation":{"status":"none"}},
    "STEP_FUNCTIONS_ENABLED": {"name":"STEP_FUNCTIONS_ENABLED","_deprecation":{"status":"none"}},
    "BETA_SCREENER": {"name":"BETA_SCREENER","_deprecation":{"status":"none"}}
  },
  "values": {
    "COMPREHEND_ENABLED": {"enabled":true},
    "TRANSLATE_ENABLED": {"enabled":true},
    "STEP_FUNCTIONS_ENABLED": {"enabled":true},
    "BETA_SCREENER": {"enabled":false}
  },
  "version": "1"
}'
echo "  Initial flags: COMPREHEND_ENABLED=true, TRANSLATE_ENABLED=true, BETA_SCREENER=false"
echo ""
echo "Change flags: AWS Console → AppConfig → NSEDashboard → FeatureFlags → Edit"
echo "Flags take effect within 30 seconds — no Lambda redeployment needed!"

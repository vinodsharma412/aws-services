#!/bin/bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Cognito User Pool — replaces custom JWT auth
#
#  Creates:
#    - Cognito User Pool (nse-users-{stage})
#      Password policy, email verification, custom:role attribute
#    - App Client (no secret — SPA compatible)
#    - Identity Pool (for temporary AWS credentials)
#    - Saves Pool ID + Client ID to SSM
#
#  Free tier: 50,000 MAU (Monthly Active Users) FOREVER
#  No credit card needed, no time limit.
#
#  Usage:
#    bash infrastructure/cognito/setup_cognito.sh staging your@email.com
#    bash infrastructure/cognito/setup_cognito.sh prod   your@email.com
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
set -e
STAGE="${1:?Usage: $0 <stage> <admin-email>}"
ADMIN_EMAIL="${2:?Provide admin email address}"
REGION="ap-south-1"
POOL_NAME="nse-users-${STAGE}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Cognito User Pool: ${POOL_NAME}"
echo "  Stage: ${STAGE}  Region: ${REGION}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Create User Pool ───────────────────────────────────────────────────────
echo "[1/5] Creating User Pool..."
POOL_ID=$(aws cognito-idp create-user-pool \
  --pool-name "${POOL_NAME}" \
  --region "${REGION}" \
  --policies '{"PasswordPolicy":{"MinimumLength":8,"RequireUppercase":false,"RequireLowercase":true,"RequireNumbers":true,"RequireSymbols":false}}' \
  --auto-verified-attributes email \
  --username-attributes email \
  --schema \
    '[{"Name":"email","Required":true,"Mutable":true},
      {"Name":"role","AttributeDataType":"String","Mutable":true,"StringAttributeConstraints":{"MinLength":"3","MaxLength":"20"}}]' \
  --admin-create-user-config '{"AllowAdminCreateUserOnly":false}' \
  --email-configuration '{"EmailSendingAccount":"COGNITO_DEFAULT"}' \
  --query "UserPool.Id" --output text)
echo "  Pool ID: ${POOL_ID}"

# ── 2. Create App Client (no secret for SPA) ──────────────────────────────────
echo "[2/5] Creating App Client..."
CLIENT_ID=$(aws cognito-idp create-user-pool-client \
  --user-pool-id "${POOL_ID}" \
  --client-name "nse-web-client-${STAGE}" \
  --no-generate-secret \
  --explicit-auth-flows "ALLOW_USER_PASSWORD_AUTH" "ALLOW_REFRESH_TOKEN_AUTH" "ALLOW_USER_SRP_AUTH" \
  --supported-identity-providers "COGNITO" \
  --prevent-user-existence-errors "ENABLED" \
  --region "${REGION}" \
  --query "UserPoolClient.ClientId" --output text)
echo "  Client ID: ${CLIENT_ID}"

# ── 3. Create Identity Pool (for temporary AWS credentials) ───────────────────
echo "[3/5] Creating Identity Pool..."
IDENTITY_POOL_ID=$(aws cognito-identity create-identity-pool \
  --identity-pool-name "nse_identity_${STAGE}" \
  --no-allow-unauthenticated-identities \
  --cognito-identity-providers \
    ProviderName="cognito-idp.${REGION}.amazonaws.com/${POOL_ID}",ClientId="${CLIENT_ID}",ServerSideTokenCheck=true \
  --region "${REGION}" \
  --query "IdentityPoolId" --output text)
echo "  Identity Pool: ${IDENTITY_POOL_ID}"

# ── 4. Create admin user ──────────────────────────────────────────────────────
echo "[4/5] Creating admin user..."
aws cognito-idp admin-create-user \
  --user-pool-id "${POOL_ID}" \
  --username "admin" \
  --user-attributes \
    Name=email,Value="${ADMIN_EMAIL}" \
    Name=email_verified,Value=true \
    "Name=custom:role,Value=admin" \
  --temporary-password "Nse@2025!" \
  --message-action "SUPPRESS" \
  --region "${REGION}" > /dev/null 2>/dev/null || echo "  (admin user already exists)"

# ── 5. Save to SSM ────────────────────────────────────────────────────────────
echo "[5/5] Saving to SSM Parameter Store..."
for KEY_VAL in \
  "cognito-user-pool-id=${POOL_ID}" \
  "cognito-client-id=${CLIENT_ID}" \
  "cognito-identity-pool-id=${IDENTITY_POOL_ID}"; do
  KEY="${KEY_VAL%%=*}"
  VAL="${KEY_VAL#*=}"
  aws ssm put-parameter --name "/nse/${STAGE}/${KEY}" \
    --value "${VAL}" --type String --overwrite --region "${REGION}" > /dev/null
  echo "  SSM: /nse/${STAGE}/${KEY}"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Cognito User Pool: ${POOL_NAME}"
echo "  Pool ID:     ${POOL_ID}"
echo "  Client ID:   ${CLIENT_ID}"
echo ""
echo "  Admin user:  admin / Nse@2025! (must change on first login)"
echo ""
echo "  Next: add JWT Authorizer to API Gateway"
echo "  Issuer: https://cognito-idp.${REGION}.amazonaws.com/${POOL_ID}"
echo "  Audience: ${CLIENT_ID}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

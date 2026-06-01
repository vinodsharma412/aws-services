#!/bin/bash
# CodeBuild + CodePipeline — AWS-native CI/CD (alternative to GitHub Actions)
# Free tier: 100 build minutes/month, 1 active pipeline/month
# Usage: bash infrastructure/codebuild/setup_codebuild.sh staging
set -e
STAGE="${1:?Usage: $0 <stage>}"; REGION="ap-south-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
PROJECT_NAME="nse-build-${STAGE}"

echo "Setting up CodeBuild for stage: ${STAGE}"

# IAM role for CodeBuild
echo "[1/3] Creating CodeBuild IAM role..."
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "NSECodeBuildRole" \
  --assume-role-policy-document "${TRUST}" > /dev/null 2>/dev/null || true
aws iam attach-role-policy --role-name "NSECodeBuildRole" \
  --policy-arn "arn:aws:iam::aws:policy/PowerUserAccess" > /dev/null 2>/dev/null || true

# Create buildspec.yml content in S3
echo "[2/3] Creating CodeBuild project..."

BUILDSPEC=$(cat << 'BUILDSPEC'
version: 0.2
phases:
  install:
    runtime-versions:
      python: 3.12
      nodejs: 20
    commands:
      - pip install ruff -q
      - pip install -r backend/requirements.txt -q
      - cd frontend && npm ci && cd ..
  pre_build:
    commands:
      - ruff check backend/handlers/ backend/app/
  build:
    commands:
      - cd frontend && REACT_APP_API_URL=$STAGING_API_URL npm run build && cd ..
      - mkdir -p /tmp/lambda-pkg
      - pip install -r backend/requirements.txt -t /tmp/lambda-pkg/ -q
      - cp -r backend/handlers backend/app /tmp/lambda-pkg/
      - cd /tmp/lambda-pkg && zip -r /tmp/api-lambda.zip . -q
  post_build:
    commands:
      - aws lambda update-function-code --function-name nse-api-$STAGE --zip-file fileb:///tmp/api-lambda.zip
      - aws s3 sync frontend/build/ s3://$S3_FRONTEND_BUCKET/$STAGE/
artifacts:
  files:
    - /tmp/api-lambda.zip
BUILDSPEC
)

aws codebuild create-project \
  --name "${PROJECT_NAME}" \
  --source "type=GITHUB,location=https://github.com/yourusername/aws-services,buildspec=${BUILDSPEC}" \
  --artifacts "type=NO_ARTIFACTS" \
  --environment "type=LINUX_CONTAINER,computeType=BUILD_GENERAL1_SMALL,image=aws/codebuild/standard:7.0,environmentVariables=[{name=STAGE,value=${STAGE}},{name=AWS_DEFAULT_REGION,value=${REGION}}]" \
  --service-role "arn:aws:iam::${ACCOUNT_ID}:role/NSECodeBuildRole" \
  --region "${REGION}" > /dev/null 2>/dev/null && \
  echo "  Created: ${PROJECT_NAME}" || echo "  Already exists: ${PROJECT_NAME}"

echo "[3/3] CodeBuild project ready."
echo ""
echo "  Trigger a build:"
echo "  aws codebuild start-build --project-name ${PROJECT_NAME} --region ${REGION}"
echo ""
echo "  View in console: AWS → CodeBuild → Build projects → ${PROJECT_NAME}"

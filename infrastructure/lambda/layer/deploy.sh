#!/bin/bash
# Deploy the NSE shared Lambda Layer.
# Contains: aws_xray_sdk, utils/ (appconfig, xray_helper, response)
# All Lambda functions attach this layer to share common code.
#
# Usage: bash infrastructure/lambda/layer/deploy.sh staging
set -e
STAGE="${1:?Usage: $0 <stage>}"
REGION="ap-south-1"
LAYER_NAME="nse-shared-utils"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${DIR}/build"
ZIP_FILE="${DIR}/layer.zip"

echo "Building Lambda Layer: ${LAYER_NAME}"
rm -rf "${BUILD_DIR}" && mkdir -p "${BUILD_DIR}/python"
cp -r "${DIR}/python/." "${BUILD_DIR}/python/"
pip install aws-xray-sdk -t "${BUILD_DIR}/python/" -q \
  --platform manylinux2014_x86_64 --implementation cp \
  --python-version 3.12 --only-binary=:all: 2>/dev/null || \
pip install aws-xray-sdk -t "${BUILD_DIR}/python/" -q
cd "${BUILD_DIR}" && zip -r "${ZIP_FILE}" python/ -q && cd -
echo "Layer size: $(du -sh "${ZIP_FILE}" | cut -f1)"

LAYER_ARN=$(aws lambda publish-layer-version \
  --layer-name "${LAYER_NAME}" \
  --description "NSE shared utils: X-Ray, AppConfig, response helpers" \
  --zip-file "fileb://${ZIP_FILE}" \
  --compatible-runtimes python3.12 \
  --region "${REGION}" \
  --query "LayerVersionArn" --output text)

echo "Layer published: ${LAYER_ARN}"
aws ssm put-parameter --name "/nse/${STAGE}/shared-layer-arn" \
  --value "${LAYER_ARN}" --type String --overwrite --region "${REGION}" > /dev/null
echo "ARN saved to SSM: /nse/${STAGE}/shared-layer-arn"
rm -rf "${BUILD_DIR}"

# Developer Guide — Daily Workflow

## Local development

```bash
# Install dependencies
pip install -r backend/requirements.txt
cd frontend && npm install

# Start backend (uses staging DynamoDB tables via AWS profile)
export AWS_PROFILE=aws-staging
cd backend && STAGE=staging uvicorn app.main:app --reload --port 9000
# → http://localhost:9000/docs

# Start frontend
cd frontend && npm start
# → http://localhost:3000
```

Local dev uses your `~/.aws` profile to access the **staging** account DynamoDB tables.
Never run local dev against prod account credentials.

## Make a code change

```bash
# Edit a Lambda handler
vim backend/handlers/stocks.py

# Lint
make lint

# Test locally at localhost:9000

# Push to staging
git add backend/handlers/stocks.py
git commit -m "feat: add RSI divergence signal"
git push origin develop

# → GitHub Actions: lint → build → deploy to aws-staging (~3 min)
# → Test on staging: curl https://<STAGING_API_URL>/api/v1/stocks/basic/RELIANCE.NS
# → Approve in GitHub to deploy to aws-prod
```

## Lambda handler pattern

Each handler file handles all routes for one domain. No framework — pure Python:

```python
# backend/handlers/my_feature.py
from aws_xray_sdk.core import patch_all, xray_recorder
from handlers._base import ok, bad_request, get_method, get_path, get_body

patch_all()  # auto-trace all boto3 calls

@xray_recorder.capture("my_feature")
def handler(event, context):
    method = get_method(event)
    path = get_path(event)
    body = get_body(event)

    if method == "GET" and path.endswith("/my-route"):
        return ok({"result": "data"})

    if method == "POST":
        data = body.get("field")
        # ... do work
        return ok({"created": True}, 201)

    return ok({"detail": "Route not found"}, 404)
```

Register the handler in `infrastructure/scripts/api_gateway_setup.sh` as a new route.

## Environment variables in Lambda

Set via Lambda console or update the deploy script. Read in Python:

```python
import os
STAGE = os.environ.get("STAGE", "staging")
```

Secrets are always in SSM, never in env vars:

```python
import boto3
ssm = boto3.client("ssm")
secret = ssm.get_parameter(Name=f"/nse/{STAGE}/my-secret", WithDecryption=True)["Parameter"]["Value"]
```

## Use AppConfig feature flags

```python
from utils.appconfig import get_flag, is_enabled

if is_enabled("COMPREHEND_ENABLED"):
    score = comprehend_sentiment(text)
else:
    score = keyword_sentiment(text)
```

Change flag in AWS Console → AppConfig → NSEDashboard → FeatureFlags.
Takes effect within 30 seconds. No redeployment.

## View logs

```bash
# Live staging API logs
make logs STAGE=staging
export AWS_PROFILE=aws-staging && make logs STAGE=staging

# Live prod logs
export AWS_PROFILE=aws-prod && make logs STAGE=prod

# Search for errors (last 1 hour)
AWS_PROFILE=aws-staging aws logs filter-log-events \
  --log-group-name /aws/lambda/nse-api-staging \
  --filter-pattern "ERROR" \
  --start-time $(($(date +%s) - 3600))000 \
  --region ap-south-1

# X-Ray traces (open in browser)
make xray
```

## Health check

```bash
make health
# → Staging health: {"status":"ok","stage":"staging"} ✓
# → Prod health: {"status":"ok","stage":"prod"} ✓
```

## Debugging a Lambda function

```bash
# View last 100 lines
AWS_PROFILE=aws-staging aws logs tail \
  /aws/lambda/nse-api-staging \
  --region ap-south-1

# Test invoke directly (bypasses API Gateway)
AWS_PROFILE=aws-staging aws lambda invoke \
  --function-name nse-api-staging \
  --payload '{"rawPath":"/api/v1/health","requestContext":{"http":{"method":"GET"}}}' \
  --region ap-south-1 \
  /tmp/response.json && cat /tmp/response.json
```

## DynamoDB quick inspection

```bash
# List tables in staging account
AWS_PROFILE=aws-staging aws dynamodb list-tables --region ap-south-1

# Find a user
AWS_PROFILE=aws-staging aws dynamodb query \
  --table-name users \
  --index-name username-index \
  --key-condition-expression "username = :u" \
  --expression-attribute-values '{":u":{"S":"admin"}}' \
  --region ap-south-1

# Count items in a table
AWS_PROFILE=aws-staging aws dynamodb scan \
  --table-name scraping_jobs \
  --select COUNT \
  --region ap-south-1
```

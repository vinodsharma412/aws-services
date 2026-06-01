# Developer Guide — Serverless NSE Stock Dashboard

## Local development

```bash
# Backend (FastAPI)
cd backend
pip install -r requirements.txt
STAGE=staging uvicorn app.main:app --reload --port 9000
# → http://localhost:9000/docs  (Swagger UI)

# Frontend (React)
cd frontend
npm install && npm start
# → http://localhost:3000

# Env file for local dev
cp backend/.env.example backend/.env
# Set STAGE=staging (reads DynamoDB staging tables via your AWS profile)
```

Local development uses your `~/.aws/credentials` to access AWS (DynamoDB, S3, SQS).
No Lambda needed locally — FastAPI runs directly via uvicorn.

---

## How Lambda + Mangum works

The key file is `backend/lambda_handler.py`:

```python
from mangum import Mangum
from app.main import app

handler = Mangum(app, lifespan="off")
```

When API Gateway receives a request, it calls `lambda_handler.handler(event, context)`.
Mangum translates the API Gateway HTTP event into a standard ASGI request.
FastAPI processes it exactly as if uvicorn sent it.
Mangum then converts the ASGI response back into the API Gateway format.

Your FastAPI code is completely unchanged — just add `lambda_handler.py`.

---

## Project layout

```
backend/
├── app/
│   ├── main.py                  FastAPI app factory (CORS, middleware, router)
│   ├── config.py                Settings + SSM secret loading (lru_cache)
│   ├── dependencies.py          JWT decode → DynamoDB user lookup
│   ├── api/v1/
│   │   ├── router.py            Assembles all sub-routers
│   │   └── endpoints/
│   │       ├── auth.py          POST /auth/token → JWT
│   │       ├── users.py         CRUD + S3 avatar upload
│   │       ├── stocks.py        yfinance analysis, portfolio, watchlist
│   │       ├── scraping.py      Amazon scraping jobs (polling, no SSE)
│   │       ├── menu.py          Navigation menu CRUD
│   │       └── health.py        GET /health/ → {"status":"ok"}
│   ├── crud/
│   │   ├── user_dynamo.py       DynamoDB users table operations
│   │   ├── stock_dynamo.py      Transactions + watchlist operations
│   │   └── scraping_dynamo.py   Scraping jobs + tasks operations
│   ├── services/
│   │   ├── auth_service.py      Login validation → JWT creation
│   │   ├── stock_service.py     yfinance fetch + analysis
│   │   ├── sentiment_service.py Bing news → Comprehend → score
│   │   ├── scraping_queue.py    SQS enqueue/receive/delete
│   │   └── s3_storage.py        Avatar upload/delete
│   ├── schemas/                 Pydantic models (request/response)
│   └── core/
│       ├── security.py          bcrypt + JWT encode/decode
│       └── roles.py             ADMIN/MANAGER/VIEWER role guards
├── lambda_handler.py            Mangum entry point for Lambda
└── requirements.txt
```

---

## Adding a new API endpoint

1. Add route in the appropriate `endpoints/` file:
```python
@router.get("/new-route")
def my_new_endpoint(current_user: dict = Depends(get_current_active_user)):
    return {"hello": current_user["username"]}
```

2. If it needs DynamoDB, add a function in `crud/`:
```python
def get_my_data(user_id: str) -> list:
    resp = dynamo_table.query(...)
    return resp.get("Items", [])
```

3. Push to develop → staging auto-deploys (~2 min) → approve prod.

No restart needed. Lambda loads your new code on the next invocation.

---

## Debugging

### Check what Lambda is executing

```bash
# Last 100 log lines from staging API
aws logs tail /aws/lambda/nse-api-staging --region ap-south-1

# Live logs while making API calls
make logs STAGE=staging
# (in another terminal) curl https://<staging-url>/api/v1/health/
```

### Test an endpoint directly

```bash
# Get a token
TOKEN=$(curl -s -X POST https://<api-url>/api/v1/auth/token \
  -d "username=admin&password=<pass>" | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

# Call an endpoint
curl -H "Authorization: Bearer $TOKEN" https://<api-url>/api/v1/users/me
```

### Check DynamoDB for a user

```bash
aws dynamodb scan \
  --table-name stg_users \
  --filter-expression "username = :u" \
  --expression-attribute-values '{":u":{"S":"admin"}}' \
  --region ap-south-1
```

### Check SQS queue depth

```bash
aws sqs get-queue-attributes \
  --queue-url <queue-url> \
  --attribute-names ApproximateNumberOfMessages \
  --region ap-south-1
```

---

## Common issues

### Lambda timeout (30 s)

Stock analysis (`/stocks/analyse/{symbol}`) calls yfinance and news APIs which can take 10-20 s.
If it hits 30 s, increase Lambda timeout:
```bash
aws lambda update-function-configuration \
  --function-name nse-api-staging \
  --timeout 60 \
  --region ap-south-1
```

### Cold start latency

First Lambda call after idle takes 3-5 s (cold start).
Subsequent calls within ~5 minutes reuse the same container (warm).

To reduce cold starts:
- Keep package size small (remove unused deps)
- Use Lambda Provisioned Concurrency (not free tier)

### Package too large (>250 MB)

Check what's large:
```bash
du -sh build_staging/* | sort -rh | head -20
```

Solutions:
- Use AWS-managed layers (pandas, numpy already handled)
- Remove unused packages from requirements.txt
- Use `--exclude` flags in pip install

### DynamoDB table not found

Make sure you ran `make dynamo-tables STAGE=staging` before deploying.
Check with:
```bash
aws dynamodb list-tables --region ap-south-1 | grep nse
```

---

## Environment variables reference

Set on Lambda (in deploy scripts or CI/CD):

| Variable | Description | Where set |
|---|---|---|
| `STAGE` | `staging` or `prod` | CI/CD env var |
| `AWS_REGION` | `ap-south-1` | CI/CD env var |
| `SECRET_KEY` | JWT signing key | SSM `/nse/{stage}/jwt-secret` |
| `S3_ASSETS_BUCKET` | Avatar bucket name | SSM `/nse/{stage}/s3-assets-bucket` |
| `SQS_SCRAPING_JOBS_URL` | SQS queue URL | SSM `/nse/{stage}/sqs-jobs-url` |
| `SNS_ALERTS_ARN` | SNS topic ARN | SSM `/nse/{stage}/sns-alerts-arn` |
| `COMPREHEND_ENABLED` | `true`/`false` | Lambda env var |

All empty vars are auto-loaded from SSM at Lambda cold start via `config.py:get_settings()`.

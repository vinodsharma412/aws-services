# NSE Stock Dashboard — Fully Serverless AWS

A full-stack stock market analysis platform built entirely on **AWS free-tier services**.  
No EC2. No VMs. No servers to maintain. You push code → GitHub Actions deploys Lambda automatically.

---

## What this project covers

| Layer | Service | Free Tier |
|---|---|---|
| **API** | API Gateway HTTP API | 1M req/month forever |
| **Backend** | Lambda (Python 3.12 + FastAPI + Mangum) | 1M req + 400K GB-s/month forever |
| **Worker** | Lambda (SQS-triggered httpx scraper) | same Lambda free tier |
| **Database** | DynamoDB | 25 GB + 25 RCU/WCU forever |
| **File storage** | S3 (avatars, frontend) | 5 GB, 20K GET / 12 months |
| **CDN** | CloudFront | 1 TB transfer, 10M req / 12 months |
| **Queue** | SQS Standard | 1M req/month forever |
| **Notifications** | SNS | 1M publishes forever |
| **Secrets** | SSM Parameter Store | 10K API calls/month forever |
| **Scheduled jobs** | EventBridge | 1M events/month forever |
| **Monitoring** | CloudWatch Logs + Alarms + Dashboard | 5 GB logs, 10 alarms / 12 months |
| **Audit** | CloudTrail | 1 free trail forever |
| **CI/CD** | GitHub Actions | free for public repos |

**Estimated monthly cost: $0 (free tier)**

---

## Architecture

```
                    ┌───────────────────────────────────────────┐
                    │          BROWSER (React SPA)               │
                    │   S3 static website + CloudFront CDN       │
                    └────────────────┬──────────────────────────┘
                                     │  HTTPS REST + JWT
                                     ▼
                    ┌───────────────────────────────────────────┐
                    │       API Gateway HTTP API                 │
                    │   nse-api-staging  /  nse-api-prod         │
                    │   Rate limit: 20 req/s, burst 50           │
                    └────────────────┬──────────────────────────┘
                                     │  Lambda proxy
                                     ▼
                    ┌───────────────────────────────────────────┐
                    │   Lambda: nse-api-{stage}                  │
                    │   FastAPI + Mangum (512 MB, 30 s)          │
                    │   ├── /api/v1/auth/*    JWT login          │
                    │   ├── /api/v1/users/*   user CRUD          │
                    │   ├── /api/v1/stocks/*  yfinance analysis  │
                    │   └── /api/v1/scraping/* job management    │
                    └───┬────────────┬───────────┬──────────────┘
                        │            │           │
               DynamoDB │        S3  │     SQS   │  SSM / Comprehend
                        ▼            ▼           ▼
         ┌──────────────────┐  ┌──────────┐  ┌──────────────────────┐
         │ DynamoDB tables  │  │ S3 assets│  │ SQS: scraping queue  │
         │ (12 tables)      │  │ (avatars)│  │                      │
         └──────────────────┘  └──────────┘  └──────────┬───────────┘
                                                          │ SQS trigger
                                                          ▼
                                              ┌──────────────────────┐
                                              │ Lambda: nse-scraping │
                                              │ -worker-{stage}      │
                                              │ httpx + BeautifulSoup│
                                              │ Scrapes amazon.in    │
                                              └──────────────────────┘

── Scheduled automation (EventBridge → Lambda) ──────────────────────
   Daily 3 AM    → nse-universe-refresh   downloads NSE symbol list
   Every 30 min  → nse-screener-refresh   caches top 40 screener results

── Monitoring (CloudWatch) ──────────────────────────────────────────
   Log groups:  /aws/lambda/nse-api-{stage}
                /aws/lambda/nse-scraping-worker-{stage}
                /aws/apigateway/nse-api-{stage}
   Alarms:      Lambda errors, DLQ depth, API 5xx rate, DynamoDB throttles
   Dashboard:   NSE-Operations-{stage}
```

---

## Quick Start (local development)

```bash
# 1. Clone and install
git clone <your-repo-url>
cd awsapigateway

# 2. Backend
pip install -r backend/requirements.txt
cd backend && STAGE=staging uvicorn app.main:app --reload --port 9000
# → http://localhost:9000/docs

# 3. Frontend (new terminal)
cd frontend && npm install && npm start
# → http://localhost:3000
```

---

## Deploy to AWS (one-time setup)

See [docs/02_STEP_BY_STEP_SETUP.md](docs/02_STEP_BY_STEP_SETUP.md) for full instructions.

```bash
# 1. Create IAM role for Lambda
bash infrastructure/iam/setup_lambda_role.sh

# 2. Create S3 buckets, DynamoDB tables, SQS, SNS, SSM secrets
make setup-infra STAGE=staging
make setup-infra STAGE=prod

# 3. Deploy Lambda functions
bash infrastructure/lambda/api/deploy.sh staging
bash infrastructure/lambda/api/deploy.sh prod

# 4. Wire API Gateway → Lambda
bash infrastructure/scripts/api_gateway_setup.sh staging
bash infrastructure/scripts/api_gateway_setup.sh prod

# 5. Add GitHub Secrets (from SSM output above)
#    STAGING_API_URL, PROD_API_URL, S3_FRONTEND_BUCKET
#    AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
```

After that, every push to `develop` auto-deploys staging. Prod requires a 1-click approval in GitHub.

---

## How changes get deployed

```
Developer pushes to develop
        ↓
GitHub Actions:
  1. Lint (ruff) + npm build (both stages)
  2. Package Lambda zip (pip install → zip)
  3. Deploy STAGING (auto):
        aws lambda update-function-code --zip-file ...
        aws s3 sync build/ s3://bucket/staging/
  4. Health check staging API Gateway URL ✓
  5. Deploy PROD (manual approval required in GitHub UI):
        aws lambda update-function-code --zip-file ...
        aws s3 sync build/ s3://bucket/
        aws cloudfront create-invalidation --paths "/*"
```

No SSH. No rsync. No EC2 to maintain. Lambda is updated in ~30 seconds.

---

## Monitoring with CloudWatch

```bash
# Live API logs (staging)
make logs STAGE=staging

# Live worker logs
make logs-worker STAGE=staging

# Health check both stages
make health
```

**CloudWatch Console:**
- Logs → `/aws/lambda/nse-api-staging` — every API request
- Logs → `/aws/lambda/nse-scraping-worker-staging` — every scrape
- Alarms → 6 alarms per stage (Lambda errors, SQS DLQ, API 5xx, DynamoDB throttles)
- Dashboards → `NSE-Operations-staging` and `NSE-Operations-prod`

See [docs/06_CLOUDWATCH_MONITORING.md](docs/06_CLOUDWATCH_MONITORING.md) for the full monitoring guide.

---

## Repository structure

```
awsapigateway/
├── backend/
│   ├── app/                        FastAPI application
│   │   ├── api/v1/endpoints/       Route handlers (auth, users, stocks, scraping)
│   │   ├── crud/                   DynamoDB access layer
│   │   ├── services/               Business logic (stock, sentiment, scraping)
│   │   ├── schemas/                Pydantic models
│   │   └── config.py               Settings + SSM secret loading
│   ├── lambda_handler.py           Mangum adapter (FastAPI → Lambda)
│   └── requirements.txt
│
├── frontend/
│   └── src/                        React 18 SPA
│
├── infrastructure/
│   ├── dynamodb/create_tables.py   Create all 12 DynamoDB tables
│   ├── iam/                        IAM role setup
│   ├── lambda/
│   │   ├── api/deploy.sh           Deploy API Lambda
│   │   └── scraping_worker/        SQS-triggered worker Lambda
│   ├── scripts/
│   │   ├── api_gateway_setup.sh    Wire API GW → Lambda
│   │   └── frontend_deploy.sh      Build + upload React to S3
│   ├── cloudwatch/                 Alarms + dashboards
│   ├── sqs/, sns/, ssm/            Queue, alerts, secrets
│   └── eventbridge/                Scheduled Lambda triggers
│
├── .github/workflows/deploy.yml    CI/CD pipeline
├── Makefile                        Developer commands
└── docs/                           Detailed documentation
```

---

## Documentation

| Doc | Contents |
|---|---|
| [01_ARCHITECTURE.md](docs/01_ARCHITECTURE.md) | Full system diagram, service decisions, data flows |
| [02_STEP_BY_STEP_SETUP.md](docs/02_STEP_BY_STEP_SETUP.md) | Zero-to-deployed walkthrough |
| [03_VS_CODE_SETUP.md](docs/03_VS_CODE_SETUP.md) | Local dev environment |
| [04_INTERVIEW_PREP.md](docs/04_INTERVIEW_PREP.md) | Serverless + AWS concepts for interviews |
| [05_DEVELOPER_GUIDE.md](docs/05_DEVELOPER_GUIDE.md) | Day-to-day development workflow |
| [06_CLOUDWATCH_MONITORING.md](docs/06_CLOUDWATCH_MONITORING.md) | Logs, alarms, dashboards |
| [07_STAGING_PROD_WORKFLOW.md](docs/07_STAGING_PROD_WORKFLOW.md) | How staging → prod promotion works |

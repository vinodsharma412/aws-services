# NSE Stock Dashboard — Multi-Account AWS (Staging + Prod)

**Two isolated AWS accounts. Zero EC2. 41 free-tier services. One git push deploys staging automatically.**

```
aws-staging account          aws-prod account
┌─────────────────────┐      ┌─────────────────────┐
│  Lambda (staging)   │      │  Lambda (prod)       │
│  DynamoDB (staging) │      │  DynamoDB (prod)     │
│  Cognito (staging)  │      │  Cognito (prod)      │
│  API GW (staging)   │      │  API GW (prod)       │
│  S3 (staging)       │      │  S3 (prod)           │
└─────────────────────┘      └─────────────────────┘
         ↑                            ↑
  git push develop            Manual approval
  (auto-deploy)               in GitHub UI
```

## Quick start

```bash
# Local development
pip install -r backend/requirements.txt
cd backend && STAGE=staging uvicorn app.main:app --reload --port 9000

# Frontend
cd frontend && npm install && npm start
```

## First-time AWS setup

**Step 1** — Set up staging account (~30 min):
```bash
export AWS_PROFILE=aws-staging
bash infrastructure/scripts/setup_staging_account.sh vinodsharma412/aws-services your@email.com
```

**Step 2** — Set up prod account (~30 min):
```bash
export AWS_PROFILE=aws-prod
bash infrastructure/scripts/setup_prod_account.sh vinodsharma412/aws-services your@email.com
```

**Step 3** — Add GitHub Secrets (shown at end of each setup script).

**Step 4** — Push code → staging auto-deploys → approve → prod deploys.

## AWS services (41 total, all free tier)

| Category | Services |
|---|---|
| **Compute** | Lambda (12 functions), Lambda Layers |
| **API** | API Gateway HTTP API, API Gateway WebSocket API |
| **Auth** | Cognito User Pool, Cognito Identity Pool |
| **Database** | DynamoDB (13 tables), DynamoDB Streams, DynamoDB TTL |
| **Storage** | S3 (frontend + avatars), S3 Lifecycle, S3 Events |
| **CDN** | CloudFront, CloudFront Functions, ACM (SSL) |
| **Messaging** | SQS + DLQ, SNS, SES, EventBridge, EventBridge Pipes |
| **Orchestration** | Step Functions (parallel scraping) |
| **AI/ML** | Comprehend (sentiment), Translate, Rekognition (avatar) |
| **Secrets** | SSM Parameter Store, AppConfig (feature flags) |
| **Monitoring** | CloudWatch (logs+alarms+dashboard), X-Ray, CloudTrail |
| **Security** | IAM, KMS, Shield Standard |
| **Governance** | AWS Organizations, Resource Groups, Budgets |
| **CI/CD** | GitHub Actions (OIDC), CodeBuild |

**Total monthly cost: $0 (free tier)**

## Documentation

| File | Contents |
|---|---|
| [docs/01_ARCHITECTURE.md](docs/01_ARCHITECTURE.md) | Full system diagram + all 41 services |
| [docs/02_STEP_BY_STEP_SETUP.md](docs/02_STEP_BY_STEP_SETUP.md) | **Start here — complete setup guide** |
| [docs/03_VS_CODE_SETUP.md](docs/03_VS_CODE_SETUP.md) | Local development environment |
| [docs/04_INTERVIEW_PREP.md](docs/04_INTERVIEW_PREP.md) | AWS interview Q&A |
| [docs/05_DEVELOPER_GUIDE.md](docs/05_DEVELOPER_GUIDE.md) | Day-to-day workflow |
| [docs/06_CLOUDWATCH_MONITORING.md](docs/06_CLOUDWATCH_MONITORING.md) | Monitoring guide |
| [docs/07_STAGING_PROD_WORKFLOW.md](docs/07_STAGING_PROD_WORKFLOW.md) | How deployments work |

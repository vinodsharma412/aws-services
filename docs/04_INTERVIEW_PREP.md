# Interview Prep — Serverless AWS Architecture

## 30-second project pitch

"I built a full-stack NSE stock analysis platform using a fully serverless AWS architecture.
The backend is FastAPI running inside Lambda via the Mangum ASGI adapter, with API Gateway as the entry point.
All state is in DynamoDB and S3. A separate SQS-triggered Lambda handles Amazon product scraping.
The frontend is React hosted on S3 + CloudFront. Everything deploys via GitHub Actions — no EC2, no VMs, zero infrastructure maintenance, all within the AWS free tier."

---

## Key questions and answers

### "Why Lambda instead of EC2?"

Lambda is permanently free (1M req/month forever vs EC2 free only 12 months).
There's nothing to maintain — no OS patches, no SSH, no Nginx config.
Deploys take 30 seconds: `aws lambda update-function-code`.
It auto-scales from 0 to 1,000 concurrent requests without configuration.

### "How does FastAPI run on Lambda?"

One line of code using the Mangum library:
```python
handler = Mangum(app, lifespan="off")
```
Mangum is an ASGI adapter. API Gateway sends an HTTP event in JSON format.
Mangum translates it into a standard ASGI request. FastAPI processes it normally.
Mangum converts the response back to API Gateway's expected format.
All existing FastAPI routes, auth, and DynamoDB code works unchanged.

### "Why polling instead of SSE?"

API Gateway + Lambda has a hard 29-second response timeout. SSE requires holding
a connection open for minutes. Polling every 2 seconds:
- Works within API Gateway's constraints
- Costs < 1 DynamoDB read per poll (virtually free)
- Users see updates within 2 seconds — functionally identical to SSE

### "How do you handle secrets?"

SSM Parameter Store with SecureString type (encrypted at rest using KMS).
Lambda reads secrets via boto3 at cold start with `@lru_cache(maxsize=1)`.
No secrets in environment variables, no secrets in code.
IAM role on Lambda has `ssm:GetParameter` permission for `/nse/{stage}/*` paths only.

### "How are staging and prod isolated?"

- DynamoDB: different table names (`stg_` prefix for staging)
- SQS: different queue names (`nse-scraping-jobs-staging` vs `nse-scraping-jobs`)
- Lambda: different function names
- API Gateway: different APIs with different URLs
- SSM: different parameter paths (`/nse/staging/` vs `/nse/prod/`)

Same AWS account, same region, completely data-isolated.

### "Walk me through a deploy"

1. Developer pushes to `develop` branch
2. GitHub Actions starts: ruff lint → npm build → pip install → zip
3. `aws lambda update-function-code --zip-file lambda.zip` (30 seconds)
4. Health check: `curl https://<staging-url>/api/v1/health/`
5. `aws s3 sync build/ s3://bucket/staging/`
6. Reviewer approves prod in GitHub UI
7. Same steps for prod Lambda + CloudFront invalidation

No SSH. No servers. Code is running in 2 minutes.

### "What happens when a scraping job fails?"

1. SQS keeps the message visible after the Lambda function returns an error
2. SQS retries after the visibility timeout (300 s)
3. After 3 failed attempts: message moves to Dead Letter Queue (DLQ)
4. DLQ has an event-source mapping to `nse-dlq-alert` Lambda
5. dlq-alert Lambda reads task details from DynamoDB, formats an alert
6. Publishes to SNS `nse-alerts-{stage}` topic → email to admin

### "How do you monitor the application?"

CloudWatch automatically gets Lambda logs (no agent needed).
6 alarms per stage: Lambda errors, DLQ depth > 0, API 5xx rate, DynamoDB throttles.
Dashboard: Lambda invocations/errors/duration, SQS depth, API latency.
`make logs STAGE=prod` — tails live logs from terminal.

### "What's the cost?"

Within the AWS free tier (12 months for some, forever for others):
- Lambda: $0 forever (1M req/month free)
- API Gateway: $0 for 12 months (1M req/month)
- DynamoDB: $0 forever (25 GB storage, 25 RCU/WCU)
- S3: $0 for 12 months (5 GB)
- CloudFront: $0 for 12 months (1 TB transfer)
- SQS: $0 forever (1M req/month)
Total: $0/month for a production-grade serverless app.

---

## AWS services used and why

| Service | Role | Why not alternatives |
|---|---|---|
| API Gateway HTTP API | Entry point, rate limiting, CORS | REST API is cheaper; WebSocket not needed |
| Lambda | All backend compute | vs EC2: no maintenance, always free |
| Mangum | ASGI adapter for FastAPI | vs rewriting for Lambda: zero code change |
| DynamoDB | Primary database | vs RDS: serverless, no patching, free tier |
| S3 | Frontend hosting + avatar storage | vs server-side: scales automatically |
| CloudFront | CDN + HTTPS | Free tier, caches S3, adds HTTPS |
| SQS | Scraping job queue | Durable, retry, DLQ — better than in-memory |
| SNS | Email alerts | vs SES: simpler, no domain verification |
| SSM | Secret storage | vs Secrets Manager: SSM is free |
| EventBridge | Scheduled jobs | vs cron on EC2: zero infrastructure |
| CloudWatch | Logs + alarms + dashboards | Automatic for Lambda, free tier |
| IAM | Access control | Roles not keys — no credential rotation |
| Comprehend | AI sentiment analysis | 50K free units/month |

---

## Architecture pattern: event-driven scraping

```
POST /scraping/jobs (Lambda API)
  → DynamoDB: create job record + task records
  → SQS: publish {task_id} for each ASIN

SQS → Lambda worker (triggered per message)
  → DynamoDB: task = "running"
  → httpx: scrape amazon.in/dp/{asin}
  → DynamoDB: task = "completed", product data saved
  → SQS message deleted (success)

Frontend polls GET /scraping/jobs every 2 s
  → Lambda: DynamoDB query
  → Returns updated job with task statuses
  → React renders progress bar
```

This is the fan-out pattern: one API call fans out to N parallel Lambda invocations (one per ASIN). SQS handles backpressure naturally.

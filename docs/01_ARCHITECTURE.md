# Architecture — 40+ AWS Free-Tier Services, Zero EC2

## All AWS services used

| # | Service | Role | Free Tier |
|---|---|---|---|
| 1 | **API Gateway HTTP API** | REST entry point, rate limiting, CORS | 1M req/month forever |
| 2 | **API Gateway WebSocket API** | Real-time scraping progress push | 1M conn min/month 12 mo |
| 3 | **Lambda** (6 functions) | All backend compute | 1M req + 400K GB-s/month forever |
| 4 | **Lambda Layers** | Shared X-Ray + utilities code | Same Lambda free tier |
| 5 | **DynamoDB** | Primary database (12 tables) | 25 GB + 25 RCU/WCU forever |
| 6 | **DynamoDB Streams** | Event-driven WS push on task update | Included with DynamoDB |
| 7 | **DynamoDB TTL** | Auto-expire WebSocket connections | Included with DynamoDB |
| 8 | **S3** | Frontend hosting + avatar images | 5 GB, 20K GET / 12 months |
| 9 | **S3 Event Notifications** | Trigger Rekognition on avatar upload | Included with S3 |
| 10 | **S3 Lifecycle Policies** | Archive old scraping data to Glacier | Included with S3 |
| 11 | **CloudFront** | CDN + HTTPS for frontend | 1 TB, 10M req / 12 months |
| 12 | **CloudFront Functions** | Edge auth header injection | 2M invocations/month forever |
| 13 | **Cognito User Pool** | Auth — replaces JWT/bcrypt entirely | 50,000 MAU forever |
| 14 | **Cognito Identity Pool** | Temporary AWS credentials for browser | Included with Cognito |
| 15 | **SQS Standard** | Scraping job queue + DLQ | 1M req/month forever |
| 16 | **SNS** | Email alerts + job notifications | 1M publishes/month forever |
| 17 | **SES** | Transactional email (job reports) | 62K emails/month from Lambda |
| 18 | **EventBridge** | Custom events (JobCreated, JobCompleted) | 1M events/month forever |
| 19 | **EventBridge Scheduler** | Daily universe refresh, screener cron | 14M invocations/month free |
| 20 | **EventBridge Pipes** | SQS → Lambda with filter (optional) | 5M events/month 12 months |
| 21 | **Step Functions** | Parallel ASIN scraping (Map state) | 4,000 state transitions/month forever |
| 22 | **SSM Parameter Store** | Secrets — JWT, DB URLs, feature flags | 10K API calls/month forever |
| 23 | **AppConfig** | Feature flags without redeployment | Free (uses SSM) |
| 24 | **X-Ray** | Distributed tracing all Lambda calls | 100K traces/month forever |
| 25 | **CloudWatch Logs** | Auto log all Lambda invocations | 5 GB ingestion + storage / 12 mo |
| 26 | **CloudWatch Metrics** | Custom metrics (queue depth, errors) | 10 detailed metrics / 12 mo |
| 27 | **CloudWatch Alarms** | Alert on Lambda errors, DLQ depth | 10 alarms / 12 months |
| 28 | **CloudWatch Dashboard** | Operations view per stage | 3 dashboards / 12 months |
| 29 | **CloudWatch Logs Insights** | Query logs across functions | 5 GB queried/month / 12 mo |
| 30 | **CloudTrail** | Audit log every API call | 1 trail, 90-day history forever |
| 31 | **IAM** | Roles, policies, least privilege | Always free |
| 32 | **KMS (AWS-managed keys)** | Encrypt DynamoDB, S3, SSM at rest | AWS-managed keys are free |
| 33 | **Comprehend** | ML sentiment on NSE news | 50K units/month / 12 months |
| 34 | **Translate** | Translate product titles to English | 2M chars/month / 12 months |
| 35 | **Rekognition** | Moderate avatar images (no NSFW) | 5K images/month / 12 months |
| 36 | **CodeBuild** | Build Lambda packages in AWS | 100 build min/month forever |
| 37 | **Resource Groups + Tags** | Organize all resources by stage | Always free |
| 38 | **Budgets** | Alert if spend > $0.50/month | 2 budgets free forever |
| 39 | **Shield Standard** | DDoS protection on API Gateway | Always free |
| 40 | **ACM (Certificate Manager)** | Free SSL certs for CloudFront | Always free |
| 41 | **Lambda@Edge** | CloudFront request manipulation | 1M requests / 12 months |

**Total estimated cost: $0/month (all within free tier)**

---

## System diagram

```
Developer  git push develop
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│  GitHub Actions CI/CD (or CodeBuild)                         │
│  ruff lint → npm build → pip install → zip → Lambda update  │
└────────────────┬────────────────────────────────────────────┘
                 │ aws lambda update-function-code
                 ▼

BROWSER (React SPA)
S3 static website + CloudFront CDN + ACM SSL + Shield DDoS
     │
     ├─ HTTPS REST  ──────────────────────────────────────────────┐
     │                                                            ▼
     │                             ┌────────────────────────────────────────┐
     │                             │   API Gateway HTTP API                  │
     │                             │   Cognito JWT Authorizer               │
     │                             │   Throttle: 20 req/s + burst 50        │
     │                             │   Routes → Lambda per domain           │
     │                             └──────────┬─────────────────────────────┘
     │                                        │
     │                        ┌───────────────┼────────────────┐
     │                        ▼               ▼                ▼
     │            Lambda: nse-auth  Lambda: nse-users  Lambda: nse-stocks
     │            (Cognito auth)    (S3 avatars)        (yfinance + portfolio)
     │                        │               │                │
     │                        └───────────────┼────────────────┘
     │                                        ▼
     │                              DynamoDB (12 tables)
     │                              S3 (avatars)
     │                              SSM (secrets)
     │                              Comprehend (AI sentiment)
     │                              Translate (product titles)
     │
     ├─ WebSocket wss://  ─────────────────────────────────────┐
     │                                                         ▼
     │                         ┌───────────────────────────────────────────┐
     │                         │  API Gateway WebSocket API                 │
     │                         │  $connect / $disconnect / $default         │
     │                         └───────────┬───────────────────────────────┘
     │                                     ▼
     │                         Lambda: nse-ws (connection registry)
     │                         DynamoDB: ws_connections (TTL 2h)
     │                                     ▲
     │                                     │ push update
     │                         Lambda: nse-dynamo-streams
     │                                     ▲
     │                                     │ triggered
     │                         DynamoDB Streams (scraping_tasks)
     │                                     ▲
     └─ POST /scraping/jobs ───────────────┘
              │
              ▼
         Lambda: nse-scraping
              │
         ┌────┴──────────────────────────────────────────┐
         │  Option A: Step Functions (Map state)          │
         │    → 5 parallel Lambda invocations             │
         │    → each scrapes 1 ASIN (httpx + bs4)        │
         │    → SNS completion notification               │
         │                                                │
         │  Option B: SQS queue (fallback)                │
         │    → Lambda: nse-scraping-worker (SQS trigger) │
         │    → On failure: DLQ → nse-dlq-alert → SNS    │
         └────────────────────────────────────────────────┘

── Scheduled background jobs ─────────────────────────────────────────────────
EventBridge Scheduler
  cron(0 3 * * ?)    daily 3 AM → Lambda: nse-universe-refresh
  cron(0/30 6-16 MON-FRI) → Lambda: nse-screener-refresh

EventBridge custom events
  JobCreated / JobCompleted → Lambda: nse-ses-notifications → SES email

── Monitoring ─────────────────────────────────────────────────────────────────
X-Ray: traces every Lambda call, boto3, httpx
CloudWatch: logs + 6 alarms + dashboard per stage
CloudTrail: audit every AWS API call (who did what, when)
AppConfig: feature flags (toggle Comprehend, Translate without redeploy)
Budgets: alert if monthly bill > $0.50
```

---

## What "replace FastAPI with API Gateway" means

| Before | After |
|---|---|
| `fastapi` framework routes requests | API Gateway routes to Lambda directly |
| `mangum` adapter translates events | No adapter — Lambda reads API GW event dict |
| One Lambda runs ALL routes | One Lambda per domain (auth, users, stocks, scraping) |
| JWT from `python-jose` | Cognito JWT validated by API Gateway (no Lambda code needed) |
| bcrypt password hashing | Cognito handles all password storage and verification |
| SSE long-polling | WebSocket API pushes state changes instantly |
| Polling for progress | DynamoDB Streams → push to WebSocket |
| SQS-only scraping | Step Functions Map state (parallel) + SQS fallback |

---

## Lambda function map

| Function | Handler | Trigger | Memory/Timeout |
|---|---|---|---|
| `nse-api-{stage}` | — (API GW routes to sub-handlers) | API Gateway HTTP | 512MB / 30s |
| `nse-auth-{stage}` | `handlers.auth.handler` | API GW `/auth/*` | 256MB / 10s |
| `nse-users-{stage}` | `handlers.users.handler` | API GW `/users/*` | 256MB / 15s |
| `nse-stocks-{stage}` | `handlers.stocks.handler` | API GW `/stocks/*` | 512MB / 30s |
| `nse-scraping-{stage}` | `handlers.scraping.handler` | API GW `/scraping/*` | 256MB / 15s |
| `nse-scraping-worker-{stage}` | `handler.lambda_handler` | SQS trigger | 256MB / 120s |
| `nse-ws-{stage}` | `handler.handler` | WebSocket API | 256MB / 30s |
| `nse-dynamo-streams-{stage}` | `dynamo_streams.handler` | DynamoDB Streams | 256MB / 30s |
| `nse-ses-notifications-{stage}` | `ses_notifications.handler` | EventBridge | 256MB / 30s |
| `nse-dlq-alert-{stage}` | `handler.lambda_handler` | SQS DLQ | 128MB / 30s |
| `nse-screener-refresh-{stage}` | `handler.handler` | EventBridge cron | 512MB / 300s |
| `nse-universe-refresh-{stage}` | `handler.handler` | EventBridge cron | 256MB / 300s |

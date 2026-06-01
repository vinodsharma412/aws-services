# Interview Prep — Multi-Account AWS Architecture

## 30-second pitch

"I built a full-stack NSE stock dashboard on AWS using a multi-account architecture —
separate AWS accounts for staging and prod. The backend is pure Lambda functions
(no FastAPI framework — API Gateway routes directly to Lambda). Authentication uses
Cognito. Real-time scraping progress uses WebSocket API + DynamoDB Streams.
Workflow orchestration uses Step Functions. Everything deploys via GitHub Actions
with OIDC — no stored AWS credentials anywhere. 41 free-tier services, $0/month."

---

## Key interview questions

### "Why two AWS accounts instead of one?"

Single-account approach uses table prefixes (`stg_users`, `prod_users`) but this
has risks: a bug in staging code could accidentally write to `prod_users`.
Two accounts provide **complete blast radius isolation** — staging can't touch
prod at all, because they're different accounts. Also:
- Separate AWS bills per environment
- Separate IAM permissions (stricter in prod)
- Separate CloudWatch logs (no mixing of logs)
- Each account gets its own free tier (double the free resources)
- AWS Organizations can add Service Control Policies to restrict prod further

### "How does GitHub Actions deploy to two different accounts?"

GitHub OIDC (OpenID Connect). No access keys stored anywhere.
Each account has an IAM role `GitHubActionsRole-{stage}` with a trust policy
that only allows GitHub's token service for this specific repo + branch.

When the pipeline runs:
1. GitHub generates a short-lived JWT signed by GitHub
2. GitHub Actions uses `aws-actions/configure-aws-credentials` with `role-to-assume`
3. AWS STS verifies the JWT against the OIDC provider
4. Returns temporary 1-hour credentials
5. Pipeline deploys using those credentials

If GitHub is compromised, the attacker gets tokens that expire in 1 hour.
If you need to revoke access, just delete the IAM role — no key rotation needed.

### "How does Cognito replace your JWT auth?"

Before: `python-jose` generated JWTs, `bcrypt` hashed passwords, DynamoDB stored hashed passwords.
After: Cognito handles all of this — user storage, password hashing, MFA, token issuance.

Flow:
1. User POSTs username/password to Lambda: `auth.handler`
2. Lambda calls `cognito.initiate_auth(AuthFlow="USER_PASSWORD_AUTH")`
3. Cognito returns `AccessToken`, `IdToken`, `RefreshToken`
4. Frontend sends `IdToken` as `Authorization: Bearer` header
5. API Gateway's **JWT Authorizer** validates `IdToken` against Cognito
6. Lambda receives verified claims in `event.requestContext.authorizer.jwt.claims`
7. No JWT decoding in Lambda — API Gateway already did it

Security improvements: Cognito enforces password policy, handles brute force protection, supports MFA, manages token refresh.

### "Walk me through the WebSocket real-time updates"

Old: Frontend polls `GET /scraping/jobs` every 2 seconds (500ms wasted, DynamoDB read per poll)
New: Browser connects once, server pushes instantly

1. User submits scraping job → Lambda creates DynamoDB records + starts Step Functions
2. Frontend opens WebSocket: `wss://<ws-api>.execute-api.ap-south-1.amazonaws.com/staging`
3. Browser sends: `{"action": "subscribe", "job_id": "<uuid>"}`
4. WebSocket Lambda stores: `{connection_id, user_id, job_id, ttl: now+2h}` in DynamoDB
5. Step Functions runs Map state → 5 parallel Lambda invocations → each scrapes 1 ASIN
6. Worker Lambda updates DynamoDB: `task.status = "completed"` (or `"failed"`)
7. DynamoDB Stream record is generated (NEW_AND_OLD_IMAGES)
8. `nse-dynamo-streams` Lambda is triggered
9. Lambda queries `ws_connections` table: find all connections subscribed to this job
10. For each connection: API Gateway Management API `post_to_connection`
11. Browser receives: `{"type": "job_update", "pending": 3, "running": 2, ...}`

Zero polling. Zero wasted reads. Updates in milliseconds.

### "Why Step Functions for scraping?"

Step Functions Map state fans out to N parallel Lambda invocations automatically.
For 10 ASINs with MaxConcurrency=5: runs 5 at a time, starts next as each finishes.
Built-in retry with exponential backoff. Built-in error handling (Catch → RecordFailure).
When all done: publishes SNS notification automatically.

Alternative was N SQS messages → N Lambda invocations → manual DLQ → manual retry.
Step Functions handles all of this with JSON config.

Free tier: 4,000 state transitions/month forever. A 10-ASIN job = ~30 transitions.

### "How do you monitor the multi-account setup?"

Each account has its own CloudWatch. To see everything:
- `AWS_PROFILE=aws-staging make logs STAGE=staging` — staging Lambda logs
- `AWS_PROFILE=aws-prod make logs STAGE=prod` — prod Lambda logs
- X-Ray service maps in each account show end-to-end traces
- Alarms in each account email to the same address via SNS
- Resource Groups show all 41 services tagged `Project=NSEDashboard` per account

### "What's the cost?"

Staging account free tier + Prod account free tier = double the resources.
With two accounts, both environments run completely free:
- Lambda: 1M req × 2 accounts = 2M free requests
- DynamoDB: 25 GB × 2 accounts = 50 GB free storage
- API Gateway: 1M req × 2 accounts = 2M free requests

Total: $0/month.

---

## AWS services quick reference (for interviews)

| Service | 10-word explanation |
|---|---|
| API Gateway HTTP API | Managed HTTP router → Lambda/backend |
| API Gateway WebSocket | Persistent bidirectional connection → Lambda |
| Lambda | Run code without servers, pay per invocation |
| Lambda Layers | Shared code/libraries across multiple Lambdas |
| DynamoDB | NoSQL key-value store, serverless, auto-scaling |
| DynamoDB Streams | CDC — triggers Lambda on every table change |
| DynamoDB TTL | Auto-delete items after timestamp expires |
| Cognito | Managed user pool — auth, MFA, token issuance |
| S3 | Object storage — files, frontend, avatars |
| CloudFront | Global CDN — cache S3/Lambda responses at edge |
| SQS | Message queue — decouple producers from consumers |
| SNS | Pub-sub — one message to many subscribers |
| SES | Send transactional email from Lambda |
| EventBridge | Event bus + cron scheduler for Lambda |
| Step Functions | Visual workflow — orchestrate Lambda steps |
| SSM Parameter Store | Store secrets, config — free alternative to Secrets Manager |
| AppConfig | Feature flags — toggle features without redeploy |
| X-Ray | Distributed tracing across all Lambda calls |
| CloudWatch | Logs, metrics, alarms, dashboards |
| CloudTrail | Audit log of every AWS API call |
| Comprehend | ML sentiment analysis on text |
| Translate | Machine translation (40+ languages) |
| Rekognition | Computer vision — image moderation |
| KMS | Encryption key management |
| IAM | Identity and access management |
| AWS Organizations | Multi-account management from master account |

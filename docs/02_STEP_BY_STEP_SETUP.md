# Step-by-Step AWS Setup — Zero to Deployed (Serverless)

This guide takes you from a blank AWS account to a fully deployed serverless application.
No EC2. No SSH. No servers to manage. Time: ~60 minutes first time, ~10 min for each redeploy.

---

## Prerequisites

- AWS account (free tier)
- AWS CLI installed: `pip install awscli` and `aws configure`
- Python 3.12+ and Node 20+
- GitHub account (for CI/CD)

---

## Step 1 — IAM: Create Lambda execution role

```bash
bash infrastructure/iam/setup_lambda_role.sh
```

Creates `NSELambdaRole` with permissions for DynamoDB, S3, SQS, SNS, SSM, CloudWatch, Comprehend.
All Lambda functions run under this role — no hard-coded AWS keys anywhere.

---

## Step 2 — S3: Create buckets

```bash
bash infrastructure/scripts/s3_setup.sh
```

- `nse-frontend-{account-id}` — React build (static website hosting)
- `nse-assets-{account-id}` — User avatars (private)

---

## Step 3 — DynamoDB: Create tables

```bash
make dynamo-tables STAGE=staging    # creates stg_users, stg_scraping_tasks, etc.
make dynamo-tables STAGE=prod       # creates users, scraping_tasks, etc.
```

12 tables per stage, PAY_PER_REQUEST billing (free within free tier).

---

## Step 4 — SSM: Store secrets

```bash
bash infrastructure/ssm/setup_ssm.sh staging
bash infrastructure/ssm/setup_ssm.sh prod
```

Enter when prompted:
- JWT secret (generate: `openssl rand -hex 32`)
- Gmail address + app password (for alert emails)

Stored as SecureString — encrypted, never in code.

---

## Step 5 — SQS + SNS

```bash
bash infrastructure/sqs/setup_sqs.sh staging
bash infrastructure/sqs/setup_sqs.sh prod

bash infrastructure/sns/setup_sns.sh staging your@email.com
bash infrastructure/sns/setup_sns.sh prod   your@email.com
```

Check your email and click Confirm subscription for SNS.

---

## Step 6 — Deploy Lambda functions

### API Lambda

```bash
bash infrastructure/lambda/api/deploy.sh staging
bash infrastructure/lambda/api/deploy.sh prod
```

Packages FastAPI + Mangum into a zip, uploads to Lambda.
Attaches the AWS-managed pandas layer (pandas/numpy pre-built for Lambda).

### Scraping Worker Lambda

```bash
bash infrastructure/lambda/scraping_worker/deploy.sh staging
bash infrastructure/lambda/scraping_worker/deploy.sh prod
```

Also wires SQS as the event source trigger (batch size = 1).

---

## Step 7 — API Gateway

```bash
bash infrastructure/scripts/api_gateway_setup.sh staging
bash infrastructure/scripts/api_gateway_setup.sh prod
```

Creates HTTP API → Lambda integration for each stage.
Outputs the invoke URL — copy it for GitHub Secrets.

Test:
```bash
curl https://<api-id>.execute-api.ap-south-1.amazonaws.com/api/v1/health/
# {"status":"ok","stage":"staging"}
```

---

## Step 8 — EventBridge + CloudWatch

```bash
bash infrastructure/eventbridge/setup_eventbridge.sh staging
bash infrastructure/cloudwatch/setup_alarms.sh staging <api-gw-id>
bash infrastructure/cloudfront/setup_cloudfront.sh staging
```

Repeat for prod.

---

## Step 9 — GitHub Secrets

Settings → Secrets → Actions. Add:

| Secret | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM access key |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key |
| `S3_FRONTEND_BUCKET` | `nse-frontend-{account-id}` |
| `STAGING_API_URL` | `https://<id>.execute-api.ap-south-1.amazonaws.com/api/v1` |
| `PROD_API_URL` | `https://<id>.execute-api.ap-south-1.amazonaws.com/api/v1` |

Settings → Environments. Create:
- `staging` — no protection rules
- `prod` — Required reviewers: your GitHub username

---

## Step 10 — First deploy

```bash
git add . && git commit -m "feat: serverless migration" && git push origin develop
```

Watch GitHub Actions: Lint → Build → Deploy STAGING → Approve → Deploy PROD.

---

## Daily workflow after initial setup

```bash
# Make changes locally, test on localhost:9000
# Push to develop → auto-deploys staging in 2 min
# Approve in GitHub UI → prod deployed in 1 min

make logs STAGE=staging     # watch CloudWatch logs live
make health                 # verify both stages
```

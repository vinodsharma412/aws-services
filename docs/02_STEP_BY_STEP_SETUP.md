# Step-by-Step Setup — Two AWS Accounts (Staging + Prod)

> **Read this first. Do every step in order. Don't skip.**

---

## Before you start — what you need

- [ ] **Two AWS accounts** (free, see Step 0)
- [ ] **AWS CLI installed** on your machine
- [ ] **GitHub account** with the `aws-services` repo
- [ ] **Your email address** (for alerts)
- [ ] **~60 minutes** total

---

## Step 0 — Create two AWS accounts

You need **two separate AWS accounts**:
- `aws-staging` — developers test here (auto-deploys on every push)
- `aws-prod` — real users here (manual approval required)

### 0a. Create accounts via AWS Organizations (recommended)

AWS Organizations lets you manage both accounts from a single "master" account.
The benefit: one login, one billing, separate IAM per account.

1. Go to [aws.amazon.com](https://aws.amazon.com) → **Create a Free Account**
2. This becomes your **master/management account**
3. In the AWS Console → **AWS Organizations** → **Add an AWS account**
4. Create `aws-staging` account (give it a unique email, e.g. `yourname+staging@gmail.com`)
5. Create `aws-prod` account (unique email, e.g. `yourname+prod@gmail.com`)

Each account gets its own 12-month free tier from creation date.

### 0b. Alternative: Two completely independent accounts

Just create two separate AWS accounts at [aws.amazon.com](https://aws.amazon.com).
Use different email addresses. No Organizations needed.

---

## Step 1 — Install and configure AWS CLI

```bash
# Install AWS CLI
pip install awscli

# Configure profiles (one per account)
aws configure --profile aws-staging
# Enter: Access Key ID, Secret Access Key, region (ap-south-1), output (json)

aws configure --profile aws-prod
# Enter: Access Key ID, Secret Access Key, region (ap-south-1), output (json)

# Test
aws sts get-caller-identity --profile aws-staging
aws sts get-caller-identity --profile aws-prod
```

**How to get access keys per account:**
1. Log into each AWS account console
2. IAM → Users → Create user → Attach `AdministratorAccess`
3. Security credentials → Create access key → Download CSV

---

## Step 2 — Clone the repository

```bash
git clone https://github.com/vinodsharma412/aws-services.git
cd aws-services
git checkout develop
```

---

## Step 3 — Set up the STAGING account (aws-staging)

Run this ONE TIME inside your staging AWS account:

```bash
export AWS_PROFILE=aws-staging

bash infrastructure/scripts/setup_staging_account.sh \
  vinodsharma412/aws-services \
  your@email.com
```

This script runs all 15 steps automatically:
1. Creates `NSELambdaRole` (Lambda execution role)
2. Sets up GitHub OIDC (no access keys needed in GitHub)
3. Creates S3 buckets (frontend + avatars)
4. Creates 13 DynamoDB tables
5. Sets up SSM secrets (asks you for JWT key, passwords)
6. Creates Cognito User Pool
7. Creates SQS + SNS + SES
8. Deploys Lambda Layer (X-Ray + AppConfig)
9. Deploys Lambda functions (API + Worker)
10. Creates API Gateway → Lambda
11. Creates WebSocket API + DynamoDB Streams
12. Creates Step Functions state machine
13. Creates EventBridge scheduled rules
14. Creates CloudWatch alarms + dashboard
15. Creates CloudFront + AppConfig + KMS + Resource Groups

At the end it prints the GitHub Secrets you need to add. **Copy them.**

---

## Step 4 — Set up the PROD account (aws-prod)

```bash
export AWS_PROFILE=aws-prod

bash infrastructure/scripts/setup_prod_account.sh \
  vinodsharma412/aws-services \
  your@email.com
```

Same 15 steps as staging, but in a completely separate AWS account.
It asks for confirmation before starting (this is production).

---

## Step 5 — Add GitHub Secrets

Go to: **GitHub → your repo → Settings → Secrets → Actions**

Add ALL of these (values shown at end of each setup script):

### Staging account secrets
```
STAGING_ROLE_ARN          arn:aws:iam::<staging-account-id>:role/GitHubActionsRole-staging
STAGING_ACCOUNT_ID        <12-digit staging account ID>
STAGING_API_URL           https://<api-id>.execute-api.ap-south-1.amazonaws.com/api/v1
S3_FRONTEND_BUCKET_STAGING  nse-frontend-<staging-account-id>
```

### Prod account secrets
```
PROD_ROLE_ARN             arn:aws:iam::<prod-account-id>:role/GitHubActionsRole-prod
PROD_ACCOUNT_ID           <12-digit prod account ID>
PROD_API_URL              https://<api-id>.execute-api.ap-south-1.amazonaws.com/api/v1
S3_FRONTEND_BUCKET_PROD   nse-frontend-<prod-account-id>
```

> **No AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY needed.**
> GitHub OIDC uses temporary tokens — more secure than stored keys.

---

## Step 6 — Set up GitHub Environments

Go to: **GitHub → Settings → Environments**

Create two environments:

**`staging`** — No protection rules (auto-deploy)
- Click "New environment" → name: `staging`
- No reviewers, no wait timer

**`prod`** — Manual approval required
- Click "New environment" → name: `prod`
- Required reviewers: add your GitHub username
- Optional: Add 5-minute wait timer

---

## Step 7 — First deploy

```bash
# Push to develop branch
git add . && git commit -m "chore: initial deploy" && git push origin develop
```

Then:
1. Go to **GitHub → Actions** — watch the pipeline run
2. **Lint & Build** completes (~3 min)
3. **Deploy → aws-staging** completes automatically (~2 min)
4. Check: `curl https://<STAGING_API_URL>/health/`
5. You see: **"Waiting for approval to deploy to aws-prod"**
6. Click **Review deployments** → **Approve and deploy**
7. **Deploy → aws-prod** completes (~2 min)

---

## Step 8 — Verify both environments

```bash
# Health check both
make health

# View staging logs live
make logs STAGE=staging

# View prod logs live
make logs STAGE=prod
```

**AWS Console verification:**

| Service | Where to look |
|---|---|
| Lambda | Console → Lambda → Functions |
| DynamoDB | Console → DynamoDB → Tables |
| API Gateway | Console → API Gateway → APIs |
| Cognito | Console → Cognito → User pools |
| CloudWatch | Console → CloudWatch → Dashboards → `NSE-Operations-staging` |
| X-Ray | Console → CloudWatch → X-Ray traces |

---

## Step 9 — Create admin user

After first deploy, create your admin user in Cognito:

```bash
# Staging
AWS_PROFILE=aws-staging aws cognito-idp admin-create-user \
  --user-pool-id $(AWS_PROFILE=aws-staging aws ssm get-parameter \
    --name /nse/staging/cognito-user-pool-id \
    --query Parameter.Value --output text) \
  --username admin \
  --user-attributes Name=email,Value=your@email.com Name=email_verified,Value=true \
    "Name=custom:role,Value=admin" \
  --temporary-password "Nse@2025!" \
  --message-action SUPPRESS \
  --region ap-south-1

# Prod (same command with aws-prod profile)
```

Log in at the frontend URL → change password on first login.

---

## Cost check (should be $0)

```bash
# Check AWS bill for staging account
AWS_PROFILE=aws-staging aws ce get-cost-and-usage \
  --time-period Start=$(date -d "1 month ago" +%Y-%m-01),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --query "ResultsByTime[0].Total.BlendedCost.Amount" \
  --region us-east-1

# Should output: "0.0000000000"
```

If you see charges, check if you accidentally enabled paid services (EC2, RDS, etc.).

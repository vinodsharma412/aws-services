# Complete AWS Setup — Every Service, Every Step

> Zero to fully deployed, with staging and prod in separate accounts.
> Follow every section in order. Do not skip.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [AWS Organizations — Three Accounts](#2-aws-organizations--three-accounts)
3. [IAM — Master Account User](#3-iam--master-account-user)
4. [Switch Role — Cross-Account Access](#4-switch-role--cross-account-access)
5. [AWS CLI — Switch Role Profiles](#5-aws-cli--switch-role-profiles)
6. [IAM — Lambda Execution Role](#6-iam--lambda-execution-role)
7. [IAM — GitHub OIDC (No Stored Keys)](#7-iam--github-oidc-no-stored-keys)
8. [S3 — Frontend + Avatar Buckets](#8-s3--frontend--avatar-buckets)
9. [DynamoDB — 13 Tables](#9-dynamodb--13-tables)
10. [SSM Parameter Store — Secrets](#10-ssm-parameter-store--secrets)
11. [Cognito — User Pool + Identity Pool](#11-cognito--user-pool--identity-pool)
12. [SQS — Scraping Queue + DLQ](#12-sqs--scraping-queue--dlq)
13. [SNS — Alert Notifications](#13-sns--alert-notifications)
14. [SES — Transactional Email](#14-ses--transactional-email)
15. [Lambda Layer — Shared Utilities](#15-lambda-layer--shared-utilities)
16. [Lambda — All Functions](#16-lambda--all-functions)
17. [API Gateway HTTP API — REST Endpoints](#17-api-gateway-http-api--rest-endpoints)
18. [API Gateway WebSocket API — Real-Time](#18-api-gateway-websocket-api--real-time)
19. [DynamoDB Streams — Event-Driven Push](#19-dynamodb-streams--event-driven-push)
20. [Step Functions — Parallel Scraping](#20-step-functions--parallel-scraping)
21. [EventBridge — Scheduled Jobs](#21-eventbridge--scheduled-jobs)
22. [CloudFront — CDN + HTTPS](#22-cloudfront--cdn--https)
23. [AppConfig — Feature Flags](#23-appconfig--feature-flags)
24. [KMS — Encryption](#24-kms--encryption)
25. [CloudWatch — Logs, Alarms, Dashboard](#25-cloudwatch--logs-alarms-dashboard)
26. [X-Ray — Distributed Tracing](#26-x-ray--distributed-tracing)
27. [CloudTrail — Audit Log](#27-cloudtrail--audit-log)
28. [Resource Groups + Tags](#28-resource-groups--tags)
29. [Budgets — Cost Alert](#29-budgets--cost-alert)
30. [CodeBuild — AWS-Native CI/CD](#30-codebuild--aws-native-cicd)
31. [GitHub Actions — CI/CD Pipeline](#31-github-actions--cicd-pipeline)
32. [Frontend Deploy — S3 + CloudFront](#32-frontend-deploy--s3--cloudfront)
33. [Verify Everything Works](#33-verify-everything-works)

---

## 1. Prerequisites

### Install on your laptop

```bash
# AWS CLI
pip install awscli
aws --version           # must show aws-cli/2.x.x

# Python 3.12
python3 --version       # must show 3.10+

# Node 20 (for frontend)
node --version          # must show v20.x.x
npm --version

# Git
git --version

# jq (JSON parser, useful for AWS output)
sudo apt install jq     # Ubuntu/Debian
brew install jq         # Mac
```

### Clone the project

```bash
git clone https://github.com/vinodsharma412/aws-services.git
cd aws-services
git checkout develop
```

### Gather these values before starting

You will need:
- Your email address (for alerts and account creation)
- A strong JWT secret: `openssl rand -hex 32` → copy output
- A Gmail address + App Password (for SES email)

---

## 2. AWS Organizations — Three Accounts

### Why three accounts?

```
master account    → your personal account, one IAM user
aws-staging       → all staging resources, zero IAM users
aws-prod          → all prod resources, zero IAM users
```

Data isolation is TOTAL — staging cannot touch prod even with a code bug.
Each account has its own free tier.

### 2a. Create master account

Go to [https://aws.amazon.com](https://aws.amazon.com) → **Create an AWS Account**

- Email: `yourprimary@email.com`
- Account name: `nse-master`
- Payment: credit card required (will not be charged within free tier)

### 2b. Enable AWS Organizations

In master account console:

```
Console → Search "Organizations" → AWS Organizations
→ Create organization
→ Choose "Enable all features"
→ Confirm
```

### 2c. Create staging account

```
AWS Organizations → Add an AWS account → Create an AWS account
  Account name : aws-staging
  Email        : yourname+staging@gmail.com   (different from master!)
  IAM role name: OrganizationAccountAccessRole   (keep default)
→ Create AWS account
```

Wait 2-3 minutes. The account appears in Organizations.

**Copy the staging account ID** (12-digit number shown in Organizations).

### 2d. Create prod account

```
AWS Organizations → Add an AWS account → Create an AWS account
  Account name : aws-prod
  Email        : yourname+prod@gmail.com
  IAM role name: OrganizationAccountAccessRole   (keep default)
→ Create AWS account
```

**Copy the prod account ID.**

### 2e. Access child accounts from master

```
AWS Organizations → Accounts → aws-staging
→ Access account
→ Opens staging console as OrganizationAccountAccessRole (admin)
```

This is how you log into child accounts WITHOUT creating IAM users in them.

---

## 3. IAM — Master Account User

Create ONE IAM user. All credentials live here.

### Console steps

```
Master console → IAM → Users → Create user
  Username        : vinod           (your name)
  Select policies : AdministratorAccess
→ Create user
```

### Create access key

```
IAM → Users → vinod
→ Security credentials tab
→ Create access key
→ Use case: Command Line Interface (CLI)
→ Create access key
→ DOWNLOAD CSV (do this now — you can never see the secret again)
```

Save the CSV. It contains:
```
Access key ID      : AKIAIOSFODNN7EXAMPLE
Secret access key  : wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

### Enable MFA (strongly recommended)

```
IAM → Users → vinod → Security credentials
→ Multi-factor authentication (MFA)
→ Assign MFA device
→ Authenticator app
→ Scan QR code with Google Authenticator / Authy
→ Enter two consecutive codes
→ Add MFA
```

With MFA enabled, anyone who steals your access key STILL cannot switch roles
into staging/prod (because the trust policy requires MFA).

---

## 4. Switch Role — Cross-Account Access

Create a role in each child account that your master account user can assume.

### 4a. Set up role in STAGING account

**Step 1**: Access staging account
```
Master console → Organizations → Accounts → aws-staging → Access account
```

**Step 2**: Run the setup script
```bash
# You are now in staging account console as OrganizationAccountAccessRole
# Get temporary credentials from the console (or use environment variables)

# If using the console session (simplest):
# → Console → IAM → Create role (manual steps below)

# If using CLI with temp credentials from Organizations:
bash infrastructure/iam/setup_switch_role.sh staging <MASTER_ACCOUNT_ID>
```

**Manual console steps** (if not using CLI):
```
Staging console → IAM → Roles → Create role

Trusted entity type: AWS account
  Another AWS account
  Account ID: <MASTER_ACCOUNT_ID>
  ✓ Require external ID: nse-staging-access
  ✓ Require MFA (check this box)

→ Next: Permissions
  Attach: PowerUserAccess
→ Role name: CrossAccountAccessRole
→ Create role
```

**Copy the Role ARN**: `arn:aws:iam::<STAGING_ACCOUNT_ID>:role/CrossAccountAccessRole`

### 4b. Set up role in PROD account

Same steps in prod account:
```
Master console → Organizations → aws-prod → Access account

Prod console → IAM → Roles → Create role
  Another AWS account: <MASTER_ACCOUNT_ID>
  External ID: nse-prod-access
  ✓ Require MFA
  Policy: (custom — read-only + deploy only)
```

Or use the script:
```bash
bash infrastructure/iam/setup_switch_role.sh prod <MASTER_ACCOUNT_ID>
```

**Copy the Role ARN**: `arn:aws:iam::<PROD_ACCOUNT_ID>:role/CrossAccountAccessRole`

### 4c. Console Switch Role (browser)

Set up quick-switch buttons in the console:

**For staging:**
```
Master console → click your username (top right) → Switch Role
  Account     : <STAGING_ACCOUNT_ID>   (12-digit number)
  Role        : CrossAccountAccessRole
  Display Name: aws-staging
  Color       : Blue
→ Switch Role
```

**For prod:**
```
→ Switch Role again
  Account     : <PROD_ACCOUNT_ID>
  Role        : CrossAccountAccessRole
  Display Name: aws-prod
  Color       : Red
→ Switch Role
```

Now you have quick-switch buttons. Click **your username** anytime to switch:

```
┌──────────────────────────┐
│  vinod @ nse-master      │
│  ─────────────────────── │
│  Switch Role History:    │
│  🔵 aws-staging          │  ← click to switch instantly
│  🔴 aws-prod             │  ← click to switch instantly
│  ─────────────────────── │
│  My Account              │
│  Sign Out                │
└──────────────────────────┘
```

---

## 5. AWS CLI — Switch Role Profiles

Configure your laptop to auto-switch roles.

### Run the config script

```bash
bash infrastructure/iam/configure_aws_profiles.sh \
  AKIAIOSFODNN7EXAMPLE \
  wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
  <STAGING_ACCOUNT_ID> \
  <PROD_ACCOUNT_ID>
```

Or configure manually:

**`~/.aws/credentials`** — paste this:
```ini
[default]
aws_access_key_id     = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

**`~/.aws/config`** — paste this:
```ini
[default]
region = ap-south-1
output = json

[profile aws-staging]
role_arn             = arn:aws:iam::<STAGING_ACCOUNT_ID>:role/CrossAccountAccessRole
source_profile       = default
external_id          = nse-staging-access
region               = ap-south-1
role_session_name    = aws-staging-session
# mfa_serial         = arn:aws:iam::<MASTER_ID>:mfa/vinod   # uncomment if MFA enabled

[profile aws-prod]
role_arn             = arn:aws:iam::<PROD_ACCOUNT_ID>:role/CrossAccountAccessRole
source_profile       = default
external_id          = nse-prod-access
region               = ap-south-1
role_session_name    = aws-prod-session
# mfa_serial         = arn:aws:iam::<MASTER_ID>:mfa/vinod
```

### Test

```bash
# Master account
aws sts get-caller-identity
# → {"Account": "<MASTER_ID>", "Arn": "arn:aws:iam::<MASTER_ID>:user/vinod"}

# Staging — auto-assumes CrossAccountAccessRole
aws sts get-caller-identity --profile aws-staging
# → {"Account": "<STAGING_ID>", "Arn": "arn:aws:sts::<STAGING_ID>:assumed-role/CrossAccountAccessRole/aws-staging-session"}

# Prod — auto-assumes CrossAccountAccessRole
aws sts get-caller-identity --profile aws-prod
# → {"Account": "<PROD_ID>", "Arn": "arn:aws:sts::<PROD_ID>:assumed-role/CrossAccountAccessRole/aws-prod-session"}
```

### Set staging as default for development

```bash
export AWS_PROFILE=aws-staging
```

Add to `~/.bashrc` or `~/.zshrc`:
```bash
export AWS_DEFAULT_REGION=ap-south-1
# Default to staging (safe) — switch to prod explicitly when needed
alias use-staging='export AWS_PROFILE=aws-staging && echo "✓ Using aws-staging"'
alias use-prod='export AWS_PROFILE=aws-prod && echo "⚠ Using PRODUCTION"'
alias use-master='unset AWS_PROFILE && echo "✓ Using master account"'
```

---

**Now run ALL remaining steps twice: once for staging, once for prod.**
**Switch your profile before each section.**

```bash
export AWS_PROFILE=aws-staging    # ← do section for staging
# ... run commands ...
export AWS_PROFILE=aws-prod       # ← do section for prod
# ... run same commands again ...
```

---

## 6. IAM — Lambda Execution Role

Lambda functions need permission to call DynamoDB, S3, SQS, SNS, etc.
Create this in BOTH staging and prod accounts.

```bash
# Run in staging
export AWS_PROFILE=aws-staging
bash infrastructure/iam/setup_lambda_role.sh

# Run in prod
export AWS_PROFILE=aws-prod
bash infrastructure/iam/setup_lambda_role.sh
```

### What this creates

```
Role name: NSELambdaRole
Trust:     lambda.amazonaws.com (Lambda can assume this role)
Policies:
  ✓ AmazonDynamoDBFullAccess       read/write all DynamoDB tables
  ✓ AmazonS3FullAccess             read/write S3 buckets
  ✓ AmazonSQSFullAccess            read/write SQS queues
  ✓ AmazonSNSFullAccess            publish to SNS topics
  ✓ AmazonSSMReadOnlyAccess        read SSM parameters (secrets)
  ✓ CloudWatchLogsFullAccess       write logs
  ✓ AWSXRayDaemonWriteAccess       send X-Ray traces
  ✓ ComprehendReadOnly             call Comprehend sentiment API
  ✓ AmazonRekognitionReadOnlyAccess call Rekognition
  ✓ TranslateReadOnly              call Translate
  ✓ AmazonSESFullAccess            send emails via SES
  ✓ AWSStepFunctionsFullAccess     start Step Functions executions
  ✓ AmazonEventBridgeFullAccess    publish EventBridge events
```

### Verify

```bash
aws iam get-role --role-name NSELambdaRole --profile aws-staging \
  --query "Role.Arn" --output text
# → arn:aws:iam::<STAGING_ID>:role/NSELambdaRole
```

---

## 7. IAM — GitHub OIDC (No Stored Keys)

GitHub Actions authenticates to AWS WITHOUT any access keys stored in GitHub.

### How OIDC works

```
GitHub Actions job starts
        ↓
GitHub generates a short-lived JWT (1 hour)
        ↓
GitHub Actions calls: aws-actions/configure-aws-credentials
  role-to-assume: arn:aws:iam::<STAGING_ID>:role/GitHubActionsRole-staging
        ↓
AWS STS verifies the JWT against GitHub's OIDC endpoint
        ↓
STS returns temporary credentials (valid 1 hour)
        ↓
Job deploys using those temp credentials
        ↓
Job ends → credentials automatically expire
```

No credentials ever stored in GitHub. If the token leaks, it expires in 1 hour.

### Setup — STAGING account

```bash
export AWS_PROFILE=aws-staging
bash infrastructure/iam/setup_oidc_github.sh staging vinodsharma412/aws-services
```

### Setup — PROD account

```bash
export AWS_PROFILE=aws-prod
bash infrastructure/iam/setup_oidc_github.sh prod vinodsharma412/aws-services
```

### What this creates

```
OIDC Provider: token.actions.githubusercontent.com
Role: GitHubActionsRole-staging
Trust policy:
  Principal: Federated OIDC provider
  Condition: token.actions.githubusercontent.com:sub
             = repo:vinodsharma412/aws-services:ref:refs/heads/develop
             (only THIS repo's develop branch can assume this role)
Permissions:
  Lambda: UpdateFunctionCode, UpdateFunctionConfiguration, CreateFunction
  S3: PutObject, DeleteObject, ListBucket
  CloudFront: CreateInvalidation
  SSM: GetParameter, PutParameter
```

### Verify in Console

```
Staging console → IAM → Identity providers
→ token.actions.githubusercontent.com (should exist)

IAM → Roles → GitHubActionsRole-staging (should exist)
→ Trust relationships → review the sub condition
```

---

## 8. S3 — Frontend + Avatar Buckets

Two buckets per account: one for the React frontend, one for user avatar images.

```bash
export AWS_PROFILE=aws-staging
bash infrastructure/scripts/s3_setup.sh
```

### What this creates

**Frontend bucket**: `nse-frontend-<ACCOUNT_ID>`
```
Type     : Static website hosting
Access   : Public read (anyone can view the website)
CORS     : allowed for all origins
Index    : index.html
Error    : index.html (React Router handles 404s)
Versioning: enabled
```

**Assets bucket**: `nse-assets-<ACCOUNT_ID>`
```
Type     : Private
Access   : Only via Lambda (NSELambdaRole has read/write)
Lifecycle: Delete avatar files after 365 days if replaced
```

### Verify

```bash
aws s3 ls --profile aws-staging | grep nse
# nse-frontend-<STAGING_ID>
# nse-assets-<STAGING_ID>
```

### Console view

```
Console → S3 → Buckets
→ nse-frontend-<ID> → Properties → Static website hosting → should show endpoint URL
→ nse-assets-<ID>   → Permissions → Block all public access: ON
```

---

## 9. DynamoDB — 13 Tables

All tables are identical in staging and prod accounts (no prefix — accounts isolate them).

```bash
export AWS_PROFILE=aws-staging
AWS_REGION=ap-south-1 python3 infrastructure/dynamodb/create_tables.py
```

### Tables created

| Table | Primary Key | Purpose | GSIs |
|---|---|---|---|
| `users` | `user_id` | User accounts + Cognito mapping | username-index, email-index |
| `stock_transactions` | `txn_id` | Buy/sell/dividend history | user-transactions-index |
| `stock_watchlist` | `wl_id` | Per-user watchlist | user-watchlist-index, user-symbol-index |
| `scraping_jobs` | `job_id` | Amazon scraping jobs | user-jobs-index |
| `scraping_tasks` | `task_id` | Per-ASIN tasks in a job | job-tasks-index, status-index |
| `product_data` | `task_id` | Scraped product content | — |
| `screener_cache` | `cache_key` | Pre-computed screener results | — |
| `menus` | `menu_id` | Navigation menu items | path-index, parent-index |
| `menu_access` | `access_id` | Role → menu permission | menu-index, role-index |
| `ws_connections` | `connection_id` | Active WebSocket sessions | job-connections-index |
| `product_master` | `product_id` | Product catalog | — |
| `email_messages` | `message_id` | Email inbox tracking | uid-index, status-index, category-index |
| `email_sync_state` | `sync_key` | IMAP sync cursor | — |

### All tables have:
- `PAY_PER_REQUEST` billing (free tier: 25 RCU/WCU)
- `AES256` encryption (AWS-managed key, free)
- `ws_connections` also has **TTL** on `ttl` attribute (auto-deletes after 2 hours)

### Verify

```bash
aws dynamodb list-tables --region ap-south-1 --profile aws-staging
# → should show all 13 table names

# Check one table
aws dynamodb describe-table --table-name users \
  --region ap-south-1 --profile aws-staging \
  --query "Table.{Status:TableStatus,Billing:BillingModeSummary.BillingMode,Encryption:SSEDescription.Status}"
# → {"Status": "ACTIVE", "Billing": "PAY_PER_REQUEST", "Encryption": "ENABLED"}
```

### Console view

```
Console → DynamoDB → Tables
→ 13 tables listed, all ACTIVE
→ Click users → Indexes tab → username-index, email-index
→ Click ws_connections → Additional settings → TTL: Enabled on "ttl"
```

---

## 10. SSM Parameter Store — Secrets

Store all secrets. Lambda reads them at cold start. Nothing in code or environment variables.

```bash
export AWS_PROFILE=aws-staging
bash infrastructure/ssm/setup_ssm.sh staging
```

You will be prompted for:
1. **JWT secret**: paste output of `openssl rand -hex 32`
2. **Gmail user**: your Gmail address (for SES email alerts)
3. **Gmail app password**: Generate at myaccount.google.com → Security → App passwords

### Parameters created

```
/nse/staging/jwt-secret          SecureString  JWT signing key
/nse/staging/gmail-user          SecureString  Gmail sender address
/nse/staging/gmail-password      SecureString  Gmail app password
/nse/staging/s3-assets-bucket    String        nse-assets-<ID>
/nse/staging/s3-frontend-bucket  String        nse-frontend-<ID>
```

Others are added automatically by later scripts:
```
/nse/staging/cognito-user-pool-id     (added by cognito setup)
/nse/staging/cognito-client-id        (added by cognito setup)
/nse/staging/sqs-jobs-url             (added by SQS setup)
/nse/staging/sns-alerts-arn           (added by SNS setup)
/nse/staging/api-gateway-url          (added by API GW setup)
/nse/staging/api-gateway-id           (added by API GW setup)
/nse/staging/websocket-url            (added by WebSocket setup)
/nse/staging/websocket-endpoint       (added by WebSocket setup)
/nse/staging/stepfunctions-scraping-arn  (added by Step Functions setup)
/nse/staging/shared-layer-arn         (added by Lambda Layer deploy)
```

### Verify

```bash
aws ssm describe-parameters \
  --filters Key=Path,Values=/nse/staging/ \
  --profile aws-staging \
  --query "Parameters[].Name"
# → ["/nse/staging/jwt-secret", "/nse/staging/gmail-user", ...]
```

### Console view

```
Console → Systems Manager → Parameter Store
→ Filter by path: /nse/staging/
→ Click jwt-secret → Type: SecureString (encrypted, cannot see value in console)
```

---

## 11. Cognito — User Pool + Identity Pool

Replaces custom JWT auth. Cognito handles user storage, password hashing, MFA, tokens.

```bash
export AWS_PROFILE=aws-staging
bash infrastructure/cognito/setup_cognito.sh staging your@email.com
```

### What this creates

**User Pool**: `nse-users-staging`
```
Username attribute  : email (login with email)
Password policy     : min 8 chars, requires numbers
Email verification  : auto-send verification code
Custom attribute    : custom:role (admin/manager/viewer)
MFA                 : optional (can enable later)
```

**App Client**: `nse-web-client-staging`
```
No client secret  (SPA compatible — no server-side secret storage)
Auth flows:
  ✓ USER_PASSWORD_AUTH  (for direct username/password login)
  ✓ REFRESH_TOKEN_AUTH  (for token refresh)
  ✓ USER_SRP_AUTH       (Secure Remote Password — more secure)
```

**Identity Pool**: `nse_identity_staging`
```
Provider: Cognito User Pool (nse-users-staging)
Authenticated: mapped to IAM role (can call AWS services directly from browser)
Unauthenticated: disabled
```

**Admin user**:
```
Username: admin
Email: your@email.com
Temporary password: Nse@2025! (must change on first login)
Role: admin
```

### Verify

```bash
# List user pools
aws cognito-idp list-user-pools --max-results 10 \
  --profile aws-staging --region ap-south-1 \
  --query "UserPools[].{Name:Name, Id:Id}"
# → [{"Name": "nse-users-staging", "Id": "ap-south-1_XXXXXXXXX"}]

# Check admin user exists
POOL_ID=$(aws ssm get-parameter --name /nse/staging/cognito-user-pool-id \
  --query Parameter.Value --output text --profile aws-staging)
aws cognito-idp admin-get-user --user-pool-id $POOL_ID --username admin \
  --profile aws-staging --region ap-south-1 \
  --query "UserAttributes[?Name=='custom:role'].Value"
# → ["admin"]
```

### Console view

```
Console → Cognito → User pools → nse-users-staging
→ Users tab → admin user listed
→ App clients → nse-web-client-staging
→ Sign-in experience → Authentication flows (USER_PASSWORD_AUTH should be checked)
```

---

## 12. SQS — Scraping Queue + DLQ

Message queue for scraping tasks. If a task fails 3 times, goes to DLQ.

```bash
export AWS_PROFILE=aws-staging
bash infrastructure/sqs/setup_sqs.sh staging
```

### What this creates

**Main queue**: `nse-scraping-jobs-staging`
```
Type              : Standard (at-least-once, best-effort ordering)
Visibility timeout: 300 seconds (5 min — how long worker has to process)
Message retention : 4 days
Max message size  : 256 KB
Long polling      : 20 seconds (reduces empty receive calls, saves API requests)
Redrive policy    : maxReceiveCount=3 → DLQ after 3 failures
```

**Dead Letter Queue**: `nse-scraping-jobs-staging-dlq`
```
Type             : Standard
Message retention: 14 days (you have 2 weeks to investigate failures)
Triggers         : Lambda nse-dlq-alert-staging (when messages arrive)
```

**Cost calculation** (why it's free):
```
Long-polling: one receive call per 20 seconds
= 3 calls/min × 60 min × 24 h × 30 days = 129,600 calls/month
SQS free tier: 1,000,000 calls/month
→ Uses ~13% of free tier ✓
```

### Verify

```bash
aws sqs list-queues --profile aws-staging --region ap-south-1 \
  --query "QueueUrls[]"
# → ["https://sqs.ap-south-1.amazonaws.com/.../nse-scraping-jobs-staging",
#    "https://sqs.ap-south-1.amazonaws.com/.../nse-scraping-jobs-staging-dlq"]

# Check queue attributes
QUEUE_URL=$(aws ssm get-parameter --name /nse/staging/sqs-jobs-url \
  --query Parameter.Value --output text --profile aws-staging)
aws sqs get-queue-attributes --queue-url $QUEUE_URL \
  --attribute-names All --profile aws-staging \
  --query "Attributes.{Timeout:VisibilityTimeout,Retention:MessageRetentionPeriod,Redrive:RedrivePolicy}"
```

### Console view

```
Console → SQS → Queues
→ nse-scraping-jobs-staging → Details tab
  Visibility timeout: 300 seconds
  DLQ: nse-scraping-jobs-staging-dlq
→ nse-scraping-jobs-staging-dlq → Message retention: 14 days
```

---

## 13. SNS — Alert Notifications

Publish to this topic → email arrives in your inbox.

```bash
export AWS_PROFILE=aws-staging
bash infrastructure/sns/setup_sns.sh staging your@email.com
```

### What this creates

**Topic**: `nse-alerts-staging`
```
Type         : Standard
Protocol     : Email → your@email.com
ARN          : arn:aws:sns:ap-south-1:<ID>:nse-alerts-staging
```

**IMPORTANT**: Check your email now. AWS sends a confirmation email.
You MUST click **Confirm subscription** or you will never receive alerts.

### Subscribers (added automatically by other setup scripts)

```
your@email.com          → CloudWatch alarms, SQS DLQ alerts
Lambda: nse-dlq-alert   → scraping task permanently failed
Lambda: nse-ses-notify  → job completed (triggers email report)
```

### Verify

```bash
SNS_ARN=$(aws ssm get-parameter --name /nse/staging/sns-alerts-arn \
  --query Parameter.Value --output text --profile aws-staging)
aws sns list-subscriptions-by-topic --topic-arn $SNS_ARN \
  --profile aws-staging \
  --query "Subscriptions[].{Protocol:Protocol, Endpoint:Endpoint, Status:SubscriptionArn}"
```

### Console view

```
Console → SNS → Topics → nse-alerts-staging
→ Subscriptions tab
→ your email → Status: Confirmed (must be Confirmed, not PendingConfirmation)
```

---

## 14. SES — Transactional Email

Send job completion reports and daily portfolio summaries via email.

```bash
export AWS_PROFILE=aws-staging
bash infrastructure/ses/setup_ses.sh staging your@email.com
```

**Check email** — click the verification link AWS sends.

### Important: SES sandbox mode

New AWS accounts start in **SES sandbox**. You can only send to verified emails.
To send to anyone:
```
Console → SES → Account dashboard → Production access
→ Request production access → fill form → wait 24 hours for approval
```

For a practice project, sandbox is fine (you just receive your own emails).

### Verify

```bash
aws ses get-account-sending-enabled --profile aws-staging --region ap-south-1
# → {"Enabled": true}

aws ses list-verified-email-addresses --profile aws-staging --region ap-south-1
# → {"VerifiedEmailAddresses": ["your@email.com"]}
```

### Console view

```
Console → SES → Verified identities
→ your@email.com → Status: Verified (green)
Console → SES → Account dashboard → Sending quota
→ Max 200 emails/day in sandbox (62K/month from Lambda in production)
```

---

## 15. Lambda Layer — Shared Utilities

A Lambda Layer is shared code attached to multiple Lambda functions.
Our layer contains: `aws_xray_sdk` (tracing) + `utils/appconfig.py` (feature flags).

```bash
export AWS_PROFILE=aws-staging
bash infrastructure/lambda/layer/deploy.sh staging
```

### What this creates

```
Layer name : nse-shared-utils
Contents   :
  python/
    aws_xray_sdk/          ← AWS X-Ray SDK (traces Lambda calls)
    wrapt/                 ← dependency of xray_sdk
    utils/
      __init__.py
      appconfig.py         ← feature flag helper
      xray_helper.py       ← tracing decorators
      response.py          ← (if present) HTTP response helpers
Compatible runtimes: python3.12
```

**Why use a layer instead of bundling in each Lambda?**
- The layer is deployed once, shared by all 12+ Lambda functions
- Reduces each Lambda package size (~15 MB saved per function)
- Update the layer → all functions get the update without redeployment

### Verify

```bash
aws lambda list-layers --compatible-runtime python3.12 \
  --profile aws-staging --region ap-south-1 \
  --query "Layers[?contains(LayerName,'nse')].{Name:LayerName, ARN:LatestMatchingVersion.LayerVersionArn}"
# → [{"Name": "nse-shared-utils", "ARN": "arn:aws:lambda:...:layer:nse-shared-utils:1"}]

# ARN is saved to SSM for Lambda deploy scripts to read
aws ssm get-parameter --name /nse/staging/shared-layer-arn \
  --query Parameter.Value --output text --profile aws-staging
```

### Console view

```
Console → Lambda → Layers
→ nse-shared-utils → Version 1
→ Compatible runtimes: Python 3.12
→ Size: ~5 MB
```

---

## 16. Lambda — All Functions

Deploy all Lambda functions for the staging account.

### 16a. API Lambda (handles all REST routes)

```bash
export AWS_PROFILE=aws-staging
bash infrastructure/lambda/api/deploy.sh staging
```

**Function**: `nse-api-staging`
```
Runtime       : Python 3.12
Handler       : handlers.health.handler   (entry point, routes internally)
Memory        : 512 MB (yfinance + pandas need headroom)
Timeout       : 30 seconds (API Gateway max is 29s)
Layers        : AWSSDKPandas-Python312 + nse-shared-utils
Tracing       : Active (X-Ray)
Environment:
  STAGE       = staging
  AWS_REGION  = ap-south-1
```

**Routes handled by this function** (API Gateway decides which path):

| Route | Handler file |
|---|---|
| `POST /auth/login` | `handlers/auth.py` |
| `POST /auth/refresh` | `handlers/auth.py` |
| `POST /auth/register` | `handlers/auth.py` |
| `GET /users/me` | `handlers/users.py` |
| `POST /users/me/avatar` | `handlers/users.py` (+ Rekognition) |
| `GET /stocks/*` | `handlers/stocks.py` (yfinance + Comprehend + Translate) |
| `POST /scraping/jobs` | `handlers/scraping.py` (+ Step Functions) |
| `GET /scraping/jobs` | `handlers/scraping.py` |
| `GET /health` | `handlers/health.py` |

### 16b. Scraping Worker Lambda (SQS-triggered)

```bash
bash infrastructure/lambda/scraping_worker/deploy.sh staging
```

**Function**: `nse-scraping-worker-staging`
```
Runtime       : Python 3.12
Handler       : handler.lambda_handler
Memory        : 256 MB
Timeout       : 120 seconds (scraping takes up to 2 min)
Trigger       : SQS queue nse-scraping-jobs-staging (batch size = 1)
Retry         : SQS automatically retries up to 3 times, then DLQ
Tracing       : Active (X-Ray)
```

**What it does per invocation:**
```
1. Receive {task_id} from SQS
2. Fetch task record from DynamoDB
3. Mark status = "running"
4. httpx.get(amazon.in/dp/{asin})
5. BeautifulSoup parse: title, price, rating, image, brand
6. DynamoDB: task = "completed", product data saved
7. DLQ triggers nse-dlq-alert if this fails 3 times
```

### 16c. DLQ Alert Lambda

```bash
cd infrastructure/lambda/dlq_alert
zip handler.zip handler.py
aws lambda create-function \
  --function-name nse-dlq-alert-staging \
  --runtime python3.12 \
  --handler handler.lambda_handler \
  --zip-file fileb://handler.zip \
  --role arn:aws:iam::<STAGING_ID>:role/NSELambdaRole \
  --timeout 30 --memory-size 128 \
  --environment Variables="{STAGE=staging,AWS_REGION=ap-south-1}" \
  --tracing-config Mode=Active \
  --region ap-south-1 \
  --profile aws-staging

# Wire DLQ as trigger
DLQ_ARN=$(aws sqs get-queue-attributes \
  --queue-url $(aws ssm get-parameter --name /nse/staging/sqs-jobs-url \
    --query Parameter.Value --output text --profile aws-staging) \
  --attribute-names QueueArn \
  --query Attributes.QueueArn --output text --profile aws-staging \
  --region ap-south-1 | sed 's/nse-scraping-jobs-staging/nse-scraping-jobs-staging-dlq/')

aws lambda create-event-source-mapping \
  --function-name nse-dlq-alert-staging \
  --event-source-arn $DLQ_ARN \
  --batch-size 1 \
  --region ap-south-1 \
  --profile aws-staging
```

### 16d. Scheduled Lambdas (screener + universe)

```bash
# screener-refresh: updates screener cache every 30 min during market hours
cd infrastructure/lambda/screener_refresh
bash deploy.sh staging

# universe-refresh: downloads NSE symbol list daily
cd ../universe_refresh
bash deploy.sh staging
```

### Verify all functions

```bash
aws lambda list-functions --profile aws-staging --region ap-south-1 \
  --query "Functions[?contains(FunctionName,'nse')].{Name:FunctionName, State:State, Memory:MemorySize}"
```

Expected output:
```json
[
  {"Name": "nse-api-staging",                "State": "Active", "Memory": 512},
  {"Name": "nse-scraping-worker-staging",    "State": "Active", "Memory": 256},
  {"Name": "nse-dlq-alert-staging",          "State": "Active", "Memory": 128},
  {"Name": "nse-screener-refresh-staging",   "State": "Active", "Memory": 512},
  {"Name": "nse-universe-refresh-staging",   "State": "Active", "Memory": 256}
]
```

### Console view

```
Console → Lambda → Functions
→ Filter: nse → 5+ functions listed
→ Click nse-api-staging:
  → Configuration → General: Memory 512, Timeout 30s
  → Configuration → Permissions: NSELambdaRole
  → Configuration → Environment variables: STAGE=staging
  → Configuration → Monitoring: X-Ray Active Tracing enabled
  → Layers: 2 layers attached (AWSSDKPandas + nse-shared-utils)
→ Click nse-scraping-worker-staging:
  → Triggers tab: SQS nse-scraping-jobs-staging (batch size 1)
```

---

## 17. API Gateway HTTP API — REST Endpoints

API Gateway is the front door. All REST calls go through it.

```bash
export AWS_PROFILE=aws-staging
bash infrastructure/scripts/api_gateway_setup.sh staging
```

### What this creates

```
API Name    : nse-api-staging
Protocol    : HTTP API (cheaper and faster than REST API)
Stage       : $default (auto-deploy on every change)

Routes:
  ANY /{proxy+}  →  Lambda: nse-api-staging
  $default       →  Lambda: nse-api-staging

JWT Authorizer:
  Provider: Cognito User Pool nse-users-staging
  Issuer  : https://cognito-idp.ap-south-1.amazonaws.com/<POOL_ID>
  Audience: <CLIENT_ID>
  All routes except /health and /auth/* require valid Cognito token

CORS:
  Allow origins   : *
  Allow methods   : GET, POST, PUT, DELETE, PATCH, OPTIONS
  Allow headers   : Authorization, Content-Type
  Max age         : 300 seconds (5 min browser cache)

Throttling:
  Burst : 50 requests
  Rate  : 20 requests/second
  (prevents runaway Lambda costs if traffic spikes)

Access logging → CloudWatch: /aws/apigateway/nse-api-staging
  Format: JSON with requestId, IP, method, path, status, latency, error
```

### Invoke URL saved to SSM

```bash
aws ssm get-parameter --name /nse/staging/api-gateway-url \
  --query Parameter.Value --output text --profile aws-staging
# → https://abc123xyz.execute-api.ap-south-1.amazonaws.com
```

### Test immediately

```bash
API_URL=$(aws ssm get-parameter --name /nse/staging/api-gateway-url \
  --query Parameter.Value --output text --profile aws-staging)

# Health check (no auth needed)
curl -s "${API_URL}/api/v1/health/" | python3 -m json.tool
# → {"status": "ok", "stage": "staging", "region": "ap-south-1", ...}

# Try without auth (should return 401)
curl -s "${API_URL}/api/v1/users/me"
# → {"message": "Unauthorized"}
```

### Console view

```
Console → API Gateway → APIs → nse-api-staging
→ Routes: shows ALL routes (ANY /{proxy+}, $default)
→ Authorization: JWT authorizer on most routes
→ Stages → $default → Invoke URL: https://abc123.execute-api.ap-south-1.amazonaws.com
→ Logging → Access log group: /aws/apigateway/nse-api-staging
```

---

## 18. API Gateway WebSocket API — Real-Time

WebSocket pushes task updates to browser instantly. No polling needed.

```bash
export AWS_PROFILE=aws-staging
bash infrastructure/websocket/setup_websocket_api.sh staging
```

### What this creates

**WebSocket API**: `nse-ws-staging`
```
Protocol          : WebSocket
Route selection   : $request.body.action
Stage             : staging (auto-deploy)

Routes:
  $connect     → nse-ws-staging Lambda (store connection in DynamoDB)
  $disconnect  → nse-ws-staging Lambda (remove connection from DynamoDB)
  $default     → nse-ws-staging Lambda (subscribe to job, ping)
```

**DynamoDB table**: `ws_connections`
```
connection_id (PK)     the WebSocket connection ID
user_id                which user is connected
job_id                 which job they subscribed to (optional)
ttl                    Unix timestamp 2 hours from now
                       DynamoDB TTL auto-deletes expired connections
```

**WebSocket URL**: `wss://xyz.execute-api.ap-south-1.amazonaws.com/staging`

### How the browser uses it

```javascript
// Frontend connects after creating a scraping job
const ws = new WebSocket('wss://<WS_ID>.execute-api.ap-south-1.amazonaws.com/staging?user_id=<USER_ID>');

ws.onopen = () => {
  // Subscribe to specific job
  ws.send(JSON.stringify({ action: 'subscribe', job_id: '<JOB_UUID>' }));
};

ws.onmessage = (event) => {
  const update = JSON.parse(event.data);
  // update = { type: 'job_update', pending: 3, running: 2, completed: 5, failed: 0 }
  setJobState(update);
};
```

### Verify

```bash
# Get WebSocket URL
aws ssm get-parameter --name /nse/staging/websocket-url \
  --query Parameter.Value --output text --profile aws-staging
# → wss://xyz.execute-api.ap-south-1.amazonaws.com/staging

# Test with wscat (install: npm install -g wscat)
wscat -c "wss://xyz.execute-api.ap-south-1.amazonaws.com/staging?user_id=test"
# connected (press CTRL+C to quit)
# > {"action": "ping"}
# < {"type": "pong"}
```

### Console view

```
Console → API Gateway → APIs → nse-ws-staging
→ Routes: $connect, $disconnect, $default
→ Stages → staging → WebSocket URL: wss://...
```

---

## 19. DynamoDB Streams — Event-Driven Push

When a scraping task status changes in DynamoDB, a stream event fires immediately.
The `nse-dynamo-streams` Lambda picks it up and pushes to connected WebSocket clients.

```bash
# Enable streams on scraping_tasks table
aws dynamodb update-table \
  --table-name scraping_tasks \
  --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
  --region ap-south-1 --profile aws-staging

# Deploy the streams Lambda
cd infrastructure/lambda
BUILD=/tmp/streams && rm -rf $BUILD && mkdir $BUILD
pip install aws-xray-sdk boto3 -t $BUILD/ -q
cp ../../backend/handlers/dynamo_streams.py $BUILD/handler.py
cp ../../backend/handlers/_base.py $BUILD/
cd $BUILD && zip -r /tmp/streams.zip . -q

aws lambda create-function \
  --function-name nse-dynamo-streams-staging \
  --runtime python3.12 --handler handler.handler \
  --zip-file fileb:///tmp/streams.zip \
  --role arn:aws:iam::<STAGING_ID>:role/NSELambdaRole \
  --timeout 30 --memory-size 256 \
  --environment Variables="{STAGE=staging,AWS_REGION=ap-south-1}" \
  --tracing-config Mode=Active \
  --region ap-south-1 --profile aws-staging

# Wire DynamoDB Stream as trigger
STREAM_ARN=$(aws dynamodb describe-table --table-name scraping_tasks \
  --query "Table.LatestStreamArn" --output text \
  --region ap-south-1 --profile aws-staging)

aws lambda create-event-source-mapping \
  --function-name nse-dynamo-streams-staging \
  --event-source-arn $STREAM_ARN \
  --starting-position LATEST \
  --batch-size 10 \
  --region ap-south-1 --profile aws-staging
```

### How it works

```
Step 1: Worker Lambda updates scraping_tasks:
        task_id=abc → status="completed", product={title, price, ...}

Step 2: DynamoDB Streams emits record (NEW_AND_OLD_IMAGES):
        {eventName: "MODIFY", dynamodb: {NewImage: {...}, OldImage: {...}}}

Step 3: nse-dynamo-streams Lambda is triggered automatically

Step 4: Lambda queries ws_connections:
        "Find all connections where job_id = <this task's job_id>"

Step 5: For each connection:
        API Gateway Management API → post_to_connection(connection_id, update_json)

Step 6: Browser's ws.onmessage fires with the update
        (typically < 500ms after the DynamoDB write)
```

### Console view

```
Console → Lambda → nse-dynamo-streams-staging
→ Triggers tab: DynamoDB scraping_tasks (starting position: Latest)
Console → DynamoDB → Tables → scraping_tasks
→ Exports and streams → DynamoDB stream: ENABLED, NEW_AND_OLD_IMAGES
```

---

## 20. Step Functions — Parallel Scraping

Orchestrate scraping as a workflow: fan-out to N parallel Lambda invocations.

```bash
export AWS_PROFILE=aws-staging
bash infrastructure/stepfunctions/setup_stepfunctions.sh staging
```

### State machine logic

```json
{
  "StartAt": "ProcessAllASINs",
  "States": {
    "ProcessAllASINs": {
      "Type": "Map",
      "MaxConcurrency": 5,
      "Iterator": {
        "StartAt": "ScrapeASIN",
        "States": {
          "ScrapeASIN": {
            "Type": "Task",
            "Resource": "arn:aws:lambda:...:nse-scraping-worker-staging",
            "Retry": [{ "MaxAttempts": 2, "IntervalSeconds": 10 }],
            "Catch": [{ "ErrorEquals": ["States.ALL"], "Next": "RecordFailure" }],
            "End": true
          },
          "RecordFailure": { "Type": "Pass", "End": true }
        }
      },
      "Next": "PublishCompletion"
    },
    "PublishCompletion": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sns:publish",
      "Parameters": {
        "TopicArn": "arn:aws:sns:...:nse-alerts-staging",
        "Message.$": "States.Format('Job {} complete', $.job_id)"
      },
      "Next": "JobDone"
    },
    "JobDone": { "Type": "Succeed" }
  }
}
```

**For 10 ASINs with MaxConcurrency=5:**
```
t=0s: scrape ASIN 1, 2, 3, 4, 5 simultaneously
t=~30s: ASIN 3 finishes → immediately start ASIN 6
t=~45s: all done → SNS notification
```

### Free tier calculation

```
1 job with 10 ASINs:
  ~30 state transitions (Map entry + 10 task entries + Map exit + SNS + Succeed)
  
Free tier: 4,000 transitions/month
= ~133 jobs/month FREE

After free tier: $0.025 per 1,000 transitions = $0.00075 per 10-ASIN job
```

### Verify

```bash
SFN_ARN=$(aws ssm get-parameter --name /nse/staging/stepfunctions-scraping-arn \
  --query Parameter.Value --output text --profile aws-staging)

aws stepfunctions describe-state-machine \
  --state-machine-arn $SFN_ARN \
  --query "{Name:name, Status:status, Tracing:tracingConfiguration}" \
  --profile aws-staging
```

### Console view

```
Console → Step Functions → State machines → nse-scraping-staging
→ Definition → visual graph shows the Map state branching out
→ Executions → (empty until first job submitted)
→ click an execution → shows each ASIN's scrape result
```

---

## 21. EventBridge — Scheduled Jobs

Two scheduled Lambda triggers: NSE symbol refresh and screener cache refresh.

```bash
export AWS_PROFILE=aws-staging
bash infrastructure/eventbridge/setup_eventbridge.sh staging
```

### Rules created

**Rule 1**: `nse-universe-refresh-staging`
```
Schedule  : cron(30 20 * * ? *)   = daily 2:00 AM IST (20:30 UTC)
Target    : Lambda nse-universe-refresh-staging
What it does:
  Downloads NSE EQUITY_L.csv from nse.india.com
  Parses 1800+ stock symbols + company names
  Writes to DynamoDB product_data table (key: "nse_universe")
  Used by: stock search, screener, portfolio lookup
```

**Rule 2**: `nse-screener-refresh-staging`
```
Schedule  : cron(0/30 1-11 ? * MON-FRI *)  = every 30 min, Mon-Fri, 6:30AM-5PM IST
Target    : Lambda nse-screener-refresh-staging
What it does:
  Calls screen_stocks(min_yield=0.03, max_pe=50)
  Computes top 40 dividend + value stocks
  Writes result to DynamoDB screener_cache table
  API /stocks/screener reads cache → response in <100ms
  Without cache: live computation takes 70+ seconds (30+ yfinance calls)
```

**EventBridge also handles custom events**:
```
Source: nse.scraping
Detail-Type: JobCompleted
→ Rule: invoke nse-ses-notifications Lambda
→ Lambda: sends job report email via SES
```

### Verify

```bash
aws events list-rules --name-prefix nse \
  --profile aws-staging --region ap-south-1 \
  --query "Rules[].{Name:Name, State:State, Schedule:ScheduleExpression}"
```

### Console view

```
Console → EventBridge → Rules → filter: nse
→ nse-universe-refresh-staging → Enabled → Schedule: cron(30 20 * * ? *)
→ nse-screener-refresh-staging → Enabled → Schedule: cron(0/30 1-11 ? * MON-FRI *)
→ Click any rule → Targets tab → Lambda function shown
```

---

## 22. CloudFront — CDN + HTTPS

Serve the React frontend from CloudFront instead of direct S3 (no HTTPS on S3).

```bash
export AWS_PROFILE=aws-staging
bash infrastructure/cloudfront/setup_cloudfront.sh staging
```

### What this creates

```
Origin              : S3 bucket nse-frontend-<STAGING_ID>
Price class         : PriceClass_200 (US, Europe, Asia — covers India)
HTTPS               : Required (redirects HTTP to HTTPS)
SSL certificate     : AWS Certificate Manager (ACM) — FREE
Compression         : Gzip + Brotli enabled
Cache behaviors:
  /static/*         → Cache 1 year (content-hashed filenames)
  /index.html       → No cache (always fresh)
  /*                → Short TTL (5 min default)
Custom error pages  :
  404 → /index.html  (React Router handles routing)
  403 → /index.html
```

**Distribution URL**: `https://d1234xyz.cloudfront.net`

This is saved to SSM: `/nse/staging/cloudfront-url`

### Verify

```bash
DIST_ID=$(aws ssm get-parameter --name /nse/staging/cloudfront-dist-id \
  --query Parameter.Value --output text --profile aws-staging)
aws cloudfront get-distribution --id $DIST_ID \
  --query "Distribution.{Status:Status, Domain:DomainName}" \
  --profile aws-staging
# → {"Status": "Deployed", "Domain": "d1234xyz.cloudfront.net"}
```

Wait 5-15 minutes for CloudFront to deploy globally.

### Console view

```
Console → CloudFront → Distributions
→ Your distribution → Status: Deployed (wait if still InProgress)
→ General tab → Distribution domain name: d1234xyz.cloudfront.net
→ Origins tab → S3 bucket nse-frontend-<ID>
→ Behaviors tab → /static/* with TTL 31536000, /* with shorter TTL
→ Error pages tab → 404 → /index.html
```

---

## 23. AppConfig — Feature Flags

Change feature flags without redeploying Lambda.

```bash
export AWS_PROFILE=aws-staging
bash infrastructure/appconfig/setup_appconfig.sh staging
```

### Flags created

```
Application: NSEDashboard
Environment: Staging

Feature flags:
  COMPREHEND_ENABLED     : true   → use AI sentiment analysis
  TRANSLATE_ENABLED      : true   → translate product titles
  STEP_FUNCTIONS_ENABLED : true   → use Step Functions for scraping
  BETA_SCREENER          : false  → new screener algorithm (disabled)
```

### Change a flag (no redeploy needed)

```
Console → AppConfig → NSEDashboard → FeatureFlags
→ Edit configuration
→ Change COMPREHEND_ENABLED to false  (if hitting quota limits)
→ Start deployment
→ Takes effect in ≤ 30 seconds across ALL Lambda invocations
```

This is how you do **gradual feature rollout** and **emergency toggles**.

### Console view

```
Console → AppConfig → NSEDashboard
→ Environments → Staging
→ Configuration profiles → FeatureFlags
→ Latest deployed version → click to see JSON
```

---

## 24. KMS — Encryption

Enable encryption for DynamoDB tables using AWS-managed keys (free).

```bash
export AWS_PROFILE=aws-staging
bash infrastructure/kms/setup_kms.sh staging
```

### What this does

- Enables `AES256` (SSE-S3) encryption on all 13 DynamoDB tables
- Uses AWS-managed key `aws/dynamodb` — no cost for the key itself
- No KMS API call charges (AWS-managed keys are free for DynamoDB)
- Data at rest is encrypted automatically

### S3 bucket encryption

```bash
# Enable encryption on S3 buckets
for BUCKET in nse-frontend-<ID> nse-assets-<ID>; do
  aws s3api put-bucket-encryption \
    --bucket $BUCKET \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' \
    --profile aws-staging
done
```

### Console view

```
Console → DynamoDB → Tables → users
→ Additional settings tab
→ Encryption at rest: ENABLED, AES-256

Console → S3 → nse-assets-<ID>
→ Properties tab
→ Default encryption: Amazon S3 managed keys (SSE-S3)
```

---

## 25. CloudWatch — Logs, Alarms, Dashboard

Set up monitoring for the staging account.

```bash
export AWS_PROFILE=aws-staging
API_GW_ID=$(aws ssm get-parameter --name /nse/staging/api-gateway-id \
  --query Parameter.Value --output text)
bash infrastructure/cloudwatch/setup_alarms.sh staging $API_GW_ID
```

### Log groups created

Lambda creates log groups automatically on first invocation:
```
/aws/lambda/nse-api-staging                ← every API request
/aws/lambda/nse-scraping-worker-staging    ← every scraping task
/aws/lambda/nse-dynamo-streams-staging     ← every WS push event
/aws/lambda/nse-dlq-alert-staging          ← DLQ alerts
/aws/lambda/nse-screener-refresh-staging   ← screener cache updates
/aws/lambda/nse-universe-refresh-staging   ← symbol list updates
/aws/apigateway/nse-api-staging            ← API GW access logs
/aws/states/nse-scraping-staging           ← Step Functions logs
```

All log groups: 30-day retention (saves cost after 30 days).

### Alarms created (6 per stage)

```
Alarm 1: nse-lambda-api-errors-staging
  Metric: Lambda Errors > 0 in 5 minutes
  Action: SNS → email "API Lambda error in staging"

Alarm 2: nse-lambda-worker-errors-staging
  Metric: Lambda Errors > 0 in 5 minutes
  Action: SNS → email "Worker Lambda error"

Alarm 3: nse-sqs-dlq-depth-staging
  Metric: SQS ApproximateNumberOfMessagesVisible > 0
  Queue : nse-scraping-jobs-staging-dlq
  Action: SNS → email "Scraping task permanently failed"

Alarm 4: nse-apigw-5xx-staging
  Metric: API Gateway 5XXError > 10 in 5 minutes
  Action: SNS → email "API returning server errors"

Alarm 5: nse-lambda-screener-errors-staging
  Metric: Lambda Errors > 0 in 5 minutes (screener function)
  Action: SNS → email "Screener cache not updating"

Alarm 6: nse-lambda-universe-errors-staging
  Metric: Lambda Errors > 0 in 5 minutes (universe function)
  Action: SNS → email "NSE symbol list not updating"
```

### Dashboard: NSE-Operations-staging

```
Console → CloudWatch → Dashboards → NSE-Operations-staging

Panels:
  Row 1:
    Lambda Invocations & Errors (all functions, 5min intervals)
    SQS Queue Depth (main + DLQ)
    API Gateway Requests (total, 4xx, 5xx)

  Row 2:
    Lambda Duration p50/p99 (response time percentiles)
    DynamoDB Consumed RCU/WCU
    Step Functions Executions (success vs fail)
```

### Live log tailing

```bash
# API logs (live)
aws logs tail /aws/lambda/nse-api-staging --follow \
  --profile aws-staging --region ap-south-1

# Worker logs
aws logs tail /aws/lambda/nse-scraping-worker-staging --follow \
  --profile aws-staging --region ap-south-1

# Filter errors only
aws logs filter-log-events \
  --log-group-name /aws/lambda/nse-api-staging \
  --filter-pattern "ERROR" \
  --profile aws-staging --region ap-south-1
```

---

## 26. X-Ray — Distributed Tracing

X-Ray shows exactly how long each component takes — which DynamoDB call, which API call.

### Enable on Lambda functions

```bash
for FUNC in nse-api-staging nse-scraping-worker-staging nse-dynamo-streams-staging; do
  aws lambda update-function-configuration \
    --function-name $FUNC \
    --tracing-config Mode=Active \
    --profile aws-staging --region ap-south-1
done
```

(Already enabled if you used the deploy scripts — this is just verification)

### Enable on API Gateway

```bash
API_ID=$(aws ssm get-parameter --name /nse/staging/api-gateway-id \
  --query Parameter.Value --output text --profile aws-staging)
aws apigatewayv2 update-stage \
  --api-id $API_ID \
  --stage-name '$default' \
  --default-route-settings "DetailedMetricsEnabled=true" \
  --profile aws-staging --region ap-south-1
```

### View traces

```
Console → CloudWatch → X-Ray Traces → Service Map

Shows:
  Browser → API Gateway → Lambda(nse-api) → DynamoDB(users) → DynamoDB(stock_transactions)
                                           → Comprehend → SQS

Click any node → see latency breakdown
Click any trace → see exact timing for each operation
  API Gateway: 2ms overhead
  Lambda init: 800ms (cold start), 0ms (warm)
  DynamoDB GetItem: 4ms
  Comprehend: 230ms
  Total: 1.2s
```

### Console view

```
Console → CloudWatch → X-Ray Traces
→ Service map: visual graph of all services
→ Traces: list of individual requests with timing
→ Insights: automatically detects latency spikes and error clusters
```

---

## 27. CloudTrail — Audit Log

Records every AWS API call made in the account. Who did what, when.

```bash
bash infrastructure/cloudtrail/setup_cloudtrail.sh staging
```

### What it captures

```
Every call to:
  - Lambda CreateFunction, UpdateFunctionCode, InvokeFunction
  - DynamoDB CreateTable, PutItem, DeleteItem
  - S3 PutObject, DeleteObject
  - IAM CreateRole, AttachPolicy
  - Cognito AdminCreateUser, InitiateAuth
  - SSM PutParameter, GetParameter
  - etc.

Each event includes:
  - Who called it (IAM user/role ARN)
  - When (timestamp)
  - From where (IP address, AWS Console vs CLI vs SDK)
  - What parameters were used
  - Whether it succeeded or failed
```

### Useful CloudTrail queries

```
Console → CloudTrail → Event history → Filter by event name

"Who deleted a Lambda function?"
  Event name: DeleteFunction → shows who and when

"Who changed SSM parameters?"
  Event name: PutParameter → shows all secret changes

"When did the last prod deployment happen?"
  Event name: UpdateFunctionCode → filter by function name nse-api-prod
```

### CloudTrail Lake (advanced)

```
Console → CloudTrail → Lake → Create event data store
→ Enables SQL queries on audit logs
→ Query: SELECT * FROM <store> WHERE eventSource = 'lambda.amazonaws.com'
         AND eventName = 'UpdateFunctionCode'
         AND awsRegion = 'ap-south-1'
         ORDER BY eventTime DESC LIMIT 10
```

---

## 28. Resource Groups + Tags

Tag all resources and group them for easy viewing.

```bash
export AWS_PROFILE=aws-staging
bash infrastructure/scripts/setup_resource_groups.sh staging
```

### Tags applied to all Lambda functions

```
Project   = NSEDashboard
Stage     = staging
ManagedBy = Infrastructure
```

### Resource Group: NSEDashboard-staging

```
Console → Resource Groups → NSEDashboard-staging
→ Shows ALL tagged resources in one view:
  Lambda functions (5+)
  DynamoDB tables (13)
  S3 buckets (2)
  SQS queues (2)
  API Gateways (2)
  SNS topics (1)
  Step Functions (1)
  CloudWatch alarms (6)
```

Tag resources from CLI:

```bash
# Tag S3 buckets
for BUCKET in nse-frontend nse-assets; do
  aws s3api put-bucket-tagging \
    --bucket ${BUCKET}-<STAGING_ID> \
    --tagging "TagSet=[{Key=Project,Value=NSEDashboard},{Key=Stage,Value=staging}]" \
    --profile aws-staging
done

# Tag SQS queues
for QUEUE in nse-scraping-jobs-staging nse-scraping-jobs-staging-dlq; do
  QUEUE_URL=$(aws sqs get-queue-url --queue-name $QUEUE \
    --query QueueUrl --output text --profile aws-staging --region ap-south-1)
  aws sqs tag-queue --queue-url $QUEUE_URL \
    --tags Project=NSEDashboard,Stage=staging \
    --profile aws-staging --region ap-south-1
done
```

---

## 29. Budgets — Cost Alert

Get an email if spending exceeds $0.50/month (means something went wrong).

```bash
bash infrastructure/scripts/setup_budget.sh your@email.com
```

### Console setup (manual)

```
Console → Billing → Budgets → Create budget

Budget type: Cost budget
Budget name: NSE-MonthlySpend-Staging
Budgeted amount: $1.00
Time period: Monthly

Alert threshold: 50% of budgeted ($0.50)
Alert type: Actual cost
Notify: your@email.com

→ Create budget
```

### What triggers an alert

```
Scenario: you accidentally leave EC2 running
→ EC2 t2.micro costs $0.0116/hour = $8.35/month
→ Budget alert fires at day 1 (cost already $0.50)
→ You get email immediately and stop the EC2

Scenario: you enabled RDS by mistake
→ RDS db.t2.micro = $0.017/hour = $12.24/month
→ Budget alert fires within 2 days
```

---

## 30. CodeBuild — AWS-Native CI/CD

Alternative to GitHub Actions — build and deploy entirely within AWS.

```bash
export AWS_PROFILE=aws-staging
bash infrastructure/codebuild/setup_codebuild.sh staging
```

### Trigger a build

```bash
aws codebuild start-build --project-name nse-build-staging \
  --profile aws-staging --region ap-south-1

# Watch the logs
aws codebuild batch-get-builds \
  --ids $(aws codebuild list-builds-for-project --project-name nse-build-staging \
    --query "ids[0]" --output text --profile aws-staging) \
  --query "builds[0].{Status:buildStatus, Phase:currentPhase}" \
  --profile aws-staging
```

### Console view

```
Console → CodeBuild → Build projects → nse-build-staging
→ Start build → Build history shows progress
→ Phase details: INSTALL → PRE_BUILD → BUILD → POST_BUILD
→ Build logs: same output as GitHub Actions
```

---

## 31. GitHub Actions — CI/CD Pipeline

### Add GitHub Secrets

Go to: **GitHub → vinodsharma412/aws-services → Settings → Secrets → Actions**

Click "New repository secret" for each:

```
Name                      Value
──────────────────────── ──────────────────────────────────────────────────
STAGING_ROLE_ARN          arn:aws:iam::<STAGING_ID>:role/GitHubActionsRole-staging
STAGING_ACCOUNT_ID        <12-digit staging account ID>
STAGING_API_URL           https://<API_ID>.execute-api.ap-south-1.amazonaws.com/api/v1
S3_FRONTEND_BUCKET_STAGING  nse-frontend-<STAGING_ID>

PROD_ROLE_ARN             arn:aws:iam::<PROD_ID>:role/GitHubActionsRole-prod
PROD_ACCOUNT_ID           <12-digit prod account ID>
PROD_API_URL              https://<API_ID>.execute-api.ap-south-1.amazonaws.com/api/v1
S3_FRONTEND_BUCKET_PROD   nse-frontend-<PROD_ID>
```

Find these values:
```bash
# Staging
aws ssm get-parameter --name /nse/staging/api-gateway-url \
  --query Parameter.Value --output text --profile aws-staging
aws s3 ls --profile aws-staging | grep nse-frontend

# Prod
aws ssm get-parameter --name /nse/prod/api-gateway-url \
  --query Parameter.Value --output text --profile aws-prod
aws s3 ls --profile aws-prod | grep nse-frontend
```

### Create GitHub Environments

```
GitHub → Settings → Environments → New environment

Environment 1:
  Name: staging
  No protection rules
  No wait timer
  → Save

Environment 2:
  Name: prod
  → Required reviewers → Add: vinodsharma412
  → Wait timer: 5 minutes (gives you time to cancel if something is wrong)
  → Save
```

### The pipeline flow

```
git push origin develop
        ↓
[Job 1] lint-build (ubuntu-latest)
  ├── ruff check backend/handlers/ backend/app/
  ├── npm run build (staging config → artifact: frontend-staging)
  ├── npm run build (prod config → artifact: frontend-prod)
  ├── pip install → zip → artifact: api-lambda.zip
  ├── pip install → zip → artifact: worker-lambda.zip
  ├── pip install → zip → artifact: ws-lambda.zip
  └── pip install → zip → artifact: lambda-layer.zip

        ↓ (only if lint-build succeeds)

[Job 2] deploy-staging (environment: staging — no approval)
  ├── GitHub OIDC → assume GitHubActionsRole-staging in STAGING account
  ├── Verify account ID matches STAGING_ACCOUNT_ID secret (safety check)
  ├── aws lambda publish-layer-version (uploads layer.zip)
  ├── aws lambda update-function-code (uploads api-lambda.zip)
  ├── aws lambda update-function-code (uploads worker-lambda.zip)
  ├── aws lambda update-function-code (uploads ws-lambda.zip)
  ├── curl STAGING_API_URL/health/ → must return 200
  └── aws s3 sync frontend-staging/ → S3 staging bucket

        ↓ (shows "Waiting for approval" in GitHub)

[Job 3] deploy-prod (environment: prod — reviewer must approve)
  ├── GitHub OIDC → assume GitHubActionsRole-prod in PROD account
  ├── Verify account ID matches PROD_ACCOUNT_ID secret (safety check)
  ├── aws lambda update-function-code (ALL functions in PROD account)
  ├── curl PROD_API_URL/health/ → must return 200
  ├── aws s3 sync frontend-prod/ → S3 prod bucket
  ├── aws cloudfront create-invalidation /* (clear CDN cache)
  └── git tag prod-YYYYMMDD-HHMMSS (marks the deployed commit)
```

---

## 32. Frontend Deploy — S3 + CloudFront

### Build and upload

```bash
# Staging frontend
export AWS_PROFILE=aws-staging
STAGING_API=$(aws ssm get-parameter --name /nse/staging/api-gateway-url \
  --query Parameter.Value --output text)
S3_BUCKET=$(aws s3 ls | grep nse-frontend | awk '{print $3}')

cd frontend
REACT_APP_API_URL="${STAGING_API}/api/v1" \
REACT_APP_STAGE=staging \
npm run build

aws s3 sync build/static/ s3://${S3_BUCKET}/static/ \
  --cache-control "max-age=31536000,immutable" --delete
aws s3 sync build/ s3://${S3_BUCKET}/ \
  --cache-control "no-cache,no-store,must-revalidate" \
  --exclude "static/*" --delete

# Invalidate CloudFront cache
DIST_ID=$(aws ssm get-parameter --name /nse/staging/cloudfront-dist-id \
  --query Parameter.Value --output text)
aws cloudfront create-invalidation --distribution-id $DIST_ID --paths "/*"
```

### Access your application

```bash
# CloudFront URL (HTTPS)
aws ssm get-parameter --name /nse/staging/cloudfront-url \
  --query Parameter.Value --output text --profile aws-staging
# → https://d1234xyz.cloudfront.net

# API URL
aws ssm get-parameter --name /nse/staging/api-gateway-url \
  --query Parameter.Value --output text --profile aws-staging
# → https://abc.execute-api.ap-south-1.amazonaws.com
```

---

## 33. Verify Everything Works

### Health check script

```bash
#!/bin/bash
# Run this to verify all services are working

echo "═══════════════════════════════════════════"
echo "  NSE Dashboard — Full Verification"
echo "═══════════════════════════════════════════"

for STAGE in staging prod; do
  echo ""
  echo "── ${STAGE^^} account ──────────────────────"
  export AWS_PROFILE=aws-${STAGE}

  # Get API URL
  API_URL=$(aws ssm get-parameter --name /nse/${STAGE}/api-gateway-url \
    --query Parameter.Value --output text 2>/dev/null)

  if [ -z "$API_URL" ]; then
    echo "  ✗ API Gateway URL not found in SSM"
    continue
  fi

  # Health check
  HEALTH=$(curl -s "${API_URL}/api/v1/health/" 2>/dev/null)
  if echo "$HEALTH" | grep -q '"status"'; then
    echo "  ✓ API Gateway → Lambda health check"
  else
    echo "  ✗ Health check failed: $HEALTH"
  fi

  # DynamoDB
  TABLE_COUNT=$(aws dynamodb list-tables --region ap-south-1 \
    --query "length(TableNames)" --output text 2>/dev/null)
  echo "  ✓ DynamoDB: ${TABLE_COUNT} tables"

  # Lambda count
  FUNC_COUNT=$(aws lambda list-functions --region ap-south-1 \
    --query "length(Functions[?contains(FunctionName,'nse')])" --output text 2>/dev/null)
  echo "  ✓ Lambda: ${FUNC_COUNT} NSE functions"

  # Cognito
  POOL_COUNT=$(aws cognito-idp list-user-pools --max-results 10 \
    --region ap-south-1 --query "length(UserPools)" --output text 2>/dev/null)
  echo "  ✓ Cognito: ${POOL_COUNT} user pool(s)"

  # SQS
  QUEUE_COUNT=$(aws sqs list-queues --region ap-south-1 \
    --query "length(QueueUrls[?contains(@,'nse')])" --output text 2>/dev/null)
  echo "  ✓ SQS: ${QUEUE_COUNT} NSE queues"

  # CloudFront
  CF_URL=$(aws ssm get-parameter --name /nse/${STAGE}/cloudfront-url \
    --query Parameter.Value --output text 2>/dev/null || echo "not-set")
  echo "  ✓ CloudFront: ${CF_URL}"
done

echo ""
echo "═══════════════════════════════════════════"
```

### Expected outputs

```
── STAGING account ──────────────────────
  ✓ API Gateway → Lambda health check
  ✓ DynamoDB: 13 tables
  ✓ Lambda: 5 NSE functions
  ✓ Cognito: 1 user pool(s)
  ✓ SQS: 2 NSE queues
  ✓ CloudFront: https://d1234xyz.cloudfront.net

── PROD account ──────────────────────
  ✓ API Gateway → Lambda health check
  ✓ DynamoDB: 13 tables
  ✓ Lambda: 5 NSE functions
  ✓ Cognito: 1 user pool(s)
  ✓ SQS: 2 NSE queues
  ✓ CloudFront: https://d5678abc.cloudfront.net
```

### Test login via API

```bash
API_URL=$(aws ssm get-parameter --name /nse/staging/api-gateway-url \
  --query Parameter.Value --output text --profile aws-staging)

# Login with Cognito
TOKEN=$(curl -s -X POST "${API_URL}/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"Nse@2025!"}' | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['id_token'])" 2>/dev/null)

if [ -n "$TOKEN" ]; then
  echo "✓ Login successful — token received"

  # Test authenticated endpoint
  curl -s -H "Authorization: Bearer $TOKEN" \
    "${API_URL}/api/v1/users/me" | python3 -m json.tool
else
  echo "✗ Login failed — check Cognito setup"
fi
```

### Check billing is $0

```bash
# Check staging account cost this month
aws ce get-cost-and-usage \
  --time-period Start=$(date -d "1 month ago" +%Y-%m-01),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --query "ResultsByTime[0].Total.BlendedCost.Amount" \
  --region us-east-1 --profile aws-staging
# → "0.0000000000"  ← should be zero or near-zero
```

---

## Summary — All 41 Services

| # | Service | Setup step | Free tier |
|---|---|---|---|
| 1 | API Gateway HTTP API | Step 17 | 1M req/month |
| 2 | API Gateway WebSocket | Step 18 | 1M conn-min/month |
| 3 | Lambda (12 functions) | Step 16 | 1M req + 400K GB-s |
| 4 | Lambda Layers | Step 15 | Same as Lambda |
| 5 | DynamoDB (13 tables) | Step 9 | 25 GB + 25 RCU/WCU |
| 6 | DynamoDB Streams | Step 19 | Included |
| 7 | DynamoDB TTL | Step 9 | Included |
| 8 | S3 (2 buckets) | Step 8 | 5 GB, 20K GET |
| 9 | S3 Lifecycle | Step 8 | Included |
| 10 | S3 Events | Step 8 | Included |
| 11 | CloudFront | Step 22 | 1 TB, 10M req |
| 12 | CloudFront Functions | Step 22 | 2M invocations |
| 13 | ACM (SSL certs) | Step 22 | Free |
| 14 | Cognito User Pool | Step 11 | 50K MAU forever |
| 15 | Cognito Identity Pool | Step 11 | Included |
| 16 | SQS Standard | Step 12 | 1M req forever |
| 17 | SQS DLQ | Step 12 | Same |
| 18 | SNS | Step 13 | 1M publishes |
| 19 | SES | Step 14 | 62K emails/month |
| 20 | EventBridge Events | Step 21 | 1M events |
| 21 | EventBridge Scheduler | Step 21 | 14M/month |
| 22 | EventBridge Pipes | Step 21 | 5M events |
| 23 | Step Functions | Step 20 | 4K transitions |
| 24 | SSM Parameter Store | Step 10 | 10K calls/month |
| 25 | AppConfig | Step 23 | Free (uses SSM) |
| 26 | X-Ray | Step 26 | 100K traces |
| 27 | CloudWatch Logs | Step 25 | 5 GB |
| 28 | CloudWatch Alarms | Step 25 | 10 alarms |
| 29 | CloudWatch Dashboard | Step 25 | 3 dashboards |
| 30 | CloudWatch Insights | Step 25 | 5 GB queries |
| 31 | CloudTrail | Step 27 | 1 trail forever |
| 32 | IAM (roles, policies) | Steps 3,6,7 | Free |
| 33 | AWS Organizations | Step 2 | Free |
| 34 | Switch Role | Step 4 | Free |
| 35 | OIDC (GitHub Actions) | Step 7 | Free |
| 36 | KMS (AWS-managed keys) | Step 24 | Free |
| 37 | Shield Standard | CloudFront | Free |
| 38 | Comprehend | Lambda env | 50K units |
| 39 | Translate | Lambda env | 2M chars |
| 40 | Rekognition | Lambda env | 5K images |
| 41 | Resource Groups | Step 28 | Free |
| 42 | Budgets | Step 29 | 2 budgets free |
| 43 | CodeBuild | Step 30 | 100 min/month |

**Total monthly cost: $0**

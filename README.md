# NSE Stock Dashboard — Multi-Account AWS (Switch Role)

**One AWS access key. Three accounts. Switch roles automatically.**

```
YOUR LAPTOP                    AWS Cloud
~/.aws/credentials             ┌─────────────────────────────────────────┐
  [default]          ──────►   │  master account  (your IAM user lives here)
  key_id = AKIA...             └──────────┬──────────────────────────────┘
  secret  = ...                           │  STS AssumeRole (switch role)
                                ┌─────────▼─────────┐  ┌─────────────────────┐
~/.aws/config                   │  aws-staging        │  │  aws-prod account   │
  [profile aws-staging]  ──►   │  CrossAccountRole   │  │  CrossAccountRole   │
  role_arn = arn:...:staging    │  Lambda / DynamoDB  │  │  Lambda / DynamoDB  │
                                │  Cognito / S3 ...   │  │  Cognito / S3 ...   │
  [profile aws-prod]    ──►    └─────────────────────┘  └─────────────────────┘
  role_arn = arn:...:prod               ↑                          ↑
                               git push develop             GitHub approval
                               (auto-deploy)                (manual gate)
```

## Quick start

```bash
# 1. Clone
git clone https://github.com/vinodsharma412/aws-services.git
cd aws-services && git checkout develop

# 2. Local dev
pip install -r backend/requirements.txt
export AWS_PROFILE=aws-staging
cd backend && STAGE=staging uvicorn app.main:app --reload --port 9000

# 3. Frontend
cd frontend && npm install && npm start
```

## First-time setup (do once)

```bash
# Step 1: Create cross-account roles (in each child account)
bash infrastructure/iam/setup_switch_role.sh staging <MASTER_ACCOUNT_ID>
bash infrastructure/iam/setup_switch_role.sh prod    <MASTER_ACCOUNT_ID>

# Step 2: Configure switch role profiles on your laptop
bash infrastructure/iam/configure_aws_profiles.sh \
  <MASTER_KEY_ID> <MASTER_SECRET> <STAGING_ACCOUNT_ID> <PROD_ACCOUNT_ID>

# Step 3: Set up all infrastructure (41 AWS services each account)
export AWS_PROFILE=aws-staging
bash infrastructure/scripts/setup_staging_account.sh vinodsharma412/aws-services your@email.com

export AWS_PROFILE=aws-prod
bash infrastructure/scripts/setup_prod_account.sh vinodsharma412/aws-services your@email.com

# Step 4: Add GitHub Secrets → push code → done
git push origin develop
```

See [docs/02_STEP_BY_STEP_SETUP.md](docs/02_STEP_BY_STEP_SETUP.md) for full instructions.

## Using AWS CLI with switch role

```bash
# Staging commands
export AWS_PROFILE=aws-staging
aws sts get-caller-identity          # verify staging account
make logs STAGE=staging              # view staging Lambda logs
make setup-infra STAGE=staging       # run any infra setup

# Prod commands (use carefully)
export AWS_PROFILE=aws-prod
aws sts get-caller-identity          # verify prod account
make health                          # health check
make logs STAGE=prod                 # prod logs (read-only)

# Console Switch Role
# → AWS Console → click username → Switch Role
# → Account: <STAGING_ACCOUNT_ID>  Role: CrossAccountAccessRole
```

## AWS services (41 total, all free tier)

| Category | Services |
|---|---|
| Compute | Lambda (12 functions), Lambda Layers |
| API | API Gateway HTTP API, API Gateway WebSocket API |
| Auth | Cognito User Pool, Cognito Identity Pool |
| Database | DynamoDB (13 tables), DynamoDB Streams, DynamoDB TTL |
| Storage | S3 (frontend + avatars), S3 Lifecycle, S3 Event Notifications |
| CDN | CloudFront, CloudFront Functions, ACM (SSL) |
| Messaging | SQS + DLQ, SNS, SES, EventBridge, EventBridge Pipes |
| Orchestration | Step Functions (parallel scraping with Map state) |
| AI/ML | Comprehend (sentiment), Translate, Rekognition (avatar moderation) |
| Secrets | SSM Parameter Store, AppConfig (feature flags) |
| Monitoring | CloudWatch Logs + Alarms + Dashboard, X-Ray, CloudTrail |
| Security | IAM, KMS, Shield Standard, Switch Role, OIDC |
| Governance | AWS Organizations, Resource Groups, Budgets |
| CI/CD | GitHub Actions OIDC, CodeBuild |

**Monthly cost: $0**

## Documentation

| Doc | Read when |
|---|---|
| [docs/02_STEP_BY_STEP_SETUP.md](docs/02_STEP_BY_STEP_SETUP.md) | **First time setup — start here** |
| [docs/01_ARCHITECTURE.md](docs/01_ARCHITECTURE.md) | Understanding all services |
| [docs/03_VS_CODE_SETUP.md](docs/03_VS_CODE_SETUP.md) | Setting up local dev |
| [docs/05_DEVELOPER_GUIDE.md](docs/05_DEVELOPER_GUIDE.md) | Daily workflow |
| [docs/06_CLOUDWATCH_MONITORING.md](docs/06_CLOUDWATCH_MONITORING.md) | Monitoring logs/alarms |
| [docs/07_STAGING_PROD_WORKFLOW.md](docs/07_STAGING_PROD_WORKFLOW.md) | How staging→prod works |
| [docs/04_INTERVIEW_PREP.md](docs/04_INTERVIEW_PREP.md) | AWS interview prep |

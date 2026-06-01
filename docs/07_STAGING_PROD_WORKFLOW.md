# Staging → Prod Promotion Workflow

## The two-account model

```
Developer laptop
      │  git push develop
      ▼
GitHub Actions
      │
      ├──── Lint + Build (Lambda zips + frontend)
      │
      ├──── Deploy STAGING (aws-staging account) ─── AUTOMATIC
      │     Assume GitHubActionsRole-staging via OIDC
      │     Lambda update in aws-staging account
      │     S3 sync in aws-staging account
      │
      └──── WAIT FOR APPROVAL ──────────────────────── MANUAL
            ↓ (reviewer clicks Approve in GitHub)
            Deploy PROD (aws-prod account)
            Assume GitHubActionsRole-prod via OIDC
            Lambda update in aws-prod account
            S3 sync in aws-prod account
            CloudFront invalidation in aws-prod account
            Tag commit as prod-YYYYMMDD-HHMMSS
```

## Isolation between accounts

| Resource | aws-staging account | aws-prod account |
|---|---|---|
| DynamoDB table "users" | staging users only | prod users only |
| Lambda "nse-api-staging" | staging code | — |
| Lambda "nse-api-prod" | — | prod code |
| Cognito User Pool | staging logins | prod logins |
| S3 frontend bucket | staging S3 bucket | prod S3 bucket |
| SSM secrets | `/nse/staging/*` | `/nse/prod/*` |
| CloudWatch logs | staging account logs | prod account logs |
| AWS bill | staging costs | prod costs |

**It is impossible** for staging code to accidentally write to prod DynamoDB —
they are in completely separate AWS accounts.

## How to deploy a change

```bash
# 1. Make change locally, test on localhost:9000
vim backend/handlers/stocks.py

# 2. Commit and push
git add backend/handlers/stocks.py
git commit -m "feat: add volume-weighted average price to stock analysis"
git push origin develop

# 3. GitHub Actions starts automatically:
#    Lint → Build Lambda zips → Deploy STAGING (2 min)

# 4. Test on staging
curl -H "Authorization: Bearer <token>" \
  https://<STAGING_API_URL>/api/v1/stocks/basic/RELIANCE.NS

# 5. Approve prod in GitHub UI:
#    Actions → your run → "Deploy → aws-prod" → Review deployments → Approve

# 6. Prod deploys in ~2 min
# 7. Commit is tagged: prod-20260601-143022
```

## What GitHub Environments enforce

**staging** environment: no rules → deploys immediately after build

**prod** environment:
- Required reviewer must click Approve
- The reviewer sees exactly which commit is being deployed
- If they click Reject, the prod job is cancelled
- The code already on prod remains unchanged

## How to rollback prod

```bash
# Option 1: Re-run a previous GitHub Actions workflow
# GitHub → Actions → find the last good run → Re-run jobs → "Deploy → aws-prod"

# Option 2: Deploy a previous commit directly
git checkout <previous-commit-hash>
git push origin develop --force  # triggers new pipeline

# Option 3: Update Lambda directly (fastest, no CI)
AWS_PROFILE=aws-prod aws lambda update-function-code \
  --function-name nse-api-prod \
  --zip-file fileb://api-lambda-backup.zip \
  --region ap-south-1
```

## How to watch what's deployed

```bash
# Which version is in prod right now?
AWS_PROFILE=aws-prod aws lambda get-function-configuration \
  --function-name nse-api-prod \
  --query "[LastModified, CodeSize]" \
  --region ap-south-1

# All prod deployment tags
git tag | grep prod- | sort

# Live prod logs
make logs STAGE=prod

# Health check both
make health
```

## Multi-account billing

Each AWS account has its own bill:
- `aws-staging` free tier: resets on staging account creation date
- `aws-prod` free tier: resets on prod account creation date

They don't share free tier limits — you effectively get **double the free tier**.

## Branch strategy

```
develop  ─────────────────────────────────────► (deployed to staging)
              │
              └── approved ──────────────────► (deployed to prod + tagged)
```

No separate `main` branch needed. The GitHub Environment approval is the gate.

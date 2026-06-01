# Staging → Prod Promotion Workflow

---

## The two-stage model

```
develop branch  →  staging  →  (manual approval)  →  prod
```

Both stages are completely independent Lambda functions with separate:
- DynamoDB tables (`stg_` prefix for staging, no prefix for prod)
- SQS queues (`nse-scraping-jobs-staging` vs `nse-scraping-jobs`)
- SNS topics (`nse-alerts-staging` vs `nse-alerts`)
- SSM parameter paths (`/nse/staging/` vs `/nse/prod/`)
- API Gateway endpoints (different URLs)
- CloudFront distributions (separate)

**Staging is always one commit ahead of prod.** You test on staging before approving prod.

---

## What triggers a deploy

| Event | Staging | Prod |
|---|---|---|
| Push to `develop` | Auto-deploys | No |
| Push to `main` | No | No (use manual approve) |
| Manual `workflow_dispatch` | Optional | Optional |
| Reviewer approves in GitHub | No | Yes |

---

## The deploy pipeline (GitHub Actions)

### Job 1: Lint & Test (runs first, blocks both deploys)

```
ruff check backend/app/ backend/lambda_handler.py
npm ci && npm run build (STAGING config)
npm run build (PROD config)
pip install → zip → upload artifacts (api-lambda.zip, worker-lambda.zip)
```

Both Lambda packages are built once, reused for staging and prod.

### Job 2: Deploy STAGING (auto, no approval)

```
aws lambda update-function-code --zip-file api-lambda.zip (nse-api-staging)
aws lambda update-function-code --zip-file worker-lambda.zip (nse-scraping-worker-staging)
Health check: curl https://<staging-url>/api/v1/health/
aws s3 sync build/ s3://<bucket>/staging/
aws cloudfront create-invalidation (staging dist)
```

### Job 3: Deploy PROD (waits for approval)

GitHub shows a banner: **"Waiting for approval to deploy to prod"**

To approve: GitHub → Actions → your workflow run → click **Review deployments** → **Approve and deploy**

```
aws lambda update-function-code --zip-file api-lambda.zip (nse-api-prod)
aws lambda update-function-code --zip-file worker-lambda.zip (nse-scraping-worker-prod)
Health check: curl https://<prod-url>/api/v1/health/
aws s3 sync build/ s3://<bucket>/   (root, no prefix)
aws cloudfront create-invalidation /* (prod dist)
```

---

## How to make a change and deploy

### Normal feature development

```bash
# 1. Make code changes locally
# 2. Test on localhost:9000

# 3. Commit and push
git add backend/app/api/v1/endpoints/stocks.py
git commit -m "feat: add P/E ratio filter to screener"
git push origin develop

# 4. Wait ~2 minutes → staging deployed automatically
# 5. Test on staging API URL
#    curl https://<staging-url>/api/v1/stocks/screener?min_yield=0.03

# 6. Open GitHub → Actions → approve prod deployment
# 7. Wait ~1 minute → prod deployed
```

### Hotfix to prod

If you find an urgent bug in prod:
```bash
git checkout develop
# fix the bug
git commit -m "fix: correct portfolio P&L calculation"
git push origin develop
# → staging auto-deploys, test quickly
# → approve prod immediately
```

There is no separate prod branch — all deploys go through develop → staging → prod.

---

## Checking what's deployed

```bash
# Which zip is currently running in staging?
aws lambda get-function-configuration \
  --function-name nse-api-staging \
  --query "[CodeSize,LastModified,Environment.Variables.STAGE]" \
  --region ap-south-1

# Check the Lambda code hash (matches the artifact hash from GitHub Actions)
aws lambda get-function \
  --function-name nse-api-prod \
  --query "Configuration.CodeSha256" \
  --region ap-south-1
```

---

## Rolling back prod

Lambda keeps the last deployed code. To rollback:

```bash
# Option 1: Redeploy the previous artifact
# In GitHub Actions → find the last working run → re-run that deploy-prod job

# Option 2: Use Lambda aliases + versions (advanced)
# Publish a version:
aws lambda publish-version --function-name nse-api-prod --region ap-south-1

# Point the alias to the previous version:
aws lambda update-alias \
  --function-name nse-api-prod \
  --name live \
  --function-version <previous-version-number> \
  --region ap-south-1
```

For simplicity, re-running the last good GitHub Actions job is the fastest rollback.

---

## Environment isolation checklist

Before deploying to prod, verify on staging:

- [ ] Login works (JWT token issued)
- [ ] Stock analysis returns data (`/api/v1/stocks/basic/RELIANCE.NS`)
- [ ] Scraping job creates and workers pick up tasks
- [ ] Portfolio operations work (add/view/delete transaction)
- [ ] CloudWatch logs show no errors

```bash
# Quick smoke test on staging
STAGING_URL="https://<staging-url>/api/v1"
TOKEN=$(curl -s -X POST "$STAGING_URL/auth/token" \
  -d "username=admin&password=<password>" | jq -r .access_token)

curl -s -H "Authorization: Bearer $TOKEN" "$STAGING_URL/health/"
curl -s -H "Authorization: Bearer $TOKEN" "$STAGING_URL/stocks/basic/RELIANCE.NS" | jq .current_price
```

---

## Cost isolation

Staging and prod share the same AWS account but are completely data-isolated.
Neither stage can accidentally write to the other's DynamoDB tables (different names).

Both stages are within the AWS free tier individually:
- Lambda: each stage uses a fraction of 1M free requests/month
- DynamoDB: both stages together use << 25 GB storage
- API Gateway: both stages together use << 1M requests/month

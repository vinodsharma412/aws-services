# Step-by-Step AWS Setup — Switch Role (Staging + Prod)

## Concept: Switch Role vs separate access keys

```
WITHOUT switch role (bad):           WITH switch role (correct):
┌──────────────────────────┐         ┌──────────────────────────┐
│ aws-staging account      │         │ master account (yours)    │
│   IAM user: vinod        │         │   IAM user: vinod        │
│   Access key #1          │         │   ONE access key          │
└──────────────────────────┘         └────────────┬─────────────┘
┌──────────────────────────┐                      │ STS AssumeRole
│ aws-prod account         │         ┌────────────▼─────────────┐
│   IAM user: vinod        │         │ aws-staging account       │
│   Access key #2          │         │   Role: CrossAccountRole  │
└──────────────────────────┘         └──────────────────────────┘
                                     ┌──────────────────────────┐
2 IAM users, 2 access keys,          │ aws-prod account          │
2 passwords to manage               │   Role: CrossAccountRole  │
                                     └──────────────────────────┘

                                     1 IAM user, 1 access key,
                                     1 password — switch roles freely
```

---

## Before you start

- [ ] **Three AWS accounts** (or AWS Organizations)
  - Master account (your personal/main account — has IAM user)
  - aws-staging account (separate account, only has IAM roles — no users)
  - aws-prod account (separate account, only has IAM roles — no users)
- [ ] AWS CLI installed: `pip install awscli`
- [ ] GitHub repo: `vinodsharma412/aws-services`
- [ ] Your email address

---

## Step 1 — Create three AWS accounts

### Option A: AWS Organizations (recommended for learning)

This is the enterprise pattern. One master account bills everything.

1. Create a **master account** at [aws.amazon.com](https://aws.amazon.com)
2. In master console → **AWS Organizations** → **Create organization**
3. **Add an AWS account**:
   - Name: `aws-staging`
   - Email: `yourname+staging@gmail.com`
4. **Add an AWS account**:
   - Name: `aws-prod`
   - Email: `yourname+prod@gmail.com`

AWS creates sub-accounts automatically. No separate sign-up needed.

### Option B: Three independent accounts (simpler)

Just create three accounts at [aws.amazon.com](https://aws.amazon.com) with different emails.
Choose this if you don't want Organizations complexity.

---

## Step 2 — Create ONE IAM user in master account only

All your credentials live here. Staging/prod have no IAM users.

1. Log into **master account** console
2. Go to **IAM → Users → Create user**
3. Username: `vinod` (or your name)
4. Attach policy: `AdministratorAccess`
5. **Security credentials → Create access key**
6. Download the CSV — you'll need these in Step 5

---

## Step 3 — Create Cross-Account Role in STAGING account

You need to temporarily log into the staging account once to create this role.

### How to log into staging account console

**If using AWS Organizations:**
- Master console → **AWS Organizations** → **Accounts** → `aws-staging`
- Click **Access account** → opens staging console as `OrganizationAccountAccessRole`

**If using independent accounts:**
- Log in at console.aws.amazon.com with the `aws-staging` email

### Run the script

```bash
# You need temporary staging account credentials (root or OrganizationAccountAccessRole)
# Set them as environment variables temporarily:

AWS_ACCESS_KEY_ID=<staging-temp-key> \
AWS_SECRET_ACCESS_KEY=<staging-temp-secret> \
AWS_DEFAULT_REGION=ap-south-1 \
bash infrastructure/iam/setup_switch_role.sh staging <MASTER_ACCOUNT_ID>
```

Copy the output. You'll see:
```
Role ARN: arn:aws:iam::111111111111:role/CrossAccountAccessRole
External ID: nse-staging-access
```

---

## Step 4 — Create Cross-Account Role in PROD account

Same process, but in the prod account:

```bash
AWS_ACCESS_KEY_ID=<prod-temp-key> \
AWS_SECRET_ACCESS_KEY=<prod-temp-secret> \
AWS_DEFAULT_REGION=ap-south-1 \
bash infrastructure/iam/setup_switch_role.sh prod <MASTER_ACCOUNT_ID>
```

Copy the output:
```
Role ARN: arn:aws:iam::222222222222:role/CrossAccountAccessRole
External ID: nse-prod-access
```

---

## Step 5 — Configure AWS CLI on your laptop (Switch Role profiles)

This is the key step. You only configure the master account credentials once,
then profiles switch roles automatically.

### Option A: Run the config script (recommended)

```bash
bash infrastructure/iam/configure_aws_profiles.sh \
  <MASTER_ACCESS_KEY_ID> \
  <MASTER_SECRET_ACCESS_KEY> \
  <STAGING_ACCOUNT_ID> \
  <PROD_ACCOUNT_ID>
```

This script:
- Writes master credentials to `~/.aws/credentials`
- Writes switch role profiles to `~/.aws/config`
- Tests both profiles

### Option B: Edit files manually

**`~/.aws/credentials`** — only master account keys:
```ini
[default]
aws_access_key_id = AKIA...YOUR_MASTER_KEY...
aws_secret_access_key = ...YOUR_MASTER_SECRET...
```

**`~/.aws/config`** — switch role profiles:
```ini
[default]
region = ap-south-1
output = json

[profile aws-staging]
role_arn = arn:aws:iam::<STAGING_ACCOUNT_ID>:role/CrossAccountAccessRole
source_profile = default
external_id = nse-staging-access
region = ap-south-1
role_session_name = aws-staging-session

[profile aws-prod]
role_arn = arn:aws:iam::<PROD_ACCOUNT_ID>:role/CrossAccountAccessRole
source_profile = default
external_id = nse-prod-access
region = ap-south-1
role_session_name = aws-prod-session
```

### Test it

```bash
# Should show STAGING account ID
aws sts get-caller-identity --profile aws-staging

# Should show PROD account ID
aws sts get-caller-identity --profile aws-prod

# Should show MASTER account ID
aws sts get-caller-identity
```

---

## Step 6 — Console Switch Role (browser)

For the AWS Console (browser), you switch roles manually:

1. Log into **master account** console
2. Click your **username** (top right) → **Switch Role**
3. Fill in:
   - Account: `<STAGING_ACCOUNT_ID>` (e.g. `111111111111`)
   - Role: `CrossAccountAccessRole`
   - Display name: `aws-staging` (for easy identification)
   - Color: Orange (staging)
4. Click **Switch Role**
5. You're now in the staging account — notice "CrossAccountAccessRole @ 111111111111" in the header
6. To go back: click the role name → **Switch Back**
7. Repeat for prod with a different color (e.g. red)

**Tip:** AWS saves your last 5 switched roles in a dropdown — you'll never type account IDs again after the first time.

---

## Step 7 — Set up staging infrastructure

Now use the switch role profile:

```bash
export AWS_PROFILE=aws-staging

# Verify you're in the right account
aws sts get-caller-identity --query Account --output text
# → should print STAGING_ACCOUNT_ID

# Run full setup (15 steps, ~30 min)
bash infrastructure/scripts/setup_staging_account.sh \
  vinodsharma412/aws-services \
  your@email.com
```

---

## Step 8 — Set up prod infrastructure

```bash
export AWS_PROFILE=aws-prod

# Verify account
aws sts get-caller-identity --query Account --output text
# → should print PROD_ACCOUNT_ID

# Run full setup
bash infrastructure/scripts/setup_prod_account.sh \
  vinodsharma412/aws-services \
  your@email.com
```

---

## Step 9 — GitHub Secrets (still needed for CI/CD)

Go to: **GitHub → repo → Settings → Secrets → Actions**

The setup scripts printed these at the end. Add them:

```
STAGING_ROLE_ARN           arn:aws:iam::<STAGING_ID>:role/GitHubActionsRole-staging
STAGING_ACCOUNT_ID         <STAGING_ACCOUNT_ID>
STAGING_API_URL            https://<id>.execute-api.ap-south-1.amazonaws.com/api/v1
S3_FRONTEND_BUCKET_STAGING nse-frontend-<STAGING_ACCOUNT_ID>

PROD_ROLE_ARN              arn:aws:iam::<PROD_ID>:role/GitHubActionsRole-prod
PROD_ACCOUNT_ID            <PROD_ACCOUNT_ID>
PROD_API_URL               https://<id>.execute-api.ap-south-1.amazonaws.com/api/v1
S3_FRONTEND_BUCKET_PROD    nse-frontend-<PROD_ACCOUNT_ID>
```

> GitHub Actions uses OIDC (not switch role) — but the concept is the same:
> it assumes a specific IAM role in each account per job.

---

## Step 10 — GitHub Environments

Go to: **GitHub → Settings → Environments**

| Environment | Protection |
|---|---|
| `staging` | None — auto-deploy on push |
| `prod` | Required reviewer: your GitHub username |

---

## Step 11 — First deploy

```bash
git push origin develop
```

GitHub Actions:
1. Assumes `GitHubActionsRole-staging` in aws-staging (OIDC, no keys)
2. Deploys Lambda + S3 to staging
3. Health check passes
4. Waits for your approval
5. You click **Approve** in GitHub
6. Assumes `GitHubActionsRole-prod` in aws-prod (OIDC, no keys)
7. Deploys Lambda + S3 to prod

---

## Daily workflow after setup

```bash
# Staging work
export AWS_PROFILE=aws-staging
make logs STAGE=staging          # view staging logs
make dynamo-tables               # create a new table in staging

# Prod work (read-only normally)
export AWS_PROFILE=aws-prod
make health                      # check prod health
aws logs tail /aws/lambda/nse-api-prod --follow  # prod logs

# Deploy (always go through git)
git push origin develop          # → auto staging → approve → prod
```

---

## Switch Role quick reference

| Action | Command |
|---|---|
| Use staging profile | `export AWS_PROFILE=aws-staging` |
| Use prod profile | `export AWS_PROFILE=aws-prod` |
| Use master account | `unset AWS_PROFILE` |
| Verify current account | `aws sts get-caller-identity` |
| Console switch role | Username → Switch Role → enter account ID |
| Console switch back | Role name (top right) → Switch Back |

---

## Security: why switch role is better than multiple keys

| Concern | Multiple keys | Switch Role |
|---|---|---|
| How many credentials? | 1 key per account | 1 key total |
| Key rotation | Rotate in every account | Rotate once (master) |
| Accidental prod access | Easy — two separate profiles | Hard — explicit assume required |
| MFA enforcement | Per-account (inconsistent) | Once on master account |
| If key leaked | Compromised account only | All accounts (but can block via MFA condition) |
| Audit trail | Per-account CloudTrail | Cross-account via Organizations |
| Best for | Simple/personal projects | Enterprise, teams, compliance |

**Recommendation:** Enable MFA on your master account. Then add `mfa_serial` to
`~/.aws/config` profiles. Every switch role will require your MFA code.
This means even if your access key is leaked, the attacker can't switch roles.

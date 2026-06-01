# VS Code Setup — Local Dev with Switch Role

## Extensions to install

| Extension | Purpose |
|---|---|
| Python (Microsoft) | Python language support |
| Pylance | Type checking |
| Ruff | Linting (replaces flake8/black) |
| AWS Toolkit | Browse DynamoDB, Lambda, CloudWatch in VS Code |
| ESLint + Prettier | Frontend linting |

## AWS CLI profiles (Switch Role)

After completing `docs/02_STEP_BY_STEP_SETUP.md`, your `~/.aws/config` has:

```ini
[default]
region = ap-south-1

[profile aws-staging]
role_arn = arn:aws:iam::<STAGING_ID>:role/CrossAccountAccessRole
source_profile = default
external_id = nse-staging-access
region = ap-south-1

[profile aws-prod]
role_arn = arn:aws:iam::<PROD_ID>:role/CrossAccountAccessRole
source_profile = default
external_id = nse-prod-access
region = ap-south-1
```

Test:
```bash
aws sts get-caller-identity --profile aws-staging   # shows staging account
aws sts get-caller-identity --profile aws-prod       # shows prod account
```

## Python interpreter

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r backend/requirements.txt
```

`Ctrl+Shift+P` → Python: Select Interpreter → `./venv/bin/python`

## VS Code launch config (`.vscode/launch.json`)

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Backend — aws-staging",
      "type": "python",
      "request": "launch",
      "module": "uvicorn",
      "args": ["app.main:app", "--reload", "--port", "9000"],
      "env": {
        "STAGE": "staging",
        "AWS_PROFILE": "aws-staging",
        "AWS_REGION": "ap-south-1"
      },
      "cwd": "${workspaceFolder}/backend",
      "console": "integratedTerminal"
    }
  ]
}
```

Press **F5** → FastAPI starts at `http://localhost:9000/docs`

FastAPI uses your `aws-staging` profile to access staging DynamoDB tables.
You never need a `.env` file with credentials — the profile handles it.

## AWS Toolkit — multi-account setup

1. Click AWS icon in VS Code sidebar
2. **Add a profile** → choose `aws-staging`
3. Browse DynamoDB → Tables → `users` (staging data)
4. Switch to `aws-prod` to browse prod tables (read-only recommended)

The AWS Toolkit respects your `~/.aws/config` profiles automatically.

## Environment file (`backend/.env`)

Only needed for local dev without AWS (completely offline):

```ini
STAGE=staging
AWS_REGION=ap-south-1
# Leave all secrets blank — they load from SSM via aws-staging profile
# SECRET_KEY=
# SQS_SCRAPING_JOBS_URL=
```

When `AWS_PROFILE=aws-staging` is set, all boto3 calls automatically use
your staging account credentials. No keys in `.env`.

## Verify you are NOT on prod

Add this safety check to `~/.bashrc` or `~/.zshrc`:

```bash
# Warn when using prod profile
aws() {
  if [ "${AWS_PROFILE}" = "aws-prod" ]; then
    echo "⚠  WARNING: Running against PRODUCTION account!"
    echo "   Command: aws $*"
    read -rp "   Continue? (yes/no): " ok
    [ "$ok" != "yes" ] && return 1
  fi
  command aws "$@"
}
```

## Quick commands

```bash
# Switch to staging (safe for development)
export AWS_PROFILE=aws-staging

# Tail staging Lambda logs
aws logs tail /aws/lambda/nse-api-staging --follow --region ap-south-1

# View staging DynamoDB tables
aws dynamodb list-tables --region ap-south-1

# Switch to prod (only for monitoring)
export AWS_PROFILE=aws-prod

# View prod health
curl $(aws ssm get-parameter --name /nse/prod/api-gateway-url \
  --query Parameter.Value --output text)/api/v1/health/

# Back to default (master account)
unset AWS_PROFILE
```

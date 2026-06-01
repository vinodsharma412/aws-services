# VS Code Setup — Local Development

## Extensions to install

- **Python** (Microsoft)
- **Pylance** (type hints)
- **Ruff** (linting — replaces flake8/black)
- **AWS Toolkit** (browse DynamoDB, Lambda, CloudWatch in VS Code)
- **ESLint + Prettier** (frontend)

## Python interpreter

```
Ctrl+Shift+P → Python: Select Interpreter → ./venv/bin/python
```

Or create a venv:
```bash
python3 -m venv venv
source venv/bin/activate
pip install -r backend/requirements.txt
```

## Launch configuration

Create `.vscode/launch.json`:
```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Backend (staging account)",
      "type": "python",
      "request": "launch",
      "module": "uvicorn",
      "args": ["app.main:app", "--reload", "--port", "9000"],
      "env": {
        "STAGE": "staging",
        "AWS_PROFILE": "aws-staging"
      },
      "cwd": "${workspaceFolder}/backend",
      "console": "integratedTerminal"
    }
  ]
}
```

Press **F5** → FastAPI starts at http://localhost:9000/docs

## AWS Toolkit — multi-account setup

1. Click AWS icon in left sidebar
2. Add Profile → select `aws-staging` from `~/.aws/credentials`
3. Switch profiles to see staging vs prod resources
4. Browse: DynamoDB → Tables → users → view items
5. Browse: Lambda → nse-api-staging → Invoke with test payload
6. Browse: CloudWatch → nse-api-staging → tail logs

## Environment file for local dev

```bash
cp backend/.env.example backend/.env
```

Edit `backend/.env`:
```
STAGE=staging
AWS_PROFILE=aws-staging
AWS_REGION=ap-south-1
```

Leave all secrets empty — they load from SSM automatically using your AWS profile.

## Important: never use aws-prod profile locally

Always develop against `aws-staging`. Use `aws-prod` profile ONLY for:
- Running `setup_prod_account.sh` once
- Emergency rollback via AWS CLI

Add this to `~/.bashrc` to prevent accidental prod access:
```bash
prod_check() {
  if [ "${AWS_PROFILE}" = "aws-prod" ]; then
    echo "WARNING: You are using the PROD AWS profile!"
    read -p "Are you sure? (yes/no): " ok
    [ "$ok" != "yes" ] && return 1
  fi
}
```

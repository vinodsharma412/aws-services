# VS Code Setup — Local Development

## Install extensions

- Python (Microsoft)
- Pylance
- Ruff (for linting)
- ESLint + Prettier (for React)
- AWS Toolkit (to browse DynamoDB, Lambda, CloudWatch directly in VS Code)

## Python interpreter

Select the project venv:
1. `Ctrl+Shift+P` → Python: Select Interpreter
2. Choose `./venv/bin/python` (or wherever you created the venv)

## Backend launch config

Create `.vscode/launch.json`:
```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "FastAPI (staging)",
      "type": "python",
      "request": "launch",
      "module": "uvicorn",
      "args": ["app.main:app", "--reload", "--port", "9000"],
      "env": {"STAGE": "staging"},
      "cwd": "${workspaceFolder}/backend",
      "console": "integratedTerminal"
    }
  ]
}
```

Press F5 → FastAPI starts at http://localhost:9000/docs

## Frontend launch

In a terminal:
```bash
cd frontend && npm start
```

## AWS Toolkit setup

1. Install AWS Toolkit extension
2. Click the AWS icon in the left sidebar
3. Add credentials profile or use IAM Identity Center
4. Browse: DynamoDB → Tables → stg_users → view items
5. Browse: Lambda → nse-api-staging → view recent logs
6. Browse: CloudWatch → Log groups → tail logs

## Environment file

Copy the example:
```bash
cp backend/.env.example backend/.env
```

Edit `backend/.env`:
```
STAGE=staging
AWS_REGION=ap-south-1
# Leave SECRET_KEY empty — loaded from SSM automatically
# Leave SQS_SCRAPING_JOBS_URL empty — loaded from SSM automatically
```

The app reads from SSM at startup using your `~/.aws` profile.
Local dev always points to staging DynamoDB tables (never prod).

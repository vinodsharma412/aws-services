"""AWS Lambda entry point — wraps FastAPI with Mangum.

Mangum translates the API Gateway HTTP API event format into a standard ASGI
request that FastAPI can process, then converts the ASGI response back into
the format API Gateway expects.

How it works:
    API Gateway HTTP API
        │  event: { routeKey, headers, body, ... }
        ▼
    Lambda: lambda_handler(event, context)
        │  Mangum translates event → ASGI scope
        ▼
    FastAPI (ASGI app)
        │  runs your existing endpoint code unchanged
        │  DynamoDB / S3 / SQS via boto3 (IAM role, no keys)
        ▼
    Mangum translates ASGI response → API Gateway response format
        │  { statusCode, headers, body }
        ▼
    API Gateway returns response to browser

Environment variables (set via Lambda console or SSM):
    STAGE                   staging | prod
    AWS_REGION              ap-south-1
    SECRET_KEY              JWT secret (loaded from SSM when empty)
    S3_ASSETS_BUCKET        nse-assets-<account-id>
    SQS_SCRAPING_JOBS_URL   SQS queue URL (loaded from SSM when empty)
    SNS_ALERTS_ARN          SNS topic ARN (loaded from SSM when empty)

Note on file uploads:
    Mangum handles multipart/form-data correctly when the API Gateway
    integration is configured with binaryMediaTypes=["multipart/form-data"].
    The lambda_handler is instantiated with api_gateway_base_path stripped
    so FastAPI's root_path matches the stage prefix automatically.
"""

from mangum import Mangum

from app.main import app

# lifespan="off" tells Mangum not to run the FastAPI startup/shutdown events
# (the worker subprocess is no longer started here; it runs as a separate
# SQS-triggered Lambda — see infrastructure/lambda/scraping_worker/).
handler = Mangum(app, lifespan="off")

"""FastAPI application factory — fully serverless AWS edition.

Deployment model:
    Local dev  → uvicorn  (hot-reload, no Lambda needed)
    AWS        → Lambda + Mangum  (see backend/lambda_handler.py)

What changed from the EC2 version:
    - No subprocess.Popen for the Playwright worker.
      The scraping worker now runs as a separate SQS-triggered Lambda
      (infrastructure/lambda/scraping_worker/handler.py).
    - No StaticFiles mount (avatars live in S3).
    - No EC2/Nginx references.
    - lifespan context manager kept for future hooks but is a no-op on Lambda
      (Mangum is called with lifespan='off').

CORS policy:
    allow_origins=["*"] is fine here — the S3/CloudFront URL is public.
    In production you can restrict to your CloudFront distribution domain.
"""

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.v1.router import api_router
from app.config import settings
from app.middleware.logging_middleware import LoggingMiddleware


@asynccontextmanager
async def lifespan(_app: FastAPI):
    """Application lifespan — no-op on Lambda, kept for local dev hooks."""
    yield


# On Lambda the stage prefix is handled by API Gateway; locally we keep it
# so the OpenAPI docs URL matches the real endpoint paths.
_root_path = "" if settings.STAGE == "prod" else f"/{settings.STAGE}"

app = FastAPI(
    title=settings.APP_NAME,
    debug=settings.DEBUG,
    lifespan=lifespan,
    root_path=_root_path,
)

app.add_middleware(LoggingMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(api_router, prefix="/api/v1")

"""Shared helpers for all pure-Lambda handlers.

No FastAPI. No Mangum. No uvicorn.
API Gateway HTTP API sends an event dict; each handler returns a response dict.
"""

import base64
import json
import logging
import os

logger = logging.getLogger()
logger.setLevel(logging.INFO)

CORS_HEADERS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Authorization,Content-Type,X-Api-Key",
    "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,PATCH,OPTIONS",
    "X-Content-Type-Options": "nosniff",
}


# ── Response helpers ───────────────────────────────────────────────────────────

def ok(body, status: int = 200) -> dict:
    return {
        "statusCode": status,
        "headers": CORS_HEADERS,
        "body": json.dumps(body, default=str),
    }


def created(body) -> dict:
    return ok(body, 201)


def no_content() -> dict:
    return {"statusCode": 204, "headers": CORS_HEADERS, "body": ""}


def err(status: int, detail: str) -> dict:
    return ok({"detail": detail}, status)


def bad_request(detail: str) -> dict:
    return err(400, detail)


def unauthorized(detail: str = "Not authenticated") -> dict:
    return err(401, detail)


def forbidden(detail: str = "Access denied") -> dict:
    return err(403, detail)


def not_found(detail: str = "Not found") -> dict:
    return err(404, detail)


def conflict(detail: str) -> dict:
    return err(409, detail)


def server_error(detail: str = "Internal server error") -> dict:
    return err(500, detail)


# ── API Gateway event helpers ──────────────────────────────────────────────────

def get_method(event: dict) -> str:
    return (
        event.get("requestContext", {})
        .get("http", {})
        .get("method", "GET")
        .upper()
    )


def get_path(event: dict) -> str:
    return event.get("rawPath", "")


def get_path_params(event: dict) -> dict:
    return event.get("pathParameters") or {}


def get_qs(event: dict) -> dict:
    return event.get("queryStringParameters") or {}


def get_body(event: dict) -> dict:
    raw = event.get("body") or ""
    if not raw:
        return {}
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return {}


def get_raw_body_bytes(event: dict) -> bytes:
    raw = event.get("body") or b""
    if event.get("isBase64Encoded") and isinstance(raw, str):
        return base64.b64decode(raw)
    if isinstance(raw, str):
        return raw.encode("utf-8")
    return raw


def get_header(event: dict, name: str) -> str:
    headers = event.get("headers") or {}
    return headers.get(name.lower(), headers.get(name, ""))


# ── Cognito JWT claims ─────────────────────────────────────────────────────────

def get_claims(event: dict) -> dict:
    """Extract Cognito JWT claims validated by API Gateway JWT Authorizer."""
    return (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("jwt", {})
        .get("claims", {})
    )


def get_current_username(event: dict) -> str:
    claims = get_claims(event)
    return claims.get("cognito:username") or claims.get("username", "")


def get_current_user_id(event: dict) -> str:
    """Cognito sub = stable unique user ID (UUID)."""
    return get_claims(event).get("sub", "")


def get_current_role(event: dict) -> str:
    claims = get_claims(event)
    return claims.get("custom:role", claims.get("role", "viewer"))


def require_role(event: dict, *allowed_roles: str):
    """Return forbidden response if user's role is not in allowed_roles."""
    role = get_current_role(event)
    if role not in allowed_roles:
        return forbidden(f"Role '{role}' cannot perform this action")
    return None


# ── Content-type helper ────────────────────────────────────────────────────────

def get_content_type(event: dict) -> str:
    return get_header(event, "content-type").split(";")[0].strip()


# ── Stage ─────────────────────────────────────────────────────────────────────

STAGE = os.environ.get("STAGE", "staging")
TABLE_PREFIX = "" if STAGE == "prod" else f"{STAGE}_"

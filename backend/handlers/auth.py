"""Authentication Lambda — replaces FastAPI auth endpoints.

Routes handled:
  POST /auth/login      Cognito InitiateAuth → returns tokens
  POST /auth/refresh    Cognito refresh token
  POST /auth/register   Cognito sign-up (admin creates user)
  POST /auth/logout     Revoke Cognito tokens

AWS services used:
  - Cognito User Pool  (auth, token issuance)
  - SSM Parameter Store  (Cognito client ID / pool ID)
  - X-Ray  (distributed tracing)
  - CloudWatch  (auto log all requests)

Replacing: FastAPI + python-jose JWT + bcrypt password hashing
"""

import json
import logging
import os

import boto3
from aws_xray_sdk.core import patch_all, xray_recorder
from botocore.exceptions import ClientError

patch_all()

from handlers._base import (
    STAGE,
    bad_request,
    get_body,
    get_method,
    get_path,
    ok,
    require_role,
    server_error,
    unauthorized,
)

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("AWS_REGION", "ap-south-1")

_cognito = boto3.client("cognito-idp", region_name=REGION)
_ssm = boto3.client("ssm", region_name=REGION)


def _get_pool_config() -> tuple[str, str]:
    """Read Cognito User Pool ID and App Client ID from SSM."""
    pool_id = os.environ.get("COGNITO_USER_POOL_ID") or _ssm.get_parameter(
        Name=f"/nse/{STAGE}/cognito-user-pool-id"
    )["Parameter"]["Value"]
    client_id = os.environ.get("COGNITO_CLIENT_ID") or _ssm.get_parameter(
        Name=f"/nse/{STAGE}/cognito-client-id"
    )["Parameter"]["Value"]
    return pool_id, client_id


@xray_recorder.capture("auth")
def handler(event, context):
    method = get_method(event)
    path = get_path(event)

    if method == "OPTIONS":
        return ok({})

    body = get_body(event)

    try:
        pool_id, client_id = _get_pool_config()

        # ── POST /auth/login ──────────────────────────────────────────────────
        if method == "POST" and path.endswith("/login"):
            username = body.get("username", "").strip()
            password = body.get("password", "").strip()
            if not username or not password:
                return bad_request("username and password are required")

            try:
                resp = _cognito.initiate_auth(
                    AuthFlow="USER_PASSWORD_AUTH",
                    AuthParameters={"USERNAME": username, "PASSWORD": password},
                    ClientId=client_id,
                )
                auth = resp.get("AuthenticationResult", {})
                logger.info("Login success: %s", username)
                return ok({
                    "access_token": auth.get("AccessToken"),
                    "id_token": auth.get("IdToken"),
                    "refresh_token": auth.get("RefreshToken"),
                    "expires_in": auth.get("ExpiresIn", 3600),
                    "token_type": "Bearer",
                })
            except ClientError as e:
                code = e.response["Error"]["Code"]
                if code in ("NotAuthorizedException", "UserNotFoundException"):
                    return unauthorized("Invalid username or password")
                if code == "UserNotConfirmedException":
                    return unauthorized("Account not confirmed")
                logger.error("Cognito login error: %s", e)
                return server_error("Authentication service error")

        # ── POST /auth/refresh ────────────────────────────────────────────────
        if method == "POST" and path.endswith("/refresh"):
            refresh_token = body.get("refresh_token", "")
            if not refresh_token:
                return bad_request("refresh_token is required")

            try:
                resp = _cognito.initiate_auth(
                    AuthFlow="REFRESH_TOKEN_AUTH",
                    AuthParameters={"REFRESH_TOKEN": refresh_token},
                    ClientId=client_id,
                )
                auth = resp["AuthenticationResult"]
                return ok({
                    "access_token": auth.get("AccessToken"),
                    "id_token": auth.get("IdToken"),
                    "expires_in": auth.get("ExpiresIn", 3600),
                    "token_type": "Bearer",
                })
            except ClientError as e:
                logger.error("Refresh error: %s", e)
                return unauthorized("Token refresh failed")

        # ── POST /auth/register (admin creates user) ──────────────────────────
        if method == "POST" and path.endswith("/register"):
            guard = require_role(event, "admin")
            if guard:
                return guard

            username = body.get("username", "").strip()
            email = body.get("email", "").strip()
            temp_password = body.get("temp_password", "").strip()
            role = body.get("role", "viewer")

            if not username or not email or not temp_password:
                return bad_request("username, email and temp_password are required")

            try:
                _cognito.admin_create_user(
                    UserPoolId=pool_id,
                    Username=username,
                    TemporaryPassword=temp_password,
                    UserAttributes=[
                        {"Name": "email", "Value": email},
                        {"Name": "email_verified", "Value": "true"},
                        {"Name": "custom:role", "Value": role},
                    ],
                    MessageAction="SUPPRESS",
                )
                logger.info("User created in Cognito: %s role=%s", username, role)
                return ok({"message": f"User {username} created", "role": role}, 201)
            except ClientError as e:
                code = e.response["Error"]["Code"]
                if code == "UsernameExistsException":
                    return ok({"detail": "Username already exists"}, 409)
                logger.error("Register error: %s", e)
                return server_error("Failed to create user")

        # ── POST /auth/logout ─────────────────────────────────────────────────
        if method == "POST" and path.endswith("/logout"):
            access_token = body.get("access_token", "")
            if access_token:
                try:
                    _cognito.global_sign_out(AccessToken=access_token)
                except ClientError:
                    pass  # already expired, that's fine
            return ok({"message": "Logged out"})

        return ok({"detail": "Route not found"}, 404)

    except Exception as e:
        logger.error("Auth handler error: %s", e)
        return server_error(str(e))

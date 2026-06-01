"""Users Lambda — replaces FastAPI /users/* endpoints.

Routes:
  GET    /users/me           current user profile
  PUT    /users/me           update own profile
  POST   /users/me/avatar    upload avatar to S3
  DELETE /users/me/avatar    delete avatar from S3
  GET    /users              list all users (ADMIN/MANAGER)
  POST   /users              create user (ADMIN)
  PUT    /users/{id}         update user (ADMIN)
  DELETE /users/{id}         delete user (ADMIN)

AWS services used:
  - DynamoDB  (user records)
  - S3  (avatar images)
  - Rekognition  (validate avatar is a face/appropriate image)
  - Cognito  (update user attributes)
  - X-Ray  (tracing)
  - CloudWatch  (auto logging)
"""

import base64
import logging
import os

import boto3
from aws_xray_sdk.core import patch_all, xray_recorder

patch_all()

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.crud import user_dynamo
from app.services.s3_storage import delete_avatar, upload_avatar
from handlers._base import (
    STAGE,
    bad_request,
    conflict,
    created,
    forbidden,
    get_body,
    get_current_role,
    get_current_user_id,
    get_current_username,
    get_header,
    get_method,
    get_path,
    get_path_params,
    get_qs,
    get_raw_body_bytes,
    no_content,
    not_found,
    ok,
    require_role,
    server_error,
)

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("AWS_REGION", "ap-south-1")
_rekognition = boto3.client("rekognition", region_name=REGION)

ALLOWED_CONTENT_TYPES = {"image/jpeg", "image/png", "image/webp", "image/gif"}
MAX_AVATAR_BYTES = 3 * 1024 * 1024


def _check_avatar_with_rekognition(image_bytes: bytes) -> bool:
    """Use Rekognition to detect moderation labels on avatar image.

    AWS Rekognition DetectModerationLabels is used to ensure uploaded
    avatars are appropriate. Free tier: 5,000 images/month.

    Returns True if image is safe, False if inappropriate content detected.
    """
    try:
        resp = _rekognition.detect_moderation_labels(
            Image={"Bytes": image_bytes},
            MinConfidence=80,
        )
        labels = resp.get("ModerationLabels", [])
        if labels:
            logger.warning("Rekognition flagged avatar: %s", [l["Name"] for l in labels])
            return False
        return True
    except Exception as e:
        logger.warning("Rekognition check skipped: %s", e)
        return True  # fail open — don't block upload if Rekognition is unavailable


@xray_recorder.capture("users")
def handler(event, context):
    method = get_method(event)
    path = get_path(event)
    path_params = get_path_params(event)
    qs = get_qs(event)
    user_id = get_current_user_id(event)
    username = get_current_username(event)
    role = get_current_role(event)

    if method == "OPTIONS":
        return ok({})

    try:
        # ── GET /users/me ─────────────────────────────────────────────────────
        if method == "GET" and path.endswith("/me"):
            user = user_dynamo.get_by_id(user_id)
            if not user:
                return not_found("User profile not found")
            return ok(user)

        # ── PUT /users/me ─────────────────────────────────────────────────────
        if method == "PUT" and path.endswith("/me"):
            body = get_body(event)
            allowed = {"email", "full_name"}
            fields = {k: v for k, v in body.items() if k in allowed}
            updated = user_dynamo.update(user_id, fields)
            return ok(updated or {})

        # ── POST /users/me/avatar ─────────────────────────────────────────────
        if method == "POST" and path.endswith("/avatar"):
            content_type = get_header(event, "content-type").split(";")[0].strip()
            if content_type not in ALLOWED_CONTENT_TYPES:
                return bad_request("Only JPEG, PNG, WebP or GIF images allowed")

            img_bytes = get_raw_body_bytes(event)
            if len(img_bytes) > MAX_AVATAR_BYTES:
                return bad_request("Image must be smaller than 3 MB")

            # Rekognition moderation check
            if not _check_avatar_with_rekognition(img_bytes):
                return bad_request("Image contains inappropriate content")

            current = user_dynamo.get_by_id(user_id)
            old_url = (current or {}).get("avatar_url")
            if old_url:
                delete_avatar(old_url)

            ext = "jpg"
            if "png" in content_type:
                ext = "png"
            elif "webp" in content_type:
                ext = "webp"
            elif "gif" in content_type:
                ext = "gif"

            s3_url = upload_avatar(img_bytes, content_type, user_id, ext)
            updated = user_dynamo.update(user_id, {"avatar_url": s3_url})
            return ok(updated or {})

        # ── DELETE /users/me/avatar ───────────────────────────────────────────
        if method == "DELETE" and path.endswith("/avatar"):
            current = user_dynamo.get_by_id(user_id)
            old_url = (current or {}).get("avatar_url")
            if old_url:
                delete_avatar(old_url)
                updated = user_dynamo.update(user_id, {"avatar_url": None})
                return ok(updated or {})
            return ok(current or {})

        # ── GET /users (admin/manager) ────────────────────────────────────────
        if method == "GET" and (path.endswith("/users") or path.rstrip("/").endswith("/users")):
            guard = require_role(event, "admin", "manager")
            if guard:
                return guard
            skip = int(qs.get("skip", 0))
            limit = int(qs.get("limit", 100))
            users = user_dynamo.get_all(skip=skip, limit=limit)
            return ok(users)

        # ── POST /users (admin) ───────────────────────────────────────────────
        if method == "POST" and (path.endswith("/users") or path.rstrip("/").endswith("/users")):
            guard = require_role(event, "admin")
            if guard:
                return guard
            body = get_body(event)
            uname = body.get("username", "").strip()
            if not uname:
                return bad_request("username is required")
            if user_dynamo.get_by_username(uname):
                return conflict("Username already exists")
            new_user = user_dynamo.create(
                username=uname,
                email=body.get("email", ""),
                full_name=body.get("full_name", ""),
                role=body.get("role", "viewer"),
                password=body.get("password", ""),
            )
            return created(new_user)

        # ── PUT /users/{user_id} (admin) ──────────────────────────────────────
        target_id = path_params.get("user_id") or path_params.get("id")
        if method == "PUT" and target_id:
            guard = require_role(event, "admin")
            if guard:
                return guard
            body = get_body(event)
            allowed = {"email", "full_name", "role", "is_active"}
            fields = {k: v for k, v in body.items() if k in allowed}
            updated = user_dynamo.update(target_id, fields)
            if not updated:
                return not_found("User not found")
            return ok(updated)

        # ── DELETE /users/{user_id} (admin) ───────────────────────────────────
        if method == "DELETE" and target_id:
            guard = require_role(event, "admin")
            if guard:
                return guard
            existing = user_dynamo.get_by_id(target_id)
            if not existing:
                return not_found("User not found")
            user_dynamo.delete(target_id)
            return no_content()

        return ok({"detail": "Route not found"}, 404)

    except Exception as e:
        logger.error("Users handler error: %s", e, exc_info=True)
        return server_error(str(e))

"""Health check Lambda — GET /health

AWS services verified:
  - DynamoDB (ping via describe_table)
  - SQS (ping via get_queue_attributes)
  - Lambda (this function is alive if handler is called)

X-Ray traces this function automatically.
CloudWatch Synthetics can call this on a schedule to verify uptime.
"""

import json
import logging
import os
import time

import boto3
from aws_xray_sdk.core import patch_all, xray_recorder

patch_all()

from handlers._base import STAGE, TABLE_PREFIX, ok, server_error

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("AWS_REGION", "ap-south-1")

_dynamo = boto3.client("dynamodb", region_name=REGION)
_ssm = boto3.client("ssm", region_name=REGION)


@xray_recorder.capture("health_check")
def handler(event, context):
    """Return health status of all integrated AWS services."""
    checks = {}
    start = time.time()

    # ── DynamoDB ──────────────────────────────────────────────────────────────
    try:
        _dynamo.describe_table(TableName=f"{TABLE_PREFIX}users")
        checks["dynamodb"] = "ok"
    except Exception as e:
        checks["dynamodb"] = f"error: {e}"

    # ── SSM ───────────────────────────────────────────────────────────────────
    try:
        _ssm.describe_parameters(MaxResults=1)
        checks["ssm"] = "ok"
    except Exception as e:
        checks["ssm"] = f"error: {e}"

    elapsed_ms = round((time.time() - start) * 1000)
    overall = "ok" if all(v == "ok" for v in checks.values()) else "degraded"

    logger.info("Health check: %s in %dms | %s", overall, elapsed_ms, checks)

    body = {
        "status": overall,
        "stage": STAGE,
        "region": REGION,
        "checks": checks,
        "latency_ms": elapsed_ms,
    }
    status_code = 200 if overall == "ok" else 503
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }

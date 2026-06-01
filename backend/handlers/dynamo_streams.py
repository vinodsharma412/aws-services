"""DynamoDB Streams Lambda — event-driven WebSocket push.

Trigger: DynamoDB Stream on scraping_tasks table (NEW_AND_OLD_IMAGES)

Flow:
  scraping_worker updates task status in DynamoDB
      → DynamoDB Streams emits record
      → This Lambda is triggered automatically
      → Reads all WebSocket connections subscribed to the job
      → Pushes updated job state via API Gateway Management API

AWS services used:
  - DynamoDB Streams  (CDC — change data capture, always free with DynamoDB)
  - API Gateway WebSocket API Management API  (push to connected browsers)
  - DynamoDB  (connection registry + job/task lookup)
  - X-Ray  (tracing)
  - CloudWatch  (logs)

Why this is powerful:
  Zero polling. The browser gets a push within milliseconds of any task
  status changing. No wasted DynamoDB reads. Completely event-driven.
"""

import json
import logging
import os

import boto3
from aws_xray_sdk.core import patch_all, xray_recorder
from boto3.dynamodb.conditions import Attr
from botocore.exceptions import ClientError

patch_all()

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("AWS_REGION", "ap-south-1")
STAGE = os.environ.get("STAGE", "staging")
TABLE_PREFIX = "" if STAGE == "prod" else f"{STAGE}_"

_dynamo = boto3.resource("dynamodb", region_name=REGION)
_ws_table = _dynamo.Table(f"{TABLE_PREFIX}ws_connections")
_jobs_table = _dynamo.Table(f"{TABLE_PREFIX}scraping_jobs")
_tasks_table = _dynamo.Table(f"{TABLE_PREFIX}scraping_tasks")

# WebSocket API endpoint URL is stored in SSM
_ssm = boto3.client("ssm", region_name=REGION)


def _get_ws_endpoint() -> str:
    try:
        return _ssm.get_parameter(
            Name=f"/nse/{STAGE}/websocket-endpoint"
        )["Parameter"]["Value"]
    except Exception:
        return os.environ.get("WEBSOCKET_ENDPOINT", "")


def _get_mgmt_client():
    endpoint = _get_ws_endpoint()
    if not endpoint:
        return None
    return boto3.client(
        "apigatewaymanagementapi",
        endpoint_url=endpoint,
        region_name=REGION,
    )


def _get_job_state(job_id: str) -> dict:
    """Fetch current job + tasks state from DynamoDB."""
    try:
        job_resp = _jobs_table.get_item(Key={"job_id": job_id})
        job = job_resp.get("Item", {})

        tasks_resp = _tasks_table.query(
            IndexName="job-tasks-index",
            KeyConditionExpression="job_id = :jid",
            ExpressionAttributeValues={":jid": job_id},
        )
        tasks = tasks_resp.get("Items", [])

        return {
            "type": "job_update",
            "job_id": job_id,
            "total": int(job.get("total", 0)),
            "pending": sum(1 for t in tasks if t.get("status") == "pending"),
            "running": sum(1 for t in tasks if t.get("status") == "running"),
            "completed": sum(1 for t in tasks if t.get("status") == "completed"),
            "failed": sum(1 for t in tasks if t.get("status") == "failed"),
            "tasks": [
                {
                    "task_id": t.get("task_id"), "asin": t.get("asin"),
                    "status": t.get("status"), "error": t.get("error"),
                    "product": t.get("product"),
                }
                for t in tasks
            ],
        }
    except Exception as e:
        logger.error("Failed to get job state for %s: %s", job_id, e)
        return {}


def _push_to_connections(job_id: str, payload: dict):
    """Push job update to all WebSocket connections subscribed to job_id."""
    mgmt = _get_mgmt_client()
    if not mgmt:
        logger.warning("No WebSocket endpoint configured — skipping push")
        return

    try:
        # Find all connections subscribed to this job
        resp = _ws_table.scan(
            FilterExpression=Attr("job_id").eq(job_id)
        )
        connections = resp.get("Items", [])
        logger.info("Pushing to %d WebSocket connections for job %s", len(connections), job_id)

        stale = []
        for conn in connections:
            conn_id = conn["connection_id"]
            try:
                mgmt.post_to_connection(
                    ConnectionId=conn_id,
                    Data=json.dumps(payload, default=str),
                )
            except ClientError as e:
                code = e.response["Error"]["Code"]
                if code == "GoneException":
                    stale.append(conn_id)
                else:
                    logger.error("Push error for %s: %s", conn_id, e)

        # Clean up stale connections
        for conn_id in stale:
            _ws_table.delete_item(Key={"connection_id": conn_id})
            logger.info("Removed stale connection: %s", conn_id)

    except Exception as e:
        logger.error("WebSocket push error: %s", e)


@xray_recorder.capture("dynamo_streams")
def handler(event, context):
    """Process DynamoDB Stream records from scraping_tasks table."""
    records = event.get("Records", [])
    logger.info("DynamoDB Streams: %d records", len(records))

    processed_jobs = set()

    for record in records:
        if record.get("eventName") not in ("MODIFY", "INSERT"):
            continue

        new_image = record.get("dynamodb", {}).get("NewImage", {})
        if not new_image:
            continue

        job_id = new_image.get("job_id", {}).get("S", "")
        if not job_id or job_id in processed_jobs:
            continue

        processed_jobs.add(job_id)
        job_state = _get_job_state(job_id)
        if job_state:
            _push_to_connections(job_id, job_state)

    return {"statusCode": 200, "processed_jobs": list(processed_jobs)}

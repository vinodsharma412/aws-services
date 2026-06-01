"""WebSocket Lambda — API Gateway WebSocket API handlers.

Replaces SSE and polling entirely.
Browser connects once → server pushes updates in real time.

Routes (WebSocket API route selection key = $request.body.action):
  $connect     store connection in DynamoDB with TTL
  $disconnect  remove connection from DynamoDB
  $default     handle subscribe/unsubscribe messages

DynamoDB table: {prefix}ws_connections
  PK: connection_id
  SK: user_id
  job_id: optional — subscribed job for targeted updates
  ttl: Unix timestamp 2h from now (DynamoDB TTL auto-deletes)

AWS services used:
  - API Gateway WebSocket API  (persistent connection management)
  - DynamoDB  (connection registry with TTL auto-cleanup)
  - DynamoDB TTL  (auto-expire stale connections after 2 hours)
  - X-Ray  (tracing)
  - CloudWatch  (logs)
"""

import json
import logging
import os
import time

import boto3
from aws_xray_sdk.core import patch_all, xray_recorder
from botocore.exceptions import ClientError

patch_all()

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("AWS_REGION", "ap-south-1")
STAGE = os.environ.get("STAGE", "staging")
TABLE_PREFIX = "" if STAGE == "prod" else f"{STAGE}_"
WS_TABLE = f"{TABLE_PREFIX}ws_connections"
TTL_HOURS = 2

_dynamo = boto3.resource("dynamodb", region_name=REGION)
_ws_table = _dynamo.Table(WS_TABLE)


def _get_mgmt_client(domain: str, stage: str):
    endpoint = f"https://{domain}/{stage}"
    return boto3.client(
        "apigatewaymanagementapi",
        endpoint_url=endpoint,
        region_name=REGION,
    )


@xray_recorder.capture("ws_connect")
def _connect(event):
    connection_id = event["requestContext"]["connectionId"]
    # Extract user_id from Cognito claims passed via queryStringParameters
    qs = event.get("queryStringParameters") or {}
    user_id = qs.get("user_id", "anonymous")

    ttl = int(time.time()) + (TTL_HOURS * 3600)
    try:
        _ws_table.put_item(Item={
            "connection_id": connection_id,
            "user_id": user_id,
            "connected_at": int(time.time()),
            "ttl": ttl,
            "stage": STAGE,
        })
        logger.info("WS connect: %s user=%s", connection_id, user_id)
    except Exception as e:
        logger.error("WS connect DynamoDB error: %s", e)

    return {"statusCode": 200, "body": "Connected"}


@xray_recorder.capture("ws_disconnect")
def _disconnect(event):
    connection_id = event["requestContext"]["connectionId"]
    try:
        _ws_table.delete_item(Key={"connection_id": connection_id})
        logger.info("WS disconnect: %s", connection_id)
    except Exception as e:
        logger.error("WS disconnect error: %s", e)
    return {"statusCode": 200, "body": "Disconnected"}


@xray_recorder.capture("ws_default")
def _default(event):
    connection_id = event["requestContext"]["connectionId"]
    domain = event["requestContext"]["domainName"]
    stage = event["requestContext"]["stage"]
    body = {}
    try:
        body = json.loads(event.get("body", "{}"))
    except Exception:
        pass

    action = body.get("action", "")
    job_id = body.get("job_id")

    if action == "subscribe" and job_id:
        # Link connection to a specific job for targeted pushes
        try:
            _ws_table.update_item(
                Key={"connection_id": connection_id},
                UpdateExpression="SET job_id = :j",
                ExpressionAttributeValues={":j": job_id},
            )
            mgmt = _get_mgmt_client(domain, stage)
            mgmt.post_to_connection(
                ConnectionId=connection_id,
                Data=json.dumps({"type": "subscribed", "job_id": job_id}),
            )
            logger.info("WS subscribed: %s → job %s", connection_id, job_id)
        except Exception as e:
            logger.error("WS subscribe error: %s", e)

    elif action == "ping":
        try:
            mgmt = _get_mgmt_client(domain, stage)
            mgmt.post_to_connection(
                ConnectionId=connection_id,
                Data=json.dumps({"type": "pong"}),
            )
        except Exception:
            pass

    return {"statusCode": 200, "body": "OK"}


def handler(event, context):
    route = event.get("requestContext", {}).get("routeKey", "$default")
    if route == "$connect":
        return _connect(event)
    elif route == "$disconnect":
        return _disconnect(event)
    else:
        return _default(event)

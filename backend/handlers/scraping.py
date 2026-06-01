"""Scraping Lambda — replaces FastAPI /scraping/* endpoints.

Routes:
  POST /scraping/jobs          create job → publish to SQS → Step Functions
  GET  /scraping/jobs          list jobs
  GET  /scraping/jobs/{id}     single job with task detail

Scraping progress:
  Frontend connects to WebSocket API (wss://...) after job creation.
  DynamoDB Streams → ws_push Lambda → API GW Management API → browser.
  No polling needed. Real-time push when each task updates.

AWS services used:
  - DynamoDB  (jobs, tasks)
  - SQS  (scraping task queue)
  - Step Functions  (orchestrate multi-ASIN jobs as Map state)
  - EventBridge  (publish JobCreated / JobCompleted custom events)
  - SNS  (alert on job completion)
  - X-Ray  (distributed tracing)
  - CloudWatch  (logs)
"""

import json
import logging
import os
import sys
from datetime import datetime, timezone

import boto3
from aws_xray_sdk.core import patch_all, xray_recorder
from botocore.exceptions import ClientError

patch_all()

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.crud import scraping_dynamo
from app.services.scraping_queue import enqueue
from handlers._base import (
    STAGE,
    bad_request,
    created,
    forbidden,
    get_body,
    get_current_role,
    get_current_user_id,
    get_current_username,
    get_method,
    get_path,
    get_path_params,
    get_qs,
    not_found,
    ok,
    server_error,
)

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("AWS_REGION", "ap-south-1")

_events = boto3.client("events", region_name=REGION)
_sfn = boto3.client("stepfunctions", region_name=REGION)
_ssm = boto3.client("ssm", region_name=REGION)


def _get_sfn_arn() -> str:
    try:
        return _ssm.get_parameter(
            Name=f"/nse/{STAGE}/stepfunctions-scraping-arn"
        )["Parameter"]["Value"]
    except Exception:
        return os.environ.get("STEPFUNCTIONS_SCRAPING_ARN", "")


def _publish_job_event(event_type: str, detail: dict) -> None:
    """Publish a custom event to EventBridge for downstream consumers."""
    try:
        _events.put_events(Entries=[{
            "Source": "nse.scraping",
            "DetailType": event_type,
            "Detail": json.dumps(detail),
            "EventBusName": "default",
        }])
        logger.info("EventBridge: %s published", event_type)
    except ClientError as e:
        logger.warning("EventBridge publish failed: %s", e)


def _task_to_dict(t: dict) -> dict:
    return {
        "id": t.get("task_id"), "asin": t.get("asin"),
        "status": t.get("status"), "error": t.get("error"),
        "queued_at": t.get("queued_at"), "started_at": t.get("started_at"),
        "completed_at": t.get("completed_at"), "product": t.get("product"),
    }


def _job_to_dict(job: dict, tasks=None) -> dict:
    if tasks is not None:
        pending = sum(1 for t in tasks if t.get("status") == "pending")
        running = sum(1 for t in tasks if t.get("status") == "running")
        completed = sum(1 for t in tasks if t.get("status") == "completed")
        failed = sum(1 for t in tasks if t.get("status") == "failed")
    else:
        pending = int(job.get("pending", 0))
        running = int(job.get("running", 0))
        completed = int(job.get("completed", 0))
        failed = int(job.get("failed", 0))

    return {
        "id": job.get("job_id"), "user_id": job.get("user_id"),
        "username": job.get("username"), "total": int(job.get("total", 0)),
        "pending": pending, "running": running,
        "completed": completed, "failed": failed,
        "created_at": job.get("created_at"),
        "tasks": [_task_to_dict(t) for t in tasks] if tasks is not None else None,
    }


@xray_recorder.capture("scraping")
def handler(event, context):
    method = get_method(event)
    path = get_path(event)
    path_params = get_path_params(event)
    user_id = get_current_user_id(event)
    username = get_current_username(event)
    role = get_current_role(event)

    if method == "OPTIONS":
        return ok({})

    try:
        # ── POST /scraping/jobs ───────────────────────────────────────────────
        if method == "POST" and (path.endswith("/jobs") or path.rstrip("/").endswith("/jobs")):
            body = get_body(event)
            asins = body.get("asins", [])
            if not asins or not isinstance(asins, list):
                return bad_request("asins must be a non-empty list")
            if len(asins) > 50:
                return bad_request("Maximum 50 ASINs per request")

            # Validate ASIN format (10 alphanumeric chars)
            invalid = [a for a in asins if not (isinstance(a, str) and len(a) == 10 and a.isalnum())]
            if invalid:
                return bad_request(f"Invalid ASINs: {invalid[:5]}")

            job = scraping_dynamo.create_job(
                user_id=user_id, username=username, total=len(asins),
            )
            tasks = [scraping_dynamo.create_task(job["job_id"], asin) for asin in asins]

            # Try Step Functions first (orchestrated workflow with Map state)
            sfn_arn = _get_sfn_arn()
            if sfn_arn:
                try:
                    _sfn.start_execution(
                        stateMachineArn=sfn_arn,
                        name=f"job-{job['job_id'][:8]}-{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}",
                        input=json.dumps({
                            "job_id": job["job_id"],
                            "tasks": [{"task_id": t["task_id"], "asin": t["asin"]} for t in tasks],
                        }),
                    )
                    logger.info("Step Functions execution started for job %s", job["job_id"])
                except ClientError as e:
                    logger.warning("Step Functions failed, falling back to SQS: %s", e)
                    for task in tasks:
                        enqueue(task["task_id"])
            else:
                # Fallback: SQS-triggered Lambda worker
                for task in tasks:
                    enqueue(task["task_id"])

            # Publish JobCreated event to EventBridge
            _publish_job_event("JobCreated", {
                "job_id": job["job_id"],
                "user_id": user_id,
                "total": len(asins),
                "stage": STAGE,
            })

            logger.info("Created job %s with %d ASINs", job["job_id"], len(asins))
            return created(_job_to_dict(job, tasks=tasks))

        # ── GET /scraping/jobs ────────────────────────────────────────────────
        if method == "GET" and (path.endswith("/jobs") or path.rstrip("/").endswith("/jobs")):
            if role == "viewer":
                jobs = scraping_dynamo.list_jobs_for_user(user_id)
            else:
                jobs = scraping_dynamo.list_all_jobs()
            return ok([_job_to_dict(j) for j in jobs])

        # ── GET /scraping/jobs/{job_id} ───────────────────────────────────────
        job_id = path_params.get("job_id")
        if method == "GET" and job_id:
            job = scraping_dynamo.get_job(job_id)
            if not job:
                return not_found("Job not found")
            if role == "viewer" and job.get("user_id") != user_id:
                return forbidden("Access denied")
            tasks = scraping_dynamo.get_tasks_for_job(job_id)
            return ok(_job_to_dict(job, tasks=tasks))

        return ok({"detail": "Route not found"}, 404)

    except Exception as e:
        logger.error("Scraping handler error: %s", e, exc_info=True)
        return server_error(str(e))

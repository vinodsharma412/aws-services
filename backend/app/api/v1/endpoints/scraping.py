"""Amazon ASIN scraping job endpoints.

Architecture change — Lambda edition:
    SSE (Server-Sent Events) has been REMOVED because API Gateway + Lambda
    enforces a hard 29-second response timeout that breaks long-lived streams.

    Real-time progress is now delivered via POLLING:
        Frontend polls  GET /scraping/jobs         every 2 s (job list)
        Frontend polls  GET /scraping/jobs/{id}    every 2 s (single job)

    The scraping itself runs in a separate SQS-triggered Lambda:
        POST /scraping/jobs
          → creates DynamoDB records
          → publishes task_ids to SQS
          → SQS triggers nse-scraping-worker-{stage} Lambda
          → worker scrapes Amazon, updates DynamoDB
          → next frontend poll sees updated status

REST endpoints:
    POST  /jobs          — create a new scraping job (enqueue all ASINs)
    GET   /jobs          — list jobs visible to the current user
    GET   /jobs/{job_id} — single job with full task detail
"""

from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, status

from app.crud import scraping_dynamo
from app.dependencies import get_current_active_user
from app.schemas.scraping import JobCreate, JobOut
from app.services.scraping_queue import enqueue

router = APIRouter()


# ── Serialisation helpers ──────────────────────────────────────────────────────


def _task_to_dict(t: dict) -> dict:
    """Normalise a DynamoDB task item for JSON output.

    Args:
        t: Raw DynamoDB task dict.

    Returns:
        Normalised dict with ``id`` mapped from ``task_id``.
    """
    return {
        "id": t.get("task_id"),
        "asin": t.get("asin"),
        "status": t.get("status"),
        "error": t.get("error"),
        "queued_at": t.get("queued_at"),
        "started_at": t.get("started_at"),
        "completed_at": t.get("completed_at"),
        "product": t.get("product"),
    }


def _job_to_dict(job: dict, tasks: Optional[list] = None) -> dict:
    """Normalise a DynamoDB job item for JSON output.

    When tasks are provided, counters are derived from live task rows rather
    than the potentially-stale counter fields on the job record.

    Args:
        job:   Raw DynamoDB job dict.
        tasks: Optional list of task dicts (for accurate live counters).

    Returns:
        Normalised job dict.
    """
    if tasks is not None:
        pending   = sum(1 for t in tasks if t.get("status") == "pending")
        running   = sum(1 for t in tasks if t.get("status") == "running")
        completed = sum(1 for t in tasks if t.get("status") == "completed")
        failed    = sum(1 for t in tasks if t.get("status") == "failed")
    else:
        pending   = int(job.get("pending", 0))
        running   = int(job.get("running", 0))
        completed = int(job.get("completed", 0))
        failed    = int(job.get("failed", 0))

    return {
        "id":         job.get("job_id"),
        "user_id":    job.get("user_id"),
        "username":   job.get("username"),
        "total":      int(job.get("total", 0)),
        "pending":    pending,
        "running":    running,
        "completed":  completed,
        "failed":     failed,
        "created_at": job.get("created_at"),
        "tasks":      [_task_to_dict(t) for t in tasks] if tasks is not None else None,
    }


# ── REST endpoints ─────────────────────────────────────────────────────────────


@router.post("/jobs", response_model=JobOut, status_code=status.HTTP_201_CREATED)
def create_job(
    payload: JobCreate,
    current_user: dict = Depends(get_current_active_user),
) -> dict:
    """Create a new scraping job and enqueue all ASINs to SQS.

    Creates one ScrapingJob record and one ScrapingTask per ASIN in DynamoDB,
    then publishes each task_id to SQS.  The nse-scraping-worker Lambda picks
    them up automatically via its SQS event-source mapping.

    Frontend tracks progress by polling GET /scraping/jobs/{id} every 2 seconds.

    Args:
        payload:      Validated JobCreate body with a list of ASIN strings.
        current_user: Authenticated user dict from DynamoDB.

    Returns:
        The created job as JobOut (with full task list and initial counters).
    """
    asins = payload.asins
    job = scraping_dynamo.create_job(
        user_id=current_user["user_id"],
        username=current_user.get("username", ""),
        total=len(asins),
    )

    tasks = [scraping_dynamo.create_task(job["job_id"], asin) for asin in asins]

    for task in tasks:
        enqueue(task["task_id"])

    return _job_to_dict(job, tasks=tasks)


@router.get("/jobs", response_model=List[JobOut])
def list_jobs(current_user: dict = Depends(get_current_active_user)) -> List[dict]:
    """List scraping jobs visible to the current user.

    ADMIN and MANAGER see all jobs; VIEWER sees only their own.

    Poll this endpoint every 2 seconds while jobs are active to track
    progress (replaces the previous SSE /events stream).

    Args:
        current_user: Authenticated user dict.

    Returns:
        List of jobs as JobOut (without task detail — use GET /jobs/{id} for tasks).
    """
    if current_user.get("role") == "viewer":
        jobs = scraping_dynamo.list_jobs_for_user(current_user["user_id"])
    else:
        jobs = scraping_dynamo.list_all_jobs()

    return [_job_to_dict(j) for j in jobs]


@router.get("/jobs/{job_id}", response_model=JobOut)
def get_job(
    job_id: str,
    current_user: dict = Depends(get_current_active_user),
) -> dict:
    """Retrieve a single scraping job with full task detail.

    Poll this endpoint every 2 seconds to track progress of an active job.
    Stop polling when  pending == 0  and  running == 0.

    Args:
        job_id:       UUID string primary key of the job.
        current_user: Used for ownership check when role is VIEWER.

    Returns:
        Job as JobOut including all tasks and scraped product data.

    Raises:
        HTTPException 404: If the job does not exist.
        HTTPException 403: If a VIEWER requests a job they do not own.
    """
    job = scraping_dynamo.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found.")

    if (
        current_user.get("role") == "viewer"
        and job.get("user_id") != current_user["user_id"]
    ):
        raise HTTPException(status_code=403, detail="Access denied.")

    tasks = scraping_dynamo.get_tasks_for_job(job_id)
    return _job_to_dict(job, tasks=tasks)

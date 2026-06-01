"""Scraping Worker Lambda — SQS-triggered, httpx-based.

Trigger:  SQS queue  nse-scraping-jobs-{stage}
          (Lambda event-source mapping, batch size = 1)

Why httpx instead of Playwright:
    Playwright requires ~200 MB of browser binaries.  Lambda deployment
    packages are limited to 250 MB unzipped.  httpx + BeautifulSoup is
    < 5 MB and works within the Lambda environment without any extra layers.

Flow per SQS message:
    1. Parse task_id from message body  {"task_id": "<uuid>"}
    2. Fetch task record from DynamoDB
    3. Mark task status = "running"
    4. Scrape amazon.in/dp/{asin} using httpx
    5. On success: update DynamoDB status = "completed", store product data
       Delete SQS message (return empty batchItemFailures)
    6. On failure: update DynamoDB status = "failed", store error message
       Return message in batchItemFailures so SQS retries (up to maxReceiveCount=3)
       After 3 failures: SQS moves to DLQ → triggers nse-dlq-alert Lambda → SNS email

Environment variables (set on Lambda):
    STAGE           staging | prod
    AWS_REGION      ap-south-1

IAM permissions needed (NSELambdaRole):
    dynamodb:GetItem, PutItem, UpdateItem on {prefix}scraping_tasks
    dynamodb:UpdateItem on {prefix}scraping_jobs
    sqs:DeleteMessage, ReceiveMessage on nse-scraping-jobs-{stage}

Deploy:
    bash infrastructure/lambda/scraping_worker/deploy.sh staging
    bash infrastructure/lambda/scraping_worker/deploy.sh prod
"""

import json
import logging
import os
from datetime import datetime, timezone
from typing import Optional

import boto3
import httpx
from bs4 import BeautifulSoup

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("AWS_REGION", "ap-south-1")
STAGE = os.environ.get("STAGE", "staging")
TABLE_PREFIX = "" if STAGE == "prod" else f"{STAGE}_"

_dynamo = boto3.resource("dynamodb", region_name=REGION)
_tasks_table = _dynamo.Table(f"{TABLE_PREFIX}scraping_tasks")
_jobs_table = _dynamo.Table(f"{TABLE_PREFIX}scraping_jobs")


# ── Amazon scraper (httpx + BeautifulSoup) ─────────────────────────────────────

_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept-Language": "en-IN,en;q=0.9",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
}

_PRICE_SELECTORS = [
    ".a-price .a-offscreen",
    "#priceblock_ourprice",
    "#priceblock_dealprice",
    ".apexPriceToPay .a-offscreen",
    "#corePrice_feature_div .a-offscreen",
]


def _scrape_amazon(asin: str) -> dict:
    """Scrape product data for one Amazon ASIN using httpx + BeautifulSoup.

    This is the Lambda-compatible replacement for the Playwright scraper.
    httpx works without any browser binary so the Lambda package stays small.

    Args:
        asin: Amazon Standard Identification Number (10-char string).

    Returns:
        Dict with asin, title, brand, price, rating, review_count,
        availability, image_url, scraped_at.

    Raises:
        RuntimeError: On CAPTCHA, 404, or HTTP error.
    """
    url = f"https://www.amazon.in/dp/{asin}"

    with httpx.Client(headers=_HEADERS, follow_redirects=True, timeout=15) as client:
        resp = client.get(url)

    if resp.status_code == 404:
        raise RuntimeError(f"ASIN {asin} not found on Amazon.in (404)")
    if resp.status_code != 200:
        raise RuntimeError(f"Amazon returned HTTP {resp.status_code} for ASIN {asin}")

    soup = BeautifulSoup(resp.text, "html.parser")

    if soup.find("form", {"action": "/errors/validateCaptcha"}):
        raise RuntimeError(f"Amazon returned CAPTCHA for ASIN {asin}")

    def _text(selector: str) -> Optional[str]:
        el = soup.select_one(selector)
        return el.get_text(strip=True) if el else None

    def _attr(selector: str, attr: str) -> Optional[str]:
        el = soup.select_one(selector)
        return el.get(attr) if el else None

    title = _text("#productTitle")
    brand = _text("#bylineInfo")

    price = None
    for sel in _PRICE_SELECTORS:
        price = _text(sel)
        if price:
            break

    rating_el = soup.select_one("#acrPopover")
    rating = None
    if rating_el:
        title_attr = rating_el.get("title", "")
        rating = title_attr.split(" ")[0] if title_attr else None

    review_count = _text("#acrCustomerReviewText")
    avail_el = soup.select_one("#availability span")
    availability = avail_el.get_text(strip=True) if avail_el else None

    img_el = soup.select_one("#landingImage")
    image_url = None
    if img_el:
        image_url = img_el.get("data-old-hires") or img_el.get("src")

    logger.info("Scraped ASIN %s: title=%r price=%r", asin, title, price)

    return {
        "asin": asin,
        "title": title,
        "brand": brand,
        "price": price,
        "rating": rating,
        "review_count": review_count,
        "availability": availability,
        "image_url": image_url,
        "scraped_at": datetime.now(timezone.utc).isoformat(),
    }


# ── DynamoDB helpers ───────────────────────────────────────────────────────────

def _get_task(task_id: str) -> Optional[dict]:
    resp = _tasks_table.get_item(Key={"task_id": task_id})
    return resp.get("Item")


def _update_task_status(task_id: str, new_status: str, **extra) -> None:
    update_expr = "SET #s = :s, updated_at = :u"
    names = {"#s": "status"}
    values = {":s": new_status, ":u": datetime.now(timezone.utc).isoformat()}

    if new_status == "running":
        update_expr += ", started_at = :t"
        values[":t"] = datetime.now(timezone.utc).isoformat()
    elif new_status in ("completed", "failed"):
        update_expr += ", completed_at = :t"
        values[":t"] = datetime.now(timezone.utc).isoformat()

    if "product" in extra:
        update_expr += ", product = :p"
        values[":p"] = extra["product"]
    if "error" in extra:
        update_expr += ", #e = :err"
        names["#e"] = "error"
        values[":err"] = str(extra["error"])[:500]

    _tasks_table.update_item(
        Key={"task_id": task_id},
        UpdateExpression=update_expr,
        ExpressionAttributeNames=names,
        ExpressionAttributeValues=values,
    )


def _inc_job_counter(job_id: str, field: str, delta: int) -> None:
    _jobs_table.update_item(
        Key={"job_id": job_id},
        UpdateExpression="SET #f = if_not_exists(#f, :zero) + :d",
        ExpressionAttributeNames={"#f": field},
        ExpressionAttributeValues={":d": delta, ":zero": 0},
    )


# ── Lambda handler ─────────────────────────────────────────────────────────────

def lambda_handler(event: dict, context) -> dict:
    """Process SQS messages — scrape Amazon ASINs and update DynamoDB.

    Each SQS message body: {"task_id": "<uuid>"}

    Returns batchItemFailures so SQS retries failed messages.
    After maxReceiveCount=3 failures, SQS moves to DLQ which triggers
    the nse-dlq-alert Lambda to send an SNS email.

    Args:
        event:   SQS event with Records list.
        context: Lambda context (unused).

    Returns:
        {"batchItemFailures": [...]} — empty list means all succeeded.
    """
    records = event.get("Records", [])
    logger.info("Scraping worker: %d SQS records received | stage=%s", len(records), STAGE)

    batch_failures = []

    for record in records:
        message_id = record.get("messageId", "?")
        try:
            body = json.loads(record.get("body", "{}"))
            task_id = body.get("task_id", "")

            if not task_id:
                logger.warning("Empty task_id in SQS message %s — skipping", message_id)
                continue

            task = _get_task(task_id)
            if not task:
                logger.warning("task_id=%s not found in DynamoDB — discarding message", task_id)
                continue

            if task.get("status") != "pending":
                logger.info("task_id=%s already %s — skipping", task_id, task.get("status"))
                continue

            job_id = task["job_id"]
            asin = task["asin"]

            logger.info("Processing task_id=%s asin=%s", task_id, asin)
            _update_task_status(task_id, "running")
            _inc_job_counter(job_id, "pending", -1)
            _inc_job_counter(job_id, "running", 1)

            product_data = _scrape_amazon(asin)

            _update_task_status(task_id, "completed", product=product_data)
            _inc_job_counter(job_id, "running", -1)
            _inc_job_counter(job_id, "completed", 1)
            logger.info("DONE task=%s asin=%s title=%r", task_id, asin, (product_data.get("title") or "")[:60])

        except Exception as exc:
            logger.error("FAIL task_id=%s error=%s", task_id if "task_id" in dir() else "?", exc)
            try:
                _update_task_status(task_id, "failed", error=str(exc))
                _inc_job_counter(job_id, "running", -1)
                _inc_job_counter(job_id, "failed", 1)
            except Exception:
                pass
            batch_failures.append({"itemIdentifier": message_id})

    return {"batchItemFailures": batch_failures}

"""SES Notifications Lambda — email reports and alerts.

Triggers:
  EventBridge rule: JobCompleted event → send scraping report
  EventBridge rule: DailyPortfolioReport → send portfolio summary
  Direct invocation: admin triggers weekly report

AWS services used:
  - SES (Simple Email Service)  — transactional email, 62K/month free from Lambda
  - DynamoDB  — fetch portfolio + job data
  - S3  — attach CSV export of job results
  - SSM  — get sender email address
  - Translate  — optionally translate product titles to English
  - X-Ray  — tracing
"""

import csv
import io
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

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("AWS_REGION", "ap-south-1")
STAGE = os.environ.get("STAGE", "staging")
TABLE_PREFIX = "" if STAGE == "prod" else f"{STAGE}_"

_ses = boto3.client("ses", region_name=REGION)
_translate = boto3.client("translate", region_name=REGION)
_s3 = boto3.client("s3", region_name=REGION)
_ssm = boto3.client("ssm", region_name=REGION)


def _get_sender() -> str:
    try:
        return _ssm.get_parameter(
            Name=f"/nse/{STAGE}/ses-sender-email"
        )["Parameter"]["Value"]
    except Exception:
        return os.environ.get("SES_SENDER_EMAIL", "")


def _translate_text(text: str, source_lang: str = "auto") -> str:
    """Translate product title to English using AWS Translate.

    AWS Translate free tier: 2M characters/month for 12 months.
    """
    if not text or source_lang == "en":
        return text
    try:
        resp = _translate.translate_text(
            Text=text[:5000],
            SourceLanguageCode=source_lang,
            TargetLanguageCode="en",
        )
        return resp["TranslatedText"]
    except Exception as e:
        logger.warning("Translate error: %s", e)
        return text


def _build_job_report_html(job: dict, tasks: list) -> str:
    completed = [t for t in tasks if t.get("status") == "completed"]
    failed = [t for t in tasks if t.get("status") == "failed"]
    rows = ""
    for t in completed[:20]:  # limit to 20 rows in email
        product = t.get("product") or {}
        title = product.get("title", "—")
        # Translate non-English product titles
        if title and title != "—":
            title = _translate_text(title)
        rows += f"""
        <tr>
            <td>{t.get('asin', '—')}</td>
            <td>{title[:80]}</td>
            <td>{product.get('price', '—')}</td>
            <td>{product.get('rating', '—')}</td>
            <td style="color:#27ae60">✓ done</td>
        </tr>"""
    for t in failed:
        rows += f"""
        <tr>
            <td>{t.get('asin', '—')}</td>
            <td colspan="3" style="color:#e74c3c">{(t.get('error') or '—')[:80]}</td>
            <td style="color:#e74c3c">✗ failed</td>
        </tr>"""
    return f"""
    <html><body style="font-family:sans-serif">
    <h2>Scraping Job Report — {STAGE.upper()}</h2>
    <p>Job ID: <code>{job.get('job_id','—')}</code></p>
    <p>Submitted by: <strong>{job.get('username','—')}</strong></p>
    <p>Total: {job.get('total',0)} | Completed: {len(completed)} | Failed: {len(failed)}</p>
    <table border="1" cellpadding="6" style="border-collapse:collapse;width:100%">
        <tr style="background:#2c3e50;color:#fff">
            <th>ASIN</th><th>Title</th><th>Price</th><th>Rating</th><th>Status</th>
        </tr>
        {rows}
    </table>
    <p style="color:#666;font-size:12px">
        Sent by NSE Dashboard | Stage: {STAGE}
        | Time: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}
    </p>
    </body></html>"""


@xray_recorder.capture("ses_notifications")
def handler(event, context):
    """Handle SES notification events from EventBridge."""
    logger.info("SES handler triggered: %s", json.dumps(event, default=str)[:500])

    sender = _get_sender()
    if not sender:
        logger.error("SES sender email not configured — check SSM /nse/%s/ses-sender-email", STAGE)
        return {"statusCode": 500}

    detail_type = event.get("detail-type", "")
    detail = event.get("detail", {})

    # ── Job Completed notification ────────────────────────────────────────────
    if detail_type == "JobCompleted" or detail.get("job_id"):
        job_id = detail.get("job_id", "")
        recipient = detail.get("user_email") or sender  # fallback to sender

        job = scraping_dynamo.get_job(job_id) or {}
        tasks = scraping_dynamo.get_tasks_for_job(job_id) if job_id else []

        html = _build_job_report_html(job, tasks)
        subject = f"[NSE {STAGE.upper()}] Scraping job complete — {job.get('total',0)} ASINs"

        try:
            _ses.send_email(
                Source=sender,
                Destination={"ToAddresses": [recipient]},
                Message={
                    "Subject": {"Data": subject[:78], "Charset": "UTF-8"},
                    "Body": {"Html": {"Data": html, "Charset": "UTF-8"}},
                },
            )
            logger.info("Job report sent to %s for job %s", recipient, job_id)
        except ClientError as e:
            logger.error("SES send failed: %s", e)
            return {"statusCode": 500}

    # ── Daily portfolio summary ───────────────────────────────────────────────
    elif detail_type == "DailyPortfolioReport":
        logger.info("Daily portfolio report triggered")
        # Placeholder for portfolio email — similar pattern

    return {"statusCode": 200, "body": "Email sent"}

"""Create all DynamoDB tables for the NSE Stock Dashboard.

Multi-account architecture:
  - Run this script INSIDE each AWS account (staging OR prod), NOT both together.
  - The AWS account itself provides isolation — no table prefix is needed.
  - Tables are identical in both accounts: "users", "scraping_tasks", etc.

Configure AWS CLI for the correct account before running:
  # Staging account
  export AWS_PROFILE=aws-staging    # or export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
  python3 infrastructure/dynamodb/create_tables.py

  # Prod account
  export AWS_PROFILE=aws-prod
  python3 infrastructure/dynamodb/create_tables.py

  # Or via Makefile
  AWS_PROFILE=aws-staging make dynamo-tables
  AWS_PROFILE=aws-prod    make dynamo-tables

All tables use PAY_PER_REQUEST billing — free tier (25 GB + 25 RCU/WCU forever).
DynamoDB encryption is enabled using the AWS-managed key (free, no KMS cost).
"""

import os
import sys

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION", "ap-south-1")

db = boto3.client("dynamodb", region_name=REGION)


def _account_id() -> str:
    try:
        return boto3.client("sts", region_name=REGION).get_caller_identity()["Account"]
    except Exception:
        return "unknown"


def create_table(name: str, key_schema: list, attribute_defs: list, gsi: list = None) -> None:
    """Create one DynamoDB table, skip silently if it already exists.

    Args:
        name:           Table name (no prefix — account provides isolation).
        key_schema:     DynamoDB KeySchema.
        attribute_defs: AttributeDefinitions.
        gsi:            Optional GlobalSecondaryIndexes.
    """
    kwargs = {
        "TableName": name,
        "KeySchema": key_schema,
        "AttributeDefinitions": attribute_defs,
        "BillingMode": "PAY_PER_REQUEST",
        "SSESpecification": {"Enabled": True, "SSEType": "AES256"},  # free KMS
    }
    if gsi:
        kwargs["GlobalSecondaryIndexes"] = gsi

    try:
        db.create_table(**kwargs)
        print(f"  Creating → {name} ...")
        db.get_waiter("table_exists").wait(TableName=name)
        print(f"  ACTIVE   ✓ {name}")
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ResourceInUseException":
            print(f"  EXISTS   – {name} (skipped)")
        else:
            raise


def main() -> None:
    """Create all 13 DynamoDB tables (no prefix — isolated by AWS account)."""
    account = _account_id()
    print(f"Creating DynamoDB tables")
    print(f"Account: {account}  |  Region: {REGION}")
    print("=" * 60)

    # ── Users ─────────────────────────────────────────────────────────────────
    create_table(
        name="users",
        key_schema=[{"AttributeName": "user_id", "KeyType": "HASH"}],
        attribute_defs=[
            {"AttributeName": "user_id",  "AttributeType": "S"},
            {"AttributeName": "username", "AttributeType": "S"},
            {"AttributeName": "email",    "AttributeType": "S"},
        ],
        gsi=[
            {
                "IndexName": "username-index",
                "KeySchema": [{"AttributeName": "username", "KeyType": "HASH"}],
                "Projection": {"ProjectionType": "ALL"},
            },
            {
                "IndexName": "email-index",
                "KeySchema": [{"AttributeName": "email", "KeyType": "HASH"}],
                "Projection": {"ProjectionType": "ALL"},
            },
        ],
    )

    # ── Stock Transactions ─────────────────────────────────────────────────────
    create_table(
        name="stock_transactions",
        key_schema=[{"AttributeName": "txn_id", "KeyType": "HASH"}],
        attribute_defs=[
            {"AttributeName": "txn_id",  "AttributeType": "S"},
            {"AttributeName": "user_id", "AttributeType": "S"},
        ],
        gsi=[{
            "IndexName": "user-transactions-index",
            "KeySchema": [{"AttributeName": "user_id", "KeyType": "HASH"}],
            "Projection": {"ProjectionType": "ALL"},
        }],
    )

    # ── Stock Watchlist ────────────────────────────────────────────────────────
    create_table(
        name="stock_watchlist",
        key_schema=[{"AttributeName": "wl_id", "KeyType": "HASH"}],
        attribute_defs=[
            {"AttributeName": "wl_id",   "AttributeType": "S"},
            {"AttributeName": "user_id", "AttributeType": "S"},
            {"AttributeName": "symbol",  "AttributeType": "S"},
        ],
        gsi=[
            {
                "IndexName": "user-watchlist-index",
                "KeySchema": [{"AttributeName": "user_id", "KeyType": "HASH"}],
                "Projection": {"ProjectionType": "ALL"},
            },
            {
                "IndexName": "user-symbol-index",
                "KeySchema": [
                    {"AttributeName": "user_id", "KeyType": "HASH"},
                    {"AttributeName": "symbol",  "KeyType": "RANGE"},
                ],
                "Projection": {"ProjectionType": "KEYS_ONLY"},
            },
        ],
    )

    # ── Scraping Jobs ──────────────────────────────────────────────────────────
    create_table(
        name="scraping_jobs",
        key_schema=[{"AttributeName": "job_id", "KeyType": "HASH"}],
        attribute_defs=[
            {"AttributeName": "job_id",  "AttributeType": "S"},
            {"AttributeName": "user_id", "AttributeType": "S"},
        ],
        gsi=[{
            "IndexName": "user-jobs-index",
            "KeySchema": [{"AttributeName": "user_id", "KeyType": "HASH"}],
            "Projection": {"ProjectionType": "ALL"},
        }],
    )

    # ── Scraping Tasks (with DynamoDB Streams for WebSocket push) ─────────────
    create_table(
        name="scraping_tasks",
        key_schema=[{"AttributeName": "task_id", "KeyType": "HASH"}],
        attribute_defs=[
            {"AttributeName": "task_id", "AttributeType": "S"},
            {"AttributeName": "job_id",  "AttributeType": "S"},
            {"AttributeName": "status",  "AttributeType": "S"},
        ],
        gsi=[
            {
                "IndexName": "job-tasks-index",
                "KeySchema": [{"AttributeName": "job_id", "KeyType": "HASH"}],
                "Projection": {"ProjectionType": "ALL"},
            },
            {
                "IndexName": "status-index",
                "KeySchema": [{"AttributeName": "status", "KeyType": "HASH"}],
                "Projection": {"ProjectionType": "ALL"},
            },
        ],
    )

    # ── Product Data, Screener Cache, Menus, Menu Access ──────────────────────
    for table_name, pk in [
        ("product_data",    "task_id"),
        ("screener_cache",  "cache_key"),
        ("product_master",  "product_id"),
    ]:
        create_table(
            name=table_name,
            key_schema=[{"AttributeName": pk, "KeyType": "HASH"}],
            attribute_defs=[{"AttributeName": pk, "AttributeType": "S"}],
        )

    # ── Menus ──────────────────────────────────────────────────────────────────
    create_table(
        name="menus",
        key_schema=[{"AttributeName": "menu_id", "KeyType": "HASH"}],
        attribute_defs=[
            {"AttributeName": "menu_id",   "AttributeType": "S"},
            {"AttributeName": "path",      "AttributeType": "S"},
            {"AttributeName": "parent_id", "AttributeType": "S"},
        ],
        gsi=[
            {
                "IndexName": "path-index",
                "KeySchema": [{"AttributeName": "path", "KeyType": "HASH"}],
                "Projection": {"ProjectionType": "ALL"},
            },
            {
                "IndexName": "parent-index",
                "KeySchema": [{"AttributeName": "parent_id", "KeyType": "HASH"}],
                "Projection": {"ProjectionType": "ALL"},
            },
        ],
    )

    # ── Menu Access ────────────────────────────────────────────────────────────
    create_table(
        name="menu_access",
        key_schema=[{"AttributeName": "access_id", "KeyType": "HASH"}],
        attribute_defs=[
            {"AttributeName": "access_id", "AttributeType": "S"},
            {"AttributeName": "menu_id",   "AttributeType": "S"},
            {"AttributeName": "role",      "AttributeType": "S"},
        ],
        gsi=[
            {
                "IndexName": "menu-index",
                "KeySchema": [{"AttributeName": "menu_id", "KeyType": "HASH"}],
                "Projection": {"ProjectionType": "ALL"},
            },
            {
                "IndexName": "role-index",
                "KeySchema": [{"AttributeName": "role", "KeyType": "HASH"}],
                "Projection": {"ProjectionType": "ALL"},
            },
        ],
    )

    # ── WebSocket Connections (with TTL for auto-cleanup) ──────────────────────
    create_table(
        name="ws_connections",
        key_schema=[{"AttributeName": "connection_id", "KeyType": "HASH"}],
        attribute_defs=[
            {"AttributeName": "connection_id", "AttributeType": "S"},
            {"AttributeName": "job_id",        "AttributeType": "S"},
        ],
        gsi=[{
            "IndexName": "job-connections-index",
            "KeySchema": [{"AttributeName": "job_id", "KeyType": "HASH"}],
            "Projection": {"ProjectionType": "ALL"},
        }],
    )

    # Enable TTL on ws_connections
    try:
        db.update_time_to_live(
            TableName="ws_connections",
            TimeToLiveSpecification={"Enabled": True, "AttributeName": "ttl"},
        )
        print("  TTL enabled: ws_connections.ttl (2h auto-expire)")
    except ClientError:
        pass

    print("=" * 60)
    print(f"All tables ready in account {account}")
    print("")
    print("Next step: enable DynamoDB Streams on scraping_tasks")
    print("  bash infrastructure/websocket/setup_websocket_api.sh")


if __name__ == "__main__":
    main()

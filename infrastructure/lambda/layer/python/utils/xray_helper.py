"""X-Ray tracing helpers.

AWS X-Ray traces every Lambda invocation automatically when:
  - LAMBDA_INSIGHTS_LOG_GROUP is set  (CloudWatch Lambda Insights)
  - aws_xray_sdk is installed + patch_all() called at module level

Free tier: 100,000 traces/month + 1M trace segments/month forever.

Usage:
    from utils.xray_helper import trace, add_annotation, add_metadata

    @trace("my_operation")
    def slow_function():
        ...

    add_annotation("user_id", user_id)
    add_metadata("stock", {"symbol": "TCS", "price": 3500})
"""

import functools
import logging
from typing import Any, Callable

logger = logging.getLogger(__name__)

try:
    from aws_xray_sdk.core import xray_recorder
    from aws_xray_sdk.core import patch_all as _patch_all
    _XRAY_AVAILABLE = True
except ImportError:
    logger.warning("aws_xray_sdk not available — X-Ray disabled")
    _XRAY_AVAILABLE = False


def patch_all():
    """Patch all supported libraries (boto3, requests, httpx) for X-Ray tracing."""
    if _XRAY_AVAILABLE:
        _patch_all()


def trace(name: str):
    """Decorator to add an X-Ray subsegment around a function."""
    def decorator(func: Callable) -> Callable:
        if not _XRAY_AVAILABLE:
            return func

        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            with xray_recorder.in_subsegment(name):
                return func(*args, **kwargs)
        return wrapper
    return decorator


def add_annotation(key: str, value: Any) -> None:
    """Add a searchable annotation to the current X-Ray segment.

    Annotations are indexed — you can search for them in X-Ray console.
    Example: add_annotation("user_id", "abc-123")
    """
    if not _XRAY_AVAILABLE:
        return
    try:
        xray_recorder.current_segment().put_annotation(key, value)
    except Exception:
        pass


def add_metadata(key: str, value: Any, namespace: str = "nse") -> None:
    """Add metadata to the current X-Ray segment (not indexed, any type).

    Example: add_metadata("request", {"symbol": "TCS", "period": "1y"})
    """
    if not _XRAY_AVAILABLE:
        return
    try:
        xray_recorder.current_segment().put_metadata(key, value, namespace)
    except Exception:
        pass

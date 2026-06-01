"""AWS AppConfig client — feature flags for Lambda.

AppConfig lets you change feature flags WITHOUT redeploying Lambda.
Example: disable Comprehend sentiment during quota outage, enable
beta features for specific users, A/B test new screener algorithm.

Free tier: AppConfig itself is free. Data stored in SSM (free).

Usage in any Lambda:
    from utils.appconfig import get_flag

    if get_flag("COMPREHEND_ENABLED", default=True):
        score = comprehend_sentiment(text)
    else:
        score = keyword_sentiment(text)
"""

import json
import logging
import os
import time
from functools import lru_cache
from typing import Any

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)

REGION = os.environ.get("AWS_REGION", "ap-south-1")
STAGE = os.environ.get("STAGE", "staging")
APP_NAME = "NSEDashboard"
ENV_NAME = STAGE.capitalize()
CONFIG_PROFILE = "FeatureFlags"

_appconfig = boto3.client("appconfigdata", region_name=REGION)

_cache: dict = {}
_cache_expiry: float = 0
_CACHE_TTL = 30  # seconds — AppConfig recommends polling every 30s minimum


def _fetch_config() -> dict:
    """Fetch latest feature flags from AppConfig."""
    global _cache, _cache_expiry
    now = time.time()
    if now < _cache_expiry and _cache:
        return _cache

    try:
        session_resp = _appconfig.start_configuration_session(
            ApplicationIdentifier=APP_NAME,
            EnvironmentIdentifier=ENV_NAME,
            ConfigurationProfileIdentifier=CONFIG_PROFILE,
            RequiredMinimumPollIntervalInSeconds=30,
        )
        token = session_resp["InitialConfigurationToken"]
        config_resp = _appconfig.get_latest_configuration(ConfigurationToken=token)
        raw = config_resp["Configuration"].read()
        if raw:
            _cache = json.loads(raw)
            _cache_expiry = now + _CACHE_TTL
    except ClientError as e:
        logger.warning("AppConfig fetch failed: %s — using cached/default values", e)
    except Exception as e:
        logger.warning("AppConfig error: %s", e)

    return _cache


def get_flag(name: str, default: Any = None) -> Any:
    """Get a feature flag value from AppConfig.

    Args:
        name:    Flag name as configured in AppConfig (e.g. "COMPREHEND_ENABLED")
        default: Value to return if flag is not found or AppConfig unreachable

    Returns:
        The flag value (bool, str, int, dict) or default.
    """
    config = _fetch_config()
    return config.get(name, default)


def is_enabled(flag_name: str) -> bool:
    """Shorthand for boolean feature flags."""
    return bool(get_flag(flag_name, False))

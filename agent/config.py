"""Shared configuration helpers for the agent scripts.

Values are read, in order of precedence:
1. Environment variables.
2. The Terraform outputs in ../terraform (via `terraform output -json`).

Required values:
  PROJECT_ENDPOINT          - Foundry project endpoint (project_endpoint output)
  MODEL_DEPLOYMENT_NAME     - model deployment name (model_deployment_name output)
  AI_SEARCH_CONNECTION_NAME - project connection name (ai_search_connection_name)
  AI_SEARCH_ENDPOINT        - search endpoint (ai_search_endpoint output)
  AI_SEARCH_INDEX_NAME      - index name to query (default: agent-sample-index)
"""

from __future__ import annotations

import json
import os
import subprocess
from functools import lru_cache
from pathlib import Path

_TERRAFORM_DIR = Path(__file__).resolve().parent.parent / "terraform"

_OUTPUT_MAP = {
    "PROJECT_ENDPOINT": "project_endpoint",
    "MODEL_DEPLOYMENT_NAME": "model_deployment_name",
    "AI_SEARCH_CONNECTION_NAME": "ai_search_connection_name",
    "AI_SEARCH_ENDPOINT": "ai_search_endpoint",
}


@lru_cache(maxsize=1)
def _terraform_outputs() -> dict:
    """Return Terraform outputs as a dict, or {} if unavailable."""
    try:
        result = subprocess.run(
            ["terraform", "output", "-json"],
            cwd=_TERRAFORM_DIR,
            capture_output=True,
            text=True,
            check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return {}
    try:
        raw = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {}
    return {k: v.get("value") for k, v in raw.items()}


def get(name: str, default: str | None = None) -> str:
    """Resolve a config value from env, then Terraform outputs, then default."""
    if name in os.environ and os.environ[name]:
        return os.environ[name]

    tf_key = _OUTPUT_MAP.get(name)
    if tf_key:
        value = _terraform_outputs().get(tf_key)
        if value:
            return value

    if default is not None:
        return default

    raise RuntimeError(
        f"Missing configuration '{name}'. Set it as an environment variable or "
        f"run from a directory where `terraform output` is available."
    )


def index_name() -> str:
    return get("AI_SEARCH_INDEX_NAME", "agent-sample-index")

"""Content-free audit callback for Yossarian.

This deliberately records request metadata only. Prompt and response bodies are
never copied into the audit event.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from typing import Any

from litellm.integrations.custom_logger import CustomLogger

AUDIT_LOG_PATH = os.environ.get(
    "RUNTIME_AUDIT_LOG_PATH", "/var/lib/runtime-audit/audit.jsonl"
)
RUNTIME_VERSION = os.environ.get("RUNTIME_VERSION", "dev")
BACKEND_MODEL = os.environ.get("VLLM_MODEL")


def _as_dict(value: Any) -> dict[str, Any]:
    if value is None:
        return {}
    if isinstance(value, dict):
        return value
    if hasattr(value, "model_dump"):
        try:
            dumped = value.model_dump()
            return dumped if isinstance(dumped, dict) else {}
        except Exception:
            return {}
    try:
        return dict(value)
    except Exception:
        return {}


def _headers(kwargs: dict[str, Any]) -> dict[str, str]:
    params = _as_dict(kwargs.get("litellm_params"))
    request = _as_dict(params.get("proxy_server_request"))
    headers = _as_dict(request.get("headers"))
    return {str(k).lower(): str(v) for k, v in headers.items()}


def _request(kwargs: dict[str, Any]) -> dict[str, Any]:
    params = _as_dict(kwargs.get("litellm_params"))
    return _as_dict(params.get("proxy_server_request"))


def _usage(response_obj: Any) -> dict[str, Any]:
    if response_obj is None:
        return {}
    if isinstance(response_obj, dict):
        return _as_dict(response_obj.get("usage"))
    return _as_dict(getattr(response_obj, "usage", None))


def _response_field(response_obj: Any, name: str) -> Any:
    if response_obj is None:
        return None
    if isinstance(response_obj, dict):
        return response_obj.get(name)
    return getattr(response_obj, name, None)


def _iso(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc).isoformat()
    return str(value)


def _duration_ms(start_time: Any, end_time: Any) -> float | None:
    try:
        return round((end_time - start_time).total_seconds() * 1000.0, 3)
    except Exception:
        return None


def _event(
    *,
    status: str,
    kwargs: dict[str, Any],
    response_obj: Any,
    start_time: Any,
    end_time: Any,
) -> dict[str, Any]:
    request = _request(kwargs)
    headers = _headers(kwargs)
    body = _as_dict(request.get("body"))
    usage = _usage(response_obj)
    params = _as_dict(kwargs.get("litellm_params"))
    standard = _as_dict(kwargs.get("standard_logging_object"))

    error = kwargs.get("exception")
    call_id = (
        kwargs.get("litellm_call_id")
        or params.get("litellm_call_id")
        or standard.get("request_id")
        or standard.get("id")
    )

    return {
        "schema_version": 1,
        "runtime_version": RUNTIME_VERSION,
        "request_id": call_id,
        "started_at": _iso(start_time),
        "finished_at": _iso(end_time),
        "principal": {
            "id": headers.get("x-runtime-user-id") or None,
            "subject": headers.get("x-runtime-subject") or None,
            "email": headers.get("x-runtime-user-email") or None,
        },
        "client": headers.get("x-runtime-client") or None,
        "conversation_id": headers.get("x-runtime-conversation-id") or None,
        "message_id": headers.get("x-runtime-message-id") or None,
        "endpoint": request.get("url"),
        "model_alias": body.get("model") or kwargs.get("model"),
        "model_revision": BACKEND_MODEL or _response_field(response_obj, "model") or kwargs.get("model"),
        "system_fingerprint": _response_field(response_obj, "system_fingerprint"),
        "input_tokens": usage.get("prompt_tokens") or usage.get("input_tokens"),
        "output_tokens": usage.get("completion_tokens") or usage.get("output_tokens"),
        "total_tokens": usage.get("total_tokens"),
        "latency_ms": _duration_ms(start_time, end_time),
        "status": status,
        "error_type": type(error).__name__ if error is not None else None,
        "content_logged": False,
    }


def _append(event: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(AUDIT_LOG_PATH), exist_ok=True)
    payload = (json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n").encode()
    fd = os.open(AUDIT_LOG_PATH, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, payload)
    finally:
        os.close(fd)


class RuntimeAuditHandler(CustomLogger):
    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        try:
            _append(
                _event(
                    status="success",
                    kwargs=kwargs,
                    response_obj=response_obj,
                    start_time=start_time,
                    end_time=end_time,
                )
            )
        except Exception as exc:
            # Audit failure must be visible, but must not take inference down.
            print(f"RUNTIME_AUDIT_ERROR success: {exc}", flush=True)

    async def async_log_failure_event(self, kwargs, response_obj, start_time, end_time):
        try:
            _append(
                _event(
                    status="failure",
                    kwargs=kwargs,
                    response_obj=response_obj,
                    start_time=start_time,
                    end_time=end_time,
                )
            )
        except Exception as exc:
            print(f"RUNTIME_AUDIT_ERROR failure: {exc}", flush=True)


audit_handler = RuntimeAuditHandler()

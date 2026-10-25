"""Redaction helpers for server logs.

Anything written to a log, an HTTP response or a stored error message goes
through these helpers first. They never raise.
"""

from __future__ import annotations

import re
from urllib.parse import urlsplit

_SENSITIVE_KEYS = (
    "token",
    "access_token",
    "refresh_token",
    "id_token",
    "password",
    "passwd",
    "pwd",
    "api_key",
    "apikey",
    "secret",
    "client_secret",
    "signature",
    "sign",
    "sig",
    "authorization",
    "code",
    "session",
    "cookie",
)

_KEY_PATTERN = "|".join(re.escape(key) for key in _SENSITIVE_KEYS)

_QUERY_RE = re.compile(rf"([?&](?:{_KEY_PATTERN})=)[^&\s#]+", re.IGNORECASE)
_KV_RE = re.compile(
    rf"((?:{_KEY_PATTERN})\s*[:=]\s*)[^\s,;&}}\]]+", re.IGNORECASE
)
_BEARER_RE = re.compile(r"(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+", re.IGNORECASE)
_USERINFO_RE = re.compile(r"(://)[^/@\s]+@")


def redact_text(value: object, *, limit: int = 2048) -> str:
    """Return a single-line, credential-free version of a log message."""
    try:
        text = str(value or "")
    except Exception:  # pragma: no cover - defensive
        return "[unprintable]"
    text = text.replace("\r", " ").replace("\n", " ")
    text = _BEARER_RE.sub("Bearer [redacted]", text)
    text = _USERINFO_RE.sub(r"\1[redacted]@", text)
    text = _QUERY_RE.sub(r"\1[redacted]", text)
    text = _KV_RE.sub(r"\1[redacted]", text)
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > limit:
        return text[: limit - 1] + "…"
    return text


def redact_url(value: object) -> str:
    """scheme://host[:port]/path with the query and userinfo removed."""
    text = str(value or "").strip()
    if not text:
        return ""
    if "://" not in text:
        text = f"http://{text}"
    try:
        parts = urlsplit(text)
        port = parts.port
    except ValueError:
        return "[invalid-url]"
    host = parts.hostname or ""
    if not host:
        return "[invalid-url]"
    suffix = f":{port}" if port else ""
    path = parts.path or ""
    return f"{parts.scheme}://{host}{suffix}{path}"


def redact_exception(exc: BaseException, *, limit: int = 512) -> str:
    """Exception type plus a redacted message, never a full stack."""
    message = redact_text(exc, limit=limit)
    name = type(exc).__name__
    return f"{name}: {message}" if message else name

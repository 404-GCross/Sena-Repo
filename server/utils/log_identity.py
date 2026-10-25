"""Opaque per-account identifiers used to scope log records.

The value is derived from the account row plus a machine-local key, so a
recreated account with the same id, a renamed user or a reinstalled server
does not inherit another account's log history. It is never an auth token.
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import os
import secrets
from pathlib import Path

from config import load_config

logger = logging.getLogger(__name__)

_KEY_NAME = ".log_identity_key"
_warned = False


def _key_path() -> Path:
    return Path(load_config().data_path) / _KEY_NAME


def _read_or_create_key() -> bytes:
    configured = os.environ.get("SENA_LOG_IDENTITY_KEY", "").strip()
    if configured:
        return configured.encode("utf-8")

    path = _key_path()
    try:
        if path.is_file():
            stored = path.read_text(encoding="ascii").strip()
            if stored:
                return stored.encode("ascii")
        key = secrets.token_hex(32)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(key + "\n", encoding="ascii")
        try:
            path.chmod(0o600)
        except OSError:
            pass
        return key.encode("ascii")
    except OSError:
        global _warned
        if not _warned:
            _warned = True
            logger.warning(
                "Log identity key is unavailable; log scopes will not survive a restart"
            )
        return secrets.token_hex(32).encode("ascii")


def account_log_scope(user) -> str:
    """Stable, non-reversible scope for one account row."""
    created = ""
    value = getattr(user, "created_at", None)
    if value is not None:
        created = value.isoformat()
    message = f"{getattr(user, 'id', 0)}|{created}".encode("utf-8")
    return hmac.new(_read_or_create_key(), message, hashlib.sha256).hexdigest()[:32]

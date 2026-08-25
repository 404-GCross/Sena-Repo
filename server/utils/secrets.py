"""Small helpers for encrypting persisted service credentials."""

from __future__ import annotations

import os
from pathlib import Path

from cryptography.fernet import Fernet, InvalidToken

from config import load_config

_PREFIX = "enc:v1:"


def _key_path() -> Path:
    return Path(load_config().data_path) / ".secrets_key"


def _fernet() -> Fernet:
    configured = os.environ.get("SENA_ENCRYPTION_KEY", "").strip()
    if configured:
        key = configured.encode("ascii")
    else:
        path = _key_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.is_file():
            key = path.read_text(encoding="ascii").strip().encode("ascii")
        else:
            key = Fernet.generate_key()
            path.write_bytes(key + b"\n")
            try:
                path.chmod(0o600)
            except OSError:
                pass
    return Fernet(key)


def is_encrypted(value: str | None) -> bool:
    return bool(value and value.startswith(_PREFIX))


def encrypt_secret(value: str | None) -> str:
    plain = value or ""
    if not plain or is_encrypted(plain):
        return plain
    token = _fernet().encrypt(plain.encode("utf-8")).decode("ascii")
    return f"{_PREFIX}{token}"


def decrypt_secret(value: str | None) -> str:
    stored = value or ""
    if not is_encrypted(stored):
        return stored
    try:
        token = stored.removeprefix(_PREFIX).encode("ascii")
        return _fernet().decrypt(token).decode("utf-8")
    except (InvalidToken, UnicodeError, ValueError) as exc:
        raise RuntimeError("Unable to decrypt stored service credential") from exc

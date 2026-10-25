"""Shared logging setup for the API process and the local CLI."""

from __future__ import annotations

import logging
import sys
from logging.handlers import RotatingFileHandler
from pathlib import Path

_configured: set[str] = set()

_FORMAT = "%(asctime)s %(levelname)s %(name)s %(message)s"


class _AccessLogRedactionFilter(logging.Filter):
    """Strip query strings from uvicorn's access log (signed URLs carry secrets)."""

    def filter(self, record: logging.LogRecord) -> bool:
        args = record.args
        if not isinstance(args, tuple) or len(args) < 3:
            return True
        path = args[2]
        if not isinstance(path, str):
            return True
        if "?" in path:
            record.args = (*args[:2], path.split("?", 1)[0], *args[3:])
        return True


def _file_handler(data_path: Path, component: str) -> logging.Handler | None:
    try:
        directory = data_path / "logs"
        directory.mkdir(parents=True, exist_ok=True)
        handler = RotatingFileHandler(
            directory / f"{component}.log",
            maxBytes=5 * 1024 * 1024,
            backupCount=5,
            encoding="utf-8",
            delay=True,
        )
        handler.setFormatter(logging.Formatter(_FORMAT))
        try:
            (directory / f"{component}.log").touch(exist_ok=True)
            (directory / f"{component}.log").chmod(0o600)
        except OSError:
            pass
        return handler
    except OSError:
        return None


def configure_logging(
    component: str, data_path: str | Path | None = None
) -> None:
    """Configure logging once per component; safe to call repeatedly."""
    if component in _configured:
        return
    _configured.add(component)

    root = logging.getLogger()
    if not root.handlers:
        stream = logging.StreamHandler(sys.stderr)
        stream.setFormatter(logging.Formatter(_FORMAT))
        root.addHandler(stream)
    root.setLevel(logging.INFO)

    if data_path:
        handler = _file_handler(Path(data_path), component)
        if handler is not None:
            root.addHandler(handler)

    for name in ("uvicorn.access", "uvicorn.error"):
        logging.getLogger(name).addFilter(_AccessLogRedactionFilter())

    # httpx/httpcore log full URLs at INFO; keep warnings only so signed
    # download links and query parameters never reach the log.
    for name in ("httpx", "httpcore"):
        logging.getLogger(name).setLevel(logging.WARNING)

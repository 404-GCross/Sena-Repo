"""File utility functions: archive detection, file size, etc."""

from __future__ import annotations

import os
from pathlib import Path

# Supported archive extensions
ARCHIVE_EXTENSIONS = {".rar", ".zip", ".7z", ".apk", ".tar", ".gz", ".xz", ".bz2"}


def is_archive(filepath: str | Path) -> bool:
    """Check if a file is a supported archive format."""
    return Path(filepath).suffix.lower() in ARCHIVE_EXTENSIONS


def get_file_size(filepath: str | Path) -> int:
    """Get file size in bytes. Returns 0 if file doesn't exist."""
    try:
        return os.path.getsize(filepath)
    except OSError:
        return 0

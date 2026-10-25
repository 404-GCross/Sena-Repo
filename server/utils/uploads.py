"""Bounded reading for uploaded files."""

from __future__ import annotations

from fastapi import HTTPException, UploadFile

_CHUNK = 1024 * 1024


async def read_upload(
    file: UploadFile,
    *,
    limit: int,
    label: str = "文件",
) -> bytes:
    """Read an upload while enforcing a hard size limit (no unbounded RAM use)."""
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = await file.read(_CHUNK)
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise HTTPException(
                status_code=413,
                detail=f"{label}过大，最大 {limit // (1024 * 1024)} MB",
            )
        chunks.append(chunk)
    return b"".join(chunks)

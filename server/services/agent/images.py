from __future__ import annotations

import base64
import hashlib
import io
import warnings
from dataclasses import dataclass
from urllib.parse import urljoin

from PIL import Image, ImageOps

from services.scraper.orchestrator import _is_public_http_url

MAX_IMAGE_BYTES = 8 * 1024 * 1024
MAX_IMAGE_PIXELS = 20_000_000


@dataclass(frozen=True)
class ImagePreview:
    width: int
    height: int
    uri: str
    digest: str


async def remote_image_bytes(client, reference):
    current = reference
    for _ in range(6):
        if not await _is_public_http_url(current):
            raise ValueError("Image address unavailable")
        async with client.stream(
            "GET", current, follow_redirects=False, timeout=30
        ) as response:
            if response.is_redirect:
                location = response.headers.get("location")
                if not location:
                    raise ValueError("Missing image redirect")
                current = urljoin(current, location)
                continue
            response.raise_for_status()
            data = bytearray()
            async for chunk in response.aiter_bytes():
                data.extend(chunk)
                if len(data) > MAX_IMAGE_BYTES:
                    raise ValueError("Image size limit")
            if not data:
                raise ValueError("Empty image")
            return bytes(data)
    raise ValueError("Too many image redirects")


def image_preview(data: bytes) -> ImagePreview:
    if not data or len(data) > MAX_IMAGE_BYTES:
        raise ValueError("Image size limit")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(data)) as source:
                if source.width * source.height > MAX_IMAGE_PIXELS or getattr(
                    source, "is_animated", False
                ):
                    raise ValueError("Unsupported image dimensions or animation")
                image = ImageOps.exif_transpose(source)
                width, height = image.size
                image.thumbnail((1536, 1536))
                output = io.BytesIO()
                image.convert("RGB").save(output, format="JPEG", quality=85)
    except (Image.DecompressionBombWarning, Image.DecompressionBombError):
        raise ValueError("Image dimension limit") from None
    return ImagePreview(
        width,
        height,
        "data:image/jpeg;base64," + base64.b64encode(output.getvalue()).decode(),
        hashlib.sha256(data).hexdigest(),
    )


def image_data(data: bytes) -> str:
    return image_preview(data).uri

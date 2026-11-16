from __future__ import annotations

import asyncio
import base64
import hashlib
import io
import json
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urljoin, urlsplit

import httpx
from PIL import Image, ImageOps
from pydantic import BaseModel, ConfigDict, Field, StrictBool
from sqlalchemy import select, update

from models.agent import AgentResult
from models.game import Game
from services.agent.providers import ModelError
from services.agent.settings import load_settings
from services.scraper.orchestrator import _is_public_http_url
from utils.log_redaction import redact_text

MAX_IMAGE_BYTES = 8 * 1024 * 1024
MAX_IMAGE_PIXELS = 20_000_000


class ImageAssessment(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    image: int = Field(ge=0, strict=True)
    nudity: StrictBool | None
    reason: str = Field(min_length=1, max_length=240)


class Assessment(BaseModel):
    model_config = ConfigDict(extra="forbid")
    images: list[ImageAssessment] = Field(min_length=1, max_length=2)


@dataclass
class ImageCheck:
    status: str
    summary: str
    data: dict
    fingerprint: str = ""


def _local_bytes(reference: str, directory: Path) -> bytes:
    path = Path(reference).resolve()
    path.relative_to(directory.resolve())
    with path.open("rb") as image:
        data = image.read(MAX_IMAGE_BYTES + 1)
    if not data or len(data) > MAX_IMAGE_BYTES:
        raise ValueError("Image size limit")
    return data


async def _remote_bytes(client, reference):
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


def _image_data(data):
    with Image.open(io.BytesIO(data)) as image:
        if image.width * image.height > MAX_IMAGE_PIXELS or getattr(
            image, "is_animated", False
        ):
            raise ValueError("Unsupported image dimensions or animation")
        image = ImageOps.exif_transpose(image)
        image.thumbnail((1536, 1536))
        output = io.BytesIO()
        image.convert("RGB").save(output, format="JPEG", quality=85)
    return "data:image/jpeg;base64," + base64.b64encode(output.getvalue()).decode()


async def inspect_game_images(runtime, game, client, config) -> ImageCheck | None:
    if not runtime.settings.image_nsfw or not runtime.settings.vision:
        return None
    await runtime.check()
    await runtime.session.refresh(game)
    if game.metadata_locked or game.nsfw_manual or game.is_nsfw:
        return ImageCheck(
            "nsfw_skipped", "保留手动、锁定或已开启的 NSFW 设置", {"game_id": game.id}
        )

    original = (game.cover_path, game.bg_path, game.updated_at)
    images, failures = [], []
    for kind, reference, directory in (
        ("封面", game.cover_path, config.covers_path),
        ("背景", game.bg_path, config.backgrounds_path),
    ):
        if not reference:
            continue
        try:
            remote = urlsplit(reference).scheme in {"http", "https"}
            data = (
                await asyncio.wait_for(_remote_bytes(client, reference), timeout=45)
                if remote
                else await asyncio.to_thread(_local_bytes, reference, directory)
            )
            uri = await asyncio.to_thread(_image_data, data)
            images.append(
                {
                    "kind": kind,
                    "reference": reference,
                    "directory": directory,
                    "remote": remote,
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "uri": uri,
                }
            )
        except (
            OSError,
            ValueError,
            SyntaxError,
            EOFError,
            httpx.HTTPError,
            asyncio.TimeoutError,
            Image.DecompressionBombError,
        ):
            failures.append(kind)

    details = {
        "game_id": game.id,
        "images": [
            {"kind": image["kind"], "sha256": image["sha256"]} for image in images
        ],
        "unavailable": failures,
    }
    if not images:
        return ImageCheck(
            "nsfw_unknown", "没有可分析的封面或背景，保留当前 NSFW 设置", details
        )

    fingerprint = hashlib.sha256(
        json.dumps(
            [
                "image-nsfw-v1",
                game.id,
                details["images"],
                failures,
                runtime.settings.provider,
                runtime.settings.protocol,
                runtime.settings.base_url,
                runtime.settings.model,
            ],
            sort_keys=True,
        ).encode()
    ).hexdigest()
    previous = (
        await runtime.session.execute(
            select(AgentResult)
            .where(
                AgentResult.fingerprint == fingerprint,
                AgentResult.status.in_(["nsfw_checked", "nsfw_enabled"]),
            )
            .order_by(AgentResult.id.desc())
            .limit(1)
        )
    ).scalar_one_or_none()
    try:
        if previous is not None:
            answer = Assessment.model_validate(previous.data["assessment"])
            details["cached"] = True
        else:
            data = await runtime.reason(
                "image_nsfw",
                {
                    "images": [
                        {"image": index, "kind": image["kind"]}
                        for index, image in enumerate(images)
                    ]
                },
                Assessment.model_json_schema(),
                images=[image["uri"] for image in images],
            )
            answer = Assessment.model_validate(data)
        if len(answer.images) != len(images) or {
            row.image for row in answer.images
        } != set(range(len(images))):
            raise ValueError("Unverified image indexes")
    except ModelError as exc:
        return ImageCheck(
            "nsfw_unknown",
            "图片判断未完成，保留当前 NSFW 设置：" + redact_text(exc, limit=300),
            details,
            fingerprint,
        )
    except (ValueError, KeyError):
        return ImageCheck(
            "nsfw_unknown",
            "图片判断未完成或结果无效，保留当前 NSFW 设置",
            details,
            fingerprint,
        )

    await runtime.check()
    settings, revision = await load_settings(runtime.session)
    await runtime.session.refresh(game)
    if (
        not settings.image_nsfw
        or not settings.vision
        or revision != runtime.revision
        or game.metadata_locked
        or game.nsfw_manual
        or (game.cover_path, game.bg_path, game.updated_at) != original
    ):
        return ImageCheck(
            "nsfw_skipped", "分析期间图片、设置或条目发生变化，保留最新状态", details
        )
    for image in images:
        if not image["remote"]:
            try:
                current = await asyncio.to_thread(
                    _local_bytes, image["reference"], image["directory"]
                )
            except (OSError, ValueError):
                current = b""
            if hashlib.sha256(current).hexdigest() != image["sha256"]:
                return ImageCheck(
                    "nsfw_skipped", "分析期间图片已更换，保留当前 NSFW 设置", details
                )

    for row in answer.images:
        row.reason = redact_text(row.reason, limit=240)
    details["assessment"] = answer.model_dump()
    reasons = "；".join(
        f"{images[row.image]['kind']}：{row.reason}" for row in answer.images
    )
    if any(row.nudity is True for row in answer.images):
        applied = await runtime.session.execute(
            update(Game)
            .where(
                Game.id == game.id,
                Game.is_nsfw.is_(False),
                Game.nsfw_manual.is_(False),
                Game.metadata_locked.is_(False),
                Game.updated_at == original[2],
                Game.cover_path == original[0],
                Game.bg_path == original[1],
            )
            .values(is_nsfw=True)
            .execution_options(synchronize_session="fetch")
        )
        await runtime.session.commit()
        if not applied.rowcount:
            return ImageCheck(
                "nsfw_skipped", "条目状态已变化，保留最新 NSFW 设置", details
            )
        return ImageCheck(
            "nsfw_enabled", "已自动开启 NSFW；" + reasons, details, fingerprint
        )
    if failures or any(row.nudity is None for row in answer.images):
        return ImageCheck(
            "nsfw_unknown",
            "部分图片无法确定，保留当前 NSFW 设置；" + reasons,
            details,
            fingerprint,
        )
    return ImageCheck(
        "nsfw_checked",
        "未检出明确裸露，保留当前 NSFW 设置；" + reasons,
        details,
        fingerprint,
    )

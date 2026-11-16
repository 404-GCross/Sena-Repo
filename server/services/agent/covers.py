from __future__ import annotations

import asyncio
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Literal

import httpx
from pydantic import BaseModel, ConfigDict, Field

from services.agent.images import ImagePreview, image_preview, remote_image_bytes
from services.agent.providers import ModelError
from utils.log_redaction import redact_text

COVER_POLICY_VERSION = "single-portrait-v1"
CHINESE_LANGUAGES = {
    "zh",
    "zh-cn",
    "zh-tw",
    "zh-hans",
    "zh-hant",
    "chs",
    "cht",
    "中文",
    "简体中文",
    "繁体中文",
}


class CoverAssessment(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    cover: int = Field(ge=0, strict=True)
    layout: Literal[
        "single_cover",
        "stacked",
        "collage",
        "screenshot",
        "packaging",
        "other",
        "unknown",
    ]
    language: Literal["zh", "other", "unknown"]
    reason: str = Field(min_length=1, max_length=240)


class CoverAssessments(BaseModel):
    model_config = ConfigDict(extra="forbid")
    covers: list[CoverAssessment] = Field(min_length=1, max_length=4)


@dataclass(frozen=True)
class CoverAsset:
    url: str
    data: bytes
    preview: ImagePreview


@dataclass
class CoverDecision:
    asset: CoverAsset | None = None
    reason: str = ""
    checks: list[dict] = field(default_factory=list)


class CoverChecker:
    def __init__(self, config, runtime):
        self.config = config
        self.runtime = runtime
        self.assets = OrderedDict()
        self.client = None

    async def close(self):
        if self.client is not None:
            await self.client.aclose()
        self.assets.clear()

    async def load(self, url):
        if url in self.assets:
            self.assets.move_to_end(url)
            return self.assets[url]
        if self.client is None:
            self.client = httpx.AsyncClient(
                timeout=30, proxy=self.config.proxy or None, trust_env=False
            )
        try:
            data = await asyncio.wait_for(
                remote_image_bytes(self.client, url), timeout=45
            )
            preview = await asyncio.to_thread(image_preview, data)
            asset = CoverAsset(url, data, preview)
        except (
            OSError,
            ValueError,
            SyntaxError,
            EOFError,
            httpx.HTTPError,
            asyncio.TimeoutError,
        ):
            asset = None
        if len(self.assets) >= 12:
            self.assets.popitem(last=False)
        self.assets[url] = asset
        return asset

    async def choose(self, urls, metadata, preferred=None):
        decision = CoverDecision()
        settings = self.runtime.settings
        if not settings.vision:
            decision.reason = "未开启图片分析，无法确认单张竖版封面，已保留现有封面"
            return decision
        if not urls:
            decision.reason = "来源没有封面候选，已保留现有封面"
            return decision
        order = list(range(len(urls)))
        if preferred in order:
            order.remove(preferred)
            order.insert(0, preferred)
        accepted = []
        incomplete = ""
        for start in range(0, len(order), 4):
            try:
                await self.runtime.check(model=True)
                batch = {}
                for index in order[start : start + 4]:
                    asset = await self.load(urls[index])
                    if asset is None:
                        decision.checks.append(
                            {
                                "cover": index,
                                "layout": "unknown",
                                "reason": "图片无法读取或超出分析限制",
                            }
                        )
                    elif asset.preview.height <= asset.preview.width:
                        decision.checks.append(
                            {
                                "cover": index,
                                "layout": "other",
                                "reason": "实际尺寸不是竖版",
                                "width": asset.preview.width,
                                "height": asset.preview.height,
                            }
                        )
                    else:
                        batch[index] = asset
                if not batch:
                    continue
                data = await self.runtime.reason(
                    "cover_quality",
                    {
                        "covers": [
                            {
                                "cover": index,
                                "width": asset.preview.width,
                                "height": asset.preview.height,
                            }
                            for index, asset in batch.items()
                        ]
                    },
                    CoverAssessments.model_json_schema(),
                    images=[asset.preview.uri for asset in batch.values()],
                )
                result = CoverAssessments.model_validate(data)
                if len(result.covers) != len(batch) or {
                    item.cover for item in result.covers
                } != set(batch):
                    raise ValueError("Unverified cover indexes")
                for item in result.covers:
                    asset = batch[item.cover]
                    check = item.model_dump()
                    check.update(
                        width=asset.preview.width,
                        height=asset.preview.height,
                        sha256=asset.preview.digest,
                    )
                    check["reason"] = redact_text(item.reason, limit=240)
                    decision.checks.append(check)
                    if item.layout != "single_cover":
                        continue
                    source_language = str(
                        metadata.get(asset.url, {}).get("language") or ""
                    ).lower()
                    chinese = item.language == "zh" or (
                        item.language == "unknown"
                        and source_language in CHINESE_LANGUAGES
                    )
                    rank = (
                        int(chinese) if settings.cover_language == "zh" else 0,
                        asset.preview.width * asset.preview.height
                        if settings.high_resolution
                        else 0,
                        int(item.cover == preferred),
                        -item.cover,
                    )
                    accepted.append((rank, chinese, asset))
                if accepted and (
                    settings.cover_language != "zh" or any(item[1] for item in accepted)
                ):
                    break
            except ModelError as exc:
                incomplete = redact_text(exc, limit=240)
                break
            except ValueError:
                incomplete = "模型未给出与候选对应的有效构图结论"
                break
        if accepted:
            _, chinese, asset = max(accepted, key=lambda item: item[0])
            if (
                settings.cover_language != "zh"
                or chinese
                or settings.cover_fallback == "original"
            ):
                decision.asset = asset
                return decision
            decision.reason = "没有通过校验的中文单张竖版封面，已按回退策略保留现有封面"
        else:
            decision.reason = (
                f"封面构图校验未完成：{incomplete}；已保留现有封面"
                if incomplete
                else "没有通过单张竖版构图校验的封面，已保留现有封面"
            )
        return decision

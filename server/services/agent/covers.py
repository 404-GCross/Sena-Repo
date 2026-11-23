from __future__ import annotations

import asyncio
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Literal

import httpx
from pydantic import BaseModel, ConfigDict, Field

from services.agent.images import ImagePreview, image_preview, remote_image_bytes
from services.agent.providers import ModelError
from services.scraper.base import title_search_key
from utils.log_redaction import redact_text

COVER_POLICY_VERSION = "work-edition-portrait-v2"
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
    identity: Literal["match", "mismatch", "unknown"]
    basis: Literal["visible_title", "official_asset", "none"]
    visible_title: str = Field(max_length=512)
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
    selected: int | None = None
    selection_reason: str = ""
    reason: str = ""
    checks: list[dict] = field(default_factory=list)


def _same_art(a: ImagePreview, b: ImagePreview) -> bool:
    if abs(a.width * b.height / (a.height * b.width) - 1) > 0.025:
        return False
    differences = [abs(x - y) for x, y in zip(a.thumbnail, b.thumbnail)]
    return max(differences) <= 28 and sum(differences) <= 4 * len(differences)


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

    async def choose(self, urls, metadata, preferred=None, *, target):
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
        titles = (
            {title_search_key(t) for t in target["titles"]}
            - {title_search_key(t) for t in target["ambiguous_titles"]}
            - {""}
        )
        official_urls = {
            url
            for url in urls
            if target["source_id"]
            and metadata.get(url, {}).get("official_work_id") == target["source_id"]
        }
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
                        "target": target,
                        "covers": [
                            {
                                "cover": index,
                                "width": asset.preview.width,
                                "height": asset.preview.height,
                                "official_for_target": asset.url in official_urls,
                            }
                            for index, asset in batch.items()
                        ],
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
                    check = item.model_dump(exclude={"visible_title"})
                    check.update(
                        width=asset.preview.width,
                        height=asset.preview.height,
                        sha256=asset.preview.digest,
                    )
                    check["reason"] = redact_text(item.reason, limit=240)
                    decision.checks.append(check)
                    verified = item.identity == "match" and (
                        (
                            item.basis == "visible_title"
                            and title_search_key(item.visible_title) in titles
                        )
                        or (
                            item.basis == "official_asset"
                            and asset.url in official_urls
                        )
                    )
                    check["identity_verified"] = verified
                    if item.layout != "single_cover" or not verified:
                        continue
                    source_language = str(
                        metadata.get(asset.url, {}).get("language") or ""
                    ).lower()
                    chinese = item.language == "zh" or (
                        item.language == "unknown"
                        and source_language in CHINESE_LANGUAGES
                    )
                    accepted.append((item.cover, chinese, asset))
                if (
                    accepted
                    and not settings.high_resolution
                    and (
                        settings.cover_language != "zh"
                        or any(row[1] for row in accepted)
                    )
                ):
                    break
            except ModelError as exc:
                incomplete = redact_text(exc, limit=240)
                break
            except ValueError:
                incomplete = "模型未给出与候选对应的有效归属和构图结论"
                break
        if accepted:
            if settings.cover_language == "zh":
                chinese = [row for row in accepted if row[1]]
                if chinese:
                    accepted = chinese
                elif settings.cover_fallback != "original":
                    decision.reason = (
                        "没有通过校验的中文单张竖版封面，已按回退策略保留现有封面"
                    )
                    return decision
            index, _, asset = min(
                accepted, key=lambda row: (row[0] != preferred, row[0])
            )
            why = (
                "采用已核实作品与版本的推荐封面"
                if index == preferred
                else "采用符合语言策略且已核实作品与版本的来源封面"
            )
            if settings.high_resolution:
                variants = [
                    row for row in accepted if _same_art(asset.preview, row[2].preview)
                ]
                larger = max(
                    variants,
                    key=lambda row: row[2].preview.width * row[2].preview.height,
                )
                if (
                    larger[2].preview.width * larger[2].preview.height
                    > asset.preview.width * asset.preview.height
                ):
                    index, _, asset = larger
                    why += "的同图高清版本"
            decision.selected, decision.asset, decision.selection_reason = (
                index,
                asset,
                why,
            )
        else:
            decision.reason = (
                f"封面构图校验未完成：{incomplete}；已保留现有封面"
                if incomplete
                else "没有可确认属于本作品和版本的单张竖版正封面，已保留现有封面待复核"
            )
        return decision

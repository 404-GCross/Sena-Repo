from __future__ import annotations

import asyncio
import re
import unicodedata
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Annotated, Literal

import httpx
from pydantic import BaseModel, ConfigDict, Field

from services.agent.images import ImagePreview, image_preview, remote_image_bytes
from services.agent.providers import ModelError
from services.scraper.base import title_search_key
from utils.log_redaction import redact_text

COVER_POLICY_VERSION = "work-edition-cover-v3"
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
    subtitle: str = Field(default="", max_length=256)
    edition: str = Field(default="", max_length=128)
    other_titles: list[Annotated[str, Field(min_length=1, max_length=512)]] = Field(default_factory=list, max_length=4)
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
    priority: int = 4
    source: str = ""
    source_id: str = ""


def _title_keys(title: str) -> set[str]:
    keys = {title_search_key(title)} - {""}
    text = unicodedata.normalize("NFKC", title)
    # D.C. II ~Da Capo II~ repeats the initials and numeral, not an edition subtitle.
    match = re.search(
        r"\b(?P<initials>(?:[a-z]\.){2,})\s*(?P<number>[ivx]+|[0-9]+)?\s*"
        r"[~〜](?P<words>[a-z ]+?)(?P<repeat>[ivx]+|[0-9]+)?[~〜]", text, re.I,
    )
    if match:
        initials = "".join(word[0] for word in match["words"].split())
        number = match["number"] or ""
        if (title_search_key(match["initials"]) == initials.casefold()
                and number.casefold() == (match["repeat"] or "").casefold()):
            short = text[:match.start()] + match["initials"] + number + text[match.end():]
            keys.add(title_search_key(short))
    return keys


def _match_printed_title(text, aliases, ambiguous):
    key = title_search_key(text)
    if key in ambiguous:
        return []
    if key in aliases:
        return [aliases[key]]
    # Older models sometimes transcribe an entire bilingual logo in a single field.
    for first, alias in aliases.items():
        if key.startswith(first):
            second = key[len(first):]
            if (second in aliases and first.isascii() != second.isascii()
                    and any(c.isalpha() for c in first) and any(c.isalpha() for c in second)):
                return [alias, aliases[second]]
    return []


def _identity_check(item, aliases, ambiguous, official):
    printed = [" ".join(filter(None, (item.visible_title, item.subtitle, item.edition))), *item.other_titles]
    matches = [_match_printed_title(text, aliases, ambiguous) for text in printed]
    if item.basis == "official_asset":
        has_evidence = official and (not any(t.strip() for t in printed) or all(matches))
    else:
        has_evidence = item.basis == "visible_title" and all(matches)
    verified = item.identity == "match" and has_evidence
    check = item.model_dump(include={"layout", "language", "identity", "basis"})
    check.update(
        reason=redact_text(item.reason, limit=240),
        printed_titles=[redact_text(re.sub(r"https?://\S+", "[链接]", t, flags=re.I), limit=512) for t in printed if t],
        matched_titles=[redact_text(t, limit=512) for group in matches for t in group],
        identity_verified=verified,
    )
    if item.layout != "single_cover":
        check["rejection"] = "不是完整单张正封面"
    elif item.identity != "match":
        check["rejection"] = "作品或版本不符" if item.identity == "mismatch" else "作品或版本归属不明"
    elif not verified:
        check["rejection"] = "图上完整标题未匹配到无歧义的作品和版本别名" if item.basis == "visible_title" else "缺少可信的版本绑定"
    return check


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

    async def _assess_batch(self, batch, target, official_urls, assessments):
        keys = {i: (asset.preview.digest, asset.url in official_urls) for i, asset in batch.items()}
        pending = {}
        for i, key in keys.items():
            if key not in assessments:
                pending.setdefault(key, i)
        if pending:
            indexes = list(pending.values())
            data = await self.runtime.reason(
                "cover_quality",
                {"target": target, "covers": [
                    {"cover": i, "width": batch[i].preview.width, "height": batch[i].preview.height,
                     "official_for_target": batch[i].url in official_urls} for i in indexes
                ]},
                CoverAssessments.model_json_schema(),
                images=[batch[i].preview.uri for i in indexes],
            )
            result = CoverAssessments.model_validate(data)
            if len(result.covers) != len(indexes) or {item.cover for item in result.covers} != set(indexes):
                raise ValueError("Unverified cover indexes")
            assessments.update((keys[item.cover], item) for item in result.covers)
        return {i: assessments[key] for i, key in keys.items()}

    async def choose(self, urls, metadata, preferred=None, *, target, assessments=None):
        decision = CoverDecision()
        settings = self.runtime.settings
        if not settings.vision:
            decision.reason = "未开启图片分析，无法确认单张正封面，已保留现有封面"
            return decision
        if not urls:
            decision.reason = "来源没有封面候选，已保留现有封面"
            return decision
        order = list(range(len(urls)))
        if preferred in order:
            order.remove(preferred)
            order.insert(0, preferred)
        accepted = []
        ambiguous = {key for title in target["ambiguous_titles"] for key in _title_keys(title)}
        aliases = {key: title for title in target["titles"] for key in _title_keys(title) if key not in ambiguous}
        if assessments is None:
            assessments = {}
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
                    elif asset.preview.height == asset.preview.width:
                        decision.checks.append(
                            {
                                "cover": index,
                                "layout": "other",
                                "reason": "正方形图片，不是竖版或横版封面",
                                "width": asset.preview.width,
                                "height": asset.preview.height,
                            }
                        )
                    else:
                        batch[index] = asset
                if not batch:
                    continue
                verdicts = await self._assess_batch(batch, target, official_urls, assessments)
                for index, item in verdicts.items():
                    asset = batch[index]
                    check = _identity_check(item, aliases, ambiguous, asset.url in official_urls)
                    check.update(
                        cover=index,
                        width=asset.preview.width,
                        height=asset.preview.height,
                        sha256=asset.preview.digest,
                    )
                    decision.checks.append(check)
                    if "rejection" in check:
                        continue
                    source_language = str(
                        metadata.get(asset.url, {}).get("language") or ""
                    ).lower()
                    chinese = item.language == "zh" or (
                        item.language == "unknown"
                        and source_language in CHINESE_LANGUAGES
                    )
                    if settings.cover_language == "zh" and not chinese and settings.cover_fallback != "original":
                        check["rejection"] = "语言策略不允许非中文封面回退"
                        continue
                    rank = 2 if asset.preview.width > asset.preview.height else 0
                    if settings.cover_language == "zh" and not chinese:
                        rank += 1
                    accepted.append((index, rank, asset))
                if (
                    accepted
                    and not settings.high_resolution
                    and any(row[1] == 0 for row in accepted)
                ):
                    break
            except ModelError as exc:
                incomplete = redact_text(exc, limit=240)
                break
            except ValueError:
                incomplete = "模型未给出与候选对应的有效归属和构图结论"
                break
        if accepted:
            decision.priority = min(row[1] for row in accepted)
            accepted = [row for row in accepted if row[1] == decision.priority]
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
            if asset.preview.width > asset.preview.height:
                decision.selection_reason += "（横版回退）"
        else:
            decision.reason = (
                f"封面构图校验未完成：{incomplete}；已保留现有封面"
                if incomplete
                else "没有符合语言策略且可核实作品和版本的单张正封面，已保留现有封面待复核"
            )
        return decision

from __future__ import annotations

import asyncio
import io
import logging
from collections.abc import Iterable
from dataclasses import dataclass, field

import httpx
from PIL import Image

from services.agent.images import MAX_IMAGE_PIXELS, remote_image_bytes
from services.scraper.base import ScraperResult
from services.scraper.orchestrator import _save_verified_image
from services.task_stop import checkpoint, stoppable_request

logger = logging.getLogger(__name__)


@dataclass
class AgentBackgroundPolicy:
    preference: str
    overwrite: bool = False
    selected: ScraperResult | None = None
    attempted: set[str] = field(default_factory=set, init=False, repr=False)
    saved: bool = field(default=False, init=False)

    async def apply(self, results, game, client, session, config):
        if self.saved or game.metadata_locked or (game.bg_path and not self.overwrite) or config is None:
            return
        saved_ids = {
            key: str(getattr(game, f"{key}_id") or "").strip().lower()
            for key in ("steam", "vndb", "nextmoe", "bangumi", "hikarinagi")
        }
        saved_ids["vndb"] = saved_ids["vndb"].removeprefix("v")
        saved_ids = {key: val for key, val in saved_ids.items() if val}
        urls = ranked_backgrounds(self.preference, results, selected=self.selected, saved_ids=saved_ids)
        for url in urls:
            checkpoint()
            if url in self.attempted:
                continue
            self.attempted.add(url)
            try:
                data = await stoppable_request(asyncio.wait_for(remote_image_bytes(client, url), timeout=45))
                await asyncio.to_thread(_verify_background, data)
            except (OSError, httpx.HTTPError, asyncio.TimeoutError, ValueError, SyntaxError, Image.DecompressionBombError):
                continue
            await session.refresh(game, attribute_names=["metadata_locked", "bg_path"])
            if game.metadata_locked or (game.bg_path and not self.overwrite):
                return
            path = config.backgrounds_path / f"{game.id}_hero.jpg"
            try:
                await asyncio.to_thread(_save_verified_image, path, data)
            except OSError:
                logger.warning('Failed to save agent background for game %s', game.id)
                return
            game.bg_path = str(path)
            self.saved = True
            session.add(game)
            logger.info('Saved agent background for game %s (preference=%s)', game.id, self.preference)
            return
        if urls:
            logger.info('No usable agent background for game %s', game.id)


def _verify_background(data: bytes) -> None:
    with Image.open(io.BytesIO(data)) as image:
        if image.width * image.height > MAX_IMAGE_PIXELS or getattr(image, 'is_animated', False):
            raise ValueError('Unsupported background image')
        image.load()


def _work_ids(result: ScraperResult) -> dict[str, str]:
    ids = {}
    for source, value in {**result.external_ids, result.source_name: result.source_id}.items():
        if not source or not value:
            continue
        key = 'vndb' if source == 'vndb_kana' else source
        ident = str(value).strip().lower()
        ids[key] = ident.removeprefix('v') if key == 'vndb' else ident
    return ids


def ranked_backgrounds(
    preference: str, results: Iterable[ScraperResult], *, selected: ScraperResult | None = None,
    saved_ids: dict[str, str] | None = None,
) -> list[str]:
    groups: dict[str, dict[str, None]] = {'artwork': {}, 'screenshot': {}}
    selected_ids = _work_ids(selected) if selected is not None else {}
    if saved_ids and any(selected_ids[k] != saved_ids[k] for k in saved_ids.keys() & selected_ids.keys()):
        return []
    for result in results:
        ids = _work_ids(result)
        if saved_ids and any(ids[k] != saved_ids[k] for k in saved_ids.keys() & ids.keys()):
            continue
        if selected is None and (result.background_media or result.screenshot_urls):
            selected, selected_ids = result, ids
        if selected is not None and result is not selected:
            shared = selected_ids.keys() & ids.keys()
            linked_by_game = saved_ids and not selected_ids.keys().isdisjoint(saved_ids) and not ids.keys().isdisjoint(saved_ids)
            if (not shared and not linked_by_game) or any(ids[key] != selected_ids[key] for key in shared):
                continue
        for kind, url in result.background_media:
            if isinstance(url, str) and url:
                groups[kind][url] = None
        for url in result.screenshot_urls:
            if url:
                groups['screenshot'][url] = None

    # A source may also use its first screenshot as its banner.
    for url in groups['screenshot']:
        groups['artwork'].pop(url, None)
    other = 'artwork' if preference == 'screenshot' else 'screenshot'
    return [*groups[preference], *groups[other]]

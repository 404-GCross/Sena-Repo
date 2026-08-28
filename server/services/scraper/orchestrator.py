"""Batch scrape orchestrator — runs multiple scrapers against games."""

from __future__ import annotations

import logging
import asyncio
import ipaddress
import socket
from datetime import datetime
from pathlib import Path
from urllib.parse import urljoin, urlparse

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from config import Config, normalize_scraper_config
from models.game import Game, GameTag
from models.scrape_job import JobStatus, ScrapeJob
from models.tag import Tag

from .base import BaseScraper, ScrapedTag, ScraperResult, clean_title
from .vndb_kana import VndbKanaScraper, VndbTitlesScraper
from .bangumi import BangumiScraper
from .steam import SteamScraper
from .hikarinagi import HikarinagiScraper
from services.hikarinagi_oauth import get_default_access_token

logger = logging.getLogger(__name__)

_SCRAPER_SEARCH_TIMEOUT = 45
_GAME_SCRAPE_TIMEOUT = 300

_VALID_SOURCES = {"vndb_kana", "vndb", "bangumi", "steam", "hikarinagi"}
# Average playtime is intentionally sourced from VNDB only.
_PLAYTIME_SOURCES = {"vndb_kana", "vndb"}


def _is_public_http_url(url: str) -> bool:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        return False
    try:
        ip = ipaddress.ip_address(parsed.hostname)
        return not (ip.is_loopback or ip.is_private or ip.is_link_local)
    except ValueError:
        pass
    try:
        addrs = socket.getaddrinfo(parsed.hostname, None)
    except OSError:
        return False
    for addr in addrs:
        try:
            ip = ipaddress.ip_address(addr[4][0])
        except ValueError:
            return False
        if ip.is_loopback or ip.is_private or ip.is_link_local:
            return False
    return True


def _build_scrapers(config: Config) -> list[BaseScraper]:
    """Build enabled scrapers in the configured priority order."""
    s = config.scrapers
    normalize_scraper_config(s)
    builders = {
        "hikarinagi": lambda: HikarinagiScraper(
            proxy=config.proxy,
            access_token_provider=get_default_access_token,
        ),
        "vndb_kana": lambda: VndbKanaScraper(proxy=config.proxy),
        "bangumi": lambda: BangumiScraper(proxy=config.proxy, token=s.bangumi_token),
        "steam": lambda: SteamScraper(proxy=config.proxy),
    }
    scrapers: list[BaseScraper] = []
    for source in s.scraper_order:
        if source not in s.enabled_scrapers:
            continue
        scraper = builders[source]()
        scrapers.append(scraper)
        # Keep the legacy VNDB parser as a fallback within the VNDB slot.
        if source == "vndb_kana":
            scrapers.append(VndbTitlesScraper(proxy=config.proxy))
    return scrapers


async def _download_cover(
    client: httpx.AsyncClient,
    url: str,
    dest_path: Path,
) -> bool:
    """Download a cover image to the specified path."""
    try:
        current = url
        for _ in range(6):
            if not _is_public_http_url(current):
                logger.warning(f"Skipping non-public image URL: {current}")
                return False
            resp = await client.get(current, timeout=30.0, follow_redirects=False)
            if resp.status_code not in {301, 302, 303, 307, 308}:
                break
            location = resp.headers.get("location")
            if not location:
                break
            current = urljoin(current, location)
        else:
            logger.warning(f"Too many image redirects: {url}")
            return False
        resp.raise_for_status()
        dest_path.parent.mkdir(parents=True, exist_ok=True)
        with open(dest_path, "wb") as f:
            f.write(resp.content)
        return True
    except Exception as e:
        logger.warning(f"Cover download failed for {url}: {e}")
        return False


async def scrape_single_game(
    game: Game,
    scrapers: list[BaseScraper],
    client: httpx.AsyncClient,
    covers_dir: Path,
    session: AsyncSession,
    config: "Config | None" = None,
    mode: str = "missing",
) -> dict:
    """Scrape a single game across all available sources.

    Returns:
        Dict with {source_name: ScraperResult or None}
    """
    company_hint = game.company.name if game.company else None
    results = {}

    async def handle_result(scraper: BaseScraper, result: ScraperResult) -> None:
        results[scraper.source_name] = result

    async def search_best(
        scraper: BaseScraper,
        query: str,
        context: str,
    ) -> ScraperResult | None:
        try:
            return await asyncio.wait_for(
                scraper.search_best(query, company_hint),
                timeout=_SCRAPER_SEARCH_TIMEOUT,
            )
        except asyncio.TimeoutError:
            logger.warning(
                "Scraper %s timed out after %ss for %s '%s'",
                scraper.source_name,
                _SCRAPER_SEARCH_TIMEOUT,
                context,
                query,
            )
            return None

    # ── Build search candidates (best → worst) ──
    candidates: list[str] = []
    raw_name = game.name

    # Extract folder name for additional candidate
    folder_name = ""
    try:
        folder_name = Path(game.folder_path).name
    except Exception:
        pass

    candidates.append(clean_title(raw_name))
    if folder_name and clean_title(folder_name) not in candidates:
        candidates.append(clean_title(folder_name))
    for c in list(candidates):
        if c and c != raw_name and raw_name not in candidates:
            candidates.append(raw_name)
    candidates = [c for c in candidates if c]

    # Prefer an explicitly saved VNDB ID for VNDB scrapers only.
    if game.vndb_id:
        for scraper in scrapers:
            if scraper.source_name not in {"vndb_kana", "vndb"}:
                continue
            try:
                result = await search_best(scraper, game.vndb_id, "VNDB ID")
                if result:
                    await handle_result(scraper, result)
            except Exception as e:
                logger.error(f"Scraper {scraper.source_name} error for VNDB ID '{game.vndb_id}': {e}")

    # Prefer an explicitly saved Bangumi ID for the Bangumi scraper only.
    if game.bangumi_id:
        for scraper in scrapers:
            if scraper.source_name != "bangumi":
                continue
            try:
                result = await search_best(scraper, game.bangumi_id, "Bangumi ID")
                if result:
                    await handle_result(scraper, result)
            except Exception as e:
                logger.error(f"Scraper {scraper.source_name} error for Bangumi ID '{game.bangumi_id}': {e}")

    # Prefer an explicitly saved Hikarinagi ID for the Hikarinagi scraper only.
    if game.hikarinagi_id:
        for scraper in scrapers:
            if scraper.source_name != "hikarinagi":
                continue
            try:
                result = await search_best(
                    scraper,
                    game.hikarinagi_id,
                    "Hikarinagi ID",
                )
                if result:
                    await handle_result(scraper, result)
            except Exception as e:
                logger.error(
                    f"Scraper {scraper.source_name} error for Hikarinagi ID '{game.hikarinagi_id}': {e}"
                )

    # ── Standard search: try candidates × scrapers ──
    for query in candidates:
        for scraper in scrapers:
            if scraper.source_name in results:
                continue
            try:
                result = await search_best(scraper, query, "query")
                if result:
                    await handle_result(scraper, result)
            except Exception as e:
                logger.error(f"Scraper {scraper.source_name} error for '{query}': {e}")

    ordered_results = [
        (scraper.source_name, results[scraper.source_name])
        for scraper in scrapers
        if scraper.source_name in results
    ]
    if mode in {"overwrite", "images"}:
        ordered_results.reverse()
    for source_name, result in ordered_results:
        await _apply_result(
            result, source_name, game, client, covers_dir, session, config, mode
        )

    await session.commit()
    return results


async def _apply_result(
    result: ScraperResult,
    source_name: str,
    game: Game,
    client: httpx.AsyncClient,
    covers_dir: Path,
    session: AsyncSession,
    config: "Config | None" = None,
    mode: str = "missing",
):
    """Apply a scraper result to a game, respecting the scrape mode."""
    overwrite = mode == "overwrite"
    images_only = mode == "images"
    metadata_only = mode == "metadata"

    # ── Images ──
    if not metadata_only:
        # Cover
        if result.cover_url and (overwrite or images_only or not game.cover_path):
            ext = ".jpg"
            cover_path = covers_dir / f"{game.id}_{source_name}{ext}"
            success = await _download_cover(client, result.cover_url, cover_path)
            if success:
                game.cover_path = str(cover_path)
                session.add(game)
        # Hero/landscape
        if result.hero_url and config is not None and (overwrite or images_only or not game.bg_path):
            logger.info(f"Downloading hero for game {game.id}: {result.hero_url}")
            bg_dir = config.backgrounds_path
            bg_dir.mkdir(parents=True, exist_ok=True)
            bg_path = bg_dir / f"{game.id}_hero.jpg"
            success = await _download_cover(client, result.hero_url, bg_path)
            if success:
                game.bg_path = str(bg_path)
                session.add(game)
            else:
                logger.warning(f"Hero download failed for game {game.id}")
        elif result.hero_url and config is not None and game.bg_path:
            logger.debug(f"Hero skipped for game {game.id}: already has bg_path ({game.bg_path})")

    # ── Text metadata ──
    if result.is_nsfw is True and not game.is_nsfw:
        game.is_nsfw = True
        session.add(game)

    if not images_only:
        if result.developer and (overwrite or not game.developer):
            game.developer = result.developer
            session.add(game)
        if result.description and (overwrite or not game.description):
            game.description = result.description[:2000]
            session.add(game)
        if result.release_date and (overwrite or not game.release_date):
            game.release_date = result.release_date
            session.add(game)
        if source_name in _PLAYTIME_SOURCES and result.length and (
            overwrite or not game.length
        ):
            game.length = result.length
            session.add(game)
        if source_name in _PLAYTIME_SOURCES and result.length_minutes and (
            overwrite or not game.length_minutes
        ):
            game.length_minutes = result.length_minutes
            session.add(game)
        # Source ID — map scraper to game ID column
        _id_map = {
            "vndb_kana": "vndb_id",
            "vndb": "vndb_id",
            "steam": "steam_id",
            "bangumi": "bangumi_id",
            "hikarinagi": "hikarinagi_id",
        }
        col = _id_map.get(source_name)
        if col and result.source_id and (overwrite or not getattr(game, col, None)):
            setattr(game, col, result.source_id)
            session.add(game)
        if result.tags:
            await _apply_scraped_tags(
                session,
                game,
                source_name,
                result.tags,
                overwrite=overwrite,
            )


async def _apply_scraped_tags(
    session: AsyncSession,
    game: Game,
    source_name: str,
    tags: list[ScrapedTag],
    *,
    overwrite: bool,
) -> None:
    for scraped in tags:
        name = scraped.name.strip()
        if not name:
            continue

        result = await session.execute(select(Tag).where(Tag.name == name))
        tag = result.scalar_one_or_none()
        if tag is None:
            tag = Tag(name=name)
            session.add(tag)
            await session.flush()

        assoc_result = await session.execute(
            select(GameTag).where(
                GameTag.game_id == game.id,
                GameTag.tag_id == tag.id,
            )
        )
        assoc = assoc_result.scalar_one_or_none()
        if assoc is None:
            session.add(
                GameTag(
                    game_id=game.id,
                    tag_id=tag.id,
                    source=source_name,
                    weight=scraped.rating,
                    is_spoiler=scraped.is_spoiler,
                )
            )
            continue

        if overwrite or (assoc.source or "") != "user":
            assoc.source = source_name
        if overwrite or scraped.rating > (assoc.weight or 0.0):
            assoc.weight = scraped.rating
        assoc.is_spoiler = bool(assoc.is_spoiler) or scraped.is_spoiler
        session.add(assoc)


async def run_batch_scrape(
    config: Config,
    game_ids: list[int] | None,
    session: AsyncSession,
    job: ScrapeJob,
    sources: list[str] | None = None,
    mode: str = "missing",
) -> dict:
    """Run batch scraping for specified games (or all without covers).

    Args:
        config: Application config.
        game_ids: Specific game IDs to scrape, or None for all missing covers.
        session: Database session.
        job: ScrapeJob record for progress tracking.

    Returns:
        Dict with stats: {total, completed, failed}
    """
    # Re-attach job to this session (it may come from a different session)
    job = await session.merge(job)

    # Get games to scrape
    if game_ids:
        result = await session.execute(
            select(Game).options(selectinload(Game.company))
            .where(Game.id.in_(game_ids), Game.is_deleted == False)
        )
    elif mode in ("overwrite", "images"):
        # overwrite/images mode: scrape ALL games (not just missing covers)
        result = await session.execute(
            select(Game).options(selectinload(Game.company))
            .where(Game.is_deleted == False)
            .order_by(Game.imported_at.desc())
        )
    elif mode == "metadata":
        from sqlalchemy import or_
        # metadata mode: games missing text fields (but may have covers)
        result = await session.execute(
            select(Game).options(selectinload(Game.company))
            .where(
                Game.is_deleted == False,
                or_(
                    Game.description == None, Game.description == "",
                    Game.developer == None, Game.developer == "",
                ),
            ).order_by(Game.imported_at.desc())
        )
    else:
        # missing mode: only games without covers
        result = await session.execute(
            select(Game).options(selectinload(Game.company))
            .where(
                Game.is_deleted == False,
                Game.cover_path == None,
            ).order_by(Game.imported_at.desc())
        )

    games = result.scalars().all()

    if not games:
        job.status = JobStatus.COMPLETED
        job.log = "No games to scrape."
        await session.commit()
        return {"total": 0, "completed": 0, "failed": 0}

    job.total_games = len(games)
    job.status = JobStatus.RUNNING
    job.started_at = datetime.utcnow()
    await session.commit()

    scrapers = _build_scrapers(config)
    if sources:
        source_set = {str(source) for source in sources if str(source) in _VALID_SOURCES}
        if "vndb_kana" in source_set:
            source_set.add("vndb")
        scrapers = [s for s in scrapers if s.source_name in source_set]
    covers_dir = config.covers_path
    completed = 0
    failed = 0

    client_kwargs = {"timeout": httpx.Timeout(30.0)}
    if config.proxy:
        client_kwargs["proxy"] = config.proxy
    async with httpx.AsyncClient(**client_kwargs) as client:
        for i, game in enumerate(games):
            await session.refresh(job)
            if job.status == JobStatus.FAILED:
                job.current_game = None
                job.log = (job.log or "") + " 已停止。"
                await session.commit()
                break

            job.current_game = game.name
            job.completed_games = i
            await session.commit()

            try:
                results = await asyncio.wait_for(
                    scrape_single_game(
                        game,
                        scrapers,
                        client,
                        covers_dir,
                        session,
                        config,
                        mode=mode,
                    ),
                    timeout=_GAME_SCRAPE_TIMEOUT,
                )
                if any(results.values()):
                    completed += 1
                else:
                    failed += 1
            except asyncio.TimeoutError:
                logger.error(
                    "Failed to scrape game %s: timed out after %ss",
                    game.name,
                    _GAME_SCRAPE_TIMEOUT,
                )
                await session.rollback()
                job = await session.merge(job)
                failed += 1
            except Exception as e:
                logger.error(f"Failed to scrape game {game.name}: {e}")
                await session.rollback()
                job = await session.merge(job)
                failed += 1

    await session.refresh(job)
    if job.status != JobStatus.FAILED:
        job.status = JobStatus.COMPLETED
        job.log = f"Completed: {completed}, Failed: {failed}"
    else:
        job.log = (job.log or "") + f" 停止前完成: {completed}, 失败: {failed}"
    job.completed_games = completed
    job.failed_games = failed
    job.current_game = None
    await session.commit()

    # Clean up scrapers
    for scraper in scrapers:
        await scraper.close()

    return {"total": len(games), "completed": completed, "failed": failed}

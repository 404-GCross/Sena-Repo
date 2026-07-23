"""Batch scrape orchestrator — runs multiple scrapers against games."""

from __future__ import annotations

import logging
import ipaddress
import json
import socket
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from config import Config
from models.game import Game
from models.scrape_job import JobStatus, ScrapeJob

from .base import BaseScraper, ScraperResult, clean_title
from .vndb_kana import VndbKanaScraper, VndbTitlesScraper
from .bangumi import BangumiScraper
from .steam import SteamScraper
from .ymgal import YmgalScraper

logger = logging.getLogger(__name__)

_VALID_SOURCES = {"vndb_kana", "vndb", "bangumi", "steam", "ymgal"}
_VALID_FIELD_MAP = {
    "title": "title",
    "name": "title",
    "cover": "cover",
    "cover_url": "cover",
    "background": "background",
    "hero": "background",
    "hero_url": "background",
    "description": "description",
    "release_date": "release_date",
    "developer": "developer",
    "length": "length",
    "length_minutes": "length_minutes",
}


def _normalize_field_sources(
    field_sources: dict[str, list[str]] | None,
) -> dict[str, list[str]]:
    normalized: dict[str, list[str]] = {}
    for raw_field, raw_sources in (field_sources or {}).items():
        field = _VALID_FIELD_MAP.get(str(raw_field))
        if not field or not isinstance(raw_sources, list):
            continue
        sources: list[str] = []
        for raw_source in raw_sources:
            source = str(raw_source)
            if source in _VALID_SOURCES and source not in sources:
                sources.append(source)
        if sources:
            normalized[field] = sources
    return normalized


def _load_default_field_sources(config: Config) -> dict[str, list[str]]:
    path = Path(config.data_path) / "scraper_config.json"
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return _normalize_field_sources(data.get("batch_field_sources"))


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
    """Build all available scrapers from config."""
    s = config.scrapers

    scrapers: list[BaseScraper] = [
        VndbKanaScraper(proxy=config.proxy),
        VndbTitlesScraper(proxy=config.proxy),
        BangumiScraper(proxy=config.proxy, token=s.bangumi_token),
        SteamScraper(proxy=config.proxy),
        YmgalScraper(proxy=config.proxy, client_id=s.ymgal_client_id, client_secret=s.ymgal_client_secret),
    ]

    return scrapers


async def _download_cover(
    client: httpx.AsyncClient,
    url: str,
    dest_path: Path,
) -> bool:
    """Download a cover image to the specified path."""
    if not _is_public_http_url(url):
        logger.warning(f"Skipping non-public image URL: {url}")
        return False
    try:
        resp = await client.get(url, timeout=30.0)
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
    field_sources: dict[str, list[str]] | None = None,
) -> dict:
    """Scrape a single game across all available sources.

    Returns:
        Dict with {source_name: ScraperResult or None}
    """
    company_hint = game.company.name if game.company else None
    results = {}
    field_sources = _normalize_field_sources(field_sources)
    collect_only = bool(field_sources)

    async def handle_result(scraper: BaseScraper, result: ScraperResult) -> None:
        results[scraper.source_name] = result
        if not collect_only:
            await _apply_result(
                result, scraper.source_name, game, client, covers_dir, session, config, mode
            )

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
                result = await scraper.search_best(game.vndb_id, company_hint)
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
                result = await scraper.search_best(game.bangumi_id, company_hint)
                if result:
                    await handle_result(scraper, result)
            except Exception as e:
                logger.error(f"Scraper {scraper.source_name} error for Bangumi ID '{game.bangumi_id}': {e}")

    # ── Standard search: try candidates × scrapers ──
    for query in candidates:
        for scraper in scrapers:
            if scraper.source_name in results:
                continue
            try:
                result = await scraper.search_best(query, company_hint)
                if result:
                    await handle_result(scraper, result)
                    break  # Found for this candidate, try next candidate for remaining scrapers
            except Exception as e:
                logger.error(f"Scraper {scraper.source_name} error for '{query}': {e}")

    if field_sources:
        await _apply_field_sources(results, field_sources, game, client, covers_dir, session, config, mode)
        unmapped_fields = {
            "cover",
            "background",
            "developer",
            "description",
            "release_date",
            "length",
            "length_minutes",
            "source_id",
        } - set(field_sources.keys())
        if unmapped_fields:
            for source_name, result in results.items():
                await _apply_result(
                    result,
                    source_name,
                    game,
                    client,
                    covers_dir,
                    session,
                    config,
                    mode,
                    field_filter=unmapped_fields,
                )

    await session.commit()
    return results


async def _apply_field_sources(
    results: dict[str, ScraperResult],
    field_sources: dict[str, list[str]],
    game: Game,
    client: httpx.AsyncClient,
    covers_dir: Path,
    session: AsyncSession,
    config: "Config | None",
    mode: str,
) -> None:
    overwrite = mode == "overwrite"
    images_only = mode == "images"
    metadata_only = mode == "metadata"

    def pick(field: str) -> tuple[str, ScraperResult] | tuple[None, None]:
        for source in field_sources.get(field, []):
            result = results.get(source)
            if result is None:
                continue
            value = getattr(result, {
                "cover": "cover_url",
                "background": "hero_url",
            }.get(field, field), None)
            if value:
                return source, result
        return None, None

    applied_sources: set[str] = set()

    if not metadata_only:
        source, result = pick("cover")
        if result and result.cover_url and (overwrite or images_only or not game.cover_path):
            cover_path = covers_dir / f"{game.id}_{source}.jpg"
            if await _download_cover(client, result.cover_url, cover_path):
                game.cover_path = str(cover_path)
                applied_sources.add(source)
                session.add(game)

        source, result = pick("background")
        if (
            result
            and config is not None
            and result.hero_url
            and (overwrite or images_only or not game.bg_path)
        ):
            bg_dir = config.backgrounds_path
            bg_dir.mkdir(parents=True, exist_ok=True)
            bg_path = bg_dir / f"{game.id}_hero.jpg"
            if await _download_cover(client, result.hero_url, bg_path):
                game.bg_path = str(bg_path)
                applied_sources.add(source)
                session.add(game)

    if not images_only:
        source, result = pick("title")
        if result and result.title and (overwrite or not game.name):
            game.name = result.title[:512]
            applied_sources.add(source)
            session.add(game)

        source, result = pick("developer")
        if result and result.developer and (overwrite or not game.developer):
            game.developer = result.developer
            applied_sources.add(source)
            session.add(game)

        source, result = pick("description")
        if result and result.description and (overwrite or not game.description):
            game.description = result.description[:2000]
            applied_sources.add(source)
            session.add(game)

        source, result = pick("release_date")
        if result and result.release_date and (overwrite or not game.release_date):
            game.release_date = result.release_date
            applied_sources.add(source)
            session.add(game)

        source, result = pick("length")
        if result and result.length and (overwrite or not game.length):
            game.length = result.length
            applied_sources.add(source)
            session.add(game)

        source, result = pick("length_minutes")
        if result and result.length_minutes and (overwrite or not game.length_minutes):
            game.length_minutes = result.length_minutes
            applied_sources.add(source)
            session.add(game)

    _id_map = {
        "vndb_kana": "vndb_id",
        "vndb": "vndb_id",
        "steam": "steam_id",
        "bangumi": "bangumi_id",
    }
    for source in applied_sources:
        result = results.get(source)
        col = _id_map.get(source)
        if col and result and result.source_id and (overwrite or not getattr(game, col, None)):
            setattr(game, col, result.source_id)
            session.add(game)


async def _apply_result(
    result: ScraperResult,
    source_name: str,
    game: Game,
    client: httpx.AsyncClient,
    covers_dir: Path,
    session: AsyncSession,
    config: "Config | None" = None,
    mode: str = "missing",
    field_filter: set[str] | None = None,
):
    """Apply a scraper result to a game, respecting the scrape mode."""
    overwrite = mode == "overwrite"
    images_only = mode == "images"
    metadata_only = mode == "metadata"

    def allow(field: str) -> bool:
        return field_filter is None or field in field_filter

    # ── Images ──
    if not metadata_only:
        # Cover
        if allow("cover") and result.cover_url and (overwrite or images_only or not game.cover_path):
            ext = ".jpg"
            cover_path = covers_dir / f"{game.id}_{source_name}{ext}"
            success = await _download_cover(client, result.cover_url, cover_path)
            if success:
                game.cover_path = str(cover_path)
                session.add(game)
        # Hero/landscape
        if allow("background") and result.hero_url and config is not None and (overwrite or images_only or not game.bg_path):
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
        elif allow("background") and result.hero_url and config is not None and game.bg_path:
            logger.debug(f"Hero skipped for game {game.id}: already has bg_path ({game.bg_path})")

    # ── Text metadata ──
    if not images_only:
        if allow("developer") and result.developer and (overwrite or not game.developer):
            game.developer = result.developer
            session.add(game)
        if allow("description") and result.description and (overwrite or not game.description):
            game.description = result.description[:2000]
            session.add(game)
        if allow("release_date") and result.release_date and (overwrite or not game.release_date):
            game.release_date = result.release_date
            session.add(game)
        if allow("length") and result.length and (overwrite or not game.length):
            game.length = result.length
            session.add(game)
        if allow("length_minutes") and result.length_minutes and (overwrite or not game.length_minutes):
            game.length_minutes = result.length_minutes
            session.add(game)
        # Source ID — map scraper to game ID column
        _id_map = {"vndb_kana": "vndb_id", "vndb": "vndb_id",
                   "steam": "steam_id", "bangumi": "bangumi_id"}
        col = _id_map.get(source_name)
        if allow("source_id") and col and result.source_id and (overwrite or not getattr(game, col, None)):
            setattr(game, col, result.source_id)
            session.add(game)


async def run_batch_scrape(
    config: Config,
    game_ids: list[int] | None,
    session: AsyncSession,
    job: ScrapeJob,
    sources: list[str] | None = None,
    mode: str = "missing",
    field_sources: dict[str, list[str]] | None = None,
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

    field_sources = (
        _normalize_field_sources(field_sources)
        if field_sources is not None
        else _load_default_field_sources(config)
    )
    scrapers = _build_scrapers(config)
    if sources:
        scrapers = [s for s in scrapers if s.source_name in sources]
    covers_dir = config.covers_path
    completed = 0
    failed = 0

    client_kwargs = {"timeout": httpx.Timeout(30.0)}
    if config.proxy:
        client_kwargs["proxy"] = config.proxy
    async with httpx.AsyncClient(**client_kwargs) as client:
        for i, game in enumerate(games):
            job.current_game = game.name
            job.completed_games = i
            await session.commit()

            try:
                results = await scrape_single_game(
                    game,
                    scrapers,
                    client,
                    covers_dir,
                    session,
                    config,
                    mode=mode,
                    field_sources=field_sources,
                )
                if any(results.values()):
                    completed += 1
                else:
                    failed += 1
            except Exception as e:
                logger.error(f"Failed to scrape game {game.name}: {e}")
                failed += 1

    job.status = JobStatus.COMPLETED
    job.completed_games = completed
    job.failed_games = failed
    job.current_game = None
    job.log = f"Completed: {completed}, Failed: {failed}"
    await session.commit()

    # Clean up scrapers
    for scraper in scrapers:
        await scraper.close()

    return {"total": len(games), "completed": completed, "failed": failed}

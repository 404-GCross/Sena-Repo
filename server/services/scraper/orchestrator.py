"""Batch scrape orchestrator — runs multiple scrapers against games."""

from __future__ import annotations

import logging
import asyncio
import ipaddress
import re
import shutil
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

logger = logging.getLogger(__name__)

_SCRAPER_SEARCH_TIMEOUT = 45
_GAME_SCRAPE_TIMEOUT = 300
_DNS_LOOKUP_TIMEOUT = 3.0
_IMAGE_DOWNLOAD_TIMEOUT = 45.0
_MAX_PROGRESS_TEXT_LENGTH = 512
_UNSET = object()

_VALID_SOURCES = {"vndb_kana", "vndb", "bangumi", "steam", "hikarinagi"}
# Average playtime is intentionally sourced from VNDB only.
_PLAYTIME_SOURCES = {"vndb_kana", "vndb"}


def _safe_progress_text(value: object, *, limit: int = _MAX_PROGRESS_TEXT_LENGTH) -> str:
    text = str(value or "").replace("\r", " ").replace("\n", " ").strip()
    text = re.sub(r"https?://\S+", "[url]", text)
    text = re.sub(r"(?i)(token|secret|password|signature|authorization)=([^&\s]+)", r"\1=[redacted]", text)
    if len(text) > limit:
        return text[: limit - 1] + "…"
    return text


def _exception_summary(exc: Exception) -> str:
    if isinstance(exc, httpx.HTTPStatusError):
        return f"HTTP {exc.response.status_code}"
    if isinstance(exc, httpx.TimeoutException):
        return "请求超时"
    return _safe_progress_text(f"{type(exc).__name__}: {exc}")


async def _update_job_progress(
    session: AsyncSession,
    job: ScrapeJob | None,
    *,
    game: Game | None = None,
    status: JobStatus | None = None,
    total_games: int | None = None,
    processed_games: int | None = None,
    successful_games: int | None = None,
    completed_games: int | None = None,
    failed_games: int | None = None,
    source: object = _UNSET,
    query: object = _UNSET,
    stage: object = _UNSET,
    last_error: object = _UNSET,
    log: str | None = None,
) -> None:
    if job is None:
        return
    now = datetime.utcnow()
    if status is not None:
        job.status = status
    if total_games is not None:
        job.total_games = total_games
    if processed_games is not None:
        job.processed_games = processed_games
    if successful_games is not None:
        job.successful_games = successful_games
    if completed_games is not None:
        job.completed_games = completed_games
    if failed_games is not None:
        job.failed_games = failed_games
    if game is not None:
        job.current_game_id = game.id
        job.current_game = game.name
    if source is not _UNSET:
        job.current_source = None if source is None else _safe_progress_text(source, limit=64)
    if query is not _UNSET:
        job.current_query = None if query is None else _safe_progress_text(query)
    if stage is not _UNSET:
        job.current_stage = None if stage is None else _safe_progress_text(stage, limit=64)
    if last_error is not _UNSET:
        job.last_error = None if last_error is None else _safe_progress_text(last_error, limit=1024)
    if log is not None:
        job.log = log
    job.heartbeat_at = now
    job.updated_at = now
    session.add(job)
    await session.commit()


def _is_blocked_address(value: str) -> bool:
    address = ipaddress.ip_address(value)
    return (
        address.is_loopback
        or address.is_private
        or address.is_link_local
        or address.is_reserved
        or address.is_unspecified
        or address.is_multicast
    )


async def _is_public_http_url(url: str) -> bool:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        return False
    try:
        ip = ipaddress.ip_address(parsed.hostname)
        return not _is_blocked_address(str(ip))
    except ValueError:
        pass
    try:
        loop = asyncio.get_running_loop()
        addrs = await asyncio.wait_for(
            loop.getaddrinfo(parsed.hostname, None),
            timeout=_DNS_LOOKUP_TIMEOUT,
        )
    except (OSError, asyncio.TimeoutError):
        return False
    for addr in addrs:
        try:
            ip = ipaddress.ip_address(addr[4][0])
        except ValueError:
            return False
        if _is_blocked_address(str(ip)):
            return False
    return True


def _build_scrapers(config: Config) -> list[BaseScraper]:
    """Build enabled scrapers in the configured priority order."""
    s = config.scrapers
    normalize_scraper_config(s)
    builders = {
        "hikarinagi": lambda: HikarinagiScraper(
            proxy=config.proxy,
            client_id=s.hikarinagi_client_id,
            client_secret=s.hikarinagi_client_secret,
            scope=s.hikarinagi_scope,
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
    async def _download() -> bool:
        current = url
        for _ in range(6):
            if not await _is_public_http_url(current):
                logger.warning(
                    "Skipping non-public image URL host: %s",
                    _safe_progress_text(urlparse(current).netloc, limit=128),
                )
                return False
            resp = await client.get(
                current,
                timeout=httpx.Timeout(30.0, connect=10.0),
                follow_redirects=False,
            )
            if resp.status_code not in {301, 302, 303, 307, 308}:
                break
            location = resp.headers.get("location")
            if not location:
                break
            current = urljoin(current, location)
        else:
            logger.warning("Too many image redirects for host: %s", _safe_progress_text(urlparse(url).netloc))
            return False
        resp.raise_for_status()
        dest_path.parent.mkdir(parents=True, exist_ok=True)
        with open(dest_path, "wb") as f:
            f.write(resp.content)
        return True

    try:
        return await asyncio.wait_for(_download(), timeout=_IMAGE_DOWNLOAD_TIMEOUT)
    except asyncio.TimeoutError:
        logger.warning(
            "Cover download timed out after %ss for host: %s",
            _IMAGE_DOWNLOAD_TIMEOUT,
            _safe_progress_text(urlparse(url).netloc),
        )
        return False
    except Exception as e:
        logger.warning(
            "Cover download failed for host %s: %s",
            _safe_progress_text(urlparse(url).netloc),
            _exception_summary(e),
        )
        return False


def _copy_local_asset(source_path: str | None, dest_dir: Path, dest_stem: str) -> str | None:
    if not source_path:
        return None
    src = Path(source_path)
    if not src.is_file():
        return None
    suffix = src.suffix or ".jpg"
    dest = dest_dir / f"{dest_stem}{suffix}"
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        if src.resolve() != dest.resolve():
            shutil.copy2(src, dest)
        return str(dest)
    except Exception as exc:
        logger.warning("Failed to reuse local metadata asset: %s", _exception_summary(exc))
        return None


async def _reuse_existing_metadata(
    session: AsyncSession,
    game: Game,
    covers_dir: Path,
    config: Config | None,
    mode: str,
) -> bool:
    if mode == "overwrite":
        return False

    result = await session.execute(
        select(Game)
        .options(selectinload(Game.company), selectinload(Game.tags).selectinload(GameTag.tag))
        .where(
            Game.id != game.id,
            Game.is_deleted == False,
            Game.name == game.name,
        )
        .order_by(Game.updated_at.desc())
    )
    candidates = result.scalars().unique().all()
    if not candidates:
        return False

    candidate: Game | None = None
    for item in candidates:
        if game.company_id and item.company_id and game.company_id != item.company_id:
            continue
        candidate = item
        break
    if candidate is None:
        return False

    changed = False
    images_only = mode == "images"
    metadata_only = mode == "metadata"

    if not metadata_only:
        copied_cover = _copy_local_asset(candidate.cover_path, covers_dir, f"{game.id}_reused")
        if copied_cover and not game.cover_path:
            game.cover_path = copied_cover
            changed = True
        if config is not None:
            copied_bg = _copy_local_asset(
                candidate.bg_path,
                config.backgrounds_path,
                f"{game.id}_hero",
            )
            if copied_bg and not game.bg_path:
                game.bg_path = copied_bg
                changed = True

    if not images_only:
        for attr in (
            "developer",
            "description",
            "release_date",
            "vndb_id",
            "steam_id",
            "bangumi_id",
            "hikarinagi_id",
            "length",
            "length_minutes",
        ):
            if getattr(game, attr, None):
                continue
            value = getattr(candidate, attr, None)
            if value:
                setattr(game, attr, value)
                changed = True
        if candidate.is_nsfw and not game.is_nsfw:
            game.is_nsfw = True
            changed = True

        for assoc in candidate.tags:
            if (assoc.source or "") == "user":
                continue
            assoc_result = await session.execute(
                select(GameTag).where(
                    GameTag.game_id == game.id,
                    GameTag.tag_id == assoc.tag_id,
                )
            )
            existing = assoc_result.scalar_one_or_none()
            if existing is None:
                session.add(
                    GameTag(
                        game_id=game.id,
                        tag_id=assoc.tag_id,
                        source=assoc.source,
                        weight=assoc.weight,
                        is_spoiler=assoc.is_spoiler,
                    )
                )
                changed = True
            elif (existing.source or "") != "user":
                if existing.source != assoc.source:
                    existing.source = assoc.source
                    changed = True
                if assoc.weight > (existing.weight or 0.0):
                    existing.weight = assoc.weight
                    changed = True
                if assoc.is_spoiler and not existing.is_spoiler:
                    existing.is_spoiler = True
                    changed = True

    if changed:
        game.updated_at = datetime.utcnow()
        session.add(game)
        await session.commit()
        logger.info("Reused metadata from game %s for duplicate game %s", candidate.id, game.id)
    return changed


async def scrape_single_game(
    game: Game,
    scrapers: list[BaseScraper],
    client: httpx.AsyncClient,
    covers_dir: Path,
    session: AsyncSession,
    config: "Config | None" = None,
    mode: str = "missing",
    job: ScrapeJob | None = None,
) -> dict:
    """Scrape a single game across all available sources.

    Returns:
        Dict with {source_name: ScraperResult or None}
    """
    company_hint = game.company.name if game.company else None
    results = {}

    await _update_job_progress(
        session,
        job,
        game=game,
        source=None,
        query=None,
        stage="reuse_metadata",
    )
    if await _reuse_existing_metadata(session, game, covers_dir, config, mode):
        results["metadata_cache"] = ScraperResult(
            title=game.name,
            source_name="metadata_cache",
        )
        await _update_job_progress(
            session,
            job,
            game=game,
            source="metadata_cache",
            query=game.name,
            stage="reused",
            last_error=None,
        )
        if mode in {"missing", "images"} and game.cover_path:
            return results
        if mode == "metadata" and game.description and game.developer:
            return results

    async def handle_result(scraper: BaseScraper, result: ScraperResult) -> None:
        results[scraper.source_name] = result

    async def search_best(
        scraper: BaseScraper,
        query: str,
        context: str,
    ) -> ScraperResult | None:
        await _update_job_progress(
            session,
            job,
            game=game,
            source=scraper.source_name,
            query=query,
            stage="search",
        )
        try:
            result = await asyncio.wait_for(
                scraper.search_best(query, company_hint),
                timeout=_SCRAPER_SEARCH_TIMEOUT,
            )
            if result is not None:
                await _update_job_progress(
                    session,
                    job,
                    game=game,
                    source=scraper.source_name,
                    query=query,
                    stage="matched",
                    last_error=None,
                )
            return result
        except asyncio.TimeoutError:
            message = (
                f"{scraper.source_name} {context} 查询超时"
                f"（{_SCRAPER_SEARCH_TIMEOUT}s）：{query}"
            )
            logger.warning(
                "Scraper %s timed out after %ss for %s '%s'",
                scraper.source_name,
                _SCRAPER_SEARCH_TIMEOUT,
                context,
                query,
            )
            await _update_job_progress(
                session,
                job,
                game=game,
                source=scraper.source_name,
                query=query,
                stage="search_timeout",
                last_error=message,
            )
            return None
        except Exception as exc:
            message = f"{scraper.source_name} {context} 查询失败：{_exception_summary(exc)}"
            logger.warning(
                "Scraper %s failed for %s '%s': %s",
                scraper.source_name,
                context,
                query,
                _exception_summary(exc),
            )
            await _update_job_progress(
                session,
                job,
                game=game,
                source=scraper.source_name,
                query=query,
                stage="search_failed",
                last_error=message,
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
    replaced_tags = False
    for source_name, result in ordered_results:
        replace_tags = mode == "overwrite" and not replaced_tags and bool(result.tags)
        await _apply_result(
            result,
            source_name,
            game,
            client,
            covers_dir,
            session,
            config,
            mode,
            job=job,
            replace_tags=replace_tags,
        )
        if replace_tags:
            replaced_tags = True

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
    job: ScrapeJob | None = None,
    replace_tags: bool | None = None,
):
    """Apply a scraper result to a game, respecting the scrape mode."""
    overwrite = mode == "overwrite"
    images_only = mode == "images"
    metadata_only = mode == "metadata"

    # ── Images ──
    if not metadata_only:
        # Cover
        if result.cover_url and (overwrite or images_only or not game.cover_path):
            await _update_job_progress(
                session,
                job,
                game=game,
                source=source_name,
                query=result.title or game.name,
                stage="download_cover",
            )
            ext = ".jpg"
            cover_path = covers_dir / f"{game.id}_{source_name}{ext}"
            success = await _download_cover(client, result.cover_url, cover_path)
            if success:
                game.cover_path = str(cover_path)
                session.add(game)
        # Hero/landscape
        if result.hero_url and config is not None and (overwrite or images_only or not game.bg_path):
            await _update_job_progress(
                session,
                job,
                game=game,
                source=source_name,
                query=result.title or game.name,
                stage="download_hero",
            )
            logger.info("Downloading hero for game %s from %s", game.id, source_name)
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
    await _update_job_progress(
        session,
        job,
        game=game,
        source=source_name,
        query=result.title or game.name,
        stage="apply_metadata",
    )
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
                replace_existing=overwrite if replace_tags is None else replace_tags,
            )


async def _apply_scraped_tags(
    session: AsyncSession,
    game: Game,
    source_name: str,
    tags: list[ScrapedTag],
    *,
    overwrite: bool,
    replace_existing: bool = False,
) -> None:
    if replace_existing:
        existing_result = await session.execute(
            select(GameTag).where(
                GameTag.game_id == game.id,
                GameTag.source != "user",
            )
        )
        for assoc in existing_result.scalars():
            await session.delete(assoc)
        await session.flush()

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

        if (assoc.source or "") != "user":
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
        await _update_job_progress(
            session,
            job,
            status=JobStatus.COMPLETED,
            total_games=0,
            processed_games=0,
            successful_games=0,
            completed_games=0,
            failed_games=0,
            source=None,
            query=None,
            stage="completed",
            last_error=None,
            log="No games to scrape.",
        )
        return {"total": 0, "completed": 0, "successful": 0, "failed": 0}

    await _update_job_progress(
        session,
        job,
        status=JobStatus.RUNNING,
        total_games=len(games),
        processed_games=0,
        successful_games=0,
        completed_games=0,
        failed_games=0,
        source=None,
        query=None,
        stage="started",
        last_error=None,
    )
    job.started_at = datetime.utcnow()
    await session.commit()

    scrapers = _build_scrapers(config)
    if sources:
        source_set = {str(source) for source in sources if str(source) in _VALID_SOURCES}
        if "vndb_kana" in source_set:
            source_set.add("vndb")
        scrapers = [s for s in scrapers if s.source_name in source_set]
    covers_dir = config.covers_path
    processed = 0
    successful = 0
    failed = 0

    client_kwargs = {"timeout": httpx.Timeout(30.0)}
    if config.proxy:
        client_kwargs["proxy"] = config.proxy
    try:
        async with httpx.AsyncClient(**client_kwargs) as client:
            for game in games:
                await session.refresh(job)
                if job.status == JobStatus.FAILED:
                    await _update_job_progress(
                        session,
                        job,
                        game=None,
                        processed_games=processed,
                        successful_games=successful,
                        completed_games=processed,
                        failed_games=failed,
                        source=None,
                        query=None,
                        stage=job.current_stage or "cancelled",
                        log=(job.log or "") + " 已停止。",
                    )
                    break

                await _update_job_progress(
                    session,
                    job,
                    game=game,
                    processed_games=processed,
                    successful_games=successful,
                    completed_games=processed,
                    failed_games=failed,
                    source=None,
                    query=None,
                    stage="game",
                )

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
                            job=job,
                        ),
                        timeout=_GAME_SCRAPE_TIMEOUT,
                    )
                    processed += 1
                    if any(results.values()):
                        successful += 1
                        last_error = None
                    else:
                        failed += 1
                        last_error = f"未匹配到可用元数据：{game.name}"
                    await _update_job_progress(
                        session,
                        job,
                        game=game,
                        processed_games=processed,
                        successful_games=successful,
                        completed_games=processed,
                        failed_games=failed,
                        source=None,
                        query=None,
                        stage="completed_game",
                        last_error=last_error,
                    )
                except asyncio.TimeoutError:
                    await session.rollback()
                    job = await session.merge(job)
                    processed += 1
                    failed += 1
                    message = f"单个游戏刮削超过 {_GAME_SCRAPE_TIMEOUT}s，已跳过：{game.name}"
                    logger.error(message)
                    await _update_job_progress(
                        session,
                        job,
                        game=game,
                        processed_games=processed,
                        successful_games=successful,
                        completed_games=processed,
                        failed_games=failed,
                        source=None,
                        query=None,
                        stage="game_timeout",
                        last_error=message,
                    )
                except Exception as e:
                    await session.rollback()
                    job = await session.merge(job)
                    processed += 1
                    failed += 1
                    message = f"刮削失败：{game.name}：{_exception_summary(e)}"
                    logger.error(message)
                    await _update_job_progress(
                        session,
                        job,
                        game=game,
                        processed_games=processed,
                        successful_games=successful,
                        completed_games=processed,
                        failed_games=failed,
                        source=None,
                        query=None,
                        stage="game_failed",
                        last_error=message,
                    )

        await session.refresh(job)
        if job.status != JobStatus.FAILED:
            await _update_job_progress(
                session,
                job,
                status=JobStatus.COMPLETED,
                processed_games=processed,
                successful_games=successful,
                completed_games=processed,
                failed_games=failed,
                source=None,
                query=None,
                stage="completed",
                log=f"Completed: {successful}, Failed: {failed}",
            )
            job.current_game_id = None
            job.current_game = None
            await session.commit()
        else:
            await _update_job_progress(
                session,
                job,
                processed_games=processed,
                successful_games=successful,
                completed_games=processed,
                failed_games=failed,
                source=None,
                query=None,
                stage=job.current_stage or "cancelled",
                log=(job.log or "") + f" 停止前处理: {processed}, 成功: {successful}, 失败: {failed}",
            )
            job.current_game_id = None
            job.current_game = None
            await session.commit()
    finally:
        for scraper in scrapers:
            await scraper.close()

    return {"total": len(games), "completed": processed, "successful": successful, "failed": failed}

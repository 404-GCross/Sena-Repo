"""Batch scrape orchestrator — runs multiple scrapers against games."""

from __future__ import annotations

import logging
from datetime import datetime
from pathlib import Path

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from config import Config
from models.game import Game
from models.scrape_job import JobStatus, ScrapeJob

from .base import BaseScraper, ScraperResult, clean_title, extract_dlsite_workno
from .vndb_kana import VndbKanaScraper, VndbTitlesScraper
from .bangumi import BangumiScraper
from .steam import SteamScraper
from .dlsite import DLsiteScraper
from .igdb import IGDBScraper

logger = logging.getLogger(__name__)


def _build_scrapers(config: Config) -> list[BaseScraper]:
    """Build all available scrapers from config."""
    s = config.scrapers

    scrapers: list[BaseScraper] = [
        VndbKanaScraper(proxy=config.proxy),
        VndbTitlesScraper(proxy=config.proxy),
        BangumiScraper(proxy=config.proxy, token=s.bangumi_token),
        DLsiteScraper(proxy=config.proxy),
        SteamScraper(proxy=config.proxy),
    ]
    if s.igdb_client_id and s.igdb_client_secret:
        scrapers.append(IGDBScraper(
            proxy=config.proxy,
            client_id=s.igdb_client_id,
            client_secret=s.igdb_client_secret,
        ))

    return scrapers


async def _download_cover(
    client: httpx.AsyncClient,
    url: str,
    dest_path: Path,
) -> bool:
    """Download a cover image to the specified path."""
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
) -> dict:
    """Scrape a single game across all available sources.

    Returns:
        Dict with {source_name: ScraperResult or None}
    """
    company_hint = game.company.name if game.company else None
    results = {}

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

    # ── DLsite: auto-detect work number → prioritize DLsite ──
    dlsite_workno = extract_dlsite_workno(raw_name) or extract_dlsite_workno(folder_name)
    if dlsite_workno:
        dlsite_scraper = next((s for s in scrapers if s.source_name == "dlsite"), None)
        if dlsite_scraper:
            for query in [dlsite_workno] + candidates:
                try:
                    result = await dlsite_scraper.search_best(query, company_hint)
                    if result:
                        results[dlsite_scraper.source_name] = result
                        await _apply_result(result, dlsite_scraper.source_name, game, client, covers_dir, session)
                        break
                except Exception:
                    continue

    # ── Standard search: try candidates × scrapers ──
    non_dlsite = [s for s in scrapers if s.source_name != "dlsite"]
    for query in candidates:
        for scraper in non_dlsite:
            if scraper.source_name in results:
                continue
            try:
                result = await scraper.search_best(query, company_hint)
                if result:
                    results[scraper.source_name] = result
                    await _apply_result(result, scraper.source_name, game, client, covers_dir, session)
                    break  # Found for this candidate, try next candidate for remaining scrapers
            except Exception as e:
                logger.error(f"Scraper {scraper.source_name} error for '{query}': {e}")

    await session.commit()
    return results


async def _apply_result(
    result: ScraperResult,
    source_name: str,
    game: Game,
    client: httpx.AsyncClient,
    covers_dir: Path,
    session: AsyncSession,
):
    """Apply a scraper result to a game: download cover, set metadata."""
    if result.cover_url and not game.cover_path:
        ext = ".jpg"
        cover_path = covers_dir / f"{game.id}_{source_name}{ext}"
        success = await _download_cover(client, result.cover_url, cover_path)
        if success:
            game.cover_path = str(cover_path)
            session.add(game)
    if result.developer and not game.developer:
        game.developer = result.developer
        session.add(game)
    if result.description and not game.description:
        game.description = result.description[:2000]
        session.add(game)


async def run_batch_scrape(
    config: Config,
    game_ids: list[int] | None,
    session: AsyncSession,
    job: ScrapeJob,
    sources: list[str] | None = None,
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
    else:
        # All games without covers
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
                    game, scrapers, client, covers_dir, session,
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

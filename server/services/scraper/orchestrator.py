"""Batch scrape orchestrator — runs multiple scrapers against games."""

from __future__ import annotations

import logging
from datetime import datetime
from pathlib import Path

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from config import Config
from models.game import Game
from models.scrape_job import JobStatus, ScrapeJob

from .base import BaseScraper, ScraperResult
from .vndb_kana import VndbKanaScraper, VndbTitlesScraper
from .bangumi import BangumiScraper
from .steam import SteamScraper
from .dlsite import DLsiteScraper
from .steamgriddb import SteamGridDBScraper
from .igdb import IGDBScraper
from .muyue import MuyueScraper

logger = logging.getLogger(__name__)


def _build_scrapers(config: Config) -> list[BaseScraper]:
    """Build all available scrapers from config."""
    s = config.scrapers

    scrapers: list[BaseScraper] = [
        VndbKanaScraper(proxy=config.proxy),
        VndbTitlesScraper(proxy=config.proxy),
        BangumiScraper(proxy=config.proxy, token=s.bangumi_token),
        SteamScraper(proxy=config.proxy),
        DLsiteScraper(proxy=config.proxy),
        MuyueScraper(proxy=config.proxy),
    ]
    if s.steamgriddb_key:
        scrapers.append(SteamGridDBScraper(proxy=config.proxy, api_key=s.steamgriddb_key))
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

    for scraper in scrapers:
        try:
            result = await scraper.search_best(game.name, company_hint)
            if result:
                results[scraper.source_name] = result

                # Download cover if found and game has no cover
                if result.cover_url and not game.cover_path:
                    ext = ".jpg"
                    cover_path = covers_dir / f"{game.id}_{scraper.source_name}{ext}"
                    success = await _download_cover(client, result.cover_url, cover_path)
                    if success:
                        game.cover_path = str(cover_path)
                        session.add(game)

                # Set developer from scraper result if game doesn't have one
                if result.developer and not game.developer:
                    game.developer = result.developer

                # Set description if not set
                if result.description and not game.description:
                    game.description = result.description[:2000]  # Truncate

        except Exception as e:
            logger.error(f"Scraper {scraper.source_name} error for '{game.name}': {e}")
            results[scraper.source_name] = None

    await session.commit()
    return results


async def run_batch_scrape(
    config: Config,
    game_ids: list[int] | None,
    session: AsyncSession,
    job: ScrapeJob,
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
            select(Game).where(Game.id.in_(game_ids), Game.is_deleted == False)
        )
    else:
        # All games without covers
        result = await session.execute(
            select(Game).where(
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
    covers_dir = config.covers_path
    completed = 0
    failed = 0

    async with httpx.AsyncClient(timeout=30.0) as client:
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

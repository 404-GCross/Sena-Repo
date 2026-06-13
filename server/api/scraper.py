"""Scraper API — manual and batch metadata scraping."""

from __future__ import annotations

import logging
import ipaddress
from urllib.parse import urlparse
from datetime import datetime

import httpx
from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.orm import joinedload
from sqlalchemy.ext.asyncio import AsyncSession

from database import get_session
from config import load_config
from models.game import Game
from models.scrape_job import JobStatus, ScrapeJob
from schemas.common import MessageResponse
from services.scraper.orchestrator import (
    _build_scrapers,
    run_batch_scrape,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["scraper"])


def _validate_public_url(url: str) -> None:
    """Reject non-HTTP(S) and internal/private URLs (SSRF prevention)."""
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise HTTPException(status_code=400, detail="仅支持 HTTP/HTTPS URL")
    if parsed.hostname:
        try:
            ip = ipaddress.ip_address(parsed.hostname)
            if ip.is_loopback or ip.is_private or ip.is_link_local:
                raise HTTPException(status_code=400, detail="不允许使用内网地址")
        except ValueError:
            pass  # Hostname (not IP) is fine


class BatchScrapeRequest(BaseModel):
    game_ids: list[int] | None = None
    sources: list[str] | None = None
    mode: str = "missing"  # "missing" | "overwrite" | "images" | "metadata"


class JobStatusOut(BaseModel):
    id: int
    status: str
    total_games: int
    completed_games: int
    failed_games: int
    current_game: str | None
    log: str
    started_at: str | None


# --- Search candidates (Playnite-style) ---

@router.get("/scrape/search")
async def search_candidates(
    q: str,
    source: str = "vndb_kana",
):
    """Search a specific source and return all candidates."""
    config = load_config()
    scrapers = {s.source_name: s for s in _build_scrapers(config)}
    scraper = scrapers.get(source)
    if scraper is None:
        raise HTTPException(status_code=400, detail=f"Unknown source: {source}")

    try:
        results = await scraper.search(q)
        return {
            "source": source,
            "query": q,
            "results": [
                {"title": r.title, "cover_url": r.cover_url, "hero_url": r.hero_url,
                 "developer": r.developer,
                 "description": r.description, "release_date": r.release_date,
                 "source_id": r.source_id}
                for r in results
            ],
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        await scraper.close()


@router.post("/games/{game_id}/scrape-apply")
async def scrape_apply(
    game_id: int,
    source: str,
    source_id: str,
    cover_url: str = "",
    hero_url: str = "",
    developer: str = "",
    title: str = "",
    description: str = "",
    release_date: str = "",
    session: AsyncSession = Depends(get_session),
):
    """Apply a specific scraper result to a game."""
    result = await session.execute(select(Game).where(Game.id == game_id))
    game = result.scalar_one_or_none()
    if game is None:
        raise HTTPException(status_code=404, detail="Game not found")

    if cover_url:
        _validate_public_url(cover_url)
        config = load_config()
        client_kwargs = {"timeout": httpx.Timeout(30.0)}
        if config.proxy:
            client_kwargs["proxy"] = config.proxy
        async with httpx.AsyncClient(**client_kwargs) as c:
            try:
                resp = await c.get(cover_url)
                resp.raise_for_status()
                cover_path = config.covers_path / f"{game_id}_{source}.jpg"
                config.covers_path.mkdir(parents=True, exist_ok=True)
                cover_path.write_bytes(resp.content)
                game.cover_path = str(cover_path)
            except Exception as e:
                logger.warning(f"Cover download failed: {e}")
        # Download hero/landscape banner to backgrounds folder
        if hero_url:
            _validate_public_url(hero_url)
            try:
                resp = await c.get(hero_url)
                resp.raise_for_status()
                bg_dir = config.backgrounds_path
                bg_dir.mkdir(parents=True, exist_ok=True)
                bg_path = bg_dir / f"{game_id}_hero.jpg"
                bg_path.write_bytes(resp.content)
                game.bg_path = str(bg_path)
            except Exception as e:
                logger.warning(f"Hero download failed: {e}")

    if developer:
        game.developer = developer
    if description:
        game.description = description[:2000]
    if release_date:
        game.release_date = release_date
    sfx = ""
    sf = {"vndb_kana": "vndb_id", "vndb": "vndb_id", "bangumi": "bangumi_id", "steam": "steam_id"}
    sfx = sf.get(source, "")
    if sfx and source_id:
        setattr(game, sfx, source_id)

    game.updated_at = datetime.utcnow()
    session.add(game)
    await session.commit()
    return {"message": "已应用"}


# --- Manual scrape for a single game ---

@router.post("/games/{game_id}/scrape", response_model=dict)
async def scrape_game_cover(
    game_id: int,
    sources: list[str] | None = Query(default=None),
    session: AsyncSession = Depends(get_session),
):
    """Manually scrape metadata for a single game.

    Optionally specify which sources to use (e.g. ?sources=vndb_kana&sources=bangumi).
    If no sources specified, uses all available sources.
    """
    result = await session.execute(
        select(Game)
        .where(Game.id == game_id, Game.is_deleted == False)
        .options(joinedload(Game.company))
    )
    game = result.unique().scalar_one_or_none()
    if game is None:
        raise HTTPException(status_code=404, detail="Game not found")

    config = load_config()
    all_scrapers = _build_scrapers(config)

    # Filter by requested sources
    if sources:
        all_scrapers = [s for s in all_scrapers if s.source_name in sources]
        if not all_scrapers:
            raise HTTPException(status_code=400, detail="No valid sources specified")

    company_hint = game.company.name if game.company else None
    covers_dir = config.covers_path
    found_results = []

    client_kwargs = {"timeout": httpx.Timeout(30.0)}
    if config.proxy:
        client_kwargs["proxy"] = config.proxy
    async with httpx.AsyncClient(**client_kwargs) as client:
        for scraper in all_scrapers:
            try:
                result = await scraper.search_best(game.name, company_hint)
                if result:
                    found_results.append({
                        "source": scraper.source_name,
                        "title": result.title,
                        "cover_url": result.cover_url,
                        "developer": result.developer,
                    })

                    # Download first available cover
                    if result.cover_url and not game.cover_path:
                        ext = ".jpg"
                        cover_path = covers_dir / f"{game_id}_{scraper.source_name}{ext}"
                        try:
                            resp = await client.get(result.cover_url, timeout=30.0)
                            resp.raise_for_status()
                            covers_dir.mkdir(parents=True, exist_ok=True)
                            cover_path.write_bytes(resp.content)
                            game.cover_path = str(cover_path)
                            session.add(game)
                        except Exception as e:
                            logger.warning(f"Cover download failed: {e}")
                    # Download hero/landscape banner
                    if result.hero_url and not game.bg_path:
                        try:
                            bg_dir = config.backgrounds_path
                            bg_dir.mkdir(parents=True, exist_ok=True)
                            resp = await client.get(result.hero_url, timeout=30.0)
                            resp.raise_for_status()
                            bg_path = bg_dir / f"{game_id}_hero.jpg"
                            bg_path.write_bytes(resp.content)
                            game.bg_path = str(bg_path)
                            session.add(game)
                        except Exception as e:
                            logger.warning(f"Hero download failed: {e}")

                    if result.developer and not game.developer:
                        game.developer = result.developer
                        session.add(game)

            except Exception as e:
                logger.error(f"Scraper {scraper.source_name} failed: {e}")
            finally:
                await scraper.close()

    await session.commit()
    return {
        "game_id": game_id,
        "game_name": game.name,
        "sources_checked": len(all_scrapers),
        "results": found_results,
        "cover_downloaded": bool(game.cover_path),
    }


# --- Batch scrape ---

@router.post("/scrape/batch", response_model=dict)
async def start_batch_scrape(
    body: BatchScrapeRequest,
    session: AsyncSession = Depends(get_session),
):
    """Start a batch scrape job for games without covers.

    If game_ids is provided, only those games are scraped.
    Otherwise, all games without covers are scraped.
    """
    config = load_config()

    # Create job record
    job = ScrapeJob(status=JobStatus.PENDING)
    session.add(job)
    await session.commit()
    await session.refresh(job)

    # Run in background thread — isolated SelectorEventLoop avoids uvloop/greenlet conflict
    import threading

    def _run_thread():
        import asyncio as _asyncio
        import database
        loop = _asyncio.new_event_loop()
        _asyncio.set_event_loop(loop)
        try:
            async def _work():
                async with database._session_factory() as bg_session:
                    await run_batch_scrape(config, body.game_ids, bg_session, job, sources=body.sources, mode=body.mode)
            loop.run_until_complete(_work())
        except Exception as e:
            logger.error(f"Batch scrape job {job.id} failed: {e}", exc_info=True)
        finally:
            loop.close()

    threading.Thread(target=_run_thread, daemon=True).start()

    return {
        "job_id": job.id,
        "status": "started",
        "message": f"Batch scrape started for {job.total_games or 'all missing'} games",
    }


@router.post("/scrape/jobs/{job_id}/cancel")
async def cancel_scrape_job(job_id: int, session: AsyncSession = Depends(get_session)):
    """Cancel a running scrape job."""
    result = await session.execute(select(ScrapeJob).where(ScrapeJob.id == job_id))
    job = result.scalar_one_or_none()
    if job is None:
        raise HTTPException(status_code=404, detail="Job not found")
    if job.status not in (JobStatus.PENDING, JobStatus.RUNNING):
        raise HTTPException(status_code=400, detail="Job is not active")
    job.status = JobStatus.FAILED
    job.log = (job.log or "") + " [已取消]"
    await session.commit()
    return {"message": "Job cancelled"}


@router.get("/scrape/jobs", response_model=list[JobStatusOut])
async def list_scrape_jobs(session: AsyncSession = Depends(get_session)):
    """List all scrape jobs."""
    result = await session.execute(
        select(ScrapeJob).order_by(ScrapeJob.created_at.desc()).limit(20)
    )
    jobs = result.scalars().all()
    return [
        {
            "id": j.id,
            "status": j.status.value,
            "total_games": j.total_games,
            "completed_games": j.completed_games,
            "failed_games": j.failed_games,
            "current_game": j.current_game,
            "log": j.log,
            "started_at": j.started_at.isoformat() if j.started_at else None,
        }
        for j in jobs
    ]


@router.get("/scrape/jobs/{job_id}", response_model=JobStatusOut)
async def get_scrape_job(job_id: int, session: AsyncSession = Depends(get_session)):
    """Get a specific scrape job's status."""
    result = await session.execute(
        select(ScrapeJob).where(ScrapeJob.id == job_id)
    )
    job = result.scalar_one_or_none()
    if job is None:
        raise HTTPException(status_code=404, detail="Job not found")

    return {
        "id": job.id,
        "status": job.status.value,
        "total_games": job.total_games,
        "completed_games": job.completed_games,
        "failed_games": job.failed_games,
        "current_game": job.current_game,
        "log": job.log,
        "started_at": job.started_at.isoformat() if job.started_at else None,
    }


# --- Cover management ---

@router.post("/games/{game_id}/cover", response_model=MessageResponse)
async def update_game_cover(
    game_id: int,
    cover_url: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session),
):
    """Update a game's cover via URL or mark it for manual update.

    Pass ?cover_url=<url> to download from a URL.
    """
    result = await session.execute(select(Game).where(Game.id == game_id))
    game = result.scalar_one_or_none()
    if game is None:
        raise HTTPException(status_code=404, detail="Game not found")

    if cover_url:
        _validate_public_url(cover_url)
        config = load_config()
        covers_dir = config.covers_path
        covers_dir.mkdir(parents=True, exist_ok=True)
        ext = ".jpg"
        cover_path = covers_dir / f"{game_id}_manual{ext}"

        client_kwargs = {"timeout": httpx.Timeout(30.0)}
        if config.proxy:
            client_kwargs["proxy"] = config.proxy
        async with httpx.AsyncClient(**client_kwargs) as client:
            try:
                resp = await client.get(cover_url)
                resp.raise_for_status()
                cover_path.write_bytes(resp.content)
                game.cover_path = str(cover_path)
                await session.commit()
                return {"message": "Cover updated", "cover_path": game.cover_path}
            except Exception as e:
                raise HTTPException(status_code=400, detail=f"Failed to download cover: {type(e).__name__}: {e}")

    return MessageResponse(message="No cover URL provided")


@router.post("/games/{game_id}/cover/upload")
async def upload_game_cover(
    game_id: int,
    file: UploadFile = File(...),
    session: AsyncSession = Depends(get_session),
):
    """Upload a cover image directly from a local file."""
    result = await session.execute(select(Game).where(Game.id == game_id))
    game = result.scalar_one_or_none()
    if game is None:
        raise HTTPException(status_code=404, detail="Game not found")

    # Validate file type
    import os
    ext = os.path.splitext(file.filename or "cover.jpg")[1].lower()
    if ext not in {".jpg", ".jpeg", ".png", ".gif", ".webp"}:
        raise HTTPException(status_code=400, detail="不支持的图片格式，仅支持 JPG/PNG/GIF/WebP")

    config = load_config()
    covers_dir = config.covers_path
    covers_dir.mkdir(parents=True, exist_ok=True)

    # Delete old cover if exists
    if game.cover_path and os.path.isfile(game.cover_path):
        try: os.remove(game.cover_path)
        except Exception: pass

    cover_path = covers_dir / f"{game_id}_upload{ext}"
    cover_path.write_bytes(await file.read())
    game.cover_path = str(cover_path)
    await session.commit()
    return {"message": "Cover uploaded", "cover_path": game.cover_path}


@router.delete("/games/{game_id}/cover", response_model=MessageResponse)
async def delete_game_cover(
    game_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Remove a game's cover image."""
    result = await session.execute(select(Game).where(Game.id == game_id))
    game = result.scalar_one_or_none()
    if game is None:
        raise HTTPException(status_code=404, detail="Game not found")

    if game.cover_path:
        import os
        if os.path.isfile(game.cover_path):
            os.remove(game.cover_path)
        game.cover_path = None
        await session.commit()

    return MessageResponse(message="Cover removed")


# --- Background image management ---

@router.post("/games/{game_id}/background", response_model=MessageResponse)
async def update_game_background(
    game_id: int,
    bg_url: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session),
):
    """Set a custom background image for a game. Pass ?bg_url=<url> to download."""
    result = await session.execute(select(Game).where(Game.id == game_id))
    game = result.scalar_one_or_none()
    if game is None:
        raise HTTPException(status_code=404, detail="Game not found")

    if bg_url:
        config = load_config()
        bg_dir = config.backgrounds_path
        bg_dir.mkdir(parents=True, exist_ok=True)
        ext = ".jpg" if ".jpg" in bg_url.lower() or ".jpeg" in bg_url.lower() else ".png"
        bg_path = bg_dir / f"{game_id}_bg{ext}"

        client_kwargs = {"timeout": httpx.Timeout(30.0)}
        if config.proxy:
            client_kwargs["proxy"] = config.proxy
        async with httpx.AsyncClient(**client_kwargs) as client:
            try:
                resp = await client.get(bg_url)
                resp.raise_for_status()
                bg_path.write_bytes(resp.content)
                game.bg_path = str(bg_path)
                await session.commit()
                return MessageResponse(message="Background updated from URL")
            except Exception as e:
                raise HTTPException(status_code=400, detail=f"Failed to download background: {e}")

    return MessageResponse(message="No background URL provided")


@router.delete("/games/{game_id}/background", response_model=MessageResponse)
async def delete_game_background(
    game_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Remove a game's custom background image."""
    result = await session.execute(select(Game).where(Game.id == game_id))
    game = result.scalar_one_or_none()
    if game is None:
        raise HTTPException(status_code=404, detail="Game not found")

    if game.bg_path:
        import os
        if os.path.isfile(game.bg_path):
            os.remove(game.bg_path)
        game.bg_path = None
        await session.commit()

    return MessageResponse(message="Background removed")

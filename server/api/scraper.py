"""Scraper API — manual and batch metadata scraping."""

from __future__ import annotations

import logging
import ipaddress
import socket
from pathlib import Path
from urllib.parse import urljoin, urlparse
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
from models.user import User
from api.auth import get_current_user, require_admin
from models.scrape_job import JobStatus, ScrapeJob
from schemas.common import MessageResponse
from services.scraper.orchestrator import (
    _apply_result,
    _build_scrapers,
    run_batch_scrape,
)
from services.scraper.base import rank_scraper_results

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["scraper"])


_MAX_REMOTE_IMAGE_BYTES = 20 * 1024 * 1024


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


def _validate_public_url(url: str) -> set[str]:
    """Reject non-HTTP(S) and internal/private URLs (SSRF prevention)."""
    from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeout
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise HTTPException(status_code=400, detail="仅支持 HTTP/HTTPS URL")
    if not parsed.hostname:
        raise HTTPException(status_code=400, detail="URL 缺少主机名")
    try:
        ip = ipaddress.ip_address(parsed.hostname)
        if _is_blocked_address(str(ip)):
            raise HTTPException(status_code=400, detail="不允许使用内网地址")
        return {str(parsed.hostname)}
    except ValueError:
        pass

    try:
        with ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(socket.getaddrinfo, parsed.hostname, None)
            addrs = future.result(timeout=3)
    except FuturesTimeout as exc:
        raise HTTPException(status_code=400, detail="URL 主机名解析超时") from exc
    except Exception as exc:
        raise HTTPException(status_code=400, detail="URL 主机名解析失败") from exc

    for addr in addrs:
        ip_str = addr[4][0]
        if _is_blocked_address(ip_str):
            raise HTTPException(status_code=400, detail="不允许使用内网地址")
    return {addr[4][0] for addr in addrs}


async def _safe_get(client: httpx.AsyncClient, url: str, **kwargs) -> httpx.Response:
    """Fetch a public URL and re-check every redirect target."""
    current = url
    for _ in range(6):
        allowed_addresses = _validate_public_url(current)
        resp = await client.get(current, follow_redirects=False, **kwargs)
        if len(resp.content) > _MAX_REMOTE_IMAGE_BYTES:
            raise HTTPException(status_code=413, detail="远程图片过大")
        # Resolve immediately before every request and reject a changed answer.
        # This closes the common DNS-rebinding window without trusting proxy headers.
        parsed = urlparse(current)
        if parsed.hostname and not _validate_public_url(current).intersection(allowed_addresses):
            raise HTTPException(status_code=400, detail="URL 主机解析发生变化")
        if resp.status_code not in {301, 302, 303, 307, 308}:
            return resp
        location = resp.headers.get("location")
        if not location:
            return resp
        current = urljoin(current, location)
    raise HTTPException(status_code=400, detail="URL 重定向次数过多")


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
    user: User = Depends(get_current_user),
):
    """Search a specific source and return all candidates."""
    config = load_config()
    scrapers = {s.source_name: s for s in _build_scrapers(config)}
    scraper = scrapers.get(source)
    if scraper is None:
        raise HTTPException(status_code=400, detail=f"Unknown source: {source}")

    try:
        results = rank_scraper_results(q, await scraper.search(q))
        return {
            "source": source,
            "query": q,
            "results": [
                {"title": r.title, "cover_url": r.cover_url, "hero_url": r.hero_url,
                 "screenshots": r.screenshot_urls,
                 "developer": r.developer,
                 "description": r.description, "release_date": r.release_date,
                 "is_nsfw": r.is_nsfw,
                 "source_id": r.source_id,
                 "tags": [
                     {
                         "name": tag.name,
                         "rating": tag.rating,
                         "is_spoiler": tag.is_spoiler,
                     }
                     for tag in r.tags
                 ]}
                for r in results
            ],
        }
    except Exception:
        raise HTTPException(status_code=500, detail="搜索失败，请查看服务端日志")
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
    is_nsfw: bool | None = None,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_admin),
):
    """Apply a specific scraper result to a game."""
    result = await session.execute(select(Game).where(Game.id == game_id))
    game = result.scalar_one_or_none()
    if game is None:
        raise HTTPException(status_code=404, detail="Game not found")

    config = load_config()
    client_kwargs = {"timeout": httpx.Timeout(30.0), "trust_env": False}
    if config.proxy:
        client_kwargs["proxy"] = config.proxy
    if cover_url or hero_url:
        async with httpx.AsyncClient(**client_kwargs) as c:
            if cover_url:
                try:
                    resp = await _safe_get(c, cover_url)
                    resp.raise_for_status()
                    cover_path = config.covers_path / f"{game_id}_{source}.jpg"
                    config.covers_path.mkdir(parents=True, exist_ok=True)
                    cover_path.write_bytes(resp.content)
                    game.cover_path = str(cover_path)
                except Exception as e:
                    logger.warning(f"Cover download failed: {e}")
            # Download hero/landscape banner to backgrounds folder
            if hero_url:
                try:
                    resp = await _safe_get(c, hero_url)
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
    if is_nsfw is True:
        game.is_nsfw = True
    sfx = ""
    sf = {
        "vndb_kana": "vndb_id",
        "vndb": "vndb_id",
        "bangumi": "bangumi_id",
        "steam": "steam_id",
        "hikarinagi": "hikarinagi_id",
    }
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
    user: User = Depends(require_admin),
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

    client_kwargs = {"timeout": httpx.Timeout(30.0), "trust_env": False}
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
                        "is_nsfw": result.is_nsfw,
                        "tags": [
                            {
                                "name": tag.name,
                                "rating": tag.rating,
                                "is_spoiler": tag.is_spoiler,
                            }
                            for tag in result.tags
                        ],
                    })

                    await _apply_result(
                        result,
                        scraper.source_name,
                        game,
                        client,
                        covers_dir,
                        session,
                        config,
                    )

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
    user: User = Depends(require_admin),
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
                    await run_batch_scrape(
                        config,
                        body.game_ids,
                        bg_session,
                        job,
                        sources=body.sources,
                        mode=body.mode,
                    )
            loop.run_until_complete(_work())
        except Exception as e:
            logger.error(f"Batch scrape job {job.id} failed: {e}", exc_info=True)
            error_message = str(e)

            async def _mark_failed():
                async with database._session_factory() as bg_session:
                    result = await bg_session.execute(
                        select(ScrapeJob).where(ScrapeJob.id == job.id)
                    )
                    failed_job = result.scalar_one_or_none()
                    if failed_job is not None:
                        failed_job.status = JobStatus.FAILED
                        failed_job.current_game = None
                        failed_job.log = f"批量刮削失败: {error_message}"
                        await bg_session.commit()

            try:
                loop.run_until_complete(_mark_failed())
            except Exception:
                logger.exception("Failed to mark batch scrape job as failed")
        finally:
            loop.close()

    threading.Thread(target=_run_thread, daemon=True).start()

    return {
        "job_id": job.id,
        "status": "started",
        "message": f"Batch scrape started for {job.total_games or 'all missing'} games",
    }


@router.post("/scrape/jobs/{job_id}/cancel")
async def cancel_scrape_job(job_id: int, session: AsyncSession = Depends(get_session), user: User = Depends(require_admin)):
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
async def list_scrape_jobs(session: AsyncSession = Depends(get_session), user: User = Depends(get_current_user)):
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
async def get_scrape_job(job_id: int, session: AsyncSession = Depends(get_session), user: User = Depends(get_current_user)):
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
    user: User = Depends(require_admin),
):
    """Update a game's cover via URL or mark it for manual update.

    Pass ?cover_url=<url> to download from a URL.
    """
    result = await session.execute(select(Game).where(Game.id == game_id))
    game = result.scalar_one_or_none()
    if game is None:
        raise HTTPException(status_code=404, detail="Game not found")

    if cover_url:
        config = load_config()
        covers_dir = config.covers_path
        covers_dir.mkdir(parents=True, exist_ok=True)
        ext = ".jpg"
        cover_path = covers_dir / f"{game_id}_manual{ext}"

        client_kwargs = {"timeout": httpx.Timeout(30.0), "trust_env": False}
        if config.proxy:
            client_kwargs["proxy"] = config.proxy
        async with httpx.AsyncClient(**client_kwargs) as client:
            try:
                resp = await _safe_get(client, cover_url)
                resp.raise_for_status()
                cover_path.write_bytes(resp.content)
                game.cover_path = str(cover_path)
                await session.commit()
                return {"message": "Cover updated", "cover_path": game.cover_path}
            except Exception as e:
                logger.warning(f"Cover download failed: {e}")
                raise HTTPException(status_code=400, detail="封面下载失败")

    return MessageResponse(message="No cover URL provided")


@router.post("/games/{game_id}/cover/upload")
async def upload_game_cover(
    game_id: int,
    file: UploadFile = File(...),
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_admin),
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

    # Delete old cover if exists (validate path is within covers dir)
    if game.cover_path:
        cover_path_obj = Path(game.cover_path)
        try:
            cover_path_obj.resolve().relative_to(config.covers_path.resolve())
        except ValueError:
            pass  # path outside covers dir — skip deletion
        else:
            if cover_path_obj.is_file():
                try: os.remove(str(cover_path_obj))
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
    user: User = Depends(require_admin),
):
    """Remove a game's cover image."""
    result = await session.execute(select(Game).where(Game.id == game_id))
    game = result.scalar_one_or_none()
    if game is None:
        raise HTTPException(status_code=404, detail="Game not found")

    if game.cover_path:
        import os
        config = load_config()
        cover_path = Path(game.cover_path)
        try:
            cover_path.resolve().relative_to(config.covers_path.resolve())
        except ValueError:
            pass  # path outside covers dir — skip deletion
        else:
            if cover_path.is_file():
                os.remove(str(cover_path))
        game.cover_path = None
        await session.commit()

    return MessageResponse(message="Cover removed")


# --- Background image management ---

@router.post("/games/{game_id}/background", response_model=MessageResponse)
async def update_game_background(
    game_id: int,
    bg_url: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_admin),
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
        from urllib.parse import urlparse
        _bg_url_path = urlparse(bg_url).path.lower()
        _ext_map = {".webp": ".webp", ".gif": ".gif", ".png": ".png", ".jpeg": ".jpg", ".jpg": ".jpg"}
        ext = next((v for k, v in _ext_map.items() if _bg_url_path.endswith(k)), ".jpg")
        bg_path = bg_dir / f"{game_id}_bg{ext}"

        client_kwargs = {"timeout": httpx.Timeout(30.0), "trust_env": False}
        if config.proxy:
            client_kwargs["proxy"] = config.proxy
        async with httpx.AsyncClient(**client_kwargs) as client:
            try:
                resp = await _safe_get(client, bg_url)
                resp.raise_for_status()
                bg_path.write_bytes(resp.content)
                game.bg_path = str(bg_path)
                await session.commit()
                return MessageResponse(message="Background updated from URL")
            except Exception as e:
                logger.warning(f"Background download failed: {e}")
                raise HTTPException(status_code=400, detail="背景下载失败")

    return MessageResponse(message="No background URL provided")


@router.post("/games/{game_id}/background/upload")
async def upload_game_background(
    game_id: int,
    file: UploadFile = File(...),
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_admin),
):
    """Upload a background/hero image directly from a local file."""
    result = await session.execute(select(Game).where(Game.id == game_id))
    game = result.scalar_one_or_none()
    if game is None:
        raise HTTPException(status_code=404, detail="Game not found")

    import os
    ext = os.path.splitext(file.filename or "bg.jpg")[1].lower()
    if ext not in {".jpg", ".jpeg", ".png", ".gif", ".webp"}:
        raise HTTPException(status_code=400, detail="不支持的图片格式，仅支持 JPG/PNG/GIF/WebP")

    config = load_config()
    bg_dir = config.backgrounds_path
    bg_dir.mkdir(parents=True, exist_ok=True)

    # Delete old background if exists (validate path is within backgrounds dir)
    if game.bg_path:
        bg_path_obj = Path(game.bg_path)
        try:
            bg_path_obj.resolve().relative_to(config.backgrounds_path.resolve())
        except ValueError:
            pass  # path outside backgrounds dir — skip deletion
        else:
            if bg_path_obj.is_file():
                try: os.remove(str(bg_path_obj))
                except Exception: pass

    bg_path = bg_dir / f"{game_id}_hero{ext}"
    bg_path.write_bytes(await file.read())
    game.bg_path = str(bg_path)
    await session.commit()
    return {"message": "Background uploaded", "bg_path": game.bg_path}


@router.delete("/games/{game_id}/background", response_model=MessageResponse)
async def delete_game_background(
    game_id: int,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_admin),
):
    """Remove a game's custom background image."""
    result = await session.execute(select(Game).where(Game.id == game_id))
    game = result.scalar_one_or_none()
    if game is None:
        raise HTTPException(status_code=404, detail="Game not found")

    if game.bg_path:
        import os
        config = load_config()
        bg_path = Path(game.bg_path)
        try:
            bg_path.resolve().relative_to(config.backgrounds_path.resolve())
        except ValueError:
            pass  # path outside backgrounds dir — skip deletion
        else:
            if bg_path.is_file():
                os.remove(str(bg_path))
        game.bg_path = None
        await session.commit()

    return MessageResponse(message="Background removed")

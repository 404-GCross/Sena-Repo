"""Importer — orchestrates scan → clean → DB insert for a root directory."""

from __future__ import annotations

import asyncio, logging
from datetime import datetime
from pathlib import Path

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from config import Config
from models.game import Company, Game, GameVersion, Platform, GameTag
from models.file_source import FileSource
from models.ignore_list import IgnoreList
from models.root_directory import RootDirectory
from models.tag import Tag
from services.cleaner import clean_filename, normalize_company_name, _clean_name
from services.file_source import adapter_from_source, canonical_source_path
from services.scanner import scan_root, scan_source, get_ignore_paths

logger = logging.getLogger(__name__)


async def import_from_root(
    root_id: int,
    config: Config,
    session: AsyncSession,
) -> dict:
    """Scan a root directory and import/update all discovered games.

    Returns:
        Dict with import statistics: {new_games, updated_games, new_versions, total}
    """
    # Load root directory record
    result = await session.execute(
        select(RootDirectory).where(RootDirectory.id == root_id)
    )
    root = result.scalar_one_or_none()
    if root is None:
        raise ValueError(f"Root directory with id {root_id} not found")

    ignore_paths = await get_ignore_paths(session)

    source_type = root.source_type or "local"
    source_path = root.source_path or root.path
    source_model = None
    if source_type == "openlist" and root.source_id:
        source_result = await session.execute(select(FileSource).where(FileSource.id == root.source_id))
        source_model = source_result.scalar_one_or_none()

    # Scan the filesystem/source in a thread pool so slow/remote storage doesn't block the event loop
    scan_structure = getattr(config, "_scan_structure", "company_game")
    if source_type == "local":
        scan_result = await asyncio.to_thread(scan_root, source_path, ignore_paths, scan_structure)
    else:
        adapter = adapter_from_source(source_model, source_type)
        scan_result = await asyncio.to_thread(scan_source, adapter, source_path, ignore_paths, scan_structure)

    stats = {"new_games": 0, "updated_games": 0, "new_versions": 0, "total": 0}

    for company_folder in scan_result.companies:
        # Upsert company
        company_name = normalize_company_name(company_folder.name)
        company = await _upsert_company(session, company_name)

        # Upsert company as a tag (auto-tag feature)
        company_tag = await _upsert_tag(session, company_name)

        for game_folder in company_folder.games:
            # Upsert game
            canonical_game_path = canonical_source_path(source_type, root.source_id, game_folder.path)
            game = await _upsert_game(
                session,
                name=game_folder.name,
                company_id=company.id,
                root_id=root.id,
                folder_path=canonical_game_path,
                developer=company_name,
            )

            version_count = 0
            for archive in game_folder.archives:
                # Clean filename to extract platform + name
                # Convert CustomRegex dataclass objects to dicts for the cleaner
                custom_patterns = [
                    {"pattern": r.pattern, "platform": r.platform}
                    for r in config.custom_regex
                    if r.pattern and r.platform
                ] if config.custom_regex else None

                extraction = clean_filename(
                    archive.filename,
                    custom_patterns,
                )

                if extraction is None:
                    logger.warning(f"Could not extract platform from: {archive.filename}")
                    continue

                # Upsert version
                created = await _upsert_version(
                    session,
                    game_id=game.id,
                    platform=extraction.platform,
                    filename=archive.filename,
                    file_path=canonical_source_path(source_type, root.source_id, archive.filepath),
                    file_size=archive.file_size,
                    source_type=source_type,
                    source_id=root.source_id,
                    source_path=archive.filepath,
                )
                if created:
                    version_count += 1

            # Auto-tag with company name
            await _ensure_game_tag(session, game.id, company_tag.id)

            stats["new_versions"] += version_count
            stats["total"] += 1

    # Detect orphaned games (exist in DB but folder no longer on disk)
    scanned_paths = {
        canonical_source_path(source_type, root.source_id, g.path)
        for c in scan_result.companies for g in c.games
    }
    all_games = await session.execute(
        select(Game).where(Game.root_id == root_id, Game.is_deleted == False)
    )
    orphans = 0
    for game in all_games.scalars().all():
        if game.folder_path and game.folder_path not in scanned_paths:
            if source_type != "local" or not Path(game.folder_path).exists():
                game.is_deleted = True
                game.updated_at = datetime.utcnow()
                orphans += 1
    if orphans:
        await session.flush()

    await session.commit()

    # Count total games from this root
    count_result = await session.execute(
        select(Game).where(Game.root_id == root_id, Game.is_deleted == False)
    )
    stats["total_games"] = len(count_result.scalars().all())
    stats["orphaned"] = orphans

    # Clean up companies that no longer have any games
    await cleanup_empty_companies(session)

    return stats


async def cleanup_empty_companies(session: AsyncSession) -> int:
    """Delete companies that have zero games after import/delete."""
    # Find companies with no non-deleted games
    sub = select(func.count(Game.id)).where(
        Game.company_id == Company.id,
        Game.is_deleted == False,
    ).correlate(Company).scalar_subquery()
    result = await session.execute(
        select(Company).where(sub == 0)
    )
    empty = result.scalars().all()
    for c in empty:
        await session.delete(c)
    if empty:
        await session.flush()
    return len(empty)


async def _upsert_company(session: AsyncSession, name: str) -> Company:
    """Get or create a Company by name."""
    result = await session.execute(
        select(Company).where(Company.name == name)
    )
    company = result.scalar_one_or_none()
    if company is None:
        company = Company(name=name)
        session.add(company)
        await session.flush()
    return company


async def _upsert_tag(session: AsyncSession, name: str) -> Tag:
    """Get or create a Tag by name."""
    result = await session.execute(
        select(Tag).where(Tag.name == name)
    )
    tag = result.scalar_one_or_none()
    if tag is None:
        tag = Tag(name=name)
        session.add(tag)
        await session.flush()
    return tag


async def _upsert_game(
    session: AsyncSession,
    name: str,
    company_id: int,
    root_id: int,
    folder_path: str,
    developer: str | None = None,
) -> Game:
    """Get or create a Game by folder_path (unique key)."""
    result = await session.execute(
        select(Game).where(Game.folder_path == folder_path)
    )
    game = result.scalar_one_or_none()
    clean_name = _clean_name(name)
    if game is None:
        game = Game(
            name=clean_name,
            company_id=company_id,
            root_id=root_id,
            folder_path=folder_path,
            developer=developer,
        )
        session.add(game)
        await session.flush()
    else:
        # Update fields if changed, restore if previously deleted
        game.name = clean_name
        game.company_id = company_id
        game.is_deleted = False
        if game.developer is None and developer:
            game.developer = developer
        game.updated_at = datetime.utcnow()
    return game


async def _upsert_version(
    session: AsyncSession,
    game_id: int,
    platform: Platform,
    filename: str,
    file_path: str,
    file_size: int,
    source_type: str = "local",
    source_id: int | None = None,
    source_path: str | None = None,
) -> bool:
    """Create a GameVersion if one with same file_path doesn't exist.
    Returns True if a new version was created.
    """
    result = await session.execute(
        select(GameVersion).where(GameVersion.file_path == file_path)
    )
    existing = result.scalar_one_or_none()
    if existing is not None:
        # Update size if changed
        existing.file_size = file_size
        existing.source_type = source_type
        existing.source_id = source_id
        existing.source_path = source_path or file_path
        return False

    version = GameVersion(
        game_id=game_id,
        platform=platform,
        filename=filename,
        file_path=file_path,
        source_type=source_type,
        source_id=source_id,
        source_path=source_path or file_path,
        file_size=file_size,
    )
    session.add(version)
    return True


async def _ensure_game_tag(session: AsyncSession, game_id: int, tag_id: int):
    """Ensure a game has a specific tag (no-op if already exists)."""
    result = await session.execute(
        select(GameTag).where(
            GameTag.game_id == game_id,
            GameTag.tag_id == tag_id,
        )
    )
    if result.scalar_one_or_none() is None:
        session.add(GameTag(game_id=game_id, tag_id=tag_id))

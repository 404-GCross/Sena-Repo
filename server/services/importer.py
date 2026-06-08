"""Importer — orchestrates scan → clean → DB insert for a root directory."""

from __future__ import annotations

import logging
from datetime import datetime
from pathlib import Path

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from config import Config
from models.game import Company, Game, GameVersion, Platform, GameTag
from models.ignore_list import IgnoreList
from models.root_directory import RootDirectory
from models.tag import Tag
from services.cleaner import clean_filename, normalize_company_name, _clean_name
from services.scanner import scan_root, get_ignore_paths

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

    # Scan the filesystem
    scan_result = scan_root(root.path, ignore_paths)

    stats = {"new_games": 0, "updated_games": 0, "new_versions": 0, "total": 0}

    for company_folder in scan_result.companies:
        # Upsert company
        company_name = normalize_company_name(company_folder.name)
        company = await _upsert_company(session, company_name)

        # Upsert company as a tag (auto-tag feature)
        company_tag = await _upsert_tag(session, company_name)

        for game_folder in company_folder.games:
            # Upsert game
            game = await _upsert_game(
                session,
                name=game_folder.name,
                company_id=company.id,
                root_id=root.id,
                folder_path=game_folder.path,
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
                    file_path=archive.filepath,
                    file_size=archive.file_size,
                )
                if created:
                    version_count += 1

            # Auto-tag with company name
            await _ensure_game_tag(session, game.id, company_tag.id)

            stats["new_versions"] += version_count
            stats["total"] += 1

    await session.commit()

    # Count total games from this root
    count_result = await session.execute(
        select(Game).where(Game.root_id == root_id, Game.is_deleted == False)
    )
    stats["total_games"] = len(count_result.scalars().all())

    return stats


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
        )
        session.add(game)
        await session.flush()
    else:
        # Update fields if changed
        game.name = clean_name
        game.company_id = company_id
        game.updated_at = datetime.utcnow()
    return game


async def _upsert_version(
    session: AsyncSession,
    game_id: int,
    platform: Platform,
    filename: str,
    file_path: str,
    file_size: int,
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
        return False

    version = GameVersion(
        game_id=game_id,
        platform=platform,
        filename=filename,
        file_path=file_path,
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

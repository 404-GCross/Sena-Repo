"""Directory scanner — walks root directories to find companies, games, and archives."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from models.ignore_list import IgnoreList
from utils.file_utils import is_archive


@dataclass
class ArchiveFile:
    filename: str
    filepath: str
    file_size: int


@dataclass
class GameFolder:
    name: str
    path: str
    archives: list[ArchiveFile] = field(default_factory=list)


@dataclass
class CompanyFolder:
    name: str
    path: str
    games: list[GameFolder] = field(default_factory=list)


@dataclass
class ScanResult:
    root_path: str
    companies: list[CompanyFolder] = field(default_factory=list)


async def get_ignore_paths(session: AsyncSession) -> set[str]:
    """Get all paths currently in the ignore list."""
    result = await session.execute(select(IgnoreList.path))
    return {row[0] for row in result.fetchall()}


def scan_root(root_path: str, ignore_paths: set[str] | None = None) -> ScanResult:
    """Walk a root directory and discover the 3-level structure.

    Level 1 → Company folders
    Level 2 → Game folders
    Level 3 → Archive files

    Args:
        root_path: Absolute path to the root directory.
        ignore_paths: Set of paths to skip (from ignore list).

    Returns:
        ScanResult with the discovered structure.
    """
    if ignore_paths is None:
        ignore_paths = set()

    result = ScanResult(root_path=root_path)
    root = Path(root_path)

    if not root.is_dir():
        return result

    # Level 1: Company folders
    for company_entry in sorted(root.iterdir()):
        if not company_entry.is_dir():
            continue

        company = CompanyFolder(name=company_entry.name, path=str(company_entry))

        # Level 2: Game folders
        for game_entry in sorted(company_entry.iterdir()):
            if not game_entry.is_dir():
                continue

            game_path_str = str(game_entry)
            if game_path_str in ignore_paths:
                continue

            game = GameFolder(name=game_entry.name, path=game_path_str)

            # Level 3: Archive files
            for file_entry in sorted(game_entry.iterdir()):
                if file_entry.is_file() and is_archive(file_entry.name):
                    game.archives.append(
                        ArchiveFile(
                            filename=file_entry.name,
                            filepath=str(file_entry),
                            file_size=file_entry.stat().st_size,
                        )
                    )

            # Only include games that have at least one archive
            if game.archives:
                company.games.append(game)

        if company.games:
            result.companies.append(company)

    return result

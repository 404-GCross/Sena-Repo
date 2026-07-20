"""Directory scanner — walks root directories to find companies, games, and archives."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from models.ignore_list import IgnoreList
from utils.file_utils import is_archive
from services.file_source import FileSourceAdapter


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


def scan_root(
    root_path: str,
    ignore_paths: set[str] | None = None,
    structure: str = "company_game",
) -> ScanResult:
    """Walk a root directory and discover the 3-level structure.

    Level 1 → Company folders
    Level 2 → Game folders
    Level 3 → Archive files

    Args:
        root_path: Absolute path to the root directory.
        ignore_paths: Set of paths to skip (from ignore list).
        structure: Directory layout. One of company_game, game_only, flat.

    Returns:
        ScanResult with the discovered structure.
    """
    if ignore_paths is None:
        ignore_paths = set()

    result = ScanResult(root_path=root_path)
    root = Path(root_path)

    if not root.is_dir():
        return result

    if structure == "game_only":
        company = CompanyFolder(name=root.name, path=str(root))

        for entry in sorted(root.iterdir()):
            entry_path = str(entry)
            if entry_path in ignore_paths:
                continue

            if entry.is_file() and is_archive(entry.name):
                game = GameFolder(name=entry.stem, path=entry_path)
                game.archives.append(
                    ArchiveFile(
                        filename=entry.name,
                        filepath=entry_path,
                        file_size=entry.stat().st_size,
                    )
                )
                company.games.append(game)
                continue

            if not entry.is_dir():
                continue

            game = GameFolder(name=entry.name, path=entry_path)
            for file_entry in sorted(entry.rglob("*")):
                file_path = str(file_entry)
                if file_path in ignore_paths:
                    continue
                if file_entry.is_file() and is_archive(file_entry.name):
                    game.archives.append(
                        ArchiveFile(
                            filename=file_entry.name,
                            filepath=file_path,
                            file_size=file_entry.stat().st_size,
                        )
                    )
            if game.archives:
                company.games.append(game)

        if company.games:
            result.companies.append(company)
        return result

    if structure == "flat":
        company = CompanyFolder(name=root.name, path=str(root))
        for file_entry in sorted(root.rglob("*")):
            file_path = str(file_entry)
            if file_path in ignore_paths:
                continue
            if file_entry.is_file() and is_archive(file_entry.name):
                game = GameFolder(name=file_entry.stem, path=file_path)
                game.archives.append(
                    ArchiveFile(
                        filename=file_entry.name,
                        filepath=file_path,
                        file_size=file_entry.stat().st_size,
                    )
                )
                company.games.append(game)
        if company.games:
            result.companies.append(company)
        return result

    # Level 1: Company folders
    for company_entry in sorted(root.iterdir()):
        if not company_entry.is_dir():
            continue

        company = CompanyFolder(name=company_entry.name, path=str(company_entry))

        # Archives directly in company folder → each becomes its own game
        for file_entry in sorted(company_entry.iterdir()):
            if file_entry.is_file() and is_archive(file_entry.name):
                # Use file path as virtual folder path for uniqueness
                game_path_str = str(file_entry)
                if game_path_str not in ignore_paths:
                    game = GameFolder(name=file_entry.stem, path=game_path_str)
                    game.archives.append(
                        ArchiveFile(
                            filename=file_entry.name,
                            filepath=str(file_entry),
                            file_size=file_entry.stat().st_size,
                        )
                    )
                    company.games.append(game)

        # Level 2: Game folders
        for game_entry in sorted(company_entry.iterdir()):
            if not game_entry.is_dir():
                continue

            game_path_str = str(game_entry)
            if game_path_str in ignore_paths:
                continue

            game = GameFolder(name=game_entry.name, path=game_path_str)

            # Level 3+: Archive files (recursive, find them anywhere inside game folder)
            for file_entry in sorted(game_entry.rglob("*")):
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


def scan_source(
    source: FileSourceAdapter,
    root_path: str,
    ignore_paths: set[str] | None = None,
    structure: str = "company_game",
) -> ScanResult:
    """Scan a generic file source and return the same structure as scan_root."""
    if ignore_paths is None:
        ignore_paths = set()

    result = ScanResult(root_path=root_path)

    def children(path: str) -> list:
        return source.list(path)

    def archives_recursive(path: str) -> list[ArchiveFile]:
        found: list[ArchiveFile] = []
        stack = [path]
        while stack:
            current = stack.pop()
            for entry in children(current):
                if entry.path in ignore_paths:
                    continue
                if entry.is_dir:
                    stack.append(entry.path)
                elif is_archive(entry.name):
                    found.append(ArchiveFile(entry.name, entry.path, entry.size))
        found.sort(key=lambda a: a.filepath.lower())
        return found

    root_entries = children(root_path)

    if structure == "game_only":
        company = CompanyFolder(name=Path(root_path).name or root_path.strip("/") or "OpenList", path=root_path)
        for entry in root_entries:
            if entry.path in ignore_paths:
                continue
            if not entry.is_dir and is_archive(entry.name):
                company.games.append(
                    GameFolder(entry.name.rsplit(".", 1)[0], entry.path, [ArchiveFile(entry.name, entry.path, entry.size)])
                )
            elif entry.is_dir:
                archives = archives_recursive(entry.path)
                if archives:
                    company.games.append(GameFolder(entry.name, entry.path, archives))
        if company.games:
            result.companies.append(company)
        return result

    if structure == "flat":
        company = CompanyFolder(name=Path(root_path).name or root_path.strip("/") or "OpenList", path=root_path)
        for archive in archives_recursive(root_path):
            company.games.append(GameFolder(archive.filename.rsplit(".", 1)[0], archive.filepath, [archive]))
        if company.games:
            result.companies.append(company)
        return result

    for company_entry in root_entries:
        if not company_entry.is_dir:
            continue
        company = CompanyFolder(name=company_entry.name, path=company_entry.path)
        for entry in children(company_entry.path):
            if entry.path in ignore_paths:
                continue
            if not entry.is_dir and is_archive(entry.name):
                company.games.append(
                    GameFolder(entry.name.rsplit(".", 1)[0], entry.path, [ArchiveFile(entry.name, entry.path, entry.size)])
                )
            elif entry.is_dir:
                archives = archives_recursive(entry.path)
                if archives:
                    company.games.append(GameFolder(entry.name, entry.path, archives))
        if company.games:
            result.companies.append(company)

    return result

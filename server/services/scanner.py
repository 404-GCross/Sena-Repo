"""Directory scanner: discovers companies, games, and archives."""

from __future__ import annotations

from utils.log_redaction import redact_exception

import logging
import stat
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Callable

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from models.ignore_list import IgnoreList
from services.file_source import FileEntry, FileSourceAdapter, SourceUnavailable, local_entries, local_files
from services.task_stop import checkpoint
from utils.file_utils import is_archive

logger = logging.getLogger(__name__)

MAX_GAME_DEPTH = 8


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


def normalize_game_depth(
    structure: str = "company_game",
    game_depth: int | None = None,
) -> int:
    """Resolve new game_depth while keeping old scan_structure values working."""
    if game_depth is None:
        return {"flat": 0, "game_only": 1}.get(structure, 2)
    try:
        depth = int(game_depth)
    except (TypeError, ValueError):
        return {"flat": 0, "game_only": 1}.get(structure, 2)
    return max(0, min(depth, MAX_GAME_DEPTH))


def structure_from_depth(game_depth: int) -> str:
    if game_depth <= 0:
        return "flat"
    if game_depth == 1:
        return "game_only"
    return "company_game"


def scan_root(
    root_path: str,
    ignore_paths: set[str] | None = None,
    structure: str = "company_game",
    game_depth: int | None = None,
) -> ScanResult:
    """Walk a local root and discover games by directory depth.

    game_depth:
      0 = flat archives under root
      1 = root/game/archive
      2 = root/company/game/archive
      3+ = root/.../company/game/archive
    """
    ignore_paths = ignore_paths or set()
    result = ScanResult(root_path=root_path)
    root = Path(root_path)
    depth = normalize_game_depth(structure, game_depth)

    if depth == 0:
        company = CompanyFolder(name=root.name or str(root), path=str(root))
        for archive in _local_archives_recursive(root, ignore_paths):
            company.games.append(
                GameFolder(
                    name=Path(archive.filename).stem,
                    path=archive.filepath,
                    archives=[archive],
                )
            )
        if company.games:
            result.companies.append(company)
        return result

    companies: dict[str, CompanyFolder] = {}

    for game_dir in _local_dirs_at_depth(root, depth, ignore_paths):
        archives = _local_archives_recursive(game_dir, ignore_paths)
        if archives:
            company = _local_company_for_game(root, game_dir, depth, companies)
            company.games.append(
                GameFolder(name=game_dir.name, path=str(game_dir), archives=archives)
            )

    # Backward compatibility: archives directly under the parent level still
    # become individual games, as the old company_game scanner allowed.
    for parent_dir in _local_dirs_at_depth(root, max(0, depth - 1), ignore_paths):
        for file_entry, info in local_entries(parent_dir):
            file_path = str(file_entry)
            if file_path in ignore_paths:
                continue
            if not stat.S_ISREG(info.st_mode) or not is_archive(file_entry.name):
                continue
            company = _local_company_for_archive_parent(root, parent_dir, depth, companies)
            company.games.append(
                GameFolder(
                    name=file_entry.stem,
                    path=file_path,
                    archives=[ArchiveFile(file_entry.name, file_path, info.st_size)],
                )
            )

    result.companies.extend(companies.values())
    return result


def scan_source(
    source: FileSourceAdapter,
    root_path: str,
    ignore_paths: set[str] | None = None,
    structure: str = "company_game",
    game_depth: int | None = None,
) -> ScanResult:
    """Scan a generic file source and return the same structure as scan_root."""
    ignore_paths = ignore_paths or set()
    result = ScanResult(root_path=root_path)
    depth = normalize_game_depth(structure, game_depth)

    listings: dict[str, list[FileEntry]] = {}
    def children(path: str) -> list[FileEntry]:
        checkpoint()
        try:
            if path not in listings:
                listings[path] = source.list(path)
            return listings[path]
        except Exception as exc:
            logger.warning("Failed to list source path %s: %s", path, redact_exception(exc))
            # Returning an empty list here would look like "the folder is gone"
            # and the importer would mark every game under it as deleted.
            raise SourceUnavailable("网盘目录枚举不完整，请检查来源后重试") from exc

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

    if depth == 0:
        company = CompanyFolder(name=_source_basename(root_path), path=root_path)
        for archive in archives_recursive(root_path):
            company.games.append(
                GameFolder(
                    name=archive.filename.rsplit(".", 1)[0],
                    path=archive.filepath,
                    archives=[archive],
                )
            )
        if company.games:
            result.companies.append(company)
        return result

    companies: dict[str, CompanyFolder] = {}

    for game_entry in _source_dirs_at_depth(root_path, depth, children):
        if game_entry.path in ignore_paths:
            continue
        archives = archives_recursive(game_entry.path)
        if archives:
            company = _source_company_for_game(root_path, game_entry.path, depth, companies)
            company.games.append(GameFolder(game_entry.name, game_entry.path, archives))

    for parent_entry in _source_dirs_at_depth(root_path, max(0, depth - 1), children):
        for entry in children(parent_entry.path):
            if entry.path in ignore_paths:
                continue
            if entry.is_dir or not is_archive(entry.name):
                continue
            company = _source_company_for_archive_parent(root_path, parent_entry.path, depth, companies)
            company.games.append(
                GameFolder(
                    name=entry.name.rsplit(".", 1)[0],
                    path=entry.path,
                    archives=[ArchiveFile(entry.name, entry.path, entry.size)],
                )
            )

    result.companies.extend(companies.values())
    return result


def _local_archives_recursive(path: Path, ignore_paths: set[str]) -> list[ArchiveFile]:
    archives = [
        ArchiveFile(entry.name, str(entry), info.st_size)
        for entry, info in local_files(path, ignore_paths)
        if is_archive(entry.name)
    ]
    return sorted(archives, key=lambda a: a.filepath.lower())


def _local_dirs_at_depth(root: Path, depth: int, ignore_paths: set[str]) -> list[Path]:
    if depth == 0:
        return [root]
    current = [root]
    for _ in range(depth):
        next_dirs: list[Path] = []
        for directory in current:
            checkpoint()
            for entry, info in local_entries(directory):
                if str(entry) in ignore_paths:
                    continue
                if stat.S_ISDIR(info.st_mode):
                    next_dirs.append(entry)
        current = next_dirs
        if not current:
            break
    return current


def _local_company_for_game(
    root: Path,
    game_dir: Path,
    depth: int,
    companies: dict[str, CompanyFolder],
) -> CompanyFolder:
    if depth <= 1:
        path = str(root)
        name = root.name or str(root)
    else:
        path = str(game_dir.parent)
        name = game_dir.parent.name
    return companies.setdefault(path, CompanyFolder(name=name, path=path))


def _local_company_for_archive_parent(
    root: Path,
    parent_dir: Path,
    depth: int,
    companies: dict[str, CompanyFolder],
) -> CompanyFolder:
    if depth <= 1:
        path = str(root)
        name = root.name or str(root)
    else:
        path = str(parent_dir)
        name = parent_dir.name
    return companies.setdefault(path, CompanyFolder(name=name, path=path))


def _source_basename(path: str) -> str:
    clean = path.rstrip("/")
    if not clean:
        return "OpenList"
    return PurePosixPath(clean).name or clean.strip("/") or "OpenList"


def _source_parent_path(path: str) -> str:
    clean = path.rstrip("/")
    if not clean or clean == "/":
        return "/"
    parent = clean.rsplit("/", 1)[0]
    return parent or "/"


def _source_dirs_at_depth(
    root_path: str,
    depth: int,
    children: Callable[[str], list[FileEntry]],
) -> list[FileEntry]:
    if depth == 0:
        return [FileEntry(name=_source_basename(root_path), path=root_path, is_dir=True)]
    current = [FileEntry(name=_source_basename(root_path), path=root_path, is_dir=True)]
    for _ in range(depth):
        next_dirs: list[FileEntry] = []
        for directory in current:
            next_dirs.extend(entry for entry in children(directory.path) if entry.is_dir)
        current = next_dirs
        if not current:
            break
    return current


def _source_company_for_game(
    root_path: str,
    game_path: str,
    depth: int,
    companies: dict[str, CompanyFolder],
) -> CompanyFolder:
    if depth <= 1:
        path = root_path
        name = _source_basename(root_path)
    else:
        path = _source_parent_path(game_path)
        name = _source_basename(path)
    return companies.setdefault(path, CompanyFolder(name=name, path=path))


def _source_company_for_archive_parent(
    root_path: str,
    parent_path: str,
    depth: int,
    companies: dict[str, CompanyFolder],
) -> CompanyFolder:
    if depth <= 1:
        path = root_path
        name = _source_basename(root_path)
    else:
        path = parent_path
        name = _source_basename(parent_path)
    return companies.setdefault(path, CompanyFolder(name=name, path=path))

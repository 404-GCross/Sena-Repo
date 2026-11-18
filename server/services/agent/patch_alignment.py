"""Validate client inventories and derive copy-only candidates for one patch."""

from collections import defaultdict
import hashlib
from pathlib import PurePosixPath
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, field_validator

from services.agent.inventory import relative_path

PathList = Annotated[
    list[Annotated[str, Field(min_length=1, max_length=512)]], Field(max_length=30000)
]


class PatchInventories(BaseModel):
    model_config = ConfigDict(extra="forbid")
    app_id: str = Field(pattern=r"^[1-9][0-9]{0,9}$")
    sha256: str | None = Field(default=None, pattern=r"^[a-f0-9]{64}$")
    archive_files: PathList = Field(default_factory=list)
    game_files: PathList
    game_dirs: PathList

    @field_validator("archive_files", "game_files", "game_dirs")
    @classmethod
    def safe_paths(cls, paths):
        if any(
            relative_path(p) != p or len(p.split("/")) > 32 or not p.isprintable()
            for p in paths
        ):
            raise ValueError("清单必须是安全的相对路径")
        if sum(map(len, paths)) > 2_000_000:
            raise ValueError("目录清单过大")
        return paths


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def copy_candidate(data: PatchInventories):
    files = set(data.archive_files)
    if (
        not files
        or not data.game_files
        or any(
            PurePosixPath(p).suffix.lower()
            in {
                ".exe",
                ".msi",
                ".cmd",
                ".bat",
                ".ps1",
                ".lnk",
                ".sh",
                ".reg",
                ".zip",
                ".7z",
                ".rar",
            }
            for p in files
        )
    ):
        return None
    payload = sorted(
        p
        for p in files
        if PurePosixPath(p).suffix.lower()
        not in {".txt", ".md", ".pdf", ".html", ".htm"}
    )
    if not payload:
        return None
    game = set(data.game_files)
    by_name = defaultdict(list)
    for p in game:
        by_name[p.rsplit("/", 1)[-1]].append(p)
    dirs = set(data.game_dirs) | {""}
    for p in game:
        dirs.update(str(d) for d in PurePosixPath(p).parents if str(d) != ".")
    srcs = [""]
    for parent in reversed(PurePosixPath(payload[0]).parents):
        s = str(parent)
        if s != "." and all(p.startswith(s + "/") for p in payload):
            srcs.append(s)
    best = {}
    for src in srcs:
        relative = [p[len(src) + 1 :] if src else p for p in payload]
        votes = defaultdict(set)
        for rel in relative:
            name = rel.rsplit("/", 1)[-1]
            found = by_name[name]
            if len(found) == 1 and name.lower() not in {
                "steam_api.dll",
                "steam_api64.dll",
                "patch.xp3",
                "data.xp3",
                "data.pac",
                "assembly-csharp.dll",
            }:
                p = found[0]
                if p == rel or p.endswith("/" + rel):
                    votes[p[: -len(rel)].rstrip("/")].add(p)
        # A game-specific Unity data directory is useful for all-new payload files.
        first = relative[0].split("/")[0]
        if (
            first.lower().endswith("_data")
            and len(first) > 7
            and first in dirs
            and all(p.startswith(first + "/") for p in relative)
        ):
            votes[""].add(first + "/")
        for dest, anchors in votes.items():
            if dest not in dirs or not (
                len(anchors) >= 2 or any(p.endswith("/") for p in anchors)
            ):
                continue
            # Equivalent strip/preserve mappings write the same relative payload paths.
            key = (dest + "/" if dest else "") + relative[0]
            candidate = (len(anchors), src, dest, sorted(anchors)[:12])
            if key not in best or best[key][0] < len(anchors):
                best[key] = candidate
    if len(best) != 1:
        return None
    _, src, dest, anchors = next(iter(best.values()))
    return {"patch_dir": src, "target_dir": dest, "anchors": anchors}

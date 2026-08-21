"""Steam patch injection API - PC client feature.

Reads patches.json in the patch directory for patch index.
Falls back to bare file scanning if no patches.json exists.
"""
from __future__ import annotations

import asyncio, json, logging, re, shutil, subprocess, tempfile, zipfile
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import joinedload
from sqlalchemy.ext.asyncio import AsyncSession

from config import load_config
from database import get_session
from models.user import User
from models.file_source import FileSource, SteamPatchRoot
from api.auth import get_current_user, require_admin
from services.file_source import adapter_from_source, normalize_base_url, normalize_remote_path

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/steam", tags=["steam-patch"])


def _get_patches_dir(config=None):
    if config is None:
        config = load_config()
    return Path(config.patch_dir or "/steam_patch")


async def _patch_roots(session: AsyncSession) -> list[SteamPatchRoot]:
    result = await session.execute(select(SteamPatchRoot).order_by(SteamPatchRoot.id))
    roots = result.scalars().all()
    if roots:
        return roots
    config = load_config()
    default_dir = str(_get_patches_dir(config))
    return [SteamPatchRoot(id=0, source_type="local", path=default_dir)]


class PatchRootCreate(BaseModel):
    path: str = Field(min_length=1, max_length=1024)
    source_type: str = "local"
    source_id: int | None = None
    source_name: str | None = None
    base_url: str | None = None
    username: str | None = None
    password: str | None = None


class PatchRootOut(BaseModel):
    id: int
    path: str
    source_type: str = "local"
    source_id: int | None = None
    source_name: str | None = None

    model_config = {"from_attributes": True}


@router.get("/patch-roots", response_model=list[PatchRootOut])
async def list_patch_roots(user: User = Depends(require_admin), session: AsyncSession = Depends(get_session)):
    return await _patch_roots(session)


@router.post("/patch-roots", response_model=PatchRootOut, status_code=201)
async def add_patch_root(
    body: PatchRootCreate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    source_type = body.source_type if body.source_type in {"local", "openlist"} else "local"
    source_id = body.source_id
    source_name = body.source_name
    path = body.path if source_type == "local" else normalize_remote_path(body.path)
    if source_type == "openlist":
        source = None
        if source_id:
            result = await session.execute(select(FileSource).where(FileSource.id == source_id))
            source = result.scalar_one_or_none()
            if source is None:
                raise HTTPException(status_code=404, detail="OpenList source not found")
        else:
            if not body.base_url:
                raise HTTPException(status_code=400, detail="OpenList URL is required")
            source = FileSource(
                name=source_name or body.base_url,
                type="openlist",
                base_url=normalize_base_url(body.base_url),
                username=body.username,
                password=body.password or "",
            )
            session.add(source)
            await session.flush()
            source_id = source.id
        adapter = adapter_from_source(source, "openlist")
        if not await asyncio.to_thread(adapter.exists, path):
            raise HTTPException(status_code=404, detail="OpenList path not found")
        source_name = source.name
    root = SteamPatchRoot(source_type=source_type, source_id=source_id, source_name=source_name, path=path)
    session.add(root)
    await session.commit()
    await session.refresh(root)
    return root


@router.put("/patch-roots/{root_id}", response_model=PatchRootOut)
async def update_patch_root(
    root_id: int,
    body: PatchRootCreate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    result = await session.execute(select(SteamPatchRoot).where(SteamPatchRoot.id == root_id))
    root = result.scalar_one_or_none()
    if root is None:
        raise HTTPException(status_code=404, detail="Patch root not found")

    source_type = body.source_type if body.source_type in {"local", "openlist"} else "local"
    source_id = body.source_id
    source_name = body.source_name
    path = body.path if source_type == "local" else normalize_remote_path(body.path)
    if source_type == "openlist":
        source = None
        if source_id:
            result = await session.execute(select(FileSource).where(FileSource.id == source_id))
            source = result.scalar_one_or_none()
            if source is None:
                raise HTTPException(status_code=404, detail="OpenList source not found")
        else:
            if not body.base_url:
                raise HTTPException(status_code=400, detail="OpenList source must be selected first")
            source = FileSource(
                name=source_name or body.base_url,
                type="openlist",
                base_url=normalize_base_url(body.base_url),
                username=body.username,
                password=body.password or "",
            )
            session.add(source)
            await session.flush()
            source_id = source.id
        adapter = adapter_from_source(source, "openlist")
        if not await asyncio.to_thread(adapter.exists, path):
            raise HTTPException(status_code=404, detail="OpenList path not found")
        source_name = source.name

    root.source_type = source_type
    root.source_id = source_id
    root.source_name = source_name
    root.path = path
    await session.commit()
    await session.refresh(root)
    return root


@router.delete("/patch-roots/{root_id}")
async def delete_patch_root(root_id: int, user: User = Depends(require_admin), session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(SteamPatchRoot).where(SteamPatchRoot.id == root_id))
    root = result.scalar_one_or_none()
    if root is None:
        raise HTTPException(status_code=404, detail="Patch root not found")
    await session.delete(root)
    await session.commit()
    return {"message": "Patch root removed"}


def _load_patches_index(patches_dir: Path) -> dict[str, dict] | None:
    """Load patches.json; returns dict keyed by app_id string (only for patches with valid app_id)."""
    idx_path = patches_dir / "patches.json"
    if not idx_path.is_file():
        return None
    try:
        with open(idx_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        patches = data.get("patches", [])
        idx = {}
        for p in patches:
            aid = p.get("app_id")
            if aid is not None and str(aid) != "None" and aid != 0:
                idx[str(aid)] = p
        return idx
    except Exception:
        return None


def _load_all_patches(patches_dir: Path) -> list[dict]:
    """Load ALL patches from patches.json, including those with null app_id."""
    idx_path = patches_dir / "patches.json"
    if not idx_path.is_file():
        return []
    try:
        with open(idx_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data.get("patches", [])
    except Exception:
        return []


def _patches_index_needs_autoscan(json_path: Path) -> bool:
    if not json_path.is_file():
        return True
    try:
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return False
    for patch in data.get("patches", []):
        if patch.get("source_type") == "openlist" and not patch.get("size"):
            return True
    return False


# Patch-type keyword matching

_KEYWORD_VERSION = 1  # bump when DEFAULT_TYPE_KEYWORDS changes to force migration

DEFAULT_TYPE_KEYWORDS = {
    "translation": ["_Steam_Chinese_Patch"],
    "voice": ["_Steam_Voice_Patch"],
    "story": ["_Steam_Story_Patch"],
    "extra": ["_Steam_Extra_Patch"],
    "misc": [],
}


def _get_type_keywords_path(patches_dir: Path) -> Path:
    return patches_dir / "patch_type_keywords.json"


def _load_type_keywords(patches_dir: Path) -> dict[str, list[str]]:
    """Load patch_type_keywords.json; create/overwrite with defaults if missing or outdated."""
    kw_path = _get_type_keywords_path(patches_dir)
    if kw_path.is_file():
        try:
            with open(kw_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict) and data.get("_version") == _KEYWORD_VERSION:
                return {k: v for k, v in data.items() if k != "_version" and isinstance(v, list)}
        except Exception:
            pass
    # Create / overwrite with current defaults
    patches_dir.mkdir(parents=True, exist_ok=True)
    defaults = {"_version": _KEYWORD_VERSION, **DEFAULT_TYPE_KEYWORDS}
    with open(kw_path, "w", encoding="utf-8") as f:
        json.dump(defaults, f, ensure_ascii=False, indent=2)
    return dict(DEFAULT_TYPE_KEYWORDS)


def _guess_type_by_keywords(filename: str, keywords: dict[str, list[str]]) -> str | None:
    """Match filename (case-insensitive) against keyword dict; return first matching type."""
    lower = filename.lower()
    for ptype, words in keywords.items():
        if ptype == "misc":
            continue
        for w in words:
            if w.lower() in lower:
                return ptype
    return None


def _save_type_keywords(patches_dir: Path, keywords: dict[str, list[str]]):
    patches_dir.mkdir(parents=True, exist_ok=True)
    data = {"_version": _KEYWORD_VERSION, **keywords}
    with open(_get_type_keywords_path(patches_dir), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


_MAX_TREE_ENTRIES = 2500
_MAX_OPENLIST_TREE_SCAN_BYTES = 2 * 1024 * 1024 * 1024


def _patch_lookup_matches(patch: dict, lookup_key: str) -> bool:
    if str(patch.get("app_id", "")) == lookup_key:
        return True
    if patch.get("file", "") == lookup_key:
        return True
    if patch.get("display_file", "") == lookup_key:
        return True
    return False


def _find_patch_entry(patches_dir: Path, lookup_key: str) -> dict | None:
    for patch in _load_all_patches(patches_dir):
        if _patch_lookup_matches(patch, lookup_key):
            return patch
    index = _load_patches_index(patches_dir)
    if index and lookup_key in index:
        return index[lookup_key]
    fallback = _find_patch_fallback(patches_dir, lookup_key)
    if fallback:
        return {
            "app_id": lookup_key,
            "file": fallback.name,
            "source_type": "local",
            "source_path": str(fallback),
            "size": fallback.stat().st_size,
        }
    return None


def _update_patch_record(
    patches_dir: Path,
    lookup_key: str,
    values: dict,
    file_hint: str | None = None,
) -> dict:
    json_path = patches_dir / "patches.json"
    if not json_path.is_file():
        raise HTTPException(status_code=404, detail="patches.json not found")
    try:
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        raise HTTPException(status_code=400, detail="patches.json 格式错误")

    patches = data.get("patches", [])
    for patch in patches:
        matched = _patch_lookup_matches(patch, lookup_key)
        if not matched and file_hint and patch.get("file", "") == file_hint:
            matched = True
        if not matched:
            continue
        for key, value in values.items():
            if value is None:
                continue
            if key == "app_id" and value != "":
                patch[key] = int(value) if str(value).isdigit() else value
            elif key != "app_id":
                patch[key] = value
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        return patch

    raise HTTPException(status_code=404, detail=f"未找到补丁: {lookup_key}")


def _is_relative_safe_archive_path(path: str) -> bool:
    cleaned = path.replace("\\", "/").strip()
    if not cleaned or cleaned.startswith("/"):
        return False
    if re.match(r"^[A-Za-z]:", cleaned):
        return False
    return ".." not in [part for part in cleaned.split("/") if part]


def _safe_archive_member_path(path: str) -> str:
    cleaned = path.replace("\\", "/").strip()
    while cleaned.startswith("./"):
        cleaned = cleaned[2:]
    return cleaned.rstrip("/") if cleaned != "/" else ""


def _seven_zip_executable() -> str | None:
    for name in ("7zz", "7z", "7za"):
        exe = shutil.which(name)
        if exe:
            return exe
    return None


def _parse_7z_slt(output: str, archive_path: Path) -> tuple[list[dict], list[dict]]:
    raw_entries: list[dict] = []
    current: dict[str, str] = {}

    def flush():
        if not current:
            return
        path = _safe_archive_member_path(current.get("Path", ""))
        if not path or path == str(archive_path):
            current.clear()
            return
        size_text = current.get("Size", "0")
        try:
            size = int(size_text) if size_text else 0
        except ValueError:
            size = 0
        is_dir = current.get("Folder") == "+" or path.endswith("/")
        raw_entries.append({"path": path, "type": "dir" if is_dir else "file", "size": size})
        current.clear()

    for line in output.splitlines():
        if not line.strip():
            flush()
            continue
        if " = " not in line:
            continue
        key, value = line.split(" = ", 1)
        current[key] = value
    flush()
    return _build_archive_tree(raw_entries)


def _list_zip_entries(archive_path: Path) -> tuple[list[dict], list[dict]]:
    raw_entries = []
    with zipfile.ZipFile(archive_path) as zf:
        for info in zf.infolist():
            path = _safe_archive_member_path(info.filename)
            if not path:
                continue
            raw_entries.append({
                "path": path,
                "type": "dir" if info.is_dir() else "file",
                "size": 0 if info.is_dir() else info.file_size,
            })
    return _build_archive_tree(raw_entries)


def _list_archive_entries(archive_path: Path) -> dict:
    tree: list[dict]
    risks: list[dict]
    exe = _seven_zip_executable()
    if exe:
        proc = subprocess.run(
            [exe, "l", "-slt", "-p-", str(archive_path)],
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        if proc.returncode != 0:
            message = (proc.stderr or proc.stdout or "Archive listing failed").strip()
            raise HTTPException(status_code=422, detail=message[-500:])
        tree, risks = _parse_7z_slt(proc.stdout, archive_path)
    elif archive_path.suffix.lower() == ".zip":
        tree, risks = _list_zip_entries(archive_path)
    else:
        raise HTTPException(status_code=501, detail="Server archive listing tool is not installed")

    file_count = sum(1 for item in tree if item["type"] == "file")
    dir_count = sum(1 for item in tree if item["type"] == "dir")
    total_size = sum(int(item.get("size") or 0) for item in tree if item["type"] == "file")
    top_dirs = {
        item["path"].split("/", 1)[0]
        for item in tree
        if item["path"] and "/" in item["path"]
    }
    top_files = [
        item
        for item in tree
        if item["type"] == "file" and "/" not in item["path"]
    ]
    recommended_patch_dir = ""
    if len(top_dirs) == 1 and not top_files:
        recommended_patch_dir = next(iter(top_dirs))
        risks.append({
            "level": "warning",
            "code": "single_outer_dir",
            "message": f"检测到单一外层目录 {recommended_patch_dir}，建议作为补丁内容根目录。",
        })
    if len(tree) >= _MAX_TREE_ENTRIES:
        risks.append({
            "level": "warning",
            "code": "tree_truncated",
            "message": f"目录树仅返回前 {_MAX_TREE_ENTRIES} 项。",
        })
    return {
        "archive_type": archive_path.suffix.lower().lstrip("."),
        "file_count": file_count,
        "dir_count": dir_count,
        "total_uncompressed_size": total_size,
        "recommended": {
            "patch_dir": recommended_patch_dir,
            "target_dir": "",
            "strip_components": 1 if recommended_patch_dir else 0,
            "target_mode": "game_root",
        },
        "risks": risks,
        "tree": tree[:_MAX_TREE_ENTRIES],
        "truncated": len(tree) > _MAX_TREE_ENTRIES,
    }


def _build_archive_tree(raw_entries: list[dict]) -> tuple[list[dict], list[dict]]:
    nodes: dict[str, dict] = {}
    risks: list[dict] = []
    invalid_count = 0
    for entry in raw_entries:
        path = _safe_archive_member_path(entry.get("path", ""))
        if not _is_relative_safe_archive_path(path):
            invalid_count += 1
            continue
        parts = [part for part in path.split("/") if part]
        for index in range(1, len(parts)):
            dir_path = "/".join(parts[:index])
            nodes.setdefault(
                dir_path,
                {"path": dir_path, "name": parts[index - 1], "type": "dir", "size": 0, "depth": index - 1},
            )
        is_dir = entry.get("type") == "dir"
        nodes[path] = {
            "path": path,
            "name": parts[-1] if parts else path,
            "type": "dir" if is_dir else "file",
            "size": 0 if is_dir else int(entry.get("size") or 0),
            "depth": max(0, len(parts) - 1),
        }
    if invalid_count:
        risks.append({
            "level": "danger",
            "code": "unsafe_paths",
            "message": f"忽略 {invalid_count} 个不安全路径。",
        })
    tree = sorted(nodes.values(), key=lambda item: (item["path"].lower(), item["type"] != "dir"))
    return tree, risks


async def _local_patch_file_from_entry(
    entry: dict,
    patches_dir: Path,
    session: AsyncSession,
) -> Path | None:
    roots = await _patch_roots(session)
    allowed_roots = [patches_dir.resolve()]
    for root in roots:
        if root.source_type == "local":
            allowed_roots.append(Path(root.path).resolve())

    for raw in (entry.get("source_path"), entry.get("file")):
        if not raw:
            continue
        candidate = Path(str(raw))
        if not candidate.is_absolute():
            candidate = patches_dir / candidate
        try:
            resolved = candidate.resolve()
        except OSError:
            continue
        if not resolved.is_file():
            continue
        for root in allowed_roots:
            try:
                resolved.relative_to(root)
                return resolved
            except ValueError:
                continue
    return None


async def _download_openlist_patch_to_temp(entry: dict, session: AsyncSession) -> Path:
    size = int(entry.get("size") or 0)
    if size > _MAX_OPENLIST_TREE_SCAN_BYTES:
        raise HTTPException(status_code=413, detail="Patch archive is too large for server-side tree scan")
    result = await session.execute(select(FileSource).where(FileSource.id == entry.get("source_id")))
    source = result.scalar_one_or_none()
    if source is None:
        raise HTTPException(status_code=404, detail="OpenList source not found")
    adapter = adapter_from_source(source, "openlist")
    raw_url = await asyncio.to_thread(adapter.download_url, entry.get("source_path") or entry.get("file", ""))
    suffix = Path(entry.get("source_path") or entry.get("file") or "patch").suffix
    fd, temp_name = tempfile.mkstemp(prefix="sena_patch_tree_", suffix=suffix)
    temp_path = Path(temp_name)
    bytes_read = 0
    try:
        import httpx
        with open(fd, "wb", closefd=True) as out:
            try:
                with httpx.stream("GET", raw_url, follow_redirects=True, timeout=httpx.Timeout(120.0, connect=15.0)) as resp:
                    if resp.status_code >= 400:
                        raise HTTPException(status_code=502, detail=f"OpenList download failed: {resp.status_code}")
                    for chunk in resp.iter_bytes(1024 * 1024):
                        if not chunk:
                            continue
                        bytes_read += len(chunk)
                        if bytes_read > _MAX_OPENLIST_TREE_SCAN_BYTES:
                            raise HTTPException(status_code=413, detail="Patch archive is too large for server-side tree scan")
                        out.write(chunk)
            except httpx.HTTPError as exc:
                raise HTTPException(status_code=502, detail="OpenList download request failed") from exc
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise
    return temp_path


# Models

class SteamGameInfo(BaseModel):
    app_id: str
    name: str
    install_dir: str


class PatchMatch(BaseModel):
    app_id: str
    game_name: str
    install_dir: str
    patch_available: bool
    patch_filename: str | None = None
    patch_size: int = 0
    patch_dir: str | None = None
    target_dir: str | None = None
    label: str | None = None
    type: str | None = None  # translation/voice/story/extra/misc


class ScanRequest(BaseModel):
    games: list[SteamGameInfo]


class PatchRuleUpdate(BaseModel):
    patch_dir: str = ""
    target_dir: str = ""
    strip_components: int = Field(default=0, ge=0, le=16)
    target_mode: str = "game_root"
    app_id: str | None = None
    file: str | None = None


# Endpoints

@router.post("/scan", response_model=list[PatchMatch])
async def scan_steam_games(
    body: ScanRequest,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    config = load_config()
    patches_dir = _get_patches_dir(config)
    index = _load_patches_index(patches_dir)
    keywords = _load_type_keywords(patches_dir)
    results = []

    for game in body.games:
        match = PatchMatch(
            app_id=game.app_id,
            game_name=game.name,
            install_dir=game.install_dir,
            patch_available=False,
        )

        if not patches_dir.exists():
            results.append(match)
            continue

        # 1. Try patches.json index
        if index and game.app_id in index:
            entry = index[game.app_id]
            if entry.get("source_type") == "openlist":
                match.patch_available = True
                match.patch_filename = (entry.get("display_file") or entry.get("source_path") or entry.get("file", "")).split("/")[-1]
                match.patch_size = int(entry.get("size") or 0)
                match.patch_dir = entry.get("patch_dir", "")
                match.target_dir = entry.get("target_dir", "")
                match.label = entry.get("label", "")
                if entry.get("game_name"):
                    match.game_name = entry["game_name"]
                match.type = entry.get("type", "misc") or "misc"
                results.append(match)
                continue
            patch_file = await _local_patch_file_from_entry(entry, patches_dir, session)
            if patch_file and patch_file.is_file():
                match.patch_available = True
                match.patch_filename = patch_file.name
                match.patch_size = patch_file.stat().st_size
                match.patch_dir = entry.get("patch_dir", "")
                match.target_dir = entry.get("target_dir", "")
                match.label = entry.get("label", "")
                # Use game_name from patches.json if available (Chinese name from Steam)
                if entry.get("game_name"):
                    match.game_name = entry["game_name"]
                # Type: keep existing if already set (non-misc), else keyword-guess
                existing_type = entry.get("type", "misc")
                if existing_type and existing_type != "misc":
                    match.type = existing_type
                else:
                    guessed = _guess_type_by_keywords(match.patch_filename or "", keywords)
                    match.type = guessed or existing_type or "misc"
                results.append(match)
                continue

        # 2. Fallback: bare file scan
        patch_file = _find_patch_fallback(patches_dir, game.app_id)
        if patch_file:
            match.patch_available = True
            match.patch_filename = patch_file.name
            match.patch_size = patch_file.stat().st_size
            # Keyword guess for bare files
            guessed = _guess_type_by_keywords(patch_file.name, keywords)
            if guessed:
                match.type = guessed

        results.append(match)

    return results


@router.get("/patches")
async def list_patches(session: AsyncSession = Depends(get_session), user: User = Depends(get_current_user)):
    """List indexed patches. Scanning is explicit via /scan-patches."""
    patches_dir = _get_patches_dir()
    patches_dir.mkdir(parents=True, exist_ok=True)
    json_path = patches_dir / "patches.json"
    needs_scan = _patches_index_needs_autoscan(json_path)
    patches = _load_all_patches(patches_dir)

    # Match patches without app_id to games in DB by name
    if patches:
        try:
            from models.game import Game as _Game
            result = await session.execute(
                select(_Game).where(_Game.is_deleted == False).options(joinedload(_Game.company))
            )
            games = result.unique().scalars().all()

            for p in patches:
                aid = p.get("app_id")
                if aid is not None and str(aid) != "None" and aid != 0:
                    continue
                filename = p.get("file", "").split("/")[-1]
                for game in games:
                    if game.name and game.name.lower() in filename.lower():
                        p["app_id"] = game.id
                        p["matched_game"] = game.name
                        p["matched_company"] = game.company.name if game.company else None
                        break
        except Exception:
            pass

    return {
        "patches": patches,
        "count": len(patches),
        "source": "patches.json",
        "needs_scan": needs_scan,
    }


@router.get("/patches/{lookup_key}/tree")
async def get_patch_tree(
    lookup_key: str,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    patches_dir = _get_patches_dir()
    entry = _find_patch_entry(patches_dir, lookup_key)
    if entry is None:
        raise HTTPException(status_code=404, detail=f"未找到补丁: {lookup_key}")

    temp_path: Path | None = None
    source_type = entry.get("source_type") or "local"
    try:
        if source_type == "openlist":
            temp_path = await _download_openlist_patch_to_temp(entry, session)
            archive_path = temp_path
        else:
            archive_path = await _local_patch_file_from_entry(entry, patches_dir, session)
            if archive_path is None:
                raise HTTPException(status_code=404, detail="Patch archive file not found")

        tree_data = await asyncio.to_thread(_list_archive_entries, archive_path)
        filename = (entry.get("display_file") or entry.get("source_path") or entry.get("file") or archive_path.name).split("/")[-1]
        return {
            "lookup_key": lookup_key,
            "file": entry.get("file") or filename,
            "display_file": entry.get("display_file") or filename,
            "source_type": source_type,
            "size": int(entry.get("size") or (archive_path.stat().st_size if archive_path.exists() else 0)),
            "app_id": str(entry.get("app_id") or ""),
            "game_name": entry.get("game_name") or entry.get("label") or "",
            "patch_dir": entry.get("patch_dir") or "",
            "target_dir": entry.get("target_dir") or "",
            "strip_components": int(entry.get("strip_components") or 0),
            "target_mode": entry.get("target_mode") or "game_root",
            **tree_data,
        }
    finally:
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)


@router.put("/patches/{lookup_key}/rules")
async def update_patch_rules(
    lookup_key: str,
    body: PatchRuleUpdate,
    user: User = Depends(require_admin),
):
    patches_dir = _get_patches_dir()
    updated = _update_patch_record(
        patches_dir,
        lookup_key,
        {
            "patch_dir": body.patch_dir.strip().strip("/"),
            "target_dir": body.target_dir.strip().strip("/"),
            "strip_components": body.strip_components,
            "target_mode": body.target_mode or "game_root",
            "app_id": body.app_id,
        },
        file_hint=body.file,
    )
    return {"message": "Rules updated", "lookup_key": lookup_key, "patch": updated}


@router.get("/patches/{app_id}/download")
async def download_patch(
    app_id: str,
    request: Request,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    patches_dir = _get_patches_dir()

    index = _load_patches_index(patches_dir)
    if index and app_id in index:
        entry = index[app_id]
        if entry.get("source_type") == "openlist":
            result = await session.execute(select(FileSource).where(FileSource.id == entry.get("source_id")))
            source = result.scalar_one_or_none()
            adapter = adapter_from_source(source, "openlist")
            raw_url = await asyncio.to_thread(adapter.download_url, entry.get("source_path") or entry.get("file", ""))
            from fastapi.responses import RedirectResponse
            return RedirectResponse(raw_url, status_code=302)
        patch_file = await _local_patch_file_from_entry(entry, patches_dir, session)
        if patch_file and patch_file.is_file():
            return FileResponse(
                path=str(patch_file),
                filename=patch_file.name,
                media_type="application/octet-stream",
                headers={"Accept-Ranges": "bytes"},
            )

    if not patches_dir.exists():
        raise HTTPException(status_code=404, detail="Patch directory not found")
    patch_file = _find_patch_fallback(patches_dir, app_id)
    if patch_file is None:
        raise HTTPException(status_code=404, detail=f"Patch file for App ID {app_id} not found")
    return FileResponse(
        path=str(patch_file),
        filename=patch_file.name,
        media_type="application/octet-stream",
        headers={"Accept-Ranges": "bytes"},
    )

class PatchUpdate(BaseModel):
    patch_dir: str | None = None
    target_dir: str | None = None
    label: str | None = None
    type: str | None = None
    strip_components: int | None = Field(default=None, ge=0, le=16)
    target_mode: str | None = None
    app_id: str | None = None  # new app_id to update
    file: str | None = None    # lookup by file path if app_id is None/unknown


@router.put("/patches/{lookup_key}")
async def update_patch(lookup_key: str, body: PatchUpdate, user: User = Depends(require_admin)):
    """Update patch metadata in patches.json. lookup_key can be app_id or file path."""
    patches_dir = _get_patches_dir()
    updated = _update_patch_record(
        patches_dir,
        lookup_key,
        {
            "patch_dir": body.patch_dir,
            "target_dir": body.target_dir,
            "label": body.label,
            "type": body.type,
            "strip_components": body.strip_components,
            "target_mode": body.target_mode,
            "app_id": body.app_id,
        },
        file_hint=body.file,
    )
    return {"message": "Updated", "lookup_key": lookup_key, "patch": updated}


# Patch scan endpoint

@router.post("/scan-patches")
async def scan_patches_endpoint(user: User = Depends(require_admin), session: AsyncSession = Depends(get_session)):
    """Re-scan all configured patch roots and regenerate patches.json."""
    index_dir = _get_patches_dir()
    index_dir.mkdir(parents=True, exist_ok=True)
    try:
        from scan_patches import scan_patches_dir, scan_patches_source, load_existing, merge

        scanned = []
        roots = await _patch_roots(session)
        for root in roots:
            if root.source_type == "openlist":
                result = await session.execute(select(FileSource).where(FileSource.id == root.source_id))
                source = result.scalar_one_or_none()
                adapter = adapter_from_source(source, "openlist")
                scanned.extend(await asyncio.to_thread(scan_patches_source, adapter, root.path, "openlist", root.source_id))
                continue

            root_path = Path(root.path)
            local_scanned = await asyncio.to_thread(scan_patches_dir, root_path)
            for item in local_scanned:
                item["source_type"] = "local"
                item["source_id"] = None
                item["source_path"] = str(root_path / item["file"])
                if root_path.resolve() != index_dir.resolve():
                    item["file"] = str(root_path / item["file"])
            scanned.extend(local_scanned)

        json_path = index_dir / "patches.json"
        existing = load_existing(json_path)
        existing_list = existing.get("patches", []) if existing else []
        merged_patches = merge(existing_list, scanned)
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump({"patches": merged_patches}, f, ensure_ascii=False, indent=2)
        return {"message": "扫描完成", "scanned": len(scanned), "directory": str(index_dir)}
    except Exception as e:
        logger.error(f"Patch scan failed: {e}")
        raise HTTPException(status_code=500, detail="Patch scan failed; check server logs")

# Patch type keywords API

@router.get("/patch-type-keywords")
async def get_type_keywords(user: User = Depends(get_current_user)):
    """Return patch_type_keywords.json content."""
    patches_dir = _get_patches_dir()
    return _load_type_keywords(patches_dir)


class TypeKeywordsUpdate(BaseModel):
    keywords: dict[str, list[str]]


@router.put("/patch-type-keywords")
async def update_type_keywords(body: TypeKeywordsUpdate, user: User = Depends(require_admin)):
    """Overwrite patch_type_keywords.json (admin only)."""
    patches_dir = _get_patches_dir()
    _save_type_keywords(patches_dir, body.keywords)
    return {"message": "关键词已更新"}


def _find_patch_fallback(patches_dir: Path, app_id: str) -> Path | None:
    # Only use basename of app_id to prevent path traversal
    safe_name = Path(app_id.replace("\\", "/")).name
    if not safe_name or safe_name in (".", ".."):
        return None
    for ext in (".zip", ".rar", ".7z", ".tar", ".gz"):
        candidate = patches_dir / f"{safe_name}{ext}"
        if candidate.is_file():
            return candidate
    app_dir = patches_dir / safe_name
    if app_dir.is_dir():
        for ext in (".zip", ".rar", ".7z"):
            for f in app_dir.iterdir():
                if f.is_file() and f.suffix.lower() == ext:
                    return f
    return None


# Patch ID re-scrape

class RescrapeResult(BaseModel):
    lookup_key: str
    file: str = ""
    old_app_id: str = ""
    new_app_id: str = ""
    game_name: str = ""
    status: str = ""  # "updated" / "skipped" / "not_found" / "error"


@router.post("/patches/{lookup_key}/rescrape")
async def rescrape_patch(lookup_key: str, user: User = Depends(require_admin)):
    """Re-search Steam for a single patch's app_id and update patches.json."""
    import asyncio as _asyncio
    patches_dir = _get_patches_dir()
    json_path = patches_dir / "patches.json"

    if not json_path.is_file():
        raise HTTPException(status_code=404, detail="patches.json not found")

    try:
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        raise HTTPException(status_code=400, detail="patches.json 格式错误")

    patches = data.get("patches", [])
    target = None
    for p in patches:
        if str(p.get("app_id", "")) == lookup_key:
            target = p; break
        if p.get("file", "") == lookup_key:
            target = p; break

    if target is None:
        raise HTTPException(status_code=404, detail=f"未找到补丁: {lookup_key}")

    old_app_id = str(target.get("app_id", "") or "")
    filename = target.get("file", "").split("/")[-1]
    from scan_patches import _extract_game_name, _search_steam_app_id, _fetch_game_name
    game_name_candidate = _extract_game_name(filename)

    try:
        new_id = await _asyncio.to_thread(_search_steam_app_id, game_name_candidate)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Steam API 查询失败: {e}")

    result = RescrapeResult(
        lookup_key=lookup_key,
        file=filename,
        old_app_id=old_app_id,
        status="not_found",
    )

    if new_id:
        target["app_id"] = new_id
        result.new_app_id = str(new_id)
        result.status = "updated"
        # Also fetch game name
        try:
            name = await _asyncio.to_thread(_fetch_game_name, new_id)
            if name:
                target["game_name"] = name
                result.game_name = name
        except Exception:
            pass
    elif old_app_id:
        result.status = "skipped"
        result.new_app_id = old_app_id

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

    return result


@router.post("/patches/rescrape-all")
async def rescrape_all_patches(user: User = Depends(require_admin)):
    """Re-search Steam for all patches' app_ids (batch)."""
    import asyncio as _asyncio
    patches_dir = _get_patches_dir()
    json_path = patches_dir / "patches.json"

    if not json_path.is_file():
        raise HTTPException(status_code=404, detail="patches.json not found")

    try:
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        raise HTTPException(status_code=400, detail="patches.json 格式错误")

    patches = data.get("patches", [])
    from scan_patches import _extract_game_name, _search_steam_app_id, _fetch_game_name

    results: list[RescrapeResult] = []

    async def rescrape_one(p: dict) -> RescrapeResult:
        filename = p.get("file", "").split("/")[-1]
        old_id = str(p.get("app_id", "") or "")
        lookup = old_id or p.get("file", "")
        game_name_candidate = _extract_game_name(filename)

        r = RescrapeResult(lookup_key=lookup, file=filename, old_app_id=old_id)

        if not game_name_candidate:
            r.status = "skipped"
            return r

        try:
            new_id = await _asyncio.to_thread(_search_steam_app_id, game_name_candidate)
        except Exception:
            r.status = "error"
            return r

        if new_id:
            p["app_id"] = new_id
            r.new_app_id = str(new_id)
            r.status = "updated"
            try:
                name = await _asyncio.to_thread(_fetch_game_name, new_id)
                if name:
                    p["game_name"] = name
                    r.game_name = name
            except Exception:
                pass
        elif old_id:
            r.new_app_id = old_id
            r.status = "skipped"
        else:
            r.status = "not_found"

        return r

    tasks = [rescrape_one(p) for p in patches]
    results = await _asyncio.gather(*tasks)
    updated = sum(1 for r in results if r.status == "updated")

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

    return {"message": f"Batch rescrape completed: {updated} updated", "updated": updated, "total": len(patches), "results": [r.model_dump() for r in results]}


# Steam game name resolution

class AppIdList(BaseModel):
    appids: list[str]


@router.post("/game-names")
async def get_game_names(body: AppIdList, user: User = Depends(get_current_user)):
    """Resolve Steam AppIDs to Chinese game names via Store API."""
    import httpx
    import asyncio

    results: dict[str, str] = {}
    sem = asyncio.Semaphore(5)

    async def resolve(appid: str):
        async with sem:
            try:
                async with httpx.AsyncClient(timeout=httpx.Timeout(10.0)) as client:
                    for lang in ("schinese", "english"):
                        resp = await client.get(
                            f"https://store.steampowered.com/api/appdetails?appids={appid}&l={lang}"
                        )
                        if resp.status_code == 200:
                            data = resp.json()
                            details = (data.get(str(appid)) or {}).get("data") or {}
                            name = details.get("name", "")
                            if name:
                                results[appid] = name
                                return
            except Exception:
                pass

    tasks = [resolve(a) for a in body.appids]
    await asyncio.gather(*tasks)
    return results

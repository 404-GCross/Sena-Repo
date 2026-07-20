"""Scan steam_patches directory and generate/update patches.json template.

Usage:
  python scan_patches.py                           # scan, generate template
  python scan_patches.py --dir /path/to/patches    # custom dir
  python scan_patches.py --add 123456 v2.zip "汉化补丁" "data" "汉化 v2" "translation"
                                                        # add one entry
"""
import json, os, sys, argparse, re
from pathlib import Path

# Default keywords for auto type detection (mirrors steam_patch.py)
_KEYWORD_VERSION = 1  # bump when DEFAULT_TYPE_KEYWORDS changes to force migration

DEFAULT_TYPE_KEYWORDS = {
    "translation": ["_Steam_Chinese_Patch"],
    "voice": ["_Steam_Voice_Patch"],
    "story": ["_Steam_Story_Patch"],
    "extra": ["_Steam_Extra_Patch"],
    "misc": [],
}

# Suffix patterns to strip when extracting game name from filename
_NAME_STRIP_PATTERNS = [
    r"_Steam_.*_Patch",      # _Steam_Chinese_Patch, _Steam_extra_Patch
    r"_steam_.*_patch",
    r"_Steam_Patch",
    r"_steam_patch",
    r"_Patch$",
    r"_patch$",
    r"_Steam$",
    r"_steam$",
    r"\[Steam\]",
    r"\[steam\]",
]


def _load_keywords(base_dir: Path) -> dict[str, list[str]]:
    kw_path = base_dir / "patch_type_keywords.json"
    if kw_path.is_file():
        try:
            with open(kw_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict) and data.get("_version") == _KEYWORD_VERSION:
                return {k: v for k, v in data.items() if k != "_version" and isinstance(v, list)}
        except Exception:
            pass
    # Create / overwrite with current defaults
    base_dir.mkdir(parents=True, exist_ok=True)
    defaults = {"_version": _KEYWORD_VERSION, **DEFAULT_TYPE_KEYWORDS}
    with open(kw_path, "w", encoding="utf-8") as f:
        json.dump(defaults, f, ensure_ascii=False, indent=2)
    return dict(DEFAULT_TYPE_KEYWORDS)


def _guess_type(filename: str, keywords: dict[str, list[str]]) -> str:
    """Case-insensitive keyword match against filename; return type or 'misc'."""
    lower = filename.lower()
    for ptype, words in keywords.items():
        if ptype == "misc":
            continue
        for w in words:
            if w.lower() in lower:
                return ptype
    return "misc"


def _extract_game_name(filename: str) -> str:
    """Extract a candidate game name by stripping type suffixes and extension."""
    name = filename
    # Remove file extension
    for ext in (".zip", ".ZIP", ".rar", ".RAR", ".7z", ".7Z", ".tar", ".TAR", ".gz", ".GZ", ".xz", ".XZ"):
        if name.endswith(ext):
            name = name[:-len(ext)]
            break
    # Strip known Steam/patch patterns
    for pattern in _NAME_STRIP_PATTERNS:
        name = re.sub(pattern, "", name, flags=re.IGNORECASE)
    # Clean up separators
    name = name.replace("_", " ").replace("  ", " ").strip()
    return name


def _search_steam_app_id(game_name: str) -> int | None:
    """Search Steam store for a game by name and return its app_id."""
    import urllib.request
    import urllib.parse
    try:
        url = "https://store.steampowered.com/api/storesearch/?term=" + urllib.parse.quote(game_name) + "&l=schinese&cc=CN"
        req = urllib.request.Request(url, headers={"User-Agent": "Sena-Repo/1.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
        items = data.get("items", [])
        if items:
            # Return the first match's app_id
            return items[0].get("id")
    except Exception:
        pass
    return None


def _fetch_game_name(app_id: int) -> str:
    """Fetch game name from Steam Store API by app_id. Prefers schinese, falls back to english."""
    import urllib.request
    try:
        for lang in ("schinese", "english"):
            url = f"https://store.steampowered.com/api/appdetails?appids={app_id}&l={lang}"
            req = urllib.request.Request(url, headers={"User-Agent": "Sena-Repo/1.0"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read())
            details = (data.get(str(app_id)) or {}).get("data") or {}
            name = details.get("name", "")
            if name:
                return name
    except Exception:
        pass
    return ""


def _guess_app_id(rel_path: str, filename: str = "") -> int | None:
    """Try to get app_id from filename (numeric ID) or Steam search (game name)."""
    name = rel_path.split("/")[-1]

    # Try numeric extraction from filename: 123456.zip
    m = re.match(r"^(\d{3,8})\..+$", name)
    if m:
        return int(m.group(1))

    # Try numeric from parent folder: 123456/v2.zip
    parent = rel_path.split("/")[0] if "/" in rel_path else ""
    m = re.match(r"^(\d{3,8})$", parent)
    if m:
        return int(m.group(1))

    # Steam search by game name
    search_name = filename or name
    game_name = _extract_game_name(search_name)
    if game_name:
        return _search_steam_app_id(game_name)

    return None


def scan_patches_dir(base_dir: Path) -> list[dict]:
    """Scan recurisvely for archive files, auto-detect app_id and type from name."""
    base_dir.mkdir(parents=True, exist_ok=True)
    keywords = _load_keywords(base_dir)
    archives = []
    exts = (".zip", ".ZIP", ".rar", ".RAR", ".7z", ".7Z", ".tar", ".TAR", ".gz", ".GZ", ".xz", ".XZ")
    for ext in exts:
        for f in sorted(base_dir.rglob(f"*{ext}")):
            rel = str(f.relative_to(base_dir)).replace("\\", "/")
            app_id = _guess_app_id(rel, f.name)
            ptype = _guess_type(f.name, keywords)
            # Use extracted game name as label if available
            label = _extract_game_name(f.name) if not app_id else ""
            archives.append({
                "app_id": app_id,
                "file": rel,
                "patch_dir": "",
                "target_dir": "",
                "label": label,
                "type": ptype,
                "game_name": _fetch_game_name(app_id) if app_id else "",
            })
    return archives


def scan_patches_source(source, root_path: str, source_type: str = "local", source_id: int | None = None) -> list[dict]:
    """Scan a generic file source for patch archive files."""
    from services.file_source import canonical_source_path

    keywords = dict(DEFAULT_TYPE_KEYWORDS)
    archives = []
    exts = (".zip", ".rar", ".7z", ".tar", ".gz", ".xz")
    root = root_path.rstrip("/")
    stack = [root_path]
    while stack:
        current = stack.pop()
        for entry in source.list(current):
            if entry.is_dir:
                stack.append(entry.path)
                continue
            if not entry.name.lower().endswith(exts):
                continue
            rel = entry.path[len(root):].lstrip("/") if entry.path.startswith(root) else entry.name
            app_id = _guess_app_id(rel, entry.name)
            ptype = _guess_type(entry.name, keywords)
            label = _extract_game_name(entry.name) if not app_id else ""
            archives.append({
                "app_id": app_id,
                "file": canonical_source_path(source_type, source_id, entry.path),
                "source_type": source_type,
                "source_id": source_id,
                "source_path": entry.path,
                "display_file": rel,
                "patch_dir": "",
                "target_dir": "",
                "label": label,
                "type": ptype,
                "game_name": _fetch_game_name(app_id) if app_id else "",
            })
    archives.sort(key=lambda p: p.get("file", ""))
    return archives


def load_existing(json_path: Path) -> dict | None:
    if json_path.exists():
        try:
            with open(json_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return None


def merge(existing_patches: list[dict], scanned: list[dict]) -> list[dict]:
    """Keep user-filled fields from existing, add new files."""
    existing_by_file = {}
    for p in existing_patches:
        existing_by_file[p.get("file", "")] = p

    merged = []
    for s in scanned:
        old = existing_by_file.get(s["file"])
        if old:
            # Keep user's manual entries but update discovered fields
            if not old.get("app_id") and s.get("app_id"):
                old["app_id"] = s["app_id"]
            if not old.get("type") or old.get("type") == "misc":
                if s.get("type") and s["type"] != "misc":
                    old["type"] = s["type"]
            if not old.get("game_name") and s.get("game_name"):
                old["game_name"] = s["game_name"]
            merged.append(old)
        else:
            merged.append(s)

    return merged


def main():
    parser = argparse.ArgumentParser(description="Manage patches.json")
    parser.add_argument("--dir", type=str, help="Patch directory path")
    parser.add_argument("--add", nargs=6, metavar=("APP_ID", "FILE", "PATCH_DIR", "TARGET_DIR", "LABEL", "TYPE"),
                        help="Add a single entry (type: translation/voice/story/extra/misc)")
    args = parser.parse_args()

    base_dir = Path(args.dir) if args.dir else Path(__file__).parent / "steam_patches"

    if args.add:
        app_id, file_path, patch_dir, target_dir, label, ptype = args.add
        json_path = base_dir / "patches.json"
        existing = load_existing(json_path)
        patches = existing.get("patches", []) if existing else []
        patches.append({
            "app_id": int(app_id),
            "file": file_path,
            "patch_dir": patch_dir,
            "target_dir": target_dir,
            "label": label,
            "type": ptype,
        })
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump({"patches": patches}, f, ensure_ascii=False, indent=2)
        print(f"已添加: {file_path}")
        return

    # Scan mode
    json_path = base_dir / "patches.json"
    scanned = scan_patches_dir(base_dir)

    if not scanned:
        print(f"未在 {base_dir} 找到任何压缩包")
        return

    existing = load_existing(json_path)
    patches = merge(existing.get("patches", []) if existing else [], scanned)

    # Show summary
    print(f"扫描 {base_dir}")
    print(f"找到 {len(scanned)} 个补丁文件\n")
    for p in patches:
        status = "✓" if p.get("patch_dir") and p.get("target_dir") else "○"
        app_id = p.get("app_id")
        print(f"  [{status}] AppID={app_id}  {p['file']}")
        if p.get("patch_dir"):
            print(f"       patch={p['patch_dir']} -> target={p['target_dir']}")
        if p.get("label"):
            print(f"       label={p['label']}")

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump({"patches": patches}, f, ensure_ascii=False, indent=2)

    todo = sum(1 for p in patches if not p.get("patch_dir") or not p.get("target_dir"))
    if todo:
        print(f"\n⚠ {todo} 个补丁尚未配置 patch_dir / target_dir，请编辑 {json_path} 补填")
    else:
        print(f"\n✓ 全部配置完成，共 {len(patches)} 个补丁")


if __name__ == "__main__":
    main()

"""Scan steam_patches directory and generate/update patches.json template.

Usage:
  python scan_patches.py                           # scan, generate template
  python scan_patches.py --dir /path/to/patches    # custom dir
  python scan_patches.py --add 123456 v2.zip "汉化补丁" "data" "汉化 v2" "translation"
                                                        # add one entry
"""
import argparse, hashlib, json, logging, re, unicodedata
from pathlib import Path

import httpx

logger = logging.getLogger(__name__)

# Default keywords for auto type detection (mirrors steam_patch.py)
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
            if isinstance(data, dict):
                return {k: v for k, v in data.items() if isinstance(v, list)}
        except Exception:
            pass
    # Create with current defaults
    base_dir.mkdir(parents=True, exist_ok=True)
    with open(kw_path, "w", encoding="utf-8") as f:
        json.dump(DEFAULT_TYPE_KEYWORDS, f, ensure_ascii=False, indent=2)
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


def _make_patch_id(source_type: str, source_id: int | None, path: str) -> str:
    identity = f"{source_type or 'local'}|{source_id or ''}|{path}"
    digest = hashlib.sha1(identity.encode("utf-8")).hexdigest()[:16]
    return f"sp_{digest}"


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


_STEAM_SEARCH_LIMIT = 5
_MATCH_ACCEPT_SCORE = 60
_MATCH_MARGIN = 15

# Words that usually mark a derivative release rather than the base game.
_DERIVATIVE_MARKERS = (
    "凸", "hd", "fhd", "remaster", "remastered", "完全版", "体験版", "体验版",
    "demo", "dlc", "fd", "fandisc", "append", "plus", "special", "deluxe",
    "ultimate", "collection", "限定版", "中文版", "汉化版", "汉化", "r18",
)

_APPDETAILS_CACHE: dict[int, dict] = {}
_APPDETAILS_LANGS: dict[int, set[str]] = {}
_STEAM_PROXY_CACHE: str | None = None


def _steam_proxy() -> str:
    global _STEAM_PROXY_CACHE
    if _STEAM_PROXY_CACHE is None:
        try:
            from config import load_config

            _STEAM_PROXY_CACHE = str(load_config().proxy or "").strip()
        except Exception:
            _STEAM_PROXY_CACHE = ""
    return _STEAM_PROXY_CACHE


def _steam_request_kwargs() -> dict:
    kwargs: dict = {"timeout": httpx.Timeout(10.0)}
    proxy = _steam_proxy()
    if proxy:
        kwargs["proxy"] = proxy
    return kwargs


def _load_appdetails(app_id: int, langs: tuple[str, ...] = ("schinese",)) -> dict:
    """Cached Steam appdetails lookup: names, type and the parent app of a DLC.

    Titles differ per language ("LOVEPICAL-POPPY!" is "缘起甜韵趣恋丛生！" on the
    Chinese store), so callers can ask for the languages they need.
    """
    entry = _APPDETAILS_CACHE.setdefault(app_id, {"names": [], "type": "", "fullgame": None})
    fetched = _APPDETAILS_LANGS.setdefault(app_id, set())
    for lang in langs:
        if lang in fetched:
            continue
        try:
            with httpx.Client(**_steam_request_kwargs()) as client:
                resp = client.get(
                    "https://store.steampowered.com/api/appdetails",
                    params={"appids": app_id, "l": lang},
                    headers={"User-Agent": "Sena-Repo/1.0"},
                )
                resp.raise_for_status()
                data = resp.json()
        except Exception as exc:
            logger.warning("Steam appdetails failed for app_id=%s lang=%s: %s", app_id, lang, exc)
            continue
        # A completed request is required before the language is marked fetched,
        # so transient failures can be retried on the next call.
        fetched.add(lang)
        details = (data.get(str(app_id)) or {}).get("data") or {}
        if not details:
            continue
        name = str(details.get("name") or "")
        if name and name not in entry["names"]:
            entry["names"].append(name)
        if not entry["type"] and details.get("type"):
            entry["type"] = str(details["type"]).lower()
        fullgame = details.get("fullgame")
        if entry["fullgame"] is None and isinstance(fullgame, dict) and fullgame.get("appid"):
            try:
                entry["fullgame"] = int(fullgame["appid"])
            except (TypeError, ValueError):
                entry["fullgame"] = None
    return entry


def _appdetails(app_id: int) -> dict:
    return _load_appdetails(int(app_id), ("schinese", "english"))


def _fetch_game_name(app_id: int) -> str:
    """Fetch game name from Steam Store API by app_id. Prefers schinese, falls back to english."""
    try:
        names = _appdetails(int(app_id)).get("names") or []
    except (TypeError, ValueError):
        return ""
    return names[0] if names else ""


def _normalize_for_match(value: str) -> str:
    """Normalize a title for comparison: strip patch/extension noise, full-width
    forms, separators and case."""
    text = unicodedata.normalize("NFKC", _extract_game_name(value or ""))
    text = text.casefold()
    # Drop every separator/symbol ("Making*Lovers" vs "Making Lovers") but keep letters, digits and CJK.
    return re.sub(r"\W+", "", text)


def _has_derivative_marker(text: str) -> bool:
    return any(marker in text for marker in _DERIVATIVE_MARKERS)


def _name_match_score(query: str, candidate: str) -> int:
    """Score how well a Steam title matches the wanted game name."""
    if not query or not candidate:
        return 0
    if query == candidate:
        return 100
    if candidate.startswith(query):
        extra = candidate[len(query):]
        score = 85 - min(30, 5 * len(extra))
        if _has_derivative_marker(extra) or any(ch.isdigit() for ch in extra):
            score -= 25
        return max(0, score)
    if query.startswith(candidate):
        extra = query[len(candidate):]
        return max(0, 70 - 5 * len(extra))
    if query in candidate or candidate in query:
        return 45
    return 0


def _search_steam_app_id(game_name: str) -> int | None:
    """Search Steam for the base game of a patch.

    Steam's search ranks DLC and derivative releases first (for example
    "常轨脱离Creative凸" is a DLC of "常轨脱离Creative"), so candidates are scored
    by name and non-game entries are followed back to their ``fullgame``.
    Anything ambiguous returns None instead of guessing.
    """
    query = _normalize_for_match(game_name)
    if not query:
        return None
    try:
        with httpx.Client(**_steam_request_kwargs()) as client:
            resp = client.get(
                "https://store.steampowered.com/api/storesearch/",
                params={"term": game_name, "l": "schinese", "cc": "CN"},
                headers={"User-Agent": "Sena-Repo/1.0"},
            )
            resp.raise_for_status()
            data = resp.json()
    except Exception as exc:
        logger.warning("Steam search failed for %r: %s", game_name, exc)
        return None

    items = [item for item in (data.get("items") or [])[:_STEAM_SEARCH_LIMIT] if isinstance(item.get("id"), int)]

    def collect(langs: tuple[str, ...]) -> list[dict]:
        collected: list[dict] = []
        for item in items:
            app_id = int(item["id"])
            info = _load_appdetails(app_id, langs)
            names = info.get("names") or [str(item.get("name") or "")]
            best_name = names[0]
            best_score = _name_match_score(query, _normalize_for_match(best_name))
            for candidate_name in names[1:]:
                score = _name_match_score(query, _normalize_for_match(candidate_name))
                if score > best_score:
                    best_name, best_score = candidate_name, score
            collected.append({
                "app_id": app_id,
                "name": best_name,
                "normalized": _normalize_for_match(best_name),
                "type": info.get("type") or "",
                "fullgame": info.get("fullgame"),
                "score": best_score,
            })
        return collected

    candidates = collect(("schinese",))
    # Romanized titles are listed under a totally different Chinese name, so only
    # then pay for the extra languages (the schinese lookup stays cached).
    if query.isascii() and not any(
        c["normalized"] == query or (c["type"] == "game" and c["score"] >= _MATCH_ACCEPT_SCORE)
        for c in candidates
    ):
        candidates = collect(("schinese", "english", "japanese"))
    if not candidates:
        return None

    # 1) The patch name itself matches an entry exactly (base game or the DLC it targets).
    for candidate in sorted(candidates, key=lambda c: (c["type"] != "game", -c["score"])):
        if candidate["normalized"] == query:
            return candidate["app_id"]

    # 2) Closest candidate is a DLC/demo: fall back to its base game.
    best = max(candidates, key=lambda c: c["score"])
    if best["score"] > 0 and best["type"] != "game" and best["fullgame"]:
        parent_id = best["fullgame"]
        parent = _load_appdetails(parent_id, ("schinese", "english", "japanese"))
        parent_names = parent.get("names") or []
        parent_score = max(
            (_name_match_score(query, _normalize_for_match(name)) for name in parent_names),
            default=0,
        )
        if (parent.get("type") or "game") == "game" and parent_score >= _MATCH_ACCEPT_SCORE:
            logger.info(
                "Steam search %r: %s(%s) is %s, using base game %s(%s)",
                game_name, best["app_id"], best["name"], best["type"] or "not-a-game",
                parent_id, parent_names[0] if parent_names else "",
            )
            return parent_id

    # 3) Best plain game title, but only when it clearly wins.
    games = sorted(
        [c for c in candidates if c["type"] == "game" and c["score"] >= _MATCH_ACCEPT_SCORE],
        key=lambda c: -c["score"],
    )
    if games and (len(games) == 1 or games[0]["score"] - games[1]["score"] >= _MATCH_MARGIN):
        return games[0]["app_id"]

    logger.warning(
        "Steam search %r is ambiguous, leaving app_id empty; candidates=%s",
        game_name,
        [(c["app_id"], c["name"], c["type"] or "?", c["score"]) for c in candidates],
    )
    return None


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


def scan_patches_dir(base_dir: Path, analysis_mode: str = "auto") -> list[dict]:
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
                "patch_id": _make_patch_id("local", None, rel),
                "app_id": app_id,
                "file": rel,
                "size": f.stat().st_size,
                "analysis_mode": analysis_mode,
                "patch_dir": "",
                "target_dir": "",
                "manifest_status": "pending",
                "label": label,
                "type": ptype,
                "game_name": _fetch_game_name(app_id) if app_id else "",
            })
    return archives


def scan_patches_source(
    source,
    root_path: str,
    source_type: str = "local",
    source_id: int | None = None,
    analysis_mode: str = "auto",
) -> list[dict]:
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
                "patch_id": _make_patch_id(source_type, source_id, entry.path),
                "app_id": app_id,
                "file": canonical_source_path(source_type, source_id, entry.path),
                "source_type": source_type,
                "source_id": source_id,
                "source_path": entry.path,
                "display_file": rel,
                "size": entry.size,
                "analysis_mode": analysis_mode,
                "patch_dir": "",
                "target_dir": "",
                "manifest_status": "pending",
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
            if not old.get("patch_id") and s.get("patch_id"):
                old["patch_id"] = s["patch_id"]
            if old.get("locked"):
                # Locked entries keep their metadata; only refresh facts about the file
                # itself so the list still shows the current size and source.
                for key in ("size", "display_file", "source_type", "source_id", "source_path", "analysis_mode"):
                    if s.get(key) is not None:
                        old[key] = s[key]
                merged.append(old)
                continue
            # Keep user's manual entries but update discovered fields
            if not old.get("app_id") and s.get("app_id"):
                old["app_id"] = s["app_id"]
            if not old.get("type") or old.get("type") == "misc":
                if s.get("type") and s["type"] != "misc":
                    old["type"] = s["type"]
            if not old.get("game_name") and s.get("game_name"):
                old["game_name"] = s["game_name"]
            if s.get("size") and not old.get("size"):
                old["size"] = s["size"]
            for key in ("source_type", "source_id", "source_path", "display_file", "analysis_mode"):
                if s.get(key) is not None:
                    old[key] = s[key]
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
            "manifest_status": "confirmed",
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
        configured = p.get("manifest_status") == "confirmed"
        status = "✓" if configured else "○"
        app_id = p.get("app_id")
        print(f"  [{status}] AppID={app_id}  {p['file']}")
        if configured or p.get("patch_dir") or p.get("target_dir"):
            print(f"       patch={p.get('patch_dir', '')} -> target={p.get('target_dir', '')}")
        if p.get("label"):
            print(f"       label={p['label']}")

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump({"patches": patches}, f, ensure_ascii=False, indent=2)

    todo = sum(1 for p in patches if p.get("manifest_status") != "confirmed")
    if todo:
        print(f"\n⚠ {todo} 个补丁尚未确认注入规则，请编辑 {json_path} 或在客户端保存规则")
    else:
        print(f"\n✓ 全部配置完成，共 {len(patches)} 个补丁")


if __name__ == "__main__":
    main()

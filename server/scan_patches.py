"""Scan steam_patches directory and generate/update patches.json template.

Usage:
  python scan_patches.py                           # scan, generate template
  python scan_patches.py --dir /path/to/patches    # custom dir
  python scan_patches.py --add 123456 v2.zip "汉化补丁" "data" "汉化 v2"
                                                        # add one entry
"""
import json, os, sys, argparse, re
from pathlib import Path


def scan_patches_dir(base_dir: Path) -> list[dict]:
    """Scan recurisvely for archive files, auto-detect app_id from name."""
    archives = []
    for ext in (".zip", ".rar", ".7z", ".tar", ".gz", ".xz"):
        for f in sorted(base_dir.rglob(f"*{ext}")):
            rel = str(f.relative_to(base_dir)).replace("\\", "/")
            app_id = _guess_app_id(rel)
            archives.append({
                "app_id": app_id,
                "file": rel,
                "patch_dir": "",
                "target_dir": "",
                "label": "",
                "type": "misc",
            })
    return archives


def _guess_app_id(rel_path: str) -> int | None:
    """Try to extract app_id from filename or parent folder name."""
    name = rel_path.split("/")[-1]
    # Direct: 123456.zip
    m = re.match(r"^(\d{3,8})\..+$", name)
    if m:
        return int(m.group(1))
    # Parent folder: 123456/v2.zip
    parent = rel_path.split("/")[0] if "/" in rel_path else ""
    m = re.match(r"^(\d{3,8})$", parent)
    if m:
        return int(m.group(1))
    return None


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
    # Index existing by file path
    existing_by_file = {}
    for p in existing_patches:
        existing_by_file[p.get("file", "")] = p

    merged = []
    for s in scanned:
        old = existing_by_file.get(s["file"])
        if old:
            # Keep user's manual entries
            merged.append(old)
        else:
            merged.append(s)

    # Add entries that are no longer on disk? Keep them with a warning.
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

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump({"patches": patches}, f, ensure_ascii=False, indent=2)

    todo = sum(1 for p in patches if not p.get("patch_dir") or not p.get("target_dir"))
    if todo:
        print(f"\n⚠ {todo} 个补丁尚未配置 patch_dir / target_dir，请编辑 {json_path} 补填")
    else:
        print(f"\n✓ 全部配置完成，共 {len(patches)} 个补丁")


if __name__ == "__main__":
    main()

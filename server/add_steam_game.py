"""Add a non-Steam game shortcut — matches Steam's own shortcuts.vdf format."""
import argparse
import binascii
import json
import os
import shutil
import sys
from datetime import datetime

_script_dir = os.path.dirname(os.path.abspath(__file__))
_vdf_path = os.path.join(_script_dir, "vdf")
if os.path.isdir(_vdf_path):
    sys.path.insert(0, _script_dir)
try:
    import vdf
except ImportError:
    print(json.dumps({"success": False, "message": "vdf module not found"}))
    sys.exit(0)

parser = argparse.ArgumentParser()
parser.add_argument("--steamroot", required=True)
parser.add_argument("--userid", required=True)
parser.add_argument("--appname", required=True)
parser.add_argument("--exe", required=True)
parser.add_argument("--startdir", default="")
parser.add_argument("--icon", default="")
args = parser.parse_args()

args.exe = os.path.normpath(args.exe)
args.startdir = os.path.normpath(args.startdir) if args.startdir else ""
args.icon = os.path.normpath(args.icon) if args.icon else ""

shortcuts_path = os.path.join(args.steamroot, "userdata", args.userid, "config", "shortcuts.vdf")
os.makedirs(os.path.dirname(shortcuts_path), exist_ok=True)

# Read or create
if os.path.exists(shortcuts_path):
    try:
        with open(shortcuts_path, "rb") as f:
            data = vdf.binary_loads(f.read())
    except Exception:
        data = {"shortcuts": {}}
else:
    data = {"shortcuts": {}}

shortcuts = data.setdefault("shortcuts", {})

quoted_exe = f'"{args.exe}"'
hash_input = (quoted_exe + args.appname).encode()


def _to_u32(value):
    return int(value) & 0xFFFFFFFF


def _to_s32(value):
    value = _to_u32(value)
    return value - 0x100000000 if value >= 0x80000000 else value


def _shortcut_launch_id(shortcut_app_id):
    return (_to_u32(shortcut_app_id) << 32) | 0x02000000


def _shortcut_payload(success, message, shortcut_app_id, existing):
    launch_id = _shortcut_launch_id(shortcut_app_id)
    return {
        "success": success,
        "existing": existing,
        "shortcut_app_id": _to_u32(shortcut_app_id),
        "appid": _to_s32(shortcut_app_id),
        "grid_id": _to_u32(shortcut_app_id),
        "launch_id": str(launch_id),
        "steam_url": f"steam://rungameid/{launch_id}",
        "message": message,
    }


# Check if already added (match against normalized quoted Exe)
for sid, entry in shortcuts.items():
    if not isinstance(entry, dict):
        continue
    entry_exe = str(entry.get("Exe", ""))
    if os.path.normcase(entry_exe.strip('"')) == os.path.normcase(args.exe):
        shortcut_app_id = entry.get("appid")
        if shortcut_app_id is None:
            shortcut_app_id = binascii.crc32(hash_input) | 0x80000000
        print(json.dumps(_shortcut_payload(
            True,
            "已在 Steam 库中，无需重复添加。",
            int(shortcut_app_id),
            True,
        ), ensure_ascii=False))
        sys.exit(0)

# Steam uses sequential numeric keys (0, 1, 2, ...)
existing_keys = set()
used_app_ids = set()
for k in shortcuts.keys():
    try:
        existing_keys.add(int(k))
    except ValueError:
        pass
for entry in shortcuts.values():
    if not isinstance(entry, dict):
        continue
    if "appid" in entry:
        used_app_ids.add(_to_u32(entry["appid"]))
next_key = 0
while next_key in existing_keys:
    next_key += 1

shortcut_app_id = binascii.crc32(hash_input) | 0x80000000
shortcut_app_id_u32 = _to_u32(shortcut_app_id)
while shortcut_app_id_u32 in used_app_ids:
    shortcut_app_id_u32 = _to_u32(shortcut_app_id_u32 + 1) | 0x80000000
shortcut_app_id_s32 = _to_s32(shortcut_app_id_u32)

# Match Steam's EXACT format:
# - Exe value wrapped in double quotes
# - AppName capitalized
# - appid field = CRC32 (signed int32)
# - icon empty, sortas empty
shortcuts[str(next_key)] = {
    "appid":      shortcut_app_id_s32,
    "AppName":    args.appname,
    "Exe":        f'"{args.exe}"',           # quoted!
    "StartDir":   f'"{args.startdir or os.path.dirname(args.exe)}"',
    "icon":       "",
    "ShortcutPath": "",
    "LaunchOptions": "",
    "IsHidden":   0,
    "AllowDesktopConfig": 1,
    "AllowOverlay": 1,
    "OpenVR":     0,
    "Devkit":     0,
    "DevkitGameID": "",
    "DevkitOverrideAppID": 0,
    "LastPlayTime": 0,
    "FlatpakAppID": "",
    "sortas":     "",
    "tags":       {},
}

if os.path.exists(shortcuts_path):
    backup_path = (
        f"{shortcuts_path}.bak."
        f"{datetime.now().strftime('%Y%m%d%H%M%S')}"
    )
    shutil.copy2(shortcuts_path, backup_path)

with open(shortcuts_path, "wb") as f:
    f.write(vdf.binary_dumps(data))

print(json.dumps(_shortcut_payload(
    True,
    f"'{args.appname}' 已添加到 Steam，重启 Steam 客户端后生效。",
    shortcut_app_id_u32,
    False,
), ensure_ascii=False))

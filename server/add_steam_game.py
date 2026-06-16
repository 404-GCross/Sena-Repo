"""Add a non-Steam game shortcut — matches Steam's own shortcuts.vdf format."""
import json, os, sys, argparse, binascii

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

# Steam uses sequential numeric keys (0, 1, 2, ...)
# Find next available key
existing_keys = set()
for k in shortcuts.keys():
    try:
        existing_keys.add(int(k))
    except ValueError:
        pass
next_key = 0
while next_key in existing_keys:
    next_key += 1

# CRC32 for grid_id (used for artwork filenames)
crc = binascii.crc32((args.exe + args.appname).encode()) | 0x80000000

# Match Steam's EXACT format:
# - Exe value wrapped in double quotes
# - AppName capitalized
# - appid field = CRC32 (signed int32)
# - icon empty, sortas empty
shortcuts[str(next_key)] = {
    "appid":      crc - 0x100000000,
    "AppName":    args.appname,
    "Exe":        f'"{args.exe}"',           # quoted!
    "StartDir":   args.startdir or os.path.dirname(args.exe),
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

with open(shortcuts_path, "wb") as f:
    f.write(vdf.binary_dumps(data))

print(json.dumps({"success": True, "grid_id": crc,
    "message": f"'{args.appname}' 已添加到 Steam，重启 Steam 客户端后生效。"},
    ensure_ascii=False))

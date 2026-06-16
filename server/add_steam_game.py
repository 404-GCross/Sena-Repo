"""Add a non-Steam game shortcut via Python vdf library (NSL approach)."""
import json, os, sys, argparse

# Use bundled vdf module (from NSL), fall back to system package
_script_dir = os.path.dirname(os.path.abspath(__file__))
_vdf_path = os.path.join(_script_dir, "vdf")
if os.path.isdir(_vdf_path):
    sys.path.insert(0, _script_dir)
try:
    import vdf
except ImportError:
    print(json.dumps({"success": False, "message": "vdf module not found. Run: pip install vdf"}))
    sys.exit(0)

parser = argparse.ArgumentParser()
parser.add_argument("--steamroot", required=True)
parser.add_argument("--userid", required=True)
parser.add_argument("--appname", required=True)
parser.add_argument("--exe", required=True)
parser.add_argument("--startdir", default="")
parser.add_argument("--icon", default="")
args = parser.parse_args()

# Normalize all paths for the current OS (Windows: / → \)
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
    except Exception as e:
        print(json.dumps({"success": False, "message": f"Failed to parse shortcuts.vdf: {e}"}))
        sys.exit(0)
else:
    data = {"shortcuts": {}}

shortcuts = data.setdefault("shortcuts", {})

# Check if already added
for sid, entry in shortcuts.items():
    if isinstance(entry, dict) and entry.get("exe") == args.exe:
        print(json.dumps({"success": True, "message": f"已在 Steam 库中，无需重复添加。"}))
        sys.exit(0)

# Generate new entry ID (Steam formula: CRC32(exe+name) | 0x80000000)
import binascii
raw_id = args.exe + args.appname
crc = binascii.crc32(raw_id.encode()) | 0x80000000
entry_id = crc - 0x100000000  # signed int32 (negative), used in shortcuts.vdf
grid_id = crc                  # unsigned int32 (positive), used for grid image filenames

shortcuts[str(entry_id)] = {
    "appname": args.appname,
    "exe": args.exe,
    "StartDir": args.startdir or os.path.dirname(args.exe),
    "icon": args.icon or args.exe,
    "ShortcutPath": "",
    "LaunchOptions": "",
    "IsHidden": 0,
    "AllowDesktopConfig": 1,
    "AllowOverlay": 1,
    "OpenVR": 0,
    "Devkit": 0,
    "DevkitGameID": "",
    "DevkitOverrideAppID": 0,
    "LastPlayTime": 0,
    "FlatpakAppID": "",
    "tags": {}
}

with open(shortcuts_path, "wb") as f:
    f.write(vdf.binary_dumps(data))

print(json.dumps({"success": True, "grid_id": grid_id,
    "message": f"'{args.appname}' 已添加到 Steam，重启 Steam 客户端后生效。"}))

"""Add a non-Steam game shortcut via Python vdf library (NSL approach)."""
import json, os, sys, argparse

parser = argparse.ArgumentParser()
parser.add_argument("--steamroot", required=True)
parser.add_argument("--userid", required=True)
parser.add_argument("--appname", required=True)
parser.add_argument("--exe", required=True)
parser.add_argument("--startdir", default="")
parser.add_argument("--icon", default="")
args = parser.parse_args()

shortcuts_path = os.path.join(args.steamroot, "userdata", args.userid, "config", "shortcuts.vdf")
os.makedirs(os.path.dirname(shortcuts_path), exist_ok=True)

try:
    import vdf
except ImportError:
    print(json.dumps({"success": False, "message": "Python vdf library not installed. Run: pip install vdf"}))
    sys.exit(0)

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

# Check if already added
for sid, entry in shortcuts.items():
    if isinstance(entry, dict) and entry.get("exe") == args.exe:
        print(json.dumps({"success": True, "message": f"'{args.appname}' already in Steam library"}))
        sys.exit(0)

# Generate new entry ID
import binascii, ctypes, struct
raw_id = "".join([args.exe, args.appname])
entry_id = ctypes.c_int(binascii.crc32(raw_id.encode()) | 0x80000000).value

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

print(json.dumps({"success": True, "message": f"'{args.appname}' added to Steam. Restart Steam to see it."}))

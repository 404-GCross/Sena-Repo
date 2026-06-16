"""Diagnostic: dump shortcuts.vdf entries for comparison."""
import json, os, sys

_script_dir = os.path.dirname(os.path.abspath(__file__))
_vdf_path = os.path.join(_script_dir, "vdf")
if os.path.isdir(_vdf_path):
    sys.path.insert(0, _script_dir)
import vdf

if len(sys.argv) < 3:
    print("Usage: python dump_vdf.py <shortcuts.vdf path> <entry_name>")
    sys.exit(1)

path = sys.argv[1]
name_filter = sys.argv[2].lower()

with open(path, "rb") as f:
    data = vdf.binary_loads(f.read())

shortcuts = data.get("shortcuts", {})

# Also dump raw hex around each entry
raw = open(path, "rb").read()

for sid, entry in shortcuts.items():
    if not isinstance(entry, dict):
        continue
    an = (entry.get("appname") or entry.get("AppName") or "").lower()
    if name_filter not in an:
        continue

    print(f"\n=== Entry '{entry.get('appname')}' (key={sid}) ===")
    for k, v in entry.items():
        val = repr(v)
        if len(val) > 120:
            val = val[:120] + "..."
        print(f"  {k}: {val}")

    # Find raw bytes of this entry
    needle = f"{sid}".encode('utf-8')
    idx = raw.find(needle)
    if idx >= 0:
        start = max(0, idx - 4)
        end = min(len(raw), idx + 300)
        chunk = raw[start:end]
        print(f"  RAW [{start}:{end}]: {chunk.hex(' ')}")

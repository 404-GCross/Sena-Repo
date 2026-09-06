"""Add a non-Steam game shortcut — matches Steam's own shortcuts.vdf format."""

import argparse
import binascii
import json
import os
import shutil
import sys
import tempfile
from datetime import datetime


def _emit(payload):
    print(json.dumps(payload, ensure_ascii=False))
    sys.exit(0)


_script_dir = os.path.dirname(os.path.abspath(__file__))
_vdf_path = os.path.join(_script_dir, "vdf")
if os.path.isdir(_vdf_path):
    sys.path.insert(0, _script_dir)
try:
    import vdf
except ImportError:
    _emit({"success": False, "message": "vdf module not found"})


class ShortcutFileError(Exception):
    pass


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


def _read_shortcuts_file(shortcuts_path):
    if not os.path.exists(shortcuts_path):
        return {"shortcuts": {}}
    with open(shortcuts_path, "rb") as f:
        return vdf.binary_loads(f.read())


def _shortcuts_map(data):
    if not isinstance(data, dict):
        raise ShortcutFileError("shortcuts.vdf 顶层结构异常")
    shortcuts = data.get("shortcuts")
    if shortcuts is None:
        shortcuts = {}
        data["shortcuts"] = shortcuts
    if not isinstance(shortcuts, dict):
        raise ShortcutFileError("shortcuts.vdf shortcuts 节点结构异常")
    return shortcuts


def _comparable_exe(value):
    return os.path.normcase(os.path.normpath(str(value).strip().strip('"')))


def _find_shortcut_by_exe(shortcuts, exe_path):
    target = _comparable_exe(exe_path)
    for entry in shortcuts.values():
        if not isinstance(entry, dict):
            continue
        if _comparable_exe(entry.get("Exe", "")) == target:
            return entry
    return None


def _fsync_parent(directory):
    if os.name != "posix":
        return
    try:
        fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass


def _write_shortcuts_atomic(shortcuts_path, data):
    directory = os.path.dirname(shortcuts_path)
    payload = vdf.binary_dumps(data)
    fd, tmp_path = tempfile.mkstemp(
        prefix="shortcuts.",
        suffix=".tmp",
        dir=directory,
    )
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, shortcuts_path)
        _fsync_parent(directory)
    finally:
        if os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass


def _backup_shortcuts(shortcuts_path):
    if not os.path.exists(shortcuts_path):
        return None
    backup_path = (
        f"{shortcuts_path}.bak."
        f"{datetime.now().strftime('%Y%m%d%H%M%S')}"
    )
    shutil.copy2(shortcuts_path, backup_path)
    _fsync_parent(os.path.dirname(shortcuts_path))
    return backup_path


def _restore_backup(shortcuts_path, backup_path):
    shutil.copy2(backup_path, shortcuts_path)
    _fsync_parent(os.path.dirname(shortcuts_path))


def _parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--steamroot", required=True)
    parser.add_argument("--userid", required=True)
    parser.add_argument("--appname", required=True)
    parser.add_argument("--exe", required=True)
    parser.add_argument("--startdir", default="")
    parser.add_argument("--icon", default="")
    return parser.parse_args()


args = _parse_args()
args.exe = os.path.normpath(args.exe)
args.startdir = os.path.normpath(args.startdir) if args.startdir else ""
args.icon = os.path.normpath(args.icon) if args.icon else ""

shortcuts_path = os.path.join(
    args.steamroot,
    "userdata",
    args.userid,
    "config",
    "shortcuts.vdf",
)
os.makedirs(os.path.dirname(shortcuts_path), exist_ok=True)

try:
    data = _read_shortcuts_file(shortcuts_path)
    shortcuts = _shortcuts_map(data)
except Exception as exc:
    _emit({
        "success": False,
        "message": (
            "无法读取 Steam shortcuts.vdf，已停止写入以避免覆盖原有库。"
            f"原因: {exc}"
        ),
    })

quoted_exe = f'"{args.exe}"'
hash_input = (quoted_exe + args.appname).encode()

existing = _find_shortcut_by_exe(shortcuts, args.exe)
if existing is not None:
    shortcut_app_id = existing.get("appid")
    if shortcut_app_id is None:
        shortcut_app_id = binascii.crc32(hash_input) | 0x80000000
    _emit(_shortcut_payload(
        True,
        "已在 Steam 库中，无需重复添加。",
        int(shortcut_app_id),
        True,
    ))

existing_keys = set()
used_app_ids = set()
for key in shortcuts.keys():
    try:
        existing_keys.add(int(key))
    except (TypeError, ValueError):
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

shortcuts[str(next_key)] = {
    "appid": shortcut_app_id_s32,
    "AppName": args.appname,
    "Exe": quoted_exe,
    "StartDir": f'"{args.startdir or os.path.dirname(args.exe)}"',
    "icon": "",
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
    "sortas": "",
    "tags": {},
}

backup_path = None
try:
    backup_path = _backup_shortcuts(shortcuts_path)
    _write_shortcuts_atomic(shortcuts_path, data)
    verified_data = _read_shortcuts_file(shortcuts_path)
    verified_shortcuts = _shortcuts_map(verified_data)
    if _find_shortcut_by_exe(verified_shortcuts, args.exe) is None:
        raise ShortcutFileError("写入后未找到目标快捷方式")
except Exception as exc:
    restored = False
    if backup_path is not None:
        try:
            _restore_backup(shortcuts_path, backup_path)
            restored = True
        except Exception:
            restored = False
    elif os.path.exists(shortcuts_path):
        try:
            os.remove(shortcuts_path)
            _fsync_parent(os.path.dirname(shortcuts_path))
        except OSError:
            pass
    _emit({
        "success": False,
        "message": (
            "写入 Steam shortcuts.vdf 失败，"
            f"{'已恢复备份' if restored else '请手动检查 Steam 配置文件'}。"
            f"原因: {exc}"
        ),
    })

_emit(_shortcut_payload(
    True,
    f"'{args.appname}' 已添加到 Steam，重启 Steam 客户端后生效。",
    shortcut_app_id_u32,
    False,
))

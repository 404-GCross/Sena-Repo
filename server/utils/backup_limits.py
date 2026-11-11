from __future__ import annotations

import json
import re
import shutil
import stat
import struct
import zipfile
import zlib
from contextlib import contextmanager
from pathlib import Path

MAX_ARCHIVE_BYTES = 16 * 1024 ** 3
MAX_JSON_BYTES = 64 * 1024 ** 2
MAX_MEDIA_BYTES = 64 * 1024 ** 2
MAX_EXPANDED_BYTES = 32 * 1024 ** 3
MAX_ENTRIES = 100_000
MAX_DIRECTORY_BYTES = 16 * 1024 ** 2
DISK_RESERVE_BYTES = 256 * 1024 ** 2
CHUNK_BYTES = 1024 * 1024
_MEDIA_PATH = re.compile(r"media/(?:covers|backgrounds|avatars)/[A-Za-z0-9_-]{8,64}\.(?:jpg|jpeg|png|gif|webp)", re.I)


class BackupLimitError(ValueError):
    pass


def _directory_preflight(path: Path) -> None:
    size = path.stat().st_size
    if size > MAX_ARCHIVE_BYTES:
        raise BackupLimitError("备份压缩文件过大")
    with path.open("rb") as handle:
        handle.seek(max(0, size - 65557))
        tail = handle.read(65557)
        index = tail.rfind(b"PK\x05\x06")
        if index < 0 or index + 22 > len(tail):
            raise BackupLimitError("备份 ZIP 目录无效")
        end = struct.unpack_from("<4s4H2IH", tail, index)
        if index + 22 + end[7] != len(tail) or end[1] or end[2]:
            raise BackupLimitError("不支持该备份 ZIP 格式")
        count, directory_size, directory_offset = end[4], end[5], end[6]
        directory_end = size - len(tail) + index
        locator = None
        if directory_end >= 20:
            handle.seek(directory_end - 20)
            candidate = handle.read(20)
            if candidate[:4] == b"PK\x06\x07":
                locator = struct.unpack("<4sIQI", candidate)
        if locator is not None:
            if locator[0] != b"PK\x06\x07" or locator[1] != 0 or locator[3] != 1:
                raise BackupLimitError("不支持该 ZIP64 目录")
            handle.seek(locator[2])
            record = handle.read(56)
            if len(record) != 56:
                raise BackupLimitError("ZIP64 目录不完整")
            values = struct.unpack("<4sQ2H2I4Q", record)
            if (values[0] != b"PK\x06\x06" or not 44 <= values[1] <= 65536
                    or values[4] or values[5] or values[6] != values[7]
                    or locator[2] + 12 + values[1] != directory_end - 20):
                raise BackupLimitError("ZIP64 目录无效")
            count, directory_size, directory_offset = values[7:10]
            directory_end = locator[2]
        elif 65535 in end[3:5] or 4294967295 in end[5:7]:
            raise BackupLimitError("ZIP64 目录缺失")
        elif end[3] != end[4]:
            raise BackupLimitError("不支持分卷备份")
        if count > MAX_ENTRIES or directory_size > MAX_DIRECTORY_BYTES:
            raise BackupLimitError("备份文件数量或 ZIP 目录超过限制")
        if directory_offset + directory_size != directory_end:
            raise BackupLimitError("备份 ZIP 目录边界无效")


@contextmanager
def open_backup_zip(path: Path):
    _directory_preflight(path)
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > MAX_ENTRIES:
            raise BackupLimitError("备份文件数量超过限制")
        seen = set()
        total = 0
        for entry in entries:
            name = entry.filename
            if name in seen:
                raise BackupLimitError("备份包含重复文件")
            seen.add(name)
            kind = stat.S_IFMT(entry.external_attr >> 16)
            if kind not in (0, stat.S_IFREG) or entry.flag_bits & 1:
                raise BackupLimitError("备份不能包含链接、特殊文件或加密条目")
            if entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                raise BackupLimitError("不支持该备份压缩方式")
            if name != "backup.json" and _MEDIA_PATH.fullmatch(name) is None:
                raise BackupLimitError("备份包含无效的文件路径")
            limit = MAX_JSON_BYTES if name == "backup.json" else MAX_MEDIA_BYTES
            if entry.file_size > limit:
                raise BackupLimitError("备份内单个文件展开大小超过限制")
            if entry.compress_type == zipfile.ZIP_STORED and entry.compress_size != entry.file_size:
                raise BackupLimitError("备份条目长度不一致")
            total += entry.file_size
            if total > MAX_EXPANDED_BYTES:
                raise BackupLimitError("备份总展开大小超过限制")
        if "backup.json" not in seen:
            raise BackupLimitError("备份缺少 backup.json")
        yield archive


class ExpandedBudget:
    def __init__(self, used: int = 0):
        self.used = used

    def add(self, size: int) -> None:
        if size < 0 or self.used + size > MAX_EXPANDED_BYTES:
            raise BackupLimitError("备份总展开大小超过限制")
        self.used += size


def copy_zip_entry(archive, name: str, destination, limit: int, budget: ExpandedBudget) -> int:
    info = archive.getinfo(name)
    handle = archive.fp
    handle.seek(info.header_offset)
    header = handle.read(30)
    if len(header) != 30 or header[:4] != b"PK\x03\x04":
        raise BackupLimitError("备份条目头无效")
    fields = struct.unpack("<4s5H3I2H", header)
    if fields[2] & 1 or fields[3] != info.compress_type:
        raise BackupLimitError("备份条目头与目录不一致")
    raw_name = handle.read(fields[9])
    encoding = "utf-8" if fields[2] & 2048 else "cp437"
    if raw_name.decode(encoding) != info.orig_filename:
        raise BackupLimitError("备份条目名称不一致")
    data_offset = info.header_offset + 30 + fields[9] + fields[10]
    if data_offset + info.compress_size > archive.start_dir:
        raise BackupLimitError("备份条目数据越界")
    handle.seek(data_offset)
    decoder = zlib.decompressobj(-15) if info.compress_type == zipfile.ZIP_DEFLATED else None
    remaining = info.compress_size
    size = crc = 0

    def consume(chunk):
        nonlocal size, crc
        size += len(chunk)
        if size > limit or size > info.file_size:
            raise BackupLimitError("备份条目实际展开大小超过限制或与目录不一致")
        budget.add(len(chunk))
        crc = zlib.crc32(chunk, crc)
        destination.write(chunk)

    while remaining:
        compressed = handle.read(min(64 * 1024, remaining))
        if not compressed:
            raise BackupLimitError("备份条目数据不完整")
        remaining -= len(compressed)
        if decoder is None:
            consume(compressed)
            continue
        while compressed:
            consume(decoder.decompress(compressed, min(CHUNK_BYTES, limit - size + 1)))
            if decoder.unused_data:
                raise BackupLimitError("备份条目包含多余压缩数据")
            compressed = decoder.unconsumed_tail
    if decoder is not None:
        while not decoder.eof:
            chunk = decoder.decompress(b"", min(CHUNK_BYTES, limit - size + 1))
            if not chunk:
                break
            consume(chunk)
        if not decoder.eof or decoder.unused_data:
            raise BackupLimitError("备份压缩数据不完整")
    if size != info.file_size or crc != info.CRC:
        raise BackupLimitError("备份条目大小或校验和不一致")
    return size


def copy_bounded(source, destination, limit: int, budget: ExpandedBudget) -> int:
    size = 0
    while True:
        chunk = source.read(min(CHUNK_BYTES, limit - size + 1))
        if not chunk:
            return size
        size += len(chunk)
        if size > limit:
            raise BackupLimitError("备份内单个文件展开大小超过限制")
        budget.add(len(chunk))
        destination.write(chunk)


def _unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise BackupLimitError("备份 JSON 包含重复字段")
        result[key] = value
    return result


def load_backup_json(path: Path):
    import io

    output = io.BytesIO()
    if zipfile.is_zipfile(path):
        with open_backup_zip(path) as archive:
            copy_zip_entry(archive, "backup.json", output, MAX_JSON_BYTES, ExpandedBudget())
    else:
        if path.stat().st_size > MAX_JSON_BYTES:
            raise BackupLimitError("备份 JSON 文件过大")
        with path.open("rb") as source:
            copy_bounded(source, output, MAX_JSON_BYTES, ExpandedBudget())
    return json.loads(output.getvalue().decode("utf-8"), object_pairs_hook=_unique_pairs)


def check_restore_space(config, archive: Path, media: dict | None = None) -> None:
    expanded = 0
    if zipfile.is_zipfile(archive):
        with open_backup_zip(archive) as source:
            expanded = source.getinfo("backup.json").file_size
            names = set(source.namelist())
            for kind, entries in (media or {}).items():
                for key in entries:
                    name = f"media/{kind}/{key}"
                    if name in names and not (Path(config.data_path) / kind / key).is_file():
                        expanded += source.getinfo(name).file_size
    elif archive.stat().st_size > MAX_JSON_BYTES:
        raise BackupLimitError("备份 JSON 文件过大")
    root = Path(config.data_path)
    snapshot = sum(p.stat().st_size for p in (
        root / "sena_repo.db", root / "sena_repo.db-wal"
    ) if p.is_file())
    if shutil.disk_usage(root).free < expanded + snapshot + DISK_RESERVE_BYTES:
        raise BackupLimitError("磁盘空间不足以展开备份并保留安全快照")

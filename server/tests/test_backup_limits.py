import io
import json
import shutil
import stat
import struct
import tempfile
import unittest
import warnings
import zipfile
import zlib
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from cli import backup
from cli.common import CliError
from utils import backup_limits as limits


class BackupLimitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sena-backup-limits-")
        self.root = Path(self.temp.name).resolve()
        self.archive = self.root / "input.zip"
        self.payload = {"kind": backup.KIND, "schema_version": backup.SCHEMA_VERSION}

    def tearDown(self):
        self.assertEqual(self.root, Path(self.temp.name).resolve())
        self.temp.cleanup()

    def make_zip(self, entries=None, *, payload=None, compression=zipfile.ZIP_DEFLATED):
        with zipfile.ZipFile(self.archive, "w", compression=compression) as archive:
            archive.writestr("backup.json", json.dumps(payload or self.payload))
            for name, value in (entries or {}).items():
                archive.writestr(name, value)
        return self.archive

    def test_native_export_roundtrip_and_plain_json(self):
        image = self.root / "image.png"
        image.write_bytes(b"image-data")
        backup.write_backup(self.archive, self.payload,
                            {"covers": {"abcdefgh.png": image}}, include_media=True)
        self.assertEqual(backup.read_backup_payload(self.archive), self.payload)
        output = io.BytesIO()
        with limits.open_backup_zip(self.archive) as archive:
            limits.copy_zip_entry(archive, "media/covers/abcdefgh.png", output,
                                  limits.MAX_MEDIA_BYTES, limits.ExpandedBudget())
        self.assertEqual(output.getvalue(), b"image-data")
        plain = self.root / "backup.json"
        plain.write_text(json.dumps(self.payload))
        self.assertEqual(backup.read_backup_payload(plain), self.payload)

    def test_large_plain_and_compressed_json(self):
        payload = {**self.payload, "padding": "x" * 500}
        self.make_zip(payload=payload)
        plain = self.root / "backup.json"
        plain.write_text(json.dumps(payload))
        with patch.object(limits, "MAX_JSON_BYTES", 128):
            for path in (plain, self.archive):
                with self.subTest(path=path.name), self.assertRaises(CliError):
                    backup.read_backup_payload(path)

    def test_entry_and_total_and_directory_caps(self):
        self.make_zip({"media/covers/abcdefgh.png": b"x" * 200})
        for key, value in (("MAX_MEDIA_BYTES", 100), ("MAX_EXPANDED_BYTES", 150),
                           ("MAX_ENTRIES", 1), ("MAX_DIRECTORY_BYTES", 10),
                           ("MAX_ARCHIVE_BYTES", 10)):
            with self.subTest(key=key), patch.object(limits, key, value):
                with self.assertRaises(limits.BackupLimitError):
                    with limits.open_backup_zip(self.archive):
                        pass

    def test_duplicate_zip_json_and_manifest_keys(self):
        self.make_zip()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.archive, "a") as archive:
                archive.writestr("backup.json", "{}")
        with self.assertRaises(CliError):
            backup.read_backup_payload(self.archive)
        plain = self.root / "duplicate.json"
        plain.write_text('{"kind":"sena_backup","kind":"sena_backup"}')
        with self.assertRaises(CliError):
            backup.read_backup_payload(plain)
        with self.assertRaises(CliError):
            backup.normalise_payload({"media": {"covers": [
                {"key": "abcdefgh.png"}, {"key": "abcdefgh.png"},
            ]}})

    def test_links_special_paths_and_unsupported_compression_rejected(self):
        for name in ("../outside.png", "/outside.png", "media/covers/../secret.png"):
            self.make_zip({name: b"x"})
            with self.assertRaises(CliError):
                backup.read_backup_payload(self.archive)
        for mode in (stat.S_IFLNK, stat.S_IFIFO):
            self.make_zip()
            info = zipfile.ZipInfo("media/covers/abcdefgh.png")
            info.external_attr = (mode | 0o600) << 16
            with zipfile.ZipFile(self.archive, "a") as archive:
                archive.writestr(info, "target")
            with self.assertRaises(CliError):
                backup.read_backup_payload(self.archive)
        self.make_zip(compression=zipfile.ZIP_BZIP2)
        with self.assertRaises(CliError):
            backup.read_backup_payload(self.archive)

    def test_forged_expanded_size_and_prefix_crc_rejected(self):
        for compression in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            self.make_zip({"media/covers/abcdefgh.png": b"abcde"}, compression=compression)
            with zipfile.ZipFile(self.archive) as archive:
                local = archive.getinfo("media/covers/abcdefgh.png").header_offset
            data = bytearray(self.archive.read_bytes())
            central = data.index(b"PK\x01\x02", data.index(b"PK\x01\x02") + 4)
            for offset, crc_offset, size_offset in ((local, 14, 22), (central, 16, 24)):
                struct.pack_into("<I", data, offset + crc_offset, zlib.crc32(b"abc"))
                struct.pack_into("<I", data, offset + size_offset, 3)
            self.archive.write_bytes(data)
            with self.subTest(compression=compression), self.assertRaises(limits.BackupLimitError):
                with limits.open_backup_zip(self.archive) as archive:
                    limits.copy_zip_entry(archive, "media/covers/abcdefgh.png", io.BytesIO(),
                                          100, limits.ExpandedBudget())

    def test_zip64_locator_is_checked_even_without_classic_sentinels(self):
        self.make_zip()
        data = self.archive.read_bytes()
        position = data.rfind(b"PK\x05\x06")
        end = struct.unpack("<4s4H2IH", data[position:position + 22])
        record = struct.pack("<4sQ2H2I4Q", b"PK\x06\x06", 44, 45, 45, 0, 0,
                             end[4], end[4], end[5], end[6])
        locator = struct.pack("<4sIQI", b"PK\x06\x07", 0, position, 1)
        fake = struct.pack("<4s4H2IH", b"PK\x05\x06", 0, 0, 0, 0, 0, position + 76, 0)
        self.archive.write_bytes(data[:position] + record + locator + fake)
        with patch.object(limits, "MAX_DIRECTORY_BYTES", end[5] - 1):
            with patch.object(zipfile, "ZipFile") as constructor:
                with self.assertRaises(limits.BackupLimitError):
                    with limits.open_backup_zip(self.archive):
                        pass
                constructor.assert_not_called()
        self.assertEqual(backup.read_backup_payload(self.archive), self.payload)

    def test_truncated_zip_and_corrupt_stream_rejected(self):
        self.make_zip()
        self.archive.write_bytes(self.archive.read_bytes()[:-8])
        with self.assertRaises(CliError):
            backup.read_backup_payload(self.archive)
        self.make_zip()
        data = bytearray(self.archive.read_bytes())
        with zipfile.ZipFile(self.archive) as archive:
            info = archive.getinfo("backup.json")
            offset = info.header_offset + 30 + len(info.filename)
        data[offset] ^= 255
        self.archive.write_bytes(data)
        with self.assertRaises(CliError):
            backup.read_backup_payload(self.archive)

    def test_actual_stream_budget_is_enforced_before_write(self):
        output = io.BytesIO()
        with patch.object(limits, "CHUNK_BYTES", 4), patch.object(limits, "MAX_EXPANDED_BYTES", 5):
            with self.assertRaises(limits.BackupLimitError):
                limits.copy_bounded(io.BytesIO(b"x" * 20), output, 100, limits.ExpandedBudget())
        self.assertEqual(len(output.getvalue()), 4)

    def test_disk_check_charges_only_selected_new_media(self):
        self.make_zip({"media/covers/abcdefgh.png": b"x" * 300})
        config = SimpleNamespace(data_path=str(self.root))
        manifest = {"covers": {"abcdefgh.png": {}}}
        usage = shutil.disk_usage(self.root)._replace(free=200)
        with patch.object(limits, "DISK_RESERVE_BYTES", 0), patch.object(limits.shutil, "disk_usage", return_value=usage):
            limits.check_restore_space(config, self.archive)
            with self.assertRaises(limits.BackupLimitError):
                limits.check_restore_space(config, self.archive, manifest)
            (self.root / "covers").mkdir()
            (self.root / "covers" / "abcdefgh.png").write_bytes(b"existing")
            limits.check_restore_space(config, self.archive, manifest)

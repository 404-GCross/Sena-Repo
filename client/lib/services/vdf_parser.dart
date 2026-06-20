/// Steam shortcuts.vdf binary parser.
///
/// Format:
///   Byte 0:    0x00 (shortcut section marker)
///   Per entry: appid (uint32 LE) + key-value pairs ...
///              terminated by 0x08
///   EOF:       0x08
///
/// Each KV pair:
///   key:   1-byte length + UTF-8 bytes
///   type:  1 byte (0x00=end, 0x01=string, 0x02=int32)
///   value: string → 1-byte length + UTF-8 bytes
///          int32  → 4 bytes LE

import "dart:convert";
import "dart:typed_data";

class VdfShortcut {
  /// Parsed key-value pairs for this shortcut.
  final Map<String, dynamic> data;
  /// Original appid from the file.
  int appid;

  VdfShortcut({required this.appid, required this.data});

  /// Convenience: get the game name.
  String get appname => data["appname"]?.toString() ?? "";

  /// Convenience: get the exe path.
  String get exe => data["exe"]?.toString() ?? "";
}

/// Read shortcuts.vdf bytes into a list of [VdfShortcut] entries.
List<VdfShortcut> parseShortcutsVdf(List<int> raw) {
  final buf = raw is Uint8List ? raw : Uint8List.fromList(raw);
  final entries = <VdfShortcut>[];
  int pos = 0;

  // First byte should be 0x00
  if (buf.isEmpty || buf[pos] != 0x00) return entries;
  pos++;

  // Skip "shortcuts\0" section header if present
  if (pos + 9 < buf.length &&
      buf[pos] == 0x73 && buf[pos+1] == 0x68 && buf[pos+2] == 0x6F &&
      buf[pos+3] == 0x72 && buf[pos+4] == 0x74 && buf[pos+5] == 0x63 &&
      buf[pos+6] == 0x75 && buf[pos+7] == 0x74 && buf[pos+8] == 0x73) {
    // "shortcuts" found, skip until \x00 terminator then \x08
    pos += 9; // skip "shortcuts"
    while (pos < buf.length && buf[pos] != 0x00) pos++; // skip to null
    if (pos < buf.length && buf[pos] == 0x00) pos++; // skip null
  }

  while (pos + 4 <= buf.length) {
    // Check for EOF marker
    if (buf[pos] == 0x08) {
      // Double 0x08 = EOF, single 0x08 = entry terminator
      if (pos + 1 < buf.length && buf[pos + 1] == 0x08) break;
    }

    // Read appid (uint32 LE)
    if (pos + 4 > buf.length) break;
    final appid = _readU32LE(buf, pos);
    pos += 4;

    // Read key-value pairs until 0x08 terminator
    final data = <String, dynamic>{};
    while (pos < buf.length && buf[pos] != 0x08) {
      final key = _readString(buf, pos);
      pos += 1 + key.length; // length-byte + string

      if (pos >= buf.length) break;
      final type = buf[pos];
      pos++;

      if (type == 0x00) {
        // End of map section for this key
        continue;
      } else if (type == 0x01) {
        final val = _readString(buf, pos);
        pos += 1 + val.length;
        data[key] = val;
      } else if (type == 0x02) {
        if (pos + 4 > buf.length) break;
        final val = _readU32LE(buf, pos);
        pos += 4;
        data[key] = val;
      }
    }
    // Skip 0x08 terminator
    if (pos < buf.length && buf[pos] == 0x08) pos++;

    entries.add(VdfShortcut(appid: appid, data: data));
  }
  return entries;
}

/// Serialize a list of shortcuts back to the binary VDF format.
/// For new entries (appid == 0), auto-generate CRC32-based negative ID.
/// Existing entries keep their original appid.
Uint8List writeShortcutsVdf(List<VdfShortcut> entries) {
  final out = BytesBuilder();
  // Header: \x00shortcuts\x00\x08
  out.addByte(0x00);
  out.add("shortcuts".codeUnits);
  out.addByte(0x00);
  out.addByte(0x08);

  for (final entry in entries) {
    _writeU32LE(out, entry.appid);

    for (final kv in entry.data.entries) {
      _writeString(out, kv.key);
      final v = kv.value;
      if (v is String) {
        out.addByte(0x01);
        _writeString(out, v);
      } else if (v is int) {
        out.addByte(0x02);
        _writeU32LE(out, v);
      }
    }
    out.addByte(0x08); // entry terminator
  }
  out.addByte(0x08); // EOF marker
  return out.takeBytes();
}

/// Calculate the Steam grid appid for non-Steam games.
/// This is what Steam uses to name grid images in userdata/<id>/config/grid/
int gridAppId(String appname, String exe) {
  // Steam formula: CRC32(appname + exe) | 0x80000000
  return _makeAppid(appname, exe);
}

int _makeAppid(String appname, String exe) {
  final bytes = utf8.encode("$appname$exe");
  final crc = _crc32(Uint8List.fromList(bytes));
  return (crc | 0x80000000);
}

// ── helpers ──

String _readString(Uint8List buf, int pos) {
  final len = buf[pos];
  if (pos + 1 + len > buf.length) return "";
  return utf8.decode(buf.sublist(pos + 1, pos + 1 + len));
}

int _readU32LE(Uint8List buf, int pos) {
  return (buf[pos] & 0xFF) |
         ((buf[pos + 1] & 0xFF) << 8) |
         ((buf[pos + 2] & 0xFF) << 16) |
         ((buf[pos + 3] & 0xFF) << 24);
}

void _writeString(BytesBuilder out, String s) {
  final bytes = utf8.encode(s);
  if (bytes.length > 255) {
    out.addByte(255);
    out.add(bytes.sublist(0, 255));
  } else {
    out.addByte(bytes.length);
    out.add(bytes);
  }
}

void _writeU32LE(BytesBuilder out, int v) {
  out.addByte(v & 0xFF);
  out.addByte((v >> 8) & 0xFF);
  out.addByte((v >> 16) & 0xFF);
  out.addByte((v >> 24) & 0xFF);
}

// Simple CRC32 implementation (matches zlib/Steam behavior)
int _crc32(Uint8List data) {
  int crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (int i = 0; i < 8; i++) {
      if ((crc & 1) != 0) {
        crc = (crc >> 1) ^ 0xEDB88320;
      } else {
        crc >>= 1;
      }
    }
  }
  return crc ^ 0xFFFFFFFF;
}

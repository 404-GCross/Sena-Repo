/// Copies locally picked or downloaded background images into app storage.

import "dart:io";
import "dart:typed_data";
import "dart:ui" as ui;

import "package:path_provider/path_provider.dart";

import "logged_http.dart" as http;
import "logger_service.dart";

class BackgroundImageStore {
  static const _maxBytes = 25 * 1024 * 1024;
  static const _allowedExtensions = {
    ".jpg",
    ".jpeg",
    ".png",
    ".gif",
    ".webp",
    ".bmp",
  };

  static Future<Directory> _directory() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory("${base.path}${Platform.pathSeparator}backgrounds");
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<String> importFile(
    String sourcePath, {
    required String slot,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const FileSystemException("背景图片不存在");
    }
    final name = sourcePath.split(RegExp(r"[/\\]")).last;
    final dot = name.lastIndexOf(".");
    final extension = dot >= 0 ? name.substring(dot).toLowerCase() : ".jpg";
    if (!_allowedExtensions.contains(extension)) {
      throw const FileSystemException("不支持的图片格式");
    }
    if (await source.length() > _maxBytes) {
      throw const FormatException("背景图片不能超过 25 MB");
    }
    final bytes = await source.readAsBytes();
    return _storeBytes(bytes, slot: slot, extension: extension);
  }

  static Future<String> importUrl(
    String url, {
    required String slot,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !(uri.scheme == "http" || uri.scheme == "https") ||
        uri.host.isEmpty) {
      throw const FormatException("图片网址无效");
    }
    final response = await http
        .get(uri, headers: const {"Accept": "image/*"})
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw HttpException("图片下载失败（HTTP ${response.statusCode}）");
    }
    final bytes = response.bodyBytes;
    final contentType = response.headers["content-type"] ?? "";
    final extension = _extensionFor(contentType, uri.path);
    return _storeBytes(bytes, slot: slot, extension: extension);
  }

  static String _extensionFor(String contentType, String path) {
    final type = contentType.split(";").first.trim().toLowerCase();
    switch (type) {
      case "image/png":
        return ".png";
      case "image/gif":
        return ".gif";
      case "image/webp":
        return ".webp";
      case "image/bmp":
        return ".bmp";
      case "image/jpeg":
      case "image/jpg":
        return ".jpg";
    }
    final dot = path.lastIndexOf(".");
    if (dot >= 0) {
      final extension = path.substring(dot).toLowerCase();
      if (_allowedExtensions.contains(extension)) return extension;
    }
    return ".jpg";
  }

  static Future<String> _storeBytes(
    Uint8List bytes, {
    required String slot,
    required String extension,
  }) async {
    if (bytes.isEmpty) {
      throw const FormatException("图片内容为空");
    }
    if (bytes.length > _maxBytes) {
      throw const FormatException("背景图片不能超过 25 MB");
    }
    await _validateImage(bytes);
    final dir = await _directory();
    final target = File(
      "${dir.path}${Platform.pathSeparator}"
      "background_${slot}_${DateTime.now().microsecondsSinceEpoch}$extension",
    );
    await target.writeAsBytes(bytes, flush: true);
    return target.path;
  }

  static Future<void> _validateImage(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    } catch (e, stackTrace) {
      LoggerService().warn("background image decode failed", e, stackTrace);
      throw const FormatException("无法识别该图片文件");
    }
  }

  static Future<void> delete(String? path) async {
    final value = path?.trim() ?? "";
    if (value.isEmpty || value.startsWith("http")) return;
    try {
      final dir = await _directory();
      final file = File(value);
      if (!await file.exists()) return;
      final normalizedDir = dir.absolute.path.endsWith(Platform.pathSeparator)
          ? dir.absolute.path
          : "${dir.absolute.path}${Platform.pathSeparator}";
      final filePath = Platform.isWindows
          ? file.absolute.path.toLowerCase()
          : file.absolute.path;
      final dirPath = Platform.isWindows
          ? normalizedDir.toLowerCase()
          : normalizedDir;
      if (!filePath.startsWith(dirPath)) return;
      await file.delete();
    } catch (_) {
      // A stale file that cannot be removed must not block the UI update.
    }
  }
}

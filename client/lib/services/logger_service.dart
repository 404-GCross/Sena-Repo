/// Simple file-based logger with daily rotation (7-day retention).
/// Pure dart:io, no external dependencies.

import "dart:io";

import "package:path_provider/path_provider.dart";

class LoggerService {
  static final LoggerService _instance = LoggerService._();
  factory LoggerService() => _instance;
  LoggerService._();

  String? _logDir;

  Future<String> get _dir async {
    if (_logDir != null) return _logDir!;
    final appDir = await getApplicationSupportDirectory();
    _logDir = "${appDir.path}${Platform.pathSeparator}logs";
    await Directory(_logDir!).create(recursive: true);
    return _logDir!;
  }

  String _todayFile() {
    final now = DateTime.now();
    final d = "${now.year}-${now.month.toString().padLeft(2, "0")}-${now.day.toString().padLeft(2, "0")}";
    return "sena_$d.log";
  }

  Future<void> log(String level, String message, [Object? error]) async {
    try {
      final dir = await _dir;
      final ts = DateTime.now().toString().substring(0, 19);
      var line = "[$ts] [$level] $message";
      if (error != null) line += " | $error";
      await File("$dir${Platform.pathSeparator}${_todayFile()}").writeAsString("$line\n", mode: FileMode.append);
    } catch (_) {}
  }

  void info(String message) => log("INFO", message);
  void warn(String message, [Object? e]) => log("WARN", message, e);
  void error(String message, [Object? e]) => log("ERROR", message, e);

  Future<List<File>> getLogFiles() async {
    try {
      final dir = await _dir;
      final files = Directory(dir).listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith(".log"))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path)); // newest first
      return files;
    } catch (_) {
      return [];
    }
  }

  Future<String> readLog(File file) async {
    try {
      return await file.readAsString();
    } catch (e) {
      return "读取失败: $e";
    }
  }

  /// Delete logs older than 7 days
  Future<void> cleanOldLogs() async {
    try {
      final dir = await _dir;
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      for (final f in Directory(dir).listSync().whereType<File>()) {
        if (f.path.endsWith(".log")) {
          final stat = await f.stat();
          if (stat.modified.isBefore(cutoff)) {
            await f.delete();
          }
        }
      }
    } catch (_) {}
  }

  Future<String> get logDirPath async => await _dir;
}

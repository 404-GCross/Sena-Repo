// Simple file-based logger with daily rotation (7-day retention).
// Pure dart:io, no external dependencies.

import "dart:io";

import "package:path_provider/path_provider.dart";

class LogRecord {
  final String raw;
  final DateTime? timestamp;
  final String timestampLabel;
  final String level;
  final String module;
  final String message;

  const LogRecord({
    required this.raw,
    required this.timestamp,
    required this.timestampLabel,
    required this.level,
    required this.module,
    required this.message,
  });

  bool get isInfo => level == "INFO";
  bool get isWarn => level == "WARN";
  bool get isError => level == "ERROR";
}

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
    final d =
        "${now.year}-${now.month.toString().padLeft(2, "0")}-${now.day.toString().padLeft(2, "0")}";
    return "sena_$d.log";
  }

  Future<void> log(String level, String message, [Object? error]) async {
    try {
      final dir = await _dir;
      final ts = DateTime.now().toString().substring(0, 19);
      var line = "[$ts] [$level] ${_redact(message)}";
      if (error != null) line += " | ${_redact(error.toString())}";
      await File("$dir${Platform.pathSeparator}${_todayFile()}")
          .writeAsString("$line\n", mode: FileMode.append);
    } catch (_) {}
  }

  void info(String message) => log("INFO", message);
  void warn(String message, [Object? e]) => log("WARN", message, e);
  void error(String message, [Object? e]) => log("ERROR", message, e);

  Future<List<File>> getLogFiles() async {
    try {
      final dir = await _dir;
      final files = Directory(dir)
          .listSync()
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

  Future<List<LogRecord>> readLogEntries(File file) async {
    try {
      final content = await file.readAsString();
      return content
          .split(RegExp(r"\r?\n"))
          .where((line) => line.trim().isNotEmpty)
          .map(_parseLine)
          .toList()
          .reversed
          .toList();
    } catch (e) {
      return [
        LogRecord(
          raw: "读取失败: $e",
          timestamp: null,
          timestampLabel: "--:--:--",
          level: "ERROR",
          module: "日志",
          message: "读取日志文件失败",
        ),
      ];
    }
  }

  LogRecord _parseLine(String raw) {
    final match =
        RegExp(r"^\[([^\]]+)\]\s+\[([^\]]+)\]\s+(.*)$").firstMatch(raw.trim());
    if (match == null) {
      return LogRecord(
        raw: raw,
        timestamp: null,
        timestampLabel: "--:--:--",
        level: "INFO",
        module: _moduleFor(raw),
        message: raw,
      );
    }

    final timestampText = match.group(1) ?? "";
    final parsed = DateTime.tryParse(timestampText);
    return LogRecord(
      raw: raw,
      timestamp: parsed,
      timestampLabel: parsed == null
          ? timestampText
          : "${parsed.hour.toString().padLeft(2, "0")}:${parsed.minute.toString().padLeft(2, "0")}:${parsed.second.toString().padLeft(2, "0")}",
      level: (match.group(2) ?? "INFO").toUpperCase(),
      module: _moduleFor(match.group(3) ?? ""),
      message: match.group(3) ?? "",
    );
  }

  String _moduleFor(String message) {
    final lower = message.toLowerCase();
    if (message.contains("连接") ||
        message.contains("令牌") ||
        lower.contains("connect") ||
        lower.contains("login") ||
        lower.contains("token")) {
      return "连接";
    }
    if (message.contains("刮削") ||
        message.contains("Hikarinagi") ||
        message.contains("VNDB") ||
        lower.contains("scrape")) {
      return "刮削";
    }
    if (message.contains("扫描") ||
        message.contains("游戏库") ||
        lower.contains("scan") ||
        lower.contains("library")) {
      return "扫描";
    }
    if (message.contains("下载") ||
        message.contains("补丁") ||
        message.contains("解压") ||
        lower.contains("download") ||
        lower.contains("patch") ||
        lower.contains("extract")) {
      return "下载";
    }
    return "其他";
  }

  String _redact(String value) {
    return value
        .replaceAll(
            RegExp(r"Bearer\s+[A-Za-z0-9._~+/=-]+", caseSensitive: false),
            "Bearer [REDACTED]")
        .replaceAll(
            RegExp(r"([?&](?:token|access_token|password|passwd|key)=)[^&\s]+",
                caseSensitive: false),
            r"$1[REDACTED]")
        .replaceAll(
            RegExp(r"((?:password|passwd|token|access_token)\s*[:=]\s*)[^,\s]+",
                caseSensitive: false),
            r"$1[REDACTED]");
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

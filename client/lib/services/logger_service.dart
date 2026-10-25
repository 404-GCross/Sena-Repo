// Scoped, file-based logger.
//
// Records are written as JSON Lines under a scope derived from the verified
// server + account, so one account never reads another account's history.
// Severity (INFO/WARN/ERROR) is separate from [LogVisibility].

import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:path_provider/path_provider.dart";

import "../models/log_models.dart";

class LoggerService {
  static final LoggerService _instance = LoggerService._();
  factory LoggerService() => _instance;
  LoggerService._();

  String? _logDir;
  Future<void> _writeQueue = Future<void>.value();
  LogContext? _context;
  String _deviceSession = "";
  String? _cachedDeviceSession;

  /// Null while logging works; a message once writes start failing.
  final ValueNotifier<String?> storageStatus = ValueNotifier<String?>(null);

  void setContext(LogContext? context) {
    _context = context;
  }

  LogContext? get context => _context;

  String get deviceSession {
    if (_deviceSession.isEmpty) {
      _deviceSession = _cachedDeviceSession ??
          "device-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}";
      _cachedDeviceSession = _deviceSession;
    }
    return _deviceSession;
  }

  LogContext get _effectiveContext =>
      _context ??
      LogContext(serverKey: "device", accountScope: "", sessionId: deviceSession);

  Future<String> get _dir async {
    if (_logDir != null) return _logDir!;
    final appDir = await getApplicationSupportDirectory();
    _logDir = "${appDir.path}${Platform.pathSeparator}logs";
    await Directory(_logDir!).create(recursive: true);
    return _logDir!;
  }

  String _dayStamp(DateTime value) {
    final d = "${value.year}-${value.month.toString().padLeft(2, "0")}-"
        "${value.day.toString().padLeft(2, "0")}";
    return d;
  }

  String _scopeDir(String root, LogContext context) {
    final sep = Platform.pathSeparator;
    if (context.accountScope.isEmpty) {
      return "$root${sep}device${sep}${context.sessionId}";
    }
    return "$root${sep}scoped${sep}${context.serverKey}"
        "${sep}${context.accountScope}";
  }

  /// Structured entry point. New code should prefer this over [info]/[warn].
  Future<void> record(
    LogLevel level,
    String event,
    String message, {
    String module = "app",
    LogVisibility visibility = LogVisibility.personal,
    Map<String, Object?> fields = const {},
    String? taskId,
    String? requestId,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final context = _effectiveContext;
    final record = LogRecord(
      timestamp: DateTime.now(),
      level: level,
      visibility: visibility,
      context: context,
      module: module,
      event: event,
      message: _sanitize(message),
      requestId: requestId,
      taskId: taskId,
      fields: _sanitizeFields(fields),
    );
    var line = jsonEncode(record.toJson());
    if (error != null) {
      line = line.replaceFirst(
        RegExp(r"\}$"),
        ',"error":${jsonEncode(_sanitize(error.toString()))}}',
      );
    }
    if (stackTrace != null && level == LogLevel.error) {
      line = line.replaceFirst(
        RegExp(r"\}$"),
        ',"stack":${jsonEncode(_sanitize(stackTrace.toString()))}}',
      );
    }
    final writeTask = _writeQueue.catchError((_) {}).then(
          (_) => _writeLine(line, record.timestamp, context),
        );
    _writeQueue = writeTask;
    return writeTask;
  }

  Future<void> _writeLine(
    String line,
    DateTime timestamp,
    LogContext context,
  ) async {
    try {
      final root = await _dir;
      final dir = _scopeDir(root, context);
      await Directory(dir).create(recursive: true);
      final file = File(
        "$dir${Platform.pathSeparator}${_dayStamp(timestamp)}.jsonl",
      );
      await file.writeAsString("$line\n", mode: FileMode.append, flush: true);
      if (storageStatus.value != null) storageStatus.value = null;
    } catch (e) {
      final message = "日志写入失败: ${_sanitize(e.toString())}";
      if (storageStatus.value == null) {
        storageStatus.value = message;
        // Console fallback so the failure is not completely silent.
        debugPrint(message);
      }
    }
  }

  /// Waits for queued writes; call before exporting or exiting normally.
  Future<void> flush() => _writeQueue.catchError((_) {});

  // ── legacy convenience API ───────────────────────────────────────────────

  Future<void> log(
    String level,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    final parsed = switch (level) {
      "ERROR" => LogLevel.error,
      "WARN" => LogLevel.warning,
      _ => LogLevel.info,
    };
    return record(
      parsed,
      "app",
      message,
      error: error,
      stackTrace: stackTrace,
    );
  }

  void info(String message) => log("INFO", message);
  void warn(String message, [Object? e, StackTrace? stackTrace]) =>
      log("WARN", message, e, stackTrace);
  void error(String message, [Object? e, StackTrace? stackTrace]) =>
      log("ERROR", message, e, stackTrace);

  String redact(String value) => _sanitize(value);

  // ── reading (always scoped) ──────────────────────────────────────────────

  Future<List<LogFileInfo>> listFiles(LogViewerAccess access) async {
    if (!access.isUsable) return const [];
    try {
      final root = await _dir;
      final sep = Platform.pathSeparator;
      final dirs = <String>[
        if (access.management)
          "$root${sep}scoped${sep}${access.serverKey}"
              "${sep}${access.accountScope}",
        "$root${sep}device${sep}${access.sessionId}",
      ];
      final files = <LogFileInfo>[];
      for (final dir in dirs) {
        final directory = Directory(dir);
        if (!await directory.exists()) continue;
        await for (final entity in directory.list()) {
          if (entity is! File || !entity.path.endsWith(".jsonl")) continue;
          final stat = await entity.stat();
          files.add(
            LogFileInfo(
              path: entity.path,
              name: entity.path.split(sep).last,
              day: _dayFromName(entity.path.split(sep).last),
              size: stat.size,
            ),
          );
        }
      }
      files.sort((a, b) => b.name.compareTo(a.name));
      return files;
    } catch (e) {
      _warnOnce("读取日志列表失败", e);
      return const [];
    }
  }

  DateTime? _dayFromName(String name) {
    final match = RegExp(r"^(\d{4})-(\d{2})-(\d{2})\.jsonl$").firstMatch(name);
    if (match == null) return null;
    return DateTime.tryParse(
      "${match.group(1)}-${match.group(2)}-${match.group(3)}",
    );
  }

  Future<List<LogRecord>> readEntries(
    LogViewerAccess access,
    LogFileInfo file, {
    int limit = 500,
  }) async {
    if (!access.isUsable) return const [];
    try {
      final content = await File(file.path).readAsString();
      final records = <LogRecord>[];
      for (final line in const LineSplitter().convert(content)) {
        if (line.trim().isEmpty) continue;
        final parsed = _parseLine(line);
        if (parsed == null) continue;
        if (!access.canRead(parsed)) continue;
        records.add(parsed);
      }
      records.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      if (records.length > limit) {
        return records.sublist(0, limit);
      }
      return records;
    } catch (e) {
      _warnOnce("读取日志文件失败", e);
      return const [];
    }
  }

  Future<String> exportEntries(
    LogViewerAccess access, {
    String? query,
  }) async {
    if (!access.isUsable) return "";
    final needle = (query ?? "").trim().toLowerCase();
    final lines = <String>[];
    for (final file in await listFiles(access)) {
      final entries = await readEntries(access, file, limit: 100000);
      for (final entry in entries.reversed) {
        if (needle.isNotEmpty && !entry.raw.toLowerCase().contains(needle)) {
          continue;
        }
        lines.add(entry.raw);
      }
    }
    return lines.join("\n");
  }

  LogRecord? _parseLine(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return null;
      return LogRecord.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  void _warnOnce(String message, Object error) {
    if (storageStatus.value != null) return;
    final text = "$message: ${_sanitize(error.toString())}";
    storageStatus.value = text;
    debugPrint(text);
  }

  // ── redaction ────────────────────────────────────────────────────────────

  String _sanitize(String value) => _redact(value)
      .replaceAll("\r", r"\r")
      .replaceAll("\n", r"\n")
      .replaceAll(RegExp(r"\s+"), " ")
      .trim();

  Map<String, Object?> _sanitizeFields(Map<String, Object?> fields) {
    final cleaned = <String, Object?>{};
    fields.forEach((key, value) {
      if (value == null) return;
      if (value is String) {
        cleaned[key] = _sanitize(value);
      } else if (value is num || value is bool) {
        cleaned[key] = value;
      } else if (value is List) {
        cleaned[key] = value
            .take(20)
            .map((item) => _sanitize(item.toString()))
            .toList();
      } else {
        cleaned[key] = _sanitize(value.toString());
      }
    });
    return cleaned;
  }

  String _redact(String value) {
    const sensitiveKeys =
        r"token|access_token|refresh_token|password|passwd|pwd|key|api_key|"
        r"secret|client_secret|signature|sign|sig|auth|authorization|username|"
        r"account|email|code|session|cookie";
    var redacted = value
        .replaceAll(
            RegExp(r"Bearer\s+[A-Za-z0-9._~+/=-]+", caseSensitive: false),
            "Bearer [REDACTED]")
        .replaceAll(
            RegExp(r"Basic\s+[A-Za-z0-9._~+/=-]+", caseSensitive: false),
            "Basic [REDACTED]");

    redacted = redacted.replaceAllMapped(
      RegExp(r"(Authorization\s*[:=]\s*)[^,\s}]+", caseSensitive: false),
      (match) => "${match.group(1)}[REDACTED]",
    );
    redacted = redacted.replaceAllMapped(
      RegExp("([?&](?:$sensitiveKeys)=)[^&\\s]+", caseSensitive: false),
      (match) => "${match.group(1)}[REDACTED]",
    );
    redacted = redacted.replaceAllMapped(
      RegExp("(%3[f&](?:$sensitiveKeys)%3[dD])[^%&\\s]+",
          caseSensitive: false),
      (match) => "${match.group(1)}[REDACTED]",
    );
    redacted = redacted.replaceAllMapped(
      RegExp("(^|[^A-Za-z0-9_])((?:$sensitiveKeys)\\s*[:=]\\s*)[^,\\s}]+",
          caseSensitive: false),
      (match) => "${match.group(1)}${match.group(2)}[REDACTED]",
    );
    return redacted.replaceAllMapped(
      RegExp("([\"'](?:$sensitiveKeys)[\"']\\s*:\\s*)([\"'])[^\"']*([\"'])",
          caseSensitive: false),
      (match) => "${match.group(1)}${match.group(2)}[REDACTED]${match.group(3)}",
    );
  }

  /// Delete log files older than 7 days. Internal maintenance, not viewer-scoped.
  Future<void> cleanOldLogs() async {
    try {
      final root = await _dir;
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      await for (final entity
          in Directory(root).list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith(".jsonl") && !entity.path.endsWith(".log")) {
          continue;
        }
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          try {
            await entity.delete();
          } catch (e) {
            _warnOnce("清理旧日志失败", e);
          }
        }
      }
    } catch (e) {
      _warnOnce("清理旧日志失败", e);
    }
  }

  Future<String> get logDirPath async => await _dir;
}

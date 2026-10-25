/// Log ownership model: severity is separate from who may read a record.

enum LogLevel { info, warning, error }

enum LogVisibility {
  /// Diagnostics for the account that produced the record.
  personal,

  /// Management detail (server paths, upstream errors, admin actions).
  management,

  /// Startup / connection diagnostics that have no account yet.
  device,
}

class LogContext {
  final String serverKey;
  final String accountScope;
  final String sessionId;

  const LogContext({
    required this.serverKey,
    required this.accountScope,
    required this.sessionId,
  });

  bool get isDevice => accountScope.isEmpty;

  Map<String, Object?> toJson() => {
        "server": serverKey,
        "account": accountScope,
        "session": sessionId,
      };

  static LogContext fromJson(Map<String, dynamic> json) => LogContext(
        serverKey: json["server"]?.toString() ?? "",
        accountScope: json["account"]?.toString() ?? "",
        sessionId: json["session"]?.toString() ?? "",
      );
}

class LogRecord {
  final DateTime timestamp;
  final LogLevel level;
  final LogVisibility visibility;
  final LogContext context;
  final String module;
  final String event;
  final String message;
  final String? requestId;
  final String? taskId;
  final Map<String, Object?> fields;

  const LogRecord({
    required this.timestamp,
    required this.level,
    required this.visibility,
    required this.context,
    required this.module,
    required this.event,
    required this.message,
    this.requestId,
    this.taskId,
    this.fields = const {},
  });

  String get levelLabel => switch (level) {
        LogLevel.info => "INFO",
        LogLevel.warning => "WARN",
        LogLevel.error => "ERROR",
      };

  String get timestampLabel {
    String two(int value) => value.toString().padLeft(2, "0");
    return "${two(timestamp.hour)}:${two(timestamp.minute)}:"
        "${two(timestamp.second)}";
  }

  bool get isError => level == LogLevel.error;
  bool get isWarn => level == LogLevel.warning;
  bool get isInfo => level == LogLevel.info;

  Map<String, Object?> toJson() => {
        "ts": timestamp.toUtc().toIso8601String(),
        "level": levelLabel,
        "visibility": visibility.name,
        "module": module,
        "event": event,
        "message": message,
        if (requestId != null) "request_id": requestId,
        if (taskId != null) "task_id": taskId,
        if (fields.isNotEmpty) "fields": fields,
        "context": context.toJson(),
      };

  String get raw {
    final buffer = StringBuffer(
      "[$timestampLabel] [$levelLabel] $module/$event $message",
    );
    if (requestId != null && requestId!.isNotEmpty) {
      buffer.write(" request_id=$requestId");
    }
    if (fields.isNotEmpty) buffer.write(" $fields");
    return buffer.toString();
  }

  static LogRecord? fromJson(Map<String, dynamic> json) {
    final levelText = json["level"]?.toString().toUpperCase() ?? "INFO";
    final visibilityText = json["visibility"]?.toString() ?? "personal";
    final parsed = DateTime.tryParse(json["ts"]?.toString() ?? "");
    if (parsed == null) return null;
    return LogRecord(
      timestamp: parsed.toLocal(),
      level: switch (levelText) {
        "ERROR" => LogLevel.error,
        "WARN" => LogLevel.warning,
        _ => LogLevel.info,
      },
      visibility: switch (visibilityText) {
        "management" => LogVisibility.management,
        "device" => LogVisibility.device,
        _ => LogVisibility.personal,
      },
      context: LogContext.fromJson(
        Map<String, dynamic>.from(json["context"] as Map? ?? const {}),
      ),
      module: json["module"]?.toString() ?? "app",
      event: json["event"]?.toString() ?? "app",
      message: json["message"]?.toString() ?? "",
      requestId: json["request_id"]?.toString(),
      taskId: json["task_id"]?.toString(),
      fields: Map<String, Object?>.from(json["fields"] as Map? ?? const {}),
    );
  }
}

class LogFileInfo {
  final String path;
  final String name;
  final DateTime? day;
  final int size;

  const LogFileInfo({
    required this.path,
    required this.name,
    required this.day,
    required this.size,
  });
}

/// What the current viewer may read. Built only from a verified session.
class LogViewerAccess {
  final String serverKey;
  final String accountScope;
  final String sessionId;
  final bool management;

  const LogViewerAccess({
    required this.serverKey,
    required this.accountScope,
    required this.sessionId,
    required this.management,
  });

  bool get isUsable => serverKey.isNotEmpty && accountScope.isNotEmpty;

  bool canRead(LogRecord record) {
    if (record.context.serverKey != serverKey) return false;
    switch (record.visibility) {
      case LogVisibility.management:
        return management && record.context.accountScope == accountScope;
      case LogVisibility.device:
        return record.context.sessionId == sessionId;
      case LogVisibility.personal:
        return record.context.accountScope == accountScope;
    }
  }
}

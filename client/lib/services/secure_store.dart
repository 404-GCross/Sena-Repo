import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:shared_preferences/shared_preferences.dart";

import "../models/log_models.dart";
import "logger_service.dart";

class SecureStore {
  static const _storage = FlutterSecureStorage();

  static Future<String?> getString(String key) async {
    try {
      final value = await _storage.read(key: key);
      if (value != null && value.isNotEmpty) return value;
    } catch (e, stackTrace) {
      LoggerService().record(
        LogLevel.warning,
        "secure_store.read_failed",
        "安全存储读取失败，尝试旧存储",
        module: "storage",
        error: e,
        stackTrace: stackTrace,
        fields: {"key": _safeKey(key)},
      );
    }

    final prefs = await SharedPreferences.getInstance();
    final legacyValue = prefs.getString(key);
    if (legacyValue != null && legacyValue.isNotEmpty) {
      try {
        await _storage.write(key: key, value: legacyValue);
        await prefs.remove(key);
      } catch (e, stackTrace) {
        LoggerService().record(
          LogLevel.warning,
          "secure_store.migrate_failed",
          "旧凭据迁移到安全存储失败，仍使用旧存储",
          module: "storage",
          error: e,
          stackTrace: stackTrace,
          fields: {"key": _safeKey(key)},
        );
      }
    }
    return legacyValue;
  }

  static Future<void> setString(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (e, stackTrace) {
      LoggerService().record(
        LogLevel.warning,
        "secure_store.write_failed",
        "安全存储写入失败，已降级为本地偏好存储",
        module: "storage",
        error: e,
        stackTrace: stackTrace,
        fields: {"key": _safeKey(key)},
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    }
  }

  static Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e, stackTrace) {
      LoggerService().record(
        LogLevel.warning,
        "secure_store.delete_failed",
        "安全存储删除失败",
        module: "storage",
        error: e,
        stackTrace: stackTrace,
        fields: {"key": _safeKey(key)},
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }

  /// Key names are constant strings today, but never log a value.
  static String _safeKey(String key) => key.replaceAll(RegExp(r"[^a-z0-9_]"), "_");
}

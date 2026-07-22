import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:shared_preferences/shared_preferences.dart";

class SecureStore {
  static const _storage = FlutterSecureStorage();

  static Future<String?> getString(String key) async {
    try {
      final value = await _storage.read(key: key);
      if (value != null && value.isNotEmpty) return value;
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    final legacyValue = prefs.getString(key);
    if (legacyValue != null && legacyValue.isNotEmpty) {
      try {
        await _storage.write(key: key, value: legacyValue);
        await prefs.remove(key);
      } catch (_) {}
    }
    return legacyValue;
  }

  static Future<void> setString(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    }
  }

  static Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
}

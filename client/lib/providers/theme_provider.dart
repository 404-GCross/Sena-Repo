/// Theme / beautification state management.

import "package:flutter/material.dart";
import "package:shared_preferences/shared_preferences.dart";

class ThemeProvider extends ChangeNotifier {
  Color _accentColor = const Color(0xFF7C3AED);
  String? _backgroundUrl;
  Color? _bgColor;
  ThemeMode _themeMode = ThemeMode.dark;

  Color get accentColor => _accentColor;
  String? get backgroundUrl => _backgroundUrl;
  Color? get bgColor => _bgColor;
  ThemeMode get themeMode => _themeMode;
  bool get isDark => _themeMode == ThemeMode.dark;

  ThemeProvider() {
    WidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.getInstance().then((prefs) {
      final accentHex = prefs.getString("theme_accent");
      if (accentHex != null) {
        _accentColor = Color(int.parse(accentHex));
      }
      _backgroundUrl = prefs.getString("theme_bg_url");
      final bgHex = prefs.getString("theme_bg_color");
      if (bgHex != null) {
        _bgColor = Color(int.parse(bgHex));
      }
      final mode = prefs.getString("theme_mode");
      if (mode == "light") _themeMode = ThemeMode.light;
      else if (mode == "system") _themeMode = ThemeMode.system;
      notifyListeners();
    });
  }

  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString("theme_mode", mode.name);
    });
    notifyListeners();
  }

  Future<void> setAccentColor(Color color) async {
    _accentColor = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("theme_accent", color.value.toString());
    notifyListeners();
  }

  Future<void> setBackgroundUrl(String? url) async {
    _backgroundUrl = url;
    final prefs = await SharedPreferences.getInstance();
    if (url != null) {
      await prefs.setString("theme_bg_url", url);
    } else {
      await prefs.remove("theme_bg_url");
    }
    notifyListeners();
  }

  Future<void> setBgColor(Color? color) async {
    _bgColor = color;
    final prefs = await SharedPreferences.getInstance();
    if (color != null) {
      await prefs.setString("theme_bg_color", color.value.toString());
    } else {
      await prefs.remove("theme_bg_color");
    }
    notifyListeners();
  }
}

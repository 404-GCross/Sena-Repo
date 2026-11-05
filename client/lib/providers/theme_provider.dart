/// Theme / beautification state management.

import "dart:io";

import "package:flutter/material.dart";
import "package:shared_preferences/shared_preferences.dart";

import "../services/background_image_store.dart";

class BackgroundSettings {
  final String? path;
  final double opacity;
  final double blur;
  final double alignX;
  final double alignY;

  const BackgroundSettings({
    this.path,
    this.opacity = 0.22,
    this.blur = 0,
    this.alignX = 0,
    this.alignY = 0,
  });

  bool get hasImage => path != null && path!.trim().isNotEmpty;

  BackgroundSettings copyWith({
    String? path,
    bool clearPath = false,
    double? opacity,
    double? blur,
    double? alignX,
    double? alignY,
  }) {
    return BackgroundSettings(
      path: clearPath ? null : (path ?? this.path),
      opacity: opacity ?? this.opacity,
      blur: blur ?? this.blur,
      alignX: alignX ?? this.alignX,
      alignY: alignY ?? this.alignY,
    );
  }
}

class ThemeProvider extends ChangeNotifier {
  Color _accentColor = const Color(0xFF7C3AED);
  BackgroundSettings _mobile = const BackgroundSettings();
  BackgroundSettings _desktop = const BackgroundSettings();
  Future<void> _saveChain = Future.value();

  Color get accentColor => _accentColor;

  /// Phones and tablets keep the portrait profile even after rotating.
  bool get isMobilePlatform => Platform.isAndroid || Platform.isIOS;

  BackgroundSettings backgroundFor(bool mobile) =>
      mobile ? _mobile : _desktop;

  ThemeProvider() {
    WidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.getInstance().then((prefs) async {
      final accentHex = prefs.getString("theme_accent");
      if (accentHex != null) {
        _accentColor = Color(int.parse(accentHex));
      }
      _mobile = _read(prefs, "mobile");
      _desktop = _read(prefs, "desktop");
      final legacy = prefs.getString("theme_bg_url");
      if (legacy != null && legacy.isNotEmpty && !_desktop.hasImage) {
        final path =
            legacy.startsWith("file://") ? legacy.substring(7) : legacy;
        _desktop = _desktop.copyWith(path: path);
        await prefs.setString("theme_bg_desktop_path", path);
        await prefs.remove("theme_bg_url");
      }
      notifyListeners();
    });
  }

  BackgroundSettings _read(SharedPreferences prefs, String mode) {
    final path = prefs.getString("theme_bg_${mode}_path");
    return BackgroundSettings(
      path: path,
      opacity: prefs.getDouble("theme_bg_${mode}_opacity") ?? 0.22,
      blur: prefs.getDouble("theme_bg_${mode}_blur") ?? 0,
      alignX: prefs.getDouble("theme_bg_${mode}_align_x") ?? 0,
      alignY: prefs.getDouble("theme_bg_${mode}_align_y") ?? 0,
    );
  }

  Future<void> setAccentColor(Color color) async {
    _accentColor = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("theme_accent", color.value.toString());
    notifyListeners();
  }

  Future<void> setBackgroundImage({
    required bool mobile,
    String? path,
    bool clear = false,
  }) async {
    final current = backgroundFor(mobile);
    if (current.path != path) {
      await BackgroundImageStore.delete(current.path);
    }
    final updated = current.copyWith(path: path, clearPath: clear);
    await _save(mobile, updated);
  }

  Future<void> setBackgroundOpacity(bool mobile, double value) async {
    await _save(
      mobile,
      backgroundFor(mobile).copyWith(
        opacity: value.clamp(0.05, 1.0).toDouble(),
      ),
    );
  }

  Future<void> setBackgroundBlur(bool mobile, double value) async {
    await _save(
      mobile,
      backgroundFor(mobile).copyWith(
        blur: value.clamp(0, 24).toDouble(),
      ),
    );
  }

  Future<void> setBackgroundAlignment(
    bool mobile,
    double x,
    double y,
  ) async {
    await _save(
      mobile,
      backgroundFor(mobile).copyWith(
        alignX: x.clamp(-1.0, 1.0).toDouble(),
        alignY: y.clamp(-1.0, 1.0).toDouble(),
      ),
    );
  }

  Future<void> clearBackground(bool mobile) async {
    final current = backgroundFor(mobile);
    await BackgroundImageStore.delete(current.path);
    await _save(mobile, const BackgroundSettings());
  }

  Future<void> _save(bool mobile, BackgroundSettings settings) {
    if (mobile) {
      _mobile = settings;
    } else {
      _desktop = settings;
    }
    notifyListeners();
    final operation = _saveChain
        .catchError((Object _) {})
        .then((_) => _write(mobile, settings));
    _saveChain = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _write(bool mobile, BackgroundSettings settings) async {
    final mode = mobile ? "mobile" : "desktop";
    final prefs = await SharedPreferences.getInstance();
    if (settings.hasImage) {
      await prefs.setString("theme_bg_${mode}_path", settings.path!);
    } else {
      await prefs.remove("theme_bg_${mode}_path");
    }
    await prefs.setDouble("theme_bg_${mode}_opacity", settings.opacity);
    await prefs.setDouble("theme_bg_${mode}_blur", settings.blur);
    await prefs.setDouble("theme_bg_${mode}_align_x", settings.alignX);
    await prefs.setDouble("theme_bg_${mode}_align_y", settings.alignY);
  }
}

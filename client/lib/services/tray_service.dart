/// System tray service — minimize to tray on close.
/// Windows / Linux desktop only. Window close handling is in main.dart.

import "dart:io" show Directory, File, Platform;
import "dart:typed_data";
import "dart:ui" as ui;

import "package:path_provider/path_provider.dart";
import "package:system_tray/system_tray.dart";
import "package:window_manager/window_manager.dart";

class TrayService {
  final SystemTray _tray = SystemTray();
  bool _enabled = false;
  bool _initialized = false;
  void Function()? _onQuit;

  bool get isEnabled => _enabled;

  Future<void> init({required void Function() onQuit}) async {
    if (_initialized) return;
    _onQuit = onQuit;

    if (!Platform.isWindows && !Platform.isLinux) return;

    // Generate a simple tray icon (16x16 purple square = Sena Repo brand)
    String iconPath = "";
    try {
      final dir = await getTemporaryDirectory();
      final iconFile = File("${dir.path}/sena_tray_icon.png");
      if (!await iconFile.exists()) {
        final bytes = await _generateIconPng();
        await iconFile.writeAsBytes(bytes);
      }
      iconPath = iconFile.path;
    } catch (_) {}

    await _tray.initSystemTray(
      title: "Sena Repo",
      iconPath: iconPath,
    );

    final menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(label: "显示窗口", onClicked: (_) => windowManager.show()),
      MenuItemLabel(label: "退出", onClicked: (_) => _onQuit?.call()),
    ]);
    await _tray.setContextMenu(menu);
    _initialized = true;
  }

  /// Generate a 32x32 purple PNG icon programmatically.
  Future<Uint8List> _generateIconPng() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    const size = 32.0;

    final paint = ui.Paint()..color = const ui.Color(0xFF7C3AED);
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(
        const ui.Rect.fromLTWH(0, 0, size, size),
        const ui.Radius.circular(6),
      ),
      paint,
    );

    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
  }

  void showWindow() => windowManager.show();

  Future<void> dispose() async {
    await windowManager.setPreventClose(false);
  }
}

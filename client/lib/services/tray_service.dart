/// System tray service — minimize to tray on close.
/// Windows / Linux desktop only, using tray_manager.
/// Pattern based on PiliPlus implementation.

import "dart:io" show File, Platform;
import "dart:typed_data";
import "dart:ui" as ui;

import "package:path_provider/path_provider.dart";
import "package:tray_manager/tray_manager.dart";
import "package:window_manager/window_manager.dart";

class TrayService with TrayListener {
  bool _enabled = false;
  bool _initialized = false;
  void Function()? _onQuit;

  bool get isEnabled => _enabled;

  Future<void> init({required void Function() onQuit}) async {
    if (_initialized) return;
    _onQuit = onQuit;

    if (!Platform.isWindows && !Platform.isLinux) return;

    trayManager.addListener(this);

    // Generate icon and set
    String iconPath = "";
    try {
      final dir = await getTemporaryDirectory();
      final iconFile = File("${dir.path}/sena_tray.png");
      if (!await iconFile.exists()) {
        await iconFile.writeAsBytes(await _genIcon());
      }
      iconPath = iconFile.path;
    } catch (_) {}
    await trayManager.setIcon(iconPath);
    await trayManager.setToolTip("Sena Repo");

    final menu = Menu(items: [
      MenuItem(key: "show", label: "显示窗口"),
      MenuItem.separator(),
      MenuItem(key: "exit", label: "退出"),
    ]);
    await trayManager.setContextMenu(menu);

    _initialized = true;
  }

  Future<Uint8List> _genIcon() async {
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

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu(bringAppToFront: true);
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case "show":
        windowManager.show();
      case "exit":
        _onQuit?.call();
    }
  }

  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
  }

  Future<void> dispose() async {
    trayManager.removeListener(this);
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
  }
}

/// System tray service — minimize to tray on close.
/// Windows / Linux desktop only. Window close handling is in main.dart.

import "dart:io" show Platform;

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

    await _tray.initSystemTray(
      title: "Sena Repo",
      iconPath: "",
    );

    final menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(label: "显示窗口", onClicked: (_) => windowManager.show()),
      MenuItemLabel(label: "退出", onClicked: (_) => _onQuit?.call()),
    ]);
    await _tray.setContextMenu(menu);

    _initialized = true;
  }

  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
  }

  void showWindow() => windowManager.show();

  Future<void> dispose() async {
    await windowManager.setPreventClose(false);
  }
}

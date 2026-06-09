/// System tray service — minimize to tray on close.
/// Windows / Linux desktop only.

import "dart:io" show Platform;

import "package:flutter/material.dart";
import "package:system_tray/system_tray.dart";
import "package:window_manager/window_manager.dart";

class TrayService {
  final SystemTray _tray = SystemTray();
  bool _enabled = false;
  bool _initialized = false;
  VoidCallback? _onQuit;

  bool get isEnabled => _enabled;

  Future<void> init({required VoidCallback onQuit}) async {
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
      MenuItemSeparator(),
      MenuItemLabel(label: "退出", onClicked: (_) => _onQuit?.call()),
    ]);
    await _tray.setContextMenu(menu);

    windowManager.setPreventClose(true);
    windowManager.addListener(_onWindowEvent);

    _initialized = true;
  }

  void _onWindowEvent() async {
    if (!_enabled) return;
    if (await windowManager.isPreventClose()) {
      await windowManager.hide();
    }
  }

  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    if (!_initialized) return;
    await windowManager.setPreventClose(enabled);
  }

  void showWindow() => windowManager.show();

  Future<void> dispose() async {
    windowManager.removeListener(_onWindowEvent);
    await windowManager.setPreventClose(false);
  }
}
